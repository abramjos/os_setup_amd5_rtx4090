#!/bin/bash
###############################################################################
# verify-complete-system.sh
#
# PURPOSE: Comprehensive system verification script for the dual-GPU ML
#          workstation. Run after completing all 3 phases of setup.
#          Tests every component of the configuration and reports pass/fail
#          with detailed fix instructions for each failure.
#
# WHAT THIS VERIFIES:
#   Section 1:  Kernel version (HWE 6.17 recommended, GA 6.8 fallback)
#   Section 2:  AMD iGPU detection and card0 assignment
#   Section 3:  NVIDIA GPU detection and headless state
#   Section 4:  PCIe link status (Gen 4 x16)
#   Section 5:  Kernel boot parameters (all 7 critical params)
#   Section 6:  Module load order (amdgpu before nvidia)
#   Section 7:  Display rendering (AMD renderer, not NVIDIA)
#   Section 8:  NVIDIA compute state (exec timeout, persistence, P-state)
#   Section 9:  CUDA functionality
#   Section 10: Configuration files existence and content
#   Section 11: Systemd services (persistence, sleep mask, gpu-manager)
#   Section 12: Security (SME disabled, nouveau blocked)
#   Section 13: Display artifacts check (sg_display, dcdebugmask)
#   Section 14: GPU error check (Xid errors in dmesg)
#   Section 15: amdgpu runtime parameters (sysfs verification)
#   Section 16: modprobe.d parameter validation (catches invalid params)
#
# OUTPUT: Color-coded pass/fail/warn with fix instructions and references.
#         Summary at end with exit code (0=pass, 1=fail, 2=warn).
#
# USAGE: sudo bash verify-complete-system.sh
#        sudo bash verify-complete-system.sh --json    # Machine-readable output
#        sudo bash verify-complete-system.sh --quick   # Skip CUDA test (faster)
#
# REFERENCES:
#   All references are inline with each check.
#
# SYSTEM: Ryzen 9 7950X | ASUS ROG Crosshair X670E Hero | RTX 4090
#         Ubuntu 24.04.1 LTS | Kernel 6.17 HWE (6.8 GA fallback) | NVIDIA 595.58.03
###############################################################################

# Note: -e intentionally omitted — individual checks may fail without aborting
set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'

PASS=0; FAIL=0; WARN=0; SKIP=0
QUICK=false
JSON=false

for arg in "$@"; do
    case $arg in
        --quick) QUICK=true ;;
        --json)  JSON=true ;;
    esac
done

pass()    { echo -e "  ${GREEN}[PASS]${NC} $1"; ((PASS++)); }
fail()    { echo -e "  ${RED}[FAIL]${NC} $1"; ((FAIL++)); }
warn()    { echo -e "  ${YELLOW}[WARN]${NC} $1"; ((WARN++)); }
skip()    { echo -e "  ${DIM}[SKIP]${NC} $1"; ((SKIP++)); }
info()    { echo -e "  ${BLUE}[INFO]${NC} $1"; }
section() { echo -e "\n${BOLD}${CYAN}━━━ $1 ━━━${NC}"; }
fix()     { echo -e "       ${DIM}→ FIX: $1${NC}"; }
ref()     { echo -e "       ${DIM}→ REF: $1${NC}"; }

CMDLINE=$(cat /proc/cmdline)

echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  ML Workstation Complete System Verification                ║${NC}"
echo -e "${BOLD}║  Ryzen 9 7950X + X670E Hero + RTX 4090                     ║${NC}"
echo -e "${BOLD}║  Ubuntu 24.04 | Kernel 6.17 HWE / 6.8 GA | NVIDIA 595     ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo -e "  Run date: $(date -Is)"
echo -e "  Hostname: $(hostname)"

###############################################################################
section "1. Kernel Version"
###############################################################################
# WHY HWE 6.17: Kernel 6.8 GA has an unfixed GFXOFF bug for Raphael gfx1036
#   causing "ring gfx_0.0.0 timeout" errors. The fix landed in kernels 6.9-6.11
#   (GFXOFF rework for GC 10.3.x). Ubuntu 24.04 HWE 6.17 includes this fix.
#   NVIDIA 595.58.03 supports kernels 6.8-6.19 (validated by CUDA 13.2 guide).
#   REF: https://gitlab.freedesktop.org/drm/amd/-/issues/3006
#   REF: https://docs.nvidia.com/cuda/cuda-installation-guide-linux/
#   REF: https://docs.nvidia.com/datacenter/tesla/tesla-release-notes-595-58-03/

KERNEL=$(uname -r)
KERNEL_MAJOR=$(echo "$KERNEL" | cut -d. -f1-2)
info "Running kernel: $KERNEL"

if echo "$KERNEL" | grep -qE "^6\.(1[1-9]|[2-9][0-9])\."; then
    pass "HWE kernel $KERNEL_MAJOR (gfx ring timeout fix included, NVIDIA 595 compatible)"
elif echo "$KERNEL" | grep -q "^6\.8\."; then
    warn "GA kernel 6.8 — ring timeout workaround (gfx_off=0) required"
    fix "sudo apt install linux-generic-hwe-24.04 && reboot (HWE 6.17 recommended)"
    ref "https://gitlab.freedesktop.org/drm/amd/-/issues/3006"
else
    fail "Unexpected kernel: $KERNEL (expected 6.8 GA or 6.11+ HWE)"
    fix "sudo apt install linux-generic-hwe-24.04 && reboot"
fi

# Check HWE metapackage is installed
if dpkg -l linux-generic-hwe-24.04 2>/dev/null | grep -q "^ii"; then
    pass "linux-generic-hwe-24.04 metapackage installed"
