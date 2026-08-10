#!/usr/bin/env bash
#
# boot-state-core.sh — the SHARED on-device A/B slot-state core.
#
# RK3588 and x86 run the same A/B + bootcount MODEL (BOOT_ORDER + per-slot
# BOOT_<name>_LEFT countdown), the same RAUC custom-backend surface and the same
# CLI. Only the PERSISTENCE differs: RK3588's vendor U-Boot is built
# ENV_IS_NOWHERE so its state is a CRC-guarded text file on the FAT boot
# partition, while x86's GRUB has a real persistent environment block. Everything
# above that line lived twice; it lives here now, and each platform ships a thin
# adapter that supplies only its own storage.
#
# Ships ON the device (installed as /usr/lib/ceralive/boot-state-core.sh beside
# /usr/bin/ceralive-boot-state) and is also driven by the build-time offline
# tests, so it is deliberately SELF-CONTAINED: no dependency on the repo's
# lib/common.sh, which does not exist on a device. Strict mode, no `|| true`
# swallowing except the one documented best-effort heal in the RK adapter.
#
# ── What an adapter MUST provide before sourcing this file ──────────────────
#   BOOT_STATE_TOOL             name used in diagnostics ("ceralive-boot-state")
#   BOOT_ATTEMPTS               the per-slot attempt budget
#   BOOT_STATE_KEEP_LAST_SLOT   1 to keep a `set-state bad` slot as the sole
#                               BOOT_ORDER entry when it was the last one, 0 to
#                               allow an empty BOOT_ORDER (the two platforms
#                               differ here today; making them agree is a
#                               behaviour change, not an extraction)
#
# ── What an adapter MUST define as functions ────────────────────────────────
#   load_state                  populate BOOT_ORDER / BOOT_A_LEFT / BOOT_B_LEFT
#   store_state                 persist those three
#   boot_state_dump_backend     print the backend's own `dump` line
#   boot_state_usage            print the whole usage text
#
# shellcheck shell=bash

# Valid slot bootnames. Symmetric A/B per the frozen partition contract
# (rootfs_a = slot A, rootfs_b = slot B). Single-slot images carry only A.
readonly VALID_SLOTS=("A" "B")

die() { printf '%s: %s\n' "${BOOT_STATE_TOOL}" "$*" >&2; exit 1; }

# rootfs PARTLABEL for a bootname (contract: slot A -> rootfs_a, slot B -> rootfs_b).
slot_partlabel() {
  case "$1" in
    A) printf 'rootfs_a' ;;
    B) printf 'rootfs_b' ;;
    *) die "unknown slot '$1' (expected A or B)" ;;
  esac
}

is_valid_slot() {
  local s
  for s in "${VALID_SLOTS[@]}"; do [[ "$1" == "${s}" ]] && return 0; done
  return 1
}

# The three state fields every backend loads into and stores from.
BOOT_ORDER=""
BOOT_A_LEFT=""
BOOT_B_LEFT=""

# left_of <slot> / set_left <slot> <n> — per-slot counter accessors.
left_of() { case "$1" in A) printf '%s' "${BOOT_A_LEFT}" ;; B) printf '%s' "${BOOT_B_LEFT}" ;; esac; }
set_left() { case "$1" in A) BOOT_A_LEFT="$2" ;; B) BOOT_B_LEFT="$2" ;; esac; }

# in_order <slot> — is the slot still present in BOOT_ORDER?
in_order() {
  local s
  for s in ${BOOT_ORDER}; do [[ "${s}" == "$1" ]] && return 0; done
  return 1
}

# ---------------------------------------------------------------------------
# Subcommands. Identical surface on both platforms — that symmetry is the point.
# ---------------------------------------------------------------------------

# init [--attempts N] [--single-slot] — write fresh state. Both slots get the full
# attempt budget; A leads. --single-slot drops B entirely (contract §4).
cmd_init() {
  local attempts="${BOOT_ATTEMPTS}" single_slot="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --attempts)    attempts="${2:?--attempts needs a value}"; shift 2 ;;
      --single-slot) single_slot="true"; shift ;;
      *) die "init: unknown argument '$1'" ;;
    esac
  done
  [[ "${attempts}" =~ ^[0-9]+$ ]] || die "init: --attempts must be a non-negative integer"
  if [[ "${single_slot}" == "true" ]]; then
    BOOT_ORDER="A"; BOOT_A_LEFT="${attempts}"; BOOT_B_LEFT="0"
  else
    BOOT_ORDER="A B"; BOOT_A_LEFT="${attempts}"; BOOT_B_LEFT="${attempts}"
  fi
  store_state
}

cmd_get_order() { load_state; printf '%s\n' "${BOOT_ORDER}"; }

cmd_get_left() {
  local slot="${1:?get-left needs a slot}"; is_valid_slot "${slot}" || die "invalid slot '${slot}'"
  load_state; printf '%s\n' "$(left_of "${slot}")"
}

# get-primary — first slot in BOOT_ORDER with LEFT>0 (the slot that WILL boot). If
# all are exhausted, the head of BOOT_ORDER (last-resort), matching boot-select.
cmd_get_primary() {
  load_state
  local s
  for s in ${BOOT_ORDER}; do
    if (( "$(left_of "${s}")" > 0 )); then printf '%s\n' "${s}"; return 0; fi
  done
  printf '%s\n' "${BOOT_ORDER%% *}"
}

