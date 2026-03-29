# BIOS Checklist — ASUS ROG Crosshair X670E Hero

**BIOS Version:** 3603 (March 18, 2026)
**AGESA:** ComboAM5 PI 1.3.0.0a
**System:** Ryzen 9 7950X + RTX 4090 (headless compute) + Raphael iGPU (display)
**Purpose:** Dual-GPU ML workstation — Ubuntu 24.04

All paths verified against the official ROG Crosshair X670E Hero BIOS manual
and cross-referenced with ASUS FAQ articles and user reports for BIOS 3603.

---

## How to Use

1. Enter BIOS: Press **DEL** during POST (or F2)
2. Switch to **Advanced Mode** (F7)
3. Walk through each setting below in order
4. **Save & Exit** (F10) when done
5. Boot Ubuntu, run: `sudo bash 00-verify-bios-prerequisites.sh`

Settings are grouped by BIOS tab/submenu to minimize navigation.
Complete one section before moving to the next.

---

## TIER 1 — MUST HAVE (11 settings)

Without these, display will not work, NVIDIA driver will fail, or system will be unstable.

### Advanced Tab → NB Configuration

| # | Setting | Value | Default | Why |
|---|---------|-------|---------|-----|
| B1 | **IGFX Multi-Monitor** | **Enabled** (verify — may be hidden) | Enabled (AM5 default) | Keeps iGPU active when dGPU is installed. On AM5 boards this is enabled by default and the setting may not be visible in BIOS. If you don't see it, it's already enabled. Verify in Linux: `lspci \| grep -i "AMD.*VGA"` must show the Raphael iGPU. REF: https://www.asus.com/support/faq/1045574/ |
| B2 | **Primary Video Device** | **IGFX Video** | PCIE Video | BIOS POSTs on iGPU so you see output from motherboard HDMI/USB-C. If set to PCIE, you see nothing on motherboard outputs until OS boots. |
| B9 | **UMA Frame Buffer Size** | **2G** | Auto (512M) | Allocates 2 GB system RAM as iGPU VRAM. Default 512M causes page faults during compositing → gfx ring timeouts. REF: https://gitlab.freedesktop.org/drm/amd/-/issues/3006 |

### Advanced Tab → PCI Subsystem Settings

| # | Setting | Value | Default | Why |
|---|---------|-------|---------|-----|
| B3 | **Above 4G Decoding** | **Enabled** | Disabled | Required to map RTX 4090's 24 GB VRAM BAR into CPU address space. Without this, GPU may fail to initialize. |
| B16 | **Re-Size BAR Support** | **Enabled** | Disabled | Appears only when Above 4G Decoding is Enabled. Allows full 24 GB VRAM mapping (vs 256 MB window). 5-15% memory transfer improvement. CSM must be Disabled. Exact label: "Re-Size BAR Support". REF: https://nvidia.custhelp.com/app/answers/detail/a_id/5165 |

### Advanced Tab → AMD CBS → IOMMU

| # | Setting | Value | Default | Why |
|---|---------|-------|---------|-----|
| B6 | **IOMMU** | **Enabled** | Auto | **NOTE: On Crosshair X670E Hero, IOMMU is at the AMD CBS root level, NOT nested under NBIO Common Options.** Required for kernel `iommu=pt` parameter. Enables IOMMU hardware for pass-through DMA. |

### Advanced Tab → AMD CBS → CPU Common Options

| # | Setting | Value | Default | Why |
|---|---------|-------|---------|-----|
| B4 | **SMEE** | **Disabled** | Auto | Secure Memory Encryption Enable. NVIDIA driver cannot DMA to encrypted memory — hard incompatibility with zero workaround. Results in "Failed to initialize DMA" errors. REF: https://github.com/NVIDIA/open-gpu-kernel-modules/issues/340 |

### Advanced Tab → AMD CBS → UMC Common Options → DDR Security

| # | Setting | Value | Default | Why |
|---|---------|-------|---------|-----|
| B5 | **TSME** | **Disabled** | Auto | Transparent SME. **NOTE: On Crosshair X670E Hero, TSME is under UMC Common Options → DDR Security, NOT under CPU Common Options.** Same DMA failure as SMEE — all memory encrypted regardless of OS settings. |

### Advanced Tab → Onboard Devices Configuration — ASPM Controls

