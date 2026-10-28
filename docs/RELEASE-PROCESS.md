# Release process

How a CeraLive device image actually goes from a merged commit to a bundle a
fielded device can install. The integration branch implements the signed image
channel publisher and pins stable CeraUI v2026.10.0's unified update orchestrator.
**Qualification [PARTIAL]:** two-board update drills and released arm64 package
installation are proven; full override-free candidate boot, multi-uplink failover
and amd64 hardware remain separate, unverified gates. Build-time APT credential
rotation and fleet OTA rollback runbooks remain below.

> **Honesty rule for this doc.** Every stage below is either (a) backed by a
> script or workflow that exists in this repo right now, with its path cited, or
> (b) explicitly marked **MANUAL (no automation yet)** with the exact operator
> steps to run by hand. Nothing here describes a CI job that isn't committed.

---

## Local kernel candidates [PARTIAL]

Kernel compilation runs on the owner's workstation, never a GitHub runner or
remote builder. The ordered owner steps, the bench binding and the device
outcome records live in [`kernel-release.md`](kernel-release.md). From a clean,
non-shallow checkout with complete kernel tags:

```bash
python3 ci/kernel-release.py rk3588 \
  --candidate-run-id 12345 --channel beta \
  --os-releases mkosi/cache/reviewed-os-kernel-sidecars
```

`--candidate-run-id` is an owner-selected positive decimal **local candidate ID**,
not a claim that an Actions run exists. `--os-releases` is required: provide a
complete, already authenticated snapshot of the published OS kernel sidecars
across boards/channels, as described under signed channel publishing below.
An empty directory asserts no OS kernel publication; it is not a substitute
for inventorying live releases. `CERALIVE_KERNEL_HISTORY_DIR` optionally supplies
the existing version gate's local kernel metadata history; otherwise that gate
reads kernel Release metadata through `gh`. No APT credentials are needed for
the local bundle store; the builder retains its normal authenticated dependencies.
This command does not refresh tags or authenticate the supplied OS snapshot.

The command refuses a dirty/shallow source, mismatched existing kernel tag,
DRY_RUN, an existing version bundle, or any failed gate. It checks the production
variant and runs `ci/check-kernel-version-monotonic.py --candidate`, `--published`
and `--floor --os-releases ...` before invoking exactly
`./build rk3588 --kernel-only`. That existing builder performs all-family
package/config/boot/DTB/firmware checks. The command then snapshots its five
outputs, reuses the strict metadata parser, verifies the archive's checksum and
all-family validation list, recomputes the existing family fingerprint, and
repeats candidate/publication/floor admission before sealing. A local producer
lock is not an APT publication lease or the image publisher's Actions lock.
Its persistent file is `mkosi/.kernel-release.lock`, outside candidate stores;
stores containing that lock are refused. Failed attempts remove only empty
store directories and parents that they created. Existing stores, completed
bundles and the shared lock are never removed by failure cleanup.

The default store is `mkosi/build/kernel-releases/<version>/`; `--output-dir`
can select another repo-local, ignored store. Linux `renameat2(RENAME_NOREPLACE)`
installs the complete bundle create-only, including against an empty-directory
collision. Files become read-only, as does the completed version directory.
The command never overwrites or reuses an existing version, even for identical
bytes. Manual filesystem writes by the owner are outside this command's
immutability guarantee. The original five builder files remain byte-identical:

- The production arm64 `.deb`, `kernel-artifact.json`, `resolved.config`,
  `built-modules.txt` and their original `SHA256SUMS`.
- `candidate.json`: local ID, source commit, family, observed floor and
  `publication: "blocked-pending-owner"`.
- `publish-authorization.inputs.json`: exactly apt-worker's eleven authorization
  field names. The artifact identity, candidate ID, tag, commit and channel are
  bound. `publish_run_id` and `run_attempt` are `null` because no approved Actions
  run exists; `bench_report_sha256` is `null` unless a report was supplied.
  This is an input record, **not** a valid or approved publish authorization.
- `BUNDLE.SHA256SUMS`: digests for every file above, including the original
  checksum list and the two local records.

Optionally supply `--bench-report FILE` during candidate creation. The command
uses `ci/validate-kernel-bench-report.py` and the byte-identical apt-worker schema,
requires exact candidate/tag/commit/archive identity and all six passing board
observations, then retains `bench-<version>.json` and binds its **raw-byte** hash.
Bootstrap reports use the same publisher schema and version/digest binding;
their eligibility still belongs exclusively to apt-worker's publication state.
A report cannot be attached later by rerunning this immutable local command.
No report is required to build a candidate; a report can separately be prepared
against that frozen candidate for a future owner-approved publication interface.

```bash
python3 ci/kernel-release.py --publish
```

This always exits nonzero with one error, before reading repository/history or
creating output: apt-worker requires a `kernel-release.yml` `workflow_dispatch`
run approved in the `kernel-release` environment. The owner must choose a
self-hosted `kernel-release.yml` on this PC or an apt-worker contract change.
Neither option is implemented or enabled here. There is no GitHub Release
creation/upload, APT dispatch/signing/publication, token, or environment in this
local lane. The production pin remains `7.2.0-ceralive1`; allocating the next
revision and any actual publication remain owner actions.

CI runs only the offline command/bench fixtures through `tests/registry.tsv`
and `./run-tests`; tests stub build/transport boundaries and make no network
requests. Fixture success is not a real kernel build, board drill or publication.

---

## 1. The path at a glance

```
push to release/** or vX.Y.Z tag
        │
        ▼
release.yml: admission + production build for rock-5b-plus and orange-pi-5-plus
        │
        ▼
./build <board>  →  orchestrate.sh  →  build-bundle.sh
        │                                       │
        │                                       ▼
        │                            signs the leaf-key .raucb,
        │                            verifies leaf→intermediate→root
        │
        ▼
verify each uncompressed raw, then seal + upload one immutable artifact per board
(.raw.xz + compressed and uncompressed SHA-256 records)
        │
        ▼  (MANUAL from here down — no automated hardware gate)
operator flashes the compressed candidate with verify-and-flash-candidate.sh and
hand-tests it on a REAL RK3588 (realhw-suite.sh: boot/service,
encode-path init, dev-loop sanity, RAUC A/B rollback)
        │
        ▼  (once the operator confirms the hand-test is green)
owner approves publish-release.yml for the hand-tested candidate run
        │
        ▼
publish-release.sh writes immutable releases/<board>/<OS CalVer>/ parts + index,
then channels/<channel>/<board>.json.sig and signed JSON pointer (JSON last)
        │
        ▼
device CeraUI verifies the images.ceralive.tv signed channel manifest,
stages via RAUC, activates only at clean idle shutdown/reboot
        │
        ▼
verification: preflash-verify.sh (pre-flash) + on-device
rauc status / ceralive-healthcheck (post-boot), then lagged other-slot mirror
```

The production job signs and seals the exact candidate first so the operator
hand-tests the bytes that could ship. A human may publish those bytes only after
hand-testing that exact candidate on real hardware — there is no automated CI job
that flashes or tests real hardware. Hardware acceptance and publication approval
remain human decisions; the committed channel-publishing workflow automates the
approved upload, promotion, refresh and retention operations (§5). The manual
bundle-pair/hawkBit procedures are legacy tooling, not the product's automatic
update path; `rauc-hawkbit-updater` is disabled and masked on the new image.

### OS release version rule

Use `YYYY.M.P`, where `YYYY.M` is the UTC month of the candidate build and `P`
is one above the highest patch ever used in that month on **any channel and
either board**, including private drill releases. If that month has no previous
release, start at `P = 0`. The October 2026 inventory gives `2026.10.99` as the
next version; a new month starts at patch zero. Inventory both
`releases/<board>/` prefixes with
`bash ci/publish-release.sh prune --board <board> --channel-family --dry-run`,
or review existing pointer and channel-marker versions. Never reuse a patch
because its release was pruned.

For a tag build, `vYYYY.M.P` supplies `CERALIVE_OS_RELEASE_VERSION` after removing
the leading `v`. For a `release/**` branch push, the repository Actions variable
`CERALIVE_OS_RELEASE_VERSION` is a required version input: set it to the reviewed
CalVer before pushing. The tag takes precedence over that variable. The workflow
rejects a missing or malformed version against `^[0-9]{4}\.[0-9]+\.[0-9]+$`
before building, then exports the validated value to both board jobs so each
rootfs carries `/etc/ceralive/os-release-version`. Patch allocation and the UTC
month are operator checks, not an automated live inventory or version bump.

---

## 2. Trigger

[`release.yml`](../.github/workflows/release.yml) fires on:

- a push to `release/**`
- a `v*` tag (e.g. `v2026.7.0`)

It builds and seals one production candidate per board in the
`[rock-5b-plus, orange-pi-5-plus]` matrix, as immutable artifacts named
`<board>-<commit sha>`, for an operator to download, flash, and hand-test on real hardware — there is no
automated hardware-flashing gate. `concurrency.cancel-in-progress: false` prevents
a newer release push from cancelling a build in progress.

There is no version-bump automation in this repo. Section 1 defines the OS CalVer
input and tag rule; the resulting rootfs stamp is distinct from the bundle's
`BUNDLE_VERSION` diagnostic (§4).

A workflow rerun for an existing tag always checks out that tag's original SHA.
If a release fix lands after the tag, rotate any affected secret first; rerunning
the old tag does not include the merged code. Merge the fix, push an untagged
`release/**` branch at that exact merge SHA, require the production candidate
build to pass, and hand-test the rebuilt candidate on real hardware. Verify the
successful run SHA equals the merge SHA, then create the next unused CalVer patch
tag at that same proven commit. A new tag must not be the first production
execution of a release-path repair, and an older tag is never moved or rerun to
pick up the fix.

For the resource failure after `v2026.7.2`, the only eligible next patch is
`v2026.7.3`; never rerun or move `v2026.7.0`, `v2026.7.1`, or `v2026.7.2`.

### CeraUI package release and image pins (separate release train)

