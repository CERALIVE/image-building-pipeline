#!/usr/bin/env bash
set -euo pipefail

rauc_cert_sha256() {
  openssl x509 -in "$1" -outform DER | sha256sum | cut -d' ' -f1
}

rauc_pki_resolve() {
  local mode="$1" requested_pki="${2:-}" requested_keyring="${3:-}"
  local here v2 pki keyring cert_pub key_pub
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
  # RAUC's unconfigured CMS verifier requires S/MIME signing; the host's
  # codesign check alone would accept a leaf that the device rejects.
  openssl verify -purpose smimesign -CAfile "${keyring}" \
    -untrusted "${pki}/chain.pem" "${pki}/leaf-signing.pem" >/dev/null || {
    printf 'RAUC leaf is not valid for the device S/MIME signing purpose\n' >&2
    return 1
  }
  openssl verify -purpose codesign -CAfile "${keyring}" \
    -untrusted "${pki}/chain.pem" "${pki}/leaf-signing.pem" >/dev/null || {
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
