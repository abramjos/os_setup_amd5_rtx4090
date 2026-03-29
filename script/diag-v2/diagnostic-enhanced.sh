#!/bin/bash
###############################################################################
# diagnostic-enhanced.sh — Enhanced GPU Diagnostic Collector v2
#
# PURPOSE: Comprehensive diagnostic collection for AMD Raphael iGPU DCN 3.1.5
#          crash loop analysis. Extends diagnostic-full.sh with:
#          - DMCUB state machine diagnostics (debugfs)
#          - devcoredump capture before auto-clear
#          - PCI AER error collection
#          - Module load timing analysis
#          - Display pipeline state (HUBP, DPP, OPP, OPTC)
#          - Firmware blob verification (hash + size)
#          - GPU reset event correlation
#          - Xorg/LightDM crash analysis
#          - GART/TLB and IOMMU state
#          - Automatic USB output detection
#
# SYSTEM: Ryzen 9 7950X | X670E Hero | RTX 4090 + Raphael iGPU
#
# USAGE:
#   sudo bash diagnostic-enhanced.sh [--auto] [max_boots]
#   --auto: Non-interactive mode (for systemd service)
#   max_boots: Number of previous boots to analyze (default: 5)
#
# OUTPUT: /var/log/ml-workstation-setup/diag-YYYYMMDD-HHMMSS/
#         Also copies to USB if detected.
###############################################################################

set -uo pipefail

###############################################################################
# Configuration
###############################################################################
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

AUTO_MODE=false
MAX_BOOTS=5
VARIANT="${VARIANT:-unknown}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto) AUTO_MODE=true; shift ;;
    --variant) VARIANT="$2"; shift 2 ;;
    *) MAX_BOOTS="$1"; shift ;;
  esac
done

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
DIAG_DIR="/var/log/ml-workstation-setup/diag-${TIMESTAMP}"

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}ERROR: Must run as root (sudo).${NC}"
    exit 1
fi

mkdir -p "$DIAG_DIR"

###############################################################################
# Helper functions
###############################################################################
section() { echo -e "\n${CYAN}=== $1 ===${NC}"; }
capture() {
    local outfile="$1"; shift
    eval "$@" > "$DIAG_DIR/$outfile" 2>&1 || true
}
capture_root() {
    local dir="$DIAG_DIR/$1"; shift
    mkdir -p "$dir"
    local outfile="$dir/$1"; shift
    eval "$@" > "$outfile" 2>&1 || true
}

detect_amd_card() {
    for card in /sys/class/drm/card[0-9]; do
        local driver=$(basename "$(readlink "$card/device/driver" 2>/dev/null)" 2>/dev/null)
        if [ "$driver" = "amdgpu" ]; then
            echo "$(basename "$card")"
            return
        fi
    done
    echo "card1"  # fallback
}

AMD_CARD=$(detect_amd_card)
AMD_PCI=$(readlink "/sys/class/drm/${AMD_CARD}/device" 2>/dev/null | grep -oP '\d+:\d+:\d+\.\d+' | tail -1)
DRM_DEBUGFS="/sys/kernel/debug/dri"

echo -e "${BOLD}ML Workstation Enhanced Diagnostic v2${NC}"
echo "Variant: $VARIANT | AMD card: $AMD_CARD | PCI: $AMD_PCI"
echo "Output: $DIAG_DIR"
echo ""

###############################################################################
# 01. KERNEL & SYSTEM
###############################################################################
section "01-kernel-system"
DIR="$DIAG_DIR/01-kernel-system"
mkdir -p "$DIR"

uname -a > "$DIR/uname-a.txt"
uname -r > "$DIR/kernel-release.txt"
cat /proc/cmdline > "$DIR/proc-cmdline.txt"
cat /proc/version > "$DIR/proc-version.txt"
cat /etc/os-release > "$DIR/os-release.txt" 2>/dev/null
uptime > "$DIR/uptime.txt"
cat /proc/sys/kernel/tainted > "$DIR/tainted.txt"
journalctl --list-boots 2>/dev/null | head -20 > "$DIR/boot-list.txt"
journalctl -b 0 --output=short-monotonic | head -1 > "$DIR/boot-id.txt"
dpkg -l | grep -E "linux-image|linux-headers" > "$DIR/kernel-packages.txt" 2>/dev/null
lsmod | sort > "$DIR/lsmod.txt"
systemctl --failed --no-pager > "$DIR/systemd-failed.txt" 2>/dev/null
systemctl status systemd-modules-load.service --no-pager > "$DIR/modules-load-status.txt" 2>/dev/null

# Module load TIMING — critical for card ordering diagnosis
journalctl -b 0 --no-pager -o short-monotonic | grep -E "nvidia|amdgpu|drm|simpledrm" | head -50 > "$DIR/module-load-timing.txt"

