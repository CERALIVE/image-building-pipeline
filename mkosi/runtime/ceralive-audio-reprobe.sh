#!/usr/bin/env bash
# Recreate one kernel sound card's userspace profile set after a no-signal probe.
set -uo pipefail
export LC_ALL=C

die() { printf 'audio-reprobe: %s\n' "$*" >&2; exit 1; }

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
mkdir -p -- "${run_dir}" || die "cannot create runtime directory"
umask 077
stamp="${run_dir}/audio-reprobe-${id}.stamp"
exec 9>"${stamp}.lock" || die "cannot open card lock"
flock -n 9 || die "card reprobe already running"
now="$(date +%s)" || die "cannot read current time"
if [[ -e "${stamp}" ]]; then
  IFS= read -r previous <"${stamp}" || die "cannot read attempt stamp"
  [[ "${previous}" =~ ^[0-9]{1,12}$ ]] || die "invalid attempt stamp"
  (( now - 10#${previous} >= 30 )) || die "card reprobe rate limited"
fi
# Failed attempts consume the same budget, preventing repeated device churn.
printf '%s\n' "${now}" >"${stamp}" || die "cannot record attempt"
timeout --signal=KILL 1s udevadm trigger --action=remove \
  --subsystem-match=sound "--sysname-match=${card_name}" || die "remove trigger failed"
timeout --signal=KILL 1s udevadm trigger --action=add \
  --subsystem-match=sound "--sysname-match=${card_name}" || die "add trigger failed"
