#!/bin/bash
###############################################################################
# diagnostic-full.sh — Comprehensive GPU Diagnostic Collector
#
# PURPOSE: Single script that collects ALL diagnostic data for troubleshooting
#          AMD Raphael iGPU ring timeouts, display instability, and GPU resets
#          on the dual-GPU ML workstation (Raphael iGPU + RTX 4090).
#
# COMBINES AND EXTENDS:
#   - diagnostic-collect.sh (single-boot system state)
#   - 05-multiboot-amdgpu-diag.sh (multi-boot journal comparison)
#   - Additional: debugfs, devcoredump, EDID, PCIe AER, hwmon, initramfs,
#     power management, GPU memory, clock/frequency, RAS errors, DRM clients
#
# SYSTEM: Ryzen 9 7950X | X670E Hero | RTX 4090 + Raphael iGPU (GC 10.3.6)
#
# OUTPUT STRUCTURE:
#   runLog-XX/
#   ├── META.txt                    # Run metadata (timestamp, kernel, verdict)
#   ├── ANALYSIS.txt                # Automated quick analysis
#   ├── COMPARISON.txt              # Multi-boot side-by-side table
#   ├── comparison.csv              # Spreadsheet-importable data
#   ├── 01-kernel-system/           # Kernel version, cmdline, OS info
#   ├── 02-amdgpu-driver/           # amdgpu dmesg, sysfs params, module info
#   ├── 03-nvidia-driver/           # nvidia dmesg, lsmod, nvidia-smi
#   ├── 04-firmware/                # Firmware files, versions, initramfs
#   ├── 05-display/                 # GDM, Xorg, Wayland, EDID, connectors
#   ├── 06-pci-hardware/            # lspci, PCIe link, AER errors, IOMMU
#   ├── 07-drm-state/               # DRM devices, clients, debugfs
#   ├── 08-power-thermal/           # Power management, clocks, temps, hwmon
#   ├── 09-memory/                  # VRAM, GTT, meminfo, buddyinfo
#   ├── 10-config-files/            # GRUB, modprobe.d, udev, xorg.conf
#   ├── 11-ring-events/             # Ring timeouts, GPU resets, devcoredump
#   ├── 12-journal-full/            # Full journal + dmesg (current + previous)
#   ├── 13-multiboot/               # Per-boot comparison data
#   │   ├── boot-list.txt
#   │   ├── boot-0/  boot--1/ ...
#   │   │   ├── SUMMARY.txt
#   │   │   ├── dmesg-full.txt
#   │   │   ├── dmesg-amdgpu.txt
#   │   │   ├── dmesg-ring-events.txt
#   │   │   ├── gdm-journal.txt
#   │   │   ├── cmdline.txt
#   │   │   └── timeout-processes.txt
#   │   └── ...
#   └── runLog-XX.tar.gz            # Archive of everything
#
# USAGE:
#   sudo bash diagnostic-full.sh [max_boots]
#   max_boots: how many recent boots to analyze (default: 20)
#
# USB DETECTION: Auto-detects /mnt/usb/Final or /media/*/Final
###############################################################################

set -uo pipefail

###############################################################################
# Constants
###############################################################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

MAX_BOOTS="${1:-20}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

###############################################################################
# Root check
###############################################################################
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}ERROR: Must run as root (sudo).${NC}"
    exit 1
fi

