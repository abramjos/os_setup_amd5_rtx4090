# =============================================================================
# Fedora 43 KDE Spin — Automated Kickstart
# ML Workstation: AMD Ryzen 9 7950X + NVIDIA RTX 4090 (headless)
#
# Hardware:
#   CPU:    AMD Ryzen 9 7950X (Raphael, iGPU GC 10.3.6, DCN 3.1.5)
#   iGPU:   AMD Radeon Graphics — drives ALL displays (2-3 x 1440p)
#   dGPU:   NVIDIA RTX 4090 — 100% headless CUDA/ML compute, zero display
#   MB:     ASUS ROG Crosshair X670E Hero (X670E, AM5)
#   NVMe:   Samsung SSD 990 PRO 2TB (sda / nvme0n1)
#   RAM:    2×32 GB DDR5-6000
#
# Dual-Boot Partition Layout (Windows partitions MUST be preserved):
#   sda1:  100M  EFI   Windows Boot Manager  — PRESERVE
#   sda2:   16M        MSR                   — PRESERVE
#   sda3:  908G  NTFS  Windows C:            — PRESERVE
#   sda4:  888M  NTFS  Windows Recovery      — PRESERVE (at end of disk)
#   sda5:    1G  EFI   (was Ubuntu EFI)      — REFORMAT as Fedora /boot/efi
#   sda6:    2G  ext4  (was Ubuntu /boot)    — REFORMAT as Fedora /boot
#   sda7:   64G  swap  (was Ubuntu swap)     — REFORMAT as Fedora swap
#   sda8:  200G  xfs   (was Ubuntu /)        — REFORMAT as Fedora /
#   sda9:  rest  xfs   (was Ubuntu /home)    — REFORMAT as Fedora /home
#
# IMPORTANT: Fedora Kickstart uses the block device name from the installer
# environment. The Samsung 990 PRO NVMe typically appears as nvme0n1 (with
# partitions nvme0n1p1..p9) in the Fedora Live ISO environment.
# Verify with: lsblk  (from the Anaconda rescue shell or pre-install terminal)
# If the device shows as nvme0n1, replace every "sda" below with "nvme0n1"
# and "sdaN" with "nvme0n1pN" accordingly.
#
# Usage:
#   Boot from Fedora 43 KDE Spin ISO, at the boot menu press Tab (GRUB) or 'e'
#   and append:  inst.ks=https://your-server/fedora43-kde-ml.ks
#   OR place on USB/HTTP and use:  inst.ks=hd:sdb1:/fedora43-kde-ml.ks
#
# See FEDORA-SETUP.md for full pre/post-install instructions.
# =============================================================================

# =============================================================================
# INSTALLATION MODE
# =============================================================================
# Fully graphical unattended install
graphical

# =============================================================================
# INSTALL SOURCE
# =============================================================================
# Use the running media (Live ISO) as the install source.
# Anaconda on the KDE Spin Live ISO uses the embedded repo by default.
# For a netinstall ISO, replace with:
#   url --metalink=https://mirrors.fedoraproject.org/metalink?repo=fedora-43&arch=x86_64
cdrom

# =============================================================================
# KEYBOARD, LANGUAGE, TIMEZONE
# =============================================================================
keyboard --vckeymap=us --xlayouts='us'
lang en_US.UTF-8
timezone America/New_York --utc

# =============================================================================
# NETWORK
# =============================================================================
# DHCP on the first available Ethernet interface.
# SSH is enabled in %post via systemctl enable sshd.
network --bootproto=dhcp --device=link --activate
network --hostname=vortex

# =============================================================================
# USERS & AUTHENTICATION
# =============================================================================
# Root is locked by default on Fedora; the wheel user gets sudo via PAM.
# Password hash generated with: python3 -c "import crypt; print(crypt.crypt('yourpassword', crypt.mksalt(crypt.METHOD_SHA512)))"
# Replace the hash below before use.
rootpw --lock
user --name=abraham --groups=wheel --gecos="Abraham" \
     --password="$6$tgmHIWX35Qendhwj$hSQ0dDsaUy2zJwnh8uRoMBEHybDjWXsmnjgi2fcECzmAZGrMfpuSDnOnTVG/uJ/G23Yf403i//i984JlbFvhy1" \
     --iscrypted

# =============================================================================
# SECURITY — SELinux & Firewall
# =============================================================================
# Permissive for ML workload compatibility (CUDA containers, bind mounts, etc.)
# Change to 'enforcing' if your workload is compatible.
selinux --permissive

# Firewalld enabled with SSH allowed; Docker bitmask applied in %post.
firewall --enabled --service=ssh

# =============================================================================
# BOOTLOADER
# =============================================================================
# --boot-drive: target the NVMe where Fedora EFI will be installed.
# --location=partition: writes GRUB to the /boot/efi partition, not the MBR.
#   This is required for EFI systems. Windows Boot Manager on sda1 is untouched.
# --append: base kernel parameters; comprehensive ML/display params added via
#   grubby in %post so they apply to all future kernel entries too.
#
# Key parameters here:
#   rd.driver.blacklist=nouveau,nova_core — prevents nouveau loading in initrd
#   modprobe.blacklist=nouveau,nova_core  — belt-and-suspenders userspace blacklist
#   initcall_blacklist=simpledrm_platform_driver_init — prevents simpledrm from
#     stealing card0; ensures amdgpu = card0 for display (critical for SDDM)
bootloader \
  --location=partition \
  --boot-drive=sda \
  --append="rd.driver.blacklist=nouveau,nova_core modprobe.blacklist=nouveau,nova_core initcall_blacklist=simpledrm_platform_driver_init iommu=pt pcie_aspm=off"

# =============================================================================
# STORAGE — Dual-Boot Partition Layout
# =============================================================================
# Strategy: clearpart only lists sda5-sda9 (the Linux partitions).
# sda1-sda4 (Windows) are never touched.
#
# clearpart --list= enumerates ONLY the partitions to be cleared.
# --drives=sda ensures clearpart doesn't act on any secondary disk.
#
# NOTE: If the installer sees the NVMe as nvme0n1, replace:
#   sda  → nvme0n1
#   sdaN → nvme0n1pN
# Use lsblk from the Anaconda pre-install shell to confirm device names.
# =============================================================================
clearpart --list=sda5,sda6,sda7,sda8,sda9 --drives=sda

