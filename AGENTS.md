# image-building-pipeline

Parent: [`../AGENTS.md`](../AGENTS.md)

## ROLE IN THE GROUP

Assembly hub for the device image. Pulls every device-side first-party component
(.deb packages from `srtla`, `srt`, `ceracoder`, `CeraUI`), drives a containerized
mkosi v26 build, and produces a flashable image for RK3588 targets (Orange Pi 5+,
Radxa Rock 5B+).

Relates to:
- `cert-work/` — GPG signing key injected into image; mTLS certs baked in; add-on keyring sourced from here
- `apt-worker/` — runtime apt source on device points to `apt.ceralive.tv` (Cloudflare R2); add-on `.raw` artifacts served from R2 path `addons/{os_version}/{board}/{feature}.raw`
- `versions.yaml` — pin registry; `fetch-debs.sh` reads pin versions from `../versions.yaml` [EXISTS]

## STRUCTURE

```
image-building-pipeline/
├── v2/                       # current build system (mkosi v26)
│   ├── build                 # entry point: ./v2/build <board>
│   ├── ci/
│   │   └── Dockerfile        # pinned debian:trixie-slim builder (mkosi 26)
│   ├── manifests/            # board and family manifests + package lists
│   │   └── schema/
│   │       └── addon.schema.json   # add-on descriptor JSON Schema (T21)
│   ├── lib/                  # orchestrate.sh, assemble-disk.sh, build-bundle.sh,
│   │   │                     #   build-all.sh (parallel runner), build-feature-sysext.sh,
│   │   │                     #   measure-size.sh, parity-check.sh, …
│   │   └── app-layer/
│   │       └── sysext.sh     # sysext build lib (extract → prune → squashfs)
│   ├── docs/                 # dev-loop.md, kiosk-display.md, host-support.md,
│   │   │                     #   size-notes.md, cog-display-addon.md,
│   │   │                     #   addon-sysext-refresh.md, deferred items
│   │   └── fast-reload.md    # dev-sync live-reload loop
│   └── tests/                # manifest.bats, preflash-verify.sh, qemu-x86.sh
├── scripts/
│   └── fetch-debs.sh         # downloads .deb packages for REPOS array
└── CONTRIBUTING.md           # contribution rules
```

## WHERE TO LOOK

| Task | Location |
|------|----------|
| Start a build | `./v2/build <board>` — see [`v2/docs/dev-loop.md`](v2/docs/dev-loop.md) |
| Add/change .deb packages | `scripts/fetch-debs.sh` → `REPOS` array |
| Board/kernel customisation | `v2/manifests/boards/<board>.yaml` |
| Contribution rules | [`CONTRIBUTING.md`](CONTRIBUTING.md) |
| **Dev-sync live-reload loop** | [`v2/docs/dev-loop.md`](v2/docs/dev-loop.md) |
| Manifest schema / validation | `v2/manifests/schema/{board,family}.schema.json` (enforced by `v2/lib/resolve.py`; an invalid manifest fails at validation, not at build) |
| v2 unit tests / x86 boot fallback | `v2/tests/manifest.bats` via `v2/run-tests`; forced-primary-failure rollback proof: `v2/tests/qemu-x86.sh --fallback-selftest` |
| **Kiosk display stack (chassis)** | [`v2/docs/kiosk-display.md`](v2/docs/kiosk-display.md) — units, packages, OOM, wvkbd build |
| Cross-repo kiosk architecture | [`CeraUI/docs/ON_DEVICE_DISPLAY.md`](../CeraUI/docs/ON_DEVICE_DISPLAY.md) — DC-1..DC-4, Phase-3 deferral register |
| **Build host support matrix** | [`v2/docs/host-support.md`](v2/docs/host-support.md) — which hosts work, what they need |
| **Image size notes / levers** | [`v2/docs/size-notes.md`](v2/docs/size-notes.md) — locale strip, firmware audit, size-gate |
| **Cog display add-on recipe** | [`v2/docs/cog-display-addon.md`](v2/docs/cog-display-addon.md) — Cog+WPEWebKit packaging, libmali strategy |
| **sysext refresh protocol** | [`v2/docs/addon-sysext-refresh.md`](v2/docs/addon-sysext-refresh.md) — update/disable lifecycle |
| Add-on descriptor schema | `v2/manifests/schema/addon.schema.json` |
| Build a feature sysext add-on | `v2/lib/build-feature-sysext.sh` |

