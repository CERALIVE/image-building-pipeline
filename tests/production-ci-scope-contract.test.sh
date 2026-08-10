#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"
REPO="${PIPELINE_DIR}"

reject_pattern() {
  local pattern="$1" file="$2"
  if grep -q "${pattern}" "${file}"; then
    printf 'forbidden pattern %s in %s\n' "${pattern}" "${file}" >&2
    exit 1
  fi
}

grep -Eq '^jsonschema==[0-9]+\.[0-9]+\.[0-9]+$' "${PIPELINE_DIR}/ci/requirements-ci.txt"
grep -Eq '^PyYAML==[0-9]+\.[0-9]+\.[0-9]+$' "${PIPELINE_DIR}/ci/requirements-ci.txt"
grep -Eq '^FROM debian:trixie-[0-9]{8}-slim@sha256:[0-9a-f]{64}$' "${PIPELINE_DIR}/ci/Dockerfile"
reject_pattern 'no x86 disk artifact present.*skip' "${REPO}/.github/workflows/v2-ci.yml"
reject_pattern 'if ! ./ci/check-size-regression.sh' "${REPO}/.github/workflows/v2-ci.yml"
if rg -n 'REPO_ROOT/\.\./CeraUI|PIPELINE_DIR/\.\./\.\.|DEV_SYNC_HERE}/\.\./\.\./\.\./\.\.' \
    "${PIPELINE_DIR}/tests/manifest.bats" "${PIPELINE_DIR}/tests/realhw-suite.sh" \
    "${PIPELINE_DIR}/lib/build-bundle.sh" "${PIPELINE_DIR}/lib/dev-sync/config.sh"; then
  printf 'tracked code escapes the repository root\n' >&2
  exit 1
fi
[[ -s "${PIPELINE_DIR}/ci/size-exceptions.txt" ]]

printf 'production CI/scope contract: PASS\n'
