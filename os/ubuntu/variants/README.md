# Autoinstall Variant Testing Strategy

## Quick Decision Guide

| Situation | Use this variant |
|-----------|-----------------|
| **Proven production ML workstation** | **Variant K** — XFCE + labwc-pixman, dual-GPU, zero GFX ring, validated stable |
| **Production ML workstation** (previous) | **Variant H** — XFCE + labwc-pixman, dual-GPU, DMCUB 0x05002000 via initramfs |
| GNOME + multi-display (UNRELIABLE) | **Variant L** — GNOME Wayland + SDDM, intermittent ring timeouts on boot |
| **GNOME + multi-display (2-3 monitors)** | **Variant J** — GNOME Wayland + SDDM + monitors.xml, multi-display focused |
| GNOME/Wayland single display | Variant I — GNOME Wayland Extended, nvidia-drm.modeset=0 |
| No firmware update possible, need stability | Variant A — display-only, AccelMethod "none" |
| Firmware available, validate glamor rendering | Variant B — firmware fix + glamor |
| Full stack validation (B + NVIDIA) | Variant C |
| Wayland, CPU-only rendering | Variant D (labwc) or E (sway) |
| Modern X11 desktop, non-production | Variant F |
| GNOME/Wayland research (highest risk) | Variant G — GDM3, maximum GFX ring pressure test |

**Variant K is now the recommended production target.** GNOME (Variants G, I, J, L) remains unreliable — intermittent ring timeouts persist despite firmware fix + SDDM + Mutter hardening.

**Variant K** (2026-04-01, STABLE) — Same architecture as H with fixes from I/J lessons.
XFCE + labwc-pixman, NVIDIA headless, full CUDA. Zero ring timeouts, zero resets.

**Variant L** (2026-04-01, MARGINAL) — GNOME multi-display with SDDM replacing GDM3.
SDDM avoids GDM greeter crash but GNOME ring pressure NOT eliminated. Boot -1 had ring timeout.

**Variant H** — Previous production target (2026-03-31 stable, 72+ min uptime).
DMUB 0x05002000 via custom initramfs hook, XFCE + labwc-pixman, NVIDIA headless, full CUDA.

**Variant J** (2026-03-31, untested) — GNOME multi-display production target.
Extends Variant I: SDDM replaces GDM3, amdgpu.noretry=0, monitors.xml 2-display template,
scale-monitor-framebuffer + kms-modifiers dconf, autorandr. Test after Variant H confirms stable.

## Problem Statement

The ML workstation suffers from an intermittent crash loop caused by:
1. **DMCUB firmware 0x05000F00** (0.0.15.0) — critically outdated, predating all known fixes
2. **card0=NVIDIA** — wrong DRM card ordering despite initramfs ordering
3. **Xorg glamor** submitting to GFX ring on a partially broken DCN pipeline
4. **optc31_disable_crtc REG_WAIT timeout** during EFI-to-amdgpu handoff

## Three Variants for Isolation Testing

### Variant A: Display-Only (No NVIDIA) — TESTED PASS (2026-03-29)
**File:** `autoinstall-A-display-only.yaml`
**Purpose:** Isolate whether NVIDIA module coexistence causes the crash.

| Component | Configuration |
|-----------|--------------|
| NVIDIA driver | NOT INSTALLED |
| NVIDIA in initramfs | NO |
| Xorg AccelMethod | `none` (software rendering) |
| DMCUB firmware | Updated (linux-firmware tag 20250509) + initramfs hook |
| Compositor | XFCE, compositing OFF |
| GRUB params | No nvidia-drm.*, no seamless=1 |

**Test result (2026-03-29, runlog-A_v1):**
- optc31 REG_WAIT timeout: 1 at T+5.095s (deterministic, firmware bug)
- Ring gfx_0.0.0 timeout: **0 (PASS)**
- MODE2 GPU reset: **0 (PASS)**
- DMUB init count: 1 (clean)
- Card ordering: card0=amdgpu (PASS — initcall_blacklist working)
- Display: 3840x2160@60 on HDMI-A-1

**Conclusion:** Crash loop requires BOTH DCN stall AND compositor GL pressure. AccelMethod "none" eliminates Condition 2.

