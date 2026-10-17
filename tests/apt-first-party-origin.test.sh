#!/usr/bin/env bash
# Real, offline APT candidate resolution for both image preferences writers.
set -uo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assertions.sh
source "${ROOT}/tests/lib/assertions.sh"
check() { if "$@"; then ok "$*"; else bad "$*"; fi; }
work=''
server_pid=''
finish() {
  local status=$?
  [[ "$status" -eq 0 || "$FAIL" -gt 0 ]] || bad "unexpected exit: $status"
  if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || :; wait "$server_pid" 2>/dev/null || :; fi
  [[ -z "$work" ]] || rm -rf -- "$work"
  printf ' RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
  [[ "$FAIL" -eq 0 ]]
}
trap 'finish; exit $?' EXIT
set -o errtrace
trap 'bad "fixture command failed at line $LINENO: $BASH_COMMAND"; exit 1' ERR
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
candidate() { policy "$1" | perl -0777 -ne 'print "$1\n" if /^\s*Candidate: (.+)$/m'; }
assert_eq 'non-vacuity: default APT prefers Debian' 4.0 "$(candidate cerastream)"

names_b64="$(base64 -w0 "${ROOT}/manifests/first-party-apt-names.txt")"
export CERALIVE_FIRST_PARTY_NAMES_B64="${names_b64}"
awk 'NF && $1 !~ /^#/ {print $1}' "${ROOT}/mkosi/runtime/first-party-origin-names.txt" | sort >"${work}/authority-names"
check_pinned_authority() {
  local rk_pins="$1"
  awk -F= '/^[a-z0-9][a-z0-9+.-]*(\[(amd64|arm64)\])?=/ {sub(/\[.*/, "", $1); print $1}' \
    "${ROOT}/manifests/first-party-deb-versions.txt" | sort -u >"${work}/pinned-names"
  # Provenance, not a two-name allowlist: every active CERALIVE GitHub release
  # asset here is first-party, regardless of the package name it gives the .deb.
  awk '!/^[[:space:]]*#/ && $4 ~ /^https:\/\/github[.]com\/CERALIVE\/[^/]+\/releases\/download\// {print $1}' \
    "$rk_pins" >>"${work}/pinned-names"
  sort -u "${work}/pinned-names" -o "${work}/pinned-names"
  cmp "${work}/pinned-names" "${work}/authority-names" || { printf 'origin-name authority differs from pinned first-party package manifests\n' >&2; return 1; }
}
check check_pinned_authority "${ROOT}/manifests/rk3588-userspace-deb-versions.txt"
cp "${ROOT}/manifests/rk3588-userspace-deb-versions.txt" "${work}/rk-first-party.txt"
printf '%s\n' 'rockchip-new-fork rockchip-new-fork_1_arm64.deb 0000000000000000000000000000000000000000000000000000000000000000 https://github.com/CERALIVE/new-fork/releases/download/v1/rockchip-new-fork_1_arm64.deb' >>"${work}/rk-first-party.txt"
if check_pinned_authority "${work}/rk-first-party.txt" >"${work}/first-party-mutation.log" 2>&1; then
  bad 'origin-name authority accepted an unprotected new CeraLive RK3588 package'
else
  ok 'new CeraLive RK3588 package refused'
fi
if ! grep -Fq 'origin-name authority differs from pinned first-party package manifests' "${work}/first-party-mutation.log" ||
   ! grep -Fxq 'rockchip-new-fork' "${work}/pinned-names"; then
  bad 'origin-name authority did not reject the new CeraLive package as a pinned name'
else
  ok 'new CeraLive package diagnosed as pinned name'
fi
cp "${ROOT}/manifests/rk3588-userspace-deb-versions.txt" "${work}/rk-third-party.txt"
printf '%s\n' 'rockchip-new-foreign rockchip-new-foreign_1_arm64.deb 0000000000000000000000000000000000000000000000000000000000000000 https://github.com/tsukumijima/new-fork/releases/download/v1/rockchip-new-foreign_1_arm64.deb' >>"${work}/rk-third-party.txt"
check check_pinned_authority "${work}/rk-third-party.txt"
awk 'NF && $1 !~ /^#/ {print $1}' "${ROOT}/manifests/first-party-apt-names.txt" | sort >"${work}/input-names"
check cmp "${work}/input-names" "${work}/authority-names"
export APT_CERALIVE_REPO_NO_AUTORUN=1
export APT_PREFERENCES_DIR="${work}/preferences-customize"
# shellcheck source=/dev/null
source "${ROOT}/mkosi/customize/apt-ceralive-repo.sh"
set +e
trap 'bad "fixture command failed at line $LINENO: $BASH_COMMAND"; exit 1' ERR
assert_rejected() {
  local writer="$1" scenario="$2" text="$3" reason="$4" encoded
  encoded="$(printf '%s\n' "$text" | base64 -w0)"
  if (CERALIVE_FIRST_PARTY_NAMES_B64="$encoded"; "$writer") >"${work}/${scenario}-${writer}.log" 2>&1; then
    bad "$writer accepted $scenario first-party names"
  else
    ok "$writer refused $scenario first-party names"
  fi
  if ! grep -Fq -- "$reason" "${work}/${scenario}-${writer}.log"; then
    bad "$writer refused $scenario without naming $reason"
    command cat "${work}/${scenario}-${writer}.log" >&2
  else
    ok "$writer diagnosed $scenario: $reason"
  fi
}
if (unset CERALIVE_FIRST_PARTY_NAMES_B64; install_apt_preferences) >"${work}/missing-customize.log" 2>&1; then
  bad 'customize writer accepted missing names for origin protection'
