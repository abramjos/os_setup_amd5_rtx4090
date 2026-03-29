#!/bin/bash
###############################################################################
# 00-verify-bios-prerequisites.sh
#
# PURPOSE: Verify BIOS settings are correctly applied BEFORE starting Ubuntu
#          software configuration. Run this immediately after first boot into
#          Ubuntu from a clean install.
#
# SYSTEM: Ryzen 9 7950X | ASUS ROG Crosshair X670E Hero | RTX 4090
#         BIOS 3603 (AGESA ComboAM5 PI 1.3.0.0a)
#
# BIOS SETTINGS TIERS (see BIOS-SETTINGS-COMPLETE-GUIDE.md for full details):
#   TIER 1 (MUST HAVE): B1-B9 — Required for display + driver operation
#   TIER 2 (NICE TO HAVE): B10-B17 — Stability improvements
#   TIER 3 (ML OPTIMIZED): B18-B21 — Training throughput tuning
#
# WHAT THIS CHECKS:
#   - Network connectivity for package installation
#   - Sufficient disk space for CUDA toolkit and VRAM suspend dumps
#   - System architecture is x86_64 (required for NVIDIA CUDA)
#   - Secure Boot status (affects NVIDIA driver loading)
#   - iGPU is active (IGFX Multi-Monitor was enabled in BIOS)
#   - UMA Frame Buffer Size for iGPU stability
#   - Both GPUs are visible to the kernel
#   - PCIe link speed and width for RTX 4090
#   - PCIe ASPM is disabled (prevents Xid 79 crashes)
#   - IOMMU is enabled
#   - SME/TSME is disabled (critical for NVIDIA DMA)
#   - CPU microcode is loaded
#   - Basic memory configuration
#   - Kernel version compatibility
#   - Kernel boot parameters (including CPU C-state and amd_pstate)
#   - BIOS-only settings reminders (C-states, power, PCIe)
#   - ML training optimization BIOS reminders
#   - nouveau driver is blacklisted
#
# REFERENCES:
#   - ASUS iGPU Multi-Monitor FAQ: https://www.asus.com/support/faq/1045574/
#   - NVIDIA DMA + AMD SME Issue: https://github.com/NVIDIA/open-gpu-kernel-modules/issues/340
#   - AM5 PCIe stability: https://rog-forum.asus.com/t5/nvidia-graphics-cards/solved-how-to-enable-pcie-gen-4-5-link-speed-full-16x-lanes/td-p/1114798
#   - Raphael iGPU kernel support: https://wiki.archlinux.org/title/AMDGPU
#
# USAGE: sudo bash 00-verify-bios-prerequisites.sh
#
# EXIT CODES:
#   0 = All checks passed
#   1 = Critical failure (must fix before proceeding)
#   2 = Warnings present (can proceed but should address)
###############################################################################

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
BOLD='\033[1m'

PASS=0
FAIL=0
WARN=0

pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS=$((PASS+1)); }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL=$((FAIL+1)); }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; WARN=$((WARN+1)); }
info() { echo -e "  ${BLUE}[INFO]${NC} $1"; }
section() { echo -e "\n${BOLD}=== $1 ===${NC}"; }

echo -e "${BOLD}================================================================${NC}"
echo -e "${BOLD}  BIOS Prerequisites Verification Script${NC}"
echo -e "${BOLD}  System: Ryzen 9 7950X + X670E Hero + RTX 4090${NC}"
echo -e "${BOLD}================================================================${NC}"
echo ""

###############################################################################
# CHECK 1: Network Connectivity
###############################################################################
section "1. Network Connectivity"

# WHY: Network access is required for:
#   - Installing NVIDIA driver packages (nvidia-headless-595)
#   - Installing CUDA toolkit (cuda-toolkit-13-2)
#   - Downloading NVIDIA CUDA repository keyring
#   - Installing monitoring tools (nvtop, radeontop)

if ping -c 1 -W 5 archive.ubuntu.com &>/dev/null; then
    pass "Network connectivity OK (archive.ubuntu.com reachable)"
elif ping -c 1 -W 5 8.8.8.8 &>/dev/null; then
    warn "DNS may not work (IP reachable but hostname not)"
    echo "       → FIX: Check /etc/resolv.conf or systemd-resolved config"
else
    fail "No network connectivity!"
    echo "       → FIX: Configure network (ethernet recommended for reliability)"
    echo "       → FIX: Check: ip link show; nmcli device status"
fi

###############################################################################
# CHECK 2: Disk Space
###############################################################################
section "2. Disk Space"

# WHY: CUDA toolkit requires ~5 GB. NVIDIA driver ~500 MB.
#   VRAM suspend dump (NVreg_TemporaryFilePath) needs up to 24 GB in /var/tmp.
#   Total: need at least 30 GB free.

ROOT_FREE_KB=$(df / | awk 'NR==2 {print $4}')
ROOT_FREE_GB=$((ROOT_FREE_KB / 1024 / 1024))
info "Free space on /: ${ROOT_FREE_GB} GB"

if [ "$ROOT_FREE_GB" -ge 30 ]; then
    pass "Sufficient disk space (${ROOT_FREE_GB} GB free, 30 GB needed)"
elif [ "$ROOT_FREE_GB" -ge 10 ]; then
    warn "Low disk space (${ROOT_FREE_GB} GB free)"
    echo "       → CUDA toolkit needs ~5 GB, VRAM suspend dump needs up to 24 GB in /var/tmp"
