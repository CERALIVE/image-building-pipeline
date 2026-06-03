#!/usr/bin/env bash
#
# x86-rauc-boot-adapter.sh — RAUC custom bootloader backend for CeraLive on x86
# (UEFI/GRUB). The x86 twin of ceralive-rauc-boot-adapter.sh: IDENTICAL RAUC custom
# backend interface (get-primary/set-primary/get-state/set-state), backed by the
# x86 grubenv state engine (x86-boot-state -> /usr/bin/ceralive-boot-state) instead
# of the RK3588 FAT text file.
#
# Wired into RAUC via system.conf (written by install-x86-boot.sh rootfs):
#   [system]
#   bootloader=custom
#   [handlers]
#   bootloader-custom-backend=/usr/lib/rauc/ceralive-rauc-boot-adapter
#
# WHY custom and not RAUC's built-in `bootloader=grub` (deliberate — see README.md):
# RAUC's stock grub backend uses a single boolean retry (<slot>_OK / <slot>_TRY). We
# keep the RK3588 multi-attempt COUNTDOWN model (BOOT_<slot>_LEFT 3->2->1->0) so both
# platforms share ONE adapter interface, ONE state model, and ONE offline test shape.
# GRUB DOES have working persistent env (grub-editenv) — unlike the RK3588 vendor
# U-Boot — so the storage is grubenv, not a hand-rolled text file.
#
# RAUC CUSTOM BACKEND INTERFACE (https://rauc.readthedocs.io/ integration.html):
# RAUC invokes this script with the operation as $1 and the slot's `bootname` (A/B)
# as the trailing argument. The four operations and their CeraLive mapping:
#
#   get-primary                 -> ceralive-boot-state get-primary
#   set-primary  <bootname>     -> ceralive-boot-state set-primary <bootname>
#   get-state    <bootname>     -> ceralive-boot-state get-state <bootname>
#   set-state    <bootname> <good|bad>
#                               -> ceralive-boot-state set-state <bootname> <...>
#
# `bootname` is the RAUC slot bootname from system.conf (A or B), identical to the
# slot identifiers ceralive-boot-state uses — no translation needed.
#
# This is a THIN adapter: all state logic lives in the x86 boot-state engine so the
# bootloader (grub.cfg), the adapter, and the offline test share ONE implementation.
# Self-contained (ships on device; no repo lib). Strict mode, no error swallowing.
#
# shellcheck shell=bash

set -euo pipefail

die() { printf 'x86-rauc-boot-adapter: %s\n' "$*" >&2; exit 1; }

# Locate the state helper: an explicit override, then the installed device path
# (/usr/bin/ceralive-boot-state — the platform-uniform name), then a sibling copy so
# the adapter is exercisable straight from the source tree by the offline test.
find_boot_state() {
  if [[ -n "${CERALIVE_BOOT_STATE_BIN:-}" && -x "${CERALIVE_BOOT_STATE_BIN}" ]]; then
    printf '%s' "${CERALIVE_BOOT_STATE_BIN}"; return 0
  fi
  if command -v ceralive-boot-state >/dev/null 2>&1; then
    command -v ceralive-boot-state; return 0
  fi
  local here; here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -x "${here}/x86-boot-state.sh" ]]; then
    printf '%s' "${here}/x86-boot-state.sh"; return 0
  fi
  die "cannot find ceralive-boot-state (set CERALIVE_BOOT_STATE_BIN, or install it on PATH)"
}

main() {
  local op="${1:-}"; shift || true
  local boot_state; boot_state="$(find_boot_state)"

  case "${op}" in
    get-primary)
      [[ $# -eq 0 ]] || die "get-primary takes no arguments"
      "${boot_state}" get-primary
      ;;
    set-primary)
      local slot="${1:-}"; [[ -n "${slot}" ]] || die "set-primary needs a bootname"
      "${boot_state}" set-primary "${slot}"
      ;;
    get-state)
      local slot="${1:-}"; [[ -n "${slot}" ]] || die "get-state needs a bootname"
      "${boot_state}" get-state "${slot}"
      ;;
    set-state)
      local slot="${1:-}" state="${2:-}"
      [[ -n "${slot}" && -n "${state}" ]] || die "set-state needs: <bootname> <good|bad>"
      "${boot_state}" set-state "${slot}" "${state}"
      ;;
    -h|--help|"")
      cat >&2 <<'EOF'
RAUC custom bootloader backend (x86/GRUB). Invoked by RAUC, not by hand:
  get-primary
  set-primary <bootname>
  get-state   <bootname>
  set-state   <bootname> <good|bad>
EOF
      [[ -n "${op}" ]]
      ;;
    *) die "unknown RAUC backend operation '${op}'" ;;
  esac
}

main "$@"
