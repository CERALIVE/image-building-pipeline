# Release process

How a CeraLive device image actually goes from a merged commit to a bundle a
fielded device can install — as the pipeline is wired **today**, not as it is
someday planned to be. Two runbook sections live at the bottom: credential
rotation for the build-time apt secrets, and fleet OTA rollback.

> **Honesty rule for this doc.** Every stage below is either (a) backed by a
> script or workflow that exists in this repo right now, with its path cited, or
> (b) explicitly marked **MANUAL (no automation yet)** with the exact operator
> steps to run by hand. Nothing here describes a CI job that isn't committed.

---

## 1. The path at a glance

```
push to release/** or vX.Y.Z tag
        │
        ▼
release.yml: admission + production build
        │
        ▼
./v2/build <board>  →  orchestrate.sh  →  build-bundle.sh
        │                                       │
        │                                       ▼
        │                            signs the leaf-key .raucb,
        │                            verifies leaf→intermediate→root
        │
        ▼
seal + upload one immutable candidate artifact
        │
        ▼
realhw-job.yml: realhw-suite.sh on a REAL RK3588
(boot/service, encode-path init, dev-loop sanity, RAUC A/B rollback)
        │
        ▼  (once the gate is green; MANUAL from here down)
operator uploads images/<board>/<ts>.raucb (+ .sha256) to R2
        │
        ▼
operator registers bundles/{channel}/{board}/<ts>.raucb + rolls out via hawkBit
(v2/fleet/hawkbit/provision.sh, platform-bridge.sh)
        │
        ▼
device rauc-hawkbit-updater pulls from apt.ceralive.tv/bundles/...
        │
        ▼
verification: preflash-verify.sh (pre-flash) + on-device
rauc status / ceralive-healthcheck (post-install)
```

The production job signs and seals the exact candidate first so the physical
real-HW gate tests the bytes that could ship. A human may publish those bytes
only after that gate passes. Everything from "operator uploads" onward is a
manual, operator-driven step today — there is no committed workflow that does
it for OS bundles. Section 5 spells out exactly why and exactly what to type.

---

## 2. Trigger

[`release.yml`](../.github/workflows/release.yml) fires on:

- a push to `release/**`
- a `v*` tag (e.g. `v2026.7.0`)

It builds and seals one production candidate, then calls
[`realhw-job.yml`](../.github/workflows/realhw-job.yml) with the immutable
artifact identity. `concurrency.cancel-in-progress: false` prevents a newer
release push from cancelling a build or flash in progress.

There is no version-bump automation in this repo. The tag itself is the release
marker; CeraLive's CalVer convention (`YYYY.MINOR.PATCH`, documented as the
cross-repo source of truth in `CeraUI/docs/APT_VERSION_CONTROL.md`) governs what
string goes in the tag and in `BUNDLE_VERSION` (§4).

A workflow rerun for an existing tag always checks out that tag's original SHA.
If a release fix lands after the tag, rotate any affected secret first; rerunning
the old tag does not include the merged code. Merge the fix, push an untagged
`release/**` branch at that exact merge SHA, and require both the production
candidate and physical real-HW jobs to pass. Verify the successful run SHA equals
the merge SHA, then create the next unused CalVer patch tag at that same proven
commit. A new tag must not be the first production execution of a release-path
repair, and an older tag is never moved or rerun to pick up the fix.

For the resource failure after `v2026.7.2`, the only eligible next patch is
`v2026.7.3`; never rerun or move `v2026.7.0`, `v2026.7.1`, or `v2026.7.2`.

---

## 3. Real-HW gate

`release.yml` first builds and uploads one immutable production candidate, then
calls `realhw-job.yml` on the **self-hosted runner physically wired to an RK3588
board** (`[self-hosted, ceralive-rk3588, rock-5b-plus]`). The artifact name, artifact digest,
raw filename, raw SHA-256, bundle, keyring, hash-pinned Maskrom loader, and
candidate commit are all required workflow inputs. The candidate job labels the
upload action's bare hexadecimal
digest as `sha256:<64 lowercase hex>` before passing it to the real-HW workflow,
whose input contract rejects any other form.

