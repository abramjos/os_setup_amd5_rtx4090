#!/bin/bash
# =============================================================================
# 01-rollback.sh — Rollback Phase 1 (Display Fix) Changes
# =============================================================================
#
# Reverts changes made by 01-first-boot-display-fix.sh, step by step.
#
# USAGE:
#   sudo bash 01-rollback.sh           # Rollback ALL Phase 1 steps
#   sudo bash 01-rollback.sh 1 3 6     # Rollback only steps 1, 3, and 6
#   sudo bash 01-rollback.sh --list    # Show available steps
#
# After rollback: sudo reboot
# Then re-run:    sudo bash 01-first-boot-display-fix.sh
# =============================================================================

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

if [ "${1:-}" = "--list" ] || [ "${1:-}" = "-l" ]; then
    echo "Available rollback steps for Phase 1:"
    echo "  1  GRUB kernel parameters    → restore from backup"
    echo "  2  amdgpu modprobe config    → remove /etc/modprobe.d/amdgpu.conf"
    echo "  3  HWE kernel                → unhold packages (does NOT remove HWE)"
    echo "  4  gpu-manager               → unmask and re-enable"
    echo "  5  GDM display manager       → restore Wayland default"
    echo "  6  Raphael iGPU firmware     → restore from backup"
    echo "  7  Display utilities         → (no rollback needed — packages stay)"
    echo ""
    echo "Usage: sudo bash 01-rollback.sh [step_numbers...]"
    echo "  No arguments = rollback all steps"
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}ERROR: This script must be run as root (sudo)${NC}"
    exit 1
fi

