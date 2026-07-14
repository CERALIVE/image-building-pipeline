#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2="$(cd "${HERE}/.." && pwd)"
AUTH="${V2}/lib/fetch-debs-auth.sh"
FETCH="${V2}/lib/fetch-debs.sh"
PINS="${V2}/manifests/armbian-bsp-deb-versions.txt"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# shellcheck source=../lib/fetch-debs-auth.sh
source "${AUTH}"
# shellcheck source=../lib/fetch-debs.sh
source "${FETCH}"

# Publishing must fail closed if archive readability cannot be normalized. Bash
# suppresses errexit inside functions reached through `if !`, so this regression
# exercises the helper through that exact caller shape.
mkdir -p "${TMP}/chmod-failure/bin" "${TMP}/chmod-failure/dest"
printf 'fixture\n' >"${TMP}/chmod-failure/source.deb"
cat >"${TMP}/chmod-failure/bin/chmod" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
/usr/bin/chmod 0755 "${TMP}/chmod-failure/bin/chmod"
if PATH="${TMP}/chmod-failure/bin:${PATH}" publish_staged_deb \
    "${TMP}/chmod-failure/source.deb" "${TMP}/chmod-failure/dest/package.deb"; then
  printf 'staged package publication swallowed chmod failure\n' >&2
  exit 1
fi
[[ -f "${TMP}/chmod-failure/source.deb" ]]
[[ ! -e "${TMP}/chmod-failure/dest/package.deb" ]]

cat >"${TMP}/Packages.current-like" <<'EOF'
Package: linux-image-vendor-rk35xx
Version: 26.2.1
Architecture: arm64
Filename: pool/linux-image-vendor-rk35xx_26.2.1_arm64.deb
SHA256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

Package: linux-image-vendor-rk35xx
Version: 26.5.1
Architecture: arm64
Filename: pool/linux-image-vendor-rk35xx_26.5.1_arm64.deb
SHA256: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

Package: linux-dtb-vendor-rk35xx
Version: 26.2.1
Architecture: arm64
Filename: pool/linux-dtb-vendor-rk35xx_26.2.1_arm64.deb
SHA256: cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc

Package: linux-dtb-vendor-rk35xx
Version: 26.5.1
Architecture: arm64
Filename: pool/linux-dtb-vendor-rk35xx_26.5.1_arm64.deb
SHA256: dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd

Package: armbian-firmware
Version: 26.5.1
Architecture: all
Filename: pool/armbian-firmware_26.5.1_all.deb
SHA256: eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee

Package: linux-u-boot-rock-5b-plus-vendor
Version: 26.5.1
Architecture: arm64
Filename: pool/linux-u-boot-rock-5b-plus-vendor_26.5.1_arm64.deb
SHA256: ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
EOF

rock_packages=(
  linux-image-vendor-rk35xx
  linux-dtb-vendor-rk35xx
  armbian-firmware
  linux-u-boot-rock-5b-plus-vendor
)

legacy_lookup_package() {
  local index="$1" package="$2" arch="$3" rows
  rows="$(awk -v want_pkg="${package}" -v want_arch="${arch}" '
    BEGIN { RS=""; FS="\n" }
    {
      pkg=""; a=""; filename=""; sha=""
      for (i=1; i<=NF; i++) {
        if ($i ~ /^Package: /) pkg=substr($i,10)
        else if ($i ~ /^Architecture: /) a=substr($i,15)
        else if ($i ~ /^Filename: /) filename=substr($i,11)
        else if ($i ~ /^SHA256: /) sha=substr($i,9)
      }
      if (pkg==want_pkg && a==want_arch && filename!="" && sha!="") print filename
    }
  ' "${index}")"
  [[ "$(grep -c . <<<"${rows}")" -eq 1 ]]
}

# Given the metadata shape from failed run 29289411641, when bare package names
# are resolved, then the current failure is exactly three rejects and one match.
baseline_status=()
for package in "${rock_packages[@]}"; do
  if legacy_lookup_package "${TMP}/Packages.current-like" "${package}" arm64; then
    baseline_status+=(PASS)
  else
    baseline_status+=(FAIL)
  fi
