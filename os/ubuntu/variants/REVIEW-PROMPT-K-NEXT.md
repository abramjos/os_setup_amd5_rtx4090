# Comprehensive Review & Research Prompt — autoinstall-K-next.yaml

> Use this prompt to commission a thorough, multi-domain review of the entire
> autoinstall YAML. Paste it into a fresh conversation with the file attached,
> or point at the path below.

---

## File Under Review

```
/Volumes/Untitled/UbuntuAutoInstall/os/ubuntu/variants/autoinstall-K-next.yaml
```

3,289 lines. 39 numbered late-command sections. 68 heredoc files created on target.
52 `curtin in-target` commands. ~120 packages installed.

## Supporting Documentation (READ BEFORE REVIEWING)

These files contain the hardware spec, root cause analysis, 12+ variant test
results, and empirical crash data. They are authoritative — the YAML was built
from their findings.

```
/Volumes/Untitled/UbuntuAutoInstall/CLAUDE.md
/Volumes/Untitled/UbuntuAutoInstall/os/ubuntu/DIAGNOSIS-PROGNOSIS.md
/Volumes/Untitled/UbuntuAutoInstall/MULTI-DISPLAY-RESEARCH.md
/Volumes/Untitled/UbuntuAutoInstall/DIAGNOSTIC-REFERENCE.md
```

---

## Context

This is an Ubuntu 24.04 LTS **autoinstall** YAML (cloud-init / Subiquity format)
for an unattended OS installation on a dual-GPU ML workstation. It runs once
during installation from a USB stick and produces a fully configured system on
first boot — no manual post-install steps.

### Fixed Hardware

| Component | Value |
|-----------|-------|
| CPU | AMD Ryzen 9 7950X (Zen 4, 16C/32T, Raphael) |
| iGPU | AMD Raphael (RDNA2, GC 10.3.6, DCN 3.1.5, 2 CUs) — display only |
| dGPU | NVIDIA RTX 4090 (AD102, 24GB GDDR6X, SM 8.9) — headless CUDA/ML compute only |
| Secondary dGPU target | NVIDIA RTX 4070 Ti Super (AD103, SM 8.9) — same stack must work |
| Motherboard | ASUS ROG Crosshair X670E Hero (X670E, AM5) |
| RAM | 2x 32GB DDR5-6000 CL30 (EXPO) |
| NVMe | Samsung 990 PRO 2TB x2 (dual-boot with Windows) |
| Display | 4K monitor (3840x2160) |

### Architecture

- iGPU drives ALL display/desktop. dGPU is 100% headless CUDA/ML compute.
- Two desktop sessions at LightDM login: XFCE (X11) and labwc (Wayland).
- Both sessions achieve ZERO GFX ring pressure (AccelMethod "none" + pixman).
- NVIDIA has no display processes. Ever.

### The Solved Bug

The system had an intermittent boot crash loop caused by a two-condition failure:
1. **DCN pipeline stall**: optc31 REG_WAIT timeout during EFI→amdgpu handoff
   (outdated DMCUB firmware 0x05000F00 could not recover)
2. **GFX ring pressure**: compositor GL commands hitting the corrupted DCN state

Both conditions are eliminated:
- Condition 1: DMUB firmware upgraded to 0x05002000 via initramfs hook (sections 4 + 27)
- Condition 2: AccelMethod "none" (X11) + WLR_RENDERER=pixman (Wayland) = zero GL on iGPU

### Critical Constraints (VIOLATION = BROKEN SYSTEM)

1. `amdgpu.gfx_off=0` must NOT appear as a kernel/module parameter — it is NOT
   a valid param on kernel 6.17+ and causes amdgpu probe failure (-22 EINVAL).
   GFXOFF is disabled via BIOS + ppfeaturemask=0xfffd7fff.
2. GNOME/GDM must NOT be installed or enabled — intermittent ring pressure
   confirmed across variants I, J, L.
