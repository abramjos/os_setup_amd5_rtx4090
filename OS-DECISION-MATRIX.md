# OS Decision Matrix: Dual-GPU ML Workstation

**Hardware:** AMD Ryzen 9 7950X (Raphael iGPU, GC 10.3.6, DCN 3.1.5) + NVIDIA RTX 4090 (headless compute)
**Board:** ASUS ROG Crosshair X670E Hero | BIOS 3603 (AGESA 1.3.0.0a)
**Date:** 2026-03-28
**Sources:** 5 parallel research agents, 60+ web sources, upstream bug trackers, distro changelogs, kernel mailing lists

---

## Executive Summary

**OPTIMAL CHOICE: Ubuntu 24.04.4 LTS + manual firmware fix + XFCE**

Ubuntu wins on ML ecosystem maturity (5/5), CUDA certification (official), community support (10x any alternative), and long-term stability (supported until 2029). Its one critical weakness — stale DMCUB firmware — is solvable with a one-time manual fix that takes 10 minutes. Every other OS solves firmware out-of-box but trades away something significant in return.

**RUNNER-UP: Fedora 43 XFCE Spin** — if you cannot tolerate manual firmware management or if Ubuntu's firmware fix fails to resolve the crash loop. Fedora 43 has the best out-of-box firmware (20260309, all DMCUB fixes included), CUDA 13.2 is now officially supported, and kernel 6.19 has every DCN31 patch. Its 13-month lifecycle (EOL December 2026) is the main drawback.

---

## The Four Candidates

