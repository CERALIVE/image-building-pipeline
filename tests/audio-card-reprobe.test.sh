#!/usr/bin/env bash
# Offline runtime boundary: only the selected card may receive remove/add events.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck source=tests/lib/assertions.sh
source "${HERE}/lib/assertions.sh"

TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP}"' EXIT
mkdir -p "${TMP}/bin" "${TMP}/sys/card0" "${TMP}/sys/card7" "${TMP}/run"
printf 'Other\n' >"${TMP}/sys/card0/id"
printf 'Capture_1\n' >"${TMP}/sys/card7/id"
cat >"${TMP}/bin/udevadm" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${AUDIO_CALLS}"
case "${AUDIO_STUB_MODE:-ok}" in
  fail-remove) [[ "$*" != *--action=remove* ]] ;;
  fail-add) [[ "$*" != *--action=add* ]] ;;
  misleading) printf 'success\n'; exit 1 ;;
  hung) exec tail -f /dev/null ;;
esac
SH
printf '#!/bin/sh\nprintf "1700000000\\n"\n' >"${TMP}/bin/date"
chmod +x "${TMP}/bin/udevadm" "${TMP}/bin/date"

run_helper() {
  env PATH="${TMP}/bin:$PATH" AUDIO_CALLS="${TMP}/calls" \
    AUDIO_STUB_MODE="${MODE:-ok}" \
    CERALIVE_AUDIO_SYSFS_ROOT="${TMP}/sys" CERALIVE_AUDIO_RUN_DIR="${TMP}/run" \
    bash "${ROOT}/mkosi/runtime/ceralive-audio-reprobe.sh" "$@" \
    >"${TMP}/output" 2>&1
}

reset_state() {
  rm -f -- "${TMP}/run/"*
  : >"${TMP}/calls"
  MODE=ok
}

reset_state
run_helper Capture_1
assert_eq "selected card reprobe succeeds" 0 "$?"
expected=$'trigger --action=remove --subsystem-match=sound --sysname-match=card7\ntrigger --action=add --subsystem-match=sound --sysname-match=card7'
assert_eq "matching card gets remove then add only" "${expected}" "$(<"${TMP}/calls")"
[[ -f "${TMP}/run/audio-reprobe-Capture_1.stamp" ]] \
  && ok "attempt creates the per-card volatile stamp" || bad "attempt stamp missing"
assert_eq "stamp is private to root" 600 "$(stat -c %a "${TMP}/run/audio-reprobe-Capture_1.stamp")"

: >"${TMP}/calls"
run_helper Capture_1
[[ "$?" -ne 0 ]] && ok "immediate second attempt is refused" || bad "second attempt accepted"
assert_eq "rate limit makes no udevadm call" "" "$(<"${TMP}/calls")"
run_helper Other
assert_eq "another card has an independent rate limit" 0 "$?"
assert_eq "another card receives only its own remove/add" \
  $'trigger --action=remove --subsystem-match=sound --sysname-match=card0\ntrigger --action=add --subsystem-match=sound --sysname-match=card0' \
  "$(<"${TMP}/calls")"

reset_state
exec 8>"${TMP}/run/audio-reprobe-Capture_1.stamp.lock"
flock -n 8
run_helper Capture_1
[[ "$?" -ne 0 ]] && ok "concurrent attempt is refused" || bad "concurrent attempt accepted"
assert_eq "concurrent attempt triggers nothing" "" "$(<"${TMP}/calls")"
flock -u 8
exec 8>&-

for invalid in '../../x' '' 'a.b' 'a b' "$(printf 'a%.0s' {1..33})" 'Unknown'; do
  reset_state
  run_helper "${invalid}"
  [[ "$?" -ne 0 ]] && ok "invalid or unknown id is refused" || bad "invalid id accepted"
  assert_eq "refused id makes no udevadm call" "" "$(<"${TMP}/calls")"
done
reset_state
run_helper Capture_1 extra
[[ "$?" -ne 0 ]] && ok "extra arguments are refused" || bad "extra argument accepted"
assert_eq "extra argument makes no udevadm call" "" "$(<"${TMP}/calls")"

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

for stamp in corrupt 999999999999; do
  reset_state
  printf '%s\n' "${stamp}" >"${TMP}/run/audio-reprobe-Capture_1.stamp"
  run_helper Capture_1
  [[ "$?" -ne 0 ]] && ok "malformed or future stamp refuses recovery" || bad "unsafe stamp accepted"
  assert_eq "unsafe stamp triggers nothing" "" "$(<"${TMP}/calls")"
done

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
assert_eq "shared run directory is not made private" 755 "$(stat -c %a "${TMP}/run")"

printf 'audio-card-reprobe: %s passed, %s failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
