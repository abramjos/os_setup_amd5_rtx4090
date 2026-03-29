#!/bin/bash
###############################################################################
# 05-multiboot-amdgpu-diag.sh
#
# PURPOSE: Collect and compare AMD Raphael iGPU behavior across multiple boots.
#          Extracts per-boot GRUB cmdline, ring timeout events, GPU resets,
#          GDM session status, and generates a side-by-side comparison table
#          so you can see exactly which GRUB parameters helped/hurt.
#
# WHY THIS EXISTS:
#   We're systematically testing GRUB parameters (vm_fragment_size, seamless,
#   dcdebugmask, noretry, lockup_timeout, etc.) to resolve persistent
#   "ring gfx_0.0.0 timeout" on the Raphael iGPU (GC 10.3.6, DCN 3.1.5).
#   Each reboot uses different parameters. This script gathers the evidence
#   from ALL available boots in one pass for comparison.
#
# DATA COLLECTED PER BOOT:
#   - Boot ID, timestamp, kernel version
#   - Full kernel cmdline (GRUB parameters)
#   - Extracted amdgpu.* parameters
#   - Ring timeout count, timestamps, triggering processes
#   - REG_WAIT timeout (optc31_disable_crtc) occurrences
#   - GPU reset attempts: count, type (ring/MODE2), success/fail
#   - GDM session status (registered / failed / crash-looped)
#   - Parser errors (-125)
#   - Time from boot to first ring timeout (seconds)
#   - Firmware version loaded (DMUB, VCN)
#   - vm_fragment_size / block_size from amdgpu init
#   - Overall stability verdict
#
# OUTPUT:
#   - Per-boot detailed log files in OUTPUT_DIR/boot-<N>/
#   - Summary comparison table: OUTPUT_DIR/COMPARISON.txt
#   - Raw data CSV: OUTPUT_DIR/comparison.csv (for spreadsheet import)
#   - Full archive: OUTPUT_DIR.tar.gz
#
# USAGE: sudo bash 05-multiboot-amdgpu-diag.sh [max_boots]
#        max_boots: how many recent boots to analyze (default: 10)
#
# REQUIRES: Root privileges (for journalctl access to previous boots)
###############################################################################

set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# Configuration
MAX_BOOTS="${1:-10}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT_DIR="/tmp/amdgpu-multiboot-diag-${TIMESTAMP}"

# Ensure running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}ERROR: This script must be run as root (sudo) to access previous boot logs.${NC}"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo -e "${BOLD}================================================================${NC}"
echo -e "${BOLD}  Multi-Boot AMD iGPU Diagnostic Comparison${NC}"
echo -e "${BOLD}  Analyzing up to ${MAX_BOOTS} recent boots${NC}"
echo -e "${BOLD}================================================================${NC}"
echo ""

###############################################################################
# Step 1: Enumerate available boots
###############################################################################
echo -e "${BLUE}[Step 1]${NC} Enumerating available boots..."

# journalctl --list-boots gives: OFFSET BOOT_ID FIRST_ENTRY LAST_ENTRY
BOOT_LIST=$(journalctl --list-boots --no-pager 2>/dev/null || true)

if [ -z "$BOOT_LIST" ]; then
    echo -e "${RED}ERROR: No boot entries found in journal. Is persistent logging enabled?${NC}"
    echo -e "${YELLOW}  Fix: sudo mkdir -p /var/log/journal && sudo systemd-tmpfiles --create --prefix /var/log/journal${NC}"
    echo -e "${YELLOW}  Then reboot and re-run this script.${NC}"
    exit 1
fi

TOTAL_BOOTS=$(echo "$BOOT_LIST" | wc -l)
ANALYZE_COUNT=$((TOTAL_BOOTS < MAX_BOOTS ? TOTAL_BOOTS : MAX_BOOTS))

echo -e "  ${GREEN}${TOTAL_BOOTS} boot(s) available in journal, analyzing ${ANALYZE_COUNT}${NC}"
echo "$BOOT_LIST" > "${OUTPUT_DIR}/boot-list.txt"
echo ""

###############################################################################
# Step 2: Collect per-boot data
###############################################################################
echo -e "${BLUE}[Step 2]${NC} Collecting per-boot diagnostic data..."
echo ""