else
    fail "Critically low disk space (${ROOT_FREE_GB} GB free)"
    echo "       → FIX: Need at least 30 GB free for all components"
fi

# Check /var/tmp specifically (VRAM suspend dump location)
VARTMP_FREE_KB=$(df /var/tmp 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")
VARTMP_FREE_GB=$((VARTMP_FREE_KB / 1024 / 1024))
info "Free space on /var/tmp: ${VARTMP_FREE_GB} GB"
if [ "$VARTMP_FREE_GB" -lt 24 ]; then
    warn "/var/tmp has less than 24 GB free — NVIDIA suspend VRAM dump needs up to 24 GB"
fi

###############################################################################
# CHECK 3: System Architecture
###############################################################################
section "3. System Architecture"

ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
    pass "Architecture: x86_64 (correct for NVIDIA CUDA)"
else
    fail "Architecture: $ARCH — expected x86_64"
    echo "       → FIX: NVIDIA CUDA packages only available for x86_64"
fi

###############################################################################
# CHECK 4: Secure Boot Status
###############################################################################
section "4. Secure Boot Status"

# WHY: Secure Boot can prevent NVIDIA's proprietary kernel module from loading.
#   Ubuntu's NVIDIA packages handle this via DKMS + MOK enrollment, but it adds
#   complexity. If Secure Boot is enabled, you'll need to enroll a MOK key.

if command -v mokutil &>/dev/null; then
    SB_STATE=$(mokutil --sb-state 2>/dev/null || echo "unknown")
    if echo "$SB_STATE" | grep -qi "enabled"; then
        warn "Secure Boot is ENABLED"
        echo "       → NVIDIA driver will require MOK key enrollment during install"
        echo "       → Alternative: Disable Secure Boot in BIOS (simpler)"
    else
        pass "Secure Boot is disabled (simplifies NVIDIA driver install)"
    fi
else
    info "mokutil not available — cannot check Secure Boot status"
fi

###############################################################################
# CHECK 5: AMD iGPU (Raphael RDNA2) is visible
###############################################################################
section "5. AMD Raphael iGPU Detection"

# The iGPU should appear in lspci as an AMD/ATI VGA controller
# Device ID for Raphael iGPU is typically 164e (gfx1036)
# If this is missing, BIOS setting "IGFX Multi-Monitor" is NOT enabled
# FIX: Reboot → BIOS → Advanced → NB Configuration → IGFX Multi-Monitor → Enabled
#      Also set: Primary Video Device → IGFX Video
# REF: https://www.asus.com/support/faq/1045574/

# Filter AMD vendor FIRST, then for VGA/Display class.
# Previous grep order (VGA first, then AMD) could match wrong GPU when
# NVIDIA appears before AMD in lspci output (e.g., 01:00.0 vs 6c:00.0).
AMD_GPU=$(lspci 2>/dev/null | grep -i "AMD\|ATI\|Radeon" | grep -i "VGA\|Display" || true)
if [ -n "$AMD_GPU" ]; then
    pass "AMD iGPU detected: $AMD_GPU"

    # Extract PCI BusID — re-filter to ensure we only pick AMD lines
    AMD_BUSID_HEX=$(echo "$AMD_GPU" | grep -i "AMD\|ATI\|Radeon" | head -1 | awk '{print $1}')
    AMD_BUS_DEC=$(printf "%d" "0x$(echo $AMD_BUSID_HEX | cut -d: -f1)")
    AMD_DEV_DEC=$(printf "%d" "0x$(echo $AMD_BUSID_HEX | cut -d: -f2 | cut -d. -f1)")
    AMD_FUNC_DEC=$(echo $AMD_BUSID_HEX | cut -d. -f2)
    info "PCI BusID (hex): $AMD_BUSID_HEX → (decimal for xorg.conf): PCI:${AMD_BUS_DEC}:${AMD_DEV_DEC}:${AMD_FUNC_DEC}"
else
    fail "AMD iGPU NOT detected!"
    echo "       → FIX: Reboot → BIOS → Advanced → NB Configuration → IGFX Multi-Monitor → Enabled"
    echo "       → FIX: Also set Primary Video Device → IGFX Video"
    echo "       → FIX: Also set UMA Frame Buffer Size → 2G (prevents gfx ring timeouts)"
    echo "       → REF: https://www.asus.com/support/faq/1045574/"
fi

# Check if amdgpu kernel module is loaded
if lsmod | grep -q "^amdgpu"; then
    pass "amdgpu kernel module is loaded"
else
    fail "amdgpu kernel module is NOT loaded"
    echo "       → This means the iGPU hardware is not being driven by the kernel"
    echo "       → FIX: Ensure kernel 6.5+ (Raphael support). Ubuntu 24.04 has 6.8 — should work"
    echo "       → FIX: Try: sudo modprobe amdgpu"
    echo "       → FIX: Check dmesg: dmesg | grep amdgpu"
    echo "       → REF: Kernel 6.5+ required for Raphael: https://wiki.archlinux.org/title/AMDGPU"
fi

# Check UMA Frame Buffer Size via iGPU VRAM reported by sysfs
# WHY: The UMA Frame Buffer Size BIOS setting allocates system RAM as dedicated
#      VRAM for the Raphael iGPU. The default (Auto/512M) provides too little
#      VRAM, causing page faults during desktop compositing that contribute to
#      gfx ring timeouts. 2G is the recommended setting for stability.
# BIOS: Advanced → NB Configuration → UMA Frame Buffer Size → 2G  [TIER 1: B9]
# REF: https://gitlab.freedesktop.org/drm/amd/-/issues/3006
if [ -f /sys/class/drm/card0/device/mem_info_vram_total ]; then
    VRAM_BYTES=$(cat /sys/class/drm/card0/device/mem_info_vram_total 2>/dev/null || echo "0")
    if [ "$VRAM_BYTES" != "0" ]; then
        VRAM_MB=$((VRAM_BYTES / 1024 / 1024))
        info "iGPU VRAM (UMA Frame Buffer): ${VRAM_MB} MB"
        if [ "$VRAM_MB" -ge 1500 ]; then
            pass "UMA Frame Buffer >= 2G (reduces gfx ring timeout risk)"
        elif [ "$VRAM_MB" -ge 400 ]; then
            warn "UMA Frame Buffer appears small (${VRAM_MB} MB) — 2G recommended"
            echo "       → FIX: BIOS → Advanced → NB Configuration → UMA Frame Buffer Size → 2G"
            echo "       → WHY: Larger VRAM pool reduces page faults that cause gfx ring timeouts"
            echo "       → REF: https://gitlab.freedesktop.org/drm/amd/-/issues/3006"
        else
            warn "UMA Frame Buffer very small or unreadable (${VRAM_MB} MB)"
        fi
    fi
fi

# Check if amdgpu is card0 (must be primary for display)
# WHY: Compositors (GNOME, GDM) use the first DRM card (card0) by default.
#      If nvidia claims card0, the desktop renders on the wrong GPU.
# FIX: Module load order — amdgpu must load before nvidia in initramfs
# REF: https://gist.github.com/wangruohui/bc7b9f424e3d5deb0c0b8bba990b1bc5
if [ -f /sys/class/drm/card0/device/vendor ]; then
    CARD0_VENDOR=$(cat /sys/class/drm/card0/device/vendor)
    if [ "$CARD0_VENDOR" = "0x1002" ]; then
        pass "card0 is AMD (0x1002) — correct for display primary"
    elif [ "$CARD0_VENDOR" = "0x10de" ]; then
        fail "card0 is NVIDIA (0x10de) — wrong! Should be AMD"
        echo "       → FIX: Ensure amdgpu loads before nvidia in /etc/modules-load.d/gpu.conf"
        echo "       → FIX: Also add to /etc/initramfs-tools/modules (amdgpu first)"
        echo "       → FIX: Run: sudo update-initramfs -u -k all && sudo reboot"
        echo "       → REF: https://gist.github.com/wangruohui/bc7b9f424e3d5deb0c0b8bba990b1bc5"
    else
        warn "card0 vendor is $CARD0_VENDOR — unexpected"
    fi
else
    warn "Cannot read /sys/class/drm/card0/device/vendor — DRM devices may not be initialized"
fi

###############################################################################
# CHECK 6: NVIDIA RTX 4090 Detection
###############################################################################
section "6. NVIDIA RTX 4090 Detection"

# The RTX 4090 should appear as an NVIDIA VGA or 3D controller
# Device ID for AD102 (RTX 4090) is 2684
# REF: https://forums.developer.nvidia.com/t/gpu-has-fallen-off-the-bus-issues-on-daily-basis-rtx-4090/314647

NVIDIA_BUSID_HEX=""
# Filter NVIDIA vendor first, then display class (same defensive pattern as AMD)
NVIDIA_GPU=$(lspci 2>/dev/null | grep -i "NVIDIA" | grep -i "VGA\|3D\|Display" || true)
if [ -n "$NVIDIA_GPU" ]; then
    pass "NVIDIA GPU detected: $NVIDIA_GPU"

    NVIDIA_BUSID_HEX=$(echo "$NVIDIA_GPU" | head -1 | awk '{print $1}')
    NVIDIA_BUS_DEC=$(printf "%d" "0x$(echo $NVIDIA_BUSID_HEX | cut -d: -f1)")
    NVIDIA_DEV_DEC=$(printf "%d" "0x$(echo $NVIDIA_BUSID_HEX | cut -d: -f2 | cut -d. -f1)")
    NVIDIA_FUNC_DEC=$(echo $NVIDIA_BUSID_HEX | cut -d. -f2)
    info "PCI BusID (hex): $NVIDIA_BUSID_HEX → (decimal for xorg.conf): PCI:${NVIDIA_BUS_DEC}:${NVIDIA_DEV_DEC}:${NVIDIA_FUNC_DEC}"
else
    fail "NVIDIA GPU NOT detected!"
    echo "       → FIX: Check physical seating of RTX 4090 in PCIe x16 slot"
    echo "       → FIX: Check 12VHPWR power cable is fully connected"
    echo "       → FIX: BIOS → Above 4G Decoding → Enabled"
fi

###############################################################################
# CHECK 7: PCIe Link Status
###############################################################################
section "7. PCIe Link Status for NVIDIA GPU"

# RTX 4090 is a PCIe 4.0 x16 device. We want Gen4 x16 for full bandwidth.
# WHY Gen 4 not Gen 5: RTX 4090 doesn't support Gen 5. Running the slot at Gen 5
#   Auto causes unnecessary link training and potential instability.
# FIX: BIOS → Advanced → PCIEX16_1 Link Mode → Gen 4
# REF: https://www.overclock.net/threads/4090-strix-oc-stuck-at-8x-pcie.1802623/
# REF: https://rog-forum.asus.com/t5/nvidia-graphics-cards/solved-how-to-enable-pcie-gen-4-5-link-speed-full-16x-lanes/td-p/1114798

if [ -n "$NVIDIA_BUSID_HEX" ]; then
    PCIE_INFO=$(sudo lspci -vvv -s "$NVIDIA_BUSID_HEX" 2>/dev/null | grep -A2 "LnkSta:" | head -3 || true)
    if echo "$PCIE_INFO" | grep -q "Speed 16GT/s"; then
        pass "PCIe link speed: Gen 4 (16 GT/s)"
    elif echo "$PCIE_INFO" | grep -q "Speed 32GT/s"; then
        warn "PCIe link speed: Gen 5 (32 GT/s) — RTX 4090 is Gen 4. Force Gen 4 in BIOS for stability"
        echo "       → FIX: BIOS → Advanced → PCIEX16_1 Link Mode → Gen 4"
    elif echo "$PCIE_INFO" | grep -q "Speed 8GT/s"; then
        fail "PCIe link speed: Gen 3 (8 GT/s) — underperforming!"
        echo "       → FIX: Reseat GPU. Check BIOS PCIe speed setting."
    elif echo "$PCIE_INFO" | grep -q "Speed 2.5GT/s"; then
        fail "PCIe link speed: Gen 1 (2.5 GT/s) — critical underperformance!"
        echo "       → FIX: Reseat GPU. Reboot. Check for Xid errors in dmesg."
    else
        warn "Could not determine PCIe link speed from: $PCIE_INFO"
    fi

    if echo "$PCIE_INFO" | grep -q "Width x16"; then
        pass "PCIe link width: x16"
    elif echo "$PCIE_INFO" | grep -q "Width x8"; then
        fail "PCIe link width: x8 — should be x16!"
        echo "       → FIX: Reseat GPU fully. Check for bent pins. Try reseating after full power off."
    elif echo "$PCIE_INFO" | grep -q "Width x1"; then
        fail "PCIe link width: x1 — critical! GPU barely connected"
        echo "       → FIX: Full power off (PSU switch off 10s), reseat GPU, check for physical damage"
    else
        warn "Could not determine PCIe width"
    fi
fi

###############################################################################
# CHECK 8: ASPM Status
###############################################################################
section "8. PCIe ASPM Status"

# ASPM (Active State Power Management) MUST be disabled for RTX 4090 stability.
# WHY: ASPM L0s causes Xid 79 "GPU has fallen off the bus" — the most common
#      RTX 4090 crash on AM5 Linux. PCIe power state transitions fail and
#      the link drops entirely, requiring hard reboot.
# FIX: Two-layer ASPM disable:
#      BIOS: Advanced → Onboard Devices Configuration:
#            Native ASPM → Enabled (hands control to Linux — BIOS-managed ASPM is
#            broken with NVIDIA cards per NVIDIA dev forums)
#            CPU PCIE ASPM Mode Control → Disabled (kills L0s/L1 on GPU's CPU-direct lanes)
#      Kernel: pcie_aspm=off in /etc/default/grub
#      NOTE: pcie_aspm=off means "don't touch ASPM, leave firmware settings" — it does
#            NOT actively disable ASPM. The BIOS CPU PCIE ASPM Mode Control = Disabled
#            is what actually kills L0s/L1. The kernel param is belt-and-suspenders.
# REF: https://forums.developer.nvidia.com/t/nvidia-driver-xid-79-gpu-crash-while-idling-if-aspm-l0s-is-enabled-in-uefi-bios-gpu-has-fallen-off-the-bus/314453
# REF: https://forums.developer.nvidia.com/t/rtx-4090-xid-79-fell-off-the-bus-infrequently/300369

CMDLINE=$(cat /proc/cmdline)
if echo "$CMDLINE" | grep -q "pcie_aspm=off"; then
    pass "pcie_aspm=off is set in kernel command line"
    info "  NOTE: pcie_aspm=off tells the kernel 'don't touch ASPM config' — it leaves"
    info "  firmware settings unchanged. The actual ASPM disable comes from the BIOS:"
    info "  CPU PCIE ASPM Mode Control = Disabled (B7b). Verify this BIOS setting!"
else
    warn "pcie_aspm=off is NOT set in kernel command line"
    echo "       → FIX: Add pcie_aspm=off to GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub"
    echo "       → FIX: Run: sudo update-grub && sudo reboot"
    echo "       → NOTE: pcie_aspm=off is belt-and-suspenders. The critical BIOS settings are:"
    echo "       →   Native ASPM = Enabled (B7) + CPU PCIE ASPM Mode Control = Disabled (B7b)"
fi

info "  BIOS ASPM settings for RTX 4090 stability (TIER 1):"
info "  [TIER 1] Native ASPM → Enabled (B7)"
info "    Path: Advanced → Onboard Devices Configuration → Native ASPM"
info "    WHY: Hands ASPM control to Linux. BIOS-managed ASPM is broken with NVIDIA cards."
info "         When Enabled, Linux can enforce pcie_aspm=off properly."
info "  [TIER 1] CPU PCIE ASPM Mode Control → Disabled (B7b)"
info "    Path: Advanced → Onboard Devices Configuration → CPU PCIE ASPM Mode Control"
info "    WHY: THE critical ASPM setting. Kills L0s/L1 on CPU-direct PCIe lanes (GPU slot)."
info "         L0s is the confirmed culprit for Xid 79 crashes during idle."
info "  (ASM1061 ASPM Support → Disabled — SATA controller only, not GPU-relevant)"
info ""
info "  Additional PCIe BIOS settings:"
info "  [TIER 2] D3Cold Support → Disabled (B15)"
info "    Path: Advanced → AMD PBS → Graphics Features → D3Cold Support"
info "    WHY: Prevents OS from cutting power to the PCIe slot."
info "    REF: https://forums.developer.nvidia.com/t/gpu-has-fallen-off-the-bus-issues-on-daily-basis-rtx-4090/314647"
info "  [TIER 2] PCIe Spread Spectrum → Disabled (B17)"
info "    Path: Advanced → AMD CBS → NBIO Common Options → Spread Spectrum"
info "    WHY: Cleaner PCIe clock signal. Eliminates one variable for PCIe debugging."

###############################################################################
# CHECK 9: IOMMU Status
###############################################################################
section "9. IOMMU Configuration"

# IOMMU should be enabled in pass-through mode for best GPU compute DMA performance.
# WHY: iommu=pt (pass-through) allows the GPU to do DMA without IOMMU translation
#      overhead, improving CUDA data transfer performance by ~1-3%.
# FIX: BIOS: Advanced → AMD CBS → IOMMU → Enabled (at CBS root level, NOT under NBIO)
#      Kernel: iommu=pt in /etc/default/grub
# REF: https://docs.nvidia.com/cuda/cuda-installation-guide-linux/

if echo "$CMDLINE" | grep -q "iommu=pt"; then
    pass "iommu=pt is set — IOMMU pass-through mode active"
elif echo "$CMDLINE" | grep -q "iommu="; then
    warn "IOMMU is set but not in pass-through mode. Current: $(echo $CMDLINE | grep -o 'iommu=[^ ]*')"
    echo "       → FIX: Change to iommu=pt in /etc/default/grub for best CUDA performance"
else
    warn "IOMMU parameter not found in kernel command line"
    echo "       → FIX: Add iommu=pt to GRUB_CMDLINE_LINUX_DEFAULT"
fi

# Check if IOMMU is actually active in the kernel
if dmesg 2>/dev/null | grep -qi "AMD-Vi: Interrupt remapping enabled"; then
    pass "AMD IOMMU (AMD-Vi) is active in kernel"
elif dmesg 2>/dev/null | grep -qi "AMD-Vi"; then
    info "AMD IOMMU detected but status unclear"
else
    warn "AMD IOMMU not detected in dmesg — may need BIOS enable"
    echo "       → FIX: BIOS → Advanced → AMD CBS → IOMMU → Enabled (at CBS root level)"
fi

###############################################################################
# CHECK 10: SME/TSME Status (CRITICAL)
###############################################################################
section "10. AMD Memory Encryption (SME/TSME) Status"

# SME and TSME MUST be disabled for NVIDIA driver to work.
# WHY: NVIDIA's proprietary driver cannot handle encrypted memory pages.
#      DMA initialization fails with "Failed to initialize DMA" errors.
#      The Xorg server won't start, nvidia-smi shows no GPUs.
#      This is a hard incompatibility with NO workaround except disabling.
# FIX: BIOS → Advanced → AMD CBS → CPU Common Options → SMEE → Disabled
#      BIOS → Advanced → AMD CBS → UMC Common Options → DDR Security → TSME → Disabled
#      Kernel: Do NOT add mem_encrypt=on to kernel parameters
# REF: https://github.com/NVIDIA/open-gpu-kernel-modules/issues/340
# REF: https://www.phoronix.com/news/Linux-SME-No-Default-Use

if echo "$CMDLINE" | grep -q "mem_encrypt=on"; then
    fail "mem_encrypt=on is set — this BREAKS NVIDIA driver!"
    echo "       → FIX: Remove mem_encrypt=on from /etc/default/grub IMMEDIATELY"
    echo "       → REF: https://github.com/NVIDIA/open-gpu-kernel-modules/issues/340"
else
    pass "mem_encrypt=on is NOT set in kernel command line"
fi

# Check if SME is active at kernel level
if dmesg 2>/dev/null | grep -qi "AMD Memory Encryption Features active: SME"; then
    fail "SME is ACTIVE in kernel — this will break NVIDIA driver!"
    echo "       → FIX: BIOS → Advanced → AMD CBS → CPU Common Options → SMEE → Disabled"
    echo "       → FIX: Also disable TSME in same menu"
elif dmesg 2>/dev/null | grep -qi "SME"; then
    info "SME mentioned in dmesg but may not be active — verify with: dmesg | grep SME"
else
    pass "No SME activity detected — good for NVIDIA compatibility"
fi

###############################################################################
# CHECK 11: CPU Microcode
###############################################################################
section "11. CPU Microcode"

# AMD microcode updates fix platform stability bugs including memory controller
# issues, power management quirks, and security vulnerabilities.
# The microcode package amd64-microcode should be installed and loaded at boot.
# Current expected microcode for Ryzen 9 7950X: 0xa60120c or newer
# REF: Ubuntu ships microcode via package: amd64-microcode

MICROCODE=$(cat /proc/cpuinfo | grep "microcode" | head -1 | awk '{print $3}')
if [ -n "$MICROCODE" ]; then
    pass "CPU microcode loaded: $MICROCODE"
    if dpkg -l | grep -q "amd64-microcode"; then
        UCODE_VER=$(dpkg -l amd64-microcode | grep "^ii" | awk '{print $3}')
        info "amd64-microcode package version: $UCODE_VER"
    fi
else
    warn "Could not determine CPU microcode version"
fi

###############################################################################
# CHECK 12: Memory Configuration
###############################################################################
section "12. Memory Configuration"

# For ML workloads, we want maximum stable bandwidth.
# DDR5-6000 CL30 is the sweet spot for Zen 4 (1:1 FCLK if silicon permits).
# 2x DIMM is more stable than 4x on AM5.
# UMA allocation for iGPU reduces available system RAM by 512MB-1GB.
# REF: https://www.overclock.net/threads/ddr5-woes-on-am5.1810036/
# REF: https://linustechtips.com/topic/1532574-7950x-2-x-16gb-trident-z5-ddr5-6000-cl30-cannot-run-stable-with-expo/

TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_MEM_GB=$(echo "scale=1; $TOTAL_MEM_KB / 1024 / 1024" | bc)
info "Total system RAM: ${TOTAL_MEM_GB} GB"

DIMM_COUNT=$(sudo dmidecode -t memory 2>/dev/null | grep -c "Size: [0-9]" || echo "unknown")
info "Populated DIMM slots: $DIMM_COUNT"

if [ "$DIMM_COUNT" = "2" ]; then
    pass "2x DIMM configuration (recommended for AM5 stability)"
elif [ "$DIMM_COUNT" = "4" ]; then
    warn "4x DIMM configuration — may have EXPO stability issues on AM5"
    echo "       → If experiencing crashes, consider moving to 2x higher-capacity DIMMs"
    echo "       → REF: https://www.overclock.net/threads/ddr5-woes-on-am5.1810036/"
fi

# Check memory speed
MEM_SPEED=$(sudo dmidecode -t memory 2>/dev/null | grep "Speed:" | grep -v "Unknown\|Configured" | head -1 | awk '{print $2, $3}' || echo "unknown")
info "Memory speed: $MEM_SPEED"

###############################################################################
# CHECK 13: Kernel Version
###############################################################################
section "13. Kernel Version"

# HWE kernel 6.17 is the recommended target — it fixes gfx ring timeouts on
# Raphael gfx1036 natively (GFXOFF rework landed in 6.9-6.11). Kernel 6.8 GA
# is acceptable as a fallback with the gfx_off=0 workaround. NVIDIA 595.58.03
# supports kernels 6.8 through 6.19 (validated by CUDA 13.2 install guide).
#
# NOTE: Older NVIDIA branches (470/535/early-550) had compile failures on 6.11+
#       due to an fbdev header rename. This was fixed in NVIDIA 550.135 (Nov 2024).
#       NVIDIA 595.58.03 inherits the fix — HWE kernels are fully supported.
#
# REF: https://gitlab.freedesktop.org/drm/amd/-/issues/3006 (ring timeout)
# REF: https://docs.nvidia.com/cuda/cuda-installation-guide-linux/ (validates 6.17)
# REF: https://docs.nvidia.com/datacenter/tesla/tesla-release-notes-595-58-03/
# REF: https://bbs.archlinux.org/viewtopic.php?id=299450 (fbdev fix history)

KERNEL=$(uname -r)
KERNEL_MAJOR=$(echo "$KERNEL" | cut -d. -f1-2)
info "Running kernel: $KERNEL"

if echo "$KERNEL" | grep -qE "^6\.(1[1-9]|[2-9][0-9])\."; then
    pass "HWE kernel $KERNEL_MAJOR — gfx ring timeout fix included, NVIDIA 595 compatible"
elif echo "$KERNEL" | grep -q "^6\.8\."; then
    warn "GA kernel 6.8 — ring timeout workaround (gfx_off=0) required"
    echo "       → FIX: sudo apt install linux-generic-hwe-24.04 && reboot"
    echo "       → REF: https://gitlab.freedesktop.org/drm/amd/-/issues/3006"
else
    warn "Kernel $KERNEL — verify compatibility with NVIDIA 595 and amdgpu"
fi

###############################################################################
# CHECK 14: Key Kernel Parameters
###############################################################################
section "14. Kernel Boot Parameters"

# Check all critical kernel parameters
# Each parameter addresses a specific hardware issue documented in the research
# REF: https://gist.github.com/dlqqq/876d74d030f80dc899fc58a244b72df0 (C-state freezes)
# REF: https://wiki.archlinux.org/title/AMDGPU (sg_display, dcdebugmask)

check_param() {
    local param="$1"
    local desc="$2"
    local fix="$3"
    if echo "$CMDLINE" | grep -q "$param"; then
        pass "$param is set — $desc"
    else
        warn "$param is NOT set — $desc"
        echo "       → FIX: $fix"
    fi
}

check_param "amdgpu.sg_display=0" \
    "Prevents Raphael iGPU scatter-gather display corruption" \
    "Add to GRUB_CMDLINE_LINUX_DEFAULT. REF: https://wiki.archlinux.org/title/AMDGPU"

check_param "amdgpu.dcdebugmask=0x10" \
    "Disables PSR to prevent flicker and multi-monitor wake issues" \
    "Add to GRUB_CMDLINE_LINUX_DEFAULT. REF: https://docs.kernel.org/gpu/amdgpu/display/dc-debug.html"

check_param "amdgpu.gfx_off=0" \
    "Disables GFXOFF power gating — prevents gfx ring timeouts on Raphael" \
    "Add to GRUB_CMDLINE_LINUX_DEFAULT. REF: https://gitlab.freedesktop.org/drm/amd/-/issues/3006"

check_param "amdgpu.ppfeaturemask=0xfffd7fff" \
    "Disables PP_GFXOFF + PP_STUTTER_MODE — firmware-level ring timeout prevention" \
    "Add to GRUB_CMDLINE_LINUX_DEFAULT. REF: https://docs.kernel.org/gpu/amdgpu/module-parameters.html"

check_param "pcie_aspm=off" \
    "Prevents RTX 4090 Xid 79 PCIe link drops" \
    "Add to GRUB_CMDLINE_LINUX_DEFAULT + BIOS ASPM → Disabled. REF: https://forums.developer.nvidia.com/t/gpu-has-fallen-off-the-bus-issues-on-daily-basis-rtx-4090/314647"

check_param "iommu=pt" \
    "IOMMU pass-through — optimal DMA for CUDA compute" \
    "Add to GRUB_CMDLINE_LINUX_DEFAULT + BIOS IOMMU → Enabled. REF: https://docs.nvidia.com/cuda/cuda-installation-guide-linux/"

check_param "nogpumanager" \
    "Prevents Ubuntu gpu-manager from overriding manual GPU config" \
    "Add to GRUB_CMDLINE_LINUX_DEFAULT. Also: sudo systemctl mask gpu-manager"

# processor.max_cstate=1 — Prevents Ryzen deep C-state freezes
# WHY: Ryzen 7000 series has a documented kernel bug where transitions into deep
#      C-states (C2+, especially C6) cause intermittent system freezes. The AMD
#      data fabric entering deep sleep can stall PCIe transactions, contributing
#      to both CPU freezes and GPU "fell off the bus" events. Setting max_cstate=1
#      keeps the CPU in C1 (halt) which still saves power versus C0 (active) but
#      avoids the problematic deep sleep transitions.
# COST: ~15-20W higher idle power (CPU stays in C1 instead of C6)
# BIOS: Also disable Global C-state Control for belt-and-suspenders [TIER 2: B11]
# REF: https://gist.github.com/dlqqq/876d74d030f80dc899fc58a244b72df0
# REF: https://bugzilla.kernel.org/show_bug.cgi?id=206299
check_param "processor.max_cstate=1" \
    "Limits CPU C-states to C1 — prevents Ryzen deep-sleep freezes (+15-20W idle)" \
    "Add to GRUB_CMDLINE_LINUX_DEFAULT. ALSO: BIOS → Global C-state Control → Disabled. REF: https://bugzilla.kernel.org/show_bug.cgi?id=206299"

# amd_pstate=active — AMD P-State EPP CPU frequency scaling driver
# WHY: On kernel 6.8 GA, the default CPU frequency driver is acpi-cpufreq, which
#      provides coarse-grained frequency control. amd_pstate=active enables the
#      modern EPP (Energy Performance Preference) driver that uses hardware
#      collaboration (CPPC v2) for finer-grained CPU frequency control.
#      On kernel 6.11+, amd-pstate-epp is the default for Zen 2+ — the explicit
#      parameter is harmless but ensures it activates on the 6.8 GA fallback.
# INTERACTION: power-profiles-daemon (PPD) v0.20+ can set EPP via sysfs.
#      Setting PPD to "performance" profile sets all cores to max frequency.
# REF: https://docs.kernel.org/admin-guide/pm/amd-pstate.html
# REF: https://wiki.archlinux.org/title/CPU_frequency_scaling#amd_pstate
if echo "$CMDLINE" | grep -q "amd_pstate=active"; then
    pass "amd_pstate=active is set — AMD P-State EPP driver enabled"
else
    if echo "$(uname -r)" | grep -q "^6\.8\."; then
        warn "amd_pstate=active NOT set — needed on kernel 6.8 for optimal CPU frequency scaling"
        echo "       → FIX: Add amd_pstate=active to GRUB_CMDLINE_LINUX_DEFAULT"
        echo "       → REF: https://docs.kernel.org/admin-guide/pm/amd-pstate.html"
    else
        info "amd_pstate=active not in cmdline (default on kernel 6.11+ for Zen 4)"
    fi
fi

# Verify the actual CPU scaling driver regardless of cmdline
if [ -f /sys/devices/system/cpu/cpufreq/policy0/scaling_driver ]; then
    SCALING_DRIVER=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_driver 2>/dev/null || echo "unknown")
    if [ "$SCALING_DRIVER" = "amd-pstate-epp" ]; then
        pass "CPU scaling driver: amd-pstate-epp (EPP active, optimal for Zen 4)"
    elif [ "$SCALING_DRIVER" = "amd-pstate" ]; then
        pass "CPU scaling driver: amd-pstate (passive mode — consider active/EPP)"
    elif [ "$SCALING_DRIVER" = "acpi-cpufreq" ]; then
        warn "CPU scaling driver: acpi-cpufreq (legacy — amd_pstate recommended)"
        echo "       → FIX: Add amd_pstate=active to GRUB_CMDLINE_LINUX_DEFAULT"
    else
        info "CPU scaling driver: $SCALING_DRIVER"
    fi
