> **STATUS: ACTIVE** — Multi-display feasibility research. Primary output: compositor/DE recommendation for 2-3 monitor setup on Raphael iGPU.

# Multi-Display Feasibility: AMD Raphael iGPU (DCN 3.1.5, 2 CUs)

**Hardware:** AMD Ryzen 9 7950X | ASUS ROG Crosshair X670E Hero | RTX 4090 (headless) + Raphael iGPU (all display)
**Date:** 2026-03-31
**Sources:** 5 parallel research agents, 200+ web sources, upstream bug trackers, compositor release notes
**Question:** What is the best desktop/compositor stack for a 2-3 monitor setup driven exclusively by the Raphael iGPU?

---

## Executive Summary

**RECOMMENDED: KWin Wayland (KDE Plasma 6)** — best multi-monitor tooling, confirmed dual-1440p stable on Raphael with `amdgpu.sg_display=0`, configurable to low GFX overhead.

**RUNNER-UP: Sway (wlroots 0.19)** — lowest GFX ring overhead, explicit sync support, ideal if you want minimal overhead over visual polish.

**GNOME is not recommended for 2-CU iGPU multi-display** — Mutter has the highest GFX overhead of any compositor, and 2 CUs will saturate under normal desktop activity with 2+ monitors. The llvmpipe path (zero GFX) is a workaround, not a proper solution.

**One non-negotiable kernel parameter applies regardless of compositor:**
```
amdgpu.sg_display=0
```
Without this, Raphael iGPU multi-monitor causes screen flickering, solid white screens, and display glitches on every compositor tested.

---

## 1. Hardware Capability: What DCN 3.1.5 + 2 CUs Can Actually Drive

### DCN vs GFX Ring — Two Separate Subsystems

The critical insight is that **display output and compositor rendering run on entirely separate hardware**:

| Subsystem | Hardware | What It Does | Multi-Display Impact |
|---|---|---|---|
| **DCN 3.1.5** (Display Core Next) | Dedicated display engine, independent of CUs | Scanout, scaling, color, page flips | Handles 2-3 displays natively — NOT GFX ring |
| **GFX Ring** (Shader/Compute) | 2 Compute Units | Compositor rendering: window drawing, blur, shadows, animations | Bottleneck for multi-display compositing |

DCN 3.1.5 supports **4 simultaneous display outputs** at the silicon level (4 CRTCs, 4 OTGs). The ASUS ROG Crosshair X670E Hero exposes rear I/O ports connected to the iGPU — typically HDMI 2.1 + DisplayPort 1.4 (exact port count varies; verify on ASUS product page). Running 2-3 displays is within DCN 3.1.5 spec.

**The constraint is entirely compositor rendering on 2 CUs, not hardware display output count.**

### GFX Ring Capacity for Multi-Display Compositing

With 2 CUs (~0.5 TFLOPS), the practical limits are:

| Setup | Compositor | Feasibility |
|---|---|---|
| 2× 1440p@60Hz | Software rendering (CPU) | ✅ Works — limited by single compositor core speed |
| 2× 1440p@60Hz | Lightweight GL (Sway, labwc, KWin no-effects) | ✅ Comfortable — damage tracking means mostly idle |
| 2× 1440p@144Hz | Lightweight GL | ✅ Should work — higher frame rate, same GFX load per frame |
| 2× 1440p@60Hz | Heavy GL (GNOME full effects, Hyprland pre-0.54) | ⚠️ Risk — GPU saturation reported on 8-CU iGPUs; 2-CU is 4× worse |
| 2× 4K@60Hz | Any GL compositor | ⚠️ Risky — pixel area 4× larger than 1440p |
| 3× 1440p@60Hz | Lightweight GL | ⚠️ Marginal — validated per-display overhead × 3 |
| 3× 1440p@60Hz | Software rendering | ⚠️ CPU bottleneck (single-threaded compositor path) |

**Key data point:** A Radeon 680M user (8 CUs — 4× your CU count) reported Hyprland saturation with a single 4K second monitor before the 0.54 optimization. Your 2-CU Raphael is significantly more constrained at 4K. **Stick to 1440p or lower for multi-display.**

### Multi-Display Boot-Time Risk

The `optc31_disable_crtc` REG_WAIT timeout fires for **each active CRTC** at boot. With 2 monitors connected:
- 2 BIOS-initialized CRTCs = potentially 2 optc31 timeouts instead of 1
- With DMUB 0x05002000, each timeout recovers individually — does NOT cascade to ring timeout
- With old firmware (< 0x05002000), 2 CRTCs = 2 opportunities for ring timeout cascade