# /boot/efi — reformat the existing 1G EFI partition (sda5, formerly Ubuntu EFI)
# --onpart=sda5: reuse the existing physical partition slot
# fstype=efi is required for Anaconda to register this as the EFI system partition
part /boot/efi --fstype=efi --onpart=sda5 --label=EFI-FEDORA

# /boot — separate /boot needed for GRUB2 on UEFI + amdgpu (initramfs needs space)
# 1G is sufficient; Fedora keeps 3 kernel generations
part /boot --fstype=xfs --onpart=sda6 --label=BOOT --size=1024

# swap — matches RAM (64G) for potential hibernate / large model loading
part swap --fstype=swap --onpart=sda7 --label=SWAP

# / (root) — 200G XFS (Fedora default filesystem)
part / --fstype=xfs --onpart=sda8 --label=ROOT

# /home — remaining space (XFS); ML datasets, models, Docker volumes live here
# NOTE: --onpart= with no --grow is fine; the partition already fills the space.
# If the existing partition is larger than needed, Anaconda uses its full size.
part /home --fstype=xfs --onpart=sda9 --label=HOME

# =============================================================================
# REPOSITORIES
# =============================================================================
# Base Fedora repos are provided by the installation media.
# RPM Fusion repos must be declared here for the %packages section to resolve
# akmod-nvidia at install time. However, the key must be accepted in %post
# because the Kickstart repo directive doesn't install the GPG key persistently.
#
# ALTERNATIVE: Comment out the repo directives here, remove NVIDIA packages from
# %packages, and install everything in %post instead (safer for offline installs).

repo --name=rpmfusion-free \
     --baseurl=https://download1.rpmfusion.org/free/fedora/releases/43/Everything/x86_64/os/ \
     --cost=1000

repo --name=rpmfusion-nonfree \
     --baseurl=https://download1.rpmfusion.org/nonfree/fedora/releases/43/Everything/x86_64/os/ \
     --cost=1000

# =============================================================================
# SERVICES
# =============================================================================
# Enable during installation; additional services configured in %post.
services --enabled=sshd,firewalld,NetworkManager
# Disable power management targets (server/ML workstation stays on)
services --disabled=sleep.target,suspend.target,hibernate.target,hybrid-sleep.target

# =============================================================================
# PACKAGES
# =============================================================================
# @^kde-desktop-environment  — KDE Plasma 6 environment group (the ^ prefix
#   denotes an environment group, equivalent to the KDE Spin selection)
# @kde-apps                  — Full KDE application suite
# @development-tools         — gcc, make, git, etc.
# @hardware-support          — Firmware, hardware enablement
# @base-x                    — X.Org server (required as KWin Wayland fallback)
# @networkmanager-submodules — NM VPN plugins, WiFi support
# @printing                  — CUPS (optional but handy)
# =============================================================================
%packages
# --- KDE Plasma 6 Desktop Environment ---
@^kde-desktop-environment
@kde-apps
@kde-media

# --- X.Org base (KWin uses it for X11 fallback; SDDM needs it) ---
@base-x

# --- Core system groups ---
@development-tools
@hardware-support
@networkmanager-submodules
@printing

# --- Kernel build / module support ---
kernel-devel
kernel-headers
dkms
akmods
kmodtool
mokutil

# --- NVIDIA drivers via RPM Fusion ---
# akmod-nvidia: Fedora's automatic kernel module build system (like DKMS).
#   Builds the NVIDIA kernel module on first boot (takes 2-3 min).
#   Wait for: akmods-ostree.service or check: modinfo nvidia
# xorg-x11-drv-nvidia-cuda: CUDA libraries and tools.
# Note: akmod-nvidia requires rpmfusion-nonfree repo (declared above).
akmod-nvidia
xorg-x11-drv-nvidia-cuda
nvidia-settings

# --- Display / GPU utilities ---
mesa-utils
mesa-vulkan-drivers
mesa-dri-drivers
libdrm
libdrm-devel
vulkan-tools
vulkan-loader
clinfo
glxinfo
vdpauinfo
libva-utils
nvtop

# --- Display Manager ---
sddm
sddm-kcm
sddm-breeze
# Ensure GDM is not installed (conflicts with SDDM display ownership)
-gdm

# --- Python / ML prerequisites ---
python3
python3-pip
python3-virtualenv
python3-devel

# --- Development / build ---
git
cmake
ninja-build
gcc
gcc-c++
make
pkgconf-pkg-config
openssl-devel
libffi-devel
bzip2-devel
readline-devel
sqlite-devel
zlib-devel
xz-devel
ncurses-devel

# --- System utilities ---
vim
htop
tmux
wget
curl
rsync
unzip
zstd
jq
pciutils
usbutils
dmidecode
lm_sensors
lm_sensors-devel
smartmontools
hdparm
nvme-cli
ethtool
net-tools
bind-utils
strace
lsof
sysstat
iotop
iftop
tcpdump

# --- Firmware tools ---
fwupd
linux-firmware

# --- Container / Docker prerequisites ---
# Docker CE is installed via its own repo in %post.
# These ensure the kernel modules and dependencies are present.
container-selinux
libseccomp
iptables-nft

# --- Exclude packages that conflict with headless NVIDIA or add bloat ---
-@gnome-desktop
-@workstation-product-environment
-switcheroo-control
-power-profiles-daemon
%end

# =============================================================================
# PRE-INSTALL SCRIPT
# =============================================================================
# Runs before partitioning. Used here only for informational logging.
%pre --log=/root/ks-pre.log
echo "=== Fedora 43 KDE ML Workstation Kickstart — Pre-install ==="
echo "Date: $(date)"
lsblk
echo "=== Pre-install complete ==="
%end

