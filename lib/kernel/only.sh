#!/usr/bin/env bash
# Kernel-only orchestration. Sourced by lib/orchestrate.sh.
# shellcheck disable=SC2154

kernel_family_boards() {
  python3 - "${PIPELINE_DIR}/manifests/boards" "$1" <<'PY'
import pathlib
import sys
import yaml
boards = [p.stem for p in sorted(pathlib.Path(sys.argv[1]).glob('*.yaml'))
          if yaml.safe_load(p.read_text()).get('family') == sys.argv[2]]
if not boards:
    sys.exit('family has no board manifests: ' + sys.argv[2])
print('\n'.join(boards))
PY
}

kernel_only_firmware() (
  local dest="$1"
  # Use the image's signed BSP transports, exact keyring and content-pin gates,
  # but fetch only firmware, never first-party, U-Boot or userspace packages.
  source "${PIPELINE_DIR}/lib/fetch-debs.sh"
  DRY_RUN=""
  local pin="${HERE}/../manifests/armbian-firmware-content.json" record pkg version
  record="$(firmware_content_read "${pin}")"
  IFS=$'\t' read -r pkg version _ <<<"${record}"
  [[ -s "${ARMBIAN_APT_KEYRING}" ]] || die "ARMBIAN_APT_KEYRING is required for authenticated firmware fetch"
  auth_keyring_has_exact_fingerprints "${ARMBIAN_APT_KEYRING}" "${ARMBIAN_APT_KEY_FINGERPRINTS[@]}" \
    || die "firmware keyring primary fingerprints differ"
  mkdir -p "${dest}/debs"
  if command -v apt-get >/dev/null 2>&1; then
    _fetch_bsp_native "${dest}/debs" "${pkg}=${version}"
  else
    _fetch_bsp_curl "${dest}/debs" "${pkg}=${version}"
  fi
  local -a debs=("${dest}/debs/"*.deb)
  (( ${#debs[@]} == 1 )) || die "expected one pinned firmware archive"
  firmware_content_assert_archive "${pin}" "${debs[0]}" || die "firmware archive differs from content pin"
  dpkg-deb -x "${debs[0]}" "${dest}/root"
)

# Gate independently callable against an existing artifact directory; callers
# supply private scratch storage. Each board gets a fresh extraction (DTB prune).
kernel_only_gate() {
  local built="$1" firmware="$2" scratch="$3" family="$4" variant="$5"
  local boards board params release package version arch dtb src dst suffix root
  boards="$(kernel_family_boards "${family}")" || return 1
  local -a debs=("${built}/"*.deb) validated=()
  (( ${#debs[@]} == 1 )) || { log_error "expected one kernel deb"; return 1; }
  for board in ${boards}; do
    params="$("${RESOLVE_SH}" "${board}" --variant "${variant}")" || return 1
    # Isolate board-specific values; no per-board field is artifact identity.
    (
      eval "${params}" || exit 1
      release="${KERNEL_SOURCE_KERNEL_RELEASE}"
      package="${KERNEL_PACKAGES}"
      version="${KERNEL_SOURCE_PACKAGE_VERSION}"
      arch="${ARCH}"
      dtb="${DTB_NAME}"
      src="${KERNEL_SOURCE_DTB_DEB_DIR}"
      dst="${KERNEL_SOURCE_DTB_BOOT_DIR}"
      [[ "${release}" =~ ^[0-9]+[.][0-9]+[.][0-9]+(-[a-zA-Z0-9-]+)$ ]] || exit 1
      suffix="${BASH_REMATCH[1]}"
      # This is the same four-axis gate as compilation and cache restoration.
      source "${PIPELINE_DIR}/lib/kernel/package.sh" || exit 1
      validate_built_kernel_deb "${debs[0]}" "${package}" "${version}" "${arch}" "${src}/${dtb}" || exit 1
      root="${scratch}/${board}"
      mkdir -p "${root}/usr/lib/ceralive" || exit 1
      dpkg-deb -x "${debs[0]}" "${root}" || exit 1
      printf '{\n "dtb_name": "%s",\n "dtb_deb_dir_template": "%s",\n "dtb_boot_dir": "%s",\n "kernel_package_regex": "^linux-image-[0-9]+[.][0-9]+[.][0-9]+%s$"\n}\n' \
        "${dtb}" "${src//"${release}"/\{kernel_release\}}" "${dst}" "${suffix}" \
        >"${root}/usr/lib/ceralive/board-boot.json" || exit 1
      install -m 0644 "${PIPELINE_DIR}/mkosi/customize/bluetooth-firmware.sh" \
        "${root}/usr/lib/ceralive/kernel-firmware-rules.sh" || exit 1
      install -m 0644 "${PIPELINE_DIR}/manifests/rk3588-bluetooth-firmware-roots.txt" \
        "${root}/usr/lib/ceralive/kernel-firmware-rules.txt" || exit 1
      bash "${PIPELINE_DIR}/mkosi/runtime/ceralive-kernel-boot-staging.sh" \
        "${root}" --kernel-release "${release}" --no-initrd || exit 1
      bash "${VERIFY_BOOT_ARTIFACTS_SH}" --root-dir "${root}" --dtb-name "${dtb}" --skip-initrd || exit 1
      bash "${PIPELINE_DIR}/mkosi/runtime/ceralive-kernel-boot-staging.sh" firmware-check \
        "${root}" --kernel-release "${release}" --firmware-root "${firmware}"
    ) || return 1
    validated+=("${board}")
  done
  python3 - "${built}/kernel-artifact.json" "${debs[0]}" "${validated[@]}" <<'PY'
import hashlib
import json
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
record = json.loads(path.read_text())
if record['deb_sha256'] != hashlib.sha256(pathlib.Path(sys.argv[2]).read_bytes()).hexdigest():
    sys.exit('kernel artifact digest disagrees with gated bytes')
record['validated_boards'] = sys.argv[3:]
path.write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
PY
}

stage_kernel_only() (
  [[ "${kernel_from_source}" == 1 ]] || die "--kernel-only requires a source-built kernel family"
  local out="${MKOSI_DIR}/build/kernel-only/${FAMILY}" work pending=""
  log_info "[2b/9] building family kernel '${FAMILY}' from pinned source -> ${out}"
  if [[ "${DRY_RUN:-0}" == 1 ]]; then
    "${BUILD_KERNEL_SH}" --board "${board}" --out "${out}"
    log_info "DRY-RUN family gate: every ${FAMILY} board; boot staging --no-initrd, boot verifier --skip-initrd, pinned-archive firmware-check"
    return 0
  fi
  work="$(mktemp -d)"
  trap 'if [[ -d "${work}/previous" && ! -e "${out}" ]]; then mv "${work}/previous" "${out}"; fi; [[ -z "${pending}" ]] || rm -rf "${pending}"; rm -rf "${work}"' EXIT
  mkdir -p "${work}/built"
  "${BUILD_KERNEL_SH}" --board "${board}" --out "${work}/built"
  kernel_only_firmware "${work}/firmware"
  local firmware="${work}/firmware/root/usr/lib/firmware"
  [[ -d "${firmware}" ]] || firmware="${work}/firmware/root/lib/firmware"
  kernel_only_gate "${work}/built" "${firmware}" "${work}/scratch" "${FAMILY}" "${variant}"
  [[ -s "${work}/built/resolved.config" && -s "${work}/built/built-modules.txt" ]] \
    || die "kernel metadata outputs are absent"
  (cd "${work}/built"; sha256sum ./*.deb resolved.config built-modules.txt kernel-artifact.json >SHA256SUMS)
  # Prepare on the output filesystem, then publish only the complete gated set.
  mkdir -p "$(dirname "${out}")"
  pending="$(mktemp -d "$(dirname "${out}")/.${FAMILY}.XXXXXXXX")"
  cp -a "${work}/built/." "${pending}/"
  if [[ -d "${out}" ]]; then mv "${out}" "${work}/previous"; fi
  mv "${pending}" "${out}"
  log_success "kernel-only complete: ${out}"
)