The reusable job is admitted only from this repository's `release.yml`, on a
first-attempt `push` to `release/**` or `v*`, and enters the protected
`image-hardware` environment before a self-hosted runner is selected. Configure
that environment for trusted required reviewers and restrict its deployment
branches and tags to those same release refs before adding the hardware labels.

Steps, in order:

1. **Candidate verification** — verify the exact raw SHA-256, production bundle,
   embedded slot keyrings, boot artifacts, GPT geometry, loader SHA-256, and
   loader-mode eMMC capacity before any media write.
2. **Required flash and identity proof** — copy the raw into a private snapshot,
   verify its SHA-256, and use that same snapshot for preflight and the RK3588
   Maskrom write. The board is expected to be in Maskrom when the job starts;
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

   After the pinned loader is positively observed, `rkdeveloptool rci` captures
   the 16-byte SoC-**family** marker before `wl`. The structured parser accepts LF
   and CRLF framing, strips only the terminal transport CR, and requires exactly one
   `Chip Info:` record of exactly 16 one- or two-digit hex octets. Truncated,
   extra, split, nonhex, or duplicate records fail closed before media write. `rci`
   returns the RK3588 family constant (identical on every board of this SoC), not a
   per-device id — Maskrom exposes no per-device read — so it is only a coarse
   family guard; the accepted downstream family marker is lowercase 32-hex. A UART
   helper acquires the serial port before the write, then
   interrupts U-Boot and supplies a volatile, one-boot data-only UART bootstrap
   argument. A dedicated host-local Ed25519 key signs the request; the image
   contains only its public verification key. Before USB access, the verifier
   proves that the configured private key derives that exact public key. The
   bootstrap emits a fresh device nonce and verifies the signature, nonce, baked
   candidate commit, USB-captured SoC-family marker, one-hour maximum expiry, and a
   persistent non-decreasing epoch floor before it installs a newly
   generated, restricted root public key with an
   absolute expiry into the empty `/data` authorized-key store; neither the key
   nor a password is embedded in the immutable image. The board must reconnect
   before the bounded retry budget expires with a media **CID** that matches the
   one the UART bootstrap recorded (the genuine **per-device** binding), the same
   RK3588 SoC-**family** marker read by Linux from the first 16 bytes of the
   raw OTP NVMEM device (a coarse family guard, not per-device), a root filesystem
   whose parent is the flashed eMMC, and a fresh run-local SSH host-key record.
   The gate deliberately does not hash
   post-boot media because U-Boot state and the mounted rootfs are mutable. Its
   later `rkdeveloptool` children retain their cancellable/reaped behavior. The
   verifier resets inherited
   ignored INT/TERM dispositions before Bash starts its traps, covering
   asynchronous CI-shell launches where SIGINT would otherwise remain ignored.
   Artifact filenames in the identity record are restricted to a safe
   line-oriented character set.
3. **The gate itself** — [`v2/tests/realhw-suite.sh`](../v2/tests/realhw-suite.sh),
   which runs four sub-harnesses in sequence and aggregates one exit code:
   - **boot+service** (`v2/tests/realhw-smoke.sh`) — boot, service, binary,
     quirk checks, and required live parity against the manifest. Missing or
     incomplete parity collection is a hard failure.
   - **encode-path init** — `cerastream --version` / `srtla_send --version`
     actually run on the board.
   - **dev-loop sanity** — `v2/dev-push` completes in under 120s using the
     candidate-bound package in `DEV_DEB_DIR`; this lane is required.
   - **RAUC A/B rollback** ([`v2/tests/rauc-rollback.sh`](../v2/tests/rauc-rollback.sh))
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
./v2/build rock-5b-plus
```

which execs [`v2/lib/orchestrate.sh`](../v2/lib/orchestrate.sh) through its
staged pipeline (resolve manifest → fetch `.deb`s → validate → mkosi → assemble
disk → write the bootloader gap → emit the signed `.raucb`). See
[`docs/DEVICE-BRINGUP.md`](DEVICE-BRINGUP.md) §2 for the full stage list and
artifact layout.

### Production builder admission

The dedicated `ceralive-image-builder` runner must use the host's native Linux
Docker daemon. The candidate job sets `DOCKER_CONTEXT=default`, and
[`check-builder-resources.sh`](../v2/ci/check-builder-resources.sh) runs before
BuildKit. It fails closed unless all of these are true:

- `default` resolves to `unix:///var/run/docker.sock` and the daemon is not
  Docker Desktop;
