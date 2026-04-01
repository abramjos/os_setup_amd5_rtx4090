# /review-variant — Full Variant Audit & Documentation Update

Perform a complete forensic review of one autoinstall variant and its boot logs,
then update every affected documentation file.

**Invocation:** `/review-variant <LETTER>[_v<N>]`
Examples: `/review-variant J`, `/review-variant I_v1`, `/review-variant H`

---

## STEP 0 — Resolve Paths

From `$ARGUMENTS` (e.g. `J` or `J_v1`):

1. Derive **VARIANT_LETTER** (single letter, uppercase).
2. **YAML path**: `os/ubuntu/variants/autoinstall-<LETTER>-*.yaml` — glob to find exact filename.
3. **Log dir**: `logs/runlog-<LETTER>_v<N>/` — use the highest `vN` present, or the only one.
   If no log dir exists yet, note "no run data" and skip Phase 2.
4. Print resolved paths before proceeding so the user can confirm.

---

## PHASE 1 — YAML Deep Audit (read the full file)

Read the entire YAML. For every `late-commands` block, check:

### 1A. Validator checklist (replicate the validate-autoinstall.sh logic manually)
- [ ] `export PATH=...` appears before any `curl` or `wget` call
- [ ] USB fallback lists all 6 paths: `/cdrom /media/cdrom /mnt/usb /isodevice /run/live/medium /run/mnt/ubuntu-seed`
- [ ] `INSTALLED` counter increments only inside the `if curl ... then` success branch
- [ ] `lsinitramfs` uses installed-kernel detection, not `uname -r`
- [ ] BLOBS list is non-empty
- [ ] No `exec_always export VAR=x` (builtins fail silently)
- [ ] `update-initramfs` and `update-grub` use `curtin in-target --`
- [ ] Git version capture (`autoinstall-version.txt`) is present in `early-commands`
- [ ] No `: ` (colon-space) in single-line YAML list scalars inside `bash -c`

### 1B. Kernel parameter audit
Cross-check GRUB `GRUB_CMDLINE_LINUX_DEFAULT` against `modprobe.d/*.conf`.
Flag any parameter that appears in one place but conflicts with or is absent from the other.
Reference table from CLAUDE.md:
- `amdgpu.sg_display=0` — required; both GRUB and modprobe
- `amdgpu.dcdebugmask` — 0x10 (PSR off) or 0x18 (PSR+clock-gating off); must be consistent
- `amdgpu.ppfeaturemask=0xfffd7fff` — GFXOFF disable via feature mask
- `amdgpu.seamless` — document value and rationale
- `amdgpu.gfx_off=0` — **INVALID on kernel 6.17+**; flag as CRITICAL if present
- `amdgpu.reset_method=1` — **NOT SUPPORTED on Raphael APU**; flag as CRITICAL if present
- `nvidia-drm.modeset` — should be 0 for headless
- `nvidia_drm fbdev=0` — should be in modprobe for headless
- `initcall_blacklist=simpledrm_platform_driver_init` — required for card ordering
- `NVreg_RegisterPCIDriverOnEarlyBoot` — needed for proper NVIDIA boot ordering

### 1C. Display manager / compositor check
- Which DM is installed? Which is purged?
- Does the DM start a compositor during the boot DCN window (T+5-6s)?
- Is `AccelMethod "none"` set in xorg.conf? (required if DMCUB < 0.0.224.0 or as Condition 2 mitigation)
- Is `Virtual 8192 4320` needed for multi-display?

### 1D. Firmware section check
- Which `FW_TAG` is requested? (should be `20250509` or later)
- Does the firmware block have a `wget` fallback alongside `curl`?
- Are `.bin.zst` conflicts handled (compress + remove bare `.bin`)?
- Is the initramfs firmware hook present?

### 1E. Package list completeness
Flag any package that is:
- Listed but known to not exist in Ubuntu 24.04 repos
- Missing but required by a subsequent late-command (e.g., `zstd` must be in packages if used in late-commands)
- Conflicting (e.g., both `gdm3` and `sddm` without a purge step)

### 1F. Script logic bugs
Check every multi-line shell block for:
- `VAR=$(grep -c ... || echo 0)` — produces `"0\n0"` string (known bug pattern); correct form is `VAR=$(grep -c ...) || VAR=0`
- Bare `curtin in-target -- update-initramfs` (missing `bash -c`)
- `dconf update` called outside `curtin in-target --`
- `systemctl enable/disable` without `curtin in-target --`

---

## PHASE 2 — Log Forensics (read the run data)

Read these files in order. For each, record the key value and flag anomalies:

### 2A. System baseline (`01-kernel-system/`)
- `uname-a.txt` → kernel version, architecture
- `proc-cmdline.txt` → actual kernel parameters at boot (compare to YAML intent)
- `os-release.txt` → Ubuntu version
- `tainted.txt` → kernel taint flags (0 = clean; non-zero = investigate)
- `systemd-failed.txt` → list every failed unit; treat each as a separate issue
- `modules-load-status.txt` / `modules-load-journal.txt` → any module load failures

