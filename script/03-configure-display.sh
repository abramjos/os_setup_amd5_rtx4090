#!/bin/bash
###############################################################################
# 03-configure-display.sh
#
# PURPOSE: Configure X11 display server to use AMD iGPU for rendering and
#          NVIDIA RTX 4090 as headless compute-only. Includes udev rules,
#          environment variables, and systemd services.
#
# WHEN TO RUN: After Phase 2 (02-install-nvidia-driver.sh) and reboot.
#              NVIDIA driver should be loaded (verify: nvidia-smi works).
#
# PREREQUISITES:
#   - Phases 0-2 completed
#   - nvidia-smi shows RTX 4090
#   - Display is on AMD iGPU (glxinfo shows AMD renderer)
#   - Module load order correct (card0=AMD, card1=NVIDIA)
#
# WHAT THIS DOES:
#   1. Creates X11 xorg.conf.d configuration for dual-GPU
#   2. Creates udev rules for GPU seat assignment and permissions
#   3. Configures environment variables for OpenGL/CUDA
#   4. Sets up systemd services (persistence, power, sleep mask)
#   5. Creates ML utility scripts
#   6. Installs monitoring tools
#
# DISPLAY SERVER CHOICE: X11
#   WHY X11 OVER WAYLAND FOR THIS CONFIGURATION:
#   - Deterministic GPU assignment via BusID in xorg.conf
#     Wayland relies on boot GPU detection which can be unreliable with dual GPU
#   - Lower CPU overhead: X11 compositor uses <4% CPU idle
#     Wayland + nvidia.ko loaded: 20-50% CPU overhead even when NVIDIA is headless
#     REF: https://dasroot.net/posts/2025/11/wayland-vs-x11/
#   - No XWayland VRAM leak: X11 apps under Wayland can consume up to 2.4GB
#     of NVIDIA VRAM via XWayland, even when NVIDIA is supposed to be headless
#     REF: https://github.com/NVIDIA/egl-wayland/issues/126
#     REF: https://bbs.archlinux.org/viewtopic.php?id=291454
#   - Better VRAM management: X11 NVIDIA driver can fall back to system RAM on OOM
#     Wayland NVIDIA crashes instead of falling back
#     REF: https://github.com/NVIDIA/egl-wayland/issues/185
#   - No GLVidHeapReuseRatio bug: Wayland compositors trigger NVIDIA buffer
#     caching that consumes up to 2.5GB VRAM and never releases it
#     REF: https://forums.developer.nvidia.com/t/multiple-wayland-compositors-not-freeing-vram-after-resizing-windows/307939
#
#   WHEN TO SWITCH TO WAYLAND:
#   - You need mixed refresh rate multi-monitor (X11 locks to lowest refresh)
#   - You need native HiDPI fractional scaling (X11 workarounds are complex)
#   - To switch: set WaylandEnable=true in /etc/gdm3/custom.conf and add
#     WLR_DRM_DEVICES=/dev/dri/card0 to /etc/environment
#
# REFERENCES:
#   - iGPU display + NVIDIA compute guide: https://gist.github.com/alexlee-gk/76a409f62a53883971a18a11af93241b
#   - Intel/AMD display + NVIDIA compute: https://gist.github.com/wangruohui/bc7b9f424e3d5deb0c0b8bba990b1bc5
#   - AMD Ryzen freezing on Linux: https://gist.github.com/dlqqq/876d74d030f80dc899fc58a244b72df0
#   - NVIDIA persistence daemon: https://docs.nvidia.com/deploy/driver-persistence/index.html
#   - NVIDIA 595 release: https://www.gamingonlinux.com/2026/03/nvidia-driver-595-58-03-released-as-the-big-new-recommended-stable-driver-for-linux/
#
# USAGE: sudo bash 03-configure-display.sh
###############################################################################

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}ERROR: This script must be run as root (sudo).${NC}"
    exit 1
fi

echo -e "${BOLD}================================================================${NC}"
echo -e "${BOLD}  Phase 3: Display & Service Configuration${NC}"
echo -e "${BOLD}  AMD iGPU display + NVIDIA headless compute${NC}"
echo -e "${BOLD}================================================================${NC}"
echo ""

###############################################################################
# AUTO-DETECT PCI BUS IDs
###############################################################################
echo -e "${BLUE}[Auto-detect]${NC} Finding GPU PCI Bus IDs..."

# Detect AMD iGPU BusID
# WHY AUTO-DETECT: PCI BusIDs vary between motherboards and BIOS versions.
#   Hardcoding would fail on different systems. We must read the actual
#   BusID from lspci and convert from hex to decimal for xorg.conf.
# FORMAT: lspci shows "XX:YY.Z" in hex. Xorg needs "PCI:DD:DD:D" in decimal.

AMD_LINE=$(lspci | grep -i "VGA\|Display" | grep -i "AMD\|ATI\|Radeon" | head -1 || true)
NVIDIA_LINE=$(lspci | grep -i "VGA\|3D\|Display" | grep -i "NVIDIA" | head -1 || true)

if [ -z "$AMD_LINE" ]; then
    echo -e "${RED}ERROR: AMD iGPU not detected! Ensure BIOS IGFX Multi-Monitor is Enabled.${NC}"
    echo "REF: https://www.asus.com/support/faq/1045574/"
    exit 1
fi

