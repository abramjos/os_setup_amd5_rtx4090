# Wayland Compositor Research: Raphael iGPU DCN 3.1.5 Crash Loop Mitigation

**Hardware:** AMD Ryzen 9 7950X (Raphael) | RDNA2 iGPU GC 10.3.6, DCN 3.1.5, 2 CUs | RTX 4090 (headless)
**Date:** 2026-03-29
**Purpose:** Evaluate every viable Wayland compositor for Ubuntu 24.04, ranked by ability to survive the DCN pipeline stall crash loop.

---

## The Core Problem: Why Compositor Choice Matters

The crash loop requires **two simultaneous conditions**:

1. **DCN pipeline stall** -- `optc31_disable_crtc` REG_WAIT timeout during EFI-to-amdgpu handoff (caused by outdated DMCUB firmware 0.0.15.0)
2. **GFX ring submissions from compositor** -- compositor sends OpenGL/GLES draw commands to `gfx_0.0.0` ring, which hangs because DCN is stalled, triggering MODE2 reset (GFX/SDMA only, NOT DCN), creating an infinite loop

**Remove either condition and the crash loop breaks.** The firmware fix addresses condition 1. This document addresses condition 2: minimizing or eliminating GFX ring pressure from the compositor.

### AMD GPU Ring Architecture (Relevant to This Problem)

| Ring | Engine | What Uses It | Crash Impact |
|------|--------|-------------|--------------|
| `gfx_0.0.0` | GFX (Graphics Compute) | OpenGL, GLES, Vulkan graphics queue | **THIS IS THE CRASH TRIGGER** |
| `comp_1.x.x` | Compute | Vulkan compute queue, OpenCL, ROCm | Independent of GFX -- does NOT trigger crash |
| `sdma0`, `sdma1` | SDMA | DMA transfers, buffer copies | Reset by MODE2 but not the trigger |

**Key insight:** OpenGL and GLES compositors submit ALL work to the `gfx_0.0.0` ring. Vulkan can optionally use the compute queue (`comp_1.x.x`) which is independent. The pixman software renderer uses ZERO GPU rings -- all rendering happens on the CPU. The rendered framebuffer is sent to the display controller via DRM dumb buffers and KMS page-flips, bypassing the GFX engine entirely.

### KMS Page-Flip vs GFX Ring: The Critical Distinction

ALL Wayland compositors must perform KMS page-flips to display content (this is the `drmModeAtomicCommit` ioctl). This interacts with DCN directly via the display controller hardware path, NOT through the GFX ring. A KMS page-flip with a pre-rendered buffer does NOT submit GFX ring commands.

The danger is the **rendering** step, not the **display** step:
- GPU-rendered compositing: CPU -> GFX ring command -> GPU renders to buffer -> KMS page-flip
- Software-rendered compositing: CPU renders to buffer -> DRM dumb buffer -> KMS page-flip (GFX ring never touched)

---

## Ubuntu 24.04 Package Availability Summary

| Compositor | Ubuntu 24.04 Package | Version | wlroots Version | Install Method |
|-----------|---------------------|---------|-----------------|----------------|
| **GNOME (Mutter)** | `mutter` | 46.x | N/A (own stack) | Default install |
| **KDE Plasma (KWin)** | `plasma-desktop` | 5.27.11 | N/A (own stack) | `sudo apt install kde-plasma-desktop` |
| **Sway** | `sway` | 1.8.1 / 1.9 | 0.16.2 / 0.17.1 | `sudo apt install sway` |
| **labwc** | `labwc` | 0.7.1 | 0.17.x | `sudo apt install labwc` |
| **Weston** | `weston` | 12.0.1 / 13.0 | N/A (own stack) | `sudo apt install weston` |
| **Wayfire** | `wayfire` | 0.8.0 | 0.17.x | `sudo apt install wayfire` |
| **Cage** | `cage` | Check repo | 0.17.x | `sudo apt install cage` |
| **Hyprland** | Not in repos | N/A | N/A | PPA: `ppa:cppiber/hyprland` |
| **niri** | Not in repos | N/A | N/A | Build from source (Rust/cargo) |
| **river** | Not in repos | N/A | N/A | Build from source (Zig) |
| **dwl** | Not in repos | N/A | N/A | Build from source (C) |
| **gamescope** | Not available | N/A | N/A | Build from source (dep conflicts) |
| **COSMIC** | Not in repos | N/A | N/A | PPA (replaces Mesa/Wayland -- risky) |
| **Mir/Miriway** | `mir-*` libs | 2.x | N/A (own stack) | `sudo apt install miriway` |

---

## Detailed Compositor Analysis

### 1. GNOME on Wayland (Mutter) -- THE CURRENT CRASH TRIGGER

**Version on Ubuntu 24.04:** Mutter 46.x (GNOME 46)
**GPU Rendering Backend:** OpenGL (Cogl/Clutter), no software fallback on Wayland
**GFX Ring Pressure:** **HIGH -- CONTINUOUS**
**Software Rendering Fallback:** `LIBGL_ALWAYS_SOFTWARE=1` forces llvmpipe but gnome-shell becomes extremely slow and may still interact with the GFX ring through EGL context creation
**KMS/DRM Method:** Atomic modesetting, per-monitor frame clocks
**DMABUF Scanout:** Yes (direct scanout for fullscreen, but gnome-shell itself always composites)
**Resource Usage:** HIGH (300-500MB RAM, 5-15% CPU, continuous GPU)

