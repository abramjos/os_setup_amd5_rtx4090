#!/bin/bash
###############################################################################
# 01-first-boot-display-fix.sh
#
# PURPOSE: Apply critical display stability fixes immediately after first boot.
#          This script addresses the AMD Raphael iGPU display corruption issues
#          that affect the system BEFORE any NVIDIA driver is installed.
#
# WHEN TO RUN: Immediately after Ubuntu 24.04.1 installation, on first boot.
#              Run BEFORE installing NVIDIA drivers or any GPU software.
#
# WHAT THIS DOES:
#   1. Applies critical GRUB kernel parameters for iGPU display stability
#   2. Creates amdgpu modprobe configuration
#   3. Installs HWE kernel 6.17 (fixes gfx ring timeout; keeps GA 6.8 as fallback)
#   4. Disables gpu-manager (prevents Ubuntu from overriding GPU config)
#   5. Configures GDM to use X11 (more stable for dual-GPU)
#   6. Installs essential display utilities
#
# ISSUES ADDRESSED:
#   - Black screen after boot (scatter-gather DMA bug in Raphael iGPU)
#     REF: https://bugs.launchpad.net/bugs/2038998
#     REF: https://wiki.archlinux.org/title/AMDGPU#Boot_parameter
#     FIX: amdgpu.sg_display=0 kernel parameter
#
#   - Screen flickering / horizontal artifacts (PSR bug)
#     REF: https://gitlab.freedesktop.org/drm/amd/-/issues/2986
#     REF: https://docs.kernel.org/gpu/amdgpu/display/dc-debug.html
#     FIX: amdgpu.dcdebugmask=0x10 disables Panel Self Refresh
#
#   - GFX ring timeout (amdgpu_job_timedout ring gfx_0.0.0)
#     REF: https://bugs.launchpad.net/ubuntu/+source/linux/+bug/2081092
#     REF: https://gitlab.freedesktop.org/drm/amd/-/issues/3006
#     REF: https://bbs.archlinux.org/viewtopic.php?id=299047
#     FIX: amdgpu.gfx_off=0 disables GFX power gating (primary cause)
#     FIX: amdgpu.ppfeaturemask=0xfffd7fff disables GFXOFF + stutter mode
#     FIX: linux-firmware update (kernel 6.8 firmware regression)
#
#   - Multi-monitor wake from sleep failure
#     REF: https://forums.developer.nvidia.com/t/no-video-on-displayport-after-computer-sleep-hdmi-works/304794
#     FIX: dcdebugmask + disabling sleep for ML workstation
#
#   - PCIe ASPM causing Xid 79 "GPU has fallen off the bus"
#     REF: https://forums.developer.nvidia.com/t/gpu-has-fallen-off-the-bus-issues-on-daily-basis-rtx-4090/314647
#     REF: https://forums.developer.nvidia.com/t/rtx-4090-xid-79-fell-off-the-bus-infrequently/300369
#     FIX: pcie_aspm=off kernel parameter
#
#   - Kernel 6.8 GA has unfixed GFXOFF bug for Raphael gfx1036
#     The ring timeout fix landed upstream in kernels 6.9-6.11 (GFXOFF rework
#     for GC 10.3.x). Ubuntu 24.04 HWE 6.17 includes this fix natively.
#     REF: https://gitlab.freedesktop.org/drm/amd/-/issues/3006
#     REF: https://bbs.archlinux.org/viewtopic.php?id=299047
#     FIX: Install HWE kernel 6.17 (keeps GA 6.8 as GRUB fallback)
#
#   - [RESOLVED] HWE kernel breaking NVIDIA driver (no longer applies to 595)
#     The fbdev header rename (drm_fbdev_generic.h → drm_fbdev_ttm.h) in
#     kernel 6.11 broke NVIDIA 470/535/early-550 DKMS compilation. This was
#     fixed in NVIDIA 550.135 (Nov 2024). NVIDIA 595.58.03 inherits the fix
#     and supports kernels 6.8 through 6.19. CUDA 13.2 install guide validates
#     Ubuntu 24.04 with kernel 6.17.0-19 specifically.
#     REF: https://bbs.archlinux.org/viewtopic.php?id=299450 (original fbdev break)
#     REF: https://docs.nvidia.com/datacenter/tesla/tesla-release-notes-595-58-03/
#     REF: https://docs.nvidia.com/cuda/cuda-installation-guide-linux/ (validates 6.17)
#     NOTE: Original concern was for NVIDIA 470/550 — no longer relevant for 595
#
#   - Ubuntu gpu-manager overriding manual xorg.conf
#     REF: https://gist.github.com/wangruohui/bc7b9f424e3d5deb0c0b8bba990b1bc5
#     FIX: nogpumanager kernel param + systemctl mask gpu-manager
#
# SYSTEM: Ryzen 9 7950X | ASUS ROG Crosshair X670E Hero | RTX 4090
#         BIOS 3603 (AGESA ComboAM5 PI 1.3.0.0a)
#         Ubuntu 24.04.1 LTS | Kernel 6.17 HWE (6.8 GA fallback)
#
# USAGE: sudo bash 01-first-boot-display-fix.sh
#
# REQUIRES: Root privileges
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

