# Comprehensive Mitigation Research: AMD Raphael iGPU DCN Stall + GFX Ring Crash Loop

**Date:** 2026-03-29
**Hardware:** AMD Ryzen 9 7950X (Raphael, DCN 3.1.5, GC 10.3.6, 2 CUs) + NVIDIA RTX 4090 (headless)
**Board:** ASUS ROG Crosshair X670E Hero, BIOS 3603 (AGESA 1.3.0.0a)
**Current state:** DMCUB firmware 0.0.15.0 (critically outdated), kernel 6.17 HWE, Ubuntu 24.04

**CONFIRMED:** With `AccelMethod "none"` + XFCE + no NVIDIA, system is STABLE (0 ring timeouts). The optc31 timeout still fires once but does not cascade.

---

## The Two-Condition Crash Model

The crash loop requires BOTH conditions simultaneously:

1. **Condition 1 -- DCN stall:** `optc31_disable_crtc` REG_WAIT timeout during EFI-to-amdgpu handoff (fires at ~6s)
2. **Condition 2 -- GFX ring pressure:** Compositor submits GL commands to the GFX ring, which hangs on the stalled DCN pipeline

**MODE2 reset** (default on Raphael) resets only GC/SDMA via GCHUB. The DCN goes through DCHUB and is **untouched**. So after each reset, the compositor immediately re-submits commands to a still-broken DCN, creating an infinite loop.

**Fix strategy:** Eliminate Condition 1 (firmware + kernel patches), OR eliminate Condition 2 (zero-GL compositor), OR mitigate the loop (better reset method, longer timeouts).

---

## 1. FIRMWARE FIXES

### 1.1 Which DMCUB Firmware Versions Fix the optc31 Timeout?

The DMCUB (Display Microcontroller Unit B) manages display state transitions including the CRTC disable/enable sequence. The `REG_WAIT` macro can offload register polls to DMCUB via `dmub_reg_wait_done_pack()`. If DMCUB firmware has a state machine bug, the offload fails silently and the CPU-side poll times out.

