#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[[ -x "$ROOT/mkosi/runtime/rauc/install-update-capabilities.sh" ]]
[[ -f "$ROOT/mkosi/runtime/rauc/update-capabilities.schema.json" ]]
grep -Fq 'install-update-capabilities.sh' "$ROOT/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"
grep -Fq 'systemd-sysusers' "$ROOT/mkosi/customize/users.sh"
grep -Fxq 'u ceralive-ota - "CeraLive RAUC streaming" /nonexistent /usr/sbin/nologin' \
  "$ROOT/mkosi/runtime/rauc/ceralive-ota.sysusers.conf"
grep -Fxq 'd /data/ceralive/rauc 0700 root root -' "$ROOT/mkosi/runtime/rauc/ceralive-ota.tmpfiles.conf"
grep -Fxq 'd /data/ceralive/update-state 0750 root ceralive -' "$ROOT/mkosi/runtime/rauc/ceralive-ota.tmpfiles.conf"

mkdir -p "$WORK/bin" "$WORK/root/usr/lib/ceralive"
mkdir -p "$WORK/root/etc/apt/preferences.d"
pin="$WORK/root/etc/apt/preferences.d/ceralive-origin"
awk '!/^[[:space:]]*(#|$)/ {
  print "Package: " $0 "\nPin: origin apt.ceralive.tv\nPin-Priority: 990"
  print "Package: " $0 "\nPin: origin *\nPin-Priority: -1"
}' "$ROOT/mkosi/runtime/first-party-origin-names.txt" >"$pin"
cat >"$WORK/bin/getent" <<'EOF'
#!/bin/sh
case "$2" in
  ceralive-ota) printf 'ceralive-ota:x:657:657::/nonexistent:/usr/sbin/nologin\n';;
  _apt) printf '_apt:x:42:65534::/nonexistent:/usr/sbin/nologin\n';;
  *) exit 2;;
esac
EOF
chmod +x "$WORK/bin/getent"
PATH="$WORK/bin:$PATH" "$ROOT/mkosi/runtime/rauc/install-update-capabilities.sh" "$WORK/root"
cp "$pin" "$WORK/complete-pin"
awk 'BEGIN {skip=0} /^Package: cerastream$/ {skip=1} /^Package: / && $0 != "Package: cerastream" {skip=0} !skip {print}' "$WORK/complete-pin" >"$pin"
if PATH="$WORK/bin:$PATH" "$ROOT/mkosi/runtime/rauc/install-update-capabilities.sh" "$WORK/root" >"$WORK/short.log" 2>&1; then
  printf 'short origin pin advertised origin-protection\n' >&2; exit 1
fi
grep -Fq 'origin protection pin file is incomplete' "$WORK/short.log"
[[ ! -e "$WORK/root/usr/lib/ceralive/update-capabilities.json" ]]
printf '# no package stanzas\n' >"$pin"
if PATH="$WORK/bin:$PATH" "$ROOT/mkosi/runtime/rauc/install-update-capabilities.sh" "$WORK/root" >"$WORK/vacuous.log" 2>&1; then
  printf 'comment-only origin pin advertised origin-protection\n' >&2; exit 1
fi
grep -Fq 'origin protection pin has no package stanzas' "$WORK/vacuous.log"
rm "$pin"
if PATH="$WORK/bin:$PATH" "$ROOT/mkosi/runtime/rauc/install-update-capabilities.sh" "$WORK/root" >"$WORK/absent.log" 2>&1; then
  printf 'missing origin pin advertised origin-protection\n' >&2; exit 1
fi
grep -Fq 'origin protection pin or independent name authority missing' "$WORK/absent.log"
cp "$WORK/complete-pin" "$pin"
PATH="$WORK/bin:$PATH" "$ROOT/mkosi/runtime/rauc/install-update-capabilities.sh" "$WORK/root"
jq -e --argjson ota 657 --argjson apt 42 \
  '.schema == 1 and .ota_uid == $ota and .apt_uid == $apt and .features == [
    "rauc-verity-streaming", "rauc-activate-on-shutdown", "slot-sync",
    "origin-protection", "apt-all-packages", "reprune-hook",
    "apt-credentials", "transport-uidrange"
  ]' \
  "$WORK/root/usr/lib/ceralive/update-capabilities.json" >/dev/null
python3 - "$ROOT/mkosi/runtime/rauc/update-capabilities.schema.json" "$WORK/root/usr/lib/ceralive/update-capabilities.json" <<'PY'
import json, sys
from jsonschema import validate
with open(sys.argv[1]) as schema, open(sys.argv[2]) as data:
    validate(json.load(data), json.load(schema))
PY
echo 'update capability contract: PASS (actual UIDs, schema, full feature set)'