if [ -z "$NVIDIA_LINE" ]; then
    echo -e "${RED}ERROR: NVIDIA GPU not detected! Check physical seating and power.${NC}"
    exit 1
fi

# Parse AMD BusID
AMD_BUSID_HEX=$(echo "$AMD_LINE" | awk '{print $1}')
AMD_BUS=$(printf "%d" "0x$(echo $AMD_BUSID_HEX | cut -d: -f1)")
AMD_DEV=$(printf "%d" "0x$(echo $AMD_BUSID_HEX | cut -d: -f2 | cut -d. -f1)")
AMD_FUNC=$(echo $AMD_BUSID_HEX | cut -d. -f2)
AMD_XORG_BUSID="PCI:${AMD_BUS}:${AMD_DEV}:${AMD_FUNC}"

# Parse NVIDIA BusID
NV_BUSID_HEX=$(echo "$NVIDIA_LINE" | awk '{print $1}')
NV_BUS=$(printf "%d" "0x$(echo $NV_BUSID_HEX | cut -d: -f1)")
NV_DEV=$(printf "%d" "0x$(echo $NV_BUSID_HEX | cut -d: -f2 | cut -d. -f1)")
NV_FUNC=$(echo $NV_BUSID_HEX | cut -d. -f2)
NV_XORG_BUSID="PCI:${NV_BUS}:${NV_DEV}:${NV_FUNC}"

echo "  AMD iGPU:   $AMD_LINE"
echo "    hex: $AMD_BUSID_HEX → xorg: $AMD_XORG_BUSID"
echo "  NVIDIA GPU: $NVIDIA_LINE"
echo "    hex: $NV_BUSID_HEX → xorg: $NV_XORG_BUSID"
echo ""

###############################################################################
# STEP 1: Create X11 configuration
###############################################################################
echo -e "${BLUE}[Step 1/6]${NC} Creating X11 xorg.conf.d configuration..."

# WHY /etc/X11/xorg.conf.d/ instead of /etc/X11/xorg.conf:
#   - Drop-in directory (.d) is modular — we can add/remove configs independently
#   - xorg.conf is a single monolithic file that gpu-manager may overwrite
#   - The .d directory is processed after xorg.conf, so it takes precedence
#   - Easier to debug: each file handles one aspect of configuration

mkdir -p /etc/X11/xorg.conf.d

# The X11 configuration:
#
# ServerLayout:
#   - Screen 0 = AMD iGPU → this is where the desktop renders
#   - Screen-nvidia = Inactive → NVIDIA has no display attached
#   - AllowNVIDIAGPUScreens → allows CUDA to still access NVIDIA even though
#     it's "Inactive" for display. WITHOUT this, CUDA programs can't find the GPU!
#     REF: https://gist.github.com/alexlee-gk/76a409f62a53883971a18a11af93241b
#
# Device-amd:
#   - Driver "amdgpu" → uses the in-kernel amdgpu DDX (Display Driver eXtension)
#   - BusID must match your actual PCI address (auto-detected above)
#   - TearFree "true" → eliminates screen tearing on the iGPU
#     WHY: amdgpu doesn't enable TearFree by default in X11. Without it,
#          horizontal tearing is visible when scrolling or moving windows.
#
# Device-nvidia:
#   - AllowEmptyInitialConfiguration → NVIDIA starts even with no display connected
#     WHY: Without this, nvidia X11 driver refuses to initialize when no monitor
#          is detected on any output, which prevents CUDA from working.
#   - IgnoreDisplayDevices "CRT" → don't scan for legacy CRT monitors
#     WHY: Reduces initialization time and prevents false monitor detection
#
# REF: https://gist.github.com/alexlee-gk/76a409f62a53883971a18a11af93241b
# REF: https://gist.github.com/wangruohui/bc7b9f424e3d5deb0c0b8bba990b1bc5
# REF: https://bbs.archlinux.org/viewtopic.php?id=269134

cat <<XORGEOF > /etc/X11/xorg.conf.d/10-gpu.conf
# Dual-GPU Configuration: AMD iGPU (display) + NVIDIA RTX 4090 (headless compute)
#
# Auto-generated by ml-workstation-setup/03-configure-display.sh
# Date: $(date -Is)
#
# AMD iGPU BusID: ${AMD_XORG_BUSID} (detected from lspci: ${AMD_BUSID_HEX})
# NVIDIA BusID:   ${NV_XORG_BUSID} (detected from lspci: ${NV_BUSID_HEX})
#
# ARCHITECTURE:
#   Display: Monitor ← HDMI/USB-C ← Motherboard ← AMD Raphael iGPU (amdgpu)
#   Compute: PyTorch/CUDA ← PCIe x16 ← NVIDIA RTX 4090 (nvidia, headless)
#
# REF: https://gist.github.com/alexlee-gk/76a409f62a53883971a18a11af93241b
# REF: https://gist.github.com/wangruohui/bc7b9f424e3d5deb0c0b8bba990b1bc5

Section "ServerLayout"
    Identifier     "Layout0"
    # Screen 0 = AMD iGPU → desktop renders here
    Screen      0  "Screen-amd" 0 0
    # NVIDIA is Inactive for display (no monitor connected)
    Inactive       "Screen-nvidia"
    # AllowNVIDIAGPUScreens: CRITICAL — without this, CUDA cannot find the GPU
    # even though it's present in the system. This option allows NVIDIA to be
    # accessible for compute while remaining Inactive for display.
    Option         "AllowNVIDIAGPUScreens"