# Ensure running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}ERROR: This script must be run as root (sudo).${NC}"
    exit 1
fi

echo -e "${BOLD}================================================================${NC}"
echo -e "${BOLD}  Phase 1: First Boot Display Fix${NC}"
echo -e "${BOLD}  Stabilizing AMD Raphael iGPU display before NVIDIA install${NC}"
echo -e "${BOLD}================================================================${NC}"
echo ""

###############################################################################
# STEP 1: Configure GRUB kernel parameters
###############################################################################
echo -e "${BLUE}[Step 1/7]${NC} Configuring GRUB kernel parameters..."

# Back up original GRUB config
# WHY: Always back up before modifying boot configuration. If something goes
#      wrong, we can restore from backup without needing a live USB.
cp /etc/default/grub /etc/default/grub.backup.$(date +%Y%m%d%H%M%S)
echo "  Backed up /etc/default/grub"

# Also create a deterministic backup name for the rollback script (99-rollback.sh)
cp /etc/default/grub /etc/default/grub.bak.ml-setup

# Define the kernel parameters we need
# Each parameter addresses a specific, documented hardware issue:
#
# amdgpu.sg_display=0
#   WHAT: Disables scatter-gather DMA for display scanout on AMD iGPU
#   WHY:  Raphael (gfx1036) has a hardware/firmware bug where S/G DMA causes
#         display corruption (black screen, garbled output) on kernels ≥6.1.4
#   RISK: Slightly higher memory usage for display (uses contiguous DMA instead)
#   REF:  https://bugs.launchpad.net/bugs/2038998
#   REF:  https://wiki.archlinux.org/title/AMDGPU
#
# amdgpu.dcdebugmask=0x10
#   WHAT: Disables PSR (Panel Self Refresh) in the amdgpu Display Core
#   WHY:  PSR causes intermittent flicker on many monitors. Also helps with
#         multi-monitor wake-from-sleep failures where one monitor shows "no signal"
#   NOTE: This is a KERNEL CMDLINE param only. On kernel 6.8 GA, dcdebugmask is
#         NOT a valid modprobe module parameter — do NOT put in modprobe.d.
#   RISK: Slightly higher power draw from display controller (PSR saves ~0.5W)
#   REF:  https://docs.kernel.org/gpu/amdgpu/display/dc-debug.html
#   REF:  https://gitlab.freedesktop.org/drm/amd/-/issues/2986
#
# nvidia-drm.modeset=1
#   WHAT: Enables kernel mode setting for the NVIDIA DRM driver
#   WHY:  Required for Wayland support, VT switching, and proper DRM integration.
#         Default in NVIDIA 595.58.03 but we set it explicitly for safety.
#   RISK: None on supported hardware
#   REF:  https://www.gamingonlinux.com/2026/03/nvidia-driver-595-58-03-released-as-the-big-new-recommended-stable-driver-for-linux/
#
# nvidia-drm.fbdev=1
#   WHAT: Enables NVIDIA framebuffer device for VT console
#   WHY:  Improves VT switching (Ctrl+Alt+F1/F2) and early boot display.
#         Available in NVIDIA 545+ drivers.
#   RISK: None on supported hardware
#
# amdgpu.gfx_off=0
#   WHAT: Disables GFX power gating (GFXOFF) on the AMD iGPU
#   WHY:  GFXOFF puts the graphics engine into deep sleep when idle. On
#         Raphael gfx1036, the wake-up from GFXOFF frequently fails, causing
#         "ring gfx_0.0.0 timeout" errors (amdgpu_job_timedout). This is the
#         most common cause of gfx ring timeouts on Raphael iGPU with kernel 6.8.
#         Without this, the GPU command ring stalls when the graphics engine
#         doesn't wake in time to execute submitted commands.
#   NOTE: This is a KERNEL CMDLINE param only. On kernel 6.8 GA, gfx_off is NOT
#         a valid modprobe module parameter — putting it in modprobe.d causes
#         "unknown parameter 'gfx_off' ignored" and can cascade into probe
#         failure (error -22). ppfeaturemask=0xfffd7fff (in modprobe.d) already
#         disables GFXOFF at firmware level, making this belt-and-suspenders.
#   BIOS: Also set GFXOFF → Disabled in BIOS for the most authoritative disable
#         [TIER 1: B22]. Path: Advanced → AMD CBS → NBIO Common Options →
#         SMU Common Options → GFXOFF. The BIOS setting prevents the SMU from
#         enabling GFXOFF before any OS/driver code runs.
#   RISK: ~1-2W higher iGPU idle power (graphics engine stays in active state)
#   REF:  https://gitlab.freedesktop.org/drm/amd/-/issues/3006
#   REF:  https://bbs.archlinux.org/viewtopic.php?id=299047
#
# amdgpu.ppfeaturemask=0xfffd7fff
#   WHAT: Disables PP_GFXOFF_MASK (bit 15) and PP_STUTTER_MODE (bit 17) in
#         the amdgpu PowerPlay feature mask while keeping all other features
#   WHY:  Three-layer GFXOFF disable model:
#         Layer 1 (BIOS/SMU): GFXOFF = Disabled [B22] — highest authority
#         Layer 2 (Firmware):  ppfeaturemask=0xfffd7fff (this param, in modprobe.d)
#         Layer 3 (Driver):    amdgpu.gfx_off=0 (GRUB cmdline)
#         ppfeaturemask controls the PowerPlay firmware-level power features.
#         Together with BIOS GFXOFF=Disabled and kernel gfx_off=0, this ensures
#         the graphics engine never enters the problematic GFXOFF sleep state.
#         Stutter mode on APUs causes additional display-related power
#         transitions that can trigger ring timeouts.
#   RISK: Same as gfx_off=0 — minimal idle power increase
#   NOTE: Do NOT use 0xffffffff — that enables unstable experimental features
#         that cause flickering and broken suspend/resume
#   REF:  https://docs.kernel.org/gpu/amdgpu/module-parameters.html
#
# pcie_aspm=off
#   WHAT: Tells the kernel "don't touch ASPM — leave firmware settings unchanged"
#   NOTE: Despite the name, pcie_aspm=off does NOT actively disable ASPM.
#         A kernel commit clarified: "Don't touch ASPM configuration at all.
#         Leave any configuration done by firmware unchanged."
#         The actual ASPM disable comes from BIOS settings:
#           - Native ASPM = Enabled (B7) — hands control to Linux via ACPI _OSC
#           - CPU PCIE ASPM Mode Control = Disabled (B7b) — kills L0s/L1 on GPU lanes
#         pcie_aspm=off is belt-and-suspenders: since Native ASPM hands control
#         to the OS, and the kernel is told not to touch it, ASPM stays off.
#   WHY:  ASPM L0s is the #1 cause of RTX 4090 Xid 79 "GPU has fallen off the bus"
#         on AM5 platforms. PCIe power state transitions cause link drops that
#         require a hard reboot to recover.
#   RISK: ~5-10W higher system idle power (PCIe links stay in L0 state)
#   BIOS: Native ASPM → Enabled [TIER 1: B7]
#         CPU PCIE ASPM Mode Control → Disabled [TIER 1: B7b]
#         Path: Advanced → Onboard Devices Configuration
#   REF:  https://forums.developer.nvidia.com/t/nvidia-driver-xid-79-gpu-crash-while-idling-if-aspm-l0s-is-enabled-in-uefi-bios-gpu-has-fallen-off-the-bus/314453
#   REF:  https://forums.developer.nvidia.com/t/gpu-has-fallen-off-the-bus-issues-on-daily-basis-rtx-4090/314647
#
# iommu=pt
#   WHAT: Sets IOMMU to pass-through mode
#   WHY:  Pass-through mode allows GPU DMA without IOMMU address translation
#         overhead. Improves CUDA data transfer performance by ~1-3%.
#         Also required for GPU passthrough to VMs if needed later.
#   RISK: None for this use case (reduces protection but we trust our own hardware)
#   REF:  https://docs.nvidia.com/cuda/cuda-installation-guide-linux/
#
# nogpumanager
#   WHAT: Disables Ubuntu's automatic GPU manager service
#   WHY:  gpu-manager auto-generates /etc/X11/xorg.conf based on detected GPUs,
#         overriding any manual configuration. In our dual-GPU setup, it often
#         makes the wrong choice (putting display on NVIDIA instead of iGPU).
#   RISK: None — we configure GPU assignment manually via xorg.conf.d
#   REF:  https://gist.github.com/wangruohui/bc7b9f424e3d5deb0c0b8bba990b1bc5
#
# processor.max_cstate=1
#   WHAT: Limits CPU C-states to C1 (halt only)
#   WHY:  Ryzen 7000 series has a documented kernel bug (bugzilla #206299) where
#         transitions into deep C-states (C2+, especially C6) cause intermittent
#         system freezes. The AMD data fabric entering deep sleep during C6 can
#         stall PCIe transactions, contributing to both CPU freezes and GPU
#         "fell off the bus" events (Xid 79). C1 (halt) still saves significant
#         power versus C0 (active) — the CPU clock is gated, reducing power by
#         ~50% from active — but avoids the problematic deep sleep transitions
#         that affect the data fabric and PCIe subsystem.
#   COST: ~15-20W higher idle power compared to C6. Negligible during training
#         (CPU is active anyway). Noticeable only at desktop idle.
#   NOTE: Previously listed as Tier 4-5 troubleshooting step. Promoted to default
#         because random freezes during multi-hour training runs are unacceptable
#         and the power cost is minimal for a workstation.
#   BIOS: Also disable Global C-state Control in BIOS for defense in depth [B11]
#   REF:  https://gist.github.com/dlqqq/876d74d030f80dc899fc58a244b72df0
#   REF:  https://bugzilla.kernel.org/show_bug.cgi?id=206299
#
# amd_pstate=active
#   WHAT: Enables the AMD P-State EPP (Energy Performance Preference) CPU
#         frequency scaling driver using CPPC v2 hardware collaboration
#   WHY:  Kernel 6.8 GA defaults to acpi-cpufreq, which provides coarse-grained
#         CPU frequency steps. amd_pstate=active enables EPP mode where the CPU
#         hardware and OS collaborate on frequency selection, providing finer
#         granularity and faster response to load changes. This improves both
#         single-thread (data preprocessing) and multi-thread (data loading)
#         performance.
#         On kernel 6.11+, amd-pstate-epp is already the default for Zen 2+ CPUs.
#         The explicit parameter is redundant on 6.17 HWE but ensures it activates
#         if the user boots the 6.8 GA fallback kernel from GRUB.
#   COST: None. This is the recommended driver for Zen 4.
#   INTERACTION: power-profiles-daemon (PPD) v0.20+ can set the EPP hint via
#         /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference.
#         Script 03 sets PPD to "performance" profile for maximum throughput.
#   REF:  https://docs.kernel.org/admin-guide/pm/amd-pstate.html
#   REF:  https://wiki.archlinux.org/title/CPU_frequency_scaling#amd_pstate

