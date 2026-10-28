#!/usr/bin/env bash
# Runner-side admission for the disposable kernel-release VM.
#
# Installed root-owned (0755) at /usr/local/lib/ceralive-kernel-runner/ and wired
# through ACTIONS_RUNNER_HOOK_JOB_STARTED, so the JIT runner refuses a job BEFORE
# any step runs. This is independent of ci/kernel-release.py's --publish guard:
# that one protects publication, this one protects execution on the workstation.
# Values are the same context the --publish guard requires; anything missing or
# different fails closed, including re-runs (GITHUB_RUN_ATTEMPT != 1).
set -euo pipefail

refuse() {
  printf 'ceralive runner admission refused: %s\n' "$1" >&2
  exit 1
}

[[ "${GITHUB_ACTIONS:-}" == "true" ]] \
  || refuse "GITHUB_ACTIONS='${GITHUB_ACTIONS:-}' is not true"
[[ "${GITHUB_REPOSITORY:-}" == "CERALIVE/image-building-pipeline" ]] \
  || refuse "repository '${GITHUB_REPOSITORY:-<missing>}'"
[[ "${GITHUB_EVENT_NAME:-}" == "workflow_dispatch" ]] \
  || refuse "event '${GITHUB_EVENT_NAME:-<missing>}'"
[[ "${GITHUB_REF:-}" == "refs/heads/master" ]] \
  || refuse "ref '${GITHUB_REF:-<missing>}'"
[[ "${GITHUB_WORKFLOW_REF:-}" == "CERALIVE/image-building-pipeline/.github/workflows/kernel-release.yml@refs/heads/master" ]] \
  || refuse "workflow ref '${GITHUB_WORKFLOW_REF:-<missing>}'"
[[ "${GITHUB_RUN_ATTEMPT:-}" == "1" ]] \
  || refuse "run attempt '${GITHUB_RUN_ATTEMPT:-<missing>}'"

printf 'ceralive runner admission: approved %s run=%s\n' \
  "${GITHUB_WORKFLOW_REF}" "${GITHUB_RUN_ID:-<no-run-id>}"