EndSection

# === AMD iGPU (Raphael RDNA2 gfx1036) — Display GPU ===
Section "Device"
    Identifier     "Device-amd"
    Driver         "amdgpu"
    BusID          "${AMD_XORG_BUSID}"
    # TearFree: Eliminates horizontal tearing artifacts
    # WHY: amdgpu DDX doesn't enable this by default under X11
    Option         "TearFree" "true"
    # DRI 3: Direct Rendering Infrastructure v3 — better performance than DRI2
    Option         "DRI" "3"
    # AccelMethod: glamor uses OpenGL for 2D acceleration (modern, fast)
    Option         "AccelMethod" "glamor"
EndSection

Section "Screen"
    Identifier     "Screen-amd"
    Device         "Device-amd"
    DefaultDepth   24
    SubSection     "Display"
        Depth      24
        # Add your resolution here if auto-detection fails
        # Modes "3840x2160" "2560x1440" "1920x1080"
    EndSubSection
EndSection

# === NVIDIA RTX 4090 — Headless Compute GPU ===
Section "Device"
    Identifier     "Device-nvidia"
    Driver         "nvidia"
    BusID          "${NV_XORG_BUSID}"
    # AllowEmptyInitialConfiguration: Start even with no display connected
    # WHY: Without this, nvidia refuses to initialize when no monitor is
    #      detected, which would prevent CUDA from working
    Option         "AllowEmptyInitialConfiguration" "on"
    # IgnoreDisplayDevices: Don't scan for legacy CRT monitors
    # WHY: Reduces init time, prevents false detection on headless GPU
    Option         "IgnoreDisplayDevices" "CRT"
    # Coolbits 28: Enables fan/power/clock control via nvidia-settings
    # Bit 2 (4): Manual fan control
    # Bit 3 (8): Thermal monitoring
    # Bit 4 (16): Clock offset control
    # Total: 4+8+16 = 28
    Option         "Coolbits" "28"
EndSection

Section "Screen"
    Identifier     "Screen-nvidia"
    Device         "Device-nvidia"
    # AllowEmptyInitialConfiguration on Screen as well
    Option         "AllowEmptyInitialConfiguration" "on"
EndSection
XORGEOF

echo -e "  ${GREEN}Created /etc/X11/xorg.conf.d/10-gpu.conf${NC}"
echo "    AMD BusID: ${AMD_XORG_BUSID}"
echo "    NVIDIA BusID: ${NV_XORG_BUSID}"

###############################################################################
# STEP 2: Create udev rules
###############################################################################
echo -e "\n${BLUE}[Step 2/6]${NC} Creating udev rules..."

# === Rule 1: Force GDM to use AMD iGPU ===
# WHY: GDM3 (GNOME Display Manager) may attempt to use card1 (NVIDIA) for the
#      login screen if it determines NVIDIA has better capabilities. This udev
#      rule explicitly tags card0 (AMD) as the "master-of-seat" for seat0,
#      ensuring GDM renders on the iGPU.
# WHEN THIS MATTERS: During GDM startup, before our xorg.conf is read.
#      The login screen renders BEFORE X11 processes xorg.conf.d.
# REF: https://gist.github.com/wangruohui/bc7b9f424e3d5deb0c0b8bba990b1bc5

cat <<'EOF' > /etc/udev/rules.d/61-gdm-amd-primary.rules
# Force GDM (GNOME Display Manager) to use AMD iGPU for login screen
# WHY: GDM may prefer NVIDIA GPU if present. This rule ensures card0 (AMD)
#      is tagged as the primary display device for the login seat.
# WHAT: Tags the amdgpu DRM card as "master-of-seat" for seat0
# WHEN: Applied during boot, before GDM starts
# FIX IF BROKEN: If login screen is on wrong GPU, verify card0 is AMD:
#   cat /sys/class/drm/card0/device/vendor  (should be 0x1002)
# REF: https://gist.github.com/wangruohui/bc7b9f424e3d5deb0c0b8bba990b1bc5
TAG+="seat", TAG+="master-of-seat", ENV{ID_SEAT}="seat0", SUBSYSTEM=="drm", KERNEL=="card0", DRIVERS=="amdgpu"
EOF

echo "  Created /etc/udev/rules.d/61-gdm-amd-primary.rules"

# === Rule 2: NVIDIA compute permissions and power management ===
# WHY:
#   - GROUP="render": Allows non-root users in the "render" group to access
#     NVIDIA GPU for CUDA. Without this, CUDA programs need sudo.
#   - MODE="0660": Readable/writable by owner and group only (security)
#   - power/control="auto": Enables runtime power management.
#     When no CUDA workload is active, the GPU enters low-power state (~15W).
#     Combined with NVreg_DynamicPowerManagement=0x02 in modprobe.d.
# RISK: power/control="auto" adds ~ms latency on first CUDA call after idle.
#       Not noticeable in practice for ML workloads.