###############################################################################
# 02. AMDGPU DRIVER — Deep diagnostics
###############################################################################
section "02-amdgpu-driver"
DIR="$DIAG_DIR/02-amdgpu-driver"
mkdir -p "$DIR"

# dmesg filtered
dmesg | grep -i amdgpu > "$DIR/dmesg-amdgpu.txt" 2>/dev/null
dmesg | grep -iE 'drm|display|fb0|fbcon|connector' > "$DIR/dmesg-drm-display.txt" 2>/dev/null
dmesg | grep -iE 'error|warn|fail|timeout|fault' > "$DIR/dmesg-err-warn.txt" 2>/dev/null
dmesg | grep -iE 'firmware|fw|dmub|dmcub|psp' > "$DIR/dmesg-firmware.txt" 2>/dev/null
dmesg | grep -iE 'ring.*timeout|ring.*reset|GPU reset|MODE2|wedge|coredump' > "$DIR/dmesg-ring-timeout.txt" 2>/dev/null
dmesg | grep -iE 'gart|gtt|vram|memory|alloc|page.fault|iommu' > "$DIR/dmesg-memory.txt" 2>/dev/null
dmesg | grep -iE 'pci|aspm|link|aer|correctable|uncorrectable' > "$DIR/dmesg-pci-init.txt" 2>/dev/null
dmesg | grep -iE 'power|gfxoff|smu|dpm|suspend|resume' > "$DIR/dmesg-power.txt" 2>/dev/null
dmesg | grep -iE 'optc|crtc|otg|dcn|hubp|dpp|opp' > "$DIR/dmesg-dcn-pipeline.txt" 2>/dev/null
dmesg | grep -iE 'seamless|optimized_init' > "$DIR/dmesg-seamless.txt" 2>/dev/null

# sysfs parameters (all of them)
if [ -d /sys/module/amdgpu/parameters ]; then
    for param in /sys/module/amdgpu/parameters/*; do
        pname=$(basename "$param")
        pval=$(cat "$param" 2>/dev/null || echo "N/A")
        echo "$pname = $pval"
    done > "$DIR/amdgpu-sysfs-params.txt"
fi

# Module info
modinfo amdgpu > "$DIR/modinfo-amdgpu.txt" 2>/dev/null
lsmod | grep -E "amdgpu|drm" > "$DIR/lsmod-amdgpu.txt"

# GFXOFF state
if [ -f "/sys/class/drm/${AMD_CARD}/device/amdgpu_gfxoff_status" ]; then
    cat "/sys/class/drm/${AMD_CARD}/device/amdgpu_gfxoff_status" > "$DIR/gfxoff-status.txt"
fi
if [ -f "/sys/class/drm/${AMD_CARD}/device/amdgpu_gfxoff_count" ]; then
    cat "/sys/class/drm/${AMD_CARD}/device/amdgpu_gfxoff_count" > "$DIR/gfxoff-count.txt"
fi

###############################################################################
# 03. DMCUB / DCN PIPELINE STATE (debugfs) — CRITICAL
###############################################################################
section "03-dmcub-dcn-state"
DIR="$DIAG_DIR/03-dmcub-dcn-state"
mkdir -p "$DIR"

# Find DRM debugfs for AMD
AMD_DRM_IDX="${AMD_CARD#card}"
AMD_DEBUGFS="$DRM_DEBUGFS/$AMD_DRM_IDX"

# DMCUB firmware info from debugfs
if [ -f "$AMD_DEBUGFS/amdgpu_firmware_info" ]; then
    cat "$AMD_DEBUGFS/amdgpu_firmware_info" > "$DIR/firmware-info.txt"
fi

# DM (Display Manager) debugfs
if [ -d "$AMD_DEBUGFS/amdgpu_dm" ]; then
    # Dump all DM debugfs files
    for f in "$AMD_DEBUGFS/amdgpu_dm"/*; do
        fname=$(basename "$f")
        if [ -f "$f" ] && [ -r "$f" ]; then
            cat "$f" > "$DIR/dm-${fname}.txt" 2>/dev/null
        fi
    done
fi

# DMCUB trace log (if available)
if [ -f "$AMD_DEBUGFS/amdgpu_dm/amdgpu_dm_dmub_tracebuffer" ]; then
    cat "$AMD_DEBUGFS/amdgpu_dm/amdgpu_dm_dmub_tracebuffer" > "$DIR/dmcub-tracebuffer.txt" 2>/dev/null
fi

# DMCUB firmware status
if [ -f "$AMD_DEBUGFS/amdgpu_dm/amdgpu_dm_dmub_fw_state" ]; then
    cat "$AMD_DEBUGFS/amdgpu_dm/amdgpu_dm_dmub_fw_state" > "$DIR/dmcub-fw-state.txt" 2>/dev/null
fi

# DC state (display core)
if [ -f "$AMD_DEBUGFS/amdgpu_dm/dc_state" ]; then
    cat "$AMD_DEBUGFS/amdgpu_dm/dc_state" > "$DIR/dc-state.txt" 2>/dev/null
fi

# Display status
if [ -f "$AMD_DEBUGFS/amdgpu_dm/amdgpu_dm_visual_confirm" ]; then
    cat "$AMD_DEBUGFS/amdgpu_dm/amdgpu_dm_visual_confirm" > "$DIR/visual-confirm.txt" 2>/dev/null
fi

# CRC status per connector
for conn_dir in "$AMD_DEBUGFS"/amdgpu_dm/crc_win_*; do
    [ -d "$conn_dir" ] || continue
    cname=$(basename "$conn_dir")
    for f in "$conn_dir"/*; do
        [ -f "$f" ] || continue
        cat "$f" > "$DIR/${cname}-$(basename $f).txt" 2>/dev/null
    done
done

# GPU reset info
if [ -f "$AMD_DEBUGFS/amdgpu_gpu_recover" ]; then
    echo "amdgpu_gpu_recover exists (write-only trigger)" > "$DIR/gpu-recover-status.txt"
fi

# Ring info
for ring_file in "$AMD_DEBUGFS"/amdgpu_ring_*; do
    [ -f "$ring_file" ] || continue
    rname=$(basename "$ring_file")
    head -50 "$ring_file" > "$DIR/${rname}.txt" 2>/dev/null
done

###############################################################################
# 04. DEVCOREDUMP — Capture before auto-clear
###############################################################################
section "04-devcoredump"
DIR="$DIAG_DIR/04-devcoredump"
mkdir -p "$DIR"

COREDUMP_IDX=0
for devcd in /sys/class/devcoredump/devcd*/data; do
    if [ -f "$devcd" ]; then
        cp "$devcd" "$DIR/devcoredump-${COREDUMP_IDX}.bin" 2>/dev/null
        echo "Captured: $devcd ($(stat -c%s "$devcd" 2>/dev/null || echo '?') bytes)" >> "$DIR/devcoredump-manifest.txt"
        COREDUMP_IDX=$((COREDUMP_IDX + 1))
    fi
