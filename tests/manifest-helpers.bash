#!/usr/bin/env bash
#
# manifest-helpers.bash — the shared setup/teardown and fixture helpers for the
# manifest contract suites.
#
# `tests/manifest.bats` was one 7,244-line file. It is now six concern-scoped
# suites — manifest-schema, package-contract, postinst-wiring, mkosi-image-contract,
# runtime-services, variant-contract — each of which starts with
# `load manifest-helpers`. The test CASES moved verbatim; this file holds
# everything that was not a case, so that no suite can be missing a helper a
# relocated case happens to use.
#
# Not a Bats file: it defines no `@test` and must never define one, or the split
# suites' case count would stop summing to the pre-split total.
#
# shellcheck shell=bats
# shellcheck disable=SC2154,SC2034,SC2317
#
# Inherited scope note from the former single file (UNIT ONLY — no image boot,
# no orchestrator):
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
# Run:  run-tests              (CI entrypoint)
#   or: bats tests/{manifest-schema,package-contract,postinst-wiring,mkosi-image-contract,runtime-services,variant-contract}.bats

setup() {
  TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  PIPELINE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
  LIB_DIR="$PIPELINE_DIR/lib"
  COMMON_SH="$LIB_DIR/common.sh"
  RESOLVE_SH="$LIB_DIR/resolve.sh"
  RESOLVE_PY="$LIB_DIR/resolve.py"
  VERSIONS_LIB_SH="$LIB_DIR/shared/versions-lib.sh"
  # common.sh sources the standalone logger, so any stub tree that copies
  # common.sh must carry log-lib.sh beside it or the source fails.
  LOG_LIB_SH="$LIB_DIR/shared/log-lib.sh"
  MEASURE_SH="$LIB_DIR/measure-size.sh"
  FETCH_DEBS="$LIB_DIR/fetch-debs.sh"
  CHECK_WWAN="$LIB_DIR/check-wwan-modules.sh"
  # Two handles on the same library, and the difference is load-bearing.
  # $POSTINST_ENTRY is the file every real caller SOURCES; it is thin and only
  # pulls in the per-concern modules under customize/postinst.d/. A static
  # contract check must instead read the WHOLE sourced set, or it goes silently
  # vacuous the moment a function moves between modules — so $POSTINST_LIB is
  # that set, materialized once per test.
  POSTINST_ENTRY="$PIPELINE_DIR/mkosi/customize/postinst-lib.sh"
  POSTINST_LIB="$BATS_TEST_TMPDIR/postinst-lib.sourceset.sh"
  cat "$POSTINST_ENTRY" "$PIPELINE_DIR"/mkosi/customize/postinst.d/*.sh >"$POSTINST_LIB"
  APT_CERALIVE_REPO="$PIPELINE_DIR/mkosi/customize/apt-ceralive-repo.sh"
  VERIFY_PASETO="$LIB_DIR/verify-paseto-key-encodings.sh"
  BSP_BASELINE_JSON="$PIPELINE_DIR/manifests/bsp-baseline.json"
  SIZE_BUDGET_JSON="$PIPELINE_DIR/manifests/size-budget.json"
  QEMU_X86="$TESTS_DIR/qemu-x86.sh"
  SCHEMA_DIR="$PIPELINE_DIR/manifests/schema"
  FAMILY_SCHEMA="$SCHEMA_DIR/family.schema.json"
  BOARD_SCHEMA="$SCHEMA_DIR/board.schema.json"
  ADDON_SCHEMA="$SCHEMA_DIR/addon.schema.json"
  VALIDATE_PY="$PIPELINE_DIR/ci/validate-manifests.py"
  # The target-release mapping every suite/VERSION_ID expectation derives from.
  # Fixtures MUST NOT hardcode a VERSION_ID: validate-manifests.py and the sysext
  # backend both read this file, so a frozen fixture would start failing for the
  # right reason at the wrong time (a release bump) and read as a broken test.
  TARGET_RELEASE_LIB="$LIB_DIR/shared/target-release-lib.sh"
  # shellcheck source=../lib/shared/target-release-lib.sh
  source "$TARGET_RELEASE_LIB"
  target_release_load
  FIXTURES="$TESTS_DIR/manifests/fixtures"
  REPO_ROOT="${PIPELINE_DIR}"
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
  "payload": { "type": "sysext" }, "sysextLevel": "1", "versionId": "${OS_VERSION_ID}",
  "compatibleOsVersions": ["${OS_VERSION_ID}"],
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
    "$COMMON_SH" "$PIPELINE_DIR/manifests/packages/shared.list" "$PIPELINE_DIR/manifests/packages"
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
  packages+=(gstreamer1.0-rockchip-ceralive rockchip-multimedia-config ceralive-device cerastream srtla-send-rs)
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
  printf '255\tlocal\n254\tmain\n253\tdefault\n' >"$root/etc/iproute2/rt_tables"
  : >"$root/etc/udev/rules.d/99-ceralive-hardware.rules"
  : >"$root/etc/apt/sources.list.d/debian.sources"
  : >"$root/etc/apt/sources.list.d/ceralive.sources"
  : >"$root/etc/systemd/network/10-ceralive-wlan0.link"
}

# serialize <name> — hold an exclusive, suite-scoped lock for the REST of the
# current @test, so the handful of tests that share mutable state run correctly
# under `bats --jobs N` (which run-tests enables when GNU parallel is on
# PATH). bats parallelizes test CASES, not the comment "sections", so any two
# tests that touch the same mutable resource must serialize themselves:
#   * §8 postinst-drift — two tests mutate the working tree (an inline twin
#     appended to mkosi.postinst.chroot; a planted residue file under mkosi/)
#     while a third asserts the CLEAN tree; without a lock a parallel scheduler
#     could read the tree mid-mutation -> false failure.
#   * §14 feature sysext — build_feature_fixture populates a per-FILE fixture
#     dir ($BATS_FILE_TMPDIR/out) shared by five tests; only one may build it.
#   * §9 build-plan probes — each `build` invocation removes and recreates
#     the shared `mkosi/.staging/<board>` directory; these tests take one
#     lock so GNU-parallel CI cannot interleave board fetch plans.
# The lock auto-releases when the @test subshell exits (each bats test runs in
# its own subshell). Use BATS_RUN_TMPDIR so workers spawned by GNU parallel share
# the rendezvous even when BATS_FILE_TMPDIR is worker-local. flock-less hosts get
# a no-op — run-tests only requests --jobs when flock is present, so a serial
# run never needs it.
#
# THE LOCK NAME IS THE RESOURCE, AND MUST NOT NAME THE SUITE FILE. run-tests
# passes `--jobs N --no-parallelize-within-files`, so cases inside one file are
# ALREADY serial — an intra-file lock buys nothing, and the only exclusion that
# matters is between files. Keying the lock path on $BATS_TEST_FILENAME gave each
# suite its own lock file, i.e. no cross-file exclusion at all: `working-tree` is
# mutated by postinst-wiring.bats while hdmirx-edid-contract.bats and
# package-contract.bats read the same tree through ci/postinst-drift-check.sh,
# and `build-plan` is shared by variant-contract.bats and
# mkosi-image-contract.bats. The resource name ("$1") is the whole key.
serialize() {
  command -v flock >/dev/null 2>&1 || return 0
  local lockfd lock_root="${BATS_RUN_TMPDIR:-${BATS_FILE_TMPDIR:-}}"
  [[ -n "$lock_root" ]] || return 0
  mkdir -p "$lock_root/locks"
  exec {lockfd}>"$lock_root/locks/.serialize.$1.lock"
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

# The orchestrator is an ENTRY (lib/orchestrate.sh) plus one module per stage
# under lib/stages/, sourced in PIPELINE order. A static check that reads it by
# TEXT must read the whole SET in that order, or it matches nothing and passes
# vacuously — and a stage-ORDER assertion only means something if the modules
# appear in the entry's own source order. Written to a file, never piped: `grep -q`
# closes the pipe and `set -o pipefail` turns a correct read into a failure.
orch_source_set() {
  local out="$BATS_TEST_TMPDIR/orch-source-set.sh" m
  {
    cat "$PIPELINE_DIR/lib/orchestrate.sh"
    # shellcheck disable=SC2016
    while read -r m; do cat "$PIPELINE_DIR/lib/stages/$m"; done \
      < <(sed -n 's#^source "${STAGE_DIR}/\(.*\)"$#\1#p' "$PIPELINE_DIR/lib/orchestrate.sh")
  } >"$out"
  [ -s "$out" ]
  printf '%s\n' "$out"
}

# Emit the real [6c/9] block out of orchestrate.sh so the cases below execute the
# shipped code rather than a copy of it.
extract_size_gate_block() {
  awk '
    /^  if \[\[/ { inblk = 1; buf = $0; next }
    inblk {
      buf = buf ORS $0
      if ($0 == "  fi") { if (buf ~ /\[6c\/9\]/) { print buf; exit } ; inblk = 0 }
    }
  ' "$PIPELINE_DIR/lib/stages/size-gate.sh"
}

# Drive that block with stubbed logging, a caller-supplied budget file and a
# caller-supplied MEASURE_SIZE_SH, exactly as main() would.
run_size_gate_block() {
  local install_boot_bsp="$1" budget_json="$2" artifact="$3" measure_sh="${4:-$MEASURE_SH}"
  local baseline_spy="${5:-}" release_variant_sh="${6:-}" kernel_variant="${7:-}"
  run bash -c "
    set -euo pipefail
    log_info()  { printf '[INFO] %s\n' \"\$*\"; }
    log_warn()  { printf '[WARN] %s\n' \"\$*\"; }
    die()       { printf '[ERROR] %s\n' \"\$*\" >&2; exit 1; }
    compare_size_against_baseline() { if [[ -n '${baseline_spy}' ]]; then touch '${baseline_spy}'; fi; printf '[INFO] baseline-compare %s\n' \"\$1\"; }
    export SIZE_BUDGET_JSON='${budget_json}'
    MEASURE_SIZE_SH='${measure_sh}'
    CHECK_RELEASE_VARIANT_SH='${release_variant_sh}'
    KERNEL_VARIANT='${kernel_variant}'
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
  ' "$PIPELINE_DIR/lib/stages/size-gate.sh"
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
    CHECK_SIZE_REGRESSION_SH='$PIPELINE_DIR/ci/check-size-regression.sh'
    $(extract_baseline_compare_fn)
    compare_size_against_baseline '${board}' '${artifact}'
  "
}






































# repro_prereqs — the deterministic signer needs mksquashfs + openssl + the dev
# PKI. Anything missing → the test SKIPs (still green) rather than false-fails.
repro_prereqs() {
  command -v mksquashfs >/dev/null 2>&1 || return 1
  command -v openssl    >/dev/null 2>&1 || return 1
  [ -s "$PIPELINE_DIR/.dev-keys/leaf-signing.key" ] || return 1
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
  env CERALIVE_RAUC_PKI_DIR="$PIPELINE_DIR/.dev-keys" \
      COMPATIBLE_STRING="ceralive-rock-5b-plus" \
      BUNDLE_VERSION="reprotest" BUNDLE_TS="fixed" BUNDLE_OUT_DIR="$out" \
      SOURCE_DATE_EPOCH="$sde" \
      bash "$PIPELINE_DIR/lib/build-bundle.sh" rock-5b-plus "$tree" >/dev/null 2>&1
}
















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
  # Derived from the SAME mapping --os-version passes below: a hardcoded stem
  # goes VACUOUS on a release bump (guard misses, every §14 case rebuilds).
  local raw="$out/demo-feature-rock-5b-plus-${OS_VERSION_ID}.raw"
  (
    command -v flock >/dev/null 2>&1 && flock 9
    [ -f "$raw" ] && exit 0          # idempotency check INSIDE the lock (no TOCTOU)
    local stg="$BATS_FILE_TMPDIR/staging"
    mkdir -p "$stg/usr/bin" "$stg/opt/demo"
    printf '#!/bin/sh\necho hi\n' > "$stg/usr/bin/demo-tool"
    printf 'payload\n'            > "$stg/opt/demo/data.txt"
    bash "$LIB_DIR/build-feature-sysext.sh" \
      --feature demo-feature --board rock-5b-plus --os-version "${OS_VERSION_ID}" \
      --deb-staging "$stg" --out "$out" \
      --keyring "$BATS_FILE_TMPDIR/gnupg" >/dev/null 2>&1
  ) 9>"$BATS_FILE_TMPDIR/.serialize.feature-fixture.lock"
}















# Two distinct 64-hex content digests for the drift fixtures.
BSP_SHA_A="1111111111111111111111111111111111111111111111111111111111111111"
BSP_SHA_B="2222222222222222222222222222222222222222222222222222222222222222"
















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







# wwan_stage_six <root> [kver] — stage a module tree carrying all six WWAN
# modules with a deliberate MIX of forms: qmi_wwan/cdc_mbim loadable (.ko),
# cdc_ether loadable (.ko.xz, compressed), cdc_wdm as cdc-wdm.ko (hyphen on disk
# — exercises the -/_ normalisation), option + cdc_ncm built-in (modules.builtin).
wwan_stage_six() {
  local root="$1" kv="${2:-6.1.0-generic}"
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
Package: linux-image-generic-rk35xx
Version: 6.1.0-generic
Architecture: arm64
Maintainer: ceralive-test <test@ceralive.tv>
Description: fixture kernel for WWAN module-presence tests
CTL
  tar -C "$tmp/ctl" -czf "$tmp/control.tar.gz" ./control
  printf '2.0\n' > "$tmp/debian-binary"
  ( cd "$tmp" && ar rc "$out" debian-binary control.tar.gz data.tar.gz )
  rm -rf "$tmp"
}







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
      bash -c "source '$POSTINST_ENTRY'; setup_paseto_public_key"
  else
    local b64; b64="$(printf '%s' "$payload" | base64 -w0)"
    run env PASETO_PUBLIC_KEY_B64="$b64" PASETO_DROPIN_DIR="$dir" \
      bash -c "source '$POSTINST_ENTRY'; setup_paseto_public_key"
  fi
  PASETO_DROPIN="$dir/20-paseto-public-key.conf"
}

















# typec_fake_sysfs <dir> <power_role contents> <data_role contents> — a settled
# partner attachment in a minimal /sys/class/typec stand-in.
typec_fake_sysfs() {
  mkdir -p "$1/port0" "$1/port0-partner"
  printf '%s\n' "$2" >"$1/port0/power_role"
  printf '%s\n' "$3" >"$1/port0/data_role"
}











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








FAN_SCRIPT() { printf '%s' "$PIPELINE_DIR/mkosi/runtime/ceralive-fan-curve.sh"; }
FAN_UNIT() { printf '%s' "$PIPELINE_DIR/mkosi/runtime/ceralive-fan-curve.service"; }
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














LED_SCRIPT() { printf '%s' "$PIPELINE_DIR/mkosi/runtime/ceralive-led-status.sh"; }
LED_UNIT() { printf '%s' "$PIPELINE_DIR/mkosi/runtime/ceralive-led-status.service"; }
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






































MODEM_CLOSURE_PKGS="modemmanager libmm-glib0 libmbim-glib4 libmbim-proxy libmbim-utils libqmi-glib5 libqmi-proxy libqmi-utils libqrtr-glib0"












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
      bash -c "source '$PIPELINE_DIR/mkosi/customize/udev.sh' >/dev/null 2>&1 || true
               source '$PIPELINE_DIR/lib/common.sh'
               source '$PIPELINE_DIR/mkosi/customize/udev.sh' 2>/dev/null || true
               generate_modem_slot_uid_rules" >"$BATS_TEST_TMPDIR/gen.out" 2>&1
  MODEM_GEN_STATUS=$?
  MODEM_GEN_RULES="$rules_dir/78-mm-ceralive-slot-uid.rules"
}













# The frozen golden resolves of the PRODUCTION path, one file per shipped board.
# Formerly `vendor-baseline/`, captured when the prebuilt Armbian vendor BSP was
# the bare default; that track is retired, so the rk3588 files were re-captured
# from the mainline `default_variant: edge` resolve and the directory renamed to
# say what it holds. x86-minipc.params is byte-unchanged — its family declares no
# variants and no default_variant, so the bare default still means "apply no
# overlay" there, which is exactly what makes it the opt-in proof.
PRODUCTION_BASELINE_DIR() { printf '%s' "$TESTS_DIR/manifests/fixtures/production-baseline"; }

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
#
# THE OVERLAYS CALLERS PASS ARE FROZEN SYNTHETIC FIXTURES, NOT MIRRORS OF THE
# SHIPPED MANIFEST. Their kernel pins (`tag: v7.1.7`, `commit: c7ba9d6d…`,
# `kernel_release: 7.1.7-…`) are arbitrary but INTERNALLY CONSISTENT strings
# whose only job is to make the rest of the block schema-valid so the ONE
# deliberately-broken field is what the validator reports. They must NOT be
# re-pinned when the real `manifests/families/rk3588.yaml` moves to a new kernel
# base: chasing the live pin here buys nothing, and a fixture that tracks the
# thing it is testing against stops being an independent negative. A leg that
# genuinely asserts the SHIPPED pin runs the real resolver instead — see the
# `kernel_source: the pinned patches commit …` tests in variant-contract.bats.
write_variant_family() {
  local dest="$1" overlay="$2"
  cat > "$dest" <<YAML
arch: arm64
armbian_branch: edge
kernel_packages: [linux-image-generic-rk35xx]
uboot_packages: []
dtb_packages: [linux-dtb-generic-rk35xx]
firmware_packages: [armbian-firmware]
rauc_bootloader_adapter: custom
partition_template: rk3588-ab
serial_console: ttyS2:1500000
variants:
${overlay}
YAML
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
    source '$PIPELINE_DIR/mkosi/mkosi.images/app/mkosi.postinst.chroot'
    FIRST_PARTY_DIR='$dest'
    stage_first_party_from_source_mount
  "
}









removefiles_runtime() {
  sed -n 's/^RemoveFiles=//p' "$PIPELINE_DIR/mkosi/mkosi.images/runtime/mkosi.conf"
}






FANKICK_SCRIPT() { printf '%s' "$PIPELINE_DIR/mkosi/runtime/ceralive-fan-kickstart.sh"; }
FANKICK_UNIT() { printf '%s' "$PIPELINE_DIR/mkosi/runtime/ceralive-fan-kickstart.service"; }

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

# fankick_set_state <attr-path> <value> — move a fake sysfs attribute the way the
# governor would, ATOMICALLY. `printf > attr` truncates before it writes, so a
# concurrent reader can observe a zero-length file, which a real sysfs attribute
# can never do (one ->show() serves a complete value or nothing). That window
# swallowed 16 of 31 overlapping reads here, and the monitor reads an unparsable
# cur_state as "the cooling device went away" and exits 0 — silently skipping the
# rest of the test. `mv` in the same directory is a rename(2): whole old or whole new.
fankick_set_state() {
  local attr="$1" value="$2"
  printf '%s\n' "$value" >"${attr}.new"
  mv -f -- "${attr}.new" "${attr}"
}

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



















DEV_DELTA_LIST() { printf '%s' "$PIPELINE_DIR/manifests/packages/development.delta.list"; }

# dev_delta_expected — the exact debug-only set, sorted. Written out literally
# rather than read from the file so a silent edit to the list is a test failure,
# not a self-fulfilling assertion.
dev_delta_expected() {
  # `pulseaudio` LEFT this set at todo 28 and must never come back: the mandatory
  # `pipewire-alsa` entry in shared.list declares `Conflicts: pulseaudio`, so a debug
  # build carrying both fails its single apt transaction outright (verified against a
  # real trixie arm64 index). Its diagnostic role is covered more broadly by
  # `pipewire-bin`'s pw-cli/pw-dump/pw-top, which ship on EVERY image.
  printf '%s\n' \
    alsa-utils can-utils htop i2c-tools iotop iperf3 lsof nano \
    netcat-openbsd nethogs pciutils python3 socat strace \
    tcpdump usbutils vnstat | sort
}

active_pkgs_of() { sed -e 's/#.*//' "$1" | awk 'NF{print $1}' | sort -u; }
