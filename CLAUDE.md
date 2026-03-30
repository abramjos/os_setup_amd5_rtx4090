# ML Workstation Dual-GPU Setup — Research & Implementation Playbook

## Objective

Resolve the intermittent boot crash loop on this dual-GPU ML workstation by evaluating **multiple candidate combinations** of OS, kernel, linux-firmware, NVIDIA driver, Mesa/amdgpu userspace, BIOS/AGESA, and compositor — then generate a research-backed compatibility report.

**Target deliverable**: `setup_final/COMPATIBILITY-MATRIX.md`

---

## Fixed Hardware

| Component | Fixed Value |
|-----------|-------------|
| CPU | AMD Ryzen 9 7950X (Zen 4, Raphael, Family 25 Model 0x61) |
| iGPU | AMD Radeon Graphics — RDNA2, GC 10.3.6, DCN 3.1.5, 2 CUs |
| dGPU | NVIDIA GeForce RTX 4090 (Ada Lovelace AD102, 16384 CUDA cores, 24 GB GDDR6X) |
| Motherboard | ASUS ROG Crosshair X670E Hero (X670E chipset, AM5) |
| BIOS | Currently 3603 (AGESA ComboAM5 PI 1.3.0.0a), released 2026-03-18 |
| Memory | 2x 32 GB DDR5-6000 CL30 (EXPO) |
| PSU | 1000W single-rail |

**Architecture goal**: iGPU drives ALL display/desktop. dGPU is 100% headless CUDA/ML compute. No display processes on NVIDIA whatsoever.

---

## Current Status & What Has Been Tried

### The Core Bug

The system suffers from an **intermittent crash loop** on boot:

```
[  6.1s] REG_WAIT timeout - optc31_disable_crtc    <- DCN register stall during EFI->amdgpu handoff
[  8.0s] REG_WAIT timeout - optc1_wait_for_state   <- Cascading: OTG stopped, no VBLANK arrives
[ 18.5s] ring gfx_0.0.0 timeout (gnome-shell)      <- GFX ring hangs on corrupted display state
[ 19.0s] MODE2 GPU reset                            <- Resets GFX/SDMA only -- NOT the DCN
[ 31.3s] ring gfx_0.0.0 timeout (gnome-shell #2)   <- DCN still broken -> repeat
[ 69.2s] ring gfx_0.0.0 timeout (gnome-shell #3)   <- GDM gives up -> session-failed
```

MODE2 reset does NOT reset the DCN (Display Core Next) — only GFX and SDMA. So the broken display pipeline persists through every GPU reset, causing an infinite crash loop. The triggering process is the active compositor/display server (`gnome-shell` under GDM/GNOME, `Xorg` under LightDM/XFCE). DMUB firmware version is `0x05000F00` (0.0.15.0) and re-initializes 3 times per boot during crash loop (1 initial + 2 after MODE2 resets).

### Exact Upstream Bug Match

