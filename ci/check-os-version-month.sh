#!/usr/bin/env bash
# A new OS version's YYYY.M must be the current UTC month, so a stale CERALIVE_OS_RELEASE_VERSION
# cannot ship an image labelled with a past month.
set -euo pipefail

version="${1:?usage: check-os-version-month.sh VERSION [YYYY.M]}"
now="${2:-$(date -u +%Y.%-m)}"

[[ "${version}" =~ ^([0-9]{4}\.[0-9]+)\.[0-9]+$ ]] || { echo "OS version is not CalVer: ${version}" >&2; exit 1; }
[[ "${BASH_REMATCH[1]}" == "${now}" ]] || {
  echo "OS version ${version} is not in the current month (${now}): set CERALIVE_OS_RELEASE_VERSION to ${now}.N and rebuild" >&2
  exit 1
}
