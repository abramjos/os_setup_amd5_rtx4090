#!/bin/bash
###############################################################################
# 07-fix-xorg-no-nvidia.sh
#
# PURPOSE: Fix X11 crash caused by xorg.conf referencing nvidia driver that
#          is not yet installed. Rewrites xorg.conf with AMD-only config.
#
# ROOT CAUSE:
#   Phase 3 (03-configure-display.sh) created an xorg.conf for dual-GPU
#   (AMD display + NVIDIA headless). But Phase 2 (NVIDIA driver install)
#   was never run. The xorg.conf references Driver "nvidia" which doesn't
#   exist → X11 fails with "Data incomplete" → "no screens found" → GDM
#   crash-loops → black screen.
#
#   From journal-boot-prev.txt:
#     Data incomplete in file /etc/X11/xorg.conf.d/10-gpu.conf
#     Fatal server error:
#     (EE) no screens found(EE)
#
# WHAT THIS DOES:
#   1. Backs up the broken xorg.conf
#   2. Writes an AMD-only xorg.conf (no nvidia references)
#   3. Optionally enables Wayland in GDM (doesn't need xorg.conf at all)
#   4. Verifies the fix
#
# AFTER NVIDIA DRIVER IS INSTALLED (Phase 2):
#   Re-run Phase 3 (03-configure-display.sh) with the BusID fix to
#   generate a proper dual-GPU xorg.conf. Or manually add the nvidia
#   Device/Screen sections back.
#
# RUN FROM: Ubuntu recovery mode root shell
# USAGE:    mount -o remount,rw / && bash /path/to/07-fix-xorg-no-nvidia.sh
# REBOOT:   Required after running
###############################################################################

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

LOG_FILE="/tmp/07-fix-xorg-no-nvidia-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "===== Fix Xorg Log Started: $(date) ====="

echo -e "${BOLD}================================================================${NC}"
echo -e "${BOLD}  Fix: Remove nvidia refs from xorg.conf${NC}"
echo -e "${BOLD}  (nvidia driver not installed yet)${NC}"
echo -e "${BOLD}================================================================${NC}"
echo ""

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}ERROR: Must run as root.${NC}"
    exit 1
fi

# Remount rw if needed
if mount | grep ' / ' | grep -q 'ro[,)]'; then
    mount -o remount,rw /
    echo -e "${GREEN}Remounted / as read-write${NC}"
fi

XORG_CONF="/etc/X11/xorg.conf.d/10-gpu.conf"
GDM_CONF="/etc/gdm3/custom.conf"

###############################################################################
# FIX 1: Rewrite xorg.conf — AMD iGPU only
###############################################################################
echo -e "${BLUE}[FIX 1/2]${NC} Rewriting xorg.conf with AMD-only config..."

if [ -f "$XORG_CONF" ]; then
    cp "$XORG_CONF" "${XORG_CONF}.bak.$(date +%Y%m%d%H%M%S)"
    echo -e "  Backed up existing config"
fi

# AMD iGPU PCI address: lspci 6c:00.0 = xorg PCI:108:0:0
cat > "$XORG_CONF" << 'XORGEOF'
# AMD iGPU Only Configuration
#
# NVIDIA sections removed — nvidia driver not installed yet.
# After installing NVIDIA driver (Phase 2), re-run Phase 3 to generate
# the full dual-GPU xorg.conf with correct BusIDs:
#   AMD iGPU:  PCI:108:0:0 (lspci 6c:00.0)
#   NVIDIA:    PCI:1:0:0   (lspci 01:00.0)

Section "Device"
    Identifier     "Device-amd"
    Driver         "amdgpu"
    BusID          "PCI:108:0:0"
    Option         "TearFree" "true"
    Option         "DRI" "3"
    Option         "AccelMethod" "glamor"
EndSection

Section "Screen"
    Identifier     "Screen-amd"
    Device         "Device-amd"
    DefaultDepth   24
    SubSection     "Display"
        Depth      24
    EndSubSection
EndSection
XORGEOF

