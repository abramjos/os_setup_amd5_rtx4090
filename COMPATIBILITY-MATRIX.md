> **STATUS: ACTIVE** — Technical research reference for firmware/kernel/compositor decisions. Primary output of the research phase.

# Technical Research Findings: Raphael DCN 3.1.5 Display Stability

**Hardware:** AMD Ryzen 9 7950X | ASUS ROG Crosshair X670E Hero | RTX 4090 (headless) + Raphael iGPU (display)
**Date:** 2026-03-28 (updated 2026-03-31 with Variant H v1 test results)
**Based on:** 20-boot diagnostic data (runLog-04), upstream bug trackers, kernel mailing lists, linux-firmware git history, 60+ web sources

> **For OS selection**, see [OS-DECISION-MATRIX.md](OS-DECISION-MATRIX.md).
> **For cross-OS infrastructure comparison**, see [OS-CROSSCUTTING-CONCERNS.md](OS-CROSSCUTTING-CONCERNS.md).
> **For installation scripts and verification**, see [INSTALLATION-PROMPT.md](INSTALLATION-PROMPT.md).
> **For the original research specification**, see [RESEARCH-PROMPT.md](RESEARCH-PROMPT.md).

---

## 1. The Crash Loop — Mechanistic Analysis

### The Failure Sequence

```
[  6.1s] REG_WAIT timeout — optc31_disable_crtc line:136    ← DCN register stall during EFI→amdgpu handoff
[  8.0s] REG_WAIT timeout — optc1_wait_for_state            ← Cascading: OTG stopped, no VBLANK arrives
[ 18.5s] ring gfx_0.0.0 timeout (gnome-shell)               ← GFX ring hangs on corrupted display state
[ 19.0s] MODE2 GPU reset                                     ← Resets GFX/SDMA only — NOT the DCN
[ 31.3s] ring gfx_0.0.0 timeout (gnome-shell #2)            ← DCN still broken → repeat
[ 69.2s] ring gfx_0.0.0 timeout (gnome-shell #3)            ← GDM gives up → session-failed
```

### What The Registers Tell Us

**`optc31_disable_crtc` (line ~136):** Disables the BIOS-configured CRTC during amdgpu init. Disconnects OPP segments from ODM, disables OTG master, then waits for `OTG_BUSY` bit in `OTG_CLOCK_CONTROL` to clear. The wait is 1us x 100,000 = 100ms. When `OTG_BUSY` stays stuck, the timeout fires.

**Why OTG_BUSY stays stuck:** The DCN31 implementation uses `OTG_DISABLE_POINT_CNTL=2` (disable at end-of-frame), but if the display pipeline is stalled, the end-of-frame never arrives, so OTG_BUSY never clears. Fixed upstream by the "bypass ODM before CRTC off" patch.

**`optc1_wait_for_state` (line ~839):** Waits for `OTG_V_BLANK` or `OTG_V_ACTIVE_DISP` in `OTG_STATUS`. If OTG is dead from the first failure, no timing signals → always times out. Cascading failure, not independent.

### Why MODE2 Reset Cannot Fix This

