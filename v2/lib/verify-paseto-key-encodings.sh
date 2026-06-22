#!/usr/bin/env bash
#
# verify-paseto-key-encodings.sh — prove the PASETO device-token PUBLIC key is
# byte-identical across the two encodings the platform and the device consume,
# then prove the image build bakes it into the runtime drop-in unchanged
# (ADR-0006 D2; runbook docs/paseto-key-provisioning.md).
#
# THE THREE ENCODINGS OF ONE Ed25519 PUBLIC KEY
#   k4.public.<b64url>     PASERK public  — platform PASETO_PUBLIC_KEY (paseto-ts)
#   <std-base64 32-byte>   raw base64     — device PASETO_PUBLIC_KEY (node:crypto
#                                            importEd25519PublicKey); == the decoded
#                                            payload of the build input below
#   PASETO_PUBLIC_KEY_B64  build input    — base64(<std-base64 32-byte>); the env
#                                            orchestrate.sh forwards into mkosi, which
#                                            setup_paseto_public_key base64-decodes once
#                                            back to the device PASETO_PUBLIC_KEY
# The k4.secret (PASERK private, platform signer) is NEVER read or printed here —
# this verifier is PUBLIC-ONLY by construction.
#
# WHAT IT ASSERTS
#   1. k4.public and the raw-base64 file decode to the SAME 32 raw bytes.
#   2. The shipped setup_paseto_public_key (postinst-lib.sh) bakes that raw-base64
#      verbatim into Environment=PASETO_PUBLIC_KEY in the ceralive.service drop-in.
#   3. The baked value re-decodes to the SAME 32 raw bytes (build input → device key
#      round-trips with zero drift).
#   4. A k4.secret fed as the build input is REFUSED (public-only contract).
#
# It prints only sha256 fingerprints + MATCH/MISMATCH — never key bytes (the public
# key is public, but we keep the evidence surface fingerprint-only on purpose).
#
# Usage:
#   verify-paseto-key-encodings.sh --self-test
#       Generate an EPHEMERAL Ed25519 keypair (openssl, scratch dir, wiped on exit)
#       and run the full check. Self-contained — needs no cert-work, no secrets; the
#       CI-friendly form (v2/run-tests section 19).
#
#   verify-paseto-key-encodings.sh --key-dir <dir>
#       Verify a real cert-work/paseto/gen-keys.sh output dir. Reads ONLY the two
#       PUBLIC files (paseto.k4.public, paseto.public.raw.b64); never the k4.secret.
#
# Exit 0 = every assertion held; non-zero = a drift was found (fail loud).
#
# shellcheck shell=bash
set -euo pipefail

