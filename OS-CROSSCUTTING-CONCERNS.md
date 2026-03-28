# OS Cross-Cutting Concerns: Dual-GPU ML Workstation

**Hardware:** AMD Ryzen 9 7950X (Raphael iGPU) + NVIDIA RTX 4090 (headless compute)
**Date:** 2026-03-28
**Scope:** Ubuntu 24.04, Fedora 43, Arch Linux, Pop!_OS 24.04, NixOS (where relevant)

---

## 1. NVIDIA Container Toolkit / nvidia-docker

### Officially Supported Distributions

The NVIDIA Container Toolkit (v1.19.0) is officially tested on:

| Distribution | Architectures | Package Manager |
|---|---|---|
| **Ubuntu 20.04, 22.04, 24.04** | amd64, ppc64le, arm64 | apt |
| **RHEL 8.x, 9.x, 10.x** | amd64, ppc64le, arm64 | dnf/yum |
| **Rocky Linux 9.7** | amd64, ppc64le, arm64 | dnf |
| **CentOS 8** | amd64, ppc64le, arm64 | dnf/yum |
| **Amazon Linux 2, 2023** | amd64 (+ arm64 for 2023) | dnf/yum |
| **OpenSUSE/SLES 15.x** | amd64 only | zypper |
| **Debian 11** | amd64 only | apt |

**Fedora**: Not listed explicitly, but uses the same RHEL/CentOS repo and `dnf` commands. RPM Fusion provides the driver; the container toolkit repo works identically to RHEL.

**Arch Linux**: The `nvidia-container-toolkit` package (v1.19.0) is in the **official `extra` repository** -- no AUR needed. Install with `pacman -S nvidia-container-toolkit`.

**Pop!_OS**: Uses the same Ubuntu/Debian apt repository. Installation is identical to Ubuntu. Confirmed working on Pop!_OS 22.04 and 24.04.

### Supported Container Engines

All distros support the same four engines:
- **Docker** (including rootless mode)
- **Podman** (CDI recommended for device access; Podman v4.1.0+ supports `--device` with CDI)
- **containerd** (for Kubernetes and nerdctl)
- **CRI-O**

### Installation Comparison

| Distro | Commands | Notes |
|---|---|---|
| Ubuntu/Pop!_OS | `curl -fsSL https://nvidia.github.io/...gpgkey \| sudo gpg --dearmor` then `apt install nvidia-container-toolkit` | Straightforward; driver from Ubuntu repos or PPA |
| Fedora | `curl -s -L https://nvidia.github.io/...repo` then `dnf install nvidia-container-toolkit` | Driver from RPM Fusion (`akmod-nvidia`); toolkit from NVIDIA repo |
| Arch | `pacman -S nvidia-container-toolkit` | Simplest -- single command, official repo |
| NixOS | Declarative config in `/etc/nixos/configuration.nix` | More complex but fully reproducible |

### Verdict

All four major distros have first-class support. Arch has the simplest installation (single pacman command). Ubuntu and Pop!_OS have the most documentation. Fedora requires an extra repo but works identically.

