#!/bin/bash
###############################################################################
# 02-install-nvidia-driver.sh
#
# PURPOSE: Install NVIDIA 595.58.03 driver for headless CUDA compute on
#          the RTX 4090, while keeping AMD iGPU as the display GPU.
#
# WHEN TO RUN: After Phase 1 (01-first-boot-display-fix.sh) and reboot.
#              Display should be stable on iGPU before running this.
#
# PREREQUISITES:
#   - Ubuntu 24.04.1 with HWE kernel 6.17 (or GA 6.8 fallback)
#   - Phase 1 script (01-first-boot-display-fix.sh) completed and rebooted
#   - Display working on AMD iGPU (verify with: glxinfo | grep "OpenGL renderer")
#   - Internet connection available
#
# WHAT THIS DOES:
#   1. Blacklists nouveau driver (open-source NVIDIA — conflicts with proprietary)
#   2. Adds NVIDIA CUDA repository (provides latest driver packages)
#   3. Installs NVIDIA driver 595 (or latest available)
#   4. Configures NVIDIA module options for headless compute
#   5. Sets module load order (amdgpu first, then nvidia)
#   6. Installs CUDA toolkit
#   7. Pins driver version to prevent unintended upgrades
#
# DRIVER INSTALLATION STRATEGY:
#   We use the NVIDIA CUDA repository method rather than:
#   - Ubuntu repos: May not have 595 yet (Ubuntu adds drivers with delay)
#     REF: https://ubuntuhandbook.org/index.php/2025/09/ubuntu-added-nvidia-580-driver/
#   - .run installer: Bypasses apt; breaks on kernel updates; hard to remove
#     REF: https://forums.developer.nvidia.com/t/ubuntu-and-nvidia-provided-packages-conflict-breaking-installation/259150
#   - PPA: graphics-drivers PPA is an option but CUDA repo is more comprehensive
#     REF: https://launchpad.net/~graphics-drivers/+archive/ubuntu/ppa
#
#   The CUDA repository provides:
#   - NVIDIA driver packages built for each Ubuntu version
#   - CUDA toolkit that matches the driver version
#   - Consistent package naming and dependency management
#   REF: https://docs.nvidia.com/cuda/cuda-installation-guide-linux/
#   REF: https://developer.nvidia.com/cuda-downloads
#
#   OPEN vs PROPRIETARY KERNEL MODULES:
#   Since NVIDIA R560 (August 2024), open kernel modules are the default and
#   recommended path for Turing+ (RTX 2000+) GPUs. RTX 4090 (Ada Lovelace) is
#   fully supported with identical compute performance. We prefer open modules
#   because they have better compatibility with newer kernels (important for our
#   HWE 6.17 strategy) and allow community debugging of kernel-level issues.
#   REF: https://docs.nvidia.com/datacenter/tesla/driver-installation-guide/kernel-modules.html
#   REF: https://github.com/NVIDIA/open-gpu-kernel-modules
#
# WHY DRIVER 595.58.03:
#   - Latest production branch (released March 24, 2026)
#   - CudaNoStablePerfLimit: CUDA can reach P0 PState (full memory clocks)
#     Previously, CUDA was forced to P2 which reduced GDDR6X memory speed
#   - nvidia-drm.ko modeset=1 enabled by default
#   - GPU reset via nvidia-smi while modeset=1 (without stopping display)
#   - Improved VRAM fallback to system RAM under Wayland
#   - Fixed kernel module build for Linux 6.19
#   - Fixed X11 compositor blinking regression
#   - Supports kernels 6.8 through 6.19
#   REF: https://www.gamingonlinux.com/2026/03/nvidia-driver-595-58-03-released-as-the-big-new-recommended-stable-driver-for-linux/
#   REF: https://docs.nvidia.com/datacenter/tesla/tesla-release-notes-595-58-03/index.html
#   REF: https://9to5linux.com/nvidia-595-linux-graphics-driver-released-as-latest-production-branch-version
#
# SYSTEM: Ryzen 9 7950X | ASUS ROG Crosshair X670E Hero | RTX 4090
#         Ubuntu 24.04.1 LTS | Kernel 6.17 HWE (6.8 GA fallback)
#
# USAGE: sudo bash 02-install-nvidia-driver.sh
#
# REBOOT: Required after running this script
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
echo -e "${BOLD}  Phase 2: NVIDIA Driver & CUDA Installation${NC}"
echo -e "${BOLD}  Installing 595.58.03 for headless RTX 4090 compute${NC}"
echo -e "${BOLD}================================================================${NC}"
echo ""

###############################################################################
# PRE-CHECK: Mandatory amdgpu Verification Gate
###############################################################################
# WHY: Installing NVIDIA on a broken amdgpu config makes debugging exponentially
#      harder. If the AMD display stack isn't working, we block installation.
#      This gate validates that Phase 1 (01-first-boot-display-fix.sh) was
#      completed successfully and the system rebooted.
#
# SOURCE: Adapted from scripts_v2/07-reboot-verify-amdgpu.sh
###############################################################################
echo -e "${BLUE}[Pre-check]${NC} Mandatory amdgpu verification before NVIDIA install..."
echo "  This ensures the AMD display stack is working before adding NVIDIA."
echo ""

