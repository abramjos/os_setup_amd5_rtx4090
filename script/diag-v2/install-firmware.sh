#!/bin/bash
###############################################################################
# install-firmware.sh — Install Raphael firmware blobs from USB to target
#
# Run this on the target machine after booting (recovery mode is fine).
# It finds firmware blobs on the USB, backs up stock firmware, installs
# the new blobs as .bin.zst, rebuilds initramfs, and verifies.
#
# USAGE:
#   sudo bash install-firmware.sh [--reboot]
#   --reboot: Automatically reboot after install (default: prompt)
#
# PREREQUISITES:
#   - Firmware blobs on USB at <mount>/UbuntuAutoInstall/firmware/amdgpu/*.bin
#   - Run prepare-firmware-usb.sh on the host Mac first if blobs are missing
###############################################################################

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; NC='\033[0m'

AUTO_REBOOT=false
[ "${1:-}" = "--reboot" ] && AUTO_REBOOT=true

# Log all output to file (tee to both console and log)
SCRIPT_LOG="/tmp/install-firmware-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$SCRIPT_LOG") 2>&1
echo "Logging to: $SCRIPT_LOG"

###############################################################################
# Root check
###############################################################################
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}ERROR: Must run as root (sudo).${NC}"
    exit 1
fi

###############################################################################
# Find firmware source (USB)
###############################################################################
echo -e "${BOLD}=== Raphael Firmware Installer ===${NC}"
echo ""

FW_SRC=""
USB_MOUNT=""