done
[ $COREDUMP_IDX -eq 0 ] && echo "(no devcoredumps found)" > "$DIR/devcoredump-manifest.txt"

# Also check DRM device-specific coredump
for card_path in /sys/class/drm/card*/device/devcoredump/data; do
    if [ -f "$card_path" ]; then
        card_name=$(echo "$card_path" | grep -oP 'card\d+')
        cp "$card_path" "$DIR/drm-${card_name}-coredump.bin" 2>/dev/null
        echo "Captured DRM coredump: $card_path" >> "$DIR/devcoredump-manifest.txt"
    fi
done

###############################################################################
# 05. NVIDIA DRIVER
###############################################################################
section "05-nvidia-driver"
DIR="$DIAG_DIR/05-nvidia-driver"
mkdir -p "$DIR"

dmesg | grep -iE 'nvidia|nvrm|nvlink|xid' > "$DIR/dmesg-nvidia.txt" 2>/dev/null
lsmod | grep nvidia > "$DIR/lsmod-nvidia.txt" 2>/dev/null
lsmod | grep nouveau > "$DIR/lsmod-nouveau.txt" 2>/dev/null

if command -v nvidia-smi &>/dev/null; then
    nvidia-smi > "$DIR/nvidia-smi.txt" 2>/dev/null
    nvidia-smi -q > "$DIR/nvidia-smi-q.txt" 2>/dev/null
    nvidia-smi --query-gpu=name,driver_version,display_active,display_mode,persistence_mode --format=csv > "$DIR/nvidia-gpu-info.txt" 2>/dev/null
    nvidia-smi --query-compute-apps=pid,name,used_memory --format=csv > "$DIR/nvidia-compute-apps.txt" 2>/dev/null
else
    echo "nvidia-smi not available" > "$DIR/nvidia-smi.txt"
fi

modinfo nvidia > "$DIR/modinfo-nvidia.txt" 2>/dev/null

###############################################################################
# 06. FIRMWARE — Hash verification + version analysis
###############################################################################
section "06-firmware"
DIR="$DIAG_DIR/06-firmware"
mkdir -p "$DIR"

# Package version
dpkg -l linux-firmware > "$DIR/firmware-package.txt" 2>/dev/null
dpkg -l | grep -iE 'firmware|nvidia-firmware' >> "$DIR/firmware-package.txt" 2>/dev/null

# Raphael-specific firmware blobs
echo "=== Raphael Firmware Blobs ===" > "$DIR/firmware-blobs.txt"
for pattern in "dcn_3_1_5_*" "psp_13_0_5_*" "gc_10_3_6_*" "sdma_5_2_6*" "vcn_3_1_2*"; do
    echo "--- ${pattern} ---" >> "$DIR/firmware-blobs.txt"
    ls -la /lib/firmware/amdgpu/${pattern} 2>/dev/null >> "$DIR/firmware-blobs.txt" || echo "  (none)" >> "$DIR/firmware-blobs.txt"