# CSV header
CSV_FILE="${OUTPUT_DIR}/comparison.csv"
echo "boot_offset,boot_id,boot_time,kernel,cmdline_amdgpu,vm_fragment_size,seamless,dcdebugmask,ppfeaturemask,noretry,lockup_timeout,sg_display,runpm,pcie_aspm,iommu,max_cstate,nouveau_blacklisted,optc31_timeout_count,ring_timeout_count,first_timeout_sec,ring_reset_fail_count,mode2_reset_count,gpu_reset_success_count,parser_error_count,gdm_status,dmub_version,vcn_version,block_size,fragment_size,verdict" > "$CSV_FILE"

# Process each boot (most recent first, which is the bottom of --list-boots)
BOOT_OFFSETS=$(echo "$BOOT_LIST" | tail -n "$ANALYZE_COUNT" | awk '{print $1}')

BOOT_NUM=0
for OFFSET in $BOOT_OFFSETS; do
    BOOT_NUM=$((BOOT_NUM + 1))
    BOOT_ID=$(echo "$BOOT_LIST" | awk -v off="$OFFSET" '$1 == off {print $2}')
    BOOT_TIME=$(echo "$BOOT_LIST" | awk -v off="$OFFSET" '$1 == off {for(i=3;i<=NF;i++) printf "%s ", $i; print ""}')

    BOOT_DIR="${OUTPUT_DIR}/boot-${OFFSET}"
    mkdir -p "$BOOT_DIR"

    echo -e "  ${CYAN}[Boot ${BOOT_NUM}/${ANALYZE_COUNT}]${NC} offset=${OFFSET}  id=${BOOT_ID:0:12}...  ${BOOT_TIME}"

    #---------------------------------------------------------------------------
    # Collect raw logs for this boot
    #---------------------------------------------------------------------------

    # Full dmesg-equivalent from journal (kernel messages only)
    journalctl --boot="$OFFSET" -k --no-pager 2>/dev/null > "${BOOT_DIR}/dmesg-full.txt" || true

    # amdgpu-specific messages
    journalctl --boot="$OFFSET" -k --no-pager 2>/dev/null | grep -iE "amdgpu|drm.*amd|\[drm\]" > "${BOOT_DIR}/dmesg-amdgpu.txt" || true

    # Ring timeout and GPU reset messages
    journalctl --boot="$OFFSET" -k --no-pager 2>/dev/null | grep -iE "ring.*timeout|ring.*reset|GPU reset|MODE2|REG_WAIT|optc31|parser.*-125|coredump|wedged|gfx_0" > "${BOOT_DIR}/dmesg-ring-events.txt" || true

    # GDM journal
    journalctl --boot="$OFFSET" -u gdm3 --no-pager 2>/dev/null > "${BOOT_DIR}/gdm-journal.txt" || true
    journalctl --boot="$OFFSET" -u gdm --no-pager 2>/dev/null >> "${BOOT_DIR}/gdm-journal.txt" || true

    # Kernel cmdline (from dmesg "Command line:" or "Kernel command line:")
    journalctl --boot="$OFFSET" -k --no-pager 2>/dev/null | grep -m1 "Kernel command line:" > "${BOOT_DIR}/cmdline.txt" || true

    # All errors and warnings
    journalctl --boot="$OFFSET" -k -p warning --no-pager 2>/dev/null > "${BOOT_DIR}/dmesg-warnings.txt" || true

    # Module load messages
    journalctl --boot="$OFFSET" -k --no-pager 2>/dev/null | grep -iE "amdgpu.*parameter|amdgpu.*unknown|amdgpu.*ignored|modprobe|module" > "${BOOT_DIR}/module-load.txt" || true

    # nouveau messages (if present, indicates nouveau wasn't blacklisted)
    journalctl --boot="$OFFSET" -k --no-pager 2>/dev/null | grep -i "nouveau" > "${BOOT_DIR}/dmesg-nouveau.txt" || true

    #---------------------------------------------------------------------------
    # Extract structured data
    #---------------------------------------------------------------------------
    DMESG_AMDGPU="${BOOT_DIR}/dmesg-amdgpu.txt"
    RING_EVENTS="${BOOT_DIR}/dmesg-ring-events.txt"
    CMDLINE_FILE="${BOOT_DIR}/cmdline.txt"
    GDM_LOG="${BOOT_DIR}/gdm-journal.txt"

    # Kernel version
    KERNEL=$(journalctl --boot="$OFFSET" -k --no-pager 2>/dev/null | grep -m1 "Linux version" | sed -E 's/.*Linux version ([^ ]+).*/\1/' || echo "unknown")

    # Full cmdline
    FULL_CMDLINE=$(cat "$CMDLINE_FILE" 2>/dev/null | sed -E 's/.*Kernel command line: //' || echo "N/A")

    # Extract individual amdgpu parameters
    extract_param() {
        local param="$1"
        local default="$2"
        echo "$FULL_CMDLINE" | grep -oP "amdgpu\.${param}=\K[^ ]+" 2>/dev/null || echo "$default"
    }

    PARAM_VM_FRAGMENT=$(extract_param "vm_fragment_size" "default")
    PARAM_SEAMLESS=$(extract_param "seamless" "default")
    PARAM_DCDEBUGMASK=$(extract_param "dcdebugmask" "default")
    PARAM_PPFEATUREMASK=$(extract_param "ppfeaturemask" "default")
    PARAM_NORETRY=$(extract_param "noretry" "default")
    PARAM_LOCKUP_TIMEOUT=$(extract_param "lockup_timeout" "default")
    PARAM_SG_DISPLAY=$(extract_param "sg_display" "default")
    PARAM_RUNPM=$(extract_param "runpm" "default")

    # Non-amdgpu params
    PARAM_PCIE_ASPM="default"
    echo "$FULL_CMDLINE" | grep -q "pcie_aspm=off" && PARAM_PCIE_ASPM="off"

    PARAM_IOMMU="default"
    echo "$FULL_CMDLINE" | grep -oP "iommu=\K[^ ]+" 2>/dev/null && PARAM_IOMMU=$(echo "$FULL_CMDLINE" | grep -oP "iommu=\K[^ ]+" 2>/dev/null) || true

    PARAM_MAX_CSTATE="default"
    echo "$FULL_CMDLINE" | grep -oP "processor\.max_cstate=\K[^ ]+" 2>/dev/null && PARAM_MAX_CSTATE=$(echo "$FULL_CMDLINE" | grep -oP "processor\.max_cstate=\K[^ ]+" 2>/dev/null) || true

    NOUVEAU_BLACKLISTED="no"
    echo "$FULL_CMDLINE" | grep -q "modprobe.blacklist=nouveau" && NOUVEAU_BLACKLISTED="yes"

    # Collect all amdgpu.* params for display
    CMDLINE_AMDGPU=$(echo "$FULL_CMDLINE" | grep -oP 'amdgpu\.\S+' 2>/dev/null | tr '\n' ' ' || echo "none")

    # optc31_disable_crtc REG_WAIT timeout count
    OPTC31_COUNT=$(grep -c "optc31_disable_crtc" "$RING_EVENTS" 2>/dev/null || echo 0)

    # Ring timeout count
    RING_TIMEOUT_COUNT=$(grep -c "ring gfx_0.0.0 timeout" "$RING_EVENTS" 2>/dev/null || echo 0)

    # Time of first ring timeout (seconds from boot)
    FIRST_TIMEOUT_SEC="none"
    if [ "$RING_TIMEOUT_COUNT" -gt 0 ]; then
        FIRST_TIMEOUT_SEC=$(grep "ring gfx_0.0.0 timeout" "$RING_EVENTS" 2>/dev/null | head -1 | grep -oP '^\S+ \S+ \S+ \S+ \S+ kernel: \[\s*\K[0-9.]+' || true)
        if [ -z "$FIRST_TIMEOUT_SEC" ]; then
            # Fallback: try extracting from dmesg timestamp format [seconds.microseconds]
            FIRST_TIMEOUT_SEC=$(grep "ring gfx_0.0.0 timeout" "$DMESG_AMDGPU" 2>/dev/null | head -1 | grep -oP '\[\s*\K[0-9.]+' || echo "unknown")
        fi
    fi

    # Ring reset failures
    RING_RESET_FAIL=$(grep -c "Ring gfx_0.0.0 reset failed" "$RING_EVENTS" 2>/dev/null || echo 0)

    # MODE2 resets
    MODE2_RESETS=$(grep -c "MODE2 reset" "$RING_EVENTS" 2>/dev/null || echo 0)

    # Successful GPU resets
    GPU_RESET_SUCCESS=$(grep -c "GPU reset.*succeeded" "$RING_EVENTS" 2>/dev/null || echo 0)

    # Parser -125 errors
    PARSER_ERRORS=$(grep -c "parser.*-125" "$RING_EVENTS" 2>/dev/null || echo 0)

    # GDM status analysis
    GDM_STATUS="unknown"
    if [ -s "$GDM_LOG" ]; then
        GDM_NEVER_REG=$(grep -c "Session never registered" "$GDM_LOG" 2>/dev/null || echo 0)
        GDM_ALREADY_DEAD=$(grep -c "already dead" "$GDM_LOG" 2>/dev/null || echo 0)
        GDM_STARTED=$(grep -c "Gdm.*started\|GdmManager.*started\|New session" "$GDM_LOG" 2>/dev/null || echo 0)

        if [ "$GDM_NEVER_REG" -gt 2 ]; then
            GDM_STATUS="crash-loop(${GDM_NEVER_REG}x)"
        elif [ "$GDM_NEVER_REG" -gt 0 ]; then
            GDM_STATUS="session-failed(${GDM_NEVER_REG}x)"
        elif [ "$GDM_ALREADY_DEAD" -gt 0 ]; then
            GDM_STATUS="child-died(${GDM_ALREADY_DEAD}x)"
        elif [ "$GDM_STARTED" -gt 0 ]; then
            GDM_STATUS="ok"
        else
            GDM_STATUS="no-events"
        fi
    fi

    # DMUB firmware version
    DMUB_VER=$(grep -oP "DMUB.*version=\K0x[0-9a-fA-F]+" "$DMESG_AMDGPU" 2>/dev/null | head -1 || echo "N/A")

    # VCN firmware version
    VCN_VER=$(grep -oP "VCN firmware Version \K[^$]+" "$DMESG_AMDGPU" 2>/dev/null | head -1 || echo "N/A")

    # VM block_size and fragment_size from amdgpu init line
    BLOCK_SIZE=$(grep -oP "block size is \K[0-9]+-bit" "$DMESG_AMDGPU" 2>/dev/null | head -1 || echo "N/A")
    FRAGMENT_SIZE=$(grep -oP "fragment size is \K[0-9]+-bit" "$DMESG_AMDGPU" 2>/dev/null | head -1 || echo "N/A")

    # Unknown/invalid parameter warnings
    grep -i "unknown parameter" "$DMESG_AMDGPU" > "${BOOT_DIR}/invalid-params.txt" 2>/dev/null || true

    # Process names that triggered ring timeouts
    grep "ring gfx_0.0.0 timeout" -A1 "$DMESG_AMDGPU" 2>/dev/null | grep "Process" > "${BOOT_DIR}/timeout-processes.txt" || true

    # Verdict
    VERDICT="STABLE"
    if [ "$RING_TIMEOUT_COUNT" -gt 0 ]; then
        if [ "$RING_TIMEOUT_COUNT" -ge 3 ]; then
            VERDICT="UNSTABLE(${RING_TIMEOUT_COUNT}x-timeout)"
        else
            VERDICT="DEGRADED(${RING_TIMEOUT_COUNT}x-timeout)"
        fi
    fi
    if [ "$GDM_STATUS" = "crash-loop"* ]; then
        VERDICT="BROKEN(gdm-crash-loop)"
    fi

    #---------------------------------------------------------------------------
    # Write per-boot summary
    #---------------------------------------------------------------------------
    SUMMARY="${BOOT_DIR}/SUMMARY.txt"
    cat > "$SUMMARY" << EOSUMMARY
