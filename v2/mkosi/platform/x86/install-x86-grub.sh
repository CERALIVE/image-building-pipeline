#!/usr/bin/env bash
#
# install-x86-grub.sh — build-time installer for the CeraLive x86 A/B bootloader
# integration using RAUC's NATIVE `bootloader=grub` backend (the meta-rauc-qemux86
# reference pattern). Task 12 — closes TODO(x86-disk).
#
# WHY RAUC-NATIVE bootloader=grub (and NOT the bootloader=custom scaffold next to
# it): GRUB has full persistent env (grub-editenv + grubenv), so RAUC's stock grub
# backend manages the A/B grubenv (ORDER / <slot>_OK / <slot>_TRY) directly — no
# CeraLive custom backend script, no userspace state engine on the device. That is
# the least-custom-glue path the Task-12 VERIFY-FIRST gate selected. The sibling
# bootloader=custom files (install-x86-boot.sh / x86-boot-state.sh / grub.cfg.tmpl)
# are RETAINED only as the offline rollback-contract harness that test-x86-fallback.sh
# and qemu-x86.sh --fallback-selftest exercise; they are NOT installed by this path.
#
# Board specifics are NEVER hardcoded: they arrive as environment variables that the
# orchestrator resolves from the board+family manifest (lib/resolve.sh) and forwards
# via mkosi `--environment` / PassEnvironment:
#   SERIAL_CONSOLE        family manifest serial_console (e.g. ttyS0:115200)
#   COMPATIBLE_STRING     orchestrator ceralive-<board-slug> -> RAUC compatible
#   SINGLE_SLOT_FALLBACK  board manifest single_slot_fallback (true|false)
# x86 has NO DTB and NO U-Boot (ACPI + UEFI) — those fields are unused here.
#
# THREE targets (the bits live in two places + a grubenv mutator):
#
#   rootfs <chroot=/>   USERSPACE bits into the rootfs slot. No grub tooling needed:
#                       - /etc/rauc/system.conf  (bootloader=grub, grubenv= on ESP)
#                       - /etc/fstab             (mount the ESP at /boot/efi so RAUC
#                                                 can grub-editenv the grubenv)
#                       Invoked from platform/mkosi.finalize via mkosi-chroot.
#
#   esp <dir>           EFI SYSTEM PARTITION bits into <dir> (the ESP staging tree):
#                       - EFI/BOOT/BOOTX64.EFI  (removable-path GRUB, grub-mkstandalone)
#                       - EFI/BOOT/grub.cfg     (rendered from grub-ab.cfg)
#                       - EFI/BOOT/grubenv      (seeded A/B state: ORDER + OK/TRY)
#                       Invoked by lib/assemble-disk-x86.sh at disk-assembly time.
#
#   grubenv-set <file> KEY=VALUE [KEY=VALUE ...]
#                       Set vars in a grubenv (prefer grub-editenv; self-contained
#                       1024-byte bash fallback otherwise). Used to seed/flip ORDER
#                       and is the slot-switch lever the verification drives.
#
# Self-contained: the rootfs path runs INSIDE the image (mkosi-chroot) where the
# repo's lib/common.sh is absent, so this script carries its own helpers. Strict,
# no `|| true` swallowing.
#
# shellcheck shell=bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '[install-x86-grub] %s\n' "$*" >&2; }
die()  { printf '[install-x86-grub] ERROR: %s\n' "$*" >&2; exit 1; }

# Board specifics from the environment (manifest-resolved).
SERIAL_CONSOLE="${SERIAL_CONSOLE:-}"
SINGLE_SLOT_FALLBACK="${SINGLE_SLOT_FALLBACK:-false}"
BOOT_ATTEMPTS="${CERALIVE_BOOT_ATTEMPTS:-3}"

# RAUC system compatible — read verbatim from the orchestrator (single source of
# truth: ceralive-<board-slug>). NO local default: a value computed here could
# disagree with the signed bundle and reject every OTA. Empty is a hard error.
COMPATIBLE="${COMPATIBLE_STRING:-}"

