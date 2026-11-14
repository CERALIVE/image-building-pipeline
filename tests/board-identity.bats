#!/usr/bin/env bats
setup() {
  source "${BATS_TEST_DIRNAME}/../mkosi/customize/board-identity.sh"
}
@test "board record is data-only, profile-driven and read-only" {
  write_board_identity "$BATS_TEST_TMPDIR/release" example-board bcm2712 'client-internet wifi-country'
  grep -qx 'BOARD=example-board' "$BATS_TEST_TMPDIR/release"
  grep -qx 'FAMILY=bcm2712' "$BATS_TEST_TMPDIR/release"
  grep -qx 'CAPABILITIES="client-internet wifi-country"' "$BATS_TEST_TMPDIR/release"
  [ "$(stat -c %a "$BATS_TEST_TMPDIR/release")" = 444 ]
}
@test "invalid identity never writes a record" {
  run write_board_identity "$BATS_TEST_TMPDIR/release" '$(id)' bcm2712 'client-internet'
  [ "$status" -ne 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/release" ]
}
@test "empty hardware capabilities do not invent hardware" {
  write_board_identity "$BATS_TEST_TMPDIR/release" generic x86_64 ''
  grep -qx 'CAPABILITIES=""' "$BATS_TEST_TMPDIR/release"
}
@test "board profiles resolve their declared capabilities for mkosi" {
  for board in rock-5b-plus orange-pi-5-plus x86-minipc; do
    run bash "${BATS_TEST_DIRNAME}/../lib/resolve.sh" "$board"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CAPABILITIES="*"client-internet"* ]]
    [[ "$output" == *"CAPABILITIES="*"hw-encoder"* ]]
    if [ "$board" = x86-minipc ]; then
      [[ "$output" != *"hdmi-rx"* ]]
      [[ "$output" != *"b-key-modem"* ]]
    else
      [[ "$output" == *"hdmi-rx"* ]]
      if [ "$board" = rock-5b-plus ]; then
        [[ "$output" == *"b-key-modem"* ]]
      else
        [[ "$output" != *"b-key-modem"* ]]
      fi
    fi
  done
}
@test "capability injection is rejected before opening destination" {
  run write_board_identity "$BATS_TEST_TMPDIR/release" generic generic 'client-internet"$(id)'
  [ "$status" -ne 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/release" ]
}
@test "mkosi forwards capabilities and both writers use the shared contract" {
  root="${BATS_TEST_DIRNAME}/.."
  grep -q 'BOARD_ID FAMILY CAPABILITIES SERIAL_CONSOLE' "$root/lib/orchestrate.sh"
  grep -q '^PassEnvironment=.*BOARD_ID FAMILY CAPABILITIES' "$root/mkosi/mkosi.conf"
  for entry in customize/structure.sh mkosi.images/runtime/mkosi.postinst.chroot; do
    grep -q 'source .*board-identity.sh' "$root/mkosi/$entry"
    grep -q 'write_board_identity /etc/ceralive/release.*BOARD_ID.*FAMILY.*CAPABILITIES' "$root/mkosi/$entry"
  done
}
@test "a profile without capabilities emits an empty grant rather than inheriting environment" {
  run python3 "${BATS_TEST_DIRNAME}/../lib/resolve.py" merge \
    --family "${BATS_TEST_DIRNAME}/manifests/fixtures/valid-family.yaml" \
    --board "${BATS_TEST_DIRNAME}/manifests/fixtures/valid-board.yaml" \
    --family-schema "${BATS_TEST_DIRNAME}/../manifests/schema/family.schema.json" \
    --board-schema "${BATS_TEST_DIRNAME}/../manifests/schema/board.schema.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'CAPABILITIES\t'* ]]
}
