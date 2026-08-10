#!/usr/bin/env bash
#
# versions-lib.test.sh — contract for lib/shared/versions-lib.sh::get_pin, the ONE
# reader of the repo-root versions.yaml pin registry.
#
# The extraction replaced two byte-identical private copies (lib/resolve.sh and
# lib/fetch/firstparty.sh). This suite pins the behaviour those copies had, so a
# future edit to the shared reader cannot quietly change what either consumer sees:
#
#   known      — an existing key returns exactly its pin
#   missing    — an absent key, an absent `pin:`, and an absent FILE all return empty
#   duplicate  — a repeated top-level key resolves FIRST-WINS (documented, not an
#                error) AND the shipped versions.yaml is proved to contain none
#   malformed  — prefix keys, regex-looking keys, a column-0 `pin:`, and a `pin:`
#                that belongs to the NEXT component are all refused
#
# It also asserts the single-definition property: neither former call site keeps a
# private copy, and both resolve get_pin from the shared library.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"
VERSIONS_LIB="${PIPELINE_DIR}/lib/shared/versions-lib.sh"
SHIPPED_YAML="${PIPELINE_DIR}/versions.yaml"

PASS=0
fail() { printf 'versions-lib: FAIL: %s\n' "$*" >&2; exit 1; }
ok()   { PASS=$(( PASS + 1 )); printf 'versions-lib: ok  %s\n' "$*"; }

[[ -f "${VERSIONS_LIB}" ]] || fail "missing library: ${VERSIONS_LIB}"
[[ -f "${SHIPPED_YAML}" ]] || fail "missing shipped registry: ${SHIPPED_YAML}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# shellcheck source=../lib/shared/versions-lib.sh
source "${VERSIONS_LIB}"

expect_pin() {
  local desc="$1" want="$2" key="$3" file="$4" got
  got="$(get_pin "${key}" "${file}")"
  [[ "${got}" == "${want}" ]] \
    || fail "${desc}: get_pin '${key}' returned '${got}', expected '${want}'"
  ok "${desc}"
}

# --- single-definition property --------------------------------------------
n="$(grep -c '^get_pin() {' "${VERSIONS_LIB}")"
[[ "${n}" == "1" ]] || fail "get_pin is defined ${n} times in versions-lib.sh (expected 1)"
dupes="$(cd "${PIPELINE_DIR}" && grep -rln '^get_pin() {' --include='*.sh' lib 2>/dev/null \
  | grep -v '^lib/shared/versions-lib.sh$' || true)"
[[ -z "${dupes}" ]] || fail "a private get_pin copy is still present in: ${dupes}"
for consumer in lib/resolve.sh lib/fetch-debs.sh; do
  grep -q 'shared/versions-lib.sh' "${PIPELINE_DIR}/${consumer}" \
    || fail "${consumer} does not source the shared versions library"
done
ok "get_pin is defined once and both former call sites source it"

# --- known keys -------------------------------------------------------------
fixture="${WORK}/versions.yaml"
cat >"${fixture}" <<'YAML'
srt:
  repo: CERALIVE/srt
  pin: v1.5.4-ceralive1
srtla:
  repo: CERALIVE/srtla
  pin: 9b0b4fa
CeraUI:
  pin: 2026.6.3
gstlibuvch264src:
  pin: 0.4.2
no-pin-here:
  repo: CERALIVE/nothing
trailing:
  pin:    spaced-value
YAML

expect_pin "known: a plain key returns its pin"            "v1.5.4-ceralive1" srt              "${fixture}"
expect_pin "known: a mixed-case key returns its pin"       "2026.6.3"         CeraUI           "${fixture}"
expect_pin "known: a digit-bearing key returns its pin"    "0.4.2"            gstlibuvch264src "${fixture}"
expect_pin "known: leading whitespace in the value is stripped" "spaced-value" trailing        "${fixture}"

# The exact-match property, and the reason it matters: `srt` is a prefix of
# `srtla`, and reading the wrong one would silently pin the wrong component.
expect_pin "known: a prefix key does NOT read the longer key's pin" "9b0b4fa" srtla "${fixture}"