**Conclusion:** With DMUB 0x05002000 in place (confirmed working in H_v1), adding a second monitor increases boot-time DCN activity but should not cause a crash loop. The firmware fix is what makes multi-display safe.

---

## 2. Critical Kernel Parameters (Universal — All Compositors)

Apply these in `/etc/default/grub` → `GRUB_CMDLINE_LINUX` regardless of compositor choice:

```
amdgpu.sg_display=0        # MANDATORY: prevents Raphael multi-monitor flicker/white-screen
amdgpu.gpu_recovery=1      # Enable GPU reset recovery
amdgpu.noretry=0           # Re-enable retry faults (AMD disables by default; causes APU stalls)
amdgpu.gfx_off=0           # Disable GFX power gating (DCN state transition glitches)
amdgpu.ppfeaturemask=0xfffd7fff  # Disable STUTTER_MODE, reduces DCN power transition latency
```

Already present from variant testing: `sg_display=0`, `ppfeaturemask=0xfffd7fff`, `dcdebugmask=0x10`.

**sg_display context:** The Scatter/Gather Display feature on Raphael is confirmed to cause multi-monitor flickering on 7950X with every compositor tested (XFCE, KDE, GNOME). `sg_display=0` was the fix. This is already set in the autoinstall YAML variants — confirm it remains set when deploying a new compositor.

---

## 3. Compositor Ranking for Multi-Display

### Tier 1: Recommended

#### 1. KWin Wayland (KDE Plasma 6.5+)

**Multi-monitor feature set:** Best of any compositor tested.
- Per-monitor independent scaling (fractional supported), refresh rates, color profiles, VRR per-display
- GUI management: System Settings → Display & Monitor
- Different refresh rates per monitor: ✅ native
- Hotplug: ✅ handled via kscreen
- wlr-output-management compatible: ✅ (kscreen-doctor CLI)

**GFX ring overhead:** Medium, but fully configurable.
```
System Settings → Display → Compositor:
  - Disable desktop effects globally: reduces to near-Sway levels
  - Rendering backend: OpenGL 3.1
  - Scale method: Crisp (lower GPU load than Smooth)
  - Max framerate: 60 (cap reduces idle submissions)
```

**NVIDIA headless — critical env var:**
```bash
KWIN_DRM_DEVICES=/dev/dri/by-path/pci-<AMD-PCI-ADDRESS>-card
```
Without this, KWin probes all DRM nodes including NVIDIA, causing a 12-second main thread hang when NVIDIA DRM node is in D3cold. Set in `/etc/environment` before SDDM starts.

**AMD Raphael stability evidence:**
- KDE Bug 512967: Granite Ridge (9950X3D, same GC generation) shows ring timeout on Wayland — grave severity, no kernel fix as of early 2026. Workaround: `KWIN_DRM_NO_AMS=1` + kernel params.
- Dual-1440p working confirmed on Raphael iGPU with `amdgpu.sg_display=0` + KDE 6.5.3 (community, March 2026)
- Fedora 43: intermittent black screen fixed in `plasma-desktop 6.5.3-2`

**Required KWin env vars / workarounds:**

| Variable | Value | Purpose |
|---|---|---|
| `KWIN_DRM_DEVICES` | `/dev/dri/card_AMD` | **CRITICAL** — prevent NVIDIA probing |
| `KWIN_DRM_NO_AMS` | `1` | Legacy DRM if atomic commit errors appear |
| `POWERDEVIL_NO_DDCUTIL` | `1` | Prevent DDCUtil main thread hang (fixed Plasma 6.4+ but belt-and-suspenders) |

**Display manager:** SDDM (not GDM). SDDM starts a lightweight Qt greeter — no Mutter KMS involvement at boot. GDM starts gnome-shell which exercises the AMD DCN path before any login.

**Ubuntu 24.04 install:**
```bash
sudo add-apt-repository ppa:kubuntu-ppa/backports   # for Plasma 6 (Ubuntu 24.04 ships Plasma 5.27)
sudo apt install kubuntu-desktop
```

**Fedora 43 install:**
```bash
# Fedora 43 KDE Spin ships Plasma 6 natively — recommended route
```

---

#### 2. Sway (wlroots 0.19 / Sway 1.11+)

**Multi-monitor:** Excellent CLI control, different refresh rates per output, wlr-randr for runtime adjustment.

```ini
# ~/.config/sway/config
output HDMI-A-1 resolution 2560x1440@60Hz position 0,0
output DP-1 resolution 2560x1440@144Hz position 2560,0
output DP-2 resolution 1920x1080@60Hz position 5120,0
```

