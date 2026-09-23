#!/usr/bin/env bash
#
# apt-lib.test.sh — contract for the two extracted fetch transports:
#   lib/fetch/apt-lib.sh  (generic apt: isolated state + the sandbox gate)
#   lib/fetch/index.sh    (signed-index verification + explicit optional lookups)
#
# The legs that matter, in the order the plan names them:
#
#   isolated apt state  — one definition of the six redirecting options, and both
#                         former call sites use it
#   signed index        — the digest is read from the VERIFIED plaintext only; an
#                         index whose bytes do not match the signed digest is
#                         REJECTED, and a bad signature is refused outright rather
#                         than silently skipped
#   explicit optionals  — a cache probe distinguishes "not in the index" from
#                         "the index is unusable"; no fetch module swallows a
#                         failure with `|| true`
#   wrong arch          — an index entry for another architecture is not a hit

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"
APT_LIB="${PIPELINE_DIR}/lib/fetch/apt-lib.sh"
INDEX_LIB="${PIPELINE_DIR}/lib/fetch/index.sh"
AUTH_LIB="${PIPELINE_DIR}/lib/fetch-debs-auth.sh"

PASS=0
fail() { printf 'apt-lib: FAIL: %s\n' "$*" >&2; exit 1; }
ok()   { PASS=$(( PASS + 1 )); printf 'apt-lib: ok  %s\n' "$*"; }

for f in "${APT_LIB}" "${INDEX_LIB}" "${AUTH_LIB}"; do
  [[ -f "${f}" ]] || fail "missing source file: ${f}"
