#!/usr/bin/env bats
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"; }
@test "power button: taps only show status, including while live" {
  run python3 "$ROOT/tests/power-button-contract.py" Gestures.test_taps
  [ "$status" -eq 0 ]
}
@test "power button: double press confirms once and requests are exclusive" {
  run python3 "$ROOT/tests/power-button-contract.py" Gestures.test_confirm
  [ "$status" -eq 0 ]
}
@test "power button: bounded double window, timeout and cancellation" {
  run python3 "$ROOT/tests/power-button-contract.py" Gestures.test_windows
  [ "$status" -eq 0 ]
}
@test "power button: release cancels and only full hold shuts down while live" {
  run python3 "$ROOT/tests/power-button-contract.py" Gestures.test_holds Gestures.test_releasable_inhibitor_child
  [ "$status" -eq 0 ]
}
@test "power button: fake evdev handles partial records, repeats and loss" {
  run python3 "$ROOT/tests/power-button-contract.py" Gestures.test_decoder
  [ "$status" -eq 0 ]
}
@test "power button: real local socket ownership, one-shot, TTL and validation" {
  run python3 "$ROOT/tests/power-button-contract.py" Socket.test_socket
  [ "$status" -eq 0 ]
}
@test "power button: both installers, runtime dependency and exclusive hold owner" {
  grep -q 'setup_power_button' "$ROOT/mkosi/customize/services.sh"
  grep -q 'setup_power_button' "$ROOT/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"
  grep -q '^python3 ' "$ROOT/manifests/packages/shared.list"
  grep -q 'HandlePowerKey=ignore' "$ROOT/mkosi/runtime/power-button/60-ceralive-button.conf"
  grep -q 'HandlePowerKeyLongPress=poweroff' "$ROOT/mkosi/runtime/power-button/60-ceralive-button.conf"
  grep -q "'--what=handle-power-key'" "$ROOT/mkosi/runtime/power-button/button.py"
  grep -qx 'ExecStart=/usr/bin/python3 /usr/local/lib/ceralive-button/button.py' "$ROOT/mkosi/runtime/power-button/ceralive-button.service"
  grep -q 'version.*-ge 251' "$ROOT/mkosi/customize/postinst.d/services.sh"
}
@test "power button: installer stages policy and rejects older systemd" {
  run bash -e -c '
    source "$1/mkosi/customize/postinst-lib.sh"
    CERALIVE_RUNTIME_SRC="$1/mkosi/runtime"
    target="$2"
    systemd() { echo "systemd ${VERSION}"; }
    install() {
      local args=("$@") last=$(($# - 1))
      args[$last]="$target${args[$last]}"
      command install "${args[@]}"
    }
    enable_service() { echo "$1" > "$target/enabled"; }
    VERSION=257 setup_power_button
    cmp "$1/mkosi/runtime/power-button/button.py" "$target/usr/local/lib/ceralive-button/button.py"
    grep -qx ceralive-button.service "$target/enabled"
    test "$(stat -c %a "$target/etc/systemd/logind.conf.d/60-ceralive-button.conf")" = 644
    VERSION=250 setup_power_button
  ' bash "$ROOT" "$BATS_TEST_TMPDIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"power button requires systemd >=251"* ]]
}

@test "power button: queued evdev timestamps cannot bypass request or double window" {
  run python3 "$ROOT/tests/power-button-contract.py" Gestures.test_queued_events
  [ "$status" -eq 0 ]
}

@test "power button: scheduling pauses, batch boundaries and key-state uncertainty fail closed" {
  run python3 "$ROOT/tests/power-button-contract.py" Socket.test_pause_between_read_and_tick Socket.test_split_batches Socket.test_current_key_released Socket.test_uncertain_key_state Socket.test_observed_hold
  [ "$status" -eq 0 ]
}
@test "power button: both tap edges follow admission and delivery precedes expiry" {
  run python3 "$ROOT/tests/power-button-contract.py" Gestures.test_pre_admission_press Gestures.test_delayed_confirmation Gestures.test_final_confirmation_deadline
  [ "$status" -eq 0 ]
}

@test "power button: persistent query faults hand ownership back and expose failed state" {
  run python3 "$ROOT/tests/power-button-contract.py" Socket.test_persistent_ioctl_failure_relinquishes_ownership
  [ "$status" -eq 0 ]
}
