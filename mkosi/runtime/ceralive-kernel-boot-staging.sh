#!/usr/bin/env bash
# Shared build/device boot mapping. Sourcing defines the original function API.
# CLI: <rootdir> --kernel-release R [--no-initrd]
#      firmware-refs <rootdir> --kernel-release R

prune_dtb_dir() {
  local dir="$1" label="$2" board_dtb="$3"
  [[ -d "${dir}" ]] || { log "FATAL: cannot prune ${label}: ${dir} is not a directory"; exit 1; }
  [[ -n "${board_dtb}" ]] || { log "FATAL: cannot prune ${label}: no board DTB name resolved"; exit 1; }

  local -a keep=("${board_dtb}")
  local -a overlays=()
  read -r -a overlays <<<"${CERALIVE_DTB_KEEP_OVERLAYS:-}"
  keep+=(${overlays[@]+"${overlays[@]}"})

  local rel
  for rel in "${keep[@]}"; do
    [[ -f "${dir}/${rel}" ]] \
      || { log "FATAL: ${label}: required device-tree file '${rel}' is absent from ${dir} — refusing to prune"; exit 1; }
  done

  local keep_list; keep_list="$(printf '%s\n' "${keep[@]}")"
  local removed=0 path
  while IFS= read -r -d '' path; do
    rel="${path#"${dir}/"}"
    grep -qxF -- "${rel}" <<<"${keep_list}" && continue
    rm -f "${path}"
    removed=$(( removed + 1 ))
  done < <(find "${dir}" -type f -print0)

  find "${dir}" -mindepth 1 -type d -empty -delete

  for rel in "${keep[@]}"; do
    [[ -f "${dir}/${rel}" ]] \
      || { log "FATAL: ${label}: '${rel}' did not survive the prune of ${dir}"; exit 1; }
  done
  log "${label}: kept ${#keep[@]} device-tree file(s) in ${dir}, removed ${removed}"
}

install_kernel_source_dtbs() {
  local root="${BUILDROOT:?BUILDROOT is required by mkosi postinstall}"
  local src="${KERNEL_SOURCE_DTB_DEB_DIR:-}"
  local dst="${KERNEL_SOURCE_DTB_BOOT_DIR:-}"

  if [[ -z "${src}" && -z "${dst}" ]]; then
    return 0
  fi
  if [[ -z "${src}" || -z "${dst}" ]]; then
    log "FATAL: kernel_source DTB mapping is half-specified (deb_dir='${src}' boot_dir='${dst}')"
    exit 1
  fi

  if [[ ! -d "${root}${src}" ]]; then
    log "FATAL: kernel_source.dtb_deb_dir ${src} is absent from the installed kernel package"
    exit 1
  fi

  log "installing source-built kernel DTBs: ${src} -> ${dst}"
  install -d -m 0755 "${root}${dst}"
  cp -a "${root}${src}/." "${root}${dst}/"

  if [[ -n "${DTB_NAME:-}" && ! -e "${root}${dst}/${DTB_NAME}" ]]; then
    log "FATAL: board DTB ${DTB_NAME} is not present at ${dst} after the copy"
    exit 1
  fi
  log "board DTB present at ${dst}/${DTB_NAME:-<unset>}"

  # BOTH installed locations, not just /boot: the package-payload directory stays
  # in the rootfs after installation, so trimming only the boot copy would leave
  # the full 228-blob set shipping inside every slot anyway.
  prune_dtb_dir "${root}${src}" "kernel-package DTB payload" "${DTB_NAME:-}"
  prune_dtb_dir "${root}${dst}" "/boot device trees" "${DTB_NAME:-}"
}