### Variant B: Display + Firmware Fix — TESTED PASS (2026-03-30)
**File:** `autoinstall-B-display-firmware.yaml`
**Purpose:** Test if updated DMCUB firmware resolves the crash loop.

| Component | Configuration |
|-----------|--------------|
| NVIDIA driver | NOT INSTALLED |
| DMCUB firmware | **Updated** (linux-firmware tag 20250509) + initramfs hook |
| Xorg AccelMethod | `glamor` (GL acceleration enabled) |
| Compositor | XFCE, compositing OFF |
| GRUB params | seamless=1 re-enabled |

**Test result (2026-03-30, runlog-B_v2, 8 boots):**

| Boot | DMUB | Ring Timeouts | Verdict |
|------|------|---------------|---------|
| -6 | 0x05000F00 (old) | **4** | UNSTABLE |
| -4 | 0x05000F00 (old) | **1** | DEGRADED |
| -2 | 0x05000F00 (old) | 0 | STABLE (intermittent) |
| -1 | **0x05002000 (new)** | **0** | **STABLE (firmware fix)** |

**Conclusion:** DMUB firmware upgrade 0x05000F00 → 0x05002000 eliminates ring timeouts with glamor enabled. optc31 timeout still fires at T+5s but no longer cascades. **Firmware was the root cause. Proceed to Variant C.**

**Note:** Initial B_v1 test failed because firmware was on disk but not in initramfs. Fixed by adding custom initramfs hook to all variants.

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
         |-- PASS ✓ (2026-03-29) --> Proves two-condition crash model
         |
Step 3: Boot Variant B (firmware fix, critical milestone)
         |-- PASS ✓ (2026-03-30) --> DMUB 0x05002000 stable with glamor
         |
Step 4: Boot Variant C (full stack with NVIDIA)
         |-- PASS --> Production ready
         |-- FAIL --> NVIDIA interaction issue, use Variant B for now
         |
Step 5: Boot Variant H (production target: dual-session desktop)
         |-- PASS --> Ship it
         |-- FAIL --> Use Variant F (modern XFCE) or D/E (Wayland)
         |
Step 7: Boot Variant K (Modern Desktop v2)    [DONE - STABLE (2026-04-01)]
         |-- Validates H config under new letter, PCIe Gen1 BIOS fix needed
Step 8: Boot Variant L (GNOME Multi-Display)  [DONE - MARGINAL (2026-04-01)]
         |-- SDDM avoids GDM crash but GNOME ring pressure NOT eliminated
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

## Post-Firmware Compositor Variants (D/E/F/G/H)

**Variant B firmware milestone reached 2026-03-30** — DMUB 0x05002000 confirmed stable with glamor. All compositor variants below are now viable for testing.

### Variant D: labwc + pixman (Wayland, Stacking, Zero GFX Ring)
**File:** `autoinstall-D-labwc-pixman.yaml`
**Purpose:** wlroots-based stacking compositor with CPU-only rendering.

| Component | Configuration |
|-----------|--------------|
| NVIDIA driver | NOT INSTALLED |
| Compositor | **labwc** (wlroots stacking, Openbox-like) |
| Renderer | **pixman** (CPU-only, zero GFX ring) |
| Display Manager | LightDM (Wayland session) |
| Desktop tools | waybar, foot, thunar, wofi, mako |
| Risk | **LOWEST** — zero GPU compositing |

### Variant E: Sway + pixman (Wayland, Tiling, Zero GFX Ring)
**File:** `autoinstall-E-sway-pixman.yaml`
**Purpose:** i3-compatible tiling compositor with CPU-only rendering.

| Component | Configuration |
|-----------|--------------|
| NVIDIA driver | NOT INSTALLED |
| Compositor | **Sway** (wlroots tiling, i3-compatible) |
| Renderer | **pixman** (CPU-only, zero GFX ring) |
| Display Manager | LightDM (Wayland session) |
| Desktop tools | waybar, foot, thunar, wofi, grim, slurp, mako |
| Risk | **LOWEST** — zero GPU compositing, idle = zero CPU |

