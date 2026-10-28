#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/assertions.sh
source "$ROOT/tests/lib/assertions.sh"
check() { if "$@"; then ok "$*"; else bad "$*"; fi; }
WORK=''
finish() {
  local status=$?
  [[ "$status" -eq 0 || "$FAIL" -gt 0 ]] || bad "unexpected exit: $status"
  [[ -z "$WORK" ]] || rm -rf "$WORK"
  printf ' RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
  [[ "$FAIL" -eq 0 ]]
}
trap 'finish; exit $?' EXIT
set -o errtrace
trap 'bad "fixture command failed at line $LINENO: $BASH_COMMAND"; exit 1' ERR
WORK="$(mktemp -d)" || { bad 'fixture: mktemp'; exit 1; }

check test -x "$ROOT/mkosi/runtime/rauc/install-update-capabilities.sh"
check test -f "$ROOT/mkosi/runtime/rauc/update-capabilities.schema.json"
check grep -Fq 'install-update-capabilities.sh' "$ROOT/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"
check grep -Fq 'systemd-sysusers' "$ROOT/mkosi/customize/users.sh"
check grep -Fxq 'u ceralive-ota - "CeraLive RAUC streaming" /nonexistent /usr/sbin/nologin' \
  "$ROOT/mkosi/runtime/rauc/ceralive-ota.sysusers.conf"
check grep -Fxq 'd /data/ceralive/rauc 0700 root root -' "$ROOT/mkosi/runtime/rauc/ceralive-ota.tmpfiles.conf"
check grep -Fxq 'd /data/ceralive/update-state 0750 root ceralive -' "$ROOT/mkosi/runtime/rauc/ceralive-ota.tmpfiles.conf"

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
check env PATH="$WORK/bin:$PATH" "$ROOT/mkosi/runtime/rauc/install-update-capabilities.sh" "$WORK/root"
cp "$pin" "$WORK/complete-pin"
awk 'BEGIN {skip=0} /^Package: cerastream$/ {skip=1} /^Package: / && $0 != "Package: cerastream" {skip=0} !skip {print}' "$WORK/complete-pin" >"$pin"
if PATH="$WORK/bin:$PATH" "$ROOT/mkosi/runtime/rauc/install-update-capabilities.sh" "$WORK/root" >"$WORK/short.log" 2>&1; then
  bad 'short origin pin advertised origin-protection'
else
  ok 'short origin pin refused'
fi
check grep -Fq 'origin protection pin file is incomplete' "$WORK/short.log"
check test ! -e "$WORK/root/usr/lib/ceralive/update-capabilities.json"
printf '# no package stanzas\n' >"$pin"
if PATH="$WORK/bin:$PATH" "$ROOT/mkosi/runtime/rauc/install-update-capabilities.sh" "$WORK/root" >"$WORK/vacuous.log" 2>&1; then
  bad 'comment-only origin pin advertised origin-protection'
else
  ok 'comment-only origin pin refused'
fi
check grep -Fq 'origin protection pin has no package stanzas' "$WORK/vacuous.log"
rm "$pin"
if PATH="$WORK/bin:$PATH" "$ROOT/mkosi/runtime/rauc/install-update-capabilities.sh" "$WORK/root" >"$WORK/absent.log" 2>&1; then
  bad 'missing origin pin advertised origin-protection'
else
  ok 'missing origin pin refused'
fi
check grep -Fq 'origin protection pin or independent name authority missing' "$WORK/absent.log"
cp "$WORK/complete-pin" "$pin"
check env PATH="$WORK/bin:$PATH" "$ROOT/mkosi/runtime/rauc/install-update-capabilities.sh" "$WORK/root"
check jq -e --argjson ota 657 --argjson apt 42 \
  '.schema == 1 and .ota_uid == $ota and .apt_uid == $apt and .features == [
    "rauc-verity-streaming", "rauc-activate-on-shutdown", "slot-sync",
    "origin-protection", "apt-all-packages", "reprune-hook",
    "apt-credentials", "transport-uidrange"
  ]' \
  "$WORK/root/usr/lib/ceralive/update-capabilities.json" >/dev/null