- Docker reports at least 16 GiB daemon-visible memory;
- the workflow-pinned `/proc/meminfo` reports at least 16 GiB combined
  `MemAvailable` + `SwapFree`;
- the checkout and Docker root each have at least 24 GiB free.

These are admission floors for the production path, not a substitute for the
full build or hardware gate. If admission fails, restore native-daemon access or
free the reported resource and start a new candidate from the fixed commit. Do
not increase a timeout, bypass the check, or rerun/move an existing immutable
tag.

The raw disk's large logical size is flash geometry, not transport size. The
assembler creates it sparse; candidate sealing uses a same-filesystem hard link
instead of a byte copy, and `actions/upload-artifact` compresses the candidate at
explicit level 6. This keeps the raw bytes and SHA-256 unchanged while avoiding
a second allocated raw during the upload window.

### Production build caches

The candidate job persists only reusable build state; it never caches a
candidate image or a trust input. BuildKit loads the canonical
`v2/ci/Dockerfile` builder image and exports its layers through the GitHub
Actions cache with a stable repository/OS/architecture/board/mkosi-tool scope.
The source hash is carried in the builder tag and label, while BuildKit's
content-addressed Dockerfile/context digests select the reusable layers. The
export uses `mode=min` so the cache contains only layers needed by the loaded
builder image.

The same job restores and saves only the board-specific mkosi package cache at
`v2/mkosi/cache/rock-5b-plus`. Its exact key includes the repository, runner
OS/architecture, board, mkosi pin, and build-source hash; its fallback prefix
keeps those axes fixed. Before saving, the workflow enforces a 2 GiB ceiling,
measures/prunes the tree as root inside the builder container, and normalizes
ownership to the runner so mode-700 mkosi entries remain cacheable. Image outputs,
`.staging`, QEMU state, apt credentials, and release artifacts are not cache
inputs. These steps are guarded to release pushes/tags, and the trust-input
step remains after cache restore and builder preparation; the production build,
candidate contents, and required real-HW workflow call are unchanged. Candidate
sealing uses the same-filesystem hard link described above.

Fetching the five first-party `.deb`s (`libsrt1.5-ceralive`, `cerastream`,
`gstreamer1.0-libuvch264src`, `ceralive-device`, `srtla-send-rs`) from `apt.ceralive.tv` needs a GPG-verified,
mTLS-authenticated apt source — the exact credential contract is
`APT_GPG_PUBLIC_B64` / `APT_CLIENT_CRT_B64` / `APT_CLIENT_KEY_B64` in
[`v2/lib/fetch-debs.sh`](../v2/lib/fetch-debs.sh) `fetch_first_party()`
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
bash -c 'source v2/lib/fetch-debs-auth.sh; \
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

`v2/lib/fetch-debs.sh` independently enforces exact primary-fingerprint set
equality before either apt or the curl fallback runs. That check deliberately
rejects old-only, new-only, malformed, revoked, expired, invalid, disabled,
normalization-failed, and expected-plus-unrelated keyrings. Both native apt and
curl paths re-verify the downloaded `InRelease` with `gpgv`; both signatures must
be valid before package download begins.

### Armbian BSP package pin promotion

Family manifests choose the required BSP package names. Production resolves those
names only through the exact Debian versions in
`v2/manifests/armbian-bsp-deb-versions.txt`; it never asks apt for an unqualified
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
   `v2/manifests/bsp-baseline.json` to the reviewed version and content hash in the
   same change.
4. Run `v2/tests/bsp-package-resolution.test.sh`, `v2/run-tests`, an authenticated
   live BSP fetch, and the release hardware gate before shipping a new immutable
   tag.