# Check if USB is already mounted somewhere
for candidate in \
    /cdrom/UbuntuAutoInstall \
    /media/cdrom/UbuntuAutoInstall \
    /mnt/usb/UbuntuAutoInstall \
    /media/*/UbuntuAutoInstall; do
    for p in $candidate; do
        if [ -d "$p/firmware/amdgpu" ] && ls "$p"/firmware/amdgpu/*.bin >/dev/null 2>&1; then
            FW_SRC="$p/firmware/amdgpu"
            break 2
        fi
    done
done

# If not found, try to mount USB
if [ -z "$FW_SRC" ]; then
    echo "Firmware not found at standard mount points. Searching for USB..."

    # Find USB block devices (not the boot disk)
    for dev in /dev/sd[a-z]1 /dev/sd[a-z]2; do
        [ -b "$dev" ] || continue

        USB_MOUNT="/mnt/usb-fw-$$"
        mkdir -p "$USB_MOUNT"

        if mount -o ro "$dev" "$USB_MOUNT" 2>/dev/null; then
            if [ -d "$USB_MOUNT/UbuntuAutoInstall/firmware/amdgpu" ] && \
               ls "$USB_MOUNT"/UbuntuAutoInstall/firmware/amdgpu/*.bin >/dev/null 2>&1; then
                FW_SRC="$USB_MOUNT/UbuntuAutoInstall/firmware/amdgpu"
                echo "  Found firmware on $dev"
                break
            fi
            umount "$USB_MOUNT" 2>/dev/null
        fi
        rmdir "$USB_MOUNT" 2>/dev/null || true
    done
fi

if [ -z "$FW_SRC" ]; then
    echo -e "${RED}ERROR: Cannot find firmware blobs on USB.${NC}"
    echo ""
    echo "Make sure the USB contains:"
    echo "  <USB>/UbuntuAutoInstall/firmware/amdgpu/*.bin"
    echo ""
    echo "To prepare: run prepare-firmware-usb.sh on the host Mac."
    exit 1
fi

echo -e "Source: ${GREEN}$FW_SRC${NC}"

BLOB_COUNT=$(ls "$FW_SRC"/*.bin 2>/dev/null | wc -l)
echo "Blobs found: $BLOB_COUNT"
echo ""

# Verify critical blob exists
if [ ! -f "$FW_SRC/dcn_3_1_5_dmcub.bin" ]; then
    echo -e "${RED}ERROR: dcn_3_1_5_dmcub.bin missing — this is the critical DMCUB blob.${NC}"
    exit 1
fi

###############################################################################
# Show current firmware version
###############################################################################
echo -e "${BOLD}--- Current Firmware ---${NC}"
CURRENT_DMCUB=$(ls -la /lib/firmware/amdgpu/dcn_3_1_5_dmcub.bin* 2>/dev/null || echo "  (not found)")
echo "$CURRENT_DMCUB"

DMUB_VER=$(dmesg 2>/dev/null | grep "Loading DMUB firmware" | head -1 | grep -oP 'version=0x[0-9a-fA-F]+' | sed 's/version=//' || echo "N/A")
echo "Running DMUB version: $DMUB_VER"
echo ""

###############################################################################
# Backup stock firmware
###############################################################################
echo -e "${BOLD}--- Backing Up Stock Firmware ---${NC}"
BACKUP_DIR="/var/log/ml-workstation-setup/firmware-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

BACKED=0
for blob in "$FW_SRC"/*.bin; do
    bname=$(basename "$blob")
    # Back up existing .bin.zst (stock) version
    if [ -f "/lib/firmware/amdgpu/${bname}.zst" ]; then
        cp "/lib/firmware/amdgpu/${bname}.zst" "$BACKUP_DIR/"
        BACKED=$((BACKED + 1))
    elif [ -f "/lib/firmware/amdgpu/${bname}" ]; then
        cp "/lib/firmware/amdgpu/${bname}" "$BACKUP_DIR/"
        BACKED=$((BACKED + 1))
    fi
done
echo "  Backed up $BACKED files to $BACKUP_DIR"
echo ""

###############################################################################
# Install firmware blobs
###############################################################################
echo -e "${BOLD}--- Installing Firmware ---${NC}"

INSTALLED=0
FAILED=0

for blob in "$FW_SRC"/*.bin; do
    [ -f "$blob" ] || continue
    bname=$(basename "$blob")

    # Copy bare .bin
    cp "$blob" "/lib/firmware/amdgpu/$bname"

    # Compress to .bin.zst (kernel preference) and remove bare .bin
    if zstd -f -q "/lib/firmware/amdgpu/$bname" -o "/lib/firmware/amdgpu/${bname}.zst"; then
        rm -f "/lib/firmware/amdgpu/$bname"
        echo -e "  ${GREEN}OK${NC}  $bname -> ${bname}.zst"
        INSTALLED=$((INSTALLED + 1))
    else
        echo -e "  ${YELLOW}WARN${NC}  zstd failed for $bname — left as bare .bin"
        INSTALLED=$((INSTALLED + 1))
    fi
done

if [ "$INSTALLED" -eq 0 ]; then
    echo -e "${RED}ERROR: No firmware blobs installed.${NC}"
    exit 1
fi

echo ""
echo "  Installed: $INSTALLED blobs"
echo ""

###############################################################################
# Verify no .bin/.bin.zst conflicts
###############################################################################
echo -e "${BOLD}--- Checking for Conflicts ---${NC}"
CONFLICTS=0
for f in /lib/firmware/amdgpu/dcn_3_1_5_dmcub psp_13_0_5_toc psp_13_0_5_ta psp_13_0_5_asd \
         gc_10_3_6_ce gc_10_3_6_me gc_10_3_6_mec gc_10_3_6_mec2 gc_10_3_6_pfp gc_10_3_6_rlc \
         sdma_5_2_6 vcn_3_1_2; do
    base=$(basename "$f")
    if [ -f "/lib/firmware/amdgpu/${base}.bin" ] && [ -f "/lib/firmware/amdgpu/${base}.bin.zst" ]; then
        echo -e "  ${RED}CONFLICT${NC}: ${base}.bin AND ${base}.bin.zst both exist"
        CONFLICTS=$((CONFLICTS + 1))
    fi
done

if [ "$CONFLICTS" -eq 0 ]; then
    echo -e "  ${GREEN}No conflicts${NC}"
else
    echo -e "  ${YELLOW}$CONFLICTS conflict(s) — kernel may load wrong version${NC}"
fi
echo ""

###############################################################################
# Show new DMCUB size (sanity check)
###############################################################################
echo -e "${BOLD}--- Installed DMCUB ---${NC}"
ls -la /lib/firmware/amdgpu/dcn_3_1_5_dmcub.bin*
echo ""

###############################################################################
# Ensure amdgpu is in /etc/initramfs-tools/modules
###############################################################################
echo -e "${BOLD}--- Ensuring amdgpu in initramfs modules ---${NC}"
if ! grep -q '^amdgpu' /etc/initramfs-tools/modules 2>/dev/null; then
    echo "amdgpu" >> /etc/initramfs-tools/modules
    echo "  Added amdgpu to /etc/initramfs-tools/modules"
else
    echo "  amdgpu already listed"
fi
echo ""

###############################################################################
# Create initramfs hook to force-copy Raphael firmware
#
# In recovery/nomodeset mode, amdgpu doesn't bind to hardware, so the
# default firmware hook skips amdgpu blobs. This custom hook ensures
# Raphael-specific firmware is ALWAYS included in the initramfs.
###############################################################################
echo -e "${BOLD}--- Creating initramfs firmware hook ---${NC}"

cat > /etc/initramfs-tools/hooks/amdgpu-firmware << 'HOOK'
#!/bin/sh
PREREQ=""
prereqs() { echo "$PREREQ"; }
case "$1" in prereqs) prereqs; exit 0 ;; esac

. /usr/share/initramfs-tools/hook-functions

# Validate DESTDIR is set by update-initramfs
if [ -z "${DESTDIR:-}" ]; then
    echo "amdgpu-firmware hook: ERROR - DESTDIR not set, cannot copy into initramfs" >&2
    exit 1
fi

echo "amdgpu-firmware hook: DESTDIR=$DESTDIR"

# On Ubuntu 24.04, /lib/firmware is a symlink to /usr/lib/firmware.
# Find where firmware actually lives on this host.
HOSTDIR=""
for candidate in /usr/lib/firmware/amdgpu /lib/firmware/amdgpu; do
    if [ -d "$candidate" ]; then
        HOSTDIR="$candidate"
        break
    fi
done

if [ -z "$HOSTDIR" ]; then
    echo "amdgpu-firmware hook: WARNING - no firmware dir found on host" >&2
    exit 0
fi

echo "amdgpu-firmware hook: source=$HOSTDIR"

# Determine where firmware should go inside initramfs.
# Check if the default firmware hook already created the symlink structure.
# If /lib/firmware is a symlink inside DESTDIR, copy to the resolved target.
# Otherwise, copy to both paths to cover all cases.
DESTDIRS=""
if [ -L "${DESTDIR}/lib/firmware" ]; then
    # Symlink exists inside initramfs — just copy to the real target
    REAL=$(readlink -f "${DESTDIR}/lib/firmware")/amdgpu
    mkdir -p "$REAL"
    DESTDIRS="$REAL"
    echo "amdgpu-firmware hook: initramfs has /lib/firmware symlink, target=$REAL"
else
    # No symlink — copy to both paths
    DESTDIRS="${DESTDIR}/lib/firmware/amdgpu ${DESTDIR}/usr/lib/firmware/amdgpu"
    echo "amdgpu-firmware hook: no symlink in initramfs, copying to both paths"
fi

# Force-copy Raphael (DCN 3.1.5 / GC 10.3.6 / PSP 13.0.5) firmware
COPIED=0
for blob in \
    dcn_3_1_5_dmcub \
    psp_13_0_5_toc psp_13_0_5_ta psp_13_0_5_asd \
    gc_10_3_6_ce gc_10_3_6_me gc_10_3_6_mec gc_10_3_6_mec2 gc_10_3_6_pfp gc_10_3_6_rlc \
    sdma_5_2_6 vcn_3_1_2; do
    FOUND=0
    for ext in .bin.zst .bin; do
        src="${HOSTDIR}/${blob}${ext}"
        if [ -f "$src" ]; then
            for dest in $DESTDIRS; do
                mkdir -p "$dest"
                cp "$src" "${dest}/${blob}${ext}"
            done
            COPIED=$((COPIED + 1))
            FOUND=1
            break  # prefer .zst, skip .bin if .zst found
        fi
    done
    if [ "$FOUND" -eq 0 ]; then
        echo "amdgpu-firmware hook: MISSING ${blob} (.bin.zst and .bin)" >&2
    fi
done
echo "amdgpu-firmware hook: copied $COPIED blobs"

# Verify the critical blob landed
for dest in $DESTDIRS; do
    if [ -f "${dest}/dcn_3_1_5_dmcub.bin.zst" ] || [ -f "${dest}/dcn_3_1_5_dmcub.bin" ]; then
        echo "amdgpu-firmware hook: VERIFIED dcn_3_1_5_dmcub in ${dest}"
    else
        echo "amdgpu-firmware hook: FAILED to copy dcn_3_1_5_dmcub to ${dest}" >&2
    fi
done
HOOK

chmod +x /etc/initramfs-tools/hooks/amdgpu-firmware
echo "  Created /etc/initramfs-tools/hooks/amdgpu-firmware"
echo ""

###############################################################################
# Rebuild initramfs
###############################################################################
echo -e "${BOLD}--- Rebuilding Initramfs ---${NC}"
echo "  This may take a minute..."
INITRAMFS_LOG="/tmp/initramfs-rebuild-$$.log"
# Suppress "W: initramfs-tools configuration sets RESUME" warning
export RESUME=none
update-initramfs -u -k all -v > "$INITRAMFS_LOG" 2>&1 || true
echo -e "  ${GREEN}Done${NC}"
echo ""

# Show hook output from the rebuild log
if grep -q "amdgpu-firmware hook" "$INITRAMFS_LOG"; then
    grep "amdgpu-firmware hook" "$INITRAMFS_LOG" | sed 's/^/  /'
else
    echo -e "  ${YELLOW}WARNING: amdgpu-firmware hook output not found in rebuild log${NC}"
    echo "  Checking if hook was invoked at all..."
    grep -i "amdgpu" "$INITRAMFS_LOG" | head -10 | sed 's/^/    /' || echo "    (no amdgpu references)"
fi
echo ""
echo "  Full rebuild log: $INITRAMFS_LOG"
echo ""

###############################################################################
# Verify DMCUB is in initramfs
###############################################################################
echo -e "${BOLD}--- Verifying Initramfs Contents ---${NC}"
LATEST_INITRD=$(ls -t /boot/initrd.img-* 2>/dev/null | head -1)
if [ -z "$LATEST_INITRD" ]; then
    echo -e "  ${YELLOW}Could not find initramfs to verify${NC}"
else
    echo "  Checking: $LATEST_INITRD"
    echo ""

    FOUND_FW=false

    # Method 1: unmkinitramfs --list (most reliable on Ubuntu 24.04)
    if command -v unmkinitramfs >/dev/null 2>&1; then
        echo "  Method: unmkinitramfs --list"
        EXTRACT_DIR="/tmp/initramfs-check-$$"
        mkdir -p "$EXTRACT_DIR"
        unmkinitramfs "$LATEST_INITRD" "$EXTRACT_DIR" 2>/dev/null || true
        # unmkinitramfs extracts to early/ + main/ subdirs
        FOUND_FILES=$(find "$EXTRACT_DIR" -name "dcn_3_1_5_dmcub*" 2>/dev/null || true)
        if [ -n "$FOUND_FILES" ]; then
            FOUND_FW=true
            echo -e "  ${GREEN}dcn_3_1_5_dmcub found in initramfs:${NC}"
            echo "$FOUND_FILES" | sed "s|${EXTRACT_DIR}|  (initramfs)|" | sed 's/^/    /'
        fi
        # Also show all amdgpu entries
        AMDGPU_FILES=$(find "$EXTRACT_DIR" -path "*/amdgpu/*" 2>/dev/null || true)
        if [ -n "$AMDGPU_FILES" ]; then
            AMDGPU_COUNT=$(echo "$AMDGPU_FILES" | wc -l)
            echo "  Total amdgpu firmware files in initramfs: $AMDGPU_COUNT"
        fi
        rm -rf "$EXTRACT_DIR"
    fi

    # Method 2: lsinitramfs fallback
    if [ "$FOUND_FW" = false ]; then
        echo "  Method: lsinitramfs"
        MATCHES=$(lsinitramfs "$LATEST_INITRD" 2>&1 | grep "dcn_3_1_5_dmcub" || true)
        if [ -n "$MATCHES" ]; then
            FOUND_FW=true
            echo -e "  ${GREEN}dcn_3_1_5_dmcub found in initramfs:${NC}"
            echo "$MATCHES" | sed 's/^/    /'
        fi
    fi

    # Method 3: raw cpio listing (last resort)
    if [ "$FOUND_FW" = false ]; then
        echo "  Method: raw cpio listing (zstd + gzip)"
        # Try zstd first (Ubuntu 24.04 default), then gzip
        for decomp in "zstd -d -c" "gzip -d -c"; do
            MATCHES=$($decomp "$LATEST_INITRD" 2>/dev/null | cpio -t 2>/dev/null | grep "dcn_3_1_5_dmcub" || true)
            if [ -n "$MATCHES" ]; then
                FOUND_FW=true
                echo -e "  ${GREEN}dcn_3_1_5_dmcub found in initramfs:${NC}"
                echo "$MATCHES" | sed 's/^/    /'
                break
            fi
        done
    fi

    if [ "$FOUND_FW" = false ]; then
        echo -e "  ${RED}dcn_3_1_5_dmcub NOT found in initramfs${NC}"
        echo ""
        echo "  --- Diagnostic dump ---"
        echo "  Hook file:"
        ls -la /etc/initramfs-tools/hooks/amdgpu-firmware 2>&1 | sed 's/^/    /'
        echo "  Firmware on disk:"
        ls -la /lib/firmware/amdgpu/dcn_3_1_5_dmcub.bin* 2>&1 | sed 's/^/    /'
        ls -la /usr/lib/firmware/amdgpu/dcn_3_1_5_dmcub.bin* 2>&1 | sed 's/^/    /'
        echo "  Symlink check:"
        ls -la /lib/firmware 2>&1 | sed 's/^/    /'
        echo "  Hook rebuild log (last 20 amdgpu lines):"
        grep -i "amdgpu" "$INITRAMFS_LOG" 2>/dev/null | tail -20 | sed 's/^/    /' || echo "    (none)"
    fi
fi
echo ""

###############################################################################
# Cleanup USB mount if we mounted it
###############################################################################
if [ -n "$USB_MOUNT" ] && mountpoint -q "$USB_MOUNT" 2>/dev/null; then
    umount "$USB_MOUNT" 2>/dev/null
    rmdir "$USB_MOUNT" 2>/dev/null || true
fi

###############################################################################
# Summary
###############################################################################
echo -e "${BOLD}================================================================${NC}"
echo -e "${BOLD}  FIRMWARE INSTALL COMPLETE${NC}"
echo -e "${BOLD}================================================================${NC}"
echo ""
echo "  Blobs installed: $INSTALLED"
echo "  Backup location: $BACKUP_DIR"
echo "  Conflicts:       $CONFLICTS"
echo ""
echo -e "  ${BOLD}Next: Reboot normally (NOT recovery mode) and verify:${NC}"
echo ""
echo "    sudo dmesg | grep 'Loading DMUB firmware'"
echo "    # Want version HIGHER than 0x05000F00"
echo ""
echo "    sudo dmesg | grep 'optc31_disable_crtc'"
echo "    # Want: no output"
echo ""
echo "    sudo dmesg | grep 'ring gfx.*timeout'"
echo "    # Want: no output"
echo ""
echo "    sudo /usr/local/bin/verify-boot.sh --variant B"
echo ""
echo "  Script log saved to: $SCRIPT_LOG"
echo "  Initramfs rebuild log: $INITRAMFS_LOG"
echo "  (Copy these to USB if you need to share them)"
echo ""

###############################################################################
# Reboot
###############################################################################
if [ "$AUTO_REBOOT" = true ]; then
    echo "Rebooting in 5 seconds..."
    sleep 5
    reboot
else
    echo -n "Reboot now? [y/N] "
    read -r answer
    if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
        reboot
    else
        echo "Reboot manually when ready: sudo reboot"
    fi
fi