# =============================================================================
# POST-INSTALL SCRIPT
# =============================================================================
# Runs chrooted into the new installation at /mnt/sysimage (or / after chroot).
# --log writes to the installed system root for debugging.
%post --log=/root/ks-post.log
set -euo pipefail

echo ""
echo "============================================================"
echo " Fedora 43 KDE ML Workstation — Post-Install Configuration"
echo " $(date)"
echo "============================================================"

# ---------------------------------------------------------------------------
# 1. GRUB KERNEL PARAMETERS
# ---------------------------------------------------------------------------
# grubby updates ALL existing and future kernel entries.
# Parameters are the result of extensive testing on Raphael DCN 3.1.5 +
# RTX 4090 dual-GPU. See CLAUDE.md / COMPATIBILITY-MATRIX.md for rationale.
#
# Critical parameters for Raphael iGPU display stability:
#   amdgpu.sg_display=0          — disable scatter/gather display, forces
#                                   contiguous VRAM for framebuffers (prevents
#                                   GART/TLB stall on EFI->amdgpu handoff)
#   amdgpu.ppfeaturemask=0xfffd7fff — disables GFXOFF (bit 15) via feature mask
#   amdgpu.dcdebugmask=0x10      — disables PSR (Panel Self Refresh), reduces
#                                   DCN state machine complexity
#   amdgpu.gfx_off=0             — belt-and-suspenders GFXOFF disable
#   amdgpu.gpu_recovery=1        — enable GPU reset on hang (default but explicit)
#   amdgpu.noretry=0             — allow GPU memory retry (default)
#
# NVIDIA headless:
#   nvidia-drm.modeset=0         — NVIDIA NOT a KMS device; KWin only sees AMD
#
# EFI framebuffer / card ordering:
#   initcall_blacklist=simpledrm_platform_driver_init — already in bootloader
#     directive above; grubby --args is additive, not duplicate
#
# Power / PCIe stability:
#   iommu=pt                     — IOMMU passthrough for GPU compute
#   pcie_aspm=off                — prevents Xid 79 link loss on RTX 4090
echo "--- Configuring GRUB kernel parameters ---"
grubby --update-kernel=ALL --args=" \
  amdgpu.sg_display=0 \
  amdgpu.ppfeaturemask=0xfffd7fff \
  amdgpu.dcdebugmask=0x10 \
  amdgpu.gfx_off=0 \
  amdgpu.gpu_recovery=1 \
  amdgpu.noretry=0 \
  nvidia-drm.modeset=0 \
  modprobe.blacklist=nouveau,nova_core \
  initcall_blacklist=simpledrm_platform_driver_init \
  iommu=pt \
  pcie_aspm=off \
"

# Verify the update was applied
echo "--- GRUB kernel args (first entry) ---"
grubby --info=DEFAULT | grep args || true

# ---------------------------------------------------------------------------
# 2. MODPROBE CONFIGURATION
# ---------------------------------------------------------------------------
echo "--- Writing modprobe configuration ---"

# NVIDIA: headless, no KMS, load AFTER amdgpu
cat > /etc/modprobe.d/nvidia.conf << 'NVIDIA_MODPROBE'
# NVIDIA RTX 4090 — Headless compute only, zero display
# KWin must NOT see NVIDIA as a DRM device.
# nvidia-drm.modeset=0: disable KMS on NVIDIA (SDDM/KWin use AMD only)
# softdep pre: amdgpu: ensures amdgpu initialises first so it gets card0
options nvidia-drm modeset=0
options nvidia-drm fbdev=0
options nvidia NVreg_UsePageAttributeTable=1
options nvidia NVreg_InitializeSystemMemoryAllocations=0
options nvidia NVreg_DynamicPowerManagement=0x02
options nvidia NVreg_EnableGpuFirmware=1
options nvidia NVreg_PreserveVideoMemoryAllocations=1
options nvidia NVreg_RegistryDwords="RmGpuComputeExecTimeout=0"

# Ensure amdgpu loads before NVIDIA so AMD gets card0 (display)
softdep nvidia pre: amdgpu
softdep nvidia_drm pre: amdgpu

blacklist nouveau
blacklist lbm-nouveau
blacklist nova_core
options nouveau modeset=0
alias nouveau off
alias lbm-nouveau off
NVIDIA_MODPROBE

# amdgpu: DCN 3.1.5 (Raphael) display stability parameters
cat > /etc/modprobe.d/amdgpu.conf << 'AMDGPU_MODPROBE'
# AMD Radeon Raphael (GC 10.3.6, DCN 3.1.5) — display and iGPU configuration
# Mirrors kernel cmdline parameters; belt-and-suspenders for module reload.

# sg_display=0: disable scatter/gather display allocation.
# Forces contiguous VRAM for display framebuffers, bypassing GART/TLB.
# Critical for Raphael multi-monitor — prevents HUBP fetch stalls on boot.
options amdgpu sg_display=0

# ppfeaturemask=0xfffd7fff: disable GFXOFF (bit 15).
# GFXOFF powers down GFX block between draws; on Raphael + NVIDIA dGPU
# the power state transition interacts with DCN register access.
options amdgpu ppfeaturemask=0xfffd7fff

# dcdebugmask=0x10: disable PSR (Panel Self Refresh).
# PSR allows display engine to enter self-refresh during idle; on DCN 3.1.5
# the EFI->amdgpu handoff sometimes leaves PSR in an inconsistent state.
options amdgpu dcdebugmask=0x10

# gfx_off=0: belt-and-suspenders GFXOFF disable.
options amdgpu gfx_off=0

# gpu_recovery=1: enable automatic GPU reset on hang (default; explicit here).
options amdgpu gpu_recovery=1

# dc=1: enable Display Core (required for Wayland/KMS on Raphael).
options amdgpu dc=1

# audio=1: enable HDMI/DP audio via amdgpu.
options amdgpu audio=1
AMDGPU_MODPROBE

