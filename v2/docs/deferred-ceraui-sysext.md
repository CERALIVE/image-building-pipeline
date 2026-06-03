# Deferred: make CeraUI sysext-ready

> **SCOPE FENCE — this is a CeraUI-REPO task, NOT image-building-pipeline work.**
> Every change below is to the `CeraUI/` repository (its `.deb` install layout and
> systemd/udev integration). The pipeline already ships CeraUI correctly **today**
> via the appfs backend (`v2/mkosi/app/build-ceraui-appfs.sh`). Nothing in this doc
> blocks the pipeline; it is the precise spec the CeraUI repo must implement before
> CeraUI can move from the appfs backend to the sysext backend. **Do not implement
> any of this inside `image-building-pipeline/`.**

## Why CeraUI is on appfs, not sysext

A `systemd-sysext` extension overlays **only `/usr` and `/opt`**. It cannot merge
`/etc` or `/var` — those paths are silently dropped from the merged tree (task-4
boundary map). CeraUI's current `.deb` (`CeraUI/scripts/build/build-debian-package.sh`)
installs to:

| Path | Backend-merges under sysext? | What it is |
|------|------------------------------|------------|
| `/usr/local/bin/ceralive` | ✅ `/usr` | Bun `--compile` backend binary (FFI host) |
| `/usr/local/bin/override-belaui.sh`, `/usr/local/bin/reset-to-default.sh` | ✅ `/usr` | maintenance scripts |
| `/etc/systemd/system/ceralive.service` | ❌ `/etc` dropped | systemd unit |
| `/etc/systemd/system/ceralive.socket` | ❌ `/etc` dropped | socket activation |
| `/etc/udev/rules.d/98-ceralive-audio.rules` | ❌ `/etc` dropped | audio device rules |
| `/etc/udev/rules.d/99-ceralive-check-usb-devices.rules` | ❌ `/etc` dropped | USB capture rules |
| `/etc/ceralive/config.json` | ❌ `/etc` dropped | runtime config |
| `/var/www/ceralive/` | ❌ `/var` dropped | PWA static assets (web root) |

A sysext build of this tree (`v2/lib/app-layer/sysext.sh::build_app_layer` copies
**only** `/usr`+`/opt`) would ship a binary with **no unit to start it, no udev
rules, no config, and no web root** — an unstartable, unreachable UI. Hence appfs
(full-filesystem payload) is the only viable backend until the relocations below.

## Required CeraUI-repo changes

Each item moves a payload from a non-mergeable path into a sysext-mergeable one
(or onto confext for the genuinely host-mutable bits). All edits are in the CeraUI
`.deb` packaging (`scripts/build/build-debian-package.sh` + the unit/udev source
files), never in this pipeline.

### 1. systemd units → `/usr/lib/systemd/system/`

Move `ceralive.service` and `ceralive.socket` out of `/etc/systemd/system/` into
`/usr/lib/systemd/system/` (the vendor unit dir, which **is** sysext-mergeable).

- Update the `.deb` packaging dir from `etc/systemd/system/` to
  `usr/lib/systemd/system/`.
- `WorkingDirectory=`/`ExecStart=` must point at `/usr`-resident paths once the
  binary and web root move (items 4–5); no `/etc` or `/var` runtime dependency in
  the unit itself.
- `/etc/systemd/system/` stays available for **operator** overrides only
  (`systemctl edit`), which is correct — vendor units belong in `/usr/lib`.

### 2. udev rules → `/usr/lib/udev/rules.d/`

Move `98-ceralive-audio.rules` and `99-ceralive-check-usb-devices.rules` from
`/etc/udev/rules.d/` to `/usr/lib/udev/rules.d/` (the vendor rules dir — udev reads
both, and only the `/usr/lib` one is sysext-mergeable). `/etc/udev/rules.d/`
remains for host-local overrides only.

### 3. default config → `/usr/share/ceralive/config.json.default` + confext overlay

`/etc/ceralive/config.json` is **host-mutable runtime state** (the device writes to
it), so it cannot simply move to read-only `/usr`. Split it:

- Ship the **immutable default** as
  `/usr/share/ceralive/config.json.default` (sysext-mergeable, read-only).
- Materialize the live `/etc/ceralive/config.json` from the default via **confext**
  (a `systemd-confext` extension overlays `/etc` the way sysext overlays `/usr`),
  **or** a `ConditionPathExists=!` `ExecStartPre=` seed step that copies the default
  on first boot if the operator config is absent.

