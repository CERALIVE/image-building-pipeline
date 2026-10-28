#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export FIXTURE="$BATS_TEST_TMPDIR"
  export CERALIVE_UPDATE_STATE_DIR="$FIXTURE/state"
  export CERALIVE_ACTIVATION_STATE_DIR="$FIXTURE/state"
  export CERALIVE_ACTIVATION_LOCK="$FIXTURE/activation.lock"
  export CERALIVE_STREAMING_MARKER="$FIXTURE/streaming"
  export CERALIVE_KERNEL_STATE_LIB="${KERNEL_STATE_LIB_OVERRIDE:-$ROOT/mkosi/runtime/ceralive-kernel-state-lib.sh}"
  export CERALIVE_BOOT_STATE_FILE="$FIXTURE/boot-state"
  export BOOT_STATE_BIN="$ROOT/mkosi/platform/boot/ceralive-boot-state.sh"
  export CERALIVE_HEALTHCHECK_BOOT_ID_FILE="$FIXTURE/boot-id"
  export CERALIVE_HEALTHCHECK_CMDLINE_FILE="$FIXTURE/cmdline"
  export CERALIVE_HEALTHCHECK_CONF="$FIXTURE/update.conf"
  export CERALIVE_HEALTHCHECK_MARKER="$FIXTURE/marker"
  export CERALIVE_HEALTHY_STATE_FILE="$FIXTURE/state/healthy-state.json"
  export CERALIVE_DPKG_STATUS_FILE="$FIXTURE/status"
  export CERALIVE_DPKG_UPDATES_DIR="$FIXTURE/updates"
  export CERALIVE_OS_RELEASE_FILE="$FIXTURE/os-release"
  export CERALIVE_PARTLABEL_FAILURE="$FIXTURE/partlabel-failed"
  export CERALIVE_DEBUG_MARKER="$FIXTURE/debug"
  export CERALIVE_FORCE_HEALTHCHECK_FAIL="$FIXTURE/force-fail"
  export RAUC_BIN="$FIXTURE/bin/rauc"
  export SYSTEMCTL_BIN=true CERASTREAM_BIN=/usr/bin/true SRTLA_SEND_BIN=/usr/bin/true CURL_BIN=true
  export DPKG_BIN="$FIXTURE/bin/dpkg" DPKG_QUERY_BIN="$FIXTURE/bin/dpkg-query"
  export UNAME_BIN="$FIXTURE/bin/uname"
  export SYNC_BIN="$FIXTURE/bin/sync"
  export REAL_SYNC
  REAL_SYNC="$(command -v sync)"
  mkdir -p "$FIXTURE/bin" "$FIXTURE/state" "$FIXTURE/updates"
  export PATH="$FIXTURE/bin:$PATH"
  export ACTIVATE_SCRIPT="${ACTIVATE_SCRIPT_OVERRIDE:-$ROOT/mkosi/runtime/ceralive-rauc-activate.sh}"
  export HEALTH_SCRIPT="${HEALTH_SCRIPT_OVERRIDE:-$ROOT/mkosi/runtime/ceralive-healthcheck.sh}"
  export EXPECTED_PACKAGE=linux-image-7.2.0-ceralive-rk3588
  export EXPECTED_VERSION=7.2.0-ceralive2
  export EXPECTED_SHA
  EXPECTED_SHA="$(printf 'a%.0s' {1..64})"
  export ATTEMPT=11111111-1111-4111-8111-111111111111
  printf 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa\n' >"$FIXTURE/boot-id"
  printf 'rauc.slot=A\n' >"$FIXTURE/cmdline"
  printf 'BUILD_ID="image-10"\n' >"$FIXTURE/os-release"
  printf 'HEALTHCHECK_TIMEOUT=0\n' >"$FIXTURE/update.conf"
  printf 'fixture package database\n' >"$FIXTURE/status"
  : >"$FIXTURE/calls"
  cat >"$FIXTURE/bin/id" <<'SH'
#!/bin/sh
printf '0\n'
SH
  cat >"$RAUC_BIN" <<'SH'