If a tagged candidate fails, merge the fix and follow the §2 repair procedure:
prove the exact merge SHA with an untagged `release/**` production candidate and
physical real-HW pass, then create the next unused CalVer patch tag at that same
commit. Never move or rerun an older tag expecting it to pick up new code.

### Signing (`build-bundle.sh`)

The orchestrator's stage 8 calls [`v2/lib/build-bundle.sh`](../v2/lib/build-bundle.sh)
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
  real `rauc` path or the deterministic OpenSSL-CMS fallback path.
- **Verification is part of the same step.** After signing, `build-bundle.sh`
  immediately verifies the bundle against the injected `root-ca.pem` (the
  same keyring baked into the device) — `rauc info` on a host with `rauc`
  installed, or an equivalent OpenSSL CMS chain-verify
  (`verify_openssl_bundle()`) when it isn't. A bundle that fails to verify
  never leaves the build host.
- **Reproducible by default** (`REPRODUCIBLE=1`). `SOURCE_DATE_EPOCH` clamps
  every embedded mtime and the OpenSSL CMS signer uses `-noattr` (no wall-clock
  `signingTime`), so the same source state produces a bit-identical `.raucb`.
  `REPRODUCIBLE=0` opts back into the native `rauc bundle` signer, which is
  **not** bit-reproducible (rauc always bakes a signing timestamp).

The RAUC signing PKI itself (root/intermediate/leaf tiers, validity, and how a
leaf or intermediate rotates through the channel without a reflash) is a
**separate** rotation procedure from the apt credentials in §7 — see
[`v2/docs/cert-rotation-policy.md`](../v2/docs/cert-rotation-policy.md) for the
full contract; it isn't duplicated here.

### CI determinism coverage — cross-runner build-plan gate (C6b)

CI cannot run the privileged mkosi build (no network / privileged container /
board under `DRY_RUN`), so it does **not** produce — let alone dual-host-compare —
a real signed `.raucb`. What it CAN prove is the reachable precondition for the
bit-identical bundle above: that the **build plan / input closure** resolves
host-independently.

- The [`v2-ci.yml`](../.github/workflows/v2-ci.yml) `build-plan-xrunner` +
  `build-plan-xrunner-gate` jobs resolve the `DRY_RUN=1` mkosi plan on **two
  independent GitHub-hosted runners** (`ubuntu-24.04` + `ubuntu-22.04`), hash the
  **normalized** per-board plan ([`v2/ci/emit-build-plan-sha.sh`](../v2/ci/emit-build-plan-sha.sh)
  — the same task-15 normalization: strip the abs repo path → `<REPO>`, sha256 the
  single line), and fail if the two runners disagree on any board's plan sha256
  ([`v2/ci/assert-xrunner-parity.sh`](../v2/ci/assert-xrunner-parity.sh)). It
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
  a full `.raucb` image build**. **Full-artifact (`.raucb`) determinism remains
  future work** — it would require running the real privileged mkosi build on two
  independent hosts and comparing the signed bundle bytes. The plan gate plus the
  `SOURCE_DATE_EPOCH` clamp above is the necessary precondition for a bit-identical
  image, not a substitute for proving it.

---

## 5. R2 upload — the ACTUAL mechanism (MANUAL today)

**There is no CI job or high-level candidate publisher for signed OS `.raucb`
bundles.** The tested low-level helper performs only the final immutable R2 pair
write after an operator completes every proof below. Compare the three artifact
families this pipeline produces:

| Artifact | R2 path | Publisher |
|----------|---------|-----------|
| Feature-sysext add-ons | `addons/{os_version}/{board}/{feature}.raw` | [`v2/lib/upload-addons.sh`](../v2/lib/upload-addons.sh) — **exists, automatable, CI-proven under `DRY_RUN`** (`v2-ci.yml` `addon-publish` job) |
| CeraUI federation UI bundles | `ui-bundle/{ceraui-version}/*.js` | CeraUI's own `publish-release.yml` → `publish-federation` job — **exists in the CeraUI repo** |
| **OS `.raucb` OTA bundles** | `bundles/{channel}/{board}/*.raucb` | manual candidate proof, then [`publish-immutable-r2-pair.sh`](../v2/ci/publish-immutable-r2-pair.sh); **no publishing workflow** |