### Variant F: Modern XFCE (X11, XRender Compositing ON, Arc Theme)
**File:** `autoinstall-F-modern-xfce.yaml`
**Purpose:** Best-looking X11 desktop. xfwm4 XRender compositing (CPU-side).

| Component | Configuration |
|-----------|--------------|
| NVIDIA driver | NOT INSTALLED |
| Compositor | **xfwm4** (XRender, compositing ON, vblank=xpresent) |
| AccelMethod | glamor |
| Theme | **Arc-Dark** + Papirus icons + Inter font + Plank dock |
| Display Manager | LightDM (themed greeter) |
| Risk | **LOW** — XRender is CPU-side, no GFX ring for compositing |

**Key:** `vblank_mode=xpresent` NOT `glx`. GLX creates an OpenGL context (GFX ring). Xpresent uses DRM page-flip events (no GL).

### Variant G: GNOME (Mutter) Post-Firmware-Fix (Full Stack)
**File:** `autoinstall-G-gnome-full.yaml`
**Purpose:** "Can we go back to GNOME?" Full Ubuntu GNOME + Mutter + GDM3 + NVIDIA.

| Component | Configuration |
|-----------|--------------|
| NVIDIA driver | **INSTALLED** (auto from repos + CUDA keys) |
| Compositor | **Mutter/GNOME Shell** (OpenGL, Wayland) |
| Display Manager | **GDM3** (Wayland enabled) |
| Mitigations | MUTTER_DEBUG_KMS_THREAD_TYPE=user, MUTTER_DEBUG_DISABLE_HW_CURSORS=1 |
| ML stack | Docker, CUDA env, nvidia-power-limit, sysctl tuning |
| Risk | **HIGHEST** — intentionally tests maximum GFX ring pressure |

### Variant H: Modern Desktop (Dual-Session, Zero GFX Ring, Full ML Stack)
**File:** `autoinstall-H-modern-desktop.yaml`
**Purpose:** "Best of all worlds" — most polished, GNOME/macOS-like desktop with zero GFX ring pressure, NVIDIA headless compute, and maximum functionality.

| Component | Configuration |
|-----------|--------------|
| NVIDIA driver | **INSTALLED** (headless compute only, no display) |
| Session 1 (X11) | **XFCE** — xfwm4 XRender (vblank=xpresent), AccelMethod "none", Plank dock |
| Session 2 (Wayland) | **labwc** — WLR_RENDERER=pixman, waybar top+dock, wofi launcher, mako |
| Display Manager | **LightDM** (dual-session: XFCE + labwc-pixman selectable at login) |
| Theme | **Arc-Dark** + Papirus-Dark + Bibata-Modern-Classic + Inter font (both sessions) |
| ML stack | Docker, CUDA env, nvidia-power-limit, sysctl tuning |
| Risk | **LOWEST** — zero GFX ring in BOTH sessions |

**Key:** Combines Variant F (modern XFCE), Variant D (labwc pixman), and Variant G (NVIDIA+ML stack) into one dual-session variant. Users choose X11 or Wayland at LightDM login. Both sessions share the same visual identity.

