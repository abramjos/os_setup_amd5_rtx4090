#!/bin/bash
###############################################################################
# verify-boot.sh — ML Workstation Boot Verification
#
# PURPOSE: Automated pass/fail verification for each autoinstall variant.
#          Runs a series of checks with clear PASS/FAIL/WARN verdicts.
#          Designed to run automatically on first boot via systemd service
#          AND manually for iterative testing.
#
# CHECKS (ordered by criticality):
#   1. KERNEL: Correct version (HWE 6.17+)
#   2. DMUB_FIRMWARE: Version check (>= 0x0500E000 for post-fix)
#   3. DMUB_INIT_COUNT: Should be 1 (multiple = reset loop)
#   4. OPTC31_TIMEOUT: Zero REG_WAIT timeouts
#   5. RING_TIMEOUT: Zero ring gfx timeouts
#   6. GPU_RESET: Zero GPU resets
#   7. CARD_ORDER: card0 should be amdgpu (Variant A/B: any; Variant C: must be amdgpu)
#   8. DISPLAY_MANAGER: LightDM active, GDM masked
#   9. DESKTOP_SESSION: XFCE running, no gnome-shell
#  10. NVIDIA_HEADLESS: (Variant C only) Xorg NOT on NVIDIA GPU
#  11. FIRMWARE_CONFLICTS: No .bin/.bin.zst conflicts
#  12. BOOT_PARAMS: All expected kernel params present
#  13. COMPOSITOR: XFCE compositor disabled
#  14. DISPLAY_OUTPUT: At least one connected display on AMD
#  15. UPTIME_STABILITY: System has been up > 2 minutes without crash
#
# USAGE:
#   sudo bash verify-boot.sh [--variant A|B|C] [--auto] [--wait SECS]
#   --variant: Which autoinstall variant to verify against
#   --auto: Non-interactive mode (for systemd)
#   --wait: Wait N seconds before starting checks (default: 0)
#
# OUTPUT:
#   /var/log/ml-workstation-setup/verify-<variant>-<timestamp>.txt
#   Also copies to USB if detected.
###############################################################################

set -uo pipefail

###############################################################################
# Argument parsing
###############################################################################
VARIANT="unknown"
AUTO_MODE=false
WAIT_SECS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --variant) VARIANT="$2"; shift 2 ;;
    --auto) AUTO_MODE=true; shift ;;
    --wait) WAIT_SECS="$2"; shift 2 ;;
    *) shift ;;
  esac
done

###############################################################################
# Configuration
###############################################################################
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
REPORT_DIR="/var/log/ml-workstation-setup"
mkdir -p "$REPORT_DIR"
REPORT="$REPORT_DIR/verify-${VARIANT}-${TIMESTAMP}.txt"

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
SKIP_COUNT=0

###############################################################################
# Root check
###############################################################################
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}ERROR: Must run as root (sudo).${NC}"
    exit 1
fi

###############################################################################
# Wait if requested
###############################################################################
if [ "$WAIT_SECS" -gt 0 ]; then
    echo "Waiting ${WAIT_SECS}s for system to stabilize..."
    sleep "$WAIT_SECS"
fi

###############################################################################
# Check functions
###############################################################################
check_pass() {
    local name="$1" detail="$2"
    echo -e "${GREEN}[PASS]${NC} $name: $detail"
    echo "[PASS] $name: $detail" >> "$REPORT"
    PASS_COUNT=$((PASS_COUNT + 1))
}

check_fail() {
    local name="$1" detail="$2"
    echo -e "${RED}[FAIL]${NC} $name: $detail"
    echo "[FAIL] $name: $detail" >> "$REPORT"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

check_warn() {
    local name="$1" detail="$2"
    echo -e "${YELLOW}[WARN]${NC} $name: $detail"
    echo "[WARN] $name: $detail" >> "$REPORT"
    WARN_COUNT=$((WARN_COUNT + 1))
}

check_skip() {
    local name="$1" detail="$2"
    echo -e "${CYAN}[SKIP]${NC} $name: $detail"
    echo "[SKIP] $name: $detail" >> "$REPORT"
    SKIP_COUNT=$((SKIP_COUNT + 1))
}

###############################################################################
# Report header
###############################################################################
cat > "$REPORT" << EOF
================================================================
  ML WORKSTATION BOOT VERIFICATION
  Variant: $VARIANT
  Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)
  Kernel: $(uname -r)
  Uptime: $(uptime -p)