# ---------------------------------------------------------------------------
# 3. ENVIRONMENT VARIABLES — KWin / Display
# ---------------------------------------------------------------------------
echo "--- Writing /etc/environment additions ---"

# Append to /etc/environment (create if it doesn't exist).
# KWIN_DRM_DEVICES: restrict KWin to AMD DRI node only.
#   The path /dev/dri/by-path/pci-0000:6c:00.0-card is for the Raphael iGPU
#   on this specific X670E Hero board. The PCI address WILL VARY per system.
#   POST-INSTALL ACTION REQUIRED: verify with:
#     ls -la /dev/dri/by-path/
#   Then update KWIN_DRM_DEVICES to the correct symlink target.
#   If the wrong path is set, KWin will fall back to auto-detection (still
#   usually correct) but may occasionally pick the NVIDIA device.
#
# POWERDEVIL_NO_DDCUTIL=1: prevent PowerDevil's DDCUtil from hanging the
#   KDE main thread when querying monitor brightness/capabilities.
#   DDCUtil issues blocking I2C reads; on multi-monitor setups this can
#   freeze the entire KDE session for 5-30 seconds.

cat >> /etc/environment << 'KWIN_ENV'

# --- KWin Display Configuration (ML Workstation) ---
# Restrict KWin to AMD iGPU DRI node only; exclude NVIDIA RTX 4090.
# IMPORTANT: Verify the PCI address below with: ls -la /dev/dri/by-path/
# The address 0000:6c:00.0 is the Raphael iGPU PCI slot on X670E Hero.
# If your system shows a different address, update this line.
KWIN_DRM_DEVICES=/dev/dri/by-path/pci-0000:6c:00.0-card

# Keep atomic modesetting enabled (KWin default).
# Set to 1 only if KWin logs show "atomic check failed" errors.
KWIN_DRM_NO_AMS=0

# Prevent DDCUtil I2C hang on KDE main thread.
POWERDEVIL_NO_DDCUTIL=1

# CUDA environment (applies system-wide for all users)
CUDA_HOME=/usr/local/cuda
PATH=/usr/local/cuda/bin:$PATH
LD_LIBRARY_PATH=/usr/local/cuda/lib64:/usr/lib64/nvidia:$LD_LIBRARY_PATH
KWIN_ENV

# ---------------------------------------------------------------------------
# 4. SDDM CONFIGURATION — Wayland session, AMD card only
# ---------------------------------------------------------------------------
echo "--- Configuring SDDM ---"

mkdir -p /etc/sddm.conf.d

cat > /etc/sddm.conf.d/wayland.conf << 'SDDM_CONF'
[General]
# Use Wayland compositor for the login screen.
# SDDM's built-in wlroots compositor handles the AMD card directly.
# This is safer than starting a full KWin session at login.
DisplayServer=wayland

# Enable numlock at login
Numlock=on

[Wayland]
# Point to the installed Wayland session definitions (Plasma Wayland, etc.)
SessionDir=/usr/share/wayland-sessions
# Compositor command used by SDDM's Wayland compositor mode.
# Leave blank to use SDDM's built-in compositor.
CompositorCommand=

[Theme]
Current=breeze
SDDM_CONF

# Ensure SDDM is the active display manager.
# On a fresh Fedora KDE install, SDDM is the default; this is belt-and-suspenders.
systemctl enable sddm.service

# Disable GDM if it was pulled in as a dependency (should not be with -gdm above,
# but guard against it in case the package set changes).
if systemctl list-unit-files gdm.service &>/dev/null; then
    systemctl disable gdm.service || true
    systemctl mask gdm.service || true
    echo "GDM masked."
fi

# ---------------------------------------------------------------------------
# 5. RPM FUSION REPOS — Persistent post-install configuration
# ---------------------------------------------------------------------------
# The repo directives in the header install packages from RPM Fusion during
# Anaconda's install phase, but the persistent .repo files must be installed
# via the rpm packages so future dnf operations (updates, akmod rebuilds) work.
echo "--- Installing RPM Fusion repo packages ---"
dnf install -y \
    https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-43.noarch.rpm \
    https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-43.noarch.rpm \
    || true  # Don't fail if already installed or offline

# ---------------------------------------------------------------------------
# 6. NVIDIA DRIVER — akmod build + CUDA
# ---------------------------------------------------------------------------
# akmod-nvidia was installed via %packages. The kernel module is NOT yet built.
# The first-boot akmods service builds it; we trigger a pre-build here so
# that the module is available immediately after reboot.
#
# IMPORTANT: Do NOT reboot immediately after this. The akmods build takes
# 2-3 minutes. The dracut rebuild at the end of this %post section will
# pick up the built module.
echo "--- Pre-building NVIDIA akmod kernel module ---"
# Build for the currently running kernel (the one that was just installed).
# This may fail in the chroot if /proc and /sys are not mounted; that is OK —
# akmods will build on first real boot via akmods.service.
akmods --force --rebuild 2>/dev/null || echo "akmod pre-build skipped (expected in chroot)"

# CUDA toolkit installation.
# NVIDIA does not publish an official Fedora 43 CUDA repo as of 2026-03.
# Use the CUDA repo targeting Fedora 42 (binary compatible) or install
# cuda-toolkit from RPM Fusion (xorg-x11-drv-nvidia-cuda was installed via
# %packages). For the full CUDA toolkit, add NVIDIA's repo:
echo "--- Configuring CUDA repository ---"
CUDA_DISTRO="fedora43"
CUDA_ARCH="x86_64"
CUDA_REPO_URL="https://developer.download.nvidia.com/compute/cuda/repos/${CUDA_DISTRO}/${CUDA_ARCH}/cuda-${CUDA_DISTRO}.repo"

# Attempt Fedora 43 CUDA repo; fall back to Fedora 42 if not yet published.
if curl --silent --head --fail "${CUDA_REPO_URL}" > /dev/null 2>&1; then
    dnf config-manager addrepo --from-repofile="${CUDA_REPO_URL}" || true
    dnf install -y cuda-toolkit || echo "CUDA toolkit install failed; install manually post-boot"