`apt-worker/AGENTS.md` and `apt-worker/README.md` both describe the `bundles/`
path as a pure read side (the worker range-serves whatever is already in R2)
and explicitly credit the add-on and federation paths to their respective
publisher scripts. The helper here is operator-invoked and is not a release
workflow or candidate-selection authority.

### Operator steps (today, until this is automated)

Until a high-level publisher or equivalent CI job exists, publish a release
bundle manually from the exact candidate artifact that passed physical hardware.
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
expected_media_cid=<approved-32-lowercase-hex-media-cid>
artifact_name="rock-5b-plus-${merge_sha}"
realhw_artifact_name="realhw-${board}-${run_id}"

# Bind publication to the successful workflow at the exact proven merge SHA.
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
test "${run_workflow}" = 'Release candidate real-HW gate'
test "${workflow_path}" = '.github/workflows/release.yml'
master_status="$(gh api "repos/${repo}/compare/${merge_sha}...master" --jq .status)"
[[ "${master_status}" == identical || "${master_status}" == ahead ]]

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
publisher="${tmp}/publish-immutable-r2-pair.sh"
GIT_NO_REPLACE_OBJECTS=1 git show "${merge_sha}:v2/ci/publish-immutable-r2-pair.sh" > "${publisher}"
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

# Select the physical acceptance evidence emitted by this same workflow run.
realhw_artifact_id="$(jq -er --arg name "${realhw_artifact_name}" '
  [.artifacts[] | select(.name == $name and (.expired | not))]
  | if length == 1 then .[0].id else error("expected exactly one live real-HW evidence artifact") end
' "${tmp}/artifacts.json")"
realhw_artifact_digest="$(
  gh api "repos/${repo}/actions/artifacts/${realhw_artifact_id}" --jq .digest
)"
realhw_artifact_sha="$(
  gh api "repos/${repo}/actions/artifacts/${realhw_artifact_id}" --jq .workflow_run.head_sha
)"
[[ "${realhw_artifact_digest}" =~ ^sha256:[0-9a-f]{64}$ ]]
test "${realhw_artifact_sha}" = "${merge_sha}"

# Verify both exact GitHub artifact archives before inspecting the tested bytes.
gh api -H 'Accept: application/vnd.github+json' \
  "repos/${repo}/actions/artifacts/${artifact_id}/zip" > "${tmp}/candidate.zip"
printf '%s  %s\n' "${artifact_digest#sha256:}" "${tmp}/candidate.zip" | sha256sum -c -
mkdir "${tmp}/candidate"
unzip -q "${tmp}/candidate.zip" -d "${tmp}/candidate"
gh api -H 'Accept: application/vnd.github+json' \
  "repos/${repo}/actions/artifacts/${realhw_artifact_id}/zip" > "${tmp}/realhw.zip"
printf '%s  %s\n' "${realhw_artifact_digest#sha256:}" "${tmp}/realhw.zip" | sha256sum -c -
mkdir "${tmp}/realhw"
unzip -q "${tmp}/realhw.zip" -d "${tmp}/realhw"

candidate="${tmp}/candidate"
identity="${tmp}/realhw/candidate-identity.txt"
expected_raw_sha="$(awk 'NR == 1 { print $1 }' "${candidate}/raw.sha256")"
[[ "${expected_raw_sha}" =~ ^[0-9a-f]{64}$ ]]
[[ "${expected_media_cid}" =~ ^[0-9a-f]{32}$ ]]
grep -Fx "candidate_commit=${merge_sha}" "${identity}"
grep -Fx "raw_sha256=${expected_raw_sha}" "${identity}"
grep -Fx 'bundle_file=good.raucb' "${identity}"
grep -Fx "artifact_digest=${artifact_digest}" "${identity}"
grep -Fx "media_cid=${expected_media_cid}" "${identity}"
grep -Fx 'pre_boot_media_identity=verified' "${identity}"
grep -Fx 'post_boot_reconnect=verified' "${identity}"
grep -Fx 'flash_transport=maskrom-rkdeveloptool' "${identity}"
grep -F 'RESULT: 4 PASS / 0 FAIL / 0 SKIP' "${tmp}/realhw/realhw-suite.log"
grep -Fx '{"mode":"live","board":"rock-5b-plus","pass":4,"fail":0,"skip":0,"exit":0}' \
  "${tmp}/realhw/realhw/result.json"

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