| # | Setting | Value | Default | Why |
|---|---------|-------|---------|-----|
| B7 | **Native ASPM** | **Enabled** | Auto | **Hands ASPM control from BIOS firmware to the Linux kernel.** When Disabled (BIOS-managed), the firmware configures L0s/L1 states during POST and the kernel cannot override them — NVIDIA developer forums confirm "BIOS-controlled PCIe ASPM is broken with all NVIDIA cards." When Enabled, the OS takes control via ACPI _OSC handoff, and the kernel's `pcie_aspm=off` parameter then effectively prevents any ASPM states from being activated. **NOTE: Previously listed as "PSPP Policy" under NBIO Common Options — PSPP controls PCIe link *speed* (Gen4→Gen3 downshift), NOT ASPM power states. PSPP is not visible in BIOS 3603 on this board and is irrelevant to Xid 79.** REF: https://forums.developer.nvidia.com/t/nvidia-driver-xid-79-gpu-crash-while-idling-if-aspm-l0s-is-enabled-in-uefi-bios-gpu-has-fallen-off-the-bus/314453 |
| B7b | **CPU PCIE ASPM Mode Control** | **Disabled** | Auto | **THE critical ASPM setting for RTX 4090 stability.** Controls L0s/L1 power states on CPU-direct PCIe lanes — which is where the RTX 4090 x16 slot connects. L0s (low-latency standby) is the confirmed culprit for Xid 79 "GPU has fallen off the bus" errors during idle. Disabling here kills L0s/L1 at hardware level on the GPU's PCIe lanes. REF: https://forums.developer.nvidia.com/t/gpu-has-fallen-off-the-bus-issues-on-daily-basis-rtx-4090/314647 |

### Boot Tab → Secure Boot

| # | Setting | Value | Default | Why |
|---|---------|-------|---------|-----|
| B8 | **OS Type** | **Other OS** | Windows UEFI Mode | **NOTE: "Secure Boot State" is a read-only display field. The actual control is "OS Type".** Setting to "Other OS" disables Secure Boot. Simplifies NVIDIA driver loading (no MOK key enrollment needed). |

### Advanced Tab → AMD CBS → NBIO Common Options → SMU Common Options

| # | Setting | Value | Default | Why |
|---|---------|-------|---------|-----|
| B22 | **GFXOFF** | **Disabled** | Auto | **CRITICAL: BIOS-level master switch for GFX power gating on the Raphael iGPU.** GFXOFF puts the iGPU graphics engine into deep sleep when idle. Wake-up from this state frequently fails on gfx1036, causing "ring gfx_0.0.0 timeout" errors and `amdgpu probe failed with error -22`. Disabling here is the **most authoritative** level — prevents the SMU from enabling GFXOFF before any OS/driver code runs. This creates a three-layer GFXOFF disable: Layer 1 (BIOS/SMU) = GFXOFF Disabled, Layer 2 (firmware) = `ppfeaturemask=0xfffd7fff` in modprobe.d, Layer 3 (driver) = `amdgpu.gfx_off=0` in GRUB. REF: https://gitlab.freedesktop.org/drm/amd/-/issues/3006 |

---

## TIER 2 — NICE TO HAVE (8 settings)

Improve stability and reliability. Scripts will install without these, but intermittent issues may occur.

### Advanced Tab → PCIEX16_1 Link Mode (top-level Advanced menu)