**Rendering Architecture:**
Mutter uses Cogl (a Clutter-internal OpenGL abstraction) for ALL rendering. On Wayland, it creates an EGL context on the DRM device and submits OpenGL draw calls every frame for every monitor. The frame clock drives rendering at the monitor's refresh rate (e.g., 60Hz = 60 GFX ring submissions per second minimum, even when idle with cursor blinking).

gnome-shell is a Clutter actor that renders its entire UI (panel, overview, notifications, window decorations) through the same OpenGL pipeline. Every visual update -- cursor blink, clock tick, notification -- triggers a full recomposite through the GFX ring.

**Mutter-Specific SIGKILL Bug:** Mutter 46.x creates a real-time priority KMS page-flip thread. When amdgpu takes too long on a page flip (DCN latency), the thread exceeds its RT scheduling deadline and gets SIGKILL'd by the kernel. This crashes GDM/gnome-shell independently of ring timeouts.

**Workaround:** `MUTTER_DEBUG_KMS_THREAD_TYPE=user` (normal priority instead of RT)

**Known Issues with Raphael/RDNA2:**
- gnome-shell is the process named in EVERY ring timeout in the 20-boot diagnostic
- No way to disable compositing on Wayland (unlike X11)
- No pixman/software fallback for the compositor itself
- `MUTTER_DEBUG_DISABLE_HW_CURSORS=1` reduces one source of GFX ring traffic

**Risk Assessment: HIGHEST -- This is the compositor that crashes. Do not use until firmware is fixed.**

**Can GFX ring usage be minimized?** No. Mutter on Wayland has no software rendering path for the compositor. `LIBGL_ALWAYS_SOFTWARE=1` makes client apps use llvmpipe but Mutter itself still creates an EGL/GL context on the hardware device.

---

### 2. KDE Plasma 6 on Wayland (KWin)

**Version on Ubuntu 24.04:** KWin 5.27.11 (Plasma 5.27, not Plasma 6). Plasma 6 available via Kubuntu Backports PPA.
**GPU Rendering Backend:** OpenGL ES 2.0 via EGL
**GFX Ring Pressure:** **MEDIUM -- DAMAGE-DRIVEN** (renders only when content changes, but still uses GL)
**Software Rendering Fallback:** `KWIN_COMPOSE=Q` (QPainter backend -- CPU-rendered, Wayland only)
**KMS/DRM Method:** Atomic modesetting
**DMABUF Scanout:** Yes (direct scanout for fullscreen clients)
**Resource Usage:** MEDIUM (200-400MB RAM, 1-5% CPU with GPU, higher with QPainter)

**Rendering Architecture:**
KWin uses OpenGL ES via EGL for compositing. Unlike Mutter, KWin has more sophisticated damage tracking -- it only recomposites regions that have changed. When the desktop is idle (no cursor movement, no animations), KWin can skip frames entirely, resulting in near-zero GFX ring submissions during idle periods.

