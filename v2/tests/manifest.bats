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
  MEASURE_SH="$LIB_DIR/measure-size.sh"
  FETCH_DEBS="$LIB_DIR/fetch-debs.sh"
  BSP_BASELINE_JSON="$V2/manifests/bsp-baseline.json"
  SIZE_BUDGET_JSON="$V2/manifests/size-budget.json"
  QEMU_X86="$TESTS_DIR/qemu-x86.sh"
  SCHEMA_DIR="$V2/manifests/schema"
  FAMILY_SCHEMA="$SCHEMA_DIR/family.schema.json"
  BOARD_SCHEMA="$SCHEMA_DIR/board.schema.json"
  ADDON_SCHEMA="$SCHEMA_DIR/addon.schema.json"
  VALIDATE_PY="$V2/ci/validate-manifests.py"
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

# write_addon <dir> <id> <conflicts-json-array> <provides-path>
# Emit a minimal, schema-valid add-on descriptor into <dir>/<id>.json so the E6
# collision tests can compose conflict scenarios without shipping fixtures that
# would themselves trip the shipped-tree validator.
write_addon() {
  local dir="$1" id="$2" conflicts="$3" provides="$4"
  cat > "$dir/$id.json" <<JSON
{
  "id": "$id", "name": "$id", "version": "1.0.0", "category": "other",
  "payload": { "type": "sysext" }, "sysextLevel": "1", "versionId": "12",
  "compatibleOsVersions": ["12"],
  "artifact": {
    "urlTemplate": "https://apt.ceralive.tv/addons/$id/{os_version}/$id.raw",
    "sha256": "d0009ed268df5fd0ec12904201c64be392f56671a4d61acec7355188536bb5e9",
    "gpgSigRef": "https://apt.ceralive.tv/addons/$id/{os_version}/$id.raw.asc",
    "sizeDownload": 1024, "sizeInstalled": 2048
  },
  "provides": ["$provides"],
  "conflicts": $conflicts
}
JSON
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

@test "valid: shipped orange-pi-5-plus board validates against board schema" {
  run validate_manifest "$V2/manifests/boards/orange-pi-5-plus.yaml" "$BOARD_SCHEMA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"VALID"* ]]
}

@test "valid: shipped x86_64 family validates against family schema" {
  run validate_manifest "$V2/manifests/families/x86_64.yaml" "$FAMILY_SCHEMA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"VALID"* ]]
}

@test "valid: shipped x86-minipc board validates against board schema" {
  run validate_manifest "$V2/manifests/boards/x86-minipc.yaml" "$BOARD_SCHEMA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"VALID"* ]]
}

@test "valid: EVERY shipped manifest validates (no un-checked manifest ships)" {
  local f rc=0
  for f in "$V2"/manifests/families/*.yaml; do
    run validate_manifest "$f" "$FAMILY_SCHEMA"
    [ "$status" -eq 0 ] || { echo "family failed: $f"; echo "$output"; rc=1; }
  done
  for f in "$V2"/manifests/boards/*.yaml; do
    run validate_manifest "$f" "$BOARD_SCHEMA"
    [ "$status" -eq 0 ] || { echo "board failed: $f"; echo "$output"; rc=1; }
  done
  [ "$rc" -eq 0 ]
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

@test "invalid: family with EMPTY firmware_packages fails and names firmware_packages" {
  # orchestrate.sh require_field's FIRMWARE_PACKAGES — the expanded schema's
  # minItems:1 catches an empty set at VALIDATION, not at build (the whole point).
  run validate_manifest "$FIXTURES/invalid-family-empty-firmware.yaml" "$FAMILY_SCHEMA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"firmware_packages"* ]]
}

@test "invalid: family with malformed Debian package name fails and names kernel_packages" {
  run validate_manifest "$FIXTURES/invalid-family-bad-pkg-name.yaml" "$FAMILY_SCHEMA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"kernel_packages"* ]]
}

@test "invalid: board missing required dtb_name fails and names dtb_name" {
  run validate_manifest "$FIXTURES/invalid-board-missing-dtb_name.yaml" "$BOARD_SCHEMA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"dtb_name"* ]]
}

@test "valid: board with an interfaces identity map passes board schema" {
  run validate_manifest "$FIXTURES/valid-board-interfaces.yaml" "$BOARD_SCHEMA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"VALID"* ]]
}

@test "invalid: board with an unknown interfaces key fails and names interfaces" {
  run validate_manifest "$FIXTURES/invalid-board-bad-interface-key.yaml" "$BOARD_SCHEMA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"interfaces"* ]]
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
# 7. x86 boot fallback — a forced primary-slot failure rolls back to the known-
#    good slot. The qemu-x86 harness' --fallback-selftest drives the SHIPPED x86
#    grubenv A/B engine (no qemu/GRUB/root); a green run is the proof. Engine-only
#    (no image boot), so it fits this UNIT suite.
# ===========================================================================

@test "x86 fallback: forced primary-slot failure rolls back to the known-good slot" {
  run env CERALIVE_QEMU_FALLBACK_SELFTEST=1 bash "$QEMU_X86"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ROLLBACK: forced A failure fell back to known-good slot B"* ]]
  [[ "$output" == *"QEMU x86 VALIDATION OK"* ]]
  [[ "$output" != *"FAIL"* ]]
}

# ===========================================================================
# 8. postinst dual-track drift gate (Task 6) — the consolidated runtime-config
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
  sed -i 's/^120[[:space:]]\+wlan0$/121     wlan0/' "$netsrtla"
  run bash "$V2/ci/postinst-drift-check.sh"
  cp "$backup" "$netsrtla"          # ALWAYS restore
  [ "$status" -ne 0 ]
  [[ "$output" == *"DIVERGED"* ]]
}

# ===========================================================================
# 8b. First-boot WiFi provisioning captive portal (Task 14).
#     The offline proof harness stubs nmcli/ip/systemctl/systemd-run and drives the
#     real ceralive-provision.sh + ceralive-portal.sh through bring-up, the GET/POST
#     captive page, the credential handoff, and the four-condition MAC6 teardown
#     (incl. wrong-passphrase retry + hard-timeout return-to-AP). No radio/systemd
#     needed, so it fits this static suite.
# ===========================================================================

@test "provision portal: offline harness proves the 4-condition teardown + handoff" {
  run bash "$TESTS_DIR/provision-portal.test.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
  # The fail() marker is "  FAIL  " (two-space framed); match that, not the word
  # "FAILURE" that legitimately appears in a scenario header.
  [[ "$output" != *"  FAIL  "* ]]
}

# ===========================================================================
# 9. Multi-device rootfs non-regression + x86 disk-path guard (Task 14).
#    All three shipped boards must drive the orchestrator through to the build
#    plan (the rootfs.tar producer, step 6) without aborting; x86 (efi) must
#    NOT take the RK3588 `custom` .raw path — its disk assembly is deferred.
#
#    These run `DRY_RUN=1` (orchestrate stops at [5/9], before mkosi/Stage-4 —
#    no network, no qemu, no privileged container) with INSTALL_BOOT_BSP=0
#    (offline host stages no BSP .debs; the default BSP=1 path aborts at the
#    require_field / missing-BSP gate, which is a SEPARATE guard tested by the
#    pipeline itself, not what Task 14 verifies). Reaching the DRY-RUN banner
#    proves resolve + fetch-plan + every pre-mkosi gate passed for that board.
# ===========================================================================

@test "t14 rootfs: rock-5b-plus reaches the build plan (exit 0, custom/rk3588)" {
  run env INSTALL_BOOT_BSP=0 DRY_RUN=1 bash "$V2/build" rock-5b-plus
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN complete"* ]]
}

@test "t14 rootfs: orange-pi-5-plus reaches the build plan (exit 0, custom/rk3588)" {
  run env INSTALL_BOOT_BSP=0 DRY_RUN=1 bash "$V2/build" orange-pi-5-plus
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN complete"* ]]
}

@test "t14 rootfs: x86-minipc reaches the build plan (exit 0, efi)" {
  run env INSTALL_BOOT_BSP=0 DRY_RUN=1 bash "$V2/build" x86-minipc
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN complete"* ]]
}

@test "t14 x86 guard: x86-minipc DRY_RUN emits no .raw (resolve+plan only, before Stage-4)" {
  run env INSTALL_BOOT_BSP=0 DRY_RUN=1 bash "$V2/build" x86-minipc
  [ "$status" -eq 0 ]
  # DRY_RUN stops at [5/9], before ANY board reaches Stage-4 disk assembly, so no
  # artifact is written (the preview contract). x86 disk assembly itself is now WIRED
  # (lib/assemble-disk-x86.sh) and exercised by the x86-grub test below.
  local raws=()
  if [[ -d "$V2/images/x86-minipc" ]]; then
    while IFS= read -r f; do raws+=("$f"); done \
      < <(find "$V2/images/x86-minipc" -maxdepth 1 -type f -name '*.raw')
  fi
  [ "${#raws[@]}" -eq 0 ]
}

@test "t14 x86 guard: resolved adapter routes x86 to efi, rk3588 to custom (non-vacuity)" {
  run "$RESOLVE_SH" x86-minipc
  [ "$status" -eq 0 ]
  [[ "$output" == *"RAUC_BOOTLOADER_ADAPTER='efi'"* ]]
  run "$RESOLVE_SH" rock-5b-plus
  [ "$status" -eq 0 ]
  [[ "$output" == *"RAUC_BOOTLOADER_ADAPTER='custom'"* ]]
}

@test "t14 x86 guard: orchestrate.sh wires the x86 ESP/GRUB disk path (TODO(x86-disk) closed)" {
  local orch="$V2/lib/orchestrate.sh"
  # Task 12 closed the deferral: the former active TODO(x86-disk) marker is GONE.
  ! grep -q 'TODO(x86-disk)' "$orch"
  # Each adapter has exactly ONE .raw producer under its own branch: RK3588 custom
  # -> assemble-disk.sh, x86 efi/grub -> assemble-disk-x86.sh.
  [ "$(grep -c 'ASSEMBLE_DISK_SH}" build' "$orch")" -eq 1 ]
  [ "$(grep -c 'ASSEMBLE_DISK_X86_SH}" build' "$orch")" -eq 1 ]
}

# ===========================================================================
# 9b. x86 RAUC-native bootloader=grub disk-path artifacts (Task 12). The shipped
#     installer (install-x86-grub.sh) renders the bootloader=grub system.conf, the
#     grub.cfg ORDER/OK/TRY selector, and the seeded grubenv; test-x86-grub.sh
#     drives it offline (no qemu/GRUB/root/image) and proves the slot-switch
#     contract (flip grubenv ORDER -> the OTHER slot is selected). Engine/artifact
#     only, so it fits this UNIT suite.
# ===========================================================================

@test "x86 grub: bootloader=grub system.conf + grub.cfg selector + grubenv slot-switch (selects B)" {
  run bash "$V2/mkosi/platform/x86/test-x86-grub.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"switched selection is 'B rootfs_b'"* ]]
  [[ "$output" == *"X86-GRUB TEST OK"* ]]
  [[ "$output" != *"FAIL"* ]]
}

# ===========================================================================
# 10. Size-gate measurement scaffolding (Task 8) — REPORT-ONLY.
#     measure-size.sh sizes rootfs CONTENT (du --apparent-size -sb on the
#     artifact/tree, NOT the frozen 4096 MB partition — G4/E5) and compares it to
#     manifests/size-budget.json. While every rootfs_bytes_max is null the gate
#     only REPORTS (prints measured vs budget, exits 0). Pure static measurement —
#     no chroot/build/mount — so it fits this UNIT suite. Task 20 flips it to
#     blocking by setting a non-null threshold; the enforcement branch is proven
#     here so that flip stays a one-line manifest edit.
# ===========================================================================

@test "size-budget: every shipped board carries a positive-integer blocking ceiling (Task-20 flip landed)" {
  run python3 - "$SIZE_BUDGET_JSON" "$V2/manifests/boards" <<'PY'
import json, sys
from pathlib import Path

budget = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert isinstance(budget, dict), "root must be an object"
boards = {p.stem for p in Path(sys.argv[2]).glob("*.yaml")}
entries = {k: v for k, v in budget.items() if not k.startswith("_")}
missing = boards - set(entries)
assert not missing, "boards missing a size-budget entry: %s" % sorted(missing)
for name, entry in entries.items():
    limit = entry.get("rootfs_bytes_max")
    assert isinstance(limit, int) and not isinstance(limit, bool) and limit > 0, (
        "%s: rootfs_bytes_max must be a positive int (blocking), got %r" % (name, limit)
    )
print("BUDGET-OK")
PY
  [ "$status" -eq 0 ]
  [[ "$output" == *"BUDGET-OK"* ]]
}

@test "size-gate: a null budget is report-only (retained path for newly-added boards) and exits 0" {
  local tree="$BATS_TEST_TMPDIR/rootfs"
  mkdir -p "$tree"
  head -c 4096 /dev/zero > "$tree/a.bin"
  local nullbudget="$BATS_TEST_TMPDIR/null-budget.json"
  printf '{ "rock-5b-plus": { "rootfs_bytes_max": null, "measured": null } }\n' > "$nullbudget"
  run env SIZE_BUDGET_JSON="$nullbudget" "$MEASURE_SH" rock-5b-plus "$tree"
  [ "$status" -eq 0 ]
  [[ "$output" =~ measured=[0-9]+\ budget=null\ \(report-only\) ]]
}

@test "size-gate: apparent-size measurement is deterministic (identical bytes across runs)" {
  local tree="$BATS_TEST_TMPDIR/rootfs-det"
  mkdir -p "$tree/sub"
  head -c 8192 /dev/zero > "$tree/a.bin"
  head -c 333  /dev/zero > "$tree/sub/b.bin"
  run "$MEASURE_SH" rock-5b-plus "$tree"
  [ "$status" -eq 0 ]
  local first="${output%% *}"          # "measured=<N>"
  run "$MEASURE_SH" rock-5b-plus "$tree"
  [ "$status" -eq 0 ]
  [[ "${output%% *}" == "$first" ]]
}

@test "size-gate: malformed size-budget.json fails loudly (non-vacuity negative)" {
  local tree="$BATS_TEST_TMPDIR/rootfs-bad"
  mkdir -p "$tree"
  head -c 16 /dev/zero > "$tree/a.bin"
  local bad="$BATS_TEST_TMPDIR/bad-budget.json"
  printf '{ this is not json\n' > "$bad"
  run env SIZE_BUDGET_JSON="$bad" "$MEASURE_SH" rock-5b-plus "$tree"
  [ "$status" -ne 0 ]
  [[ "$output" == *"malformed size-budget.json"* ]]
}

@test "size-gate: unknown board fails loudly (no silent pass on a missing budget)" {
  local tree="$BATS_TEST_TMPDIR/rootfs-unknown"
  mkdir -p "$tree"
  head -c 16 /dev/zero > "$tree/a.bin"
  run "$MEASURE_SH" definitely-not-a-board "$tree"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no size budget entry"* ]]
}

@test "size-gate: a non-null budget enforces (over-budget fails) — proves Task-20 flip works" {
  local tree="$BATS_TEST_TMPDIR/rootfs-enf"
  mkdir -p "$tree"
  head -c 65536 /dev/zero > "$tree/big.bin"   # ~64 KiB of content
  local tight="$BATS_TEST_TMPDIR/tight-budget.json"
  printf '{ "rock-5b-plus": { "rootfs_bytes_max": 1024, "measured": null } }\n' > "$tight"
  run env SIZE_BUDGET_JSON="$tight" "$MEASURE_SH" rock-5b-plus "$tree"
  [ "$status" -ne 0 ]
  [[ "$output" == *"exceeds budget"* ]]
}

@test "size-gate: a generous non-null budget passes and reports 'enforced'" {
  local tree="$BATS_TEST_TMPDIR/rootfs-ok"
  mkdir -p "$tree"
  head -c 256 /dev/zero > "$tree/small.bin"
  local roomy="$BATS_TEST_TMPDIR/roomy-budget.json"
  printf '{ "rock-5b-plus": { "rootfs_bytes_max": 1073741824, "measured": null } }\n' > "$roomy"
  run env SIZE_BUDGET_JSON="$roomy" "$MEASURE_SH" rock-5b-plus "$tree"
  [ "$status" -eq 0 ]
  [[ "$output" =~ measured=[0-9]+\ budget=1073741824\ \(enforced\) ]]
}

@test "size-gate: the COMMITTED size-budget.json enforces (non-null) for every shipped board" {
  local tree="$BATS_TEST_TMPDIR/rootfs-committed"
  mkdir -p "$tree"
  head -c 4096 /dev/zero > "$tree/a.bin"
  for board in orange-pi-5-plus rock-5b-plus x86-minipc; do
    run "$MEASURE_SH" "$board" "$tree"
    [ "$status" -eq 0 ]
    [[ "$output" =~ measured=[0-9]+\ budget=[0-9]+\ \(enforced\) ]]
    [[ "$output" != *"report-only"* ]]
  done
}

@test "size-gate: a tree over the COMMITTED ceiling fails the gate (sparse 2 GiB > 1.5 GB budget)" {
  local tree="$BATS_TEST_TMPDIR/rootfs-over"
  mkdir -p "$tree"
  truncate -s 2G "$tree/oversize.img"
  run "$MEASURE_SH" rock-5b-plus "$tree"
  [ "$status" -ne 0 ]
  [[ "$output" == *"exceeds budget"* ]]
}

# ===========================================================================
# 11. Reproducible builds (Task 14) — a double-build of the SAME inputs yields a
#     BIT-IDENTICAL signed .raucb. build-bundle.sh clamps every embedded mtime to
#     SOURCE_DATE_EPOCH (rootfs.tar + squashfs) and signs the CMS without the
#     wall-clock signingTime attribute — the only non-determinism real `rauc`
#     cannot suppress — so two runs collide on sha256. A mock rootfs (no
#     mkosi/network/board) keeps it in this UNIT suite while exercising the REAL
#     bundle assembly + RSA signing chain against the committed dev PKI.
# ===========================================================================

# repro_prereqs — the deterministic signer needs mksquashfs + openssl + the dev
# PKI. Anything missing → the test SKIPs (still green) rather than false-fails.
repro_prereqs() {
  command -v mksquashfs >/dev/null 2>&1 || return 1
  command -v openssl    >/dev/null 2>&1 || return 1
  [ -s "$V2/.dev-keys/leaf-signing.key" ] || return 1
  return 0
}

# build_repro_bundle <out-dir> <source-date-epoch> — build the SAME mock rootfs
# into <out-dir> with a fixed compatible/version/ts. Echoes nothing; the bundle
# lands at <out-dir>/fixed.raucb.
build_repro_bundle() {
  local out="$1" sde="$2"
  local tree="$BATS_TEST_TMPDIR/repro-tree"
  if [ ! -d "$tree" ]; then
    mkdir -p "$tree/etc" "$tree/usr/bin"
    printf 'ceralive\n' > "$tree/etc/hostname"
    printf 'bin\n'      > "$tree/usr/bin/app"
  fi
  rm -rf "$out"; mkdir -p "$out"
  env CERALIVE_RAUC_PKI_DIR="$V2/.dev-keys" \
      COMPATIBLE_STRING="ceralive-rock-5b-plus" \
      BUNDLE_VERSION="reprotest" BUNDLE_TS="fixed" BUNDLE_OUT_DIR="$out" \
      SOURCE_DATE_EPOCH="$sde" \
      bash "$V2/lib/build-bundle.sh" rock-5b-plus "$tree" >/dev/null 2>&1
}

@test "repro: double-build of rock-5b-plus yields a bit-identical .raucb (same sha256)" {
  repro_prereqs || skip "mksquashfs/openssl/dev-PKI not available"
  build_repro_bundle "$BATS_TEST_TMPDIR/r1" 1700000000
  build_repro_bundle "$BATS_TEST_TMPDIR/r2" 1700000000
  [ -f "$BATS_TEST_TMPDIR/r1/fixed.raucb" ]
  [ -f "$BATS_TEST_TMPDIR/r2/fixed.raucb" ]
  local h1 h2
  h1="$(sha256sum "$BATS_TEST_TMPDIR/r1/fixed.raucb" | cut -d' ' -f1)"
  h2="$(sha256sum "$BATS_TEST_TMPDIR/r2/fixed.raucb" | cut -d' ' -f1)"
  [ -n "$h1" ]
  [ "$h1" = "$h2" ]
}

@test "repro: the reproducible bundle still verifies leaf->intermediate->root (signing not faked)" {
  repro_prereqs || skip "mksquashfs/openssl/dev-PKI not available"
  local tree="$BATS_TEST_TMPDIR/repro-vtree"; mkdir -p "$tree/etc"
  printf 'x\n' > "$tree/etc/hostname"
  local out="$BATS_TEST_TMPDIR/rv"; mkdir -p "$out"
  run env CERALIVE_RAUC_PKI_DIR="$V2/.dev-keys" \
      COMPATIBLE_STRING="ceralive-rock-5b-plus" \
      BUNDLE_VERSION="reprotest" BUNDLE_TS="fixed" BUNDLE_OUT_DIR="$out" \
      SOURCE_DATE_EPOCH=1700000000 \
      bash "$V2/lib/build-bundle.sh" rock-5b-plus "$tree"
  [ "$status" -eq 0 ]
  [[ "$output" == *"signature verified: leaf -> intermediate -> root"* ]]
  [ -f "$out/fixed.raucb" ]
}

@test "repro: changing SOURCE_DATE_EPOCH changes the artifact (test has teeth / not vacuous)" {
  repro_prereqs || skip "mksquashfs/openssl/dev-PKI not available"
  build_repro_bundle "$BATS_TEST_TMPDIR/t1" 1700000000
  build_repro_bundle "$BATS_TEST_TMPDIR/t2" 1800000000
  local h1 h2
  h1="$(sha256sum "$BATS_TEST_TMPDIR/t1/fixed.raucb" | cut -d' ' -f1)"
  h2="$(sha256sum "$BATS_TEST_TMPDIR/t2/fixed.raucb" | cut -d' ' -f1)"
  [ -n "$h1" ]
  [ "$h1" != "$h2" ]
}

# ===========================================================================
# 12. Bounded-parallel multi-board runner (Task 12) — lib/build-all.sh.
#     Two guards:
#       * REGRESSION: `build --all` under DRY_RUN=1 still resolves the full board
#         list and exits 0 BEFORE the runner is reached (the preview contract the
#         runner must not break).
#       * AGGREGATE + ISOLATION: build-all.sh run directly against a STUB
#         orchestrator (no real mkosi/network/board) — one board passes, one
#         fails. The overall run must exit non-zero (failure never masked), yet
#         the passing board must still complete with its OWN log file (no early
#         abort, logs not interleaved). A stub keeps this in the UNIT suite.
# ===========================================================================

@test "t12 parallel: build --all under DRY_RUN=1 exits 0 and prints the resolved board list" {
  run env DRY_RUN=1 bash "$V2/build" --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY_RUN"* ]]
  # every shipped board manifest must appear in the previewed selection
  local f board
  for f in "$V2"/manifests/boards/*.yaml; do
    board="$(basename "$f" .yaml)"
    [[ "$output" == *"$board"* ]] || { echo "missing board in preview: $board"; false; }
  done
}

@test "t12 parallel: build-all.sh fails overall if any board fails, but the passing board still completes (isolated logs)" {
  local bdir="$BATS_TEST_TMPDIR/boards" ldir="$BATS_TEST_TMPDIR/logs"
  mkdir -p "$bdir" "$ldir"
  # Fixture manifests: content is irrelevant — the STUB orchestrator ignores it,
  # find_manifest only needs the files to exist.
  : > "$bdir/passboard.yaml"
  : > "$bdir/failboard.yaml"

  # STUB orchestrator: echoes a marker (so we can prove the log is its OWN output)
  # and exits non-zero for any board whose name contains 'fail'.
  local stub="$BATS_TEST_TMPDIR/stub-orchestrate.sh"
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
board=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --board)    board="$2"; shift 2 ;;
    --manifest) shift 2 ;;
    *)          shift ;;
  esac
done
echo "stub orchestrator ran for board=${board}"
case "$board" in
  *fail*) echo "stub: simulating failure for ${board}" >&2; exit 7 ;;
  *)      exit 0 ;;
esac
SH
  chmod +x "$stub"

  run env ORCHESTRATOR="$stub" BOARDS_DIR="$bdir" LOGS_DIR="$ldir" JOBS=2 \
    bash "$V2/lib/build-all.sh" passboard failboard

  # A failed board makes the whole run non-zero (aggregate, never swallowed).
  [ "$status" -ne 0 ]
  # Summary table reports BOTH outcomes with the real per-board exit code.
  [[ "$output" == *"passboard"* ]]
  [[ "$output" == *"failboard"* ]]
  [[ "$output" == *"FAIL(7)"* ]]
  [[ "$output" == *"board(s) FAILED"* ]]

  # The passing board completed despite the other's failure: its OWN log exists
  # and carries the stub's stdout (per-board isolation, not interleaved).
  local passlog faillog
  passlog="$(echo "$ldir"/passboard-*.log)"
  faillog="$(echo "$ldir"/failboard-*.log)"
  [ -f "$passlog" ]
  [ -f "$faillog" ]
  grep -q "stub orchestrator ran for board=passboard" "$passlog"
  # the failing board's stderr was captured into ITS log, not the passing one
  grep -q "simulating failure for failboard" "$faillog"
  ! grep -q "failboard" "$passlog"
}

# ===========================================================================
# 13. Add-on descriptor format + conflict model (Task 21).
#     addon.schema.json is the per-descriptor gate: G1 sysext merge identity
#     (sysextLevel const "1", versionId const "12") and G2 the /usr+/opt-only
#     provides[] boundary. validate-manifests.py layers the cross-descriptor E6
#     model on top: no two add-ons may claim the same provides[] path unless they
#     mutually declare each other in conflicts[] (the provides/conflicts model).
#     Pure static validation (no image, no sysext merge) so it fits this UNIT
#     suite.
# ===========================================================================

@test "schema: addon.schema.json is a valid draft-2020-12 schema" {
  run check_schema_metaschema "$ADDON_SCHEMA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SCHEMA-OK"* ]]
}

@test "valid: shipped debug-toolset descriptor validates against addon schema" {
  run validate_manifest "$V2/manifests/addons/debug-toolset.json" "$ADDON_SCHEMA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"VALID"* ]]
}

@test "addon: validate-manifests.py passes clean on the shipped descriptors (exit 0)" {
  run bash -c "python3 '$VALIDATE_PY' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"debug-toolset.json"* ]]
  [[ "$output" == *"0 errors"* ]]
}

@test "invalid: addon with an /etc path in provides[] is REJECTED (G2), names provides" {
  run validate_manifest "$FIXTURES/invalid-addon-etc-provides.json" "$ADDON_SCHEMA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"provides"* ]]
}

@test "invalid: addon missing sysextLevel is REJECTED (G1), names sysextLevel" {
  run validate_manifest "$FIXTURES/invalid-addon-missing-sysextlevel.json" "$ADDON_SCHEMA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"sysextLevel"* ]]
}

@test "addon conflict: two descriptors claiming the same provides[] path are flagged (E6)" {
  local adir="$BATS_TEST_TMPDIR/addons-collide"
  mkdir -p "$adir"
  write_addon "$adir" addon-a '[]' "/usr/bin/shared-tool"
  write_addon "$adir" addon-b '[]' "/usr/bin/shared-tool"
  run bash -c "ADDONS_DIR='$adir' python3 '$VALIDATE_PY' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"collision"* ]]
  [[ "$output" == *"/usr/bin/shared-tool"* ]]
}

@test "addon conflict: a shared provides[] path is ALLOWED when both declare mutual conflicts[] (provides/conflicts model)" {
  local adir="$BATS_TEST_TMPDIR/addons-resolved"
  mkdir -p "$adir"
  write_addon "$adir" addon-a '["addon-b"]' "/usr/bin/shared-tool"
  write_addon "$adir" addon-b '["addon-a"]' "/usr/bin/shared-tool"
  run bash -c "ADDONS_DIR='$adir' python3 '$VALIDATE_PY' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 errors"* ]]
  [[ "$output" != *"collision"* ]]
}

# ===========================================================================
# 14. Signed per-board/per-OS feature sysext build (Task 24).
#     lib/build-feature-sysext.sh turns a .deb staging tree into a SIGNED add-on
#     sysext: <feature>-<board>-<os>.raw + .raw.sha256 + .raw.sig, verifiable with
#     gpgv against the image-baked add-on PUBLIC keyring. Guards proven here:
#       * artifact set + sha256 integrity + GPG authenticity (gpgv OK)
#       * G1 — the produced extension-release carries SYSEXT_LEVEL=1 + VERSION_ID=12
#       * G2 — a staging tree with /etc (escapes the /usr+/opt boundary) is REFUSED
#       * tamper — a flipped byte in the .raw makes gpgv FAIL (signing has teeth)
#       * the baked keyring is PUBLIC-only and a DISTINCT trust domain from RAUC
#     Hermetic: a throwaway gpg home under BATS_FILE_TMPDIR signs the fixture, so
#     the suite never touches the repo dev keys. Skips (still green) if the signing
#     toolchain (mksquashfs/gpg/gpgv/unsquashfs) is unavailable on the host.
# ===========================================================================

# feature_prereqs — the signer needs mksquashfs + gpg + gpgv + unsquashfs.
feature_prereqs() {
  command -v mksquashfs >/dev/null 2>&1 || return 1
  command -v gpg        >/dev/null 2>&1 || return 1
  command -v gpgv       >/dev/null 2>&1 || return 1
  command -v unsquashfs >/dev/null 2>&1 || return 1
  return 0
}

# build_feature_fixture — build a sample signed feature sysext ONCE per file into
# BATS_FILE_TMPDIR, signed by a throwaway gpg home (NOT the repo dev keys). Echoes
# nothing; idempotent — later tests reuse the produced artifacts.
build_feature_fixture() {
  local out="$BATS_FILE_TMPDIR/out"
  local raw="$out/demo-feature-rock-5b-plus-12.raw"
  [ -f "$raw" ] && return 0
  local stg="$BATS_FILE_TMPDIR/staging"
  mkdir -p "$stg/usr/bin" "$stg/opt/demo"
  printf '#!/bin/sh\necho hi\n' > "$stg/usr/bin/demo-tool"
  printf 'payload\n'            > "$stg/opt/demo/data.txt"
  bash "$LIB_DIR/build-feature-sysext.sh" \
    --feature demo-feature --board rock-5b-plus --os-version 12 \
    --deb-staging "$stg" --out "$out" \
    --keyring "$BATS_FILE_TMPDIR/gnupg" >/dev/null 2>&1
}

@test "t24 sysext: build emits .raw + .raw.sha256 + .raw.sig + addon-keyring.gpg" {
  feature_prereqs || skip "mksquashfs/gpg/gpgv/unsquashfs not available"
  build_feature_fixture
  local out="$BATS_FILE_TMPDIR/out"
  [ -f "$out/demo-feature-rock-5b-plus-12.raw" ]
  [ -f "$out/demo-feature-rock-5b-plus-12.raw.sha256" ]
  [ -f "$out/demo-feature-rock-5b-plus-12.raw.sig" ]
  [ -f "$out/addon-keyring.gpg" ]
}

@test "t24 sysext: sha256 sidecar matches the produced .raw" {
  feature_prereqs || skip "signing toolchain not available"
  build_feature_fixture
  local out="$BATS_FILE_TMPDIR/out"
  run bash -c "cd '$out' && sha256sum -c demo-feature-rock-5b-plus-12.raw.sha256"
  [ "$status" -eq 0 ]
  [[ "$output" == *": OK"* ]]
}

@test "t24 sysext: detached signature verifies against the baked add-on keyring (gpgv OK)" {
  feature_prereqs || skip "signing toolchain not available"
  build_feature_fixture
  local out="$BATS_FILE_TMPDIR/out"
  run gpgv --keyring "$out/addon-keyring.gpg" \
        "$out/demo-feature-rock-5b-plus-12.raw.sig" \
        "$out/demo-feature-rock-5b-plus-12.raw"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Good signature"* ]]
}

@test "t24 sysext G1: produced extension-release carries SYSEXT_LEVEL=1 + VERSION_ID=12" {
  feature_prereqs || skip "signing toolchain not available"
  build_feature_fixture
  local out="$BATS_FILE_TMPDIR/out"
  run unsquashfs -no-progress -cat \
        "$out/demo-feature-rock-5b-plus-12.raw" \
        usr/lib/extension-release.d/extension-release.demo-feature
  [ "$status" -eq 0 ]
  [[ "$output" == *"SYSEXT_LEVEL=1"* ]]
  [[ "$output" == *"VERSION_ID=12"* ]]
}

@test "t24 sysext G2: a staging tree with /etc is REFUSED (escapes /usr+/opt boundary)" {
  feature_prereqs || skip "signing toolchain not available"
  local stg="$BATS_TEST_TMPDIR/g2-staging" out="$BATS_TEST_TMPDIR/g2-out"
  mkdir -p "$stg/usr/bin" "$stg/etc"
  printf 'x\n'   > "$stg/usr/bin/t"
  printf 'cfg\n' > "$stg/etc/foo.conf"
  run bash "$LIB_DIR/build-feature-sysext.sh" \
        --feature bad --board rock-5b-plus --os-version 12 \
        --deb-staging "$stg" --out "$out" --keyring "$BATS_FILE_TMPDIR/gnupg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"G2 boundary"* ]]
  [ ! -f "$out/bad-rock-5b-plus-12.raw" ]
}

@test "t24 sysext tamper: a flipped byte in the .raw makes gpgv FAIL (signing has teeth)" {
  feature_prereqs || skip "signing toolchain not available"
  build_feature_fixture
  local out="$BATS_FILE_TMPDIR/out"
  local tampered="$BATS_TEST_TMPDIR/tampered.raw"
  cp "$out/demo-feature-rock-5b-plus-12.raw" "$tampered"
  printf '\xff' | dd of="$tampered" bs=1 seek=64 count=1 conv=notrunc 2>/dev/null
  run gpgv --keyring "$out/addon-keyring.gpg" \
        "$out/demo-feature-rock-5b-plus-12.raw.sig" "$tampered"
  [ "$status" -ne 0 ]
  [[ "$output" != *"Good signature"* ]]
}

@test "t24 keyring: committed baked add-on keyring exists and is PUBLIC-only (no secret packets)" {
  command -v gpg >/dev/null 2>&1 || skip "gpg not available"
  local baked="$V2/mkosi/runtime/addon-keyring/addon-keyring.gpg"
  [ -s "$baked" ]
  # It must be a usable OpenPGP public keyring...
  run gpg --show-keys --with-colons "$baked"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\npub:'* || "$output" == pub:* ]]
  # ...and must NOT carry any secret-key material (a device only verifies).
  run gpg --list-packets "$baked"
  [ "$status" -eq 0 ]
  [[ "$output" != *"secret key"* ]]
  ! grep -aq 'PRIVATE KEY' "$baked"
}

@test "t24 keyring: add-on keyring is a DISTINCT trust domain from the RAUC keyring" {
  local baked="$V2/mkosi/runtime/addon-keyring/addon-keyring.gpg"
  local rauc="$V2/mkosi/runtime/rauc/ceralive-keyring.pem"
  [ -s "$baked" ]
  [ -s "$rauc" ]
  # Different files, different bytes — add-on signing never reuses the RAUC anchor.
  run cmp -s "$baked" "$rauc"
  [ "$status" -ne 0 ]
}

# ===========================================================================
# 15. BSP provenance + advisory kernel drift-guard (Task 3).
#     fetch-debs.sh records the floating kernel BSP's resolved version + content
#     sha256 into a gitignored bsp-provenance.json, and runs an ADVISORY drift
#     guard against the committed v2/manifests/bsp-baseline.json. The guard is
#     never fatal (always exit 0); it compares the CONTENT hash (not just the
#     version) so a same-version re-spin is still caught, and seeds the baseline
#     on first run. These tests source the fetch helpers directly (main is
#     BASH_SOURCE-guarded) and drive the guard with synthetic version/hash inputs
#     — no apt, no real .deb — so they fit this UNIT suite.
# ===========================================================================

# Two distinct 64-hex content digests for the drift fixtures.
BSP_SHA_A="1111111111111111111111111111111111111111111111111111111111111111"
BSP_SHA_B="2222222222222222222222222222222222222222222222222222222222222222"

@test "bsp drift: matching version+hash is no-drift (exit 0, no 'BSP drift' banner)" {
  local base="$BATS_TEST_TMPDIR/baseline-match.json"
  printf '{ "schema_version": 1, "package": "linux-image-vendor-rk35xx", "version": "6.1.0-vendor", "sha256": "%s" }\n' "$BSP_SHA_A" > "$base"
  run bash -c "source '$FETCH_DEBS'; bsp_drift_check '$base' linux-image-vendor-rk35xx 6.1.0-vendor $BSP_SHA_A"
  [ "$status" -eq 0 ]
  [[ "$output" != *"BSP drift"* ]]
  [[ "$output" == *"matches known-good baseline"* ]]
}

@test "bsp drift: a version mismatch fires an advisory 'BSP drift' warning (exit 0)" {
  local base="$BATS_TEST_TMPDIR/baseline-ver.json"
  printf '{ "schema_version": 1, "package": "linux-image-vendor-rk35xx", "version": "6.1.0-vendor", "sha256": "%s" }\n' "$BSP_SHA_A" > "$base"
  run bash -c "source '$FETCH_DEBS'; bsp_drift_check '$base' linux-image-vendor-rk35xx 6.1.99-vendor $BSP_SHA_A"
  [ "$status" -eq 0 ]
  [[ "$output" =~ [Dd]rift ]]
  [[ "$output" == *"BSP drift"* ]]
}

@test "bsp drift: SAME version but DIFFERENT content hash still drifts (content-hash compare, exit 0)" {
  local base="$BATS_TEST_TMPDIR/baseline-hash.json"
  printf '{ "schema_version": 1, "package": "linux-image-vendor-rk35xx", "version": "6.1.0-vendor", "sha256": "%s" }\n' "$BSP_SHA_A" > "$base"
  run bash -c "source '$FETCH_DEBS'; bsp_drift_check '$base' linux-image-vendor-rk35xx 6.1.0-vendor $BSP_SHA_B"
  [ "$status" -eq 0 ]
  [[ "$output" =~ [Dd]rift ]]
  # the re-spin note proves the guard compared the hash, not just the version
  [[ "$output" == *"re-spin"* ]]
}

@test "bsp drift: first run with NO baseline seeds it, notes it, exits 0" {
  local base="$BATS_TEST_TMPDIR/seed-me.json"
  [ ! -f "$base" ]
  run bash -c "source '$FETCH_DEBS'; bsp_drift_check '$base' linux-image-vendor-rk35xx 6.1.0-vendor $BSP_SHA_A"
  [ "$status" -eq 0 ]
  [[ "$output" == *"first run"* ]]
  [ -f "$base" ]
  run cat "$base"
  [[ "$output" == *'"version": "6.1.0-vendor"'* ]]
  [[ "$output" == *"$BSP_SHA_A"* ]]
}

@test "bsp drift: an UNSEEDED (null) baseline scaffold is treated as first run (seeds, exit 0)" {
  # Copy the COMMITTED scaffold so the test never mutates the tracked file.
  local base="$BATS_TEST_TMPDIR/scaffold.json"
  cp "$BSP_BASELINE_JSON" "$base"
  run bash -c "source '$FETCH_DEBS'; bsp_drift_check '$base' linux-image-vendor-rk35xx 6.1.0-vendor $BSP_SHA_A"
  [ "$status" -eq 0 ]
  [[ "$output" == *"first run"* ]]
  # now seeded with real values (no longer null)
  run cat "$base"
  [[ "$output" == *"$BSP_SHA_A"* ]]
}

@test "bsp provenance: bsp_write_json emits valid JSON with schema_version + 64-hex sha256" {
  local out="$BATS_TEST_TMPDIR/prov/bsp-provenance.json"
  run bash -c "source '$FETCH_DEBS'; bsp_write_json '$out' linux-image-vendor-rk35xx 6.1.0-vendor $BSP_SHA_A"
  [ "$status" -eq 0 ]
  [ -f "$out" ]
  # parses as JSON and carries the expected shape
  run python3 -c "import json,sys; d=json.load(open('$out')); assert d['schema_version']==1; assert d['package']=='linux-image-vendor-rk35xx'; assert len(d['sha256'])==64; print('JSON-OK')"
  [ "$status" -eq 0 ]
  [[ "$output" == *"JSON-OK"* ]]
}

@test "bsp provenance: the committed baseline scaffold is valid JSON and ships UNSEEDED (null)" {
  run python3 -c "import json; d=json.load(open('$BSP_BASELINE_JSON')); assert d['schema_version']==1; assert d['package']=='linux-image-vendor-rk35xx'; assert d['version'] is None and d['sha256'] is None; print('SCAFFOLD-OK')"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SCAFFOLD-OK"* ]]
}

@test "bsp provenance: artifact is gitignored and absent from the determinism hash set" {
  # The provenance artifact lands in the image output dir ($DEST, default ./out);
  # the bare-filename .gitignore pattern matches it at any depth.
  run git -C "$REPO_ROOT" check-ignore -q out/bsp-provenance.json
  [ "$status" -eq 0 ]
  # The determinism job hashes the NORMALIZED build-plan string ('would build
  # with:'), never a file tree — so the floating provenance artifact can never
  # enter the sha256 comparison. Assert the plan-line anchor exists and the
  # artifact name is nowhere in that workflow.
  grep -q "would build with:" "$REPO_ROOT/.github/workflows/v2-ci.yml"
  ! grep -q "bsp-provenance" "$REPO_ROOT/.github/workflows/v2-ci.yml"
}