#!/bin/bash
case "$*" in
  'status --detailed --output-format=shell')
    booted="$(sed -n 's/rauc.slot=//p' "$FIXTURE/cmdline")"
    primary="$("$BOOT_STATE_BIN" get-primary)"
    if [[ "$primary" == A ]]; then index=0; else index=1; fi
    printf "RAUC_SYSTEM_BOOTED_BOOTNAME='%s'\nRAUC_BOOT_PRIMARY='rootfs.%s'\n" "$booted" "$index"
    printf "RAUC_SYSTEM_SLOTS='rootfs.0 rootfs.1'\nRAUC_SLOTS='1 2'\n"
    printf "RAUC_SLOT_BOOTNAME_1='A'\nRAUC_SLOT_BOOTNAME_2='B'\n"
    if [[ "$booted" == A ]]; then a=booted; b=inactive; else a=inactive; b=booted; fi
    printf "RAUC_SLOT_STATE_1='%s'\nRAUC_SLOT_STATE_2='%s'\n" "$a" "$b"
    # Deliberately equal: retained bundle timestamps cannot authorize activation.
    printf "RAUC_SLOT_STATUS_INSTALLED_TIMESTAMP_2='2026-10-01T00:00:00Z'\n"
    printf "RAUC_SLOT_STATUS_ACTIVATED_TIMESTAMP_2='2026-10-01T00:00:00Z'\n"
    ;;
  'status mark-active other')
    [[ "${CRASH_BOUNDARY:-}" != before-mark-active ]] || { kill -KILL "$PPID"; exit 99; }
    printf 'mark-active B\n' >>"$FIXTURE/calls"
    "$BOOT_STATE_BIN" set-primary B ;;
  'status mark-good')
    slot="$(sed -n 's/rauc.slot=//p' "$FIXTURE/cmdline")"
    printf 'mark-good %s\n' "$slot" >>"$FIXTURE/calls"
    "$BOOT_STATE_BIN" set-state "$slot" good || exit
    [[ "${CRASH_BOUNDARY:-}" != after-mark-good-before-marker ]] || { kill -KILL "$PPID"; exit 99; } ;;
  *) exit 90 ;;
esac
SH
  cat >"$DPKG_BIN" <<'SH'
#!/bin/sh
[ "$*" = --audit ]
SH
  cat >"$DPKG_QUERY_BIN" <<'SH'
#!/bin/bash
[[ "${@: -1}" == "$EXPECTED_PACKAGE" ]] || exit 90
printf 'install ok installed\t%s\n' "${INSTALLED_VERSION:-$EXPECTED_VERSION}"
SH
  cat >"$UNAME_BIN" <<'SH'
#!/bin/sh
printf '%s\n' "${RUNNING_RELEASE:-7.2.0-ceralive-rk3588}"
SH
  cat >"$SYNC_BIN" <<'SH'
#!/bin/bash
case "${CRASH_BOUNDARY:-}:$1" in
  before-activated-write:*kernel-state.json.tmp.*)
    grep -q '"state":"activated"' "$1" && { kill -KILL "$PPID"; exit 99; } ;;
  after-mark-good:*kernel-state.json.tmp.*)
    grep -q '"state":"succeeded"' "$1" && { kill -KILL "$PPID"; exit 99; } ;;
  after-terminal-succeeded:*/state)
    grep -q '"state":"succeeded"' "$FIXTURE/state/kernel-state.json" && { kill -KILL "$PPID"; exit 99; } ;;
  after-terminal-rolled-back:*/state)
    grep -q '"state":"rolled_back"' "$FIXTURE/state/kernel-state.json" && { kill -KILL "$PPID"; exit 99; } ;;
esac
exec "$REAL_SYNC" "$@"
SH
  chmod +x "$FIXTURE/bin/"*
  "$BOOT_STATE_BIN" init
  write_state staged
}