GRUB_PARAMS="quiet splash amdgpu.sg_display=0 amdgpu.dcdebugmask=0x10 amdgpu.gfx_off=0 amdgpu.ppfeaturemask=0xfffd7fff amdgpu.seamless=0 amdgpu.vm_fragment_size=9 amdgpu.gpu_recovery=1 amdgpu.lockup_timeout=30000 nvidia-drm.modeset=1 nvidia-drm.fbdev=1 pcie_aspm=off iommu=pt nogpumanager processor.max_cstate=1 amd_pstate=active initcall_blacklist=simpledrm_platform_driver_init"

# Replace the GRUB_CMDLINE_LINUX_DEFAULT line
# Using sed to modify the existing line rather than appending
sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${GRUB_PARAMS}\"|" /etc/default/grub

echo -e "  ${GREEN}GRUB parameters set:${NC}"
echo "    $GRUB_PARAMS"

# Update GRUB
update-grub 2>/dev/null
echo -e "  ${GREEN}GRUB updated${NC}"

###############################################################################
# STEP 2: Create amdgpu modprobe configuration
###############################################################################
echo -e "\n${BLUE}[Step 2/7]${NC} Creating amdgpu modprobe configuration..."

# WHY: modprobe.d options are Layer 2 in the three-layer GFXOFF defense model:
#      Layer 1 (BIOS/SMU): GFXOFF = Disabled [B22] — highest authority
#      Layer 2 (Firmware):  ppfeaturemask=0xfffd7fff (this file, modprobe.d)
#      Layer 3 (Driver):    amdgpu.gfx_off=0 (GRUB cmdline)
#      Even if GRUB parameters are lost (e.g., after grub-install), these
#      options are embedded in the initramfs and take effect at module load time.
#
# IMPORTANT — modprobe vs kernel cmdline parameters:
#   Only REAL module parameters (listed by `modinfo amdgpu`) belong in
#   modprobe.d. Kernel-cmdline-only params (gfx_off, dcdebugmask) cause
#   "unknown parameter" errors in modprobe.d, which can cascade into
#   amdgpu probe failure (error -22) on kernel 6.8 GA.
#
#   - gfx_off=0 → kernel cmdline ONLY (amdgpu.gfx_off=0 in GRUB)
#     Not a real modprobe param on 6.8 GA. ppfeaturemask already disables GFXOFF.
#   - dcdebugmask=0x10 → kernel cmdline ONLY (amdgpu.dcdebugmask=0x10 in GRUB)
#     Not a real modprobe param on 6.8 GA.
#
# sg_display=0: Same as kernel param — prevents scatter-gather corruption
# ppfeaturemask=0xfffd7fff: Disables PP_GFXOFF + PP_STUTTER_MODE at firmware
#   level. This SUBSUMES gfx_off=0 — GFXOFF is disabled even without the
#   gfx_off param. Belt-and-suspenders: GRUB cmdline also has amdgpu.gfx_off=0
#   for kernels that support it as a module param (6.11+).
# gpu_recovery=1: Enables automatic GPU hang recovery instead of requiring reboot
#   WHY: If the iGPU hangs during desktop use (rare but possible), the kernel
#        will automatically reset it instead of leaving the display frozen.
# audio=1: Enables HDMI/DP audio output from motherboard ports
#   WHY: You may want audio from your monitor. This is often disabled by default.
# dc=1: Explicitly enables the Display Core subsystem
#   WHY: Display Core is the modern display management path in amdgpu.
#        Some older kernels defaulted to the legacy path. Explicit is safer.
#
# REF: https://wiki.archlinux.org/title/AMDGPU#Module_parameters
# REF: https://docs.kernel.org/gpu/amdgpu/module-parameters.html

