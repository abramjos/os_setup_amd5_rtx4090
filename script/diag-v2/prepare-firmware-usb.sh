#!/bin/bash
###############################################################################
# prepare-firmware-usb.sh — Download Raphael firmware blobs to USB
#
# Downloads individual firmware files via curl (not a full git clone).
# Places them on the USB drive for Variant B/C/D/E/F/G/H autoinstall.
#
# NOTE: This is OPTIONAL. Variant B+ autoinstall late-commands will
# download firmware directly during install if USB blobs are missing.
# Use this script to pre-stage firmware for offline/air-gapped installs.
#
# USAGE:
#   bash prepare-firmware-usb.sh [USB_MOUNT_PATH]
#   Default: auto-detect USB at /Volumes/Untitled or /media/*/Untitled
#
# OUTPUT:
#   <USB>/UbuntuAutoInstall/firmware/amdgpu/*.bin
###############################################################################

set -euo pipefail

FIRMWARE_TAG="20250509"

# Raw file URL from kernel.org git CGI
BASE_URL="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain"

# Raphael-specific firmware blobs (paths within the linux-firmware repo)
# IP blocks: DCN 3.1.5, PSP 13.0.5, GC 10.3.6, SDMA 5.2.6, VCN 3.1.2
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
    "amdgpu/sdma_5_2_6.bin"
    "amdgpu/vcn_3_1_2.bin"
)

# Detect USB mount
USB_PATH="${1:-}"
if [ -z "$USB_PATH" ]; then
    for candidate in \
        "/Volumes/Untitled/UbuntuAutoInstall" \
        "/mnt/usb/UbuntuAutoInstall" \
        "/media/*/UbuntuAutoInstall"; do
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

echo "=== Firmware Preparation for Variant B+ ==="
echo "Tag:         linux-firmware $FIRMWARE_TAG"
echo "Source:      $BASE_URL/amdgpu/...?h=$FIRMWARE_TAG"
echo "Destination: $DEST"
echo ""

COPIED=0
FAILED=0
for blob in "${BLOBS[@]}"; do
    bname=$(basename "$blob")
    url="${BASE_URL}/${blob}?h=${FIRMWARE_TAG}"
    echo -n "  $bname ... "

    if curl -sfL -o "$DEST/$bname" "$url"; then
        size=$(stat -f%z "$DEST/$bname" 2>/dev/null || stat -c%s "$DEST/$bname" 2>/dev/null || echo "?")
        sha=$(shasum -a 256 "$DEST/$bname" 2>/dev/null || sha256sum "$DEST/$bname" 2>/dev/null)
        sha=$(echo "$sha" | cut -d' ' -f1)
        echo "OK ($size bytes, sha256=${sha:0:16}...)"
        COPIED=$((COPIED + 1))
    else
        echo "FAILED"
        FAILED=$((FAILED + 1))
        rm -f "$DEST/$bname"
    fi
done

echo ""
if [ "$FAILED" -gt 0 ]; then
    echo "WARNING: $FAILED blob(s) failed to download."
    echo "Check your network connection and that tag '$FIRMWARE_TAG' is valid."
    echo ""
    echo "Available tags: git ls-remote --tags https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git | grep -oP '\\d{8}' | sort | tail -10"
fi

echo "=== Done: $COPIED/$((COPIED + FAILED)) firmware blobs downloaded to $DEST ==="
echo ""

if [ -f "$DEST/dcn_3_1_5_dmcub.bin" ]; then
    echo "Critical blob (DMCUB):"
    ls -la "$DEST/dcn_3_1_5_dmcub.bin"
else
    echo "ERROR: dcn_3_1_5_dmcub.bin missing — firmware update will not work!"
    exit 1
fi

echo ""
echo "Next: Boot with Variant B (or later) autoinstall."
echo "Late-commands will install these blobs automatically."
echo "(If USB blobs are missing, autoinstall will download them directly.)"