**GFX ring overhead:** Lowest of any accelerated Wayland compositor.
- No animations, no blur, no rounded corners by default
- Damage tracking via wlroots — only redraws changed pixels
- Explicit sync (wlroots 0.19 / June 2025): better frame timing on AMD
- Near-zero GFX ring activity for a static terminal/IDE desktop

**NVIDIA headless:** Sway requires `--unsupported-gpu` flag when NVIDIA is present. With NVIDIA truly headless (no display connectors), Sway uses only the AMD DRM path. The `--unsupported-gpu` flag prevents Sway from refusing to start on NVIDIA detection.

**AMD Raphael stability:** Well-tested. Sway 1.8.1 fixed AMD memory clock regression (100% VRAM clocks at idle, ~30W idle vs ~10W). wlroots 0.18 added GPU reset recovery specifically useful for AMD ring reset scenarios.

**Trade-off:** Tiling WM paradigm. Requires keybinding-based window management. Appropriate for keyboard-driven workflows (terminal, IDE, browser). Not a traditional stacking WM/GNOME replacement in workflow.

---

### Tier 2: Viable

#### 3. Hyprland 0.54+ (Aquamarine backend)

**Key development (Feb 2026):** Hyprland 0.54 delivered 50–500% iGPU performance improvement specifically targeting this hardware class. The Aquamarine DRM/KMS rendering backend was restructured to reduce redundant GPU submissions.

**Multi-monitor config (best in class):**
```ini
# hyprland.conf
monitor = HDMI-A-1, 2560x1440@60, 0x0, 1
monitor = DP-1, 2560x1440@144, 2560x0, 1       # different refresh rates: ✅ native
monitor = DP-2, 1920x1080@60, 5120x0, 1

# if second display fails to commit:
env = WLR_DRM_NO_MODIFIERS, 1   # Note: does NOT apply to Hyprland (uses Aquamarine, not wlroots)
# For Hyprland/Aquamarine use:
env = AQ_NO_ATOMIC, 1           # last resort only — not recommended
```

**NVIDIA headless (AMD iGPU only display):**
```bash
# Force only AMD card as display device:
env = AQ_DRM_DEVICES, /dev/dri/by-path/pci-<AMD-ADDRESS>-card
```
If NVIDIA has no display connectors, Aquamarine may automatically exclude it from display device enumeration. Test: start Hyprland without `AQ_DRM_DEVICES` first; if it fails, restrict to AMD path.

**Caveat:** Pre-0.54 had documented GPU saturation on 8-CU iGPUs with effects enabled. Post-0.54 is promising but 2-CU Raphael desktop-specific reports are limited. To stay safe on 2 CUs:
```ini
animations { enabled = no }
decoration { blur { enabled = no } }
decoration { shadow { enabled = no } }
```

**Suitability:** Best ergonomics and configuration of any tiling/dynamic compositor. Modern Wayland-native. Rapid development. Not for users needing enterprise stability guarantees.

---

#### 4. labwc (wlroots 0.19, XFCE-compatible)

**What it is:** Lowest-risk migration from current XFCE + X11 setup. Replaces `xfwm4` as the compositor/WM while keeping all XFCE components (panels, Thunar, xfce4-settings).

```bash
# Ubuntu 24.04
sudo apt install labwc
# Then: run `labwc` from XFCE session or set as WM in XFCE
```

**Multi-monitor:** wlroots 0.19 DRM backend, full multi-display support. No built-in GUI tool — use `wlr-randr`:
```bash
wlr-randr --output HDMI-A-1 --mode 2560x1440@60 --pos 0,0 \
          --output DP-1 --mode 2560x1440@60 --pos 2560,0
```

**GFX ring overhead:** Very low — no animations, no blur, DRM direct scanout. Comparable to Sway.

**Trade-off:** Stacking WM paradigm (openbox-like). No built-in per-monitor workspace management.

---

### Tier 3: Not Recommended for 2-CU iGPU Multi-Display

#### GNOME / Mutter (any version)

| Issue | Detail |
|---|---|
| GFX ring overhead | Highest of any compositor tested — animations, blur, shadows not easily disabled |
| 2-CU constraint | A user with 8-CU iGPU reported saturation with 2nd 4K display under Mutter. 2-CU = 4× worse headroom |
| Multi-display + DCN | More displays = more atomic commit pressure in Mutter's KMS thread |
| Mutter 46 RT SIGKILL | `MUTTER_DEBUG_KMS_THREAD_TYPE=user` still required for Ubuntu 24.04; causes crashes on Mutter 46+ if applied incorrectly |
| X11 dropped | GNOME 50 (Ubuntu 26.04) drops X11 entirely — Wayland-only, no AccelMethod "none" fallback |

