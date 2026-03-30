# X11 Compositor & Desktop Environment Research for Raphael iGPU DCN Stall Scenario

**Hardware:** AMD Ryzen 9 7950X (Raphael, RDNA2 iGPU, GC 10.3.6, DCN 3.1.5)
**Target OS:** Ubuntu 24.04 LTS (Noble Numbat)
**Date:** 2026-03-29
**Purpose:** Identify all X11-based compositor/desktop options that avoid or survive the optc31_disable_crtc crash loop

---

## The Problem Statement

The crash loop requires **two simultaneous conditions**:

1. **DCN pipeline stall** -- `optc31_disable_crtc` REG_WAIT timeout during EFI-to-amdgpu handoff (DMCUB firmware 0.0.15.0 is critically outdated)
2. **GFX ring pressure from compositor** -- compositor submits OpenGL commands to the GFX ring while DCN is stalled, causing ring timeout, MODE2 reset (which does NOT reset DCN), creating infinite crash loop

**Remove condition 2 and the crash loop breaks**, even if the DCN stall still occurs. The goal is to identify every X11 compositor option ranked by GFX ring pressure.

### How GFX Ring Pressure Works

The amdgpu kernel driver uses **ring buffers** to communicate between userspace and GPU hardware. The Command Processor (CP) reads packets from the GFX ring and distributes instructions to GPU pipeline stages. When the DCN is stalled:

- **OpenGL compositors** (Mutter, KWin, Cinnamon/Muffin) submit GL draw calls through Mesa/radeonsi, which generate command buffer packets on the GFX ring. If DCN is stalled, these commands hang waiting for display state, causing `amdgpu_job_timedout`.
- **XRender compositors** (xfwm4, Marco) use the X Render extension, which on modern amdgpu+glamor translates to GL internally via glamor. However, with `AccelMethod "none"`, XRender operations are CPU-only and generate **zero** GFX ring submissions.
- **No-compositor window managers** (i3, bspwm, dwm, Openbox without picom) generate zero GFX ring submissions for window management. Only client applications using OpenGL/Vulkan would touch the ring.

---

## AccelMethod Analysis (Critical for All Options)

### Available AccelMethods for amdgpu DDX

The `xf86-video-amdgpu` DDX driver supports these AccelMethod values:

