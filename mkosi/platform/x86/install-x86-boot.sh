#!/usr/bin/env bash
#
# install-x86-boot.sh — build-time installer for the CeraLive x86 A/B bootloader
# integration (RAUC bootloader=custom on UEFI/GRUB; task 33). The x86 twin of the
# RK3588 platform/boot/install-boot.sh.
#
# Board specifics are NEVER hardcoded: they arrive as environment variables that
# the orchestrator resolves from the board+family manifest (lib/resolve.sh) and
# forwards via mkosi `--environment`:
#   SERIAL_CONSOLE        family manifest serial_console (e.g. ttyS0:115200)
#   FAMILY                board  manifest family         (e.g. x86_64) -> RAUC compatible
#   SINGLE_SLOT_FALLBACK  board  manifest single_slot_fallback (true|false)
# x86 has NO DTB and NO U-Boot (ACPI + UEFI) — DTB_NAME/UBOOT are intentionally
# unused here, unlike the RK3588 installer.
#
# TWO install targets (the bits live in two places, need different tooling):
#
#   rootfs <chroot=/>   USERSPACE bits into the rootfs slot. No grub tooling needed:
#                       - /usr/bin/ceralive-boot-state              (x86 state helper)
#                       - /usr/lib/rauc/ceralive-rauc-boot-adapter  (RAUC backend)
#                       - /etc/rauc/system.conf                     (bootloader=custom)
#                       Same device-side paths as RK3588 -> RAUC system.conf is
#                       platform-uniform; only the SOURCE implementation differs.
#
#   esp <dir>           EFI SYSTEM PARTITION bits into <dir> (the mounted ESP):
#                       - EFI/ceralive/grub.cfg   (rendered from grub.cfg.tmpl:
#                                                  console + generated decrement ladder)
#                       - EFI/ceralive/grubenv    (initial A/B state seed)
#                       - the GRUB EFI binary (grubx64.efi) is written by `grub-install`
#                         at disk-assembly time (a HOST/runtime tool); --install-grub
#                         <esp> <disk> runs it when available, else the hook is logged.
#
# Self-contained: the rootfs path runs INSIDE the image (mkosi-chroot) where the
# repo's lib/common.sh is absent, so this script carries its own helpers. Strict,
# no `|| true` swallowing.
#
# shellcheck shell=bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '[install-x86-boot] %s\n' "$*" >&2; }
die()  { printf '[install-x86-boot] ERROR: %s\n' "$*" >&2; exit 1; }

# Board specifics from the environment (manifest-resolved).
SERIAL_CONSOLE="${SERIAL_CONSOLE:-}"
FAMILY="${FAMILY:-}"
SINGLE_SLOT_FALLBACK="${SINGLE_SLOT_FALLBACK:-false}"
BOOT_ATTEMPTS="${CERALIVE_BOOT_ATTEMPTS:-3}"

# RAUC system compatible string — derived from the family, NOT hardcoded per board.
COMPATIBLE="${RAUC_COMPATIBLE:-ceralive-${FAMILY:-unknown}}"

# GRUB id / ESP install path. The grubenv + grub.cfg live under EFI/<id> so GRUB's
# $prefix (set by grub-install --bootloader-id) finds grubenv via plain `load_env`.
GRUB_BOOTLOADER_ID="${GRUB_BOOTLOADER_ID:-ceralive}"

# console= value for the kernel: the manifest uses `ttyS0:115200`; the kernel form
# is `ttyS0,115200`. Rewrite the ':' separator to ','.
console_value() {
  [[ -n "${SERIAL_CONSOLE}" ]] || die "SERIAL_CONSOLE is empty (manifest serial_console) — cannot render boot console"
  printf '%s' "${SERIAL_CONSOLE/:/,}"
}

