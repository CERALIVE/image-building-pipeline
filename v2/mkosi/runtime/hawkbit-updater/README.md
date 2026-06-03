# CeraLive device OTA — `rauc-hawkbit-updater` (Runtime layer, Stage 7, task 41)

Device-side counterpart of the private hawkBit engine (`v2/fleet/hawkbit/`, task 40).
`rauc-hawkbit-updater` 1.4 polls the private hawkBit **DDI v1** API, downloads a
signed `.raucb` from R2 (the URL hawkBit hands back is rewritten to
`apt.ceralive.tv/bundles/...`, task 39), and installs it to the inactive RAUC A/B
slot. Slot **confirmation/rollback stays with `ceralive-healthcheck.service`**
(task 29) — the updater never confirms a slot.

```
hawkBit DDI v1 (private, 127.0.0.1:8080 behind TLS proxy/VPN)
        │  poll + deployment-base (auth: per-device target token)
        ▼
rauc-hawkbit-updater ──download──▶ /data/ceralive/rauc-downloads/bundle.raucb
        │  RAUC D-Bus InstallBundle                         (NOT rootfs — task 41)
        ▼
RAUC installs to inactive slot, marks it primary (boot-attempts=3, system.conf)
        │  (updater has NO mark-good — gate is NOT bypassed)
        ▼  reboot (operator/CeraUI controlled; post_update_reboot=false)
new slot boots → ceralive-healthcheck.service → rauc mark-good  OR  rollback
```

## Files (this directory = canonical reference; the wired executor is the postinst)

| File | Installed to | Role |
|------|--------------|------|
| `config.conf` | `/etc/rauc-hawkbit-updater/config.conf` | Baked-in **template** (`@PLACEHOLDERS@`, **no token**). |
| `rauc-hawkbit-updater.service` | `/etc/systemd/system/rauc-hawkbit-updater.service.d/10-ceralive.conf` | Drop-in over the `.deb` unit: `-c` the `/data` config + gate on it. |
| `provision-token.sh` | `/usr/local/sbin/ceralive-hawkbit-provision` | First-boot per-device enrollment + config render. |
| `README.md` | — | This document. |

**Dual-track** (the project convention, tasks 26/29/30): these canonical files are
mirrored by inline twins written by
`mkosi.images/runtime/mkosi.postinst.chroot::setup_hawkbit_updater()`, which is the
layer that actually runs in the build. The postinst also installs three CeraLive
systemd units described below. Keep the twins in sync.

## The backport `.deb` (NOT in bookworm apt)

`rauc-hawkbit-updater` 1.4 is **not** in Debian bookworm `main` — only in sid/forky
as `1.4-1` (decisions.md task 5). It must be **built once as a bookworm backport
`.deb`** and pre-staged for the image build, exactly like the first-party `.deb`s
(it is **not** an `apt-get install` line in `shared.list` — that would break the
whole-list install on a build host without the backport).

Build it from the Debian maintainer source (all build-deps are in bookworm `main`):

```bash
git clone https://salsa.debian.org/debian/rauc-hawkbit-updater.git
cd rauc-hawkbit-updater
# build-deps: debhelper-compat(=13) libcurl4-openssl-dev libglib2.0-dev \
#             libjson-glib-dev meson pkgconf
# Produce an arm64 bookworm backport on an arm64 builder (or cross):
dpkg-buildpackage -us -uc -b
#   → ../rauc-hawkbit-updater_1.4-1~bpo12+1_arm64.deb
```

Stage that `.deb` where the runtime postinst can see it (default
`/opt/ceralive-staging`, the same place `lib/orchestrate.sh` drops the first-party
`.deb`s). The postinst installs it with `apt-get install -y ./<file>.deb` so apt
resolves its runtime deps (`libcurl4`, `libglib2.0-0`, `libjson-glib-1.0-0` — all
bookworm `main`) from the Debian sources written earlier in the same postinst.

> **Graceful build:** if the backport `.deb` is not staged (parity / dry / offline
> builds), the postinst still deploys the config template, the provision script and
> the three CeraLive units, logs a clear warning, and skips only the binary install
> — mirroring the postinst's "no secret in env → install placeholder" pattern. The
> units stay inert (no binary, and the updater is gated on the un-rendered config),
> so a package-less image is safe.

## Secure enrollment — **no shared static token in the image**

The image bakes **only the template** (`@PLACEHOLDERS@`). The real per-device token
is provisioned on first boot onto the **data partition** (survives A/B swaps,
never in git):

1. Operator drops an enrollment file on `/data` (out-of-band — flashing, a config
   push, or a first-boot orchestration step), mode `0600`:

   ```ini
   # /data/ceralive/hawkbit.conf   (on /data — NEVER baked into the image)
   HAWKBIT_SERVER=hawkbit.internal.example:8080      # required
   HAWKBIT_TARGET_TOKEN=<per-device DDI target token> # preferred …
   #HAWKBIT_GATEWAY_TOKEN=<tenant gateway token>       # … or a tenant gateway token
   #HAWKBIT_PROVISION_URL=https://provision.example/…  # … or fetch over mTLS
   HAWKBIT_TARGET_NAME=               # optional; default = hostname
   HAWKBIT_TENANT=DEFAULT             # optional
   HAWKBIT_SSL=true                   # optional
   HAWKBIT_SSL_VERIFY=true            # optional
   ```

