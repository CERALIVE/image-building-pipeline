#!/usr/bin/env bash
# Real, offline APT candidate resolution for both image preferences writers.
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${1:-}" != --in-container ]]; then
  command -v docker >/dev/null || { printf 'real APT or Docker is required for the origin policy test\n' >&2; exit 1; }
  docker image inspect debian:trixie-slim >/dev/null || { printf 'offline Debian trixie image missing\n' >&2; exit 1; }
  exec docker run --rm --network none -e CERALIVE_APT_FIXTURE_CONTAINER=1 -v "${ROOT}:${ROOT}:ro" debian:trixie-slim bash "${ROOT}/tests/apt-first-party-origin.test.sh" --in-container
fi
[[ "${CERALIVE_APT_FIXTURE_CONTAINER:-}" == 1 ]] || { printf 'APT fixture must run in disposable offline container\n' >&2; exit 1; }

if ! command -v apt-cache >/dev/null || ! command -v apt-get >/dev/null; then
  printf 'real APT is required\n' >&2
  exit 1
fi
[[ -r "${ROOT}/manifests/first-party-apt-names.txt" ]] || exit 1
[[ -r "${ROOT}/mkosi/runtime/first-party-origin-names.txt" ]] || { printf 'independent origin-name authority missing\n' >&2; exit 1; }
work="$(mktemp -d)"
server_pid=''
cleanup() {
  if [[ -n "${server_pid}" ]]; then kill "${server_pid}" 2>/dev/null || :; wait "${server_pid}" 2>/dev/null || :; fi
  rm -rf -- "${work}"
}
trap cleanup EXIT

mkdir -p "${work}"/{ours,debian,foreign,apt/etc/sources.list.d,apt/etc/preferences.d,apt/lists/partial,apt/cache/archives/partial}
cat >"${work}/ours/Packages" <<'PACKAGES'
Package: cerastream
Version: 2.0
Architecture: all
Filename: pool/cerastream_2.0_all.deb
Size: 100
Maintainer: Fixture <fixture@example.invalid>
Description: first-party candidate

PACKAGES
cat >"${work}/debian/Packages" <<'PACKAGES'
Package: cerastream
Version: 4.0
Architecture: all
Maintainer: Fixture <fixture@example.invalid>
Description: same-name Debian candidate

Package: unrelated-debian-tool
Version: 1.0
Architecture: all
Maintainer: Fixture <fixture@example.invalid>
Description: ordinary Debian package

PACKAGES
cat >"${work}/foreign/Packages" <<'PACKAGES'
Package: cerastream
Version: 3.0
Architecture: all
Maintainer: Fixture <fixture@example.invalid>
Description: same-name third-origin candidate

PACKAGES
write_release() {
  local origin="$1" label bytes digest
  case "$origin" in ours) label=CeraLive ;; debian) label=Debian ;; foreign) label=Foreign ;; esac
  bytes="$(stat -c %s "${work}/${origin}/Packages")"
  digest="$(sha256sum "${work}/${origin}/Packages")"; digest="${digest%% *}"
  cat >"${work}/${origin}/Release" <<EOF
Origin: ${label}
Label: ${label}
Suite: stable
Codename: stable
Date: Thu, 01 Jan 2026 00:00:00 UTC
Architectures: amd64
Components: main
SHA256:
 ${digest} ${bytes} Packages
EOF
}
for origin in ours debian foreign; do
  write_release "$origin"
done