=== Boot ${OFFSET} Summary ===
Boot ID:        ${BOOT_ID}
Boot Time:      ${BOOT_TIME}
Kernel:         ${KERNEL}
Verdict:        ${VERDICT}

--- Kernel Cmdline ---
${FULL_CMDLINE}

--- amdgpu Parameters ---
  sg_display:       ${PARAM_SG_DISPLAY}
  vm_fragment_size: ${PARAM_VM_FRAGMENT}
  seamless:         ${PARAM_SEAMLESS}
  dcdebugmask:      ${PARAM_DCDEBUGMASK}
  ppfeaturemask:    ${PARAM_PPFEATUREMASK}
  noretry:          ${PARAM_NORETRY}
  lockup_timeout:   ${PARAM_LOCKUP_TIMEOUT}
  runpm:            ${PARAM_RUNPM}

--- System Parameters ---
  pcie_aspm:             ${PARAM_PCIE_ASPM}
  iommu:                 ${PARAM_IOMMU}
  processor.max_cstate:  ${PARAM_MAX_CSTATE}
  nouveau blacklisted:   ${NOUVEAU_BLACKLISTED}

--- Ring Timeout Events ---
  optc31 REG_WAIT timeouts: ${OPTC31_COUNT}
  ring gfx_0.0.0 timeouts:  ${RING_TIMEOUT_COUNT}
  First timeout at:          ${FIRST_TIMEOUT_SEC}s after boot
  Ring reset failures:       ${RING_RESET_FAIL}
  MODE2 GPU resets:          ${MODE2_RESETS}
  GPU reset successes:       ${GPU_RESET_SUCCESS}
  Parser -125 errors:        ${PARSER_ERRORS}

