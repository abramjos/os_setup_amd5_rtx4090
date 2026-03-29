#!/usr/bin/env bash
#===============================================================================
# apply-test-a.sh — Apply "Test A: Clean Slate" GRUB + modprobe parameters
#
# PURPOSE: Remove all counterproductive amdgpu parameters and test with
#          minimal known-good set + cg_mask=0 (disable clock gating).
#
# WHAT CHANGES:
#   1. /etc/modprobe.d/amdgpu.conf → stripped to gpu_recovery=1, audio=1, dc=1
#      (removes sg_display=0, ppfeaturemask — these are NOT helping)
#   2. /etc/default/grub → GRUB_CMDLINE_LINUX_DEFAULT set to clean slate
#   3. Rebuilds initramfs to include updated modprobe.d
#   4. Runs update-grub
#
# GRUB CMDLINE (Test A):
#   loglevel=4 amdgpu.vm_fragment_size=9 amdgpu.cg_mask=0
#   modprobe.blacklist=nouveau iommu=pt nogpumanager
#
# REMOVED (confirmed not helping or actively harmful):
#   amdgpu.sg_display=0       — unnecessary on UMA, wastes VRAM
#   amdgpu.ppfeaturemask=*    — GFXOFF disable made timeouts WORSE (3 → 9)
#   amdgpu.dcdebugmask=*      — PSR/stutter disable made timeouts WORSE
#   amdgpu.seamless=0         — forces buggy optc31_disable_crtc code path
#   amdgpu.noretry=0          — enables page fault retry that stalls GFX ring
#                                (AMD default for GC 10.3.x is noretry=1)
#   amdgpu.lockup_timeout=*   — masks timeouts, doesn't fix them
#   pcie_aspm=off             — irrelevant for on-die iGPU
#   processor.max_cstate=1    — unrelated to GPU ring
#
# ADDED:
#   amdgpu.cg_mask=0          — disables ALL clock gating; CG race conditions
#                                are a known ring timeout trigger, never tested
#
# RUN FROM: TTY on the target machine (sudo required)
# AFTER: Reboot, then run diagnostic-full.sh to collect runLog-01
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

echo -e "${CYAN}=== Test A: Clean Slate ===${NC}"
echo ""

#-------------------------------------------------------------------------------
# Step 1: Backup current configs
#-------------------------------------------------------------------------------
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="/root/gpu-config-backups/${TIMESTAMP}"
mkdir -p "$BACKUP_DIR"

echo -e "${CYAN}[1/4] Backing up current configs to ${BACKUP_DIR}${NC}"

cp /etc/modprobe.d/amdgpu.conf "${BACKUP_DIR}/amdgpu.conf.bak" 2>/dev/null || true
cp /etc/default/grub "${BACKUP_DIR}/grub.bak" 2>/dev/null || true

echo "  Backed up amdgpu.conf and grub"

#-------------------------------------------------------------------------------
# Step 2: Update modprobe.d/amdgpu.conf
#-------------------------------------------------------------------------------
echo -e "${CYAN}[2/4] Updating /etc/modprobe.d/amdgpu.conf${NC}"

cat > /etc/modprobe.d/amdgpu.conf << 'EOF'
# AMD iGPU (Raphael RDNA2 gfx1036) — Test A: Clean Slate
# Only essential params that don't interfere with driver defaults.
#
# REMOVED: sg_display=0, ppfeaturemask (GFXOFF/stutter disable made things WORSE)
# GRUB handles: vm_fragment_size=9, cg_mask=0
#
# gpu_recovery=1 — Enables automatic GPU hang recovery
# audio=1       — Enables HDMI/DP audio from motherboard outputs
# dc=1          — Explicitly enables Display Core subsystem
options amdgpu gpu_recovery=1
options amdgpu audio=1
options amdgpu dc=1
EOF

echo "  Written: gpu_recovery=1, audio=1, dc=1"
echo "  Removed: sg_display=0, ppfeaturemask"

#-------------------------------------------------------------------------------
# Step 3: Update GRUB cmdline
#-------------------------------------------------------------------------------
echo -e "${CYAN}[3/4] Updating /etc/default/grub${NC}"

# Show current value
CURRENT=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub || echo "(not found)")
echo "  Current: ${CURRENT}"

# Replace the GRUB_CMDLINE_LINUX_DEFAULT line
sed -i 's|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT="loglevel=4 amdgpu.vm_fragment_size=9 amdgpu.cg_mask=0 modprobe.blacklist=nouveau iommu=pt nogpumanager"|' /etc/default/grub

NEW=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub)
echo "  New:     ${NEW}"

#-------------------------------------------------------------------------------
# Step 4: Rebuild initramfs + update GRUB
#-------------------------------------------------------------------------------
echo -e "${CYAN}[4/4] Rebuilding initramfs and updating GRUB${NC}"

update-initramfs -u
update-grub

echo ""
echo -e "${GREEN}=== Test A applied successfully ===${NC}"
echo ""
echo "  GRUB cmdline: loglevel=4 amdgpu.vm_fragment_size=9 amdgpu.cg_mask=0"
echo "                modprobe.blacklist=nouveau iommu=pt nogpumanager"
echo ""
echo "  modprobe.d:   gpu_recovery=1, audio=1, dc=1"
echo ""
echo -e "${YELLOW}  NEXT STEPS:${NC}"
echo "    1. Reboot:  sudo reboot"
echo "    2. If graphical desktop loads → SUCCESS"
echo "    3. If TTY again → run diagnostic-full.sh to collect runLog-01"
echo "    4. Backups at: ${BACKUP_DIR}/"
echo ""
echo -e "${YELLOW}  ROLLBACK:${NC}"
echo "    cp ${BACKUP_DIR}/amdgpu.conf.bak /etc/modprobe.d/amdgpu.conf"
echo "    cp ${BACKUP_DIR}/grub.bak /etc/default/grub"
echo "    update-initramfs -u && update-grub && reboot"
