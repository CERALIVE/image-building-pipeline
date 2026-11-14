#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source mkosi/customize/postinst.d/persistence.sh
w=$(mktemp -d); trap 'rm -rf "$w"' EXIT
install_bounded_apt_metadata "$w"
install_bounded_apt_metadata "$w"
[[ $(grep -Fxc 'tmpfs /var/lib/apt/lists tmpfs nosuid,nodev,noexec,size=192M,mode=0755 0 0' "$w/etc/fstab") -eq 1 ]]
grep -Fxq 'tmpfs /var/lib/apt/lists tmpfs nosuid,nodev,noexec,size=192M,mode=0755 0 0' "$w/etc/fstab"
apt-config -c "$w/etc/apt/apt.conf.d/82bounded-metadata" dump >"$w/config"
grep -Fxq 'Dir::Cache::pkgcache "";' "$w/config"
grep -Fxq 'Dir::Cache::srcpkgcache "";' "$w/config"
# No transaction hooks remove the lists that an install following update needs.
if grep -q 'Post-Invoke' "$w/etc/apt/apt.conf.d/82bounded-metadata"; then
  echo 'APT metadata policy must retain indexes after a transaction' >&2
  exit 1
fi
# Board-specific setup must follow the shared attention installation so every
# board receives diagnostics before customization enters its optional path.
python3 - <<'PY'
from pathlib import Path
s = Path('mkosi/customize/postinst.d/persistence.sh').read_text()
body = s[s.index('setup_data_persistence() {'):]
# The shared diagnostic installer is a separate optional topic. When present,
# it must remain ahead of the board-specific policy; this standalone base has
# only the growth installer. Both compositions must configure APT once.
if 'ceralive-attention.py' in body:
    assert body.index('ceralive-attention.py') < body.index('install_bounded_apt_metadata /')
assert body.index('install_bounded_apt_metadata /') < body.index('ceralive-grow-data.sh')
assert body.count('install_bounded_apt_metadata /') == 1
PY
