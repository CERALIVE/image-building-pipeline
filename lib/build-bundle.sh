#!/usr/bin/env bash
# Build a signed verity/adaptive RAUC OS bundle from a full-size ext4 slot image.
# The root signing key never enters the builder; the leaf and chain sign the bundle.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/common.sh"
# shellcheck source=lib/disk/slot-image.sh
source "${HERE}/disk/slot-image.sh"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"
IMAGES_DIR="${PIPELINE_DIR}/images"
SOURCE_DATE_EPOCH="$(resolve_source_date_epoch "${PIPELINE_DIR}")"
export SOURCE_DATE_EPOCH

[[ -n "${CERALIVE_RAUC_PKI_DIR:-}" ]] \
  || die "CERALIVE_RAUC_PKI_DIR is required (resolve it with rauc-pki-contract.sh)"
RAUC_PKI_DIR="${CERALIVE_RAUC_PKI_DIR}"
RAUC_ROOT_CA="${RAUC_PKI_DIR}/root-ca.pem"
RAUC_CHAIN="${RAUC_PKI_DIR}/chain.pem"
RAUC_LEAF_CERT="${RAUC_PKI_DIR}/leaf-signing.pem"
RAUC_LEAF_KEY="${RAUC_PKI_DIR}/leaf-signing.key"
RAUC_ROOT_KEY="${RAUC_PKI_DIR}/root-ca.key"
RAUC_VERIFY_OPTS=(-C keyring:check-purpose=codesign)

usage() {
  printf 'Usage: build-bundle.sh <board> <rootfs-tree>\n' >&2
}

assert_pki() {
  local f
  for f in "${RAUC_ROOT_CA}" "${RAUC_CHAIN}" "${RAUC_LEAF_CERT}" "${RAUC_LEAF_KEY}"; do
    [[ -s "${f}" ]] || die "RAUC PKI file missing or empty: ${f}"
  done
}

assert_no_root_signing() {
  local rendered="$*"
  [[ "${rendered}" != *"$(basename "${RAUC_ROOT_KEY}")"* ]] \
    || die "REFUSING to sign: root-ca.key must stay offline"
  [[ "${rendered}" == *leaf-signing.key* ]] \
    || die "signing invocation does not use leaf-signing.key"
}

write_manifest() {
  local path="$1" compatible="$2" version="$3"
  cat >"${path}" <<EOF
[update]
compatible=${compatible}
version=${version}

[bundle]
format=verity

[image.rootfs]
filename=rootfs.ext4
adaptive=block-hash-index
EOF
}

