> **STATUS: ACTIVE** — Full phased install guide. Use Variant H (`os/ubuntu/variants/autoinstall-H-modern-desktop.yaml`) for production installs.

# Master Installation Prompt: Dual-GPU ML Workstation — Full Setup from Bare Metal to Verified ML Stack

## Purpose

This prompt directs Claude to generate and execute a **complete, phased installation** of an ML workstation with dual GPUs: AMD Raphael iGPU (display) + NVIDIA RTX 4090 (headless compute). Every phase produces **executable scripts with full logging**, **verification scripts that inspect low-level state**, and **exhaustive debugging prompts** for when things go wrong.

The user may install **any** of the recommended OS candidates (Ubuntu 24.04.4 LTS, Fedora 43 XFCE Spin, Arch Linux, or Pop!_OS 24.04). The scripts must detect the OS at runtime and branch accordingly.

> **Cross-References:**
> - [OS-DECISION-MATRIX.md](OS-DECISION-MATRIX.md) — Full research-backed OS comparison with weighted scoring, known bugs, and decision flowchart
> - [COMPATIBILITY-MATRIX.md](COMPATIBILITY-MATRIX.md) — Technical research findings: crash mechanism, DMCUB firmware history, kernel patch table, documentation gaps
> - [OS-CROSSCUTTING-CONCERNS.md](OS-CROSSCUTTING-CONCERNS.md) — Cross-OS analysis: container toolkit, CUDA certification, Docker/Podman, firmware update mechanisms, DKMS reliability, initramfs tools
> - [RESEARCH-PROMPT.md](RESEARCH-PROMPT.md) — Original research specification

---

## Fixed Hardware Specification

| Component | Value |
|-----------|-------|
| CPU | AMD Ryzen 9 7950X (Zen 4, Raphael, Family 25h Model 61h) |
| iGPU | AMD Radeon Graphics — RDNA2, GC 10.3.6, DCN 3.1.5, 2 CUs |
| dGPU | NVIDIA GeForce RTX 4090 (AD102, 16384 CUDA, 24 GB GDDR6X) |
| Board | ASUS ROG Crosshair X670E Hero (X670E, AM5) |
| BIOS | 3603 (AGESA ComboAM5 PI 1.3.0.0a) |
| RAM | 2x 32 GB DDR5-6000 CL30 (EXPO) |
| PSU | 1000W single-rail |
| Storage | NVMe (assume `/dev/nvme0n1`) |
| Display | HDMI-A-1 (from iGPU), 1920x1080@60 minimum |

**Architecture goal**: iGPU handles ALL display/desktop. dGPU is 100% headless CUDA/ML compute. Zero display processes on NVIDIA.

---

## The Core Problem Being Solved

The system suffers an **intermittent crash loop** on boot:

```
[  6.1s] REG_WAIT timeout — optc31_disable_crtc line:136    ← DCN register stall
[  8.0s] REG_WAIT timeout — optc1_wait_for_state            ← Cascading OTG failure
[ 18.5s] ring gfx_0.0.0 timeout (gnome-shell)               ← GFX ring hangs
[ 19.0s] MODE2 GPU reset                                     ← Resets GFX only, NOT DCN
[ 31.3s] ring gfx_0.0.0 timeout (repeat)                    ← DCN still broken → loop
```

### The Crash Requires TWO Conditions

1. **optc31_disable_crtc timeout at boot** (~6s) — stalls DCN pipeline during EFI→amdgpu handoff
2. **GFX ring submissions from compositor** — gnome-shell floods the ring, which hangs on stalled DCN

**If EITHER condition is removed, the crash loop breaks:**
- Fix condition 1: update DMCUB firmware + kernel patches → DCN doesn't stall
- Remove condition 2: use XFCE (zero GPU ring submissions via XRender) → even if DCN stalls, no ring timeout triggers

