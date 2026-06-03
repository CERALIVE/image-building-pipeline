#!/usr/bin/env bash
#
# install-boot.sh — build-time installer for the CeraLive A/B bootloader
# integration (RAUC bootloader=custom on the RK3588 vendor U-Boot; decision D3).
#
# Board specifics are NEVER hardcoded: they arrive as environment variables that
# the orchestrator (lib/orchestrate.sh) resolves from the board+family manifest
# (lib/resolve.sh) and forwards via mkosi `--environment`:
#   SERIAL_CONSOLE   family manifest  serial_console  (e.g. ttyS2:1500000)
#   DTB_NAME         board  manifest  dtb_name        (e.g. rk3588-rock-5b-plus.dtb)
#   BOARD_ID         board  manifest  board_id        (e.g. rock-5b-plus)
#   FAMILY           board  manifest  family          (e.g. rk3588) -> RAUC compatible
#   SINGLE_SLOT_FALLBACK  board manifest single_slot_fallback (true|false)
#
# TWO install targets, because the bits live in two places and need different
# tooling (see v2/mkosi/platform/boot/README.md):
#
#   rootfs <chroot=/>      USERSPACE bits into the rootfs slot. NO mkimage needed:
#                          - /usr/bin/ceralive-boot-state               (state helper)
#                          - /usr/lib/rauc/ceralive-rauc-boot-adapter   (RAUC backend)
#                          - /etc/rauc/system.conf                      (bootloader=custom)
#                          Invoked from platform/mkosi.finalize via mkosi-chroot.
#
#   boot-partition <dir>   FAT BOOT PARTITION bits into <dir> (the mounted p1 boot).
#                          NEEDS mkimage (u-boot-tools) — a HOST tool here:
#                          - boot.scr        (compiled from boot.scr.cmd)
#                          - cera_board.env  (rendered console/fdtfile/board_id)
#                          - boot_state.txt  (initial A/B state seed)
#                          - extlinux/extlinux.conf (manual recovery menu)
#                          Invoked by the disk assembler / the offline test.
#
# Self-contained: the rootfs path runs INSIDE the image (mkosi-chroot) where the
# repo's lib/common.sh is absent, so this script carries its own helpers. Strict,
# no `|| true` swallowing.
#
# shellcheck shell=bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '[install-boot] %s\n' "$*" >&2; }
die()  { printf '[install-boot] ERROR: %s\n' "$*" >&2; exit 1; }

# Board specifics from the environment (manifest-resolved). Empty = hard error for
# the values the boot path genuinely needs; we refuse to ship a half-board image.
BOARD_ID="${BOARD_ID:-}"
DTB_NAME="${DTB_NAME:-}"
SERIAL_CONSOLE="${SERIAL_CONSOLE:-}"
FAMILY="${FAMILY:-}"
SINGLE_SLOT_FALLBACK="${SINGLE_SLOT_FALLBACK:-false}"
BOOT_ATTEMPTS="${CERALIVE_BOOT_ATTEMPTS:-3}"

# RAUC system compatible string — board-aware, NOT hardcoded per board. Honors
# COMPATIBLE_STRING (the orchestrator-forwarded knob shared with the runtime
# fallback, task 26), then the legacy RAUC_COMPATIBLE, then the family default.
# Whatever wins MUST equal the compatible baked into the signed bundle.
COMPATIBLE="${COMPATIBLE_STRING:-${RAUC_COMPATIBLE:-ceralive-${FAMILY:-unknown}}}"

# console= value for kernel/U-Boot: the manifest uses `ttyS2:1500000`; the kernel
# console form is `ttyS2,1500000`. Rewrite the ':' separator to ','.
console_value() {
  [[ -n "${SERIAL_CONSOLE}" ]] || die "SERIAL_CONSOLE is empty (manifest serial_console) — cannot render boot console"
  printf '%s' "${SERIAL_CONSOLE/:/,}"
}

