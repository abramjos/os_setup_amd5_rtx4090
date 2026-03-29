#!/bin/bash
# =============================================================================
# 99-rollback.sh — Emergency Rollback of All Configuration Changes
# =============================================================================
#
# PURPOSE:
#   Reverts ALL changes made by the setup scripts, restoring the system to
#   its pre-setup state. Use this if something went catastrophically wrong
#   and you need to start fresh.
#
# WHAT IT REVERTS:
#   1. GRUB configuration (restores backup)
#   2. modprobe.d files (removes nvidia.conf, amdgpu.conf, blacklist-nouveau.conf)
#   3. modules-load.d files (removes gpu.conf)
#   4. initramfs modules (removes GPU entries)
#   5. Xorg configuration (removes 10-gpu.conf)
#   6. GDM configuration (restores Wayland default)
#   7. udev rules (removes custom rules)
#   8. Systemd services (unmasks suspend, removes nvidia-power-settings)
#   9. Apt kernel pin preferences
#   10. Utility scripts (gpu-ml-setup.sh, gpu-ml-reset.sh, gpu-status.sh)
#   11. Environment files (/etc/profile.d/cuda-env.sh, /etc/environment entries)
#   12. Kernel pinning preferences
#   13. Rebuilds initramfs
#
# WHAT IT DOES NOT REVERT:
#   - NVIDIA driver installation (use 'apt purge nvidia-*' separately)
#   - CUDA toolkit installation (use 'apt purge cuda-*' separately)
#   - BIOS settings (must be changed manually)
#   - Kernel pinning (use 'apt-mark unhold' separately)
#
# CAUTION:
#   This script is aggressive. After running it and rebooting:
#   - Display may not work (no xorg.conf, no modprobe options)
#   - NVIDIA driver may not load (nouveau will load instead)
#   - You will need to re-run the entire setup from Step 2
#
# USAGE:
#   sudo bash scripts/99-rollback.sh
#   sudo reboot
#
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

echo ""
echo -e "${RED}================================================================${NC}"
echo -e "${RED} EMERGENCY ROLLBACK — Reverting ALL Setup Changes${NC}"
echo -e "${RED}================================================================${NC}"
echo ""

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}ERROR: This script must be run as root (sudo)${NC}"
    exit 1
fi

echo -e "${YELLOW}WARNING: This will revert all dual-GPU configuration changes.${NC}"
echo -e "${YELLOW}After rollback and reboot:${NC}"
echo -e "${YELLOW}  - Display may use default auto-configuration${NC}"
echo -e "${YELLOW}  - NVIDIA driver may not load properly${NC}"
echo -e "${YELLOW}  - You will need to re-run the entire setup${NC}"
echo ""
read -p "Are you sure? Type 'ROLLBACK' to confirm: " CONFIRM

if [ "$CONFIRM" != "ROLLBACK" ]; then
    echo "Rollback cancelled."
    exit 0
fi

echo ""

# ---------------------------------------------------------------------------
# 1. Restore GRUB
# ---------------------------------------------------------------------------
echo -e "${BLUE}1. Restoring GRUB configuration...${NC}"
if [ -f /etc/default/grub.bak.ml-setup ]; then
    cp /etc/default/grub.bak.ml-setup /etc/default/grub
    update-grub 2>/dev/null || true
    echo -e "  ${GREEN}Restored from backup${NC}"
else
    echo -e "  ${YELLOW}No backup found — GRUB unchanged${NC}"
fi

# ---------------------------------------------------------------------------
# 2. Remove modprobe.d files
# ---------------------------------------------------------------------------
echo -e "${BLUE}2. Removing modprobe.d configuration files...${NC}"
for f in /etc/modprobe.d/nvidia.conf /etc/modprobe.d/amdgpu.conf /etc/modprobe.d/blacklist-nouveau.conf; do
    if [ -f "$f" ]; then
        rm -f "$f"
        echo -e "  ${GREEN}Removed $f${NC}"
    fi
done

# ---------------------------------------------------------------------------
# 3. Remove modules-load.d files
# ---------------------------------------------------------------------------
echo -e "${BLUE}3. Removing modules-load.d configuration...${NC}"
if [ -f /etc/modules-load.d/gpu.conf ]; then
    rm -f /etc/modules-load.d/gpu.conf
    echo -e "  ${GREEN}Removed /etc/modules-load.d/gpu.conf${NC}"
fi

