# image-building-pipeline

## ROLE IN THE GROUP

Assembly hub for the device image. Pulls every device-side first-party component
(.deb packages from `srtla-send-rs`, `cerastream`, `CeraUI`), drives a
containerized mkosi v26 build, and produces a flashable image for RK3588 targets
(Orange Pi 5+, Radxa Rock 5B+).

Relates to:
- `cert-work/` — GPG signing key injected into image; mTLS certs baked in; add-on keyring sourced from here; PASETO device-token PUBLIC key (`paseto/`) provisioned into the CeraUI runtime env
- `apt-worker/` — runtime apt source on device points to `apt.ceralive.tv` (Cloudflare R2); add-on `.raw` artifacts served from R2 path `addons/{os_version}/{board}/{feature}.raw`
- `versions.yaml` — standalone pin registry consumed by `fetch-debs.sh` [EXISTS]

## STRUCTURE

```
image-building-pipeline/
├── v2/                       # current build system (mkosi v26)
│   ├── build                 # entry point: ./v2/build <board>
│   ├── ci/
│   │   ├── Dockerfile        # pinned debian:trixie-slim builder (mkosi 26)
│   │   └── publish-immutable-r2-pair.sh # approved-digest-bound RAUC publisher
│   ├── manifests/            # board/family manifests + exact package registries
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
│   └── tests/                # manifests, RK3588 A/B/preflash, x86 rollback
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
| **Supported-modem matrix / WWAN modules** | [`v2/docs/modem-matrix.md`](v2/docs/modem-matrix.md) — cellular stack (ModemManager 1.24 fork closure §1) + the advisory check `v2/lib/check-wwan-modules.sh` + fail-closed `modem_ports` slot-UID discovery runbook (§7) |
| **Modem slot-UID udev generator (fail-closed)** | `v2/mkosi/customize/udev.sh` `generate_modem_slot_uid_rules` — emits nothing while board `modem_ports.status: unverified`; permanent generic modem rules in `setup_hardware_access` are separate and always ship |
| Contribution rules | [`CONTRIBUTING.md`](CONTRIBUTING.md) |
| **Operator first-boot guide** | [`docs/FIRST-BOOT.md`](docs/FIRST-BOOT.md) — flash → WiFi portal → SSH → CeraUI |
| **Manual bench flashing (dev/debug only, real-HW validated)** | [`docs/DEVICE-BRINGUP.md`](docs/DEVICE-BRINGUP.md) §4 "Manual bench flashing" — direct `rkdeveloptool db`/`wl`/`rd`, timeout discipline, UART baud, and log-parsing gotchas; NOT a production/recovery path (see the CI release gate in the same section) |
| **Dev-sync live-reload loop** | [`v2/docs/dev-loop.md`](v2/docs/dev-loop.md) |
| Manifest schema / validation | `v2/manifests/schema/{board,family}.schema.json` (enforced by `v2/lib/resolve.py`; an invalid manifest fails at validation, not at build) |
| Armbian BSP Debian version pins | `v2/manifests/armbian-bsp-deb-versions.txt` |
| v2 unit tests / boot fallback | `v2/tests/manifest.bats` and `v2/tests/rk3588-ab-contract.bats` via `v2/run-tests` (GNU-parallel runs files in parallel but cases within each file stay serial; shared build-plan probes also lock staging); RK3588 bootcount proof: `v2/mkosi/platform/boot/test-fallback.sh`; x86 forced-primary proof: `v2/tests/qemu-x86.sh --fallback-selftest` |
| **x86 ESP + GRUB A/B disk assembly** | `v2/lib/assemble-disk-x86.sh` (offline producer); `v2/mkosi/platform/x86/{install-x86-grub.sh,grub-ab.cfg,10-esp.conf}`; offline proof `v2/mkosi/platform/x86/test-x86-grub.sh`; rationale in [`v2/mkosi/platform/x86/README.md`](v2/mkosi/platform/x86/README.md) §2 |
| **x86-minipc bring-up/validation runbook** (device discovery, build/flash, first-boot, `hw-smoke.sh n100` encoder validation, `.raucb` OTA install+rollback) | [`v2/docs/X86-MINIPC-BRINGUP.md`](v2/docs/X86-MINIPC-BRINGUP.md) — **NOT YET VALIDATED ON HARDWARE**, runbook only |
| **Kiosk display stack (chassis)** | [`v2/docs/kiosk-display.md`](v2/docs/kiosk-display.md) — units, packages, OOM, wvkbd build |
| Cross-repo kiosk architecture | [CeraUI on-device display](https://github.com/CERALIVE/CeraUI/blob/main/docs/ON_DEVICE_DISPLAY.md) — DC-1..DC-4, Phase-3 deferral register |
| **Build host support matrix** | [`v2/docs/host-support.md`](v2/docs/host-support.md) — which hosts work, what they need |
| **Image size notes / levers** | [`v2/docs/size-notes.md`](v2/docs/size-notes.md) — locale strip, firmware audit, size-gate |
| **Cog display add-on recipe** | [`v2/docs/cog-display-addon.md`](v2/docs/cog-display-addon.md) — Cog+WPEWebKit packaging, libmali strategy |
| **Cog on-hardware render QA checklist** | [`v2/docs/cog-display-hw-checklist.md`](v2/docs/cog-display-hw-checklist.md) — ready-to-run RK3588 render gate (software path proven in `test-results/task-39-cog-qa.txt`) |
| **sysext refresh protocol** | [`v2/docs/addon-sysext-refresh.md`](v2/docs/addon-sysext-refresh.md) — update/disable lifecycle |
| **Deferred / hardware-gated items** | [`v2/docs/DEFERRED.md`](v2/docs/DEFERRED.md) — index of every deferred item with file:line anchors and unblock conditions |
| **Kernel currency watch** | [`v2/docs/kernel-currency-watch.md`](v2/docs/kernel-currency-watch.md) — vendor 6.1 lock decision, 7-way evidence, and the two precise revisit triggers |
| Add-on descriptor schema | `v2/manifests/schema/addon.schema.json` |
| Build a feature sysext add-on | `v2/lib/build-feature-sysext.sh` |
| Publish a signed add-on to R2 | `v2/lib/upload-addons.sh` (CI: `v2-ci.yml` `addon-publish` job) |
| Publish a hardware-approved RAUC bundle pair to R2 | `v2/ci/publish-immutable-r2-pair.sh` via [`docs/RELEASE-PROCESS.md`](docs/RELEASE-PROCESS.md) §5; requires the independently approved candidate SHA-256 and performs private, read-only input snapshots plus create-only exact-byte recovery |
| **PASETO device-token key provisioning** | [`docs/paseto-key-provisioning.md`](docs/paseto-key-provisioning.md) — generate per-env keypair, route the 3 values; verify with `v2/lib/verify-paseto-key-encodings.sh` |
| **End-to-end release process** (build/sign → immutable candidate → real-HW gate → manual R2 publish) | [`docs/RELEASE-PROCESS.md`](docs/RELEASE-PROCESS.md) §1-6 |
| **apt.ceralive.tv build-credential rotation** (`APT_GPG_PUBLIC_B64`/`APT_CLIENT_CRT_B64`/`APT_CLIENT_KEY_B64`) | [`docs/RELEASE-PROCESS.md`](docs/RELEASE-PROCESS.md) §7 |
| **OTA-rollback runbook** (bad `.raucb` fleet response, A/B fallback, pulling a published bundle) | [`docs/RELEASE-PROCESS.md`](docs/RELEASE-PROCESS.md) §8 |

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
The signed `.raucb` OTA bundle is now emitted on the x86 path too: the `efi`/`grub`
Stage-4 branch calls `build-bundle.sh` after `assemble-disk-x86.sh`, alongside the
`.raw`, stamped with the board-specific `COMPATIBLE_STRING` (`ceralive-<board-id>`).
`build-bundle.sh` is board-agnostic, so the x86 path mirrors the RK3588 `custom`
path verbatim.

**Rock 5B+ production A/B contract** [EXISTS]

`rock-5b-plus.yaml` resolves `single_slot_fallback: false` with RAUC
`bootloader=custom`. The RK3588 assembler emits a 14,800 MiB factory image, writes
the same bootable baseline into `rootfs_a` and `rootfs_b`, seeds A as primary, and
passes `rauc.slot=A|B` on every automatic/manual boot path. The custom backend marks
the inactive target bad before installation and RAUC activates it only after a
successful write; a three-attempt bootcount rolls an unconfirmed slot back.
Both rootfs slots explicitly mount the shared XBOOTLDR p1 at `/boot`; relying on
automatic discovery would fail because each slot's kernel makes `/boot` non-empty.

`v2/tests/preflash-verify.sh` requires `--target-size-bytes` and rejects wrong GPT
starts/sizes or labels, a missing idblock or second-stage FIT, external FIT payloads
whose declared extents exceed the image/8 MiB budget or whose SHA-256 nodes mismatch,
malformed compiled boot metadata, either slot missing its arm64 kernel/board DTB/initrd, stale boot
state, incompatible/invalid signed bundles, and a destination smaller than the raw
image. Its `check_rootfs_populated` resolves the real Armbian kernel-package `/boot`
layout — `/boot/Image` is a symlink to `vmlinuz-<ver>` and only the versioned
`/boot/initrd.img-<ver>` exists (no bare `/boot/initrd.img`). `debugfs dump -p` does
NOT dereference a symlink that is the FINAL path component (it writes the link
target, so a fast symlink yields a 0-byte file), so the gate `stat`s each artifact,
follows a terminal-component symlink to the versioned target, and globs the versioned
initrd name when the bare one is absent; plain-file `/boot` layouts still pass. `v2/run-tests` blocks on the actual boot-script sanitizer, fallback engine,
mock rollback, preflash adversarial fixtures, and the two privileged hardware-free
contracts required by CI: `CERALIVE_RUN_REAL_RAUC_CONTRACT=required` exercises
real-RAUC interruption/cleanup, while
`CERALIVE_RUN_REAL_AVAHI_CONTRACT=required` exercises real mDNS arbitration in
private namespaces. The RAUC harness uses the supported boot-slot override for
its synthetic file-backed slots, so the same service contract runs across CI
RAUC versions without depending on the runner's boot device. A v1 single-slot
disk cannot migrate by
OTA because its `data` partition starts where v2 places `rootfs_b`; back up required
state and perform a full re-flash. Physical Rock 5B+ install/reboot/rollback remains
the hardware acceptance gate in `v2/docs/hardware-gated-completion.md` Item 4.

The v2 CI Bats job installs the split Ubuntu `rauc` + `rauc-service` packages,
starts a system D-Bus, reloads its installed policy, and then invokes the real
RAUC contract; the harness requires RAUC to own its normal system-bus service
name and does not replace that check with a session bus or a skipped test. The
standalone DRY_RUN build-plan jobs materialize the same ignored NON-PRODUCTION
fixture before resolving, so build-plan checks are self-contained too.

Production builds require one explicit RAUC PKI contract: signer root, chain,
leaf certificate/key, and baked device keyring must match. The release workflow
builds the candidate before hardware validation, uploads the raw image, bundle,
keyring, and digest as one immutable artifact, then the hardware gate preflights
and flashes a private, digest-verified snapshot of that exact raw image. While
the board is still in maskrom, the gate reads the exact whole-media sector range
back with `rkdeveloptool rl`, hashes the private readback, and refuses to reset
on mismatch. The candidate artifact also carries the official Radxa Maskrom
loader under an exact SHA-256. The gate starts from Maskrom, derives capacity in
loader mode, and uses UART to enable a bounded, one-shot data-only bootstrap that
installs a restricted, expiring run-local root public key into the empty `/data`
key store. The initial `rkdeveloptool db` runs under a pinned leader in an owned
session/process group with a monotonic 15-second command budget. The leader
stays present until command status and descendant cleanup are proved, preventing
PID/process-group reuse from redirecting cleanup signals. On timeout or
interruption the verifier sends TERM to the whole group, waits one second, sends
KILL to survivors, reaps the leader, and fails unless no live or zombie group
member remains. A clean `db` exit is not readiness: a separate 10-second poll
must observe exactly the same
VID/PID/`LocationID` in `Loader` mode before `rfi`. Zero devices or the same
fixture still in Maskrom are transient; malformed, multiple, changed, or
unexpected-mode listings fail immediately. Neither phase retries `db` or any
later destructive operation, and no `rfi`, identity read, write, readback, or
reset may run after failure. The diagnostics distinguish “rkdeveloptool db
command timed out” from “loader re-enumeration timed out.” Test overrides are
hard-capped at 60 seconds for either phase, 10 seconds for each cleanup grace,
and 5 seconds for the poll interval, so configuration cannot recreate an
unbounded handoff.

The bootstrap accepts no shell commands, does not restart, and binds
an authenticated, one-hour-bounded request containing a device-generated nonce,
the baked candidate commit, USB-captured 16-byte chip identity, and fresh UART challenge to
the post-boot SSH marker. Consumed nonces and a non-decreasing signed epoch floor
persist on `/data`; the runner private key must derive the public verifier baked
into the candidate before any USB operation. The
image contains only the UART verification public key, never an SSH credential or
password. Only after
the immutable proof does it boot, rotate a run-local SSH host-key record, require
a valid media CID, the same chip identity read by `rkdeveloptool rci` before reset
and from the first 16 bytes of Rockchip OTP NVMEM through the installed
`ceralive-rockchip-chip-info` helper, and `/`
on the flashed eMMC, then run
the physical suite, and remove the exact temporary key
with a cleanup receipt. Each planned RAUC reboot consumes a one-use retention
marker; any unarmed later boot revokes leftover CI access before sshd. It never compares
mutable post-boot media bytes. Later `rkdeveloptool` operations retain their
existing cancellable-child behavior. The verifier resets inherited
ignored INT/TERM dispositions before Bash starts its signal traps, so CI shells
that launch it asynchronously cannot make SIGINT cancellation ineffective. The
identity record accepts only safe artifact filename characters so its
line-oriented fields cannot be split. The `rci` structured-input boundary accepts
exactly one `Chip Info:` record containing exactly 16 one- or two-digit hex octets,
under LF or CRLF framing; it strips only the terminal transport CR and rejects
truncated, extra, split, nonhex, or duplicate records before media write. The
accepted identity remains lowercase 32-hex downstream.
Authenticated BSP fetches require the exact two-key Armbian archive rotation set
(`DF00FAF1…E78D5` + `8CFA83D1…6099FE`, with no extra primary keys) and verify
InRelease, Packages.gz, and every package SHA-256. Manual RK3588 recovery uses
`recovery.scr`, which loads boot artifacts directly from p2 or p3.

**Multi-board dispatch** [EXISTS]

Dispatch is by the **count of resolved boards**, not the flag: a single resolved
board (`<board>`, or `--only`/`--all` that resolves to exactly one) execs the
orchestrator directly; a multi-board selection is handed to the parallel runner
`v2/lib/build-all.sh`. An unknown board in `--only` exits non-zero, names the
offender, and lists the available boards — it is never silently skipped.

**REPOS array — case and order are sacred**
```bash
REPOS=("srt" "cerastream" "CeraUI" "srtla-send-rs")
```
`cerastream` is the sole streaming engine — `ceracoder` was retired 2026-06-11
after the generic boot-parity profile passed
(`cerastream/docs/notes/boot-parity-results.md`); RK3588 hardware-gated profiles
now track as cerastream hardware validation, while Jetson profiles are DEFERRED —
not currently planned. `srtla-send-rs` is
the Rust sender fork (v1.0.0+) added at cutover (Task 20); `srtla` is
receiver-side only after cutover. **Conflict declaration:** `srtla-send-rs` declares
`Conflicts: srtla (<< 2026.6.2)` (SRTLA_CUTOVER_VERSION); any pre-cutover
`srtla (<< 2026.6.2)` — which still bundled the C sender — is correctly blocked from
coinstall, while `srtla` v2026.6.2 (the first receiver-only release) is NOT
`<< 2026.6.2`, so it coinstalls with the Rust sender. REPOS lives in
`v2/lib/fetch-debs.sh`.

**First-party .deb fetch — build-time apt pull from apt.ceralive.tv** [EXISTS]

`fetch_first_party` (in `v2/lib/fetch-debs.sh`) pulls the device first-party
`.deb`s from `apt.ceralive.tv` via a GPG-verified, mTLS-authenticated apt source —
this REPLACES the retired R2 `aws s3 sync` (CI) and `gh release download` (local)
paths. It mirrors `v2/mkosi/customize/apt-ceralive-repo.sh`: a deb822 source
(`URIs: …/dists/{CHANNEL}/`, `Suites: ./`, GPG `Signed-By`), the GPG keyring and
the mTLS client cert/key injected from the environment, all in an **isolated apt
state** under the staging dir (the host apt config is never touched).

- **Packages staged** (`FIRST_PARTY_APT_PKGS`): `libsrt1.5-ceralive`,
  `cerastream ceralive-device srtla-send-rs`, the required capture plugin
  `gstreamer1.0-libuvch264src`, PLUS the **ModemManager 1.24 closure** — the nine
  ceralive-forked (`~ceralive0.2.0`) modem packages `modemmanager libmm-glib0
  libmbim-glib4 libmbim-proxy libmbim-utils libqmi-glib5 libqmi-proxy libqmi-utils
  libqrtr-glib0` (modem-stack v0.2.0). All are downloaded into `$DEST/debs/` using the pins
  from `v2/manifests/first-party-deb-versions.txt` (14 packages total). The modem
  closure is a self-contained dependency set (`modemmanager`→`libmm-glib0`; the
  glib libs bind the qmi/mbim/qrtr transports); external deps (GLib, `libgudev`,
  `polkit`, systemd) come from Debian. The app layer classifies all nine as
  `RUNTIME_APP_PKGS` and their `dpkg -i` **upgrades** the Debian modem packages the
  runtime layer pulled via `shared.list` (`modemmanager`/`libqmi-utils`/`libmbim-utils`
  stay in `shared.list` to resolve that dependency tree; the fork wins on-device via
  the `Package: *` origin-990 pin). `mobile-broadband-provider-info` (ModemManager's
  APN database, a `Recommends:`) is an explicit `shared.list` entry. Debian hosts use isolated `apt-get download`;
  non-Debian hosts use a curl fallback that verifies `InRelease` with `gpgv`,
  checks the `Packages.gz` SHA256 from that signed metadata, then downloads the
  exact package files. Every verified `.deb` is normalized to mode `0644` before
  its atomic staging rename, then copied into explicit mode-`0755` mkosi consumer
  directories as mode `0644` so a restrictive runner umask cannot hide packages
  from mkosi's unprivileged local-repository helper. Containerized builds expose
  only those two consumer leaves through read-only bind mounts; mkosi never has
  to traverse the intentionally mode-`0700` persistent-runner checkout or staging
  ancestors. The platform postinstall is deliberately non-chrooted so mkosi
  exposes its `mkosi-install` wrapper; raw `apt-get` bypasses mkosi's ephemeral
  `file:/repository` package-list state and is forbidden for this path. Mode,
  mount, rename, or local-repository consumption failures fail closed and clean
  private package-temporary artifacts, while package payload modes are
  unaffected. These are Debian **Package** names — a
  deliberate mapping off `REPOS` (the directory/pin names), notably
  `srt → libsrt1.5-ceralive`, `CeraUI → ceralive-device`, and
  `gstlibuvch264src → gstreamer1.0-libuvch264src`.
- **`srt` provides the device SRT runtime.** Its `libsrt1.5-ceralive` package
  replaces Debian's GnuTLS/OpenSSL variants, so GStreamer and cerastream resolve
  one forked `libsrt.so.1.5` implementation. The
  `gstlibuvch264src` stays out of `REPOS`, but its Debian binary
  `gstreamer1.0-libuvch264src` is staged so the app layer can install all
  first-party packages from local `.deb`s with no downloads; `libgstreamer*`
  plugins still come from the runtime OS layer (`shared.list`). When that app
  layer installs `ceralive-device`, it explicitly enables `ceralive.service`;
  the runtime layer runs earlier and cannot enable a unit supplied later by the
  CeraUI package.
- **Secrets are env-only, base64-encoded** (same names as the device customize
  script): `APT_GPG_PUBLIC_B64`, `APT_CLIENT_CRT_B64`, `APT_CLIENT_KEY_B64`. They
  are NEVER hardcoded, NEVER logged, NEVER committed; a half-supplied mTLS pair is
  fatal. `APT_CERALIVE_URL` (default `https://apt.ceralive.tv`) is overridable.
