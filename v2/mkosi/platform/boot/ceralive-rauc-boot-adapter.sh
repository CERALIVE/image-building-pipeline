#!/usr/bin/env bash
#
# ceralive-rauc-boot-adapter.sh — RAUC custom bootloader backend for CeraLive.
#
# Wired into RAUC via system.conf:
#   [system]
#   bootloader=custom
#   [handlers]
#   bootloader-custom-backend=/usr/lib/rauc/ceralive-rauc-boot-adapter
#
# WHY custom (decision D3): the RK3588 vendor U-Boot (2017.09, ENV_IS_NOWHERE) has
# no working `fw_setenv`, so RAUC's stock `bootloader=uboot` backend cannot persist
# BOOT_ORDER / bootcount. We keep that exact A/B+bootcount model, but in a text file
# on the FAT `boot` partition instead of U-Boot env — see ceralive-boot-state.sh.
#
# RAUC CUSTOM BACKEND INTERFACE (https://rauc.readthedocs.io/ integration.html):
# RAUC invokes this script with the operation as $1 and the slot's `bootname` as the
# trailing argument. Debian bookworm's RAUC 1.8 reads `rauc.slot=` itself and calls
# the four state/primary operations. RAUC 1.11+ may also call `get-current`, which
# this backend implements for forward compatibility. Their CeraLive mapping:
#
#   get-current                 -> read rauc.slot=A|B from the kernel command line
#       Print the bootname of the slot running now. Never infer this from primary:
#       an install changes primary while the old slot is still running.
#   get-primary                 -> ceralive-boot-state get-primary
#       Print the bootname of the slot marked primary (the one that boots next).
#   set-primary  <bootname>     -> ceralive-boot-state set-primary <bootname>
#       Mark <bootname> primary (RAUC calls this to activate a freshly-installed
#       slot). Moves it to the head of BOOT_ORDER and resets its attempt budget.
#   get-state    <bootname>     -> ceralive-boot-state get-state <bootname>
#       Print "good" or "bad" for <bootname>.
#   set-state    <bootname> <good|bad>
#                               -> ceralive-boot-state set-state <bootname> <...>
#       Mark <bootname> good (healthy; reset attempts) or bad (faulty; drop it).
#
# `bootname` is the RAUC slot bootname from system.conf (A or B), identical to the
# slot identifiers ceralive-boot-state uses — no translation needed.
#
# This is a THIN adapter: all state logic lives in ceralive-boot-state so the
# bootloader (boot.scr), the adapter, and the offline test share ONE implementation.
# Self-contained (ships on device; no repo lib). Strict mode, no error swallowing.
#
# shellcheck shell=bash

set -euo pipefail

die() { printf 'ceralive-rauc-boot-adapter: %s\n' "$*" >&2; exit 1; }

# Locate the state helper: the installed device path first, then a sibling copy so
# the adapter is exercisable straight from the source tree by the offline test.
find_boot_state() {
  if [[ -n "${CERALIVE_BOOT_STATE_BIN:-}" && -x "${CERALIVE_BOOT_STATE_BIN}" ]]; then
    printf '%s' "${CERALIVE_BOOT_STATE_BIN}"; return 0
  fi
  if command -v ceralive-boot-state >/dev/null 2>&1; then
    command -v ceralive-boot-state; return 0
  fi
  local here; here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -x "${here}/ceralive-boot-state.sh" ]]; then
    printf '%s' "${here}/ceralive-boot-state.sh"; return 0
  fi
  die "cannot find ceralive-boot-state (set CERALIVE_BOOT_STATE_BIN, or install it on PATH)"
}

get_current_slot() {
  local cmdline_file="${CERALIVE_KERNEL_CMDLINE_FILE:-/proc/cmdline}" cmdline token
  local current=""
  local -a tokens=()
  [[ -r "${cmdline_file}" ]] || die "cannot read kernel command line: ${cmdline_file}"
  cmdline="$(<"${cmdline_file}")"
  read -r -a tokens <<<"${cmdline}"
  for token in "${tokens[@]}"; do
    case "${token}" in
      rauc.slot=*)
        [[ -z "${current}" ]] || die "kernel command line has duplicate rauc.slot arguments"
        current="${token#rauc.slot=}"
        ;;
    esac
  done
  case "${current}" in
    A|B) printf '%s\n' "${current}" ;;
    "") die "kernel command line is missing rauc.slot=A|B" ;;
    *) die "invalid kernel rauc.slot '${current}' (expected A or B)" ;;
  esac
}

main() {
  local op="${1:-}"; shift || true
  local boot_state; boot_state="$(find_boot_state)"

  case "${op}" in
    get-current)
      [[ $# -eq 0 ]] || die "get-current takes no arguments"
      get_current_slot
      ;;
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
RAUC custom bootloader backend. Invoked by RAUC, not by hand:
  get-current
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