write_state() {
  printf '{"schema":1,"attempt":"%s","package":"%s","version":"%s","deb_sha256":"%s","target_slot":"B","booted_slot_at_stage":"A","boot_id_at_activation":%s,"state":"%s","reason":null,"timestamps":{"staging":"2026-10-01T00:00:00Z","staged":"2026-10-01T00:00:01Z"}}\n' \
    "$ATTEMPT" "$EXPECTED_PACKAGE" "$EXPECTED_VERSION" "$EXPECTED_SHA" \
    "${2:-null}" "$1" >"$FIXTURE/state/kernel-state.json"
  printf '{"base_bundle_identity":{"slot":"rootfs.0","bundleHash":"%s","checksum":"%s","installedAt":"2026-10-01T00:00:00Z","installedCount":1},"kernel":{"package":"%s","version":"%s","deb_sha256":"%s"},"attempt":"%s","status":"pending","reason":null}\n' \
    "$EXPECTED_SHA" "$EXPECTED_SHA" "$EXPECTED_PACKAGE" "$EXPECTED_VERSION" "$EXPECTED_SHA" "$ATTEMPT" \
    >"$FIXTURE/state/slot-overlay-B.json"
}

boot_target() {
  printf 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb\n' >"$FIXTURE/boot-id"
  printf 'rauc.slot=B\n' >"$FIXTURE/cmdline"
  "$BOOT_STATE_BIN" boot-select
}

snapshot() {
  [[ -n "${T10_QA_DIR:-}" ]] || return 0
  local directory="$T10_QA_DIR/$BATS_TEST_NUMBER-$1"
  mkdir -p "$directory"
  cp "$FIXTURE/state/"* "$FIXTURE/calls" "$FIXTURE/boot-state" "$directory/"
}

assert_state() {
  jq -e --arg state "$1" '.state == $state' "$FIXTURE/state/kernel-state.json"
}

@test "kernel staged arm activation reboot and health confirmation use real CLIs" {
  snapshot staged
  run bash "$ACTIVATE_SCRIPT" --arm
  [ "$status" -eq 0 ]
  assert_state armed
  [ -f "$FIXTURE/state/activation-armed" ]
  snapshot armed
  run bash "$ACTIVATE_SCRIPT" --now
  [ "$status" -eq 0 ]
  assert_state activated
  jq -e '.boot_id_at_activation == "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" and .timestamps.staged == "2026-10-01T00:00:01Z"' "$FIXTURE/state/kernel-state.json"
  snapshot activated
  boot_target
  run bash "$HEALTH_SCRIPT"
  [ "$status" -eq 0 ]
  assert_state succeeded
  jq -e '.status == "confirmed"' "$FIXTURE/state/slot-overlay-B.json"
  grep -Fxq 'mark-good B' "$FIXTURE/calls"
  [ -s "$CERALIVE_HEALTHY_STATE_FILE" ]
  snapshot succeeded
}

@test "disarm preserves staged overlay and allows a later rearm" {
  bash "$ACTIVATE_SCRIPT" --arm
  run bash "$ACTIVATE_SCRIPT" --disarm
  [ "$status" -eq 0 ]
  assert_state staged
  jq -e '.timestamps.staged == "2026-10-01T00:00:01Z"' "$FIXTURE/state/kernel-state.json"
  jq -e '.status == "pending"' "$FIXTURE/state/slot-overlay-B.json"
  [ ! -e "$FIXTURE/state/activation-armed" ]
  bash "$ACTIVATE_SCRIPT" --arm
  assert_state armed
}

@test "idle shutdown selects an armed kernel without requesting a reboot" {
  bash "$ACTIVATE_SCRIPT" --arm
  run bash "$ACTIVATE_SCRIPT"
  [ "$status" -eq 0 ]
  assert_state activated
  [ "$("$BOOT_STATE_BIN" get-primary)" = B ]
  [ "$(<"$FIXTURE/calls")" = 'mark-active B' ]
}

@test "immediate kernel activation refuses an unarmed staged attempt" {
  run bash "$ACTIVATE_SCRIPT" --now
  [ "$status" -ne 0 ]
  assert_state staged
  [ ! -s "$FIXTURE/calls" ]
  [ "$("$BOOT_STATE_BIN" get-primary)" = A ]
}

@test "streaming prevents both immediate and shutdown activation" {
  bash "$ACTIVATE_SCRIPT" --arm
  touch "$CERALIVE_STREAMING_MARKER"
  run bash "$ACTIVATE_SCRIPT" --now
  [ "$status" -ne 0 ]
  run bash "$ACTIVATE_SCRIPT"
  [ "$status" -eq 0 ]
  assert_state armed
  [ ! -s "$FIXTURE/calls" ]
  [ "$("$BOOT_STATE_BIN" get-primary)" = A ]
}