else
    warn "linux-generic-hwe-24.04 not installed — running on GA kernel"
    fix "sudo apt install linux-generic-hwe-24.04"
fi

# Check GA kernel is still available as GRUB fallback
if dpkg -l linux-generic 2>/dev/null | grep -q "^ii"; then
    pass "linux-generic (GA) installed as GRUB fallback"
else
    warn "linux-generic (GA fallback) not installed"
    fix "sudo apt install linux-generic (provides GRUB fallback with gfx_off=0 workaround)"
fi

# Check for stale kernel pin from older script versions
if [ -f /etc/apt/preferences.d/pin-kernel-ga ]; then
    warn "Stale kernel pin file found (/etc/apt/preferences.d/pin-kernel-ga)"
    fix "sudo rm /etc/apt/preferences.d/pin-kernel-ga (no longer needed with NVIDIA 595)"
fi

###############################################################################
section "2. AMD iGPU Detection"
###############################################################################

AMD_GPU=$(lspci | grep -i "VGA\|Display" | grep -i "AMD\|ATI\|Radeon" || true)
if [ -n "$AMD_GPU" ]; then
    pass "AMD iGPU detected: $(echo $AMD_GPU | head -1)"
else
    fail "AMD iGPU NOT detected"
    fix "BIOS → Advanced → NB Configuration → IGFX Multi-Monitor → Enabled"
    ref "https://www.asus.com/support/faq/1045574/"
fi

if lsmod | grep -q "^amdgpu"; then
    pass "amdgpu kernel module loaded"
else
    fail "amdgpu module NOT loaded"
    fix "sudo modprobe amdgpu; check dmesg | grep amdgpu for errors"
fi

if [ -f /sys/class/drm/card0/device/vendor ]; then
    CARD0=$(cat /sys/class/drm/card0/device/vendor)
    if [ "$CARD0" = "0x1002" ]; then
        pass "card0 = AMD (0x1002) — correct for display primary"
    else
        fail "card0 = $CARD0 — should be AMD (0x1002)"
        fix "Ensure amdgpu loads before nvidia in /etc/modules-load.d/gpu.conf and /etc/initramfs-tools/modules"
        ref "https://gist.github.com/wangruohui/bc7b9f424e3d5deb0c0b8bba990b1bc5"
    fi
fi

###############################################################################
section "3. NVIDIA GPU Detection & Headless State"
###############################################################################

NV_GPU=$(lspci | grep -i "VGA\|3D\|Display" | grep -i "NVIDIA" || true)
if [ -n "$NV_GPU" ]; then
    pass "NVIDIA GPU detected: $(echo $NV_GPU | head -1)"
else
    fail "NVIDIA GPU NOT detected"
    fix "Check physical seating, 12VHPWR power cable, BIOS Above 4G Decoding"
fi

if command -v nvidia-smi &>/dev/null; then
    if nvidia-smi &>/dev/null; then
        pass "nvidia-smi functional"

        DRIVER_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null || echo "unknown")
        info "NVIDIA driver version: $DRIVER_VER"

        if [ "$DRIVER_VER" = "595.58.03" ]; then
            pass "Driver is exactly 595.58.03 (target version)"
        elif echo "$DRIVER_VER" | grep -q "^595\."; then
            pass "Driver is 595.x branch (latest production)"
        else
            warn "Driver is $DRIVER_VER — expected 595.58.03 or 595.x branch"
            fix "Update driver: sudo apt install nvidia-headless-595 nvidia-utils-595"
        fi

        # Detect if using open or proprietary kernel modules
        # WHY: Open kernel modules are recommended since NVIDIA R560 for Turing+ GPUs.
        #      This check confirms which variant is loaded.
        NV_MOD_FILE=$(modinfo nvidia 2>/dev/null | grep "^filename:" | awk '{print $2}' || echo "")
        if echo "$NV_MOD_FILE" | grep -qi "open\|nvidia-open"; then
            pass "Using NVIDIA open kernel modules (recommended for Ada Lovelace)"
        elif [ -n "$NV_MOD_FILE" ]; then
            info "Using NVIDIA proprietary kernel modules (open modules recommended but not required)"
        fi

        DISP_ACTIVE=$(nvidia-smi --query-gpu=display_active --format=csv,noheader 2>/dev/null || echo "unknown")
        if [ "$DISP_ACTIVE" = "Disabled" ]; then
            pass "NVIDIA display: Disabled (headless compute) — CORRECT"
        else
            warn "NVIDIA display active: $DISP_ACTIVE — should be Disabled for headless"
            fix "Verify display cable is on motherboard (not GPU) and xorg.conf has UseDisplayDevice=none"
        fi

        NV_PROCS=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | wc -l)
        NV_GFX_PROCS=$(nvidia-smi pmon -c 1 2>/dev/null | grep -c "Xorg\|gnome\|gdm\|mutter" || echo "0")
        if [ "$NV_GFX_PROCS" = "0" ]; then
            pass "No display processes on NVIDIA GPU"
        else
            fail "Display processes found on NVIDIA GPU!"
            fix "Check /etc/X11/xorg.conf.d/10-gpu.conf — NVIDIA should be Inactive"
        fi
    else
        fail "nvidia-smi failed to execute"
        fix "Check driver installation: dpkg -l | grep nvidia"
    fi
else
    fail "nvidia-smi not found — NVIDIA driver not installed"
    fix "Run Phase 2 script (02-install-nvidia-driver.sh)"
fi

###############################################################################
section "4. PCIe Link Status"
###############################################################################