###############################################################################
# Detect USB output path
###############################################################################
detect_output_base() {
    # Priority 1: /mnt/usb/UbuntuAutoInstall/logs
    if [ -d /mnt/usb/UbuntuAutoInstall/logs ]; then
        echo "/mnt/usb/UbuntuAutoInstall/logs"
        return
    fi
    # Priority 2: /mnt/usb/Final (create logs/)
    if [ -d /mnt/usb/Final ]; then
        mkdir -p /mnt/usb/UbuntuAutoInstall/logs
        echo "/mnt/usb/UbuntuAutoInstall/logs"
        return
    fi
    # Priority 3: /media/*UbuntuAutoInstall/logs (any mounted USB)
    for d in /media/*UbuntuAutoInstall/logs; do
        if [ -d "$d" ]; then
            echo "$d"
            return
        fi
    done
    # Priority 4: /media/*/Final
    for d in /media/*/Final; do
        if [ -d "$d" ]; then
            mkdir -p "$d/logs"
            echo "$d/logs"
            return
        fi
    done
    # Priority 5: any /media/* mount with enough space
    for d in /media/*; do
        if [ -d "$d" ] && mountpoint -q "$d" 2>/dev/null; then
            mkdir -p "$dUbuntuAutoInstall/logs"
            echo "$dUbuntuAutoInstall/logs"
            return
        fi
    done
    # Fallback: /tmp
    echo -e "${YELLOW}WARNING: No USB detected. Writing to /tmp${NC}" >&2
    echo "/tmp"
}

OUTPUT_BASE=$(detect_output_base)

###############################################################################
# Enumerate next runLog-XX
###############################################################################
next_run_number() {
    local base="$1"
    local n=0
    while [ $n -lt 100 ]; do
        local dir=$(printf "%s/runLog-%02d" "$base" "$n")
        if [ ! -d "$dir" ]; then
            echo "$n"
            return
        fi
        n=$((n + 1))
    done
    echo "99"
}

RUN_NUM=$(next_run_number "$OUTPUT_BASE")
RUN_DIR=$(printf "%s/runLog-%02d" "$OUTPUT_BASE" "$RUN_NUM")
mkdir -p "$RUN_DIR"

echo -e "${BOLD}================================================================${NC}"
echo -e "${BOLD}  Comprehensive GPU Diagnostic Collector${NC}"
echo -e "${BOLD}  Output: ${RUN_DIR}/${NC}"
echo -e "${BOLD}  Analyzing up to ${MAX_BOOTS} boots${NC}"
echo -e "${BOLD}================================================================${NC}"
echo ""

###############################################################################
# Helper functions
###############################################################################

# collect LABEL SUBDIR FILENAME COMMAND [ARGS...]
# Runs command, writes stdout+stderr to SUBDIR/FILENAME
collect() {
    local label="$1" subdir="$2" file="$3"
    shift 3
    local dir="${RUN_DIR}/${subdir}"
    mkdir -p "$dir"
    echo -e "  ${BLUE}[+]${NC} ${label}"
    "$@" > "${dir}/${file}" 2>&1 || true
}

# collect_bash LABEL SUBDIR FILENAME "bash code"
collect_bash() {
    local label="$1" subdir="$2" file="$3" code="$4"
    local dir="${RUN_DIR}/${subdir}"
    mkdir -p "$dir"
    echo -e "  ${BLUE}[+]${NC} ${label}"
    bash -c "$code" > "${dir}/${file}" 2>&1 || true
}

# collect_file LABEL SUBDIR FILENAME SOURCE_PATH
collect_file() {
    local label="$1" subdir="$2" file="$3" src="$4"
    local dir="${RUN_DIR}/${subdir}"
    mkdir -p "$dir"
    echo -e "  ${BLUE}[+]${NC} ${label}"
    if [ -f "$src" ]; then
        cp "$src" "${dir}/${file}" 2>/dev/null || echo "UNREADABLE: $src" > "${dir}/${file}"
    elif [ -d "$src" ]; then
        ls -la "$src" > "${dir}/${file}" 2>&1
    else
        echo "NOT FOUND: $src" > "${dir}/${file}"
    fi
}

# safe_cat PATH — cat file if it exists, else print fallback
safe_cat() {
    cat "$1" 2>/dev/null || echo "N/A"
}

# Detect AMD GPU DRM card number (card0, card1, etc.)
detect_amd_card() {
    for card in /sys/class/drm/card[0-9]*; do
        [ -d "$card" ] || continue
        local vendor
        vendor=$(cat "$card/device/vendor" 2>/dev/null)
        if [ "$vendor" = "0x1002" ]; then
            basename "$card"
            return
        fi
    done
    echo ""
}

# Detect AMD GPU DRI number for debugfs (0, 1, etc.)
detect_amd_dri() {
    local card
    card=$(detect_amd_card)
    [ -z "$card" ] && echo "" && return
    local num="${card#card}"
    # debugfs might use a different index — check name file
    for d in /sys/kernel/debug/dri/[0-9]*; do
        [ -d "$d" ] || continue
        local name
        name=$(cat "$d/name" 2>/dev/null || true)
        if echo "$name" | grep -qi "amdgpu"; then
            basename "$d"
            return
        fi
    done
    echo "$num"
}

AMD_CARD=$(detect_amd_card)
AMD_DRI=$(detect_amd_dri)
AMD_SYSFS=""
[ -n "$AMD_CARD" ] && AMD_SYSFS="/sys/class/drm/${AMD_CARD}/device"
AMD_DEBUGFS=""
[ -n "$AMD_DRI" ] && AMD_DEBUGFS="/sys/kernel/debug/dri/${AMD_DRI}"

echo -e "  AMD card: ${AMD_CARD:-not found}  DRI: ${AMD_DRI:-N/A}  sysfs: ${AMD_SYSFS:-N/A}"
echo ""

###############################################################################
# 01 — Kernel & System Info
###############################################################################
echo -e "${BOLD}--- 01. Kernel & System Info ---${NC}"
S="01-kernel-system"

collect "Kernel version (uname -a)" "$S" "uname-a.txt" uname -a
collect "Kernel release" "$S" "kernel-release.txt" uname -r
collect_file "/proc/cmdline" "$S" "proc-cmdline.txt" /proc/cmdline
collect_file "/proc/version" "$S" "proc-version.txt" /proc/version
collect_file "/etc/os-release" "$S" "os-release.txt" /etc/os-release
collect "Uptime" "$S" "uptime.txt" uptime
collect_file "Boot ID" "$S" "boot-id.txt" /proc/sys/kernel/random/boot_id
collect_file "Kernel taint flags" "$S" "tainted.txt" /proc/sys/kernel/tainted
collect "Installed kernel packages" "$S" "kernel-packages.txt" dpkg -l 'linux-image-*' 'linux-headers-*' 'linux-modules-*'
collect "Installed kernels in /boot" "$S" "installed-kernels.txt" bash -c 'ls -la /boot/vmlinuz-* 2>/dev/null'
collect "systemd-modules-load status" "$S" "modules-load-status.txt" systemctl status systemd-modules-load.service --no-pager
collect "systemd-modules-load journal" "$S" "modules-load-journal.txt" journalctl -u systemd-modules-load.service -b --no-pager
collect "Loaded modules (lsmod)" "$S" "lsmod.txt" lsmod
collect "Failed systemd units" "$S" "systemd-failed.txt" systemctl --failed --no-pager
echo ""

###############################################################################
# 02 — amdgpu Driver
###############################################################################
echo -e "${BOLD}--- 02. amdgpu Driver ---${NC}"
S="02-amdgpu-driver"

collect_bash "dmesg: amdgpu" "$S" "dmesg-amdgpu.txt" 'dmesg | grep -iE "amdgpu|\\[drm\\]|\\[drm:" || echo "(no amdgpu messages)"'
collect_bash "dmesg: firmware loading" "$S" "dmesg-firmware.txt" 'dmesg | grep -iE "firmware|fw_load|ucode|psp.*load|psp.*boot" || echo "(none)"'
collect_bash "dmesg: ring/fence/timeout" "$S" "dmesg-ring-timeout.txt" 'dmesg | grep -iE "ring.*timeout|ring.*reset|ring gfx|ring sdma|ring comp|ring vcn|signaled seq|emitted seq|gpu fault|page fault|vm fault|gpu reset|gpu recover|MODE2|REG_WAIT|optc31|parser.*-125|wedged|amdgpu_job_timedout" || echo "(none)"'
collect_bash "dmesg: module errors" "$S" "dmesg-module-errors.txt" 'dmesg | grep -iE "unknown parameter|amdgpu.*fail|amdgpu.*error|probe.*fail|module.*fail|firmware.*fail" || echo "(none)"'
collect_bash "dmesg: drm connector/display" "$S" "dmesg-drm-display.txt" 'dmesg | grep -iE "connector|hdmi|displayport|\\bdp\\b|edid|link training|backlight|panel" || echo "(none)"'
collect_bash "dmesg: memory/vram" "$S" "dmesg-memory.txt" 'dmesg | grep -iE "vram|\\bgtt\\b|gart|stolen|visible vram" || echo "(none)"'
collect_bash "dmesg: power management" "$S" "dmesg-power.txt" 'dmesg | grep -iE "dpm|smu|powerplay|pp_|suspend|resume|runtime.pm|gfxoff" || echo "(none)"'
collect_bash "dmesg: pci/init" "$S" "dmesg-pci-init.txt" 'dmesg | grep -iE "pci.*1002|ATOM BIOS|amdgpu.*init|amdgpu.*fini|amdgpu.*IP" || echo "(none)"'
collect_bash "dmesg: all errors+warnings" "$S" "dmesg-err-warn.txt" 'dmesg --level=err,warn 2>/dev/null || dmesg | grep -iE "error|warn|fail|critical"'

collect_bash "amdgpu in lsmod" "$S" "lsmod-amdgpu.txt" 'lsmod | grep -iE "amdgpu|drm" || echo "(amdgpu not loaded)"'
collect "modinfo amdgpu" "$S" "modinfo-amdgpu.txt" modinfo amdgpu
collect_bash "amdgpu accepted parameters" "$S" "amdgpu-params-accepted.txt" 'modinfo amdgpu 2>/dev/null | grep "^parm:" | sort'
collect "modprobe amdgpu --dry-run" "$S" "modprobe-dryrun.txt" modprobe --dry-run -v amdgpu

# sysfs parameters (all of them)
collect_bash "amdgpu sysfs parameters" "$S" "amdgpu-sysfs-params.txt" '
if [ -d /sys/module/amdgpu/parameters ]; then
    for p in /sys/module/amdgpu/parameters/*; do
        [ -f "$p" ] || continue
        pname=$(basename "$p")
        pval=$(cat "$p" 2>/dev/null || echo "unreadable")
        printf "%-40s = %s\n" "$pname" "$pval"
    done
else
    echo "amdgpu module not loaded"
fi'

# gfx_off validity check
collect_bash "gfx_off parameter check" "$S" "gfx-off-check.txt" '
if modinfo amdgpu 2>/dev/null | grep -q "parm:.*gfx_off"; then
    echo "gfx_off: VALID parameter"
    modinfo amdgpu 2>/dev/null | grep "parm:.*gfx_off"
else
    echo "gfx_off: NOT a valid parameter for this kernel"
    echo ""
    echo "Parameters containing gfx:"
    modinfo amdgpu 2>/dev/null | grep -i "parm:.*gfx" || echo "  (none)"
fi'

echo ""

###############################################################################
# 03 — NVIDIA Driver
###############################################################################
echo -e "${BOLD}--- 03. NVIDIA Driver ---${NC}"
S="03-nvidia-driver"

collect_bash "dmesg: nvidia" "$S" "dmesg-nvidia.txt" 'dmesg | grep -iE "nvidia|nouveau" || echo "(no nvidia/nouveau messages)"'
collect_bash "nvidia in lsmod" "$S" "lsmod-nvidia.txt" 'lsmod | grep -iE "nvidia" || echo "(nvidia not loaded)"'
collect_bash "nouveau in lsmod" "$S" "lsmod-nouveau.txt" 'lsmod | grep -iE "nouveau" || echo "(nouveau not loaded — good if blacklisted)"'
collect "nvidia-smi" "$S" "nvidia-smi.txt" nvidia-smi
collect "nvidia-smi -q" "$S" "nvidia-smi-q.txt" nvidia-smi -q
collect "modinfo nvidia" "$S" "modinfo-nvidia.txt" modinfo nvidia
echo ""

###############################################################################
# 04 — Firmware
###############################################################################
echo -e "${BOLD}--- 04. Firmware ---${NC}"
S="04-firmware"

collect_bash "Firmware package version" "$S" "firmware-package.txt" '
dpkg -l linux-firmware firmware-amd-graphics 2>/dev/null || true
apt list --installed 2>/dev/null | grep -i firmware || true'

collect_bash "Raphael firmware files (gc_10_3_6)" "$S" "firmware-raphael.txt" '
echo "=== gc_10_3_6 (Raphael GC) ==="
ls -la /lib/firmware/amdgpu/gc_10_3_6_* 2>/dev/null || echo "  (none)"
echo ""
echo "=== psp_13_0_5 (Raphael PSP) ==="
ls -la /lib/firmware/amdgpu/psp_13_0_5_* 2>/dev/null || echo "  (none)"
echo ""
echo "=== dcn_3_1_5 (Raphael DCN) ==="
ls -la /lib/firmware/amdgpu/dcn_3_1_5_* 2>/dev/null || echo "  (none)"
echo ""
echo "=== sdma_5_2_6 (Raphael SDMA) ==="
ls -la /lib/firmware/amdgpu/sdma_5_2_6_* 2>/dev/null || echo "  (none)"
echo ""
echo "=== vcn_3_1_2 (Raphael VCN) ==="
ls -la /lib/firmware/amdgpu/vcn_3_1_2_* 2>/dev/null || echo "  (none)"
echo ""
echo "=== gc_10_3_7 (alternate GC) ==="
ls -la /lib/firmware/amdgpu/gc_10_3_7_* 2>/dev/null || echo "  (none)"'

collect_bash ".bin/.bin.zst conflicts" "$S" "firmware-conflicts.txt" '
echo "Checking for .bin + .bin.zst conflicts (kernel prefers .bin.zst)..."
found=0
for f in /lib/firmware/amdgpu/gc_10_3_6_*.bin /lib/firmware/amdgpu/psp_13_0_5_*.bin /lib/firmware/amdgpu/dcn_3_1_5_*.bin /lib/firmware/amdgpu/sdma_5_2_6_*.bin; do
    [ -f "$f" ] || continue
    case "$f" in *.bin.zst) continue ;; esac
    if [ -f "${f}.zst" ]; then
        echo "CONFLICT: $(basename "$f") AND $(basename "$f").zst both exist"
        found=1
    fi
done
[ "$found" -eq 0 ] && echo "(no conflicts found)"'

collect_bash "All amdgpu firmware file count" "$S" "firmware-count.txt" '
echo "Total files in /lib/firmware/amdgpu/:"
ls /lib/firmware/amdgpu/ 2>/dev/null | wc -l'

# Firmware versions from debugfs
if [ -n "$AMD_DEBUGFS" ] && [ -f "${AMD_DEBUGFS}/amdgpu_firmware_info" ]; then
    collect_file "debugfs firmware info" "$S" "debugfs-firmware-info.txt" "${AMD_DEBUGFS}/amdgpu_firmware_info"
fi

# Initramfs firmware check
collect_bash "Initramfs amdgpu contents" "$S" "initramfs-amdgpu.txt" '
INITRD="/boot/initrd.img-$(uname -r)"
if [ -f "$INITRD" ]; then
    echo "=== amdgpu modules in initramfs ==="
    lsinitramfs "$INITRD" 2>/dev/null | grep -i amdgpu || echo "  (none)"
    echo ""
    echo "=== drm modules in initramfs ==="
    lsinitramfs "$INITRD" 2>/dev/null | grep -iE "drm" | head -20 || echo "  (none)"
    echo ""
    echo "=== modprobe configs in initramfs ==="
    lsinitramfs "$INITRD" 2>/dev/null | grep -i modprobe || echo "  (none)"
    echo ""
    echo "=== firmware blobs in initramfs (amdgpu) ==="
    lsinitramfs "$INITRD" 2>/dev/null | grep "firmware/amdgpu" | head -30 || echo "  (none)"
    echo ""
    echo "Total amdgpu firmware in initramfs:"
    lsinitramfs "$INITRD" 2>/dev/null | grep "firmware/amdgpu" | wc -l
else
    echo "initrd not found at $INITRD"
fi'

# BIOS info
collect "DMI BIOS info" "$S" "dmi-bios.txt" dmidecode -t bios
echo ""

###############################################################################
# 05 — Display (GDM / Xorg / Wayland / EDID / Connectors)
###############################################################################
echo -e "${BOLD}--- 05. Display ---${NC}"
S="05-display"

collect "GDM status" "$S" "gdm-status.txt" systemctl status gdm3 --no-pager
collect "GDM journal (this boot)" "$S" "gdm-journal.txt" journalctl -u gdm3 -b --no-pager
collect "GDM journal (previous boot)" "$S" "gdm-journal-prev.txt" journalctl -u gdm3 -b -1 --no-pager
# Also try 'gdm' unit name (varies by distro)
collect_bash "GDM journal (alt unit)" "$S" "gdm-journal-alt.txt" 'journalctl -u gdm -b --no-pager 2>/dev/null || echo "(gdm unit not found, gdm3 used)"'
collect "systemd-logind journal" "$S" "logind-journal.txt" journalctl -u systemd-logind -b --no-pager
collect_bash "gnome-shell journal" "$S" "gnome-shell-journal.txt" '
journalctl --user -b 2>/dev/null | grep -iE "gnome-shell|mutter|gdm|wayland|drm" | head -500 || echo "(no user journal access or empty)"'

collect_file "GDM custom.conf" "$S" "gdm-custom.conf" /etc/gdm3/custom.conf
collect_file "Xorg log" "$S" "Xorg.0.log" /var/log/Xorg.0.log
collect_file "Xorg log (old)" "$S" "Xorg.0.log.old" /var/log/Xorg.0.log.old
collect_bash "Xorg user log" "$S" "Xorg-user.log" 'cat /home/*/.local/share/xorg/Xorg.0.log 2>/dev/null || echo "(no user Xorg log)"'
collect_bash "Xorg via journal" "$S" "xorg-journal.txt" 'journalctl -b _COMM=Xorg --no-pager 2>/dev/null | head -200 || echo "(none)"'

collect "gpu-manager status" "$S" "gpu-manager-status.txt" systemctl status gpu-manager --no-pager

# Session type
collect_bash "Active sessions" "$S" "loginctl-sessions.txt" '
loginctl list-sessions --no-pager 2>/dev/null || echo "(loginctl unavailable)"
echo ""
for sess in $(loginctl list-sessions --no-legend 2>/dev/null | awk "{print \$1}"); do
    echo "=== Session $sess ==="
    loginctl show-session "$sess" 2>/dev/null
    echo ""
done'

# Connector status and EDID
collect_bash "DRM connectors status" "$S" "connectors-status.txt" '
for conn in /sys/class/drm/card*-*; do
    [ -d "$conn" ] || continue
    name=$(basename "$conn")
    status=$(cat "$conn/status" 2>/dev/null || echo "unknown")
    enabled=$(cat "$conn/enabled" 2>/dev/null || echo "unknown")
    dpms=$(cat "$conn/dpms" 2>/dev/null || echo "unknown")
    modes=$(cat "$conn/modes" 2>/dev/null | head -5 | tr "\n" ", ")
    printf "%-30s status=%-12s enabled=%-8s dpms=%-4s modes=%s\n" "$name" "$status" "$enabled" "$dpms" "$modes"
done'

# EDID binary dump (hex) for connected monitors
collect_bash "EDID data (hex)" "$S" "edid-hex.txt" '
for conn in /sys/class/drm/card*-*; do
    [ -f "$conn/edid" ] || continue
    name=$(basename "$conn")
    status=$(cat "$conn/status" 2>/dev/null)
    [ "$status" = "connected" ] || continue
    echo "=== $name ==="
    xxd "$conn/edid" 2>/dev/null | head -20
    echo ""
done
echo "(only connected outputs shown)"'

# edid-decode if available
collect_bash "EDID decoded" "$S" "edid-decoded.txt" '
if command -v edid-decode >/dev/null 2>&1; then
    for conn in /sys/class/drm/card*-*; do
        [ -f "$conn/edid" ] || continue
        status=$(cat "$conn/status" 2>/dev/null)
        [ "$status" = "connected" ] || continue
        echo "=== $(basename "$conn") ==="
        edid-decode "$conn/edid" 2>/dev/null
        echo ""
    done
else
    echo "(edid-decode not installed)"
fi'

echo ""

###############################################################################
# 06 — PCI & Hardware
###############################################################################
echo -e "${BOLD}--- 06. PCI & Hardware ---${NC}"
S="06-pci-hardware"

collect_bash "GPU PCI devices" "$S" "lspci-gpu.txt" 'lspci -nn | grep -iE "VGA|Display|3D"'
collect_bash "AMD iGPU detailed" "$S" "lspci-amd-verbose.txt" '
AMD_BUS=$(lspci -Dn | grep -i "1002" | grep -E "0300|0380" | head -1 | awk -F" " "{print \$1}")
[ -n "$AMD_BUS" ] && lspci -vvv -s "$AMD_BUS" || echo "AMD iGPU not found"'
collect_bash "NVIDIA GPU detailed" "$S" "lspci-nvidia-verbose.txt" '
NV_BUS=$(lspci -Dn | grep -i "10de" | grep -E "0300|0302" | head -1 | awk -F" " "{print \$1}")
[ -n "$NV_BUS" ] && lspci -vvv -s "$NV_BUS" || echo "NVIDIA GPU not found"'
collect "PCI topology tree" "$S" "lspci-tree.txt" lspci -tv
collect "PCI numeric" "$S" "lspci-Dn.txt" lspci -Dn

# PCIe link status
collect_bash "PCIe link status" "$S" "pcie-link-status.txt" '
for card in /sys/class/drm/card[0-9]*; do
    [ -d "$card/device" ] || continue
    name=$(basename "$card")
    vendor=$(cat "$card/device/vendor" 2>/dev/null || echo "?")
    cur_speed=$(cat "$card/device/current_link_speed" 2>/dev/null || echo "N/A")
    cur_width=$(cat "$card/device/current_link_width" 2>/dev/null || echo "N/A")
    max_speed=$(cat "$card/device/max_link_speed" 2>/dev/null || echo "N/A")
    max_width=$(cat "$card/device/max_link_width" 2>/dev/null || echo "N/A")
    echo "$name (vendor=$vendor):"
    echo "  Current: ${cur_speed} x${cur_width}"
    echo "  Maximum: ${max_speed} x${max_width}"
    echo ""
done'

# PCIe AER errors
collect_bash "PCIe AER errors" "$S" "pcie-aer-errors.txt" '
for card in /sys/class/drm/card[0-9]*; do
    [ -d "$card/device" ] || continue
    name=$(basename "$card")
    echo "=== $name ==="
    for f in aer_dev_correctable aer_dev_nonfatal aer_dev_fatal; do
        if [ -f "$card/device/$f" ]; then
            echo "  $f:"
            cat "$card/device/$f" 2>/dev/null | sed "s/^/    /"
        fi
    done
    echo ""
done'

# IOMMU groups
collect_bash "IOMMU groups (GPUs)" "$S" "iommu-groups.txt" '
for d in /sys/kernel/iommu_groups/*/devices/*; do
    [ -e "$d" ] || continue
    n=$(echo "$d" | cut -d/ -f5)
    dev="${d##*/}"
    info=$(lspci -nns "$dev" 2>/dev/null || echo "$dev")
    echo "Group $n: $info"