3. `initcall_blacklist=simpledrm_platform_driver_init` must remain — ensures
   card0=amdgpu, not simpledrm.
4. Firmware update mechanism (sections 4 + 27) must not change.
5. GRUB parameters, modprobe configs, initramfs module ordering must not change
   unless a specific fix is documented.
6. NVIDIA driver comes from Ubuntu repos (`drivers: install: true`). Use
   `cuda-toolkit-12-6` only (NOT the `cuda` metapackage which pulls conflicting drivers).
7. Sections 1-27 are proven stable. New additions go in sections 28+.

---

## What To Review

Read the ENTIRE 3,289-line file and ALL supporting documentation. Then produce
a structured report covering every domain below. For each finding, classify as:

- **CRITICAL**: Will cause install failure, boot failure, or data loss
- **HIGH**: Will cause visible malfunction on first boot but system still usable
- **MEDIUM**: Suboptimal but functional — polish item
- **LOW**: Cosmetic or pedantic

---

### DOMAIN 1: YAML SYNTAX & AUTOINSTALL SCHEMA

- Is the YAML syntactically valid? Check indentation (2-space for autoinstall
  keys, variable inside heredocs).
- Are all top-level keys valid for Ubuntu 24.04 autoinstall schema v1?
  (`version`, `interactive-sections`, `locale`, `keyboard`, `timezone`,
  `refresh-installer`, `source`, `kernel`, `network`, `proxy`, `apt`,
  `storage`, `identity`, `ssh`, `drivers`, `codecs`, `updates`, `packages`,
  `snaps`, `early-commands`, `late-commands`, `user-data`, `reporting`,
  `shutdown`)
- Are `early-commands` and `late-commands` valid list items? Each must be
  either a string or a multi-line block scalar (`|` or `>`).
- Do all `>-` folded scalars properly join into single-line commands?
- Do all `|` literal blocks preserve newlines correctly?
- Are heredoc delimiters properly quoted (`<< 'EOF'`) to prevent variable
  expansion during install?
- Does any heredoc delimiter collide with another? (Each must be unique within
  its scope.)
- Is `storage: version: 2` config valid for this partition layout?
  Check: EFI, boot, swap, root, home partitions with correct offsets for
  dual-boot alongside Windows.

### DOMAIN 2: BOOT CHAIN & GPU INITIALIZATION

- **GRUB parameters** (section 1): Are all parameters valid for kernel 6.17 HWE?
  Cross-reference each against CLAUDE.md parameter table. Check for:
  - Parameters that conflict with each other
  - Parameters that are redundant (set in both GRUB and modprobe)
  - Missing parameters that should be present
  - The `nvidia-drm.modeset=1` vs header comment saying `modeset=0` discrepancy
- **Modprobe configs** (section 2): Do `amdgpu.conf` and `nvidia.conf` match
  the GRUB parameters? Are softdep ordering rules correct? Is `nouveau`
  properly blacklisted in all three places (modprobe, blacklist file, GRUB)?
- **Initramfs module ordering** (section 3): Is `amdgpu` listed before `nvidia`?
  Does `/etc/modules-load.d/gpu.conf` match?
- **Firmware update** (section 4): Does the three-tier fallback (kernel.org →
  GitHub → USB) work? Are all 12 firmware blobs listed? Is `.bin` → `.bin.zst`
  compression correct? Does the backup mechanism work?
- **Initramfs firmware hook** (section 27): Does the hook correctly copy blobs
  into initramfs? Does it handle both `/lib/firmware` and `/usr/lib/firmware`
  symlink layouts? Does the initramfs rebuild (section 39) happen AFTER the
  hook is installed?
- **Card ordering**: Does `initcall_blacklist=simpledrm_platform_driver_init`
  ensure card0=amdgpu? Verify this is in GRUB params.

### DOMAIN 3: DISPLAY STACK & COMPOSITOR SAFETY

