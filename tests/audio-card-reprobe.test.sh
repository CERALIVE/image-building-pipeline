#!/usr/bin/env bash
# Offline runtime boundary: only the selected card may receive remove/add events,
# only HDMI-IN may receive a change event, and no command may outlive the caller.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck source=tests/lib/assertions.sh
source "${HERE}/lib/assertions.sh"

# The helper, not the caller's umask, must make its own files private.
umask 022
TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP}"' EXIT
mkdir -p "${TMP}/bin" "${TMP}/sys" "${TMP}/run"
# HDMI-IN is not card3, and ids one edit away from it are found first. The last rows
# would be selectable if the id, index or complete-line checks were missing.
while IFS=: read -r card id; do
  mkdir "${TMP}/sys/${card}"
  printf '%s\n' "${id}" >"${TMP}/sys/${card}/id"
done <<'CARDS'
card0:Other
card1:HDMIIN2
card10:XHDMIIN
card11:hdmiin
card12:HDMIINX
card13:HDMIIN
card3:Decoy
card4:HDMIIN_1
card5:Cam-aaaaaaaaaaaaaaaaaaaaaaaaaaaa
card7:Capture_1
card15:a.b
card16:a b
card17:
card18:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
card1x:Suffixed
CARDS
mkdir "${TMP}/sys/card19" "${TMP}/sys/card2"
printf 'Partial' >"${TMP}/sys/card2/id"

# Every stub records what it is asked to do, even for a helper that cannot write files.
cat >"${TMP}/bin/udevadm" <<'SH'
#!/usr/bin/env bash
ulimit -S -f hard
point="${0##*/}"
[[ -n "${AUDIO_LIMITED:-}" ]] || printf 'no limit %s %s\n' "${point}" "$*" >>"${AUDIO_LIMITS}"
if [[ "${point}" == udevadm ]]; then
  point="${2#--action=}"
  printf '%s\n' "$*" >>"${AUDIO_CALLS}"
fi
if [[ "${AUDIO_BLOCK_AT:-}" == "${point}" ]]; then
  printf 'ready\n' >&8
  IFS= read -r _ <"${AUDIO_RELEASE}"
  printf 'late %s\n' "${point}" >>"${AUDIO_CALLS}"
fi
uptime="AUDIO_UPTIME_${point}"
case "${!uptime:-}" in
  '') ;;
  gone) /usr/bin/rm -- "${CERALIVE_AUDIO_UPTIME}" ;;
  *) printf '%s 0.00\n' "${!uptime}" >"${CERALIVE_AUDIO_UPTIME}" ;;
esac
case "${AUDIO_STUB_MODE:-ok}" in
  "fail-${point}") exit 7 ;;
  "hang-${point}") trap '' TERM; exec /usr/bin/sleep 60 ;;
esac
case "${point}" in
  date) [[ "$*" == +%s ]] || exit 9; printf '%s\n' "${AUDIO_NOW:-1700000000}"; exit ;;
  mkdir | flock) exec "/usr/bin/${point}" "$@" ;;
esac
case "${AUDIO_STUB_MODE:-ok}" in
  misleading) printf 'success\n'; exit 1 ;;
  hung) exec /usr/bin/tail -f /dev/null ;;
esac
SH
# Logs each limit with its whole command; AUDIO_LIMIT replaces the limit, never the flags.
cat >"${TMP}/bin/timeout" <<'SH'
#!/usr/bin/env bash
ulimit -S -f hard
args=() line=""
for arg in "$@"; do
  if [[ -n "${line}" ]]; then
    line+=" ${arg}"
  elif [[ "${arg}" =~ ^[0-9.]+s$ ]]; then
    line="${arg}"
    arg="${AUDIO_LIMIT:-${arg}}"
  fi
  args+=("${arg}")
done
printf '%s\n' "${line}" >>"${AUDIO_LIMITS}"
AUDIO_LIMITED=1 exec /usr/bin/timeout "${args[@]}"
SH
chmod +x "${TMP}/bin/udevadm" "${TMP}/bin/timeout"
for command in mkdir date flock; do cp -- "${TMP}/bin/udevadm" "${TMP}/bin/${command}"; done
# The helper's PATH holds only the stubs: a command of another name is recorded, then run.
ln -s "${BASH}" "${TMP}/bin/bash"
cat >"${TMP}/unlisted" <<'SH'
command_not_found_handle() {
  ulimit -S -f hard
  printf 'no limit %s\n' "$*" >>"${AUDIO_LIMITS}"
  /usr/bin/env "PATH=${PATH}:/usr/bin:/bin" "$@"
}
SH

