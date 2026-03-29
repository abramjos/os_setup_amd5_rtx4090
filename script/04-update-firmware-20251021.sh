#!/bin/bash
###############################################################################
# 04-update-firmware-20251021.sh
#
# PURPOSE: Update AMD Raphael iGPU firmware to linux-firmware tag 20251021.
#          This is the "sweet spot" firmware version — newer than the broken
#          20240318 package firmware, but avoids regressions in 20251111+.
#
# WHY THIS VERSION:
#   - linux-firmware 20240318 (from Ubuntu apt): ships with kernel 6.17 HWE
#     but contains old Raphael firmware that contributes to ring gfx_0.0.0
#     timeouts under GC 10.3.6 / DCN 3.1.5.
#   - linux-firmware 20251021: latest known-good for Raphael iGPU.
#     REF: https://gitlab.freedesktop.org/drm/amd/-/issues/4737
#     REF: https://gitlab.freedesktop.org/drm/amd/-/issues/4755
#   - linux-firmware 20251111 / 20251125: REGRESSION — breaks Raphael,
#     causes new ring timeouts and display failures. DO NOT USE.
#
# FIRMWARE FAMILIES FOR RAPHAEL (GC 10.3.6, DCN 3.1.5, PSP 13.0.5):
#   - gc_10_3_6_*   — Graphics Compute engine (CE, ME, MEC, MEC2, PFP, RLC)
#   - psp_13_0_5_*  — Platform Security Processor (TA, SOS, ASD, TOC)
#   - dcn_3_1_5_*   — Display Core Next (DMCUB)
#   - sdma_5_2_6_*  — System DMA engine
#   - vcn_3_1_2_*   — Video Core Next (encoder/decoder)
#
# CRITICAL: .bin vs .bin.zst CONFLICT
#   The kernel firmware loader prefers .bin.zst (zstd-compressed) over .bin
#   (uncompressed) when BOTH exist. Having both means the kernel loads the
#   .bin.zst (old apt version) and ignores your .bin (new manual version).
#   This script removes conflicting formats to ensure exactly ONE version
#   of each firmware file is loaded.
#
# WHAT THIS DOES:
#   1. Backs up current firmware (timestamped, never overwrites prior backups)
#   2. Clones linux-firmware at tag 20251021 (shallow, ~300MB)
#   3. Copies all Raphael firmware families
#   4. Resolves .bin/.bin.zst conflicts (keeps only the new version)
#   5. Rebuilds initramfs for all installed kernels
#   6. Verifies firmware files are in place
#
# SYSTEM: Ryzen 9 7950X | ASUS ROG Crosshair X670E Hero | RTX 4090
#         Ubuntu 24.04.1 LTS | Kernel 6.17 HWE (6.8 GA fallback)
#         AMD iGPU: Raphael (PCI 6c:00.0, device 0x164E)
#
# USAGE: sudo bash 04-update-firmware-20251021.sh
#
# REQUIRES: Root privileges, git, zstd (for optional compression)
# REBOOT:   Required after running this script
###############################################################################

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

# Configuration
FIRMWARE_DIR="/lib/firmware/amdgpu"
FIRMWARE_TAG="20251021"
CLONE_DIR="/tmp/linux-firmware-${FIRMWARE_TAG}"
BACKUP_DIR="${FIRMWARE_DIR}/backup-pre-fw-${FIRMWARE_TAG}-$(date +%Y%m%d-%H%M%S)"
LOG_FILE="/tmp/firmware-update-${FIRMWARE_TAG}-$(date +%Y%m%d-%H%M%S).log"

# All Raphael firmware file prefixes
# These are the IP block firmware blobs loaded by amdgpu for GC 10.3.6 / Raphael
RAPHAEL_PREFIXES=(
    "gc_10_3_6"     # Graphics Compute — CE, ME, MEC, MEC2, PFP, RLC
    "psp_13_0_5"    # Platform Security Processor — TA, SOS, ASD, TOC
    "dcn_3_1_5"     # Display Core Next — DMCUB firmware
    "sdma_5_2_6"    # System DMA engine
    "vcn_3_1_2"     # Video Core Next — encoder/decoder
)

