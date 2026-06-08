#!/usr/bin/env bats
#
# manifest.bats — CI unit suite for the CeraLive v2 manifest system.
#
# Scope (UNIT ONLY — no image boot, no orchestrator):
#   * schema self-validation : the JSON Schemas are themselves legal draft-2020-12
#   * valid manifests        : minimal valid family/board fixtures validate (exit 0)
#   * invalid manifests      : missing-required + bad-enum fixtures fail, naming field
#   * resolver merge-precedence : family defaults <- board overrides (board wins),
#                                 arrays REPLACE (board array replaces family array)
#   * versions.yaml pins     : an `@versions:<key>` defer token resolves to the pin
#   * common.sh strict-fail  : die / err_trap / require_cmd all fail loudly
#
# Dependency: bats-core (https://github.com/bats-core/bats-core) + python3 with
# PyYAML and python-jsonschema (the same validator lib resolve.py uses). ajv is
# NOT available on the host; validation goes through python-jsonschema.
#
# Run:  v2/run-tests              (CI entrypoint)
#   or: bats v2/tests/manifest.bats

setup() {
  TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  V2="$(cd "$TESTS_DIR/.." && pwd)"
  LIB_DIR="$V2/lib"
  COMMON_SH="$LIB_DIR/common.sh"
  RESOLVE_SH="$LIB_DIR/resolve.sh"
  RESOLVE_PY="$LIB_DIR/resolve.py"
  SCHEMA_DIR="$V2/manifests/schema"
  FAMILY_SCHEMA="$SCHEMA_DIR/family.schema.json"
  BOARD_SCHEMA="$SCHEMA_DIR/board.schema.json"
  FIXTURES="$TESTS_DIR/manifests/fixtures"
  REPO_ROOT="$(cd "$V2/.." && pwd)"
  # Locate the pin registry. Standalone CI checks out only this repo, so the
  # canonical versions.yaml ships at the repo root (sibling of v2/). In the
  # monorepo dev layout it also exists one level up (workspace root). Honour an
  # explicit VERSIONS_YAML override first, then prefer the repo-root copy, then
  # fall back to the workspace-root copy.
  if [[ -z "${VERSIONS_YAML:-}" || ! -f "${VERSIONS_YAML:-}" ]]; then
    if [[ -f "$REPO_ROOT/versions.yaml" ]]; then
      VERSIONS_YAML="$REPO_ROOT/versions.yaml"
    elif [[ -f "$REPO_ROOT/../versions.yaml" ]]; then
      VERSIONS_YAML="$(cd "$REPO_ROOT/.." && pwd)/versions.yaml"
    else
      VERSIONS_YAML="$REPO_ROOT/versions.yaml"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# validate_manifest <manifest.yaml> <schema.json>
# Exit 0 + "VALID" when the YAML satisfies the schema; exit 1 + one
# "validation error: field '<field>': <message>" line per violation otherwise.
validate_manifest() {
  python3 - "$1" "$2" <<'PY'
import sys, json
import yaml
from jsonschema import Draft202012Validator

data = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
schema = json.load(open(sys.argv[2], encoding="utf-8"))
validator = Draft202012Validator(schema)
errors = sorted(validator.iter_errors(data), key=lambda e: list(e.absolute_path))
if errors:
    for e in errors:
        field = "/".join(str(p) for p in e.absolute_path) or "(root)"
        sys.stderr.write("validation error: field '%s': %s\n" % (field, e.message))
    sys.exit(1)
print("VALID")
PY
}

# check_schema_metaschema <schema.json>
# Exit 0 + "SCHEMA-OK" iff the schema is itself a legal draft-2020-12 schema.
check_schema_metaschema() {
  python3 - "$1" <<'PY'
import sys, json
from jsonschema import Draft202012Validator

schema = json.load(open(sys.argv[1], encoding="utf-8"))
Draft202012Validator.check_schema(schema)  # raises SchemaError -> non-zero
print("SCHEMA-OK")
PY
}

# get_pin <key> — same awk get_pin used by resolve.sh / fetch-debs.sh.
get_pin() {
  awk -v key="$1" '$0==key":"{f=1;next} f&&/^[a-zA-Z]/{f=0}
    f&&/^[[:space:]]+pin:/{gsub(/^[[:space:]]+pin:[[:space:]]*/,"");print;exit}' "$VERSIONS_YAML"
}

# ===========================================================================
# 1. Schema self-validation — the schemas are legal draft-2020-12 documents.
# ===========================================================================

@test "schema: family.schema.json is a valid draft-2020-12 schema" {
  run check_schema_metaschema "$FAMILY_SCHEMA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SCHEMA-OK"* ]]
}