# Determine which steps to rollback
STEPS=()
if [ $# -eq 0 ]; then
    STEPS=(1 2 3 4 5 6 7)
    echo -e "${YELLOW}Rolling back ALL Phase 1 steps...${NC}"
else
    STEPS=("$@")
    echo -e "${YELLOW}Rolling back Phase 1 steps: ${STEPS[*]}${NC}"
fi
echo ""

CHANGES=0

for STEP in "${STEPS[@]}"; do
    case "$STEP" in
    1)
        # -----------------------------------------------------------------
        # Step 1: Restore GRUB
        # -----------------------------------------------------------------
        echo -e "${BLUE}[Step 1]${NC} Restoring GRUB configuration..."

        # Prefer the timestamped backup (survives re-runs); fall back to .bak.ml-setup
        TIMESTAMP_BACKUP=$(ls -1t /etc/default/grub.backup.* 2>/dev/null | head -1)
        if [ -n "$TIMESTAMP_BACKUP" ]; then
            cp "$TIMESTAMP_BACKUP" /etc/default/grub
            update-grub 2>/dev/null || true
            echo -e "  ${GREEN}Restored from ${TIMESTAMP_BACKUP}${NC}"
            CHANGES=$((CHANGES+1))
        elif [ -f /etc/default/grub.bak.ml-setup ]; then
            cp /etc/default/grub.bak.ml-setup /etc/default/grub
            update-grub 2>/dev/null || true
            echo -e "  ${GREEN}Restored from .bak.ml-setup${NC}"
            CHANGES=$((CHANGES+1))
        else
            echo -e "  ${YELLOW}No GRUB backup found — skipping${NC}"
        fi
        ;;
    2)
        # -----------------------------------------------------------------
        # Step 2: Remove amdgpu modprobe config
        # -----------------------------------------------------------------
        echo -e "${BLUE}[Step 2]${NC} Removing amdgpu modprobe configuration..."
        if [ -f /etc/modprobe.d/amdgpu.conf ]; then
            rm -f /etc/modprobe.d/amdgpu.conf
            echo -e "  ${GREEN}Removed /etc/modprobe.d/amdgpu.conf${NC}"
            CHANGES=$((CHANGES+1))
        else
            echo "  Nothing to remove"
        fi
        ;;
    3)
        # -----------------------------------------------------------------
        # Step 3: Revert kernel configuration
        # -----------------------------------------------------------------
        echo -e "${BLUE}[Step 3]${NC} Reverting kernel configuration..."

        # Remove stale kernel pin file
        if [ -f /etc/apt/preferences.d/pin-kernel-ga ]; then
            rm -f /etc/apt/preferences.d/pin-kernel-ga
            echo -e "  ${GREEN}Removed kernel pin file${NC}"
            CHANGES=$((CHANGES+1))
        fi

        # Unhold any held kernel packages
        apt-mark unhold linux-generic linux-image-generic linux-headers-generic 2>/dev/null || true

        # Report HWE status (do NOT auto-remove)
        if dpkg -l linux-generic-hwe-24.04 2>/dev/null | grep -q "^ii"; then
            echo -e "  ${YELLOW}HWE kernel is still installed (safe to keep)${NC}"
            echo "  To remove: sudo apt remove linux-generic-hwe-24.04"
            echo "  To keep (recommended): provides kernel fixes for gfx ring timeout"
        fi
        echo -e "  ${GREEN}Kernel holds/pins removed${NC}"
        ;;
    4)
        # -----------------------------------------------------------------
        # Step 4: Re-enable gpu-manager
        # -----------------------------------------------------------------
        echo -e "${BLUE}[Step 4]${NC} Re-enabling gpu-manager..."
        systemctl unmask gpu-manager 2>/dev/null || true
        systemctl enable gpu-manager 2>/dev/null || true
        echo -e "  ${GREEN}gpu-manager unmasked and enabled${NC}"
        CHANGES=$((CHANGES+1))
        ;;
    5)
        # -----------------------------------------------------------------
        # Step 5: Restore GDM configuration
        # -----------------------------------------------------------------
        echo -e "${BLUE}[Step 5]${NC} Restoring GDM configuration..."
        if [ -f /etc/gdm3/custom.conf.bak.ml-setup ]; then
            cp /etc/gdm3/custom.conf.bak.ml-setup /etc/gdm3/custom.conf
            echo -e "  ${GREEN}Restored from backup${NC}"
            CHANGES=$((CHANGES+1))
        elif [ -f /etc/gdm3/custom.conf ]; then
            sed -i 's/^WaylandEnable=false/WaylandEnable=true/' /etc/gdm3/custom.conf
            echo -e "  ${GREEN}Re-enabled Wayland in GDM${NC}"
            CHANGES=$((CHANGES+1))
        else
            echo "  GDM config not found — skipping"
        fi
        ;;
    6)
        # -----------------------------------------------------------------
        # Step 6: Restore original iGPU firmware
        # -----------------------------------------------------------------
        echo -e "${BLUE}[Step 6]${NC} Restoring original iGPU firmware..."
        FW_BACKUP="/lib/firmware/amdgpu/backup-pre-ml-setup"
        if [ -d "$FW_BACKUP" ] && ls "$FW_BACKUP"/*.bin &>/dev/null; then
            RESTORED=0
            for fw in "$FW_BACKUP"/*.bin; do
                fname=$(basename "$fw")
                cp "$fw" "/lib/firmware/amdgpu/${fname}"
                RESTORED=$((RESTORED+1))
            done
            echo -e "  ${GREEN}Restored ${RESTORED} firmware files${NC}"
            rm -rf "$FW_BACKUP"
            CHANGES=$((CHANGES+1))
        else
            echo "  No firmware backup found — skipping"
        fi
        ;;
    7)
        # -----------------------------------------------------------------
        # Step 7: Display utilities (nothing to rollback)
        # -----------------------------------------------------------------
        echo -e "${BLUE}[Step 7]${NC} Display utilities — no rollback needed"
        echo "  Packages (mesa-utils, vainfo, etc.) are harmless to keep"
        ;;
    *)
        echo -e "${RED}Unknown step: ${STEP} (valid: 1-7)${NC}"
        ;;
    esac
    echo ""
done

# Rebuild initramfs if anything changed
if [ $CHANGES -gt 0 ]; then
    echo -e "${BLUE}Rebuilding initramfs...${NC}"
    update-initramfs -u -k all 2>/dev/null || true
    echo -e "${GREEN}initramfs rebuilt${NC}"
    echo ""
    echo -e "${GREEN}================================================================${NC}"
    echo -e "${GREEN} Phase 1 rollback complete (${CHANGES} steps reverted)${NC}"
    echo -e "${GREEN}================================================================${NC}"
    echo ""
    echo "  Reboot to apply: sudo reboot"
    echo "  Then re-run:     sudo bash 01-first-boot-display-fix.sh"
else
    echo "  No changes were made."
fi