@test "activation refuses each inconsistent or absent pending overlay" {
  cp "$FIXTURE/state/slot-overlay-B.json" "$FIXTURE/valid-overlay"
  for mutation in \
    '.attempt = "22222222-2222-4222-8222-222222222222"' \
    '.kernel.package = "linux-image-7.3.0-ceralive-rk3588"' \
    '.kernel.version = "7.2.0-ceralive3"' \
    '.kernel.deb_sha256 = ("b" * 64)' \
    '.status = "invalid"'; do
    jq "$mutation" "$FIXTURE/valid-overlay" >"$FIXTURE/state/slot-overlay-B.json"
    run bash "$ACTIVATE_SCRIPT" --arm
    [ "$status" -ne 0 ]
    [ ! -s "$FIXTURE/calls" ]
  done
  rm "$FIXTURE/state/slot-overlay-B.json"
  run bash "$ACTIVATE_SCRIPT" --arm
  [ "$status" -ne 0 ]
}

@test "partial corrupt and duplicate kernel state cannot activate or confirm" {
  cp "$FIXTURE/state/kernel-state.json" "$FIXTURE/valid-state"
  for document in '{"state":"staged"' '{}' '[]'; do
    printf '%s\n' "$document" >"$FIXTURE/state/kernel-state.json"
    run bash "$ACTIVATE_SCRIPT" --arm
    [ "$status" -ne 0 ]
    run bash "$HEALTH_SCRIPT"
    [ "$status" -ne 0 ]
    [ ! -s "$FIXTURE/calls" ]
  done
  sed 's/"schema":1/"schema":1,"schema":1/' "$FIXTURE/valid-state" >"$FIXTURE/state/kernel-state.json"
  run bash "$ACTIVATE_SCRIPT" --arm
  [ "$status" -ne 0 ]
}

@test "crash before mark active returns activating to armed on the same boot" {
  bash "$ACTIVATE_SCRIPT" --arm
  run env CRASH_BOUNDARY=before-mark-active bash "$ACTIVATE_SCRIPT" --now
  [ "$status" -eq 137 ]
  assert_state activating
  [ "$("$BOOT_STATE_BIN" get-primary)" = A ]
  snapshot activating-before-selector
  run bash "$HEALTH_SCRIPT"
  [ "$status" -eq 0 ]
  assert_state armed
  snapshot armed-after-recovery
  bash "$ACTIVATE_SCRIPT" --now
  assert_state activated
}

@test "crash after mark active before activated settles succeeded on target boot" {
  bash "$ACTIVATE_SCRIPT" --arm
  run env CRASH_BOUNDARY=before-activated-write bash "$ACTIVATE_SCRIPT" --now
  [ "$status" -eq 137 ]
  assert_state activating
  [ "$("$BOOT_STATE_BIN" get-primary)" = B ]
  snapshot activating-after-selector
  boot_target
  run bash "$HEALTH_SCRIPT"
  [ "$status" -eq 0 ]
  assert_state succeeded
  jq -e '.status == "confirmed"' "$FIXTURE/state/slot-overlay-B.json"
}

@test "after mark active elsewhere waits while selector still has target attempts" {
  bash "$ACTIVATE_SCRIPT" --arm
  run env CRASH_BOUNDARY=before-activated-write bash "$ACTIVATE_SCRIPT" --now
  [ "$status" -eq 137 ]
  printf 'cccccccc-cccc-4ccc-8ccc-cccccccccccc\n' >"$FIXTURE/boot-id"
  run bash "$HEALTH_SCRIPT"
  [ "$status" -eq 0 ]
  assert_state activating
  [ ! -e "$FIXTURE/state/kernel-quarantine.json" ]
}