# Ensure running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}ERROR: This script must be run as root (sudo).${NC}"
    exit 1
fi

echo -e "${BOLD}================================================================${NC}"
echo -e "${BOLD}  Firmware Update: linux-firmware ${FIRMWARE_TAG}${NC}"
echo -e "${BOLD}  AMD Raphael iGPU (GC 10.3.6 / DCN 3.1.5)${NC}"
echo -e "${BOLD}================================================================${NC}"
echo ""

# Start logging
exec > >(tee -a "$LOG_FILE") 2>&1
echo -e "${BLUE}[Log]${NC} Output saved to: ${LOG_FILE}"
echo ""

###############################################################################
# Step 0: Pre-flight checks
###############################################################################
echo -e "${BLUE}[Step 0/6]${NC} Pre-flight checks..."

# Check required tools
for cmd in git zstd; do
    if ! command -v "$cmd" &>/dev/null; then
        echo -e "${RED}ERROR: '${cmd}' is not installed. Install with: sudo apt install ${cmd}${NC}"
        exit 1
    fi
done
echo -e "  ${GREEN}Required tools: git, zstd${NC}"

# Verify firmware directory exists
if [ ! -d "$FIRMWARE_DIR" ]; then
    echo -e "${RED}ERROR: ${FIRMWARE_DIR} does not exist. Is amdgpu supported on this system?${NC}"
    exit 1
fi
echo -e "  ${GREEN}Firmware directory: ${FIRMWARE_DIR}${NC}"

# Show current firmware state
echo ""
echo -e "  Current Raphael firmware files:"
for prefix in "${RAPHAEL_PREFIXES[@]}"; do
    count=$(find "$FIRMWARE_DIR" -maxdepth 1 -name "${prefix}*" ! -type d 2>/dev/null | wc -l)
    echo -e "    ${prefix}: ${count} files"
done

# Detect .bin/.bin.zst conflicts
echo ""
CONFLICTS=0
for f in "${FIRMWARE_DIR}"/gc_10_3_6_*.bin; do
    [ -f "$f" ] || continue
    if [ -f "${f}.zst" ]; then
        echo -e "  ${YELLOW}CONFLICT: $(basename "$f") AND $(basename "$f").zst both exist${NC}"
        CONFLICTS=$((CONFLICTS + 1))
    fi
done
if [ "$CONFLICTS" -gt 0 ]; then
    echo -e "  ${YELLOW}${CONFLICTS} conflict(s) found — will be resolved in Step 4${NC}"
else
    echo -e "  ${GREEN}No .bin/.bin.zst conflicts detected${NC}"
fi
echo ""

###############################################################################
# Step 1: Back up existing firmware
###############################################################################
echo -e "${BLUE}[Step 1/6]${NC} Backing up current Raphael firmware..."

mkdir -p "$BACKUP_DIR"

BACKED_UP=0
for prefix in "${RAPHAEL_PREFIXES[@]}"; do
    for f in "${FIRMWARE_DIR}"/${prefix}*; do
        [ -f "$f" ] || [ -L "$f" ] || continue
        cp -a "$f" "$BACKUP_DIR/"
        BACKED_UP=$((BACKED_UP + 1))
    done
done

echo -e "  ${GREEN}Backed up ${BACKED_UP} files to:${NC}"
echo -e "  ${BACKUP_DIR}"
echo ""

###############################################################################
# Step 2: Clone linux-firmware at target tag
###############################################################################
echo -e "${BLUE}[Step 2/6]${NC} Cloning linux-firmware at tag ${FIRMWARE_TAG}..."

# Clean up any previous clone attempt
if [ -d "$CLONE_DIR" ]; then
    echo -e "  ${YELLOW}Removing previous clone at ${CLONE_DIR}${NC}"
    rm -rf "$CLONE_DIR"
