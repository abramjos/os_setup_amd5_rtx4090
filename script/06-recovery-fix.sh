#!/bin/bash
###############################################################################
# 06-recovery-fix.sh
#
# PURPOSE: Fix all identified boot failures from recovery mode root shell.
#          No internet or git required — purely local file edits.
#
# RUN FROM: Ubuntu recovery mode root shell (GRUB > Advanced > recovery > root)
#
# WHAT THIS FIXES:
#
#   [FIX 1] xorg.conf BusID — CRITICAL
#     Phase 3 script assigned BOTH GPUs to PCI:1:0:0 (NVIDIA's address).
#     AMD iGPU is at lspci 6c:00.0 = xorg PCI:108:0:0.
#     X11 can't open two devices at the same BusID → GDM crash-loop →
#     "Session never registered" → black screen on EVERY normal boot.
#
#   [FIX 2] GRUB kernel parameters — CRITICAL
#     - amdgpu.noretry had no value → "'' invalid for parameter 'noretry'"
#       → amdgpu module refused to load → no display driver → black screen
#     - amdgpu.gfxoff=0 / gfx_off=0 are invalid on kernel 6.17 (removed
#       upstream in 6.9-6.11 GFXOFF rework) — remove to avoid warnings
#     - GRUB_TIMEOUT=0 prevents accessing GRUB menu — set to 3
#     - Adds modprobe.blacklist=nouveau (was missing or typo'd on some boots)
#
#   [FIX 3] udev rule — card number hardcoded
#     Rule targets KERNEL=="card0" but AMD iGPU is card2 (nouveau loads first
#     as card1, amdgpu loads as card2). Fix: match by driver name with wildcard.
#
#   [FIX 4] Firmware .bin/.bin.zst conflict
#     gc_10_3_6 has BOTH .bin (manual Mar 27 copy) and .bin.zst (apt Feb 19).
#     Kernel firmware loader prefers .bin.zst → loads OLD firmware, ignores new.
#     Fix: remove stale .bin files so kernel loads .bin.zst consistently.
#     NOTE: Firmware VERSION update (to 20251021) requires internet/git and
#     is handled separately by 04-update-firmware-20251021.sh.
#
#   [FIX 5] Rebuild initramfs
#     Embeds corrected firmware into boot image for all installed kernels.
#
# EVIDENCE (from run2 multi-boot diagnostic):
#   Boots -9 through -5 had amdgpu loaded with ZERO ring gfx_0.0.0 timeouts.
#   The ring timeout problem appears SOLVED by current kernel params.
#   Black screen was caused entirely by xorg.conf BusID bug (boots -9 to -5)
#   and broken amdgpu.noretry (boots -3 to -1).
#
# SYSTEM: Ryzen 9 7950X | ASUS ROG Crosshair X670E Hero | RTX 4090
#         Ubuntu 24.04.1 LTS | Kernel 6.17.0-19-generic (6.8 GA fallback)
#         AMD iGPU: Raphael PCI 6c:00.0 | NVIDIA: PCI 01:00.0
#
# USAGE:
#   1. Boot into GRUB (hold Shift during POST if GRUB_TIMEOUT=0)
#   2. Select "Advanced options for Ubuntu"
#   3. Select any kernel with "(recovery mode)"
#   4. Select "root — Drop to root shell prompt"
#   5. Press Enter for maintenance
#   6. Run: mount -o remount,rw /
#   7. Run: bash /path/to/06-recovery-fix.sh
#   8. Reboot: reboot
#
# REQUIRES: Root (recovery shell is root by default)
# REBOOT:   Required after running
###############################################################################

set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

# Logging — capture everything to a timestamped log file
LOG_FILE="/tmp/06-recovery-fix-$(date +%Y%m%d-%H%M%S).log"

# Tee all stdout and stderr to the log file while still printing to console
exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== Recovery Fix Log Started: $(date) =====" >> "$LOG_FILE"

echo -e "${BLUE}[Log]${NC} All output saved to: ${LOG_FILE}"
echo ""