**Future work.** The remaining gap is a high-level publisher that performs the
candidate/workflow/hardware checks above automatically and a protected
release-triggered job analogous to `v2-ci.yml`'s `addon-publish`. The low-level
immutable R2 pair helper deliberately does not select or trust a candidate by
itself.

### Registering the artifact with hawkBit (also manual/operator-driven)

Once the bundle is on R2, the private hawkBit fleet-update engine
([`v2/fleet/hawkbit/`](../v2/fleet/hawkbit/)) needs to know about it before any
device is offered the update:

```bash
cd v2/fleet/hawkbit
set -a; source .env; set +a
EXAMPLE_BUNDLE_FILE="${release_name}" ./provision.sh
```

`provision.sh` creates the RAUC software-module type, registers the artifact
**metadata only** (filename + sha256 — hawkBit never stores the blob; devices
fetch the blob straight from R2 via the artifact-URL rewrite, see
[`v2/fleet/hawkbit/README.md`](../v2/fleet/hawkbit/README.md)), and creates a
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
[`v2/tests/preflash-verify.sh`](../v2/tests/preflash-verify.sh) checks GPT
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
feeds into. hawkBit's Management API also reports per-target action status
(`RUNNING` / `FINISHED` / `ERROR`) for anyone tracking a fleet-wide rollout,
per the integration contract in `v2/fleet/integration-contract.md`.

The realhw gate (§3) already proves the rollback and healthcheck contract
against real silicon **before** the bundle ships — post-install verification on
a fielded device is confirming that the same proven contract held for this
specific rollout, not re-deriving it from scratch.

---

## 7. Runbook: rotating the apt.ceralive.tv build credentials

Scope: `APT_GPG_PUBLIC_B64`, `APT_CLIENT_CRT_B64`, `APT_CLIENT_KEY_B64` — the
three secrets `fetch-debs.sh::fetch_first_party()` needs to pull the five
first-party `.deb`s (`libsrt1.5-ceralive`, `cerastream`,
`gstreamer1.0-libuvch264src`, `ceralive-device`, `srtla-send-rs`) from
`apt.ceralive.tv` during a real (non-`DRY_RUN`) build.
The device-side twin of this same contract is
[`v2/mkosi/customize/apt-ceralive-repo.sh`](../v2/mkosi/customize/apt-ceralive-repo.sh),
which bakes the same three values (as build-time inputs) into the image's own
apt source for its own package installs.

This is a **distinct** rotation from the RAUC signing PKI in
[`v2/docs/cert-rotation-policy.md`](../v2/docs/cert-rotation-policy.md) — that
doc governs the leaf/intermediate/root chain that signs `.raucb` bundles; this
section governs the mTLS + GPG credential that authenticates a **build host**
to the `apt.ceralive.tv` package feed. Don't conflate the two.

### Where they live today