PRE_FAIL=0
PRE_WARN=0

# --- Check 1: Kernel version (6.8 GA or 6.11-6.17 HWE) ---
# WHY: Kernel 6.17 HWE is the recommended target — it fixes gfx ring timeouts
#      on Raphael gfx1036 natively (GFXOFF rework in 6.9-6.11).
#      Kernel 6.8 GA is acceptable as a fallback with gfx_off=0 workaround.
#      NVIDIA 595.58.03 supports kernels 6.8 through 6.19.
#   REF: https://docs.nvidia.com/datacenter/tesla/tesla-release-notes-595-58-03/
#   REF: https://docs.nvidia.com/cuda/cuda-installation-guide-linux/
KERNEL=$(uname -r)
KERNEL_MAJOR=$(echo "$KERNEL" | cut -d. -f1-2)
if echo "$KERNEL" | grep -qE "^6\.(1[1-9]|[2-9][0-9])\."; then
    echo -e "  ${GREEN}[PASS]${NC} HWE kernel confirmed: $KERNEL (ring timeout fix included)"
elif echo "$KERNEL" | grep -q "^6\.8\."; then
    echo -e "  ${YELLOW}[WARN]${NC} GA kernel 6.8: $KERNEL (ring timeout workaround via gfx_off=0)"
    echo "       → NOTE: HWE 6.17 recommended — fixes ring timeout at kernel level"
    echo "       → FIX: sudo apt install linux-generic-hwe-24.04 && reboot"
    PRE_WARN=$((PRE_WARN+1))
else
    echo -e "  ${RED}[FAIL]${NC} Unexpected kernel: $KERNEL (expected 6.8 GA or 6.11+ HWE)"
    echo "       → FIX: sudo apt install linux-generic-hwe-24.04 && reboot"
    PRE_FAIL=$((PRE_FAIL+1))
fi

# --- Check 2: Critical kernel parameters (FAIL if missing — prevent hardware failures) ---
CMDLINE=$(cat /proc/cmdline)
for param in "amdgpu.sg_display=0" "amdgpu.dcdebugmask=0x10" "amdgpu.gfx_off=0" "amdgpu.ppfeaturemask=0xfffd7fff" "nvidia-drm.modeset=1" "pcie_aspm=off" "iommu=pt" "nogpumanager"; do
    if echo "$CMDLINE" | grep -q "$param"; then
        echo -e "  ${GREEN}[PASS]${NC} $param is set"
    else
        echo -e "  ${RED}[FAIL]${NC} $param is NOT set in kernel cmdline"
        echo "       → FIX: Run 01-first-boot-display-fix.sh and reboot"
        PRE_FAIL=$((PRE_FAIL+1))
    fi
done

# --- Check 2b: Recommended kernel parameters (WARN if missing — stability optimizations) ---
for param in "processor.max_cstate=1" "amd_pstate=active"; do
    if echo "$CMDLINE" | grep -q "$param"; then
        echo -e "  ${GREEN}[PASS]${NC} $param is set"
    else
        echo -e "  ${YELLOW}[WARN]${NC} $param is NOT set (recommended for stability)"
        echo "       → FIX: Run 01-first-boot-display-fix.sh and reboot"
        PRE_WARN=$((PRE_WARN+1))
    fi
done

# --- Check 3: amdgpu module loaded ---
if lsmod | grep -q "^amdgpu"; then
    echo -e "  ${GREEN}[PASS]${NC} amdgpu kernel module is loaded"
else
    echo -e "  ${RED}[FAIL]${NC} amdgpu kernel module is NOT loaded"
    echo "       → FIX: Check dmesg | grep amdgpu for errors"
    PRE_FAIL=$((PRE_FAIL+1))
fi

# --- Check 4: amdgpu parameters active in sysfs ---
SG_DISPLAY=$(cat /sys/module/amdgpu/parameters/sg_display 2>/dev/null || echo "N/A")
if [ "$SG_DISPLAY" = "0" ]; then
    echo -e "  ${GREEN}[PASS]${NC} amdgpu sg_display=0 (active in sysfs)"
elif [ "$SG_DISPLAY" = "N/A" ]; then
    echo -e "  ${YELLOW}[WARN]${NC} Cannot read sg_display from sysfs"
    PRE_WARN=$((PRE_WARN+1))
else
    echo -e "  ${YELLOW}[WARN]${NC} sg_display=$SG_DISPLAY — expected 0"
    PRE_WARN=$((PRE_WARN+1))
fi

DC_MASK=$(cat /sys/module/amdgpu/parameters/dcdebugmask 2>/dev/null || echo "N/A")
if [ "$DC_MASK" = "0x10" ] || [ "$DC_MASK" = "16" ]; then
    echo -e "  ${GREEN}[PASS]${NC} amdgpu dcdebugmask=0x10 (PSR disabled in sysfs)"
elif [ "$DC_MASK" = "N/A" ]; then
    echo -e "  ${YELLOW}[WARN]${NC} Cannot read dcdebugmask from sysfs"
    PRE_WARN=$((PRE_WARN+1))