helper=(bash "${ROOT}/mkosi/runtime/ceralive-audio-reprobe.sh")
settings=(PATH="${TMP}/bin" BASH_ENV="${TMP}/unlisted" AUDIO_CALLS="${TMP}/calls"
  AUDIO_LIMITS="${TMP}/limits" AUDIO_RELEASE="${TMP}/release"
  CERALIVE_AUDIO_SYSFS_ROOT="${TMP}/sys" CERALIVE_AUDIO_RUN_DIR="${TMP}/run"
  CERALIVE_AUDIO_UPTIME="${TMP}/uptime")

# The caller-shaped outer limit turns a missing inner limit into exit 137. Only a hang
# runs against the real inner limit, so a busy host cannot fail the other cases.
# No exit may leave a card lock behind; HELD is the one the test holds itself.
LEAKED="" HELD=""
run_helper() {
  local limit=30s lock result
  [[ "${MODE:-ok}" != @(hang-*|hung) ]] || limit=""
  env "${settings[@]}" AUDIO_STUB_MODE="${MODE:-ok}" AUDIO_LIMIT="${limit}" \
    /usr/bin/timeout --signal=KILL 10s "${helper[@]}" "$@" >"${TMP}/output" 2>&1
  result=$?
  for lock in "${TMP}/run/"*.lock; do
    [[ ! -e "${lock}" || "${lock}" == "${HELD}" ]] || flock -n "${lock}" true \
      || LEAKED+="${MODE:-ok} $* exit ${result}; "
  done
  return "${result}"
}

reset_state() {
  grep -s '^no limit' "${TMP}/limits" >>"${TMP}/unlimited"
  rm -rf -- "${TMP}/run"
  mkdir "${TMP}/run"
  : >"${TMP}/calls"
  : >"${TMP}/limits"
  printf '100.00 0.00\n' >"${TMP}/uptime"
  MODE=ok
}

events() { # <card> <action...>
  local action
  for action in "${@:2}"; do
    printf 'trigger --action=%s --subsystem-match=sound --sysname-match=%s\n' "${action}" "$1"
  done
}

limits() { # <limit...>: one for each command of an HDMI-IN run, in order
  printf '%s mkdir -p -- %s\n%s date +%%s\n%s flock -n 9\n' "$1" "${TMP}/run" "$2" "$3"
  printf '%s udevadm %s\n' "$4" "$(events card13 remove)" "$5" "$(events card13 add)" \
    "$6" "$(events card13 change)"
}

assert_unlocked() { # <label> <id>
  flock -n "${TMP}/run/audio-reprobe-$2.stamp.lock" true
  assert_eq "card lock is free after $1" 0 "$?"
}

reset_state
run_helper Capture_1
assert_eq "selected card reprobe succeeds" 0 "$?"
expected=$'trigger --action=remove --subsystem-match=sound --sysname-match=card7\ntrigger --action=add --subsystem-match=sound --sysname-match=card7'
assert_eq "matching card gets remove then add only" "${expected}" "$(<"${TMP}/calls")"
assert_eq "successful reprobe reports no error" "" "$(<"${TMP}/output")"
[[ -f "${TMP}/run/audio-reprobe-Capture_1.stamp" ]] \
  && ok "attempt creates the per-card volatile stamp" || bad "attempt stamp missing"
assert_eq "stamp is private to root" 600 "$(stat -c %a "${TMP}/run/audio-reprobe-Capture_1.stamp")"
assert_eq "lock is private to root" 600 "$(stat -c %a "${TMP}/run/audio-reprobe-Capture_1.stamp.lock")"

: >"${TMP}/calls"
run_helper Capture_1
[[ "$?" -ne 0 ]] && ok "immediate second attempt is refused" || bad "second attempt accepted"
assert_eq "rate limit makes no udevadm call" "" "$(<"${TMP}/calls")"
run_helper Other
assert_eq "another card has an independent rate limit" 0 "$?"
assert_eq "another card receives only its own remove/add" \
  $'trigger --action=remove --subsystem-match=sound --sysname-match=card0\ntrigger --action=add --subsystem-match=sound --sysname-match=card0' \
  "$(<"${TMP}/calls")"

