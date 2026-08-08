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
  APT_CERALIVE_REPO="$V2/mkosi/customize/apt-ceralive-repo.sh"
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

extract_hostname_unit() {
  awk '
    /cat >\/etc\/systemd\/system\/ceralive-hostname\.service <<'\''EOF'\''/ { in_unit = 1; next }
    in_unit && /^EOF$/ { exit }
    in_unit { print }
  ' "$POSTINST_LIB"
}

make_hostname_fixture() {
  local root="$1"
  local bin="$root/bin"
  rm -rf "$root"
  mkdir -p "$root/state" "$root/avahi" "$root/shared" "$bin"
  printf '127.0.0.1\tlocalhost\n' >"$root/hosts"
  printf '0123456789abcdef0123456789abcdef\n' >"$root/machine-id"
  # A live avahi-daemon always answers GetState; seed a RUNNING state so
  # wait_for_avahi_ready probes a ready daemon like hardware. published is left
  # unset (the mock creates it on the first SetHostName) so tests that die before
  # any claim still observe published=<missing>.
  printf '2\n' >"$root/avahi/state"
  extract_hostname_script >"$root/ceralive-set-hostname"
  chmod +x "$root/ceralive-set-hostname"

  cat >"$bin/hostnamectl" <<'SH'
#!/usr/bin/env bash
printf 'hostnamectl %s\n' "$*" >>"$HOSTNAME_CALLS"
[[ "${1:-}" = set-hostname && -n "${2:-}" ]] || exit 2
if [[ "${HOSTNAMECTL_SCENARIO:-normal}" = interrupt ]]; then
  kill -TERM "$PPID"
  exit 143
fi
printf '%s\n' "$2" >"$SYSTEM_HOSTNAME_FILE"
SH
  cat >"$bin/hostname" <<'SH'
#!/usr/bin/env bash
if [[ $# -eq 0 ]]; then
  cat "$SYSTEM_HOSTNAME_FILE"
else
  printf 'hostname %s\n' "$*" >>"$HOSTNAME_CALLS"
  printf '%s\n' "$1" >"$SYSTEM_HOSTNAME_FILE"
fi
SH
  cat >"$bin/systemctl" <<'SH'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$HOSTNAME_CALLS"
[[ "${HOSTNAME_SYSTEMCTL_SCENARIO:-normal}" != fail ]]
SH
  cat >"$bin/ip" <<'SH'
#!/usr/bin/env bash
if [[ "$*" = *"addr show"* ]]; then
  iface="${HOSTNAME_LOCAL_IFACE:-eth0}"
  printf '2: %s    inet %s/24 brd 192.168.78.255 scope global %s\n' \
    "$iface" "${HOSTNAME_LOCAL_IP:-192.168.78.50}" "$iface"
fi
SH
  cat >"$bin/timeout" <<'SH'
#!/usr/bin/env bash
while [[ "${1:-}" = -* ]]; do shift; done
shift
exec "$@"
SH
  cat >"$bin/sync" <<'SH'
#!/usr/bin/env bash
printf 'sync %s\n' "$*" >>"$HOSTNAME_CALLS"
if [[ -n "${SYNC_FAIL_MATCH:-}" && "$*" = *"$SYNC_FAIL_MATCH"* ]]; then
  exit 1
fi
SH
  cat >"$bin/avahi-set-host-name" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
name="${1:?missing hostname}"
mkdir -p "$AVAHI_DEVICE_STATE" "$AVAHI_SHARED_DIR"
printf 'avahi-set-host-name %s\n' "$name" >>"$HOSTNAME_CALLS"

if [[ "${AVAHI_SCENARIO:-normal}" = preowned && "$name" = ceralive ]]; then
  exit 1
fi

if [[ "${AVAHI_SCENARIO:-normal}" =~ ^(concurrent|symmetric-gap)$ \
      && "$name" = ceralive && ! -e "$AVAHI_DEVICE_STATE/gate-passed" ]]; then
  : >"$AVAHI_SHARED_DIR/ready.${AVAHI_CLIENT_ID}"
  flock "$AVAHI_SHARED_DIR/gate.lock" -c :
  : >"$AVAHI_DEVICE_STATE/gate-passed"
fi

attempt_file="$AVAHI_DEVICE_STATE/set-count.${name}"
attempt=0
[[ ! -s "$attempt_file" ]] || attempt="$(cat "$attempt_file")"
attempt=$((attempt + 1))
printf '%s\n' "$attempt" >"$attempt_file"

published="$name"
if [[ "${AVAHI_SCENARIO:-normal}" = symmetric-gap && "$name" = ceralive && "$attempt" -eq 1 ]]; then
  published="ceralive-2"
else
  case ",${HOSTNAME_OCCUPIED_NAMES:-}," in
    *",${name},"*) published="${name}-2" ;;
  esac
  if [[ "${AVAHI_SCENARIO:-normal}" = rename && "$name" = ceralive ]]; then
    published="ceralive-2"
  fi
fi

if [[ "${AVAHI_SCENARIO:-normal}" =~ ^(concurrent|symmetric-gap)$ && "$published" = "$name" ]]; then
  exec 9>"$AVAHI_SHARED_DIR/owners.lock"
  flock 9
  owner="$AVAHI_SHARED_DIR/owner.${name}"
  if [[ ! -e "$owner" ]]; then
    printf '%s\n' "$AVAHI_CLIENT_ID" >"$owner"
  elif [[ "$(cat "$owner")" != "$AVAHI_CLIENT_ID" ]]; then
    published="${name}-2"
  fi
fi

printf '%s\n' "$published" >"$AVAHI_DEVICE_STATE/published"
printf '2\n' >"$AVAHI_DEVICE_STATE/state"
SH
  cat >"$bin/avahi-resolve" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  -n)
    fqdn="${2:?missing host name}"
    name="${fqdn%.local}"
    stable=0
    case ",${HOSTNAME_OCCUPIED_NAMES:-}," in
      *",${name},"*) stable=1 ;;
    esac
    if [[ "${AVAHI_SCENARIO:-normal}" = rename && "$name" = ceralive ]]; then
      stable=1
    fi
    owner="$AVAHI_SHARED_DIR/owner.${name}"
    if [[ -s "$owner" && "$(cat "$owner")" != "$AVAHI_CLIENT_ID" ]]; then
      stable=1
    fi
    (( stable == 1 )) || exit 1
    printf '%s\n' "$name" >"$AVAHI_DEVICE_STATE/resolved-name"
    printf '%s\t192.0.2.10\n' "$fqdn"
    ;;
  -a)
    address="${2:?missing address}"
    name="$(cat "$AVAHI_DEVICE_STATE/resolved-name")"
    printf '%s\t%s.local\n' "$address" "$name"
    ;;
  *) exit 2 ;;
esac
SH
  cat >"$bin/busctl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *GetState)
    case "${AVAHI_SCENARIO:-normal}" in
      malformed) printf 'malformed-state\n' ;;
      misleading-state) printf 'i 2 trailing-data\n' ;;
      multiline-state) printf 'i 2\ntrailing-record\n' ;;
      slow-ready)
        sc="$AVAHI_DEVICE_STATE/state-poll-count"
        c=0; [[ ! -s "$sc" ]] || c="$(cat "$sc")"; c=$((c + 1)); printf '%s\n' "$c" >"$sc"
        if (( c <= 2 )); then printf 'i 0\n'; else printf 'i %s\n' "$(cat "$AVAHI_DEVICE_STATE/state")"; fi
        ;;
      *) printf 'i %s\n' "$(cat "$AVAHI_DEVICE_STATE/state")" ;;
    esac
    ;;
  *GetHostName)
    count_file="$AVAHI_DEVICE_STATE/get-name-count"
    exec 9>"$AVAHI_DEVICE_STATE/probe.lock"
    flock 9
    count=0
    [[ ! -s "$count_file" ]] || count="$(cat "$count_file")"
    count=$((count + 1))
    printf '%s\n' "$count" >"$count_file"
    if [[ "${AVAHI_SCENARIO:-normal}" = multiline-name ]]; then
      printf 's "%s"\ntrailing-record\n' "$(cat "$AVAHI_DEVICE_STATE/published")"
    elif [[ "${AVAHI_SCENARIO:-normal}" = misleading-name ]]; then
      printf 's "%s" trailing-data\n' "$(cat "$AVAHI_DEVICE_STATE/published")"
    elif [[ "${AVAHI_SCENARIO:-normal}" = stale && "$count" -eq 1 ]]; then
      printf 's "old-hostname"\n'
    else
      printf 's "%s"\n' "$(cat "$AVAHI_DEVICE_STATE/published")"
    fi
    ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$bin"/*
}

emit_hostname_observables() {
  local root="$1"
  [[ ! -f "$root/calls" ]] || cat "$root/calls"
  printf 'index=%s\n' "$(cat "$root/state/host_index" 2>/dev/null || printf '<missing>')"
  printf 'system-hostname=%s\n' "$(cat "$root/system-hostname" 2>/dev/null || printf '<missing>')"
  printf 'hostname-file=%s\n' "$(cat "$root/hostname" 2>/dev/null || printf '<missing>')"
  printf 'hosts=%s\n' "$(awk '$1 == "127.0.1.1" { print $2 }' "$root/hosts")"
  printf 'published=%s\n' "$(cat "$root/avahi/published" 2>/dev/null || printf '<missing>')"
  printf 'get-name-count=%s\n' "$(cat "$root/avahi/get-name-count" 2>/dev/null || printf '0')"
}

run_hostname_script() {
  local root="$1"
  local bin="$root/bin"
  local occupied="${2:-}"
  local scenario="${3:-normal}"
  local client="${4:-device}"
  local shared="${5:-$root/shared}"
  local hostnamectl_scenario="${6:-normal}"
  local mode="${7:-}"
  local -a script_args=()
  [[ -z "$mode" ]] || script_args+=("$mode")
  local rc=0
  env HOSTNAME_CALLS="$root/calls" \
      SYSTEM_HOSTNAME_FILE="$root/system-hostname" \
      HOSTNAME_OCCUPIED_NAMES="$occupied" \
      HOSTNAMECTL_SCENARIO="$hostnamectl_scenario" \
      HOSTNAME_SYSTEMCTL_SCENARIO="${HOSTNAME_SYSTEMCTL_SCENARIO:-normal}" \
      HOSTNAME_LOCAL_IP="${HOSTNAME_LOCAL_IP:-192.168.78.50}" \
      HOSTNAME_LOCAL_IFACE="${HOSTNAME_LOCAL_IFACE:-eth0}" \
      AVAHI_SCENARIO="$scenario" \
      AVAHI_CLIENT_ID="$client" \
      AVAHI_DEVICE_STATE="$root/avahi" \
      AVAHI_SHARED_DIR="$shared" \
      CERALIVE_HOSTNAME_STATE_DIR="$root/state" \
      CERALIVE_HOSTNAME_LOCK_FILE="$root/run/hostname.lock" \
      CERALIVE_HOSTS_FILE="$root/hosts" \
      CERALIVE_HOSTNAME_FILE="$root/hostname" \
      CERALIVE_MACHINE_ID_FILE="$root/machine-id" \
      HOSTNAMECTL_BIN="$bin/hostnamectl" \
      HOSTNAME_BIN="$bin/hostname" \
      IP_BIN="$root/bin/ip" \
      TIMEOUT_BIN="$root/bin/timeout" \
      SYNC_BIN="$root/bin/sync" \
      AVAHI_SET_HOSTNAME_BIN="$root/bin/avahi-set-host-name" \
      BUSCTL_BIN="$root/bin/busctl" \
      AVAHI_RESOLVE_BIN="$root/bin/avahi-resolve" \
      SYSTEMCTL_BIN="$root/bin/systemctl" \
      CERALIVE_HOSTNAME_MAX_INDEX=4 \
      CERALIVE_HOSTNAME_MAX_WAIT=4 \
      CERALIVE_HOSTNAME_MAX_PROBES=4 \
      CERALIVE_HOSTNAME_POLL_INTERVAL=0 \
      CERALIVE_HOSTNAME_STABLE_CHECKS=2 \
      CERALIVE_HOSTNAME_CONTENTION_RETRIES=4 \
      CERALIVE_HOSTNAME_CONTENTION_BACKOFF_MAX=0 \
      bash "$root/ceralive-set-hostname" "${script_args[@]}" || rc=$?
  emit_hostname_observables "$root"
  return "$rc"
}

run_concurrent_hostname_scripts() {
  local root_a="$1" root_b="$2" shared="$3" scenario="${4:-concurrent}"
  make_hostname_fixture "$root_a"
  make_hostname_fixture "$root_b"
  mkdir -p "$shared"
  exec 8>"$shared/gate.lock"
  flock 8

  run_hostname_script "$root_a" "" "$scenario" device-a "$shared" >"$root_a/output" 2>&1 &
  local pid_a=$!
  run_hostname_script "$root_b" "" "$scenario" device-b "$shared" >"$root_b/output" 2>&1 &
  local pid_b=$!
  local observed=0
  for _ in $(seq 1 200); do
    if [[ -e "$shared/ready.device-a" && -e "$shared/ready.device-b" ]]; then
      observed=1
      break
    fi
    if ! kill -0 "$pid_a" 2>/dev/null && ! kill -0 "$pid_b" 2>/dev/null; then
      break
    fi
    sleep 0.01
  done
  flock -u 8

  local rc=0
  wait "$pid_a" || rc=1
  wait "$pid_b" || rc=1
  printf 'overlap-observed=%s\n' "$observed"
  sed 's/^/device-a: /' "$root_a/output"
  sed 's/^/device-b: /' "$root_b/output"
  return "$rc"
}

@test "hostname: no collision commits and publishes ceralive" {
  local root="$BATS_TEST_TMPDIR/no-collision"
  make_hostname_fixture "$root"
  run run_hostname_script "$root"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hostnamectl set-hostname ceralive"* ]]
  [[ "$output" == *"index=1"* ]]
  [[ "$output" == *"system-hostname=ceralive"* ]]
  [[ "$output" == *"hostname-file=ceralive"* ]]
  [[ "$output" == *"hosts=ceralive"* ]]
  [[ "$output" == *"published=ceralive"* ]]
  printf '%s\n' "$output"
}

# Real Rock 5B+ regression (2026-07-19, empirically reproduced against live
# avahi): the baked /etc/hostname=ceralive makes avahi already publish ceralive,
# so avahi-set-host-name ceralive returns AVAHI_ERR_NO_CHANGE (exit 1). The old
# claim treated that as a lost claim and died, cascading DEPEND failures across
# the whole appliance. The fix accepts "already own it" as success.
@test "hostname: avahi already owns the baked name (NO_CHANGE) is accepted as success" {
  local root="$BATS_TEST_TMPDIR/preowned"
  make_hostname_fixture "$root"
  printf 'ceralive\n' >"$root/avahi/published"
  run run_hostname_script "$root" "" preowned
  [ "$status" -eq 0 ]
  [[ "$output" == *"avahi-set-host-name ceralive"* ]]
  [[ "$output" == *"hostnamectl set-hostname ceralive"* ]]
  [[ "$output" == *"index=1"* ]]
  [[ "$output" == *"system-hostname=ceralive"* ]]
  [[ "$output" == *"hosts=ceralive"* ]]
  [[ "$output" == *"published=ceralive"* ]]
  [[ "$output" != *"avahi-set-host-name ceralive2"* ]]
  printf '%s\n' "$output"
}

# wait_for_avahi_ready must poll GetState until the daemon is query-ready rather
# than issue the first claim into a cold daemon. slow-ready reports not-ready
# (state 0) for the first two GetState calls, then RUNNING.
@test "hostname: allocation waits for avahi to become query-ready" {
  local root="$BATS_TEST_TMPDIR/slow-ready"
  make_hostname_fixture "$root"
  run run_hostname_script "$root" "" slow-ready
  [ "$status" -eq 0 ]
  [[ "$output" == *"system-hostname=ceralive"* ]]
  [[ "$output" == *"published=ceralive"* ]]
  [ "$(cat "$root/avahi/state-poll-count")" -ge 3 ]
  printf '%s\n' "$output"
}

@test "hostname: occupied ceralive commits and publishes ceralive2" {
  local root="$BATS_TEST_TMPDIR/one-collision"
  make_hostname_fixture "$root"
  run run_hostname_script "$root" "ceralive"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hostnamectl set-hostname ceralive2"* ]]
  [[ "$output" == *"index=2"* ]]
  [[ "$output" == *"system-hostname=ceralive2"* ]]
  [[ "$output" == *"hostname-file=ceralive2"* ]]
  [[ "$output" == *"hosts=ceralive2"* ]]
  [[ "$output" == *"published=ceralive2"* ]]
  [[ "$output" != *"system-hostname=ceralive-2"* ]]
  printf '%s\n' "$output"
}

@test "hostname: occupied ceralive and ceralive2 commit and publish ceralive3" {
  local root="$BATS_TEST_TMPDIR/two-collisions"
  make_hostname_fixture "$root"
  run run_hostname_script "$root" "ceralive,ceralive2"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hostnamectl set-hostname ceralive3"* ]]
  [[ "$output" == *"index=3"* ]]
  [[ "$output" == *"system-hostname=ceralive3"* ]]
  [[ "$output" == *"hostname-file=ceralive3"* ]]
  [[ "$output" == *"published=ceralive3"* ]]
  printf '%s\n' "$output"
}

@test "hostname: concurrent first boots establish distinct deterministic names" {
  local root_a="$BATS_TEST_TMPDIR/concurrent-a"
  local root_b="$BATS_TEST_TMPDIR/concurrent-b"
  local shared="$BATS_TEST_TMPDIR/concurrent-shared"
  run run_concurrent_hostname_scripts "$root_a" "$root_b" "$shared"
  [ "$status" -eq 0 ]
  [[ "$output" == *"overlap-observed=1"* ]]
  local concurrent_output="$output"
  run bash -c "printf '%s\n' \"\$(cat '$root_a/system-hostname')\" \"\$(cat '$root_b/system-hostname')\" | sort | paste -sd,"
  [ "$status" -eq 0 ]
  [ "$output" = "ceralive,ceralive2" ]
  [ "$(cat "$root_a/system-hostname")" = "$(cat "$root_a/hostname")" ]
  [ "$(cat "$root_a/hostname")" = "$(cat "$root_a/avahi/published")" ]
  [ "$(cat "$root_b/system-hostname")" = "$(cat "$root_b/hostname")" ]
  [ "$(cat "$root_b/hostname")" = "$(cat "$root_b/avahi/published")" ]
  printf '%s\n' "$concurrent_output"
}

@test "hostname: symmetric Avahi renames retry the unowned lower candidate" {
  local root_a="$BATS_TEST_TMPDIR/symmetric-gap-a"
  local root_b="$BATS_TEST_TMPDIR/symmetric-gap-b"
  local shared="$BATS_TEST_TMPDIR/symmetric-gap-shared"
  run run_concurrent_hostname_scripts "$root_a" "$root_b" "$shared" symmetric-gap
  [ "$status" -eq 0 ]
  [[ "$output" == *"overlap-observed=1"* ]]
  [[ "$output" == *"has no stable owner; retrying the same deterministic candidate"* ]]
  local race_output="$output"
  run bash -c "printf '%s\n' \"\$(cat '$root_a/system-hostname')\" \"\$(cat '$root_b/system-hostname')\" | sort | paste -sd,"
  [ "$status" -eq 0 ]
  [ "$output" = "ceralive,ceralive2" ]
  [ "$(cat "$root_a/system-hostname")" = "$(cat "$root_a/avahi/published")" ]
  [ "$(cat "$root_b/system-hostname")" = "$(cat "$root_b/avahi/published")" ]
  printf '%s\n' "$race_output"
}

@test "hostname: stale Avahi snapshot is retried without skipping ceralive" {
  local root="$BATS_TEST_TMPDIR/stale-probe"
  make_hostname_fixture "$root"
  run run_hostname_script "$root" "" stale
  [ "$status" -eq 0 ]
  [[ "$output" == *"index=1"* ]]
  [[ "$output" == *"system-hostname=ceralive"* ]]
  [[ "$output" == *"hostname-file=ceralive"* ]]
  [[ "$output" == *"published=ceralive"* ]]
  [[ "$output" == *"get-name-count=3"* ]]
  printf '%s\n' "$output"
}

@test "hostname: malformed Avahi snapshots fail closed without persisting identity" {
  local root="$BATS_TEST_TMPDIR/malformed-probe"
  make_hostname_fixture "$root"
  run run_hostname_script "$root" "" malformed
  [ "$status" -ne 0 ]
  [[ "$output" == *"index=<missing>"* ]]
  [[ "$output" == *"system-hostname=<missing>"* ]]
  [[ "$output" == *"hostname-file=<missing>"* ]]
  printf '%s\n' "$output"
}

@test "hostname: Avahi automatic hyphen rename advances to deterministic next candidate" {
  local root="$BATS_TEST_TMPDIR/avahi-rename"
  make_hostname_fixture "$root"
  run run_hostname_script "$root" "" rename
  [ "$status" -eq 0 ]
  [[ "$output" == *"avahi-set-host-name ceralive"* ]]
  [[ "$output" == *"avahi-set-host-name ceralive2"* ]]
  [[ "$output" == *"index=2"* ]]
  [[ "$output" == *"system-hostname=ceralive2"* ]]
  [[ "$output" == *"hostname-file=ceralive2"* ]]
  [[ "$output" == *"published=ceralive2"* ]]
  [[ "$output" != *"system-hostname=ceralive-2"* ]]
  printf '%s\n' "$output"
}

@test "hostname: restart reapplies persisted identity to system and Avahi" {
  local root="$BATS_TEST_TMPDIR/restart"
  make_hostname_fixture "$root"
  mkdir -p "$root/data"
  ln -s "$root/data/host_index" "$root/state/host_index"
  ln -s "$root/data/hostname.lock" "$root/state/hostname.lock"
  run run_hostname_script "$root"
  [ "$status" -eq 0 ]
  [ -L "$root/state/host_index" ]
  [ -L "$root/state/hostname.lock" ]
  [ ! -e "$root/data/hostname.lock" ]
  [ -f "$root/run/hostname.lock" ]
  [ "$(cat "$root/data/host_index")" = 1 ]
  local first_boot_output="$output"

  printf 'factory-seed\n' >"$root/hostname"
  printf 'factory-seed\n' >"$root/system-hostname"
  rm -f "$root/avahi/published" "$root/avahi/get-name-count" "$root/calls"
  run run_hostname_script "$root"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hostnamectl set-hostname ceralive"* ]]
  [[ "$output" == *"index=1"* ]]
  [[ "$output" == *"system-hostname=ceralive"* ]]
  [[ "$output" == *"hostname-file=ceralive"* ]]
  [[ "$output" == *"hosts=ceralive"* ]]
  [[ "$output" == *"published=ceralive"* ]]
  printf '%s\n--- restart ---\n%s\n' "$first_boot_output" "$output"
}

@test "hostname: stale persisted lock symlink is ignored without clobbering its target" {
  local root="$BATS_TEST_TMPDIR/stale-lock-symlink"
  make_hostname_fixture "$root"
  printf 'do-not-clobber\n' >"$root/victim"
  ln -s "$root/victim" "$root/state/hostname.lock"

  run run_hostname_script "$root"
  [ "$status" -eq 0 ]
  [ "$(cat "$root/victim")" = do-not-clobber ]
  [ -L "$root/state/hostname.lock" ]
  [ -f "$root/run/hostname.lock" ]
  [[ "$output" == *"system-hostname=ceralive"* ]]
  [[ "$output" == *"published=ceralive"* ]]
  printf '%s\n' "$output"
}

@test "hostname: identity files are synced before the persisted claim completes" {
  local root="$BATS_TEST_TMPDIR/durable-identity"
  make_hostname_fixture "$root"

  run run_hostname_script "$root"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^sync -f ' "$root/calls")" -eq 9 ]
  grep -Fq "sync -f $root/hostname" "$root/calls"
  grep -Fq "sync -f $root/hosts" "$root/calls"
  grep -Fq "sync -f $root/state/host_index" "$root/calls"
  [ "$(tail -n 1 "$root/calls")" = "sync -f $root/state" ]
  printf '%s\n' "$output"
}

@test "hostname: interrupted commit leaves no identity and restart converges" {
  local root="$BATS_TEST_TMPDIR/interrupted-commit"
  make_hostname_fixture "$root"
  run run_hostname_script "$root" "" normal device "$root/shared" interrupt
  [ "$status" -ne 0 ]
  [[ "$output" == *"index=<missing>"* ]]
  [[ "$output" == *"system-hostname=<missing>"* ]]
  [[ "$output" == *"hostname-file=<missing>"* ]]
  [[ "$output" == *"published=ceralive"* ]]
  [ -f "$root/run/hostname.lock" ]
  local interrupted_output="$output"

  run run_hostname_script "$root"
  [ "$status" -eq 0 ]
  [[ "$output" == *"index=1"* ]]
  [[ "$output" == *"system-hostname=ceralive"* ]]
  [[ "$output" == *"hostname-file=ceralive"* ]]
  [[ "$output" == *"published=ceralive"* ]]
  printf '%s\n--- recovered ---\n%s\n' "$interrupted_output" "$output"
}

@test "hostname: claim tooling and identity consumer ordering ship together" {
  local hostname_unit
  run bash -c "sed 's/#.*//' '$V2/manifests/packages/shared.list' | awk 'NF { print \$1 }' | grep -Fx avahi-utils"
  [ "$status" -eq 0 ]
  hostname_unit="$(extract_hostname_unit)"
  grep -Fq 'Requires=ceralive-migrate-data.service' "$POSTINST_LIB"
  grep -Fq 'RequiresMountsFor=/data' "$POSTINST_LIB"
  [[ "$hostname_unit" == *'ExecStartPost=/usr/bin/systemctl --no-block start ceralive.service'* ]]
  [[ "$hostname_unit" == *'ExecStartPost=/usr/bin/systemctl --no-block restart ceralive-tls-firstboot.service nginx.service ceralive-hawkbit-provision.service ceralive-healthcheck.service'* ]]
  [[ "$hostname_unit" == *'RemainAfterExit=yes'* ]]
  [[ "$hostname_unit" != *'OnSuccess='* ]]
  grep -Fq 'ceralive-hostname-reconcile.service' "$POSTINST_LIB"
  grep -Fq 'ExecStart=/usr/local/sbin/ceralive-set-hostname reconcile' "$POSTINST_LIB"
  grep -Fq 'ceralive-hostname-reconcile.timer' "$POSTINST_LIB"
  grep -Fq 'OnUnitActiveSec=30s' "$POSTINST_LIB"
  grep -Fq 'Unit=ceralive-hostname-reconcile.service' "$POSTINST_LIB"
  grep -Fq 'RuntimeDirectory=ceralive-hostname' "$POSTINST_LIB"
  # ceralive-hostname.service MUST wait for network-online.target (link up), not
  # just NetworkManager.service (daemon up) — else the mDNS claim runs before eth0
  # links and every Requires= consumer cascades to "Dependency failed" on first boot
  # (real Rock 5B+ regression). After=/Wants= both carry network-online.target.
  grep -Fq 'After=systemd-machine-id-commit.service ceralive-migrate-data.service NetworkManager.service network-online.target avahi-daemon.service' "$POSTINST_LIB"
  grep -Fq 'Wants=NetworkManager.service network-online.target avahi-daemon.service' "$POSTINST_LIB"
  [[ "$hostname_unit" == *'After='*'network-online.target'*'avahi-daemon.service'* ]]
  [[ "$hostname_unit" == *'Wants=NetworkManager.service network-online.target avahi-daemon.service'* ]]
  # Graceful degradation: appliance consumers Wants= (not Requires=) the hostname
  # claim, so a failed claim boots on the baked default instead of cascading
  # DEPEND failures across ceralive.service/nginx/tls/hawkbit. Only the reconcile
  # retry service keeps a hard Requires= (its failure is harmless, timer refires).
  grep -Fq 'Wants=ceralive-hostname.service' "$POSTINST_LIB"
  grep -Fq 'Wants=ceralive-hostname.service' "$V2/mkosi/runtime/ceralive-tls-firstboot.service"
  ! grep -Fq 'Requires=ceralive-hostname.service' "$V2/mkosi/runtime/ceralive-tls-firstboot.service"
  grep -Fq 'Requires=ceralive-hostname.service' "$POSTINST_LIB"
  grep -Fq 'x509 -in "$cert" -noout -checkhost "$FQDN"' "$V2/mkosi/runtime/ceralive-tls-firstboot.sh"
  ! grep -Fq 'HOSTNAME_STAMP=' "$V2/mkosi/runtime/ceralive-tls-firstboot.sh"
  grep -Fq 'After=ceralive-migrate-data.service ceralive-hostname.service network-online.target' \
    "$V2/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"
  grep -Fq 'Wants=network-online.target ceralive-hostname.service' \
    "$V2/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"
  ! grep -Fq 'Requires=ceralive-hostname.service' "$V2/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"
}

@test "hostname: aligned reconciliation is a no-op" {
  local root="$BATS_TEST_TMPDIR/reconcile-aligned"
  make_hostname_fixture "$root"
  run run_hostname_script "$root"
  [ "$status" -eq 0 ]

  : >"$root/calls"
  run run_hostname_script "$root" "" normal device "$root/shared" normal reconcile
  [ "$status" -eq 0 ]
  [[ "$output" == *"identity already aligned at ceralive.local"* ]]
  [[ "$output" != *"avahi-set-host-name"* ]]
  [[ "$output" != *"systemctl --no-block restart"* ]]
  [[ "$output" == *"index=1"* ]]
  [[ "$output" == *"published=ceralive"* ]]
  printf '%s\n' "$output"
}

@test "hostname: late Avahi rename advances identity and restarts every consumer" {
  local root="$BATS_TEST_TMPDIR/reconcile-conflict"
  make_hostname_fixture "$root"
  run run_hostname_script "$root"
  [ "$status" -eq 0 ]

  printf 'ceralive-2\n' >"$root/avahi/published"
  printf '2\n' >"$root/avahi/state"
  : >"$root/calls"
  run run_hostname_script "$root" "" rename device "$root/shared" normal reconcile
  [ "$status" -eq 0 ]
  [[ "$output" == *"publication diverged"* ]]
  [[ "$output" == *"index=2"* ]]
  [[ "$output" == *"system-hostname=ceralive2"* ]]
  [[ "$output" == *"hostname-file=ceralive2"* ]]
  [[ "$output" == *"hosts=ceralive2"* ]]
  [[ "$output" == *"published=ceralive2"* ]]
  [[ "$output" == *"systemctl --no-block restart ceralive-tls-firstboot.service nginx.service ceralive.service ceralive-hawkbit-provision.service ceralive-healthcheck.service"* ]]
  [[ "$output" != *"system-hostname=ceralive-2"* ]]
  printf '%s\n' "$output"
}

@test "hostname: registering publication defers reconciliation without churn" {
  local root="$BATS_TEST_TMPDIR/reconcile-registering"
  make_hostname_fixture "$root"
  run run_hostname_script "$root"
  [ "$status" -eq 0 ]

  printf '1\n' >"$root/avahi/state"
  : >"$root/calls"
  run run_hostname_script "$root" "" normal device "$root/shared" normal reconcile
  [ "$status" -eq 0 ]
  [[ "$output" == *"publication is still registering; deferring"* ]]
  [[ "$output" != *"avahi-set-host-name"* ]]
  [[ "$output" != *"systemctl --no-block restart"* ]]
  [[ "$output" == *"index=1"* ]]
  printf '%s\n' "$output"
}

@test "hostname: malformed reconciliation probe fails closed without mutation" {
  local root="$BATS_TEST_TMPDIR/reconcile-malformed"
  make_hostname_fixture "$root"
  run run_hostname_script "$root"
  [ "$status" -eq 0 ]

  : >"$root/calls"
  run run_hostname_script "$root" "" malformed device "$root/shared" normal reconcile
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot read a strict Avahi publication snapshot"* ]]
  [[ "$output" != *"avahi-set-host-name"* ]]
  [[ "$output" != *"systemctl --no-block restart"* ]]
  [[ "$output" == *"index=1"* ]]
  [[ "$output" == *"system-hostname=ceralive"* ]]
  [[ "$output" == *"hostname-file=ceralive"* ]]
  printf '%s\n' "$output"
}

@test "hostname: interrupted consumer requeue is retried without reallocating" {
  local root="$BATS_TEST_TMPDIR/reconcile-requeue-interruption"
  make_hostname_fixture "$root"
  mkdir -p "$root/data"
  ln -s "$root/data/hostname_consumers_pending" "$root/state/hostname_consumers_pending"
  run run_hostname_script "$root"
  [ "$status" -eq 0 ]

  printf 'ceralive-2\n' >"$root/avahi/published"
  printf '2\n' >"$root/avahi/state"
  : >"$root/calls"
  HOSTNAME_SYSTEMCTL_SCENARIO=fail run run_hostname_script \
    "$root" "" rename device "$root/shared" normal reconcile
  [ "$status" -ne 0 ]
  [ -e "$root/state/hostname_consumers_pending" ]
  [ -L "$root/state/hostname_consumers_pending" ]
  [ -e "$root/data/hostname_consumers_pending" ]
  [[ "$output" == *"failed to requeue identity consumers"* ]]
  [[ "$output" == *"index=2"* ]]
  [[ "$output" == *"system-hostname=ceralive2"* ]]
  [[ "$output" == *"published=ceralive2"* ]]

  : >"$root/calls"
  run run_hostname_script "$root" "" normal device "$root/shared" normal reconcile
  [ "$status" -eq 0 ]
  [ ! -e "$root/state/hostname_consumers_pending" ]
  [ -L "$root/state/hostname_consumers_pending" ]
  [ ! -e "$root/data/hostname_consumers_pending" ]
  [[ "$output" == *"completed pending consumer restart for ceralive2.local"* ]]
  [[ "$output" == *"identity already aligned at ceralive2.local"* ]]
  [[ "$output" != *"avahi-set-host-name"* ]]
  [[ "$output" == *"systemctl --no-block restart ceralive-tls-firstboot.service nginx.service ceralive.service ceralive-hawkbit-provision.service ceralive-healthcheck.service"* ]]
  printf '%s\n' "$output"
}

@test "hostname: TLS certificate follows the committed identity and stays stable" {
  local tls_script="$V2/mkosi/runtime/ceralive-tls-firstboot.sh"
  local root="$BATS_TEST_TMPDIR/tls-hostname"
  local bin="$root/bin"
  local cert="$root/state/ceralive.crt"
  local key="$root/state/ceralive.key"
  mkdir -p "$bin"

  grep -Fq 'CERALIVE_TLS_STATE_DIR' "$tls_script"
  cat >"$bin/hostname" <<'SH'
#!/usr/bin/env bash
cat "$TLS_TEST_HOSTNAME_FILE"
SH
  cat >"$bin/ip" <<'SH'
#!/usr/bin/env bash
printf '2: eth0    inet 192.0.2.20/24 brd 192.0.2.255 scope global eth0\n'
SH
  chmod +x "$bin/hostname" "$bin/ip"

  printf 'ceralive\n' >"$root/runtime-hostname"
  TLS_TEST_HOSTNAME_FILE="$root/runtime-hostname" \
    CERALIVE_TLS_STATE_DIR="$root/state" HOSTNAME_BIN="$bin/hostname" IP_BIN="$bin/ip" \
    run bash "$tls_script"
  [ "$status" -eq 0 ]
  [ -s "$cert" ]
  [ -s "$key" ]
  local first_fingerprint
  first_fingerprint="$(openssl x509 -in "$cert" -noout -fingerprint -sha256)"
  [[ "$(openssl x509 -in "$cert" -noout -checkhost ceralive.local 2>/dev/null)" == *"does match certificate"* ]]

  TLS_TEST_HOSTNAME_FILE="$root/runtime-hostname" \
    CERALIVE_TLS_STATE_DIR="$root/state" HOSTNAME_BIN="$bin/hostname" IP_BIN="$bin/ip" \
    run bash "$tls_script"
  [ "$status" -eq 0 ]
  [ "$(openssl x509 -in "$cert" -noout -fingerprint -sha256)" = "$first_fingerprint" ]

  printf 'ceralive2\n' >"$root/runtime-hostname"
  TLS_TEST_HOSTNAME_FILE="$root/runtime-hostname" \
    CERALIVE_TLS_STATE_DIR="$root/state" HOSTNAME_BIN="$bin/hostname" IP_BIN="$bin/ip" \
    run bash "$tls_script"
  [ "$status" -eq 0 ]
  [ "$(openssl x509 -in "$cert" -noout -fingerprint -sha256)" != "$first_fingerprint" ]
  [[ "$(openssl x509 -in "$cert" -noout -checkhost ceralive2.local 2>/dev/null)" == *"does match certificate"* ]]
  [[ "$(openssl x509 -in "$cert" -noout -checkhost ceralive.local 2>/dev/null)" != *"does match certificate"* ]]
  [ "$(openssl x509 -in "$cert" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum | awk '{print $1}')" = \
    "$(openssl pkey -in "$key" -pubout -outform DER | sha256sum | awk '{print $1}')" ]
  printf 'first=%s\nsecond=%s\n' "$first_fingerprint" \
    "$(openssl x509 -in "$cert" -noout -fingerprint -sha256)"
}

