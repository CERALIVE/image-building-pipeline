#!/usr/bin/env bash
set -euo pipefail

# Materialize the ignored, non-production RAUC PKI used by offline tests.
# Production builds must continue to provide CERALIVE_RAUC_PKI_DIR explicitly.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2="$(cd "${HERE}/.." && pwd)"
DEV_KEYS="${V2}/.dev-keys"

die() {
  printf 'dev RAUC PKI: %s\n' "$1" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

for tool in openssl mktemp; do
  require_cmd "$tool"
done

umask 077
mkdir -p "$DEV_KEYS"
chmod 700 "$DEV_KEYS"

material=(
  dev-root-ca.key
  dev-root-ca.pem
  dev-intermediate-ca.key
  dev-intermediate-ca.pem
  dev-leaf-signing.key
  dev-leaf-signing.pem
  dev-chain.pem
)

present=0
missing=0
for file in "${material[@]}"; do
  if [[ -e "$DEV_KEYS/$file" ]]; then
    present=1
  else
    missing=1
  fi
done

if (( present && missing )); then
  die "incomplete fixture in ${DEV_KEYS}; remove only this ignored directory and retry"
fi

link_fixture() {
  local name="$1" target="$2" path
  path="${DEV_KEYS}/${name}"
  if [[ -e "$path" || -L "$path" ]]; then
    [[ -L "$path" && "$(readlink "$path")" == "$target" ]] \
      || die "fixture link is not the expected dev link: ${path}"
    return 0
  fi
  ln -s "$target" "$path"
}

matches_key() {
  local cert="$1" key="$2" cert_pub key_pub
  cert_pub="$(openssl x509 -in "$cert" -pubkey -noout)"
  key_pub="$(openssl pkey -in "$key" -pubout)"
  [[ "$cert_pub" == "$key_pub" ]] || die "certificate/private-key mismatch: $(basename "$cert")"
}

validate_fixture() {
  local cert subject chain_certs
  for cert in dev-root-ca.pem dev-intermediate-ca.pem dev-leaf-signing.pem dev-chain.pem; do
    [[ -s "$DEV_KEYS/$cert" ]] || die "fixture file is missing or empty: ${DEV_KEYS}/${cert}"
  done
  chain_certs="$(awk '/^-----BEGIN CERTIFICATE-----$/{n++} END{print n+0}' "$DEV_KEYS/dev-chain.pem")"
  [[ "$chain_certs" -eq 1 ]] || die "dev-chain.pem must contain only the intermediate certificate"
  for cert in dev-root-ca.pem dev-intermediate-ca.pem dev-leaf-signing.pem; do
    subject="$(openssl x509 -in "$DEV_KEYS/$cert" -noout -subject)"
    [[ "$subject" == *"NON-PRODUCTION"* ]] \
      || die "refusing a non-test certificate in ${DEV_KEYS}/${cert}"
  done
  matches_key "$DEV_KEYS/dev-root-ca.pem" "$DEV_KEYS/dev-root-ca.key"
  matches_key "$DEV_KEYS/dev-intermediate-ca.pem" "$DEV_KEYS/dev-intermediate-ca.key"
  matches_key "$DEV_KEYS/dev-leaf-signing.pem" "$DEV_KEYS/dev-leaf-signing.key"
  openssl verify -CAfile "$DEV_KEYS/dev-root-ca.pem" \
    -untrusted "$DEV_KEYS/dev-intermediate-ca.pem" \
    "$DEV_KEYS/dev-leaf-signing.pem" >/dev/null
  local leaf_eku
  leaf_eku="$(openssl x509 -in "$DEV_KEYS/dev-leaf-signing.pem" -noout -ext extendedKeyUsage)"
  [[ "$leaf_eku" == *"E-mail Protection"* ]] \
    || die "leaf EKU missing emailProtection — rauc 1.8's smime_sign default would reject the bundle (regenerate: rm -rf ${DEV_KEYS})"
  [[ "$leaf_eku" == *"Code Signing"* ]] \
    || die "leaf EKU missing codeSigning — needed for a future rauc >=1.9 check-purpose=codesign (regenerate: rm -rf ${DEV_KEYS})"
}

if (( ! present )); then
  tmp="$(mktemp -d "${DEV_KEYS}/.generate.XXXXXX")"
  cleanup() { rm -rf "$tmp"; }
  trap cleanup EXIT

  openssl genrsa -out "$tmp/dev-root-ca.key" 2048 >/dev/null 2>&1
  openssl req -new -x509 -sha256 -days 3650 -set_serial 1 \
    -key "$tmp/dev-root-ca.key" -out "$tmp/dev-root-ca.pem" \
    -subj '/CN=CeraLive CI Test Root CA (NON-PRODUCTION)' \
    -addext 'basicConstraints=critical,CA:TRUE,pathlen:1' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign' \
    -addext 'subjectKeyIdentifier=hash' >/dev/null 2>&1

  openssl genrsa -out "$tmp/dev-intermediate-ca.key" 2048 >/dev/null 2>&1
  openssl req -new -sha256 -key "$tmp/dev-intermediate-ca.key" \
    -out "$tmp/dev-intermediate-ca.csr" \
    -subj '/CN=CeraLive CI Test Intermediate CA (NON-PRODUCTION)' >/dev/null 2>&1
  printf '%s\n' \
    'basicConstraints=critical,CA:TRUE,pathlen:0' \
    'keyUsage=critical,keyCertSign,cRLSign' \
    'subjectKeyIdentifier=hash' \
    'authorityKeyIdentifier=keyid,issuer' >"$tmp/intermediate.ext"
  openssl x509 -req -sha256 -days 1825 -set_serial 2 \
    -in "$tmp/dev-intermediate-ca.csr" \
    -CA "$tmp/dev-root-ca.pem" -CAkey "$tmp/dev-root-ca.key" \
    -out "$tmp/dev-intermediate-ca.pem" -extfile "$tmp/intermediate.ext" \
    >/dev/null 2>&1

  openssl genrsa -out "$tmp/dev-leaf-signing.key" 2048 >/dev/null 2>&1
  openssl req -new -sha256 -key "$tmp/dev-leaf-signing.key" \
    -out "$tmp/dev-leaf-signing.csr" \
    -subj '/CN=CeraLive CI Test Leaf Signing (NON-PRODUCTION)' >/dev/null 2>&1
  # DUAL EKU (emailProtection + codeSigning) — do NOT reduce to codeSigning-only.
  # The device runs Debian bookworm's rauc 1.8, which predates the
  # check-purpose=codesign / X.509-key-usage feature (added in rauc 1.9). On 1.8
  # rauc's CMS_verify() falls back to OpenSSL's default smime_sign purpose, which
  # rejects a codeSigning-ONLY leaf with "unsuitable certificate purpose" (proven
  # on real Rock 5B+ hardware). emailProtection satisfies that unconfigured 1.8
  # default so `rauc install` accepts the bundle; codeSigning stays for
  # forward-compat with a future rauc >=1.9 using check-purpose=codesign.
  printf '%s\n' \
    'basicConstraints=critical,CA:FALSE' \
    'keyUsage=critical,digitalSignature' \
    'extendedKeyUsage=emailProtection,codeSigning' \
    'subjectKeyIdentifier=hash' \
    'authorityKeyIdentifier=keyid,issuer' >"$tmp/leaf.ext"
  openssl x509 -req -sha256 -days 730 -set_serial 3 \
    -in "$tmp/dev-leaf-signing.csr" \
    -CA "$tmp/dev-intermediate-ca.pem" -CAkey "$tmp/dev-intermediate-ca.key" \
    -out "$tmp/dev-leaf-signing.pem" -extfile "$tmp/leaf.ext" \
    >/dev/null 2>&1

  cp "$tmp/dev-intermediate-ca.pem" "$tmp/dev-chain.pem"
  rm -f "$tmp"/*.csr "$tmp"/*.ext
  ln -s dev-root-ca.pem "$tmp/root-ca.pem"
  ln -s dev-chain.pem "$tmp/chain.pem"
  ln -s dev-leaf-signing.pem "$tmp/leaf-signing.pem"
  ln -s dev-leaf-signing.key "$tmp/leaf-signing.key"
  chmod 600 "$tmp"/*.key
  chmod 644 "$tmp"/*.pem
  mv "$tmp"/* "$DEV_KEYS/"
  rmdir "$tmp"
  trap - EXIT
fi

cp "$DEV_KEYS/dev-intermediate-ca.pem" "$DEV_KEYS/dev-chain.pem"
link_fixture root-ca.pem dev-root-ca.pem
link_fixture chain.pem dev-chain.pem
link_fixture leaf-signing.pem dev-leaf-signing.pem
link_fixture leaf-signing.key dev-leaf-signing.key
validate_fixture
printf 'dev RAUC PKI ready: %s (NON-PRODUCTION, ignored)\n' "$DEV_KEYS"
