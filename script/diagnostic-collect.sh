#!/bin/bash
###############################################################################
# diagnostic-collect.sh
#
# PURPOSE: Collect comprehensive system diagnostics for troubleshooting display
#          instability, amdgpu probe failures, and systemd-modules-load failures
#          on the dual-GPU ML workstation (Raphael iGPU + RTX 4090).
#
# WHAT THIS COLLECTS:
#   1. Kernel version + module parameters + loaded modules
#   2. systemd-modules-load.service status + journal
#   3. amdgpu driver status: dmesg, parameters, firmware, sysfs
#   4. nvidia driver status: dmesg, loaded state
#   5. GRUB configuration + /proc/cmdline
#   6. modprobe.d configs (amdgpu.conf, nvidia.conf, blacklist)
#   7. modules-load.d + initramfs module list
#   8. X11/GDM/display status
#   9. PCI topology (full lspci for both GPUs)
#  10. DRM device state
#  11. Hardware info: CPU, memory, firmware
#  12. Full dmesg (last boot)
#  13. journalctl for current + previous boot
#
# OUTPUT: Creates /tmp/ml-diag-<timestamp>/ with all collected data
#         and a tarball /tmp/ml-diag-<timestamp>.tar.gz
#
# USAGE: sudo bash diagnostic-collect.sh
#
# SYSTEM: Ryzen 9 7950X | X670E Hero | RTX 4090 + Raphael iGPU
###############################################################################

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}ERROR: This script must be run as root (sudo).${NC}"
    exit 1
fi

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
DIAG_DIR="/tmp/ml-diag-${TIMESTAMP}"
mkdir -p "$DIAG_DIR"

echo -e "${BOLD}================================================================${NC}"
echo -e "${BOLD}  ML Workstation Diagnostic Collector${NC}"
echo -e "${BOLD}  Output: ${DIAG_DIR}/${NC}"
echo -e "${BOLD}================================================================${NC}"
echo ""

collect() {
    local label="$1"
    local file="$2"
    shift 2
    echo -e "  ${BLUE}[COLLECT]${NC} $label"
    "$@" > "${DIAG_DIR}/${file}" 2>&1 || true
}

collect_cat() {
    local label="$1"
    local file="$2"
    local src="$3"
    echo -e "  ${BLUE}[COLLECT]${NC} $label"
    if [ -f "$src" ]; then
        cat "$src" > "${DIAG_DIR}/${file}" 2>&1
    elif [ -d "$src" ]; then
        ls -la "$src" > "${DIAG_DIR}/${file}" 2>&1
    else
        echo "NOT FOUND: $src" > "${DIAG_DIR}/${file}"
    fi
}

###############################################################################
echo -e "\n${BOLD}--- 1. Kernel & System Info ---${NC}"
###############################################################################
collect "Kernel version" "kernel-version.txt" uname -a
collect "Kernel release" "kernel-release.txt" uname -r
collect "OS release" "os-release.txt" cat /etc/os-release
collect "Uptime" "uptime.txt" uptime
collect "Boot ID" "boot-id.txt" cat /proc/sys/kernel/random/boot_id

# What kernel packages are installed
collect "Installed kernel packages" "kernel-packages.txt" dpkg -l linux-image-\* linux-headers-\* linux-modules-\*

###############################################################################
echo -e "\n${BOLD}--- 2. systemd-modules-load.service ---${NC}"
###############################################################################
collect "systemd-modules-load status" "modules-load-status.txt" systemctl status systemd-modules-load.service
collect "systemd-modules-load journal (this boot)" "modules-load-journal.txt" journalctl -u systemd-modules-load.service -b --no-pager
collect "systemd-modules-load journal (previous boot)" "modules-load-journal-prev.txt" journalctl -u systemd-modules-load.service -b -1 --no-pager

###############################################################################
echo -e "\n${BOLD}--- 3. Module Configuration ---${NC}"
###############################################################################
collect_cat "/etc/modules-load.d/gpu.conf" "modules-load-d-gpu.conf" /etc/modules-load.d/gpu.conf
collect "All files in /etc/modules-load.d/" "modules-load-d-ls.txt" ls -la /etc/modules-load.d/
collect "All content in /etc/modules-load.d/" "modules-load-d-all.txt" bash -c 'for f in /etc/modules-load.d/*.conf; do echo "=== $f ==="; cat "$f" 2>/dev/null; echo ""; done'
collect_cat "/etc/initramfs-tools/modules" "initramfs-modules.txt" /etc/initramfs-tools/modules

