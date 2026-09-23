#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"
PKI="${PIPELINE_DIR}/lib/rauc-pki-contract.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

[[ -x "${PKI}" ]]
mkdir -p "${TMP}/match" "${TMP}/mismatch"
for name in root-ca.pem chain.pem leaf-signing.pem leaf-signing.key; do
  case "${name}" in
    root-ca.pem) cp "${PIPELINE_DIR}/.dev-keys/dev-root-ca.pem" "${TMP}/match/${name}" ;;
    chain.pem) cp "${PIPELINE_DIR}/.dev-keys/dev-chain.pem" "${TMP}/match/${name}" ;;
    leaf-signing.pem) cp "${PIPELINE_DIR}/.dev-keys/dev-leaf-signing.pem" "${TMP}/match/${name}" ;;
    leaf-signing.key) cp "${PIPELINE_DIR}/.dev-keys/dev-leaf-signing.key" "${TMP}/match/${name}" ;;
  esac
done
cp -a "${TMP}/match/." "${TMP}/mismatch/"
cp "${PIPELINE_DIR}/mkosi/runtime/rauc/ceralive-keyring.pem" "${TMP}/mismatch/root-ca.pem"

# Reissue only a test leaf under the test intermediate with the same matching
# leaf key, but with codeSigning alone. The old resolver accepted this signer;
# the device's S/MIME-purpose CMS verification rejects it.
mkdir -p "${TMP}/codesign-only"
cp -a "${TMP}/match/." "${TMP}/codesign-only/"
openssl req -new -key "${TMP}/codesign-only/leaf-signing.key" \
  -subj '/CN=CI codeSigning-only negative fixture (NON-PRODUCTION)' \
  -out "${TMP}/leaf.csr"
printf '%s\n' 'basicConstraints=critical,CA:FALSE' \
  'keyUsage=critical,digitalSignature' 'extendedKeyUsage=codeSigning' \
  >"${TMP}/leaf.ext"
openssl x509 -req -in "${TMP}/leaf.csr" -days 1 -sha256 \
  -CA "${PIPELINE_DIR}/.dev-keys/dev-intermediate-ca.pem" \
  -CAkey "${PIPELINE_DIR}/.dev-keys/dev-intermediate-ca.key" \
  -set_serial 901 -extfile "${TMP}/leaf.ext" \
  -out "${TMP}/codesign-only/leaf-signing.pem" >/dev/null 2>&1

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
openssl verify -purpose codesign -CAfile "${TMP}/codesign-only/root-ca.pem" \
  -untrusted "${TMP}/codesign-only/chain.pem" "${TMP}/codesign-only/leaf-signing.pem" >/dev/null
if "${PKI}" resolve --mode production --pki-dir "${TMP}/codesign-only" \
  --keyring "${TMP}/codesign-only/root-ca.pem" >"${TMP}/rejected" 2>"${TMP}/error"; then
  printf 'codeSigning-only leaf passed the device S/MIME purpose gate\n' >&2
  exit 1
fi
grep -q 'S/MIME signing purpose' "${TMP}/error"

printf 'RAUC production trust-root contract: PASS\n'