# Device-side ESP mount + grubenv location. The ESP (PARTLABEL=boot) mounts at
# /boot/efi; GRUB's removable binary, grub.cfg and grubenv all live in /EFI/BOOT so
# the standalone BOOTX64.EFI finds them and `load_env`/RAUC's grub-editenv share one
# file. The grubenv= path RAUC writes is the on-device path below.
ESP_MOUNT="/boot/efi"
ESP_GRUB_SUBDIR="EFI/BOOT"
GRUBENV_DEVICE_PATH="${ESP_MOUNT}/${ESP_GRUB_SUBDIR}/grubenv"
RAUC_KEYRING_PATH="/etc/rauc/ceralive-keyring.pem"

GRUB_EDITENV="${GRUB_EDITENV:-grub-editenv}"
GRUB_MKSTANDALONE="${GRUB_MKSTANDALONE:-grub-mkstandalone}"

# console= value for the kernel: the manifest uses `ttyS0:115200`; the kernel form
# is `ttyS0,115200`. Rewrite the ':' separator to ','.
console_value() {
  [[ -n "${SERIAL_CONSOLE}" ]] || die "SERIAL_CONSOLE is empty (manifest serial_console) — cannot render boot console"
  printf '%s' "${SERIAL_CONSOLE/:/,}"
}

# ---------------------------------------------------------------------------
# grubenv primitives. Prefer the real grub-editenv (byte-compatible with GRUB's
# load_env); fall back to a self-contained 1024-byte GRUB environment block writer
# so this runs on hosts/containers with no GRUB tooling (and so the offline test
# does not need grub installed). Same proven block shape as x86-boot-state.sh.
# ---------------------------------------------------------------------------
GRUBENV_HEADER="# GRUB Environment Block"
GRUBENV_SIZE=1024

have_grub_editenv() { command -v "${GRUB_EDITENV}" >/dev/null 2>&1; }

grubenv_list_file() {
  local f="$1"
  if have_grub_editenv && [[ -f "${f}" ]]; then
    "${GRUB_EDITENV}" "${f}" list
    return 0
  fi
  [[ -f "${f}" ]] || return 0
  awk '/^[A-Za-z_][A-Za-z0-9_]*=/{ print }' "${f}"
}

# grubenv_set_file <file> KEY=VALUE [KEY=VALUE ...] — merge vars into the grubenv,
# preserving any others. grub-editenv merges natively; the bash fallback re-reads,
# merges, and rewrites a compatible 1024-byte block.
grubenv_set_file() {
  local f="$1"; shift
  local dir; dir="$(dirname "${f}")"
  mkdir -p "${dir}"
  if have_grub_editenv; then
    [[ -f "${f}" ]] || "${GRUB_EDITENV}" "${f}" create
    "${GRUB_EDITENV}" "${f}" set "$@"
    return 0
  fi
  declare -A _vars=()
  local line key val kv
  while IFS= read -r line; do
    [[ "${line}" == *=* ]] || continue
    key="${line%%=*}"; val="${line#*=}"; _vars["${key}"]="${val}"
  done < <(grubenv_list_file "${f}")
  for kv in "$@"; do
    key="${kv%%=*}"; val="${kv#*=}"; _vars["${key}"]="${val}"
  done
  local body="" content pad len tmp
  for key in $(printf '%s\n' "${!_vars[@]}" | sort); do
    body+="${key}=${_vars[$key]}"$'\n'
  done
  content="${GRUBENV_HEADER}"$'\n'"${body}"
  len="${#content}"
  (( len <= GRUBENV_SIZE )) || die "grubenv content (${len}B) exceeds the ${GRUBENV_SIZE}B block"
  pad="$(printf '%*s' "$(( GRUBENV_SIZE - len ))" '' | tr ' ' '#')"
  tmp="${f}.tmp.$$"
  printf '%s%s' "${content}" "${pad}" >"${tmp}"
  mv -f "${tmp}" "${f}"
}