@test "after mark active elsewhere with target bad rolls back without rearming" {
  bash "$ACTIVATE_SCRIPT" --arm
  run env CRASH_BOUNDARY=before-activated-write bash "$ACTIVATE_SCRIPT" --now
  [ "$status" -eq 137 ]
  "$BOOT_STATE_BIN" set-state B bad
  printf 'cccccccc-cccc-4ccc-8ccc-cccccccccccc\n' >"$FIXTURE/boot-id"
  run bash "$HEALTH_SCRIPT"
  [ "$status" -eq 0 ]
  assert_state rolled_back
  [ "$("$BOOT_STATE_BIN" get-left B)" = 0 ]
  jq -e --arg sha "$EXPECTED_SHA" 'length == 1 and .[0].deb_sha256 == $sha' "$FIXTURE/state/kernel-quarantine.json"
}

@test "crash after health mark good settles through the already confirmed fast path" {
  bash "$ACTIVATE_SCRIPT" --arm
  bash "$ACTIVATE_SCRIPT" --now
  boot_target
  run env CRASH_BOUNDARY=after-mark-good bash "$HEALTH_SCRIPT"
  [ "$status" -eq 137 ]
  assert_state activated
  [ -s "$CERALIVE_HEALTHY_STATE_FILE" ]
  snapshot after-mark-good
  run bash "$HEALTH_SCRIPT"
  [ "$status" -eq 0 ]
  assert_state succeeded
  [ "$(grep -c 'mark-good B' "$FIXTURE/calls")" = 1 ]
  jq -e '.status == "confirmed"' "$FIXTURE/state/slot-overlay-B.json"
}

@test "crash immediately after mark good retries normal checks before confirming" {
  bash "$ACTIVATE_SCRIPT" --arm
  bash "$ACTIVATE_SCRIPT" --now
  boot_target
  run env CRASH_BOUNDARY=after-mark-good-before-marker bash "$HEALTH_SCRIPT"
  [ "$status" -eq 137 ]
  assert_state activated
  [ ! -e "$CERALIVE_HEALTHY_STATE_FILE" ]
  [ ! -e "$CERALIVE_HEALTHCHECK_MARKER" ]
  run bash "$HEALTH_SCRIPT"
  [ "$status" -eq 0 ]
  assert_state succeeded
  [ "$(grep -c 'mark-good B' "$FIXTURE/calls")" = 2 ]
  jq -e '.status == "confirmed"' "$FIXTURE/state/slot-overlay-B.json"
}

@test "wrong running release cannot mark good or publish healthy state" {
  bash "$ACTIVATE_SCRIPT" --arm
  bash "$ACTIVATE_SCRIPT" --now
  boot_target
  : >"$FIXTURE/calls"
  run env RUNNING_RELEASE=7.3.0-ceralive-rk3588 bash "$HEALTH_SCRIPT"
  [ "$status" -ne 0 ]
  [ ! -s "$FIXTURE/calls" ]
  [ ! -e "$CERALIVE_HEALTHY_STATE_FILE" ]
  assert_state activated
  snapshot wrong-release
}

@test "wrong installed package version cannot mark good or publish healthy state" {
  bash "$ACTIVATE_SCRIPT" --arm
  bash "$ACTIVATE_SCRIPT" --now
  boot_target
  : >"$FIXTURE/calls"
  run env INSTALLED_VERSION=7.2.0-ceralive1 bash "$HEALTH_SCRIPT"
  [ "$status" -ne 0 ]
  [ ! -s "$FIXTURE/calls" ]
  [ ! -e "$CERALIVE_HEALTHY_STATE_FILE" ]
}

@test "identity prerequisite also runs before an already confirmed marker exit" {
  bash "$ACTIVATE_SCRIPT" --arm
  bash "$ACTIVATE_SCRIPT" --now
  boot_target
  run env CRASH_BOUNDARY=after-mark-good bash "$HEALTH_SCRIPT"
  [ "$status" -eq 137 ]
  cp "$CERALIVE_HEALTHY_STATE_FILE" "$FIXTURE/healthy-before"
  : >"$FIXTURE/calls"
  run env RUNNING_RELEASE=wrong bash "$HEALTH_SCRIPT"
  [ "$status" -ne 0 ]
  assert_state activated
  [ ! -s "$FIXTURE/calls" ]
  cmp "$FIXTURE/healthy-before" "$CERALIVE_HEALTHY_STATE_FILE"
}

