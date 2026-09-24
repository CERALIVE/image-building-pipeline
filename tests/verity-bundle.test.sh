#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "${here}/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/var/tmp}/verity-contract.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
"${repo}/tests/generate-dev-rauc-pki.sh" >/dev/null
for tool in rauc mkfs.ext4 dumpe2fs; do command -v "$tool" >/dev/null; done
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
rauc bundle --cert="${keys}/leaf-signing.pem" --key="${keys}/leaf-signing.key" \
  --intermediate="${keys}/chain.pem" "${work}/bundle" "${work}/fixture.raucb" >/dev/null
rauc info --keyring="${keys}/root-ca.pem" "${work}/fixture.raucb" >"${work}/info"
grep -iq 'Bundle Format:.*verity' "${work}/info"
grep -iq 'adaptive.*block-hash-index' "${work}/info"
printf 'FIXTURE=PASS verity adaptive block-hash-index signature verified\n'

grep -q 'make_slot_image' "${repo}/lib/build-bundle.sh"
grep -q 'format=verity' "${repo}/lib/build-bundle.sh"
grep -q 'adaptive=block-hash-index' "${repo}/lib/build-bundle.sh"
! grep -q 'bundle_with_openssl' "${repo}/lib/build-bundle.sh"
printf 'PRODUCER=PASS shared full-size ext4 verity producer\n'