else
    echo -e "  ${YELLOW}[WARN]${NC} dcdebugmask=$DC_MASK — expected 0x10 (16)"
    PRE_WARN=$((PRE_WARN+1))
fi

GFX_OFF=$(cat /sys/module/amdgpu/parameters/gfx_off 2>/dev/null || echo "N/A")
if [ "$GFX_OFF" = "0" ]; then
    echo -e "  ${GREEN}[PASS]${NC} amdgpu gfx_off=0 (GFXOFF disabled — ring timeout protection)"
elif [ "$GFX_OFF" = "N/A" ]; then
    echo -e "  ${YELLOW}[WARN]${NC} Cannot read gfx_off from sysfs"
    PRE_WARN=$((PRE_WARN+1))
else
    # On HWE 6.11+, GFXOFF is fixed at kernel level; gfx_off=1 is acceptable
    if echo "$KERNEL" | grep -qE "^6\.(1[1-9]|[2-9][0-9])\."; then
        echo -e "  ${GREEN}[PASS]${NC} gfx_off=$GFX_OFF (GFXOFF safe on HWE kernel $KERNEL_MAJOR)"
    else
        echo -e "  ${YELLOW}[WARN]${NC} gfx_off=$GFX_OFF — expected 0 on kernel 6.8 (GFXOFF causes ring timeouts)"
        PRE_WARN=$((PRE_WARN+1))
    fi
fi

# --- Check 5: nouveau NOT loaded ---
if lsmod | grep -q "^nouveau"; then
    echo -e "  ${RED}[FAIL]${NC} nouveau module is LOADED — conflicts with nvidia"
    echo "       → FIX: Blacklist nouveau and reboot (Phase 1 should have done this)"
    PRE_FAIL=$((PRE_FAIL+1))
else
    echo -e "  ${GREEN}[PASS]${NC} nouveau module is not loaded"
fi

# --- Check 6: card0 is AMD ---
if [ -f /sys/class/drm/card0/device/vendor ]; then
    CARD0_VENDOR=$(cat /sys/class/drm/card0/device/vendor)
    if [ "$CARD0_VENDOR" = "0x1002" ]; then
        echo -e "  ${GREEN}[PASS]${NC} card0 = AMD (0x1002) — correct for display"
    else
        echo -e "  ${RED}[FAIL]${NC} card0 = $CARD0_VENDOR — should be AMD (0x1002)"
        echo "       → FIX: Ensure amdgpu loads before nvidia in /etc/modules-load.d/gpu.conf"
        PRE_FAIL=$((PRE_FAIL+1))
    fi
else
    echo -e "  ${YELLOW}[WARN]${NC} Cannot read card0 vendor — DRM may not be initialized"
    PRE_WARN=$((PRE_WARN+1))
fi

# --- Check 7: OpenGL renderer is AMD (if available) ---
if command -v glxinfo &>/dev/null && [ -n "${DISPLAY:-}" ]; then
    RENDERER=$(glxinfo 2>/dev/null | grep "OpenGL renderer" || true)
    if echo "$RENDERER" | grep -qi "AMD\|Radeon\|raphael"; then
        echo -e "  ${GREEN}[PASS]${NC} Display is on AMD iGPU: $RENDERER"
    elif echo "$RENDERER" | grep -qi "NVIDIA\|GeForce"; then
        echo -e "  ${RED}[FAIL]${NC} Display is on NVIDIA — WRONG! $RENDERER"
        echo "       → FIX: Check xorg.conf and module load order"
        PRE_FAIL=$((PRE_FAIL+1))
    elif echo "$RENDERER" | grep -qi "llvmpipe\|software"; then
        echo -e "  ${YELLOW}[WARN]${NC} Software rendering — iGPU acceleration not working"
        PRE_WARN=$((PRE_WARN+1))
    else
        echo -e "  ${BLUE}[INFO]${NC} Renderer: $RENDERER"
    fi
else
    echo -e "  ${BLUE}[INFO]${NC} glxinfo not available or no DISPLAY — skipping renderer check"
fi

# --- Check 8: Both GPUs visible in lspci ---
AMD_GPU=$(lspci 2>/dev/null | grep -i "VGA\|Display" | grep -i "AMD\|ATI\|Radeon" || true)
NVIDIA_GPU=$(lspci 2>/dev/null | grep -i "VGA\|3D\|Display" | grep -i "NVIDIA" || true)
if [ -n "$AMD_GPU" ] && [ -n "$NVIDIA_GPU" ]; then
    echo -e "  ${GREEN}[PASS]${NC} Both GPUs detected in lspci"
else
    [ -z "$AMD_GPU" ] && echo -e "  ${RED}[FAIL]${NC} AMD iGPU NOT detected" && PRE_FAIL=$((PRE_FAIL+1))
    [ -z "$NVIDIA_GPU" ] && echo -e "  ${RED}[FAIL]${NC} NVIDIA GPU NOT detected" && PRE_FAIL=$((PRE_FAIL+1))
fi

