# Guest firmware trust [EXISTS]

`armbian-old.asc` and `armbian-new.asc` are public keys copied byte-for-byte
from the immutable Armbian commits and SHA-256 pins documented in
`docs/RELEASE-PROCESS.md`, "Armbian archive keyring rotation".

The base installs those public files and `keyring.sh`, not the host's keyring,
GitHub secret, GnuPG home or environment. Before starting either a JIT job or
an unregistered check, `guest-job.sh` verifies both source digests, exports
exactly the host procedure's two primary keys into a temporary guest keyring,
and exports `ARMBIAN_APT_KEYRING` to the job. A missing or modified source
aborts before any job starts. The existing firmware gate independently
requires those exact fingerprints and authenticates the archive signatures.

Rebuild the pristine base after changing any runner files; an older base does
not gain new provisioning from a workflow checkout. The keyring and temporary
GnuPG state never leave the disposable guest. No host secret is needed.

# Runner-side job admission [EXISTS]

`admit-job.sh` is the runner's own gate. The base installs it root-owned (0755)
at `/usr/local/lib/ceralive-kernel-runner/admit-job.sh`, the runner service gets
`ACTIONS_RUNNER_HOOK_JOB_STARTED` pointing at it, and the hook exits non-zero
before any step unless the job is the approved dispatch: `GITHUB_ACTIONS=true`,
repository `CERALIVE/image-building-pipeline`, event `workflow_dispatch`, ref
`refs/heads/master`, workflow ref
`CERALIVE/image-building-pipeline/.github/workflows/kernel-release.yml@refs/heads/master`
and `GITHUB_RUN_ATTEMPT=1`. Every missing or different value fails closed,
including a re-run. It is the runner-side twin of `ci/kernel-release.py`'s
`--publish` guard, which protects publication rather than execution.
`guest-job.sh` refuses to start the runner if the hook is missing or writable by
the runner user; the offline `check` path starts no runner and needs none.
