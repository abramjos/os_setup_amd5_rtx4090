#!/bin/bash
###############################################################################
# prepare-firmware-usb.sh — Download firmware blobs for USB-based install
#
# PURPOSE: Downloads the correct firmware blobs from linux-firmware git
#          and places them on the USB drive for Variant B/C autoinstall.
#
# RUN THIS ON ANY MACHINE WITH INTERNET ACCESS before booting the
# autoinstall USB. The firmware files will be picked up by late-commands.
#
# USAGE:
#   bash prepare-firmware-usb.sh [USB_MOUNT_PATH]
#   Default: auto-detect USB at /Volumes/Untitled or /media/*/Untitled
#
# OUTPUT:
#   <USB>/UbuntuAutoInstall/firmware/amdgpu/*.bin
###############################################################################

set -euo pipefail

FIRMWARE_TAG="20250305"  # Conservative: DMCUB 0.0.255.0 (last 0.0.x series)

# Raphael-specific firmware blobs
BLOBS=(
    "amdgpu/dcn_3_1_5_dmcub.bin"
    "amdgpu/psp_13_0_5_toc.bin"
    "amdgpu/psp_13_0_5_ta.bin"
    "amdgpu/psp_13_0_5_asd.bin"
    "amdgpu/gc_10_3_6_ce.bin"
    "amdgpu/gc_10_3_6_me.bin"
    "amdgpu/gc_10_3_6_mec.bin"
    "amdgpu/gc_10_3_6_mec2.bin"
    "amdgpu/gc_10_3_6_pfp.bin"
    "amdgpu/gc_10_3_6_rlc.bin"
)

# Detect USB mount
USB_PATH="${1:-}"
if [ -z "$USB_PATH" ]; then
    for candidate in \
        "/Volumes/Untitled/UbuntuAutoInstall" \
        "/mnt/usb/UbuntuAutoInstall" \
        "/media/*/UbuntuAutoInstall"; do
        # Handle glob
        for p in $candidate; do
            if [ -d "$p" ]; then
                USB_PATH="$p"
                break 2
            fi
        done
    done
fi

if [ -z "$USB_PATH" ] || [ ! -d "$USB_PATH" ]; then
    echo "ERROR: Cannot find USB mount. Provide path as argument."
    echo "Usage: $0 /path/to/UbuntuAutoInstall"
    exit 1
fi

DEST="$USB_PATH/firmware/amdgpu"
mkdir -p "$DEST"

echo "=== Firmware Preparation for Variant B/C ==="
echo "Tag: linux-firmware $FIRMWARE_TAG"
echo "Destination: $DEST"
echo ""

# Clone firmware repo (shallow, specific tag)
TMPDIR=$(mktemp -d)
echo "Downloading linux-firmware tag $FIRMWARE_TAG..."
git clone --depth 1 --branch "$FIRMWARE_TAG" \
    https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git \
    "$TMPDIR/linux-firmware" 2>&1 | tail -3

echo ""
echo "Copying firmware blobs..."
COPIED=0
for blob in "${BLOBS[@]}"; do
    src="$TMPDIR/linux-firmware/$blob"
    bname=$(basename "$blob")
    if [ -f "$src" ]; then
        cp "$src" "$DEST/$bname"
        size=$(stat -f%z "$src" 2>/dev/null || stat -c%s "$src" 2>/dev/null || echo "?")
        sha=$(sha256sum "$src" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$src" | cut -d' ' -f1)
        echo "  $bname ($size bytes, sha256=${sha:0:16}...)"
        COPIED=$((COPIED + 1))
    else
        echo "  WARNING: $bname not found in firmware repo"
    fi
done

# Also handle symlinks (mec2 -> mec)
if [ -L "$TMPDIR/linux-firmware/amdgpu/gc_10_3_6_mec2.bin" ]; then
    # Copy the target file as mec2
    target=$(readlink "$TMPDIR/linux-firmware/amdgpu/gc_10_3_6_mec2.bin")
    if [ -f "$TMPDIR/linux-firmware/amdgpu/$target" ]; then
        cp "$TMPDIR/linux-firmware/amdgpu/$target" "$DEST/gc_10_3_6_mec2.bin"
        echo "  gc_10_3_6_mec2.bin (symlink resolved from $target)"
    fi
fi

# Cleanup
rm -rf "$TMPDIR"

echo ""
echo "=== Done: $COPIED firmware blobs copied to $DEST ==="
echo ""
echo "Verify critical blob:"
ls -la "$DEST/dcn_3_1_5_dmcub.bin"
echo ""
echo "Now boot with Variant B or C autoinstall."
echo "The late-commands will find and install these firmware blobs."