@test "dev-sync: target selection is explicit when deterministic names can collide" {
  local missing="$BATS_TEST_TMPDIR/no-dev-sync-config.yaml"
  run env -u DEV_SYNC_TARGET_HOST -u DEV_SYNC_TARGET_IP \
    DEV_SYNC_CONFIG="$missing" DRY_RUN=1 bash "$V2/lib/dev-sync/transport.sh" resolve
  [ "$status" -ne 0 ]
  [[ "$output" == *"neither DEV_SYNC_TARGET_HOST nor DEV_SYNC_TARGET_IP is set"* ]]
  [[ "$output" != *"ceralive.local"* ]]
  printf '%s\n' "$output"
}

@test "hostname: valid-looking D-Bus output with trailing data fails closed" {
  local scenario root
  for scenario in misleading-state misleading-name; do
    root="$BATS_TEST_TMPDIR/$scenario"
    make_hostname_fixture "$root"
    run run_hostname_script "$root" "" "$scenario"
    [ "$status" -ne 0 ]
    [[ "$output" == *"index=<missing>"* ]]
    [[ "$output" == *"system-hostname=<missing>"* ]]
    [[ "$output" == *"hostname-file=<missing>"* ]]
    printf 'scenario=%s\n%s\n' "$scenario" "$output"
  done
}

@test "hostname: multiline D-Bus output fails closed without persisting identity" {
  local scenario root
  for scenario in multiline-state multiline-name; do
    root="$BATS_TEST_TMPDIR/$scenario"
    make_hostname_fixture "$root"
    run run_hostname_script "$root" "" "$scenario"
    [ "$status" -ne 0 ]
    [[ "$output" == *"index=<missing>"* ]]
    [[ "$output" == *"hostname-file=<missing>"* ]]
    printf 'scenario=%s\n%s\n' "$scenario" "$output"
  done
}

@test "hostname: setup AP address alone is not accepted as publishable identity" {
  local root="$BATS_TEST_TMPDIR/setup-ap-only"
  make_hostname_fixture "$root"
  HOSTNAME_LOCAL_IP=192.168.42.1 HOSTNAME_LOCAL_IFACE=wlan0 run run_hostname_script "$root"
  [ "$status" -ne 0 ]
  [[ "$output" == *"index=<missing>"* ]]
  [[ "$output" == *"hostname-file=<missing>"* ]]
  printf '%s\n' "$output"
}

@test "hostname: same-subnet non-AP LAN address remains publishable" {
  local root="$BATS_TEST_TMPDIR/same-subnet-lan"
  make_hostname_fixture "$root"
  HOSTNAME_LOCAL_IP=192.168.42.50 HOSTNAME_LOCAL_IFACE=eth0 run run_hostname_script "$root"
  [ "$status" -eq 0 ]
  [[ "$output" == *"system-hostname=ceralive"* ]]
  [[ "$output" == *"published=ceralive"* ]]
  printf '%s\n' "$output"
}

@test "hostname: Ethernet IPv4 link-local remains a publishable collision domain" {
  local root="$BATS_TEST_TMPDIR/ethernet-link-local"
  make_hostname_fixture "$root"
  HOSTNAME_LOCAL_IP=169.254.50.2 HOSTNAME_LOCAL_IFACE=eth0 run run_hostname_script "$root"
  [ "$status" -eq 0 ]
  [[ "$output" == *"system-hostname=ceralive"* ]]
  [[ "$output" == *"published=ceralive"* ]]
  printf '%s\n' "$output"
}

