#!/bin/bash
#
# cert-rotation.sh — on-device activation of channel-delivered intermediate/leaf
# signing certs, verified against the IMMUTABLE root CA (Stage 7, task 42).
#
# WHY THIS EXISTS (cert-work/rauc/README.txt, decisions.md Stage 0g):
#   The device trusts ONE thing forever: the root CA baked into its RAUC keyring at
#   first flash. RAUC has no through-channel root swap — a new root means physical
#   reflash. But the intermediate (<=5y) and leaf (<=2y) below that root MUST be
#   rotatable in the field. A signed cert-rotation .raucb (built by
#   lib/build-cert-rotation-bundle.sh, signed with the CURRENT leaf) is verified by
#   RAUC against the keyring root exactly like any OS bundle, then its install hook
#   drops the NEW intermediate.pem + leaf.pem into CERT_INCOMING_DIR and triggers
#   this script (cert-rotation.service).
#
#   This script is the SECOND, independent gate: before the new certs are trusted
#   for any on-device use it re-verifies the full chain leaf -> intermediate ->
#   ROOT_CA with `openssl verify`, refuses anything that does not chain to the
#   immutable root or is already expired, and only then ATOMICALLY activates them
#   (keeping the previous pair as .prev for recovery). Defense in depth: RAUC
#   verified the bundle signature; we re-verify the delivered material itself.
#
# BAKED IN FROM THE FIRST IMAGE: this script + its units are installed by the
# Runtime layer postinst, so every device can accept a rotation from first flash.
# The mechanism is non-retrofittable by design — a device that never shipped with
# it could only be fixed by reflashing.
#
# SUBCOMMANDS:
#   install        Activate certs staged in CERT_INCOMING_DIR (post-RAUC-install).
#                  No-op (exit 0) when nothing is staged.
#   check-expiry   Log days-to-expiry for the activated certs; WARN under threshold
#                  (weekly cert-rotation-expiry.timer). Monitoring only — exit 0
#                  even when near/over expiry, so it never blocks anything.
#   status         Print the current cert inventory (for operators).
#
# Everything is on /data (survives A/B OS updates). NEVER points at a rootfs slot.
#
# This is a standalone DEVICE script — it does NOT source the repo lib/common.sh
# (not present on the device). DUAL-TRACK: an inline twin lives in
# mkosi.images/runtime/mkosi.postinst.chroot (setup_cert_rotation) — keep in sync.
#
# shellcheck shell=bash

set -euo pipefail

PROG="cert-rotation"

# --- config: defaults first, then /etc/ceralive/cert-rotation.conf overrides -----
CONF="${CERALIVE_CERT_ROTATION_CONF:-/etc/ceralive/cert-rotation.conf}"

CERT_DIR="/data/ceralive/certs"
CERT_INCOMING_DIR="/data/ceralive/certs/incoming"
ROOT_CA="/etc/rauc/ceralive-keyring.pem"
INTERMEDIATE_CERT="/data/ceralive/certs/intermediate.pem"
LEAF_CERT="/data/ceralive/certs/leaf.pem"
EXPIRY_WARN_DAYS="90"

# Test seam: the real tool on device; stubbed in the offline proof harness.
OPENSSL_BIN="${OPENSSL_BIN:-openssl}"

ts()   { date -u +%Y-%m-%dT%H:%M:%SZ; }
log()  { printf '%s %s: %s\n' "$(ts)" "${PROG}" "$*"; }
warn() { printf '%s %s: WARNING: %s\n' "$(ts)" "${PROG}" "$*" >&2; }
fail() { printf '%s %s: FAIL: %s\n' "$(ts)" "${PROG}" "$*" >&2; }

load_conf() {
  if [ -r "${CONF}" ]; then
    log "reading config from ${CONF}"
    # shellcheck disable=SC1090
    . "${CONF}"
  else
    log "no readable ${CONF} — using built-in defaults"
  fi
}

# --- chain verification: the candidate MUST chain to the immutable root ----------
# Builds leaf -> intermediate -> ROOT_CA exactly as the device's RAUC keyring does.
# -purpose any: the leaf carries EKU codeSigning, not the default S/MIME purpose.
verify_chain() {
  local intermediate="$1" leaf="$2"
  if [ ! -s "${ROOT_CA}" ]; then
    fail "immutable root CA ${ROOT_CA} missing or empty — cannot verify a rotation (is the device keyring baked in?)"
    return 1
  fi
  local out rc=0
  out="$("${OPENSSL_BIN}" verify -purpose any -CAfile "${ROOT_CA}" \
    -untrusted "${intermediate}" "${leaf}" 2>&1)" || rc=$?
  if [ "${rc}" -ne 0 ]; then
    fail "candidate chain does NOT verify to the immutable root ${ROOT_CA}: ${out}"
    return 1
  fi
  log "OK: candidate chain verifies leaf -> intermediate -> ${ROOT_CA}"
  return 0
}

