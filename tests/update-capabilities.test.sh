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
jq -e --argjson ota 657 --argjson apt 42 \
  '.schema == 1 and .ota_uid == $ota and .apt_uid == $apt and .features == []' \
  "$WORK/root/usr/lib/ceralive/update-capabilities.json" >/dev/null
python3 - "$ROOT/mkosi/runtime/rauc/update-capabilities.schema.json" "$WORK/root/usr/lib/ceralive/update-capabilities.json" <<'PY'
import json, sys
from jsonschema import validate
with open(sys.argv[1]) as schema, open(sys.argv[2]) as data:
    validate(json.load(data), json.load(schema))
PY
if PATH="$WORK/bin:$PATH" CERALIVE_UPDATE_FEATURES=apt-all-packages \
  "$ROOT/mkosi/runtime/rauc/install-update-capabilities.sh" "$WORK/root" >"$WORK/early" 2>&1; then
  printf 'premature apt-all-packages advertisement accepted\n' >&2; exit 1
fi
if PATH="$WORK/bin:$PATH" CERALIVE_UPDATE_FEATURES=rauc-verity-streaming \
  "$ROOT/mkosi/runtime/rauc/install-update-capabilities.sh" "$WORK/root" >"$WORK/early" 2>&1; then
  printf 'premature verity advertisement accepted\n' >&2; exit 1
fi
grep -Fq 'not implemented' "$WORK/early"
echo 'update capability contract: PASS (actual UIDs, schema, premature feature refusal)'
