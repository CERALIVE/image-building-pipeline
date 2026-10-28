#!/usr/bin/env bash
set -euo pipefail

root="${1:-}"
[[ "${root}" == /* ]] || { printf 'absolute root path required\n' >&2; exit 1; }

uid_for() {
  local account="$1" entry uid
  entry="$(getent passwd "$account")" || { printf 'missing account: %s\n' "$account" >&2; exit 1; }
  IFS=: read -r _ _ uid _ _ _ _ <<<"$entry"
  [[ "$uid" =~ ^[1-9][0-9]*$ ]] || { printf 'invalid non-root UID: %s\n' "$account" >&2; exit 1; }
  printf '%s' "$uid"
}

ota_uid="$(uid_for ceralive-ota)"
apt_uid="$(uid_for _apt)"
dest="$root/usr/lib/ceralive/update-capabilities.json"
pin_file="$root/etc/apt/preferences.d/ceralive-origin"
authority="${BASH_SOURCE[0]%/*}/../first-party-origin-names.txt"
[[ -s "$pin_file" && -s "$authority" ]] || { rm -f "$dest"; printf 'origin protection pin or independent name authority missing\n' >&2; exit 1; }
[[ "$(grep -c '^Package: ' "$pin_file")" -gt 0 ]] || { rm -f "$dest"; printf 'origin protection pin has no package stanzas\n' >&2; exit 1; }
if ! cmp -s \
  <(awk '/^(Package|Pin|Pin-Priority): / {print}' "$pin_file") \
  <(awk '!/^[[:space:]]*(#|$)/ {
    print "Package: " $0 "\nPin: origin apt.ceralive.tv\nPin-Priority: 990"
    print "Package: " $0 "\nPin: origin *\nPin-Priority: -1"
  }' "$authority"); then
  rm -f "$dest"
  printf 'origin protection pin file is incomplete or differs from the independent name authority\n' >&2
  exit 1
fi
mkdir -p "${dest%/*}"
# Owner fills the default only after releasing the capable CeraUI. Empty is OFF.
KERNEL_STAGE_MIN_CERAUI="${KERNEL_STAGE_MIN_CERAUI:-}"
kernel_feature=""
kernel_pins="${CERALIVE_KERNEL_STAGE_PIN_FILE:-${BASH_SOURCE[0]%/*}/../first-party-deb-versions.txt}"
if [[ -n "${KERNEL_STAGE_MIN_CERAUI}" && -r "${kernel_pins}" &&
      -x "$root/usr/lib/ceralive/ceralive-kernel-stage" &&
      -r "$root/usr/lib/ceralive/ceralive-kernel-state-lib.sh" &&
      -r "$root/usr/lib/ceralive/ceralive-slot-mirror-lib.sh" &&
      -x "$root/usr/libexec/ceralive/ceralive-slot-sync" &&
      -x "$root/usr/lib/ceralive/ceralive-kernel-boot-staging" &&
      -x "$root/usr/lib/ceralive/verify-boot-artifacts.sh" ]]; then
  arch="$(dpkg --print-architecture)"
  pinned="$(awk -F= -v package="ceralive-device[${arch}]" '$1 == package {version=$2; count++} END {if (count == 1) print version}' "${kernel_pins}")"
  if [[ -n "${pinned}" ]] &&
    dpkg --validate-version "${pinned}" >/dev/null 2>&1 &&
    dpkg --validate-version "${KERNEL_STAGE_MIN_CERAUI}" >/dev/null 2>&1 &&
    dpkg --compare-versions "${pinned}" ge "${KERNEL_STAGE_MIN_CERAUI}"; then
    kernel_feature=',"kernel-apt-stage"'
  fi
fi
printf '{"schema":1,"features":["rauc-verity-streaming","rauc-activate-on-shutdown","slot-sync","origin-protection","apt-all-packages","reprune-hook","apt-credentials","transport-uidrange"%s],"ota_uid":%s,"apt_uid":%s}\n' \
  "$kernel_feature" "$ota_uid" "$apt_uid" >"$dest"
chmod 0644 "$dest"
