# image-building-pipeline

Parent: [`../AGENTS.md`](../AGENTS.md)

## ROLE IN THE GROUP

Assembly hub for the device image. Pulls every device-side first-party component
(.deb packages from `srtla`, `srt`, `cerastream`, `CeraUI`), drives a
containerized mkosi v26 build, and produces a flashable image for RK3588 targets
(Orange Pi 5+, Radxa Rock 5B+).

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
│   │   │                     #   cog-display-hw-checklist.md,
│   │   │                     #   addon-sysext-refresh.md, DEFERRED.md
│   │   └── fast-reload.md    # dev-sync live-reload loop
│   └── tests/                # manifest.bats, preflash-verify.sh, qemu-x86.sh
├── docs/
│   ├── FIRST-BOOT.md         # operator first-boot guide: flash → WiFi portal → SSH → CeraUI [EXISTS]
│   ├── DEVICE-BRINGUP.md     # developer bring-up guide: build, flash, dev loop, E2E smoke test
│   └── partition-contract.md # frozen GPT layout contract
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
| **Operator first-boot guide** | [`docs/FIRST-BOOT.md`](docs/FIRST-BOOT.md) — flash → WiFi portal → SSH → CeraUI |
| **Dev-sync live-reload loop** | [`v2/docs/dev-loop.md`](v2/docs/dev-loop.md) |
| Manifest schema / validation | `v2/manifests/schema/{board,family}.schema.json` (enforced by `v2/lib/resolve.py`; an invalid manifest fails at validation, not at build) |
| v2 unit tests / x86 boot fallback | `v2/tests/manifest.bats` via `v2/run-tests`; forced-primary-failure rollback proof: `v2/tests/qemu-x86.sh --fallback-selftest` |
| **x86 ESP + GRUB A/B disk assembly** | `v2/lib/assemble-disk-x86.sh` (offline producer); `v2/mkosi/platform/x86/{install-x86-grub.sh,grub-ab.cfg,10-esp.conf}`; offline proof `v2/mkosi/platform/x86/test-x86-grub.sh`; rationale in [`v2/mkosi/platform/x86/README.md`](v2/mkosi/platform/x86/README.md) §2 |
| **Kiosk display stack (chassis)** | [`v2/docs/kiosk-display.md`](v2/docs/kiosk-display.md) — units, packages, OOM, wvkbd build |
| Cross-repo kiosk architecture | [`CeraUI/docs/ON_DEVICE_DISPLAY.md`](../CeraUI/docs/ON_DEVICE_DISPLAY.md) — DC-1..DC-4, Phase-3 deferral register |
| **Build host support matrix** | [`v2/docs/host-support.md`](v2/docs/host-support.md) — which hosts work, what they need |
| **Image size notes / levers** | [`v2/docs/size-notes.md`](v2/docs/size-notes.md) — locale strip, firmware audit, size-gate |
| **Cog display add-on recipe** | [`v2/docs/cog-display-addon.md`](v2/docs/cog-display-addon.md) — Cog+WPEWebKit packaging, libmali strategy |
| **Cog on-hardware render QA checklist** | [`v2/docs/cog-display-hw-checklist.md`](v2/docs/cog-display-hw-checklist.md) — ready-to-run RK3588 render gate (software path proven in `test-results/task-39-cog-qa.txt`) |
| **sysext refresh protocol** | [`v2/docs/addon-sysext-refresh.md`](v2/docs/addon-sysext-refresh.md) — update/disable lifecycle |
| **Deferred / hardware-gated items** | [`v2/docs/DEFERRED.md`](v2/docs/DEFERRED.md) — index of every deferred item with file:line anchors and unblock conditions |
| Add-on descriptor schema | `v2/manifests/schema/addon.schema.json` |
| Build a feature sysext add-on | `v2/lib/build-feature-sysext.sh` |
| Publish a signed add-on to R2 | `v2/lib/upload-addons.sh` (CI: `v2-ci.yml` `addon-publish` job) |

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