check python3 - "$ROOT/mkosi/runtime/rauc/update-capabilities.schema.json" "$WORK/root/usr/lib/ceralive/update-capabilities.json" <<'PY'
import json, sys
from jsonschema import validate
with open(sys.argv[1]) as schema, open(sys.argv[2]) as data:
    validate(json.load(data), json.load(schema))
PY
export CERALIVE_KERNEL_STAGE_PIN_FILE="$ROOT/manifests/first-party-deb-versions.txt"
export REAL_DPKG
REAL_DPKG="$(command -v dpkg)"
cat >"$WORK/bin/dpkg" <<'SH'
#!/bin/sh
if [ "$1" = --print-architecture ]; then
  printf '%s\n' "${FIXTURE_ARCH:-amd64}"
else
  exec "$REAL_DPKG" "$@"
fi
SH
chmod +x "$WORK/bin/dpkg"
mkdir -p "$WORK/root/usr/libexec/ceralive"
for file in ceralive-kernel-stage ceralive-kernel-state-lib.sh ceralive-slot-mirror-lib.sh \
  ceralive-kernel-boot-staging verify-boot-artifacts.sh; do
  install -m 0755 /usr/bin/true "$WORK/root/usr/lib/ceralive/$file"
done
install -m 0755 /usr/bin/true "$WORK/root/usr/libexec/ceralive/ceralive-slot-sync"
capability_has_kernel() {
  jq -e '.features | index("kernel-apt-stage") != null' "$WORK/root/usr/lib/ceralive/update-capabilities.json" >/dev/null
}
emit() {
  env PATH="$WORK/bin:$PATH" "$ROOT/mkosi/runtime/rauc/install-update-capabilities.sh" "$WORK/root"
}
for arch in amd64 arm64; do
  export FIXTURE_ARCH="$arch"
  # Real payload pins include timestamp/hash suffixes, not just the release tag.
  version="$(awk -F= -v package="ceralive-device[$arch]" '$1 == package {print $2}' "$CERALIVE_KERNEL_STAGE_PIN_FILE")"
  check test -n "$version"
  unset KERNEL_STAGE_MIN_CERAUI
  check emit
  if capability_has_kernel; then bad 'unset minimum enabled kernel staging'; else ok 'unset minimum stays OFF'; fi
  export KERNEL_STAGE_MIN_CERAUI=""
  check emit
  if capability_has_kernel; then bad 'empty minimum enabled kernel staging'; else ok 'empty minimum stays OFF'; fi
  export KERNEL_STAGE_MIN_CERAUI="$version"
  check emit
  check capability_has_kernel
  export KERNEL_STAGE_MIN_CERAUI="2026.10.0"
  check emit
  check capability_has_kernel
  export KERNEL_STAGE_MIN_CERAUI="${version}1"
  check emit
  if capability_has_kernel; then bad 'below-minimum pin enabled kernel staging'; else ok 'below-minimum payload stays OFF'; fi
done
export KERNEL_STAGE_MIN_CERAUI="$version"
for file in usr/lib/ceralive/ceralive-kernel-stage usr/lib/ceralive/ceralive-kernel-state-lib.sh \
  usr/lib/ceralive/ceralive-slot-mirror-lib.sh usr/libexec/ceralive/ceralive-slot-sync \
  usr/lib/ceralive/ceralive-kernel-boot-staging usr/lib/ceralive/verify-boot-artifacts.sh; do
  mv "$WORK/root/$file" "$WORK/missing-file"
  check emit
  if capability_has_kernel; then bad "missing $file enabled staging"; else ok "missing $file stays OFF"; fi
  mv "$WORK/missing-file" "$WORK/root/$file"
done
export CERALIVE_KERNEL_STAGE_PIN_FILE="$WORK/missing-pins"
check emit
if capability_has_kernel; then bad 'missing pins enabled staging'; else ok 'missing pins stay OFF'; fi
trap - ERR
[[ "$FAIL" -eq 0 ]]
