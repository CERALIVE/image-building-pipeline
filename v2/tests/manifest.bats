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
  CHECK_WWAN="$LIB_DIR/check-wwan-modules.sh"
  POSTINST_LIB="$V2/mkosi/customize/postinst-lib.sh"
  VERIFY_PASETO="$LIB_DIR/verify-paseto-key-encodings.sh"
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
  # Locate the repo-local pin registry unless the caller provides an override.
  if [[ -z "${VERSIONS_YAML:-}" || ! -f "${VERSIONS_YAML:-}" ]]; then
    VERSIONS_YAML="$REPO_ROOT/versions.yaml"
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

extract_hostname_script() {
  awk '
    /cat >\/usr\/local\/sbin\/ceralive-set-hostname <<'\''EOF'\''/ { in_script = 1; next }
    in_script && /^EOF$/ { exit }
    in_script { print }
  ' "$POSTINST_LIB"
}

run_hostname_script_with_collision() {
  local collision_ip="${1:-}"
  local state="$BATS_TEST_TMPDIR/hostname-state"
  local bin="$BATS_TEST_TMPDIR/hostname-bin"
  local script="$BATS_TEST_TMPDIR/ceralive-set-hostname"
  local hosts="$BATS_TEST_TMPDIR/hosts"
  local hostname_file="$BATS_TEST_TMPDIR/hostname"
  local calls="$BATS_TEST_TMPDIR/hostname-calls"
  rm -rf "$state" "$bin"
  mkdir -p "$state" "$bin"
  printf '127.0.0.1\tlocalhost\n' >"$hosts"
  extract_hostname_script >"$script"
  chmod +x "$script"
  cat >"$bin/hostnamectl" <<'SH'
#!/usr/bin/env bash
printf 'hostnamectl %s\n' "$*" >>"$HOSTNAME_CALLS"
exit 0
SH
  cat >"$bin/ip" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"-4 addr show scope global"*) printf '2: eth0    inet 192.168.78.50/24 brd 192.168.78.255 scope global eth0\n' ;;
esac
SH
  cat >"$bin/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
  cat >"$bin/avahi-resolve-host-name" <<'SH'
#!/usr/bin/env bash
name="${*: -1}"
if [ "$name" = "ceralive.local" ] && [ -n "${HOSTNAME_COLLISION_IP:-}" ]; then
  printf 'ceralive.local\t%s\n' "$HOSTNAME_COLLISION_IP"
fi
SH
  chmod +x "$bin/hostnamectl" "$bin/ip" "$bin/timeout" "$bin/avahi-resolve-host-name"
  env HOSTNAME_CALLS="$calls" HOSTNAME_COLLISION_IP="$collision_ip" \
      CERALIVE_HOSTNAME_STATE_DIR="$state" \
      CERALIVE_HOSTS_FILE="$hosts" \
      CERALIVE_HOSTNAME_FILE="$hostname_file" \
      HOSTNAMECTL_BIN="$bin/hostnamectl" \
      IP_BIN="$bin/ip" \
      TIMEOUT_BIN="$bin/timeout" \
      AVAHI_RESOLVE_BIN="$bin/avahi-resolve-host-name" \
      CERALIVE_HOSTNAME_PROBE_GRACE=0 \
      bash "$script"
  cat "$calls"
  printf 'index=%s\n' "$(cat "$state/host_index")"
  printf 'hosts=%s\n' "$(grep '^127\.0\.1\.1' "$hosts")"
}

@test "hostname: first device claims predictable ceralive.local" {
  run run_hostname_script_with_collision ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"hostnamectl set-hostname ceralive"* ]]
  [[ "$output" == *"index=1"* ]]
  [[ "$output" == *$'hosts=127.0.1.1\tceralive'* ]]
}

@test "hostname: mDNS collision falls back to ceralive2.local" {
  run run_hostname_script_with_collision "192.168.78.10"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hostnamectl set-hostname ceralive2"* ]]
  [[ "$output" == *"index=2"* ]]
  [[ "$output" == *$'hosts=127.0.1.1\tceralive2'* ]]
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

write_installed_package_status() {
  local status_file="$1"
  shift
  : >"$status_file"
  local package
  for package in "$@"; do
    cat >>"$status_file" <<STATUS
Package: $package
Status: install ok installed

STATUS
  done
}

make_parity_rootfs() {
  local root="$1"
  mkdir -p \
    "$root/var/lib/dpkg" \
    "$root/etc/systemd/system" \
    "$root/usr/bin" \
    "$root/etc/iproute2" \
    "$root/etc/dhcp/dhclient-exit-hooks.d" \
    "$root/etc/NetworkManager/dispatcher.d" \
    "$root/etc/udev/rules.d" \
    "$root/etc/apt/sources.list.d" \
    "$root/etc/systemd/network"

  local packages=() package
  while IFS= read -r package; do [[ -n "$package" ]] && packages+=("$package"); done \
    < <(sed -e 's/#.*//' "$V2/manifests/packages/shared.list" "$V2/manifests/packages"/*.delta.list | awk 'NF{print $1}')
  packages+=(gstreamer1.0-rockchip1 rockchip-multimedia-config ceralive-device cerastream srtla-send-rs)
  write_installed_package_status "$root/var/lib/dpkg/status" "${packages[@]}"

  printf 'ceralive:x:1000:1000:CeraLive:/home/ceralive:/bin/bash\n' >"$root/etc/passwd"
  for group in sudo audio video dialout plugdev netdev gpio i2c spi; do
    printf '%s:x:1000:ceralive\n' "$group" >>"$root/etc/group"
  done
  : >"$root/usr/bin/sudo"
  chmod +x "$root/usr/bin/sudo"
  for svc in NetworkManager ModemManager ssh chrony avahi-daemon systemd-resolved ceralive-hostname; do
    : >"$root/etc/systemd/system/$svc.service"
  done
  printf '100 modem0\n120 wlan0\n' >"$root/etc/iproute2/rt_tables"
  : >"$root/etc/dhcp/dhclient-exit-hooks.d/srtla-source-routing"
  : >"$root/etc/NetworkManager/dispatcher.d/90-srtla-wifi-routing"
  chmod +x "$root/etc/dhcp/dhclient-exit-hooks.d/srtla-source-routing"
  chmod +x "$root/etc/NetworkManager/dispatcher.d/90-srtla-wifi-routing"
  : >"$root/etc/udev/rules.d/99-ceralive-hardware.rules"
  : >"$root/etc/apt/sources.list.d/debian.sources"
  : >"$root/etc/apt/sources.list.d/ceralive.sources"
  : >"$root/etc/systemd/network/10-ceralive-wlan0.link"
}

# serialize <name> — hold an exclusive, suite-scoped lock for the REST of the
# current @test, so the handful of tests that share mutable state run correctly
# under `bats --jobs N` (which v2/run-tests enables when GNU parallel is on
# PATH). bats parallelizes test CASES, not the comment "sections", so any two
# tests that touch the same mutable resource must serialize themselves:
#   * §8 postinst-drift — two tests cp/sed-restore tracked working-tree files
#     (mkosi.postinst.chroot, networking-srtla.sh) while a third asserts the
#     CLEAN tree; without a lock a parallel scheduler could read the tree
#     mid-mutation -> false failure.
#   * §14 feature sysext — build_feature_fixture populates a per-FILE fixture
#     dir ($BATS_FILE_TMPDIR/out) shared by five tests; only one may build it.
#   * §9 build-plan probes — each `v2/build` invocation removes and recreates
#     the shared `v2/mkosi/.staging/<board>` directory; these tests take one
#     lock so GNU-parallel CI cannot interleave board fetch plans.
# The lock auto-releases when the @test subshell exits (each bats test runs in
# its own subshell). Use BATS_RUN_TMPDIR so workers spawned by GNU parallel share
# the rendezvous even when BATS_FILE_TMPDIR is worker-local. flock-less hosts get
# a no-op — v2/run-tests only requests --jobs when flock is present, so a serial
# run never needs it.
serialize() {
  command -v flock >/dev/null 2>&1 || return 0
  local lockfd lock_root="${BATS_RUN_TMPDIR:-${BATS_FILE_TMPDIR:-}}"
  [[ -n "$lock_root" ]] || return 0
  mkdir -p "$lock_root/locks"
  exec {lockfd}>"$lock_root/locks/.serialize.${BATS_TEST_FILENAME##*/}.$1.lock"
  flock "$lockfd"
}

# assert_bsp_architecture_plan <debian-arch> — both supported offline BSP
# transports must expose the resolved Debian architecture. Native apt-get logs
# its explicit APT::Architecture option; the curl fallback logs the Packages.gz
# index path. Keep both checks because CI and Arch-like developer hosts choose
# different transports without changing the build contract.
assert_bsp_architecture_plan() {
  local arch="$1"
  if [[ "$output" == *"DRY-RUN would write Armbian source:"* ]]; then
    [[ "$output" == *"DRY-RUN would write Armbian source: deb [arch=${arch}]"* ]]
    [[ "$output" == *"APT::Architecture=${arch}"* ]]
  else
    [[ "$output" == *"binary-${arch}/Packages.gz"* ]]
  fi
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
  serialize working-tree   # never read the tree while a sibling test mutates it
  run bash "$V2/ci/postinst-drift-check.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RESULT: no drift"* ]]
  [[ "$output" != *"FAIL"* ]]
}