PROG="$(basename "$0")"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The shipped device-side baker (single source of truth — we test the REAL function,
# never a re-implementation). v2/lib -> v2/mkosi/customize/postinst-lib.sh.
POSTINST_LIB="${POSTINST_LIB:-${HERE}/../mkosi/customize/postinst-lib.sh}"

PUBLIC_PASERK_FILE_NAME="paseto.k4.public"
PUBLIC_RAW_FILE_NAME="paseto.public.raw.b64"

die()  { printf '%s: error: %s\n' "${PROG}" "$*" >&2; exit 1; }
pass() { printf '  [PASS] %s\n' "$*"; }
info() { printf '  %s\n' "$*"; }

usage() {
	cat <<EOF
${PROG} — verify the PASETO device-token PUBLIC key encodings agree and bake clean.

  ${PROG} --self-test          ephemeral keypair, full check (CI-safe, no secrets)
  ${PROG} --key-dir <dir>      verify a gen-keys.sh output dir (PUBLIC files only)
  ${PROG} -h | --help
EOF
}

command -v openssl >/dev/null 2>&1 || die "openssl not found on PATH (required)"
[[ -f "${POSTINST_LIB}" ]] || die "postinst-lib.sh not found: ${POSTINST_LIB}"

# --- helpers ----------------------------------------------------------------
# base64url (no pad) -> raw bytes on stdout. PASERK uses unpadded base64url; map it
# back to standard base64 (-_ -> +/), re-pad to a multiple of 4, then decode.
b64url_to_bin() {
	local s; s="$(tr -d '\r\n')"
	s="$(printf '%s' "${s}" | tr '_-' '/+')"
	case $(( ${#s} % 4 )) in
		2) s+='==' ;;
		3) s+='=' ;;
	esac
	printf '%s' "${s}" | openssl base64 -d -A
}

# standard base64 -> raw bytes on stdout.
b64_to_bin() { tr -d '\r\n' | openssl base64 -d -A; }

sha256_hex() { openssl dgst -sha256 -r | awk '{print $1}'; }

# verify_pair <k4_public_string> <raw_b64_string> — the core assertion set, shared
# by --self-test and --key-dir so the two paths can never diverge.
verify_pair() {
	local k4_public="$1" raw_b64="$2"
	local work; work="$(mktemp -d "${TMPDIR:-/tmp}/paseto-verify.XXXXXX")" || die "mktemp failed"
	# shellcheck disable=SC2064
	trap "rm -rf '${work}'" RETURN

	# --- 1. both encodings decode to the SAME 32 raw bytes ------------------
	[[ "${k4_public}" == k4.public.* ]] || die "k4.public string lacks the 'k4.public.' prefix"
	printf '%s' "${k4_public#k4.public.}" | b64url_to_bin > "${work}/from_paserk.bin" \
		|| die "k4.public payload is not valid base64url"
	printf '%s' "${raw_b64}" | b64_to_bin > "${work}/from_raw.bin" \
		|| die "raw-base64 public key is not valid base64"

	local n_paserk n_raw
	n_paserk=$(wc -c < "${work}/from_paserk.bin")
	n_raw=$(wc -c < "${work}/from_raw.bin")
	[[ "${n_paserk}" -eq 32 ]] || die "k4.public decoded to ${n_paserk} bytes, expected 32 (Ed25519 public key)"
	[[ "${n_raw}"    -eq 32 ]] || die "raw-base64 decoded to ${n_raw} bytes, expected 32 (Ed25519 public key)"

	local fp_paserk fp_raw
	fp_paserk="$(sha256_hex < "${work}/from_paserk.bin")"
	fp_raw="$(sha256_hex < "${work}/from_raw.bin")"
	info "k4.public  -> 32 bytes, sha256=${fp_paserk}"
	info "raw-base64 -> 32 bytes, sha256=${fp_raw}"
	cmp -s "${work}/from_paserk.bin" "${work}/from_raw.bin" \
		|| die "MISMATCH — k4.public and raw-base64 are DIFFERENT public keys (${fp_paserk} != ${fp_raw})"
	pass "k4.public and raw-base64 decode to byte-equal 32-byte public keys"

	# --- 2. the shipped baker writes the raw-base64 verbatim ----------------
	# PASETO_PUBLIC_KEY_B64 is what orchestrate.sh forwards: base64(raw-base64).
	local build_input dropin_dir baked
	build_input="$(printf '%s' "${raw_b64}" | base64 -w0)"
	dropin_dir="${work}/ceralive.service.d"
	# Run the REAL function in a subshell so its die() can't exit us; PASETO_DROPIN_DIR
	# redirects the drop-in to scratch (no system files touched).
	env PASETO_PUBLIC_KEY_B64="${build_input}" PASETO_DROPIN_DIR="${dropin_dir}" \
		bash -c "source '${POSTINST_LIB}'; setup_paseto_public_key" \
		|| die "setup_paseto_public_key FAILED on a legitimate PUBLIC key"
	local dropin="${dropin_dir}/20-paseto-public-key.conf"
	[[ -f "${dropin}" ]] || die "no drop-in written at ${dropin}"
	grep -q '^\[Service\]' "${dropin}" || die "drop-in missing [Service] section"
	grep -q "^Environment=PASETO_PUBLIC_KEY=${raw_b64}\$" "${dropin}" \
		|| die "drop-in PASETO_PUBLIC_KEY does not match the raw-base64 key"
	# PUBLIC-ONLY: no private material may appear in the baked artifact.
	! grep -aq 'k4.secret'   "${dropin}" || die "drop-in leaked a k4.secret"
	! grep -aq 'PRIVATE KEY' "${dropin}" || die "drop-in leaked PEM PRIVATE KEY material"
	pass "setup_paseto_public_key baked Environment=PASETO_PUBLIC_KEY (additive ceralive.service drop-in)"

	# --- 3. baked value re-decodes to the SAME 32 bytes (no drift) ----------
	baked="$(sed -n 's/^Environment=PASETO_PUBLIC_KEY=//p' "${dropin}")"
	printf '%s' "${baked}" | b64_to_bin > "${work}/from_dropin.bin" \
		|| die "baked PASETO_PUBLIC_KEY is not valid base64"
	cmp -s "${work}/from_dropin.bin" "${work}/from_raw.bin" \
		|| die "baked device key drifted from the source public key"
	pass "build input -> drop-in -> device key round-trips to the same 32-byte public key"

	# --- 4. a k4.secret as the build input is REFUSED -----------------------
	# Synthetic literal (NOT a real secret) — proves the public-only gate fires.
	local bad; bad="$(printf '%s' 'k4.secret.Zm9yYmlkZGVu' | base64 -w0)"
	if env PASETO_PUBLIC_KEY_B64="${bad}" PASETO_DROPIN_DIR="${work}/reject.d" \
		bash -c "source '${POSTINST_LIB}'; setup_paseto_public_key" >/dev/null 2>&1; then
		die "setup_paseto_public_key ACCEPTED a k4.secret — public-only gate is broken"
	fi
	[[ ! -f "${work}/reject.d/20-paseto-public-key.conf" ]] \
		|| die "a drop-in was written for a refused k4.secret"
	pass "a k4.secret fed as the build input is REFUSED (no drop-in produced)"
}

# --- modes ------------------------------------------------------------------
self_test() {
	echo "== PASETO key-encoding verify: --self-test (ephemeral keypair) =="
	local scratch; scratch="$(mktemp -d "${TMPDIR:-/tmp}/paseto-selftest.XXXXXX")" || die "mktemp failed"
	# shellcheck disable=SC2064
	trap "rm -rf '${scratch}'" EXIT
	# Mint an ephemeral Ed25519 keypair and derive the two PUBLIC encodings exactly
	# as gen-keys.sh does (32-byte SPKI tail; base64url-nopad vs standard base64).
	openssl genpkey -algorithm ed25519 -out "${scratch}/priv.pem" 2>/dev/null \
		|| die "openssl could not generate an Ed25519 key"
	openssl pkey -in "${scratch}/priv.pem" -pubout -outform DER 2>/dev/null \
		| tail -c 32 > "${scratch}/pub.bin"
	[[ "$(wc -c < "${scratch}/pub.bin")" -eq 32 ]] || die "unexpected Ed25519 public-key length"
	local raw_b64 k4_public
	raw_b64="$(openssl base64 -A < "${scratch}/pub.bin")"
	k4_public="k4.public.$(openssl base64 -A < "${scratch}/pub.bin" | tr '+/' '-_' | tr -d '=')"
	verify_pair "${k4_public}" "${raw_b64}"
	echo "== self-test OK =="
}

key_dir_test() {
	local dir="$1"
	echo "== PASETO key-encoding verify: --key-dir ${dir} =="
	local pf="${dir}/${PUBLIC_PASERK_FILE_NAME}" rf="${dir}/${PUBLIC_RAW_FILE_NAME}"
	[[ -f "${pf}" ]] || die "missing ${PUBLIC_PASERK_FILE_NAME} in ${dir}"
	[[ -f "${rf}" ]] || die "missing ${PUBLIC_RAW_FILE_NAME} in ${dir}"
	# Guard: never accidentally ingest the private file from this dir.
	local k4_public raw_b64
	k4_public="$(tr -d '\r\n' < "${pf}")"
	raw_b64="$(tr -d '\r\n' < "${rf}")"
	verify_pair "${k4_public}" "${raw_b64}"
	echo "== ${dir} OK =="
}

main() {
	[[ $# -ge 1 ]] || { usage >&2; die "an argument is required"; }
	case "$1" in
		--self-test) self_test ;;
		--key-dir)   [[ -n "${2:-}" ]] || die "--key-dir requires a directory"; key_dir_test "$2" ;;
		--key-dir=*) key_dir_test "${1#*=}" ;;
		-h|--help)   usage ;;
		*)           usage >&2; die "unknown argument: $1" ;;
	esac
}

main "$@"