# render <template> <dest> — substitute @CONSOLE@/@DTB_NAME@/@BOARD_ID@ placeholders.
render() {
  local tmpl="$1" dest="$2" console; console="$(console_value)"
  [[ -f "${tmpl}" ]] || die "template not found: ${tmpl}"
  sed -e "s|@CONSOLE@|${console}|g" \
      -e "s|@DTB_NAME@|${DTB_NAME}|g" \
      -e "s|@BOARD_ID@|${BOARD_ID}|g" \
      "${tmpl}" >"${dest}"
}

# render_env <template> <dest> — like render, but DROP comment + blank lines so the
# result is pure KEY=value. cera_board.env is imported by U-Boot `env import -t`,
# which has no comment syntax and would turn a stray `# ...` line into junk vars.
render_env() {
  local tmpl="$1" dest="$2"
  render "${tmpl}" "${dest}.raw"
  grep -vE '^[[:space:]]*(#|$)' "${dest}.raw" >"${dest}"
  rm -f "${dest}.raw"
}

# ---------------------------------------------------------------------------
# rootfs — install the userspace bits into the image (chroot). No mkimage here.
# ROOT (default empty = the chroot's /) optionally prefixes every install path so
# the same installer can populate a staging dir for tests/evidence without root.
# ---------------------------------------------------------------------------
install_rootfs() {
  local root="${ROOT:-}"
  log "installing RAUC custom bootloader backend + state helper into the rootfs${root:+ (ROOT=${root})}"

  install -D -m 0755 "${SCRIPT_DIR}/ceralive-boot-state.sh"          "${root}/usr/bin/ceralive-boot-state"
  install -D -m 0755 "${SCRIPT_DIR}/ceralive-rauc-boot-adapter.sh"   "${root}/usr/lib/rauc/ceralive-rauc-boot-adapter"

  # RAUC system.conf — bootloader=custom wired to our backend. Slots referenced by
  # PARTLABEL (frozen contract: never FS-UUID). The B slot is omitted for
  # single-slot media (contract §4) so RAUC never targets a non-existent partition.
  log "writing ${root}/etc/rauc/system.conf (bootloader=custom, compatible=${COMPATIBLE}, single_slot=${SINGLE_SLOT_FALLBACK})"
  mkdir -p "${root}/etc/rauc"
  {
    cat <<EOF
[system]
compatible=${COMPATIBLE}
bootloader=custom
# Boot attempts per slot before the custom backend / boot.scr declare a slot bad
# and roll back. Mirrors CERALIVE_BOOT_ATTEMPTS used by ceralive-boot-state.
boot-attempts=${BOOT_ATTEMPTS}

[handlers]
# RAUC bootloader=custom delegates every boot-state op to this script
# (get-primary / set-primary / get-state / set-state). It keeps BOOT_ORDER +
# per-slot attempt counters in a text file on the FAT boot partition, because the
# vendor U-Boot 2017.09 has no working fw_setenv (decision D3).
bootloader-custom-backend=/usr/lib/rauc/ceralive-rauc-boot-adapter

[keyring]
path=/etc/rauc/ceralive-keyring.pem

[slot.rootfs.0]
device=/dev/disk/by-partlabel/rootfs_a
type=ext4
bootname=A
EOF
    if [[ "${SINGLE_SLOT_FALLBACK}" != "true" ]]; then
      cat <<EOF

[slot.rootfs.1]
device=/dev/disk/by-partlabel/rootfs_b
type=ext4
bootname=B
EOF
    fi
  } >"${root}/etc/rauc/system.conf"
  chmod 0644 "${root}/etc/rauc/system.conf"

  log "rootfs bootloader integration installed"
}