@test "postinst drift: gate CATCHES a re-inlined consolidated function (non-vacuity)" {
  serialize working-tree   # mutates a tracked file then restores; exclusive
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
  serialize working-tree   # mutates a tracked file then restores; exclusive
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
  serialize build-plan
  run env INSTALL_BOOT_BSP=0 DRY_RUN=1 bash "$V2/build" rock-5b-plus
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN complete"* ]]
}

@test "t14 rootfs: orange-pi-5-plus reaches the build plan (exit 0, custom/rk3588)" {
  serialize build-plan
  run env INSTALL_BOOT_BSP=0 DRY_RUN=1 bash "$V2/build" orange-pi-5-plus
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN complete"* ]]
}

@test "t14 rootfs: x86-minipc reaches the build plan (exit 0, efi)" {
  serialize build-plan
  run env INSTALL_BOOT_BSP=0 DRY_RUN=1 bash "$V2/build" x86-minipc
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN complete"* ]]
}

@test "fetch staging: x86-minipc maps resolved x86-64 to Debian amd64" {
  serialize build-plan
  run env INSTALL_BOOT_BSP=0 DRY_RUN=1 bash "$V2/build" x86-minipc
  [ "$status" -eq 0 ]
  [[ "$output" == *"resolved: family=x86_64 arch=x86-64 (mkosi=x86-64)"* ]]
  [[ "$output" == *"channel=stable arch=amd64"* ]]
  [[ "$output" == *"non-Armbian family: BSP fetch omitted from DRY_RUN plan"* ]]
  [[ "$output" != *"DRY-RUN would write Armbian source:"* ]]
  [[ "$output" != *"https://apt.armbian.com"* ]]
  [[ "$output" == *"first-party source: https://apt.ceralive.tv/dists/stable/binary-amd64/"* ]]
  [[ "$output" == *"APT::Architecture=amd64"* ]]
  [[ "$output" != *"binary-arm64"* ]]
}

@test "fetch staging: RK3588 boards keep Debian arm64" {
  serialize build-plan
  local board
  for board in rock-5b-plus orange-pi-5-plus; do
    run env INSTALL_BOOT_BSP=0 DRY_RUN=1 bash "$V2/build" "$board"
    [ "$status" -eq 0 ]
    [[ "$output" == *"resolved: family=rk3588 arch=arm64 (mkosi=arm64)"* ]]
    [[ "$output" == *"channel=stable arch=arm64"* ]]
    assert_bsp_architecture_plan arm64
    [[ "$output" == *"first-party source: https://apt.ceralive.tv/dists/stable/binary-arm64/"* ]]
    [[ "$output" == *"APT::Architecture=arm64"* ]]
    [[ "$output" != *"binary-amd64"* ]]
  done
}