else
  ok 'customize writer refused missing names'
fi
if (CERALIVE_FIRST_PARTY_NAMES_B64="$(printf '# no packages\n' | base64 -w0)"; install_apt_preferences) >"${work}/empty-customize.log" 2>&1; then
  bad 'customize writer accepted zero first-party names'
else
  ok 'customize writer refused zero names'
fi
check install_apt_preferences

# The real build runs the runtime writer. It writes only inside this throwaway
# container; extract its actual function, without reimplementing its pin logic.
eval "$(perl -0777 -ne 'print $1 if /(setup_ceralive_repository\(\) \{.*?^\})/ms' "${ROOT}/mkosi/mkosi.images/runtime/mkosi.postinst.chroot")"
check declare -F setup_ceralive_repository >/dev/null
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
  bad 'runtime writer accepted missing names for origin protection'
else
  ok 'runtime writer refused missing names'
fi
if (CERALIVE_FIRST_PARTY_NAMES_B64="$(printf '# no packages\n' | base64 -w0)"; setup_ceralive_repository) >"${work}/empty-runtime.log" 2>&1; then
  bad 'runtime writer accepted zero first-party names'
else
  ok 'runtime writer refused zero names'
fi
check setup_ceralive_repository
for writer in install_apt_preferences setup_ceralive_repository; do
  CERALIVE_FIRST_PARTY_NAMES_B64="$( { printf '   # indented comment\n  \n'; base64 -d <<<"$names_b64"; } | base64 -w0)" check "$writer"
done
expected_names="$(awk 'NF && $1 !~ /^#/ {n++} END {print n+0}' "${ROOT}/manifests/first-party-apt-names.txt")"
assert_eq 'runtime pin count matches manifest' "$((expected_names * 2))" "$(grep -c '^Package: ' /etc/apt/preferences.d/ceralive-origin)"
for writer in install_apt_preferences setup_ceralive_repository; do
  mutant="$(declare -f "$writer" | perl -pe 'if (/Pin: origin \*/ && /printf/) { $_ = "        :\n"; $found++ } END { die "expected one stanza writer\n" unless $found == 1 }')"
  if (eval "$mutant"; "$writer") >"${work}/missing-stanza-${writer}.log" 2>&1; then
    bad "$writer accepted fewer pin stanzas than names"
  else
    ok "$writer refused missing pin stanza"
  fi
done
if cmp "${APT_PREFERENCES_DIR}/ceralive-origin" /etc/apt/preferences.d/ceralive-origin >/dev/null; then
  bad 'writers must differ only in their generated-by comment'
else
  ok 'writer comments differ'
fi
for writer in customize runtime; do
  if [[ "$writer" == customize ]]; then
    cp "${APT_PREFERENCES_DIR}/ceralive-origin" "${work}/apt/etc/preferences.d/ceralive-origin"
  else
    cp /etc/apt/preferences.d/ceralive-origin "${work}/apt/etc/preferences.d/ceralive-origin"
  fi
  # Ignore only the generated-by comment: byte-equivalent operative preferences.
  perl -ne 'print unless /^#/' "${work}/apt/etc/preferences.d/ceralive-origin" >"${work}/${writer}.rules"
  if [[ "$writer" == runtime ]]; then check cmp "${work}/customize.rules" "${work}/runtime.rules"; fi

  assert_eq "$writer: our candidate wins" 2.0 "$(candidate cerastream)"
  if policy cerastream | perl -0777 -ne 'exit(!/2\.0\s+990\s+500\s+http:\/\/apt\.ceralive\.tv/)'; then ok "$writer: hostname gets 990"; else bad "$writer: hostname did not get 990"; policy cerastream >&2; fi
  assert_eq "$writer: unrelated Debian package allowed" 1.0 "$(candidate unrelated-debian-tool)"

  # Removing only our package from the same local archive must not allow either
  # the Debian 4.0 or the foreign 3.0 candidate to take its place.
  : >"${work}/ours/Packages"
  write_release ours
  apt-get "${apt_opts[@]}" update >"${work}/update.log" 2>&1 || { command cat "${work}/update.log" >&2; exit 1; }
  assert_eq "$writer: no foreign/Debian candidate without ours" '(none)' "$(candidate cerastream)"
  if policy cerastream | perl -0777 -ne 'exit(!/4\.0 -1\s+500 file:.*debian.*3\.0 -1\s+500 file:.*foreign/s)'; then ok "$writer: Debian and foreign priority -1"; else bad "$writer: Debian or foreign source did not receive -1"; policy cerastream >&2; fi
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
  assert_eq "$writer: newer release selected" 2.0 "$(candidate cerastream)"
  if apt-get "${apt_opts[@]}" -s upgrade | grep -q '^Inst cerastream \[1\.0\] (2\.0'; then ok "$writer: upgrade selects our newer release"; else bad "$writer: upgrade did not select our newer release"; fi
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
  assert_eq "$writer: 990 preserves installed newer release" 10.0 "$(candidate cerastream)"
  if apt-get "${apt_opts[@]}" -s upgrade | grep -q '^Inst cerastream'; then
    bad "$writer: upgrade would replace installed 10.0"
  else
    ok "$writer: upgrade does not replace installed 10.0"
  fi
  : >"${work}/apt/status"
done
trap - ERR
[[ "$FAIL" -eq 0 ]]