cat <<'EOF' > /etc/udev/rules.d/99-nvidia-compute.rules
# NVIDIA RTX 4090 compute permissions and power management
#
# GROUP="render": Allows users in "render" group to access GPU for CUDA
#   WHY: Without this, CUDA programs require root/sudo
#   FIX: Add your user to render group: sudo usermod -aG render $USER
#
# power/control="auto": Enable runtime PM for GPU power savings when idle
#   WHY: Headless RTX 4090 drops to ~15W idle instead of staying at 35-60W
#   COMBINED WITH: NVreg_DynamicPowerManagement=0x02 in /etc/modprobe.d/nvidia.conf
#   REF: https://download.nvidia.com/XFree86/Linux-x86_64/595.58.03/README/dynamicpowermanagement.html

# DRM device permissions
SUBSYSTEM=="drm", KERNEL=="card*", DRIVERS=="nvidia", GROUP="render", MODE="0660"

# NVIDIA character device permissions
SUBSYSTEM=="nvidia", GROUP="render", MODE="0660"

# Runtime PM for NVIDIA VGA controller (class 0x030000)
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030000", ATTR{power/control}="auto"

# Runtime PM for NVIDIA 3D controller (class 0x030200)
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030200", ATTR{power/control}="auto"
EOF

echo "  Created /etc/udev/rules.d/99-nvidia-compute.rules"

# Reload udev rules
udevadm control --reload-rules
udevadm trigger
echo -e "  ${GREEN}udev rules applied${NC}"

# Ensure current user is in render group
REAL_USER="${SUDO_USER:-$USER}"
if ! groups "$REAL_USER" 2>/dev/null | grep -q "render"; then
    usermod -aG render "$REAL_USER"
    echo "  Added $REAL_USER to 'render' group (needed for CUDA without sudo)"
    echo -e "  ${YELLOW}NOTE: Group change takes effect on next login${NC}"
fi

###############################################################################
# STEP 3: Configure environment variables
###############################################################################
echo -e "\n${BLUE}[Step 3/6]${NC} Configuring environment variables..."

# WHY ENVIRONMENT VARIABLES MATTER:
#   In a dual-GPU system, desktop applications may try to use the NVIDIA GPU
#   for OpenGL rendering instead of the AMD iGPU. This happens because:
#   - libglvnd (GL Vendor-Neutral Dispatch) may route GL calls to NVIDIA
#   - Applications that use DRI_PRIME for GPU selection may pick wrong GPU
#   - CUDA needs to know which GPU to use (device ordering)
#
# __GLX_VENDOR_LIBRARY_NAME=mesa
#   WHAT: Forces GLX (OpenGL for X11) to use Mesa's implementation
#   WHY:  Without this, libglvnd may route OpenGL calls to NVIDIA's libGLX_nvidia.so
#         instead of Mesa's libGLX_mesa.so. This means desktop apps (browsers,
#         file managers, terminals) would render on the RTX 4090 instead of iGPU.
#   REF:  https://bbs.archlinux.org/viewtopic.php?id=244003
#   REF:  https://wiki.archlinux.org/title/OpenGL
#
# DRI_PRIME=0
#   WHAT: Selects the primary DRI device (0 = card0 = AMD iGPU)
#   WHY:  Some apps check DRI_PRIME for GPU selection. 0 = first GPU = AMD.
#
# __NV_PRIME_RENDER_OFFLOAD=0
#   WHAT: Disables NVIDIA PRIME render offload
#   WHY:  Prevents desktop apps from offloading rendering to the NVIDIA GPU.
#         We want all desktop rendering on AMD iGPU; NVIDIA is compute-only.
#
# CUDA_VISIBLE_DEVICES=0
#   WHAT: Limits CUDA to device 0 (the RTX 4090)
#   WHY:  In a multi-GPU system, explicitly selecting the compute GPU prevents
#         CUDA from accidentally trying to use the iGPU (which has no CUDA).
#
# CUDA_DEVICE_ORDER=PCI_BUS_ID
#   WHAT: Orders CUDA devices by PCI bus address instead of driver enumeration
#   WHY:  Ensures consistent device numbering across reboots. The default
#         "FASTEST_FIRST" ordering can change if driver init order changes.
#   REF:  https://docs.nvidia.com/cuda/cuda-c-programming-guide/

# Add to /etc/environment (system-wide, affects all users and GDM)
# Using /etc/environment because these need to be active even for the login screen
# and for services that don't source .bashrc
if ! grep -q "GLX_VENDOR_LIBRARY_NAME" /etc/environment 2>/dev/null; then
    cat <<'EOF' >> /etc/environment

# === ML Workstation Dual-GPU Environment ===
# Force desktop OpenGL to use AMD Mesa (not NVIDIA)
# REF: https://bbs.archlinux.org/viewtopic.php?id=244003
__GLX_VENDOR_LIBRARY_NAME=mesa
# Disable VSync for compute workstation (reduces latency)
__GL_SYNC_TO_VBLANK=0
# Select primary DRI device (0 = card0 = AMD iGPU)
DRI_PRIME=0
# Disable PRIME render offload (keep desktop rendering on AMD, not NVIDIA)
__NV_PRIME_RENDER_OFFLOAD=0
EOF
    echo "  Added GL/DRI variables to /etc/environment"
fi

# Create CUDA environment script for user shell
# Using a separate file in /etc/profile.d/ so it's sourced for all login shells
cat <<'CUDAEOF' > /etc/profile.d/cuda-env.sh
# CUDA Environment for ML Workstation
# Auto-generated by ml-workstation-setup
#
# These variables configure CUDA to use the RTX 4090 for compute
# and ensure consistent device numbering across reboots.
#
# REF: https://docs.nvidia.com/cuda/cuda-c-programming-guide/

