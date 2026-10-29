# Kernel-only release runbook [PARTIAL]

A kernel change can reach a device without a full OS release. This page is the
owner's path from a bumped `kernel_source.package_version` to a kernel a capable
device can install, plus how to read the result when it succeeds or rolls back.

**What exists today.** The kernel-only build lane and its gates are [EXISTS]:
`./build <family> --kernel-only` compiles one family kernel and validates it
for every board in that family. The local release command
`ci/kernel-release.py` is [EXISTS] up to one immutable candidate bundle per
version. The approved workflow adapter and ephemeral VM scripts are [EXISTS].
APT publication is [PARTIAL]: GitHub settings, runner registration, approval and
the first publication are owner actions, not performed by implementation/tests.
The two-board bench drill has not been run, and no bench report exists.

| Part | State | Contract |
|---|---|---|
| Family compile, boot/DTB/firmware gates | EXISTS | [`kernel-build-from-source.md`](kernel-build-from-source.md#kernel-only-build-lane-exists) |
| Immutable per-version candidate | EXISTS | this page |
| APT publication of a candidate | PARTIAL, owner-gated | this page, "Publish" |
| Device staging into the inactive slot | EXISTS as a host contract; capability off | [`kernel-staging.md`](kernel-staging.md) |
| Two-board bench drill | not run | [`ota-activation.md`](ota-activation.md#local-kernel-activation-and-recovery-partial) |

Kernel compilation runs only inside a dedicated KVM guest on the owner's
workstation, never on GitHub-hosted runners or a remote machine. Cheap lint
can run on GitHub-hosted compute; the full tests, candidate and publication
jobs use the `kernel-release` runner group and `ceralive-kernel-vm` label.

The offline release contracts clear inherited `GITHUB_*` and `RUNNER_*`
variables before defining their scenarios. Workflow-adapter scenarios then set
their exact dispatch context explicitly; local publication-refusal scenarios
remain local even when the suite runs inside `kernel-release.yml`. The command
contract also corrupts and unsets each guarded dispatch variable independently,
with one approved-context control proving the guard admits the full context.
`bash tests/kernel-release-environment.test.sh` checks the command contract's
exit status and exact pass/fail totals in both parent environments.

## 0. Owner setup and runner lifecycle [MANUAL]

Set these GitHub controls before registering any runner:

- Organization runner group `kernel-release`: repository access **Selected
  repositories**, only `CERALIVE/image-building-pipeline`; enable **Allow public
  repositories**. Workflow access **Selected workflows**, only
  `CERALIVE/image-building-pipeline/.github/workflows/kernel-release.yml@refs/heads/master`.
  Keep it out of the default groups (currently IDs 1 and 5); use the new group's
  numeric ID with `--group-id`.
- Repository environment `kernel-release`: required reviewer `andrescera`;
  prevent administrator bypass. Use **Selected branches and tags**, add branch
  `master` as a branch rule and `kernel/v*` as a separate tag rule.
  The workflow nevertheless admits VM jobs only for dispatches on master.
  Leave **Prevent self-review** off so the named
  release owner can initiate and approve each run; turning it on requires a
  second authorized reviewer and a changed release procedure.
- Organization secret `CERALIVE_DISPATCH_TOKEN`: retain selected-repository
  visibility and add `image-building-pipeline`. Its token needs Contents:
  read/write on `apt-worker` for repository dispatch, and Contents: read plus
  Actions: read on `image-building-pipeline` for the publisher's independent
  provenance/artifact checks. Preserve its existing consumers.
- Environment secrets `KERNEL_FLOOR_R2_ACCESS_KEY_ID` and
  `KERNEL_FLOOR_R2_SECRET_ACCESS_KEY`: a separate **read-only**, bucket-scoped
  `ceralive-images` credential for complete OS publication inventory, never
  the image publisher's write key. `R2_IMAGES_ENDPOINT` is that bucket's S3 API
  endpoint. Environment variable `OTA_MANIFEST_ROOT_CA_B64` is the base64
  **public** OTA manifest verification root. No signing key is needed.
- Repository Actions settings: **Require approval for all outside
  collaborators** for fork pull requests. Do not allow PR workflows access to
  this runner group. A label by itself is not an access control.

The scripts require user-accessible `/dev/kvm`, QEMU, `qemu-img`, `xorriso`,
Python/PyYAML, curl and authenticated `gh` on the host. A group-scoped JIT
request needs organization self-hosted-runners write permission, held only by
the host's `gh` session. No script runs host sudo. If `/dev/kvm` is inaccessible,
an administrator must grant the owner KVM access outside this procedure.

Build the base once, then boot a **new overlay for every job**:

```bash
: "${KERNEL_HEAVY_LOCK:?Set the workstation shared heavy-suite.lock path}"
flock --exclusive --close "$KERNEL_HEAVY_LOCK" \
  python3 ci/kernel-runner/vm.py build-base --base mkosi/cache/kernel-runner/base.qcow2
flock --exclusive --close "$KERNEL_HEAVY_LOCK" \
  python3 ci/kernel-runner/vm.py run --base mkosi/cache/kernel-runner/base.qcow2 \
    --group-id "${KERNEL_RUNNER_GROUP_ID:?Set the dedicated group numeric ID}"
```

Run these commands under the workstation's shared exclusive heavy-suite lock.
The base uses SHA-verified Ubuntu noble/20261017 and runner 2.338.2; cloud-init
installs Docker and CI/build dependencies, disables SSH and console logins,
then powers off. Job output uses journal+console, not a shared login terminal.
The host alone requests a single-use JIT configuration. It reaches the guest
through an anonymous RAM fd/QEMU firmware configuration; no registration
credential is written to a host file or printed. The guest starts `run.sh
--jitconfig`, handles one job, then powers off. The overlay is deleted on
success, guest/registration failure, timeout, SIGTERM or Ctrl-C. Job disks are
unlinked temporary-file descriptors, so SIGKILL cannot leave an overlay path.
**The guest admits the job itself.** A single-use JIT config still executes
whatever job context GitHub delivers, so the runner is started with
`ACTIONS_RUNNER_HOOK_JOB_STARTED=/usr/local/lib/ceralive-kernel-runner/admit-job.sh`
(root-owned 0755, installed by the base, not writable by the runner user). That
hook exits non-zero unless `GITHUB_ACTIONS=true`, `GITHUB_REPOSITORY` is
`CERALIVE/image-building-pipeline`, `GITHUB_EVENT_NAME` is `workflow_dispatch`,
`GITHUB_REF` is `refs/heads/master`, `GITHUB_WORKFLOW_REF` is
`CERALIVE/image-building-pipeline/.github/workflows/kernel-release.yml@refs/heads/master`
and `GITHUB_RUN_ATTEMPT` is `1`, and it fails closed on any missing value. It is
independent of `ci/kernel-release.py`'s `--publish` guard: that one gates
publication, this one gates execution on the workstation. `guest-job.sh` refuses
to start the runner when the hook is absent or writable by the runner user;
the `check --check-script` path runs no runner and is unaffected.
Linux parent-death signals kill QEMU when Python dies and kill Python when its
flock parent dies. Stop by sending
SIGTERM to the `vm.py run` process; never reuse its overlay. Start again with
the same command for the next job.
Wait for that process to exit before another launch. Keep the direct flock to
Python chain above; do not insert a host `timeout` process group or cancel only
an outer shell. Guest and transport deadlines are enforced inside `vm.py`.
The launcher refuses execution without that direct exclusive/close flock parent.

There are no host directory mounts, Docker socket forwarding, SSH agent
forwarding or host secrets in the guest. QEMU uses user-mode outbound networking,
which is not a network firewall: guest egress can reach host/LAN services, so do
not expose credential services there. Workflow credentials are short-lived
Actions tokens plus the explicitly configured job secrets, not copied host
credentials. JIT logs stay inside the disposable guest. `check --check-script
FILE` replaces the runner with a local stand-in and never contacts GitHub;
`--source-bundle FILE` attaches only a public-source tar capsule as a read-only
block device. It is not a host directory share; credentials still use RAM only.

**CI policy note:** this dedicated VM lane uses `actions/cache` for the
kernel-builder Docker archive/dependency caches instead of `type=gha`, since
the existing kernel engine uses `docker build`, not a Buildx exporter. Record
this targeted cache deviation in the root CI standard when integrating policy;
do not change the compiler/producer to satisfy a cache convention.

## 1. Bump the kernel version

The first kernel-only publication advances exactly one Debian revision in
`manifests/families/rk3588.yaml`, now prepared as:

```yaml
kernel_source:
  package_version: 7.2.0-ceralive2
```

Revision 1 (`7.2.0-ceralive1`) identifies the existing image kernel and captured
firmware fixture. Revision 2 is the source pin for the first kernel-only
publication, not a publication receipt. Never reissue an existing revision with
different bytes. A new
upstream base changes `kernel_release`, and with it the package name
(`linux-image-<release>-ceralive-rk3588`).

## 2. Create the local candidate

For standalone diagnostics, run this inside an unregistered workstation VM,
from a clean, non-shallow checkout with complete local tags. For publication,
use the approved dispatch sequence in section 5:

```bash
python3 ci/kernel-release.py rk3588 \
  --candidate-run-id 12345 --channel beta \
  --os-releases mkosi/cache/reviewed-os-kernel-sidecars
```

| Argument | Meaning |
|---|---|
| `family` (positional) | Family to build, for example `rk3588`. |
| `--candidate-run-id N` | Required positive decimal local candidate ID. It is not, and does not claim to be, an Actions run. |
| `--channel beta\|stable` | Channel recorded in the authorization inputs. Default `beta`. |
| `--os-releases DIR` | Required authenticated snapshot of published OS kernel sidecars across boards and channels, used for the floor. An empty directory claims no OS kernel publication. |
| `--output-dir DIR` | Optional repo-local bundle store. Default `mkosi/build/kernel-releases`. |
| `--bench-report FILE` | Optional report bound to this candidate; see step 4. |
| `--publish` | Refuses outside the exact approved workflow context; see step 5. |

The command refuses, before any build, when `DRY_RUN` has any value other than
`0`, the repository is shallow or dirty, an existing `kernel/v<version>` tag does
not point at HEAD, a bundle for that version already exists (even with identical
bytes), or the store is outside the repository. It reads tags and never creates
or moves one.

`--published` and `--floor` read published kernel versions and their metadata
through `gh`. Set `CERALIVE_KERNEL_HISTORY_DIR` to a local directory of
`<version>/` metadata directories to read them from disk instead.

## 3. Gates, in the order the command runs them

1. `ci/check-release-variant.sh --variant default`: the production variant, never a debug sibling.
2. `ci/check-kernel-version-monotonic.py --candidate`: the version is at least the newest local `kernel/v*` tag (published versions join that set when `CERALIVE_KERNEL_HISTORY_DIR` is set), and a lower one is refused. An equal version is admitted only when its identity is unchanged: an equal version that is already published must keep its released family fingerprint against the current inputs, and an equal tag with no Release admits its first publication.
3. `--published`: the version exceeds every published kernel.
4. `--floor --os-releases DIR`: the candidate is not below the highest published kernel or OS kernel sidecar version (`os_kernel_below_floor`).
5. `./build <family> --kernel-only`: compile, then validate every board of the family (4-axis package checks, config survival, DTB and boot-artifact staging, pinned Bluetooth/UHID firmware closure).
6. Post-build admission on the snapshot: strict metadata parse, exactly one production archive, `sha256sum --check`, all-family `validated_boards`, recomputed family fingerprint, then `--candidate --artifact`, `--published` and `--floor` again, and an unchanged source HEAD and status.

The bundle lands in `mkosi/build/kernel-releases/<version>/` and holds:

- The five builder outputs: the arm64 `.deb`, `kernel-artifact.json`, `resolved.config`, `built-modules.txt` and the original `SHA256SUMS`.
- `candidate.json`: family, commit, candidate ID, observed floor and `publication: "blocked-pending-owner"`.
- `publish-authorization.inputs.json`: apt-worker's eleven authorization field names. `publish_run_id` and `run_attempt` are `null`, and `bench_report_sha256` is `null` unless a report was supplied. This is an input record, not an authorization.
- `BUNDLE.SHA256SUMS`: digests of every file above.

Files are made read-only and the version directory is installed create-only,
so an existing version is never reused or replaced. Manual writes into the
store are outside that guarantee.

## 4. Bench report, before any future publication

A kernel-lane report comes from the two-board drill on `rock-5b-plus` and
`orange-pi-5-plus`: happy install, forced rollback and restore, each with
evidence, bound to this candidate's ID, `kernel/v<version>` tag, commit and
`.deb` SHA-256. Validate it with:

```bash
python3 ci/validate-kernel-bench-report.py REPORT \
  CANDIDATE_RUN_ID kernel/v7.2.0-ceralive2 COMMIT DEB_SHA256 7.2.0-ceralive2
```

The schema is `ci/kernel-bench-report.schema.json`. A `kernel-lane` report needs
both boards with `happy`, `forced_rollback` and `restored` all `pass`; a
`bootstrap` report carries `approving_owner` and the statement
`No kernel-apt-stage image is published.`, and its eligibility is apt-worker's
decision, not this command's. Pass the file as `--bench-report` during candidate
creation: the command keeps the raw bytes and binds their hash. A report cannot
be attached later by rerunning the immutable command.

**No drill has been run for any version.** These are the steps a report must
satisfy, not a receipt.

## 5. Owner release sequence [MANUAL]

1. Merge the reviewed release source on `master`, with revision 2 for the first
   publication. Create `kernel/v<version>` at that exact commit. Do not advance
   `master` during this three-run release sequence. The tag push runs lint only:
   the group deliberately permits workflow code only from `master`, not tags.
2. Dispatch `kernel-release.yml` **on master**, `mode=candidate`, channel
   `beta`, and `tag=kernel/v<version>`. The explicit tag must match the manifest
   and this exact master commit. Approve the `kernel-release` environment and start one fresh VM for
   `tests`, then another for `candidate`. The workflow runs the four real
   contracts, authenticates the complete OS kernel floor and calls the existing
   candidate engine. Retain the successful run ID and five-file immutable
   `kernel-candidate-<commit>` artifact.
3. Dispatch `mode=release`, the same tag/candidate run ID/channel and exact master
   commit. Approve it and provide fresh VMs for tests and publish. Under the
   shared non-cancelling `ceralive-kernel-floor` job group it checks GitHub
   provenance, tag/manifest/commit, checksums, `--published` and `--floor`, then
   creates the identity Release. This mode needs no bench report and never
   dispatches APT.
4. Attach `bench-<version>.json` to that existing Release. For the first kernel
   use the owner-reviewed bootstrap statement; only apt-worker's inventory
   decides bootstrap eligibility. Later versions need both boards' passing
   happy/forced-rollback/restore observations. Never invent a passing report.
5. Dispatch `mode=apt-publish` with the same successful candidate ID, exact
   master/tag commit, explicit tag input and chosen channel. Approve and provide new VMs for tests
   and publish. The adapter compares all five released files to the candidate,
   validates the raw bench bytes, uploads `publish-authorization` **before**
   dispatch and reads that immutable artifact back before sending `apt-reindex`.
   apt-worker independently checks the approved workflow and authorization,
   signs the APT indexes and verifies served bytes. It stays the sole publisher.
   For bootstrap, choose the channel the capable OS consumes (normally stable);
   an APT retry must replay the original authorization, not manufacture a new
   bootstrap authorization or use it as a cross-channel promotion.
6. Confirm apt-worker's successful served-verification receipt before building
   a capable OS release. Images fetch the released kernel only from authenticated
   APT, never the Release's `.deb`; a production miss refuses `kernel_not_on_apt`.

Candidate provenance is a successful first-attempt **workflow_dispatch** on
master, rather than the original tag-push build: a tag workflow cannot satisfy
the owner's master-only runner-group restriction. The additional `candidate`
mode separates completed build provenance from later approval/publication.
Every operation still requires master HEAD == the kernel tag commit. A rerun
is refused; a new explicitly approved dispatch is a new authorization, not an
immutable candidate overwrite.

`ci/publish-release.sh kernel-floor --kernel-version V --os-releases DIR` is
read-only: it reuses the image publisher's complete R2 marker inventory, CMS
verification and existing version comparator. It never receives a signing key.
Kernel and OS publication share the floor exclusion. No APT eligibility check
is duplicated upstream. Direct `ci/kernel-release.py --publish` still refuses
before imports/output when the exact workflow context is absent.

## 6. Reading the outcome on a device

A device that declares the `kernel-apt-stage` capability stages a kernel only
into the inactive slot. The capability is off until the owner releases a CeraUI
with the kernel lane and raises the minimum. The records live in
`/data/ceralive/update-state/`:

| File | What it holds |
|---|---|
| `kernel-state.json` | `state` is one of `staging`, `staged`, `armed`, `activating`, `activated`, `succeeded`, `rolled_back`, `failed`, with `attempt`, `package`, `version`, `deb_sha256`, slot fields, a nullable reason and per-state `timestamps`. |
| `kernel-quarantine.json` | Identities `{package, version, deb_sha256}` that failed to boot. |
| `slot-overlay-A.json` / `slot-overlay-B.json` | The RAUC base identity, the kernel overlay and `status`: `invalid`, `pending` or `confirmed`. |

`succeeded` means the healthcheck booted the target, matched `uname -r` and the
installed package version, and marked the slot good. `rolled_back` means the
selector gave up and the previous slot booted; the failed version is quarantined
and later updates are not blocked. An armed activation with a missing or
inconsistent overlay is refused, never downgraded to the retained bundle
timestamp. Slot-sync refuses `kernel_staged_pending` while a transaction is
pending, and a verified mirror repairs the target slot afterwards. The full
sequencing is in [`ota-activation.md`](ota-activation.md) and
[`kernel-staging.md`](kernel-staging.md).

## 7. Tests

PR CI runs offline tests for this lane, through `tests/registry.tsv` and
`./run-tests`. `tests/kernel-release-command.test.sh` drives the real command
with stubbed build and transport boundaries, and `tests/kernel-bench-report.test.sh`
drives the validator. Fixture success is not a kernel build, a board drill or a
publication. `tests/kernel-release-workflow.test.sh` drives the workflow
adapter with stubbed GitHub transport; `tests/kernel-runner.test.sh` checks
anonymous JIT handoff, QEMU arguments and cleanup with stubbed QEMU/gh.

## See also

- [`kernel-build-from-source.md`](kernel-build-from-source.md): the pins, the kernel-only lane, released-artifact reuse and known gaps.
- [`RELEASE-PROCESS.md`](RELEASE-PROCESS.md#local-kernel-candidates-partial): the same command's inputs, store and refusal, next to OS image publishing.
- [`kernel-tracks.md`](kernel-tracks.md): the pin chain, including `package_version`.
- [`kernel-staging.md`](kernel-staging.md) and [`ota-activation.md`](ota-activation.md): the device transaction and its recovery.
