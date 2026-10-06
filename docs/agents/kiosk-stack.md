<!-- Moved verbatim from AGENTS.md on 2026-10-05 by lean-rules-docs-landing-latam -->

## KIOSK STACK

The image ships a kiosk display stack (cage + Chromium + wvkbd) **installed but inert by default**. All kiosk units are masked at first boot. CeraUI enables kiosk mode at runtime via systemctl — no reflash needed.

**Repo boundary (DC-1):** the image owns the chassis (units, packages, OOM config, `OnFailure` handler). CeraUI owns the content, control, and lifecycle state (toggle RPC, token mint, state machine).

**Cog display add-on (W4) — trixie closure + a Panthor/Mesa GPU stack:** Cog +
WPEWebKit is validated as a lighter alternative display engine, packaged as a
feature sysext add-on. Acquisition path is unchanged in shape — plain `apt` from
the target suite's `main` — but **every pin and the whole GPU half moved** at the
trixie/mainline migration, and neither was a version bump:

- **The renderer package was RENAMED.** `libwpewebkit-1.1-0` does not exist in
  trixie at all; the closure is now `cog` **0.18.4-1+b1** + `libwpewebkit-2.0-1`
  **2.48.3-1** (+ `libicu72` → `libicu76`, `libopenjp2-7` dropped for
  `libjxl0.11`/`libavif16`). The retired pins fail acquisition with apt exit 100
  and zero `.deb`s — proven, not assumed. Note 2.48.3, **not** the "2.44.x" the
  pre-migration doc forecast; that forecast was never re-checked against the
  archive.
- **The GPU userspace is Mesa now.** Mainline binds the Mali-G610 (a Valhall CSF
  part) with the in-tree open **`panthor`** DRM driver — `CONFIG_DRM_PANTHOR=m`,
  verified in the real resolved v7.2 `edge` config and pinned in
  `manifests/kernel/required-symbols.list`. `libmali` is **off the mainline
  path**: `manifests/families/rk3588.yaml` `variants.edge.firmware_packages`
  lists `armbian-firmware` only. That drop is load-bearing rather than tidy — the
  blob ships `/etc/ld.so.conf.d/00-aarch64-mali.conf`, which sorts first and
  captures `libEGL.so.1`/`libGLESv2.so.2`/`libgbm.so.1` image-wide for a driver
  bound to a `/dev/mali0` a mainline kernel never creates
  (armbian/build#10320), so leaving it in would not degrade GL, it would remove
  it. **The vendor overlays that still shipped libmali are themselves retired**,
  and the blob's URL/SHA pin went with them — no variant declares it and no build
  stages it.
- **The Mesa half rides INSIDE the sysext**, which is the one place the
  Platform-layer rule inverts — see the ANTI-PATTERNS entry and
  [`docs/cog-display-addon.md`](../cog-display-addon.md) §5 for why (the
  Runtime layer prunes exactly those four globs for the size gate, so the base
  has no file at those paths to shadow).

Measured, not estimated: **353,172,379 B installed / 111,521,792 B squashed**
(real trixie arm64 closure, extracted, pruned with the real
`SYSEXT_EXCLUDE_NAMES` and squashed as `sysext-build.lib.sh` does).
**Hardware-gated:** the descriptor is wired into the build only after RK3588
render QA passes (same gate as Tasks 26/27/28). The gated item is now
**Panthor/Mesa EGL/GBM render**, not package availability — and the failure mode
to watch for is Mesa silently falling back to `llvmpipe`, which renders
*correctly* and so cannot be distinguished from success without checking the
bound driver by name.

**Implementation status:** Tasks 26 (systemd units), 27 (packages), 28 (RK3588 dual-GPU udev + touch calibration), and 30 (integration validation) are **hardware-gated** by the display-stack spike. Its original NO-GO recorded no reachable board in that session, not a permanent access state. Later Trixie and Rock RGA qualification do not exercise display rendering or clear that separate gate.

**Phase-3 deferrals:** e-ink kernel DRM driver + device-tree, dual-display hybrid, on-device live-video preview, and #61 battery/power telemetry (document-only: current boards are mains-powered, no fuel-gauge IC). Full register: [`docs/kiosk-display.md §7`](../kiosk-display.md).

**RK3588 mainline-patch contingency is retired:** the mainline/`edge` 7.2
production build default replaced the vendor track, and the vendor machinery is
preserved at `vendor-kernel-final`. The old patch bookmark in
[`docs/kiosk-display.md §3`](../kiosk-display.md) is historical context only,
not an active safety fallback or instruction to re-open D3.