- **Arch axis only** — the source carries no board axis; `arch` is selected by
  `APT::Architecture` (apt-worker two-axis model: `channel × arch`). Resolved
  mkosi `x86-64` is normalized to Debian `amd64`; RK3588 remains `arm64`.
- **DRY_RUN** logs the exact version-qualified `apt-get … download` plan + source
  and downloads nothing. With no `APT_GPG_PUBLIC_B64` in the env the fetcher
  auto-enables DRY_RUN (no credential for a verified fetch).
- **BSP fetch is authenticated** — kernel/DTB/U-Boot/firmware/GStreamer come
  from signed Armbian metadata, with the exact archive-key fingerprint set and
  all content hashes checked before staging. Family manifests select package
  names; `v2/manifests/armbian-bsp-deb-versions.txt` supplies the exact Debian
  versions. Both native apt and curl fetches re-verify the downloaded InRelease
  with `gpgv`, require signatures from both pinned archive keys, and validate the
  signed suite/component/architecture identity before any package download. The
  curl path parses only that verified Release plaintext and preflights every
  exact spec. The
  current transition set is the
  historical `DF00FAF1C577104B50BF1D0093D6889F9F0E78D5` key plus repository key
  `8CFA83D13EB2181EEF5843E41EB30FAF236099FE`; missing or additional primary keys,
  unusable primary/subkey states, and keyring parsing or normalization failures
  fail before apt runs. Source pins and the stdin-only secret rotation procedure
  are in [`docs/RELEASE-PROCESS.md`](docs/RELEASE-PROCESS.md) §4.