# ---------------------------------------------------------------------------
# 4. Clean initramfs modules
# ---------------------------------------------------------------------------
echo -e "${BLUE}4. Cleaning initramfs modules...${NC}"
INITRAMFS="/etc/initramfs-tools/modules"
if [ -f "$INITRAMFS" ]; then
    sed -i '/^# === GPU modules/,/^nvidia_drm$/d' "$INITRAMFS" 2>/dev/null || true
    sed -i '/^amdgpu$/d; /^nvidia$/d; /^nvidia_uvm$/d; /^nvidia_modeset$/d; /^nvidia_drm$/d' "$INITRAMFS" 2>/dev/null || true
    echo -e "  ${GREEN}Cleaned GPU entries from initramfs modules${NC}"
fi

# ---------------------------------------------------------------------------
# 5. Remove Xorg configuration
# ---------------------------------------------------------------------------
echo -e "${BLUE}5. Removing Xorg GPU configuration...${NC}"
if [ -f /etc/X11/xorg.conf.d/10-gpu.conf ]; then
    rm -f /etc/X11/xorg.conf.d/10-gpu.conf
    echo -e "  ${GREEN}Removed /etc/X11/xorg.conf.d/10-gpu.conf${NC}"
fi

# ---------------------------------------------------------------------------
# 6. Restore GDM configuration
# ---------------------------------------------------------------------------
echo -e "${BLUE}6. Restoring GDM configuration...${NC}"
if [ -f /etc/gdm3/custom.conf.bak.ml-setup ]; then
    cp /etc/gdm3/custom.conf.bak.ml-setup /etc/gdm3/custom.conf
    echo -e "  ${GREEN}Restored from backup${NC}"
else
    # Default: enable Wayland
    if [ -f /etc/gdm3/custom.conf ]; then
        sed -i 's/^WaylandEnable=false/WaylandEnable=true/' /etc/gdm3/custom.conf
        echo -e "  ${GREEN}Re-enabled Wayland in GDM${NC}"
    fi
fi

# ---------------------------------------------------------------------------
# 7. Remove udev rules
# ---------------------------------------------------------------------------
echo -e "${BLUE}7. Removing udev rules...${NC}"
for f in /etc/udev/rules.d/99-nvidia-compute.rules /etc/udev/rules.d/61-gdm-amd-primary.rules; do
    if [ -f "$f" ]; then
        rm -f "$f"
        echo -e "  ${GREEN}Removed $f${NC}"
    fi
done
udevadm control --reload-rules 2>/dev/null || true
udevadm trigger 2>/dev/null || true

# ---------------------------------------------------------------------------
# 8. Restore systemd services
# ---------------------------------------------------------------------------
echo -e "${BLUE}8. Restoring systemd services...${NC}"

# Unmask suspend targets
systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null || true
echo -e "  ${GREEN}Unmasked sleep/suspend/hibernate targets${NC}"

# Remove custom service
if [ -f /etc/systemd/system/nvidia-power-settings.service ]; then
    systemctl disable nvidia-power-settings 2>/dev/null || true
    rm -f /etc/systemd/system/nvidia-power-settings.service
    echo -e "  ${GREEN}Removed nvidia-power-settings service${NC}"
fi

# Unmask gpu-manager
systemctl unmask gpu-manager 2>/dev/null || true
systemctl enable gpu-manager 2>/dev/null || true
echo -e "  ${GREEN}Unmasked and enabled gpu-manager${NC}"

systemctl daemon-reload

# ---------------------------------------------------------------------------
# 8b. Restore power-profiles-daemon defaults
# ---------------------------------------------------------------------------
echo -e "${BLUE}8b. Restoring power-profiles-daemon defaults...${NC}"
if [ -d /etc/systemd/system/power-profiles-daemon.service.d ]; then
    rm -rf /etc/systemd/system/power-profiles-daemon.service.d
    systemctl daemon-reload
    echo -e "  ${GREEN}Removed power-profiles-daemon override${NC}"
fi
if command -v powerprofilesctl &>/dev/null; then
    powerprofilesctl set balanced 2>/dev/null || true
    echo -e "  ${GREEN}Reset to balanced profile${NC}"
fi

# ---------------------------------------------------------------------------
# 9. Revert kernel configuration
# ---------------------------------------------------------------------------
echo -e "${BLUE}9. Reverting kernel configuration...${NC}"

# Remove stale kernel pin if present (from older script versions)
if [ -f /etc/apt/preferences.d/pin-kernel-ga ]; then
    rm -f /etc/apt/preferences.d/pin-kernel-ga
    echo -e "  ${GREEN}Removed kernel pin preferences${NC}"
