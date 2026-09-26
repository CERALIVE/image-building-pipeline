#!/usr/bin/env bash
# shellcheck disable=SC2016  # bash -c bodies expand in the child shell, by design
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck source=tests/lib/assertions.sh
source "${HERE}/lib/assertions.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/first-party-override-XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
for tool in dpkg-deb python3 sha256sum; do
  command -v "${tool}" >/dev/null 2>&1 || { bad "missing ${tool}"; exit 1; }
done

make_deb() {
  local pkg="$1" version="$2" arch="$3" dest="$4" stage="${WORK}/package"
  rm -rf "${stage}"
  mkdir -p "${stage}/DEBIAN" "${stage}/usr/share/ceralive"
  printf 'Package: %s\nVersion: %s\nArchitecture: %s\nMaintainer: Fixture <test@example.com>\nDescription: Local test package\n' \
    "${pkg}" "${version}" "${arch}" >"${stage}/DEBIAN/control"
  printf 'payload\n' >"${stage}/usr/share/ceralive/fixture"
  dpkg-deb -b "${stage}" "${dest}" >/dev/null
}

mkdir -p "${WORK}/overrides" "${WORK}/cache"
make_deb ceralive-device 99.2 arm64 "${WORK}/overrides/local.deb"
export TEST_PINS="${WORK}/pins" TEST_OVERRIDE="${WORK}/overrides" TEST_ROOT="${WORK}"
printf 'ceralive-device=1.0\nceralive-modem-support=1.0\n' >"${TEST_PINS}"
export APT_GPG_PUBLIC_B64
APT_GPG_PUBLIC_B64="$(printf key | base64 -w0)"

fetch_case() {
  local dest="$1"; shift
  mkdir -p "${dest}/debs"
  env DEST="${dest}" CERALIVE_DEBCACHE_DIR="${WORK}/cache" "$@" \
    bash -c 'source "$1"; FIRST_PARTY_APT_PKGS=(ceralive-device); FIRST_PARTY_DEB_VERSIONS_FILE="$TEST_PINS"; fetch_first_party "$DEST/debs"' \
    _ "${ROOT}/lib/fetch-debs.sh"
}

if fetch_case "${WORK}/accepted" CERALIVE_BUILD_MODE=development \
    CERALIVE_FIRST_PARTY_LOCAL_DEBS_DIR="${TEST_OVERRIDE}" >"${WORK}/accepted.log" 2>&1; then
  ok 'development override passes staged identity validation against its own version 99.2 (pin is 1.0)'
else
  bad "development override rejected: $(<"${WORK}/accepted.log")"
fi
sha="$(sha256sum "${TEST_OVERRIDE}/local.deb" | cut -d' ' -f1)"
if python3 - "${WORK}/accepted/first-party-local-override.json" "${sha}" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as source:
    rows = json.load(source)
assert rows == [{'package': 'ceralive-device', 'version': '99.2', 'arch': 'arm64',
                 'sha256': sys.argv[2], 'filename': 'ceralive-device_99.2_arm64.deb'}]
PY
then ok 'manifest has exact control identity, digest and staged filename'; else bad 'manifest shape/content'; fi
staged="${WORK}/accepted/debs/ceralive-device_99.2_arm64.deb"
if [[ -f "${staged}" && "$(stat -c %a "${staged}")" == 644 ]]; then
  ok 'local bytes stage atomically as mode 0644'
else
  bad 'staged file/mode'
fi
if [[ -z "$(ls -A "${WORK}/cache")" ]]; then ok 'local .deb never enters verified .debcache'; else bad 'cache changed'; fi
if [[ "$(grep -Fc 'FIRST-PARTY LOCAL OVERRIDE (bench only): ceralive-device=99.2 sha256=' "${WORK}/accepted.log")" == 1 ]]; then
  ok 'exactly one override warning emitted'
else
  bad 'override warning count'
fi