done
[[ "${baseline_status[*]}" == 'FAIL FAIL FAIL PASS' ]]
printf 'baseline: bare BSP names reproduce FAIL FAIL FAIL PASS\n'

# Given production fetch code, when the regression seam is inspected, then exact
# BSP specs, signed-index preflight, and release-identity validation must exist.
if [[ ! -f "${PINS}" ]] || ! declare -F bsp_download_specs >/dev/null \
    || ! declare -F bsp_assert_index_specs >/dev/null \
    || ! declare -F auth_release_has_identity >/dev/null; then
  printf 'FAIL: exact BSP package resolution is not implemented; production still uses ambiguous bare names\n' >&2
  exit 1
fi

specs_text="$(bsp_download_specs "${rock_packages[@]}")"
mapfile -t rock_specs <<<"${specs_text}"
expected_specs=(
  linux-image-vendor-rk35xx=26.5.1
  linux-dtb-vendor-rk35xx=26.5.1
  armbian-firmware=26.5.1
  linux-u-boot-rock-5b-plus-vendor=26.5.1
)
[[ "${rock_specs[*]}" == "${expected_specs[*]}" ]]
[[ "$(bsp_download_specs linux-u-boot-orangepi5-plus-vendor)" == \
  'linux-u-boot-orangepi5-plus-vendor=26.5.1' ]]
grep -q '^  - linux-u-boot-orangepi5-plus-vendor$' \
  "${V2}/manifests/boards/orange-pi-5-plus.yaml"

# Given a non-Armbian family, DRY_RUN omits an inapplicable Armbian fetch and a
# real fetch fails closed until an authenticated Debian BSP source is implemented.
mkdir -p "${TMP}/non-armbian"
DRY_RUN=1
non_armbian_plan="$(fetch_bsp \
  "${V2}/manifests/families/x86_64.yaml" "${TMP}/non-armbian" 2>&1)"
grep -q 'non-Armbian family: BSP fetch omitted from DRY_RUN plan' \
  <<<"${non_armbian_plan}"
if grep -q 'apt.armbian.com' <<<"${non_armbian_plan}"; then
  printf 'non-Armbian DRY_RUN emitted an Armbian package plan\n' >&2
  exit 1
fi
DRY_RUN=""
if (fetch_bsp "${V2}/manifests/families/x86_64.yaml" \
    "${TMP}/non-armbian" >/dev/null 2>&1); then
  printf 'real non-Armbian BSP fetch did not fail closed\n' >&2
  exit 1
fi

build_test_deb() {
  local out="$1" package="$2" version="$3" arch="$4" work
  work="$(mktemp -d "${TMP}/deb-fixture.XXXXXX")"
  mkdir -p "${work}/control"
  printf 'Package: %s\nVersion: %s\nArchitecture: %s\nMaintainer: Test <test@example.invalid>\nDescription: fixture\n' \
    "${package}" "${version}" "${arch}" >"${work}/control/control"
  printf '2.0\n' >"${work}/debian-binary"
  tar -czf "${work}/control.tar.gz" -C "${work}/control" ./control
  tar -czf "${work}/data.tar.gz" --files-from /dev/null
  ar r "${out}" "${work}/debian-binary" "${work}/control.tar.gz" \
    "${work}/data.tar.gz" >/dev/null
  rm -rf "${work}"
}

# Native apt workers must propagate apt failures, reject empty-success responses,
# and inspect the one downloaded package before it can enter final staging.
mkdir -p "${TMP}/native-ok" "${TMP}/native-fail" "${TMP}/native-empty" \
  "${TMP}/native-wrong-arch"
