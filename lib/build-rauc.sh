#!/usr/bin/env bash
#
# build-rauc.sh — RAUC-build-from-source stage for the CeraLive v2 pipeline.
#
# Todo 22 RAUC-version-path follow-up (decisions.md, 2026-09-24, "Todo 22 RAUC
# version path — FINAL RULING"). Unlike lib/build-kernel.sh (gated on a
# `kernel_source:` manifest block), this stage runs UNCONDITIONALLY on every
# board build — both the rk3588 and x86_64 families ship RAUC, and neither
# carries a CeraLive-owned RAUC fork (Option A of the ruling: in-pipeline build,
# no new repo, zero CeraLive patches to upstream or to Debian's packaging).
#
# WHAT THIS BUILDS: upstream RAUC v1.15.2 (GitHub release source tarball,
# static SHA-256 pin) packaged with Debian unstable's OWN, byte-unmodified
# `debian/` directory (gpgv-verified against the signed InRelease/Sources
# chain), producing `rauc_1.15.2-1+ceralive.1_<arch>.deb` +
# `rauc-service_1.15.2-1+ceralive.1_all.deb`. See
# manifests/rauc-deb-versions.txt for the full pin rationale, including WHY
# Debian unstable's packaging is used rather than trixie's own (empirically
# verified: four of trixie's six patches are already incorporated upstream in
# 1.15.2, and unstable's maintainer independently reached the same conclusion).
#
# OUTPUT CONSUMPTION mirrors the kernel's, NOT gstreamer-rockchip/librga's: the
# built .deb pair is staged in-process into the common debs pool by
# lib/stages/rauc-build.sh, the same way lib/stages/kernel-build.sh stages a
# source-built kernel .deb — never a second downloadable URL+SHA round-trip for
# the BUILT artifact (there is no CeraLive-owned release to host one at).
#
# shellcheck shell=bash

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${HERE}/common.sh"
# shellcheck source=lib/paths.sh
source "${HERE}/paths.sh"
# shellcheck source=lib/shared/deb-lib.sh
source "${HERE}/shared/deb-lib.sh"
# shellcheck source=lib/fetch/index.sh
source "${HERE}/fetch/index.sh"
# shellcheck source=lib/fetch-debs-auth.sh
source "${HERE}/fetch-debs-auth.sh"

PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"
RAUC_BUILDER_DOCKERFILE="${PIPELINE_DIR}/ci/Dockerfile.rauc"
RAUC_DEB_VERSIONS_FILE="${RAUC_DEB_VERSIONS_FILE:-${PIPELINE_DIR}/manifests/rauc-deb-versions.txt}"

# Same digest-pinned trixie base the kernel builder already uses
# (manifests/families/rk3588.yaml kernel_source.builder_image) — one reviewed
# libc/toolchain generation across every containerized build stage in this
# pipeline, not a fourth one this stage introduces on its own.
RAUC_BUILDER_BASE_IMAGE="${CERALIVE_RAUC_BUILDER_BASE_IMAGE:-debian:trixie-20260623-slim@sha256:28de0877c2189802884ccd20f15ee41c203573bd87bb6b883f5f46362d24c5c2}"

# ---------------------------------------------------------------------------
# CONCERN MODULES (lib/rauc-build/) — this file stays the STAGE: the CLI, the
# locations, and main(). Mirrors lib/build-kernel.sh's own "entry stays thin,
# each concern is its own sourced module" shape exactly:
#
#   source.sh   pinned fetch: upstream tarball (SHA-256) + Debian packaging
#               (gpgv-against-InRelease) + source-tree assembly
#   builder.sh  builder container resolution/build
#   package.sh  built-.deb identity validation
#
# EXPLICIT and ORDERED, never a glob — a module lost or never wired up fails
# HERE, at source time, not halfway through a real build.
# ---------------------------------------------------------------------------
RAUC_BUILD_LIB_DIR="${HERE}/rauc-build"
# shellcheck source=rauc-build/source.sh
source "${RAUC_BUILD_LIB_DIR}/source.sh"
# shellcheck source=rauc-build/builder.sh
source "${RAUC_BUILD_LIB_DIR}/builder.sh"
# shellcheck source=rauc-build/package.sh
source "${RAUC_BUILD_LIB_DIR}/package.sh"