@test "t14 x86 guard: x86-minipc DRY_RUN emits no .raw (resolve+plan only, before Stage-4)" {
  serialize build-plan
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
  run grep -q 'TODO(x86-disk)' "$orch"
  [ "$status" -ne 0 ]
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

@test "size-gate: final app layer strips apt caches while preserving dpkg status" {
  run grep -qx 'CleanPackageMetadata=no' "$V2/mkosi/mkosi.images/app/mkosi.conf"
  [ "$status" -eq 0 ]

  run grep -F 'clean_package_download_metadata' "$V2/mkosi/mkosi.images/app/mkosi.postinst.chroot"
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean_package_download_metadata"* ]]

  run grep -F 'rm -rf /var/lib/apt/lists/* /var/cache/apt/pkgcache.bin /var/cache/apt/srcpkgcache.bin' "$V2/mkosi/mkosi.images/app/mkosi.postinst.chroot"
  [ "$status" -eq 0 ]
}

@test "size-gate: platform prunes RK3588 firmware and final app prunes headless payload" {
  run grep -F 'prune_final_image_payload' "$V2/mkosi/mkosi.images/app/mkosi.postinst.chroot"
  [ "$status" -eq 0 ]

  run grep -F '/usr/lib/firmware/qcom' "$V2/mkosi/mkosi.images/platform/mkosi.postinst.chroot"
  [ "$status" -eq 0 ]

  run grep -F '/usr/lib/firmware/intel' "$V2/mkosi/mkosi.images/app/mkosi.postinst.chroot"
  [ "$status" -ne 0 ]

  run grep -F '/usr/share/icons/Adwaita' "$V2/mkosi/mkosi.images/app/mkosi.postinst.chroot"
  [ "$status" -eq 0 ]
}

@test "app-layer: first-party packages can be copied from mkosi source staging" {
  run grep -F 'stage_first_party_from_source_mount' "$V2/mkosi/mkosi.images/app/mkosi.postinst.chroot"
  [ "$status" -eq 0 ]

  run grep -F 'src="${src%/}/.staging/${BOARD_ID}/firstparty"' "$V2/mkosi/mkosi.images/app/mkosi.postinst.chroot"
  [ "$status" -eq 0 ]

  run grep -F 'cp -a "${src}"/*.deb "${FIRST_PARTY_DIR}/"' "$V2/mkosi/mkosi.images/app/mkosi.postinst.chroot"
  [ "$status" -eq 0 ]
}

@test "app-layer: first-party install is closed over staged packages and runtime deps" {
  run grep -F 'gstreamer1.0-libuvch264src' "$FETCH_DEBS"
  [ "$status" -eq 0 ]

  run grep -F 'dpkg -i "${debs[@]}"' "$V2/mkosi/mkosi.images/app/mkosi.postinst.chroot"
  [ "$status" -eq 0 ]

  run grep -F -- 'apt-get install -y --no-install-recommends --no-download -f' "$V2/mkosi/mkosi.images/app/mkosi.postinst.chroot"
  [ "$status" -eq 0 ]

  run grep -F 'apt-get update' "$V2/mkosi/mkosi.images/app/mkosi.postinst.chroot"
  [ "$status" -ne 0 ]
}

@test "runtime packages: sudo is installed for the CeraUI add-on helper" {
  run grep -Ex 'sudo[[:space:]]*(#.*)?' "$V2/manifests/packages/shared.list"
  [ "$status" -eq 0 ]
}

@test "production image leaves debug access disabled without failing finalization" {
  run env \
    CERALIVE_DEBUG_IMAGE=0 \
    CERALIVE_DEBUG_PASSWORD_HASH='' \
    bash -c 'source "$1"; configure_debug_access' bash "$POSTINST_LIB"

  [ "$status" -eq 0 ]
}

@test "mkosi passes lab debug settings to every subimage" {
  run grep -Fx 'PassEnvironment=CERALIVE_DEBUG_IMAGE CERALIVE_DEBUG_PASSWORD_HASH' "$V2/mkosi/mkosi.conf"

  [ "$status" -eq 0 ]
}

@test "lab debug password requires an explicitly marked debug image" {
  local bin="$BATS_TEST_TMPDIR/debug-password-bin"
  local calls="$BATS_TEST_TMPDIR/debug-password-calls"
  mkdir -p "$bin"

  for command in id usermod chage install; do
    cat >"$bin/$command" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >>"$DEBUG_PASSWORD_CALLS"
case "$(basename "$0")" in
  id) exit 0 ;;
esac
SH
    chmod +x "$bin/$command"
  done

  run env \
    PATH="$bin:$PATH" \
    DEBUG_PASSWORD_CALLS="$calls" \
    CERALIVE_DEBUG_IMAGE=0 \
    CERALIVE_DEBUG_PASSWORD_HASH='$6$test$hash' \
    bash -c 'source "$1"; configure_debug_access' bash "$POSTINST_LIB"

  [ "$status" -ne 0 ]
  [[ "$output" == *"CERALIVE_DEBUG_PASSWORD_HASH requires CERALIVE_DEBUG_IMAGE=1"* ]]
}

@test "lab debug image unlocks ceralive with an injected password hash" {
  local bin="$BATS_TEST_TMPDIR/debug-password-bin"
  local calls="$BATS_TEST_TMPDIR/debug-password-calls"
  mkdir -p "$bin"

  for command in id usermod chage install; do
    cat >"$bin/$command" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >>"$DEBUG_PASSWORD_CALLS"
case "$(basename "$0")" in
  id) exit 0 ;;
esac
SH
    chmod +x "$bin/$command"
  done

  run env \
    PATH="$bin:$PATH" \
    DEBUG_PASSWORD_CALLS="$calls" \
    CERALIVE_DEBUG_IMAGE=1 \
    CERALIVE_DEBUG_PASSWORD_HASH='$6$test$hash' \
    bash -c 'source "$1"; configure_debug_access' bash "$POSTINST_LIB"

  [ "$status" -eq 0 ]
  run cat "$calls"
  [ "$status" -eq 0 ]
  [[ "$output" == *'usermod --password $6$test$hash ceralive'* ]]
  [[ "$output" == *'chage -d -1 ceralive'* ]]
  [[ "$output" == *'install -Dm 0600 /dev/null /etc/ceralive/debug-image'* ]]
}

@test "parity: ceralive.service fails when ExecStart target is missing" {
  local root="$BATS_TEST_TMPDIR/parity-rootfs"
  make_parity_rootfs "$root"
  cat >"$root/etc/systemd/system/ceralive.service" <<'UNIT'
[Service]
ExecStart=/opt/ceralive/ceralive
UNIT

  run "$LIB_DIR/parity-check.sh" "$root"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ceralive.service ExecStart target missing/not executable: /opt/ceralive/ceralive"* ]]
}

@test "parity: ceralive.service must be enabled for multi-user boot" {
  local root="$BATS_TEST_TMPDIR/parity-rootfs"
  make_parity_rootfs "$root"
  mkdir -p "$root/usr/local/bin"
  : >"$root/usr/local/bin/ceralive"
  chmod +x "$root/usr/local/bin/ceralive"
  cat >"$root/etc/systemd/system/ceralive.service" <<'UNIT'
[Service]
ExecStart=/usr/local/bin/ceralive
UNIT

  run "$LIB_DIR/parity-check.sh" "$root"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ceralive.service is not enabled for multi-user boot"* ]]
}

@test "rauc: service guard checks installed unit files without relying on systemctl list output" {
  run grep -F '[[ ! -f /lib/systemd/system/rauc.service && ! -f /usr/lib/systemd/system/rauc.service ]]' "$V2/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"
  [ "$status" -eq 0 ]

  run grep -F '[[ ! -f /lib/systemd/system/rauc.service && ! -f /usr/lib/systemd/system/rauc.service ]]' "$V2/mkosi/customize/rauc-setup.sh"
  [ "$status" -eq 0 ]

  run grep -F 'systemctl list-unit-files rauc.service' "$V2/mkosi/mkosi.images/runtime/mkosi.postinst.chroot" "$V2/mkosi/customize/rauc-setup.sh"
  [ "$status" -ne 0 ]
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
  local probe
  command -v mksquashfs >/dev/null 2>&1 || return 1
  command -v gpg        >/dev/null 2>&1 || return 1
  command -v gpg-agent  >/dev/null 2>&1 || return 1
  command -v gpgv       >/dev/null 2>&1 || return 1
  command -v unsquashfs >/dev/null 2>&1 || return 1
  probe="$(mktemp -d)"
  chmod 700 "$probe"
  if ! gpg-agent --homedir "$probe" --daemon >/dev/null 2>&1; then
    rm -rf "$probe"
    return 1
  fi
  gpgconf --homedir "$probe" --kill gpg-agent >/dev/null 2>&1 || true
  rm -rf "$probe"
  return 0
}

