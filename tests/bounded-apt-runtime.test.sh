#!/bin/bash
# Opt-in disposable mount namespace: no host APT state or mount is changed.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ${CERALIVE_RUN_BOUNDED_APT:-0} != 1 ]]; then
  echo 'SKIP: set CERALIVE_RUN_BOUNDED_APT=1 and run as root with mount namespaces'
  exit 0
fi
[[ $EUID == 0 ]] || exit 1
w=$(mktemp -d /var/tmp/bounded-apt.XXXXXX)
trap 'rm -rf "$w"' EXIT
chmod 755 "$w"
mkdir -p "$w"/{pkg/DEBIAN,repo,lists,archives/partial,etc}
printf 'Package: bounded-apt-fixture\nVersion: 1\nArchitecture: all\nMaintainer: Test <test@example.org>\nDescription: disposable APT transaction fixture\n' >"$w/pkg/DEBIAN/control"
dpkg-deb --build "$w/pkg" "$w/repo/fixture.deb" >/dev/null
(cd "$w/repo"; dpkg-scanpackages . /dev/null >Packages)
printf 'deb [trusted=yes] file:%s/repo ./\n' "$w" >"$w/sources"
touch "$w/status"
source mkosi/customize/postinst.d/persistence.sh
install_bounded_apt_metadata "$w/config"
# Load isolation before APT reads any host configuration fragments or hooks.
printf 'Dir::Etc::parts "%s/etc";\nDir::Etc::main "/dev/null";\nDir::State "%s/state";\nDir::Cache "%s/cache";\nDir::Log "%s/log";\n' "$w" "$w" "$w" "$w" >"$w/early.conf"
mkdir -p "$w/"{state,cache,log}
export APT_CONFIG="$w/early.conf"
export w
unshare -m bash -euo pipefail <<'INNER'
mount --make-rprivate /
mount -t tmpfs -o nosuid,nodev,noexec,size=192M,mode=0755 tmpfs "$w/lists"
a=(-o "Dir::Etc::sourcelist=$w/sources" -o "Dir::Etc::sourceparts=$w/etc" -o "Dir::State::lists=$w/lists" -o "Dir::State::status=$w/status" -o "Dir::Cache::archives=$w/archives" -c "$w/config/etc/apt/apt.conf.d/82bounded-metadata")
apt-get "${a[@]}" update
apt-cache "${a[@]}" show bounded-apt-fixture | grep -q 'Version: 1'
apt-get "${a[@]}" --download-only -y install bounded-apt-fixture
# Oversize metadata fails inside the bound; existing lists remain queryable.
if dd if=/dev/zero of="$w/lists/over-limit" bs=1M count=193 status=none; then exit 1; fi
rm "$w/lists/over-limit"
apt-cache "${a[@]}" show bounded-apt-fixture | grep -q 'Version: 1'
read -r blocks block_size < <(stat -f -c '%b %S' "$w/lists")
(( blocks * block_size == 201326592 ))
umount "$w/lists"
mount -t tmpfs -o size=192M tmpfs "$w/lists"
[[ -z $(ls -A "$w/lists") ]]
umount "$w/lists"
INNER
echo 'APT refresh/query/download, enforced metadata bound and empty next-boot mount PASS'