### 2B. AMD GPU driver (`02-amdgpu-driver/`)
- `dmesg-amdgpu.txt` → look for: `REG_WAIT timeout`, `optc31_disable_crtc`, `optc1_wait_for_state`, `ring gfx_0.0.0 timeout`, `MODE2 reset`, `DMUB hardware initialized: version=`, `Failed to load`, `probe -22`
- `dmesg-firmware.txt` → firmware load lines; extract DMCUB version (`0x05002000` is good; `0x05000F00` = old)
- `dmesg-ring-timeout.txt` → count of ring timeouts; 0 = pass, >0 = fail
- `dmesg-err-warn.txt` → all ERR/WARN lines; categorize by subsystem
- `amdgpu-params-accepted.txt` / `amdgpu-sysfs-params.txt` → actual loaded values vs YAML intent; flag any mismatch
- `gfx-off-check.txt` → GFX off state (should be 0 = disabled)

### 2C. DMCUB / DCN state (if `03-dmcub-dcn-state/` exists)
- `firmware-info.txt` → DMCUB version as loaded (cross-check with 2B)
- `amdgpu_ring_gfx_0.0.0.txt` → ring status; `rptr==wptr` = healthy
- `gpu-recover-status.txt` → reset count

### 2D. NVIDIA driver (`03-nvidia-driver/` or `05-nvidia-driver/`)
- `dmesg-nvidia.txt` → Xid errors, link state, probe messages
- `nvidia-smi.txt` → GPU detected, display_active=Disabled, display_mode=Disabled
- `lsmod-nouveau.txt` → nouveau must NOT be loaded

### 2E. Firmware (`04-firmware/` or `06-firmware/`)
- `firmware-package.txt` → `linux-firmware` dpkg version
- `firmware-conflicts.txt` → `.bin` AND `.bin.zst` both present = conflict (CRITICAL)
- `initramfs-amdgpu.txt` / `initramfs-firmware.txt` → firmware blobs present in initrd
- `debugfs-firmware-info.txt` → DMCUB version as seen by amdgpu debugfs

### 2F. Display / DM (`05-display/` or `07-display/`)
- `connectors-status.txt` → which outputs are connected; which card owns them
- `Xorg.0.log` → parse for: `(EE)` errors, GPU-specific lines, screen resolution
- `loginctl-sessions.txt` → active sessions
- `glxinfo.txt` (if present) → OpenGL renderer (must be AMD, not llvmpipe/swrast unless AccelMethod=none is intentional)
- DM journal (`gdm-journal.txt` / `lightdm-journal.txt` / `sddm-journal.txt`) → crashes, auth failures

### 2G. PCIe / hardware (`06-pci-hardware/` or `08-pci-hardware/`)
- `pcie-link-status.txt` / `lspci-nvidia-verbose.txt` → RTX 4090 link speed; Gen1 = CRITICAL (expected Gen4)
- `lspci-amd-verbose.txt` → iGPU BAR sizes
- `pcie-aer-errors.txt` → AER correctable/uncorrectable errors

### 2H. Power/thermal (`08-power-thermal/` or `09-power-thermal/`)
- `sysfs-pp_dpm_sclk.txt` → GPU clock state
- `gfx-off-check.txt` → GFXOFF status (must be 0)
- `sensors.txt` → temperatures

### 2I. DRM state (`07-drm-state/`)
- `drm-cards.txt` → card0 must be AMD (not NVIDIA)
- `debugfs-amdgpu_firmware_info.txt` → DMCUB version
- `debugfs-rings.txt` → all ring statuses
- `debugfs-dtn-log.txt` → DCN state machine log (look for `CRTC_DISABLED`, `OTG_BUSY`, `UNDERFLOW`)

### 2J. autoinstall-hw.log / autoinstall-version.txt (if present in log dir root)
- Check firmware source used (kernel.org / GitHub / USB / CRITICAL failure)
- Check variant ID and git commit recorded

---

## PHASE 3 — Web Research

For every distinct error string or anomaly found in Phases 1-2, spawn a websearch.
Prioritize searching:
- freedesktop.org GitLab drm/amd issues (append `site:gitlab.freedesktop.org`)
- kernel.org mailing list archives (`site:lore.kernel.org`)
- Ubuntu Launchpad bugs (`site:bugs.launchpad.net`)
- NixOS/Debian/Arch bug trackers for cross-distro confirmation

Mandatory searches:
1. Any new `REG_WAIT timeout` or `ring gfx timeout` error strings not yet in CLAUDE.md
2. Any Xid error codes from NVIDIA dmesg
3. Any new DMCUB version numbers seen (verify what fixed issues they contain)
4. Any `probe -22` or module parameter rejection messages
5. PCIe Gen1 downgrade cause for RTX 4090 on X670E if confirmed

Summarize each search: **Error → Root cause found? → Fix available? → Upstream bug link**

---

## PHASE 4 — Problem Catalog

Produce a numbered list of ALL problems found, sorted by severity:

