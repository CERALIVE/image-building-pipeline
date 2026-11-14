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
@test "update identity follows profile, including distinct Orange product slug" {
  UPDATE_BOARD=orange-pi-5-plus COMPATIBLE_STRING=ceralive-orangepi5-plus ARCH=arm64 write_board_identity "$BATS_TEST_TMPDIR/release" orangepi5-plus rk3588 os-updates
  grep -qx 'UPDATE_BOARD=orange-pi-5-plus' "$BATS_TEST_TMPDIR/release"
  grep -qx 'UPDATE_COMPATIBLE=ceralive-orangepi5-plus' "$BATS_TEST_TMPDIR/release"
  grep -qx 'KERNEL_ARCH=arm64' "$BATS_TEST_TMPDIR/release"
}
@test "future families carry kernel architecture without enabling updates" {
  for family in rk3566 bcm2711 bcm2712 x86_64 unknown; do
    ARCH=amd64 write_board_identity "$BATS_TEST_TMPDIR/$family" generic "$family" ''
    grep -qx 'UPDATE_BOARD=' "$BATS_TEST_TMPDIR/$family"
    grep -qx 'KERNEL_ARCH=amd64' "$BATS_TEST_TMPDIR/$family"
  done
}
@test "a new family resolves explicit update metadata without a build" {
  root="${BATS_TEST_DIRNAME}/.."
  cp "$BATS_TEST_DIRNAME/manifests/fixtures/valid-family.yaml" "$BATS_TEST_TMPDIR/rk3566.yaml"
  cp "$BATS_TEST_DIRNAME/manifests/fixtures/valid-board.yaml" "$BATS_TEST_TMPDIR/example.yaml"
  python3 - "$BATS_TEST_TMPDIR/example.yaml" <<'PY'
import sys,yaml
p=sys.argv[1]
v=yaml.safe_load(open(p))
v['family']='rk3566'
v['capabilities']=['os-updates']
with open(p,'w') as f: yaml.safe_dump(v,f)
PY
  run python3 "$root/lib/resolve.py" merge --family "$BATS_TEST_TMPDIR/rk3566.yaml" --board "$BATS_TEST_TMPDIR/example.yaml" --family-schema "$root/manifests/schema/family.schema.json" --board-schema "$root/manifests/schema/board.schema.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'FAMILY\trk3566'* ]]
  [[ "$output" == *$'UPDATE_BOARD\texample'* ]]
}
@test "production baselines declare the exact profile update slug" {
  for board in rock-5b-plus orange-pi-5-plus x86-minipc; do
    baseline="$BATS_TEST_DIRNAME/manifests/fixtures/production-baseline/$board.params"
    [ "$(grep -c '^UPDATE_BOARD=' "$baseline")" -eq 1 ]
    grep -qx "UPDATE_BOARD='$board'" "$baseline"
  done
}

@test "x86 resolver architecture writes the runtime record under errexit" {
  root="${BATS_TEST_DIRNAME}/.."
  run bash -euo pipefail -c '
    eval "$(bash "$1/lib/resolve.sh" x86-minipc)"
    [[ "$ARCH" == x86-64 ]]
    export COMPATIBLE_STRING="${COMPATIBLE_STRING:-ceralive-${BOARD_ID}}"
    source "$1/mkosi/customize/board-identity.sh"
    write_board_identity "$2" "$BOARD_ID" "$FAMILY" "$CAPABILITIES"
    [[ "$ARCH" == x86-64 ]]
  ' _ "$root" "$BATS_TEST_TMPDIR/release"
  [ "$status" -eq 0 ]
  grep -qx 'BOARD=x86-minipc' "$BATS_TEST_TMPDIR/release"
  grep -qx 'UPDATE_BOARD=x86-minipc' "$BATS_TEST_TMPDIR/release"
  grep -qx 'UPDATE_COMPATIBLE=ceralive-x86-minipc' "$BATS_TEST_TMPDIR/release"
  grep -qx 'KERNEL_ARCH=amd64' "$BATS_TEST_TMPDIR/release"
  [ "$(stat -c %a "$BATS_TEST_TMPDIR/release")" = 444 ]
}
@test "unsupported kernel architecture is rejected before opening the record" {
  run env ARCH='x86-64;id' bash -c '
    source "$1/mkosi/customize/board-identity.sh"
    write_board_identity "$2" x86-minipc x86_64 os-updates
  ' _ "${BATS_TEST_DIRNAME}/.." "$BATS_TEST_TMPDIR/release"
  [ "$status" -ne 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/release" ]
}