## KEY FACTS

**Build entry point** [EXISTS]

The **container build is the canonical path.** The orchestrator runs mkosi v26
inside a pinned `debian:trixie-slim` builder (`v2/ci/Dockerfile`). Native builds
(`--native` / `MKOSI_NATIVE=1`) are opt-in and require mkosi ≥ 26 + Python ≥ 3.12
on a Debian trixie+ host. See [`v2/docs/host-support.md`](v2/docs/host-support.md)
for the full host matrix.

```bash
./v2/build <board>                       # single board, e.g. ./v2/build rock-5b-plus
./v2/build --all                         # every manifest in manifests/boards/
./v2/build --only rock-5b-plus,x86-minipc  # validated subset
DRY_RUN=1 ./v2/build <board>             # resolve + fetch plan only
./v2/build <board> --native              # opt-in native build (trixie+ host only)
MKOSI_NATIVE=1 ./v2/build <board>        # same, env-var form
```

Entry: `v2/build` → `v2/lib/orchestrate.sh`. Produces `.raw` sysext bundles and
`.raucb` A/B RAUC OTA packages. See [`v2/docs/dev-loop.md`](v2/docs/dev-loop.md).

**Multi-board dispatch** [EXISTS]

Dispatch is by the **count of resolved boards**, not the flag: a single resolved
board (`<board>`, or `--only`/`--all` that resolves to exactly one) execs the
orchestrator directly; a multi-board selection is handed to the parallel runner
`v2/lib/build-all.sh`. An unknown board in `--only` exits non-zero, names the
offender, and lists the available boards — it is never silently skipped.

**REPOS array — case and order are sacred**
```bash
REPOS=("srtla" "srt" "ceracoder" "CeraUI")
```

**CI vs local .deb fetch**
- `R2_ACCESS_KEY_ID` set → fetch from R2 (`dists/{CHANNEL}/binary-{ARCH}/`)
- unset → `gh release download` from GitHub releases

**versions.yaml** [EXISTS]
`fetch-debs.sh` reads pin versions from `../versions.yaml` instead of resolving latest.
Don't hardcode versions in the script.

**Reproducible builds** [EXISTS]
Same source state → bit-identical `.raucb`. The orchestrator pins one
`SOURCE_DATE_EPOCH` (env override → HEAD commit time → frozen fallback, via
`common.sh::resolve_source_date_epoch`) and exports it so every embedded mtime
(rootfs.tar, squashfs, ext4, mkosi) clamps to it. `build-bundle.sh` signs the RAUC
bundle through a deterministic OpenSSL CMS path (`-noattr` → no wall-clock
`signingTime`; real leaf key + chain, still `rauc`-verifiable) because `rauc`
itself bakes an uncontrollable CMS timestamp. `REPRODUCIBLE=0` opts back into the
native `rauc bundle` signer (NOT bit-reproducible). Proof: `v2/run-tests` section
11; double-build the same board and compare `.raucb` sha256.

**Image size gate — BLOCKING at 1.5 GB** [EXISTS]

`v2/lib/measure-size.sh` runs after every build. If the compressed rootfs exceeds
**1.5 GB** the build fails loudly and the `.raucb` is not produced. The threshold
is post-slim (locale strip + `WithDocs=no` already applied). See
[`v2/docs/size-notes.md`](v2/docs/size-notes.md) for the levers used to reach it.

## ADD-ON SUBSYSTEM [EXISTS]