@test "hostname: malformed persisted index fails closed without reinterpretation" {
  local root="$BATS_TEST_TMPDIR/malformed-index"
  make_hostname_fixture "$root"
  printf '2stale\n' >"$root/state/host_index"
  run run_hostname_script "$root"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid persisted hostname index"* ]]
  [[ "$output" == *"index=2stale"* ]]
  [[ "$output" == *"system-hostname=<missing>"* ]]
  [[ "$output" == *"hostname-file=<missing>"* ]]
  [[ "$output" == *"published=<missing>"* ]]
  printf '%s\n' "$output"
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

# runtime_pkg_lists — the SHIPPED common.sh::runtime_pkg_list_files, run in a
# subshell so its `set -e` + ERR trap cannot escape into bats. Honours
# CERALIVE_DEBUG_IMAGE from the caller's environment.
runtime_pkg_lists() {
  bash -c 'source "$1"; runtime_pkg_list_files "$2" "$3"' bash \
    "$COMMON_SH" "$V2/manifests/packages/shared.list" "$V2/manifests/packages"
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

  # File selection goes through the SHIPPED common.sh helper, never a bare
  # `*.delta.list` glob: that glob would fold the debug-only development delta
  # into this synthetic rootfs and make every production parity assertion below
  # vacuously pass on packages a production image does not install.
  local lists=() list
  while IFS= read -r list; do [[ -n "$list" ]] && lists+=("$list"); done \
    < <(runtime_pkg_lists)
  local packages=() package
  while IFS= read -r package; do [[ -n "$package" ]] && packages+=("$package"); done \
    < <(sed -e 's/#.*//' "${lists[@]}" | awk 'NF{print $1}')
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

  run grep -F '/usr/lib/firmware/qcom' "$V2/mkosi/mkosi.images/platform/mkosi.postinst"
  [ "$status" -eq 0 ]

  run grep -F '/usr/lib/firmware/intel' "$V2/mkosi/mkosi.images/app/mkosi.postinst.chroot"
  [ "$status" -ne 0 ]

  run grep -F '/usr/share/icons/Adwaita' "$V2/mkosi/mkosi.images/app/mkosi.postinst.chroot"
  [ "$status" -eq 0 ]
}

# --- the wiring that makes the budget a BUILD gate, not a CI curiosity --------
#
# For three releases the "BLOCKING size gate" never ran against a real image:
# orchestrate.sh had no measurement stage at all, and the only live caller was
# v2-ci.yml's size job, which measures a synthetic 4 KB tree. Both RK3588 boards
# shipped 65-76 MB over the committed ceiling while README/AGENTS claimed the gate
# ran after every build. These cases pin the [6c/9] stage that closed that gap:
# where it sits, that it propagates a failure, and that it cannot run on inputs
# that have no real rootfs behind them. Root-free and hardware-free — the shipped
# block is extracted and executed against synthetic KB-sized trees.

# Emit the real [6c/9] block out of orchestrate.sh so the cases below execute the
# shipped code rather than a copy of it.
extract_size_gate_block() {
  awk '
    /^  if \[\[/ { inblk = 1; buf = $0; next }
    inblk {
      buf = buf ORS $0
      if ($0 == "  fi") { if (buf ~ /\[6c\/9\]/) { print buf; exit } ; inblk = 0 }
    }
  ' "$V2/lib/orchestrate.sh"
}

# Drive that block with stubbed logging, a caller-supplied budget file and a
# caller-supplied MEASURE_SIZE_SH, exactly as main() would.
run_size_gate_block() {
  local install_boot_bsp="$1" budget_json="$2" artifact="$3" measure_sh="${4:-$MEASURE_SH}"
  local baseline_spy="${5:-}"
  run bash -c "
    set -euo pipefail
    log_info()  { printf '[INFO] %s\n' \"\$*\"; }
    log_warn()  { printf '[WARN] %s\n' \"\$*\"; }
    die()       { printf '[ERROR] %s\n' \"\$*\" >&2; exit 1; }
    compare_size_against_baseline() { if [[ -n '${baseline_spy}' ]]; then touch '${baseline_spy}'; fi; printf '[INFO] baseline-compare %s\n' \"\$1\"; }
    export SIZE_BUDGET_JSON='${budget_json}'
    MEASURE_SIZE_SH='${measure_sh}'
    INSTALL_BOOT_BSP='${install_boot_bsp}'
    board=rock-5b-plus
    artifact='${artifact}'
    $(extract_size_gate_block)
  "
}

# Emit the real compare_size_against_baseline() out of orchestrate.sh so the
# relative-gate cases execute the shipped function rather than a copy of it.
extract_baseline_compare_fn() {
  awk '
    /^compare_size_against_baseline\(\) \{/ { inblk = 1 }
    inblk { print }
    inblk && /^\}/ { exit }
  ' "$V2/lib/orchestrate.sh"
}

run_baseline_compare() {
  local board="$1" artifact="$2" baseline_dir="$3"
  run bash -c "
    set -euo pipefail
    log_info()    { printf '[INFO] %s\n' \"\$*\"; }
    log_warn()    { printf '[WARN] %s\n' \"\$*\"; }
    log_success() { printf '[OK] %s\n' \"\$*\"; }
    die()         { printf '[ERROR] %s\n' \"\$*\" >&2; exit 1; }
    SIZE_BASELINE_DIR='${baseline_dir}'
    CHECK_SIZE_REGRESSION_SH='$V2/ci/check-size-regression.sh'
    $(extract_baseline_compare_fn)
    compare_size_against_baseline '${board}' '${artifact}'
  "
}

@test "size-gate wiring: orchestrate.sh resolves measure-size.sh and invokes it" {
  run grep -Fx 'MEASURE_SIZE_SH="${HERE}/measure-size.sh"' "$V2/lib/orchestrate.sh"
  [ "$status" -eq 0 ]
  [ -x "$MEASURE_SH" ]

  run grep -F '"${MEASURE_SIZE_SH}" "${board}" "${artifact}"' "$V2/lib/orchestrate.sh"
  [ "$status" -eq 0 ]
}

@test "size-gate wiring: the gate runs after the tar is emitted and before parity/disk assembly" {
  # Position is the whole point: measuring before the emit has nothing to measure,
  # and measuring after Stage-4 would already have cut a .raw and a signed .raucb
  # from an over-budget image.
  local emit_line gate_line parity_line disk_line
  emit_line="$(grep -n '\[6/9\] emitting normalized artifact' "$V2/lib/orchestrate.sh" | head -1 | cut -d: -f1)"
  gate_line="$(grep -n '\[6c/9\] enforcing the rootfs size budget' "$V2/lib/orchestrate.sh" | head -1 | cut -d: -f1)"
  parity_line="$(grep -n '\[7/9\] verifying parity' "$V2/lib/orchestrate.sh" | head -1 | cut -d: -f1)"
  disk_line="$(grep -n '\[8/9\] Stage-4 disk assembly' "$V2/lib/orchestrate.sh" | head -1 | cut -d: -f1)"
  [ -n "$emit_line" ] && [ -n "$gate_line" ] && [ -n "$parity_line" ] && [ -n "$disk_line" ]
  [ "$emit_line" -lt "$gate_line" ]
  [ "$gate_line" -lt "$parity_line" ]
  [ "$parity_line" -lt "$disk_line" ]
}

@test "size-gate wiring: DRY_RUN exits the orchestrator before the gate can run" {
  # DRY_RUN ships no rootfs at all, so the gate must be unreachable there — by
  # placement, not by a condition that a later edit could drop.
  local dryrun_exit_line gate_line
  dryrun_exit_line="$(grep -n '=== DRY-RUN complete' "$V2/lib/orchestrate.sh" | head -1 | cut -d: -f1)"
  gate_line="$(grep -n '\[6c/9\] enforcing the rootfs size budget' "$V2/lib/orchestrate.sh" | head -1 | cut -d: -f1)"
  [ -n "$dryrun_exit_line" ] && [ -n "$gate_line" ]
  [ "$dryrun_exit_line" -lt "$gate_line" ]
}

@test "size-gate wiring: the shipped block PASSES an under-budget artifact" {
  local tree="$BATS_TEST_TMPDIR/wired-ok"
  mkdir -p "$tree"
  head -c 4096 /dev/zero > "$tree/a.bin"
  run_size_gate_block 1 "$SIZE_BUDGET_JSON" "$tree"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[6c/9] enforcing the rootfs size budget"* ]]
  [[ "$output" =~ measured=[0-9]+\ budget=1500000000\ \(enforced\) ]]
}

@test "size-gate wiring: the shipped block ABORTS the build on an over-budget artifact" {
  # The non-vacuity leg. Without it an always-passing gate looks identical to a
  # working one — which is exactly the state this stage was added to end.
  local tree="$BATS_TEST_TMPDIR/wired-over"
  mkdir -p "$tree"
  head -c 65536 /dev/zero > "$tree/big.bin"
  local tight="$BATS_TEST_TMPDIR/wired-tight.json"
  printf '{ "rock-5b-plus": { "rootfs_bytes_max": 1024 } }\n' > "$tight"
  run_size_gate_block 1 "$tight" "$tree"
  [ "$status" -ne 0 ]
  [[ "$output" == *"exceeds budget"* ]]
  [[ "$output" == *"rootfs size budget EXCEEDED for board 'rock-5b-plus'"* ]]
  [[ "$output" == *"do NOT raise rootfs_bytes_max"* ]]
}

@test "size-gate wiring: an INSTALL_BOOT_BSP=0 parity build skips the gate LOUDLY" {
  # A kernel-less parity rootfs is not the shipped image, so measuring it would be
  # a vacuous pass. Skipping is correct; skipping silently is not.
  local tree="$BATS_TEST_TMPDIR/wired-parity"
  mkdir -p "$tree"
  head -c 65536 /dev/zero > "$tree/big.bin"
  local tight="$BATS_TEST_TMPDIR/wired-parity-tight.json"
  printf '{ "rock-5b-plus": { "rootfs_bytes_max": 1024 } }\n' > "$tight"

  local sentinel="$BATS_TEST_TMPDIR/measure-ran"
  local spy="$BATS_TEST_TMPDIR/measure-spy.sh"
  printf '#!/usr/bin/env bash\ntouch "%s"\n' "$sentinel" > "$spy"
  chmod +x "$spy"

  run_size_gate_block 0 "$tight" "$tree" "$spy"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[6c/9] INSTALL_BOOT_BSP=0"* ]]
  [ ! -e "$sentinel" ]
}

@test "size-gate wiring: the shipped block runs the relative baseline check after the absolute gate" {
  # The absolute ceiling and the relative baseline are different questions. Wiring
  # only the ceiling leaves size-baseline.json dead data that no real build reads.
  local tree="$BATS_TEST_TMPDIR/wired-baseline"
  mkdir -p "$tree"
  head -c 4096 /dev/zero > "$tree/a.bin"
  local spy="$BATS_TEST_TMPDIR/baseline-compare-ran"
  run_size_gate_block 1 "$SIZE_BUDGET_JSON" "$tree" "$MEASURE_SH" "$spy"
  [ "$status" -eq 0 ]
  [ -e "$spy" ]

  local block
  block="$(extract_size_gate_block)"
  local measure_pos baseline_pos
  measure_pos="$(printf '%s\n' "$block" | grep -n 'MEASURE_SIZE_SH' | head -1 | cut -d: -f1)"
  baseline_pos="$(printf '%s\n' "$block" | grep -n 'compare_size_against_baseline' | head -1 | cut -d: -f1)"
  [ -n "$measure_pos" ] && [ -n "$baseline_pos" ]
  [ "$measure_pos" -lt "$baseline_pos" ]
}

@test "size-baseline: every shipped RK3588 board has a REAL committed per-board baseline" {
  # "Real" means: recorded from an actual measured artifact, not a placeholder.
  # A baseline with no artifact/sha256/commit provenance cannot be re-derived, and
  # a baseline above the blocking ceiling would be a baseline for an image that
  # could never have shipped.
  run python3 - "$V2/ci" "$SIZE_BUDGET_JSON" <<'PY'
import json, re, sys
from pathlib import Path

ci, budget_path = Path(sys.argv[1]), Path(sys.argv[2])
budget = json.loads(budget_path.read_text(encoding="utf-8"))

for board in ("rock-5b-plus", "orange-pi-5-plus"):
    f = ci / ("size-baseline.%s.json" % board)
    assert f.is_file(), "missing per-board baseline: %s" % f.name
    d = json.loads(f.read_text(encoding="utf-8"))
    assert d.get("board") == board, "%s: board field is %r" % (f.name, d.get("board"))
    b = d.get("bytes")
    assert isinstance(b, int) and not isinstance(b, bool) and b > 0, (
        "%s: bytes must be a positive int, got %r" % (f.name, b)
    )
    assert b > 100_000_000, (
        "%s: bytes=%d is not a real rootfs measurement (placeholder?)" % (f.name, b)
    )
    assert re.fullmatch(r"\d{4}-\d{2}-\d{2}", str(d.get("recorded_at", ""))), (
        "%s: recorded_at must be an ISO date" % f.name
    )
    for prov in ("artifact", "artifact_sha256", "commit"):
        assert d.get(prov), "%s: missing provenance field %r" % (f.name, prov)
    assert re.fullmatch(r"[0-9a-f]{64}", d["artifact_sha256"]), (
        "%s: artifact_sha256 must be lowercase hex sha256" % f.name
    )
    ceiling = budget[board]["rootfs_bytes_max"]
    assert b <= ceiling, (
        "%s: baseline %d exceeds the blocking ceiling %d" % (f.name, b, ceiling)
    )
print("BASELINE-REAL-OK")
PY
  [ "$status" -eq 0 ]
  [[ "$output" == *"BASELINE-REAL-OK"* ]]
}

@test "size-baseline: size-budget.json 'measured' agrees byte-for-byte with the per-board baseline" {
  # The measured value is recorded in two registries. They are read by different
  # consumers (the budget file by measure-size.sh's operators, the baseline file by
  # the relative gate), so a silent divergence would make one of them a lie.
  run python3 - "$V2/ci" "$SIZE_BUDGET_JSON" <<'PY'
import json, sys
from pathlib import Path

ci, budget_path = Path(sys.argv[1]), Path(sys.argv[2])
budget = json.loads(budget_path.read_text(encoding="utf-8"))

for board in ("rock-5b-plus", "orange-pi-5-plus"):
    d = json.loads((ci / ("size-baseline.%s.json" % board)).read_text(encoding="utf-8"))
    entry = budget[board]
    assert entry.get("measured") == d["bytes"], (
        "%s: size-budget measured=%r != baseline bytes=%r"
        % (board, entry.get("measured"), d["bytes"])
    )
    for a, b in (("measured_at", "recorded_at"), ("measured_commit", "commit"),
                 ("measured_artifact", "artifact")):
        assert entry.get(a) == d.get(b), (
            "%s: size-budget %s=%r != baseline %s=%r"
            % (board, a, entry.get(a), b, d.get(b))
        )
print("BASELINE-AGREE-OK")
PY
  [ "$status" -eq 0 ]
  [[ "$output" == *"BASELINE-AGREE-OK"* ]]
}

@test "size-baseline: the comparator REFUSES a baseline recorded for a different board" {
  # Baselines differ between boards by tens of MB, so an unchecked file argument
  # yields a confident, meaningless delta. This is the non-vacuity leg.
  run "$V2/ci/check-size-regression.sh" 1412259840 "$V2/ci/size-baseline.rock-5b-plus.json" orange-pi-5-plus
  [ "$status" -eq 2 ]
  [[ "$output" == *"baseline is for board"* ]]

  run "$V2/ci/check-size-regression.sh" 1412259840 "$V2/ci/size-baseline.rock-5b-plus.json" rock-5b-plus
  [ "$status" -eq 0 ]
}

@test "size-baseline: the shipped compare function DIES on a cross-board baseline and SKIPS a missing one" {
  local tree="$BATS_TEST_TMPDIR/baseline-art"
  mkdir -p "$tree"
  head -c 4096 /dev/zero > "$tree/a.bin"

  # A board with no committed baseline is the newly-added-board allowance: warn,
  # do not fail. Crucially it must NOT silently fall back to another board's file.
  local empty="$BATS_TEST_TMPDIR/baselines-empty"
  mkdir -p "$empty"
  cp "$V2/ci/size-baseline.rock-5b-plus.json" "$empty/size-baseline.json"
  run_baseline_compare x86-minipc "$tree" "$empty"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no committed size baseline"* ]]

  # A per-board file whose own board field disagrees is a misconfiguration, not a
  # size event, so it must abort rather than report a delta.
  local bad="$BATS_TEST_TMPDIR/baselines-bad"
  mkdir -p "$bad"
  cp "$V2/ci/size-baseline.rock-5b-plus.json" "$bad/size-baseline.x86-minipc.json"
  run_baseline_compare x86-minipc "$tree" "$bad"
  [ "$status" -ne 0 ]
  [[ "$output" == *"size baseline unusable"* ]]
}

@test "size-gate wiring: the gate is NOT arch-gated (x86 carries a real ceiling too)" {
  # Gating on arm64 would exempt the one board whose size has never been measured.
  # Every shipped board has a non-null ceiling, so the gate applies to all of them.
  local block
  block="$(extract_size_gate_block)"
  [ -n "$block" ]
  [[ "$block" != *'${ARCH}'* ]]
  [[ "$block" != *'arm64'* ]]

  run python3 -c "
import json, sys
d = json.load(open('$SIZE_BUDGET_JSON', encoding='utf-8'))
e = {k: v for k, v in d.items() if not k.startswith('_')}
assert 'x86-minipc' in e, 'x86-minipc has no size-budget entry'
assert isinstance(e['x86-minipc']['rootfs_bytes_max'], int), 'x86-minipc ceiling must be a real integer'
print('X86-CEILING-OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"X86-CEILING-OK"* ]]
}

@test "size-gate: no board's ceiling may be raised above 1.5 GB" {
  # Raising rootfs_bytes_max to match an overage launders it into a passing gate.
  # Both RK3588 boards were 65-76 MB over and the ceiling was never moved; that is
  # the precedent this pins. Lowering stays allowed.
  run python3 -c "
import json
d = json.load(open('$SIZE_BUDGET_JSON', encoding='utf-8'))
for name, entry in d.items():
    if name.startswith('_'):
        continue
    limit = entry['rootfs_bytes_max']
    assert limit <= 1500000000, '%s: rootfs_bytes_max %d exceeds the 1.5 GB policy ceiling' % (name, limit)
print('CEILING-POLICY-OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CEILING-POLICY-OK"* ]]
}

@test "app-layer: first-party packages can be copied from mkosi source staging" {
  run grep -F 'stage_first_party_from_source_mount' "$V2/mkosi/mkosi.images/app/mkosi.postinst.chroot"
  [ "$status" -eq 0 ]

  run grep -F 'src="${src%/}/.staging/${board}/firstparty"' "$V2/mkosi/mkosi.images/app/mkosi.postinst.chroot"
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

@test "runtime packages: gstreamer1.0-alsa is installed so alsasrc is available" {
  # Audio-capable capture pipelines construct an ALSA leg even when the source
  # selection has no configured audio. Keep this explicit because the plugin
  # is not pulled by the GStreamer base packages with --no-install-recommends.
  run grep -Ex 'gstreamer1\.0-alsa[[:space:]]*(#.*)?' "$V2/manifests/packages/shared.list"
  [ "$status" -eq 0 ]
}

@test "runtime packages: gstreamer1.0-nice is installed so nicesrc is available" {
  # WebRTC ICE pipelines require the libnice GStreamer source. Keep this explicit
  # because the plugin is not pulled by the GStreamer base packages with --no-install-recommends.
  run grep -Ex 'gstreamer1\.0-nice[[:space:]]*(#.*)?' "$V2/manifests/packages/shared.list"
  [ "$status" -eq 0 ]
}

@test "runtime packages: wireless-regdb is installed so cfg80211 loads regulatory.db" {
  # The runtime layer installs shared.list with --no-install-recommends
  # (runtime/mkosi.postinst.chroot), so wpasupplicant's `Recommends: wireless-regdb`
  # is NOT pulled transitively. Without an explicit entry the kernel cfg80211
  # subsystem fails to load /lib/firmware/regulatory.db at boot
  # ("Direct firmware load for regulatory.db failed with error -2") and
  # NetworkManager reports no usable WiFi interface (confirmed on real hardware).
  run grep -Ex 'wireless-regdb[[:space:]]*(#.*)?' "$V2/manifests/packages/shared.list"
  [ "$status" -eq 0 ]
}

@test "runtime packages: iw is installed so the regulatory domain can be applied" {
  # `wireless-tools` looks like it covers this and does NOT: it ships only the
  # legacy WEXT binaries (iwconfig/iwlist/iwgetid/iwpriv/iwspy). The nl80211 `iw`
  # binary is a SEPARATE Debian package, is nothing else's dependency in this
  # list, and is what CeraUI shells out to for `iw reg set <CC>` (apply the
  # operator's country) and `iw phy` (read the AP-usable channels back out).
  # Absent it, wireless-regdb is loaded but no country can ever be selected and
  # the hotspot is stuck on the conservative world domain.
  run grep -Ex 'iw[[:space:]]*(#.*)?' "$V2/manifests/packages/shared.list"
  [ "$status" -eq 0 ]
}

@test "runtime packages: squashfs-tools is installed so rauc can unsquashfs bundles" {
  # rauc info/install shells out to /usr/bin/unsquashfs to extract the manifest
  # (and rootfs image) from a plain-format .raucb. Without squashfs-tools on the
  # device, install fails right after signature verification with
  # "Failed to start unsquashfs: ... No such file or directory" (real Rock 5B+
  # hardware). build-time mksquashfs runs on the HOST/CI, so this runtime-only gap
  # was invisible until OTA was exercised on-device.
  run grep -Ex 'squashfs-tools[[:space:]]*(#.*)?' "$V2/manifests/packages/shared.list"
  [ "$status" -eq 0 ]
}

@test "runtime packages: e2fsprogs is installed so rauc can format ext4 slots" {
  # rauc install shells out to /sbin/mkfs.ext4 to format the target ext4 slot
  # before copying the new rootfs image during the slot-write phase, after
  # signature and manifest checks. Without e2fsprogs, real Rock 5B+ hardware
  # reported "Failed to execute child process 'mkfs.ext4' (No such file or
  # directory)"; build-time tooling never needed it, so this runtime-only gap
  # was invisible until OTA was exercised on-device.
  run grep -Ex 'e2fsprogs[[:space:]]*(#.*)?' "$V2/manifests/packages/shared.list"
  [ "$status" -eq 0 ]
}

@test "runtime packages: net-tools is installed so CeraUI's ifconfig poll works" {
  # CeraUI's backend polls /sbin/ifconfig every ~5s (apps/backend
  # network-interfaces.ts run("ifconfig", [])) to build the `netif` broadcast
  # (WiFi/Ethernet/cellular/bonded-link status). This minimal bookworm image ships
  # only modern iproute2, so without net-tools every poll tick fails ("Executable
  # not found in $PATH: \"ifconfig\"") and the Network destination renders empty
  # ("No WiFi/wired interfaces", "No SIM cards", "No active links") plus a missing
  # Ethernet entry in Bonded Links — confirmed on real Rock 5B+ hardware.
  run grep -Ex 'net-tools[[:space:]]*(#.*)?' "$V2/manifests/packages/shared.list"
  [ "$status" -eq 0 ]
}

@test "runtime packages: net-tools reaches the resolved runtime package set (rk3588 + x86)" {
  # net-tools is arch-independent (shared.list), so it must appear in the runtime
  # package set the runtime layer installs for EVERY board family — the same
  # sed|awk projection make_parity_rootfs uses to model the installed set. A
  # missing/misplaced entry (e.g. accidentally landing in a delta list only) would
  # break ifconfig on one family; this asserts the shared list carries it.
  local pkgs
  pkgs="$(sed -e 's/#.*//' "$V2/manifests/packages/shared.list" | awk 'NF{print $1}')"
  [[ "$pkgs" == *net-tools* ]]
}

@test "production image leaves debug access disabled without failing finalization" {
  run env \
    CERALIVE_DEBUG_IMAGE=0 \
    CERALIVE_DEBUG_PASSWORD_HASH='' \
    bash -c 'source "$1"; configure_debug_access' bash "$POSTINST_LIB"

  [ "$status" -eq 0 ]
}

@test "mkosi passes lab debug settings to every subimage" {
  run grep -Fx 'PassEnvironment=CERALIVE_DEBUG_IMAGE CERALIVE_DEBUG_PASSWORD_HASH CERALIVE_IMAGE_BUILD_COMMIT' "$V2/mkosi/mkosi.conf"

  [ "$status" -eq 0 ]
}

@test "mkosi PassEnvironment stays in lockstep with orchestrate.sh env_names" {
  # STRUCTURAL DRIFT GUARD (the actual bug class, not just two instances).
  #
  # orchestrate.sh:run_mkosi_build() exports+CLI-passes `env_names` to the
  # TOP-LEVEL mkosi image, but only PassEnvironment= in mkosi.conf propagates a
  # value from there into the base/platform/runtime/app SUBIMAGES, where the
  # postinst scripts that consume it actually run. A name in env_names that is
  # missing from PassEnvironment reads EMPTY in every subimage chroot — silently.
  # That drift shipped two production bugs: eth0/eth1 never renamed (dropped from
  # SRTLA's eth*/wlan* bonding globs) and an empty add-on keyring (rejects every
  # add-on signature). This test asserts env_names is a SUBSET of PassEnvironment
  # so any FUTURE name added to env_names without a matching PassEnvironment=
  # entry fails here — the lockstep the mkosi.conf comment already demands.
  local orchestrate="$LIB_DIR/orchestrate.sh"
  local mkosi_conf="$V2/mkosi/mkosi.conf"

  # Extract the multi-line `local env_names=( … )` bash array literal: every line
  # between the opener and the first line that is only a closing paren.
  local env_names
  env_names="$(awk '
    /local env_names=\(/ { grab=1; next }
    grab && /^[[:space:]]*\)/ { grab=0 }
    grab { print }
  ' "$orchestrate")"

  # Extract every whitespace-separated name from ALL PassEnvironment= lines.
  local pass_names
  pass_names="$(sed -n 's/^PassEnvironment=//p' "$mkosi_conf")"

  # Guard against a parser that silently yields nothing (which would make the
  # subset assertion vacuously pass).
  [ -n "$env_names" ]
  [ -n "$pass_names" ]

  local -A in_pass=()
  local n
  for n in $pass_names; do in_pass["$n"]=1; done

  # Names legitimately in env_names but NOT in PassEnvironment. SOURCE_DATE_EPOCH
  # is a reproducible-builds variable consumed ONLY by host-side orchestrator
  # scripts (never inside a subimage chroot — verified: zero references under
  # mkosi.images/); mkosi also handles it natively, so it needs no propagation.
  local -A env_only_ok=( [SOURCE_DATE_EPOCH]=1 )

  local missing=()
  for n in $env_names; do
    [ -n "${in_pass[$n]:-}" ] && continue
    [ -n "${env_only_ok[$n]:-}" ] && continue
    missing+=("$n")
  done

  if [ "${#missing[@]}" -ne 0 ]; then
    printf 'env_names not propagated via PassEnvironment=: %s\n' "${missing[*]}" >&2
  fi
  [ "${#missing[@]}" -eq 0 ]
}

@test "mkosi PassEnvironment forwards interface-naming + add-on keyring into subimages" {
  # Explicit regression pin for the two instances the lockstep guard above closed:
  #   * CERALIVE_INTERFACES_eth0/eth1/wlan0 → runtime install_interface_naming()
  #     emits per-role .link Path= rules; empty ⇒ ethernet keeps its kernel name
  #     (enP4p65s0) and SRTLA's eth*/wlan* glob never matches the wired uplink.
  #   * ADDON_KEYRING_B64 → runtime setup_addon_keyring() bakes the PUBLIC add-on
  #     keyring; empty ⇒ EMPTY placeholder that rejects ALL add-on signatures.
  local pass_names
  pass_names="$(sed -n 's/^PassEnvironment=//p' "$V2/mkosi/mkosi.conf")"

  local -A in_pass=()
  local n
  for n in $pass_names; do in_pass["$n"]=1; done

  local want missing=()
  for want in CERALIVE_INTERFACES_eth0 CERALIVE_INTERFACES_eth1 \
              CERALIVE_INTERFACES_wlan0 ADDON_KEYRING_B64; do
    [ -n "${in_pass[$want]:-}" ] || missing+=("$want")
  done

  if [ "${#missing[@]}" -ne 0 ]; then
    printf 'PassEnvironment= missing: %s\n' "${missing[*]}" >&2
  fi
  [ "${#missing[@]}" -eq 0 ]
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

@test "production image leaves ssh.service NOT enabled (disabled-by-default)" {
  # Todo 42: on a production image (CERALIVE_DEBUG_IMAGE=0/unset) ssh MUST NOT be
  # enabled. The base layer's openssh-server preset already enables ssh.service, so
  # configure_ssh_enablement must actively DISABLE it — never call `enable ssh`.
  local bin="$BATS_TEST_TMPDIR/ssh-enable-bin"
  local calls="$BATS_TEST_TMPDIR/ssh-enable-calls"
  mkdir -p "$bin"

  cat >"$bin/systemctl" <<'SH'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$SSH_ENABLE_CALLS"
# disable_service greps list-unit-files output for the unit before disabling; echo
# the unit so it treats it as present (the base-layer-enabled state).
case "$1" in
  list-unit-files) printf '%s enabled\n' "$2" ;;
esac
exit 0
SH
  chmod +x "$bin/systemctl"

  run env \
    PATH="$bin:$PATH" \
    SSH_ENABLE_CALLS="$calls" \
    CERALIVE_DEBUG_IMAGE=0 \
    bash -c 'source "$1"; configure_ssh_enablement' bash "$POSTINST_LIB"

  [ "$status" -eq 0 ]
  run cat "$calls"
  [ "$status" -eq 0 ]
  [[ "$output" != *"enable ssh"* ]]
  [[ "$output" == *"disable ssh.service"* ]]
}

@test "lab debug image enables ssh.service by default" {
  # Todo 42: the debug branch (CERALIVE_DEBUG_IMAGE=1) keeps the historical
  # enabled-by-default behavior — `enable ssh`, no disable.
  local bin="$BATS_TEST_TMPDIR/ssh-enable-bin"
  local calls="$BATS_TEST_TMPDIR/ssh-enable-calls"
  mkdir -p "$bin"

  cat >"$bin/systemctl" <<'SH'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$SSH_ENABLE_CALLS"
case "$1" in
  list-unit-files) printf '%s enabled\n' "$2" ;;
esac
exit 0
SH
  chmod +x "$bin/systemctl"

  run env \
    PATH="$bin:$PATH" \
    SSH_ENABLE_CALLS="$calls" \
    CERALIVE_DEBUG_IMAGE=1 \
    bash -c 'source "$1"; configure_ssh_enablement' bash "$POSTINST_LIB"

  [ "$status" -eq 0 ]
  run cat "$calls"
  [ "$status" -eq 0 ]
  [[ "$output" == *"enable ssh"* ]]
  [[ "$output" != *"disable ssh"* ]]
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
# 18b. avahi-daemon restart hardening (defense-in-depth mDNS reliability) —
#      stock Debian's avahi-daemon.service ships NO Restart= directive, so ANY
#      signal/crash leaves mDNS (<hostname>.local) dead until reboot. Confirmed
#      live on real hardware: killed by SIGUSR2 (status=12/USR2), NRestarts=0.
#      setup_avahi_restart (postinst-lib.sh) bakes an ADDITIVE drop-in installed
#      from the committed standalone artifact under CERALIVE_RUNTIME_SRC (like the
#      TLS nginx drop-in). These drive the SHIPPED function against a temp drop-in
#      dir (AVAHI_DROPIN_DIR) — no image boot, UNIT scope.
# ===========================================================================

@test "avahi restart: an additive Restart=on-failure drop-in is baked for avahi-daemon.service" {
  local dir="$BATS_TEST_TMPDIR/avahi-daemon.service.d"
  rm -rf "$dir"
  run env CERALIVE_RUNTIME_SRC="$V2/mkosi/runtime" AVAHI_DROPIN_DIR="$dir" \
    bash -c "source '$POSTINST_LIB'; setup_avahi_restart"
  [ "$status" -eq 0 ]
  [ -f "$dir/10-ceralive-restart.conf" ]
  grep -q '^\[Service\]' "$dir/10-ceralive-restart.conf"
  grep -q '^Restart=on-failure$' "$dir/10-ceralive-restart.conf"
  grep -q '^RestartSec=2$' "$dir/10-ceralive-restart.conf"
}

@test "avahi restart: missing runtime source FAILS the build (fail-closed, no drop-in)" {
  local dir="$BATS_TEST_TMPDIR/avahi-fail.d"
  rm -rf "$dir"
  run env CERALIVE_RUNTIME_SRC="$BATS_TEST_TMPDIR/empty-src" AVAHI_DROPIN_DIR="$dir" \
    bash -c "source '$POSTINST_LIB'; setup_avahi_restart"
  [ "$status" -ne 0 ]
  [[ "$output" == *"avahi-restart source not found"* ]]
  [ ! -f "$dir/10-ceralive-restart.conf" ]
}

@test "avahi restart: image contract wires setup_avahi_restart into the runtime executor" {
  grep -q 'setup_avahi_restart' "$REPO_ROOT/v2/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"
}

# ===========================================================================
# 18c. ceralive.service -> cerastream.service boot ordering — ceralive.service's
#      initPipelines() connects to cerastream's control socket exactly once, so a
#      cerastream that starts LATE (confirmed live: ~2 min after ceralive.service)
#      permanently fails that boot's connect. setup_cerastream_ordering
#      (postinst-lib.sh) bakes an ADDITIVE After=cerastream.service drop-in from the
#      committed standalone artifact under CERALIVE_RUNTIME_SRC (like the avahi/TLS
#      drop-ins). ORDERING-ONLY: it must NEVER carry Requires= — ceralive.service has
#      to boot into its "engine unavailable" degraded state if cerastream is
#      absent/masked. These drive the SHIPPED function against a temp drop-in dir
#      (CERASTREAM_ORDERING_DROPIN_DIR) — no image boot, UNIT scope.
# ===========================================================================

@test "cerastream ordering: an additive After=cerastream.service drop-in is baked for ceralive.service" {
  local dir="$BATS_TEST_TMPDIR/ceralive.service.d"
  rm -rf "$dir"
  run env CERALIVE_RUNTIME_SRC="$V2/mkosi/runtime" CERASTREAM_ORDERING_DROPIN_DIR="$dir" \
    bash -c "source '$POSTINST_LIB'; setup_cerastream_ordering"
  [ "$status" -eq 0 ]
  [ -f "$dir/30-cerastream-ordering.conf" ]
  grep -q '^\[Unit\]' "$dir/30-cerastream-ordering.conf"
  grep -q '^After=cerastream.service$' "$dir/30-cerastream-ordering.conf"
}

@test "cerastream ordering: the drop-in is ordering-ONLY (no Requires=/Requisite=/BindsTo= hard dependency)" {
  # ceralive.service MUST still boot and serve its "engine unavailable" degraded
  # state (CeraUI helpers/boot-guard.ts::guardNonCritical) if cerastream is ever
  # genuinely absent or masked. A hard dependency (Requires=/Requisite=/BindsTo=)
  # would break that fail-soft design — this asserts the drop-in never introduces one.
  local dir="$BATS_TEST_TMPDIR/ceralive-ordering-only.d"
  rm -rf "$dir"
  run env CERALIVE_RUNTIME_SRC="$V2/mkosi/runtime" CERASTREAM_ORDERING_DROPIN_DIR="$dir" \
    bash -c "source '$POSTINST_LIB'; setup_cerastream_ordering"
  [ "$status" -eq 0 ]
  run grep -Eq '^(Requires|Requisite|BindsTo|Wants)=cerastream\.service' "$dir/30-cerastream-ordering.conf"
  [ "$status" -ne 0 ]
  # Same guard against the committed source artifact so a future edit can't smuggle
  # a hard dependency in past the runtime-src indirection.
  run grep -Eq '^(Requires|Requisite|BindsTo|Wants)=cerastream\.service' \
    "$V2/mkosi/runtime/ceralive-cerastream-ordering.dropin.conf"
  [ "$status" -ne 0 ]
}

@test "cerastream ordering: missing runtime source FAILS the build (fail-closed, no drop-in)" {
  local dir="$BATS_TEST_TMPDIR/ceralive-ordering-fail.d"
  rm -rf "$dir"
  run env CERALIVE_RUNTIME_SRC="$BATS_TEST_TMPDIR/empty-src" CERASTREAM_ORDERING_DROPIN_DIR="$dir" \
    bash -c "source '$POSTINST_LIB'; setup_cerastream_ordering"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cerastream-ordering source not found"* ]]
  [ ! -f "$dir/30-cerastream-ordering.conf" ]
}

@test "cerastream ordering: image contract wires setup_cerastream_ordering into the runtime executor" {
  grep -q 'setup_cerastream_ordering' "$REPO_ROOT/v2/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"
}

# ===========================================================================
# 18d. USB-C Type-C source role — the board's connector is a DRP (dual-role)
#      FUSB302/TCPM port, so every fresh boot reads `[dual] source sink` and the
#      Try.SRC/Try.SNK arbitration against the (also dual-role) camera decides
#      the role. When it lands on sink the SoC runs as a USB peripheral and the
#      camera's bus is absent entirely — the "camera sometimes isn't detected
#      over USB-C" complaint. setup_typec_source_role (postinst-lib.sh) installs
#      a oneshot that pins port_type to `source` before cerastream.service.
#      These drive the SHIPPED function and the SHIPPED script against temp
#      install dirs and a fake sysfs tree — no image boot, no hardware.
# ===========================================================================

# typec_fake_sysfs <dir> <port_type contents> — a minimal /sys/class/typec stand-in.
typec_fake_sysfs() {
  mkdir -p "$1/port0"
  printf '%s\n' "$2" >"$1/port0/port_type"
}

@test "typec source: the pinning script + boot unit are installed and enabled" {
  local unit_dir="$BATS_TEST_TMPDIR/typec-units"
  local sbin_dir="$BATS_TEST_TMPDIR/typec-sbin"
  local bin="$BATS_TEST_TMPDIR/typec-bin"
  local calls="$BATS_TEST_TMPDIR/typec-calls"
  mkdir -p "$bin"
  cat >"$bin/systemctl" <<'SH'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$TYPEC_CALLS"
exit 0
SH
  chmod +x "$bin/systemctl"

  run env PATH="$bin:$PATH" TYPEC_CALLS="$calls" \
    CERALIVE_RUNTIME_SRC="$V2/mkosi/runtime" \
    TYPEC_UNIT_DIR="$unit_dir" TYPEC_SBIN_DIR="$sbin_dir" \
    bash -c "source '$POSTINST_LIB'; setup_typec_source_role"
  [ "$status" -eq 0 ]
  [ -x "$sbin_dir/ceralive-typec-source" ]
  [ -f "$unit_dir/ceralive-typec-source.service" ]

  run cat "$calls"
  [ "$status" -eq 0 ]
  [[ "$output" == *"enable ceralive-typec-source.service"* ]]
}

@test "typec source: the target is port_type -> source (never sink, never dual)" {
  # `dual` is the broken default and `sink` is the failure mode it resolves to;
  # only `source` removes the arbitration. Locked against a well-meaning "fix".
  local script="$V2/mkosi/runtime/ceralive-typec-source.sh"
  grep -Fq 'WANTED_ROLE="source"' "$script"
  grep -Fq '/port_type' "$script"

  run grep -E 'WANTED_ROLE="(sink|dual)"' "$script"
  [ "$status" -ne 0 ]
  run grep -E '^[[:space:]]*printf .*(sink|dual).*>"\$\{ATTR\}"' "$script"
  [ "$status" -ne 0 ]
}

@test "typec source: the unit is ordered before cerastream.service" {
  # cerastream is what actually opens the capture device; ceralive.service is
  # ordered after cerastream, so Before= on both covers the whole camera chain.
  local unit="$V2/mkosi/runtime/ceralive-typec-source.service"
  grep -Eq '^Before=.*\bcerastream\.service\b' "$unit"
  grep -Eq '^Before=.*\bceralive\.service\b' "$unit"

  # Ordering-ONLY: a hard dependency would make a board without cerastream fail.
  run grep -Eq '^(Requires|Requisite|BindsTo|Wants)=.*cerastream' "$unit"
  [ "$status" -ne 0 ]
}

@test "typec source: a DRP port reading [dual] is pinned to source" {
  local sysfs="$BATS_TEST_TMPDIR/typec-drp"
  typec_fake_sysfs "$sysfs" '[dual] source sink'

  run env CERALIVE_TYPEC_CLASS_DIR="$sysfs" \
    bash "$V2/mkosi/runtime/ceralive-typec-source.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pinning port0 from 'dual' to 'source'"* ]]
  run cat "$sysfs/port0/port_type"
  [[ "$output" == "source" ]]
}

@test "typec source: pinning is idempotent — an already-source port is not rewritten" {
  # The kernel prints the whole menu with the ACTIVE entry bracketed, so a
  # pinned port reads `dual [source] sink`, NOT `source`. A naive literal
  # comparison would miss that and rewrite port_type on every boot.
  local sysfs="$BATS_TEST_TMPDIR/typec-idem"
  typec_fake_sysfs "$sysfs" 'dual [source] sink'

  run env CERALIVE_TYPEC_CLASS_DIR="$sysfs" \
    bash "$V2/mkosi/runtime/ceralive-typec-source.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already source"* ]]
  # Untouched: the menu string survives, proving no write happened.
  run cat "$sysfs/port0/port_type"
  [[ "$output" == "dual [source] sink" ]]
}

@test "typec source: a late/absent port_type is a bounded wait, never a hang or a failure" {
  # /sys/class/typec/port0 is created by an ASYNCHRONOUS fusb302/TCPM probe, so
  # the script must poll to a deadline — not sleep a fixed amount and hope.
  local sysfs="$BATS_TEST_TMPDIR/typec-empty"
  mkdir -p "$sysfs"

  run env CERALIVE_TYPEC_CLASS_DIR="$sysfs" CERALIVE_TYPEC_WAIT=1 \
    bash "$V2/mkosi/runtime/ceralive-typec-source.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"did not appear within 1s"* ]]

  # A board with no Type-C class at all is a clean no-op, not a boot failure.
  run env CERALIVE_TYPEC_CLASS_DIR="$BATS_TEST_TMPDIR/typec-absent" \
    bash "$V2/mkosi/runtime/ceralive-typec-source.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to pin"* ]]

  # The wait is a deadline-bounded poll, not a bare fixed settle constant.
  grep -Fq 'deadline=$((SECONDS + WAIT_SECONDS))' "$V2/mkosi/runtime/ceralive-typec-source.sh"
}

@test "typec source: a role change that does not take FAILS loudly (read-back verified)" {
  # /dev/null accepts the write and reads back empty — the same observable shape
  # as a TCPM that refuses the role change. It must not be reported as success.
  local sysfs="$BATS_TEST_TMPDIR/typec-nulled"
  mkdir -p "$sysfs/port0"
  printf '%s\n' '[dual] source sink' >"$sysfs/port0/real_port_type"
  ln -sf /dev/null "$sysfs/port0/port_type"

  run env CERALIVE_TYPEC_CLASS_DIR="$sysfs" \
    bash "$V2/mkosi/runtime/ceralive-typec-source.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"after writing 'source'"* ]]
}

@test "typec source: missing runtime source FAILS the build (fail-closed, nothing installed)" {
  local unit_dir="$BATS_TEST_TMPDIR/typec-failclosed-units"
  local sbin_dir="$BATS_TEST_TMPDIR/typec-failclosed-sbin"
  run env CERALIVE_RUNTIME_SRC="$BATS_TEST_TMPDIR/empty-src" \
    TYPEC_UNIT_DIR="$unit_dir" TYPEC_SBIN_DIR="$sbin_dir" \
    bash -c "source '$POSTINST_LIB'; setup_typec_source_role"
  [ "$status" -ne 0 ]
  [[ "$output" == *"typec-source script not found"* ]]
  [ ! -e "$unit_dir/ceralive-typec-source.service" ]
}

@test "typec source: pinning is wired into configure_services" {
  # An unreferenced setup function is dead code — the camera race would ship.
  run grep -E '^\s*setup_typec_source_role$' "$POSTINST_LIB"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# 18e. Boot dead-weight masks — six stock units that cost a shipped Rock 5B+
#      ~2 minutes of EVERY boot and left it permanently `degraded`.
#      systemd-networkd{,.socket,-wait-online} can never be satisfied (NM owns
#      every link; networkctl reports all `unmanaged`), yet wait-online burned a
#      flat 120s inside network-online.target and held ceralive.service — the
#      CeraUI web UI on :80 — unreachable for 2 minutes after power-on.
#      systemd-machine-id-commit fails forever because OUR OWN migrate-data bind
#      mount satisfies its ConditionPathIsMountPoint while the bind source is real
#      ext4. Standalone dnsmasq.service always loses port 53 to systemd-resolved.
#      chrony-wait blocks multi-user.target ~21s for NTP convergence nothing
#      orders itself after. These drive the SHIPPED function against a temp mask
#      dir (CERALIVE_MASK_UNIT_DIR) with a faithful `systemctl mask` stub — no
#      image boot, no hardware, UNIT scope.
# ===========================================================================

# mask_stub_bin <dir> — a systemctl stub that RECORDS every call and faithfully
# reproduces `systemctl mask` (symlink the unit to /dev/null) into
# $CERALIVE_MASK_UNIT_DIR, so the shipped function's own post-mask verification is
# exercised rather than bypassed.
mask_stub_bin() {
  mkdir -p "$1"
  cat >"$1/systemctl" <<'SH'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$MASK_CALLS"
if [ "${1:-}" = mask ]; then
  mkdir -p "$CERALIVE_MASK_UNIT_DIR"
  ln -sfn /dev/null "$CERALIVE_MASK_UNIT_DIR/$2"
fi
exit 0
SH
  chmod +x "$1/systemctl"
}

@test "boot unit masks: all six unusable/blocking units are masked to /dev/null" {
  local bin="$BATS_TEST_TMPDIR/mask-bin"
  local calls="$BATS_TEST_TMPDIR/mask-calls"
  local dir="$BATS_TEST_TMPDIR/mask-units"
  rm -rf "$bin" "$calls" "$dir"
  mask_stub_bin "$bin"

  run env PATH="$bin:$PATH" MASK_CALLS="$calls" CERALIVE_MASK_UNIT_DIR="$dir" \
    bash -c "source '$POSTINST_LIB'; suppress_unusable_boot_units"
  [ "$status" -eq 0 ]

  local unit
  for unit in systemd-networkd.service systemd-networkd.socket \
              systemd-networkd-wait-online.service \
              systemd-machine-id-commit.service dnsmasq.service \
              chrony-wait.service; do
    [ -L "$dir/$unit" ]
    [ "$(readlink "$dir/$unit")" = "/dev/null" ]
  done
}

@test "boot unit masks: masking systemd-networkd.service itself closes the Also= resurrection path" {
  # Debian's 90-systemd.preset says `enable systemd-networkd.service` AND
  # `disable systemd-networkd-wait-online.service` — and the disable LOSES, because
  # systemd-networkd.service's [Install] carries
  # `Also=systemd-networkd-wait-online.service`, applied unconditionally by enable.
  # Masking the parent is what makes that Also= unreachable, so both must be masked.
  grep -Fq 'Also=systemd-networkd-wait-online.service' \
    "$V2/mkosi/build/runtime/usr/lib/systemd/system/systemd-networkd.service" \
    || skip "built runtime tree not present — Also= premise checked on the real unit only"

  local bin="$BATS_TEST_TMPDIR/mask-also-bin"
  local calls="$BATS_TEST_TMPDIR/mask-also-calls"
  local dir="$BATS_TEST_TMPDIR/mask-also-units"
  rm -rf "$bin" "$calls" "$dir"
  mask_stub_bin "$bin"

  run env PATH="$bin:$PATH" MASK_CALLS="$calls" CERALIVE_MASK_UNIT_DIR="$dir" \
    bash -c "source '$POSTINST_LIB'; suppress_unusable_boot_units"
  [ "$status" -eq 0 ]
  [ -L "$dir/systemd-networkd.service" ]
  [ -L "$dir/systemd-networkd-wait-online.service" ]
}

@test "boot unit masks: mask, NOT disable — first-boot preset-all would undo a disable" {
  # /etc/machine-id ships as the literal string `uninitialized`, so every freshly
  # flashed board is a systemd FIRST BOOT and PID 1 runs `preset-all`, re-applying
  # the vendor presets over anything this build merely disabled. `systemctl enable`
  # refuses to act on a masked unit, so only a mask survives.
  run grep -E '^\s*mask_service "\$\{svc\}"' "$POSTINST_LIB"
  [ "$status" -eq 0 ]

  local unit
  for unit in systemd-networkd systemd-networkd-wait-online \
              systemd-machine-id-commit dnsmasq chrony-wait; do
    run grep -E "disable_service ${unit}" "$POSTINST_LIB"
    [ "$status" -ne 0 ]
  done
}

@test "boot unit masks: a mask that does not land FAILS the build (fail-closed, never silent)" {
  # A silently-ineffective mask ships the exact defect back to the fleet on an image
  # that otherwise builds, boots and passes every other gate — so the shipped
  # function VERIFIES the symlink instead of trusting the systemctl exit status.
  local bin="$BATS_TEST_TMPDIR/mask-noop-bin"
  local dir="$BATS_TEST_TMPDIR/mask-noop-units"
  rm -rf "$bin" "$dir"
  mkdir -p "$bin"
  cat >"$bin/systemctl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$bin/systemctl"

  run env PATH="$bin:$PATH" CERALIVE_MASK_UNIT_DIR="$dir" \
    bash -c "source '$POSTINST_LIB'; suppress_unusable_boot_units"
  [ "$status" -ne 0 ]
  [[ "$output" == *"mask did not land"* ]]
  [ ! -e "$dir/systemd-networkd.service" ]
}

@test "boot unit masks: NEVER widen to NetworkManager, resolved, udevd or chronyd" {
  # NM is the only network stack; systemd-resolved owns :53 and the resolv.conf stub;
  # systemd-udevd's BUILT-IN net_setup_link (not networkd) consumes the .link files
  # that produce eth0/wlan0 for SRTLA's bonding globs; chrony.service is the NTP
  # daemon itself — only its boot-blocking chrony-wait sibling may be masked.
  local bin="$BATS_TEST_TMPDIR/mask-scope-bin"
  local calls="$BATS_TEST_TMPDIR/mask-scope-calls"
  local dir="$BATS_TEST_TMPDIR/mask-scope-units"
  rm -rf "$bin" "$calls" "$dir"
  mask_stub_bin "$bin"

  run env PATH="$bin:$PATH" MASK_CALLS="$calls" CERALIVE_MASK_UNIT_DIR="$dir" \
    bash -c "source '$POSTINST_LIB'; suppress_unusable_boot_units"
  [ "$status" -eq 0 ]

  run grep -cE '^systemctl mask ' "$calls"
  [ "$output" -eq 6 ]

  run grep -E '^systemctl mask (NetworkManager|systemd-resolved|systemd-udevd|systemd-networkd-generator|chrony)\.(service|socket)$' "$calls"
  [ "$status" -ne 0 ]

  # The positive half: the units above are still ENABLED and the .link writer intact.
  run grep -E '^\s*for svc in systemd-resolved NetworkManager ModemManager chrony avahi-daemon' "$POSTINST_LIB"
  [ "$status" -eq 0 ]
  run grep -F '/etc/systemd/network/10-ceralive-${role}.link' "$POSTINST_LIB"
  [ "$status" -eq 0 ]
}

@test "boot unit masks: suppression is wired into configure_services" {
  # An unreferenced setup function is dead code — the 2-minute stall would ship.
  run grep -E '^\s*suppress_unusable_boot_units$' "$POSTINST_LIB"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# 18f. Fan curve — the RK3588 package thermal zone ships `active` trips at 55 C
#      and 65 C plus `critical` at 115 C, so the pwm-fan stays silent through
#      idle (measured 46-52 C at rest on a Rock 5B+) and then snaps on audibly.
#      setup_fan_curve (postinst-lib.sh) installs a oneshot that LOWERS exactly
#      one value: the temperature of the FIRST `active` trip in the zone bound to
#      the pwm-fan cooling device. The kernel step_wise governor (live-proven to
#      auto-step cur_state 0 -> 1 at a real trip crossing and revert cleanly)
#      keeps doing all the actual fan control.
#
#      The fixture below deliberately numbers everything DIFFERENTLY from the
#      reference board — pwm-fan is cooling_device7 (not 4), the zone is
#      thermal_zone3 (not 0), it is the zone's cdev1 (not cdev0), and the first
#      `active` trip is index 1 behind a `critical` at index 0. A hardcoded index
#      anywhere in the discovery therefore fails these tests. No image boot, no
#      hardware, UNIT scope.
# ===========================================================================

FAN_SCRIPT() { printf '%s' "$V2/mkosi/runtime/ceralive-fan-curve.sh"; }
FAN_UNIT() { printf '%s' "$V2/mkosi/runtime/ceralive-fan-curve.service"; }
# NOTE for the static guards below: the script HEADER deliberately names the
# reference indices it refuses to hardcode, so every "no hardcoded index" check
# strips comment lines first and inspects executable lines only.

# fan_fake_thermal <dir> — a synthetic /sys/class/thermal with a decoy CPUFreq
# cooling device, a decoy zone that must never be touched, and the real pwm-fan
# zone at non-reference indices.
fan_fake_thermal() {
  local root="$1"
  rm -rf "$root"

  mkdir -p "$root/cooling_device2" "$root/cooling_device7"
  printf 'thermal-cpufreq-0\n' >"$root/cooling_device2/type"
  printf 'pwm-fan\n' >"$root/cooling_device7/type"
  printf '0\n' >"$root/cooling_device7/cur_state"
  printf '6\n' >"$root/cooling_device7/max_state"

  # Decoy zone: bound only to the CPUFreq cooling device. Its `active` trip is a
  # tripwire — anything that writes it has stopped keying on pwm-fan.
  mkdir -p "$root/thermal_zone0"
  printf 'soc-thermal\n' >"$root/thermal_zone0/type"
  printf 'enabled\n' >"$root/thermal_zone0/mode"
  ln -s ../cooling_device2 "$root/thermal_zone0/cdev0"
  printf '0\n' >"$root/thermal_zone0/cdev0_trip_point"
  printf 'active\n' >"$root/thermal_zone0/trip_point_0_type"
  printf '70000\n' >"$root/thermal_zone0/trip_point_0_temp"
  printf 'critical\n' >"$root/thermal_zone0/trip_point_1_type"
  printf '115000\n' >"$root/thermal_zone0/trip_point_1_temp"

  # The real subject: pwm-fan hangs off cdev1, behind a CPUFreq cdev0, and the
  # first `active` trip sits at index 1 behind a `critical` at index 0.
  mkdir -p "$root/thermal_zone3"
  printf 'package-thermal\n' >"$root/thermal_zone3/type"
  printf 'enabled\n' >"$root/thermal_zone3/mode"
  printf 'step_wise\n' >"$root/thermal_zone3/policy"
  ln -s ../cooling_device2 "$root/thermal_zone3/cdev0"
  printf '1\n' >"$root/thermal_zone3/cdev0_trip_point"
  printf '1\n' >"$root/thermal_zone3/cdev0_weight"
  ln -s ../cooling_device7 "$root/thermal_zone3/cdev1"
  printf '1\n' >"$root/thermal_zone3/cdev1_trip_point"
  printf '1\n' >"$root/thermal_zone3/cdev1_weight"
  printf 'critical\n' >"$root/thermal_zone3/trip_point_0_type"
  printf '115000\n' >"$root/thermal_zone3/trip_point_0_temp"
  printf 'active\n' >"$root/thermal_zone3/trip_point_1_type"
  printf '55000\n' >"$root/thermal_zone3/trip_point_1_temp"
  printf 'active\n' >"$root/thermal_zone3/trip_point_2_type"
  printf '65000\n' >"$root/thermal_zone3/trip_point_2_temp"
}

fan_attr() { tr -d '[:space:]' <"$1"; }

@test "fan curve: the lowering script + boot unit are installed and enabled" {
  local unit_dir="$BATS_TEST_TMPDIR/fan-units"
  local sbin_dir="$BATS_TEST_TMPDIR/fan-sbin"
  local bin="$BATS_TEST_TMPDIR/fan-bin"
  local calls="$BATS_TEST_TMPDIR/fan-calls"
  mkdir -p "$bin"
  cat >"$bin/systemctl" <<'SH'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$FAN_CALLS"
exit 0
SH
  chmod +x "$bin/systemctl"

  run env PATH="$bin:$PATH" FAN_CALLS="$calls" \
    CERALIVE_RUNTIME_SRC="$V2/mkosi/runtime" \
    FAN_CURVE_UNIT_DIR="$unit_dir" FAN_CURVE_SBIN_DIR="$sbin_dir" \
    bash -c "source '$POSTINST_LIB'; setup_fan_curve"
  [ "$status" -eq 0 ]
  [ -x "$sbin_dir/ceralive-fan-curve" ]
  [ -f "$unit_dir/ceralive-fan-curve.service" ]

  run cat "$calls"
  [ "$status" -eq 0 ]
  [[ "$output" == *"enable ceralive-fan-curve.service"* ]]
}

@test "fan curve: discovery is generic — pwm-fan is found at ANY cooling_device/zone/cdev/trip index" {
  # Reference hardware is cooling_device4 in thermal_zone0; this fixture is
  # cooling_device7 in thermal_zone3 at cdev1 with the first active trip at
  # index 1. Any hardcoded index fails here.
  local sysfs="$BATS_TEST_TMPDIR/fan-generic"
  fan_fake_thermal "$sysfs"

  run env CERALIVE_FAN_THERMAL_DIR="$sysfs" bash "$(FAN_SCRIPT)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cooling_device7"* ]]
  [[ "$output" == *"thermal_zone3"* ]]
  [ "$(fan_attr "$sysfs/thermal_zone3/trip_point_1_temp")" = "45000" ]

  # And no executable line in the shipped script may name a concrete index.
  run bash -c "grep -vE '^[[:space:]]*#' '$(FAN_SCRIPT)' | grep -E 'thermal_zone[0-9]|cooling_device[0-9]'"
  [ "$status" -ne 0 ]
}

@test "fan curve: ONLY the first active trip moves — critical and every other trip are untouched" {
  # This is the core safety property. `critical` at 115 C is the board's last
  # line of defence; the second `active` trip and the decoy zone's own active
  # trip are equally out of scope.
  local sysfs="$BATS_TEST_TMPDIR/fan-scope"
  fan_fake_thermal "$sysfs"

  run env CERALIVE_FAN_THERMAL_DIR="$sysfs" bash "$(FAN_SCRIPT)"
  [ "$status" -eq 0 ]

  [ "$(fan_attr "$sysfs/thermal_zone3/trip_point_0_temp")" = "115000" ]
  [ "$(fan_attr "$sysfs/thermal_zone3/trip_point_2_temp")" = "65000" ]
  [ "$(fan_attr "$sysfs/thermal_zone0/trip_point_0_temp")" = "70000" ]
  [ "$(fan_attr "$sysfs/thermal_zone0/trip_point_1_temp")" = "115000" ]

  # Nothing else in the tree may have been written either.
  [ "$(fan_attr "$sysfs/thermal_zone3/mode")" = "enabled" ]
  [ "$(fan_attr "$sysfs/thermal_zone0/mode")" = "enabled" ]
  [ "$(fan_attr "$sysfs/cooling_device7/cur_state")" = "0" ]
}

@test "fan curve: the script never writes mode/cur_state/pwm and runs no polling loop" {
  # Disabling a zone would ALSO disable its critical trip; driving cur_state or
  # the hwmon pwm node means owning the fan forever. The kernel governor already
  # works — this unit only moves the threshold it acts on.
  local script unit
  script="$(FAN_SCRIPT)"
  unit="$(FAN_UNIT)"

  # No executable line may even MENTION the attributes that would take ownership
  # of the fan or switch the zone off (and with it the 115 C critical trip).
  run bash -c "grep -vE '^[[:space:]]*#' '$script' | grep -E '(cur_state|emul_temp|/mode|pwm1)'"
  [ "$status" -ne 0 ]

  # A oneshot that exits, never a resident monitor or a timer.
  grep -Eq '^Type=oneshot$' "$unit"
  run grep -E '^(Type=(simple|notify|exec)|Restart=(always|on-failure))' "$unit"
  [ "$status" -ne 0 ]
  run grep -E '^(OnCalendar|OnUnitActiveSec)=' "$unit"
  [ "$status" -ne 0 ]

  # Exactly ONE sysfs write exists in the whole script, and it is the trip temp.
  run bash -c "grep -vE '^[[:space:]]*#' '$script' | grep -cE '>\"\\\$\{temp_attr\}\"'"
  [ "$output" -eq 1 ]
  run bash -c "grep -vE '^[[:space:]]*#' '$script' | grep -cE '^[^#]*>[[:space:]]*\"?\\\$\{(THERMAL_DIR|zone|temp_attr)'"
  [ "$output" -eq 1 ]
}

@test "fan curve: a board with no pwm-fan cooling device is an informational no-op, not a failure" {
  # x86-minipc has a populated /sys/class/thermal (ACPI) and no pwm-fan at all.
  local sysfs="$BATS_TEST_TMPDIR/fan-nofan"
  rm -rf "$sysfs"
  mkdir -p "$sysfs/cooling_device0" "$sysfs/thermal_zone0"
  printf 'Processor\n' >"$sysfs/cooling_device0/type"
  printf 'acpitz\n' >"$sysfs/thermal_zone0/type"
  ln -s ../cooling_device0 "$sysfs/thermal_zone0/cdev0"
  printf 'active\n' >"$sysfs/thermal_zone0/trip_point_0_type"
  printf '80000\n' >"$sysfs/thermal_zone0/trip_point_0_temp"

  run env CERALIVE_FAN_THERMAL_DIR="$sysfs" CERALIVE_FAN_WAIT=1 bash "$(FAN_SCRIPT)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no fan to re-curve"* ]]
  [ "$(fan_attr "$sysfs/thermal_zone0/trip_point_0_temp")" = "80000" ]

  # A board with no thermal class at all is equally a clean no-op.
  run env CERALIVE_FAN_THERMAL_DIR="$BATS_TEST_TMPDIR/fan-absent" bash "$(FAN_SCRIPT)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no thermal class"* ]]

  # The wait is a deadline-bounded poll, not a bare fixed settle constant.
  grep -Fq 'deadline=$((SECONDS + WAIT_SECONDS))' "$(FAN_SCRIPT)"
}

@test "fan curve: a pwm-fan zone with no active trip is skipped, never failed or force-written" {
  local sysfs="$BATS_TEST_TMPDIR/fan-noactive"
  fan_fake_thermal "$sysfs"
  printf 'passive\n' >"$sysfs/thermal_zone3/trip_point_1_type"
  printf 'passive\n' >"$sysfs/thermal_zone3/trip_point_2_type"

  run env CERALIVE_FAN_THERMAL_DIR="$sysfs" bash "$(FAN_SCRIPT)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"declares no 'active' trip"* ]]
  [ "$(fan_attr "$sysfs/thermal_zone3/trip_point_0_temp")" = "115000" ]
  [ "$(fan_attr "$sysfs/thermal_zone3/trip_point_1_temp")" = "55000" ]
  [ "$(fan_attr "$sysfs/thermal_zone3/trip_point_2_temp")" = "65000" ]
}

@test "fan curve: lowering is idempotent and can only ever LOWER, never raise" {
  local sysfs="$BATS_TEST_TMPDIR/fan-idem"
  fan_fake_thermal "$sysfs"

  run env CERALIVE_FAN_THERMAL_DIR="$sysfs" bash "$(FAN_SCRIPT)"
  [ "$status" -eq 0 ]
  [ "$(fan_attr "$sysfs/thermal_zone3/trip_point_1_temp")" = "45000" ]

  # Second run: no error, no rewrite, and it says so.
  run env CERALIVE_FAN_THERMAL_DIR="$sysfs" bash "$(FAN_SCRIPT)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"at or below"* ]]
  [ "$(fan_attr "$sysfs/thermal_zone3/trip_point_1_temp")" = "45000" ]

  # An operator (or a future DT) that already set a COOLER trip keeps it.
  printf '38000\n' >"$sysfs/thermal_zone3/trip_point_1_temp"
  run env CERALIVE_FAN_THERMAL_DIR="$sysfs" bash "$(FAN_SCRIPT)"
  [ "$status" -eq 0 ]
  [ "$(fan_attr "$sysfs/thermal_zone3/trip_point_1_temp")" = "38000" ]
}

@test "fan curve: the threshold is one named constant, defaulting to 45000 m°C and band-clamped" {
  # 45 C sits just under the 46-52 C idle band measured on a Rock 5B+, so the fan
  # idles gently instead of waiting for the stock 55 C. It is a named constant
  # precisely so it can be retuned without touching the discovery logic.
  grep -Eq '^FAN_TRIP_MILLICELSIUS="\$\{CERALIVE_FAN_TRIP_MILLIC:-45000\}"$' "$(FAN_SCRIPT)"

  local sysfs="$BATS_TEST_TMPDIR/fan-tunable"
  fan_fake_thermal "$sysfs"
  run env CERALIVE_FAN_THERMAL_DIR="$sysfs" CERALIVE_FAN_TRIP_MILLIC=50000 bash "$(FAN_SCRIPT)"
  [ "$status" -eq 0 ]
  [ "$(fan_attr "$sysfs/thermal_zone3/trip_point_1_temp")" = "50000" ]

  # A value anywhere near the 115 C critical trip would defeat the whole point.
  fan_fake_thermal "$sysfs"
  run env CERALIVE_FAN_THERMAL_DIR="$sysfs" CERALIVE_FAN_TRIP_MILLIC=110000 bash "$(FAN_SCRIPT)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"outside the accepted"* ]]
  [ "$(fan_attr "$sysfs/thermal_zone3/trip_point_1_temp")" = "55000" ]

  run env CERALIVE_FAN_THERMAL_DIR="$sysfs" CERALIVE_FAN_TRIP_MILLIC=forty bash "$(FAN_SCRIPT)"
  [ "$status" -ne 0 ]
}

@test "fan curve: a write the kernel ACCEPTS but ignores FAILS loudly (read-back verified)" {
  # The observable shape of a thermal core that takes the write and then clamps
  # or discards it: a `cat` double keeps answering the stale value, so the write
  # succeeds and the read-back disagrees. Silently reporting that as success is
  # exactly how a fan fix ships without ever having changed anything.
  local sysfs="$BATS_TEST_TMPDIR/fan-stale"
  local bin="$BATS_TEST_TMPDIR/fan-stale-bin"
  fan_fake_thermal "$sysfs"
  mkdir -p "$bin"
  cat >"$bin/cat" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    */trip_point_1_temp) printf '55000\n'; exit 0 ;;
  esac
done
exec "$(PATH=/usr/bin:/bin command -v cat)" "$@"
SH
  chmod +x "$bin/cat"

  run env PATH="$bin:$PATH" CERALIVE_FAN_THERMAL_DIR="$sysfs" bash "$(FAN_SCRIPT)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"after accepting a write"* ]]
}

@test "fan curve: an unwritable or nonsensical trip WARNs and exits 0 (RO is a legal ABI configuration)" {
  # `trip_point_Y_temp` is documented "RO, Optional" in
  # Documentation/ABI/testing/sysfs-class-thermal, so a zone whose driver offers
  # no setter is a LEGAL configuration — the board keeps its stock curve and
  # nothing is broken. That must never become a failed unit on every boot.
  local sysfs="$BATS_TEST_TMPDIR/fan-nonnumeric"
  fan_fake_thermal "$sysfs"
  ln -sf /dev/null "$sysfs/thermal_zone3/trip_point_1_temp"

  run env CERALIVE_FAN_THERMAL_DIR="$sysfs" bash "$(FAN_SCRIPT)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not a temperature"* ]]
  [ "$(fan_attr "$sysfs/thermal_zone3/trip_point_0_temp")" = "115000" ]

  if [ "$(id -u)" -ne 0 ]; then
    local ro="$BATS_TEST_TMPDIR/fan-readonly"
    fan_fake_thermal "$ro"
    chmod 0444 "$ro/thermal_zone3/trip_point_1_temp"
    run env CERALIVE_FAN_THERMAL_DIR="$ro" bash "$(FAN_SCRIPT)"
    [ "$status" -eq 0 ]
    [[ "$output" == *"refused the write"* ]]
    [ "$(fan_attr "$ro/thermal_zone3/trip_point_1_temp")" = "55000" ]
  fi
}

@test "fan curve: missing runtime source FAILS the build (fail-closed, nothing installed)" {
  local unit_dir="$BATS_TEST_TMPDIR/fan-failclosed-units"
  local sbin_dir="$BATS_TEST_TMPDIR/fan-failclosed-sbin"
  run env CERALIVE_RUNTIME_SRC="$BATS_TEST_TMPDIR/empty-src" \
    FAN_CURVE_UNIT_DIR="$unit_dir" FAN_CURVE_SBIN_DIR="$sbin_dir" \
    bash -c "source '$POSTINST_LIB'; setup_fan_curve"
  [ "$status" -ne 0 ]
  [[ "$output" == *"fan-curve script not found"* ]]
  [ ! -e "$unit_dir/ceralive-fan-curve.service" ]
}

@test "fan curve: the fix is wired into configure_services and registered in the drift gate" {
  # An unreferenced setup function is dead code — the silent-until-55C fan ships.
  run grep -E '^\s*setup_fan_curve$' "$POSTINST_LIB"
  [ "$status" -eq 0 ]
  # Standalone-artifact idiom: defined once in postinst-lib.sh, never inlined.
  grep -Fq 'setup_fan_curve' "$V2/ci/postinst-drift-check.sh"
  run grep -cE '^setup_fan_curve\(\) \{' "$POSTINST_LIB"
  [ "$output" -eq 1 ]
}

# ===========================================================================
# 18g. Status LEDs — the board's indicator LEDs are registered by the kernel and
#      then left completely unconfigured (`trigger = [none]`, `brightness = 0`),
#      so a headless appliance gives its operator no visual feedback at all.
#      setup_led_status (postinst-lib.sh) installs a oneshot that assigns the
#      FIRST discovered indicator LED the `heartbeat` trigger and the SECOND the
#      `mmc1` trigger, and writes nothing else — never `brightness`, which would
#      fight the trigger it just installed.
#
#      The reference board (Orange Pi 5 Plus) names its LEDs `blue:indicator-1`
#      (gpio-leds), `green:indicator-2` (pwm-leds) and `mmc0::` (the MMC host's
#      own, already-working activity LED). The fixture below deliberately uses
#      DIFFERENT names — `amber:status-a`, `white:status-b`, `mmc2::` and a
#      `red:power` decoy — so any hardcoded LED name, and any `mmc0`-literal
#      exclusion, fails these tests. Note the fixture's sort order is also not
#      the discovery order of the names it stands in for. No image boot, no
#      hardware, UNIT scope.
# ===========================================================================

LED_SCRIPT() { printf '%s' "$V2/mkosi/runtime/ceralive-led-status.sh"; }
LED_UNIT() { printf '%s' "$V2/mkosi/runtime/ceralive-led-status.service"; }
# NOTE for the static guards below: the script HEADER deliberately names the
# reference board's LEDs to explain what it refuses to hardcode, so every
# "no hardcoded name" check strips comment lines first and inspects executable
# lines only.

# led_fake_class <dir> — a synthetic /sys/class/leds carrying two free indicator
# LEDs under names the reference board does not use, the kernel's own MMC
# activity LED at a non-reference index, and a power-rail decoy.
led_fake_class() {
  local root="$1" d
  rm -rf "$root"

  for d in "amber:status-a" "white:status-b"; do
    mkdir -p "$root/$d"
    printf '[none] rfkill-any kbd-scrolllock heartbeat mmc0 mmc1 usbport\n' >"$root/$d/trigger"
    printf '0\n' >"$root/$d/brightness"
    printf '255\n' >"$root/$d/max_brightness"
  done

  # The kernel's OWN SD/eMMC activity LED. Already driven, not ours, and the
  # index is 2 rather than the reference board's 0 on purpose.
  mkdir -p "$root/mmc2::"
  printf 'none rfkill-any heartbeat [mmc2] mmc1\n' >"$root/mmc2::/trigger"
  printf '0\n' >"$root/mmc2::/brightness"

  # A power-rail indicator: unclaimed, but repurposing it would destroy
  # information rather than add it.
  mkdir -p "$root/red:power"
  printf '[none] rfkill-any heartbeat mmc0 mmc1\n' >"$root/red:power/trigger"
  printf '1\n' >"$root/red:power/brightness"
}

led_attr() { tr -d '[:space:]' <"$1"; }

@test "led status: the trigger script + boot unit are installed and enabled" {
  local unit_dir="$BATS_TEST_TMPDIR/led-units"
  local sbin_dir="$BATS_TEST_TMPDIR/led-sbin"
  local bin="$BATS_TEST_TMPDIR/led-bin"
  local calls="$BATS_TEST_TMPDIR/led-calls"
  mkdir -p "$bin"
  cat >"$bin/systemctl" <<'SH'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$LED_CALLS"
exit 0
SH
  chmod +x "$bin/systemctl"

  run env PATH="$bin:$PATH" LED_CALLS="$calls" \
    CERALIVE_RUNTIME_SRC="$V2/mkosi/runtime" \
    LED_STATUS_UNIT_DIR="$unit_dir" LED_STATUS_SBIN_DIR="$sbin_dir" \
    bash -c "source '$POSTINST_LIB'; setup_led_status"
  [ "$status" -eq 0 ]
  [ -x "$sbin_dir/ceralive-led-status" ]
  [ -f "$unit_dir/ceralive-led-status.service" ]

  run cat "$calls"
  [ "$status" -eq 0 ]
  [[ "$output" == *"enable ceralive-led-status.service"* ]]
}

@test "led status: discovery is generic — indicator LEDs are found under ANY name" {
  # The reference board is blue:indicator-1 / green:indicator-2; this fixture is
  # amber:status-a / white:status-b. Any hardcoded name fails here.
  local sysfs="$BATS_TEST_TMPDIR/led-generic"
  led_fake_class "$sysfs"

  run env CERALIVE_LED_CLASS_DIR="$sysfs" bash "$(LED_SCRIPT)"
  [ "$status" -eq 0 ]
  [ "$(led_attr "$sysfs/amber:status-a/trigger")" = "heartbeat" ]
  [ "$(led_attr "$sysfs/white:status-b/trigger")" = "mmc1" ]

  # And no executable line in the shipped script may name a concrete LED, a
  # concrete LED index, or the reference board's vendor DTS labels.
  run bash -c "grep -vE '^[[:space:]]*#' '$(LED_SCRIPT)' | grep -E 'indicator-[0-9]|blue:|green:|mmc0|led[0-9]'"
  [ "$status" -ne 0 ]
}

@test "led status: the kernel's own mmc* LED and a power indicator are never touched" {
  # mmc0::/mmc1:: are the MMC core's activity LEDs — already working, kernel
  # managed, and not indicator LEDs. A power-rail LED must keep meaning "powered".
  local sysfs="$BATS_TEST_TMPDIR/led-reserved"
  led_fake_class "$sysfs"

  run env CERALIVE_LED_CLASS_DIR="$sysfs" bash "$(LED_SCRIPT)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mmc2::"* ]]
  [[ "$output" == *"red:power"* ]]

  [ "$(led_attr "$sysfs/mmc2::/trigger")" = "nonerfkill-anyheartbeat[mmc2]mmc1" ]
  [ "$(led_attr "$sysfs/red:power/trigger")" = "[none]rfkill-anyheartbeatmmc0mmc1" ]
  [ "$(led_attr "$sysfs/mmc2::/brightness")" = "0" ]
  [ "$(led_attr "$sysfs/red:power/brightness")" = "1" ]
}

