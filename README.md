# CeraLive Image Building Pipeline

A build pipeline for creating ready-to-use images for ARM-based streaming devices,
targeting Rockchip RK3588 devices (Orange Pi 5+, Radxa Rock 5B+) with future
support for Intel N100/N200 and AMD platforms.

> Status: Alpha — interfaces and docs may evolve. Contributions welcome! See [CONTRIBUTING.md](./CONTRIBUTING.md).

## Build Requirements (at a glance)

| Requirement | Version / detail | Verified |
|---|---|---|
| mkosi | ≥ 26 (native builds only; container build needs none of this host-side) | `mkosi --version` → `mkosi 26` on this host |
| Python | ≥ 3.12 (native build host requirement) | this host runs 3.14.6 |
| Container runtime | Docker or Podman — the container build is canonical | `docker --version` → 29.7.2; `podman --version` → 6.0.2, both present |
| Disk | ~24 GiB free workspace + Docker root for the production-runner contract; a dev box needs headroom for the mkosi cache + `.staging/` + output `.raw`/`.raucb` per board | see `df -h` in the full prerequisites walkthrough below |
| ccache | recommended for repeat kernel-from-source builds (`--variant edge` / `--variant vendor-patched`) | `which ccache` → `/usr/bin/ccache` present on this host |

This table is the quick-reference; the full, step-by-step, executed walkthrough
— including the container-vs-native host matrix, the full board × kernel-track
× image-variant build matrix, and every flash path — lives in
[`docs/DEVICE-BRINGUP.md`](docs/DEVICE-BRINGUP.md) §1-4. **The container build
is canonical** — most of the table above (mkosi/Python versions) matters only
if you opt into `--native`; a container build only needs Docker or Podman.

## Supported Devices

### Current (RK3588-based)
- **Orange Pi 5+** — HDMI input, good power delivery
- **Radxa Rock 5B+** — best HDMI input EMI resistance, M.2 modem support

### Future Support
- Intel N100/N200 devices
- AMD-based microcomputers

## Key Features

- **Streaming-focused**: SRTLA bonding, WiFi management, HDMI capture
- **Hardware acceleration**: Rockchip MPP integration for encoding
- **Custom software stack**: `CeraUI`, `cerastream`, `srtla-send-rs`, `srt` via .deb packages
- **Minimal system**: Debian bookworm-based with minimal apt sources
- **Ready-to-use**: Images for eMMC/SD cards, no additional setup required
- **Predictable LAN identity**: Avahi-arbitrated `ceralive.local`, `ceralive2.local`,
  `ceralive3.local`, ... allocation with no random or hyphenated fallback