--- Display / GDM ---
  GDM status: ${GDM_STATUS}

--- Firmware ---
  DMUB version: ${DMUB_VER}
  VCN version:  ${VCN_VER}
  VM block_size:    ${BLOCK_SIZE}
  VM fragment_size: ${FRAGMENT_SIZE}

--- Triggering Processes ---
$(cat "${BOOT_DIR}/timeout-processes.txt" 2>/dev/null || echo "  (none)")

--- Invalid Parameters ---
$(cat "${BOOT_DIR}/invalid-params.txt" 2>/dev/null || echo "  (none)")
EOSUMMARY

    # Append to CSV
    echo "${OFFSET},${BOOT_ID},${BOOT_TIME% },${KERNEL},\"${CMDLINE_AMDGPU}\",${PARAM_VM_FRAGMENT},${PARAM_SEAMLESS},${PARAM_DCDEBUGMASK},${PARAM_PPFEATUREMASK},${PARAM_NORETRY},${PARAM_LOCKUP_TIMEOUT},${PARAM_SG_DISPLAY},${PARAM_RUNPM},${PARAM_PCIE_ASPM},${PARAM_IOMMU},${PARAM_MAX_CSTATE},${NOUVEAU_BLACKLISTED},${OPTC31_COUNT},${RING_TIMEOUT_COUNT},${FIRST_TIMEOUT_SEC},${RING_RESET_FAIL},${MODE2_RESETS},${GPU_RESET_SUCCESS},${PARSER_ERRORS},${GDM_STATUS},${DMUB_VER},${VCN_VER},${BLOCK_SIZE},${FRAGMENT_SIZE},${VERDICT}" >> "$CSV_FILE"

    # Print short status
    if [ "$RING_TIMEOUT_COUNT" -eq 0 ]; then
        echo -e "    ${GREEN}STABLE${NC} — 0 ring timeouts, GDM: ${GDM_STATUS}"
    elif [ "$RING_TIMEOUT_COUNT" -lt 3 ]; then
        echo -e "    ${YELLOW}DEGRADED${NC} — ${RING_TIMEOUT_COUNT} timeout(s), first@${FIRST_TIMEOUT_SEC}s, GDM: ${GDM_STATUS}"
    else
        echo -e "    ${RED}UNSTABLE${NC} — ${RING_TIMEOUT_COUNT} timeout(s), first@${FIRST_TIMEOUT_SEC}s, GDM: ${GDM_STATUS}"
    fi
    echo -e "    params: ${CMDLINE_AMDGPU:-none}"
    echo ""