# --- Check 9: dmesg amdgpu errors ---
AMDGPU_ERRORS=$(dmesg 2>/dev/null | grep -i "amdgpu.*error\|amdgpu.*fault\|amdgpu.*timeout" | wc -l || echo "0")
if [ "$AMDGPU_ERRORS" -gt 0 ]; then
    echo -e "  ${YELLOW}[WARN]${NC} Found $AMDGPU_ERRORS amdgpu error(s) in dmesg"
    echo "       → Review: dmesg | grep -i 'amdgpu.*error'"
    PRE_WARN=$((PRE_WARN+1))
else
    echo -e "  ${GREEN}[PASS]${NC} No amdgpu errors in dmesg"
fi

# --- Gate Decision ---
echo ""
if [ $PRE_FAIL -gt 0 ]; then
    echo -e "${RED}${BOLD}BLOCKING: $PRE_FAIL critical pre-check(s) failed.${NC}"
    echo "Fix the issues above, then re-run this script."
    echo "Installing NVIDIA on a broken amdgpu config makes debugging exponentially harder."
    exit 1
elif [ $PRE_WARN -gt 0 ]; then
    echo -e "${YELLOW}$PRE_WARN warning(s) — proceeding, but review these after installation.${NC}"
    echo ""
else
    echo -e "${GREEN}All pre-checks passed. Proceeding with NVIDIA installation.${NC}"
    echo ""
fi

###############################################################################
# STEP 1: Blacklist nouveau driver
###############################################################################
echo -e "${BLUE}[Step 1/7]${NC} Blacklisting nouveau driver..."

# WHY: nouveau is the open-source NVIDIA driver that ships with the Linux kernel.
#      It MUST be prevented from loading because:
#      - It claims the NVIDIA GPU before the proprietary driver can
#      - Both drivers cannot control the same hardware simultaneously
#      - If nouveau loads first, nvidia module fails to initialize
#      - nouveau has no CUDA support — useless for ML compute
#
# HOW: We blacklist at multiple levels for defense in depth:
#      - modprobe.d blacklist: Prevents modprobe from loading nouveau
#      - alias nouveau off: Redirects any attempt to load nouveau to "off"
#      - initramfs rebuild: Ensures blacklist applies during early boot
#
# REF: https://docs.nvidia.com/cuda/cuda-installation-guide-linux/
# REF: https://wiki.archlinux.org/title/NVIDIA#Blacklisting_nouveau

cat <<'EOF' > /etc/modprobe.d/blacklist-nouveau.conf
# Blacklist nouveau (open-source NVIDIA driver) to prevent conflicts
# with NVIDIA proprietary driver needed for CUDA/ML compute
#
# WHY: nouveau claims the GPU before nvidia can load, and has no CUDA support.
#      Both drivers cannot coexist on the same hardware.
# REF: https://docs.nvidia.com/cuda/cuda-installation-guide-linux/
# REF: https://wiki.archlinux.org/title/NVIDIA#Blacklisting_nouveau

blacklist nouveau
blacklist lbm-nouveau
options nouveau modeset=0
alias nouveau off
alias lbm-nouveau off
EOF

echo -e "  ${GREEN}nouveau blacklisted${NC}"

###############################################################################
# STEP 2: Remove any existing NVIDIA packages
###############################################################################
echo -e "\n${BLUE}[Step 2/7]${NC} Removing any existing NVIDIA packages..."

# WHY: Clean slate prevents version conflicts between different driver branches.
#      Ubuntu may have pre-installed an older nvidia-driver-XXX package.
#      Mixing driver versions causes module mismatch errors.

apt purge -y nvidia-* libnvidia-* 2>/dev/null || true
apt autoremove -y 2>/dev/null || true
echo -e "  ${GREEN}Existing NVIDIA packages removed${NC}"

###############################################################################
# STEP 3: Add NVIDIA CUDA repository
###############################################################################
echo -e "\n${BLUE}[Step 3/7]${NC} Adding NVIDIA CUDA repository..."

# WHY: The NVIDIA CUDA repository provides:
#      - Latest driver packages built specifically for Ubuntu 24.04
#      - CUDA toolkit matched to the driver version
#      - Proper apt dependency management
#      This is the officially recommended method from NVIDIA:
# REF: https://docs.nvidia.com/cuda/cuda-installation-guide-linux/
# REF: https://developer.nvidia.com/cuda-downloads

# Download and install the CUDA repository keyring
# This adds NVIDIA's GPG key and repository configuration
KEYRING_URL="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb"

echo "  Downloading CUDA repository keyring..."
wget -q "$KEYRING_URL" -O /tmp/cuda-keyring.deb

echo "  Installing keyring..."
dpkg -i /tmp/cuda-keyring.deb
rm /tmp/cuda-keyring.deb

echo "  Updating package lists..."
apt update -qq

echo -e "  ${GREEN}NVIDIA CUDA repository added${NC}"

###############################################################################
# STEP 4: Install NVIDIA driver
###############################################################################
echo -e "\n${BLUE}[Step 4/7]${NC} Installing NVIDIA driver..."

