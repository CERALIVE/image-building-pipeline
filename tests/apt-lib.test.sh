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
mapfile -t opts < <(lib_eval 'apt_isolated_opts "$1" "$2" "$3"' /st /st/src.list arm64)
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

Package: srtla-send-rs
Architecture: amd64
Version: 1.0.0
Filename: ./srtla-send-rs_1.0.0_amd64.deb
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
lib_eval 'index_lookup_optional "$1" srtla-send-rs 1.0.0 arm64' "${pkgindex}" >/dev/null 2>&1 || rc=$?
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