@test "schema: board.schema.json is a valid draft-2020-12 schema" {
  run check_schema_metaschema "$BOARD_SCHEMA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SCHEMA-OK"* ]]
}

# ===========================================================================
# 2. Valid manifests — minimal fixtures + shipped manifests validate.
# ===========================================================================

@test "valid: minimal family fixture passes family schema" {
  run validate_manifest "$FIXTURES/valid-family.yaml" "$FAMILY_SCHEMA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"VALID"* ]]
}

@test "valid: minimal board fixture passes board schema" {
  run validate_manifest "$FIXTURES/valid-board.yaml" "$BOARD_SCHEMA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"VALID"* ]]
}

@test "valid: shipped rk3588 family validates against family schema" {
  run validate_manifest "$V2/manifests/families/rk3588.yaml" "$FAMILY_SCHEMA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"VALID"* ]]
}

@test "valid: shipped rock-5b-plus board validates against board schema" {
  run validate_manifest "$V2/manifests/boards/rock-5b-plus.yaml" "$BOARD_SCHEMA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"VALID"* ]]
}

# ===========================================================================
# 3. Invalid manifests — schema rejection names the offending field.
# ===========================================================================

@test "invalid: family missing required 'arch' fails and names arch" {
  run validate_manifest "$FIXTURES/invalid-family-missing-arch.yaml" "$FAMILY_SCHEMA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"arch"* ]]
}

@test "invalid: board with out-of-enum app_backend fails and names app_backend" {
  run validate_manifest "$FIXTURES/invalid-board-bad-backend.yaml" "$BOARD_SCHEMA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"app_backend"* ]]
}

# ===========================================================================
# 4. Resolver merge-precedence — family defaults survive, board fields apply.
# ===========================================================================

@test "resolve: rock-5b-plus emits family defaults (ARCH, RAUC adapter, partition)" {
  run "$RESOLVE_SH" rock-5b-plus
  [ "$status" -eq 0 ]
  [[ "$output" == *"ARCH='arm64'"* ]]
  [[ "$output" == *"RAUC_BOOTLOADER_ADAPTER='custom'"* ]]
  [[ "$output" == *"PARTITION_TEMPLATE='rk3588-ab'"* ]]
}

@test "resolve: rock-5b-plus emits board-tier fields at board value" {
  run "$RESOLVE_SH" rock-5b-plus
  [ "$status" -eq 0 ]
  [[ "$output" == *"BOARD_ID='rock-5b-plus'"* ]]
  [[ "$output" == *"DTB_NAME='rk3588-rock-5b-plus.dtb'"* ]]
  [[ "$output" == *"QUIRKS_M2_MODEM_SIM_WORKAROUND='required'"* ]]
}

@test "resolve: board overrides family on key conflict; arrays REPLACE" {
  fam="$BATS_TEST_TMPDIR/fam.yaml"
  brd="$BATS_TEST_TMPDIR/brd.yaml"
  cat > "$fam" <<'YAML'
shared_scalar: from-family
only_in_family: family-value
list_field:
  - fam-a
  - fam-b
YAML
  cat > "$brd" <<'YAML'
shared_scalar: from-board
only_in_board: board-value
list_field:
  - brd-x
YAML
  run python3 "$RESOLVE_PY" merge --family "$fam" --board "$brd"
  [ "$status" -eq 0 ]
  # board wins on the shared key
  [[ "$output" == *$'SHARED_SCALAR\tfrom-board'* ]]
  # family-only key preserved, board-only key added
  [[ "$output" == *$'ONLY_IN_FAMILY\tfamily-value'* ]]
  [[ "$output" == *$'ONLY_IN_BOARD\tboard-value'* ]]
  # array REPLACED (board element present, family elements gone)
  [[ "$output" == *$'LIST_FIELD\tbrd-x'* ]]
  [[ "$output" != *"fam-a"* ]]
  [[ "$output" != *"fam-b"* ]]
}

# ===========================================================================
# 5. versions.yaml pin resolution — `@versions:<key>` -> pin from versions.yaml.
# ===========================================================================

@test "resolve: @versions:srtla defer token resolves to versions.yaml pin" {
  expected="$(get_pin srtla)"
  [ -n "$expected" ]   # guard: the fixture under test must actually have a pin

  stub="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$stub/manifests/boards" "$stub/manifests/families" \
           "$stub/manifests/schema" "$stub/lib"
  cp "$COMMON_SH" "$RESOLVE_SH" "$RESOLVE_PY" "$stub/lib/"
  # Permissive schemas isolate the defer mechanism from field-shape rules.
  echo '{"type":"object"}' > "$stub/manifests/schema/board.schema.json"
  echo '{"type":"object"}' > "$stub/manifests/schema/family.schema.json"
  cat > "$stub/manifests/families/pinfam.yaml" <<'YAML'
framework_pin: "@versions:srtla"
shared: from-family
YAML
  cat > "$stub/manifests/boards/pinboard.yaml" <<'YAML'
family: pinfam
shared: from-board
YAML

  run env VERSIONS_YAML="$VERSIONS_YAML" "$stub/lib/resolve.sh" pinboard
  [ "$status" -eq 0 ]
  [[ "$output" == *"FRAMEWORK_PIN='${expected}'"* ]]
  # and the full path still applies board precedence
  [[ "$output" == *"SHARED='from-board'"* ]]
}

