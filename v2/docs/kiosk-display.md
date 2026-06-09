# Kiosk Display Stack — Image-Side Architecture

**Status:** `[PARTIAL]` (Phase 2 docs complete; Task 26/27/28 implementation hardware-blocked)
**Scope:** image-building-pipeline only (chassis ownership per DC-1)
**Cross-repo reference:** [`CeraUI/docs/ON_DEVICE_DISPLAY.md`](../../../CeraUI/docs/ON_DEVICE_DISPLAY.md)

This document covers everything the image is responsible for in the kiosk display stack: the systemd units, the package set, the OOM configuration, the wvkbd build, and the inert-by-default model. CeraUI owns the content, control, and lifecycle state — see the cross-repo doc above for the full picture.

---

## 1. Inert-by-Default Model

The kiosk stack ships **installed but masked**. At first boot, all kiosk-related units are masked so they cannot start accidentally. The device boots headless. CeraUI enables kiosk mode at runtime by unmasking and starting the units via systemctl.

This means:
- A device with no display attached boots and operates normally (headless streaming appliance)
- Enabling kiosk requires no reflash — the operator toggles it in the CeraUI Settings UI
- Disabling kiosk (or a crash-loop auto-disable) returns the device to headless operation without any image change

The postinst script (`v2/mkosi/mkosi.images/runtime/mkosi.postinst.chroot`) is responsible for masking the units at install time. The mask must survive a `systemctl daemon-reload` — use `systemctl mask --now` or write the mask symlink directly.

---

## 2. Systemd Units (Task 26 — hardware-blocked)

> **Status: planned, requires hardware validation before implementation.**
> The unit design below is the authoritative spec. Implementation is blocked on Task 1 (RK3588 display-stack spike: NO-GO — no board reachable). Do not implement until the hardware gate clears.

### `kiosk.service`

The primary kiosk unit. Runs cage as the Wayland compositor with Chromium as the single kiosk application.

```ini
[Unit]
Description=CeraLive Kiosk Display
After=ceralive.service graphical.target
Requires=ceralive.service
StartLimitIntervalSec=60
StartLimitBurst=3
OnFailure=kiosk-onfailure.service

[Service]
Type=simple
User=ceralive
Environment=DISPLAY_PROFILE=lcd
EnvironmentFile=-/etc/ceralive/kiosk.env
RuntimeDirectory=ceralive
ExecStartPre=/bin/sh -c 'until curl -sf http://127.0.0.1:80/status; do sleep 1; done'
ExecStart=/usr/bin/cage -- /usr/bin/chromium \
    --kiosk \
    --ozone-platform=wayland \
    --no-sandbox \
    "http://127.0.0.1:80/?mode=touch&display=${DISPLAY_PROFILE:-lcd}&kiosk_token=$(cat /run/ceralive/kiosk-token)"
Restart=on-failure
RestartSec=5

[Install]
WantedBy=graphical.target
```

Key design decisions:
- `After=ceralive.service` + `ExecStartPre` health check: the backend must be up and the token file must exist before Chromium launches
- `StartLimitBurst=3` / `StartLimitIntervalSec=60`: three failures within 60 seconds triggers the `OnFailure` handler and puts the unit in `failed` state (DC-2 crash-loop detection)
- `RuntimeDirectory=ceralive`: ensures `/run/ceralive/` exists before the token read (the backend also creates it, but belt-and-suspenders)
- The token is read inline in `ExecStart` via `$(cat ...)` — it is NOT cached in an env var or logged

### `kiosk-onfailure.service`

Runs when `kiosk.service` enters `failed` state. Writes a marker file to distinguish display-unplug from a crash-loop.

```ini
[Unit]
Description=CeraLive Kiosk OnFailure Handler
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=/usr/lib/ceralive/kiosk-onfailure.sh
```

The handler script (`/usr/lib/ceralive/kiosk-onfailure.sh`) checks the cage exit code. If cage exited because no DRM/KMS output was available, it writes `/run/kiosk-no-display`. Otherwise it writes nothing (crash-loop is inferred by the CeraUI backend from `NRestarts >= 3`).

```bash
#!/bin/bash
# kiosk-onfailure.sh
# Called by kiosk-onfailure.service when kiosk.service fails.
# Writes /run/kiosk-no-display if cage exited due to missing display.
# The CeraUI backend reads this file to distinguish display-unplug from crash-loop.

CAGE_EXIT_CODE="${EXIT_CODE:-}"
# cage exits 1 when no DRM output is found at startup
if [ "${CAGE_EXIT_CODE}" = "1" ]; then
    touch /run/kiosk-no-display
fi
```