done 2>/dev/null | sort -t: -k1 -n | head -40'

# CPU and memory
collect_bash "CPU info" "$S" "cpuinfo.txt" 'head -40 /proc/cpuinfo'
collect "DMI system info" "$S" "dmi-system.txt" dmidecode -t system
collect "DMI memory info" "$S" "dmi-memory.txt" dmidecode -t memory

# Interrupts for amdgpu
collect_bash "Interrupts (amdgpu)" "$S" "interrupts-amdgpu.txt" 'grep -i amdgpu /proc/interrupts 2>/dev/null || echo "(no amdgpu interrupts)"'

# I/O memory map for amdgpu
collect_bash "IOMEM (amdgpu)" "$S" "iomem-amdgpu.txt" 'grep -i amdgpu /proc/iomem 2>/dev/null || echo "(no amdgpu iomem)"'

echo ""

###############################################################################
# 07 — DRM State
###############################################################################
echo -e "${BOLD}--- 07. DRM State ---${NC}"
S="07-drm-state"

collect "DRM device listing" "$S" "drm-ls.txt" ls -la /sys/class/drm/
collect_bash "DRM cards detail" "$S" "drm-cards.txt" '
for card in /sys/class/drm/card[0-9]*; do
    [ -d "$card" ] || continue
    name=$(basename "$card")
    driver=$(readlink -f "$card/device/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "unknown")
    vendor=$(cat "$card/device/vendor" 2>/dev/null || echo "unknown")
    device=$(cat "$card/device/device" 2>/dev/null || echo "unknown")
    echo "$name: driver=$driver vendor=$vendor device=$device"
done'

collect_bash "/dev/dri/ devices" "$S" "dev-dri.txt" 'ls -la /dev/dri/ 2>/dev/null || echo "/dev/dri not found"'

# DRM debugfs (requires debugfs mounted and accessible)
collect_bash "DRM module debug level" "$S" "drm-debug-level.txt" 'cat /sys/module/drm/parameters/debug 2>/dev/null || echo "N/A"'

if [ -n "$AMD_DEBUGFS" ]; then
    echo -e "  ${CYAN}AMD debugfs at ${AMD_DEBUGFS}${NC}"

    for f in amdgpu_firmware_info amdgpu_pm_info amdgpu_fence_info amdgpu_gem_info \
             amdgpu_vm_info amdgpu_sa_info amdgpu_gca_config amdgpu_sensors \
             amdgpu_gfxoff amdgpu_gfxoff_status amdgpu_gfxoff_count \
             amdgpu_gfxoff_residency state clients framebuffer name; do
        if [ -f "${AMD_DEBUGFS}/${f}" ]; then
            collect_file "debugfs: $f" "$S" "debugfs-${f}.txt" "${AMD_DEBUGFS}/${f}"
        fi
    done

    # Ring buffer info (just status, not full contents)
    collect_bash "debugfs: ring buffers" "$S" "debugfs-rings.txt" '
    for ring in '"${AMD_DEBUGFS}"'/amdgpu_ring_*; do
        [ -f "$ring" ] || continue
        echo "=== $(basename "$ring") ==="
        head -20 "$ring" 2>/dev/null
        echo ""
    done'

    # Display Core DTN log
    if [ -f "${AMD_DEBUGFS}/amdgpu_dm_dtn_log" ]; then
        collect_file "debugfs: DTN log" "$S" "debugfs-dtn-log.txt" "${AMD_DEBUGFS}/amdgpu_dm_dtn_log"
    fi
else
    echo -e "  ${YELLOW}AMD debugfs not available (normal if lockdown or not mounted)${NC}"
fi

echo ""

###############################################################################
# 08 — Power & Thermal
###############################################################################
echo -e "${BOLD}--- 08. Power & Thermal ---${NC}"
S="08-power-thermal"

if [ -n "$AMD_SYSFS" ]; then
    # Power management
    for f in power_dpm_state power_dpm_force_performance_level pp_power_profile_mode \
             pp_features pp_dpm_sclk pp_dpm_mclk pp_dpm_socclk pp_dpm_fclk \
             pp_dpm_dcefclk pp_dpm_vclk pp_dpm_dclk pp_dpm_pcie \
             gpu_busy_percent mem_busy_percent pp_od_clk_voltage; do
        if [ -f "${AMD_SYSFS}/${f}" ]; then
            collect_file "sysfs: $f" "$S" "sysfs-${f}.txt" "${AMD_SYSFS}/${f}"
        fi
    done

    # Runtime PM
    collect_bash "Runtime PM state" "$S" "runtime-pm.txt" '
    for f in runtime_status runtime_usage runtime_active_time runtime_suspended_time control autosuspend_delay_ms; do
        val=$(cat "'"${AMD_SYSFS}"'/power/$f" 2>/dev/null || echo "N/A")
        printf "%-30s = %s\n" "$f" "$val"
    done'

    # Power state
    collect_bash "PCI power state" "$S" "power-state.txt" '
    cat "'"${AMD_SYSFS}"'/power_state" 2>/dev/null || echo "N/A"'

    # hwmon sensors
    collect_bash "hwmon sensors" "$S" "hwmon-all.txt" '
    for hwmon in '"${AMD_SYSFS}"'/hwmon/hwmon*; do
        [ -d "$hwmon" ] || continue
        echo "=== $(basename "$hwmon") ($(cat "$hwmon/name" 2>/dev/null || echo "unknown")) ==="
        # Temperatures
        for t in "$hwmon"/temp*_input; do
            [ -f "$t" ] || continue
            num=$(basename "$t" | sed "s/temp//;s/_input//")
            label=$(cat "${hwmon}/temp${num}_label" 2>/dev/null || echo "temp${num}")
            val=$(cat "$t" 2>/dev/null || echo "?")
            crit=$(cat "${hwmon}/temp${num}_crit" 2>/dev/null || echo "N/A")
            printf "  %-12s: %s mC  (crit: %s mC)\n" "$label" "$val" "$crit"
        done
        # Fan
        for t in "$hwmon"/fan*_input; do
            [ -f "$t" ] || continue
            num=$(basename "$t" | sed "s/fan//;s/_input//")
            val=$(cat "$t" 2>/dev/null || echo "?")
            printf "  fan%s:        %s RPM\n" "$num" "$val"
        done
        # Power
        for t in "$hwmon"/power*_average "$hwmon"/power*_input; do
            [ -f "$t" ] || continue
            name=$(basename "$t")
            val=$(cat "$t" 2>/dev/null || echo "?")
            printf "  %-12s: %s uW\n" "$name" "$val"
        done
        # Frequency
        for t in "$hwmon"/freq*_input; do
            [ -f "$t" ] || continue
            name=$(basename "$t")
            val=$(cat "$t" 2>/dev/null || echo "?")
            printf "  %-12s: %s Hz\n" "$name" "$val"
        done
        # Voltage
        for t in "$hwmon"/in*_input; do
            [ -f "$t" ] || continue
            name=$(basename "$t")
            val=$(cat "$t" 2>/dev/null || echo "?")
            printf "  %-12s: %s mV\n" "$name" "$val"
        done
        echo ""
    done'
fi

# System-wide sensors
collect_bash "lm-sensors" "$S" "sensors.txt" 'sensors 2>/dev/null || echo "(lm-sensors not installed)"'

# Power profiles daemon
collect "power-profiles-daemon" "$S" "power-profiles.txt" systemctl status power-profiles-daemon --no-pager

echo ""

###############################################################################
# 09 — Memory (VRAM / GTT / System)
###############################################################################
echo -e "${BOLD}--- 09. Memory ---${NC}"
S="09-memory"

if [ -n "$AMD_SYSFS" ]; then
    collect_bash "GPU memory info" "$S" "gpu-memory.txt" '
    for f in mem_info_vram_total mem_info_vram_used mem_info_vis_vram_total \
             mem_info_vis_vram_used mem_info_gtt_total mem_info_gtt_used; do
        val=$(cat "'"${AMD_SYSFS}"'/$f" 2>/dev/null || echo "N/A")
        if [ "$val" != "N/A" ] && [ "$val" -gt 0 ] 2>/dev/null; then
            val_mb=$((val / 1048576))
            printf "%-30s = %s (%s MB)\n" "$f" "$val" "$val_mb"
        else
            printf "%-30s = %s\n" "$f" "$val"
        fi
    done'

    # RAS error counts
    collect_bash "RAS error counts" "$S" "ras-errors.txt" '
    if [ -d "'"${AMD_SYSFS}"'/ras" ]; then
        for f in "'"${AMD_SYSFS}"'/ras"/*; do
            [ -f "$f" ] || continue
            echo "$(basename "$f"): $(cat "$f" 2>/dev/null)"
        done
    else
        echo "(RAS not available — normal for consumer GPUs)"
    fi'
fi

collect_file "/proc/meminfo" "$S" "meminfo.txt" /proc/meminfo
collect_file "/proc/buddyinfo" "$S" "buddyinfo.txt" /proc/buddyinfo
collect_file "/proc/vmstat" "$S" "vmstat.txt" /proc/vmstat
collect_bash "Swap info" "$S" "swap.txt" 'swapon --show 2>/dev/null; echo ""; cat /proc/swaps 2>/dev/null'

echo ""

###############################################################################
# 10 — Configuration Files
###############################################################################
echo -e "${BOLD}--- 10. Configuration Files ---${NC}"
S="10-config-files"

collect_file "/etc/default/grub" "$S" "etc-default-grub.txt" /etc/default/grub
collect_bash "GRUB cmdline extraction" "$S" "grub-cmdline.txt" 'grep "GRUB_CMDLINE" /etc/default/grub 2>/dev/null || echo "(not found)"'

# All modprobe.d configs
collect_bash "modprobe.d listing" "$S" "modprobe-d-ls.txt" 'ls -la /etc/modprobe.d/ 2>/dev/null'
collect_bash "modprobe.d all content" "$S" "modprobe-d-all.txt" '
for f in /etc/modprobe.d/*.conf; do
    [ -f "$f" ] || continue
    echo "=== $f ==="
    cat "$f" 2>/dev/null
    echo ""
done'

# modules-load.d
collect_bash "modules-load.d listing" "$S" "modules-load-d-ls.txt" 'ls -la /etc/modules-load.d/ 2>/dev/null'
collect_bash "modules-load.d all content" "$S" "modules-load-d-all.txt" '
for f in /etc/modules-load.d/*.conf; do
    [ -f "$f" ] || continue
    echo "=== $f ==="
    cat "$f" 2>/dev/null
    echo ""
done'

collect_file "initramfs-tools/modules" "$S" "initramfs-modules.txt" /etc/initramfs-tools/modules

# X11 configs
collect_bash "X11 xorg.conf.d" "$S" "xorg-conf-d.txt" '
for f in /etc/X11/xorg.conf.d/*.conf; do
    [ -f "$f" ] || continue
    echo "=== $f ==="
    cat "$f" 2>/dev/null
    echo ""
done'
collect_file "xorg.conf" "$S" "xorg.conf" /etc/X11/xorg.conf

# udev rules (GPU-related)
collect_bash "udev rules (GPU)" "$S" "udev-rules-gpu.txt" '
for d in /etc/udev/rules.d /usr/lib/udev/rules.d; do
    for f in "$d"/*amdgpu* "$d"/*nvidia* "$d"/*drm* "$d"/*gpu* "$d"/*seat* "$d"/*gdm*; do
        [ -f "$f" ] || continue
        echo "=== $f ==="
        cat "$f" 2>/dev/null
        echo ""
    done
done'

# udevadm info for DRM devices
collect_bash "udevadm info (DRM)" "$S" "udevadm-drm.txt" '
for dev in /dev/dri/card*; do
    [ -e "$dev" ] || continue
    echo "=== $dev ==="
    udevadm info -a -n "$dev" 2>/dev/null | head -40
    echo ""
done'

echo ""

###############################################################################
# 11 — Ring Events & Crash Dumps
###############################################################################
echo -e "${BOLD}--- 11. Ring Events & Crash Dumps ---${NC}"
S="11-ring-events"

collect_bash "All ring/reset events (dmesg)" "$S" "ring-events-dmesg.txt" '
dmesg | grep -iE "ring.*timeout|ring.*reset|GPU reset|MODE2|REG_WAIT|optc31|parser.*-125|coredump|wedged|gfx_0|signaled seq|emitted seq|amdgpu_job_timedout|gpu fault|page fault|vm fault" || echo "(no ring events in current boot)"'

collect_bash "Ring events timeline" "$S" "ring-timeline.txt" '
echo "=== Ring timeout events with timestamps ==="
dmesg -T 2>/dev/null | grep -iE "ring.*timeout|GPU reset|MODE2|REG_WAIT|optc31" || echo "(none)"'

# Device coredump
collect_bash "Device coredump" "$S" "devcoredump.txt" '
if ls /sys/class/devcoredump/devcd*/data 2>/dev/null; then
    for dump in /sys/class/devcoredump/devcd*/data; do
        echo "=== $dump ==="
        # First 200 lines of text representation
        cat "$dump" 2>/dev/null | head -200
        echo ""
        echo "(truncated at 200 lines)"
    done
else
    echo "(no device coredumps present — they are cleared after read)"
fi'

# Crash process info
collect_bash "Processes at timeout" "$S" "timeout-processes.txt" '
dmesg | grep -A2 "ring gfx_0\.[01]\.0 timeout" | grep -i "Process" || echo "(no process info in ring timeouts)"'

echo ""

###############################################################################
# 12 — Full Journal & dmesg
###############################################################################
echo -e "${BOLD}--- 12. Full Journal & dmesg ---${NC}"
S="12-journal-full"

collect "Full dmesg" "$S" "dmesg-full.txt" dmesg
collect_bash "Full dmesg (timestamped)" "$S" "dmesg-full-timestamp.txt" 'dmesg -T 2>/dev/null || echo "dmesg -T not supported"'
collect_bash "Journal this boot (last 5000 lines)" "$S" "journal-boot-current.txt" 'journalctl -b --no-pager 2>/dev/null | tail -5000'
collect_bash "Journal previous boot (last 5000 lines)" "$S" "journal-boot-prev.txt" 'journalctl -b -1 --no-pager 2>/dev/null | tail -5000'
collect_bash "Journal kernel (this boot)" "$S" "journal-kernel-current.txt" 'journalctl -b -k --no-pager 2>/dev/null'
collect_bash "Journal kernel (previous boot)" "$S" "journal-kernel-prev.txt" 'journalctl -b -1 -k --no-pager 2>/dev/null'
collect_bash "Journal errors only (this boot)" "$S" "journal-errors.txt" 'journalctl -b -p err --no-pager 2>/dev/null | head -1000'
collect_bash "Journal errors (previous boot)" "$S" "journal-errors-prev.txt" 'journalctl -b -1 -p err --no-pager 2>/dev/null | head -1000'
echo ""

###############################################################################
# 13 — Multi-boot Comparison
###############################################################################
echo -e "${BOLD}--- 13. Multi-boot Comparison ---${NC}"
S="13-multiboot"
MULTI_DIR="${RUN_DIR}/${S}"
mkdir -p "$MULTI_DIR"

BOOT_LIST=$(journalctl --list-boots --no-pager 2>/dev/null || true)

if [ -z "$BOOT_LIST" ]; then
    echo -e "  ${YELLOW}No boot entries in journal. Persistent logging may not be enabled.${NC}"
    echo "No boot entries found. Enable persistent journal:" > "${MULTI_DIR}/boot-list.txt"
    echo "  sudo mkdir -p /var/log/journal" >> "${MULTI_DIR}/boot-list.txt"
    echo "  sudo systemd-tmpfiles --create --prefix /var/log/journal" >> "${MULTI_DIR}/boot-list.txt"
else
    echo "$BOOT_LIST" > "${MULTI_DIR}/boot-list.txt"

    TOTAL_BOOTS=$(echo "$BOOT_LIST" | wc -l)
    ANALYZE_COUNT=$((TOTAL_BOOTS < MAX_BOOTS ? TOTAL_BOOTS : MAX_BOOTS))
    echo -e "  ${GREEN}${TOTAL_BOOTS} boot(s) in journal, analyzing ${ANALYZE_COUNT}${NC}"

    # CSV header — use pipe delimiter to avoid lockup_timeout comma issues
    CSV_FILE="${MULTI_DIR}/comparison.csv"
    echo 'boot_offset|boot_id|boot_time|kernel|amdgpu_params|vm_fragment_size|seamless|dcdebugmask|ppfeaturemask|noretry|lockup_timeout|sg_display|cg_mask|runpm|pcie_aspm|iommu|max_cstate|nouveau_blacklisted|optc31_count|ring_timeout_count|first_timeout_sec|ring_reset_fail|mode2_reset_count|gpu_reset_success|parser_error_count|gdm_status|dmub_version|vcn_version|block_size|fragment_size|verdict' > "$CSV_FILE"

    BOOT_OFFSETS=$(echo "$BOOT_LIST" | tail -n "$ANALYZE_COUNT" | awk '{print $1}')

    BOOT_NUM=0
    for OFFSET in $BOOT_OFFSETS; do
        BOOT_NUM=$((BOOT_NUM + 1))
        BOOT_ID=$(echo "$BOOT_LIST" | awk -v off="$OFFSET" '$1 == off {print $2}')
        # journalctl --list-boots format: OFFSET BOOT_ID DAY DATE TIME TZ DAY2 DATE2 TIME2 TZ2
        # Extract only the FIRST timestamp (fields 3-6), ignore the LAST timestamp (7-10)
        BOOT_TIME=$(echo "$BOOT_LIST" | awk -v off="$OFFSET" '$1 == off {printf "%s %s %s %s", $3, $4, $5, $6}')

        BOOT_DIR="${MULTI_DIR}/boot-${OFFSET}"
        mkdir -p "$BOOT_DIR"

        echo -e "  ${CYAN}[Boot ${BOOT_NUM}/${ANALYZE_COUNT}]${NC} offset=${OFFSET}  id=${BOOT_ID:0:12}...  ${BOOT_TIME}"

        #-----------------------------------------------------------------------
        # Collect raw logs for this boot
        #-----------------------------------------------------------------------
        journalctl --boot="$OFFSET" -k --no-pager > "${BOOT_DIR}/dmesg-full.txt" 2>/dev/null || true
        journalctl --boot="$OFFSET" -k --no-pager 2>/dev/null | grep -iE "amdgpu|drm.*amd|\\[drm\\]" > "${BOOT_DIR}/dmesg-amdgpu.txt" 2>/dev/null || true
        journalctl --boot="$OFFSET" -k --no-pager 2>/dev/null | grep -iE "ring.*timeout|ring.*reset|GPU reset|MODE2|REG_WAIT|optc31|parser.*-125|coredump|wedged|gfx_0|signaled seq|emitted seq|gpu fault|page fault|vm fault|amdgpu_job_timedout" > "${BOOT_DIR}/dmesg-ring-events.txt" 2>/dev/null || true
        journalctl --boot="$OFFSET" -u gdm3 -u gdm --no-pager > "${BOOT_DIR}/gdm-journal.txt" 2>/dev/null || true
        journalctl --boot="$OFFSET" -k --no-pager 2>/dev/null | grep -m1 "Kernel command line:" > "${BOOT_DIR}/cmdline.txt" 2>/dev/null || true
        journalctl --boot="$OFFSET" -k -p warning --no-pager > "${BOOT_DIR}/dmesg-warnings.txt" 2>/dev/null || true
        journalctl --boot="$OFFSET" -k --no-pager 2>/dev/null | grep -iE "amdgpu.*parameter|amdgpu.*unknown|amdgpu.*ignored|modprobe|module" > "${BOOT_DIR}/module-load.txt" 2>/dev/null || true
        journalctl --boot="$OFFSET" -k --no-pager 2>/dev/null | grep -i "nouveau" > "${BOOT_DIR}/dmesg-nouveau.txt" 2>/dev/null || true
        journalctl --boot="$OFFSET" -k --no-pager 2>/dev/null | grep -iE "firmware|ucode|psp" > "${BOOT_DIR}/dmesg-firmware.txt" 2>/dev/null || true
        journalctl --boot="$OFFSET" -k --no-pager 2>/dev/null | grep -iE "dpm|smu|powerplay|gfxoff|clock.*gat|power.*gat" > "${BOOT_DIR}/dmesg-power.txt" 2>/dev/null || true
        journalctl --boot="$OFFSET" -u systemd-logind --no-pager > "${BOOT_DIR}/logind-journal.txt" 2>/dev/null || true

        #-----------------------------------------------------------------------
        # Extract structured data
        #-----------------------------------------------------------------------
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
            local param="$1" default="$2"
            echo "$FULL_CMDLINE" | grep -oP "amdgpu\\.${param}=\\K[^ ]+" 2>/dev/null || echo "$default"
        }

        PARAM_VM_FRAGMENT=$(extract_param "vm_fragment_size" "default")
        PARAM_SEAMLESS=$(extract_param "seamless" "default")
        PARAM_DCDEBUGMASK=$(extract_param "dcdebugmask" "default")
        PARAM_PPFEATUREMASK=$(extract_param "ppfeaturemask" "default")
        PARAM_NORETRY=$(extract_param "noretry" "default")
        PARAM_LOCKUP_TIMEOUT=$(extract_param "lockup_timeout" "default")
        PARAM_SG_DISPLAY=$(extract_param "sg_display" "default")
        PARAM_CG_MASK=$(extract_param "cg_mask" "default")
        PARAM_RUNPM=$(extract_param "runpm" "default")

        # Non-amdgpu params
        PARAM_PCIE_ASPM="default"
        echo "$FULL_CMDLINE" | grep -q "pcie_aspm=off" && PARAM_PCIE_ASPM="off"

        PARAM_IOMMU=$(echo "$FULL_CMDLINE" | grep -oP "iommu=\\K[^ ]+" 2>/dev/null || echo "default")
        PARAM_MAX_CSTATE=$(echo "$FULL_CMDLINE" | grep -oP "processor\\.max_cstate=\\K[^ ]+" 2>/dev/null || echo "default")

        NOUVEAU_BLACKLISTED="no"
        echo "$FULL_CMDLINE" | grep -q "modprobe.blacklist=nouveau" && NOUVEAU_BLACKLISTED="yes"

        CMDLINE_AMDGPU=$(echo "$FULL_CMDLINE" | grep -oP 'amdgpu\.\S+' 2>/dev/null | tr '\n' ' ' || echo "none")

        # Event counts
        # Note: grep -c outputs "0" on no match but exits 1; "|| echo 0" would
        # append a second "0" producing "0\n0" which breaks integer tests.
        # Use: capture output, default empty to 0, strip non-digits.
        OPTC31_COUNT=$(grep -c "optc31_disable_crtc" "$RING_EVENTS" 2>/dev/null) || true
        RING_TIMEOUT_COUNT=$(grep -c "ring gfx_0\.[01]\.0 timeout" "$RING_EVENTS" 2>/dev/null) || true
        OPTC31_COUNT="${OPTC31_COUNT:-0}"; RING_TIMEOUT_COUNT="${RING_TIMEOUT_COUNT:-0}"

        FIRST_TIMEOUT_SEC="none"
        if [ "$RING_TIMEOUT_COUNT" -gt 0 ]; then
            FIRST_TIMEOUT_SEC=$(grep "ring gfx_0\.[01]\.0 timeout" "$DMESG_AMDGPU" 2>/dev/null | head -1 | grep -oP '\[\s*\K[0-9.]+' || echo "unknown")
            [ -z "$FIRST_TIMEOUT_SEC" ] && FIRST_TIMEOUT_SEC=$(grep "ring gfx_0\.[01]\.0 timeout" "$RING_EVENTS" 2>/dev/null | head -1 | grep -oP '\[\s*\K[0-9.]+' || echo "unknown")
        fi

        RING_RESET_FAIL=$(grep -c "Ring gfx_0\.[01]\.0 reset failed\|ring reset failed" "$RING_EVENTS" 2>/dev/null) || true
        MODE2_RESETS=$(grep -c "MODE2 reset" "$RING_EVENTS" 2>/dev/null) || true
        GPU_RESET_SUCCESS=$(grep -c "GPU reset.*succeeded" "$RING_EVENTS" 2>/dev/null) || true
        PARSER_ERRORS=$(grep -c "parser.*-125" "$RING_EVENTS" 2>/dev/null) || true
        RING_RESET_FAIL="${RING_RESET_FAIL:-0}"; MODE2_RESETS="${MODE2_RESETS:-0}"
        GPU_RESET_SUCCESS="${GPU_RESET_SUCCESS:-0}"; PARSER_ERRORS="${PARSER_ERRORS:-0}"

        # GDM status
        GDM_STATUS="unknown"
        if [ -s "$GDM_LOG" ]; then
            GDM_NEVER_REG=$(grep -c "Session never registered\|never registered" "$GDM_LOG" 2>/dev/null) || true
            GDM_ALREADY_DEAD=$(grep -c "already dead\|child.*dead\|Failed with result" "$GDM_LOG" 2>/dev/null) || true
            GDM_STARTED=$(grep -c "Gdm.*started\|GdmManager.*started\|New session\|session opened" "$GDM_LOG" 2>/dev/null) || true
            GDM_NEVER_REG="${GDM_NEVER_REG:-0}"; GDM_ALREADY_DEAD="${GDM_ALREADY_DEAD:-0}"; GDM_STARTED="${GDM_STARTED:-0}"

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

        # Firmware versions
        DMUB_VER=$(grep -oP "DMUB.*version=\\K0x[0-9a-fA-F]+" "$DMESG_AMDGPU" 2>/dev/null | head -1 || echo "N/A")
        VCN_VER=$(grep -oP "VCN firmware Version \\K[^\"]+" "$DMESG_AMDGPU" 2>/dev/null | head -1 || echo "N/A")
        BLOCK_SIZE=$(grep -oP "block size is \\K[0-9]+-bit" "$DMESG_AMDGPU" 2>/dev/null | head -1 || echo "N/A")
        FRAGMENT_SIZE=$(grep -oP "fragment size is \\K[0-9]+-bit" "$DMESG_AMDGPU" 2>/dev/null | head -1 || echo "N/A")

        # Invalid parameter warnings
        grep -i "unknown parameter" "$DMESG_AMDGPU" > "${BOOT_DIR}/invalid-params.txt" 2>/dev/null || true

        # Processes that triggered timeouts
        grep "ring gfx_0\.[01]\.0 timeout" -A1 "$DMESG_AMDGPU" 2>/dev/null | grep "Process" > "${BOOT_DIR}/timeout-processes.txt" 2>/dev/null || true

        # Verdict
        VERDICT="STABLE"
        if [ "$RING_TIMEOUT_COUNT" -gt 0 ]; then
            if [ "$RING_TIMEOUT_COUNT" -ge 3 ]; then
                VERDICT="UNSTABLE(${RING_TIMEOUT_COUNT}x-timeout)"
            else
                VERDICT="DEGRADED(${RING_TIMEOUT_COUNT}x-timeout)"
            fi
        fi
        if echo "$GDM_STATUS" | grep -q "crash-loop"; then
            VERDICT="BROKEN(gdm-crash-loop)"
        fi

        #-----------------------------------------------------------------------
        # Per-boot summary
        #-----------------------------------------------------------------------
        cat > "${BOOT_DIR}/SUMMARY.txt" << EOSUMMARY
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
  cg_mask:          ${PARAM_CG_MASK}
  runpm:            ${PARAM_RUNPM}