**Exception — GNOME + llvmpipe:**
If GNOME UX is the explicit requirement, run GNOME Shell with software rendering:
```bash
LIBGL_ALWAYS_SOFTWARE=1
```
This gives zero GFX ring pressure (CPU compositor path) with full GNOME ecosystem. The 7950X has sufficient single-core throughput for 2×1440p@60Hz software compositing. Performance degrades at 4K or during rapid window activity. This is the Wayland equivalent of `AccelMethod "none"` but for GNOME — not a production recommendation, but viable for light usage.

#### COSMIC DE (Epoch 1.0)

Blocked by two unresolved issues:
- **Multi-monitor stutter at mixed refresh rates** (cosmic-comp Issue #2202, unresolved March 2026)
- **smithay memory leak on AMD** — problematic for a long-running ML workstation
- **AMD VRAM leak** (cosmic-comp Issue #1179)

Revisit in 6-12 months when Epoch 2 ships the Vulkan renderer.

---

## 4. Display Manager Comparison

| DM | Compositor at Login | DCN Impact | Multi-Monitor | Best For |
|---|---|---|---|---|
| **GDM** | gnome-shell (full Mutter) | HIGH — exercises AMD DCN/KMS ring at boot | Supported | GNOME only |
| **SDDM** | Qt greeter (no Mutter) | LOW — minimal KMS activity | Supported | KDE, Sway, Hyprland |
| **LightDM** | GTK greeter (minimal) | LOW | Supported | XFCE, any non-GNOME |

**For multi-display stability: SDDM or LightDM strongly preferred.** GDM starts gnome-shell before user login, exercising the AMD DCN path at the most vulnerable boot window (when optc31 timeout fires at T+6s). SDDM/LightDM avoid this entirely.

**Note:** GDM is required for `gnome-remote-desktop` headless remote login feature. If remote access is needed alongside multi-display, see RDP section below.

---

## 5. Remote Desktop with Multi-Display

| Stack | Multi-Monitor Over RDP | Notes |
|---|---|---|
| GNOME + gnome-remote-desktop | Partial — virtual monitor extend mode via `--dynamic-resolution` | Requires GDM; headless session support; update to gnome-remote-desktop 46.3-0ubuntu1.2 |
| KDE + KRdp (Plasma 6.1+) | **No** — all monitors merged into single ultra-wide feed | Per-monitor remote display not yet implemented (March 2026) |
| xrdp + XFCE | N/A — requires forced Xorg (`WaylandEnable=false`) | Dead-end architecture; xrdp incompatible with Wayland |
| PipeWire screen capture | Works on Wayland compositors with xdg-desktop-portal | Each display as separate PipeWire stream |

For multi-display + remote access: GNOME GRD with virtual monitors is the most functional option, but carries GNOME's GFX ring overhead. The practical workaround for KDE is to be logged in locally (displays active) and mirror a single display over RDP.

---

## 6. Current Config Migration Path

**Current state (Variant H v1):** XFCE + X11 + `AccelMethod "none"` + DMUB 0x05002000 — STABLE, single display confirmed.

**Step 1 (Near-term): Enable multi-display on current config**

Add to GRUB cmdline (already have sg_display=0 — verify):
```
amdgpu.sg_display=0 amdgpu.noretry=0 amdgpu.gpu_recovery=1
```

Switch `AccelMethod` from `"none"` to `"glamor"` in xorg.conf — this enables GPU-accelerated compositing with damage tracking, which is materially better for multi-display than pure software rendering. With DMUB 0x05002000, glamor is confirmed stable (Variant B v2: 8 boots, 0 ring timeouts with glamor).

**Step 2 (Medium-term): KWin Wayland on Fedora 43 or Ubuntu 24.04+backports**

```bash
# Fedora 43 KDE Spin (cleanest path):
# Install from KDE Spin ISO — ships Plasma 6 + SDDM + kernel 6.17 + Mesa 25.x natively

# Ubuntu 24.04:
sudo add-apt-repository ppa:kubuntu-ppa/backports
sudo apt install kubuntu-desktop sddm
sudo systemctl disable gdm && sudo systemctl enable sddm

# /etc/environment additions:
KWIN_DRM_DEVICES=/dev/dri/by-path/pci-<AMD-PCI>-card
POWERDEVIL_NO_DDCUTIL=1
```

**Step 3 (Validation):** Connect 2 monitors before boot. Check dmesg for:
- `optc31_disable_crtc` — expect 1-2 at T+5-6s, should self-recover with DMUB 0x05002000
- `ring gfx_0.0.0 timeout` — should be absent with correct firmware + sg_display=0
- `kwin_wayland` startup — look for GPU selection messages

---

## 7. Summary Decision Matrix

| Compositor | Multi-Display Tooling | GFX Ring Load (2 CU) | Raphael Stability | NVIDIA Headless | DM | Score |
|---|---|---|---|---|---|---|
| **KWin Wayland** | ★★★★★ | Medium (configurable) | ★★★★☆ | KWIN_DRM_DEVICES | SDDM | **9/10** |
| **Sway 1.11** | ★★★☆☆ | ★★★★★ Lowest | ★★★★★ | --unsupported-gpu | SDDM/LightDM | **8/10** |
| **Hyprland 0.54** | ★★★★★ | Medium (0.54 improved) | ★★★★☆ | AQ_DRM_DEVICES | SDDM | **8/10** |
| **labwc 0.9** | ★★★☆☆ | ★★★★☆ Low | ★★★★★ | Transparent | LightDM | **7/10** |
| **GNOME + llvmpipe** | ★★★★☆ | ★★★★★ Zero (CPU) | N/A | N/A | GDM | **6/10** |
| **GNOME + Mutter GL** | ★★★★☆ | ★★☆☆☆ Highest | ★★★☆☆ | Needs config | GDM | **4/10** |
| **XFCE + X11 + glamor** | ★★☆☆☆ | ★★★☆☆ Medium | ★★★★☆ | AccelMethod | LightDM | **6/10** |
| **COSMIC Epoch 1** | ★★★☆☆ | Unknown | ★★☆☆☆ Bug | Workaround | SDDM | **3/10** |

---

## Sources

- Hyprland 0.54 iGPU performance — [Phoronix](https://www.phoronix.com/news/Hyprland-0.54-Released) · [XDA](https://www.xda-developers.com/hyprland-054-is-out-50-500-percent-boost/)
- KDE Bug 512967 (Granite Ridge ring timeout on KWin Wayland) — kde-bugs-dist mailing list
- KWin multi-GPU hang fix — [Manjaro forum](https://forum.manjaro.org/t/kwin-wayland-main-thread-hangs-12s-on-amd-hybrid-gpu-rog-g14-kwin-trying-to-open-d3cold-dgpu/186640)
- KWin Environment Variables — [KDE Community Wiki](https://community.kde.org/KWin/Environment_Variables)
- AMD Raphael sg_display=0 fix — [NixOS Discourse](https://discourse.nixos.org/t/white-flickering-desktop-environments-with-amd-raphael-ryzen-7950x/26286) · [ArchWiki AMDGPU](https://wiki.archlinux.org/title/AMDGPU)
- wlroots 0.18/0.19 AMD improvements — [Phoronix wlroots-0.18](https://www.phoronix.com/news/wlroots-0.18-Released)
- Sway AMD memory clock fix — [Issue #7361](https://github.com/swaywm/sway/issues/7361)
- COSMIC multi-monitor stutter — [cosmic-comp Issue #2202](https://github.com/pop-os/cosmic-comp/issues/2202)
- Mutter KMS thread RT fix (MR !3324) — [Phoronix](https://www.phoronix.com/news/GNOME-High-Priority-KMS-Thread) · [GNOME GitLab](https://gitlab.gnome.org/GNOME/mutter/-/merge_requests/3324)
- GDM vs SDDM AMD DCN impact — [LP #2034619](https://bugs.launchpad.net/ubuntu/+source/mutter/+bug/2034619)
- KRdp multi-monitor limitation — [KDE Discuss](https://discuss.kde.org/t/inquiry-regarding-true-headless-multi-monitor-rdp-remote-sessions-on-plasma-wayland/45327)
- GRD session persistence fix — [LP #2072130](https://bugs.launchpad.net/ubuntu/+source/gnome-remote-desktop/+bug/2072130)
- labwc 0.9 wlroots 0.19 — [linuxiac](https://linuxiac.com/labwc-0-9-wayland-compositor-released-with-wlroots-0-19-support/)
- KDE Plasma Wayland iGPU — [Fedora Discussion](https://discussion.fedoraproject.org/t/f43-kde-running-plasma-using-nvidia-gpu-instead-of-amd-igpu-by-default-after-upgrade/171419)
- DCN overview — [Linux Kernel Docs](https://docs.kernel.org/gpu/amdgpu/display/dcn-overview.html)
- Dedoimedo AMD Wayland vs X11 benchmarks — [dedoimedo.com](https://www.dedoimedo.com/computers/wayland-vs-x11-performance-amd-graphics.html)