- **Xorg config** (section 15): Is `AccelMethod "none"` correctly set? Is
  `PrimaryGPU "yes"` on AMD and `PrimaryGPU "no"` on NVIDIA? Is BusID
  `PCI:108:0:0` correct for this motherboard? (Check: `108` decimal = `0x6c`,
  which is the iGPU PCI bus on X670E.)
- **NVIDIA headless** (section 15): Does the OutputClass config prevent NVIDIA
  from claiming any display?
- **labwc** (section 7): Is `WLR_RENDERER=pixman` set in BOTH the session
  `.desktop` Exec line AND the environment file? Are they consistent?
- **xfwm4** (section 13): Is `vblank_mode` set to `xpresent` (not `glx`)?
  Is `use_compositing` true? Does XRender compositing avoid GL?
- **LightDM** (section 5): Is it correctly set as default display manager?
  Does it present both X11 and Wayland sessions? Are GNOME session files
  removed/diverted?
- **Service masking** (section 16): Are `gdm3`, `gpu-manager`,
  `switcheroo-control`, `gnome-initial-setup` all disabled AND masked?
  Are sleep/suspend/hibernate targets masked (ML workstation)?

### DOMAIN 4: NVIDIA COMPUTE STACK

- **Driver installation**: `drivers: install: true` uses Ubuntu-packaged
  driver. Is `cuda-keyring` installed (section 20)? Is
  `nvidia-container-toolkit` repo added?
- **CUDA toolkit** (section 29): Is `cuda-toolkit-12-6` installed (not the
  `cuda` metapackage)? Are cuDNN and NCCL installed? Are NVIDIA drivers
  pinned with `apt-mark hold`?
- **CUDA env** (section 19): Is `/etc/profile.d/cuda-env.sh` correct?
  Does it set PATH and LD_LIBRARY_PATH? Is CUDA_VISIBLE_DEVICES=0 correct
  for single-GPU compute?
- **udev rules** (sections 21): Are NVIDIA device nodes (nvidia0, nvidiactl,
  nvidia-uvm, nvidia-modeset, nvidia-caps) all set to mode 0666?
  Are there duplicate rules between `99-gpu.rules` and
  `99-nvidia-compute.rules`?
- **Power management**: Is `nvidia-persistenced` enabled? Is the 400W power
  limit service (section 19) correct for RTX 4090? What about 4070 Ti Super
  (which has a different TDP)?
- **Docker** (section 22): Is `nvidia-container-runtime` configured? Is
  `data-root: /data/docker` valid (does `/data` exist at this point)?
- **DCGM** (section 30): Is datacenter-gpu-manager installation correct from
  CUDA repo?

### DOMAIN 5: TEST & BENCHMARK SCRIPTS

Review each embedded script for correctness, robustness, and completeness:

**5a. CUDA Samples Full Validation** (section 31, ~300 lines)
- Does it correctly auto-detect CUDA version and checkout matching tag?
- Is cmake invoked with `-DCMAKE_CUDA_ARCHITECTURES=89` (Ada Lovelace)?
- Does it use `run_tests.py` when available with `test_args.json`?
- Does the fallback manual execution work?
- Does the validation report correctly parse deviceQuery output for:
  - Compute capability 8.9
  - Memory size (24GB for 4090, 16GB for 4070 Ti Super)
  - Multiprocessor count (128 for 4090, 66 for 4070 Ti Super)
- Does p2pBandwidthLatencyTest bandwidth parsing work?
- Are PCIe Gen1 warnings with BIOS fix instructions present?
- Are Tensor Core sample results (FP16, TF32, BF16, INT8) extracted?
- Does nbody thermal check work?

**5b. GPU Hardware Validation** (section 32, ~130 lines)
- Does gpu_burn clone and build correctly?
- Is `-tc` flag used for Tensor Core stress?
- Does DCGM fallback work when dcgmi is not installed?
- Does clock monitoring (`nvidia-smi dmon`) run concurrently with gpu_burn?
- Is the `--extended` flag for longer tests properly handled?

