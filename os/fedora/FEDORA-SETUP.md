# Fedora 43 KDE — ML Workstation Setup Guide

AMD Ryzen 9 7950X (Raphael iGPU, DCN 3.1.5) + NVIDIA RTX 4090 (headless)
Dual-boot with Windows 11 on Samsung SSD 990 PRO 2TB

---

## Overview

`fedora43-kde-ml.ks` is a fully automated Anaconda Kickstart file that installs
Fedora 43 KDE Plasma 6 alongside Windows on the same NVMe drive. It:

- Preserves Windows partitions (sda1–sda4) exactly as-is
- Reformats the existing Linux partitions (sda5–sda9) for Fedora
- Installs KDE Plasma 6 with SDDM (Wayland session at login)
- Configures the AMD iGPU for display; NVIDIA RTX 4090 headless compute only
- Installs RPM Fusion, akmod-nvidia, CUDA toolkit, Docker CE, nvidia-container-toolkit
- Applies all Raphael DCN 3.1.5 display stability kernel parameters
- Writes `ml-verify-gpu` and `ml-check-firmware` diagnostic scripts

---

## Why Fedora 43 KDE for This Hardware

| Concern | Ubuntu 24.04 | Fedora 43 KDE |
|---------|-------------|---------------|
| Kernel | 6.8 GA (missing all 6 DCN31 patches) | 6.17+ (all patches included natively) |
| linux-firmware | 20240318 (DMCUB 0.0.15.0 — critically stale) | 20260309 (DMCUB 0.1.53.0) |
| KDE Plasma | Requires PPA (Plasma 5 stock) | Plasma 6 native, no PPA |
| Display Manager | GDM (gnome-shell crash risk) | SDDM (safe, no gnome-shell) |
| Mesa | 24.0.4 (no RDNA2 APU fixes) | 25.x (Mesa 25 + Raphael fixes) |
| NVIDIA driver | nvidia-headless packages | akmod-nvidia (RPM Fusion) |
| DMUB firmware hook | Manual (MR#587 not included) | Included in linux-firmware |

The core difference: Fedora 43's linux-firmware ships DMCUB 0.1.53.0, which
includes the critical display state machine fixes documented in Debian #1057656.
Ubuntu 24.04's stock firmware (0.0.15.0) predates all known fixes and is the
primary driver of the intermittent optc31_disable_crtc timeout crash loop.

---

## Pre-Installation Checklist

### BIOS Settings (ASUS ROG Crosshair X670E Hero)

Verify these settings before installing. Fedora's kernel parameters assume
the iGPU is forced active and GFXOFF is disabled.

**TIER 1 — MUST SET:**

| Setting | Path | Value |
|---------|------|-------|
| Integrated Graphics | Advanced > NB Configuration | Force |
| IGFX Multi-Monitor | Advanced > NB Configuration | Enabled |
| Primary Video Device | Advanced > NB Configuration | IGFX Video |
| UMA Frame Buffer Size | Advanced > AMD CBS > NBIO > GFX Configuration | 2G (or 4G) |
| GFXOFF | Advanced > AMD CBS > NBIO > SMU Common Options | Disabled |
| Above 4G Decoding | Advanced > PCI Subsystem Settings | Enabled |
| Re-Size BAR | Advanced > PCI Subsystem Settings | Enabled |
| IOMMU | Advanced > AMD CBS (root) | Enabled |
| CSM | Boot > CSM Configuration | Disabled |

**TIER 2 — STABILITY:**

| Setting | Path | Value |
|---------|------|-------|
| CPU PCIE ASPM Mode | Advanced > Onboard Devices Configuration | Disabled |
| Global C-State Control | Advanced > AMD CBS (root) | Disabled |
| D3Cold Support | Advanced > AMD PBS > Graphics Features | Disabled |
| Fast Boot | Boot | Disabled |

### Partition Layout Verification

Boot from a Fedora Live USB (do not start the installer yet), open a terminal:

```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT
```

Confirm:
- The Samsung 990 PRO shows as `nvme0n1` (or `sda` — note which)
- Partitions 1-4 are Windows (EFI, MSR, NTFS, NTFS)
- Partitions 5-9 are the former Ubuntu partitions (safe to reformat)

If the device is `nvme0n1`, you must edit the Kickstart file before use.
Search and replace:
- `sda` → `nvme0n1`
- `sdaN` → `nvme0n1pN` (e.g., `sda5` → `nvme0n1p5`)

---

## Using the Kickstart File

### Option A: HTTP Server (Recommended)

1. Place `fedora43-kde-ml.ks` on an HTTP server (or use Python's built-in):
   ```bash
   cd /path/to/kickstart/dir
   python3 -m http.server 8000
   ```
2. Boot the Fedora 43 KDE Spin ISO
3. At the GRUB boot menu, press **Tab** (legacy) or **E** (UEFI) to edit
4. Find the line starting with `linux` or `linuxefi`
5. Append at the end of that line:
   ```
   inst.ks=http://YOUR-SERVER-IP:8000/fedora43-kde-ml.ks
   ```
6. Press **Ctrl+X** or **Enter** to boot

### Option B: USB Drive

1. Copy `fedora43-kde-ml.ks` to a USB drive formatted as FAT32 (not the installer USB)
2. Boot the Fedora 43 KDE Spin ISO
3. At the GRUB boot menu, press **E**
4. Append to the `linuxefi` line:
   ```
   inst.ks=hd:sdb1:/fedora43-kde-ml.ks
   ```
   (Replace `sdb1` with the actual device/partition of your USB drive)
5. Press **Ctrl+X** to boot

### Option C: Build into ISO (Advanced)

Use `lorax` or `mkksiso` (from the `pykickstart` package) to embed the
Kickstart into a custom ISO:

```bash
mkksiso fedora43-kde-ml.ks Fedora-KDE-Live-x86_64-43-*.iso fedora43-kde-ml.iso
```

Boot the resulting ISO directly.

---

## Installation Process

The install is fully unattended (~20-40 minutes depending on network speed):

1. Anaconda reads the Kickstart, partitions disk, installs packages
2. `%post` script runs: configures GRUB, modprobe, SDDM, NVIDIA, Docker
3. System reboots automatically

**Do NOT interrupt the first boot.** The `akmod-nvidia` service builds the
NVIDIA kernel module on first boot (2-3 minutes). You will see a text splash
screen during this time; this is normal.

---

## Post-Install Steps

### Step 1: Verify AMD DRI Path (CRITICAL)

KWin's `KWIN_DRM_DEVICES` environment variable must point to the correct
AMD iGPU DRI device. The path set in the Kickstart uses PCI address
`0000:6c:00.0` (Raphael iGPU on X670E Hero), but verify it:

```bash
ls -la /dev/dri/by-path/
```

Expected output (addresses will match your board's PCI assignment):
```
lrwxrwxrwx ... pci-0000:00:08.1-card -> ../card1
lrwxrwxrwx ... pci-0000:6c:00.0-card -> ../card0   <-- AMD Raphael (use this)
lrwxrwxrwx ... pci-0000:01:00.0-card -> ../card1   <-- or NVIDIA (ignore)
```

The AMD Raphael iGPU typically appears at PCI address `0000:6c:00.0` on AM5
X670E boards, but this varies. If it differs, update:

```bash
# Find the correct AMD card path
AMD_PATH=$(ls -la /dev/dri/by-path/ | grep -v nvidia | grep card | head -1 | awk '{print $9}')
echo "AMD DRI path: /dev/dri/by-path/${AMD_PATH}"

# Update /etc/environment
sudo sed -i "s|KWIN_DRM_DEVICES=.*|KWIN_DRM_DEVICES=/dev/dri/by-path/${AMD_PATH}|" /etc/environment

# Update the KDE plasma env file
sudo sed -i "s|KWIN_DRM_DEVICES=.*|export KWIN_DRM_DEVICES=/dev/dri/by-path/${AMD_PATH}|" \
    /etc/xdg/plasma-workspace/env/ml-workstation.sh
```

Log out and back in after updating.

### Step 2: Wait for akmod-nvidia Build

Check the NVIDIA module build status:

```bash
# Check if akmods finished building
systemctl status akmods.service

# Or directly check if nvidia.ko is present
modinfo nvidia 2>/dev/null | grep filename

# If not built yet, force it:
sudo akmods --force --rebuild
sudo dracut --force
sudo reboot
```

### Step 3: Run Verification Script

```bash
sudo ml-verify-gpu
```

Expected output:
```
1. DRM Card Assignment
   [PASS] card0 driver is amdgpu (display)

2. amdgpu Module Parameters
   [PASS] sg_display=0 (contiguous VRAM for display)

3. NVIDIA Driver (RTX 4090 Headless)
   [PASS] RTX 4090 detected
   [PASS] NVIDIA display_active=Disabled (headless)
   [PASS] NVIDIA display_mode=Disabled (headless)

...
Results: PASS=N  WARN=0  FAIL=0
```

### Step 4: Check Firmware Status

```bash
sudo ml-check-firmware
```

Verify:
- DMCUB firmware loads **once** (if it loads 3-4 times, the crash loop is active)
- No firmware file conflicts (both `.bin` and `.bin.zst` for the same file)
- `sg_display = 0`

### Step 5: Verify Multi-Display

Connect all monitors to the AMD iGPU (HDMI/DisplayPort on the Ryzen CPU's
video output, NOT the RTX 4090). Open KDE Display Configuration:

```bash
# From a terminal in KDE
kscreen-doctor --outputs
```

All displays should enumerate under amdgpu. If the RTX 4090 appears as an
active display device in KWin, check `KWIN_DRM_DEVICES` again.

### Step 6: Verify NVIDIA Headless Compute

```bash
# Basic GPU info
nvidia-smi

# CUDA test
python3 -c "import torch; print(torch.cuda.is_available()); print(torch.cuda.get_device_name(0))"

# Docker with NVIDIA GPU
docker run --rm --gpus all nvidia/cuda:12.0-base nvidia-smi
```

---

## Verification Commands Reference

```bash
# Kernel version (should be 6.17+)
uname -r

# amdgpu parameters
cat /sys/module/amdgpu/parameters/sg_display      # should be 0
cat /sys/module/amdgpu/parameters/ppfeaturemask   # should be 0xfffd7fff
cat /sys/module/amdgpu/parameters/gfx_off         # should be 0

# Display on AMD iGPU
glxinfo | grep "OpenGL renderer"
# Expected: AMD Radeon Graphics (raphael, LLVM ...)

# NVIDIA headless
nvidia-smi --query-gpu=name,display_active,display_mode --format=csv

# DRM card assignment
for card in /sys/class/drm/card[0-9]; do
    vendor=$(cat "$card/device/vendor" 2>/dev/null)
    driver=$(basename "$(readlink "$card/device/driver" 2>/dev/null)")
    echo "$(basename $card): vendor=$vendor driver=$driver"
done
# card0 should be 0x1002 (AMD), card1 should be 0x10de (NVIDIA)

# SDDM enabled
systemctl is-enabled sddm.service

# Docker with GPU
docker info | grep -i runtime
docker run --rm --gpus all nvidia/cuda:12.0-base nvidia-smi

# CUDA path
which nvcc
nvcc --version

# Kernel parameters active
cat /proc/cmdline | tr ' ' '\n' | grep -E 'amdgpu|nvidia|iommu|pcie'

# No DCN errors since boot
dmesg | grep -i "REG_WAIT timeout"  # should be empty
dmesg | grep -i "ring.*timeout"     # should be empty
dmesg | grep -i "GPU reset"         # should be empty

# DMUB firmware loaded once
dmesg | grep "Loading DMUB firmware"  # should appear exactly once
```

---

## Troubleshooting

### NVIDIA module not building

```bash
# Check akmod build log
sudo journalctl -u akmods.service -f

# Force rebuild
sudo akmods --force --rebuild
sudo dracut --force
sudo reboot
```

### KWin compositor not starting / black screen

This is usually because `KWIN_DRM_DEVICES` points to a non-existent path.

```bash
# Check what paths exist
ls -la /dev/dri/by-path/

# Temporarily disable KWIN_DRM_DEVICES restriction
export KWIN_DRM_DEVICES=
startplasma-wayland
```

### DMUB firmware loads multiple times (crash loop)

If `dmesg | grep "Loading DMUB firmware"` shows 3+ lines, the DCN crash loop
is active. The most common cause on Fedora 43 is a firmware file conflict:

```bash
sudo ml-check-firmware
# Look for CONFLICT messages

# Fix conflicts
for f in dcn_3_1_5_dmcub psp_13_0_5_toc; do
    if [[ -f "/lib/firmware/amdgpu/${f}.bin" ]] && \
       [[ -f "/lib/firmware/amdgpu/${f}.bin.zst" ]]; then
        echo "Fixing conflict: ${f}"
        sudo zstd -f /lib/firmware/amdgpu/${f}.bin \
                  -o /lib/firmware/amdgpu/${f}.bin.zst
        sudo rm -f /lib/firmware/amdgpu/${f}.bin
    fi
done
sudo dracut --force
sudo reboot
```

### sg_display not taking effect

```bash
# Check if the parameter is in initramfs modprobe config
sudo lsinitrd | grep modprobe

# Verify kernel cmdline has the parameter
grep sg_display /proc/cmdline

# Force reapply grubby
sudo grubby --update-kernel=ALL --args="amdgpu.sg_display=0"
sudo grubby --info=DEFAULT | grep args
sudo dracut --force
sudo reboot
```

### Docker container can't see NVIDIA GPU

```bash
# Verify nvidia-container-toolkit is configured
cat /etc/docker/daemon.json | grep nvidia

# Reconfigure
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker

# Test
docker run --rm --gpus all nvidia/cuda:12.0-base nvidia-smi
```

### Windows Boot Manager missing from GRUB

```bash
# Reinstall os-prober
sudo dnf install os-prober

# Re-detect Windows
sudo os-prober
sudo grub2-mkconfig -o /boot/efi/EFI/fedora/grub.cfg
```

---

## Key Files Written by the Kickstart

| File | Purpose |
|------|---------|
| `/etc/modprobe.d/nvidia.conf` | NVIDIA headless: modeset=0, softdep amdgpu pre: nvidia |
| `/etc/modprobe.d/amdgpu.conf` | AMD DCN stability: sg_display=0, ppfeaturemask |
| `/etc/environment` | KWIN_DRM_DEVICES, POWERDEVIL_NO_DDCUTIL, CUDA path |
| `/etc/sddm.conf.d/wayland.conf` | SDDM Wayland mode, breeze theme |
| `/etc/xdg/plasma-workspace/env/ml-workstation.sh` | KWin session env vars |
| `/etc/docker/daemon.json` | Docker CE: overlay2, NVIDIA runtime |
| `/etc/systemd/system/nvidia-persistenced.service` | NVIDIA persistence daemon |
| `/etc/systemd/system/nvidia-powerlimit.service` | RTX 4090 power limit (450W) |
| `/etc/udev/rules.d/70-nvidia-gpu.rules` | NVIDIA device permissions |
| `/etc/profile.d/cuda.sh` | CUDA environment for all login shells |
| `/etc/sysctl.d/99-ml-workstation.conf` | vm.max_map_count, swappiness, network |
| `/etc/security/limits.d/99-ml-workstation.conf` | nofile, memlock for ML workloads |
| `/usr/local/bin/ml-verify-gpu` | GPU configuration verification script |
| `/usr/local/bin/ml-check-firmware` | DMCUB firmware status checker |

---

## Kernel Parameters Applied

These are set via `grubby --update-kernel=ALL` so they apply to all kernel
entries including future kernel updates:

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| `amdgpu.sg_display` | `0` | Disable scatter/gather display; prevents GART stall on EFI->amdgpu handoff |
| `amdgpu.ppfeaturemask` | `0xfffd7fff` | Disable GFXOFF (bit 15); prevents power-gate race during DCN init |
| `amdgpu.dcdebugmask` | `0x10` | Disable PSR; reduces DCN state machine complexity |
| `amdgpu.gfx_off` | `0` | Belt-and-suspenders GFXOFF disable |
| `amdgpu.gpu_recovery` | `1` | Enable GPU reset on hang |
| `amdgpu.noretry` | `0` | Allow GPU memory retry (default; explicit) |
| `nvidia-drm.modeset` | `0` | NVIDIA NOT a KMS device; KWin uses AMD only |
| `modprobe.blacklist` | `nouveau,nova_core` | Prevent open-source NVIDIA drivers |
| `initcall_blacklist` | `simpledrm_platform_driver_init` | Prevent simpledrm from stealing card0; ensures amdgpu = card0 |
| `iommu` | `pt` | IOMMU passthrough for GPU compute performance |
| `pcie_aspm` | `off` | Prevent Xid 79 PCIe link loss on RTX 4090 |

---

## References

- Upstream bug: [drm/amd #5073](https://gitlab.freedesktop.org/drm/amd/-/work_items/5073) — Raphael iGPU optc31 timeout (OPEN)
- Debian firmware fix: [Debian #1057656](https://bugs-devel.debian.org/cgi-bin/bugreport.cgi?bug=1057656) — DMCUB fixed in firmware 20240709
- DMCUB caution: [NixOS #418212](https://github.com/nixos/nixpkgs/issues/418212) — v0.1.14.0 broke DMCUB on some Raphael systems
- Kernel patch: [commit a878304276b8](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=a878304276b8) — bypass ODM before CRTC off (in 6.10+)
- Kernel patch: [commit c707ea82c79d](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=c707ea82c79d) — DMCUB idle before reset (in 6.15+)
- RPM Fusion NVIDIA guide: https://rpmfusion.org/Howto/NVIDIA
- Docker on Fedora: https://docs.docker.com/engine/install/fedora/
- NVIDIA Container Toolkit: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html
- Pykickstart docs: https://pykickstart.readthedocs.io/en/latest/kickstart-docs.html
