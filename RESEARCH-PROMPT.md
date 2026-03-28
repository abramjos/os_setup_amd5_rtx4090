# Foundational Research Prompt: Dual-GPU ML Workstation Compatibility Matrix

## Objective

Generate a comprehensive, research-backed compatibility report (`COMPATIBILITY-MATRIX.md`) that evaluates **multiple candidate combinations** of OS, kernel, linux-firmware, BIOS/AGESA, NVIDIA driver, Mesa/amdgpu userspace, and compositor for the following **fixed hardware**:

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

## Context: What Has Been Tried and What Failed

### The Core Bug

The system suffers from an **intermittent crash loop** on boot:

```
[  6.1s] REG_WAIT timeout — optc31_disable_crtc line:136    (DCN register stall during EFI->amdgpu handoff)
[  8.0s] REG_WAIT timeout — optc1_wait_for_state            (Cascading: OTG stopped, no VBLANK arrives)
[ 18.5s] ring gfx_0.0.0 timeout (gnome-shell)               (GFX ring hangs on corrupted display state)
[ 19.0s] MODE2 GPU reset                                     (Resets GFX/SDMA only — NOT the DCN)
[ 31.3s] ring gfx_0.0.0 timeout (gnome-shell #2)            (DCN still broken -> repeat)
[ 69.2s] ring gfx_0.0.0 timeout (gnome-shell #3)            (GDM gives up -> session-failed)
```

MODE2 reset does NOT reset the DCN (Display Core Next) — only GFX and SDMA. So the broken display pipeline persists through every GPU reset, causing an infinite crash loop.

The triggering process is ALWAYS `gnome-shell` (PID varies each boot). The DMUB firmware version is `0x05002F00` and re-initializes 3-4 times per boot after each MODE2 reset.

### Exact Upstream Bug Match