- **Non-Armbian package staging is fail-closed** — a family with
  `armbian_branch: none` emits no Armbian fetch in DRY_RUN and a real `fetch_bsp`
  invocation fails until an authenticated, exact-versioned Debian BSP source is
  implemented. The x86 disk/boot assembly exists, but its production Debian
  kernel/firmware staging path remains [GREENFIELD]; Armbian must not be used as
  an accidental substitute.

**Exact BSP package pins + advisory kernel content drift-guard** [EXISTS]

Decision D3 still selects the vendor branch through package names such as
`linux-image-vendor-rk35xx`; exact Debian versions for every required BSP package
are committed in `v2/manifests/armbian-bsp-deb-versions.txt`. `fetch_bsp`
authenticates the exact Armbian archive-key fingerprint set, verifies `InRelease`
and its configured suite/`main`/architecture identity, verifies the `Packages.gz`
digest from signed metadata, preflights the complete exact package set, and
verifies every staged package SHA-256. `Architecture: all` is compatible with a
target architecture; a stale version, wrong suite/architecture, ambiguous record,
or partial package set fails closed without fallback. It also makes an upstream
same-version content replacement observable:

- **Provenance capture** — after the real BSP fetch, `bsp_capture_provenance`
  records the kernel package's exact resolved **version string** + **content
  `sha256`** into `bsp-provenance.json` in the image output dir (`$DEST`). Scope is
  the **kernel BSP package only** — provenance is deliberately not widened to the
  rest of the BSP set. The artifact is **gitignored, never committed**, and
  deliberately **excluded from the build-matrix `sha256` determinism comparison**
  (that job hashes the normalized build-plan string, never a file tree).
- **Drift-guard (warn-default, strict opt-in, C6b)** — `bsp_drift_check` compares
  the captured version+hash against the committed baseline
  `v2/manifests/bsp-baseline.json`. On a mismatch it prints a `BSP drift` banner to
  stdout. Exit policy is **opt-in**: by DEFAULT (`BSP_DRIFT_STRICT` unset/≠1) it
  **exits 0 — drift is warn-only, never fatal** (build continues, the historical
  byte-for-byte path). With **`BSP_DRIFT_STRICT=1`** a real mismatch against a
  SEEDED baseline **exits non-zero, failing the build** (the seeding run + a clean
  match stay exit 0 regardless — a fresh baseline can never fail a strict build). It
  compares the **content hash, not just the version**, so a same-version re-spin is
  still caught. **Promotion criterion:** flipping the default to strict is a FUTURE
  change gated on (1) the baseline seeded with a real known-good version+sha256 AND
  (2) a fleet manifest run clean of drift — see
  [`v2/docs/kernel-currency-watch.md`](v2/docs/kernel-currency-watch.md).
- **First-run / seeded baseline** — a new scaffold may start with `version` and
  `sha256` as `null`; the first authenticated real build seeds the baseline with
  the actual values, emits an informational note, and exits 0. Commit that seeded
  value to set the known-good content reference. Exact package selection remains
  governed by `armbian-bsp-deb-versions.txt`. Proof:
  `v2/run-tests` section 15.
- **DRY_RUN stages no `.deb`**, so provenance capture is skipped under DRY_RUN — the
  CI build-matrix (DRY_RUN=1) never writes the artifact.

**RK3588 HW-accel userspace .deb fetch — pinned upstream URLs + SHA-256** [EXISTS]

The RK3588 GPU/video **userspace** (Mali-G610 blob, Rockchip MPP encode/decode lib,
RGA 2D accelerator, the GStreamer MPP plugin, and the multimedia udev config) is NOT
in the Armbian bookworm arm64 feed, so it is baked from **exact upstream release-asset
URLs verified by SHA-256** — the same fail-closed, no-fallback discipline as the BSP
fetch, but URL-pinned (a pinned URL + SHA-256 needs no rotating apt index or GPG trust
root). This is what makes `mpph264enc`/`mpph265enc`/`mppjpegenc`/`mppvp8enc` register —
proven on real Rock 5B+ hardware (ffprobe-verified H.264/H.265 HW encode).

- **Pin file:** `v2/manifests/rk3588-userspace-deb-versions.txt` — one record per
  package (`package  filename  sha256  url`). Six packages:
  `libmali-valhall-g610-g24p0-wayland-gbm` 1.9-1 (firmware_packages),
  `gstreamer1.0-rockchip1` 1.14-4 (hw_accel_gstreamer_plugins), and
  `rockchip-multimedia-config` 1.0.2-1 / `librga2` 2.2.0-1 / `librockchip-mpp1` 1.5.0-1
  / `librockchip-mpp-dev` 1.5.0-1 (gstreamer_runtime_packages). Sources: tsukumijima
  (`mpp-rockchip`, `rockchip-multimedia-config`, `libmali-rockchip`) + radxa
  `rk3588s2-bookworm` (the gst plugin + its ABI-paired RGA; tsukumijima ships no
  gst-rockchip mirror).