else
    echo "Fedora 43 CUDA repo not yet available from NVIDIA."
    echo "Falling back to Fedora 42 CUDA repo (binary compatible)..."
    CUDA_REPO_URL_F42="https://developer.download.nvidia.com/compute/cuda/repos/fedora42/${CUDA_ARCH}/cuda-fedora42.repo"
    if curl --silent --head --fail "${CUDA_REPO_URL_F42}" > /dev/null 2>&1; then
        dnf config-manager addrepo --from-repofile="${CUDA_REPO_URL_F42}" || true
        dnf install -y cuda-toolkit || echo "CUDA toolkit install failed; install manually post-boot"
    else
        echo "Neither Fedora 43 nor Fedora 42 CUDA repos available."
        echo "Install cuda-toolkit manually after first boot."
        echo "See: https://developer.nvidia.com/cuda-downloads"
    fi
fi

# ---------------------------------------------------------------------------
# 7. NVIDIA CONTAINER TOOLKIT
# ---------------------------------------------------------------------------
echo "--- Installing NVIDIA Container Toolkit ---"
# Add the container toolkit repo
curl -sL https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
    -o /etc/yum.repos.d/nvidia-container-toolkit.repo || true

dnf install -y nvidia-container-toolkit \
    || echo "nvidia-container-toolkit install failed; install manually post-boot"

# ---------------------------------------------------------------------------
# 8. DOCKER CE
# ---------------------------------------------------------------------------
echo "--- Installing Docker CE ---"

# Add Docker CE repository for Fedora
dnf config-manager addrepo \
    --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo \
    || true

# Install Docker CE packages
dnf install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin \
    || echo "Docker CE install failed; install manually post-boot"

# Add primary user to docker group
usermod -aG docker abraham || true

# Enable Docker service (starts on boot)
systemctl enable docker.service
systemctl enable containerd.service

# Write Docker daemon configuration for NVIDIA GPU support
mkdir -p /etc/docker
cat > /etc/docker/daemon.json << 'DOCKER_DAEMON'
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "100m",
        "max-file": "3"
    },
    "storage-driver": "overlay2",
    "default-runtime": "runc",
    "runtimes": {
        "nvidia": {
            "path": "nvidia-container-runtime",
            "runtimeArgs": []
        }
    },
    "default-ulimits": {
        "nofile": {
            "name": "nofile",
            "soft": 65536,
            "hard": 65536
        }
    }
}
DOCKER_DAEMON

# Configure nvidia-container-toolkit to work with Docker
nvidia-ctk runtime configure --runtime=docker 2>/dev/null \
    || echo "nvidia-ctk configure skipped (nvidia-ctk not yet available)"

# ---------------------------------------------------------------------------
# 9. NVIDIA PERSISTENCE DAEMON
# ---------------------------------------------------------------------------
echo "--- Configuring nvidia-persistenced ---"

# nvidia-persistenced keeps the NVIDIA driver loaded even when no compute
# process is running. Essential for headless compute cards to avoid driver
# re-initialization latency before ML jobs.
cat > /etc/systemd/system/nvidia-persistenced.service << 'NV_PERSIST_SVC'
[Unit]
Description=NVIDIA Persistence Daemon
Wants=syslog.target
After=sysinit.target

[Service]
Type=forking
ExecStart=/usr/bin/nvidia-persistenced --verbose
ExecStopPost=/bin/rm -rf /var/run/nvidia-persistenced
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
NV_PERSIST_SVC

systemctl enable nvidia-persistenced.service || true

# ---------------------------------------------------------------------------
# 10. NVIDIA POWER LIMIT SERVICE
# ---------------------------------------------------------------------------
# Optionally caps the RTX 4090 TDP for efficiency during sustained ML training.
# Default: 450W (RTX 4090 TDP). Uncomment and adjust as desired.
# The service runs at boot after the NVIDIA driver loads.
echo "--- Writing nvidia-powerlimit systemd service ---"

cat > /etc/systemd/system/nvidia-powerlimit.service << 'NV_PL_SVC'
[Unit]
Description=Set NVIDIA GPU Power Limit
After=nvidia-persistenced.service
Requires=nvidia-persistenced.service

[Service]
Type=oneshot
RemainAfterExit=yes
# Adjust watt value as needed:
#   450W = RTX 4090 TDP (default, no change)
#   350W = good sustained training efficiency
#   300W = maximum efficiency (slower, cooler)
ExecStart=/usr/bin/nvidia-smi -pl 450
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
NV_PL_SVC

systemctl enable nvidia-powerlimit.service || true

# ---------------------------------------------------------------------------
# 11. UDEV RULES — NVIDIA compute access
# ---------------------------------------------------------------------------
echo "--- Writing udev rules ---"

# Allow members of the 'video' group to access NVIDIA devices.
# The primary user is in 'wheel'; add to 'video' explicitly.
cat > /etc/udev/rules.d/70-nvidia-gpu.rules << 'NVIDIA_UDEV'
# NVIDIA GPU — headless compute access
# Allow video group access to the NVIDIA character devices.
KERNEL=="nvidia", SUBSYSTEM=="module", ACTION=="add", RUN+="/bin/chmod 0660 /dev/nvidia0"
KERNEL=="nvidia-modeset", SUBSYSTEM=="module", ACTION=="add", RUN+="/bin/chmod 0660 /dev/nvidia-modeset"
KERNEL=="nvidia-uvm", ACTION=="add", RUN+="/bin/chmod 0660 /dev/nvidia-uvm /dev/nvidia-uvm-tools"

# Ensure nvidia-uvm device is created when the module loads
SUBSYSTEM=="module", ACTION=="add", DEVPATH=="/module/nvidia_uvm", \
    RUN+="/usr/bin/nvidia-modprobe -c0 -u"

KERNEL=="nvidia*", RUN+="/bin/bash -c '/usr/bin/nvidia-modprobe -c0 -u'"
NVIDIA_UDEV

# Add user to video and render groups for GPU device access
usermod -aG video,render abraham || true