**[freedesktop.org drm/amd #5073](https://gitlab.freedesktop.org/drm/amd/-/work_items/5073)** — "Fence fallback timer expired on Raphael iGPU"
- Same hardware pattern: Raphael/Granite Ridge iGPU, ASUS TUF X870, AGESA 1.3.0.0a, 64GB DDR5, NVIDIA dGPU present
- Same errors: optc31_disable_crtc REG_WAIT timeout + gfx ring timeouts + MODE2 resets
- Status: **OPEN, no fix** as of 2026-03-28
- User tried: GFXOFF disabled, sg_display=0, ppfeaturemask, iGPU VRAM 4GB — none fully fixed it

Related open issues: #5093, #3377, #3583, #4433 (all Raphael/Phoenix optc31/optc1 REG_WAIT timeouts).

### 20-Boot Diagnostic Data (runLog-04, 2026-03-27)

Across 20 boots with varying kernel + parameter combinations:

| Observation | Evidence |
|---|---|
| The bug is **intermittent** — some boots work fine with identical config | Boots -18, -4, -14 (kernel 6.8, default params) = no events |
| Kernel 6.17 HWE does NOT reliably fix it | Boots -19, -9, -6, -5 on 6.17 still show timeouts/crash-loops |
| Aggressive amdgpu parameter overrides can make things **WORSE** | Boot -10 (6.8 + all params) = 9 ring timeouts (worst run) |
| card0 = NVIDIA, card1 = AMD in EVERY boot | Module load order issue — amdgpu should be card0 |
| DMUB re-initializes 3-4 times per boot after MODE2 resets | DMUB firmware interaction is central |
| `sg_display = -1` in current config (Test B removed it) | The sg_display=0 workaround was removed during A/B testing |
| modprobe.d and GRUB are inconsistent (stale initramfs from test iterations) | Config conflicts between test A and test B |
| linux-firmware is `20240318.git3b128b60-0ubuntu2.25` — from **March 2024** | Missing DMCUB fixes from mid-2024+ |
| Firmware `.bin` and `.bin.zst` file conflicts exist for dcn_3_1_5_dmcub and psp_13_0_5_toc | Kernel prefers `.bin.zst` — manually placed `.bin` files may be ignored |
| Current boot cmdline is minimal: `loglevel=4 video=HDMI-A-1:1920x1080@60 modprobe.blacklist=nouveau iommu=pt nogpumanager` | Most amdgpu params were stripped during Test A/B |
| amdgpu.conf only has: `gpu_recovery=1 audio=1 dc=1` | sg_display, ppfeaturemask, dcdebugmask all removed |
| ppfeaturemask reads `0xfff7bfff` (not the recommended `0xfffd7fff`) | GFXOFF bit may still be enabled at firmware level |
| sg_display reads `-1` (driver default, NOT the recommended `0`) | Scatter/gather display is active — known problematic on Raphael |

### Key Firmware Details

| File | .bin (manual) | .bin.zst (package) |
|------|--------------|-------------------|
| dcn_3_1_5_dmcub | 242208 bytes, Mar 27 13:03 | 116455 bytes, Feb 19 07:21 |
| psp_13_0_5_toc | 1792 bytes, Mar 27 13:03 | 915 bytes, Feb 19 07:21 |

The `.bin` files were manually placed (probably from git). The `.bin.zst` files are from the Ubuntu `linux-firmware 20240318` package. Kernel loads `.bin.zst` when both exist — so the manual update may be **completely ignored**.

### What the Root Cause Analysis Points To (ranked)

1. **DMCUB firmware too old** — linux-firmware 20240318 predates the Debian #1057656 fix (July 2024) for broken `dcn_3_1_5_dmcub.bin`
2. **Kernel 6.8 missing DCN31 patches** — "bypass ODM before CRTC off" (6.9+), "Wait until OTG enable state cleared" (6.12+), CVE-2024-46870/47662 DMCUB fixes (6.11+)
3. **EFI framebuffer handoff race** — UEFI GOP sets up display via DMCUB; amdgpu teardown races with stale DMCUB state
4. **Scatter/gather display** — sg_display enabled by default; GART/TLB inconsistency during EFI->amdgpu transition

---

## Research Requirements

### 1. OS Candidates

Evaluate at least these, with pros/cons for THIS specific hardware:

| Candidate | Why Consider |
|-----------|-------------|
| **Ubuntu 24.04.1 LTS** (current) | Tier 1 NVIDIA/CUDA certification, largest ML community, but linux-firmware is stale |
| **Ubuntu 24.10 / 25.04** | Newer kernel (6.11/6.14), newer linux-firmware, but shorter support window; NVIDIA driver compat? |
| **Ubuntu 24.04 with HWE kernel** | Kernel 6.11+ backported to LTS base — best of both worlds? |
| **Fedora 41/42** | Bleeding-edge kernel + firmware; DNF handles firmware well; NVIDIA RPM Fusion or official repo |
| **Arch Linux** | Rolling release = always latest kernel/firmware/Mesa; but manual setup, no CUDA tier-1 certification |
| **NixOS** | Declarative config, easy rollback, but NixOS #418212 reports DMCUB loading broken on Raphael |
| **Pop!_OS 24.04** | System76's NVIDIA integration, hybrid GPU handling out of box |

For EACH candidate, research:
- Default kernel version and whether it includes the critical DCN31 patches (ODM bypass, OTG state wait, DMCUB CVEs)
- linux-firmware version shipped (does it include the July 2024+ DMCUB fix?)
- NVIDIA driver availability and installation method (official repo, distro repo, .run file)
- CUDA toolkit availability and version
- Known issues with Raphael iGPU + NVIDIA dGPU dual-GPU on that distro
- Mesa version (for amdgpu userspace)
- Community size/support for ML workstation use cases

### 2. Kernel Candidates

For each kernel version, assess DCN31 patch coverage:

| Kernel | Patches Included? | Source |
|--------|------------------|--------|
| **6.8** (Ubuntu 24.04 GA) | Missing: ODM bypass, OTG state wait, DMCUB CVEs | In-use, intermittent failures |
| **6.11** (Ubuntu 24.04 HWE) | Has DMCUB CVE fixes, may have ODM bypass | HWE backport |
| **6.12** | Has OTG state wait patch | Mainline PPA |
| **6.14** | Should have all patches | Ubuntu 25.04 default |
| **6.17** (tested as HWE) | Should have everything — but still crashed | Tested, still fails |
| **6.19** (bleeding edge) | Latest; NVIDIA 595 claims compat through 6.19 | Mainline PPA |

For each, verify:
- Does it contain the "bypass ODM before CRTC off" patch? (commit hash, merge date)
- Does it contain "Wait until OTG enable state cleared"? (commit hash, merge date)
- Does it contain CVE-2024-46870 and CVE-2024-47662 DMCUB fixes?
- Is NVIDIA driver 595.58.03 compatible? (check NVIDIA's kernel compat matrix)
- Are there any NEW regressions for Raphael iGPU in that kernel version?

**Critical question**: Kernel 6.17 was tested and STILL crashed. Why? Possible reasons to investigate:
- Stale linux-firmware (DMCUB fix not applied even though kernel has patches)
- Firmware file conflicts (.bin vs .bin.zst) causing wrong firmware to load
- Stale initramfs not rebuilt after kernel switch
- modprobe.d config conflicts from prior test iterations

### 3. linux-firmware Candidates

| Version | Date | Key Content |
|---------|------|-------------|
| `20240318` (current) | March 2024 | Pre-DMCUB fix; known broken for Raphael (Debian #1057656) |
| `20240709+` | July 2024+ | Contains the Debian #1057656 DMCUB fix |
| `20250211` (latest Ubuntu noble-updates?) | Feb 2025 | Check if Ubuntu backported newer firmware |
| Git HEAD (`linux-firmware.git`) | Current | Latest everything; may have untested changes |

For each, research:
- Exact `dcn_3_1_5_dmcub.bin` firmware version hash/size
- Any known regressions for Raphael
- How to install on Ubuntu 24.04 without breaking other firmware
- Whether the `.bin` vs `.bin.zst` conflict causes issues (which format does the kernel prefer at each version?)

### 4. NVIDIA Driver Candidates

| Driver | CUDA | Kernel Compat | Notes |
|--------|------|---------------|-------|
| **595.58.03** (current) | 13.x | 6.8-6.19 | Latest stable; CudaNoStablePerfLimit |
| **570.x** (previous production) | 12.x | 6.8-6.14 | Older but battle-tested |
| **560.x** | 12.x | 6.8-6.11 | Even older; may have fewer bugs |
| **550.x** | 12.x | 6.8 only? | Known compile failures on 6.11+ |

For each, verify:
- Headless package availability on each OS candidate (`nvidia-headless-NNN`)
- Compatibility with each kernel candidate
- Known issues with amdgpu coexistence
- GSP firmware behavior on RTX 4090
- Any Xid error patterns specific to that version

### 5. BIOS/AGESA Candidates

| BIOS | AGESA | Date | Notes |
|------|-------|------|-------|
| **3603** (current) | 1.3.0.0a | 2026-03-18 | Latest; DDR5 stability, boot fixes |
| **3513** | Pre-1.3.0.0 | 2026-01-30 | Possible fallback if 3603 introduced issues |

Research:
- Are there any user reports of 3603 introducing NEW iGPU issues on X670E Hero?
- Is there a newer BIOS beyond 3603?
- Does AGESA 1.3.0.0a change any iGPU/DCN behavior vs previous AGESA?
- BIOS settings that are **specific to AGESA version** (some settings change behavior between AGESA versions)

### 6. Compositor / Display Server Candidates

| Compositor | Why Consider |
|------------|-------------|
| **GNOME on X11** (current) | Standard Ubuntu; gnome-shell is the crash trigger |
| **GNOME on Wayland** | Different rendering path; may avoid the GFX ring timeout |
| **XFCE4** | Much lighter GPU demands; confirmed working on Raphael by multiple users |
| **Sway** (Wayland) | Lightweight Wayland compositor; minimal GPU allocation |
| **KDE Plasma 6** | Alternative full DE; different compositor (KWin) |
| **i3/i3wm** | Tiling WM on X11; minimal GPU compositing |
| **No compositor (TTY + SSH)** | Nuclear option: skip desktop entirely, SSH in for ML work |

For each, research:
- GPU compositing demands (how much GFX ring activity does it generate?)
- Known compatibility with Raphael RDNA2 iGPU
- Whether it triggers the same optc31/ring timeout pattern
- Resource overhead (CPU, RAM, iGPU VRAM via UMA)

### 7. Mesa / amdgpu Userspace Candidates

| Mesa Version | Source | Notes |
|--------------|--------|-------|
| **24.0.x** (Ubuntu 24.04 stock) | distro | Current; matches kernel 6.8 |
| **24.2+** (kisak PPA) | PPA | Newer radeonsi; may fix compositing bugs |
| **25.x** (bleeding edge) | Oibaf PPA or Arch | Latest; risk of regressions |

Research whether newer Mesa versions have any fixes for Raphael display compositing issues.

---

## Analysis Requirements

### Cross-Reference Matrix

After researching all candidates, build a **compatibility matrix** showing which combinations are valid:

```
OS x Kernel x linux-firmware x NVIDIA-driver x Mesa x Compositor
```

Eliminate invalid combinations (e.g., NVIDIA 550 + kernel 6.14 = compile failure).

### Recommended Test Candidates (Ranked)

Produce **3-5 concrete, testable configurations** ranked by likelihood of success:

For each candidate configuration, specify:
1. **Exact versions** of every component (OS, kernel, linux-firmware, NVIDIA driver, Mesa, compositor)
2. **Why this combination** — which root cause does it address?
3. **Risk assessment** — what could still fail and why?
4. **Installation steps** — how to get to this config from a clean Ubuntu 24.04 install (or fresh install of another OS)
5. **Verification commands** — how to confirm each component is correctly installed
6. **Rollback plan** — how to revert if it makes things worse

### Untracked Paths / Gaps in Current Documentation

Review ALL existing documentation and flag:
- Settings mentioned in one doc but not another
- BIOS paths that differ between docs (e.g., GFXOFF path varies across files)
- Kernel parameters that appear in GRUB but not modprobe.d (or vice versa)
- Scripts that set values different from what the docs recommend
- Firmware versions that don't match what the logs show
- Any assumptions that aren't backed by evidence

### Questions That Must Be Answered by Research

1. **Why did kernel 6.17 still crash?** It should have all DCN31 patches. Was it firmware? Config? A new regression?
2. **Is the DMCUB firmware fix from July 2024 actually in the linux-firmware available for Ubuntu 24.04?** Or does Ubuntu's backport policy exclude it?
3. **Does the `.bin.zst` preference mean the manual firmware update was completely ignored?** If so, all prior "firmware update" attempts were ineffective.
4. **Is there a DMCUB firmware version newer than 0x05002F00 that fixes the handoff?** What version does the latest linux-firmware git contain?
5. **Would a completely different compositor (XFCE, Sway) avoid the bug entirely?** The crash is always gnome-shell — does a lighter compositor never trigger the problematic GFX ring path?
6. **Is the card0=NVIDIA, card1=AMD ordering a contributing factor?** amdgpu should be card0 for display. Does the initramfs module order actually work, or is PCI enumeration overriding it?
7. **Does `video=efifb:off` change the handoff behavior enough to prevent the optc31 timeout?** This hasn't been tested.
8. **Is there a kernel boot parameter or amdgpu module parameter that forces a full DCN reset (not MODE2) on hang?** MODE2 only resets GFX/SDMA — leaving DCN broken.
9. **Would Ubuntu 24.04 with ONLY the linux-firmware updated (no kernel change) fix this?** Isolate firmware vs kernel as the variable.
10. **Are there any ASUS X670E Hero-specific BIOS interactions with the iGPU that differ from other X670E boards?** The upstream bug is on ASUS TUF X870 — same vendor, different board.

---

## Output Format

Generate a single file: `setup_final/COMPATIBILITY-MATRIX.md` with these sections:

1. **Executive Summary** — One-paragraph bottom line: what is the most likely path to success?
2. **Hardware Constraints** — Fixed hardware, confirmed working/broken states
3. **OS Candidate Analysis** — Table + prose for each OS
4. **Kernel Candidate Analysis** — Table + prose for each kernel, with patch verification
5. **Firmware Candidate Analysis** — Table + prose for each firmware version
6. **NVIDIA Driver Candidate Analysis** — Table + prose for each driver version
7. **Compositor Candidate Analysis** — Table + prose for each compositor
8. **Mesa/amdgpu Userspace Analysis** — Table + prose
9. **Cross-Reference Compatibility Matrix** — The big grid
10. **Recommended Test Configurations** — 3-5 ranked candidates with full specs
11. **Untracked Paths & Documentation Gaps** — Everything inconsistent across existing docs
12. **Open Questions & Required Investigations** — What we still don't know
13. **Test Protocol** — How to run each candidate (boot, verify, collect diagnostics)
14. **References** — All upstream bugs, patches, docs, forum threads cited

---

## Source Material to Ingest

Read and cross-reference ALL of the following before generating output:

### Documentation (in `setup/`)
- `ryzen-rtx4090-research-report.md` — AM5+RTX4090 stability catalog, BIOS settings, display config
- `DUAL-GPU-SETUP-COMPLETE-GUIDE.md` — 21+ issue catalog, solution matrix, step-by-step setup
- `BIOS-SETTINGS-COMPLETE-GUIDE.md` — 14-phase BIOS configuration, scripts_v3 gap analysis
- `OPTIMAL-ML-WORKSTATION-SPEC.md` — Full hardware + software spec with exact versions
- `spec.md` — Hardware platform reference (same content as above, shorter)
- `README.md` — Setup overview

### Scripts (in `setup/scripts_v3/`)
- `00-verify-bios-prerequisites.sh` — BIOS verification checks
- `01-first-boot-display-fix.sh` — GRUB + modprobe + HWE kernel setup
- `02-install-nvidia-driver.sh` — NVIDIA 595 + CUDA installation
- `03-configure-display.sh` — X11 + udev + services configuration
- `apply-test-a.sh` — Test A parameter set (clean slate)
- `apply-test-b-1080p.sh` — Test B parameter set (1080p)
- `diagnostic-full.sh` — Comprehensive 13-section diagnostic collector
- `05-multiboot-amdgpu-diag.sh` — Multi-boot comparison tool
- `06-recovery-fix.sh` — Recovery procedures
- All rollback scripts (`01-rollback.sh`, `02-rollback.sh`, etc.)

### Logs (in `logs/`)
- `runLog-04/` — Latest 20-boot diagnostic (March 27, 2026):
  - `ANALYSIS.txt` — Current boot analysis with ring timeout counts
  - `COMPARISON.txt` — Multi-boot comparison table (20 boots, kernel 6.8 + 6.17)
  - `META.txt` — Run metadata
  - `comparison.csv` — Machine-readable comparison data
  - `04-firmware/` — Firmware versions, conflicts, initramfs contents
  - `13-multiboot/boot-*/SUMMARY.txt` — Per-boot summaries with parameters and events
  - `01-kernel-system/` through `12-journal-full/` — Detailed per-category diagnostics
- `runLog-00` through `runLog-03` — Earlier diagnostic runs (skim for progression)
- `ml-diag-*` — Single-boot diagnostics
- `run2` through `run5` — Older test runs

### Project CLAUDE.md
- `/Users/abraham/Documents/Final/CLAUDE.md` — Root cause analysis, playbook, BIOS reference, post-fix checklist

---

## Research Methodology

For web research, prioritize these sources in order:

1. **Upstream bug trackers**: `gitlab.freedesktop.org/drm/amd/`, `github.com/NVIDIA/open-gpu-kernel-modules/`
2. **Kernel mailing lists**: `amd-gfx@lists.freedesktop.org`, `dri-devel@lists.freedesktop.org`
3. **Distro bug trackers**: Launchpad (Ubuntu), Bugzilla (Fedora), GitHub (NixOS, Arch)
4. **linux-firmware git**: `git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git`
5. **NVIDIA forums**: `forums.developer.nvidia.com`
6. **Reddit**: `r/linuxhardware`, `r/VFIO`, `r/archlinux`, `r/pop_os`
7. **Arch Wiki**: `wiki.archlinux.org` (AMDGPU, NVIDIA, Dual GPU)
8. **ASUS ROG forum**: For X670E Hero-specific BIOS issues

When citing research, include:
- Source URL
- Date of information (to assess staleness)
- Whether the information is confirmed/unconfirmed
- Relevance to THIS specific hardware combination