# Validate modprobe parameters against what the running kernel actually supports.
# This prevents "unknown parameter" errors that cause amdgpu probe failure (-22).
MODPROBE_PARAMS="sg_display ppfeaturemask gpu_recovery audio dc"
MODINFO_OUT=$(modinfo amdgpu 2>/dev/null || true)
for param in $MODPROBE_PARAMS; do
    if [ -n "$MODINFO_OUT" ] && ! echo "$MODINFO_OUT" | grep -q "parm:.*${param}:"; then
        echo -e "  ${YELLOW}[WARN]${NC} amdgpu parameter '$param' not recognized by this kernel — will be written to modprobe.d but may be silently ignored at runtime"
    fi
done

cat <<'EOF' > /etc/modprobe.d/amdgpu.conf
# AMD iGPU (Raphael RDNA2 gfx1036) display configuration
# Applied at module load time — affects initramfs and runtime
#
# ONLY validated modprobe params go here (listed by `modinfo amdgpu`).
# Kernel-cmdline-only params (gfx_off, dcdebugmask) are in GRUB only —
# putting them here causes "unknown parameter" errors on kernel 6.8 GA,
# which can cascade into amdgpu probe failure (error -22).
#
# sg_display=0 — Disables scatter-gather DMA for display
#   Prevents black screen/corruption on Raphael iGPU
#   REF: https://bugs.launchpad.net/bugs/2038998
#
# ppfeaturemask=0xfffd7fff — Disables PP_GFXOFF + PP_STUTTER_MODE
#   Firmware-level GFXOFF disable. Subsumes gfx_off=0 (which is set
#   in GRUB cmdline as belt-and-suspenders for kernels that support it).
#   REF: https://docs.kernel.org/gpu/amdgpu/module-parameters.html
#
# gpu_recovery=1 — Enables automatic GPU hang recovery
#   If iGPU hangs, kernel resets it instead of freezing display
#
# audio=1 — Enables HDMI/DP audio from motherboard outputs
#
# dc=1 — Explicitly enables Display Core subsystem
options amdgpu sg_display=0
options amdgpu ppfeaturemask=0xfffd7fff
options amdgpu gpu_recovery=1
options amdgpu audio=1
options amdgpu dc=1
EOF