- **Device support**: Automatic USB audio/video device detection and access
- **Modem support**: M.2 and USB 4G/5G modems
- **Feature add-ons**: Optional per-board/per-OS sysext `.raw` artifacts (display engine, debug tools, etc.)

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    CeraUI Application                       │
├─────────────────────────────────────────────────────────────┤
│ cerastream  │ srtla-send-rs│     srt     │   WiFi Manager   │
├─────────────────────────────────────────────────────────────┤
│           GStreamer + Rockchip MPP (Hardware Encoding)      │
├─────────────────────────────────────────────────────────────┤
│            Debian bookworm + CeraLive Customizations        │
├─────────────────────────────────────────────────────────────┤
│                    Hardware Layer                           │
│  Orange Pi 5+ │ Radxa Rock 5B+ │ Future Intel/AMD devices  │
└─────────────────────────────────────────────────────────────┘
```

## Build System

The build path lives at the repository root and uses mkosi v26 inside a pinned `debian:trixie-slim`
container (`ci/Dockerfile`). It produces reproducible `.raw` sysext bundles and
`.raucb` A/B RAUC OTA packages from a layered source.

**The container build is canonical.** Native builds (`--native` /
`MKOSI_NATIVE=1`) are opt-in and require mkosi ≥ 26 + Python ≥ 3.12 on a Debian
trixie+ host. See [`docs/host-support.md`](docs/host-support.md) for the
full host matrix (Ubuntu/Debian, Arch, Fedora, macOS Apple Silicon, WSL2).

The protected production-candidate job has a stricter host contract than local
development: it pins Docker's native Linux `default` context and fails before
BuildKit unless the daemon exposes at least 16 GiB RAM, live memory plus swap
headroom is at least 16 GiB, and both the workspace and Docker root have at
least 24 GiB free. Docker Desktop is not a supported production runner daemon.
On the persistent self-hosted runner, digest-pinned pre-checkout and `always()`
post-run cleanup removes only the ignored mkosi `build` and `cache` paths so an
interrupted rootful build cannot block the next clean checkout.
See the production-runner section of the host matrix for the exact checks.

See [`docs/dev-loop.md`](docs/dev-loop.md) for the full dev loop.

Rock 5B+ production images use a populated A/B factory layout: both 4096 MiB
rootfs slots carry the baseline OS, slot A starts primary, and RAUC uses the
RK3588 custom bootcount backend with explicit `rauc.slot=A|B` kernel arguments.
Before flashing, run `tests/preflash-verify.sh --target-size-bytes <bytes>`; it
requires exact GPT geometry, both RK3588 bootloader stages, bounded and SHA-256-valid
embedded/external FIT payloads, a compiled selector, complete kernel/DTB/initrd sets
in both slots, and a real compatible signed bundle.
Images are hand-tested on real hardware before a manual release is cut — there
is no automated CI job that flashes or tests real hardware. The bench
flash-and-verify tool (`ci/verify-and-flash-candidate.sh`, run by an operator)
starts with one Rock 5B+ in Maskrom, carries a SHA-256-pinned loader in the
candidate artifact, checks loader-mode eMMC capacity, and verifies a full readback
before reset. A canonical hash approves the Maskrom USB port before loader
transfer. The initial `rkdeveloptool db` runs under a pinned leader in an owned
process group with a monotonic 15-second budget and bounded one-second
TERM-to-KILL cleanup. Returning from `db` is not treated as success: for up to 10
seconds the tool requires the same VID/PID/`LocationID` to reappear in exact
`Loader` mode before it can query capacity or identity. A timeout, malformed or
multiple listing, changed fixture, or unexpected mode fails with no retry and
before `rfi`, write, readback, or reset. Command timeout and USB re-enumeration
timeout have separate diagnostics. After flashing and readback, `/` on the booted
board must resolve to the flashed eMMC. UART observes first boot through a bounded
one-shot bootstrap that emits a fresh device nonce. Its request is signed by a
host-local key, bound to that nonce and the baked candidate commit, protected by
consumed-nonce and non-decreasing epoch records on `/data`, and provisions only a
restricted, expiring per-run root SSH public key into `/data`; the immutable image
contains no CI SSH credential or password (only the UART verification public key).
The runner key is matched to that public key before USB access, and cleanup proves
the exact key and marker were removed after the physical checks. Planned RAUC
reboots consume a one-use retention marker; any unarmed later boot revokes
leftover CI access before sshd starts. Legacy single-slot images require a full
re-flash because their data partition overlaps the new B-slot extent; they cannot
be converted by OTA.

## Directory Structure

```
.                          # Build system lives at the repository root (mkosi v26)
├── build                  # Entry point: ./build <board>
├── run-tests              # Canonical test entrypoint
├── dev-push / dev-sync    # Dev-loop helpers
├── ci/
│   ├── Dockerfile         # Pinned trixie-slim builder (mkosi 26)
│   └── publish-immutable-r2-pair.sh # Approved RAUC bundle publisher
├── manifests/             # Board/family manifests, package pins, add-on descriptors
├── lib/                   # Orchestrator, assembler, bundle scripts,
│   │                      #   build-all.sh (parallel runner),
│   │                      #   build-feature-sysext.sh (add-on builder),
│   │                      #   fetch-debs.sh (REPOS + FIRST_PARTY_APT_PKGS)
│   └── app-layer/         # sysext.sh — extract → prune → squashfs
├── mkosi/                 # mkosi config, customize hooks, runtime artifacts, platform
├── fleet/                 # hawkBit provisioning + platform bridge
├── docs/                  # Dev loop, kiosk display, host support, size notes,
│   │                      #   Cog add-on recipe, sysext refresh protocol,
│   │                      #   fast-reload.md (dev-sync live-reload loop)
│   └── partition-contract.md # Frozen GPT layout contract
├── tests/                 # Six manifest contract suites + shared manifest-helpers.bash,
│                          #   RK3588 A/B/preflash + x86 rollback
└── CONTRIBUTING.md        # Contribution rules
```

## Quick Start

```bash
cd image-building-pipeline

# Build for a specific board (container build — canonical)
./build rock-5b-plus
./build orange-pi-5-plus

# Build every board manifest, or a named subset
./build --all
./build --only rock-5b-plus,x86-minipc

# Opt-in family variant (rk3588 'edge' = kernel built from pinned source)
./build rock-5b-plus --variant edge

# Dry run (resolve + fetch plan only, no image written)
DRY_RUN=1 ./build rock-5b-plus
DRY_RUN=1 ./build --all                 # preview the resolved board list