install_kernel_source_boot_artifacts() {
  local root="${BUILDROOT:?BUILDROOT is required by mkosi postinstall}"
  local release="${KERNEL_SOURCE_KERNEL_RELEASE:-}"

  [[ -n "${release}" ]] || return 0

  local vmlinuz="${root}/boot/vmlinuz-${release}"
  if [[ ! -f "${vmlinuz}" ]]; then
    log "FATAL: /boot/vmlinuz-${release} is absent after installing the source-built kernel"
    exit 1
  fi

  # Existence was not enough either. arm64 defaults KBUILD_IMAGE to
  # arch/arm64/boot/Image.gz, and bindeb-pkg ships exactly that as vmlinuz-<REL>,
  # so the symlink pointed at GZIP. Armbian's own prebuilt package did not have the
  # problem because its framework builds with KERNEL_IMAGE_TYPE=Image.
  #
  # Whether a gzip Image boots is then a per-board U-Boot fact, and the two shipped
  # boards answer differently: rock-5b-plus ships U-Boot 2026.04 (CONFIG_GZIP=y,
  # CONFIG_CMD_UNZIP=y) and booted it fine; orange-pi-5-plus ships the Rockchip
  # 2017.09 fork, whose config has no CONFIG_GZIP symbol at all, and it answered
  # `Bad Linux ARM64 Image magic!` and abandoned the slot. Inheriting a board
  # capability is the same mistake the undefined `loadaddr` already cost a board,
  # so the raw Image is produced HERE, once, for every board.
  local head_hex
  head_hex="$(od -An -tx1 -j0 -N6 -v "${vmlinuz}" | tr -d ' \n')"
  local image="${root}/boot/Image"
  rm -f "${image}"

  case "${head_hex}" in
    1f8b*)
      log "vmlinuz-${release} is gzip (Image.gz) — decompressing into a real /boot/Image"
      if ! gzip -dc "${vmlinuz}" >"${image}"; then
        log "FATAL: could not decompress /boot/vmlinuz-${release} into /boot/Image"
        exit 1
      fi
      chmod 0644 "${image}"
      ;;
    fd377a585a00*) log "FATAL: /boot/vmlinuz-${release} is xz-compressed"          ; exit 1 ;;
    28b52ffd*)     log "FATAL: /boot/vmlinuz-${release} is zstd-compressed"        ; exit 1 ;;
    425a68*)       log "FATAL: /boot/vmlinuz-${release} is bzip2-compressed"       ; exit 1 ;;
    04224d18*|02214c18*) log "FATAL: /boot/vmlinuz-${release} is lz4-compressed"   ; exit 1 ;;
    894c5a4f*)     log "FATAL: /boot/vmlinuz-${release} is lzop-compressed"        ; exit 1 ;;
    5d0000*)       log "FATAL: /boot/vmlinuz-${release} is lzma-compressed"        ; exit 1 ;;
    *)
      log "linking /boot/Image -> vmlinuz-${release} (prebuilt linux-image postinst parity)"
      ln -sfn "vmlinuz-${release}" "${image}"
      ;;
  esac

  # The one property booti actually reads: magic 0x644d5241 ("ARM\x64",
  # little-endian) at offset 56 of the 64-byte header
  # (Documentation/arm64/booting.rst §4). Asserted on whatever the branches above
  # produced, because a decompression that SUCCEEDS on the wrong payload is still
  # an unbootable slot.
  if [[ "$(od -An -tx1 -j56 -N4 -v "${image}" | tr -d ' \n')" != "41524d64" ]]; then
    log "FATAL: /boot/Image carries no raw ARM64 Image magic at offset 56"
    log "       booti would answer 'Bad Linux ARM64 Image magic!' and abandon the slot."
    exit 1
  fi

  # Armbian's postinst touches this; nand-sata-install and armbian-config both
  # probe for it, so a source-built rootfs that omits it looks unmanaged.
  : >"${root}/boot/.next"

  [[ "${KERNEL_BOOT_NO_INITRD:-0}" == 1 ]] && return 0

  local initrd="${root}/boot/initrd.img-${release}"
  if [[ ! -f "${initrd}" ]]; then
    log "FATAL: /boot/initrd.img-${release} was not generated"
    log "       initramfs-tools must be installed BEFORE the kernel package so its"
    log "       /etc/kernel/postinst.d hook exists when the kernel postinst run-parts."
    exit 1
  fi

  log "boot artifacts complete: raw ARM64 /boot/Image, initrd.img-${release}"
}