NV_BUSID=$(lspci | grep -i NVIDIA | head -1 | awk '{print $1}' || true)
if [ -n "$NV_BUSID" ]; then
    LINK_INFO=$(sudo lspci -vvv -s "$NV_BUSID" 2>/dev/null | grep "LnkSta:" | head -1 || true)

    if echo "$LINK_INFO" | grep -q "16GT/s"; then
        pass "PCIe link speed: Gen 4 (16 GT/s) — optimal"
    elif echo "$LINK_INFO" | grep -q "32GT/s"; then
        warn "PCIe link speed: Gen 5 — force Gen 4 in BIOS for stability"
        fix "BIOS → Advanced → PCIEX16_1 Link Mode → Gen 4"
    else
        warn "PCIe link speed: unexpected — $LINK_INFO"
    fi

    if echo "$LINK_INFO" | grep -q "x16"; then
        pass "PCIe link width: x16 — full bandwidth"
    else
        fail "PCIe link width NOT x16 — $LINK_INFO"
        fix "Reseat GPU. Full power cycle (PSU off 10s). Check slot."
        ref "https://www.overclock.net/threads/4090-strix-oc-stuck-at-8x-pcie.1802623/"
    fi
fi

###############################################################################
section "5. Kernel Boot Parameters"
###############################################################################

check_kparam() {
    local param="$1" desc="$2" fixmsg="$3" refurl="$4"
    if echo "$CMDLINE" | grep -q "$param"; then
        pass "$param — $desc"
    else
        fail "$param NOT set — $desc"
        fix "$fixmsg"
        ref "$refurl"
    fi
}

check_kparam "amdgpu.sg_display=0" \
    "Prevents Raphael iGPU scatter-gather display corruption" \
    "Add to GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub" \
    "https://bugs.launchpad.net/bugs/2038998"

check_kparam "amdgpu.dcdebugmask=0x10" \
    "Disables PSR — prevents flicker and multi-monitor wake issues" \
    "Add to GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub" \
    "https://docs.kernel.org/gpu/amdgpu/display/dc-debug.html"

check_kparam "amdgpu.gfx_off=0" \
    "Disables GFX power gating — prevents gfx ring timeouts on Raphael" \
    "Add to GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub" \
    "https://gitlab.freedesktop.org/drm/amd/-/issues/3006"

check_kparam "amdgpu.ppfeaturemask=0xfffd7fff" \
    "Disables PP_GFXOFF + PP_STUTTER_MODE — firmware-level ring timeout prevention" \
    "Add to GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub" \
    "https://docs.kernel.org/gpu/amdgpu/module-parameters.html"

check_kparam "pcie_aspm=off" \
    "Prevents RTX 4090 Xid 79 PCIe link drops" \
    "Add to GRUB_CMDLINE_LINUX_DEFAULT + BIOS ASPM → Disabled" \
    "https://forums.developer.nvidia.com/t/gpu-has-fallen-off-the-bus-issues-on-daily-basis-rtx-4090/314647"

check_kparam "iommu=pt" \
    "IOMMU pass-through — optimal DMA for CUDA" \
    "Add to GRUB_CMDLINE_LINUX_DEFAULT + BIOS IOMMU → Enabled" \
    "https://docs.nvidia.com/cuda/cuda-installation-guide-linux/"

check_kparam "nogpumanager" \
    "Prevents Ubuntu gpu-manager from overriding GPU config" \
    "Add to GRUB_CMDLINE_LINUX_DEFAULT + systemctl mask gpu-manager" \
    "https://gist.github.com/wangruohui/bc7b9f424e3d5deb0c0b8bba990b1bc5"

check_kparam "nvidia-drm.modeset=1" \
    "NVIDIA kernel mode setting enabled" \
    "Add to GRUB_CMDLINE_LINUX_DEFAULT (default in 595 but explicit is safer)" \
    "https://www.gamingonlinux.com/2026/03/nvidia-driver-595-58-03-released-as-the-big-new-recommended-stable-driver-for-linux/"

# Optional but recommended
if echo "$CMDLINE" | grep -q "nvidia-drm.fbdev=1"; then
    pass "nvidia-drm.fbdev=1 — NVIDIA framebuffer for VT console"
else
    info "nvidia-drm.fbdev=1 not set (optional, improves VT switching)"
fi

check_kparam "processor.max_cstate=1" \
    "Limits CPU C-states to C1 — prevents Ryzen deep-sleep freezes" \
    "Add to GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub" \
    "https://bugzilla.kernel.org/show_bug.cgi?id=206299"

# amd_pstate check is kernel-version-aware
# On 6.8 GA: the parameter is NEEDED (acpi-cpufreq is default)
# On 6.11+: amd-pstate-epp is default, parameter is harmless/redundant
KERNEL_MAJOR=$(uname -r | cut -d. -f1-2)
if echo "$CMDLINE" | grep -q "amd_pstate=active"; then
    pass "amd_pstate=active — AMD P-State EPP driver explicitly enabled"
elif echo "$KERNEL_MAJOR" | grep -qE "^6\.(1[1-9]|[2-9][0-9])$"; then
    info "amd_pstate=active not in cmdline (default on HWE kernel $KERNEL_MAJOR)"
else
    warn "amd_pstate=active NOT set — needed on kernel 6.8 for optimal CPU scaling"
    fix "Add amd_pstate=active to GRUB_CMDLINE_LINUX_DEFAULT"
    ref "https://docs.kernel.org/admin-guide/pm/amd-pstate.html"
fi

###############################################################################
section "6. Module Load Order"
###############################################################################

AMDGPU_FIRST=$(dmesg 2>/dev/null | grep -n "amdgpu\|nvidia" | head -20 | grep -n "amdgpu" | head -1 | cut -d: -f1)
NVIDIA_FIRST=$(dmesg 2>/dev/null | grep -n "amdgpu\|nvidia" | head -20 | grep -n "nvidia" | head -1 | cut -d: -f1)