Feature sysexts are optional, per-board/per-OS `.raw` artifacts delivered
out-of-band from the base image. They extend `/usr` and `/opt` only
(`SYSEXT_LEVEL=1`, `VERSION_ID=12`) and are managed at runtime by the CeraUI
add-on manager.

**Descriptor format** (`v2/manifests/schema/addon.schema.json`)

Each add-on ships a JSON descriptor baked into the image at
`/usr/share/ceralive/addons/<id>.json`. Required fields:

| Field | Description |
|-------|-------------|
| `id` | Lowercase alphanumeric + hyphens; unique per image |
| `version` | Semver `MAJOR.MINOR.PATCH` |
| `category` | `debug` / `display` / `media` / `network` / `other` |
| `payload.type` | `sysext` (only implemented type; `appfs` reserved) |
| `artifact.urlTemplate` | HTTPS URL with `{os_version}` placeholder |
| `artifact.sha256` | Lowercase hex SHA-256 of the `.raw` |
| `artifact.gpgSigRef` | Reference to the detached GPG signature |
| `artifact.sizeDownload` | Compressed `.raw` size in bytes |
| `artifact.sizeInstalled` | Installed size in bytes |
| `sysext.paths` | List of `/usr/…` or `/opt/…` paths the sysext provides |
| `deps` / `conflicts` | Optional add-on id arrays (uniqueItems) |

**Signing contract** [EXISTS]

Every `.raw` artifact is signed with the add-on keyring GPG key from `cert-work/`.
The signature is a detached `.sig` file co-located with the `.raw` on R2. CeraUI
verifies the GPG signature and the `sha256` field before activating any add-on.
The keyring is baked into the image at build time via `build-feature-sysext.sh`.

**Build a feature sysext** [EXISTS]

```bash
# Build a signed per-board/per-OS sysext .raw:
v2/lib/build-feature-sysext.sh \
  --descriptor v2/manifests/addons/<id>.sysext.conf \
  --board rock-5b-plus \
  --out dist/
# Output: dist/<id>-<board>-<os_version>.raw + dist/<id>-<board>-<os_version>.raw.sig
```

The builder reuses `v2/lib/app-layer/sysext.sh` (extract → prune Platform/Runtime
libs → assert required binaries → squashfs). The exclusion contract
(`SYSEXT_EXCLUDE_NAMES`) prevents GPU/BSP userspace from leaking into add-on
artifacts.

**R2 delivery path**

```
addons/{os_version}/{board}/{feature}.raw
addons/{os_version}/{board}/{feature}.raw.sig
```

`os_version` is the Debian `VERSION_ID` (e.g. `12` for bookworm). The
`{os_version}` placeholder in `artifact.urlTemplate` is substituted at download
time by the CeraUI add-on manager.

**sysext refresh protocol** — see [`v2/docs/addon-sysext-refresh.md`](v2/docs/addon-sysext-refresh.md)

Services SURVIVE `systemd-sysext refresh` but keep running the old binary. The
add-on manager must:
- **Update:** `systemd-sysext refresh` → `systemctl restart <addon>.service`
- **Disable:** `systemctl stop <addon>.service` → `systemd-sysext refresh`

Never report an add-on "updated" or "disabled" on the strength of the sysext call
alone.

## KIOSK STACK

The image ships a kiosk display stack (cage + Chromium + wvkbd) **installed but inert by default**. All kiosk units are masked at first boot. CeraUI enables kiosk mode at runtime via systemctl — no reflash needed.

**Repo boundary (DC-1):** the image owns the chassis (units, packages, OOM config, `OnFailure` handler). CeraUI owns the content, control, and lifecycle state (toggle RPC, token mint, state machine).

**Cog display add-on (W4):** Cog + WPEWebKit is validated as a lighter alternative
display engine, packaged as a feature sysext add-on. Acquisition path: plain `apt`
from bookworm `main` (`cog` 0.16.1, `libwpewebkit-1.1-0` 2.38.6). The Mali-G610
GPU userspace (`libmali-valhall-g610-*`) is Platform-layer and excluded from the
sysext by contract. Full recipe: [`v2/docs/cog-display-addon.md`](v2/docs/cog-display-addon.md).
**Hardware-gated:** `cog.sysext.conf` wired into the build only after RK3588 render
QA passes (same gate as Tasks 26/27/28).

