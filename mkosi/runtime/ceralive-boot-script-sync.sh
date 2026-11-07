#!/bin/bash
#
# ceralive-boot-script-sync — replace /boot/boot.scr with the copy shipped in this
# rootfs, once the booted slot is health-confirmed.
#
# WHY: boot.scr lives on the FAT boot partition (p1), written only when a disk image
# is assembled; a RAUC bundle carries a rootfs and never touches it. Without this
# step a fix to the selector reaches only freshly flashed boards. The image build
# compiles boot.scr (mkimage is host-side only) and ships it, with its SHA-256, at
# /usr/lib/ceralive/boot/.
#
# SAFETY: boot.scr is boot-critical and a damaged one leaves U-Boot with no eMMC
# selector. So this runs only after the healthcheck succeeded (unit Requires=), never
# while a kernel activation is armed, and only on a mounted, writable vfat /boot.
# It never creates boot.scr, keeps the previous one as boot.scr.prev, writes the new
# file beside the old one, verifies it by byte comparison, renames it into place and
# verifies again, restoring the previous file if the final check fails.
#
# EQUALITY: mkimage stamps a creation time in the 64-byte legacy uImage header, so two
# compiles of the same selector differ there. Sameness is judged on the bytes after
# the header; a freshly flashed board therefore never rewrites its own boot.scr.
#
# Test seams (production uses every default):
#   CERALIVE_BOOT_SCRIPT_SRC     shipped boot.scr (default /usr/lib/ceralive/boot/boot.scr)
#   CERALIVE_BOOT_SCRIPT_SUMS    its checksum file (default <src>.sha256)
#   CERALIVE_BOOT_DIR            boot partition mount (default /boot)
#   CERALIVE_ACTIVATION_ARMED    pending-activation marker
#   CERALIVE_FINDMNT_BIN         findmnt
#   CERALIVE_BOOT_SCRIPT_CP_BIN  cp used for the new file (default cp)
#   CERALIVE_BOOT_SCRIPT_MV_BIN  mv used for the rename and the restore (default mv)

set -uo pipefail

SRC="${CERALIVE_BOOT_SCRIPT_SRC:-/usr/lib/ceralive/boot/boot.scr}"
SUMS="${CERALIVE_BOOT_SCRIPT_SUMS:-${SRC}.sha256}"
BOOT_DIR="${CERALIVE_BOOT_DIR:-/boot}"
ARMED="${CERALIVE_ACTIVATION_ARMED:-/data/ceralive/update-state/activation-armed}"
FINDMNT_BIN="${CERALIVE_FINDMNT_BIN:-findmnt}"
CP_BIN="${CERALIVE_BOOT_SCRIPT_CP_BIN:-cp}"
MV_BIN="${CERALIVE_BOOT_SCRIPT_MV_BIN:-mv}"
HEADER_BYTES=64

DST="${BOOT_DIR}/boot.scr"
NEW="${BOOT_DIR}/boot.scr.new"
PREV="${BOOT_DIR}/boot.scr.prev"

log() { printf 'ceralive-boot-script-sync: %s\n' "$*"; }
fail() { printf 'ceralive-boot-script-sync: ERROR: %s\n' "$*" >&2; exit 1; }

same_script() { cmp -s -i "${HEADER_BYTES}" -- "$1" "$2"; }

[[ -r "${SRC}" ]] || { log "no shipped boot.scr at ${SRC} — nothing to sync"; exit 0; }

expected="$(awk 'NR == 1 { print $1 }' "${SUMS}" 2>/dev/null)"
actual="$(sha256sum -- "${SRC}" | awk '{ print $1 }')"
[[ -n "${expected}" && "${expected}" == "${actual}" ]] \
  || fail "shipped boot.scr does not match ${SUMS} — refusing to write it"

if [[ -e "${ARMED}" ]]; then
  log "a kernel activation is armed — not touching the boot partition now"
  exit 0
fi

mount_info="$("${FINDMNT_BIN}" -n -o FSTYPE,OPTIONS "${BOOT_DIR}" 2>/dev/null)" \
  || fail "${BOOT_DIR} is not a mount point — refusing to write"
fstype="${mount_info%% *}"
options=",${mount_info#* },"
[[ "${fstype}" == vfat && "${options}" == *,rw,* ]] \
  || fail "${BOOT_DIR} must be a writable vfat mount (found: ${mount_info})"

[[ -f "${DST}" ]] || fail "${DST} is absent — refusing to create a boot selector"

rm -f -- "${NEW}"
if same_script "${SRC}" "${DST}"; then
  log "boot.scr is already current ($(sha256sum -- "${DST}" | cut -c1-12))"
  exit 0
fi

cp -f -- "${DST}" "${PREV}" || fail "cannot keep the previous boot.scr as ${PREV}"
"${CP_BIN}" -f -- "${SRC}" "${NEW}" || { rm -f -- "${NEW}"; fail "cannot write ${NEW}"; }
sync -f -- "${NEW}" 2>/dev/null || sync
if ! cmp -s -- "${SRC}" "${NEW}"; then
  rm -f -- "${NEW}"
  fail "readback of ${NEW} differs from the shipped boot.scr — ${DST} untouched"
fi
"${MV_BIN}" -f -- "${NEW}" "${DST}" || { rm -f -- "${NEW}"; fail "cannot rename ${NEW} over ${DST}"; }
sync -f -- "${DST}" 2>/dev/null || sync

if ! cmp -s -- "${SRC}" "${DST}"; then
  cp -f -- "${PREV}" "${NEW}" && "${MV_BIN}" -f -- "${NEW}" "${DST}" && sync
  fail "readback of ${DST} differs after the rename — restored the previous boot.scr"
fi
log "boot.scr updated to the shipped selector ($(sha256sum -- "${DST}" | cut -c1-12)); previous kept as ${PREV}"