**Known limitations:**
1. Screen sharing broken in labwc session (pixman can't provide DMABUF). Use XFCE session.
2. nm-applet tray limited on Wayland — waybar network module + nmcli instead.
3. Plank dock is X11-only — labwc session uses waybar bottom dock.
4. Thunar on labwc via XWayland — drag-and-drop between X11/Wayland apps may have issues.
5. swaylock-effects (blur) not in repos — solid color lock screen only.

### Variant I: GNOME Wayland Extended — Single Display
**File:** `autoinstall-I-gnome-wayland-extended.yaml`
**Purpose:** Production GNOME Wayland with nvidia-drm.modeset=0 (single KMS device, AMD only).

| Component | Configuration |
|-----------|--------------|
| NVIDIA driver | **INSTALLED** (compute only, nvidia-drm.modeset=0 — no KMS) |
| Compositor | **Mutter/GNOME Shell** (Wayland, glamor) |
| Display Manager | **GDM3** (greeter hardened with Mutter env vars) |
| Mitigations | MUTTER_DEBUG_KMS_THREAD_TYPE=user, MUTTER_DEBUG_DISABLE_HW_CURSORS=1, animations=false, check-alive-timeout=30000, fractional scaling |
| ML stack | Docker, CUDA env, nvidia-power-limit, sysctl tuning |
| Risk | **HIGH** (reduced from G: single KMS eliminates dual-RT-thread deadlock) |

### Variant J: GNOME Multi-Display (SDDM, 2-3 Monitors) — UNTESTED
**File:** `autoinstall-J-gnome-multidisplay.yaml`
**Purpose:** Production GNOME Wayland with explicit multi-display support. SDDM eliminates the GDM3 gnome-shell greeter crash window. Designed for 2-3 monitors on Raphael iGPU.

| Component | Configuration |
|-----------|--------------|
| NVIDIA driver | **INSTALLED** (compute only, nvidia-drm.modeset=0) |
| Compositor | **Mutter/GNOME Shell** (Wayland, glamor) |
| Display Manager | **SDDM** (Qt greeter — no compositor at login, GDM3 purged) |
| Multi-display | monitors.xml template (HDMI-1 + DP-1, 2560×1440), autorandr, arandr |
| New kernel params | `amdgpu.noretry=0` (added to Variant I params) |
| New dconf | `scale-monitor-framebuffer`, `kms-modifiers`, sleep-inactive disabled |
| ML stack | Docker, CUDA env, nvidia-power-limit, sysctl tuning |
| Risk | **MEDIUM** — SDDM eliminates greeter risk; GNOME GFX ring pressure remains |

**Key differences from Variant I:**
1. SDDM replaces GDM3 — gnome-shell never runs at login screen
2. `amdgpu.noretry=0` — re-enables APU fault retry, reduces spurious GPU resets during multi-display framebuffer setup
3. monitors.xml pre-configured for 2 monitors; adjust connector names post-install
4. `experimental-features=['scale-monitor-framebuffer', 'kms-modifiers']` in dconf

**Post-install checklist:**
```bash
# 1. Verify SDDM running (not GDM3)
systemctl status sddm
# 2. Verify DMUB firmware
dmesg | grep "DMUB hardware initialized"  # expect: version=0x05002000
# 3. Verify single KMS device (AMD only)
ls /dev/dri/by-path/  # should show amdgpu card, no nvidia-drm card
# 4. Verify multi-display
gnome-randr  # or: DISPLAY=:0 xrandr (from X11 terminal)
# 5. Check ring timeout absence
dmesg | grep -c "ring gfx.*timeout"  # must be 0
# 6. Adjust monitors.xml to actual connector names
cat /sys/class/drm/card*/card*-*/status  # list connected outputs
```

### Variant K: Modern Desktop v2 (Dual-Session, Zero GFX Ring, Full ML Stack)
**File:** `autoinstall-K-modern-desktop.yaml`
**Purpose:** Same architecture as H but with fixes from I/J lessons. Validated stable production target.

| Component | Configuration |
|-----------|--------------|
| NVIDIA driver | **INSTALLED** (headless compute only, no display) |
| Session 1 (X11) | **XFCE** — xfwm4 XRender (vblank=xpresent), AccelMethod "none" |
| Session 2 (Wayland) | **labwc** — WLR_RENDERER=pixman |
| Display Manager | **LightDM** (dual-session: XFCE + labwc-pixman selectable at login) |
| GRUB params | nvidia-drm.modeset=1 (should be 0 — to fix) |
| ML stack | Docker, CUDA env, nvidia-power-limit, sysctl tuning |
| Risk | **LOWEST** — zero GFX ring in BOTH sessions |

**Test result (2026-04-01):** STABLE — 0 ring timeouts, 0 resets.

**Key differences from Variant H:**
1. Incorporates fixes and lessons learned from Variant I and J testing
2. nvidia-drm.modeset=1 currently set (should be corrected to 0 for headless NVIDIA)
3. PCIe Gen1 BIOS fix needed

### Variant L: GNOME Multi-Display (SDDM + Wayland, 2-3 Monitor iGPU)
**File:** `autoinstall-L-gnome-multidisplay.yaml`
**Purpose:** GNOME Wayland with SDDM replacing GDM3 to avoid greeter crash window. Designed for 2-3 monitors on Raphael iGPU.

| Component | Configuration |
|-----------|--------------|
| NVIDIA driver | **INSTALLED** (compute only, nvidia-drm.modeset=0) |
| Compositor | **Mutter/GNOME Shell** (Wayland, glamor) |
| Display Manager | **SDDM** (Qt greeter — no compositor at login, GDM3 purged) |
| Kernel params | `amdgpu.noretry=0` (APU fault retry) |
| Mutter hardening | GNOME Wayland with Mutter hardening (KMS thread=user, HW cursors off, animations off) |
| ML stack | Docker, CUDA env, nvidia-power-limit, sysctl tuning |
| Risk | **MEDIUM-HIGH** — intermittent ring timeouts on some boots |

**Test result (2026-04-01):** MARGINAL — boot -1 had ring timeout, boot 0 clean.

**Key differences from Variant J:**
1. SDDM autologin successfully avoids GDM boot-window crash
2. GNOME Wayland session launches without crash on clean boots
3. BUT: boot -1 had 1 ring gfx timeout — GNOME ring pressure is NOT eliminated by firmware fix alone
4. dm_irq_work_func CPU hog (10ms+ stalls) at T+257s in steady state
5. Conclusion: GNOME/Mutter is architecturally incompatible with Raphael iGPU for production use

## Extended Testing Workflow

```
Step 1: Boot Variant A (display isolation)
         |
Step 2: Boot Variant B (firmware fix — CRITICAL MILESTONE)
         |-- PASS --> Choose path:
         |
         |   Path 1 (Best):        K (Modern Desktop v2 — zero GFX ring, validated stable)
         |   Path 1b (Previous):   H (Modern Desktop — zero GFX ring, full ML)
         |   Path 2 (GNOME+multi): L (GNOME multi-display, SDDM — MARGINAL)
         |   Path 2b (Untested):   J (GNOME multi-display, SDDM — untested)
         |   Path 3 (GNOME+single):I (GNOME Wayland Extended, GDM3)
         |   Path 4 (Wayland):     D (labwc+pixman) or E (Sway+pixman)
         |   Path 5 (X11):         F (Modern XFCE + compositing)
         |   Path 6 (Risk test):   G (GNOME, max GFX ring pressure)
         |
         |-- FAIL --> Check Xorg.0.log, try Variant A
         |
Step 3: Boot chosen variant
         |
         K PASS = Production ready (zero GFX ring, validated stable)
         H PASS = Production ready (zero GFX ring, most stable)
         L MARGINAL = GNOME ring pressure NOT eliminated; use K instead
         J PASS = GNOME multi-display production ready
         J FAIL = Use K as desktop; investigate GNOME ring pressure
```

**Recommended path:** Variant B (confirm firmware fix) -> **Variant K** (production desktop). **Variant K is now the recommended production target. GNOME (Variants G, I, J, L) remains unreliable — intermittent ring timeouts persist despite firmware fix + SDDM + Mutter hardening.**

## Verification Commands by Variant

```bash
# Variant D (labwc)
echo $WAYLAND_DISPLAY       # wayland-1 or similar
echo $WLR_RENDERER           # pixman
pgrep -a labwc               # running

# Variant E (Sway)
swaymsg -t get_version       # sway version
echo $WLR_RENDERER           # pixman

# Variant F (Modern XFCE)
xfconf-query -c xfwm4 -p /general/use_compositing    # true
xfconf-query -c xfwm4 -p /general/vblank_mode         # xpresent
xfconf-query -c xsettings -p /Net/ThemeName           # Arc-Dark
pgrep -a plank                                        # running

# Variant G (GNOME)
echo $XDG_CURRENT_DESKTOP    # ubuntu:GNOME
echo $XDG_SESSION_TYPE       # wayland
pgrep -a gnome-shell         # running
nvidia-smi                   # RTX 4090 visible

# Variant H — XFCE session (X11, zero GFX ring)
xfconf-query -c xfwm4 -p /general/use_compositing    # true
xfconf-query -c xfwm4 -p /general/vblank_mode         # xpresent
xfconf-query -c xsettings -p /Net/ThemeName           # Arc-Dark
grep AccelMethod /var/log/Xorg.0.log                   # none
pgrep plank                                            # running

# Variant H — labwc session (Wayland, zero GFX ring)
echo $WLR_RENDERER                                     # pixman
echo $XDG_CURRENT_DESKTOP                              # wlroots
pgrep -c waybar                                        # 2 (top + dock)
pgrep mako                                             # running
pgrep labwc                                            # running

# Variant H — dual-session available at LightDM
ls /usr/share/xsessions/xfce.desktop                   # exists
ls /usr/share/wayland-sessions/labwc-pixman.desktop     # exists

# Variant H — NVIDIA headless
nvidia-smi --query-gpu=display_active --format=csv     # Disabled

# Variant H — unified theme
gsettings get org.gnome.desktop.interface gtk-theme    # Arc-Dark

# Variant K — XFCE session (X11, zero GFX ring)
xfconf-query -c xfwm4 -p /general/use_compositing    # true
xfconf-query -c xfwm4 -p /general/vblank_mode         # xpresent
grep AccelMethod /var/log/Xorg.0.log                   # none
pgrep plank                                            # running (if configured)

# Variant K — labwc session (Wayland, zero GFX ring)
echo $WLR_RENDERER                                     # pixman
echo $XDG_CURRENT_DESKTOP                              # wlroots
pgrep labwc                                            # running

# Variant K — dual-session available at LightDM
ls /usr/share/xsessions/xfce.desktop                   # exists
ls /usr/share/wayland-sessions/labwc-pixman.desktop     # exists

# Variant K — NVIDIA headless
nvidia-smi --query-gpu=display_active --format=csv     # Disabled

# Variant L — SDDM running (not GDM3)
systemctl status sddm                                  # active
systemctl status gdm3 2>/dev/null || echo "GDM3 not installed"

# Variant L — GNOME Wayland session
echo $XDG_CURRENT_DESKTOP                              # ubuntu:GNOME
echo $XDG_SESSION_TYPE                                  # wayland
pgrep -a gnome-shell                                   # running

# Variant L — NVIDIA headless
nvidia-smi --query-gpu=display_active --format=csv     # Disabled

# All variants — crash indicators (MUST all be 0/empty)
dmesg | grep -c "ring gfx.*timeout"    # 0
dmesg | grep -c "MODE2"                # 0
dmesg | grep -c "REG_WAIT timeout"     # 0
journalctl -b | grep -i sigkill        # empty
```

## Key Fixes Applied Across All Variants

| Issue from runLog-00 | Fix Applied |
|---------------------|-------------|
| DMCUB 0x05000F00 (too old) | Variant B/C/D/E/F/G/H/K/L: firmware from USB |
| card0=NVIDIA (wrong order) | Explicit BusID PCI:108:0:0 in Xorg (B/C/F/G/H/K) |
| video=HDMI-A-1:1920x1080@60 rejected | Removed (let DRM auto-detect) |
| Xorg glamor → ring timeout | Variant A/H/K: AccelMethod none; D/E: no Xorg |
| amdgpu.seamless=1 ineffective | Variant A: removed; all others: re-enabled with new firmware |
| NVIDIA 580 instead of 595 | Noted; 595 via CUDA repo post-install |
| dcdebugmask=0x10 | Changed to 0x18 (disable PSR + DCN clock gating) |
| gnome-shell processes | Variant G: intentional test; H/K: masked; L: SDDM avoids greeter; others: diverted/disabled |
| Mutter RT thread SIGKILL | MUTTER_DEBUG_KMS_THREAD_TYPE=user (all GNOME variants incl. L) |
| GDM3 greeter crash window | Variant L: SDDM replaces GDM3; Variant K: LightDM (no GNOME) |
| nvidia-drm.modeset=1 (incorrect) | Variant K: set to 1, should be 0 — to fix |
| GNOME ring pressure (persistent) | Variant L: confirmed NOT eliminated by firmware fix + SDDM + Mutter hardening |
| amdgpu.noretry=0 (APU fault retry) | Variant J/L: re-enables fault retry for multi-display framebuffer setup |

## Critical Findings Per Variant

> Full interactive comparison: **[VARIANT-COMPARISON.html](../../VARIANT-COMPARISON.html)**

### Variant A: Display-Only
- **Diagnostic-only** — NOT a production desktop. Answers "is the crash purely AMD?"
- Uses stock firmware (0.0.15.0) — still vulnerable to the exact crash
- AccelMethod "none" = zero GPU load but also zero performance
- If A crashes: firmware is 100% the root cause. If A is stable: NVIDIA coexistence contributes.

### Variant B: Firmware Fix (CRITICAL MILESTONE)
- **Everything depends on this.** DMCUB ≥0.0.255.0 fixes the state machine that manages CRTC disable/enable.
- Re-enables `glamor` + `amdgpu.seamless=1` (both need working firmware)
- The `.bin.zst` preference is handled: late-commands compress firmware and remove bare `.bin` files
- If B PASS → all subsequent variants are viable. If B FAIL → deeper investigation needed.

### Variant C: Full Stack
- First variant with NVIDIA — tests `softdep nvidia pre: amdgpu` module ordering
- ML stack (Docker, Python, CUDA env) but still using XFCE with compositing OFF
- Medium-high risk: NVIDIA module coexistence is untested with new firmware
- nvidia-power-limit.service caps RTX 4090 at 400W

### Variant D: labwc + pixman
- **Zero GFX ring** — pixman renderer does ALL compositing on CPU
- Crash-proof even if firmware fix is incomplete (breaks two-condition model)
- labwc 0.7.x is relatively new — smaller community than Sway
- Stacking WM (familiar drag-and-drop) but no settings GUI

### Variant E: Sway + pixman
- **Zero GFX ring + zero CPU when idle** — Sway's scene-graph damage tracking only redraws changed pixels
- Best for ML workstation where desktop sits idle during long training runs
- i3-compatible keybinds — large existing community and documentation
- Steep learning curve for non-tiling-WM users

### Variant F: Modern XFCE
- **Best visual quality** of non-GNOME variants (Arc-Dark + Papirus + Plank + Inter font)
- **Critical:** `vblank_mode=xpresent` NOT `glx` — GLX creates an OpenGL context (GFX ring), xpresent uses DRM page-flip events (no GL)
- XRender compositing provides shadows/transparency without GPU compositing
- glamor AccelMethod still uses GFX ring for 2D acceleration (low but non-zero)

### Variant G: GNOME Full Stack
- **Highest risk** — intentionally tests maximum GFX ring pressure via Mutter GL compositing
- 7 mitigations applied: KMS thread=user, HW cursors off, animations off, check-alive-timeout=30000, cursor-blink off, lockup_timeout=30000, GDM greeter hardening
- Full ML stack (same as C) + GNOME Shell + GDM3 + Wayland
- **Production target if firmware fix works** — most modern UI, best app ecosystem
- gnome-shell was the crash trigger in EVERY previous failure — this variant tests if firmware eliminates the root cause

### Variant K: Modern Desktop v2 (RECOMMENDED)
- **Validated stable** — 0 ring timeouts, 0 resets (2026-04-01)
- Same architecture as H: XFCE + labwc-pixman dual-session, LightDM, NVIDIA headless compute
- Incorporates fixes from Variant I/J lessons learned
- nvidia-drm.modeset=1 currently set (should be corrected to 0 for headless NVIDIA)
- PCIe Gen1 BIOS fix needed
- **Production target** — supersedes Variant H as recommended path

### Variant L: GNOME Multi-Display (MARGINAL)
- **SDDM successfully avoids GDM greeter crash** — gnome-shell never runs at login screen
- GNOME Wayland session launches without crash on clean boots
- **BUT: boot -1 had 1 ring gfx timeout** — GNOME ring pressure is NOT eliminated by firmware fix alone
- dm_irq_work_func CPU hog (10ms+ stalls) at T+257s in steady state
- **Conclusion:** GNOME/Mutter is architecturally incompatible with Raphael iGPU for production use
- The GL compositing pipeline creates intermittent GFX ring pressure that, combined with the optc31 DCN stall, produces timing-dependent ring timeouts
