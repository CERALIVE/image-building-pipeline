#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2="$(cd "${HERE}/.." && pwd)"
ROOT="$(cd "${V2}/.." && pwd)"
AUTH="${V2}/lib/fetch-debs-auth.sh"
FETCH="${V2}/lib/fetch-debs.sh"
RELEASE_DOC="${ROOT}/docs/RELEASE-PROCESS.md"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

[[ -f "${AUTH}" && -f "${RELEASE_DOC}" ]]
# shellcheck source=../lib/fetch-debs-auth.sh
source "${AUTH}"
cat >"${TMP}/Packages" <<'EOF'
Package: demo
Version: 1.2.3
Architecture: arm64
Filename: pool/demo_1.2.3_arm64.deb
SHA256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

Package: demo
Version: 1.2.30
Architecture: arm64
Filename: pool/demo_1.2.30_arm64.deb
SHA256: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
EOF

resolved="$(bash "${AUTH}" lookup --index "${TMP}/Packages" --package demo --version 1.2.3 --arch arm64)"
IFS=$'\t' read -r filename digest version <<<"${resolved}"
[[ "${filename}" == pool/demo_1.2.3_arm64.deb ]]
[[ "${digest}" == "$(printf '%064d' 0 | tr 0 a)" ]]
[[ "${version}" == 1.2.3 ]]
if bash "${AUTH}" lookup --index "${TMP}/Packages" --package demo --version 1.2 --arch arm64; then
  printf 'prefix package version was accepted\n' >&2
  exit 1
fi
cat "${TMP}/Packages" >>"${TMP}/duplicate"
cat "${TMP}/Packages" >>"${TMP}/duplicate"
if bash "${AUTH}" lookup --index "${TMP}/duplicate" --package demo --version 1.2.3 --arch arm64; then
  printf 'duplicate exact package was accepted\n' >&2
  exit 1
fi
printf 'payload\n' >"${TMP}/demo.deb"
if bash "${AUTH}" verify-file --file "${TMP}/demo.deb" --sha256 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; then
  printf 'wrong package hash was accepted\n' >&2
  exit 1
fi
if grep -qiE 'trusted[=:][[:space:]]*(yes|true)' "${FETCH}" \
    "${V2}/mkosi/mkosi.images/platform/mkosi.postinst.chroot"; then
  printf 'trusted=yes bypass was found in the BSP fetch path\n' >&2
  exit 1
fi
grep -q 'signed-by=' "${FETCH}"
grep -q 'ARMBIAN_APT_KEYRING' "${FETCH}"
grep -q 'auth_keyring_has_exact_fingerprints' "${FETCH}"
mapfile -t armbian_fingerprints < <(
  bash -c 'source "$1"; printf "%s\n" "${ARMBIAN_APT_KEY_FINGERPRINTS[@]}"' bash "${FETCH}"
)
[[ "${armbian_fingerprints[*]}" == \
  'DF00FAF1C577104B50BF1D0093D6889F9F0E78D5 8CFA83D13EB2181EEF5843E41EB30FAF236099FE' ]]