done

# SHA256 hash of critical firmware files
echo "=== Firmware SHA256 Hashes ===" > "$DIR/firmware-hashes.txt"
for f in /lib/firmware/amdgpu/dcn_3_1_5_dmcub.bin* /lib/firmware/amdgpu/psp_13_0_5_toc.bin*; do
    if [ -f "$f" ]; then
        sha256sum "$f" >> "$DIR/firmware-hashes.txt"
    fi
done

# Check for .bin/.bin.zst conflicts
echo "=== Firmware File Conflicts ===" > "$DIR/firmware-conflicts.txt"
for base in dcn_3_1_5_dmcub psp_13_0_5_toc psp_13_0_5_ta psp_13_0_5_asd; do
    bin="/lib/firmware/amdgpu/${base}.bin"
    zst="/lib/firmware/amdgpu/${base}.bin.zst"
    if [ -f "$bin" ] && [ -f "$zst" ]; then
        echo "CONFLICT: $base — both .bin and .bin.zst exist (kernel uses .bin.zst)" >> "$DIR/firmware-conflicts.txt"
        ls -la "$bin" "$zst" >> "$DIR/firmware-conflicts.txt"
    fi
done
grep -c "CONFLICT" "$DIR/firmware-conflicts.txt" | grep -q "^0$" && echo "(no conflicts)" >> "$DIR/firmware-conflicts.txt"

# Firmware in initramfs
lsinitramfs "/boot/initrd.img-$(uname -r)" 2>/dev/null | grep -E "amdgpu|dcn|psp|gc_10" > "$DIR/initramfs-firmware.txt" || echo "(lsinitramfs not available)" > "$DIR/initramfs-firmware.txt"

# DMUB version from dmesg
dmesg | grep -i "DMUB\|dmcub" > "$DIR/dmub-dmesg.txt" 2>/dev/null

# debugfs firmware info
if [ -f "$AMD_DEBUGFS/amdgpu_firmware_info" ]; then
    cat "$AMD_DEBUGFS/amdgpu_firmware_info" > "$DIR/debugfs-firmware-info.txt"
fi

###############################################################################
# 07. DISPLAY — Full display pipeline state
###############################################################################
section "07-display"
DIR="$DIAG_DIR/07-display"
mkdir -p "$DIR"

# DRM connectors
for conn in /sys/class/drm/card*-*/; do
    [ -d "$conn" ] || continue
    cname=$(basename "$conn")
    status=$(cat "$conn/status" 2>/dev/null || echo "unknown")
    enabled=$(cat "$conn/enabled" 2>/dev/null || echo "unknown")
    dpms=$(cat "$conn/dpms" 2>/dev/null || echo "unknown")
    modes=$(cat "$conn/modes" 2>/dev/null | tr '\n' ',' || echo "")
    echo "$cname  status=$status  enabled=$enabled  dpms=$dpms  modes=${modes:-(none)}"
done > "$DIR/connectors-status.txt"

# EDID
for conn in /sys/class/drm/card*-*/edid; do
    [ -f "$conn" ] || continue
    cname=$(echo "$conn" | grep -oP 'card\d+-[^/]+')
    if [ -s "$conn" ]; then
        xxd "$conn" > "$DIR/edid-${cname}-hex.txt" 2>/dev/null
        # Try to decode
        if command -v edid-decode &>/dev/null; then
            edid-decode "$conn" > "$DIR/edid-${cname}-decoded.txt" 2>/dev/null
        fi
    fi
done

# Display manager status
systemctl status lightdm.service --no-pager > "$DIR/lightdm-status.txt" 2>/dev/null
systemctl status gdm3.service --no-pager > "$DIR/gdm3-status.txt" 2>/dev/null
systemctl status display-manager.service --no-pager > "$DIR/display-manager-status.txt" 2>/dev/null

# GDM custom config
cat /etc/gdm3/custom.conf > "$DIR/gdm-custom.conf" 2>/dev/null

# gpu-manager
systemctl status gpu-manager.service --no-pager > "$DIR/gpu-manager-status.txt" 2>/dev/null

