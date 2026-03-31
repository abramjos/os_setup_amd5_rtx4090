# ML Workstation Dual-GPU Setup — Research & Implementation Playbook

## Objective

Resolve the intermittent boot crash loop on this dual-GPU ML workstation by evaluating **multiple candidate combinations** of OS, kernel, linux-firmware, NVIDIA driver, Mesa/amdgpu userspace, BIOS/AGESA, and compositor — then generate a research-backed compatibility report.

**Status**: COMPLETE — research deliverable at [COMPATIBILITY-MATRIX.md](COMPATIBILITY-MATRIX.md)

---

## Fixed Hardware

| Component | Fixed Value |
|-----------|-------------|
| CPU | AMD Ryzen 9 7950X (Zen 4, Raphael, Family 25 Model 0x61) |
| iGPU | AMD Radeon Graphics — RDNA2, GC 10.3.6, DCN 3.1.5, 2 CUs |
| dGPU | NVIDIA GeForce RTX 4090 (Ada Lovelace AD102, 16384 CUDA cores, 24 GB GDDR6X) |
| Motherboard | ASUS ROG Crosshair X670E Hero (X670E chipset, AM5) |
| BIOS | Currently 3603 (AGESA ComboAM5 PI 1.3.0.0a), released 2026-03-18 |
| Memory | 2x 32 GB DDR5-6000 CL30 (EXPO) |
| PSU | 1000W single-rail |

**Architecture goal**: iGPU drives ALL display/desktop. dGPU is 100% headless CUDA/ML compute. No display processes on NVIDIA whatsoever.

---

## Current Status & What Has Been Tried

### The Core Bug

The system suffers from an **intermittent crash loop** on boot:

```
[  6.1s] REG_WAIT timeout - optc31_disable_crtc    <- DCN register stall during EFI->amdgpu handoff
[  8.0s] REG_WAIT timeout - optc1_wait_for_state   <- Cascading: OTG stopped, no VBLANK arrives
[ 18.5s] ring gfx_0.0.0 timeout (gnome-shell)      <- GFX ring hangs on corrupted display state
[ 19.0s] MODE2 GPU reset                            <- Resets GFX/SDMA only -- NOT the DCN
[ 31.3s] ring gfx_0.0.0 timeout (gnome-shell #2)   <- DCN still broken -> repeat
[ 69.2s] ring gfx_0.0.0 timeout (gnome-shell #3)   <- GDM gives up -> session-failed
```

MODE2 reset does NOT reset the DCN (Display Core Next) — only GFX and SDMA. So the broken display pipeline persists through every GPU reset, causing an infinite crash loop. The triggering process is the active compositor/display server (`gnome-shell` under GDM/GNOME, `Xorg` under LightDM/XFCE). DMUB firmware version is `0x05000F00` (0.0.15.0) and re-initializes 3 times per boot during crash loop (1 initial + 2 after MODE2 resets).

### Exact Upstream Bug Match