@test "led status: brightness is NEVER written and the unit runs no polling loop" {
  # Assigning a trigger hands the LED to the kernel; writing brightness
  # afterwards fights the very trigger just installed — the same
  # "kernel does 100% of the driving" rule ceralive-fan-curve follows.
  local script unit sysfs
  script="$(LED_SCRIPT)"
  unit="$(LED_UNIT)"
  sysfs="$BATS_TEST_TMPDIR/led-nobrightness"
  led_fake_class "$sysfs"

  run env CERALIVE_LED_CLASS_DIR="$sysfs" bash "$script"
  [ "$status" -eq 0 ]
  [ "$(led_attr "$sysfs/amber:status-a/brightness")" = "0" ]
  [ "$(led_attr "$sysfs/white:status-b/brightness")" = "0" ]

  # The script never even constructs a brightness path.
  run grep -F '/brightness' "$script"
  [ "$status" -ne 0 ]

  # Exactly ONE sysfs write exists in the whole script, and it is the trigger.
  run bash -c "grep -vE '^[[:space:]]*#' '$script' | grep -cE '>\"\\\$\{trigger_attr\}\"'"
  [ "$output" -eq 1 ]
  run bash -c "grep -vE '^[[:space:]]*#' '$script' | grep -cE '^[^#]*>[[:space:]]*\"?\\\$\{(LED_CLASS_DIR|led|trigger_attr)'"
  [ "$output" -eq 1 ]

  # A oneshot that exits, never a resident monitor or a timer.
  grep -Eq '^Type=oneshot$' "$unit"
  run grep -E '^(Type=(simple|notify|exec)|Restart=(always|on-failure))' "$unit"
  [ "$status" -ne 0 ]
  run grep -E '^(OnCalendar|OnUnitActiveSec)=' "$unit"
  [ "$status" -ne 0 ]
  # Nothing consumes an LED trigger, so this must not sit on any unit's
  # critical path — a board with no LEDs would pay the bounded wait for nothing.
  run grep -E '^Before=' "$unit"
  [ "$status" -ne 0 ]
}

@test "led status: zero, one and more-than-two LED boards are all informational no-ops" {
  local script sysfs
  script="$(LED_SCRIPT)"

  # No LED class at all (a board or kernel without CONFIG_LEDS_CLASS).
  run env CERALIVE_LED_CLASS_DIR="$BATS_TEST_TMPDIR/led-absent" bash "$script"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no LED class"* ]]

  # An empty LED class.
  sysfs="$BATS_TEST_TMPDIR/led-empty"
  rm -rf "$sysfs"; mkdir -p "$sysfs"
  run env CERALIVE_LED_CLASS_DIR="$sysfs" CERALIVE_LED_WAIT=1 bash "$script"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no LEDs under"* ]]

  # Only kernel-managed/reserved LEDs — nothing free to configure.
  sysfs="$BATS_TEST_TMPDIR/led-onlymmc"
  rm -rf "$sysfs"; mkdir -p "$sysfs/mmc1::"
  printf 'none [mmc1] heartbeat\n' >"$sysfs/mmc1::/trigger"
  run env CERALIVE_LED_CLASS_DIR="$sysfs" CERALIVE_LED_WAIT=1 bash "$script"
  [ "$status" -eq 0 ]
  [[ "$output" == *"kernel-managed or reserved"* ]]
  [ "$(led_attr "$sysfs/mmc1::/trigger")" = "none[mmc1]heartbeat" ]

  # Exactly one free LED: it gets the heartbeat and the policy simply runs out.
  sysfs="$BATS_TEST_TMPDIR/led-one"
  rm -rf "$sysfs"; mkdir -p "$sysfs/violet:lonely"
  printf '[none] heartbeat mmc1\n' >"$sysfs/violet:lonely/trigger"
  run env CERALIVE_LED_CLASS_DIR="$sysfs" bash "$script"
  [ "$status" -eq 0 ]
  [ "$(led_attr "$sysfs/violet:lonely/trigger")" = "heartbeat" ]

  # Three free LEDs: the first two are assigned, the surplus is logged and left
  # exactly as the kernel set it.
  sysfs="$BATS_TEST_TMPDIR/led-three"
  led_fake_class "$sysfs"
  mkdir -p "$sysfs/zzz:spare"
  printf '[none] heartbeat mmc1\n' >"$sysfs/zzz:spare/trigger"
  run env CERALIVE_LED_CLASS_DIR="$sysfs" bash "$script"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no trigger left in the policy"* ]]
  [ "$(led_attr "$sysfs/amber:status-a/trigger")" = "heartbeat" ]
  [ "$(led_attr "$sysfs/white:status-b/trigger")" = "mmc1" ]
  [ "$(led_attr "$sysfs/zzz:spare/trigger")" = "[none]heartbeatmmc1" ]

  # The wait is a deadline-bounded poll, not a bare fixed settle constant.
  grep -Fq 'deadline=$((SECONDS + WAIT_SECONDS))' "$script"
}

@test "led status: an LED that already has a trigger is never re-pointed (idempotent)" {
  local sysfs="$BATS_TEST_TMPDIR/led-idem"
  led_fake_class "$sysfs"

  run env CERALIVE_LED_CLASS_DIR="$sysfs" bash "$(LED_SCRIPT)"
  [ "$status" -eq 0 ]

  # Re-render the trigger files the way real sysfs does — the whole menu with
  # the active entry in brackets. A naive literal compare is never true here,
  # which is the bracket trap ceralive-typec-source documents for port_type.
  printf 'none rfkill-any [heartbeat] mmc0 mmc1\n' >"$sysfs/amber:status-a/trigger"
  printf 'none rfkill-any heartbeat mmc0 [mmc1]\n' >"$sysfs/white:status-b/trigger"

  run env CERALIVE_LED_CLASS_DIR="$sysfs" bash "$(LED_SCRIPT)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already driven by the 'heartbeat' trigger"* ]]
  [[ "$output" == *"already driven by the 'mmc1' trigger"* ]]
  [ "$(led_attr "$sysfs/amber:status-a/trigger")" = "nonerfkill-any[heartbeat]mmc0mmc1" ]

  # An operator (or a device tree default-trigger) that already claimed an LED
  # for something else keeps it.
  printf 'none [panic] heartbeat mmc1\n' >"$sysfs/amber:status-a/trigger"
  run env CERALIVE_LED_CLASS_DIR="$sysfs" bash "$(LED_SCRIPT)"
  [ "$status" -eq 0 ]
  [ "$(led_attr "$sysfs/amber:status-a/trigger")" = "none[panic]heartbeatmmc1" ]
}

@test "led status: a trigger this kernel does not offer is skipped, never forced" {
  # The trigger menu is the kernel's own answer about what it supports; writing
  # a name that is not in it just yields EINVAL and a failed unit on every boot.
  local sysfs="$BATS_TEST_TMPDIR/led-notoffered"
  led_fake_class "$sysfs"
  printf '[none] rfkill-any usbport\n' >"$sysfs/amber:status-a/trigger"
  printf '[none] rfkill-any usbport heartbeat\n' >"$sysfs/white:status-b/trigger"

  run env CERALIVE_LED_CLASS_DIR="$sysfs" bash "$(LED_SCRIPT)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"does not offer a 'heartbeat' trigger"* ]]
  [[ "$output" == *"does not offer a 'mmc1' trigger"* ]]
  [ "$(led_attr "$sysfs/amber:status-a/trigger")" = "[none]rfkill-anyusbport" ]
  [ "$(led_attr "$sysfs/white:status-b/trigger")" = "[none]rfkill-anyusbportheartbeat" ]
}

@test "led status: a write the kernel ACCEPTS but ignores FAILS loudly (read-back verified)" {
  # The observable shape of an LED core that takes the write and then discards
  # it: `cat` keeps answering the stale menu, so the write succeeds and the
  # read-back disagrees. Reporting that as success is exactly how an LED fix
  # ships without ever having lit anything.
  local sysfs="$BATS_TEST_TMPDIR/led-stale"
  local bin="$BATS_TEST_TMPDIR/led-stale-bin"
  led_fake_class "$sysfs"
  mkdir -p "$bin"
  cat >"$bin/cat" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    */amber:status-a/trigger) printf '[none] heartbeat mmc0 mmc1\n'; exit 0 ;;
  esac
done
exec "$(PATH=/usr/bin:/bin command -v cat)" "$@"
SH
  chmod +x "$bin/cat"

  run env PATH="$bin:$PATH" CERALIVE_LED_CLASS_DIR="$sysfs" bash "$(LED_SCRIPT)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"after accepting a write"* ]]
}

@test "led status: an unwritable trigger WARNs and exits 0 (a dark LED is the state it shipped in)" {
  if [ "$(id -u)" -eq 0 ]; then skip "root ignores file permissions"; fi
  local sysfs="$BATS_TEST_TMPDIR/led-readonly"
  led_fake_class "$sysfs"
  chmod 0444 "$sysfs/amber:status-a/trigger"

  run env CERALIVE_LED_CLASS_DIR="$sysfs" bash "$(LED_SCRIPT)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"refused the write"* ]]
  [ "$(led_attr "$sysfs/amber:status-a/trigger")" = "[none]rfkill-anykbd-scrolllockheartbeatmmc0mmc1usbport" ]
  # The second LED is still configured — one bad node is not a reason to stop.
  [ "$(led_attr "$sysfs/white:status-b/trigger")" = "mmc1" ]
}

@test "led status: missing runtime source FAILS the build (fail-closed, nothing installed)" {
  local unit_dir="$BATS_TEST_TMPDIR/led-failclosed-units"
  local sbin_dir="$BATS_TEST_TMPDIR/led-failclosed-sbin"
  run env CERALIVE_RUNTIME_SRC="$BATS_TEST_TMPDIR/empty-src" \
    LED_STATUS_UNIT_DIR="$unit_dir" LED_STATUS_SBIN_DIR="$sbin_dir" \
    bash -c "source '$POSTINST_LIB'; setup_led_status"
  [ "$status" -ne 0 ]
  [[ "$output" == *"led-status script not found"* ]]
  [ ! -e "$unit_dir/ceralive-led-status.service" ]
}

@test "led status: the fix is wired into configure_services and registered in the drift gate" {
  # An unreferenced setup function is dead code — the dark LEDs ship.
  run grep -E '^\s*setup_led_status$' "$POSTINST_LIB"
  [ "$status" -eq 0 ]
  # Standalone-artifact idiom: defined once in postinst-lib.sh, never inlined.
  grep -Fq 'setup_led_status' "$V2/ci/postinst-drift-check.sh"
  run grep -cE '^setup_led_status\(\) \{' "$POSTINST_LIB"
  [ "$output" -eq 1 ]
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
  local expected_ceraui_pin="v2026.7.2"
  local expected_device_version="2026.7.2-20260719T181141.a881b77"
  local device_version

  [ "$(get_pin CeraUI)" = "$expected_ceraui_pin" ]
  device_version="$(awk -F= '$1 == "ceralive-device" { print $2; exit }' \
    "$REPO_ROOT/v2/manifests/first-party-deb-versions.txt")"
  [ "$device_version" = "$expected_device_version" ]
  [[ "$device_version" == "${expected_ceraui_pin#v}-"* ]]
}

@test "fetch-debs srt pin ships libsrt1.5-ceralive bundling /usr/bin/srt-live-transmit" {
  # srt 1.5.6+ceralive.1 (upstream v1.5.6 KMREQ CVE fixes, built off master) still
  # bundles srt-live-transmit into the EXISTING libsrt1.5-ceralive .deb (PR #18 "Path A"),
  # linked against the same shared GnuTLS libsrt.so.1.5 (single-libsrt invariant) — so it
  # needs NO new FIRST_PARTY_APT_PKGS entry, only the version bump. Live + GPG-signed on
  # apt.ceralive.tv (arm64+amd64).
  local expected_srt_pin="v1.5.6+ceralive.1"
  [ "$(get_pin srt)" = "$expected_srt_pin" ]
  local libsrt_version
  libsrt_version="$(awk -F= '$1 == "libsrt1.5-ceralive" { print $2; exit }' \
    "$REPO_ROOT/v2/manifests/first-party-deb-versions.txt")"
  [ "$libsrt_version" = "${expected_srt_pin#v}" ]
  # The rootfs build/install-test asserts the bundled tool actually lands on-device.
  grep -Fq '/usr/bin/srt-live-transmit' "$V2/tests/realhw-smoke.sh"
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

# ===========================================================================
# 19b. RK3588 HW-accel userspace fetch (pinned URL + SHA-256) —
#      fetch_rk3588_userspace stages ONLY the pinned userspace packages the
#      resolved family declares (Mali blob / MPP / RGA / gst-rockchip / config),
#      and fetch_bsp EXCLUDES exactly that set from the Armbian fetch because the
#      Armbian bookworm arm64 feed does NOT carry them. DRY_RUN logs the exact
#      pinned URL + hash and stages nothing. Self-contained: temp pin files, no
#      network (DRY_RUN plan-only).
# ===========================================================================

@test "fetch-debs RK3588 userspace: DRY_RUN logs the pinned URL + sha and stages no .deb" {
  local family="$BATS_TEST_TMPDIR/family.yaml"
  local pins="$BATS_TEST_TMPDIR/userspace.txt"
  mkdir -p "$BATS_TEST_TMPDIR/debs"
  cat >"$family" <<'YAML'
armbian_branch: vendor
kernel_packages:
  - linux-image-test
dtb_packages: []
uboot_packages: []
firmware_packages:
  - libmali-test
hw_accel_gstreamer_plugins: []
gstreamer_runtime_packages: []
YAML
  cat >"$pins" <<'PINS'
libmali-test  libmali-test_1.0_arm64.deb  0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef  https://example.invalid/libmali-test_1.0_arm64.deb
PINS
  run bash -c "{ export DRY_RUN=1 ARCH=arm64 RK3588_USERSPACE_DEB_VERSIONS_FILE='$pins' KERNEL_PACKAGES=linux-image-test FIRMWARE_PACKAGES=libmali-test; source '$FETCH_DEBS'; fetch_rk3588_userspace '$family' '$BATS_TEST_TMPDIR/debs'; } 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RK3588 userspace set from"* ]]
  [[ "$output" == *"libmali-test"* ]]
  [[ "$output" == *"https://example.invalid/libmali-test_1.0_arm64.deb"* ]]
  [[ "$output" == *"DRY-RUN would run:"* ]]
  # plan-only: not one .deb was staged
  run bash -c "shopt -s nullglob; f=('$BATS_TEST_TMPDIR/debs'/*.deb); echo \${#f[@]}"
  [ "$output" -eq 0 ]
}

@test "fetch-debs RK3588 userspace: fetch_bsp EXCLUDES pinned userspace pkgs from the Armbian set" {
  local family="$BATS_TEST_TMPDIR/family.yaml"
  local bsp_pins="$BATS_TEST_TMPDIR/bsp.txt"
  local us_pins="$BATS_TEST_TMPDIR/userspace.txt"
  cat >"$family" <<'YAML'
armbian_branch: vendor
kernel_packages:
  - linux-image-test
dtb_packages: []
uboot_packages: []
firmware_packages:
  - armbian-firmware
  - libmali-test
hw_accel_gstreamer_plugins:
  - gst-rockchip-test
gstreamer_runtime_packages: []
YAML
  cat >"$bsp_pins" <<'PINS'
linux-image-test=1.0
armbian-firmware=1.0
PINS
  cat >"$us_pins" <<'PINS'
libmali-test  libmali-test_1.0_arm64.deb  0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef  https://example.invalid/libmali-test_1.0_arm64.deb
gst-rockchip-test  gst-rockchip-test_1.0_arm64.deb  fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210  https://example.invalid/gst-rockchip-test_1.0_arm64.deb
PINS
  run bash -c "{ export DRY_RUN=1 ARCH=arm64 BSP_DEB_VERSIONS_FILE='$bsp_pins' RK3588_USERSPACE_DEB_VERSIONS_FILE='$us_pins' KERNEL_PACKAGES=linux-image-test FIRMWARE_PACKAGES='armbian-firmware libmali-test' HW_ACCEL_GSTREAMER_PLUGINS=gst-rockchip-test; source '$FETCH_DEBS'; fetch_bsp '$family' '$BATS_TEST_TMPDIR/debs'; } 2>&1"
  [ "$status" -eq 0 ]
  # the pinned userspace names never enter the Armbian BSP set / apt specs
  [[ "$output" != *"libmali-test"* ]]
  [[ "$output" != *"gst-rockchip-test"* ]]
  # the real Armbian BSP packages DO
  [[ "$output" == *"BSP set from"* ]]
  [[ "$output" == *"linux-image-test"* ]]
  [[ "$output" == *"armbian-firmware"* ]]
}

@test "fetch-debs RK3588 userspace: a family declaring no pinned userspace pkg fetches nothing" {
  local family="$BATS_TEST_TMPDIR/family.yaml"
  local us_pins="$BATS_TEST_TMPDIR/userspace.txt"
  cat >"$family" <<'YAML'
armbian_branch: none
kernel_packages: []
dtb_packages: []
uboot_packages: []
firmware_packages: []
hw_accel_gstreamer_plugins: []
gstreamer_runtime_packages: []
YAML
  cat >"$us_pins" <<'PINS'
libmali-test  libmali-test_1.0_arm64.deb  0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef  https://example.invalid/libmali-test_1.0_arm64.deb
PINS
  run bash -c "{ export DRY_RUN=1 ARCH=x86-64 RK3588_USERSPACE_DEB_VERSIONS_FILE='$us_pins'; source '$FETCH_DEBS'; fetch_rk3588_userspace '$family' '$BATS_TEST_TMPDIR/debs'; } 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"declares no pinned userspace package"* ]]
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

# ===========================================================================
# 22. apt.ceralive.tv repo correctness (T2.6) — the customize module
#     apt-ceralive-repo.sh writes the device's own apt source (deb822 with a
#     Signed-By keyring), installs the GPG keyring from env-injected
#     APT_GPG_PUBLIC_B64 (the empty-keyring placeholder is a DEV-ONLY branch that
#     MUST NOT ship in a credentialed build), and pins the apt.ceralive.tv origin
#     at Pin-Priority 990 so OUR first-party updates win for the packages the
#     origin carries while the rest of the Debian archive keeps its 500 default.
#     These drive the SHIPPED functions (sourced with APT_CERALIVE_REPO_NO_AUTORUN=1
#     so the chroot auto-run is suppressed) against scratch dirs
#     (APT_SOURCES_DIR / APT_PREFERENCES_DIR / APT_KEYRING_FILE) — no chroot, no
#     image, UNIT scope. Secret VALUES are never echoed: the keyring fixture is a
#     synthetic non-secret payload whose bytes are asserted ABSENT from output.
# ===========================================================================

@test "apt ceralive (T2.6): ceralive.sources is written with a Signed-By keyring reference" {
  local dir="$BATS_TEST_TMPDIR/apt-src/sources.list.d"
  run env APT_CERALIVE_REPO_NO_AUTORUN=1 APT_SOURCES_DIR="$dir" \
    bash -c "source '$APT_CERALIVE_REPO'; configure_ceralive_source"
  [ "$status" -eq 0 ]
  [ -f "$dir/ceralive.sources" ]
  grep -q '^Signed-By: /usr/share/keyrings/ceralive-archive-keyring.gpg$' "$dir/ceralive.sources"
  grep -q '^URIs: https://apt.ceralive.tv/' "$dir/ceralive.sources"
  printf '%s\n' "$output"
}

@test "apt ceralive (T2.6): a credentialed build installs a NON-EMPTY keyring, never the empty placeholder" {
  local root="$BATS_TEST_TMPDIR/apt-keyring"
  mkdir -p "$root"
  local keyring="$root/ceralive-archive-keyring.gpg"
  local payload="SYNTHETIC-NON-SECRET-KEYRING-BYTES"
  local b64; b64="$(printf '%s' "$payload" | base64 -w0)"
  run env APT_CERALIVE_REPO_NO_AUTORUN=1 APT_KEYRING_FILE="$keyring" \
    APT_GPG_PUBLIC_B64="$b64" \
    bash -c "source '$APT_CERALIVE_REPO'; install_gpg_keyring"
  [ "$status" -eq 0 ]
  [ -s "$keyring" ]
  [[ "$output" != *"$b64"* ]]
  [[ "$output" != *"$payload"* ]]

  local placeholder="$root/placeholder.gpg"
  run env -u APT_GPG_PUBLIC_B64 APT_CERALIVE_REPO_NO_AUTORUN=1 APT_KEYRING_FILE="$placeholder" \
    bash -c "source '$APT_CERALIVE_REPO'; install_gpg_keyring"
  [ "$status" -eq 0 ]
  [ ! -s "$placeholder" ]
  [[ "$output" == *"empty placeholder"* ]]
}

@test "apt ceralive (T2.6): the apt.ceralive.tv origin is pinned at Pin-Priority 990" {
  local dir="$BATS_TEST_TMPDIR/apt-prefs/preferences.d"
  run env APT_CERALIVE_REPO_NO_AUTORUN=1 APT_PREFERENCES_DIR="$dir" \
    bash -c "source '$APT_CERALIVE_REPO'; install_apt_preferences"
  [ "$status" -eq 0 ]
  [ -f "$dir/ceralive" ]
  grep -q '^Package: \*$' "$dir/ceralive"
  grep -q '^Pin: origin apt.ceralive.tv$' "$dir/ceralive"
  grep -q '^Pin-Priority: 990$' "$dir/ceralive"
  grep -q '^  install_apt_preferences$' "$APT_CERALIVE_REPO"
  printf '%s\n' "$output"
}

# The guard ABOVE proves the customize MODULE (apt-ceralive-repo.sh) pins the origin
# — but `./v2/build` never runs that module; it runs the runtime executor
# (mkosi.postinst.chroot::setup_ceralive_repository). Todo 8's pin shipped absent
# from real images precisely because only the module was tested. This guard drives
# the REAL build-path function against a scratch chroot filesystem and asserts the
# pin is baked there.
@test "apt ceralive (T2.6): the RUNTIME EXECUTOR (the ./v2/build path) bakes the 990 origin pin" {
  run bash "$TESTS_DIR/apt-preferences-baked.test.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Part A static contract OK"* ]]
  [[ "$output" == *"regression: PASS"* ]]
  printf '%s\n' "$output"
}

# The RUNTIME EXECUTOR (./v2/build path) must ALSO hand the mTLS client.key to the
# _apt sandbox user (else apt-get update dies "Could not load client certificate"),
# dedupe to exactly ONE Debian source (else "configured multiple times" warnings),
# and write an arch-qualified apt.ceralive.tv URI (else the Release file 404s).
@test "apt ceralive (T2.6): the build path makes client.key _apt-readable and dedupes Debian sources" {
  run bash "$TESTS_DIR/apt-mtls-and-dedupe.test.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Part A static contract OK"* ]]
  [[ "$output" == *"regression: PASS"* ]]
  printf '%s\n' "$output"
}

# The build path must normalize the armored CI secret before the runtime executor
# writes it: the device carries apt/gpgv, not gpg or file(1).
@test "apt ceralive (T2.6): the build dearmors its keyring and the RUNTIME EXECUTOR consumes binary input" {
  command -v gpg >/dev/null || skip "gpg is required for the synthetic OpenPGP fixture"
  command -v file >/dev/null || skip "file is required for the keyring-magic guard"
  unshare -rm --map-root-user true 2>/dev/null || skip "rootless mount namespaces are required"

  local fixture_home="$BATS_TEST_TMPDIR/apt-keyring-gnupg"
  local armored="$BATS_TEST_TMPDIR/ceralive-archive-keyring.asc"
  local repro="$BATS_TEST_TMPDIR/runtime-keyring-repro.sh"
  local dearmor="$V2/lib/dearmor-apt-keyring.sh"
  mkdir -m 700 "$fixture_home"
  run gpg --batch --homedir "$fixture_home" --passphrase '' \
    --quick-generate-key 'CeraLive test archive <test-archive@example.invalid>' ed25519 sign 1d
  [ "$status" -eq 0 ]
  run gpg --batch --homedir "$fixture_home" --armor --export test-archive@example.invalid
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" >"$armored"

  local armored_b64 binary_b64
  armored_b64="$(base64 -w0 "$armored")"
  run env APT_GPG_PUBLIC_B64="$armored_b64" "$dearmor"
  [ "$status" -eq 0 ]
  binary_b64="$output"
  printf '%s' "$binary_b64" | base64 -d >"$BATS_TEST_TMPDIR/build-keyring.gpg"
  run file -b "$BATS_TEST_TMPDIR/build-keyring.gpg"
  [ "$status" -eq 0 ]
  [[ "$output" == OpenPGP\ Public\ Key\ Version* ]]
  local binary_magic="$output"

  run env APT_GPG_PUBLIC_B64="$binary_b64" "$dearmor"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | base64 -d >"$BATS_TEST_TMPDIR/reaccepted-binary-keyring.gpg"
  run file -b "$BATS_TEST_TMPDIR/reaccepted-binary-keyring.gpg"
  [ "$status" -eq 0 ]
  [[ "$output" == "$binary_magic" ]]

  run env APT_GPG_PUBLIC_B64='@@@@' "$dearmor"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not decode APT_GPG_PUBLIC_B64"* ]]

  local fake_bin="$BATS_TEST_TMPDIR/fake-gpg"
  mkdir -p "$fake_bin"
  cat >"$fake_bin/gpg" <<'FAKE_GPG'
#!/usr/bin/env bash
set -euo pipefail
output=''
input=''
while (( $# )); do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    *) input="$1"; shift ;;
  esac
done
cat "$input" >"$output"
FAKE_GPG
  chmod +x "$fake_bin/gpg"
  run env PATH="$fake_bin:$PATH" APT_GPG_PUBLIC_B64="$armored_b64" "$dearmor"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a binary OpenPGP public key (PGP public key block Public-Key (old))"* ]]

  cat >"$repro" <<'REPRO'
set -euo pipefail
postinst="$1"
key_b64="$2"
work="$3"
final=/usr/share/keyrings/ceralive-archive-keyring.gpg
expected="$work/expected-runtime-keyring.gpg"
old="$work/old-runtime-keyring.gpg"

extract_fn() {
  awk -v fn="$1" '
    $0 ~ "^" fn "\\(\\) \\{" { found=1 }
    found { print }
    found && /^}/ { exit }
  ' "$2"
}

mkdir -p "$work/bin"
mount -t tmpfs tmpfs /etc
mount -t tmpfs tmpfs /usr/share
mkdir -p /etc/opt/ceralive /etc/apt/certs /etc/apt/apt.conf.d /etc/apt/sources.list.d \
  /etc/apt/preferences.d /usr/share/keyrings
cat >"$work/bin/dpkg" <<'DPKG'
#!/usr/bin/env bash
printf 'amd64\n'
DPKG
chmod +x "$work/bin/dpkg"
export PATH="$work/bin:$PATH"

printf '%s' "$key_b64" | base64 -d >"$expected"
printf '\x00old-ceralive-keyring\xff\n' >"$old"

fail() {
  printf 'runtime-keyring regression: FAIL: %s\n' "$*" >&2
  exit 1
}

assert_no_temp() {
  local leaked
  leaked="$(find /usr/share/keyrings -maxdepth 1 -type f \
    -name 'ceralive-archive-keyring.gpg.??????' -print -quit)"
  [[ -z "$leaked" ]] || fail "$1 left temporary keyring $leaked"
}

seed_old() {
  cp "$old" "$final"
  old_sha="$(sha256sum "$final" | awk '{print $1}')"
}

assert_old_preserved() {
  local actual_sha
  [[ -f "$final" ]] || fail "$1 removed the pre-existing final keyring"
  actual_sha="$(sha256sum "$final" | awk '{print $1}')"
  [[ "$actual_sha" == "$old_sha" ]] \
    || fail "$1 changed the pre-existing final keyring: expected $old_sha, got $actual_sha"
  cmp -s "$old" "$final" || fail "$1 changed the pre-existing final keyring bytes"
  assert_no_temp "$1"
  printf 'runtime-keyring: %s preserved old sha256=%s and cleaned temp\n' "$1" "$actual_sha"
}

log() { printf '[runtime-test] %s\n' "$*" >&2; }
eval "$(extract_fn setup_ceralive_repository "$postinst")"
CHANNEL=stable

seed_old
APT_GPG_PUBLIC_B64='@@@@'
if setup_ceralive_repository; then
  fail "malformed base64 unexpectedly succeeded"
fi
assert_old_preserved "decode failure"

cat >"$work/bin/mktemp" <<'MKTEMP'
#!/usr/bin/env bash
exit 74
MKTEMP
chmod +x "$work/bin/mktemp"
seed_old
APT_GPG_PUBLIC_B64="$key_b64"
if setup_ceralive_repository; then
  fail "temporary preparation failure unexpectedly succeeded"
fi
assert_old_preserved "temporary preparation failure"
rm -f "$work/bin/mktemp"
hash -r

cat >"$work/bin/mv" <<'MV'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == "-f" && "$2" == "--" && "$#" -eq 4 ]]
source_path="$3"
final_path="$4"
[[ "$final_path" == /usr/share/keyrings/ceralive-archive-keyring.gpg ]]
cmp -s "$TEST_EXPECTED_KEYRING" "$source_path"
[[ "$(stat -c '%a' "$source_path")" == 644 ]]
[[ "$(stat -c '%u:%g' "$source_path")" == 0:0 ]]
printf 'prepared source bytes, mode, and owner verified\n' >"$TEST_MV_MARKER"
exit 73
MV
chmod +x "$work/bin/mv"
seed_old
export TEST_EXPECTED_KEYRING="$expected"
export TEST_MV_MARKER="$work/mv-preparation-verified"
APT_GPG_PUBLIC_B64="$key_b64"
if setup_ceralive_repository; then
  fail "final replacement failure unexpectedly succeeded"