**Implementation status:** Tasks 26 (systemd units), 27 (packages), 28 (RK3588 dual-GPU udev + touch calibration), and 30 (integration validation) are **hardware-blocked** — no RK3588 board is reachable from the dev environment (Task 1 spike: NO-GO). The architecture is fully specced; implementation waits for hardware access.

**Phase-3 deferrals:** e-ink kernel DRM driver + device-tree, dual-display hybrid, on-device live-video preview, and #61 battery/power telemetry (document-only: current boards are mains-powered, no fuel-gauge IC). Full register: [`v2/docs/kiosk-display.md §7`](v2/docs/kiosk-display.md).

## ANTI-PATTERNS

- Don't change REPOS order or casing — downstream scripts key on exact names
- Don't add `ceralive-platform` to REPOS — cloud-only, not in device image
- Don't commit GPG private keys or mTLS certs — those come from `cert-work/` at build time
- Don't implement kiosk units/packages without clearing the Task 1 hardware gate first
- Don't use `--native` as the default build path — container is canonical; native is opt-in
- Don't put GPU/BSP userspace (`libmali*`, `librockchip_mpp*`) in any add-on sysext — Platform-layer only
- Don't touch runtime apt sources on the device — `E4` guardrail
- Don't let add-ons gate OTA healthcheck/rollback — add-ons are orthogonal to the RAUC A/B slot

## KNOWN ISSUES / DEFERRED

**OPi 5+ interface ID_PATHs are FIXME placeholders.** `manifests/boards/orange-pi-5-plus.yaml`
ships the `interfaces:` block with `FIXME-…` values because the board is not in
hand. The OPi 5+ has two onboard r8169 NICs on the same driver/bus, so a generic
`Type=ether` match races. Before building an OPi 5+ image, read the real ID_PATHs
on the device (`udevadm info /sys/class/net/<iface> | grep ID_PATH`) and replace
each FIXME. Until then `install_interface_naming()` skips the FIXME values and
emits only the generic `Type=wlan → wlan0` rule; the dual NICs stay
non-deterministic.

**Modem source-routing may not fire (NM `dhcp=internal`).** The SRTLA dhclient
exit hook (`/etc/dhcp/dhclient-exit-hooks.d/srtla-source-routing`) installs
per-modem source-policy routes on DHCP `BOUND` events. NetworkManager in Debian
bookworm defaults to `dhcp=internal` (its own DHCP client), which does NOT execute
`dhclient-exit-hooks.d/`. Modem routing may therefore never trigger for
NM-managed interfaces. The wifi path is unaffected (it uses the NM dispatcher,
`/etc/NetworkManager/dispatcher.d/90-srtla-wifi-routing`). Verify with a modem
attached: check `journalctl -t srtla-routing` and `ip rule show` after the modem
connects. If the hook doesn't fire, extend `90-srtla-wifi-routing` to also match
`usb*|wwan*` and assign tables 100–107 by index — but that touches the
drift-gated SRTLA payloads (`v2/ci/postinst-drift-check.sh` CHECK 2) and requires
a deliberate twin-update of both `networking-srtla.sh` and the `§6` block in
`mkosi.postinst.chroot`.

**Modem `usb0..7` naming is hardware-gated.** Deterministic modem renames need a
physical modem to read its ID_PATH; not implemented here. Only `eth0/eth1/wlan0`
are pinned today.

**Cog render QA hardware-gated.** `cog.sysext.conf` + build wrapper are inert
scaffolds until a physical RK3588 validates render (OKLCH/Tailwind v4 on WebKit
2.38.6, Mali-G610 EGL/GBM wiring). See [`v2/docs/cog-display-addon.md §7`](v2/docs/cog-display-addon.md).