| # | Setting | Value | Default | Why |
|---|---------|-------|---------|-----|
| B10 | **PCIEX16_1 Link Mode** | **Gen 4** | Auto | Force PCIe Gen 4 for the x16 GPU slot. RTX 4090 is PCIe 4.0 — Auto may attempt Gen 5 link training (which GPU doesn't support), causing unnecessary retraining cycles. **NOTE: This setting is at the top level of the Advanced menu (not under NBIO Common Options).** The BIOS tree map shows `Advanced → PCIEX16_1 Link Mode [Auto], [Gen1] - [Gen5]`. If not found, leave at Auto — the GPU being Gen 4 natively usually negotiates correctly. REF: https://rog-forum.asus.com/t5/nvidia-graphics-cards/solved-how-to-enable-pcie-gen-4-5-link-speed-full-16x-lanes/td-p/1114798 |

### Extreme Tweaker Tab → Clock Spread Spectrum

| # | Setting | Value | Default | Why |
|---|---------|-------|---------|-----|
| B17 | **Clock Spread Spectrum** | **Disabled** | Auto | Reduces EMI but introduces clock jitter that can destabilize PCIe signaling. Disable for cleaner clock signals. **NOTE: On ROG boards, this is under Extreme Tweaker (not "Ai Tweaker" or NBIO Common Options).** If not visible, skip — impact is minimal. |

### Advanced Tab → AMD CBS → Global C-state Control

| # | Setting | Value | Default | Why |
|---|---------|-------|---------|-----|
| B11 | **Global C-state Control** | **Disabled** | Auto | **NOTE: On Crosshair X670E Hero, this is at the AMD CBS root level (directly under Advanced → AMD CBS), NOT nested inside CPU Common Options.** Disables CPU C-states at hardware level. Ryzen 7000 has documented C6 freezes. Belt-and-suspenders with kernel `processor.max_cstate=1`. Cost: ~2-3 W idle. REF: https://bugzilla.kernel.org/show_bug.cgi?id=206299 |

### Advanced Tab → AMD CBS → DF Common Options

| # | Setting | Value | Default | Why |
|---|---------|-------|---------|-----|
| B12 | **DF Cstates** | **Disabled** | Auto | Data Fabric C-states. DF entering deep idle can stall PCIe transactions and cause latency spikes during GPU DMA transfers. Cost: ~2-3 W idle. |

### Advanced Tab → AMD PBS → Graphics Features

| # | Setting | Value | Default | Why |
|---|---------|-------|---------|-----|
| B15 | **D3Cold Support** | **Disabled** | Enabled | **NOTE: Exact label is "D3Cold Support" (not "PCIe x16 Slot D3Cold").** Prevents OS from completely cutting power to the PCIe slot. Combined with ASPM disable (B7/B7b) and `pcie_aspm=off` kernel param, provides full protection against PCIe power-related GPU disconnections. |

### Advanced Tab → APM Configuration

| # | Setting | Value | Default | Why |
|---|---------|-------|---------|-----|
| B13 | **Restore AC Power Loss** | **Power On** | Power Off | Auto-restart after power outage during long training runs. **NOTE: ErP Ready must be Disabled for this option to be configurable.** |

### Boot Tab

| # | Setting | Value | Default | Why |
|---|---------|-------|---------|-----|
| B14 | **Wait For 'F1' If Error** | **Disabled** | Enabled | Prevents BIOS from halting boot on non-critical errors (fan speed, USB). Combined with B13, enables fully unattended recovery from power events. |

---

## TIER 3 — ML OPTIMIZED (8 settings)

Tuning specifically for AI model training throughput. No effect on display or driver operation.

### Extreme Tweaker Tab

| # | Setting | Value | Default | Why |
|---|---------|-------|---------|-----|
| B25 | **Core Performance Boost** | **Enabled** | Enabled | Master toggle for AMD's dynamic frequency scaling (PBO, Curve Optimizer). If disabled, CPU runs at base clock only (4.5 GHz) and all boost logic is inactive. Verify this is Enabled — some BIOS updates or CMC clears can reset it. |

### Extreme Tweaker Tab → Precision Boost Overdrive

| # | Setting | Value | Default | Why |
|---|---------|-------|---------|-----|
| B18 | **Eco Mode** | **Disabled** (or Auto if no Eco option listed) | Auto | **NOTE: On Crosshair X670E Hero (ROG board), the overclocking tab is called "Extreme Tweaker", NOT "Ai Tweaker" (which is used on TUF/PRIME boards).** Path: Extreme Tweaker → Precision Boost Overdrive → Eco Mode. Eco Mode caps TDP to 65W — severely limits data loading throughput on a 170W CPU. Options may show as [Auto] [Eco 170W] [Eco 105W] [Eco 65W]. |

### Advanced Tab → AMD CBS → CPU Common Options

| # | Setting | Value | Default | Why |
|---|---------|-------|---------|-----|
| B21 | **Power Supply Idle Control** | **Typical Current Idle** | Auto | Prevents CPU from entering deepest idle where VRM transitions to very low current mode. Eliminates one source of latency jitter during data loading. |

### Advanced Tab → AMD CBS → NBIO Common Options → SMU Common Options

| # | Setting | Value | Default | Why |
|---|---------|-------|---------|-----|
| B19 | **APBDIS** | **1** (Fixed SOC Pstate = P0) | Auto (0) | **NOTE: APBDIS may NOT be visible in default BIOS mode on the Crosshair X670E Hero.** The BIOS manual does not document it. If not found under SMU Common Options, skip — the SoC will still dynamically adjust and the impact on ML training is small (~2-5% DMA consistency). If visible, setting to 1 locks SoC frequency for consistent IOMMU/memory controller throughput. |

### Advanced Tab → AMD CBS → UMC Common Options → DDR Options → DDR Memory Features

| # | Setting | Value | Default | Why |
|---|---------|-------|---------|-----|
| B20 | **Memory Context Restore** | **Enabled** | Disabled | **NOTE: MCR exists in TWO places: (1) AMD CBS → UMC Common Options → DDR Options → DDR Memory Features → Memory Context Restore, and (2) Extreme Tweaker → DRAM Timing Control → Memory Context Restore. Enable in the AMD CBS path. If the Extreme Tweaker copy conflicts, set it to Auto or Disabled there.** Also ensure Power Down Enable is [Enabled] when MCR is active. Saves DDR5 training parameters for faster S3 resume (~30-60s savings). |

### Advanced Tab → AMD CBS → CPU Common Options

| # | Setting | Value | Default | Why |
|---|---------|-------|---------|-----|
| B26 | **AVX512** | **Enabled** | Auto | Zen 4 (Ryzen 7950X stepping 2) supports AVX-512 for 256-bit vector operations. Some ML frameworks (TensorFlow, PyTorch with oneDNN) can use AVX-512 for vectorized CPU-side data preprocessing. If not visible in BIOS, the CPU may not support it (stepping 0) or it's enabled by default under Auto — either case is fine. |

### Advanced Tab → AMD CBS → DF Common Options

| # | Setting | Value | Default | Why |
|---|---------|-------|---------|-----|
| B27 | **ACPI SRAT L3 Cache As NUMA Domain** | **Disabled** | Auto | When Enabled, each L3 cache (one per CCD on 7950X) is exposed as a separate NUMA node to the OS. For ML workstations using NPS1 (single NUMA), leave Disabled to keep a unified memory view for CUDA. Enable only if running NUMA-aware ML pipelines that benefit from per-CCD cache locality. |

### Advanced Tab → PCI Subsystem Settings

| # | Setting | Value | Default | Why |
|---|---------|-------|---------|-----|
| B28 | **SR-IOV Support** | **Enabled** | Disabled | Single Root I/O Virtualization. Required for GPU passthrough to Docker containers (NVIDIA Container Toolkit), VFIO passthrough, or KVM guests. Enables the RTX 4090 to appear as multiple virtual PCIe devices. If not using containers or VMs, can leave at Disabled. |

---

## Verification After Configuration

After saving BIOS settings and booting Ubuntu:

```bash
# Run the verification script (checks everything it can from Linux)
sudo bash 00-verify-bios-prerequisites.sh

# Manual spot-checks for BIOS-only settings the script can't verify:
# (These are displayed as INFO reminders by the verification script)

# Verify iGPU is active
lspci | grep -i "AMD.*VGA"

# Verify RTX 4090 is detected
lspci | grep -i NVIDIA

# Verify PCIe link (should show Gen 4 x16)
sudo lspci -vvv -s $(lspci | grep -i NVIDIA | awk '{print $1}') | grep -A2 "LnkSta:"

# Verify ASPM is off (check per-device state on GPU)
sudo lspci -vv -s $(lspci | grep -i NVIDIA | awk '{print $1}') | grep -i "ASPM.*abled"

# Verify SME is NOT active
dmesg | grep -i "SME\|encrypt"

# Verify IOMMU pass-through
dmesg | grep -i "AMD-Vi"

# Verify iGPU VRAM (UMA Frame Buffer) — should be ~2048 MB
cat /sys/class/drm/card0/device/mem_info_vram_total 2>/dev/null | awk '{print $1/1024/1024 " MB"}'

# Verify ReBAR (should show ~24576 MiB, not 256 MiB)
nvidia-smi -q | grep -A3 "BAR1"

# Verify CPU scaling driver
cat /sys/devices/system/cpu/cpufreq/policy0/scaling_driver
```

---

## Path Corrections vs Other Documentation

The following paths differ from what is commonly documented online (and from
the earlier `BIOS-SETTINGS-COMPLETE-GUIDE.md`). These corrections are verified
against the official Crosshair X670E Hero BIOS manual for BIOS 3603:

| Setting | Commonly Listed Path | Actual Path on Crosshair X670E Hero |
|---------|---------------------|-------------------------------------|
| IGFX Multi-Monitor | Advanced → NB Configuration → IGFX Multi-Monitor | **Not visible** — AM5 boards enable dual display by default (ASUS FAQ #1045574) |
| TSME | Advanced → AMD CBS → CPU Common Options → TSME | **Advanced → AMD CBS → UMC Common Options → DDR Security → TSME** |
| IOMMU | Advanced → AMD CBS → NBIO Common Options → IOMMU | **Advanced → AMD CBS → IOMMU** (at CBS root level) |
| Global C-state Control | Advanced → AMD CBS → CPU Common Options → Global C-state Control | **Advanced → AMD CBS → Global C-state Control** (at CBS root level) |
| Secure Boot | Boot → Secure Boot → Secure Boot State | **Boot → Secure Boot → OS Type** (State is read-only) |
| D3Cold | Advanced → AMD PBS → PCIe x16 Slot D3Cold | **Advanced → AMD PBS → Graphics Features → D3Cold Support** |
| Re-Size BAR | Resizable BAR | **Re-Size BAR Support** (exact label) |
| Eco Mode | Ai Tweaker → PBO → ... | **Extreme Tweaker → Precision Boost Overdrive → Eco Mode** (ROG boards use "Extreme Tweaker") |
| Memory Context Restore | AMD CBS → UMC Common Options → MCR | **AMD CBS → UMC Common Options → DDR Options → DDR Memory Features → Memory Context Restore** (deeper nesting; also exists in Extreme Tweaker) |
| ASPM | AMD CBS → NBIO Common Options → ASPM / PSPP Policy | **PSPP Policy does NOT exist in BIOS 3603 on this board, and controls link *speed* not ASPM anyway.** The actual ASPM controls are under **Onboard Devices Configuration**: (1) **Native ASPM → Enabled** (hands control to OS), (2) **CPU PCIE ASPM Mode Control → Disabled** (kills L0s/L1 on GPU lanes). ASM1061 ASPM is for SATA controller only — irrelevant to GPU. |
| GFXOFF | Not previously documented | **AMD CBS → NBIO Common Options → SMU Common Options → GFXOFF** — BIOS-level master switch for iGPU GFX power gating. Set to Disabled. |

---

## Quick Reference Card

Print this and keep next to your workstation during BIOS configuration.

```
═══════════════════════════════════════════════════════════════
  BIOS 3603 Quick Reference — Crosshair X670E Hero
  AGESA ComboAM5 PI 1.3.0.0a
═══════════════════════════════════════════════════════════════

  ADVANCED → NB Configuration
    Primary Video Device ........... IGFX Video
    UMA Frame Buffer Size .......... 2G

  ADVANCED → PCI Subsystem Settings
    Above 4G Decoding .............. Enabled
    Re-Size BAR Support ............ Enabled

  ADVANCED → AMD CBS
    IOMMU .......................... Enabled
    Global C-state Control ......... Disabled

  ADVANCED → AMD CBS → NBIO Common Options → SMU Common Options
    GFXOFF ......................... Disabled        ★ NEW

  ADVANCED → AMD CBS → CPU Common Options
    SMEE ........................... Disabled
    Power Supply Idle Control ...... Typical Current Idle
    [AVX512 — if visible] ......... Enabled          ★ NEW

  ADVANCED → AMD CBS → UMC Common Options → DDR Security
    TSME ........................... Disabled

  ADVANCED → AMD CBS → UMC Common Options → DDR Options
    → DDR Memory Features
      Memory Context Restore ....... Enabled

  ADVANCED → AMD CBS → DF Common Options
    DF Cstates ..................... Disabled
    ACPI SRAT L3 NUMA ............. Disabled         ★ NEW

  ADVANCED → Onboard Devices Configuration
    Native ASPM .................... Enabled          ★ CORRECTED (hands control to Linux)
    CPU PCIE ASPM Mode Control ..... Disabled         ★ CRITICAL (kills L0s/L1 on GPU lanes)
    (ASM1061 ASPM Support .......... Disabled — SATA only, not GPU-relevant)

  ADVANCED → AMD CBS → NBIO Common Options
    [PCIe Speed — if visible] ...... Gen 4
    [Spread Spectrum — if visible] . Disabled

  ADVANCED → AMD CBS → NBIO Common Options → SMU Common Options
    [APBDIS — if visible] ......... 1

  ADVANCED → AMD PBS → Graphics Features
    D3Cold Support ................. Disabled

  ADVANCED → PCI Subsystem Settings
    SR-IOV Support ................. Enabled          ★ NEW

  ADVANCED → APM Configuration
    Restore AC Power Loss .......... Power On
    (Requires ErP Ready = Disabled)

  EXTREME TWEAKER
    Core Performance Boost ......... Enabled          ★ NEW
  EXTREME TWEAKER → Precision Boost Overdrive
    Eco Mode ....................... Disabled

  BOOT
    Secure Boot → OS Type .......... Other OS
    Wait For 'F1' If Error ......... Disabled

  SAVE & EXIT (F10)
═══════════════════════════════════════════════════════════════
```