**Software Rendering Options:**
- `KWIN_COMPOSE=Q` -- QPainter backend: CPU-based rendering using Qt's raster paint engine. This is a legitimate software rendering mode that avoids the GFX ring entirely. However, reports indicate it is "garbage" visually and may not be production-usable.
- `KWIN_COMPOSE=N` -- Disable compositing: X11 only, NOT available on Wayland.
- KWin will automatically fall back to llvmpipe if no hardware GL is detected, but this still uses the GFX ring (llvmpipe submits GL commands to Mesa's software implementation, but EGL context creation still touches the DRM device).

**GPU Recovery:** KWin has built-in GPU reset recovery. When it detects `GL_CONTEXT_LOST`, it attempts to re-create the GL context. This is better than Mutter which simply crashes.

**Known Issues with Raphael/RDNA2:**
- KDE Bug [#453147](https://bugs.kde.org/show_bug.cgi?id=453147): "amdgpu: GPU reset crash loop" -- documented crash loop behavior
- KDE Bug [#475322](https://bugs.kde.org/show_bug.cgi?id=475322): GPU reset causes Xwayland to hang KWin
- KWin Wayland main thread hangs ~12s on AMD hybrid GPU systems (reported on ROG G14)
- On Raphael specifically: `amdgpu.sg_display=0` and `amdgpu.noretry=0` reported to help

**Risk Assessment: MEDIUM -- Better GPU recovery than Mutter, but still uses GFX ring for normal rendering. QPainter software fallback exists but is low quality.**

**Can GFX ring usage be minimized?**
- `KWIN_COMPOSE=Q` eliminates GFX ring usage entirely (QPainter is CPU-only)
- Disable desktop effects: Settings > Workspace Behavior > Desktop Effects > disable all
- `KWIN_FORCE_SW_CURSOR=1` avoids hardware cursor plane interaction
- Damage-driven rendering already reduces idle GFX ring submissions

**Install:**
```bash
sudo apt install kde-plasma-desktop
# For QPainter software rendering:
echo 'KWIN_COMPOSE=Q' | sudo tee /etc/environment.d/91-kwin-software.conf
```

---

### 3. Sway (wlroots-based, i3-compatible) -- RECOMMENDED

**Version on Ubuntu 24.04:** sway 1.8.1 (Release) / 1.9 (Proposed), wlroots 0.16.2 / 0.17.1
**GPU Rendering Backend:** OpenGL ES 2.0 via wlroots (default) OR **pixman software renderer**
**GFX Ring Pressure:** **ZERO with `WLR_RENDERER=pixman`**, LOW with default GLES2
**Software Rendering Fallback:** YES -- `WLR_RENDERER=pixman` (full software rendering, no GPU)
**KMS/DRM Method:** Atomic modesetting
**DMABUF Scanout:** Yes (zero-copy direct scanout for fullscreen, added in Sway 1.7)
**Resource Usage:** LOW (50-150MB RAM, 1-5% CPU with pixman, <1% CPU with GLES2)

**Rendering Architecture:**
Sway uses wlroots for rendering. wlroots supports three renderer backends:
1. **GLES2** (default): OpenGL ES 2.0 via EGL -- uses `gfx_0.0.0` ring
2. **Pixman** (software): CPU-based pixel manipulation -- **ZERO GFX ring usage**
3. **Vulkan** (experimental): Vulkan graphics pipeline -- uses `gfx_0.0.0` ring (graphics queue, NOT compute)

**The pixman renderer is the key to surviving the DCN stall.** With `WLR_RENDERER=pixman`:
- All compositing happens on the CPU using the pixman library (SSE-optimized)
- Rendered framebuffers are written to DRM dumb buffers
- DRM dumb buffers are scanned out via KMS page-flips
- The `gfx_0.0.0` ring is NEVER used
- Even if DCN is stalled, no GFX ring timeout can occur because nothing is submitted to the GFX ring

**Scene Graph and Damage Tracking:**
Sway 1.9+ uses the wlroots scene-graph API with built-in damage tracking. When nothing on screen changes, NO rendering occurs -- not even a page-flip. This means:
- Idle desktop: ZERO CPU usage, ZERO GPU usage, ZERO GFX ring submissions
- Active desktop: Only damaged regions are re-rendered, only affected outputs get new page-flips

**Critical Warning -- Pixman + DRM + amdgpu Compatibility:**
wlroots issue [#2916](https://github.com/swaywm/wlroots/issues/2916) documented that the DRM dumb buffer allocator did not work on amdgpu because amdgpu refused to import DRM dumb buffers via GBM. This was fixed by dropping GBM and using `drmPrimeFDToHandle` directly. The fix was merged via PR #3131.

**However:** Ubuntu 24.04 ships wlroots 0.16.2/0.17.1. The fix was in the 0.16.x development branch. The Ubuntu 24.04 wlroots version **should include this fix**, but must be verified on the actual hardware. A follow-up regression (fullscreen corruption on POLARIS10) was reported but may not affect Raphael.

**Sway 1.10 (NOT in Ubuntu repos):** Adds GPU reset recovery, scene-graph renderer rewrite, and improved robustness. Available via Ubuntu Sway Remix PPA or build from source with wlroots 0.18.

**Known Issues with Raphael/RDNA2:**
- With GLES2 renderer: same ring timeout risk as other GL compositors
- With pixman renderer: no known Raphael-specific issues (zero GPU involvement)
- Pixman renderer does not support screencasting via `xdg-desktop-portal-wlr` (screencast protocol requires DMABUF, which pixman cannot provide)

**Risk Assessment: LOWEST (with pixman) -- Zero GFX ring pressure eliminates crash trigger entirely.**

**Can GFX ring usage be minimized?**
- `WLR_RENDERER=pixman` -- ZERO GFX ring usage (RECOMMENDED)
- `WLR_RENDERER=gles2` with `WLR_RENDERER_ALLOW_SOFTWARE=1` -- forces llvmpipe (still uses EGL)
- Scene-graph damage tracking already minimizes rendering when idle

**Install:**
```bash
sudo apt install sway swaybg swayidle swaylock waybar foot
# Launch with pixman software rendering:
WLR_RENDERER=pixman sway
# Or set permanently:
mkdir -p ~/.config/environment.d
echo 'WLR_RENDERER=pixman' > ~/.config/environment.d/91-wlr-pixman.conf
# GDM integration for session selection:
# The sway package installs /usr/share/wayland-sessions/sway.desktop
```

---

### 4. Hyprland (formerly wlroots-based, now Aquamarine)

**Version on Ubuntu 24.04:** Not in repos. PPA: `ppa:cppiber/hyprland`
**GPU Rendering Backend:** OpenGL ES 3.2 via Aquamarine (custom backend, forked from wlroots)
**GFX Ring Pressure:** **HIGH -- CONTINUOUS** (animations, blur effects, rounded corners)
**Software Rendering Fallback:** NO -- Hyprland requires GPU acceleration, no pixman support
**KMS/DRM Method:** Atomic modesetting
**DMABUF Scanout:** Limited (animations prevent direct scanout in most cases)
**Resource Usage:** HIGH (200-400MB RAM, 5-15% CPU, heavy GPU)

**Rendering Architecture:**
Hyprland uses its own rendering backend (Aquamarine, forked from wlroots) with OpenGL ES 3.2. It does NOT support Vulkan rendering. The compositor uses extensive animations (window open/close, workspace transitions, blur, shadows) that generate continuous GFX ring submissions even on an "idle" desktop. Disabling animations reduces but does not eliminate GL submissions.

Hyprland does NOT support `WLR_RENDERER=pixman` because it forked away from upstream wlroots and uses its own Aquamarine backend which only supports OpenGL.

**Known Issues with Raphael/RDNA2:**
- [Hyprland #5271](https://github.com/hyprwm/Hyprland/issues/5271): Crashes on startup on AMDGPU
- AMD iGPU rendering fails when set as primary rendering backend, causing Hyprland to freeze
- Multi-GPU AMD+NVIDIA: renderer selection issues documented

**Risk Assessment: HIGH -- Continuous GL rendering, no software fallback, known AMD iGPU issues. NOT recommended for this hardware.**

**Install (if needed):**
```bash
sudo add-apt-repository ppa:cppiber/hyprland
sudo apt update
sudo apt install hyprland
```

---

### 5. river (wlroots-based, minimal)

**Version on Ubuntu 24.04:** Not in repos. Must build from source (requires Zig compiler).
**GPU Rendering Backend:** Inherits wlroots (GLES2 default, pixman available via `WLR_RENDERER=pixman`)
**GFX Ring Pressure:** **ZERO with pixman**, LOW with GLES2
**Software Rendering Fallback:** YES -- `WLR_RENDERER=pixman`
**KMS/DRM Method:** Atomic modesetting
**DMABUF Scanout:** Yes (via wlroots)
**Resource Usage:** VERY LOW (30-80MB RAM, minimal CPU)

**Rendering Architecture:**
River is a non-monolithic wlroots compositor. It uses wlroots' renderer infrastructure directly, supporting all three backends (GLES2, pixman, Vulkan). The minimal design means very little compositor-side rendering (no decorations, no animations, no effects).

**Known Issues:** Building from source on Ubuntu 24.04 is non-trivial -- requires Zig compiler and wlroots 0.18 (Ubuntu ships 0.17). Must compile wlroots from source as well.

**Risk Assessment: LOWEST (with pixman) -- Same as Sway but harder to install.**

**Install:**
```bash
# Requires building wlroots 0.18 and Zig from source
# Not practical for production -- use Sway or labwc instead
```

---

### 6. wayfire (wlroots-based, 3D effects)

**Version on Ubuntu 24.04:** wayfire 0.8.0
**GPU Rendering Backend:** OpenGL ES (default), Vulkan (experimental in 0.10+), Pixman (experimental in 0.10+)
**GFX Ring Pressure:** **HIGH -- CONTINUOUS** (3D effects, cube, wobbly windows)
**Software Rendering Fallback:** Only in 0.10+ (not in Ubuntu 24.04 repos). Ubuntu version 0.8.0 does NOT support pixman.
**KMS/DRM Method:** Atomic modesetting
**DMABUF Scanout:** Limited (effects prevent direct scanout)
**Resource Usage:** HIGH (200-400MB RAM, heavy GPU usage with effects)

**Rendering Architecture:**
Wayfire is Compiz for Wayland -- 3D desktop cube, wobbly windows, fire animations. All effects use GL shaders generating heavy GFX ring traffic. The Ubuntu 24.04 version (0.8.0) only supports GLES2. Wayfire 0.10 (not in repos) added experimental Vulkan and Pixman support via wlroots 0.18.

**Risk Assessment: HIGH -- 3D effects generate constant heavy GFX ring pressure. NOT recommended.**

**Install:**
```bash
sudo apt install wayfire
```

---

### 7. labwc (wlroots-based, Openbox-like) -- RECOMMENDED

**Version on Ubuntu 24.04:** labwc 0.7.1
**GPU Rendering Backend:** Inherits wlroots (GLES2 default, pixman via `WLR_RENDERER=pixman`)
**GFX Ring Pressure:** **ZERO with pixman**, VERY LOW with GLES2 (no effects, no animations)
**Software Rendering Fallback:** YES -- `WLR_RENDERER=pixman`
**KMS/DRM Method:** Atomic modesetting
**DMABUF Scanout:** Yes (via wlroots)
**Resource Usage:** VERY LOW (30-100MB RAM, minimal CPU)

**Rendering Architecture:**
labwc is a stacking window compositor (like Openbox) built on wlroots. It has NO animations, NO blur, NO 3D effects. It renders window decorations and the desktop background -- nothing else. With GLES2, this means very few GL draw calls (only on window move/resize/expose). With pixman, zero GL calls.

labwc is an excellent choice for this hardware because:
1. Stacking (not tiling) is familiar for users coming from GNOME/XFCE
2. Supports `WLR_RENDERER=pixman` for zero GFX ring usage
3. Extremely lightweight -- minimal compositor overhead
4. No fancy effects that would generate unnecessary GFX ring traffic
5. Available in Ubuntu 24.04 repos (no PPA needed)
6. Confirmed working with `WLR_RENDERER=pixman` in community reports

**Configuration:** Uses Openbox-compatible XML config (`~/.config/labwc/rc.xml`). Themes from the Openbox ecosystem work. Pairs well with a panel like `waybar` or `sfwbar`.

**Known Issues:**
- Pixman renderer does not support screencasting via `xdg-desktop-portal-wlr`
- Some visual limitations with pixman (no fractional scaling, no output rotation other than 90-degree multiples)

**Risk Assessment: LOWEST (with pixman) -- Minimal design + zero GFX ring = ideal for crash-prone hardware.**

**Install:**
```bash
sudo apt install labwc waybar
# Launch with pixman:
WLR_RENDERER=pixman labwc
# Permanent config:
mkdir -p ~/.config/labwc
cat > ~/.config/labwc/environment << 'EOF'
WLR_RENDERER=pixman
EOF
```

---

### 8. cage (wlroots kiosk)

**Version on Ubuntu 24.04:** Check `apt search cage`
**GPU Rendering Backend:** Inherits wlroots (GLES2 default, pixman via `WLR_RENDERER=pixman`)
**GFX Ring Pressure:** **ZERO with pixman**, VERY LOW with GLES2
**Software Rendering Fallback:** YES -- `WLR_RENDERER=pixman`
**KMS/DRM Method:** Atomic modesetting
**Resource Usage:** MINIMAL (single application, no chrome)

**Rendering Architecture:**
Cage is a kiosk compositor -- it displays a single maximized application and nothing else. No panel, no task switching, no decorations. The compositor itself does almost zero rendering. With pixman, the GFX ring is completely untouched.

**Use Case:** Run a single application (e.g., a terminal for SSH ML work, or a browser) in full-screen. Cage exits when the application exits.

**Risk Assessment: LOWEST (with pixman) -- Absolute minimum compositor footprint.**

**Install:**
```bash
sudo apt install cage
# Launch a terminal in kiosk mode with pixman:
WLR_RENDERER=pixman cage foot
```

---

### 9. Weston (reference compositor)

**Version on Ubuntu 24.04:** weston 12.0.1 (Release) / 13.0.0 (Proposed)
**GPU Rendering Backend:** OpenGL ES (default), Vulkan (13.0+), **Pixman** (`--renderer=pixman`)
**GFX Ring Pressure:** **ZERO with `--renderer=pixman`**, LOW with GL
**Software Rendering Fallback:** YES -- `weston --renderer=pixman` (native, well-tested)
**KMS/DRM Method:** Atomic modesetting
**DMABUF Scanout:** Yes (direct display extension for zero-copy bypass)
**Resource Usage:** LOW (50-150MB RAM)

**Rendering Architecture:**
Weston is the Wayland reference implementation. It has the OLDEST and MOST MATURE pixman renderer of any Wayland compositor -- pixman support was added to Weston's DRM backend years before wlroots. The DRM+pixman path in Weston is well-tested on real hardware including embedded ARM platforms without GPU acceleration.

By default, Weston will try EGL/GLES2 and fall back to pixman if EGL fails. Passing `--renderer=pixman` forces software rendering from the start.

**Limitations:**
- Weston is a reference compositor, not a full desktop environment
- Limited window management (floating windows, no tiling)
- No system tray, no task bar (must add external panels)
- Designed more for embedded/kiosk than desktop use

**Risk Assessment: VERY LOW (with pixman) -- Most mature software rendering path of any Wayland compositor.**

**Install:**
```bash
sudo apt install weston
# Launch with pixman on DRM/KMS:
weston --renderer=pixman
# Or in weston.ini:
# [core]
# renderer=pixman
```

---

### 10. niri (scrollable tiling, Smithay-based)

**Version on Ubuntu 24.04:** Not in repos. Must build from source with Rust/cargo.
**GPU Rendering Backend:** OpenGL ES via Smithay (default), **Pixman** via Smithay multi-renderer
**GFX Ring Pressure:** **ZERO with pixman mode**, LOW with GL
**Software Rendering Fallback:** YES -- Smithay supports pixman renderer (niri built with `renderer_pixman` feature)
**KMS/DRM Method:** Atomic modesetting via Smithay
**Resource Usage:** LOW-MEDIUM (Rust binary, 100-200MB RAM)

**Rendering Architecture:**
niri is built on Smithay (the Rust equivalent of wlroots). Smithay's multi-renderer system supports:
- `renderer_gl`: Hardware-accelerated OpenGL ES via EGL
- `renderer_pixman`: Software rendering via pixman (CPU-only)
- `renderer_multi`: Runtime selection between the two

niri includes damage tracking and animations (window open/close, workspace scrolling). With pixman renderer, all animation rendering is CPU-based.

**Known Issues:**
- Not available in any Ubuntu/Debian repository -- must compile from source
- Build requires Rust toolchain, many -dev packages
- Relatively new project, less battle-tested than Sway

**Risk Assessment: LOW (with pixman) -- Pixman support exists, but installation complexity is high.**

**Install:**
```bash
sudo apt install gcc clang libudev-dev libgbm-dev libxkbcommon-dev \
  libegl1-mesa-dev libwayland-dev libinput-dev libdbus-1-dev \
  libsystemd-dev libseat-dev libpipewire-0.3-dev libpango1.0-dev \
  libdisplay-info-dev
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
cargo install niri
```

---

### 11. dwl (dwm for Wayland)

**Version on Ubuntu 24.04:** Not in repos. Must build from source.
**GPU Rendering Backend:** Inherits wlroots (GLES2 default, pixman via `WLR_RENDERER=pixman`)
**GFX Ring Pressure:** **ZERO with pixman**, VERY LOW with GLES2
**Software Rendering Fallback:** YES -- `WLR_RENDERER=pixman`
**KMS/DRM Method:** Atomic modesetting
**Resource Usage:** MINIMAL (20-50MB RAM, bare-bones)

**Rendering Architecture:**
dwl is the Wayland equivalent of dwm -- minimal, configurable via source code editing (config.h). Uses wlroots directly. The absolute minimum compositor footprint possible while still being a functional tiling window manager.

**Limitations:**
- Configuration requires editing C source code and recompiling
- Ubuntu 24.04 ships wlroots 0.17, dwl 0.7 requires wlroots 0.18 -- must build wlroots from source too
- No system tray, status bar requires external tool (somebar, dwlb)

**Risk Assessment: LOWEST (with pixman) -- But installation is impractical on Ubuntu 24.04.**

---

### 12. Mir / Miriway (Canonical)

**Version on Ubuntu 24.04:** mir 2.x libraries available, Miriway compositor
**GPU Rendering Backend:** OpenGL only (no software renderer)
**GFX Ring Pressure:** **MEDIUM** (GL-based compositing)
**Software Rendering Fallback:** NO
**KMS/DRM Method:** GBM/KMS or EGLStreams
**Resource Usage:** MEDIUM

**Rendering Architecture:**
Mir is Canonical's compositor library, primarily targeting IoT/embedded/signage use cases. Miriway is a desktop compositor built on Mir. The rendering platform only supports GL -- there is no pixman/software fallback.

**Risk Assessment: MEDIUM-HIGH -- No software rendering path, GL-only, niche desktop use.**

**Install:**
```bash
sudo apt install miriway
```

---

### 13. gamescope (Valve's compositor)

**Version on Ubuntu 24.04:** NOT AVAILABLE (dependency conflicts with wlroots/libopenvr)
**GPU Rendering Backend:** **Vulkan async compute** (unique among compositors)
**GFX Ring Pressure:** **POTENTIALLY LOW** -- uses Vulkan compute queue, not graphics queue
**Software Rendering Fallback:** NO
**KMS/DRM Method:** DRM direct flip
**Resource Usage:** MEDIUM

**Rendering Architecture:**
gamescope is the only Wayland compositor that uses **Vulkan async compute** for compositing instead of the graphics queue. When it composites, it does so with async Vulkan compute, meaning the compositor work goes to the `comp_1.x.x` ring (compute queue) rather than `gfx_0.0.0` (graphics queue). This is unique and theoretically would NOT trigger the DCN crash loop since the GFX ring is not involved.

Additionally, gamescope supports DRM direct flip (zero-copy scanout) which bypasses compositing entirely for fullscreen applications.

**However:**
- Not available on Ubuntu 24.04 (wlroots/libopenvr dependency conflicts)
- Designed for gaming on Steam Deck, not desktop use
- Only works with AMD/Intel GPUs (Mesa)
- No window management, task bar, or desktop features
- Building from source requires resolving many dependencies

**Risk Assessment: THEORETICALLY LOW (compute queue avoids GFX ring) -- but impractical to install and not designed for desktop use.**

---

### 14. COSMIC (System76)

**Version on Ubuntu 24.04:** Not in repos. Unofficial PPA available but replaces critical system packages (Mesa, Wayland, LLVM).
**GPU Rendering Backend:** OpenGL ES via Smithay (default), Softbuffer for non-3D hardware
**GFX Ring Pressure:** **LOW-MEDIUM** (damage-driven rendering, but uses GL)
**Software Rendering Fallback:** Softbuffer exists for the iced UI toolkit but cosmic-comp itself requires GL
**KMS/DRM Method:** Atomic modesetting via Smithay
**Resource Usage:** MEDIUM (200-300MB RAM, Rust binary)

**Rendering Architecture:**
COSMIC's compositor (cosmic-comp) is built on Smithay. It uses OpenGL ES for compositing. The iced widget toolkit used for COSMIC apps can fall back to Softbuffer (CPU rendering) for its UI, but the compositor itself requires hardware-accelerated GL.

**Risk Assessment: MEDIUM -- GL-based, no pure software compositor path. PPA installation is RISKY (replaces Mesa, Wayland libs).**

**Install (CAUTION -- modifies critical system packages):**
```bash
sudo add-apt-repository ppa:cosmic-de/ppa
sudo apt update
sudo apt install cosmic-session
```

---

## Critical Technical Deep-Dive: wlroots Pixman Renderer

### How It Works

When `WLR_RENDERER=pixman` is set, wlroots:

1. **Skips EGL/GL entirely** -- no `eglCreateContext`, no GL shader compilation, no GFX ring allocation
2. **Creates a pixman image** for each output (monitor) as the render target
3. **Uses pixman library functions** (`pixman_image_composite32`) for all compositing -- these are SSE/AVX-optimized CPU routines
4. **Allocates DRM dumb buffers** via `DRM_IOCTL_MODE_CREATE_DUMB` -- these are simple linear framebuffers in system memory, mapped via `DRM_IOCTL_MODE_MAP_DUMB` and `mmap()`
5. **Copies the pixman-rendered image** into the DRM dumb buffer
6. **Performs KMS atomic commit** to scan out the dumb buffer -- this is a display controller operation (DCN path), NOT a GFX ring operation

### The GFX Ring Isolation

With pixman, the rendering pipeline is:
```
CPU (pixman library) -> System RAM (dumb buffer) -> KMS page-flip -> DCN scanout -> Display
```

Without pixman (GLES2), the pipeline is:
```
CPU (GL commands) -> GFX Ring -> GPU Shader Cores -> VRAM (GBM buffer) -> KMS page-flip -> DCN scanout -> Display
                     ^^^^^^^^
                     THIS IS WHERE THE TIMEOUT HAPPENS
```

The pixman path completely bypasses the GFX ring. Even if DCN is stalled and DMCUB firmware is hung, no GFX ring timeout can occur because nothing is ever submitted to the GFX ring.

### Performance on Raphael

The Raphael iGPU has only 2 CUs -- it is a very weak GPU. For desktop compositing (window borders, panel, wallpaper), the CPU (Ryzen 9 7950X with 16 cores) is actually FASTER than the 2-CU iGPU for many operations, especially with pixman's SSE/AVX optimizations.

Expected performance with pixman on a 1080p display:
- Static desktop: ~0% CPU (damage tracking prevents unnecessary rendering)
- Window drag/resize: 1-3% CPU on one core
- Video playback in a window: 5-10% CPU (client renders to SHM buffer, compositor composites via pixman)
- The 7950X can easily handle 4K@60Hz compositing in pixman without breaking a sweat

### Known Limitations

| Limitation | Impact | Workaround |
|-----------|--------|------------|
| No screencasting via xdg-desktop-portal-wlr | Cannot share screen in video calls | Use `wf-recorder` for recording, or `pipewire` with manual buffer sharing |
| No output rotation (except 90/180/270) | Cannot use arbitrary rotation angles | Use standard rotations only |
| No fractional scaling | 1x, 2x, 3x only | Use integer scaling or application-level scaling |
| Client GPU rendering still works | Apps using GL/Vulkan still use GPU | This is fine -- only compositor rendering is CPU |
| DRM dumb buffer + amdgpu had historical issues | wlroots #2916 | Fixed in wlroots 0.16+ by dropping GBM dependency |

### What About Client Applications?

When using `WLR_RENDERER=pixman`, only the **compositor's rendering** is software. Client applications can still use GPU acceleration:

- **GPU-accelerated clients** (Firefox with WebRender, VS Code, etc.): These render to their own GPU buffers (DMABUF) and pass them to the compositor. The compositor composites them into the final image using pixman (CPU). The client's GPU rendering uses the GFX ring, but since the COMPOSITOR is not using the GFX ring, a DCN stall won't cause an infinite crash loop -- the client might get one timeout, the GPU resets, and the client recovers.

- **SHM clients** (terminals, simple GUI apps): These render to shared memory buffers on the CPU. The compositor composites them via pixman. Zero GPU involvement at any level.

- **Worst case with pixman compositor:** A GPU-accelerated client gets a ring timeout, GPU does a MODE2 reset, client loses its GL context and must recreate it. But the COMPOSITOR survives because it never used the GFX ring. This is the key difference from Mutter where the compositor itself triggers the infinite crash loop.

---

## wlroots Vulkan Renderer Analysis

### Does Vulkan Avoid the GFX Ring?

**Short answer: No, not by default.** The wlroots Vulkan renderer currently uses the Vulkan **graphics queue**, which maps to the same `gfx_0.0.0` ring as OpenGL. There is an open proposal ([wlroots #3265](https://github.com/swaywm/wlroots/issues/3265)) to experiment with Vulkan **compute shaders** which could use the `comp_1.x.x` compute queue instead, but this has NOT been implemented.

The only compositor that actually uses Vulkan compute for compositing is **gamescope**, which explicitly submits compositing work to the async compute queue to avoid blocking the graphics queue.

**Conclusion:** `WLR_RENDERER=vulkan` does NOT help with this problem. It still uses the GFX ring. Use `WLR_RENDERER=pixman` instead.

---

## Recommendation Matrix

### Ranked by Crash Avoidance (Best to Worst)

| Rank | Compositor | Renderer | GFX Ring Usage | Install Difficulty | Desktop Usability | Recommendation |
|------|-----------|----------|---------------|-------------------|-------------------|----------------|
| **1** | **labwc** | pixman | **ZERO** | Easy (apt) | Good (stacking, Openbox-like) | **BEST CHOICE** |
| **2** | **Sway** | pixman | **ZERO** | Easy (apt) | Good (tiling, i3-like) | **BEST CHOICE (tiling)** |
| **3** | **Weston** | pixman | **ZERO** | Easy (apt) | Limited (reference only) | Good for testing |
| **4** | **cage** | pixman | **ZERO** | Easy (apt) | Kiosk only | Good for single-app |
| **5** | **niri** | pixman | **ZERO** | Hard (build) | Good (scrolling tiling) | If you like the UX |
| **6** | **KWin** | QPainter | **ZERO** | Easy (apt) | Full DE but degraded visuals | Last resort for KDE users |
| **7** | **Sway** | gles2 | LOW | Easy (apt) | Good | Acceptable after firmware fix |
| **8** | **labwc** | gles2 | VERY LOW | Easy (apt) | Good | Acceptable after firmware fix |
| **9** | **KWin** | OpenGL | MEDIUM | Easy (apt) | Full DE, good recovery | After firmware fix |
| **10** | **COSMIC** | OpenGL ES | LOW-MEDIUM | Risky PPA | Full DE | After firmware fix |
| **11** | **Wayfire** | GLES2 | HIGH | Easy (apt) | Eye candy | NOT recommended |
| **12** | **Hyprland** | GLES3.2 | HIGH | PPA | Eye candy | NOT recommended |
| **13** | **Mutter** | OpenGL | **HIGH** | Default | Full GNOME DE | **DO NOT USE** |

### Recommended Deployment Strategy

#### Phase 1: Immediate (Before Firmware Fix)

Use a pixman-rendered compositor to eliminate crash trigger:

```bash
# Option A: labwc (stacking, familiar for GNOME/XFCE users)
sudo apt install labwc waybar foot
mkdir -p ~/.config/labwc
echo 'WLR_RENDERER=pixman' > ~/.config/labwc/environment

# Option B: Sway (tiling, for i3 users)
sudo apt install sway waybar foot
mkdir -p ~/.config/environment.d
echo 'WLR_RENDERER=pixman' > ~/.config/environment.d/91-wlr-pixman.conf
```

#### Phase 2: After Firmware Fix (DMCUB >= 0.0.224.0)

Switch to GPU-accelerated rendering for better performance:

```bash
# Remove pixman override:
rm ~/.config/labwc/environment  # or
rm ~/.config/environment.d/91-wlr-pixman.conf

# Or switch back to GNOME if desired (now safe with fixed firmware)
```

#### Phase 3: Long-term

Once firmware and kernel are both updated and stable:
- Return to GNOME/Mutter if desired (with `MUTTER_DEBUG_KMS_THREAD_TYPE=user` as defense)
- Or keep labwc/Sway for lower resource usage and better stability

---

## GDM Integration for Session Selection

GDM (GNOME Display Manager) reads session files from `/usr/share/wayland-sessions/` and `/usr/share/xsessions/`. Installing sway or labwc via apt automatically installs the session file. At the GDM login screen, click the gear icon to select the session.

To force a specific session as default:

```bash
# Set default session for a user
sudo -u gdm dbus-run-session gsettings set org.gnome.login-screen sessions '["labwc"]'
# Or edit /var/lib/AccountsService/users/<username>:
# [User]
# Session=labwc
```

To launch a pixman session from GDM, create a custom session file:

```bash
sudo tee /usr/share/wayland-sessions/labwc-pixman.desktop << 'EOF'
[Desktop Entry]
Name=labwc (Software Rendering)
Comment=labwc compositor with pixman software renderer
Exec=env WLR_RENDERER=pixman labwc
Type=Application
DesktopNames=labwc
EOF

sudo tee /usr/share/wayland-sessions/sway-pixman.desktop << 'EOF'
[Desktop Entry]
Name=Sway (Software Rendering)
Comment=Sway compositor with pixman software renderer
Exec=env WLR_RENDERER=pixman sway
Type=Application
DesktopNames=sway
EOF
```

---

## Verification Commands

```bash
# 1. Confirm compositor is running
echo $WAYLAND_DISPLAY  # Should show "wayland-0" or similar

# 2. Confirm renderer type
# For wlroots compositors (sway, labwc, etc.):
# Check startup logs:
journalctl --user -u sway 2>/dev/null || journalctl -b | grep -i "renderer\|pixman\|gles\|vulkan"
# Expected with pixman: "Using pixman renderer"
# Expected with GLES2: "Using GLES2 renderer"

# 3. Confirm ZERO GFX ring submissions (pixman mode)
# After 60 seconds of idle desktop:
cat /sys/kernel/debug/dri/1/amdgpu_fence_info 2>/dev/null | grep gfx
# With pixman: sequence numbers should NOT increase during idle

# 4. Monitor for ring timeouts
dmesg -w | grep -i "ring.*timeout"
# Expected: no output (no timeouts)

# 5. Confirm card assignment
for card in /sys/class/drm/card[0-9]; do
    vendor=$(cat "$card/device/vendor" 2>/dev/null)
    driver=$(basename $(readlink "$card/device/driver") 2>/dev/null)
    echo "$(basename $card): vendor=$vendor driver=$driver"
done
# Expected: card0=amdgpu, card1=nvidia
```

---

## Sources

### Compositor Projects
- [wlroots environment variables](https://github.com/swaywm/wlroots/blob/master/docs/env_vars.md)
- [wlroots pixman renderer issue #2399](https://github.com/swaywm/wlroots/issues/2399)
- [wlroots DRM dumb allocator + amdgpu issue #2916](https://github.com/swaywm/wlroots/issues/2916)
- [wlroots Vulkan compute experiment #3265](https://github.com/swaywm/wlroots/issues/3265)
- [wlroots scene-graph API](https://github.com/swaywm/wlroots/pull/1966)
- [Sway 1.10 release notes](https://github.com/swaywm/sway/releases/tag/1.10)
- [Sway software rendering support #6613](https://github.com/swaywm/sway/issues/6613)
- [labwc project](https://labwc.github.io/)
- [Weston documentation](https://wayland.pages.freedesktop.org/weston/toc/running-weston.html)
- [niri project](https://github.com/niri-wm/niri)
- [Hyprland Aquamarine](https://wiki.hypr.land/Hypr-Ecosystem/aquamarine/)
- [gamescope](https://github.com/ValveSoftware/gamescope)
- [KWin environment variables](https://community.kde.org/KWin/Environment_Variables)

### AMD GPU Ring Architecture
- [AMDGPU Ring Buffer documentation](https://docs.kernel.org/gpu/amdgpu/ring-buffer.html)
- [AMDGPU driver documentation](https://docs.kernel.org/gpu/amdgpu/driver-core.html)

### Ubuntu Package Versions
- [sway Noble package](https://launchpad.net/ubuntu/noble/+package/sway) -- version 1.8.1-2 / 1.9-1build2
- [labwc Noble package](https://launchpad.net/ubuntu/noble/+package/labwc) -- version 0.7.1-1build1
- [weston Noble package](https://launchpad.net/ubuntu/noble/+package/weston) -- version 12.0.1-1 / 13.0.0-4build3
- [wlroots Noble package](https://launchpad.net/ubuntu/+source/wlroots) -- version 0.16.2-3 / 0.17.1-2.1build1
- [wayfire Noble package](https://launchpad.net/ubuntu/noble/+package/wayfire) -- version 0.8.0

### Bug Reports
- [KDE Bug #453147: amdgpu GPU reset crash loop](https://bugs.kde.org/show_bug.cgi?id=453147)
- [KDE Bug #475322: GPU reset hangs KWin via Xwayland](https://bugs.kde.org/show_bug.cgi?id=475322)
- [Hyprland #5271: Crashes on startup on AMDGPU](https://github.com/hyprwm/Hyprland/issues/5271)
- [drm/amd #5073: Fence fallback timer expired on Raphael](https://gitlab.freedesktop.org/drm/amd/-/work_items/5073)

### Community Research
- [Arch Wiki: Sway](https://wiki.archlinux.org/title/Sway)
- [Arch Wiki: Wayland](https://wiki.archlinux.org/title/Wayland)
- [Arch Wiki: AMDGPU](https://wiki.archlinux.org/title/AMDGPU)
- [GNOME Shell Frame Clock blog post](https://blogs.gnome.org/shell-dev/2020/07/02/splitting-up-the-frame-clock/)
- [COSMIC desktop PPA for Ubuntu 24.04](https://www.omgubuntu.co.uk/2025/12/install-cosmic-desktop-ubuntu-24-04-ppa)