# LightDM config
cat /etc/lightdm/lightdm.conf.d/*.conf > "$DIR/lightdm-conf.txt" 2>/dev/null

# Journal for display managers
journalctl -b 0 -u lightdm --no-pager | tail -100 > "$DIR/lightdm-journal.txt" 2>/dev/null
journalctl -b 0 -u gdm3 --no-pager | tail -50 > "$DIR/gdm-journal.txt" 2>/dev/null

# Xorg log
cp /var/log/Xorg.0.log "$DIR/Xorg.0.log" 2>/dev/null
cp /var/log/Xorg.0.log.old "$DIR/Xorg.0.log.old" 2>/dev/null

# loginctl sessions
loginctl list-sessions --no-pager > "$DIR/loginctl-sessions.txt" 2>/dev/null
for sess in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
    echo "=== Session $sess ===" >> "$DIR/loginctl-sessions.txt"
    loginctl show-session "$sess" --no-pager >> "$DIR/loginctl-sessions.txt" 2>/dev/null
    echo "" >> "$DIR/loginctl-sessions.txt"
done

# logind journal
journalctl -b 0 -u systemd-logind --no-pager | tail -50 > "$DIR/logind-journal.txt" 2>/dev/null

# Xorg processes
ps aux | grep -iE 'xorg|lightdm|gdm|gnome-shell|xfce|xfwm' > "$DIR/display-processes.txt" 2>/dev/null

# GL renderer info
if command -v glxinfo &>/dev/null; then
    DISPLAY=:0 glxinfo 2>/dev/null | head -30 > "$DIR/glxinfo.txt" || echo "(glxinfo failed — display not available?)" > "$DIR/glxinfo.txt"
fi

###############################################################################
# 08. PCI & HARDWARE — AER, link state, IOMMU
###############################################################################
section "08-pci-hardware"
DIR="$DIAG_DIR/08-pci-hardware"
mkdir -p "$DIR"

lspci -nn > "$DIR/lspci-nn.txt" 2>/dev/null
lspci -vvv > "$DIR/lspci-vvv.txt" 2>/dev/null

# PCI link state for both GPUs
for gpu_pci in "$AMD_PCI" "01:00.0"; do
    echo "=== PCI $gpu_pci ===" >> "$DIR/pci-link-state.txt"
    lspci -vvv -s "$gpu_pci" 2>/dev/null | grep -iE "lnksta|lnkcap|speed|width|aspm|l0|l1" >> "$DIR/pci-link-state.txt"
    echo "" >> "$DIR/pci-link-state.txt"
done

# AER (Advanced Error Reporting)
echo "=== PCI AER Errors ===" > "$DIR/pci-aer.txt"
for dev in /sys/bus/pci/devices/*/aer_dev_correctable; do
    [ -f "$dev" ] || continue
    pci_addr=$(basename "$(dirname "$dev")")
    corr=$(cat "$dev" 2>/dev/null)
    uncorr=$(cat "$(dirname "$dev")/aer_dev_nonfatal" 2>/dev/null)
    fatal=$(cat "$(dirname "$dev")/aer_dev_fatal" 2>/dev/null)
    if [ -n "$corr" ] || [ -n "$uncorr" ] || [ -n "$fatal" ]; then
        echo "--- $pci_addr ---" >> "$DIR/pci-aer.txt"
        echo "  Correctable: $corr" >> "$DIR/pci-aer.txt"
        echo "  Non-fatal: $uncorr" >> "$DIR/pci-aer.txt"
        echo "  Fatal: $fatal" >> "$DIR/pci-aer.txt"
    fi
done