fi
apt-mark unhold linux-generic linux-image-generic linux-headers-generic 2>/dev/null || true

# Inform about HWE kernel (do NOT auto-remove — user may want to keep it)
if dpkg -l linux-generic-hwe-24.04 2>/dev/null | grep -q "^ii"; then
    echo -e "  ${YELLOW}HWE kernel (linux-generic-hwe-24.04) is still installed${NC}"
    echo "  To remove: sudo apt remove linux-generic-hwe-24.04"
    echo "  To keep (recommended): HWE provides security updates and hardware fixes"
fi
echo -e "  ${GREEN}Kernel configuration reverted${NC}"

# ---------------------------------------------------------------------------
# 10. Remove utility scripts
# ---------------------------------------------------------------------------
echo -e "${BLUE}10. Removing utility scripts...${NC}"
for f in /usr/local/bin/gpu-ml-setup.sh /usr/local/bin/gpu-ml-reset.sh /usr/local/bin/gpu-status.sh; do
    if [ -f "$f" ]; then
        rm -f "$f"
        echo -e "  ${GREEN}Removed $f${NC}"
    fi
done

# ---------------------------------------------------------------------------
# 11. Restore original iGPU firmware
# ---------------------------------------------------------------------------
echo -e "${BLUE}11. Restoring original iGPU firmware...${NC}"
FW_BACKUP="/lib/firmware/amdgpu/backup-pre-ml-setup"
if [ -d "$FW_BACKUP" ] && ls "$FW_BACKUP"/*.bin &>/dev/null; then
    RESTORED=0
    for fw in "$FW_BACKUP"/*.bin; do
        fname=$(basename "$fw")
        cp "$fw" "/lib/firmware/amdgpu/${fname}"
        RESTORED=$((RESTORED+1))
    done
    echo -e "  ${GREEN}Restored ${RESTORED} firmware files from ${FW_BACKUP}/${NC}"
    rm -rf "$FW_BACKUP"
else
    echo "  No firmware backup found — skipping"
fi

# ---------------------------------------------------------------------------
# 12. Clean environment files
# ---------------------------------------------------------------------------
echo -e "${BLUE}12. Cleaning environment files...${NC}"

# Remove CUDA environment profile
if [ -f /etc/profile.d/cuda-env.sh ]; then
    rm -f /etc/profile.d/cuda-env.sh
    echo -e "  ${GREEN}Removed /etc/profile.d/cuda-env.sh${NC}"
fi

# Clean ML Workstation entries from /etc/environment
if grep -q "ML Workstation" /etc/environment 2>/dev/null; then
    sed -i '/# === ML Workstation Dual-GPU Environment ===/,/^$/d' /etc/environment 2>/dev/null || true
    # Also remove individual entries in case the block delete missed them
    sed -i '/__GLX_VENDOR_LIBRARY_NAME/d' /etc/environment 2>/dev/null || true
    sed -i '/__GL_SYNC_TO_VBLANK/d' /etc/environment 2>/dev/null || true
    sed -i '/^DRI_PRIME/d' /etc/environment 2>/dev/null || true
    sed -i '/__NV_PRIME_RENDER_OFFLOAD/d' /etc/environment 2>/dev/null || true
    echo -e "  ${GREEN}Cleaned ML entries from /etc/environment${NC}"
fi

# ---------------------------------------------------------------------------
# 13. Rebuild initramfs
# ---------------------------------------------------------------------------
echo -e "${BLUE}13. Rebuilding initramfs...${NC}"
update-initramfs -u -k all 2>/dev/null || true
echo -e "  ${GREEN}initramfs rebuilt${NC}"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${GREEN}================================================================${NC}"
echo -e "${GREEN} Rollback Complete${NC}"
echo -e "${GREEN}================================================================${NC}"
echo ""
echo "  Changes reverted. Reboot to apply."
echo ""
echo "  NOT reverted (do manually if needed):"
echo "    - HWE kernel:    sudo apt remove linux-generic-hwe-24.04 (optional — safe to keep)"
echo "    - NVIDIA driver: sudo apt purge nvidia-* libnvidia-*"
echo "    - CUDA toolkit:  sudo apt purge cuda-toolkit-*"
echo "    - BIOS settings: Must be changed manually in BIOS"
echo ""
echo "  After reboot, the system will use default Ubuntu GPU auto-configuration."
echo ""
