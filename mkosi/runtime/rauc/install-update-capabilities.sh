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
mkdir -p "${dest%/*}"
printf '{"schema":1,"features":["rauc-verity-streaming","rauc-activate-on-shutdown","slot-sync","origin-protection","apt-all-packages","reprune-hook","apt-credentials","transport-uidrange"],"ota_uid":%s,"apt_uid":%s}\n' \
  "$ota_uid" "$apt_uid" >"$dest"
chmod 0644 "$dest"
