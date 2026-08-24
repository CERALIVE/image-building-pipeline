#!/usr/bin/env bash
#
# firstparty-version-resolution.test.sh — architecture-specific first-party pins
# resolve to exact apt package specs without weakening generic package pins.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"
FETCH="${PIPELINE_DIR}/lib/fetch-debs.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() { printf 'firstparty-version-resolution: FAIL: %s\n' "$*" >&2; exit 1; }

cat >"${TMP}/pins" <<'PINS'
shared=1.0
split[amd64]=2.0-amd64
split[arm64]=2.0-arm64
PINS

resolve() {
  local arch="$1" pkg="$2"
  ARCH="${arch}" FIRST_PARTY_DEB_VERSIONS_FILE="${TMP}/pins" \
    bash -c 'source "$1" >/dev/null; first_party_pinned_version "$2"' _ "${FETCH}" "${pkg}"
}

[[ "$(resolve amd64 shared)" == "1.0" ]] || fail "generic pin did not resolve for amd64"
[[ "$(resolve arm64 shared)" == "1.0" ]] || fail "generic pin did not resolve for arm64"
[[ "$(resolve amd64 split)" == "2.0-amd64" ]] || fail "amd64 override did not resolve"
[[ "$(resolve arm64 split)" == "2.0-arm64" ]] || fail "arm64 override did not resolve"

printf 'split[amd64]=duplicate\n' >>"${TMP}/pins"
if resolve amd64 split >"${TMP}/duplicate.out" 2>&1; then
  fail "duplicate architecture-specific pins were accepted"
fi
grep -Fq 'duplicate architecture-specific Debian versions' "${TMP}/duplicate.out" \
  || fail "duplicate pin rejection did not name the defect"

printf 'firstparty-version-resolution: PASS\n'