The marker file lives on tmpfs (`/run/`) and is deleted on reboot and on `toggle-off` (T3 in the state machine).

### `kiosk-osk.service`

Manages the on-screen keyboard (wvkbd). Runs alongside `kiosk.service`, started hidden.

```ini
[Unit]
Description=CeraLive On-Screen Keyboard
PartOf=kiosk.service
After=kiosk.service

[Service]
Type=simple
User=ceralive
ExecStart=/usr/bin/wvkbd-mobintl --hidden
Restart=on-failure
RestartSec=2
```

The OSK is toggled by sending `SIGUSR1` (show) / `SIGUSR2` (hide) to the wvkbd process. The CeraUI frontend triggers this via the backend RPC when a text input gains focus. wvkbd runs as a Wayland layer-shell surface — it overlays Chromium without resizing the viewport.

---

## 3. Package Set (Task 27 — hardware-blocked)

> **Status: planned, requires hardware validation before implementation.**
> The package list below is the authoritative spec. wvkbd is NOT in Debian bookworm (it entered Debian at trixie). It requires build-from-source or a vetted pre-built .deb.

| Package | Source | Notes |
|---|---|---|
| `cage` | Debian bookworm | Wayland compositor for single-app kiosk |
| `chromium` | Debian bookworm | Must be >= 111 for OKLCH + TailwindCSS v4 render |
| `wvkbd` | Build from source | NOT in bookworm; entered Debian at trixie |
| `libmali-valhall-g610-*` | Rockchip vendor | GPU userspace for RK3588 (Mali-G610); required for Chromium ozone-wayland EGL/GBM |
| `libwayland-client0` | Debian bookworm | Wayland client library (cage dep) |
| `libwayland-server0` | Debian bookworm | Wayland server library (cage dep) |

**wvkbd build notes:**
- Source: https://github.com/jjsullivan5196/wvkbd
- Build deps: `libwayland-dev`, `libxkbcommon-dev`, `scdoc` (for man page)
- The build produces `wvkbd-mobintl` (mobile international layout) and `wvkbd-full` (full keyboard)
- The kiosk stack uses `wvkbd-mobintl` — appropriate for a touch streaming appliance
- Pin the wvkbd commit SHA in `versions.yaml` once a vetted build is confirmed on hardware

**Chromium version constraint:** bookworm ships chromium ~v120. This is >= 111, so OKLCH color space and TailwindCSS v4 render correctly. Do NOT downgrade below 111.

**GPU contingency:** if `libmali-valhall-g610` fails to provide EGL/GBM for Chromium ozone-wayland (i.e. Chromium falls back to software rendering or refuses to start), the contingency is mainline kernel + Mesa panthor/panfrost. This collides with D3 (`armbian_branch: vendor` for HDMI hdmirx + Rockchip MPP). That collision requires a re-plan and escalation — do not attempt silently.

---

## 4. OOM Configuration

The kiosk stack adds two memory-hungry processes (cage + Chromium) to a device that is already running ceracoder (hardware encoder) and the CeraUI backend. OOM score adjustments ensure the encoder is never killed before the UI.

| Process | OOM score adjustment | Rationale |
|---|---|---|
| `ceracoder` | `-500` (protected) | Killing the encoder drops the stream |
| `ceralive` (CeraUI backend) | `-300` (protected) | Killing the backend kills the kiosk session |
| `chromium` | `+200` (expendable) | UI can restart; stream must not drop |
| `cage` | `+100` (expendable) | Compositor can restart; stream must not drop |

OOM adjustments are set via `OOMScoreAdjust=` in the respective unit files, or via a `postinst` step that writes `/proc/<pid>/oom_score_adj` after service start.

---

## 5. Display Hardware Notes (RK3588)

These notes apply to the Orange Pi 5+ and Radxa Rock 5B+ targets.

**DRM node mapping:** the RK3588 exposes two DRM nodes: `card0` (display output, HDMI/DSI) and `card1` (render-only, Mali-G610 GPU). cage must be pointed at `card0`. The exact mapping is unconfirmed without hardware (Task 28). The `kiosk.service` unit may need `Environment=WLR_DRM_DEVICES=/dev/dri/card0` to force the correct node.