fi

# Shallow clone at the exact tag — only fetches ~300MB instead of 2GB+
# Using --no-checkout + sparse-checkout to only materialize /amdgpu/
echo -e "  Cloning (sparse, depth=1)... this may take 1-3 minutes."
git clone --depth=1 --branch "${FIRMWARE_TAG}" --filter=blob:none --sparse \
    https://gitlab.com/kernel-firmware/linux-firmware.git "$CLONE_DIR" 2>&1 | tail -3

cd "$CLONE_DIR"
git sparse-checkout set amdgpu
echo -e "  ${GREEN}Clone complete: ${CLONE_DIR}${NC}"

# Verify the tag
TAG_HASH=$(git rev-parse HEAD)
echo -e "  Tag ${FIRMWARE_TAG} commit: ${TAG_HASH:0:12}"
echo ""

###############################################################################
# Step 3: Copy new Raphael firmware
###############################################################################
echo -e "${BLUE}[Step 3/6]${NC} Copying Raphael firmware from ${FIRMWARE_TAG}..."

COPIED=0
SKIPPED=0
SRC_DIR="${CLONE_DIR}/amdgpu"

for prefix in "${RAPHAEL_PREFIXES[@]}"; do
    # Find all firmware files for this prefix in the cloned repo
    for src_file in "${SRC_DIR}"/${prefix}*; do
        [ -f "$src_file" ] || [ -L "$src_file" ] || continue
        basename_f=$(basename "$src_file")

        # Copy file (preserving symlinks)
        cp -a "$src_file" "${FIRMWARE_DIR}/${basename_f}"
        echo -e "  ${GREEN}Copied:${NC} ${basename_f}"
        COPIED=$((COPIED + 1))
    done

    # Check if any files were found for this prefix
    found=$(find "$SRC_DIR" -maxdepth 1 -name "${prefix}*" ! -type d 2>/dev/null | wc -l)
    if [ "$found" -eq 0 ]; then
        echo -e "  ${YELLOW}WARN: No files found for prefix '${prefix}' in ${FIRMWARE_TAG}${NC}"
        SKIPPED=$((SKIPPED + 1))
    fi
done

echo ""
echo -e "  ${GREEN}Copied ${COPIED} files${NC}"
if [ "$SKIPPED" -gt 0 ]; then
    echo -e "  ${YELLOW}${SKIPPED} prefix(es) had no files in ${FIRMWARE_TAG} (may be normal)${NC}"
fi
echo ""

###############################################################################
# Step 4: Resolve .bin / .bin.zst conflicts
###############################################################################
echo -e "${BLUE}[Step 4/6]${NC} Resolving .bin / .bin.zst conflicts..."
echo -e "  Strategy: For each Raphael firmware file, keep only ONE format."
echo -e "  If the new ${FIRMWARE_TAG} repo provided .bin, compress it to .bin.zst"
echo -e "  and remove the old .bin.zst. If the repo provided .bin.zst, remove"
echo -e "  any stale .bin file."
echo ""

RESOLVED=0

for prefix in "${RAPHAEL_PREFIXES[@]}"; do
    for bin_file in "${FIRMWARE_DIR}"/${prefix}*.bin; do
        [ -f "$bin_file" ] || continue

        # Skip if this IS a .bin.zst file (glob *.bin also matches *.bin.zst? No, but be safe)
        case "$bin_file" in *.bin.zst) continue ;; esac

        zst_file="${bin_file}.zst"

        if [ -f "$zst_file" ]; then
            basename_bin=$(basename "$bin_file")
            basename_zst=$(basename "$zst_file")

            # Check which is newer (from our copy in Step 3)
            # The .bin we just copied is from 20251021; the .bin.zst is from apt (old)
            # Strategy: compress the new .bin to .bin.zst, remove both old files
            echo -e "  Compressing ${basename_bin} → ${basename_zst}"
            zstd -f -q --rm "$bin_file"
            # zstd --rm removes the source .bin after creating .bin.zst
            RESOLVED=$((RESOLVED + 1))
        fi
    done

    # Also handle: if repo gave us .bin but system expects .bin.zst (no conflict, just compress)
    # This is already handled above since we check for existence of .zst
