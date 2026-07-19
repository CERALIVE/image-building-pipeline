#!/usr/bin/env bash
#
# firstparty-classification.test.sh — offline guard against the [3/9] package
# partitioner drifting from the fetcher's first-party set.
#
# fetch-debs.sh stages every FIRST_PARTY_APT_PKGS entry into <staging>/debs/, and
# orchestrate.sh's [3/9] step then partitions each staged .deb into BSP vs
# first-party by an exact package-name allowlist (firstparty_names). If a package
# is added to the fetcher but not the partitioner allowlist, a REAL build (not the
# DRY_RUN plan-only CI job) dies with "unclassified staged package". That exact gap
# shipped the 9-package ModemManager closure (modem-stack v0.2.0): the fetcher got
# the packages, the partitioner did not, and the first full build since blew up.
# This guard asserts the partitioner allowlist covers the whole fetcher set.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2="$(cd "${HERE}/.." && pwd)"
FETCH="${V2}/lib/fetch-debs.sh"
ORCH="${V2}/lib/orchestrate.sh"

fail() { printf 'firstparty-classification: FAIL: %s\n' "$*" >&2; exit 1; }

for f in "${FETCH}" "${ORCH}"; do
  [[ -f "${f}" ]] || fail "missing source file: ${f}"
done

# Source the fetcher's array declaration in an isolated subshell (the file guards
# direct execution, so sourcing only defines vars/functions — it runs nothing).
mapfile -t fetch_pkgs < <(
  bash -c '
    set -euo pipefail
    # shellcheck disable=SC1090
    source "$1" >/dev/null 2>&1 || true
    printf "%s\n" "${FIRST_PARTY_APT_PKGS[@]}"
  ' _ "${FETCH}"
)
(( ${#fetch_pkgs[@]} > 0 )) \
  || fail "could not read FIRST_PARTY_APT_PKGS from ${FETCH}"

# Extract the partitioner's exact firstparty_names allowlist literal.
firstparty_names="$(awk -F'"' '/local firstparty_names=/ { print $2; exit }' "${ORCH}")"
[[ -n "${firstparty_names}" ]] \
  || fail "could not extract firstparty_names allowlist from ${ORCH}"

missing=()
for pkg in "${fetch_pkgs[@]}"; do
  [[ -n "${pkg}" ]] || continue
  [[ "${firstparty_names}" == *" ${pkg} "* ]] || missing+=("${pkg}")
done

if (( ${#missing[@]} > 0 )); then
  fail "orchestrate.sh firstparty_names is missing $(( ${#missing[@]} )) fetched first-party package(s): ${missing[*]} — a real build would die with 'unclassified staged package'"
fi

# Sanity: the closure the regression was about must be present (non-vacuity).
for required in modemmanager libmbim-glib4 libqmi-glib5 libqrtr-glib0; do
  [[ "${firstparty_names}" == *" ${required} "* ]] \
    || fail "expected ModemManager-closure package '${required}' in firstparty_names"
done

printf 'firstparty-classification: PASS (all %d fetched first-party packages are classifiable)\n' "${#fetch_pkgs[@]}"
