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
#   COMPATIBLE_STRING  orchestrator   ceralive-<board-slug> (e.g. ceralive-rock-5b-plus)
#   SINGLE_SLOT_FALLBACK  board manifest single_slot_fallback (true|false)
#
# TWO install targets, because the bits live in two places and need different
# tooling (see mkosi/platform/boot/README.md):
#
#   rootfs <chroot=/>      USERSPACE bits into the rootfs slot. NO mkimage needed:
#                          - /usr/bin/ceralive-boot-state               (state helper)
#                          - /usr/lib/ceralive/boot-state-core.sh       (shared A/B core)
#                          - /usr/lib/rauc/ceralive-rauc-boot-adapter   (RAUC backend)
#                          - /etc/rauc/system.conf                      (bootloader=custom)
#                          - /etc/fstab                                 (shared p1 at /boot)
#                          Invoked from platform/mkosi.finalize via mkosi-chroot.
#
#   boot-partition <dir>   FAT BOOT PARTITION bits into <dir> (the mounted p1 boot).
#                          NEEDS mkimage (u-boot-tools) — a HOST tool here:
#                          - boot.scr        (compiled from boot.scr.cmd)
#                          - cera_board.env  (rendered console/fdtfile/board_id)
#                          - boot_state.txt  (initial A/B state seed)
#                          - recovery.scr    (cross-partition manual recovery)
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
SINGLE_SLOT_FALLBACK="${SINGLE_SLOT_FALLBACK:-false}"
BOOT_ATTEMPTS="${CERALIVE_BOOT_ATTEMPTS:-3}"

# RAUC system compatible — read verbatim from the orchestrator (T12 single source
# of truth: ceralive-<board-slug>). NO family/board default here: a value computed
# locally could disagree with the signed bundle and reject every OTA. Empty is a
# hard error at install time (install_rootfs guard).
COMPATIBLE="${COMPATIBLE_STRING:-}"

# console= value for kernel/U-Boot: the manifest uses `ttyS2:1500000`; the kernel
# console form is `ttyS2,1500000`. Rewrite the ':' separator to ','.
console_value() {
  [[ -n "${SERIAL_CONSOLE}" ]] || die "SERIAL_CONSOLE is empty (manifest serial_console) — cannot render boot console"
  printf '%s' "${SERIAL_CONSOLE/:/,}"
}

# Self-contained twin of lib/common.sh::partlabel_prefix / resolve_partlabel (the
# rootfs target runs inside the chroot, where lib/ is not mounted — same reason
# this script carries its own log()/die()). CERALIVE_BENCH_LABELS=1 is the opt-in
# bench overlay: it must reach EVERY PARTLABEL this installer writes (the RAUC
# slot devices, the shared /boot fstab entry and the compiled U-Boot selectors),
# because a relabelled GPT whose selector still asks for `rootfs_a` does not boot.
partlabel_prefix() {
  [[ "${CERALIVE_BENCH_LABELS:-0}" == "1" ]] && printf 'x'
  return 0
}

resolve_partlabel() {
  printf '%s%s' "$(partlabel_prefix)" "${1:?resolve_partlabel needs a partition role}"
}