# CUDA toolkit paths
if [ -d /usr/local/cuda ]; then
    export PATH=/usr/local/cuda/bin:$PATH
    export LD_LIBRARY_PATH=/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}
fi

# CUDA device selection
export CUDA_VISIBLE_DEVICES=0
export CUDA_DEVICE_ORDER=PCI_BUS_ID

# PyTorch optimizations for Ada Lovelace (RTX 4090)
# expandable_segments: Reduces CUDA memory fragmentation
# REF: https://pytorch.org/docs/stable/notes/cuda.html
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True

# cuDNN v8 API: improved kernel selection, 10-30% faster convolutions on Ada Lovelace
# REF: https://docs.nvidia.com/deeplearning/cudnn/latest/developer/cudnn-v8-api.html
export TORCH_CUDNN_V8_API_ENABLED=1

# NCCL (NVIDIA Collective Communications Library) settings
# Optimized for single-GPU workstation
export NCCL_P2P_DISABLE=0    # Enable peer-to-peer (for future multi-GPU)
export NCCL_IB_DISABLE=1     # Disable InfiniBand (not present)
export NCCL_SHM_DISABLE=0    # Enable shared memory transport
export NCCL_SOCKET_IFNAME=lo # Use loopback for single-node
CUDAEOF

chmod 644 /etc/profile.d/cuda-env.sh
echo -e "  ${GREEN}Environment variables configured${NC}"

###############################################################################
# STEP 4: Configure systemd services
###############################################################################
echo -e "\n${BLUE}[Step 4/6]${NC} Configuring systemd services..."

# === nvidia-persistenced ===
# WHY: Without persistence mode, the NVIDIA kernel module tears down GPU state
#      every time the last CUDA program exits. The next CUDA call must re-initialize
#      the entire GPU, taking ~1.5 minutes on some configurations. With persistence
#      mode, the GPU stays initialized and CUDA startup is ~4 seconds.
# REF: https://docs.nvidia.com/deploy/driver-persistence/index.html
# REF: https://docs.nvidia.com/deploy/driver-persistence/persistence-daemon.html

systemctl enable nvidia-persistenced 2>/dev/null || true
systemctl start nvidia-persistenced 2>/dev/null || true
echo "  nvidia-persistenced: enabled and started"

# === nvidia-powerd ===
# WHY: nvidia-powerd is a daemon for dynamic power management on supported GPUs.
#      For our headless compute GPU, NVreg_DynamicPowerManagement=0x02 in modprobe.d
#      handles power management at the kernel level. nvidia-powerd adds unnecessary
#      overhead and can conflict with manual power settings.
# WHEN TO ENABLE: Only if you notice the GPU not entering low-power idle state.

systemctl disable nvidia-powerd 2>/dev/null || true
echo "  nvidia-powerd: disabled (NVreg handles power for headless GPU)"

# === nvidia-power-settings (custom service) ===
# WHY: Ensures nvidia-smi persistence mode is set on every boot.
#      nvidia-persistenced handles the daemon, but nvidia-smi -pm 1 explicitly
#      sets the flag in the driver.

cat <<'EOF' > /etc/systemd/system/nvidia-power-settings.service
# NVIDIA GPU Power Settings — applied at boot
# WHY: Sets persistence mode via nvidia-smi to ensure fast CUDA initialization
# DEPENDS ON: nvidia-persistenced must be running first
# REF: https://docs.nvidia.com/deploy/driver-persistence/index.html

[Unit]
Description=NVIDIA GPU Power Settings for ML Workstation
After=nvidia-persistenced.service
Requires=nvidia-persistenced.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/nvidia-smi -pm 1

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable nvidia-power-settings
echo "  nvidia-power-settings: enabled"

# === gpu-manager ===
# Ensure it stays disabled (Phase 1 should have done this, but double-check)
systemctl disable gpu-manager 2>/dev/null || true
systemctl mask gpu-manager 2>/dev/null || true
echo "  gpu-manager: disabled and masked"

# === power-profiles-daemon: set to "performance" ===
# WHY: power-profiles-daemon (PPD) v0.20+ integrates with the amd_pstate EPP driver.
#      It sets the energy_performance_preference (EPP) hint for all CPU cores via
#      /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference.
#      "performance" profile sets EPP to "performance" — the CPU targets maximum
#      frequency at all times. This is optimal for an ML workstation where CPU
#      throughput directly affects data loading speed and training iteration time.
#      The "balanced" default trades throughput for power savings, which adds
#      latency to data pipeline operations.
# VERIFY: powerprofilesctl get  (should show "performance")
# NOTE: This only affects CPU frequency scaling. GPU power is managed separately
#       by NVreg_DynamicPowerManagement in modprobe.d.
# REF: https://wiki.archlinux.org/title/CPU_frequency_scaling#power-profiles-daemon
# REF: https://docs.kernel.org/admin-guide/pm/amd-pstate.html
if command -v powerprofilesctl &>/dev/null; then
    powerprofilesctl set performance 2>/dev/null || true
    echo "  power-profiles-daemon: set to 'performance' (max CPU throughput)"

    # Create a systemd drop-in to ensure performance profile persists across reboots
    # WHY: PPD resets to "balanced" on every service restart. The drop-in runs
    #      powerprofilesctl after the service starts to override this default.
    mkdir -p /etc/systemd/system/power-profiles-daemon.service.d
    cat <<'PPDEOF' > /etc/systemd/system/power-profiles-daemon.service.d/ml-performance.conf
