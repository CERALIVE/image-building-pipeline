#!/usr/bin/env bash
# Exercise the shipped fetch functions offline; curl's shim models exit-56 retry.
set -uo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/assertions.sh
source "${repo}/tests/lib/assertions.sh"
# shellcheck source=lib/fetch/index.sh
source "${repo}/lib/fetch/index.sh"
# shellcheck source=lib/rauc-build/source.sh
source "${repo}/lib/rauc-build/source.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
mkdir -p "${work}/bin" "${work}/fixtures"
export CURL_FIXTURES="${work}/fixtures" CURL_ATTEMPTS="${work}/attempts"
export PATH="${work}/bin:${PATH}"
log_info() { :; }
log_success() { :; }
log_error() { printf '%s\n' "$*" >&2; }
die() { log_error "$*"; exit 1; }
# Signature verification is a separate contract; these tests start from trusted
# Release bytes, but execute the real index and source-tar digest checks.
auth_verify_release_to_file() { cp "$2" "$3"; }
cat >"${work}/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
retry=0 all_errors=0 dest='' url=''
while (( $# )); do
  case "$1" in
    --retry) retry="$2"; shift 2 ;;
    --retry-all-errors) all_errors=1; shift ;;
    -o) dest="$2"; shift 2 ;;
    --connect-timeout|--max-time) shift 2 ;;
    -fsSL) shift ;;
    https://*) url="$1"; shift ;;
    *) exit 2 ;;
  esac
done
name="${url##*/}"
attempt() {
  printf '%s %s\n' "${name}" "$1" >>"${CURL_ATTEMPTS}"
  if [[ "${name}" == "${FAIL_TARGET}" ]] && (( $1 <= FAIL_COUNT )); then
    printf partial >"${dest}"
    return 56
  fi
  cp "${CURL_FIXTURES}/${name}" "${dest}"
}
for ((i=0; ; i++)); do
  if attempt "$((i + 1))"; then exit 0; else status=$?; fi
  (( all_errors && i < retry )) || exit "${status}"
done
SH
chmod +x "${work}/bin/curl"
printf upstream >"${CURL_FIXTURES}/upstream.tar.xz"
printf packaging >"${CURL_FIXTURES}/rauc_1.15.2-1.debian.tar.xz"
upstream_sha="$(sha256sum "${CURL_FIXTURES}/upstream.tar.xz")"
upstream_sha="${upstream_sha%% *}"
packaging_sha="$(sha256sum "${CURL_FIXTURES}/rauc_1.15.2-1.debian.tar.xz")"
packaging_sha="${packaging_sha%% *}"
printf 'Package: rauc\nVersion: 1.15.2-1\nChecksums-Sha256:\n %s 9 rauc_1.15.2-1.debian.tar.xz\n\n' \
  "${packaging_sha}" | xz >"${CURL_FIXTURES}/Sources.xz"
sources_sha="$(sha256sum "${CURL_FIXTURES}/Sources.xz")"
sources_sha="${sources_sha%% *}"
printf 'SHA256:\n %s %s main/source/Sources.xz\n' "${sources_sha}" \
  "$(stat -c %s "${CURL_FIXTURES}/Sources.xz")" >"${CURL_FIXTURES}/InRelease"
touch "${work}/keyring"

# Given one or three SSL read failures, when upstream acquisition runs, then
# only the complete, digest-verified response is published.
for failures in 1 3; do
  export FAIL_TARGET=upstream.tar.xz FAIL_COUNT="${failures}"
  if (set -e; rauc_fetch_upstream_tarball https://fixture.invalid/upstream.tar.xz \
      "${upstream_sha}" "${work}/upstream-${failures}") && \
      cmp -s "${CURL_FIXTURES}/upstream.tar.xz" "${work}/upstream-${failures}"; then
    ok "upstream succeeds after ${failures} exit-56 failures"
  else
    bad "upstream fails after ${failures} exit-56 failures"
  fi
done

# Given a transient failure at each Debian fetch boundary, when the packaging
# fetch runs, then its final output matches the trusted Sources digest.
for target in InRelease Sources.xz rauc_1.15.2-1.debian.tar.xz; do
  export FAIL_TARGET="${target}" FAIL_COUNT=1
  if (set -e; rauc_fetch_debian_packaging unstable main 1.15.2-1 \
      rauc_1.15.2-1.debian.tar.xz "${work}/keyring" "${work}/${target}.result" fixture-key) && \
      cmp -s "${CURL_FIXTURES}/rauc_1.15.2-1.debian.tar.xz" "${work}/${target}.result"; then
    ok "Debian packaging recovers from exit 56 at ${target}"
  else
    bad "Debian packaging fails at ${target}"
  fi
done

# Given more failures than the retry budget, when fetching, then the existing
# destination survives and the function fails rather than publishing partial data.
export FAIL_TARGET=upstream.tar.xz FAIL_COUNT=4
printf existing >"${work}/existing"
cp "${work}/existing" "${work}/exhausted"
if (set -e; rauc_fetch_upstream_tarball https://fixture.invalid/upstream.tar.xz \
    "${upstream_sha}" "${work}/exhausted"); then
  bad 'retry exhaustion was accepted'
elif cmp -s "${work}/existing" "${work}/exhausted"; then
  ok 'retry exhaustion preserves the destination'
else
  bad 'retry exhaustion changed the destination'
fi

# Given a successful but corrupt response, when fetching, then digest validation
# still refuses it; retry broadening must never bypass integrity checks.
export FAIL_COUNT=0
if (set -e; rauc_fetch_upstream_tarball https://fixture.invalid/upstream.tar.xz \
    "${packaging_sha}" "${work}/corrupt"); then
  bad 'corrupt upstream response was accepted'
else
  ok 'corrupt upstream response is refused'
fi
printf ' RESULT: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