fi
[[ -s "$TEST_MV_MARKER" ]] \
  || fail "final replacement failure was not injected after full temporary preparation"
assert_old_preserved "final replacement failure"
rm -f "$work/bin/mv"
hash -r

APT_GPG_PUBLIC_B64="$key_b64"
setup_ceralive_repository
cmp -s "$expected" "$final" || fail "successful handoff published unexpected bytes"
[[ "$(stat -c '%a' "$final")" == 644 ]] || fail "successful handoff mode is not 0644"
[[ "$(stat -c '%u:%g' "$final")" == 0:0 ]] || fail "successful handoff owner is not root:root"
assert_no_temp "successful handoff"
cp "$final" "$work/runtime-keyring.gpg"
printf 'runtime-keyring: success published expected bytes mode=0644 owner=root:root and cleaned temp\n'
REPRO

  run unshare -rm --map-root-user bash "$repro" "$V2/mkosi/mkosi.images/runtime/mkosi.postinst.chroot" \
    "$binary_b64" "$BATS_TEST_TMPDIR"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
  [[ "$output" != *"$binary_b64"* ]]
  run file -b "$BATS_TEST_TMPDIR/runtime-keyring.gpg"
  [ "$status" -eq 0 ]
  [[ "$output" == OpenPGP\ Public\ Key\ Version* ]]
  [[ "$output" == "$binary_magic" ]]

  local runtime_fn
  runtime_fn="$(awk '/^setup_ceralive_repository\(\) \{/{f=1} f{print} f && /^}/{exit}' "$V2/mkosi/mkosi.images/runtime/mkosi.postinst.chroot")"
  [[ "$runtime_fn" == *'mv -f -- "${keyring_tmp}" /usr/share/keyrings/ceralive-archive-keyring.gpg'* ]]
  [[ "$runtime_fn" != *'install -m 0644 "${keyring_tmp}" /usr/share/keyrings/ceralive-archive-keyring.gpg'* ]]
  [[ "$runtime_fn" != *"gpg --"* ]]
  [[ "$runtime_fn" != *"file -b"* ]]
  grep -q 'DEARMOR_APT_KEYRING_SH=' "$V2/lib/orchestrate.sh"
  grep -q 'APT_GPG_PUBLIC_B64="$("${DEARMOR_APT_KEYRING_SH}")"' "$V2/lib/orchestrate.sh"
  grep -q '/work/lib/dearmor-apt-keyring.sh' "$V2/lib/orchestrate.sh"
  local failing_container_helper="$BATS_TEST_TMPDIR/failing-container-dearmor"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 37' >"$failing_container_helper"
  chmod +x "$failing_container_helper"
  local container_prepare
  container_prepare="$(awk '
    /if \[\[ -n "\$\{APT_GPG_PUBLIC_B64:-\}" \]\]; then/ { found=1 }
    found { print }
    found && /^[[:space:]]*fi$/ { exit }
  ' "$V2/lib/orchestrate.sh")"
  [[ "$container_prepare" == *'/work/lib/dearmor-apt-keyring.sh'* ]]
  run env APT_GPG_PUBLIC_B64='must-fail' bash -euo pipefail -c "${container_prepare//\/work\/lib\/dearmor-apt-keyring.sh/$failing_container_helper}"$'\nprintf "mkosi_started=yes\\n"'
  [ "$status" -eq 1 ]
  [[ "$output" == *'could not prepare the binary CeraLive apt keyring for mkosi'* ]]
  [[ "$output" != *'mkosi_started=yes'* ]]
  local passing_container_helper="$BATS_TEST_TMPDIR/passing-container-dearmor"
  printf '%s\n' '#!/usr/bin/env bash' 'printf binary-keyring-b64' >"$passing_container_helper"
  chmod +x "$passing_container_helper"
  run env APT_GPG_PUBLIC_B64='normalizes' bash -euo pipefail -c "${container_prepare//\/work\/lib\/dearmor-apt-keyring.sh/$passing_container_helper}"$'\nprintf "mkosi_started=yes keyring=%s\\n" "$APT_GPG_PUBLIC_B64"'
  [ "$status" -eq 0 ]
  [[ "$output" == 'mkosi_started=yes keyring=binary-keyring-b64' ]]
  grep -Eq '^[[:space:]]+file \\' "$V2/ci/Dockerfile"
  grep -Eq '^[[:space:]]+gpg \\' "$V2/ci/Dockerfile"
  printf 'binary magic: %s\narmored fixture rejected by build guard\nruntime consumed build-validated binary keyring\n' "$binary_magic"
}

@test "image hygiene: hardware udev rules do not queue the retired optimize unit" {
  # Scope: mkosi SOURCE only. The generated siblings must be excluded, and both
  # exclusions are load-bearing on any machine that has run a real build:
  #   -r not -R — mkosi's cached base rootfs carries absolute symlinks into /dev,
  #     /proc and /run, and -R dereferences them straight out of the repo onto the
  #     host, where one blocking open() on a FIFO or tty hangs the suite forever.
  #   --exclude-dir — that same cache is root-owned and partly mode 0700, so grep
  #     exits 2 (error) instead of 1 (no match) and the assertion below fails even
  #     though nothing matched.
  # CI sees neither because it wipes v2/mkosi/{build,cache} before the job.
  run grep -rE --exclude-dir=cache --exclude-dir=build --exclude-dir=.staging \
    '^[[:space:]]*[^#[:space:]].*(ceralive-optimize@|SYSTEMD_WANTS.*optimize)' "$V2/mkosi"
  [ "$status" -eq 1 ]
}

@test "image hygiene: portable check detects a planted retired optimize unit" {
  local fixture="$BATS_TEST_TMPDIR/planted-udev.rules"
  printf '%s\n' 'ACTION=="add", ENV{SYSTEMD_WANTS}="ceralive-optimize@.service"' >"$fixture"

  run grep -E 'ceralive-optimize@|SYSTEMD_WANTS.*optimize' "$fixture"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ceralive-optimize@"* ]]
}

# ===========================================================================
# 23. ModemManager 1.24 closure image integration + fail-closed modem_ports udev.
#     The nine-package modem-stack fork (modemmanager + libmm-glib0 +
#     libmbim/libqmi/libqrtr) is staged first-party (FIRST_PARTY_APT_PKGS),
#     exact-pinned in first-party-deb-versions.txt, classified RUNTIME_APP_PKGS by
#     the app postinst, and covered by the Package:* origin-990 pin. The board
#     modem_ports block drives a FAIL-CLOSED udev generator: unverified ⇒ zero
#     generated slot-uid rules, verified fixture ⇒ rules emitted. All static /
#     sourced-function checks — UNIT scope, no image.
# ===========================================================================

MODEM_CLOSURE_PKGS="modemmanager libmm-glib0 libmbim-glib4 libmbim-proxy libmbim-utils libqmi-glib5 libqmi-proxy libqmi-utils libqrtr-glib0"

@test "modem closure: all nine packages are in FIRST_PARTY_APT_PKGS" {
  local staged pkg
  staged="$(bash -c 'source "$1"; printf "%s\n" "${FIRST_PARTY_APT_PKGS[@]}"' bash "$FETCH_DEBS")"
  for pkg in $MODEM_CLOSURE_PKGS; do
    grep -Fxq "$pkg" <<<"$staged" || { echo "missing from FIRST_PARTY_APT_PKGS: $pkg"; false; }
  done
  # The set grew by exactly nine (5 original + 9 closure = 14).
  [ "$(bash -c 'source "$1"; printf "%s" "${#FIRST_PARTY_APT_PKGS[@]}"' bash "$FETCH_DEBS")" -eq 14 ]
}

@test "modem closure: each package has an exact live-verified Version pin in the txt" {
  local pins="$V2/manifests/first-party-deb-versions.txt"
  local pkg version
  for pkg in $MODEM_CLOSURE_PKGS; do
    version="$(awk -F= -v p="$pkg" '$1==p{print $2; exit}' "$pins")"
    [ -n "$version" ] || { echo "no pin for $pkg"; false; }
    # every closure pin carries the ~ceralive0.2.0 fork suffix (published live)
    [[ "$version" == *"~ceralive0.2.0" ]] || { echo "$pkg pin lacks ~ceralive0.2.0: $version"; false; }
  done
  # spot-check the two anchor versions confirmed live on apt.ceralive.tv
  [ "$(awk -F= '$1=="modemmanager"{print $2}' "$pins")" = "1.24.2-2~ceralive0.2.0" ]
  [ "$(awk -F= '$1=="libqrtr-glib0"{print $2}' "$pins")" = "1.4.0-1~ceralive0.2.0" ]
}

@test "modem closure: the app postinst classifies all nine as RUNTIME_APP_PKGS (never sysext/appfs)" {
  local app="$V2/mkosi/mkosi.images/app/mkosi.postinst.chroot"
  local runtime_line sysext_line appfs_line pkg
  # RUNTIME_APP_PKGS spans a line continuation; collapse the assignment to one line.
  runtime_line="$(awk '/^RUNTIME_APP_PKGS=/{f=1} f{printf "%s ", $0} f&&!/\\$/{exit}' "$app")"
  sysext_line="$(grep -E '^SYSEXT_APP_PKGS=' "$app")"
  appfs_line="$(grep -E '^APPFS_APP_PKGS=' "$app")"
  for pkg in $MODEM_CLOSURE_PKGS; do
    [[ "$runtime_line" == *" $pkg"* || "$runtime_line" == *"\"$pkg"* ]] \
      || { echo "$pkg not in RUNTIME_APP_PKGS"; false; }
    [[ "$sysext_line" != *"$pkg"* ]] || { echo "$pkg leaked into SYSEXT_APP_PKGS"; false; }
    [[ "$appfs_line" != *"$pkg"* ]] || { echo "$pkg leaked into APPFS_APP_PKGS"; false; }
  done
}

@test "modem closure: mobile-broadband-provider-info is in shared.list (Recommends not auto-pulled)" {
  run grep -Ex 'mobile-broadband-provider-info[[:space:]]*(#.*)?' "$V2/manifests/packages/shared.list"
  [ "$status" -eq 0 ]
}

@test "modem closure: the Package:* origin-990 pin covers the closure (wildcard, not per-package)" {
  # The closure debs are served from the apt.ceralive.tv origin. The pin is
  # `Package: *` at Pin-Priority 990, so it covers EVERY package that origin
  # carries — including all nine — with no per-package enumeration needed.
  local dir="$BATS_TEST_TMPDIR/modem-prefs/preferences.d"
  run env APT_CERALIVE_REPO_NO_AUTORUN=1 APT_PREFERENCES_DIR="$dir" \
    bash -c "source '$APT_CERALIVE_REPO'; install_apt_preferences"
  [ "$status" -eq 0 ]
  grep -qxF 'Package: *' "$dir/ceralive"
  grep -qxF 'Pin: origin apt.ceralive.tv' "$dir/ceralive"
  grep -qxF 'Pin-Priority: 990' "$dir/ceralive"
}

@test "modem closure: DRY_RUN fetch_first_party resolves every closure package" {
  local debs="$BATS_TEST_TMPDIR/modem-debs"
  mkdir -p "$debs"
  run bash -c "{ export DRY_RUN=1 VERSIONS_YAML='$VERSIONS_YAML'; source '$FETCH_DEBS'; fetch_first_party '$debs'; } 2>&1"
  [ "$status" -eq 0 ]
  local pkg
  for pkg in $MODEM_CLOSURE_PKGS; do
    [[ "$output" == *"$pkg"* ]] || { echo "DRY_RUN plan missing $pkg"; false; }
  done
  # plan-only: nothing staged
  run bash -c "shopt -s nullglob; f=('$debs'/*.deb); echo \${#f[@]}"
  [ "$output" -eq 0 ]
}

@test "modem closure: executable app-layer install test passes (classification + install)" {
  run bash "$TESTS_DIR/app-layer-modem-closure.test.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS positive"* ]]
  [[ "$output" == *"PASS negative"* ]]
  [[ "$output" == *"regression: PASS"* ]]
  printf '%s\n' "$output"
}

@test "modem_ports schema: rock-5b-plus ships status: unverified and validates" {
  run validate_manifest "$V2/manifests/boards/rock-5b-plus.yaml" "$BOARD_SCHEMA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"VALID"* ]]
  run python3 -c "import yaml; d=yaml.safe_load(open('$V2/manifests/boards/rock-5b-plus.yaml')); print(d['modem_ports']['status'])"
  [ "$status" -eq 0 ]
  [[ "$output" == "unverified" ]]
}

@test "modem_ports schema: a verified board with slot ID_PATHs validates" {
  local brd="$BATS_TEST_TMPDIR/verified-board.yaml"
  cat > "$brd" <<'YAML'
family: rk3588
board_id: modem-verified
dtb_name: none
description: verified modem slots fixture
modem_ports:
  status: verified
  slots:
    modem0: platform-fc000000.usb-usb-0:1:1.0
    modem1: platform-fc400000.usb-usb-0:1:1.0
YAML
  run validate_manifest "$brd" "$BOARD_SCHEMA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"VALID"* ]]
}

@test "modem_ports schema: an out-of-enum status is REJECTED and names modem_ports" {
  local brd="$BATS_TEST_TMPDIR/bad-status-board.yaml"
  cat > "$brd" <<'YAML'
family: rk3588
board_id: modem-bad
dtb_name: none
description: bad modem status fixture
modem_ports:
  status: maybe
YAML
  run validate_manifest "$brd" "$BOARD_SCHEMA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"modem_ports"* ]]
}

@test "modem_ports schema: a slot key that is not modemN is REJECTED" {
  local brd="$BATS_TEST_TMPDIR/bad-slot-board.yaml"
  cat > "$brd" <<'YAML'
family: rk3588
board_id: modem-badslot
dtb_name: none
description: bad modem slot key fixture
modem_ports:
  status: verified
  slots:
    wlan0: platform-xyz
YAML
  run validate_manifest "$brd" "$BOARD_SCHEMA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"modem_ports"* ]]
}

# --- Generator matrix: the CORE fail-closed contract of this integration -------
# run_modem_generator <status> <slots> — source udev.sh's generator (setup runs on
# source but writes only into the scratch rules dir), drive it with the given
# CERALIVE_MODEM_PORTS_* env, and echo the resulting rules-dir listing.
run_modem_generator() {
  local status="$1" slots="$2"
  local rules_dir="$BATS_TEST_TMPDIR/udev-rules.d"
  rm -rf "$rules_dir"; mkdir -p "$rules_dir"
  env CERALIVE_MODEM_PORTS_STATUS="$status" CERALIVE_MODEM_PORTS_SLOTS="$slots" \
      MODEM_SLOT_RULES_DIR="$rules_dir" \
      bash -c "source '$V2/mkosi/customize/udev.sh' >/dev/null 2>&1 || true
               source '$V2/lib/common.sh'
               source '$V2/mkosi/customize/udev.sh' 2>/dev/null || true
               generate_modem_slot_uid_rules" >"$BATS_TEST_TMPDIR/gen.out" 2>&1
  MODEM_GEN_STATUS=$?
  MODEM_GEN_RULES="$rules_dir/78-mm-ceralive-slot-uid.rules"
}

@test "modem generator MATRIX: unverified fixture emits ZERO generated slot-uid rules (fail-closed)" {
  run_modem_generator unverified ""
  [ "$MODEM_GEN_STATUS" -eq 0 ]
  [ ! -f "$MODEM_GEN_RULES" ]
  grep -q "emitting NO generated slot-uid rules" "$BATS_TEST_TMPDIR/gen.out"
}

@test "modem generator MATRIX: an unset status is treated as unverified (no permissive fallback)" {
  local rules_dir="$BATS_TEST_TMPDIR/udev-unset"
  rm -rf "$rules_dir"; mkdir -p "$rules_dir"
  run env -u CERALIVE_MODEM_PORTS_STATUS -u CERALIVE_MODEM_PORTS_SLOTS \
      MODEM_SLOT_RULES_DIR="$rules_dir" \
      bash -c "source '$V2/lib/common.sh'; source '$V2/mkosi/customize/udev.sh' 2>/dev/null || true; generate_modem_slot_uid_rules"
  [ "$status" -eq 0 ]
  [ ! -f "$rules_dir/78-mm-ceralive-slot-uid.rules" ]
}

@test "modem generator MATRIX: a verified fixture EMITS one ID_MM_PHYSDEV_UID rule per slot" {
  run_modem_generator verified "modem0=platform-fc000000.usb-usb-0:1:1.0 modem1=platform-fc400000.usb-usb-0:1:1.0"
  [ "$MODEM_GEN_STATUS" -eq 0 ]
  [ -f "$MODEM_GEN_RULES" ]
  grep -q 'ENV{ID_PATH}=="platform-fc000000.usb-usb-0:1:1.0", ENV{ID_MM_PHYSDEV_UID}="modem0"' "$MODEM_GEN_RULES"
  grep -q 'ENV{ID_PATH}=="platform-fc400000.usb-usb-0:1:1.0", ENV{ID_MM_PHYSDEV_UID}="modem1"' "$MODEM_GEN_RULES"
  # exactly two emitted RULE lines (count ACTION== rules, not the header comment
  # line that also mentions ID_MM_PHYSDEV_UID)
  [ "$(grep -c '^ACTION==.*ID_MM_PHYSDEV_UID' "$MODEM_GEN_RULES")" -eq 2 ]
}

@test "modem generator MATRIX: a stale verified rule file is removed when status reverts to unverified" {
  local rules_dir="$BATS_TEST_TMPDIR/udev-revert"
  rm -rf "$rules_dir"; mkdir -p "$rules_dir"
  # seed a prior generated file, then run unverified — it must be cleaned up
  printf 'stale\n' > "$rules_dir/78-mm-ceralive-slot-uid.rules"
  run env CERALIVE_MODEM_PORTS_STATUS=unverified CERALIVE_MODEM_PORTS_SLOTS="" \
      MODEM_SLOT_RULES_DIR="$rules_dir" \
      bash -c "source '$V2/lib/common.sh'; source '$V2/mkosi/customize/udev.sh' 2>/dev/null || true; generate_modem_slot_uid_rules"
  [ "$status" -eq 0 ]
  [ ! -f "$rules_dir/78-mm-ceralive-slot-uid.rules" ]
}

@test "modem generator MATRIX: verified with NO slots FAILS closed (refuses an empty verified set)" {
  local rules_dir="$BATS_TEST_TMPDIR/udev-empty-verified"
  rm -rf "$rules_dir"; mkdir -p "$rules_dir"
  run env CERALIVE_MODEM_PORTS_STATUS=verified CERALIVE_MODEM_PORTS_SLOTS="" \
      MODEM_SLOT_RULES_DIR="$rules_dir" \
      bash -c "source '$V2/lib/common.sh'; source '$V2/mkosi/customize/udev.sh' 2>/dev/null || true; generate_modem_slot_uid_rules"
  [ "$status" -ne 0 ]
  [ ! -f "$rules_dir/78-mm-ceralive-slot-uid.rules" ]
}

@test "modem generator: the permanent generic modem rules (udev.sh 'USB Modem Devices') are untouched" {
  # The fail-closed generator must NOT remove or alter the always-shipped generic
  # dialout group-tag rules in setup_hardware_access.
  local udev="$V2/mkosi/customize/udev.sh"
  grep -Fq 'USB Modem Devices (4G/5G)' "$udev"
  grep -Fq 'KERNEL=="cdc-wdm[0-9]*", GROUP="dialout"' "$udev"
  grep -Fq 'ATTRS{idVendor}=="2c7c", GROUP="dialout"' "$udev"
  # and the generator is a SEPARATE function, invoked after setup_hardware_access
  grep -Fq 'generate_modem_slot_uid_rules "$@"' "$udev"
}

@test "hdmi-in: a driver-keyed SYMLINK rule gives the SoC HDMI-RX a stable /dev/hdmi-in node" {
  # The SoC HDMI-IN capture node must get a persistent, collision-proof name that
  # does not depend on its /dev/videoN enumeration index (a USB capture card can
  # grab video0 and renumber the HDMI-RX). The symlink rule keys on the stable
  # HDMI-RX DRIVER name, never on KERNEL=="video0" or the node's name attr.
  local udev="$V2/mkosi/customize/udev.sh"
  local rule
  rule="$(grep -F 'SYMLINK+="hdmi-in"' "$udev")"
  [ -n "$rule" ]
  # keyed on the driver name, not a fixed node index
  [[ "$rule" == *'DRIVERS=="rk_hdmirx|snps_hdmirx"'* ]]
  [[ "$rule" != *'ATTRS{name}=="rk_hdmirx"'* ]]
  [[ "$rule" != *'KERNEL=="video0"'* ]]
  # also provides /dev/hdmirx (cerastream's canonical default HDMI device string)
  [[ "$rule" == *'SYMLINK+="hdmirx"'* ]]
  # additive: the original name-matched HDMI permission rules are still present
  grep -Fq 'ATTRS{name}=="rk_hdmirx", GROUP="video", MODE="0664"' "$udev"
  grep -Fq 'ATTRS{name}=="*hdmi*", GROUP="video", MODE="0664"' "$udev"
}

@test "hdmi-in: the symlink rule is in the LIVE writer (runtime postinst), not only the customize module" {
  # `./v2/build` runs mkosi.images/runtime/mkosi.postinst.chroot; run-all.sh's
  # RUNTIME modules (customize/udev.sh) are NOT executed by it — only
  # `run-all.sh base`. So a rule that exists ONLY in customize/udev.sh never
  # ships. That is exactly what happened: a live Rock 5B+ had neither
  # /dev/hdmi-in nor /dev/hdmirx, and its /etc/udev/rules.d/99-ceralive-hardware.rules
  # was the postinst twin with no symlink rule at all (board-confirmed 2026-08-02).
  local postinst="$V2/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"
  local rule
  rule="$(grep -F 'SYMLINK+="hdmi-in"' "$postinst")"
  [ -n "$rule" ]
  [[ "$rule" == *'DRIVERS=="rk_hdmirx|snps_hdmirx"'* ]]
  [[ "$rule" == *'SYMLINK+="hdmirx"'* ]]
  [[ "$rule" != *'KERNEL=="video0"'* ]]
}

@test "hdmi-in: BOTH kernel tracks' driver names are matched (rk_hdmirx AND snps_hdmirx)" {
  # The vendor BSP ships an out-of-tree driver named rk_hdmirx; mainline (the
  # `edge` variant) ships the upstream Synopsys driver, whose platform driver
  # name is snps_hdmirx. Board-confirmed on 7.1.5:
  #   readlink /sys/devices/platform/fdee0000.hdmi_receiver/driver
  #     -> /sys/bus/platform/drivers/snps_hdmirx
  # An rk_hdmirx-only rule therefore produces NO symlink on an edge image.
  local f
  for f in "$V2/mkosi/customize/udev.sh" \
           "$V2/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"; do
    local rule
    rule="$(grep -F 'SYMLINK+="hdmi-in"' "$f")"
    [[ "$rule" == *rk_hdmirx* ]]
    [[ "$rule" == *snps_hdmirx* ]]
  done
}

@test "runtime packages: bluez is installed so the Bluetooth adapter is usable" {
  # The kernel half already works: on a Rock 5B+ the RTL8852BE's Bluetooth radio
  # enumerates as USB 13d3:3572, btusb+btrtl bind it, and /sys/class/bluetooth/hci0
  # exists. Without bluez there is no bluetoothd, no bluetooth.service and no
  # bluetoothctl, so the adapter can never be powered up or paired. libbluetooth3
  # ships only as an unrelated transitive dependency and provides no daemon.
  run grep -Ex 'bluez[[:space:]]*(#.*)?' "$V2/manifests/packages/shared.list"
  [ "$status" -eq 0 ]
}

@test "modem_ports wiring: CERALIVE_MODEM_PORTS_* is forwarded env_names -> PassEnvironment lockstep" {
  # Mirrors the interface-naming lockstep guard: the status/slots vars must be in
  # BOTH orchestrate.sh env_names AND mkosi.conf PassEnvironment, or they read
  # EMPTY in the runtime subimage chroot (the generator would then see no status).
  local orchestrate="$LIB_DIR/orchestrate.sh"
  local mkosi_conf="$V2/mkosi/mkosi.conf"
  local var
  for var in CERALIVE_MODEM_PORTS_STATUS CERALIVE_MODEM_PORTS_SLOTS; do
    grep -Fq "$var" "$orchestrate" || { echo "$var missing from orchestrate.sh"; false; }
    grep -Eq "^PassEnvironment=.*$var" "$mkosi_conf" || { echo "$var missing from PassEnvironment"; false; }
  done
}

# ===========================================================================
# 26. Family variants + kernel-build-from-source (Task 26).
#
#     The load-bearing property of this whole feature is a NEGATIVE one: adding
#     an opt-in variant must not move the production vendor path by a single
#     byte. That is pinned first (against committed golden fixtures), and pinned
#     with an explicit non-vacuity leg, because a golden-file comparison that
#     silently compares nothing is worse than no comparison at all.
# ===========================================================================

VENDOR_BASELINE_DIR() { printf '%s' "$TESTS_DIR/manifests/fixtures/vendor-baseline"; }

# make_stub_deb <out.deb> <package> <version> <arch> — a minimal but REAL .deb
# (debian-binary + control.tar.gz + data.tar.gz via ar) so the uniqueness check
# exercises its actual ar+tar control-reading path rather than a filename parse.
make_stub_deb() {
  local out="$1" pkg="$2" version="$3" arch="$4" tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/ctl" "$tmp/data"
  printf 'stub\n' > "$tmp/data/stub"
  tar -C "$tmp/data" -czf "$tmp/data.tar.gz" .
  cat > "$tmp/ctl/control" <<CTL
Package: ${pkg}
Version: ${version}
Architecture: ${arch}
Maintainer: ceralive-test <test@ceralive.tv>
Description: fixture package for staged-uniqueness tests
CTL
  tar -C "$tmp/ctl" -czf "$tmp/control.tar.gz" ./control
  printf '2.0\n' > "$tmp/debian-binary"
  ( cd "$tmp" && ar rc "$out" debian-binary control.tar.gz data.tar.gz )
  rm -rf "$tmp"
}

# Write a schema-valid family carrying one variant overlay, so the negative
# schema legs below differ from the shipped manifest in exactly one field.
write_variant_family() {
  local dest="$1" overlay="$2"
  cat > "$dest" <<YAML
arch: arm64
armbian_branch: vendor
kernel_packages: [linux-image-vendor-rk35xx]
uboot_packages: []
dtb_packages: [linux-dtb-vendor-rk35xx]
firmware_packages: [armbian-firmware]
rauc_bootloader_adapter: custom
partition_template: rk3588-ab
serial_console: ttyS2:1500000
variants:
${overlay}
YAML
}

@test "variants: shipped rk3588 family declares edge and still validates" {
  run validate_manifest "$V2/manifests/families/rk3588.yaml" "$FAMILY_SCHEMA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"VALID"* ]]
  grep -Eq '^variants:' "$V2/manifests/families/rk3588.yaml"
  grep -Eq '^  edge:' "$V2/manifests/families/rk3588.yaml"
}

@test "variants: VENDOR PATH IS BYTE-IDENTICAL for every shipped board" {
  # THE hard requirement of task 26. The fixtures were captured from the
  # resolver BEFORE variants existed; if declaring one moved any production
  # parameter, this fails with a readable diff.
  local board
  for board in rock-5b-plus orange-pi-5-plus x86-minipc; do
    run bash -c "'$RESOLVE_SH' '$board' 2>/dev/null"
    [ "$status" -eq 0 ]
    if ! diff -u "$(VENDOR_BASELINE_DIR)/${board}.params" <(printf '%s\n' "$output") >&2; then
      printf 'vendor path moved for %s\n' "$board" >&2
      false
    fi
  done
}

@test "variants: explicit --variant default is also byte-identical to the baseline" {
  run bash -c "'$RESOLVE_SH' rock-5b-plus --variant default 2>/dev/null"
  [ "$status" -eq 0 ]
  diff -u "$(VENDOR_BASELINE_DIR)/rock-5b-plus.params" <(printf '%s\n' "$output") >&2
}

@test "variants: CERALIVE_KERNEL_VARIANT=default is byte-identical too" {
  run bash -c "CERALIVE_KERNEL_VARIANT=default '$RESOLVE_SH' rock-5b-plus 2>/dev/null"
  [ "$status" -eq 0 ]
  diff -u "$(VENDOR_BASELINE_DIR)/rock-5b-plus.params" <(printf '%s\n' "$output") >&2
}

@test "variants: the byte-identity proof HAS TEETH (a real change makes it fail)" {
  # Non-vacuity. Resolve with the edge variant — which genuinely changes the
  # kernel package and branch — and require the SAME comparison to fail. Without
  # this leg a broken fixture path would make the guard above pass forever.
  run bash -c "'$RESOLVE_SH' rock-5b-plus --variant edge 2>/dev/null"
  [ "$status" -eq 0 ]
  run diff -q "$(VENDOR_BASELINE_DIR)/rock-5b-plus.params" <(printf '%s\n' "$output")
  [ "$status" -ne 0 ]
}

@test "variants: the variants: block never reaches the flattened param set" {
  # A leaked VARIANTS_* key would (a) move the vendor path and (b) hand the
  # orchestrator a second, unselected kernel pin in its environment.
  local board
  for board in rock-5b-plus orange-pi-5-plus x86-minipc; do
    run bash -c "'$RESOLVE_SH' '$board' 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" != *"VARIANTS_"* ]]
    run bash -c "'$RESOLVE_SH' rock-5b-plus --variant edge 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" != *"VARIANTS_"* ]]
  done
}

@test "variants: merge order is family -> variant -> board (board still wins last)" {
  fam="$BATS_TEST_TMPDIR/vfam.yaml"
  brd="$BATS_TEST_TMPDIR/vbrd.yaml"
  cat > "$fam" <<'YAML'
from_family: family
overridden_by_variant: family
overridden_by_board: family
variants:
  edge:
    overridden_by_variant: variant
    overridden_by_board: variant
YAML
  cat > "$brd" <<'YAML'
family: vfam
overridden_by_board: board
YAML
  run python3 "$RESOLVE_PY" merge --family "$fam" --board "$brd" --variant edge
  [ "$status" -eq 0 ]
  [[ "$output" == *$'FROM_FAMILY\tfamily'* ]]
  [[ "$output" == *$'OVERRIDDEN_BY_VARIANT\tvariant'* ]]
  [[ "$output" == *$'OVERRIDDEN_BY_BOARD\tboard'* ]]
}

@test "variants: an unknown variant fails loudly and lists what IS available" {
  run bash -c "'$RESOLVE_SH' rock-5b-plus --variant does-not-exist 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does-not-exist"* ]]
  [[ "$output" == *"available: edge"* ]]
}

@test "variants: --variant with no name is refused (never silently defaults)" {
  run bash -c "'$RESOLVE_SH' rock-5b-plus --variant '' 2>&1"
  [ "$status" -ne 0 ]
}

@test "variants: x86 has no variants, so an edge build of x86-minipc is refused" {
  # x86_64 declares no variants at all. Asking for one must fail rather than
  # silently resolve the vendor path under a name that promises otherwise.
  run bash -c "'$RESOLVE_SH' x86-minipc --variant edge 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown variant 'edge'"* ]]
  [[ "$output" == *"available: <none>"* ]]
}

@test "variants: schema rejects a variant named 'default' (reserved)" {
  local f="$BATS_TEST_TMPDIR/default-variant.yaml"
  write_variant_family "$f" "  default:
    armbian_branch: edge"
  run validate_manifest "$f" "$FAMILY_SCHEMA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"variants"* ]]
}

@test "variants: schema rejects an unknown field inside a variant overlay" {
  local f="$BATS_TEST_TMPDIR/wide-variant.yaml"
  write_variant_family "$f" "  edge:
    firmware_packages: [something-else]"
  run validate_manifest "$f" "$FAMILY_SCHEMA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"firmware_packages"* ]]
}

# Write a schema-valid board carrying one variant_overrides block, so the
# negative legs below differ from the shipped manifest in exactly one field.
write_override_board() {
  local dest="$1" overrides="$2"
  cat > "$dest" <<YAML
family: rk3588
board_id: fixture-board
dtb_name: rk3588-fixture.dtb
description: fixture board for variant_overrides schema legs
variant_overrides:
${overrides}
YAML
}

@test "variant_overrides: OPi 5+ --variant edge resolves the MAINLINE DTB name" {
  # Mainline's rockchip Makefile at the pinned v7.1.5 builds
  # rk3588-orangepi-5-plus.dtb, and the override states that explicitly rather
  # than inheriting it, so a future mainline rename moves exactly one line.
  run bash -c "'$RESOLVE_SH' orange-pi-5-plus --variant edge 2>/dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DTB_NAME='rk3588-orangepi-5-plus.dtb'"* ]]
  [[ "$output" != *"rk3588s-orangepi-5-plus.dtb"* ]]
}