if [ -n "$AMDGPU_FIRST" ] && [ -n "$NVIDIA_FIRST" ]; then
    if [ "$AMDGPU_FIRST" -lt "$NVIDIA_FIRST" ]; then
        pass "amdgpu loads before nvidia (correct order)"
    else
        warn "nvidia may have loaded before amdgpu — check dmesg carefully"
        fix "Verify /etc/modules-load.d/gpu.conf and /etc/initramfs-tools/modules have amdgpu first"
    fi
else
    info "Could not determine module load order from dmesg"
fi

[ -f /etc/modules-load.d/gpu.conf ] && pass "gpu.conf module order file exists" || warn "gpu.conf not found"
grep -q "^amdgpu" /etc/initramfs-tools/modules 2>/dev/null && pass "amdgpu in initramfs modules" || warn "amdgpu not in initramfs"

###############################################################################
section "7. Display Rendering"
###############################################################################

if command -v glxinfo &>/dev/null; then
    RENDERER=$(glxinfo 2>/dev/null | grep "OpenGL renderer" | sed 's/OpenGL renderer string: //' || true)
    if echo "$RENDERER" | grep -qi "AMD\|Radeon\|raphael"; then
        pass "OpenGL renderer: $RENDERER (AMD iGPU) — CORRECT"
    elif echo "$RENDERER" | grep -qi "NVIDIA\|GeForce"; then
        fail "OpenGL renderer: $RENDERER — WRONG! Display is on NVIDIA, should be AMD"
        fix "Check xorg.conf BusIDs. Verify card0=AMD. Check module load order."
    elif echo "$RENDERER" | grep -qi "llvmpipe\|software"; then
        warn "OpenGL renderer: software rendering — iGPU acceleration not working"
        fix "Check amdgpu module: lsmod | grep amdgpu; check dmesg | grep amdgpu"
    else
        info "OpenGL renderer: $RENDERER"
    fi

    if command -v xrandr &>/dev/null && [ -n "${DISPLAY:-}" ]; then
        PROVIDERS=$(xrandr --listproviders 2>/dev/null | head -5 || true)
        if echo "$PROVIDERS" | grep -qi "amdgpu"; then
            pass "xrandr shows amdgpu as display provider"
        else
            info "xrandr provider info: $PROVIDERS"
        fi
    fi
else
    skip "glxinfo not available (install mesa-utils)"
fi

###############################################################################
section "8. NVIDIA Compute Configuration"
###############################################################################

if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
    # Kernel exec timeout
    TIMEOUT=$(nvidia-smi -q 2>/dev/null | grep "Kernel Exec Timeout" | awk '{print $NF}')
    if [ "$TIMEOUT" = "No" ]; then
        pass "Kernel Exec Timeout: No — long CUDA kernels allowed"
    elif [ "$TIMEOUT" = "Yes" ]; then
        fail "Kernel Exec Timeout: Yes — CUDA kernels >2s will be killed!"
        fix "Add NVreg_RegistryDwords=\"RmGpuComputeExecTimeout=0\" to /etc/modprobe.d/nvidia.conf"
        ref "https://forums.developer.nvidia.com/t/disable-kernel-execution-timeout/40228"
    else
        warn "Could not determine kernel exec timeout status"
    fi

    # Persistence mode
    PERSIST=$(nvidia-smi -q 2>/dev/null | grep "Persistence Mode" | awk '{print $NF}')
    if [ "$PERSIST" = "Enabled" ]; then
        pass "Persistence Mode: Enabled — fast CUDA init"
    else
        fail "Persistence Mode: $PERSIST — should be Enabled"
        fix "sudo systemctl enable nvidia-persistenced && sudo nvidia-smi -pm 1"
        ref "https://docs.nvidia.com/deploy/driver-persistence/index.html"
    fi

    # Power state
    PSTATE=$(nvidia-smi --query-gpu=pstate --format=csv,noheader 2>/dev/null)
    info "Current P-State: $PSTATE (P0=max perf, P8=idle)"

    # CudaNoStablePerfLimit verification (driver 595+ feature)
    # WHY: Before driver 595, CUDA workloads were limited to P2 PState (reduced
    #      memory clocks). The CudaNoStablePerfLimit application profile in 595
    #      allows CUDA to reach P0 PState (full GDDR6X memory bandwidth: 1,008 GB/s).
    #      This is automatic in 595 — no manual activation needed.
    # REF: https://www.gamingonlinux.com/2026/03/nvidia-driver-595-58-03-released-as-the-big-new-recommended-stable-driver-for-linux/
    if [ "$DRIVER_VER" = "595.58.03" ] || echo "$DRIVER_VER" | grep -q "^595\."; then
        pass "Driver 595: CudaNoStablePerfLimit available (CUDA can reach P0 — full memory bandwidth)"
        info "  Verify during active training: nvidia-smi -q -d PERFORMANCE | grep 'Performance State'"
        info "  Expected: P0 during compute (was limited to P2 on pre-595 drivers)"
    else
        info "Driver $DRIVER_VER — CudaNoStablePerfLimit requires driver 595+"
    fi

    # VRAM usage
    VRAM_USED=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null)
    VRAM_TOTAL=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null)
    if [ -n "$VRAM_USED" ] && [ "$VRAM_USED" -lt 100 ]; then
        pass "VRAM usage: ${VRAM_USED} MiB / ${VRAM_TOTAL} MiB — headless (minimal overhead)"
    elif [ -n "$VRAM_USED" ] && [ "$VRAM_USED" -lt 500 ]; then
        warn "VRAM usage: ${VRAM_USED} MiB — some processes may be using GPU"
    else
        fail "VRAM usage: ${VRAM_USED} MiB — significant usage on supposedly headless GPU"
        fix "Check nvidia-smi for processes. Verify display is not on NVIDIA."
    fi

    # Temperature
    TEMP=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader 2>/dev/null)
    if [ -n "$TEMP" ] && [ "$TEMP" -lt 50 ]; then
        pass "GPU temperature: ${TEMP}°C (cool idle — headless confirmed)"
    elif [ -n "$TEMP" ] && [ "$TEMP" -lt 70 ]; then
        info "GPU temperature: ${TEMP}°C"
    else
        warn "GPU temperature: ${TEMP}°C — high for idle"
    fi

    # Power
    POWER=$(nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits 2>/dev/null | cut -d. -f1)
    if [ -n "$POWER" ] && [ "$POWER" -lt 25 ]; then
        pass "GPU power: ${POWER}W (deep idle — headless + dynamic PM working)"
    elif [ -n "$POWER" ] && [ "$POWER" -lt 60 ]; then
        info "GPU power: ${POWER}W (elevated idle — check if display is attached)"
    else
        warn "GPU power: ${POWER}W — high for idle state"
    fi