done

# Handle symlinks: mec2 → mec symlinks need to match the format
for prefix in "${RAPHAEL_PREFIXES[@]}"; do
    # Check for mec2 → mec symlink pattern
    mec2_zst="${FIRMWARE_DIR}/${prefix}_mec2.bin.zst"
    mec_zst="${FIRMWARE_DIR}/${prefix}_mec.bin.zst"
    mec2_bin="${FIRMWARE_DIR}/${prefix}_mec2.bin"
    mec_bin="${FIRMWARE_DIR}/${prefix}_mec.bin"

    # If mec2 is a regular file but should be a symlink to mec (same content)
    if [ -f "$mec_zst" ] && [ -f "$mec2_bin" ] && [ ! -L "$mec2_bin" ]; then
        # The repo likely has mec2 as a symlink to mec — recreate it
        if [ -L "${SRC_DIR}/${prefix}_mec2.bin" ] || [ -L "${SRC_DIR}/${prefix}_mec2.bin.zst" ]; then
            rm -f "$mec2_bin" "$mec2_zst"
            ln -sf "${prefix}_mec.bin.zst" "$mec2_zst"
            echo -e "  ${GREEN}Fixed symlink: ${prefix}_mec2.bin.zst → ${prefix}_mec.bin.zst${NC}"
        fi
    fi

    # If mec2.bin.zst exists as a symlink but points to .bin instead of .bin.zst
    if [ -L "$mec2_zst" ]; then
        target=$(readlink "$mec2_zst")
        if [[ "$target" == *".bin" ]] && [[ "$target" != *".bin.zst" ]]; then
            rm -f "$mec2_zst"
            ln -sf "${prefix}_mec.bin.zst" "$mec2_zst"
            echo -e "  ${GREEN}Fixed symlink target: ${prefix}_mec2.bin.zst${NC}"
        fi
    fi
done

if [ "$RESOLVED" -gt 0 ]; then
    echo -e "  ${GREEN}Resolved ${RESOLVED} conflict(s) — compressed .bin → .bin.zst${NC}"
else
    echo -e "  ${GREEN}No conflicts to resolve${NC}"
fi
echo ""

###############################################################################
# Step 5: Rebuild initramfs
###############################################################################
echo -e "${BLUE}[Step 5/6]${NC} Rebuilding initramfs for all installed kernels..."
echo -e "  This embeds the new firmware into the boot image."
echo ""

# Find all installed kernels
KERNELS=$(ls /boot/vmlinuz-* 2>/dev/null | sed 's|/boot/vmlinuz-||' | sort -V)

for kernel in $KERNELS; do
    if [ -d "/lib/modules/${kernel}" ]; then
        echo -e "  Updating initramfs for ${kernel}..."
        update-initramfs -u -k "$kernel"
        echo -e "  ${GREEN}Done: ${kernel}${NC}"
    else
        echo -e "  ${YELLOW}Skipping ${kernel} (no modules directory)${NC}"
    fi
done
echo ""

###############################################################################
# Step 6: Verify
###############################################################################
echo -e "${BLUE}[Step 6/6]${NC} Verifying firmware installation..."
echo ""

ALL_OK=true