**x86 disk assembly — full A/B GRUB (Task 12)** [EXISTS]

`v2/build x86-minipc` now produces a flashable `.raw` with RAUC **A/B** boot (was:
deferred `TODO(x86-disk)`, rootfs.tar only). x86 boots UEFI → GRUB from an EFI System
Partition with RAUC's **native `bootloader=grub`** backend: `lib/assemble-disk-x86.sh`
(the offline x86 producer, parallel to the RK3588 `assemble-disk.sh`) lays the ESP
(`grub-mkstandalone` removable-path `/EFI/BOOT/BOOTX64.EFI` + `grub.cfg` + `grubenv`)
plus the **FROZEN** `rootfs_a`/`rootfs_b`/`data` slots — `repart/` and the RK3588
assembly stay zero-diff (G3/SC6). The earlier `bootloader=custom` countdown scaffold
is RETAINED, unchanged, only as the offline rollback-contract harness
(`qemu-x86.sh --fallback-selftest`, `test-x86-fallback.sh`). Full rationale +
VERIFY-FIRST finding: [`v2/mkosi/platform/x86/README.md`](v2/mkosi/platform/x86/README.md) §2.
The signed `.raucb` OTA bundle for x86 is a documented follow-up (`build-bundle.sh`
covers the RK3588 path today).

**Multi-board dispatch** [EXISTS]

Dispatch is by the **count of resolved boards**, not the flag: a single resolved
board (`<board>`, or `--only`/`--all` that resolves to exactly one) execs the
orchestrator directly; a multi-board selection is handed to the parallel runner
`v2/lib/build-all.sh`. An unknown board in `--only` exits non-zero, names the
offender, and lists the available boards — it is never silently skipped.

**REPOS array — case and order are sacred**
```bash
REPOS=("srtla" "srt" "cerastream" "CeraUI" "srtla-send-rs")
```
`cerastream` is the sole streaming engine — `ceracoder` was retired 2026-06-11
after the generic boot-parity profile passed
(`cerastream/docs/notes/boot-parity-results.md`); the hardware-gated profiles
(Jetson/RK3588) now track as cerastream hardware validation. `srtla-send-rs` is
the Rust sender fork (v1.0.0+) added at cutover (Task 20); `srtla` .deb provides
receiver-only after cutover. **Conflict declaration:** `srtla-send-rs` declares
`Conflicts: srtla (<< 2026.7.0)`; `srtla` v2026.6.2 << 2026.7.0 is TRUE, so
coinstall is blocked correctly until the srtla cutover release. REPOS lives in
`v2/lib/fetch-debs.sh`.

**First-party .deb fetch — build-time apt pull from apt.ceralive.tv** [EXISTS]

`fetch_first_party` (in `v2/lib/fetch-debs.sh`) pulls the device first-party
`.deb`s from `apt.ceralive.tv` via a GPG-verified, mTLS-authenticated apt source —
this REPLACES the retired R2 `aws s3 sync` (CI) and `gh release download` (local)
paths. It mirrors `v2/mkosi/customize/apt-ceralive-repo.sh`: a deb822 source
(`URIs: …/dists/{CHANNEL}/`, `Suites: ./`, GPG `Signed-By`), the GPG keyring and
the mTLS client cert/key injected from the environment, all in an **isolated apt
state** under the staging dir (the host apt config is never touched).

- **Packages staged** (`FIRST_PARTY_APT_PKGS`): exactly the four top-level
  packages `cerastream ceralive-device srtla srtla-send-rs` are `apt-get
  download`ed into `$DEST/debs/`. These are Debian **Package** names — a deliberate
  mapping off `REPOS` (the directory/pin names), notably `CeraUI → ceralive-device`.
- **`srt` is dependency-resolved, not staged.** The libsrt fork (`srt`), like
  `gstlibuvch264src` and the `libgstreamer*` plugins, is resolved by the app
  layer's own `apt-get install` from `apt.ceralive.tv` + bookworm `main` at install
  time (`mkosi.images/app/mkosi.postinst.chroot`), so it is intentionally not a
  download target here.