# ---------------------------------------------------------------------------
# 12. CUDA ENVIRONMENT PROFILE
# ---------------------------------------------------------------------------
echo "--- Writing CUDA environment profile ---"

cat > /etc/profile.d/cuda.sh << 'CUDA_PROFILE'
# CUDA environment — sourced for all login shells
# Update CUDA_VERSION if a different CUDA version is installed.
export CUDA_HOME=/usr/local/cuda
export CUDA_VERSION=$(ls /usr/local/cuda/version.json 2>/dev/null \
    | xargs grep -oP '"version"\s*:\s*"\K[^"]+' 2>/dev/null \
    || echo "12.x")

# Add CUDA binaries and libraries to PATH / LD_LIBRARY_PATH
export PATH=${CUDA_HOME}/bin${PATH:+:${PATH}}
export LD_LIBRARY_PATH=${CUDA_HOME}/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}
export LD_LIBRARY_PATH=/usr/lib64/nvidia${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}

# NCCL / cuDNN library path (if installed)
export LD_LIBRARY_PATH=/usr/local/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}

# Python virtual environments inherit CUDA automatically.
# ML frameworks: PyTorch, JAX, TensorFlow will find CUDA via this path.
CUDA_PROFILE

chmod +x /etc/profile.d/cuda.sh

# ---------------------------------------------------------------------------
# 13. KDE AUTOSTART — Environment variables for KWin session
# ---------------------------------------------------------------------------
# The /etc/environment entries are read by the PAM session; they apply to
# all Wayland and X11 sessions. However, for belt-and-suspenders, also
# write a KDE plasma-workspace env file that KWin reads directly.
echo "--- Writing KDE plasma environment configuration ---"

mkdir -p /etc/xdg/plasma-workspace/env

cat > /etc/xdg/plasma-workspace/env/ml-workstation.sh << 'PLASMA_ENV'
#!/bin/bash
# KDE Plasma environment variables for ML workstation display configuration.
# Sourced by the KWin/Plasma session before compositing starts.

# Restrict KWin DRM to AMD iGPU only (exclude NVIDIA RTX 4090).
# IMPORTANT: Verify this PCI path post-install with: ls -la /dev/dri/by-path/
export KWIN_DRM_DEVICES=/dev/dri/by-path/pci-0000:6c:00.0-card

# Atomic modesetting: keep enabled (0 = use AMS, 1 = disable AMS).
# Set to 1 only if KWin logs show atomic check failures.
export KWIN_DRM_NO_AMS=0

# Prevent PowerDevil DDCUtil main thread hang on multi-monitor setups.
export POWERDEVIL_NO_DDCUTIL=1

# CUDA environment
export CUDA_HOME=/usr/local/cuda
export PATH=${CUDA_HOME}/bin${PATH:+:${PATH}}
PLASMA_ENV

chmod +x /etc/xdg/plasma-workspace/env/ml-workstation.sh

# ---------------------------------------------------------------------------
# 14. POWER MANAGEMENT — Disable sleep/suspend (workstation/server use)
# ---------------------------------------------------------------------------
echo "--- Disabling sleep/suspend targets ---"
systemctl mask sleep.target suspend.target hibernate.target \
    hybrid-sleep.target || true

# Disable switcheroo-control (Ubuntu GPU switcher, not applicable to Fedora
# but may be pulled in by some hardware-support packages).
systemctl disable switcheroo-control.service 2>/dev/null \
    || echo "switcheroo-control not present (expected)"
systemctl mask switcheroo-control.service 2>/dev/null || true

# ---------------------------------------------------------------------------
# 15. DRACUT — Rebuild initramfs
# ---------------------------------------------------------------------------
# Rebuilds initramfs to include:
#   - Updated modprobe.d/nvidia.conf (blacklist nouveau, softdep nvidia pre: amdgpu)
#   - Updated modprobe.d/amdgpu.conf (sg_display=0, ppfeaturemask)
#   - akmod-built NVIDIA kernel module (if pre-build succeeded above)
#   - New udev rules
# This ensures the correct module load order from the very first real boot.
echo "--- Rebuilding initramfs via dracut ---"
# --no-hostonly: build a generic initramfs (more portable, slightly larger)
# --force: overwrite existing initramfs
dracut --force --no-hostonly 2>&1 | tail -20 || \
    echo "WARNING: dracut failed — initramfs may not include updated modprobe config"

# ---------------------------------------------------------------------------
# 16. FIREWALLD — Additional rules for ML/development workflow
# ---------------------------------------------------------------------------
echo "--- Configuring firewalld ---"
# Ensure Docker bridge interface is trusted (Docker uses iptables/nftables).
# This prevents Docker containers from losing network when firewalld restarts.
firewall-offline-cmd --zone=trusted --add-interface=docker0 2>/dev/null || true
firewall-offline-cmd --zone=trusted --add-interface=br-+ 2>/dev/null || true

# Allow Jupyter Lab (8888) and TensorBoard (6006) from local network.
# Remove these if the workstation is on an untrusted network.
firewall-offline-cmd --zone=public --add-port=8888/tcp 2>/dev/null || true
firewall-offline-cmd --zone=public --add-port=6006/tcp 2>/dev/null || true

# ---------------------------------------------------------------------------
# 17. BOOT VERIFICATION SCRIPT
# ---------------------------------------------------------------------------
# A standalone diagnostic script installed to /usr/local/bin/.
# Run it after first boot to verify the GPU configuration is correct.
echo "--- Writing boot verification script ---"

cat > /usr/local/bin/ml-verify-gpu << 'VERIFY_SCRIPT'
#!/bin/bash
# =============================================================================
# ml-verify-gpu — Post-Install GPU Verification Script
# ML Workstation: AMD Raphael iGPU (display) + NVIDIA RTX 4090 (compute)
# =============================================================================
set -euo pipefail

PASS=0
WARN=0
FAIL=0