# Refuse an already-expired candidate (checkend 0 = "valid right now").
assert_not_expired() {
  local cert="$1" label="$2"
  if ! "${OPENSSL_BIN}" x509 -checkend 0 -noout -in "${cert}" >/dev/null 2>&1; then
    fail "candidate ${label} (${cert}) is ALREADY EXPIRED — refusing to activate"
    return 1
  fi
  return 0
}

# Atomic single-file swap with a .prev backup for recovery.
atomic_install() {
  local src="$1" dst="$2"
  local tmp="${dst}.tmp.$$"
  install -m 0644 "${src}" "${tmp}"
  if [ -e "${dst}" ]; then
    cp -a "${dst}" "${dst}.prev"
  fi
  mv -f "${tmp}" "${dst}"
}

# --- install: activate certs staged by the rotation bundle's install hook ---------
do_install() {
  mkdir -p "${CERT_DIR}"
  local in_int="${CERT_INCOMING_DIR}/intermediate.pem"
  local in_leaf="${CERT_INCOMING_DIR}/leaf.pem"

  if [ ! -e "${in_int}" ] && [ ! -e "${in_leaf}" ]; then
    log "no candidate certs in ${CERT_INCOMING_DIR} — nothing to rotate (no-op)"
    return 0
  fi
  if [ ! -s "${in_int}" ] || [ ! -s "${in_leaf}" ]; then
    fail "incomplete rotation in ${CERT_INCOMING_DIR} — need BOTH intermediate.pem and leaf.pem; leaving current certs untouched"
    return 1
  fi

  log "candidate rotation present — verifying against the immutable root before activating"
  verify_chain "${in_int}" "${in_leaf}" || return 1
  assert_not_expired "${in_int}" "intermediate" || return 1
  assert_not_expired "${in_leaf}" "leaf" || return 1

  atomic_install "${in_int}" "${INTERMEDIATE_CERT}"
  atomic_install "${in_leaf}" "${LEAF_CERT}"
  log "activated rotated certs: ${INTERMEDIATE_CERT}, ${LEAF_CERT} (previous kept as *.prev)"

  # Clear the staging area so re-runs / future boots are no-ops.
  rm -f "${in_int}" "${in_leaf}"
  rmdir "${CERT_INCOMING_DIR}" 2>/dev/null || true

  log "cert rotation complete — new intermediate/leaf in service, root CA unchanged"
  return 0
}

# Days until a cert's notAfter, or empty on parse failure.
days_until_expiry() {
  local cert="$1" end end_epoch now_epoch
  end="$("${OPENSSL_BIN}" x509 -enddate -noout -in "${cert}" 2>/dev/null | cut -d= -f2)"
  [ -n "${end}" ] || return 1
  end_epoch="$(date -u -d "${end}" +%s 2>/dev/null)" || return 1
  now_epoch="$(date -u +%s)"
  printf '%s\n' "$(( (end_epoch - now_epoch) / 86400 ))"
}

# One cert's expiry line; WARN under threshold. Monitoring only — never fails.
report_one() {
  local cert="$1" label="$2" days
  if [ ! -s "${cert}" ]; then
    log "${label}: ${cert} not present — device still on the baked-in chain.pem (no rotation yet)"
    return 0
  fi
  if ! days="$(days_until_expiry "${cert}")"; then
    warn "${label}: could not read notAfter from ${cert}"
    return 0
  fi
  if [ "${days}" -lt 0 ]; then
    warn "${label}: ${cert} has EXPIRED ($(( -days )) days ago) — push a rotation bundle NOW"
  elif [ "${days}" -lt "${EXPIRY_WARN_DAYS}" ]; then
    warn "${label}: ${cert} expires in ${days} days (< ${EXPIRY_WARN_DAYS}) — rotate before expiry"
  else
    log "OK: ${label} (${cert}) expires in ${days} days"
  fi
  return 0
}

do_check_expiry() {
  log "pre-expiry check (warn threshold ${EXPIRY_WARN_DAYS} days)"
  report_one "${INTERMEDIATE_CERT}" "intermediate"
  report_one "${LEAF_CERT}" "leaf"
  return 0
}

do_status() {
  log "cert store: ${CERT_DIR}"
  log "immutable root CA (keyring): ${ROOT_CA}"
  report_one "${INTERMEDIATE_CERT}" "intermediate"
  report_one "${LEAF_CERT}" "leaf"
  return 0
}

usage() {
  cat >&2 <<EOF
Usage: cert-rotation.sh <install|check-expiry|status>

  install        Verify + activate certs staged in CERT_INCOMING_DIR (post-RAUC-install).
  check-expiry   Log days-to-expiry for activated certs; WARN under EXPIRY_WARN_DAYS.
  status         Print the current cert inventory.

Config: ${CONF} (overrides the built-in defaults).
EOF
}

main() {
  load_conf
  case "${1:-install}" in
    install)      do_install ;;
    check-expiry) do_check_expiry ;;
    status)       do_status ;;
    -h | --help)  usage; exit 0 ;;
    *)            usage; exit 2 ;;
  esac
}

main "$@"
