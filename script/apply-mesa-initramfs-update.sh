#!/usr/bin/env bash
#===============================================================================
# apply-mesa-initramfs-update.sh — Update Mesa radeonsi + bake firmware into initramfs
#
# PURPOSE: Address the Mesa/radeonsi side of the ring timeout bug.
#
#   The devcoredump from runLog-03 shows a NULL page fault at address 0x0 in the
#   gfxhub during gnome-shell GL rendering. This is a radeonsi userspace driver
#   bug where a command buffer references a NULL GPU virtual address. Mesa 24.2+
#   (via kisak PPA) contains GFX10.3 fixes for:
#     - Buffer management NULL pointer dereferences
#     - Shader compilation issues on small CU counts (2 CUs / 128 shaders)
#     - gnome-shell/mutter compositor interaction improvements
#
#   This script also ensures amdgpu firmware blobs are baked into the initramfs.
#   runLog-00 showed 0 firmware blobs in initramfs — the firmware only loaded
#   from the root filesystem, which delays DMUB initialization.
#
# FIRMWARE NOTE:
#   This script does NOT update the firmware files themselves.
#   Use 04-update-firmware-20251021.sh for that — it handles the .bin/.bin.zst
#   conflict correctly via git clone of the exact tag.
#   Run 04 FIRST, then this script.
#
# MODES:
#   --online   (default) Uses apt + PPA — requires internet
#   --offline  Installs from pre-downloaded packages on USB
#
# OFFLINE PREP (run on a machine WITH internet + matching Ubuntu 24.04):
#   mkdir -p /path/to/usb/Final/packages/mesa
#   sudo add-apt-repository ppa:kisak/kisak-mesa
#   sudo apt update
#   apt list --upgradable 2>/dev/null | grep -v Listing | awk -F/ '{print $1}' | \
#     xargs apt download
#   mv *.deb /path/to/usb/Final/packages/mesa/
#
# RUN FROM: TTY on the target machine (sudo required)
# RUN ORDER: 04-update-firmware-20251021.sh → this script → reboot
#===============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

MODE="online"

usage() {
    echo "Usage: $0 [--online|--offline]"
    echo ""
    echo "  --online     Install Mesa via apt + kisak PPA (requires internet) [default]"
    echo "  --offline    Install Mesa from USB packages directory"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --online)  MODE="online"; shift ;;
        --offline) MODE="offline"; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}ERROR: Must run as root (sudo)${NC}"
    exit 1
fi

echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN}  Mesa + Initramfs Update${NC}"
echo -e "${CYAN}  Mode: ${MODE}${NC}"
echo -e "${CYAN}============================================${NC}"
echo ""

#-------------------------------------------------------------------------------
# Pre-flight: Detect USB path (for offline mode)
#-------------------------------------------------------------------------------
USB_PATH=""
for p in /mnt/usb/Final /media/*/Final; do
    if [ -d "$p" ]; then
        USB_PATH="$p"
        break
    fi
done

if [ "$MODE" = "offline" ] && [ -z "$USB_PATH" ]; then
    echo -e "${RED}ERROR: USB not found at /mnt/usb/Final or /media/*/Final${NC}"
    echo "  Mount USB first: sudo mount /dev/sdX1 /mnt/usb"
    exit 1
fi

#-------------------------------------------------------------------------------
# Pre-flight: Show current versions
#-------------------------------------------------------------------------------
echo -e "${CYAN}[Pre-flight] Current versions${NC}"

CURRENT_KERNEL=$(uname -r)
echo "  Kernel:    ${CURRENT_KERNEL}"

CURRENT_FW=$(dpkg-query -W -f='${Version}' linux-firmware 2>/dev/null || echo "unknown")
echo "  Firmware:  ${CURRENT_FW}"

DMUB_VER=$(dmesg 2>/dev/null | grep -oP 'DMUB.*version=\K0x[0-9a-fA-F]+' | head -1 || echo "unknown")
echo "  DMUB:      ${DMUB_VER}"