done

###############################################################################
# Step 3: Generate comparison table
###############################################################################
echo -e "${BLUE}[Step 3]${NC} Generating comparison table..."

COMPARISON="${OUTPUT_DIR}/COMPARISON.txt"

cat > "$COMPARISON" << 'EOHEADER'
================================================================================
  MULTI-BOOT AMD iGPU DIAGNOSTIC COMPARISON
  AMD Raphael (GC 10.3.6 / DCN 3.1.5 / PCI 6c:00.0)
  ring gfx_0.0.0 timeout analysis across boots
================================================================================

LEGEND:
  optc31    = REG_WAIT timeout optc31_disable_crtc (DCN CRTC handoff failure)
  ring_to   = ring gfx_0.0.0 timeout count
  1st_to    = seconds from boot to first ring timeout
  reset_f   = ring reset failed count
  mode2     = MODE2 GPU reset count
  parse_err = amdgpu_cs_ioctl parser -125 error count
  gdm       = GDM session status

EOHEADER

# Table header
printf "%-6s %-22s %-6s %-6s %-6s %-8s %-6s %-6s %-6s %-24s %-10s\n" \
    "Boot" "Time" "optc31" "ring_to" "1st_to" "reset_f" "mode2" "parse" "gdm" "verdict" "kernel" >> "$COMPARISON"