make_deb ceralive-modem-support 1.0 all "${WORK}/pinned.deb"
export TEST_PINNED_DEB="${WORK}/pinned.deb" TEST_APT_ARGS="${WORK}/apt-args"
if env DEST="${WORK}/partial" CERALIVE_DEBCACHE=0 \
    CERALIVE_FIRST_PARTY_LOCAL_DEBS_DIR="${TEST_OVERRIDE}" bash -c '
      source "$1"
      FIRST_PARTY_APT_PKGS=(ceralive-device ceralive-modem-support)
      FIRST_PARTY_DEB_VERSIONS_FILE="$TEST_PINS"
      mkdir -p "$DEST/debs"
      apt-get() {
        case " $* " in
          *" download "*) printf "%s\n" "$*" >"$TEST_APT_ARGS"; cp "$TEST_PINNED_DEB" ./ceralive-modem-support_1.0_all.deb ;;
        esac
      }
      fetch_first_party "$DEST/debs"
    ' _ "${ROOT}/lib/fetch-debs.sh" >"${WORK}/partial.log" 2>&1; then
  ok 'mixed local + pinned fetch validates both packages'
else
  bad "mixed fetch failed: $(<"${WORK}/partial.log")"
fi
if [[ -s "${TEST_APT_ARGS}" && "$(<"${TEST_APT_ARGS}")" == *'ceralive-modem-support=1.0'* \
   && "$(<"${TEST_APT_ARGS}")" != *'ceralive-device='* ]]; then
  ok 'overridden package excluded from normal apt download list'
else
  bad 'apt download list contains override or omits pinned package'
fi
mkdir -p "${WORK}/empty" "${WORK}/empty-run/debs" "${WORK}/unset-run/debs"
for case_name in empty unset; do
  if [[ "${case_name}" == empty ]]; then
    case_env=(CERALIVE_FIRST_PARTY_LOCAL_DEBS_DIR="${WORK}/empty")
  else
    case_env=()
  fi
  if env DEST="${WORK}/${case_name}-run" "${case_env[@]}" bash -c '
    source "$1"
    FIRST_PARTY_APT_PKGS=(ceralive-modem-support)
    FIRST_PARTY_DEB_VERSIONS_FILE="$TEST_PINS"
    apt-get() { case " $* " in *" download "*) cp "$TEST_PINNED_DEB" ./ceralive-modem-support_1.0_all.deb ;; esac; }
    fetch_first_party "$DEST/debs"
  ' _ "${ROOT}/lib/fetch-debs.sh" >"${WORK}/${case_name}.log" 2>&1 \
    && [[ "$(<"${WORK}/${case_name}-run/first-party-local-override.json")" == '[]' ]]; then
    ok "${case_name} override writes an empty JSON array"
  else
    bad "${case_name} override manifest missing/invalid: $(<"${WORK}/${case_name}.log")"
  fi
done

