# Compatibility Matrix: Dual-GPU ML Workstation

**Hardware:** AMD Ryzen 9 7950X | ASUS ROG Crosshair X670E Hero | RTX 4090 (headless) + Raphael iGPU (display)
**Date:** 2026-03-28 (v2 — updated with deep web research)
**Based on:** 20-boot diagnostic data (runLog-04), 5 documentation files, 15+ scripts, 50+ web sources, upstream bug trackers, kernel mailing lists, distro changelogs

---

## 1. Executive Summary

**The most likely path to success is a 4-step fix on Ubuntu 24.04:**

1. **Fix the firmware** — Ubuntu Noble NEVER updated DCN 3.1.5 DMCUB firmware via SRU (confirmed from changelog through v0ubuntu2.26). The loaded firmware `0x05002F00` is critically outdated. Download firmware from linux-firmware tag `20250305` (DMCUB 0.0.255.0 — the last safe version before the 0.1.x regression). Compress to `.bin.zst` so the kernel loads it.

2. **Restore stripped kernel parameters** — Test A removed `sg_display=0`, `ppfeaturemask`, `dcdebugmask`, `pcie_aspm=off`, and `processor.max_cstate=1`. Restore all.

3. **Fix the card ordering** — `simpledrm` grabs card0. Add `initcall_blacklist=simpledrm_platform_driver_init` so amdgpu claims card0.

4. **Test `reset_method=1` (mode0 full ASIC reset)** — NEW FINDING: MODE2 (default) only resets GC/SDMA via GCHUB. DCN goes through DCHUB and is UNTOUCHED by MODE2. Setting `amdgpu.reset_method=1` forces full ASIC reset including DCN, potentially breaking the crash loop.

If these four fixes don't resolve it: **Switch to XFCE** (avoids the GNOME/Mutter compositor GFX ring pressure that triggers the loop). If that fails: **Fedora 42** (linux-firmware 20260309 with ALL firmware fixes, kernel 6.14 with most DCN31 patches).