###############################################################################
echo -e "\n${BOLD}--- 4. modprobe.d Configuration ---${NC}"
###############################################################################
collect "All files in /etc/modprobe.d/" "modprobe-d-ls.txt" ls -la /etc/modprobe.d/
collect "All modprobe.d content" "modprobe-d-all.txt" bash -c 'for f in /etc/modprobe.d/*.conf; do echo "=== $f ==="; cat "$f" 2>/dev/null; echo ""; done'
collect_cat "amdgpu.conf" "modprobe-d-amdgpu.conf" /etc/modprobe.d/amdgpu.conf
collect_cat "nvidia.conf" "modprobe-d-nvidia.conf" /etc/modprobe.d/nvidia.conf
collect_cat "blacklist-nouveau.conf" "modprobe-d-blacklist-nouveau.conf" /etc/modprobe.d/blacklist-nouveau.conf

# What parameters does the running kernel's amdgpu module actually accept?
collect "amdgpu module info (modinfo)" "modinfo-amdgpu.txt" modinfo amdgpu
collect "amdgpu accepted parameters" "amdgpu-params-accepted.txt" bash -c 'modinfo amdgpu 2>/dev/null | grep "^parm:" | sort'
collect "nvidia module info (modinfo)" "modinfo-nvidia.txt" modinfo nvidia

###############################################################################
echo -e "\n${BOLD}--- 5. amdgpu Driver Diagnostics ---${NC}"
###############################################################################

# dmesg filtered for amdgpu
collect "dmesg: amdgpu" "dmesg-amdgpu.txt" bash -c 'dmesg | grep -i amdgpu'
collect "dmesg: drm" "dmesg-drm.txt" bash -c 'dmesg | grep -i drm'
collect "dmesg: firmware" "dmesg-firmware.txt" bash -c 'dmesg | grep -i firmware'

# amdgpu module state
collect "amdgpu in lsmod" "lsmod-amdgpu.txt" bash -c 'lsmod | grep -i amdgpu'
collect "amdgpu sysfs parameters" "amdgpu-sysfs-params.txt" bash -c 'if [ -d /sys/module/amdgpu/parameters ]; then for p in /sys/module/amdgpu/parameters/*; do echo "$(basename $p) = $(cat $p 2>/dev/null)"; done; else echo "amdgpu module not loaded - no sysfs parameters"; fi'

# Check if gfx_off is a valid parameter for this kernel's amdgpu
collect "gfx_off parameter check" "amdgpu-gfx-off-check.txt" bash -c '
echo "=== Is gfx_off a valid amdgpu parameter? ==="
if modinfo amdgpu 2>/dev/null | grep -q "parm:.*gfx_off"; then
    echo "YES: gfx_off is a recognized parameter"
    modinfo amdgpu 2>/dev/null | grep "parm:.*gfx_off"
else
    echo "NO: gfx_off is NOT a recognized parameter for this kernel amdgpu module"
    echo ""
    echo "Available amdgpu parameters containing gfx:"
    modinfo amdgpu 2>/dev/null | grep -i "parm:.*gfx" || echo "  (none found)"
    echo ""
    echo "All amdgpu parameters:"
    modinfo amdgpu 2>/dev/null | grep "^parm:" | sort
fi
echo ""
echo "=== Kernel version ==="
uname -r
echo ""
echo "=== amdgpu module file ==="
modinfo amdgpu 2>/dev/null | grep "^filename:" || echo "amdgpu module not found"
'

# amdgpu firmware files
collect "amdgpu firmware (ls)" "amdgpu-firmware-ls.txt" bash -c 'ls -la /lib/firmware/amdgpu/ 2>/dev/null | head -50; echo "..."; ls /lib/firmware/amdgpu/ 2>/dev/null | wc -l; echo " total files"'
collect "amdgpu firmware for gfx1036 (Raphael)" "amdgpu-firmware-raphael.txt" bash -c 'ls -la /lib/firmware/amdgpu/*gc_10_3_7* /lib/firmware/amdgpu/*gfx1036* /lib/firmware/amdgpu/*raphael* 2>/dev/null || echo "No Raphael-specific firmware found"; echo ""; echo "gc_10_3 firmware:"; ls -la /lib/firmware/amdgpu/gc_10_3* 2>/dev/null || echo "  none"'