awk '
  /^### Armbian archive keyring rotation$/ { section=1; next }
  section && /^```bash$/ { block=1; next }
  block && /^\($/ { open=NR }
  block && /^set -euo pipefail$/ { strict=NR }
  block && /gh secret set ARMBIAN_APT_KEYRING_B64/ { update=NR }
  block && /^\)$/ { closed=NR }
  END { exit !(open && strict == open + 1 && update > strict && closed > update) }
' "${RELEASE_DOC}"

mkdir "${TMP}/bin"
cat >"${TMP}/bin/gpgv" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "${TMP}/bin/gpgv"
printf 'signed metadata fixture\n' >"${TMP}/InRelease"
printf 'keyring fixture\n' >"${TMP}/keyring.gpg"
if PATH="${TMP}/bin:${PATH}" bash "${AUTH}" verify-signature \
    --keyring "${TMP}/keyring.gpg" --inrelease "${TMP}/InRelease"; then
  printf 'bad BSP metadata signature was accepted\n' >&2
  exit 1
fi

GPG_HOME="${TMP}/gnupg"
install -d -m 0700 "${GPG_HOME}"

generate_signing_key() {
  local uid="$1"
  gpg --batch --quiet --homedir "${GPG_HOME}" --pinentry-mode loopback \
    --passphrase '' --quick-generate-key "${uid}" rsa2048 sign 1d
  gpg --batch --homedir "${GPG_HOME}" --with-colons --list-keys "${uid}" \
    | awk -F: '$1=="fpr"{print $10; exit}'
}

old_fpr="$(generate_signing_key 'Armbian historical fixture <old@example.invalid>')"
new_fpr="$(generate_signing_key 'Armbian rotation fixture <new@example.invalid>')"
unknown_fpr="$(generate_signing_key 'Unrelated fixture <unknown@example.invalid>')"

printf 'Origin: Armbian\nSuite: bookworm\n' >"${TMP}/Release"
gpg --batch --quiet --yes --homedir "${GPG_HOME}" --pinentry-mode loopback \
  --passphrase '' --local-user "${old_fpr}" --local-user "${new_fpr}" \
  --digest-algo SHA512 --clearsign --output "${TMP}/InRelease.dual" "${TMP}/Release"
gpg --batch --quiet --yes --homedir "${GPG_HOME}" --pinentry-mode loopback \
  --passphrase '' --local-user "${unknown_fpr}" --digest-algo SHA512 \
  --clearsign --output "${TMP}/InRelease.unknown" "${TMP}/Release"

gpg --batch --quiet --yes --homedir "${GPG_HOME}" \
  --output "${TMP}/old-only.gpg" --export "${old_fpr}"
gpg --batch --quiet --yes --homedir "${GPG_HOME}" \
  --output "${TMP}/new-only.gpg" --export "${new_fpr}"
gpg --batch --quiet --yes --homedir "${GPG_HOME}" \
  --output "${TMP}/combined.gpg" --export "${old_fpr}" "${new_fpr}"
gpg --batch --quiet --yes --homedir "${GPG_HOME}" \
  --output "${TMP}/combined-extra.gpg" --export "${old_fpr}" "${new_fpr}" "${unknown_fpr}"
printf 'not an OpenPGP keyring\n' >"${TMP}/malformed.gpg"
cp "${TMP}/InRelease.dual" "${TMP}/InRelease.malformed"
sed -i 's/Suite: bookworm/Suite: tampered/' "${TMP}/InRelease.malformed"

if ! auth_keyring_has_exact_fingerprints "${TMP}/combined.gpg" "${old_fpr}" "${new_fpr}"; then
  printf 'exact two-key Armbian rotation keyring was rejected\n' >&2
  exit 1
fi
if (
  sort() { return 127; }
  auth_keyring_has_exact_fingerprints "${TMP}/combined.gpg" "${old_fpr}" "${new_fpr}"
); then
  printf 'Armbian keyring policy accepted after normalization failed\n' >&2
  exit 1
fi
for keyring in old-only.gpg new-only.gpg combined-extra.gpg malformed.gpg; do
  if auth_keyring_has_exact_fingerprints "${TMP}/${keyring}" "${old_fpr}" "${new_fpr}"; then
    printf 'non-exact Armbian rotation keyring was accepted: %s\n' "${keyring}" >&2
    exit 1
  fi
done

emit_mock_primary() {
  local validity="$1" fingerprint="$2"
  printf 'pub:%s:4096:1:%s:1426518686:::-:::scESC::::::23::0:\n' \
    "${validity}" "${fingerprint: -16}"
  printf 'fpr:::::::::%s:\n' "${fingerprint}"
}

emit_mock_subkey() {
  local validity="$1"
  printf 'sub:%s:4096:1:1111111111111111:1426518686::::::s::::::23:\n' \
    "${validity}"
  printf 'fpr:::::::::1111111111111111111111111111111111111111:\n'
}

for key_state in r e i d; do
  if (
    gpg() {
      emit_mock_primary "${key_state}" "${old_fpr}"
      emit_mock_primary - "${new_fpr}"
    }
    auth_keyring_has_exact_fingerprints /unused "${old_fpr}" "${new_fpr}"
  ); then
    printf 'Armbian keyring policy accepted primary key state: %s\n' "${key_state}" >&2
    exit 1
  fi
  if (
    gpg() {
      emit_mock_primary - "${old_fpr}"
      emit_mock_subkey "${key_state}"
      emit_mock_primary - "${new_fpr}"
    }
    auth_keyring_has_exact_fingerprints /unused "${old_fpr}" "${new_fpr}"
  ); then
    printf 'Armbian keyring policy accepted subkey state: %s\n' "${key_state}" >&2
    exit 1
  fi
done

if ! auth_verify_release_signature "${TMP}/combined.gpg" "${TMP}/InRelease.dual"; then
  printf 'dual-signed InRelease was rejected by the exact two-key keyring\n' >&2
  exit 1
fi
for failure in \
  'old-only.gpg InRelease.dual' \
  'new-only.gpg InRelease.dual' \
  'combined.gpg InRelease.unknown' \
  'combined.gpg InRelease.malformed'; do
  read -r keyring inrelease <<<"${failure}"
  if auth_verify_release_signature "${TMP}/${keyring}" "${TMP}/${inrelease}"; then
    printf 'invalid Armbian signature case was accepted: %s\n' "${failure}" >&2
    exit 1
  fi
done

printf 'BSP signed-index/hash and dual-signing key-rotation contract: PASS\n'
