#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2="$(cd "${HERE}/.." && pwd)"
PKI="${V2}/lib/rauc-pki-contract.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

[[ -x "${PKI}" ]]
mkdir -p "${TMP}/match" "${TMP}/mismatch"
for name in root-ca.pem chain.pem leaf-signing.pem leaf-signing.key; do
  case "${name}" in
    root-ca.pem) cp "${V2}/.dev-keys/dev-root-ca.pem" "${TMP}/match/${name}" ;;
    chain.pem) cp "${V2}/.dev-keys/dev-chain.pem" "${TMP}/match/${name}" ;;
    leaf-signing.pem) cp "${V2}/.dev-keys/dev-leaf-signing.pem" "${TMP}/match/${name}" ;;
    leaf-signing.key) cp "${V2}/.dev-keys/dev-leaf-signing.key" "${TMP}/match/${name}" ;;
  esac
done
cp -a "${TMP}/match/." "${TMP}/mismatch/"
cp "${V2}/mkosi/runtime/rauc/ceralive-keyring.pem" "${TMP}/mismatch/root-ca.pem"

if "${PKI}" resolve --mode production; then
  printf 'production PKI resolved without explicit inputs\n' >&2
  exit 1
fi
if "${PKI}" resolve --mode production --pki-dir "${TMP}/match" --keyring "${TMP}/mismatch/root-ca.pem"; then
  printf 'mismatched signer/device roots were accepted\n' >&2
  exit 1
fi
"${PKI}" resolve --mode production --pki-dir "${TMP}/match" --keyring "${TMP}/match/root-ca.pem" >"${TMP}/resolved"
grep -qx "RAUC_KEYRING_FILE=${TMP}/match/root-ca.pem" "${TMP}/resolved"

printf 'RAUC production trust-root contract: PASS\n'