# build_feature_fixture — build a sample signed feature sysext ONCE per file into
# BATS_FILE_TMPDIR, signed by a throwaway gpg home (NOT the repo dev keys). Echoes
# nothing; idempotent — later tests reuse the produced artifacts. Under
# `bats --jobs N` the five §14 tests call this concurrently, so the build (and
# the idempotency check that guards it) run inside a flock'd subshell: exactly
# one test populates the shared per-FILE fixture dir, the rest see it already
# built. The lock releases as soon as the subshell exits, so the assertion
# bodies still run in parallel.
build_feature_fixture() {
  local out="$BATS_FILE_TMPDIR/out"
  local raw="$out/demo-feature-rock-5b-plus-12.raw"
  (
    command -v flock >/dev/null 2>&1 && flock 9
    [ -f "$raw" ] && exit 0          # idempotency check INSIDE the lock (no TOCTOU)
    local stg="$BATS_FILE_TMPDIR/staging"
    mkdir -p "$stg/usr/bin" "$stg/opt/demo"
    printf '#!/bin/sh\necho hi\n' > "$stg/usr/bin/demo-tool"
    printf 'payload\n'            > "$stg/opt/demo/data.txt"
    bash "$LIB_DIR/build-feature-sysext.sh" \
      --feature demo-feature --board rock-5b-plus --os-version 12 \
      --deb-staging "$stg" --out "$out" \
      --keyring "$BATS_FILE_TMPDIR/gnupg" >/dev/null 2>&1
  ) 9>"$BATS_FILE_TMPDIR/.serialize.feature-fixture.lock"
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
# 14b. Build-time descriptor schema fail-fast (C6b).
#     build-feature-sysext.sh validates its target add-on descriptor against
#     addon.schema.json (reusing ci/validate-manifests.py --file) BEFORE any
#     build side-effect. A corrupt descriptor aborts non-zero with the path in
#     stderr and produces no artifact; a schema-valid descriptor proceeds. The
#     cross-descriptor G1/G2/E6 semantics stay CI-only (glob mode) — build time
#     is schema-only. Needs python3 + jsonschema (a suite-wide assumption, §13).
# ===========================================================================

@test "c6b: --file mode of validate-manifests.py rejects a corrupt descriptor, names its path" {
  local desc="$FIXTURES/invalid-addon-build-fixture.json"
  run bash -c "python3 '$VALIDATE_PY' --file '$desc' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$desc"* ]]
  [[ "$output" == *"name"* ]]
}

@test "c6b: --file mode of validate-manifests.py passes a shipped descriptor (exit 0)" {
  run bash -c "python3 '$VALIDATE_PY' --file '$V2/manifests/addons/debug-toolset.json' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"debug-toolset.json"* ]]
}

@test "c6b build: a corrupt descriptor is REJECTED before any build side-effect, names the path" {
  local stg="$BATS_TEST_TMPDIR/c6b-staging" out="$BATS_TEST_TMPDIR/c6b-out"
  local desc="$FIXTURES/invalid-addon-build-fixture.json"
  mkdir -p "$stg/usr/bin"
  printf 'x\n' > "$stg/usr/bin/t"
  run bash "$LIB_DIR/build-feature-sysext.sh" \
        --feature demo-feature --board rock-5b-plus --os-version 12 \
        --deb-staging "$stg" --out "$out" --descriptor "$desc" \
        --keyring "$BATS_TEST_TMPDIR/c6b-gnupg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$desc"* ]]
  # No build side-effect: the output dir is never created past the fail-fast gate.
  [ ! -e "$out" ]
}

@test "c6b build: a schema-valid descriptor passes validation and the build proceeds" {
  feature_prereqs || skip "signing toolchain not available"
  local stg="$BATS_TEST_TMPDIR/c6b-ok-staging" out="$BATS_TEST_TMPDIR/c6b-ok-out"
  mkdir -p "$stg/usr/bin"
  printf '#!/bin/sh\necho hi\n' > "$stg/usr/bin/demo-tool"
  run bash "$LIB_DIR/build-feature-sysext.sh" \
        --feature demo-feature --board rock-5b-plus --os-version 12 \
        --deb-staging "$stg" --out "$out" \
        --descriptor "$V2/manifests/addons/debug-toolset.json" \
        --keyring "$BATS_TEST_TMPDIR/c6b-ok-gnupg"
  [ "$status" -eq 0 ]
  [[ "$output" == *"descriptor schema-valid"* ]]
  [ -f "$out/demo-feature-rock-5b-plus-12.raw" ]
}

# ===========================================================================
# 15. BSP provenance + advisory kernel drift-guard (Task 3).
#     fetch-debs.sh records the exact-versioned kernel BSP's resolved version +
#     content sha256 into a gitignored bsp-provenance.json, then runs a drift
#     guard against the committed v2/manifests/bsp-baseline.json. It warns by
#     default and is fatal only with BSP_DRIFT_STRICT=1; it compares the CONTENT
#     hash (not just the version), so a same-version re-spin is still caught, and
#     seeds the baseline on first run. These tests source the fetch helpers
#     directly and drive the guard with synthetic version/hash inputs
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
  local base="$BATS_TEST_TMPDIR/scaffold.json"
  printf '{ "schema_version": 1, "package": "linux-image-vendor-rk35xx", "version": null, "sha256": null }\n' > "$base"
  run bash -c "source '$FETCH_DEBS'; bsp_drift_check '$base' linux-image-vendor-rk35xx 6.1.0-vendor $BSP_SHA_A"
  [ "$status" -eq 0 ]
  [[ "$output" == *"first run"* ]]
  run cat "$base"
  [[ "$output" == *"$BSP_SHA_A"* ]]
}

@test "bsp drift (C6b): default (STRICT unset) with drift warns and exits 0" {
  local base="$BATS_TEST_TMPDIR/baseline-default.json"
  printf '{ "schema_version": 1, "package": "linux-image-vendor-rk35xx", "version": "6.1.0-vendor", "sha256": "%s" }\n' "$BSP_SHA_A" > "$base"
  run bash -c "source '$FETCH_DEBS'; bsp_drift_check '$base' linux-image-vendor-rk35xx 6.1.99-vendor $BSP_SHA_A"
  [ "$status" -eq 0 ]
  [[ "$output" == *"BSP drift"* ]]
  [[ "$output" == *"advisory — build continues"* ]]
}

@test "bsp drift (C6b): BSP_DRIFT_STRICT=1 with drift fails (non-zero)" {
  local base="$BATS_TEST_TMPDIR/baseline-strict.json"
  printf '{ "schema_version": 1, "package": "linux-image-vendor-rk35xx", "version": "6.1.0-vendor", "sha256": "%s" }\n' "$BSP_SHA_A" > "$base"
  run bash -c "source '$FETCH_DEBS'; BSP_DRIFT_STRICT=1 bsp_drift_check '$base' linux-image-vendor-rk35xx 6.1.99-vendor $BSP_SHA_A"
  [ "$status" -ne 0 ]
  [[ "$output" == *"BSP drift"* ]]
  [[ "$output" == *"BSP_DRIFT_STRICT=1"* ]]
}