- **Fetcher:** `fetch_rk3588_userspace` in `v2/lib/fetch-debs.sh` stages only the
  pinned packages the resolved family declares (intersection of
  `collect_declared_bsp_pkgs` and the pin file's names); `fetch_bsp` EXCLUDES exactly
  this set from the Armbian fetch. An x86 family declares none. DRY_RUN logs the exact
  URLs + hashes and downloads nothing.
- **DO NOT** convert any of these into a `deb [signed-by=...] https://...` apt line —
  that is a new live trust root, exactly what the pinned-URL + SHA-256 approach avoids.
  **DO NOT** bump a pinned VERSION without re-proving HW encode (the versions are
  empirically proven). See `v2/docs/kernel-currency-watch.md` and
  `v2/docs/cog-display-addon.md`.

**versions.yaml** [EXISTS]
`fetch-debs.sh` and `resolve.sh` read pin versions from the repo-local `versions.yaml`.
Don't hardcode versions in the script.

**CI and release build caches** [EXISTS]
PR CI (`v2-ci.yml`) caches only pip's download/wheel store (`~/.cache/pip`) for
the manifest-validation and build-plan jobs. Its key includes the runner OS,
architecture, and the hash of `v2/ci/requirements-ci.txt`; image outputs, mkosi
caches, QEMU state, and release artifacts remain uncached there.

The protected release candidate (`.github/workflows/release.yml`) persists the
two build-state stores that materially shorten a production rebuild:

- BuildKit's GitHub Actions cache reuses layers from the canonical
  `v2/ci/Dockerfile`. The scope is stable per repository, runner OS/architecture,
  board, and mkosi tool pin, so old commits do not create an unbounded cache
  family. The source hash is carried in the builder image tag and label; the
  Dockerfile/context digests remain BuildKit's layer keys. `mode=min` exports
  only layers needed by the loaded builder image.
- `v2/mkosi/cache/rock-5b-plus` is restored and saved with a key containing the
  repository, runner OS/architecture, board, mkosi pin, and build-source hash.
  Its restore prefix retains those collision boundaries. The cache is capped at
  2 GiB; size measurement, over-limit clearing, and runner-UID/GID
  normalization all happen as root inside the builder container before the save
  step, because mkosi may create mode-700 root-owned entries.

The persistent self-hosted runner also clears exactly the ignored generated
paths `v2/mkosi/build` and `v2/mkosi/cache` in a digest-pinned, network-disabled
cleanup container before checkout and in an `always()` step after the job. The
post-run cleanup happens after a successful cache save. This bounded allowlist
lets `actions/checkout` keep its normal clean checkout while recovering from a
host interruption that skipped post-run cleanup; it never deletes the checkout,
staging inputs, image outputs, QEMU state, release artifacts, or trust material.

Both cache paths are build state only: image outputs, `.staging`, QEMU state,
apt credentials, and release artifacts are excluded. Cache steps are guarded to
release pushes/tags (the workflow has no pull-request trigger), and all
production trust inputs are materialized after cache restore/build, so an
untrusted PR cannot populate or consume this release cache path and secrets
never enter a cache key or build context.

**Production builder resource contract** [EXISTS]
The protected candidate job pins `DOCKER_CONTEXT=default`; the context must
resolve to the native Linux socket `unix:///var/run/docker.sock`, and the daemon
must not identify as Docker Desktop. Before BuildKit or trust materialization,
`v2/ci/check-builder-resources.sh` requires at least 16 GiB daemon-visible RAM,
16 GiB combined `MemAvailable` + `SwapFree` from the workflow-pinned
`/proc/meminfo`, and 24 GiB free on both the workspace and Docker-root
filesystems. A pressure or topology failure aborts before package fetch/build
instead of risking a kernel OOM and runner restart.

After a failed immutable candidate exposes a release-path defect, merge its fix
before proving it: push an untagged `release/**` branch at the exact merge SHA,
require the production candidate and physical real-HW jobs to pass, then create
the next unused patch tag at that same proven commit. Never use a new tag as the
first production execution of the repair, and never move or rerun the failed tag.

The Rock 5B+ raw's 14,800 MiB logical geometry is intentional and starts sparse.
Candidate sealing hard-links that immutable raw into the repo-local `candidate/`
directory, so staging does not allocate a second multi-GiB copy; artifact upload
uses explicit zlib compression level 6. Keep the candidate directory on the same
filesystem, and do not replace the hard link with `cp`. Regression coverage is
in `v2/tests/builder-resource-budget.test.sh` and
`v2/tests/release-cache-contract.test.sh`.

**Reproducible builds** [EXISTS]
Same source state → bit-identical `.raucb`. The orchestrator pins one
`SOURCE_DATE_EPOCH` (env override → HEAD commit time → frozen fallback, via
`common.sh::resolve_source_date_epoch`) and exports it so every embedded mtime
(rootfs.tar, squashfs, ext4, mkosi) clamps to it. `build-bundle.sh` signs the RAUC
bundle through a deterministic OpenSSL CMS path (`-noattr` → no wall-clock
`signingTime`; real leaf key + intermediate chain, still `rauc`-verifiable) because `rauc`
itself bakes an uncontrollable CMS timestamp. `REPRODUCIBLE=0` opts back into the
native `rauc bundle` signer (NOT bit-reproducible). Proof: `v2/run-tests` section
11; double-build the same board and compare `.raucb` sha256.

**RAUC test trust fixture** [EXISTS]

The canonical `v2/run-tests` entrypoint invokes
`v2/tests/generate-dev-rauc-pki.sh` before any RAUC contract suite. The generator
creates or validates only the ignored `v2/.dev-keys/` NON-PRODUCTION fixture
(including the leaf → intermediate → root chain and leaf key pairing); it never
provides a production default. Production image builds still require an explicit
`CERALIVE_RAUC_PKI_DIR` and matching `RAUC_KEYRING_FILE`.

**RAUC 1.8 needs a DUAL-EKU signing leaf, `unsquashfs`, and `mkfs.ext4` on the
device — else OTA is 100% broken** [EXISTS]

The device runs Debian bookworm's `rauc 1.8-2`. `rauc install` (the config-driven
path `ceralive-update` / CeraUI `system.startUpdate()` actually use) failed on real
Rock 5B+ hardware in three stacked ways, all fixed here. A REAL, complete,
end-to-end OTA install with all three fixes combined has now been PROVEN on
physical Rock 5B+ hardware: signature verified, manifest checked, slot B was
written, the bootloader switched to it, and the new slot rebooted healthy.

- **Signing leaf EKU.** RAUC's `check-purpose=codesign` / X.509 key-usage support
  landed in **rauc 1.9** (March 2023); 1.8 predates it entirely — its
  `-C`/`--confopt` CLI flag does not exist and a `[keyring] check-purpose=codesign`
  line in `system.conf` is ignored. So 1.8's `CMS_verify()` falls back to OpenSSL's
  default `smime_sign` purpose, which rejects a **codeSigning-only** leaf with
  `Verify error: unsuitable certificate purpose`. The dev/CI leaf
  (`v2/tests/generate-dev-rauc-pki.sh`) now carries a **dual EKU**
  `emailProtection,codeSigning`: `emailProtection` satisfies 1.8's unconfigured
  `smime_sign` default (install succeeds), `codeSigning` keeps forward-compat with a
  future rauc ≥1.9 `check-purpose=codesign` upgrade (and the modern CI/local `rauc`
  1.15.2 strict path). CA certs (root/intermediate) intentionally carry NO EKU per
  RAUC's own docs — do not add one. The build-time self-check in
  `build-bundle.sh::verify_openssl_bundle()` was `openssl cms -verify -purpose any`
  (accepts anything) — materially weaker than the device, which is why the bug
  shipped silently; it is now `-purpose smimesign`, reproducing rauc 1.8's default
  purpose (same OpenSSL error) so a single-purpose leaf fails at build time.
  Structural guards: `generate-dev-rauc-pki.sh`'s `validate_fixture()` asserts the
  leaf carries both EKUs, and `verify_openssl_bundle()` now fails a single-purpose
  leaf.
- **`unsquashfs` runtime gap.** Even with a verified signature, `rauc info`/`install`
  next fails `Failed to start unsquashfs: ... No such file or directory` — `rauc`
  shells out to `unsquashfs` to extract the plain-format bundle manifest. Build-time
  `mksquashfs` runs on the HOST/CI, so this runtime-only gap was invisible.
  `squashfs-tools` is now in `shared.list` (standard bookworm `main` — no new trust
  source). Guard: `manifest.bats` "squashfs-tools is installed so rauc can unsquashfs
  bundles".
- **`mkfs.ext4` runtime gap.** After signature and manifest checks pass, RAUC's
  slot-write phase shells out to `/sbin/mkfs.ext4` from `e2fsprogs` to format the
  target ext4 slot before copying in the new rootfs image. Without it, the real
  Rock 5B+ install reported exactly: `LastError: Installation error: Failed updating slot rootfs.1: failed to start mkfs.ext4: Failed to execute child process 'mkfs.ext4' (No such file or directory)`. Build-time tooling never needed
  `mkfs.ext4`, so this runtime-only gap was invisible. Adding `e2fsprogs` made the
  REAL end-to-end install complete successfully, activate slot B, and boot the
  fresh slot healthy; guard: `manifest.bats` "e2fsprogs is installed so rauc can
  format ext4 slots".

**PRODUCTION PKI still carries the codeSigning-only leaf and was DELIBERATELY NOT
touched here.** `/mnt/development/ceralive/cert-work/rauc/gen-certs.sh` generates the
production leaf with the same `extendedKeyUsage = codeSigning` only — so it has the
identical RAUC 1.8 defect. It is live security key material (private keys included)
and reissuing it is a separate, explicit decision per `cert-work/ROTATION.md` — out
of scope for this fix. Flagged for the orchestrator/user to action separately before
production OTA can work on a 1.8 device.

**Image size gate — BLOCKING at 1.5 GB** [EXISTS]