```
CRITICAL  — System will not boot or GPU not functional
HIGH      — Intermittent crash or significant performance degradation
MEDIUM    — Suboptimal config, may affect stability under load
LOW       — Minor inconsistency, cosmetic, or documentation gap
INFO      — Observation, no action required
```

For each problem:
- **ID**: P1, P2, ...
- **Severity**: CRITICAL / HIGH / MEDIUM / LOW / INFO
- **Source**: YAML:line_number or LOG:filename
- **Description**: exact error text + what it means
- **Root cause**: mechanistic explanation
- **Fix**: specific change to YAML or config, with exact values
- **Upstream reference**: bug/commit link if found in Phase 3

---

## PHASE 5 — Cross-Variant Comparison

Read the headers/parameter sections of ALL other variant YAMLs (A through latest, skipping the current variant). Do NOT re-read full files — focus on:
- GRUB parameter lines
- modprobe option blocks
- Display manager section
- dcdebugmask value
- AccelMethod setting

Then produce a comparison table:

| Parameter | A | B | C | D | E | F | G | H | I | J |
|-----------|---|---|---|---|---|---|---|---|---|---|
| dcdebugmask | | | | | | | | | | |
| seamless | | | | | | | | | | |
| noretry | | | | | | | | | | |
| AccelMethod | | | | | | | | | | |
| Display Manager | | | | | | | | | | |
| DMCUB FW Tag | | | | | | | | | | |
| wget fallback | | | | | | | | | | |
| Virtual resolution | | | | | | | | | | |

Highlight cells where the current variant **diverges from the stable baseline (H)** in a way that is unexplained or potentially regressive.

---

## PHASE 6 — Documentation Updates

Make all updates in this order. Each update must be surgical — edit the specific section, do not rewrite unrelated content.

### 6A. DIAGNOSTIC-REFERENCE.md
- Update **Section 0: Test Run Results & Cross-Variant Evidence**
  - Add a new `### 0.x Run Summary` subsection for this variant/run
  - Use the exact same format as existing entries (table: boot#, kernel, DMCUB, optc31 count, ring timeout count, verdict)
  - Update the **Run Summary Matrix** table at the top of Section 0
- Update the header `Last tested:` date line

### 6B. os/ubuntu/DIAGNOSIS-PROGNOSIS.md
- Update the `> Date:` header line to add this variant's data reference
- Add a new section under the appropriate heading documenting this variant's findings
- Update the **Status** summary line at the top

### 6C. VARIANT-COMPARISON.html
- Add a new `<tr>` row to the main variants table for this run
- Columns: Variant, DM, Kernel Params delta, DMCUB version, optc31 count, Ring timeouts, Verdict, Notes
- Use existing row color scheme: green=PASS, yellow=PARTIAL, red=FAIL

### 6D. os/ubuntu/variants/GNOME-COMPARISON.md (if GNOME variant)
- Add or update the entry for this variant's specific GNOME/display findings
- Update the comparison table columns

### 6E. COMPATIBILITY-MATRIX.md
- If new kernel/firmware/DMCUB version data was found, add it to the relevant version table
- If a bug was confirmed or resolved, update that bug's status row

### 6F. MITIGATION-RESEARCH.md
- Add any new mitigation confirmed or disproven by this run to the appropriate section

### 6G. WAYLAND-COMPOSITOR-RESEARCH.md or X11-COMPOSITOR-RESEARCH.md
- If the variant tests a compositor (SDDM+GNOME, labwc, etc.), update that compositor's risk/status entry

### 6H. GNOME-MUTTER-HARDENING.md (if GNOME variant)
- Update any Mutter parameter findings from the run logs

### 6I. MULTI-DISPLAY-RESEARCH.md (if multi-display variant)
- Add empirical findings to the relevant section

### 6J. OS-CROSSCUTTING-CONCERNS.md
- Update NVIDIA driver version compatibility data if new nvidia-smi output was seen

### 6K. CLAUDE.md — Variant Testing Results table
- Add or update the row for this variant in the **Variant Testing Results** table under "Current Status & What Has Been Tried"

---

## PHASE 7 — Summary Report

Print a final structured summary:

```
=== VARIANT <LETTER> v<N> REVIEW COMPLETE ===

YAML: os/ubuntu/variants/autoinstall-<LETTER>-*.yaml
Logs: logs/runlog-<LETTER>_v<N>/

VERDICT: PASS / PARTIAL / FAIL / NO-RUN-DATA

Problems found: <N> CRITICAL, <N> HIGH, <N> MEDIUM, <N> LOW
Web searches completed: <N>
Documentation files updated: <N>

Key findings:
  1. <most important finding>
  2. <second most important>
  3. <third>

Recommended next action:
  <single concrete next step>
```

---

## Execution Notes

- Read log files with `Read` tool directly — do not use Bash cat.
- Run web searches in parallel when multiple independent errors need researching.
- When updating HTML files, match the existing indentation and color scheme exactly.
- Do NOT rewrite documentation sections that are not affected by this variant's findings.
- If a log file is empty or contains only "No output" / permission errors, note it as INFO and continue.
- Commit nothing — leave all changes staged for the user to review and commit.