@test "three failed selector boots quarantine without resetting the target budget" {
  bash "$ACTIVATE_SCRIPT" --arm
  bash "$ACTIVATE_SCRIPT" --now
  for left in 2 1 0; do
    run "$BOOT_STATE_BIN" boot-select
    [ "$status" -eq 0 ]
    [[ "$output" == B* ]]
    [ "$("$BOOT_STATE_BIN" get-left B)" = "$left" ]
  done
  run "$BOOT_STATE_BIN" boot-select
  [[ "$output" == A* ]]
  printf 'dddddddd-dddd-4ddd-8ddd-dddddddddddd\n' >"$FIXTURE/boot-id"
  run bash "$HEALTH_SCRIPT"
  [ "$status" -eq 0 ]
  assert_state rolled_back
  [ "$("$BOOT_STATE_BIN" get-left B)" = 0 ]
  [ "$("$BOOT_STATE_BIN" get-primary)" = A ]
  jq -e 'length == 1' "$FIXTURE/state/kernel-quarantine.json"
  run bash -c 'source "$1"; gate_kernel_pending' _ "$ROOT/mkosi/runtime/ceralive-slot-sync.sh"
  [ "$status" -eq 0 ]
  snapshot rolled-back
}

@test "terminal succeeded crash repairs pending overlay after acknowledgement and restart" {
  bash "$ACTIVATE_SCRIPT" --arm
  bash "$ACTIVATE_SCRIPT" --now
  boot_target
  run env CRASH_BOUNDARY=after-terminal-succeeded bash "$HEALTH_SCRIPT"
  [ "$status" -eq 137 ]
  assert_state succeeded
  jq -e '.status == "pending"' "$FIXTURE/state/slot-overlay-B.json"
  jq '.acknowledged = true' "$FIXTURE/state/kernel-state.json" >"$FIXTURE/ack"
  mv "$FIXTURE/ack" "$FIXTURE/state/kernel-state.json"
  run bash "$HEALTH_SCRIPT"
  [ "$status" -eq 0 ]
  jq -e '.status == "confirmed"' "$FIXTURE/state/slot-overlay-B.json"
  jq -e '.acknowledged and .package and .timestamps.staged' "$FIXTURE/state/kernel-state.json"
  [ "$(grep -c 'mark-good B' "$FIXTURE/calls")" = 1 ]
}

@test "terminal rolled back crash repairs quarantine after acknowledgement idempotently" {
  bash "$ACTIVATE_SCRIPT" --arm
  bash "$ACTIVATE_SCRIPT" --now
  "$BOOT_STATE_BIN" set-state B bad
  printf 'dddddddd-dddd-4ddd-8ddd-dddddddddddd\n' >"$FIXTURE/boot-id"
  run env CRASH_BOUNDARY=after-terminal-rolled-back bash "$HEALTH_SCRIPT"
  [ "$status" -eq 137 ]
  assert_state rolled_back
  [ ! -e "$FIXTURE/state/kernel-quarantine.json" ]
  jq '.acknowledged = true' "$FIXTURE/state/kernel-state.json" >"$FIXTURE/ack"
  mv "$FIXTURE/ack" "$FIXTURE/state/kernel-state.json"
  bash "$HEALTH_SCRIPT"
  bash "$HEALTH_SCRIPT"
  jq -e 'length == 1' "$FIXTURE/state/kernel-quarantine.json"
  [ "$("$BOOT_STATE_BIN" get-left B)" = 0 ]
}

@test "atomic writer keeps old complete JSON on file sync failure and ignores stale temps" {
  run bash -c '
    source "$CERALIVE_KERNEL_STATE_LIB"
    file="$FIXTURE/state/atomic.json"
    kernel_atomic_write "$file" "{\"old\":true}" || exit
    printf "torn" >"$file.tmp.leftover"
    SYNC_BIN=false
    kernel_atomic_write "$file" "{\"new\":true}" && exit 90
    [[ "$(<"$file")" == "{\"old\":true}" ]] || exit 91
    SYNC_BIN="$REAL_SYNC"
    kernel_atomic_write "$file" "{\"new\":true}" || exit
    [[ "$(<"$file")" == "{\"new\":true}" ]] || exit 92
    [[ "$(stat -c %a "$file")" == 600 ]]
  '
  [ "$status" -eq 0 ]
}
