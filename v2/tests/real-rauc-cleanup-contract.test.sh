#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="${HERE}/real-rauc-contract.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

snapshot() {
  find /tmp -maxdepth 1 -type d -name 'ceralive-rauc-contract.*' -printf '%f\n' 2>/dev/null | sort
}

assert_no_new_resources() {
  local before="$1" after="$2" added work
  added="$(comm -13 "${before}" "${after}")"
  [[ -z "${added}" ]] || { printf 'RAUC harness leaked workdirs: %s\n' "${added}" >&2; return 1; }
  # Each check must fail the FUNCTION on its own. A bare `! cmd` here would not:
  # `!`-negated commands are exempt from errexit, so they are three ordinary
  # statements whose status is discarded by the next one — only the last command
  # of the last iteration could ever have reached the caller.
  while IFS= read -r work; do
    [[ -n "${work}" ]] || continue
    if findmnt -rn -o TARGET,SOURCE | grep -F "/tmp/${work}" >/dev/null; then
      printf 'RAUC harness leaked a mount under /tmp/%s\n' "${work}" >&2
      return 1
    fi
    if losetup -l -n -O BACK-FILE | grep -F "/tmp/${work}" >/dev/null; then
      printf 'RAUC harness leaked a loop device backed by /tmp/%s\n' "${work}" >&2
      return 1
    fi
    if pgrep -f "/tmp/${work}/" >/dev/null; then
      printf 'RAUC harness leaked a process referencing /tmp/%s\n' "${work}" >&2
      return 1
    fi
  done <"${after}"
}

snapshot >"${TMP}/before"
if CERALIVE_REAL_RAUC_FAIL_AFTER_SERVICE=1 bash "${HARNESS}" >"${TMP}/forced-failure.log" 2>&1; then
  printf 'forced-failure RAUC cleanup probe unexpectedly passed\n' >&2
  exit 1
fi
snapshot >"${TMP}/after-failure"
assert_no_new_resources "${TMP}/before" "${TMP}/after-failure"

CERALIVE_REAL_RAUC_PAUSE_AFTER_SERVICE=30 bash "${HARNESS}" >"${TMP}/terminated.log" 2>&1 &
pid=$!
for _ in $(seq 1 100); do
  pgrep -P "${pid}" >/dev/null 2>&1 && break
  sleep 0.1
done
kill -TERM "${pid}"
set +e
wait "${pid}"
rc=$?
set -e
[[ "${rc}" -ne 0 ]]
snapshot >"${TMP}/after-termination"
assert_no_new_resources "${TMP}/before" "${TMP}/after-termination"

printf 'real RAUC trap cleanup failure/termination contract: PASS\n'