echo -e "  ${GREEN}Created /etc/modprobe.d/amdgpu.conf${NC}"

###############################################################################
# STEP 3: Install HWE kernel (fixes gfx ring timeout at kernel level)
###############################################################################
echo -e "\n${BLUE}[Step 3/7]${NC} Installing HWE kernel..."

# WHY HWE INSTEAD OF GA:
#   Kernel 6.8 (GA) has an unfixed GFXOFF (GFX power gating) bug for the
#   Raphael iGPU (gfx1036). When the iGPU enters GFXOFF sleep, it fails to
#   wake correctly, causing "ring gfx_0.0.0 timeout" errors (amdgpu_job_timedout).
#   The workarounds (gfx_off=0, ppfeaturemask) disable GFXOFF entirely — they're
#   band-aids, not fixes. The actual fix is a GFXOFF rework for GC 10.3.x that
#   landed upstream in kernels 6.9-6.11.
#
#   REF: https://gitlab.freedesktop.org/drm/amd/-/issues/3006
#   REF: https://bbs.archlinux.org/viewtopic.php?id=299047 (SOLVED with newer kernel)
#   REF: https://forum.endeavouros.com/t/amdgpu-ring-gfx-0-0-0-timeout/74670
#
# WHY HWE 6.17 IS SAFE FOR NVIDIA 595:
#   The old concern was: "HWE breaks NVIDIA". That was true for NVIDIA 470/535/550
#   due to the fbdev header rename (drm_fbdev_generic.h → drm_fbdev_ttm.h) in
#   kernel 6.11. But that was fixed in NVIDIA 550.135 (Nov 2024), and 595.58.03
#   inherits the fix. NVIDIA's own docs confirm:
#
#   - 595.58.03 release notes: "Fixed kernel module build issues with Linux kernel 6.19"
#     This means the entire 6.8-6.19 range is supported.
#     REF: https://docs.nvidia.com/datacenter/tesla/tesla-release-notes-595-58-03/
#
#   - CUDA 13.2 installation guide validates Ubuntu 24.04 with kernel 6.17.0-19
#     REF: https://docs.nvidia.com/cuda/cuda-installation-guide-linux/
#
#   - The fbdev fix timeline:
#     550.135 (Nov 2024) → first fix
#     560+, 565, 570, 580, 590 → all carry the fix
#     595.58.03 (Mar 2026) → fully supports 6.11-6.19
#     REF: https://bbs.archlinux.org/viewtopic.php?id=299450 (original break report)
#
# UBUNTU 24.04 HWE TIMELINE:
#   24.04.0/1 (Apr/Aug 2024) → 6.8 GA
#   24.04.2   (Feb 2025)     → 6.11 HWE
#   24.04.3   (Aug 2025)     → 6.14 HWE
#   24.04.4   (Feb 2026)     → 6.17 HWE ← current linux-generic-hwe-24.04
#   REF: https://wiki.ubuntu.com/Kernel/LTSEnablementStack
#
# WHAT WE DO:
#   1. Remove any existing GA kernel pin/hold (from previous script versions)
#   2. Install HWE kernel metapackage (kernel 6.17)
#   3. Keep GA kernel installed as GRUB fallback (do NOT remove linux-generic)
#   4. Ensure GRUB boots the latest (HWE) kernel by default
#
# SAFETY NET:
#   If HWE causes issues, select "Advanced options" → kernel 6.8 from GRUB menu.
#   The gfx_off=0 and ppfeaturemask workarounds in GRUB_PARAMS provide ring
#   timeout protection on the 6.8 fallback kernel.

