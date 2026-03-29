# Autoinstall Variant Testing Strategy

## Problem Statement

The ML workstation suffers from an intermittent crash loop caused by:
1. **DMCUB firmware 0x05000F00** (0.0.15.0) — critically outdated, predating all known fixes
2. **card0=NVIDIA** — wrong DRM card ordering despite initramfs ordering
3. **Xorg glamor** submitting to GFX ring on a partially broken DCN pipeline
4. **optc31_disable_crtc REG_WAIT timeout** during EFI-to-amdgpu handoff

## Three Variants for Isolation Testing

### Variant A: Display-Only (No NVIDIA)
**File:** `autoinstall-A-display-only.yaml`
**Purpose:** Isolate whether NVIDIA module coexistence causes the crash.

| Component | Configuration |
|-----------|--------------|
| NVIDIA driver | NOT INSTALLED |
| NVIDIA in initramfs | NO |
| Xorg AccelMethod | `none` (software rendering) |
| DMCUB firmware | Stock (from linux-firmware package) |
| Compositor | XFCE, compositing OFF |
| GRUB params | No nvidia-drm.*, no seamless=1 |

**What it tests:** Is the crash purely AMD DMCUB/DCN, or does NVIDIA contribute?
**Expected result if PASS:** NVIDIA coexistence is a factor; proceed to Variant B.
**Expected result if FAIL:** Pure AMD issue; firmware update is critical.

### Variant B: Display + Firmware Fix (Critical Milestone)
**File:** `autoinstall-B-display-firmware.yaml`
**Purpose:** Test if updated DMCUB firmware resolves the crash loop.

| Component | Configuration |
|-----------|--------------|
| NVIDIA driver | NOT INSTALLED |
| DMCUB firmware | **Updated from USB** (linux-firmware 20250305, DMCUB 0.0.255.0) |
| Xorg AccelMethod | `glamor` (GL acceleration enabled) |
| Compositor | XFCE, compositing OFF |
| GRUB params | seamless=1 re-enabled |

**Prerequisite:** Run `script/diag-v2/prepare-firmware-usb.sh` to download firmware blobs to USB.

**What it tests:** Does DMCUB >= 0.0.255.0 fix the optc31 timeout and ring crashes?
**Expected result if PASS:** Firmware was the root cause. Proceed to Variant C.
**Expected result if FAIL:** Additional issues beyond firmware. Check Xorg.0.log.

### Variant C: Full Stack (Display + Firmware + NVIDIA)
**File:** `autoinstall-C-full-stack.yaml`
**Purpose:** Full target configuration with all fixes applied.

| Component | Configuration |
|-----------|--------------|
| NVIDIA driver | 580 (auto-installed from Ubuntu repos) |
| DMCUB firmware | **Updated from USB** |
| Xorg AccelMethod | `glamor` |
| Card ordering | `softdep nvidia pre: amdgpu` + explicit BusID |
| Compositor | XFCE, compositing OFF |

**What it tests:** Full dual-GPU stability with fixed firmware.
**Expected result if PASS:** System is ready for production use.

## Testing Workflow

```
Step 1: Run prepare-firmware-usb.sh (downloads firmware to USB)
         |
Step 2: Boot Variant A (display isolation)
         |-- PASS --> Step 3
         |-- FAIL --> Pure AMD issue, firmware is root cause
         |
Step 3: Boot Variant B (firmware fix, critical milestone)
         |-- PASS --> Step 4
         |-- FAIL --> Check Xorg.0.log, try AccelMethod "none"
         |
Step 4: Boot Variant C (full stack)
         |-- PASS --> Production ready
         |-- FAIL --> NVIDIA interaction issue, use Variant B for now
```

## How to Use

1. Copy the desired variant YAML to `autoinstall.yaml`:
   ```bash
   cp variants/autoinstall-A-display-only.yaml ../autoinstall.yaml
   ```

2. For Variant B/C, download firmware first:
   ```bash
   bash ../../script/diag-v2/prepare-firmware-usb.sh
   ```

3. Boot from USB with the autoinstall.

4. After boot, check verification report:
   ```bash
   cat /var/log/ml-workstation-setup/verify-*.txt
   ```

5. Run full diagnostics:
   ```bash
   sudo diagnostic-enhanced.sh
   ```

6. Copy results to USB and analyze.

## Key Fixes Applied Across All Variants

| Issue from runLog-00 | Fix Applied |
|---------------------|-------------|
| DMCUB 0x05000F00 (too old) | Variant B/C: firmware from USB |
| card0=NVIDIA (wrong order) | Explicit BusID PCI:108:0:0 in Xorg |
| video=HDMI-A-1:1920x1080@60 rejected | Removed (let DRM auto-detect) |
| Xorg glamor → ring timeout | Variant A: AccelMethod none |
| amdgpu.seamless=1 ineffective | Variant A: removed; B/C: re-enabled with new firmware |
| NVIDIA 580 instead of 595 | Noted; 595 via CUDA repo post-install |
| dcdebugmask=0x10 | Changed to 0x18 (disable PSR + DCN clock gating) |
| gnome-shell processes | GNOME sessions diverted/disabled |
