# ML Workstation Crash Loop: Diagnosis & Prognosis

> **Date**: 2026-03-29 (updated 2026-03-30 with Variant B v2 cross-validation)
> **Test Run**: `runLog-01` (Variant A: Display-Only, No NVIDIA)
> **Source Data**: `logs/runLog-01/diag-20260329-054341/` (14 categories, ~200 files)
> **Comparison**: `logs/runLog-01/runLog-00/` (7 categories, earlier diagnostic of same install)
> **Cross-validation**: Variant B v2 (`logs/runlog-B_v2/`) confirms firmware upgrade to DMUB 0x05002000 eliminates ring timeouts (2026-03-30)

---

## 1. System Under Test

### Hardware (Fixed)

| Component | Value | PCI Address |
|-----------|-------|-------------|
| CPU | AMD Ryzen 9 7950X (Zen 4, 16C/32T) | --- |
| iGPU | AMD Raphael (RDNA2, GC 10.3.6, DCN 3.1.5, 2 CUs) | `0000:6c:00.0` |
| dGPU | NVIDIA GeForce RTX 4090 (AD102, 24 GB GDDR6X) | `0000:01:00.0` |
| Motherboard | ASUS ROG Crosshair X670E Hero (X670E, AM5) | --- |
| BIOS | 3603 (AMI, AGESA ComboAM5 PI 1.3.0.0a, Release 2026-03-09) | --- |
| RAM | 2x 32 GB DDR5 (60 Gi usable, 63 Gi swap) | --- |
| NVMe | Samsung 990 PRO 2TB (Pascal controller, `144d:a80c`) x2 | `0000:02:00.0`, `0000:6b:00.0` |
| WiFi | Intel AX210 Wi-Fi 6E (Typhoon Peak, `8086:2725`) | `0000:08:00.0` |
| Ethernet | Intel I225-V 2.5GbE (`8086:15f3`) | `0000:09:00.0` |
| Thunderbolt | Intel Maple Ridge 4C TB4 (`8086:1136`) | `0000:0c:00.0` |

### Software Stack (Variant A Configuration)

