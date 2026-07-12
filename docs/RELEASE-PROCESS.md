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
release.yml  ──workflow_call──▶  realhw-job.yml
        │                              │
        │                              ▼
        │                    realhw-suite.sh on a REAL RK3588
        │                    (boot/service, encode-path init,
        │                     dev-loop sanity, RAUC A/B rollback)
        │
        ▼  (once the gate is green)
./v2/build <board>  →  orchestrate.sh  →  build-bundle.sh
        │                                       │
        │                                       ▼
        │                            signs the leaf-key .raucb,
        │                            verifies leaf→intermediate→root
        │
        ▼
images/<board>/<ts>.raucb (+ .sha256)      ◀── MANUAL step from here down
        │
        ▼
operator uploads to R2  bundles/{channel}/{board}/<ts>.raucb
        │
        ▼
operator registers the artifact + rolls out via hawkBit
(v2/fleet/hawkbit/provision.sh, platform-bridge.sh)
        │
        ▼
device rauc-hawkbit-updater pulls from apt.ceralive.tv/bundles/...
        │
        ▼
verification: preflash-verify.sh (pre-flash) + on-device
rauc status / ceralive-healthcheck (post-install)
```

The realhw gate runs **before** a human trusts the build enough to sign and
ship it. Everything from "operator uploads to R2" onward is a manual,
operator-driven step today — there is no committed workflow that does it for
OS bundles. Section 5 spells out exactly why and exactly what to type.

---

## 2. Trigger

[`release.yml`](../.github/workflows/release.yml) fires on:

- a push to `release/**` or `release-*`
- a `v*` tag (e.g. `v2026.7.0`)

It builds and seals one production candidate, then calls
[`realhw-job.yml`](../.github/workflows/realhw-job.yml) with the immutable
artifact identity. `concurrency.cancel-in-progress: false` prevents a newer
release push from cancelling a build or flash in progress.

There is no version-bump automation in this repo. The tag itself is the release
marker; CeraLive's CalVer convention (`YYYY.MINOR.PATCH`, documented as the
cross-repo source of truth in `CeraUI/docs/APT_VERSION_CONTROL.md`) governs what
string goes in the tag and in `BUNDLE_VERSION` (§4).

---

## 3. Real-HW gate

`release.yml` first builds and uploads one immutable production candidate, then
calls `realhw-job.yml` on the **self-hosted runner physically wired to an RK3588
board** (`[self-hosted, ceralive-rk3588]`). The artifact name, artifact digest,
raw filename, raw SHA-256, bundle, keyring, and candidate commit are all required
workflow inputs.

Steps, in order:

1. **Candidate verification** — verify the exact raw SHA-256, production bundle,
   embedded slot keyrings, boot artifacts, GPT geometry, and target capacity.
2. **Required flash and identity proof** — write that raw file through RK3588
   maskrom with `rkdeveloptool`, reboot,
   fail on reconnect exhaustion, and compare the flashed media bytes to the
   expected digest.
3. **The gate itself** — [`v2/tests/realhw-suite.sh`](../v2/tests/realhw-suite.sh),
   which runs four sub-harnesses in sequence and aggregates one exit code:
   - **boot+service** (`v2/tests/realhw-smoke.sh`) — boot, service, binary,
     quirk checks, and parity against the manifest.
   - **encode-path init** — `cerastream --version` / `srtla_send --version`
     actually run on the board.
   - **dev-loop sanity** — `v2/dev-push` completes in under 120s (optional,
     needs `DEV_DEB_DIR`).
   - **RAUC A/B rollback** ([`v2/tests/rauc-rollback.sh`](../v2/tests/rauc-rollback.sh))
     — the same rollback proof described in §8, run live against real
     silicon rather than the mock harness.
4. **Evidence upload** — always uploads the candidate identity, artifact digest,
   and suite logs with a 14-day retention.

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

Fetching the five first-party `.deb`s (`libsrt1.5-ceralive`, `cerastream`,
`gstreamer1.0-libuvch264src`, `ceralive-device`, `srtla-send-rs`) from `apt.ceralive.tv` needs a GPG-verified,
mTLS-authenticated apt source — the exact credential contract is
`APT_GPG_PUBLIC_B64` / `APT_CLIENT_CRT_B64` / `APT_CLIENT_KEY_B64` in
[`v2/lib/fetch-debs.sh`](../v2/lib/fetch-debs.sh) `fetch_first_party()`
(lines ~518-637). **Section 7 below is the full rotation runbook for these
three values** — read it before running an authenticated release build.

### Signing (`build-bundle.sh`)

The orchestrator's stage 8 calls [`v2/lib/build-bundle.sh`](../v2/lib/build-bundle.sh)
to produce `images/<board>/<ts>.raucb` (+ `.sha256`), stamped with the
board-specific `COMPATIBLE_STRING` (`ceralive-<board-id>`) and a
`BUNDLE_VERSION` (git short SHA by default). The signing contract:

- **Leaf key only, never root.** The bundle is signed with the injected release
  `leaf-signing.key` + `chain.pem` (intermediate + leaf).
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

**There is no script or CI job in this repo that uploads a signed OS `.raucb`
to R2.** This is a real gap, not an oversight in this doc. Compare the three
artifact families this pipeline produces:

| Artifact | R2 path | Publisher |
|----------|---------|-----------|
| Feature-sysext add-ons | `addons/{os_version}/{board}/{feature}.raw` | [`v2/lib/upload-addons.sh`](../v2/lib/upload-addons.sh) — **exists, automatable, CI-proven under `DRY_RUN`** (`v2-ci.yml` `addon-publish` job) |
| CeraUI federation UI bundles | `ui-bundle/{ceraui-version}/*.js` | CeraUI's own `publish-release.yml` → `publish-federation` job — **exists in the CeraUI repo** |
| **OS `.raucb` OTA bundles** | `bundles/{channel}/{board}/*.raucb` | **none — no script, no workflow** |

`apt-worker/AGENTS.md` and `apt-worker/README.md` both describe the `bundles/`
path as a pure read side (the worker range-serves whatever is already in R2)
and explicitly credit the add-on and federation paths to their respective
publisher scripts — they say nothing publishes `bundles/`, because nothing
does yet.

### Operator steps (today, until this is automated)

Until an `upload-bundle.sh` (or equivalent CI job) exists, publish a release
bundle by hand, following the exact pattern `upload-addons.sh` already
proves out for add-ons — same tool (`aws s3 cp` against the R2 S3-compatible
endpoint), same trust-gate-first discipline, same per-file content-type
pinning:

```bash
# from the build host, after build-bundle.sh has produced + verified the bundle
board=rock-5b-plus
channel=stable
bundle_dir="v2/images/${board}"
bundle="$(ls -t "${bundle_dir}"/*.raucb | head -1)"
sha="${bundle}.sha256"

# sanity: never upload a bundle whose sha256 didn't verify in §4
sha256sum -c "${sha}"

aws s3 cp "${bundle}" \
  "s3://${R2_BUCKET}/bundles/${channel}/${board}/$(basename "${bundle}")" \
  --endpoint-url "${R2_ENDPOINT}" \
  --content-type application/vnd.rauc.bundle

aws s3 cp "${sha}" \
  "s3://${R2_BUCKET}/bundles/${channel}/${board}/$(basename "${sha}")" \
  --endpoint-url "${R2_ENDPOINT}" \
  --content-type 'text/plain; charset=utf-8'
```

`R2_BUCKET` / `R2_ENDPOINT` are the same two variables `upload-addons.sh` and
`fetch-debs.sh`'s BSP path already use for R2 access — no new credential shape
to provision.

**Future work.** The natural next step is a `v2/lib/upload-bundle.sh` that
mirrors `upload-addons.sh` line for line (require a `.sha256` sidecar present,
refuse to upload without it, `DRY_RUN` plan mode, pinned content-type), plus a
release-triggered CI job analogous to `v2-ci.yml`'s `addon-publish` — gated the
same way (real credentials only on a protected branch/tag, `DRY_RUN=1`
everywhere else). Track this as an open item; it is **not** implemented by this
doc, only described.

### Registering the artifact with hawkBit (also manual/operator-driven)

Once the bundle is on R2, the private hawkBit fleet-update engine
([`v2/fleet/hawkbit/`](../v2/fleet/hawkbit/)) needs to know about it before any
device is offered the update:

```bash
cd v2/fleet/hawkbit
set -a; source .env; set +a
EXAMPLE_BUNDLE_FILE="$(basename "${bundle}")" ./provision.sh
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
the expected nine-green-check output.

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

**Honestly: no committed GitHub Actions workflow in this repo currently
injects these three secrets.** `v2-ci.yml`'s build-matrix job runs
`DRY_RUN=1` specifically so it never needs them (its own header comment says
so: "No secrets are referenced"). `release.yml` / `realhw-job.yml` gate
hardware validation on an already-built image and use repo **variables**
(`vars.CERALIVE_RK3588_*`) for board connectivity, not these secrets.

The real (authenticated) build is run today by whoever executes
`./v2/build <board>` with these three values exported in their own shell —
locally, or from a private/未-committed CI job outside this repo's tracked
workflows. **Recommendation, not current fact:** when a real build/sign/upload
CI job is added (see §5's "future work"), these three values should be stored
as **GitHub Actions encrypted repository secrets** (`Settings → Secrets and
variables → Actions → Repository secrets`), scoped to an environment
(`production`) with required reviewers, exactly the way `fetch-debs.sh`
already expects to consume them (env-only, base64-encoded, never written to
disk outside the isolated per-run apt state dir).

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

### Pulling or superseding a published bundle on R2

Because R2 delivery for `bundles/{channel}/{board}/` has no publisher
automation yet (§5), removing a bad bundle is also a manual step. Two options,
in order of preference:

1. **Supersede, don't delete (preferred).** Build a fixed bundle, sign it
   (§4), upload it under a **new** timestamped filename (§5's manual steps),
   and register it with hawkBit as a new artifact/distribution set
   (`provision.sh`). Devices that already pulled the bad bundle self-heal via
   the fallback contract above regardless; devices that haven't updated yet
   get offered the fixed one instead. This avoids ever deleting an artifact a
   device might still be mid-download of.
2. **Remove the bad object from R2 (only if it must not be fetched again).**
   ```bash
   aws s3 rm "s3://${R2_BUCKET}/bundles/${channel}/${board}/<bad-ts>.raucb" \
     --endpoint-url "${R2_ENDPOINT}"
   aws s3 rm "s3://${R2_BUCKET}/bundles/${channel}/${board}/<bad-ts>.raucb.sha256" \
     --endpoint-url "${R2_ENDPOINT}"
   ```
   `apt-worker` returns a true 404 for a missing object (never a 200-empty),
   so any device that hasn't already downloaded the bundle simply can't fetch
   it anymore. A device mid-download when the object disappears fails its
   transfer and retries against whatever hawkBit currently offers — it does
   **not** brick, per the same A/B contract above.
3. **Stop/pause the hawkBit rollout** so no further devices are even offered
   the bad distribution set, independent of whether the R2 object itself is
   pulled:
   ```bash
   curl -u "$HAWKBIT_ADMIN_USER:<pass>" \
     -X POST "http://127.0.0.1:8080/rest/v1/rollouts/<rollout-id>/pauseGroup"
   ```
   (or the equivalent `platform-bridge.sh` call, once that verb is exposed —
   see `v2/fleet/integration-contract.md` for the full rollout-control
   surface). Pausing is instantaneous and reversible; it's the fastest lever
   to pull while deciding between options 1 and 2.

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