# Ensure "performance" profile is applied after PPD starts
# Created by ml-workstation-setup for ML training optimization
# REF: https://wiki.archlinux.org/title/CPU_frequency_scaling#power-profiles-daemon
[Service]
ExecStartPost=/usr/bin/powerprofilesctl set performance
PPDEOF
    systemctl daemon-reload
    echo "  power-profiles-daemon: performance profile will persist across reboots"
else
    echo -e "  ${YELLOW}[INFO]${NC} power-profiles-daemon not installed — CPU frequency managed by amd_pstate defaults"
    echo "         amd_pstate EPP defaults to 'balance_performance' which is acceptable"
fi

# === Disable sleep/suspend/hibernate ===
# WHY: For a dedicated ML workstation, sleep/suspend causes:
#      - Multi-monitor wake failures (AMD iGPU + multi-display is problematic)
#        REF: https://forums.developer.nvidia.com/t/no-video-on-displayport-after-computer-sleep-hdmi-works/304794
#      - GPU state loss (even with NVreg_PreserveVideoMemoryAllocations, resume can fail)
#      - Training job interruption (obvious — multi-hour jobs can't tolerate suspend)
#      - Dual-GPU state restoration conflicts (amdgpu + nvidia resume order issues)
# WHAT: systemctl mask creates a symlink to /dev/null, making the target impossible to start
# RISK: None for ML workstation (it should be running 24/7 during training)

systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null || true
echo "  sleep/suspend/hibernate: masked"

echo -e "  ${GREEN}Systemd services configured${NC}"

###############################################################################
# STEP 5: Creating ML utility scripts
###############################################################################
echo -e "\n${BLUE}[Step 5/6]${NC} Creating ML utility scripts..."

# WHY A SEPARATE SCRIPT:
#   During ML training, we want consistent, reproducible performance.
#   GPU clock frequencies boost dynamically, which causes variable batch times.
#   Locking clocks ensures every training step takes approximately the same time,
#   making training curves smoother and performance benchmarks reliable.
#
# CLOCK VALUES:
#   GPU core: 2235-2520 MHz (base to boost range for RTX 4090)
#   Memory: 10501 MHz (GDDR6X maximum for RTX 4090)
#   REF: https://indii.org/blog/fix-clock-speed-on-nvidia-gpu/
#   REF: https://forums.developer.nvidia.com/t/can-not-to-lock-gpu-clock-rtx-4090/286603
#
# CUDANOSTABLEPERFIMIT:
#   Driver 595 introduces the CudaNoStablePerfLimit application profile.
#   This allows CUDA workloads to reach P0 PState (full clocks) instead of
#   being limited to P2 (reduced memory clocks). This is automatic in 595
#   and doesn't need manual activation — just having the driver is enough.
#   REF: https://www.gamingonlinux.com/2026/03/nvidia-driver-595-58-03-released-as-the-big-new-recommended-stable-driver-for-linux/

cat <<'MLEOF' > /usr/local/bin/gpu-ml-setup.sh
#!/bin/bash
###############################################################################
# gpu-ml-setup.sh — Configure RTX 4090 for ML Training
#
# PURPOSE: Lock GPU clocks for consistent, reproducible training performance.
#          Run before starting ML training sessions.
#
# WHAT IT DOES:
#   1. Enables persistence mode (fast CUDA init)
#   2. Locks GPU core clocks to maximum boost range
#   3. Locks memory clocks to maximum (GDDR6X)
#   4. Displays current GPU state
#
# CLOCK LOCKING EXPLAINED:
#   Without locking, the GPU dynamically adjusts clocks based on thermal
#   headroom and power consumption. This causes variable batch times:
#   - Batch 1: 1.2s (GPU cold, high boost)
#   - Batch 100: 1.4s (GPU hot, thermal throttle reduces clocks)
#   - Batch 200: 1.3s (equilibrium)
#   With locking, all batches are ~1.3s (consistent, predictable).
#
# RTX 4090 CLOCK RANGES:
#   Core: 210 MHz (idle) to 2520 MHz (max boost)
#   Memory: 405 MHz (idle) to 10501 MHz (max GDDR6X)
#   We lock to the full operating range so the GPU boosts to max but
#   doesn't drop below base clock during sustained load.
#
# NOTE: Thermal throttling still works even with locked clocks.
#   If GPU temp exceeds ~83°C, hardware will reduce clocks regardless.
#   This protects the hardware — our lock just sets the target, not a hard override.
#
# REF: https://indii.org/blog/fix-clock-speed-on-nvidia-gpu/
# REF: https://forums.developer.nvidia.com/t/can-not-to-lock-gpu-clock-rtx-4090/286603
# REF: https://developer.nvidia.com/blog/advanced-api-performance-setstablepowerstate/
#
# USAGE: sudo gpu-ml-setup.sh           # Set up for training
#        sudo gpu-ml-setup.sh --reset   # Reset to default clocks after training
###############################################################################

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Run as root (sudo)"
    exit 1
fi