reject() {
  local title="$1" expected="$2"; shift 2
  if fetch_case "${WORK}/rejected-${title}" "$@" >"${WORK}/rejected.log" 2>&1; then
    bad "${title}: override accepted"
  elif grep -Fq "${expected}" "${WORK}/rejected.log"; then
    ok "${title}: refused before accepting override"
  else
    bad "${title}: wrong refusal: $(<"${WORK}/rejected.log")"
  fi
}
reject production 'refused in production mode' CERALIVE_BUILD_MODE=production CERALIVE_FIRST_PARTY_LOCAL_DEBS_DIR="${TEST_OVERRIDE}"
reject actions 'refused in GitHub Actions' GITHUB_ACTIONS=true CERALIVE_FIRST_PARTY_LOCAL_DEBS_DIR="${TEST_OVERRIDE}"
make_deb wrong-name 99.2 arm64 "${TEST_OVERRIDE}/local.deb"
reject unknown 'unknown first-party local override package' CERALIVE_FIRST_PARTY_LOCAL_DEBS_DIR="${TEST_OVERRIDE}"
make_deb ceralive-device 99.2 arm64 "${TEST_OVERRIDE}/local.deb"
cp "${TEST_OVERRIDE}/local.deb" "${TEST_OVERRIDE}/duplicate.deb"
reject duplicate 'duplicate first-party local override package' CERALIVE_FIRST_PARTY_LOCAL_DEBS_DIR="${TEST_OVERRIDE}"
rm "${TEST_OVERRIDE}/duplicate.deb"
make_deb ceralive-device 99.2 amd64 "${TEST_OVERRIDE}/local.deb"
reject architecture 'architecture/identity mismatch' CERALIVE_FIRST_PARTY_LOCAL_DEBS_DIR="${TEST_OVERRIDE}"
make_deb ceralive-device 99.2 all "${TEST_OVERRIDE}/local.deb"
reject arch-all-disallowed 'architecture/identity mismatch' CERALIVE_FIRST_PARTY_LOCAL_DEBS_DIR="${TEST_OVERRIDE}"
make_deb ceralive-modem-support 99.2 all "${TEST_OVERRIDE}/local.deb"
if env DEST="${WORK}/arch-all" CERALIVE_FIRST_PARTY_LOCAL_DEBS_DIR="${TEST_OVERRIDE}" \
    bash -c 'source "$1"; FIRST_PARTY_APT_PKGS=(ceralive-modem-support); FIRST_PARTY_DEB_VERSIONS_FILE="$TEST_PINS"; mkdir -p "$DEST/debs"; fetch_first_party "$DEST/debs"' \
      _ "${ROOT}/lib/fetch-debs.sh" >"${WORK}/arch-all.log" 2>&1; then
  ok 'arch-all allowlisted companion accepts Architecture: all'
else
  bad "arch-all companion rejected: $(<"${WORK}/arch-all.log")"
fi

