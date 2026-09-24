#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export CERALIVE_HEALTHCHECK_CONF="$BATS_TEST_TMPDIR/update.conf"
  export CERALIVE_HEALTHCHECK_MARKER="$BATS_TEST_TMPDIR/.slot-marked-good"
  export CERALIVE_HEALTHCHECK_BOOT_ID_FILE="$BATS_TEST_TMPDIR/boot_id"
  export CERALIVE_BOOT_STATE_FILE="$BATS_TEST_TMPDIR/boot_state.txt"
  export TEST_STATE_HELPER="$ROOT/mkosi/platform/boot/ceralive-boot-state.sh"
  export TEST_SLOT=B
  export TEST_CALLS="$BATS_TEST_TMPDIR/calls"
  export RAUC_BIN="$BATS_TEST_TMPDIR/rauc"
  export SYSTEMCTL_BIN="$BATS_TEST_TMPDIR/systemctl"
  export CERASTREAM_BIN="$BATS_TEST_TMPDIR/encoder"
  export SRTLA_SEND_BIN="$BATS_TEST_TMPDIR/sender"
  export CURL_BIN=true
  export DPKG_BIN="$BATS_TEST_TMPDIR/dpkg"
  export CERALIVE_DPKG_STATUS_FILE="$BATS_TEST_TMPDIR/status"
  export CERALIVE_DPKG_UPDATES_DIR="$BATS_TEST_TMPDIR/updates"
  export CERALIVE_DPKG_RECOVERED="$BATS_TEST_TMPDIR/dpkg-recovered"
  export CERALIVE_PARTLABEL_FAILURE="$BATS_TEST_TMPDIR/partlabel-guard.failed"
  export CERALIVE_HEALTHY_STATE_FILE="$BATS_TEST_TMPDIR/healthy-state.json"
  export CERALIVE_OS_RELEASE_FILE="$BATS_TEST_TMPDIR/os-release"
  export CERALIVE_HEALTHCHECK_CMDLINE_FILE="$BATS_TEST_TMPDIR/cmdline"
  export CERALIVE_DEBUG_MARKER="$BATS_TEST_TMPDIR/debug-image"
  export CERALIVE_FORCE_HEALTHCHECK_FAIL="$BATS_TEST_TMPDIR/force-healthcheck-fail"
  printf 'BUILD_ID="image-27"\n' > "$CERALIVE_OS_RELEASE_FILE"
  printf 'root=PARTLABEL=rootfs_b cera_slot=B\n' > "$CERALIVE_HEALTHCHECK_CMDLINE_FILE"
  printf 'Package: ceralive-device\nStatus: install ok installed\n' > "$CERALIVE_DPKG_STATUS_FILE"
  mkdir -p "$CERALIVE_DPKG_UPDATES_DIR"
  printf 'HEALTHCHECK_TIMEOUT=0\n' > "$CERALIVE_HEALTHCHECK_CONF"
  printf '847ee4ac-0b00-4043-8d1b-5a5e1eb5b930\n' > "$CERALIVE_HEALTHCHECK_BOOT_ID_FILE"
  printf 'marked-good 2026-07-19T17:06:10Z\n' > "$CERALIVE_HEALTHCHECK_MARKER"
  : > "$TEST_CALLS"
  cat > "$RAUC_BIN" <<'SH'
#!/bin/bash
[[ "$*" == 'status mark-good' ]] || exit 90
printf 'mark-good %s\n' "$TEST_SLOT" >> "$TEST_CALLS"
[[ ${TEST_RAUC_FAIL:-0} == 0 ]] || exit 1
bash "$TEST_STATE_HELPER" set-state "$TEST_SLOT" good
SH
  cat > "$SYSTEMCTL_BIN" <<'SH'
#!/bin/bash
printf 'check-service\n' >> "$TEST_CALLS"
exit "${TEST_SERVICE_FAIL:-0}"
SH
  cat > "$DPKG_BIN" <<'SH'
