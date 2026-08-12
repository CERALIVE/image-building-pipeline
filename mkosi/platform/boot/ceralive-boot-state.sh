#!/usr/bin/env bash
#
# ceralive-boot-state.sh — RK3588 A/B boot-state helper: the PERSISTENCE ADAPTER
# over the shared slot-state core (RAUC custom backend data layer +
# bootloader-algorithm reference).
#
# The slot model, the CLI, the RAUC semantics and the boot-select algorithm all
# live in ../boot-state-core.sh, byte-for-byte shared with x86. This file adds
# ONLY what U-Boot forces to be different: a CRC-guarded text file on the FAT
# boot partition.
#
# WHY THAT STORAGE (decision D3): the staged RK3588 vendor U-Boot is built
# ENV_IS_NOWHERE — `fw_setenv` does not persist, so
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
# worst outcome). Writes are made durable beside the destination and replaced with
# a same-filesystem `mv -f`; cross-filesystem `mv` is copy-then-unlink, not atomic.
# The BOOT_CRC line lets the reader detect a truncated / empty / byte-flipped file
# even when that write is interrupted by power loss. On ANY validation failure the
# reader falls back to
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

BOOT_STATE_TOOL="ceralive-boot-state"
# A `set-state bad` that would empty BOOT_ORDER keeps the slot as the sole entry:
# the U-Boot selector's last-resort branch boots BOOT_ORDER's head, and an empty
# order would leave it nothing to boot at all.
BOOT_STATE_KEEP_LAST_SLOT=1

# The shared core: beside this file in the repo tree, or at its installed device
# path. CERALIVE_BOOT_STATE_CORE overrides both for a staged/test layout.
BOOT_STATE_CORE="${CERALIVE_BOOT_STATE_CORE:-}"
if [[ -z "${BOOT_STATE_CORE}" ]]; then
  _bs_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for _bs_candidate in "${_bs_here}/../boot-state-core.sh" \
                       /usr/lib/ceralive/boot-state-core.sh; do
    if [[ -r "${_bs_candidate}" ]]; then BOOT_STATE_CORE="${_bs_candidate}"; break; fi
  done
fi
[[ -r "${BOOT_STATE_CORE}" ]] \
  || { printf 'ceralive-boot-state: shared boot-state core not found (set CERALIVE_BOOT_STATE_CORE)\n' >&2; exit 1; }
# shellcheck source=../boot-state-core.sh
source "${BOOT_STATE_CORE}"

# ---------------------------------------------------------------------------
# PERSISTENCE — the only thing that is RK3588-specific. The file is the single
# source of truth; we read it into BOOT_ORDER / BOOT_A_LEFT / BOOT_B_LEFT, the
# shared core mutates them in memory, then we rewrite atomically with a CRC line
# so a corrupt file is detected and healed.
# ---------------------------------------------------------------------------

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
  [[ "${BOOT_A_LEFT}" =~ ^[0-9]+$ ]] || return 1
  [[ "${BOOT_B_LEFT}" =~ ^[0-9]+$ ]] || return 1
  (( BOOT_A_LEFT <= BOOT_ATTEMPTS && BOOT_B_LEFT <= BOOT_ATTEMPTS )) || return 1
  local s seen_a=0 seen_b=0
  for s in ${BOOT_ORDER}; do
    is_valid_slot "${s}" || return 1
    case "${s}" in
      A) (( seen_a == 0 )) || return 1; seen_a=1 ;;
      B) (( seen_b == 0 )) || return 1; seen_b=1 ;;
    esac
  done
  return 0
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
  local tmp; tmp="$(mktemp "${dir}/.boot_state.XXXXXX")" \
    || die "cannot create staging file beside ${STATE_FILE}"
  {
    state_payload
    printf 'BOOT_CRC=%s\n' "$(crc_of_payload)"
  } >"${tmp}"
  sync -f "${tmp}"
  mv -f "${tmp}" "${STATE_FILE}"
  sync -f "${STATE_FILE}"
}

boot_state_dump_backend() { printf 'STATE_FILE=%s\n' "${STATE_FILE}"; }

boot_state_usage() {
  {
    printf 'Usage: ceralive-boot-state <command> [args]\n'
    boot_state_command_lines
    printf '\nState file: $CERALIVE_BOOT_STATE_FILE (default %s)\n' "${STATE_FILE}"
    printf 'Attempts:   $CERALIVE_BOOT_ATTEMPTS (default %s)\n' "${BOOT_ATTEMPTS}"
  } >&2
}

boot_state_main "$@"