| Component | Version / Value |
|-----------|----------------|
| OS | Ubuntu 24.04.4 LTS (Noble Numbat) |
| Kernel | `6.17.0-19-generic` (#19~24.04.2, HWE, PREEMPT_DYNAMIC) |
| amdgpu driver | 3.64.0 (kernel module, built-in) |
| Display Core | v3.2.340 on DCN 3.1.5 |
| NVIDIA driver | **NOT INSTALLED** (intentionally excluded for isolation) |
| linux-firmware | `20240318.git3b128b60-0ubuntu2.25` (March 2024 base + SRU patches) |
| DMCUB firmware | `0x05000F00` = **version 0.0.15.0** |
| VBIOS | `102-RAPHAEL-008` (fetched from VFCT) |
| Display Manager | LightDM 1.x (active, PID 2271) |
| Desktop | XFCE4 (xfwm4 compositor, compositing OFF) |
| Xorg | AccelMethod `none` (pure software rendering) |
| GDM3 | **Masked** (inactive, cannot start) |
| GNOME Shell | **Not running** (no gnome-shell process) |
| Hostname | `vortex` |

---

## 2. Diagnostic Results Summary

### Boot Health Scorecard

| Metric | Result | Status |
|--------|--------|--------|
| optc31_disable_crtc REG_WAIT timeout | **1** (at T+5.095s) | Expected (firmware too old) |
| optc1_wait_for_state REG_WAIT timeout | **0** | PASS |
| Ring gfx_0.0.0 timeout | **0** | PASS |
| Ring reset failed | **0** | PASS |
| MODE2 GPU reset | **0** | PASS |
| GPU reset succeeded | **0** | PASS (none needed) |
| Device wedged | **0** | PASS |
| NVIDIA Xid errors | **0** | N/A (no NVIDIA) |
| DMUB hardware initialized | **1** (clean, single init) | PASS |
| parser -125 errors | **0** | PASS |
| Devcoredumps | **0** (none found) | PASS |
| DRM card ordering | `card0` = amdgpu (`0x1002:0x164e`) | PASS |
| Render node | `renderD128` = amdgpu | PASS |
| Kernel taint flags | `68` (expected: proprietary + staging) | OK |
| Failed systemd units | 1 (`ml-boot-verify.service`) | Non-critical (script not on USB) |
| System uptime at diagnostic | 12 min, load avg 0.00/0.05/0.06 | Idle, stable |
| Boot count in journal | 1 (single clean boot) | PASS |

### Verdict: STABLE

Zero ring timeouts, zero GPU resets, zero device wedges, single DMUB initialization.
The crash loop is **broken**.

---

## 3. The Crash Loop Mechanism (What Was Happening)

### Previous Behavior (Production with GNOME)

```
T+6.1s   optc31_disable_crtc REG_WAIT timeout    <-- DCN register stall during EFI->amdgpu handoff
T+8.0s   optc1_wait_for_state REG_WAIT timeout    <-- Cascading: OTG stopped, no VBLANK signal
T+18.5s  ring gfx_0.0.0 timeout (gnome-shell)     <-- GFX ring hangs on corrupted display state
T+19.0s  MODE2 GPU reset                           <-- Resets GFX/SDMA ONLY, NOT DCN
T+31.3s  ring gfx_0.0.0 timeout (gnome-shell #2)  <-- DCN still broken, compositor retries
T+69.2s  ring gfx_0.0.0 timeout (gnome-shell #3)  <-- GDM gives up -> session-failed
         DMUB re-initializes 3-4 times per boot    <-- Each MODE2 reset triggers DMUB re-init
```

**Root cause chain**: The crash requires TWO conditions simultaneously:
1. **DCN pipeline stall** (optc31 timeout from outdated DMCUB firmware)
2. **GFX ring pressure** (compositor submitting GL commands to a stalled display pipeline)

MODE2 reset (the only reset mode available on Raphael APU) resets GFX/SDMA but **does NOT reset DCN/DCHUB**. The broken display pipeline persists through every GPU reset, creating an infinite loop.

### Variant A Behavior (This Test)

```
T+4.772s  amdgpu kernel modesetting enabled
T+4.787s  DMUB firmware loaded via PSP: version=0x05000F00
T+4.884s  Display Core v3.2.340 initialized on DCN 3.1.5
T+4.885s  DMUB hardware initialized: version=0x05000F00
T+4.917s  Initialized amdgpu 3.64.0 on minor 0 (card0)
T+4.923s  fbcon: amdgpudrmfb (fb0) is primary device
T+5.095s  REG_WAIT timeout - optc31_disable_crtc line:145   <-- STILL FIRES (firmware too old)
T+5.206s  fb0: amdgpudrmfb frame buffer device              <-- BUT system continues normally
T+5.500s  systemd running
T+5.665s  modprobe@drm.service started and completed
...nothing else. No ring timeouts. No resets. No cascade.
```

**Why it stops at one timeout**: With `AccelMethod "none"`, Xorg uses pixman (CPU-based software renderer). Zero GL commands are submitted to the GFX ring. The stalled DCN has no ring pressure to trigger a timeout against. The single optc31 timeout is a dead end — it fires once during BIOS CRTC teardown and the system moves on.

---

## 4. Complete Parameter Audit

### 4.1 Kernel Command Line (from `/proc/cmdline`)

```
BOOT_IMAGE=/vmlinuz-6.17.0-19-generic
root=UUID=21ea91ea-1207-44a6-a219-2945530535e7 ro
quiet splash
amdgpu.sg_display=0
amdgpu.dcdebugmask=0x18
amdgpu.ppfeaturemask=0xfffd7fff
amdgpu.gpu_recovery=1
amdgpu.lockup_timeout=30000
pcie_aspm=off
iommu=pt
processor.max_cstate=1
amd_pstate=active
nogpumanager
initcall_blacklist=simpledrm_platform_driver_init
vt.handoff=7
```

### 4.2 Parameter Verification (sysfs readback)

| Parameter | Configured | Sysfs Readback | Confirmed |
|-----------|-----------|----------------|-----------|
| `sg_display` | 0 | `0` | YES |
| `dcdebugmask` | 0x18 (24) | `24` | YES |
| `ppfeaturemask` | 0xfffd7fff | `0xfffd7fff` | YES |
| `gpu_recovery` | 1 | `1` | YES |
| `lockup_timeout` | 30000 | `30000` | YES |
| `dc` | 1 | `1` | YES |
| `audio` | 1 | `1` | YES |
| `noretry` | (not set) | `-1` (driver default) | YES (removed) |
| `seamless` | (not set) | `-1` (auto) | YES (not forced) |
| `reset_method` | (not set) | `-1` (auto=MODE2) | YES (not forced, MODE2 on Raphael) |
| `async_gfx_ring` | (default) | `1` | Default |
| `dpm` | (default) | `-1` (enabled) | Default |

**Key observations**:
- `reset_method=-1` confirms production's finding: `reset_method=1` (MODE0) is NOT supported on Raphael APU. The kernel logs "Specified reset method:1 isn't supported, using AUTO instead." This variant correctly does not set it.
- `seamless=-1` (auto) means seamless boot is auto-detected. On Raphael (DCN 3.1.5 + APU), auto defaults to ENABLED. Yet optc31 still fires — indicating seamless adoption failed (likely because DMCUB firmware is too old for proper seamless handoff).
- `noretry=-1` confirms the stale `amdgpu.noretry=0` was successfully removed from this variant.

### 4.3 Modprobe Configuration

**`/etc/modprobe.d/amdgpu.conf`** (Variant A):
```
options amdgpu sg_display=0
options amdgpu ppfeaturemask=0xfffd7fff
options amdgpu dcdebugmask=0x18
options amdgpu gpu_recovery=1
options amdgpu lockup_timeout=30000
options amdgpu dc=1
options amdgpu audio=1
```

**`/etc/modprobe.d/blacklist-nouveau.conf`**:
```
blacklist nouveau
blacklist nova_core
blacklist lbm-nouveau
alias nouveau off
alias lbm-nouveau off
```

No `nvidia.conf` present (correct for Variant A).

### 4.4 Initramfs Module Load Order

```
/etc/initramfs-tools/modules:
  amdgpu          <-- ONLY module (no NVIDIA in Variant A)

/etc/modules-load.d/gpu.conf:
  amdgpu          <-- ONLY module
```

`systemd-modules-load.service`: active (exited), status=0/SUCCESS. Module loading completed cleanly.

### 4.5 Xorg Configuration

**`/etc/X11/xorg.conf.d/10-amdgpu-primary.conf`**:
```
Section "Device"
    Identifier "AMD-iGPU"
    Driver "amdgpu"
    BusID "PCI:108:0:0"        # 0x6c = 108 decimal
    Option "AccelMethod" "none" # Software rendering — zero GFX ring submissions
    Option "PrimaryGPU" "yes"
EndSection

Section "Screen"
    Identifier "AMD-Screen"
    Device "AMD-iGPU"
    DefaultDepth 24
EndSection

Section "ServerLayout"
    Identifier "Layout"
    Screen "AMD-Screen"
EndSection
```

**`AccelMethod "none"`** is the critical setting. This tells the amdgpu DDX driver to skip all EXA/glamor (GL) acceleration and use pixman for 2D rendering. No GFX ring submissions from Xorg.

### 4.6 Environment Variables

```
DRI_PRIME=0                            # Force primary GPU (AMD) for DRI
MUTTER_DEBUG_KMS_THREAD_TYPE=user      # Normal-priority KMS thread (safety net)
```

`MUTTER_DEBUG_KMS_THREAD_TYPE=user` is set as a safety net even though Mutter/GNOME is not running. If any GNOME component loads, it prevents the RT-priority KMS thread SIGKILL bug.

### 4.7 `initcall_blacklist=simpledrm_platform_driver_init`

**Confirmed working**:
```
[    0.047215] blacklisting initcall simpledrm_platform_driver_init
[    0.556801] initcall simpledrm_platform_driver_init blacklisted
```

**Effect**: simpledrm cannot register as a DRM device before amdgpu loads. Result: `card0` = amdgpu (confirmed), `renderD128` = amdgpu. No NVIDIA card at all (driver not installed).

---

## 5. Firmware Analysis

### 5.1 DMCUB Firmware

| Field | Value |
|-------|-------|
| DMCUB loaded version | `0x05000F00` |
| DMCUB decoded version | **0.0.15.0** (0x0F = 15 decimal) |
| DMUB hardware init count | **1** (clean, no re-init loop) |
| linux-firmware package | `20240318.git3b128b60-0ubuntu2.25` |
| Firmware file on disk | `/lib/firmware/amdgpu/dcn_3_1_5_dmcub.bin.zst` (116,455 bytes) |
| Firmware SHA256 | `cd015a65201fffd8ce05ea85baf641e0880c347414bdc80c89cb356673662d32` |
| File conflicts | **None** (no bare `.bin` alongside `.bin.zst`) |

**CRITICAL**: DMCUB 0.0.15.0 is drastically outdated. The known-good minimum is **0.0.224.0** (Debian #1057656 fix from July 2024). The current firmware predates even the initial Raphael DMCUB in the linux-firmware git (0.0.88.0 from October 2022).

Despite the package version showing SRU patch level 0ubuntu2.25, the DMCUB blob was apparently NOT updated by any SRU. The actual firmware binary dates from the March 2024 base package.

### 5.2 Complete Firmware Inventory (debugfs)

| Component | Version | Notes |
|-----------|---------|-------|
| **DMCUB** | `0x05000f00` (0.0.15.0) | **CRITICAL: update needed** |
| VBIOS | `102-RAPHAEL-008` | Stock Raphael VBIOS |
| SMC (SMU) | `0x04540400` (84.4.0) | System Management Unit |
| ASD | `0x210000c7` | Application Security Driver |
| TA HDCP | `0x1700003c` | Content protection |
| TA DTM | `0x12000016` | Display Topology Management |
| TOC | `0x00000007` | Table of Contents (never updated upstream) |
| ME | feat 38, fw `0x0000000e` | Micro Engine |
| PFP | feat 38, fw `0x0000000e` | Pre-Fetch Parser |
| CE | feat 38, fw `0x00000003` | Constant Engine |
| RLC | feat 1, fw `0x0000001f` | Run List Controller |
| MEC/MEC2 | feat 38, fw `0x00000014` | Micro Engine Compute |
| SDMA0 | feat 52, fw `0x00000009` | System DMA |
| VCN | `0x0311e004` | Video Core Next (ENC 1.30, DEC 3) |
| PSP TOC | `psp_13_0_5_toc.bin.zst` (915 bytes) | PSP Table of Contents |
| PSP ASD | `psp_13_0_5_asd.bin.zst` (51,089 bytes) | PSP App Security Driver |
| PSP TA | `psp_13_0_5_ta.bin.zst` (62,651 bytes) | PSP Trusted Applications |

### 5.3 PSP Firmware File Status

```
dcn_3_1_5_dmcub.bin.zst    116,455 bytes  Feb 19 10:21  (from package)
psp_13_0_5_toc.bin.zst         915 bytes  Feb 19 10:21  (from package, never updated upstream)
psp_13_0_5_asd.bin.zst      51,089 bytes  Feb 19 10:21  (from package)
psp_13_0_5_ta.bin.zst       62,651 bytes  Feb 19 10:21  (from package)
gc_10_3_6_ce.bin.zst         4,413 bytes  Feb 19 10:21
gc_10_3_6_me.bin.zst         8,210 bytes  Feb 19 10:21
gc_10_3_6_mec.bin.zst       38,054 bytes  Feb 19 10:21
gc_10_3_6_mec2.bin.zst      -> gc_10_3_6_mec.bin.zst (symlink)
gc_10_3_6_pfp.bin.zst       14,834 bytes  Feb 19 10:21
gc_10_3_6_rlc.bin.zst       43,874 bytes  Feb 19 10:21
sdma_5_2_6.bin.zst          11,210 bytes  Feb 19 10:21
vcn_3_1_2.bin.zst          393,909 bytes  Feb 19 10:21
```

**No firmware file conflicts** (bare `.bin` + `.bin.zst` dual-existence issue resolved).

---

## 6. Display Pipeline State

### 6.1 DRM Connector Status

| Connector | Status | Enabled | DPMS | Active Resolution |
|-----------|--------|---------|------|-------------------|
| `card0-HDMI-A-1` | **connected** | **enabled** | **On** | 3840x2160 (4K) |
| `card0-DP-1` | disconnected | disabled | Off | --- |
| `card0-DP-2` | disconnected | disabled | Off | --- |
| `card0-Writeback-1` | unknown | disabled | On | --- |

Display: DELL 4K monitor on HDMI-A-1 running at 3840x2160. DRM auto-detected mode (no `video=` parameter forced).

### 6.2 Display Processes Running

| Process | PID | User | CPU | Description |
|---------|-----|------|-----|-------------|
| `/usr/sbin/lightdm` | 2271 | root | 0.0% | Display manager daemon |
| `Xorg -core :0` | 4217 | root | 1.5% | X server on VT7 (AccelMethod=none) |
| `lightdm --session-child` | 4555 | root | 0.0% | Session wrapper |
| `xfce4-session` | 4681 | abraham | 0.0% | XFCE session manager |
| `xfwm4` | 4972 | abraham | 0.0% | XFCE window manager |
| `xfce4-panel` | 5003 | abraham | 0.2% | Panel |
| `xfce4-power-manager` | 5021 | abraham | 0.0% | Power manager |
| `xfce4-notifyd` | 5036 | abraham | 0.0% | Notification daemon |

**No gnome-shell, no mutter, no gdm** — confirmed. GDM3 is masked (`systemctl mask gdm3`).

LightDM memory: 210 MiB (peak 272 MiB). Total display stack is lightweight.

### 6.3 GLX Info

`glxinfo` failed — "display not available?" This is expected because `AccelMethod "none"` means no GL acceleration is configured. The software renderer does not expose GLX to the diagnostic tool's environment (it was run from SSH/TTY, not within the X session).

---

## 7. Thermal & Power State

### 7.1 Temperatures at Diagnostic Time (T+12 min, idle)

| Sensor | Temperature | Notes |
|--------|-------------|-------|
| amdgpu edge (iGPU) | **44.0 C** | Healthy idle |
| CPU Tctl | 58.8 C | Package composite |
| CPU CCD1 | 47.5 C | Chiplet 1 |
| CPU CCD2 | 44.6 C | Chiplet 2 |
| CPU Package (ASUS EC) | 58.0 C | EC sensor |
| Motherboard | 38.0 C | PCH/VRM area |
| VRM | 41.0 C | Voltage regulator |
| DDR5 DIMM1 | 46.8 C | SPD5118 sensor |
| DDR5 DIMM2 | 45.5 C | SPD5118 sensor |
| NVMe (system) | 50.9 C | Samsung 990 PRO #1 |
| NVMe (data) | 45.9 C | Samsung 990 PRO #2 |
| WiFi (AX210) | 39.0 C | Virtual thermal zone |

All temperatures nominal. No thermal throttling.

### 7.2 GPU Power State

| Field | Value |
|-------|-------|
| GPU Load | **0%** (idle) |
| VCN Load | **0%** |
| SCLK (GPU clock) | 600 MHz |
| MCLK (memory clock) | 2400 MHz |
| VDDGFX | 1.38 V (1444 mV from pm_info) |
| VDDNB | 1.02 V (1020 mV from pm_info) |
| SoC Power (incl. CPU) | 33.13 W |
| PPT (Package Power Tracking) | 16.05 W |
| DPM state | `performance` |
| Performance level | `auto` |
| VCN | Powered down |

SMC Feature Mask: `0x0000ff33b15fefff`. GFXOFF bit is **disabled** (ppfeaturemask=0xfffd7fff sets bit 15 to 0).

### 7.3 GPU Memory

| Field | Value |
|-------|-------|
| VRAM total | 2,147,483,648 bytes (2048 MiB = **2 GB UMA**) |
| VRAM used | 89,231,360 bytes (85 MiB) |
| VRAM utilization | **4.2%** |
| GTT total | ~30,959 MiB |
| System RAM free | 54 Gi / 60 Gi |
| Swap used | 0 B / 63 Gi |

VRAM is 2 GB — this is the UMA Frame Buffer Size set in BIOS. Production CLAUDE.md recommends 2G (confirmed). At 85 MiB used (4.2%), there's plenty of headroom.

---

## 8. NVIDIA Status (Variant A)

| Check | Result |
|-------|--------|
| NVIDIA kernel module loaded | **No** (`nvidia` not in lsmod) |
| nvidia-smi available | **No** ("not available") |
| NVIDIA Xid errors in dmesg | **0** |
| NVIDIA dmesg entries | 4 lines (HDA NVidia audio device detection only) |
| nouveau loaded | **No** (blacklisted) |

The RTX 4090 is physically present at `0000:01:00.0` (visible in lspci) but has no driver bound. Only the HDA audio controller at `0000:01:00.1` is detected (snd_hda_intel).

---

## 9. PCI & IOMMU State

### 9.1 IOMMU Configuration

- **Mode**: Passthrough (set via kernel command line `iommu=pt`)
- **IOMMU hardware**: AMD-Vi, performance counters supported
- **iGPU IOMMU group**: Group 21 (`0000:6c:00.0`)
- **dGPU IOMMU group**: Group 13 (`0000:01:00.0` + `0000:01:00.1`)

Separate IOMMU groups for iGPU and dGPU — good for future VFIO passthrough if needed.

### 9.2 PCIe Errors

```
PCI bridge window assignment failures (non-critical):
  0000:07:04.0: bridge window [io size 0x2000]: failed to assign (x2)
  0000:0c:00.0: bridge window [io size 0x2000]: failed to assign (x2)
  0000:0d:03.0: bridge window [mem size 0x00200000]: failed to assign
  0000:0d:01.0: bridge window [io/mem]: failed to assign (multiple)
```

These are Thunderbolt 4 bridge (Maple Ridge) IO window assignment failures. Non-critical — the TB4 controller works but some downstream ports can't get IO windows. Not related to the GPU issue.

**Recommendation from kernel**: "Some PCI device resources are unassigned, try booting with `pci=realloc`". Low priority.

### 9.3 Miscellaneous Warnings

| Warning | Severity | Impact |
|---------|----------|--------|
| `i2c i2c-0: Failed to register i2c client MSFT8000:00 at 0x4e (-16)` | Low | HID sensor hub conflict, cosmetic |
| `asus_wmi: failed to register LPS0 sleep handler` | Low | S0ix sleep not available, irrelevant for workstation |
| `Bluetooth: hci0: No dsm support to set reset delay` | Low | BT firmware cosmetic warning |
| `nvme nvme0: using unchecked data buffer` | Low | NVMe passthrough buffer, cosmetic |
| `kauditd_printk_skb: N callbacks suppressed` | Info | Audit log rate limiting (Firefox AppArmor denials) |
| `exFAT-fs (sdb1): Volume was not properly unmounted` | Medium | USB drive (diagnostic collection), not system disk |
| Firefox AppArmor: `/proc/pressure/memory` denied | Low | Snap sandbox restriction, cosmetic |

None of these affect GPU stability.

---

## 10. Comparison: runLog-00 vs diag-20260329-054341

Both diagnostics were collected from the **same Variant A installation**, on the same boot or consecutive boots.

| Field | runLog-00 | diag-20260329-054341 | Match? |
|-------|-----------|---------------------|--------|
| Kernel | 6.17.0-19-generic | 6.17.0-19-generic | YES |
| Kernel cmdline | Identical (all params) | Identical (all params) | YES |
| BIOS version | 3603 | 3603 | YES |
| linux-firmware | 20240318.git3b128b60-0ubuntu2.25 | 20240318.git3b128b60-0ubuntu2.25 | YES |
| DMCUB version | 0x05000f00 | 0x05000F00 | YES |
| All firmware versions | Identical (debugfs match) | Identical (debugfs match) | YES |
| DRM card0 | amdgpu (0x1002:0x164e) | amdgpu (0x1002:0x164e) | YES |
| NVIDIA driver loaded | No | No | YES |
| optc31 REG_WAIT timeout | 1 (at T+5.095s) | 1 (at T+5.095s) | YES |
| Ring gfx timeouts | 0 | 0 | YES |
| GPU resets | 0 | 0 | YES |
| GDM3 | Masked | Masked | YES |
| Display on HDMI-A-1 | 3840x2160 connected | 3840x2160 connected | YES |
| Uptime at collection | 13 min | 12 min | Close |
| Firmware conflicts | None | None | YES |

**Conclusion**: The Variant A configuration produces **reproducible, stable boots**. The single optc31 timeout at T+5.095s is deterministic (same timestamp, same line:145) and harmless without ring pressure.

---

## 11. Diagnosis

### 11.1 What We Now Know (Confirmed by Evidence)

1. **The crash loop requires TWO simultaneous conditions**:
   - Condition A: DCN pipeline stall (optc31_disable_crtc timeout from outdated DMCUB firmware)
   - Condition B: GFX ring pressure from a compositor (gnome-shell/glamor submitting GL commands)
   - Remove EITHER condition and the system is stable

2. **DMCUB firmware 0.0.15.0 causes the optc31 timeout deterministically**:
   - It fires at exactly T+5.095s on every boot
   - It occurs during `dcn31_init_hw` -> `dcn10_init_pipes` when tearing down BIOS-configured CRTC
   - The `OTG_BUSY` bit in `OTG_CLOCK_CONTROL` fails to clear within 100ms (1us x 100,000)
   - This is at line 145 of `optc31_disable_crtc` in the kernel source

3. **AccelMethod "none" eliminates GFX ring pressure completely**:
   - Xorg uses pixman (CPU-based) for all 2D rendering
   - Zero GL/EXA commands are submitted to the amdgpu GFX ring
   - Without ring submissions, a stalled DCN cannot trigger a ring timeout
   - The system works at 4K (3840x2160) with software rendering (sufficient for a workstation UI)

4. **XFCE + LightDM eliminates GNOME-specific triggers**:
   - No gnome-shell process = no Mutter GL compositing
   - No Mutter RT-priority KMS thread = no SIGKILL risk
   - LightDM is a simple display manager with minimal GPU interaction

5. **`initcall_blacklist=simpledrm_platform_driver_init` fixes card ordering**:
   - Without it, simpledrm registers before amdgpu, potentially taking card0
   - With it, amdgpu reliably gets card0, renderD128
   - Screen is black until amdgpu loads (~4.7s) — acceptable for a workstation

6. **MODE2 reset does NOT fix DCN on Raphael**:
   - `reset_method=1` (MODE0/full ASIC reset) is NOT SUPPORTED on Raphael APU
   - The kernel falls back to MODE2 (GFX/SDMA only)
   - This means any DCN stall persists through GPU resets
   - The only way to clear a stuck DCN is a full system reboot

7. **The linux-firmware SRU did NOT update the DMCUB blob**:
   - Despite package version `0ubuntu2.25`, the actual `dcn_3_1_5_dmcub.bin.zst` is from the March 2024 base
   - DMCUB 0.0.15.0 predates all known fixes (minimum known-good: 0.0.224.0)
   - Firmware file conflict issue is resolved (no dual `.bin` + `.bin.zst`)

### 11.2 What We Don't Yet Know (Requires Further Testing)

1. **Does updated DMCUB firmware eliminate the optc31 timeout entirely?**
   - The single timeout at T+5.095s is harmless now but indicates the EFI->amdgpu handoff is still broken
   - DMCUB >= 0.0.224.0 should fix the display state machine that manages this transition
   - **This is Variant B's test objective**

2. **Can glamor (GL acceleration) work safely with updated firmware?**
   - Current setup uses software rendering — functional but not ideal for desktop responsiveness
   - If DMCUB firmware fix eliminates the DCN stall, glamor may work without triggering ring timeouts
   - **This is also Variant B's test objective** (re-enables AccelMethod "glamor")

3. **Does NVIDIA module coexistence contribute to the crash?**
   - Variant A removed NVIDIA entirely, so we can't isolate NVIDIA's role
   - NVIDIA may affect card ordering, PCIe bandwidth, or IOMMU interactions
   - **This is Variant C's test objective** (re-adds NVIDIA after firmware fix)

4. **Does seamless boot (`amdgpu.seamless=1`) work with updated DMCUB?**
   - Currently `seamless=-1` (auto), which should enable seamless on Raphael
   - But seamless adoption failed (optc31 still fires), possibly because DMCUB 0.0.15.0 doesn't support it properly
   - Variant B forces `seamless=1` with updated firmware to test this

---

## 12. Prognosis

### 12.1 Testing Workflow Status

```
Step 1: Run prepare-firmware-usb.sh     [NOT YET DONE]
         |
Step 2: Boot Variant A                  [DONE - PASS]
         |-- PASS --> Step 3             [<-- WE ARE HERE]
         |
Step 3: Boot Variant B (firmware fix)   [NEXT]
         |-- PASS --> Step 4
         |-- FAIL --> Check Xorg.0.log, try AccelMethod "none"
         |
Step 4: Boot Variant C (full stack)     [PENDING]
         |-- PASS --> Production ready
         |-- FAIL --> NVIDIA interaction issue, use Variant B
```

### 12.2 Immediate Next Steps

#### Step 1: Prepare Firmware for Variant B

```bash
# On a machine with internet access:
bash script/diag-v2/prepare-firmware-usb.sh
# Downloads linux-firmware 20250305 tag, extracts Raphael blobs to USB
```

Target firmware: DMCUB **0.0.255.0** (latest 0.0.x series, conservative, well-tested).

#### Step 2: Boot Variant B

Variant B configuration changes from A:
- **DMCUB firmware**: Updated from USB (0.0.255.0)
- **AccelMethod**: `glamor` (GL acceleration re-enabled)
- **seamless**: `amdgpu.seamless=1` (forced seamless boot)
- **Everything else**: Same as Variant A (no NVIDIA, XFCE, LightDM)

```bash
cp variants/autoinstall-B-display-firmware.yaml ../autoinstall.yaml
# Boot from USB
```

**What to watch for**:
- Does the optc31 timeout disappear entirely?
- Does DMUB version in dmesg show >= 0.0.224.0?
- With glamor enabled, are there ring gfx timeouts?
- Does seamless=1 actually adopt the BIOS pipeline (no CRTC teardown)?

#### Step 3: If Variant B Passes, Boot Variant C

Variant C adds NVIDIA 580 driver back (headless compute). Tests full dual-GPU stability.

### 12.3 Predicted Outcomes

| Scenario | Probability | Evidence |
|----------|-------------|----------|
| **Variant B PASS** (firmware fixes everything) | **High (70%)** | The optc31 timeout is deterministic at the same DMCUB version. Debian #1057656 was an exact match for this firmware issue on Raphael. The crash requires both DCN stall + ring pressure; eliminating the DCN stall should allow glamor to work. |
| **Variant B PARTIAL** (optc31 gone but glamor has new issues) | Medium (20%) | Even with fixed firmware, the GC 10.3.6 has only 2 CUs — glamor at 4K may be slow enough to hit ring timeouts under load. Fix: use `lockup_timeout=30000` (already set). |
| **Variant B FAIL** (same crashes even with new firmware) | Low (10%) | Would indicate a kernel-level DCN31 bug independent of firmware. Fix: test `amdgpu.seamless=0` to force pipe teardown with the new firmware, or try `dcdebugmask=0x18` variants. |
| **Variant C PASS** (full stack works) | High (65%) if B passes | With firmware fixed, NVIDIA headless mode + card ordering via initcall_blacklist should be stable. The NVIDIA driver doesn't interact with DCN. |
| **Variant C FAIL** (NVIDIA triggers new issues) | Medium (35%) if B passes | NVIDIA module load may affect timing, PCIe bandwidth, or IOMMU. The `softdep nvidia pre: amdgpu` ordering is critical. |

### 12.4 If All Variants Pass — Production Configuration

The target production stack would be:
- **Firmware**: DMCUB >= 0.0.224.0 (ideally 0.0.255.0), embedded in initramfs as `.bin.zst`
- **Kernel**: 6.17 HWE (all DCN31 patches)
- **Display**: LightDM + XFCE (no GNOME), AccelMethod `glamor` (if Variant B passes) or `none` (fallback)
- **NVIDIA**: 580 headless (if Variant C passes)
- **All current kernel params**: Retained (sg_display=0, dcdebugmask=0x18, ppfeaturemask, lockup_timeout, etc.)
- **BIOS**: 3603, UMA 2G, GFXOFF disabled (confirmed)

### 12.5 Long-Term Outlook

The upstream bug ([drm/amd #5073](https://gitlab.freedesktop.org/drm/amd/-/work_items/5073)) remains **OPEN** with no driver-level fix. Our strategy bypasses the bug through:

1. **Updated firmware** — fixes the DMCUB state machine that causes the optc31 stall
2. **Compositor choice** — XFCE/LightDM avoids GNOME's aggressive GL compositing
3. **Kernel params** — defense-in-depth (sg_display=0, dcdebugmask, ppfeaturemask, lockup_timeout)
4. **Card ordering** — initcall_blacklist ensures amdgpu gets card0

Even if AMD never fixes the upstream bug, this combination should provide a stable production workstation.

---

## 13. Reference: Key Files in This Diagnostic

### diag-20260329-054341/ (Enhanced Diagnostic v2)

| Directory | Key Files | What They Show |
|-----------|-----------|---------------|
| `01-kernel-system/` | `proc-cmdline.txt`, `uname-a.txt`, `lsmod.txt`, `systemd-failed.txt` | Kernel 6.17.0-19, all params confirmed, only ml-boot-verify failed |
| `02-amdgpu-driver/` | `dmesg-amdgpu.txt`, `amdgpu-sysfs-params.txt`, `dmesg-err-warn.txt` | Full amdgpu init timeline, param verification, single REG_WAIT |
| `03-dmcub-dcn-state/` | `firmware-info.txt`, `gpu-recover-status.txt`, ring files | DMCUB 0x05000f00, all ring states, no recovery triggered |
| `04-devcoredump/` | `devcoredump-manifest.txt` | No devcoredumps (clean) |
| `05-nvidia-driver/` | `nvidia-smi.txt`, `dmesg-nvidia.txt` | Not installed; only HDA audio detection |
| `06-firmware/` | `dmub-dmesg.txt`, `firmware-hashes.txt`, `firmware-conflicts.txt` | DMUB loaded once, SHA256 hashes, no conflicts |
| `07-display/` | `connectors-status.txt`, `display-processes.txt`, `lightdm-status.txt` | 4K on HDMI, LightDM+XFCE running, no GNOME |
| `08-pci-hardware/` | `lspci-nn.txt`, `iommu-groups.txt`, `dmi-bios.txt` | Full PCI topology, BIOS 3603, IOMMU passthrough |
| `09-power-thermal/` | `sensors.txt`, `amdgpu-hwmon.txt` | All temps nominal, GPU 44C, 16W PPT |
| `10-memory/` | `free.txt`, `vram-total.txt`, `vram-used.txt` | 2GB VRAM (UMA), 85 MiB used (4.2%), 60Gi RAM |
| `11-config-files/` | `etc-default-grub.txt`, `modprobe-d-all.txt`, `xorg-conf-d-all.txt` | All configs match Variant A spec |
| `12-ring-events/` | `event-counts.txt` | Zero ring timeouts, zero resets, 1 optc31 |
| `13-journal/` | `dmesg-full.txt`, `journal-current-boot.txt` | Full boot log, Firefox AppArmor noise only |
| `14-drm-cards/` | `card-assignments.txt` | card0=amdgpu, renderD128=amdgpu |

### runLog-00/ (Basic Diagnostic, Same Install)

| Directory | Key Finding |
|-----------|-------------|
| `02-amdgpu-driver/dmesg-ring-timeout.txt` | Same single optc31 at T+5.095s, zero ring timeouts |
| `04-firmware/firmware-conflicts.txt` | No conflicts (clean) |
| `05-display/gdm-status.txt` | GDM3 masked (correct) |
| `07-drm-state/debugfs-amdgpu_firmware_info.txt` | All firmware versions match diag-20260329 exactly |
| `07-drm-state/debugfs-amdgpu_pm_info.txt` | GPU idle, 45C, 600 MHz SCLK, clock gating active |

---

## 14. Appendix: Clock Gating State

From runLog-00 debugfs `pm_info`:

| Clock Gating Feature | State |
|----------------------|-------|
| Graphics Fine Grain CG | On |
| Graphics Medium Grain CG | On |
| Graphics Medium Grain Memory LS | On |
| Graphics Coarse Grain CG | On |
| Graphics Coarse Grain Memory LS | On |
| Graphics Coarse Grain Tree Shader CG | **Off** |
| Graphics Command Processor LS | On |
| Graphics Run List Controller LS | On |
| Graphics 3D Coarse Grain CG | On |
| Memory Controller LS | On |
| Memory Controller Medium Grain CG | On |
| SDMA LS | On |
| SDMA Medium Grain CG | On |
| Bus Interface Medium Grain CG | On |
| IH CG | On |
| ATH Medium Grain CG | On |
| ATH LS | On |

`dcdebugmask=0x18` disables PSR (0x10) and DCN clock gating (0x08). The GFX-level clock gating shown above is separate from DCN clock gating and remains active (expected — we only disable DCN clock gating to keep OPTC registers accessible).

---

*Generated from `logs/runLog-01/` diagnostic data. All values sourced directly from kernel dmesg, sysfs, debugfs, and systemd journal.*
