#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
root="$work/root"
stage="$work/staging"
mkdir -p "$root/usr/lib/ceralive/build-lock" "$root/var/lib/dpkg" "$stage/packages-lock" "$stage/kernel-build" "$work/out"

hash_a="$(printf apt | sha256sum | cut -d' ' -f1)"
hash_k="$(printf kernel | sha256sum | cut -d' ' -f1)"
printf kernel >"$stage/kernel-build/linux-image-test_1_arm64.deb"
mkdir -p "$work/control/DEBIAN" "$stage/debs"
printf 'Package: local-example\nVersion: 2.0\nArchitecture: all\nMaintainer: Fixture <fixture@example.invalid>\nDescription: fixture\n' >"$work/control/DEBIAN/control"
dpkg-deb --root-owner-group --build "$work/control" "$stage/debs/local-example_2.0_all.deb" >/dev/null
hash_b="$(sha256sum "$stage/debs/local-example_2.0_all.deb" | cut -d' ' -f1)"
printf 'Package: local-example\nVersion: 2.0\nArchitecture: all\nFilename: pool/local-example_2.0_all.deb\nSHA256: %s\n\n' \
  "$hash_b" >"$work/Packages"
DEST="$stage" ARCH=arm64 DRY_RUN='' INDEX="$work/Packages" LIB="$HERE/lib" bash -ec '
  die() { printf "%s\n" "$*" >&2; exit 1; }
  log_error() { die "$*"; }
  deb_pkg_name() { dpkg-deb -f "$1" Package; }
  deb_pkg_version() { dpkg-deb -f "$1" Version; }
  deb_pkg_arch() { dpkg-deb -f "$1" Architecture; }
  rk3588_userspace_record() { :; }
  debcache_apt_index() { :; }
  FIRST_PARTY_APT_PKGS=()
  _BSP_APT_INDEX="$INDEX"
  source "$LIB/fetch-debs-auth.sh"
  source "$LIB/fetch/index.sh"
  source "$LIB/fetch/lock.sh"
  fetch_lock_sidecar
'
ARCH=arm64 SOURCE_DATE_EPOCH=1780000000 DEBS="$stage/debs" LIB="$HERE/lib" bash -ec '
  die() { printf "%s\n" "$*" >&2; exit 1; }
  log_success() { :; }
  assert_deb_identity() { [[ "$(dpkg-deb -f "$1" Package)" == "$2" && "$(dpkg-deb -f "$1" Version)" == "$3" && "$(dpkg-deb -f "$1" Architecture)" == "$4" ]]; }
  source "$LIB/fetch/userspace.sh"
  build_libv4l0_compat_deb "$DEBS"
'
hash_c="$(sha256sum "$stage/debs/libv4l-0_1.30.1-1+ceralive1_arm64.deb" | cut -d' ' -f1)"
cat >"$root/var/lib/dpkg/status" <<'EOF'
Package: apt-example
Status: install ok installed
Architecture: arm64
Version: 1.0

Package: local-example
Status: install ok installed
Architecture: all
Version: 2.0

Package: libv4l-0
Status: install ok installed
Architecture: arm64
Version: 1.30.1-1+ceralive1

Package: linux-image-test
Status: hold ok installed
Architecture: arm64
Version: 1
EOF
printf '{"name":"apt-example","version":"1.0","arch":"arm64","origin":"debian","sha256":"%s"}\n' "$hash_a" >"$root/usr/lib/ceralive/build-lock/base.jsonl"
printf 'trixie\tWed, 23 Sep 2026 00:00:00 UTC\ntrixie-security\tWed, 23 Sep 2026 01:00:00 UTC\n' >"$root/usr/lib/ceralive/build-lock/runtime.dates"

args=("$root" "$stage" "$work/out/20260924.packages.lock.json" 1780000000 2026-09-24T12:00:00Z aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)
python3 "$HERE/lib/packages-lock.py" merge "${args[@]}"
python3 - "${args[2]}" "$hash_a" "$hash_b" "$hash_c" "$hash_k" <<'PY'
import json
import sys
lock = json.load(open(sys.argv[1]))
assert lock['built_at'] == '2026-09-24T12:00:00Z'
assert lock['source_date_epoch'] == 1780000000
assert lock['debian_release_dates']['trixie'] == 'Wed, 23 Sep 2026 00:00:00 UTC'
entries = {p['name']: p for p in lock['packages']}
assert len(entries) == 4
for name, origin, sha in [('apt-example', 'debian', sys.argv[2]),
                          ('local-example', 'bsp', sys.argv[3]),
                          ('libv4l-0', 'generated-locally', sys.argv[4])]:
    entry = entries[name]
    assert (entry['origin'], entry['sha256']) == (origin, sha)
    assert set(entry) == {'name', 'version', 'arch', 'origin', 'sha256'}
kernel = entries['linux-image-test']
assert kernel['origin'] == 'source-built'
assert kernel['source']['commit'] == 'a' * 40
assert kernel['source']['patches_commit'] == 'b' * 40
assert kernel['artifact']['sha256'] == {'linux-image-test_1_arm64.deb': sys.argv[5]}
assert 'sha256' not in kernel
PY
printf 'Package: genuinely-unaccounted\nStatus: install ok installed\nArchitecture: arm64\nVersion: 9\n\n' >>"$root/var/lib/dpkg/status"
if python3 "$HERE/lib/packages-lock.py" merge "${args[@]}" >"$work/error" 2>&1; then
  printf 'FAIL: novel unaccounted package was accepted\n' >&2
  exit 1
fi
grep -q 'genuinely-unaccounted' "$work/error"
printf 'packages-lock: PASS cases (a)/(b)/(c), source-built kernel, fail-closed novel package\n'
