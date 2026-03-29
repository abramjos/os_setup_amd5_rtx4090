#!/bin/bash
# =============================================================================
# 02-rollback.sh — Rollback Phase 2 (NVIDIA Driver) Changes
# =============================================================================
#
# Reverts changes made by 02-install-nvidia-driver.sh, step by step.
#
# USAGE:
#   sudo bash 02-rollback.sh           # Rollback ALL Phase 2 steps
#   sudo bash 02-rollback.sh 1 5 6     # Rollback only steps 1, 5, and 6
#   sudo bash 02-rollback.sh --list    # Show available steps
#
# After rollback: sudo reboot
# Then re-run:    sudo bash 02-install-nvidia-driver.sh
# =============================================================================

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

if [ "${1:-}" = "--list" ] || [ "${1:-}" = "-l" ]; then
    echo "Available rollback steps for Phase 2:"
    echo "  1  Nouveau blacklist         → remove /etc/modprobe.d/blacklist-nouveau.conf"
    echo "  2  NVIDIA packages           → purge all NVIDIA/CUDA packages"
    echo "  3  NVIDIA CUDA repository    → remove repo + keyring"
    echo "  4  NVIDIA driver             → (covered by step 2)"
    echo "  5  NVIDIA module options     → remove /etc/modprobe.d/nvidia.conf"
    echo "  6  Module load order         → remove /etc/modules-load.d/gpu.conf + initramfs entries"
    echo "  7  CUDA toolkit              → (covered by step 2)"
    echo ""
    echo "Usage: sudo bash 02-rollback.sh [step_numbers...]"
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
    STEPS=(1 2 3 5 6)
    echo -e "${YELLOW}Rolling back ALL Phase 2 steps...${NC}"
else
    STEPS=("$@")
    echo -e "${YELLOW}Rolling back Phase 2 steps: ${STEPS[*]}${NC}"
fi
echo ""

CHANGES=0

for STEP in "${STEPS[@]}"; do
    case "$STEP" in
    1)
        # -----------------------------------------------------------------
        # Step 1: Remove nouveau blacklist
        # -----------------------------------------------------------------
        echo -e "${BLUE}[Step 1]${NC} Removing nouveau blacklist..."
        if [ -f /etc/modprobe.d/blacklist-nouveau.conf ]; then
            rm -f /etc/modprobe.d/blacklist-nouveau.conf
            echo -e "  ${GREEN}Removed /etc/modprobe.d/blacklist-nouveau.conf${NC}"
            CHANGES=$((CHANGES+1))
        else
            echo "  Nothing to remove"
        fi
        ;;
    2|4|7)
        # -----------------------------------------------------------------
        # Steps 2/4/7: Purge NVIDIA + CUDA packages
        # -----------------------------------------------------------------
        echo -e "${BLUE}[Step $STEP]${NC} Purging NVIDIA and CUDA packages..."
        echo -e "  ${YELLOW}This will remove ALL NVIDIA drivers and CUDA toolkit${NC}"

        # Unpin driver version first
        apt-mark unhold nvidia-driver-595 cuda-drivers-595 2>/dev/null || true
        apt-mark unhold 'nvidia-*' 'cuda-*' 2>/dev/null || true

        apt purge -y 'nvidia-*' 'libnvidia-*' 'cuda-*' 'libcudnn*' 'libnccl*' 2>/dev/null || true
        apt autoremove -y 2>/dev/null || true
        echo -e "  ${GREEN}NVIDIA/CUDA packages purged${NC}"
        CHANGES=$((CHANGES+1))
        ;;
    3)
        # -----------------------------------------------------------------
        # Step 3: Remove NVIDIA CUDA repository
        # -----------------------------------------------------------------
        echo -e "${BLUE}[Step 3]${NC} Removing NVIDIA CUDA repository..."

        # Remove repo list file
        for f in /etc/apt/sources.list.d/cuda*.list; do
            if [ -f "$f" ]; then
                rm -f "$f"
                echo -e "  ${GREEN}Removed $f${NC}"
                CHANGES=$((CHANGES+1))
            fi
        done

        # Remove keyring
        if dpkg -l cuda-keyring 2>/dev/null | grep -q "^ii"; then
            apt purge -y cuda-keyring 2>/dev/null || true
            echo -e "  ${GREEN}Removed cuda-keyring${NC}"
        fi

        apt update -qq 2>/dev/null || true
        ;;
    5)
        # -----------------------------------------------------------------
        # Step 5: Remove NVIDIA module options
        # -----------------------------------------------------------------
        echo -e "${BLUE}[Step 5]${NC} Removing NVIDIA module options..."
        if [ -f /etc/modprobe.d/nvidia.conf ]; then
            rm -f /etc/modprobe.d/nvidia.conf
            echo -e "  ${GREEN}Removed /etc/modprobe.d/nvidia.conf${NC}"
            CHANGES=$((CHANGES+1))
        else
            echo "  Nothing to remove"
        fi
        ;;
    6)
        # -----------------------------------------------------------------
        # Step 6: Remove module load order + initramfs entries
        # -----------------------------------------------------------------
        echo -e "${BLUE}[Step 6]${NC} Removing module load order configuration..."

        # Remove modules-load.d
        if [ -f /etc/modules-load.d/gpu.conf ]; then
            rm -f /etc/modules-load.d/gpu.conf
            echo -e "  ${GREEN}Removed /etc/modules-load.d/gpu.conf${NC}"
            CHANGES=$((CHANGES+1))
        fi

        # Clean initramfs modules
        INITRAMFS="/etc/initramfs-tools/modules"
        if [ -f "$INITRAMFS" ]; then
            sed -i '/^# === GPU modules/,/^nvidia_drm$/d' "$INITRAMFS" 2>/dev/null || true
            sed -i '/^amdgpu$/d; /^nvidia$/d; /^nvidia_uvm$/d; /^nvidia_modeset$/d; /^nvidia_drm$/d' "$INITRAMFS" 2>/dev/null || true
            echo -e "  ${GREEN}Cleaned GPU entries from initramfs modules${NC}"
            CHANGES=$((CHANGES+1))
        fi
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
    echo -e "${GREEN} Phase 2 rollback complete (${CHANGES} steps reverted)${NC}"
    echo -e "${GREEN}================================================================${NC}"
    echo ""
    echo "  Reboot to apply: sudo reboot"
    echo "  Then re-run:     sudo bash 02-install-nvidia-driver.sh"
else
    echo "  No changes were made."
fi