# PipeWire ignores a re-added card until a change event sets SOUND_INITIALIZED.
reset_state
run_helper HDMIIN
assert_eq "HDMI-IN reprobe succeeds" 0 "$?"
assert_eq "HDMI-IN gets exactly one change after its add" \
  "$(events card13 remove add change)" "$(<"${TMP}/calls")"
for other in card1:HDMIIN2 card10:XHDMIIN card11:hdmiin card12:HDMIINX card3:Decoy card4:HDMIIN_1 \
  card5:Cam-aaaaaaaaaaaaaaaaaaaaaaaaaaaa; do
  reset_state
  run_helper "${other#*:}"
  assert_eq "${other#*:} reprobe succeeds" 0 "$?"
  assert_eq "${other#*:} gets remove/add on its own card and no change" \
    "$(events "${other%%:*}" remove add)" "$(<"${TMP}/calls")"
done

# The stub fails with 7, so exit 1 can only be the helper's own refusal.
commands=(mkdir date flock remove add change)
sent=()
for step in "${commands[@]}"; do
  [[ "${step}" != @(remove|add|change) ]] || sent+=("${step}")
  for mode in fail hang; do
    reset_state
    MODE="${mode}-${step}"
    run_helper HDMIIN
    assert_eq "HDMI-IN ${MODE} is refused by the helper itself" 1 "$?"
    assert_eq "HDMI-IN ${MODE} sends nothing after it" \
      "$(events card13 "${sent[@]}")" "$(<"${TMP}/calls")"
    [[ "${step}" != @(mkdir|date) ]] \
      || assert_eq "HDMI-IN ${MODE} never opens the card lock" "" "$(ls -A "${TMP}/run")"
  done
done

# Every command draws on one 1.50 s budget of the caller's 3 s.
reset_state
run_helper HDMIIN
assert_eq "every command the helper runs is limited" \
  "$(limits 1.50s 1.50s 1.50s 1.50s 1.50s 1.50s)" "$(<"${TMP}/limits")"
reset_state
AUDIO_UPTIME_mkdir=100.25 AUDIO_UPTIME_date=100.45 AUDIO_UPTIME_flock=100.70 \
  AUDIO_UPTIME_remove=101.00 AUDIO_UPTIME_add=101.45 run_helper HDMIIN
assert_eq "a slow reprobe inside the budget succeeds" 0 "$?"
assert_eq "later commands get only what is left" \
  "$(limits 1.50s 1.25s 1.05s 0.80s 0.50s 0.05s)" "$(<"${TMP}/limits")"
reset_state
rm -- "${TMP}/sys/card0/id"
mkfifo "${TMP}/sys/card0/id"
# The clock moves while the helper waits for the first card id.
(
  exec >"${TMP}/sys/card0/id"
  printf '100.40 0.00\n' >"${TMP}/uptime"
  printf 'Other\n'
) &
run_helper HDMIIN
assert_eq "the card lookup draws on the budget too" "1.10s mkdir -p -- ${TMP}/run" \
  "$(head -n 1 "${TMP}/limits")"
kill "$!" 2>/dev/null
wait "$!" 2>/dev/null
rm -- "${TMP}/sys/card0/id"
printf 'Other\n' >"${TMP}/sys/card0/id"
reset_state
printf '0.08 0.00\n' >"${TMP}/uptime"
AUDIO_UPTIME_mkdir=0.09 run_helper HDMIIN
assert_eq "clock digits are read as decimal" 0 "$?"
reset_state
AUDIO_UPTIME_add=101.50 run_helper HDMIIN
assert_eq "a spent budget is a failure" 1 "$?"
assert_eq "a spent budget sends no change" "$(events card13 remove add)" "$(<"${TMP}/calls")"
reset_state
AUDIO_UPTIME_date=101.50 run_helper HDMIIN
assert_eq "a budget spent before the triggers is a failure" 1 "$?"
assert_eq "a budget spent before the triggers sends none" "" "$(<"${TMP}/calls")"
reset_state
rm -- "${TMP}/uptime"
run_helper HDMIIN
assert_eq "an unreadable clock is a failure" 1 "$?"
assert_eq "an unreadable clock is reported by the helper" 1 "$(grep -c '^audio-reprobe: ' "${TMP}/output")"
assert_eq "an unreadable clock triggers nothing" "" "$(<"${TMP}/calls")"
assert_eq "an unreadable clock runs nothing and leaves the run directory empty" "" "$(<"${TMP}/limits")$(ls -A "${TMP}/run")"
reset_state
rm -- "${TMP}/uptime"
mkfifo "${TMP}/uptime"
# Written once and cut short: a second read would block until the caller's limit.
printf '100.00' >"${TMP}/uptime" &
run_helper HDMIIN
assert_eq "a truncated clock stops the run at its first read" 1 "$?"
kill "$!" 2>/dev/null
wait "$!" 2>/dev/null
rm -- "${TMP}/uptime"
reset_state
AUDIO_UPTIME_remove=gone run_helper HDMIIN
assert_eq "a clock lost during the run is a failure" 1 "$?"
assert_eq "a clock lost during the run is reported by the helper" 1 "$(grep -c '^audio-reprobe: ' "${TMP}/output")"
assert_eq "a clock lost during the run sends nothing more" "$(events card13 remove)" "$(<"${TMP}/calls")"
reset_state
cat /proc/uptime >"${TMP}/uptime"
run_helper HDMIIN
assert_eq "the kernel's own clock format is accepted" 0 "$?"

