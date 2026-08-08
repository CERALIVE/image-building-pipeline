#!/usr/bin/env bash
#
# verify-boot-artifacts.sh — assert a built rootfs carries everything the U-Boot
# A/B selector loads, for EITHER kernel path.
#
# The selector (mkosi/platform/boot/boot.scr.cmd) does exactly three loads:
#
#   ext4load … /boot/Image                          (fatal)
#   ext4load … /boot/dtb/<subdir>/${fdtfile}        (fatal)
#   ext4load … /boot/initrd.img                     (optional — see below)
#
# Those artifacts arrive by DIFFERENT mechanisms per kernel path, which is how one
# path can be complete while the other is silently broken:
#
#   vendor  — Armbian's linux-image-* postinst symlinks Image and Depends: on
#             initramfs-tools (whose /etc/kernel/postinst.d hook writes the initrd);
#             linux-dtb-* symlinks /boot/dtb -> dtb-<release>/.
#   source  — `make bindeb-pkg` does none of that; the platform layer has to.
#
# So this verifier is deliberately LAYOUT-AGNOSTIC: it checks what U-Boot can
# actually load, not which mechanism produced it. /boot/Image may be a symlink or a
# real file; /boot/dtb may be a symlink to dtb-<release>/ or a real directory.
#
# The initrd is NOT fatal to U-Boot (the vendor package ships only the versioned
# name, so the bare-name load legitimately fails and the board boots root=PARTLABEL
# directly), but a rootfs with NO initrd at all means the initramfs hook never ran —
# which on the source path is the same broken-packaging signal as a missing Image.
# So a versioned initrd IS required here.
#
# Input is the normalized rootfs tar the build already emits, so this needs no root,
# no loop device and no filesystem tooling, and runs identically in CI.
#
# Usage: verify-boot-artifacts.sh <rootfs.tar> --dtb-name <name.dtb> [--dtb-subdir <dir>]

set -euo pipefail

PROG="$(basename "${BASH_SOURCE[0]}")"
log() { printf '[%s] %s\n' "${PROG}" "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

TAR=""
DTB_NAME=""
DTB_SUBDIR="rockchip"
MIN_KERNEL_BYTES=$((4 * 1024 * 1024))
MIN_INITRD_BYTES=$((256 * 1024))
MIN_DTB_BYTES=4096

while (($#)); do
  case "$1" in
    --dtb-name)   DTB_NAME="${2:?--dtb-name needs a value}"; shift 2 ;;
    --dtb-subdir) DTB_SUBDIR="${2:?--dtb-subdir needs a value}"; shift 2 ;;
    -h|--help)    sed -n '2,32p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*)           die "unknown option: $1" ;;
    *)            TAR="$1"; shift ;;
  esac
done

[[ -n "${TAR}" ]]      || die "usage: ${PROG} <rootfs.tar> --dtb-name <name.dtb>"
[[ -f "${TAR}" ]]      || die "rootfs tar not found: ${TAR}"
[[ -n "${DTB_NAME}" ]] || die "--dtb-name is required (the board manifest's dtb_name)"

# ---------------------------------------------------------------------------
# Index the tar once. `tar -tv` gives type, size and symlink target in one pass,
# which is all the resolution below needs — no extraction, no second scan.
# ---------------------------------------------------------------------------
declare -A TYPE=() SIZE=() LINK=()

# `tar -tv` columns are: mode owner/group size date time name[ -> target].
# Parsed with a 6-field `read` (the name, which may contain spaces, lands whole in
# the last field) — no subprocess per entry, because a real rootfs tar has ~100k of
# them and an awk fork each would take minutes.
index_tar() {
  local mode size name target
  while read -r mode _ size _ _ name; do
    [[ -n "${name}" ]] || continue
    target=""
    if [[ "${name}" == *" -> "* ]]; then
      target="${name#* -> }"
      name="${name%% -> *}"
    fi
    name="${name#./}"
    name="${name%/}"
    [[ -n "${name}" ]] || continue
    case "${mode:0:1}" in
      d) TYPE["${name}"]="dir" ;;
      l) TYPE["${name}"]="link"; LINK["${name}"]="${target}" ;;
      -) TYPE["${name}"]="file"; SIZE["${name}"]="${size}" ;;
      *) TYPE["${name}"]="other" ;;
    esac
  done < <(LC_ALL=C tar -tvf "${TAR}")
}