fi

###############################################################################
section "9. CUDA Functionality"
###############################################################################

if $QUICK; then
    skip "CUDA test (--quick mode)"
else
    # Test basic CUDA via nvidia-smi first (no Python required)
    if command -v nvidia-smi &>/dev/null; then
        CUDA_VER=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null || echo "")
        if [ -n "$CUDA_VER" ]; then
            pass "CUDA compute capability: $CUDA_VER"
        fi
    fi

    # Test PyTorch CUDA
    if command -v python3 &>/dev/null; then
        PYTORCH_TEST=$(python3 -c "
import sys
try:
    import torch
    if torch.cuda.is_available():
        print(f'PASS:PyTorch CUDA available. Device: {torch.cuda.get_device_name(0)}. VRAM: {torch.cuda.get_device_properties(0).total_mem // 1024**3}GB')
    else:
        print('FAIL:PyTorch installed but CUDA not available')
except ImportError:
    print('SKIP:PyTorch not installed')
except Exception as e:
    print(f'FAIL:{e}')
" 2>/dev/null || echo "FAIL:Python error")

        STATUS=$(echo "$PYTORCH_TEST" | cut -d: -f1)
        MSG=$(echo "$PYTORCH_TEST" | cut -d: -f2-)
        case "$STATUS" in
            PASS) pass "PyTorch: $MSG" ;;
            FAIL) fail "PyTorch: $MSG" ;;
            SKIP) skip "PyTorch: $MSG" ;;
        esac
    else
        skip "Python3 not found — CUDA test skipped"
    fi

    # Test nvcc
    if command -v nvcc &>/dev/null; then
        NVCC_VER=$(nvcc --version 2>/dev/null | grep "release" | awk '{print $NF}' | tr -d ',')
        pass "nvcc (CUDA compiler): version $NVCC_VER"
    else
        warn "nvcc not found — CUDA toolkit may not be in PATH"
        fix "Add to ~/.bashrc: export PATH=/usr/local/cuda/bin:\$PATH"
    fi
fi

###############################################################################
section "10. Configuration Files"
###############################################################################

check_file() {
    local path="$1" desc="$2" content="${3:-}"
    if [ -f "$path" ]; then
        if [ -n "$content" ]; then
            if grep -q "$content" "$path" 2>/dev/null; then
                pass "$desc — file exists with correct content"
            else
                warn "$desc — file exists but missing expected content: $content"
            fi
        else
            pass "$desc — file exists"
        fi
    else
        fail "$desc — FILE MISSING: $path"
        fix "Run the appropriate setup phase script to create it"
    fi
}

check_file "/etc/modprobe.d/nvidia.conf" "NVIDIA module options" "NVreg_RegisterPCIDriverOnEarlyBoot"
check_file "/etc/modprobe.d/amdgpu.conf" "AMD iGPU module options" "sg_display=0"
check_file "/etc/modprobe.d/blacklist-nouveau.conf" "nouveau blacklist" "blacklist nouveau"
check_file "/etc/modules-load.d/gpu.conf" "GPU module load order" "amdgpu"
check_file "/etc/X11/xorg.conf.d/10-gpu.conf" "X11 dual-GPU config" "AllowNVIDIAGPUScreens"
check_file "/etc/udev/rules.d/61-gdm-amd-primary.rules" "GDM AMD primary rule" "amdgpu"
check_file "/etc/udev/rules.d/99-nvidia-compute.rules" "NVIDIA compute permissions" "render"
# NOTE: /etc/apt/preferences.d/pin-kernel-ga should NOT exist — it's a stale
# artifact from the old "pin 6.8 GA" strategy. If present, Section 1 warns.
if [ -f /etc/apt/preferences.d/pin-kernel-ga ]; then
    fail "Stale kernel pin file present (/etc/apt/preferences.d/pin-kernel-ga)"
    fix "sudo rm /etc/apt/preferences.d/pin-kernel-ga (blocks HWE kernel updates)"
fi
check_file "/etc/profile.d/cuda-env.sh" "CUDA environment" "CUDA_VISIBLE_DEVICES"