installed_module_firmware_refs() {
  local root="$1"
  # merged-usr makes /lib/modules a symlink, which `find` will not descend, so
  # the real directory is tried first.
  local moddir="${root}/usr/lib/modules"
  [[ -d "${moddir}" ]] || moddir="${root}/lib/modules"
  if [[ -n "${2:-}" ]]; then moddir+="/$2"; fi
  [[ -d "${moddir}" ]] || return 0

  local -a mods=()
  mapfile -d '' -t mods < <(find "${moddir}" -type f \
    \( -name '*.ko' -o -name '*.ko.xz' -o -name '*.ko.zst' -o -name '*.ko.gz' \) -print0)
  (( ${#mods[@]} > 0 )) || return 0

  # One module at a time, tolerating an individual failure but NOT a total one.
  # Batching through xargs made a single unparseable .ko abort the whole
  # postinstall under `set -e`; swallowing every failure instead would be worse,
  # because a modinfo that cannot read anything yields an EMPTY consumer set and
  # would authorise deleting every candidate family. So a run in which no module
  # parsed at all returns non-zero and the caller declines to prune.
  local refs="" out ko
  local -i parsed=0
  for ko in "${mods[@]}"; do
    if out="$(modinfo -F firmware "${ko}" 2>/dev/null)"; then
      parsed+=1
      refs+="${out}"$'\n'
    fi
  done
  (( parsed > 0 )) || return 1

  printf '%s' "${refs}" | sed 's#^/*##' | awk 'NF' | sort -u
}

kernel_boot_staging_main() {
  local mode=stage
  if [[ "${1:-}" == firmware-refs ]]; then mode=firmware-refs; shift; fi
  local BUILDROOT="${1:?root directory required}"
  shift
  local KERNEL_SOURCE_KERNEL_RELEASE="" KERNEL_BOOT_NO_INITRD=0
  while (($#)); do
    case "$1" in
      --kernel-release) KERNEL_SOURCE_KERNEL_RELEASE="${2:?--kernel-release needs a value}"; shift 2 ;;
      --no-initrd) KERNEL_BOOT_NO_INITRD=1; shift ;;
      *) log "FATAL: unknown option: $1"; return 1 ;;
    esac
  done
  [[ -d "${BUILDROOT}" ]] || { log "FATAL: root directory is absent: ${BUILDROOT}"; return 1; }
  [[ "${KERNEL_SOURCE_KERNEL_RELEASE}" =~ ^[0-9]+[.][0-9]+[.][0-9]+-[a-zA-Z0-9.+-]+$ ]] \
    || { log "FATAL: invalid --kernel-release: ${KERNEL_SOURCE_KERNEL_RELEASE}"; return 1; }
  local board="${BUILDROOT}/usr/lib/ceralive/board-boot.json"
  [[ -r "${board}" ]] || { log "FATAL: missing board-boot.json: ${board}"; return 1; }
  local DTB_NAME KERNEL_SOURCE_DTB_DEB_DIR KERNEL_SOURCE_DTB_BOOT_DIR kernel_package_regex
  # Same flat-string convention as slot-sync's image-owned healthy-state.json.
  # The platform writes constrained paths/names and a regex without JSON escapes.
  DTB_NAME="$(sed -n 's/.*"dtb_name"[[:space:]]*:[[:space:]]*"\([^"\\]*\)".*/\1/p' "${board}")"
  KERNEL_SOURCE_DTB_DEB_DIR="$(sed -n 's/.*"dtb_deb_dir_template"[[:space:]]*:[[:space:]]*"\([^"\\]*\)".*/\1/p' "${board}")"
  KERNEL_SOURCE_DTB_BOOT_DIR="$(sed -n 's/.*"dtb_boot_dir"[[:space:]]*:[[:space:]]*"\([^"\\]*\)".*/\1/p' "${board}")"
  kernel_package_regex="$(sed -n 's/.*"kernel_package_regex"[[:space:]]*:[[:space:]]*"\([^"\\]*\)".*/\1/p' "${board}")"
  [[ "${DTB_NAME}" =~ ^[a-zA-Z0-9_-]+[.]dtb$ && "${kernel_package_regex}" == ^*\$ ]] \
    || { log "FATAL: invalid board-boot.json identity"; return 1; }
  [[ "linux-image-${KERNEL_SOURCE_KERNEL_RELEASE}" =~ ${kernel_package_regex} ]] \
    || { log "FATAL: --kernel-release does not match board kernel_package_regex"; return 1; }
  [[ "${KERNEL_SOURCE_DTB_DEB_DIR}" == *'{kernel_release}'* ]] \
    || { log "FATAL: board-boot.json lacks {kernel_release} in DTB template"; return 1; }
  KERNEL_SOURCE_DTB_DEB_DIR="${KERNEL_SOURCE_DTB_DEB_DIR//\{kernel_release\}/${KERNEL_SOURCE_KERNEL_RELEASE}}"
  local path
  for path in "${KERNEL_SOURCE_DTB_DEB_DIR}" "${KERNEL_SOURCE_DTB_BOOT_DIR}"; do
    [[ "${path}" =~ ^/[a-zA-Z0-9_./+-]+$ && "/${path}/" != *'/../'* && "/${path}/" != *'/./'* ]] \
      || { log "FATAL: invalid board-boot.json DTB path: ${path}"; return 1; }
  done
  [[ -f "${BUILDROOT}/boot/vmlinuz-${KERNEL_SOURCE_KERNEL_RELEASE}" ]] \
    || { log "FATAL: /boot/vmlinuz-${KERNEL_SOURCE_KERNEL_RELEASE} is absent"; return 1; }
  if [[ "${mode}" == firmware-refs ]]; then
    installed_module_firmware_refs "${BUILDROOT}" "${KERNEL_SOURCE_KERNEL_RELEASE}"
  else
    install_kernel_source_dtbs
    install_kernel_source_boot_artifacts
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  log() { printf '[kernel-boot-staging] %s\n' "$*" >&2; }
  kernel_boot_staging_main "$@"
fi