**5c. ML Benchmark Suite** (section 33, ~270 lines)
- Does the venv setup work correctly?
- Is `torch.cuda.amp.autocast()` usage correct (not deprecated in latest PyTorch)?
- Does the BERT proxy (TransformerEncoder) actually approximate BERT-base workload?
- Is the VRAM stress test (90% allocation) safe?
- Does `torch.compile` usage have proper error handling?
- Are all Python heredocs (`<< 'PYTHON_EOF'`) properly delimited?

**5d. CUDA Toolchain Validation** (section 34, ~200 lines)
- Does the custom vector add kernel compile with `-arch=sm_89`?
- Does NCCL single-GPU test work (process group with world_size=1)?
- Is pynvml installation inside the script robust?

**5e. CPU Benchmark Suite** (section 35, ~130 lines)
- Is STREAM compiled with `-march=znver4 -fopenmp`?
- Is `STREAM_ARRAY_SIZE=80000000` appropriate for 64GB RAM?
- Does the curl/wget fallback for stream.c work?
- Are stress-ng parameters appropriate for 7950X?

**5f. Master Test Launcher** (section 36, ~110 lines)
- Does the menu loop work correctly?
- Does "Run ALL" execute scripts sequentially with combined report?
- Is the LOGDIR variable set correctly in run_all()?

### DOMAIN 6: DESKTOP SHORTCUTS & SYSTEMD

- Do all 6 `.desktop` files (section 37) have correct `Exec` lines?
- Does the session-aware terminal detection work?
  (`$XDG_SESSION_TYPE = wayland` → foot, else xfce4-terminal)
- Are all shortcuts marked executable (`chmod +x`)?
- Is ownership set to uid 1000 (abraham)?
- Does the systemd service (section 38) have correct dependencies
  (`After=nvidia-persistenced.service`)?
- Is it correctly NOT enabled (manual start only)?
- Is `TimeoutStartSec=3600` sufficient for full CUDA samples build+run?

### DOMAIN 7: UI/UX & THEME CONSISTENCY

Audit every visual element across BOTH sessions for 4K comfort:

**DPI & Scaling:**
- XFCE xsettings: DPI=120, fonts Inter 12, cursors 32
- labwc environment: XCURSOR_SIZE=32, GDK_SCALE=1, GDK_DPI_SCALE=1.25,
  QT_SCALE_FACTOR=1.25
- LightDM greeter: xft-dpi=120, font Inter 12, cursor 32
- X11 Xresources: Xft.dpi:120 + xrdb autostart
- gsettings (labwc autostart): font Inter 12, mono JetBrains Mono 12, cursor 32
- Are the GDK_DPI_SCALE=1.25 and QT_SCALE_FACTOR=1.25 values correct when
  GDK_SCALE=1? (DPI_SCALE multiplies the font size; SCALE multiplies the
  entire UI. Setting both GDK_SCALE=1 + GDK_DPI_SCALE=1.25 means "render at
  1x pixel scale but 125% font/widget size" — is this the intended behavior
  for 120 DPI on 4K, or should GDK_DPI_SCALE match the 120/96 ratio = 1.25?)

**Fonts:**
- Are ALL font references 12pt+ for body text?
- Are monospace fonts consistently JetBrains Mono 12?
- Is the Inter font properly installed? (PPA + GitHub zip in section 27b,
  plus `fonts-inter` in packages list — is this redundant/conflicting?)
- Are font fallback chains adequate for CJK / emoji?

**Cursors & Icons:**
- Is Bibata-Modern-Classic installed (PPA in section 27b)?
- Are cursor sizes 32px in ALL locations?
- Are Papirus-Dark icons set everywhere?
- Panel icons: XFCE panel icon-size=28, waybar tray icon-size=24
- Plank dock: IconSize=48 — is the config path `/etc/xdg/plank/dock1/settings`
  correct? (Plank typically uses `~/.config/plank/dock1/launchers/` and
  `dconf` for settings, not a file in `/etc/xdg/plank/`)