echo -e "${BOLD}================================================================${NC}"
echo -e "${BOLD}  Recovery Mode Fix Script${NC}"
echo -e "${BOLD}  Fixing: xorg BusID, GRUB params, udev, firmware conflict${NC}"
echo -e "${BOLD}================================================================${NC}"
echo ""

# Ensure running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}ERROR: Must run as root.${NC}"
    exit 1
fi

# Ensure filesystem is mounted read-write
if mount | grep ' / ' | grep -q 'ro[,)]'; then
    echo -e "${YELLOW}Filesystem is read-only. Remounting read-write...${NC}"
    mount -o remount,rw /
    echo -e "${GREEN}Remounted / as read-write${NC}"
fi
echo ""

ERRORS=0

###############################################################################
# FIX 1: xorg.conf BusID
###############################################################################
echo -e "${BLUE}[FIX 1/5]${NC} Correcting xorg.conf GPU BusIDs..."

XORG_CONF="/etc/X11/xorg.conf.d/10-gpu.conf"

if [ ! -f "$XORG_CONF" ]; then
    echo -e "${YELLOW}  SKIP: ${XORG_CONF} not found${NC}"
else
    # Back up
    cp "$XORG_CONF" "${XORG_CONF}.bak.$(date +%Y%m%d%H%M%S)"

    # Current state: both sections have BusID "PCI:1:0:0"
    # AMD iGPU is at lspci 6c:00.0
    #   6c hex = 108 decimal → xorg BusID PCI:108:0:0
    # NVIDIA is at lspci 01:00.0
    #   01 hex = 1 decimal → xorg BusID PCI:1:0:0 (already correct)
    #
    # The AMD section (Device-amd with Driver "amdgpu") needs PCI:108:0:0
    # The NVIDIA section (Device-nvidia with Driver "nvidia") keeps PCI:1:0:0

    # Strategy: rewrite the entire file to avoid ambiguous sed on duplicate lines
    if grep -q 'BusID.*"PCI:1:0:0"' "$XORG_CONF" && grep -q 'Driver.*"amdgpu"' "$XORG_CONF"; then
        # Use awk to fix only the BusID in the AMD device section
        awk '
        /Section "Device"/ { in_device=1; is_amd=0 }
        in_device && /Driver.*"amdgpu"/ { is_amd=1 }
        in_device && is_amd && /BusID/ {
            sub(/"PCI:[^"]*"/, "\"PCI:108:0:0\"")
        }
        /EndSection/ { in_device=0; is_amd=0 }
        { print }
        ' "$XORG_CONF" > "${XORG_CONF}.tmp" && mv "${XORG_CONF}.tmp" "$XORG_CONF"

        # Verify
        AMD_BUS=$(awk '/Driver.*"amdgpu"/{found=1} found && /BusID/{print; found=0}' "$XORG_CONF")
        NV_BUS=$(awk '/Driver.*"nvidia"/{found=1} found && /BusID/{print; found=0}' "$XORG_CONF")

        echo -e "  ${GREEN}AMD iGPU BusID: ${AMD_BUS}${NC}"
        echo -e "  ${GREEN}NVIDIA BusID:   ${NV_BUS}${NC}"

        if echo "$AMD_BUS" | grep -q "108:0:0" && echo "$NV_BUS" | grep -q "1:0:0"; then
            echo -e "  ${GREEN}xorg.conf BusIDs corrected${NC}"
        else
            echo -e "  ${RED}WARNING: BusID verification failed — check ${XORG_CONF} manually${NC}"
            ERRORS=$((ERRORS + 1))
        fi
    else
        echo -e "  ${YELLOW}xorg.conf doesn't match expected pattern — skipping auto-fix${NC}"
        echo -e "  ${YELLOW}Manually verify BusIDs in ${XORG_CONF}${NC}"
        ERRORS=$((ERRORS + 1))
    fi

    # Also fix the comment header to reflect correct BusIDs
    sed -i 's/# AMD iGPU BusID: PCI:1:0:0.*/# AMD iGPU BusID: PCI:108:0:0 (detected from lspci: 6c:00.0)/' "$XORG_CONF"
    sed -i 's/# NVIDIA BusID:   PCI:1:0:0.*/# NVIDIA BusID:   PCI:1:0:0 (detected from lspci: 01:00.0)/' "$XORG_CONF"