echo -e "  ${GREEN}Wrote AMD-only xorg.conf${NC}"
echo -e "  Contents:"
cat "$XORG_CONF" | sed 's/^/    /'
echo ""

###############################################################################
# FIX 2: Enable Wayland as fallback
###############################################################################
echo -e "${BLUE}[FIX 2/2]${NC} Enabling Wayland in GDM as fallback..."

if [ -f "$GDM_CONF" ]; then
    cp "$GDM_CONF" "${GDM_CONF}.bak.$(date +%Y%m%d%H%M%S)"

    # Change WaylandEnable=false to WaylandEnable=true
    # Wayland doesn't use xorg.conf — it reads DRM/KMS directly.
    # If X11 still fails for some reason, GDM can fall back to Wayland.
    if grep -q 'WaylandEnable=false' "$GDM_CONF"; then
        sed -i 's/WaylandEnable=false/WaylandEnable=true/' "$GDM_CONF"
        echo -e "  ${GREEN}Changed WaylandEnable=false → true${NC}"
        echo -e "  GDM will try Wayland first, fall back to X11 if needed"
    else
        echo -e "  ${GREEN}WaylandEnable already not false${NC}"
    fi
else
    echo -e "  ${YELLOW}SKIP: ${GDM_CONF} not found${NC}"
fi
echo ""

###############################################################################
# Verify
###############################################################################
echo -e "${BLUE}[Verify]${NC} Checking configuration..."

# Check xorg.conf doesn't reference nvidia
if grep -q 'nvidia' "$XORG_CONF" 2>/dev/null; then
    echo -e "  ${RED}WARNING: xorg.conf still references nvidia!${NC}"
else
    echo -e "  ${GREEN}xorg.conf: no nvidia references${NC}"
fi

# Check AMD BusID
if grep -q 'PCI:108:0:0' "$XORG_CONF" 2>/dev/null; then
    echo -e "  ${GREEN}AMD BusID: PCI:108:0:0 (correct)${NC}"
else
    echo -e "  ${RED}WARNING: AMD BusID not found in xorg.conf${NC}"
fi

# Check GDM Wayland
if grep -q 'WaylandEnable=true' "$GDM_CONF" 2>/dev/null; then
    echo -e "  ${GREEN}GDM: Wayland enabled${NC}"
fi

# Check amdgpu DDX is available
if [ -f /usr/lib/xorg/modules/drivers/amdgpu_drv.so ]; then
    echo -e "  ${GREEN}amdgpu DDX driver: installed${NC}"
elif [ -f /usr/lib/x86_64-linux-gnu/xorg/modules/drivers/amdgpu_drv.so ]; then
    echo -e "  ${GREEN}amdgpu DDX driver: installed${NC}"
else
    echo -e "  ${YELLOW}WARN: amdgpu DDX not found — X11 will use modesetting driver (still works)${NC}"
fi

echo ""
echo -e "${BOLD}================================================================${NC}"
echo -e "${GREEN}${BOLD}  Fix Applied${NC}"
echo -e "${BOLD}================================================================${NC}"
echo ""
echo -e "  Log: ${LOG_FILE}"
echo ""
echo -e "  ${BOLD}Changes:${NC}"
echo -e "    [1] xorg.conf: stripped nvidia sections (AMD-only)"
echo -e "    [2] GDM: Wayland enabled (X11 still available as fallback)"
echo ""
echo -e "  ${BOLD}${YELLOW}REBOOT NOW:${NC}  reboot"
echo ""
echo -e "  ${BOLD}After reboot:${NC}"
echo -e "    You should see the GNOME login screen."
echo -e "    If using Wayland: echo \$XDG_SESSION_TYPE → wayland"
echo -e "    If using X11:     echo \$XDG_SESSION_TYPE → x11"
echo ""
echo -e "  ${BOLD}Next steps after display works:${NC}"
echo -e "    1. Install NVIDIA driver (Phase 2: 02-install-nvidia-driver.sh)"
echo -e "    2. Re-run Phase 3 to create dual-GPU xorg.conf"
echo ""