# Captured once from the pre-change fetch_first_party with the same deterministic
# logger and fixed DEST; compare the complete plan, not selected substrings.
plan() {
  DRY_RUN=1 DEST=/tmp/ceralive-task44-golden ARCH=arm64 CERALIVE_APT_PROXY=off \
    bash -c 'source "$1" >/dev/null; log_info() { printf "INFO %s\n" "$*"; }; log_warn() { printf "WARN %s\n" "$*"; }; log_success() { printf "OK %s\n" "$*"; }; fetch_first_party "${DEST}/debs"' _ "${ROOT}/lib/fetch-debs.sh"
}
read -r -d '' baseline <<'PLAN' || :
INFO first-party pins (versions.yaml):
INFO   srt = srt-v1.5.7+ceralive.2
INFO   cerastream = v2026.9.6
INFO   CeraUI = v2026.9.3
INFO   srtla = v4.1.0
INFO   modem-stack = v1.4.0
INFO first-party source: https://apt.ceralive.tv/dists/stable/binary-arm64/ (GPG Signed-By + mTLS)
INFO first-party packages: libsrt1.5-ceralive cerastream gstreamer1.0-libuvcsrc ceralive-device srtla modemmanager libmm-glib0 libmbim-glib4 libmbim-proxy libmbim-utils libqmi-glib5 libqmi-proxy libqmi-utils libqrtr-glib0 ceralive-modem-support ceralive-apt-credentials
INFO first-party apt specs: libsrt1.5-ceralive=1.5.7+ceralive.2 cerastream=2026.9.6 gstreamer1.0-libuvcsrc=2026.9.0 ceralive-device=2026.9.3-20260920T155654.ec522ad srtla=4.1.0 modemmanager=1.24.2-2~ceralive.3 libmm-glib0=1.24.2-2~ceralive.3 libmbim-glib4=1.34.0-1~ceralive.3 libmbim-proxy=1.34.0-1~ceralive.3 libmbim-utils=1.34.0-1~ceralive.3 libqmi-glib5=1.38.0-1~ceralive.3 libqmi-proxy=1.38.0-1~ceralive.3 libqmi-utils=1.38.0-1~ceralive.3 libqrtr-glib0=1.4.0-1~ceralive.3 ceralive-modem-support=1.4.0 ceralive-apt-credentials=1.0.0
INFO DRY-RUN would run: mkdir -p /tmp/ceralive-task44-golden/debs/.apt-state-firstparty/lists/partial /tmp/ceralive-task44-golden/debs/.apt-state-firstparty/cache/archives/partial /tmp/ceralive-task44-golden/debs/.apt-state-firstparty/certs
INFO DRY-RUN would write deb822 source -> /tmp/ceralive-task44-golden/debs/.apt-state-firstparty/ceralive.sources: Types=deb URIs=https://apt.ceralive.tv/dists/stable/binary-arm64/ Suites=./ Signed-By=/tmp/ceralive-task44-golden/debs/.apt-state-firstparty/ceralive-archive-keyring.gpg
INFO DRY-RUN: would install GPG keyring from APT_GPG_PUBLIC_B64 -> /tmp/ceralive-task44-golden/debs/.apt-state-firstparty/ceralive-archive-keyring.gpg
INFO DRY-RUN would run: apt-get -o Dir::Etc::SourceList=/tmp/ceralive-task44-golden/debs/.apt-state-firstparty/ceralive.sources -o Dir::Etc::SourceParts=- -o Dir::State::Lists=/tmp/ceralive-task44-golden/debs/.apt-state-firstparty/lists -o Dir::Cache=/tmp/ceralive-task44-golden/debs/.apt-state-firstparty/cache -o Dir::Cache::Archives=/tmp/ceralive-task44-golden/debs/.apt-state-firstparty/cache/archives -o APT::Architecture=arm64 update
INFO DRY-RUN would run: (cd /tmp/ceralive-task44-golden/debs && apt-get -o Dir::Etc::SourceList=/tmp/ceralive-task44-golden/debs/.apt-state-firstparty/ceralive.sources -o Dir::Etc::SourceParts=- -o Dir::State::Lists=/tmp/ceralive-task44-golden/debs/.apt-state-firstparty/lists -o Dir::Cache=/tmp/ceralive-task44-golden/debs/.apt-state-firstparty/cache -o Dir::Cache::Archives=/tmp/ceralive-task44-golden/debs/.apt-state-firstparty/cache/archives -o APT::Architecture=arm64 download libsrt1.5-ceralive=1.5.7+ceralive.2 cerastream=2026.9.6 gstreamer1.0-libuvcsrc=2026.9.0 ceralive-device=2026.9.3-20260920T155654.ec522ad srtla=4.1.0 modemmanager=1.24.2-2~ceralive.3 libmm-glib0=1.24.2-2~ceralive.3 libmbim-glib4=1.34.0-1~ceralive.3 libmbim-proxy=1.34.0-1~ceralive.3 libmbim-utils=1.34.0-1~ceralive.3 libqmi-glib5=1.38.0-1~ceralive.3 libqmi-proxy=1.38.0-1~ceralive.3 libqmi-utils=1.38.0-1~ceralive.3 libqrtr-glib0=1.4.0-1~ceralive.3 ceralive-modem-support=1.4.0 ceralive-apt-credentials=1.0.0)  # from https://apt.ceralive.tv/dists/stable/
PLAN
if [[ "$(plan 2>/dev/null)" == "${baseline%$'\n'}" ]]; then
  ok 'unset DRY_RUN plan byte-identical to the pre-change capture (fixed DEST/logger)'
else
  bad 'unset DRY_RUN plan differs from the pre-change capture'
fi

if grep -l 'CERALIVE_FIRST_PARTY_LOCAL_DEBS_DIR' "${ROOT}"/.github/workflows/*.yml >/dev/null; then
  bad 'a GitHub workflow sets the bench-only override variable'
else
  ok 'no GitHub workflow sets the bench-only override variable'
fi
printf '\n== %d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