printf "%-6s %-22s %-6s %-6s %-6s %-8s %-6s %-6s %-6s %-24s %-10s\n" \
    "------" "----------------------" "------" "------" "------" "--------" "------" "------" "------" "------------------------" "----------" >> "$COMPARISON"

# Read CSV (skip header) and format table
tail -n +2 "$CSV_FILE" | while IFS=',' read -r offset boot_id boot_time kernel cmdline_amdgpu vm_frag seamless dcdebug ppfeat noretry lockup sg_disp runpm pcie_aspm iommu max_cstate nouveau_bl optc31_count ring_to first_to reset_f mode2 gpu_ok parse_err gdm dmub vcn block frag verdict; do
    # Clean up quotes from CSV
    boot_time_short=$(echo "$boot_time" | sed 's/^ *//;s/ *$//' | cut -c1-22)
    verdict_clean=$(echo "$verdict" | tr -d '"')

    printf "%-6s %-22s %-6s %-6s %-6s %-8s %-6s %-6s %-6s %-24s %-10s\n" \
        "$offset" "$boot_time_short" "$optc31_count" "$ring_to" "$first_to" "$reset_f" "$mode2" "$parse_err" "$gdm" "$verdict_clean" "$kernel" >> "$COMPARISON"
done

echo "" >> "$COMPARISON"

# Parameter comparison section
echo "================================================================================" >> "$COMPARISON"
echo "  PARAMETER COMPARISON BY BOOT" >> "$COMPARISON"
echo "================================================================================" >> "$COMPARISON"
echo "" >> "$COMPARISON"

printf "%-6s %-10s %-10s %-14s %-16s %-10s %-16s %-10s %-10s\n" \
    "Boot" "sg_disp" "vm_frag" "dcdebugmask" "ppfeaturemask" "seamless" "lockup_timeout" "noretry" "runpm" >> "$COMPARISON"
printf "%-6s %-10s %-10s %-14s %-16s %-10s %-16s %-10s %-10s\n" \
    "------" "----------" "----------" "--------------" "----------------" "----------" "----------------" "----------" "----------" >> "$COMPARISON"

tail -n +2 "$CSV_FILE" | while IFS=',' read -r offset boot_id boot_time kernel cmdline_amdgpu vm_frag seamless dcdebug ppfeat noretry lockup sg_disp runpm pcie_aspm iommu max_cstate nouveau_bl optc31_count ring_to first_to reset_f mode2 gpu_ok parse_err gdm dmub vcn block frag verdict; do
    printf "%-6s %-10s %-10s %-14s %-16s %-10s %-16s %-10s %-10s\n" \
        "$offset" "$sg_disp" "$vm_frag" "$dcdebug" "$ppfeat" "$seamless" "$lockup" "$noretry" "$runpm" >> "$COMPARISON"
done

echo "" >> "$COMPARISON"

# System parameter comparison
echo "================================================================================" >> "$COMPARISON"
echo "  SYSTEM PARAMETERS BY BOOT" >> "$COMPARISON"
echo "================================================================================" >> "$COMPARISON"
echo "" >> "$COMPARISON"

printf "%-6s %-12s %-10s %-12s %-18s %-10s\n" \
    "Boot" "pcie_aspm" "iommu" "max_cstate" "nouveau_blocked" "verdict" >> "$COMPARISON"