--- System Parameters ---
  pcie_aspm:             ${PARAM_PCIE_ASPM}
  iommu:                 ${PARAM_IOMMU}
  processor.max_cstate:  ${PARAM_MAX_CSTATE}
  nouveau blacklisted:   ${NOUVEAU_BLACKLISTED}

--- Ring Timeout Events ---
  optc31 REG_WAIT timeouts: ${OPTC31_COUNT}
  ring gfx timeouts:        ${RING_TIMEOUT_COUNT}
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

        # Append to CSV (pipe-delimited to avoid lockup_timeout comma issue)
        echo "${OFFSET}|${BOOT_ID}|${BOOT_TIME}|${KERNEL}|${CMDLINE_AMDGPU}|${PARAM_VM_FRAGMENT}|${PARAM_SEAMLESS}|${PARAM_DCDEBUGMASK}|${PARAM_PPFEATUREMASK}|${PARAM_NORETRY}|${PARAM_LOCKUP_TIMEOUT}|${PARAM_SG_DISPLAY}|${PARAM_CG_MASK}|${PARAM_RUNPM}|${PARAM_PCIE_ASPM}|${PARAM_IOMMU}|${PARAM_MAX_CSTATE}|${NOUVEAU_BLACKLISTED}|${OPTC31_COUNT}|${RING_TIMEOUT_COUNT}|${FIRST_TIMEOUT_SEC}|${RING_RESET_FAIL}|${MODE2_RESETS}|${GPU_RESET_SUCCESS}|${PARSER_ERRORS}|${GDM_STATUS}|${DMUB_VER}|${VCN_VER}|${BLOCK_SIZE}|${FRAGMENT_SIZE}|${VERDICT}" >> "$CSV_FILE"

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

    #---------------------------------------------------------------------------
    # Generate COMPARISON.txt
    #---------------------------------------------------------------------------
    echo -e "  ${BLUE}Generating comparison table...${NC}"

    COMPARISON="${MULTI_DIR}/COMPARISON.txt"
    cat > "$COMPARISON" << 'EOHEADER'
