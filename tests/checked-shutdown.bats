#!/usr/bin/env bats
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  export CALLS="$BATS_TEST_TMPDIR/calls"
  cat >"$BATS_TEST_TMPDIR/bin/systemctl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$CALLS"
exit "${SYSTEMCTL_STATUS:-0}"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/systemctl"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}
@test "planned reboot checks inhibitors without force or fallback" {
  run bash "$ROOT/mkosi/runtime/ceralive-power.sh" reboot
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = "reboot" ]
}
@test "planned shutdown checks inhibitors" {
  run bash "$ROOT/mkosi/runtime/ceralive-power.sh" poweroff
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = "poweroff" ]
}
@test "inhibited action is refused calmly and never retried" {
  export SYSTEMCTL_STATUS=1
  run bash "$ROOT/mkosi/runtime/ceralive-power.sh" reboot
  [ "$status" -eq 75 ]
  [[ "$output" == *"not restarted"* ]]
  [ "$(wc -l <"$CALLS")" -eq 1 ]
}
@test "unknown operation cannot submit a power action" {
  run bash "$ROOT/mkosi/runtime/ceralive-power.sh" --force
  [ "$status" -eq 64 ]
  [ ! -e "$CALLS" ]
}
@test "runtime assembly installs the checked power entrypoint" {
  export CERALIVE_RUNTIME_SRC="$ROOT/mkosi/runtime"
  export CERALIVE_POWER_HELPER_DIR="$BATS_TEST_TMPDIR/helpers"
  export CERALIVE_RAUC_ACTIVATE_UNIT_DIR="$BATS_TEST_TMPDIR/units"
  export CERALIVE_LOGIND_CONF_DIR="$BATS_TEST_TMPDIR/logind.conf.d"
  run bash -euc 'source "$1"; enable_service() { :; }; setup_power_policy' _ "$ROOT/mkosi/customize/postinst.d/services.sh"
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$CERALIVE_POWER_HELPER_DIR/ceralive-power")" = 755 ]
  cmp "$ROOT/mkosi/runtime/ceralive-power.sh" "$CERALIVE_POWER_HELPER_DIR/ceralive-power"
}
@test "disposable runner shutdown also checks inhibitors" {
  grep -Fq 'systemctl poweroff' "$ROOT/ci/kernel-runner/guest-job.sh"
}
@test "updater cannot autonomously bypass planned shutdown" {
  grep -Eq '^post_update_reboot[[:space:]]*=[[:space:]]*false' "$ROOT/mkosi/runtime/hawkbit-updater/config.conf"
}

@test "extra arguments cannot disable inhibitor checks" {
  run bash "$ROOT/mkosi/runtime/ceralive-power.sh" reboot --force
  [ "$status" -eq 64 ]
  [ ! -e "$CALLS" ]
}
@test "an unavailable shutdown command fails closed without fallback" {
  export SYSTEMCTL_STATUS=127
  run bash "$ROOT/mkosi/runtime/ceralive-power.sh" poweroff
  [ "$status" -eq 75 ]
  [[ "$output" == *"Shutdown command unavailable"* ]]
  [ "$(wc -l <"$CALLS")" -eq 1 ]
}
@test "interrupted power submission reports an uncertain result without retry" {
  export SYSTEMCTL_STATUS=143
  run bash "$ROOT/mkosi/runtime/ceralive-power.sh" reboot
  [ "$status" -eq 70 ]
  [[ "$output" == *"could not be confirmed"* ]]
  [ "$(wc -l <"$CALLS")" -eq 1 ]
}

@test "runtime assembly installs power-key safety policy for short and long presses" {
  export CERALIVE_RUNTIME_SRC="$ROOT/mkosi/runtime"
  export CERALIVE_POWER_HELPER_DIR="$BATS_TEST_TMPDIR/helpers"
  export CERALIVE_RAUC_ACTIVATE_UNIT_DIR="$BATS_TEST_TMPDIR/units"
  export CERALIVE_LOGIND_CONF_DIR="$BATS_TEST_TMPDIR/logind.conf.d"
  run bash -euc 'source "$1"; enable_service() { :; }; setup_power_policy' _ "$ROOT/mkosi/customize/postinst.d/services.sh"
  [ "$status" -eq 0 ]
  local policy="$CERALIVE_LOGIND_CONF_DIR/60-ceralive-power-key.conf"
  [ "$(stat -c %a "$policy")" = 644 ]
  grep -Fxq 'PowerKeyIgnoreInhibited=yes' "$policy"
  grep -Fxq 'HandlePowerKey=poweroff' "$policy"
  grep -Fxq 'HandlePowerKeyLongPress=poweroff' "$policy"
}

@test "TERM to the helper itself reports uncertainty and never retries" {
  cat >"$BATS_TEST_TMPDIR/bin/systemctl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$CALLS"
kill -TERM "$PPID"
exit 0
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/systemctl"
  run bash "$ROOT/mkosi/runtime/ceralive-power.sh" reboot
  [ "$status" -eq 70 ]
  [[ "$output" == *"could not be confirmed"* ]]
  [ "$(wc -l <"$CALLS")" -eq 1 ]
}
@test "power policy is wired independently of RAUC activation" {
  export CERALIVE_RUNTIME_SRC="$ROOT/mkosi/runtime"
  export CERALIVE_POWER_HELPER_DIR="$BATS_TEST_TMPDIR/helpers"
  export CERALIVE_LOGIND_CONF_DIR="$BATS_TEST_TMPDIR/logind.conf.d"
  run bash -euc '
    source "$1"
    for fn in $(declare -F | cut -d" " -f3) configure_debug_access configure_ssh_enablement setup_typec_policy setup_fan_curve setup_fan_kickstart setup_led_status setup_cpu_governor setup_hdmirx_edid setup_slot_sync setup_boot_script_sync; do
      case "$fn" in configure_services|setup_power_policy) ;; *) eval "$fn() { :; }" ;; esac
    done
    configure_services
  ' _ "$ROOT/mkosi/customize/postinst.d/services.sh"
  [ "$status" -eq 0 ]
  [ -f "$CERALIVE_LOGIND_CONF_DIR/60-ceralive-power-key.conf" ]
  [ -x "$CERALIVE_POWER_HELPER_DIR/ceralive-power" ]
}