# file: archives provide the actual Debian and foreign indexes. The CeraLive
# archive is served from loopback under its real hostname so APT, not the test,
# evaluates `Pin: origin apt.ceralive.tv`. No network leaves this container.
cat >"${work}/server.pl" <<'PERL'
use strict;
use warnings;
use IO::Socket::INET;
my ($root, $port_file) = @ARGV;
my $listener = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 8, ReuseAddr => 1) or die $!;
open my $pf, '>', $port_file or die $!;
print {$pf} $listener->sockport;
close $pf;
while (my $client = $listener->accept) {
  my $request = <$client> // '';
  $request =~ m{^GET /ours/(?:\./)?(Packages|Release) HTTP/1\.[01]\r?\n$} or do {
    print {$client} "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    close $client;
    next;
  };
  my $name = $1;
  while (my $header = <$client>) { last if $header =~ /^\r?\n$/; }
  open my $file, '<', "$root/$name" or die $!;
  local $/;
  my $body = <$file>;
  print {$client} "HTTP/1.1 200 OK\r\nContent-Length: ", length($body), "\r\nConnection: close\r\n\r\n", $body;
  close $file;
  close $client;
}
PERL
perl "${work}/server.pl" "${work}/ours" "${work}/port" & server_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -s "${work}/port" ]] && break; sleep .1; done
[[ -s "${work}/port" ]] || { printf 'local APT fixture server did not start\n' >&2; exit 1; }
port="$(<"${work}/port")"
# In a disposable network-less container only. Avoid DNS and all public mirrors.
printf '\n127.0.0.1 apt.ceralive.tv\n' >>/etc/hosts
cat >"${work}/apt/etc/sources.list" <<EOF
deb [trusted=yes] http://apt.ceralive.tv:${port}/ours/ ./
deb [trusted=yes] file:${work}/debian/ ./
deb [trusted=yes] file:${work}/foreign/ ./
EOF
: >"${work}/apt/etc/preferences"
: >"${work}/apt/status"
apt_opts=(
  -o "Dir::Etc::sourcelist=${work}/apt/etc/sources.list"
  -o "Dir::Etc::sourceparts=${work}/apt/etc/sources.list.d"
  -o "Dir::Etc::preferences=${work}/apt/etc/preferences"
  -o "Dir::Etc::preferencesparts=${work}/apt/etc/preferences.d"
  -o "Dir::State::lists=${work}/apt/lists"
  -o "Dir::State::status=${work}/apt/status"
  -o "Dir::Cache=${work}/apt/cache"
  -o Acquire::Languages=none
  -o Acquire::http::Proxy=DIRECT
  -o Debug::NoLocking=true
)
apt-get "${apt_opts[@]}" update >"${work}/update.log" 2>&1 || { printf 'fixture apt update failed:\n' >&2; command cat "${work}/update.log" >&2; exit 1; }
policy() { apt-cache "${apt_opts[@]}" policy "$1"; }
candidate() { policy "$1" | perl -ne 'if (/^\s*Candidate: (.+)$/) { print "$1\n"; exit }'; }
[[ "$(candidate cerastream)" == 4.0 ]] || { printf 'non-vacuity: default APT must prefer Debian 4.0\n' >&2; policy cerastream >&2; exit 1; }

names_b64="$(base64 -w0 "${ROOT}/manifests/first-party-apt-names.txt")"
export CERALIVE_FIRST_PARTY_NAMES_B64="${names_b64}"
awk -F= '/^[a-z0-9][a-z0-9+.-]*(\[(amd64|arm64)\])?=/ {sub(/\[.*/, "", $1); print $1}' \
  "${ROOT}/manifests/first-party-deb-versions.txt" | sort -u >"${work}/pinned-names"
awk '!/^[[:space:]]*#/ && ($1 == "gstreamer1.0-rockchip-ceralive" || $1 == "librga2-ceralive") {print $1}' \
  "${ROOT}/manifests/rk3588-userspace-deb-versions.txt" >>"${work}/pinned-names"
sort -u "${work}/pinned-names" -o "${work}/pinned-names"
awk 'NF && $1 !~ /^#/ {print $1}' "${ROOT}/mkosi/runtime/first-party-origin-names.txt" | sort >"${work}/authority-names"
cmp "${work}/pinned-names" "${work}/authority-names" || { printf 'origin-name authority differs from pinned first-party package manifests\n' >&2; exit 1; }
awk 'NF && $1 !~ /^#/ {print $1}' "${ROOT}/manifests/first-party-apt-names.txt" | sort >"${work}/input-names"
cmp "${work}/input-names" "${work}/authority-names" || { printf 'origin names manifest differs from independent authority (missing, extra or duplicate name)\n' >&2; exit 1; }
export APT_CERALIVE_REPO_NO_AUTORUN=1
export APT_PREFERENCES_DIR="${work}/preferences-customize"
# shellcheck source=/dev/null
source "${ROOT}/mkosi/customize/apt-ceralive-repo.sh"
assert_rejected() {
  local writer="$1" scenario="$2" text="$3" reason="$4" encoded
  encoded="$(printf '%s\n' "$text" | base64 -w0)"
  if (CERALIVE_FIRST_PARTY_NAMES_B64="$encoded"; "$writer") >"${work}/${scenario}-${writer}.log" 2>&1; then
    printf '%s accepted %s first-party names\n' "$writer" "$scenario" >&2; exit 1
  fi
  if ! grep -Fq -- "$reason" "${work}/${scenario}-${writer}.log"; then
    printf '%s refused %s without naming %s\n' "$writer" "$scenario" "$reason" >&2
    command cat "${work}/${scenario}-${writer}.log" >&2; exit 1
  fi
}
if (unset CERALIVE_FIRST_PARTY_NAMES_B64; install_apt_preferences) >"${work}/missing-customize.log" 2>&1; then
  printf 'customize writer accepted missing names for origin protection\n' >&2; exit 1