> See [COMPATIBILITY-MATRIX.md §1](COMPATIBILITY-MATRIX.md#1-the-crash-loop--mechanistic-analysis) for full register-level analysis.

### Why MODE2 Reset Cannot Fix This

The GPU IP block routing on Raphael:
```
GCHUB  ← GC (Graphics Compute) + SDMA   ← MODE2 resets THESE
MMHUB  ← VCN + JPEG + VPE               ← MODE1 resets THIS
DCHUB  ← DCN (Display Core Next)         ← NOT TOUCHED BY MODE2
```

**MODE2** (`reset_method=3`, default): Resets only GC/SDMA. DCN remains broken → infinite crash loop.
**MODE0** (`reset_method=1`): Full ASIC reset of ALL IP blocks including DCN/DCHUB. **TESTED AND NOT SUPPORTED on Raphael APU** — kernel 6.17 rejects it: "Specified reset method:1 isn't supported, using AUTO instead." The hardware/firmware does not implement MODE0 for this APU.

### Root Causes (Ranked by Evidence)

1. **DMCUB firmware critically outdated** — Ubuntu SRU status for DCN 3.1.5 DMCUB is AMBIGUOUS: SRU 0ubuntu2.22 (Jan 2026) mentions "DMCUB firmware updates" but the changelog never explicitly names `dcn_3_1_5_dmcub.bin`. Currently loaded version `0x05000F00` (0.0.15.0) predates all known fixes. Manual verification + update required.
   > **Version correction:** Earlier drafts cited `0x05002F00` (0.0.47.0). Actual logs show `0x05000F00` (0.0.15.0) — even older than previously thought. Version encoding: `0x05XXYYZZ` where `0x0F` = 15, not 47 (`0x2F`).
   > **UPDATE (2026-03-30):** Firmware upgraded to 0x05002000 via install-firmware.sh — confirmed stable with glamor on 8 consecutive boots. All 8 autoinstall variants now include firmware download + initramfs hook.
2. **Kernel 6.8 missing DCN31 patches** — ODM bypass (6.10+), OTG state wait (6.12+), DMCUB idle fix (6.15+). Need kernel >= 6.14, ideally 6.17+.
3. **EFI framebuffer handoff race** — simpledrm steals card0; amdgpu gets card1; compositor targets wrong device.
4. **MODE2 reset doesn't fix DCN** — MODE2 only resets GC/SDMA via GCHUB. DCN goes through DCHUB, untouched. `reset_method=1` (mode0) would theoretically reset all IP blocks, but is **TESTED AND NOT SUPPORTED on Raphael APU** (kernel rejects it).
5. **GNOME/Mutter GFX ring pressure** — gnome-shell floods GFX ring, which hangs on stalled DCN. XFCE/xfwm4 uses zero GPU acceleration (XRender), avoiding the trigger entirely.
6. **Mutter RT thread SIGKILL** — Mutter 46.x KMS page-flip thread gets SIGKILL'd when amdgpu is slow on page flip.
7. **Scatter/gather display** — `sg_display=1` (default) causes GART/TLB inconsistency during handoff.

### Key Research Findings

- **Upstream bug [drm/amd #5073](https://gitlab.freedesktop.org/drm/amd/-/work_items/5073)** — EXACT hardware match. Status: **OPEN** upstream as of 2026-03-28; **our system resolved** via DMUB firmware upgrade to 0x05002000 (2026-03-30).
- **GNOME crash is cross-distro** — Fedora 43, Ubuntu 25.04, Ubuntu 24.04 all affected. Switching distro alone does NOT fix it.
- **NVIDIA 595.58.03**: Open modules DEFAULT, `nvidia-drm.modeset=1` DEFAULT, `NVreg_EnableGpuFirmware=1` REQUIRED. `nvidia-headless-595-server` package does NOT exist (naming changed at branch 590).
- **`initcall_blacklist=simpledrm_platform_driver_init`** — confirmed fix for card ordering (Arch forums).

### DMCUB Safe Firmware Targets

| Strategy | linux-firmware Tag | DMCUB Version | Risk | Use When |
|----------|-------------------|---------------|------|----------|
| **Conservative** | `20250305` | 0.0.255.0 | Lowest | Manual firmware on Ubuntu — safest choice |
| **YAML variants (confirmed)** | `20250509` | **0.0.32.0 (0x05002000)** | Low | Used by all autoinstall variants (A–I); confirmed delivers working DMCUB on this hardware |
| **script/04 target (sweet spot)** | `20251021` | ~0.0.32.x | Low | Post-fix, pre-regression; used by `04-update-firmware-20251021.sh` |
| **AVOID — REGRESSION** | `20251111` | unknown | **HIGH** | Breaks Raphael — confirmed regression; also affects `20251125` |
| **AVOID — REGRESSION** | `20251125` | unknown | **HIGH** | Same regression as 20251111; do not use |
| **Latest stable** | `20260309` | ~0.1.40+ | Low (post-MR#587) | Fedora/Arch ship this by default |
| **AVOID** | `20250613` | 0.1.14.0 | **HIGH** | [NixOS #418212](https://github.com/nixos/nixpkgs/issues/418212): "failed to load ucode DMCUB(0x3D)" |
| **Currently loaded (stock Ubuntu)** | `20240318` | 0.0.15.0 | **CRITICAL** | Predates ALL fixes — must be updated |

> See [COMPATIBILITY-MATRIX.md §2](COMPATIBILITY-MATRIX.md#2-dmcub-firmware-analysis) for complete firmware version history and SRU analysis.

### Known Documentation Gaps

These inconsistencies exist in the `setup/` directory docs. This installation prompt supersedes them:
- `sg_display` was removed by Test A iterations but is CRITICAL (must be `0`)
- `ppfeaturemask` running value `0xfff7bfff` ≠ documented `0xfffd7fff` (GFXOFF bit wrong)
- `NVreg_EnableGpuFirmware=0` in one BIOS doc — INCORRECT, must be `1` for NVIDIA 595 open modules
- `nvidia-drm.modeset=1` in GRUB — now DEFAULT in 595 (harmless to keep explicit)
- `amdgpu.reset_method=1` (mode0) was tested and is NOT SUPPORTED on Raphael APU — kernel 6.17 rejects it, falls back to AUTO (mode2)

### Open Questions (Verify on Live System)

| # | Question | Command | Priority |
|---|----------|---------|----------|
| 1 | Did Ubuntu SRU deliver working DMCUB for DCN315? | `dmesg \| grep "DMUB firmware.*version"` | **HIGH** |
| 2 | ~~Does `reset_method=1` (mode0) actually reset DCN on Raphael APU?~~ | **ANSWERED: NO.** Kernel 6.17 rejects mode0 on Raphael: "Specified reset method:1 isn't supported, using AUTO instead." | **RESOLVED** |
| 3 | Does XFCE avoid crash loop even WITHOUT firmware fix? | Install XFCE, boot old firmware, check dmesg | MEDIUM |
| 4 | What is actual UMA Frame Buffer Size in BIOS? | Visual BIOS check | MEDIUM |
| 5 | Does `amdgpu.seamless=1` skip the optc31 path entirely? | Boot test | LOW |

---

## OS Candidates

The scripts MUST support all four. Each phase detects the OS and adapts.

| OS | Kernel | Firmware | Compositor | ML Maturity | Score | Notes |
|----|--------|----------|-----------|-------------|-------|-------|
| **Ubuntu 24.04.4 LTS** | 6.17 HWE | Manual DMCUB update required | XFCE (install) | 5/5 | **8.65/10** | **PRIMARY** — best ML ecosystem, 5yr support |
| **Fedora 43 XFCE Spin** | 6.19 | **20260309** (out-of-box) | XFCE (native) | 3/5 | 7.35/10 | Best firmware out-of-box; CUDA 13.2 now official; 9mo lifecycle |
| **Arch Linux** | 6.19 + 6.18 LTS | **20260309** | XFCE (install) | 3/5 | 7.65/10 | CUDA+cuDNN in official repos; rolling risk |
| **Pop!_OS 24.04** | 6.18-6.19 | 20250317+sys76 | COSMIC (Wayland) | 3/5 | 7.60/10 | Avoids Mutter; COSMIC v1.0 risks |

> See [OS-DECISION-MATRIX.md](OS-DECISION-MATRIX.md) for full weighted scoring, per-OS deep analysis, and decision flowchart.

### Compositor Risk Matrix

This directly informs Phase 3 (Display Stack) decisions:

| Compositor | GPU Backend | GFX Ring Pressure | Crash Risk | Recommendation |
|-----------|------------|-------------------|------------|----------------|
| **GNOME (Mutter)** | OpenGL | **HIGH** | **CRASHES** | Do NOT use |
| **XFCE (compositing OFF)** | None (XRender) | **ZERO** | **SAFEST** | **PRIMARY choice** |
| **XFCE (compositing ON)** | XRender (CPU) | VERY LOW | SAFE | Enable after stability confirmed |
| **COSMIC (cosmic-comp)** | OpenGL ES | LOW-MEDIUM | GOOD | Pop!_OS default; still uses GFX ring |
| **Sway (wlroots)** | Minimal GL | LOW | GOOD | Wayland fallback option |
| **KDE Plasma (KWin)** | OpenGL | MEDIUM | MEDIUM | Not recommended |
| **i3wm** | None | ZERO | **SAFEST** | Tiling WM alternative |

---

## Phased Installation Plan Overview

```
PHASE 0: BIOS Configuration (manual, pre-OS)
PHASE 1: OS Installation (manual, per chosen OS)
PHASE 2: Post-Install Foundation (firmware, kernel, boot config)
PHASE 3: Display Stack (iGPU driver, compositor, display config)
PHASE 4: NVIDIA Compute Stack (driver, CUDA, cuDNN, containers)
PHASE 5: ML Framework Stack (PyTorch, Docker GPU, venv, monitoring)
PHASE 6: Stability Validation (multi-boot, stress, thermal)
PHASE 7: Post-Stability Maintenance (kernel freeze, update strategy)
```

Each phase contains:
- **Installation script** with full logging, error trapping, rollback hooks
- **Verification script** that checks low-level state exhaustively
- **Reboot checkpoint** with pre/post comparison
- **Debugging CLAUDE.md** generated on failure from collected logs

---

## Output Requirements

For EVERY script generated:

### Script Requirements

1. **OS detection at the top** — detect Ubuntu/Fedora/Arch/Pop!_OS and branch accordingly
2. **Root check** — exit if not root (or not sudoable)
3. **Timestamped logging** — every command logged to `$LOG_DIR/phase-XX-install-YYYYMMDD-HHMMSS.log` with both stdout and stderr captured
4. **`set -euo pipefail`** at the top — fail on any error
5. **Error trap** — on ERR, dump last 50 lines of log, system state, and suggest next steps
6. **Idempotency** — safe to re-run; skip steps already completed (check before acting)
7. **Backup before modify** — before changing ANY config file, copy to `$BACKUP_DIR/` with timestamp
8. **Dry-run mode** — `--dry-run` flag that prints what WOULD happen without doing it
9. **Rollback script** — each install script generates a matching `rollback-phase-XX.sh`
10. **Pre-flight checks** — at the top, verify prerequisites (packages, kernel version, disk space, network)
11. **Checksum verification** — for any downloaded file (firmware, packages), verify SHA256
12. **Progress indicators** — numbered steps with `[N/TOTAL]` prefix
13. **Color-coded output** — GREEN=success, YELLOW=warning, RED=error, BLUE=info
14. **Summary at end** — table of what changed, what was backed up, what needs reboot

### Verification Script Requirements

1. **One verification per installation script** — named `verify-phase-XX.sh`
2. **Check EVERY setting** the install script touched — file existence, content, permissions, kernel params, module params, sysfs values
3. **Low-level inspection** — not just "is the package installed" but:
   - For firmware: check dmesg for loaded version string, compare to expected
   - For kernel: check `uname -r`, verify specific commit presence via `/proc/version` or `zcat /proc/config.gz`
   - For modules: check `lsmod`, `modinfo`, sysfs parameter values, `/sys/module/*/parameters/*`
   - For display: check DRM card assignment, connector status, framebuffer info via `/sys/class/drm/`
   - For NVIDIA: check `nvidia-smi`, GSP firmware load, Xid errors, persistence mode, compute mode
   - For CUDA: compile and run a vectorAdd sample, check runtime version, driver version match
4. **Cross-reference check** — verify GRUB/kernelstub config matches running cmdline, modprobe.d matches loaded params, initramfs contains expected firmware
5. **Output a JSON report** — `verify-phase-XX-report.json` with structured pass/fail per check
6. **Output a human-readable summary** — table with checkmark/X per item
7. **Exit code** — 0 if all checks pass, 1 if any CRITICAL check fails, 2 if WARN-only failures

### Reboot Checkpoint Requirements

For each phase that requires a reboot:

1. **Pre-reboot snapshot** — save to `$LOG_DIR/pre-reboot-phase-XX/`:
   - `uname -a`
   - `cat /proc/cmdline`
   - `dmesg > dmesg-pre.log`
   - `journalctl -b -0 > journal-pre.log`
   - `lsmod > lsmod-pre.txt`
   - All `/sys/module/amdgpu/parameters/*`
   - All `/sys/module/nvidia*/parameters/*` (if loaded)
   - `/sys/class/drm/card*/` device info
   - Package list: `dpkg -l | grep -E 'linux-|nvidia|mesa|firmware'` (Ubuntu/Pop!_OS), `rpm -qa | grep -E 'kernel|nvidia|mesa|firmware'` (Fedora), `pacman -Q | grep -E 'linux|nvidia|mesa|firmware'` (Arch)
   - Full boot config (GRUB or kernelstub)
   - Full modprobe.d contents
   - initramfs file list: `lsinitramfs` (Ubuntu/Pop!_OS), `lsinitrd` (Fedora), `lsinitcpio` (Arch)

2. **Post-reboot auto-check** — install a one-shot systemd service that runs on next boot:
   - Captures same state as pre-reboot
   - Diffs pre vs post
   - Checks for regression indicators: `REG_WAIT timeout`, `ring.*timeout`, `GPU reset`, `DMUB`, `Xid`
   - Writes `$LOG_DIR/post-reboot-phase-XX/reboot-diff.txt`
   - Disables itself after running

3. **Comparison script** — `compare-reboot-phase-XX.sh` that reads pre and post, highlights:
   - Kernel version change
   - Firmware version change
   - New dmesg errors
   - Parameter changes
   - Card ordering changes
   - Any new Xid or amdgpu errors

### Debugging CLAUDE.md Requirements

When a verification fails or a reboot produces errors:

1. **Generate `DEBUG-PHASE-XX.md`** in the project directory
2. Contents:
   - **Symptom**: exact error message from dmesg/journal/verify output
   - **Context**: which phase, which step, which OS, which kernel, which firmware
   - **Collected evidence**: relevant log excerpts (last 100 lines of dmesg around the error, full verify report)
   - **Differential analysis**: what changed between the last working state and current
   - **Root cause hypotheses** (ranked): based on the specific error pattern, reference the COMPATIBILITY-MATRIX.md findings
   - **Recommended fixes** (ranked): specific commands to try, with expected outcomes
   - **If fix fails**: escalation path (next hypothesis, parameter to try, fallback OS)
   - **References**: links to upstream bugs, patches, docs relevant to this specific failure
3. **Cross-reference with known patterns**:
   - If `REG_WAIT timeout optc31` → firmware version? kernel version? seamless parameter?
   - If `ring gfx_0.0.0 timeout` → which process? compositor or driver init?
   - If `GPU reset` → MODE2 or mode0? Did DCN reset?
   - If `Xid` → which Xid number? NVIDIA or amdgpu?
   - If `failed to load ucode` → firmware file exists? .bin vs .bin.zst conflict? initramfs rebuilt?
4. **Include a "paste this to Claude" block** — a self-contained prompt that includes the error, context, and asks for targeted debugging help

---

## PHASE 0: BIOS Configuration

### What to Generate

A **printable BIOS checklist** (markdown table) with exact navigation paths for the ASUS ROG Crosshair X670E Hero BIOS 3603.

### Settings to Configure

#### TIER 1 — MUST SET (display/GPU stability)

| Setting | Value | BIOS Path | Why |
|---------|-------|-----------|-----|
| Integrated Graphics | **Force** | Advanced > NB Configuration | Enable iGPU even with dGPU present |
| IGFX Multi-Monitor | **Enabled** | Advanced > NB Configuration | Allow both GPUs to initialize |
| Primary Video Device | **IGFX Video** | Advanced > NB Configuration | iGPU is primary display device |
| UMA Frame Buffer Size | **2G** | Advanced > NB Configuration | 512M causes page faults → gfx ring timeouts ([drm/amd #3006](https://gitlab.freedesktop.org/drm/amd/-/issues/3006)) |
| GFXOFF | **Disabled** | Advanced > AMD CBS > NBIO > SMU Common Options | Prevent iGPU power gating during display ops |
| Above 4G Decoding | **Enabled** | Advanced > PCI Subsystem Settings | Required for RTX 4090 24GB BAR |
| Re-Size BAR | **Enabled** | Advanced > PCI Subsystem Settings | Enables full BAR for RTX 4090 |
| IOMMU | **Enabled** | Advanced > AMD CBS (root level) | Required for `iommu=pt` passthrough |
| CSM | **Disabled** | Boot > CSM Configuration | Required for UEFI GOP (display handoff) |
| Secure Boot OS Type | **Other OS** | Boot > Secure Boot | Disables Secure Boot enforcement — eliminates DKMS signing failures. See [OS-CROSSCUTTING-CONCERNS.md §7](OS-CROSSCUTTING-CONCERNS.md#7-secure-boot-and-nvidia). |
| SMEE (SME) | **Disabled** | Advanced > AMD CBS > CPU Common Options | Memory encryption breaks GPU DMA |
| TSME | **Disabled** | Advanced > AMD CBS > UMC > DDR Security | Same as SMEE |

#### TIER 2 — STABILITY

| Setting | Value | BIOS Path | Why |
|---------|-------|-----------|-----|
| PCIEX16_1 Link Mode | **Gen 4** | Advanced | Force RTX 4090 to Gen4 (avoid link training issues) |
| Global C-State Control | **Disabled** | Advanced > AMD CBS (root level) | Prevent deep idle causing PCIe link drops |
| Power Supply Idle Control | **Typical Current Idle** | Advanced > AMD CBS > CPU Common Options | Stable power delivery |
| D3Cold Support | **Disabled** | Advanced > AMD PBS > Graphics Features | Prevent GPU from entering D3Cold state |
| fTPM | **Disabled** | Advanced > AMD fTPM Configuration | fTPM firmware stutter bug |
| Fast Boot | **Disabled** | Boot > Boot Configuration | Full POST needed for GPU init |
| Clock Spread Spectrum | **Disabled** | Extreme Tweaker | Clean clock signals |
| ErP Ready | **Disabled** | Advanced > APM Configuration | Prevent power-saving interference |
| Restore AC Power Loss | **Power On** | Advanced > APM Configuration | Auto-boot after power loss |

#### TIER 3 — ML PERFORMANCE

| Setting | Value | BIOS Path | Why |
|---------|-------|-----------|-----|
| EXPO Profile | **EXPO II** | Extreme Tweaker > AI Overclock Tuner | DDR5-6000 XMP |
| FCLK | **2000 MHz** | Advanced > AMD Overclocking | Match EXPO memory frequency |
| Core Performance Boost | **Enabled** | Extreme Tweaker | Full Zen 4 boost |
| SVM (AMD-V) | **Enabled** | Advanced > CPU Configuration | Virtualization for containers |
| SR-IOV | **Enabled** | Advanced > PCI Subsystem Settings | GPU SR-IOV support |
| Native ASPM | **Enabled** | Advanced > Onboard Devices | Let OS manage ASPM |
| CPU PCIE ASPM Mode | **Disabled** | Advanced > Onboard Devices | Prevent CPU-side ASPM |

### Verification

After saving BIOS settings, the Phase 2 script will verify visible settings via:
```bash
# Check IOMMU enabled
dmesg | grep -i "AMD-Vi: AMD IOMMUv2"
# Check Re-Size BAR
lspci -vvv -s $(lspci | grep NVIDIA | head -1 | cut -d' ' -f1) | grep -i "resize"
# Check SME/TSME disabled
dmesg | grep -i "SME\|TSME\|Memory Encryption"
# Check UMA allocation
dmesg | grep -i "VRAM\|UMA\|Framebuffer\|stolen"
# Check CSM disabled (UEFI boot)
[ -d /sys/firmware/efi ] && echo "UEFI boot: OK" || echo "LEGACY boot: FAIL — CSM still enabled"
```

### Debugging: BIOS Phase

If the system does not POST or boot after BIOS changes:
1. Clear CMOS (rear I/O button on X670E Hero)
2. Re-enter BIOS, apply TIER 1 only
3. If POST fails with TIER 1 only → test with UMA Frame Buffer = **Auto** instead of 2G
4. If GPU not detected → check PCIe slot seating, try Gen 3 instead of Gen 4
5. Document which setting caused the failure → file as `DEBUG-PHASE-00.md`

---

## PHASE 1: OS Installation

### What to Generate

A **decision matrix** and installation notes for each OS. The user chooses one. All subsequent phases auto-detect the OS.

### Ubuntu 24.04.4 LTS (PRIMARY RECOMMENDATION)

**Download:** Ubuntu 24.04.4 desktop ISO (ships with HWE kernel 6.17 + Mesa 25.2.8)
- URL: `https://releases.ubuntu.com/noble/`
- Fresh install from 24.04.4 ISO ships HWE kernel 6.17 + Mesa 25.2.8 **by default**. No separate HWE step needed.
- If 24.04.4 is not yet available, download 24.04.1 and Phase 2 will install HWE stack.

**Installation notes:**
- Use the HDMI output from the **motherboard** (iGPU), NOT the RTX 4090
- If installer hangs at desktop (gnome-shell crash): press `e` at GRUB, append `nomodeset` to linux line, boot, install from there
- Select "Minimal installation" to reduce GNOME surface area
- Enable third-party drivers during install (for NVIDIA)
- After install, switch to TTY (Ctrl+Alt+F3) IMMEDIATELY. **Do NOT log into GNOME** — it may crash loop.

**gpu-manager WARNING:** Ubuntu's `gpu-manager` service auto-rewrites GPU configuration on every boot, overriding manual dual-GPU config. MUST disable:
```bash
# Kernel param (in Phase 2): nogpumanager
# Belt-and-suspenders:
sudo systemctl disable gpu-manager.service
sudo systemctl mask gpu-manager.service
```

**Known Ubuntu bugs for this hardware:**

| Bug | Description | Impact |
|-----|-------------|--------|
| [LP #2033157](https://bugs.launchpad.net/ubuntu/+source/switcheroo-control/+bug/2033157) | iGPU/dGPU mix-up — NVIDIA incorrectly selected as primary | DIRECT |
| [LP #2130926](https://bugs.launchpad.net/ubuntu/+source/nvidia-graphics-drivers-580/+bug/2130926) | No display on dual GPU with NVIDIA 580 + AMD onboard | DIRECT |
| [LP #2141477](https://bugs.launchpad.net/ubuntu/+source/nvidia-graphics-drivers-580/+bug/2141477) | nvidia-dkms-580-open fails on HWE kernel 6.17.0-14 | MEDIUM (fixed in 580.95+) |
| [LP #2143294](https://bugs.launchpad.net/ubuntu/+source/linux/+bug/2143294) | Kernel 6.17 MES firmware timeout on Radeon 740M | LOW (different GPU arch) |

### Fedora 43 XFCE Spin

**Download:** Fedora 43 XFCE Spin ISO
- URL: `https://fedoraproject.org/spins/xfce/`
- **Install Fedora 43, NOT 42.** Fedora 42 EOLs May 13, 2026 (~6 weeks away). Fedora 43 has 9 months remaining (EOL December 2026).

**Installation notes:**
- Ships with kernel 6.19, linux-firmware 20260309 (DMCUB already fixed!), XFCE (no GNOME)
- After install: enable RPM Fusion for NVIDIA (see Phase 4)
- **NVIDIA driver lag:** RPM Fusion ships **580.119**, NOT 595. For 595, use NVIDIA `.run` installer (see Phase 4).
- **CUDA 13.2 now officially supports Fedora 43** (`fedora43` in CUDA support matrix). Install via `.run` file `--toolkit` only.
- **`nova_core` blacklisting:** Kernel 6.15+ includes the `nova` DRM module. Must blacklist BOTH `nouveau` AND `nova_core`.

**Known Fedora issues for Raphael:**

| Issue | Description | Impact |
|-------|-------------|--------|
| [UNUSABLE Gnome: REG_WAIT timeout](https://discussion.fedoraproject.org/t/166223) | optc32_disable_crtc on AMD+GNOME+Wayland | HIGH (XFCE spin avoids this) |
| [GNOME Shell crash + ring timeout](https://discussion.fedoraproject.org/t/149587) | ring gfx_0.0.0 timeout triggered by Brave/Chrome | HIGH (GNOME only) |
| [AMD laptop freezes on GNOME+Wayland](https://discussion.fedoraproject.org/t/150550) | Consistent hangs on AMD+GNOME | HIGH (GNOME only) |
| [Framework: critical amdgpu bugs 6.18/6.19](https://community.frame.work/t/79221) | Strix Point APU issues | LOW (different APU gen) |

### Arch Linux

**Download:** Latest Arch ISO
- URL: `https://archlinux.org/download/`

**Installation notes:**
- Use `archinstall` for **base system only** (disk, bootloader, networking, users). Manually configure GPU drivers, XFCE, and initramfs afterward.
  - archinstall has had reliability issues: Nov 2024 ISO broke pipewire step, v2.5.4 random lockups, disk encryption bugs. Use for base, configure GPU manually.
- `linux-firmware-amdgpu` 20260309 ships with fixed DMCUB — no manual firmware work needed
- **Dual kernel safety net:** Install BOTH `linux` (6.19) and `linux-lts` (6.18). If 6.19 breaks, boot 6.18.
- CUDA 13.2 + cuDNN 9.19 in **official repos**: `pacman -S cuda cudnn` — simplest of all distros.
- `nvidia-container-toolkit` also in official repos: `pacman -S nvidia-container-toolkit`

**mkinitcpio configuration (critical):**
```bash
# /etc/mkinitcpio.conf
MODULES=(amdgpu nvidia nvidia_modeset nvidia_uvm nvidia_drm)
# amdgpu FIRST — array order determines load order → claims card0
# When amdgpu is listed, mkinitcpio auto-includes ALL 400+ firmware blobs

HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block filesystems fsck)
# kms hook (default since mkinitcpio v33) handles early GPU KMS

sudo mkinitcpio -P  # Rebuild for all installed kernels
```

**Risk mitigation strategy:**
```bash
# 1. Dual kernels
sudo pacman -S linux linux-lts nvidia-open-dkms

# 2. Pin critical packages after stability confirmed
# /etc/pacman.conf: IgnorePkg = linux-firmware-amdgpu linux nvidia-open-dkms

# 3. Btrfs snapshots before every system update
sudo btrfs subvolume snapshot / /.snapshots/pre-update-$(date +%Y%m%d)

# 4. Check Arch news BEFORE updating
curl -s https://archlinux.org/feeds/news/ | head -50
```

**Known Arch issues for Raphael:**

| Issue | Description | Impact |
|-------|-------------|--------|
| [bbs #291457](https://bbs.archlinux.org/viewtopic.php?id=291457) | 7950X iGPU crashes, ring gfx_0.0.0 timeout | DIRECT |
| [bbs #306826](https://bbs.archlinux.org/viewtopic.php?id=306826) | System freeze with nvidia-open 575.x | MEDIUM (fixed in 595) |
| [L1T: 7950X iGPU instability](https://forum.level1techs.com/t/224035) | Blackouts/freezes on both Linux AND Windows | DIRECT (hardware-level) |
| [firmware 20250613 broke DMCUB](https://bbs.archlinux.org/viewtopic.php?pid=2247690) | Black screen on RX 9000 after firmware update | LOW (different GPU, same risk class) |

### Pop!_OS 24.04

**Download:** Pop!_OS 24.04 NVIDIA ISO
- URL: `https://pop.system76.com/`

**Installation notes:**
- Ships with COSMIC desktop (not GNOME — avoids Mutter crash modes)
- **COSMIC v1.0 (Dec 2025)**: Uses cosmic-comp (Rust/Smithay, OpenGL ES), NOT Mutter. No RT-priority KMS thread. But still uses GFX ring for compositing — ring timeouts are less likely but not impossible. Known bugs: [#1105](https://github.com/pop-os/cosmic-epoch/issues/1105) (kernel panic AMD+NVIDIA), [#2561](https://github.com/pop-os/cosmic-epoch/issues/2561) (EGL errors), [#3334](https://github.com/pop-os/cosmic-epoch/issues/3334) (panel crash after nvidia_drm semaphore failure).
- NVIDIA 580 driver built-in (upgrade to 595 in Phase 4 if needed)
- Kernel 6.18-6.19
- **`system76-power` GPU switching NOT supported on desktops.** Only for laptops. Manual PRIME configuration needed.

**CRITICAL: Pop!_OS uses `kernelstub`, NOT GRUB:**
```bash
# Pop!_OS uses systemd-boot with kernelstub for kernel parameters
# NOT /etc/default/grub + update-grub
sudo kernelstub -a "amdgpu.sg_display=0"
sudo kernelstub -a "amdgpu.dcdebugmask=0x10"
# ... (each parameter individually or space-separated)
```

---

## PHASE 2: Post-Install Foundation (firmware, kernel, boot config)

### Script: `phase-02-foundation.sh`

**This is the MOST CRITICAL phase.** It fixes the firmware, kernel, boot parameters, module config, and initramfs.

> **UPDATE (2026-03-30):** Firmware update to DMUB 0x05002000 is now automated in all 8 autoinstall variants via `install-firmware.sh`. The script downloads the firmware, compresses to `.bin.zst`, rebuilds initramfs, and verifies the blob is included. No manual firmware step is needed when using the autoinstall variants.

#### Target Firmware Versions

| Blob | Minimum Safe | Conservative Target | How to Check |
|------|-------------|---------------------|-------------|
| DMCUB (`dcn_3_1_5_dmcub`) | 0.0.224.0 (tag 20240709) | **0.0.255.0** (tag 20250305) | `dmesg \| grep "DMUB firmware.*version"` |
| PSP TOC (`psp_13_0_5_toc`) | Any (static, never updated) | Latest | N/A |
| PSP TA (`psp_13_0_5_ta`) | Latest available | Latest | `dmesg \| grep "PSP"` |

> See [COMPATIBILITY-MATRIX.md §2](COMPATIBILITY-MATRIX.md#2-dmcub-firmware-analysis) for full DMCUB version history, SRU status, and `.bin`/`.bin.zst` conflict analysis.

#### What the Script Must Do

```
Step 1:  Detect OS (Ubuntu/Fedora/Arch/Pop!_OS)
Step 2:  Check network connectivity
Step 3:  Check disk space (need >= 5GB free)
Step 4:  Record pre-install baseline (kernel, firmware, params, dmesg snapshot)
Step 5:  Install/verify HWE kernel (Ubuntu: linux-generic-hwe-24.04; Fedora/Arch: already fine; Pop!_OS: already fine)
Step 6:  Update linux-firmware (THE critical step):
         - Ubuntu/Pop!_OS: Check if SRU delivered the fix first:
             dmesg | grep "DMUB firmware.*version"
             If version >= 0x0500E000 (0.0.224.0): SRU worked — skip manual update
             If version == 0x05000F00 (0.0.15.0): manual update needed:
               Download from git tag 20250305
               Install DMCUB + PSP blobs manually
               Compress to .bin.zst (kernel loads .zst FIRST when CONFIG_FW_LOADER_COMPRESS_ZSTD=y)
               Remove bare .bin to prevent conflicts
               Verify ONLY .bin.zst exists for each blob
         - Fedora: already has 20260309, verify DMCUB version
         - Arch: already has 20260309, verify DMCUB version
Step 7:  Configure kernel command line:
         Ubuntu:  /etc/default/grub → GRUB_CMDLINE_LINUX_DEFAULT, then update-grub
         Fedora:  /etc/default/grub → GRUB_CMDLINE_LINUX_DEFAULT, then grub2-mkconfig
         Arch:    /etc/default/grub → GRUB_CMDLINE_LINUX_DEFAULT, then grub-mkconfig
                  OR if systemd-boot: edit /boot/loader/entries/*.conf options line
         Pop!_OS: sudo kernelstub -a "param=value" for each parameter
         Parameters:
           amdgpu.sg_display=0
           amdgpu.dcdebugmask=0x10
           amdgpu.ppfeaturemask=0xfffd7fff
           # NOTE: amdgpu.reset_method=1 removed — TESTED AND NOT SUPPORTED on Raphael APU.
           # Kernel 6.17 rejects it: "Specified reset method:1 isn't supported, using AUTO instead."
           amdgpu.gpu_recovery=1
           pcie_aspm=off
           iommu=pt
           processor.max_cstate=1
           amd_pstate=active
           modprobe.blacklist=nouveau              (Ubuntu/Pop!_OS)
           modprobe.blacklist=nouveau,nova_core     (Fedora/Arch — kernel 6.15+)
           nogpumanager                             (Ubuntu/Pop!_OS)
           initcall_blacklist=simpledrm_platform_driver_init
Step 8:  Configure modprobe.d/amdgpu.conf:
           options amdgpu sg_display=0
           options amdgpu ppfeaturemask=0xfffd7fff
           options amdgpu gpu_recovery=1
           # NOTE: reset_method=1 removed — not supported on Raphael APU (kernel rejects it).
           options amdgpu dc=1
           options amdgpu audio=1
Step 9:  Configure modprobe.d/nvidia.conf:
           blacklist nouveau
           options nouveau modeset=0
           options nvidia NVreg_RegisterPCIDriverOnEarlyBoot=1
           options nvidia NVreg_UsePageAttributeTable=1
           options nvidia NVreg_InitializeSystemMemoryAllocations=0
           options nvidia NVreg_DynamicPowerManagement=0x02
           options nvidia NVreg_EnableGpuFirmware=1
           options nvidia NVreg_PreserveVideoMemoryAllocations=1
           options nvidia NVreg_TemporaryFilePath=/var/tmp
           options nvidia NVreg_RegistryDwords="RmGpuComputeExecTimeout=0"
           options nvidia_drm modeset=1
           options nvidia_drm fbdev=1
         NOTE: nvidia-drm.modeset=1 is DEFAULT in 595, but set explicitly for belt-and-suspenders.
         NOTE: NVreg_EnableGpuFirmware=1 is REQUIRED — =0 breaks open kernel modules.
         NOTE: NVreg_RegisterPCIDriverOnEarlyBoot=1 improves PCIe init stability; prevents Xid 79.
Step 10: Configure modprobe.d/blacklist-nouveau.conf:
         Ubuntu/Pop!_OS:
           blacklist nouveau
           blacklist lbm-nouveau
           alias nouveau off
           alias lbm-nouveau off
         Fedora/Arch (kernel 6.15+):
           blacklist nouveau
           blacklist nova_core
           blacklist lbm-nouveau
           alias nouveau off
           alias lbm-nouveau off
Step 11: Configure initramfs module load order:
         Ubuntu/Pop!_OS:
           /etc/initramfs-tools/modules:
             amdgpu
             nvidia
             nvidia_uvm
             nvidia_modeset
             nvidia_drm
           NOTE: Modules listed here trigger auto-inclusion of their firmware via modinfo.
           GOTCHA: If both .bin and .bin.zst exist, initramfs may include the wrong one.
         Fedora:
           /etc/dracut.conf.d/gpu-modules.conf:
             force_drivers+=" amdgpu nvidia nvidia_modeset nvidia_uvm nvidia_drm "
           /etc/dracut.conf.d/amdgpu-firmware.conf:
             fw_dir+=" /lib/firmware/amdgpu "
             install_items+=" /lib/firmware/amdgpu/dcn_3_1_5_dmcub.bin "
           CRITICAL: Always include spaces at beginning AND end of += values.
         Arch:
           /etc/mkinitcpio.conf:
             MODULES=(amdgpu nvidia nvidia_modeset nvidia_uvm nvidia_drm)
             HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block filesystems fsck)
           NOTE: When amdgpu is in MODULES, mkinitcpio auto-includes ALL 400+ firmware blobs.
           No manual firmware management needed on Arch.
Step 12: Configure modules-load.d/gpu.conf (all OS):
           amdgpu
           nvidia
           nvidia_uvm
           nvidia_modeset
           nvidia_drm
Step 13: Rebuild initramfs:
           Ubuntu/Pop!_OS: sudo update-initramfs -u -k all
           Fedora:         sudo dracut --force
           Arch:           sudo mkinitcpio -P
Step 14: Verify initramfs contains:
           The new firmware files (dcn_3_1_5_dmcub, psp_13_0_5_*)
           amdgpu module
           nvidia modules (if installed yet — may not be until Phase 4)
           Correct module ordering
         Verification:
           Ubuntu/Pop!_OS: lsinitramfs /boot/initrd.img-$(uname -r) | grep dcn_3_1_5
           Fedora:         lsinitrd | grep dcn_3_1_5
           Arch:           lsinitcpio /boot/initramfs-linux.img | grep dcn_3_1_5
Step 15: Apply Mutter KMS thread workaround (even for XFCE — in case user switches):
           /etc/environment.d/90-mutter-kms.conf: MUTTER_DEBUG_KMS_THREAD_TYPE=user
Step 16: Disable gpu-manager (Ubuntu/Pop!_OS):
           sudo systemctl disable gpu-manager.service
           sudo systemctl mask gpu-manager.service
Step 17: Install post-reboot verification service (systemd one-shot)
Step 18: Record post-install state
Step 19: Print summary and prompt for reboot
```

#### Firmware Update — Deep Detail

This is the single most important operation. The script MUST:

1. **Check current firmware version FIRST:**
   ```bash
   # On a running system:
   dmesg | grep "DMUB firmware.*version"
   # Version encoding: 0x0XYYZZWW → X.YY.ZZ.WW
   # 0x05000F00 = 0.0.15.0 (CRITICALLY outdated)
   # 0x0500E000 = 0.0.224.0 (minimum safe)
   # 0x0500FF00 = 0.0.255.0 (conservative target)
   ```

2. **Download firmware from a pinned, verified source (Ubuntu/Pop!_OS only):**
   ```bash
   # Option A: git tag (preferred — verified source)
   cd /tmp
   git clone --depth 1 --branch 20250305 \
     https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git fw-20250305

   # Option B: if git clone fails (firewall, etc), fall back to wget with checksum
   # Provide SHA256 of each firmware blob for verification
   ```

3. **List ALL firmware files to update for Raphael:**
   ```
   amdgpu/dcn_3_1_5_dmcub.bin        — Display MicroController Unit B (THE critical one)
   amdgpu/psp_13_0_5_toc.bin         — PSP Table of Contents
   amdgpu/psp_13_0_5_ta.bin          — PSP Trust Application
   amdgpu/psp_13_0_5_asd.bin         — PSP Application Security Driver
   amdgpu/gc_10_3_6_me.bin           — Graphics Compute 10.3.6 Micro Engine
   amdgpu/gc_10_3_6_mec.bin          — GC Micro Engine Compute
   amdgpu/gc_10_3_6_mec2.bin         — GC Micro Engine Compute 2
   amdgpu/gc_10_3_6_pfp.bin          — GC Pre-Fetch Parser
   amdgpu/gc_10_3_6_rlc.bin          — GC Run List Controller
   amdgpu/gc_10_3_6_ce.bin           — GC Constant Engine (if exists)
   amdgpu/sdma_5_2_6.bin             — SDMA 5.2.6 engine (Raphael)
   amdgpu/vcn_3_1_2.bin              — Video Core Next 3.1.2 (Raphael)
   ```

4. **For EACH firmware file:**
   - Check if source exists in downloaded firmware tree
   - Backup existing file (both `.bin` and `.bin.zst` variants)
   - Copy new `.bin` from source
   - Compress to `.bin.zst` using `zstd -f`
   - Remove bare `.bin` (keep ONLY `.bin.zst`)
   - Verify file size is nonzero
   - Log old vs new file sizes

5. **Handle the `.bin` vs `.bin.zst` conflict explicitly:**
   ```bash
   # The kernel firmware loader checks in this order:
   # 1. {name}.zst (if CONFIG_FW_LOADER_COMPRESS_ZSTD=y)
   # 2. {name}.xz  (if CONFIG_FW_LOADER_COMPRESS_XZ=y)
   # 3. {name}     (uncompressed)
   # Ubuntu 24.04 has CONFIG_FW_LOADER_COMPRESS_ZSTD=y
   # So .bin.zst takes priority. BOTH existing = conflict.
   # Resolution: keep ONLY .bin.zst
   ```

6. **Verify the firmware version in the blob:**
   ```bash
   # DMCUB version is at a known offset in the binary
   # Check first 64 bytes:
   xxd -l 64 /tmp/fw-20250305/amdgpu/dcn_3_1_5_dmcub.bin
   ```

> **Why Fedora/Arch skip this step:** They ship `linux-firmware-amdgpu` 20260309, which includes DMCUB firmware post-MR#587 with all DCN315 fixes. No `.bin`/`.bin.zst` conflicts because they use `.zst` exclusively. See [OS-CROSSCUTTING-CONCERNS.md §5](OS-CROSSCUTTING-CONCERNS.md#5-linux-firmware-update-mechanisms).

#### GRUB Configuration — Exact Parameters with Rationale

```bash
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash \
  amdgpu.sg_display=0 \
  amdgpu.dcdebugmask=0x10 \
  amdgpu.ppfeaturemask=0xfffd7fff \
  amdgpu.gpu_recovery=1 \
  pcie_aspm=off \
  iommu=pt \
  processor.max_cstate=1 \
  amd_pstate=active \
  modprobe.blacklist=nouveau \
  nogpumanager \
  initcall_blacklist=simpledrm_platform_driver_init"
# NOTE: amdgpu.reset_method=1 intentionally omitted — TESTED AND NOT SUPPORTED on Raphael APU.
# Kernel 6.17 rejects it: "Specified reset method:1 isn't supported, using AUTO instead."
```

**Fedora/Arch addition** (kernel 6.15+): Change `modprobe.blacklist=nouveau` to `modprobe.blacklist=nouveau,nova_core`

**Pop!_OS**: Use `kernelstub` instead:
```bash
for param in \
  "amdgpu.sg_display=0" \
  "amdgpu.dcdebugmask=0x10" \
  "amdgpu.ppfeaturemask=0xfffd7fff" \
  "amdgpu.gpu_recovery=1" \
  "pcie_aspm=off" \
  "iommu=pt" \
  "processor.max_cstate=1" \
  "amd_pstate=active" \
  "modprobe.blacklist=nouveau" \
  "initcall_blacklist=simpledrm_platform_driver_init"; do
  sudo kernelstub -a "$param"
done
# NOTE: amdgpu.reset_method=1 intentionally omitted — not supported on Raphael APU.
```

| Parameter | Value | Why |
|-----------|-------|-----|
| `amdgpu.sg_display=0` | Disable scatter/gather | Forces contiguous VRAM, bypasses GART/TLB issues |
| `amdgpu.dcdebugmask=0x10` | Disable PSR | Reduces DCN complexity, prevents state machine conflicts |
| `amdgpu.ppfeaturemask=0xfffd7fff` | Disable GFXOFF bit 15 | Prevents power gating during display operations |
| ~~`amdgpu.reset_method=1`~~ | ~~Force mode0 (full ASIC)~~ | **REMOVED: NOT SUPPORTED on Raphael APU.** Kernel 6.17 rejects it, falls back to AUTO (mode2). |
| `amdgpu.gpu_recovery=1` | Enable GPU reset on hang | Allows recovery from ring timeouts |
| `pcie_aspm=off` | Disable PCIe ASPM globally | Prevents Xid 79 link loss on RTX 4090 |
| `iommu=pt` | IOMMU passthrough | Required for GPU compute, minimal overhead |
| `processor.max_cstate=1` | Limit CPU C-state | Prevents deep idle causing PCIe link drops |
| `amd_pstate=active` | AMD P-State EPP | Better perf/watt; default on kernel 6.5+ but explicit for safety |
| `modprobe.blacklist=nouveau` | Block nouveau | Prevent open-source NVIDIA driver |
| `modprobe.blacklist=...,nova_core` | Block nova (6.15+) | Fedora/Arch: new `nova` module conflicts with nvidia-open |
| `nogpumanager` | Disable gpu-manager | Ubuntu/Pop!_OS: prevents auto-rewrite of GPU config |
| `initcall_blacklist=simpledrm_platform_driver_init` | Block simpledrm | Fix card ordering (amdgpu gets card0) |

**WARNING:** `initcall_blacklist=simpledrm_platform_driver_init` removes early boot display. Screen is black until amdgpu loads. Acceptable for workstation without disk encryption.

### Verification: `verify-phase-02.sh`

```
CHECK 01: Kernel version matches expected (6.17.x for Ubuntu HWE, 6.19.x for Fedora/Arch, 6.18-6.19.x for Pop!_OS)
CHECK 02: DMCUB firmware version in dmesg != 0x05000F00 (old) and matches expected
CHECK 03: DMCUB loaded exactly ONCE (not 3-4 times = reset loop)
CHECK 04: No firmware file conflicts (only .bin.zst exists, no bare .bin alongside) — Ubuntu/Pop!_OS only
CHECK 05: Initramfs contains dcn_3_1_5_dmcub firmware
CHECK 06: Initramfs contains amdgpu module
CHECK 07: Initramfs contains nvidia modules (if already installed)
CHECK 08: /proc/cmdline contains all expected parameters
CHECK 09: /sys/module/amdgpu/parameters/sg_display == 0
CHECK 10: /sys/module/amdgpu/parameters/ppfeaturemask == 0xfffd7fff (or decimal 4294443007)
CHECK 11: /sys/module/amdgpu/parameters/reset_method == -1 (AUTO; mode0 is not supported on Raphael APU)
CHECK 12: /sys/module/amdgpu/parameters/gpu_recovery == 1
CHECK 13: /sys/module/amdgpu/parameters/dc == 1
CHECK 14: Boot config matches expected (parse GRUB config or kernelstub config)
CHECK 15: modprobe.d/amdgpu.conf exists and contains all expected options
CHECK 16: modprobe.d/nvidia.conf exists and contains all expected options
CHECK 17: modprobe.d/blacklist-nouveau.conf exists (and contains nova_core on Fedora/Arch)
CHECK 18: nouveau is NOT loaded (lsmod | grep nouveau == empty)
CHECK 19: nova_core is NOT loaded (Fedora/Arch: lsmod | grep nova_core == empty)
CHECK 20: Card ordering: card0 = amdgpu (check /sys/class/drm/card0/device/driver)
CHECK 21: Card ordering: card1 = nvidia OR not present yet
CHECK 22: UEFI boot confirmed (/sys/firmware/efi exists)
CHECK 23: IOMMU enabled (dmesg | grep "AMD-Vi")
CHECK 24: No REG_WAIT timeout in dmesg
CHECK 25: No ring timeout in dmesg
CHECK 26: No GPU reset in dmesg
CHECK 27: No Xid errors in dmesg
CHECK 28: simpledrm NOT loaded (lsmod | grep simpledrm == empty)
CHECK 29: Mutter KMS env file exists
CHECK 30: amd_pstate driver active (cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver == amd-pstate-epp)
CHECK 31: PCIe ASPM status (lspci -vvv | grep "ASPM.*Disabled")
CHECK 32: Firmware backup directory exists and is non-empty
CHECK 33: gpu-manager disabled (Ubuntu/Pop!_OS: systemctl is-enabled gpu-manager → masked)
```

### Reboot Sets for Phase 2

**Set A: Cold boot (5 boots)**
- Power off completely (not reboot). Wait 10 seconds. Power on.
- The optc31 bug is intermittent — single-boot success proves nothing.
- Log each boot: `dmesg > $LOG_DIR/phase02-boot-A-N.log`

**Set B: Warm reboot (5 boots)**
- `sudo reboot` from running system
- Tests reboot path (different from cold boot for DMCUB init)
- Log each boot: `dmesg > $LOG_DIR/phase02-boot-B-N.log`

**Analysis after 10 boots:**
```bash
for log in $LOG_DIR/phase02-boot-*.log; do
  echo "=== $(basename $log) ==="
  grep -c "REG_WAIT timeout" "$log" || echo "0"
  grep -c "ring.*timeout" "$log" || echo "0"
  grep -c "GPU reset" "$log" || echo "0"
  grep "DMUB firmware.*version" "$log"
done
```

**Success criteria:** 10/10 boots with zero REG_WAIT timeouts, zero ring timeouts, zero GPU resets, correct DMCUB version.

**Partial success:** If 8-9/10 boots are clean → firmware fix is working but the intermittent case persists. Proceed to Phase 3 (XFCE will mask the remaining intermittent failures).

**Failure:** If >3/10 boots show timeouts → generate DEBUG-PHASE-02.md, try parameter variants:
1. Add `amdgpu.dcdebugmask=0x18` (disable clock gating + PSR)
2. Add `amdgpu.seamless=1` (skip CRTC disable entirely)
3. Add `amdgpu.lockup_timeout=30000` (increase timeout to 30s)

---

## PHASE 3: Display Stack (iGPU driver, compositor, display config)

### Script: `phase-03-display.sh`

```
Step 1:  Detect OS
Step 2:  Record pre-install state (display, DRM, Mesa)
Step 3:  Install XFCE desktop environment:
         Ubuntu:         sudo apt install xfce4 xfce4-goodies lightdm lightdm-gtk-greeter
         Fedora XFCE:    already installed (native spin)
         Arch:           sudo pacman -S xfce4 xfce4-goodies lightdm lightdm-gtk-greeter
         Pop!_OS:        Option A: Keep COSMIC (lower risk than GNOME, but still uses GFX ring)
                         Option B: sudo apt install xfce4 xfce4-goodies (maximum safety)
                         COSMIC note: v1.0 uses OpenGL ES via GlowRenderer on GFX ring.
                         Less ring pressure than Mutter, no RT-priority SIGKILL, but not immune.
                         cosmic-epoch #1105 confirms amdgpu kernel panic on AMD+NVIDIA under COSMIC.
Step 4:  Set XFCE as default session (configure display manager):
         Ubuntu:         sudo dpkg-reconfigure lightdm (select lightdm over gdm3)
                         OR: keep gdm3, select XFCE at login screen
         Fedora XFCE:    already default
         Arch:           sudo systemctl enable lightdm
         Pop!_OS:        If keeping COSMIC: no change. If XFCE: install lightdm, configure.
Step 5:  Configure XFCE compositing:
         DISABLE xfwm4 compositor initially (zero GPU ring submissions for maximum safety)
         Create /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml with:
           use_compositing=false
         Can re-enable later if display is stable after Phase 6.
         NOTE: NVIDIA 595 includes xfwm4 blinking fix — compositing ON is viable after stability confirmed.
Step 6:  Verify Mesa version matches kernel:
         Ubuntu HWE 6.17: Mesa should be 25.2.8 (ships with 24.04.4)
         Fedora:          Mesa 25.1.9 (from repos)
         Arch:            Mesa 26.0+ (from repos)
         Pop!_OS:         Mesa 25.1.5-26.0.3
         If mismatch on Ubuntu, install matching HWE Mesa:
           sudo apt install libgl1-mesa-dri:amd64 libgl1-mesa-glx:amd64
Step 7:  Configure Xorg for dual-GPU:
         Create /etc/X11/xorg.conf.d/10-amdgpu.conf:
           Section "Device"
             Identifier "AMD"
             Driver "amdgpu"
             BusID "PCI:X:Y:Z"  # from lspci
             Option "TearFree" "true"
             Option "DRI" "3"
           EndSection
         Create /etc/X11/xorg.conf.d/20-nvidia-headless.conf:
           # Explicitly exclude NVIDIA from display
           # This file intentionally does NOT add NVIDIA as a screen device
Step 8:  Configure udev rules for GPU permissions:
         /etc/udev/rules.d/99-gpu.rules
         Ensure NVIDIA device nodes are accessible for compute
Step 9:  Configure environment.d for display:
         DRI_PRIME=0 (use iGPU for rendering)
         LIBGL_ALWAYS_SOFTWARE=0
Step 10: Record post-install state
Step 11: Print summary, prompt for reboot/re-login
```

### Verification: `verify-phase-03.sh`

```
CHECK 01: XFCE packages installed (xfce4, xfwm4 present)
CHECK 02: Display manager configured (lightdm or gdm3 with XFCE session available)
CHECK 03: XFCE session file exists (/usr/share/xsessions/xfce.desktop)
CHECK 04: OpenGL renderer is AMD (glxinfo | grep "OpenGL renderer" → "AMD Radeon Graphics")
CHECK 05: OpenGL vendor is AMD (not llvmpipe, not NVIDIA, not swrast)
CHECK 06: Mesa version matches expected (glxinfo | grep "OpenGL version")
CHECK 07: DRI3 enabled (check Xorg log or LIBGL_DEBUG=verbose)
CHECK 08: DRM card0 is amdgpu (readlink /sys/class/drm/card0/device/driver → amdgpu)
CHECK 09: DRM card0 has active connector (cat /sys/class/drm/card0-HDMI-A-1/status → connected)
CHECK 10: No NVIDIA display (nvidia-smi --query-gpu=display_active --format=csv → Disabled)
CHECK 11: Compositor status (pgrep xfwm4 && check compositing disabled if configured)
CHECK 12: No gnome-shell running (pgrep gnome-shell should be empty)
CHECK 13: Xorg log clean (grep -i "EE\|WW" /var/log/Xorg.0.log — categorize errors)
CHECK 14: No ring timeout since boot (dmesg | grep "ring.*timeout")
CHECK 15: No GPU reset since boot (dmesg | grep "GPU reset")
CHECK 16: Display resolution correct (xrandr | grep "*")
CHECK 17: VRAM usage reasonable (<500MB for desktop) via:
          cat /sys/class/drm/card0/device/mem_info_vram_used
CHECK 18: xfwm4 compositor disabled (xfconf-query -c xfwm4 -p /general/use_compositing → false)
```

### Reboot Sets for Phase 3

**Set A: Login/logout cycle (5 cycles)**
- Log in to XFCE session, wait 30 seconds, log out, wait 10 seconds, log back in
- Tests compositor startup/shutdown stability
- Check dmesg after each cycle

**Set B: Cold boot to XFCE (5 boots)**
- Full power cycle, auto-login or manual login to XFCE
- Tests full boot path with XFCE
- Check dmesg, Xorg log after each boot

**Fallback if XFCE still crashes:**
1. Boot to TTY only (`systemctl set-default multi-user.target`)
2. If TTY is stable → problem is desktop/X11, not driver
3. Try Sway: install sway → test lightweight Wayland without Mutter (LOW GFX ring pressure)
4. Try i3: install i3 → test minimal X11 tiling WM (ZERO GFX ring pressure)
5. Document in DEBUG-PHASE-03.md

---

## PHASE 4: NVIDIA Compute Stack (headless)

### Script: `phase-04-nvidia.sh`

#### NVIDIA 595 Key Behavioral Changes

Before generating NVIDIA install commands, note these 595.58.03 changes:
- **Open kernel modules are now DEFAULT** — no need for `-M=proprietary` flag
- **`nvidia-drm.modeset=1` is now DEFAULT** — explicit setting is belt-and-suspenders
- **`NVreg_EnableGpuFirmware=1` REQUIRED** — `=0` breaks open kernel modules
- **CudaNoStablePerfLimit** — CUDA apps reach P0 (full clock speed)
- **xfwm4 blinking fix included** — directly relevant for Phase 3 XFCE compositor
- **No `nvidia-headless-595-server` package** — NVIDIA changed naming at branch 590

```
Step 1:  Detect OS
Step 2:  Record pre-install state

Step 3:  Add NVIDIA repository:
         Ubuntu/Pop!_OS:
           wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
           sudo dpkg -i cuda-keyring_1.1-1_all.deb
           sudo apt update
         Fedora:
           sudo dnf install \
             https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-43.noarch.rpm \
             https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-43.noarch.rpm
         Arch:
           nvidia-open-dkms is in official repos — no extra repo needed
           CUDA 13.2 + cuDNN 9.19 also in official repos

Step 4:  Install NVIDIA driver (NO display components):
         Ubuntu:
           sudo apt install cuda-drivers
           # This installs 595.58.03 from NVIDIA CUDA repo
           # For headless-only (no display components):
           sudo apt install libnvidia-compute-595 nvidia-dkms-open-595
           # IMPORTANT: There is NO nvidia-headless-595-server package.
           # NVIDIA changed naming at branch 590.
           # Alternative: nvidia-driver-590-server (590.48.01) in Ubuntu multiverse uses old naming.
         Fedora:
           sudo dnf install akmod-nvidia xorg-x11-drv-nvidia-cuda
           # NOTE: RPM Fusion currently ships 580.119.02, NOT 595.58.03
           # For 595 on Fedora:
           #   Download .run from nvidia.com:
           #   sudo ./NVIDIA-Linux-x86_64-595.58.03.run --kernel-module-type=open --no-drm
           # CRITICAL: Wait for akmods to finish building before rebooting (2-5 min):
           watch -n 2 "ls /lib/modules/$(uname -r)/extra/nvidia/"
           # Wait until nvidia.ko.xz appears
         Arch:
           sudo pacman -S nvidia-open-dkms nvidia-utils
           # Ships 595.58.03 from official repo
         Pop!_OS:
           # system76-driver-nvidia ships nvidia-driver-580-open by default
           # To upgrade to 595: add NVIDIA CUDA repo (same as Ubuntu), then:
           sudo apt install cuda-drivers

Step 5:  Wait for DKMS build to complete:
         Ubuntu/Pop!_OS: sudo dkms status | grep nvidia → "installed"
         Fedora: ls /lib/modules/$(uname -r)/extra/nvidia/ → nvidia.ko.xz exists
         Arch: DKMS auto-builds via pacman hook; check: modinfo nvidia | grep version

         DKMS RELIABILITY WARNING:
         - Ubuntu: HWE kernel updates can land BEFORE compatible NVIDIA packages.
           LP #2141477: nvidia-dkms-580-open failed on kernel 6.17.0-14.
           Mitigation: Always keep previous kernel. Do not auto-update HWE.
         - Fedora: akmods can fail after kernel updates. MUST wait 2-5 min after dnf upgrade.
         - Arch: Any pacman -Syu can break NVIDIA. Check Arch news before updating.
           Mitigation: Keep linux-lts as fallback. Pin packages after stability confirmed.
         See OS-CROSSCUTTING-CONCERNS.md §10 for full DKMS failure analysis.

Step 6:  Install CUDA toolkit:
         Ubuntu/Pop!_OS: sudo apt install cuda-toolkit-13-2
         Fedora:
           # Option A: NVIDIA runfile (CUDA 13.2 officially supports fedora43)
           wget https://developer.download.nvidia.com/compute/cuda/13.2.0/local_installers/cuda_13.2.0_595.58.03_linux.run
           sudo sh cuda_13.2.0_595.58.03_linux.run --toolkit --silent
           # --toolkit only: skips driver install (already installed via RPM Fusion/run)
           # Option B: Container-based (for version flexibility)
           sudo dnf install nvidia-container-toolkit podman
           podman run --device nvidia.com/gpu=all nvidia/cuda:13.2-runtime-ubuntu24.04 nvidia-smi
         Arch:
           sudo pacman -S cuda cudnn
           # Both in official repos — simplest installation of all distros

Step 7:  Install cuDNN:
         Ubuntu/Pop!_OS: sudo apt install libcudnn9-cuda-13 libcudnn9-dev-cuda-13
         Fedora: Installed via CUDA .run file or download from NVIDIA
         Arch: Already installed with cuda package (step 6)

Step 8:  Install NCCL:
         Ubuntu/Pop!_OS: sudo apt install libnccl2 libnccl-dev
         Fedora: Download from NVIDIA
         Arch: Available in AUR (nccl)

Step 9:  Install NVIDIA Container Toolkit:
         Ubuntu/Pop!_OS:
           curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
             sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
           curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
             sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
             sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
           sudo apt update && sudo apt install nvidia-container-toolkit
         Fedora:
           curl -s -L https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo | \
             sudo tee /etc/yum.repos.d/nvidia-container-toolkit.repo
           sudo dnf install nvidia-container-toolkit
         Arch:
           sudo pacman -S nvidia-container-toolkit
           # Single command — official repo, no extra setup
         See OS-CROSSCUTTING-CONCERNS.md §1 for full platform support details.

Step 10: Configure CUDA environment:
         /etc/profile.d/cuda.sh:
           export PATH=/usr/local/cuda/bin:$PATH
           export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH
           export CUDA_VISIBLE_DEVICES=0

Step 11: Configure nvidia-persistenced:
         sudo systemctl enable nvidia-persistenced
         sudo systemctl start nvidia-persistenced

Step 12: Configure NVIDIA compute mode (headless):
         sudo nvidia-smi -c DEFAULT
         sudo nvidia-smi -pm 1  (persistence mode)

Step 13: Configure NVIDIA power management:
         # Set power limit (400W reduces thermals with ~2% perf loss vs 450W default)
         sudo nvidia-smi -pl 400
         # Optional: Lock GPU clocks for consistent ML training
         # sudo nvidia-smi -lgc 800,2520

         # Create persistent power limit service (all distros):
         sudo tee /etc/systemd/system/nvidia-power-limit.service << 'EOF'
         [Unit]
         Description=NVIDIA GPU Power Limit
         After=nvidia-persistenced.service
         [Service]
         Type=oneshot
         ExecStart=/usr/bin/nvidia-smi -pl 400
         [Install]
         WantedBy=multi-user.target
         EOF
         sudo systemctl enable nvidia-power-limit.service

Step 14: Configure suspend/resume services (all distros):
         sudo systemctl enable nvidia-suspend nvidia-resume nvidia-hibernate

Step 15: Disable NVIDIA display (belt-and-suspenders):
         sudo nvidia-smi --drain -p 0000:XX:00.0 -m 0  (if supported)

Step 16: Verify CUDA installation:
         Compile and run vectorAdd sample
         Compile and run deviceQuery sample

Step 17: Record post-install state
Step 18: Print summary
```

### Verification: `verify-phase-04.sh`

```
CHECK 01: nvidia module loaded (lsmod | grep nvidia)
CHECK 02: nvidia module version matches expected (modinfo nvidia | grep version)
         Ubuntu/Arch: 595.58.03; Fedora: 580.119 or 595.58.03 depending on install method
CHECK 03: nvidia-smi runs without error
CHECK 04: GPU name = "NVIDIA GeForce RTX 4090"
CHECK 05: GPU memory = 24576 MiB (24 GB)
CHECK 06: Display Active = Disabled (nvidia-smi --query-gpu=display_active --format=csv)
CHECK 07: Display Mode = Disabled
CHECK 08: Persistence Mode = Enabled
CHECK 09: Driver version matches expected
CHECK 10: CUDA version = 13.2 (nvidia-smi top-right)
CHECK 11: No Xid errors in dmesg (dmesg | grep "Xid")
CHECK 12: GSP firmware loaded (dmesg | grep "GSP")
CHECK 13: Open kernel modules used (dmesg | grep "nvidia.*open")
CHECK 14: nvidia-persistenced running (systemctl is-active nvidia-persistenced)
CHECK 15: CUDA toolkit installed (nvcc --version → CUDA 13.2)
CHECK 16: CUDA compiler works (compile trivial .cu file)
CHECK 17: vectorAdd sample passes
CHECK 18: deviceQuery sample shows correct GPU info
CHECK 19: cuDNN installed and loadable
CHECK 20: cuDNN version matches CUDA
CHECK 21: NCCL installed
CHECK 22: /usr/local/cuda/bin in PATH
CHECK 23: /usr/local/cuda/lib64 in LD_LIBRARY_PATH
CHECK 24: Re-Size BAR enabled (nvidia-smi -q | grep "Resizable BAR" OR dmesg | grep "BAR")
CHECK 25: PCIe link speed = Gen4 x16 (nvidia-smi -q | grep "Link Speed\|Link Width")
CHECK 26: Power limit set correctly (nvidia-smi -q | grep "Power Limit")
CHECK 27: Temperature sensor responding (nvidia-smi --query-gpu=temperature.gpu --format=csv)
CHECK 28: No nouveau module loaded (lsmod | grep nouveau → empty)
CHECK 29: No nova_core module loaded (Fedora/Arch: lsmod | grep nova_core → empty)
CHECK 30: NVIDIA device files exist (/dev/nvidia0, /dev/nvidiactl, /dev/nvidia-uvm)
CHECK 31: CUDA_VISIBLE_DEVICES set correctly
CHECK 32: Memory clock and SM clock responding (nvidia-smi dmon -s u -c 1)
CHECK 33: ECC mode status (nvidia-smi -q | grep "ECC")
CHECK 34: nvidia-container-toolkit installed (nvidia-ctk --version)
CHECK 35: Power limit service enabled (systemctl is-enabled nvidia-power-limit)
CHECK 36: Suspend/resume services enabled (systemctl is-enabled nvidia-suspend)
```

### Reboot Sets for Phase 4

**Set A: NVIDIA cold boot (3 boots)**
- Verify nvidia-smi works after each cold boot
- Check for Xid errors
- Verify persistence mode survived reboot

**Set B: CUDA stress test (2 runs)**
- Run `cuda-samples/Samples/1_Utilities/bandwidthTest/bandwidthTest`
- Run `cuda-samples/Samples/0_Introduction/matrixMul/matrixMul`
- Check for Xid errors during and after
- Verify no amdgpu errors while NVIDIA is under load

---

## PHASE 5: ML Framework Stack

### Script: `phase-05-ml-stack.sh`

```
Step 1:  Detect OS
Step 2:  Install Python 3.11+ (if not present)
Step 3:  Create ML virtual environment:
         python3 -m venv /opt/ml/venv
         OR conda/mamba if user prefers

Step 4:  Install PyTorch with CUDA:
         pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu132
         NOTE: PyTorch wheels are DISTRO-AGNOSTIC (manylinux_2_28 standard).
         The same pip command works on Ubuntu, Fedora, Arch, Pop!_OS.
         No distro-specific builds exist. Only requirement: Python 3.x + glibc >= 2.28.
         See OS-CROSSCUTTING-CONCERNS.md §4 for details.

Step 5:  Install ML utilities:
         pip install numpy scipy pandas matplotlib
         pip install transformers accelerate
         pip install jupyter tensorboard

Step 6:  Install Docker and configure GPU access:
         Ubuntu/Pop!_OS:
           sudo apt install docker.io
           sudo nvidia-ctk runtime configure --runtime=docker
           sudo systemctl restart docker
         Fedora:
           # Fedora defaults to Podman. For Docker:
           sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
           sudo dnf install docker-ce docker-ce-cli containerd.io
           sudo systemctl enable --now docker
           sudo nvidia-ctk runtime configure --runtime=docker
           # For Podman (Fedora default, no Docker needed):
           nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
         Arch:
           sudo pacman -S docker
           sudo systemctl enable --now docker
           sudo nvidia-ctk runtime configure --runtime=docker
         Verify GPU access in container:
           docker run --rm --gpus all nvidia/cuda:13.2-base-ubuntu24.04 nvidia-smi
           # Podman (Fedora):
           podman run --device nvidia.com/gpu=all nvidia/cuda:13.2-runtime-ubuntu24.04 nvidia-smi
         Performance note: Docker and Podman have IDENTICAL GPU performance (both use runc/crun
         with nvidia-container-runtime hook). 1-3% overhead vs bare metal for compute workloads.
         See OS-CROSSCUTTING-CONCERNS.md §3 for Docker vs Podman comparison.

Step 7:  Install monitoring tools:
         Ubuntu/Pop!_OS: sudo apt install nvtop htop iotop
         Fedora: sudo dnf install nvtop htop iotop
         Arch: sudo pacman -S nvtop htop

Step 8:  Configure CPU performance for ML:
         echo "performance" | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference
         # Persist via systemd service or tuned profile

Step 9:  Verify PyTorch CUDA:
         python3 -c "
         import torch
         print(f'PyTorch: {torch.__version__}')
         print(f'CUDA available: {torch.cuda.is_available()}')
         print(f'CUDA version: {torch.version.cuda}')
         print(f'GPU: {torch.cuda.get_device_name(0)}')
         print(f'GPU memory: {torch.cuda.get_device_properties(0).total_mem / 1e9:.1f} GB')
         t = torch.randn(1000, 1000, device='cuda')
         print(f'Tensor on GPU: {t.device}')
         print(f'Matrix multiply test: {torch.mm(t, t).sum().item():.2f}')
         "

Step 10: Run a quick training benchmark:
         Train a small ResNet on CIFAR-10 for 1 epoch
         Verify GPU utilization during training (nvidia-smi dmon)
         Verify no amdgpu errors during training (dmesg)

Step 11: Record post-install state
Step 12: Print summary
```

### Verification: `verify-phase-05.sh`

```
CHECK 01: Python version >= 3.11
CHECK 02: venv exists and is activatable
CHECK 03: PyTorch installed and importable
CHECK 04: torch.cuda.is_available() == True
CHECK 05: torch.cuda.get_device_name(0) == "NVIDIA GeForce RTX 4090"
CHECK 06: CUDA version in PyTorch matches system CUDA
CHECK 07: cuDNN available in PyTorch (torch.backends.cudnn.is_available())
CHECK 08: Matrix multiplication test passes
CHECK 09: GPU memory allocation works (allocate 20GB tensor, verify)
CHECK 10: No Xid errors during test (dmesg | grep Xid)
CHECK 11: No amdgpu errors during test (dmesg | grep -E "ring.*timeout|GPU reset")
CHECK 12: nvtop runs and shows both GPUs
CHECK 13: transformers library importable
CHECK 14: jupyter notebook starts (quick test)
CHECK 15: Docker running and GPU-accessible (docker run --gpus all nvidia/cuda:13.2-base nvidia-smi)
CHECK 16: nvidia-container-toolkit configured (cat /etc/docker/daemon.json | grep nvidia)
```

---

## PHASE 6: Stability Validation

### Script: `phase-06-stability.sh`

This phase runs comprehensive stability tests. No new software is installed.

```
Step 1:  Multi-boot stress test — 10 cold boots:
         For each boot: record dmesg, check for errors, check card ordering
         Automated via SSH from another machine, OR
         Use a systemd timer that records state on each boot

Step 2:  Display stability test — 2 hours:
         Leave XFCE desktop running
         Open a terminal, monitor dmesg in real-time
         Run a lightweight desktop task (file manager, text editor)
         Check every 15 min for ring timeouts

Step 3:  CUDA compute stress test — 1 hour:
         Run nvidia-smi dmon in background (logging every 1s)
         Run gpu-burn or cuda-memtest for sustained GPU load
         Run a real ML training job (ResNet-50 on ImageNet subset)
         Monitor both GPUs: iGPU display stability + dGPU compute

Step 4:  Combined stress test — 30 min:
         Desktop active on iGPU (file manager, browser)
         CUDA training on dGPU simultaneously
         Tests the interaction between display and compute paths

Step 5:  Thermal monitoring:
         Record CPU temp, iGPU temp, dGPU temp every 10s for 30 min under load
         Check for thermal throttling (nvidia-smi -q | grep "Thermal Slowdown")

Step 6:  Generate final stability report:
         Aggregate all boot logs
         Count total errors per category
         Compute stability score: (clean boots / total boots) * 100
         List any surviving issues with severity rating
```

### Success Criteria

| Metric | Target | Acceptable | Fail |
|--------|--------|-----------|------|
| Clean boot rate | 10/10 | 8/10 | <8/10 |
| REG_WAIT timeouts (total across all boots) | 0 | 0 | >0 |
| Ring timeouts (total) | 0 | 1 (if recovers) | >1 |
| GPU resets (total) | 0 | 1 (if recovers) | >1 |
| Xid errors (total) | 0 | 0 | >0 |
| 2-hour desktop uptime | No crash | No crash | Crash |
| 1-hour compute test | Passes | Passes | Fails |
| Combined test | Passes | Passes | Fails |
| GPU temps under load | <85C both | <90C both | >95C |

---

## PHASE 7: Post-Stability Maintenance

Once Phase 6 passes, the system is stable. This phase defines ongoing maintenance to **prevent regression**.

### Kernel Freeze (CRITICAL — Do Immediately After Phase 6)

```bash
# Ubuntu/Pop!_OS:
sudo apt-mark hold linux-image-$(uname -r) linux-headers-$(uname -r)
sudo apt-mark hold nvidia-dkms-open-595 libnvidia-compute-595 cuda-drivers
# Verify: apt-mark showhold

# Fedora:
sudo dnf install python3-dnf-plugin-versionlock
sudo dnf versionlock add kernel-$(uname -r)
sudo dnf versionlock add akmod-nvidia
# Verify: dnf versionlock list

# Arch:
# /etc/pacman.conf:
# IgnorePkg = linux linux-firmware-amdgpu nvidia-open-dkms
# Verify: grep IgnorePkg /etc/pacman.conf
```

### Update Strategy Per OS

| OS | Security Updates | Kernel Updates | Driver Updates |
|----|-----------------|---------------|---------------|
| **Ubuntu** | Monthly (`apt upgrade` excluding held packages) | Quarterly, after testing on a non-critical session | Wait for matching NVIDIA DKMS |
| **Fedora** | Weekly (`dnf upgrade --exclude=kernel*`) | Manual, after Arch/forum testing confirms stability | Wait for RPM Fusion update |
| **Arch** | Monthly (`pacman -Syu` with IgnorePkg set) | Manual, after checking archlinux.org/news | Happens with kernel; both pinned together |
| **Pop!_OS** | Same as Ubuntu | Same as Ubuntu | Same as Ubuntu |

### DKMS Recovery Procedure

When a kernel update breaks NVIDIA:
1. **Boot into previous kernel** — GRUB Advanced Options (or kernelstub previous entry)
2. **Re-pin the working kernel** — `apt-mark hold` / `dnf versionlock add` / `IgnorePkg`
3. **Wait for compatible NVIDIA driver** — check vendor repos
4. **Test DKMS build on new kernel:**
   ```bash
   sudo dkms install nvidia/595.58.03 -k NEW_KERNEL_VERSION
   ```
5. **If build succeeds:** unpin old kernel, reboot into new kernel, verify
6. **If build fails:** stay on old kernel, report bug

### Firmware Update Protocol

Before updating `linux-firmware`:
1. Check release notes for `dcn_3_1_5_dmcub` changes
2. **AVOID** tags containing DMCUB 0.1.14.0 (linux-firmware 20250613 — known bad)
3. After update:
   - Ubuntu/Pop!_OS: `sudo update-initramfs -u -k all`
   - Fedora: `sudo dracut --force`
   - Arch: auto-rebuilt via pacman hook
4. Verify: `dmesg | grep "DMUB firmware.*version"`
5. If regression: restore backup firmware from `$BACKUP_DIR/`, rebuild initramfs

> See [OS-CROSSCUTTING-CONCERNS.md §5](OS-CROSSCUTTING-CONCERNS.md#5-linux-firmware-update-mechanisms) for firmware update mechanisms per OS and [§10](OS-CROSSCUTTING-CONCERNS.md#10-dkms-reliability-for-nvidia) for DKMS reliability analysis.

---

## Debugging CLAUDE.md Template

When ANY phase fails, generate a debug file using this template:

```markdown
# DEBUG-PHASE-XX: [Phase Name] Failure

## Failure Summary
- **Phase:** XX — [Phase Name]
- **Step:** [Step number and description]
- **OS:** [Detected OS and version]
- **Kernel:** [uname -r output]
- **Firmware:** [DMCUB version from dmesg]

## Error Evidence

### Primary Error
```
[Exact error message from dmesg/journal/script output]
```

### Surrounding Context (50 lines before/after error in dmesg)
```
[dmesg excerpt]
```

### Full Verify Report
```
[Contents of verify-phase-XX-report.json]
```

## Differential Analysis

### What Changed Since Last Working State
| Item | Before (working) | After (broken) |
|------|------------------|----------------|
| Kernel | X.Y.Z | A.B.C |
| Firmware | version | version |
| Parameter X | value | value |

## Root Cause Hypotheses (Ranked)

### Hypothesis 1: [Most likely cause]
**Evidence:** [What points to this]
**Test:** [Command to confirm/deny]
**Fix:** [Exact commands to apply]

### Hypothesis 2: [Second most likely]
**Evidence:** ...
**Test:** ...
**Fix:** ...

### Hypothesis 3: [Third most likely]
**Evidence:** ...
**Test:** ...
**Fix:** ...

## Known Error Patterns Cross-Reference

| Pattern | Match? | Reference |
|---------|--------|-----------|
| optc31_disable_crtc REG_WAIT | YES/NO | drm/amd #5073; COMPATIBILITY-MATRIX.md §1 |
| ring gfx_0.0.0 timeout | YES/NO | Cross-distro GNOME issue; COMPATIBILITY-MATRIX.md §5 |
| failed to load ucode DMCUB | YES/NO | NixOS #418212; COMPATIBILITY-MATRIX.md §2 |
| Xid 79 (GPU fallen off bus) | YES/NO | PCIe ASPM or power issue |
| Xid 13 (graphics engine error) | YES/NO | Compute error, check memory |
| MODE2 GPU reset (not fixing DCN) | YES/NO | COMPATIBILITY-MATRIX.md §1 (IP block routing) |
| nova_core/nouveau conflict | YES/NO | Fedora/Arch kernel 6.15+ |

## Open Questions (verify on live system)

| # | Question | Command | Priority |
|---|----------|---------|----------|
| 1 | Did SRU deliver working DMCUB? | dmesg \| grep "DMUB firmware.*version" | HIGH |
| 2 | ~~Does reset_method=1 actually reset DCN?~~ | **ANSWERED: NOT SUPPORTED.** Kernel 6.17 rejects mode0 on Raphael APU. | RESOLVED |
| 3 | Does XFCE avoid crash WITHOUT firmware fix? | Install XFCE, boot old firmware | MEDIUM |
| 4 | What is actual UMA Frame Buffer Size? | Visual BIOS check | MEDIUM |

## Recommended Fixes

### Fix 1: [Highest confidence fix]
```bash
[Exact commands]
```
**Expected outcome:** [What should change]
**Verify:** [How to check it worked]

### Fix 2: [Fallback]
```bash
[Exact commands]
```

### Fix 3: [Nuclear option]
```bash
[Exact commands]
```

## Escalation Path

If all fixes fail:
1. [Next parameter to try]
2. [Alternative compositor]
3. [Alternative OS — see OS-DECISION-MATRIX.md for scored alternatives]
4. [Upstream bug report with collected evidence to drm/amd #5073]

## Paste-to-Claude Block

Use this prompt to get targeted debugging help:

```
I'm setting up an AMD Ryzen 9 7950X workstation with Raphael iGPU (RDNA2, GC 10.3.6, DCN 3.1.5) for display and NVIDIA RTX 4090 for headless CUDA compute on [OS].

Phase XX ([Phase Name]) failed at step [N].

Error:
[Error message]

Current state:
- Kernel: [uname -r]
- DMCUB firmware: [version from dmesg]
- Boot config: [/proc/cmdline]
- amdgpu params: sg_display=[val], ppfeaturemask=[val], gpu_recovery=[val]
- Card ordering: card0=[driver], card1=[driver]
- Compositor: [XFCE/Sway/COSMIC/none]

I've already tried:
[List what was attempted]

The upstream bug is drm/amd #5073 (OPEN, no fix).
Reference docs: COMPATIBILITY-MATRIX.md, OS-DECISION-MATRIX.md, OS-CROSSCUTTING-CONCERNS.md
What should I try next?
```

## Collected Logs
- `$LOG_DIR/phase-XX-install-*.log`
- `$LOG_DIR/pre-reboot-phase-XX/`
- `$LOG_DIR/post-reboot-phase-XX/`
- `$LOG_DIR/phase-XX-verify-report.json`
```

---

## Logging Infrastructure

### Directory Structure

All scripts write to a common log directory:

```
/var/log/ml-workstation-setup/
├── phase-00/
│   └── bios-checklist.md
├── phase-02/
│   ├── phase-02-install-YYYYMMDD-HHMMSS.log
│   ├── pre-reboot/
│   │   ├── dmesg-pre.log
│   │   ├── journal-pre.log
│   │   ├── cmdline-pre.txt
│   │   ├── lsmod-pre.txt
│   │   ├── amdgpu-params-pre.txt
│   │   ├── grub-config-pre.txt (or kernelstub-config-pre.txt)
│   │   ├── modprobe-config-pre.txt
│   │   └── initramfs-contents-pre.txt
│   ├── post-reboot/
│   │   ├── (same files as pre-reboot)
│   │   └── reboot-diff.txt
│   ├── boot-tests/
│   │   ├── cold-boot-01.log ... cold-boot-05.log
│   │   └── warm-boot-01.log ... warm-boot-05.log
│   └── verify-phase-02-report.json
├── phase-03/
│   └── (same structure)
├── phase-04/
│   └── (same structure)
├── phase-05/
│   └── (same structure)
├── phase-06/
│   ├── stability-report.json
│   ├── multi-boot-summary.csv
│   ├── thermal-log.csv
│   └── combined-stress-log.csv
└── DEBUG-PHASE-XX.md (generated on failure)
```

### Logging Function (shared across all scripts)

```bash
#!/bin/bash
# Source this at the top of every script

LOG_DIR="/var/log/ml-workstation-setup"
BACKUP_DIR="/var/log/ml-workstation-setup/backups"
PHASE_NUM="XX"  # Set per script
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
PHASE_LOG="$LOG_DIR/phase-${PHASE_NUM}/phase-${PHASE_NUM}-install-${TIMESTAMP}.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

mkdir -p "$LOG_DIR/phase-${PHASE_NUM}" "$BACKUP_DIR"

# Tee all output to log
exec > >(tee -a "$PHASE_LOG") 2>&1

log_info()  { echo -e "${BLUE}[INFO]${NC} $(date +%H:%M:%S) $*"; }
log_ok()    { echo -e "${GREEN}[  OK]${NC} $(date +%H:%M:%S) $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $(date +%H:%M:%S) $*"; }
log_error() { echo -e "${RED}[FAIL]${NC} $(date +%H:%M:%S) $*"; }
log_step()  { echo -e "\n${BLUE}[$1/$TOTAL_STEPS]${NC} $2"; }

detect_os() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    case "$ID" in
      ubuntu)    echo "ubuntu" ;;
      fedora)    echo "fedora" ;;
      arch)      echo "arch" ;;
      pop)       echo "pop" ;;
      *)         echo "unknown" ;;
    esac
  else
    echo "unknown"
  fi
}

backup_file() {
  local src="$1"
  if [ -f "$src" ]; then
    local dst="$BACKUP_DIR/$(basename $src).${TIMESTAMP}"
    cp "$src" "$dst"
    log_info "Backed up: $src → $dst"
  fi
}

trap_error() {
  local exit_code=$?
  local line_no=$1
  log_error "Script failed at line $line_no (exit code: $exit_code)"
  log_error "Last 50 lines of log:"
  tail -50 "$PHASE_LOG"
  log_error "Generating debug file..."
  # Generate DEBUG-PHASE-XX.md here
}
trap 'trap_error $LINENO' ERR
```

### OS Detection Matrix

Every script branches on OS. The pattern:

```bash
OS=$(detect_os)
case "$OS" in
  ubuntu)
    PKG_INSTALL="sudo apt install -y"
    PKG_QUERY="dpkg -l"
    INITRAMFS_REBUILD="sudo update-initramfs -u -k all"
    GRUB_CONFIG="/etc/default/grub"
    GRUB_UPDATE="sudo update-grub"
    INITRAMFS_LIST="lsinitramfs"
    BOOT_PARAM_SET="grub"  # modify /etc/default/grub
    ;;
  pop)
    PKG_INSTALL="sudo apt install -y"
    PKG_QUERY="dpkg -l"
    INITRAMFS_REBUILD="sudo update-initramfs -u -k all"
    GRUB_CONFIG=""  # Pop!_OS uses kernelstub, not GRUB
    GRUB_UPDATE=""
    INITRAMFS_LIST="lsinitramfs"
    BOOT_PARAM_SET="kernelstub"  # sudo kernelstub -a "param"
    ;;
  fedora)
    PKG_INSTALL="sudo dnf install -y"
    PKG_QUERY="rpm -qa"
    INITRAMFS_REBUILD="sudo dracut --force"
    GRUB_CONFIG="/etc/default/grub"
    # UEFI: /boot/efi/EFI/fedora/grub.cfg; BIOS: /boot/grub2/grub.cfg
    # grub2-mkconfig auto-detects via symlink when -o is omitted on BLS systems.
    # Use the UEFI path since CSM=Disabled (UEFI boot required).
    if [ -d /sys/firmware/efi ]; then
      GRUB_UPDATE="sudo grub2-mkconfig -o /boot/efi/EFI/fedora/grub.cfg"
    else
      GRUB_UPDATE="sudo grub2-mkconfig -o /boot/grub2/grub.cfg"
    fi
    INITRAMFS_LIST="lsinitrd"
    BOOT_PARAM_SET="grub"
    BLACKLIST_EXTRA="nova_core"  # kernel 6.15+
    ;;
  arch)
    PKG_INSTALL="sudo pacman -S --noconfirm"
    PKG_QUERY="pacman -Q"
    INITRAMFS_REBUILD="sudo mkinitcpio -P"
    INITRAMFS_LIST="lsinitcpio"
    BLACKLIST_EXTRA="nova_core"  # kernel 6.15+
    # Arch: detect bootloader (archinstall defaults to systemd-boot since 2024)
    if [ -d /boot/loader/entries ] && command -v bootctl &>/dev/null; then
      GRUB_CONFIG=""
      GRUB_UPDATE=""
      BOOT_PARAM_SET="systemd-boot"  # edit /boot/loader/entries/*.conf
    else
      GRUB_CONFIG="/etc/default/grub"
      GRUB_UPDATE="sudo grub-mkconfig -o /boot/grub/grub.cfg"
      BOOT_PARAM_SET="grub"
    fi
    ;;
  *)
    log_error "Unsupported OS: $OS"
    exit 1
    ;;
esac

# Helper for boot param management
set_boot_param() {
  local param="$1"
  case "$BOOT_PARAM_SET" in
    grub)
      # Append to GRUB_CMDLINE_LINUX_DEFAULT if not already present
      if ! grep -q "$param" "$GRUB_CONFIG"; then
        sudo sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"/GRUB_CMDLINE_LINUX_DEFAULT=\"$param /" "$GRUB_CONFIG"
      fi
      ;;
    kernelstub)
      sudo kernelstub -a "$param"
      ;;
    systemd-boot)
      # Arch with systemd-boot: append to options line in all loader entries
      for entry in /boot/loader/entries/*.conf; do
        if [ -f "$entry" ] && ! grep -q "$param" "$entry"; then
          sudo sed -i "s/^options.*/& $param/" "$entry"
        fi
      done
      ;;
  esac
}
```

---

## Parameter Fallback Matrix

If Phase 2 boot tests fail, try these parameter combinations in order. Each row removes or changes ONE parameter from the previous to isolate the problematic one:

| # | Change from Baseline | Parameters |
|---|---------------------|------------|
| **Baseline** | Full recommended set | `sg_display=0 dcdebugmask=0x10 ppfeaturemask=0xfffd7fff pcie_aspm=off max_cstate=1 initcall_blacklist=simpledrm...` |
| **F1** | Change `dcdebugmask=0x18` | (add clock gating disable: bit 3 + bit 4) |
| **F2** | Add `amdgpu.seamless=1` | (skip CRTC disable entirely — avoids optc31 path) |
| **F3** | Add `amdgpu.lockup_timeout=30000` | (30s timeout, prevent premature reset) |
| **F4** | Remove `initcall_blacklist` | (simpledrm steals card0 but maybe compositor handles it) |
| **F5** | Add `amdgpu.dpm=0` | (disable dynamic power management — nuclear) |
| **F6** | Add `initcall_blacklist=sysfb_init` | (remove ALL early framebuffer — black until amdgpu) |
| **F7** | Switch to TTY only | (`systemctl set-default multi-user.target` — isolate compositor) |
| **F8** | Switch compositor | XFCE → Sway (Wayland, low GL) → i3 (X11, zero GL) |

For each fallback:
1. Apply the change
2. Rebuild initramfs
3. Reboot 3 times (cold boot)
4. Check dmesg for errors
5. If clean → keep and proceed
6. If not → revert and try next

---

## Auxiliary Logging to Enable

### Enable Verbose Kernel Logging (Pre-Phase 2)

```bash
# Enable verbose amdgpu DRM debug
echo 0x19F | sudo tee /sys/module/drm/parameters/debug
# Bits: 0x01=CORE, 0x02=DRIVER, 0x04=KMS, 0x08=PRIME, 0x10=ATOMIC, 0x80=DP, 0x100=VBL

# Enable verbose amdgpu trace (WARNING: extremely verbose, disk-filling)
# Only enable for single diagnostic boots
echo 1 | sudo tee /sys/kernel/debug/tracing/events/amdgpu/amdgpu_dm_dc_clocks_state/enable
echo 1 | sudo tee /sys/kernel/debug/tracing/events/amdgpu/amdgpu_dm_connector_funcs_calls/enable

# DMCUB trace mailbox (if supported)
cat /sys/kernel/debug/dri/0/amdgpu_dm_dmub_tracebuffer 2>/dev/null

# Journal persistent logging (survives reboot)
sudo mkdir -p /var/log/journal
sudo systemd-tmpfiles --create --prefix /var/log/journal
sudo systemctl restart systemd-journald
# Now: journalctl -b -1 gives LAST boot's log even after crash
```

### Enable NVIDIA Debug Logging

```bash
# GSP firmware debug
sudo nvidia-smi -q -d GSP

# Detailed GPU info
sudo nvidia-smi -q > $LOG_DIR/nvidia-smi-full.txt

# Performance state monitoring
nvidia-smi dmon -s pucvmet -d 5 -f $LOG_DIR/nvidia-dmon.csv &

# Xid error monitoring
sudo dmesg -w | grep --line-buffered "Xid\|nvidia" >> $LOG_DIR/nvidia-xid-watch.log &
```

### Enable amdgpu Debug Logging

```bash
# DMCUB status
cat /sys/kernel/debug/dri/0/amdgpu_dm_dmub_fw_state 2>/dev/null
cat /sys/kernel/debug/dri/0/amdgpu_dm_visual_confirm 2>/dev/null

# GPU recovery info
cat /sys/kernel/debug/dri/0/amdgpu_gpu_recover 2>/dev/null

# Ring status
cat /sys/kernel/debug/dri/0/amdgpu_ring_gfx 2>/dev/null

# PM info (power management)
cat /sys/kernel/debug/dri/0/amdgpu_pm_info 2>/dev/null

# Firmware versions (all IP blocks)
cat /sys/kernel/debug/dri/0/amdgpu_firmware_info 2>/dev/null
```

---

## Execution Instructions

### For Claude

When the user says "execute phase N" or "run the setup":

1. **Generate the script** for that phase (using the requirements above)
2. **Show the script** to the user for review
3. **Execute with `--dry-run` first** to show what will happen
4. **Execute for real** after user approval
5. **Run verification** immediately after
6. **Interpret results** — explain what passed, what failed, why
7. **If failure:** generate DEBUG-PHASE-XX.md and recommend next steps
8. **If success:** proceed to next phase or prompt for reboot

### For the User

1. Start with BIOS (Phase 0) — manual, follow checklist
2. Install OS (Phase 1) — manual, per your chosen OS
3. After first login, switch to TTY (Ctrl+Alt+F3)
4. Run: `sudo bash phase-02-foundation.sh`
5. Reboot, then run: `sudo bash verify-phase-02.sh`
6. Repeat boot tests (5 cold, 5 warm)
7. If stable: run phases 3-6 in sequence
8. If unstable: check DEBUG file, try fallback parameters
9. After Phase 6 passes: **immediately freeze kernel** (Phase 7)

---

## References

All research backing this prompt:

### Research Files (in setup_final/)
- [COMPATIBILITY-MATRIX.md](COMPATIBILITY-MATRIX.md) — Crash mechanism, DMCUB firmware history, kernel patches, documentation gaps
- [OS-DECISION-MATRIX.md](OS-DECISION-MATRIX.md) — Weighted OS scoring, per-OS analysis, compatibility matrices, settings
- [OS-CROSSCUTTING-CONCERNS.md](OS-CROSSCUTTING-CONCERNS.md) — Container toolkit, CUDA certification, Docker/Podman, firmware mechanisms, DKMS reliability

### Upstream Bugs (OPEN)
- [drm/amd #5073](https://gitlab.freedesktop.org/drm/amd/-/work_items/5073) — EXACT match: Raphael optc31 timeout
- [drm/amd #3377](https://gitlab.freedesktop.org/drm/amd/-/work_items/3377) — Raphael optc1 black screen
- [drm/amd #3583](https://gitlab.freedesktop.org/drm/amd/-/work_items/3583) — 9950X optc31 + DMCUB error
- [drm/amd #4433](https://gitlab.freedesktop.org/drm/amd/-/work_items/4433) — 8600G optc314 REG_WAIT timeout
- [drm/amd #3006](https://gitlab.freedesktop.org/drm/amd/-/issues/3006) — UMA 512M ring timeout

### Firmware
- [Debian #1057656](https://bugs-devel.debian.org/cgi-bin/bugreport.cgi?bug=1057656) — DMCUB fix (20240709)
- [NixOS #418212](https://github.com/nixos/nixpkgs/issues/418212) — DMCUB 0.1.14.0 regression
- [kernel-firmware MR #587](https://gitlab.com/kernel-firmware/linux-firmware/-/merge_requests/587) — DCN315 fix

### Kernel Patches
- `a878304276b8` — Bypass ODM before CRTC off (6.10+)
- `9724b8494d3e` — Restore immediate_disable_crtc (6.12+)
- `faee3edfcff7` — Wait for all pending cleared (6.13+)
- `391cea4fff00` — Skip disable CRTC on seamless boot (6.13+)
- `c707ea82c79d` — Ensure DMCUB idle before reset (6.15+)

### NVIDIA
- [595.58.03 README](https://us.download.nvidia.com/XFree86/Linux-x86_64/595.58.03/README/)
- [595.58.03 Open Kernel Modules](https://us.download.nvidia.com/XFree86/Linux-x86_64/595.58.03/README/kernel_open.html)
- [CUDA 13.2 Downloads](https://developer.nvidia.com/cuda-downloads)
- [CUDA 13.2 Installation Guide](https://docs.nvidia.com/cuda/cuda-installation-guide-linux/)
- [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)

### Community
- [simpledrm card ordering fix](https://bbs.archlinux.org/viewtopic.php?id=303311)
- [GNOME ring timeout — Fedora](https://discussion.fedoraproject.org/t/149587)
- [GNOME ring timeout — Ubuntu 25.04](https://discourse.ubuntu.com/t/62975)
- [7950X iGPU instability (Level1Techs)](https://forum.level1techs.com/t/224035)
- [Arch Wiki: AMDGPU](https://wiki.archlinux.org/title/AMDGPU)
- [Arch Wiki: NVIDIA](https://wiki.archlinux.org/title/NVIDIA)
- [Arch Wiki: mkinitcpio](https://wiki.archlinux.org/title/Mkinitcpio)

### Ubuntu-Specific
- [LP #2033157: iGPU/dGPU mix-up](https://bugs.launchpad.net/ubuntu/+source/switcheroo-control/+bug/2033157)
- [LP #2130926: No display on dual GPU](https://bugs.launchpad.net/ubuntu/+source/nvidia-graphics-drivers-580/+bug/2130926)
- [LP #2141477: DKMS 580 fails on 6.17](https://bugs.launchpad.net/ubuntu/+source/nvidia-graphics-drivers-580/+bug/2141477)
- [gpu-manager source](https://github.com/canonical/ubuntu-drivers-common/blob/master/share/hybrid/gpu-manager.c)

### Pop!_OS-Specific
- [cosmic-epoch #1105: AMD+NVIDIA kernel panic](https://github.com/pop-os/cosmic-epoch/issues/1105)
- [cosmic-epoch #2561: EGL errors](https://github.com/pop-os/cosmic-epoch/issues/2561)
- [cosmic-epoch #3334: Panel crash](https://github.com/pop-os/cosmic-epoch/issues/3334)
- [system76-power GPU switching](https://support.system76.com/articles/graphics-switch-pop/)