printf "%-6s %-12s %-10s %-12s %-18s %-10s\n" \
    "------" "------------" "----------" "------------" "------------------" "----------" >> "$COMPARISON"

tail -n +2 "$CSV_FILE" | while IFS=',' read -r offset boot_id boot_time kernel cmdline_amdgpu vm_frag seamless dcdebug ppfeat noretry lockup sg_disp runpm pcie_aspm iommu max_cstate nouveau_bl optc31_count ring_to first_to reset_f mode2 gpu_ok parse_err gdm dmub vcn block frag verdict; do
    verdict_clean=$(echo "$verdict" | tr -d '"')
    printf "%-6s %-12s %-10s %-12s %-18s %-10s\n" \
        "$offset" "$pcie_aspm" "$iommu" "$max_cstate" "$nouveau_bl" "$verdict_clean" >> "$COMPARISON"
done

echo "" >> "$COMPARISON"

# Firmware comparison
echo "================================================================================" >> "$COMPARISON"
echo "  FIRMWARE & VM CONFIG BY BOOT" >> "$COMPARISON"
echo "================================================================================" >> "$COMPARISON"
echo "" >> "$COMPARISON"

printf "%-6s %-18s %-36s %-12s %-12s\n" \
    "Boot" "DMUB" "VCN" "block_size" "frag_size" >> "$COMPARISON"
printf "%-6s %-18s %-36s %-12s %-12s\n" \
    "------" "------------------" "------------------------------------" "------------" "------------" >> "$COMPARISON"

tail -n +2 "$CSV_FILE" | while IFS=',' read -r offset boot_id boot_time kernel cmdline_amdgpu vm_frag seamless dcdebug ppfeat noretry lockup sg_disp runpm pcie_aspm iommu max_cstate nouveau_bl optc31_count ring_to first_to reset_f mode2 gpu_ok parse_err gdm dmub vcn block frag verdict; do
    printf "%-6s %-18s %-36s %-12s %-12s\n" \
        "$offset" "$dmub" "$vcn" "$block" "$frag" >> "$COMPARISON"
done

echo "" >> "$COMPARISON"
echo "================================================================================" >> "$COMPARISON"
echo "  Full per-boot details: ${OUTPUT_DIR}/boot-<N>/SUMMARY.txt" >> "$COMPARISON"
echo "  CSV for spreadsheet:   ${OUTPUT_DIR}/comparison.csv" >> "$COMPARISON"
echo "================================================================================" >> "$COMPARISON"

echo -e "  ${GREEN}Comparison table written${NC}"
echo ""

###############################################################################
# Step 4: Also collect current system state (if running on target)
###############################################################################
echo -e "${BLUE}[Step 4]${NC} Collecting current system state..."

CURRENT_DIR="${OUTPUT_DIR}/current-state"
mkdir -p "$CURRENT_DIR"

# Current GRUB config
cp /etc/default/grub "$CURRENT_DIR/grub" 2>/dev/null || echo "N/A" > "$CURRENT_DIR/grub"

# Current modprobe.d configs
for f in /etc/modprobe.d/amdgpu*.conf /etc/modprobe.d/nvidia*.conf /etc/modprobe.d/blacklist*.conf; do
    [ -f "$f" ] && cp "$f" "$CURRENT_DIR/" 2>/dev/null || true
done

