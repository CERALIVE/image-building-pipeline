#!/usr/bin/env bash
#
# v2/ci/postinst-drift-check.sh — CI gate against postinst <-> customize DRIFT.
#
# WHY (Task 6): the wired runtime executor
#   mkosi.images/runtime/mkosi.postinst.chroot
# and the canonical decomposed modules under customize/*.sh used to carry
# DUPLICATED ("dual-track") logic. A dual track is a silent-divergence hazard:
# one side gets a fix, the other quietly rots (the data-persistence /data skeleton
# actually drifted — incoming/rauc-downloads/hawkbit-updater dirs were missing on
# one track). Task 6 consolidated the shared logic into ONE file,
#   customize/postinst-lib.sh,
# SOURCED by both tracks. This gate FAILS CI the moment that single-source
# property is broken — i.e. drift is reintroduced.
#
# THREE CHECKS:
#   1. SINGLE SOURCE  — every consolidated function is defined EXACTLY once, in
#                       postinst-lib.sh, and is NEVER re-inlined into the runtime
#                       executor or the customize modules (re-inlining == drift).
#   1b. SOURCED       — postinst.chroot, services.sh and data-persistence.sh all
#                       SOURCE postinst-lib.sh (so they actually share that copy).
#   2. PAYLOAD PARITY — the one remaining genuinely dual-track twin, §6 SRTLA
#                       source-policy routing (customize/networking-srtla.sh vs the
#                       inline §6 in postinst.chroot), must emit BYTE-IDENTICAL
#                       on-device files. Their heredoc payloads are diffed by
#                       destination path; any divergence fails.
#   3. LINE-COUNT     — postinst.chroot must not regrow past a ceiling (catches a
#                       bulk re-inline of the ~744 consolidated lines even if it
#                       somehow sidestepped checks 1/2).
#
# Exit 0 iff no drift. Non-zero (1) on any drift, with the offending lines on stderr.
#
# Run:  v2/ci/postinst-drift-check.sh      (also gated via tests/manifest.bats §8)
#
# shellcheck shell=bash

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2_DIR="$(cd "${HERE}/.." && pwd)"
MKOSI="${V2_DIR}/mkosi"

POSTINST="${MKOSI}/mkosi.images/runtime/mkosi.postinst.chroot"
LIB="${MKOSI}/customize/postinst-lib.sh"
SERVICES="${MKOSI}/customize/services.sh"
DATAPERSIST="${MKOSI}/customize/data-persistence.sh"
NETSRTLA="${MKOSI}/customize/networking-srtla.sh"

# postinst.chroot ceiling. Post-consolidation it is ~841 lines; the consolidated
# dual-track was ~744 lines. 950 leaves generous headroom for ordinary edits while
# still catching a re-inline of any one consolidated section (smallest, data-
# persistence, is ~206 lines → 841+206 > 950).
readonly MAX_POSTINST_LINES=950

# Functions consolidated into postinst-lib.sh (Task 6). The single source of truth.
readonly CONSOLIDATED_FUNCS=(
  ensure_group enable_service disable_service
  configure_networking configure_services setup_hostname_service
  setup_data_persistence setup_boot_healthcheck setup_cert_rotation
)

FAIL=0
note() { printf '[drift] %s\n' "$*"; }
ok()   { printf '[drift] OK   %s\n' "$*"; }
bad()  { printf '[drift] FAIL %s\n' "$*" >&2; FAIL=1; }

# defcount <func> <file> — number of TOP-LEVEL `func() {` definitions in <file>.
defcount() {
  grep -cE "^$1\(\) \{" "$2" 2>/dev/null || true
}

# heredoc_for <file> <dest-substr> — print the body of the `cat >DEST <<DELIM`
# here-document whose redirect target contains <dest-substr>. Keyed by destination
# path (stable) rather than delimiter name (ambiguous: postinst.chroot reuses EOF).
heredoc_for() {
  awk -v dest="$2" '
    !f && index($0, "cat ") && index($0, "<<") && index($0, dest) {
      s = $0; sub(/.*<</, "", s); gsub(/[ \t"'"'"']/, "", s); delim = s; f = 1; next
    }
    f && $0 == delim { exit }
    f { print }
  ' "$1"
}