usage() {
  cat >&2 <<EOF
Usage: build-rauc.sh --arch <arm64|amd64> --out <dir>

Builds rauc + rauc-service from pinned upstream source + Debian's own
packaging directory (manifests/rauc-deb-versions.txt), inside the
digest-pinned builder container, and stages the validated .deb pair into <dir>.

Env:
  CERALIVE_RAUC_BUILDER_IMAGE       pin a prebuilt builder image tag (skips build)
  CERALIVE_RAUC_BUILDER_BASE_IMAGE  override the FROM base (default: the kernel
                                     builder's own digest-pinned trixie base)
  DRY_RUN=1                         plan only; fetches/verifies pins, builds nothing
EOF
}

# ---------------------------------------------------------------------------
# rauc_read_pin <key> — read one KEY=VALUE line from RAUC_DEB_VERSIONS_FILE.
# Fails closed on an absent key rather than silently defaulting.
# ---------------------------------------------------------------------------
rauc_read_pin() {
  local key="$1" value
  [[ -f "${RAUC_DEB_VERSIONS_FILE}" ]] \
    || die "rauc-build: pin file missing: ${RAUC_DEB_VERSIONS_FILE}"
  value="$(awk -F= -v k="${key}" '$1==k { sub(/^[^=]+=/, ""); print; exit }' "${RAUC_DEB_VERSIONS_FILE}")"
  [[ -n "${value}" ]] \
    || die "rauc-build: pin file carries no ${key}= line: ${RAUC_DEB_VERSIONS_FILE}"
  printf '%s' "${value}"
}

main() {
  local arch="" out=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --arch) arch="${2:-}"; shift 2 ;;
      --out)  out="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) usage; die "unknown argument: $1" ;;
    esac
  done
  [[ -n "${arch}" ]] || { usage; die "--arch is required"; }
  [[ -n "${out}" ]]  || { usage; die "--out is required"; }
  case "${arch}" in
    arm64|amd64) ;;
    *) die "rauc-build: unsupported --arch '${arch}' (expected arm64|amd64)" ;;
  esac
  require_cmd curl
  require_cmd sha256sum
  require_cmd xz
  require_cmd gpgv
  mkdir -p "${out}"

  local upstream_version upstream_url upstream_sha256
  local debian_suite debian_component debian_source_version debian_tar_filename
  local keyring_path ceralive_suffix
  local -a fingerprints=()
  upstream_version="$(rauc_read_pin UPSTREAM_VERSION)"
  upstream_url="$(rauc_read_pin UPSTREAM_URL)"
  upstream_sha256="$(rauc_read_pin UPSTREAM_SHA256)"
  debian_suite="$(rauc_read_pin DEBIAN_SUITE)"
  debian_component="$(rauc_read_pin DEBIAN_COMPONENT)"
  debian_source_version="$(rauc_read_pin DEBIAN_SOURCE_VERSION)"
  debian_tar_filename="$(rauc_read_pin DEBIAN_DEBIAN_TAR_FILENAME)"
  keyring_path="$(rauc_read_pin DEBIAN_ARCHIVE_KEYRING_PATH)"
  ceralive_suffix="$(rauc_read_pin CERALIVE_SUFFIX)"
  read -r -a fingerprints <<<"$(rauc_read_pin DEBIAN_ARCHIVE_KEY_FINGERPRINTS)"

  log_info "=== rauc-build: arch=${arch} upstream=${upstream_version} debian=${debian_suite}/${debian_source_version} suffix=${ceralive_suffix} out=${out} ==="

  if [[ -n "${DRY_RUN:-}" ]]; then
    log_info "DRY-RUN would fetch+verify: ${upstream_url} (sha256=${upstream_sha256})"
    log_info "DRY-RUN would fetch+verify: ${debian_tar_filename} via gpgv(${debian_suite})+Sources"
    log_info "DRY-RUN would build: rauc_${debian_source_version}${ceralive_suffix}_${arch}.deb + rauc-service_${debian_source_version}${ceralive_suffix}_all.deb"
    return 0
  fi

  local work; work="$(mktemp -d)"
  # shellcheck disable=SC2064  # intentional immediate expansion: an EXIT trap
  # fires at actual PROCESS exit, after main()'s own local `work` has already
  # gone out of scope, so lazy (single-quoted) expansion of ${work} here would
  # read as unbound under set -u. Baking the resolved path in now avoids it.
  trap "rm -rf '${work}'" EXIT

  local upstream_tar; upstream_tar="${work}/$(basename "${upstream_url}")"
  rauc_fetch_upstream_tarball "${upstream_url}" "${upstream_sha256}" "${upstream_tar}"

  local debian_tar="${work}/${debian_tar_filename}"
  rauc_fetch_debian_packaging "${debian_suite}" "${debian_component}" \
    "${debian_source_version}" "${debian_tar_filename}" "${keyring_path}" \
    "${debian_tar}" "${fingerprints[@]}"

  local src_dir="${work}/src" built_version
  built_version="$(rauc_assemble_source_tree "${upstream_tar}" "${debian_tar}" \
    "${ceralive_suffix}" "${debian_source_version}" "${src_dir}")"

  local runtime; runtime="$(select_rauc_container_runtime)"
  local platform; platform="$(rauc_docker_platform "${arch}")"
  local tag; tag="$(resolve_rauc_builder_tag "${RAUC_BUILDER_BASE_IMAGE}" "${platform}")"
  ensure_rauc_builder_image "${runtime}" "${RAUC_BUILDER_BASE_IMAGE}" "${tag}" "${platform}"
  mkdir -p "${work}/out"

  log_info "rauc-build: dpkg-buildpackage inside ${tag} (platform=${platform})"
  "${runtime}" run --rm --platform "${platform}" \
    -e "HOST_UID=$(id -u)" -e "HOST_GID=$(id -g)" \
    -v "${src_dir}:/build/rauc:rw" \
    -v "${work}/out:/out" \
    -w /build/rauc \
    "${tag}" \
    bash -euo pipefail -c '
      export DEBIAN_FRONTEND=noninteractive
      # nocheck: several of RAUC upstream own test-suite cases need a
      # privileged loop/dm-verity device (test/dm.c, test/bundle.c) this
      # ordinary (non --privileged) builder container does not grant, matching
      # exactly the <!nocheck> annotation already on dbus/e2fsprogs/fakeroot/
      # faketime/opensc*/softhsm2/squashfs-tools in the source packages own
      # debian/control Build-Depends -- this is the documented, standard
      # dpkg-buildpackage mechanism those annotations exist for, not a
      # CeraLive-specific build-recipe edit.
      DEB_BUILD_OPTIONS=nocheck dpkg-buildpackage -us -uc -b
      cp ../rauc_*.deb ../rauc-service_*.deb /out/
      chown -R "${HOST_UID}:${HOST_GID}" /build/rauc /out
    ' \
    || die "rauc-build: containerized build failed (see the container log above)"

  local -a built
  mapfile -t built < <(validate_built_rauc_debs "${work}/out" "${built_version}" "${arch}")
  local rauc_deb="${built[0]}" service_deb="${built[1]}"

  "${MKOSI_PACKAGE_STAGING_SH:-${HERE}/stage-mkosi-package.sh}" "${rauc_deb}" "${out}"
  "${MKOSI_PACKAGE_STAGING_SH:-${HERE}/stage-mkosi-package.sh}" "${service_deb}" "${out}"
  log_success "rauc-build: staged $(basename "${rauc_deb}") + $(basename "${service_deb}") -> ${out}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