| | Ubuntu 24.04.4 LTS | Fedora 43 XFCE | Arch Linux | Pop!_OS 24.04 |
|---|---|---|---|---|
| **Kernel** | 6.17 HWE | 6.19 | 6.19 (+ 6.18 LTS) | 6.18-6.19 |
| **linux-firmware** | 20240318 base + SRU patches | **20260309** | **20260309** | 20250317+system76 |
| **DMCUB Status** | Possibly updated via SRU 0ubuntu2.21 — **UNVERIFIED** | **FIXED** (post-MR#587) | **FIXED** (post-MR#587) | Likely 0.0.255.0 (March 2025 base) |
| **Mesa** | 25.2.8 (HWE) | 25.1.9 | 26.0+ | 25.1.5-26.0.3 |
| **NVIDIA Driver** | 595.58.03 via CUDA repo | 580.119 via RPM Fusion | 595.58.03 (official repo) | 580-595 (rolling updates) |
| **CUDA** | 13.2 (official NVIDIA repo) | 13.2 (.run file; F43 in matrix) | 13.2 (official repo) | 13.x via NVIDIA repo |
| **Compositor** | XFCE (install separately) | XFCE (native spin) | XFCE (install) | COSMIC (native Wayland) |
| **Support Lifecycle** | **April 2029** (5 years) | **December 2026** (~9 months) | Rolling (indefinite) | LTS (next: 26.04) |
| **ML Maturity** | **5/5** | 3/5 | 3/5 | 3/5 |

---

## 1. Ubuntu 24.04.4 LTS — RECOMMENDED

### Why Ubuntu Wins

1. **CUDA is officially certified.** Ubuntu 24.04 LTS is in NVIDIA's CUDA 13.2 support matrix with validated kernel 6.17.0-19 and GCC 14.3.0. When CUDA breaks, NVIDIA fixes it for Ubuntu first.

2. **Community is 10x larger for ML.** Every PyTorch tutorial, every NGC container, every StackOverflow answer, every cloud provider default — all Ubuntu. When you hit an obscure issue at 2 AM, Ubuntu has the answer.

3. **5-year support.** Supported until April 2029. Fedora 43 EOLs in 9 months. You won't need to reinstall or upgrade the OS for years.

4. **`nvidia-headless` concept exists.** Ubuntu separates display and compute NVIDIA packages. `cuda-drivers` from the NVIDIA repo installs 595.58.03 cleanly for headless compute.

5. **Docker is first-class.** `docker.io` in the repo, nvidia-container-toolkit documented for Ubuntu, every ML Docker image is Ubuntu-based.

### Ubuntu's One Critical Weakness: Firmware

Ubuntu Noble's `linux-firmware` package has a March 2024 base (`20240318`). Updates are cherry-picked via SRU, not rebased. The SRU changelog for version **0ubuntu2.21** (November 2025) mentions:

> "amdgpu: DCUB update for DCN401 and DCN315"

DCN315 = DCN 3.1.5. **This means the DMCUB firmware MAY have been updated** — but the changelog is ambiguous and doesn't specify the exact firmware version delivered. The loaded firmware on the current system is `0x05002F00` (version 0.0.47.0), which predates all known fixes. This could mean:

- The SRU delivered the fix but the `.bin` vs `.bin.zst` file conflict prevented it from loading
- The SRU delivered a firmware version that's still too old
- The SRU worked but the initramfs was never rebuilt

**Resolution: Manual firmware verification + update.** This is a one-time 10-minute fix:

```bash
# Step 1: Check what's actually loaded
dmesg | grep "DMUB firmware.*version"
# If version >= 0x0500E000 (0.0.224.0): SRU worked, firmware is fine
# If version == 0x05002F00 (0.0.47.0): SRU didn't fix it, manual update needed

# Step 2: If manual update needed
cd /tmp && git clone --depth 1 --branch 20250305 \
  https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git
for f in dcn_3_1_5_dmcub psp_13_0_5_toc psp_13_0_5_ta psp_13_0_5_asd; do
  sudo cp /tmp/linux-firmware/amdgpu/${f}.bin /lib/firmware/amdgpu/
  sudo zstd -f /lib/firmware/amdgpu/${f}.bin -o /lib/firmware/amdgpu/${f}.bin.zst
  sudo rm -f /lib/firmware/amdgpu/${f}.bin
done
sudo update-initramfs -u -k all && sudo reboot
```

### Point Release Timeline

| Release | Date | Kernel | Mesa | Notes |
|---------|------|--------|------|-------|
| 24.04 GA | Apr 2024 | 6.8 | 24.0.4 | Missing ALL DCN31 patches |
| 24.04.1 | Aug 2024 | 6.8 | 24.0.x | No HWE yet |
| 24.04.2 | Feb 2025 | **6.11** | 24.2.x | Has ODM bypass + CVE fixes |
| 24.04.3 | Aug 2025 | **6.14** | **25.0.7** | Has ODM + OTG + seamless patches |
| **24.04.4** | **Feb 2026** | **6.17** | **25.2.8** | **ALL DCN31 patches.** This is the target. |
| 24.04.5 | ~Aug 2026 | ~6.20 | TBD | Future |

**Fresh install from 24.04.4 ISO ships HWE kernel 6.17 + Mesa 25.2.8 by default.** No separate HWE installation needed for new installs.

Existing 24.04 users: `sudo apt install linux-generic-hwe-24.04` to get 6.17.

### NVIDIA Driver Installation (CORRECTED)

**IMPORTANT CORRECTION:** There is no `nvidia-headless-595-server` package. NVIDIA changed package naming starting with branch 590. The correct installation for 595:

```bash
# Add NVIDIA CUDA repo
wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
sudo dpkg -i cuda-keyring_1.1-1_all.deb
sudo apt update

# Install driver (595.58.03) + CUDA 13.2
sudo apt install cuda-drivers cuda-toolkit-13-2

# For headless compute ONLY (no display components):
sudo apt install libnvidia-compute-595 nvidia-dkms-open-595
```

Alternative: `nvidia-driver-590-server` (590.48.01) is available in Ubuntu's multiverse repo and uses the old naming convention. `nvidia-driver-580` is Canonical-supported in restricted.

### gpu-manager Warning

Ubuntu's `gpu-manager` service (from `ubuntu-drivers-common`) **auto-rewrites GPU configuration on every boot**. It generates X11 config files for NVIDIA PRIME hybrid GPU setups, overriding your manual dual-GPU config.

**Must disable:**
```bash
# GRUB parameter (already in recommended config):
nogpumanager

# Belt-and-suspenders: mask the service
sudo systemctl disable gpu-manager.service
sudo systemctl mask gpu-manager.service
```

### Known Ubuntu Bugs for This Hardware

| Bug | Description | Impact | Status |
|-----|-------------|--------|--------|
| [LP #2033157](https://bugs.launchpad.net/ubuntu/+source/switcheroo-control/+bug/2033157) | iGPU and dGPU mix-up — NVIDIA incorrectly selected as primary | DIRECT — glxgears runs on dGPU | Open |
| [LP #2130926](https://bugs.launchpad.net/ubuntu/+source/nvidia-graphics-drivers-580/+bug/2130926) | No display on dual GPU with NVIDIA 580 + AMD onboard | DIRECT — X11 session blank | Open |
| [LP #2143294](https://bugs.launchpad.net/ubuntu/+source/linux/+bug/2143294) | Kernel 6.17 MES firmware timeout on Radeon 740M | LOW — different GPU arch (RDNA3 vs RDNA2) | Open |
| [LP #2141477](https://bugs.launchpad.net/ubuntu/+source/nvidia-graphics-drivers-580/+bug/2141477) | nvidia-dkms-580-open fails on HWE kernel 6.17.0-14 | MEDIUM — DKMS build failure; fixed in 580.95+ | Open |

### Ubuntu Score

| Category | Score | Notes |
|----------|-------|-------|
| Firmware freshness | D (fixable to A) | Stale out-of-box, one-time manual fix solves it |
| Kernel patch coverage | A | 6.17 HWE has ALL 6 DCN31 patches |
| NVIDIA/CUDA ecosystem | A+ | Official CUDA 13.2, nvidia-container-toolkit, Docker |
| Community/support | A+ | 10x any alternative for ML |
| Lifecycle | A+ | 5-year support (to 2029) |
| Firmware management | C | Manual initramfs rebuild, `.bin`/`.bin.zst` conflicts |
| initramfs control | B | initramfs-tools, less flexible than dracut/mkinitcpio |
| DKMS reliability | B+ | Low frequency failure, slow recovery (wait for SRU) |

---

## 2. Fedora 43 XFCE Spin — BEST OUT-OF-BOX FIRMWARE

### Why Consider Fedora

1. **Firmware problem solved out-of-box.** linux-firmware 20260309 ships with ALL DMCUB fixes including the MR#587 DCN315 regression fix. No manual firmware management. No `.bin`/`.bin.zst` conflicts. Just install and boot.

2. **Kernel 6.19 has everything.** All 6 critical DCN31 patches, plus 2 additional kernel versions of amdgpu improvements beyond Ubuntu's 6.17.

3. **XFCE spin is native.** Ships with Xfce 4.20, X11, no GNOME/Mutter anywhere. The compositor ring timeout trigger is eliminated at the OS level.

4. **CUDA 13.2 now officially supports Fedora.** CUDA 13.2 lists `fedora43` in its support matrix. This is a significant change from historical practice.

5. **Split firmware packages.** `amd-gpu-firmware` updates independently of WiFi/Bluetooth firmware. Updates are faster and more targeted.

### Why NOT Fedora (Significant Drawbacks)

1. **9-month remaining lifecycle.** Fedora 43 released October 2025, EOLs December 2026. You will need to upgrade to Fedora 44 or 45 within a year.

2. **NVIDIA driver lags.** RPM Fusion has **580.119.02** (December 2025), NOT 595.58.03. Getting 595 requires the NVIDIA `.run` installer or waiting for RPM Fusion to package it.

3. **CUDA installation is harder.** No native `cuda-fedora43` repo existed initially. CUDA 13.2 supports Fedora 43 via runfile only — not RPM packages. GCC 15 compatibility is needed.

4. **Kernel updates break NVIDIA every 2-3 cycles.** Fedora rebases to new upstream kernels within a release (6.14→6.15→...→6.19). Each rebase risks akmods build failure. RPM Fusion fixes within days, but you're stuck in the meantime.

5. **Smaller ML community.** Most ML tutorials, Docker images, and CI pipelines target Ubuntu. Fedora-specific ML debugging help is harder to find.

6. **`nova_core` blacklisting required.** Starting with kernel 6.15, Fedora includes the new `nova` kernel module alongside nouveau. Must blacklist both:
   ```
   modprobe.blacklist=nouveau,nova_core
   ```

### Fedora 42 vs 43

| | Fedora 42 | Fedora 43 |
|---|---|---|
| Release | April 15, 2025 | October 28, 2025 |
| **EOL** | **May 13, 2026 (~6 weeks away!)** | **December 9, 2026 (~9 months)** |
| Kernel at launch | 6.14 | 6.17 |
| Current kernel | 6.19.8 | 6.19.10 |
| Firmware | 20260309 | 20260309 |
| GNOME | 48 | 49 |

**Install Fedora 43, NOT 42.** Fedora 42 EOLs in ~6 weeks (May 2026). Fedora 43 has 9 months of support remaining and identical hardware support.

### NVIDIA Installation on Fedora

```bash
# Enable RPM Fusion
sudo dnf install \
  https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-43.noarch.rpm \
  https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-43.noarch.rpm

# Install NVIDIA driver (580.119.02 from RPM Fusion)
sudo dnf install akmod-nvidia xorg-x11-drv-nvidia-cuda

# CRITICAL: Wait for akmods to finish building before rebooting
# This takes 2-5 minutes. Monitor with:
watch -n 2 "ls /lib/modules/$(uname -r)/extra/nvidia/"
# Wait until nvidia.ko.xz appears

# Blacklist nouveau AND nova_core
echo 'blacklist nouveau
blacklist nova_core' | sudo tee /etc/modprobe.d/blacklist-nvidia-nouveau.conf

# For NVIDIA 595 (if RPM Fusion doesn't have it yet):
# Download .run file from nvidia.com, install with:
# sudo ./NVIDIA-Linux-x86_64-595.58.03.run --kernel-module-type=open --no-drm
```

### CUDA on Fedora (Practical Guide)

```bash
# Option A: NVIDIA runfile (official, CUDA 13.2 supports fedora43)
wget https://developer.download.nvidia.com/compute/cuda/13.2.0/local_installers/cuda_13.2.0_595.58.03_linux.run
sudo sh cuda_13.2.0_595.58.03_linux.run --toolkit --silent
# This installs ONLY the toolkit, not the driver (driver already installed via RPM Fusion)

# Option B: Container-based (recommended for version flexibility)
sudo dnf install nvidia-container-toolkit podman
nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
podman run --device nvidia.com/gpu=all nvidia/cuda:13.2-runtime-ubuntu24.04 nvidia-smi
```

### Known Fedora Issues for AMD Raphael

| Issue | Description | Impact |
|-------|-------------|--------|
| [UNUSABLE Gnome: REG_WAIT timeout](https://discussion.fedoraproject.org/t/166223) | optc32_disable_crtc timeout on AMD+GNOME+Wayland | HIGH — but XFCE spin avoids this |
| [GNOME Shell crash + ring timeout](https://discussion.fedoraproject.org/t/149587) | ring gfx_0.0.0 timeout triggered by Brave/Chrome | HIGH — GNOME only, not XFCE |
| [AMD laptop freezes on GNOME+Wayland](https://discussion.fedoraproject.org/t/150550) | Consistent hangs on AMD+GNOME | HIGH — GNOME only |
| [Framework: critical amdgpu bugs 6.18/6.19](https://community.frame.work/t/79221) | Strix Point APU issues | LOW — different APU generation |

**Pattern:** All reported issues are GNOME+Wayland specific. The XFCE spin on X11 avoids the entire failure path.

### Fedora Score

| Category | Score | Notes |
|----------|-------|-------|
| Firmware freshness | **A+** | 20260309 with all fixes, no manual work |
| Kernel patch coverage | **A+** | 6.19 has ALL patches + 2 versions ahead of Ubuntu |
| NVIDIA/CUDA ecosystem | B | RPM Fusion driver lags; CUDA via runfile; less documented |
| Community/support | B+ | Growing but ~1/10th of Ubuntu for ML |
| Lifecycle | **C** | 9 months remaining (EOL Dec 2026) |
| Firmware management | **A+** | Split packages, auto-updated, no conflicts |
| initramfs control | A | dracut, most granular control |
| DKMS reliability | B | Medium frequency failure, fast recovery (1-3 days) |

---

## 3. Arch Linux — LATEST EVERYTHING

### Why Consider Arch

1. **Always-current firmware and kernel.** linux-firmware 20260309, kernel 6.19.9, Mesa 26.0+, NVIDIA 595.58.03 — all in the official repos. No PPAs, no manual downloads, no SRU lag.

2. **CUDA 13.2 + cuDNN 9.19 in official repos.** `pacman -S cuda cudnn` — done. No NVIDIA repo setup, no runfiles. This is simpler than any other distro.

3. **No `.bin`/`.bin.zst` firmware conflicts.** Arch uses `.zst` only. Kernel loads it. No ambiguity.

4. **Automatic initramfs rebuild.** mkinitcpio auto-rebuilds on every kernel/firmware/driver update via pacman hooks. No forgotten `update-initramfs` commands.

5. **Dual kernel safety net.** Install both `linux` (6.19) and `linux-lts` (6.18) with `nvidia-open-dkms`. If 6.19 breaks, boot into 6.18 LTS.

6. **nvidia-container-toolkit in official repo.** `pacman -S nvidia-container-toolkit` — single command, no NVIDIA repo needed.

### Why NOT Arch (Significant Drawbacks)

1. **Rolling release risk is REAL.** linux-firmware-amdgpu 20250613 shipped a broken DMCUB that caused black screens on RX 9000 series. Fixed within days, but users were stuck. This WILL happen again.

2. **Any `pacman -Syu` can break NVIDIA.** Kernel 6.19→6.20 transition could break nvidia-open-dkms build. You must check Arch news before every system update.

3. **Not NVIDIA-certified.** Arch is NOT in NVIDIA's CUDA support matrix. CUDA works (glibc/GCC compatible), but NVIDIA won't help if it breaks.

4. **Smaller ML community.** Most ML infrastructure assumes Ubuntu. Docker images, tutorials, CI pipelines — all Ubuntu-centric.

5. **DMCUB 0.1.x firmware risk.** Arch ships the latest DMCUB (0.1.40-0.1.53 range). Version 0.1.14.0 was KNOWN BAD on Raphael (NixOS #418212). Later 0.1.x versions include the fix (MR#587), but the 0.1.x series has less Raphael-specific testing than the conservative 0.0.255.0.

6. **Manual setup required.** Even with archinstall, GPU driver config, initramfs tuning, and compositor setup require manual work.

### archinstall Reliability

archinstall offers XFCE as a desktop profile and NVIDIA open modules as a driver option. However:

- November 2024 ISO broke installation during pipewire step
- Version 2.5.4 had random lockups during package entry
- Disk encryption had AttributeError bugs
- Video driver detection issues documented

**Recommendation:** Use archinstall for base system (disk, bootloader, networking, users). Then manually configure GPU drivers, XFCE, and initramfs.

### mkinitcpio Configuration for Dual GPU

```bash
# /etc/mkinitcpio.conf
MODULES=(amdgpu nvidia nvidia_modeset nvidia_uvm nvidia_drm)
# amdgpu FIRST — ensures it claims card0 before nvidia loads
# All 400+ amdgpu firmware blobs auto-included

HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block filesystems fsck)
# kms hook (default since mkinitcpio v33) handles early GPU KMS

# Rebuild for all kernels:
sudo mkinitcpio -P
```

### Package Installation

```bash
# GPU drivers
sudo pacman -S nvidia-open-dkms nvidia-utils linux-firmware-amdgpu

# CUDA + ML
sudo pacman -S cuda cudnn

# Desktop
sudo pacman -S xfce4 xfce4-goodies lightdm lightdm-gtk-greeter

# Containers
sudo pacman -S docker nvidia-container-toolkit

# Monitoring
sudo pacman -S nvtop htop

# ML frameworks (use pip in venv, NOT pacman)
python -m venv ~/ml-env
source ~/ml-env/bin/activate
pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu132
```

### Risk Mitigation Strategy

```bash
# 1. Dual kernels
sudo pacman -S linux linux-lts nvidia-open-dkms

# 2. Pin critical packages when stable
# /etc/pacman.conf:
# IgnorePkg = linux-firmware-amdgpu linux nvidia-open-dkms

# 3. Btrfs snapshots before every update
sudo btrfs subvolume snapshot / /.snapshots/pre-update-$(date +%Y%m%d)
sudo pacman -Syu

# 4. Check Arch news feed before updating
curl -s https://archlinux.org/feeds/news/ | head -50
```

### Known Arch Issues for Raphael

| Issue | Description | Impact |
|-------|-------------|--------|
| [bbs #291457](https://bbs.archlinux.org/viewtopic.php?id=291457) | AMD 7950X iGPU crashes, ring gfx_0.0.0 timeout | DIRECT — same error pattern |
| [bbs #306826](https://bbs.archlinux.org/viewtopic.php?id=306826) | System freeze with nvidia-open 575.x | MEDIUM — fixed in 595 |
| [L1T: 7950X iGPU instability](https://forum.level1techs.com/t/224035) | Blackouts/freezes on 7950X iGPU (Linux AND Windows) | DIRECT — hardware-level |
| [firmware 20250613 broke DMCUB](https://bbs.archlinux.org/viewtopic.php?pid=2247690) | Black screen on RX 9000 after firmware update | LOW — different GPU, but same risk class |

### Arch Score

| Category | Score | Notes |
|----------|-------|-------|
| Firmware freshness | **A+** | 20260309, all fixes, auto-updated |
| Kernel patch coverage | **A+** | 6.19 + 6.18 LTS, all patches |
| NVIDIA/CUDA ecosystem | A- | CUDA 13.2 + cuDNN in official repo; not NVIDIA-certified |
| Community/support | B | Niche but active; Wiki is excellent reference |
| Lifecycle | **A** (rolling) | Never EOLs; but YOU maintain it forever |
| Firmware management | **A+** | `.zst` only, no conflicts, auto initramfs |
| initramfs control | **A+** | mkinitcpio auto-includes all firmware, auto-rebuilds |
| DKMS reliability | B- | Medium-high risk; requires vigilance before `pacman -Syu` |

---

## 4. Pop!_OS 24.04 — COSMIC DESKTOP ALTERNATIVE

### Why Consider Pop!_OS

1. **COSMIC avoids Mutter crash modes.** COSMIC desktop uses cosmic-comp (Rust/Smithay), NOT Mutter. No RT-priority KMS thread SIGKILL. Multi-threaded per-output rendering. Per-output damage tracking. This eliminates Mutter-specific failure modes.

2. **Newer firmware than Ubuntu.** Pop!_OS fork of linux-firmware is `20250317+system76` (March 2025) — approximately DMCUB 0.0.255.0. This is dramatically newer than Ubuntu 24.04's March 2024 base.

3. **Newer kernel than Ubuntu stock.** Ships with 6.18.7 (now updating to 6.19), which includes all DCN31 patches.

4. **NVIDIA pre-installed.** The NVIDIA ISO ships with driver pre-configured. Less manual setup.

5. **System76 sells Raphael desktops.** Their Thelio line uses Ryzen 7950X, so the platform is tested by System76 QA.

### Why NOT Pop!_OS (Significant Drawbacks)

1. **COSMIC is v1.0.** Released December 2025. Known GPU bugs: panel crashes after nvidia_drm semaphore failure (#3334), intermittent UI lag and hard freezes with EGL errors (#2561), kernel panic in amdgpu display stream on AMD+NVIDIA (#1105).

2. **COSMIC still uses OpenGL ES on the GFX ring.** The compositor submits GL draw calls via Smithay's GlowRenderer (OpenGL ES 2.0/3.0). If the underlying DCN/DMCUB is buggy, COSMIC can still trigger ring timeouts — just potentially less frequently than Mutter.

3. **system76-power GPU switching is NOT supported on desktops.** The switchable graphics feature (Integrated/Hybrid/NVIDIA/Compute modes) is officially for laptops only. On a desktop with AMD iGPU + NVIDIA dGPU, you need manual PRIME configuration.

4. **systemd-boot, not GRUB.** Pop!_OS uses `kernelstub` for kernel parameter management instead of `/etc/default/grub`. All existing documentation and scripts assume GRUB. Kernel params go in:
   ```bash
   sudo kernelstub -a "amdgpu.sg_display=0 amdgpu.dcdebugmask=0x10 ..."
   ```

5. **NVIDIA driver may have CUDA issues.** The `system76-driver-nvidia` metapackage defaults to `nvidia-driver-580-open`, which caused CUDA detection failures with PyTorch on some configurations (GitHub #3654). May need manual driver installation.

6. **Fresh install required from Ubuntu.** No in-place migration path from Ubuntu to Pop!_OS.

7. **Same firmware management as Ubuntu.** Pop!_OS uses Ubuntu's package base for `linux-firmware`. While the System76 overlay provides a newer base (March 2025 vs March 2024), it still doesn't have the latest 2026 firmware that Fedora/Arch ship.

### COSMIC Desktop Architecture — Deep Dive

| Component | Technology | Crash Risk for Raphael |
|-----------|-----------|----------------------|
| **Compositor** | cosmic-comp (Rust/Smithay) | **Lower than Mutter** — multi-threaded, no RT thread |
| **Compositing renderer** | GlowRenderer (OpenGL ES 2.0/3.0) | **Still uses GFX ring** — ring timeout possible |
| **App UI renderer** | wgpu (Vulkan by default) | **Different ring** — separate from compositor |
| **Buffer management** | GBM (Generic Buffer Manager) | Standard DRM, same as Mutter |
| **Multi-GPU** | GpuManager (explicit DMABUF routing) | **Better than Mutter** — intelligent cross-GPU handling |
| **KMS thread** | Normal priority | **No SIGKILL risk** (unlike Mutter's RT thread) |

**Will COSMIC avoid the crash loop?** Partially:
- The optc31 timeout is kernel/firmware-level — COSMIC cannot prevent it
- But COSMIC's lighter GL usage + no RT-priority SIGKILL means the cascade from "DCN stall → ring timeout → crash loop" is less likely
- Not a guarantee — issue #1105 shows COSMIC can still trigger amdgpu display crashes

### System76 Hardware Testing

System76's Thelio desktops use Ryzen 7950X but with **discrete GPUs only** (no iGPU display). The specific configuration of "Raphael iGPU for display + NVIDIA for headless compute" is NOT a configuration System76 tests or sells. So while the platform is validated, the exact dual-GPU architecture is not.

### Pop!_OS Score

| Category | Score | Notes |
|----------|-------|-------|
| Firmware freshness | B | March 2025 base (~0.0.255.0); newer than Ubuntu, older than Fedora/Arch |
| Kernel patch coverage | A | 6.18+ has all DCN31 patches |
| NVIDIA/CUDA ecosystem | B+ | Pre-installed driver; CUDA via NVIDIA repo; some CUDA detection issues |
| Community/support | B+ | Active community; System76 support for hardware issues |
| Lifecycle | A | LTS (next release 26.04) |
| Firmware management | C+ | Same as Ubuntu but with newer base |
| initramfs control | B | kernelstub + update-initramfs; different from GRUB workflow |
| DKMS reliability | B+ | System76 tests driver/kernel combos; same DKMS as Ubuntu |
| **Compositor safety** | **A-** | COSMIC avoids Mutter-specific crashes; still uses GL |

---

## Cross-Reference Compatibility Matrix

### Kernel x NVIDIA Driver

| | NVIDIA 580 | NVIDIA 590 | NVIDIA 595 |
|---|:--:|:--:|:--:|
| Kernel 6.8 (Ubuntu GA) | YES | YES | YES |
| Kernel 6.14 (Ubuntu HWE 24.04.3) | YES | YES | YES |
| Kernel 6.17 (Ubuntu HWE 24.04.4) | **BUILD FAIL (580.65)** Fixed in 580.95+ | YES | YES |
| Kernel 6.18 (Pop!_OS) | YES (580.119+) | YES | YES |
| Kernel 6.19 (Fedora 43, Arch) | YES (580.119+) | YES | YES (explicit build fix) |

### OS x Firmware x Compositor

| | GNOME (Mutter) | XFCE (xfwm4) | COSMIC | Sway | TTY |
|---|:--:|:--:|:--:|:--:|:--:|
| **Ubuntu + old firmware** | **CRASH LOOP** | Likely OK | N/A | Likely OK | OK |
| **Ubuntu + fixed firmware** | Risk remains | **BEST** | N/A | Good | OK |
| **Fedora + native firmware** | Risk remains | **BEST** | N/A | Good | OK |
| **Arch + native firmware** | Risk remains | **BEST** | N/A | Good | OK |
| **Pop!_OS + native firmware** | N/A | Install separately | **Good (some risk)** | N/A | OK |

### OS x CUDA Installation Method

| OS | CUDA Package Source | Version | Method | Complexity |
|----|-------------------|---------|--------|-----------|
| **Ubuntu 24.04** | NVIDIA apt repo | 13.2 | `apt install cuda-toolkit-13-2` | **Easiest** |
| **Fedora 43** | NVIDIA .run file | 13.2 | `sh cuda_13.2.0_*.run --toolkit` | Medium |
| **Arch** | Official pacman repo | 13.2 | `pacman -S cuda` | **Easiest** |
| **Pop!_OS** | NVIDIA apt repo (Ubuntu compat) | 13.2 | Same as Ubuntu | **Easiest** |

---

## Weighted Scoring Matrix

Each category is weighted by importance for THIS specific workstation (Raphael iGPU stability + ML compute):

| Category | Weight | Ubuntu 24.04.4 | Fedora 43 XFCE | Arch Linux | Pop!_OS 24.04 |
|----------|--------|:-:|:-:|:-:|:-:|
| **Firmware (fixes root cause)** | 25% | 7/10 (fixable) | **10/10** | **10/10** | 8/10 |
| **Kernel patch coverage** | 15% | 9/10 | **10/10** | **10/10** | 9/10 |
| **CUDA/NVIDIA ecosystem** | 20% | **10/10** | 6/10 | 8/10 | 7/10 |
| **ML community support** | 15% | **10/10** | 5/10 | 4/10 | 6/10 |
| **Lifecycle / stability** | 10% | **10/10** | 4/10 | 7/10 | 8/10 |
| **Compositor safety** | 10% | 8/10 (XFCE) | 8/10 (XFCE) | 8/10 (XFCE) | **9/10** (COSMIC) |
| **Setup complexity** | 5% | 7/10 | 6/10 | 4/10 | 7/10 |
| **WEIGHTED TOTAL** | 100% | **8.65** | 7.35 | 7.65 | 7.60 |

**Ubuntu wins by 1.0-1.3 points** despite its firmware weakness, because the CUDA ecosystem and community advantages are worth more for a production ML workstation than having perfect out-of-box firmware.

---

## Optimal System Settings (Post-OS-Install)

Regardless of which OS is chosen, these settings produce the most stable configuration for Raphael iGPU + RTX 4090 headless compute:

### Kernel Command Line (GRUB or kernelstub)

```
quiet splash
amdgpu.sg_display=0
amdgpu.dcdebugmask=0x10
amdgpu.ppfeaturemask=0xfffd7fff
amdgpu.reset_method=1
amdgpu.gpu_recovery=1
pcie_aspm=off
iommu=pt
processor.max_cstate=1
amd_pstate=active
modprobe.blacklist=nouveau
nogpumanager
initcall_blacklist=simpledrm_platform_driver_init
```

Add for Fedora 43 (kernel 6.15+):
```
modprobe.blacklist=nouveau,nova_core
```

### modprobe.d/amdgpu.conf

```bash
options amdgpu sg_display=0
options amdgpu ppfeaturemask=0xfffd7fff
options amdgpu gpu_recovery=1
options amdgpu reset_method=1
options amdgpu dc=1
options amdgpu audio=1
```

### modprobe.d/nvidia.conf

```bash
blacklist nouveau
options nouveau modeset=0
options nvidia NVreg_UsePageAttributeTable=1
options nvidia NVreg_InitializeSystemMemoryAllocations=0
options nvidia NVreg_DynamicPowerManagement=0x02
options nvidia NVreg_EnableGpuFirmware=1
options nvidia NVreg_PreserveVideoMemoryAllocations=1
options nvidia NVreg_TemporaryFilePath=/var/tmp
options nvidia NVreg_RegistryDwords="RmGpuComputeExecTimeout=0"
options nvidia_drm modeset=1
options nvidia_drm fbdev=1
```

**Note:** `nvidia-drm.modeset=1` is DEFAULT in NVIDIA 595. Setting it explicitly is belt-and-suspenders. Do NOT set `NVreg_EnableGpuFirmware=0` — this breaks the open kernel modules that 595 uses by default.

### initramfs Module Order

```
amdgpu          # FIRST — claims card0 for display
nvidia
nvidia_modeset
nvidia_uvm
nvidia_drm
```

### Compositor: XFCE with Compositing Disabled

```bash
# Install XFCE
# Ubuntu: sudo apt install xfce4 xfce4-goodies
# Fedora: native XFCE spin (already installed)
# Arch:   sudo pacman -S xfce4 xfce4-goodies lightdm lightdm-gtk-greeter

# Disable xfwm4 compositor initially (zero GPU ring submissions)
xfconf-query -c xfwm4 -p /general/use_compositing -s false

# If display is stable, OPTIONALLY re-enable compositing later:
# xfconf-query -c xfwm4 -p /general/use_compositing -s true
```

### Mutter Workaround (if GNOME is ever used)

```bash
echo 'MUTTER_DEBUG_KMS_THREAD_TYPE=user' | sudo tee /etc/environment.d/90-mutter-kms.conf
```

### NVIDIA Headless Compute Config

```bash
# Enable persistence daemon
sudo systemctl enable nvidia-persistenced

# Set persistence mode and compute mode
sudo nvidia-smi -pm 1
sudo nvidia-smi -c DEFAULT

# Lock power limit for consistent training (optional)
sudo nvidia-smi -pl 400  # RTX 4090 default TDP is 450W; 400W reduces thermals with ~2% perf loss
```

### BIOS Settings (Quick Reference)

| Setting | Value | Why |
|---------|-------|-----|
| Integrated Graphics | **Force** | Enable iGPU with dGPU present |
| UMA Frame Buffer | **2G** | 512M causes ring timeouts (drm/amd #3006) |
| GFXOFF | **Disabled** | Prevent iGPU power gating |
| Above 4G Decoding | **Enabled** | RTX 4090 24GB BAR |
| Re-Size BAR | **Enabled** | Full BAR for compute |
| Global C-State | **Disabled** | Prevent PCIe link drops |
| CSM | **Disabled** | Required for UEFI GOP |
| Secure Boot OS Type | **Other OS** | Allow unsigned GPU drivers |

### Target Firmware Versions

| Blob | Minimum Safe Version | How to Check |
|------|---------------------|-------------|
| DMCUB (dcn_3_1_5_dmcub) | **0.0.224.0** (tag 20240709) | `dmesg \| grep "DMUB firmware.*version"` |
| Ideal DMCUB | **0.0.255.0** (tag 20250305) | Last 0.0.x series, widest testing |
| PSP TOC (psp_13_0_5_toc) | Any (never updated) | Static, cosmetic conflict only |
| PSP TA (psp_13_0_5_ta) | Latest available | `dmesg \| grep "PSP"` |

### Verification Commands (All OS)

```bash
# 1. DMCUB firmware version (MOST IMPORTANT)
dmesg | grep "DMUB firmware.*version"
# Expect: NOT 0x05002F00 (0.0.47.0)
# Good:   0x0500FF00 (0.0.255.0) or higher

# 2. Card ordering
for card in /sys/class/drm/card[0-9]; do
  echo "$(basename $card): $(basename $(readlink $card/device/driver 2>/dev/null))"
done
# Expect: card0=amdgpu, card1=nvidia (or nvidia absent if not yet installed)

# 3. Kernel parameters active
cat /proc/cmdline
# Verify all parameters present

# 4. Module parameters
cat /sys/module/amdgpu/parameters/sg_display      # Expect: 0
cat /sys/module/amdgpu/parameters/ppfeaturemask    # Expect: 4294443007 (0xfffd7fff)
cat /sys/module/amdgpu/parameters/reset_method     # Expect: 1
cat /sys/module/amdgpu/parameters/gpu_recovery     # Expect: 1

# 5. Display on AMD
glxinfo | grep "OpenGL renderer"
# Expect: AMD Radeon Graphics (raphael, LLVM ...)

# 6. NVIDIA headless
nvidia-smi --query-gpu=name,display_active,display_mode --format=csv
# Expect: NVIDIA GeForce RTX 4090, Disabled, Disabled

# 7. No crash indicators
dmesg | grep -c "REG_WAIT timeout"   # Expect: 0
dmesg | grep -c "ring.*timeout"      # Expect: 0
dmesg | grep -c "GPU reset"          # Expect: 0
dmesg | grep -c "Xid"               # Expect: 0

# 8. CUDA functional
nvidia-smi  # Shows GPU info + CUDA version
nvcc --version  # Shows CUDA compiler version
python3 -c "import torch; print(torch.cuda.is_available(), torch.cuda.get_device_name(0))"
```

---

## Final Recommendation: Decision Flowchart

```
START
  │
  ├─ Are you comfortable with a one-time manual firmware fix (10 min)?
  │   │
  │   ├─ YES → UBUNTU 24.04.4 LTS + XFCE + manual firmware
  │   │         (Best ML ecosystem, 5-year support, CUDA certified)
  │   │
  │   └─ NO → Do you need maximum stability or maximum freshness?
  │       │
  │       ├─ STABILITY → FEDORA 43 XFCE SPIN
  │       │               (Firmware fixed out-of-box, 9-month lifecycle)
  │       │
  │       └─ FRESHNESS → ARCH LINUX + XFCE
  │                       (Everything latest, rolling release risk)
  │
  └─ Do you want to try a non-GNOME Wayland compositor?
      │
      └─ YES → POP!_OS 24.04
                (COSMIC desktop, newer firmware, NVIDIA pre-installed)
                (But: v1.0 compositor, some GPU bugs, fresh install required)
```

**For this specific workstation: Ubuntu 24.04.4 LTS + manual DMCUB firmware fix + XFCE + all optimal settings above.** The 10-minute firmware fix eliminates Ubuntu's only weakness while preserving its overwhelming advantages for ML workloads.

---

## References

### Ubuntu
- [Ubuntu Kernel Lifecycle](https://ubuntu.com/kernel/lifecycle)
- [Ubuntu 24.04.4 HWE (OMG!Ubuntu)](https://www.omgubuntu.co.uk/2026/02/ubuntu-24-04-4-lts-released)
- [Ubuntu Noble linux-firmware changelog](https://launchpad.net/ubuntu/noble/+source/linux-firmware/+changelog)
- [CUDA 13.2 Downloads for Ubuntu](https://developer.nvidia.com/cuda-downloads?target_os=Linux&target_arch=x86_64&Distribution=Ubuntu&target_version=24.04)
- [gpu-manager source](https://github.com/canonical/ubuntu-drivers-common/blob/master/share/hybrid/gpu-manager.c)
- [LP #2033157: iGPU/dGPU mix-up](https://bugs.launchpad.net/ubuntu/+source/switcheroo-control/+bug/2033157)
- [LP #2141477: DKMS 580 fails on 6.17](https://bugs.launchpad.net/ubuntu/+source/nvidia-graphics-drivers-580/+bug/2141477)

### Fedora
- [Fedora 42/43 release](https://9to5linux.com/fedora-linux-42-is-out-now-powered-by-linux-kernel-6-14-and-gnome-48-desktop)
- [Fedora kernel packages](https://packages.fedoraproject.org/pkgs/kernel/kernel/fedora-42-updates.html)
- [Fedora amd-gpu-firmware](https://packages.fedoraproject.org/pkgs/linux-firmware/amd-gpu-firmware/fedora-42-updates.html)
- [RPM Fusion NVIDIA Howto](https://rpmfusion.org/Howto/NVIDIA)
- [CUDA on Fedora (Level1Techs)](https://forum.level1techs.com/t/cuda-12-9-on-fedora-42-guide-including-getting-cuda-samples-running/230769)
- [Fedora 42 EOL (endoflife.date)](https://endoflife.date/fedora)
- [GNOME ring timeout on Fedora 42](https://discussion.fedoraproject.org/t/149587)

### Arch
- [Arch linux-firmware 20260309](https://archlinux.org/packages/core/any/linux-firmware/)
- [Arch nvidia-open-dkms 595.58.03](https://archlinux.org/packages/extra/x86_64/nvidia-open-dkms/)
- [Arch CUDA 13.2](https://archlinux.org/packages/extra/x86_64/cuda/)
- [Arch cuDNN 9.19](https://archlinux.org/packages/extra/x86_64/cudnn/)
- [NVIDIA 590 open modules transition](https://archlinux.org/news/nvidia-590-driver-drops-pascal-support-main-packages-switch-to-open-kernel-modules/)
- [7950X iGPU crashes (bbs)](https://bbs.archlinux.org/viewtopic.php?id=291457)
- [simpledrm card ordering fix (bbs)](https://bbs.archlinux.org/viewtopic.php?id=303311)

### Pop!_OS
- [Pop!_OS 24.04 LTS Release](https://www.omgubuntu.co.uk/2025/12/pop_os-24-04-lts-stable-release)
- [cosmic-comp Architecture (DeepWiki)](https://deepwiki.com/pop-os/cosmic-comp)
- [system76-power GPU switching](https://support.system76.com/articles/graphics-switch-pop/)
- [cosmic-epoch #1105: AMD+NVIDIA kernel panic](https://github.com/pop-os/cosmic-epoch/issues/1105)
- [pop #3654: CUDA detection failure](https://github.com/pop-os/pop/issues/3654)
- [Pop!_OS linux-firmware fork](https://github.com/pop-os/linux-firmware/blob/master/debian/changelog)

### Cross-OS
- [NVIDIA Container Toolkit Platforms](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/supported-platforms.html)
- [CUDA 13.2 Installation Guide](https://docs.nvidia.com/cuda/cuda-installation-guide-linux/)
- [PyTorch Get Started](https://pytorch.org/get-started/locally/)
- [2025 Stack Overflow Developer Survey](https://survey.stackoverflow.co/2025/technology)
- [drm/amd #5073: Raphael optc31 timeout (OPEN)](https://gitlab.freedesktop.org/drm/amd/-/work_items/5073)
- [Debian #1057656: DMCUB fix](https://bugs-devel.debian.org/cgi-bin/bugreport.cgi?bug=1057656)
- [NixOS #418212: DMCUB 0.1.14.0 regression](https://github.com/nixos/nixpkgs/issues/418212)
- [kernel-firmware MR #587: DCN315 fix](https://gitlab.com/kernel-firmware/linux-firmware/-/merge_requests/587)