# Remove any kernel pin from previous script versions
if [ -f /etc/apt/preferences.d/pin-kernel-ga ]; then
    rm -f /etc/apt/preferences.d/pin-kernel-ga
    echo "  Removed old kernel pin (/etc/apt/preferences.d/pin-kernel-ga)"
fi
apt-mark unhold linux-generic linux-image-generic linux-headers-generic 2>/dev/null || true

# Ensure GA kernel is installed (kept as GRUB fallback)
apt install -y linux-generic 2>/dev/null || true

# Install HWE kernel (6.17 as of Ubuntu 24.04.4)
# This pulls in linux-image-generic-hwe-24.04 + linux-headers-generic-hwe-24.04
echo "  Installing HWE kernel package..."
apt install -y linux-generic-hwe-24.04 2>/dev/null

# Verify HWE kernel image was installed
HWE_KERNEL=$(dpkg -l 'linux-image-*-generic' 2>/dev/null | awk '/^ii.*hwe/{print $2}' | sort -V | tail -1)
GA_KERNEL=$(dpkg -l 'linux-image-*-generic' 2>/dev/null | awk '/^ii/ && !/hwe/{print $2}' | sort -V | tail -1)

if [ -n "$HWE_KERNEL" ]; then
    echo -e "  ${GREEN}HWE kernel installed: ${HWE_KERNEL}${NC}"
else
    echo -e "  ${YELLOW}WARNING: HWE kernel package not detected — will fall back to GA${NC}"
    echo "         The gfx_off=0 workaround will protect against ring timeouts on 6.8"
fi

if [ -n "$GA_KERNEL" ]; then
    echo "  GA kernel (fallback): ${GA_KERNEL}"
fi

# Ensure GRUB boots the latest kernel by default (not a saved selection)
# WHY: If GRUB_DEFAULT is set to "saved" from a previous config, it might boot
#      the old GA kernel instead of the new HWE kernel.
if grep -q '^GRUB_DEFAULT=saved' /etc/default/grub; then
    sed -i 's/^GRUB_DEFAULT=saved/GRUB_DEFAULT=0/' /etc/default/grub
    echo "  Set GRUB_DEFAULT=0 (boots latest kernel)"
    update-grub 2>/dev/null
fi

echo ""
echo "  Current running kernel: $(uname -r)"
echo "  After reboot: HWE kernel will be active (select 'Advanced options' in GRUB for GA fallback)"

###############################################################################
# STEP 4: Disable gpu-manager
###############################################################################
echo -e "\n${BLUE}[Step 4/7]${NC} Disabling Ubuntu gpu-manager..."

# WHY: Ubuntu's gpu-manager is a service that runs at boot and generates
#      /etc/X11/xorg.conf based on detected GPUs. In a dual-GPU system:
#      - It often chooses NVIDIA as the display GPU (wrong for our config)
#      - It overwrites our carefully crafted xorg.conf.d settings
#      - It can cause display to switch between GPUs unpredictably
#
# We disable it via both kernel parameter (nogpumanager, already in GRUB)
# and systemd (mask prevents it from ever running).
#
# REF: https://gist.github.com/wangruohui/bc7b9f424e3d5deb0c0b8bba990b1bc5

systemctl disable gpu-manager 2>/dev/null || true
systemctl mask gpu-manager 2>/dev/null || true

# Remove any auto-generated xorg.conf that gpu-manager created
if [ -f /etc/X11/xorg.conf ]; then
    mv /etc/X11/xorg.conf /etc/X11/xorg.conf.gpu-manager-backup.$(date +%Y%m%d%H%M%S)
    echo "  Backed up and removed gpu-manager-generated /etc/X11/xorg.conf"
fi

echo -e "  ${GREEN}gpu-manager disabled and masked${NC}"

###############################################################################
# STEP 5: Configure display manager (GDM3)
###############################################################################
echo -e "\n${BLUE}[Step 5/7]${NC} Configuring GDM3 display manager..."

# WHY X11 over Wayland (for initial setup):
#   - X11 allows explicit BusID pinning in xorg.conf — deterministic GPU assignment
#   - X11 has lower CPU overhead with NVIDIA driver loaded (even when GPU is headless)
#     Wayland compositors consume 20-50% CPU inside nvidia.ko when nvidia module is loaded
#     REF: https://dasroot.net/posts/2025/11/wayland-vs-x11/
#   - X11 VRAM fallback is better — under X11, NVIDIA driver can spill to system RAM;
#     under Wayland, it crashes on OOM
#     REF: https://github.com/NVIDIA/egl-wayland/issues/185
#   - X11 doesn't suffer from the GLVidHeapReuseRatio VRAM leak bug
#     REF: https://forums.developer.nvidia.com/t/multiple-wayland-compositors-not-freeing-vram-after-resizing-windows/307939
#   - X11 is more stable for this dual-GPU configuration during initial setup
#
# NOTE: You can switch to Wayland later if you need:
#   - Mixed refresh rate multi-monitor (Wayland handles natively, X11 locks to lowest)
#   - Fractional HiDPI scaling (Wayland native; X11 requires complex xrandr workarounds)
#   To switch: change WaylandEnable=true in /etc/gdm3/custom.conf and reboot