#!/bin/bash
case "$*" in
  '--audit')
    printf 'audit\n' >> "$TEST_CALLS"
    [[ ${TEST_DPKG_BAD:-0} == 0 ]] || { printf 'broken package\n'; exit 1; }
    ;;
  '--configure -a')
    printf 'configure\n' >> "$TEST_CALLS"
    [[ ${TEST_CONFIGURE_FAIL:-0} == 0 ]] || exit 1
    rm -f "$CERALIVE_DPKG_UPDATES_DIR"/*
    ;;
  *) exit 90 ;;
esac
SH
  cat > "$CERASTREAM_BIN" <<'SH'
#!/bin/bash
printf 'check-encoder\n' >> "$TEST_CALLS"
if [[ ${TEST_ENCODER_FAIL:-0} == 1 ]]; then
  echo 'error while loading shared libraries: libsrt.so.1.5: cannot open shared object file'
  exit 127
fi
SH
  printf '#!/bin/bash\nexit 0\n' > "$SRTLA_SEND_BIN"
  chmod +x "$RAUC_BIN" "$SYSTEMCTL_BIN" "$CERASTREAM_BIN" "$SRTLA_SEND_BIN" "$DPKG_BIN"
  bash "$TEST_STATE_HELPER" init
  bash "$TEST_STATE_HELPER" set-state B bad
}

@test "broken dpkg refuses mark-good even when the current boot marker exists" {
  printf 'boot-id %s\n' "$(<"$CERALIVE_HEALTHCHECK_BOOT_ID_FILE")" > "$CERALIVE_HEALTHCHECK_MARKER"
  export TEST_DPKG_BAD=1
  run bash "$ROOT/mkosi/runtime/ceralive-healthcheck.sh"
  [ "$status" -ne 0 ]
  [ ! -e "$CERALIVE_HEALTHY_STATE_FILE" ]
  ! grep -q mark-good "$TEST_CALLS"
}

@test "pending dpkg updates or an unreadable audit refuses confirmation" {
  printf 'pending\n' > "$CERALIVE_DPKG_UPDATES_DIR/0000"
  run bash "$ROOT/mkosi/runtime/ceralive-healthcheck.sh"
  [ "$status" -ne 0 ]
  ! grep -q mark-good "$TEST_CALLS"
  rm "$CERALIVE_DPKG_UPDATES_DIR/0000" "$DPKG_BIN"
  run bash "$ROOT/mkosi/runtime/ceralive-healthcheck.sh"
  [ "$status" -ne 0 ]
  ! grep -q mark-good "$TEST_CALLS"
}

@test "dpkg audit reporting a broken package refuses mark-good and triggers recovery" {
  export TEST_DPKG_BAD=1
  run bash "$ROOT/mkosi/runtime/ceralive-healthcheck.sh"
  [ "$status" -ne 0 ]
  ! grep -q mark-good "$TEST_CALLS"
  run bash "$ROOT/mkosi/runtime/ceralive-dpkg-recover.sh"
  [ "$status" -ne 0 ]
  grep -Fxq configure "$TEST_CALLS"
  grep -Fxq 'result=failure' "$CERALIVE_DPKG_RECOVERED"
}

@test "partlabel marker refuses confirmation even on the boot marker fast path" {
  printf 'boot-id %s\n' "$(<"$CERALIVE_HEALTHCHECK_BOOT_ID_FILE")" > "$CERALIVE_HEALTHCHECK_MARKER"
  touch "$CERALIVE_PARTLABEL_FAILURE"
  run bash "$ROOT/mkosi/runtime/ceralive-healthcheck.sh"
  [ "$status" -ne 0 ]
  ! grep -q mark-good "$TEST_CALLS"
}

@test "healthy record follows mark-good with boot slot build and status hash" {
  run bash "$ROOT/mkosi/runtime/ceralive-healthcheck.sh"
  [ "$status" -eq 0 ]
  python3 - "$CERALIVE_HEALTHY_STATE_FILE" "$CERALIVE_DPKG_STATUS_FILE" "$CERALIVE_HEALTHCHECK_BOOT_ID_FILE" <<'PY'
import hashlib, json, pathlib, sys
record = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert set(record) == {'boot_id', 'slot', 'build_id', 'dpkg_status_sha256', 'recorded_at'}
assert record['boot_id'] == pathlib.Path(sys.argv[3]).read_text().strip()
assert record['slot'] == 'B' and record['build_id'] == 'image-27'
assert record['dpkg_status_sha256'] == hashlib.sha256(pathlib.Path(sys.argv[2]).read_bytes()).hexdigest()
assert record['recorded_at'].endswith('Z')
PY
  [ ! -e "$CERALIVE_HEALTHY_STATE_FILE.tmp" ]
}

@test "record falls back to the image's baked build commit when os-release lacks BUILD_ID" {
  printf 'VERSION_ID=13\n' > "$CERALIVE_OS_RELEASE_FILE"
  export CERALIVE_IMAGE_VERSION_FILE="$BATS_TEST_TMPDIR/image-build-commit"
  printf 'd92a84b8284541bc34bf0118662fad769bd80466\n' > "$CERALIVE_IMAGE_VERSION_FILE"
  run bash "$ROOT/mkosi/runtime/ceralive-healthcheck.sh"
  [ "$status" -eq 0 ]
  grep -Fq '"build_id":"d92a84b8284541bc34bf0118662fad769bd80466"' "$CERALIVE_HEALTHY_STATE_FILE"
  grep -Fq '/etc/ceralive/image-build-commit' "$ROOT/mkosi/runtime/ceralive-slot-sync.sh"
}

@test "failed mark-good never writes healthy state" {
  export TEST_RAUC_FAIL=1
  run bash "$ROOT/mkosi/runtime/ceralive-healthcheck.sh"
  [ "$status" -ne 0 ]
  [ ! -e "$CERALIVE_HEALTHY_STATE_FILE" ]
}

@test "debug force-fail requires BOTH markers; either marker alone is inert" {
  touch "$CERALIVE_FORCE_HEALTHCHECK_FAIL"
  run bash "$ROOT/mkosi/runtime/ceralive-healthcheck.sh"
  [ "$status" -eq 0 ]
  rm "$CERALIVE_FORCE_HEALTHCHECK_FAIL" "$CERALIVE_HEALTHCHECK_MARKER"
  touch "$CERALIVE_DEBUG_MARKER"
  run bash "$ROOT/mkosi/runtime/ceralive-healthcheck.sh"
  [ "$status" -eq 0 ]
  rm "$CERALIVE_HEALTHCHECK_MARKER"
  touch "$CERALIVE_FORCE_HEALTHCHECK_FAIL"
  : > "$TEST_CALLS"
  run bash "$ROOT/mkosi/runtime/ceralive-healthcheck.sh"
  [ "$status" -ne 0 ]
  ! grep -q mark-good "$TEST_CALLS"
}

@test "dpkg recovery skips clean state, repairs pending state, and records failure" {
  local recover="$ROOT/mkosi/runtime/ceralive-dpkg-recover.sh"
  run bash "$recover"
  [ "$status" -eq 0 ]
  ! grep -q configure "$TEST_CALLS"
  touch "$CERALIVE_DPKG_UPDATES_DIR/0000"
  run bash "$recover"
  [ "$status" -eq 0 ]
  grep -Fxq configure "$TEST_CALLS"
  grep -Fxq 'result=success' "$CERALIVE_DPKG_RECOVERED"
  export TEST_CONFIGURE_FAIL=1
  touch "$CERALIVE_DPKG_UPDATES_DIR/0000"
  run bash "$recover"
  [ "$status" -ne 0 ]
  grep -Fxq 'result=failure' "$CERALIVE_DPKG_RECOVERED"
}

@test "recovery times out dpkg --configure -a at exactly 600 seconds" {
  grep -Fq 'timeout 600s' "$ROOT/mkosi/runtime/ceralive-dpkg-recover.sh"
  grep -Fxq 'TimeoutStartSec=610s' "$ROOT/mkosi/runtime/ceralive-dpkg-recover.service"
}

@test "dpkg recovery installer installs and enables the committed unit from configure_services" {
  local install_root="$BATS_TEST_TMPDIR/install"
  run bash -c '
    source "$1/mkosi/customize/postinst-lib.sh"
    setup_dpkg_recovery
  ' _ "$ROOT"
  [ "$status" -ne 0 ]
  run env CERALIVE_RUNTIME_SRC="$ROOT/mkosi/runtime" \
    CERALIVE_DPKG_RECOVER_UNIT_DIR="$install_root/units" \
    CERALIVE_DPKG_RECOVER_HELPER_DIR="$install_root/helpers" \
    TEST_ENABLE_LOG="$install_root/enabled" bash -c '
      source "$1/mkosi/customize/postinst-lib.sh"
      enable_service() { printf "%s\n" "$1" >"$TEST_ENABLE_LOG"; }
      setup_dpkg_recovery
    ' _ "$ROOT"
  [ "$status" -eq 0 ]
  cmp "$ROOT/mkosi/runtime/ceralive-dpkg-recover.service" "$install_root/units/ceralive-dpkg-recover.service"
  cmp "$ROOT/mkosi/runtime/ceralive-dpkg-recover.sh" "$install_root/helpers/ceralive-dpkg-recover"
  [ -x "$install_root/helpers/ceralive-dpkg-recover" ]
  grep -Fxq ceralive-dpkg-recover.service "$install_root/enabled"
  grep -Fq '  setup_dpkg_recovery' "$ROOT/mkosi/customize/postinst.d/services.sh"
}

@test "stale Rock marker cannot skip checks or leave current B budget exhausted" {
  run bash "$ROOT/mkosi/runtime/ceralive-healthcheck.sh"
  [ "$status" -eq 0 ]
  grep -Fxq check-service "$TEST_CALLS"
  grep -Fxq check-encoder "$TEST_CALLS"
  grep -Fxq 'mark-good B' "$TEST_CALLS"
  grep -Fxq BOOT_B_LEFT=3 "$CERALIVE_BOOT_STATE_FILE"
  grep -Fxq "boot-id $(cat "$CERALIVE_HEALTHCHECK_BOOT_ID_FILE")" "$CERALIVE_HEALTHCHECK_MARKER"
}

@test "stale marker cannot confirm a dead encoder" {
  export TEST_ENCODER_FAIL=1
  run bash "$ROOT/mkosi/runtime/ceralive-healthcheck.sh"
  [ "$status" -ne 0 ]
  run grep -q mark-good "$TEST_CALLS"
  [ "$status" -eq 1 ]
  grep -Fxq BOOT_B_LEFT=0 "$CERALIVE_BOOT_STATE_FILE"
}

@test "stale marker cannot confirm an inactive control service" {
  export TEST_SERVICE_FAIL=1
  run bash "$ROOT/mkosi/runtime/ceralive-healthcheck.sh"
  [ "$status" -ne 0 ]
  run grep -q mark-good "$TEST_CALLS"
  [ "$status" -eq 1 ]
}

@test "same boot is idempotent but a later boot of the same slot verifies again" {
  bash "$ROOT/mkosi/runtime/ceralive-healthcheck.sh"
  : > "$TEST_CALLS"
  run bash "$ROOT/mkosi/runtime/ceralive-healthcheck.sh"
  [ "$status" -eq 0 ]
  ! grep -qE 'check-service|mark-good' "$TEST_CALLS"
  printf '2d7b1750-d034-4d34-91e3-a1d4c7a71257\n' > "$CERALIVE_HEALTHCHECK_BOOT_ID_FILE"
  bash "$TEST_STATE_HELPER" set-state B bad
  run bash "$ROOT/mkosi/runtime/ceralive-healthcheck.sh"
  [ "$status" -eq 0 ]
  grep -Fxq check-encoder "$TEST_CALLS"
  grep -Fxq BOOT_B_LEFT=3 "$CERALIVE_BOOT_STATE_FILE"
}

@test "a previous B boot cannot confirm a later A boot" {
  bash "$ROOT/mkosi/runtime/ceralive-healthcheck.sh"
  export TEST_SLOT=A
  printf '2d7b1750-d034-4d34-91e3-a1d4c7a71257\n' > "$CERALIVE_HEALTHCHECK_BOOT_ID_FILE"
  bash "$TEST_STATE_HELPER" set-state A bad
  : > "$TEST_CALLS"
  run bash "$ROOT/mkosi/runtime/ceralive-healthcheck.sh"
  [ "$status" -eq 0 ]
  grep -Fxq 'mark-good A' "$TEST_CALLS"
  grep -Fxq BOOT_A_LEFT=3 "$CERALIVE_BOOT_STATE_FILE"
}

@test "a refused RAUC mark-good never refreshes the old marker" {
  export TEST_RAUC_FAIL=1
  run bash "$ROOT/mkosi/runtime/ceralive-healthcheck.sh"
  [ "$status" -ne 0 ]
  [ "$(cat "$CERALIVE_HEALTHCHECK_MARKER")" = 'marked-good 2026-07-19T17:06:10Z' ]
}

@test "unreadable boot identity cannot treat a persistent marker as current" {
  rm "$CERALIVE_HEALTHCHECK_BOOT_ID_FILE"
  run bash "$ROOT/mkosi/runtime/ceralive-healthcheck.sh"
  [ "$status" -ne 0 ]
  run grep -q mark-good "$TEST_CALLS"
  [ "$status" -eq 1 ]
}

@test "systemd must dispatch the boot-aware predicate even with a persistent marker" {
  run grep -Eq '^ConditionPathExists=.*slot-marked-good' "$ROOT/mkosi/runtime/ceralive-healthcheck.service"
  [ "$status" -eq 1 ]
  grep -Fxq Requires=ceralive.service "$ROOT/mkosi/runtime/ceralive-healthcheck.service"
}