# start_blocked <step> <command...>: run it in the background until <step> is in flight.
# Its whole process tree holds `alive`, so end of file there means nothing is left.
# It also checks the card lock: a lock found free later proves nothing unless it was held.
start_blocked() {
  local held=0
  [[ "$1" != @(remove|add|change) ]] || held=1
  reset_state
  rm -f -- "${TMP}/alive" "${TMP}/release"
  mkfifo "${TMP}/alive" "${TMP}/release"
  exec 5<>"${TMP}/alive" 7<>"${TMP}/release"
  (
    export "${settings[@]}" AUDIO_BLOCK_AT="$1" AUDIO_LIMIT=30s
    exec "${@:2}" >"${TMP}/output" 2>&1 5>&- 7>&- 8>"${TMP}/alive"
  ) &
  pid=$!
  IFS= read -r -t 10 _ <&5
  assert_eq "$1 is in flight" 0 "$?"
  exec 6<"${TMP}/alive" 5>&-
  # A shared request is refused only while another process holds the lock exclusively.
  flock -n -s "${TMP}/run/audio-reprobe-HDMIIN.stamp.lock" true
  assert_eq "card lock is held exclusively during $1 (0 no, 1 yes)" "${held}" "$?"
}

assert_drained() { # <label>
  local result
  printf '\n' >&7
  IFS= read -r -t 10 _ <&6
  result=$?
  exec 6<&- 7>&-
  assert_eq "no process is left after $1" 1 "${result}"
}

sent=()
for step in "${commands[@]}"; do
  [[ "${step}" != @(remove|add|change) ]] || sent+=("${step}")
  # An expired caller's timeout kills the process group it leads, itself included.
  start_blocked "${step}" /usr/bin/timeout --signal=KILL 30s "${helper[@]}" HDMIIN
  kill -KILL -- "-${pid}"
  wait "${pid}" 2>/dev/null
  assert_eq "caller kill during ${step} ends the run" 137 "$?"
  assert_drained "a caller kill during ${step}"
  assert_eq "caller kill during ${step} leaves no late event" \
    "$(events card13 "${sent[@]}")" "$(<"${TMP}/calls")"
  assert_unlocked "a caller kill during ${step}" HDMIIN
  for signal in HUP:129 KILL:137 TERM:143; do
    start_blocked "${step}" "${helper[@]}" HDMIIN
    kill -s "${signal%:*}" "${pid}"
    wait "${pid}" 2>/dev/null
    assert_eq "SIG${signal%:*} during ${step} ends the helper" "${signal#*:}" "$?"
    assert_unlocked "SIG${signal%:*} during ${step}, with it still in flight" HDMIIN
    assert_drained "SIG${signal%:*} during ${step}"
    assert_eq "SIG${signal%:*} during ${step} lets only that command finish" \
      "$(events card13 "${sent[@]}"; printf 'late %s\n' "${step}")" "$(<"${TMP}/calls")"
  done
done