# Create deterministic backup for rollback script (99-rollback.sh)
cp /etc/gdm3/custom.conf /etc/gdm3/custom.conf.bak.ml-setup 2>/dev/null || true

cat <<'EOF' > /etc/gdm3/custom.conf
# GDM3 Display Manager Configuration
# Modified by ml-workstation-setup for dual-GPU (AMD iGPU display + NVIDIA compute)
#
# WaylandEnable=false forces X11 for maximum stability during initial setup
# WHY X11: Deterministic GPU pinning via xorg.conf, lower CPU overhead with
#          nvidia.ko loaded, better VRAM management, no GLVidHeapReuseRatio bug
# REF: https://dasroot.net/posts/2025/11/wayland-vs-x11/
# REF: https://github.com/NVIDIA/egl-wayland/issues/185
#
# TO SWITCH TO WAYLAND LATER: Change WaylandEnable=true and reboot
# Wayland is recommended for: mixed-refresh multi-monitor, HiDPI fractional scaling

[daemon]
WaylandEnable=false

[security]

[xdmcp]

[chooser]

[debug]
EOF

echo -e "  ${GREEN}GDM3 configured for X11${NC}"

###############################################################################
# STEP 6: Update Raphael iGPU firmware from upstream linux-firmware
###############################################################################
echo -e "\n${BLUE}[Step 6/7]${NC} Updating Raphael iGPU firmware..."

# WHY: Ubuntu 24.04 noble ships linux-firmware 20240318 which contains OUTDATED
#      GC 10.3.6 firmware for the Raphael iGPU. The updated firmware (upstream
#      commit 6f3948e by Alex Deucher, included in tag 20260309) fixes SMU-related
#      gfx ring timeouts on gfx1036. This fix has NOT been backported to any
#      Ubuntu 24.04 package — not in noble-updates (.25) nor noble-proposed (.26).
#      Manual install from upstream is the only path.
#
#   REF: https://bugs.launchpad.net/ubuntu/+source/linux/+bug/2081092
#   REF: https://github.com/nixos/nixpkgs/issues/466945
#   REF: https://kernel.googlesource.com/pub/scm/linux/kernel/git/firmware/linux-firmware/
#
# FIRMWARE FILES for Raphael iGPU (gfx1036, PCI 0x164e):
#   GC 10.3.6:  gc_10_3_6_{ce,me,mec,mec2,pfp,rlc}.bin  — Graphics Compute
#   PSP 13.0.5: psp_13_0_5_toc.bin                        — Platform Security Processor
#   DCN 3.1.5:  dcn_3_1_5_dmcub.bin                       — Display Core Next
#   SDMA 5.2.6: sdma_5_2_6.bin                            — System DMA
#   VCN 3.1.2:  vcn_3_1_2.bin                             — Video Core Next

# First, update the apt package to get any other firmware fixes
CURRENT_FW=$(dpkg -l linux-firmware 2>/dev/null | awk '/^ii/{print $3}')
echo "  Current linux-firmware package: ${CURRENT_FW:-not installed}"
apt update -qq
apt install -y linux-firmware 2>/dev/null
UPDATED_FW=$(dpkg -l linux-firmware 2>/dev/null | awk '/^ii/{print $3}')
if [ "$CURRENT_FW" != "$UPDATED_FW" ]; then
    echo -e "  ${GREEN}linux-firmware package updated: ${CURRENT_FW} → ${UPDATED_FW}${NC}"
else
    echo -e "  linux-firmware package unchanged: ${UPDATED_FW}"
fi

# Now install upstream Raphael firmware (the part Ubuntu hasn't backported)
echo ""
echo "  Installing upstream GC 10.3.6 firmware (not yet in Ubuntu 24.04 repos)..."

UPSTREAM_URL="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/amdgpu"
FW_DIR="/lib/firmware/amdgpu"
BACKUP_DIR="${FW_DIR}/backup-pre-ml-setup"

# Raphael iGPU firmware files — all IP blocks
RAPHAEL_FW=(
    "gc_10_3_6_ce.bin"
    "gc_10_3_6_me.bin"
    "gc_10_3_6_mec.bin"
    "gc_10_3_6_mec2.bin"
    "gc_10_3_6_pfp.bin"
    "gc_10_3_6_rlc.bin"
    "psp_13_0_5_toc.bin"
    "dcn_3_1_5_dmcub.bin"
    "sdma_5_2_6.bin"
    "vcn_3_1_2.bin"
)

# Back up existing firmware before overwriting
mkdir -p "$BACKUP_DIR"
for fw in "${RAPHAEL_FW[@]}"; do
    if [ -f "${FW_DIR}/${fw}" ]; then
        cp "${FW_DIR}/${fw}" "${BACKUP_DIR}/${fw}"
    fi
done
echo "  Backed up existing firmware to ${BACKUP_DIR}/"

# Download each firmware file from upstream
FW_OK=0
FW_FAIL=0
for fw in "${RAPHAEL_FW[@]}"; do
    if wget -q --timeout=15 -O "${FW_DIR}/${fw}.tmp" "${UPSTREAM_URL}/${fw}" 2>/dev/null; then
        mv "${FW_DIR}/${fw}.tmp" "${FW_DIR}/${fw}"
        FW_OK=$((FW_OK+1))
    else
        rm -f "${FW_DIR}/${fw}.tmp"
        echo -e "    ${YELLOW}Could not download ${fw} — keeping existing${NC}"
        FW_FAIL=$((FW_FAIL+1))
    fi
