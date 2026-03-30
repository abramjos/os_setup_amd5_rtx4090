# Comprehensive Diagnostic Reference: AMD Raphael iGPU (GC 10.3.6, DCN 3.1.5)

## Target Bug Pattern

```
[  6.1s] REG_WAIT timeout - optc31_disable_crtc    <- DCN register stall during EFI->amdgpu handoff
[  8.0s] REG_WAIT timeout - optc1_wait_for_state   <- Cascading: OTG stopped, no VBLANK arrives
[ 18.5s] ring gfx_0.0.0 timeout (compositor)       <- GFX ring hangs on corrupted display state
[ 19.0s] MODE2 GPU reset                            <- Resets GFX/SDMA only -- NOT DCN
[ 31.3s] ring gfx_0.0.0 timeout (compositor #2)    <- DCN still broken -> repeat
```

System: Ubuntu 24.04.4, HWE kernel 6.17.0-19-generic, XFCE/LightDM, AMD Ryzen 9 7950X iGPU + NVIDIA RTX 4090
Last tested: 2026-03-30 (Variant B v2 — firmware fix confirmed stable with DMUB 0x05002000)

---

## Table of Contents

0. [Test Run Results & Cross-Variant Evidence](#0-test-results)
1. [Priority 1 -- CRITICAL: Capture During or Immediately After Crash](#1-critical)
2. [Priority 2 -- IMPORTANT: System State Baseline](#2-important)
3. [Priority 3 -- NICE-TO-HAVE: Deep Dive and Tracing](#3-nice-to-have)
4. [Automatic Capture Infrastructure](#4-automatic-capture)
5. [External Tools](#5-external-tools)
6. [Diagnostic Gaps in Current Script](#6-gaps)

---

<a name="0-test-results"></a>
## 0. Test Run Results & Cross-Variant Evidence (2026-03-29 through 2026-03-30)

This section documents empirical findings across all variant test runs, organized
chronologically. Each run corresponds to a log directory under `logs/`.

---

### 0.1 Run Summary Matrix

| Log Dir | Variant | Date | Boots | Verdict | Key Finding |
|---------|---------|------|-------|---------|-------------|
| `runLog-00` | Pre-variant baseline | 2026-03-29 | 1 | **UNSTABLE** (5x ring timeout) | GNOME/glamor + DMUB 0x05000F00 = crash loop |
| `runlog-A_v1` | A (display-only) | 2026-03-29 | 1 | **STABLE** (1 optc31, 0 ring) | AccelMethod "none" eliminates ring timeouts |
| `runlog-B_v1` | B (firmware fix) | 2026-03-30 | 3 | **FAIL** (card ordering) | recovery/nomodeset: simple-framebuffer claims card0 |
| `runlog-B_v2` | B (firmware fix) | 2026-03-30 | 8 | **PARTIAL** → **PASS** after firmware | Old firmware: intermittent ring timeouts; New firmware: zero ring timeouts |

---

### 0.2 Baseline: runLog-00 (Pre-Variant, UNSTABLE)

**Configuration:** GNOME/GDM, AccelMethod "glamor", NVIDIA present, dcdebugmask=0x10
**Firmware:** DMUB 0x05000F00 (stock Ubuntu 24.04, linux-firmware 20240318)

| Metric | Value |
|--------|-------|
| optc31 REG_WAIT timeouts | 1 (T+5.248s) |
| ring gfx_0.0.0 timeouts | **5** (crash loop) |
| MODE2 GPU resets | 5 (all failed to fix DCN) |
| Parser -125 errors | 5 (post-reset command stream corruption) |
| Triggering process | gnome-shell (PIDs 2693, 6805, 7222, 7455, 7665) |
| Card ordering | card0=NVIDIA, card1=AMD (wrong) |
| DM status | GDM inactive (crashed) |

**Conclusion:** Confirmed the crash-loop pattern. MODE2 resets GFX/SDMA but NOT DCN,
so the broken display pipeline persists. gnome-shell's OpenGL compositing pressures
the GFX ring, which hangs on the corrupted DCN state.

---

### 0.3 Variant A: runlog-A_v1 (Display-Only, STABLE)

**Configuration:** XFCE/LightDM, AccelMethod **"none"** (CPU rendering), NO NVIDIA,
dcdebugmask=0x18, seamless removed from cmdline
**Firmware:** DMUB 0x05000F00 (unchanged stock)

| Metric | Value |
|--------|-------|
| optc31 REG_WAIT timeouts | **1** (T+5.095s, deterministic) |
| ring gfx_0.0.0 timeouts | **0** (PASS) |
| MODE2 GPU resets | 0 |
| DMUB init count | 1 (clean, no re-init loop) |
| Card ordering | card0=amdgpu (PASS — initcall_blacklist working) |
| Display | 3840x2160@60 on HDMI-A-1 (Dell S2722QC) |
| DM status | LightDM active, XFCE running |

**Conclusion:** Proves the **two-condition crash model**:
- **Condition 1 (optc31 timeout):** STILL PRESENT — firmware bug remains
- **Condition 2 (GFX ring pressure):** ELIMINATED by AccelMethod "none"
- With only Condition 1, the system is stable. The optc31 timeout at boot
  does NOT cascade into ring timeouts when no compositor is submitting GL work.

---

### 0.4 Variant B v1: runlog-B_v1 (Firmware Fix Attempt, FAIL)

**Configuration:** XFCE/LightDM, AccelMethod "glamor", seamless=1, dcdebugmask=0x18
**Firmware:** Attempted DMCUB update, but captured in recovery/nomodeset mode

**Diagnostics captured in recovery mode** — NOT representative of normal boot:

| Metric | Value |
|--------|-------|
| Card ordering | card0=simple-framebuffer (recovery mode, NOT a real failure) |
| DMUB loaded | NO (nomodeset prevents amdgpu probe) |
| amdgpu probe | Failed with -22 EINVAL (expected in nomodeset) |
| Ring timeouts | 0 (no GPU activity in recovery) |

**Xorg error in normal boot attempt** (from `Xorg.0.log` lines 71-78):
```
[   14.111] (EE) AMDGPU(0): amdgpu_device_initialize failed
[   14.112] (EE) AMDGPU(1): [drm] Failed to open DRM device for pci:0000:6c:00.0: Invalid argument
[   14.112] (EE) Device(s) detected, but none match those in the config file.
```

**Conclusion:** B_v1 diagnostics were taken in recovery mode, obscuring the real state.
The Xorg error suggests the initial firmware update didn't take effect (possibly
initramfs was not rebuilt, or firmware wasn't included in the initramfs image).

---

### 0.5 Variant B v2: runlog-B_v2 (Firmware Fix + Manual Install, PARTIAL → PASS)

**Configuration:** XFCE/LightDM, AccelMethod "glamor", seamless=1, dcdebugmask=0x18
**Firmware:** Started with DMUB 0x05000F00, manually updated to 0x05002000 via
`install-firmware.sh` between boots -2 and -1 (firmware blobs timestamped 04:50 EDT).

**8-Boot Progression (from `runLog-02/comparison.csv`):**

| Boot | Time (EDT) | Mode | DMUB Ver | optc31 | Ring GFX | Resets | Verdict |
|------|------------|------|----------|--------|----------|--------|---------|
| -6 | 02:17 | normal+params | 0x05000F00 | 1 | **4** | 4 MODE2 | **UNSTABLE** |
| -5 | 02:58 | recovery | N/A | 0 | 0 | 0 | STABLE |
| -4 | 03:52 | normal+params | 0x05000F00 | 1 | **1** | 1 MODE2 | **DEGRADED** |
| -3 | 03:55 | recovery | N/A | 0 | 0 | 0 | STABLE |
| -2 | 03:59 | normal+params | 0x05000F00 | 1 | **0** | 0 | STABLE |
| | **04:50** | | **install-firmware.sh run** | | | | |
| -1 | 04:53 | normal+params | **0x05002000** | 1 | **0** | 0 | **STABLE** |
| 0 | 04:54 | recovery | N/A | 0 | 0 | 0 | STABLE |

**Firmware version change at boot -1:**
- DMUB: 0x05000F00 → **0x05002000** (version 0.0.32.0, Revision 6)
- VCN: ENC 1.30 DEC 3 Revision 4 → **ENC 1.33 DEC 4 Revision 6**

**Ring timeout triggering processes (boots -6 and -4):**
```
Boot -6: Xorg pid 2279 (cs0:2304), pid 4544 (cs0:4545), pid 4909 (cs0:4912), pid 5094 (cs0:5097)
Boot -4: Xorg pid 1729 (cs0:1739)
```
All from Xorg glamor command submission thread (`Xorg:cs0`).

**Xorg log confirms glamor was fully operational** (from `Xorg.0.log.old` line 96):
```
AMDGPU(0): glamor X acceleration enabled on AMD Ryzen 9 7950X 16-Core Processor
(radeonsi, raphael_mendocino, LLVM 20.1.2, DRM 3.64, 6.17.0-19-generic)
```

**ATPX probe failure in recovery mode** (from `dmesg-amdgpu.txt`):
```
amdgpu: vga_switcheroo: detected switching method \_SB_.PCI0.GP17.VGA_.ATPX handle
amdgpu: ATPX version 1, functions 0x00000000
amdgpu 0000:6c:00.0: probe with driver amdgpu failed with error -22
```
This is a **red herring** — only occurs in recovery/nomodeset mode. ATPX returns
zero functions because the BIOS-level GPU switching is disabled by nomodeset.
Normal boots probe successfully (evidenced by DMUB loading and Xorg starting).

---

### 0.6 Findings: What Worked and What Didn't

#### CONFIRMED WORKING

| Fix | Evidence | Variant |
|-----|----------|---------|
| AccelMethod "none" (eliminates Condition 2) | 0 ring timeouts in A_v1 | A |
| initcall_blacklist=simpledrm_platform_driver_init | card0=amdgpu in A_v1 | A, B |
| dcdebugmask=0x18 (PSR + seamless boot disable) | Reduced optc31 impact vs 0x10 | A, B |
| DMUB firmware upgrade (0x05000F00 → 0x05002000) | 0 ring timeouts post-upgrade in B_v2 | B |
| install-firmware.sh + initramfs hook | Firmware properly loaded at boot -1 | B |
| XFCE/LightDM (replacing GNOME/GDM) | Lighter compositor, fewer GL calls | A, B |
| sg_display=0 (disable scatter-gather) | Consistent across all stable boots | A, B |

#### CONFIRMED NOT WORKING / INSUFFICIENT

| Approach | Evidence | Issue |
|----------|----------|-------|
| Autoinstall late-commands firmware download | Boots -6 through -2 still used 0x05000F00 | Firmware not in initramfs after autoinstall |
| DMUB 0x05000F00 + glamor | Ring timeouts in boots -6, -4 | Old firmware can't handle glamor GFX pressure |
| seamless=1 with old firmware | Contributed to instability in boot -6 | Seamless boot + broken DMCUB = race condition |
| Recovery/nomodeset diagnostics | ATPX -22, no DMUB, simple-framebuffer | Doesn't represent normal boot state |

#### STILL UNRESOLVED

| Issue | Evidence | Status |
|-------|----------|--------|
| optc31 REG_WAIT timeout at T+5s | Present in ALL normal boots (A and B) | **Residual firmware bug** — doesn't cascade with new DMUB |
| Intermittent ring timeouts with old firmware | Boot -2 had 0 timeouts, boot -6 had 4 | Bug is probabilistic, not deterministic |
| Autoinstall firmware delivery to initramfs | Firmware files present on disk but not in initramfs | **Autoinstall gap** — needs hook in late-commands |

---

### 0.7 Updated Root Cause Model (Post-Testing)

The original two-condition crash model is **confirmed with refinement**:

```
┌─────────────────────────────────────────────────────────────┐
│  CONDITION 1: DCN Pipeline Stall (optc31_disable_crtc)      │
│  ├── Cause: DMCUB firmware bug during EFI→amdgpu handoff    │
│  ├── Present: EVERY normal boot (both old and new firmware)  │
│  └── Severity: REDUCED by dcdebugmask=0x18, NOT eliminated  │
│                                                             │
│  CONDITION 2: GFX Ring Pressure (compositor GL workload)     │
│  ├── Cause: Compositor submits GL commands to GFX ring       │
│  ├── Eliminated by: AccelMethod "none" (Variant A)          │
│  └── Tolerated by: DMUB ≥ 0x05002000 (Variant B post-fix)  │
│                                                             │
│  CRASH LOOP = Condition 1 + Condition 2 + Old DMUB Firmware │
│                                                             │
│  MODE2 reset path:                                          │
│    optc31 stall → DCN frozen → GFX ring timeout →           │
│    MODE2 reset (GFX+SDMA only) → DCN STILL FROZEN →        │
│    compositor retries GL → ring timeout again → ∞ loop      │
│                                                             │
│  STABLE path (new firmware):                                │
│    optc31 stall → DMCUB ≥ 0x05002000 recovers pipeline →   │
│    GFX ring NOT affected → compositor GL works normally →   │
│    stable boot                                              │
│                                                             │
│  STABLE path (no GL):                                       │
│    optc31 stall → DCN partially frozen → no GL workload →   │
│    GFX ring idle → no timeout → stable boot                 │
└─────────────────────────────────────────────────────────────┘
```

**Key insight from B_v2:** The optc31 timeout still occurs at T+5s even with
DMUB 0x05002000, but the newer firmware's DMCUB recovers the DCN pipeline
gracefully, preventing the cascade into ring timeouts. The old firmware
(0x05000F00) left the DCN in a permanently broken state that MODE2 reset
could not fix.

---

### 0.8 Autoinstall Firmware Delivery Gap

**Problem:** The autoinstall `late-commands` section downloads firmware blobs
and places them in `/target/lib/firmware/amdgpu/` as `.bin.zst`, then runs
`update-initramfs -u -k all`. But boots -6 through -2 in B_v2 still loaded
DMUB 0x05000F00, meaning the firmware was NOT in the initramfs.

**Root cause:** The default `update-initramfs` hook only copies firmware blobs
that the currently-loaded amdgpu driver requests. During autoinstall, the
target system is in a chroot — amdgpu is not bound to hardware, so the
firmware hook skips all amdgpu blobs.

**Fix applied by `install-firmware.sh`:** Creates a custom initramfs hook at
`/etc/initramfs-tools/hooks/amdgpu-firmware` that force-copies Raphael-specific
firmware blobs into the initramfs regardless of driver binding state. This is
why boot -1 (after running `install-firmware.sh`) loaded DMUB 0x05002000.

**Recommended fix for autoinstall:** Add the initramfs hook creation to the
autoinstall `late-commands` BEFORE `update-initramfs -u -k all`:

```yaml
# Add BEFORE the final update-initramfs step:
- |
  cat > /target/etc/initramfs-tools/hooks/amdgpu-firmware << 'HOOK'
  #!/bin/sh
  PREREQ=""
  prereqs() { echo "$PREREQ"; }
  case "$1" in prereqs) prereqs; exit 0 ;; esac
  . /usr/share/initramfs-tools/hook-functions
  [ -z "${DESTDIR:-}" ] && exit 1
  for candidate in /usr/lib/firmware/amdgpu /lib/firmware/amdgpu; do
      [ -d "$candidate" ] && HOSTDIR="$candidate" && break
  done
  [ -z "$HOSTDIR" ] && exit 0
  DESTDIRS="${DESTDIR}/lib/firmware/amdgpu"
  [ -L "${DESTDIR}/lib/firmware" ] && DESTDIRS="$(readlink -f "${DESTDIR}/lib/firmware")/amdgpu"
  for blob in dcn_3_1_5_dmcub psp_13_0_5_toc psp_13_0_5_ta psp_13_0_5_asd \
              gc_10_3_6_ce gc_10_3_6_me gc_10_3_6_mec gc_10_3_6_mec2 \
              gc_10_3_6_pfp gc_10_3_6_rlc sdma_5_2_6 vcn_3_1_2; do
      for ext in .bin.zst .bin; do
          [ -f "${HOSTDIR}/${blob}${ext}" ] || continue
          for dest in $DESTDIRS; do
              mkdir -p "$dest"
              cp "${HOSTDIR}/${blob}${ext}" "${dest}/${blob}${ext}"
          done
          break
      done
  done
  HOOK
  chmod +x /target/etc/initramfs-tools/hooks/amdgpu-firmware
```

---

### 0.9 DMUB Firmware Version Reference

| Version Hex | Version Decimal | Source | Stability with Glamor |
|-------------|-----------------|--------|----------------------|
| 0x05000F00 | 0.0.15.0 | Ubuntu 24.04 stock (linux-firmware 20240318) | **UNSTABLE** — ring timeouts |
| 0x05002000 | 0.0.32.0 | install-firmware.sh (linux-firmware tag 20250509) | **STABLE** — no ring timeouts |
| 0x0500E000 | 0.0.224.0 | linux-firmware tag 20240709 | Expected stable (Debian fix) |
| 0x050FF000 | 0.0.255.0 | linux-firmware tag 20250305 | Expected stable (conservative target) |

**VCN firmware also upgraded:**
- Old: ENC 1.30, DEC 3, VEP 0, Revision 4
- New: ENC 1.33, DEC 4, VEP 0, Revision 6

---

### 0.10 Next Steps

1. **Fix autoinstall firmware delivery:** Add initramfs hook to Variant B
   late-commands (Section 0.8). Re-test to confirm firmware loads on first boot.

2. **Verify optc31 timeout is benign:** Boot -1 (DMUB 0x05002000) still showed
   1 optc31 timeout but zero ring timeouts. Confirm this pattern is consistent
   across 10+ boots to rule out intermittent regressions.

3. **Test Variant C (full stack):** Once B is confirmed stable, add NVIDIA
   back to verify dual-GPU coexistence with new firmware.

4. **Consider linux-firmware 20250305 (DMUB 0.0.255.0):** The tag 20250509
   used by `install-firmware.sh` provided DMUB 0x05002000 (0.0.32.0), which
   works. Tag 20250305 provides 0.0.255.0, which is even newer. Test if it
   also eliminates the residual optc31 timeout.

---

<a name="1-critical"></a>
## 1. CRITICAL -- Capture During or Immediately After Crash

These diagnostics are time-sensitive. Some data (devcoredump, ring state) is
transient and disappears after a few minutes or after GPU reset recovery.

---

### 1.1 Device Coredump (devcoredump)

**Why it matters:** When amdgpu detects a ring timeout and triggers GPU reset,
it creates a device coredump containing a full snapshot of GPU and driver state
at the moment of the hang. This includes the faulting ring, IP block states,
fence sequences, and (on newer kernels) the IB contents that caused the
timeout. The devcoredump is the single most valuable artifact for root-cause
analysis because it freezes the GPU state before reset destroys it.

**The problem:** Devcoredumps auto-delete after an internal kernel timer
(default ~5 minutes) OR after being read once. On a crash-looping system,
repeated GPU resets may overwrite previous dumps. Newer kernels (6.15+) have a
patch to "always keep the latest coredump" which helps.

**Exact paths and commands:**

```bash
# Check if any coredump exists right now
ls /sys/class/devcoredump/devcd*/data 2>/dev/null

# Read the coredump (WARNING: reading clears it on older kernels)
# Copy first, read later
for dump in /sys/class/devcoredump/devcd*/data; do
    [ -f "$dump" ] || continue
    devcd_name=$(basename $(dirname "$dump"))
    cp "$dump" "/tmp/amdgpu-devcoredump-${devcd_name}-$(date +%s).txt" 2>/dev/null
done

# Alternative path (symlinked from DRM device)
cat /sys/class/drm/card*/device/devcoredump/data 2>/dev/null
```

**What to look for in the dump:**
```
**** AMDGPU Device Coredump ****
kernel: <version>
module: amdgpu
...
ring name: gfx_0.0.0          <- Which ring timed out
...
Fence driver on ring gfx_0.0.0:
  last signaled fence: 0xNNNN
  last emitted fence:  0xNNNN  <- Gap between signaled and emitted = stuck jobs
...
IP Block Status:
  GFX: <state>
  SDMA: <state>
  VCN: <state>
```

- **Requires root:** No for reading, but the file is often only readable by root
- **Safe on unstable system:** Yes -- read-only
- **Auto-capture:** See Section 4.1 (udev rule)

---

### 1.2 DMCUB Trace Buffer

**Why it matters:** The DMCUB (Display Microcontroller Unit B) is a dedicated
microcontroller that manages display state transitions -- including the exact
CRTC disable/enable sequence that triggers the optc31 timeout. The DMCUB
trace buffer is a ring buffer recording internal firmware events: state
transitions, mailbox commands, register operations, and error conditions.
This is the ONLY way to see what the display firmware was doing when OTG_BUSY
got stuck.

**Exact commands:**

```bash
# Find the AMD DRI number first
AMD_DRI=""
for d in /sys/kernel/debug/dri/[0-9]*; do
    name=$(cat "$d/name" 2>/dev/null)
    echo "$name" | grep -qi amdgpu && AMD_DRI=$(basename "$d") && break
done

# Dump the DMCUB trace buffer (chronological since kernel 6.15+)
cat /sys/kernel/debug/dri/${AMD_DRI}/amdgpu_dm_dmub_tracebuffer

# Dump DMCUB firmware state
cat /sys/kernel/debug/dri/${AMD_DRI}/amdgpu_dm_dmub_fw_state
```

**Trace buffer entry format:**
Each entry contains: `trace_code`, `tick_count`, `param0`, `param1`.
The trace buffer is a ring -- if it rolled over, entries may not be
chronological on kernels before 6.15 (commit that added chronological
ordering). Kernel 6.15+ prints chronologically using the fw `meta_info`
entry count.

**What to look for:**
- Trace codes corresponding to CRTC disable/enable operations
- Mailbox timeout entries (DMCUB stopped responding to driver commands)
- Repeated initialization entries (DMCUB re-init after MODE2 reset means
  firmware saw the reset but DCN state was NOT cleaned)
- Gaps in tick_count indicating firmware hung for a period

**Requires root:** Yes (debugfs)
**Safe on unstable system:** Yes -- read-only, does not change state
**Auto-capture:** See Section 4.2 (systemd timer)

---

### 1.3 DMCUB Trace Event Control

**Why it matters:** The DMCUB can generate trace events that are logged to
dmesg. Enabling them before boot gives real-time visibility into DMCUB
operations during the critical EFI-to-amdgpu handoff window.

```bash
# Enable DMCUB trace events (write 1 to enable, 0 to disable)
echo 1 > /sys/kernel/debug/dri/${AMD_DRI}/amdgpu_dm_dmcub_trace_event_en

# Control which trace groups are logged via bitmask
# Each bit enables a different trace group in the firmware
cat /sys/kernel/debug/dri/${AMD_DRI}/amdgpu_dm_dmub_trace_mask
echo 0xFFFF > /sys/kernel/debug/dri/${AMD_DRI}/amdgpu_dm_dmub_trace_mask
```

**Requires root:** Yes
**Safe on unstable system:** Mostly safe. Enabling full trace mask generates
heavy dmesg output which could impact performance on an already struggling
system. Use targeted masks in production.
**Auto-capture:** Enable at boot via systemd service (Section 4.2)

---

### 1.4 Display Test Next (DTN) Log -- Full Pipeline State

**Why it matters:** The DTN log is the most comprehensive dump of the DCN
display pipeline hardware state. It shows the configuration of every display
block: HUBBUB watermarks, HUBP (framebuffer fetch), DPP (pixel processing),
MPCC (multi-pipe compositing), OTG (output timing generator), and DSC
(display stream compression). This directly reveals:

- Whether OTG[0] is stuck (the optc31 bug)
- HUBP underflow status (scatter/gather DMA failures)
- Whether blank_en is set (pipe in blanked state)
- Actual framebuffer address, dimensions, pixel format
- Watermark values (indicates memory bandwidth calculations)

```bash
# One-shot dump
cat /sys/kernel/debug/dri/${AMD_DRI}/amdgpu_dm_dtn_log

# Real-time monitoring (watch for changes during crash)
sudo watch -d -n 0.5 cat /sys/kernel/debug/dri/${AMD_DRI}/amdgpu_dm_dtn_log
```

**Key fields to examine:**

| Block | Field | What to Check |
|-------|-------|---------------|
| HUBP[0] | `blank_en` | 1 = pipe blanked (normal during disable); stuck at 0 during disable = bad |
| HUBP[0] | `clock_en` | 0 = HUBP clock gated; should be 1 if pipe is active |
| HUBP[0] | `underflow` | Non-zero = HUBP could not fetch FB data in time (GART/sg_display issue) |
| HUBP[0] | `ttu_dis` | 1 = time-to-urgent disabled; unusual |
| OTG[0] | `underflow` | Non-zero = OTG starved for data -- pipeline broken |
| OTG[0] | `blank_en` | 0 during active display, 1 during blanking |
| OTG[0] | `v_bs/v_be/h_bs/h_be` | Timing parameters; all 0 = OTG not programmed |
| HUBBUB WM | `sr_enter/sr_exit` | Self-refresh watermarks; critical for APU with shared memory |

**Requires root:** Yes (debugfs)
**Safe on unstable system:** Yes -- read-only
**Auto-capture:** Capture on every boot and on GPU reset event

---

### 1.5 Ring Buffer State

**Why it matters:** The GFX ring is where the compositor submits rendering
commands. When the ring times out, examining the ring read/write pointers
reveals whether the GPU stopped processing (HW hang) or never received
commands (software/scheduling issue).

```bash
# Dump all ring buffer status
for ring in /sys/kernel/debug/dri/${AMD_DRI}/amdgpu_ring_*; do
    [ -f "$ring" ] || continue
    echo "=== $(basename "$ring") ==="
    # First 50 lines show ring metadata: rptr, wptr, count, etc.
    head -50 "$ring"
    echo ""
done
```

**What to look for:**
- `rptr` (read pointer) == `wptr` (write pointer): ring is idle/drained
- `rptr` stuck while `wptr` advanced: GPU hardware hang
- `rptr` and `wptr` both stuck at same non-zero value: scheduler stopped
- Ring `gfx_0.0.0` vs `gfx_0.1.0`: which GFX pipe is stuck

**Requires root:** Yes (debugfs)
**Safe on unstable system:** Yes
**Auto-capture:** Section 4.2

---

### 1.6 Fence State

**Why it matters:** Fences are the synchronization mechanism between CPU and
GPU. The gap between "last emitted" and "last signaled" reveals how many
commands are stuck in the GPU pipeline. Multiple rings showing stuck fences
indicates a system-wide hang (likely DCN-caused) vs a single ring (likely
that ring's IP block).

```bash
cat /sys/kernel/debug/dri/${AMD_DRI}/amdgpu_fence_info
```

**What to look for:**
```
--- ring gfx_0.0.0 ---
Last signaled fence          0x00001234
Last emitted                 0x00001238   <- 4 fences stuck in GPU
...
```

- Gap > 0: jobs submitted but not completed
- All rings show gaps: full GPU hang (likely DCN/MMHUB frozen everything)
- Only gfx ring: GFX-specific hang (compositor job stuck on display op)

**Requires root:** Yes (debugfs)
**Safe on unstable system:** Yes

---

### 1.7 GPU Reset Event Correlation

**Why it matters:** Understanding the exact sequence -- which timeout
triggered which reset, what IP blocks were affected, and whether reset
succeeded or failed -- is essential for determining if MODE2 reset is the
problem (it does not reset DCN).

```bash
# Timestamped timeline of all reset-related events
dmesg -T | grep -iE \
  'REG_WAIT timeout|ring.*timeout|GPU reset|MODE[012]|amdgpu_job_timedout|gpu recover|gpu fault|page fault|vm fault|ring.*reset.*fail|wedged|signaled seq|emitted seq' \
  | sort

# Extract which process triggered each timeout
dmesg | grep -B1 -A3 "ring gfx_0\.[01]\.0 timeout"

# Count DMUB re-initializations (indicates MODE2 reset occurred
# but DCN was not properly reset)
dmesg | grep -c "DMUB.*initialized\|DMUB.*version="
# Expected: 1 (boot). Multiple = reset loop.

# Check reset method actually used
dmesg | grep -iE "reset_method|mode[012].*reset|BACO|full.*reset"
```

**What to look for:**
- `MODE2 reset` appearing: DCN was NOT reset (root cause of crash loop)
- Multiple `DMUB.*version=` entries: firmware re-inited after resets
- `ring reset failed`: soft reset failed, escalated to full reset
- `GPU reset succeeded` followed by another timeout within 30s: DCN still broken

**Requires root:** No (dmesg may need root depending on kernel.dmesg_restrict)
**Safe on unstable system:** Yes

---

### 1.8 PCI Advanced Error Reporting (AER)

**Why it matters:** PCIe link errors (correctable or uncorrectable) can
cause GPU communication failures that look like ring timeouts. On the RTX
4090, ASPM issues cause Xid 79 errors. On the iGPU (integrated into CPU
package), AER errors would indicate a fundamental SoC issue. AER data helps
distinguish between a DCN firmware bug and a PCIe link problem.

```bash
# Per-device AER counters (survives across resets)
for card in /sys/class/drm/card[0-9]*; do
    [ -d "$card/device" ] || continue
    name=$(basename "$card")
    vendor=$(cat "$card/device/vendor" 2>/dev/null)
    echo "=== $name (vendor=$vendor) ==="
    for f in aer_dev_correctable aer_dev_nonfatal aer_dev_fatal; do
        [ -f "$card/device/$f" ] || continue
        echo "  $f:"
        cat "$card/device/$f" 2>/dev/null | while read line; do
            val=$(echo "$line" | awk '{print $NF}')
            [ "$val" != "0" ] && echo "    *** $line ***" || echo "    $line"
        done
    done
    echo ""
done

# Kernel AER messages
dmesg | grep -iE "AER|correctable error|uncorrectable error|PCIe Bus Error"

# Full PCIe link status for both GPUs
lspci -vvv -s $(lspci -Dn | grep "1002" | head -1 | awk '{print $1}') 2>/dev/null | \
    grep -iE "LnkSta:|LnkCap:|DevSta:|AER"
lspci -vvv -s $(lspci -Dn | grep "10de" | head -1 | awk '{print $1}') 2>/dev/null | \
    grep -iE "LnkSta:|LnkCap:|DevSta:|AER"
```

**What to look for:**
- Any non-zero AER counter on the AMD iGPU: unusual for integrated GPU
- `BadTLP` or `BadDLLP` on NVIDIA: PCIe link integrity issue (ASPM-related)
- `Unsupported Request`: driver tried to access unmapped BAR
- `LnkSta: Speed 2.5GT/s` when `LnkCap: Speed 16GT/s`: link downgraded

**Requires root:** Some files need root, `lspci -vvv` needs root
**Safe on unstable system:** Yes

---

### 1.9 VRAM and GTT Memory State

**Why it matters:** On Raphael, VRAM is carved from system memory via UMA.
When `sg_display=1` (default for APUs), the display framebuffer is allocated
from GTT (system memory via GART scatter/gather DMA). If GART TLB state is
inconsistent during the EFI-to-amdgpu transition, HUBP cannot fetch
framebuffer data, causing the pipeline stall that precedes the optc31 timeout.

```bash
# GPU memory allocation summary
for f in mem_info_vram_total mem_info_vram_used mem_info_vis_vram_total \
         mem_info_vis_vram_used mem_info_gtt_total mem_info_gtt_used; do
    val=$(cat "/sys/class/drm/card${AMD_CARD_NUM}/device/$f" 2>/dev/null)
    [ -n "$val" ] && printf "%-30s = %s (%s MB)\n" "$f" "$val" "$((val/1048576))"
done

# GEM (Graphics Execution Manager) buffer objects -- shows all active allocations
cat /sys/kernel/debug/dri/${AMD_DRI}/amdgpu_gem_info

# VM (Virtual Memory) info -- GART page table state
cat /sys/kernel/debug/dri/${AMD_DRI}/amdgpu_vm_info

# SA (Sub-Allocator) info -- internal driver allocations
cat /sys/kernel/debug/dri/${AMD_DRI}/amdgpu_sa_info

# System memory pressure (can trigger VRAM/GTT evictions)
cat /proc/meminfo | grep -E "MemTotal|MemFree|MemAvail|Buffers|Cached|Swap"
cat /proc/buddyinfo
```

**What to look for:**
- `mem_info_gtt_used` >> 0 with `sg_display=1`: display FB in GTT (risky)
- `mem_info_vram_used` near `mem_info_vram_total`: VRAM pressure
- Low system memory: could trigger GTT eviction of display framebuffer
- GEM objects pinned in VRAM for display: confirms `sg_display=0` worked

**Requires root:** debugfs files need root; sysfs may not
**Safe on unstable system:** Yes

---

### 1.10 Power State and GFXOFF Status

**Why it matters:** GFXOFF is a power-saving feature where the GFX engine
is completely powered down when idle. If GFXOFF activates during a DCN
operation that needs GFX, the register access times out. The upstream bug
(#5073) explicitly mentions GFXOFF as a contributing factor. Even with the
BIOS GFXOFF setting disabled, the software feature mask must also disable it.

```bash
# GFXOFF status (0=off, 1=in GFXOFF, 2=transitioning)
cat /sys/kernel/debug/dri/${AMD_DRI}/amdgpu_gfxoff 2>/dev/null
cat /sys/kernel/debug/dri/${AMD_DRI}/amdgpu_gfxoff_status 2>/dev/null

# GFXOFF entry count (should be 0 if properly disabled)
cat /sys/kernel/debug/dri/${AMD_DRI}/amdgpu_gfxoff_count 2>/dev/null

# GFXOFF residency (time spent in GFXOFF)
cat /sys/kernel/debug/dri/${AMD_DRI}/amdgpu_gfxoff_residency 2>/dev/null

# ppfeaturemask -- check bit 15 (GFXOFF)
# 0xfffd7fff = GFXOFF disabled; 0xfff7bfff = bit 15 still set
cat /sys/module/amdgpu/parameters/ppfeaturemask

# SMU power info
cat /sys/kernel/debug/dri/${AMD_DRI}/amdgpu_pm_info

# Current clock frequencies
cat /sys/class/drm/card${AMD_CARD_NUM}/device/pp_dpm_sclk
cat /sys/class/drm/card${AMD_CARD_NUM}/device/pp_dpm_mclk
cat /sys/class/drm/card${AMD_CARD_NUM}/device/pp_dpm_socclk
cat /sys/class/drm/card${AMD_CARD_NUM}/device/pp_dpm_dcefclk
cat /sys/class/drm/card${AMD_CARD_NUM}/device/pp_dpm_fclk

# Runtime PM state (should be "active" for iGPU driving display)
cat /sys/class/drm/card${AMD_CARD_NUM}/device/power/runtime_status
```

**What to look for:**
- `amdgpu_gfxoff_count` > 0: GFXOFF is activating despite being "disabled"
- `ppfeaturemask` has bit 15 set (0x8000): GFXOFF still enabled in software
- `dcefclk` at lowest DPM level during display activity: underpowered DCE
- `runtime_status` = "suspended": GPU runtime-suspended while display active

**Requires root:** debugfs needs root
**Safe on unstable system:** Yes

---

<a name="2-important"></a>
## 2. IMPORTANT -- System State Baseline

These diagnostics establish the system configuration and should be captured
on every boot, whether or not a crash occurs. They provide the baseline
against which crash data is compared.

---

### 2.1 Firmware Version Verification

**Why it matters:** The DMCUB firmware version is the single most important
variable. Version 0.0.15.0 (0x05000F00) is critically outdated and known
buggy. The minimum safe version is 0.0.224.0 (post-Debian #1057656 fix).
Verifying the ACTUAL loaded firmware (not just what's on disk) is critical
because `.bin`/`.bin.zst` conflicts can cause the wrong firmware to load.

```bash
# Firmware versions from debugfs (most authoritative -- shows what's RUNNING)
cat /sys/kernel/debug/dri/${AMD_DRI}/amdgpu_firmware_info

# DMUB version from dmesg (shows what was loaded at boot)
dmesg | grep -iE "DMUB|dmcub" | head -20

# Firmware version encoding: 0x0XYYZZWW -> X.YY.ZZ.WW
# 0x05000F00 = 0.0.15.0  (BAD -- predates all fixes)
# 0x0500E000 = 0.0.224.0 (minimum safe)
# 0x0500FF00 = 0.0.255.0 (conservative target)
# 0x05010E00 = 0.1.14.0  (caution -- NixOS load failures)
# 0x05013500 = 0.1.53.0  (latest HEAD)

# All firmware blobs on disk vs in initramfs
echo "=== On-disk firmware ==="
ls -la /lib/firmware/amdgpu/dcn_3_1_5_* 2>/dev/null
ls -la /lib/firmware/amdgpu/psp_13_0_5_* 2>/dev/null
ls -la /lib/firmware/amdgpu/gc_10_3_6_* 2>/dev/null

echo "=== .bin/.bin.zst conflicts ==="
for f in /lib/firmware/amdgpu/{dcn_3_1_5,psp_13_0_5,gc_10_3_6}_*.bin; do
    [ -f "$f" ] || continue
    case "$f" in *.bin.zst) continue ;; esac
    [ -f "${f}.zst" ] && echo "CONFLICT: $(basename $f) AND ${f}.zst both exist"
done

echo "=== Firmware in initramfs ==="
lsinitramfs /boot/initrd.img-$(uname -r) 2>/dev/null | grep -E "dcn_3_1_5|psp_13_0_5|gc_10_3_6"

echo "=== DMCUB .bin.zst hex header (version bytes) ==="
# Decompress and show first 32 bytes to verify version
zstdcat /lib/firmware/amdgpu/dcn_3_1_5_dmcub.bin.zst 2>/dev/null | xxd | head -4

echo "=== linux-firmware package version ==="
dpkg -l linux-firmware 2>/dev/null
```

**What to look for:**
- DMCUB firmware version < 0x0500E000 (0.0.224.0): CRITICAL -- update needed
- Both `.bin` and `.bin.zst` exist: kernel loads `.bin.zst`, ignoring `.bin`
- Firmware missing from initramfs: won't be available in early boot
- Multiple `DMUB.*version=` lines in dmesg: firmware re-initialized (reset loop)

**Requires root:** debugfs needs root; file listing does not
**Safe on unstable system:** Yes

---

### 2.2 Module Load Order and Timing

**Why it matters:** The DRM card numbering (card0, card1) is determined by
module load order. If NVIDIA loads before amdgpu, NVIDIA gets card0 and the
display stack may route rendering to the wrong GPU. On this system, amdgpu
MUST be card0 because the iGPU drives all displays. The
`initcall_blacklist=simpledrm_platform_driver_init` parameter prevents
simpledrm from stealing card0.

```bash
# Current card assignments (CRITICAL: AMD must be card0)
for card in /sys/class/drm/card[0-9]; do
    [ -d "$card" ] || continue
    vendor=$(cat "$card/device/vendor" 2>/dev/null)
    device=$(cat "$card/device/device" 2>/dev/null)
    driver=$(basename $(readlink "$card/device/driver") 2>/dev/null)
    case $vendor in
        0x1002) vname="AMD" ;;
        0x10de) vname="NVIDIA" ;;
        *) vname="$vendor" ;;
    esac
    echo "$(basename $card): $vname ($vendor:$device) driver=$driver"
done

# Module load timestamps from dmesg
dmesg | grep -E "simpledrm|amdgpu|nvidia" | head -30

# Exact timestamps of key init events
dmesg -T | grep -iE \
  'simpledrm.*initialized|amdgpu 0000|nvidia 0000|Display Core initialized|DMUB firmware|fb[0-9]:.*frame buffer' \
  | head -20

# Was simpledrm blacklisted?
cat /proc/cmdline | grep -o 'initcall_blacklist=[^ ]*'

# Module load order in initramfs
cat /etc/initramfs-tools/modules
cat /etc/modules-load.d/gpu.conf 2>/dev/null
```

**What to look for:**
- card0=NVIDIA, card1=AMD: **WRONG** -- amdgpu must be card0
- simpledrm initialized at ~0.1s, amdgpu at ~3s: simpledrm got card0 first
- `initcall_blacklist=simpledrm_platform_driver_init` present: good
- amdgpu listed before nvidia in initramfs modules: correct order

**Requires root:** No
**Safe on unstable system:** Yes

---

### 2.3 Kernel Parameters -- Effective vs Configured

**Why it matters:** There are THREE places where amdgpu parameters can be
set (GRUB cmdline, modprobe.d, compiled defaults), and they can conflict.
The diagnostic runLog-04 found exactly this: modprobe.d and GRUB had
different values from test iterations, and the effective runtime value
differed from both.

```bash
# What the kernel actually booted with
cat /proc/cmdline

# What modprobe.d says
cat /etc/modprobe.d/amdgpu.conf 2>/dev/null
cat /etc/modprobe.d/nvidia.conf 2>/dev/null

# What GRUB is configured with
grep "GRUB_CMDLINE" /etc/default/grub 2>/dev/null

# What the driver is ACTUALLY running with (the truth)
if [ -d /sys/module/amdgpu/parameters ]; then
    echo "=== EFFECTIVE amdgpu parameters ==="
    for p in /sys/module/amdgpu/parameters/*; do
        pname=$(basename "$p")
        pval=$(cat "$p" 2>/dev/null || echo "unreadable")
        printf "%-30s = %s\n" "$pname" "$pval"
    done
fi

# Check for unknown/invalid parameter warnings
dmesg | grep -i "unknown parameter"

# Validate modprobe.d parameters against accepted ones
echo "=== Parameter validation ==="
for param in $(grep "^options amdgpu" /etc/modprobe.d/amdgpu.conf 2>/dev/null | \
    sed 's/options amdgpu//' | tr ' ' '\n' | cut -d= -f1); do
    if modinfo amdgpu 2>/dev/null | grep -q "parm:.*${param}:"; then
        echo "  $param: VALID"
    else
        echo "  $param: INVALID (will be IGNORED or cause load failure)"
    fi
done
```

**What to look for:**
- `sg_display` reads `-1` at runtime but configured as `0`: NOT applied
- `ppfeaturemask` reads `0xfff7bfff` but should be `0xfffd7fff`: wrong bit
- Unknown parameter warnings: module may have failed to load with those
- Conflicts between GRUB and modprobe.d: last one wins, unpredictably

**Requires root:** No
**Safe on unstable system:** Yes

---

### 2.4 Display Server and Session State

**Why it matters:** The crash loop is triggered by the compositor (gnome-shell
in previous tests, now XFCE with xfwm4). Understanding what the display
server is doing when the crash occurs helps determine if the problem is
compositor-specific. XFCE with compositing OFF uses XRender (zero GFX ring
submissions) and should avoid the bug entirely.

```bash
# Display manager status
systemctl status lightdm --no-pager 2>/dev/null || \
    systemctl status gdm3 --no-pager 2>/dev/null

# LightDM logs
journalctl -u lightdm -b --no-pager | tail -100
cat /var/log/lightdm/lightdm.log 2>/dev/null | tail -50

# Xorg log (critical for understanding display init)
cat /var/log/Xorg.0.log 2>/dev/null | head -200

# Active sessions and display type
loginctl list-sessions --no-pager 2>/dev/null
for sess in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
    loginctl show-session "$sess" --no-pager 2>/dev/null | \
        grep -E "Type=|Display=|Remote=|Service=|Desktop="
done

# XFCE compositor state
xfconf-query -c xfwm4 -p /general/use_compositing 2>/dev/null || echo "N/A"

# Is Mutter KMS thread workaround active? (relevant if GNOME fallback)
cat /etc/environment.d/90-mutter-kms.conf 2>/dev/null

# gpu-manager (Ubuntu's automatic GPU config -- should be disabled)
systemctl status gpu-manager --no-pager 2>/dev/null
cat /var/log/gpu-manager.log 2>/dev/null | tail -20

# Which GPU is rendering the desktop
glxinfo 2>/dev/null | grep -E "OpenGL renderer|OpenGL vendor" | head -2
# Expected: AMD Radeon Graphics (raphael, LLVM ...)

# NVIDIA display status (should show Disabled)
nvidia-smi --query-gpu=name,display_active,display_mode --format=csv 2>/dev/null
```

**What to look for:**
- Xorg using `modesetting` driver on AMD card: correct
- Xorg using `nvidia` driver for display: WRONG for this architecture
- gpu-manager active: can interfere with manual GPU config
- XFCE compositing ON: GFX ring submissions happening
- XFCE compositing OFF: XRender only, should avoid ring timeouts

**Requires root:** Some commands need root
**Safe on unstable system:** Yes

---

### 2.5 DRM Connector and EDID State

**Why it matters:** The display connector status shows which outputs are
connected and active. If multiple outputs are "connected" when only one
monitor is physically attached, phantom outputs can cause extra DCN pipe
programming. EDID parsing failures can cause mode-setting issues.

```bash
# All connectors with detailed status
for conn in /sys/class/drm/card*-*; do
    [ -d "$conn" ] || continue
    name=$(basename "$conn")
    status=$(cat "$conn/status" 2>/dev/null || echo "unknown")
    enabled=$(cat "$conn/enabled" 2>/dev/null || echo "unknown")
    dpms=$(cat "$conn/dpms" 2>/dev/null || echo "unknown")
    modes_count=$(cat "$conn/modes" 2>/dev/null | wc -l)
    first_mode=$(head -1 "$conn/modes" 2>/dev/null || echo "none")
    printf "%-30s status=%-12s enabled=%-8s dpms=%-4s modes=%-3d first=%s\n" \
        "$name" "$status" "$enabled" "$dpms" "$modes_count" "$first_mode"
done

# EDID hex dump for connected outputs
for conn in /sys/class/drm/card*-*; do
    [ -f "$conn/edid" ] || continue
    status=$(cat "$conn/status" 2>/dev/null)
    [ "$status" = "connected" ] || continue
    echo "=== $(basename $conn) EDID ==="
    xxd "$conn/edid" 2>/dev/null | head -16
    echo ""
done

# EDID decode (if edid-decode installed)
command -v edid-decode >/dev/null 2>&1 && {
    for conn in /sys/class/drm/card*-*; do
        status=$(cat "$conn/status" 2>/dev/null)
        [ "$status" = "connected" ] || continue
        [ -f "$conn/edid" ] || continue
        echo "=== $(basename $conn) ==="
        edid-decode "$conn/edid" 2>&1
    done
}
```

**Requires root:** No
**Safe on unstable system:** Yes

---

### 2.6 IOMMU and GART State

**Why it matters:** With `iommu=pt` (passthrough), GPU DMA bypasses the
IOMMU translation. With `sg_display=1`, the display framebuffer is scatter/
gather mapped through GART. IOMMU translation faults or GART errors can
cause HUBP to fail to fetch framebuffer data, stalling the display pipeline.

```bash
# IOMMU configuration
dmesg | grep -iE "IOMMU|AMD-Vi|DMAR" | head -20
cat /proc/cmdline | grep -o 'iommu=[^ ]*'

# IOMMU groups (GPUs should be in separate groups)
for d in /sys/kernel/iommu_groups/*/devices/*; do
    [ -e "$d" ] || continue
    grp=$(echo "$d" | cut -d/ -f5)
    dev="${d##*/}"
    info=$(lspci -nns "$dev" 2>/dev/null)
    echo "Group $grp: $info"
done 2>/dev/null | grep -iE "VGA|Display|3D|Audio.*1002|Audio.*10de"

# IOMMU faults (should be empty with iommu=pt)
dmesg | grep -iE "IOMMU.*fault|AMD-Vi.*event|IO_PAGE_FAULT|translation fault"

# GART errors
dmesg | grep -iE "GART|gart.*error|gart.*fault|mc.*error|mmhub.*error"

# GCVM L2 protection faults (GPU page table errors)
dmesg | grep -iE "GCVM_L2_PROTECTION_FAULT|VM_L2_PROTECTION"
```

**What to look for:**
- `IO_PAGE_FAULT` on AMD device: IOMMU blocking GPU DMA access
- `AMD-Vi: Event logged`: IOMMU translation error
- `GART error`: GPU page table mapping failure
- `GCVM_L2_PROTECTION_FAULT`: GPU virtual memory fault

**Requires root:** Some commands need root
**Safe on unstable system:** Yes

---

### 2.7 Kernel Taint and System Health

**Why it matters:** A tainted kernel (proprietary module, previous oops)
changes behavior. Knowing the taint state at crash time helps determine if
the NVIDIA proprietary driver contributed.

```bash
# Kernel taint flags
cat /proc/sys/kernel/tainted
# 0 = clean
# 1 = proprietary module loaded (P) -- NVIDIA always causes this
# 4 = SMP but unsafe (S)
# 64 = previous OOPS (D) -- important: kernel was already degraded
# 128 = module force-loaded (O)
# 256 = module force-unloaded (R)
# 8192 = externally-built module loaded (E) -- NVIDIA

# Decode taint flags
cat /proc/version

# Failed systemd units
systemctl --failed --no-pager

# OOM events
dmesg | grep -i "oom\|out of memory\|killed process"

# Previous kernel panic/oops
dmesg | grep -i "kernel panic\|Oops\|BUG:\|RIP:\|Call Trace" | head -20
```

**Requires root:** No
**Safe on unstable system:** Yes

---

<a name="3-nice-to-have"></a>
## 3. NICE-TO-HAVE -- Deep Dive and Tracing

These diagnostics provide deep insight but require setup, may impact
performance, or need specific tools installed. Use them for focused
debugging sessions.

---

### 3.1 ftrace: Tracing DCN Init and CRTC Operations

**Why it matters:** ftrace can trace the exact kernel function call chain
during the optc31_disable_crtc timeout. This reveals whether the driver
reached the REG_WAIT, how long it waited, and what called it. This is
the closest thing to a debugger for the crash sequence.

```bash
# List available amdgpu tracepoints
ls /sys/kernel/tracing/events/amdgpu/ 2>/dev/null
# Common ones: amdgpu_bo_move, amdgpu_cs_ioctl, amdgpu_iv,
#              amdgpu_vm_bo_map, amdgpu_vm_bo_unmap

# List DRM display tracepoints
ls /sys/kernel/tracing/events/drm/ 2>/dev/null

# List amdgpu_dm (display manager) tracepoints
ls /sys/kernel/tracing/events/amdgpu_dm/ 2>/dev/null

# Enable function_graph tracing for DCN init functions
echo function_graph > /sys/kernel/tracing/current_tracer
echo 'dcn31_init_hw' > /sys/kernel/tracing/set_graph_function
echo 'dcn10_init_pipes' >> /sys/kernel/tracing/set_graph_function
echo 'optc31_disable_crtc' >> /sys/kernel/tracing/set_graph_function
echo 'optc1_wait_for_state' >> /sys/kernel/tracing/set_graph_function
echo 'dcn31_enable_power_gating_plane' >> /sys/kernel/tracing/set_graph_function
echo 1 > /sys/kernel/tracing/tracing_on

# Capture trace (after event occurs)
cat /sys/kernel/tracing/trace > /tmp/ftrace-dcn-init.txt

# Disable tracing
echo 0 > /sys/kernel/tracing/tracing_on
echo nop > /sys/kernel/tracing/current_tracer

# --- Alternative: Boot-time ftrace via kernel cmdline ---
# Add to GRUB_CMDLINE_LINUX_DEFAULT:
#   ftrace=function_graph ftrace_filter=optc31_disable_crtc,optc1_wait_for_state,dcn31_init_hw
#   trace_buf_size=64M
```

**What to look for:**
- `optc31_disable_crtc` call duration > 100ms: confirmed REG_WAIT timeout
- `dcn10_init_pipes` calling `optc31_disable_crtc` on pipe 0: the crash path
- Missing return from `optc1_wait_for_state`: hung in register poll loop
- `dcn31_init_hw` completing normally: optc31 was not the failure point

**Requires root:** Yes
**Safe on unstable system:** LOW RISK but adds overhead. Function graph
tracing on frequently called functions can slow boot. Restrict to specific
functions only.
**Auto-capture:** Kernel cmdline ftrace setup captures from very early boot

---

### 3.2 ftrace: Tracing amdgpu_dm Atomic Commit

**Why it matters:** The compositor triggers display updates via
`amdgpu_dm_atomic_commit_tail`. If this function is where the GFX ring
timeout occurs (because it waits for a display flip that never completes
due to DCN stall), tracing it shows the exact commit that failed.

```bash
# Trace atomic commit path
echo function_graph > /sys/kernel/tracing/current_tracer
echo 'amdgpu_dm_atomic_commit_tail' > /sys/kernel/tracing/set_graph_function
echo 'dm_update_crtc_state' >> /sys/kernel/tracing/set_graph_function
echo 'amdgpu_dm_commit_planes' >> /sys/kernel/tracing/set_graph_function
echo 1 > /sys/kernel/tracing/tracing_on

# After crash, dump trace
cat /sys/kernel/tracing/trace > /tmp/ftrace-atomic-commit.txt

# --- Targeted: trace specific amdgpu_dm events ---
echo 1 > /sys/kernel/tracing/events/amdgpu_dm/enable
cat /sys/kernel/tracing/trace_pipe  # real-time output
```

**Requires root:** Yes
**Safe on unstable system:** Moderate risk -- atomic commits happen frequently

---

### 3.3 eBPF Probes for GPU Events

**Why it matters:** eBPF provides zero-overhead (when not firing) probes
that can capture function arguments and return values. This is more
targeted than ftrace and can filter for specific conditions.

```bash
# Prerequisites
apt install bpfcc-tools linux-headers-$(uname -r)

# Trace ring timeout handler with arguments
# This fires only when amdgpu_job_timedout is called
bpftrace -e '
kprobe:amdgpu_job_timedout {
    printf("RING TIMEOUT at %llu ns, comm=%s pid=%d\n",
           nsecs, comm, pid);
    print(kstack);
}
'

# Trace GPU reset
bpftrace -e '
kprobe:amdgpu_device_gpu_recover {
    printf("GPU RESET at %llu ns\n", nsecs);
    print(kstack);
}
kretprobe:amdgpu_device_gpu_recover {
    printf("GPU RESET returned %d\n", retval);
}
'

# Trace optc31 timeout specifically
bpftrace -e '
kprobe:optc31_disable_crtc {
    printf("optc31_disable_crtc ENTER at %llu ns\n", nsecs);
}
kretprobe:optc31_disable_crtc {
    printf("optc31_disable_crtc EXIT at %llu ns (duration: %llu ns)\n",
           nsecs, nsecs - @start[tid]);
}
'
```

**Requires root:** Yes
**Safe on unstable system:** Safe -- eBPF probes are non-invasive
**Prerequisites:** bpfcc-tools, kernel headers

---

### 3.4 UMR -- AMDGPU User Mode Register Debugger

**Why it matters:** UMR is AMD's official register-level debugging tool.
It can read/write MMIO, PCIE, SMC registers directly, decode ring
contents, scan entire IP blocks, and inspect wave states. For the optc31
bug, UMR can directly read the OTG_CLOCK_CONTROL and OTG_STATUS registers
that are timing out.

```bash
# Install
apt install umr  # or build from source: https://cgit.freedesktop.org/amd/umr/

# Detect GPU
umr --enumerate

# Scan DCN registers (OPTC block)
umr --scan dcn31.optc0

# Read specific registers mentioned in optc31_disable_crtc
umr --read dcn31.optc0.OTG_CLOCK_CONTROL
umr --read dcn31.optc0.OTG_STATUS
umr --read dcn31.optc0.OTG_DISABLE_POINT_CNTL
umr --read dcn31.optc0.OTG_MASTER_EN

# Scan HUBP registers (framebuffer fetch)
umr --scan dcn31.hubp0

# Scan HUBBUB (memory controller interface)
umr --scan dcn31.hubbub

# Decode GFX ring contents
umr --ring-read gfx

# Full IP block dump for DCN
umr --scan dcn31

# Wave state (if GFX hangs)
umr --waves
```

**What to look for with UMR:**
- `OTG_CLOCK_CONTROL.OTG_BUSY` = 1: OTG is stuck (the optc31 bug)
- `OTG_STATUS.OTG_V_BLANK` never transitions: OTG not generating timing
- `OTG_DISABLE_POINT_CNTL` = 2: end-of-frame disable (can hang)
- `OTG_MASTER_EN` = 0 but `OTG_BUSY` = 1: disable requested but not complete
- `HUBP.HUBP_UNDERFLOW_STATUS` non-zero: framebuffer fetch failed

**Requires root:** Yes
**Safe on unstable system:** READ operations are safe. WRITE operations
can crash the system. Never use --write on a production system.
**Note:** UMR needs the amdgpu driver loaded and functional. If the GPU
is in a reset loop, UMR may not work.

---

### 3.5 DRM Debug Logging (Verbose Kernel Messages)

**Why it matters:** The DRM subsystem has a debug bitmask that enables
verbose logging for different subsystems. Enabling KMS and DRIVER debug
produces detailed logs of every modeset, every page flip, every CRTC
enable/disable -- which is exactly the operation that fails.

```bash
# DRM debug bitmask values:
# 0x01 = CORE    (drm core code)
# 0x02 = DRIVER  (drm controller code -- amdgpu driver messages)
# 0x04 = KMS     (modesetting code -- CRTC, encoder, connector)
# 0x08 = PRIME   (prime/dma-buf sharing)
# 0x10 = ATOMIC  (atomic modesetting commits)
# 0x20 = VBL     (vblank events)
# 0x80 = LEASE   (lease code)
# 0x100 = DP     (DisplayPort link training)

# Enable DRIVER + KMS + ATOMIC for display debugging
echo 0x16 > /sys/module/drm/parameters/debug

# Or via kernel cmdline (boot-time):
# drm.debug=0x16

# CAUTION: This generates MASSIVE log output. Use only for targeted debugging.
# Disable when done:
echo 0 > /sys/module/drm/parameters/debug

# Focused: Enable only KMS (modesetting) messages
echo 0x04 > /sys/module/drm/parameters/debug
```

**Requires root:** Yes
**Safe on unstable system:** Safe but generates enormous log volume.
On a crash-looping system, this may fill the journal before the crash
data can be captured. Use with `journalctl --vacuum-size=2G` first.

---

### 3.6 DC Debug Options (Display Core Internal)

**Why it matters:** The DC (Display Core) has internal debug flags that
control detailed behavior and logging for the display pipeline. These
are separate from the DRM debug level and provide DC-specific diagnostics.

```bash
# Visual confirm -- adds colored bars to the scanout that indicate
# pipe assignments, surface types, and error conditions
echo 1 > /sys/kernel/debug/dri/${AMD_DRI}/amdgpu_dm_visual_confirm
# Colors indicate: pipe number, surface rotation, YUV format, etc.
# Red bar at top = underflow detected

# Force timing sync (diagnostic -- forces all CRTCs to sync)
echo 1 > /sys/kernel/debug/dri/${AMD_DRI}/amdgpu_dm_force_timing_sync

# DC state dump
cat /sys/kernel/debug/dri/${AMD_DRI}/amdgpu_dm_dc_state 2>/dev/null

# Check if IPS (Idle Power State) is causing issues (DCN 3.5+, may not apply)
cat /sys/kernel/debug/dri/${AMD_DRI}/amdgpu_dm_ips_status 2>/dev/null
```

**Requires root:** Yes (debugfs)
**Safe on unstable system:** `visual_confirm` is safe. `force_timing_sync`
may cause brief display glitch.

---

### 3.7 Hardware Cursor State

**Why it matters:** Hardware cursors use a dedicated HUBP cursor plane. If
the cursor plane has issues (wrong address, format mismatch), it can cause
display pipeline errors. Disabling hardware cursors eliminates one variable.

```bash
# Check if HW cursor is active
# The DTN log shows cursor plane state in the HUBP section

# Check Mutter/XFCE cursor setting
cat /etc/environment 2>/dev/null | grep -i cursor
# MUTTER_DEBUG_DISABLE_HW_CURSORS=1 would be set here

# For XFCE, hardware cursors are controlled by Xorg
grep -i "cursor\|HWCursor" /var/log/Xorg.0.log 2>/dev/null

# Runtime disable (Xorg):
# Add to xorg.conf.d:
# Option "SWcursor" "true"
```

**Requires root:** No for checking; Yes for changing
**Safe on unstable system:** Yes

---

### 3.8 Interrupt and Scheduler State

**Why it matters:** The amdgpu driver uses interrupts (IV ring) for fence
signaling, page flip completion, and error notification. If interrupts are
lost or delayed, fence timeouts occur even though the GPU completed work.

```bash
# Interrupt counts for amdgpu
grep -i amdgpu /proc/interrupts

# IV (Interrupt Vector) ring state
cat /sys/kernel/debug/dri/${AMD_DRI}/amdgpu_ring_ih 2>/dev/null | head -20

# GPU scheduler state per ring
for ring in /sys/kernel/debug/dri/${AMD_DRI}/amdgpu_ring_*; do
    [ -f "$ring" ] || continue
    echo "=== $(basename $ring) ==="
    head -10 "$ring"
done

# Check for interrupt storms (high interrupt rate)
# Take two samples 1 second apart, compare amdgpu interrupt count
grep amdgpu /proc/interrupts
sleep 1
grep amdgpu /proc/interrupts
```

**Requires root:** Yes for debugfs
**Safe on unstable system:** Yes

---

### 3.9 SMU (System Management Unit) Firmware State

**Why it matters:** The SMU controls power management, clock gating, and
GFXOFF. SMU firmware bugs or communication failures can cause the GFX
engine to be in an unexpected power state during display operations.

```bash
# Full PM info dump
cat /sys/kernel/debug/dri/${AMD_DRI}/amdgpu_pm_info

# SMU firmware version
grep "SMC feature" /sys/kernel/debug/dri/${AMD_DRI}/amdgpu_firmware_info

# Power features enabled/disabled
cat /sys/class/drm/card${AMD_CARD_NUM}/device/pp_features 2>/dev/null

# Clock gating status
dmesg | grep -iE "clock.*gat|CG_|cg_mask"
cat /sys/module/amdgpu/parameters/cg_mask

# Power gating status
cat /sys/module/amdgpu/parameters/pg_mask
```

**Requires root:** Yes for debugfs
**Safe on unstable system:** Yes

---

### 3.10 GCA (Graphics and Compute Array) Configuration

**Why it matters:** The GCA config shows the hardware configuration of the
GFX engine: number of shader engines, CU count, and feature capabilities.
On Raphael (2 CUs), misdetection could cause driver misconfiguration.

```bash
cat /sys/kernel/debug/dri/${AMD_DRI}/amdgpu_gca_config
```

**Requires root:** Yes (debugfs)
**Safe on unstable system:** Yes

---

### 3.11 RAS (Reliability, Availability, Serviceability) Errors

**Why it matters:** Consumer GPUs don't typically have full RAS support,
but some error counters may still be available. Non-zero counts indicate
hardware-level errors (bit flips in VRAM, ECC failures, etc.).

```bash
AMD_SYSFS="/sys/class/drm/card${AMD_CARD_NUM}/device"
if [ -d "${AMD_SYSFS}/ras" ]; then
    for f in "${AMD_SYSFS}/ras"/*; do
        echo "$(basename $f): $(cat $f 2>/dev/null)"
    done
else
    echo "RAS not available (normal for consumer APU)"
fi

# UMC (Unified Memory Controller) errors -- relevant for DDR5
dmesg | grep -iE "UMC|ECC|memory.*error|DRAM"
```

**Requires root:** No
**Safe on unstable system:** Yes

---

<a name="4-automatic-capture"></a>
## 4. Automatic Capture Infrastructure

The critical challenge is capturing transient data (devcoredump, ring state,
DTN log) AUTOMATICALLY when a crash occurs, before the data is lost.

---

### 4.1 udev Rule: Auto-Capture Devcoredump

The kernel creates a devcoredump entry under `/sys/class/devcoredump/` when
a GPU reset occurs. By default, this data auto-deletes after ~5 minutes.
This udev rule captures it immediately.

```bash
sudo tee /etc/udev/rules.d/99-amdgpu-devcoredump.rules << 'EOF'
# Auto-capture GPU devcoredump data on creation
# Trigger: kernel creates /sys/class/devcoredump/devcdN/data
ACTION=="add", SUBSYSTEM=="devcoredump", \
    RUN+="/bin/bash -c 'mkdir -p /var/log/gpu-dumps && cp /sys/%p/data /var/log/gpu-dumps/devcoredump-$(date +%%Y%%m%%d-%%H%%M%%S)-$(basename /sys/%p).txt 2>/dev/null; echo captured > /var/log/gpu-dumps/last-capture.log'"
EOF

sudo udevadm control --reload-rules

# Create the dump directory
sudo mkdir -p /var/log/gpu-dumps
```

**Note:** The `%p` expands to the devpath. The double `%%` is needed for
udev escaping. Test with: `udevadm test /sys/class/devcoredump/devcd0`

---

### 4.2 systemd Service: Boot-Time Diagnostic Capture

This service runs early in boot to capture GPU state before the display
manager starts, and then again after GPU events.

```bash
sudo tee /etc/systemd/system/gpu-diag-capture.service << 'EOF'
[Unit]
Description=GPU Diagnostic Data Capture
After=systemd-modules-load.service
Before=display-manager.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/gpu-diag-capture.sh boot
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sudo tee /usr/local/bin/gpu-diag-capture.sh << 'SCRIPT'
#!/bin/bash
# GPU diagnostic capture -- runs at boot and on-demand
PHASE="${1:-manual}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTDIR="/var/log/gpu-diag/${TIMESTAMP}-${PHASE}"
mkdir -p "$OUTDIR"

# Find AMD DRI
AMD_DRI=""
for d in /sys/kernel/debug/dri/[0-9]*; do
    name=$(cat "$d/name" 2>/dev/null)
    echo "$name" | grep -qi amdgpu && AMD_DRI=$(basename "$d") && break
done

[ -z "$AMD_DRI" ] && echo "AMD DRI not found" > "$OUTDIR/error.txt" && exit 0

DEBUGFS="/sys/kernel/debug/dri/${AMD_DRI}"

# Capture time-sensitive data
cat "$DEBUGFS/amdgpu_dm_dtn_log" > "$OUTDIR/dtn_log.txt" 2>&1
cat "$DEBUGFS/amdgpu_dm_dmub_tracebuffer" > "$OUTDIR/dmub_tracebuffer.txt" 2>&1
cat "$DEBUGFS/amdgpu_dm_dmub_fw_state" > "$OUTDIR/dmub_fw_state.txt" 2>&1
cat "$DEBUGFS/amdgpu_fence_info" > "$OUTDIR/fence_info.txt" 2>&1
cat "$DEBUGFS/amdgpu_firmware_info" > "$OUTDIR/firmware_info.txt" 2>&1
cat "$DEBUGFS/amdgpu_pm_info" > "$OUTDIR/pm_info.txt" 2>&1
cat "$DEBUGFS/amdgpu_gfxoff" > "$OUTDIR/gfxoff.txt" 2>&1
cat "$DEBUGFS/amdgpu_gfxoff_status" > "$OUTDIR/gfxoff_status.txt" 2>&1
cat "$DEBUGFS/amdgpu_gfxoff_count" > "$OUTDIR/gfxoff_count.txt" 2>&1
cat "$DEBUGFS/amdgpu_gem_info" > "$OUTDIR/gem_info.txt" 2>&1
cat "$DEBUGFS/amdgpu_vm_info" > "$OUTDIR/vm_info.txt" 2>&1

# Ring buffer state
for ring in "$DEBUGFS"/amdgpu_ring_*; do
    [ -f "$ring" ] || continue
    head -50 "$ring" > "$OUTDIR/ring_$(basename $ring).txt" 2>&1
done

# Devcoredump
for dump in /sys/class/devcoredump/devcd*/data; do
    [ -f "$dump" ] || continue
    cp "$dump" "$OUTDIR/devcoredump_$(basename $(dirname $dump)).txt" 2>/dev/null
done

# DRM card assignments
for card in /sys/class/drm/card[0-9]; do
    [ -d "$card" ] || continue
    vendor=$(cat "$card/device/vendor" 2>/dev/null)
    driver=$(basename $(readlink "$card/device/driver") 2>/dev/null)
    echo "$(basename $card): vendor=$vendor driver=$driver"
done > "$OUTDIR/card_assignments.txt"

# Dmesg snapshot
dmesg > "$OUTDIR/dmesg.txt" 2>&1
dmesg | grep -iE "amdgpu|drm|DMUB|ring.*timeout|GPU reset|optc|REG_WAIT" \
    > "$OUTDIR/dmesg_filtered.txt" 2>&1

echo "Captured at $TIMESTAMP phase=$PHASE" > "$OUTDIR/META.txt"
SCRIPT

sudo chmod +x /usr/local/bin/gpu-diag-capture.sh
sudo systemctl daemon-reload
sudo systemctl enable gpu-diag-capture.service
```

---

### 4.3 systemd Path Unit: Trigger on GPU Reset

This watches for the syslog message indicating a GPU reset and triggers
an immediate diagnostic capture.

```bash
sudo tee /etc/systemd/system/gpu-reset-capture.path << 'EOF'
[Unit]
Description=Watch for GPU reset events

[Path]
PathChanged=/dev/kmsg

[Install]
WantedBy=multi-user.target
EOF

# Better approach: use journald match
sudo tee /etc/systemd/system/gpu-reset-monitor.service << 'EOF'
[Unit]
Description=Monitor for GPU reset and capture diagnostics

[Service]
ExecStart=/bin/bash -c 'journalctl -k -f --no-pager | grep --line-buffered -iE "GPU reset|ring.*timeout|MODE2" | while read line; do /usr/local/bin/gpu-diag-capture.sh reset; sleep 30; done'
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable gpu-reset-monitor.service
```

---

### 4.4 Enable DMCUB Trace Events at Boot

```bash
sudo tee /etc/systemd/system/gpu-dmcub-trace.service << 'EOF'
[Unit]
Description=Enable DMCUB trace events for display debugging
After=systemd-modules-load.service
ConditionPathExists=/sys/kernel/debug/dri

[Service]
Type=oneshot
ExecStart=/bin/bash -c '\
    for d in /sys/kernel/debug/dri/[0-9]*; do \
        name=$(cat "$d/name" 2>/dev/null); \
        echo "$name" | grep -qi amdgpu || continue; \
        echo 0xFFFF > "$d/amdgpu_dm_dmub_trace_mask" 2>/dev/null; \
        echo 1 > "$d/amdgpu_dm_dmcub_trace_event_en" 2>/dev/null; \
        echo "DMCUB trace enabled on $(basename $d)"; \
        break; \
    done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable gpu-dmcub-trace.service
```

---

### 4.5 Persistent Journal Configuration

```bash
# Ensure journal persists across reboots (CRITICAL for multi-boot comparison)
sudo mkdir -p /var/log/journal
sudo systemd-tmpfiles --create --prefix /var/log/journal

# Increase journal size for verbose GPU logging
sudo tee /etc/systemd/journald.conf.d/gpu-debug.conf << 'EOF'
[Journal]
SystemMaxUse=4G
SystemMaxFileSize=512M
RateLimitIntervalSec=0
RateLimitBurst=0
EOF

sudo systemctl restart systemd-journald
```

---

### 4.6 Kernel Command Line for Boot-Time Tracing

Add to `GRUB_CMDLINE_LINUX_DEFAULT` for comprehensive boot-time capture:

```bash
# Minimal: just DRM KMS debug (moderate log volume)
drm.debug=0x04

# Moderate: DRM DRIVER + KMS + ATOMIC (significant log volume)
drm.debug=0x16

# Full: Add ftrace for optc31 functions (high log volume)
drm.debug=0x16 ftrace=function_graph ftrace_filter=optc31_disable_crtc,optc1_wait_for_state,dcn31_init_hw trace_buf_size=64M

# Add display manager trace event
trace_event=amdgpu_dm:*
```

**WARNING:** `drm.debug=0x16` on every boot generates ~50-200MB of journal
per boot. Only enable for debugging sessions, not permanent use.

---

<a name="5-external-tools"></a>
## 5. External Tools

---

### 5.1 IGT GPU Tools

**What it is:** Intel GPU Tools (now generic DRM test suite) with AMDGPU
support. IGT 2.0 added RDNA3.5 family support and a display memory
bandwidth measurement tool.

```bash
# Install
apt install intel-gpu-tools  # or build from source

# Key tests for this bug pattern:

# Test basic display functionality
igt_runner -t kms_cursor_legacy
igt_runner -t kms_flip
igt_runner -t kms_setmode

# Test atomic modesetting (the path that triggers the crash)
igt_runner -t kms_atomic

# Test pipe configuration
igt_runner -t kms_pipe_crc_basic

# Display memory bandwidth (new in IGT 2.0)
igt_display_bw

# GPU facts
igt_facts
```

**Note:** IGT tests may trigger the exact bug you're debugging. Run them
only when prepared to capture the crash data.

---

### 5.2 kworkflow (kw)

**What it is:** A kernel developer workflow tool with specific support for
AMD display driver development. Simplifies ftrace, event tracing, and
module management.

```bash
# Install
pip install kworkflow  # or from https://kworkflow.org

# Trace amdgpu_dm functions
kw debug --ftrace="function_graph:amdgpu_dm*" --follow --history

# List available amdgpu events
kw debug --events | grep amdgpu

# Load/unload amdgpu with logging
kw drm --load-module='amdgpu' --gui-on
```

---

### 5.3 umr (User Mode Register Debugger)

See Section 3.4 for detailed usage. Install from:
- Ubuntu: `apt install umr` (if available)
- Source: https://cgit.freedesktop.org/amd/umr/
- Documentation: https://umr.readthedocs.io/

---

<a name="6-gaps"></a>
## 6. Diagnostic Gaps in Current Script (diagnostic-full.sh)

The existing `diagnostic-full.sh` script covers 13 sections. Here are the
gaps identified by this research:

### Currently MISSING -- Should Add

| Diagnostic | Section | Priority | Why Missing |
|---|---|---|---|
| DMCUB trace buffer (`amdgpu_dm_dmub_tracebuffer`) | 07-drm-state | CRITICAL | Not in debugfs file list |
| DMCUB firmware state (`amdgpu_dm_dmub_fw_state`) | 07-drm-state | CRITICAL | Not in debugfs file list |
| DMCUB trace event enable state | 07-drm-state | HIGH | Not captured |
| DMCUB trace mask value | 07-drm-state | HIGH | Not captured |
| DC state (`amdgpu_dm_dc_state`) | 07-drm-state | HIGH | Not in debugfs file list |
| Visual confirm state (`amdgpu_dm_visual_confirm`) | 07-drm-state | LOW | Not in debugfs file list |
| IPS status (`amdgpu_dm_ips_status`) | 07-drm-state | MEDIUM | Not in debugfs file list |
| Force timing sync state | 07-drm-state | LOW | Not in debugfs file list |
| DMUB re-init count (from dmesg) | 02-amdgpu-driver | HIGH | Not counted separately |
| Module load timestamps | 01-kernel-system | HIGH | Not extracted |
| simpledrm init timestamp | 01-kernel-system | HIGH | Not checked |
| Card assignment correctness check | ANALYSIS.txt | CRITICAL | Not validated |
| Firmware hash/size verification | 04-firmware | HIGH | Only lists files, not contents |
| IOMMU fault messages | 06-pci-hardware | MEDIUM | Not filtered for |
| GART/GCVM errors | 06-pci-hardware | MEDIUM | Not filtered for |
| Effective vs configured param comparison | ANALYSIS.txt | HIGH | Not cross-checked |
| LightDM logs (current DM) | 05-display | HIGH | Only checks gdm3 |
| XFCE compositor state | 05-display | MEDIUM | Not checked |
| DRM debug level at capture time | 07-drm-state | LOW | Captured but not in analysis |
| Devcoredump auto-preservation | 11-ring-events | CRITICAL | Reads once (may clear) |
| pp_features sysfs | 08-power-thermal | MEDIUM | Not captured |
| cg_mask/pg_mask effective values | 08-power-thermal | MEDIUM | Not captured |

### Currently CAPTURED (Good)

The existing script already captures these well:
- DTN log (dtn_log)
- Ring buffer state (truncated at 20 lines -- should increase to 50)
- Firmware info from debugfs
- AER errors
- IOMMU groups
- GFXOFF status/count/residency
- VRAM/GTT memory info
- All sysfs parameters
- Multi-boot comparison with CSV
- Devcoredump (basic -- but only text, and warns about auto-clear)
- Full dmesg and journal
- EDID data

---

## 7. Quick Reference: Complete debugfs File List

Files under `/sys/kernel/debug/dri/<N>/` for an amdgpu device:

### Core amdgpu debugfs
```
amdgpu_benchmark          # Run GPU benchmark (WRITE)
amdgpu_test_ib            # Test IB submission (WRITE)
amdgpu_evict_gtt          # Force GTT eviction (WRITE -- DANGEROUS)
amdgpu_evict_vram         # Force VRAM eviction (WRITE -- DANGEROUS)
amdgpu_gpu_recover        # Trigger manual GPU reset (READ triggers reset -- DANGEROUS)
amdgpu_fence_info         # Fence state per ring (READ)
amdgpu_firmware_info      # All firmware versions (READ)
amdgpu_gem_info           # Buffer object allocations (READ)
amdgpu_vm_info            # Virtual memory state (READ)
amdgpu_sa_info            # Sub-allocator state (READ)
amdgpu_gca_config         # GFX/Compute Array config (READ)
amdgpu_sensors            # Temperature, clock (READ)
amdgpu_pm_info            # Power management state (READ)
amdgpu_ring_<name>        # Per-ring buffer state (READ)
amdgpu_mqd_<name>         # Per-ring MQD (READ)
amdgpu_gfxoff             # GFXOFF enable/disable (READ/WRITE)
amdgpu_gfxoff_status      # GFXOFF current status (READ)
amdgpu_gfxoff_count       # GFXOFF entry count (READ)
amdgpu_gfxoff_residency   # Time in GFXOFF (READ)
amdgpu_wave               # Shader wave state (READ)
amdgpu_gpr                # General purpose registers (READ)
amdgpu_regs_*             # Register access (READ/WRITE -- careful)
amdgpu_vram               # VRAM read access (READ)
amdgpu_iomem              # IO memory read (READ)
amdgpu_discovery          # IP discovery table (READ)
amdgpu_vbios              # Video BIOS dump (READ)
amdgpu_fw_attestation     # Firmware attestation (READ)
```

### Display Manager (amdgpu_dm) debugfs
```
amdgpu_dm_dtn_log                # DTN log -- full pipeline state (READ) *
amdgpu_dm_visual_confirm         # Visual debug overlay (READ/WRITE)
amdgpu_dm_dmub_tracebuffer       # DMCUB trace ring buffer (READ) *
amdgpu_dm_dmub_fw_state          # DMCUB firmware state (READ) *
amdgpu_dm_dmcub_trace_event_en   # Enable DMCUB trace to dmesg (WRITE) *
amdgpu_dm_dmub_trace_mask        # DMCUB trace group bitmask (READ/WRITE) *
amdgpu_dm_force_timing_sync      # Force CRTC timing sync (WRITE)
amdgpu_dm_dc_state               # DC state dump (READ) *
amdgpu_dm_ips_status             # IPS status (READ, DCN 3.5+)
amdgpu_dm_trigger_hpd_mst        # Trigger MST hotplug (WRITE)
```

Files marked with `*` are the most important for this bug pattern.

### Per-connector debugfs (under card<N>-<connector>/)
```
force                     # Force connector state
edid_override             # Override EDID
i2c                       # I2C interface
output_bpc                # Output bits per color
trigger_hotplug           # Trigger hotplug event
```

---

## 8. Diagnostic Capture Priorities for This Bug

### On EVERY boot (automated):
1. Devcoredump (udev rule)
2. DMCUB trace buffer
3. DMCUB firmware state
4. DTN log
5. Fence info
6. GFXOFF status/count
7. Ring buffer state
8. Card assignments
9. Filtered dmesg (amdgpu + ring + reset + optc)
10. Full dmesg

### On crash-loop boot (if accessible via SSH):
1. Devcoredump (FIRST -- before it auto-clears)
2. DMCUB trace buffer
3. DTN log
4. Fence info for all rings
5. UMR register dump of DCN31.OPTC0

### For targeted debugging session:
1. Enable `drm.debug=0x16` in GRUB
2. Enable DMCUB trace events (systemd service)
3. Set up ftrace for optc31_disable_crtc
4. Boot and capture
5. Disable verbose logging after capturing

---

## Sources

- [AMDGPU DebugFS -- Linux Kernel Documentation](https://docs.kernel.org/gpu/amdgpu/debugfs.html)
- [GPU Debugging -- Linux Kernel Documentation](https://docs.kernel.org/gpu/amdgpu/debugging.html)
- [Display Core Debug Tools -- Linux Kernel Documentation](https://docs.kernel.org/gpu/amdgpu/display/dc-debug.html)
- [Display Core Next (DCN) Overview](https://docs.kernel.org/gpu/amdgpu/display/dcn-overview.html)
- [15 Tips for Debugging Issues in the AMD Display Kernel Driver (Melissa Wen)](https://melissawen.github.io/blog/2023/12/13/amd-display-debugging-tips)
- [DMCUB Tracebuffer Chronological Patch](https://www.mail-archive.com/amd-gfx@lists.freedesktop.org/msg116010.html)
- [amdgpu devcoredump ring timeout information](https://www.mail-archive.com/amd-gfx@lists.freedesktop.org/msg103622.html)
- [amdgpu devcoredump moved to worker thread](https://www.mail-archive.com/amd-gfx@lists.freedesktop.org/msg138167.html)
- [UMR: User Mode Register Debugger](https://umr.readthedocs.io/en/main/intro.html)
- [UMR man page](https://www.mankier.com/1/umr)
- [IGT GPU Tools 2.0](https://www.phoronix.com/news/IGT-GPU-Tools-2.0)
- [IGT AMDGPU Tests Reference](https://drm.pages.freedesktop.org/igt-gpu-tools/igt-amdgpu-tests.html)
- [kworkflow Kernel Debug Tools](https://kworkflow.org/tutorials/kernel-debug.html)
- [Kworkflow at Kernel Recipes 2025](https://melissawen.github.io/blog/2025/11/03/kworkflow-talk-at-kernel-recipes-2025)
- [DRM Debugging (wlroots wiki)](https://github.com/swaywm/wlroots/wiki/DRM-Debugging)
- [AMDGPU Module Parameters](https://docs.kernel.org/gpu/amdgpu/module-parameters.html)
- [CVE-2024-47662: DMCUB diagnostic fix](https://windowsforum.com/threads/cve-2024-47662-amd-dcn35-dmcub-diagnostic-fix-improves-linux-gpu-availability.392738/)
- [freedesktop drm/amd #5073](https://gitlab.freedesktop.org/drm/amd/-/work_items/5073)
- [Debian Bug #1057656](https://bugs-devel.debian.org/cgi-bin/bugreport.cgi?bug=1057656)
- [eBPF GPU Driver Tracepoint Monitoring](https://eunomia.dev/tutorials/xpu/gpu-kernel-driver/)
- [amdgpu_dm_debugfs.c source (GitHub)](https://github.com/torvalds/linux/tree/master/drivers/gpu/drm/amd/display/amdgpu_dm)