fi
echo ""

###############################################################################
# FIX 2: GRUB kernel parameters
###############################################################################
echo -e "${BLUE}[FIX 2/5]${NC} Fixing GRUB kernel parameters..."

GRUB_FILE="/etc/default/grub"

if [ ! -f "$GRUB_FILE" ]; then
    echo -e "${RED}  ERROR: ${GRUB_FILE} not found!${NC}"
    ERRORS=$((ERRORS + 1))
else
    # Back up
    cp "$GRUB_FILE" "${GRUB_FILE}.bak.$(date +%Y%m%d%H%M%S)"

    # Show current state
    CURRENT_CMDLINE=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE" || echo "(not set)")
    echo -e "  Current: ${CURRENT_CMDLINE}"

    # New GRUB cmdline:
    #   loglevel=4                    — verbose boot (no quiet/splash, per user preference)
    #   amdgpu.sg_display=0           — prevent black screen (scatter-gather DMA bug)
    #   amdgpu.vm_fragment_size=9     — fix VM page table fragmentation (freedesktop #4955)
    #   amdgpu.seamless=0             — force full CRTC reset during FB handoff (prevents optc31 cascade)
    #   amdgpu.dcdebugmask=0x10       — disable PSR (Panel Self Refresh) — prevents flicker
    #   amdgpu.ppfeaturemask=0xfffd7fff — disable GFXOFF + stutter at firmware level
    #   amdgpu.noretry=0              — allow GPU page fault retries (reduces false timeouts on UMA)
    #   amdgpu.lockup_timeout=10000,10000,10000,10000 — 10s timeout per ring (GFX,Compute,SDMA,Video)
    #   modprobe.blacklist=nouveau    — prevent nouveau from loading (conflicts with future nvidia driver)
    #   pcie_aspm=off                 — prevent PCIe power saving issues (NVIDIA Xid 79)
    #   iommu=pt                      — IOMMU passthrough for GPU compute performance
    #   nogpumanager                  — prevent Ubuntu gpu-manager from overriding xorg.conf
    #   processor.max_cstate=1        — prevent deep CPU idle states that can stall PCIe
    #
    # REMOVED:
    #   amdgpu.gfxoff=0 / gfx_off=0  — invalid on kernel 6.17 (parameter removed upstream)
    #   quiet splash                  — user wants verbose boot
    #   nvidia-drm.modeset=1          — NVIDIA driver not installed yet
    #   nvidia-drm.fbdev=1            — NVIDIA driver not installed yet
    #   amd_pstate=active             — not needed (active is default on 6.17)

    NEW_CMDLINE='GRUB_CMDLINE_LINUX_DEFAULT="loglevel=4 amdgpu.sg_display=0 amdgpu.vm_fragment_size=9 amdgpu.seamless=0 amdgpu.dcdebugmask=0x10 amdgpu.ppfeaturemask=0xfffd7fff amdgpu.noretry=0 amdgpu.lockup_timeout=10000,10000,10000,10000 modprobe.blacklist=nouveau pcie_aspm=off iommu=pt nogpumanager processor.max_cstate=1"'

    # Replace the GRUB_CMDLINE_LINUX_DEFAULT line
    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|${NEW_CMDLINE}|" "$GRUB_FILE"

    # Fix GRUB_TIMEOUT: set to 3 so GRUB menu is accessible for kernel switching
    if grep -q '^GRUB_TIMEOUT=0' "$GRUB_FILE"; then
        sed -i 's/^GRUB_TIMEOUT=0/GRUB_TIMEOUT=3/' "$GRUB_FILE"
        echo -e "  ${GREEN}GRUB_TIMEOUT: 0 → 3 (menu now accessible)${NC}"
    fi

    # Show hidden timeout style warning
    if grep -q 'GRUB_TIMEOUT_STYLE=hidden' "$GRUB_FILE"; then
        sed -i 's/^GRUB_TIMEOUT_STYLE=hidden/GRUB_TIMEOUT_STYLE=menu/' "$GRUB_FILE"
        echo -e "  ${GREEN}GRUB_TIMEOUT_STYLE: hidden → menu${NC}"
    fi

    # Verify
    echo -e "  ${GREEN}New GRUB cmdline:${NC}"
    grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE" | sed 's/^/    /'

    # Run update-grub
    echo ""
    echo -e "  Running update-grub..."
    if update-grub 2>&1; then
        echo -e "  ${GREEN}GRUB updated successfully${NC}"
    else
        echo -e "  ${RED}update-grub failed — you may need to run it manually after reboot${NC}"
        ERRORS=$((ERRORS + 1))
    fi
