#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/common.sh"
# shellcheck source=lib/shared/deb-lib.sh
source "${HERE}/shared/deb-lib.sh"

PIN_FILE="${PIPELINE_DIR}/manifests/kernel/vendor-cls-fw.env"
PACKAGE_LIST="${PIPELINE_DIR}/manifests/packages/rk3588-vendor-kernel-extensions.list"
BUILDER_DOCKERFILE="${PIPELINE_DIR}/ci/Dockerfile.kernel-module"

usage() { printf 'Usage: build-kernel-extension.sh --out <directory>\n' >&2; }

out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) out="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown argument: $1" ;;
  esac
done
[[ -n "${out}" ]] || { usage; die "--out is required"; }

# This file is tracked, reviewed input containing assignments only.
# shellcheck disable=SC1090
source "${PIN_FILE}"
export PACKAGE_NAME PACKAGE_VERSION KERNEL_RELEASE KERNEL_IMAGE_PACKAGE KERNEL_IMAGE_VERSION
export HEADERS_PACKAGE HEADERS_VERSION
export SOURCE_DATE_EPOCH
mapfile -t declared_packages < <(awk 'NF && $1 !~ /^#/ { print $1 }' "${PACKAGE_LIST}")
[[ "${#declared_packages[@]}" -eq 1 && "${declared_packages[0]}" == "${PACKAGE_NAME}" ]] \
  || die "${PACKAGE_LIST} must declare exactly ${PACKAGE_NAME}"
[[ "${KERNEL_EXTENSION_PACKAGES:-}" == "${PACKAGE_NAME}" ]] \
  || die "kernel extension set must be exactly '${PACKAGE_NAME}', got '${KERNEL_EXTENSION_PACKAGES:-<empty>}'"

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  log_info "DRY-RUN would build ${PACKAGE_NAME} ${PACKAGE_VERSION} for ${KERNEL_RELEASE} from ${HEADERS_PACKAGE}=${HEADERS_VERSION} and ${SOURCE_COMMIT}"
  exit 0
fi

require_cmd curl
require_cmd docker
require_cmd sha256sum
require_cmd dpkg-deb

install -d -m 0755 "${out}"
work="${out}/.cls-fw-work"
rm -rf "${work}"
install -d -m 0755 "${work}"
trap 'rm -rf "${work}"' EXIT

curl -fsSL --retry 3 -o "${work}/headers.deb" "${HEADERS_URL}"
printf '%s  %s\n' "${HEADERS_SHA256}" "${work}/headers.deb" | sha256sum -c -
assert_deb_identity "${work}/headers.deb" "${HEADERS_PACKAGE}" "${HEADERS_VERSION}" arm64 \
  || die "downloaded headers package identity does not match the pin"

curl -fsSL --retry 3 -o "${work}/cls_fw.c" "${SOURCE_URL}"
printf '%s  %s\n' "${SOURCE_SHA256}" "${work}/cls_fw.c" | sha256sum -c -

builder="ceralive-kernel-module-builder:$(sha256sum "${BUILDER_DOCKERFILE}" "${HERE}/kernel/build-cls-fw-container.sh" | sha256sum | cut -c1-12)"
if ! docker image inspect "${builder}" >/dev/null 2>&1; then
  docker build -f "${BUILDER_DOCKERFILE}" -t "${builder}" "${PIPELINE_DIR}"
fi

docker run --rm --network none --user "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  -e PACKAGE_NAME -e PACKAGE_VERSION -e KERNEL_RELEASE \
  -e KERNEL_IMAGE_PACKAGE -e KERNEL_IMAGE_VERSION \
  -e HEADERS_PACKAGE -e HEADERS_VERSION \
  -e SOURCE_DATE_EPOCH \
  -v "${work}:/work" -v "${out}:/out" "${builder}"

deb="${out}/${PACKAGE_NAME}_${PACKAGE_VERSION}_arm64.deb"
assert_deb_identity "${deb}" "${PACKAGE_NAME}" "${PACKAGE_VERSION}" arm64 \
  || die "built kernel extension package identity mismatch"
log_success "built kernel extension package: ${deb}"