@test "bsp drift (C6b): no drift is exit 0 in BOTH default and strict modes" {
  local base="$BATS_TEST_TMPDIR/baseline-match-modes.json"
  printf '{ "schema_version": 1, "package": "linux-image-vendor-rk35xx", "version": "6.1.0-vendor", "sha256": "%s" }\n' "$BSP_SHA_A" > "$base"
  run bash -c "source '$FETCH_DEBS'; bsp_drift_check '$base' linux-image-vendor-rk35xx 6.1.0-vendor $BSP_SHA_A"
  [ "$status" -eq 0 ]
  run bash -c "source '$FETCH_DEBS'; BSP_DRIFT_STRICT=1 bsp_drift_check '$base' linux-image-vendor-rk35xx 6.1.0-vendor $BSP_SHA_A"
  [ "$status" -eq 0 ]
  [[ "$output" == *"matches known-good baseline"* ]]
}

@test "bsp drift (C6b): BSP_DRIFT_STRICT=1 with an UNSEEDED baseline seeds and exits 0 (seeding is exempt)" {
  local base="$BATS_TEST_TMPDIR/scaffold-strict.json"
  printf '{ "schema_version": 1, "package": "linux-image-vendor-rk35xx", "version": null, "sha256": null }\n' > "$base"
  run bash -c "source '$FETCH_DEBS'; BSP_DRIFT_STRICT=1 bsp_drift_check '$base' linux-image-vendor-rk35xx 6.1.0-vendor $BSP_SHA_A"
  [ "$status" -eq 0 ]
  [[ "$output" == *"first run"* ]]
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

@test "bsp provenance: the committed baseline is valid JSON and carries a valid seed state" {
  run python3 -c "import json,re; d=json.load(open('$BSP_BASELINE_JSON')); assert d['schema_version']==1; assert d['package']=='linux-image-vendor-rk35xx'; v=d.get('version'); s=d.get('sha256'); assert (v is None and s is None) or (isinstance(v,str) and re.fullmatch(r'[0-9a-f]{64}', s or '')); print('BASELINE-OK')"
  [ "$status" -eq 0 ]
  [[ "$output" == *"BASELINE-OK"* ]]
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

@test "v2 CI: resolver dependency cache is content-addressed and covers every resolver job" {
  run python3 - "$REPO_ROOT" <<'PY'
import sys
from pathlib import Path

import yaml

repo_root = Path(sys.argv[1])
workflow = yaml.safe_load((repo_root / ".github/workflows/v2-ci.yml").read_text())
requirements = repo_root / "v2/ci/requirements-ci.txt"
assert requirements.read_text().splitlines()[-2:] == ["jsonschema==4.26.0", "PyYAML==6.0.3"]

expected_key = "pip-${{ runner.os }}-${{ runner.arch }}-${{ hashFiles('v2/ci/requirements-ci.txt') }}"
for job_id in ("schema-validate", "bats", "build-matrix", "build-plan-xrunner"):
    steps = workflow["jobs"][job_id]["steps"]
    cache = next(step for step in steps if step.get("uses") == "actions/cache@v6")
    assert cache["with"] == {
        "path": "~/.cache/pip",
        "key": expected_key,
    }, f"{job_id}: unexpected pip cache declaration: {cache!r}"
    install = next(step["run"] for step in steps if step.get("name", "").startswith("Install "))
    assert "pip install --quiet --requirement v2/ci/requirements-ci.txt" in install, job_id

print("V2-CI-PIP-CACHE-OK")
PY
  [ "$status" -eq 0 ]
  [[ "$output" == *"V2-CI-PIP-CACHE-OK"* ]]
}

@test "v2 CI: qemu job honestly runs only the assertion-engine selftest" {
  run python3 -c "import yaml; workflow = yaml.safe_load(open('$REPO_ROOT/.github/workflows/v2-ci.yml')); job = workflow['jobs']['qemu']; runs = '\n'.join(step.get('run', '') for step in job['steps']); assert 'CERALIVE_QEMU_SELFTEST' in str(job['steps']); assert 'IMAGE_PATH=' not in runs; assert 'skip mode' not in runs; print('QEMU-SELFTEST-SCOPE-OK')"
  [ "$status" -eq 0 ]
  [[ "$output" == *"QEMU-SELFTEST-SCOPE-OK"* ]]
}

# ===========================================================================
# 16. OTA-during-stream guard (Task 4).
#     /usr/local/bin/ceralive-update (generated by postinst-lib.sh::
#     setup_data_persistence) refuses to install a RAUC bundle while a stream
#     is live. The guard MUST cover the bonding SENDER unit — srtla-send.service
#     — not just the cerastream encoder and the srtla RECEIVER. These tests
#     reconstruct the generated script and drive its guard loop with a stubbed
#     `systemctl is-active`, so they exercise the SHIPPED guard body verbatim
#     (extracted from postinst-lib.sh), with no image boot — UNIT scope.
# ===========================================================================

# render_ceralive_update <conf> <data> — emit the generated ceralive-update
# script to stdout. The dynamic header (shebang/set/CONF/DATA — first heredoc)
# is reproduced with the test paths; the literal guard body (the second,
# '<<'EOF'' append heredoc: die(), the rauc/mount prechecks, and the
# OTA-during-stream loop) is extracted verbatim from postinst-lib.sh so the
# guard under test is the one that ships, not a copy. The `>>` append redirect
# uniquely marks the literal heredoc (the first uses a single `>`).
render_ceralive_update() {
  local conf="$1" data="$2"
  printf '#!/bin/bash\nset -euo pipefail\nCONF="%s"\nDATA="%s"\n' "$conf" "$data"
  awk '/>>\/usr\/local\/bin\/ceralive-update/{f=1;next} f&&/^EOF$/{exit} f{print}' "$POSTINST_LIB"
}

# ota_stub_bin — build a PATH dir of command stubs and echo its path:
#   systemctl is-active --quiet <svc> → exit 0 iff <svc> ∈ $ACTIVE_SVCS (else 3,
#       mirroring `inactive` for a stopped OR not-installed unit)
#   rauc / mountpoint → success no-ops, so the stream guard (not a precheck)
#       decides the outcome.
ota_stub_bin() {
  local bin="$BATS_TEST_TMPDIR/otabin"
  mkdir -p "$bin"
  cat > "$bin/systemctl" <<'SH'
#!/bin/bash
if [ "${1:-}" = "is-active" ]; then
  shift; [ "${1:-}" = "--quiet" ] && shift
  svc="${1:-}"
  for a in ${ACTIVE_SVCS:-}; do [ "$a" = "$svc" ] && exit 0; done
  exit 3
fi
exit 0
SH
  printf '#!/bin/bash\nexit 0\n' > "$bin/rauc"
  printf '#!/bin/bash\nexit 0\n' > "$bin/mountpoint"
  chmod +x "$bin/systemctl" "$bin/rauc" "$bin/mountpoint"
  printf '%s\n' "$bin"
}

# run_ota_guard <active-svcs> — render the guard against a provisioned CONF
# (BUNDLE_URL set) + mounted DATA, then run it with ACTIVE_SVCS as the only
# "active" units. Populates bats $status/$output.
run_ota_guard() {
  local active="$1"
  local data="$BATS_TEST_TMPDIR/data"
  local conf="$data/ceralive/update.conf"
  mkdir -p "$data/ceralive"
  printf 'BUNDLE_URL=https://apt.ceralive.tv/stable/x.raucb\nCHANNEL=stable\n' > "$conf"
  local script="$BATS_TEST_TMPDIR/ceralive-update.rendered"
  render_ceralive_update "$conf" "$data" > "$script"
  chmod +x "$script"
  local bin; bin="$(ota_stub_bin)"
  run env ACTIVE_SVCS="$active" PATH="$bin:$PATH" bash "$script"
}

@test "ota guard: srtla-send.service active BLOCKS the update (bonding sender — Task 4 fix)" {
  run_ota_guard "srtla-send.service"
  [ "$status" -ne 0 ]
  [[ "$output" == *"stream active (srtla-send.service)"* ]]
  [[ "$output" == *"refusing to update"* ]]
}

@test "ota guard: srtla-send.service inactive/absent ALLOWS the update (is-active=inactive for not-installed)" {
  run_ota_guard ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"installing RAUC bundle"* ]]
  [[ "$output" != *"stream active"* ]]
}