# Current amdgpu sysfs parameters (if loaded)
if [ -d /sys/module/amdgpu/parameters ]; then
    for p in /sys/module/amdgpu/parameters/*; do
        [ -f "$p" ] || continue
        pname=$(basename "$p")
        pval=$(cat "$p" 2>/dev/null || echo "unreadable")
        echo "${pname}=${pval}"
    done > "$CURRENT_DIR/amdgpu-sysfs-params.txt"
else
    echo "amdgpu module not loaded" > "$CURRENT_DIR/amdgpu-sysfs-params.txt"
fi

# Installed kernels
ls /boot/vmlinuz-* 2>/dev/null | sed 's|/boot/vmlinuz-||' | sort -V > "$CURRENT_DIR/installed-kernels.txt"

# Firmware file listing for Raphael
ls -la /lib/firmware/amdgpu/gc_10_3_6_* /lib/firmware/amdgpu/psp_13_0_5_* \
       /lib/firmware/amdgpu/dcn_3_1_5_* /lib/firmware/amdgpu/sdma_5_2_6_* \
       /lib/firmware/amdgpu/vcn_3_1_2_* 2>/dev/null > "$CURRENT_DIR/raphael-firmware-files.txt" || true

# Check .bin/.bin.zst conflicts
echo "--- .bin / .bin.zst conflicts ---" > "$CURRENT_DIR/firmware-conflicts.txt"
for f in /lib/firmware/amdgpu/gc_10_3_6_*.bin; do
    [ -f "$f" ] || continue
    case "$f" in *.bin.zst) continue ;; esac
    if [ -f "${f}.zst" ]; then
        echo "CONFLICT: $(basename "$f") AND $(basename "$f").zst" >> "$CURRENT_DIR/firmware-conflicts.txt"
    fi
done

# PCI devices
lspci -Dn 2>/dev/null | grep -E "0300|0302|0380" > "$CURRENT_DIR/gpu-pci-devices.txt" || true

# DRM card assignments
if [ -d /sys/class/drm ]; then
    for card in /sys/class/drm/card[0-9]*; do
        [ -d "$card" ] || continue
        cname=$(basename "$card")
        driver=$(readlink -f "$card/device/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "unknown")
        vendor=$(cat "$card/device/vendor" 2>/dev/null || echo "unknown")
        echo "${cname}: driver=${driver} vendor=${vendor}"
    done > "$CURRENT_DIR/drm-cards.txt"
fi

echo -e "  ${GREEN}Current system state collected${NC}"
echo ""

###############################################################################
# Step 5: Enable persistent journal (if not already)
###############################################################################
JOURNAL_PERSISTENT=true
if [ ! -d /var/log/journal ]; then
    JOURNAL_PERSISTENT=false
    echo -e "${YELLOW}[Step 5]${NC} Persistent journal not configured!"
    echo -e "  ${YELLOW}Without persistent journal, only current boot logs are available.${NC}"
    echo -e "  ${YELLOW}To enable (saves logs across reboots):${NC}"
    echo -e "    sudo mkdir -p /var/log/journal"
    echo -e "    sudo systemd-tmpfiles --create --prefix /var/log/journal"
    echo -e "    sudo systemctl restart systemd-journald"
    echo ""
    echo "WARN: persistent journal not enabled" >> "${OUTPUT_DIR}/WARNINGS.txt"
else
    echo -e "${BLUE}[Step 5]${NC} ${GREEN}Persistent journal is configured${NC}"
fi
echo ""

###############################################################################
# Step 6: Create archive
###############################################################################
echo -e "${BLUE}[Step 6]${NC} Creating archive..."

ARCHIVE="${OUTPUT_DIR}.tar.gz"
tar -czf "$ARCHIVE" -C /tmp "$(basename "$OUTPUT_DIR")" 2>/dev/null
echo -e "  ${GREEN}Archive: ${ARCHIVE}${NC}"
echo ""

###############################################################################
# Summary
###############################################################################
echo -e "${BOLD}================================================================${NC}"
echo -e "${GREEN}${BOLD}  Multi-Boot Diagnostic Complete!${NC}"
echo -e "${BOLD}================================================================${NC}"
echo ""
echo -e "  Analyzed: ${ANALYZE_COUNT} boot(s)"
echo ""
echo -e "  ${BOLD}Key files:${NC}"
echo -e "    ${OUTPUT_DIR}/COMPARISON.txt     — Side-by-side comparison table"
echo -e "    ${OUTPUT_DIR}/comparison.csv      — CSV for spreadsheet import"
echo -e "    ${OUTPUT_DIR}/boot-<N>/SUMMARY.txt — Per-boot detailed summary"
echo -e "    ${OUTPUT_DIR}/boot-<N>/dmesg-ring-events.txt — Ring timeout events"
echo -e "    ${OUTPUT_DIR}/current-state/      — Current system configuration"
echo ""
echo -e "  ${BOLD}Archive:${NC} ${ARCHIVE}"
echo ""
echo -e "  ${BOLD}Quick view:${NC}"
echo -e "    cat ${OUTPUT_DIR}/COMPARISON.txt"
echo ""

# Print the comparison table to stdout
echo -e "${BOLD}--- COMPARISON TABLE ---${NC}"
cat "$COMPARISON"