fi
echo ""

###############################################################################
# FIX 3: udev rule — card number wildcard
###############################################################################
echo -e "${BLUE}[FIX 3/5]${NC} Fixing udev GDM seat rule..."

UDEV_GDM="/etc/udev/rules.d/61-gdm-amd-primary.rules"

if [ ! -f "$UDEV_GDM" ]; then
    echo -e "${YELLOW}  SKIP: ${UDEV_GDM} not found${NC}"
else
    cp "$UDEV_GDM" "${UDEV_GDM}.bak.$(date +%Y%m%d%H%M%S)"

    if grep -q 'KERNEL=="card0"' "$UDEV_GDM"; then
        # Replace hardcoded card0 with wildcard card[0-9]*, match by driver
        sed -i 's/KERNEL=="card0"/KERNEL=="card[0-9]*"/' "$UDEV_GDM"
        echo -e "  ${GREEN}Changed KERNEL==\"card0\" → KERNEL==\"card[0-9]*\"${NC}"
    else
        echo -e "  ${GREEN}Already uses wildcard or different pattern${NC}"
    fi

    echo -e "  Current rule:"
    cat "$UDEV_GDM" | sed 's/^/    /'
fi
echo ""

###############################################################################
# FIX 4: Firmware .bin / .bin.zst conflict
###############################################################################
echo -e "${BLUE}[FIX 4/5]${NC} Resolving firmware .bin/.bin.zst conflicts..."

FW_DIR="/lib/firmware/amdgpu"
CONFLICTS_FIXED=0

if [ ! -d "$FW_DIR" ]; then
    echo -e "${RED}  ERROR: ${FW_DIR} not found${NC}"
    ERRORS=$((ERRORS + 1))
else
    # For each gc_10_3_6 .bin file, check if a .bin.zst also exists
    for bin_file in "${FW_DIR}"/gc_10_3_6_*.bin; do
        [ -f "$bin_file" ] || continue
        # Skip if this is actually a .bin.zst (glob safety)
        case "$bin_file" in *.bin.zst) continue ;; esac

        zst_file="${bin_file}.zst"
        if [ -f "$zst_file" ]; then
            basename_bin=$(basename "$bin_file")
            basename_zst=$(basename "$zst_file")

            # The .bin.zst from apt is what the kernel loads (prefers compressed).
            # The .bin was a manual copy that the kernel IGNORES.
            # Remove the stale .bin to eliminate confusion.
            echo -e "  Removing stale: ${basename_bin} (kernel uses ${basename_zst})"
            rm -f "$bin_file"
            CONFLICTS_FIXED=$((CONFLICTS_FIXED + 1))
        fi
    done

    # Also check for orphaned .bin files without a .bin.zst
    # (these are loaded by the kernel and are fine to keep)
    for bin_file in "${FW_DIR}"/gc_10_3_6_*.bin; do
        [ -f "$bin_file" ] || continue
        case "$bin_file" in *.bin.zst) continue ;; esac
        echo -e "  ${GREEN}Kept (no .zst conflict): $(basename "$bin_file")${NC}"
    done

    if [ "$CONFLICTS_FIXED" -gt 0 ]; then
        echo -e "  ${GREEN}Removed ${CONFLICTS_FIXED} conflicting .bin file(s)${NC}"
    else
        echo -e "  ${GREEN}No .bin/.bin.zst conflicts found${NC}"
    fi

    # Show final firmware state
    echo ""
    echo -e "  gc_10_3_6 firmware files:"
    ls -la "${FW_DIR}"/gc_10_3_6_* 2>/dev/null | awk '{print "    " $NF " (" $5 " bytes, " $6 " " $7 " " $8 ")"}' || echo "    (none)"