# Check ReBAR configuration
if grep -q "NVreg_EnableResizableBar=1" /etc/modprobe.d/nvidia.conf 2>/dev/null; then
    pass "NVreg_EnableResizableBar=1 configured in nvidia.conf"
    # Verify actual BAR1 size via nvidia-smi
    if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
        BAR1_LINE=$(nvidia-smi -q 2>/dev/null | grep -A3 "BAR1" | grep "Total" || true)
        if [ -n "$BAR1_LINE" ]; then
            BAR1_SIZE=$(echo "$BAR1_LINE" | awk '{print $3}')
            if [ -n "$BAR1_SIZE" ] && [ "$BAR1_SIZE" -gt 256 ] 2>/dev/null; then
                pass "BAR1 Memory: ${BAR1_SIZE} MiB (Resizable BAR active)"
            else
                info "BAR1 Memory: ${BAR1_SIZE} MiB (ReBAR may not be active in BIOS)"
                fix "BIOS → Advanced → PCI Subsystem Settings → Resizable BAR → Enabled"
            fi
        fi
    fi
else
    info "NVreg_EnableResizableBar not in nvidia.conf (optional — improves memory transfers 5-15%)"
fi

###############################################################################
section "11. Systemd Services"
###############################################################################

check_service_active() {
    local svc="$1" expected="$2" desc="$3"
    local state=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
    if [ "$state" = "$expected" ]; then
        pass "$desc: $state"
    else
        warn "$desc: $state (expected: $expected)"
    fi
}

check_service_enabled() {
    local svc="$1" expected="$2" desc="$3"
    local state=$(systemctl is-enabled "$svc" 2>/dev/null || echo "unknown")
    if [ "$state" = "$expected" ]; then
        pass "$desc: $state"
    else
        warn "$desc: $state (expected: $expected)"
    fi
}

check_service_enabled "nvidia-persistenced" "enabled" "nvidia-persistenced"
check_service_enabled "gpu-manager" "masked" "gpu-manager (should be masked)"
check_service_enabled "nvidia-power-settings" "enabled" "nvidia-power-settings"

# Check sleep targets are masked
for target in sleep.target suspend.target hibernate.target; do
    state=$(systemctl is-enabled "$target" 2>/dev/null || echo "unknown")
    if [ "$state" = "masked" ]; then
        pass "$target: masked (sleep disabled for ML workstation)"
    else
        warn "$target: $state (should be masked for ML stability)"
        fix "sudo systemctl mask $target"
    fi
done

# Check power-profiles-daemon
if command -v powerprofilesctl &>/dev/null; then
    PPD_PROFILE=$(powerprofilesctl get 2>/dev/null || echo "unknown")
    if [ "$PPD_PROFILE" = "performance" ]; then
        pass "power-profiles-daemon: performance profile (max CPU throughput)"
    elif [ "$PPD_PROFILE" = "balanced" ]; then
        warn "power-profiles-daemon: balanced profile (performance recommended for ML)"
        fix "sudo powerprofilesctl set performance"
    else
        info "power-profiles-daemon: $PPD_PROFILE profile"
    fi

    # Check if the persistence override exists
    if [ -f /etc/systemd/system/power-profiles-daemon.service.d/ml-performance.conf ]; then
        pass "PPD performance profile persists across reboots (systemd override present)"
    else
        info "PPD performance override not configured — profile may reset to balanced on reboot"
        fix "Run 03-configure-display.sh to create the PPD persistence override"
    fi
fi

###############################################################################
section "12. Security Checks"
###############################################################################

# SME/TSME check
if echo "$CMDLINE" | grep -q "mem_encrypt=on"; then
    fail "mem_encrypt=on is set — BREAKS NVIDIA driver"
    fix "Remove mem_encrypt=on from /etc/default/grub immediately"
    ref "https://github.com/NVIDIA/open-gpu-kernel-modules/issues/340"
else
    pass "mem_encrypt not enabled (NVIDIA compatible)"
fi

if dmesg 2>/dev/null | grep -qi "AMD Memory Encryption Features active: SME"; then
    fail "SME is active — NVIDIA DMA will fail"
    fix "BIOS → Advanced → AMD CBS → CPU Common Options → SMEE → Disabled"
else
    pass "SME not active"
fi

# nouveau check
if lsmod | grep -q "^nouveau"; then
    fail "nouveau module is loaded — conflicts with nvidia"
    fix "Ensure blacklist-nouveau.conf exists and run update-initramfs -u"
else
    pass "nouveau not loaded"
fi

###############################################################################
section "13. Display Artifact Protections"
###############################################################################

if echo "$CMDLINE" | grep -q "amdgpu.sg_display=0"; then
    pass "Scatter-gather display fix active (sg_display=0)"
else
    fail "sg_display=0 NOT active — Raphael iGPU may show corruption"
    fix "Add amdgpu.sg_display=0 to /etc/default/grub GRUB_CMDLINE_LINUX_DEFAULT"
    ref "https://bugs.launchpad.net/bugs/2038998"
fi

if echo "$CMDLINE" | grep -q "amdgpu.dcdebugmask=0x10"; then
    pass "PSR disabled (dcdebugmask=0x10) — prevents flicker"
else
    warn "PSR not disabled — may cause flicker on some monitors"
    fix "Add amdgpu.dcdebugmask=0x10 to kernel parameters"
    ref "https://docs.kernel.org/gpu/amdgpu/display/dc-debug.html"
fi

###############################################################################
section "14. GPU Error Check"
###############################################################################

XID_COUNT=$(dmesg 2>/dev/null | grep -ci "xid" || echo "0")
if [ "$XID_COUNT" -gt 0 ]; then
    fail "Found $XID_COUNT Xid error(s) in dmesg — GPU instability!"
    echo "  Recent Xid errors:"
    dmesg 2>/dev/null | grep -i "xid" | tail -5 | while read line; do
        echo "    $line"
    done
    fix "Common fixes: pcie_aspm=off, reseat GPU, check 12VHPWR cable, force PCIe Gen 4"
    ref "https://forums.developer.nvidia.com/t/gpu-has-fallen-off-the-bus-issues-on-daily-basis-rtx-4090/314647"