fi
if (CERALIVE_FIRST_PARTY_NAMES_B64="$(printf '# no packages\n' | base64 -w0)"; install_apt_preferences) >"${work}/empty-customize.log" 2>&1; then
  printf 'customize writer accepted zero first-party names\n' >&2; exit 1
fi
install_apt_preferences

# The real build runs the runtime writer. It writes only inside this throwaway
# container; extract its actual function, without reimplementing its pin logic.
eval "$(perl -0777 -ne 'print $1 if /(setup_ceralive_repository\(\) \{.*?^\})/ms' "${ROOT}/mkosi/mkosi.images/runtime/mkosi.postinst.chroot")"
declare -F setup_ceralive_repository >/dev/null
log() { :; }
export CHANNEL=stable
export CERALIVE_RUNTIME_SRC="${ROOT}/mkosi/runtime"
for writer in install_apt_preferences setup_ceralive_repository; do
  assert_rejected "$writer" short "$(printf '%s\n' "$names_b64" | base64 -d | awk '$0 != "ceralive-apt-credentials"')" 'missing: ceralive-apt-credentials'
  assert_rejected "$writer" missing-critical "$(printf '%s\n' "$names_b64" | base64 -d | awk '$0 != "cerastream"')" 'missing: cerastream'
  assert_rejected "$writer" extra "$(printf '%s\n' "$names_b64" | base64 -d)"$'\nforeign-package' 'unexpected: foreign-package'
  assert_rejected "$writer" duplicate "$(printf '%s\n' "$names_b64" | base64 -d)"$'\ncerastream' 'duplicate: cerastream'
  assert_rejected "$writer" malformed "$(printf '%s\n' "$names_b64" | base64 -d)"$'\nBad!Package' 'invalid first-party package name'
  assert_rejected "$writer" empty '# only comments' 'first-party names list is empty'
done
if (unset CERALIVE_FIRST_PARTY_NAMES_B64; setup_ceralive_repository) >"${work}/missing-runtime.log" 2>&1; then
  printf 'runtime writer accepted missing names for origin protection\n' >&2; exit 1
fi
if (CERALIVE_FIRST_PARTY_NAMES_B64="$(printf '# no packages\n' | base64 -w0)"; setup_ceralive_repository) >"${work}/empty-runtime.log" 2>&1; then
  printf 'runtime writer accepted zero first-party names\n' >&2; exit 1
fi
setup_ceralive_repository
for writer in install_apt_preferences setup_ceralive_repository; do
  CERALIVE_FIRST_PARTY_NAMES_B64="$( { printf '   # indented comment\n  \n'; base64 -d <<<"$names_b64"; } | base64 -w0)" "$writer"
done
expected_names="$(awk 'NF && $1 !~ /^#/ {n++} END {print n+0}' "${ROOT}/manifests/first-party-apt-names.txt")"
[[ "$(grep -c '^Package: ' /etc/apt/preferences.d/ceralive-origin)" == "$((expected_names * 2))" ]] || {
  printf 'runtime pin count does not match first-party names manifest\n' >&2; exit 1
}
for writer in install_apt_preferences setup_ceralive_repository; do
  mutant="$(declare -f "$writer" | perl -pe 'if (/Pin: origin \*/ && /printf/) { $_ = "        :\n"; $found++ } END { die "expected one stanza writer\n" unless $found == 1 }')"
  if (eval "$mutant"; "$writer") >"${work}/missing-stanza-${writer}.log" 2>&1; then
    printf '%s accepted fewer pin stanzas than names\n' "$writer" >&2; exit 1
  fi