================================================================================
  MULTI-BOOT AMD iGPU DIAGNOSTIC COMPARISON
  AMD Raphael (GC 10.3.6 / DCN 3.1.5 / PCI 6c:00.0)
  ring gfx timeout analysis across boots (gfx_0.0.0 + gfx_0.1.0)
================================================================================

LEGEND:
  optc31    = REG_WAIT timeout optc31_disable_crtc (DCN CRTC handoff failure)
  ring_to   = ring gfx timeout count (gfx_0.0.0 + gfx_0.1.0)
  1st_to    = seconds from boot to first ring timeout
  reset_f   = ring reset failed count
  mode2     = MODE2 GPU reset count
  parse_err = amdgpu_cs_ioctl parser -125 error count
  gdm       = GDM session status

EOHEADER

    printf "%-6s %-28s %-6s %-7s %-8s %-7s %-6s %-6s %-26s %-10s\n" \
        "Boot" "Time" "optc31" "ring_to" "1st_to" "reset_f" "mode2" "parse" "verdict" "kernel" >> "$COMPARISON"
    printf "%-6s %-28s %-6s %-7s %-8s %-7s %-6s %-6s %-26s %-10s\n" \
        "------" "----------------------------" "------" "-------" "--------" "-------" "------" "------" "--------------------------" "----------" >> "$COMPARISON"

    tail -n +2 "$CSV_FILE" | while IFS='|' read -r offset boot_id boot_time kernel cmdline_amdgpu vm_frag seamless dcdebug ppfeat noretry lockup sg_disp cg_mask runpm pcie_aspm iommu max_cstate nouveau_bl optc31_count ring_to first_to reset_f mode2 gpu_ok parse_err gdm dmub vcn block frag verdict; do
        boot_time_short=$(echo "$boot_time" | sed 's/^ *//;s/ *$//' | cut -c1-28)
        printf "%-6s %-28s %-6s %-7s %-8s %-7s %-6s %-6s %-26s %-10s\n" \
            "$offset" "$boot_time_short" "$optc31_count" "$ring_to" "$first_to" "$reset_f" "$mode2" "$parse_err" "$verdict" "$kernel" >> "$COMPARISON"
    done

    echo "" >> "$COMPARISON"
    echo "================================================================================" >> "$COMPARISON"
    echo "  PARAMETER COMPARISON BY BOOT" >> "$COMPARISON"
    echo "================================================================================" >> "$COMPARISON"
    echo "" >> "$COMPARISON"

    printf "%-6s %-10s %-10s %-14s %-16s %-10s %-20s %-10s %-10s %-16s\n" \
        "Boot" "sg_disp" "vm_frag" "dcdebugmask" "ppfeaturemask" "seamless" "lockup_timeout" "noretry" "cg_mask" "runpm" >> "$COMPARISON"
    printf "%-6s %-10s %-10s %-14s %-16s %-10s %-20s %-10s %-10s %-16s\n" \
        "------" "----------" "----------" "--------------" "----------------" "----------" "--------------------" "----------" "----------" "----------------" >> "$COMPARISON"

    tail -n +2 "$CSV_FILE" | while IFS='|' read -r offset boot_id boot_time kernel cmdline_amdgpu vm_frag seamless dcdebug ppfeat noretry lockup sg_disp cg_mask runpm pcie_aspm iommu max_cstate nouveau_bl optc31_count ring_to first_to reset_f mode2 gpu_ok parse_err gdm dmub vcn block frag verdict; do
        printf "%-6s %-10s %-10s %-14s %-16s %-10s %-20s %-10s %-10s %-16s\n" \
            "$offset" "$sg_disp" "$vm_frag" "$dcdebug" "$ppfeat" "$seamless" "$lockup" "$noretry" "$cg_mask" "$runpm" >> "$COMPARISON"
    done

    echo "" >> "$COMPARISON"
    echo "================================================================================" >> "$COMPARISON"
    echo "  SYSTEM PARAMETERS & FIRMWARE BY BOOT" >> "$COMPARISON"
    echo "================================================================================" >> "$COMPARISON"
    echo "" >> "$COMPARISON"

    printf "%-6s %-12s %-10s %-12s %-10s %-18s %-14s %-12s\n" \
        "Boot" "pcie_aspm" "iommu" "max_cstate" "nouveau" "DMUB" "block_size" "frag_size" >> "$COMPARISON"
    printf "%-6s %-12s %-10s %-12s %-10s %-18s %-14s %-12s\n" \
        "------" "------------" "----------" "------------" "----------" "------------------" "--------------" "------------" >> "$COMPARISON"

    tail -n +2 "$CSV_FILE" | while IFS='|' read -r offset boot_id boot_time kernel cmdline_amdgpu vm_frag seamless dcdebug ppfeat noretry lockup sg_disp cg_mask runpm pcie_aspm iommu max_cstate nouveau_bl optc31_count ring_to first_to reset_f mode2 gpu_ok parse_err gdm dmub vcn block frag verdict; do
        printf "%-6s %-12s %-10s %-12s %-10s %-18s %-14s %-12s\n" \
            "$offset" "$pcie_aspm" "$iommu" "$max_cstate" "$nouveau_bl" "$dmub" "$block" "$frag" >> "$COMPARISON"
    done

    echo "" >> "$COMPARISON"
    echo "================================================================================" >> "$COMPARISON"
    echo "  Per-boot details: ${S}/boot-<N>/SUMMARY.txt" >> "$COMPARISON"
    echo "  CSV (pipe-delimited): ${S}/comparison.csv" >> "$COMPARISON"
    echo "================================================================================" >> "$COMPARISON"

    # Copy comparison to top level
    cp "$COMPARISON" "${RUN_DIR}/COMPARISON.txt"
    cp "$CSV_FILE" "${RUN_DIR}/comparison.csv"