# A run that reaches the lock late must see the stamp of the run that overtook it.
start_blocked flock /usr/bin/timeout --signal=KILL 30s "${helper[@]}" HDMIIN
run_helper HDMIIN
assert_eq "a run that overtakes a paused one succeeds" 0 "$?"
assert_drained "the paused run"
wait "${pid}"
assert_eq "the overtaken run is refused" 1 "$?"
assert_unlocked "the overtaken run" HDMIIN
assert_eq "the two runs send one reprobe" \
  "$(events card13 remove add change)"$'\nlate flock' "$(<"${TMP}/calls")"

# The stamp is 60 s old for the second run, so only the lock can refuse it.
start_blocked remove /usr/bin/timeout --signal=KILL 30s "${helper[@]}" HDMIIN
HELD="${TMP}/run/audio-reprobe-HDMIIN.stamp.lock"
AUDIO_NOW=1700000060 run_helper HDMIIN
assert_eq "a run that meets one in flight is refused" 1 "$?"
assert_eq "a run that meets one in flight sends nothing" "$(events card13 remove)" "$(<"${TMP}/calls")"
HELD=""
assert_drained "the run in flight"
wait "${pid}"
assert_eq "the run in flight still succeeds" 0 "$?"
assert_unlocked "the run in flight" HDMIIN
assert_eq "the run in flight still sends its events" \
  "$(events card13 remove)"$'\nlate remove\n'"$(events card13 add change)" "$(<"${TMP}/calls")"

reset_state
exec 8>"${TMP}/run/audio-reprobe-Capture_1.stamp.lock"
flock -n 8
HELD="${TMP}/run/audio-reprobe-Capture_1.stamp.lock"
run_helper Capture_1
result="$?"
[[ "${result}" -ne 0 ]] && ok "concurrent attempt is refused" || bad "concurrent attempt accepted"
assert_eq "concurrent attempt is refused without waiting for the lock" 1 "${result}"
assert_eq "concurrent attempt triggers nothing" "" "$(<"${TMP}/calls")"
assert_eq "concurrent attempt records no stamp" audio-reprobe-Capture_1.stamp.lock "$(ls -A "${TMP}/run")"
flock -n "${HELD}" true
assert_eq "a refused attempt leaves the other run's lock held" 1 "$?"
flock -u 8
exec 8>&-
HELD=""

for invalid in '../../x' '' 'a.b' 'a b' "$(printf 'a%.0s' {1..33})" 'Unknown' 'Suffixed' 'Partial'; do
  reset_state
  run_helper "${invalid}"
  [[ "$?" -ne 0 ]] && ok "invalid or unknown id is refused" || bad "invalid id accepted"
  assert_eq "refused id makes no udevadm call" "" "$(<"${TMP}/calls")"
  assert_eq "refused id runs nothing and leaves the run directory empty" "" "$(<"${TMP}/limits")$(ls -A "${TMP}/run")"
done
reset_state
run_helper Capture_1 extra
[[ "$?" -ne 0 ]] && ok "extra arguments are refused" || bad "extra argument accepted"
assert_eq "extra argument makes no udevadm call" "" "$(<"${TMP}/calls")"
assert_eq "extra argument runs nothing and leaves the run directory empty" "" "$(<"${TMP}/limits")$(ls -A "${TMP}/run")"

for age in 29 30 31; do
  reset_state
  now=1700000000
  # Inject the previous attempt time; never wait for the throttle to expire.
  printf '%s\n' "$((now - age))" >"${TMP}/run/audio-reprobe-Capture_1.stamp"
  run_helper Capture_1
  result="$?"
  if (( age < 30 )); then
    [[ "${result}" -ne 0 ]] && ok "29-second stamp is refused" || bad "fresh stamp accepted"
    assert_eq "fresh stamp triggers nothing" "" "$(<"${TMP}/calls")"
  else
    assert_eq "expired stamp permits a new attempt" 0 "${result}"
    assert_eq "expired stamp reprobes selected card" "${expected}" "$(<"${TMP}/calls")"
  fi
done

# The next run must read the stamp this one writes. A refusal must not move it, and an
# accepted run must renew it.
reset_state
run_helper Capture_1
for age in 29:1 30:0 59:1 60:0; do
  AUDIO_NOW="$((now + ${age%:*}))" run_helper Capture_1
  assert_eq "${age%:*} s after the first run, a run exits ${age#*:}" "${age#*:}" "$?"
done
reset_state
printf '0%s\n' "$((now - 30))" >"${TMP}/run/audio-reprobe-Capture_1.stamp"
run_helper Capture_1
assert_eq "stamp digits are read as decimal" 0 "$?"