# Opt-in native build (Debian trixie+ host with mkosi ≥ 26 only)
./build rock-5b-plus --native
```

A single resolved board execs the orchestrator directly. A multi-board selection
(`--all`, or `--only` with 2+ boards) is handed to the parallel runner
`lib/build-all.sh`. An unknown board in `--only` fails loudly: it names the
offender and lists the available boards.

For the full developer bring-up guide (prerequisites, flashing, dev loop, E2E
smoke test, and signing), see
[`docs/DEVICE-BRINGUP.md`](docs/DEVICE-BRINGUP.md).

### The full build matrix

Every real build is a point in a 3-axis space — board × kernel track × image
variant. Not every cell is populated: kernel-from-source variants are opt-in
and only the `rk3588` family declares them; `x86-minipc` has no kernel-track
axis at all (it always uses its prebuilt Debian kernel path). `PRODUCTION` is
the default in every cell; `DEBUG` is bench-only and never published (see
"Production vs Debug Image Variants" below).

| Board | Kernel track | Command | Notes |
|---|---|---|---|
| `rock-5b-plus` | vendor 6.1 BSP (prebuilt, shipped) | `./build rock-5b-plus` | production path; the kernel the fleet actually runs |
| `rock-5b-plus` | vendor 6.1 BSP, source-built + HDMI-RX audio fix | `./build rock-5b-plus --variant vendor-patched` | same 6.1.115 BSP, rebuilt from pinned source with the 5-patch HDMI-RX capture series; compiles and boots; the patch series is Tier 1 board-confirmed on a hand-built kernel (incl. CeraUI audio-meter validation), Tier 2 open on this pipeline's own built image, which has not itself been booted |
| `rock-5b-plus` | mainline 7.1 (source-built) | `./build rock-5b-plus --variant edge` | compiles and boots; at the `v7.1.7` pin MPP hardware video encode now works here too — board-confirmed on this board only (see the pipeline `AGENTS.md` "MPP hardware video encode" entry) — still a bench/insurance track |
| `orange-pi-5-plus` | vendor 6.1 BSP (prebuilt, shipped) | `./build orange-pi-5-plus` | production path |
| `orange-pi-5-plus` | mainline 7.1 (source-built) | `./build orange-pi-5-plus --variant edge` | compiles and passes all four validation axes; never booted, so the MPP result above is unconfirmed on this board |
| `orange-pi-5-plus` | vendor-patched | not yet run against this board | `variant_overrides` exist for `edge`'s DTB name; `vendor-patched` has not been separately proven on this board |
| `x86-minipc` | n/a (Debian prebuilt) | `./build x86-minipc` | GRUB A/B disk assembly ships; **not yet validated on hardware** — see `docs/X86-MINIPC-BRINGUP.md` |
| any board | any track | add `CERALIVE_DEBUG_IMAGE=1 CERALIVE_DEBUG_PASSWORD_HASH='<crypt(3) hash>'` | DEBUG variant — bench only, adds the development package delta and enables SSH by default; see "Production vs Debug Image Variants" below |

Bulk/dry-run forms cut across every cell: `./build --all`, `./build --only
<comma-list>`, and `DRY_RUN=1` in front of any of the above to resolve+fetch a
plan with no image written (see the executed transcript in
[`docs/DEVICE-BRINGUP.md`](docs/DEVICE-BRINGUP.md) §2).

The complete hardware-free CI/test entrypoint is
`CERALIVE_RUN_REAL_AVAHI_CONTRACT=required
CERALIVE_RUN_REAL_RAUC_CONTRACT=required
CERALIVE_RUN_REAL_PRIVILEGE_DROP_CONTRACT=required ./run-tests`. It creates the
ignored, NON-PRODUCTION RAUC signing fixture on demand; production builds must
still provide `CERALIVE_RAUC_PKI_DIR` explicitly. The real-Avahi leg uses private
network namespaces and D-Bus sockets to prove simultaneous first boot and
late-network-merge reconciliation without touching the host publication.

All three default to `skip` so a developer machine is never mounted on
unexpectedly, and CI sets each to `required`. The first two decide whether their
suite runs at all. The third is narrower: it governs only the three
package-index probes in `tests/mkosi-package-staging.test.sh` that must run
`find` as a different, unprivileged UID (via `runuser` as real root, or
passwordless `sudo`). Those probes always run when that privilege IS available,
whichever value is set — `skip` only decides that a genuinely unavailable probe
reports `SKIP` instead of failing, while `required` makes its absence fatal. The
rest of that file needs no privilege and always runs, which is why it stays in
the always-run `default-shell` set rather than being reclassified `opt-in`.
When GNU parallel is available, Bats files run in parallel but cases within each
file stay serial; tests that share the build staging tree also use file locks so
CI concurrency cannot alter their assertions. The real-RAUC harness uses RAUC's
supported boot-slot override for its synthetic file-backed slots, so CI does not
depend on the runner's boot device. The CI Bats job also installs Ubuntu's split
`rauc` + `rauc-service` packages and starts a system D-Bus before the required
real-RAUC contract, reloading the installed bus policy; it does not substitute
a session bus or skip the service check. Standalone DRY_RUN build-plan jobs also
materialize the same ignored NON-PRODUCTION fixture before resolving, so they
do not depend on the Bats job's checkout.

Production RAUC publication follows [`docs/RELEASE-PROCESS.md`](docs/RELEASE-PROCESS.md)
§5. Its low-level `ci/publish-immutable-r2-pair.sh` helper requires the
independently approved candidate SHA-256, snapshots both inputs privately, and
uses create-only writes with exact-byte retry recovery; it never deletes an
immutable release key.

## Custom Components

All custom components are distributed via .deb packages from our repository:

- **CeraUI**: Main streaming application UI
- **cerastream**: The streaming engine (Rust) — sole engine since 2026-06-11, when the legacy
  ceracoder encoder was retired after the generic boot-parity profile passed; RK3588
  hardware-gated profiles now track as cerastream hardware-validation work, while
  Jetson profiles are DEFERRED — not currently planned
- **srtla**: SRT Link Aggregation implementation
- **srt**: Custom SRT implementation

Repository location: `/etc/opt/ceraui/`

## Feature Add-Ons

Optional capabilities are delivered as signed per-board/per-OS sysext `.raw`
artifacts, served from `apt.ceralive.tv/R2` at path
`addons/{os_version}/{board}/{feature}.raw`. Each add-on:

- Extends `/usr` and `/opt` only (`SYSEXT_LEVEL=1`, `VERSION_ID=12`)
- Is GPG-signed with the add-on keyring from `cert-work/`
- Has a sha256 checksum verified by CeraUI before activation
- Is managed at runtime by the CeraUI add-on manager (install, enable, disable)

Current validated add-ons:

| Add-on | Status | Notes |
|--------|--------|-------|
| `cog` (Cog + WPEWebKit display engine) | `[PARTIAL]` — packaging validated, hardware-gated | See [`docs/cog-display-addon.md`](docs/cog-display-addon.md) |

Build a feature sysext:

```bash
lib/build-feature-sysext.sh \
  --descriptor manifests/addons/<id>.sysext.conf \
  --board rock-5b-plus \
  --out dist/
```

## Production vs Debug Image Variants

Every build is one of two variants, selected by a single environment flag:

```bash
./build rock-5b-plus                                    # PRODUCTION (default)

CERALIVE_DEBUG_IMAGE=1 \
CERALIVE_DEBUG_PASSWORD_HASH='<crypt(3) hash>' \
  ./build rock-5b-plus                                  # DEBUG (bench only)