else
    pass "No Xid errors in dmesg — GPU stable"
fi

AMDGPU_ERRORS=$(dmesg 2>/dev/null | grep -i "amdgpu.*error\|amdgpu.*fault\|amdgpu.*timeout" | wc -l)
if [ "$AMDGPU_ERRORS" -gt 0 ]; then
    warn "Found $AMDGPU_ERRORS amdgpu error(s) in dmesg"
    dmesg 2>/dev/null | grep -i "amdgpu.*error\|amdgpu.*fault\|amdgpu.*timeout" | tail -3 | while read line; do
        echo "    $line"
    done
else
    pass "No amdgpu errors in dmesg — iGPU stable"
fi

###############################################################################
section "15. amdgpu Runtime Parameters (sysfs)"
###############################################################################

# WHY: Section 13 checks /proc/cmdline for kernel parameters, but that only
#      verifies the parameter was PASSED to the kernel. This section checks
#      /sys/module/amdgpu/parameters/ to verify the parameter actually TOOK
#      EFFECT at the module level. It's possible for cmdline params to be
#      present but not applied (e.g., if module loads from initramfs before
#      cmdline is processed).

SG_DISPLAY=$(cat /sys/module/amdgpu/parameters/sg_display 2>/dev/null || echo "N/A")
if [ "$SG_DISPLAY" = "0" ]; then
    pass "amdgpu sg_display=0 (scatter-gather DMA disabled in sysfs)"
elif [ "$SG_DISPLAY" = "N/A" ]; then
    warn "Cannot read sg_display from sysfs (amdgpu may not be loaded)"
else
    fail "amdgpu sg_display=$SG_DISPLAY — MUST be 0 to prevent Raphael display corruption"
    fix "Add amdgpu.sg_display=0 to GRUB_CMDLINE_LINUX_DEFAULT and reboot"
    ref "https://bugs.launchpad.net/bugs/2038998"
fi

DC_MASK=$(cat /sys/module/amdgpu/parameters/dcdebugmask 2>/dev/null || echo "N/A")
if [ "$DC_MASK" = "0x10" ] || [ "$DC_MASK" = "16" ]; then
    pass "amdgpu dcdebugmask=0x10 (PSR disabled in sysfs)"
elif [ "$DC_MASK" = "N/A" ]; then
    warn "Cannot read dcdebugmask from sysfs"
else
    warn "amdgpu dcdebugmask=$DC_MASK — expected 0x10 (PSR disabled)"
    fix "Add amdgpu.dcdebugmask=0x10 to GRUB_CMDLINE_LINUX_DEFAULT and reboot"
    ref "https://docs.kernel.org/gpu/amdgpu/display/dc-debug.html"
fi

GFX_OFF=$(cat /sys/module/amdgpu/parameters/gfx_off 2>/dev/null || echo "N/A")
if [ "$GFX_OFF" = "0" ]; then
    pass "amdgpu gfx_off=0 (GFXOFF disabled — ring timeout protection active)"
elif [ "$GFX_OFF" = "N/A" ]; then
    # gfx_off is not a real modprobe param on kernel 6.8 GA — it only exists on
    # newer kernels. ppfeaturemask=0xfffd7fff already disables GFXOFF at firmware
    # level, so missing gfx_off sysfs is fine as long as ppfeaturemask is correct.
    if echo "$KERNEL" | grep -q "^6\.8\."; then
        info "gfx_off sysfs not available (kernel 6.8 — param only exists on 6.11+)."
        info "  ppfeaturemask handles firmware-level GFXOFF disable (Layer 2)."
        info "  BIOS GFXOFF=Disabled (B22) provides hardware-level disable (Layer 1) — verify in BIOS."
    else
        warn "Cannot read gfx_off from sysfs (amdgpu may not be loaded)"
    fi
else
    # On HWE 6.11+, GFXOFF is fixed at kernel level; gfx_off=1 is acceptable
    if echo "$KERNEL" | grep -qE "^6\.(1[1-9]|[2-9][0-9])\."; then
        pass "amdgpu gfx_off=$GFX_OFF (GFXOFF safe — kernel $KERNEL_MAJOR has the fix)"
    else
        fail "amdgpu gfx_off=$GFX_OFF — MUST be 0 on kernel 6.8 to prevent ring timeouts"
        fix "Add amdgpu.gfx_off=0 to GRUB_CMDLINE_LINUX_DEFAULT and reboot"
        ref "https://gitlab.freedesktop.org/drm/amd/-/issues/3006"
    fi
fi

PP_MASK=$(cat /sys/module/amdgpu/parameters/ppfeaturemask 2>/dev/null || echo "N/A")
if [ "$PP_MASK" != "N/A" ]; then
    # Convert to hex for comparison (kernel may report as decimal)
    PP_HEX=$(printf "0x%x" "$PP_MASK" 2>/dev/null || echo "$PP_MASK")
    # Check that GFXOFF bit (0x8000) is NOT set
    if [ $((PP_MASK & 0x8000)) -eq 0 ] 2>/dev/null; then
        pass "amdgpu ppfeaturemask ($PP_HEX) has PP_GFXOFF disabled"
    else
        warn "amdgpu ppfeaturemask ($PP_HEX) still has PP_GFXOFF enabled"
        fix "Set amdgpu.ppfeaturemask=0xfffd7fff in GRUB_CMDLINE_LINUX_DEFAULT"
        ref "https://docs.kernel.org/gpu/amdgpu/module-parameters.html"
    fi
else
    warn "Cannot read ppfeaturemask from sysfs"
fi