# Try loading amdgpu manually to get verbose error
collect "modprobe amdgpu --dry-run" "modprobe-amdgpu-dryrun.txt" modprobe --dry-run -v amdgpu
collect "modprobe amdgpu verbose (WILL FAIL if already loaded or broken)" "modprobe-amdgpu-verbose.txt" bash -c 'modprobe -v amdgpu 2>&1 || echo "modprobe failed with exit code $?"'

###############################################################################
echo -e "\n${BOLD}--- 6. NVIDIA Driver Diagnostics ---${NC}"
###############################################################################
collect "dmesg: nvidia" "dmesg-nvidia.txt" bash -c 'dmesg | grep -i nvidia'
collect "nvidia in lsmod" "lsmod-nvidia.txt" bash -c 'lsmod | grep -i nvidia'
collect "nvidia-smi" "nvidia-smi.txt" nvidia-smi
collect "nvidia-smi -q (full query)" "nvidia-smi-q.txt" nvidia-smi -q
collect "nouveau in lsmod" "lsmod-nouveau.txt" bash -c 'lsmod | grep -i nouveau || echo "nouveau not loaded (good)"'

###############################################################################
echo -e "\n${BOLD}--- 7. GRUB & Kernel Parameters ---${NC}"
###############################################################################
collect_cat "/proc/cmdline" "proc-cmdline.txt" /proc/cmdline
collect_cat "/etc/default/grub" "etc-default-grub.txt" /etc/default/grub
collect "GRUB_CMDLINE from grub" "grub-cmdline.txt" bash -c 'grep "GRUB_CMDLINE" /etc/default/grub'

###############################################################################
echo -e "\n${BOLD}--- 8. PCI Topology ---${NC}"
###############################################################################
collect "lspci (all VGA/Display/3D)" "lspci-gpu.txt" bash -c 'lspci | grep -iE "VGA|Display|3D"'
collect "lspci -v (AMD iGPU detailed)" "lspci-amd-igpu.txt" bash -c 'AMD_BUS=$(lspci | grep -i "AMD.*VGA\|ATI.*VGA\|Radeon" | head -1 | awk "{print \$1}"); if [ -n "$AMD_BUS" ]; then lspci -vvv -s "$AMD_BUS"; else echo "AMD iGPU not found in lspci"; fi'
collect "lspci -v (NVIDIA detailed)" "lspci-nvidia.txt" bash -c 'NV_BUS=$(lspci | grep -i "NVIDIA" | head -1 | awk "{print \$1}"); if [ -n "$NV_BUS" ]; then lspci -vvv -s "$NV_BUS"; else echo "NVIDIA GPU not found in lspci"; fi'
collect "lspci full tree" "lspci-tree.txt" lspci -tv

###############################################################################
echo -e "\n${BOLD}--- 9. DRM & Display ---${NC}"
###############################################################################
collect "DRM devices" "drm-devices.txt" bash -c 'for d in /sys/class/drm/card*; do echo "=== $(basename $d) ==="; cat "$d/device/vendor" 2>/dev/null && echo " (vendor)"; cat "$d/device/device" 2>/dev/null && echo " (device)"; cat "$d/device/driver_override" 2>/dev/null && echo " (driver_override)"; ls -la "$d/device/driver" 2>/dev/null; echo ""; done'
collect "DRM card list" "drm-card-ls.txt" ls -la /sys/class/drm/
collect "GDM status" "gdm-status.txt" systemctl status gdm
collect "GDM journal (this boot)" "gdm-journal.txt" journalctl -u gdm -b --no-pager
collect "GDM journal (previous boot)" "gdm-journal-prev.txt" journalctl -u gdm -b -1 --no-pager
collect "Xorg log" "xorg-log.txt" bash -c 'cat /var/log/Xorg.0.log 2>/dev/null || echo "No Xorg log found"'
collect "Xorg log (old)" "xorg-log-old.txt" bash -c 'cat /var/log/Xorg.0.log.old 2>/dev/null || echo "No old Xorg log found"'
collect_cat "X11 GPU config" "xorg-10-gpu.conf" /etc/X11/xorg.conf.d/10-gpu.conf

