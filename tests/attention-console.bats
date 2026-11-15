#!/usr/bin/env bats
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}
@test "attention console: unchanged fatal survives startup repaint on its own VT" {
  run python3 "$ROOT/tests/attention-console.test.py" ConsoleTests.test_startup_getty_and_unchanged_fatal ConsoleTests.test_watch_repaints_every_tick_and_releases_on_stop
  [ "$status" -eq 0 ]
}
@test "attention console: clear/expiry restores text, font and previous VT" {
  run python3 "$ROOT/tests/attention-console.test.py" ConsoleTests.test_info_clear_restores_font_and_login ConsoleTests.test_return_to_previous_vt_on_critical_clear_and_stop ConsoleTests.test_failed_save_never_changes_font_and_failed_restore_retries ConsoleTests.test_failed_switch_keeps_message_and_shortcut_until_retry
  [ "$status" -eq 0 ]
}
@test "attention console: login stays reachable through critical and process restart" {
  run python3 "$ROOT/tests/attention-console.test.py" ConsoleTests.test_login_remains_reachable_and_not_stolen ConsoleTests.test_restart_keeps_original_snapshot_and_does_not_steal_login ConsoleTests.test_warning_has_no_console_effect_and_long_detail_keeps_shortcut
  [ "$status" -eq 0 ]
}
@test "attention console: unit reserves VT8 and starts independent rescue gettys first" {
  run python3 - "$ROOT" <<'PY'
from pathlib import Path
import configparser
import sys
root=Path(sys.argv[1])
unit=configparser.ConfigParser()
unit.read(root/'mkosi/runtime/ceralive-attention.service')
for login in ('getty@tty1.service','getty@tty2.service'):
    assert login in unit['Unit']['Wants'].split()
    assert login in unit['Unit']['After'].split()
for reserved in ('getty@tty8.service','autovt@tty8.service'):
    assert reserved in unit['Unit']['Conflicts'].split()
    assert reserved in unit['Unit']['Before'].split()
assert unit['Service']['RuntimeDirectoryPreserve']=='restart'
PY
  [ "$status" -eq 0 ]
}