fi

# BIOS-only settings — informational reminders
# These cannot be verified via Linux sysfs/procfs. We remind the user to check BIOS.
info "BIOS-only settings (cannot verify from Linux — check manually):"
info "  [TIER 1] GFXOFF → Disabled (B22)"
info "    Path: Advanced → AMD CBS → NBIO Common Options → SMU Common Options → GFXOFF"
info "    WHY: BIOS-level master switch for GFX power gating — most authoritative GFXOFF"
info "         disable. Prevents 'ring gfx_0.0.0 timeout' errors. Kernel params (gfx_off=0,"
info "         ppfeaturemask) are belt-and-suspenders layers below this."
info "  [TIER 2] Global C-state Control → Disabled (B11)"
info "    Path: Advanced → AMD CBS → Global C-state Control (at CBS root level)"
info "    WHY: Hardware-level complement to processor.max_cstate=1 kernel param"
info "  [TIER 2] DF C-states → Disabled (B12)"
info "    Path: Advanced → AMD CBS → DF Common Options → DF Cstates"
info "    WHY: Prevents Data Fabric deep idle that stalls PCIe/memory transactions"
info "  [TIER 2] Restore AC Power Loss → Power On (B13)"
info "    Path: Advanced → APM Configuration → Restore AC Power Loss"
info "    WHY: Auto-restart after power outage during long training runs"
info "  [TIER 2] Wait For F1 If Error → Disabled (B14)"
info "    Path: Boot → Wait For F1 If Error"
info "    WHY: Prevents boot hang on non-critical BIOS errors during unattended restart"