The earlier 2026.9.5 update-system release was **stable**, not a beta package
release: CeraUI PR #379 merged to
`23ee67ae14d9b548475cc7cc670573943e597d91`, then its own `publish-release.yml`
was dispatched from `main` once with `release_type=stable` and
`force_version=2026.9.5` (run `39361690725`). Tag v2026.9.5 and both exact Debian
versions are published and served on stable. That image pin selected
`ceralive-device[arm64]=2026.9.5-20261020T030724.23ee67a` and
`ceralive-device[amd64]=2026.9.5-20261020T030729.23ee67a` in
`manifests/first-party-deb-versions.txt`, with `CeraUI.pin: v2026.9.5` in the
repo-local registry. Both release downloads matched their SHA-256 sidecars;
both bench boards installed the arm64 release through the product.

The current image pin selects the subsequent stable CeraUI **v2026.10.0** release
(tag commit `7c076c1`), published 2026-10-24T03:42:10Z. The exact Debian versions
are `2026.10.0-20261024T034043.7c076c1` (arm64) and
`2026.10.0-20261024T034041.7c076c1` (amd64), with repo-local provenance
`CeraUI.pin: v2026.10.0`. Both asset control fields and SHA-256 sidecars agree
with the authenticated publisher's served-release proof; both bench boards
installed the released arm64 package through the product. The mTLS-protected APT
index was not read directly during this pin update. See the
[pin receipt](first-party-pin-currency.md#ceraui-pin-receipt--2026-10-24) for the
authorized serving evidence. Pinning is not image qualification or OS stable/beta
authorization; OS 2026.10.97 remains private-drill only and channel pointers are
unchanged.

Keep `ceralive-apt-credentials=1.0.1` and registry tag
`apt-credentials-v1.0.1`: this release is served on stable and the boards use it
under enforced mTLS. After a package release, refresh the authenticated catalog
with `python3 ci/check-first-party-pins.py --refresh`, then run the ordinary
check; do not waive unrelated stale or unverifiable pins. A registry refresh
alone is not signed APT-index serving proof.

Package installation is not full-image qualification. Next build override-free
candidates from the committed image tree, verify no local-package overrides,
boot each exact candidate and restore the saved board state before image merge.
Do not infer that proof from the earlier package/script-deployment drills or
close physical bench-label verification (`DEFERRED.md` item 12) without evidence.
An OS-channel `promote` below is a different operation from the stable-only
CeraUI package release; executors publish OS drill candidates only, while the
owner controls OS stable/beta publication.

---

## 3. Manual hand-test on real hardware

`release.yml` builds and uploads one immutable production candidate per supported
board; there is no automated CI job that flashes or tests real hardware. An
operator downloads each candidate artifact and hand-tests it on its matching
Rock 5B+ or Orange Pi 5 Plus before a manual release, using
the bench flash-and-verify tool (`ci/verify-and-flash-candidate.sh`) plus the
acceptance suite (`tests/realhw-suite.sh`). The candidate artifact carries the
   xz-compressed raw image, SHA-256 records for both its compressed transport and
   decompressed bytes, the production bundle, keyring, the hash-pinned Maskrom
loader, and the candidate commit — everything the operator needs to flash and
validate the exact bytes that could ship.

Steps, in order:

1. **Candidate verification** — verify the compressed download SHA-256, decompress
   into a private sparse snapshot, verify the exact raw SHA-256, production bundle,
   embedded slot keyrings, boot artifacts, GPT geometry, loader SHA-256, and
   loader-mode eMMC capacity before any media write.
2. **Required flash and identity proof** — use that decompressed private snapshot
   for preflight and the RK3588
   Maskrom write. The board is expected to be in Maskrom when the tool starts;
   no pre-flash SSH session, password, or power helper is required. Before reset,
   read the exact candidate sector range into a
   private file, verify its size and SHA-256, and refuse to boot on any mismatch.
   The board must enumerate as the only RK3588 USB target and its canonical
   VID/PID/`LocationID` hash must match the approved Rock 5B+ fixture before
   loader transfer. The initial `rkdeveloptool db` is isolated under a pinned
   leader in an owned process group and limited by a monotonic 15-second budget.
   Timeout or interruption sends TERM to the group, waits one second, sends KILL
   to survivors, reaps the leader, and fails unless no group member or zombie
   remains. A clean command exit starts a
   distinct 10-second USB re-enumeration phase: only exactly one target with the
   same VID/PID/`LocationID` in `Loader` mode may advance to `rfi`. Zero targets
   or the same target still in Maskrom may be transient; malformed, multiple,
   changed, or unexpected-mode output fails immediately. There is no `db` retry,
   and no capacity query, identity read, write, readback, or reset follows either
   failure. Logs distinguish “rkdeveloptool db command timed out” from “loader
   re-enumeration timed out.”

   After the pinned loader is positively observed, a UART helper acquires the
   serial port before the write, then interrupts U-Boot and supplies a volatile,
   one-boot data-only UART bootstrap argument. A dedicated host-local Ed25519 key
   signs the request; the image contains only its public verification key. Before
   USB access, the verifier proves that the configured private key derives that
   exact public key. The bootstrap emits a fresh device nonce and verifies the
   signature, nonce, baked candidate commit, one-hour maximum expiry, and a
   persistent non-decreasing epoch floor before it installs a newly generated,
   restricted root public key with an absolute expiry into the empty `/data`
   authorized-key store; neither the key nor a password is embedded in the
   immutable image. The board must reconnect before the bounded retry budget
   expires with a root filesystem whose parent is the flashed eMMC and a fresh
   run-local SSH host-key record.
   The tool deliberately does not hash
   post-boot media because U-Boot state and the mounted rootfs are mutable. Its
   later `rkdeveloptool` children retain their cancellable/reaped behavior. The
   verifier resets inherited
   ignored INT/TERM dispositions before Bash starts its traps, covering
   asynchronous CI-shell launches where SIGINT would otherwise remain ignored.
   Artifact filenames in the identity record are restricted to a safe
   line-oriented character set.
3. **The acceptance suite** — [`tests/realhw-suite.sh`](../tests/realhw-suite.sh),
   which runs four sub-harnesses in sequence and aggregates one exit code:
   - **boot+service** (`tests/realhw-smoke.sh`) — boot, service, binary,
     quirk checks, and required live parity against the manifest. Missing or
     incomplete parity collection is a hard failure.
   - **encode-path init** — `cerastream --version` / `srtla_send --version`
     actually run on the board.
   - **dev-loop sanity** — `dev-push` completes in under 120s using the
     candidate-bound package in `DEV_DEB_DIR`; this lane is required.
   - **RAUC A/B rollback** ([`tests/rauc-rollback.sh`](../tests/rauc-rollback.sh))
     — the same rollback proof described in §8, run live against real
     silicon rather than the mock harness.
4. **Access cleanup and evidence upload** — an `always()` step removes the exact
   run-local authorized-key line and marker, proves both absent, deletes the
   private key, and records a cleanup receipt. If cleanup cannot run, the
   server-enforced key expiry bounds access, and any later boot without a one-use
   marker armed by the authenticated RAUC harness revokes the key before sshd.
   Evidence includes candidate identity,
   artifact digest, UART log, suite logs, and the receipt for 14 days.

A release only proceeds past this job if all four sub-harnesses pass on the
physical board. There is no bypass.

---

## 4. Build and sign

The release workflow performs the real production build before the hardware
gate on a dedicated `ceralive-image-builder` runner. PR CI remains DRY_RUN-only.
The release job fails closed unless production RAUC PKI, the pinned Armbian
archive keyring, and first-party apt GPG/mTLS credentials are supplied as secrets.

The real build is:

```bash
./build rock-5b-plus
# The other matrix job runs:
./build orange-pi-5-plus
```

which execs [`lib/orchestrate.sh`](../lib/orchestrate.sh) through its
staged pipeline (resolve manifest → fetch `.deb`s → validate → mkosi → assemble
disk → write the bootloader gap → emit the signed `.raucb`). See
[`docs/DEVICE-BRINGUP.md`](DEVICE-BRINGUP.md) §2 for the full stage list and
artifact layout.

### Production builder admission

The dedicated `ceralive-image-builder` runner must use the host's native Linux
Docker daemon. The candidate job sets `DOCKER_CONTEXT=default`, and
[`check-builder-resources.sh`](../ci/check-builder-resources.sh) runs before
BuildKit. It fails closed unless all of these are true:

- `default` resolves to `unix:///var/run/docker.sock` and the daemon is not
  Docker Desktop;
- Docker reports at least 16 GiB daemon-visible memory;
- the workflow-pinned `/proc/meminfo` reports at least 16 GiB combined
  `MemAvailable` + `SwapFree`;
- the checkout and Docker root each have at least 24 GiB free.

These are admission floors for the production path, not a substitute for the
full build or the operator's hand-test on real hardware. If admission fails, restore native-daemon access or
free the reported resource and start a new candidate from the fixed commit. Do
not increase a timeout, bypass the check, or rerun/move an existing immutable
tag.

The raw disk's large logical size is flash geometry, not transport size. The
assembler creates it sparse and every build-time parity check operates on those
uncompressed bytes. After the build-log census, `release.yml` runs
`preflash-verify.sh` against that uncompressed `.raw`; only then does candidate
sealing call `ci/seal-raw-candidate.sh`. The sealer uses `xz -T0 -6`: level 6 is
a deliberate middle ground between download size and the disproportionate CPU
cost of `-9`, while `-T0` uses the production runner's available cores. It emits
`<timestamp>.raw.xz`, `<timestamp>.raw.xz.sha256`, and `raw.sha256` (the digest of
the bytes obtained after decompression). It also streams the compressed output
back through `xz -dc` and checks that digest before sealing succeeds.
Candidate readers inspect the XZ index before extraction, reject a declared
decompressed size above 16 GiB, require enough temporary space, and apply a
1 GiB XZ decoder-memory ceiling. These bounds cover the frozen RK3588 disk
geometry without allowing an untrusted transport to grow without limit.

The uncompressed `.raw` remains in `images/<board>/` for build-local consumers;
it is not copied into `candidate/`. GitHub artifact upload therefore uses
compression level 0 rather than spending more CPU trying to recompress xz data.
The sealer prints raw/compressed byte counts and elapsed seconds in its own
workflow step. That timing is intentionally outside `candidate-build.log`, whose
frozen build-log census covers the nine image-construction stages rather than
release transport packaging.

### Production build caches

The candidate job persists only reusable build state; it never caches a
candidate image or a trust input. BuildKit loads the canonical
`ci/Dockerfile` builder image and exports its layers through the GitHub
Actions cache with a stable repository/OS/architecture/board/mkosi-tool scope.
The source hash is carried in the builder tag and label, while BuildKit's
content-addressed Dockerfile/context digests select the reusable layers. The
export uses `mode=min` so the cache contains only layers needed by the loaded
builder image.

The same job restores and saves only the board-specific mkosi package cache at
the manifest-resolved path from `ci/emit-canonical-paths.sh`:
`mkosi/cache/rock-5b-plus` or `mkosi/cache/orangepi5-plus`. The Orange manifest
stem is not its cache ID. Its exact key includes the repository, runner
OS/architecture, board, mkosi pin, and build-source hash; its fallback prefix
keeps those axes fixed. Before saving, the workflow enforces a 2 GiB ceiling,
measures/prunes the tree as root inside the builder container, and normalizes
ownership to the runner so mode-700 mkosi entries remain cacheable. That
normalization is a **cache-transport** step, not a build step: it exists so
`actions/cache/save` can read the tree, and it costs the next job a cold base
layer because mkosi 26 refuses a cache whose owner uid is not its own. Never
copy it into the local build path — `lib/stages/mkosi.sh` deliberately keeps the
cache inside one privilege domain instead (see
[`host-support.md`](host-support.md) "The mkosi cache lives in ONE privilege
domain"). Image outputs,
`.staging`, QEMU state, apt credentials, and release artifacts are not cache
inputs. These steps are guarded to release pushes/tags, and the trust-input
step remains after cache restore and builder preparation; the production build,
candidate contents, and required real-HW workflow call are unchanged. Candidate
sealing uses the post-verification xz step described above.

Fetching the five first-party `.deb`s (`libsrt1.5-ceralive`, `cerastream`,
`gstreamer1.0-libuvcsrc`, `ceralive-device`, `srtla`) from `apt.ceralive.tv` needs a GPG-verified,
mTLS-authenticated apt source — the exact credential contract is
`APT_GPG_PUBLIC_B64` / `APT_CLIENT_CRT_B64` / `APT_CLIENT_KEY_B64` in
[`lib/fetch-debs.sh`](../lib/fetch-debs.sh) `fetch_first_party()`
(lines ~518-637). **Section 7 below is the full rotation runbook for these
three values** — read it before running an authenticated release build.

### Armbian archive keyring rotation

`ARMBIAN_APT_KEYRING_B64` is a public-key trust input stored as a GitHub Actions
repository secret. During Armbian's current repository-key transition, the
canonical keyring is exactly these two primary keys, with no third primary key:

| Fingerprint | Identity |
|---|---|
| `DF00FAF1C577104B50BF1D0093D6889F9F0E78D5` | `Igor Pecovnik (Ljubljana, Slovenia) <igor.pecovnik@gmail.com>` |
| `8CFA83D13EB2181EEF5843E41EB30FAF236099FE` | `Armbian Repository Signing Key (Repository Key) <info@armbian.com>` |

The authority is Armbian-owned and immutable: current
[`armbian/build` signing code](https://github.com/armbian/build/blob/d14878c7e9f68106b2cde368f1cf576ab9f61e60/tools/repository/repo.sh)
signs with both fingerprints, while the
[`armbian/documentation` key instructions](https://github.com/armbian/documentation/blob/b683e8c2cc30a2a2a05b3b6b347e7437687fc614/docs/User-Guide_Getting-Started.md)
name both. Build the combined keyring only from the SHA-pinned official key files:

- historical key: [`armbian/build@fa9302f…/config/armbian.key`](https://github.com/armbian/build/blob/fa9302f1629409d035d55ff5b41543cf94aa6cf2/config/armbian.key), SHA-256 `45eea660732932370088652b214b85acb426c022529284211d76c12dcb5c9ec3`;
- repository key: [`armbian/build@d14878c…/config/armbian.key`](https://github.com/armbian/build/blob/d14878c7e9f68106b2cde368f1cf576ab9f61e60/config/armbian.key), SHA-256 `c86db754ae38d13aa254e59672d8bb6c0ed9a0eeee9b5440cde69afef995da7a`.

Provision it from a clean checkout with `curl`, `gpg`, `gpgv`, and authenticated
`gh`. The commands compare source bytes, full primary fingerprints, and exact UIDs;
the secret value never appears in argv or terminal output. Run the block as one
compound command: its strict subshell stops before the secret update if any source,
identity, keyring-policy, or live-signature check fails.

```bash
(
set -euo pipefail
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
install -d -m 0700 "${tmp}/gnupg"
export GNUPGHOME="${tmp}/gnupg"

old_fpr=DF00FAF1C577104B50BF1D0093D6889F9F0E78D5
new_fpr=8CFA83D13EB2181EEF5843E41EB30FAF236099FE
curl --proto '=https' --tlsv1.2 -fsSL \
  -o "${tmp}/old.asc" \
  https://raw.githubusercontent.com/armbian/build/fa9302f1629409d035d55ff5b41543cf94aa6cf2/config/armbian.key
curl --proto '=https' --tlsv1.2 -fsSL \
  -o "${tmp}/new.asc" \
  https://raw.githubusercontent.com/armbian/build/d14878c7e9f68106b2cde368f1cf576ab9f61e60/config/armbian.key

test "$(sha256sum "${tmp}/old.asc" | cut -d' ' -f1)" = \
  45eea660732932370088652b214b85acb426c022529284211d76c12dcb5c9ec3
test "$(sha256sum "${tmp}/new.asc" | cut -d' ' -f1)" = \
  c86db754ae38d13aa254e59672d8bb6c0ed9a0eeee9b5440cde69afef995da7a

old_meta="$(gpg --batch --with-colons --show-keys --fingerprint "${tmp}/old.asc")"
new_meta="$(gpg --batch --with-colons --show-keys --fingerprint "${tmp}/new.asc")"
test "$(awk -F: '$1=="fpr"{print $10; exit}' <<<"${old_meta}")" = "${old_fpr}"
test "$(awk -F: '$1=="uid"{print $10; exit}' <<<"${old_meta}")" = \
  'Igor Pecovnik (Ljubljana, Slovenia) <igor.pecovnik@gmail.com>'
test "$(awk -F: '$1=="fpr"{print $10; exit}' <<<"${new_meta}")" = "${new_fpr}"
test "$(awk -F: '$1=="uid"{print $10; exit}' <<<"${new_meta}")" = \
  'Armbian Repository Signing Key (Repository Key) <info@armbian.com>'

gpg --batch --quiet --import "${tmp}/old.asc" "${tmp}/new.asc"
gpg --batch --yes --output "${tmp}/armbian-combined.gpg" \
  --export "${old_fpr}" "${new_fpr}"
bash -c 'source lib/fetch-debs-auth.sh; \
  auth_keyring_has_exact_fingerprints "$1" "$2" "$3"' \
  bash "${tmp}/armbian-combined.gpg" "${old_fpr}" "${new_fpr}"

curl --proto '=https' --tlsv1.2 -fsSL \
  -o "${tmp}/InRelease" https://apt.armbian.com/dists/bookworm/InRelease
gpgv --keyring "${tmp}/armbian-combined.gpg" "${tmp}/InRelease"
base64 -w0 <"${tmp}/armbian-combined.gpg" \
  | gh secret set ARMBIAN_APT_KEYRING_B64 \
      --repo CERALIVE/image-building-pipeline
)
```

`lib/fetch-debs.sh` independently enforces exact primary-fingerprint set
equality before either apt or the curl fallback runs. That check deliberately
rejects old-only, new-only, malformed, revoked, expired, invalid, disabled,
normalization-failed, and expected-plus-unrelated keyrings. Both native apt and
curl paths re-verify the downloaded `InRelease` with `gpgv`; both signatures must
be valid before package download begins.

### Armbian BSP package pin promotion

Family manifests choose the required BSP package names. Production resolves those
names only through the exact Debian versions in
`manifests/armbian-bsp-deb-versions.txt`; it never asks apt for an unqualified
latest package. Both fetch paths verify the dual-signed `InRelease` and require
the configured suite, `main` component, and architecture. The curl path also
verifies the signed `Packages.gz` digest and preflights the complete exact set
before downloading. Each downloaded package is then checked against its
signed-index SHA-256 and its Debian control package/version/architecture.

To promote a BSP version:

1. Fetch the live official `InRelease` and `Packages.gz` from
   `https://apt.armbian.com` using the exact two-key procedure above.
2. Verify suite/component/architecture identity and confirm one compatible
   (`arm64` or `all`) record, including SHA-256, for every required exact package.
   Do not promote a partial set or use an unsigned mirror or HTTP status alone.
3. Review the package contents and hardware implications. Update
   `armbian-bsp-deb-versions.txt`; when the kernel changes, update
   `manifests/bsp-baseline.json` to the reviewed version and content hash in the
   same change.
4. Run `tests/bsp-package-resolution.test.sh`, `run-tests`, an authenticated
   live BSP fetch, and a hand-test of the candidate on real hardware before shipping
   a new immutable tag.

If a tagged candidate fails, merge the fix and follow the §2 repair procedure:
prove the exact merge SHA with an untagged `release/**` production candidate and
physical real-HW pass, then create the next unused CalVer patch tag at that same
commit. Never move or rerun an older tag expecting it to pick up new code.

### Signing (`build-bundle.sh`)

The orchestrator's stage 8 calls [`lib/build-bundle.sh`](../lib/build-bundle.sh)
to produce `images/<board>/<ts>.raucb` (+ `.sha256`), stamped with the
board-specific `COMPATIBLE_STRING` (`ceralive-<board-id>`) and a
`BUNDLE_VERSION` (git short SHA by default). The signing contract:

- **Leaf key only, never root.** The bundle is signed with the injected release
  `leaf-signing.key` + `chain.pem` (the intermediate chain; the leaf certificate is
  passed separately as the signer).
  The root CA key (`root-ca.key`) never touches the signing invocation — it
  stays offline, by design.
- **`assert_no_root_signing()`** is the enforced guard: it greps the *rendered*
  signing command for `root-ca.key` and dies if it's present, then positively
  asserts `leaf-signing.key` IS the signer. This runs on every bundle build,
   native RAUC bundle path; the old OpenSSL plain-format signer is retired.
- **Verification is part of the same step.** After signing, `build-bundle.sh`
  immediately verifies the bundle against the injected `root-ca.pem` (the
   same keyring baked into the device) with `rauc info --keyring`. A bundle
   that fails to verify never leaves the build host.
- **Verity, not bit-identical signed containers.** OS and certificate-rotation
  bundles use `format=verity`; OS bundles also set `adaptive=block-hash-index` on
  the rootfs image (`lib/build-bundle.sh`), while the certificate-rotation bundle
  carries a hook-installed `certs.tar` with no `adaptive=` setting. Native RAUC's
  CMS/verity metadata varies between signings: the signed `.raucb` is **not
  bit-reproducible**. Rootfs reproducibility and its image-version timestamp
  exception are documented in [the README](../README.md#reproducible-builds).
  Never substitute a plain-format OpenSSL bundle to claim determinism.

The RAUC signing PKI itself (root/intermediate/leaf tiers, validity, and how a
leaf or intermediate rotates through the channel without a reflash) is a
**separate** rotation procedure from the apt credentials in §7 — see
[`docs/cert-rotation-policy.md`](../docs/cert-rotation-policy.md) for the
full contract; it isn't duplicated here.

### CI determinism coverage — cross-runner build-plan gate (C6b)

CI cannot run the privileged mkosi build (no network / privileged container /
board under `DRY_RUN`), so it does **not** produce — let alone dual-host-compare —
a real signed `.raucb`. What it CAN prove is that the **build plan / input closure** resolves
host-independently.

- The [`v2-ci.yml`](../.github/workflows/v2-ci.yml) `build-plan-xrunner` +
  `build-plan-xrunner-gate` jobs resolve the `DRY_RUN=1` mkosi plan on **two
  independent GitHub-hosted runners** (`ubuntu-24.04` + `ubuntu-22.04`), hash the
  **normalized** per-board plan ([`ci/emit-build-plan-sha.sh`](../ci/emit-build-plan-sha.sh)
  — the same task-15 normalization: strip the abs repo path → `<REPO>`, sha256 the
  single line), and fail if the two runners disagree on any board's plan sha256
  ([`ci/assert-xrunner-parity.sh`](../ci/assert-xrunner-parity.sh)). It
  extends the `build-matrix` job's **same-host** rebuild-parity into a **cross-host**
  check — catching host-dependence (hostname / arch / toolchain / an un-normalized
  path) a single host can never surface.
- **Runner diversity:** two independent GH runners of different OS images were
  chosen (not cross-OS/arch or two containers) because the DRY_RUN resolution needs
  a Linux container runtime + GNU coreutils — macOS/Windows runners can't run it —
  while `ubuntu-24.04`/`ubuntu-22.04` are guaranteed-available, fast, and ship
  different toolchains (glibc/coreutils/python/docker). It starts **advisory**
  (`continue-on-error` gated on the repo variable `XRUNNER_PARITY_BLOCKING`);
  promote it to a required check after one green in-budget run.
- **SCOPE LIMIT:** this compares the deterministic PLAN / input closure ONLY, **not
  a full `.raucb` image build**. Signed verity containers are not bit-reproducible;
  plan equality does not prove rootfs equality, artifact identity or board
  qualification. Verify the exact candidate bytes and their signatures instead.

---

## 5. R2 upload — legacy bundle pair and signed image channels

The legacy bundle-pair path below remains manual for old consumers. The new
`images.ceralive.tv` OS channel publisher is a separate, environment-gated
workflow described after it. Compare the artifact families:

| Artifact | R2 path | Publisher |
|----------|---------|-----------|
| Feature-sysext add-ons | `addons/{os_version}/{board}/{feature}.raw` | [`lib/upload-addons.sh`](../lib/upload-addons.sh) — **exists, automatable, CI-proven under `DRY_RUN`** (`v2-ci.yml` `addon-publish` job) |
| CeraUI federation UI bundles | `ui-bundle/{ceraui-version}/*.js` | CeraUI's own `publish-release.yml` → `publish-federation` job — **exists in the CeraUI repo** |
| **OS `.raucb` OTA bundles** | `bundles/{channel}/{board}/*.raucb` | manual candidate proof, then [`publish-immutable-r2-pair.sh`](../ci/publish-immutable-r2-pair.sh); **no publishing workflow** |
| **Signed OS image channels** | `releases/{board}/{version}/` plus `channels/{channel}/{board}.json[.sig]` | [`publish-release.sh`](../ci/publish-release.sh) via approved [`publish-release.yml`](../.github/workflows/publish-release.yml) |

`apt-worker/AGENTS.md` and `apt-worker/README.md` both describe the `bundles/`
path as a pure read side (the worker range-serves whatever is already in R2)
and explicitly credit the add-on and federation paths to their respective
publisher scripts. The helper here is operator-invoked and is not a release
workflow or candidate-selection authority.

### Operator steps (today, until this is automated)

For an explicitly authorized legacy consumer, publish a bundle pair manually
from the exact candidate artifact that passed physical hardware. New capable
devices use the signed image-channel publisher below instead.
Do not select a local build by timestamp or "newest" ordering. The candidate
contains the production bundle's original release filename and checksum; the
GitHub artifact API binds that candidate to the successful run and merge SHA.
After installing `gh`, `jq`, `unzip`, `rauc`, and the AWS CLI:

```bash
set -euo pipefail
repo=CERALIVE/image-building-pipeline
run_id=<successful-untagged-release-run-id>
merge_sha=<full-merge-sha>
board=rock-5b-plus
channel=stable
approved_root=<path-to-operator-approved-production-root-ca.pem>
# The raw-image SHA-256 you recorded while hand-testing these exact bytes on a
# real RK3588 (it must equal the candidate's own raw.sha256). Publishing is gated on it.
hand_tested_raw_sha256=<64-lowercase-hex-you-flashed-and-tested>
artifact_name="rock-5b-plus-${merge_sha}"

# Bind publication to the successful candidate-build workflow at the exact proven merge SHA.
test "$(gh run view "${run_id}" --repo "${repo}" --json headSha --jq .headSha)" = "${merge_sha}"
test "$(gh run view "${run_id}" --repo "${repo}" --json conclusion --jq .conclusion)" = success
run_event="$(gh run view "${run_id}" --repo "${repo}" --json event --jq .event)"
run_branch="$(gh run view "${run_id}" --repo "${repo}" --json headBranch --jq .headBranch)"
run_workflow="$(gh run view "${run_id}" --repo "${repo}" --json workflowName --jq .workflowName)"
workflow_id="$(
  gh run view "${run_id}" --repo "${repo}" --json workflowDatabaseId --jq .workflowDatabaseId
)"
workflow_path="$(gh api "repos/${repo}/actions/workflows/${workflow_id}" --jq .path)"
test "${run_event}" = push
[[ "${run_branch}" == release/* ]]
test "${run_workflow}" = 'Release candidate build'
test "${workflow_path}" = '.github/workflows/release.yml'
master_status="$(gh api "repos/${repo}/compare/${merge_sha}...master" --jq .status)"
[[ "${master_status}" == identical || "${master_status}" == ahead ]]

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
publisher="${tmp}/publish-immutable-r2-pair.sh"
GIT_NO_REPLACE_OBJECTS=1 git show "${merge_sha}:ci/publish-immutable-r2-pair.sh" > "${publisher}"
chmod 0700 "${publisher}"
gh api "repos/${repo}/actions/runs/${run_id}/artifacts" > "${tmp}/artifacts.json"
artifact_id="$(jq -er --arg name "${artifact_name}" '
  [.artifacts[] | select(.name == $name and (.expired | not))]
  | if length == 1 then .[0].id else error("expected exactly one live candidate artifact") end
' "${tmp}/artifacts.json")"
artifact_digest="$(gh api "repos/${repo}/actions/artifacts/${artifact_id}" --jq .digest)"
artifact_sha="$(gh api "repos/${repo}/actions/artifacts/${artifact_id}" --jq .workflow_run.head_sha)"
[[ "${artifact_digest}" =~ ^sha256:[0-9a-f]{64}$ ]]
test "${artifact_sha}" = "${merge_sha}"

# Verify the exact GitHub candidate archive before inspecting the tested bytes.
gh api -H 'Accept: application/vnd.github+json' \
  "repos/${repo}/actions/artifacts/${artifact_id}/zip" > "${tmp}/candidate.zip"
printf '%s  %s\n' "${artifact_digest#sha256:}" "${tmp}/candidate.zip" | sha256sum -c -
mkdir "${tmp}/candidate"
unzip -q "${tmp}/candidate.zip" -d "${tmp}/candidate"

candidate="${tmp}/candidate"
raw_transport="$(find "${candidate}" -maxdepth 1 -type f -name '*.raw.xz' -print -quit)"
test -n "${raw_transport}"
( cd "${candidate}" && sha256sum -c "$(basename "${raw_transport}").sha256" )
expected_raw_sha="$(awk 'NR == 1 { print $1 }' "${candidate}/raw.sha256")"
[[ "${expected_raw_sha}" =~ ^[0-9a-f]{64}$ ]]
[[ "${hand_tested_raw_sha256}" =~ ^[0-9a-f]{64}$ ]]
# Publish ONLY the exact raw image you hand-tested on real hardware: the SHA-256
# you recorded while flashing/validating must equal the candidate's own raw.sha256.
test "${hand_tested_raw_sha256}" = "${expected_raw_sha}"

release_name="$(<"${candidate}/release-bundle-name.txt")"
[[ "${release_name}" =~ ^[0-9]{8}T[0-9]{6}Z\.raucb$ ]]
approved_bundle_sha="$(awk 'NR == 1 { print $1 }' "${candidate}/good.raucb.sha256")"
[[ "${approved_bundle_sha}" =~ ^[0-9a-f]{64}$ ]]
( cd "${candidate}" && sha256sum -c good.raucb.sha256 )
test -f "${approved_root}"
test "$(openssl x509 -in "${approved_root}" -outform DER | sha256sum | cut -d' ' -f1)" = \
  "$(openssl x509 -in "${candidate}/root-ca.pem" -outform DER | sha256sum | cut -d' ' -f1)"
rauc info --keyring "${approved_root}" "${candidate}/good.raucb" >/dev/null

bundle="${candidate}/good.raucb"
sha="${tmp}/${release_name}.sha256"
printf '%s  %s\n' "${approved_bundle_sha}" "${release_name}" > "${sha}"
"${publisher}" \
  --bundle "${bundle}" --sidecar "${sha}" --expected-sha256 "${approved_bundle_sha}" \
  --bucket "${R2_BUCKET}" --endpoint "${R2_ENDPOINT}" \
  --bundle-key "bundles/${channel}/${board}/${release_name}"
```

`R2_BUCKET` / `R2_ENDPOINT` use the same S3-compatible R2 endpoint shape as
`upload-addons.sh`. Do not use a long-lived or prefix-scoped publication token.
Immediately before invoking the helper, a trusted issuer must locally sign an
R2 temporary credential with `actions: ["GetObject", "PutObject"]`, the shortest
practical TTL, and `paths.objectPaths` containing exactly these two keys:
`bundles/${channel}/${board}/${release_name}` and
`bundles/${channel}/${board}/${release_name}.sha256`. Export its access key,
secret, and session token through the standard AWS environment variables. It
must have no `DeleteObject`, list, bucket-administration, or unrelated-key
access and must expire after this one publication attempt; the helper's
conditional PUT enforces create-only writes while that authority exists.
The helper requires an AWS CLI version whose `s3api put-object` supports
`--if-none-match`. It snapshots both inputs privately and requires the snapshot
to match the already-approved candidate SHA-256 before using sidecar-first
create-only writes and exact-byte, idempotent collision recovery. An interrupted
accepted write is resumed only when the existing bytes exactly match. It never
deletes a release key. Any
mismatched collision or unverifiable read aborts before hawkBit registration;
never replace an existing release key.

### Signed channel publishing (CeraUI OS agent)

The manual `Publish signed image release` workflow asks for mode (`publish`,
`promote`, `refresh`, `prune`), comma-separated boards, channel and (for publish
or promote) OS CalVer. Publish additionally requires the **successful** release
candidate run ID. The `release` GitHub environment requires owner approval;
every invocation's publish job joins the non-cancelling shared
`ceralive-kernel-floor` group. This replaces the workflow-level
`image-release-publisher` group while retaining serialization of publish,
promote, refresh and prune. Integration of the owner's separate local
kernel-release command uses this floor contract. Kernel/image builds remain local; this does
not add a kernel tag-triggered build or dispatch workflow. A
workflow `refresh` accepts exactly one board and requires the operator's observed
`expect_serial` and **quoted** JSON `expect_etag`. It fetches that board's JSON
and ETag again in the approved job, refuses stale/missing inputs, and forwards
both as `--expect-serial` / `--expect-etag` to the publisher. Read the current
signed pointer and its R2 ETag using the procedure below before dispatch; do
not enter an unquoted digest or use a serial from another board.

The issue-only upstream watcher opens an advisory within 30 days of a stable or
beta manifest's expiry. Its copyable refresh command includes `expect_serial`
and shell-quoted `expect_etag` from the **same HTTP response**, retaining the
literal double quotes in the ETag value. The public manifest endpoint preserves
the R2 JSON ETag (checked read-only against `head-object` on 2026-10-20).
A missing, weak or malformed ETag stops the watch rather than producing an
unusable command. The advisory is an observation, not approval: review the
signed pointer before dispatch, and re-observe if the workflow refuses drift.

A release-candidate archive must include `good.raucb`, both transport checksums,
`raw.sha256`, `packages.lock.json` and `kernel-artifact.json`. Current `.raw.zst` candidates are decoded
and recompressed to actual xz; earlier `.raw.xz` candidates are copied. In both
cases the bytes after decompression must match the
original raw SHA. The publisher independently rechecks both file hashes and
pins `min_ceraui_version` from the repo-local CeraUI version registry. If the
candidate lacks a package lock (older releases), it is **not** publishable.
Before approving, the owner must match the candidate run SHA/artifact and the
real board hand-test; the workflow verifies the successful run and its downloaded
archive, but does not perform a physical board test.

For RK3588, the publisher derives the installed kernel's exact package/version/
digest from the **candidate's** package lock, requires authenticated
`ceralive-kernel` origin, checks it against that version's released artifact,
and cross-checks the candidate artifact identity when present. A newer kernel
manifest in the publishing checkout cannot change this identity. It writes
immutable `releases/<board>/<CalVer>/kernel.json` and `kernel.json.sig`, signed
with the same dedicated channel key. The sidecar has schema 1, board, os_version
and kernel `{package,version,deb_sha256}`. Deterministic, attribute-free CMS
allows exact-byte retries. No field is added to the strict channel manifest.

Both publish and promote inventory **all boards'** published channel membership
markers, authenticate their kernel sidecars with the channel trust root, and
compare against the maximum OS/kernel release floor. A lower candidate fails
`os_kernel_below_floor` before publishing any marker/channel pointer. Missing,
malformed or unsigned historical sidecars stop the gate; they are not treated
as version zero. Historical releases must therefore have reviewed signed
sidecars before a new managed-kernel publication. x86-minipc has no managed
CeraLive source kernel and is outside this RK3588 version floor.
`--floor --os-releases DIR` can inspect an already verified local snapshot;
`CERALIVE_KERNEL_HISTORY_DIR` supplies local immutable kernel metadata, otherwise
the gate reads release metadata through `gh`. Neither path supplies kernel
`.deb` bytes: production image candidates take those only from authenticated
CeraLive APT.

The release is stored under `releases/<board>/<CalVer>/`: 268435456-byte
create-only parts for both `bundle.raucb` and `flash.raw.xz`; one schema-1
`index.json` with both files' complete digests, sizes and ordered parts;
`packages.lock.json`; `SHA256SUMS`; the signed `kernel.json`/`kernel.json.sig`
pair; and create-only
`channels/<channel>` membership marker. All immutable writes use the same
conditional/exact-byte-recovery primitive as the legacy publisher. Only after
they succeed does the publisher sign the strict schema-1 channel manifest with
the dedicated `CeraLive OTA Manifest Signer` (codeSigning only, **not** the
dual-EKU bundle signer), upload the detached DER CMS `.sig`, and put `.json`
**last**, conditional on the previous channel ETag. Its serial increases once
per publish/promotion/refresh on that channel, and the 90-day validity window
starts at that operation. `refresh` retains version and artifact bytes and
uploads **no parts**; it is required before a rarely-released channel expires.
`promote` requires a beta manifest naming the exact version and matching the
immutable index; it uploads no parts. A failed conditional manifest write is a
serial replay refusal, not licence to overwrite a release object.

After chain verification against the root, both the publisher's signing check
and every existing-pointer read pin the CMS leaf's RFC2253 issuer DN exactly to
`CN=CeraLive RAUC Intermediate CA,O=CeraLive` (production) or
`CN=CeraLive RAUC Bench Intermediate CA,O=CeraLive` (non-production bench).
The supplied `intermediate-ca.pem` is an untrusted chain candidate, not a
requirement that OpenSSL use it: a root-direct leaf could otherwise pass the
chain, dedicated CN and EKU checks. A different or near-miss issuer fails even
when its signature chains to the same root. The downloader applies the same
issuer rule with `--keyring`.

**Signed board identity is not the filename stem.** `board` and the release
URL use the product manifest stem (`orange-pi-5-plus`); `compatible` is derived
through the validated board resolver's `BOARD_ID` (`orangepi5-plus`) and equals
the signed RAUC bundle/system.conf value `ceralive-orangepi5-plus`. Rock's
stem and `BOARD_ID` both happen to be `rock-5b-plus`. The publisher reads the
immutable index and every part back from R2, validates part and whole-file
lengths/digests, then runs `rauc info -C keyring:check-purpose=codesign`
against the reconstructed bundle and an explicit `RAUC_BUNDLE_KEYRING`. Missing
root, missing part, invalid signature, wrong compatible, or wrong signed pointer
URL/digest aborts before any channel signature or JSON write. `publish` also
preflights its candidate signature before any immutable write.
`tools/flash-download.sh --board <board> --keyring <reviewed-manifest-root.pem>`
uses the same resolved `BOARD_ID` for compatible, and requires the CMS signer
CN `CeraLive OTA Manifest Signer`, Code Signing EKU, no E-mail Protection, and
one of the two exact intermediate issuer DNs above.
Without `--keyring` the downloader is intentionally **unauthenticated**: SHA-256
checks detect transfer corruption, not a malicious replacement; its output
must not be treated as a trusted release. An invalid pre-existing `flash.raw`
is removed before extraction, so a failed decode cannot leave unverified bytes
under the final raw pathname.

`promote` and `refresh` verify the prior channel CMS under the dedicated manifest signer
root; only refresh accepts the old, demonstrably wrong product-stem compatible
as a source and replaces it with the verified value. It never treats that
legacy claim as install authority. Refresh requires `--expect-serial` and the
quoted, observed `--expect-etag` of the current JSON, checked again before
signature-first/JSON-last ETag CAS. If JSON CAS fails while the old JSON ETag
is still current, a conditional write restores the old signature; a concurrent
change is not overwritten. No immutable release is re-signed or rewritten.

The two channel objects are **not atomic**. Before changing `.json.sig`, the
publisher creates an immutable recovery intent under
`channels/<channel>/<board>.json.recovery/`, keyed by the prior JSON ETag,
operation and version. It contains byte-for-byte copies of the previously
CMS-signed pair (if present) and the new pair; it is not trusted merely because
it exists. On retry after a process dies between the signature and JSON PUT,
the publisher checks the prior JSON against its observed ETag and saved bytes,
verifies **both** CMS signatures and signer identities, checks the new serial,
board/channel/version and indexed artifact identities against the reverified
RAUC bundle, and requires the currently exposed signature to match the saved
new signature exactly. Only then may it commit the saved new JSON with
`If-Match` against the prior ETag and verify the resulting pair by readback.
For an interrupted first publication (no prior JSON), the next identical
`publish` reuses the authenticated intent and commits with `If-None-Match`.
Foreign signatures, changed JSON/ETag, drifted parts/index, absent trust roots
and stale refresh preconditions fail closed: **never re-sign the old JSON** or
delete/rewrite immutable release bytes to bypass the refusal. The intent is
retained as an audit/retry record; ordinary successful operations also create
one. During the interval between the two PUTs readers may still see an
unverifiable pair and must fail closed; this is recoverability, **not** atomic
availability or a guarantee of uninterrupted service. Retry the same reviewed
operation with the same preconditions; if the pair is foreign/drifted, stop and
adjudicate rather than forcing a write.

**Recovery integrity [EXISTS]:** release-index schema/chunk checks, reconstructed
whole-file size/SHA-256 checks and the verified RAUC bundle's exact compatible
are mandatory even when recovery is reached through a conditional channel read.
Each failed check explicitly aborts; Bash `set -e` alone is not a guard inside
functions invoked by `if`, `!`, `&&` or `||`. Both real and dry-run recovery
refuse before the channel JSON PUT or `PLAN recover` on any such failure.
Every authenticated existing pointer must also name the requested schema,
board and channel and carry a valid serial/version identity. A validly signed
beta manifest on the stable key is refused, not re-signed as stable, by publish,
promote, refresh and prune. Publishing may already have attempted create-only
release objects before it reads that existing pointer; the refusal prevents
channel mutation, not those immutable attempts.

**Publisher dry-run [EXISTS]:** `--dry-run` never creates, replaces or deletes
remote objects, in any mode. It still performs the required reads and trust
checks. If publish, promote or refresh finds an authenticated interrupted
signature-first write, it prints `PLAN recover <channel JSON key> by JSON ETag
CAS; stop after recovery plan` and exits successfully without committing the
recovery or continuing the original operation. The pair remains mismatched;
this plan is not evidence of a repaired channel. Retry without `--dry-run` only
under the normal release authorization and preconditions. Invalid or foreign
pairs still fail closed, and prune never attempts recovery. A dry-run selftest
only prints its synthetic round-trip plan; it uploads nothing and installs no
remote-cleanup trap. The recording-stub regression is
`bash tests/publisher-dry-run.test.sh`; the real-mode publication, CMS and RAUC
contracts remain in `bash tests/publish-release.test.sh`.
The recording suite also rejects cross-channel replay in dry-run and real modes,
invalid recovery release metadata, foreign-root next signatures and a mismatched
pair with no recovery intent. Its remote-call allow-list records all AWS calls,
including unsupported non-`s3api` invocations, before deciding whether they are
read-only.

The workflow materializes the RAUC root separately from the CMS manifest
signer: stable/beta (and promotion to stable) use `RAUC_RELEASE_PKI_TAR_B64`'s
production `root-ca.pem`; drill requires the separately provisioned
`RAUC_BENCH_ROOT_CA_B64` (base64 of the bench root certificate). A missing
secret fails closed. For a reviewed **pointer-only Orange drill repair** after
both the publisher and device consumer fixes pass their own reviews, use this
procedure; it is **not authorization to run it during a blocked drill**:

```bash
# Export R2_IMAGES_ENDPOINT, R2_IMAGES_ACCESS_KEY_ID and
# R2_IMAGES_SECRET_ACCESS_KEY through the private credential source first.
export RAUC_BUNDLE_KEYRING=<reviewed-bench-root-ca.pem>
export OTA_MANIFEST_SIGNER_DIR=<reviewed-manifest-signer-directory>
bucket=ceralive-images
endpoint="$R2_IMAGES_ENDPOINT"
key=channels/drill/orange-pi-5-plus.json
work="$(mktemp -d)"    # remove this private directory after verification
aws s3api get-object --bucket "$bucket" --endpoint-url "$endpoint" --key "$key" "$work/old.json"
aws s3api get-object --bucket "$bucket" --endpoint-url "$endpoint" --key "$key.sig" "$work/old.sig"
etag="$(aws s3api head-object --bucket "$bucket" --endpoint-url "$endpoint" --key "$key" --query ETag --output text)"
test "$etag" = "\"$(openssl dgst -md5 "$work/old.json" | cut -d' ' -f2)\""
openssl cms -verify -binary -inform DER -in "$work/old.sig" -content "$work/old.json" \
  -CAfile "$OTA_MANIFEST_SIGNER_DIR/root-ca.pem" -purpose any -signer "$work/old-signer.pem" -out /dev/null
test "$(grep -c '^-----BEGIN CERTIFICATE-----$' "$work/old-signer.pem")" = 1
subject="$(openssl x509 -in "$work/old-signer.pem" -noout -subject -nameopt RFC2253)"
cn_pattern='(^subject=|,)CN=CeraLive OTA Manifest Signer(,|$)'
[[ "$subject" =~ $cn_pattern ]]
eku="$(openssl x509 -in "$work/old-signer.pem" -noout -ext extendedKeyUsage)"
[[ "$eku" == *'Code Signing'* && "$eku" != *'E-mail Protection'* ]]
issuer="$(openssl x509 -in "$work/old-signer.pem" -noout -issuer -nameopt RFC2253)"
case "$issuer" in
  'issuer=CN=CeraLive RAUC Intermediate CA,O=CeraLive'|\
  'issuer=CN=CeraLive RAUC Bench Intermediate CA,O=CeraLive') ;;
  *) printf 'refused manifest signer issuer: %s\n' "$issuer" >&2; exit 1 ;;
esac
python3 - "$work/old.json" <<'PY'
import json,sys
m=json.load(open(sys.argv[1]))
assert (m['schema'],m['board'],m['channel'],m['version'],m['serial'],m['compatible']) == \
       (1,'orange-pi-5-plus','drill','2026.10.6',4,'ceralive-orange-pi-5-plus')
assert m['bundle']['sha256']=='1820b2b0035b1c3cfa9ff04fcce97a38535c21b793db0e49204b74455dc7f46e'
PY
# Re-run only after both repo reviews, device binary verification, and bench approval.
bash ci/publish-release.sh refresh --board orange-pi-5-plus --channel drill \
  --expect-serial 4 --expect-etag "$etag"
```

The command itself re-reads and verifies the immutable 2026.10.6 index,
bundle parts, whole digest and RAUC signature/compatible under the bench root.
It updates `channels/drill/orange-pi-5-plus.json{,.sig}` and creates an immutable
`channels/drill/orange-pi-5-plus.json.recovery/` intent. The existing release
prefix, Rock pointer and stable/beta pointers are untouched. If the
live serial, ETag, bundle digest or signer differs, **stop**, never force a
same-version overwrite. Afterwards fetch both new objects over the public
`https://images.ceralive.tv/channels/drill/orange-pi-5-plus.json{,.sig}` origin
(not just R2), repeat the CMS, signer CN/EKU and exact issuer checks above with
`-content <fetched.json>` and the reviewed manifest root, and confirm signed
`serial:5`, `board:orange-pi-5-plus`, `compatible:ceralive-orangepi5-plus`,
unchanged `version`, bundle/flash URLs, sizes, hashes and lock URL. Verify the
served bundle with `rauc info` under the reviewed bench root and match its
whole-file SHA-256 to the signed pointer. A CMS-valid but false compatible is
not a successful repair.

`prune --board <b> --channel-family` inventories all release keys, protects every
version referenced by **any** of the three current CMS-verified channel pairs,
keeps the three newest marked stable/beta versions across those two channels combined and
one newest drill version, and deletes only eligible keys under that board's
`releases/` prefix. A version with **no channel marker** is never pruned.
The workflow supplies the existing manifest-signer root to prune as well as
publish/refresh. Before planning or deleting any release key, prune requires
every present channel JSON to have a valid `.json.sig` under that root (including
the dedicated signer identity); a missing or mismatched signature refuses the
whole operation. An absent channel remains absent, not a fabricated reference.
`--dry-run` performs the real inventory/read and prints exact planned keys with
no R2 mutations; use it before pruning. `--selftest` publishes a unique synthetic
600 MiB logical file in three parts, compares an HTTP Range crossing the first
part boundary, and cleans up only the unique test prefix. Local stub/CMS contract:
`bash tests/publish-release.test.sh`. Live publishing by this executor is
restricted to `drill`; stable/beta require the owner to approve and dispatch.

### Legacy hawkBit registration (manual/operator-driven, updater dormant)

The retained private hawkBit tooling ([`fleet/hawkbit/`](../fleet/hawkbit/)) can
register an explicitly authorized legacy bundle. It is not part of the unified
orchestrator or a reason to re-enable the dormant updater. For that legacy path:

```bash
cd fleet/hawkbit
set -a; source .env; set +a
EXAMPLE_BUNDLE_FILE="${release_name}" ./provision.sh
```

`provision.sh` creates the RAUC software-module type, registers the artifact
**metadata only** (filename + sha256 — hawkBit never stores the blob; devices
fetch the blob straight from R2 via the artifact-URL rewrite, see
[`fleet/hawkbit/README.md`](../fleet/hawkbit/README.md)), and creates a
`compatible`-filtered distribution set. Triggering the actual rollout to
targets is a separate, deliberate operator action (a fresh rollout is created
**paused** and must be explicitly started) — either via `platform-bridge.sh
trigger_rollout` or the Management API directly. The operator dashboard for
this is deferred to `ceralive-platform` (task 43 in the fleet integration
contract); it does not exist in this repo.

---

## 6. Verification

Two verification passes bracket the whole path, one before ship and one after:

**Pre-flash (build-time, offline, this repo):**
[`tests/preflash-verify.sh`](../tests/preflash-verify.sh) checks GPT
geometry plus `sgdisk -v`, both idblock and parsed second-stage FIT, the compiled
boot selector and board metadata, the seeded boot state, complete arm64
kernel/DTB/initrd sets in A and B, destination capacity, and — the one
relevant to this doc — that the `.raucb` parses and carries the expected
`Compatible=` string. Pass the exact block-device size with
`--target-size-bytes`; see [`docs/DEVICE-BRINGUP.md`](DEVICE-BRINGUP.md) §3 for
the expected nine-green-check output. For FIT images with external data, the gate
separates the FDT metadata `totalsize` from the full payload extent, bounds every
declared payload within the image and 8 MiB bootloader budget, and verifies each
payload against its SHA-256 hash node before authorizing a flash.

**Post-install (on the fielded device):**

```bash
ssh ceralive@<device> 'rauc status'
ssh ceralive@<device> 'systemctl status ceralive-healthcheck.service'
```

`ceralive-healthcheck.service` is the gate that decides whether the newly
booted slot gets `rauc mark-good` — see §8 for the full rollback contract this
feeds into. For the legacy tooling only, hawkBit's Management API reports per-target action status
(`RUNNING` / `FINISHED` / `ERROR`) for anyone tracking a fleet-wide rollout,
per the integration contract in `fleet/integration-contract.md`.

The operator's §3 hand-test on real hardware already proves the rollback and
healthcheck contract against real silicon **before** the bundle ships —
post-install verification on a fielded device is confirming that the same proven
contract held for this specific rollout, not re-deriving it from scratch.

---

## 7. Runbook: rotating the apt.ceralive.tv build credentials

Scope: `APT_GPG_PUBLIC_B64`, `APT_CLIENT_CRT_B64`, `APT_CLIENT_KEY_B64` — the
three secrets `fetch-debs.sh::fetch_first_party()` needs to pull the five
first-party `.deb`s (`libsrt1.5-ceralive`, `cerastream`,
`gstreamer1.0-libuvcsrc`, `ceralive-device`, `srtla`) from
`apt.ceralive.tv` during a real (non-`DRY_RUN`) build.
The image's APT-source writer is
[`mkosi/customize/apt-ceralive-repo.sh`](../mkosi/customize/apt-ceralive-repo.sh),
which configures the image's own authenticated source. The new runtime image
gets its fleet mTLS pair from `ceralive-apt-credentials=1.0.1`, not a baked copy
of CI's private APT client key. Build-only credentials and reusable build caches
must not become runtime credential or release-authority inputs.

This is a **distinct** rotation from the RAUC signing PKI in
[`docs/cert-rotation-policy.md`](../docs/cert-rotation-policy.md) — that
doc governs the leaf/intermediate/root chain that signs `.raucb` bundles; this
section governs the mTLS + GPG credential that authenticates a **build host**
to the `apt.ceralive.tv` package feed. Don't conflate the two.

### Where they live today

`v2-ci.yml`'s build-matrix job runs `DRY_RUN=1` specifically so it never needs
these values (its own header comment says so: "No secrets are referenced"). The
protected `release.yml` candidate job injects them from GitHub Actions secrets
for release pushes/tags. The operator's bench flash-and-verify tool
(`verify-and-flash-candidate.sh`) takes the board address/port, stable UART path,
approved Maskrom USB identity hash, and absolute path to the mode-`0600`
host-local UART signing key as its own inputs. The verifier rejects
that key before USB access unless its derived public key equals the verifier baked
into the candidate. SSH is fixed to root. Loader
bytes travel inside the candidate artifact, and the board-login key is generated
and revoked per run; it is neither a runner variable nor a stored secret.
The release workflow keeps the values env-only and materializes them after cache restore; they are never
part of a cache key or Docker build context.

For any additional authenticated build path, store these three values as
**GitHub Actions encrypted repository secrets** (`Settings → Secrets and
variables → Actions → Repository secrets`), scoped to an environment
(`production`) with required reviewers, exactly the way `fetch-debs.sh`
expects to consume them (env-only, base64-encoded, never written to disk
outside the isolated per-run apt state dir).

### Half-supplied-pair-is-fatal behavior

`APT_CLIENT_CRT_B64` and `APT_CLIENT_KEY_B64` are a **matched pair** — the mTLS
cert and its key. Both `fetch-debs.sh` (`fetch_first_party()`, line ~552-555)
and its device-side twin `apt-ceralive-repo.sh` (`install_mtls_cert()`, line
~63-69) enforce the identical rule:

```bash
if [[ -n "${crt}" && -z "${key}" ]] || [[ -z "${crt}" && -n "${key}" ]]; then
  die "incomplete mTLS pair: set BOTH APT_CLIENT_CRT_B64 and APT_CLIENT_KEY_B64, or neither"
fi
```

Setting only one of the pair is treated as a misconfiguration and **fails the
build loudly** — never a silent skip, never a fallback to an unauthenticated
fetch. Setting **neither** is a valid, supported state (the build proceeds
without mTLS, GPG-only — e.g. for a package feed that doesn't require client
certs); setting **exactly one** is always a hard error. `APT_GPG_PUBLIC_B64` is
independent of the mTLS pair: without it, `fetch-debs.sh` auto-enables
`DRY_RUN` (no credential to do a GPG-verified fetch with) rather than
attempting an unverified download — see `main()` line ~671-676.

### Rotation procedure

1. **Generate the new credential set** at its source of truth (the
   `apt.ceralive.tv` operator side — GPG keypair for repo signing, mTLS
   CA-issued client cert/key for the build-host identity). This is outside
   this repo's scope; whoever operates `apt-worker`'s upstream signing/CA
   process owns key generation.
2. **Base64-encode each value** exactly as the consumers expect (a single
   `base64` pass over the raw PEM/keyring bytes — no PASERK-style double
   wrapping, unlike the PASETO key contract in
   [`docs/paseto-key-provisioning.md`](../docs/paseto-key-provisioning.md)):
   ```bash
   APT_GPG_PUBLIC_B64="$(base64 -w0 < new-ceralive-archive-keyring.asc)"
   APT_CLIENT_CRT_B64="$(base64 -w0 < new-client.crt)"
   APT_CLIENT_KEY_B64="$(base64 -w0 < new-client.key)"
   ```
   The current secret is armored `.asc`; a binary `.gpg` public keyring is also
   accepted for compatibility. Before mkosi runs, the native host or canonical
   builder executes `lib/dearmor-apt-keyring.sh`, verifies the resulting binary
   OpenPGP keyring with `file(1)`, and forwards only the binary payload into the
   runtime postinstall. This is build-only tooling: the device image must not gain
   `gpg` or `file` for this conversion.
3. **Update wherever the current values are stored** — today, that means every
   place a human or private CI job keeps them (local `.env`, a secrets
   manager, or GitHub repository secrets once §5's future CI job lands). Set
   all three (or leave the mTLS pair both-unset) — never touch only one of
   `APT_CLIENT_CRT_B64`/`APT_CLIENT_KEY_B64` in isolation, or the next build
   fails the half-supplied-pair guard.
4. **Verify with a real (non-`DRY_RUN`) fetch** before relying on the new
   credentials for a release build:
   ```bash
   DEST=/tmp/fetch-verify \
   APT_GPG_PUBLIC_B64="${APT_GPG_PUBLIC_B64}" \
   APT_CLIENT_CRT_B64="${APT_CLIENT_CRT_B64}" \
   APT_CLIENT_KEY_B64="${APT_CLIENT_KEY_B64}" \
   ./lib/fetch-debs.sh --family manifests/families/<family>.yaml
   ```
   A successful run logs `first-party: staged 4 .deb(s) from
   https://apt.ceralive.tv/...`. Any GPG/mTLS mismatch fails loudly at
   `apt-get update`/`download`, not silently.
5. **Revoke the old credential set** at the source of truth once every build
   host/CI job that used it has confirmed the new one works — there is no
   device-side impact to rotating these (they are build-time only; a fielded
   device never sees `apt.ceralive.tv`'s mTLS client cert).
6. **Never commit or log any of the three raw values.** They must only ever
   exist base64-encoded, in-memory, in an environment variable, or inside a
   secrets manager — the same invariant `fetch-debs.sh`'s own header comment
   states ("NEVER hardcoded, NEVER logged, NEVER committed").

### Rotation cadence recommendation

- **GPG keyring (`APT_GPG_PUBLIC_B64`):** rotate on the same cadence as the
  `apt.ceralive.tv` repo-signing key's own policy (align with whatever
  interval `apt-worker`'s operators set for `Release`/`InRelease` signing) —
  **at minimum annually**, sooner on any suspected compromise.
- **mTLS client cert/key (`APT_CLIENT_CRT_B64` / `APT_CLIENT_KEY_B64`):**
  treat as a **build-host identity credential** — rotate on a **≤1 year**
  cycle, mirroring the RAUC leaf-certificate rotation window (≤2y) but
  tighter, since this credential authenticates every real build rather than
  every OTA bundle. Rotate immediately if a build host is decommissioned or a
  laptop/CI runner holding the credential is lost or compromised.
- In both cases, treat "half-supplied pair" failures during rotation as a
  signal to **stop and check the update**, not to work around it — the guard
  exists precisely to catch a rotation applied to only one side of the pair.

---

## 8. Runbook: fleet response to a bad `.raucb`

Scope: what happens — automatically, on-device — when a published OTA bundle
turns out to be broken, and what an operator does to stop it from spreading
further or to pull it from circulation.

The one-time Bookworm → Trixie/mainline transition has an additional compatibility
profile and an exact two-arm bench drill (deliberate failure → automatic Bookworm
rollback, then healthy apply + `/data` JSON survival). Run
[`ota-bookworm-trixie-transition.md`](ota-bookworm-trixie-transition.md) before
using the generic fleet-response procedure below. Todo 12 establishes the
offline contract; todo 16 executes it on hardware.

### The A/B fallback contract (automatic, on-device, no operator action needed)

RAUC's A/B slot model provides bounded automatic rollback for a bad update when
the factory image passed the A/B preflash gate and the board-specific hardware
cycle has passed. The software contract is exercised by
[`tests/rauc-rollback.sh`](../tests/rauc-rollback.sh) (run live on real
hardware as part of the §3 operator hand-test, and in a MOCK mode that drives the
same shipped scripts without hardware):

1. `rauc install` marks the inactive target bad, writes the new bundle there,
   and makes it primary only after the write succeeds. If installation is
   interrupted first, the currently-running slot remains primary.
2. On reboot, the device boots the new (now-primary) slot with a **bounded
   bootcount budget** (`BOOT_ATTEMPTS`, default 3).
3. `ceralive-healthcheck.service` runs after boot and decides the slot's fate:
   - **Healthy** (service active, `cerastream`/`srtla_send` load, SRT
     reachable) → `rauc mark-good`. The slot's bootcount resets, and the
     switch to the new slot is now **permanent** — a subsequent reboot does
     **not** revert, even after the confirmation.
   - **Unhealthy** (e.g. a stripped/missing encoder binary, service
     inactive) → the healthcheck does **not** confirm. The slot's bootcount
     bleeds down (3→2→1→0) across repeated boot attempts.
4. Once the bad slot's bootcount is exhausted, the boot selector (U-Boot's
   `boot.scr` on RK3588, GRUB's `grubenv` A/B selector on x86 — see
   `mkosi/platform/x86/README.md` §2 for the x86 mirror of this contract)
   **automatically falls back** to the last-known-good slot. The device
   resumes streaming on the old, still-good software with **zero operator
   intervention**.
5. The `OTA-during-stream guard` (`ceralive-update`, see root `AGENTS.md` /
   this repo's `docs/agents/key-facts.md` KEY FACTS) additionally refuses to even **start**
   installing an update while `cerastream.service` / `srtla.service` /
   `srtla-send.service` is active — a bad bundle pushed during a live
   broadcast doesn't get a chance to interrupt it in the first place.

The A/B contract covers the **ModemManager 1.24 closure** the same way it covers
every other baked package: the nine fork `.deb`s (`modemmanager` +
`libmm-glib0`/`libqmi-*`/`libmbim-*`/`libqrtr-glib0`, all `~ceralive.3`) are
installed into the rootfs, atomic with the RAUC slot, so a bad modem-stack bundle
rolls back with the slot — there is no separately-updatable modem partition to
strand. After a rollback the recovered slot runs whatever modem-stack version it
was built with; a bad closure never leaves a device with a half-installed
cellular stack. The generated `78-mm-ceralive-slot-uid.rules` file is likewise
per-slot rootfs content (absent while `modem_ports.status: unverified`), so it
never diverges from the running slot.

This is the automatic safety net for an already A/B-provisioned device. It does
not convert a legacy single-slot disk: that transition requires backup and a
full re-flash because the old `data` partition overlaps the new B slot. The
fleet-response actions below stop a bad bundle from reaching more devices.

### qemu-x86 fallback-selftest — the proof reference

The **x86** analogue of the RK3588 rollback contract (grubenv-based A/B,
no RAUC-specific tooling) is proven offline, with no board and no qemu, by:

```bash
tests/qemu-x86.sh --fallback-selftest
```

([`tests/qemu-x86.sh`](../tests/qemu-x86.sh) `run_fallback_selftest()`.)
It drives the **real shipped** `x86-boot-state.sh` engine (the same one the
on-device GRUB selector runs), forces a primary-slot failure by never
confirming it, and asserts:

- a single failed boot does **not** roll back yet (the slot still has budget
  — the non-vacuity control);
- once the bootcount is exhausted, the selector **does** fall back to the
  known-good slot, keyed by its `rootfs_b` PARTLABEL;
- the exhausted primary is marked `bad`, the fallback target stays `good`;
- a subsequent `mark-good` makes the recovered slot sticky (no further
  reversion).

This is the harness cited in this repo's [`docs/agents/where-to-look.md`](agents/where-to-look.md) `WHERE TO LOOK` table
as the "forced-primary-failure rollback proof" — treat a passing run of it as
the evidence that the x86 boot-state engine itself has not regressed, the same
way `rauc-rollback.sh`'s MOCK mode is the evidence for the RK3588 engine. Both
are proof of the **engine**, not a substitute for the operator's real-hardware
hand-test in §3 (the operator's RK3588 hand-test is the only accepted proof for
that board — "no qemu/mock result is accepted as the RK3588 rollback proof" per
the harness's own MOCK-mode warning banner).

### Pausing or superseding a published bundle on R2

Immutable bundle objects and their digest sidecars are never deleted or
overwritten.

**Signed image channels (the path capable devices use).** There is no pause or
rollback command for a signed channel. The response to a bad release is to
publish a fixed, **newer** OS CalVer through the same `publish`/`promote` flow
in §5, which moves the channel pointer to the fix with a higher serial. Never
delete, rewrite or reuse the bad release's `releases/<board>/<CalVer>/` prefix;
`prune` only removes versions no current channel references and that fall
outside its retention count. On the device, CeraUI refuses a channel manifest
whose serial is not higher than the one it last accepted, a version that is not
newer than the booted one, and a version on its quarantine list, which it adds
to after an OS rollback. So a device that fell back from the bad release never
retries it, and pointing a channel back at an older release does not move
devices that already run the bad one. That is a limit: a device that booted the
bad release and passed its healthcheck stays on it until the newer fix is
published.

**Legacy hawkBit tooling (dormant).** `rauc-hawkbit-updater` is disabled on new
images, so these steps apply only to a deployment still driven by the retained
hawkBit tooling. If a bundle it distributes is found to be bad:

1. **Pause the hawkBit rollout** so no further devices are offered the bad
   distribution set:
   ```bash
   curl -u "$HAWKBIT_ADMIN_USER:<pass>" \
     -X POST "http://127.0.0.1:8080/rest/v1/rollouts/<rollout-id>/pauseGroup"
   ```
   (or the equivalent `platform-bridge.sh` call once that verb is exposed; see
   `fleet/integration-contract.md` for the rollout-control surface).
2. **Supersede, never delete.** Build a fixed bundle, sign it
   (§4), upload it under a **new** timestamped filename (§5's manual steps),
   and register it with hawkBit as a new artifact/distribution set
   (`provision.sh`). Devices that already pulled the bad bundle self-heal via
   the fallback contract above regardless; devices that haven't updated yet
   get offered the fixed one instead. This avoids ever deleting an artifact a
   device might still be mid-download of.

### Healthcheck interplay

The healthcheck (`ceralive-healthcheck.sh`, gated by
`ceralive-healthcheck.service`) is what makes the fallback contract
**self-driving** rather than requiring an operator to watch every device's
boot log:

- It is the **sole** gate on marking the **booted** slot good — nothing else
  confirms the slot the board is running on. `ceralive-slot-sync.sh` marks only
  the other slot good (`rauc status mark-good other`), and only after it has
  mirrored the healthy running slot into it and verified the copy.
- Confirmation is scoped to the current kernel boot ID, stored beside the
  timestamp in `/data/ceralive/.slot-marked-good`. A previous boot's marker,
  including a legacy timestamp-only one, never suppresses checks. Same-slot
  reboots must replenish the attempt budget just as A/B swaps do; install-time
  marker removal alone cannot provide that guarantee.
- It is deliberately **non-fatal** for cosmetic/secondary probes (e.g. the mDNS
  probe, or the HTTPS `:443` check on a device whose uplink is briefly down
  during provisioning) — see this repo's `docs/agents/add-on-subsystem.md` "CeraUI TLS front" section.
  A UI/TLS hiccup does not roll back a slot whose core streaming stack
  (`cerastream`/`srtla_send`/`srtla`) is genuinely healthy.
- It **is** fatal for the streaming-critical checks (service active, encoder
  binary loadable, SRT reachability when configured) — exactly the checks
  `rauc-rollback.sh`'s BAD-BUNDLE test case exercises by stripping the
  `cerastream` binary and asserting the healthcheck refuses to confirm.

An operator investigating a fleet-wide rollback pattern (many devices falling
back around the same time) should start at `journalctl -u
ceralive-healthcheck.service` on an affected device — the exact failing probe
line tells you whether the bundle itself was bad or whether the failure is
environmental (e.g. no SRT reachability at that specific site, which the
healthcheck's own skip-when-unconfigured logic already accounts for).

### Resolved finding — mark-good is scoped to one kernel boot [EXISTS]

An older Rock 5B+ image treated `/data/ceralive/.slot-marked-good` as a permanent
existence flag. That allowed a stale marker to skip health checks while the U-Boot
selector decremented the slot's remaining attempts on each reboot, eventually
reporting a healthy slot as `bad`. The historical observation was a marker dated
`2026-07-19T17:06:10Z` and `BOOT_A_LEFT=0` five weeks later; it does not describe
the current healthcheck.

The unit now runs on every boot. The script reads the current kernel boot ID and
accepts a marker only if its `boot-id` matches; a previous boot's marker or an
old timestamp-only marker is ignored. After the service, binary and configured
reachability checks succeed and RAUC marks the running slot good, the script
writes the current boot ID beside the timestamp. An unreadable boot ID fails
closed. This replenishes the attempt budget on healthy same-slot reboots as well
as after an A/B switch; removal by an installer is compatible but no longer
needed for correctness. `tests/healthcheck-boot-marker.bats` exercises stale
markers and exhausted counters. Inspect the marker's `boot-id` and the current
`/proc/sys/kernel/random/boot_id` when diagnosing a mark-good decision.

---

## See also

- [`docs/DEVICE-BRINGUP.md`](DEVICE-BRINGUP.md) — the developer build/flash/dev-loop guide this doc's §4 and §6 summarize.
- [`docs/cert-rotation-policy.md`](../docs/cert-rotation-policy.md) — RAUC signing-PKI rotation (leaf/intermediate/root) — a distinct procedure from §7.
- [`docs/paseto-key-provisioning.md`](paseto-key-provisioning.md) — the sibling runbook style this doc follows for a different credential (device-token PASETO keys).
- [`fleet/hawkbit/README.md`](../fleet/hawkbit/README.md) + [`fleet/integration-contract.md`](../fleet/integration-contract.md) — the fleet rollout engine referenced in §5 and §8.
- [`docs/DEFERRED.md`](../docs/DEFERRED.md) — index of every other deferred/hardware-gated item in this pipeline.
- [`docs/kernel-release.md`](kernel-release.md) — the local kernel-only release
  runbook: version bump, candidate, gates, refused publication and the device
  records that report success or rollback.
