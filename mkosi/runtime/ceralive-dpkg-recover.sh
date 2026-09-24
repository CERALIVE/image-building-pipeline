#!/usr/bin/env bash
set -uo pipefail

DPKG_BIN="${DPKG_BIN:-dpkg}"
UPDATES="${CERALIVE_DPKG_UPDATES_DIR:-/var/lib/dpkg/updates}"
RESULT="${CERALIVE_DPKG_RECOVERED:-/run/ceralive/dpkg-recovered}"

pending_updates() {
  [[ -d "${UPDATES}" ]] || return 0
  local -a entries
  shopt -s nullglob dotglob
  entries=("${UPDATES}"/*)
  shopt -u nullglob dotglob
  ((${#entries[@]} > 0))
}

audit_clean() {
  local audit
  audit="$("${DPKG_BIN}" --audit 2>&1)" || return 1
  [[ -z "${audit}" ]]
}

write_result() {
  local temporary="${RESULT}.tmp.$$"
  mkdir -p "$(dirname "${RESULT}")" || return 1
  if ! printf 'result=%s\nrecorded_at=%s\n' "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"${temporary}" ||
    ! mv -f "${temporary}" "${RESULT}"; then
    rm -f "${temporary}"
    return 1
  fi
}

if [[ ! -d "${UPDATES}" ]]; then
  write_result failure
  exit 1
fi
if ! pending_updates && audit_clean; then
  exit 0
fi

# timeout's 124 status is a failure, never an implicit successful recovery.
if timeout 600s "${DPKG_BIN}" --configure -a && ! pending_updates && audit_clean; then
  write_result success || exit 1
  exit 0
fi
write_result failure
exit 1