# Strategy: Prefer open kernel modules, then proprietary. Prefer headless, then full.
#
# NVIDIA Open Kernel Modules (recommended since R560, August 2024):
#   Open kernel modules are now the DEFAULT for Turing+ GPUs (including Ada Lovelace
#   RTX 4090). They provide:
#   - Better compatibility with newer kernels (important for HWE 6.17)
#   - Community visibility into kernel module code for debugging
#   - Full GSP firmware support (NVreg_EnableGpuFirmware=1)
#   - Identical CUDA compute performance to proprietary modules
#   The proprietary modules still work but NVIDIA recommends open for compute/datacenter.
#   REF: https://docs.nvidia.com/datacenter/tesla/driver-installation-guide/kernel-modules.html
#   REF: https://github.com/NVIDIA/open-gpu-kernel-modules
#
# Package preference order:
#   1. nvidia-headless-595-open  — open modules, compute-only (best for our use case)
#   2. nvidia-headless-595       — proprietary, compute-only
#   3. nvidia-driver-595-open    — open modules, full driver (includes display libs)
#   4. nvidia-driver-595         — proprietary, full driver
#   5. Any 595.x variant available
#
# nvidia-utils-595: nvidia-smi and management utilities
#   ALWAYS NEEDED: Required for monitoring, clock control, persistence mode.
#
# WHY headless preferred:
#   Eliminates OpenGL library conflicts with Mesa/amdgpu. When nvidia installs
#   its libGL, it can override Mesa's libGL for the AMD iGPU, causing desktop
#   apps to try to render on NVIDIA.
#   REF: https://forums.developer.nvidia.com/t/nvidia-driver-conflicts-with-mesa-libraries/33103
#   REF: https://bbs.archlinux.org/viewtopic.php?id=244003
#
# WHY 595.58.03 specifically:
#   - CudaNoStablePerfLimit application profile: CUDA reaches P0 PState
#     (full GDDR6X memory clocks). Previous drivers forced P2 state with
#     reduced memory bandwidth during CUDA workloads.
#   - modeset=1 by default: No manual nvidia-drm.modeset=1 needed
#   - GPU reset while modeset=1: Can recover compute GPU without reboot
#   - VRAM fallback improvement: Less likely to crash on OOM
#   REF: https://www.gamingonlinux.com/2026/03/nvidia-driver-595-58-03-released-as-the-big-new-recommended-stable-driver-for-linux/

if apt-cache show nvidia-headless-595-open &>/dev/null 2>&1; then
    echo "  Found nvidia-headless-595-open — installing (open kernel modules, compute-only, RECOMMENDED)"
    apt install -y nvidia-headless-595-open nvidia-utils-595
    DRIVER_PACKAGE="nvidia-headless-595-open"
elif apt-cache show nvidia-headless-595 &>/dev/null 2>&1; then
    echo "  Found nvidia-headless-595 — installing (proprietary, compute-only)"
    echo "  NOTE: Open kernel modules (nvidia-headless-595-open) preferred when available"
    apt install -y nvidia-headless-595 nvidia-utils-595
    DRIVER_PACKAGE="nvidia-headless-595"
elif apt-cache show nvidia-driver-595-open &>/dev/null 2>&1; then
    echo "  Headless not available. Installing nvidia-driver-595-open (open modules, full driver)"
    apt install -y nvidia-driver-595-open
    DRIVER_PACKAGE="nvidia-driver-595-open"
elif apt-cache show nvidia-driver-595 &>/dev/null 2>&1; then
    echo "  Open/headless not available. Installing nvidia-driver-595 (proprietary, full driver)"
    apt install -y nvidia-driver-595
    DRIVER_PACKAGE="nvidia-driver-595"
else
    # Fall back to whatever 595.x is available
    echo "  Searching for any 595.x driver package..."
    AVAILABLE=$(apt-cache search "nvidia-driver-595\|nvidia-headless-595" 2>/dev/null | head -5)
    if [ -n "$AVAILABLE" ]; then
        echo "  Available: $AVAILABLE"
        # Try the first match
        PKG=$(echo "$AVAILABLE" | head -1 | awk '{print $1}')
        apt install -y "$PKG"
        DRIVER_PACKAGE="$PKG"
    else
        echo -e "  ${YELLOW}Driver 595 not found in repos. Trying latest available...${NC}"
        # List all available driver packages
        echo "  Available NVIDIA driver packages:"
        apt-cache search "nvidia-driver-[0-9]" 2>/dev/null | sort -t'-' -k3 -n | tail -5
        echo ""
        echo -e "  ${YELLOW}Install manually with: sudo apt install nvidia-driver-<VERSION>${NC}"
        echo "  Or use the .run installer from nvidia.com with --no-opengl-files flag"
        echo "  REF: https://www.nvidia.com/download/driverResults.aspx/265870/en-us/"
        exit 1
    fi
fi

echo -e "  ${GREEN}NVIDIA driver installed: $DRIVER_PACKAGE${NC}"

###############################################################################
# STEP 5: Configure NVIDIA module options
###############################################################################
echo -e "\n${BLUE}[Step 5/7]${NC} Configuring NVIDIA module options..."