fi

# Check persistent journal
if [ ! -d /var/log/journal ]; then
    echo -e "  ${YELLOW}WARNING: Persistent journal not configured! Only current boot available.${NC}"
    echo -e "  ${YELLOW}  sudo mkdir -p /var/log/journal && sudo systemd-tmpfiles --create --prefix /var/log/journal${NC}"
fi

echo ""

###############################################################################
# META.txt — Run metadata
###############################################################################
echo -e "${BOLD}--- Generating META.txt and ANALYSIS.txt ---${NC}"

KERNEL_VER=$(uname -r 2>/dev/null || echo "unknown")
CMDLINE_NOW=$(cat /proc/cmdline 2>/dev/null || echo "N/A")

cat > "${RUN_DIR}/META.txt" << EOMETA
=== Diagnostic Run Metadata ===
Run:            runLog-$(printf "%02d" "$RUN_NUM")
Timestamp:      $(date '+%Y-%m-%d %H:%M:%S %Z')
Kernel:         ${KERNEL_VER}
Boot cmdline:   ${CMDLINE_NOW}
USB path:       ${RUN_DIR}
Boots analyzed: ${ANALYZE_COUNT:-0}
AMD card:       ${AMD_CARD:-not found}
Script version: diagnostic-full.sh v1.0
EOMETA

