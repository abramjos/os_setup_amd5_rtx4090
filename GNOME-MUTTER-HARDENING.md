# GNOME/Mutter Hardening Guide for AMD Raphael iGPU + NVIDIA RTX 4090 Headless

**Hardware:** AMD Ryzen 9 7950X (Raphael, GC 10.3.6, DCN 3.1.5, 2 CUs) + NVIDIA RTX 4090 (headless compute)
**OS:** Ubuntu 24.04 LTS (Noble), Mutter 46.2, GNOME 46
**Date:** 2026-03-29
**Purpose:** Comprehensive list of every GNOME/Mutter hardening option available for this hardware

---

## 1. MUTTER_DEBUG_* Environment Variables (Hardening)

These are standalone environment variables (NOT topics for the `MUTTER_DEBUG=` var). They control specific Mutter subsystem behaviors. Set them in `/etc/environment.d/*.conf` files.

### 1.1 MUTTER_DEBUG_KMS_THREAD_TYPE

**Status: CRITICAL -- MUST SET**

```
MUTTER_DEBUG_KMS_THREAD_TYPE=user
```

| Property | Detail |
|----------|--------|
| **What it does** | Forces Mutter's KMS page-flip thread to use normal (SCHED_OTHER) priority instead of real-time (SCHED_FIFO) priority |
| **Why needed** | Mutter 45+ creates an RT-priority KMS thread for cursor latency. When amdgpu takes too long on a page flip (DCN latency on Raphael), the thread exceeds its RT scheduling deadline and the kernel sends SIGKILL to gnome-shell. This crashes GDM/gnome-shell independently of ring timeouts. |
| **Values** | `user` (normal priority), `kernel` (RT priority, default) |
| **Ubuntu bug** | [LP #2034619](https://bugs.launchpad.net/ubuntu/+source/mutter/+bug/2034619) |
| **Fix status** | Workaround. A universal fix is coming in Mutter 48+ (Ubuntu 25.04+). For Ubuntu 24.04 (Mutter 46.2), this env var remains necessary. |
| **Install location** | `/etc/environment.d/90-mutter-kms.conf` |

### 1.2 MUTTER_DEBUG_DISABLE_HW_CURSORS

**Status: RECOMMENDED**

```
MUTTER_DEBUG_DISABLE_HW_CURSORS=1
```

| Property | Detail |
|----------|--------|
| **What it does** | Disables hardware cursor planes and forces Mutter to render the cursor as part of the compositor framebuffer (software cursor) |
| **Why needed** | Hardware cursor plane updates interact with the DCN display controller. On Raphael with DCN stall, even hardware cursor updates can contribute to GFX ring traffic. Disabling HW cursors eliminates one source of DCN interaction. |
| **Values** | `1` (disable HW cursors), unset (default, HW cursors enabled) |
| **Trade-off** | Slightly higher CPU overhead for cursor rendering. Negligible on Ryzen 9 7950X. On Wayland, every cursor move triggers a partial recomposite through the GFX ring. On X11 with `AccelMethod "none"`, software cursor rendering is CPU-only, so this variable has no ring pressure effect. |
| **When to remove** | After firmware fix is confirmed stable (10+ clean boots), test with HW cursors re-enabled |
| **Install location** | `/etc/environment.d/50-gpu-display.conf` |

### 1.3 MUTTER_DEBUG_FORCE_KMS_MODE

**Status: DIAGNOSTIC / FALLBACK**

```
MUTTER_DEBUG_FORCE_KMS_MODE=simple
```

| Property | Detail |
|----------|--------|
| **What it does** | Forces Mutter to use the legacy (non-atomic) DRM modesetting API instead of the modern atomic API |
| **Why consider** | Atomic modesetting makes multi-property commits (CRTC + plane + connector in one ioctl). If the atomic path triggers a DCN bug, falling back to legacy mode can isolate the issue. Legacy mode uses separate `drmModeSetCrtc`, `drmModePageFlip` calls. |
| **Values** | `simple` (legacy DRM API), `atomic` (atomic DRM API, default) |
| **Replaces** | `MUTTER_DEBUG_ENABLE_ATOMIC_KMS=0` (pre-Mutter 43 variable name) |
| **Risk** | Legacy KMS mode may not support all features (VRR, multi-plane). Functional but reduced capability. |
| **When to use** | If atomic modesetting is causing display issues that the firmware fix does not resolve |
| **Install location** | `/etc/environment.d/90-mutter-kms.conf` |

### 1.4 MUTTER_DEBUG_FORCE_EGL_STREAM

**Status: NOT RECOMMENDED for this hardware**

```
MUTTER_DEBUG_FORCE_EGL_STREAM=1
```

| Property | Detail |
|----------|--------|
| **What it does** | Forces Mutter to use the EGL Stream rendering backend instead of GBM |
| **Why NOT needed** | EGL Stream is for NVIDIA-primary display. This system uses AMD iGPU for display with GBM, which is the correct path. Setting this would attempt to use NVIDIA for display rendering -- opposite of the architecture goal. |
| **Values** | `1` (force EGL Stream), unset (use GBM, default) |

### 1.5 MUTTER_DEBUG_TRIPLE_BUFFERING

**Status: INFORMATIONAL**

```
MUTTER_DEBUG_TRIPLE_BUFFERING=auto
```

| Property | Detail |
|----------|--------|
| **What it does** | Controls Ubuntu's dynamic triple/double buffering patch for Mutter |
| **Values** | `auto` (Ubuntu default -- dynamic switching), `always` (force triple buffering), `never` (force double buffering) |
| **Ubuntu-specific** | This is an Ubuntu-only patch, not upstream Mutter. Ubuntu 24.04 ships with dynamic triple buffering enabled by default. |
| **For this hardware** | `auto` is correct. Triple buffering can help smooth frame delivery when DCN latency is variable. Setting `never` could increase frame drops during DCN recovery periods. |
| **Known issue** | [LP #2070437](https://bugs.launchpad.net/bugs/2070437): `MUTTER_DEBUG_TRIPLE_BUFFERING=always` causes issues on some systems |
| **Install location** | `/etc/environment.d/90-mutter-kms.conf` |

### 1.6 MUTTER_DEBUG_ENABLE_ATOMIC_KMS

**Status: DEPRECATED -- use MUTTER_DEBUG_FORCE_KMS_MODE instead**

```
MUTTER_DEBUG_ENABLE_ATOMIC_KMS=0
```

| Property | Detail |
|----------|--------|
| **What it does** | Disables atomic KMS API (same effect as `MUTTER_DEBUG_FORCE_KMS_MODE=simple`) |
| **Status** | Pre-Mutter 43 variable. Still read in some versions for backward compat. Use `MUTTER_DEBUG_FORCE_KMS_MODE=simple` on Mutter 43+ (Ubuntu 24.04). |

### 1.7 MUTTER_DEBUG_DUMMY_MODE_SPECS

**Status: TESTING ONLY**

```
MUTTER_DEBUG_DUMMY_MODE_SPECS=1920x1080
```

| Property | Detail |
|----------|--------|
| **What it does** | Overrides the default set of display modes available when using the dummy monitor manager |
| **When to use** | Only for nested/headless testing, not relevant for real hardware |

### 1.8 MUTTER_DEBUG_NUM_DUMMY_MONITORS / MUTTER_DEBUG_DUMMY_MONITOR_SCALES

**Status: TESTING ONLY -- not relevant for real hardware**

### 1.9 MUTTER_DEBUG_COPY_MODE (MUTTER_DEBUG_MULTI_GPU_FORCE_COPY_MODE)

**Status: DIAGNOSTIC for multi-GPU systems**

```
MUTTER_DEBUG_MULTI_GPU_FORCE_COPY_MODE=primary-gpu-cpu
```

| Property | Detail |
|----------|--------|
| **What it does** | Forces a specific multi-GPU copy mode for display buffer sharing between GPUs |
| **Values** | `zero-copy`, `primary-gpu-gpu`, `primary-gpu-cpu` |
| **For this hardware** | Not typically needed. The AMD iGPU is the primary display GPU and handles all rendering directly. This matters more for NVIDIA-primary display setups where buffers must be copied between GPUs. |
| **When to test** | If seeing visual corruption or performance issues in multi-monitor setups |

---

## 2. MUTTER_DEBUG Topic Flags (Logging/Diagnostics)

These are values for the `MUTTER_DEBUG` environment variable (comma-separated). They increase logging verbosity but do NOT change behavior. Useful for debugging, not for hardening.

```bash
# Example: enable KMS and render debug logging
MUTTER_DEBUG="kms,render"
```

### Complete Topic List (from Mutter 46 src/core/util.c)

| Topic | Enum | What It Logs |
|-------|------|-------------|
| `focus` | META_DEBUG_FOCUS | Window focus changes |
| `workarea` | META_DEBUG_WORKAREA | Work area calculations |
| `stack` | META_DEBUG_STACK | Window stacking order |
| `sm` | META_DEBUG_SM | Session management |
| `events` | META_DEBUG_EVENTS | X11/input events |
| `window-state` | META_DEBUG_WINDOW_STATE | Window state changes |
| `window-ops` | META_DEBUG_WINDOW_OPS | Window operations |
| `geometry` | META_DEBUG_GEOMETRY | Window geometry calculations |
| `placement` | META_DEBUG_PLACEMENT | Window placement |
| `display` | META_DEBUG_DISPLAY | Display/output changes |
| `keybindings` | META_DEBUG_KEYBINDINGS | Keyboard bindings |
| `sync` | META_DEBUG_SYNC | X11 synchronization |
| `startup` | META_DEBUG_STARTUP | Startup notification |
| `prefs` | META_DEBUG_PREFS | Preference changes |
| `edge-resistance` | META_DEBUG_EDGE_RESISTANCE | Edge resistance snapping |
| `dbus` | META_DEBUG_DBUS | D-Bus operations |
| `input` | META_DEBUG_INPUT | Input device management |
| `wayland` | META_DEBUG_WAYLAND | Wayland protocol |
| **`kms`** | META_DEBUG_KMS | **KMS/modesetting operations (useful for DCN debugging)** |
| `screen-cast` | META_DEBUG_SCREEN_CAST | Screen casting |
| `remote-desktop` | META_DEBUG_REMOTE_DESKTOP | Remote desktop |
| `backend` | META_DEBUG_BACKEND | Backend operations |
| **`render`** | META_DEBUG_RENDER | **Render/compositing operations (useful for GFX ring debugging)** |
| `color` | META_DEBUG_COLOR | Color management |
| `input-events` | META_DEBUG_INPUT_EVENTS | Individual input events (very verbose) |
| `eis` | META_DEBUG_EIS | Emulated Input Server |
| **`kms-deadline`** | META_DEBUG_KMS_DEADLINE | **KMS deadline/timing (useful for page-flip latency debugging)** |
| `session-management` | META_DEBUG_SESSION_MANAGEMENT | Session management v2 |
| `x11` | META_DEBUG_X11 | X11 operations |
| `workspaces` | META_DEBUG_WORKSPACES | Workspace operations |

**For diagnosing this hardware issue, the most useful topics are:**
```bash
MUTTER_DEBUG="kms,kms-deadline,render,backend"
```

### Legacy MUTTER_* Variables (Logging Only)

| Variable | Purpose |
|----------|---------|
| `MUTTER_VERBOSE` | Enable verbose mode (all logging) |
| `MUTTER_USE_LOGFILE` | Log all messages to a temporary file |
| `MUTTER_SYNC` | Call XSync after each X call (X11 only) |
| `MUTTER_G_FATAL_WARNINGS` | Abort on any GLib warning |
| `MUTTER_DISPLAY` | Override X11 display name |
| `MUTTER_WM_CLASS_FILTER` | Restrict Mutter to specific WM_CLASS names |

---

## 3. CLUTTER_* Environment Variables

Clutter is Mutter's internal rendering framework (forked into Mutter, no longer standalone). These variables affect compositing behavior.

### 3.1 Variables That Affect Rendering Performance

| Variable | Values | Effect | Relevance |
|----------|--------|--------|-----------|
| `CLUTTER_SHOW_FPS` | `1` | Prints FPS per CRTC to journal | **Diagnostic only** -- useful to verify frame rate under load |
| `CLUTTER_DEFAULT_FPS` | Integer (e.g., `30`) | Sets the default framerate target | **POTENTIAL HARDENING** -- reducing from 60 to 30 halves GFX ring submissions |
| `CLUTTER_BACKEND` | `wayland`, `x11`, `eglnative` | Selects windowing backend | Automatically set by session type. Do not override manually. |

### 3.2 Variables Removed in Modern Mutter (Do NOT Use)

| Variable | Status | Notes |
|----------|--------|-------|
| `CLUTTER_VBLANK` | **REMOVED** in Mutter 3.32+ | Was `none`, `dri`, `glx`. No longer applicable -- vblank is controlled by the DRM backend internally. |
| `CLUTTER_DRIVER` | **REMOVED** | Driver selection is now automatic via EGL |
| `CLUTTER_INPUT_BACKEND` | **REMOVED** | Input handling moved to libinput |
| `CLUTTER_SCALE` | Still works | Forces window scaling factor. Not relevant to GPU load. |
| `CLUTTER_TEXT_DIRECTION` | Still works | Sets text directionality. Not relevant to GPU load. |

### 3.3 Debug Flags (Require Debug Build)

These require Mutter compiled with `--enable-debug` (Ubuntu ships release builds without full debug).

| Variable | Purpose |
|----------|---------|
| `CLUTTER_DEBUG` | Enable debug output for Clutter subsystems (comma-separated flags) |
| `CLUTTER_PAINT` | Enable paint debug modes (e.g., `paint-volumes` to visualize damage regions) |
| `CLUTTER_ENABLE_DIAGNOSTIC` | Set to `1` to enable runtime deprecation warnings |

**Note:** `CLUTTER_PAINT` and `CLUTTER_DEBUG` require debug-enabled builds. Ubuntu's release builds have limited debug support. These are not useful for production hardening.

---

## 4. COGL_* Environment Variables

Cogl is Mutter's internal OpenGL abstraction layer.

| Variable | Values | Effect | Relevance |
|----------|--------|--------|-----------|
| `COGL_DEBUG` | `show-source`, various flags | Debug logging for GL operations | Diagnostic only |
| `COGL_DRIVER` | `gl3`, `gles2` | Override GL driver selection | **Do not set** -- let Mutter auto-select |
| `META_DISABLE_MIPMAPS` | `1` | Disable mipmaps for window pixmap textures | **POTENTIAL HARDENING** -- reduces texture memory and GL complexity. Minor visual degradation when scaling windows. |

---

## 5. GDM3 Configuration (/etc/gdm3/custom.conf)

### 5.1 Recommended Configuration (Post-Firmware-Fix)

```ini
[daemon]
# Wayland vs X11 -- see analysis in section 5.2
WaylandEnable=false
# Uncomment to set default session explicitly:
# DefaultSession=gnome-xorg.desktop

[security]

[xdmcp]

[chooser]

[debug]
# Enable=true    # Uncomment for debugging GDM issues
```

### 5.2 WaylandEnable: Wayland vs X11 Analysis

**Post-firmware-fix, which is safer?**

| Factor | GNOME on X11 | GNOME on Wayland |
|--------|-------------|-----------------|
| **GFX ring pressure** | LOWER with `AccelMethod "none"` -- Mutter still uses GL for compositing, but 2D acceleration is CPU-only | HIGHER -- Mutter uses EGL directly on DRM device, all rendering through GFX ring, no `AccelMethod` control |
| **Compositing bypass** | Can use `AccelMethod "none"` to eliminate 2D ring traffic | No equivalent -- Wayland compositing is mandatory |
| **GPU pinning** | Deterministic via `xorg.conf` BusID | Automatic -- Mutter uses DRM device enumeration |
| **NVIDIA isolation** | Clean via xorg.conf `ServerLayout` | Mutter may probe NVIDIA DRM device at startup (bug [#2969](https://gitlab.gnome.org/GNOME/mutter/-/issues/2969)) |
| **HW cursor behavior** | X11 cursor via XFixes; `MUTTER_DEBUG_DISABLE_HW_CURSORS` works | Wayland cursor via DRM planes; `MUTTER_DEBUG_DISABLE_HW_CURSORS` works |
| **Triple buffering** | Ubuntu's dynamic triple buffering applies | Same |
| **KMS thread SIGKILL** | KMS thread still active on X11 with native backend | Same risk |
| **VRR / mixed refresh** | Locked to lowest refresh rate | Native support |
| **Fractional scaling** | Poor (requires `xrandr` hacks) | Native |
| **Known NVIDIA VRAM leak** | None | GLVidHeapReuseRatio bug on Wayland ([NVIDIA #185](https://github.com/NVIDIA/egl-wayland/issues/185)) |

**Recommendation:**

| Scenario | Setting | Rationale |
|----------|---------|-----------|
| **Initial setup / pre-firmware-fix** | `WaylandEnable=false` | X11 with `AccelMethod "none"` provides maximum ring pressure reduction |
| **Post-firmware-fix, stability confirmed** | `WaylandEnable=false` still recommended | X11 provides better GPU isolation for dual-GPU. Switch to Wayland only if fractional scaling or VRR is needed. |
| **If X11 fails (missing NVIDIA driver)** | `WaylandEnable=true` | Wayland bypasses xorg.conf, works without NVIDIA driver installed |

### 5.3 GDM3 Environment Overrides

GDM runs its own gnome-shell instance for the login greeter. The greeter generates the same GFX ring pressure as a user session. To apply environment variables to the GDM greeter:

```bash
# Method 1: /etc/environment.d/ files (affects all users AND GDM)
# Variables in /etc/environment.d/*.conf are loaded by systemd
# and apply to ALL user sessions including GDM

# Method 2: GDM-specific environment file
# /etc/gdm3/PostLogin/Default (runs after login)
# /etc/gdm3/PreSession/Default (runs before session)

# Method 3: systemd override for gdm.service
sudo systemctl edit gdm3.service
# Add:
# [Service]
# Environment=MUTTER_DEBUG_KMS_THREAD_TYPE=user
```

**Important:** Using LightDM instead of GDM3 eliminates the greeter GFX ring pressure entirely. LightDM uses a lightweight GTK greeter with zero GL. If staying with GNOME desktop but concerned about login screen crashes, consider LightDM as the display manager even when using GNOME as the session.

### 5.4 GDM3 Advanced Options

| Option | Section | Values | Purpose |
|--------|---------|--------|---------|
| `WaylandEnable` | [daemon] | `true`/`false` | Enable/disable Wayland session option |
| `DefaultSession` | [daemon] | `gnome.desktop`, `gnome-xorg.desktop` | Default session type |
| `AutomaticLoginEnable` | [daemon] | `true`/`false` | Auto-login without password prompt |
| `AutomaticLogin` | [daemon] | username | User to auto-login |
| `TimedLoginEnable` | [daemon] | `true`/`false` | Timed auto-login |
| `TimedLogin` | [daemon] | username | User for timed login |
| `TimedLoginDelay` | [daemon] | seconds | Delay before timed login |
| `FirstVT` | [daemon] | integer (e.g., `7`) | VT number for GDM |
| `Enable` | [debug] | `true`/`false` | Enable GDM debug logging |

---

## 6. gsettings / dconf Hardening

### 6.1 Reduce Compositor Overhead

```bash
# Disable ALL animations (MOST IMPACTFUL single change)
# Eliminates transition animations that generate continuous GFX ring submissions
gsettings set org.gnome.desktop.interface enable-animations false

# Increase check-alive-timeout to prevent "app not responding" dialogs
# during GPU recovery periods (default is 5000ms = 5s)
gsettings set org.gnome.mutter check-alive-timeout 30000

# Disable edge tiling (reduces compositor work during window drag)
gsettings set org.gnome.mutter edge-tiling false

# Disable attach-modal-dialogs (reduces compositor relayout)
gsettings set org.gnome.mutter attach-modal-dialogs false
```

### 6.2 Complete org.gnome.mutter Schema Keys

| Key | Default | Hardened Value | Effect |
|-----|---------|---------------|--------|
| `overlay-key` | `Super_L` | (keep default) | Super key for activities overview |
| `attach-modal-dialogs` | `true` | `false` | Detaches modal dialogs -- reduces relayout work |
| `edge-tiling` | `true` | `false` | Disables edge snap -- reduces geometry recalculation |
| `dynamic-workspaces` | `true` | `true` | Keep default -- minimal impact |
| `workspaces-only-on-primary` | `true` | `true` | Keep default -- minimal impact |
| `center-new-windows` | `false` | (keep default) | No performance impact |
| `auto-maximize` | `false` | (keep default) | No performance impact |
| `focus-change-on-pointer-rest` | `true` | (keep default) | No performance impact |
| `draggable-border-width` | `10` | (keep default) | No performance impact |
| `check-alive-timeout` | `5000` | **`30000`** | Prevents premature "not responding" during GPU recovery |
| `no-tab-popup` | `false` | (keep default) | No performance impact |
| `locate-pointer-key` | (none) | (keep default) | No performance impact |
| `experimental-features` | `[]` | See below | Experimental feature flags |

### 6.3 org.gnome.mutter experimental-features

```bash
# List current experimental features
gsettings get org.gnome.mutter experimental-features

# Available features (Mutter 46, Ubuntu 24.04):
# - 'scale-monitor-framebuffer'  -- fractional scaling (1.25x, 1.5x, 1.75x)
# - 'variable-refresh-rate'      -- VRR / FreeSync support
# - 'xwayland-native-scaling'    -- scale Xwayland apps on HiDPI (Wayland only)
# - 'autoclose-xwayland'         -- auto-terminate Xwayland if no X11 clients

# For this hardware: DO NOT enable unless specifically needed
# - 'variable-refresh-rate' adds DCN complexity (avoid during stabilization)
# - 'scale-monitor-framebuffer' increases rendering resolution (more GPU work)
# - 'autoclose-xwayland' is safe but irrelevant on X11 session
gsettings set org.gnome.mutter experimental-features "[]"
```

### 6.4 Reduce GNOME Shell Effects

```bash
# Disable desktop search indexing (reduces I/O and CPU, indirectly helps GPU)
gsettings set org.gnome.desktop.search-providers disable-external true

# Reduce desktop effects
gsettings set org.gnome.desktop.interface enable-hot-corners false

# Disable screen locking (prevents lock screen compositor overhead)
# Only do this if physical security is not a concern
gsettings set org.gnome.desktop.screensaver lock-enabled false
gsettings set org.gnome.desktop.session idle-delay 0

# Disable text cursor blink (eliminates one source of periodic recomposite)
gsettings set org.gnome.desktop.interface cursor-blink false

# Reduce notification display time
gsettings set org.gnome.desktop.notifications show-banners false

# Disable location services (reduces background activity)
gsettings set org.gnome.system.location enabled false

# Disable background app refresh
gsettings set org.gnome.desktop.background show-desktop-icons false
```

### 6.5 Power Management (Prevent GPU State Transitions)

```bash
# Prevent screen blanking (avoids DPMS state transitions that interact with DCN)
gsettings set org.gnome.desktop.session idle-delay 0
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-timeout 0
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'
gsettings set org.gnome.settings-daemon.plugins.power idle-dim false

# Disable automatic screen brightness (avoids backlight changes through DCN)
gsettings set org.gnome.settings-daemon.plugins.power ambient-enabled false

# Disable Night Light (avoids color temperature changes through DCN)
gsettings set org.gnome.settings-daemon.plugins.color night-light-enabled false
```

---

## 7. GNOME Shell Extensions for Reducing GPU Load

### 7.1 Recommended Extensions

| Extension | GNOME 46 | Effect | Install |
|-----------|---------|--------|---------|
| **[Just Perfection](https://extensions.gnome.org/extension/3843/just-perfection/)** | Yes | Disable individual GNOME Shell UI elements (panel, activities, search, dash, workspace thumbnails). Every disabled element reduces compositor render work. | `gnome-extensions install justa@just-perfection` |
| **[Disable Workspace Animation](https://extensions.gnome.org/extension/6694/disable-workspace-animation/)** | Yes | Eliminates workspace switch animation (continuous GL draw during transition) | gnome-extensions.org |
| **[Disable Workspace Switch Animation](https://extensions.gnome.org/extension/4290/disable-workspace-switch-animation-for-gnome-40/)** | Check | Same purpose as above, older implementation | gnome-extensions.org |
| **[No Overview at Startup](https://extensions.gnome.org/extension/4099/no-overview/)** | Yes | Prevents the Activities overview from showing at login (avoids a burst of GL rendering at session start) | gnome-extensions.org |

### 7.2 Just Perfection Hardening Settings

After installing Just Perfection, configure via GUI or `dconf`:

```bash
# Disable Activities button (reduces hot corner compositor checks)
dconf write /org/gnome/shell/extensions/just-perfection/activities-button false

# Disable background menu (right-click on desktop)
dconf write /org/gnome/shell/extensions/just-perfection/background-menu false

# Disable animation (redundant with gsettings but extension-level control)
dconf write /org/gnome/shell/extensions/just-perfection/animation 0

# Set animation speed to fastest if keeping animations
# 0=disable, 1=fastest, 2=fast, 3=default, 4=slow, 5=slowest
dconf write /org/gnome/shell/extensions/just-perfection/animation 1

# Disable window demands attention focus
dconf write /org/gnome/shell/extensions/just-perfection/window-demands-attention-focus true

# Disable workspace popup (reduces transient render)
dconf write /org/gnome/shell/extensions/just-perfection/workspace-popup false

# Disable workspace switcher in overview
dconf write /org/gnome/shell/extensions/just-perfection/workspace false

# Disable search in overview
dconf write /org/gnome/shell/extensions/just-perfection/search false

# Disable dash
dconf write /org/gnome/shell/extensions/just-perfection/dash false

# Disable app grid in overview
dconf write /org/gnome/shell/extensions/just-perfection/app-grid false
```

### 7.3 Disable All User Extensions (Nuclear Option)

```bash
# Disable all user-installed extensions (reduces gnome-shell complexity)
gsettings set org.gnome.shell disable-user-extensions true

# Or selectively disable specific extensions
gnome-extensions disable extension-uuid@author
```

---

## 8. Display Environment Variables (GPU Routing)

These ensure the AMD iGPU handles all display rendering and NVIDIA remains headless.

```bash
# /etc/environment.d/50-gpu-display.conf

# Force AMD iGPU for display rendering (DRI_PRIME=0 = default/primary GPU)
DRI_PRIME=0

# Force Mesa for desktop OpenGL (prevent NVIDIA libGL interception)
__GLX_VENDOR_LIBRARY_NAME=mesa

# Disable VSync for headless NVIDIA scenarios
__GL_SYNC_TO_VBLANK=0
```

### 8.1 LIBGL_ALWAYS_SOFTWARE (Nuclear Option)

```bash
# Force ALL OpenGL through llvmpipe (CPU software rendering)
# This eliminates ALL GFX ring submissions from ALL applications
LIBGL_ALWAYS_SOFTWARE=1
```

| Property | Detail |
|----------|--------|
| **Effect** | Mesa's llvmpipe software rasterizer handles all GL calls on CPU |
| **GFX ring pressure** | ZERO (no GPU involvement for rendering) |
| **Performance** | Severely degraded. gnome-shell becomes extremely slow. |
| **When to use** | Only as a diagnostic to confirm the issue is GFX-ring-related |
| **Note** | Does NOT prevent Mutter from creating an EGL context on the DRM device. EGL context creation itself may still touch the GFX ring on Wayland. |

---

## 9. Ubuntu 24.04-Specific Mutter Patches

### 9.1 Ubuntu Mutter 46.2 SRU History

Ubuntu 24.04 ships Mutter 46.2 with Ubuntu-specific patches. Key SRU changes:

| Version | Key Changes | Relevance |
|---------|-------------|-----------|
| `46.2-1ubuntu0.24.04.1` | Upstream 46.1 + 46.2 merged. Dynamic triple buffering patch refreshed. `linux-drm-syncobj-v1` disabled. | Triple buffering helps frame pacing on slow DCN |
| `46.2-1ubuntu0.24.04.10` | Handle null views in NVIDIA sessions, X11 cursor theme support | Prevents crash with NVIDIA dGPU present |
| `46.2-1ubuntu0.24.04.14` | Latest SRU (check `apt policy mutter`) | May contain additional AMD fixes |

### 9.2 Ubuntu-Only Features

| Feature | Status | Notes |
|---------|--------|-------|
| **Dynamic triple buffering** | Enabled by default (`MUTTER_DEBUG_TRIPLE_BUFFERING=auto`) | Ubuntu patch, not upstream. Helps smooth frame delivery. |
| **`linux-drm-syncobj-v1` explicit sync** | Disabled | Ubuntu disabled this feature from upstream 46.1 in the LTS SRU. Not available on 24.04. |

### 9.3 Keeping Mutter Updated

```bash
# Check current version
apt policy mutter libmutter-14-0

# Ensure latest SRU is installed
sudo apt update && sudo apt upgrade mutter libmutter-14-0 gnome-shell
```

---

## 10. Wayland vs X11: Complete Comparison for This Hardware

### 10.1 GFX Ring Pressure Comparison

| Operation | GNOME on X11 (AccelMethod glamor) | GNOME on X11 (AccelMethod none) | GNOME on Wayland |
|-----------|----------------------------------|--------------------------------|-----------------|
| Compositor frame | GL via Mutter/Cogl (GFX ring) | GL via Mutter/Cogl (GFX ring) | EGL via Mutter/Cogl (GFX ring) |
| 2D acceleration | GL via glamor (GFX ring) | CPU (ZERO ring) | N/A (no DDX) |
| Hardware cursor | X11 cursor plane (DCN) | X11 cursor plane (DCN) | DRM cursor plane (DCN) |
| Client app GL | DRI3 (GFX ring) | DRI3 (GFX ring) | EGL/DMA-BUF (GFX ring) |
| Idle desktop | 60 GL draws/sec (frame clock) | 60 GL draws/sec (frame clock) | 60 EGL draws/sec (frame clock) |

**Key insight:** In both X11 and Wayland, Mutter's compositor itself always uses the GFX ring for GL rendering. The difference is that X11 with `AccelMethod "none"` eliminates the ADDITIONAL 2D acceleration ring traffic. The compositor overhead is the same in both cases.

**True ring pressure reduction requires changing the compositor itself** (XFCE, Sway with pixman, or headless), not just the display server.

### 10.2 Recommendation

For this specific hardware, **X11 is marginally safer** because:
1. `AccelMethod "none"` eliminates 2D ring traffic (Wayland has no equivalent)
2. `xorg.conf` BusID gives deterministic GPU selection
3. No NVIDIA VRAM leak bug (Wayland-specific)
4. Better NVIDIA isolation via `ServerLayout`

**However**, post-firmware-fix, the difference is minimal. The compositor (Mutter) dominates ring traffic in both cases.

---

## 11. Complete Hardening Configuration

### 11.1 Environment Files

**`/etc/environment.d/90-mutter-kms.conf`**
```bash
MUTTER_DEBUG_KMS_THREAD_TYPE=user
```

**`/etc/environment.d/50-gpu-display.conf`**
```bash
DRI_PRIME=0
__GLX_VENDOR_LIBRARY_NAME=mesa
__GL_SYNC_TO_VBLANK=0
MUTTER_DEBUG_DISABLE_HW_CURSORS=1
```

### 11.2 GDM3 Configuration

**`/etc/gdm3/custom.conf`**
```ini
[daemon]
WaylandEnable=false

[security]

[xdmcp]

[chooser]

[debug]
```

### 11.3 gsettings (Run as the Desktop User)

```bash
#!/bin/bash
# GNOME Mutter Hardening for AMD Raphael iGPU

# Animations OFF (biggest single impact)
gsettings set org.gnome.desktop.interface enable-animations false

# Increase alive-check timeout for GPU recovery periods
gsettings set org.gnome.mutter check-alive-timeout 30000

# Disable edge tiling
gsettings set org.gnome.mutter edge-tiling false

# No experimental features during stabilization
gsettings set org.gnome.mutter experimental-features "[]"

# Disable text cursor blink (periodic recomposite source)
gsettings set org.gnome.desktop.interface cursor-blink false

# Prevent DPMS/idle state transitions
gsettings set org.gnome.desktop.session idle-delay 0
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-timeout 0
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'
gsettings set org.gnome.settings-daemon.plugins.power idle-dim false

# Disable Night Light (DCN color temperature changes)
gsettings set org.gnome.settings-daemon.plugins.color night-light-enabled false

# Disable hot corners
gsettings set org.gnome.desktop.interface enable-hot-corners false

# Disable notification banners (transient render events)
gsettings set org.gnome.desktop.notifications show-banners false

# Disable search providers
gsettings set org.gnome.desktop.search-providers disable-external true
```

### 11.4 Xorg Configuration (X11 Only)

**`/etc/X11/xorg.conf.d/20-amdgpu.conf`**
```
Section "Device"
    Identifier "AMD iGPU"
    Driver     "amdgpu"
    BusID      "PCI:108:0:0"
    Option     "AccelMethod" "none"
    Option     "TearFree"    "true"
    Option     "DRI"         "3"
EndSection
```

### 11.5 Priority-Ordered Application

| Priority | Setting | Impact | Where |
|----------|---------|--------|-------|
| 1 | `MUTTER_DEBUG_KMS_THREAD_TYPE=user` | Prevents SIGKILL crash | environment.d |
| 2 | `enable-animations false` | Halves idle GFX ring traffic | gsettings |
| 3 | `MUTTER_DEBUG_DISABLE_HW_CURSORS=1` | Eliminates cursor plane DCN interaction | environment.d |
| 4 | `WaylandEnable=false` | Enables AccelMethod control | gdm3/custom.conf |
| 5 | `AccelMethod "none"` | Eliminates 2D ring traffic | xorg.conf |
| 6 | `check-alive-timeout 30000` | Prevents false "not responding" dialogs | gsettings |
| 7 | `cursor-blink false` | Eliminates periodic recomposite | gsettings |
| 8 | `night-light-enabled false` | Eliminates DCN color changes | gsettings |
| 9 | `idle-delay 0` | Prevents DPMS state transitions | gsettings |
| 10 | Extensions: disable overview/animations | Reduces shell render complexity | gnome-extensions |

---

## 12. Alternative: LightDM Instead of GDM3

GDM3 runs its own gnome-shell instance for the login greeter, generating GFX ring pressure during the login screen. LightDM uses a lightweight GTK greeter with zero GL compositing.

```bash
sudo apt install lightdm lightdm-gtk-greeter
sudo dpkg-reconfigure lightdm
```

This eliminates the GDM greeter as a potential crash trigger during boot, while still allowing GNOME as the user session.

---

## Sources

- [GNOME Mutter debugging.md](https://github.com/GNOME/mutter/blob/main/doc/debugging.md) -- Official debug guide
- [GNOME Mutter src/core/util.c](https://github.com/GNOME/mutter/blob/main/src/core/util.c) -- Debug topic definitions
- [GNOME Mutter meta-backend-native.c](https://github.com/GNOME/mutter/blob/main/src/backends/native/meta-backend-native.c) -- Native backend env vars
- [LP #2034619](https://bugs.launchpad.net/ubuntu/+source/mutter/+bug/2034619) -- gnome-shell SIGKILL on AMD Ryzen
- [LP #2070437](https://bugs.launchpad.net/bugs/2070437) -- MUTTER_DEBUG_TRIPLE_BUFFERING issue
- [LP #2068598](https://bugs.launchpad.net/ubuntu/+source/mutter/+bug/2068598) -- Mutter 46.2 SRU for Ubuntu
- [Phoronix: GNOME Mutter KMS Thread](https://www.phoronix.com/news/GNOME-Mutter-KMS-Thread) -- KMS thread implementation
- [Phoronix: Mutter 46.2 Ubuntu](https://www.phoronix.com/news/GNOME-Mutter-46.2-Ubuntu) -- Ubuntu-specific SRU
- [Phoronix: Multi-GPU Copy Mode](https://www.phoronix.com/news/GNOME-Mutter-Debug-Copy-Mode) -- MUTTER_DEBUG_COPY_MODE
- [GNOME/mutter #2969](https://gitlab.gnome.org/GNOME/mutter/-/issues/2969) -- gnome-shell keeps dGPU awake
- [Clutter running docs](https://github.com/ebassi/clutter/blob/master/doc/reference/clutter/running-clutter.xml) -- Clutter env vars
- [GNOME Wiki Clutter Profiling](https://wiki.gnome.org/Projects/Clutter/Profiling) -- CLUTTER_PAINT / COGL_DEBUG
- [Mutter Reference Manual](https://github.com/gcampax/mutter/blob/master/doc/reference/running-mutter.xml) -- Legacy env vars
- [GDM ArchWiki](https://wiki.archlinux.org/title/GDM) -- GDM configuration reference
- [Just Perfection Extension](https://extensions.gnome.org/extension/3843/just-perfection/) -- GNOME Shell UI reduction
- [Disable Workspace Animation](https://extensions.gnome.org/extension/6694/disable-workspace-animation/) -- Workspace animation disable
- [Ubuntu Discourse: AMD GPU crash](https://discourse.ubuntu.com/t/amd-gpu-crashing-on-ubuntu-25-04-ring-gfx-0-0-0-timeout-and-reset-failure/62975) -- Ring timeout reports 2025-2026
- [Fedora Discussion: GNOME Shell crash](https://discussion.fedoraproject.org/t/gnome-shell-crash-and-gpu-ring-timeout-on-amd-gpu-when-using-brave-browser-fedora-42/149587) -- Ring timeout on Fedora 42