@test "ota guard: cerastream.service active STILL blocks (regression — pre-existing check preserved)" {
  run_ota_guard "cerastream.service"
  [ "$status" -ne 0 ]
  [[ "$output" == *"stream active (cerastream.service)"* ]]
}

@test "ota guard: srtla.service (receiver) active STILL blocks (regression — pre-existing check preserved)" {
  run_ota_guard "srtla.service"
  [ "$status" -ne 0 ]
  [[ "$output" == *"stream active (srtla.service)"* ]]
}

@test "ota guard: all three stream units inactive ALLOWS the update (regression)" {
  run_ota_guard ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"installed to inactive slot"* ]]
}

# ===========================================================================
# 17. Advisory WWAN module-presence check (Task 5).
#     v2/lib/check-wwan-modules.sh inspects a kernel .deb (or an extracted
#     module tree) and reports whether the six WWAN modules ship — loadable
#     (=m, a <mod>.ko file), built-in (=y, modules.builtin), or via a
#     modules.alias entry. It is ADVISORY: a missing module WARNS but the check
#     ALWAYS exits 0 (like the BSP drift-guard). The option module is matched by
#     option.ko / modules.builtin / alias, NEVER a bare "option" substring. These
#     tests build fixture .debs (ar+tar) and module trees in $BATS_TEST_TMPDIR —
#     no real BSP, UNIT scope.
# ===========================================================================

# wwan_stage_six <root> [kver] — stage a module tree carrying all six WWAN
# modules with a deliberate MIX of forms: qmi_wwan/cdc_mbim loadable (.ko),
# cdc_ether loadable (.ko.xz, compressed), cdc_wdm as cdc-wdm.ko (hyphen on disk
# — exercises the -/_ normalisation), option + cdc_ncm built-in (modules.builtin).
wwan_stage_six() {
  local root="$1" kv="${2:-6.1.0-vendor}"
  local netusb="$root/lib/modules/$kv/kernel/drivers/net/usb"
  local usbclass="$root/lib/modules/$kv/kernel/drivers/usb/class"
  mkdir -p "$netusb" "$usbclass"
  printf 'ELF' > "$netusb/qmi_wwan.ko"
  printf 'ELF' > "$netusb/cdc_mbim.ko"
  printf 'ELF' > "$netusb/cdc_ether.ko.xz"
  printf 'ELF' > "$usbclass/cdc-wdm.ko"
  printf 'kernel/drivers/usb/serial/option.ko\nkernel/drivers/net/usb/cdc_ncm.ko\n' \
    > "$root/lib/modules/$kv/modules.builtin"
}

# make_kernel_deb <stage> <out.deb> — pack a staged rootfs dir into a minimal but
# real .deb (debian-binary + control.tar.gz + data.tar.gz via ar), so the check's
# extraction path (explode_deb: ar+tar fallback) is exercised end-to-end.
make_kernel_deb() {
  local stage="$1" out="$2" tmp
  tmp="$(mktemp -d)"
  tar -C "$stage" -czf "$tmp/data.tar.gz" .
  mkdir -p "$tmp/ctl"
  cat > "$tmp/ctl/control" <<'CTL'
Package: linux-image-vendor-rk35xx
Version: 6.1.0-vendor
Architecture: arm64
Maintainer: ceralive-test <test@ceralive.tv>
Description: fixture kernel for WWAN module-presence tests
CTL
  tar -C "$tmp/ctl" -czf "$tmp/control.tar.gz" ./control
  printf '2.0\n' > "$tmp/debian-binary"
  ( cd "$tmp" && ar rc "$out" debian-binary control.tar.gz data.tar.gz )
  rm -rf "$tmp"
}

@test "wwan: all six modules present in a kernel .deb (happy path, mix of =m and =y)" {
  local stage="$BATS_TEST_TMPDIR/stage" deb="$BATS_TEST_TMPDIR/linux-image-vendor-rk35xx.deb"
  mkdir -p "$stage"
  wwan_stage_six "$stage"
  make_kernel_deb "$stage" "$deb"
  run "$CHECK_WWAN" "$deb"
  [ "$status" -eq 0 ]
  [[ "$output" == *"all 6 required modules present"* ]]
  [[ "$output" != *"MISSING"* ]]
  # cdc-wdm.ko (hyphen) satisfies cdc_wdm — the -/_ normalisation has teeth
  [[ "$output" == *"cdc_wdm — loadable"* ]]
  # compressed cdc_ether.ko.xz is recognised as loadable
  [[ "$output" == *"cdc_ether — loadable"* ]]
  # built-in modules recognised via modules.builtin
  [[ "$output" == *"cdc_ncm — built-in"* ]]
}

@test "wwan: a missing module WARNS and still exits 0 (advisory, missing cdc_ncm)" {
  local root="$BATS_TEST_TMPDIR/tree"
  wwan_stage_six "$root"
  # drop cdc_ncm from modules.builtin (option stays) so exactly one is absent
  printf 'kernel/drivers/usb/serial/option.ko\n' > "$root/lib/modules/6.1.0-vendor/modules.builtin"
  run "$CHECK_WWAN" "$root"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WWAN module MISSING: cdc_ncm"* ]]
  [[ "$output" == *"5/6 present, 1 missing"* ]]
  [[ "$output" == *"ADVISORY"* ]]
}