**[freedesktop.org drm/amd #5073](https://gitlab.freedesktop.org/drm/amd/-/work_items/5073)** — "Fence fallback timer expired on Raphael iGPU"
- Same hardware pattern: Raphael/Granite Ridge iGPU, ASUS TUF X870, AGESA 1.3.0.0a, 64GB DDR5, NVIDIA dGPU present
- Same errors: optc31_disable_crtc REG_WAIT timeout + gfx ring timeouts + MODE2 resets
- Status: **OPEN** upstream as of 2026-03-28
- Upstream user tried: GFXOFF disabled, sg_display=0, ppfeaturemask, iGPU VRAM 4GB — none fully fixed it
- **Our resolution (2026-03-30):** Firmware upgrade to DMUB 0x05002000 eliminates ring timeouts; AccelMethod "none" is fallback

Related open issues: #5093, #3377, #3583, #4433 (all Raphael/Phoenix optc31/optc1 REG_WAIT timeouts).

### 20-Boot Diagnostic Data (runLog-04, 2026-03-27)

| Observation | Evidence |
|---|---|
| The bug is **intermittent** — some boots work fine with identical config | Boots -18, -4, -14 (kernel 6.8, default params) = no events |
| Kernel 6.17 HWE does NOT reliably fix it | Boots -19, -9, -6, -5 on 6.17 still show timeouts/crash-loops |
| Aggressive amdgpu parameter overrides can make things **WORSE** | Boot -10 (6.8 + all params) = 9 ring timeouts (worst run) |
| card0 = NVIDIA, card1 = AMD in EVERY boot | Module load order issue — amdgpu should be card0 |
| DMUB re-initializes 3-4 times per boot after MODE2 resets | DMUB firmware interaction is central |
| linux-firmware is `20240318.git3b128b60-0ubuntu2.25` — from **March 2024** | Missing DMCUB fixes from mid-2024+ |
| Firmware `.bin` and `.bin.zst` file conflicts exist for dcn_3_1_5_dmcub and psp_13_0_5_toc | Kernel prefers `.bin.zst` — manually placed `.bin` files may be ignored |

### Variant Testing Results (2026-03-29 through 2026-03-31)

| Run | Variant | Verdict | Key Finding |
|---|---|---|---|
| runLog-00 | Pre-variant baseline | **UNSTABLE** (5x ring timeout) | GNOME/glamor + DMUB 0x05000F00 = crash loop |
| runlog-A_v1 | A (display-only) | **STABLE** (1 optc31, 0 ring) | AccelMethod "none" eliminates ring timeouts — proves two-condition model |
| runlog-B_v1 | B (firmware fix) | **FAIL** (card ordering) | Recovery/nomodeset: simple-framebuffer claims card0 |
| runlog-B_v2 | B (firmware fix) | **PARTIAL → PASS** | Old FW: 0-4 ring timeouts; after install-firmware.sh → DMUB 0x05002000 = 0 ring timeouts |
| runlog-H_v1 | H (dual-GPU, XFCE+labwc) | **STABLE — pre-fix YAML, script bugs only** | DMUB 0x05002000 delivered by initramfs hook; 1 optc31, DCN recovered, 0 ring timeouts; XFCE running 72+ min uptime; all 8 FAILs in verify script are confirmed script bugs |

**Two-condition crash model CONFIRMED:**
- Condition 1 (DCN stall): optc31 timeout at T+5s — present in ALL normal boots, even with new firmware
- Condition 2 (GFX ring pressure): compositor GL commands → ring timeout ONLY with old firmware
- **Variant A** removes Condition 2 (AccelMethod "none") → stable even with old firmware
- **Variant B** fixes Condition 1 cascade (DMUB 0x05002000 recovers DCN) → stable with glamor
- **Variant H v1** confirms both simultaneously: AccelMethod "none" + DMUB 0x05002000 → stable dual-GPU, 72+ min uptime

**Autoinstall initramfs hook confirmed working (H_v1):** Custom `/etc/initramfs-tools/hooks/amdgpu-firmware` hook added to all variants successfully delivered DMUB firmware `0x05002000` (linux-firmware tag 20250509) into initramfs. Confirmed by `dmesg | grep "DMUB hardware initialized: version=0x05002000"` in H_v1 boot log.

**Software rendering is intentional (AccelMethod "none"):** All verify script hits for "OpenGL renderer: software rendering" are expected. AccelMethod "none" disables DRI3/glamor — Xorg uses swrast/XRender with zero GFX ring pressure. XFCE compositor (xfwm4) uses XRender, not GL. This is a complete and correct Condition 2 mitigation, not a hardware failure.

**Diagnostic script bugs confirmed by H_v1 logs — all fixed (2026-03-30):**
- `|| echo 0` multiline bug: `VAR=$(grep -c ... || echo 0)` produces `"0\n0"` → bash integer comparison fails → false UNSTABLE/FAIL across 6 checks. Fixed: `VAR=$(grep -c ...) || VAR=0`
- DMUB firmware regex false-positive: pattern `0x0500[0-4]` matched `0x05002000` (char after `0x0500` is `2`, in `[0-4]`) → false "CRITICAL: firmware too old" for known-good version. Fixed: full 32-bit integer comparison via `printf '%d'`
- AMD card detection hardcoded to `card1`: display checks ran against NVIDIA DRM node. Fixed: `detect_amd_card()` function scanning `/sys/class/drm/card*/device/driver` symlinks
- NVIDIA display false-fail: CSV header line from `nvidia-smi` counted as a running display process
- DESKTOP_SESSION inverted logic: FAIL triggered when gnome-shell count = 0 (correct state for non-GNOME variants)
- All 8 FAILs and 19 WARNs in `log_verify_boot.txt` are script bugs. Hardware is correct.

### BIOS Settings Confirmed

- GFXOFF: **Disabled** (confirmed by user)
- UMA Frame Buffer Size: **2 GB** (confirmed via `amdgpu_vram_mm` debugfs, 2026-03-29)
- BIOS version: **3603** (AGESA ComboAM5 PI 1.3.0.0a, released 2026-03-09, confirmed in H_v1 dmesg)
- Kernel parameters in H_v1 **running system** (pre-fix YAML state): `dcdebugmask=0x18` (old value — corrected to `0x10` in post-fix YAML); `amdgpu.gfx_off=0` absent (added in post-fix YAML); `NVreg_RegisterPCIDriverOnEarlyBoot=1` absent from nvidia.conf (added in post-fix YAML)
- All other parameters confirmed correct in H_v1: sg_display=0, ppfeaturemask=0xfffd7fff, nvidia-drm.modeset=1, initcall_blacklist=simpledrm_platform_driver_init

**PCIe Gen1 downgrade confirmed (H_v1 lspci — BIOS fix required):**
- RTX 4090 (PCI 01:00.0): `LnkCap: Speed 16GT/s (Gen4), Width x16` — hardware is capable of Gen4
- Actual link: `LnkSta: Speed 2.5GT/s (downgraded), Width x16` — link negotiated at Gen1 (6.25% of Gen4 bandwidth)
- `LnkCtl2: Target Link Speed: 16GT/s` — BIOS/OS targeting Gen4 but link training fails to achieve it
- **Impact:** 8× ML compute bandwidth loss. PCIe Gen1 x16 = 4 GB/s bidirectional; Gen4 x16 = 32 GB/s bidirectional
- **Fix:** BIOS → Advanced → PCIe → PCIEX16_1 Speed → **Gen4** (NOT Auto). Auto negotiates Gen1 with RTX 4090 on this board
- **Software-invisible:** Cannot be fixed by kernel params or udev rules — requires BIOS change before next boot

---

## Root Cause Analysis (Research-Backed)

### What The Registers Tell Us

**`optc31_disable_crtc` (line ~136)** -- This function disables the BIOS-configured CRTC during amdgpu init. It disconnects OPP segments from ODM, disables OTG master, then waits for `OTG_BUSY` bit in `OTG_CLOCK_CONTROL` to clear. The wait is 1us x 100,000 = 100ms. When `OTG_BUSY` stays stuck, the timeout fires.

**Why OTG_BUSY stays stuck**: The DCN31 implementation uses `OTG_DISABLE_POINT_CNTL=2` (disable at end-of-frame), but if the display pipeline is stalled, the end-of-frame never arrives, so OTG_BUSY never clears. This is a known upstream issue -- a patch "[bypass ODM before CRTC off](https://mail-archive.com/amd-gfx@lists.freedesktop.org/msg107870.html)" was added post-6.8 to fix the ordering.

**`optc1_wait_for_state` (line ~839)** -- Waits for `OTG_V_BLANK` or `OTG_V_ACTIVE_DISP` in `OTG_STATUS`. If the OTG is already dead from the first failure, no timing signals are generated, so this always times out. This is a cascading failure, not an independent bug.

**MODE2 reset does NOT fix DCN** -- Raphael (MP1_HWIP 13.0.5) uses MODE2 reset by default. MODE2 only resets GFX and SDMA IP blocks. The DCN (Display Core Next) engine, VCN, MMHUB, and PSP are **untouched**. So a hung display pipeline persists through every GPU reset, causing the infinite crash loop.

### Root Causes (Ranked by Evidence)

#### 1. DMCUB Firmware / linux-firmware Version (CRITICAL)

**Current state:** `linux-firmware 20240318.git3b128b60-0ubuntu2.25` -- Ubuntu 24.04 stock from **March 2024**.

**DMUB firmware version:** Stock is `0x05000F00` = version **0.0.15.0** -- critically outdated. **RESOLVED (2026-03-30):** Manual firmware update via `install-firmware.sh` upgraded to `0x05002000` (0.0.32.0), which eliminated all ring timeouts on 8 consecutive boots with glamor enabled. The optc31 timeout still fires at T+5s but the new firmware recovers the DCN pipeline gracefully.

**The problem:** The DMCUB manages display state transitions including CRTC disable/enable. Documented broken firmware history:
- [Debian Bug #1057656](https://bugs-devel.debian.org/cgi-bin/bugreport.cgi?bug=1057656): broken `dcn_3_1_5_dmcub.bin` caused display failure on Raphael. Fixed in firmware-nonfree 20240709-1.
- [NixOS #418212](https://github.com/nixos/nixpkgs/issues/418212): linux-firmware update broke DMCUB loading on Raphael ("failed to load ucode DMCUB(0x3D)")
- The `REG_WAIT` macro can offload register polls to DMCUB via `dmub_reg_wait_done_pack()`. If DMCUB firmware is hung, offload fails silently, CPU-side poll times out.

**Firmware file conflicts detected:**
```
CONFLICT: dcn_3_1_5_dmcub.bin AND dcn_3_1_5_dmcub.bin.zst both exist
CONFLICT: psp_13_0_5_toc.bin AND psp_13_0_5_toc.bin.zst both exist
```
The kernel prefers `.bin.zst` when both exist -- meaning manually-placed `.bin` may be completely ignored.

#### 2. Kernel 6.8 Missing DCN31 Patches (HIGH)

See **Kernel Candidates** section below for all 6 critical patches with commit hashes.

HWE 6.17 was tested and *should* contain all patches. But it also crashed -- pointing to root cause #1 (firmware) or #3 (EFI handoff) as the actual primary.

#### 3. EFI Framebuffer to amdgpu Handoff (MEDIUM)

The optc31 timeout at 6 seconds happens during `dcn31_init_hw` -> `dcn10_init_pipes`, when the driver discovers BIOS-configured display pipes and tries to shut them down. If DMCUB state from UEFI doesn't cleanly hand off, the OTG stays busy.

See **EFI Handoff & Seamless Boot** section for detailed mitigations.

#### 4. Scatter/Gather Display (CONTRIBUTING)

When `sg_display` is enabled (default for APUs), display framebuffers are allocated from GTT via GART scatter/gather DMA. If GART/TLB state is inconsistent during EFI->amdgpu transition, HUBP can't fetch framebuffer data, causing pipeline stall.

Setting `amdgpu.sg_display=0` forces contiguous VRAM allocation -- but [freedesktop #5073](https://gitlab.freedesktop.org/drm/amd/-/work_items/5073) reports it did NOT fix the optc31 timeout for the same hardware pattern.

---

## Research Reference

The following research has been completed and documented in dedicated files:

- **OS selection** → [OS-DECISION-MATRIX.md](OS-DECISION-MATRIX.md) (Ubuntu 24.04.4 LTS recommended)
- **Kernel + firmware analysis** → [COMPATIBILITY-MATRIX.md](COMPATIBILITY-MATRIX.md)
- **Mitigation strategies** → [MITIGATION-RESEARCH.md](MITIGATION-RESEARCH.md)
- **Compositor comparison** → [WAYLAND-COMPOSITOR-RESEARCH.md](WAYLAND-COMPOSITOR-RESEARCH.md) + [X11-COMPOSITOR-RESEARCH.md](X11-COMPOSITOR-RESEARCH.md)
- **Cross-distro CUDA/NVIDIA infra** → [OS-CROSSCUTTING-CONCERNS.md](OS-CROSSCUTTING-CONCERNS.md)
- **GNOME-specific hardening** → [GNOME-MUTTER-HARDENING.md](GNOME-MUTTER-HARDENING.md)
- **Variant test data** → [DIAGNOSTIC-REFERENCE.md](DIAGNOSTIC-REFERENCE.md)

---

## Technical Deep-Dives

### EFI Handoff & Seamless Boot

Ubuntu 24.04 uses **simpledrm** (not efifb) for the early boot framebuffer. simpledrm is built into the kernel (not a module) and cannot be blacklisted via modprobe.

When amdgpu loads, it must take over from simpledrm. The `dcn31_init_hw` function discovers BIOS/EFI-configured display pipes and either:
1. **Tears them down** (default) -- calls `optc31_disable_crtc` on each active pipe -> THIS IS WHERE THE TIMEOUT HAPPENS
2. **Adopts them** (seamless mode) -- keeps the BIOS-configured pipe running and transitions ownership

#### amdgpu.seamless Parameter

```
amdgpu.seamless=1   -> Force seamless boot (skip pipe teardown during init)
amdgpu.seamless=0   -> Force full pipe teardown during init
amdgpu.seamless=-1  -> Auto (default): enabled if DCN >= 3.0.0 AND APU = true
```

**On Raphael (DCN 3.1.5 + APU), seamless defaults to AUTO = ENABLED.** If it's still hitting the optc31 timeout, either:
- Seamless path has a bug on DCN 3.1.5 specifically
- DMCUB state from EFI doesn't meet seamless adoption requirements
- Kernel 6.13 patch `391cea4fff00` is needed for seamless to actually work

#### DMCUB optimized_init_done Flag

DMCUB firmware sets `optimized_init_done` after BIOS golden initialization. If DMCUB firmware is too old/buggy, this flag may be incorrectly set, causing driver to skip necessary init.

**Check:** `grep "optimized_init_done" /var/log/syslog`

#### Preventing Firmware FB Device Creation

```bash
# Preferred: Prevent simpledrm from stealing card0 (surgical, targets simpledrm only)
initcall_blacklist=simpledrm_platform_driver_init

# Nuclear fallback: Prevent ALL firmware framebuffers (simpledrm, efifb, vesafb)
# initcall_blacklist=sysfb_init
```

### Complete Parameter Reference

#### GRUB Kernel Command Line Parameters

| Parameter | Default | Recommended | Effect on Display Handoff |
|---|---|---|---|
| `amdgpu.sg_display=0` | 1 (APU) | **0** | Forces contiguous VRAM for display FB, bypasses GART scatter/gather |
| `amdgpu.dcdebugmask=0x10` | 0 | **0x10** | Disables PSR -- reduces DCN complexity |
| `amdgpu.dcdebugmask=0x08` | 0 | Test | Disables DCN clock gating -- keeps OPTC registers accessible |
| `amdgpu.dcdebugmask=0x18` | 0 | Test | Combines 0x10 (PSR off) + 0x08 (clock gating off) |
| `amdgpu.seamless=1` | auto | **CAUTION** | Forces seamless boot -- skips pipe teardown. **Crashed with DMCUB 0.0.15.0** (5 ring timeouts in runLog-00). Only re-test after firmware update to >= 0.0.224.0. |
| `amdgpu.seamless=0` | auto | **Recommended (pre-firmware-fix)** | Forces full pipe teardown -- stable boots (boot-13/14) used this value |
| `amdgpu.ppfeaturemask=0xfffd7fff` | varies | **0xfffd7fff** | Disables GFXOFF via feature mask (bit 15) |
| `amdgpu.dpm=0` | 1 | Last resort | Disables DPM entirely -- max stability |
| `amdgpu.lockup_timeout=30000` | 10000 | Test | 30s ring timeout -- prevents reset during slow DMCUB init |
| `amdgpu.gpu_recovery=1` | 1 | **1** | Enables GPU reset on hang (default) |
| `amdgpu.reset_method=1` | -1 (auto, defaults to MODE2 on Raphael) | ~~1~~ **NOT SUPPORTED** | MODE0 was intended to reset ALL IP blocks including DCN/DCHUB, but kernel 6.17 rejects it on Raphael APU: "Specified reset method:1 isn't supported, using AUTO instead." |
| `amdgpu.vm_fragment_size=9` | varies | **9** | 2MB page table fragments -- reduces TLB pressure |
| `nvidia-drm.modeset=1` | 0 | **1** | Enables NVIDIA kernel modesetting |
| `nvidia-drm.fbdev=1` | 0 | **1** | Enables NVIDIA DRM framebuffer device |
| `pcie_aspm=off` | on | **off** | Prevents Xid 79 link loss on RTX 4090 |
| `iommu=pt` | off | **pt** | IOMMU passthrough for GPU compute |
| `processor.max_cstate=1` | varies | **1** | Prevents deep idle causing link drops |
| `amd_pstate=active` | passive | **active** | AMD P-State EPP driver |
| `modprobe.blacklist=nouveau,nova_core` | none | **nouveau,nova_core** | Prevents open-source NVIDIA drivers (nouveau + nova_core) |
| `nogpumanager` | n/a | **set** | Disables Ubuntu's gpu-manager |
| `initcall_blacklist=simpledrm_platform_driver_init` | n/a | **set** | Prevents simpledrm from stealing card0 -- amdgpu gets card0 for display. Black screen until amdgpu loads (acceptable for workstation). |
| `initcall_blacklist=sysfb_init` | n/a | Nuclear fallback | Prevents ALL firmware framebuffers (simpledrm, efifb, vesafb) -- more aggressive than simpledrm-only |

#### dcdebugmask Bitmask Reference

| Bit | Hex | Effect |
|---|---|---|
| 0 | 0x01 | Disable pipe split (single pipe mode) |
| 1 | 0x02 | Disable DCC (Delta Color Compression) |
| 2 | 0x04 | Disable stutter (display self-refresh) |
| 3 | 0x08 | **Disable DCN clock gating** -- keeps OPTC registers powered |
| 4 | 0x10 | **Disable PSR** (Panel Self Refresh) |
| 5 | 0x20 | Force full reprogramming on modeset |

#### modprobe.d Parameters

| Parameter | Value | Purpose |
|---|---|---|
| `options amdgpu sg_display=0` | 0 | Redundant with GRUB (belt-and-suspenders) |
| `options amdgpu ppfeaturemask=0xfffd7fff` | 0xfffd7fff | Feature control (GFXOFF bit) |
| `options amdgpu gpu_recovery=1` | 1 | Enable GPU reset |
| ~~`options amdgpu reset_method=1`~~ | ~~1~~ | **REMOVED: MODE0 NOT SUPPORTED on Raphael APU.** Kernel 6.17 rejects it. AUTO (MODE2) is used instead. |
| `options amdgpu dc=1` | 1 | Enable Display Core (required for Raphael) |
| `options amdgpu audio=1` | 1 | Enable HDMI/DP audio |

### Firmware Installation Methods

**Option A: Ubuntu package update** (simplest)
```bash
sudo apt update
apt policy linux-firmware
sudo apt install --only-upgrade linux-firmware
```

**Option B: Manual firmware from git** (precise version control)
```bash
cd /tmp
git clone --depth 1 https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git
# Or for a specific tag:
git clone --depth 1 --branch 20250305 https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git

sudo cp linux-firmware/amdgpu/dcn_3_1_5_dmcub.bin /lib/firmware/amdgpu/
sudo cp linux-firmware/amdgpu/psp_13_0_5_toc.bin /lib/firmware/amdgpu/
sudo cp linux-firmware/amdgpu/psp_13_0_5_ta.bin /lib/firmware/amdgpu/
sudo cp linux-firmware/amdgpu/psp_13_0_5_asd.bin /lib/firmware/amdgpu/
sudo cp linux-firmware/amdgpu/gc_10_3_6_*.bin /lib/firmware/amdgpu/

# CRITICAL: Compress to .bin.zst and remove bare .bin
# Ubuntu 24.04 has CONFIG_FW_LOADER_COMPRESS_ZSTD=y — kernel loads .bin.zst FIRST.
# If both .bin and .bin.zst exist, the .bin is IGNORED.
for f in dcn_3_1_5_dmcub psp_13_0_5_toc psp_13_0_5_ta psp_13_0_5_asd; do
  sudo zstd -f /lib/firmware/amdgpu/${f}.bin -o /lib/firmware/amdgpu/${f}.bin.zst
  sudo rm -f /lib/firmware/amdgpu/${f}.bin
done
for f in /lib/firmware/amdgpu/gc_10_3_6_*.bin; do
  [ -f "$f" ] && sudo zstd -f "$f" -o "${f}.zst" && sudo rm -f "$f"
done

sudo update-initramfs -u -k all
```

**Option C: Ubuntu noble-proposed** (beta SRU)
```bash
sudo add-apt-repository --enable-source "deb http://archive.ubuntu.com/ubuntu noble-proposed main restricted"
sudo apt update
apt policy linux-firmware
sudo apt install linux-firmware
sudo add-apt-repository --remove "deb http://archive.ubuntu.com/ubuntu noble-proposed main restricted"
```


---

## BIOS Configuration (Quick Reference)

### TIER 1 -- MUST SET

| Setting | Path | Value |
|---------|------|-------|
| Integrated Graphics | Advanced > NB Configuration | **Force** |
| IGFX Multi-Monitor | Advanced > NB Configuration | **Enabled** |
| Primary Video Device | Advanced > NB Configuration | **IGFX Video** |
| UMA Frame Buffer Size | Advanced > NB Configuration (or Advanced > AMD CBS > NBIO > GFX Configuration) | **2G** (or **4G** for testing) |
| GFXOFF | Advanced > AMD CBS > NBIO > SMU Common Options | **Disabled** (confirmed) |
| Above 4G Decoding | Advanced > PCI Subsystem Settings | **Enabled** |
| Re-Size BAR | Advanced > PCI Subsystem Settings | **Enabled** |
| SMEE (SME) | Advanced > AMD CBS > CPU Common Options | **Disabled** |
| TSME | Advanced > AMD CBS > UMC > DDR Security | **Disabled** |
| IOMMU | Advanced > AMD CBS (root level) | **Enabled** |
| CSM | Boot > CSM Configuration | **Disabled** |
| OS Type | Boot > Secure Boot > OS Type | **Other OS** |

### TIER 2 -- STABILITY

| Setting | Path | Value |
|---------|------|-------|
| PCIEX16_1 Link Mode | Advanced | **Gen 4** |
| Native ASPM | Advanced > Onboard Devices Configuration | **Enabled** |
| CPU PCIE ASPM Mode | Advanced > Onboard Devices Configuration | **Disabled** |
| Global C-State Control | Advanced > AMD CBS (root level) | **Disabled** |
| Power Supply Idle Control | Advanced > AMD CBS > CPU Common Options | **Typical Current Idle** |
| D3Cold Support | Advanced > AMD PBS > Graphics Features | **Disabled** |
| fTPM | Advanced > AMD fTPM Configuration | **Disabled** |
| Fast Boot | Boot > Boot Configuration | **Disabled** |
| Clock Spread Spectrum | Extreme Tweaker | **Disabled** |
| ErP Ready | Advanced > APM Configuration | **Disabled** |
| Restore AC Power Loss | Advanced > APM Configuration | **Power On** |

### TIER 3 -- ML PERFORMANCE

| Setting | Path | Value |
|---------|------|-------|
| EXPO Profile | Extreme Tweaker > AI Overclock Tuner | **EXPO II** |
| FCLK | Advanced > AMD Overclocking | **2000 MHz** |
| Core Performance Boost | Extreme Tweaker | **Enabled** |
| SVM (AMD-V) | Advanced > CPU Configuration | **Enabled** |
| SR-IOV | Advanced > PCI Subsystem Settings | **Enabled** |
| ACPI SRAT L3 NUMA | Advanced > AMD CBS > DF Common Options | **Disabled** |

---

## Post-Fix Verification Checklist

```bash
# 1. linux-firmware version (should be >= 20240709, ideally >= 20250305)
dpkg -l linux-firmware

# 2. DMUB firmware loaded successfully
dmesg | grep "DMUB"
# Expected: "Loading DMUB firmware via PSP: version=0x0500FF00" (or higher)
# Should appear only ONCE (not 3-4 times = reset loop)

# 3. No firmware file conflicts
ls -la /lib/firmware/amdgpu/dcn_3_1_5_dmcub.bin*
ls -la /lib/firmware/amdgpu/psp_13_0_5_toc.bin*

# 4. No optc31/optc1 REG_WAIT timeouts
dmesg | grep -i "REG_WAIT timeout"

# 5. No ring timeouts
dmesg | grep -i "ring.*timeout"

# 6. No GPU resets
dmesg | grep -i "GPU reset"

# 7. Card assignment (AMD MUST be card0)
for card in /sys/class/drm/card[0-9]; do
    vendor=$(cat "$card/device/vendor" 2>/dev/null)
    driver=$(basename $(readlink "$card/device/driver") 2>/dev/null)
    echo "$(basename $card): vendor=$vendor driver=$driver"
done

# 8. Display on AMD
glxinfo | grep "OpenGL renderer"
# Expected: AMD Radeon Graphics (raphael, LLVM ...)

# 9. sg_display disabled
cat /sys/module/amdgpu/parameters/sg_display
# Expected: 0

# 10. NVIDIA headless
nvidia-smi --query-gpu=name,display_active,display_mode --format=csv
# Expected: NVIDIA GeForce RTX 4090, Disabled, Disabled

# 11. Mutter KMS thread type
cat /proc/$(pgrep -f gnome-shell)/environ 2>/dev/null | tr '\0' '\n' | grep MUTTER
# Expected: MUTTER_DEBUG_KMS_THREAD_TYPE=user

# 12. Kernel version
uname -r
# Expected: 6.17.x-generic (HWE)
```

---

## Diagnostic Collection

```bash
# Quick check
dmesg | grep -i -E 'REG_WAIT|ring.*timeout|GPU reset|DMUB|optc' | tail -20

# Full diagnostic (run from repo root script/ directory)
sudo bash script/diagnostic-full.sh
# Creates runLog-XX/ with 13 subdirectories
```

---

## Documentation Gaps & Inconsistencies

Review ALL existing documentation and flag:
- Settings mentioned in one doc but not another
- BIOS paths that differ between docs (e.g., GFXOFF path varies across files)
- Kernel parameters that appear in GRUB but not modprobe.d (or vice versa)
- Scripts that set values different from what the docs recommend
- Firmware versions that don't match what the logs show
- Any assumptions that aren't backed by evidence

**Known inconsistencies identified so far:**
- `sg_display` removed during Test A/B but still referenced in docs as recommended
- `ppfeaturemask` value reads `0xfff7bfff` at runtime but `0xfffd7fff` is documented
- Firmware `.bin` files manually placed but `.bin.zst` files from package are what kernel loads
- modprobe.d and GRUB cmdline had conflicting parameter sets from test iterations
- BIOS GFXOFF path varies: some docs say `AMD CBS > NBIO > SMU Common Options`, others differ


---

## Key Upstream References

- **[drm/amd #5073](https://gitlab.freedesktop.org/drm/amd/-/work_items/5073)** -- EXACT match: Raphael iGPU optc31 timeout + ring timeout + MODE2 reset loop (OPEN)
- **[drm/amd #3377](https://gitlab.freedesktop.org/drm/amd/-/work_items/3377)** -- Raphael optc1_wait_for_state black screen (OPEN)
- **[drm/amd #3583](https://gitlab.freedesktop.org/drm/amd/-/work_items/3583)** -- Ryzen 9 9950X, optc31_disable_crtc + DMCUB error
- **[drm/amd #4433](https://gitlab.freedesktop.org/drm/amd/-/work_items/4433)** -- Ryzen 5 8600G, optc314_disable_crtc REG_WAIT timeout
- **[drm/amd #3006](https://gitlab.freedesktop.org/drm/amd/-/issues/3006)** -- UMA 512M causes gfx ring timeouts
- **[Debian #1057656](https://bugs-devel.debian.org/cgi-bin/bugreport.cgi?bug=1057656)** -- DMCUB firmware breaks Raphael display (FIXED in firmware 20240709)
- **[NixOS #418212](https://github.com/nixos/nixpkgs/issues/418212)** -- DMCUB 0.1.14.0 load failure on Raphael
- **[Kernel commit a878304276b8](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=a878304276b8)** -- bypass ODM before CRTC off (fixes optc31 timeout)
- **[Kernel commit c707ea82c79d](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=c707ea82c79d)** -- Ensure DMCUB idle before reset (100->100k iterations)
- **[Kernel commit 391cea4fff00](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=391cea4fff00)** -- Skip disable CRTC on seamless bootup
- **[Patch: Wait until OTG enable state cleared](https://www.mail-archive.com/amd-gfx@lists.freedesktop.org/msg126781.html)** -- Fixes OTG disable/enable race

---

## File Map

```
/Volumes/Untitled/UbuntuAutoInstall/
├── CLAUDE.md                           # This file — AI context + quick reference
├── COMPATIBILITY-MATRIX.md             # Technical firmware/kernel/compositor research
├── DIAGNOSTIC-REFERENCE.md             # All variant test run data (A/B/C/H)
├── INSTALLATION-PROMPT.md              # Full phased install guide
├── MITIGATION-RESEARCH.md              # All mitigation strategies
├── OS-DECISION-MATRIX.md               # OS scoring (Ubuntu 24.04.4 LTS recommended)
├── OS-CROSSCUTTING-CONCERNS.md         # NVIDIA/CUDA cross-distro support matrix
├── GNOME-MUTTER-HARDENING.md           # GNOME tuning (post-firmware-fix)
├── WAYLAND-COMPOSITOR-RESEARCH.md      # Wayland compositor risk ranking
├── X11-COMPOSITOR-RESEARCH.md          # X11/AccelMethod analysis
├── RESEARCH-PROMPT.md                  # ARCHIVED: original research spec
├── VARIANT-COMPARISON.html             # Interactive variant test results dashboard
├── COMPOSITOR-RESEARCH.html            # Compositor DCN interaction research
├── firmware/
│   └── amdgpu/                         # AMD Raphael firmware blobs (DMUB 0x05002000 confirmed)
├── os/ubuntu/
│   ├── autoinstall.yaml                # Pre-variant base config (Ubuntu 24.04.4)
│   ├── autoinstall-stable.yaml         # Pre-variant fallback (24.04.1 + HWE overlay)
│   └── variants/
│       ├── autoinstall-H-modern-desktop.yaml   # PRODUCTION TARGET (dual-GPU, XFCE+labwc)
│       ├── autoinstall-A-display-only.yaml     # Test: display-only, no firmware
│       ├── autoinstall-B-display-firmware.yaml # Test: firmware fix + glamor
│       ├── autoinstall-C-full-stack.yaml       # Test: B + NVIDIA
│       ├── autoinstall-D-labwc-pixman.yaml     # Wayland stacking WM
│       ├── autoinstall-E-sway-pixman.yaml      # Wayland tiling WM
│       ├── autoinstall-F-modern-xfce.yaml      # Modern X11 desktop
│       ├── autoinstall-G-gnome-full.yaml       # GNOME + NVIDIA (testing)
│       ├── autoinstall-I-gnome-wayland-extended.yaml  # Extended GNOME testing
│       └── README.md                   # Variant decision guide + testing workflow
└── script/
    ├── 00-verify-bios-prerequisites.sh # Pre-flight BIOS checks
    ├── 01-first-boot-display-fix.sh    # Phase 1: AMD iGPU stabilization
    ├── 02-install-nvidia-driver.sh     # Phase 2: NVIDIA 595 headless
    ├── 03-configure-display.sh         # Phase 3: X11 + udev + services
    ├── 04-update-firmware-20251021.sh  # Online firmware update (git clone)
    ├── 05-multiboot-amdgpu-diag.sh     # Multi-boot comparison collector
    ├── 06-recovery-fix.sh              # Recovery mode fixes
    ├── 07-fix-xorg-no-nvidia.sh        # Fix X11 crash from xorg.conf/nvidia mismatch
    ├── diagnostic-full.sh              # Comprehensive diagnostic (use this)
    ├── diagnostic-collect.sh           # Basic diagnostic (smaller output)
    ├── validate-autoinstall.sh         # Validate autoinstall YAML syntax
    ├── apply-nvidia-switch.sh          # Switch display GPU to RTX 4090
    ├── 01-rollback.sh / 02-rollback.sh / 03-rollback.sh / 99-rollback.sh
    ├── BIOS-CHECKLIST.md               # 3-tier BIOS settings (27 settings)
    ├── archive/                        # Superseded test scripts
    ├── verification/                   # Post-install verification
    └── diag-v2/                        # Enhanced diagnostics + firmware USB tools
```

---

## Autoinstall Workflow — Validation Required Before Every Commit/Push

**MANDATORY:** Run `./script/validate-autoinstall.sh` before committing or pushing any
change to `os/ubuntu/variants/autoinstall-*.yaml`. Do not commit if the script reports
`OVERALL: FAIL`.

```bash
# Run before every commit touching autoinstall variants:
./script/validate-autoinstall.sh

# Run against a single file during development:
./script/validate-autoinstall.sh --file os/ubuntu/variants/autoinstall-H-modern-desktop.yaml

# Verbose output (shows which checks matched):
./script/validate-autoinstall.sh --verbose
```

### What the validator checks

| Check | Why it matters |
|-------|----------------|
| YAML syntax | Unparseable YAML silently falls back to defaults — install proceeds wrongly |
| PATH export before curl/wget | Installer shell has minimal PATH; curl fails with "not found" without it |
| USB mount points (6 required) | Old paths (/cdrom, /media/cdrom, /mnt/usb) don't match modern Ubuntu live USB |
| INSTALLED counter placement | Counter outside if-success branch counts zstd failures as successful installs |
| lsinitramfs kernel detection | `uname -r` returns the **installer** kernel; lsinitramfs checks the wrong initrd |
| BLOBS list non-empty | Missing blobs = missing firmware = DMCUB 0x05000F00 remains = ring gfx timeouts |
| Colon-space in bash -c scalars | `: ` in a single-line YAML list item causes "mapping values not allowed" parse error |
| exec_always shell builtins | `exec_always export VAR=x` silently fails — builtins are not executables |
| update-initramfs/grub chroot | Must use `curtin in-target --`; bare calls affect the live installer, not /target |

### Git hooks (auto-runs on push)

The pre-push hook at `.githooks/pre-push` runs the validator automatically.
Enable it once after cloning:

```bash
git config core.hooksPath .githooks
```