main() {
  note "=== postinst dual-track drift gate (Task 6) ==="

  local f
  for f in "${POSTINST}" "${LIB}" "${SERVICES}" "${DATAPERSIST}" "${NETSRTLA}"; do
    [[ -f "${f}" ]] || bad "missing expected file: ${f}"
  done
  if (( FAIL )); then
    note "aborting: required files missing"
    return 1
  fi

  # --- CHECK 1: single source of truth --------------------------------------
  note "CHECK 1 — consolidated functions defined ONCE (postinst-lib.sh), never re-inlined"
  local fn inlib reinlined inpost insvc indp
  for fn in "${CONSOLIDATED_FUNCS[@]}"; do
    inlib="$(defcount "${fn}" "${LIB}")"
    inpost="$(defcount "${fn}" "${POSTINST}")"
    insvc="$(defcount "${fn}" "${SERVICES}")"
    indp="$(defcount "${fn}" "${DATAPERSIST}")"
    reinlined=$(( inpost + insvc + indp ))
    if [[ "${inlib}" != "1" ]]; then
      bad "  ${fn}: defined ${inlib}× in postinst-lib.sh (expected exactly 1)"
    fi
    if (( reinlined > 0 )); then
      bad "  ${fn}: RE-INLINED (postinst.chroot=${inpost}, services.sh=${insvc}, data-persistence.sh=${indp}) — dual-track drift reintroduced"
    fi
    [[ "${inlib}" == "1" && "${reinlined}" -eq 0 ]] && ok "  ${fn}: single source (postinst-lib.sh)"
  done

  # --- CHECK 1b: both tracks actually source the lib ------------------------
  note "CHECK 1b — runtime executor + customize modules source postinst-lib.sh"
  for f in "${POSTINST}" "${SERVICES}" "${DATAPERSIST}"; do
    if grep -qE 'source[[:space:]]+.*postinst-lib\.sh' "${f}"; then
      ok "  $(basename "${f}") sources postinst-lib.sh"
    else
      bad "  $(basename "${f}") does NOT source postinst-lib.sh"
    fi
  done

  # --- CHECK 2: §6 SRTLA payload parity (remaining dual-track twin) ----------
  note "CHECK 2 — §6 SRTLA payloads byte-identical (networking-srtla.sh vs postinst.chroot §6)"
  local dest a b
  for dest in /etc/iproute2/rt_tables \
              /etc/dhcp/dhclient-exit-hooks.d/srtla-source-routing \
              /etc/NetworkManager/dispatcher.d/90-srtla-wifi-routing; do
    a="$(heredoc_for "${NETSRTLA}" "${dest}")"
    b="$(heredoc_for "${POSTINST}" "${dest}")"
    if [[ -z "${a}" || -z "${b}" ]]; then
      bad "  ${dest}: could not extract payload from BOTH tracks (a=${#a}B, b=${#b}B)"
    elif [[ "${a}" == "${b}" ]]; then
      ok "  ${dest}: payload identical"
    else
      bad "  ${dest}: payload DIVERGED between networking-srtla.sh and postinst.chroot §6"
      diff <(printf '%s\n' "${a}") <(printf '%s\n' "${b}") | sed 's/^/        /' >&2
    fi
  done

  # --- CHECK 3: postinst line-count regression ------------------------------
  note "CHECK 3 — postinst.chroot line-count under the re-inline ceiling"
  local lines
  lines="$(wc -l < "${POSTINST}")"
  if (( lines <= MAX_POSTINST_LINES )); then
    ok "  postinst.chroot=${lines} lines (ceiling ${MAX_POSTINST_LINES})"
  else
    bad "  postinst.chroot=${lines} lines EXCEEDS ceiling ${MAX_POSTINST_LINES} — a consolidated section was likely re-inlined"
  fi

  if (( FAIL )); then
    note "RESULT: DRIFT DETECTED — fix the FAIL lines above (re-source postinst-lib.sh; do not re-inline)"
    return 1
  fi
  note "RESULT: no drift — postinst-lib.sh is the single source of truth; §6 payloads in sync"
  return 0
}

main "$@"