if [ "${1:-}" = "--reset" ]; then
    echo "Resetting GPU clocks to defaults..."
    nvidia-smi -rgc 2>/dev/null || true   # Reset GPU clocks
    nvidia-smi -rmc 2>/dev/null || true   # Reset memory clocks
    echo "GPU clocks reset. GPU will now dynamically adjust."
    nvidia-smi -q -d CLOCK | head -30
    exit 0
fi

echo "=== Configuring RTX 4090 for ML Training ==="
echo ""

# Step 1: Persistence mode
echo "[1/4] Enabling persistence mode..."
nvidia-smi -pm 1
echo "  Done — GPU state will persist between CUDA calls"

# Step 2: Lock GPU core clocks
echo "[2/4] Locking GPU core clocks: 2235-2520 MHz..."
nvidia-smi -lgc 2235,2520
echo "  Done — core will stay within base (2235) to boost (2520) range"

# Step 3: Lock memory clocks
echo "[3/4] Locking memory clocks: 10501 MHz..."
nvidia-smi -lmc 10501,10501
echo "  Done — GDDR6X running at maximum bandwidth (1,008 GB/s)"

# Step 3b: Display NUMA topology for ML optimization
echo ""
echo "[INFO] NUMA topology:"
if command -v numactl &>/dev/null; then
    # Find RTX 4090's NUMA node via its PCI address
    NV_PCI=\$(lspci -D 2>/dev/null | grep -i nvidia | head -1 | awk '{print \$1}')
    if [ -n "\$NV_PCI" ] && [ -f "/sys/bus/pci/devices/\${NV_PCI}/numa_node" ]; then
        NUMA_NODE=\$(cat "/sys/bus/pci/devices/\${NV_PCI}/numa_node" 2>/dev/null || echo "-1")
        echo "  RTX 4090 NUMA node: \$NUMA_NODE"
        if [ "\$NUMA_NODE" != "-1" ] && [ "\$NUMA_NODE" != "0" ]; then
            echo "  TIP: For best PCIe bandwidth, pin data loading to NUMA node \$NUMA_NODE:"
            echo "       numactl --cpunodebind=\$NUMA_NODE --membind=\$NUMA_NODE python train.py"
        else
            echo "  Single NUMA node (AM5 is single-socket) — no NUMA pinning needed."
            echo "  TIP: For multi-worker data loading, pin to specific cores to avoid contention:"
            echo "       taskset -c 0-15 python train.py  # Use first 16 cores for training"
        fi
    else
        echo "  Could not determine NUMA node for NVIDIA GPU"
    fi
else
    echo "  numactl not installed. Install for NUMA optimization: sudo apt install numactl"
fi

# Step 4: Display status
echo "[4/4] Current GPU state:"
echo ""
nvidia-smi
echo ""
echo "=== GPU configured for ML training ==="
echo "To reset after training: sudo gpu-ml-reset.sh (or: sudo gpu-ml-setup.sh --reset)"
MLEOF

chmod +x /usr/local/bin/gpu-ml-setup.sh
echo -e "  ${GREEN}Created /usr/local/bin/gpu-ml-setup.sh${NC}"

# --- gpu-ml-reset.sh: Reset clocks after training ---
cat <<'RESETEOF' > /usr/local/bin/gpu-ml-reset.sh
#!/bin/bash
# =============================================================================
# gpu-ml-reset.sh — Reset RTX 4090 to Default Clock Configuration
# =============================================================================
#
# Run this AFTER ML training to restore default clock behavior.
# The GPU will resume dynamic clock scaling based on load.
#
# This is useful when:
#   - Switching from training to development (lower power, less noise)
#   - Troubleshooting thermal issues (unlock clocks to allow throttling)
#
# USAGE: sudo gpu-ml-reset.sh
# =============================================================================

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Run with sudo"
    exit 1
fi

echo "=== Resetting RTX 4090 to default clocks ==="

# Reset GPU clocks (resume dynamic scaling)
echo "[1/3] Resetting GPU clocks..."
nvidia-smi -rgc

# Reset memory clocks
echo "[2/3] Resetting memory clocks..."
nvidia-smi -rmc

# Keep persistence mode on (it's always useful)
echo "[3/3] Persistence mode remains enabled."

echo ""
echo "=== GPU reset to default clock behavior ==="
echo "  Clocks will now dynamically scale based on load."
nvidia-smi -q -d CLOCK | grep -E "Graphics|Memory" | head -4
RESETEOF

chmod +x /usr/local/bin/gpu-ml-reset.sh
echo -e "  ${GREEN}Created /usr/local/bin/gpu-ml-reset.sh${NC}"

# --- gpu-status.sh: Quick GPU status check (no root required) ---
cat <<'STATUSEOF' > /usr/local/bin/gpu-status.sh
#!/bin/bash
# =============================================================================
# gpu-status.sh — Quick GPU Status for ML Workstation
# =============================================================================
#
# Shows a concise status of both GPUs (AMD iGPU + NVIDIA RTX 4090).
# No root required.
#
# USAGE: gpu-status.sh
# =============================================================================

echo "=== GPU Status ==="
echo ""

