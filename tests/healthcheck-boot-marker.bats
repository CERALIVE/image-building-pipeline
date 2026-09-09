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
  cat > "$CERASTREAM_BIN" <<'SH'
#!/bin/bash
printf 'check-encoder\n' >> "$TEST_CALLS"
if [[ ${TEST_ENCODER_FAIL:-0} == 1 ]]; then
  echo 'error while loading shared libraries: libsrt.so.1.5: cannot open shared object file'
  exit 127
fi
SH
  printf '#!/bin/bash\nexit 0\n' > "$SRTLA_SEND_BIN"
  chmod +x "$RAUC_BIN" "$SYSTEMCTL_BIN" "$CERASTREAM_BIN" "$SRTLA_SEND_BIN"
  bash "$TEST_STATE_HELPER" init
  bash "$TEST_STATE_HELPER" set-state B bad
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
  [ ! -s "$TEST_CALLS" ]
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
