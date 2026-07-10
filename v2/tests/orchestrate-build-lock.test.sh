#!/usr/bin/env bash

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2="$(cd "${TESTS_DIR}/.." && pwd)"
ORCHESTRATOR="${V2}/lib/orchestrate.sh"
MANIFEST="${V2}/manifests/boards/rock-5b-plus.yaml"
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/orchestrate-build-lock.XXXXXX")"

cleanup() {
	rm -rf "${RUN_DIR}"
}
trap cleanup EXIT

mkdir -p "${RUN_DIR}/locks"
exec 9>"${RUN_DIR}/locks/rock-5b-plus.lock"
flock -n 9

set +e
DRY_RUN=1 \
	INSTALL_BOOT_BSP=0 \
	CERALIVE_BUILD_LOCK_DIR="${RUN_DIR}/locks" \
	CERALIVE_BUILD_LOCK_TIMEOUT=0 \
	"${ORCHESTRATOR}" --board rock-5b-plus --manifest "${MANIFEST}" \
	>"${RUN_DIR}/contended.out" 2>&1
contended_rc=$?
set -e

if [[ "${contended_rc}" -eq 0 ]]; then
	printf 'FAIL concurrent same-board build was not rejected\n' >&2
	exit 1
fi
if ! grep -q "build already active for board 'rock-5b-plus'" "${RUN_DIR}/contended.out"; then
	printf 'FAIL contention error did not name the active board build\n' >&2
	cat "${RUN_DIR}/contended.out" >&2
	exit 1
fi
printf 'PASS concurrent same-board build is rejected before staging mutation\n'

flock -u 9

DRY_RUN=1 \
	INSTALL_BOOT_BSP=0 \
	CERALIVE_BUILD_LOCK_DIR="${RUN_DIR}/locks" \
	CERALIVE_BUILD_LOCK_TIMEOUT=0 \
	"${ORCHESTRATOR}" --board rock-5b-plus --manifest "${MANIFEST}" \
	>"${RUN_DIR}/released.out" 2>&1

grep -q 'DRY-RUN complete' "${RUN_DIR}/released.out"
printf 'PASS released same-board lock permits the build plan\n'