> **HARD BLOCKER — confext needs systemd ≥ 253.** `systemd-confext` shipped in
> **systemd v253 (Feb 2023)**. The device base OS is **Debian bookworm, which ships
> systemd v252** — confext is **NOT available**. So the confext route requires
> **upgrading the base OS beyond bookworm** (e.g. trixie / a systemd ≥253 backport)
> first. Until the base is upgraded, only the first-boot-seed fallback (no `/etc`
> overlay) is workable, and `/etc/ceralive/config.json` cannot be delivered by the
> extension at all — it must be seeded at runtime. This is the single largest reason
> the sysext migration is deferred and not "just a path move".

### 4. web root → `/usr/share/ceralive/www/` (or `/opt/ceralive/www/`)

Move the PWA static assets from `/var/www/ceralive/` to a `/usr`- or `/opt`-resident
path (`/usr/share/ceralive/www/` preferred; `/opt/ceralive/www/` also sysext-mergeable).
Update the backend's static-serve root accordingly. `/var/www/` is **state**, not
program data — read-only `/usr/share` (or `/opt`) is the correct home and it merges.

### 5. binary location (optional tidy)

`/usr/local/bin/ceralive` already merges (it is under `/usr`), so it is **not** a
blocker. For convention, consider `/usr/bin/ceralive` or `/opt/ceralive/bin/ceralive`
to keep all first-party binaries off `/usr/local` (which is conventionally
host-local). Low priority — purely cosmetic for sysext-readiness.

## Post-migration: extension-release + FFI restart

Once relocated, the CeraUI sysext build follows the same `sysext.sh` contract as
ceracoder/srtla:

- The build writes `/usr/lib/extension-release.d/extension-release.ceraui` with
  `ID=<os-id>` + `VERSION_ID=<os-version>` matching the (upgraded) host os-release,
  or the kernel refuses to merge it.
- `refresh_app_layer` already restarts `ceralive.service` after a sysext refresh —
  unchanged and still required, because CeraUI holds **in-process native FFI** to
  ceracoder/srtla and must reload after their binaries swap.

## FFI / sibling-checkout note (unchanged by this migration)

CeraUI's `link:../../../ceracoder/bindings/typescript` and
`link:../../../srtla/bindings/typescript` sibling-checkout (ARCHITECTURE.md §5) is a
**CeraUI build-time** concern — the bindings are compiled into the Bun binary before
packaging. The sysext migration does **not** touch that layout, and neither backend
(appfs today, sysext later) changes how the FFI resolves on-device: ceracoder/srtla
binaries come from their sysext into the merged `/usr/bin`, and `libsrt` comes from
the runtime OS slot's `/usr/lib`.

## Acceptance checklist (for the CeraUI-repo task)

- [ ] units in `/usr/lib/systemd/system/`, not `/etc/systemd/system/`
- [ ] udev rules in `/usr/lib/udev/rules.d/`, not `/etc/udev/rules.d/`
- [ ] default config at `/usr/share/ceralive/config.json.default`
- [ ] live `/etc/ceralive/config.json` delivered via confext (**requires base OS
      systemd ≥ 253 — base upgrade beyond bookworm**) or first-boot seed
- [ ] web root at `/usr/share/ceralive/www/` (or `/opt/ceralive/www/`)
- [ ] backend static-serve root + unit `WorkingDirectory`/`ExecStart` updated to the
      new `/usr` paths
- [ ] `dpkg-deb -x` of the new `.deb` has **no** `ceralive`-owned files under `/etc`
      or `/var` (except operator-override dirs left intentionally empty)
- [ ] pipeline flip: set the CeraUI manifest/app backend to `sysext` and replace
      `build-ceraui-appfs.sh` with a `build-ceraui-sysext.sh` (a one-line wrapper
      over the shared `sysext.sh` backend, mirroring ceracoder/srtla) — **this flip
      is the only pipeline-side change, and only AFTER all the above land**

## References

- `v2/mkosi/app/build-ceraui-appfs.sh` — current (appfs) packaging
- `v2/lib/app-layer/{interface,sysext,appfs}.sh` — the 3-verb / 2-backend contract
- `v2/mkosi/LAYER-MAP.md` §Layer 4 (app) and §libsrt — layer boundaries
- `CeraUI/scripts/build/build-debian-package.sh` — the `.deb` layout to change
- `ARCHITECTURE.md` §5 — `link:../../../` sibling-checkout requirement
- `.omo/notepads/image-platform-redesign/learnings.md` — task-4 sysext boundary,
  task-21 backend contract, bookworm-systemd-252 / confext-253 constraint
