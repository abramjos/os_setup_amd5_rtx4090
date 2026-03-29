#!/usr/bin/env bash
#===============================================================================
# apply-nvidia-switch.sh — Install NVIDIA driver and switch display to RTX 4090
#
# PURPOSE: Bypass the AMD iGPU entirely for display. The iGPU has a hardware/
#          firmware/Mesa bug causing NULL page faults in the GFX hub when
#          gnome-shell renders at 4K. No kernel parameter can fix this.
#
# PREREQUISITES:
#   - Run from TTY (Ctrl+Alt+F2) — not graphical desktop
#   - Internet connection (for apt install)
#   - Display cable ready to move to RTX 4090 HDMI/DP port
#
# WHAT THIS DOES:
#   1. Sets boot target to multi-user (TTY only, no GDM)
#   2. Installs NVIDIA driver
#   3. Cleans GRUB cmdline of all amdgpu workarounds
#   4. Prompts you to move display cable, then reboot
#   5. After reboot: re-enable graphical desktop
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

echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN}  NVIDIA Display Switch — RTX 4090${NC}"
echo -e "${CYAN}============================================${NC}"
echo ""

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="/root/gpu-config-backups/${TIMESTAMP}"
mkdir -p "$BACKUP_DIR"

#-------------------------------------------------------------------------------
# Step 1: Pre-flight checks
#-------------------------------------------------------------------------------
echo -e "${CYAN}[1/6] Pre-flight checks${NC}"

# Check NVIDIA hardware present
if ! lspci | grep -qi "nvidia"; then
    echo -e "${RED}ERROR: No NVIDIA GPU detected in lspci${NC}"
    exit 1
fi
echo "  NVIDIA GPU detected: $(lspci | grep -i nvidia | head -1)"

# Check internet (needed for apt)
if ping -c1 -W3 archive.ubuntu.com &>/dev/null; then
    echo "  Internet: OK"
    HAS_INTERNET=1
else
    echo -e "${YELLOW}  Internet: NOT AVAILABLE${NC}"
    echo -e "${YELLOW}  Will check for local .deb packages on USB${NC}"
    HAS_INTERNET=0
fi

# Check current boot target
CURRENT_TARGET=$(systemctl get-default)
echo "  Current boot target: ${CURRENT_TARGET}"

#-------------------------------------------------------------------------------
# Step 2: Backup configs
#-------------------------------------------------------------------------------
echo -e "${CYAN}[2/6] Backing up configs${NC}"
cp /etc/default/grub "${BACKUP_DIR}/grub.bak" 2>/dev/null || true
cp /etc/modprobe.d/amdgpu.conf "${BACKUP_DIR}/amdgpu.conf.bak" 2>/dev/null || true
systemctl get-default > "${BACKUP_DIR}/boot-target.bak"
echo "  Backups at: ${BACKUP_DIR}/"

#-------------------------------------------------------------------------------
# Step 3: Set multi-user target (skip GDM on next boot)
#-------------------------------------------------------------------------------
echo -e "${CYAN}[3/6] Setting boot target to multi-user (TTY only)${NC}"
systemctl set-default multi-user.target
echo "  Done — GDM will NOT start on next boot"

#-------------------------------------------------------------------------------
# Step 4: Install NVIDIA driver
#-------------------------------------------------------------------------------
echo -e "${CYAN}[4/6] Installing NVIDIA driver${NC}"

if [ "$HAS_INTERNET" -eq 1 ]; then
    # Check what's available
    echo "  Checking available NVIDIA drivers..."
    NVIDIA_PKG=$(apt-cache search '^nvidia-driver-[0-9]+$' 2>/dev/null | sort -t- -k3 -n | tail -1 | awk '{print $1}')

    if [ -z "$NVIDIA_PKG" ]; then
        echo -e "${YELLOW}  No nvidia-driver packages found in apt cache${NC}"
        echo "  Trying ubuntu-drivers..."
        apt-get update -qq
        NVIDIA_PKG=$(ubuntu-drivers devices 2>/dev/null | grep "recommended" | awk '{print $3}' || echo "")
    fi

    if [ -z "$NVIDIA_PKG" ]; then
        NVIDIA_PKG="nvidia-driver-565"
        echo -e "${YELLOW}  Falling back to: ${NVIDIA_PKG}${NC}"
    fi

    echo "  Installing: ${NVIDIA_PKG}"
    apt-get update -qq
    apt-get install -y "$NVIDIA_PKG"