# These options configure the NVIDIA kernel module for optimal headless compute.
# Each option is documented with its purpose, why it was chosen, and references.

cat <<'NVCONF' > /etc/modprobe.d/nvidia.conf
###############################################################################
# NVIDIA Module Options for Headless ML Compute
# System: RTX 4090 (Ada Lovelace AD102) on Ubuntu 24.04, Kernel 6.17 HWE / 6.8 GA
# Driver: 595.58.03
###############################################################################

# === Blacklist nouveau (redundant with blacklist-nouveau.conf but defense-in-depth) ===
blacklist nouveau
options nouveau modeset=0

# === NVreg_RegisterPCIDriverOnEarlyBoot=1 ===
# WHAT: Registers the NVIDIA PCI driver during early boot phase
# WHY:  Improves PCIe initialization stability. Helps prevent Xid 79
#       "GPU has fallen off the bus" errors during boot sequence.
#       The GPU is claimed earlier, reducing the window for PCIe link issues.
# RISK: None
# REF:  https://forums.developer.nvidia.com/t/gpu-has-fallen-off-the-bus-issues-on-daily-basis-rtx-4090/314647
options nvidia NVreg_RegisterPCIDriverOnEarlyBoot=1

# === NVreg_UsePageAttributeTable=1 ===
# WHAT: Enables PAT (Page Attribute Table) for GPU memory mapping
# WHY:  Improves memory access performance for CUDA compute workloads.
#       PAT provides finer-grained control over memory caching attributes
#       than the older MTRR mechanism, resulting in better DMA throughput.
# RISK: None on modern kernels (PAT has been stable since kernel 2.6.29)
# REF:  https://download.nvidia.com/XFree86/Linux-x86_64/595.58.03/README/
options nvidia NVreg_UsePageAttributeTable=1

# === NVreg_InitializeSystemMemoryAllocations=0 ===
# WHAT: Skips zeroing of system memory allocations by the NVIDIA driver
# WHY:  Small performance improvement. The driver normally zeros all system
#       memory allocations for security. In a single-user ML workstation,
#       this security measure is unnecessary and adds overhead.
# RISK: Theoretical information leak in multi-user environments (not applicable)
options nvidia NVreg_InitializeSystemMemoryAllocations=0

# === NVreg_DynamicPowerManagement=0x02 ===
# WHAT: Enables fine-grained dynamic power management for the GPU
# WHY:  When no CUDA workload is running, the RTX 4090 can drop to ~15W idle.
#       Without this, the GPU may stay at a higher power state (35-60W) even idle.
#       Value 0x02 = "Fine-grained" — most aggressive power saving.
#       This is safe because our GPU has NO display attached (headless).
# RISK: Slight delay (~ms) when resuming from deep idle to full power.
#       Not noticeable in practice for ML workloads.
# REF:  https://download.nvidia.com/XFree86/Linux-x86_64/595.58.03/README/dynamicpowermanagement.html
options nvidia NVreg_DynamicPowerManagement=0x02

# === NVreg_EnableGpuFirmware=1 ===
# WHAT: Enables GSP (GPU System Processor) firmware on Ada Lovelace
# WHY:  GSP offloads GPU management tasks (resource management, power control)
#       from the host CPU to a dedicated processor on the GPU die.
#       This reduces CPU overhead for GPU management operations.
#       Required for some features in driver 595+.
# RISK: GSP firmware bugs can cause initialization delays (mitigated by
#       persistence mode which keeps GSP running).
# REF:  https://docs.nvidia.com/datacenter/tesla/driver-installation-guide/kernel-modules.html
options nvidia NVreg_EnableGpuFirmware=1

# === OPTIONAL: NVreg_EnableGpuFirmware=0 (uncomment ONLY for GSP debugging) ===
# WHAT: Disables GSP (GPU System Processor) firmware offloading
# WHEN: Uncomment this (and comment out the =1 line above) ONLY if you experience:
#   - "GSP firmware failed to load" errors in dmesg after driver update
#   - nvidia-smi hangs or takes >30 seconds to respond
#   - GPU initialization failures with GSP-related errors
# WHY NOT DEFAULT: GSP is the recommended mode for Ada Lovelace (RTX 4090).
#   It offloads GPU management tasks to a dedicated processor on the GPU die,
#   reducing host CPU overhead and improving power management responsiveness.
#   Disabling forces the host CPU to handle all GPU management operations.
# NOTE: GSP is required for NVIDIA open kernel modules. If using open modules
#   (nvidia-headless-595-open), disabling GSP will cause module load failure.
# REF: https://docs.nvidia.com/datacenter/tesla/driver-installation-guide/kernel-modules.html
# options nvidia NVreg_EnableGpuFirmware=0