**Touch input:** the RK3588 DSI touchscreen controller appears as a `/dev/input/eventN` device. cage passes input events to Chromium automatically via the Wayland seat. Touch calibration (mapping the touch coordinates to the display geometry) is a Task 28 item and requires physical hardware.

**HDMI input vs display output:** the RK3588 HDMI input (hdmirx, used for capture) and HDMI output (used for the kiosk display) are separate hardware blocks. They do not conflict. The kiosk display uses the HDMI output; ceracoder uses the HDMI input via the `gstlibuvch264src` GStreamer element.

---

## 6. Postinst Integration

The kiosk stack is installed and masked in `v2/mkosi/mkosi.images/runtime/mkosi.postinst.chroot` (the single-source runtime executor, consolidated in Task 6).

The postinst section for kiosk (to be added in Task 26) must:
1. Install the kiosk units to `/usr/lib/systemd/system/` (vendor unit dir, sysext-mergeable)
2. Install the `kiosk-onfailure.sh` handler to `/usr/lib/ceralive/`
3. Run `systemctl mask kiosk.service kiosk-onfailure.service kiosk-osk.service` to set the inert-by-default state
4. NOT enable or start any kiosk unit — CeraUI does that at runtime

The postinst must be idempotent (re-running it on an already-configured system must not break anything).

---

## 7. Phase-3 Deferral Register

The following items are explicitly deferred to Phase 3. They are NOT present in the current image.

All Phase-3 items are hardware-blocked: no RK3588 board is reachable from the development environment (Task 1 spike verdict: NO-GO). See [`CeraUI/docs/ON_DEVICE_DISPLAY.md §6`](../../../CeraUI/docs/ON_DEVICE_DISPLAY.md) for the full deferral register with rationale.

| Item | Blocked on |
|---|---|
| **P3-1: E-ink kernel DRM driver + device-tree overlay** | Physical RK3588 + target e-ink panel + lab access |
| **P3-2: Dual-display hybrid (LCD + e-ink simultaneously)** | P3-1 + Task 28 (DRM node mapping + touch calibration) + hardware access |
| **P3-3: On-device live-video preview** | Hardware access + encoder/decoder pipeline design |
| **P3-4: Battery/power telemetry (#61)** | Document-only: current boards are mains-powered, no fuel-gauge IC present |

Tasks 26, 27, 28, and 30 are all hardware-blocked for the same reason (Task 1 gate not cleared). They are designed and specced; implementation waits for hardware access.

---

## 8. Related Documents

| Document | Scope |
|---|---|
| [`CeraUI/docs/ON_DEVICE_DISPLAY.md`](../../../CeraUI/docs/ON_DEVICE_DISPLAY.md) | Cross-repo architecture, DC-1..DC-4, Phase-3 deferral register |
| [`CeraUI/docs/KIOSK_STATE_MACHINE.md`](../../../CeraUI/docs/KIOSK_STATE_MACHINE.md) | DC-2: 5-state machine spec |
| [`CeraUI/docs/KIOSK_TOKEN_CONTRACT.md`](../../../CeraUI/docs/KIOSK_TOKEN_CONTRACT.md) | DC-3: loopback token spec |
| [`v2/docs/dev-loop.md`](dev-loop.md) | Dev-push loop for ceracoder/srtla |
| [`v2/docs/deferred-ceraui-sysext.md`](deferred-ceraui-sysext.md) | CeraUI sysext migration (separate deferral) |

---

## 9. Known Technical Debt

| ID | Item | Detail | Resolution |
|---|---|---|---|
| **TD-1** | Workspace-external doc links | This file and `AGENTS.md` reference sibling-repo docs via `../../../CeraUI/...` (and `../CeraUI/...`) paths that climb above this repo's checkout root. Affected here: §Header (`CeraUI/docs/ON_DEVICE_DISPLAY.md`), §7 deferral note, and §8 Related Documents rows for `ON_DEVICE_DISPLAY.md` / `KIOSK_STATE_MACHINE.md` / `KIOSK_TOKEN_CONTRACT.md`. | Violates root `AGENTS.md` **Rule D** (repos self-contained, no workspace-external references). Links resolve only inside the `ceralive/` workspace, not in a standalone CI checkout. Convert to plain textual references (repo + doc name, no relative link) when next touching this file. Low severity: Markdown cross-references only — no code/test/config reads an external path. |