@test "variant_overrides: OPi 5+ PRODUCTION path resolves the VENDOR DTB name" {
  # REGRESSION GUARD. The board shipped dtb_name 'rk3588s-orangepi-5-plus.dtb'
  # from its first commit, inferred from the "5 Plus (RK3588S)" marketing name.
  # It is wrong: the 5 Plus carries the full RK3588. The pinned vendor package
  # linux-dtb-vendor-rk35xx 26.5.1 ships rk3588-orangepi-5-plus.dtb and has NO
  # rk3588s-orangepi-5-plus.dtb — verified by extraction, and true of every
  # version in the Armbian archive back to 24.5.1, so this was never drift.
  # A real production build failed the [6b/9] boot-artifact gate on it; the
  # DRY_RUN-only PR gate never runs that stage, which is what this test replaces.
  run bash -c "'$RESOLVE_SH' orange-pi-5-plus 2>/dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DTB_NAME='rk3588-orangepi-5-plus.dtb'"* ]]
  [[ "$output" != *"rk3588s-orangepi-5-plus.dtb"* ]]
}

@test "variant_overrides: no shipped board claims an rk3588s- DTB (the '5 Plus' trap)" {
  # The bug class, not just the one instance: an RK3588S-looking board name does
  # not make the DTB rk3588s-. Both shipped RK3588 boards are full-RK3588 parts,
  # so the prefix must appear on neither, on either kernel path.
  local board path
  for board in rock-5b-plus orange-pi-5-plus; do
    ! grep -Eq '^\s*dtb_name:\s*rk3588s-' "$V2/manifests/boards/${board}.yaml"
    for path in "" "--variant edge"; do
      run bash -c "'$RESOLVE_SH' '$board' $path 2>/dev/null"
      [ "$status" -eq 0 ]
      [[ "$output" != *"DTB_NAME='rk3588s-"* ]]
    done
  done
}

@test "variant_overrides: Rock 5B+ is UNAFFECTED with and without the variant" {
  # It declares no override and needs none — mainline and vendor agree on this
  # board's spelling. Asserted explicitly on BOTH paths so a future accidental
  # divergence (either tree renaming it) is caught here rather than at build.
  local path
  for path in "" "--variant edge"; do
    run bash -c "'$RESOLVE_SH' rock-5b-plus $path 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"DTB_NAME='rk3588-rock-5b-plus.dtb'"* ]]
  done
  ! grep -Fq 'variant_overrides' "$V2/manifests/boards/rock-5b-plus.yaml"
}

@test "variant_overrides: the mechanism is OPT-IN, not a silent global change" {
  # Non-vacuity. A board that declares NO override must resolve its ordinary
  # board dtb_name under a variant, exactly as before this existed. Without
  # this leg the change could be rewriting DTB names fleet-wide unnoticed.
  local fam="$BATS_TEST_TMPDIR/no-ovr-fam.yaml"
  local brd="$BATS_TEST_TMPDIR/no-ovr-brd.yaml"
  cat > "$fam" <<'YAML'
dtb_name: family-default.dtb
variants:
  edge:
    armbian_branch: edge
YAML
  cat > "$brd" <<'YAML'
family: no-ovr-fam
dtb_name: board-own.dtb
YAML
  run python3 "$RESOLVE_PY" merge --family "$fam" --board "$brd" --variant edge
  [ "$status" -eq 0 ]
  [[ "$output" == *$'DTB_NAME\tboard-own.dtb'* ]]
}

@test "variant_overrides: the block never reaches the flattened param set" {
  # A leaked VARIANT_OVERRIDES_* key would move the vendor path and hand the
  # orchestrator a second, unselected DTB name in its environment.
  local path
  for path in "" "--variant edge"; do
    run bash -c "'$RESOLVE_SH' orange-pi-5-plus $path 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" != *"VARIANT_OVERRIDES"* ]]
  done
}

@test "variant_overrides: an override applies AFTER the board, not before it" {
  # Board-wins-last is untouched: a plain variant overlay still loses to the
  # board, and only the board's OWN per-variant entry wins.
  local fam="$BATS_TEST_TMPDIR/ovr-order-fam.yaml"
  local brd="$BATS_TEST_TMPDIR/ovr-order-brd.yaml"
  cat > "$fam" <<'YAML'
variants:
  edge:
    dtb_name: from-variant.dtb
    other_field: from-variant
YAML
  cat > "$brd" <<'YAML'
family: ovr-order-fam
dtb_name: from-board.dtb
other_field: from-board
variant_overrides:
  edge:
    dtb_name: from-board-override.dtb
YAML
  run python3 "$RESOLVE_PY" merge --family "$fam" --board "$brd" --variant edge
  [ "$status" -eq 0 ]
  [[ "$output" == *$'DTB_NAME\tfrom-board-override.dtb'* ]]
  [[ "$output" == *$'OTHER_FIELD\tfrom-board'* ]]
}

@test "variant_overrides: an override for a variant the family lacks is FATAL" {
  # The PR #83 defect-3 class: a mechanism that silently never triggers. A
  # typo'd variant name must fail the resolve, not sit there looking effective.
  local fam="$BATS_TEST_TMPDIR/typo-fam.yaml"
  local brd="$BATS_TEST_TMPDIR/typo-brd.yaml"
  cat > "$fam" <<'YAML'
variants:
  edge:
    armbian_branch: edge
YAML
  cat > "$brd" <<'YAML'
family: typo-fam
dtb_name: board-own.dtb
variant_overrides:
  edg:
    dtb_name: never-applies.dtb
YAML
  # Fatal on the DEFAULT path too — the typo is a manifest defect either way.
  run python3 "$RESOLVE_PY" merge --family "$fam" --board "$brd"
  [ "$status" -eq 2 ]
  [[ "$output" == *"variant 'edg'"* ]]
  [[ "$output" == *"never apply"* ]]
}

@test "variant_overrides: schema rejects an entry named 'default' (reserved)" {
  local f="$BATS_TEST_TMPDIR/default-override.yaml"
  write_override_board "$f" "  default:
    dtb_name: rk3588-other.dtb"
  run validate_manifest "$f" "$BOARD_SCHEMA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"variant_overrides"* ]]
}

@test "variant_overrides: schema rejects any field other than dtb_name" {
  # Deliberately narrow. This is a DTB-naming mechanism, not a general
  # board-overrides-the-variant escape hatch.
  local f="$BATS_TEST_TMPDIR/wide-override.yaml"
  write_override_board "$f" "  edge:
    kernel_packages: [linux-image-something]"
  run validate_manifest "$f" "$BOARD_SCHEMA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"kernel_packages"* ]]
}

@test "variant_overrides: shipped OPi 5+ board manifest declares edge and validates" {
  run validate_manifest "$V2/manifests/boards/orange-pi-5-plus.yaml" "$BOARD_SCHEMA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"VALID"* ]]
  grep -Eq '^variant_overrides:' "$V2/manifests/boards/orange-pi-5-plus.yaml"
  grep -Eq '^  edge:' "$V2/manifests/boards/orange-pi-5-plus.yaml"
}

@test "kernel_source: schema rejects a FLOATING patches reference" {
  # The single most important pin in the block: a branch name here would make
  # the built kernel unreproducible while still looking pinned.
  local f="$BATS_TEST_TMPDIR/floating-patches.yaml"
  write_variant_family "$f" "  edge:
    kernel_source:
      git_url: https://example.invalid/linux.git
      tag: v7.1.5
      commit: 155b42bec9cbb6b8cdc47dd9bd09503a81fbe493
      patches_git_url: https://example.invalid/patches.git
      patches_commit: main
      patches_series: patches/series
      defconfig_base: defconfig
      defconfig_fragment: manifests/kernel/f.fragment
      builder_image: debian:trixie-slim@sha256:28de0877c2189802884ccd20f15ee41c203573bd87bb6b883f5f46362d24c5c2
      local_version: -ceralive-rk3588
      kernel_release: 7.1.5-ceralive-rk3588
      package_version: 7.1.5-ceralive1
      dtb_deb_dir: /usr/lib/linux-image-7.1.5-ceralive-rk3588/rockchip
      dtb_boot_dir: /boot/dtb/rockchip"
  run validate_manifest "$f" "$FAMILY_SCHEMA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"patches_commit"* ]]
}

@test "kernel_source: schema rejects a builder_image without a digest" {
  local f="$BATS_TEST_TMPDIR/floating-image.yaml"
  write_variant_family "$f" "  edge:
    kernel_source:
      git_url: https://example.invalid/linux.git
      tag: v7.1.5
      commit: 155b42bec9cbb6b8cdc47dd9bd09503a81fbe493
      patches_git_url: https://example.invalid/patches.git
      patches_commit: 4809354656a16443c0b69f1e72b77f3fea1cbdae
      patches_series: patches/series
      defconfig_base: defconfig
      defconfig_fragment: manifests/kernel/f.fragment
      builder_image: debian:trixie-slim
      local_version: -ceralive-rk3588
      kernel_release: 7.1.5-ceralive-rk3588
      package_version: 7.1.5-ceralive1
      dtb_deb_dir: /usr/lib/linux-image-7.1.5-ceralive-rk3588/rockchip
      dtb_boot_dir: /boot/dtb/rockchip"
  run validate_manifest "$f" "$FAMILY_SCHEMA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"builder_image"* ]]
}

@test "kernel_source: schema rejects an incomplete pin (missing commit)" {
  local f="$BATS_TEST_TMPDIR/incomplete-pin.yaml"
  write_variant_family "$f" "  edge:
    kernel_source:
      git_url: https://example.invalid/linux.git
      tag: v7.1.5
      patches_git_url: https://example.invalid/patches.git
      patches_commit: 4809354656a16443c0b69f1e72b77f3fea1cbdae
      patches_series: patches/series
      defconfig_base: defconfig
      defconfig_fragment: manifests/kernel/f.fragment
      builder_image: debian:trixie-slim@sha256:28de0877c2189802884ccd20f15ee41c203573bd87bb6b883f5f46362d24c5c2
      local_version: -ceralive-rk3588
      kernel_release: 7.1.5-ceralive-rk3588
      package_version: 7.1.5-ceralive1
      dtb_deb_dir: /usr/lib/linux-image-7.1.5-ceralive-rk3588/rockchip
      dtb_boot_dir: /boot/dtb/rockchip"
  run validate_manifest "$f" "$FAMILY_SCHEMA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"commit"* ]]
}

@test "kernel_source: suppressed_packages is DERIVED, and a manifest cannot author it" {
  local f="$BATS_TEST_TMPDIR/authored-suppression.yaml"
  write_variant_family "$f" "  edge:
    kernel_source:
      git_url: https://example.invalid/linux.git
      tag: v7.1.5
      commit: 155b42bec9cbb6b8cdc47dd9bd09503a81fbe493
      patches_git_url: https://example.invalid/patches.git
      patches_commit: 4809354656a16443c0b69f1e72b77f3fea1cbdae
      patches_series: patches/series
      defconfig_base: defconfig
      defconfig_fragment: manifests/kernel/f.fragment
      builder_image: debian:trixie-slim@sha256:28de0877c2189802884ccd20f15ee41c203573bd87bb6b883f5f46362d24c5c2
      local_version: -ceralive-rk3588
      kernel_release: 7.1.5-ceralive-rk3588
      package_version: 7.1.5-ceralive1
      dtb_deb_dir: /usr/lib/linux-image-7.1.5-ceralive-rk3588/rockchip
      dtb_boot_dir: /boot/dtb/rockchip
      suppressed_packages: [linux-image-vendor-rk35xx]"
  run validate_manifest "$f" "$FAMILY_SCHEMA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"suppressed_packages"* ]]
}

@test "kernel_source: the edge resolve replaces the kernel package and empties DTB_PACKAGES" {
  run bash -c "'$RESOLVE_SH' rock-5b-plus --variant edge 2>/dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"KERNEL_PACKAGES='linux-image-7.1.5-ceralive-rk3588'"* ]]
  [[ "$output" == *"DTB_PACKAGES=''"* ]]
  [[ "$output" == *"KERNEL_VARIANT='edge'"* ]]
  # U-Boot and firmware are NOT replaced: they stay prebuilt-fetched.
  [[ "$output" == *"UBOOT_PACKAGES='linux-u-boot-rock-5b-plus-vendor'"* ]]
  [[ "$output" == *"FIRMWARE_PACKAGES='armbian-firmware libmali-valhall-g610-g24p0-wayland-gbm'"* ]]
}

@test "kernel_source: the derived suppression set is pre-overlay UNION post-overlay" {
  # Both halves matter. The pre-overlay vendor names are still in the family
  # file (fetch-debs reads it directly); the post-overlay built name exists in
  # no remote archive. Missing either half means a failed or wrong fetch.
  run bash -c "'$RESOLVE_SH' rock-5b-plus --variant edge 2>/dev/null"
  [ "$status" -eq 0 ]
  local line
  line="$(grep '^KERNEL_SOURCE_SUPPRESSED_PACKAGES=' <<<"$output")"
  [[ "$line" == *"linux-image-vendor-rk35xx"* ]]
  [[ "$line" == *"linux-dtb-vendor-rk35xx"* ]]
  [[ "$line" == *"linux-image-7.1.5-ceralive-rk3588"* ]]
  # U-Boot / firmware must NEVER be suppressed.
  [[ "$line" != *"linux-u-boot"* ]]
  [[ "$line" != *"armbian-firmware"* ]]
}

@test "kernel_source: the pinned patches commit is the merged CERALIVE PR #2 SHA" {
  # A regression pin on the actual value. CERALIVE/rk3588-kernel-patches#2 added
  # patch 0006 (the HDMI-RX audio sound-card device tree) on top of PR #1's
  # series; a silent bump here would change what the kernel contains with no
  # other signal.
  run bash -c "'$RESOLVE_SH' rock-5b-plus --variant edge 2>/dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"KERNEL_SOURCE_PATCHES_COMMIT='9c1cb385098d842a1d5755e3717b308a25bb8305'"* ]]
  [[ "$output" == *"KERNEL_SOURCE_PATCHES_GIT_URL='https://github.com/CERALIVE/rk3588-kernel-patches.git'"* ]]
  [[ "$output" == *"KERNEL_SOURCE_TAG='v7.1.5'"* ]]
  [[ "$output" == *"KERNEL_SOURCE_COMMIT='155b42bec9cbb6b8cdc47dd9bd09503a81fbe493'"* ]]
}

@test "kernel_source: the defconfig fragment the manifest names actually exists" {
  local frag
  frag="$(bash -c "'$RESOLVE_SH' rock-5b-plus --variant edge 2>/dev/null" \
          | sed -n "s/^KERNEL_SOURCE_DEFCONFIG_FRAGMENT='\(.*\)'$/\1/p")"
  [ -n "$frag" ]
  [ -f "$V2/$frag" ]
  # The two symbols the whole variant exists for.
  grep -q 'CONFIG_VIDEO_ROCKCHIP_RKVENC=' "$V2/$frag"
  grep -q 'CONFIG_VIDEO_SYNOPSYS_HDMIRX=' "$V2/$frag"
  # Determinism switch: an auto localversion would change the package NAME.
  grep -q 'CONFIG_LOCALVERSION_AUTO=n' "$V2/$frag"
}

# --- vendor-patched: commit-only source + full-config mode -------------------
#
# The vendor BSP differs from `edge` in two STRUCTURAL ways, and both were
# generalizations of build-kernel.sh rather than special cases:
#   Gap A  rk-6.1-rkr5.1 publishes NO tags, so `tag` had to become optional and
#          the checkout had to learn a shallow-fetch-by-SHA shape.
#   Gap B  Armbian ships a COMPLETE .config for this kernel; `make defconfig`
#          would build a materially different driver set, so the config source
#          had to learn "start from a fetched full .config".

@test "vendor-patched: the variant resolves a commit-only source (NO tag) " {
  run bash -c "'$RESOLVE_SH' rock-5b-plus --variant vendor-patched 2>/dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"KERNEL_SOURCE_COMMIT='95e85f6cb496c75807c5b16f158853578e7e7d1b'"* ]]
  # A synthetic tag would misrepresent the source: there is no such ref.
  [[ "$output" != *"KERNEL_SOURCE_TAG="* ]]
}

@test "vendor-patched: the variant resolves the FULL Armbian .config, not a defconfig target" {
  run bash -c "'$RESOLVE_SH' rock-5b-plus --variant vendor-patched 2>/dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"KERNEL_SOURCE_CONFIG_PATH='config/kernel/linux-rk35xx-vendor.config'"* ]]
  [[ "$output" == *"KERNEL_SOURCE_CONFIG_COMMIT='5e2fa21ab509e9cf6afb05f3df46c9bd2b0cfa39'"* ]]
  # Substituting a bare defconfig would silently build a different kernel.
  [[ "$output" != *"KERNEL_SOURCE_DEFCONFIG_BASE="* ]]
  [[ "$output" != *"KERNEL_SOURCE_DEFCONFIG_FRAGMENT="* ]]
}

@test "vendor-patched: the built package name CANNOT collide with the stock vendor kernel" {
  # A collision is the one failure that yields a plausible image instead of an
  # error: the local repo would pick one by version and the board could boot the
  # UNPATCHED kernel. The stock name must also still be suppressed from fetch.
  run bash -c "'$RESOLVE_SH' rock-5b-plus --variant vendor-patched 2>/dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"KERNEL_PACKAGES='linux-image-6.1.115-ceralive-vendor-rk35xx'"* ]]
  [[ "$output" != *"KERNEL_PACKAGES='linux-image-vendor-rk35xx'"* ]]
  local line
  line="$(grep '^KERNEL_SOURCE_SUPPRESSED_PACKAGES=' <<<"$output")"
  [[ "$line" == *"linux-image-vendor-rk35xx"* ]]
  [[ "$line" == *"linux-dtb-vendor-rk35xx"* ]]
}

@test "vendor-patched: the allow-absent list the manifest names actually exists" {
  local rel
  rel="$(bash -c "'$RESOLVE_SH' rock-5b-plus --variant vendor-patched 2>/dev/null" \
         | sed -n "s/^KERNEL_SOURCE_CONFIG_ABSENT_SYMBOLS='\(.*\)'$/\1/p")"
  [ -n "$rel" ]
  [ -f "$V2/$rel" ]
}

@test "vendor-patched: the pinned patches commit is an exact 40-hex SHA of the VENDOR repo" {
  run bash -c "'$RESOLVE_SH' rock-5b-plus --variant vendor-patched 2>/dev/null"
  [ "$status" -eq 0 ]
  # The mainline sibling's patches do not apply to this tree and vice versa.
  [[ "$output" == *"KERNEL_SOURCE_PATCHES_GIT_URL='https://github.com/CERALIVE/rk3588-vendor-kernel-patches.git'"* ]]
  local sha
  sha="$(sed -n "s/^KERNEL_SOURCE_PATCHES_COMMIT='\(.*\)'$/\1/p" <<<"$output")"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]]
}

@test "vendor-patched: DRY_RUN plans a fetch-by-SHA checkout and a fetched full .config" {
  serialize build-plan
  run env INSTALL_BOOT_BSP=0 DRY_RUN=1 bash "$V2/build" rock-5b-plus --variant vendor-patched
  [ "$status" -eq 0 ]
  [[ "$output" == *"kernel_variant=vendor-patched"* ]]
  [[ "$output" == *"git fetch --depth 1 https://github.com/armbian/linux-rockchip.git 95e85f6cb496c75807c5b16f158853578e7e7d1b"* ]]
  [[ "$output" == *"commit-only source: the pinned branch publishes no tag"* ]]
  [[ "$output" == *"cp config/kernel/linux-rk35xx-vendor.config .config (full config, no defconfig target)"* ]]
  [[ "$output" == *"config-survival gate"* ]]
  [[ "$output" == *"linux-image-6.1.115-ceralive-vendor-rk35xx_6.1.115-ceralive1_arm64.deb"* ]]
  # The plan must not perform anything.
  [[ "$output" != *"docker run"* ]]
}

@test "vendor-patched: selecting it does NOT move the edge variant" {
  run bash -c "'$RESOLVE_SH' rock-5b-plus --variant edge 2>/dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"KERNEL_SOURCE_TAG='v7.1.5'"* ]]
  [[ "$output" == *"KERNEL_SOURCE_DEFCONFIG_BASE='defconfig'"* ]]
  [[ "$output" == *"KERNEL_PACKAGES='linux-image-7.1.5-ceralive-rk3588'"* ]]
  [[ "$output" == *"BUILDER_IMAGE='debian:trixie-"* ]]
  # edge declares no config-file trio at all.
  [[ "$output" != *"KERNEL_SOURCE_CONFIG_GIT_URL="* ]]
}

@test "bench patch clone: the override is a MIRROR, never a pin override" {
  local src="$LIB_DIR/build-kernel.sh"
  # The clone is read-only and reached over file://, so the container cannot
  # write to the operator's checkout and shallow fetch still works.
  grep -q 'CERALIVE_KERNEL_PATCHES_LOCAL_REPO' "$src"
  grep -q '/in/patches-src:ro' "$src"
  grep -q 'patches_fetch_url="file:///in/patches-src"' "$src"
  # The pin assertion must stay UNCONDITIONAL: this may change where the commit
  # comes from, never which commit is built.
  grep -q 'have_p="\$(git -C /src/patches rev-parse HEAD)"' "$src"
  grep -q 'FATAL: patches repo checked out' "$src"
  # ... and the manifest URL keeps flowing into the log line, so a bench build
  # still says which pin it is standing in for.
  grep -q 'BENCH: patch series fetched from local clone' "$src"
  grep -q 'do NOT use this on a release path' "$src"
}

@test "bench patch clone: safe.directory comes from GIT_CONFIG_GLOBAL, not -c" {
  local src="$LIB_DIR/build-kernel.sh"
  # git honours safe.directory ONLY from system/global config. A -c flag or a
  # GIT_CONFIG_COUNT entry is silently ignored and the fetch dies with
  # "detected dubious ownership", which is a real failure this already hit.
  grep -q 'GIT_CONFIG_GLOBAL=/in/gitconfig' "$src"
  ! grep -q 'GIT_CONFIG_KEY_0=safe.directory' "$src"
  ! grep -qE -- '-c[[:space:]]+safe\.directory' "$src"
}

@test "bench patch clone: unset means the manifest URL is used verbatim" {
  local src="$LIB_DIR/build-kernel.sh"
  grep -q 'local patches_fetch_url="\${patches_url}"' "$src"
  # And no shipped manifest may hardcode the bench path.
  ! grep -rq 'CERALIVE_KERNEL_PATCHES_LOCAL_REPO' "$V2/manifests"
}

@test "bench patch clone: a relative path or a non-git dir is refused" {
  run env DRY_RUN=0 CERALIVE_KERNEL_PATCHES_LOCAL_REPO=relative/path \
    ARCH=arm64 DTB_NAME=x.dtb KERNEL_PACKAGES=linux-image-x \
    KERNEL_SOURCE_GIT_URL=https://example.invalid/linux.git \
    KERNEL_SOURCE_COMMIT=155b42bec9cbb6b8cdc47dd9bd09503a81fbe493 \
    KERNEL_SOURCE_PATCHES_GIT_URL=https://example.invalid/patches.git \
    KERNEL_SOURCE_PATCHES_COMMIT=9c1cb385098d842a1d5755e3717b308a25bb8305 \
    KERNEL_SOURCE_PATCHES_SERIES=patches/series \
    KERNEL_SOURCE_DEFCONFIG_BASE=defconfig \
    KERNEL_SOURCE_DEFCONFIG_FRAGMENT=manifests/kernel/rk3588-edge.fragment \
    KERNEL_SOURCE_BUILDER_IMAGE='debian:trixie-slim@sha256:28de0877c2189802884ccd20f15ee41c203573bd87bb6b883f5f46362d24c5c2' \
    KERNEL_SOURCE_LOCAL_VERSION=-x KERNEL_SOURCE_KERNEL_RELEASE=1.0-x \
    KERNEL_SOURCE_PACKAGE_VERSION=1.0-x1 \
    KERNEL_SOURCE_DTB_DEB_DIR=/usr/lib/linux-image-x/rockchip \
    bash "$LIB_DIR/build-kernel.sh" --board rock-5b-plus --out "$BATS_TEST_TMPDIR/kobench"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CERALIVE_KERNEL_PATCHES_LOCAL_REPO"* ]]
}

@test "build-kernel: a half-declared config-file mode is refused before anything runs" {
  run env DRY_RUN=1 \
    ARCH=arm64 DTB_NAME=x.dtb KERNEL_PACKAGES=linux-image-x \
    KERNEL_SOURCE_GIT_URL=https://example.invalid/linux.git \
    KERNEL_SOURCE_COMMIT=155b42bec9cbb6b8cdc47dd9bd09503a81fbe493 \
    KERNEL_SOURCE_PATCHES_GIT_URL=https://example.invalid/patches.git \
    KERNEL_SOURCE_PATCHES_COMMIT=9c1cb385098d842a1d5755e3717b308a25bb8305 \
    KERNEL_SOURCE_PATCHES_SERIES=patches/series \
    KERNEL_SOURCE_CONFIG_GIT_URL=https://example.invalid/build.git \
    KERNEL_SOURCE_BUILDER_IMAGE='debian:trixie-slim@sha256:28de0877c2189802884ccd20f15ee41c203573bd87bb6b883f5f46362d24c5c2' \
    KERNEL_SOURCE_LOCAL_VERSION=-x KERNEL_SOURCE_KERNEL_RELEASE=1.0-x \
    KERNEL_SOURCE_PACKAGE_VERSION=1.0-x1 \
    KERNEL_SOURCE_DTB_DEB_DIR=/usr/lib/linux-image-x/rockchip \
    bash "$LIB_DIR/build-kernel.sh" --board rock-5b-plus --out "$BATS_TEST_TMPDIR/ko3"
  [ "$status" -ne 0 ]
  [[ "$output" == *"config_commit"* ]]
}

@test "build-kernel: declaring BOTH config modes is refused" {
  run env DRY_RUN=1 \
    ARCH=arm64 DTB_NAME=x.dtb KERNEL_PACKAGES=linux-image-x \
    KERNEL_SOURCE_GIT_URL=https://example.invalid/linux.git \
    KERNEL_SOURCE_COMMIT=155b42bec9cbb6b8cdc47dd9bd09503a81fbe493 \
    KERNEL_SOURCE_PATCHES_GIT_URL=https://example.invalid/patches.git \
    KERNEL_SOURCE_PATCHES_COMMIT=9c1cb385098d842a1d5755e3717b308a25bb8305 \
    KERNEL_SOURCE_PATCHES_SERIES=patches/series \
    KERNEL_SOURCE_CONFIG_GIT_URL=https://example.invalid/build.git \
    KERNEL_SOURCE_CONFIG_COMMIT=5e2fa21ab509e9cf6afb05f3df46c9bd2b0cfa39 \
    KERNEL_SOURCE_CONFIG_PATH=config/kernel/x.config \
    KERNEL_SOURCE_DEFCONFIG_BASE=defconfig \
    KERNEL_SOURCE_DEFCONFIG_FRAGMENT=manifests/kernel/rk3588-edge.fragment \
    KERNEL_SOURCE_BUILDER_IMAGE='debian:trixie-slim@sha256:28de0877c2189802884ccd20f15ee41c203573bd87bb6b883f5f46362d24c5c2' \
    KERNEL_SOURCE_LOCAL_VERSION=-x KERNEL_SOURCE_KERNEL_RELEASE=1.0-x \
    KERNEL_SOURCE_PACKAGE_VERSION=1.0-x1 \
    KERNEL_SOURCE_DTB_DEB_DIR=/usr/lib/linux-image-x/rockchip \
    bash "$LIB_DIR/build-kernel.sh" --board rock-5b-plus --out "$BATS_TEST_TMPDIR/ko4"
  [ "$status" -ne 0 ]
  [[ "$output" == *"exactly one config source"* ]]
}

@test "build-kernel: a floating config_commit is refused before anything runs" {
  run env DRY_RUN=1 \
    ARCH=arm64 DTB_NAME=x.dtb KERNEL_PACKAGES=linux-image-x \
    KERNEL_SOURCE_GIT_URL=https://example.invalid/linux.git \
    KERNEL_SOURCE_COMMIT=155b42bec9cbb6b8cdc47dd9bd09503a81fbe493 \
    KERNEL_SOURCE_PATCHES_GIT_URL=https://example.invalid/patches.git \
    KERNEL_SOURCE_PATCHES_COMMIT=9c1cb385098d842a1d5755e3717b308a25bb8305 \
    KERNEL_SOURCE_PATCHES_SERIES=patches/series \
    KERNEL_SOURCE_CONFIG_GIT_URL=https://example.invalid/build.git \
    KERNEL_SOURCE_CONFIG_COMMIT=main \
    KERNEL_SOURCE_CONFIG_PATH=config/kernel/x.config \
    KERNEL_SOURCE_BUILDER_IMAGE='debian:trixie-slim@sha256:28de0877c2189802884ccd20f15ee41c203573bd87bb6b883f5f46362d24c5c2' \
    KERNEL_SOURCE_LOCAL_VERSION=-x KERNEL_SOURCE_KERNEL_RELEASE=1.0-x \
    KERNEL_SOURCE_PACKAGE_VERSION=1.0-x1 \
    KERNEL_SOURCE_DTB_DEB_DIR=/usr/lib/linux-image-x/rockchip \
    bash "$LIB_DIR/build-kernel.sh" --board rock-5b-plus --out "$BATS_TEST_TMPDIR/ko5"
  [ "$status" -ne 0 ]
  [[ "$output" == *"never a branch or tag"* ]]
}

@test "kernel_source schema: tag is OPTIONAL, but a half config-file mode is rejected" {
  local f="$BATS_TEST_TMPDIR/commit-only.yaml"
  # No tag + full config-file mode: the vendor-patched shape. Must VALIDATE.
  write_variant_family "$f" "  vendor-patched:
    kernel_source:
      git_url: https://example.invalid/linux.git
      commit: 155b42bec9cbb6b8cdc47dd9bd09503a81fbe493
      patches_git_url: https://example.invalid/p.git
      patches_commit: 9c1cb385098d842a1d5755e3717b308a25bb8305
      patches_series: patches/series
      config_git_url: https://example.invalid/build.git
      config_commit: 5e2fa21ab509e9cf6afb05f3df46c9bd2b0cfa39
      config_path: config/kernel/x.config
      builder_image: debian:trixie-slim@sha256:28de0877c2189802884ccd20f15ee41c203573bd87bb6b883f5f46362d24c5c2
      local_version: -x
      kernel_release: 1.0-x
      package_version: 1.0-x1
      dtb_deb_dir: /usr/lib/linux-image-x/rockchip
      dtb_boot_dir: /boot/dtb/rockchip"
  run python3 "$RESOLVE_PY" merge --family "$f" --board "$V2/manifests/boards/rock-5b-plus.yaml" \
    --family-schema "$V2/manifests/schema/family.schema.json" --variant vendor-patched
  [ "$status" -eq 0 ]

  # Drop config_path -> neither mode is fully declared -> rejected.
  local g="$BATS_TEST_TMPDIR/half-config.yaml"
  sed '/config_path:/d' "$f" >"$g"
  run python3 "$RESOLVE_PY" merge --family "$g" --board "$V2/manifests/boards/rock-5b-plus.yaml" \
    --family-schema "$V2/manifests/schema/family.schema.json" --variant vendor-patched
  [ "$status" -ne 0 ]
}

@test "fetch suppression: suppressed kernel/DTB names leave the declared BSP set" {
  run bash -c "
    set -euo pipefail
    export CERALIVE_KERNEL_SOURCE_SUPPRESSED_PKGS='linux-image-vendor-rk35xx linux-dtb-vendor-rk35xx linux-image-7.1.5-ceralive-rk3588'
    export KERNEL_PACKAGES='linux-image-7.1.5-ceralive-rk3588'
    export DTB_PACKAGES=''
    source '$FETCH_DEBS'
    collect_declared_bsp_pkgs '$V2/manifests/families/rk3588.yaml'
  "
  [ "$status" -eq 0 ]
  [[ "$output" != *"linux-image-vendor-rk35xx"* ]]
  [[ "$output" != *"linux-dtb-vendor-rk35xx"* ]]
  [[ "$output" != *"linux-image-7.1.5-ceralive-rk3588"* ]]
  # Everything else the family declares is untouched.
  [[ "$output" == *"armbian-firmware"* ]]
  [[ "$output" == *"gstreamer1.0-rockchip1"* ]]
}

@test "fetch suppression: NON-VACUOUS — without it the vendor names are still declared" {
  run bash -c "
    set -euo pipefail
    unset CERALIVE_KERNEL_SOURCE_SUPPRESSED_PKGS KERNEL_PACKAGES DTB_PACKAGES
    source '$FETCH_DEBS'
    collect_declared_bsp_pkgs '$V2/manifests/families/rk3588.yaml'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"linux-image-vendor-rk35xx"* ]]
  [[ "$output" == *"linux-dtb-vendor-rk35xx"* ]]
}

@test "orchestrate: an edge DRY_RUN reaches the plan for BOTH rk3588 boards" {
  serialize build-plan
  local board
  for board in rock-5b-plus orange-pi-5-plus; do
    run env INSTALL_BOOT_BSP=0 DRY_RUN=1 bash "$V2/build" "$board" --variant edge
    [ "$status" -eq 0 ]
    [[ "$output" == *"kernel_variant=edge"* ]]
    [[ "$output" == *"DRY-RUN complete: board='${board}'"* ]]
    # The Armbian BSP set no longer contains the kernel or the DTB package …
    [[ "$output" != *"BSP set from rk3588.yaml (4 pkgs)"* ]]
    [[ "$output" == *"BSP set from rk3588.yaml (2 pkgs)"* ]]
    # … but U-Boot and firmware are still fetched.
    [[ "$output" == *"armbian-firmware"* ]]
    [[ "$output" == *"linux-u-boot-"* ]]
    # The kernel-build stage ran and emitted its plan.
    [[ "$output" == *"[2b/9] building kernel from pinned source"* ]]
    [[ "$output" == *"kernel-build plan emitted"* ]]
  done
}

@test "orchestrate: NON-VACUOUS — the vendor DRY_RUN still fetches kernel + DTB" {
  serialize build-plan
  run env INSTALL_BOOT_BSP=0 DRY_RUN=1 bash "$V2/build" rock-5b-plus
  [ "$status" -eq 0 ]
  [[ "$output" == *"BSP set from rk3588.yaml (4 pkgs)"* ]]
  [[ "$output" == *"linux-image-vendor-rk35xx"* ]]
  [[ "$output" == *"linux-dtb-vendor-rk35xx"* ]]
  # And the kernel-build stage never runs on the production path.
  [[ "$output" != *"[2b/9]"* ]]
  [[ "$output" != *"kernel from source"* ]]
}

@test "orchestrate: x86 DRY_RUN is unaffected by the variant machinery" {
  serialize build-plan
  run env INSTALL_BOOT_BSP=0 DRY_RUN=1 bash "$V2/build" x86-minipc
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN complete"* ]]
  [[ "$output" == *"kernel_variant=default"* ]]
  [[ "$output" != *"[2b/9]"* ]]
  [[ "$output" != *"kernel from source"* ]]
  [[ "$output" == *"non-Armbian family: BSP fetch omitted from DRY_RUN plan"* ]]
}