================================================================

EOF

echo -e "${BOLD}ML Workstation Boot Verification — Variant $VARIANT${NC}"
echo ""

###############################################################################
# CHECK 1: KERNEL VERSION
###############################################################################
KERNEL=$(uname -r)
if echo "$KERNEL" | grep -qP '6\.1[5-9]\.|6\.[2-9]\d'; then
    check_pass "KERNEL" "$KERNEL (HWE 6.15+ with DCN31 patches)"
else
    check_fail "KERNEL" "$KERNEL (expected 6.15+ for all critical DCN31 patches)"
fi

###############################################################################
# CHECK 2: DMUB FIRMWARE VERSION
###############################################################################
DMUB_VER=$(dmesg | grep "Loading DMUB firmware" | head -1 | grep -oP 'version=0x[0-9a-fA-F]+' | sed 's/version=//')
if [ -z "$DMUB_VER" ]; then
    check_fail "DMUB_FIRMWARE" "DMUB version not found in dmesg"
else
    # Extract the revision byte (3rd byte from right)
    # 0x05XXYY00 -> YY is the version we care about
    DMUB_HEX=$(echo "$DMUB_VER" | sed 's/0x//')
    DMUB_REV_HEX=$(echo "$DMUB_HEX" | cut -c5-6)
    DMUB_REV=$((16#$DMUB_REV_HEX 2>/dev/null || echo 0))

    if [ "$DMUB_REV" -ge 224 ]; then  # 0xE0 = 224 = post-Debian-fix
        check_pass "DMUB_FIRMWARE" "$DMUB_VER (revision $DMUB_REV >= 224, post-fix)"
    elif [ "$DMUB_REV" -ge 47 ]; then
        check_warn "DMUB_FIRMWARE" "$DMUB_VER (revision $DMUB_REV — pre-fix but improved from 0.0.15)"
    else
        check_fail "DMUB_FIRMWARE" "$DMUB_VER (revision $DMUB_REV — CRITICALLY OUTDATED, need >= 224)"
    fi
fi

###############################################################################
# CHECK 3: DMUB INIT COUNT (1 = clean, >1 = reset loop)
###############################################################################
DMUB_INIT=$(dmesg | grep -c "DMUB hardware initialized" 2>/dev/null || echo 0)
if [ "$DMUB_INIT" -eq 1 ]; then
    check_pass "DMUB_INIT_COUNT" "1 (clean boot, no resets)"
elif [ "$DMUB_INIT" -eq 0 ]; then
    check_warn "DMUB_INIT_COUNT" "0 (DMUB not found — check amdgpu loaded)"
else
    check_fail "DMUB_INIT_COUNT" "$DMUB_INIT (>1 means GPU reset/crash loop occurred)"
fi

###############################################################################
# CHECK 4: optc31 REG_WAIT TIMEOUT
###############################################################################
OPTC31=$(dmesg | grep -c 'optc31_disable_crtc' 2>/dev/null || echo 0)
if [ "$OPTC31" -eq 0 ]; then
    check_pass "OPTC31_TIMEOUT" "0 (no REG_WAIT timeout during CRTC handoff)"
else
    check_fail "OPTC31_TIMEOUT" "$OPTC31 timeout(s) — DCN pipe handoff failed"
fi

###############################################################################
# CHECK 5: RING GFX TIMEOUT
###############################################################################
RING_TO=$(dmesg | grep -c 'ring gfx.*timeout' 2>/dev/null || echo 0)
if [ "$RING_TO" -eq 0 ]; then
    check_pass "RING_TIMEOUT" "0 (no GFX ring hangs)"
else
    check_fail "RING_TIMEOUT" "$RING_TO timeout(s) — compositor hung on GFX ring"
    # Show which process triggered it
    TRIGGER_PROC=$(dmesg | grep -A1 'ring gfx.*timeout' | grep 'Process' | head -1)
    [ -n "$TRIGGER_PROC" ] && echo "  Trigger: $TRIGGER_PROC" | tee -a "$REPORT"
fi

###############################################################################
# CHECK 6: GPU RESET
###############################################################################
GPU_RESET=$(dmesg | grep -c 'GPU reset' 2>/dev/null || echo 0)
if [ "$GPU_RESET" -eq 0 ]; then
    check_pass "GPU_RESET" "0 (no GPU resets)"
else
    check_fail "GPU_RESET" "$GPU_RESET reset event(s)"
fi

###############################################################################
# CHECK 7: DRM CARD ORDER
###############################################################################
CARD0_DRIVER=$(basename "$(readlink /sys/class/drm/card0/device/driver 2>/dev/null)" 2>/dev/null || echo "N/A")
CARD1_DRIVER=$(basename "$(readlink /sys/class/drm/card1/device/driver 2>/dev/null)" 2>/dev/null || echo "N/A")

if [ "$VARIANT" = "A" ] || [ "$VARIANT" = "B" ]; then
    # No NVIDIA, so card0 should be amdgpu (only GPU)
    if [ "$CARD0_DRIVER" = "amdgpu" ]; then
        check_pass "CARD_ORDER" "card0=$CARD0_DRIVER (AMD is sole/primary GPU)"
    else
        check_warn "CARD_ORDER" "card0=$CARD0_DRIVER, card1=$CARD1_DRIVER"
    fi
else
    # Variant C: dual-GPU, card0 should be amdgpu
    if [ "$CARD0_DRIVER" = "amdgpu" ]; then
        check_pass "CARD_ORDER" "card0=amdgpu card1=$CARD1_DRIVER (correct order)"
    else
        check_fail "CARD_ORDER" "card0=$CARD0_DRIVER card1=$CARD1_DRIVER (amdgpu should be card0)"
    fi
fi

###############################################################################
# CHECK 8: DISPLAY MANAGER
###############################################################################
LIGHTDM_STATUS=$(systemctl is-active lightdm.service 2>/dev/null || echo "inactive")
GDM_STATUS=$(systemctl is-active gdm3.service 2>/dev/null || echo "inactive")
GDM_MASKED=$(systemctl is-enabled gdm3.service 2>/dev/null || echo "unknown")

if [ "$LIGHTDM_STATUS" = "active" ] && [ "$GDM_MASKED" = "masked" ]; then
    check_pass "DISPLAY_MANAGER" "LightDM active, GDM masked"
elif [ "$LIGHTDM_STATUS" = "active" ]; then
    check_warn "DISPLAY_MANAGER" "LightDM active but GDM not masked ($GDM_MASKED)"
else
    check_fail "DISPLAY_MANAGER" "LightDM=$LIGHTDM_STATUS, GDM=$GDM_STATUS ($GDM_MASKED)"
fi

###############################################################################
# CHECK 9: DESKTOP SESSION (no gnome-shell)
###############################################################################
GNOME_RUNNING=$(pgrep -c gnome-shell 2>/dev/null || echo 0)
XFCE_RUNNING=$(pgrep -c xfwm4 2>/dev/null || pgrep -c xfce4-session 2>/dev/null || echo 0)

if [ "$GNOME_RUNNING" -eq 0 ] && [ "$XFCE_RUNNING" -gt 0 ]; then
    check_pass "DESKTOP_SESSION" "XFCE running, no gnome-shell"
elif [ "$GNOME_RUNNING" -eq 0 ]; then
    check_warn "DESKTOP_SESSION" "No gnome-shell (good), XFCE processes: $XFCE_RUNNING"
else
    check_fail "DESKTOP_SESSION" "gnome-shell is running ($GNOME_RUNNING processes) — will trigger ring timeouts"
fi

###############################################################################
# CHECK 10: NVIDIA HEADLESS (Variant C only)
###############################################################################
if [ "$VARIANT" = "C" ]; then
    if command -v nvidia-smi &>/dev/null; then
        NVIDIA_DISP=$(nvidia-smi --query-gpu=display_active --format=csv,noheader 2>/dev/null)
        NVIDIA_XORG=$(nvidia-smi --query-compute-apps=pid,name --format=csv,noheader 2>/dev/null | grep -c Xorg || echo 0)

        if [ "$NVIDIA_DISP" = "Disabled" ] || [ "$NVIDIA_DISP" = "Enabled" ]; then
            # Check if Xorg is using NVIDIA
            NVIDIA_XORG_MEM=$(nvidia-smi | grep -c Xorg || echo 0)
            if [ "$NVIDIA_XORG_MEM" -eq 0 ]; then
                check_pass "NVIDIA_HEADLESS" "No Xorg processes on NVIDIA GPU"
            else
                check_warn "NVIDIA_HEADLESS" "Xorg present on NVIDIA ($NVIDIA_XORG_MEM entries in nvidia-smi)"
            fi
        else
            check_warn "NVIDIA_HEADLESS" "Display status: $NVIDIA_DISP"
        fi
    else
        check_skip "NVIDIA_HEADLESS" "nvidia-smi not available"
    fi
else
    check_skip "NVIDIA_HEADLESS" "Not applicable for Variant $VARIANT (no NVIDIA)"
fi

###############################################################################
# CHECK 11: FIRMWARE CONFLICTS
###############################################################################
CONFLICTS=0
for base in dcn_3_1_5_dmcub psp_13_0_5_toc psp_13_0_5_ta psp_13_0_5_asd; do
    bin="/lib/firmware/amdgpu/${base}.bin"
    zst="/lib/firmware/amdgpu/${base}.bin.zst"
    if [ -f "$bin" ] && [ -f "$zst" ]; then
        CONFLICTS=$((CONFLICTS + 1))
    fi
done

if [ "$CONFLICTS" -eq 0 ]; then
    check_pass "FIRMWARE_CONFLICTS" "No .bin/.bin.zst conflicts"
else
    check_fail "FIRMWARE_CONFLICTS" "$CONFLICTS conflict(s) — kernel may load wrong firmware"
fi

###############################################################################
# CHECK 12: BOOT PARAMETERS
###############################################################################
CMDLINE=$(cat /proc/cmdline)
MISSING_PARAMS=""

for param in "amdgpu.sg_display=0" "amdgpu.ppfeaturemask=0xfffd7fff" "amdgpu.gpu_recovery=1" "iommu=pt" "pcie_aspm=off"; do
    if ! echo "$CMDLINE" | grep -q "$param"; then
        MISSING_PARAMS="$MISSING_PARAMS $param"
    fi
done

# Variant-specific params
if [ "$VARIANT" = "C" ]; then
    for param in "nvidia-drm.modeset=1" "modprobe.blacklist=nouveau"; do
        if ! echo "$CMDLINE" | grep -q "$param"; then
            MISSING_PARAMS="$MISSING_PARAMS $param"
        fi
    done
fi

if [ -z "$MISSING_PARAMS" ]; then
    check_pass "BOOT_PARAMS" "All expected kernel parameters present"
else
    check_fail "BOOT_PARAMS" "Missing:$MISSING_PARAMS"
fi

# Check for removed/unwanted params
if echo "$CMDLINE" | grep -q "amdgpu.reset_method=1"; then
    check_warn "BOOT_PARAMS" "reset_method=1 present but NOT SUPPORTED on Raphael APU"
fi

###############################################################################
# CHECK 13: COMPOSITOR STATE
###############################################################################
# Check if xfwm4 compositor is off
XFWM_COMP=$(DISPLAY=:0 xfconf-query -c xfwm4 -p /general/use_compositing 2>/dev/null || echo "unknown")
if [ "$XFWM_COMP" = "false" ]; then
    check_pass "COMPOSITOR" "XFCE compositor disabled (zero GFX ring pressure)"
elif [ "$XFWM_COMP" = "true" ]; then
    check_warn "COMPOSITOR" "XFCE compositor enabled — may contribute to ring timeouts"
else
    check_warn "COMPOSITOR" "Could not determine compositor state: $XFWM_COMP"
fi

###############################################################################
# CHECK 14: DISPLAY OUTPUT
###############################################################################
AMD_CONNECTED=0
for conn in /sys/class/drm/${AMD_CARD:-card1}-*/status; do
    [ -f "$conn" ] || continue
    status=$(cat "$conn" 2>/dev/null)
    if [ "$status" = "connected" ]; then
        AMD_CONNECTED=$((AMD_CONNECTED + 1))
        CONN_NAME=$(echo "$conn" | grep -oP 'card\d+-\K[^/]+')
        echo "  Connected: $CONN_NAME" | tee -a "$REPORT"
    fi
done

if [ "$AMD_CONNECTED" -gt 0 ]; then
    check_pass "DISPLAY_OUTPUT" "$AMD_CONNECTED display(s) connected to AMD iGPU"
else
    check_fail "DISPLAY_OUTPUT" "No displays connected to AMD iGPU"
fi

###############################################################################
# CHECK 15: UPTIME STABILITY
###############################################################################
UPTIME_SECS=$(cat /proc/uptime | awk '{print int($1)}')
if [ "$UPTIME_SECS" -ge 120 ]; then
    check_pass "UPTIME_STABILITY" "${UPTIME_SECS}s uptime (>2 min, no early crash)"
elif [ "$UPTIME_SECS" -ge 30 ]; then
    check_warn "UPTIME_STABILITY" "${UPTIME_SECS}s uptime (marginal — check for pending crashes)"
else
    check_warn "UPTIME_STABILITY" "${UPTIME_SECS}s uptime (too early to assess stability)"
fi

###############################################################################
# SUMMARY
###############################################################################
echo "" | tee -a "$REPORT"
echo "================================================================" | tee -a "$REPORT"
echo "  VERIFICATION SUMMARY — Variant $VARIANT" | tee -a "$REPORT"
echo "================================================================" | tee -a "$REPORT"
echo "" | tee -a "$REPORT"
echo -e "  ${GREEN}PASS: $PASS_COUNT${NC}" | tee -a "$REPORT"
echo -e "  ${RED}FAIL: $FAIL_COUNT${NC}" | tee -a "$REPORT"
echo -e "  ${YELLOW}WARN: $WARN_COUNT${NC}" | tee -a "$REPORT"
echo -e "  ${CYAN}SKIP: $SKIP_COUNT${NC}" | tee -a "$REPORT"
echo "" | tee -a "$REPORT"

if [ "$FAIL_COUNT" -eq 0 ] && [ "$WARN_COUNT" -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}OVERALL: ALL CHECKS PASSED${NC}" | tee -a "$REPORT"
    echo "  OVERALL: ALL CHECKS PASSED" >> "$REPORT"
    OVERALL="PASS"
elif [ "$FAIL_COUNT" -eq 0 ]; then
    echo -e "  ${YELLOW}${BOLD}OVERALL: PASSED WITH WARNINGS${NC}" | tee -a "$REPORT"
    echo "  OVERALL: PASSED WITH WARNINGS" >> "$REPORT"
    OVERALL="WARN"
else
    echo -e "  ${RED}${BOLD}OVERALL: FAILED ($FAIL_COUNT critical issues)${NC}" | tee -a "$REPORT"
    echo "  OVERALL: FAILED ($FAIL_COUNT critical issues)" >> "$REPORT"
    OVERALL="FAIL"
fi

echo "" | tee -a "$REPORT"

###############################################################################
# NEXT STEPS based on verdict
###############################################################################
if [ "$OVERALL" = "FAIL" ]; then
    echo "--- RECOMMENDED NEXT STEPS ---" | tee -a "$REPORT"

    if dmesg | grep -q "DMUB firmware.*0x0500[0-4]"; then
        echo "1. Update DMCUB firmware: sudo /usr/local/bin/update-dmcub-firmware.sh" | tee -a "$REPORT"
        echo "   Then reboot and re-run this verification." | tee -a "$REPORT"
    fi

    if [ "$RING_TO" -gt 0 ]; then
        echo "2. Try Variant A (AccelMethod none) to eliminate GFX ring pressure" | tee -a "$REPORT"
    fi

    if [ "$CARD0_DRIVER" != "amdgpu" ] && [ "$VARIANT" = "C" ]; then
        echo "3. Card order wrong — check softdep nvidia pre: amdgpu in modprobe.d" | tee -a "$REPORT"
    fi

    echo "4. Run full diagnostics: sudo diagnostic-enhanced.sh" | tee -a "$REPORT"
    echo "5. Copy logs to USB for analysis" | tee -a "$REPORT"
fi

###############################################################################
# Copy to USB
###############################################################################
for usbpath in /mnt/usb/UbuntuAutoInstall/logs /media/*/UbuntuAutoInstall/logs; do
    if [ -d "$usbpath" ]; then
        cp "$REPORT" "$usbpath/" 2>/dev/null && echo -e "${GREEN}Report copied to USB: $usbpath/$(basename $REPORT)${NC}"
        break
    fi
done

echo ""
echo "Full report: $REPORT"