# gen_ladder <SLOT> <attempts> — emit the GRUB string-comparison decrement ladder
# for BOOT_<SLOT>_LEFT (N -> N-1 -> ... -> 0). GRUB has no arithmetic, so we
# enumerate each step. Lines are indented to sit inside the grub.cfg `if` block.
gen_ladder() {
  local slot="$1" n="$2" var i kw out=""
  var="BOOT_${slot}_LEFT"
  [[ "${n}" =~ ^[0-9]+$ && "${n}" -ge 1 ]] || die "gen_ladder: attempts must be a positive integer (got '${n}')"
  for (( i=n; i>=1; i-- )); do
    if [[ "${i}" -eq "${n}" ]]; then kw="if"; else kw="elif"; fi
    out+="    ${kw} [ \"\${${var}}\" = \"${i}\" ]; then set ${var}=\"$(( i - 1 ))\""$'\n'
  done
  out+="    fi"
  printf '%s' "${out}"
}

# ---------------------------------------------------------------------------
# rootfs — install the userspace bits into the image (chroot). No grub tooling.
# ROOT (default empty = the chroot's /) optionally prefixes every install path so
# the same installer can populate a staging dir for tests/evidence without root.
# ---------------------------------------------------------------------------
install_rootfs() {
  local root="${ROOT:-}"
  log "installing x86 RAUC custom bootloader backend + state helper into the rootfs${root:+ (ROOT=${root})}"

  # Install to the PLATFORM-UNIFORM device paths (same as RK3588) so RAUC
  # system.conf is identical across architectures; only the source differs.
  install -D -m 0755 "${SCRIPT_DIR}/x86-boot-state.sh"            "${root}/usr/bin/ceralive-boot-state"
  install -D -m 0755 "${SCRIPT_DIR}/x86-rauc-boot-adapter.sh"     "${root}/usr/lib/rauc/ceralive-rauc-boot-adapter"

  log "writing ${root}/etc/rauc/system.conf (bootloader=custom, compatible=${COMPATIBLE}, single_slot=${SINGLE_SLOT_FALLBACK})"
  mkdir -p "${root}/etc/rauc"
  {
    cat <<EOF
[system]
compatible=${COMPATIBLE}
bootloader=custom
# Boot attempts per slot before the custom backend / grub.cfg declare a slot bad
# and roll back. Mirrors CERALIVE_BOOT_ATTEMPTS used by ceralive-boot-state.
boot-attempts=${BOOT_ATTEMPTS}

[handlers]
# RAUC bootloader=custom delegates every boot-state op to this script
# (get-primary / set-primary / get-state / set-state). It keeps BOOT_ORDER +
# per-slot attempt counters in the grubenv on the ESP via grub-editenv. GRUB has
# working persistent env, but we use a CUSTOM backend (not bootloader=grub) to keep
# the RK3588 multi-attempt countdown model + a uniform interface (task 33 / README).
bootloader-custom-backend=/usr/lib/rauc/ceralive-rauc-boot-adapter

[keyring]
path=/etc/rauc/keyring.pem

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

  log "x86 rootfs bootloader integration installed"
}

# render_grub_cfg <dest> — substitute @CONSOLE@ / @BOOT_ATTEMPTS@ and inject the
# generated @DECREMENT_A@ / @DECREMENT_B@ ladders into grub.cfg.tmpl. Pure bash
# replacement (the ladders are multi-line; sed multi-line injection is brittle).
render_grub_cfg() {
  local dest="$1" tmpl="${SCRIPT_DIR}/grub.cfg.tmpl"
  [[ -f "${tmpl}" ]] || die "template not found: ${tmpl}"
  local console; console="$(console_value)"
  local ladder_a ladder_b content
  ladder_a="$(gen_ladder A "${BOOT_ATTEMPTS}")"
  ladder_b="$(gen_ladder B "${BOOT_ATTEMPTS}")"
  content="$(<"${tmpl}")"
  content="${content//@CONSOLE@/${console}}"
  content="${content//@BOOT_ATTEMPTS@/${BOOT_ATTEMPTS}}"
  content="${content//@DECREMENT_A@/${ladder_a}}"
  content="${content//@DECREMENT_B@/${ladder_b}}"
  printf '%s\n' "${content}" >"${dest}"
}

# ---------------------------------------------------------------------------
# esp <dir> — render grub.cfg + seed grubenv into the ESP staging dir. Optionally
# run grub-install (writes grubx64.efi) when --install-grub <disk> is given AND
# grub-install is present; otherwise the GRUB-binary install is logged as the
# disk-assembly hook (analogous to the RK3588 boot.scr / mkimage staging).
# ---------------------------------------------------------------------------
install_esp() {
  local dest="" disk="" do_grub_install="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --install-grub) do_grub_install="true"; disk="${2:?--install-grub needs a target disk}"; shift 2 ;;
      *)
        [[ -z "${dest}" ]] || die "esp: unexpected arg '$1'"
        dest="$1"; shift
        ;;
    esac
  done
  [[ -n "${dest}" ]] || die "esp: destination dir (the mounted ESP) is required"

  local efidir="${dest}/EFI/${GRUB_BOOTLOADER_ID}"
  mkdir -p "${efidir}"

  log "rendering grub.cfg (console=$(console_value) attempts=${BOOT_ATTEMPTS}) -> ${efidir}/grub.cfg"
  render_grub_cfg "${efidir}/grub.cfg"

  log "seeding grubenv A/B state (single_slot=${SINGLE_SLOT_FALLBACK}, attempts=${BOOT_ATTEMPTS}) -> ${efidir}/grubenv"
  if [[ "${SINGLE_SLOT_FALLBACK}" == "true" ]]; then
    CERALIVE_GRUBENV="${efidir}/grubenv" CERALIVE_BOOT_ATTEMPTS="${BOOT_ATTEMPTS}" \
      bash "${SCRIPT_DIR}/x86-boot-state.sh" init --attempts "${BOOT_ATTEMPTS}" --single-slot
  else
    CERALIVE_GRUBENV="${efidir}/grubenv" CERALIVE_BOOT_ATTEMPTS="${BOOT_ATTEMPTS}" \
      bash "${SCRIPT_DIR}/x86-boot-state.sh" init --attempts "${BOOT_ATTEMPTS}"
  fi

  if [[ "${do_grub_install}" == "true" ]]; then
    if command -v grub-install >/dev/null 2>&1; then
      log "grub-install --target=x86_64-efi --efi-directory=${dest} --bootloader-id=${GRUB_BOOTLOADER_ID} (disk=${disk})"
      grub-install --target=x86_64-efi --efi-directory="${dest}" \
        --bootloader-id="${GRUB_BOOTLOADER_ID}" --no-nvram --removable "${disk}" >&2
    else
      die "grub-install not found but --install-grub requested — install grub-efi-amd64-bin or drop the flag"
    fi
  else
    log "GRUB EFI binary install deferred: run 'grub-install --target=x86_64-efi --efi-directory=${dest} --bootloader-id=${GRUB_BOOTLOADER_ID}' at disk-assembly time (writes grubx64.efi)"
  fi

  log "x86 ESP artifacts staged in ${efidir}"
}

usage() {
  cat >&2 <<EOF
Usage: install-x86-boot.sh <target> [args]
  rootfs                         install RAUC backend + state helper + system.conf
                                 (run inside the image via mkosi-chroot)
  esp <dir> [--install-grub <disk>]
                                 render grub.cfg + seed grubenv into the ESP <dir>;
                                 optionally run grub-install (writes grubx64.efi)

Board specifics come from the environment (manifest-resolved):
  SERIAL_CONSOLE FAMILY SINGLE_SLOT_FALLBACK
EOF
}

main() {
  local target="${1:-}"; shift || true
  case "${target}" in
    rootfs)          install_rootfs ;;
    esp)             install_esp "$@" ;;
    -h|--help|"")    usage; [[ -n "${target}" ]] ;;
    *) usage; die "unknown target '${target}'" ;;
  esac
}

main "$@"