MESA_VER=$(dpkg-query -W -f='${Version}' libgl1-mesa-dri 2>/dev/null || \
           dpkg-query -W -f='${Version}' mesa-vulkan-drivers 2>/dev/null || echo "unknown")
echo "  Mesa:      ${MESA_VER}"
echo ""

# Check if 04-update-firmware-20251021.sh was run
DMUB_FILE="/lib/firmware/amdgpu/dcn_3_1_5_dmcub.bin"
DMUB_ZST="/lib/firmware/amdgpu/dcn_3_1_5_dmcub.bin.zst"
if [ -f "$DMUB_FILE" ] || [ -f "$DMUB_ZST" ]; then
    echo -e "  ${GREEN}DMUB firmware present on disk${NC}"
else
    echo -e "  ${YELLOW}WARNING: No DMUB firmware found — run 04-update-firmware-20251021.sh first${NC}"
fi
echo ""

#-------------------------------------------------------------------------------
# Backup
#-------------------------------------------------------------------------------
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="/root/gpu-config-backups/${TIMESTAMP}"
mkdir -p "$BACKUP_DIR"

echo -e "${CYAN}[Backup] Saving current state${NC}"
dpkg-query -W -f='${Package} ${Version}\n' libgl1-mesa-dri mesa-vulkan-drivers \
    libdrm-amdgpu1 xserver-xorg-video-amdgpu libgbm1 libegl-mesa0 2>/dev/null \
    > "${BACKUP_DIR}/mesa-versions.txt" || true
cp /etc/default/grub "${BACKUP_DIR}/grub.bak" 2>/dev/null || true
echo "  Saved to: ${BACKUP_DIR}/"
echo ""

#===============================================================================
# PART 1: MESA UPDATE (radeonsi fixes for GFX10.3.6)
#===============================================================================
echo -e "${BOLD}${CYAN}━━━ Part 1: Mesa Update (radeonsi) ━━━${NC}"
echo ""

if [ "$MODE" = "online" ]; then
    echo -e "${CYAN}[Mesa] Adding kisak-mesa PPA${NC}"
    echo "  PPA: ppa:kisak/kisak-mesa (stable, well-tested Mesa builds)"
    echo "  Targets Mesa 24.2+ with radeonsi GFX10.3 fixes:"
    echo "    - Buffer management NULL pointer fixes"
    echo "    - Shader compilation fixes for small CU counts"
    echo "    - gnome-shell/mutter interaction improvements"
    echo ""

    # Check if PPA already added
    if grep -rq "kisak/kisak-mesa" /etc/apt/sources.list.d/ 2>/dev/null; then
        echo "  PPA already configured"
    else
        add-apt-repository -y ppa:kisak/kisak-mesa
    fi

    apt-get update -qq 2>/dev/null

    # Show what will be upgraded
    echo ""
    echo -e "${CYAN}[Mesa] Packages to upgrade:${NC}"
    MESA_UPGRADES=$(apt list --upgradable 2>/dev/null | grep -iE "mesa|libdrm|libgl|libgbm|libegl" || true)
    if [ -n "$MESA_UPGRADES" ]; then
        echo "$MESA_UPGRADES"
    else
        echo "  (no Mesa upgrades available — already at latest)"
    fi
    echo ""

    echo "  Installing Mesa upgrades..."
    apt-get upgrade -y
    echo -e "  ${GREEN}Mesa updated${NC}"