done

if [ $FW_OK -gt 0 ]; then
    echo -e "  ${GREEN}Updated ${FW_OK}/${#RAPHAEL_FW[@]} Raphael firmware files from upstream${NC}"
fi
if [ $FW_FAIL -gt 0 ]; then
    echo -e "  ${YELLOW}${FW_FAIL} files failed to download (network issue?)${NC}"
    echo "  Fallback: clone https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git"
    echo "  and copy amdgpu/gc_10_3_6_*.bin + related files to ${FW_DIR}/"
fi

# Verify all critical firmware files are present
MISSING=0
for fw in "${RAPHAEL_FW[@]}"; do
    if [ ! -f "${FW_DIR}/${fw}" ]; then
        echo -e "  ${RED}MISSING: ${FW_DIR}/${fw}${NC}"
        MISSING=$((MISSING+1))
    fi
done
if [ $MISSING -eq 0 ]; then
    echo -e "  ${GREEN}All ${#RAPHAEL_FW[@]} Raphael iGPU firmware files present${NC}"
else
    echo -e "  ${RED}${MISSING} firmware files missing — gfx ring timeouts may persist${NC}"
fi

###############################################################################
# STEP 7: Install essential display utilities
###############################################################################
echo -e "\n${BLUE}[Step 7/7]${NC} Installing essential display utilities..."

# These packages are needed for display verification and troubleshooting
apt update -qq
apt install -y \
    mesa-utils \
    mesa-va-drivers \
    vainfo \
    radeontop \
    htop \
    inxi \
    pciutils \
    2>/dev/null

echo -e "  ${GREEN}Display utilities installed${NC}"

###############################################################################
# Update initramfs with all changes
###############################################################################
echo -e "\n${BLUE}[Final]${NC} Updating initramfs..."
update-initramfs -u -k all 2>/dev/null
echo -e "  ${GREEN}initramfs updated${NC}"

###############################################################################
# Summary and next steps
###############################################################################
echo ""
echo -e "${BOLD}================================================================${NC}"
echo -e "${GREEN}${BOLD}  Phase 1 Complete!${NC}"
echo -e "${BOLD}================================================================${NC}"
echo ""
echo "  Changes applied:"
echo "    [1] GRUB kernel parameters for iGPU stability + PCIe + IOMMU + CPU"
echo "        Includes gfx_off=0 + ppfeaturemask + processor.max_cstate=1 + amd_pstate=active"
echo "    [2] amdgpu modprobe options (sg_display, PSR, GFXOFF, recovery)"
echo "    [3] HWE kernel 6.17 installed (GA 6.8 kept as GRUB fallback)"
echo "    [4] gpu-manager disabled and masked"
echo "    [5] GDM configured for X11"
echo "    [6] Raphael iGPU firmware updated from upstream (not in Ubuntu repos)"
echo "    [7] Display utilities installed"
echo ""
echo -e "  ${YELLOW}REBOOT REQUIRED to apply changes.${NC}"
echo ""
echo "  After reboot, run the verification script:"
echo "    sudo bash 00-verify-bios-prerequisites.sh"
echo ""
echo "  Then proceed to Phase 2: NVIDIA driver installation:"
echo "    sudo bash 02-install-nvidia-driver.sh"
echo ""
echo -e "  ${YELLOW}BIOS SETTING (do this before reboot):${NC}"
echo "    Set UMA Frame Buffer Size → 2G (not Auto or 512M)"
echo "    Path: Advanced → NB Configuration → UMA Frame Buffer Size"
echo "    WHY: Larger VRAM pool reduces page faults that cause gfx ring timeouts"
echo ""
echo -e "  ${YELLOW}If you get a black screen after reboot:${NC}"
echo "    1. At GRUB menu → press 'e' → verify amdgpu.sg_display=0 is present"
echo "    2. If still black: add 'nomodeset' to the linux line"
echo "    3. If still black: switch display cable between HDMI and USB-C on motherboard"
echo "    4. If all else fails: press Ctrl+Alt+F2 for TTY console"
echo ""
echo -e "  ${YELLOW}If gfx ring timeouts persist after reboot on HWE 6.17:${NC}"
echo "    Tier 1 (already applied): HWE kernel + gfx_off=0 + ppfeaturemask + firmware + processor.max_cstate=1"
echo "    Tier 2: Check BIOS: UMA Frame Buffer → 2G, Global C-state Control → Disabled, DF C-states → Disabled"
echo "    Tier 3: Add 'amdgpu.runpm=0' to GRUB (disable amdgpu runtime PM)"
echo "    Tier 4: Relax to 'processor.max_cstate=5' if power savings needed (test stability first)"
echo "    Fallback: Boot GA kernel 6.8 from GRUB → gfx_off=0 workaround active"
echo ""
read -p "Press Enter to reboot now, or Ctrl+C to reboot manually later... "
reboot