# The canonical build already has the builder image; direct/native callers use
# their local RAUC. Verification uses the same keyring and purpose on both paths.
bundle_with_rauc() {
  local content="$1" out="$2" runtime image out_dir
  # RAUC's verity bundler refuses a squashfs payload <= 4096 bytes (bundle.c:
  # "squashfs size (%llu) must be larger than 4096 bytes" — a single dm-verity
  # block has no hash tree to build). A tiny bundle (e.g. the cert-rotation
  # payload) can compress right up against that floor; callers with genuinely
  # small content set RAUC_BUNDLE_MKSQUASHFS_ARGS (e.g. "-noD -noF") so `rauc
  # bundle --mksquashfs-args=` skips data/fragment compression instead of this
  # helper silently failing on input the OS-bundle path never has to worry
  # about. Unset for every other caller — behaviour there is unchanged.
  local -a mksquashfs_opt=()
  [[ -n "${RAUC_BUNDLE_MKSQUASHFS_ARGS:-}" ]] \
    && mksquashfs_opt=("--mksquashfs-args=${RAUC_BUNDLE_MKSQUASHFS_ARGS}")
  if [[ -n "${MKOSI_BUILDER_IMAGE:-}" && "${MKOSI_NATIVE:-0}" != 1 ]]; then
    if command -v docker >/dev/null 2>&1; then runtime=docker
    elif command -v podman >/dev/null 2>&1; then runtime=podman
    else die "no container runtime for canonical RAUC bundle build"; fi
    image="${MKOSI_BUILDER_IMAGE}"
    out_dir="$(dirname "${out}")"
    # ci/Dockerfile deliberately ships no `rauc` (Debian trixie's is 1.13, which
    # cannot build/verify format=verity bundles). The pipeline's own source-built
    # RAUC 1.15.2 pair (lib/build-rauc.sh, staged by stage_rauc_build at
    # RAUC_DEB_DIR) is installed into the container at bundle-build time instead,
    # so this path never silently falls back to a stale system rauc.
    [[ -n "${RAUC_DEB_DIR:-}" && -d "${RAUC_DEB_DIR}" ]] \
      || die "RAUC_DEB_DIR is required for the containerized bundle build (the RAUC 1.15.2 .deb pair from stage [2c/9]/lib/build-rauc.sh)"
    assert_no_root_signing rauc bundle --key=/pki/leaf-signing.key
    "${runtime}" run --rm \
      -e "SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}" \
      -e "RAUC_BUNDLE_MKSQUASHFS_ARGS=${RAUC_BUNDLE_MKSQUASHFS_ARGS:-}" \
      -v "${content}:/bundle:ro" -v "${out_dir}:/out" \
      -v "${RAUC_PKI_DIR}:/pki:ro" -v "${RAUC_DEB_DIR}:/rauc-debs:ro" "${image}" \
      bash -euo pipefail -c '
        apt-get update -qq
        apt-get install -y --no-install-recommends /rauc-debs/rauc_*.deb /rauc-debs/rauc-service_*.deb >/dev/null
        extra=()
        [[ -n "${RAUC_BUNDLE_MKSQUASHFS_ARGS:-}" ]] && extra=("--mksquashfs-args=${RAUC_BUNDLE_MKSQUASHFS_ARGS}")
        rauc bundle --cert=/pki/leaf-signing.pem --key=/pki/leaf-signing.key \
          --intermediate=/pki/chain.pem "${extra[@]}" /bundle "/out/$1"
        rauc info -C keyring:check-purpose=codesign \
          --keyring=/pki/root-ca.pem "/out/$1"
      ' _ "$(basename "${out}")"
  else
    require_cmd rauc
    local -a sign_cmd=(rauc bundle --cert="${RAUC_LEAF_CERT}" \
      --key="${RAUC_LEAF_KEY}" --intermediate="${RAUC_CHAIN}" \
      "${mksquashfs_opt[@]}" "${content}" "${out}")
    assert_no_root_signing "${sign_cmd[@]}"
    "${sign_cmd[@]}"
    rauc info "${RAUC_VERIFY_OPTS[@]}" --keyring="${RAUC_ROOT_CA}" "${out}"
  fi
}

build-bundle() {
  [[ $# -eq 2 ]] || { usage; die "expected exactly 2 args, got $#"; }
  local board="$1" rootfs_tree="$2" compatible version ts out_dir out content
  [[ -n "${board}" && -d "${rootfs_tree}" ]] \
    || die "board and a rootfs directory are required (tar/plain input is not an ext4 slot image)"
  assert_pki
  compatible="${COMPATIBLE_STRING:-}"
  [[ -n "${compatible}" ]] || die "COMPATIBLE_STRING is unset/empty — refusing a bundle the device would reject"
  version="${BUNDLE_VERSION:-}"
  if [[ -z "${version}" ]]; then
    version="$(GIT_MASTER=1 git -C "${PIPELINE_DIR}" rev-parse --short HEAD 2>/dev/null)" || version=""
  fi
  ts="${BUNDLE_TS:-$(date -u +%Y%m%dT%H%M%SZ)}"
  [[ -n "${version}" ]] || version="${ts}"
  out_dir="${BUNDLE_OUT_DIR:-${IMAGES_DIR}/${board}/bundles}"
  mkdir -p "${out_dir}"
  content="$(mktemp -d "${out_dir}/.bundle-content.XXXXXX")"
  trap 'rm -rf "${content}"' RETURN
  out="${out_dir}/${ts}.raucb"
  SLOT_IMAGE_LABEL=rootfs make_slot_image "${rootfs_tree}" "${content}/rootfs.ext4" \
    || die "failed to make 4096 MiB ext4 rootfs slot image"
  write_manifest "${content}/manifest.raucm" "${compatible}" "${version}"
  bundle_with_rauc "${content}" "${out}"
  ( cd "${out_dir}" && sha256sum "$(basename "${out}")" >"$(basename "${out}").sha256" )
  log_success "verity adaptive bundle: ${out}"
  printf '%s\n' "${out}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    -h | --help | "") usage; exit 0 ;;
    *) build-bundle "$@" ;;
  esac
fi