# DRM Card Assignment
echo "--- DRM Devices ---"
for card in /sys/class/drm/card[0-9]; do
    if [ -d "$card" ]; then
        name=$(basename "$card")
        vendor=$(cat "$card/device/vendor" 2>/dev/null || echo "?")
        driver=$(basename "$(readlink "$card/device/driver" 2>/dev/null)" 2>/dev/null || echo "?")
        echo "  $name: vendor=$vendor driver=$driver"
    fi
done
echo ""

# Display renderer
if command -v glxinfo &>/dev/null && [ -n "${DISPLAY:-}" ]; then
    echo "--- Display Renderer ---"
    glxinfo 2>/dev/null | grep "OpenGL renderer" | head -1 | sed 's/^/  /'
    echo ""
fi

# NVIDIA GPU status
echo "--- NVIDIA RTX 4090 ---"
if command -v nvidia-smi &>/dev/null; then
    nvidia-smi --query-gpu=name,driver_version,pstate,temperature.gpu,power.draw,power.limit,utilization.gpu,utilization.memory,memory.used,memory.total,display_active,display_mode --format=csv,noheader 2>/dev/null | \
    while IFS=',' read -r name driver pstate temp power plimit gpu_util mem_util mem_used mem_total disp_active disp_mode; do
        echo "  Name: $name"
        echo "  Driver: $driver"
        echo "  PState: $pstate"
        echo "  Temperature: $temp"
        echo "  Power: $power / $plimit"
        echo "  GPU Utilization: $gpu_util"
        echo "  Memory: $mem_used / $mem_total ($mem_util)"
        echo "  Display Active: $disp_active"
        echo "  Display Mode: $disp_mode"
    done

    # Check exec timeout
    TIMEOUT=$(nvidia-smi -q 2>/dev/null | grep "Kernel Exec Timeout" | awk -F: '{print $2}' | xargs || echo "?")
    echo "  Kernel Exec Timeout: $TIMEOUT"

    # Check persistence
    PERSIST=$(nvidia-smi -q 2>/dev/null | grep "Persistence Mode" | head -1 | awk -F: '{print $2}' | xargs || echo "?")
    echo "  Persistence Mode: $PERSIST"

    # PCIe
    PCI_GEN=$(nvidia-smi -q 2>/dev/null | grep "Current.*Gen" | head -1 | awk -F: '{print $2}' | xargs || echo "?")
    PCI_WIDTH=$(nvidia-smi -q 2>/dev/null | grep "Current.*x" | head -1 | awk -F: '{print $2}' | xargs || echo "?")
    echo "  PCIe: Gen $PCI_GEN, Width $PCI_WIDTH"

    # Processes
    echo ""
    echo "--- NVIDIA Processes ---"
    nvidia-smi --query-compute-apps=pid,name,used_memory --format=csv,noheader 2>/dev/null || echo "  No compute processes"
else
    echo "  nvidia-smi not available"
fi
STATUSEOF

chmod +x /usr/local/bin/gpu-status.sh
echo -e "  ${GREEN}Created /usr/local/bin/gpu-status.sh${NC}"

###############################################################################
# STEP 6: Install monitoring tools
###############################################################################
echo -e "\n${BLUE}[Step 6/6]${NC} Installing monitoring tools..."

# nvtop: Real-time GPU monitoring (shows both AMD and NVIDIA GPUs)
# radeontop: AMD GPU utilization monitor
# htop: CPU/RAM monitor
# mesa-utils: glxinfo, glxgears for display verification
# vainfo: VA-API (hardware video decode) verification
# inxi: System information tool

apt install -y nvtop radeontop htop mesa-utils vainfo inxi numactl 2>/dev/null || true
echo -e "  ${GREEN}Monitoring tools installed${NC}"

###############################################################################
# Summary
###############################################################################
echo ""
echo -e "${BOLD}================================================================${NC}"
echo -e "${GREEN}${BOLD}  Phase 3 Complete!${NC}"
echo -e "${BOLD}================================================================${NC}"
echo ""
echo "  Changes applied:"
echo "    [1] X11 xorg.conf.d created (AMD display + NVIDIA headless)"
echo "        AMD BusID: ${AMD_XORG_BUSID} | NVIDIA BusID: ${NV_XORG_BUSID}"
echo "    [2] udev rules: GDM seat assignment + NVIDIA compute permissions"
echo "    [3] Environment variables: GLX, DRI, CUDA, PyTorch, NCCL"
echo "    [4] Systemd: persistence enabled, sleep masked, gpu-manager blocked"
echo "    [5] ML utility scripts: gpu-ml-setup.sh, gpu-ml-reset.sh, gpu-status.sh"
echo "    [6] Monitoring tools: nvtop, radeontop, htop, vainfo, numactl"
echo "    [+] power-profiles-daemon: performance profile (max CPU throughput)"
echo "    [+] numactl installed for NUMA/core pinning guidance"
echo ""
echo -e "  ${YELLOW}REBOOT REQUIRED to apply X11 and udev changes.${NC}"
echo ""
echo "  After reboot, run the full verification:"
echo "    sudo bash verification/verify-complete-system.sh"
echo ""
echo "  Quick manual checks:"
echo "    glxinfo | grep 'OpenGL renderer'     # Should show AMD Radeon"
echo "    nvidia-smi                            # Should show RTX 4090, no processes"
echo "    nvidia-smi -q | grep 'Kernel Exec'   # Should show: No"
echo ""
read -p "Press Enter to reboot now, or Ctrl+C to reboot manually later... "
reboot