###############################################################################
# ANALYSIS.txt — Quick automated analysis
###############################################################################
bash -c '
echo "================================================================"
echo "  QUICK ANALYSIS"
echo "================================================================"
echo ""

echo "--- Kernel ---"
uname -r
echo ""

echo "--- Boot Cmdline ---"
cat /proc/cmdline 2>/dev/null || echo "N/A"
echo ""

echo "--- amdgpu Module Status ---"
if lsmod | grep -q "^amdgpu"; then
    echo "amdgpu: LOADED"
    echo "  Dependencies: $(lsmod | grep "^amdgpu" | awk "{print \$4}")"
else
    echo "amdgpu: NOT LOADED"
    echo "  Probe failure messages:"
    dmesg | grep -i "amdgpu.*fail\|amdgpu.*error\|amdgpu.*unknown" 2>/dev/null | head -5
fi
echo ""

echo "--- Unknown/Invalid Parameters ---"
dmesg | grep -i "unknown parameter" 2>/dev/null || echo "(none found)"
echo ""

echo "--- DRM Card Assignments ---"
for d in /sys/class/drm/card[0-9]; do
    if [ -f "$d/device/vendor" ]; then
        vendor=$(cat "$d/device/vendor" 2>/dev/null)
        device_id=$(cat "$d/device/device" 2>/dev/null)
        driver=$(readlink -f "$d/device/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "none")
        case $vendor in
            0x1002) vname="AMD" ;;
            0x10de) vname="NVIDIA" ;;
            *) vname=$vendor ;;
        esac
        echo "  $(basename $d): $vname ($vendor:$device_id) driver=$driver"
    fi