`v2/lib/measure-size.sh` runs after every build. If the normalized rootfs tar exceeds
**1.5 GB** the build fails loudly and the `.raucb` is not produced. The threshold
is post-slim (locale strip, final apt-cache cleanup, and appliance payload pruning
already applied). See
[`v2/docs/size-notes.md`](v2/docs/size-notes.md) for the levers used to reach it.

**OTA-during-stream guard — refuses to update while a stream is live** [EXISTS]

`/usr/local/bin/ceralive-update` (generated by
`postinst-lib.sh::setup_data_persistence`, invoked by CeraUI
`system.startUpdate()`) installs the RAUC bundle named by `BUNDLE_URL` in
`/data/ceralive/update.conf`. Before it touches RAUC it bails if any active unit
in its stream-guard list is running — `systemctl is-active --quiet` (so a
stopped OR not-installed unit reads `inactive` and never blocks). The list
**must** cover all three live-media units:
`cerastream.service` (encoder), `srtla.service` (bonding RECEIVER), and
`srtla-send.service` (bonding SENDER). The sender unit was missing — a device
mid-broadcast through the bonding sender could be updated out from under the
stream; the guard now checks `srtla-send.service` too. Don't drop the receiver
check: a single image runs either role. Proof: `v2/run-tests` section 16.

**`/data` migration MUST seed the `public` frontend symlink — else `/` 404s** [EXISTS]

`postinst-lib.sh::setup_data_persistence` generates `ceralive-migrate-data`, whose
first-boot seeding loop copies the CeraUI working dir (`/opt/ceralive`) onto
`/data/ceralive` BEFORE the `/data/ceralive:/opt/ceralive` bind mount shadows it.
The CeraUI `.deb` ships the frontend static tree at `/var/www/ceralive` and an
ABSOLUTE symlink `/opt/ceralive/public -> /var/www/ceralive`
(`CeraUI` `build-debian-package.sh`). The loop MUST seed `public` alongside
`*.json`/`revision`: once the bind mount activates, `/opt/ceralive/public` is the
`/data/ceralive/public` entry, so if `/data` never got one the symlink is gone and
CeraUI serves the frontend from a missing dir — `curl http://<device>/` returns 404
while `/status` stays healthy (confirmed on real hardware). `cp -a` copies the
symlink ITSELF (never the `/var/www` asset tree — those stay on the rootfs so
image/OTA updates keep tracking); the loop's `[ -L ]` guards keep it symlink-aware
(a target-absent link isn't skipped as a source, an existing `/data` entry isn't
clobbered on a re-run / A-B swap). Because the link is absolute and `/opt/ceralive`
and `/data/ceralive` sit at the same depth, it resolves identically post-bind. This
is DISTINCT from the systemd ordering-cycle fixes — a content bug the graph check
cannot see. Offline guard: `v2/tests/data-persistence-public-symlink.test.sh`
(static contract on the seeding block + a runtime reproduction that seeds a
synthetic tree and proves the symlink is preserved, resolves after the bind mount,
is idempotent, and never clobbers an existing entry). Wired into `v2/run-tests`.

**`/etc/resolv.conf` MUST be the systemd-resolved stub symlink — else DNS is
totally dead** [EXISTS]

`postinst-lib.sh::configure_networking` writes
`/etc/NetworkManager/conf.d/ceralive.conf` with `dns=systemd-resolved`, so
NetworkManager DELEGATES DNS to systemd-resolved (forwards the DHCP-received
servers over D-Bus, never writing `/etc/resolv.conf` itself). systemd-resolved
only manages `/etc/resolv.conf` when that path IS the symlink to its stub
`/run/systemd/resolve/stub-resolv.conf`; on a plain regular file it reports
`resolv.conf mode: foreign` and stands down (its designed safety behavior). This
minimal mkosi rootfs never ran systemd-resolved's postinst trigger /
`dpkg-reconfigure`, so it ships `/etc/resolv.conf` as an empty 0-byte REGULAR
file — with delegation on and resolved refusing a foreign file, NOTHING ever
populates it and every glibc/`getent`/`curl` lookup fails with zero working DNS
despite a valid IP, gateway, and DHCP-supplied server (confirmed live on
hardware: `resolvectl status` shows the server + `mode: foreign`, `getent hosts
www.google.com` exits 2, and CeraUI logs constant `DNS timeout for
wellknown.belabox.net` / `Failed to resolve www.gstatic.com` health-check
failures). `configure_networking` now runs `ln -sf
/run/systemd/resolve/stub-resolv.conf /etc/resolv.conf` right after the
`dns=systemd-resolved` drop-in (same delegation contract); `-sf` is
force+idempotent, so it fixes the empty file, a stale link, or an
already-correct link, safe on every build and A/B slot swap. This is a content
bug the `systemd-ordering-cycle` graph check cannot see. Offline guard:
`v2/tests/resolv-conf-symlink.test.sh` (static contract on the
`configure_networking()` body + a rootless-namespace runtime reproduction that
seeds the exact 0-byte-regular-file bug state, runs the real function, and proves
the result is the stub symlink — resolves through it, is idempotent, and
force-replaces a stale link). Wired into `v2/run-tests`.

**PASETO device-token PUBLIC key provisioning (ADR-0006 D2)** [EXISTS]

`setup_paseto_public_key` (in `customize/postinst-lib.sh`, called by the runtime
`mkosi.postinst.chroot`) bakes the device-token verification key into the CeraUI
backend runtime env so the device can VERIFY device-control / relay-config tokens.

- **What it writes** — an ADDITIVE systemd drop-in
  `/etc/systemd/system/ceralive.service.d/20-paseto-public-key.conf` with
  `Environment=PASETO_PUBLIC_KEY=<raw-base64 Ed25519 public key>`. The drop-in is
  additive to the `ceralive.service` unit shipped by the CeraUI `.deb`, exactly
  like `10-data-persistence.conf`. CeraUI reads `PASETO_PUBLIC_KEY` at startup
  (`apps/backend` `device-token.ts` `DEVICE_TOKEN_PUBLIC_KEY_ENV`); its **presence**
  gates real Ed25519 verification (absent → CeraUI runs the MVP opaque-token path,
  so a key-less dev/local build still boots).
- **Secret is env-only, base64-encoded** — `PASETO_PUBLIC_KEY_B64`, mirroring the
  `APT_*_B64` / `ADDON_KEYRING_B64` pattern: orchestrator-forwarded
  (`lib/orchestrate.sh` `env_names` + `PassEnvironment` in `mkosi.conf`), decoded
  once at chroot time. The decoded payload is the raw-32-byte Ed25519 PUBLIC key in
  standard base64 — the `paseto.public.raw.b64` form `cert-work/paseto/gen-keys.sh`
  emits and CeraUI's `importEd25519PublicKey()` consumes. There is **NO committed
  default**; CI injects it. With no env var the step is a graceful no-op.