@test "resolve: absent defer pin fails loudly (no half-resolved token)" {
  stub="$BATS_TEST_TMPDIR/stub2"
  mkdir -p "$stub/manifests/boards" "$stub/manifests/families" \
           "$stub/manifests/schema" "$stub/lib"
  cp "$COMMON_SH" "$RESOLVE_SH" "$RESOLVE_PY" "$stub/lib/"
  echo '{"type":"object"}' > "$stub/manifests/schema/board.schema.json"
  echo '{"type":"object"}' > "$stub/manifests/schema/family.schema.json"
  cat > "$stub/manifests/families/pinfam.yaml" <<'YAML'
framework_pin: "@versions:does-not-exist"
YAML
  cat > "$stub/manifests/boards/pinboard.yaml" <<'YAML'
family: pinfam
YAML

  run env VERSIONS_YAML="$VERSIONS_YAML" "$stub/lib/resolve.sh" pinboard
  [ "$status" -ne 0 ]
  [[ "$output" == *"does-not-exist"* ]]
}

# ===========================================================================
# 6. common.sh strict-fail — die / err_trap / require_cmd all fail loudly.
# ===========================================================================

@test "common.sh: die exits non-zero with the message on stderr" {
  run bash -c "source '$COMMON_SH'; die 'test error' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"test error"* ]]
}

@test "common.sh: err_trap fires on an unguarded non-zero command" {
  run bash -c "source '$COMMON_SH'; false; echo SHOULD_NOT_PRINT 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" != *"SHOULD_NOT_PRINT"* ]]
  [[ "$output" == *"ERROR at"* ]]
}

@test "common.sh: require_cmd dies on a missing command" {
  run bash -c "source '$COMMON_SH'; require_cmd definitely-not-a-real-cmd-xyz 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

# ===========================================================================
# 7. postinst dual-track drift gate (Task 6) — the consolidated runtime-config
#    logic lives ONCE in customize/postinst-lib.sh, sourced by both the runtime
#    executor (mkosi.postinst.chroot) and the customize modules. The gate fails if
#    that single-source property breaks (a function re-inlined, a track no longer
#    sourcing the lib, the §6 SRTLA payloads diverging, or postinst regrowing past
#    its ceiling). Pure static analysis — no chroot/build — so it fits this suite.
# ===========================================================================

@test "postinst drift: clean tree has no dual-track drift (single source of truth)" {
  run bash "$V2/ci/postinst-drift-check.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RESULT: no drift"* ]]
  [[ "$output" != *"FAIL"* ]]
}

@test "postinst drift: gate CATCHES a re-inlined consolidated function (non-vacuity)" {
  local postinst="$V2/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"
  local backup="$BATS_TEST_TMPDIR/postinst.bak"
  cp "$postinst" "$backup"
  # Re-introduce the exact dual-track hazard the consolidation removed: an inline
  # twin of a consolidated function in the runtime executor.
  printf '\nsetup_data_persistence() { log "re-inlined twin (drift)"; }\n' >> "$postinst"
  run bash "$V2/ci/postinst-drift-check.sh"
  cp "$backup" "$postinst"          # ALWAYS restore, pass or fail
  [ "$status" -ne 0 ]
  [[ "$output" == *"RE-INLINED"* ]]
  [[ "$output" == *"setup_data_persistence"* ]]
}

@test "postinst drift: gate CATCHES a divergent §6 SRTLA payload (non-vacuity)" {
  local netsrtla="$V2/mkosi/customize/networking-srtla.sh"
  local backup="$BATS_TEST_TMPDIR/networking-srtla.bak"
  cp "$netsrtla" "$backup"
  # Diverge one inline copy of the dual-track SRTLA routing payload.
  sed -i 's/^110[[:space:]]\+wlan_bond$/111     wlan_bond/' "$netsrtla"
  run bash "$V2/ci/postinst-drift-check.sh"
  cp "$backup" "$netsrtla"          # ALWAYS restore
  [ "$status" -ne 0 ]
  [[ "$output" == *"DIVERGED"* ]]
}
