#!/usr/bin/env bash
# Explicit signer-free content measurement; never a completed release candidate.
# shellcheck shell=bash
# shellcheck disable=SC2154

rootfs_measurement_preflight() {
  [[ "${CERALIVE_BUILD_MODE}" == production ]] || die "rootfs measurement requires production mode"
  [[ -z "${DRY_RUN:-}" && "${INSTALL_BOOT_BSP}" == 1 &&
      "${CERALIVE_DEBUG_IMAGE:-0}" == 0 && -z "${CERALIVE_DEBUG_PASSWORD_HASH:-}" &&
      "${CERALIVE_BENCH_LABELS:-0}" == 0 && "${MKOSI_NATIVE:-0}" != 1 ]] \
    || die "rootfs measurement requires full shipping content and container assembly"
  [[ "${BSP_DRIFT_STRICT:-1}" == 1 && "${CERALIVE_REQUIRE_KERNEL_APT:-1}" == 1 ]] \
    || die "rootfs measurement refuses provenance or APT kernel opt-outs"
  [[ -z "${CERALIVE_RAUC_PKI_DIR:-}${RAUC_PKI_B64:-}${RAUC_RELEASE_PKI_TAR_B64:-}${APT_CLIENT_CRT_B64:-}${APT_CLIENT_KEY_B64:-}${CERALIVE_FIRST_PARTY_LOCAL_DEBS_DIR:-}" ]] \
    || die "rootfs measurement refuses private signer, direct credentials and local overrides"
  [[ -n "${CERALIVE_SEALED_INPUTS:-}" && "${CERALIVE_SEALED_INPUT_SHA256:-}" =~ ^[0-9a-f]{64}$ &&
      -s "${CERALIVE_SEALED_INPUTS}/inventory.json" && -s "${CERALIVE_SEALED_INPUTS}/trust.json" ]] \
    || die "rootfs measurement requires authenticated sealed inputs"
  rauc_public_root_resolve "${RAUC_KEYRING_FILE:-}" "${CERALIVE_MEASUREMENT_ROOT_SHA256:-}" \
    || die "rootfs measurement public device trust rejected"
  export CERALIVE_REQUIRE_KERNEL_APT=1 BSP_DRIFT_STRICT=1
  export CERALIVE_BUILD_PURPOSE=rootfs-measurement
}

rootfs_measurement_resolved() {
  local shipping_variant
  shipping_variant="$(python3 "${HERE}/resolve.py" get "${family_manifest}" default_variant)" \
    || die "rootfs measurement default kernel variant could not be resolved"
  [[ "${FAMILY}" == rk3588 && "${ARCH}" == arm64 &&
      "${SINGLE_SLOT_FALLBACK:-false}" == false &&
      "${KERNEL_VARIANT:-}" == "${shipping_variant}" ]] \
    || die "rootfs measurement requires the shipping arm64 kernel and both populated RK3588 slots"
  "${CHECK_RELEASE_VARIANT_SH}" --variant "${KERNEL_VARIANT:-${variant}}" \
    || die "rootfs measurement requires the shipping kernel variant"
  python3 - "${HERE}" "${CERALIVE_SEALED_INPUTS}" "${KERNEL_PACKAGES}" \
    "${KERNEL_SOURCE_PACKAGE_VERSION:?}" "${board}" <<'PY' \
    || die "rootfs measurement manifest differs from the approved released kernel"
import hashlib, json, pathlib, sys

lib, directory, package, version, board = sys.argv[1:]
sys.path.insert(0, lib)
from kernel_release import SHA256, KernelReleaseError, artifact

try:
    directory = pathlib.Path(directory)
    digest = json.loads((directory / "trust.json").read_text())["kernel_metadata"]["kernel-artifact.json"]
    if not SHA256.fullmatch(digest):
        sys.exit("invalid approved kernel metadata digest")
    path = directory / digest
    if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
        sys.exit("approved kernel artifact hash mismatch")
    record = artifact(path)
    if (record.identity.package, record.identity.version) != (package, version) or board not in record.boards:
        sys.exit("approved kernel artifact does not match manifest package, version or board")
except (OSError, ValueError, KeyError, TypeError, KernelReleaseError) as error:
    sys.exit(str(error))
PY
}

rootfs_measurement_complete() {
  python3 "${HERE}/rootfs-measurement.py" "${out_dir}/${ts}.measurement.json" \
    "${artifact}" "${out_dir}/${ts}.packages.lock.json" "${CERALIVE_RETAIN_SLOT_DIR}" \
    || die "rootfs measurement completion receipt failed"
  log_success "=== rootfs measurement complete: board='${board}' (unsigned content; no release candidate) ==="
}