check() {
    local label="$1"
    local expected="$2"
    local actual="$3"
    local severity="${4:-FAIL}"

    if echo "$actual" | grep -qF "$expected"; then
        echo "  [PASS] $label"
        ((PASS++)) || true
    else
        echo "  [$severity] $label"
        echo "         Expected: $expected"
        echo "         Actual:   $actual"
        [[ "$severity" == "WARN" ]] && ((WARN++)) || ((FAIL++))
    fi
}

echo ""
echo "================================================================"
echo " ML Workstation GPU Verification"
echo " $(date)"
echo "================================================================"

# --- 1. Card assignment ---
echo ""
echo "1. DRM Card Assignment (AMD must be card0 for display)"
for card in /sys/class/drm/card[0-9]; do
    vendor=$(cat "$card/device/vendor" 2>/dev/null || echo "unknown")
    driver=$(basename "$(readlink "$card/device/driver" 2>/dev/null)" || echo "unknown")
    echo "   $(basename $card): vendor=$vendor driver=$driver"
done
CARD0_DRIVER=$(basename "$(readlink /sys/class/drm/card0/device/driver 2>/dev/null)" || echo "none")
check "card0 driver is amdgpu (display)" "amdgpu" "$CARD0_DRIVER"

# --- 2. amdgpu parameters ---
echo ""
echo "2. amdgpu Module Parameters"
SG_DISPLAY=$(cat /sys/module/amdgpu/parameters/sg_display 2>/dev/null || echo "unavailable")
check "sg_display=0 (contiguous VRAM for display)" "0" "$SG_DISPLAY"

# --- 3. NVIDIA driver ---
echo ""
echo "3. NVIDIA Driver (RTX 4090 Headless)"
if command -v nvidia-smi &>/dev/null; then
    NV_GPU=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null || echo "unavailable")
    NV_DISP=$(nvidia-smi --query-gpu=display_active --format=csv,noheader 2>/dev/null || echo "unavailable")
    NV_MODE=$(nvidia-smi --query-gpu=display_mode --format=csv,noheader 2>/dev/null || echo "unavailable")
    check "RTX 4090 detected" "RTX 4090" "$NV_GPU"
    check "NVIDIA display_active=Disabled (headless)" "Disabled" "$NV_DISP"
    check "NVIDIA display_mode=Disabled (headless)" "Disabled" "$NV_MODE"
else
    echo "  [WARN] nvidia-smi not found — NVIDIA driver may not be loaded yet"
    echo "         Run: sudo akmods --force --rebuild && sudo dracut --force && reboot"
    ((WARN++)) || true
fi

# --- 4. KWIN_DRM_DEVICES ---
echo ""
echo "4. KWin DRM Devices Environment Variable"
KWIN_DRM=$(grep KWIN_DRM_DEVICES /etc/environment 2>/dev/null | head -1 || echo "not set")
echo "   $KWIN_DRM"
if [[ "$KWIN_DRM" == *"pci-"* ]]; then
    AMD_PATH=$(echo "$KWIN_DRM" | grep -oP 'pci-[^=\s]+' || echo "")
    if [[ -L "/dev/dri/by-path/${AMD_PATH}" ]]; then
        echo "  [PASS] KWIN_DRM_DEVICES path exists: $AMD_PATH"
        ((PASS++)) || true
    else
        echo "  [WARN] KWIN_DRM_DEVICES path NOT found: /dev/dri/by-path/${AMD_PATH}"
        echo "         Run: ls -la /dev/dri/by-path/"
        echo "         Update /etc/environment and /etc/xdg/plasma-workspace/env/ml-workstation.sh"
        ((WARN++)) || true
    fi
fi

# --- 5. SDDM service ---
echo ""
echo "5. Display Manager"
SDDM_STATE=$(systemctl is-enabled sddm.service 2>/dev/null || echo "disabled")
check "sddm.service enabled" "enabled" "$SDDM_STATE"

# --- 6. Docker ---
echo ""
echo "6. Docker CE"
if command -v docker &>/dev/null; then
    DOCKER_VER=$(docker --version 2>/dev/null || echo "unavailable")
    echo "   $DOCKER_VER"
    ((PASS++)) || true
else
    echo "  [WARN] docker not found"
    ((WARN++)) || true
fi

# --- 7. NVIDIA Container Toolkit ---
echo ""
echo "7. NVIDIA Container Toolkit"
if command -v nvidia-ctk &>/dev/null; then
    NCT_VER=$(nvidia-ctk --version 2>/dev/null | head -1 || echo "unavailable")
    echo "   [PASS] $NCT_VER"
    ((PASS++)) || true
else
    echo "  [WARN] nvidia-ctk not found"
    ((WARN++)) || true
fi

# --- 8. dmesg checks ---
echo ""
echo "8. Kernel Log — Critical AMD/NVIDIA Events"
REG_WAIT=$(dmesg 2>/dev/null | grep "REG_WAIT timeout" | wc -l || echo "0")
RING_TO=$(dmesg 2>/dev/null | grep "ring.*timeout" | wc -l || echo "0")
GPU_RESET=$(dmesg 2>/dev/null | grep "GPU reset" | wc -l || echo "0")
DMUB_LOAD=$(dmesg 2>/dev/null | grep "Loading DMUB firmware" | wc -l || echo "0")

check "REG_WAIT timeout count = 0 (DCN stability)" "0" "$REG_WAIT" "WARN"
check "ring timeout count = 0 (GPU stability)" "0" "$RING_TO" "WARN"
check "GPU reset count = 0 (no crashes)" "0" "$GPU_RESET" "WARN"

if [[ "$DMUB_LOAD" == "1" ]]; then
    DMUB_VER=$(dmesg 2>/dev/null | grep "Loading DMUB firmware" | grep -oP 'version=\S+' || echo "")
    echo "  [PASS] DMUB firmware loaded once: $DMUB_VER"
    ((PASS++)) || true
elif [[ "$DMUB_LOAD" -gt "1" ]]; then
    echo "  [WARN] DMUB loaded $DMUB_LOAD times (>1 = reset loop!)"
    ((WARN++)) || true
else
    echo "  [WARN] DMUB firmware load not found in dmesg"
    ((WARN++)) || true