| AccelMethod | 2D Rendering | GFX Ring Usage | DRI3/VAAPI | Page Flipping | Desktop Usability |
|-------------|-------------|----------------|------------|---------------|-------------------|
| **"glamor"** (default) | GPU via OpenGL (radeonsi) | **YES -- all 2D ops go through GFX ring** | Full DRI3 + VAAPI | Yes | Best performance |
| **"none"** | CPU software rendering | **ZERO -- no GFX ring submissions for 2D** | DRI3 works; DRI2 broken (fd.o #94220); VAAPI works via DRI3 | Disabled (ShadowPrimary implied) | Adequate for desktop; slower 2D |

**EXA is NOT available** for amdgpu. It was deprecated and removed; only glamor and none exist.

### AccelMethod "none" -- Detailed Analysis

**What it does:**
- All 2D rendering (window borders, text, rectangles, compositing) is performed by CPU
- The `glamor` library is not loaded; no OpenGL context is created for 2D acceleration
- 3D applications (GL clients, Vulkan) still use the GPU normally via DRI3
- Video decode (VAAPI) still works via DRI3 path

**Known issue:** [freedesktop.org Bug #94220](https://bugs.freedesktop.org/show_bug.cgi?id=94220) -- `AccelMethod "none"` breaks DRI2 and VDPAU. This bug was filed in 2016. DRI2 is the legacy path; DRI3 (the default since xorg-server 1.18.3) is unaffected. VDPAU via DRI2 breaks, but VAAPI via DRI3 works fine. On Ubuntu 24.04 with DRI3 as default, this bug is **not a practical concern**.

**Performance impact:**
- Window dragging, scrolling, text rendering: slightly slower (CPU-bound instead of GPU-accelerated)
- On a Ryzen 9 7950X with 16 cores, CPU overhead is negligible for desktop 2D operations
- 3D applications, video playback, CUDA compute: completely unaffected

**ShadowPrimary option:** When using `AccelMethod "none"`, the `ShadowPrimary` option (creates a CPU-accessible shadow buffer for fast CPU pixel access with separate scanout buffers per CRTC) is effectively implied. Explicitly setting it is unnecessary but harmless. Note: ShadowPrimary disables page flipping.

### amdgpu DDX xorg.conf Options Reference

| Option | Default | Description |
|--------|---------|-------------|
| `AccelMethod` | "glamor" | "glamor" for GPU 2D accel, "none" for CPU 2D |
| `ShadowPrimary` | off | Shadow buffer for CPU access; disables page flipping |
| `DRI` | 3 (xorg >= 1.18.3) | DRI level: 2 or 3 |
| `TearFree` | auto | Hardware page-flip tear prevention |
| `EnablePageFlip` | on | DRI2 page flipping |
| `VariableRefresh` | off | VRR/FreeSync support |
| `AsyncFlipSecondaries` | off | Async flips for multi-display |

### Recommendation: AccelMethod Strategy

| Scenario | Recommended AccelMethod | Rationale |
|----------|------------------------|-----------|
| **DCN stall still occurring** (pre-firmware-fix) | **"none"** | Zero GFX ring pressure; prevents crash loop entirely |
| **DCN stall fixed** (post-firmware-fix, stable) | **"glamor"** | Full GPU 2D acceleration; best performance |
| **Transitional testing** | **"none"** initially, switch to "glamor" after 10+ clean boots | Safe approach during stabilization |

### modesetting DDX vs xf86-video-amdgpu

Ubuntu 24.04 can also use the generic `modesetting` DDX (built into xorg-server) instead of `xf86-video-amdgpu`. The modesetting DDX always uses glamor and has no `AccelMethod "none"` option. For maximum control over GFX ring pressure, **use xf86-video-amdgpu** with `AccelMethod "none"`. Phoronix benchmarks show near-identical 3D performance between the two DDX drivers; the difference only affects 2D operations.

---

## Compositor/Desktop Research

### Evaluation Criteria

For each option:
- **GL Backend**: What rendering API the compositor uses (OpenGL, XRender, none)
- **GFX Ring Pressure**: How many GFX ring submissions the compositor generates during normal operation
- **AccelMethod "none" Compat**: Whether the compositor works with `AccelMethod "none"` in xorg.conf
- **No-Compositing Mode**: Whether 3D compositing can be fully disabled
- **Risk Level**: Risk of triggering the DCN stall crash loop (SAFE/LOW/MEDIUM/HIGH/CRITICAL)

---

### TIER 1: ZERO GFX RING PRESSURE (Safest)

These options generate zero GFX ring submissions for window management. Combined with `AccelMethod "none"`, the entire desktop operates with zero ring pressure.

---

#### 1. XFCE4 + xfwm4 (Compositing OFF) -- CONFIRMED WORKING BASELINE

| Property | Value |
|----------|-------|
| **Ubuntu 24.04 Package** | `xfce4` (meta), `xfwm4` 4.18.x |
| **Install** | `sudo apt install xfce4 xfce4-goodies lightdm` |
| **GL Backend** | None. xfwm4 uses **XRender only** -- no OpenGL whatsoever in the compositor |
| **GFX Ring Pressure** | **ZERO** (with compositing OFF) / **VERY LOW** (with compositing ON, XRender is CPU-side) |
| **AccelMethod "none" Compat** | Excellent -- designed to work without GL acceleration |
| **No-Compositing Mode** | Yes: Settings > Window Manager Tweaks > Compositor > uncheck "Enable display compositing" |
| **RAM Usage** | ~350-450 MB idle |
| **CPU Usage** | <2% idle |
| **Known Raphael Issues** | None when compositing is OFF. With compositing ON, tearing possible without TearFree. |
| **Risk Level** | **SAFE** -- confirmed zero ring timeouts, zero resets |

**Technical detail:** xfwm4's compositor relies on Xcomposite, Xfixes, Xdamage, and XRender X11 extensions. It does NOT use OpenGL for rendering. The vblank sync (added in 4.13) can optionally use GLX (via libepoxy) or Xpresent, but this is solely for sync timing, not rendering. With compositing OFF, even this vblank path is inactive.

**Display Manager:** Use **LightDM** instead of GDM3. GDM3 spawns gnome-shell for the login greeter, which generates OpenGL ring pressure. LightDM uses a lightweight GTK greeter with zero GL.

**vblank_mode configuration:**
```bash
# Use Xpresent for vblank (no GLX):
xfconf-query -c xfwm4 -p /general/vblank_mode -t string -s "xpresent" --create
# Or disable entirely:
xfconf-query -c xfwm4 -p /general/vblank_mode -t string -s "off" --create
```

---

#### 2. i3wm (Tiling WM, No Compositor)

| Property | Value |
|----------|-------|
| **Ubuntu 24.04 Package** | `i3-wm` 4.23-1 (or `i3` meta-package) |
| **Install** | `sudo apt install i3 lightdm lightdm-gtk-greeter` |
| **GL Backend** | **None** -- i3 is a pure tiling window manager with zero rendering |
| **GFX Ring Pressure** | **ZERO** |
| **AccelMethod "none" Compat** | Perfect -- no GL dependency |
| **No-Compositing Mode** | Default -- i3 has no built-in compositor |
| **RAM Usage** | ~100-200 MB idle (i3 alone, no DE) |
| **CPU Usage** | <1% idle |
| **Known Raphael Issues** | None reported |
| **Risk Level** | **SAFE** |

**Pros:** Absolute minimum GPU usage. Keyboard-driven workflow efficient for ML workstation. Highly scriptable. Status bar (i3status/polybar) is purely CPU-rendered.

**Cons:** No window decorations, no drag-and-drop, steep learning curve. No desktop icons, file manager integration, or system tray without additional packages.

---

#### 3. Openbox (Stacking WM, No Built-in Compositor)

| Property | Value |
|----------|-------|
| **Ubuntu 24.04 Package** | `openbox` 3.6.1-12build5 |
| **Install** | `sudo apt install openbox obconf obmenu tint2 lightdm lightdm-gtk-greeter` |
| **GL Backend** | **None** |
| **GFX Ring Pressure** | **ZERO** |
| **AccelMethod "none" Compat** | Perfect |
| **No-Compositing Mode** | Default -- no built-in compositor |
| **RAM Usage** | ~100-150 MB idle |
| **CPU Usage** | <1% idle |
| **Known Raphael Issues** | One Arch forum report of high GPU usage when moving windows with a game running -- but this was with glamor accel ON, not "none" |
| **Risk Level** | **SAFE** |

**Notes:** Traditional stacking (floating) window manager. Familiar desktop with right-click menu, window decorations, minimize/maximize/close. Works well with `tint2` panel for taskbar. Can pair with Thunar (XFCE file manager) or PCManFM for file management. This is what LXQt/LXDE use under the hood.

**Advantage over tiling WMs:** Familiar desktop paradigm with drag-resize windows. Lower learning curve than i3/bspwm/dwm while still having zero GPU ring pressure.

---

#### 4. bspwm (Binary Space Partitioning WM)

| Property | Value |
|----------|-------|
| **Ubuntu 24.04 Package** | `bspwm` 0.9.10-2 |
| **Install** | `sudo apt install bspwm sxhkd lightdm lightdm-gtk-greeter` |
| **GL Backend** | **None** |
| **GFX Ring Pressure** | **ZERO** |
| **AccelMethod "none" Compat** | Perfect |
| **No-Compositing Mode** | Default -- no built-in compositor |
| **RAM Usage** | ~80-150 MB idle |
| **CPU Usage** | <1% idle |
| **Known Raphael Issues** | None reported |
| **Risk Level** | **SAFE** |

**Notes:** Requires `sxhkd` for keybindings (separate hotkey daemon). Even more minimal than i3. Configuration via `bspwmrc` shell script.

---

#### 5. dwm (Dynamic Window Manager)

| Property | Value |
|----------|-------|
| **Ubuntu 24.04 Package** | `dwm` 6.4-1 (via `suckless-tools`) |
| **Install** | `sudo apt install dwm suckless-tools st lightdm lightdm-gtk-greeter` |
| **GL Backend** | **None** |
| **GFX Ring Pressure** | **ZERO** |
| **AccelMethod "none" Compat** | Perfect |
| **No-Compositing Mode** | Default -- no compositor |
| **RAM Usage** | ~50-100 MB idle |
| **CPU Usage** | <0.5% idle |
| **Known Raphael Issues** | None reported |
| **Risk Level** | **SAFE** |

**Notes:** Minimalist C program under 2000 SLOC. The lightest option by memory and CPU. No runtime configuration -- all config is compile-time via `config.h`. The Ubuntu packaged version cannot be customized without recompiling from source.

---

#### 6. Fluxbox

| Property | Value |
|----------|-------|
| **Ubuntu 24.04 Package** | `fluxbox` 1.3.7-1 |
| **Install** | `sudo apt install fluxbox lightdm lightdm-gtk-greeter` |
| **GL Backend** | **None** |
| **GFX Ring Pressure** | **ZERO** |
| **AccelMethod "none" Compat** | Perfect |
| **No-Compositing Mode** | Default -- no built-in compositor |
| **RAM Usage** | ~80-130 MB idle |
| **CPU Usage** | <1% idle |
| **Known Raphael Issues** | None reported |
| **Risk Level** | **SAFE** |

**Notes:** Lightweight stacking WM with built-in toolbar, tabbed windows, slit (dock), key chains, and per-window settings. More features than Openbox out of the box. Configuration via `~/.fluxbox/` text files. Mature and stable (1.3.7 since 2015, but considered complete).

---

#### 7. IceWM

| Property | Value |
|----------|-------|
| **Ubuntu 24.04 Package** | `icewm` 3.4.5-1build2 |
| **Install** | `sudo apt install icewm lightdm lightdm-gtk-greeter` |
| **GL Backend** | **None** |
| **GFX Ring Pressure** | **ZERO** |
| **AccelMethod "none" Compat** | Perfect |
| **No-Compositing Mode** | Default -- no built-in compositor |
| **RAM Usage** | ~100-150 MB idle |
| **CPU Usage** | <1% idle |
| **Known Raphael Issues** | None reported |
| **Risk Level** | **SAFE** |

**Notes:** Windows 95-style interface with built-in taskbar, start menu, and system tray. Extremely fast. Supports themes. Good choice for users who want a familiar Windows-like desktop without any GPU compositing.

---

#### 8. herbstluftwm

| Property | Value |
|----------|-------|
| **Ubuntu 24.04 Package** | `herbstluftwm` 0.9.5-3 |
| **Install** | `sudo apt install herbstluftwm lightdm lightdm-gtk-greeter` |
| **GL Backend** | **None** |
| **GFX Ring Pressure** | **ZERO** |
| **AccelMethod "none" Compat** | Perfect |
| **No-Compositing Mode** | Default -- no built-in compositor |
| **RAM Usage** | ~80-120 MB idle |
| **CPU Usage** | <1% idle |
| **Known Raphael Issues** | None reported |
| **Risk Level** | **SAFE** |

**Notes:** Manual tiling WM using frame-based layout. All configuration at runtime via `herbstclient` IPC tool. More dynamic than i3's tree-based approach.

---

#### 9. awesome wm

| Property | Value |
|----------|-------|
| **Ubuntu 24.04 Package** | `awesome` (universe) |
| **Install** | `sudo apt install awesome lightdm lightdm-gtk-greeter` |
| **GL Backend** | **None** -- uses Cairo/XCB for rendering, no OpenGL |
| **GFX Ring Pressure** | **ZERO** |
| **AccelMethod "none" Compat** | Perfect |
| **No-Compositing Mode** | Default -- no built-in compositor |
| **RAM Usage** | ~150-250 MB idle |
| **CPU Usage** | <1% idle |
| **Known Raphael Issues** | None reported |
| **Risk Level** | **SAFE** |

**Notes:** Highly extensible tiling WM configured in Lua. Built-in widgets, notifications, and system tray. Most "batteries-included" tiling WM without any GL dependency. Can create complex status bars and desktop widgets purely in Lua. X11 only.

---

### TIER 2: VERY LOW GFX RING PRESSURE (Safe with AccelMethod "none")

These options have built-in compositors that use XRender (CPU-side) rather than OpenGL. With `AccelMethod "none"`, ring pressure is effectively zero. With `AccelMethod "glamor"`, ring pressure is very low because glamor translates XRender calls to GL internally.

---

#### 10. XFCE4 + xfwm4 (Compositing ON)

| Property | Value |
|----------|-------|
| **GL Backend** | XRender (CPU) for compositing. Optional GLX for vblank sync only. |
| **GFX Ring Pressure** | **ZERO** with AccelMethod "none" / **VERY LOW** with AccelMethod "glamor" |
| **AccelMethod "none" Compat** | Excellent |
| **Risk Level** | **SAFE** with AccelMethod "none"; **LOW** with glamor |

**Notes:** Compositing ON provides transparency, shadows, and vsync. The XRender backend means all compositing math is CPU-side. The only GL interaction is vblank synchronization (timing only, no draw calls). With `AccelMethod "none"`, this is fully CPU-rendered.

**Caveat:** XRender compositing is CPU-intensive on high-resolution displays (4K). On a 7950X this is negligible (~3-5% CPU for compositing effects).

---

#### 11. MATE Desktop + Marco (No Compositor or XRender Compositor)

| Property | Value |
|----------|-------|
| **Ubuntu 24.04 Package** | `ubuntu-mate-desktop` or `mate-desktop-environment` |
| **Install** | `sudo apt install ubuntu-mate-desktop lightdm` |
| **GL Backend** | **XRender only** for Marco's built-in compositor. No OpenGL rendering path. |
| **GFX Ring Pressure** | **ZERO** (no compositor) / **ZERO** (XRender compositor with AccelMethod "none") / **VERY LOW** (XRender with glamor) |
| **AccelMethod "none" Compat** | Excellent |
| **No-Compositing Mode** | Yes: MATE Tweak > Windows > "Marco (No compositor)" |
| **RAM Usage** | ~400-500 MB idle |
| **CPU Usage** | ~2-3% idle |
| **Known Raphael Issues** | [Launchpad Bug #1876480](https://bugs.launchpad.net/bugs/1876480) -- Ubuntu MATE 20.04 display issues with AMDGPU, resolved in later versions |
| **Risk Level** | **SAFE** (no compositor) / **SAFE** (XRender + AccelMethod "none") |

**Technical detail:** Marco is the MATE window manager (fork of GNOME 2's Metacity). Its built-in compositor uses **only XRender** -- there is no OpenGL compositor backend. The source code (`compositor-xrender.c`) confirms this. The compositor is GPU-independent.

**MATE Tweak compositor options:**
- "Marco (No compositor)" -- zero compositing, zero ring pressure
- "Marco (Adaptive compositor)" -- XRender compositing, disables for fullscreen apps
- "Marco (Xpresent compositor)" -- XRender with Xpresent vsync (better tear-free)
- External compositors: picom (XRender or GLX backend selectable)

**Advantage:** Full traditional desktop experience (panels, system tray, file manager, control center) with zero GL dependency. Best usability-to-safety ratio for users who need a full DE besides XFCE.

---

#### 12. LXDE

| Property | Value |
|----------|-------|
| **Ubuntu 24.04 Package** | `lxde` |
| **Install** | `sudo apt install lxde lightdm` |
| **GL Backend** | **None** -- uses Openbox as WM (no built-in compositor) |
| **GFX Ring Pressure** | **ZERO** |
| **AccelMethod "none" Compat** | Perfect |
| **No-Compositing Mode** | Default -- Openbox has no compositor |
| **RAM Usage** | ~200-300 MB idle |
| **CPU Usage** | <2% idle |
| **Known Raphael Issues** | None reported |
| **Risk Level** | **SAFE** |

**Notes:** Full desktop environment built around Openbox. GTK2-based, considered legacy (LXQt is its successor). For maximum stability and minimum GPU usage, LXDE's simplicity is an advantage. Panel, file manager (PCManFM), session manager included.

---

#### 13. LXQt

| Property | Value |
|----------|-------|
| **Ubuntu 24.04 Package** | `lxqt` (minimal) or `task-lxqt-desktop` (full Lubuntu) |
| **Install** | `sudo apt install lxqt lightdm lightdm-gtk-greeter` |
| **GL Backend** | **None** -- uses Openbox as default WM |
| **GFX Ring Pressure** | **ZERO** (default, no compositor) |
| **AccelMethod "none" Compat** | Perfect |
| **No-Compositing Mode** | Default -- Openbox has no compositor |
| **RAM Usage** | ~220-350 MB idle |
| **CPU Usage** | <2% idle |
| **Known Raphael Issues** | None reported |
| **Risk Level** | **SAFE** |

**Notes:** LXDE's successor using Qt5 instead of GTK2. Ships with Openbox (no compositor) by default. Qt5 toolkit renders via CPU (QPainter) for 2D widgets. Desktop panel, file manager (PCManFM-Qt), and settings use zero GL. Lubuntu 24.04 ships LXQt 1.4.0. Actively maintained, better HiDPI support than LXDE.

---

#### 14. Any WM + picom (XRender backend)

| Property | Value |
|----------|-------|
| **Ubuntu 24.04 Package** | Any Tier 1 WM + `picom` |
| **Install** | `sudo apt install picom` (add to any WM) |
| **GL Backend** | **Configurable**: xrender (CPU) or glx (OpenGL 3.3) |
| **GFX Ring Pressure** | **ZERO** (xrender + AccelMethod "none") / **LOW** (glx) |
| **AccelMethod "none" Compat** | Excellent with xrender backend |
| **Risk Level** | **SAFE** (xrender + AccelMethod "none") / **LOW** (glx) |

**picom backend comparison:**

| Backend | Rendering | GFX Ring | RAM | CPU | VSync Quality |
|---------|-----------|----------|-----|-----|---------------|
| **xrender** | CPU via XRender | Zero (with AccelMethod "none") | ~7-8 MB | Higher (1-3%) | Worse (XRender cannot sync natively) |
| **glx** | GPU via OpenGL 3.3 | Low-Medium | ~35 MB (grows over time) | Lower | Better (GL vsync) |

**picom configuration for safety:**
```bash
# ~/.config/picom/picom.conf
backend = "xrender";    # CPU-only rendering, zero GFX ring
vsync = false;          # Disable vsync (avoids GL timing)
shadow = false;         # Disable shadows (reduces CPU load)
fading = false;         # Disable fading (reduces CPU load)
```

**Known issues:** [picom #1164](https://github.com/yshui/picom/issues/1164) -- performance degradation after suspend with kernel 6.7 (GLX backend only, XRender unaffected). [picom #853](https://github.com/yshui/picom/issues/853) -- GLX backend significantly heavier than XRender.

---

### TIER 3: MEDIUM-HIGH GFX RING PRESSURE (Risk of Crash Loop)

These compositors use OpenGL as their primary rendering backend. While some can be configured to reduce or eliminate GL usage, their default configurations generate moderate to high ring pressure.

---

#### 15. KDE Plasma 5.27 on X11 (KWin)

| Property | Value |
|----------|-------|
| **Ubuntu 24.04 Package** | `kde-plasma-desktop` (or `kubuntu-desktop`) |
| **Install** | `sudo apt install kde-plasma-desktop sddm` |
| **GL Backend** | **OpenGL** (mandatory since Plasma 5.23 -- XRender backend was removed via [KWin MR !1088](https://invent.kde.org/plasma/kwin/-/merge_requests/1088)) |
| **GFX Ring Pressure** | **MEDIUM-HIGH** (compositing ON) / **ZERO** (compositing OFF) |
| **AccelMethod "none" Compat** | **Problematic** -- KWin's compositing requires GL. With AccelMethod "none", compositing may fail. |
| **No-Compositing Mode** | Yes: `KWIN_COMPOSE=N` (env var) or Alt+Shift+F12 (runtime toggle) or System Settings > Display > Compositor > uncheck "Enable compositor on startup" |
| **RAM Usage** | ~500-700 MB idle |
| **CPU Usage** | ~3-5% idle |
| **Known Raphael Issues** | [KDE Bug #512967](https://www.mail-archive.com/kde-bugs-dist@kde.org/msg1118485.html) -- AMDGPU ring gfx timeout / GPU hang on Ryzen 9950X3D iGPU with KWin (Wayland). Marked RESOLVED UPSTREAM. [KDE Bug #446779](https://bugs.kde.org/show_bug.cgi?id=446779) -- Random OpenGL freeze causes KWin to disable compositing. |
| **Risk Level** | **HIGH** (compositing ON) / **SAFE** (compositing OFF with KWIN_COMPOSE=N) |

**Critical detail:** KDE Plasma 5.23+ **removed the XRender compositor backend**. The reasoning (from KWin MR !1088): OpenGL drivers had become stable enough, XRender was effectively unmaintained, and QtQuick does not support XRender API. This means KWin can only composite via OpenGL or not at all. There is no low-GPU-pressure compositing option.

**KWIN_COMPOSE environment variable values:**
- `N` -- Disable compositing entirely (X11 only) -- **SAFE for DCN stall**
- `O2` -- OpenGL 2 backend -- HIGH ring pressure
- `O2ES` -- OpenGL ES 2 backend
- `X` -- XRender backend -- **REMOVED in Plasma 5.23, will not work**
- `Q` -- QPainter backend (Wayland only)

**If using KDE Plasma, the ONLY safe configuration is:**
```bash
# /etc/environment.d/90-kwin-no-compositing.conf
KWIN_COMPOSE=N
```
This disables all compositing, making KWin a basic stacking WM with zero ring pressure. But this eliminates all desktop effects -- at which point XFCE or MATE provides a better experience with less overhead.

**Display Manager:** KDE uses SDDM, which renders its login screen via QML/Qt Quick. QML may use OpenGL for rendering. Consider LightDM instead.

---

#### 16. Cinnamon (Muffin compositor)

| Property | Value |
|----------|-------|
| **Ubuntu 24.04 Package** | `cinnamon-desktop-environment` |
| **Install** | `sudo apt install cinnamon-desktop-environment lightdm` |
| **GL Backend** | **OpenGL** via Cogl/Clutter (Mutter 3.36 fork). **Cannot be fully disabled.** |
| **GFX Ring Pressure** | **HIGH** |
| **AccelMethod "none" Compat** | **Poor** -- Cinnamon requires GL for its compositor. Falls back to "software rendering mode" which uses llvmpipe (Mesa software GL), not a true no-GL mode. |
| **No-Compositing Mode** | **NO** -- Compositing cannot be fully disabled in Cinnamon/Muffin. You can disable effects via System Settings > Effects, but the compositor itself remains active. See [GitHub Discussion #169](https://github.com/orgs/linuxmint/discussions/169). |
| **RAM Usage** | ~500-600 MB idle |
| **CPU Usage** | ~3-5% idle |
| **Known Raphael Issues** | Same class as GNOME (Muffin is a Mutter fork, uses same Cogl/Clutter OpenGL pipeline) |
| **Risk Level** | **HIGH** -- Cannot disable compositing, always generates GL ring pressure |

**Technical detail:** Muffin was forked from Mutter 3.2 and rebased on Mutter 3.36 in Cinnamon 5.4. It uses Cogl (a GL abstraction layer, source: `cogl/cogl/driver/gl/cogl-pipeline-opengl.c`) and Clutter (GL-based scene graph) for all rendering. Even with all visual effects disabled, the compositor still runs and submits GL commands for window composition.

**Software rendering fallback:** When Cinnamon detects no hardware GL, it falls back to llvmpipe (Mesa's software OpenGL renderer). This still generates command structures that interact with the driver path -- it is NOT equivalent to zero ring pressure.

**Verdict:** Do not use Cinnamon for the DCN stall scenario.

---

### TIER 4: CRITICAL GFX RING PRESSURE (Confirmed Crash Trigger)

---

#### 17. GNOME (Mutter) -- Current Crash Trigger, For Reference

| Property | Value |
|----------|-------|
| **GL Backend** | **OpenGL** via Cogl/Clutter. Mandatory. Cannot be disabled. |
| **GFX Ring Pressure** | **CRITICAL** -- continuous GL command stream for all window composition |
| **AccelMethod "none" Compat** | **Not viable** -- gnome-shell requires GL |
| **No-Compositing Mode** | **NO** |
| **Risk Level** | **CRITICAL** -- This is the confirmed crash trigger |

**Additional issue:** Mutter 46.x (Ubuntu 24.04 stock) creates a real-time priority KMS page-flip thread. When amdgpu takes too long on a page flip (DCN latency), the thread exceeds its RT scheduling deadline and gets SIGKILL'd by the kernel, crashing GDM independently of the ring timeout.

**Workaround (insufficient alone):** `MUTTER_DEBUG_KMS_THREAD_TYPE=user` reduces the KMS thread issue but does not address the fundamental GL ring pressure.

---

## Summary Matrix

### All Options Ranked by Safety

| Rank | Option | GFX Ring Pressure | Full DE? | Compositing Avoidable? | Risk Level |
|------|--------|-------------------|----------|----------------------|------------|
| 1 | **XFCE4 (compositing OFF)** | ZERO | Yes | Yes (toggle) | **SAFE** |
| 2 | **MATE (Marco, no compositor)** | ZERO | Yes | Yes (toggle) | **SAFE** |
| 3 | **LXQt** (Openbox) | ZERO | Yes | Default off | **SAFE** |
| 4 | **LXDE** (Openbox) | ZERO | Yes | Default off | **SAFE** |
| 5 | **Openbox + tint2** | ZERO | Partial | Default off | **SAFE** |
| 6 | **IceWM** | ZERO | Partial | Default off | **SAFE** |
| 7 | **Fluxbox** | ZERO | Partial | Default off | **SAFE** |
| 8 | **i3wm** | ZERO | No | Default off | **SAFE** |
| 9 | **awesome** | ZERO | No | Default off | **SAFE** |
| 10 | **bspwm** | ZERO | No | Default off | **SAFE** |
| 11 | **dwm** | ZERO | No | Default off | **SAFE** |
| 12 | **herbstluftwm** | ZERO | No | Default off | **SAFE** |
| 13 | **XFCE4 (compositing ON)** | VERY LOW | Yes | Yes | **LOW** |
| 14 | **MATE (Marco adaptive)** | VERY LOW | Yes | Yes | **LOW** |
| 15 | **Any WM + picom (xrender)** | VERY LOW | Varies | Optional | **LOW** |
| 16 | **Any WM + picom (glx)** | LOW-MEDIUM | Varies | Optional | **MEDIUM** |
| 17 | **KDE Plasma (KWIN_COMPOSE=N)** | ZERO | Yes | Yes (env var) | **SAFE** |
| 18 | **KDE Plasma (compositing ON)** | MEDIUM-HIGH | Yes | OpenGL only | **HIGH** |
| 19 | **Cinnamon** | HIGH | Yes | **Cannot disable** | **HIGH** |
| 20 | **GNOME** | CRITICAL | Yes | **Cannot disable** | **CRITICAL** |

---

## Display Manager Considerations

| Display Manager | GL Usage | GFX Ring Pressure | Recommendation |
|----------------|----------|-------------------|----------------|
| **GDM3** (GNOME default) | gnome-shell greeter uses OpenGL | **HIGH** | **AVOID** -- spawns gnome-shell which triggers crash |
| **LightDM + gtk-greeter** | GTK rendering, no GL | **ZERO** | **RECOMMENDED** |
| **LightDM + slick-greeter** | GTK rendering, no GL | **ZERO** | Good alternative |
| **SDDM** (KDE default) | QML may use OpenGL | **LOW-MEDIUM** | Acceptable if KDE is used |
| **Console autologin** | None | **ZERO** | For headless/TTY setups |

**Critical:** If using XFCE/MATE/LXQt/i3/any safe compositor, replace GDM3 with LightDM:
```bash
sudo apt install lightdm lightdm-gtk-greeter
sudo dpkg-reconfigure lightdm
# Select lightdm as default display manager
```

---

## Recommendations

### Primary: XFCE4 + LightDM + AccelMethod "none"

The **confirmed working** configuration. Provides:
- Full desktop environment with panels, file manager, settings GUI
- Zero GFX ring pressure
- Zero risk of crash loop
- Compositing can be re-enabled (XRender, still safe) after firmware fix

**Xorg configuration:**
```
Section "Device"
    Identifier     "Device-amd"
    Driver         "amdgpu"
    BusID          "PCI:X:Y:Z"
    Option         "AccelMethod" "none"
    Option         "TearFree" "true"
    Option         "DRI" "3"
EndSection
```

### Secondary: MATE + LightDM + AccelMethod "none"

For users who prefer a GNOME 2-style desktop:
- Marco with "No compositor" mode -- identical safety profile to XFCE
- Built-in XRender compositor available when desired (still safe with AccelMethod "none")
- Complete DE: panels, system tray, Caja file manager, Pluma editor

### Tertiary: LXQt + LightDM + AccelMethod "none"

Lightest full DE option:
- Openbox WM (zero compositor overhead)
- Qt5-based panels and applications
- ~220 MB RAM idle

### For Power Users: i3wm + LightDM + AccelMethod "none"

Absolute minimum attack surface:
- Zero GUI overhead beyond window tiling
- Keyboard-driven workflow ideal for ML workstation (terminal-heavy)
- Add picom with xrender backend later if compositing effects are needed

---

## Post-Firmware-Fix Migration Path

After updating DMCUB firmware to >= 0.0.224.0 and confirming 10+ clean boots with zero optc31 timeouts:

1. **Phase 1:** Switch `AccelMethod` from `"none"` to `"glamor"` -- re-enables GPU 2D acceleration
2. **Phase 2:** Enable xfwm4 compositing (XRender) -- adds transparency/shadows with minimal ring pressure
3. **Phase 3:** (Optional) Test GNOME/KDE with compositing if desired -- only after confirmed firmware stability
4. **Phase 4:** (Optional) Switch display manager from LightDM to GDM3 if GNOME is adopted

At each phase, verify with:
```bash
dmesg | grep -i "REG_WAIT timeout\|ring.*timeout\|GPU reset"
# Should show ZERO results
```

---

## Sources

- [amdgpu(4) man page -- Arch manual pages](https://man.archlinux.org/man/extra/xf86-video-amdgpu/amdgpu.4.en)
- [freedesktop Bug #94220 -- AccelMethod "none" breaks DRI2/VDPAU](https://bugs.freedesktop.org/show_bug.cgi?id=94220)
- [Glamor -- freedesktop.org](https://www.freedesktop.org/wiki/Software/Glamor/)
- [xfwm4 COMPOSITOR documentation](https://github.com/xfce-mirror/xfwm4/blob/master/COMPOSITOR)
- [KWin MR !1088 -- Remove XRender backend](https://invent.kde.org/plasma/kwin/-/merge_requests/1088)
- [KWin Environment Variables -- KDE Community Wiki](https://community.kde.org/KWin/Environment_Variables)
- [KDE Bug #512967 -- AMDGPU ring timeout on Ryzen iGPU with KWin](https://www.mail-archive.com/kde-bugs-dist@kde.org/msg1118485.html)
- [KDE Bug #446779 -- Random OpenGL freeze causes KWin to disable compositing](https://bugs.kde.org/show_bug.cgi?id=446779)
- [Picom backends wiki](https://github.com/yshui/picom/wiki/Backends)
- [Picom issue #620 -- xrender vs glx performance](https://github.com/yshui/picom/issues/620)
- [Picom issue #853 -- GLX backend heavier than XRender](https://github.com/yshui/picom/issues/853)
- [Picom issue #1164 -- Performance degradation after suspend](https://github.com/yshui/picom/issues/1164)
- [Marco compositor-xrender.c source](https://github.com/mate-desktop/marco/blob/master/src/compositor/compositor-xrender.c)
- [Muffin Cogl OpenGL pipeline source](https://github.com/linuxmint/muffin/blob/master/cogl/cogl/driver/gl/cogl-pipeline-opengl.c)
- [Cinnamon cannot disable compositing -- GitHub Discussion #169](https://github.com/orgs/linuxmint/discussions/169)
- [AMDGPU DDX vs modesetting -- Phoronix](https://www.phoronix.com/news/AMDGPU-DDX-Modesetting)
- [Ring Buffer kernel documentation](https://docs.kernel.org/gpu/amdgpu/ring-buffer.html)
- [AMDGPU -- ArchWiki](https://wiki.archlinux.org/title/AMDGPU)
- [Arch forum -- XFCE + amdgpu window manager freezes](https://bbs.archlinux.org/viewtopic.php?id=309626)
- [Arch forum -- amdgpu ring gfx timeout soft recovered](https://bbs.archlinux.org/viewtopic.php?id=288107)
- [NixOS + AMD Raphael iGPU fix guide](https://blabli.blog/post/2023/03/14/nixos-amd-raphael-igpu-screen-issues/)
- [Level1Techs -- 7950x iGPU unstable](https://forum.level1techs.com/t/7950xs-igpu-is-unstable-blackouts-freezes-both-on-linux-and-windows/224035)
- [Launchpad Bug #1876480 -- Ubuntu MATE AMDGPU display issues](https://bugs.launchpad.net/bugs/1876480)
- [LXQt wiki -- Window managers (X11)](https://github.com/lxqt/lxqt/wiki/Window-managers-(X11))
- [Arch forum -- Openbox high GPU usage](https://bbs.archlinux.org/viewtopic.php?id=276306)
- [Ubuntu 24.04 desktop environments](https://www.server-world.info/en/note?os=Ubuntu_24.04&p=desktop)
- [Cinnamon High CPU usage caused by Muffin -- GitHub #13177](https://github.com/linuxmint/cinnamon/issues/13177)