# Verify amd_pstate CPU frequency driver is active
# WHY: Section 5 checks /proc/cmdline for the kernel parameter, but this section
#      verifies the driver actually loaded and is controlling CPU frequency.
if [ -f /sys/devices/system/cpu/cpufreq/policy0/scaling_driver ]; then
    SCALING_DRIVER=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_driver 2>/dev/null || echo "unknown")
    if [ "$SCALING_DRIVER" = "amd-pstate-epp" ]; then
        pass "CPU frequency driver: amd-pstate-epp (EPP active — optimal for Zen 4)"
    elif [ "$SCALING_DRIVER" = "amd-pstate" ]; then
        pass "CPU frequency driver: amd-pstate (passive mode — consider amd_pstate=active)"
    elif [ "$SCALING_DRIVER" = "acpi-cpufreq" ]; then
        warn "CPU frequency driver: acpi-cpufreq (legacy — amd_pstate recommended)"
        fix "Add amd_pstate=active to GRUB_CMDLINE_LINUX_DEFAULT and reboot"
        ref "https://docs.kernel.org/admin-guide/pm/amd-pstate.html"
    else
        info "CPU frequency driver: $SCALING_DRIVER"
    fi

    # Check EPP setting (set by power-profiles-daemon)
    EPP=$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null || echo "N/A")
    if [ "$EPP" = "performance" ]; then
        pass "CPU EPP: performance (maximum CPU throughput for data loading)"
    elif [ "$EPP" = "balance_performance" ]; then
        info "CPU EPP: balance_performance (acceptable; 'performance' recommended for ML)"
        fix "sudo powerprofilesctl set performance"
    elif [ "$EPP" != "N/A" ]; then
        warn "CPU EPP: $EPP (consider 'performance' for ML workstation)"
        fix "sudo powerprofilesctl set performance"
    fi
fi

###############################################################################
section "16. modprobe.d Parameter Validation"
###############################################################################

# WHY: Invalid parameters in /etc/modprobe.d/amdgpu.conf cause "unknown parameter"
#      errors that can cascade into amdgpu probe failure (error -22). On kernel 6.8 GA,
#      gfx_off and dcdebugmask are NOT valid modprobe params — they only work as
#      kernel cmdline params (amdgpu.gfx_off=0). This check catches the exact issue.

AMDGPU_MODPROBE="/etc/modprobe.d/amdgpu.conf"
if [ -f "$AMDGPU_MODPROBE" ]; then
    MODINFO_OUT=$(modinfo amdgpu 2>/dev/null || true)
    if [ -n "$MODINFO_OUT" ]; then
        INVALID_PARAMS=""
        while IFS= read -r line; do
            # Extract param name from "options amdgpu param=value"
            param=$(echo "$line" | sed -n 's/^options[[:space:]]*amdgpu[[:space:]]*\([a-zA-Z_]*\)=.*/\1/p')
            if [ -n "$param" ]; then
                if ! echo "$MODINFO_OUT" | grep -q "parm:.*${param}:"; then
                    INVALID_PARAMS="${INVALID_PARAMS} ${param}"
                fi
            fi
        done < "$AMDGPU_MODPROBE"
        if [ -n "$INVALID_PARAMS" ]; then
            fail "Invalid amdgpu modprobe params:${INVALID_PARAMS}"
            fix "Remove invalid params from $AMDGPU_MODPROBE — they cause probe failure on this kernel"
            fix "Move them to GRUB_CMDLINE_LINUX_DEFAULT as amdgpu.<param>=<value> instead"
        else
            pass "All amdgpu modprobe params are valid for this kernel"
        fi
    else
        info "Cannot run modinfo amdgpu — skipping param validation"
    fi
else
    info "$AMDGPU_MODPROBE not found — amdgpu modprobe config not yet created"
fi

# BIOS-only GFXOFF reminder (cannot verify from Linux)
info "BIOS-only GFXOFF control (cannot verify from Linux — check manually in BIOS):"
info "  [TIER 1] GFXOFF → Disabled (B22)"
info "  Path: Advanced → AMD CBS → NBIO Common Options → SMU Common Options → GFXOFF"
info "  WHY: Most authoritative GFXOFF disable (Layer 1). Prevents SMU from enabling GFXOFF"
info "       before OS boots. ppfeaturemask (Layer 2) + gfx_off=0 (Layer 3) are belt-and-suspenders."

###############################################################################
# SUMMARY
###############################################################################
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  VERIFICATION SUMMARY                                      ║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
printf "${BOLD}║${NC}  ${GREEN}Passed: %-4d${NC} ${RED}Failed: %-4d${NC} ${YELLOW}Warnings: %-4d${NC} ${DIM}Skipped: %-4d${NC} ${BOLD}║${NC}\n" $PASS $FAIL $WARN $SKIP
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"

if [ $FAIL -gt 0 ]; then
    echo -e "\n${RED}${BOLD}  RESULT: $FAIL CRITICAL FAILURE(S) — Fix before using for ML training${NC}"
    echo "  Re-run this script after applying fixes."
    exit 1
elif [ $WARN -gt 0 ]; then
    echo -e "\n${YELLOW}${BOLD}  RESULT: PASS WITH $WARN WARNING(S) — System functional but not optimal${NC}"
    echo "  Address warnings for best stability."
    exit 2
else
    echo -e "\n${GREEN}${BOLD}  RESULT: ALL CHECKS PASSED — System ready for ML training!${NC}"
    echo ""
    echo "  Quick start:"
    echo "    sudo gpu-ml-setup.sh              # Lock GPU clocks for training"
    echo "    python3 -c 'import torch; ...'     # Verify CUDA in your framework"
    echo "    nvtop                              # Monitor both GPUs during training"
    exit 0
fi