@test "wwan: a =y built-in module is recognised via modules.builtin (no .ko false-negative)" {
  local root="$BATS_TEST_TMPDIR/tree"
  wwan_stage_six "$root"   # option ships ONLY in modules.builtin, no option.ko
  run "$CHECK_WWAN" "$root"
  [ "$status" -eq 0 ]
  [[ "$output" == *"option — built-in (=y, modules.builtin)"* ]]
  [[ "$output" != *"WWAN module MISSING: option"* ]]
}

@test "wwan: bare 'option' decoys do NOT satisfy the option module (false-positive guard)" {
  local root="$BATS_TEST_TMPDIR/tree" kv="6.1.0-vendor"
  wwan_stage_six "$root"
  local md="$root/lib/modules/$kv"
  # remove the only legitimate option signal (built-in), keep cdc_ncm built-in
  printf 'kernel/drivers/net/usb/cdc_ncm.ko\n' > "$md/modules.builtin"
  # decoys that all contain the word "option" but are NOT the option module:
  printf 'the option driver is mentioned here\n' > "$md/optionnotes.txt"
  printf 'ELF' > "$md/kernel/drivers/net/usb/snd_usb_option_helper.ko"
  printf 'alias usb:v1234p5678option cdc_ncm\n' > "$md/modules.alias"
  run "$CHECK_WWAN" "$root"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WWAN module MISSING: option"* ]]
  # the other five remain present → exactly one missing
  [[ "$output" == *"5/6 present, 1 missing"* ]]
}

@test "wwan: the check asserts a .deb extractor (dpkg-deb or ar+tar) is available" {
  # with a normal PATH the assertion passes (ar + tar are on the host)
  run bash -c "source '$CHECK_WWAN'; wwan_assert_deb_tools"
  [ "$status" -eq 0 ]
  # with an empty PATH (no dpkg-deb, no ar/tar) it fails loudly and names the tools
  run bash -c "source '$CHECK_WWAN'; PATH='' wwan_assert_deb_tools"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ar"* ]]
  [[ "$output" == *"tar"* ]]
}

# ===========================================================================
# 18. PASETO device-token PUBLIC key provisioning (ADR-0006 D2 / Phase-A Task 3).
#     postinst-lib.sh::setup_paseto_public_key decodes the base64-forwarded
#     $PASETO_PUBLIC_KEY_B64 and bakes it into the CeraUI backend runtime env as an
#     ADDITIVE ceralive.service drop-in (Environment=PASETO_PUBLIC_KEY=...). CeraUI
#     reads PASETO_PUBLIC_KEY at startup (apps/backend device-token.ts
#     DEVICE_TOKEN_PUBLIC_KEY_ENV) — its PRESENCE gates real Ed25519 verification.
#     Provisioning is PUBLIC ONLY: a k4.secret / PEM private key FAILS the build and
#     no private material may appear in the baked artifact. These tests drive the
#     SHIPPED function (sourced from postinst-lib.sh) against a temp drop-in dir
#     (PASETO_DROPIN_DIR) — no image boot, UNIT scope; the offline DRY_RUN proof.
# ===========================================================================

# A sample raw-32-byte Ed25519 PUBLIC key in standard base64 (the paseto.public.raw.b64
# form). The function checks public-only + non-empty, not key math, so a fixed
# all-zero-bytes sample suffices.
PASETO_RAW_PUB="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

# run_paseto_provision <value> — run the shipped setup_paseto_public_key against a
# temp drop-in dir. An empty <value> exercises the no-key (skip) path; otherwise
# <value> is base64-wrapped into $PASETO_PUBLIC_KEY_B64 as the orchestrator does.
run_paseto_provision() {
  local payload="$1"
  local dir="$BATS_TEST_TMPDIR/ceralive.service.d"
  rm -rf "$dir"
  if [[ -z "$payload" ]]; then
    run env -u PASETO_PUBLIC_KEY_B64 PASETO_DROPIN_DIR="$dir" \
      bash -c "source '$POSTINST_LIB'; setup_paseto_public_key"
  else
    local b64; b64="$(printf '%s' "$payload" | base64 -w0)"
    run env PASETO_PUBLIC_KEY_B64="$b64" PASETO_DROPIN_DIR="$dir" \
      bash -c "source '$POSTINST_LIB'; setup_paseto_public_key"
  fi
  PASETO_DROPIN="$dir/20-paseto-public-key.conf"
}

@test "paseto provision: a PUBLIC key is baked into the ceralive.service env drop-in" {
  run_paseto_provision "$PASETO_RAW_PUB"
  [ "$status" -eq 0 ]
  [ -f "$PASETO_DROPIN" ]
  grep -q '^\[Service\]' "$PASETO_DROPIN"
  grep -q "^Environment=PASETO_PUBLIC_KEY=$PASETO_RAW_PUB\$" "$PASETO_DROPIN"
}

@test "paseto provision: NO private material in the baked drop-in (no k4.secret / PRIVATE KEY)" {
  run_paseto_provision "$PASETO_RAW_PUB"
  [ "$status" -eq 0 ]
  run grep -aq 'k4.secret' "$PASETO_DROPIN"
  [ "$status" -ne 0 ]
  run grep -aq 'PRIVATE KEY' "$PASETO_DROPIN"
  [ "$status" -ne 0 ]
}

@test "paseto provision: a k4.secret PRIVATE key is REFUSED (build fails, no drop-in)" {
  run_paseto_provision "k4.secret.ZZZZ"
  [ "$status" -ne 0 ]
  [[ "$output" == *"k4.secret"* ]]
  [ ! -f "$PASETO_DROPIN" ]
}

@test "paseto provision: PEM PRIVATE KEY material is REFUSED (build fails, no drop-in)" {
  run_paseto_provision "-----BEGIN PRIVATE KEY-----"
  [ "$status" -ne 0 ]
  [[ "$output" == *"PRIVATE KEY"* ]]
  [ ! -f "$PASETO_DROPIN" ]
}

@test "paseto provision: no key in env SKIPS provisioning (CeraUI MVP opaque-token path)" {
  run_paseto_provision ""
  [ "$status" -eq 0 ]
  [ ! -f "$PASETO_DROPIN" ]
  [[ "$output" == *"MVP opaque-token path"* ]]
}

@test "paseto provision: image contract uses the canonical public-key environment name" {
  grep -q 'PASETO_PUBLIC_KEY' "$REPO_ROOT/v2/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"
}

# ===========================================================================
# 19. fetch-debs defensive guards (Task 23) — REPOS integrity + apt URL scheme.
#     fetch-debs.sh asserts the sacred device REPOS constant (a `die` that can
#     ONLY fire on a wrong EDIT, never on a valid run) and WARNS — never dies —
#     when APT_CERALIVE_URL is not https:// (legitimate local/dev http:// overrides
#     must keep working; the fetch path gains no new failure mode). These tests
#     source the helpers directly (main is BASH_SOURCE-guarded) — no apt, no .deb.
# ===========================================================================

