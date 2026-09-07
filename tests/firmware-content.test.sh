#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/lib/fetch-debs.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# Given the reviewed archive identity, when parsed or compared with signed-index
# fields, then every axis must agree before the archive can be accepted.
if [[ ! -f "${ROOT}/lib/shared/firmware-content.sh" ]]; then
  printf 'FAIL: strict firmware archive content parser is not implemented\n' >&2
  exit 1
fi
source "${ROOT}/lib/shared/firmware-content.sh"
firmware_content_read "${ROOT}/manifests/armbian-firmware-content.json" >"${TMP}/committed-fields"
pin="${TMP}/pin.json"
cat >"${pin}" <<'EOF'
{"package":"armbian-firmware-full","version":"26.8.3","architecture":"all","archive_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","compressed_bytes":763716604,"installed_kib":2283248}
EOF
firmware_content_read "${pin}" >"${TMP}/fields"
expected=$'armbian-firmware-full\t26.8.3\tall\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\t763716604\t2283248'
[[ "$(<"${TMP}/fields")" == "${expected}" ]]
for mutation in 'del(.package)' '.extra=1' '.archive_sha256="bad"' \
    '.archive_sha256=("A"*64)' '.archive_sha256=("a"*64+"\n")' '.package="armbian-firmware"' \
    '.version="26.8.4"' '.architecture="arm64"' \
    '.compressed_bytes="763716604"' '.compressed_bytes=763716605' \
    '.installed_kib=2283249' '.installed_kib=null' '.=[]'; do
  jq "${mutation}" "${pin}" >"${TMP}/bad.json"
  if firmware_content_read "${TMP}/bad.json" > /dev/null 2>&1; then
    printf 'FAIL: accepted malformed pin: %s\n' "${mutation}" >&2; exit 1
  fi
done
cat >"${TMP}/Packages" <<'EOF'
Package: armbian-firmware-full
Version: 26.8.3
Architecture: all
Filename: pool/full.deb
SHA256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
Size: 763716604
Installed-Size: 2283248
EOF
firmware_content_assert_index "${pin}" "${TMP}/Packages"
for field in Package Version Architecture SHA256 Size Installed-Size; do
  awk -v field="${field}:" '$1==field {$0=field " wrong"} {print}' \
    "${TMP}/Packages" >"${TMP}/bad-index"
  if firmware_content_assert_index "${pin}" "${TMP}/bad-index" > /dev/null 2>&1; then
    printf 'FAIL: accepted index disagreement: %s\n' "${field}" >&2; exit 1
  fi
done
cat "${TMP}/Packages" <(printf '\n') "${TMP}/Packages" >"${TMP}/duplicate-index"
if firmware_content_assert_index "${pin}" "${TMP}/duplicate-index" > /dev/null 2>&1; then
  printf 'FAIL: accepted ambiguous signed index\n' >&2; exit 1
fi
sha="$(jq -r .archive_sha256 "${ROOT}/manifests/armbian-firmware-content.json")"
sed "s/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/${sha}/" "${TMP}/Packages" >"${TMP}/committed-index"
bsp_assert_firmware_content "${TMP}/committed-index" armbian-firmware-full=26.8.3
if bsp_assert_firmware_content "${TMP}/Packages" armbian-firmware-full=26.8.3 >/dev/null 2>&1; then
  printf 'FAIL: fetch accepts a same-version firmware re-spin\n' >&2; exit 1
fi
for transport in _fetch_bsp_native _fetch_bsp_curl; do
  body="$(declare -f "${transport}")"
  pin_line="$(grep -n 'bsp_assert_firmware_content' <<<"${body}" | cut -d: -f1)"
  pool_line="$(grep -n '_run_bounded' <<<"${body}" | cut -d: -f1)"
  [[ -n "${pin_line}" && -n "${pool_line}" && "${pin_line}" -lt "${pool_line}" ]]
done
if (DRY_RUN=1 FIRMWARE_PACKAGES=armbian-firmware fetch_bsp "${ROOT}/manifests/families/rk3588.yaml" "${TMP}") >"${TMP}/coexist" 2>&1; then
  printf 'FAIL: full and trimmed firmware coexistence accepted\n' >&2; exit 1
fi
grep -q 'must not coexist' "${TMP}/coexist"
printf 'PASS: strict firmware pin, signed-index lockstep, both fetch transports and coexistence contract\n'