# relabel_selector <src> <dest> — copy a U-Boot selector source, rewriting the
# rootfs PARTLABEL it assigns. `setenv cera_root <label>` is the ONLY place a
# selector names one; the bootargs line reads ${cera_root} back out.
relabel_selector() {
  sed "s|setenv cera_root rootfs_|setenv cera_root $(partlabel_prefix)rootfs_|g" "$1" >"$2"
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
  [[ -n "${COMPATIBLE}" ]] || die "COMPATIBLE_STRING is unset/empty — the orchestrator must export ceralive-<board-slug> (board-specific); refusing to write a system.conf the signed bundle would reject"
  log "installing RAUC custom bootloader backend + state helper into the rootfs${root:+ (ROOT=${root})}"

  # The state helper is a thin persistence adapter over the SHARED A/B core; both
  # must land or the helper cannot resolve its core on the device.
  install -D -m 0644 "${SCRIPT_DIR}/../boot-state-core.sh"           "${root}/usr/lib/ceralive/boot-state-core.sh"
  install -D -m 0755 "${SCRIPT_DIR}/ceralive-boot-state.sh"          "${root}/usr/bin/ceralive-boot-state"
  install -D -m 0755 "${SCRIPT_DIR}/ceralive-rauc-boot-adapter.sh"   "${root}/usr/lib/rauc/ceralive-rauc-boot-adapter"

  # RAUC system.conf — bootloader=custom wired to our backend. Slots referenced by
  # PARTLABEL (frozen contract: never FS-UUID). The B slot is omitted for
  # single-slot media (contract §4) so RAUC never targets a non-existent partition.
  local slot_a slot_b
  slot_a="$(resolve_partlabel rootfs_a)"
  slot_b="$(resolve_partlabel rootfs_b)"
  log "writing ${root}/etc/rauc/system.conf (bootloader=custom, compatible=${COMPATIBLE}, single_slot=${SINGLE_SLOT_FALLBACK}, slots=${slot_a}/${slot_b})"
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
# Trixie RAUC 1.13 delegates the four state/primary operations to this script
# AND calls get-current, which the adapter already implements. That call is the
# one behavioural difference from the bookworm 1.8 this image used to target:  # suite-literal-ok: records the RAUC behaviour of the previously targeted suite
# 1.8 read rauc.slot= itself and never invoked get-current, so the adapter's
# implementation was dead forward-compat code; on 1.11+ it is live. No change
# was needed — it was written for exactly this — but do not delete it as unused.
# BOOT_ORDER and per-slot attempt counters live on the FAT boot partition
# because the staged vendor U-Boot has no persistent fw_setenv (decision D3).
bootloader-custom-backend=/usr/lib/rauc/ceralive-rauc-boot-adapter

[keyring]
path=/etc/rauc/ceralive-keyring.pem

[slot.rootfs.0]
device=/dev/disk/by-partlabel/${slot_a}
type=ext4
bootname=A
EOF
    if [[ "${SINGLE_SLOT_FALLBACK}" != "true" ]]; then
      cat <<EOF

[slot.rootfs.1]
device=/dev/disk/by-partlabel/${slot_b}
type=ext4
bootname=B
EOF
    fi
  } >"${root}/etc/rauc/system.conf"
  chmod 0644 "${root}/etc/rauc/system.conf"

  local fstab="${root}/etc/fstab"
  local boot_mount
  boot_mount="PARTLABEL=$(resolve_partlabel boot) /boot vfat rw,nodev,nosuid,noexec,umask=0077,shortname=mixed,errors=remount-ro 0 2"
  mkdir -p "${root}/etc" "${root}/boot"
  touch "${fstab}"
  if grep -qE '^[[:space:]]*[^#[:space:]][^[:space:]]*[[:space:]]+/boot[[:space:]]+' "${fstab}"; then
    grep -Fxq "${boot_mount}" "${fstab}" \
      || die "${fstab} already has a conflicting /boot mount; shared boot_state.txt requires ${boot_mount}"
  else
    printf '%s\n' "${boot_mount}" >>"${fstab}"
  fi

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

  # <dest> is mcopy'd wholesale into the FAT partition, so the relabelled sources
  # are staged OUTSIDE it. With the overlay off the committed sources are compiled
  # in place, byte for byte as before.
  local boot_src="${SCRIPT_DIR}/boot.scr.cmd" recovery_src="${SCRIPT_DIR}/recovery.scr.cmd"
  local relabelled=""
  if [[ -n "$(partlabel_prefix)" ]]; then
    relabelled="$(mktemp -d)"
    log "bench PARTLABEL overlay active — selectors will boot $(resolve_partlabel rootfs_a)/$(resolve_partlabel rootfs_b)"
    relabel_selector "${boot_src}"     "${relabelled}/boot.scr.cmd"
    relabel_selector "${recovery_src}" "${relabelled}/recovery.scr.cmd"
    boot_src="${relabelled}/boot.scr.cmd"
    recovery_src="${relabelled}/recovery.scr.cmd"
  fi

  if command -v mkimage >/dev/null 2>&1; then
    log "compiling automatic and manual recovery scripts (mkimage)"
    mkimage -A arm64 -O linux -T script -C none -n "CeraLive A/B selector" \
      -d "${boot_src}" "${dest}/boot.scr" >&2
    mkimage -A arm64 -O linux -T script -C none -n "CeraLive A/B recovery" \
      -d "${recovery_src}" "${dest}/recovery.scr" >&2
  else
    cp -a "${boot_src}" "${dest}/boot.scr.cmd"
    cp -a "${recovery_src}" "${dest}/recovery.scr.cmd"
    if [[ "${allow_uncompiled}" == "true" ]]; then
      log "WARN mkimage not found — staged boot.scr.cmd source (compile later); --allow-uncompiled set"
    else
      die "mkimage (u-boot-tools) not found — cannot compile boot.scr. Install u-boot-tools or pass --allow-uncompiled."
    fi
  fi

  if [[ -n "${relabelled}" ]]; then
    rm -rf "${relabelled}"
  fi

  log "boot-partition artifacts staged in ${dest}"
}

usage() {
  cat >&2 <<EOF
Usage: install-boot.sh <target> [args]
  rootfs                         install RAUC backend + state helper + system.conf
                                 (run inside the image via mkosi-chroot)
  boot-partition <dir> [--allow-uncompiled]
                                 render boot.scr + recovery.scr + cera_board.env
                                 + boot_state.txt into <dir> (the FAT partition)

Board specifics come from the environment (manifest-resolved + orchestrator):
  SERIAL_CONSOLE DTB_NAME BOARD_ID SINGLE_SLOT_FALLBACK COMPATIBLE_STRING
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