done

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# The libraries are sourced into a scrubbed subshell with only the loggers and
# run_or_plan they actually need, so this suite proves the MODULES rather than the
# fetch entry point that normally supplies their environment.
lib_eval() {
  local code="$1"; shift
  APT_LIB="${APT_LIB}" INDEX_LIB="${INDEX_LIB}" AUTH_LIB="${AUTH_LIB}" bash -c "
    set -euo pipefail
    log_info()    { printf 'INFO %s\\n'  \"\$*\" >&2; }
    log_warn()    { printf 'WARN %s\\n'  \"\$*\" >&2; }
    log_error()   { printf 'ERROR %s\\n' \"\$*\" >&2; }
    log_success() { printf 'OK %s\\n'    \"\$*\" >&2; }
    die()         { printf 'DIE %s\\n'   \"\$*\" >&2; exit 1; }
    run_or_plan() { \"\$@\"; }
    # shellcheck disable=SC1090
    source \"\${AUTH_LIB}\"
    # shellcheck disable=SC1090
    source \"\${APT_LIB}\"
    # shellcheck disable=SC1090
    source \"\${INDEX_LIB}\"
    ${code}
  " _ "$@"
}

# ---------------------------------------------------------------------------
# Isolated apt state
# ---------------------------------------------------------------------------
mapfile -t opts < <(CERALIVE_APT_PROXY=off lib_eval 'apt_isolated_opts "$1" "$2" "$3"' /st /st/src.list arm64)
(( ${#opts[@]} == 12 )) || fail "apt_isolated_opts emitted ${#opts[@]} tokens, expected 12"
joined="${opts[*]}"
for expect in \
  "Dir::Etc::SourceList=/st/src.list" \
  "Dir::Etc::SourceParts=-" \
  "Dir::State::Lists=/st/lists" \
  "Dir::Cache=/st/cache" \
  "Dir::Cache::Archives=/st/cache/archives" \
  "APT::Architecture=arm64"; do
  [[ "${joined}" == *"${expect}"* ]] || fail "apt_isolated_opts is missing '${expect}'"
done
ok "isolated: the six redirecting apt options are emitted as -o/value token pairs"

# Every path apt could reach for must point INSIDE the isolated state — a single
# absolute host path here is how the build-time fetch would start reading (or
# worse, writing) the developer's own apt configuration.
for i in "${!opts[@]}"; do
  [[ "${opts[$i]}" == "-o" ]] && continue
  case "${opts[$i]}" in
    Dir::*=/st/*|Dir::Etc::SourceParts=-|APT::Architecture=*) ;;
    *) fail "apt_isolated_opts emits a path outside the isolated state: ${opts[$i]}" ;;
  esac
done
ok "isolated: every Dir:: option stays inside the supplied state directory"

# ---------------------------------------------------------------------------
# Automatic apt proxy (CERALIVE_APT_PROXY)
# ---------------------------------------------------------------------------
# Unset must be a NO-OP down to the token count: an unconfigured build has to
# pass apt exactly the argument vector it passed before the proxy existed.
mapfile -t noproxy < <(CERALIVE_APT_PROXY=off lib_eval 'apt_isolated_opts "$1" "$2" "$3"' /st /st/src.list arm64)
(( ${#noproxy[@]} == 12 )) \
  || fail "an unset CERALIVE_APT_PROXY changed the option vector (${#noproxy[@]} tokens, expected 12)"
ok "proxy: CERALIVE_APT_PROXY=off emits nothing at all"

mkdir -p "${WORK}/bin"
cat >"${WORK}/bin/curl" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == *'--connect-timeout 1 --max-time 1 http://127.0.0.1:3142/acng-report.html'* ]] || exit 42
[[ "${CACHE_FIXTURE:-down}" == up ]]
EOF
chmod +x "${WORK}/bin/curl"
mapfile -t detected < <(unset CERALIVE_APT_PROXY; CACHE_FIXTURE=up PATH="${WORK}/bin:${PATH}" \
  lib_eval 'apt_isolated_opts "$1" "$2" "$3"' /st /st/src.list arm64)
(( ${#detected[@]} == 16 )) || fail "responding cache was not detected"
[[ "${detected[*]}" == *'Acquire::http::Proxy=http://127.0.0.1:3142'* ]] \
  || fail "detected proxy did not reach apt's HTTP acquisition"
mapfile -t absent < <(unset CERALIVE_APT_PROXY; CACHE_FIXTURE=down PATH="${WORK}/bin:${PATH}" \
  lib_eval 'apt_isolated_opts "$1" "$2" "$3"' /st /st/src.list arm64)
(( ${#absent[@]} == 12 )) || fail "unavailable cache did not fall back to direct APT"
mapfile -t disabled < <(CERALIVE_APT_PROXY=off CACHE_FIXTURE=up PATH="${WORK}/bin:${PATH}" \
  lib_eval 'apt_isolated_opts "$1" "$2" "$3"' /st /st/src.list arm64)
(( ${#disabled[@]} == 12 )) || fail "off did not override an available cache"
ok "proxy: report probe selects the local cache, failure and off stay direct"

mapfile -t container_args < <(env -u CERALIVE_APT_PROXY CACHE_FIXTURE=up PATH="${WORK}/bin:${PATH}" \
  bash -c 'source "$1/lib/common.sh"; container_build_proxy_args' _ "${PIPELINE_DIR}")
[[ "${container_args[*]}" == *'host.docker.internal:host-gateway'* \
  && "${container_args[*]}" == *'APT_PROXY=http://host.docker.internal:3142'* ]] \
  || fail "local cache cannot be reached from the builder container"
ok "proxy: Docker build args translate host-local cache to the host gateway"

nested_lib="${PIPELINE_DIR}/lib/shared/apt-proxy-lib.sh"
nested_url="$(NESTED_LIB="${nested_lib}" bash -c '
  source "${NESTED_LIB}"
  getent() { [[ "$*" == "ahostsv4 host.docker.internal" ]] && printf "172.17.0.1 STREAM host.docker.internal\n"; }
  apt_proxy_nested_chroot_url http://host.docker.internal:3142
')" || fail "outer builder did not resolve its Docker host gateway"
[[ "${nested_url}" == http://172.17.0.1:3142 ]] || fail "nested chroot was given the Docker-only hostname"
if NESTED_LIB="${nested_lib}" bash -c '
  source "${NESTED_LIB}"
  getent() { return 2; }
  apt_proxy_nested_chroot_url http://host.docker.internal:3142
' >/dev/null; then
  fail "missing Docker host mapping did not fail closed"
fi
[[ "$(NESTED_LIB="${nested_lib}" bash -c 'source "${NESTED_LIB}"; apt_proxy_nested_chroot_url http://cache.lan:3142')" == http://cache.lan:3142 ]] \
  || fail "explicit LAN cache URL was changed"
grep -Fq 'apt_proxy_nested_chroot_url "${CERALIVE_BUILD_APT_PROXY}"' "${PIPELINE_DIR}/lib/stages/mkosi.sh" \
  || fail "outer builder did not resolve the cache before starting mkosi"
ok "proxy: nested chroot gets literal host-gateway IP; absent mapping fails closed"

mapfile -t proxied < <(CERALIVE_APT_PROXY=http://acng.lan:3142 lib_eval 'apt_isolated_opts "$1" "$2" "$3"' /st /st/src.list arm64)
(( ${#proxied[@]} == 16 )) \
  || fail "CERALIVE_APT_PROXY emitted ${#proxied[@]} tokens, expected 16 (the six pairs plus http proxy and https DIRECT)"
joined_proxied="${proxied[*]}"
[[ "${joined_proxied}" == *"Acquire::http::Proxy=http://acng.lan:3142"* ]] \
  || fail "CERALIVE_APT_PROXY did not reach Acquire::http::Proxy"
ok "proxy: a set CERALIVE_APT_PROXY adds exactly the http proxy pair and the https DIRECT pair"

# https must stay DIRECT. apt.ceralive.tv is fetched with an mTLS client
# certificate, and apt's https method inherits Acquire::http::Proxy unless an
# https value is set, so DIRECT has to be stated rather than implied by absence.
for options in "${joined_proxied}" "${detected[*]}"; do
  [[ "${options}" == *"Acquire::https::Proxy=DIRECT"* ]] \
    || fail "an http proxy without https DIRECT CONNECTs the mTLS first-party fetch through the cache"
  [[ "$(grep -o 'Acquire::https::Proxy=[^ ]*' <<<"${options}")" == "Acquire::https::Proxy=DIRECT" ]] \
    || fail "https was pointed at a proxy instead of DIRECT"
done
ok "proxy: https is never proxied, so the mTLS first-party transport is untouched"

# A proxy is an acquisition-path change only. If it ever became a verification
# change the whole fetch chain would be worthless, so no proxy option may weaken
# apt's own authentication.
for options in "${joined_proxied}" "${detected[*]}" "${absent[*]}" "${disabled[*]}"; do
  [[ "$(grep -o 'Acquire::https::Proxy=[^ ]*' <<<"${options}")" =~ ^(Acquire::https::Proxy=DIRECT)?$ ]] \
    || fail "HTTPS mTLS was proxied"
  for forbidden in "Acquire::AllowInsecureRepositories" "Acquire::AllowDowngradeToInsecureRepositories" "APT::Get::AllowUnauthenticated" "Acquire::Check-Valid-Until=false" "Acquire::https::Verify-Peer=false" "gpgv"; do
    [[ "${options}" != *"${forbidden}"* ]] \
      || fail "the proxy option set contains '${forbidden}' — a cache may never relax verification"
  done
done
ok "proxy: no option in any cache-on/off set relaxes TLS or apt authentication"

grep -Fqx 'PassThroughPattern: ^apt\.ceralive\.tv:443$' "${PIPELINE_DIR}/ci/apt-cache/ceralive.conf" \
  || fail "CONNECT allowlist must name only the first-party mTLS origin"
grep -Fq 'PassEnvironment=CERALIVE_BUILD_APT_PROXY' "${PIPELINE_DIR}/mkosi/mkosi.conf" \
  || fail "build-only cache URL is not forwarded to the runtime postinst"
grep -Fq 'HTTPS///deb.debian.org/' "${PIPELINE_DIR}/mkosi/runtime/build-apt-cache.sh" \
  || fail "runtime postinst does not remap Debian HTTPS inside its build transaction"
grep -Fq 'source "${CERALIVE_RUNTIME_SRC}/build-apt-cache.sh"' "${PIPELINE_DIR}/mkosi/mkosi.images/runtime/mkosi.postinst.chroot" \
  || fail "runtime postinst does not load the build-only remap"
ok "proxy: CONNECT is exact-host scoped and Debian remap stays in the build postinst"

# Drive the REAL runtime helper: the remap must reach every later apt call in the
# layer (APT_CONFIG), leave the shipped source byte-identical, and vanish on exit.
remap_src="${WORK}/debian.sources"
printf 'Types: deb\nURIs: https://deb.debian.org/debian\nSuites: trixie\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg\n' >"${remap_src}"
cp "${remap_src}" "${WORK}/debian.sources.orig"
remap_out="$(CERALIVE_BUILD_APT_PROXY=http://host.docker.internal:3142 \
  CERALIVE_BUILD_APT_SHIPPED_SOURCES="${remap_src}" bash -c '
    log() { :; }
    source "$1/mkosi/runtime/build-apt-cache.sh"
    runtime_build_apt_scope || exit 9
    printf "dir=%s\n" "${CERALIVE_BUILD_APT_DIR}"
    cat "${APT_CONFIG}" "${CERALIVE_BUILD_APT_DIR}/sources/debian.sources"
  ' _ "${PIPELINE_DIR}")" || fail "runtime remap refused a valid build-only cache URL"
remap_dir="$(sed -n 's/^dir=//p' <<<"${remap_out}")"
[[ "${remap_out}" == *'URIs: http://host.docker.internal:3142/HTTPS///deb.debian.org/debian'* ]] \
  || fail "runtime remap did not rewrite Debian HTTPS to the cache's HTTPS/// form"
[[ "${remap_out}" == *'Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg'* ]] \
  || fail "runtime remap dropped the explicit Signed-By keyring"
[[ "${remap_out}" == *"Dir::Etc::sourcelist \"/dev/null\";"* ]] \
  || fail "runtime remap leaves the shipped source visible alongside the remapped one"
cmp -s "${remap_src}" "${WORK}/debian.sources.orig" \
  || fail "runtime remap modified the shipped debian.sources"
[[ -n "${remap_dir}" && ! -e "${remap_dir}" ]] \
  || fail "runtime remap left its build-only source behind after the layer exited"
for forbidden in "Verify-Peer" "Verify-Host" "AllowInsecure" "AllowUnauthenticated" "Check-Valid-Until" "trusted=yes"; do
  [[ "${remap_out}" != *"${forbidden}"* ]] || fail "runtime remap introduced '${forbidden}'"
done
nocache="$(CERALIVE_BUILD_APT_PROXY='' bash -c '
    log() { :; }; unset APT_CONFIG
    source "$1/mkosi/runtime/build-apt-cache.sh"
    runtime_build_apt_scope; printf "%s" "${APT_CONFIG:-unset}"
  ' _ "${PIPELINE_DIR}")"
[[ "${nocache}" == unset ]] || fail "no build cache must leave apt on the shipped sources"
CERALIVE_BUILD_APT_PROXY='http://evil/;rm' bash -c '
    log() { :; }
    source "$1/mkosi/runtime/build-apt-cache.sh"; runtime_build_apt_scope
  ' _ "${PIPELINE_DIR}" && fail "runtime remap accepted a malformed cache URL"
ok "proxy: runtime remap spans the layer via APT_CONFIG, keeps shipped sources, cleans up"

audit_workflow="${PIPELINE_DIR}/.github/workflows/real-build-audit.yml"
grep -Fq './dev-cache up' "${audit_workflow}" \
  || fail "real-build audit does not provision its runner's Debian cache"
grep -Fq 'install -m 0644 ci/apt-cache/ceralive.conf "${CERALIVE_APT_CACHE_CONFIG}"' "${audit_workflow}" \
  || fail "restrictive runner umask makes the cache's config unreadable"
grep -Fq '${CERALIVE_APT_CACHE_CONFIG:-./ceralive.conf}' "${PIPELINE_DIR}/ci/apt-cache/compose.yml" \
  || fail "runner's readable cache config is not mounted by Compose"
grep -Fq 'CERALIVE_APT_PROXY: http://127.0.0.1:3142' "${audit_workflow}" \
  || fail "real-build audit can silently fall back to the broken direct TLS path"
grep -Fq 'http://127.0.0.1:3142/acng-report.html' "${audit_workflow}" \
  || fail "real-build audit does not confirm the cache is answering before building"
ok "proxy: real-build audit mounts readable cache config and refuses a silent direct fallback"

state="${WORK}/apt-state"
lib_eval 'apt_isolated_state_init "$1" "$2"' "${state}" "${state}/certs" >/dev/null 2>&1
for d in lists/partial cache/archives/partial certs; do
  [[ -d "${state}/${d}" ]] || fail "apt_isolated_state_init did not create ${d}"
done
ok "isolated: the state tree apt refuses to run without is created, extras included"

for consumer in lib/fetch/bsp.sh lib/fetch/firstparty.sh; do
  grep -q 'apt_isolated_opts' "${PIPELINE_DIR}/${consumer}" \
    || fail "${consumer} does not use the shared apt option builder"
  grep -q 'apt_isolated_state_init' "${PIPELINE_DIR}/${consumer}" \
    || fail "${consumer} does not use the shared isolated-state initialiser"
done
if (cd "${PIPELINE_DIR}" && grep -n 'Dir::State::Lists=' lib/fetch/bsp.sh lib/fetch/firstparty.sh) >/dev/null 2>&1; then
  fail "a fetch family still writes the isolated apt options out by hand"
fi
ok "isolated: both transports build their apt state through the one library"

# The sandbox gate is generic apt plumbing and must live in the generic module.
for fn in apt_sandbox_user_exists apt_sandbox_active apt_sandbox_make_traversable apt_sandbox_own_download_dir; do
  grep -q "^${fn}() {" "${APT_LIB}" || fail "${fn} is not defined in apt-lib.sh"
  strays="$(cd "${PIPELINE_DIR}" && grep -ln "^${fn}() {" lib/fetch/*.sh lib/fetch-debs.sh | grep -v 'apt-lib.sh$' || true)"
  [[ -z "${strays}" ]] || fail "${fn} is also defined in: ${strays}"
done
ok "isolated: the apt sandbox gate is defined once, in the generic module"

# ---------------------------------------------------------------------------
# Signed index — the digest comes from the verified plaintext
#
# The fixture below models the ARMBIAN BSP archive, whose suite is ARMBIAN_SUITE
# (still bookworm, and deliberately NOT derived from RELEASE — see
# tests/target-release-derivation.test.sh §E). It is not the Debian rootfs suite,
# so it does not move with the trixie migration. The header fields are inert
# filler anyway: index_release_digest reads only the SHA256 block.
# ---------------------------------------------------------------------------
release="${WORK}/Release"
cat >"${release}" <<'EOF'
Suite: bookworm
Components: main
Architectures: arm64
MD5Sum:
 dddddddddddddddddddddddddddddddd 123 main/binary-arm64/Packages.gz
SHA256:
 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 123 main/binary-arm64/Packages.gz
 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 45 Packages.gz
Acquire-By-Hash: yes
 cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc 9 not-a-digest-entry
EOF

got="$(lib_eval 'index_release_digest "$1" "$2"' "${release}" main/binary-arm64/Packages.gz)"
[[ "${got}" == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ]] \
  || fail "index_release_digest returned '${got}' for the nested Packages.gz path"
got="$(lib_eval 'index_release_digest "$1" "$2"' "${release}" Packages.gz)"
[[ "${got}" == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ]] \
  || fail "index_release_digest returned '${got}' for the flat Packages.gz path"
ok "index: the SHA256 block is read for both the nested and flat index paths"

# An entry that sits under a DIFFERENT digest header must never be returned.
if lib_eval 'index_release_digest "$1" "$2"' "${release}" not-a-digest-entry >/dev/null 2>&1; then
  fail "index_release_digest returned a value from outside the SHA256 block"
fi
ok "index: a later header closes the SHA256 block, so no foreign digest is returned"

if lib_eval 'index_release_digest "$1" "$2"' "${release}" absent/Packages.gz >/dev/null 2>&1; then
  fail "index_release_digest succeeded for a path the Release does not list"
fi
if lib_eval 'index_release_digest "$1" "$2"' "${WORK}/no-such-release" Packages.gz >/dev/null 2>&1; then
  fail "index_release_digest succeeded against a missing Release file"
fi
ok "index: an unlisted path and a missing Release both fail explicitly"

# The whole point of the extraction: neither transport may read the digest out of
# the raw (unverified) InRelease. gpgv's plaintext output is the only input.
for consumer in lib/fetch/bsp.sh lib/fetch/firstparty.sh; do
  grep -q 'index_release_digest "${verified_release}"' "${PIPELINE_DIR}/${consumer}" \
    || fail "${consumer} does not read its index digest from the VERIFIED release"
done
if (cd "${PIPELINE_DIR}" && grep -n 'SHA256:/' lib/fetch/bsp.sh lib/fetch/firstparty.sh) >/dev/null 2>&1; then
  fail "a fetch family still carries its own Release SHA256 awk"
fi
ok "index: both transports read the digest from the verified plaintext, via one reader"

# --- a wrong index payload is rejected, not skipped -------------------------
payload="${WORK}/Packages.gz"
printf 'Package: cerastream\n' | gzip -c >"${payload}"
realsha="$(sha256sum "${payload}" | awk '{print $1}')"
lib_eval 'index_verify_digest "$1" "$2" "fixture index"' "${payload}" "${realsha}" >/dev/null 2>&1 \
  || fail "index_verify_digest rejected a payload matching its signed digest"
out="${WORK}/verify.err"
if lib_eval 'index_verify_digest "$1" "$2" "fixture index"' \
    "${payload}" 0000000000000000000000000000000000000000000000000000000000000000 2>"${out}"; then
  fail "index_verify_digest ACCEPTED a payload that does not match the signed digest"
fi
grep -q 'fixture index checksum mismatch' "${out}" \
  || fail "index_verify_digest did not name the mismatch loudly: $(cat "${out}")"
ok "index: a payload that does not match the signed digest is rejected, loudly"

decompressed="${WORK}/Packages"
lib_eval 'index_decompress_gz "$1" "$2"' "${payload}" "${decompressed}" >/dev/null
grep -q 'Package: cerastream' "${decompressed}" \
  || fail "index_decompress_gz did not produce the index"
[[ -s "${payload}" ]] || fail "index_decompress_gz consumed the verified .gz instead of keeping it"
ok "index: decompression keeps the verified .gz so it stays re-hashable"

# --- a BAD SIGNATURE must fail the release verification, never be skipped ---
if ! command -v gpgv >/dev/null 2>&1; then
  fail "gpgv is required for the signed-index rejection leg"
fi
badkeyring="${WORK}/empty-keyring.gpg"
: >"${badkeyring}"
tampered="${WORK}/InRelease.unsigned"
cp "${release}" "${tampered}"
if lib_eval 'auth_verify_release_to_file "$1" "$2" "$3"' \
    "${badkeyring}" "${tampered}" "${WORK}/Release.out" >/dev/null 2>&1; then
  fail "an UNSIGNED InRelease was accepted by the release verifier"
fi
[[ ! -s "${WORK}/Release.out" ]] \
  || fail "a rejected InRelease still produced a verified Release plaintext"
ok "index: an unsigned/badly-signed InRelease yields no verified plaintext"

# ...and a caller that then asks for a digest gets an explicit failure, so the
# rejection cannot degrade into "no digest, carry on".
if lib_eval 'index_release_digest "$1" "$2"' "${WORK}/Release.out" Packages.gz >/dev/null 2>&1; then
  fail "a digest was produced from the non-existent verified plaintext"
fi
ok "index: with no verified plaintext there is no digest, so the fetch cannot continue"

# ---------------------------------------------------------------------------
# Explicit optional lookups — the `|| true` replacement
# ---------------------------------------------------------------------------
pkgindex="${WORK}/PackagesIndex"
cat >"${pkgindex}" <<'EOF'
Package: cerastream
Architecture: arm64
Version: 2026.6.1
Filename: ./cerastream_2026.6.1_arm64.deb
SHA256: aaaa

Package: srtla
Architecture: amd64
Version: 1.0.0
Filename: ./srtla_1.0.0_amd64.deb
SHA256: bbbb
EOF

row="$(lib_eval 'index_lookup_optional "$1" cerastream 2026.6.1 arm64' "${pkgindex}")"
[[ "${row}" == *"cerastream_2026.6.1_arm64.deb"* ]] \
  || fail "index_lookup_optional did not return the hit row (got '${row}')"
ok "optional: a present package resolves to its row with exit 0"

rc=0
lib_eval 'index_lookup_optional "$1" not-a-package 1 arm64' "${pkgindex}" >/dev/null 2>&1 || rc=$?
[[ "${rc}" == "1" ]] || fail "a genuine miss returned ${rc}, expected the NOT_FOUND sentinel 1"
ok "optional: a genuine miss returns the NOT_FOUND sentinel (1)"

# WRONG ARCH is a miss, not a hit: staging an amd64 .deb into an arm64 image is
# exactly the silent corruption this lookup exists to prevent.
rc=0
lib_eval 'index_lookup_optional "$1" srtla 1.0.0 arm64' "${pkgindex}" >/dev/null 2>&1 || rc=$?
[[ "${rc}" == "1" ]] || fail "a wrong-architecture entry returned ${rc}, expected NOT_FOUND (1)"
ok "optional: an entry for another architecture is a miss, never a hit"

rc=0; out="${WORK}/unusable.err"
lib_eval 'index_lookup_optional "$1" cerastream 1 arm64' "${WORK}/no-such-index" >/dev/null 2>"${out}" || rc=$?
[[ "${rc}" == "2" ]] || fail "a missing index returned ${rc}, expected the UNUSABLE sentinel 2"
grep -q 'index is missing or empty' "${out}" || fail "an unusable index was not reported: $(cat "${out}")"
ok "optional: a MISSING index returns the UNUSABLE sentinel (2), loudly"

: >"${WORK}/empty-index"
rc=0
lib_eval 'index_lookup_optional "$1" cerastream 1 arm64' "${WORK}/empty-index" >/dev/null 2>&1 || rc=$?
[[ "${rc}" == "2" ]] || fail "an empty index returned ${rc}, expected UNUSABLE (2)"
rc=0
lib_eval 'index_lookup_optional "" cerastream 1 arm64' >/dev/null 2>&1 || rc=$?
[[ "${rc}" == "2" ]] || fail "an empty index PATH returned ${rc}, expected UNUSABLE (2)"
ok "optional: an empty index and an empty index path are both UNUSABLE, not misses"

# --- no fetch module may swallow a failure with `|| true` -------------------
swallowed="$(cd "${PIPELINE_DIR}" && grep -n '|| true' lib/fetch/*.sh lib/fetch-debs.sh \
  | grep -v '^lib/fetch/index.sh:[0-9]*:#' \
  | grep -v '^lib/fetch/retry.sh:[0-9]*:#' \
  | grep -v '^lib/fetch-debs.sh:[0-9]*:#' || true)"
[[ -z "${swallowed}" ]] \
  || fail "a fetch module still swallows a failure with '|| true':"$'\n'"${swallowed}"
ok "optional: no fetch module swallows a real failure with '|| true'"

# ...and both cache probes act on the UNUSABLE sentinel rather than continuing.
for consumer in lib/fetch/bsp.sh lib/fetch/firstparty.sh; do
  grep -q 'index_lookup_optional' "${PIPELINE_DIR}/${consumer}" \
    || fail "${consumer} does not use the explicit optional lookup"
  grep -q 'INDEX_LOOKUP_UNUSABLE' "${PIPELINE_DIR}/${consumer}" \
    || fail "${consumer} ignores the UNUSABLE sentinel — an unreadable index would pass as a miss"
done
ok "optional: both cache probes fail closed on an unusable index"

printf '\napt-lib: %d checks passed\n' "${PASS}"
