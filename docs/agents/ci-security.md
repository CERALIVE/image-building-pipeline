# CI security contract [PARTIAL: runner settings and live proof pending]

## Fork boundary

Pull request checks use GitHub-hosted `ubuntu-latest`, `ubuntu-24.04` or
`ubuntu-22.04` runners, a read-only token, no secrets and no environments.
They cannot call reusable workflows. No workflow uses `pull_request_target`,
`workflow_run` or `issue_comment`. Checkouts never persist credentials;
third-party actions outside `actions` and `CERALIVE` use full commit SHAs.
The final fork approval policy is first-time contributors. Approval history
does not grant access to a runner.

`tests/workflow-security-contract.test.sh` parses every workflow and rejects
violations, including unresolved runner expressions. `WORKFLOWS_DIR` selects
scratch workflows for negative tests. Runner isolation additionally requires
the owner-confirmed group configuration and live probes below; the contract
test cannot read or enforce GitHub settings.

## Image builder admission

The organization group `image-builder` must have visibility **Selected
repositories**, only `CERALIVE/image-building-pipeline`, **Allow public
repositories** enabled, and workflow access **Selected workflows**, exactly:

- `CERALIVE/image-building-pipeline/.github/workflows/release-candidate-build.yml@refs/heads/master`
- `CERALIVE/image-building-pipeline/.github/workflows/publish-release.yml@refs/heads/master`
- `CERALIVE/image-building-pipeline/.github/workflows/real-build-audit.yml@refs/heads/master`
- `CERALIVE/image-building-pipeline/.github/workflows/runner-admission-probe.yml@refs/heads/master`

Every image job selects `group: image-builder` and
`labels: [self-hosted, ceralive-image-builder]`. `release.yml` keeps its push
triggers, read-only permissions and non-cancelling concurrency group, but calls
the reusable build at `@master` with `secrets: inherit`. The called build has no
concurrency group of its own. Publication still validates `release.yml` as the
triggering workflow path and a push event.

In reusable workflows, `github` describes the caller. The build and probe
therefore check repository and event at job level, before runner assignment;
a pull request calling either at master is skipped, without checking out fork
code on the workstation.

Immediately after its full-history checkout, the candidate compares the build
workflow at `GITHUB_SHA` with `origin/master` using `git diff --quiet`. A
difference fails before the build. Any later change to
`release-candidate-build.yml` on master requires a proven but untagged release
branch to be proven again on a new `release/**` branch before tagging.

## Owner-only jobs and sole-admin rule

Andres (`andrescera`) is the only admin and will never add another admin.
Under that rule the release build has no `image-build` approval environment.
The publish job retains the `release` approval environment.

| Job | Starting event and ref | Actor check | Approval gate |
|---|---|---|---|
| `release-candidate-build.yml` / `candidate` | Push to `release/**` or `v*`, in this repository | `github.triggering_actor == 'andrescera'` | None under sole-admin rule |
| `publish-release.yml` / `publish` | Manual dispatch, master workflow selected by the group | This repository and `github.triggering_actor == 'andrescera'` | `release` |
| `real-build-audit.yml` / `real-build` | Schedule on master, or manual dispatch | This repository; schedule allowed, manual dispatch requires `github.triggering_actor == 'andrescera'` | None |
| `runner-admission-probe.yml` / `probe` | Manual dispatch, or a reusable call from a push to `probe/**` | This repository and `github.triggering_actor == 'andrescera'` | None |
| `kernel-release.yml` / `tests`, `candidate`, `publish` | Manual dispatch on master | Existing environment approval names the owner; no new actor predicate | `kernel-release`, sole reviewer Andres, admin bypass disabled |

`github.triggering_actor` identifies the account starting or re-running the
run. A workflow dispatch started by the built-in workflow token fails the
image-builder actor check. The scheduled audit is the explicit exception.
Kernel jobs use the separate workflow-restricted `kernel-release` group and
throwaway KVM runners; preserve that contract.

Before anyone else receives write access, complete this checklist:

- Never give anyone else the admin role: an admin can change all these controls.
- Re-add an approval environment for the release build, with only Andres as
  reviewer, before granting write access.
- Add a repository-wide CODEOWNERS file naming Andres and require at least one
  approving review plus code-owner review on master. With zero required
  approvals a collaborator could merge a workflow change that the scheduled
  audit then executes on the workstation.

Admission protects the runner user's stored GitHub login (the fallback when
`FIRST_PARTY_RELEASE_READ_TOKEN` is unset), Docker and its host access, the
persistent workspace and caches, and the credentials materialized by admitted
jobs. Checkout credential removal does not sandbox those capabilities.

## Registration and cutover

These are separate owner-confirmed operations, never performed by a PR:
create the organization group, then move the idle repository runner.
Re-register with organization URL `https://github.com/CERALIVE`,
`--runnergroup image-builder`, and `--labels ceralive-image-builder`, retaining
its existing name, work directory and service configuration. Stop the service
before removing the old repository registration. Obtain short-lived removal
and organization registration tokens privately; never log or commit them.
Read back group repository/workflow restrictions and membership, confirm the
organization runner is online/idle and repository-level runner count is zero.
See [runner setup](../../ci/runner-setup.md) for the host/bench distinction.

Merge, group creation and runner move belong in one attended session with no
scheduled audit or release/tag push during the window. Read the audit cron
before the owner confirms that window. The current cron is Monday 03:17 UTC
(`17 3 * * 1`); the next after November 14, 2026 is November 16, 2026 at
03:17 UTC. No runner or setting is changed by these workflow files.

## Admission probes

After the owner confirms each live operation, dispatch the no-checkout,
no-secret probe on master: its sole step prints `admitted`. For negative proof,
use a temporary `probe/**` push workflow that requests the same group directly;
its workflow path is outside the group's selected workflows and must remain
unassigned. A separate probe caller may call the reusable probe at master to
prove the allowed path. A pull request workflow that calls the build or the
probe at master, and a probe dispatch started by the built-in workflow token,
must each end skipped with no runner assigned. Record run/job IDs, exact refs,
conclusions and runner
assignment, then cancel unassigned negative runs with owner confirmation.
Never approve a fork run or merge contributor code until isolation is proven.

Local mutation QA copies workflows to scratch and runs
`WORKFLOWS_DIR=<scratch> bash tests/workflow-security-contract.test.sh`.
Label-only probe admission, a missing publish actor check, and a missing actor
check on any image-builder job must each fail naming the job. Missing caller
event/repository gates and malformed YAML must fail closed as well.