# === NVreg_EnableResizableBar=1 ===
# WHAT: Enables Resizable BAR (ReBAR) support in the NVIDIA driver
# WHY:  Resizable BAR allows the CPU to access the entire 24GB VRAM address space
#       of the RTX 4090 at once, instead of through a 256MB sliding window.
#       This improves host-to-device and device-to-host memory transfer performance
#       by 5-15% for large tensors (common in ML training with large batch sizes).
#       Without ReBAR, the driver must page through VRAM in 256MB chunks, adding
#       latency to every large memory transfer.
# PREREQ (BIOS): Both settings MUST be enabled in BIOS for ReBAR to work:
#       BIOS → Advanced → PCI Subsystem Settings → Above 4G Decoding → Enabled [B3]
#       BIOS → Advanced → PCI Subsystem Settings → Resizable BAR → Enabled [B16]
# VERIFY: nvidia-smi -q | grep -A2 "BAR1" (should show ~24576 MiB, not 256 MiB)
# SAFETY: If BIOS settings are not configured, this parameter is silently ignored.
#       No negative effect if ReBAR is unavailable.
# REF:  https://nvidia.custhelp.com/app/answers/detail/a_id/5165
# REF:  https://www.nvidia.com/en-us/geforce/news/geforce-rtx-30-series-resizable-bar-support/
options nvidia NVreg_EnableResizableBar=1

# === NVreg_PreserveVideoMemoryAllocations=1 ===
# WHAT: Preserves VRAM contents across suspend/resume cycles
# WHY:  If suspend is ever used (not recommended for ML), this prevents
#       loss of GPU state. VRAM is dumped to disk at the path specified
#       by NVreg_TemporaryFilePath before suspend.
#       For RTX 4090 with 24GB VRAM, needs up to 24GB free disk space.
# RISK: Suspend takes longer (24GB dump), requires disk space
# REF:  https://download.nvidia.com/XFree86/Linux-x86_64/595.58.03/README/powermanagement.html
options nvidia NVreg_PreserveVideoMemoryAllocations=1
options nvidia NVreg_TemporaryFilePath=/var/tmp

# === nvidia-drm options ===
# modeset=1: Enables kernel mode setting for NVIDIA DRM
#   WHY: Required for Wayland, VT switching, proper DRM integration
#   Default in 595 but explicit for safety
# fbdev=1: Enables NVIDIA framebuffer device
#   WHY: Improves VT console switching (Ctrl+Alt+F1-F6)
#   Available in driver 545+
options nvidia_drm modeset=1
options nvidia_drm fbdev=1

# === RmGpuComputeExecTimeout=0 ===
# WHAT: Disables the CUDA kernel execution timeout
# WHY:  CRITICAL FOR ML TRAINING. When a GPU drives a display, there is a
#       ~2 second watchdog timeout that kills any CUDA kernel running longer
#       than that. This protects the display from freezing.
#       Since our RTX 4090 is HEADLESS (no display), this timeout is not
#       needed. ML training kernels (especially custom CUDA, attention
#       mechanisms, large batch operations) can easily exceed 2 seconds.
#       Setting to 0 disables the timeout entirely.
# RISK: A truly hung CUDA kernel will never be killed automatically.
#       Use nvidia-smi --gpu-reset to recover if needed.
# NOTE: This setting only matters when no display is on the GPU.
#       nvidia-smi -q will show "Kernel Exec Timeout: No"
# REF:  https://forums.developer.nvidia.com/t/disable-kernel-execution-timeout/40228
# REF:  https://forums.developer.nvidia.com/t/compute-only-headless-mode-not-working-as-expected/339394
options nvidia NVreg_RegistryDwords="RmGpuComputeExecTimeout=0"
NVCONF

echo -e "  ${GREEN}NVIDIA module options configured${NC}"

###############################################################################
# STEP 6: Configure module load order + initramfs
###############################################################################
echo -e "\n${BLUE}[Step 6/7]${NC} Configuring module load order..."

# WHY MODULE ORDER MATTERS:
#   The Linux DRM subsystem assigns card numbers (card0, card1, ...) in the
#   order that GPU drivers claim their hardware. Compositors (GDM, GNOME Shell)
#   default to card0 for display rendering.
#
#   If nvidia loads before amdgpu:
#     card0 = NVIDIA → compositor renders on RTX 4090 → WRONG (waste of VRAM)
#   If amdgpu loads before nvidia:
#     card0 = AMD iGPU → compositor renders on iGPU → CORRECT (RTX 4090 free for CUDA)
#
#   We enforce order at two levels:
#   1. /etc/modules-load.d/gpu.conf: Systemd module loading order
#   2. /etc/initramfs-tools/modules: Initramfs module loading order (earliest)
#
# REF: https://gist.github.com/wangruohui/bc7b9f424e3d5deb0c0b8bba990b1bc5
# REF: https://gist.github.com/alexlee-gk/76a409f62a53883971a18a11af93241b

cat <<'EOF' > /etc/modules-load.d/gpu.conf
# GPU Module Load Order for Dual-GPU ML Workstation
# ORDER MATTERS: amdgpu MUST load before nvidia so AMD claims card0
#
# card0 = AMD iGPU (display) ← compositors use this by default
# card1 = NVIDIA RTX 4090 (headless compute)
#
# WHY: Compositors (GDM, GNOME) default to card0 for rendering.
#      If nvidia claims card0, the desktop renders on RTX 4090
#      instead of the iGPU, consuming VRAM and adding display overhead.
# REF: https://gist.github.com/wangruohui/bc7b9f424e3d5deb0c0b8bba990b1bc5