# --- missing ----------------------------------------------------------------
expect_pin "missing: an absent key returns empty"          "" does-not-exist "${fixture}"
expect_pin "missing: a key with no pin: field returns empty" "" no-pin-here  "${fixture}"
expect_pin "missing: an absent file returns empty"         "" srt "${WORK}/no-such-file.yaml"
expect_pin "missing: a directory in place of the file returns empty" "" srt "${WORK}"

# The empty result must be a SUCCESS, not a failure — resolve.sh decides that an
# empty deferred pin is fatal, firstparty.sh only logs it, and neither would work
# if the reader itself exited non-zero.
if ! get_pin does-not-exist "${fixture}" >/dev/null; then
  fail "missing: get_pin exited non-zero for an absent key (callers rely on exit 0)"
fi
ok "missing: an absent key is exit 0 with empty output, not a failure"

# --- duplicate --------------------------------------------------------------
dup="${WORK}/duplicate.yaml"
cat >"${dup}" <<'YAML'
srtla:
  pin: first-wins
other:
  pin: 1
srtla:
  pin: second-loses
YAML
# DOCUMENTED behaviour, deliberately NOT changed by this extraction: the first
# block wins and the scan stops. Making a duplicate key fatal would be a real
# behaviour change to the resolver and the fetch path, so it stays out of a pure
# extraction — this leg exists so that any future change to it is a visible edit.
expect_pin "duplicate: the FIRST block wins and the scan stops" "first-wins" srtla "${dup}"

dup2="${WORK}/duplicate-empty-first.yaml"
cat >"${dup2}" <<'YAML'
srtla:
  repo: CERALIVE/srtla
srtla:
  pin: from-the-second-block
YAML
expect_pin "duplicate: a pinless first block falls through to the second" \
  "from-the-second-block" srtla "${dup2}"

# Non-vacuity: the guarantee above only matters if the SHIPPED registry is clean.
shipped_dupes="$(awk '/^[A-Za-z0-9_.-]+:/{ sub(/:.*/,""); print }' "${SHIPPED_YAML}" \
  | sort | uniq -d)"
[[ -z "${shipped_dupes}" ]] \
  || fail "the shipped versions.yaml has duplicate top-level keys: ${shipped_dupes}"
ok "duplicate: the shipped versions.yaml has no duplicate top-level keys"

# --- malformed --------------------------------------------------------------
mal="${WORK}/malformed.yaml"
cat >"${mal}" <<'YAML'
alpha:
  repo: CERALIVE/alpha
pin: column-zero-is-not-a-field
beta:
  pin: beta-pin
gamma:
  repo: CERALIVE/gamma
delta:
  pin: delta-pin
YAML

# A `pin:` in column 0 is a top-level key of its own, not alpha's field. The
# block-closing rule must reject it rather than attribute it to alpha.
expect_pin "malformed: a column-0 pin: is not attributed to the preceding key" "" alpha "${mal}"
# ...and it must not leak into the NEXT component either.
expect_pin "malformed: the next component still reads its own pin" "beta-pin" beta "${mal}"
# A pinless block must not borrow the following block's pin.
expect_pin "malformed: a pinless block does not borrow the next block's pin" "" gamma "${mal}"

# The key is compared literally, never as a regular expression: a dotted or
# bracketed key must not match anything it merely resembles.
expect_pin "malformed: a regex-looking key matches nothing"        "" 'b.ta'    "${mal}"
expect_pin "malformed: an anchored regex key matches nothing"      "" '^beta$'  "${mal}"
expect_pin "malformed: a key spelled with its colon matches nothing" "" 'beta:' "${mal}"
expect_pin "malformed: an empty key matches nothing"               "" ''        "${mal}"

nocolon="${WORK}/nocolon.yaml"
printf 'epsilon:\n  pin epsilon-pin\n' >"${nocolon}"
expect_pin "malformed: a pin without a colon is not a pin" "" epsilon "${nocolon}"

# --- the shipped registry actually resolves ---------------------------------
for key in srt cerastream CeraUI srtla-send-rs; do
  [[ -n "$(get_pin "${key}" "${SHIPPED_YAML}")" ]] \
    || fail "the shipped versions.yaml has no resolvable pin for '${key}'"
done
ok "the shipped registry resolves every device-image REPOS component"

printf '\nversions-lib: %d checks passed\n' "${PASS}"