`v2-ci.yml`'s build-matrix job runs `DRY_RUN=1` specifically so it never needs
these values (its own header comment says so: "No secrets are referenced"). The
protected `release.yml` candidate job injects them from GitHub Actions secrets
for release pushes/tags, while `realhw-job.yml` uses repo **variables** for the
board address/port, stable UART path, approved Maskrom USB identity hash, and absolute
path to the mode-`0600` host-local UART signing key. The hardware verifier rejects
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
   APT_GPG_PUBLIC_B64="$(base64 -w0 < new-ceralive-archive-keyring.gpg)"
   APT_CLIENT_CRT_B64="$(base64 -w0 < new-client.crt)"
   APT_CLIENT_KEY_B64="$(base64 -w0 < new-client.key)"
   ```
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
   ./v2/lib/fetch-debs.sh --family v2/manifests/families/<family>.yaml
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

### The A/B fallback contract (automatic, on-device, no operator action needed)

RAUC's A/B slot model provides bounded automatic rollback for a bad update when
the factory image passed the A/B preflash gate and the board-specific hardware
cycle has passed. The software contract is exercised by
[`v2/tests/rauc-rollback.sh`](../v2/tests/rauc-rollback.sh) (run live on real
hardware as part of the §3 realhw gate, and in a MOCK mode that drives the same
shipped scripts without hardware):

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
   `v2/mkosi/platform/x86/README.md` §2 for the x86 mirror of this contract)
   **automatically falls back** to the last-known-good slot. The device
   resumes streaming on the old, still-good software with **zero operator
   intervention**.
5. The `OTA-during-stream guard` (`ceralive-update`, see root `AGENTS.md` /
   this repo's `AGENTS.md` KEY FACTS) additionally refuses to even **start**
   installing an update while `cerastream.service` / `srtla.service` /
   `srtla-send.service` is active — a bad bundle pushed during a live
   broadcast doesn't get a chance to interrupt it in the first place.

The A/B contract covers the **ModemManager 1.24 closure** the same way it covers
every other baked package: the nine fork `.deb`s (`modemmanager` +
`libmm-glib0`/`libqmi-*`/`libmbim-*`/`libqrtr-glib0`, all `~ceralive0.2.0`) are
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
v2/tests/qemu-x86.sh --fallback-selftest
```

([`v2/tests/qemu-x86.sh`](../v2/tests/qemu-x86.sh) `run_fallback_selftest()`.)
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

This is the harness cited in this repo's own `AGENTS.md` `WHERE TO LOOK` table
as the "forced-primary-failure rollback proof" — treat a passing run of it as
the evidence that the x86 boot-state engine itself has not regressed, the same
way `rauc-rollback.sh`'s MOCK mode is the evidence for the RK3588 engine. Both
are proof of the **engine**, not a substitute for the real-hardware run in §3
(the RK3588 realhw gate is the only accepted proof for that board — "no
qemu/mock result is accepted as the RK3588 rollback proof" per the harness's
own MOCK-mode warning banner).

### Pausing or superseding a published bundle on R2

Immutable bundle objects and their digest sidecars are never deleted or
overwritten. If a published bundle is found to be bad:

1. **Pause the hawkBit rollout** so no further devices are offered the bad
   distribution set:
   ```bash
   curl -u "$HAWKBIT_ADMIN_USER:<pass>" \
     -X POST "http://127.0.0.1:8080/rest/v1/rollouts/<rollout-id>/pauseGroup"
   ```
   (or the equivalent `platform-bridge.sh` call once that verb is exposed; see
   `v2/fleet/integration-contract.md` for the rollout-control surface).
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

- It is the **sole** gate on `rauc mark-good` — nothing else confirms a slot.
- It is deliberately **non-fatal** for cosmetic/secondary probes (e.g. the mDNS
  probe, or the HTTPS `:443` check on a device whose uplink is briefly down
  during provisioning) — see this repo's `AGENTS.md` "CeraUI TLS front" section.
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

---

## See also

- [`docs/DEVICE-BRINGUP.md`](DEVICE-BRINGUP.md) — the developer build/flash/dev-loop guide this doc's §4 and §6 summarize.
- [`v2/docs/cert-rotation-policy.md`](../v2/docs/cert-rotation-policy.md) — RAUC signing-PKI rotation (leaf/intermediate/root) — a distinct procedure from §7.
- [`docs/paseto-key-provisioning.md`](paseto-key-provisioning.md) — the sibling runbook style this doc follows for a different credential (device-token PASETO keys).
- [`v2/fleet/hawkbit/README.md`](../v2/fleet/hawkbit/README.md) + [`v2/fleet/integration-contract.md`](../v2/fleet/integration-contract.md) — the fleet rollout engine referenced in §5 and §8.
- [`v2/docs/DEFERRED.md`](../v2/docs/DEFERRED.md) — index of every other deferred/hardware-gated item in this pipeline.