```

**Production** is the shipped image: the runtime package set is
`manifests/packages/shared.list` plus the resolved `<family>.delta.list` and
nothing else, `ssh.service` is not enabled, and the `ceralive` account is
password-locked.

**Debug** is that same image plus `manifests/packages/development.delta.list` —
`python3`, `strace`, `tcpdump` and the fifteen `debug-toolset` diagnostics
(`alsa-utils`, `usbutils`, `pciutils`, `lsof`, `i2c-tools`, `can-utils`, `htop`,
`iotop`, `nethogs`, `vnstat`, `nano`, `iperf3`, `socat`, `netcat-openbsd`,
`pulseaudio`) — and keeps its existing access behaviour: the injected password
hash unlocks `ceralive`, `ssh.service` is enabled by default, and
`/etc/ceralive/debug-image` is baked as the marker. The flag is validated before
the package set is resolved, so a value other than `0`/`1`, a hash without the
flag, or the flag without a hash all abort the build.

The debug image is **bench only and is never published to apt or R2**. No release
or publish path sets the flag.

Both variants keep the same **field-diagnostics** route: the signed `debug-toolset`
sysext add-on, installed at runtime on an ordinary production image with no
reflash. The delta exists for the case the add-on cannot serve — debugging the
boot / first-boot window, before any network or add-on manager is up. The two sets
are deliberately identical so an operator does not have to know which route they
are on.

Adding a package to `development.delta.list` must not duplicate anything already
in `shared.list`, and any new code that reads `manifests/packages/*.delta.list`
must select its files through `lib/common.sh::runtime_pkg_list_files` — that
helper is what keeps the variant-keyed debug delta out of the production package
contract. Guards: `tests/package-contract.bats` §30.

## Build-Log Census

A build that exits 0 is not the same as a build that is clean. A real
`rock-5b-plus --variant edge` build emitted 26 distinct warning/error signatures
on its way to a successful `.raw` + `.raucb` — among them two mkosi deprecation
notices, three `GrowFileSystem=` keys systemd-repart silently ignored, an
`update-alternatives: error`, an initrd that quietly fell back to gzip, and eight
multi-GB cross-filesystem copies.

[`docs/build-log-census.md`](docs/build-log-census.md) freezes all 26 with a
baseline count, build stage, owner and a disposition — `FIXED` (removed; must
never reappear), `ACCEPTED` (external or inherent, allowed up to its baseline
count) or `BLOCKING`. 12 are FIXED, 14 ACCEPTED, 0 BLOCKING.

```bash
ci/check-build-log-census.py --expect-count 26 docs/build-log-census.md  # schema
ci/check-build-log.sh --self-test                                        # non-vacuity
ci/check-build-log.sh <build.log>                                        # the gate
ci/check-build-log.sh --census-report <build.log>                        # counts only
```

The lint rejects a `BLOCKING` signature, a `FIXED` regression, a signature in no
table at all, and an `ACCEPTED` signature that appears more often than its
baseline. There are no wildcard exceptions: every entry is compared with `==`
against a normalized line. It runs in `release.yml` right after the production
candidate build, which is the only place a real production build log exists — the
PR gate is `DRY_RUN=1` and never executes the image layers.

## Image Size Gate

Every real build runs `lib/measure-size.sh` as the orchestrator's `[6c/9]` stage,
between the normalized-tar emit and the parity check. If the rootfs content's
apparent size exceeds **1.5 GB** the build fails there, so no `.raw` and no `.raucb`
are produced. A `DRY_RUN=1` plan-only run never reaches it, and an
`INSTALL_BOOT_BSP=0` parity build skips it with a warning (a kernel-less rootfs is
not the shipped image). It is not architecture-gated — every shipped board carries a
real ceiling. See [`docs/size-notes.md`](docs/size-notes.md) for the wiring
(§10) and the levers applied (locale strip, `WithDocs=no`, firmware audit, Mesa
software-GL prune).

Both RK3588 boards are under the ceiling: `rock-5b-plus` 1,412,259,840 B and
`orange-pi-5-plus` 1,418,792,960 B. The largest single lever is the Mesa
software-GL prune — `libgl1-mesa-dri` drags LLVM's JIT and the Z3 solver into the
image for a software rasterizer that can never run, because the Mali vendor driver
wins the EGL/GLES/GBM lookup. The metapackage stays installed (removing it would
cascade into the GStreamer plugins cerastream needs); only its 157.6 MB of
unreachable payload is stripped.

## BSP Package Pins, Provenance + Advisory Drift-Guard

Armbian BSP metadata is accepted only with a public keyring whose primary-key
fingerprints are exactly the current dual-signing transition set:
`DF00FAF1C577104B50BF1D0093D6889F9F0E78D5` and
`8CFA83D13EB2181EEF5843E41EB30FAF236099FE`. A missing key, unusable primary or
subkey, malformed keyring, normalization failure, or unrelated extra primary key
fails before apt runs. The SHA-pinned official key sources, identities, live
`InRelease` check, and stdin-only GitHub secret update are documented in
[`docs/RELEASE-PROCESS.md`](docs/RELEASE-PROCESS.md) §4.

Family manifests select BSP package names; the reviewed exact Debian versions
live in `manifests/armbian-bsp-deb-versions.txt`. Before downloading anything,
both native apt and curl paths extract `gpgv`'s verified Release plaintext,
require both pinned Armbian signatures, and verify that plaintext identifies the
configured suite, `main` component, and architecture. The curl path then requires
one compatible (`arm64` or `all`) record for every exact `package=version` spec.
Every staged package SHA-256 and Debian control package/version/architecture are
verified. Verified `.deb` archives are staged atomically as mode `0644`, then
partitioned into mode-`0755` mkosi consumer directories with archive mode `0644`.
Those modes are explicit even under a restrictive runner umask because mkosi's
sandboxed local-repository helper is unprivileged. Container builds mount only
the BSP and first-party consumer leaves read-only, so private mode-`0700` runner
checkout ancestors remain private without hiding packages from mkosi. The
platform postinstall is non-chrooted so mkosi exposes its `mkosi-install`
wrapper; raw `apt-get` would miss the generated `file:/repository` and its
ephemeral package-list state while installing the authenticated BSP. Mode, mount, rename, or local
repository consumption failures fail closed and remove private package-temporary
artifacts. There is no fallback to another version, suite, architecture, or
mirror.
Families with `armbian_branch: none` omit Armbian from DRY_RUN and fail closed on
a real BSP fetch until an authenticated, exact-versioned non-Armbian package
source is implemented.

After the BSP fetch, `lib/fetch-debs.sh` writes the kernel package's resolved
version + content `sha256` to `bsp-provenance.json` in the image output dir
(gitignored, never committed), then runs the content drift-guard against the
committed baseline `manifests/bsp-baseline.json`.

- A differing version **or** a same-version content-hash re-spin prints a
  `BSP drift` warning. It is warn-only by default; `BSP_DRIFT_STRICT=1` makes a
  mismatch against a seeded baseline fatal.
- The baseline is seeded with the reviewed Armbian 26.5.1 kernel package version
  and SHA-256. A package promotion requires an authenticated signed-index review
  and explicit updates to the version registry and kernel baseline.
- The provenance artifact is deliberately **excluded** from the build-plan `sha256`
  determinism comparison; that comparison hashes the normalized plan, not build
  output files.

## Verified `.deb` Download Cache

All three verified fetch families — the Armbian BSP, the RK3588 HW-accel userspace
pins, and the first-party packages from `apt.ceralive.tv` — share a persistent
content-addressed cache at `mkosi/.staging/.debcache/`, keyed on
`<package>_<version>_<arch>.deb`. A second real fetch of the same plan performs
**zero `.deb` payload downloads**.

Reuse cannot weaken verification. Every family already resolves the artifact's
expected SHA-256 *before* it downloads — from the `gpgv`-verified `Packages` index
on the four apt/curl transports, or from the committed
`rk3588-userspace-deb-versions.txt` pin file — so a cache hit is re-checked against
exactly the hash the network path would have been checked against. An entry whose
hash no longer matches is deleted and re-fetched, not skipped.

Only final `.deb` payloads are cached. `InRelease`, `Release`, `Packages.gz`, the
apt lists and the GPG keyring are never cached: that is the rotating trust material
whose whole job is to be fresh. Index metadata is therefore still fetched on every
run, and the "zero downloads" claim is about payloads only.

Concurrency is a **per-cache-key `flock`** under `.debcache/.locks/`, not the
orchestrator's per-board build lock — that one is keyed on a single board and
different boards are explicitly allowed to build in parallel, so it cannot protect
a cache all of them share. A reader holds its key lock across the whole hit
sequence (existence check → SHA re-verification → copy-out), and eviction takes
each victim's own key lock before unlinking, skipping any victim a reader is
currently holding.

```bash
CERALIVE_DEBCACHE=0 ./build rock-5b-plus              # disable it entirely
CERALIVE_DEBCACHE_MAX_BYTES=8589934592 ./build …      # raise the 4 GiB ceiling
CERALIVE_DEBCACHE_DIR=/srv/debcache ./build …         # relocate it
```

The cache is bounded at 4 GiB by default and evicted least-recently-used first by
mtime, which a reuse refreshes. Disabled, the fetch behaves exactly as it did
before the cache existed; a `DRY_RUN=1` plan never touches it and its resolved
output is byte-identical. Every cache failure is non-fatal — an unwritable
directory or a lost lock degrades to an ordinary download. Contract:
`tests/debcache.test.sh`.

## Kernel Freeze — the boot stack updates via RAUC only

The kernel, device tree, board U-Boot and firmware packages change **only** when a
full-image RAUC bundle writes a new rootfs slot. They are never changed by `apt` on
the running device, because `docs/partition-contract.md` rule 3 puts kernel/DTB/initrd
*inside* each slot — an in-place apt upgrade would rewrite `/boot` in the running slot
and leave the rollback target a slot nobody tested.

Every image bakes two layers of enforcement:

- **`apt-mark hold`** on each package — the primary mechanism, and the only one that
  also blocks an explicit `apt-get install <pkg>`. The build verifies each hold landed
  and fails if one did not.
- **`/etc/apt/preferences.d/ceralive-kernel-freeze`** — a supplementary
  `Pin: version <installed>` / `Pin-Priority: 1001` stanza per package. It pins by
  name+version rather than origin because the boot BSP is installed from a
  build-time-only local package directory that has no apt-origin identity on the
  device. Apt preferences rank candidate versions and do not forbid an explicitly
  named one, so `apt-get install <pkg>=<ver>`, `--allow-downgrades` and `dpkg -i`
  bypass the pin — the limitation is stated in the generated file itself, and is why
  the hold is primary.

The package set comes from the resolved manifest, so each board's own U-Boot package
(`linux-u-boot-rock-5b-plus-vendor` / `linux-u-boot-orangepi5-plus-vendor`) is covered
without any hardcoded name.

**First-party CeraLive packages are deliberately not held.** `cerastream`,
`ceralive-device`, `srtla-send-rs`, the forked libsrt and the ModemManager closure
stay apt-updatable from `apt.ceralive.tv` — that is the software-update path CeraUI
drives — and the build refuses by name if one ever reaches the freeze set. There is no
`unattended-upgrades` on the image.

**RAUC does not consult dpkg holds.** It writes the whole inactive slot without
running dpkg or apt; the new slot arrives with its own dpkg database and its own baked
holds. Each image freezes itself, so nothing has to be unheld before an update or
re-held after one.

Verify on a device with `apt-mark showhold`, `apt-cache policy linux-image-vendor-rk35xx`
and `apt-get -s upgrade`. Full contract:
[`docs/kernel-freeze-contract.md`](docs/kernel-freeze-contract.md).

## OTA-During-Stream Guard

`/usr/local/bin/ceralive-update` (the RAUC update entrypoint CeraUI invokes)
refuses to install a bundle while the device is actively streaming. It checks
all three live-media units with `systemctl is-active` and aborts if any is
running:

- `cerastream.service` — the encoder
- `srtla.service` — the bonding **receiver** role
- `srtla-send.service` — the bonding **sender** role

A stopped or not-installed unit reads `inactive`, so the guard is a no-op on a
device that isn't streaming. The sender unit (`srtla-send.service`) is the one
that actually carries the uplink on a bonding sender device, so it is now part
of the guard alongside the encoder and receiver. Proof: `run-tests`
section 16.

## USB-C Type-C Source-Role Pinning

The board's USB-C connector is a dual-role (DRP) FUSB302/TCPM port, so on a fresh
boot it does not pick a role — it toggles, and Try.SRC/Try.SNK arbitration on the
cable decides. Against a camera that is *also* dual-role that arbitration genuinely
races, and whenever it settles on the sink side the SoC runs as a USB peripheral and
the camera never appears on the bus at all. That is the root cause of "the camera
sometimes isn't detected over USB-C".

`ceralive-typec-source.service` (a oneshot ordered before `cerastream.service`) pins
`/sys/class/typec/port0/port_type` to `source` on every boot, which removes the
arbitration entirely. The connector attribute is created by an asynchronous driver
probe, so the unit polls for it to a deadline rather than sleeping a fixed amount; a
board with no Type-C connector, or a port that never appears, is a clean no-op.

Verified live on a Rock 5B+ (including straight after a cold power-cycle): with the
port pinned, the camera enumerates within seconds on every attempt. **This code is
merged-ready but has not been through a release — no published image carries it yet,
and the persistent behaviour still needs an on-hardware board-proof.** Guards:
`tests/runtime-services.bats` §18d.

## Fan Curve

The RK3588 package thermal zone ships from the device tree with its first `active`
trip at 55 °C (plus a second at 65 °C and a `critical` trip at 115 °C), while the
board idles at 46-52 °C. The fan is therefore silent through the entire normal
operating range and only becomes audible once heat has already built up. The
`pwm-fan` cooling device itself is healthy — its `cooling-levels` range reliably
spins the fan — it is simply never asked to run.

`ceralive-fan-curve.service` (a boot oneshot) lowers exactly one value: the
temperature of the **first `active` trip** in the thermal zone bound to the
`pwm-fan` cooling device, from 55 °C to **45 °C**. The threshold is one named,
documented constant (`CERALIVE_FAN_TRIP_MILLIC`), clamped to a 20-90 °C band.

It never writes `thermal_zone*/mode` (that would also disable the 115 °C critical
trip), never writes `cur_state` or the hwmon PWM node, never touches any non-`active`
trip, and runs no monitoring loop. The kernel's `step_wise` governor keeps doing all
of the actual fan control.

Discovery is fully generic — it matches `cooling_device*/type == pwm-fan`, resolves
each zone's `cdevN` symlinks to find the binding zone, and walks trip points in
numeric order. No zone or cooling-device index is hardcoded, because both are
registration-order artefacts that differ per board and per kernel tree. A board with
no such device (x86-minipc) logs one informational line and exits 0.

## Fan Kick-Start

The fan curve above fixed *when* the fan is asked to spin. This fixes the fact that
the state it is asked *into* cannot start it from a dead stop. On an Orange Pi 5 Plus
the `pwm-fan` cooling device declares `cooling-levels = <0 70 75 80 100>` out of 255,
so the first active state is only **~27.5 % duty** — enough to keep a turning rotor
turning, not enough to break static friction on a stopped one. The fan sits energised
and stalled until someone nudges it by hand, which is exactly the long-standing
operator complaint that the fan "gets stuck and needs a push".

`ceralive-fan-kickstart.service` watches the cooling device's own `cur_state` and, on
a **0 → nonzero transition only**, drives it to that device's `max_state` for a
bounded ~1 s before writing the governor's commanded state straight back. It is
upstream Linux's own answer to this problem — `fan-stop-to-start-percent` /
`fan-stop-to-start-us` in `pwm-fan.c` — ported to userspace because those device-tree
properties postdate both v6.1 and v6.6 and so do not exist in this board's kernel.

**The restore write is mandatory, not cosmetic.** On this kernel a userspace
`cur_state` write is *sticky*: the sysfs store never clears the cooling device's
`updated` flag, the thermal core's re-assert path short-circuits while that flag is
set, and `step_wise` clears it only when its computed target changes. "Kick and let
the governor's next poll correct it" would therefore leave the fan at full speed for
as long as the temperature stayed inside one trip band. Writing the governor's own
state back is what makes the full-PWM period equal to the timer instead.

Unlike every other unit in this family it is **resident**, not a boot oneshot, because
the fan returns to state 0 and re-enters an active state many times over a device's
uptime and each re-entry is a fresh dead start. It never fires on `nonzero → nonzero`
or on `anything → 0`, never writes the hwmon PWM nodes, `thermal_zone*/mode` or any
trip point, and takes its kick value from the discovered device's own `max_state` —
never a hardcoded index and never a hand-invented "100 %". A board with no `pwm-fan`,
or one whose only active state is already `max_state` (nothing to kick above), logs
one informational line and exits 0.

## Status LEDs

The board's indicator LEDs are registered by the kernel and then left completely
unconfigured. On an Orange Pi 5 Plus, `blue:indicator-1` (gpio-leds) and
`green:indicator-2` (pwm-leds) both sit at `trigger = [none]` with
`brightness = 0` for the life of the device — wired, working, and never asked to
do anything. A headless appliance with no screen therefore gives its operator no
visual evidence that it booted or that it is doing any work.

`ceralive-led-status.service` (a boot oneshot) assigns an ordered default policy
to the LEDs it discovers: the **first** indicator LED gets the stock `heartbeat`
trigger (the kernel is alive and scheduling) and the **second** gets `mmc1`
(card activity — the board is doing I/O). Each trigger is verified to be offered
by that LED's own `trigger` menu before anything is written.

It never writes `brightness` — a trigger hands the LED to the kernel, and writing
brightness afterwards fights the trigger just installed — and it never re-points
an LED that already has a trigger, so it is idempotent across reboots and A/B
slot swaps.

Discovery is fully generic: the LED name is split on `:` and the LED is skipped
if any field matches `mmc[0-9]*` (the MMC core's own, already-working activity
LED, e.g. `mmc0::`) or `power` (a power-rail indicator must keep meaning
"powered"). No LED name is hardcoded, because `indicator-1`/`indicator-2` are
vendor DTS labels that carry no semantics and differ per board and per kernel
tree. A board with no LEDs, one LED, or more than two logs one informational line
and exits 0.

There is no red LED in the kernel's LED class on this board — the visible red one
is a hardwired power-rail indicator with no software visibility, and nothing here
can drive it.

## Supported-Modem Matrix + WWAN Module Check

The cellular modem stack (ModemManager + libqmi/libmbim + usb-modeswitch, SRTLA
modem source-routing, the M.2 SIM-detection quirk, and the known-good modem
table) is documented as-is in
[`docs/modem-matrix.md`](docs/modem-matrix.md).

Because an upstream repository can replace package bytes under the same Debian
version, a same-version Armbian re-spin could drop one of the six WWAN kernel modules the modem stack binds to
(`qmi_wwan`, `cdc_mbim`, `cdc_wdm`, `option`, `cdc_ether`, `cdc_ncm`) with no
signal. `lib/check-wwan-modules.sh` inspects a kernel `.deb` (or an extracted
module tree) and reports each module as loadable (`=m`), built-in (`=y`, in
`modules.builtin`), or present via `modules.alias`:

```bash
lib/check-wwan-modules.sh <kernel.deb | module-tree-dir>
```

It is **advisory only**, like the BSP drift-guard: a missing module prints a
WARNING but the check **always exits 0** — it never fails the build and never
edits `shared.list` or the kernel config. It is hyphen/underscore aware (the
`cdc_wdm` module ships on disk as `cdc-wdm.ko`) and matches the `option` module
by an exact `option.ko` / `modules.builtin` / alias entry, never a bare `option`
substring. Proof: `run-tests` section 17.

## Kernel Build From Source (opt-in)

The rk3588 family manifest carries two **opt-in** variants that build the kernel
and its in-tree DTBs from **pinned source**, instead of fetching the prebuilt
Armbian kernel:

```bash
./build rock-5b-plus --variant edge             # mainline 7.1 track
./build rock-5b-plus --variant vendor-patched   # vendor 6.1 BSP + HDMI-RX audio fix
```

They target different kernel tracks with different patch repositories, and
neither repository's patches apply to the other's tree:

| Variant | Kernel | Patch series | Built package |
|---|---|---|---|
| `edge` | mainline `v7.1.7` | `CERALIVE/rk3588-kernel-patches` | `linux-image-7.1.7-ceralive-rk3588` |
| `vendor-patched` | Armbian vendor BSP 6.1.115 — **the kernel the shipped image actually runs** | `CERALIVE/rk3588-vendor-kernel-patches` | `linux-image-6.1.115-ceralive-vendor-rk35xx` |

`vendor-patched` rebuilds the same 6.1.115 BSP the production path installs
prebuilt, with three patches that restore **HDMI-RX audio capture**. The stock
vendor kernel lost it when an upstream fix for RK3576 HDMI *transmit* zeroed
`hdmi-audio-codec` capture channels for every instance — including the codec
RK3588 registers HDMI *receive* through. The built package is deliberately named
differently from the stock one so a resolver can never silently substitute the
unpatched kernel for it.

Two more patches ride along. The **fourth** is diagnostic rather than
corrective: with the first three applied the capture PCM registered and opened,
but every `read()` still returned `EIO` while the kernel log — cleared
immediately beforehand — stayed completely empty, so that patch changes no
behaviour and only makes the conditions on that path printable. The **fifth** is
the fix it led to: the HDMI-RX audio domain is enabled only by a work item that
a capture open never triggered, so nothing ever clocked into the I2S receiver;
the patch starts that domain from the capture lifecycle instead.

`0005` compiles clean and is source-verified against the pinned tree. Tier 1:
it is board-confirmed on one Radxa ROCK 5B+ test on a hand-built kernel,
including end-to-end CeraUI audio-meter validation through the production
cerastream sidecar. Tier 2: the pipeline-built `--variant vendor-patched`
image has not itself been booted on hardware, and no Orange Pi 5+ evidence
exists — `0004` is retained precisely so that a future pipeline-built-image
confirmation can be read. Do not read this variant as "HDMI-RX audio works on
this pipeline's image" on the strength of the Tier 1 result alone. See
[`docs/kernel-build-from-source.md`](docs/kernel-build-from-source.md) §2d.

Every input is exact-pinned — the kernel commit, the patch-series commit (an
immutable SHA, never a branch), the kernel config's source revision, and the
builder container digest — and each pin is verified after checkout, so a moved
tag or a moved branch fails the build instead of silently building different
source. A source whose branch publishes no tags at all (the vendor BSP) is
fetched by exact commit rather than given a fabricated tag. The backend is plain
kernel `make bindeb-pkg`; the Armbian build framework is consulted for the
branch→version mapping and for the plain `.config` file it publishes, and is
never invoked as the build system.

Each of the three network fetches is retried up to three times under a
`timeout(1)`, and every attempt runs in a private directory destroyed *before*
it starts — a tree half-written by a killed clone would otherwise make each
retry fail deterministically, so one blip would present as a total outage. A
**pin mismatch is never retried**: it is checked after the retry loop and fails
on the spot, because a moved tag or a squash-merge-orphaned SHA is permanent and
re-fetching it three times only misreports it as a network fault. Nothing is
published at the path the build reads until it has verified.

`make -j` is derived as `min(nproc, MemAvailable / 2 GiB)` rather than plain
`nproc`, because a kernel compile job peaks around 1-2 GiB and a core-rich,
memory-thin builder gets OOM-killed deep inside `bindeb-pkg` after every pin has
already passed. `CERALIVE_KERNEL_BUILD_JOBS` overrides it unconditionally.

Selecting the variant suppresses the remote fetch of the kernel/DTB packages
(U-Boot and firmware stay prebuilt-fetched), replaces their names with the built
ones, and fails the build if any package name ends up with both a fetched and a
built candidate.

The two variants get their kernel config from structurally different places.
`edge` uses arm64 `defconfig` plus
[`manifests/kernel/rk3588-edge.fragment`](manifests/kernel/rk3588-edge.fragment).
`vendor-patched` instead fetches Armbian's **complete** published
`config/kernel/linux-rk35xx-vendor.config` at a pinned revision and uses it
verbatim — that is the exact config `linux-image-vendor-rk35xx` is built from, so
a bare `make defconfig` would build a materially different driver set and stop
being comparable to what the board runs.

Either way `lib/verify-kernel-config.sh` asserts inside the builder that every
symbol the declared config names survived `olddefconfig` — a leaf whose
`menuconfig` parent is off is otherwise dropped in complete silence. Four real
defects have been found that way, each disabling a whole capability on a booting,
validating image: no RTL8852BE WiFi (`CONFIG_RTW89`), no `/dev/dma_heap` for MPP
encode (`CONFIG_DMABUF_HEAPS`), a `=y` that had been resolving to `=m` for three
releases (`CONFIG_TYPEC_FUSB302`), and no nftables at all — which failed
`ceralive-ingest-firewall.service` every boot and left the WAN-side drop of the
unauthenticated RTMP/SRT ingest ports unapplied (`CONFIG_NF_TABLES`).

For `vendor-patched` a small, reviewed exception list
([`manifests/kernel/rk3588-vendor-patched.absent`](manifests/kernel/rk3588-vendor-patched.absent))
records the 24 symbols Armbian's published config names for **out-of-tree** WiFi
drivers its own build framework copies in at build time, which this pipeline
deliberately does not run. It is not an escape hatch: a listed symbol that *did*
survive fails the build as a stale exception, and neither shipped board's adapter
is on the list — both are in-tree and both pass the gate.

**With no variant selected the resolved production build is byte-identical to
before this existed**, pinned by committed golden fixtures. Nothing produced by
this stage has been compiled or booted yet, and it does not reopen the vendor-BSP
decision. Full detail:
[`docs/kernel-build-from-source.md`](docs/kernel-build-from-source.md);
gaps: [`docs/DEFERRED.md`](docs/DEFERRED.md) item 9.

## Kernel Tracks

Which patch repository feeds which opt-in variant, the pin chain from each
repo's `kernel-pin.env` through to `rk3588.yaml`, and where each track's
retire-on-merge status is tracked — a thin index, not a restatement — lives in
[`docs/kernel-tracks.md`](docs/kernel-tracks.md).

## Kernel Currency Watch

The image is locked to the **vendor 6.1 BSP + Rockchip MPP** for H.265 encoding.
This decision is recorded with a 7-way evidence summary and two precise revisit
triggers (a 6.12+ vendor BSP with MPP support, or mainline landing a frozen V4L2
stateless H.265 encode uAPI + VEPU580 driver) in
[`docs/kernel-currency-watch.md`](docs/kernel-currency-watch.md).

The MPP/GPU **userspace** that makes the vendor kernel's HW encoders reachable from
GStreamer (`gstreamer1.0-rockchip1` + `librockchip-mpp1` + `librga2`, plus the
Mali-G610 `libmali` blob) is not in the Armbian feed. It is baked from exact pinned
upstream release assets, verified by SHA-256, in
[`manifests/rk3588-userspace-deb-versions.txt`](manifests/rk3588-userspace-deb-versions.txt)
(fetched by `fetch_rk3588_userspace`) — no live third-party apt source is added.

## License

This project is dual-licensed under either:
- MIT (see LICENSE-MIT)
- Apache-2.0 (see LICENSE-APACHE)

You may choose either license.