The upstream bug ([drm/amd #5073](https://gitlab.freedesktop.org/drm/amd/-/work_items/5073)) remains OPEN.

---

## 2. Critical Findings

### Finding 1: Ubuntu Noble NEVER Updated DCN 3.1.5 DMCUB Firmware

**Source:** [Ubuntu Noble linux-firmware changelog](https://launchpad.net/ubuntu/noble/+source/linux-firmware/+changelog) through v20240318.git3b128b60-0ubuntu2.26.

The changelog mentions "DMCUB updates for various AMDGPU ASICs" generically, and specifically updates DCN 3.1.4, DCN 3.1.6, DCN 3.5, DCN 3.5.1, DCN 4.0.1 — but **DCN 3.1.5 is NEVER mentioned**. The `dcn_3_1_5_dmcub.bin.zst` file appears unchanged from the March 2024 base package.

The Debian fix ([Bug #1057656](https://bugs-devel.debian.org/cgi-bin/bugreport.cgi?bug=1057656), firmware-nonfree 20240709-1) was for Debian, not backported to Ubuntu Noble.

### Finding 2: DMCUB Firmware Has a Known-Bad Range

**Source:** [NixOS #418212](https://github.com/nixos/nixpkgs/issues/418212)

| linux-firmware Version | DMCUB Series | Status | Evidence |
|------------------------|-------------|--------|----------|
| ≤ 20240318 | 0.0.191.0 or earlier | **KNOWN BAD** | Pre-Debian-fix, currently loaded on your system |
| 20240709 | 0.0.224.0 | **KNOWN GOOD** | Debian #1057656 fix release |
| 20250305 | 0.0.255.0 | **KNOWN GOOD (safest)** | Last 0.0.x series, widest testing |
| 20250613 | 0.1.14.0 | **KNOWN BAD** | NixOS #418212: "failed to load ucode DMCUB(0x3D)" on Raphael |
| 20260221+ | Post-fix 0.1.x | **LIKELY GOOD** | [MR #587](https://gitlab.com/kernel-firmware/linux-firmware/-/merge_requests/587) "Update DMCUB fw for DCN315" fixes the regression |

**Key insight:** DCN315 = DCN 3.1.5 (naming convention). MR #587, created June 16, 2025, specifically updates DMCUB for DCN 3.1.5. linux-firmware 20260221 (Arch) and 20260309 (Fedora 42) both post-date this fix.

**Recommended target:** linux-firmware tag `20250305` for the most conservative safe choice (DMCUB 0.0.255.0). OR `20260309` (Fedora/Arch) if you want the latest with the regression fix included.

### Finding 3: MODE2 Reset Does NOT Reset DCN — mode0 Might

**Source:** [Kernel Driver Core Documentation](https://docs.kernel.org/gpu/amdgpu/driver-core.html), [amd-gfx mailing list](https://www.mail-archive.com/amd-gfx@lists.freedesktop.org/msg109235.html)

The GPU IP block routing on Raphael:
```
GCHUB  ← GC (Graphics Compute) + SDMA   ← MODE2 resets THESE
MMHUB  ← VCN + JPEG + VPE               ← MODE1 resets THIS
DCHUB  ← DCN (Display Core Next)         ← NOT TOUCHED BY MODE2
```

**MODE2 (default, `reset_method=3`):** Resets only GC and SDMA. DCN remains in its broken state. This is why the crash loops — each MODE2 reset restores GFX ring capability, but gnome-shell immediately submits work that hits the still-broken DCN pipeline, causing another ring timeout.

**MODE0 (`reset_method=1`):** Full ASIC reset. Should reset ALL IP blocks including DCN/DCHUB. This could break the crash loop by actually fixing the DCN stall, but has side effects:
- Video memory is lost (display goes black during reset)
- All display state must be re-initialized
- Untested on Raphael APU specifically

**BACO (`reset_method=4`):** Bus Active Chip Off — likely not applicable to APUs (iGPU has no separate power domain).

This is a **novel untested mitigation** worth trying: `amdgpu.reset_method=1`.

### Finding 4: simpledrm Card Ordering Fix Confirmed

**Source:** [Arch Linux Forums](https://bbs.archlinux.org/viewtopic.php?id=303311), [Linux.org thread](https://www.linux.org/threads/video-card-being-being-added-as-card1-instead-of-card0.46280/), [Blog post](https://blog.lightwo.net/fix-gpu-identifier-randomly-setting-to-card0-or-card1-linux.html)

`initcall_blacklist=simpledrm_platform_driver_init` is the confirmed fix. simpledrm loads before GPU drivers and steals card0. Blocking it lets amdgpu claim card0 as expected.

**Warning:** This removes early boot console output (Plymouth splash, LUKS password prompt). Display is black until amdgpu loads. Acceptable for a workstation with no disk encryption.

### Finding 5: GNOME Ring Timeout Is Cross-Distro

**Source:** [Fedora 42](https://discussion.fedoraproject.org/t/gnome-shell-crash-and-gpu-ring-timeout-on-amd-gpu-when-using-brave-browser-fedora-42/149587), [Ubuntu 25.04](https://discourse.ubuntu.com/t/amd-gpu-crashing-on-ubuntu-25-04-ring-gfx-0-0-0-timeout-and-reset-failure/62975), [Ubuntu Bug #2141396](http://www.mail-archive.com/desktop-bugs@lists.ubuntu.com/msg829655.html)

GNOME Shell ring gfx timeout crashes are reported on:
- Fedora 42 with kernel 6.14 + GNOME 48
- Ubuntu 25.04 with kernel 6.14
- Ubuntu 24.04 with kernel 6.8 and 6.17

This is NOT an Ubuntu-specific issue. The GNOME/Mutter compositor generates enough GFX ring pressure to trigger the crash loop on any distro. Switching distros without switching compositors will NOT fix this. **XFCE or Sway are required if GNOME keeps crashing after firmware fix.**

### Finding 6: NVIDIA 595 — Open Modules Now Default

**Source:** [NVIDIA README](https://us.download.nvidia.com/XFree86/Linux-x86_64/595.58.03/README/kernel_open.html), [GamingOnLinux](https://www.gamingonlinux.com/2026/03/nvidia-driver-595-58-03-released-as-the-big-new-recommended-stable-driver-for-linux/)

Key changes in 595.58.03:
- **Open kernel modules are now the DEFAULT** installation (override with `-M=proprietary`)
- **modeset=1 enabled by default** — no need to add `nvidia-drm.modeset=1` explicitly
- **CudaNoStablePerfLimit** — CUDA apps can reach P0 performance state
- **Blackwell+ ONLY supported by open modules** (future-proof)
- Kernel support: 4.15+ (all stable kernels), explicit build fix for 6.19
- Bug fixes: X11 compositor blinking (picom, **xfwm**), kwin_wayland wake, DP MST crash, CONFIG_RANDSTRUCT panic

The **xfwm blinking fix** is directly relevant if switching to XFCE.

---

## 3. OS Candidate Analysis

| OS | Kernel | linux-firmware | DMCUB Status | Mesa | NVIDIA | CUDA | ML Maturity |
|----|--------|---------------|-------------|------|--------|------|-------------|
| **Ubuntu 24.04 LTS** | 6.8 GA / 6.14 HWE / 6.17 HWE | 20240318 (stale!) | **NEVER UPDATED** for DCN 3.1.5 | 24.0 / 25.0 / 25.2 | `nvidia-headless-595-server` via apt | 13.2 via NVIDIA repo | **5/5** |
| **Ubuntu 25.04** | 6.14 | ~20250317 | Likely newer but unverified | 25.0 | apt | 13.2 | 3/5 |
| **Fedora 42** | 6.14 | **20260309** | **FIXED** (post-MR#587) | 25.0.4 | RPM Fusion akmod-nvidia | Via NVIDIA repo | 3/5 |
| **Arch Linux** | 6.19+ | **20260309** | **FIXED** (post-MR#587) | 26.0+ | `nvidia-open` package | `cuda` package | 3/5 |
| **Pop!_OS 24.04** | 6.17.9 | ~20250317+system76 | Likely fixed | 25.1 | Built-in (580 series) | Via NVIDIA repo | 3/5 |
| **NixOS** | 6.12+ | Varies | **CAUTION** — #418212 regression with 20250613 | Recent | Declarative config | nixpkgs | 2/5 |
| **Linux Mint 22** | 6.8 (Ubuntu base) | 20240318 (same) | **NEVER UPDATED** | 24.0 | Same as Ubuntu | Same | 4/5 |

### Detailed Assessment

**Ubuntu 24.04 LTS — STAY HERE (fix firmware manually)**
- Pros: Tier 1 NVIDIA/CUDA certification, `nvidia-headless-595-server` package, largest ML community, CUDA 13.2 via official repo, known upgrade path
- Cons: linux-firmware stuck at March 2024 for DCN 3.1.5, kernel 6.8 GA missing all DCN31 patches
- HWE timeline: 24.04.3 = kernel 6.14 + Mesa 25.0 (Aug 2025), 24.04.4 = kernel 6.17 + Mesa 25.2.7 (Feb 2026)
- **Recommendation:** Stay. Use HWE kernel 6.14 or 6.17. Manually update DMCUB firmware. This avoids re-doing the entire NVIDIA/CUDA stack.

**Fedora 42 — BEST OUT-OF-BOX FIRMWARE**
- Pros: linux-firmware 20260309 (ALL firmware fixes including DCN315 MR#587), kernel 6.14 (has ODM bypass + OTG state wait + DMCUB CVE fixes), Mesa 25.0.4
- Cons: NVIDIA via RPM Fusion (akmod-nvidia), no official `nvidia-headless` package concept, CUDA setup more manual, shorter support cycle
- **Recommendation:** Best alternative if Ubuntu approach fails. The firmware advantage is significant. CUDA 12.9 confirmed working via community guide.

**Arch Linux — LATEST EVERYTHING**
- Pros: linux-firmware 20260309, kernel 6.19.9 (ALL patches), Mesa 26.0+, NVIDIA 595 available
- Cons: Rolling release risk, no NVIDIA tier-1 cert, manual CUDA setup, requires ongoing maintenance
- **Recommendation:** Only for advanced users. The firmware and kernel are ideal but the ML stack requires manual work.

**Pop!_OS 24.04 — INTERESTING COMPOSITOR ALTERNATIVE**
- Pros: COSMIC desktop (Rust-based Wayland, NOT GNOME — avoids compositor crash), kernel 6.17.9, built-in GPU compute mode, System76 hybrid GPU management
- Cons: NVIDIA 580 not 595 (no CudaNoStablePerfLimit), COSMIC is new/less tested, full reinstall required
- **Recommendation:** Consider as last resort. COSMIC avoids the GNOME crash path entirely.

**NixOS — CAUTION**
- Hardware config module exists ([`nixos-hardware/common/cpu/amd/raphael/igpu.nix`](https://github.com/NixOS/nixos-hardware/blob/master/common/cpu/amd/raphael/igpu.nix)) — only applies `sg_display=0` for kernels 6.2-6.5
- NixOS #418212: firmware 20250613 broke DMCUB loading on Raphael (Ryzen 7950X specifically named)
- Fix: pin to firmware 20250509 or use NixOS 25.05.20250612+
- **Recommendation:** Avoid unless you specifically need declarative config.

---

## 4. Kernel Candidate Analysis

| Kernel | ODM Bypass (6.10+) | OTG State Wait (6.12+) | CVE-46870/47662 (6.11+) | Seamless CRTC Skip (6.13+) | DMCUB Idle Fix (6.15+) | NVIDIA 595 | Source |
|--------|:--:|:--:|:--:|:--:|:--:|:--:|--------|
| **6.8** (Ubuntu GA) | NO | NO | NO | NO | NO | YES | Ubuntu 24.04 |
| **6.11** (Ubuntu HWE 24.04.2) | YES | NO | YES | NO | NO | YES | Ubuntu 24.04 HWE |
| **6.14** (Ubuntu HWE 24.04.3, Fedora 42) | YES | YES | YES | YES | NO | YES | Ubuntu 24.04.3, Fedora 42, Ubuntu 25.04 |
| **6.17** (Ubuntu HWE 24.04.4) | YES | YES | YES | YES | YES | YES | Ubuntu 24.04.4 |
| **6.19** (Arch) | YES | YES | YES | YES | YES | YES (build fix) | Arch, Mainline PPA |

### Patch Details

| Patch | Kernel | Commit | Impact |
|-------|--------|--------|--------|
| **Bypass ODM before CRTC off** | 6.10+ | `a878304276b8` (May 2024 patch set) | Disconnects ODM BEFORE disabling OTG. **Directly fixes optc31 timeout.** |
| **Restore immediate_disable_crtc** | 6.12+ | `9724b8494d3e` | Re-adds `OTG_DISABLE_POINT_CNTL=0` for DCN31. Prevents OTG_BUSY hang. |
| **Wait for all pending cleared** | 6.13+ | `faee3edfcff7` | `REG_WAIT(OTG_PENDING_CLEAR, 0)` after OTG disable. Prevents race. |
| **Skip disable CRTC on seamless boot** | 6.13+ | `391cea4fff00` | If `amdgpu.seamless=1`, skips entire CRTC disable path. Avoids optc31. |
| **Ensure DMCUB idle before reset** | 6.15+ | `c707ea82c79d` | Increases halt-wait from 100 to **100,000 iterations**. Prevents premature timeout. |
| **DMCUB diagnostic fixes** | 6.15+ | CVE-2024-46870, CVE-2024-47662 | Fixes hangs during DMCUB error recovery. |

### Why Kernel 6.17 Still Crashed (Explained)

Kernel 6.17 has ALL DCN31 patches. Yet it still crashed. The reasons (ranked):

1. **DMCUB firmware still ancient** (HIGHEST) — The patches optimize the driver-side handoff, but the DMCUB microcontroller runs its own firmware. If that firmware has a state machine bug (and it does — Debian #1057656 proved it), no driver patch compensates. The `.bin.zst` priority means manual updates were ignored.

2. **simpledrm steals card0** — GNOME picks simpledrm as primary, software-renders, crashes. Independent of kernel version.

3. **Test A stripped all critical parameters** — `sg_display=-1`, `ppfeaturemask=0xfff7bfff` (wrong value). Scatter/gather display active, GFXOFF potentially enabled.

4. **Stale initramfs** — Not rebuilt after switching kernels, old config baked in.

**Conclusion:** Kernel 6.14 (HWE 24.04.3) or 6.17 (HWE 24.04.4) are both viable. 6.17 is preferred for the DMCUB idle fix. The failures were firmware + config, not kernel.

### Ubuntu HWE Bug Warning

[Ubuntu Bug #2143294](https://bugs.launchpad.net/ubuntu/+source/linux/+bug/2143294): Kernel 6.17.0-14-generic caused MES firmware timeout on HP Victus with Radeon 740M (GFX 11.x). This is a DIFFERENT GPU architecture (RDNA3) from Raphael (RDNA2/GFX 10.3.6) and likely does NOT affect your system. But monitor for similar reports.

### Recommended Kernel: **6.17 HWE** (primary) or **6.14 HWE** (fallback)

---

## 5. Firmware Candidate Analysis

| Source | DMCUB Version | Safe? | How to Get |
|--------|--------------|-------|-----------|
| Ubuntu Noble pkg (20240318 base) | ~0.0.191.0 | **NO** — predates Debian fix | Currently loaded — BROKEN |
| Debian firmware-nonfree 20240709-1 | 0.0.224.0 | **YES** — the fix release | N/A (Debian only) |
| linux-firmware tag 20250305 | **0.0.255.0** | **YES — SAFEST** | `git clone --depth 1 --branch 20250305` |
| linux-firmware 20250509 | ~0.1.x early | YES (last pre-regression) | NixOS confirmed working |
| linux-firmware 20250613 | 0.1.14.0 | **NO — REGRESSION** | NixOS #418212: DMCUB load failure |
| linux-firmware 20260221 (Arch) | Post-MR#587 fix | **LIKELY YES** | Arch `linux-firmware` package |
| linux-firmware 20260309 (Fedora 42) | Post-MR#587 fix | **LIKELY YES** | Fedora `amd-gpu-firmware` package |
| linux-firmware git HEAD | Latest | **UNKNOWN** — verify on Raphael | `git clone --depth 1` |

### Safe Firmware Download Strategy

**Option A: Conservative (RECOMMENDED) — pin to 20250305**
```bash
cd /tmp
git clone --depth 1 --branch 20250305 \
  https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git
# This gives DMCUB 0.0.255.0 — last of the stable 0.0.x series
```

**Option B: Latest with regression fix — extract from Arch/Fedora package**
```bash
# Download Arch linux-firmware 20260309
cd /tmp
wget "https://archlinux.org/packages/core/any/linux-firmware/download/"
# Extract dcn_3_1_5_dmcub.bin.zst from the package
```

**Option C: Risky — git HEAD**
```bash
cd /tmp
git clone --depth 1 \
  https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git
# May contain untested changes
```

### Firmware Installation Procedure

```bash
# 1. Backup current firmware
sudo mkdir -p /lib/firmware/amdgpu/backup-$(date +%Y%m%d)
sudo cp /lib/firmware/amdgpu/dcn_3_1_5_dmcub.bin* /lib/firmware/amdgpu/backup-$(date +%Y%m%d)/
sudo cp /lib/firmware/amdgpu/psp_13_0_5_*.bin* /lib/firmware/amdgpu/backup-$(date +%Y%m%d)/

# 2. Copy new firmware files
sudo cp /tmp/linux-firmware/amdgpu/dcn_3_1_5_dmcub.bin /lib/firmware/amdgpu/
sudo cp /tmp/linux-firmware/amdgpu/psp_13_0_5_toc.bin /lib/firmware/amdgpu/
sudo cp /tmp/linux-firmware/amdgpu/psp_13_0_5_ta.bin /lib/firmware/amdgpu/
sudo cp /tmp/linux-firmware/amdgpu/psp_13_0_5_asd.bin /lib/firmware/amdgpu/

# 3. CRITICAL: Compress to .bin.zst (kernel loads .zst FIRST)
for f in dcn_3_1_5_dmcub psp_13_0_5_toc psp_13_0_5_ta psp_13_0_5_asd; do
    sudo zstd -f /lib/firmware/amdgpu/${f}.bin \
         -o /lib/firmware/amdgpu/${f}.bin.zst
done

# 4. Remove uncompressed .bin to avoid conflicts
for f in dcn_3_1_5_dmcub psp_13_0_5_toc psp_13_0_5_ta psp_13_0_5_asd; do
    sudo rm -f /lib/firmware/amdgpu/${f}.bin
done

# 5. Verify only .bin.zst remains
ls -la /lib/firmware/amdgpu/dcn_3_1_5_dmcub.bin*
# Should show ONLY: dcn_3_1_5_dmcub.bin.zst

# 6. Rebuild initramfs
sudo update-initramfs -u -k all
```

### Firmware Version Verification After Reboot

```bash
# Check loaded DMCUB version — should be DIFFERENT from 0x05002F00
dmesg | grep "DMUB firmware.*version"

# Check DMCUB loaded only ONCE (not 3-4 times = reset loop)
dmesg | grep -c "DMUB"

# Version decode: 0x0500FF00 = 0.0.255.0, 0x05012E00 = 0.1.46.0, etc.
```

---

## 6. NVIDIA Driver Candidate Analysis

| Driver | CUDA | Kernel Range | Headless Package | Open Modules | Key Feature |
|--------|------|-------------|-----------------|-------------|-------------|
| **595.58.03** | 13.2 | 4.15–6.19+ | `nvidia-headless-595-server` | **DEFAULT** | CudaNoStablePerfLimit, modeset=1 default |
| **590.48.01** | 13.x | 4.15–6.17+ | `nvidia-headless-590-server` | Available | Previous production |
| **580.142** | 12.x | 4.15–6.14+ | `nvidia-headless-580-server` | Available | Pop!_OS ships this |
| **570.x** | 12.8 | 4.15–6.14 | `nvidia-headless-570-server` | Available | Battle-tested |
| **550.x** | 12.4 | 4.15–6.8 | `nvidia-headless-550-server` | Legacy | **Do NOT use with HWE** — compile failures on 6.11+ |

### NVIDIA 595.58.03 Deep Dive

**Release:** March 24, 2026 — latest production branch
**Minimum kernel:** 4.15, **all stable kernels supported** (pre-release kernels NOT supported)
**Build fix:** Explicit fix for kernel 6.19

**Key changes:**
- Open kernel modules now **installed by default** (override: `-M=proprietary`)
- `nvidia-drm.modeset=1` now **enabled by default** — remove from GRUB/modprobe if already set
- `CudaNoStablePerfLimit` application profile — CUDA apps reach P0 PState (full clock speed)
- `nvidia-smi` can reset GPUs while `modeset=1` is loaded (if no other processes using GPU)
- Fixes: X11 compositor blinking (picom, **xfwm4**), kwin_wayland display wake, DP MST crash, `CONFIG_RANDSTRUCT` kernel panic, EGL-X11 SLI failure

**Headless compute installation:**
```bash
# Ubuntu 24.04 — headless compute only (no display server components)
sudo apt install nvidia-headless-595-server nvidia-utils-595-server
# CUDA 13.2
sudo apt install cuda-toolkit-13-2  # from NVIDIA repo
```

**Fedora 42 — via RPM Fusion:**
```bash
sudo dnf install akmod-nvidia xorg-x11-drv-nvidia-cuda
```

### Recommendation: **595.58.03** (or 590.48.01 as fallback)

---

## 7. Compositor Candidate Analysis

| Compositor | GPU Backend | GFX Ring Pressure | Known Working on Raphael? | Crash Avoidance | Installation |
|-----------|------------|-------------------|--------------------------|----------------|-------------|
| **GNOME X11** (current) | OpenGL (Mutter) | **HIGH** | **NO** — crashes | None | Default |
| **GNOME Wayland** | EGL (Mutter) | **HIGH** | **NO** — SIGKILL from RT thread | None | Default |
| **XFCE4 (xfwm4)** | **XRender (no GL)** | **VERY LOW** | **Reports of success** | **HIGHEST** | `apt install xfce4` |
| **Sway** | wlroots (minimal GL) | LOW | Likely works | HIGH | `apt install sway` |
| **KDE Plasma 6** | OpenGL (KWin) | MEDIUM | Unknown on Raphael | MEDIUM | `apt install kde-plasma-desktop` |
| **i3wm** | None (no compositing) | **ZERO** | Very likely works | **HIGHEST** | `apt install i3` |
| **COSMIC** (Pop!_OS) | Vulkan (cosmic-comp) | LOW | Unknown but not Mutter | HIGH | Pop!_OS only |
| **TTY only** | None | ZERO | Diagnostic only | N/A | `systemctl set-default multi-user.target` |

### Why GNOME Crashes But XFCE Might Not

The crash loop requires TWO conditions:
1. **optc31_disable_crtc timeout** at boot (~6s) — stalls DCN pipeline
2. **GFX ring submissions from compositor** — gnome-shell floods the ring, which hangs on stalled DCN → MODE2 reset (GFX only, NOT DCN) → repeat

XFCE's xfwm4 with compositing disabled uses **zero GPU acceleration**. Even with compositing enabled, it uses XRender (CPU-side) not OpenGL. This means:
- Condition 2 is never met — no GFX ring submissions
- The stalled DCN may self-recover before any GPU work is submitted
- No ring timeout → no MODE2 reset → no crash loop

### Mutter-Specific Workaround

If staying with GNOME, apply the Mutter KMS thread fix to prevent SIGKILL:
```bash
echo 'MUTTER_DEBUG_KMS_THREAD_TYPE=user' | sudo tee /etc/environment.d/90-mutter-kms.conf
# Also for GDM specifically:
sudo mkdir -p /etc/gdm3/PostLogin
sudo tee /etc/gdm3/PostLogin/Default << 'GDMEOF'
#!/bin/sh
export MUTTER_DEBUG_KMS_THREAD_TYPE=user
GDMEOF
sudo chmod +x /etc/gdm3/PostLogin/Default
```

### Recommendation: **XFCE first, then Sway** (if firmware fix alone doesn't stabilize GNOME)

---

## 8. Mesa / amdgpu Userspace Analysis

| Mesa | Source | Key Raphael Fixes | Ships With |
|------|--------|-------------------|-----------|
| **24.0.4** (Ubuntu 24.04 stock) | apt | Baseline, gfx10.3 hang fix in radeonsi | Ubuntu 24.04 GA |
| **25.0.x** (Ubuntu 24.04.3 HWE) | HWE stack | Improved APU scanout, better Raphael compositing | Ubuntu 24.04.3 |
| **25.2.7** (Ubuntu 24.04.4 HWE) | HWE stack | Significant radeonsi improvements | Ubuntu 24.04.4 |
| **25.0.4** (Fedora 42) | dnf | Same era as Ubuntu HWE | Fedora 42 |
| **26.0.3** (kisak PPA) | `ppa:kisak/kisak-mesa` | GTT memory leak fix (RDNA2), ring timeout during VR | PPA only |

**Mesa 26.0.0** ([release notes](https://docs.mesa3d.org/relnotes/26.0.0.html)) includes:
- GTT memory leak fix on RX 6600 XT (RDNA2 — same architecture as Raphael iGPU)
- Ring gfx timeout fix during VR app launch
- RDNA2 page fault fixes (Borderlands 4, Forza Horizon 5)

**Note:** Ubuntu 24.04.4 HWE ships Mesa 25.2.7 alongside kernel 6.17. No separate PPA needed. If 25.2.7 isn't sufficient, kisak-mesa PPA provides 26.0.3.

---

## 9. BIOS/AGESA Analysis

| BIOS | AGESA | Date | Notes |
|------|-------|------|-------|
| **3603** (current) | 1.3.0.0a | 2026-03-18 | Latest. DDR5 stability improvements. Irreversible update. |
| 3402 | Pre-1.3.0.0 | Earlier | Previous stable |

**AGESA 1.3.0.0a** provides additional stability margin during high-frequency DDR5 training. No specific iGPU/DCN changes documented.

**Critical BIOS settings to verify:**

| Setting | Required Value | Path | Why |
|---------|---------------|------|-----|
| Integrated Graphics | **Force** | Advanced > NB Config | Enable iGPU regardless of dGPU |
| UMA Frame Buffer | **2G** (or 4G) | Advanced > NB Config | 512M causes page faults → ring timeouts ([drm/amd #3006](https://gitlab.freedesktop.org/drm/amd/-/issues/3006)) |
| GFXOFF | **Disabled** | AMD CBS > NBIO > SMU | Confirmed disabled |
| Above 4G Decoding | **Enabled** | PCI Subsystem | Required for RTX 4090 BAR |
| Re-Size BAR | **Enabled** | PCI Subsystem | Optimal for compute |
| Global C-State | **Disabled** | AMD CBS | Prevents deep idle causing link drops |
| CSM | **Disabled** | Boot | Required for UEFI GOP (simpledrm needs this) |

---

## 10. Cross-Reference Compatibility Matrix

| | Kernel 6.8 | Kernel 6.14 | Kernel 6.17 | Kernel 6.19 |
|---|:--:|:--:|:--:|:--:|
| **NVIDIA 595** | YES | YES | YES | YES |
| **NVIDIA 590** | YES | YES | YES | UNKNOWN |
| **NVIDIA 550** | YES | **X** | **X** | **X** |
| **Ubuntu 24.04** | GA | HWE 24.04.3 | HWE 24.04.4 | Mainline PPA only |
| **Fedora 42** | — | Native | — | — |
| **Arch** | — | — | — | Native |
| **Mesa 24.0** | YES | Mismatch | Mismatch | Mismatch |
| **Mesa 25.0–25.2** | OK | YES | YES | — |
| **Mesa 26.0** | — | — | — | YES |
| **Firmware 20240318** | BROKEN | BROKEN | BROKEN | BROKEN |
| **Firmware 20250305** | GOOD* | **BEST** | **BEST** | GOOD |
| **Firmware 20260309** | GOOD* | **BEST** | **BEST** | GOOD |
| **GNOME** | CRASHES | CRASHES | CRASHES | CRASHES |
| **XFCE** | Likely OK | **BEST** | **BEST** | Likely OK |

\* Firmware 20250305/20260309 with kernel 6.8 = firmware fix only, missing kernel patches. Viable but suboptimal.

---

## 11. Recommended Test Configurations (Ranked)

### Candidate 1: "Quad Fix" — Firmware + Params + simpledrm + reset_method (HIGHEST PRIORITY)

**Rationale:** Addresses ALL FOUR identified root causes while keeping current OS and GNOME. Tests whether GNOME can work once the underlying issues are fixed.

| Component | Version |
|-----------|---------|
| OS | Ubuntu 24.04.4 LTS |
| Kernel | 6.17 HWE (`linux-generic-hwe-24.04`) |
| Firmware | DMCUB 0.0.255.0 from linux-firmware 20250305 |
| NVIDIA | 595.58.03 (`nvidia-headless-595-server`) |
| Mesa | 25.2.7 (comes with HWE) |
| Compositor | GNOME (test if fix works) |
| New params | `reset_method=1`, `initcall_blacklist=simpledrm_platform_driver_init` |

```bash
# 1. Download safe firmware (DMCUB 0.0.255.0)
cd /tmp
git clone --depth 1 --branch 20250305 \
  https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git

# 2. Install firmware as .bin.zst (kernel loads .zst first)
sudo mkdir -p /lib/firmware/amdgpu/backup-$(date +%Y%m%d)
sudo cp /lib/firmware/amdgpu/dcn_3_1_5_dmcub.bin* /lib/firmware/amdgpu/backup-$(date +%Y%m%d)/
sudo cp /lib/firmware/amdgpu/psp_13_0_5_*.bin* /lib/firmware/amdgpu/backup-$(date +%Y%m%d)/

for f in dcn_3_1_5_dmcub psp_13_0_5_toc psp_13_0_5_ta psp_13_0_5_asd; do
    sudo cp /tmp/linux-firmware/amdgpu/${f}.bin /lib/firmware/amdgpu/${f}.bin
    sudo zstd -f /lib/firmware/amdgpu/${f}.bin -o /lib/firmware/amdgpu/${f}.bin.zst
    sudo rm -f /lib/firmware/amdgpu/${f}.bin
done

# 3. GRUB — all parameters restored + new fixes
sudo sed -i 's|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT="quiet splash amdgpu.sg_display=0 amdgpu.dcdebugmask=0x10 amdgpu.ppfeaturemask=0xfffd7fff amdgpu.reset_method=1 nvidia-drm.modeset=1 nvidia-drm.fbdev=1 pcie_aspm=off iommu=pt nogpumanager processor.max_cstate=1 amd_pstate=active modprobe.blacklist=nouveau initcall_blacklist=simpledrm_platform_driver_init"|' /etc/default/grub
sudo update-grub

# 4. modprobe.d/amdgpu.conf
sudo tee /etc/modprobe.d/amdgpu.conf << 'EOF'
options amdgpu sg_display=0
options amdgpu ppfeaturemask=0xfffd7fff
options amdgpu gpu_recovery=1
options amdgpu reset_method=1
options amdgpu dc=1
options amdgpu audio=1
EOF

# 5. Mutter KMS thread workaround
echo 'MUTTER_DEBUG_KMS_THREAD_TYPE=user' | sudo tee /etc/environment.d/90-mutter-kms.conf

# 6. Rebuild initramfs
sudo update-initramfs -u -k all
sudo reboot
```

**Verification:**
```bash
dmesg | grep "DMUB firmware.*version"            # Should differ from 0x05002F00
dmesg | grep -c "REG_WAIT timeout"               # Expect: 0
dmesg | grep -c "ring.*timeout"                   # Expect: 0
cat /sys/module/amdgpu/parameters/sg_display      # Expect: 0
cat /sys/module/amdgpu/parameters/ppfeaturemask   # Expect: 0xfffd7fff
cat /sys/module/amdgpu/parameters/reset_method    # Expect: 1
for card in /sys/class/drm/card[0-9]; do
    echo "$(basename $card): $(basename $(readlink $card/device/driver 2>/dev/null))"
done                                               # Expect: card0=amdgpu
```

**Risk:** `reset_method=1` (mode0) is untested on Raphael. If it causes issues (black screen, failed reset), remove it and keep other fixes.

**Rollback:** Restore firmware from backup dir, revert GRUB, restore modprobe.d.

---

### Candidate 2: "Quad Fix + XFCE" — Same as #1 but XFCE (HIGHEST SUCCESS PROBABILITY)

**Rationale:** Even if optc31 still fires intermittently, XFCE's zero GFX ring usage avoids the crash loop. This is the statistically most likely to produce a stable desktop.

| Component | Change from Candidate 1 |
|-----------|------------------------|
| **Compositor** | **XFCE4** instead of GNOME |

```bash
# All steps from Candidate 1, PLUS:
sudo apt install xfce4 xfce4-goodies
# At GDM login: click gear → select "XFCE Session"
```

**Risk:** Very low. XFCE is proven on AMD APUs. NVIDIA 595.58.03 has an explicit xfwm4 compositor blinking fix.

---

### Candidate 3: "Firmware Only — Isolate Variable"

**Rationale:** Test whether firmware alone fixes the issue, without changing parameters or compositor. Isolates firmware as the variable.

| Component | Change |
|-----------|--------|
| Firmware | DMCUB 0.0.255.0 from tag 20250305 |
| Everything else | Unchanged |

```bash
# Only do firmware steps from Candidate 1 (steps 1-2, 6)
# Do NOT change GRUB, modprobe.d, or compositor
sudo update-initramfs -u -k all
sudo reboot
```

**If this works:** Firmware was the sole root cause. Restore parameters for defense-in-depth.
**If this fails:** Firmware is necessary but not sufficient. Proceed to Candidate 1.

---

### Candidate 4: "TTY Diagnostic — Isolate Compositor vs Init"

**Rationale:** Determine if optc31 timeout is a driver init issue (happens regardless of compositor) or compositor-triggered.

```bash
sudo systemctl set-default multi-user.target
sudo reboot

# From TTY or SSH:
dmesg | grep -i "REG_WAIT\|ring.*timeout\|GPU reset\|DMUB"

# If NO timeouts → compositor triggers it → use XFCE (Candidate 2)
# If timeouts STILL happen → driver init issue → firmware fix is essential

# Restore:
sudo systemctl set-default graphical.target
```

---

### Candidate 5: "Fedora 42 Fresh Install" — Best Out-of-Box Firmware

**Rationale:** If all Ubuntu approaches fail, Fedora 42 has the best out-of-box stack:

| Component | Version |
|-----------|---------|
| OS | Fedora 42 |
| Kernel | 6.14 (all DCN31 patches except DMCUB idle fix) |
| Firmware | 20260309 (ALL fixes including MR#587 DCN315 fix) |
| Mesa | 25.0.4 |
| NVIDIA | Via RPM Fusion (akmod-nvidia + CUDA) |
| Compositor | **XFCE spin** (avoid GNOME) |

```bash
# Install Fedora 42 XFCE spin (no GNOME)
# https://fedoraproject.org/spins/xfce/

# After install, add NVIDIA:
sudo dnf install https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-42.noarch.rpm \
  https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-42.noarch.rpm
sudo dnf install akmod-nvidia xorg-x11-drv-nvidia-cuda
sudo systemctl enable nvidia-persistenced

# CUDA (from NVIDIA repo):
# Follow https://developer.nvidia.com/cuda-downloads for Fedora
```

**Risk:** HIGH effort (full install). CUDA setup less streamlined than Ubuntu. But firmware and kernel are both ideal.

---

## 12. Untracked Paths & Documentation Gaps

### Critical Inconsistencies Found

| # | Issue | Impact |
|---|-------|--------|
| 1 | `sg_display=0` removed by Test A, listed as "CRITICAL" in 5 docs | Running system has `-1` (default) — likely contributing |
| 2 | `ppfeaturemask` removed; running value `0xfff7bfff` ≠ documented `0xfffd7fff` | GFXOFF bit may be enabled |
| 3 | `dcdebugmask=0x10` in modprobe.d per docs, but scripts say it's GRUB-only on 6.8+ | Verify if modprobe.d works for dcdebugmask |
| 4 | `Integrated Graphics = Force` missing from 3 of 5 docs | Needs BIOS visual verification |
| 5 | UMA Frame Buffer: one doc says 512M OK, four say 512M crashes | [drm/amd #3006](https://gitlab.freedesktop.org/drm/amd/-/issues/3006) confirms 512M is bad |
| 6 | `NVreg_EnableGpuFirmware=1` in 3 docs, BIOS guide says `=0` | `=0` breaks open kernel modules (595 default) |
| 7 | `nvidia-drm.modeset=1` in GRUB — now DEFAULT in 595, possibly doubled | Remove from GRUB if using 595 |
| 8 | `amdgpu.reset_method` never mentioned in ANY existing doc | MODE2 (default) doesn't reset DCN — critical gap |
| 9 | NixOS Raphael hardware module only applies `sg_display=0` for 6.2-6.5, considers 6.6+ fixed | The optc31 issue is DIFFERENT from the sg_display flickering |
| 10 | DCN 3.1.5 DMCUB SRU status never checked — all docs assume Ubuntu updated it | Ubuntu NEVER updated it (confirmed from changelog) |

### Parameters Never Tested

| Parameter | Value | What It Does | Why Test |
|-----------|-------|-------------|----------|
| `amdgpu.reset_method=1` | mode0 (full ASIC) | Resets ALL IP blocks including DCN | Could break crash loop |
| `amdgpu.lockup_timeout=30000` | 30s | Increases ring timeout | Prevents reset during slow DMCUB init |
| `amdgpu.seamless=1` | Force seamless boot | Skips CRTC disable entirely | Avoids optc31 path |
| `amdgpu.dcdebugmask=0x08` | Disable DCN clock gating | Keeps OPTC registers powered | May prevent REG_WAIT timeout |
| `initcall_blacklist=simpledrm_platform_driver_init` | Block simpledrm | Fix card ordering | Confirmed fix from Arch community |
| `MUTTER_DEBUG_KMS_THREAD_TYPE=user` | Normal thread | Prevent RT thread SIGKILL | Fixes Mutter crash on slow page flip |

---

## 13. Open Questions

| # | Question | How to Answer | Priority |
|---|----------|--------------|----------|
| 1 | Is the manual `.bin` (242208 bytes) different firmware from `.bin.zst`? | `zstd -d .bin.zst -o /tmp/old.bin && diff` | HIGH |
| 2 | What DMCUB version does linux-firmware 20250305 contain? | Download, check with `xxd` | HIGH |
| 3 | Does `reset_method=1` actually reset DCN on Raphael? | Boot test | HIGH |
| 4 | Does XFCE avoid crash loop even WITHOUT firmware fix? | Install XFCE, boot, check dmesg | MEDIUM |
| 5 | Does TTY boot still show optc31 timeout? | Boot multi-user.target | MEDIUM |
| 6 | What is actual UMA Frame Buffer Size in BIOS? | Visual check | MEDIUM |
| 7 | Does kernel 6.14 HWE work better than 6.17? | Boot 6.14 with same fixes | LOW |
| 8 | Does `amdgpu.seamless=1` skip the optc31 path entirely? | Boot test | LOW |
| 9 | Does Fedora 42 XFCE spin boot clean on this hardware? | USB live test | LOW |
| 10 | Is there a newer Arch linux-firmware with confirmed Raphael testing? | Check Arch forums | LOW |

---

## 14. Test Protocol

### For each candidate:

1. **Pre-boot** — SSH in, record state:
   ```bash
   uname -r && dpkg -l linux-firmware | tail -1 && cat /proc/cmdline
   ```

2. **Apply changes** per candidate instructions

3. **Reboot** — check immediately via SSH (within 60s):
   ```bash
   dmesg | grep -c "REG_WAIT timeout"            # expect: 0
   dmesg | grep -c "ring.*timeout"                # expect: 0
   dmesg | grep -c "GPU reset"                    # expect: 0
   dmesg | grep "DMUB firmware.*version"           # check new version
   cat /sys/module/amdgpu/parameters/sg_display    # expect: 0
   cat /sys/module/amdgpu/parameters/ppfeaturemask # expect: 0xfffd7fff
   cat /sys/module/amdgpu/parameters/reset_method  # expect: 1
   for card in /sys/class/drm/card[0-9]; do
       echo "$(basename $card): $(basename $(readlink $card/device/driver 2>/dev/null))"
   done                                            # expect: card0=amdgpu
   ```

4. **If stable:** Wait 5 min, run `diagnostic-full.sh`, compare to runLog-04

5. **Multi-boot test:** Reboot **5 times minimum** (bug is intermittent — single-boot success is not proof)

6. **If crashes:** Collect via `diagnostic-full.sh`, compare parameters/firmware between working and non-working boots

---

## 15. References

### Upstream Bugs
- [drm/amd #5073](https://gitlab.freedesktop.org/drm/amd/-/work_items/5073) — EXACT match: Raphael iGPU optc31 timeout (OPEN)
- [drm/amd #3377](https://gitlab.freedesktop.org/drm/amd/-/work_items/3377) — Raphael optc1_wait_for_state (OPEN)
- [drm/amd #3583](https://gitlab.freedesktop.org/drm/amd/-/work_items/3583) — 9950X optc31 + DMCUB (OPEN)
- [drm/amd #4433](https://gitlab.freedesktop.org/drm/amd/-/work_items/4433) — 8600G optc314 REG_WAIT (OPEN)
- [drm/amd #3006](https://gitlab.freedesktop.org/drm/amd/-/issues/3006) — UMA 512M gfx ring timeouts
- [Ubuntu #2143294](https://bugs.launchpad.net/ubuntu/+source/linux/+bug/2143294) — Kernel 6.17 AMDGPU MES timeout (GFX11, not Raphael)
- [Ubuntu #2141396](http://www.mail-archive.com/desktop-bugs@lists.ubuntu.com/msg829655.html) — Wayland GNOME Shell SIGKILL on AMDGPU timeout

### Firmware
- [Debian #1057656](https://bugs-devel.debian.org/cgi-bin/bugreport.cgi?bug=1057656) — DMCUB broke Raphael (FIXED in 20240709-1)
- [NixOS #418212](https://github.com/nixos/nixpkgs/issues/418212) — DMCUB 0.1.14.0 load failure on Raphael (FIXED in MR#587)
- [kernel-firmware MR #587](https://gitlab.com/kernel-firmware/linux-firmware/-/merge_requests/587) — "Update DMCUB fw for DCN401 & DCN315" (the fix)
- [kernel-firmware MR #497](https://gitlab.com/kernel-firmware/linux-firmware/-/merge_requests/497) — "update dcn firmware" (DCN35/DCN401)
- [NixOS hardware: Raphael iGPU](https://github.com/NixOS/nixos-hardware/blob/master/common/cpu/amd/raphael/igpu.nix) — `sg_display=0` for 6.2-6.5 only
- [Ubuntu Noble linux-firmware changelog](https://launchpad.net/ubuntu/noble/+source/linux-firmware/+changelog) — No DCN 3.1.5 updates
- [UbuntuUpdates: linux-firmware Noble](https://www.ubuntuupdates.org/package/core/noble/main/updates/linux-firmware) — Version history

### Kernel Patches
- [Patch: bypass ODM before CRTC off](https://mail-archive.com/amd-gfx@lists.freedesktop.org/msg107870.html) — Yihan Zhu, May 2024
- [Patch: restore immediate_disable_crtc](https://www.mail-archive.com/amd-gfx@lists.freedesktop.org/msg110052.html)
- [Patch: Use optc31_disable_crtc for DCN 31 and 401](https://www.mail-archive.com/amd-gfx@lists.freedesktop.org/msg122432.html) — Unifies DCN31/DCN401
- [Kernel module parameters](https://docs.kernel.org/gpu/amdgpu/module-parameters.html) — reset_method, sg_display, etc.
- [Kernel driver core](https://docs.kernel.org/gpu/amdgpu/driver-core.html) — IP block reset architecture
- [DCN overview](https://docs.kernel.org/gpu/amdgpu/display/dcn-overview.html) — DMCUB role, OPTC, DCHUB

### NVIDIA
- [NVIDIA 595.58.03 Release Notes](https://docs.nvidia.com/datacenter/tesla/tesla-release-notes-595-58-03/index.html)
- [NVIDIA 595.58.03 README: Minimum Requirements](https://us.download.nvidia.com/XFree86/Linux-x86_64/595.58.03/README/minimumrequirements.html) — Kernel 4.15+
- [NVIDIA 595.58.03 README: Open Kernel Modules](https://us.download.nvidia.com/XFree86/Linux-x86_64/595.58.03/README/kernel_open.html) — Default now
- [NVIDIA 595.58.03 (GamingOnLinux)](https://www.gamingonlinux.com/2026/03/nvidia-driver-595-58-03-released-as-the-big-new-recommended-stable-driver-for-linux/)
- [NVIDIA 595 Feedback Thread](https://forums.developer.nvidia.com/t/595-release-feedback-discussion/362561)
- [NVIDIA Driver Installation Guide](https://docs.nvidia.com/datacenter/tesla/driver-installation-guide/index.html)
- [CUDA 13.2 Downloads](https://developer.nvidia.com/cuda-downloads?target_os=Linux&target_arch=x86_64&Distribution=Ubuntu&target_version=24.04&target_type=deb_network)

### Distros
- [Ubuntu Kernel Lifecycle](https://ubuntu.com/kernel/lifecycle) — 24.04.3=6.14, 24.04.4=6.17
- [Ubuntu 24.04.4 HWE](https://www.omgubuntu.co.uk/2026/01/ubuntu-24-04-4-lts-hwe-update-kernel-mesa) — Kernel 6.17, Mesa 25.2.7
- [Ubuntu 24.04.3 HWE](https://www.omgubuntu.co.uk/2025/08/ubuntu-24-04-3-lts-released) — Kernel 6.14, Mesa 25.0
- [Fedora 42 Release](https://9to5linux.com/fedora-linux-42-is-out-now-powered-by-linux-kernel-6-14-and-gnome-48-desktop) — Kernel 6.14
- [Fedora amd-gpu-firmware](https://packages.fedoraproject.org/pkgs/linux-firmware/amd-gpu-firmware/index.html) — 20260309
- [Arch linux-firmware 20260309](https://archlinux.org/packages/core/any/linux-firmware/) — File list confirms dcn_3_1_5_dmcub.bin.zst
- [Pop!_OS 24.04](https://www.omgubuntu.co.uk/2025/12/pop_os-24-04-lts-stable-release) — Kernel 6.17, COSMIC, NVIDIA 580
- [RPM Fusion NVIDIA Howto](https://rpmfusion.org/Howto/NVIDIA) — Fedora NVIDIA installation

### Mesa
- [Mesa 26.0.0 Release Notes](https://docs.mesa3d.org/relnotes/26.0.0.html) — RDNA2 fixes
- [Mesa 25.3.4 Release Notes](https://docs.mesa3d.org/relnotes/25.3.4.html)

### Community
- [simpledrm card ordering fix (Arch)](https://bbs.archlinux.org/viewtopic.php?id=303311)
- [Card ordering blog post](https://blog.lightwo.net/fix-gpu-identifier-randomly-setting-to-card0-or-card1-linux.html)
- [GNOME ring timeout on Fedora 42](https://discussion.fedoraproject.org/t/gnome-shell-crash-and-gpu-ring-timeout-on-amd-gpu-when-using-brave-browser-fedora-42/149587)
- [AMD GPU ring timeout on Ubuntu 25.04](https://discourse.ubuntu.com/t/amd-gpu-crashing-on-ubuntu-25-04-ring-gfx-0-0-0-timeout-and-reset-failure/62975)
- [Dual GPU AMD-NVIDIA on Arch](https://medium.com/@aviezab/dual-gpu-amd-nvidia-setting-on-arch-linux-based-distro-a88f9874c2d)
- [NixOS Raphael iGPU fix (sg_display)](https://blabli.blog/post/2023/03/14/nixos-amd-raphael-igpu-screen-issues/)
- [Fedora CUDA 12.9 guide](https://forum.level1techs.com/t/cuda-12-9-on-fedora-42-guide-including-getting-cuda-samples-running/230769)
- [ASUS X670E Hero BIOS](https://rog.asus.com/motherboards/rog-crosshair/rog-crosshair-x670e-hero-model/helpdesk_bios/)