for prefix in "${RAPHAEL_PREFIXES[@]}"; do
    files=$(find "$FIRMWARE_DIR" -maxdepth 1 -name "${prefix}*" \( -type f -o -type l \) 2>/dev/null)
    count=$(echo "$files" | grep -c . 2>/dev/null || echo 0)

    if [ "$count" -eq 0 ]; then
        echo -e "  ${RED}MISSING: ${prefix} — no firmware files found!${NC}"
        ALL_OK=false
        continue
    fi

    echo -e "  ${GREEN}${prefix}:${NC} ${count} file(s)"

    # Check for remaining .bin/.bin.zst conflicts
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        case "$f" in *.bin.zst) continue ;; esac
        if [ -f "${f}.zst" ]; then
            echo -e "    ${RED}CONFLICT REMAINS: $(basename "$f") and $(basename "$f").zst${NC}"
            ALL_OK=false
        fi
    done <<< "$(find "$FIRMWARE_DIR" -maxdepth 1 -name "${prefix}*.bin" -type f 2>/dev/null)"

    # List files with timestamps
    while IFS= read -r f; do
        [ -f "$f" ] || [ -L "$f" ] || continue
        if [ -L "$f" ]; then
            target=$(readlink "$f")
            echo -e "    $(basename "$f") → ${target}"
        else
            mod_date=$(stat -c '%Y %y' "$f" 2>/dev/null | cut -d'.' -f1)
            size=$(stat -c '%s' "$f" 2>/dev/null)
            echo -e "    $(basename "$f")  (${size} bytes, ${mod_date})"
        fi
    done <<< "$files"
done

echo ""

# Verify initramfs contains the firmware
echo -e "  Checking initramfs contains updated firmware..."
CURRENT_KERNEL=$(uname -r 2>/dev/null || echo "unknown")
INITRD="/boot/initrd.img-${CURRENT_KERNEL}"

if [ -f "$INITRD" ]; then
    # Count Raphael firmware in initramfs
    FW_IN_INITRD=$(lsinitramfs "$INITRD" 2>/dev/null | grep -c "amdgpu/gc_10_3_6" || echo 0)
    if [ "$FW_IN_INITRD" -gt 0 ]; then
        echo -e "  ${GREEN}initramfs (${CURRENT_KERNEL}): ${FW_IN_INITRD} gc_10_3_6 files embedded${NC}"
    else
        echo -e "  ${YELLOW}WARN: No gc_10_3_6 files found in initramfs for ${CURRENT_KERNEL}${NC}"
        echo -e "  ${YELLOW}      The kernel may load firmware from /lib/firmware directly instead${NC}"
    fi
else
    echo -e "  ${YELLOW}Cannot verify initramfs (not running on target system)${NC}"
fi

echo ""

###############################################################################
# Cleanup
###############################################################################
echo -e "${BLUE}[Cleanup]${NC} Removing clone directory..."
rm -rf "$CLONE_DIR"
echo -e "  ${GREEN}Removed ${CLONE_DIR}${NC}"
echo ""

###############################################################################
# Summary
###############################################################################
echo -e "${BOLD}================================================================${NC}"
if [ "$ALL_OK" = true ]; then
    echo -e "${GREEN}${BOLD}  Firmware Update Complete!${NC}"
else
    echo -e "${YELLOW}${BOLD}  Firmware Update Complete (with warnings)${NC}"
fi
echo -e "${BOLD}================================================================${NC}"
echo ""
echo -e "  Tag:      linux-firmware ${FIRMWARE_TAG}"
echo -e "  Backup:   ${BACKUP_DIR}"
echo -e "  Log:      ${LOG_FILE}"
echo ""
echo -e "  Firmware families updated:"
for prefix in "${RAPHAEL_PREFIXES[@]}"; do
    echo -e "    - ${prefix}"
done
echo ""
echo -e "  ${BOLD}${YELLOW}REBOOT REQUIRED to load new firmware.${NC}"
echo ""
echo -e "  After reboot, verify firmware loaded correctly:"
echo -e "    dmesg | grep -i 'firmware\|amdgpu.*version'"
echo -e "    sudo dmesg | grep 'gc_10_3_6\|psp_13_0_5\|dcn_3_1_5'"
echo ""
echo -e "  To rollback if something breaks:"
echo -e "    sudo cp -a ${BACKUP_DIR}/* ${FIRMWARE_DIR}/"
echo -e "    sudo update-initramfs -u -k \$(uname -r)"
echo -e "    sudo reboot"
echo ""