@test "orchestrate: a fetched AND built candidate for one name FAILS the build" {
  # The uniqueness check is the backstop for suppression. Two candidates for one
  # name would let mkosi's local repository pick a kernel nobody chose — a
  # plausible-looking image instead of an error, the worst outcome available.
  local fetched="$BATS_TEST_TMPDIR/uniq/debs" built="$BATS_TEST_TMPDIR/uniq/kernel"
  mkdir -p "$fetched" "$built"
  make_stub_deb "$fetched/linux-image-collide_1_arm64.deb" linux-image-collide 1 arm64
  make_stub_deb "$built/linux-image-collide_2_arm64.deb"   linux-image-collide 2 arm64

  run bash -c "
    set -euo pipefail
    ORCH='$LIB_DIR/orchestrate.sh'
    # Lift the orchestrator's function bodies without running main().
    eval \"\$(sed -n '/^deb_pkg_name()/,/^}/p;/^assert_staged_packages_unique()/,/^}/p' \"\$ORCH\")\"
    log_error() { printf 'ERROR %s\n' \"\$*\" >&2; }
    log_success() { printf 'OK %s\n' \"\$*\" >&2; }
    die() { printf 'DIE %s\n' \"\$*\" >&2; exit 1; }
    assert_staged_packages_unique '$fetched' '$built' 2>&1
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"linux-image-collide"* ]]
  [[ "$output" == *"DIE"* ]]
}

@test "orchestrate: distinct fetched and built package names PASS the uniqueness check" {
  local fetched="$BATS_TEST_TMPDIR/uniq2/debs" built="$BATS_TEST_TMPDIR/uniq2/kernel"
  mkdir -p "$fetched" "$built"
  make_stub_deb "$fetched/armbian-firmware_1_all.deb" armbian-firmware 1 all
  make_stub_deb "$built/linux-image-built_2_arm64.deb" linux-image-built 2 arm64

  run bash -c "
    set -euo pipefail
    ORCH='$LIB_DIR/orchestrate.sh'
    eval \"\$(sed -n '/^deb_pkg_name()/,/^}/p;/^assert_staged_packages_unique()/,/^}/p' \"\$ORCH\")\"
    log_error() { printf 'ERROR %s\n' \"\$*\" >&2; }
    log_success() { printf 'OK %s\n' \"\$*\" >&2; }
    die() { printf 'DIE %s\n' \"\$*\" >&2; exit 1; }
    assert_staged_packages_unique '$fetched' '$built' 2>&1
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"uniqueness verified"* ]]
}

@test "build-kernel: a non-40-hex patches pin is refused before anything runs" {
  run env DRY_RUN=1 \
    ARCH=arm64 DTB_NAME=rk3588-rock-5b-plus.dtb \
    KERNEL_PACKAGES=linux-image-7.1.5-ceralive-rk3588 \
    KERNEL_SOURCE_GIT_URL=https://example.invalid/linux.git \
    KERNEL_SOURCE_TAG=v7.1.5 \
    KERNEL_SOURCE_COMMIT=155b42bec9cbb6b8cdc47dd9bd09503a81fbe493 \
    KERNEL_SOURCE_PATCHES_GIT_URL=https://example.invalid/patches.git \
    KERNEL_SOURCE_PATCHES_COMMIT=main \
    KERNEL_SOURCE_PATCHES_SERIES=patches/series \
    KERNEL_SOURCE_DEFCONFIG_BASE=defconfig \
    KERNEL_SOURCE_DEFCONFIG_FRAGMENT=manifests/kernel/rk3588-edge.fragment \
    KERNEL_SOURCE_BUILDER_IMAGE='debian:trixie-slim@sha256:28de0877c2189802884ccd20f15ee41c203573bd87bb6b883f5f46362d24c5c2' \
    KERNEL_SOURCE_LOCAL_VERSION=-ceralive-rk3588 \
    KERNEL_SOURCE_KERNEL_RELEASE=7.1.5-ceralive-rk3588 \
    KERNEL_SOURCE_PACKAGE_VERSION=7.1.5-ceralive1 \
    KERNEL_SOURCE_DTB_DEB_DIR=/usr/lib/linux-image-7.1.5-ceralive-rk3588/rockchip \
    bash "$LIB_DIR/build-kernel.sh" --board rock-5b-plus --out "$BATS_TEST_TMPDIR/ko"
  [ "$status" -ne 0 ]
  [[ "$output" == *"patches_commit"* ]]
  [[ "$output" == *"never a branch"* ]]
}

@test "build-kernel: a half-specified pin is refused (no partial kernel build)" {
  run env DRY_RUN=1 ARCH=arm64 DTB_NAME=x.dtb KERNEL_PACKAGES=linux-image-x \
    KERNEL_SOURCE_GIT_URL=https://example.invalid/linux.git \
    bash "$LIB_DIR/build-kernel.sh" --board rock-5b-plus --out "$BATS_TEST_TMPDIR/ko2"
  [ "$status" -ne 0 ]
  [[ "$output" == *"half-specified pin"* ]]
}

@test "build-kernel: the DRY_RUN plan names every pinned coordinate" {
  serialize build-plan
  run env INSTALL_BOOT_BSP=0 DRY_RUN=1 bash "$V2/build" rock-5b-plus --variant edge
  [ "$status" -eq 0 ]
  [[ "$output" == *"git clone --branch v7.1.5"* ]]
  [[ "$output" == *"git rev-parse HEAD == 155b42bec9cbb6b8cdc47dd9bd09503a81fbe493"* ]]
  [[ "$output" == *"9c1cb385098d842a1d5755e3717b308a25bb8305"* ]]
  [[ "$output" == *"BASE_IMAGE=debian:trixie-20260623-slim@sha256:"* ]]
  [[ "$output" == *"bindeb-pkg"* ]]
  [[ "$output" == *"linux-headers-*/linux-libc-dev discarded"* ]]
  # The plan must not perform anything.
  [[ "$output" != *"docker run"* ]]
}

@test "build-kernel: ccache is wired (a rebuild must not be a cold kernel build)" {
  grep -q 'CCACHE_DIR' "$V2/ci/Dockerfile.kernel"
  grep -q '/usr/lib/ccache/aarch64-linux-gnu-gcc' "$V2/ci/Dockerfile.kernel"
  grep -q -- '-v "${ccache_dir}:/ccache"' "$LIB_DIR/build-kernel.sh"
}

@test "build-kernel: syncconfig refreshes auto.conf between olddefconfig and the kernelrelease assertion" {
  # `make kernelrelease` is in the kernel no-sync-config-targets list, so it skips
  # syncconfig and reads include/config/auto.conf as written by `make defconfig` —
  # still CONFIG_LOCALVERSION_AUTO=y. setlocalversion reads auto.conf, NOT .config,
  # so without an explicit syncconfig the fragment override never takes effect and
  # the assertion below rejects a git-describe-suffixed release on EVERY build, on
  # every board. Only a real (non-DRY_RUN) build executes that container script, so
  # this ordering is asserted statically.
  local script="$LIB_DIR/build-kernel.sh"
  local olddefconfig syncconfig release_assert

  olddefconfig="$(grep -n '^ *make olddefconfig$' "$script" | cut -d: -f1)"
  syncconfig="$(grep -n '^ *make syncconfig$' "$script" | cut -d: -f1)"
  release_assert="$(grep -n 'make -s kernelrelease' "$script" | cut -d: -f1)"

  [ "$(printf '%s\n' "$olddefconfig" | wc -l)" -eq 1 ]
  [ "$(printf '%s\n' "$syncconfig" | wc -l)" -eq 1 ]
  [ "$(printf '%s\n' "$release_assert" | wc -l)" -eq 1 ]

  (( olddefconfig < syncconfig )) \
    || { echo "make syncconfig must come AFTER make olddefconfig"; false; }
  (( syncconfig < release_assert )) \
    || { echo "make syncconfig must come BEFORE the kernelrelease assertion"; false; }
}

@test "build-kernel: the kernelrelease assertion stays an EXACT match (never relaxed to a prefix)" {
  # The assertion is the only thing between this pipeline and a non-deterministic
  # kernel package name: `git am` restamps committer dates, so an AUTO release
  # string embeds a different SHA on every run. Relaxing it is not a valid fix for
  # a stale auto.conf.
  local script="$LIB_DIR/build-kernel.sh"
  grep -Fq 'if [ "${release}" != "${KERNEL_RELEASE}" ]; then' "$script"
  run grep -Eq '\$\{release#|\$\{release\*|release. == .\$\{KERNEL_RELEASE\}\*' "$script"
  [ "$status" -ne 0 ]
}

@test "build-kernel: deb_lists_path finds a present path in a LARGE deb (no pipefail/SIGPIPE false negative)" {
  # Regression: `tar -t | grep -Fqx` under `set -o pipefail` reports FAILURE when
  # the path IS present — grep exits at the first match and tar dies of SIGPIPE.
  # It only misfires once the listing outgrows the pipe buffer, so a tiny fixture
  # passes and a real kernel deb (thousands of DTBs and modules) never does.
  local script="$LIB_DIR/build-kernel.sh"
  local deb="$BATS_TEST_TMPDIR/big.deb" stage="$BATS_TEST_TMPDIR/stage"
  local want='/usr/lib/linux-image-x/rockchip/rk3588-rock-5b-plus.dtb'

  mkdir -p "$stage/usr/lib/linux-image-x/rockchip"
  printf 'dtb\n' >"$stage$want"
  local i
  for i in $(seq 1 6000); do printf 'm\n' >"$stage/usr/lib/linux-image-x/rockchip/pad-$i.dtb"; done
  tar -C "$stage" -czf "$BATS_TEST_TMPDIR/data.tar.gz" .
  printf '2.0\n' >"$BATS_TEST_TMPDIR/debian-binary"
  mkdir -p "$BATS_TEST_TMPDIR/ctl"
  printf 'Package: linux-image-x\nVersion: 1\nArchitecture: arm64\n' >"$BATS_TEST_TMPDIR/ctl/control"
  tar -C "$BATS_TEST_TMPDIR/ctl" -czf "$BATS_TEST_TMPDIR/control.tar.gz" ./control
  ( cd "$BATS_TEST_TMPDIR" && ar rc "$deb" debian-binary control.tar.gz data.tar.gz )

  run bash -c "
    set -euo pipefail
    $(sed -n '/^deb_data_list()/,/^}/p;/^deb_lists_path()/,/^}/p' "$script")
    deb_lists_path '$deb' '$want' && echo PRESENT
    deb_lists_path '$deb' '/usr/lib/linux-image-x/rockchip/absent.dtb' && echo BUG-FALSE-POSITIVE
    echo DONE
  "
  [[ "$output" == *"PRESENT"* ]]
  [[ "$output" != *"BUG-FALSE-POSITIVE"* ]]
}

@test "build-kernel: the builder image satisfies the CROSS build-deps dpkg-checkbuilddeps demands" {
  # bindeb-pkg runs dpkg-buildpackage -a arm64, so the kernel Build-Depends-Arch
  # resolves `libssl-dev:native` against amd64 and a bare `libssl-dev` against the
  # arm64 HOST arch. Installing only the amd64 one aborts the package build at
  # dpkg-checkbuilddeps, before any compilation — invisible to a DRY_RUN gate.
  local df="$V2/ci/Dockerfile.kernel"
  grep -Eq '^RUN dpkg --add-architecture arm64' "$df"
  grep -Eq '^ +libssl-dev \\$' "$df"
  grep -Eq '^ +libssl-dev:arm64 \\$' "$df"
  grep -Eq '^ +libdw-dev \\$' "$df"
  grep -Eq '^ +libelf-dev \\$' "$df"
  # install-extmod-build rebuilds the headers package host tools with the CROSS
  # gcc, which resolves libc only via /usr/include/aarch64-linux-gnu.
  grep -Eq '^ +libc6-dev:arm64 \\$' "$df"
}

@test "build-kernel: the builder image tag is content-addressed (an edited Dockerfile invalidates it)" {
  # ensure_kernel_builder_image skips `docker build` when the tag already exists,
  # so a constant tag would pin every host to whatever layers it first built.
  local script="$LIB_DIR/build-kernel.sh"
  local base='debian:trixie-20260623-slim@sha256:28de0877c2189802884ccd20f15ee41c203573bd87bb6b883f5f46362d24c5c2'
  local tag_a tag_b tag_edited edited

  tag_a="$(bash -c "KERNEL_BUILDER_DOCKERFILE='$V2/ci/Dockerfile.kernel'; \
    $(sed -n '/^resolve_kernel_builder_tag()/,/^}/p' "$script"); \
    resolve_kernel_builder_tag '$base'")"
  [[ "$tag_a" == ceralive-kernel-builder:* ]]

  tag_b="$(bash -c "KERNEL_BUILDER_DOCKERFILE='$V2/ci/Dockerfile.kernel'; \
    $(sed -n '/^resolve_kernel_builder_tag()/,/^}/p' "$script"); \
    resolve_kernel_builder_tag '$base'")"
  [ "$tag_a" = "$tag_b" ]

  # A different builder_image pin must yield a different tag.
  tag_b="$(bash -c "KERNEL_BUILDER_DOCKERFILE='$V2/ci/Dockerfile.kernel'; \
    $(sed -n '/^resolve_kernel_builder_tag()/,/^}/p' "$script"); \
    resolve_kernel_builder_tag 'debian:trixie-slim@sha256:0000000000000000000000000000000000000000000000000000000000000000'")"
  [ "$tag_a" != "$tag_b" ]

  # An edited Dockerfile must yield a different tag.
  edited="$BATS_TEST_TMPDIR/Dockerfile.kernel"
  { cat "$V2/ci/Dockerfile.kernel"; echo '# drift'; } >"$edited"
  tag_edited="$(bash -c "KERNEL_BUILDER_DOCKERFILE='$edited'; \
    $(sed -n '/^resolve_kernel_builder_tag()/,/^}/p' "$script"); \
    resolve_kernel_builder_tag '$base'")"
  [ "$tag_a" != "$tag_edited" ]

  # An operator override is still used verbatim.
  tag_b="$(bash -c "KERNEL_BUILDER_DOCKERFILE='$V2/ci/Dockerfile.kernel'; \
    CERALIVE_KERNEL_BUILDER_IMAGE=myregistry/kbuilder:9; \
    $(sed -n '/^resolve_kernel_builder_tag()/,/^}/p' "$script"); \
    resolve_kernel_builder_tag '$base'")"
  [ "$tag_b" = "myregistry/kbuilder:9" ]
}

@test "build-kernel: the builder base image is the MANIFEST pin, not a Dockerfile default" {
  # A FROM with a baked default would let the manifest's builder_image drift
  # into decoration. ARG BASE_IMAGE with no default makes the manifest load-bearing.
  grep -Eq '^ARG BASE_IMAGE$' "$V2/ci/Dockerfile.kernel"
  grep -Eq '^FROM \$\{BASE_IMAGE\}$' "$V2/ci/Dockerfile.kernel"
  run grep -Eq '^ARG BASE_IMAGE=' "$V2/ci/Dockerfile.kernel"
  [ "$status" -ne 0 ]
}

@test "platform DTB mapping: no-op with an empty mapping, fail-loud when half-specified" {
  local postinst="$V2/mkosi/mkosi.images/platform/mkosi.postinst"
  local fn
  fn="$(sed -n '/^install_kernel_source_dtbs()/,/^}/p' "$postinst")"
  [ -n "$fn" ]

  # Empty mapping (the production vendor path) -> clean no-op.
  run bash -c "
    set -euo pipefail
    log() { printf '[platform] %s\n' \"\$*\" >&2; }
    BUILDROOT='$BATS_TEST_TMPDIR/pr'; mkdir -p \"\$BUILDROOT\"
    KERNEL_SOURCE_DTB_DEB_DIR='' KERNEL_SOURCE_DTB_BOOT_DIR=''
    $fn
    install_kernel_source_dtbs
    echo NOOP-OK
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOOP-OK"* ]]

  # Half-specified -> fatal (a silent skip here ships a DTB-less image).
  run bash -c "
    set -euo pipefail
    log() { printf '[platform] %s\n' \"\$*\" >&2; }
    BUILDROOT='$BATS_TEST_TMPDIR/pr2'; mkdir -p \"\$BUILDROOT\"
    KERNEL_SOURCE_DTB_DEB_DIR='/usr/lib/linux-image-x/rockchip' KERNEL_SOURCE_DTB_BOOT_DIR=''
    $fn
    install_kernel_source_dtbs
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"half-specified"* ]]
}

@test "platform DTB mapping: copies the board DTB where the boot script looks" {
  local postinst="$V2/mkosi/mkosi.images/platform/mkosi.postinst"
  local fn
  fn="$(sed -n '/^install_kernel_source_dtbs()/,/^}/p' "$postinst")"
  local root="$BATS_TEST_TMPDIR/dtbroot"
  mkdir -p "$root/usr/lib/linux-image-7.1.5-ceralive-rk3588/rockchip"
  printf 'dtb\n' > "$root/usr/lib/linux-image-7.1.5-ceralive-rk3588/rockchip/rk3588-rock-5b-plus.dtb"

  run bash -c "
    set -euo pipefail
    log() { printf '[platform] %s\n' \"\$*\" >&2; }
    BUILDROOT='$root'
    KERNEL_SOURCE_DTB_DEB_DIR='/usr/lib/linux-image-7.1.5-ceralive-rk3588/rockchip'
    KERNEL_SOURCE_DTB_BOOT_DIR='/boot/dtb/rockchip'
    DTB_NAME='rk3588-rock-5b-plus.dtb'
    $fn
    install_kernel_source_dtbs
  "
  [ "$status" -eq 0 ]
  # /boot/dtb/rockchip/\${fdtfile} is exactly what boot.scr.cmd resolves.
  [ -f "$root/boot/dtb/rockchip/rk3588-rock-5b-plus.dtb" ]

  # And it is fail-loud when the board's own DTB is missing from the package —
  # mainline and the Armbian vendor BSP do not always agree on RK3588 DTB names.
  run bash -c "
    set -euo pipefail
    log() { printf '[platform] %s\n' \"\$*\" >&2; }
    BUILDROOT='$root'
    KERNEL_SOURCE_DTB_DEB_DIR='/usr/lib/linux-image-7.1.5-ceralive-rk3588/rockchip'
    KERNEL_SOURCE_DTB_BOOT_DIR='/boot/dtb/rockchip'
    DTB_NAME='rk3588s-orangepi-5b.dtb'
    $fn
    install_kernel_source_dtbs
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"rk3588s-orangepi-5b.dtb"* ]]
}

@test "build: --variant is refused for a multi-board selection" {
  run bash "$V2/build" --only rock-5b-plus,x86-minipc --variant edge
  [ "$status" -ne 0 ]
  [[ "$output" == *"single-board only"* ]]
}

@test "build: --variant with no value is refused" {
  run bash "$V2/build" rock-5b-plus --variant
  [ "$status" -ne 0 ]
  [[ "$output" == *"--variant requires a name"* ]]
}

# ===========================================================================
# 27. First-party staging key — producer/consumer agreement across the subimage
#     boundary.
#
#     The orchestrator stages the 14 first-party .debs under the board MANIFEST
#     STEM; the app subimage rebuilds that path from inside its own chroot,
#     because mkosi's --extra-tree never reaches a subimage and the source-mount
#     fallback is the ONLY live delivery route. Keying the consumer off BOARD_ID
#     (the Armbian BOARD= value) made those two agree on rock-5b-plus alone —
#     the one board built regularly — so orange-pi-5-plus installed ZERO
#     first-party packages for a whole release. These tests therefore drive the
#     REAL shipped stager against the REAL shipped manifests, and every leg is
#     paired with a non-vacuity leg, because an identity mapping is exactly what
#     hid the defect.
# ===========================================================================

# run_source_mount_stager <srcdir> <ceralive_board> <board_id> <dest>
# Source the SHIPPED app postinst (its BASH_SOURCE guard leaves main() unrun, so
# the destructive prune/clean steps never fire) and call the real function.
run_source_mount_stager() {
  local srcdir="$1" ceralive_board="$2" board_id="$3" dest="$4"
  run bash -c "
    set -euo pipefail
    SRCDIR='$srcdir'
    CERALIVE_BOARD='$ceralive_board'
    BOARD_ID='$board_id'
    export SRCDIR CERALIVE_BOARD BOARD_ID
    source '$V2/mkosi/mkosi.images/app/mkosi.postinst.chroot'
    FIRST_PARTY_DIR='$dest'
    stage_first_party_from_source_mount
  "
}

@test "firstparty-staging: the REAL stager finds the tree for EVERY shipped board manifest" {
  # The producer/consumer contract, exercised end to end per board: lay the tree
  # out exactly as orchestrate.sh does (STAGING_ROOT/<manifest-stem>/firstparty)
  # and hand the stager that board's REAL board_id at the same time, which is
  # what the broken code read. orange-pi-5-plus is the leg that fails on the
  # pre-fix consumer.
  local manifest board board_id divergent=0
  for manifest in "$V2"/manifests/boards/*.yaml; do
    board="$(basename "$manifest" .yaml)"
    board_id="$(sed -n 's/^board_id:[[:space:]]*//p' "$manifest" | head -1)"
    [ -n "$board_id" ]
    [ "$board" = "$board_id" ] || divergent=1

    local srcdir="$BATS_TEST_TMPDIR/src-$board"
    local dest="$BATS_TEST_TMPDIR/dest-$board"
    mkdir -p "$srcdir/.staging/$board/firstparty" "$dest"
    make_stub_deb "$srcdir/.staging/$board/firstparty/cerastream_1_arm64.deb" \
      cerastream 1 arm64

    run_source_mount_stager "$srcdir" "$board" "$board_id" "$dest"
    [ "$status" -eq 0 ]
    [ -f "$dest/cerastream_1_arm64.deb" ] \
      || { echo "stager did not deliver for board=$board board_id=$board_id"; false; }
  done

  # NON-VACUITY: at least one shipped board must have stem != board_id, or the
  # whole matrix above is an identity test that passes on the broken consumer.
  [ "$divergent" -eq 1 ]
}

@test "firstparty-staging: a tree staged under BOARD_ID is NOT picked up (the actual defect)" {
  # The inverse of the test above, and the one that would have caught this the
  # day it shipped: with the tree at .staging/<board_id>/ and nothing at
  # .staging/<manifest-stem>/, the stager must deliver NOTHING — proving it
  # follows the orchestrator's key and not the Armbian device identity.
  local board=orange-pi-5-plus
  local board_id
  board_id="$(sed -n 's/^board_id:[[:space:]]*//p' "$V2/manifests/boards/$board.yaml" | head -1)"
  [ "$board_id" = orangepi5-plus ]
  [ "$board_id" != "$board" ]

  local srcdir="$BATS_TEST_TMPDIR/src" dest="$BATS_TEST_TMPDIR/dest"
  mkdir -p "$srcdir/.staging/$board_id/firstparty" "$dest"
  make_stub_deb "$srcdir/.staging/$board_id/firstparty/cerastream_1_arm64.deb" \
    cerastream 1 arm64

  run_source_mount_stager "$srcdir" "$board" "$board_id" "$dest"
  [ "$status" -eq 0 ]
  run bash -c "ls '$dest'/*.deb 2>/dev/null"
  [ "$status" -ne 0 ]
}

@test "firstparty-staging: a miss NAMES the probed path instead of returning silently" {
  # The silent `return 0` is why a zero-package image built to completion. An
  # offline/dev build legitimately stages nothing, so this stays non-fatal — but
  # the log line must carry the exact path, which is the entire diagnosis.
  local srcdir="$BATS_TEST_TMPDIR/src" dest="$BATS_TEST_TMPDIR/dest"
  mkdir -p "$srcdir" "$dest"

  run_source_mount_stager "$srcdir" rock-5b-plus rock-5b-plus "$dest"
  [ "$status" -eq 0 ]
  [[ "$output" == *".staging/rock-5b-plus/firstparty"* ]]

  # An unset CERALIVE_BOARD is the PassEnvironment-drift failure mode; it must
  # say so rather than look like an ordinary offline build.
  run_source_mount_stager "$srcdir" "" rock-5b-plus "$dest"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CERALIVE_BOARD"* ]]
}

@test "firstparty-staging: the ExtraTree still wins when it did reach the subimage" {
  # The fallback must stay a fallback: if /opt/ceralive-staging is already
  # populated, the source mount is not consulted at all.
  local srcdir="$BATS_TEST_TMPDIR/src" dest="$BATS_TEST_TMPDIR/dest"
  mkdir -p "$srcdir/.staging/rock-5b-plus/firstparty" "$dest"
  make_stub_deb "$srcdir/.staging/rock-5b-plus/firstparty/from-source_1_arm64.deb" \
    from-source 1 arm64
  make_stub_deb "$dest/from-extratree_1_arm64.deb" from-extratree 1 arm64

  run_source_mount_stager "$srcdir" rock-5b-plus rock-5b-plus "$dest"
  [ "$status" -eq 0 ]
  [ -f "$dest/from-extratree_1_arm64.deb" ]
  [ ! -f "$dest/from-source_1_arm64.deb" ]
}

@test "firstparty-staging: orchestrate.sh exports the SAME key it stages under" {
  # Cross-file agreement, statically. The producer's staging path and the
  # exported key must be the same shell variable, or the two halves drift again.
  local orchestrate="$LIB_DIR/orchestrate.sh"
  grep -Fq 'local staging="${STAGING_ROOT}/${board}"' "$orchestrate"
  grep -Fq 'export CERALIVE_BOARD="${board}"' "$orchestrate"

  # And the per-board mkosi cache stays keyed by BOARD_ID — a DIFFERENT tree for
  # a different purpose, deliberately not aliased onto the staging key.
  grep -Fq 'local cache_dir="cache/${BOARD_ID}"' "$orchestrate"
}

@test "firstparty-staging: the consumer never re-slips to BOARD_ID" {
  # Explicit re-slip guard (same discipline as the hdmi-in DRIVERS== rule): the
  # source-mount path expression must not mention BOARD_ID at all.
  local postinst="$V2/mkosi/mkosi.images/app/mkosi.postinst.chroot"
  local fn
  fn="$(sed -n '/^stage_first_party_from_source_mount()/,/^}/p' "$postinst")"
  [ -n "$fn" ]
  [[ "$fn" == *'.staging/${board}/firstparty'* ]]
  [[ "$fn" != *'${BOARD_ID}'* ]]
}

@test "firstparty-staging: CERALIVE_BOARD reaches the app SUBIMAGE (env_names + PassEnvironment)" {
  # Explicit regression pin on top of the structural lockstep guard: this value
  # is consumed inside a subimage chroot, so a name in env_names alone reads
  # EMPTY there — silently — and the stager degrades to installing nothing.
  grep -Eq '^[[:space:]]+CERALIVE_BENCH_LABELS CERALIVE_BOARD$' "$LIB_DIR/orchestrate.sh"

  local pass_names
  pass_names="$(sed -n 's/^PassEnvironment=//p' "$V2/mkosi/mkosi.conf")"
  [ -n "$pass_names" ]

  local n found=0
  for n in $pass_names; do
    [ "$n" = CERALIVE_BOARD ] && found=1
  done
  [ "$found" -eq 1 ]
}

# ===========================================================================
# 28. Mesa software-GL prune — the RemoveFiles contract.
#
#     `gstreamer1.0-plugins-bad` reaches `libgl1-mesa-dri`, which reaches LLVM's
#     JIT and Z3 for Mesa's software rasterizer: 157.6 MB the device can never
#     execute, because the Mali vendor stubs win the EGL/GLES/GBM lookup and the
#     only other Mesa entry point needs an X server this image does not ship.
#     `apt remove` cascades into the plugin set cerastream needs, so the lever is
#     file-level, like the locale strip.
#
#     These are STATIC guards because the prune only happens on a wet build and
#     the PR gate is DRY_RUN=1 plan-only — the same blind spot that shipped the
#     OPi DTB name and the four kernel-from-source defects. The dri glob leg is
#     the one that matters most: libva resolves VA-API drivers as
#     `<name>_drv_video.so` out of the SAME directory, so widening the glob to
#     `dri/*` would silently delete a hardware video driver on a future x86 build.
# ===========================================================================

removefiles_runtime() {
  sed -n 's/^RemoveFiles=//p' "$V2/mkosi/mkosi.images/runtime/mkosi.conf"
}

@test "mesa-prune: the runtime layer strips libLLVM-15, libz3 and the Mesa DRI megadriver" {
  local entries
  entries="$(removefiles_runtime)"
  [ -n "$entries" ]

  [[ "$entries" == *'/usr/lib/aarch64-linux-gnu/libLLVM-15.so*'* ]]
  [[ "$entries" == *'/usr/lib/aarch64-linux-gnu/libz3.so*'* ]]
  [[ "$entries" == *'/usr/lib/aarch64-linux-gnu/dri/*_dri.so'* ]]
}

@test "mesa-prune: the DRI glob never widens to dri/* (it would eat VA-API drivers)" {
  local entries
  entries="$(removefiles_runtime)"
  # libva looks up <name>_drv_video.so in /usr/lib/<triplet>/dri; only the
  # `*_dri.so` suffix may be removed. Reject a bare directory glob outright.
  [[ "$entries" != *'/dri/*,'* ]]
  [[ "$entries" != *'/dri/*' ]]
  [[ "$entries" != *'/dri,'* ]]
}

@test "mesa-prune: the locale strip it shares the key with is not clobbered" {
  # RemoveFiles is ONE comma-separated key; appending to it is exactly how the
  # Task-19 locale entries could be lost without any test noticing.
  local entries
  entries="$(removefiles_runtime)"
  [[ "$entries" == *'/usr/share/locale/*'* ]]
  [[ "$entries" == *'/usr/lib/locale/locale-archive'* ]]

  # And every OTHER layer keeps its own locale strip untouched by this change.
  local layer
  for layer in base platform app; do
    grep -Fq 'RemoveFiles=/usr/share/locale/*,/usr/lib/locale/locale-archive' \
      "$V2/mkosi/mkosi.images/$layer/mkosi.conf"
  done
}

@test "mesa-prune: the pruned packages are NOT removed from shared.list or apt" {
  # The whole point of the file-level lever is that the metapackage STAYS
  # installed — `apt remove libgl1-mesa-dri` cascades into gstreamer1.0-plugins-bad,
  # which cerastream needs. Nothing may start uninstalling it.
  local shared="$V2/manifests/packages/shared.list"
  grep -Eq '^gstreamer1\.0-plugins-bad$' "$shared"

  local postinst="$V2/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"
  ! grep -Eq 'apt-get[[:space:]]+(-y[[:space:]]+)?(remove|purge)[^|;&]*libgl1-mesa-dri' "$postinst"
  ! grep -Eq 'apt-get[[:space:]]+(-y[[:space:]]+)?(remove|purge)[^|;&]*(libllvm15|libz3-4)' "$postinst"
}

# ===========================================================================
# 29. Fan kick-start — setup_fan_curve fixed WHEN the pwm-fan is asked to spin;
#     this covers the fact that the state it is asked INTO is too weak to start
#     it from a dead stop. Measured on a live Orange Pi 5 Plus, the first active
#     state is 70/255 (~27.5% duty): enough to sustain a turning rotor, not
#     enough to break stiction on a stopped one, so the fan sits energised and
#     stalled until someone nudges it by hand.
#
#     ceralive-fan-kickstart.service watches the pwm-fan cooling device's own
#     cur_state for a 0 -> nonzero transition and, on that edge only, drives it
#     to max_state for a bounded window before writing the governor's own
#     commanded state straight back.
#
#     THE RESTORE IS THE LOAD-BEARING PART AND THESE TESTS PIN IT. On this
#     kernel a userspace cur_state write is STICKY, not self-correcting:
#     cur_state_store never clears cdev->updated, thermal_cdev_update()
#     short-circuits while that flag is set, and step_wise clears it only when
#     its computed target CHANGES. "Write max_state and let the governor's next
#     poll fix it" would therefore leave the fan at full speed for as long as
#     the temperature stayed inside one trip band.
#
#     Unlike every other unit in this family this one is RESIDENT, not a boot
#     oneshot, because the fan returns to state 0 and re-enters an active state
#     many times over a device's uptime and every re-entry is a fresh dead start.
#
#     The reference board is cooling_device4 with max_state 4 and cooling-levels
#     `0 70 75 80 100`. The fixture below deliberately uses cooling_device6 with
#     max_state 6 behind a decoy CPUFreq cooling_device2, so any hardcoded index
#     and any hand-invented "100%" kick value fails these tests. No image boot,
#     no hardware, UNIT scope.
# ===========================================================================

FANKICK_SCRIPT() { printf '%s' "$V2/mkosi/runtime/ceralive-fan-kickstart.sh"; }
FANKICK_UNIT() { printf '%s' "$V2/mkosi/runtime/ceralive-fan-kickstart.service"; }

# fankick_fake_thermal <dir> [max_state] [cur_state] — a synthetic
# /sys/class/thermal whose pwm-fan sits at a NON-reference index behind a decoy
# CPUFreq cooling device that must never be written.
fankick_fake_thermal() {
  local root="$1" max_state="${2:-6}" cur_state="${3:-0}"
  rm -rf "$root"
  mkdir -p "$root/cooling_device2" "$root/cooling_device6"

  printf 'thermal-cpufreq-0\n' >"$root/cooling_device2/type"
  printf '0\n' >"$root/cooling_device2/cur_state"
  printf '5\n' >"$root/cooling_device2/max_state"

  printf 'pwm-fan\n' >"$root/cooling_device6/type"
  printf '%s\n' "$cur_state" >"$root/cooling_device6/cur_state"
  printf '%s\n' "$max_state" >"$root/cooling_device6/max_state"
}

fankick_attr() { tr -d '[:space:]' <"$1"; }

# fankick_run <sysfs> <kick_ms> <cycles> [extra env...] — drive the resident
# monitor for a bounded number of poll ticks. CERALIVE_FAN_KICK_MAX_CYCLES is
# the test seam that makes an ongoing monitor testable at all; production runs
# unbounded.
fankick_run() {
  local sysfs="$1" kick_ms="$2" cycles="$3"; shift 3
  env CERALIVE_FAN_KICK_THERMAL_DIR="$sysfs" \
      CERALIVE_FAN_KICK_MS="$kick_ms" \
      CERALIVE_FAN_KICK_POLL=0.1 \
      CERALIVE_FAN_KICK_MAX_CYCLES="$cycles" \
      "$@" bash "$(FANKICK_SCRIPT)"
}

@test "fan kickstart: the monitor script + unit are installed and enabled" {
  local unit_dir="$BATS_TEST_TMPDIR/fk-units"
  local sbin_dir="$BATS_TEST_TMPDIR/fk-sbin"
  local bin="$BATS_TEST_TMPDIR/fk-bin"
  local calls="$BATS_TEST_TMPDIR/fk-calls"
  mkdir -p "$bin"
  cat >"$bin/systemctl" <<'SH'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$FK_CALLS"
exit 0
SH
  chmod +x "$bin/systemctl"

  run env PATH="$bin:$PATH" FK_CALLS="$calls" \
    CERALIVE_RUNTIME_SRC="$V2/mkosi/runtime" \
    FAN_KICKSTART_UNIT_DIR="$unit_dir" FAN_KICKSTART_SBIN_DIR="$sbin_dir" \
    bash -c "source '$POSTINST_LIB'; setup_fan_kickstart"
  [ "$status" -eq 0 ]
  [ -x "$sbin_dir/ceralive-fan-kickstart" ]
  [ -f "$unit_dir/ceralive-fan-kickstart.service" ]

  run cat "$calls"
  [ "$status" -eq 0 ]
  [[ "$output" == *"enable ceralive-fan-kickstart.service"* ]]
}

@test "fan kickstart: a genuine 0 -> nonzero edge kicks to the REAL max_state, then restores" {
  # The reference board's max_state is 4; this fixture's is 6. A kick value that
  # is a hand-invented "100%", a hardcoded 4, or anything but this device's own
  # max_state fails here.
  local sysfs="$BATS_TEST_TMPDIR/fk-edge"
  local timeline="$BATS_TEST_TMPDIR/fk-edge-timeline"
  fankick_fake_thermal "$sysfs" 6 0

  # Governor moves it 0 -> 1 shortly after the monitor primes.
  ( sleep 0.35; printf '1\n' >"$sysfs/cooling_device6/cur_state" ) &
  # Sample cur_state independently so the kick is observed, not inferred.
  ( for _ in $(seq 1 24); do
      fankick_attr "$sysfs/cooling_device6/cur_state" >>"$timeline"
      printf '\n' >>"$timeline"
      sleep 0.1
    done ) &
  local sampler=$!

  run fankick_run "$sysfs" 800 16
  [ "$status" -eq 0 ]
  wait "$sampler"

  [[ "$output" == *"nudging to state 6"* ]]
  [[ "$output" == *"max_state"* ]]
  # It kicked: max_state was actually observed on the device mid-run.
  grep -qx '6' "$timeline"
  # It restored: the governor's own commanded state is what is left behind.
  [[ "$output" == *"state 1 handed back"* ]]
  [ "$(fankick_attr "$sysfs/cooling_device6/cur_state")" = "1" ]
  # The decoy CPUFreq cooling device was never touched.
  [ "$(fankick_attr "$sysfs/cooling_device2/cur_state")" = "0" ]
}

@test "fan kickstart: the kick is BOUNDED — it ends on its own timer, not on a governor decision" {
  # The whole safety argument. A kick that outlived its window would sit at full
  # PWM until the temperature left the trip band, because a userspace cur_state
  # write is sticky against this kernel's governor.
  local sysfs="$BATS_TEST_TMPDIR/fk-bounded"
  local timeline="$BATS_TEST_TMPDIR/fk-bounded-timeline"
  fankick_fake_thermal "$sysfs" 6 0

  ( sleep 0.35; printf '2\n' >"$sysfs/cooling_device6/cur_state" ) &
  ( for _ in $(seq 1 30); do
      fankick_attr "$sysfs/cooling_device6/cur_state" >>"$timeline"
      printf '\n' >>"$timeline"
      sleep 0.1
    done ) &
  local sampler=$!

  run fankick_run "$sysfs" 500 20
  [ "$status" -eq 0 ]
  wait "$sampler"

  # Nothing external ever moved it off max_state, so if it is not at max_state
  # by the end, the monitor's own bounded window is what ended the kick.
  [ "$(fankick_attr "$sysfs/cooling_device6/cur_state")" = "2" ]
  # And the full-PWM period really was a period, not the whole run.
  local at_max total
  at_max="$(grep -cx '6' "$timeline" || true)"
  total="$(grep -cx '[0-9]*' "$timeline" || true)"
  [ "$at_max" -ge 1 ]
  [ "$at_max" -lt "$total" ]

  # Structurally: exactly ONE sleep spans the kick, and its length comes from a
  # validated, band-clamped constant rather than a literal.
  run bash -c "grep -vE '^[[:space:]]*#' '$(FANKICK_SCRIPT)' | grep -cE '^[[:space:]]*sleep \"\\\$\{KICK_SECONDS\}\"'"
  [ "$output" -eq 1 ]
  run fankick_run "$sysfs" 60000 4
  [ "$status" -ne 0 ]
  [[ "$output" == *"outside the accepted"* ]]
}

@test "fan kickstart: nonzero -> nonzero NEVER fires — no re-kick while the fan is already turning" {
  # The governor climbing 1 -> 3 under its own control must not be interrupted,
  # and a poll tick that simply re-observes an active fan must not re-kick.
  local sysfs="$BATS_TEST_TMPDIR/fk-nonzero"
  fankick_fake_thermal "$sysfs" 6 1

  ( sleep 0.35; printf '3\n' >"$sysfs/cooling_device6/cur_state" ) &
  run fankick_run "$sysfs" 300 12
  [ "$status" -eq 0 ]
  [[ "$output" != *"nudging"* ]]
  [ "$(fankick_attr "$sysfs/cooling_device6/cur_state")" = "3" ]
}

@test "fan kickstart: nonzero -> 0 NEVER fires — a fan being shut off is not a dead start" {
  local sysfs="$BATS_TEST_TMPDIR/fk-tozero"
  fankick_fake_thermal "$sysfs" 6 2

  ( sleep 0.35; printf '0\n' >"$sysfs/cooling_device6/cur_state" ) &
  run fankick_run "$sysfs" 300 12
  [ "$status" -eq 0 ]
  [[ "$output" != *"nudging"* ]]
  [ "$(fankick_attr "$sysfs/cooling_device6/cur_state")" = "0" ]
}

@test "fan kickstart: 0 -> max_state NEVER fires — the governor already commands full PWM" {
  # There is no room to kick above the target, so a write would be pointless.
  # Same skip condition upstream's in-driver version uses (it boosts only when
  # the target duty is BELOW the from-stopped duty).
  local sysfs="$BATS_TEST_TMPDIR/fk-atmax"
  fankick_fake_thermal "$sysfs" 6 0

  ( sleep 0.35; printf '6\n' >"$sysfs/cooling_device6/cur_state" ) &
  run fankick_run "$sysfs" 300 12
  [ "$status" -eq 0 ]
  [[ "$output" != *"nudging"* ]]
  [ "$(fankick_attr "$sysfs/cooling_device6/cur_state")" = "6" ]
}

@test "fan kickstart: priming means a monitor that STARTS on an already-spinning fan does not kick" {
  # Restart=on-failure and a mid-life restart must not produce a spurious nudge:
  # the previous state is seeded from the device, never assumed to be 0.
  local sysfs="$BATS_TEST_TMPDIR/fk-prime"
  fankick_fake_thermal "$sysfs" 6 2

  run fankick_run "$sysfs" 300 6
  [ "$status" -eq 0 ]
  [[ "$output" == *"currently state 2"* ]]
  [[ "$output" != *"nudging"* ]]
  [ "$(fankick_attr "$sysfs/cooling_device6/cur_state")" = "2" ]
}

@test "fan kickstart: a governor decision made DURING the kick wins — it is not overwritten by the restore" {
  local sysfs="$BATS_TEST_TMPDIR/fk-race"
  fankick_fake_thermal "$sysfs" 6 0

  ( sleep 0.35; printf '1\n' >"$sysfs/cooling_device6/cur_state"
    sleep 0.4;  printf '4\n' >"$sysfs/cooling_device6/cur_state" ) &
  run fankick_run "$sysfs" 900 18
  [ "$status" -eq 0 ]
  [[ "$output" == *"nudging to state 6"* ]]
  [[ "$output" == *"re-asserted state 4"* ]]
  [[ "$output" != *"state 1 handed back"* ]]
  [ "$(fankick_attr "$sysfs/cooling_device6/cur_state")" = "4" ]
}

@test "fan kickstart: it re-kicks on EVERY cooldown/reheat cycle — this is why it is not a oneshot" {
  local sysfs="$BATS_TEST_TMPDIR/fk-cycles"
  fankick_fake_thermal "$sysfs" 6 0

  ( sleep 0.35; printf '1\n' >"$sysfs/cooling_device6/cur_state"
    sleep 0.9;  printf '0\n' >"$sysfs/cooling_device6/cur_state"
    sleep 0.4;  printf '1\n' >"$sysfs/cooling_device6/cur_state" ) &
  run fankick_run "$sysfs" 300 26
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c 'nudging to state 6')" -eq 2 ]
}

@test "fan kickstart: discovery is generic and the kick value is READ, never a literal" {
  local script
  script="$(FANKICK_SCRIPT)"

  # No executable line may name a concrete index, the hwmon node, or a trip point.
  run bash -c "grep -vE '^[[:space:]]*#' '$script' | grep -E 'thermal_zone[0-9]|cooling_device[0-9]|hwmon'"
  [ "$status" -ne 0 ]

  # It selects the device by the exact `pwm-fan` type string and reads max_state.
  grep -Fq 'readonly WANTED_CDEV_TYPE="pwm-fan"' "$script"
  grep -Fq 'read_attr "${cdev}/max_state"' "$script"

  # cur_state is written exactly twice — the kick and the restore — and BOTH
  # values are variable references, so no hand-invented "100%" can creep in.
  run bash -c "grep -vE '^[[:space:]]*#' '$script' | grep -cE 'write_attr \"\\\$\{cdev\}/cur_state\"'"
  [ "$output" -eq 2 ]
  run bash -c "grep -vE '^[[:space:]]*#' '$script' | grep -E 'write_attr \"\\\$\{cdev\}/cur_state\" \"[0-9]'"
  [ "$status" -ne 0 ]
}

@test "fan kickstart: the governor is nudged, never replaced — no pwm1, no mode, no trip writes" {
  # Writing the hwmon pwm nodes means owning the fan forever (including across
  # suspend and shutdown); writing thermal_zone*/mode would also disable that
  # zone's critical trip. Both are out of bounds, exactly as for the fan curve.
  local script
  script="$(FANKICK_SCRIPT)"
  run bash -c "grep -vE '^[[:space:]]*#' '$script' | grep -E '(pwm1|pwm1_enable|/mode|trip_point|emul_temp)'"
  [ "$status" -ne 0 ]

  # And it must not reach for the fan curve's own artifacts.
  run bash -c "grep -vE '^[[:space:]]*#' '$script' | grep -E 'ceralive-fan-curve'"
  [ "$status" -ne 0 ]
}

@test "fan kickstart: the restore write is present and is NOT deletable as redundant" {
  # A userspace cur_state write is sticky against this kernel's governor
  # (cur_state_store leaves cdev->updated set, thermal_cdev_update()
  # short-circuits on it, step_wise clears it only when its target changes), so
  # the restore is the only thing that ends the kick. Pin both the code and the
  # explanation, because the tempting "simplification" is to delete it.
  local script
  script="$(FANKICK_SCRIPT)"
  grep -Fq 'write_attr "${cdev}/cur_state" "${edge_states[i]}"' "$script"
  grep -q 'STICKY' "$script"
  grep -q 'cdev->updated' "$script"
}

@test "fan kickstart: a board with no pwm-fan cooling device is an informational no-op" {
  # x86-minipc has a populated ACPI thermal tree and no pwm-fan at all.
  local sysfs="$BATS_TEST_TMPDIR/fk-nofan"
  rm -rf "$sysfs"
  mkdir -p "$sysfs/cooling_device0"
  printf 'Processor\n' >"$sysfs/cooling_device0/type"
  printf '0\n' >"$sysfs/cooling_device0/max_state"

  run env CERALIVE_FAN_KICK_THERMAL_DIR="$sysfs" CERALIVE_FAN_KICK_WAIT=1 \
    bash "$(FANKICK_SCRIPT)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no fan to kick-start"* ]]

  # A board with no thermal class at all is equally a clean no-op.
  run env CERALIVE_FAN_KICK_THERMAL_DIR="$BATS_TEST_TMPDIR/fk-absent" \
    bash "$(FANKICK_SCRIPT)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no thermal class"* ]]

  # The wait is a deadline-bounded poll, not a bare fixed settle constant.
  grep -Fq 'deadline=$(( SECONDS + WAIT_SECONDS ))' "$(FANKICK_SCRIPT)"
}

