#!/usr/bin/env bash
#
# ceralive-boot-state.sh — A/B boot-state read/write helper (RAUC custom backend
# data layer + bootloader-algorithm reference).
#
# WHY THIS EXISTS (decision D3, .omo/.../decisions.md): the RK3588 vendor U-Boot
# (Armbian 2017.09) is built ENV_IS_NOWHERE — `fw_setenv` does not persist, so
# RAUC's stock `bootloader=uboot` adapter (which drives BOOT_ORDER / bootcount via
# fw_setenv) CANNOT work. The chosen approach is RAUC `bootloader=custom` with the
# boot state kept in a plain text file on the FAT `boot` partition (PARTLABEL=boot,
# mounted /boot). This file is readable BOTH by the in-U-Boot selector script
# (`boot.scr`, via `env import -t`) AND by userspace (RAUC adapter, this script).
#
# STATE FILE FORMAT (newline KEY=VALUE; U-Boot `env import -t` compatible):
#   BOOT_ORDER=A B        # slot bootnames in priority order (head = primary)
#   BOOT_A_LEFT=3         # remaining boot attempts for slot A (3->2->1->0)
#   BOOT_B_LEFT=3         # remaining boot attempts for slot B
#   BOOT_CRC=<cksum>      # POSIX cksum of the three lines above (corruption guard)
# A slot is "good" while it is in BOOT_ORDER and its *_LEFT > 0; it is "bad" once
# *_LEFT reaches 0 (or it is removed from BOOT_ORDER). This mirrors RAUC's own
# u-boot adapter semantics (BOOT_ORDER + BOOT_<name>_LEFT) so the rollback model is
# identical — only the storage backend differs (text file vs. fw_setenv).
#
# CORRUPTION SAFETY (decision: a bricked boot from a half-written FAT file is the
# worst outcome). Writes are made durable by staging the FULL file on tmpfs and
# landing it on the fragile vfat in a SINGLE `mv -f`; the BOOT_CRC line lets the
# reader detect a truncated / empty / byte-flipped file even when that single write
# is interrupted by power loss. On ANY validation failure the reader falls back to
# the safe defaults (BOOT_ORDER="A B", both budgets full) AND rewrites a clean file
# — it NEVER aborts the boot path. A file WITHOUT a BOOT_CRC line is NOT treated as
# corrupt: the in-U-Boot selector rewrites boot_state.txt via `env export`, which
# cannot emit a checksum, so a well-formed no-CRC file is trusted (otherwise the
# bootcount the bootloader just decremented would be wiped on the next userspace read).
#
# BOOTLOADER ALGORITHM (the `boot-select` subcommand) is a faithful userspace twin
# of the on-device `boot.scr` selector: pick the first slot in BOOT_ORDER whose
# *_LEFT > 0, decrement that counter, persist, and emit the slot + its rootfs
# PARTLABEL. When every counter is exhausted it falls back to the head of
# BOOT_ORDER (last-resort boot). Keeping the two in lockstep lets the offline test
# (test-fallback.sh) PROVE the failed-boot -> decrement -> fallback behaviour
# without hardware (MUST-DO: prove fallback via stub).
#
# This script ships ON the device (/usr/bin/ceralive-boot-state) and is also driven
# by the build-time test, so it is deliberately SELF-CONTAINED: no dependency on the
# repo's lib/common.sh (absent on device). Strict mode, no `|| true` swallowing.
#
# shellcheck shell=bash

set -euo pipefail

# State file location + attempt budget are env-overridable (the test points them at
# a tmp file); NEVER hardcode a board specific here.
STATE_FILE="${CERALIVE_BOOT_STATE_FILE:-/boot/boot_state.txt}"
BOOT_ATTEMPTS="${CERALIVE_BOOT_ATTEMPTS:-3}"

# Where the fully-formed file is staged before the single mv onto the FAT partition.
# A tmpfs keeps the slow/fragile vfat touched exactly once; env-overridable for tests.
STATE_STAGEDIR="${CERALIVE_BOOT_STATE_STAGEDIR:-}"

# Valid slot bootnames. Symmetric A/B per the frozen partition contract
# (rootfs_a = slot A, rootfs_b = slot B). Single-slot images carry only A.
readonly VALID_SLOTS=("A" "B")

die() { printf 'ceralive-boot-state: %s\n' "$*" >&2; exit 1; }

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

# ---------------------------------------------------------------------------
# State load/store. The file is the single source of truth; we read it into
# BOOT_ORDER / BOOT_A_LEFT / BOOT_B_LEFT, mutate in memory, then rewrite atomically
# (tmpfs stage -> one mv) with a CRC line so a corrupt file is detected and healed.
# ---------------------------------------------------------------------------
BOOT_ORDER=""
BOOT_A_LEFT=""
BOOT_B_LEFT=""

# The canonical KEY=VALUE body the BOOT_CRC line covers and store_state writes.
state_payload() {
  printf 'BOOT_ORDER=%s\n'  "${BOOT_ORDER}"
  printf 'BOOT_A_LEFT=%s\n' "${BOOT_A_LEFT}"
  printf 'BOOT_B_LEFT=%s\n' "${BOOT_B_LEFT}"
}

# POSIX cksum of the in-memory payload; its first field is the checksum we store.
crc_of_payload() { state_payload | cksum | cut -d' ' -f1; }

# Are the parsed fields well-formed? BOOT_ORDER a sequence of valid slots, counters
# non-negative integers. Catches a truncated write that mangled a data line.
state_fields_valid() {
  [[ -n "${BOOT_ORDER}" ]] || return 1
  local s
  for s in ${BOOT_ORDER}; do is_valid_slot "${s}" || return 1; done
  [[ "${BOOT_A_LEFT}" =~ ^[0-9]+$ ]] || return 1
  [[ "${BOOT_B_LEFT}" =~ ^[0-9]+$ ]] || return 1
  return 0
}