###############################################################################
# CHECK 14b: ML Training BIOS Optimizations (Tier 3)
###############################################################################
section "14b. ML Training BIOS Optimizations (Tier 3)"

info "These BIOS settings optimize for AI model training throughput."
info "They have NO effect on display or driver operation."
info ""
info "  [TIER 3] Eco Mode (PBO) → Disabled (B18)"
info "    Path: Extreme Tweaker → Precision Boost Overdrive → Eco Mode"
info "    WHY: Eco Mode caps 7950X to 65W TDP. Full 170W needed for data loading."
info "  [TIER 3] APBDIS → 1, Fixed SOC Pstate → P0 (B19)"
info "    Path: Advanced → AMD CBS → NBIO Common Options → SMU Common Options → APBDIS"
info "    WHY: Locks SoC frequency for consistent IOMMU/memory controller throughput"
info "  [TIER 3] Memory Context Restore → Enabled (B20)"
info "    Path: Advanced → AMD CBS → UMC Common Options → DDR Options → DDR Memory Features → Memory Context Restore"
info "    WHY: Saves DDR5 training data for faster S3 resume (~30-60s savings)"
info "  [TIER 3] Power Supply Idle Control → Typical Current Idle (B21)"
info "    Path: Advanced → AMD CBS → CPU Common Options → Power Supply Idle Control"
info "    WHY: Prevents VRM low-current transition that adds latency on wakeup"