**Critical fix:** [Debian Bug #1057656](https://bugs-devel.debian.org/cgi-bin/bugreport.cgi?bug=1057656) identified a broken `dcn_3_1_5_dmcub.bin` that caused display failure on Raphael. The fix was a partial revert of problematic DMCUB updates (upstream commit `d3f66064cf43`), landing in linux-firmware tag `20240709` with DMCUB version **0.0.224.0**.

**Later fix:** [kernel-firmware MR #587](https://gitlab.com/kernel-firmware/linux-firmware/-/merge_requests/587) ("Update DMCUB fw for DCN401 & DCN315") specifically targets DCN 3.1.5 (AMD naming: DCN315). This landed in firmware tags post-`20260221`.

| DMCUB Version | Status | Rationale |
|---------------|--------|-----------|
| 0.0.15.0 (current) | **CRITICAL: KNOWN BAD** | Predates ALL fixes by years |
| 0.0.191.0 (Ubuntu stock 20240318) | **KNOWN BAD** | Pre-Debian-fix |
| **0.0.224.0** (tag 20240709) | **KNOWN GOOD (minimum)** | Debian #1057656 fix |
| **0.0.255.0** (tag 20250305) | **KNOWN GOOD (recommended)** | Last 0.0.x series, widest testing |
| 0.1.14.0 (tag 20250613) | **KNOWN BAD** | [NixOS #418212](https://github.com/nixos/nixpkgs/issues/418212): DMCUB load failure |
| 0.1.40.0+ (tag 20260309) | **LIKELY GOOD** | Post-MR#587, post-regression-fix |

**Recommendation:** Target **0.0.255.0** (conservative) or **0.1.40.0+** (latest stable). Avoid 0.1.14.0.

### 1.2 Getting linux-firmware >= 20240709 on Ubuntu 24.04

**Option A: Check if Ubuntu SRU already delivered it**

Ubuntu Noble SRU `0ubuntu2.22` (January 2026) changelog mentions "AMD GPU PSP/GC/DMCUB firmware updates" but never explicitly names `dcn_3_1_5_dmcub.bin`. The current system loads 0.0.15.0, suggesting either the SRU did not include DCN 3.1.5 DMCUB, or the `.bin`/`.bin.zst` conflict prevented loading, or the initramfs was not rebuilt.

```bash
# Step 1: Check what version the package actually contains
apt policy linux-firmware
# Step 2: Check what the kernel actually loaded
dmesg | grep "DMUB firmware.*version"
# Step 3: Compare the packaged .bin.zst vs manual .bin
ls -la /lib/firmware/amdgpu/dcn_3_1_5_dmcub.bin*
```

**Option B: Manual firmware extraction from a newer package (SAFEST)**

```bash
# Download without installing
cd /tmp
apt-get download linux-firmware   # Gets latest from noble-updates

# Extract just the DMCUB firmware
mkdir -p /tmp/fw-extract
dpkg-deb -x linux-firmware_*.deb /tmp/fw-extract/
ls -la /tmp/fw-extract/lib/firmware/amdgpu/dcn_3_1_5_dmcub*
```

**Option C: Manual firmware from linux-firmware git (PRECISE VERSION CONTROL)**

```bash
cd /tmp
git clone --depth 1 --branch 20250305 \
  https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git

# Copy specific files
sudo cp linux-firmware/amdgpu/dcn_3_1_5_dmcub.bin /lib/firmware/amdgpu/

# CRITICAL: Compress to .bin.zst and remove bare .bin
# Ubuntu 24.04 has CONFIG_FW_LOADER_COMPRESS_ZSTD=y -- kernel loads .bin.zst FIRST
sudo zstd -f /lib/firmware/amdgpu/dcn_3_1_5_dmcub.bin \
     -o /lib/firmware/amdgpu/dcn_3_1_5_dmcub.bin.zst
sudo rm -f /lib/firmware/amdgpu/dcn_3_1_5_dmcub.bin

# Also update PSP firmware (psp_13_0_5_ta.bin has 17 updates)
for f in psp_13_0_5_ta psp_13_0_5_asd psp_13_0_5_toc; do
    sudo cp linux-firmware/amdgpu/${f}.bin /lib/firmware/amdgpu/
    sudo zstd -f /lib/firmware/amdgpu/${f}.bin -o /lib/firmware/amdgpu/${f}.bin.zst
    sudo rm -f /lib/firmware/amdgpu/${f}.bin
done

# Rebuild initramfs
sudo update-initramfs -u -k all
```

**Option D: Ubuntu noble-proposed (BETA SRU)**

```bash
# Temporarily enable noble-proposed
sudo add-apt-repository --enable-source \
  "deb http://archive.ubuntu.com/ubuntu noble-proposed main restricted"
sudo apt update
apt policy linux-firmware   # Check version -- 0ubuntu2.25 is in proposed
sudo apt install linux-firmware
# Remove proposed repo after install
sudo add-apt-repository --remove \
  "deb http://archive.ubuntu.com/ubuntu noble-proposed main restricted"
sudo update-initramfs -u -k all
```

**Will updating just the DMCUB file break other firmware?** No. Each firmware blob is loaded independently by the kernel driver. Updating `dcn_3_1_5_dmcub.bin.zst` only affects the DCN 3.1.5 display microcontroller. Other firmware (GC, SDMA, VCN, PSP) remains unchanged. The only risk is if the new DMCUB version is incompatible with the kernel's DMCUB interface -- this is why 0.0.255.0 (same major/minor as kernel expects) is safer than 0.1.x.

### 1.3 fwupd / LVFS for DMCUB Firmware

**Status: NOT AVAILABLE for DMCUB.**

fwupd 1.9.6 added support for AMD GPU firmware updates, but this targets the **IFWI (Integrated Firmware Image)** on discrete Navi 3x GPUs. DMCUB firmware for integrated APUs is NOT delivered through fwupd/LVFS. DMCUB updates come exclusively through the `linux-firmware` package and are loaded by the kernel driver at boot time.

The DMCUB firmware is NOT stored in persistent flash on the APU -- it is loaded into DMCUB SRAM from the filesystem on every boot. This means:
- No risk of bricking the hardware by updating firmware
- The firmware can be tested by simply rebooting with a different file
- Rollback is trivial: restore the old `.bin.zst` file

---

## 2. KERNEL PARAMETER OPTIMIZATION

### 2.1 amdgpu.seamless (CRTC Disable Bypass)

**What it does:** Controls whether amdgpu adopts BIOS-configured display pipes seamlessly (keeping them running) or tears them down during init.

| Value | Behavior | Effect on optc31 Timeout |
|-------|----------|--------------------------|
| `-1` (auto, default) | Enabled if DCN >= 3.0 AND APU = true | On Raphael (DCN 3.1.5 APU), seamless is ON by default |
| `0` | Force full pipe teardown | **Executes** optc31_disable_crtc -- triggers the timeout |
| `1` | Force seamless boot | **Skips** the CRTC disable path entirely on kernel >= 6.13 |

**Analysis:**
- With kernel 6.17 HWE, `seamless=1` should invoke commit `391cea4fff00` ("skip disable CRTC on seamless bootup"), completely bypassing the optc31 path.
- If seamless is already auto-enabled (which it should be on Raphael), setting `seamless=1` explicitly forces it, eliminating ambiguity.
- With OLD firmware (0.0.15.0), seamless may still fail because DMCUB must set `optimized_init_done` correctly for seamless adoption. Broken DMCUB may set this flag incorrectly.
- **With NEW firmware + kernel 6.17:** `seamless=1` is the optimal first line of defense.

**Recommendation:** `amdgpu.seamless=1` with new firmware. Test `seamless=0` as diagnostic (should reliably trigger the timeout if firmware is still broken).

### 2.2 amdgpu.dcdebugmask (Display Core Debug Mask)

The `DC_DEBUG_MASK` enum from `drivers/gpu/drm/amd/include/amd_shared.h`:

| Bit | Hex | Constant | Effect | Relevance |
|-----|-----|----------|--------|-----------|
| 0 | 0x01 | `DC_DISABLE_PIPE_SPLIT` | Disable pipe splitting (single pipe mode) | LOW -- reduces DCN complexity |
| 1 | 0x02 | `DC_DISABLE_STUTTER` | Disable memory self-refresh / stutter mode | MEDIUM -- reduces DCN state transitions |
| 2 | 0x04 | `DC_DISABLE_DSC` | Disable Display Stream Compression | LOW -- only relevant for DSC displays |
| 3 | 0x08 | `DC_DISABLE_CLOCK_GATING` | **Disable DCN clock gating** -- keeps OPTC registers powered | **HIGH** -- prevents register access timeout |
| 4 | 0x10 | `DC_DISABLE_PSR` | **Disable Panel Self Refresh** (PSR and PSR-SU) | MEDIUM -- reduces DMCUB state machine load |
| 5 | 0x20 | `DC_FORCE_SUBVP_MCLK_SWITCH` | Force SubVP memory clock switching | LOW |

**Analysis of key combinations:**

| Mask | Bits Disabled | Use Case |
|------|--------------|----------|
| `0x10` | PSR only | **Conservative** -- documented fix for flickering |
| `0x08` | Clock gating only | **Targeted** -- keeps OPTC registers accessible during handoff |
| `0x18` | Clock gating + PSR | **Aggressive** -- maximum DCN stability, higher power consumption |
| `0x1A` | Clock gating + PSR + stutter | **Maximum** -- eliminates all DCN power state transitions |
| `0x1F` | Everything | **Nuclear** -- disables all DC optimizations |

**Recommendation:**
- Start with `0x10` (PSR off) -- minimal impact, proven fix for Raphael flickering.
- If optc31 timeout persists: escalate to `0x18` (clock gating + PSR off).
- If still failing: try `0x1A` (add stutter disable).
- The clock gating disable (0x08) is theoretically the most relevant to the REG_WAIT timeout because it keeps the OTG_CLOCK_CONTROL register powered and accessible.

### 2.3 amdgpu.lockup_timeout

**Format:** Single integer (applies to all rings) or comma-separated per-ring values.

| Value | Effect |
|-------|--------|
| `10000` (default for non-compute) | 10 seconds before ring timeout triggers |
| `60000` (default for compute) | 60 seconds for compute rings |
| `30000` | 30 seconds -- gives DMCUB more time to initialize |
| `0` | **Disables timeout entirely** -- ring never times out, system hangs instead of resetting |

**Analysis:**
- The optc31 timeout fires at ~6s. If DMCUB needs extra time to complete initialization, a longer lockup_timeout prevents premature ring timeouts during the slow init period.
- Setting `30000` (30s) gives 3x headroom over the default 10s.
- Setting `0` is useful for diagnostics (confirms whether the ring eventually completes or is truly hung) but should never be used in production -- the system will hard-lock instead of resetting.
- **Per-ring syntax:** `lockup_timeout=30000,30000,30000,60000` (GFX, SDMA, VCN, compute). The exact ring ordering depends on kernel version.

**Recommendation:** `amdgpu.lockup_timeout=30000` during testing. Revert to default once firmware/kernel fix eliminates the root cause.

### 2.4 amdgpu.ppfeaturemask

**Complete PP_FEATURE_MASK bit decode** from `amd_shared.h`:

| Bit | Hex | Name | Purpose |
|-----|-----|------|---------|
| 0 | 0x00001 | PP_SCLK_DPM_MASK | Shader clock dynamic power management |
| 1 | 0x00002 | PP_MCLK_DPM_MASK | Memory clock DPM |
| 2 | 0x00004 | PP_PCIE_DPM_MASK | PCIe link speed DPM |
| 3 | 0x00008 | PP_SCLK_DEEP_SLEEP_MASK | Shader clock deep sleep |
| 4 | 0x00010 | PP_POWER_CONTAINMENT_MASK | TDP power containment |
| 5 | 0x00020 | PP_UVD_HANDSHAKE_MASK | UVD/VCN handshake |
| 6 | 0x00040 | PP_SMC_VOLTAGE_CONTROL_MASK | SMC voltage control |
| 7 | 0x00080 | PP_VBI_TIME_SUPPORT_MASK | VBI time support |
| 8 | 0x00100 | PP_ULV_MASK | Ultra-low voltage |
| 9 | 0x00200 | PP_ENABLE_GFX_CG_THRU_SMU | GFX clock gating via SMU |
| 10 | 0x00400 | PP_CLOCK_STRETCH_MASK | Clock stretching |
| 11 | 0x00800 | PP_OD_FUZZY_FAN_CONTROL_MASK | OverDrive fuzzy fan control |
| 12 | 0x01000 | PP_SOCCLK_DPM_MASK | SoC clock DPM |
| 13 | 0x02000 | PP_DCEFCLK_DPM_MASK | Display engine clock DPM |
| 14 | 0x04000 | PP_OVERDRIVE_MASK | OverDrive / manual clock control |
| **15** | **0x08000** | **PP_GFXOFF_MASK** | **GFXOFF -- powers off GFX engine when idle** |
| 16 | 0x10000 | PP_ACG_MASK | Adaptive clock/voltage |
| **17** | **0x20000** | **PP_STUTTER_MODE** | **Stutter mode -- display self-refresh** |
| 18 | 0x40000 | PP_AVFS_MASK | Adaptive voltage/frequency scaling |
| 19 | 0x80000 | PP_GFX_DCS_MASK | GFX dynamic clock switching |

**Decoding current values:**

- `0xffffffff` = ALL features enabled (default for some GPUs)
- `0xfffd7fff` = Bits 15 and 17 cleared = **GFXOFF disabled + stutter disabled**
- `0xfff7bfff` (current running value) = Bits 14 and 19 cleared = **overdrive disabled + GFX_DCS disabled**

```
0xfffd7fff = 1111 1111 1111 1101 0111 1111 1111 1111
                                ^              ^
                           bit 17 (off)   bit 15 (off)
Disabled: PP_STUTTER_MODE (0x20000) + PP_GFXOFF_MASK (0x8000)
GFXOFF = OFF, STUTTER = OFF  <-- CORRECT for stability

0xfff7bfff = 1111 1111 1111 0111 1011 1111 1111 1111
                             ^     ^
                        bit 19   bit 14
                        (off)    (off)
Disabled: PP_GFX_DCS_MASK (0x80000) + PP_OVERDRIVE_MASK (0x4000)
GFXOFF = ON, STUTTER = ON  <-- WRONG: both still enabled!
```

**This is a critical finding.** The running system has `0xfff7bfff` which keeps GFXOFF and stutter mode **enabled**. The documented recommendation of `0xfffd7fff` disables GFXOFF (bit 15) and stutter mode (bit 17). These are completely different masks with completely different effects. The current running value disables overdrive and GFX_DCS (irrelevant to display stability), while leaving the two most dangerous power management features active.

**Recommendation:** `amdgpu.ppfeaturemask=0xfffd7fff` -- this disables GFXOFF (bit 15) and stutter mode (bit 17), both of which cause GFX engine power state transitions that can interact badly with DCN stalls.

### 2.5 amdgpu.sg_display

**What it does:** Controls scatter/gather (S/G) DMA for display framebuffers on APUs.

| Value | Behavior |
|-------|----------|
| `1` (default for APUs) | Display framebuffers allocated from GTT via GART scatter/gather DMA |
| `0` | Force contiguous VRAM allocation for display framebuffers |
| `-1` (driver default) | Auto-detect based on hardware capability |

**Why `sg_display=0` is correct for Raphael:** AMD re-enabled scatter/gather for all APUs by default, but Raphael has documented issues with S/G display causing flickering, white screens, and display corruption ([Phoronix](https://www.phoronix.com/news/AMD-Scatter-Gather-Re-Enabled)). The [freedesktop #5073](https://gitlab.freedesktop.org/drm/amd/-/work_items/5073) reporter notes that `sg_display=0` did NOT fix the optc31 timeout specifically, but it eliminates a secondary failure mode (GART/TLB inconsistency during EFI handoff).

**Recommendation:** `amdgpu.sg_display=0` -- eliminates a contributing factor even if it doesn't fix the root cause.

### 2.6 amdgpu.reset_method

| Value | Method | What It Resets | APU Support |
|-------|--------|---------------|-------------|
| `-1` (auto) | Driver chooses (MODE2 on Raphael) | GFX + SDMA only | Default |
| `1` | MODE0 (full ASIC) | **ALL IP blocks including DCN/DCHUB** | **UNTESTED on Raphael APU** |
| `2` | MODE1 | MMHUB (VCN, JPEG, VPE) | Not useful here |
| `3` | MODE2 | GFX + SDMA via GCHUB | Default on Raphael |
| `4` | BACO (Bus Active Chip Off) | Full power cycle | **NOT supported on APUs** (no separate power domain) |

**The critical insight:** MODE2 is why the crash loop is infinite. It resets GFX/SDMA but NOT DCN. MODE0 (full ASIC reset) resets ALL IP blocks including DCN/DCHUB, which *could* break the crash loop by actually fixing the stalled DCN.

**Risks of MODE0 on Raphael APU:**
- VRAM contents are lost (display goes black during reset)
- All GPU state is re-initialized (longer reset time)
- APU-specific concern: the iGPU shares the memory controller with the CPU. A full ASIC reset on an APU may have different behavior than on a discrete GPU.
- No community reports of MODE0 on Raphael APU found in research.

**Recommendation:** `amdgpu.reset_method=1` (MODE0) has been **TESTED AND IS NOT SUPPORTED** on Raphael APU. Kernel 6.17 rejects it: *"Specified reset method:1 isn't supported, using AUTO instead."* MODE0 remains the only reset method that could theoretically fix a stalled DCN, but it cannot be forced on this hardware. The system will always fall back to MODE2 (AUTO).

### 2.7 initcall_blacklist=simpledrm_platform_driver_init

**What it does:** Prevents simpledrm from registering as a DRM device at early boot. simpledrm is compiled into the kernel (not a module) and takes over the EFI GOP framebuffer, claiming `card0` before any GPU driver loads.

**Why it matters:** In every diagnostic boot, `card0 = NVIDIA, card1 = AMD`. This is because simpledrm claims card0, then when amdgpu loads it gets card1. Some compositors and display managers target card0 by default. The fix is confirmed working by [multiple](https://blog.lightwo.net/fix-gpu-identifier-randomly-setting-to-card0-or-card1-linux.html) [Arch](https://bbs.archlinux.org/viewtopic.php?id=288578) community posts.

**Alternatives:**
- `initcall_blacklist=sysfb_init` -- more aggressive, blocks ALL firmware framebuffers (simpledrm, efifb, vesafb). Use only if simpledrm-specific blacklist is insufficient.
- `video=efifb:off` -- NOT relevant for Ubuntu 24.04 which uses simpledrm, not efifb.

**Caveat:** With simpledrm blacklisted, the screen is BLACK from GRUB until amdgpu loads (~3-5 seconds). This is acceptable for a workstation but breaks LUKS/FDE password entry (which needs a framebuffer for the prompt). If using disk encryption, use `initcall_blacklist=sysfb_init` instead and configure Plymouth to use the DRM backend.

**Recommendation:** `initcall_blacklist=simpledrm_platform_driver_init` -- eliminates card ordering issues, one fewer DRM device in the pipeline.

### 2.8 video= Parameter (Force Resolution)

**Format:** `video=HDMI-A-1:1920x1080@60` (connector:WIDTHxHEIGHT@REFRESH)

**Does it help or hurt?**
- Does NOT affect the optc31 timeout (which happens during pipe teardown, before any mode is set).
- CAN help if the EDID probe triggers a modeset to an unsupported mode during early boot.
- CAN hurt if it forces a mode that the DMCUB can't handle in its current firmware state.
- With `AccelMethod "none"`, the resolution is set by Xorg anyway, making the kernel parameter redundant.

**Recommendation:** Omit unless EDID detection is failing. If display issues occur during early boot (before Xorg starts), try `video=HDMI-A-1:1920x1080@60` as a constraint.

### 2.9 amdgpu.vm_fragment_size

**What it does:** Controls GPU page table fragment size. A fragment is a contiguous range of pages with identical flags. The GPU TLB can store a single entry for a whole fragment, increasing effective TLB reach.

| Value | Fragment Size | TLB Entries Per Fragment |
|-------|--------------|------------------------|
| `4` | 64KB | 16 pages |
| `9` (recommended) | **2MB** | 512 pages |
| `-1` (default) | Auto per ASIC | Varies |

**Impact on compositing:** Larger fragments mean fewer TLB misses during compositor rendering. On an APU where display memory is in system RAM (or GTT), TLB efficiency matters more than on a discrete GPU with dedicated VRAM. Setting `vm_fragment_size=9` (2MB) reduces TLB pressure during compositing operations.

**Recommendation:** `amdgpu.vm_fragment_size=9` -- minor performance improvement, no downside.

### 2.10 amdgpu.gpu_recovery

| Value | Behavior |
|-------|----------|
| `-1` (default) | Auto -- disabled except SRIOV |
| `0` | Disabled -- GPU hangs crash the system |
| `1` | Enabled -- GPU reset on timeout |
| `0x4` | **Disable soft recovery, force FULL reset** |
| `0x5` | Enable recovery (0x1) + disable soft recovery (0x4) |

**The 0x4 flag** (from [kernel patch](https://www.mail-archive.com/amd-gfx@lists.freedesktop.org/msg106105.html)): Disables "soft recovery" (a lightweight recovery attempt before full GPU reset). When soft recovery fails, it adds latency before the full reset. Disabling it forces an immediate full reset.

**Recommendation:** `amdgpu.gpu_recovery=1` (enable recovery). Consider `amdgpu.gpu_recovery=0x5` (enable + skip soft recovery) if you want faster reset response. Note: the 0x4 flag was originally intended to pair with `reset_method=1` (MODE0) for faster full DCN resets, but MODE0 is **not supported on Raphael APU** (kernel 6.17 rejects it), so the benefit is limited to skipping soft recovery before the MODE2 (AUTO) reset.

---

## 3. MESA / USERSPACE OPTIMIZATION

### 3.1 Mesa Version Impact

| Mesa Version | Source | Key Changes for Raphael |
|---|---|---|
| **24.0.4** (Ubuntu stock) | Default apt | Baseline; gfx10.3 hang fix in radeonsi |
| **25.2.8** (Ubuntu HWE) | HWE stack | Improved APU scanout buffer handling, cross-device support |
| **26.0.3** (kisak PPA) | PPA | ACO as default compiler for radeonsi, mesh shader support, GFX10 ACO fixes |

Mesa 26.0.0 release notes confirm: "ACO by default for the RadeonSI driver for better GPU performance and better compile times." ACO (AMD Compiler) replaces LLVM for shader compilation on radeonsi, which can reduce GFX ring submission latency and improve command scheduling.

**Does Mesa 26.0.3 fix ring timeouts?** The release notes mention ACO fixes for GFX10 (which includes gfx1036 / Raphael) and various SGPR operand register class fixes. These could reduce the likelihood of ring timeouts caused by shader compilation issues, but they do NOT address the root cause (DCN stall). Ring timeouts caused by DCN stalls are a kernel/firmware issue, not userspace.

**Recommendation:** Use Mesa 25.2.8 (HWE match) initially. Upgrade to kisak PPA 26.0.3 only if ring timeouts persist after firmware + kernel fixes.

```bash
# Install kisak PPA (only if needed)
sudo add-apt-repository ppa:kisak/kisak-mesa
sudo apt update && sudo apt upgrade
```

### 3.2 MESA_LOADER_DRIVER_OVERRIDE

```bash
# Force a specific Mesa driver
export MESA_LOADER_DRIVER_OVERRIDE=radeonsi   # Default for Raphael
export MESA_LOADER_DRIVER_OVERRIDE=softpipe   # Software renderer (zero GPU)
export MESA_LOADER_DRIVER_OVERRIDE=llvmpipe    # CPU-based GL (fast software)
```

Using `llvmpipe` as a per-app override is useful for testing whether a specific application triggers ring pressure. It does NOT help with compositor ring pressure (compositor uses its own GL context).

### 3.3 DRI_PRIME for Single-GPU Setup

With the iGPU as the sole display device:
```bash
# Ensure all GL goes to the AMD iGPU (card1 if simpledrm not blacklisted)
export DRI_PRIME=0                    # Use default device
export DRI_PRIME=pci-0000_XX_YY_Z    # Use specific PCI device
```

With `initcall_blacklist=simpledrm_platform_driver_init`, the AMD iGPU becomes `card0` and `DRI_PRIME` configuration becomes unnecessary.

### 3.4 LIBGL_ALWAYS_SOFTWARE=1

**What it does:** Forces ALL OpenGL rendering through llvmpipe (CPU-based). Zero GPU ring submissions.

**Use cases:**
- Per-app fallback: `LIBGL_ALWAYS_SOFTWARE=1 firefox` -- runs Firefox with software GL
- System-wide: Add to `/etc/environment` -- disables all GPU acceleration
- Diagnostic: Confirms whether ring timeout is caused by a specific application

**Does NOT help with:** Compositor ring pressure (compositor ignores this env var). To disable compositor GPU usage, you need `AccelMethod "none"` in Xorg or a compositor that doesn't use GL (XFCE/xfwm4 with compositing off).

### 3.5 AMD_VULKAN_ICD: radv vs amdvlk

| ICD | Source | GFX Ring Usage | Notes |
|-----|--------|---------------|-------|
| **radv** (Mesa) | Open-source | Uses GFX ring for Vulkan | Default on most distros |
| **amdvlk** (AMD) | Open-source (AMD) | Uses GFX ring for Vulkan | Alternative, may have different ring behavior |

For a display-only workstation (no Vulkan applications on the iGPU), the Vulkan ICD choice is irrelevant. Vulkan apps running on the RTX 4090 use NVIDIA's Vulkan driver, not AMD's.

### 3.6 EGL vs GLX

**EGL** is the modern API for binding OpenGL/ES contexts to display surfaces. It fixes several design inefficiencies in **GLX** and is required for Wayland compositors. On X11, GLX is the traditional API.

**Ring pressure comparison:** Both EGL and GLX ultimately submit commands to the same GFX ring. The difference is in buffer management and synchronization overhead, not in raw ring submission count. EGL's buffer handling is slightly more efficient (fewer round-trips to the X server), but the difference is negligible for compositor workloads.

**Recommendation:** Use whatever the compositor defaults to. On X11 XFCE with compositing off, neither EGL nor GLX is used for compositing.

---

## 4. DISPLAY SERVER CONFIGURATION

### 4.1 Xorg AccelMethod

This is the **single most impactful userspace setting** for the crash loop.

| AccelMethod | Rendering Backend | GFX Ring Submissions | Ring Pressure |
|-------------|------------------|---------------------|---------------|
| **`"glamor"`** (default) | OpenGL via GFX ring | **ALL 2D operations** via GPU | **HIGH** |
| **`"none"`** | CPU software rendering | **ZERO** 2D operations via GPU | **ZERO** |
| ~~`"EXA"`~~ | Legacy DDX acceleration | N/A | **Deprecated, removed from amdgpu DDX** |

**How `AccelMethod "none"` works:**
- ALL 2D rendering (window moves, redraws, scrolling, text rendering) is done on the CPU.
- 3D acceleration (OpenGL/Vulkan) and video decode (VA-API) still work via DRI.
- The GFX ring is only used by explicit 3D/Vulkan applications, NOT by the display server or compositor.
- This eliminates Condition 2 (GFX ring pressure from compositor) entirely.

**Configuration:**
```
# /etc/X11/xorg.conf.d/20-amdgpu.conf
Section "Device"
    Identifier "AMD"
    Driver     "amdgpu"
    BusID      "PCI:X:Y:Z"   # Your AMD iGPU PCI address
    Option     "AccelMethod" "none"
    Option     "TearFree"    "off"
EndSection
```

**Performance impact:** On a modern CPU (Ryzen 9 7950X), CPU-based 2D rendering is fast enough for desktop use. You may notice slightly slower window dragging or scrolling in text-heavy applications. Video playback via VA-API hardware decode is unaffected.

**CONFIRMED by diagnostic data:** With `AccelMethod "none"` + XFCE + no NVIDIA, system is STABLE (0 ring timeouts across all test boots).

### 4.2 DRI2 vs DRI3

| Feature | DRI2 | DRI3 (default since Xorg >= 1.18.3) |
|---------|------|------|
| Buffer management | Server-controlled | Client-controlled |
| Triple buffering | Not supported | Always enabled (Mesa) |
| Synchronization | Implicit (kernel-side) | Explicit (client-side fences) |
| Ring pressure | Moderate (server manages buffers, some round-trips) | **Lower** (fewer round-trips, better buffer reuse) |

**DRI3 is preferred** for reducing ring pressure. It eliminates the server-side buffer management that adds extra GFX ring submissions. With `AccelMethod "none"`, DRI3 is mostly irrelevant (no hardware-accelerated 2D), but it still applies to any 3D/Vulkan applications.

**Configuration:**
```
Section "Device"
    Option "DRI" "3"   # Default on modern Xorg
EndSection
```

### 4.3 TearFree

**What it does:** TearFree uses dedicated scanout buffers and kernel DRM page flipping to eliminate tearing. The display server periodically copies the screen contents to a scanout buffer and flips.

**Ring pressure impact:** TearFree adds regular page flip IOCTLs to the kernel DRM path. Each flip generates a GFX ring submission for the copy/flip operation. On a stalled DCN, these flips can trigger the same ring timeout as compositor rendering.

**Recommendation:** `TearFree "off"` when using `AccelMethod "none"` (no tearing possible without GPU compositing). `TearFree "on"` only if using glamor and experiencing visible tearing.

### 4.4 VariableRefresh (VRR / FreeSync)

**What it does:** Enables variable refresh rate on FreeSync-capable monitors.

**Ring pressure impact:** VRR requires the display engine to dynamically adjust front porch timing, which adds DCN state machine activity. On a system with an intermittent DCN stall, VRR adds unnecessary complexity.

**Recommendation:** `VariableRefresh "off"` -- reduce DCN state machine load.

### 4.5 Can Xorg Use Vulkan for Compositing?

No. Xorg compositing is fundamentally based on the X Render extension (XRender) or OpenGL (glamor). There is no Vulkan compositing path for Xorg. Vulkan-based compositing only exists in Wayland compositors (e.g., wlroots-based compositors can use Vulkan renderer since 0.18).

---

## 5. KERNEL PATCHES

### 5.1 Custom Kernel PPAs

| Kernel | Source | DCN31 Patches | NVIDIA Compat | Install |
|--------|--------|---------------|---------------|---------|
| **XanMod 6.19** | [xanmod.org](https://xanmod.org/) | All 6 (mainline 6.15+ base) | Yes (DKMS) | PPA available for Ubuntu |
| **XanMod 6.18 LTS** | [xanmod.org](https://xanmod.org/) | All 6 | Yes (DKMS) | PPA available |
| **Liquorix 6.19** | [liquorix.net](https://liquorix.net/) | All 6 | Yes (DKMS) | PPA available |
| **CachyOS patches** | [GitHub](https://github.com/CachyOS/kernel-patches) | All mainline patches + extras | N/A (Arch only) | Not directly usable on Ubuntu |
| **Ubuntu HWE 6.17** | Ubuntu repos | All 6 (6.15+ base) | Yes (official) | `apt install linux-generic-hwe-24.04` |
| **Ubuntu Mainline PPA** | [kernel.ubuntu.com](https://kernel.ubuntu.com/~kernel-ppa/mainline/) | Depends on version | DKMS may fail | Manual .deb install |

**XanMod** is the best option for Ubuntu users who want a newer kernel with all DCN31 patches. It is performance-optimized (BORE scheduler, better I/O, TCP optimizations) and provides Ubuntu-compatible packages.

```bash
# Install XanMod on Ubuntu 24.04
echo 'deb http://deb.xanmod.org releases main' | sudo tee /etc/apt/sources.list.d/xanmod-kernel.list
wget -qO - https://dl.xanmod.org/gpg.key | sudo gpg --dearmor -o /usr/share/keyrings/xanmod.gpg
sudo apt update
sudo apt install linux-xanmod-x64v3   # For Zen 4 (x86-64-v3)
```

**However:** Ubuntu HWE 6.17 already contains all 6 critical patches. There is no DCN31-specific reason to use XanMod over HWE unless you want the additional performance optimizations.

### 5.2 Can We Backport Individual Patches?

**Theoretically yes, practically difficult.** The amdgpu driver is deeply integrated into the kernel. The "bypass ODM before CRTC off" patch (`a878304276b8`) modifies `optc31_funcs` in `dcn31_optc.c`, which is part of the in-tree amdgpu module. To backport:

1. You would need to compile an out-of-tree amdgpu module (the entire `drivers/gpu/drm/amd/` subtree).
2. The amdgpu module depends on DRM core, TTM, and other subsystems that may have changed between kernel versions.
3. AMD provides [amdgpu-dkms](https://www.amd.com/en/developer/rocm.html) as part of ROCm, but this is for compute workloads and may not include display patches.

**Recommendation:** Use kernel HWE 6.17 which already has all patches. Do not attempt individual backports.

### 5.3 Kernel Livepatch

Linux kernel livepatch allows replacing individual functions at runtime without reboot. Theoretically, you could livepatch `optc31_disable_crtc` to include the ODM bypass fix.

**Practical limitations:**
- Livepatch requires the function to have a unique signature and no inline callers.
- The `optc31_disable_crtc` function is called through a function pointer table (`optc31_funcs`), making livepatch technically possible.
- Writing a livepatch module requires deep kernel knowledge and access to the exact kernel binary for symbol resolution.
- Ubuntu's Canonical Livepatch service does NOT cover amdgpu fixes.

**Recommendation:** Not practical. Use HWE 6.17 instead.

---

## 6. BIOS / HARDWARE OPTIMIZATION

### 6.1 UMA Frame Buffer Size

| Setting | Effect | Recommendation |
|---------|--------|----------------|
| Auto | System manages (typically 512MB) | **NOT recommended** -- may default to 512MB which causes ring timeouts |
| 512MB | Minimum VRAM for iGPU | **KNOWN BAD** -- [drm/amd #3006](https://gitlab.freedesktop.org/drm/amd/-/issues/3006): page faults during compositing |
| **2GB** | Adequate for 1080p desktop + lightweight compositing | **RECOMMENDED** |
| 4GB | Extra headroom for 4K or multi-monitor | Good for testing, wastes 2GB system RAM |
| 8GB+ | Excessive for desktop use | Only for iGPU gaming/compute |

AMD's official documentation confirms that UMA frame buffer size determines how much system RAM is carved out for iGPU VRAM. With only 2 CUs, the Raphael iGPU doesn't need more than 2GB for desktop compositing at 1080p.

**Recommendation:** Set to **2GB** in BIOS. Verify in BIOS: `Advanced > NB Configuration > UMA Frame Buffer Size`.

### 6.2 GFXOFF: BIOS vs ppfeaturemask

GFXOFF can be controlled at two levels:
1. **BIOS:** `Advanced > AMD CBS > NBIO > SMU Common Options > GFXOFF` -- this tells the SMU firmware to disable GFXOFF at the hardware level.
2. **ppfeaturemask bit 15 (0x8000):** This tells the amdgpu driver not to request GFXOFF from SMU.

**Both should be set.** The BIOS setting disables it at the firmware level, and the ppfeaturemask disables it at the driver level. Belt-and-suspenders approach.

**Current state:** BIOS GFXOFF is confirmed disabled. But ppfeaturemask reads `0xfff7bfff` which does NOT disable GFXOFF (bit 15 is still SET in this value). This means the driver may still request GFXOFF despite the BIOS setting.

**Fix:** `amdgpu.ppfeaturemask=0xfffd7fff` (explicitly clears bit 15 and bit 17).

### 6.3 PCIe ASPM Interaction with DCN

PCIe ASPM (Active State Power Management) controls link power states for PCIe devices. For the Raphael iGPU:
- The iGPU is on the **internal fabric** (not a PCIe slot), so PCIe ASPM settings primarily affect the RTX 4090.
- ASPM L1 on the RTX 4090 can cause Xid 79 ("GPU has fallen off the bus") errors.
- ASPM does NOT directly affect DCN behavior because the DCN is accessed via the internal display hub (DCHUB), not PCIe.

**Recommendation:** `pcie_aspm=off` (for RTX 4090 stability), plus `CPU PCIE ASPM Mode = Disabled` in BIOS. The iGPU DCN is unaffected by PCIe ASPM.

### 6.4 AGESA 1.3.0.0a Changes

AGESA (AMD Generic Encapsulated Software Architecture) 1.3.0.0a is the latest for the X670E platform. Research found no specific DCN-related changes documented in AGESA 1.3.0.0a release notes. The changes focus on DDR5 memory compatibility, EXPO stability, and boot reliability.

**No action needed** on BIOS version. BIOS 3603 with AGESA 1.3.0.0a is the latest available.

---

## 7. MODERN UI/UX CONSIDERATIONS

### 7.1 Modern-Looking Desktops with Minimal GPU Acceleration

| Desktop | GPU Usage | Visual Quality | Ring Pressure | Notes |
|---------|-----------|---------------|---------------|-------|
| **XFCE + Matcha/Arc theme** | XRender (CPU) or none | Good -- modern flat design | **ZERO** | Best balance of looks + stability |
| **MX Linux XFCE** (theme) | Same as XFCE | **Excellent** -- polished look | **ZERO** | MX Linux's XFCE is highly polished |
| **i3wm + picom (xrender)** | XRender backend | Customizable | **VERY LOW** (picom xrender) | Tiling WM; picom adds shadows/transparency via CPU |
| **i3wm (no compositor)** | None | Minimal but functional | **ZERO** | Most stable possible |
| **Sway** | Minimal Vulkan/GL | Good | LOW | Wayland tiling; lighter than GNOME |
| **COSMIC** (Pop!_OS) | OpenGL ES | Modern | LOW-MEDIUM | Still uses GFX ring |

**Making XFCE look modern:**
1. Install a modern GTK theme: `sudo apt install arc-theme papirus-icon-theme`
2. Use Plank dock for a macOS-like dock: `sudo apt install plank`
3. Install Compiz-like effects WITHOUT GPU compositing: XFCE's xfwm4 compositor uses XRender (CPU-based) for shadows and transparency when compositing is ON but in XRender mode.
4. Fonts: Install `fonts-inter` or Cantarell for modern typography.

**XFCE xfwm4 compositor modes:**
- **Compositing OFF:** Zero GPU usage. No transparency, no shadows. Functional but plain.
- **Compositing ON, vblank=off:** XRender-based shadows and transparency. CPU-rendered. **No GFX ring submissions.** This is the sweet spot.
- **Compositing ON, vblank=glx:** Uses OpenGL for vsync. **Adds GFX ring submissions.** Avoid.
- **Compositing ON, vblank=xpresent:** Uses X Present extension for vsync. **Minimal ring submissions.** Good compromise.

```bash
# Set xfwm4 to XRender compositing with no GLX vblank
xfconf-query -c xfwm4 -p /general/vblank_mode -s "off"
# Or use xpresent for tear-free without GLX
xfconf-query -c xfwm4 -p /general/vblank_mode -s "xpresent"
```

### 7.2 Hardware vs Software Cursor

**Hardware cursor:** The display engine (DCN) has a dedicated hardware cursor plane. Cursor movement is handled entirely by the display engine -- it reads cursor position and bitmap from a dedicated buffer and overlays it on the scanout. **No GFX ring involvement.**

**Software cursor:** The compositor draws the cursor as part of the framebuffer. Every cursor movement triggers a partial screen redraw, which DOES generate GFX ring submissions if the compositor uses GL.

**Analysis:** Hardware cursor is BETTER for ring pressure avoidance because it bypasses the GFX ring entirely. However, on some AMD GPUs, hardware cursors are broken (invisible or glitchy), requiring `SWcursor "true"` in xorg.conf.

**On Raphael with `AccelMethod "none"`:** Software cursor rendering is done on the CPU, not the GPU. So even with software cursor, there are zero GFX ring submissions. The hardware vs software cursor distinction only matters when using glamor acceleration.

**Mutter-specific:** `MUTTER_DEBUG_DISABLE_HW_CURSORS=1` forces software cursor in GNOME. This is a GNOME workaround, not needed on XFCE.

**Recommendation:** Use hardware cursor (default) unless it's visually broken. With `AccelMethod "none"`, cursor mode doesn't affect ring pressure.

### 7.3 Multi-Monitor Considerations for Raphael 2-CU iGPU

The Raphael iGPU has only **2 Compute Units** (128 shader processors). This is extremely limited for display acceleration:

| Configuration | VRAM Needed | GPU Load (idle) | Feasible? |
|---|---|---|---|
| 1x 1080p | ~8MB framebuffer | <5% | Yes |
| 2x 1080p | ~16MB framebuffer | <10% | Yes |
| 1x 4K | ~32MB framebuffer | <10% | Yes |
| 2x 4K | ~64MB framebuffer | 10-20% | Yes, but tight |
| 3+ monitors | Scales linearly | 20%+ | Risky with GL compositing |

With `AccelMethod "none"` (CPU rendering), GPU load is near-zero regardless of monitor count. Multi-monitor is limited only by DCN hardware ports (Raphael has 2 display pipes for DCN 3.1.5).

### 7.4 4K Scaling

| Method | GPU Overhead | Visual Quality | XFCE Support |
|--------|-------------|---------------|-------------|
| **Integer scaling (2x)** | Minimal (just sets scale factor) | Sharp | Yes (via GDK_SCALE=2) |
| **Fractional scaling (1.25x, 1.5x)** | Higher (render at 2x then downscale) | Blurry on X11 | **Poor** -- XFCE has broken fractional scaling |
| **Font DPI scaling** | Zero GPU overhead | Good for text, icons may be small | Yes (Appearance > Fonts > DPI) |

**Recommendation for 4K on XFCE:**
- Use `GDK_SCALE=2` for a clean integer 2x scale (everything is doubled).
- Or use a 1080p display (no scaling needed, minimal GPU overhead).
- Fractional scaling on XFCE/X11 is unreliable -- avoid it.

---

## 8. ALTERNATIVE DISPLAY ARCHITECTURES

### 8.1 VNC/RDP as Primary Display (Zero GPU Compositing)

| Solution | Protocol | GPU Usage | Latency | Setup Complexity |
|---|---|---|---|---|
| **TigerVNC** | VNC/RFB | ZERO (virtual framebuffer) | 10-50ms LAN | Low |
| **x11vnc** | VNC over real X11 | Same as X11 session | 10-50ms LAN | Low |
| **xrdp** | RDP | ZERO (Xvnc backend) | 5-20ms LAN | Medium |
| **NoMachine** | NX | Optional GPU accel | 5-15ms LAN | Medium |
| **KasmVNC** | VNC + web | Optional GPU accel | 20-100ms | Medium |

**For ML workstation use case:**
- SSH + terminal multiplexer (tmux/screen) handles 90% of ML workflow (training scripts, monitoring, Jupyter over SSH tunnel).
- VNC/RDP provides GUI access when needed (viewing plots, debugging visualization code).
- The GPU compositing crash loop is completely eliminated because there's no local display compositor.

**Setup:**
```bash
# TigerVNC headless (no local display needed)
sudo apt install tigervnc-standalone-server
vncserver :1 -geometry 1920x1080 -depth 24
# Connect: vncviewer host:1

# xrdp (supports Windows Remote Desktop client)
sudo apt install xrdp
sudo systemctl enable xrdp
# Connect: Windows RDP client to host:3389
```

### 8.2 Headless + SSH for ML Workstation

**The most robust architecture:**

```
Multi-user target (no GUI):
  systemctl set-default multi-user.target

ML workflow:
  SSH -> tmux -> python train.py
  SSH -> jupyter notebook --no-browser --port=8888
  Browser: http://host:8888 (Jupyter)
  SSH -> nvidia-smi / gpustat (monitoring)

GUI when needed:
  SSH -X -> individual apps with X11 forwarding
  OR: VNC session on-demand
```

This eliminates the crash loop entirely because:
- No display manager (GDM/LightDM)
- No compositor
- No GFX ring submissions
- DCN is idle (HDMI can be unplugged or connected to a basic console)
- amdgpu only needs to handle console framebuffer

**Recommendation:** If the primary use case is ML compute, switch to `multi-user.target` with on-demand VNC/SSH as the highest-stability option.

### 8.3 Waypipe / WayVNC for Remote Wayland

| Tool | What It Does | GPU Usage |
|---|---|---|
| **waypipe** | Transparent proxy for individual Wayland apps over SSH | Optional (has `--no-gpu` flag) |
| **wayvnc** | VNC server for wlroots-based compositors (Sway) | Optional GPU for encoding |

**Waypipe** is particularly interesting: it virtualizes a Wayland compositor on the remote end, forwarding individual applications. Using `waypipe --no-gpu ssh host app` blocks all GPU-accelerated protocols (wayland-drm, linux-dmabuf), ensuring zero GPU ring submissions on the remote side.

**WayVNC** only works with wlroots-based compositors (Sway, Hyprland). It does NOT support GNOME or KDE. It's lightweight and can use GPU for encoding (optional).

### 8.4 VFIO GPU Passthrough

**Concept:** Pass the iGPU to a VM via VFIO, let the VM handle display, use NVIDIA directly on the host for compute.

**Problems for this use case:**
- The Raphael iGPU reset bug (the same DCN stall) would still affect the VM.
- VFIO for APU iGPUs is poorly supported (no IOMMU group isolation on most AM5 boards).
- Adds enormous complexity for no real benefit.

**Recommendation:** Do not pursue VFIO for this use case.

---

## PRIORITIZED ACTION PLAN

### Phase 1: Firmware Fix (HIGHEST PRIORITY -- Day 1)

```bash
# 1. Check current firmware version
dmesg | grep "DMUB firmware.*version"
# Expected bad: 0x05000F00 (0.0.15.0) or 0x05002F00 (0.0.47.0)

# 2. Update from linux-firmware git tag 20250305
cd /tmp
git clone --depth 1 --branch 20250305 \
  https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git

# 3. Install and compress
sudo cp linux-firmware/amdgpu/dcn_3_1_5_dmcub.bin /lib/firmware/amdgpu/
sudo zstd -f /lib/firmware/amdgpu/dcn_3_1_5_dmcub.bin \
     -o /lib/firmware/amdgpu/dcn_3_1_5_dmcub.bin.zst
sudo rm -f /lib/firmware/amdgpu/dcn_3_1_5_dmcub.bin

# 4. Remove any conflicting bare .bin files
for f in /lib/firmware/amdgpu/dcn_3_1_5_dmcub /lib/firmware/amdgpu/psp_13_0_5_toc; do
    [ -f "${f}.bin" ] && [ -f "${f}.bin.zst" ] && sudo rm -f "${f}.bin"
done

# 5. Rebuild initramfs
sudo update-initramfs -u -k all

# 6. Reboot and verify
# After reboot:
dmesg | grep "DMUB firmware.*version"
# Expected good: 0x0500FF00 (0.0.255.0) or similar post-fix version
```

### Phase 2: Kernel Parameters (Day 1, post-firmware)

Set all parameters consistently in BOTH GRUB and modprobe.d:

```bash
# GRUB
sudo sed -i 's|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT="quiet splash amdgpu.sg_display=0 amdgpu.dcdebugmask=0x10 amdgpu.ppfeaturemask=0xfffd7fff amdgpu.gpu_recovery=1 amdgpu.lockup_timeout=30000 amdgpu.vm_fragment_size=9 nvidia-drm.modeset=1 nvidia-drm.fbdev=1 pcie_aspm=off iommu=pt nogpumanager processor.max_cstate=1 amd_pstate=active modprobe.blacklist=nouveau,nova_core initcall_blacklist=simpledrm_platform_driver_init"|' /etc/default/grub
sudo update-grub

# modprobe.d/amdgpu.conf
sudo tee /etc/modprobe.d/amdgpu.conf << 'EOF'
options amdgpu sg_display=0
options amdgpu ppfeaturemask=0xfffd7fff
options amdgpu gpu_recovery=1
options amdgpu dc=1
options amdgpu audio=1
options amdgpu vm_fragment_size=9
EOF

# Rebuild initramfs
sudo update-initramfs -u -k all
```

### Phase 3: Display Stack (Day 1, post-reboot)

```bash
# Install XFCE
sudo apt install xfce4 xfce4-goodies lightdm lightdm-gtk-greeter

# Set LightDM as display manager
sudo dpkg-reconfigure lightdm

# Configure Xorg for AccelMethod none
sudo tee /etc/X11/xorg.conf.d/20-amdgpu.conf << 'EOF'
Section "Device"
    Identifier "AMD iGPU"
    Driver     "amdgpu"
    Option     "AccelMethod" "none"
    Option     "TearFree"    "off"
    Option     "DRI"         "3"
    Option     "VariableRefresh" "off"
EndSection
EOF

# Mutter workaround (in case GNOME is ever used)
echo 'MUTTER_DEBUG_KMS_THREAD_TYPE=user' | sudo tee /etc/environment.d/90-mutter-kms.conf

# Set XFCE compositor to XRender (no GL)
# This will be configured on first login via xfce4-settings
```

### Phase 4: Verification (Day 1, post-reboot)

```bash
# 1. DMCUB firmware version
dmesg | grep "DMUB"

# 2. No optc31 timeouts
dmesg | grep -i "REG_WAIT timeout"

# 3. No ring timeouts
dmesg | grep -i "ring.*timeout"

# 4. Card ordering (AMD should be card0)
for card in /sys/class/drm/card[0-9]; do
    driver=$(basename $(readlink "$card/device/driver") 2>/dev/null)
    echo "$(basename $card): driver=$driver"
done

# 5. sg_display disabled
cat /sys/module/amdgpu/parameters/sg_display

# 6. ppfeaturemask correct
cat /sys/module/amdgpu/parameters/ppfeaturemask
# Expected: 0xfffd7fff

# 7. AccelMethod none confirmed
grep -r "AccelMethod" /var/log/Xorg.0.log
```

### Phase 5: Escalation (If Still Failing)

Test these one at a time, rebooting between each:

```bash
# 5A: Force seamless boot (skips CRTC disable entirely)
# Add to GRUB: amdgpu.seamless=1

# 5B: Disable DCN clock gating + PSR
# Change dcdebugmask in GRUB: amdgpu.dcdebugmask=0x18

# 5C: Increase ring timeout to 30s
# Add to GRUB: amdgpu.lockup_timeout=30000

# 5D: Force MODE0 reset (full ASIC including DCN)
# NOTE: amdgpu.reset_method=1 is NOT SUPPORTED on Raphael APU.
# Kernel 6.17 rejects it: "Specified reset method:1 isn't supported, using AUTO instead."
# This option has no effect — the system always falls back to MODE2 (AUTO).

# 5E: Disable soft recovery, force full reset
# Change gpu_recovery: amdgpu.gpu_recovery=0x5

# 5F: Maximum DCN stability
# Change dcdebugmask: amdgpu.dcdebugmask=0x1A
# (disables clock gating + PSR + stutter)
```

### Phase 6: Nuclear Options (Last Resort)

```bash
# 6A: Headless + SSH (eliminates display entirely)
sudo systemctl set-default multi-user.target
# Access via SSH, VNC on-demand

# 6B: Software rendering for everything
echo 'LIBGL_ALWAYS_SOFTWARE=1' | sudo tee -a /etc/environment

# 6C: Mesa PPA for latest radeonsi fixes
sudo add-apt-repository ppa:kisak/kisak-mesa
sudo apt update && sudo apt upgrade

# 6D: XanMod kernel (if HWE 6.17 is somehow missing patches)
# See Section 5.1 for installation
```

---

## SOURCES

### Upstream Bug Trackers
- [drm/amd #5073 -- Exact match: Raphael iGPU optc31 timeout](https://gitlab.freedesktop.org/drm/amd/-/work_items/5073)
- [drm/amd #3377 -- Raphael optc1_wait_for_state black screen](https://gitlab.freedesktop.org/drm/amd/-/work_items/3377)
- [drm/amd #3006 -- UMA 512M causes gfx ring timeouts](https://gitlab.freedesktop.org/drm/amd/-/issues/3006)
- [Debian #1057656 -- DMCUB firmware breaks Raphael display](https://bugs-devel.debian.org/cgi-bin/bugreport.cgi?bug=1057656)
- [NixOS #418212 -- DMCUB 0.1.14.0 load failure](https://github.com/nixos/nixpkgs/issues/418212)
- [kernel-firmware MR #587 -- DMCUB update for DCN315](https://gitlab.com/kernel-firmware/linux-firmware/-/merge_requests/587)
- [Ubuntu #2034619 -- gnome-shell SIGKILL on amdgpu](https://bugs.launchpad.net/ubuntu/+source/mutter/+bug/2034619)

### Kernel Documentation
- [amdgpu Module Parameters](https://docs.kernel.org/gpu/amdgpu/module-parameters.html)
- [Display Core Debug Tools](https://docs.kernel.org/gpu/amdgpu/display/dc-debug.html)
- [DCN Overview](https://docs.kernel.org/gpu/amdgpu/display/dcn-overview.html)
- [amdgpu Driver Core (IP block reset architecture)](https://docs.kernel.org/gpu/amdgpu/driver-core.html)
- [PP_FEATURE_MASK enum (amd_shared.h)](https://github.com/torvalds/linux/blob/master/drivers/gpu/drm/amd/include/amd_shared.h)
- [Kernel Livepatch](https://docs.kernel.org/livepatch/livepatch.html)

### Kernel Patches
- [Bypass ODM before CRTC off (a878304276b8)](https://mail-archive.com/amd-gfx@lists.freedesktop.org/msg107870.html)
- [Ensure DMCUB idle before reset (c707ea82c79d)](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=c707ea82c79d)
- [Skip disable CRTC on seamless boot (391cea4fff00)](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=391cea4fff00)
- [Wait until OTG enable state cleared](https://www.mail-archive.com/amd-gfx@lists.freedesktop.org/msg126781.html)
- [Skip soft recovery patch](https://www.mail-archive.com/amd-gfx@lists.freedesktop.org/msg106105.html)

### Community and Arch Wiki
- [AMDGPU - ArchWiki](https://wiki.archlinux.org/title/AMDGPU)
- [HiDPI - ArchWiki](https://wiki.archlinux.org/title/HiDPI)
- [Picom - ArchWiki](https://wiki.archlinux.org/title/Picom)
- [simpledrm card ordering fix](https://blog.lightwo.net/fix-gpu-identifier-randomly-setting-to-card0-or-card1-linux.html)
- [AMD card0/card1 ordering (Arch Forums)](https://bbs.archlinux.org/viewtopic.php?id=288578)
- [Ring gfx timeout mitigation (CachyOS)](https://discuss.cachyos.org/t/tutorial-mitigate-gfx-crash-lockup-apparent-freeze-with-amdgpu/10842)
- [ppfeaturemask decode script (Arch Forums)](https://bbs.archlinux.org/viewtopic.php?id=302858)
- [GNOME ring timeout (Fedora 42)](https://discussion.fedoraproject.org/t/gnome-shell-crash-and-gpu-ring-timeout-on-amd-gpu-when-using-brave-browser-fedora-42/149587)
- [GNOME ring timeout (Ubuntu 25.04)](https://discourse.ubuntu.com/t/amd-gpu-crashing-on-ubuntu-25-04-ring-gfx-0-0-0-timeout-and-reset-failure/62975)

### Mesa
- [Mesa 26.0.0 Release Notes](https://docs.mesa3d.org/relnotes/26.0.0.html)
- [Mesa 26.0.2 Release Notes](https://docs.mesa3d.org/relnotes/26.0.2.html)

### Xorg Driver
- [amdgpu(4) man page](https://manpages.debian.org/testing/xserver-xorg-video-amdgpu/amdgpu.4.en.html)

### AMD Documentation
- [UMA Frame Buffer Size FAQ](https://www.amd.com/en/resources/support-articles/faqs/PA-280.html)
- [AMD Scatter/Gather Re-Enabled (Phoronix)](https://www.phoronix.com/news/AMD-Scatter-Gather-Re-Enabled)
- [AMDGPU GFXOFF Patches (Phoronix)](https://www.phoronix.com/news/AMDGPU-GFXOFF-Patches)

### Remote Display
- [Headless - ArchWiki](https://wiki.archlinux.org/title/Headless)
- [KasmVNC GPU Acceleration](https://kasmweb.com/kasmvnc/docs/master/gpu_acceleration.html)
- [WayVNC](https://github.com/any1/wayvnc)

### Custom Kernels
- [XanMod](https://xanmod.org/)
- [Liquorix](https://liquorix.net/)
- [CachyOS Kernel Patches](https://github.com/CachyOS/kernel-patches)

### fwupd
- [fwupd 1.9.6 AMD GPU support (Phoronix)](https://www.phoronix.com/news/Fwupd-1.9.6-Released)

### Display Debugging
- [15 Tips for Debugging AMD Display Driver](https://melissawen.github.io/blog/2023/12/13/amd-display-debugging-tips)

### XFCE
- [xfwm4 COMPOSITOR documentation](https://github.com/xfce-mirror/xfwm4/blob/master/COMPOSITOR)
- [XFCE Compositor Troubleshooting](https://forum.xfce.org/viewtopic.php?id=13233)
- [XFCE Modern Themes](https://itsfoss.com/best-xfce-themes/)