build_test_deb "${TMP}/native-fixture.deb" demo 1.0 all
build_test_deb "${TMP}/native-wrong-arch.deb" demo 1.0 amd64
chmod 600 "${TMP}/native-fixture.deb"
_APT_OPTS=()
DRY_RUN=""
(
  _BSP_DEBS="${TMP}/native-ok"
  apt-get() { cp "${TMP}/native-fixture.deb" ./demo_1.0_all.deb; }
  _fetch_bsp_native_one demo=1.0
)
[[ "$(find "${TMP}/native-ok" -maxdepth 1 -name '*.deb' | wc -l)" -eq 1 ]]
[[ "$(stat -c '%a' "${TMP}/native-ok/demo_1.0_all.deb")" == 644 ]]
if (
  _BSP_DEBS="${TMP}/native-fail"
  apt-get() { return 100; }
  _fetch_bsp_native_one demo=1.0
); then
  printf 'native BSP worker swallowed apt-get download failure\n' >&2
  exit 1
fi
if (
  _BSP_DEBS="${TMP}/native-empty"
  apt-get() { return 0; }
  _fetch_bsp_native_one demo=1.0
); then
  printf 'native BSP worker accepted HTTP/apt success without a package\n' >&2
  exit 1
fi
if (
  _BSP_DEBS="${TMP}/native-wrong-arch"
  apt-get() { cp "${TMP}/native-wrong-arch.deb" ./demo_1.0_amd64.deb; }
  _fetch_bsp_native_one demo=1.0
); then
  printf 'native BSP worker accepted a wrong-architecture package\n' >&2
  exit 1
fi

mock_curl_copy_fixture() {
  local output=""
  while (( $# > 0 )); do
    case "$1" in
      -o) output="$2"; shift 2 ;;
      --retry) shift 2 ;;
      -*) shift ;;
      *) shift ;;
    esac
  done
  [[ -n "${output}" ]]
  cp "${CURL_FIXTURE}" "${output}"
}

mkdir -p "${TMP}/curl-control-mismatch" "${TMP}/curl-checksum-mismatch"
build_test_deb "${TMP}/curl-control-mismatch.deb" demo 9.9 arm64
curl_control_sha="$(sha256sum "${TMP}/curl-control-mismatch.deb" | awk '{print $1}')"
cat >"${TMP}/Packages.curl-control-mismatch" <<EOF
Package: demo
Version: 1.0
Architecture: arm64
Filename: pool/demo_1.0_arm64.deb
SHA256: ${curl_control_sha}
EOF
if (
  _BSP_DEBS="${TMP}/curl-control-mismatch"
  _PKG_INDEX="${TMP}/Packages.curl-control-mismatch"
  CURL_FIXTURE="${TMP}/curl-control-mismatch.deb"
  curl() { mock_curl_copy_fixture "$@"; }
  _fetch_bsp_curl_one demo=1.0
); then
  printf 'curl BSP worker accepted checksum-valid mismatched control metadata\n' >&2
  exit 1
fi
[[ -z "$(find "${TMP}/curl-control-mismatch" -maxdepth 1 -type f -print -quit)" ]]

cat >"${TMP}/Packages.curl-checksum-mismatch" <<'EOF'
Package: demo
Version: 1.0
Architecture: arm64
Filename: pool/demo_1.0_arm64.deb
SHA256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
if (
  _BSP_DEBS="${TMP}/curl-checksum-mismatch"
  _PKG_INDEX="${TMP}/Packages.curl-checksum-mismatch"
  CURL_FIXTURE="${TMP}/native-fixture.deb"
  curl() { mock_curl_copy_fixture "$@"; }
  _fetch_bsp_curl_one demo=1.0
); then
  printf 'curl BSP worker accepted a package checksum mismatch\n' >&2
  exit 1
fi
[[ -z "$(find "${TMP}/curl-checksum-mismatch" -maxdepth 1 -type f -print -quit)" ]]

# Given curl's mktemp destination is 0600, when the verified package is published
# to staging, then mkosi's sandboxed repository helper can read it as mode 0644.
mkdir -p "${TMP}/curl-readable"
build_test_deb "${TMP}/curl-readable.deb" demo 1.0 arm64
chmod 600 "${TMP}/curl-readable.deb"
curl_readable_sha="$(sha256sum "${TMP}/curl-readable.deb" | awk '{print $1}')"
cat >"${TMP}/Packages.curl-readable" <<EOF
Package: demo
Version: 1.0
Architecture: arm64
Filename: pool/demo_1.0_arm64.deb
SHA256: ${curl_readable_sha}
EOF
(
  _BSP_DEBS="${TMP}/curl-readable"
  _PKG_INDEX="${TMP}/Packages.curl-readable"
  CURL_FIXTURE="${TMP}/curl-readable.deb"
  curl() { mock_curl_copy_fixture "$@"; }
  _fetch_bsp_curl_one demo=1.0
)
[[ "$(stat -c '%a' "${TMP}/curl-readable/demo_1.0_arm64.deb")" == 644 ]]

