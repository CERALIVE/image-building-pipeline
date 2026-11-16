#!/usr/bin/env bash
set -euo pipefail

rauc_cert_sha256() {
  openssl x509 -in "$1" -outform DER | sha256sum | cut -d' ' -f1
}

rauc_public_root_resolve() {
  local keyring="$1" approved="$2"
  [[ "${approved}" =~ ^[0-9a-f]{64}$ && -s "${keyring}" ]] || {
    printf 'measurement requires an explicit approved public device root and DER SHA-256\n' >&2
    return 1
  }
  awk '
    /^-----BEGIN CERTIFICATE-----$/ { if (inside || started++) exit 1; inside=1; next }
    /^-----END CERTIFICATE-----$/ { if (!inside) exit 1; inside=0; ended++; next }
    /^[[:space:]]*$/ { next }
    { if (!inside || $0 !~ /^[A-Za-z0-9+\/=]+$/) exit 1 }
    END { if (inside || started != 1 || ended != 1) exit 1 }
  ' "${keyring}" || {
    printf 'measurement device root must contain exactly one public certificate\n' >&2
    return 1
  }
  [[ "$(rauc_cert_sha256 "${keyring}")" == "${approved}" ]] || {
    printf 'measurement public device root identity mismatch\n' >&2
    return 1
  }
  openssl verify -check_ss_sig -CAfile "${keyring}" "${keyring}" >/dev/null || return 1
  RAUC_KEYRING_FILE="${keyring}"
  RAUC_ROOT_SHA256="${approved}"
  export RAUC_KEYRING_FILE RAUC_ROOT_SHA256
}

rauc_pki_resolve() {
  local mode="$1" requested_pki="${2:-}" requested_keyring="${3:-}"
  local here v2 pki keyring cert_pub key_pub eku
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  v2="$(cd "${here}/.." && pwd)"
  case "${mode}" in
    development)
      pki="${requested_pki:-${v2}/.dev-keys}"
      keyring="${requested_keyring:-${pki}/root-ca.pem}"
      ;;
    production)
      [[ -n "${requested_pki}" && -n "${requested_keyring}" ]] || {
        printf 'production RAUC PKI requires explicit CERALIVE_RAUC_PKI_DIR and RAUC_KEYRING_FILE\n' >&2
        return 1
      }
      pki="${requested_pki}"
      keyring="${requested_keyring}"
      ;;
    *) printf 'CERALIVE_BUILD_MODE must be development or production\n' >&2; return 2 ;;
  esac
  for file in root-ca.pem chain.pem leaf-signing.pem leaf-signing.key; do
    [[ -s "${pki}/${file}" ]] || { printf 'missing RAUC PKI file: %s/%s\n' "${pki}" "${file}" >&2; return 1; }
  done
  [[ -s "${keyring}" ]] || { printf 'missing RAUC device keyring: %s\n' "${keyring}" >&2; return 1; }
  [[ "$(rauc_cert_sha256 "${pki}/root-ca.pem")" == "$(rauc_cert_sha256 "${keyring}")" ]] || {
    printf 'RAUC signer root and device keyring do not match\n' >&2
    return 1
  }
  cert_pub="$(openssl x509 -in "${pki}/leaf-signing.pem" -pubkey -noout)"
  key_pub="$(openssl pkey -in "${pki}/leaf-signing.key" -pubout 2>/dev/null)"
  [[ "${cert_pub}" == "${key_pub}" ]] || { printf 'RAUC leaf certificate/private key mismatch\n' >&2; return 1; }
  # RAUC's unconfigured CMS verifier requires S/MIME signing; the leaf also
  # needs Code Signing EKU for newer RAUC versions.
  openssl verify -purpose smimesign -CAfile "${keyring}" \
    -untrusted "${pki}/chain.pem" "${pki}/leaf-signing.pem" >/dev/null || {
    printf 'RAUC leaf is not valid for the device S/MIME signing purpose\n' >&2
    return 1
  }
  eku="$(openssl x509 -in "${pki}/leaf-signing.pem" -noout -ext extendedKeyUsage)"
  [[ "$eku" == *'Code Signing'* ]] || {
    printf 'RAUC leaf is not valid for code signing\n' >&2
    return 1
  }
  CERALIVE_RAUC_PKI_DIR="${pki}"
  RAUC_KEYRING_FILE="${keyring}"
  RAUC_ROOT_SHA256="$(rauc_cert_sha256 "${keyring}")"
  export CERALIVE_RAUC_PKI_DIR RAUC_KEYRING_FILE RAUC_ROOT_SHA256
}

main() {
  [[ "${1:-}" == resolve ]] || { printf 'usage: %s resolve --mode MODE [--pki-dir DIR --keyring FILE]\n' "$0" >&2; exit 2; }
  shift
  local mode="" pki="" keyring=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode) mode="${2:-}"; shift 2 ;;
      --pki-dir) pki="${2:-}"; shift 2 ;;
      --keyring) keyring="${2:-}"; shift 2 ;;
      *) exit 2 ;;
    esac
  done
  rauc_pki_resolve "${mode}" "${pki}" "${keyring}"
  printf 'CERALIVE_RAUC_PKI_DIR=%s\nRAUC_KEYRING_FILE=%s\nRAUC_ROOT_SHA256=%s\n' \
    "${CERALIVE_RAUC_PKI_DIR}" "${RAUC_KEYRING_FILE}" "${RAUC_ROOT_SHA256}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