**[freedesktop.org drm/amd #5073](https://gitlab.freedesktop.org/drm/amd/-/work_items/5073)** — "Fence fallback timer expired on Raphael iGPU"
- Same hardware pattern: Raphael/Granite Ridge iGPU, ASUS TUF X870, AGESA 1.3.0.0a, 64GB DDR5, NVIDIA dGPU present
- Same errors: optc31_disable_crtc REG_WAIT timeout + gfx ring timeouts + MODE2 resets
- Status: **OPEN** upstream as of 2026-03-28
- Upstream user tried: GFXOFF disabled, sg_display=0, ppfeaturemask, iGPU VRAM 4GB — none fully fixed it
- **Our resolution (2026-03-30):** Firmware upgrade to DMUB 0x05002000 eliminates ring timeouts; AccelMethod "none" is fallback

Related open issues: #5093, #3377, #3583, #4433 (all Raphael/Phoenix optc31/optc1 REG_WAIT timeouts).

### 20-Boot Diagnostic Data (runLog-04, 2026-03-27)

| Observation | Evidence |
|---|---|
| The bug is **intermittent** — some boots work fine with identical config | Boots -18, -4, -14 (kernel 6.8, default params) = no events |
| Kernel 6.17 HWE does NOT reliably fix it | Boots -19, -9, -6, -5 on 6.17 still show timeouts/crash-loops |
| Aggressive amdgpu parameter overrides can make things **WORSE** | Boot -10 (6.8 + all params) = 9 ring timeouts (worst run) |
| card0 = NVIDIA, card1 = AMD in EVERY boot | Module load order issue — amdgpu should be card0 |
| DMUB re-initializes 3-4 times per boot after MODE2 resets | DMUB firmware interaction is central |
| linux-firmware is `20240318.git3b128b60-0ubuntu2.25` — from **March 2024** | Missing DMCUB fixes from mid-2024+ |
| Firmware `.bin` and `.bin.zst` file conflicts exist for dcn_3_1_5_dmcub and psp_13_0_5_toc | Kernel prefers `.bin.zst` — manually placed `.bin` files may be ignored |

### Variant Testing Results (2026-03-29 through 2026-03-30)

| Run | Variant | Verdict | Key Finding |
|---|---|---|---|
| runLog-00 | Pre-variant baseline | **UNSTABLE** (5x ring timeout) | GNOME/glamor + DMUB 0x05000F00 = crash loop |
| runlog-A_v1 | A (display-only) | **STABLE** (1 optc31, 0 ring) | AccelMethod "none" eliminates ring timeouts — proves two-condition model |
| runlog-B_v1 | B (firmware fix) | **FAIL** (card ordering) | Recovery/nomodeset: simple-framebuffer claims card0 |
| runlog-B_v2 | B (firmware fix) | **PARTIAL → PASS** | Old FW: 0-4 ring timeouts; after install-firmware.sh → DMUB 0x05002000 = 0 ring timeouts |

**Two-condition crash model CONFIRMED:**
- Condition 1 (DCN stall): optc31 timeout at T+5s — present in ALL normal boots, even with new firmware
- Condition 2 (GFX ring pressure): compositor GL commands → ring timeout ONLY with old firmware
- **Variant A** removes Condition 2 (AccelMethod "none") → stable even with old firmware
- **Variant B** fixes Condition 1 cascade (DMUB 0x05002000 recovers DCN) → stable with glamor

**Autoinstall initramfs gap found:** Firmware downloaded to disk during install, but `update-initramfs` skips amdgpu blobs when driver isn't bound to hardware in chroot. Fixed by adding custom `/etc/initramfs-tools/hooks/amdgpu-firmware` hook to all 8 variants.

### BIOS Settings Confirmed

- GFXOFF: **Disabled** (confirmed by user)
- UMA Frame Buffer Size: **2 GB** (confirmed via `amdgpu_vram_mm` debugfs, 2026-03-29)
- All kernel parameters verified in running system: sg_display=0, ppfeaturemask=0xfffd7fff, dcdebugmask=0x18

---

## Root Cause Analysis (Research-Backed)

### What The Registers Tell Us

**`optc31_disable_crtc` (line ~136)** -- This function disables the BIOS-configured CRTC during amdgpu init. It disconnects OPP segments from ODM, disables OTG master, then waits for `OTG_BUSY` bit in `OTG_CLOCK_CONTROL` to clear. The wait is 1us x 100,000 = 100ms. When `OTG_BUSY` stays stuck, the timeout fires.

**Why OTG_BUSY stays stuck**: The DCN31 implementation uses `OTG_DISABLE_POINT_CNTL=2` (disable at end-of-frame), but if the display pipeline is stalled, the end-of-frame never arrives, so OTG_BUSY never clears. This is a known upstream issue -- a patch "[bypass ODM before CRTC off](https://mail-archive.com/amd-gfx@lists.freedesktop.org/msg107870.html)" was added post-6.8 to fix the ordering.

**`optc1_wait_for_state` (line ~839)** -- Waits for `OTG_V_BLANK` or `OTG_V_ACTIVE_DISP` in `OTG_STATUS`. If the OTG is already dead from the first failure, no timing signals are generated, so this always times out. This is a cascading failure, not an independent bug.

**MODE2 reset does NOT fix DCN** -- Raphael (MP1_HWIP 13.0.5) uses MODE2 reset by default. MODE2 only resets GFX and SDMA IP blocks. The DCN (Display Core Next) engine, VCN, MMHUB, and PSP are **untouched**. So a hung display pipeline persists through every GPU reset, causing the infinite crash loop.

### Root Causes (Ranked by Evidence)

#### 1. DMCUB Firmware / linux-firmware Version (CRITICAL)

**Current state:** `linux-firmware 20240318.git3b128b60-0ubuntu2.25` -- Ubuntu 24.04 stock from **March 2024**.

**DMUB firmware version:** Stock is `0x05000F00` = version **0.0.15.0** -- critically outdated. **RESOLVED (2026-03-30):** Manual firmware update via `install-firmware.sh` upgraded to `0x05002000` (0.0.32.0), which eliminated all ring timeouts on 8 consecutive boots with glamor enabled. The optc31 timeout still fires at T+5s but the new firmware recovers the DCN pipeline gracefully.

**The problem:** The DMCUB manages display state transitions including CRTC disable/enable. Documented broken firmware history:
- [Debian Bug #1057656](https://bugs-devel.debian.org/cgi-bin/bugreport.cgi?bug=1057656): broken `dcn_3_1_5_dmcub.bin` caused display failure on Raphael. Fixed in firmware-nonfree 20240709-1.
- [NixOS #418212](https://github.com/nixos/nixpkgs/issues/418212): linux-firmware update broke DMCUB loading on Raphael ("failed to load ucode DMCUB(0x3D)")
- The `REG_WAIT` macro can offload register polls to DMCUB via `dmub_reg_wait_done_pack()`. If DMCUB firmware is hung, offload fails silently, CPU-side poll times out.

**Firmware file conflicts detected:**
```
CONFLICT: dcn_3_1_5_dmcub.bin AND dcn_3_1_5_dmcub.bin.zst both exist
CONFLICT: psp_13_0_5_toc.bin AND psp_13_0_5_toc.bin.zst both exist
```
The kernel prefers `.bin.zst` when both exist -- meaning manually-placed `.bin` may be completely ignored.

#### 2. Kernel 6.8 Missing DCN31 Patches (HIGH)

See **Kernel Candidates** section below for all 6 critical patches with commit hashes.

HWE 6.17 was tested and *should* contain all patches. But it also crashed -- pointing to root cause #1 (firmware) or #3 (EFI handoff) as the actual primary.

#### 3. EFI Framebuffer to amdgpu Handoff (MEDIUM)

The optc31 timeout at 6 seconds happens during `dcn31_init_hw` -> `dcn10_init_pipes`, when the driver discovers BIOS-configured display pipes and tries to shut them down. If DMCUB state from UEFI doesn't cleanly hand off, the OTG stays busy.

See **EFI Handoff & Seamless Boot** section for detailed mitigations.

#### 4. Scatter/Gather Display (CONTRIBUTING)

When `sg_display` is enabled (default for APUs), display framebuffers are allocated from GTT via GART scatter/gather DMA. If GART/TLB state is inconsistent during EFI->amdgpu transition, HUBP can't fetch framebuffer data, causing pipeline stall.

Setting `amdgpu.sg_display=0` forces contiguous VRAM allocation -- but [freedesktop #5073](https://gitlab.freedesktop.org/drm/amd/-/work_items/5073) reports it did NOT fix the optc31 timeout for the same hardware pattern.

---

## Candidate Evaluation Framework

### 1. OS Candidates

| Candidate | Why Consider | Default Kernel | linux-firmware | NVIDIA Driver Method | CUDA | Known Raphael Issues |
|-----------|-------------|----------------|----------------|---------------------|------|---------------------|
| **Ubuntu 24.04.1 LTS** (current) | Tier 1 NVIDIA/CUDA certification, largest ML community | 6.8 | 20240318 (stale) | Official repo / apt | 13.x via apt | Stale firmware is the problem |
| **Ubuntu 24.04 + HWE** | Kernel 6.11+ backported to LTS base | 6.11-6.17 | Same stale base | Same as above | Same | **Best of both worlds if firmware updated** |
| **Ubuntu 24.10 / 25.04** | Newer kernel (6.11/6.14), newer firmware | 6.11 / 6.14 | Newer (check version) | Official repo | 13.x | Shorter support window; NVIDIA compat? |
| **Fedora 41/42** | Bleeding-edge kernel + firmware; DNF handles firmware well | 6.12+ / 6.14+ | Rolling updates | RPM Fusion or official | Via toolkit | Good firmware freshness, smaller ML community |
| **Arch Linux** | Rolling = always latest kernel/firmware/Mesa | Latest stable | Git HEAD | AUR or official | Via toolkit | Manual setup, no CUDA tier-1 certification |
| **NixOS** | Declarative config, easy rollback | Configurable | Configurable | Nix packages | Nix packages | **NixOS #418212: DMCUB loading broken on Raphael** |
| **Pop!_OS 24.04** | System76 NVIDIA integration, hybrid GPU handling | 6.8-6.11 | System76 repos | Built-in | Built-in | Good dual-GPU support out of box |

**For each candidate, evaluate:**
- Does the default kernel include the critical DCN31 patches (ODM bypass, OTG state wait, DMCUB CVEs)?
- Does the linux-firmware version include the July 2024+ DMCUB fix?
- NVIDIA driver availability and installation method
- CUDA toolkit availability and version
- Known issues with Raphael iGPU + NVIDIA dGPU dual-GPU
- Mesa version (for amdgpu userspace)
- Community size/support for ML workstation use cases

### 2. Kernel Candidates

#### DCN31 Patch Coverage

| Kernel | Commit | Patch Description | Impact | Criticality |
|--------|--------|-------------------|--------|-------------|
| **6.10+** | `a878304276b8` | **Bypass ODM before CRTC off** (Yihan Zhu) | Disconnects ODM segments BEFORE disabling OTG master. **Directly fixes optc31_disable_crtc timeout.** Available on Ubuntu HWE from 6.11. | **CRITICAL** |
| **6.12** | `9724b8494d3e` | **Restore immediate_disable_crtc workaround** | Re-adds `OTG_DISABLE_POINT_CNTL=0` (immediate disable) for DCN31. Prevents OTG_BUSY stuck. | HIGH |
| **6.13** | `faee3edfcff7` | **Wait for all pending cleared** | Adds `REG_WAIT(OTG_PENDING_CLEAR, 0)` after OTG disable. Prevents race conditions. | MEDIUM |
| **6.13** | `391cea4fff00` | **Skip disable CRTC on seamless bootup** | When `amdgpu.seamless=1`, skip CRTC disable. Avoids optc31 timeout entirely. | HIGH (if seamless=1) |
| **6.15** | `c707ea82c79d` | **Ensure DMCUB idle before reset DCN31** | Increases DMCUB halt-wait timeout from **100 to 100,000 iterations**. | **CRITICAL** |
| **6.15** | (multiple) | **DMCUB diagnostic data collection fixes** | CVE-2024-46870, CVE-2024-47662 -- fixes deterministic hangs during DMCUB error recovery. | HIGH |

#### Kernel Version Assessment

| Kernel | Patches | NVIDIA 595 Compat | Source | Status for Raphael DCN31 |
|--------|---------|-------------------|--------|--------------------------|
| **6.8** (Ubuntu 24.04 GA) | Missing ALL 6 | Yes | In-use | **Most vulnerable** to optc31 timeout |
| **6.11** (Ubuntu 24.04 HWE) | ODM bypass (critical) | Yes | HWE backport | Significant improvement |
| **6.12** | + immediate disable | Yes | Mainline PPA | Better |
| **6.13** | + seamless skip + pending clear | Yes | Mainline PPA | Best with seamless=1 |
| **6.14** (Ubuntu 25.04) | Should have all | Yes | Ubuntu 25.04 default | Good |
| **6.15** | + DMCUB idle fix | Yes | Mainline PPA | **Minimum for ALL critical fixes** |
| **6.17** (tested as HWE) | Everything above | Yes | Ubuntu HWE | **Recommended** -- but still crashed (see below) |
| **6.19** (bleeding edge) | Latest | Yes (595 claims 6.19) | Mainline PPA | Untested, risk of new regressions |

#### Why HWE 6.17 Still Crashed

1. **Firmware was still 0.0.15.0** (critically outdated) -- kernel patches can't fix a broken DMCUB firmware
2. **Firmware file conflicts** -- kernel loaded the older `.bin.zst` instead of manually-placed `.bin`
3. **Stale initramfs** -- firmware wasn't rebuilt into initramfs after manual placement
4. **Config conflicts** -- modprobe.d and GRUB parameters were inconsistent between test iterations

**The kernel patches and firmware update are complementary, not alternatives.** Both are needed.

**For each kernel, verify:**
- Contains "bypass ODM before CRTC off" patch? (commit hash, merge date)
- Contains "Wait until OTG enable state cleared"? (commit hash, merge date)
- Contains CVE-2024-46870 and CVE-2024-47662 DMCUB fixes?
- NVIDIA driver 595.58.03 compatible? (check NVIDIA's kernel compat matrix)
- Any NEW regressions for Raphael iGPU in that version?

### 3. linux-firmware Candidates

#### DMCUB Firmware History for dcn_3_1_5_dmcub.bin

Source: `linux-firmware.git` log for `amdgpu/dcn_3_1_5_dmcub.bin`

| Date | Commit | DMCUB Version | Notes |
|------|--------|---------------|-------|
| 2022-10-19 | Initial | 0.0.88.0 | First Raphael DMCUB firmware |
| 2023-01-12 | Update | 0.0.106.0 | Early fixes |
| 2023-06-02 | Update | 0.0.148.0 | **Known-bad era begins** -- display failures |
| 2024-01-24 | Update | 0.0.191.0 | Ubuntu 24.04 base (linux-firmware 20240318) |
| 2024-07-09 | `a9e3ca94f` | 0.0.224.0 | **Debian #1057656 fix** -- critical DMCUB state machine repair |
| 2024-08-02 | Update | 0.0.231.0 | Follow-up stability fixes |
| 2025-01-08 | Update | 0.0.247.0 | |
| 2025-03-05 | Update | 0.0.255.0 | Last 0.0.x series |
| 2025-06-18 | Update | 0.1.14.0 | **Known-bad for some configs** (NixOS #418212) |
| 2025-12-12 | Update | 0.1.40.0 | |
| 2026-03-10 | Latest | 0.1.53.0 | Current HEAD |

#### Version Classification

| Status | Versions | Notes |
|--------|----------|-------|
| **Known-bad** | < 0.0.224.0 | Missing critical display state machine fixes (Debian #1057656) |
| **Known-good (conservative)** | 0.0.224.0 -- 0.0.255.0 | Post-Debian-fix, pre-1.0 series, most tested on Raphael |
| **Known-good (latest stable)** | 0.0.255.0 | Last of 0.0.x series, widest community testing |
| **Caution** | 0.1.14.0 | Reported DMCUB load failures on some Raphael systems |
| **Unknown/latest** | 0.1.40.0 -- 0.1.53.0 | Latest firmware, less community testing on Raphael |

#### linux-firmware Package Candidates

| Version | Date | DMCUB Version | How to Get |
|---------|------|---------------|------------|
| `20240318` (current) | March 2024 | 0.0.191.0 (too old) | Installed |
| `20240709+` | July 2024+ | 0.0.224.0+ (post-fix) | Check Ubuntu noble-updates |
| `20250211` (noble-updates?) | Feb 2025 | Check | `apt policy linux-firmware` |
| `20250305` (git tag) | March 2025 | 0.0.255.0 | Manual install from git |
| Git HEAD | Current | 0.1.53.0 | Clone repo -- may have untested changes |

**For each, research:**
- Exact `dcn_3_1_5_dmcub.bin` firmware version hash/size
- Known regressions for Raphael
- How to install on Ubuntu 24.04 without breaking other firmware
- Whether `.bin` vs `.bin.zst` conflict causes issues (kernel preference at each version)

#### Version Encoding

DMCUB firmware versions are encoded as `0x0XYYZZWW` -> `X.YY.ZZ.WW`:
- `0x05000F00` (current system) = version **0.0.15.0** (15 = 0x0F)
- Format in dmesg: `Loading DMUB firmware via PSP: version=0x05XXXXXX`

#### PSP Firmware (psp_13_0_5)

| Blob | Current Package | Updates in git | Notes |
|------|----------------|----------------|-------|
| `psp_13_0_5_toc.bin` | From 20240318 | **Never updated** since initial commit | TOC is static |
| `psp_13_0_5_ta.bin` | From 20240318 | 17 updates | Trust Application |
| `psp_13_0_5_asd.bin` | From 20240318 | Multiple | Application Security Driver |

The TOC file conflict is cosmetic (never updated). The DMCUB conflict is the critical one.

#### Ubuntu Noble SRU (Stable Release Update) Versions

| Ubuntu Package Version | linux-firmware Base | Approx DMCUB Version |
|------------------------|--------------------|-----------------------|
| 20240318-0ubuntu2 | March 2024 | 0.0.191.0 (too old) |
| 20240318-0ubuntu2.25 | March 2024 base + patches | Unknown -- **check if DMCUB was SRU'd** |
| noble-proposed | Check `apt policy` | May have newer DMCUB |

**To check if SRU updated the DMCUB:** `zstdcat /lib/firmware/amdgpu/dcn_3_1_5_dmcub.bin.zst | xxd | head -20` and look for version bytes, OR check `dmesg | grep "DMUB firmware.*version"` after boot.

### 4. NVIDIA Driver Candidates

| Driver | CUDA | Kernel Compat | Headless Pkg | Notes |
|--------|------|---------------|-------------|-------|
| **595.58.03** (current) | 13.x | 6.8-6.19 | `nvidia-headless-595` | Latest stable; CudaNoStablePerfLimit |
| **570.x** (previous production) | 12.x | 6.8-6.14 | `nvidia-headless-570` | Battle-tested, may have fewer bugs |
| **560.x** | 12.x | 6.8-6.11 | `nvidia-headless-560` | Older; fewer kernel options |
| **550.x** | 12.x | 6.8 only? | `nvidia-headless-550` | Known compile failures on 6.11+ |

**For each, verify:**
- Headless package availability on each OS candidate
- Compatibility with each kernel candidate
- Known issues with amdgpu coexistence
- GSP firmware behavior on RTX 4090
- Any Xid error patterns specific to that version

### 5. BIOS / AGESA Candidates

| BIOS | AGESA | Date | Notes |
|------|-------|------|-------|
| **3603** (current) | 1.3.0.0a | 2026-03-18 | Latest; DDR5 stability, boot fixes |
| **3513** | Pre-1.3.0.0 | 2026-01-30 | Possible fallback if 3603 introduced issues |

**Research:**
- Are there user reports of 3603 introducing NEW iGPU issues on X670E Hero?
- Is there a newer BIOS beyond 3603?
- Does AGESA 1.3.0.0a change any iGPU/DCN behavior vs previous AGESA?
- BIOS settings that are **specific to AGESA version** (some change behavior between versions)

### 6. Compositor / Display Server Candidates

| Compositor | Display Server | GPU Backend | Why Consider |
|------------|---------------|-------------|-------------|
| **GNOME on X11** (current) | X11 | OpenGL via Mutter | Standard Ubuntu; gnome-shell is the crash trigger |
| **GNOME on Wayland** | Wayland | OpenGL via Mutter | Different rendering path; may avoid GFX ring timeout |
| **XFCE4 (xfwm4)** | X11 | XRender (no OpenGL) | **Safest** -- no 3D compositing, confirmed working on Raphael |
| **Sway** | Wayland | wlroots (minimal GL) | Lightweight Wayland; minimal GPU allocation |
| **KDE Plasma 6 (KWin)** | X11 or Wayland | OpenGL | More mature GPU error recovery than Mutter |
| **i3 + picom** | X11 | Optional GL | Tiling WM, compositor is optional |
| **No compositor (TTY + SSH)** | None | None | Nuclear option: skip desktop, SSH in for ML work |

**For each, research:**
- GPU compositing demands (how much GFX ring activity?)
- Known compatibility with Raphael RDNA2 iGPU
- Whether it triggers the optc31/ring timeout pattern
- Resource overhead (CPU, RAM, iGPU VRAM via UMA)

#### Mutter KMS Thread SIGKILL Bug

Mutter 46.x (Ubuntu 24.04 stock) creates a real-time priority KMS page-flip thread. When amdgpu takes too long on a page flip (DCN latency on Raphael), the thread exceeds its RT scheduling deadline and gets SIGKILL'd by the kernel. This crashes GDM/gnome-shell independently of the ring timeout.

**Detection:** `dmesg | grep -i "kms\|sigkill\|mutter"` or `journalctl -u gdm3`

**Workaround:**
```bash
MUTTER_DEBUG_KMS_THREAD_TYPE=user   # normal-priority thread instead of RT
# Apply system-wide:
echo 'MUTTER_DEBUG_KMS_THREAD_TYPE=user' | sudo tee /etc/environment.d/90-mutter-kms.conf
```

### 7. Mesa / amdgpu Userspace Candidates

| Mesa Version | Source | Raphael-Relevant Fixes |
|---|---|---|
| **24.0.4** (Ubuntu 24.04 stock) | distro | gfx10.3 hang fix in radeonsi |
| **24.2.0** (kisak PPA) | PPA | Improved APU scanout buffer handling |
| **25.0.0** | PPA | Cross-device scanout support (dual-GPU) |
| **25.1.0** | PPA | 780M (Raphael-class GC 10.3.6) specific fixes |
| **25.2.8** (Ubuntu HWE) | HWE stack | Ships with HWE kernel |
| **26.0.3** (kisak-mesa PPA) | PPA | **Ring timeout fix in radeonsi** -- directly addresses ring gfx timeout in compositor |

| Install Source | Mesa Version | How to Install |
|--------|-------------|----------------|
| Ubuntu stock | 24.0.4 | Default (apt) |
| Ubuntu HWE | 25.2.8 | `sudo apt install libgl1-mesa-dri:amd64` (HWE) |
| **kisak-mesa PPA** | **26.0.3** | `sudo add-apt-repository ppa:kisak/kisak-mesa && sudo apt upgrade` |

**Recommendation:** If using HWE 6.17 kernel, use the matching HWE Mesa (25.2.8). If still seeing ring timeouts after firmware+kernel fix, try kisak-mesa PPA (26.0.3) for the radeonsi ring timeout fix.

---

## Cross-Reference Compatibility Matrix

After researching all candidates, build a matrix showing valid combinations:

```
OS x Kernel x linux-firmware x NVIDIA-driver x Mesa x Compositor
```

Eliminate invalid combinations (e.g., NVIDIA 550 + kernel 6.14 = compile failure).

### Recommended Combinations (Best to Worst)

| # | Firmware (DMCUB) | Kernel | Mesa | Expected Outcome |
|---|---|---|---|---|
| **1** | **0.0.255.0** (linux-firmware ~20250305) | **6.17 HWE** | **25.2.8** (HWE) | Best: latest stable firmware + all kernel patches |
| **2** | **0.0.231.0** (linux-firmware ~20240802) | **6.17 HWE** | **25.2.8** (HWE) | Good: proven post-fix firmware + all patches |
| **3** | **0.0.224.0** (linux-firmware 20240709) | **6.17 HWE** | **25.2.8** (HWE) | Minimum fix: exact Debian fix version + all patches |
| **4** | **0.0.255.0** | **6.8 stock** | **24.0.4** (stock) | Firmware fix only -- missing kernel patches |
| **5** | **0.0.191.0** (current package) | **6.17 HWE** | **25.2.8** (HWE) | Already tested -- kernel patches alone insufficient |
| **6** | **0.0.15.0** (actually loaded) | **6.8 stock** | **24.0.4** (stock) | Current state -- intermittent crash loop |

**Each test configuration must specify:**
1. **Exact versions** of every component (OS, kernel, linux-firmware, NVIDIA driver, Mesa, compositor)
2. **Why this combination** — which root cause does it address?
3. **Risk assessment** — what could still fail and why?
4. **Installation steps** — how to get to this config
5. **Verification commands** — how to confirm each component is correctly installed
6. **Rollback plan** — how to revert if it makes things worse

---

## Open Questions (Must Be Answered by Research)

### Answered by setup_final/ Research

1. **Why did kernel 6.17 still crash?** ANSWERED: Firmware was still 0.0.15.0 (critically outdated), `.bin`/`.bin.zst` conflict meant kernel loaded old package firmware, stale initramfs, config conflicts between test iterations. See COMPATIBILITY-MATRIX.md §3.
2. **Is the DMCUB firmware fix from July 2024 actually in the linux-firmware available for Ubuntu 24.04?** ANSWERED: AMBIGUOUS. SRU 0ubuntu2.22 (Jan 2026) mentions "DMCUB firmware updates" but changelog never explicitly names `dcn_3_1_5_dmcub.bin`. Must verify on live system. See COMPATIBILITY-MATRIX.md §2.
3. **Does the `.bin.zst` preference mean the manual firmware update was completely ignored?** ANSWERED: YES. Ubuntu has `CONFIG_FW_LOADER_COMPRESS_ZSTD=y`, kernel loads `.bin.zst` first. Manual `.bin` placement was ignored. Fix: compress to `.bin.zst`, remove bare `.bin`.
4. **Is there a DMCUB firmware version newer than 0x05000F00 that fixes the handoff?** ANSWERED: YES. Current linux-firmware HEAD has 0.1.53.0. Conservative target: 0.0.255.0 (tag 20250305). Post-Debian-fix minimum: 0.0.224.0.
5. **Would a completely different compositor (XFCE, Sway) avoid the bug entirely?** ANSWERED: LIKELY YES. XFCE with compositing OFF uses XRender (zero GFX ring submissions). The crash requires BOTH DCN stall AND compositor GFX ring pressure. Remove either and the loop breaks.
7. **Does `video=efifb:off` change the handoff behavior?** ANSWERED: MOOT. Ubuntu 24.04 uses simpledrm, not efifb. The correct parameter is `initcall_blacklist=simpledrm_platform_driver_init`. See COMPATIBILITY-MATRIX.md §4.
8. **Is there a kernel boot parameter that forces a full DCN reset?** ANSWERED: `amdgpu.reset_method=1` (MODE0) was intended to reset ALL IP blocks including DCN/DCHUB. However, **testing on Raphael APU confirmed MODE0 is NOT SUPPORTED** — kernel 6.17 rejects it: "Specified reset method:1 isn't supported, using AUTO instead." AUTO defaults to MODE2 (GFX/SDMA only).

### Still Open (Verify on Live System)

6. **Is the card0=NVIDIA, card1=AMD ordering a contributing factor?** amdgpu should be card0 for display. `initcall_blacklist=simpledrm_platform_driver_init` is the fix (confirmed on Arch forums). Verify with `/sys/class/drm/card*/device/driver`.
9. **Would Ubuntu 24.04 with ONLY the linux-firmware updated (no kernel change) fix this?** Isolate firmware vs kernel as the variable.
10. **Are there any ASUS X670E Hero-specific BIOS interactions with the iGPU that differ from other X670E boards?** The upstream bug is on ASUS TUF X870 — same vendor, different board.

---

## Technical Deep-Dives

### EFI Handoff & Seamless Boot

Ubuntu 24.04 uses **simpledrm** (not efifb) for the early boot framebuffer. simpledrm is built into the kernel (not a module) and cannot be blacklisted via modprobe.

When amdgpu loads, it must take over from simpledrm. The `dcn31_init_hw` function discovers BIOS/EFI-configured display pipes and either:
1. **Tears them down** (default) -- calls `optc31_disable_crtc` on each active pipe -> THIS IS WHERE THE TIMEOUT HAPPENS
2. **Adopts them** (seamless mode) -- keeps the BIOS-configured pipe running and transitions ownership

#### amdgpu.seamless Parameter

```
amdgpu.seamless=1   -> Force seamless boot (skip pipe teardown during init)
amdgpu.seamless=0   -> Force full pipe teardown during init
amdgpu.seamless=-1  -> Auto (default): enabled if DCN >= 3.0.0 AND APU = true
```

**On Raphael (DCN 3.1.5 + APU), seamless defaults to AUTO = ENABLED.** If it's still hitting the optc31 timeout, either:
- Seamless path has a bug on DCN 3.1.5 specifically
- DMCUB state from EFI doesn't meet seamless adoption requirements
- Kernel 6.13 patch `391cea4fff00` is needed for seamless to actually work

#### DMCUB optimized_init_done Flag

DMCUB firmware sets `optimized_init_done` after BIOS golden initialization. If DMCUB firmware is too old/buggy, this flag may be incorrectly set, causing driver to skip necessary init.

**Check:** `grep "optimized_init_done" /var/log/syslog`

#### Preventing Firmware FB Device Creation

```bash
# Preferred: Prevent simpledrm from stealing card0 (surgical, targets simpledrm only)
initcall_blacklist=simpledrm_platform_driver_init

# Nuclear fallback: Prevent ALL firmware framebuffers (simpledrm, efifb, vesafb)
# initcall_blacklist=sysfb_init
```

### Complete Parameter Reference

#### GRUB Kernel Command Line Parameters

| Parameter | Default | Recommended | Effect on Display Handoff |
|---|---|---|---|
| `amdgpu.sg_display=0` | 1 (APU) | **0** | Forces contiguous VRAM for display FB, bypasses GART scatter/gather |
| `amdgpu.dcdebugmask=0x10` | 0 | **0x10** | Disables PSR -- reduces DCN complexity |
| `amdgpu.dcdebugmask=0x08` | 0 | Test | Disables DCN clock gating -- keeps OPTC registers accessible |
| `amdgpu.dcdebugmask=0x18` | 0 | Test | Combines 0x10 (PSR off) + 0x08 (clock gating off) |
| `amdgpu.seamless=1` | auto | **CAUTION** | Forces seamless boot -- skips pipe teardown. **Crashed with DMCUB 0.0.15.0** (5 ring timeouts in runLog-00). Only re-test after firmware update to >= 0.0.224.0. |
| `amdgpu.seamless=0` | auto | **Recommended (pre-firmware-fix)** | Forces full pipe teardown -- stable boots (boot-13/14) used this value |
| `amdgpu.ppfeaturemask=0xfffd7fff` | varies | **0xfffd7fff** | Disables GFXOFF via feature mask (bit 15) |
| `amdgpu.dpm=0` | 1 | Last resort | Disables DPM entirely -- max stability |
| `amdgpu.lockup_timeout=30000` | 10000 | Test | 30s ring timeout -- prevents reset during slow DMCUB init |
| `amdgpu.gpu_recovery=1` | 1 | **1** | Enables GPU reset on hang (default) |
| `amdgpu.reset_method=1` | -1 (auto, defaults to MODE2 on Raphael) | ~~1~~ **NOT SUPPORTED** | MODE0 was intended to reset ALL IP blocks including DCN/DCHUB, but kernel 6.17 rejects it on Raphael APU: "Specified reset method:1 isn't supported, using AUTO instead." |
| `amdgpu.vm_fragment_size=9` | varies | **9** | 2MB page table fragments -- reduces TLB pressure |
| `nvidia-drm.modeset=1` | 0 | **1** | Enables NVIDIA kernel modesetting |
| `nvidia-drm.fbdev=1` | 0 | **1** | Enables NVIDIA DRM framebuffer device |
| `pcie_aspm=off` | on | **off** | Prevents Xid 79 link loss on RTX 4090 |
| `iommu=pt` | off | **pt** | IOMMU passthrough for GPU compute |
| `processor.max_cstate=1` | varies | **1** | Prevents deep idle causing link drops |
| `amd_pstate=active` | passive | **active** | AMD P-State EPP driver |
| `modprobe.blacklist=nouveau,nova_core` | none | **nouveau,nova_core** | Prevents open-source NVIDIA drivers (nouveau + nova_core) |
| `nogpumanager` | n/a | **set** | Disables Ubuntu's gpu-manager |
| `initcall_blacklist=simpledrm_platform_driver_init` | n/a | **set** | Prevents simpledrm from stealing card0 -- amdgpu gets card0 for display. Black screen until amdgpu loads (acceptable for workstation). |
| `initcall_blacklist=sysfb_init` | n/a | Nuclear fallback | Prevents ALL firmware framebuffers (simpledrm, efifb, vesafb) -- more aggressive than simpledrm-only |

#### dcdebugmask Bitmask Reference

| Bit | Hex | Effect |
|---|---|---|
| 0 | 0x01 | Disable pipe split (single pipe mode) |
| 1 | 0x02 | Disable DCC (Delta Color Compression) |
| 2 | 0x04 | Disable stutter (display self-refresh) |
| 3 | 0x08 | **Disable DCN clock gating** -- keeps OPTC registers powered |
| 4 | 0x10 | **Disable PSR** (Panel Self Refresh) |
| 5 | 0x20 | Force full reprogramming on modeset |

#### modprobe.d Parameters

| Parameter | Value | Purpose |
|---|---|---|
| `options amdgpu sg_display=0` | 0 | Redundant with GRUB (belt-and-suspenders) |
| `options amdgpu ppfeaturemask=0xfffd7fff` | 0xfffd7fff | Feature control (GFXOFF bit) |
| `options amdgpu gpu_recovery=1` | 1 | Enable GPU reset |
| ~~`options amdgpu reset_method=1`~~ | ~~1~~ | **REMOVED: MODE0 NOT SUPPORTED on Raphael APU.** Kernel 6.17 rejects it. AUTO (MODE2) is used instead. |
| `options amdgpu dc=1` | 1 | Enable Display Core (required for Raphael) |
| `options amdgpu audio=1` | 1 | Enable HDMI/DP audio |

### Firmware Installation Methods

**Option A: Ubuntu package update** (simplest)
```bash
sudo apt update
apt policy linux-firmware
sudo apt install --only-upgrade linux-firmware
```

**Option B: Manual firmware from git** (precise version control)
```bash
cd /tmp
git clone --depth 1 https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git
# Or for a specific tag:
git clone --depth 1 --branch 20250305 https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git

sudo cp linux-firmware/amdgpu/dcn_3_1_5_dmcub.bin /lib/firmware/amdgpu/
sudo cp linux-firmware/amdgpu/psp_13_0_5_toc.bin /lib/firmware/amdgpu/
sudo cp linux-firmware/amdgpu/psp_13_0_5_ta.bin /lib/firmware/amdgpu/
sudo cp linux-firmware/amdgpu/psp_13_0_5_asd.bin /lib/firmware/amdgpu/
sudo cp linux-firmware/amdgpu/gc_10_3_6_*.bin /lib/firmware/amdgpu/

# CRITICAL: Compress to .bin.zst and remove bare .bin
# Ubuntu 24.04 has CONFIG_FW_LOADER_COMPRESS_ZSTD=y — kernel loads .bin.zst FIRST.
# If both .bin and .bin.zst exist, the .bin is IGNORED.
for f in dcn_3_1_5_dmcub psp_13_0_5_toc psp_13_0_5_ta psp_13_0_5_asd; do
  sudo zstd -f /lib/firmware/amdgpu/${f}.bin -o /lib/firmware/amdgpu/${f}.bin.zst
  sudo rm -f /lib/firmware/amdgpu/${f}.bin
done
for f in /lib/firmware/amdgpu/gc_10_3_6_*.bin; do
  [ -f "$f" ] && sudo zstd -f "$f" -o "${f}.zst" && sudo rm -f "$f"
done

sudo update-initramfs -u -k all
```

**Option C: Ubuntu noble-proposed** (beta SRU)
```bash
sudo add-apt-repository --enable-source "deb http://archive.ubuntu.com/ubuntu noble-proposed main restricted"
sudo apt update
apt policy linux-firmware
sudo apt install linux-firmware
sudo add-apt-repository --remove "deb http://archive.ubuntu.com/ubuntu noble-proposed main restricted"
```

---

## Playbook — Priority-Ordered Actions

### Philosophy

The upstream bug (#5073) is open with no driver-level fix. Our strategy is:
1. **Maximize firmware version** to get DMCUB state machine fixes (0.0.224.0+)
2. **Maximize kernel version** (6.17 HWE) for all DCN31 patches
3. **Eliminate config conflicts** (stale initramfs, firmware file conflicts, modprobe/GRUB inconsistency)
4. **Apply defense-in-depth** kernel params (sg_display=0, dcdebugmask, Mutter workaround)
5. **Have a fallback** compositor if GNOME remains unstable

### Action 1: Update linux-firmware (HIGHEST PRIORITY)

Current firmware is version 0.0.15.0 -- predating all known fixes. Target: DMCUB >= 0.0.224.0.

```bash
dpkg -l linux-firmware
sudo apt update
sudo apt install --only-upgrade linux-firmware

# If Ubuntu doesn't have new enough -- manual from git (see Firmware Installation Methods)
```

### Action 2: Resolve Firmware File Conflicts

```bash
dmesg | grep "Loading DMUB firmware"
ls -la /lib/firmware/amdgpu/dcn_3_1_5_dmcub.bin*
ls -la /lib/firmware/amdgpu/psp_13_0_5_toc.bin*

# Ubuntu has CONFIG_FW_LOADER_COMPRESS_ZSTD=y — kernel loads .bin.zst FIRST.
# Resolution: compress new .bin to .bin.zst, remove bare .bin.
for f in /lib/firmware/amdgpu/dcn_3_1_5_dmcub /lib/firmware/amdgpu/psp_13_0_5_toc; do
    if [ -f "${f}.bin" ] && [ -f "${f}.bin.zst" ]; then
        echo "CONFLICT: ${f} -- compressing .bin to .bin.zst, removing bare .bin"
        sudo zstd -f "${f}.bin" -o "${f}.bin.zst"
        sudo rm -f "${f}.bin"
    fi
done
sudo update-initramfs -u -k all
```

### Action 3: Clean GRUB + modprobe.d Configuration

Reset to clean, consistent config. No stale test artifacts.

```bash
# GRUB
sudo sed -i 's|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT="quiet splash amdgpu.sg_display=0 amdgpu.dcdebugmask=0x10 amdgpu.ppfeaturemask=0xfffd7fff amdgpu.gpu_recovery=1 amdgpu.seamless=0 amdgpu.lockup_timeout=30000 amdgpu.vm_fragment_size=9 nvidia-drm.modeset=1 nvidia-drm.fbdev=1 pcie_aspm=off iommu=pt nogpumanager processor.max_cstate=1 amd_pstate=active modprobe.blacklist=nouveau,nova_core initcall_blacklist=simpledrm_platform_driver_init"|' /etc/default/grub
sudo update-grub

# modprobe.d/amdgpu.conf
sudo tee /etc/modprobe.d/amdgpu.conf << 'EOF'
options amdgpu sg_display=0
options amdgpu ppfeaturemask=0xfffd7fff
options amdgpu dcdebugmask=0x10
options amdgpu gpu_recovery=1
options amdgpu lockup_timeout=30000
options amdgpu dc=1
options amdgpu audio=1
# REMOVED: reset_method=1 — MODE0/BACO NOT SUPPORTED on Raphael APU.
# Kernel 6.17: "Specified reset method:1 isn't supported, using AUTO instead."
EOF

# modprobe.d/nvidia.conf
sudo tee /etc/modprobe.d/nvidia.conf << 'EOF'
blacklist nouveau
options nouveau modeset=0
options nvidia NVreg_RegisterPCIDriverOnEarlyBoot=1
options nvidia NVreg_UsePageAttributeTable=1
options nvidia NVreg_InitializeSystemMemoryAllocations=0
options nvidia NVreg_DynamicPowerManagement=0x02
options nvidia NVreg_EnableGpuFirmware=1
options nvidia NVreg_PreserveVideoMemoryAllocations=1
options nvidia NVreg_TemporaryFilePath=/var/tmp
options nvidia_drm modeset=1
options nvidia_drm fbdev=1
options nvidia NVreg_RegistryDwords="RmGpuComputeExecTimeout=0"
EOF

# blacklist-nouveau.conf
sudo tee /etc/modprobe.d/blacklist-nouveau.conf << 'EOF'
blacklist nouveau
blacklist lbm-nouveau
alias nouveau off
alias lbm-nouveau off
EOF

# initramfs module order -- amdgpu MUST be first
sudo tee /etc/initramfs-tools/modules << 'EOF'
amdgpu
nvidia
nvidia_uvm
nvidia_modeset
nvidia_drm
EOF

# modules-load.d
sudo tee /etc/modules-load.d/gpu.conf << 'EOF'
amdgpu
nvidia
nvidia_uvm
nvidia_modeset
nvidia_drm
EOF

# Mutter KMS thread workaround
echo 'MUTTER_DEBUG_KMS_THREAD_TYPE=user' | sudo tee /etc/environment.d/90-mutter-kms.conf

# REBUILD initramfs
sudo update-initramfs -u -k all
```

### Action 4: Verify UMA Frame Buffer Size in BIOS

Enter BIOS -> Advanced -> NB Configuration -> UMA Frame Buffer Size.
- If **Auto** or **512M**: Change to **2G** (or **4G** for testing)
- 512M causes page faults during compositing -> gfx ring timeouts
- Ref: [drm/amd #3006](https://gitlab.freedesktop.org/drm/amd/-/issues/3006)

### Action 5: Boot Kernel 6.17 HWE (After Firmware Fix)

```bash
sudo apt install linux-generic-hwe-24.04
dpkg -l | grep linux-image | grep hwe
# Boot into 6.17: hold Shift at GRUB -> Advanced options -> pick 6.17 kernel
```

### Action 6: If Still Failing -- Test Parameters

Try in order, one at a time, rebooting between each:

```bash
# Test A: Force seamless boot
amdgpu.seamless=1

# Test B: Disable DCN clock gating
amdgpu.dcdebugmask=0x18

# Test C: Increase lockup timeout
amdgpu.lockup_timeout=30000

# Test D: Prevent simpledrm from stealing card0 (black screen until amdgpu loads)
initcall_blacklist=simpledrm_platform_driver_init

# Test E: Force 1080p
video=HDMI-A-1:1920x1080@60
```

### Action 7: If Still Failing -- Test Lighter Compositor

```bash
# XFCE (no OpenGL compositing, uses XRender)
sudo apt install xfce4 xfce4-goodies
# Log out -> select "XFCE Session" at GDM
# If XFCE works -> problem is GNOME/Mutter OpenGL path

# Sway (lightweight Wayland)
sudo apt install sway
# Log out -> select "Sway" at GDM
```

### Action 8: Nuclear Options (Last Resort)

```bash
# A: Mesa PPA (ring timeout fix in radeonsi)
sudo add-apt-repository ppa:kisak/kisak-mesa && sudo apt update && sudo apt upgrade

# B: Disable DPM entirely
amdgpu.dpm=0

# C: Software rendering test
LIBGL_ALWAYS_SOFTWARE=1 gnome-shell --replace &

# D: Disable hardware cursors
echo 'MUTTER_DEBUG_DISABLE_HW_CURSORS=1' | sudo tee -a /etc/environment
```

---

## BIOS Configuration (Quick Reference)

### TIER 1 -- MUST SET

| Setting | Path | Value |
|---------|------|-------|
| Integrated Graphics | Advanced > NB Configuration | **Force** |
| IGFX Multi-Monitor | Advanced > NB Configuration | **Enabled** |
| Primary Video Device | Advanced > NB Configuration | **IGFX Video** |
| UMA Frame Buffer Size | Advanced > NB Configuration (or Advanced > AMD CBS > NBIO > GFX Configuration) | **2G** (or **4G** for testing) |
| GFXOFF | Advanced > AMD CBS > NBIO > SMU Common Options | **Disabled** (confirmed) |
| Above 4G Decoding | Advanced > PCI Subsystem Settings | **Enabled** |
| Re-Size BAR | Advanced > PCI Subsystem Settings | **Enabled** |
| SMEE (SME) | Advanced > AMD CBS > CPU Common Options | **Disabled** |
| TSME | Advanced > AMD CBS > UMC > DDR Security | **Disabled** |
| IOMMU | Advanced > AMD CBS (root level) | **Enabled** |
| CSM | Boot > CSM Configuration | **Disabled** |
| OS Type | Boot > Secure Boot > OS Type | **Other OS** |

### TIER 2 -- STABILITY

| Setting | Path | Value |
|---------|------|-------|
| PCIEX16_1 Link Mode | Advanced | **Gen 4** |
| Native ASPM | Advanced > Onboard Devices Configuration | **Enabled** |
| CPU PCIE ASPM Mode | Advanced > Onboard Devices Configuration | **Disabled** |
| Global C-State Control | Advanced > AMD CBS (root level) | **Disabled** |
| Power Supply Idle Control | Advanced > AMD CBS > CPU Common Options | **Typical Current Idle** |
| D3Cold Support | Advanced > AMD PBS > Graphics Features | **Disabled** |
| fTPM | Advanced > AMD fTPM Configuration | **Disabled** |
| Fast Boot | Boot > Boot Configuration | **Disabled** |
| Clock Spread Spectrum | Extreme Tweaker | **Disabled** |
| ErP Ready | Advanced > APM Configuration | **Disabled** |
| Restore AC Power Loss | Advanced > APM Configuration | **Power On** |

### TIER 3 -- ML PERFORMANCE

| Setting | Path | Value |
|---------|------|-------|
| EXPO Profile | Extreme Tweaker > AI Overclock Tuner | **EXPO II** |
| FCLK | Advanced > AMD Overclocking | **2000 MHz** |
| Core Performance Boost | Extreme Tweaker | **Enabled** |
| SVM (AMD-V) | Advanced > CPU Configuration | **Enabled** |
| SR-IOV | Advanced > PCI Subsystem Settings | **Enabled** |
| ACPI SRAT L3 NUMA | Advanced > AMD CBS > DF Common Options | **Disabled** |

---

## Post-Fix Verification Checklist

```bash
# 1. linux-firmware version (should be >= 20240709, ideally >= 20250305)
dpkg -l linux-firmware

# 2. DMUB firmware loaded successfully
dmesg | grep "DMUB"
# Expected: "Loading DMUB firmware via PSP: version=0x0500FF00" (or higher)
# Should appear only ONCE (not 3-4 times = reset loop)

# 3. No firmware file conflicts
ls -la /lib/firmware/amdgpu/dcn_3_1_5_dmcub.bin*
ls -la /lib/firmware/amdgpu/psp_13_0_5_toc.bin*

# 4. No optc31/optc1 REG_WAIT timeouts
dmesg | grep -i "REG_WAIT timeout"

# 5. No ring timeouts
dmesg | grep -i "ring.*timeout"

# 6. No GPU resets
dmesg | grep -i "GPU reset"

# 7. Card assignment (AMD MUST be card0)
for card in /sys/class/drm/card[0-9]; do
    vendor=$(cat "$card/device/vendor" 2>/dev/null)
    driver=$(basename $(readlink "$card/device/driver") 2>/dev/null)
    echo "$(basename $card): vendor=$vendor driver=$driver"
done

# 8. Display on AMD
glxinfo | grep "OpenGL renderer"
# Expected: AMD Radeon Graphics (raphael, LLVM ...)

# 9. sg_display disabled
cat /sys/module/amdgpu/parameters/sg_display
# Expected: 0

# 10. NVIDIA headless
nvidia-smi --query-gpu=name,display_active,display_mode --format=csv
# Expected: NVIDIA GeForce RTX 4090, Disabled, Disabled

# 11. Mutter KMS thread type
cat /proc/$(pgrep -f gnome-shell)/environ 2>/dev/null | tr '\0' '\n' | grep MUTTER
# Expected: MUTTER_DEBUG_KMS_THREAD_TYPE=user

# 12. Kernel version
uname -r
# Expected: 6.17.x-generic (HWE)
```

---

## Diagnostic Collection

```bash
# Quick check
dmesg | grep -i -E 'REG_WAIT|ring.*timeout|GPU reset|DMUB|optc' | tail -20

# Full diagnostic (run from setup/scripts_v3/)
sudo bash diagnostic-full.sh
# Creates runLog-XX/ with 13 subdirectories
```

---

## Documentation Gaps & Inconsistencies

Review ALL existing documentation and flag:
- Settings mentioned in one doc but not another
- BIOS paths that differ between docs (e.g., GFXOFF path varies across files)
- Kernel parameters that appear in GRUB but not modprobe.d (or vice versa)
- Scripts that set values different from what the docs recommend
- Firmware versions that don't match what the logs show
- Any assumptions that aren't backed by evidence

**Known inconsistencies identified so far:**
- `sg_display` removed during Test A/B but still referenced in docs as recommended
- `ppfeaturemask` value reads `0xfff7bfff` at runtime but `0xfffd7fff` is documented
- Firmware `.bin` files manually placed but `.bin.zst` files from package are what kernel loads
- modprobe.d and GRUB cmdline had conflicting parameter sets from test iterations
- BIOS GFXOFF path varies: some docs say `AMD CBS > NBIO > SMU Common Options`, others differ

---

## Research Methodology

Prioritize these sources in order:

1. **Upstream bug trackers**: `gitlab.freedesktop.org/drm/amd/`, `github.com/NVIDIA/open-gpu-kernel-modules/`
2. **Kernel mailing lists**: `amd-gfx@lists.freedesktop.org`, `dri-devel@lists.freedesktop.org`
3. **Distro bug trackers**: Launchpad (Ubuntu), Bugzilla (Fedora), GitHub (NixOS, Arch)
4. **linux-firmware git**: `git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git`
5. **NVIDIA forums**: `forums.developer.nvidia.com`
6. **Reddit**: `r/linuxhardware`, `r/VFIO`, `r/archlinux`, `r/pop_os`
7. **Arch Wiki**: `wiki.archlinux.org` (AMDGPU, NVIDIA, Dual GPU)
8. **ASUS ROG forum**: For X670E Hero-specific BIOS issues

When citing research, include: source URL, date of information, confirmed/unconfirmed status, and relevance to THIS specific hardware combination.

---

## Source Material to Cross-Reference

### Documentation (in `setup/`)
- `ryzen-rtx4090-research-report.md` — AM5+RTX4090 stability catalog, BIOS settings, display config
- `DUAL-GPU-SETUP-COMPLETE-GUIDE.md` — 21+ issue catalog, solution matrix, step-by-step setup
- `BIOS-SETTINGS-COMPLETE-GUIDE.md` — 14-phase BIOS configuration, scripts_v3 gap analysis
- `OPTIMAL-ML-WORKSTATION-SPEC.md` — Full hardware + software spec with exact versions
- `spec.md` — Hardware platform reference
- `README.md` — Setup overview

### Scripts (in `setup/scripts_v3/`)
- `00-verify-bios-prerequisites.sh` — BIOS verification checks
- `01-first-boot-display-fix.sh` — GRUB + modprobe + HWE kernel setup
- `02-install-nvidia-driver.sh` — NVIDIA 595 + CUDA installation
- `03-configure-display.sh` — X11 + udev + services configuration
- `apply-test-a.sh` / `apply-test-b-1080p.sh` — Test parameter variants (historical)
- `diagnostic-full.sh` — Comprehensive 13-section diagnostic collector
- `05-multiboot-amdgpu-diag.sh` — Multi-boot comparison tool
- `06-recovery-fix.sh` — Recovery procedures
- All rollback scripts (`01-rollback.sh`, `02-rollback.sh`, etc.)

### Logs (in `logs/`)
- `runLog-04/` — Latest 20-boot diagnostic (March 27, 2026)
  - `ANALYSIS.txt`, `COMPARISON.txt`, `META.txt`, `comparison.csv`
  - `04-firmware/` — Firmware versions, conflicts, initramfs contents
  - `13-multiboot/boot-*/SUMMARY.txt` — Per-boot summaries
- `runLog-00` through `runLog-03` — Earlier diagnostic runs
- `ml-diag-*` — Single-boot diagnostics

### Research Deliverables (in `setup_final/`)
- `RESEARCH-PROMPT.md` — Full research requirements specification
- `COMPATIBILITY-MATRIX.md` — Target deliverable: comprehensive compatibility report
- `INSTALLATION-PROMPT.md` — Installation procedure prompt

---

## Key Upstream References

- **[drm/amd #5073](https://gitlab.freedesktop.org/drm/amd/-/work_items/5073)** -- EXACT match: Raphael iGPU optc31 timeout + ring timeout + MODE2 reset loop (OPEN)
- **[drm/amd #3377](https://gitlab.freedesktop.org/drm/amd/-/work_items/3377)** -- Raphael optc1_wait_for_state black screen (OPEN)
- **[drm/amd #3583](https://gitlab.freedesktop.org/drm/amd/-/work_items/3583)** -- Ryzen 9 9950X, optc31_disable_crtc + DMCUB error
- **[drm/amd #4433](https://gitlab.freedesktop.org/drm/amd/-/work_items/4433)** -- Ryzen 5 8600G, optc314_disable_crtc REG_WAIT timeout
- **[drm/amd #3006](https://gitlab.freedesktop.org/drm/amd/-/issues/3006)** -- UMA 512M causes gfx ring timeouts
- **[Debian #1057656](https://bugs-devel.debian.org/cgi-bin/bugreport.cgi?bug=1057656)** -- DMCUB firmware breaks Raphael display (FIXED in firmware 20240709)
- **[NixOS #418212](https://github.com/nixos/nixpkgs/issues/418212)** -- DMCUB 0.1.14.0 load failure on Raphael
- **[Kernel commit a878304276b8](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=a878304276b8)** -- bypass ODM before CRTC off (fixes optc31 timeout)
- **[Kernel commit c707ea82c79d](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=c707ea82c79d)** -- Ensure DMCUB idle before reset (100->100k iterations)
- **[Kernel commit 391cea4fff00](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=391cea4fff00)** -- Skip disable CRTC on seamless bootup
- **[Patch: Wait until OTG enable state cleared](https://www.mail-archive.com/amd-gfx@lists.freedesktop.org/msg126781.html)** -- Fixes OTG disable/enable race

---

## File Map

```
setup/
  spec.md, OPTIMAL-ML-WORKSTATION-SPEC.md    # Hardware + full software config
  BIOS-SETTINGS-COMPLETE-GUIDE.md             # 14-phase BIOS guide
  DUAL-GPU-SETUP-COMPLETE-GUIDE.md            # 21+ issue catalog
  ryzen-rtx4090-research-report.md            # AM5+RTX4090 stability research
  scripts_v3/
    00-verify-bios-prerequisites.sh           # Pre-flight
    01-first-boot-display-fix.sh              # GRUB + modprobe + HWE kernel
    02-install-nvidia-driver.sh               # NVIDIA 595 + CUDA
    03-configure-display.sh                   # X11 + udev + services
    apply-test-a.sh / apply-test-b-1080p.sh   # Test variants (historical)
    diagnostic-full.sh                        # Comprehensive log collector
setup_final/
  RESEARCH-PROMPT.md                          # Full research requirements
  COMPATIBILITY-MATRIX.md                     # Comprehensive compatibility report
  INSTALLATION-PROMPT.md                      # Installation procedure prompt
logs/
  runLog-04/                                  # Latest 20-boot diagnostic
  ml-diag-20260327-*/                         # Single-boot diagnostics
  run2-run5/                                  # Older runs
```