done 2>/dev/null || echo "  No DRM devices found"
echo ""

echo "--- GPU PCI Devices ---"
lspci -nn 2>/dev/null | grep -iE "VGA|Display|3D" || echo "  (none)"
echo ""

echo "--- Ring Timeout Summary (current boot) ---"
ring_count=$(dmesg 2>/dev/null | grep -c "ring gfx_0\.[01]\.0 timeout") || true
optc_count=$(dmesg 2>/dev/null | grep -c "optc31_disable_crtc") || true
mode2_count=$(dmesg 2>/dev/null | grep -c "MODE2 reset") || true
ring_count="${ring_count:-0}"; optc_count="${optc_count:-0}"; mode2_count="${mode2_count:-0}"
echo "  ring gfx timeouts: $ring_count"
echo "  optc31 REG_WAIT timeouts: $optc_count"
echo "  MODE2 GPU resets: $mode2_count"
if [ "$ring_count" -gt 0 ]; then
    echo "  First timeout:"
    dmesg | grep "ring gfx_0\.[01]\.0 timeout" | head -1
    echo "  Triggering process:"
    dmesg | grep -A1 "ring gfx_0\.[01]\.0 timeout" | grep "Process" | head -1
fi
echo ""

echo "--- GDM Status ---"
systemctl is-active gdm3 2>/dev/null || systemctl is-active gdm 2>/dev/null || echo "unknown"
echo ""

echo "--- systemd-modules-load ---"
systemctl is-active systemd-modules-load.service 2>/dev/null || echo "unknown"
echo ""

echo "--- Key amdgpu sysfs Parameters ---"
if [ -d /sys/module/amdgpu/parameters ]; then
    for p in ppfeaturemask dcdebugmask sg_display vm_fragment_size seamless noretry \
             lockup_timeout cg_mask pg_mask runpm gpu_recovery dc aspm; do
        val=$(cat "/sys/module/amdgpu/parameters/$p" 2>/dev/null || echo "N/A")
        printf "  %-25s = %s\n" "$p" "$val"
    done
else
    echo "  (amdgpu not loaded)"
fi
echo ""

echo "--- modprobe.d/amdgpu.conf ---"
if [ -f /etc/modprobe.d/amdgpu.conf ]; then
    cat /etc/modprobe.d/amdgpu.conf
    echo ""
    echo "  Parameter validation:"
    while IFS= read -r line; do
        param=$(echo "$line" | sed "s/options amdgpu //" | cut -d= -f1)
        if modinfo amdgpu 2>/dev/null | grep -q "parm:.*${param}:"; then
            echo "    $param: VALID"
        else
            echo "    $param: INVALID"
        fi
    done < <(grep "^options amdgpu" /etc/modprobe.d/amdgpu.conf 2>/dev/null)
else
    echo "  (not found)"
fi
echo ""

echo "--- Firmware Versions ---"
dmesg | grep -iE "DMUB.*version=|VCN firmware Version" 2>/dev/null | head -5 || echo "  (not in dmesg)"
echo ""

echo "--- VERDICT ---"
if [ "$ring_count" -eq 0 ] && [ "$optc_count" -eq 0 ]; then
    echo "  STABLE: No ring timeouts or optc31 errors detected"
elif [ "$ring_count" -eq 0 ] && [ "$optc_count" -gt 0 ]; then
    echo "  WARNING: optc31 REG_WAIT timeout(s) but no ring timeouts"
elif [ "$ring_count" -lt 3 ]; then
    echo "  DEGRADED: $ring_count ring timeout(s), system partially functional"
else
    echo "  UNSTABLE: $ring_count ring timeout(s), likely crash-looping"
fi
echo ""
echo "================================================================"
echo "  BIOS SETTINGS TO VERIFY MANUALLY"
echo "================================================================"
echo "  GFXOFF -> Disabled"
echo "    Path: Advanced > AMD CBS > NBIO Common Options > SMU Common Options > GFXOFF"
echo "  Native ASPM -> Enabled"
echo "    Path: Advanced > Onboard Devices Configuration > Native ASPM"
echo "  CPU PCIE ASPM Mode Control -> Disabled"
echo "    Path: Advanced > Onboard Devices Configuration > CPU PCIE ASPM Mode Control"
echo "  UMA Frame Buffer Size -> check current value"
echo "    Path: Advanced > AMD CBS > NBIO > GFX Configuration > UMA Frame Buffer Size"
' > "${RUN_DIR}/ANALYSIS.txt" 2>&1

echo ""

###############################################################################
# Archive
###############################################################################
echo -e "${BOLD}--- Creating archive ---${NC}"
RUN_BASENAME=$(basename "$RUN_DIR")
ARCHIVE="${RUN_DIR}/${RUN_BASENAME}.tar.gz"
tar -czf "$ARCHIVE" -C "$(dirname "$RUN_DIR")" "$RUN_BASENAME" --exclude="*.tar.gz" 2>/dev/null || true
echo -e "  ${GREEN}Archive: ${ARCHIVE}${NC}"
echo ""

###############################################################################
# Final Summary
###############################################################################
echo -e "${BOLD}================================================================${NC}"
echo -e "${GREEN}${BOLD}  Diagnostic Collection Complete!${NC}"
echo -e "${BOLD}================================================================${NC}"
echo ""
echo -e "  ${BOLD}Run:${NC}       runLog-$(printf "%02d" "$RUN_NUM")"
echo -e "  ${BOLD}Location:${NC}  ${RUN_DIR}/"
echo -e "  ${BOLD}Archive:${NC}   ${ARCHIVE}"
echo -e "  ${BOLD}Boots:${NC}     ${ANALYZE_COUNT:-0} analyzed"
echo ""
echo -e "  ${BOLD}Quick start:${NC}"
echo -e "    cat ${RUN_DIR}/ANALYSIS.txt"
echo -e "    cat ${RUN_DIR}/COMPARISON.txt"
echo ""
echo -e "  ${BOLD}Directory layout:${NC}"
echo -e "    01-kernel-system/    Kernel, cmdline, OS, modules"
echo -e "    02-amdgpu-driver/    amdgpu dmesg, sysfs, module info"
echo -e "    03-nvidia-driver/    nvidia state"
echo -e "    04-firmware/         Firmware files, versions, initramfs"
echo -e "    05-display/          GDM, Xorg, Wayland, EDID, connectors"
echo -e "    06-pci-hardware/     lspci, PCIe link, AER, IOMMU"
echo -e "    07-drm-state/        DRM devices, debugfs"
echo -e "    08-power-thermal/    Power mgmt, clocks, temps, hwmon"
echo -e "    09-memory/           VRAM, GTT, system memory"
echo -e "    10-config-files/     GRUB, modprobe, udev, xorg"
echo -e "    11-ring-events/      Ring timeouts, GPU resets, coredumps"
echo -e "    12-journal-full/     Full dmesg + journal (current+prev)"
echo -e "    13-multiboot/        Per-boot comparison across ${ANALYZE_COUNT:-0} boots"
echo ""

# Print the analysis to stdout
echo -e "${BOLD}--- ANALYSIS ---${NC}"
cat "${RUN_DIR}/ANALYSIS.txt"

# Print comparison if it exists
if [ -f "${RUN_DIR}/COMPARISON.txt" ]; then
    echo ""
    echo -e "${BOLD}--- COMPARISON TABLE ---${NC}"
    cat "${RUN_DIR}/COMPARISON.txt"
fi