###############################################################################
# CHECK 15: nouveau Blacklist
###############################################################################
section "15. nouveau Driver Status"

# nouveau (open-source NVIDIA driver) MUST be blacklisted.
# WHY: If nouveau loads, it conflicts with the proprietary nvidia module.
#      Both cannot control the same hardware simultaneously.
# FIX: Create /etc/modprobe.d/blacklist-nouveau.conf
# REF: https://docs.nvidia.com/cuda/cuda-installation-guide-linux/

if lsmod | grep -q "^nouveau"; then
    fail "nouveau module is LOADED — this conflicts with NVIDIA proprietary driver!"
    echo "       → FIX: Create /etc/modprobe.d/blacklist-nouveau.conf with:"
    echo "              blacklist nouveau"
    echo "              options nouveau modeset=0"
    echo "       → FIX: Run: sudo update-initramfs -u && sudo reboot"
else
    pass "nouveau module is not loaded"
fi

if [ -f /etc/modprobe.d/blacklist-nouveau.conf ]; then
    pass "blacklist-nouveau.conf exists"
else
    if ! lsmod | grep -q "^nouveau"; then
        info "blacklist-nouveau.conf not found but nouveau is not loaded (may be handled elsewhere)"
    else
        fail "blacklist-nouveau.conf does not exist — create it!"
    fi
fi

###############################################################################
# SUMMARY
###############################################################################
section "SUMMARY"

echo ""
echo -e "  ${GREEN}Passed: $PASS${NC}"
echo -e "  ${RED}Failed: $FAIL${NC}"
echo -e "  ${YELLOW}Warnings: $WARN${NC}"
echo ""

if [ $FAIL -gt 0 ]; then
    echo -e "${RED}${BOLD}CRITICAL: $FAIL check(s) failed. Fix these before proceeding!${NC}"
    echo "Re-run this script after applying fixes."
    exit 1
elif [ $WARN -gt 0 ]; then
    echo -e "${YELLOW}${BOLD}$WARN warning(s). Can proceed but should address these.${NC}"
    exit 2
else
    echo -e "${GREEN}${BOLD}All checks passed! Ready to proceed with driver installation.${NC}"
    exit 0
fi