# set-primary <slot> — make <slot> the primary: move it to the FRONT of BOOT_ORDER
# and reset its attempt budget. RAUC calls this to activate a freshly-installed slot.
cmd_set_primary() {
  local slot="${1:?set-primary needs a slot}"; is_valid_slot "${slot}" || die "invalid slot '${slot}'"
  load_state
  local rest="" s
  for s in ${BOOT_ORDER}; do [[ "${s}" == "${slot}" ]] || rest+="${s} "; done
  BOOT_ORDER="$(printf '%s %s' "${slot}" "${rest}" | tr -s ' ')"; BOOT_ORDER="${BOOT_ORDER% }"
  set_left "${slot}" "${BOOT_ATTEMPTS}"
  store_state
}

# get-state <slot> — "good" while the slot is in BOOT_ORDER and has attempts left;
# "bad" once exhausted/removed. (RAUC custom backend `get-state` contract.)
cmd_get_state() {
  local slot="${1:?get-state needs a slot}"; is_valid_slot "${slot}" || die "invalid slot '${slot}'"
  load_state
  if in_order "${slot}" && (( "$(left_of "${slot}")" > 0 )); then
    printf 'good\n'
  else
    printf 'bad\n'
  fi
}

# set-state <slot> good|bad — good: reset attempts (slot proved itself this boot).
# bad: zero attempts AND remove from BOOT_ORDER so the selector skips it.
cmd_set_state() {
  local slot="${1:?set-state needs a slot}" state="${2:?set-state needs good|bad}"
  is_valid_slot "${slot}" || die "invalid slot '${slot}'"
  load_state
  case "${state}" in
    good)
      set_left "${slot}" "${BOOT_ATTEMPTS}"
      in_order "${slot}" || BOOT_ORDER="$(printf '%s %s' "${BOOT_ORDER}" "${slot}" | tr -s ' ')"
      ;;
    bad)
      set_left "${slot}" 0
      local rest="" s
      for s in ${BOOT_ORDER}; do [[ "${s}" == "${slot}" ]] || rest+="${s} "; done
      BOOT_ORDER="$(printf '%s' "${rest}" | tr -s ' ')"; BOOT_ORDER="${BOOT_ORDER% }"
      if [[ "${BOOT_STATE_KEEP_LAST_SLOT}" == "1" ]]; then
        [[ -n "${BOOT_ORDER}" ]] || BOOT_ORDER="${slot}"
      fi
      ;;
    *) die "set-state: state must be 'good' or 'bad' (got '${state}')" ;;
  esac
  store_state
}

# mark-good <slot> — convenience alias of `set-state <slot> good` (the post-boot
# confirmation RAUC/ceralive runs once the new slot is verified healthy).
cmd_mark_good() { cmd_set_state "${1:?mark-good needs a slot}" good; }

# boot-select — BOOTLOADER SIMULATION (the userspace twin of boot.scr / grub.cfg).
# Choose the active slot (first in BOOT_ORDER with LEFT>0; else head as last
# resort), DECREMENT its counter, persist, and print "<slot> <rootfs_partlabel>".
# Each call models one boot attempt: an OS that never `mark-good`s itself bleeds
# the counter to 0 and the next call falls through to the other slot — automatic
# rollback.
cmd_boot_select() {
  load_state
  local chosen="" s
  for s in ${BOOT_ORDER}; do
    if (( "$(left_of "${s}")" > 0 )); then chosen="${s}"; break; fi
  done
  if [[ -z "${chosen}" ]]; then
    # Every slot exhausted — last-resort boot the head of BOOT_ORDER, no decrement
    # (there is nothing left to spend; recovery is an external reflash).
    chosen="${BOOT_ORDER%% *}"
    printf '%s %s\n' "${chosen}" "$(slot_partlabel "${chosen}")"
    return 0
  fi
  set_left "${chosen}" "$(( "$(left_of "${chosen}")" - 1 ))"
  store_state
  printf '%s %s\n' "${chosen}" "$(slot_partlabel "${chosen}")"
}

cmd_dump() {
  load_state
  boot_state_dump_backend
  printf 'BOOT_ORDER=%s\n' "${BOOT_ORDER}"
  printf 'BOOT_A_LEFT=%s\n' "${BOOT_A_LEFT}"
  printf 'BOOT_B_LEFT=%s\n' "${BOOT_B_LEFT}"
}

# boot_state_command_lines — the command half of every adapter's usage text, so
# the two platforms cannot drift on a surface RAUC treats as identical.
boot_state_command_lines() {
  cat <<'EOF'
  init [--attempts N] [--single-slot]   write fresh A/B state
  get-order                             print BOOT_ORDER
  get-left <A|B>                        print remaining attempts for a slot
  get-primary                           print the slot that will boot
  set-primary <A|B>                     activate a slot (front of order + reset)
  get-state <A|B>                       print "good" or "bad"
  set-state <A|B> <good|bad>            mark a slot good (reset) or bad (drop)
  mark-good <A|B>                       alias of: set-state <A|B> good
  boot-select                           bootloader sim: pick+decrement+persist
  dump                                  print full state
EOF
}

boot_state_main() {
  local cmd="${1:-}"; shift || true
  case "${cmd}" in
    init)        cmd_init "$@" ;;
    get-order)   cmd_get_order ;;
    get-left)    cmd_get_left "$@" ;;
    get-primary) cmd_get_primary ;;
    set-primary) cmd_set_primary "$@" ;;
    get-state)   cmd_get_state "$@" ;;
    set-state)   cmd_set_state "$@" ;;
    mark-good)   cmd_mark_good "$@" ;;
    boot-select) cmd_boot_select ;;
    dump)        cmd_dump ;;
    -h|--help|"") boot_state_usage; [[ -n "${cmd}" ]] ;;
    *) boot_state_usage; die "unknown command '${cmd}'" ;;
  esac
}
