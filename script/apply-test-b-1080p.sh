#!/usr/bin/env bash
#===============================================================================
# apply-test-b-1080p.sh — Force 1080p resolution to reduce iGPU load
#
# PURPOSE: Test whether reducing from 4K to 1080p avoids the NULL page fault
#          that causes ring timeouts. 4K compositing on 2 CUs is extreme.
#
# GRUB CMDLINE (Test B):
#   loglevel=4 amdgpu.vm_fragment_size=9 video=HDMI-A-1:1920x1080@60
#   modprobe.blacklist=nouveau iommu=pt nogpumanager
#
# RUN FROM: TTY on the target machine (sudo required)
#===============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}ERROR: Must run as root (sudo)${NC}"
    exit 1
fi

echo -e "${CYAN}=== Test B: Force 1080p Resolution ===${NC}"
echo ""

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="/root/gpu-config-backups/${TIMESTAMP}"
mkdir -p "$BACKUP_DIR"

echo -e "${CYAN}[1/3] Backing up configs${NC}"
cp /etc/default/grub "${BACKUP_DIR}/grub.bak" 2>/dev/null || true

echo -e "${CYAN}[2/3] Updating GRUB cmdline${NC}"
CURRENT=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub || echo "(not found)")
echo "  Current: ${CURRENT}"

sed -i 's|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT="loglevel=4 amdgpu.vm_fragment_size=9 video=HDMI-A-1:1920x1080@60 modprobe.blacklist=nouveau iommu=pt nogpumanager"|' /etc/default/grub

NEW=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub)
echo "  New:     ${NEW}"

echo -e "${CYAN}[3/3] Updating GRUB${NC}"
update-grub

echo ""
echo -e "${GREEN}=== Test B applied ===${NC}"
echo ""
echo "  Resolution forced to: 1920x1080@60 on HDMI-A-1"
echo "  Removed: cg_mask=0 (made 6.8 worse)"
echo ""
echo -e "${YELLOW}  NEXT: sudo reboot${NC}"
echo "  If desktop loads at 1080p → resolution is a factor"
echo "  If still crashes → proceed to install NVIDIA driver"
echo ""
echo -e "${YELLOW}  ROLLBACK:${NC}"
echo "    cp ${BACKUP_DIR}/grub.bak /etc/default/grub"
echo "    update-grub && reboot"