2. `ceralive-hawkbit-provision.service` (oneshot, `ConditionPathExists=` that file)
   runs `provision-token.sh`, which:
   - resolves the token (target token / gateway token / fetched over mTLS using the
     existing apt client cert), persists it to `/data/ceralive/hawkbit-token`
     (`0600`, the canonical store);
   - renders the **effective** config to `/data/ceralive/hawkbit-updater/config.conf`
     (`0600`) — placeholders filled, the auth line set to `auth_token` **or**
     `gateway_token`, and `compatible` read from `/etc/rauc/system.conf` (board-aware,
     so the Runtime layer stays arch-neutral and the rollout target filter
     `attribute.compatible==ceralive-<family>` matches — task 40).

3. `rauc-hawkbit-updater.service` runs with `-c /data/ceralive/hawkbit-updater/config.conf`
   and is **gated** on that file existing — so an un-enrolled device never polls
   hawkBit with an empty token.

**Three enrollment options, pick per fleet** (all keep secrets off the image):

| Option | How | When |
|--------|-----|------|
| Token on `/data` (preferred) | `HAWKBIT_TARGET_TOKEN` in `hawkbit.conf` | Per-device token minted in hawkBit, written at flash/first-boot. |
| Provisioning endpoint | `HAWKBIT_PROVISION_URL` (mTLS, apt client cert) | Device fetches its own token on first boot — no token at flash time. |
| Gateway token | `HAWKBIT_GATEWAY_TOKEN` | Tenant-wide; use with care (authenticates many targets). |

> Build-time env injection (a per-device token baked at image build) is **not used**:
> it forces a per-device image and bakes a secret into the artifact. The `/data`
> first-boot model gives one fleet-wide image with per-device secrets on the mutable
> partition only.

## Healthcheck-gated mark-good (task 29) — the gate is **not** bypassed

`rauc-hawkbit-updater` 1.4 only **installs** (RAUC D-Bus `InstallBundle`); it has
**no `mark-good`/auto-confirm capability** (there is no such config key — the
"`mark_compatible = false` or equivalent" the task asks for is satisfied
structurally: the updater simply cannot confirm a slot). Confirmation is RAUC's
`boot-attempts` countdown + `ceralive-healthcheck.service`, which is the **sole**
caller of `rauc mark-good`. A bad bundle that boots-but-can't-stream is left
unconfirmed and rolled back on the next reboot (task 27 bootcount adapter).

`post_update_reboot = false` keeps the reboot under CeraLive's control (the upstream
docs warn `post_update_reboot=true` is an **immediate unclean reboot** — data-loss
risk). Reboot is triggered by the operator / CeraUI, like the manual `ceralive-update`
path.

### Cross-slot marker clear (the task-29 brick #2 fix, for the hawkBit path)

`/data` is shared across A/B, so the `ceralive-update` script clears
`/data/ceralive/.slot-marked-good` after a manual `rauc install` — otherwise the old
slot's "good" marker makes the new slot's healthcheck a no-op and a **healthy update
rolls back**. The hawkBit path bypasses `ceralive-update`, so this layer ships its
own clear hook: `ceralive-hawkbit-marker-clear.path` watches
`/data/ceralive/rauc-downloads/*.raucb` and runs `ceralive-hawkbit-marker-clear.service`
(`rm -f /data/ceralive/.slot-marked-good`). Clearing when a bundle is downloaded is
race-safe: the running (healthy) slot's healthcheck already ran this boot; the new
slot re-proves health after reboot.

> On real hardware the deeper hook is RAUC's custom bootloader backend
> (`ceralive-rauc-boot-adapter set-primary`, task 27) — clearing the marker there
> would cover every install path. That file is out of task-41 scope; the path-unit
> here is the in-scope, self-contained equivalent.

## CeraLive systemd units (written by the postinst)

| Unit | Type | Role |
|------|------|------|
| `ceralive-hawkbit-provision.service` | oneshot | First-boot enrollment + config render (gated on `/data/ceralive/hawkbit.conf`). |
| `rauc-hawkbit-updater.service` (+ drop-in) | daemon | Polls DDI; gated on the rendered `/data` config; `-c` it. |
| `ceralive-hawkbit-marker-clear.path` + `.service` | path/oneshot | Clear `.slot-marked-good` when a bundle is downloaded (A/B correctness). |

## Verification (offline; no board / no real hawkBit)

- `shellcheck` clean on `provision-token.sh` (and the postinst twin).
- `config.conf` parses as a GLib key-file; the rendered effective config has no
  leftover `@PLACEHOLDER@` and carries the token only on `/data` (`0600`).
- Evidence: `.omo/evidence/task-41-ota.md` (enrollment + install path) and
  `.omo/evidence/task-41-ota-rollback.md` (gate / rollback reasoning).

## Related tasks

- **Task 40** — private hawkBit engine + `provision.sh` (DDI auth, R2 artifact URL).
- **Task 39** — `apt-worker` serves `/bundles/...` from R2 (range, content-type).
- **Task 29** — `ceralive-healthcheck.service` owns `rauc mark-good` (the gate).
- **Task 27 / 26** — RAUC custom bootloader backend + `system.conf` (`compatible`).
- **Task 30** — `/data` persistence + `ceralive-update` (manual install path).
