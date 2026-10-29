#!/usr/bin/env bash
# Run the real command contract under both local and Actions parent contexts.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${ROOT}/tests/lib/assertions.sh"
WORK="$(mktemp -d)"
trap 'rm -rf -- "${WORK}"' EXIT

names="$(GITHUB_FUTURE_FIELD=fixture RUNNER_FUTURE_FIELD=fixture bash -c '
  source "$1"
  printf "%s" "${!GITHUB_@}${!RUNNER_@}"
' environment-check "${ROOT}/tests/lib/clear-workflow-env.sh")"
assert_eq 'isolation clears both entire workflow namespaces' '' "${names}"

for mode in local workflow; do
  (
    source "${ROOT}/tests/lib/clear-workflow-env.sh"
    if [[ "${mode}" == workflow ]]; then
      export GITHUB_ACTIONS=true GITHUB_REPOSITORY=CERALIVE/image-building-pipeline
      export GITHUB_WORKFLOW_REF=CERALIVE/image-building-pipeline/.github/workflows/kernel-release.yml@refs/heads/master
      export GITHUB_REF=refs/heads/master GITHUB_RUN_ATTEMPT=1 GITHUB_EVENT_NAME=workflow_dispatch
      export GITHUB_RUN_ID=67890 RUNNER_TEMP="${WORK}/unused-runner-temp"
      export GITHUB_FUTURE_FIELD=fixture RUNNER_FUTURE_FIELD=fixture
    fi
    bash "${ROOT}/tests/kernel-release-command.test.sh"
  ) >"${WORK}/${mode}.log" 2>&1
  code=$?
  assert_eq "${mode} command contract exit" 0 "${code}"
  [[ "${code}" == 0 ]] || cat "${WORK}/${mode}.log"
  summary="$(grep '^Local kernel release contract:' "${WORK}/${mode}.log")"
  assert_eq "${mode} command contract results" \
    'Local kernel release contract: 88 passed, 0 failed' "${summary}"
  printf '%s\n' "${summary}" >"${WORK}/${mode}.results"
done
if cmp -s "${WORK}/local.results" "${WORK}/workflow.results"; then
  ok 'local and workflow command contract results are byte-identical'
else
  bad 'local and workflow command contract results differ'
fi
printf 'Kernel release environment contract: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" == 0 ]]