# Given retained historical versions and Architecture: all firmware, when exact
# reviewed pins are resolved for arm64, then every required record is unique.
bsp_assert_index_specs "${TMP}/Packages.current-like" arm64 "${rock_specs[@]}"
for spec in "${rock_specs[@]}"; do
  package="${spec%%=*}"
  version="${spec#*=}"
  auth_lookup_package "${TMP}/Packages.current-like" "${package}" "${version}" arm64 >/dev/null
done

# Given stale metadata with only an older kernel, when the reviewed pin is
# preflighted, then the resolver refuses to fall back to that older record.
cat >"${TMP}/Packages.stale" <<'EOF'
Package: linux-image-vendor-rk35xx
Version: 26.2.1
Architecture: arm64
Filename: pool/linux-image-vendor-rk35xx_26.2.1_arm64.deb
SHA256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
if bsp_assert_index_specs "${TMP}/Packages.stale" arm64 linux-image-vendor-rk35xx=26.5.1; then
  printf 'stale metadata silently changed the BSP pin\n' >&2
  exit 1
fi

# Given a signed index with only part of the required set, when the whole set is
# preflighted, then package download cannot begin from a partial resolution.
awk 'BEGIN { RS=""; ORS="\n\n" } $0 !~ /^Package: linux-u-boot-rock-5b-plus-vendor\n/' \
  "${TMP}/Packages.current-like" >"${TMP}/Packages.partial"
if bsp_assert_index_specs "${TMP}/Packages.partial" arm64 "${rock_specs[@]}"; then
  printf 'partial BSP package availability was accepted\n' >&2
  exit 1
fi

# Given an amd64-only record, when arm64 is requested, then it is rejected while
# Debian's architecture-independent `all` record remains compatible.
cat >"${TMP}/Packages.wrong-arch" <<'EOF'
Package: linux-image-vendor-rk35xx
Version: 26.5.1
Architecture: amd64
Filename: pool/linux-image-vendor-rk35xx_26.5.1_amd64.deb
SHA256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
if auth_lookup_package "${TMP}/Packages.wrong-arch" linux-image-vendor-rk35xx 26.5.1 arm64; then
  printf 'wrong package architecture was accepted\n' >&2
  exit 1
fi
auth_lookup_package "${TMP}/Packages.current-like" armbian-firmware 26.5.1 arm64 >/dev/null

# Given authenticated Release metadata, when suite/architecture/component are
# checked, then only the configured bookworm/main/arm64 identity is accepted.
cat >"${TMP}/InRelease.headers" <<'EOF'
Suite: bookworm
Codename: bookworm
Architectures: all amd64 arm64 armhf
Components: bookworm-utils main
EOF
auth_release_has_identity "${TMP}/InRelease.headers" bookworm main arm64
if auth_release_has_identity "${TMP}/InRelease.headers" trixie main arm64; then
  printf 'wrong Armbian suite was accepted\n' >&2
  exit 1
fi
if auth_release_has_identity "${TMP}/InRelease.headers" bookworm main riscv64; then
  printf 'wrong Armbian release architecture was accepted\n' >&2
  exit 1
fi

# Given an HTTP-success body whose bytes are not the signed-index payload, when
# checksum validation runs, then transport success cannot masquerade as a package.
printf '<html>200 OK, but not a Debian package</html>\n' >"${TMP}/http-200-body"
if auth_verify_file "${TMP}/http-200-body" \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; then
  printf 'misleading HTTP success bypassed package checksum validation\n' >&2
  exit 1
fi

printf 'BSP exact-version/suite/architecture/adversarial resolution contract: PASS\n'