**Source:** [Kernel Driver Core Documentation](https://docs.kernel.org/gpu/amdgpu/driver-core.html), [amd-gfx mailing list](https://www.mail-archive.com/amd-gfx@lists.freedesktop.org/msg109235.html)

The GPU IP block routing on Raphael:
```
GCHUB  ← GC (Graphics Compute) + SDMA   ← MODE2 resets THESE
MMHUB  ← VCN + JPEG + VPE               ← MODE1 resets THIS
DCHUB  ← DCN (Display Core Next)         ← NOT TOUCHED BY MODE2
```

- **MODE2 (`reset_method=3`, default):** Resets only GC and SDMA. DCN remains broken. Each reset restores the GFX ring, but gnome-shell immediately hits the still-broken DCN pipeline → another ring timeout → infinite loop.
- **MODE0 (`reset_method=1`):** Full ASIC reset. Should reset ALL IP blocks including DCN/DCHUB. Side effects: VRAM lost, display goes black, all state re-initialized. **NOT SUPPORTED on Raphael APU — kernel 6.17 rejects it with "Specified reset method:1 isn't supported, using AUTO instead."**
- **BACO (`reset_method=4`):** Bus Active Chip Off — not applicable to APUs (iGPU has no separate power domain).

### The Crash Requires Two Conditions

1. **optc31_disable_crtc timeout at boot** (~6s) — stalls DCN pipeline
2. **GFX ring submissions from compositor** — gnome-shell floods the ring, which hangs on stalled DCN → MODE2 reset (GFX only, NOT DCN) → repeat

If EITHER condition is removed, the crash loop breaks:
- Fix condition 1: update DMCUB firmware + kernel patches → DCN doesn't stall — **CONFIRMED by Variant B v2 (2026-03-30)** and **Variant H v1 (2026-03-31): 1 optc31 at T+5.084s, DCN recovered without ring timeout, 72+ min stable uptime**
- Remove condition 2: use XFCE (zero GPU ring submissions via XRender) → even if DCN stalls, no ring timeout triggers — **CONFIRMED by Variant A (2026-03-29)**

> **H v1 nuance:** With DMUB >= 0x05002000, Condition 1 still fires (optc31 timeout at ~5s is hardware EFI handoff timing), but the DCN *recovers* on its own — it no longer stalls permanently. This means AccelMethod=none (XFCE + XRender) becomes belt-and-suspenders rather than the sole safety net. Both conditions were addressed in H v1: firmware fixed Condition 1 recovery, and AccelMethod=none (software rendering) eliminated Condition 2 entirely. Result: stable desktop despite optc31 still appearing in dmesg.

---

## 2. DMCUB Firmware Analysis

### Version History

DMCUB firmware versions are encoded as `0x0XYYZZWW` → `X.YY.ZZ.WW`:
- `0x05000F00` (stock Ubuntu 24.04) = version **0.0.15.0** — **REPLACED** with 0x05002000 (0.0.32.0) via install-firmware.sh (2026-03-30)
- Format in dmesg: `Loading DMUB firmware via PSP: version=0x05XXXXXX`

| linux-firmware Tag | DMCUB Version | Status | Evidence |
|--------------------|---------------|--------|----------|
| ≤ 20240318 | ~0.0.191.0 or earlier | **KNOWN BAD** | Pre-Debian-fix; stock Ubuntu 24.04 |
| 20240709 | 0.0.224.0 | **KNOWN GOOD** | [Debian #1057656](https://bugs-devel.debian.org/cgi-bin/bugreport.cgi?bug=1057656) fix release |
| **20250305** | **0.0.255.0** | **KNOWN GOOD (safest)** | Last 0.0.x series, widest community testing |
| **20250509** | **0.0.32.0 (0x05002000)** | **TESTED STABLE** | **Variant B v2 (2026-03-30): 8 boots, 0 ring timeouts, glamor enabled. Variant H v1 (2026-03-31): delivered via autoinstall initramfs hook (confirmed in debugfs), DCN recovered after single optc31, 0 ring timeouts, 72+ min uptime** |
| 20250613 | 0.1.14.0 | **KNOWN BAD** | [NixOS #418212](https://github.com/nixos/nixpkgs/issues/418212): "failed to load ucode DMCUB(0x3D)" on Raphael |
| 20260221+ | Post-MR#587 0.1.x | **LIKELY GOOD** | [MR #587](https://gitlab.com/kernel-firmware/linux-firmware/-/merge_requests/587) "Update DMCUB fw for DCN401 & DCN315" |
| 20260309 | ~0.1.40-0.1.53 | **LIKELY GOOD** | Fedora 42/Arch ship this; post-regression-fix |

**Key insight:** DCN315 = DCN 3.1.5 (AMD naming convention). MR #587 specifically fixes DMCUB for DCN 3.1.5.

### Safe Firmware Targets

| Strategy | Tag | DMCUB Version | Risk | Best For |
|----------|-----|---------------|------|----------|
| **Tested stable** | 20250509 | 0.0.32.0 (0x05002000) | **Tested on production HW × 2 methods** | Current autoinstall default (all variants); confirmed via manual script (B v2) AND initramfs hook (H v1) |
| **Conservative** | 20250305 | 0.0.255.0 | Lowest theoretical | Manual firmware update on Ubuntu |
| **Latest stable** | 20260309 | ~0.1.40+ | Low (post-regression-fix) | Fedora/Arch (ships by default) |
| **Avoid** | 20250613 | 0.1.14.0 | **HIGH — known regression** | Do not use |

### Ubuntu SRU Status (UPDATED)

The original research stated "Ubuntu Noble NEVER updated DCN 3.1.5 DMCUB." Deeper investigation found two relevant SRU entries:

- **0ubuntu2.21** (November 2025): AMD GPU PSP 14.0.0/14.0.4, GC 11.5.1, SDMA 7.0.1 — not explicitly DCN 3.1.5
- **0ubuntu2.22** (January 2026): "AMD GPU PSP/GC/DMCUB firmware updates" — possibly includes DCN 3.1.5 but changelog is ambiguous

The later entry (0ubuntu2.22) suggests the DMCUB MAY have been updated. However:
- The changelog never explicitly names `dcn_3_1_5_dmcub.bin`
- The system currently loads `0x05000F00` (0.0.15.0), which predates all fixes
- This could mean: the SRU delivered the fix but `.bin`/`.bin.zst` conflict prevented loading, or the initramfs wasn't rebuilt, or the SRU version is still too old

**H v1 verdict (2026-03-31):** `dmesg` confirmed `DMCUB feature version: 0, firmware version: 0x05002000` — the autoinstall initramfs hook (forcing blobs into initramfs at install time) successfully delivered `20250509` firmware. The stock Ubuntu SRU was NOT delivering 0x05002000 before the hook ran; the hook is the correct fix. **Question 1 in Section 8 is now CLOSED.**

### The `.bin` vs `.bin.zst` Conflict

The kernel firmware loader checks in this order:
1. `{name}.zst` (if `CONFIG_FW_LOADER_COMPRESS_ZSTD=y` — YES on Ubuntu 24.04)
2. `{name}.xz` (if `CONFIG_FW_LOADER_COMPRESS_XZ=y`)
3. `{name}` (uncompressed)

Ubuntu 24.04 has `CONFIG_FW_LOADER_COMPRESS_ZSTD=y`, so `.bin.zst` takes priority. If BOTH `.bin` and `.bin.zst` exist:
- The `.bin.zst` (from Ubuntu's package, potentially outdated) is loaded
- The manually placed `.bin` (from git, potentially newer) is **completely ignored**

**Resolution:** After placing new firmware, compress to `.bin.zst` and remove bare `.bin`:
```bash
sudo zstd -f /lib/firmware/amdgpu/dcn_3_1_5_dmcub.bin \
     -o /lib/firmware/amdgpu/dcn_3_1_5_dmcub.bin.zst
sudo rm -f /lib/firmware/amdgpu/dcn_3_1_5_dmcub.bin
sudo update-initramfs -u -k all
```

---

## 3. Kernel DCN31 Patch Table

| Kernel | Commit | Patch | Impact | Criticality |
|--------|--------|-------|--------|-------------|
| **6.10+** | `a878304276b8` | **Bypass ODM before CRTC off** | Disconnects ODM BEFORE disabling OTG master. **Directly fixes optc31 timeout.** | **CRITICAL** |
| **6.12+** | `9724b8494d3e` | **Restore immediate_disable_crtc** | Re-adds `OTG_DISABLE_POINT_CNTL=0` for DCN31. Prevents OTG_BUSY hang when pipeline stalled. | HIGH |
| **6.13+** | `faee3edfcff7` | **Wait for all pending cleared** | `REG_WAIT(OTG_PENDING_CLEAR, 0)` after OTG disable. Prevents register update race. | MEDIUM |
| **6.13+** | `391cea4fff00` | **Skip disable CRTC on seamless boot** | If `amdgpu.seamless=1`, skips entire CRTC disable path. Avoids optc31 timeout entirely. | HIGH (if seamless used) |
| **6.15+** | `c707ea82c79d` | **Ensure DMCUB idle before reset** | Increases halt-wait from 100 to **100,000 iterations**. Prevents premature timeout during DMCUB state transition. | **CRITICAL** |
| **6.15+** | CVE-2024-46870, CVE-2024-47662 | **DMCUB diagnostic fixes** | Fixes deterministic hangs during DMCUB error recovery and diagnostic register reads. | HIGH |

### Kernel Version Summary

| Kernel | Critical Patches | Available On |
|--------|-----------------|-------------|
| 6.8 (Ubuntu 24.04 GA) | **0 of 6** — most vulnerable | Ubuntu 24.04 stock |
| 6.11 (Ubuntu HWE 24.04.2) | 1 of 6 mainline (ODM bypass only) | Ubuntu 24.04.2 |
| 6.14 (Ubuntu HWE 24.04.3, Fedora 42/43 at launch) | 4 of 6 — missing DMCUB idle fix + CVE fixes | Ubuntu 24.04.3, Fedora |
| **6.17 (Ubuntu HWE 24.04.4)** | **6 of 6** — all patches | Ubuntu 24.04.4, Pop!_OS |
| 6.19 (Fedora 43 current, Arch) | 6 of 6 + additional fixes | Fedora 43, Arch |

> **Counting methodology:** Patch counts reflect **mainline kernel inclusion** (the "Kernel" column in the patch table above). Ubuntu HWE kernels may have additional backports via SRU — verify with `zcat /proc/config.gz` or `apt changelog linux-image-$(uname -r)` on a live system. The 6 patches are: ODM bypass (6.10+), immediate_disable_crtc (6.12+), pending clear (6.13+), seamless skip (6.13+), DMCUB idle fix (6.15+), CVE diagnostic fixes (6.15+).

### Why Kernel 6.17 Still Crashed (Explained)

Kernel 6.17 has ALL DCN31 patches. Yet it still crashed in the 20-boot diagnostic (runLog-04). The reasons:

1. **DMCUB firmware still ancient** (HIGHEST) — The patches optimize driver-side handoff, but DMCUB runs its own firmware. If that firmware has a state machine bug (Debian #1057656 proved it), no driver patch compensates. The `.bin.zst` priority meant manual updates were ignored.

2. **simpledrm steals card0** — GNOME picked simpledrm as primary, software-rendered, then crashed when amdgpu took over.

3. **Test A stripped all critical parameters** — `sg_display=-1` (default, not 0), `ppfeaturemask=0xfff7bfff` (wrong value, not 0xfffd7fff). Scatter/gather display active, GFXOFF potentially enabled.

4. **Stale initramfs** — Not rebuilt after switching kernels; old firmware/config baked in.

**Conclusion:** The failures were firmware + config, not kernel. Kernel 6.17 is viable once firmware and parameters are correct.

---

## 4. simpledrm Card Ordering

**Source:** [Arch Linux Forums](https://bbs.archlinux.org/viewtopic.php?id=303311), [Blog post](https://blog.lightwo.net/fix-gpu-identifier-randomly-setting-to-card0-or-card1-linux.html)

`simpledrm` is built into the kernel (not a module) and takes over the EFI GOP framebuffer at very early boot, before any GPU driver loads. It registers as a DRM device and claims `card0`. When `amdgpu` loads later, it gets `card1`. This causes:

- Compositor may target the wrong device
- DRI_PRIME defaults may be wrong
- Display manager confusion

**Fix:** `initcall_blacklist=simpledrm_platform_driver_init`

This prevents simpledrm from creating the firmware FB device. Display is black until amdgpu loads (acceptable for workstation without disk encryption).

**Confirmed working:** Multiple Arch forum posts, blog posts, and community reports.

---

## 5. GNOME Ring Timeout Is Cross-Distro

**Sources:**
- [Fedora 42](https://discussion.fedoraproject.org/t/gnome-shell-crash-and-gpu-ring-timeout-on-amd-gpu-when-using-brave-browser-fedora-42/149587)
- [Ubuntu 25.04](https://discourse.ubuntu.com/t/amd-gpu-crashing-on-ubuntu-25-04-ring-gfx-0-0-0-timeout-and-reset-failure/62975)
- [Ubuntu Bug #2141396](http://www.mail-archive.com/desktop-bugs@lists.ubuntu.com/msg829655.html)

GNOME Shell ring gfx timeout crashes are confirmed on:
- Fedora 42 (kernel 6.14 + GNOME 48)
- Ubuntu 25.04 (kernel 6.14)
- Ubuntu 24.04 (kernel 6.8 and 6.17)

**This is NOT distro-specific.** Switching distros without switching compositors will NOT fix it.

### Mutter-Specific SIGKILL Bug

Mutter 46.x creates a real-time priority KMS page-flip thread. When amdgpu takes too long on a page flip (due to DCN latency on Raphael), the thread exceeds its RT scheduling deadline → SIGKILL → crashes gnome-shell/GDM independently of ring timeouts.

**Workaround:**
```bash
echo 'MUTTER_DEBUG_KMS_THREAD_TYPE=user' | sudo tee /etc/environment.d/90-mutter-kms.conf
```

### Compositor Risk Matrix

| Compositor | GPU Backend | GFX Ring Pressure | Crash Avoidance |
|-----------|------------|-------------------|----------------|
| **GNOME (Mutter)** | OpenGL | **HIGH** | None — crashes |
| **XFCE (xfwm4, compositing OFF)** | None (XRender) | **ZERO** | **HIGHEST** |
| **XFCE (xfwm4, compositing ON)** | XRender (CPU) | **VERY LOW** | HIGH |
| **Sway (wlroots)** | Minimal GL | LOW | HIGH |
| **COSMIC (cosmic-comp)** | OpenGL ES | LOW-MEDIUM | GOOD (but still uses GFX ring) |
| **KDE Plasma (KWin)** | OpenGL | MEDIUM | MEDIUM |
| **i3wm** | None | ZERO | **HIGHEST** |
| **TTY only** | None | ZERO | Diagnostic only |

---

## 6. NVIDIA 595 — Key Changes

**Source:** [NVIDIA README](https://us.download.nvidia.com/XFree86/Linux-x86_64/595.58.03/README/kernel_open.html)

| Change | Impact |
|--------|--------|
| Open kernel modules now **DEFAULT** | Override with `-M=proprietary` if needed |
| `nvidia-drm.modeset=1` now **DEFAULT** | Remove from GRUB/modprobe if already set (avoid double-setting) |
| CudaNoStablePerfLimit | CUDA apps reach P0 (full clock speed) |
| xfwm4 blinking fix | Directly relevant for XFCE compositor |
| Kernel 4.15–6.19 support | Explicit build fix for 6.19 |
| `NVreg_EnableGpuFirmware=1` required | `=0` breaks open kernel modules |

**Package naming changed at branch 590.** There is no `nvidia-headless-595-server`. Use:
- Ubuntu: `cuda-drivers` from NVIDIA CUDA repo
- Fedora: `akmod-nvidia` from RPM Fusion (currently ships 580.119, not 595)
- Arch: `nvidia-open-dkms` from official repo (ships 595.58.03)

---

## 7. PCIe Gen1 Downgrade — RTX 4090

**Discovered:** Variant H v1 log analysis (2026-03-31) via `lspci -vvv` in `08-pci-hardware/pci-link-state.txt`.

### Observed State

```
RTX 4090 (01:00.0):
  LnkSta:  Speed 2.5GT/s (downgraded), Width x16
  LnkCtl2: Target Link Speed: 16GT/s
```

The card is targeting PCIe Gen4 (16GT/s) but negotiated to Gen1 (2.5GT/s). BIOS set to "Auto" caused fallback.

### Bandwidth Impact

| Speed | Bandwidth (x16) | ML Workload Impact |
|-------|-----------------|-------------------|
| PCIe Gen1 (2.5GT/s) | ~4 GB/s theoretical | **~8× below Gen4 — bottlenecks large model weight transfers** |
| PCIe Gen4 (16GT/s) | ~32 GB/s theoretical | Full RTX 4090 throughput |

At Gen1, VRAM bandwidth over PCIe for host↔device transfers (model loading, gradient checkpointing, large batch data) is constrained to ~4 GB/s. This is a hard bottleneck for ML workloads that move data between system RAM and VRAM.

**Note:** GPU inference *within* VRAM is not PCIe-bound. The penalty is per host↔VRAM transfer operation.

### Root Cause

The upstream PCIe bridge shows `EqualizationComplete-` (equalization never completed), causing BIOS "Auto" to fall back to Gen1 rather than Gen4. This is a BIOS configuration issue, not a driver or kernel issue.

### Fix Required

**BIOS action only — cannot be fixed in software:**
1. Enter BIOS (Del at POST)
2. Navigate to: Advanced → PCIe/NVMe Configuration → PCIEX16_1 (or equivalent slot name)
3. Set Target Link Speed: **Gen4** (not Auto)
4. Save and reboot
5. Verify: `sudo lspci -vvv | grep -A2 "RTX\|NVIDIA"` → should show `Speed 16GT/s (ok)`

---

## 8. Documentation Gaps Found  <!-- was §7 -->

Inconsistencies discovered across the existing documentation (`setup/` directory, CLAUDE.md, scripts):

| # | Issue | Impact |
|---|-------|--------|
| 1 | `sg_display=0` removed by Test A, listed as "CRITICAL" in 5 docs | Running system has `-1` (default) |
| 2 | `ppfeaturemask` removed; running value `0xfff7bfff` ≠ documented `0xfffd7fff` | GFXOFF bit may be enabled |
| 3 | `dcdebugmask=0x10` in modprobe.d per docs, but scripts say GRUB-only on 6.8+ | Verify if modprobe.d works |
| 4 | `Integrated Graphics = Force` missing from 3 of 5 docs | Needs BIOS visual verification |
| 5 | UMA Frame Buffer: one doc says 512M OK, four say 512M crashes | [drm/amd #3006](https://gitlab.freedesktop.org/drm/amd/-/issues/3006) confirms 512M is bad |
| 6 | `NVreg_EnableGpuFirmware=1` in 3 docs, BIOS guide says `=0` | **RESOLVED:** `=1` is correct. The `=0` reference was an error. `=0` breaks open modules (595 default). |
| 7 | `nvidia-drm.modeset=1` in GRUB — now DEFAULT in 595, possibly doubled | Remove from GRUB if using 595 |
| 8 | `amdgpu.reset_method` was missing from all docs — **ADDED THEN REMOVED** | MODE2 doesn't reset DCN; mode0 (reset_method=1) was added but is **NOT SUPPORTED on Raphael APU** (kernel 6.17: "Specified reset method:1 isn't supported, using AUTO instead"). Removed from configs. |
| 9 | NixOS Raphael module only applies `sg_display=0` for 6.2-6.5 | optc31 issue is DIFFERENT from sg_display flickering |
| 10 | DCN 3.1.5 DMCUB SRU status never checked | All docs assumed Ubuntu updated it |

### Parameters Never Tested

| Parameter | Value | Effect | Why Test |
|-----------|-------|--------|----------|
| ~~`amdgpu.reset_method=1`~~ | ~~mode0 (full ASIC)~~ | ~~Resets ALL IP blocks including DCN~~ | **TESTED AND REJECTED** — NOT SUPPORTED on Raphael APU (kernel 6.17: "Specified reset method:1 isn't supported, using AUTO instead"). Falls back to MODE2. |
| `amdgpu.lockup_timeout=30000` | 30s | Increases ring timeout | Prevents reset during slow DMCUB init |
| `amdgpu.seamless=1` | Force seamless boot | Skips CRTC disable entirely | Avoids optc31 path |
| `amdgpu.dcdebugmask=0x08` | Disable DCN clock gating | Keeps OPTC registers powered | May prevent REG_WAIT timeout |
| `initcall_blacklist=simpledrm_platform_driver_init` | Block simpledrm | Fix card ordering | Confirmed by Arch community |

---

## 8. Open Questions

| # | Question | How to Answer | Priority |
|---|----------|--------------|----------|
| 1 | ~~Did the SRU (0ubuntu2.21 or 0ubuntu2.22) actually deliver a working DMCUB for DCN315?~~ | **ANSWERED (H v1, 2026-03-31):** `debugfs` confirmed `firmware version: 0x05002000` on H v1. Delivery was via the **autoinstall initramfs hook**, not the SRU. The stock Ubuntu SRU was not sufficient; the hook is the correct fix. | **CLOSED** |
| 2 | ~~Does `reset_method=1` (mode0) actually reset DCN on Raphael APU?~~ | **ANSWERED:** `reset_method=1` (mode0) is **NOT SUPPORTED** on Raphael APU. Kernel 6.17 rejects it: "Specified reset method:1 isn't supported, using AUTO instead." Falls back to MODE2, which does not reset DCN. | **CLOSED** |
| 3 | Does XFCE avoid the crash loop even WITHOUT firmware fix? | Install XFCE, boot with old firmware, check dmesg | MEDIUM |
| 4 | Does TTY boot still show optc31 timeout? | `systemctl set-default multi-user.target`, check dmesg | MEDIUM |
| 5 | What is actual UMA Frame Buffer Size in BIOS? | Visual BIOS check | MEDIUM |
| 6 | Does `amdgpu.seamless=1` skip the optc31 path entirely? | Boot test | LOW |
| 7 | Is the manual `.bin` (242208 bytes) actually a different firmware than the `.bin.zst`? | `zstd -d .bin.zst -o /tmp/old.bin && diff` | LOW |
| 8 | Is the RTX 4090 running at PCIe Gen1 (2.5GT/s) due to BIOS "Auto" fallback? | **CONFIRMED (H v1, 2026-03-31):** `LnkSta: Speed 2.5GT/s (downgraded), Width x16; LnkCtl2: Target Link Speed: 16GT/s`. BIOS must be set to Gen4 explicitly — see Section 7. | **CLOSED — BIOS action required** |

---

## 9. Upstream Bug References  <!-- was §8 -->

### OPEN — Exact or Near Match
- **[drm/amd #5073](https://gitlab.freedesktop.org/drm/amd/-/work_items/5073)** — Fence fallback timer expired on Raphael iGPU. EXACT match: same hardware, same errors. **OPEN.**
- [drm/amd #3377](https://gitlab.freedesktop.org/drm/amd/-/work_items/3377) — Raphael optc1_wait_for_state black screen. **OPEN.**
- [drm/amd #3583](https://gitlab.freedesktop.org/drm/amd/-/work_items/3583) — 9950X optc31_disable_crtc + DMCUB error. **OPEN.**
- [drm/amd #4433](https://gitlab.freedesktop.org/drm/amd/-/work_items/4433) — 8600G optc314_disable_crtc REG_WAIT timeout. **OPEN.**
- [drm/amd #3006](https://gitlab.freedesktop.org/drm/amd/-/issues/3006) — UMA 512M causes gfx ring timeouts.

### FIXED — Firmware
- [Debian #1057656](https://bugs-devel.debian.org/cgi-bin/bugreport.cgi?bug=1057656) — DMCUB firmware broke Raphael display. **FIXED** in firmware 20240709.
- [NixOS #418212](https://github.com/nixos/nixpkgs/issues/418212) — DMCUB 0.1.14.0 load failure on Raphael. **FIXED** in MR#587.
- [kernel-firmware MR #587](https://gitlab.com/kernel-firmware/linux-firmware/-/merge_requests/587) — "Update DMCUB fw for DCN401 & DCN315."

### Kernel Patches
- [Patch: bypass ODM before CRTC off](https://mail-archive.com/amd-gfx@lists.freedesktop.org/msg107870.html) — Yihan Zhu, May 2024
- [Patch: restore immediate_disable_crtc](https://www.mail-archive.com/amd-gfx@lists.freedesktop.org/msg110052.html)
- [Patch: Wait until OTG enable state cleared](https://www.mail-archive.com/amd-gfx@lists.freedesktop.org/msg126781.html)
- [Kernel module parameters reference](https://docs.kernel.org/gpu/amdgpu/module-parameters.html)
- [Kernel driver core (IP block reset architecture)](https://docs.kernel.org/gpu/amdgpu/driver-core.html)
- [DCN overview (DMCUB role, OPTC, DCHUB)](https://docs.kernel.org/gpu/amdgpu/display/dcn-overview.html)

### NVIDIA
- [NVIDIA 595.58.03 Release Notes](https://docs.nvidia.com/datacenter/tesla/tesla-release-notes-595-58-03/index.html)
- [NVIDIA 595.58.03 README: Open Kernel Modules](https://us.download.nvidia.com/XFree86/Linux-x86_64/595.58.03/README/kernel_open.html)

### Community
- [simpledrm card ordering fix (Arch)](https://bbs.archlinux.org/viewtopic.php?id=303311)
- [GNOME ring timeout — Fedora 42](https://discussion.fedoraproject.org/t/gnome-shell-crash-and-gpu-ring-timeout-on-amd-gpu-when-using-brave-browser-fedora-42/149587)
- [GNOME ring timeout — Ubuntu 25.04](https://discourse.ubuntu.com/t/amd-gpu-crashing-on-ubuntu-25-04-ring-gfx-0-0-0-timeout-and-reset-failure/62975)
- [7950X iGPU instability (Level1Techs)](https://forum.level1techs.com/t/7950xs-igpu-is-unstable-blackouts-freezes-both-on-linux-and-windows/224035)
