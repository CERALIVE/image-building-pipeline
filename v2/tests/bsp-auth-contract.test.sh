#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2="$(cd "${HERE}/.." && pwd)"
AUTH="${V2}/lib/fetch-debs-auth.sh"
FETCH="${V2}/lib/fetch-debs.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

[[ -f "${AUTH}" ]]
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
! grep -qiE 'trusted[=:][[:space:]]*(yes|true)' "${FETCH}" \
  "${V2}/mkosi/mkosi.images/platform/mkosi.postinst.chroot"
grep -q 'signed-by=' "${FETCH}"
grep -q 'ARMBIAN_APT_KEYRING' "${FETCH}"

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

printf 'BSP signed-index/hash contract: PASS\n'
