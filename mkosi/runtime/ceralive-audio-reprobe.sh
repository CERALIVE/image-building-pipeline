#!/usr/bin/env bash
# Recreate one kernel sound card's userspace profile set after a no-signal probe.
set -uo pipefail
export LC_ALL=C

die() { printf 'audio-reprobe: %s\n' "$*" >&2; exit 1; }

# The engine allows 3 s for this helper, node discovery and the capture open together,
# so every command here shares the first 1.5 s. --foreground keeps each one in the
# caller's process group, where the caller's kill reaches it.
uptime="${CERALIVE_AUDIO_UPTIME:-/proc/uptime}"
IFS=' ' read -r started _ <"${uptime}" || die "cannot read uptime"
bounded() {
  local now left
  IFS=' ' read -r now _ <"${uptime}" || return 1
  left=$(( 10#${started/./} + 150 - 10#${now/./} ))
  # A zero limit would mean no limit to timeout.
  (( left > 0 )) || return 1
  printf -v left '%d.%02ds' "$(( left / 100 ))" "$(( left % 100 ))"
  timeout --foreground --signal=KILL "${left}" "$@"
}

[[ $# -eq 1 && "$1" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || die "invalid card id"
id="$1"
sysfs="${CERALIVE_AUDIO_SYSFS_ROOT:-/sys/class/sound}"
run_dir="${CERALIVE_AUDIO_RUN_DIR:-/run/ceralive}"
card_name=""
for card in "${sysfs}"/card[0-9]*; do
  [[ "${card##*/}" =~ ^card[0-9]+$ && -r "${card}/id" ]] || continue
  IFS= read -r candidate <"${card}/id" || continue
  if [[ "${candidate}" == "${id}" ]]; then
    card_name="${card##*/}"
    break
  fi
done
[[ -n "${card_name}" ]] || die "unknown card id"

# /run/ceralive is shared with other services; only this helper's files are private.
bounded mkdir -p -- "${run_dir}" || die "cannot create runtime directory"
umask 077
stamp="${run_dir}/audio-reprobe-${id}.stamp"
now="$(bounded date +%s)" || die "cannot read current time"
exec 9>"${stamp}.lock" || die "cannot open card lock"
bounded flock -n 9 || die "card reprobe already running"
if [[ -e "${stamp}" ]]; then
  IFS= read -r previous <"${stamp}" || die "cannot read attempt stamp"
  [[ "${previous}" =~ ^[0-9]{1,12}$ ]] || die "invalid attempt stamp"
  (( now - 10#${previous} >= 30 )) || die "card reprobe rate limited"
fi
# Failed attempts consume the same budget, preventing repeated device churn.
printf '%s\n' "${now}" >"${stamp}" || die "cannot record attempt"
trigger() {
  # A child that inherits fd 9 would hold the card lock after this shell is killed.
  bounded udevadm trigger "--action=$1" --subsystem-match=sound \
    "--sysname-match=${card_name}" 9>&- || die "$1 trigger failed"
}
trigger remove
trigger add
# udev sets SOUND_INITIALIZED only on a card change event, and PipeWire skips a card
# without it. HDMI-IN only: on a USB card a change event also reruns the id rename rule.
if [[ "${id}" == "HDMIIN" ]]; then
  trigger change
fi