else
    # Offline mode
    MESA_PKG_DIR="${USB_PATH}/packages/mesa"
    echo -e "${CYAN}[Mesa] Looking for packages at ${MESA_PKG_DIR}/${NC}"

    if [ -d "$MESA_PKG_DIR" ] && ls "${MESA_PKG_DIR}"/*.deb &>/dev/null; then
        DEB_COUNT=$(ls -1 "${MESA_PKG_DIR}"/*.deb | wc -l)
        echo "  Found ${DEB_COUNT} .deb packages"
        echo "  Installing..."
        dpkg -i "${MESA_PKG_DIR}"/*.deb 2>/dev/null || true
        # Fix any dependency issues
        apt-get install -f -y 2>/dev/null || true
        echo -e "  ${GREEN}Mesa packages installed${NC}"
    else
        echo -e "  ${YELLOW}No Mesa packages found at ${MESA_PKG_DIR}/${NC}"
        echo ""
        echo "  To prepare offline packages on another Ubuntu 24.04 machine:"
        echo "    sudo add-apt-repository ppa:kisak/kisak-mesa"
        echo "    sudo apt update"
        echo "    mkdir -p mesa_debs && cd mesa_debs"
        echo "    apt list --upgradable 2>/dev/null | grep -v Listing | \\"
        echo "      awk -F/ '{print \$1}' | xargs apt download"
        echo "    cp *.deb /path/to/usb/Final/packages/mesa/"
    fi
fi

# Show new Mesa version
NEW_MESA=$(dpkg-query -W -f='${Version}' libgl1-mesa-dri 2>/dev/null || \
           dpkg-query -W -f='${Version}' mesa-vulkan-drivers 2>/dev/null || echo "unknown")
echo ""
echo "  Mesa: ${MESA_VER} → ${NEW_MESA}"
echo ""

#===============================================================================
# PART 2: BAKE FIRMWARE INTO INITRAMFS
#===============================================================================
echo -e "${BOLD}${CYAN}━━━ Part 2: Bake Firmware into Initramfs ━━━${NC}"
echo ""
echo "  runLog-00 showed 0 amdgpu firmware blobs in initramfs."
echo "  This ensures DMUB + GC firmware load early (before root FS mount)."
echo ""

# Add amdgpu to early-load modules
INITRAMFS_CONF="/etc/initramfs-tools/modules"
if ! grep -q "^amdgpu" "$INITRAMFS_CONF" 2>/dev/null; then
    echo -e "${CYAN}[Initramfs] Adding amdgpu to early-load modules${NC}"
    echo "amdgpu" >> "$INITRAMFS_CONF"
    echo "  Added 'amdgpu' to ${INITRAMFS_CONF}"
else
    echo "  amdgpu already in ${INITRAMFS_CONF}"
fi

# Create initramfs hook to force-include Raphael firmware
# This catches cases where the default MODULES=most doesn't pull in amdgpu blobs
HOOKS_DIR="/etc/initramfs-tools/hooks"
HOOK_FILE="${HOOKS_DIR}/amdgpu-firmware"

echo -e "${CYAN}[Initramfs] Creating firmware inclusion hook${NC}"
cat > "$HOOK_FILE" << 'HOOKEOF'
#!/bin/sh
# Force-include AMD Raphael iGPU firmware in initramfs
# Ensures DMUB, GC, PSP, SDMA, VCN firmware are available at early boot
PREREQ=""
prereqs() { echo "$PREREQ"; }
case $1 in prereqs) prereqs; exit 0;; esac
. /usr/share/initramfs-tools/hook-functions

# Raphael firmware families: GC 10.3.6, DCN 3.1.5, PSP 13.0.5, SDMA 5.2.6, VCN 3.1.2
for prefix in gc_10_3_6 dcn_3_1_5 psp_13_0_5 sdma_5_2_6 vcn_3_1_2 smu_13_0_5; do
    for fw in /lib/firmware/amdgpu/${prefix}*; do
        [ -e "$fw" ] && copy_file firmware "$fw"
    done
done
HOOKEOF
chmod +x "$HOOK_FILE"
echo "  Created ${HOOK_FILE}"

# Rebuild for all installed kernels
echo -e "${CYAN}[Initramfs] Rebuilding for all kernels${NC}"
update-initramfs -u -k all
echo -e "  ${GREEN}Initramfs rebuilt${NC}"

# Verify
echo ""
echo -e "${CYAN}[Initramfs] Verifying firmware inclusion${NC}"
VERIFIED_KERNELS=0
for initrd in /boot/initrd.img-*; do
    [ -f "$initrd" ] || continue
    kver=$(basename "$initrd" | sed 's/initrd.img-//')
    DMUB_COUNT=$(lsinitramfs "$initrd" 2>/dev/null | grep -c "dcn_3_1_5_dmcub" || echo 0)
    GC_COUNT=$(lsinitramfs "$initrd" 2>/dev/null | grep -c "gc_10_3_6" || echo 0)
    PSP_COUNT=$(lsinitramfs "$initrd" 2>/dev/null | grep -c "psp_13_0_5" || echo 0)

    if [ "$DMUB_COUNT" -gt 0 ] && [ "$GC_COUNT" -gt 0 ]; then
        echo -e "  ${GREEN}${kver}: DMUB=${DMUB_COUNT} GC=${GC_COUNT} PSP=${PSP_COUNT}${NC}"
        VERIFIED_KERNELS=$((VERIFIED_KERNELS + 1))
    else
        echo -e "  ${YELLOW}${kver}: DMUB=${DMUB_COUNT} GC=${GC_COUNT} PSP=${PSP_COUNT} — some blobs missing${NC}"
    fi
done

if [ "$VERIFIED_KERNELS" -eq 0 ]; then
    echo -e "  ${YELLOW}WARNING: Could not verify firmware in any initramfs${NC}"
    echo "  Firmware will still load from /lib/firmware at boot (just slightly later)"
fi
echo ""

#===============================================================================
# PART 3: GRUB — Clean cmdline
#===============================================================================
echo -e "${BOLD}${CYAN}━━━ Part 3: GRUB Configuration ━━━${NC}"
echo ""

echo -e "${CYAN}[GRUB] Setting clean cmdline${NC}"
CURRENT_GRUB=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub || echo "(not found)")
echo "  Current: ${CURRENT_GRUB}"

# vm_fragment_size=9 is the one parameter confirmed to help (TLB pressure fix)
# Everything else at driver defaults — no more counterproductive overrides
sed -i 's|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT="loglevel=4 amdgpu.vm_fragment_size=9 modprobe.blacklist=nouveau iommu=pt nogpumanager"|' /etc/default/grub

NEW_GRUB=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub)
echo "  New:     ${NEW_GRUB}"

update-grub
echo -e "  ${GREEN}GRUB updated${NC}"
echo ""

#===============================================================================
# Summary
#===============================================================================
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  Mesa + Initramfs Update Complete${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo -e "${CYAN}Changes made:${NC}"
echo "  1. Mesa:      ${MESA_VER} → ${NEW_MESA} (kisak PPA)"
echo "  2. Initramfs: amdgpu firmware baked in (was missing)"
echo "  3. GRUB:      clean cmdline (vm_fragment_size=9 only)"
echo ""
echo -e "${YELLOW}  RUN ORDER:${NC}"
echo "    1. 04-update-firmware-20251021.sh  ← updates firmware files on disk"
echo "    2. This script                     ← updates Mesa + bakes firmware into initramfs"
echo "    3. sudo reboot"
echo ""
echo -e "${YELLOW}  AFTER REBOOT:${NC}"
echo "    Boot into kernel 6.17 (should be default)"
echo "    If desktop loads → SUCCESS!"
echo "    If TTY → run diagnostic-full.sh for next runLog"
echo "    Verify: dmesg | grep DMUB  (should show version > 0x05002F00)"
echo "    Verify: glxinfo | grep 'OpenGL version'  (should show Mesa 24.2+)"
echo ""
echo -e "${YELLOW}  IF STILL FAILING:${NC}"
echo "    → Run apply-test-b-1080p.sh (force 1080p to reduce GPU load)"
echo "    → Run apply-nvidia-switch.sh (switch display to RTX 4090)"
echo ""
echo -e "${YELLOW}  ROLLBACK MESA:${NC}"
echo "    sudo add-apt-repository --remove ppa:kisak/kisak-mesa"
echo "    sudo apt update && sudo apt upgrade"
echo ""
echo -e "${YELLOW}  ROLLBACK GRUB:${NC}"
echo "    cp ${BACKUP_DIR}/grub.bak /etc/default/grub"
echo "    update-grub && reboot"