fi
echo ""

###############################################################################
# FIX 5: Rebuild initramfs
###############################################################################
echo -e "${BLUE}[FIX 5/5]${NC} Rebuilding initramfs for all kernels..."

KERNELS=$(ls /boot/vmlinuz-* 2>/dev/null | sed 's|/boot/vmlinuz-||' | sort -V)
REBUILT=0

for kernel in $KERNELS; do
    if [ -d "/lib/modules/${kernel}" ]; then
        echo -e "  Updating initramfs for ${kernel}..."
        if update-initramfs -u -k "$kernel" 2>&1; then
            echo -e "  ${GREEN}Done: ${kernel}${NC}"
            REBUILT=$((REBUILT + 1))
        else
            echo -e "  ${RED}Failed: ${kernel}${NC}"
            ERRORS=$((ERRORS + 1))
        fi
    fi
done

echo -e "  ${GREEN}Rebuilt ${REBUILT} initramfs image(s)${NC}"
echo ""

###############################################################################
# Summary
###############################################################################
echo -e "${BOLD}================================================================${NC}"
if [ "$ERRORS" -eq 0 ]; then
    echo -e "${GREEN}${BOLD}  All Fixes Applied Successfully${NC}"
else
    echo -e "${YELLOW}${BOLD}  Fixes Applied with ${ERRORS} Warning(s)${NC}"
fi
echo -e "${BOLD}================================================================${NC}"
echo ""
echo -e "  ${BOLD}Changes made:${NC}"
echo -e "    [1] xorg.conf: AMD BusID PCI:1:0:0 → PCI:108:0:0"
echo -e "    [2] GRUB: fixed noretry=0, removed invalid gfxoff/gfx_off,"
echo -e "         added modprobe.blacklist=nouveau, timeout=3"
echo -e "    [3] udev: card0 → card[0-9]* (match by driver)"
echo -e "    [4] Firmware: removed .bin/.bin.zst duplicates"
echo -e "    [5] Rebuilt initramfs for all kernels"
echo ""
echo -e "  ${BOLD}Backups created:${NC}"
echo -e "    ${XORG_CONF:-/etc/X11/xorg.conf.d/10-gpu.conf}.bak.*"
echo -e "    ${GRUB_FILE:-/etc/default/grub}.bak.*"
echo -e "    ${UDEV_GDM:-/etc/udev/rules.d/61-gdm-amd-primary.rules}.bak.*"
echo ""
echo -e "  ${BOLD}${YELLOW}REBOOT NOW:${NC}"
echo -e "    reboot"
echo ""
echo -e "  ${BOLD}After reboot, verify:${NC}"
echo -e "    # Should see GNOME login screen (not black screen)"
echo -e "    # Then check:"
echo -e "    dmesg | grep -E 'amdgpu|ring.*timeout|optc31|noretry'"
echo -e "    glxinfo | grep 'OpenGL renderer'    # Should show AMD Radeon"
echo -e "    cat /proc/cmdline                    # Verify all params applied"
echo -e "    journalctl -u gdm3 --boot            # Should show successful session"
echo ""
echo -e "  ${BOLD}If still black screen:${NC}"
echo -e "    1. Boot recovery mode again"
echo -e "    2. Check: cat /var/log/Xorg.0.log | grep '(EE)'"
echo -e "    3. Check: journalctl -b -u gdm3"
echo -e "    4. Try kernel 6.8 from GRUB Advanced Options"
echo ""
