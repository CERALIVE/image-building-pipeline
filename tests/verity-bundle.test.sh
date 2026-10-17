#!/usr/bin/env bash
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "${here}/.." && pwd)"
# shellcheck source=tests/lib/assertions.sh
source "${repo}/tests/lib/assertions.sh"
check() { if "$@"; then ok "$*"; else bad "$*"; fi; }
require() { "$@" || { bad "fixture: $*"; exit 1; }; }
work=''
finish() {
  local status=$?
  [[ "$status" -eq 0 || "$FAIL" -gt 0 ]] || bad "unexpected exit: $status"
  [[ -z "$work" ]] || rm -rf "$work"
  printf ' RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
  [[ "$FAIL" -eq 0 ]]
}
trap 'finish; exit $?' EXIT
set -o errtrace
trap 'bad "fixture command failed at line $LINENO: $BASH_COMMAND"; exit 1' ERR
work="$(mktemp -d "${TMPDIR:-/var/tmp}/verity-contract.XXXXXX")" || { bad 'fixture: mktemp'; exit 1; }
require "${repo}/tests/generate-dev-rauc-pki.sh" >/dev/null
for tool in rauc mkfs.ext4 dumpe2fs; do require command -v "$tool" >/dev/null; done
mkdir -p "${work}/tree/etc" "${work}/bundle"
printf 'verity fixture\n' >"${work}/tree/etc/hostname"
truncate -s 64M "${work}/bundle/rootfs.ext4"
mkfs.ext4 -q -F -d "${work}/tree" "${work}/bundle/rootfs.ext4"
cat >"${work}/bundle/manifest.raucm" <<'MANIFEST'
[update]
compatible=ceralive-verity-fixture
version=1

[bundle]
format=verity

[image.rootfs]
filename=rootfs.ext4
adaptive=block-hash-index
MANIFEST
keys="${repo}/.dev-keys"
check rauc bundle --cert="${keys}/leaf-signing.pem" --key="${keys}/leaf-signing.key" \
  --intermediate="${keys}/chain.pem" --mksquashfs-args="-noD -noF" \
  "${work}/bundle" "${work}/fixture.raucb" >/dev/null
check rauc info --keyring="${keys}/root-ca.pem" "${work}/fixture.raucb" >"${work}/info"
check grep -iq 'Bundle Format:.*verity' "${work}/info"
check grep -iq 'adaptive.*block-hash-index' "${work}/info"

check grep -q 'make_slot_image' "${repo}/lib/build-bundle.sh"
check grep -q 'format=verity' "${repo}/lib/build-bundle.sh"
check grep -q 'adaptive=block-hash-index' "${repo}/lib/build-bundle.sh"
if grep -q 'bundle_with_openssl' "${repo}/lib/build-bundle.sh"; then
  bad 'retired OpenSSL bundle producer is still present'
else
  ok 'retired OpenSSL bundle producer absent'
fi
trap - ERR
[[ "$FAIL" -eq 0 ]]
