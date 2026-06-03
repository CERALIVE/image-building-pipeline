#!/usr/bin/env bash
#
# resolve.test.sh — behaviour tests for lib/resolve.sh (the manifest resolver).
#
# Covers the four MUST-DO assertions for task 12:
#   1. merge precedence      — board overrides family on a conflicting key
#   2. array replacement      — board array REPLACES family array (not append)
#   3. versions.yaml defer    — `@versions:<key>` token resolves via get_pin
#   4. invalid board          — unknown board -> "board not found" + list
#   5. schema violation       — malformed manifest -> "schema invalid" + field
#   6. missing family         — board refs a non-existent family -> loud + list
#   7. source-ability         — emitted flat params eval cleanly into a shell
#
# Run:  v2/tests/resolve.test.sh   (exit 0 = all pass)
#
# shellcheck shell=bash

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2="$(cd "${HERE}/.." && pwd)"
RESOLVE="${V2}/lib/resolve.sh"
RESOLVE_PY="${V2}/lib/resolve.py"
FAMILY_SCHEMA="${V2}/manifests/schema/family.schema.json"
BOARD_SCHEMA="${V2}/manifests/schema/board.schema.json"

PASS=0
FAIL=0
ok()   { printf 'PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf 'FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }

assert_contains() {
  # assert_contains <label> <haystack> <needle>
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else
    bad "$1 (expected to contain: $3)"
    printf '  ---- got ----\n%s\n  -------------\n' "$2"
  fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo "=== resolve.sh behaviour tests ==="
echo

# ---------------------------------------------------------------------------
# 1+2+3. Merge precedence / array replacement / defer token — synthetic
# fixtures fed straight through resolve.py merge (no schemas: the real schemas
# are disjoint by design, so a board can't legally carry a family key; the
# MERGE ALGORITHM is what we assert here). Defer token resolution + quoting are
# then proven through the full resolve.sh path with stub manifests.
# ---------------------------------------------------------------------------
cat > "${WORK}/fam.yaml" <<'YAML'
serial_console: ttyS2:1500000
shared_scalar: from-family
only_in_family: family-value
list_field:
  - fam-a
  - fam-b
nested:
  keep: family-keep
  override_me: family-loses
YAML

cat > "${WORK}/brd.yaml" <<'YAML'
shared_scalar: from-board
only_in_board: board-value
list_field:
  - brd-x
nested:
  override_me: board-wins
YAML

merge_out="$(python3 "${RESOLVE_PY}" merge --family "${WORK}/fam.yaml" --board "${WORK}/brd.yaml")"

assert_contains "scalar conflict: board wins"        "$merge_out" $'SHARED_SCALAR\tfrom-board'
assert_contains "family-only key preserved"          "$merge_out" $'ONLY_IN_FAMILY\tfamily-value'
assert_contains "board-only key added"               "$merge_out" $'ONLY_IN_BOARD\tboard-value'
assert_contains "array REPLACED by board (not append)" "$merge_out" $'LIST_FIELD\tbrd-x'
assert_contains "nested map: untouched family leaf kept" "$merge_out" $'NESTED_KEEP\tfamily-keep'
assert_contains "nested map: board leaf wins"        "$merge_out" $'NESTED_OVERRIDE_ME\tboard-wins'
# array replacement must NOT have leaked family elements
if [[ "$merge_out" != *"fam-a"* && "$merge_out" != *"fam-b"* ]]; then
  ok "array replacement dropped family elements"
else
  bad "array replacement leaked family elements (append, not replace)"
fi

# ---------------------------------------------------------------------------
# 3b. versions.yaml defer token resolves through the full resolve.sh path.
# A stub family+board carry `@versions:armbian` in a free-string field; we
# point VERSIONS_YAML at a controlled registry and assert the pin is injected.
# ---------------------------------------------------------------------------
STUB="${WORK}/stub"
mkdir -p "${STUB}/manifests/boards" "${STUB}/manifests/families" "${STUB}/manifests/schema" "${STUB}/lib"
cp "${V2}/lib/common.sh" "${V2}/lib/resolve.sh" "${V2}/lib/resolve.py" "${STUB}/lib/"
# Permissive schemas (accept anything) so we isolate the defer mechanism.
echo '{"type":"object"}' > "${STUB}/manifests/schema/board.schema.json"
echo '{"type":"object"}' > "${STUB}/manifests/schema/family.schema.json"
cat > "${STUB}/manifests/families/stubfam.yaml" <<'YAML'
framework_pin: "@versions:armbian"
shared: from-family
YAML
cat > "${STUB}/manifests/boards/stubboard.yaml" <<'YAML'
family: stubfam
shared: from-board
YAML
cat > "${WORK}/versions.yaml" <<'YAML'
armbian:
  pin: main
YAML

defer_out="$(VERSIONS_YAML="${WORK}/versions.yaml" "${STUB}/lib/resolve.sh" stubboard 2>/dev/null)"
assert_contains "defer token resolved via get_pin" "$defer_out" "FRAMEWORK_PIN='main'"
assert_contains "board still wins through full path" "$defer_out" "SHARED='from-board'"

# missing-pin defer must fail loudly (no half-resolved token)
cat > "${STUB}/manifests/families/stubfam.yaml" <<'YAML'
framework_pin: "@versions:does-not-exist"
YAML
if VERSIONS_YAML="${WORK}/versions.yaml" "${STUB}/lib/resolve.sh" stubboard >/dev/null 2>"${WORK}/deferr.txt"; then
  bad "absent defer pin should fail loudly"
else
  assert_contains "absent defer pin fails loudly" "$(cat "${WORK}/deferr.txt")" "defers to versions.yaml pin 'does-not-exist'"
fi

# ---------------------------------------------------------------------------
# 4. Invalid board — unknown name -> "board not found" + available list.
# ---------------------------------------------------------------------------
inv_out="$("${RESOLVE}" no-such-board 2>&1 || true)"
assert_contains "unknown board -> 'board not found'" "$inv_out" "board not found: 'no-such-board'"
assert_contains "unknown board lists available"      "$inv_out" "rock-5b-plus"

# ---------------------------------------------------------------------------
# 5. Schema violation — malformed board manifest -> "schema invalid" + field.
# dtb_name must match ^...\.dtb$; feed a bad one.
# ---------------------------------------------------------------------------
bad_board="$(python3 "${RESOLVE_PY}" merge \
  --family "${V2}/manifests/families/rk3588.yaml" \
  --board <(printf 'family: rk3588\nboard_id: badboard\ndtb_name: not-a-dtb\ndescription: x\n') \
  --family-schema "${FAMILY_SCHEMA}" --board-schema "${BOARD_SCHEMA}" 2>&1 || true)"
assert_contains "schema violation -> 'schema invalid'" "$bad_board" "schema invalid"
assert_contains "schema violation names the field"     "$bad_board" "dtb_name"

# missing required field (no arch) on family
bad_family="$(python3 "${RESOLVE_PY}" merge \
  --family <(printf 'armbian_branch: vendor\n') \
  --board "${V2}/manifests/boards/rock-5b-plus.yaml" \
  --family-schema "${FAMILY_SCHEMA}" --board-schema "${BOARD_SCHEMA}" 2>&1 || true)"
assert_contains "missing required field -> schema invalid" "$bad_family" "schema invalid"
assert_contains "missing required field is named"          "$bad_family" "arch"

# ---------------------------------------------------------------------------
# 6. Missing family — board refs a family with no manifest -> loud + list.
# ---------------------------------------------------------------------------
GHOST="${WORK}/ghost"
mkdir -p "${GHOST}/manifests/boards" "${GHOST}/manifests/families" "${GHOST}/manifests/schema" "${GHOST}/lib"
cp "${V2}/lib/common.sh" "${V2}/lib/resolve.sh" "${V2}/lib/resolve.py" "${GHOST}/lib/"
cp "${V2}/manifests/schema/"*.json "${GHOST}/manifests/schema/"
cp "${V2}/manifests/families/rk3588.yaml" "${GHOST}/manifests/families/"
cat > "${GHOST}/manifests/boards/ghostboard.yaml" <<'YAML'
family: nonexistent-family
board_id: ghostboard
dtb_name: rk3588-ghost.dtb
description: ghost board referencing a missing family
YAML
miss_out="$("${GHOST}/lib/resolve.sh" ghostboard 2>&1 || true)"
assert_contains "missing family -> 'family not found'" "$miss_out" "family not found: 'nonexistent-family'"
assert_contains "missing family lists available"       "$miss_out" "rk3588"

# ---------------------------------------------------------------------------
# 7. Source-ability — the flat output evals into a shell cleanly.
# ---------------------------------------------------------------------------
src_out="$("${RESOLVE}" rock-5b-plus 2>/dev/null)"
if (
  eval "$src_out"
  [[ "${ARCH:-}" == "arm64" ]] || exit 1
  [[ "${BOARD_ID:-}" == "rock-5b-plus" ]] || exit 1
  [[ "${ARMBIAN_BRANCH:-}" == "vendor" ]] || exit 1
  [[ "${QUIRKS_M2_MODEM_SIM_WORKAROUND:-}" == "required" ]] || exit 1
); then
  ok "flat output is source-able (eval round-trip)"
else
  bad "flat output failed eval round-trip"
fi

echo
echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ "${FAIL}" -eq 0 ]]