# 2^64 + 1 would wrap to a stamp long expired.
for stamp in corrupt 999999999999 '1 ' 18446744073709551617; do
  reset_state
  printf '%s\n' "${stamp}" >"${TMP}/run/audio-reprobe-Capture_1.stamp"
  run_helper Capture_1
  [[ "$?" -ne 0 ]] && ok "malformed or future stamp refuses recovery" || bad "unsafe stamp accepted"
  assert_eq "unsafe stamp triggers nothing" "" "$(<"${TMP}/calls")"
done
reset_state
printf '1' >"${TMP}/run/audio-reprobe-Capture_1.stamp"
run_helper Capture_1
assert_eq "a truncated stamp refuses recovery" 1 "$?"
assert_eq "a truncated stamp triggers nothing" "" "$(<"${TMP}/calls")"
reset_state
ln -s missing/stamp "${TMP}/run/audio-reprobe-Capture_1.stamp"
run_helper Capture_1
assert_eq "an unwritable stamp is a failure" 1 "$?"
assert_eq "an unwritable stamp triggers nothing" "" "$(<"${TMP}/calls")"
reset_state
# A file size limit of zero creates the stamp but fails its write, as a full /run does.
(trap '' XFSZ; ulimit -S -f 0; run_helper HDMIIN)
assert_eq "a failed stamp write is a failure" 1 "$?"
assert_eq "a failed stamp write triggers nothing" "" "$(<"${TMP}/calls")"
assert_eq "a failed stamp write leaves an empty stamp" 0 "$(stat -c %s "${TMP}/run/audio-reprobe-HDMIIN.stamp")"
assert_unlocked "a failed stamp write" HDMIIN
run_helper HDMIIN
assert_eq "an empty stamp does not refuse the next attempt" 0 "$?"
assert_eq "the attempt after a failed stamp write sends its events" \
  "$(events card13 remove add change)" "$(<"${TMP}/calls")"
: >"${TMP}/calls"
run_helper HDMIIN
assert_eq "the attempt after a failed stamp write is rate limited again" 1 "$?"
assert_eq "the rate limit after a failed stamp write sends nothing" "" "$(<"${TMP}/calls")"
reset_state
mkdir "${TMP}/run/audio-reprobe-Capture_1.stamp.lock"
# A descriptor 9 from the caller must not stand in for the lock.
run_helper Capture_1 9>"${TMP}/inherited"
assert_eq "an unopenable lock is a failure" 1 "$?"
assert_eq "an unopenable lock triggers nothing" "" "$(<"${TMP}/calls")"
reset_state
rm -rf -- "${TMP}/run"
: >"${TMP}/run"
run_helper Capture_1
assert_eq "an unusable run directory is a failure" 1 "$?"
assert_eq "an unusable run directory triggers nothing" "" "$(<"${TMP}/calls")"
rm -- "${TMP}/run"

for mode in fail-remove fail-add misleading hung; do
  reset_state
  MODE="${mode}"
  run_helper Capture_1
  [[ "$?" -ne 0 ]] && ok "${mode} is a failure" || bad "${mode} was reported as success"
  if [[ "${mode}" != fail-add ]]; then
    assert_eq "${mode} never sends add after failed remove" \
      "trigger --action=remove --subsystem-match=sound --sysname-match=card7" "$(<"${TMP}/calls")"
  fi
  : >"${TMP}/calls"
  run_helper Capture_1
  [[ "$?" -ne 0 ]] && ok "failed attempt remains rate limited" || bad "failed attempt bypassed limit"
  assert_eq "failed attempt cannot immediately retry udevadm" "" "$(<"${TMP}/calls")"
done

# The shared runtime directory keeps the caller's mode; only the helper's files are private.
rm -rf -- "${TMP}/run"
: >"${TMP}/calls"
MODE=ok
(umask 022; run_helper Capture_1)
assert_eq "helper creates the shared run directory" 0 "$?"
assert_unlocked "creating the shared run directory" Capture_1
assert_eq "shared run directory is not made private" 755 "$(stat -c %a "${TMP}/run")"

assert_eq "no helper exit leaves a card lock held" "" "${LEAKED}"
reset_state
assert_eq "no run starts a command without a limit" "" "$(<"${TMP}/unlimited")"
printf 'audio-card-reprobe: %s passed, %s failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