# grubenv_seed <file> — write the fresh-flash A/B state. Both slots known-good
# (OK=1), untried (TRY=0), A leads ORDER. Single-slot drops B (B never bootable).
grubenv_seed() {
  local f="$1"
  if [[ "${SINGLE_SLOT_FALLBACK}" == "true" ]]; then
    grubenv_set_file "${f}" "ORDER=A" "A_OK=1" "A_TRY=0" "B_OK=0" "B_TRY=0"
  else
    grubenv_set_file "${f}" "ORDER=A B" "A_OK=1" "A_TRY=0" "B_OK=1" "B_TRY=0"
  fi
}

# ---------------------------------------------------------------------------
# rootfs — install the RAUC system.conf (bootloader=grub) + ESP fstab mount into
# the image (chroot). ROOT (default empty = the chroot's /) optionally prefixes the
# paths so the same installer can populate a staging dir for tests without root.
# ---------------------------------------------------------------------------
install_rootfs() {
  local root="${ROOT:-}"
  [[ -n "${COMPATIBLE}" ]] || die "COMPATIBLE_STRING is unset/empty — the orchestrator must export ceralive-<board-slug>; refusing to write a system.conf the signed bundle would reject"
  log "installing RAUC bootloader=grub system.conf + ESP fstab mount into the rootfs${root:+ (ROOT=${root})}"

  mkdir -p "${root}/etc/rauc"
  log "writing ${root}/etc/rauc/system.conf (bootloader=grub, compatible=${COMPATIBLE}, grubenv=${GRUBENV_DEVICE_PATH}, single_slot=${SINGLE_SLOT_FALLBACK})"
  {
    cat <<EOF
[system]
compatible=${COMPATIBLE}
bootloader=grub
# RAUC's BUILT-IN grub backend manages the A/B grubenv (ORDER / <slot>_OK /
# <slot>_TRY) on the EFI System Partition via grub-editenv — no CeraLive custom
# backend. grubenv MUST live on the ESP (never in a rootfs slot): a RAUC update
# rewrites the inactive rootfs slot and would destroy boot-selection state.
grubenv=${GRUBENV_DEVICE_PATH}
# Boot attempts budget surfaced for parity with the RK3588 path. RAUC's grub
# backend itself uses the boolean <slot>_OK/<slot>_TRY retry (one attempt/cycle).
boot-attempts=${BOOT_ATTEMPTS}

[keyring]
path=${RAUC_KEYRING_PATH}

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

  # Mount the ESP at /boot/efi so RAUC's grub backend can grub-editenv the grubenv.
  # Idempotent: only append the fstab line if the mountpoint is not already there.
  mkdir -p "${root}${ESP_MOUNT}"
  local fstab="${root}/etc/fstab"
  mkdir -p "${root}/etc"
  if ! grep -qE "^[^#]*[[:space:]]${ESP_MOUNT}[[:space:]]" "${fstab}" 2>/dev/null; then
    log "adding ESP mount to ${fstab}: PARTLABEL=boot ${ESP_MOUNT} vfat"
    printf 'PARTLABEL=boot %s vfat umask=0077,shortname=mixed,errors=remount-ro 0 2\n' \
      "${ESP_MOUNT}" >>"${fstab}"
  else
    log "ESP mount ${ESP_MOUNT} already in ${fstab} — leaving it"
  fi

  log "x86 rootfs bootloader integration installed (RAUC bootloader=grub)"
}

# render_grub_cfg <dest> — substitute @CONSOLE@ in grub-ab.cfg.
render_grub_cfg() {
  local dest="$1" tmpl="${SCRIPT_DIR}/grub-ab.cfg"
  [[ -f "${tmpl}" ]] || die "template not found: ${tmpl}"
  local console; console="$(console_value)"
  sed -e "s|@CONSOLE@|${console}|g" "${tmpl}" >"${dest}"
}

# write_standalone_grub <dest_efi> — build the removable-path GRUB binary with an
# embedded early config that finds and loads the on-ESP grub.cfg. grub-mkstandalone
# packs GRUB + modules + the early cfg into one EFI image (offline, no loop mount).
# If grub-mkstandalone is absent (a host without grub-efi-amd64-bin), stage a clear
# placeholder + log the deferred hook — mirroring install-boot.sh's mkimage handling
# and install-x86-boot.sh's grub-install handling. A grub-equipped builder fills it.
write_standalone_grub() {
  local dest_efi="$1"
  mkdir -p "$(dirname "${dest_efi}")"
  if command -v "${GRUB_MKSTANDALONE}" >/dev/null 2>&1; then
    local early; early="$(mktemp)"
    cat >"${early}" <<'EARLY'
search --no-floppy --set=root --file /EFI/BOOT/grub.cfg
set prefix=($root)/EFI/BOOT
configfile ($root)/EFI/BOOT/grub.cfg
EARLY
    log "building removable-path GRUB ${dest_efi} (grub-mkstandalone, x86_64-efi)"
    "${GRUB_MKSTANDALONE}" \
      --format=x86_64-efi \
      --output="${dest_efi}" \
      --modules="part_gpt fat ext2 search search_label search_fs_file normal echo test configfile loadenv linux" \
      "boot/grub/grub.cfg=${early}" >&2
    rm -f "${early}"
  else
    log "WARN ${GRUB_MKSTANDALONE} not found — staging a placeholder BOOTX64.EFI. The real removable-path GRUB binary is built by a grub-equipped builder (apt: grub-efi-amd64-bin grub-common). The ESP layout (grub.cfg + grubenv) is complete."
    printf 'CERALIVE-GRUB-PLACEHOLDER: build with grub-mkstandalone (grub-efi-amd64-bin)\n' >"${dest_efi}"
  fi
}

# ---------------------------------------------------------------------------
# esp <dir> — render grub.cfg + seed grubenv + write BOOTX64.EFI into the ESP tree.
# ---------------------------------------------------------------------------
install_esp() {
  local dest="${1:-}"
  [[ -n "${dest}" ]] || die "esp: destination dir (the ESP staging tree) is required"
  local efidir="${dest}/EFI/BOOT"
  mkdir -p "${efidir}"

  log "rendering grub.cfg (console=$(console_value)) -> ${efidir}/grub.cfg"
  render_grub_cfg "${efidir}/grub.cfg"

  log "seeding grubenv A/B state (single_slot=${SINGLE_SLOT_FALLBACK}) -> ${efidir}/grubenv"
  grubenv_seed "${efidir}/grubenv"

  write_standalone_grub "${efidir}/BOOTX64.EFI"

  log "x86 ESP artifacts staged in ${efidir}"
}

usage() {
  cat >&2 <<EOF
Usage: install-x86-grub.sh <target> [args]
  rootfs                         install RAUC bootloader=grub system.conf + ESP fstab
                                 mount (run inside the image via mkosi-chroot)
  esp <dir>                      render grub.cfg + seed grubenv + write BOOTX64.EFI
                                 into the ESP staging tree <dir>
  grubenv-set <file> KEY=VALUE ...
                                 set vars in a grubenv (grub-editenv or bash fallback)

Board specifics come from the environment (manifest-resolved):
  SERIAL_CONSOLE COMPATIBLE_STRING SINGLE_SLOT_FALLBACK
EOF
}

main() {
  local target="${1:-}"; shift || true
  case "${target}" in
    rootfs)       install_rootfs ;;
    esp)          install_esp "$@" ;;
    grubenv-set)
      local f="${1:-}"; shift || true
      [[ -n "${f}" ]] || die "grubenv-set: <file> is required"
      [[ $# -gt 0 ]] || die "grubenv-set: at least one KEY=VALUE is required"
      grubenv_set_file "${f}" "$@"
      ;;
    -h|--help|"")  usage; [[ -n "${target}" ]] ;;
    *) usage; die "unknown target '${target}'" ;;
  esac
}

main "$@"