# ---------------------------------------------------------------------------
# boot-partition <dir> — render+compile the FAT-boot-partition artifacts into <dir>.
# Needs mkimage (u-boot-tools) to compile boot.scr; if absent, we copy the .cmd
# source and FAIL unless --allow-uncompiled is given (the device needs boot.scr).
# ---------------------------------------------------------------------------
install_boot_partition() {
  local dest="" allow_uncompiled="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --allow-uncompiled) allow_uncompiled="true"; shift ;;
      *)
        [[ -z "${dest}" ]] || die "boot-partition: unexpected arg '$1'"
        dest="$1"; shift
        ;;
    esac
  done
  [[ -n "${dest}" ]] || die "boot-partition: destination dir is required"
  [[ -n "${DTB_NAME}" ]] || die "DTB_NAME is empty (manifest dtb_name) — cannot render boot config"
  mkdir -p "${dest}"

  log "rendering board env (console=$(console_value) fdtfile=${DTB_NAME} board_id=${BOARD_ID})"
  render_env "${SCRIPT_DIR}/cera_board.env.tmpl" "${dest}/cera_board.env"

  log "seeding boot_state.txt (single_slot=${SINGLE_SLOT_FALLBACK}, attempts=${BOOT_ATTEMPTS})"
  if [[ "${SINGLE_SLOT_FALLBACK}" == "true" ]]; then
    CERALIVE_BOOT_STATE_FILE="${dest}/boot_state.txt" CERALIVE_BOOT_ATTEMPTS="${BOOT_ATTEMPTS}" \
      bash "${SCRIPT_DIR}/ceralive-boot-state.sh" init --attempts "${BOOT_ATTEMPTS}" --single-slot
  else
    CERALIVE_BOOT_STATE_FILE="${dest}/boot_state.txt" CERALIVE_BOOT_ATTEMPTS="${BOOT_ATTEMPTS}" \
      bash "${SCRIPT_DIR}/ceralive-boot-state.sh" init --attempts "${BOOT_ATTEMPTS}"
  fi

  log "rendering extlinux/extlinux.conf (manual recovery menu)"
  mkdir -p "${dest}/extlinux"
  render "${SCRIPT_DIR}/extlinux.conf.tmpl" "${dest}/extlinux/extlinux.conf"

  if command -v mkimage >/dev/null 2>&1; then
    log "compiling boot.scr from boot.scr.cmd (mkimage)"
    mkimage -A arm64 -O linux -T script -C none -n "CeraLive A/B selector" \
      -d "${SCRIPT_DIR}/boot.scr.cmd" "${dest}/boot.scr" >&2
  else
    cp -a "${SCRIPT_DIR}/boot.scr.cmd" "${dest}/boot.scr.cmd"
    if [[ "${allow_uncompiled}" == "true" ]]; then
      log "WARN mkimage not found — staged boot.scr.cmd source (compile later); --allow-uncompiled set"
    else
      die "mkimage (u-boot-tools) not found — cannot compile boot.scr. Install u-boot-tools or pass --allow-uncompiled."
    fi
  fi

  log "boot-partition artifacts staged in ${dest}"
}

usage() {
  cat >&2 <<EOF
Usage: install-boot.sh <target> [args]
  rootfs                         install RAUC backend + state helper + system.conf
                                 (run inside the image via mkosi-chroot)
  boot-partition <dir> [--allow-uncompiled]
                                 render boot.scr + cera_board.env + boot_state.txt
                                 + extlinux.conf into <dir> (the FAT boot partition)

Board specifics come from the environment (manifest-resolved):
  SERIAL_CONSOLE DTB_NAME BOARD_ID FAMILY SINGLE_SLOT_FALLBACK
EOF
}

main() {
  local target="${1:-}"; shift || true
  case "${target}" in
    rootfs)          install_rootfs ;;
    boot-partition)  install_boot_partition "$@" ;;
    -h|--help|"")    usage; [[ -n "${target}" ]] ;;
    *) usage; die "unknown target '${target}'" ;;
  esac
}

main "$@"