# First writable tmpfs-ish dir for the pre-mv staging file; falls back to the state
# file's own directory (store_state mkdir -p's it) when nothing else is writable.
staging_dir() {
  local d
  for d in "${STATE_STAGEDIR}" /run /tmp "${TMPDIR:-}"; do
    if [[ -n "${d}" && -d "${d}" && -w "${d}" ]]; then printf '%s' "${d}"; return 0; fi
  done
  dirname "${STATE_FILE}"
}

load_state() {
  BOOT_ORDER=""; BOOT_A_LEFT=""; BOOT_B_LEFT=""
  local stored_crc="" corrupt=0
  if [[ ! -f "${STATE_FILE}" ]]; then
    corrupt=1
  elif [[ ! -s "${STATE_FILE}" ]]; then
    corrupt=1
  else
    local key val
    while IFS='=' read -r key val; do
      val="${val%$'\r'}"              # FAT/U-Boot tooling may write CRLF
      case "${key}" in
        BOOT_ORDER)  BOOT_ORDER="${val}" ;;
        BOOT_A_LEFT) BOOT_A_LEFT="${val}" ;;
        BOOT_B_LEFT) BOOT_B_LEFT="${val}" ;;
        BOOT_CRC)    stored_crc="${val}" ;;
      esac
    done <"${STATE_FILE}"
    # Malformed fields are always corruption. A present CRC must match; a MISSING CRC
    # is trusted (the U-Boot selector's env-export write carries none) — see the
    # CORRUPTION SAFETY note in the header for why this must not reset the bootcount.
    if ! state_fields_valid; then
      corrupt=1
    elif [[ -n "${stored_crc}" && "${stored_crc}" != "$(crc_of_payload)" ]]; then
      corrupt=1
    fi
  fi

  if (( corrupt == 1 )); then
    BOOT_ORDER="A B"
    BOOT_A_LEFT="${BOOT_ATTEMPTS}"
    BOOT_B_LEFT="${BOOT_ATTEMPTS}"
    ( store_state ) >/dev/null 2>&1 || true   # best-effort heal; never abort the boot
  fi
}

store_state() {
  local dir; dir="$(dirname "${STATE_FILE}")"
  mkdir -p "${dir}"
  local stage; stage="$(staging_dir)"
  local tmp; tmp="$(mktemp "${stage}/.boot_state.XXXXXX")" \
    || die "cannot create staging file under ${stage}"
  {
    state_payload
    printf 'BOOT_CRC=%s\n' "$(crc_of_payload)"
  } >"${tmp}"
  # The fully-formed file lands on the fragile vfat in ONE mv; if power is lost
  # mid-write the next read sees a short/CRC-less payload, detects it, and heals to
  # safe defaults. Staging on tmpfs keeps the FAT write down to that single mv.
  mv -f "${tmp}" "${STATE_FILE}"
}

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
# Subcommands.
# ---------------------------------------------------------------------------

# init [--attempts N] [--single-slot] — write a fresh state file. Both slots get
# the full attempt budget; A leads. --single-slot drops B entirely (contract §4).
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
  BOOT_ORDER="${slot} ${rest}"; BOOT_ORDER="${BOOT_ORDER%% }"; BOOT_ORDER="$(printf '%s' "${BOOT_ORDER}" | tr -s ' ')"
  BOOT_ORDER="${BOOT_ORDER% }"
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
      ;;
    *) die "set-state: state must be 'good' or 'bad' (got '${state}')" ;;
  esac
  store_state
}

# mark-good <slot> — convenience alias of `set-state <slot> good` (the post-boot
# confirmation RAUC/ceralive runs once the new slot is verified healthy).
cmd_mark_good() { cmd_set_state "${1:?mark-good needs a slot}" good; }

# boot-select — BOOTLOADER SIMULATION (twin of boot.scr). Choose the active slot
# (first in BOOT_ORDER with LEFT>0; else head as last resort), DECREMENT its
# counter, persist, and print "<slot> <rootfs_partlabel>". Each call models one
# boot attempt: an OS that never `mark-good`s itself bleeds the counter to 0 and
# the next call falls through to the other slot — automatic rollback.
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
  printf 'STATE_FILE=%s\n' "${STATE_FILE}"
  printf 'BOOT_ORDER=%s\n' "${BOOT_ORDER}"
  printf 'BOOT_A_LEFT=%s\n' "${BOOT_A_LEFT}"
  printf 'BOOT_B_LEFT=%s\n' "${BOOT_B_LEFT}"
}

usage() {
  cat >&2 <<EOF
Usage: ceralive-boot-state <command> [args]
  init [--attempts N] [--single-slot]   write a fresh state file
  get-order                             print BOOT_ORDER
  get-left <A|B>                        print remaining attempts for a slot
  get-primary                           print the slot that will boot
  set-primary <A|B>                     activate a slot (front of order + reset)
  get-state <A|B>                       print "good" or "bad"
  set-state <A|B> <good|bad>            mark a slot good (reset) or bad (drop)
  mark-good <A|B>                       alias of: set-state <A|B> good
  boot-select                           bootloader sim: pick+decrement+persist
  dump                                  print full state

State file: \$CERALIVE_BOOT_STATE_FILE (default ${STATE_FILE})
Attempts:   \$CERALIVE_BOOT_ATTEMPTS (default ${BOOT_ATTEMPTS})
EOF
}

main() {
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
    -h|--help|"") usage; [[ -n "${cmd}" ]] ;;
    *) usage; die "unknown command '${cmd}'" ;;
  esac
}

main "$@"
