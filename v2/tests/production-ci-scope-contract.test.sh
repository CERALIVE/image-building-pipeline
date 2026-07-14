#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2="$(cd "${HERE}/.." && pwd)"
REPO="$(cd "${V2}/.." && pwd)"

reject_pattern() {
  local pattern="$1" file="$2"
  if grep -q "${pattern}" "${file}"; then
    printf 'forbidden pattern %s in %s\n' "${pattern}" "${file}" >&2
    exit 1
  fi
}

grep -Eq '^jsonschema==[0-9]+\.[0-9]+\.[0-9]+$' "${V2}/ci/requirements-ci.txt"
grep -Eq '^PyYAML==[0-9]+\.[0-9]+\.[0-9]+$' "${V2}/ci/requirements-ci.txt"
grep -Eq '^FROM debian:trixie-[0-9]{8}-slim@sha256:[0-9a-f]{64}$' "${V2}/ci/Dockerfile"
reject_pattern 'no x86 disk artifact present.*skip' "${REPO}/.github/workflows/v2-ci.yml"
reject_pattern 'if ! ./v2/ci/check-size-regression.sh' "${REPO}/.github/workflows/v2-ci.yml"
if rg -n 'REPO_ROOT/\.\./CeraUI|V2_DIR/\.\./\.\.|DEV_SYNC_HERE}/\.\./\.\./\.\./\.\.' \
    "${V2}/tests/manifest.bats" "${V2}/tests/realhw-suite.sh" \
    "${V2}/lib/build-bundle.sh" "${V2}/lib/dev-sync/config.sh"; then
  printf 'tracked code escapes the repository root\n' >&2
  exit 1
fi
[[ -s "${V2}/ci/size-exceptions.txt" ]]
for field in candidate_artifact_name candidate_artifact_digest candidate_raw_filename \
  candidate_raw_sha256 candidate_bundle_filename candidate_keyring_filename \
  candidate_loader_filename candidate_loader_sha256 candidate_commit; do
  grep -q "${field}" "${REPO}/.github/workflows/realhw-job.yml"
  grep -q "${field}" "${REPO}/.github/workflows/release.yml"
done
reject_pattern 'CERALIVE_RK3588_FLASH_IMAGE' "${REPO}/.github/workflows/realhw-job.yml"
reject_pattern 'CERALIVE_RK3588_POWER_HELPER' "${REPO}/.github/workflows/realhw-job.yml"
reject_pattern 'CERALIVE_RK3588_LOADER' "${REPO}/.github/workflows/realhw-job.yml"

printf 'production CI/scope contract: PASS\n'