**Bars & Panels:**
- XFCE panel: size=40, position=top — appropriate for 4K?
- waybar top: height=36 — does this match XFCE panel visual weight?
- waybar dock: height=56, icon-size=36
- Are padding/margin values in CSS appropriate?

**Terminals:**
- xfce4-terminal: JetBrains Mono 12, FontDPI=120, dark theme
- foot: JetBrains Mono:size=12, dpi-aware=yes, cursor block styled
- Do color schemes match between terminals?

**Notifications:**
- mako: font=Inter 14, max-icon-size=48, border-radius=12
- Is `Inter 14` valid pango font syntax for mako? (Mako uses pango —
  `font=Inter 14` should work as `family size`, but verify.)

**Lock Screen:**
- swaylock: font=Inter, font-size=28, indicator-radius=120
- Is the config path `/etc/xdg/swaylock/config` correct?
  (swaylock reads `$XDG_CONFIG_HOME/swaylock/config` per user, or
  `$XDG_CONFIG_DIRS/swaylock/config` system-wide. `/etc/xdg/` is in
  `$XDG_CONFIG_DIRS` by default — verify.)
- Is XFCE lock (`xflock4`) configured separately?

**Keybindings (MacBook-like):**
- Are these present in BOTH labwc rc.xml AND XFCE keyboard shortcuts?
  - Ctrl+Q → close/quit
  - Super+Tab → window switch
  - Super+Shift+3 → full screenshot
  - Super+Shift+4 → area screenshot
  - Super+, → settings
  - Super+Shift+N → dismiss notifications (labwc only — no XFCE equivalent?)
- In XFCE, `Ctrl+Q` is mapped to `xfce4-session-logout --fast` — this logs
  out the entire session, not just closes a window. Is this intentional?
  In labwc it maps to `Close` (close current window). This is a MISMATCH.

**Wallpaper:**
- Both sessions reference `/usr/share/backgrounds/warty-final-ubuntu.png`
  — does this file exist in `ubuntu-desktop-minimal`?

### DOMAIN 8: PACKAGE MANAGEMENT & DEPENDENCIES

- Are all packages in the `packages:` list available in Ubuntu 24.04 repos?
- Are there packages listed that pull in GNOME dependencies transitively?
  (e.g., does `policykit-1-gnome` pull gnome-session?)
- Is `cmake` listed both in packages AND installed again in the CUDA samples
  script? (Redundancy check.)
- Are `freeglut3-dev`, `libgl-dev`, `libglu-dev` needed at install time or
  only at CUDA samples build time? (They're in packages list AND installed
  in the samples script.)
- Is `fonts-inter` in the packages list AND separately installed from GitHub
  ZIP in section 27b? Which takes precedence? Do they conflict?