@test "fetch-debs REPOS guard: a REPOS without the sacred device entries trips the assert (die, non-zero)" {
  run bash -c "source '$FETCH_DEBS'; REPOS=(cerastream CeraUI); assert_repos_integrity 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"REPOS integrity"* ]]
}

@test "fetch-debs registry defaults to this checkout instead of the parent workspace" {
  run env -u VERSIONS_YAML bash -c "source '$FETCH_DEBS'; realpath \"\$VERSIONS_YAML\""
  [ "$status" -eq 0 ]
  [ "$output" = "$REPO_ROOT/versions.yaml" ]
}

@test "fetch-debs CeraUI registry pin matches the concrete device package release" {
  local expected_ceraui_pin="v2026.7.0"
  local expected_device_version="${expected_ceraui_pin#v}-20260713T190647.93ca1f8"
  local device_version

  [ "$(get_pin CeraUI)" = "$expected_ceraui_pin" ]
  device_version="$(awk -F= '$1 == "ceralive-device" { print $2; exit }' \
    "$REPO_ROOT/v2/manifests/first-party-deb-versions.txt")"
  [ "$device_version" = "$expected_device_version" ]
  [[ "$device_version" == "${expected_ceraui_pin#v}-"* ]]
}

@test "fetch-debs BSP set deduplicates the first family package against board overrides" {
  local family="$BATS_TEST_TMPDIR/family.yaml"
  local pins="$BATS_TEST_TMPDIR/bsp-versions.txt"
  cat >"$family" <<'YAML'
armbian_branch: vendor
kernel_packages:
  - linux-image-test
dtb_packages:
  - linux-dtb-test
uboot_packages: []
firmware_packages:
  - firmware-test
hw_accel_gstreamer_plugins: []
gstreamer_runtime_packages: []
YAML
  cat >"$pins" <<'PINS'
linux-image-test=1.0
linux-dtb-test=1.0
firmware-test=1.0
u-boot-test=1.0
PINS

  run bash -c "{ export DRY_RUN=1 BSP_DEB_VERSIONS_FILE='$pins' KERNEL_PACKAGES=linux-image-test DTB_PACKAGES=linux-dtb-test UBOOT_PACKAGES=u-boot-test FIRMWARE_PACKAGES=firmware-test; source '$FETCH_DEBS'; fetch_bsp '$family' '$BATS_TEST_TMPDIR/debs'; } 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"(4 pkgs): linux-image-test linux-dtb-test firmware-test u-boot-test"* ]]
  [[ "$output" == *"BSP apt specs: linux-image-test=1.0 linux-dtb-test=1.0 firmware-test=1.0 u-boot-test=1.0"* ]]
}

@test "fetch-debs URL guard: a non-HTTPS APT_CERALIVE_URL WARNS but does NOT die (sourcing proceeds)" {
  run bash -c "{ export APT_CERALIVE_URL=http://localhost:8080; source '$FETCH_DEBS' && echo SOURCED_OK; } 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not https"* ]]
  [[ "$output" == *"SOURCED_OK"* ]]
}

# ===========================================================================
# 20. fetch-debs DRY_RUN reliability (Task 24) — fetch_first_party under DRY_RUN
#     logs the EXACT planned `apt-get download` and stages NOTHING. This locks the
#     "plan-only, no side effects" contract that the run_or_plan / NO-`|| true`
#     design rule (common.sh) and the CI build-matrix (DRY_RUN=1) depend on. The
#     test sources the helper directly (main is BASH_SOURCE-guarded) — no apt.
# ===========================================================================

@test "fetch-debs DRY_RUN: fetch_first_party logs the planned apt-get download and stages no .deb" {
  local debs="$BATS_TEST_TMPDIR/debs"
  mkdir -p "$debs"
  run bash -c "{ export DRY_RUN=1 VERSIONS_YAML='$VERSIONS_YAML'; source '$FETCH_DEBS'; fetch_first_party '$debs'; } 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN would run:"* ]]
  [[ "$output" == *"download"* ]]
  [[ "$output" == *"cerastream"* ]]
  [[ "$output" == *"gstreamer1.0-libuvch264src"* ]]
  [[ "$output" == *"ceralive-device"* ]]
  [[ "$output" == *"srtla-send-rs"* ]]
  # and NOT ONE .deb was staged (plan-only, zero side effects)
  run bash -c "shopt -s nullglob; f=('$debs'/*.deb); echo \${#f[@]}"
  [ "$output" -eq 0 ]
}

# ===========================================================================
# 21. PASETO key-encoding cross-check (Task 19 / ADR-0006 D2) — the provisioning
#     verifier verify-paseto-key-encodings.sh proves the platform PASERK
#     k4.public and the device raw-base64 are the SAME 32-byte Ed25519 public
#     key, AND that the shipped setup_paseto_public_key bakes the build input
#     (PASETO_PUBLIC_KEY_B64) into Environment=PASETO_PUBLIC_KEY with zero drift,
#     AND that a k4.secret is refused. --self-test mints an EPHEMERAL keypair, so
#     the check is self-contained (no cert-work, no secrets) and CI-safe. Runbook:
#     docs/paseto-key-provisioning.md.
# ===========================================================================

@test "paseto verify: --self-test proves k4.public == raw-base64 and a clean build-bake (ephemeral keypair)" {
  run "$VERIFY_PASETO" --self-test
  [ "$status" -eq 0 ]
  [[ "$output" == *"byte-equal 32-byte public keys"* ]]
  [[ "$output" == *"round-trips to the same 32-byte public key"* ]]
  [[ "$output" == *"k4.secret fed as the build input is REFUSED"* ]]
  [[ "$output" == *"self-test OK"* ]]
}

@test "paseto verify: a mismatched k4.public / raw-base64 pair is caught (fail loud)" {
  # Two DIFFERENT Ed25519 keys' encodings must not validate as a pair. Minted
  # inline with openssl so the fixture is self-contained (no cert-work, Rule D).
  local d="$BATS_TEST_TMPDIR/paseto-mismatch"
  mkdir -p "$d/mix"
  openssl genpkey -algorithm ed25519 -out "$d/a.pem" 2>/dev/null
  openssl genpkey -algorithm ed25519 -out "$d/b.pem" 2>/dev/null
  # k4.public from keypair A (base64url-nopad), raw-base64 from keypair B (standard).
  local a_url b_std
  a_url="$(openssl pkey -in "$d/a.pem" -pubout -outform DER 2>/dev/null | tail -c 32 | openssl base64 -A | tr '+/' '-_' | tr -d '=')"
  b_std="$(openssl pkey -in "$d/b.pem" -pubout -outform DER 2>/dev/null | tail -c 32 | openssl base64 -A)"
  printf 'k4.public.%s\n' "$a_url" > "$d/mix/paseto.k4.public"
  printf '%s\n' "$b_std" > "$d/mix/paseto.public.raw.b64"
  run "$VERIFY_PASETO" --key-dir "$d/mix"
  [ "$status" -ne 0 ]
  [[ "$output" == *"MISMATCH"* ]]
}