# GDM custom config
collect_cat "GDM custom.conf" "gdm-custom.conf" /etc/gdm3/custom.conf

###############################################################################
echo -e "\n${BOLD}--- 10. Systemd & Service State ---${NC}"
###############################################################################
collect "Failed units" "systemd-failed.txt" systemctl --failed --no-pager
collect "gpu-manager status" "gpu-manager-status.txt" systemctl status gpu-manager
collect "nvidia-persistenced status" "nvidia-persistenced-status.txt" systemctl status nvidia-persistenced

###############################################################################
echo -e "\n${BOLD}--- 11. Full Logs ---${NC}"
###############################################################################
collect "Full dmesg" "dmesg-full.txt" dmesg
collect "dmesg: errors and warnings" "dmesg-errors.txt" bash -c 'dmesg --level=err,warn'
collect "journalctl this boot (last 2000 lines)" "journal-boot.txt" bash -c 'journalctl -b --no-pager | tail -2000'
collect "journalctl previous boot (last 2000 lines)" "journal-boot-prev.txt" bash -c 'journalctl -b -1 --no-pager 2>/dev/null | tail -2000'

# Specifically look for module load errors
collect "dmesg: module errors" "dmesg-module-errors.txt" bash -c 'dmesg | grep -iE "unknown parameter|failed|error|probe.*fail|module.*fail|firmware.*fail"'

###############################################################################
echo -e "\n${BOLD}--- 12. Hardware Info ---${NC}"
###############################################################################
collect "CPU info" "cpuinfo.txt" bash -c 'head -30 /proc/cpuinfo'
collect "Memory info" "meminfo.txt" bash -c 'head -10 /proc/meminfo'
collect "DMI system info" "dmi-system.txt" dmidecode -t system
collect "DMI BIOS info" "dmi-bios.txt" dmidecode -t bios
collect "IOMMU groups" "iommu-groups.txt" bash -c 'for d in /sys/kernel/iommu_groups/*/devices/*; do n=$(echo "$d" | cut -d/ -f5); echo "Group $n: $(lspci -nns ${d##*/} 2>/dev/null || echo ${d##*/})"; done 2>/dev/null | sort -t: -k1 -n | head -30'

###############################################################################
echo -e "\n${BOLD}--- 13. Quick Analysis ---${NC}"
###############################################################################

# Write a quick analysis summary
cat > "${DIAG_DIR}/ANALYSIS.txt" << 'ANALYSIS_SCRIPT'
#!/bin/bash
# Auto-generated analysis of collected diagnostics
ANALYSIS_SCRIPT

bash -c "
echo '=== QUICK ANALYSIS ==='
echo ''

# Kernel version
echo '--- Kernel ---'
uname -r
echo ''

# Is amdgpu loaded?
echo '--- amdgpu status ---'
if lsmod | grep -q '^amdgpu'; then
    echo 'amdgpu: LOADED'
else
    echo 'amdgpu: NOT LOADED'
    echo 'Probe failure reason:'
    dmesg | grep -i 'amdgpu.*fail\|amdgpu.*error\|amdgpu.*unknown' 2>/dev/null
fi
echo ''

# Check for unknown parameters
echo '--- Unknown/Invalid Parameters ---'
dmesg | grep -i 'unknown parameter' 2>/dev/null || echo '(none found)'
echo ''

# Check if gfx_off is valid
echo '--- gfx_off parameter validity ---'
if modinfo amdgpu 2>/dev/null | grep -q 'parm:.*gfx_off'; then
    echo 'gfx_off: VALID parameter'
else
    echo 'gfx_off: NOT A VALID PARAMETER for this kernel'
    echo 'This is likely causing the amdgpu probe failure (error -22 = EINVAL)'
    echo ''
    echo 'Similar parameters available:'
    modinfo amdgpu 2>/dev/null | grep -i 'parm:.*gfx' || echo '  (none with gfx in name)'
fi
echo ''