# Resolve one path component at a time, following symlinks the way U-Boot's ext4
# driver does. Relative targets resolve against the link's own directory; that is
# what makes `Image -> vmlinuz-<rel>` and `dtb -> dtb-<rel>` both work.
resolve() {
  local path="$1" depth=0 parts part acc="" target
  while ((depth < 16)); do
    IFS='/' read -r -a parts <<<"${path}"
    acc=""
    for part in "${parts[@]}"; do
      [[ -n "${part}" ]] || continue
      acc="${acc:+${acc}/}${part}"
      if [[ "${TYPE[${acc}]:-}" == "link" ]]; then
        target="${LINK[${acc}]}"
        if [[ "${target}" == /* ]]; then
          path="${target#/}${path#"${acc}"}"
        else
          path="${acc%/*}"
          [[ "${path}" == "${acc}" ]] && path=""
          path="${path:+${path}/}${target}${1#"${acc}"}"
        fi
        set -- "${path}"
        depth=$((depth + 1))
        continue 2
      fi
    done
    printf '%s\n' "${path}"
    return 0
  done
  return 1
}

FAILS=0
ok()   { printf '  ok    %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }

# Name a compression container from its leading bytes, so a rejection says WHICH
# wrong thing was staged instead of only that the magic was wrong.
compression_name() {
  case "$1" in
    1f8b*)         printf 'gzip' ;;
    fd377a585a00*) printf 'xz' ;;
    28b52ffd*)     printf 'zstd' ;;
    425a68*)       printf 'bzip2' ;;
    04224d18*)     printf 'lz4' ;;
    02214c18*)     printf 'lz4 (legacy)' ;;
    894c5a4f*)     printf 'lzop' ;;
    5d0000*)       printf 'lzma' ;;
    *)             return 1 ;;
  esac
}

# Read the first 64 bytes of one tar member. `tar -tv` cannot see content, and
# the member is stored with the `./` prefix the packer used — try both spellings.
# The whole member is extracted to a temp file rather than piped through `head`,
# because closing that pipe kills tar with SIGPIPE and `set -o pipefail` turns a
# correct read into a build failure (this repo has shipped that bug once already).
member_header() {
  local name="$1" tmp
  tmp="$(mktemp)"
  if ! LC_ALL=C tar -xOf "${TAR}" "./${name}" >"${tmp}" 2>/dev/null; then
    LC_ALL=C tar -xOf "${TAR}" "${name}" >"${tmp}" 2>/dev/null || { rm -f "${tmp}"; return 1; }
  fi
  od -An -tx1 -j0 -N64 -v "${tmp}" | tr -d ' \n'
  rm -f "${tmp}"
}

check_kernel() {
  local resolved header magic comp
  if [[ -z "${TYPE[boot/Image]:-}" ]]; then
    bad "/boot/Image is absent — the selector's first load cannot succeed"
    log "  /boot entries present: $(printf '%s ' "${!TYPE[@]}" | tr ' ' '\n' \
      | grep -E '^boot/[^/]+$' | sort | tr '\n' ' ')"
    return
  fi
  resolved="$(resolve boot/Image)" || { bad "/boot/Image symlink loop"; return; }
  if [[ "${TYPE[${resolved}]:-}" != "file" ]]; then
    bad "/boot/Image resolves to '${resolved}', which is not a file in this rootfs"
    return
  fi
  if (( ${SIZE[${resolved}]:-0} < MIN_KERNEL_BYTES )); then
    bad "/boot/Image -> ${resolved} is only ${SIZE[${resolved}]:-0} bytes"
    return
  fi

  # Present, resolvable and big enough still says nothing about whether `booti`
  # can start it. A real Orange Pi 5 Plus loaded all 15,928,530 bytes of this
  # file and answered `Bad Linux ARM64 Image magic!`, because arm64's KBUILD_IMAGE
  # default makes `make bindeb-pkg` ship arch/arm64/boot/Image.GZ as vmlinuz —
  # and that board's U-Boot has no gzip support anywhere in its booti path.
  if ! header="$(member_header "${resolved}")"; then
    bad "/boot/Image -> ${resolved} could not be read out of the tar"
    return
  fi
  # 64-byte ARM64 Image header, Documentation/arm64/booting.rst §4: magic
  # 0x644d5241 ("ARM\x64", little-endian) at offset 56 — hex chars 112..119.
  magic="${header:112:8}"
  if [[ "${magic}" != "41524d64" ]]; then
    if comp="$(compression_name "${header}")"; then
      bad "/boot/Image -> ${resolved} is ${comp}-compressed, not a raw ARM64 Image magic (booti cannot decompress it on every board)"
    else
      bad "/boot/Image -> ${resolved} has no ARM64 Image magic at offset 56 (found 0x${magic:-<short>})"
    fi
    return
  fi

  ok "/boot/Image -> ${resolved} (${SIZE[${resolved}]} bytes, raw ARM64 Image)"
}

check_dtb() {
  local path="boot/dtb/${DTB_SUBDIR}/${DTB_NAME}" resolved
  resolved="$(resolve "${path}")" || { bad "/${path} symlink loop"; return; }
  if [[ "${TYPE[${resolved}]:-}" != "file" ]]; then
    bad "/${path} does not resolve to a file (got '${resolved}')"
    return
  fi
  if (( ${SIZE[${resolved}]:-0} < MIN_DTB_BYTES )); then
    bad "/${path} -> ${resolved} is only ${SIZE[${resolved}]:-0} bytes"
    return
  fi
  ok "/${path} -> ${resolved} (${SIZE[${resolved}]} bytes)"
}

check_initrd() {
  local name best="" best_size=0
  for name in "${!TYPE[@]}"; do
    [[ "${name}" == boot/initrd.img-* ]] || continue
    [[ "${TYPE[${name}]}" == "file" ]]   || continue
    if (( ${SIZE[${name}]:-0} > best_size )); then
      best="${name}"; best_size="${SIZE[${name}]}"
    fi
  done
  if [[ -z "${best}" ]]; then
    bad "no /boot/initrd.img-<release> — the initramfs hook never ran for this kernel"
    return
  fi
  if (( best_size < MIN_INITRD_BYTES )); then
    bad "/${best} is only ${best_size} bytes"
    return
  fi
  ok "/${best} (${best_size} bytes)"
}

log "verifying boot artifacts in ${TAR} (dtb ${DTB_SUBDIR}/${DTB_NAME})"
index_tar
check_kernel
check_dtb
check_initrd

if (( FAILS > 0 )); then
  die "${FAILS} boot artifact check(s) failed — this rootfs would not boot"
fi
log "boot artifacts complete"
