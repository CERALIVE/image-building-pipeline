# Kernel-only release runbook [PARTIAL]

A kernel change can reach a device without a full OS release. This page is the
owner's path from a bumped `kernel_source.package_version` to a kernel a capable
device can install, plus how to read the result when it succeeds or rolls back.

**What exists today.** The kernel-only build lane and its gates are [EXISTS]:
`./build <family> --kernel-only` compiles one family kernel and validates it
for every board in that family. The local release command
`ci/kernel-release.py` is [EXISTS] up to one immutable candidate bundle per
version. APT publication is [PARTIAL]: `--publish` refuses, so no kernel `.deb`
from this lane is on `apt.ceralive.tv`. The two-board bench drill has not been
run, and no bench report exists.

| Part | State | Contract |
|---|---|---|
| Family compile, boot/DTB/firmware gates | EXISTS | [`kernel-build-from-source.md`](kernel-build-from-source.md#kernel-only-build-lane-exists) |
| Immutable per-version candidate | EXISTS | this page |
| APT publication of a candidate | PARTIAL, owner-gated | this page, "Publish" |
| Device staging into the inactive slot | EXISTS as a host contract; capability off | [`kernel-staging.md`](kernel-staging.md) |
| Two-board bench drill | not run | [`ota-activation.md`](ota-activation.md#local-kernel-activation-and-recovery-partial) |

Kernels and images are built locally on the owner's workstation. Nothing here
runs on a GitHub runner, and no workflow builds or publishes a kernel.

## 1. Bump the kernel version

Bump exactly one Debian revision in `manifests/families/rk3588.yaml`:

```yaml
kernel_source:
  package_version: 7.2.0-ceralive2
```

Revision 1 (`7.2.0-ceralive1`) is the production pin. Keep it until you make
this change, and never reissue an existing revision with different bytes. A new
upstream base changes `kernel_release`, and with it the package name
(`linux-image-<release>-ceralive-rk3588`).

## 2. Create the local candidate

Run from a clean, non-shallow checkout of the release commit, with complete
local tags:

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
| `--publish` | Always refuses; see step 5. |

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

## 5. Publish: refused today

```bash
python3 ci/kernel-release.py --publish
```

This exits nonzero before reading repository code or creating any file:

```text
kernel release: publication blocked pending owner decision: apt-worker requires a kernel-release.yml workflow_dispatch run approved in the kernel-release environment; choose a self-hosted kernel-release.yml on this PC or an apt-worker contract change
```

apt-worker's merged publisher admits a kernel only from a `kernel-release.yml`
`workflow_dispatch` run whose commit matches the kernel tag and whose
`kernel-release` environment deployment is approved. A local command cannot
produce that. Two owner choices would close the gap, and neither is implemented:

1. A self-hosted `kernel-release.yml` on the owner's workstation, run on this PC,
   whose dispatch and approval satisfy the existing publisher checks.
2. An apt-worker contract change that accepts a local owner authorization bound
   to the candidate bytes.

Until one lands, this lane creates no GitHub Release, dispatches nothing, signs
no index and needs no token or environment. No image can fetch this candidate
from APT: production and `--release` image builds refuse `kernel_not_on_apt`, and
only a local, non-release build of an unpublished higher version still compiles
a kernel.

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

CI runs only offline tests for this lane, through `tests/registry.tsv` and
`./run-tests`. `tests/kernel-release-command.test.sh` drives the real command
with stubbed build and transport boundaries, and `tests/kernel-bench-report.test.sh`
drives the validator. Fixture success is not a kernel build, a board drill or a
publication.

## See also

- [`kernel-build-from-source.md`](kernel-build-from-source.md): the pins, the kernel-only lane, released-artifact reuse and known gaps.
- [`RELEASE-PROCESS.md`](RELEASE-PROCESS.md#local-kernel-candidates-partial): the same command's inputs, store and refusal, next to OS image publishing.
- [`kernel-tracks.md`](kernel-tracks.md): the pin chain, including `package_version`.
- [`kernel-staging.md`](kernel-staging.md) and [`ota-activation.md`](ota-activation.md): the device transaction and its recovery.