- **PUBLIC ONLY** — a `k4.secret` (PASERK private) or any PEM `PRIVATE KEY` slipped
  into `PASETO_PUBLIC_KEY_B64` **FAILS the build**. The device only ever verifies;
  baking a private key would let a compromised device FORGE tokens. Proof:
  `v2/run-tests` section 18 (bakes the key, refuses k4.secret/PEM, no-env skip,
  and the cross-repo env-name lockstep against CeraUI's gate).
- **Operator runbook + encoding verifier** — the end-to-end provisioning procedure
  (generate one Ed25519 keypair per environment; route the THREE values — `(a)`
  PASERK `k4.secret` → platform `PASETO_SIGNING_KEY`, `(b)` PASERK `k4.public` →
  platform `PASETO_PUBLIC_KEY`, `(c)` raw-base64 → image-build `PASETO_PUBLIC_KEY_B64`)
  lives in [`docs/paseto-key-provisioning.md`](docs/paseto-key-provisioning.md).
  `v2/lib/verify-paseto-key-encodings.sh` proves `(b)` and `(c)` decode to the **same**
  32-byte public key AND that `setup_paseto_public_key` bakes the build input into the
  drop-in with zero drift (reading PUBLIC files only; never the `k4.secret`).
  `--self-test` (ephemeral keypair, no secrets) is the `v2/run-tests` section-21 gate.

**avahi-daemon restart hardening — else a single mDNS crash kills `<hostname>.local`
until reboot** [EXISTS]

Stock Debian's `avahi-daemon.service` ships **NO `Restart=` directive**, so ANY
signal or crash leaves `avahi-daemon` — and therefore `<hostname>.local` mDNS —
permanently dead until the next reboot. Confirmed live on real hardware
(`journalctl -u avahi-daemon`): the daemon was killed by SIGUSR2 (`Main process
exited, code=killed, status=12/USR2` → `Failed with result 'signal'`), and
`systemctl show avahi-daemon -p NRestarts` read `NRestarts=0` — no restart policy
was active. Operators reach the device by `<hostname>.local` (`docs/FIRST-BOOT.md`
+ the deterministic first-boot unique-hostname service), so mDNS staying up is a
device-reliability requirement. `setup_avahi_restart` (in `customize/postinst-lib.sh`,
called from the runtime `mkosi.postinst.chroot`) bakes an ADDITIVE drop-in
`/etc/systemd/system/avahi-daemon.service.d/10-ceralive-restart.conf` with
`Restart=on-failure` + `RestartSec=2`, installed from the committed standalone
artifact `v2/mkosi/runtime/avahi-daemon-restart.dropin.conf` (the SAME
standalone-artifact + `postinst-lib.sh` setup-function idiom as the nginx TLS
drop-in, never inlined in `mkosi.postinst.chroot` per the drift-gate ceiling).
`on-failure` (not `always`) so a deliberate `systemctl stop` still stops it. This
is the systemd-level **defense-in-depth** layer only — the signal SOURCE (a CeraUI
udev rule's overly-broad `pkill -f ceralive` catching avahi-daemon) is the
ROOT-CAUSE fix, handled separately in the CeraUI repo. Guard: `manifest.bats`
"avahi restart: an additive Restart=on-failure drop-in is baked …" (+ fail-closed
+ executor-wiring cases).

**`net-tools` in `shared.list` — else the CeraUI Network destination is TOTALLY
empty** [EXISTS]

CeraUI's backend (`ceralive.service`) shells out to the legacy `ifconfig` binary
every ~5s (`apps/backend/src/modules/network/network-interfaces.ts`
`run("ifconfig", [])`) to build the `netif` broadcast
(WiFi/Ethernet/cellular/bonded-link status shown on the Network destination). This
minimal Debian bookworm image ships only modern `iproute2`, NOT `net-tools`, so
every poll tick failed since boot (`{"level":"error","msg":"Error getting ifconfig:
Executable not found in $PATH: \"ifconfig\""}`, confirmed live on real Rock 5B+
hardware). That is the root cause of the Network destination rendering completely
empty ("No WiFi interfaces found", "No wired interfaces found", "No SIM cards
detected", "No active links yet") AND the missing Ethernet row in "Bonded Links"
(`BondedLinksSection.svelte` renders an `ethernet`-typed link fine — its input array
is just empty upstream) despite a live, connected Ethernet + WiFi. The fix is one
line — `net-tools` in `v2/manifests/packages/shared.list` (next to `iproute2`,
arch-independent, every board), NOT a rewrite of `network-interfaces.ts` onto `ip`:
CeraUI's `ifconfig` text-parsing is deeply embedded across its test suite
(`MONITOR-NOTES.md`, `netif-migration`/`netif-same-subnet` tests, `mocks/providers/
network.ts`), so swapping binaries is a large unrelated risk — adding the one legacy
binary is correctly scoped. Guards: `manifest.bats` "runtime packages: net-tools is
installed …" + "… reaches the resolved runtime package set …".

**`ceralive.service` ordered `After=cerastream.service` — soft boot-race hint (never
`Requires=`)** [EXISTS]

`ceralive.service`'s boot step `initPipelines()` connects to cerastream's control
socket **exactly once**, so if cerastream isn't up yet the connection fails
permanently for that boot. Confirmed live: `cerastream.service` started ~2 minutes
AFTER `ceralive.service` in one boot instance, and `systemctl show ceralive -p
After` had NO mention of `cerastream.service`. `setup_cerastream_ordering` (in
`customize/postinst-lib.sh`, called from the runtime `mkosi.postinst.chroot`) bakes
an ADDITIVE drop-in
`/etc/systemd/system/ceralive.service.d/30-cerastream-ordering.conf` with
`After=cerastream.service`, installed from the committed standalone artifact
`v2/mkosi/runtime/ceralive-cerastream-ordering.dropin.conf` (the SAME
standalone-artifact + `postinst-lib.sh` setup-function idiom as the avahi/TLS
drop-ins; additive to the `ceralive.service` unit shipped by the CeraUI `.deb`, like
`10-data-persistence.conf` / `20-paseto-public-key.conf`). **ORDERING-ONLY — never
`Requires=`**: `ceralive.service` MUST still boot and serve its "engine unavailable"
degraded state (CeraUI `helpers/boot-guard.ts::guardNonCritical` fail-soft boot
design) if cerastream is ever genuinely absent/masked, and `After=` on an
out-of-transaction unit is a harmless no-op. This is the systemd-level ordering half
only — a CeraUI-side retry/resilience fix for the one-shot connect lands separately
in that repo. Guards: `manifest.bats` "cerastream ordering: an additive
After=cerastream.service drop-in is baked …" + "… is ordering-ONLY (no
Requires=/Requisite=/BindsTo= hard dependency)" (+ fail-closed + executor-wiring
cases).

**Supported-modem matrix + advisory WWAN module-presence check** [EXISTS]

The cellular stack (ModemManager + libqmi/libmbim + usb-modeswitch, SRTLA modem
source-routing, the M.2 SIM quirk, and the known-good modem table) is documented
as-is in [`v2/docs/modem-matrix.md`](v2/docs/modem-matrix.md). That runtime stack
is **not** touched here — the doc only describes it.

Because an upstream repository can replace bytes under the same Debian package
version, a same-version Armbian re-spin could drop one of the six WWAN modules the modem stack
binds to (`qmi_wwan`, `cdc_mbim`, `cdc_wdm`, `option`, `cdc_ether`, `cdc_ncm`)
with no signal. `v2/lib/check-wwan-modules.sh` makes that observable: it inspects
a kernel `.deb` (or an extracted module tree) and reports each module as loadable
(`=m`, a `<mod>.ko` file), built-in (`=y`, in `modules.builtin`), or present via
`modules.alias`.

- Hyphen/underscore aware (the `cdc_wdm` module ships on disk as `cdc-wdm.ko`).
- The `option` module is matched by an exact `option.ko` basename, a
  `…/option.ko` `modules.builtin` entry, or a `modules.alias` module token —
  **never** a bare `option` substring (a known false-positive trap).
- Asserts a `.deb` extractor (`dpkg-deb`, or `ar`+`tar`) before opening a `.deb`.
- **Advisory only**, exactly like the BSP drift-guard: a missing module WARNS but
  the check **always exits 0**. It never fails the build and never edits
  `shared.list` or the kernel config. Proof: `v2/run-tests` section 17.

**ModemManager 1.24 closure — first-party fork, app-layer install** [EXISTS]

The device's core cellular stack is the **CeraLive ModemManager 1.24 fork**
(`~ceralive0.2.0`, modem-stack v0.2.0), not Debian's ModemManager. Nine
ELF-shipping packages — `modemmanager` + `libmm-glib0` + `libmbim-glib4`/`-proxy`/
`-utils` + `libqmi-glib5`/`-proxy`/`-utils` + `libqrtr-glib0` — are staged
first-party (`FIRST_PARTY_APT_PKGS`), exact-pinned in
`v2/manifests/first-party-deb-versions.txt`, and classified `RUNTIME_APP_PKGS` by
the app postinst (`app/mkosi.postinst.chroot`). Their local `dpkg -i` **upgrades**
the Debian modem packages the runtime layer pulled transitively via `shared.list`
(`modemmanager`/`libqmi-utils`/`libmbim-utils` stay there to resolve the full
dependency tree; external deps — GLib/`libgudev`/`polkit`/systemd — come from
Debian). The `Package: *` origin-990 pin keeps the fork winning on-device.
`mobile-broadband-provider-info` (ModemManager's APN database, a `Recommends:`) is
an explicit `shared.list` entry. Full source-of-truth: `v2/docs/modem-matrix.md §1`.
Guards: `manifest.bats §23` (closure membership, RUNTIME_APP_PKGS classification,
exact pins, origin-990 wildcard coverage, DRY_RUN resolution) +
`v2/tests/app-layer-modem-closure.test.sh` (executable install/classification).

**`orchestrate.sh` `[3/9]` partitioner allowlist MUST cover every
`FIRST_PARTY_APT_PKGS` entry.** After the fetcher stages all 14 first-party `.deb`s
into `<staging>/debs/`, the `[3/9]` step in `lib/orchestrate.sh` partitions each
staged `.deb` into BSP vs first-party by an exact package-name allowlist
(`firstparty_names`). A REAL (non-`DRY_RUN`) build `die`s with `unclassified staged
package` if a fetched first-party package is missing from that allowlist. The 9
ModemManager-closure packages were added to `FIRST_PARTY_APT_PKGS` (fetcher) but not
to `firstparty_names` (partitioner), so the first full build after that landed blew
up at `[3/9]` — invisible to CI because the PR gate only runs `DRY_RUN=1` plan-only
builds (the partitioner never runs there). `firstparty_names` now lists all 14. Guard:
`v2/tests/firstparty-classification.test.sh` (sources `FIRST_PARTY_APT_PKGS` from the
fetcher and asserts the partitioner allowlist is a superset). Wired into `v2/run-tests`.

**Fail-closed modem slot-UID naming (`modem_ports`)** [EXISTS]

The board manifest carries an optional `modem_ports` block that gates a udev
generator, `v2/mkosi/customize/udev.sh::generate_modem_slot_uid_rules`. It is
**fail-closed**: while `status: unverified` (the shipped default on every board —
verifying a slot map needs a physical modem on that exact board to read each
slot's real `ID_PATH`) the generator emits **NO** generated
`78-mm-ceralive-slot-uid.rules` and removes any stale one — **no permissive
fallback**. The **permanent generic modem rules** in `setup_hardware_access` (the
"USB Modem Devices (4G/5G)" `dialout` group-tag block) always ship and are NOT
touched. Only when a board is `status: verified` with `slots:` (`modemN` → `ID_PATH`)
does the generator emit one `ENV{ID_MM_PHYSDEV_UID}` rule per slot. The status/slots
reach the runtime subimage chroot via `CERALIVE_MODEM_PORTS_STATUS`/`_SLOTS`
(orchestrate.sh `env_names` ↔ `mkosi.conf` `PassEnvironment=`, same lockstep the
interface-naming vars use). Flipping to `verified` is a separate, hardware-gated
step (`v2/docs/modem-matrix.md §7` discovery runbook) — **do NOT flip it without
reading real hardware ID_PATHs**. Guards: `manifest.bats §23` generator matrix
(unverified ⇒ zero rules; unset ⇒ unverified; verified fixture ⇒ rules emitted;
verified-with-no-slots ⇒ fail-closed; stale-file cleanup; generic-rules-untouched;
env lockstep).

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

`ceralive-ssh-firstboot.service` runs before `ssh.service` and `ssh.socket` on
every boot, and both SSH activation paths require it to succeed. Standalone
artifacts under `v2/mkosi/runtime/`
(`ceralive-ssh-firstboot.{sh,service}`), installed by
`postinst-lib.sh::setup_ssh_firstboot` — NOT inlined in `mkosi.postinst.chroot`
(the drift gate's 950-line ceiling). Scope is locked (SC4): regenerate the baked
shared host keys into a per-device identity (persisted on `/data`, stable across
A/B) and apply the once-only password hardening on initial boot; the per-boot guard
then enforces `PermitRootLogin prohibit-password` and CI-key retention policy.
Persistent authorized-key stores are linked from `/data`; run-local CI keys survive
only an explicitly armed, one-use reboot and are otherwise purged before sshd.
The `ceralive` user ships password-locked (no default password); root retains
key-based recovery access. Full behaviour: [`v2/docs/ssh-hardening.md`](v2/docs/ssh-hardening.md).
For bench-only access, `CERALIVE_DEBUG_IMAGE=1` requires an externally supplied
encrypted `CERALIVE_DEBUG_PASSWORD_HASH`; it is rejected for normal builds and
must never be used for fleet artifacts.

**`Before=ssh.socket` guards MUST be `DefaultDependencies=no` AND
`After=sysinit.target`.** Both `ceralive-ssh-firstboot.service` and
`ceralive-ci-uart-bootstrap.service` are `Before=ssh.socket`. `ssh.socket` is
ordered `Before=sockets.target` (early boot, before `basic.target`), so a guard
that inherits the implicit `After=basic.target` closes an `ssh.socket → guard →
basic.target → sockets.target → ssh.socket` ordering cycle — systemd deletes
`ssh.socket`'s start job and SSH never starts, on every boot (proof-10 UART boot
log, 2026-07-15). `DefaultDependencies=no` breaks that, but it ALSO drops the
implicit `After=sysinit.target`; proof-11 (2026-07-15) then showed
`ceralive-ssh-firstboot` racing ahead of `systemd-sysusers`/`systemd-tmpfiles`/
udev and FAILING under `set -euo pipefail` (host-key gen, authorized-key chowns,
`sshd -t`), taking ssh.service/ssh.socket down with "Dependency failed" — with
**zero** ordering cycles. So each guard must ALSO re-add `After=sysinit.target`
explicitly (the SAFE half of the default deps; `sysinit.target` is ordered before
`sockets.target`, so it never re-closes the ssh.socket loop). NEVER re-add
`After=basic.target`. The same cycle trap (but NOT the sysinit issue) hit
`ceralive-migrate-data.service`, which seeds the `/data` skeleton the
`/var/log`+`/opt/ceralive` bind mounts shadow: it must be `Before=local-fs.target`
(never `After=`) with `DefaultDependencies=no`, and must NOT gain
`After=sysinit.target` (sysinit.target is After=local-fs.target — that would
cycle); it runs as root against `/data`+rootfs only, so it needs no sysinit-phase
ordering. `ConditionKernelCommandLine`/`ConditionPathExists` do NOT remove a
unit's ordering edges — systemd wires them at transaction-build time regardless of
the condition. Offline guard: `v2/tests/systemd-ordering-cycle.test.sh` — static
contract + `systemd-analyze verify` for zero cycles AND an ordering probe that
proves each guard is transitively after `systemd-sysusers`/`systemd-tmpfiles`
(a cycle-only check would miss the proof-11 gap). Wired into `v2/run-tests`.

**RK3588 CI-UART bootstrap owns the LIVE console `/dev/ttyFIQ0`, NOT `/dev/ttyS2`.**
On RK3588 the Rockchip vendor kernel's FIQ debugger claims physical UART2 once Linux
boots and exposes it as `/dev/ttyFIQ0` — systemd spawns `serial-getty@ttyFIQ0.service`
and there is **no `/dev/ttyS2` device node at runtime**. So
`ceralive-ci-uart-bootstrap.service` sets `TTYPath=/dev/ttyFIQ0` (was `/dev/ttyS2`,
which made its `StandardInput=tty` setup fail instantly on real Rock 5B+ hardware — no
handshake, no run-local SSH key installed), and the CI harness
`v2/ci/uart-provision-ssh.sh` masks `serial-getty@ttyFIQ0.service` over the transient
kernel cmdline (`systemd.mask=serial-getty@ttyFIQ0.service`) so the real getty cannot
contend for the port (masking `serial-getty@ttyS2.service` was a no-op — that unit
never exists). This is DISTINCT from the family `serial_console: ttyS2:1500000`, which
stays `ttyS2`: that is the raw UART2 U-Boot/early-kernel `console=ttyS2,1500000` arg,
correct because the bootloader/early kernel drive UART2 directly BEFORE the FIQ
debugger claims it (hence the UART helper's `=>` prompt interaction works). Do NOT
rename `serial_console` to `ttyFIQ0` — that would break the early/bootloader console.
The entire CI-UART path is RK3588-only by construction (`TTYPath` is a hardcoded
literal, not templated; x86 uses `ttyS0` and never runs this gate). Offline guard:
`v2/tests/uart-console-path.test.sh` (bootstrap `TTYPath` + getty mask both target
`ttyFIQ0`, the two agree, and `serial_console` stays the raw-UART2 `ttyS2` early
console). Wired into `v2/run-tests`.

**`ceralive-ssh-firstboot.sh` MUST create `/run/sshd` before its `sshd -t`.** The
guard's last step validates the sshd config with `sshd -t`, which refuses to run
without the privilege-separation dir `/run/sshd` (`Missing privilege separation
directory: /run/sshd`, exit 255). On a fresh boot that dir does not exist yet:
nothing ships a `tmpfiles.d` entry for it, and its only creator is `ssh.service`'s
`RuntimeDirectory=sshd` — which runs AFTER this `Before=ssh.service` guard. Without
pre-creating it, `sshd -t` exits 255, `set -euo pipefail` fails the unit, and both
`ssh.service` (LAN sshd on :22) and `ssh.socket` DEPEND-fail via `RequiredBy=`,
closing port 22 on EVERY boot with **zero** ordering cycles and an otherwise-healthy
system (proof-13 real-HW UART, 2026-07-16). This is a runtime script failure, NOT a
dependency-graph defect — `systemd-ordering-cycle.test.sh` cannot see it. The
dedicated offline guard is `v2/tests/ssh-firstboot-privsep.test.sh` (static: the
`/run/sshd` creation precedes `sshd -t`; runtime: the real script survives an
empty-`/run` first boot in a rootless namespace). Wired into `v2/run-tests`.

**Deterministic first-boot hostname** [EXISTS]

`ceralive-hostname.service` asks the running Avahi daemon to publish candidates
in the exact sequence `ceralive`, `ceralive2`, `ceralive3`, ... and accepts a
candidate only after Avahi repeatedly reports `RUNNING` with that exact name.
Avahi's automatic hyphenated collision name is treated only as a conflict signal;
it is never persisted. A real local `flock` serializes starts, while Avahi's mDNS
claim protocol arbitrates simultaneous devices. The selected index lives at
`/data/ceralive/host_index` through the `/etc/ceralive/host_index` symlink; the
local service lock is runtime-only state under `/run`.

The unit is ordered `After=`/`Wants=network-online.target` (link actually up), NOT
merely `After=NetworkManager.service` (daemon up). The mDNS claim (`avahi-set-host-name`
+ Avahi `RUNNING` + a publishable LAN address) cannot succeed before an interface
links, and every `Requires=ceralive-hostname.service` consumer (`ceralive.service`,
`ceralive-tls-firstboot.service`, `ceralive-hawkbit-provision.service`, and
transitively `nginx.service`/`ceralive-healthcheck.service`) cascades to "Dependency
failed" if this unit fails on first boot. Confirmed on real Rock 5B+ hardware: the
unit ran at ~15s and failed by ~15.8s while `eth0`'s link only came up at 18.89s, so
the claim failed-closed and the entire appliance stack (plus `dnsmasq`, which shares
the same start batch) never came up (`curl http://<device>/api/health` → connection
refused). Its sibling network-dependent units (`ceralive-healthcheck`,
`ceralive-hawkbit-provision`, `rauc-hawkbit-updater`) already wait for
`network-online.target`; the hostname unit was the lone omission. This is a systemd
ordering fix, distinct from the mDNS-arbitration logic. Offline guards:
`v2/tests/systemd-ordering-cycle.test.sh` (static `After=`/`Wants=` contract + a
dynamic ordering probe proving the unit runs after `network-online.target`) and
`manifest.bats` "hostname:" ordering assertions.

Each service attempt has a 120-second global claim budget, 3-second command
timeouts, and a 10-second local-lock wait. systemd caps the attempt at 150 seconds
and retries a failed attempt after 5 seconds. Missing/malformed Avahi state,
missing tooling, and failure to establish exact ownership all fail closed; there
is no random suffix or DNS-only availability fallback. The isolated provisioning
AP address is not a claimable LAN identity; Ethernet IPv4 link-local remains
eligible. A successful retry non-blockingly requeues identity consumers while
the hostname unit remains active, so an early no-network failure does not strand
CeraUI or TLS. On every restart the service reapplies the persisted identity to
the runtime hostname, `/etc/hostname`, `/etc/hosts`, and Avahi before CeraUI, TLS
certificate creation, or hawkBit enrollment may run. A separate 30-second
reconciliation timer checks strict Avahi and local identity state. Aligned and
`REGISTERING` snapshots cause no allocation or service churn; explicit conflict
or divergence reruns the bounded deterministic claim and restarts identity
consumers only after a successful commit. TLS validates the actual certificate
SAN and key pair, replacing it if the committed hostname advances. CI exercises
the production script against two real Avahi daemons in private D-Bus/network
namespaces for simultaneous boot and late-LAN-merge races. Operator behavior and
diagnostics are documented in [`docs/FIRST-BOOT.md`](docs/FIRST-BOOT.md) §4.

**Build concurrency** [EXISTS]

The orchestrator holds a per-board `flock` under `v2/mkosi/.staging/.locks/`
before touching staging, cache, or mkosi output. Different boards remain safe to
build in parallel. A second build of the same board waits for up to one hour by
default; set `CERALIVE_BUILD_LOCK_TIMEOUT=0` for fail-fast behavior or another
non-negative number of seconds for a bounded wait. This also prevents a CI
dry-run from deleting the staging tree of an active hardware image build.

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
  (machine-id-derived setup identifier), passphrase `ceralive-setup`
  (documented default), gateway `192.168.42.1/24`. **HW caveat:** AP mode also
  requires the onboard wlan driver to support it (RK3588 chip dependent) — to be
  validated on hardware, hence `[PARTIAL]`.
- **Regulatory DB (`wireless-regdb`) is an EXPLICIT `shared.list` entry.** WiFi in
  ANY mode (client or the AP above) needs `/lib/firmware/regulatory.db` (+ `.p7s`),
  which the kernel `cfg80211` subsystem loads at boot to establish a usable
  regulatory domain. It ships in Debian's `wireless-regdb` package — the Linux
  wireless project's regulatory database, NOT chip firmware, so it is **not** part
  of the RK3588 `armbian-firmware` bundle (unlike `rtl8852be-firmware`; see
  `rk3588.delta.list`). It is only `wpasupplicant`'s `Recommends:`, so the runtime
  layer's `apt-get install --no-install-recommends` (runtime/mkosi.postinst.chroot)
  never pulls it transitively — it MUST be named in `shared.list` explicitly. Absent
  it, every boot logs `platform regulatory.0: Direct firmware load for regulatory.db
  failed with error -2` / `cfg80211: failed to load regulatory.db` and NetworkManager
  reports "No WiFi interfaces found" even with a working driver (real-HW UART,
  2026-07-16; the RTL8852BE `rtw89_8852be` chip enumerates + trains PCIe fine — the
  missing DB is a distinct gap). Guard: `manifest.bats` "wireless-regdb is installed
  so cfg80211 loads regulatory.db".
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
- **Self-signed cert (no ACME/mTLS).** `ceralive-tls-firstboot.service` keeps a
  per-device self-signed key+cert in `/data/ceralive/tls/` across reboots and A/B
  OTA slot swaps. It validates the real SAN and key pair on each run, remaining
  byte-stable while the hostname is unchanged and replacing the pair after a
  deterministic hostname advance. CN/SAN = `<hostname>.local` + the device IPv4.
  **Browser caveat (honest):** the first visit
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
GPU userspace (`libmali-valhall-g610-g24p0-wayland-gbm` 1.9-1) is now **baked into
the base image** (Platform layer) via `firmware_packages` + the pinned userspace file
(see the "RK3588 HW-accel userspace" KEY FACT); it stays **excluded from the sysext**
by contract. Full recipe: [`v2/docs/cog-display-addon.md`](v2/docs/cog-display-addon.md).
**Hardware-gated:** `cog.sysext.conf` wired into the build only after RK3588 render
QA passes (same gate as Tasks 26/27/28) — on-hardware Mali EGL/GBM render is the
gated item, not the package availability.

**Implementation status:** Tasks 26 (systemd units), 27 (packages), 28 (RK3588 dual-GPU udev + touch calibration), and 30 (integration validation) are **hardware-blocked** — no RK3588 board is reachable from the dev environment (Task 1 spike: NO-GO). The architecture is fully specced; implementation waits for hardware access.

**Phase-3 deferrals:** e-ink kernel DRM driver + device-tree, dual-display hybrid, on-device live-video preview, and #61 battery/power telemetry (document-only: current boards are mains-powered, no fuel-gauge IC). Full register: [`v2/docs/kiosk-display.md §7`](v2/docs/kiosk-display.md).

**RK3588 mainline-patch contingency (D3 stays locked):** D3 (`armbian_branch: vendor`) is NOT changing. The Armbian vendor BSP kernel already provides HDMI hdmirx and mature Rockchip MPP H.265. If a mainline pivot is ever forced, the reference patch set is bookmarked in [`v2/docs/kiosk-display.md §3`](v2/docs/kiosk-display.md) (GPU contingency section): three patches from `https://github.com/rcawston/rockchip-rk3588-mainline-patches` covering VEPU580 H.265 encoder (WIP, pinned MPP fork required), HDMIRX EDID set fix, and HDMIRX plugout overflow fix. These are insurance only — do not apply without explicitly re-opening D3.

## ANTI-PATTERNS

- Don't change REPOS order or casing — downstream scripts key on exact names
- Don't add `ceralive-platform` to REPOS — cloud-only, not in device image
- Don't commit GPG private keys or mTLS certs — those come from `cert-work/` at build time
- Don't revert first-party fetch to R2 `aws s3 sync` / `gh release download` — first-party `.debs` are pulled at build time from `apt.ceralive.tv` (GPG + mTLS); see the "First-party .deb fetch" KEY FACT
- Keep `srt` in `REPOS` and map `libsrt1.5-ceralive` through `FIRST_PARTY_APT_PKGS`; do not add a Debian `libsrt1.5-*` runtime package to `shared.list`
- Don't implement kiosk units/packages without clearing the Task 1 hardware gate first
- Don't use `--native` as the default build path — container is canonical; native is opt-in
- Don't put GPU/BSP userspace (`libmali*`, `librockchip_mpp*`) in any add-on sysext — Platform-layer only
- Don't touch runtime apt sources on the device — `E4` guardrail
- Don't let add-ons gate OTA healthcheck/rollback — add-ons are orthogonal to the RAUC A/B slot
- Don't fetch BSP packages by bare name or accept apt's latest version. Update `armbian-bsp-deb-versions.txt` only after signed-index review; update `bsp-baseline.json` with the kernel pin when its reviewed bytes change
- Don't add `bsp-provenance.json` to the build-matrix `sha256` determinism comparison — it is gitignored build output by design

## KNOWN ISSUES / DEFERRED

Full index with file:line anchors and unblock conditions: [`v2/docs/DEFERRED.md`](v2/docs/DEFERRED.md).

**RK3588 predictable names — the subimage env-propagation contract.** The
deterministic `eth0/eth1/wlan0` renames (`install_interface_naming()` in
`postinst-lib.sh`, run from the runtime `mkosi.postinst.chroot`) and the add-on
signing keyring (`setup_addon_keyring()`) run inside a SUBIMAGE chroot. Their
inputs — `CERALIVE_INTERFACES_eth0/eth1/wlan0`, `ADDON_KEYRING_B64` — reach that
chroot ONLY through `PassEnvironment=` in `mkosi/mkosi.conf`. `orchestrate.sh`
exporting a name and listing it in `run_mkosi_build()`'s `env_names` is NOT
enough: mkosi's `--environment` populates the TOP-LEVEL image's script env only,
and the base/platform/runtime/app subimages each parse config in isolation. A
name present in `env_names` but MISSING from `PassEnvironment=` reads EMPTY in
every subimage — silently. That exact drift shipped two production bugs (eth0/eth1
never renamed → dropped from SRTLA's `eth*`/`wlan*` bonding globs, confirmed on
Rock 5B+ hardware; and an empty add-on keyring → all add-on signatures rejected).
`PassEnvironment=` MUST stay in lockstep with `env_names`; the structural guard is
`manifest.bats` "mkosi PassEnvironment stays in lockstep with … env_names" (it
fails the build if a future `env_names` addition skips `PassEnvironment=`).
`SOURCE_DATE_EPOCH` (host-side/mkosi-native) and `CERALIVE_V2_DIR` (forwarded via
a separate `-e`/`--environment` mechanism) are the two documented legitimate
asymmetries.

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