- Is `docker.io` the right Docker package? (vs `docker-ce` from Docker's repo)
- Does `linux-headers-generic-hwe-24.04` match `linux-generic-hwe-24.04`?
- Are there any missing dependencies for the test scripts?
  (e.g., `python3-venv` for ML benchmarks, `git` for cloning repos)

### DOMAIN 9: SECURITY & HARDENING

- Is the password hash in `identity:` section safe for the autoinstall medium?
  (It's SHA-512 crypt, which is fine — but the USB stick is unencrypted.)
- Are SSH authorized-keys empty? Is password auth enabled?
- Is `firewalld` installed but configured? (It's in packages but no rules set.)
- Are NVIDIA device nodes at mode 0666 a security concern in a
  single-user workstation context?
- Is Docker configured securely? (`data-root: /data/docker` — does
  `/data` have proper permissions?)
- Are `memlock unlimited` and `nofile 1048576` appropriate?
- Does the system expose any unnecessary network services?

### DOMAIN 10: RELIABILITY & ERROR HANDLING

- Do all `curtin in-target` commands have `|| true` where failure is acceptable?
- Are there commands that SHOULD fail hard (no `|| true`) but currently don't?
- What happens if the network is unavailable during firmware download
  (section 4)? Does USB fallback work?
- What happens if the CUDA repo is unavailable during section 29?
- What happens if any apt-get command fails mid-install?
- Are all heredoc files written to correct target paths (`/target/...` vs
  in-chroot paths)?
- Is the initramfs rebuild (section 39) truly the LAST late-command?
  (Nothing should come after it that modifies initramfs content.)
- Are there race conditions between service enablement and package installation?

### DOMAIN 11: STORAGE & PARTITIONING

- Is the dual-boot partition layout correct?
- Are Windows partitions preserved (`preserve: true`)?
- Is the EFI partition (1GB) at the correct offset for dual-boot?
- Is 64GB swap appropriate for 64GB RAM? (Matches RAM for hibernation,
  but hibernation is masked.)
- Is 200GB root sufficient for CUDA toolkit + CUDA samples + Docker images?
- Is the home partition (`size: -1`) using remaining space?
- Does the NVMe serial number match the actual drive?

### DOMAIN 12: HEADER & DOCUMENTATION ACCURACY

- Does the header comment accurately describe what the file does?
- Are "Variant H" references in section comments updated to "Variant K-Next"?
  ~~(Several sections still say "Variant H".)~~ **FIXED (2026-04-02)**: All 7
  config comments updated to "Variant K-Next".
- Is the runlog-K_v1 test result summary still accurate?
- Are the KNOWN LIMITATIONS still current?
- ~~Does the header mention that nvidia-drm.modeset=0 but GRUB params set =1?~~
  **FIXED (2026-04-02)**: Header updated to say modeset=1 and fbdev=1,
  matching GRUB/modprobe.

---

## Output Format

Produce a structured report with:

1. **Executive Summary** — Overall assessment (SHIP / FIX-FIRST / REWRITE),
   total issue count by severity, top 3 risks.

2. **Findings Table** — One row per finding:
   | # | Domain | Severity | Line(s) | Finding | Recommended Fix |

3. **Cross-Reference Matrix** — For settings that must be consistent across
   multiple locations (DPI, cursor size, theme, font), show a matrix of
   every location and whether they match.

4. **Script Correctness Review** — For each of the 6 embedded shell/Python
   scripts, a separate mini-review covering:
   - Will it run successfully on first boot?
   - Are there missing dependencies?
   - Are there shell quoting issues?
   - Are there Python compatibility issues (3.12 on Ubuntu 24.04)?
   - Are error handling and logging adequate?

5. **Redundancy Report** — Packages installed in multiple places, configs
   set in multiple locations, duplicate udev rules, etc.

6. **Recommended Changes** — Prioritized list of concrete edits with
   exact line numbers and replacement text.

---

## Review Results (2026-04-02)

### Assessment: FIX-FIRST → FIXED

A 12-domain review was conducted on 2026-04-02 using 5 parallel review agents
plus manual verification of the full 3,289-line file and all supporting docs.

**Issue counts found:**

| Severity | Found | Fixed |
|----------|-------|-------|
| CRITICAL | 4 | 4 |
| HIGH | 13 | 13 |
| MEDIUM | 18 | 0 (deferred) |
| LOW | 12 | 0 (cosmetic) |

### CRITICAL Fixes Applied

| # | Finding | Fix |
|---|---------|-----|
| C1 | `dstat` package removed from Ubuntu 24.04 repos — apt failure | Replaced with `dool` |
| C2 | `torch.cuda.get_device_properties(0).total_mem` — AttributeError | Changed to `.total_memory` |
| C3 | Header said `nvidia-drm.modeset=0`/`fbdev=0` but GRUB/modprobe set `=1` | Updated header to `=1` |
| C4 | Header claimed `amdgpu.noretry=0` but absent from GRUB params | Added `amdgpu.noretry=0` to GRUB_PARAMS |

### HIGH Fixes Applied

| # | Finding | Fix |
|---|---------|-----|
| H1 | `nvidia-container-toolkit` repo added but package never installed | Added `apt-get install -y nvidia-container-toolkit` after repo setup |
| H2 | `torch.cuda.amp.autocast()` deprecated in PyTorch 2.4+ (6 occurrences) | Replaced with `torch.amp.autocast('cuda')` |
| H3 | `torch.cuda.amp.GradScaler()` deprecated | Replaced with `torch.amp.GradScaler('cuda')` |
| H4 | XFCE Ctrl+Q mapped to `xfce4-session-logout --fast` (instant logout) | Moved to xfwm4 `close_window_key` (close window, matches labwc) |
| H5 | Wallpaper `warty-final-ubuntu.png` not guaranteed by `ubuntu-desktop-minimal` | Added `ubuntu-wallpapers` to packages list |
| H6 | `nvidia-smi -pl 400` hardcoded — fails on RTX 4070 Ti Super (285W TDP) | Auto-detect via `nvidia-smi --query-gpu=power.max_limit` |
| H7 | Header said `shutdown: reboot` but actual value was `poweroff` | Updated header to `poweroff` |
| H8 | 7 config comments still said "Variant H" | Replaced with "Variant K-Next" |
| H9 | GNOME Wayland sessions not removed — accidental selection at LightDM | Added removal of `/usr/share/wayland-sessions/gnome*.desktop` etc. |
| H10 | CUDA samples build: `set -e` kills script before report on failure | Wrapped build with `set +e`/`set -e`, use `PIPESTATUS[0]` |
| H11 | Section 34 (CUDA Toolchain) imports torch but no venv/PyTorch | Added venv activation + warning if missing; fixed pynvml PEP 668 |
| H12 | Docker `data-root: /data/docker` on 200GB root partition | Moved to `/home/docker` (686GB home partition) |
| H13 | Partial firmware download (3/12 blobs) accepted silently | Require DMCUB blob + >=10/12 blobs before accepting |

### Remaining MEDIUM Issues (not yet fixed)

These are functional but suboptimal. Fix when convenient:

1. `amdgpu.vm_fragment_size=9` missing from GRUB (CLAUDE.md recommends it)
2. Duplicate NVIDIA udev rules between `99-gpu.rules` and `99-nvidia-compute.rules`
3. `fonts-inter` installed twice (package + GitHub ZIP)
4. Plank dock config at `/etc/xdg/plank/dock1/settings` ignored (Plank uses dconf)
5. swaylock `font`/`font-size` only supported by swaylock-effects, not vanilla
6. XFCE `xflock4` lock has no backend (`light-locker` not installed) — use `dm-tool lock`
7. `amdgpu.seamless=1` forced (CLAUDE.md says CAUTION) — consider auto
8. `amdgpu.dpm=1` in GRUB but not modprobe (breaks belt-and-suspenders pattern)
9. `cuda-keyring` failure silently masks section 29 CUDA install failure
10. Redundant sysctl values in both sysctl.d and systemd service
11. PPA `ppa:ful1metal/cursor-themes` leaves broken apt source on failure
12. Tray icon size mismatch: waybar=24, XFCE=28
13. SSH password auth enabled with no hardening
14. `xfce4-terminal -e` should be `-x` for robustness
15. `linux-headers-generic` (GA) unnecessary alongside HWE headers
16. Redundant `apt-get install` of build deps in CUDA samples script
17. 200GB root may be tight (CUDA + system packages)
18. `video=efifb:off` targets non-existent efifb (harmless)

### Cross-Reference Matrix Summary

All visual settings verified **CONSISTENT** across both sessions:
- DPI: 120 everywhere (GDK_DPI_SCALE=1.25, QT_SCALE_FACTOR=1.25)
- Cursor: Bibata-Modern-Classic 32px (6 locations)
- GTK Theme: Arc-Dark (6 locations)
- Icon Theme: Papirus-Dark (4 locations)
- Font: Inter 12 / JetBrains Mono 12 (8+ locations)
- Terminal Colors: Tokyo Night palette identical in xfce4-terminal and foot