done
printf 'both preference writers reject absent, empty and incomplete name policy\n'
cmp "${APT_PREFERENCES_DIR}/ceralive-origin" /etc/apt/preferences.d/ceralive-origin >/dev/null && {
  printf 'writers must differ only in their generated-by comment\n' >&2; exit 1;
}
for writer in customize runtime; do
  if [[ "$writer" == customize ]]; then
    cp "${APT_PREFERENCES_DIR}/ceralive-origin" "${work}/apt/etc/preferences.d/ceralive-origin"
  else
    cp /etc/apt/preferences.d/ceralive-origin "${work}/apt/etc/preferences.d/ceralive-origin"
  fi
  # Ignore only the generated-by comment: byte-equivalent operative preferences.
  perl -ne 'print unless /^#/' "${work}/apt/etc/preferences.d/ceralive-origin" >"${work}/${writer}.rules"
  if [[ "$writer" == runtime ]]; then cmp "${work}/customize.rules" "${work}/runtime.rules"; fi

  [[ "$(candidate cerastream)" == 2.0 ]] || { printf '%s: our 990 candidate did not win\n' "$writer" >&2; policy cerastream >&2; exit 1; }
  policy cerastream | perl -0777 -ne 'exit(!/2\.0\s+990\s+500\s+http:\/\/apt\.ceralive\.tv/)' || { printf '%s: our hostname did not get 990\n' "$writer" >&2; policy cerastream >&2; exit 1; }
  [[ "$(candidate unrelated-debian-tool)" == 1.0 ]] || { printf '%s: unrelated Debian package blocked\n' "$writer" >&2; policy unrelated-debian-tool >&2; exit 1; }

  # Removing only our package from the same local archive must not allow either
  # the Debian 4.0 or the foreign 3.0 candidate to take its place.
  : >"${work}/ours/Packages"
  write_release ours
  apt-get "${apt_opts[@]}" update >"${work}/update.log" 2>&1 || { command cat "${work}/update.log" >&2; exit 1; }
  [[ "$(candidate cerastream)" == '(none)' ]] || { printf '%s: foreign/Debian candidate escaped when ours is absent\n' "$writer" >&2; policy cerastream >&2; exit 1; }
  policy cerastream | perl -0777 -ne 'exit(!/4\.0 -1\s+500 file:.*debian.*3\.0 -1\s+500 file:.*foreign/s)' || { printf '%s: Debian or foreign source did not receive -1\n' "$writer" >&2; policy cerastream >&2; exit 1; }
  printf '%s: absent-ours rejected foreign and Debian candidates\n' "$writer"
  cat >"${work}/ours/Packages" <<'PACKAGES'
Package: cerastream
Version: 2.0
Architecture: all
Filename: pool/cerastream_2.0_all.deb
Size: 100
Maintainer: Fixture <fixture@example.invalid>
Description: first-party candidate

PACKAGES
  write_release ours
  apt-get "${apt_opts[@]}" update >"${work}/update.log" 2>&1 || { command cat "${work}/update.log" >&2; exit 1; }
  cat >"${work}/apt/status" <<'STATUS'
Package: cerastream
Status: install ok installed
Priority: optional
Section: video
Installed-Size: 1
Maintainer: Fixture <fixture@example.invalid>
Architecture: all
Version: 1.0
Description: installed older version
STATUS
  [[ "$(candidate cerastream)" == 2.0 ]] || { printf '%s: our newer version was not selected\n' "$writer" >&2; policy cerastream >&2; exit 1; }
  apt-get "${apt_opts[@]}" -s upgrade | grep -q '^Inst cerastream \[1\.0\] (2\.0' || {
    printf '%s: apt-get -s upgrade did not select our newer release\n' "$writer" >&2; exit 1;
  }
  cat >"${work}/apt/status" <<'STATUS'
Package: cerastream
Status: install ok installed
Priority: optional
Section: video
Installed-Size: 1
Maintainer: Fixture <fixture@example.invalid>
Architecture: all
Version: 10.0
Description: installed newer version
STATUS
  [[ "$(candidate cerastream)" == 10.0 ]] || { printf '%s: 990 silently downgraded installed 10.0\n' "$writer" >&2; policy cerastream >&2; exit 1; }
  if apt-get "${apt_opts[@]}" -s upgrade | grep -q '^Inst cerastream'; then
    printf '%s: apt-get -s upgrade would replace installed 10.0\n' "$writer" >&2; exit 1
  fi
  : >"${work}/apt/status"
done
printf 'apt-first-party-origin: PASS (both real writers, 990, upgrade, foreign/Debian absent, no downgrade, unrelated Debian)\n'