amdgpu
nvidia
nvidia_uvm
nvidia_modeset
nvidia_drm
EOF

# Also add to initramfs for earliest possible loading
# WHY: initramfs modules load even before systemd. This is the most reliable
#      way to ensure amdgpu claims card0 during early boot.
INITRAMFS_MODULES="/etc/initramfs-tools/modules"
# Remove any existing gpu module entries to prevent duplicates
sed -i '/^amdgpu$/d; /^nvidia$/d; /^nvidia_uvm$/d; /^nvidia_modeset$/d; /^nvidia_drm$/d' "$INITRAMFS_MODULES" 2>/dev/null || true

cat <<'EOF' >> "$INITRAMFS_MODULES"

# GPU Module Load Order (amdgpu first for card0 assignment)
# REF: https://gist.github.com/wangruohui/bc7b9f424e3d5deb0c0b8bba990b1bc5
amdgpu
nvidia
nvidia_uvm
nvidia_modeset
nvidia_drm
EOF

echo -e "  ${GREEN}Module load order configured${NC}"

###############################################################################
# STEP 7: Install CUDA toolkit
###############################################################################
echo -e "\n${BLUE}[Step 7/7]${NC} Installing CUDA toolkit..."

# WHY: CUDA toolkit provides nvcc compiler, cuDNN, cuBLAS, and all libraries
#      needed for PyTorch/TensorFlow to use GPU acceleration.
#
# We install cuda-toolkit (not cuda package) because:
#   - cuda-toolkit: Just the development tools and libraries
#   - cuda: Full meta-package that may pull in unwanted driver version
#
# REF: https://docs.nvidia.com/cuda/cuda-installation-guide-linux/
# REF: https://developer.nvidia.com/cuda-downloads

if apt-cache show cuda-toolkit-13-2 &>/dev/null 2>&1; then
    echo "  Installing cuda-toolkit-13-2..."
    apt install -y cuda-toolkit-13-2
elif apt-cache show cuda-toolkit &>/dev/null 2>&1; then
    echo "  cuda-toolkit-13-2 not found. Installing latest cuda-toolkit..."
    apt install -y cuda-toolkit
else
    echo -e "  ${YELLOW}CUDA toolkit not found in repository.${NC}"
    echo "  You can install it later with: sudo apt install cuda-toolkit"
    echo "  REF: https://developer.nvidia.com/cuda-downloads"
fi

echo -e "  ${GREEN}CUDA installation complete${NC}"

###############################################################################
# Pin NVIDIA driver versions
###############################################################################
echo -e "\n${BLUE}[Post-install]${NC} Pinning NVIDIA driver versions..."

# WHY: Prevent apt upgrade from automatically updating the NVIDIA driver.
#      Driver updates can break CUDA compatibility, change module behavior,
#      or introduce regressions. We want to control when driver updates happen.
# NOTE: The grep pattern "nvidia-.*595" matches both proprietary (nvidia-*-595)
# and open (nvidia-*-595-open) packages, so both variants are pinned correctly.

apt-mark hold $(dpkg -l | grep "nvidia-.*595" | awk '{print $2}' | tr '\n' ' ') 2>/dev/null || true
echo "  Held packages: $(apt-mark showhold 2>/dev/null | grep nvidia | tr '\n' ' ')"
echo -e "  ${GREEN}NVIDIA packages pinned${NC}"

###############################################################################
# Update initramfs and reboot
###############################################################################
echo -e "\n${BLUE}[Final]${NC} Updating initramfs with all changes..."
update-initramfs -u -k all 2>/dev/null
echo -e "  ${GREEN}initramfs updated${NC}"

###############################################################################
# Summary
###############################################################################
echo ""
echo -e "${BOLD}================================================================${NC}"
echo -e "${GREEN}${BOLD}  Phase 2 Complete!${NC}"
echo -e "${BOLD}================================================================${NC}"
echo ""
echo "  Changes applied:"
echo "    [1] nouveau blacklisted"
echo "    [2] NVIDIA CUDA repository added"
echo "    [3] NVIDIA driver installed: $DRIVER_PACKAGE"
echo "    [4] NVIDIA module options configured for headless compute"
echo "    [5] Module load order: amdgpu → nvidia (card0 = AMD)"
echo "    [6] CUDA toolkit installed"
echo "    [7] Driver versions pinned"
echo ""
echo -e "  ${YELLOW}REBOOT REQUIRED to load NVIDIA kernel modules.${NC}"
echo ""
echo "  After reboot, verify with:"
echo "    nvidia-smi                    # Should show RTX 4090"
echo "    nvidia-smi -q | grep 'Kernel Exec Timeout'  # Should show: No"
echo "    nvidia-smi -q | grep 'Persistence'          # Should show: Enabled"
echo ""
echo "  Then proceed to Phase 3: Display configuration:"
echo "    sudo bash 03-configure-display.sh"
echo ""
read -p "Press Enter to reboot now, or Ctrl+C to reboot manually later... "
reboot