fi

# --- Summary ---
echo ""
echo "================================================================"
echo " Results: PASS=$PASS  WARN=$WARN  FAIL=$FAIL"
echo "================================================================"

if [[ "$FAIL" -gt 0 ]]; then
    echo " CRITICAL issues found — review FAIL items above."
    exit 1
elif [[ "$WARN" -gt 0 ]]; then
    echo " Warnings present — review WARN items above."
    echo " Most warnings resolve after first full reboot."
    exit 0
else
    echo " All checks passed. System ready."
    exit 0
fi
VERIFY_SCRIPT

chmod +x /usr/local/bin/ml-verify-gpu

# ---------------------------------------------------------------------------
# 18. FIRMWARE STATUS CHECK
# ---------------------------------------------------------------------------
echo "--- Writing firmware status check script ---"

cat > /usr/local/bin/ml-check-firmware << 'FW_SCRIPT'
#!/bin/bash
# =============================================================================
# ml-check-firmware — Check DMCUB and amdgpu firmware versions
# Critical for Raphael iGPU DCN 3.1.5 stability.
# Known-good DMCUB version range: 0.0.224.0 – 0.0.255.0
# Current HEAD: 0.1.53.0 (use with caution; see NixOS #418212)
# =============================================================================
echo ""
echo "=== DMCUB Firmware Version (AMD Raphael iGPU) ==="
dmesg | grep -i "DMUB\|dmub" | head -10

echo ""
echo "=== linux-firmware package version ==="
rpm -q linux-firmware 2>/dev/null || echo "Not an RPM package (manual install?)"

echo ""
echo "=== amdgpu firmware files ==="
ls -lh /lib/firmware/amdgpu/dcn_3_1_5_dmcub* 2>/dev/null || echo "Not found"
ls -lh /lib/firmware/amdgpu/psp_13_0_5_toc* 2>/dev/null || echo "Not found"

echo ""
echo "=== Firmware file conflicts (both .bin and .bin.zst present?) ==="
for f in dcn_3_1_5_dmcub psp_13_0_5_toc psp_13_0_5_ta; do
    if [[ -f "/lib/firmware/amdgpu/${f}.bin" && -f "/lib/firmware/amdgpu/${f}.bin.zst" ]]; then
        echo "  CONFLICT: ${f}.bin AND ${f}.bin.zst both exist!"
        echo "  Kernel prefers .bin.zst — the bare .bin is IGNORED."
        echo "  Fix: sudo zstd -f /lib/firmware/amdgpu/${f}.bin -o /lib/firmware/amdgpu/${f}.bin.zst && sudo rm /lib/firmware/amdgpu/${f}.bin && sudo dracut --force"
    else
        echo "  OK: ${f} (no conflict)"
    fi
done

echo ""
echo "=== amdgpu module parameters ==="
for param in sg_display ppfeaturemask gfx_off gpu_recovery dc; do
    val=$(cat /sys/module/amdgpu/parameters/${param} 2>/dev/null || echo "unavailable")
    echo "  ${param} = ${val}"
done

echo ""
echo "=== Kernel version ==="
uname -r
FW_SCRIPT

chmod +x /usr/local/bin/ml-check-firmware

# ---------------------------------------------------------------------------
# 19. SYSTEM HOSTNAME
# ---------------------------------------------------------------------------
echo "vortex" > /etc/hostname

# ---------------------------------------------------------------------------
# 20. SYSCTL TUNING — ML workstation optimizations
# ---------------------------------------------------------------------------
echo "--- Writing sysctl tuning ---"

cat > /etc/sysctl.d/99-ml-workstation.conf << 'SYSCTL_CONF'
# ML Workstation sysctl tuning
# Raphael iGPU + NVIDIA RTX 4090 dual-GPU system

# Large mmap counts for ML frameworks (PyTorch, TF require many mmap regions)
vm.max_map_count = 2097152

# Reduce swappiness (64G RAM — prefer RAM over swap during training)
vm.swappiness = 10

# Increase dirty writeback window (large model saves)
vm.dirty_ratio = 60
vm.dirty_background_ratio = 5

# Network tuning for distributed training (NCCL, etc.)
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728

# IOMMU passthrough performance
kernel.numa_balancing = 0
SYSCTL_CONF

# ---------------------------------------------------------------------------
# 21. LIMITS — Raise nofile for ML workloads
# ---------------------------------------------------------------------------
cat > /etc/security/limits.d/99-ml-workstation.conf << 'LIMITS_CONF'
# ML Workstation resource limits
# Large models and datasets require many open file handles.
abraham soft nofile 65536
abraham hard nofile 1048576
root soft nofile 65536
root hard nofile 1048576
* soft memlock unlimited
* hard memlock unlimited
LIMITS_CONF

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " Post-install configuration complete."
echo ""
echo " IMPORTANT: POST-INSTALL ACTIONS REQUIRED AFTER FIRST BOOT:"
echo ""
echo " 1. Verify AMD DRI path:"
echo "    ls -la /dev/dri/by-path/"
echo "    Update KWIN_DRM_DEVICES in:"
echo "      /etc/environment"
echo "      /etc/xdg/plasma-workspace/env/ml-workstation.sh"
echo ""
echo " 2. Wait 3+ minutes after login before running GPU tests."
echo "    akmod-nvidia is building the kernel module on first boot."
echo "    Check: systemctl status akmods.service"
echo ""
echo " 3. Run verification script:"
echo "    sudo ml-verify-gpu"
echo ""
echo " 4. Check firmware status:"
echo "    sudo ml-check-firmware"
echo ""
echo " 5. If NVIDIA module not loaded after 5 minutes:"
echo "    sudo akmods --force --rebuild"
echo "    sudo dracut --force"
echo "    sudo reboot"
echo "============================================================"
echo ""

%end

# =============================================================================
# REBOOT
# =============================================================================
# Reboot automatically after installation completes.
# The akmod-nvidia build will begin on first boot (takes 2-3 min).
# Do NOT interrupt the first boot early.
reboot
