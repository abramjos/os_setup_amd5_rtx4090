# GNOME Shell / Mutter on Ubuntu 24.04 LTS -- Comprehensive Comparison Page

**Desktop:** GNOME 46 (GNOME Shell 46.x, Mutter 46.2)
**OS:** Ubuntu 24.04 LTS (Noble Numbat)
**Variant:** G (`autoinstall-G-gnome-full.yaml`)
**Date:** 2026-03-29
**Purpose:** Full evaluation of GNOME as a compositor/desktop choice for this dual-GPU ML workstation (AMD Raphael iGPU + NVIDIA RTX 4090 headless)

---

## 1. Visual Appearance

### Stock Look: GNOME 46 on Ubuntu 24.04

Ubuntu 24.04 ships GNOME 46 with Ubuntu's own visual layer on top of upstream Adwaita:

| Element | Stock Configuration |
|---------|-------------------|
| **GTK Theme** | Yaru (Ubuntu's Adwaita derivative) -- rounded corners, subtle shadows, orange accents by default |
| **Icon Theme** | Yaru (full Suru-based icon set, integrated with Adwaita) |
| **Shell Theme** | Yaru Shell -- semi-transparent top panel, dark Activities overview |
| **Font** | Ubuntu 11pt (custom Ubuntu font family) |
| **Cursor** | Yaru cursor theme (DMZ variant) |
| **Dark Mode** | Full dark mode toggle in Settings > Appearance. Applies to GTK apps, GNOME Shell chrome, and libadwaita apps simultaneously. Ubuntu 24.04 defaults to light mode. |
| **Accent Colors** | Ubuntu 24.04 added a **color picker** for accent colors. Users can choose from ~10 preset colors (orange, bark, sage, olive, viridian, prussian green, blue, purple, magenta, red) that recolor interactive elements, selection highlights, and folder icons across the entire desktop. |
| **Wallpaper** | New GNOME 46 wallpapers with dynamic light/dark variants that change with the dark mode toggle. Ubuntu adds its own Noble Numbat wallpapers. |

### Visual Assessment

The stock Ubuntu 24.04 GNOME desktop is a **polished, modern** appearance:
- Clean top panel with system tray, clock, and Activities button
- No desktop icons by default (can be enabled via extension)
- Minimal chrome -- windows have thin title bars with close/maximize/minimize buttons (minimize hidden by default, add via gnome-tweaks)
- Window shadows and subtle animations give depth without clutter
- Dark mode is a true system-wide dark theme, not just a CSS hack

**Compared to other variants:**

| Variant | Visual Polish | Customization Depth |
|---------|--------------|-------------------|
| **G (GNOME)** | Highest -- Adwaita/Yaru is the most design-cohesive Linux DE | Medium -- requires extensions/tweaks for deeper changes |
| F (XFCE + Arc-Dark) | High with theming -- Arc-Dark + Papirus + Plank is visually competitive | High -- every panel, widget, theme element is configurable |
| D (labwc) | Functional -- waybar + GTK3 theming, no integrated design language | High -- everything is config files, but manual |
| E (Sway) | Minimal -- tiling WM aesthetic, waybar for status | Highest (config-file-driven) but requires manual work |

---

## 2. Window Management

### Activities Overview

The Activities overview is GNOME's central navigation paradigm. Triggered by:
- **Super** key (press and release)
- **Super + S** (explicit overview)
- **Hot corner** (move mouse to top-left corner, if enabled)
- Clicking the **Activities** button in the top panel

The overview shows:
- All open windows on the current workspace as live thumbnails (scaled, interactive)
- A search bar at the top (type-to-search for apps, files, settings, contacts, calculator)
- Workspace thumbnails on the right edge (dynamic workspaces -- new ones auto-created)
- The Dash at the bottom (favorited and running app launchers)

### Workspace Switching

| Method | Action |
|--------|--------|
| **Super + Page Up/Down** | Switch workspace up/down |
| **Super + Shift + Page Up/Down** | Move current window to another workspace |
| **Ctrl + Alt + Up/Down** | Switch workspace (alternative binding) |
| **Three-finger swipe** (touchpad) | Switch workspace |
| **Overview** | Click workspace thumbnail on right edge |

GNOME 46 uses **dynamic workspaces** by default: workspaces are created/removed as needed. Always one empty workspace available at the bottom. Configurable to fixed workspaces via Settings or gnome-tweaks.

### Window Tiling and Snapping

| Feature | GNOME 46 Stock | With Tiling Assistant Extension |
|---------|---------------|-------------------------------|
| **Half-screen tiling** | Yes -- drag to left/right edge or Super + Left/Right | Yes |
| **Quarter-screen tiling** | No | **Yes** -- Ubuntu 24.04 ships with Tiling Assistant |
| **Vertical half tiling** | No | Yes (Super + Up/Down to quarter) |
| **Gap between tiled windows** | No (edge to edge) | Configurable gaps |
| **Tiling suggestions** | No | Yes -- suggests tile for remaining space |

Ubuntu 24.04 ships with the **Tiling Assistant** extension pre-installed and enabled, adding quarter-screen tiling that stock GNOME lacks. This is a significant usability addition.

### Additional Window Management

| Feature | Behavior |
|---------|----------|
| **Super + Up** | Maximize window |
| **Super + Down** | Restore/unmaximize |
| **Super + H** | Minimize (hide) window |
| **Super + Tab** | Application switcher (grouped by app) |
| **Alt + Tab** | Window switcher (individual windows) |
| **Super + ` (backtick)** | Switch between windows of same app |
| **Double-click title bar** | Maximize/restore (configurable via gnome-tweaks) |
| **Middle-click title bar** | Lower window (configurable) |
| **Window previews** | Live thumbnails in Alt+Tab and overview |

---

## 3. Compositor: Mutter

### Architecture

Mutter is GNOME Shell's compositor, window manager, and display server. It uses:

- **Clutter** (forked into Mutter) -- scene graph and animation framework
- **Cogl** (forked into Mutter) -- OpenGL abstraction layer
- **EGL** on Wayland / **GLX** on X11 for GPU context

**All rendering goes through OpenGL.** There is no software rendering fallback for the compositor itself on Wayland. Every frame -- even when the desktop is idle -- requires GL draw calls submitted to the GPU's GFX ring.

### Triple Buffering (Ubuntu Patch)

Ubuntu 24.04 ships with **dynamic triple buffering** -- an Ubuntu-specific patch carried since Ubuntu 22.04, finally merged upstream in GNOME 48 / Mutter 48 (2025).

| Property | Detail |
|----------|--------|
| **What it does** | Adds a third render buffer so Mutter can start rendering the next frame before the current one finishes displaying |
| **Algorithm** | Latency-conscious: keeps rendering one frame ahead of scanout, schedules frames on an independent clock targeting optimal frame rate |
| **Default** | Enabled (`MUTTER_DEBUG_TRIPLE_BUFFERING=auto` -- dynamically switches between double and triple buffering) |
| **Impact** | Reduces frame drops when GPU latency spikes (relevant to Raphael DCN latency). Smoother animations. Increased VRAM usage by one framebuffer. |
| **Control** | `MUTTER_DEBUG_TRIPLE_BUFFERING=never` to disable, `always` to force |
| **Known issue** | LP #2070437: `always` mode causes issues on some systems. `auto` is recommended. |

### Hardware Cursors

By default, Mutter uses **hardware cursor planes** -- the cursor is composited directly by the display controller (DCN) as an overlay plane, bypassing the main compositing pipeline.

On Raphael DCN 3.1.5, hardware cursor updates interact with the DCN display controller. When DCN is stalled, hardware cursor operations become an additional DCN interaction vector.

**Mitigation:** `MUTTER_DEBUG_DISABLE_HW_CURSORS=1` forces software cursor rendering. Every cursor move triggers a partial recomposite through the GFX ring instead. This trades DCN interaction for additional GFX ring pressure, but eliminates one source of direct DCN writes.

### KMS Thread

Mutter 45+ introduced a **dedicated KMS page-flip thread** for lower latency. On Ubuntu 24.04 (Mutter 46.2), this thread runs at **real-time (SCHED_FIFO) priority** by default.

**The SIGKILL problem:** When amdgpu takes too long on a page flip (DCN latency on Raphael), the RT thread exceeds its scheduling deadline. The kernel's RT throttling (`/proc/sys/kernel/sched_rt_runtime_us`) sends SIGKILL to gnome-shell. This crashes the entire desktop session independently of any GFX ring timeout.

| Setting | Value | Effect |
|---------|-------|--------|
| `MUTTER_DEBUG_KMS_THREAD_TYPE=user` | Normal priority (SCHED_OTHER) | **CRITICAL -- prevents SIGKILL crash** |
| `MUTTER_DEBUG_KMS_THREAD_TYPE=kernel` | RT priority (SCHED_FIFO) | Default -- **dangerous on Raphael** |

**Fix timeline:** Mutter 48 (GNOME 48, Ubuntu 25.04+) changes the default from RT to high-priority non-RT. On Ubuntu 24.04 (Mutter 46.2), the `MUTTER_DEBUG_KMS_THREAD_TYPE=user` workaround is mandatory. See LP #2034619.

### Frame Clock and Idle Rendering

Mutter renders frames driven by the **per-CRTC frame clock** tied to the monitor's refresh rate:

| Monitor Refresh Rate | Minimum GFX Ring Submissions (idle desktop) |
|---------------------|---------------------------------------------|
| 60 Hz | 60 submissions/sec |
| 144 Hz | 144 submissions/sec |
| 240 Hz | 240 submissions/sec |

Even when the desktop is completely idle (no cursor movement, no animations, no window updates), Mutter submits GL draw calls at the monitor's refresh rate because:
1. **Cursor blink** in any focused text field triggers recomposite
2. **Clock tick** in the top panel triggers recomposite every second
3. **Notification timeouts** trigger recomposite
4. **Idle repaint cycle** -- Mutter does not skip frames entirely when desktop content is unchanged (unlike KWin's damage-driven approach)

**Mitigation:** Disabling animations (`enable-animations=false`), cursor blink (`cursor-blink=false`), and notification banners (`show-banners=false`) reduces but does not eliminate idle GFX ring submissions.

---

## 4. GNOME Shell Extensions

### Extension Manager

Ubuntu 24.04 ships with **Extension Manager** (`gnome-shell-extension-manager`), a GUI app for browsing, installing, and managing GNOME Shell extensions. Extensions can also be managed via:
- `gnome-extensions` CLI tool
- extensions.gnome.org website (with browser connector)
- dconf/gsettings for programmatic control

### Pre-installed Extensions (Ubuntu 24.04)

| Extension | Purpose | Status |
|-----------|---------|--------|
| **Ubuntu Dock** (Dash to Dock fork) | Persistent dock on screen edge | Enabled by default |
| **Ubuntu AppIndicators** | System tray / legacy tray icon support | Enabled by default |
| **Tiling Assistant** | Quarter-screen tiling, tile suggestions | Enabled by default |
| **Desktop Icons NG (DING)** | Desktop icons (files, folders on desktop) | Enabled by default |

### Popular Community Extensions

| Extension | GNOME 46 Compatible | What It Does | GPU Impact |
|-----------|---------------------|-------------|-----------|
| **Dash to Dock** | Yes | Transforms the dash into an always-visible dock. Ubuntu ships a fork ("Ubuntu Dock") pre-enabled. | Minimal -- dock repaints only on hover/launch |
| **AppIndicator / KStatusNotifierItem** | Yes | Adds system tray area for legacy apps (Slack, Discord, Dropbox, etc.) | Minimal -- icon updates only |
| **Blur My Shell** | Yes | Adds blur/transparency effects to panel, overview, dash, lock screen. Gaussian blur with configurable radius and brightness. | **INCREASES GPU LOAD** -- additional GL shader passes per frame. Avoid on Raphael during stabilization. |
| **Tiling Assistant** | Yes (pre-installed) | Quarter-screen tiling, tile editing mode, tile groups | Minimal -- layout changes only |
| **Just Perfection** | Yes | Selectively disable GNOME Shell UI elements (panel, search, dash, workspace thumbnails, app grid). **Every disabled element reduces compositor render work.** | **REDUCES GPU LOAD** |
| **Disable Workspace Animation** | Yes | Eliminates workspace switch animation | **REDUCES GPU LOAD** -- removes continuous GL draws during transitions |
| **No Overview at Startup** | Yes | Prevents Activities overview from showing at login | **REDUCES GPU LOAD** -- avoids burst of GL rendering at session start |
| **Caffeine** | Yes | Prevents screen blanking/locking | Neutral -- prevents DPMS state transitions (actually helpful for Raphael) |
| **Vitals** | Yes | System monitor (CPU, RAM, temp) in top bar | Minimal -- text updates |
| **GSConnect** | Yes | KDE Connect integration for phone/desktop sync | Minimal -- network operations |

### Extension Risk Assessment for This Hardware

| Category | Extensions | Recommendation |
|----------|-----------|----------------|
| **Safe** | Just Perfection, Caffeine, AppIndicator, Vitals, GSConnect, No Overview | Use freely |
| **Neutral** | Dash to Dock, Tiling Assistant, Desktop Icons NG | Pre-installed defaults are fine |
| **Risky** | Blur My Shell, Burn My Windows, Compiz-like effects | **AVOID** -- adds GL shader passes per frame |
| **Nuclear** | `disable-user-extensions=true` | Disables ALL extensions -- reduces gnome-shell complexity |

---

## 5. File Manager: Nautilus (GNOME Files)

### Version and Features

Ubuntu 24.04 ships Nautilus 46.x (renamed "Files" in GNOME branding).

| Feature | Detail |
|---------|--------|
| **View modes** | Icon (grid) view and List view. Instantaneous switching (no reload blink in GNOME 46). |
| **Search** | **Dual search modes** new in GNOME 46: (1) Global search across all indexed locations (tracker-miners), (2) "Search in folder" for current directory only. |
| **Path bar** | Click-to-edit: single click on the path bar enters text editing mode for manual path entry. Breadcrumb navigation for clicking into parent directories. |
| **Thumbnails** | Automatic thumbnail generation for images, PDFs, videos, fonts. Configurable size (small/standard/large). Thumbnails generated by `gnome-desktop-thumbnailer`. |
| **Bookmarks** | Sidebar shows bookmarks (user-defined), mounted volumes, network locations, recent files, starred files, and trash. Drag-and-drop to create bookmarks. |
| **Network browsing** | SMB/CIFS, FTP, SFTP, WebDAV, NFS, Google Drive (via GNOME Online Accounts), OneDrive (new in GNOME 46 via Microsoft Personal account). |
| **File operations** | Progress for active transfers moved to sidebar bottom in GNOME 46. Speed, time remaining, and per-file progress shown. |
| **FAT warnings** | New in GNOME 46: warns before copying files >4GB to FAT32 partitions. |
| **Batch rename** | Built-in batch rename with preview. |
| **Tabs** | Tab support (Ctrl+T for new tab). |
| **Permissions** | GUI for Unix permissions, owner, group. |
| **Archive support** | Open, extract, create archives (tar, zip, 7z via `file-roller`). |
| **Preferences** | Search field in preferences (new in GNOME 46). Detailed timestamp options. |

### Nautilus vs Thunar (Variant F)

| Feature | Nautilus (GNOME) | Thunar (XFCE) |
|---------|-----------------|---------------|
| **Search** | Powerful (tracker-indexed global + in-folder) | Basic (in-folder only, no indexing) |
| **Thumbnails** | Rich (images, PDFs, videos, fonts) | Basic (images, some media) |
| **Network** | Extensive (SMB, FTP, SFTP, WebDAV, GDrive, OneDrive) | Basic (SMB, FTP, SFTP via gvfs) |
| **Tabs** | Yes | Yes |
| **Split pane** | No (use tabs or two windows) | No (plugin available) |
| **Custom actions** | No (use Nautilus scripts in `~/.local/share/nautilus/scripts/`) | Yes (Thunar Custom Actions -- very flexible) |
| **Resource usage** | Higher (~80-120MB) | Lower (~30-50MB) |
| **Startup time** | ~1-2s (tracker indexing overhead) | ~0.3-0.5s |

---

## 6. Terminal Emulators

### gnome-terminal (Default on Ubuntu 24.04)

Ubuntu 24.04 ships **gnome-terminal** (not gnome-console/kgx) as the default terminal.

| Feature | Detail |
|---------|--------|
| **Profiles** | Multiple named profiles with independent settings (colors, font, scrollback, cursor shape, encoding) |
| **Tabs** | Full tab support (Ctrl+Shift+T) with tab reordering |
| **Colors** | Built-in color schemes (Tango, Solarized, etc.) + custom 16-color palette |
| **Font** | Configurable font and size per profile |
| **Scrollback** | Configurable line limit (default 10,000) or unlimited |
| **Transparency** | Background transparency slider (compositing required) |
| **Keyboard shortcuts** | Fully customizable keybindings |
| **Hyperlinks** | Click-to-open URLs, file paths |
| **Search** | Ctrl+Shift+F text search within scrollback |
| **Copy/Paste** | Ctrl+Shift+C/V (standard terminal convention) |
| **Shell integration** | VTE-based (Virtual Terminal Emulator), supports `__vte_prompt_command` for semantic prompts |
| **Split panes** | No (use tmux/screen for splits) |

### gnome-console (kgx)

GNOME Console is the upstream GNOME project's intended replacement for gnome-terminal. It is **not installed by default** on Ubuntu 24.04 but is available via `apt install gnome-console`.

| Comparison | gnome-terminal | gnome-console (kgx) |
|-----------|---------------|---------------------|
| **Profiles** | Yes (multiple) | No (single config) |
| **Color schemes** | Many built-in + custom | Limited |
| **Tabs** | Yes | Yes |
| **Transparency** | Yes | Yes (libadwaita) |
| **Configuration depth** | Deep (dconf keys) | Minimal |
| **Target user** | Power users | Casual users |
| **Design language** | GTK3 + VTE | libadwaita + VTE |

**Recommendation for ML workstation:** gnome-terminal is the better choice due to profile support and configuration depth. Most ML users will use tmux/screen inside the terminal anyway.

---

## 7. Notifications

### Built-in Notification Center

GNOME 46's notification system:

| Feature | Detail |
|---------|--------|
| **Toast notifications** | Pop up from top center of screen. Auto-dismiss after timeout. |
| **Collapsible content** | New in GNOME 46: notifications with action buttons or long content can be collapsed/expanded |
| **Message tray** | Click date/time in top panel to open the notification/calendar tray. Shows pending notifications grouped by app. |
| **Do Not Disturb** | Toggle in notification tray. Suppresses all visual/audio notifications. Apps can still send notifications (queued in tray). |
| **App headers** | Each notification shows app name and symbolic icon for identification |
| **Actions** | In-notification action buttons (Reply, Mark as Read, etc.) |
| **Persistence** | Notifications persist in the tray until dismissed or the session ends |
| **Sound** | Notification sounds via GNOME settings (can be disabled) |
| **Per-app control** | Settings > Notifications allows per-app enable/disable, banner/list control, sound toggle |

### GPU Impact of Notifications

Each notification toast triggers a **recomposite** of the GNOME Shell overlay. On Raphael:
- Notification appears: partial recomposite (GFX ring submission)
- Notification animates in: multiple frames of recomposite (if animations enabled)
- Notification auto-dismisses: another animated recomposite

**Mitigation:** `gsettings set org.gnome.desktop.notifications show-banners false` disables visual banners entirely. Notifications still accumulate in the tray but do not trigger recomposites.

---

## 8. Settings: gnome-control-center

### Comprehensive Settings GUI

GNOME Settings (`gnome-control-center`) provides a centralized GUI for all system configuration:

| Section | What It Controls |
|---------|-----------------|
| **Wi-Fi / Network** | Network connections, VPN, proxy, wired |
| **Bluetooth** | Bluetooth devices |
| **Background** | Wallpaper (with light/dark variants) |
| **Appearance** | Light/dark mode, accent color, dock position/behavior |
| **Notifications** | Per-app notification control, DND |
| **Search** | Search providers (apps, files, calculator, etc.) |
| **Multitasking** | Hot corners, active screen edges, fixed vs dynamic workspaces, multi-monitor workspace behavior |
| **Apps** | Default applications, installed snap/flatpak management |
| **Privacy** | Screen lock, location, file history, diagnostics |
| **Online Accounts** | Google, Microsoft, Nextcloud, IMAP -- integrates with Nautilus, Calendar, Contacts |
| **Sharing** | Remote Desktop (RDP), Screen Sharing, SSH (new in GNOME 46) |
| **Sound** | Input/output devices, volume, alert sounds |
| **Power** | Suspend behavior, power profiles (performance/balanced/saver), screen blank |
| **Displays** | Resolution, refresh rate, scaling, arrangement, night light |
| **Mouse & Touchpad** | Speed, acceleration, natural scrolling, tap-to-click |
| **Keyboard** | Layouts, shortcuts, input sources |
| **Printers** | Printer management |
| **Removable Media** | Auto-mount behavior |
| **Color** | Color profiles for displays |
| **Accessibility** | Vision, hearing, typing, pointing/clicking |
| **Users** | User accounts, parental controls |
| **System** | Region & Language, Date & Time, About (new consolidated panel in GNOME 46) |

**GNOME 46 Settings Reorganization:** The new **System** panel consolidates Region & Language, Time & Date, Users, Remote Desktop, and Secure Shell settings that were previously scattered across multiple panels.

---

## 9. Display Server: Wayland vs X11

### Default: Wayland

Ubuntu 24.04 defaults to **GNOME on Wayland** with GDM3 (`WaylandEnable=true` by default).

| Aspect | GNOME on Wayland | GNOME on X11 |
|--------|-----------------|-------------|
| **Session selector** | "Ubuntu" (Wayland) at GDM login | "Ubuntu on Xorg" at GDM login |
| **Display server** | Mutter IS the display server | Xorg server + Mutter as compositor |
| **Fractional scaling** | Native support (experimental, enable via `scale-monitor-framebuffer`) | Poor (xrandr hacks, blurry) |
| **VRR / FreeSync** | Experimental support (GNOME 46) | Not available |
| **Screen sharing** | PipeWire + xdg-desktop-portal | X11 screen capture (any app can grab) |
| **Security** | Apps cannot spy on each other's windows | Any X11 client can read any window content |
| **Xwayland** | Runs for legacy X11 apps (transparent) | N/A (native X11) |
| **NVIDIA isolation** | Mutter may probe NVIDIA DRM device at startup (GNOME/mutter #2969) | Clean isolation via xorg.conf BusID |
| **AccelMethod control** | N/A (no DDX driver) | `AccelMethod "none"` eliminates 2D ring traffic |
| **GFX ring pressure** | Higher (no AccelMethod control, EGL direct on DRM device) | Lower with `AccelMethod "none"` (CPU 2D accel) |

### Recommendation for This Hardware

**Post-firmware-fix:** X11 (`WaylandEnable=false`) is marginally safer because:
1. `AccelMethod "none"` eliminates 2D ring traffic (no Wayland equivalent)
2. `xorg.conf` BusID gives deterministic GPU selection
3. No NVIDIA VRAM leak bug (Wayland-specific, NVIDIA egl-wayland #185)
4. Better NVIDIA isolation via `ServerLayout`

**However:** The compositor (Mutter) dominates ring traffic in both X11 and Wayland. The display server choice is a secondary factor. See `GNOME-MUTTER-HARDENING.md` section 10 for the complete comparison table.

---

## 10. Resource Usage

### RAM Footprint

| Scenario | RAM Usage | Notes |
|----------|----------|-------|
| **Idle desktop, stock Ubuntu 24.04** | ~900MB -- 1.2GB | gnome-shell (~300-500MB), GDM3 greeter (~100-200MB overhead), tracker-miner, evolution-data-server, gsd-* daemons |
| **Idle, after disabling gnome-software autostart** | ~800MB -- 1.0GB | gnome-software daemon uses ~100-200MB |
| **Idle, on system with 96GB RAM** | ~1.5-1.6GB | Linux dynamically allocates more cache/buffers on high-RAM systems |
| **With browser (5 tabs)** | ~2.0-2.5GB | Browser dominates |
| **Heavy ML workflow** | ~3-5GB+ | Python, Docker, model loading dominate; DE overhead becomes negligible |

### Comparison with Other Variants

| Variant | Idle RAM | CPU (idle) | GPU (idle) |
|---------|---------|-----------|-----------|
| **G (GNOME)** | **800MB -- 1.2GB** | 2-5% (gnome-shell, tracker, gsd-*) | **Continuous GL** (60 draws/sec minimum) |
| F (XFCE) | 400-600MB | 1-2% (xfwm4, xfce4-panel) | Zero (XRender is CPU-side) |
| D (labwc + pixman) | 150-250MB | 1-3% (pixman rendering) | **Zero** (no GPU compositing) |
| E (Sway + pixman) | 80-150MB | <1% (nothing renders when idle) | **Zero** (no GPU compositing) |

### Background Processes

GNOME runs significantly more background services than lightweight alternatives:

| Process | Purpose | RAM | Can Disable? |
|---------|---------|-----|-------------|
| `gnome-shell` | Compositor + shell UI | 300-500MB | No (IS the desktop) |
| `tracker-miner-fs-3` | File indexing for search | 50-150MB | Yes (`tracker3 daemon -k`) |
| `evolution-data-server` | Calendar/contacts backend | 30-60MB | Yes (but breaks calendar) |
| `gsd-color` | Color management / night light | 10-20MB | Yes via gsettings |
| `gsd-power` | Power management | 10-20MB | Not recommended |
| `gsd-media-keys` | Media key handling | 10-15MB | Not recommended |
| `gsd-keyboard` | Keyboard layout management | 5-10MB | Not recommended |
| `gsd-xsettings` | X settings bridge (X11) | 5-10MB | N/A on Wayland |
| `gnome-software` | App store daemon | 100-200MB | Yes (disable autostart) |
| `gvfsd` | Virtual filesystem daemon | 10-30MB | Not recommended |
| `xdg-desktop-portal-gnome` | Portal service (screen sharing, file chooser) | 20-40MB | Not recommended |

**Total overhead vs lightweight DE:** GNOME adds approximately **400-700MB** more RAM usage compared to XFCE, and **700-1000MB** more compared to Sway/labwc with pixman.

On a system with 64GB DDR5, the absolute RAM difference is negligible for ML workloads. The concern is **GPU usage**, not RAM.

---

## 11. GPU Usage: The Critical Risk Factor

### Why Mutter's OpenGL Compositing Matters for This Hardware

This is the **single most important section** for evaluating GNOME as a compositor choice on this workstation.

#### The GFX Ring Pressure Model

Mutter submits OpenGL draw calls to the AMD iGPU's `gfx_0.0.0` ring buffer for EVERY composited frame. The Command Processor (CP) reads these commands and dispatches them to GPU pipeline stages. On Raphael's RDNA2 iGPU (2 CUs only):

| Event | GFX Ring Activity |
|-------|-------------------|
| **Idle desktop (60Hz)** | 60 GL draw submissions/sec (frame clock driven) |
| **Cursor movement** | Additional partial recomposite per cursor position change |
| **Window drag** | Full recomposite every frame (all window surfaces redrawn) |
| **Window animation** | Continuous full recomposite (open/close/minimize effects) |
| **Workspace switch** | Burst of full recomposites (workspace transition animation) |
| **Overview open/close** | Burst of recomposites (thumbnail generation + animation) |
| **Notification toast** | Partial recomposite per animation frame |
| **Clock tick** | 1 recomposite per second (top panel redraw) |

#### The Crash Mechanism

When the DCN display controller is stalled (optc31_disable_crtc REG_WAIT timeout from outdated DMCUB firmware):

1. Mutter submits GL draw call to GFX ring
2. GFX engine attempts to render to display buffer
3. DCN stall prevents framebuffer scanout completion
4. GFX ring job times out after `lockup_timeout` ms (default 10,000)
5. amdgpu triggers MODE2 reset (resets GFX + SDMA only, NOT DCN)
6. DCN is still stalled (MODE2 does not reset it)
7. Mutter immediately submits new GL draw call (frame clock keeps ticking)
8. Go to step 2 -- infinite crash loop

**gnome-shell is named in EVERY ring timeout in the 20-boot diagnostic data.** It is always the process triggering the crash because it is always the process submitting GL commands.

#### Comparison: GFX Ring Pressure by Compositor

| Compositor | GFX Ring (idle) | GFX Ring (active) | Crash Risk |
|-----------|----------------|-------------------|-----------|
| **Mutter (GNOME)** | 60/sec continuous | 60+/sec continuous | **HIGHEST** |
| KWin (KDE Plasma) | Near-zero (damage-driven) | On-demand | MEDIUM |
| xfwm4 XRender (XFCE F) | Zero (CPU-side) | Zero (CPU-side) | **ZERO** for compositing |
| labwc + pixman (D) | Zero (CPU-side) | Zero (CPU-side) | **ZERO** |
| Sway + pixman (E) | Zero (no render when idle) | Zero (CPU-side) | **ZERO** |

**Key insight:** Mutter is the ONLY compositor among the tested variants that generates continuous GFX ring submissions even when the desktop is idle. This makes it fundamentally the highest-risk choice for hardware with a known DCN stall issue.

---

## 12. Customization

### Available Customization Tools

| Tool | What It Controls | Depth |
|------|-----------------|-------|
| **Settings** (gnome-control-center) | Appearance, behavior, peripherals, networks | Surface level -- the "safe" settings |
| **gnome-tweaks** | Fonts, titlebar buttons, window behavior, extensions, startup apps, top bar | Intermediate -- exposes settings GNOME hides |
| **dconf-editor** | Every GSettings/dconf key in the system | Deep -- can break things if misused |
| **gsettings CLI** | Scriptable dconf access | Same depth as dconf-editor, scriptable |
| **Extensions** | Shell behavior, UI elements, visual effects | Extends GNOME's functionality significantly |
| **CSS theming** | `~/.config/gtk-4.0/gtk.css` for GTK4, `~/.config/gtk-3.0/gtk.css` for GTK3 | Pixel-level visual customization |

### Customization Limitations vs Other DEs

| Capability | GNOME | XFCE | KDE Plasma |
|-----------|-------|------|-----------|
| **Panel position** | Top only (stock). Extensions can add bottom panel. | Fully configurable (top, bottom, left, right, multiple panels) | Fully configurable |
| **Panel contents** | Limited (clock, tray, activities). Extensions add more. | Fully configurable (any widget anywhere) | Fully configurable (600+ widgets) |
| **Desktop icons** | Requires extension (DING) | Built-in | Built-in |
| **Window buttons** | Left or right (gnome-tweaks). Minimize hidden by default. | Fully configurable (any button, any position) | Fully configurable |
| **Themes** | GTK theme + Shell theme (limited by libadwaita apps ignoring non-Adwaita themes) | Full theme control (GTK + xfwm4 + icon + cursor) | Full theme + color scheme + Plasma Style |
| **Tiling** | Basic half-tile (+ Tiling Assistant extension) | Manual resize only (+ extensions) | Built-in basic tiling (+ Bismuth/Krohnkite) |
| **Global menu** | Not available | Not available | Available (for KDE/Qt apps) |
| **System tray** | Extension required (AppIndicator) | Built-in | Built-in |

**Bottom line:** GNOME is the most opinionated and least customizable of the major DEs out-of-the-box. Extensions compensate significantly but introduce complexity, potential breakage on GNOME upgrades, and additional gnome-shell render work. XFCE and KDE offer deeper stock customization without extensions.

---

## 13. Keyboard Shortcuts

### Default Keyboard Shortcuts (GNOME 46 on Ubuntu 24.04)

#### Navigation
| Shortcut | Action |
|----------|--------|
| **Super** | Open/close Activities overview |
| **Super + A** | Open application grid ("app launcher") |
| **Super + S** | Open Activities overview (explicit) |
| **Super + L** | Lock screen |
| **Super + D** | Show desktop (minimize all windows) |
| **Super + Tab** | Application switcher |
| **Alt + Tab** | Window switcher |
| **Super + ` (backtick)** | Switch windows within same application |

#### Window Management
| Shortcut | Action |
|----------|--------|
| **Super + Up** | Maximize window |
| **Super + Down** | Restore/unmaximize |
| **Super + Left/Right** | Tile window to left/right half |
| **Super + H** | Minimize (hide) window |
| **Super + Shift + Page Up/Down** | Move window to workspace above/below |
| **Alt + F4** | Close window |
| **Alt + F7** | Move window (keyboard) |
| **Alt + F8** | Resize window (keyboard) |

#### Workspaces
| Shortcut | Action |
|----------|--------|
| **Super + Page Up/Down** | Switch workspace |
| **Ctrl + Alt + Up/Down** | Switch workspace (alternative) |
| **Super + Home/End** | First/last workspace |

#### System
| Shortcut | Action |
|----------|--------|
| **Ctrl + Alt + T** | Open terminal (Ubuntu default) |
| **Ctrl + Alt + Delete** | Log out |
| **Super + Ctrl + 1-9** | Launch app from dash position 1-9 (new in GNOME 46) |
| **Print** | Screenshot (full screen) |
| **Shift + Print** | Screenshot (selection) |
| **Alt + Print** | Screenshot (active window) |

#### Customization
Shortcuts are customizable via **Settings > Keyboard > Keyboard Shortcuts**. The overview search (type in Activities view) acts as a universal launcher and calculator.

---

## 14. Multi-Monitor Support

### Configuration

GNOME has **excellent multi-monitor support**, configured through Settings > Displays:

| Feature | Support |
|---------|---------|
| **Display arrangement** | Drag-and-drop monitor positioning |
| **Primary display** | Designate any monitor as primary (top panel, notifications appear here) |
| **Resolution per monitor** | Independent resolution per display |
| **Refresh rate per monitor** | Independent refresh rate per display |
| **Scaling per monitor** | Integer scaling per monitor (100%, 200%). Fractional via experimental feature. |
| **Rotation** | 0, 90, 180, 270 degrees per monitor |
| **Mirror mode** | Clone display across monitors |
| **Night light** | Applies to all monitors simultaneously |

### Workspace Behavior

| Setting | Behavior |
|---------|----------|
| **Workspaces on primary only** (default) | Only the primary monitor switches workspaces. Secondary monitors show their own fixed set of windows. |
| **Workspaces on all displays** | All monitors switch workspaces together. |

Configurable via Settings > Multitasking > Multi-Monitor.

### Fractional Scaling (Wayland Only)

```bash
# Enable experimental fractional scaling
gsettings set org.gnome.mutter experimental-features "['scale-monitor-framebuffer']"
```

This enables 125%, 150%, 175% scaling options in Settings > Displays. However:
- **Increases GPU rendering workload** (renders at higher resolution, then scales)
- **XWayland apps may appear blurry** (GNOME 46 does NOT include the XWayland native scaling improvement; that arrived in GNOME 47)
- **Avoid during hardware stabilization** -- increases GFX ring pressure

### Multi-Monitor and Raphael iGPU

On Raphael's 2-CU RDNA2 iGPU, each additional monitor adds:
- Another CRTC/frame clock driving GFX ring submissions
- Additional compositing area per frame
- More DCN hardware usage (each monitor uses an OTG/OPTC instance)

For this workstation (single display on iGPU, RTX 4090 headless), multi-monitor on the iGPU should be limited during stabilization to minimize DCN and GFX ring pressure.

---

## 15. Accessibility

### GNOME's Accessibility Stack

GNOME has the **best accessibility support among Linux desktop environments**, primarily through the AT-SPI2 (Assistive Technology Service Provider Interface) framework.

| Feature | Detail |
|---------|--------|
| **Orca Screen Reader** | Pre-installed on Ubuntu 24.04. Enable with **Super + Alt + S** (works at login screen too). Reads all UI elements, supports Braille displays. |
| **On-Screen Keyboard** | Built-in. Auto-appears on Wayland when a text field is focused on a touchscreen device. Can be manually enabled via Accessibility settings. |
| **High Contrast** | Accessibility > Seeing > High Contrast. System-wide high contrast theme. |
| **Large Text** | Accessibility > Seeing > Large Text. Increases default font size by 1.5x. |
| **Zoom (Screen Magnifier)** | Accessibility > Seeing > Zoom. Configurable magnification with crosshair lines, lens mode, or full-screen zoom. New in GNOME 46: toggle button on/off shapes option. |
| **Cursor Size** | Accessibility > Seeing > Cursor Size. Multiple sizes from default to extra-large. |
| **Reduce Animation** | Accessibility > Seeing > Reduce Animation. Functionally equivalent to `enable-animations=false`. |
| **Sound Keys** | Accessibility > Hearing > Visual Alerts. Flash screen on system bell. |
| **Sticky Keys** | Accessibility > Typing. Modifier keys (Shift, Ctrl, Alt) can be pressed sequentially instead of simultaneously. |
| **Slow Keys** | Accessibility > Typing. Keys must be held for a duration before registering. |
| **Bounce Keys** | Accessibility > Typing. Ignores rapid repeated keystrokes. |
| **Mouse Keys** | Accessibility > Pointing & Clicking. Move cursor with numpad keys. |
| **Click Assist** | Accessibility > Pointing & Clicking. Simulated secondary click (dwell click, gesture click). |
| **Repeat Keys** | Accessibility > Typing. Configurable key repeat delay and speed. |

### Accessibility Comparison

| Feature | GNOME | XFCE | Sway/labwc |
|---------|-------|------|-----------|
| **Screen reader** | Orca (full, pre-installed) | Orca (installable, less integrated) | Orca (limited Wayland support) |
| **On-screen keyboard** | Built-in, auto-show | Requires separate app (onboard/florence) | wvkbd or squeekboard |
| **High contrast** | System-wide theme | Theme-based | Manual CSS |
| **Zoom/magnifier** | Built-in, configurable | Separate app | Not available |
| **AT-SPI2 integration** | Full (designed for it) | Partial | Minimal |
| **WCAG compliance** | Best-effort | Limited | None |

**GNOME is the only Linux DE where accessibility is a first-class, integrated feature rather than an afterthought.** For users who depend on screen readers, magnification, or alternative input methods, GNOME is effectively the only viable option.

### Ubuntu 24.04 Accessibility Notes

- The Orca screen reader works at the GDM login screen (Super + Alt + S)
- On Wayland, the CapsLock Orca modifier is less reliable than on X11 (Ubuntu-specific issue). Workaround: switch to X11 session or use Insert as the Orca modifier.
- The accessibility stack does not significantly affect GPU load (Orca is text-based, magnifier uses a shader overlay)

---

## 16. Mutter-Specific Risks for This Hardware

### Summary of All Mitigations

This section consolidates all Mutter-specific risks and mitigations relevant to the AMD Raphael iGPU + NVIDIA RTX 4090 dual-GPU configuration.

#### Critical Mitigations (Applied in Variant G)

| Mitigation | Setting | What It Prevents | Where Applied |
|-----------|---------|-----------------|---------------|
| **KMS thread type** | `MUTTER_DEBUG_KMS_THREAD_TYPE=user` | SIGKILL from RT thread deadline miss | `/etc/environment.d/90-mutter-kms.conf` |
| **Disable HW cursors** | `MUTTER_DEBUG_DISABLE_HW_CURSORS=1` | Hardware cursor plane DCN interaction | `/etc/environment.d/50-gpu-display.conf` |
| **Disable animations** | `enable-animations=false` | Continuous GL draws during transitions | dconf `00-gnome-hardening` |
| **Increase alive timeout** | `check-alive-timeout=30000` | "App not responding" dialogs during GPU recovery | dconf `00-gnome-hardening` |
| **Disable cursor blink** | `cursor-blink=false` | Periodic recomposite source | dconf `00-gnome-hardening` |
| **Disable notifications** | `show-banners=false` | Transient recomposite events | dconf `00-gnome-hardening` |
| **Disable night light** | `night-light-enabled=false` | DCN color temperature changes | dconf `00-gnome-hardening` |
| **Lockup timeout** | `amdgpu.lockup_timeout=30000` | Premature ring timeout during slow DMCUB init | GRUB cmdline |

#### Additional Mitigations (Available, Not Applied by Default in Variant G)

| Mitigation | Setting | Trade-off |
|-----------|---------|-----------|
| **Force legacy KMS** | `MUTTER_DEBUG_FORCE_KMS_MODE=simple` | Loses atomic modesetting, VRR. Use if atomic path triggers DCN bugs. |
| **Reduce FPS target** | `CLUTTER_DEFAULT_FPS=30` | Halves GFX ring submissions but makes desktop feel sluggish |
| **Disable mipmaps** | `META_DISABLE_MIPMAPS=1` | Minor visual degradation when scaling windows |
| **Force double buffering** | `MUTTER_DEBUG_TRIPLE_BUFFERING=never` | Fewer in-flight frames, but more frame drops during DCN latency spikes |
| **Software rendering** | `LIBGL_ALWAYS_SOFTWARE=1` | Zero GFX ring but extremely slow gnome-shell. Diagnostic use only. |
| **X11 with AccelMethod none** | `WaylandEnable=false` + xorg.conf | Eliminates 2D ring traffic, adds deterministic GPU selection |
| **Disable all extensions** | `disable-user-extensions=true` | Reduces gnome-shell complexity, loses Ubuntu Dock/AppIndicator/Tiling |
| **Use LightDM instead of GDM3** | Install lightdm, reconfigure | Eliminates GDM greeter gnome-shell instance (zero GL at login) |

#### Risk Severity Matrix

| Risk | Severity | Likelihood (Post-Firmware-Fix) | Mitigation Status |
|------|----------|-------------------------------|-------------------|
| **GFX ring timeout from compositing** | CRITICAL | LOW (with firmware >= 0.0.224.0) | Lockup timeout increased to 30s |
| **SIGKILL from RT KMS thread** | CRITICAL | MEDIUM (any DCN latency spike) | `KMS_THREAD_TYPE=user` applied |
| **Crash loop (ring timeout + MODE2 reset)** | CRITICAL | LOW (firmware fixes DCN stall) | Firmware update is primary fix |
| **HW cursor DCN interaction** | MEDIUM | LOW | `DISABLE_HW_CURSORS=1` applied |
| **Animation-driven ring pressure** | MEDIUM | LOW | Animations disabled |
| **GDM greeter crash** | MEDIUM | LOW | KMS thread fix covers GDM too |
| **NVIDIA DRM probe** | LOW | LOW | Wayland-specific; X11 avoids it |
| **VRAM leak (Wayland + NVIDIA)** | LOW | LOW | X11 avoids it entirely |

### Detailed Reference

For the complete catalog of every MUTTER_DEBUG_*, CLUTTER_*, COGL_*, dconf/gsettings, and GDM3 configuration option, see `/GNOME-MUTTER-HARDENING.md`.

---

## 17. Comparison Positioning

### GNOME Is Best For Users Who Want...

| Strength | Detail |
|----------|--------|
| **A full-featured modern desktop** | GNOME provides the most complete, integrated, and polished desktop experience on Linux. Settings, file manager, notifications, online accounts, screen sharing -- all work together seamlessly. |
| **Accessibility** | The only Linux DE with genuinely usable screen reader, zoom, on-screen keyboard, and AT-SPI2 integration. Non-negotiable for visually or motor-impaired users. |
| **Ubuntu's "blessed path"** | GNOME is Ubuntu's default. Every Ubuntu guide, every Ask Ubuntu answer, every third-party tutorial assumes GNOME. Maximum community support. |
| **Extension ecosystem** | Hundreds of extensions for every conceivable customization. Tiling, dock, system monitor, blur, window management, workflow automation. |
| **Wayland-native experience** | Best Wayland integration of any DE (Mutter IS the Wayland compositor). Fractional scaling, touch gestures, modern protocols. |
| **Consistent design language** | libadwaita ensures GTK4 apps look consistent. Accent colors, dark mode, and visual coherence across apps. |
| **Touchscreen support** | Gestures, on-screen keyboard, responsive UI -- GNOME is the best Linux DE for touch/hybrid devices. |

### Risks for This Specific Hardware

| Risk | Detail |
|------|--------|
| **Continuous GFX ring pressure** | Mutter generates 60+ GL submissions/sec even when idle. The only compositor variant that does this. Pixman variants (D, E) generate zero. |
| **RAM overhead** | 800MB-1.2GB idle vs 150-600MB for alternatives. Not critical on 64GB system, but symptomatic of the broader resource cost. |
| **Mutter SIGKILL bug** | RT KMS thread can crash gnome-shell on any DCN latency spike. Workaround required (`KMS_THREAD_TYPE=user`). Fixed in Mutter 48 (Ubuntu 25.04+), but not in Ubuntu 24.04's Mutter 46. |
| **No software rendering fallback** | Unlike KWin (QPainter) or Sway/labwc (pixman), Mutter on Wayland has NO way to avoid the GFX ring for compositing. `LIBGL_ALWAYS_SOFTWARE=1` makes it unusably slow. |
| **GDM greeter also runs gnome-shell** | Two gnome-shell instances (greeter + session) both generating GFX ring pressure. LightDM avoids this. |
| **Customization limitations** | Less configurable than XFCE/KDE without extensions. Extensions add complexity and potential breakage. |
| **libadwaita theme restrictions** | Modern GTK4/libadwaita apps ignore custom GTK themes, limiting visual customization. |

### Decision Matrix: When to Choose Each Variant

| Choose Variant... | When... |
|-------------------|---------|
| **G (GNOME)** | Firmware fix is confirmed stable (10+ clean boots on Variant B). User needs full desktop with accessibility, online accounts, extensions, touchscreen, or familiar Ubuntu experience. Accept GFX ring risk with mitigations applied. |
| **F (XFCE)** | Want a familiar desktop with zero GFX ring risk from compositing. Good visual polish with Arc-Dark + Papirus + Plank. Best balance of appearance vs stability. |
| **D (labwc)** | Want a modern Wayland stacking WM with zero GFX ring risk. Comfortable with manual configuration. |
| **E (Sway)** | Want minimum possible resource usage with zero GFX ring risk. Comfortable with tiling WM workflow and config files. |

### Final Assessment

**GNOME (Variant G) is the highest-risk, highest-reward compositor choice for this hardware.** It provides the best desktop experience on Linux but is the only option that generates continuous GFX ring pressure from idle compositing.

The firmware fix (DMCUB >= 0.0.224.0) is the critical prerequisite. With firmware fixed:
- The DCN stall that triggers the crash loop should not occur
- Mutter's continuous GFX ring submissions become benign (no stalled pipeline to interact with)
- The SIGKILL mitigation (`KMS_THREAD_TYPE=user`) handles the remaining Mutter-specific risk

**Without the firmware fix, GNOME WILL crash. With the firmware fix and mitigations applied, GNOME should be stable.** Variants D/E/F serve as proven fallbacks if GNOME still exhibits instability post-firmware-fix.

---

## Sources

### GNOME 46 / Ubuntu 24.04 Features
- [Ubuntu Desktop 24.04 LTS: Noble Numbat Deep Dive](https://ubuntu.com/blog/ubuntu-desktop-24-04-noble-numbat-deep-dive) -- Official Ubuntu blog
- [GNOME 46: The Best New Features](https://www.omgubuntu.co.uk/2024/03/gnome-46-new-features) -- OMG! Ubuntu feature overview
- [Ubuntu 24.04 LTS "Noble Numbat": Best New Features](https://www.debugpoint.com/ubuntu-24-04-features/) -- debugpoint
- [Ubuntu 24.04 LTS Released, This Is What's New](https://linuxiac.com/ubuntu-24-04-lts-noble-numbat/) -- Linuxiac
- [A Look at Ubuntu Desktop LTS 24.04](https://lwn.net/Articles/971143/) -- LWN.net

### Performance and Mutter
- [Ubuntu 24.04 LTS Extra GNOME Performance Optimizations](https://www.phoronix.com/news/Ubuntu-24.04-More-GNOME-Perf) -- Phoronix
- [Triple Buffering, A Debrief](https://discourse.ubuntu.com/t/triple-buffering-a-debrief/56314) -- Ubuntu Discourse
- [Mutter Triple Buffering Merged to GNOME 48](https://news.ycombinator.com/item?id=43371781) -- Hacker News discussion
- [Ensuring Steady Frame Rates with GPU-Intensive Clients](https://blogs.gnome.org/shell-dev/2023/03/30/ensuring-steady-frame-rates-with-gpu-intensive-clients/) -- GNOME Shell & Mutter blog
- [Desktop Environments Resource Usage Comparison](https://vermaden.wordpress.com/2022/07/12/desktop-environments-resource-usage-comparison/) -- vermaden

### Mutter AMD Issues
- [LP #2034619: gnome-shell SIGKILL on AMD Ryzen](https://bugs.launchpad.net/bugs/2034619) -- Ubuntu Launchpad
- [LP #2101148: amdgpu reset causes GNOME crash](https://bugs.launchpad.net/ubuntu/+source/linux/+bug/2101148) -- Ubuntu Launchpad
- [LP #2062377: gnome-shell crashes on Xorg with legacy monitor](https://bugs.launchpad.net/ubuntu/+source/mutter/+bug/2062377) -- Ubuntu Launchpad
- [AMD GPU crashing on Ubuntu 25.04 ring timeout](https://discourse.ubuntu.com/t/amd-gpu-crashing-on-ubuntu-25-04-ring-gfx-0-0-0-timeout-and-reset-failure/62975) -- Ubuntu Discourse
- [GNOME Shell crash and GPU ring timeout on Fedora 42](https://discussion.fedoraproject.org/t/gnome-shell-crash-and-gpu-ring-timeout-on-amd-gpu-when-using-brave-browser-fedora-42/149587) -- Fedora Discussion
- [GNOME Mutter Switches To High Priority KMS Thread](https://www.phoronix.com/news/GNOME-High-Priority-KMS-Thread) -- Phoronix

### Keyboard Shortcuts and Accessibility
- [Ubuntu Keyboard Shortcuts](https://help.ubuntu.com/stable/ubuntu-help/shell-keyboard-shortcuts.html.en) -- Ubuntu Help
- [Ubuntu Accessibility](https://help.ubuntu.com/community/Accessibility) -- Ubuntu Community Help
- [Read Screen Aloud with Orca](https://documentation.ubuntu.com/desktop/en/24.04/how-to/accessibility/orca/read-screen-aloud/) -- Ubuntu Desktop Documentation
- [Accessibility Stack](https://documentation.ubuntu.com/desktop/en/latest/explanation/accessibility-stack/) -- Ubuntu Desktop Documentation
- [Orca Screen Reader](https://help.gnome.org/users/orca/stable/) -- GNOME Help

### Multi-Monitor and Scaling
- [HiDPI - ArchWiki](https://wiki.archlinux.org/title/HiDPI) -- Arch Wiki
- [Fractional Scaling on 4K Monitors with GNOME](https://mundobytes.com/en/Configure-fractional-scaling-on-4k-monitors-with-gnome/) -- mundobytes

### Extensions
- [The 15 Best GNOME Shell Extensions for Ubuntu](https://www.omgubuntu.co.uk/best-gnome-shell-extensions) -- OMG! Ubuntu
- [Blur My Shell](https://extensions.gnome.org/extension/3193/blur-my-shell/) -- GNOME Extensions
- [Dash to Dock](https://extensions.gnome.org/extension/307/dash-to-dock/) -- GNOME Extensions
- [Just Perfection](https://extensions.gnome.org/extension/3843/just-perfection/) -- GNOME Extensions

### Internal Project References
- `/GNOME-MUTTER-HARDENING.md` -- Complete Mutter hardening options catalog
- `/WAYLAND-COMPOSITOR-RESEARCH.md` -- Wayland compositor comparison (GNOME vs Sway vs labwc vs KWin etc.)
- `/X11-COMPOSITOR-RESEARCH.md` -- X11 compositor comparison (AccelMethod analysis)
- `autoinstall-G-gnome-full.yaml` -- Variant G autoinstall configuration with all mitigations