else
    echo -e "${YELLOW}  No internet — looking for NVIDIA .deb on USB...${NC}"
    USB_PATH=""
    for p in /mnt/usb /media/*/Final; do
        if [ -d "$p" ]; then
            USB_PATH="$p"
            break
        fi
    done

    if [ -n "$USB_PATH" ] && ls "${USB_PATH}"/nvidia-driver*.deb &>/dev/null; then
        echo "  Found packages at ${USB_PATH}/"
        dpkg -i "${USB_PATH}"/nvidia-*.deb || apt-get install -f -y
    else
        echo -e "${RED}  ERROR: No NVIDIA packages found. Please either:${NC}"
        echo "    1. Connect to internet and re-run, OR"
        echo "    2. Download nvidia-driver-565 .deb and deps to USB"
        echo ""
        echo "  Boot target has been set to multi-user — you can safely reboot to TTY."
        exit 1
    fi
fi

# Verify installation
if command -v nvidia-smi &>/dev/null; then
    echo -e "  ${GREEN}NVIDIA driver installed successfully${NC}"
    nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null || true
else
    echo -e "${YELLOW}  nvidia-smi not found yet — will be available after reboot${NC}"
fi

#-------------------------------------------------------------------------------
# Step 5: Clean up GRUB cmdline
#-------------------------------------------------------------------------------
echo -e "${CYAN}[5/6] Cleaning GRUB cmdline${NC}"

# Minimal GRUB — no amdgpu workarounds needed when NVIDIA drives display
sed -i 's|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT="loglevel=4 modprobe.blacklist=nouveau iommu=pt"|' /etc/default/grub

# Wait — nouveau is already blacklisted and we're installing nvidia.
# The nvidia package handles nouveau blacklisting itself. But keeping it
# in GRUB is belt-and-suspenders and harmless.

update-grub
echo "  GRUB updated: removed all amdgpu.* workarounds"

#-------------------------------------------------------------------------------
# Step 6: Rebuild initramfs
#-------------------------------------------------------------------------------
echo -e "${CYAN}[6/6] Rebuilding initramfs${NC}"
update-initramfs -u
echo "  Done"

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  NVIDIA driver installed successfully${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo -e "${YELLOW}  BEFORE REBOOTING:${NC}"
echo "    1. Move display cable from MOTHERBOARD HDMI"
echo "       to RTX 4090 HDMI or DisplayPort"
echo ""
echo -e "${YELLOW}  THEN:${NC}"
echo "    sudo reboot"
echo ""
echo -e "${YELLOW}  AFTER REBOOT (you'll be at TTY):${NC}"
echo "    # Verify NVIDIA is working:"
echo "    nvidia-smi"
echo ""
echo "    # Re-enable graphical desktop:"
echo "    sudo systemctl set-default graphical.target"
echo "    sudo systemctl start gdm3"
echo ""
echo "    # If display works, make it permanent:"
echo "    # (it already is — graphical.target is set)"
echo ""
echo -e "${YELLOW}  OPTIONAL — Disable iGPU in BIOS:${NC}"
echo "    Advanced > AMD CBS > NBIO > GFX Configuration"
echo "    > Integrated Graphics Controller > Disabled"
echo ""
echo -e "${YELLOW}  ROLLBACK:${NC}"
echo "    cp ${BACKUP_DIR}/grub.bak /etc/default/grub"
echo "    cp ${BACKUP_DIR}/amdgpu.conf.bak /etc/modprobe.d/amdgpu.conf"
echo "    systemctl set-default $(cat ${BACKUP_DIR}/boot-target.bak)"
echo "    update-initramfs -u && update-grub && reboot"