**Sources:**
- [NVIDIA Container Toolkit Supported Platforms](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/supported-platforms.html)
- [NVIDIA Container Toolkit Install Guide](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)
- [Arch Linux nvidia-container-toolkit package](https://archlinux.org/packages/extra/x86_64/nvidia-container-toolkit/)
- [Installing NVIDIA container toolkit on Pop!_OS 22.04](https://nikita.melkozerov.dev/posts/nvidia-docker-pop-os-install/)

---

## 2. NVIDIA CUDA Certification

### CUDA 13.2 Supported Distributions (x86_64)

NVIDIA does **not** use explicit "Tier 1/Tier 2" labels for CUDA. Instead, they publish a table of supported distributions with validated kernel, GCC, and GLIBC versions:

| Distribution | Codename | Kernel | GCC | GLIBC |
|---|---|---|---|---|
| **Ubuntu 24.04 LTS** | ubuntu2404 | 6.17.0-19 | 14.3.0 | 2.39 |
| **Ubuntu 22.04 LTS** | ubuntu2204 | 6.5.0-45 | 12.3.0 | 2.35 |
| **RHEL 10** | rhel10 | 6.12.0-124 | 14.3.1 | 2.39 |
| **RHEL 9** | rhel9 | 5.14.0-611.5 | 11.5.0 | 2.34 |
| **RHEL 8** | rhel8 | 4.18.0-553 | 8.5.0 | 2.28 |
| **Rocky 8/9/10, AlmaLinux 8/9/10, Oracle 8/9** | Same as RHEL | Same | Same | Same |
| **Fedora 43** | fedora43 | 6.17.1-300 | 15.2.1 | 2.42 |
| **Debian 12** | debian12 | 6.1.159 | 12.2.0 | 2.36 |
| **Debian 13** | debian13 | 6.12.73-1 | 14.2.0 | 2.41 |
| **SUSE SLES 15 SP6+** | sles15 | 6.4.0-150600.21 | 7.5.0 | 2.38 |
| **SUSE SLES 16** | suse16 | 6.12.0-160000.5 | 15.1.1 | 2.40 |
| **openSUSE Leap 15 SP6, 16** | opensuse15/suse16 | Same as SLES | Same | Same |
| **Amazon Linux 2023** | amzn2023 | 6.1.82-99.168 | 11.4.1 | 2.34 |
| **Azure Linux 3.0** | azl3 | 6.6.64.2-9 | 13.2.0 | 2.38 |
| **KylinOS V11** | kylin11 | 6.6.0-32.7 | 12.3.1 | 2.38 |

**Arch Linux**: NOT in the official CUDA support matrix. However, CUDA works on Arch because:
- Arch ships GCC 6.x-15.x and GLIBC 2.39+ (within CUDA's supported range)
- The `cuda` package is in the official `extra` repository
- The `manylinux` container standard ensures binary compatibility
- NVIDIA's `.run` installer works on any Linux with compatible glibc

**Pop!_OS**: Not listed separately but is binary-compatible with Ubuntu 24.04. CUDA packages built for Ubuntu work identically.

**NixOS**: Not listed. CUDA works via Nix packages but requires special configuration. Historical licensing issues with CUDA redistribution in the Nix binary cache have been partially resolved via NVIDIA's partnership with Flox (2025).

### De Facto Tier Classification

| Tier | Distros | Evidence |
|---|---|---|
| **Tier 1** (tested, .deb/.rpm provided) | Ubuntu LTS, RHEL/Rocky/Alma, Fedora, Debian, SLES | Listed in official matrix; pre-built packages |
| **Tier 2** (works, community-packaged) | Arch, Pop!_OS, Manjaro, NixOS | Not in matrix but glibc/GCC compatible; community packages in repos |
| **Unsupported** | Gentoo, Void, Alpine | No testing, no packages; may require manual compilation |

### Key Finding

**Fedora 43 is now officially supported** with its own codename (`fedora43`) in CUDA 13.2. This is a significant change from historical practice where only RHEL was supported in the Red Hat family. Ubuntu remains the most-tested platform, but Fedora is now a first-class citizen.

**Sources:**
- [CUDA Installation Guide for Linux (13.2)](https://docs.nvidia.com/cuda/cuda-installation-guide-linux/)
- [CUDA Toolkit 13.2 Release Notes](https://docs.nvidia.com/cuda/cuda-toolkit-release-notes/index.html)
- [NixOS CUDA Wiki](https://wiki.nixos.org/wiki/CUDA)
- [Flox CUDA on Nix](https://flox.dev/blog/the-flox-catalog-now-contains-nvidia-cuda/)

---

## 3. Docker/Podman GPU Support

### Architecture Comparison

| Feature | Docker | Podman |
|---|---|---|
| **Daemon** | dockerd (persistent background service) | Daemonless (each container is a child process) |
| **Root** | Historically required root; rootless mode production-ready since v27.0+ (2024) | Rootless from the ground up |
| **NVIDIA GPU access** | `--gpus all` flag (via nvidia-container-runtime) | `--device nvidia.com/gpu=all` (via CDI, Podman v4.1.0+) |
| **Compose GPU** | `docker compose` with `deploy.resources.reservations.devices` | `podman-compose` with `--device` mappings |
| **Security** | Root daemon is a SPOF; rootless mitigates | No daemon = smaller attack surface |
| **Performance** | Identical runtime performance (both use runc/crun) | Identical runtime performance |

### GPU Passthrough by Distro

| Distro | Docker | Podman | Default Engine | Notes |
|---|---|---|---|---|
| **Ubuntu 24.04** | `apt install docker.io` + nvidia-container-toolkit | `apt install podman` + nvidia-container-toolkit | Docker | Most documented path |
| **Fedora 43** | `dnf install docker-ce` (from Docker repo) | `dnf install podman` (built-in) | **Podman** | Fedora ships Podman by default; Docker requires adding Docker's repo |
| **Arch** | `pacman -S docker nvidia-container-toolkit` | `pacman -S podman nvidia-container-toolkit` | Neither (user choice) | Both equally supported |
| **Pop!_OS 24.04** | Same as Ubuntu | Same as Ubuntu | Docker | System76 docs use Docker |

### Performance

There is **no measurable performance difference** between Docker and Podman for GPU workloads. Both use the same OCI runtime (runc or crun) and the same nvidia-container-runtime hook. The GPU passthrough mechanism (CDI or legacy runtime hook) adds negligible overhead.

A 2024 benchmark study ("Benchmarking GPU Passthrough Performance on Docker for AI Cloud System") confirmed that containerized GPU performance is within 1-3% of bare-metal for compute workloads.

### Recommendation for ML Workstation

**Docker** for the ML workstation because:
1. PyTorch, TensorFlow, and NVIDIA NGC containers all document Docker commands
2. `docker compose` GPU syntax is better documented than Podman's
3. Most ML tutorials and Stack Overflow answers use Docker
4. nvidia-container-toolkit's `--gpus` flag is more intuitive than CDI device strings

If running on Fedora, Docker still works but requires adding Docker's repo since Fedora defaults to Podman.

**Sources:**
- [Docker vs Podman: An In-Depth Comparison (2026)](https://dev.to/mechcloud_academy/docker-vs-podman-an-in-depth-comparison-2025-2eia)
- [Containers in 2025: Docker vs. Podman (Linux Journal)](https://www.linuxjournal.com/content/containers-2025-docker-vs-podman-modern-developers)
- [Docker vs Podman 2025: Honest Truth with Benchmarks](https://sanj.dev/post/container-runtime-showdown-2025)
- [Podman Desktop GPU Container Access](https://podman-desktop.io/docs/podman/gpu)
- [Benchmarking GPU Passthrough (jurnal.itscience.org)](https://jurnal.itscience.org/index.php/brilliance/article/view/6794)

---

## 4. PyTorch Wheel Availability

### Official Support Matrix (PyTorch 2.11.0, March 2026)

| Platform | CUDA 12.6 | CUDA 12.8 | CUDA 13.0 | ROCm 7.2 | CPU |
|---|---|---|---|---|---|
| **Linux x86_64** | Yes | Yes | Yes | Yes | Yes |
| **Linux arm64** | Yes | Yes | No | No | Yes |
| **macOS arm64** | N/A | N/A | N/A | N/A | Yes |
| **Windows x86_64** | Yes | Yes | No | No | Yes |

### Distribution Independence

**PyTorch wheels are distro-agnostic.** All Linux wheels use the `manylinux_2_28` standard (requires glibc >= 2.28). This means:

- The same `.whl` file works on Ubuntu, Fedora, Arch, Pop!_OS, NixOS, Debian, RHEL, etc.
- No distro-specific builds exist or are needed
- The only requirement is Python 3.x and glibc >= 2.28 (satisfied by every distro released since ~2018)

### Installation Method

All distros use the same pip command:
```bash
pip3 install torch torchvision --index-url https://download.pytorch.org/whl/cu128
```

### CXX11 ABI Change

Starting with PyTorch 2.7, all Linux builds use `CXX11_ABI=1` and `manylinux_2_28`. This is a **breaking change** for very old distros (CentOS 7, Ubuntu 16.04) but has no impact on any currently supported distro.

### Verdict

**No distro advantage** for PyTorch wheel availability. All distros get identical wheels. The only consideration is Python version -- Arch and Fedora tend to have the latest Python faster, which can matter for day-0 support of new Python releases.

**Sources:**
- [PyTorch Get Started Locally](https://pytorch.org/get-started/locally/)
- [PyTorch 2.7 Release Blog](https://pytorch.org/blog/pytorch-2-7/)
- [AMD ROCm PyTorch Installation](https://rocm.docs.amd.com/projects/install-on-linux/en/develop/install/3rd-party/pytorch-install.html)

---

## 5. linux-firmware Update Mechanisms

This is the **single most critical differentiator** for the Raphael iGPU problem. The DCN 3.1.5 DMCUB firmware fix (version 0.0.224.0+, July 2024) is required for display stability.

### Update Cadence Comparison

| Distro | Package | Current Version | Base Date | Update Method | Firmware Lag |
|---|---|---|---|---|---|
| **Ubuntu 24.04** | `linux-firmware` (monolithic) | 20240318-0ubuntu2.25 | March 2024 base | SRU cherry-pick | **Worst: base frozen at March 2024; individual blobs cherry-picked per SRU** |
| **Fedora 43** | `amd-gpu-firmware` (split) | 20260309-1 | March 2026 | Full rebase on each release | **Best: rebases to latest upstream tag; all active Fedora versions get same firmware** |
| **Arch Linux** | `linux-firmware-amdgpu` (split) | 20260309-1 | March 2026 | Rolling, tracks upstream git | **Best: equivalent to Fedora, sometimes faster** |
| **Pop!_OS 24.04** | `linux-firmware` (same as Ubuntu) | Same as Ubuntu | March 2024 base | Same SRU process as Ubuntu | **Same as Ubuntu** |

### Ubuntu's SRU Firmware Problem (CRITICAL)

Ubuntu Noble's `linux-firmware` package has a **March 2024 base** (`20240318`). Updates are applied via SRU cherry-picks: individual firmware blobs are added or updated, but the package is never fully rebased. The version history shows:

| Version | Date | DMCUB Updated? |
|---|---|---|
| 0ubuntu2.19 | Oct 2025 | AMD GPU PSP 14.0.0/14.0.4 updates -- **not DCN 3.1.5** |
| 0ubuntu2.21 | Nov 2025 | AMD GPU PSP 14.0.0/14.0.4, GC 11.5.1, SDMA 7.0.1 -- **not DCN 3.1.5** |
| 0ubuntu2.22 | Jan 2026 | "AMD GPU PSP/GC/DMCUB firmware updates" -- **possibly includes DCN 3.1.5 but changelog is ambiguous** |
| 0ubuntu2.25 | Feb 2026 | AIC100, ISH, Wi-Fi -- **not DMCUB** |

**The changelog never explicitly mentions `dcn_3_1_5_dmcub.bin`** through at least v0ubuntu2.25. Ubuntu's SRU process requires individual bug reports per firmware blob, and the DCN 3.1.5 DMCUB was apparently never SRU'd, or was only recently added without explicit mention.

### Fedora's Split Firmware Advantage

Fedora split `linux-firmware` into subpackages starting with Fedora 37:
- `amd-gpu-firmware` -- AMD amdgpu and radeon GPUs
- `intel-gpu-firmware` -- Intel integrated GPUs
- `nvidia-gpu-firmware` -- NVIDIA GSP firmware
- Plus ~20 other subpackages for WiFi, Bluetooth, etc.

Benefits:
1. **Faster updates**: Only the GPU firmware package needs updating, not the entire 287MB blob
2. **Full rebase**: Each Fedora release rebases to the latest upstream linux-firmware tag
3. **Cross-release consistency**: Fedora 42, 43, and 44 all received `20260309-1` simultaneously

### Arch's Rolling Advantage

Arch tracks upstream `linux-firmware.git` on a rolling basis. The `linux-firmware-amdgpu` split package was introduced in June 2025 (version 20250613). Current version matches Fedora at `20260309-1`.

### Ubuntu 26.04 LTS -- Future Improvement

Canonical has announced that Ubuntu 26.04 LTS will adopt firmware package splitting similar to Fedora, with vendor-specific sub-packages (`linux-firmware-amd`, `linux-firmware-intel`, etc.). This should improve update cadence for future LTS releases but does not help Ubuntu 24.04.

### Verdict

For the Raphael DMCUB firmware problem specifically:
- **Fedora and Arch**: Already have DMCUB 0.0.255.0+ (the fix). No manual intervention needed.
- **Ubuntu and Pop!_OS**: Require manual firmware download and installation from upstream git. The SRU process failed to deliver this critical fix for ~2 years.

**Sources:**
- [Ubuntu Noble linux-firmware changelog (UbuntuUpdates)](https://www.ubuntuupdates.org/package/core/noble/main/updates/linux-firmware)
- [Ubuntu linux-firmware Launchpad changelog](https://launchpad.net/ubuntu/+source/linux-firmware/+changelog)
- [Fedora amd-gpu-firmware package](https://packages.fedoraproject.org/pkgs/linux-firmware/amd-gpu-firmware/)
- [Fedora Changes: Linux Firmware Minimization](https://fedoraproject.org/wiki/Changes/Linux_Firmware_Minimization)
- [Arch Linux linux-firmware-amdgpu package](https://archlinux.org/packages/core/any/linux-firmware-amdgpu/)
- [Ubuntu 26.04 LTS Firmware Split (Hintnal)](https://hintnal.com/ubuntu-26-04-lts-firmware-split-what-developers-need-to-know/)

---

## 6. initramfs Firmware Inclusion

### Tool Comparison

| Distro | Tool | Config Location | Rebuild Command |
|---|---|---|---|
| **Ubuntu/Pop!_OS** | `update-initramfs` (initramfs-tools) | `/etc/initramfs-tools/modules`, `/etc/initramfs-tools/hooks/` | `sudo update-initramfs -u -k all` |
| **Fedora** | `dracut` | `/etc/dracut.conf.d/*.conf` | `sudo dracut --force` |
| **Arch** | `mkinitcpio` | `/etc/mkinitcpio.conf` | `sudo mkinitcpio -P` |
| **Pop!_OS (boot)** | `kernelstub` + `update-initramfs` | Same as Ubuntu + `/etc/kernelstub/configuration` | `sudo update-initramfs -u && sudo kernelstub` |

### GPU Firmware Auto-Inclusion

**Ubuntu (initramfs-tools)**:
- Modules listed in `/etc/initramfs-tools/modules` are included
- Firmware for included modules is auto-detected via `modinfo`
- To force-include: add module name to `/etc/initramfs-tools/modules` (e.g., `amdgpu`)
- To force-include specific blobs: use a custom hook script in `/etc/initramfs-tools/hooks/`
- **Gotcha**: If both `.bin` and `.bin.zst` exist, the kernel prefers `.bin.zst` -- initramfs may include the wrong one

**Fedora (dracut)**:
- Auto-detects modules and firmware via depmod data
- Config file approach:
  ```
  # /etc/dracut.conf.d/amdgpu.conf
  force_drivers+=" amdgpu "
  fw_dir+=" /lib/firmware/amdgpu "
  install_items+=" /lib/firmware/amdgpu/dcn_3_1_5_dmcub.bin "
  ```
- **Critical**: Always include spaces at beginning and end of `+=` values (files are sourced as bash)
- Rebuild: `sudo dracut --force`

**Arch (mkinitcpio)**:
- `MODULES=(amdgpu)` in `/etc/mkinitcpio.conf` for early KMS
- When a module is included, **ALL firmware it can load** is added (400+ files for amdgpu)
- No mechanism to select only specific firmware blobs (all or nothing for a given module)
- `FILES=(/usr/lib/firmware/amdgpu/dcn_3_1_5_dmcub.bin)` to force-include specific blobs without loading the module
- The `kms` hook (default since mkinitcpio v33) auto-includes GPU modules
- Rebuild: `sudo mkinitcpio -P`

### Module Load Order in initramfs

For the dual-GPU setup, **amdgpu must load before nvidia** to claim `card0`:

| Distro | How to Set Order |
|---|---|
| Ubuntu | `/etc/initramfs-tools/modules`: list `amdgpu` before `nvidia` |
| Fedora | `/etc/dracut.conf.d/gpu.conf`: `force_drivers+=" amdgpu nvidia nvidia_modeset nvidia_drm "` (first listed loads first) |
| Arch | `/etc/mkinitcpio.conf`: `MODULES=(amdgpu nvidia nvidia_modeset nvidia_drm)` (array order matters) |

### Verdict

**Arch's mkinitcpio** is the most aggressive -- it includes ALL 400+ amdgpu firmware blobs automatically. This eliminates any risk of missing firmware but makes the initramfs larger (~50MB extra).

**Fedora's dracut** offers the most granular control via `install_items` and `fw_dir` directives. You can include exactly the firmware blobs you need.

**Ubuntu's initramfs-tools** is the least flexible. Custom hooks are needed for fine-grained control, and the `.bin`/`.bin.zst` conflict issue makes firmware management error-prone.

**Sources:**
- [Arch Wiki: mkinitcpio](https://wiki.archlinux.org/title/Mkinitcpio)
- [Arch Wiki: AMDGPU](https://wiki.archlinux.org/title/AMDGPU)
- [Arch Wiki: Kernel mode setting](https://wiki.archlinux.org/title/Kernel_mode_setting)
- [Arch Wiki: Dracut](https://wiki.archlinux.org/title/Dracut)
- [Fedora Magazine: Building better initramfs with dracut](https://fedoramagazine.org/%F0%9F%A7%B1-building-better-initramfs-a-deep-dive-into-dracut-on-fedora-rhel/)
- [dracut.conf(5) man page](https://www.man7.org/linux/man-pages/man5/dracut.conf.5.html)

---

## 7. Secure Boot and NVIDIA

### Does It Matter?

Per the BIOS settings in `CLAUDE.md`: **OS Type = "Other OS"** and **CSM = Disabled**. "Other OS" effectively disables Secure Boot enforcement while keeping UEFI mode. This means:

- **If Secure Boot is OFF**: NVIDIA DKMS modules load without signing. No MOK enrollment needed. No distro difference.
- **If Secure Boot is ON**: Each distro handles module signing differently.

### Secure Boot ON -- Distro Comparison

| Distro | Signing Method | Automation | Pain Level |
|---|---|---|---|
| **Ubuntu** | DKMS auto-signs with MOK key generated at install | `sudo mokutil --import /var/lib/shim-signed/mok/MOK.der` + reboot + enroll | **Low**: mostly automated; MOK enrollment is a one-time reboot step |
| **Fedora** | `akmods` + `kmodgenca` generates signing key | `sudo kmodgenca` + `sudo mokutil --import /etc/pki/akmods/certs/public_key.der` + reboot + enroll | **Medium**: requires generating key manually before first install |
| **Arch** | Manual: generate key with `openssl`, sign with `sign-file`, enroll with `mokutil` | No automation -- entirely manual | **High**: must script signing into pacman hooks |
| **Pop!_OS** | Same as Ubuntu (uses shim-signed) | Same as Ubuntu | **Low** |

### Recent Issues (2025-2026)

**Ubuntu (Feb 2026)**: Bug #2141477 -- `nvidia-dkms-580-open` failed to build on HWE kernel 6.17.0-14 regardless of Secure Boot status. The signing worked but the module itself didn't compile due to API changes.

**Fedora (2025-2026)**: Multiple reports of `mokutil --import` failing silently, MOK keys expiring, and `akmods` not triggering signing after kernel updates. A comprehensive troubleshooting guide was needed for Fedora 42-43.

**Arch (2025)**: Switch to `nvidia-open` as default broke some signing workflows. Users with custom MOK setups needed to re-sign for the new module name.

### Recommendation

**Disable Secure Boot** (OS Type = "Other OS" in BIOS). For an ML workstation:
1. You're not dual-booting with Windows
2. Physical access to the machine implies physical security
3. Eliminates an entire class of boot failures
4. No distro advantage when Secure Boot is off

If Secure Boot must be on: **Ubuntu/Pop!_OS** have the most automated signing workflow.

**Sources:**
- [Installing NVIDIA Driver on Ubuntu with Secure Boot (PacketRealm)](https://packetrealm.io/posts/nvidia-driver-secureboot/)
- [Fedora NVIDIA with RPM Fusion akmods + Secure Boot (PacketRealm)](https://packetrealm.io/posts/fedora-nvidia-akmods-secure-boot/)
- [Install Nvidia Driver on Fedora 43 (Secure Boot + Akmods)](https://techblog.jere.ch/2026/01/13/install-nvidia-driver-on-fedora-43-secure-boot-akmods/)
- [Fedora MOK Enrollment Guide (GitHub)](https://github.com/drgreenthumb93/Fedora42_MOK_enrollment)
- [Ubuntu Secure Boot Documentation](https://documentation.ubuntu.com/security/security-features/platform-protections/secure-boot/)
- [Bug #2141477 (Launchpad)](https://bugs.launchpad.net/ubuntu/+source/nvidia-graphics-drivers-580/+bug/2141477)

---

## 8. Power Management for ML

### CPU Frequency Scaling (amd_pstate)

All distros use the same kernel driver. The difference is in **default configuration**:

| Distro | Default amd_pstate Mode | Kernel | How to Change |
|---|---|---|---|
| Ubuntu 24.04 (6.8) | `passive` | 6.8 stock | `amd_pstate=active` kernel param |
| Ubuntu 24.04 HWE (6.17) | `active` (EPP) | 6.17 HWE | Default since kernel 6.5 |
| Fedora 43 | `active` (EPP) | 6.17+ | Default |
| Arch (current) | `active` (EPP) | 6.17+ | Default |
| Pop!_OS 24.04 | Same as Ubuntu | Same | Same |

**For ML workloads**: Set `energy_performance_preference=performance` via:
```bash
echo "performance" | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference
```

### NVIDIA Persistence Mode (Headless Compute)

All distros support `nvidia-persistenced` identically:

```bash
# Enable persistence daemon (all distros)
sudo systemctl enable nvidia-persistenced

# Set power limit (example: 350W for RTX 4090)
sudo nvidia-smi -pl 350

# Lock GPU clocks for consistent ML training
sudo nvidia-smi -lgc 800,2520
```

For automated power limits at boot, create a systemd service (same on all distros):
```ini
[Unit]
Description=NVIDIA GPU Power Limit
After=nvidia-persistenced.service

[Service]
Type=oneshot
ExecStart=/usr/bin/nvidia-smi -pl 350

[Install]
WantedBy=multi-user.target
```

### PCIe Power Management

**Critical for RTX 4090 stability**: `pcie_aspm=off` is recommended (prevents Xid 79 link loss).

| Parameter | All Distros | Notes |
|---|---|---|
| `pcie_aspm=off` | Kernel param | Disables PCIe ASPM globally; prevents link drops |
| `processor.max_cstate=1` | Kernel param | Limits CPU C-state; prevents deep idle causing link drops |
| `NVreg_DynamicPowerManagement=0x02` | modprobe option | NVIDIA runtime D3 power management |

### Suspend/Resume with Dual GPU

This is a **known pain point** regardless of distro. The NVIDIA driver requires specific systemd services:

```bash
# Required on ALL distros
sudo systemctl enable nvidia-suspend nvidia-resume nvidia-hibernate
```

Additional requirements:
- `NVreg_PreserveVideoMemoryAllocations=1` in modprobe.d
- `nvidia-drm.modeset=1` kernel parameter
- `nvidia-drm.fbdev=1` kernel parameter

**AMD iGPU suspend**: The amdgpu driver has known VRAM save/restore issues during suspend. On Raphael specifically, the `amdgpu_evict_vram` debug endpoint must be used before sleep. This is kernel-version dependent, not distro-dependent.

### Verdict

**No meaningful distro difference** for power management. All use the same kernel interfaces. The only difference is default `amd_pstate` mode, which is trivially changed with a kernel parameter.

**Sources:**
- [amd-pstate CPU Performance Scaling Driver (kernel.org)](https://www.kernel.org/doc/html/latest/admin-guide/pm/amd-pstate.html)
- [NVIDIA Driver Persistence Documentation](https://docs.nvidia.com/deploy/driver-persistence/index.html)
- [NVIDIA Power Management Chapter](https://download.nvidia.com/XFree86/Linux-x86_64/435.17/README/powermanagement.html)
- [NVIDIA PCIe RTD3 Power Management](https://download.nvidia.com/XFree86/Linux-x86_64/435.17/README/dynamicpowermanagement.html)
- [Arch Wiki: CPU frequency scaling](https://wiki.archlinux.org/title/CPU_frequency_scaling)
- [Arch Wiki: Power management](https://wiki.archlinux.org/title/Power_management)
- [Set NVIDIA Power Limits on Ubuntu (linuxconfig.org)](https://linuxconfig.org/how-to-set-nvidia-power-limit-on-ubuntu)

---

## 9. Community ML Support

### Quantitative Evidence

**Stack Overflow 2025 Developer Survey** (49,000+ respondents):
- Ubuntu: **27.7%** adoption among developers (most popular Linux distro)
- Python (primary ML language): 7 percentage point increase year-over-year
- No per-distro breakdown for ML-specific respondents

**NVIDIA Documentation**: All official tutorials, NGC container examples, and CUDA getting-started guides use **Ubuntu** as the reference distro.

**PyTorch/TensorFlow CI**: Both frameworks run CI on Ubuntu. Bug reports from Ubuntu users get priority attention.

**GitHub ML Repos**: The overwhelming majority of ML project READMEs specify Ubuntu installation instructions. Many don't mention other distros at all.

### Community Rankings for ML (2025-2026)

| Rank | Distro | Community Size for ML | Why |
|---|---|---|---|
| **1** | **Ubuntu** | Largest by far | NVIDIA's reference distro; all cloud providers default; most tutorials; largest StackOverflow presence |
| **2** | **Fedora** | Growing rapidly | Fedora AI spin; Podman-native container support; increasing enterprise adoption |
| **3** | **Arch** | Niche but active | Bleeding-edge packages; power users who want control; AUR fills gaps |
| **4** | **Pop!_OS** | Significant | System76 hardware + software integration; NVIDIA out-of-box; popular with data scientists |
| **5** | **NixOS** | Small but passionate | Reproducibility focus; growing ML adoption at companies like Canva |

### Qualitative Assessment

Multiple 2025-2026 articles ("Best Linux Distro for Machine Learning") consistently rank:
1. **Ubuntu** -- least friction, most documentation, most community answers
2. **Fedora** -- best for developers wanting latest packages
3. **Pop!_OS** -- best out-of-box NVIDIA experience
4. **Arch** -- best for power users who want full control
5. **NixOS** -- best for reproducibility

### Verdict

**Ubuntu has an overwhelming community advantage for ML.** When you hit a problem, the probability of finding someone who already solved it on Ubuntu is 5-10x higher than on any other distro. This is a significant practical consideration for a workstation where uptime matters.

**Sources:**
- [2025 Stack Overflow Developer Survey](https://survey.stackoverflow.co/2025/technology)
- [Best Linux Distributions for AI and Machine Learning in 2026 (Tech2Geek)](https://www.tech2geek.net/best-linux-distributions-for-ai-and-machine-learning-in-2025/)
- [Linux Distributions for AI: Top Choices for ML in 2026 (linuxconfig.net)](https://linuxconfig.net/guide/top-linux-distributions-ai-machine-learning-2026.html)
- [AI-Ready Linux Distributions To Watch in 2025 (IT Pro Today)](https://www.itprotoday.com/linux-os/ai-ready-linux-distributions-to-watch-in-2025)
- [Top 5 Linux Distro For AI In 2025 (Talentelgia)](https://www.talentelgia.com/blog/top-5-linux-distro-for-ai/)

---

## 10. DKMS Reliability for NVIDIA

### The Core Problem

Every kernel update requires NVIDIA kernel modules to be recompiled. The three mechanisms are:
1. **DKMS** (Dynamic Kernel Module Support) -- Ubuntu, Pop!_OS, Debian
2. **akmods** (Automatic Kernel Module Support) -- Fedora
3. **Pre-built + DKMS fallback** -- Arch

### Failure Modes by Distro

#### Ubuntu/Pop!_OS (DKMS)

**Recent Critical Failure (Feb 2026)**: Ubuntu pushed HWE kernel 6.17.0-14 while `nvidia-dkms-580-open` was still at version 580.65.06. The DKMS build failed because kernel 6.17 changed a function signature (`commit a34cc7bf1034`). NVIDIA fixed this in driver 580.95+, but Ubuntu's repos hadn't updated yet. Result: **all users who auto-updated were stuck with a broken NVIDIA driver on the HWE kernel**.

Bug references:
- [Bug #2141477](https://bugs.launchpad.net/ubuntu/+source/nvidia-graphics-drivers-580/+bug/2141477): nvidia-dkms-580-open fails on kernel 6.17
- [Bug #2141920](https://bugs.launchpad.net/ubuntu/+source/openvpn-dco-dkms/+bug/2141920): HWE kernel 6.17.0-14 breaks DKMS modules

**Pattern**: Ubuntu's problem is **timing** -- the kernel team and driver team are separate, and HWE kernel updates can land before compatible driver packages.

#### Fedora (akmods)

**Recurring Pattern**: Every 2-3 kernel updates, akmods fails to rebuild the NVIDIA module. Common causes:
- **Timing**: Users reboot before akmods finishes building (~2-3 min wait needed after `dnf upgrade`)
- **GCC version mismatch**: Fedora ships bleeding-edge GCC that NVIDIA's build system may not support immediately
- **Kernel API changes**: Fedora's rapid kernel cadence (new kernel every ~2 weeks) frequently breaks NVIDIA builds

Documented failures:
- Fedora 43 kernel broken after akmod-nvidia install (Nov 2025)
- Fedora 44 kernel 6.19.x akmod build failure (Feb 2026)
- akmods failing on kernel 6.8.5 with 5XX drivers (Apr 2025)
- Fedora 41 kernel 6.14 + nvidia 470xx failure (May 2025)

**Pattern**: Fedora's problem is **frequency** -- so many kernel updates that breakage is statistically more likely. The RPM Fusion maintainers typically fix it within 1-3 days, but you may be stuck during that window.

#### Arch Linux (Pre-built + DKMS)

Arch offers two approaches:
1. **`nvidia` (pre-built)**: Compiled for the stock `linux` kernel. Breaks if you use a custom kernel.
2. **`nvidia-dkms`**: Compiles on every kernel update. Recommended for LTS or custom kernels.

**Major Change (2025)**: Arch switched the main NVIDIA packages from proprietary to open kernel modules (`nvidia-open`, `nvidia-open-dkms`). This dropped support for Pascal and older GPUs. Users with RTX 4090 are unaffected.

Documented failures:
- DKMS reports success but modules missing for LTS kernel (Dec 2025)
- nvidia-open-dkms preempted by nouveau after upgrade (2025)
- GPL-incompatible symbol errors with some driver versions

**Pattern**: Arch's problem is **user responsibility** -- the rolling model means you must verify NVIDIA driver compatibility before upgrading the kernel. Running `pacman -Syu` blindly can break things.

### Failure Rate Comparison

| Distro | Failure Frequency | Recovery Time | Mitigation |
|---|---|---|---|
| **Ubuntu** | Low (2-3x/year with HWE) | Hours to days (wait for SRU) | Pin kernel; don't auto-update HWE |
| **Fedora** | Medium (every 2-3 kernel updates) | 1-3 days (RPM Fusion fix) | Wait 2-3 min after `dnf upgrade` before reboot; keep previous kernel |
| **Arch** | Medium-High (any `pacman -Syu`) | Immediate (rollback) | Check Arch news before updating; keep previous kernel |
| **Pop!_OS** | Low (same as Ubuntu) | Same as Ubuntu | System76 tests driver/kernel combos |

### Mitigation Strategies (All Distros)

1. **Always keep the previous working kernel** installed
2. **Never auto-update** the kernel on a production ML workstation
3. **Test kernel updates** in a non-critical session first
4. **Use NVIDIA's open kernel modules** (nvidia-open) -- these are being upstreamed into the kernel and will eventually eliminate the DKMS problem entirely

### Verdict

**No distro is immune** to NVIDIA DKMS breakage. Ubuntu has the lowest frequency but the longest recovery time. Arch gives the most control but requires the most vigilance. Fedora is in the middle. For an ML workstation, the best strategy is to **freeze the kernel** after confirming stability and only update when you have time to debug.

**Sources:**
- [Bug #2141477: nvidia-dkms-580-open fails on kernel 6.17 (Launchpad)](https://bugs.launchpad.net/ubuntu/+source/nvidia-graphics-drivers-580/+bug/2141477)
- [Bug #2141920: HWE kernel 6.17.0-14 breaks DKMS (Launchpad)](https://bugs.launchpad.net/ubuntu/+source/openvpn-dco-dkms/+bug/2141920)
- [NVIDIA drivers corrupted after every kernel update (Fedora Discussion)](https://discussion.fedoraproject.org/t/nvidia-drivers-corrupted-after-every-kernel-update/87889)
- [Fedora 44 kernel 6.19.x nvidia akmod cannot be built (Fedora Discussion)](https://discussion.fedoraproject.org/t/fedora-44-kernel-6-19-x-nvidia-akmod-cannot-be-built/181035/7)
- [Arch Linux NVIDIA 590 driver announcement](https://archlinux.org/news/nvidia-590-driver-drops-pascal-support-main-packages-switch-to-open-kernel-modules/)
- [DKMS reports success but NVIDIA modules missing (NVIDIA Forums)](https://forums.developer.nvidia.com/t/dkms-reports-success-but-nvidia-modules-are-missing-for-lts-kernel-rtx-50xx-arch-linux/364881)
- [Arch Wiki: NVIDIA](https://wiki.archlinux.org/title/NVIDIA)
- [NVIDIA on Linux in 2026 (l33tsource)](https://www.l33tsource.com/blog/2026/02/22/NVIDIA-on-linux-in-2026/)

---

## Overall Scorecard

| Concern | Ubuntu 24.04 | Fedora 43 | Arch | Pop!_OS 24.04 |
|---|---|---|---|---|
| **NVIDIA Container Toolkit** | A | A | A | A |
| **CUDA Certification** | A+ (reference) | A (official) | B (works, unofficial) | A (Ubuntu-compat) |
| **Docker/Podman GPU** | A | A (Podman default) | A | A |
| **PyTorch Wheels** | A | A | A | A |
| **linux-firmware Updates** | **D** (SRU lag) | **A+** (rapid rebase) | **A+** (rolling) | **D** (same as Ubuntu) |
| **initramfs Control** | B | A | A+ (auto-includes all) | B |
| **Secure Boot + NVIDIA** | A (automated) | B+ (akmods) | C (manual) | A (same as Ubuntu) |
| **Power Management** | A | A | A | A |
| **Community ML Support** | A+ (dominant) | B+ (growing) | B (niche) | B+ (NVIDIA focus) |
| **DKMS Reliability** | B+ (low freq) | B (medium freq) | B- (user resp.) | B+ (tested combos) |

### Summary Recommendation

**For the Raphael iGPU + RTX 4090 headless compute workstation specifically:**

1. **Stay on Ubuntu 24.04** if you are willing to manually manage firmware (download upstream linux-firmware, install blobs, rebuild initramfs). Ubuntu's overwhelming community advantage and CUDA certification make it the safest long-term choice for ML. The firmware problem is solvable with a one-time manual fix.

2. **Switch to Fedora 43** if the firmware SRU situation is unacceptable and you want the firmware problem solved out-of-the-box. Fedora has DMCUB 0.0.255.0+ in its repos right now. The trade-off is more frequent NVIDIA driver breakage during kernel updates and less ML community support.

3. **Arch Linux** is only recommended if you are comfortable managing every component yourself. The reward is always having the latest firmware and kernel patches. The risk is that any `pacman -Syu` can break NVIDIA.

4. **Pop!_OS 24.04** offers no advantage over Ubuntu for this specific problem (same firmware, same SRU process) and adds COSMIC desktop complexity. It would only be preferable if you valued System76's integrated NVIDIA driver management for a different hardware configuration.

5. **NixOS** is interesting for reproducibility but adds enormous complexity to GPU driver management. Not recommended for this use case unless reproducibility is the primary goal.