# IOMMU groups
echo "=== IOMMU Groups ===" > "$DIR/iommu-groups.txt"
for group in /sys/kernel/iommu_groups/*/devices/*; do
    [ -L "$group" ] || continue
    grp_num=$(echo "$group" | grep -oP 'iommu_groups/\K\d+')
    dev=$(basename "$group")
    desc=$(lspci -s "$dev" -nn 2>/dev/null | head -1)
    echo "Group $grp_num: $dev $desc" >> "$DIR/iommu-groups.txt"
done

# dmesg IOMMU
dmesg | grep -i iommu > "$DIR/dmesg-iommu.txt" 2>/dev/null

# DMI/BIOS info
dmidecode -t bios > "$DIR/dmi-bios.txt" 2>/dev/null
dmidecode -t system > "$DIR/dmi-system.txt" 2>/dev/null

###############################################################################
# 09. POWER & THERMAL
###############################################################################
section "09-power-thermal"
DIR="$DIAG_DIR/09-power-thermal"
mkdir -p "$DIR"

# AMD GPU power
if [ -d "/sys/class/drm/${AMD_CARD}/device/hwmon" ]; then
    for hwmon in /sys/class/drm/${AMD_CARD}/device/hwmon/hwmon*; do
        [ -d "$hwmon" ] || continue
        echo "=== $(basename $hwmon) ===" >> "$DIR/amdgpu-hwmon.txt"
        for f in "$hwmon"/*; do
            [ -f "$f" ] && [ -r "$f" ] && echo "  $(basename $f) = $(cat "$f" 2>/dev/null)" >> "$DIR/amdgpu-hwmon.txt"
        done
    done
fi

# GPU clocks
cat "/sys/class/drm/${AMD_CARD}/device/pp_dpm_sclk" > "$DIR/amdgpu-sclk.txt" 2>/dev/null
cat "/sys/class/drm/${AMD_CARD}/device/pp_dpm_mclk" > "$DIR/amdgpu-mclk.txt" 2>/dev/null
cat "/sys/class/drm/${AMD_CARD}/device/power_dpm_state" > "$DIR/amdgpu-dpm-state.txt" 2>/dev/null
cat "/sys/class/drm/${AMD_CARD}/device/power_dpm_force_performance_level" > "$DIR/amdgpu-perf-level.txt" 2>/dev/null

# CPU thermal
sensors > "$DIR/sensors.txt" 2>/dev/null

# CPU frequency
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor > "$DIR/cpu-governor.txt" 2>/dev/null
cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference > "$DIR/cpu-epp.txt" 2>/dev/null

###############################################################################
# 10. MEMORY — VRAM, GTT, system
###############################################################################
section "10-memory"
DIR="$DIAG_DIR/10-memory"
mkdir -p "$DIR"

cat "/sys/class/drm/${AMD_CARD}/device/mem_info_vram_total" > "$DIR/vram-total.txt" 2>/dev/null
cat "/sys/class/drm/${AMD_CARD}/device/mem_info_vram_used" > "$DIR/vram-used.txt" 2>/dev/null
cat "/sys/class/drm/${AMD_CARD}/device/mem_info_gtt_total" > "$DIR/gtt-total.txt" 2>/dev/null
cat "/sys/class/drm/${AMD_CARD}/device/mem_info_gtt_used" > "$DIR/gtt-used.txt" 2>/dev/null
cat "/sys/class/drm/${AMD_CARD}/device/mem_info_vis_vram_total" > "$DIR/vis-vram-total.txt" 2>/dev/null
cat "/sys/class/drm/${AMD_CARD}/device/mem_info_vis_vram_used" > "$DIR/vis-vram-used.txt" 2>/dev/null

cat /proc/meminfo > "$DIR/meminfo.txt" 2>/dev/null
cat /proc/buddyinfo > "$DIR/buddyinfo.txt" 2>/dev/null
cat /proc/pagetypeinfo > "$DIR/pagetypeinfo.txt" 2>/dev/null
free -h > "$DIR/free.txt" 2>/dev/null

###############################################################################
# 11. CONFIG FILES
###############################################################################
section "11-config-files"
DIR="$DIAG_DIR/11-config-files"
mkdir -p "$DIR"

cat /etc/default/grub > "$DIR/etc-default-grub.txt" 2>/dev/null
cat /proc/cmdline > "$DIR/grub-cmdline.txt"
cat /etc/initramfs-tools/modules > "$DIR/initramfs-modules.txt" 2>/dev/null
ls -la /etc/modprobe.d/ > "$DIR/modprobe-d-ls.txt" 2>/dev/null
for f in /etc/modprobe.d/*.conf; do
    [ -f "$f" ] || continue
    echo "=== $(basename $f) ===" >> "$DIR/modprobe-d-all.txt"
    cat "$f" >> "$DIR/modprobe-d-all.txt"
    echo "" >> "$DIR/modprobe-d-all.txt"
done
ls -la /etc/modules-load.d/ > "$DIR/modules-load-d-ls.txt" 2>/dev/null
for f in /etc/modules-load.d/*.conf; do
    [ -f "$f" ] || continue
    echo "=== $(basename $f) ===" >> "$DIR/modules-load-d-all.txt"
    cat "$f" >> "$DIR/modules-load-d-all.txt"
done
ls -la /etc/X11/xorg.conf.d/ > "$DIR/xorg-conf-d-ls.txt" 2>/dev/null
for f in /etc/X11/xorg.conf.d/*.conf; do
    [ -f "$f" ] || continue
    echo "=== $(basename $f) ===" >> "$DIR/xorg-conf-d-all.txt"
    cat "$f" >> "$DIR/xorg-conf-d-all.txt"
    echo "" >> "$DIR/xorg-conf-d-all.txt"
done
cat /etc/X11/xorg.conf > "$DIR/xorg.conf" 2>/dev/null
cat /etc/X11/default-display-manager > "$DIR/default-dm.txt" 2>/dev/null
ls -la /etc/environment.d/ > "$DIR/environment-d-ls.txt" 2>/dev/null
for f in /etc/environment.d/*.conf; do
    [ -f "$f" ] || continue
    echo "=== $(basename $f) ===" >> "$DIR/environment-d-all.txt"
    cat "$f" >> "$DIR/environment-d-all.txt"
done

###############################################################################
# 12. RING EVENTS — Timeline correlation
###############################################################################
section "12-ring-events"
DIR="$DIAG_DIR/12-ring-events"
mkdir -p "$DIR"

# Full ring timeout timeline
dmesg | grep -iE 'ring.*timeout|ring.*reset|GPU reset|MODE2|wedge|coredump|parser.*-125' > "$DIR/ring-timeline.txt" 2>/dev/null

# Extract process info from ring timeouts
dmesg | grep -A1 'ring.*timeout' | grep 'Process' > "$DIR/ring-timeout-processes.txt" 2>/dev/null

# Count events
echo "optc31_disable_crtc timeouts: $(dmesg | grep -c 'optc31_disable_crtc' 2>/dev/null || echo 0)" > "$DIR/event-counts.txt"
echo "optc1_wait_for_state timeouts: $(dmesg | grep -c 'optc1_wait_for_state' 2>/dev/null || echo 0)" >> "$DIR/event-counts.txt"
echo "ring gfx timeouts: $(dmesg | grep -c 'ring gfx.*timeout' 2>/dev/null || echo 0)" >> "$DIR/event-counts.txt"
echo "ring reset failed: $(dmesg | grep -c 'Ring.*reset failed' 2>/dev/null || echo 0)" >> "$DIR/event-counts.txt"
echo "MODE2 resets: $(dmesg | grep -c 'MODE2 reset' 2>/dev/null || echo 0)" >> "$DIR/event-counts.txt"
echo "GPU reset succeeded: $(dmesg | grep -c 'GPU reset succeeded' 2>/dev/null || echo 0)" >> "$DIR/event-counts.txt"
echo "DMUB hardware initialized: $(dmesg | grep -c 'DMUB hardware initialized' 2>/dev/null || echo 0)" >> "$DIR/event-counts.txt"
echo "parser -125 errors: $(dmesg | grep -c 'parser -125' 2>/dev/null || echo 0)" >> "$DIR/event-counts.txt"
echo "device wedged: $(dmesg | grep -c 'device wedged' 2>/dev/null || echo 0)" >> "$DIR/event-counts.txt"
echo "Xid errors: $(dmesg | grep -c 'Xid' 2>/dev/null || echo 0)" >> "$DIR/event-counts.txt"

###############################################################################
# 13. FULL JOURNAL (current boot)
###############################################################################
section "13-journal"
DIR="$DIAG_DIR/13-journal"
mkdir -p "$DIR"

dmesg > "$DIR/dmesg-full.txt" 2>/dev/null
journalctl -b 0 --no-pager > "$DIR/journal-current-boot.txt" 2>/dev/null

###############################################################################
# 14. DRM CARD ASSIGNMENT — Critical for dual-GPU
###############################################################################
section "14-drm-cards"
DIR="$DIAG_DIR/14-drm-cards"
mkdir -p "$DIR"

echo "=== DRM Card Assignments ===" > "$DIR/card-assignments.txt"
for card in /sys/class/drm/card[0-9]; do
    cname=$(basename "$card")
    vendor=$(cat "$card/device/vendor" 2>/dev/null || echo "N/A")
    device=$(cat "$card/device/device" 2>/dev/null || echo "N/A")
    driver=$(basename "$(readlink "$card/device/driver" 2>/dev/null)" 2>/dev/null || echo "N/A")
    pci_addr=$(readlink "$card/device" 2>/dev/null | grep -oP '\d+:\d+:\d+\.\d+' | tail -1)
    echo "$cname: vendor=$vendor device=$device driver=$driver pci=$pci_addr" >> "$DIR/card-assignments.txt"
done

# Render nodes
echo "" >> "$DIR/card-assignments.txt"
echo "=== Render Nodes ===" >> "$DIR/card-assignments.txt"
for rn in /sys/class/drm/renderD*; do
    [ -d "$rn" ] || continue
    rname=$(basename "$rn")
    driver=$(basename "$(readlink "$rn/device/driver" 2>/dev/null)" 2>/dev/null || echo "N/A")
    echo "$rname: driver=$driver" >> "$DIR/card-assignments.txt"
done

###############################################################################
# ANALYSIS — Automated verdict
###############################################################################
section "ANALYSIS"

ANALYSIS="$DIAG_DIR/ANALYSIS.txt"
cat > "$ANALYSIS" << 'HEADER'
================================================================
  ML WORKSTATION BOOT DIAGNOSTIC — AUTOMATED ANALYSIS
================================================================
HEADER

echo "" >> "$ANALYSIS"
echo "Variant: $VARIANT" >> "$ANALYSIS"
echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$ANALYSIS"
echo "Kernel: $(uname -r)" >> "$ANALYSIS"
echo "" >> "$ANALYSIS"

# Card ordering check
echo "--- DRM Card Ordering ---" >> "$ANALYSIS"
cat "$DIAG_DIR/14-drm-cards/card-assignments.txt" >> "$ANALYSIS"
echo "" >> "$ANALYSIS"

CARD0_DRIVER=$(basename "$(readlink /sys/class/drm/card0/device/driver 2>/dev/null)" 2>/dev/null)
if [ "$CARD0_DRIVER" = "amdgpu" ]; then
    echo "PASS: card0 = AMD (correct for display)" >> "$ANALYSIS"
else
    echo "FAIL: card0 = $CARD0_DRIVER (should be amdgpu for display)" >> "$ANALYSIS"
fi
echo "" >> "$ANALYSIS"

# DMUB firmware
echo "--- DMUB Firmware ---" >> "$ANALYSIS"
DMUB_VER=$(dmesg | grep "Loading DMUB firmware" | head -1 | grep -oP 'version=0x[0-9a-fA-F]+' | head -1)
echo "Loaded: ${DMUB_VER:-NOT FOUND}" >> "$ANALYSIS"
DMUB_INIT_COUNT=$(dmesg | grep -c "DMUB hardware initialized" 2>/dev/null || echo 0)
echo "DMUB init count: $DMUB_INIT_COUNT (1 = clean boot, >1 = resets occurred)" >> "$ANALYSIS"
echo "" >> "$ANALYSIS"

# Error counts
echo "--- Error Summary ---" >> "$ANALYSIS"
REG_WAIT=$(dmesg | grep -c 'REG_WAIT timeout' 2>/dev/null || echo 0)
RING_TO=$(dmesg | grep -c 'ring.*timeout' 2>/dev/null || echo 0)
GPU_RESET=$(dmesg | grep -c 'GPU reset' 2>/dev/null || echo 0)
WEDGED=$(dmesg | grep -c 'device wedged' 2>/dev/null || echo 0)
XID=$(dmesg | grep -c 'Xid' 2>/dev/null || echo 0)

echo "REG_WAIT timeouts: $REG_WAIT" >> "$ANALYSIS"
echo "Ring gfx timeouts: $RING_TO" >> "$ANALYSIS"
echo "GPU resets: $GPU_RESET" >> "$ANALYSIS"
echo "Device wedged: $WEDGED" >> "$ANALYSIS"
echo "NVIDIA Xid errors: $XID" >> "$ANALYSIS"
echo "" >> "$ANALYSIS"

# Verdict
echo "--- VERDICT ---" >> "$ANALYSIS"
if [ "$REG_WAIT" -eq 0 ] && [ "$RING_TO" -eq 0 ] && [ "$GPU_RESET" -eq 0 ]; then
    echo "STABLE: Clean boot, no GPU errors detected" >> "$ANALYSIS"
    VERDICT="STABLE"
elif [ "$RING_TO" -eq 0 ] && [ "$REG_WAIT" -le 1 ]; then
    echo "MARGINAL: optc31 timeout detected but no ring timeouts (display recovered)" >> "$ANALYSIS"
    VERDICT="MARGINAL"
else
    echo "UNSTABLE: $RING_TO ring timeout(s), $GPU_RESET GPU reset(s) — crash loop" >> "$ANALYSIS"
    VERDICT="UNSTABLE"
fi
echo "" >> "$ANALYSIS"

# Recommendations
echo "--- RECOMMENDATIONS ---" >> "$ANALYSIS"
if [ "$VERDICT" = "UNSTABLE" ]; then
    if echo "$DMUB_VER" | grep -qP '0x0500[0-4]'; then
        echo "1. CRITICAL: DMUB firmware too old. Run: sudo /usr/local/bin/update-dmcub-firmware.sh" >> "$ANALYSIS"
    fi
    if [ "$CARD0_DRIVER" != "amdgpu" ]; then
        echo "2. Card ordering wrong — NVIDIA is card0. Check initramfs module order." >> "$ANALYSIS"
    fi
    echo "3. Try Variant A (AccelMethod none) to eliminate GFX ring pressure" >> "$ANALYSIS"
    echo "4. Check Xorg.0.log for glamor/GL errors" >> "$ANALYSIS"
fi
echo "" >> "$ANALYSIS"

cat "$ANALYSIS"

###############################################################################
# USB copy
###############################################################################
USB_COPIED=false
for usbpath in /mnt/usb/UbuntuAutoInstall/logs /media/*/UbuntuAutoInstall/logs; do
    if [ -d "$usbpath" ]; then
        DEST="$usbpath/diag-${TIMESTAMP}"
        cp -r "$DIAG_DIR" "$DEST" 2>/dev/null && USB_COPIED=true && echo -e "${GREEN}Copied to USB: $DEST${NC}" && break
    fi
done

# Also try to create tar for USB
tar czf "$DIAG_DIR/diag-${TIMESTAMP}.tar.gz" -C "$(dirname "$DIAG_DIR")" "$(basename "$DIAG_DIR")" 2>/dev/null

echo ""
echo -e "${GREEN}Diagnostic collection complete: $DIAG_DIR${NC}"
echo "Verdict: $VERDICT"
[ "$USB_COPIED" = "true" ] || echo -e "${YELLOW}USB not detected — copy manually if needed${NC}"