@test "fan kickstart: a single-active-state board is skipped — there is nothing to kick above" {
  # max_state == 1 means the only active state IS max_state, so entering it
  # already commands full PWM and a kick would be a pointless write.
  local sysfs="$BATS_TEST_TMPDIR/fk-single"
  fankick_fake_thermal "$sysfs" 1 0

  # MAX_CYCLES is a hang guard, not part of the contract: this run is supposed to
  # exit at discovery. Without it a regression that drops the skip would leave the
  # resident monitor looping forever and this test would hang instead of failing.
  run fankick_run "$sysfs" 300 6
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to kick above"* ]]
  [[ "$output" != *"nudging"* ]]
  [ "$(fankick_attr "$sysfs/cooling_device6/cur_state")" = "0" ]
}

@test "fan kickstart: the unit is RESIDENT (Type=exec + Restart=on-failure), not a oneshot" {
  # The fan re-enters an active state many times over a device's uptime, so a
  # boot oneshot would fix only the first dead start.
  local unit
  unit="$(FANKICK_UNIT)"
  grep -Eq '^Type=exec$' "$unit"
  grep -Eq '^Restart=on-failure$' "$unit"
  grep -Eq '^RestartSec=' "$unit"

  # NOT a oneshot, and NOT Restart=always: the script exits 0 on purpose on a
  # board with no fan, and `always` would respawn that in a hot loop forever.
  run grep -E '^Type=oneshot$' "$unit"
  [ "$status" -ne 0 ]
  run grep -E '^Restart=always$' "$unit"
  [ "$status" -ne 0 ]

  # Hardening must not remount /sys read-only — that would break the one write
  # this unit exists to make.
  run grep -E '^ProtectKernelTunables=yes$' "$unit"
  [ "$status" -ne 0 ]
}

@test "fan kickstart: missing runtime source FAILS the build (fail-closed, nothing installed)" {
  local unit_dir="$BATS_TEST_TMPDIR/fk-failclosed-units"
  local sbin_dir="$BATS_TEST_TMPDIR/fk-failclosed-sbin"
  run env CERALIVE_RUNTIME_SRC="$BATS_TEST_TMPDIR/fk-empty-src" \
    FAN_KICKSTART_UNIT_DIR="$unit_dir" FAN_KICKSTART_SBIN_DIR="$sbin_dir" \
    bash -c "source '$POSTINST_LIB'; setup_fan_kickstart"
  [ "$status" -ne 0 ]
  [[ "$output" == *"fan-kickstart script not found"* ]]
  [ ! -e "$unit_dir/ceralive-fan-kickstart.service" ]
}

@test "fan kickstart: the fix is wired into configure_services and registered in the drift gate" {
  # An unreferenced setup function is dead code — the stalling fan ships.
  run grep -E '^\s*setup_fan_kickstart$' "$POSTINST_LIB"
  [ "$status" -eq 0 ]
  # Standalone-artifact idiom: defined once in postinst-lib.sh, never inlined.
  grep -Fq 'setup_fan_kickstart' "$V2/ci/postinst-drift-check.sh"
  run grep -cE '^setup_fan_kickstart\(\) \{' "$POSTINST_LIB"
  [ "$output" -eq 1 ]

  # It is ADDITIVE to setup_fan_curve, which must remain untouched and separate.
  run grep -cE '^setup_fan_curve\(\) \{' "$POSTINST_LIB"
  [ "$output" -eq 1 ]
}

# ===========================================================================
# 30. Debug/production package split — the CERALIVE_DEBUG_IMAGE variant seam.
#
#     manifests/packages/development.delta.list is the debug-only package set:
#     python3 + strace/tcpdump + the fifteen T17 packages the debug-toolset
#     sysext add-on carries. It is installed ONLY when CERALIVE_DEBUG_IMAGE=1;
#     a production build's package set must stay byte-identical to what todo 31
#     measured and baselined.
#
#     THE TRAP THESE TESTS EXIST FOR: the file shares the `.delta.list` suffix
#     with the two FAMILY deltas because it is the same format, but it is keyed
#     on the BUILD VARIANT instead. Three places in this repo globbed
#     `manifests/packages/*.delta.list` as a directory — lib/parity-check.sh's
#     expected set, tests/realhw-suite.sh's synthesized dpkg status, and this
#     file's own make_parity_rootfs fixture. Left alone, every one of them would
#     have folded 18 debug packages into the PRODUCTION contract: parity-check
#     would fail the [7/9] gate on a correct production image, and the fixture
#     would have hidden it by declaring those packages installed. All three now
#     go through common.sh::runtime_pkg_list_files, which skips the debug delta
#     by name and re-appends it only under the flag.
#
#     Static + real-execution, UNIT scope: no image boot, no orchestrator run.
# ===========================================================================

DEV_DELTA_LIST() { printf '%s' "$V2/manifests/packages/development.delta.list"; }

# dev_delta_expected — the exact debug-only set, sorted. Written out literally
# rather than read from the file so a silent edit to the list is a test failure,
# not a self-fulfilling assertion.
dev_delta_expected() {
  printf '%s\n' \
    alsa-utils can-utils htop i2c-tools iotop iperf3 lsof nano \
    netcat-openbsd nethogs pciutils pulseaudio python3 socat strace \
    tcpdump usbutils vnstat | sort
}

active_pkgs_of() { sed -e 's/#.*//' "$1" | awk 'NF{print $1}' | sort -u; }

@test "dev delta: development.delta.list exists and carries exactly the debug-only set" {
  [ -f "$(DEV_DELTA_LIST)" ]
  run diff <(dev_delta_expected) <(active_pkgs_of "$(DEV_DELTA_LIST)")
  [ "$status" -eq 0 ]
}

@test "dev delta: python3 is in the delta and NOT in the production shared list" {
  # python3 is the content-diff probe for the two variants: a real production
  # rootfs has 552 installed packages and zero python3*, so its presence is an
  # unambiguous signal that the debug branch actually took effect.
  run grep -Ex 'python3[[:space:]]*(#.*)?' "$(DEV_DELTA_LIST)"
  [ "$status" -eq 0 ]
  run grep -qxF python3 <(active_pkgs_of "$V2/manifests/packages/shared.list")
  [ "$status" -ne 0 ]
}

@test "dev delta: no package is duplicated from shared.list or a family delta" {
  # A duplicate would make "debug == production + exactly this delta" untrue and
  # would silently pull a debug package into the production image.
  local dupes
  dupes="$(comm -12 <(active_pkgs_of "$(DEV_DELTA_LIST)") \
                    <(active_pkgs_of "$V2/manifests/packages/shared.list"))"
  [ -z "$dupes" ]

  local f
  for f in "$V2/manifests/packages"/rk3588.delta.list "$V2/manifests/packages"/x86_64.delta.list; do
    dupes="$(comm -12 <(active_pkgs_of "$(DEV_DELTA_LIST)") <(active_pkgs_of "$f"))"
    [ -z "$dupes" ]
  done
}

@test "dev delta: the PRODUCTION list selection is exactly shared.list + the family deltas" {
  # The reference is todo 31's merged baseline: shared.list + both family deltas,
  # nothing else. Drives the SHIPPED common.sh helper, flag unset.
  local got
  got="$(CERALIVE_DEBUG_IMAGE= runtime_pkg_lists | xargs -n1 basename | sort)"
  run diff <(printf '%s\n' rk3588.delta.list shared.list x86_64.delta.list) <(printf '%s\n' "$got")
  [ "$status" -eq 0 ]

  # …and explicitly with the flag set to 0.
  got="$(CERALIVE_DEBUG_IMAGE=0 runtime_pkg_lists | xargs -n1 basename | sort)"
  run diff <(printf '%s\n' rk3588.delta.list shared.list x86_64.delta.list) <(printf '%s\n' "$got")
  [ "$status" -eq 0 ]
}

@test "dev delta: CERALIVE_DEBUG_IMAGE=1 adds the development delta and NOTHING else" {
  local got
  got="$(CERALIVE_DEBUG_IMAGE=1 runtime_pkg_lists | xargs -n1 basename | sort)"
  run diff <(printf '%s\n' development.delta.list rk3588.delta.list shared.list x86_64.delta.list) \
           <(printf '%s\n' "$got")
  [ "$status" -eq 0 ]
}

@test "dev delta: the resolved debug package SET equals production plus exactly the delta" {
  local prod debug
  prod="$(CERALIVE_DEBUG_IMAGE=0 runtime_pkg_lists | xargs sed -e 's/#.*//' | awk 'NF{print $1}' | sort -u)"
  debug="$(CERALIVE_DEBUG_IMAGE=1 runtime_pkg_lists | xargs sed -e 's/#.*//' | awk 'NF{print $1}' | sort -u)"

  # Nothing may be REMOVED by the debug branch.
  [ -z "$(comm -23 <(printf '%s\n' "$prod") <(printf '%s\n' "$debug"))" ]
  # What it ADDS is exactly the delta.
  run diff <(dev_delta_expected) <(comm -13 <(printf '%s\n' "$prod") <(printf '%s\n' "$debug"))
  [ "$status" -eq 0 ]
}

@test "dev delta: orchestrate.sh resolves the family delta by NAME and gates the dev delta on the flag" {
  local orch="$LIB_DIR/orchestrate.sh"
  # The family delta stays a ${FAMILY}-keyed lookup — never a directory glob,
  # which is what would swallow development.delta.list on every board.
  grep -Fq 'delta_list="${pkg_dir}/${FAMILY}.delta.list"' "$orch"
  ! grep -Eq 'pkg_dir\}?"?/\*\.delta\.list' "$orch"

  # The dev delta is appended ONLY inside a CERALIVE_DEBUG_IMAGE=1 branch, and a
  # debug build with the file missing fails closed instead of silently shipping
  # a production package set under a debug label.
  grep -Fq 'dev_delta_list="${pkg_dir}/${DEV_DELTA_BASENAME}"' "$orch"
  grep -Fq 'CERALIVE_DEBUG_IMAGE=1 but the development package delta is missing' "$orch"
}

@test "dev delta: the debug flag is validated BEFORE the runtime package set is resolved" {
  # Ordering is the whole point: the package set now depends on the flag, so a
  # value like `yes` must abort rather than quietly resolve a PRODUCTION set and
  # fail three stages later at mkosi.
  local orch="$LIB_DIR/orchestrate.sh"
  local call_line res_line
  call_line="$(grep -n '^  resolve_debug_image_flag$' "$orch" | head -1 | cut -d: -f1)"
  res_line="$(grep -n 'SHARED_PACKAGES="\$(read_pkg_list' "$orch" | head -1 | cut -d: -f1)"
  [ -n "$call_line" ]
  [ -n "$res_line" ]
  [ "$call_line" -lt "$res_line" ]
}

@test "dev delta: no consumer keeps a bare delta-list directory glob" {
  # STRUCTURAL GUARD, not three instances: any future consumer that re-adds the
  # glob silently reintroduces the debug-into-production leak.
  # Comments are stripped first: this test's own prose names the offending glob.
  local f
  for f in "$LIB_DIR/parity-check.sh" "$TESTS_DIR/realhw-suite.sh" "$BATS_TEST_FILENAME"; do
    run bash -c "sed 's/#.*//' \"\$1\" | grep -nE 'PKG_MANIFEST_DIR\}?\"?/\\*\\.delta\\.list|packages\"?/\\*\\.delta\\.list'" bash "$f"
    [ "$status" -ne 0 ]
  done
  # …and each of them routes through the one shared selector instead.
  grep -Fq 'runtime_pkg_list_files' "$LIB_DIR/parity-check.sh"
  grep -Fq 'runtime_pkg_list_files' "$TESTS_DIR/realhw-suite.sh"
  grep -Fq 'runtime_pkg_list_files' "$BATS_TEST_FILENAME"
}

@test "dev delta: parity accepts a production rootfs WITHOUT the debug packages" {
  # Scoped to check A (the Debian package diff) rather than the overall exit
  # status: the shared fixture deliberately omits libsrt1.5-ceralive, so a bare
  # make_parity_rootfs already fails on a first-party gap that predates this seam
  # and has nothing to do with it.
  local root="$BATS_TEST_TMPDIR/devdelta-prod-rootfs"
  make_parity_rootfs "$root"

  # Rebuild the dpkg status from an EXPLICITLY production-only set — shared.list
  # plus the two family deltas, named, never globbed. Reusing the fixture's own
  # selection would make this vacuous: a selector that wrongly folds the debug
  # delta in feeds BOTH the rootfs and the expectation, so they agree and the leak
  # is invisible. Modelling a real production image is what exposes it.
  local packages=() package
  while IFS= read -r package; do [[ -n "$package" ]] && packages+=("$package"); done \
    < <(sed -e 's/#.*//' \
          "$V2/manifests/packages/shared.list" \
          "$V2/manifests/packages/rk3588.delta.list" \
          "$V2/manifests/packages/x86_64.delta.list" | awk 'NF{print $1}')
  packages+=(gstreamer1.0-rockchip1 rockchip-multimedia-config ceralive-device cerastream srtla-send-rs)
  write_installed_package_status "$root/var/lib/dpkg/status" "${packages[@]}"

  run "$LIB_DIR/parity-check.sh" "$root"
  [[ "$output" == *"all Debian-sourced shared.list packages installed"* ]]
  [[ "$output" != *"python3"* ]]
  [[ "$output" != *"strace"* ]]
}

@test "dev delta: parity DEMANDS the debug packages when CERALIVE_DEBUG_IMAGE=1 (non-vacuity)" {
  # The inverse leg. Without it the test above passes even if the seam does
  # nothing at all, because "absent and never checked" looks like "absent and
  # correctly not required".
  local root="$BATS_TEST_TMPDIR/devdelta-debug-rootfs"
  make_parity_rootfs "$root"          # production package set only
  run env CERALIVE_DEBUG_IMAGE=1 "$LIB_DIR/parity-check.sh" "$root"
  [ "$status" -ne 0 ]
  [[ "$output" == *"python3"* ]]
  [[ "$output" == *"strace"* ]]
}

@test "dev delta: CERALIVE_DEBUG_IMAGE reaches every subimage via PassEnvironment" {
  # The package set is forwarded as $SHARED_PACKAGES (already propagated), but the
  # runtime postinst also branches on the flag itself for ssh enablement, the
  # password hash and the /etc/ceralive/debug-image marker. Read empty in a
  # subimage chroot, a debug image would install the delta and then behave like a
  # production one.
  local pass_names
  pass_names="$(sed -n 's/^PassEnvironment=//p' "$V2/mkosi/mkosi.conf")"
  local -A in_pass=()
  local n
  for n in $pass_names; do in_pass["$n"]=1; done
  [ -n "${in_pass[CERALIVE_DEBUG_IMAGE]:-}" ]
  [ -n "${in_pass[CERALIVE_DEBUG_PASSWORD_HASH]:-}" ]
  [ -n "${in_pass[SHARED_PACKAGES]:-}" ]
}

@test "dev delta: the debug image keeps its access behaviour (password + ssh + marker)" {
  # The seam gained packages; it must not have lost the three things that already
  # defined a debug image.
  grep -Fq '/etc/ceralive/debug-image' "$POSTINST_LIB"
  grep -Fq 'usermod --password' "$POSTINST_LIB"
  run grep -cE '^configure_ssh_enablement\(\) \{' "$POSTINST_LIB"
  [ "$output" -eq 1 ]
}

@test "dev delta: the debug-toolset sysext add-on is untouched and stays the field path" {
  # BOTH paths, not either: the add-on is the runtime/field-diagnostics route on a
  # production image; the delta is the bench route baked at build time. The sysext
  # builder must keep reading a --deb-staging tree and no package .list at all.
  local descriptor="$V2/manifests/addons/debug-toolset.json"
  [ -f "$descriptor" ]
  grep -Fq '"id": "debug-toolset"' "$descriptor"
  run grep -nE '\.delta\.list|packages/shared\.list' "$LIB_DIR/build-feature-sysext.sh"
  [ "$status" -ne 0 ]

  # Every package the add-on's `provides` paths come from is also in the delta, so
  # an operator gets the same toolbox whichever route they are on.
  local p
  for p in alsa-utils pulseaudio usbutils pciutils lsof i2c-tools can-utils htop \
           iotop nethogs vnstat nano iperf3 socat netcat-openbsd; do
    grep -qxF "$p" <(active_pkgs_of "$(DEV_DELTA_LIST)")
  done
}

@test "dev delta: 'development' is not a board family, so no board can resolve the delta as one" {
  # The lookup orchestrate.sh performs is ${FAMILY}.delta.list. If a family named
  # `development` ever existed, a board could pull the debug set into a production
  # build through the ordinary family path.
  [ ! -e "$V2/manifests/families/development.yaml" ]
  run grep -rl '^family:[[:space:]]*development' "$V2/manifests/boards"
  [ "$status" -ne 0 ]
}

@test "dev delta: the relative size baseline is SKIPPED for a debug build, absolute ceiling is not" {
  # A debug image is production + ~58 MB, so it trips the comparator's 50 MB
  # growth threshold by construction. The warning's own remedy is "update the
  # baseline in the same PR" — from a debug build that would overwrite the
  # PRODUCTION baseline and desync it from size-budget.json, which another test in
  # this file fails on. Only the RELATIVE check is skipped; the absolute ceiling
  # runs for both variants.
  local orch="$LIB_DIR/orchestrate.sh"
  local body
  body="$(awk '/^compare_size_against_baseline\(\) \{/{grab=1} grab{print} grab && /^}/{exit}' "$orch")"
  [ -n "$body" ]
  grep -Fq 'CERALIVE_DEBUG_IMAGE:-0' <<<"$body"
  grep -Fq 'relative size baseline SKIPPED' <<<"$body"

  # The absolute gate is a SEPARATE call and must NOT have grown a debug branch.
  local stage
  stage="$(awk '/\[6c\/9\] enforcing the rootfs size budget/{grab=1} grab{print} grab && /^  fi$/{exit}' "$orch")"
  [ -n "$stage" ]
  grep -Fq 'MEASURE_SIZE_SH' <<<"$stage"
  ! grep -Fq 'CERALIVE_DEBUG_IMAGE' <<<"$stage"
}

# ===========================================================================
# 31. Kernel freeze guardrails — the boot stack is RAUC-only, never apt.
#
#     docs/partition-contract.md rule 3 puts kernel/DTB/initrd INSIDE each RAUC
#     rootfs slot, so the only sanctioned way to change them is writing a whole
#     new slot. Nothing enforced that: the shipped image carried ZERO dpkg holds,
#     so an `apt-get upgrade` on a running device would replace the kernel
#     underneath a slot the A/B selector had already committed to.
#     postinst-lib.sh::freeze_boot_packages bakes `apt-mark hold` (primary) plus
#     a supplementary name+version apt pin.
#
#     THE TWO TRAPS THESE TESTS EXIST FOR:
#       (a) A hardcoded package list would freeze ONE board. The U-Boot package
#           name differs per board (linux-u-boot-rock-5b-plus-vendor vs
#           linux-u-boot-orangepi5-plus-vendor), so the set must come from the
#           resolved manifest env, and the four env vars must therefore stay on
#           the orchestrate.sh env_names <-> mkosi.conf PassEnvironment= lockstep.
#       (b) Freezing a FIRST-PARTY package would break the ordinary software
#           update CeraUI drives. cerastream / ceralive-device / srtla-send-rs
#           must never be held, and the negative assertion below is what fails if
#           one is ever added.
#
#     Behavioural coverage (hold set, pin content, fail-closed legs, and a REAL
#     `apt-get -s upgrade` dry run) lives in tests/kernel-freeze-guardrails.test.sh;
#     these are the structural guards that belong beside the rest of the manifest
#     and executor contracts.
# ===========================================================================

@test "kernel freeze: the freeze set is resolved from the manifest, never hardcoded" {
  local body
  body="$(awk '/^freeze_boot_packages\(\) \{/{grab=1} grab{print} grab && /^}/{exit}' "$POSTINST_LIB")"
  [ -n "$body" ]

  local v
  for v in KERNEL_PACKAGES DTB_PACKAGES UBOOT_PACKAGES FIRMWARE_PACKAGES; do
    grep -Fq "\${$v" <<<"$body"
  done

  # A literal BSP package name here would silently freeze one board only.
  run grep -nE 'linux-image-vendor-rk35xx|linux-dtb-vendor-rk35xx|linux-u-boot-|armbian-firmware' <<<"$body"
  [ "$status" -ne 0 ]
}

@test "kernel freeze: both shipped RK3588 boards resolve a U-Boot package for it to hold" {
  # The env the freeze reads is populated from these manifest fields; if a board
  # ever stopped declaring one, its bootloader would silently drop out of the
  # freeze while the kernel stayed held.
  grep -Fq 'linux-u-boot-rock-5b-plus-vendor' "$V2/manifests/boards/rock-5b-plus.yaml"
  grep -Fq 'linux-u-boot-orangepi5-plus-vendor' "$V2/manifests/boards/orange-pi-5-plus.yaml"
  grep -Fq 'linux-image-vendor-rk35xx' "$V2/manifests/families/rk3588.yaml"
  grep -Fq 'linux-dtb-vendor-rk35xx' "$V2/manifests/families/rk3588.yaml"
  grep -Fq 'armbian-firmware' "$V2/manifests/families/rk3588.yaml"
}

@test "kernel freeze: NO first-party CeraLive package may ever be held" {
  # This is the assertion that fails if someone adds an app-layer package to the
  # freeze. cerastream and CeraUI ship over apt from apt.ceralive.tv and a hold
  # would break `system.startUpdate()` for good.
  local never
  never="$(sed -n 's/^CERALIVE_NEVER_FREEZE_PKGS=.*:-\(.*\)}"$/\1/p' "$POSTINST_LIB")"
  [ -n "$never" ]

  local p
  for p in cerastream ceralive-device srtla-send-rs libsrt1.5-ceralive \
           gstreamer1.0-libuvch264src modemmanager; do
    [[ " $never " == *" $p "* ]]
  done

  # The refusal must be a hard abort, and it must be checked BEFORE any hold runs.
  local body
  body="$(awk '/^freeze_boot_packages\(\) \{/{grab=1} grab{print} grab && /^}/{exit}' "$POSTINST_LIB")"
  grep -Fq 'refusing to hold first-party package' <<<"$body"
  local guard_line hold_line
  guard_line="$(grep -n 'refusing to hold first-party package' <<<"$body" | head -1 | cut -d: -f1)"
  hold_line="$(grep -n 'apt-mark hold' <<<"$body" | head -1 | cut -d: -f1)"
  [ "$guard_line" -lt "$hold_line" ]
}

@test "kernel freeze: the shipped image installs no unattended-upgrades" {
  # The freeze answers "apt must not change the kernel". Adding an automatic
  # upgrade daemon would be answering the opposite question, and this appliance
  # updates through RAUC only.
  run grep -rnE '^[[:space:]]*unattended-upgrades[[:space:]]*$' "$V2/manifests/packages"
  [ "$status" -ne 0 ]
  run grep -rn 'unattended-upgrade' "$V2/mkosi/customize" "$V2/mkosi/mkosi.images"
  [ "$status" -ne 0 ]
}

@test "kernel freeze: the hold is verified, not assumed" {
  # Same fail-closed discipline as mask_service: a hold that silently did not
  # apply ships an apt-upgradable kernel on an image that passes every other gate.
  # Assert against the EXECUTABLE body — the header prose names `apt-mark
  # showhold` too, and a mutation that deleted the real call still passed while
  # this grep could see the comment.
  local body code
  body="$(awk '/^freeze_boot_packages\(\) \{/{grab=1} grab{print} grab && /^}/{exit}' "$POSTINST_LIB")"
  code="$(grep -vE "^[[:space:]]*#|printf '#" <<<"$body")"
  grep -Fq 'apt-mark showhold' <<<"$code"
  grep -Fq 'did not land' <<<"$code"
}

@test "kernel freeze: the pin is name+version, and the origin form is documented as unusable" {
  local body
  body="$(awk '/^freeze_boot_packages\(\) \{/{grab=1} grab{print} grab && /^}/{exit}' "$POSTINST_LIB")"
  grep -Fq 'Pin: version' <<<"$body"
  grep -Fq 'Pin-Priority: 1001' <<<"$body"

  # An emitted origin pin cannot match a locally-installed .deb; only the
  # explanatory prose may mention one.
  run grep -Fq 'Pin: origin' <<<"$(grep -v "printf '#" <<<"$body")"
  [ "$status" -ne 0 ]

  # The generated file must carry the bypass limitation with it onto the device.
  grep -Fq 'LIMITATION' <<<"$body"
}

@test "kernel freeze: the runtime executor calls it, last, after every apt transaction" {
  local postinst="$V2/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"
  run grep -cE '^  freeze_boot_packages( |$)' "$postinst"
  [ "$output" -eq 1 ]

  # run-all.sh's runtime modules are NOT executed by ./v2/build, so the wiring in
  # this executor is the only thing that makes the freeze ship.
  local main_body
  main_body="$(awk '/^main\(\) \{/,/^\}/' "$postinst")"
  local freeze_at hawkbit_at
  freeze_at="$(grep -n 'freeze_boot_packages' <<<"$main_body" | cut -d: -f1)"
  hawkbit_at="$(grep -n 'setup_hawkbit_updater' <<<"$main_body" | cut -d: -f1)"
  [ "$freeze_at" -gt "$hawkbit_at" ]
}

@test "kernel freeze: freeze_boot_packages is on the drift gate's consolidated list" {
  grep -Fq 'freeze_boot_packages' "$V2/ci/postinst-drift-check.sh"
  run bash "$V2/ci/postinst-drift-check.sh"
  [ "$status" -eq 0 ]
}

@test "kernel freeze: its behavioural suite is wired into the CI entrypoint" {
  local suite="$TESTS_DIR/kernel-freeze-guardrails.test.sh"
  [ -x "$suite" ]
  grep -Fq 'kernel-freeze-guardrails.test.sh' "$V2/run-tests"
}
