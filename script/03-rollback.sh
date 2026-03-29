#!/bin/bash
# =============================================================================
# 03-rollback.sh — Rollback Phase 3 (Display Configuration) Changes
# =============================================================================
#
# Reverts changes made by 03-configure-display.sh, step by step.
#
# USAGE:
#   sudo bash 03-rollback.sh           # Rollback ALL Phase 3 steps
#   sudo bash 03-rollback.sh 1 3 4     # Rollback only steps 1, 3, and 4
#   sudo bash 03-rollback.sh --list    # Show available steps
#
# After rollback: sudo reboot
# Then re-run:    sudo bash 03-configure-display.sh
# =============================================================================

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

if [ "${1:-}" = "--list" ] || [ "${1:-}" = "-l" ]; then
    echo "Available rollback steps for Phase 3:"
    echo "  1  X11 xorg.conf.d           → remove /etc/X11/xorg.conf.d/10-gpu.conf"
    echo "  2  udev rules                → remove GPU udev rules"
    echo "  3  Environment variables      → remove ML env vars from /etc/environment + profile.d"
    echo "  4  Systemd services           → unmask suspend, remove nvidia-power-settings"
    echo "  5  ML utility scripts         → remove gpu-ml-setup.sh, gpu-ml-reset.sh, gpu-status.sh"
    echo "  6  Monitoring tools           → (no rollback needed — packages stay)"
    echo ""
    echo "Usage: sudo bash 03-rollback.sh [step_numbers...]"
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
    STEPS=(1 2 3 4 5 6)
    echo -e "${YELLOW}Rolling back ALL Phase 3 steps...${NC}"
else
    STEPS=("$@")
    echo -e "${YELLOW}Rolling back Phase 3 steps: ${STEPS[*]}${NC}"
fi
echo ""

CHANGES=0

for STEP in "${STEPS[@]}"; do
    case "$STEP" in
    1)
        # -----------------------------------------------------------------
        # Step 1: Remove X11 configuration
        # -----------------------------------------------------------------
        echo -e "${BLUE}[Step 1]${NC} Removing X11 GPU configuration..."
        if [ -f /etc/X11/xorg.conf.d/10-gpu.conf ]; then
            rm -f /etc/X11/xorg.conf.d/10-gpu.conf
            echo -e "  ${GREEN}Removed /etc/X11/xorg.conf.d/10-gpu.conf${NC}"
            CHANGES=$((CHANGES+1))
        else
            echo "  Nothing to remove"
        fi
        ;;
    2)
        # -----------------------------------------------------------------
        # Step 2: Remove udev rules
        # -----------------------------------------------------------------
        echo -e "${BLUE}[Step 2]${NC} Removing udev rules..."
        for f in /etc/udev/rules.d/99-nvidia-compute.rules /etc/udev/rules.d/61-gdm-amd-primary.rules; do
            if [ -f "$f" ]; then
                rm -f "$f"
                echo -e "  ${GREEN}Removed $f${NC}"
                CHANGES=$((CHANGES+1))
            fi
        done
        udevadm control --reload-rules 2>/dev/null || true
        udevadm trigger 2>/dev/null || true
        ;;
    3)
        # -----------------------------------------------------------------
        # Step 3: Remove environment variables
        # -----------------------------------------------------------------
        echo -e "${BLUE}[Step 3]${NC} Removing environment variables..."

        # Remove CUDA environment profile
        if [ -f /etc/profile.d/cuda-env.sh ]; then
            rm -f /etc/profile.d/cuda-env.sh
            echo -e "  ${GREEN}Removed /etc/profile.d/cuda-env.sh${NC}"
            CHANGES=$((CHANGES+1))
        fi

        # Clean ML Workstation entries from /etc/environment
        if grep -q "ML Workstation" /etc/environment 2>/dev/null; then
            sed -i '/# === ML Workstation Dual-GPU Environment ===/,/^$/d' /etc/environment 2>/dev/null || true
            sed -i '/__GLX_VENDOR_LIBRARY_NAME/d' /etc/environment 2>/dev/null || true
            sed -i '/__GL_SYNC_TO_VBLANK/d' /etc/environment 2>/dev/null || true
            sed -i '/^DRI_PRIME/d' /etc/environment 2>/dev/null || true
            sed -i '/__NV_PRIME_RENDER_OFFLOAD/d' /etc/environment 2>/dev/null || true
            echo -e "  ${GREEN}Cleaned ML entries from /etc/environment${NC}"
            CHANGES=$((CHANGES+1))
        fi
        ;;
    4)
        # -----------------------------------------------------------------
        # Step 4: Restore systemd services
        # -----------------------------------------------------------------
        echo -e "${BLUE}[Step 4]${NC} Restoring systemd services..."

        # Unmask suspend targets
        systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null || true
        echo -e "  ${GREEN}Unmasked sleep/suspend/hibernate targets${NC}"
        CHANGES=$((CHANGES+1))

        # Remove custom service
        if [ -f /etc/systemd/system/nvidia-power-settings.service ]; then
            systemctl disable nvidia-power-settings 2>/dev/null || true
            rm -f /etc/systemd/system/nvidia-power-settings.service
            echo -e "  ${GREEN}Removed nvidia-power-settings service${NC}"
        fi

        systemctl daemon-reload
        ;;
    5)
        # -----------------------------------------------------------------
        # Step 5: Remove ML utility scripts
        # -----------------------------------------------------------------
        echo -e "${BLUE}[Step 5]${NC} Removing ML utility scripts..."
        for f in /usr/local/bin/gpu-ml-setup.sh /usr/local/bin/gpu-ml-reset.sh /usr/local/bin/gpu-status.sh; do
            if [ -f "$f" ]; then
                rm -f "$f"
                echo -e "  ${GREEN}Removed $f${NC}"
                CHANGES=$((CHANGES+1))
            fi
        done
        ;;
    6)
        # -----------------------------------------------------------------
        # Step 6: Monitoring tools (nothing to rollback)
        # -----------------------------------------------------------------
        echo -e "${BLUE}[Step 6]${NC} Monitoring tools — no rollback needed"
        echo "  Packages (nvtop, etc.) are harmless to keep"
        ;;
    *)
        echo -e "${RED}Unknown step: ${STEP} (valid: 1-6)${NC}"
        ;;
    esac
    echo ""
done

if [ $CHANGES -gt 0 ]; then
    echo -e "${GREEN}================================================================${NC}"
    echo -e "${GREEN} Phase 3 rollback complete (${CHANGES} steps reverted)${NC}"
    echo -e "${GREEN}================================================================${NC}"
    echo ""
    echo "  Reboot to apply: sudo reboot"
    echo "  Then re-run:     sudo bash 03-configure-display.sh"
else
    echo "  No changes were made."
fi
