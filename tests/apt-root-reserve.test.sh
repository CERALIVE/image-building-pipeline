#!/usr/bin/env bash
# Offline APT/cache policy and populated ext4 measurement; no mounts or network.
set -Eeuo pipefail
trap 'printf "FAIL: APT root reserve at line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR
for tool in apt-cache apt-get mkfs.ext4 dumpe2fs; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'SKIP: APT root reserve requires %s\n' "$tool"
    exit 0
  fi
done
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
source "${REPO}/lib/shared/slot-reserve.sh"
mkdir -p "${WORK}/tree/var/cache/apt" "${WORK}/tree/var/lib/apt/lists/partial" "${WORK}/empty"
: >"${WORK}/status"
printf 'deb http://example.invalid/debian stable main\n' >"${WORK}/sources.list"
cat >"${WORK}/tree/var/lib/apt/lists/example.invalid_debian_dists_stable_main_binary-amd64_Packages" <<'PACKAGES'
Package: example
Version: 1.0
Architecture: amd64
Maintainer: Example <example@example.invalid>
Description: Synthetic package
Filename: pool/example.deb
Size: 100
SHA256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

PACKAGES
# APT_CONFIG is read first: prevent loading ANY host configuration or sources.
cat >"${WORK}/isolated.conf" <<CONF
Dir::Etc::parts "${WORK}/empty";
Dir::Etc::main "/dev/null";
Dir::Etc::sourcelist "${WORK}/sources.list";
Dir::Etc::sourceparts "${WORK}/empty";
Dir::State::status "${WORK}/status";
Dir::State::lists "${WORK}/tree/var/lib/apt/lists";
Dir::Cache "${WORK}/tree/var/cache/apt";
Dir::Cache::pkgcache "pkgcache.bin";
Dir::Cache::srcpkgcache "srcpkgcache.bin";
APT::Architecture "amd64";
CONF
export APT_CONFIG="${WORK}/isolated.conf"
apt-cache gencaches >/dev/null
for cache in pkgcache.bin srcpkgcache.bin; do
  [[ -s "${WORK}/tree/var/cache/apt/${cache}" ]]
done
measure() {
  truncate -s 1G "${WORK}/slot.ext4"
  mkfs.ext4 -q -F -d "${WORK}/tree" "${WORK}/slot.ext4"
  slot_reserve_assert_ext4 "${WORK}/slot.ext4" "$1"
}
measure with-caches >"${WORK}/before"
# Read the exact configuration shipped by the runtime writer.
awk '/cat >\/etc\/apt\/apt.conf.d\/81ceralive-cache / { active=1; next }
     active && /^EOF$/ { exit }
     active { print }' "${REPO}/mkosi/mkosi.images/runtime/mkosi.postinst.chroot" >"${WORK}/policy.conf"
[[ -s "${WORK}/policy.conf" ]]
cat "${WORK}/policy.conf" >>"${WORK}/isolated.conf"
rm "${WORK}/tree/var/cache/apt/"*.bin
apt-cache gencaches >/dev/null
[[ ! -e "${WORK}/tree/var/cache/apt/pkgcache.bin" ]]
[[ ! -e "${WORK}/tree/var/cache/apt/srcpkgcache.bin" ]]
apt-cache show example | grep -q '^Version: 1.0$'
apt-get -s install example >"${WORK}/install"
grep -q '^Inst example ' "${WORK}/install"
[[ ! -e "${WORK}/tree/var/cache/apt/pkgcache.bin" ]]
[[ ! -e "${WORK}/tree/var/cache/apt/srcpkgcache.bin" ]]
measure without-caches >"${WORK}/after"
before="$(sed -n 's/.* field=bavail free=\([0-9]*\).*/\1/p' "${WORK}/before")"
after="$(sed -n 's/.* field=bavail free=\([0-9]*\).*/\1/p' "${WORK}/after")"
(( after > before ))
cat "${WORK}/before" "${WORK}/after"
printf 'APT binary-cache policy recovers %s available bytes in populated ext4 fixture\n' "$((after - before))"
printf 'PASS: APT queries and simulated install do not regenerate binary caches\n'
