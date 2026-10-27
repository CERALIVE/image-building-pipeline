#!/bin/bash
# Emit actual producer records for byte-for-byte consumer fixture copies.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
source "${HERE}/lib/kernel-stage-fixture.sh"
OUTPUT="${1:?usage: kernel-stage-contract-fixtures.sh OUTPUT_DIRECTORY}"
mkdir -p -- "${OUTPUT}"
OUTPUT="$(cd "${OUTPUT}" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf -- "${WORK}"' EXIT
stage_fixture_init

emit_run() {
  stage_args
  STAGE_ARGS[1]=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
  flock -n -E 75 -x "${CERALIVE_UPDATE_LOCK_PATH}" \
    "${CERALIVE_STAGE_SCRIPT}" "${STAGE_ARGS[@]}"
}

stage_fixture_reset
emit_run >"${OUTPUT}/staged.log" 2>&1
cp "${CERALIVE_UPDATE_STATE_DIR}/kernel-state.json" "${OUTPUT}/staged-state.json"
cp "${CERALIVE_UPDATE_STATE_DIR}/slot-overlay-B.json" "${OUTPUT}/pending-overlay.json"
cp "${FIXTURE}/rauc.json" "${OUTPUT}/rauc-status.json"

stage_fixture_reset
export FAIL_TOOL=mirror
set +e
emit_run >"${OUTPUT}/failed.log" 2>&1
rc=$?
set -e
[[ "${rc}" -eq 75 ]]
cp "${CERALIVE_UPDATE_STATE_DIR}/kernel-state.json" "${OUTPUT}/failed-state.json"
cp "${CERALIVE_UPDATE_STATE_DIR}/slot-overlay-B.json" "${OUTPUT}/invalid-overlay.json"
sha256sum "${OUTPUT}/staged-state.json" "${OUTPUT}/pending-overlay.json" \
  "${OUTPUT}/invalid-overlay.json" "${OUTPUT}/failed-state.json"