# GPU detection
echo '--- GPU PCI devices ---'
lspci | grep -iE 'VGA|Display|3D'
echo ''

# systemd-modules-load
echo '--- systemd-modules-load ---'
systemctl is-active systemd-modules-load.service 2>/dev/null || echo 'Service status unknown'
echo ''

# GDM
echo '--- GDM ---'
systemctl is-active gdm 2>/dev/null || echo 'GDM status unknown'
echo ''

# Card assignments
echo '--- DRM card assignments ---'
for d in /sys/class/drm/card[0-9]; do
    if [ -f \"\$d/device/vendor\" ]; then
        vendor=\$(cat \"\$d/device/vendor\" 2>/dev/null)
        case \$vendor in
            0x1002) vname='AMD' ;;
            0x10de) vname='NVIDIA' ;;
            *) vname=\$vendor ;;
        esac
        echo \"\$(basename \$d): \$vname (\$vendor)\"
    fi
done 2>/dev/null || echo 'No DRM devices found'
echo ''

echo '--- Modprobe config issues ---'
if [ -f /etc/modprobe.d/amdgpu.conf ]; then
    echo 'amdgpu.conf parameters set:'
    grep '^options' /etc/modprobe.d/amdgpu.conf 2>/dev/null
    echo ''
    echo 'Checking each parameter against kernel module:'
    while IFS= read -r line; do
        param=\$(echo \"\$line\" | sed 's/options amdgpu //' | cut -d= -f1)
        if modinfo amdgpu 2>/dev/null | grep -q \"parm:.*\${param}:\"; then
            echo \"  \$param: VALID\"
        else
            echo \"  \$param: INVALID (unknown to this kernel — will cause errors)\"
        fi
    done < <(grep '^options amdgpu' /etc/modprobe.d/amdgpu.conf 2>/dev/null)
fi

echo ''
echo '--- BIOS-ONLY SETTINGS (verify manually) ---'
echo '  GFXOFF → Disabled (B22)'
echo '    Path: Advanced → AMD CBS → NBIO Common Options → SMU Common Options → GFXOFF'
echo '    WHY: Most authoritative GFXOFF disable. Prevents ring timeouts at hardware level.'
echo '  Native ASPM → Enabled (B7)'
echo '    Path: Advanced → Onboard Devices Configuration → Native ASPM'
echo '    WHY: Hands ASPM control to Linux via ACPI _OSC. BIOS-managed ASPM is broken with NVIDIA.'
echo '  CPU PCIE ASPM Mode Control → Disabled (B7b)'
echo '    Path: Advanced → Onboard Devices Configuration → CPU PCIE ASPM Mode Control'
echo '    WHY: Kills L0s/L1 on GPU CPU-direct lanes. L0s causes Xid 79 "fallen off the bus".'
" > "${DIAG_DIR}/ANALYSIS.txt" 2>&1

echo ""
echo -e "${BOLD}--- Analysis Summary ---${NC}"
cat "${DIAG_DIR}/ANALYSIS.txt"

###############################################################################
# Create tarball
###############################################################################
TARBALL="/tmp/ml-diag-${TIMESTAMP}.tar.gz"
tar -czf "$TARBALL" -C /tmp "ml-diag-${TIMESTAMP}/" 2>/dev/null

echo ""
echo -e "${BOLD}================================================================${NC}"
echo -e "${GREEN}${BOLD}  Diagnostic collection complete!${NC}"
echo -e "${BOLD}================================================================${NC}"
echo ""
echo "  Directory: ${DIAG_DIR}/"
echo "  Tarball:   ${TARBALL}"
echo ""
echo "  Key files to check first:"
echo "    ANALYSIS.txt                — Quick automated analysis"
echo "    dmesg-amdgpu.txt            — amdgpu driver messages"
echo "    dmesg-module-errors.txt     — All module/driver errors"
echo "    amdgpu-gfx-off-check.txt   — Is gfx_off valid for this kernel?"
echo "    amdgpu-params-accepted.txt  — All valid amdgpu parameters"
echo "    modules-load-journal.txt    — systemd-modules-load failure details"
echo "    modprobe-d-amdgpu.conf      — Current amdgpu modprobe config"
echo ""
echo "  To share: copy ${TARBALL} to another machine"
echo ""