- **Secrets are env-only, base64-encoded** (same names as the device customize
  script): `APT_GPG_PUBLIC_B64`, `APT_CLIENT_CRT_B64`, `APT_CLIENT_KEY_B64`. They
  are NEVER hardcoded, NEVER logged, NEVER committed; a half-supplied mTLS pair is
  fatal. `APT_CERALIVE_URL` (default `https://apt.ceralive.tv`) is overridable.
- **Arch axis only** — the source carries no board axis; `arch` is selected by
  `APT::Architecture` (apt-worker two-axis model: `channel × arch`).
- **DRY_RUN** logs the exact `apt-get … download cerastream ceralive-device srtla
  srtla-send-rs` plan + source and downloads nothing. With no `APT_GPG_PUBLIC_B64`
  in the env the fetcher auto-enables DRY_RUN (no credential for a verified fetch).
- **BSP fetch is unchanged** — kernel/DTB/U-Boot/firmware/gstreamer still come from
  the Armbian apt pool (`fetch_bsp`).

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
addons/{os_version}/{board}/{feature}.raw.sha256
addons/{os_version}/{board}/{feature}.raw.sig
```

`os_version` is the Debian `VERSION_ID` (e.g. `12` for bookworm). The
`{os_version}` placeholder in `artifact.urlTemplate` is substituted at download
time by the CeraUI add-on manager. `apt-worker` serves these keys (404 on a
missing object, never a 200-empty); see `apt-worker/AGENTS.md`.

**Publishing** [EXISTS]

`v2/lib/upload-addons.sh` publishes a signed add-on to R2, mapping
`build-feature-sysext.sh`'s `<feature>-<board>-<os_version>.raw{,.sha256,.sig}`
onto the delivery path above. It REFUSES to upload an unsigned (or
unchecksummed) artifact, and pins per-file content-type so R2 stores what the
worker serves. CI mode reuses the `fetch-debs.sh` R2 pattern (`aws s3 cp`
+ `R2_ENDPOINT`); the `v2-ci.yml` `addon-publish` job proves the plan +
unsigned-refusal gate under `DRY_RUN` without secrets.

**sysext refresh protocol** — see [`v2/docs/addon-sysext-refresh.md`](v2/docs/addon-sysext-refresh.md)

Services SURVIVE `systemd-sysext refresh` but keep running the old binary. The
add-on manager must:
- **Update:** `systemd-sysext refresh` → `systemctl restart <addon>.service`
- **Disable:** `systemctl stop <addon>.service` → `systemd-sysext refresh`

Never report an add-on "updated" or "disabled" on the strength of the sysext call
alone.

**First-boot SSH hardening** [EXISTS]

`ceralive-ssh-firstboot.service` runs once `Before=ssh.service ssh.socket` on
first boot. Standalone artifacts under `v2/mkosi/runtime/`
(`ceralive-ssh-firstboot.{sh,service}`), installed by
`postinst-lib.sh::setup_ssh_firstboot` — NOT inlined in `mkosi.postinst.chroot`
(the drift gate's 950-line ceiling). Scope is locked (SC4): regenerate the baked
shared host keys into a per-device identity (persisted on `/data`, stable across
A/B), `PermitRootLogin prohibit-password`, and a once-only `chage -d 0 ceralive`.
The `ceralive` user ships password-locked (no default password); root retains
key-based recovery access. Full behaviour: [`v2/docs/ssh-hardening.md`](v2/docs/ssh-hardening.md).

**First-boot WiFi provisioning portal** [PARTIAL]

`ceralive-provision.service` brings up a self-hosted WPA2 setup hotspot AND a
captive portal so a headless, never-configured device can be handed WiFi
credentials with no screen or keyboard. Standalone artifacts under
`v2/mkosi/runtime/` (`ceralive-provision.{sh,service}` plus the captive portal
`ceralive-portal.{sh,socket,@.service}`), installed by
`postinst-lib.sh::setup_provisioning` — NOT inlined in `mkosi.postinst.chroot`
(drift-gate 950-line ceiling; `setup_provisioning` is in the gate's
`CONSOLIDATED_FUNCS`). Full end-to-end flow:
[`v2/docs/wifi-provisioning.md`](v2/docs/wifi-provisioning.md).

- **Trigger** (runtime decision, not a static unit Condition): the AP starts IFF
  there are **no stored (non-AP) NM WiFi profiles** on `/data` **AND** no link-up
  connectivity appears within a **60-90s boot grace window** (default 75s). Either
  a stored profile or any connectivity (NM `full`/`limited`/`portal`, or a default
  route) suppresses it. A `/data/ceralive/provision/force-portal` flag
  (factory-reset hook) re-triggers it even when profiles exist.
- **EC4 — OTA-safe:** a RAUC update that preserves `/data` keeps the WiFi profiles,
  so the portal correctly does **not** start after an update.
- **Conflict safety:** the AP only runs when there is zero connectivity (so srtla
  bonding is impossible anyway), and it leaves `wlan0` with no default route, so the
  srtla NM dispatcher (`90-srtla-wifi-routing`) sees an empty gateway and writes no
  rule/route in table 120 — a no-op while the portal is up. WiFi tables 120-124 are
  untouched.
- **AP mode:** NetworkManager-native (`802-11-wireless.mode ap` + `ipv4.method
  shared`) — no extra packages (NM drives wpa_supplicant + its internal dnsmasq;
  `network-manager`/`dnsmasq`/`wpasupplicant` already ship). `hostapd` stays in the
  image only as an evidence-gated fallback. SSID `CeraLive-Setup-<short-id>`
  (machine-id-derived, like the hostname service), passphrase `ceralive-setup`
  (documented default), gateway `192.168.42.1/24`. **HW caveat:** AP mode also
  requires the onboard wlan driver to support it (RK3588 chip dependent) — to be
  validated on hardware, hence `[PARTIAL]`.
- **Captive portal (Task 14):** while the AP is up, `ceralive-provision` stops the
  CeraUI backend (`ceralive.service`) to free port 80 and starts
  `ceralive-portal.socket` — a systemd socket-activated (`Accept=yes`) **bash** HTTP
  handler on `192.168.42.1:80`. It is the lightest server already in the image (no
  busybox/python3/socat/nc ship — socat/netcat were moved to the debug add-on), and is
  a standalone plain-HTML page, NOT a CeraUI integration (SC2). A
  `address=/#/192.168.42.1` drop-in in `dnsmasq-shared.d` wildcard-captures DNS so any
  hostname pops the operator's captive-portal sign-in. The form's SSID list is the
  pre-AP scan cache (a single radio can't scan in AP mode) plus free-text entry.
- **Credential handoff:** the form POST writes the user's network via
  `nmcli connection add` (credentials land ONLY in NM's `/data`-backed store — never a
  file), answers the browser, then runs a DETACHED `ceralive-provision connect <con>`
  worker (via `systemd-run`, so it outlives the per-connection service that the AP
  teardown kills). The worker drops the AP, joins as a client under a bounded
  `nmcli --wait` + `timeout`, and on a wrong passphrase or hard timeout deletes the bad
  profile, writes a `last-error` marker the portal shows, and re-arms the AP for a
  retry — the device is never left headless-dead.
- **Port-80 coexistence:** the portal owns `192.168.42.1:80` only during provisioning;
  CeraUI's backend (binds `[80, 8080, 81]`, tries 80 first) is stopped for the window
  and restarted on teardown so it re-binds 80 on the new uplink IP. The Task-15 nginx
  TLS front on **443** is unaffected (its `127.0.0.1:80` upstream is just briefly down
  while there is no uplink — and thus no 443 client).
- **Teardown — MAC6 end-state (all four, sandbox-verified):** (a) AP profile deleted;
  (b) device joined the target network; (c) portal unreachable (`ceralive-portal.socket`
  stopped, port 80 freed); (d) CeraUI reachable on the new IP (`ceralive.service`
  restarted). A successful `connect` runs the teardown **keeping** the freshly-joined
  client link; the out-of-band `ceralive-provision teardown` verb (or a
  `/data/ceralive/provision/teardown-requested` flag) also releases `wlan0` and clears
  the portal-active + force flags. Plain `systemctl stop` (ExecStop) is link-down +
  portal-down only and RETAINS the AP profile + flags (shutdown must not disarm a
  pending factory reset). Offline proof harness:
  `v2/tests/provision-portal.test.sh` (gated in `manifest.bats`).

**CeraUI TLS front — nginx on 443 (Task 15, SC3)** [EXISTS]

The device serves the CeraUI control plane over HTTPS on **443** via `nginx-light`,
which terminates TLS and reverse-proxies to the CeraUI backend on `127.0.0.1:80`.
Standalone artifacts under `v2/mkosi/runtime/`
(`ceralive-tls.nginx.conf`, `ceralive-tls-firstboot.{sh,service}`,
`ceralive-tls-nginx.dropin.conf`), installed by
`postinst-lib.sh::setup_tls_proxy` — NOT inlined in `mkosi.postinst.chroot`
(drift-gate 950-line ceiling; `setup_tls_proxy` is wired into BOTH the postinst
executor and `services.sh`, like `setup_provisioning`).

- **SC3 — port 80 is KEPT.** nginx binds **443 only**; the backend keeps serving
  port 80 directly. `setup_tls_proxy` removes the stock nginx `sites-enabled/default`
  (which would otherwise grab :80). There is deliberately **no** 80→443 redirect —
  both ports are a real, supported entry point.
- **EC6 — WebSocket upgrade.** The proxy site sets
  `proxy_http_version 1.1; proxy_set_header Upgrade $http_upgrade; proxy_set_header
  Connection "upgrade";` so CeraUI's same-origin telemetry/RPC WebSocket survives the
  proxy (Task 1 already maps `https:`→`wss:` in the frontend; no UI change needed).
- **Self-signed cert (no ACME/mTLS).** `ceralive-tls-firstboot.service` mints a
  per-device self-signed key+cert ONCE on first boot into `/data/ceralive/tls/`
  (survives reboots + A/B OTA slot swaps), flag-guarded (idempotent). CN/SAN =
  `<hostname>.local` + the device IPv4. **Browser caveat (honest):** the first visit
  to `https://<device>.local` shows a "self-signed / not secure" warning — expected
  for a headless LAN appliance with no public DNS and no ACME path (SC3 forbids
  ACME/Let's Encrypt and mTLS). `openssl` is pinned in `shared.list` for the cert.
- **Ordering.** `ceralive-tls-firstboot.service` runs `Before=nginx.service` (and
  after the unique-hostname service); a `nginx.service.d/10-ceralive-tls.conf`
  drop-in adds `Requires=`/`After=` so nginx never starts without a cert.
- **Healthcheck.** `ceralive-healthcheck.sh` probes BOTH `http://127.0.0.1/status`
  (:80) and `https://127.0.0.1/status` (:443, `-k`); this is **non-fatal** (WARN
  only, like the mDNS probe) — a UI/TLS hiccup must not roll back a slot whose
  streaming stack is healthy and whose port 80 still serves.
- **Coexistence with provisioning (Task 11):** the AP-mode portal uses port 80;
  nginx only binds 443, so there is no conflict.
- **Size:** ~+3–4 MB; see [`v2/docs/size-notes.md §5`](v2/docs/size-notes.md).

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

**RK3588 mainline-patch contingency (D3 stays locked):** D3 (`armbian_branch: vendor`) is NOT changing. The Armbian vendor BSP kernel already provides HDMI hdmirx and mature Rockchip MPP H.265. If a mainline pivot is ever forced, the reference patch set is bookmarked in [`v2/docs/kiosk-display.md §3`](v2/docs/kiosk-display.md) (GPU contingency section): three patches from `https://github.com/rcawston/rockchip-rk3588-mainline-patches` covering VEPU580 H.265 encoder (WIP, pinned MPP fork required), HDMIRX EDID set fix, and HDMIRX plugout overflow fix. These are insurance only — do not apply without explicitly re-opening D3.

## ANTI-PATTERNS

- Don't change REPOS order or casing — downstream scripts key on exact names
- Don't add `ceralive-platform` to REPOS — cloud-only, not in device image
- Don't commit GPG private keys or mTLS certs — those come from `cert-work/` at build time
- Don't revert first-party fetch to R2 `aws s3 sync` / `gh release download` — first-party `.debs` are pulled at build time from `apt.ceralive.tv` (GPG + mTLS); see the "First-party .deb fetch" KEY FACT
- Don't add `srt` to `FIRST_PARTY_APT_PKGS` — the libsrt fork is dependency-resolved by the app layer's `apt-get install`, not a download target
- Don't implement kiosk units/packages without clearing the Task 1 hardware gate first
- Don't use `--native` as the default build path — container is canonical; native is opt-in
- Don't put GPU/BSP userspace (`libmali*`, `librockchip_mpp*`) in any add-on sysext — Platform-layer only
- Don't touch runtime apt sources on the device — `E4` guardrail
- Don't let add-ons gate OTA healthcheck/rollback — add-ons are orthogonal to the RAUC A/B slot

## KNOWN ISSUES / DEFERRED

Full index with file:line anchors and unblock conditions: [`v2/docs/DEFERRED.md`](v2/docs/DEFERRED.md).

**OPi 5+ interface ID_PATHs are FIXME placeholders.** `manifests/boards/orange-pi-5-plus.yaml`
ships the `interfaces:` block with `FIXME-…` values because the board is not in
hand. The OPi 5+ has two onboard r8169 NICs on the same driver/bus, so a generic
`Type=ether` match races. Before building an OPi 5+ image, read the real ID_PATHs
on the device (`udevadm info /sys/class/net/<iface> | grep ID_PATH`) and replace
each FIXME. Until then `install_interface_naming()` skips the FIXME values and
emits only the generic `Type=wlan → wlan0` rule; the dual NICs stay
non-deterministic.

**Modem source-routing under NM `dhcp=internal` — FIXED.** NetworkManager in
Debian bookworm defaults to `dhcp=internal` (its own DHCP client), which does NOT
execute `dhclient-exit-hooks.d/`, so the SRTLA dhclient hook
(`/etc/dhcp/dhclient-exit-hooks.d/srtla-source-routing`) never fired for
NM-managed modems. The NM dispatcher
(`/etc/NetworkManager/dispatcher.d/90-srtla-wifi-routing`) now also matches modem
interfaces (`usb0..7` and `enx*0..7`) and installs the same source rule + default
route in tables 100–107, mirroring the dhclient-hook semantics. The dhclient hook
is retained (harmless; still covers non-NM dhclient paths). Both drift-gated SRTLA
payloads were twin-updated in one commit (`networking-srtla.sh` and the `§6` block
in `mkosi.postinst.chroot`); `v2/ci/postinst-drift-check.sh` CHECK 2 confirms
byte-parity. WiFi table assignments (120–124) are unchanged. Verify on hardware
with a modem attached: `journalctl -t srtla-routing` and `ip rule show` after the
modem connects.

**Modem `usb0..7` naming is hardware-gated.** Deterministic modem renames need a
physical modem to read its ID_PATH; not implemented here. Only `eth0/eth1/wlan0`
are pinned today.

**Cog render QA hardware-gated.** `cog.sysext.conf` + build wrapper are inert
scaffolds until a physical RK3588 validates render (OKLCH/Tailwind v4 on WebKit
2.38.6, Mali-G610 EGL/GBM wiring). See [`v2/docs/cog-display-addon.md §7`](v2/docs/cog-display-addon.md).
