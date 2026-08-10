#!/bin/bash
#
# ceralive-typec-source — pin the board's USB-C connector to the Type-C SOURCE
# (power/host) role so the capture camera enumerates deterministically.
#
# WHY (root cause, confirmed on real Rock 5B+ hardware 2026-07-30, repeatedly,
# including immediately after a cold power-cycle):
#
#   The connector at /sys/class/typec/port0 is an FUSB302 TCPM port
#   (feac0000.i2c/i2c-4/4-0022) driving the DWC3 controller fc000000.usb through
#   a usb-role-switch. Its device-tree description leaves it a DRP (dual-role)
#   port, so every fresh boot comes up with `port_type` = `[dual] source sink`.
#   A DRP port does not decide its role — it TOGGLES, and the role is settled by
#   the Try.SRC/Try.SNK arbitration in the CC state machine against whatever is
#   on the other end of the cable. The DJI Osmo Pocket 3 is itself dual-role, so
#   both ends toggle and the arbitration is a genuine race with no stable winner:
#   the TCPM log shows the port cycling `SNK_TRY_WAIT -> SRC_TRYWAIT` instead of
#   converging.
#
#   When that race resolves the wrong way the SoC ends up in DEVICE role. It is
#   then not "slow to see the camera" — it is physically incapable of seeing it,
#   because its own controller is running as a USB peripheral. The camera's bus
#   (usb9/9-1) is entirely absent from /sys/bus/usb/devices/, which is the
#   long-standing "camera sometimes isn't detected over USB-C" complaint.
#
#   Forcing `port_type` to `source` removes the arbitration altogether: the port
#   is source-only, never offers itself as a sink, and the camera enumerates
#   within seconds on every attempt (measured 1-19 s from cable insert to the
#   full UVC mode switch across repeated live runs).
#
# This is deliberately the ONLY thing this script touches. Do NOT extend it to
# unbind/rebind the dwc3 platform driver as a "stronger" reset: doing that by
# hand wedges a kernel worker on this board (separate, confirmed defect).
#
# WHY A BOUNDED POLL AND NOT A SLEEP: /sys/class/typec/port0 is created when the
# fusb302 driver probes, which happens asynchronously during boot and is ordered
# against i2c bring-up, not against any systemd target. A fixed sleep would be
# either too short (silently no-op) or a permanent boot tax. This polls for the
# attribute until a deadline and gives up cleanly.
#
# WHY THE BRACKET PARSING: the kernel prints the WHOLE menu with the active entry
# in brackets — a DRP port at rest reads `[dual] source sink`, and once forced it
# reads `dual [source] sink`. A naive `[ "$(cat port_type)" = source ]` idempotency
# check is therefore never true and would rewrite the attribute on every boot;
# worse, a udev `ATTR{port_type}=="dual"` match would never fire at all.
#
# Test seams (production uses every default):
#   CERALIVE_TYPEC_CLASS_DIR  — Type-C class dir      (default /sys/class/typec)
#   CERALIVE_TYPEC_PORT       — connector to pin      (default port0)
#   CERALIVE_TYPEC_WAIT       — poll deadline seconds (default 30)
#   CERALIVE_TYPEC_POLL       — poll interval seconds (default 0.25)

set -euo pipefail

CLASS_DIR="${CERALIVE_TYPEC_CLASS_DIR:-/sys/class/typec}"
PORT="${CERALIVE_TYPEC_PORT:-port0}"
WAIT_SECONDS="${CERALIVE_TYPEC_WAIT:-30}"
POLL_INTERVAL="${CERALIVE_TYPEC_POLL:-0.25}"
WANTED_ROLE="source"

log() { printf 'ceralive-typec-source: %s\n' "$*"; }
die() { printf 'ceralive-typec-source: %s\n' "$*" >&2; exit 1; }

[[ "${WAIT_SECONDS}" =~ ^[0-9]+$ ]] || die "CERALIVE_TYPEC_WAIT must be an unsigned integer"

ATTR="${CLASS_DIR}/${PORT}/port_type"

# active_role <file> — the entry the kernel marked active. `[dual] source sink`
# -> dual. Falls back to the raw trimmed value for a kernel that ever drops the
# brackets, so the idempotency check degrades to "compare literally" rather than
# to "always rewrite".
active_role() {
  local raw token
  raw="$(cat -- "$1")"
  token="$(printf '%s\n' "${raw}" | sed -n 's/.*\[\([a-z_]\{1,\}\)\].*/\1/p')"
  if [[ -n "${token}" ]]; then
    printf '%s\n' "${token}"
  else
    printf '%s\n' "${raw//[[:space:]]/}"
  fi
}

# A board with no Type-C connector class at all (x86, or a kernel without
# CONFIG_TYPEC) has nothing to pin — that is a clean no-op, not a failure.
if [[ ! -d "${CLASS_DIR}" ]]; then
  log "no Type-C connector class at ${CLASS_DIR} — nothing to pin"
  exit 0
fi

# Bounded poll for the TCPM-created attribute (see WHY A BOUNDED POLL above).
deadline=$((SECONDS + WAIT_SECONDS))
while [[ ! -e "${ATTR}" ]]; do
  if (( SECONDS >= deadline )); then
    log "WARNING: ${ATTR} did not appear within ${WAIT_SECONDS}s — leaving the connector at its default role"
    exit 0
  fi
  sleep "${POLL_INTERVAL}"
done

current="$(active_role "${ATTR}")"
if [[ "${current}" == "${WANTED_ROLE}" ]]; then
  log "${PORT} is already ${WANTED_ROLE} — no change"
  exit 0
fi

log "pinning ${PORT} from '${current}' to '${WANTED_ROLE}' (DRP Try.SRC/Try.SNK arbitration must not decide the camera's fate)"
printf '%s\n' "${WANTED_ROLE}" >"${ATTR}" \
  || die "could not write '${WANTED_ROLE}' to ${ATTR}"

# The kernel commits port->port_type synchronously once the TCPM accepts the
# request, so a read-back is a real confirmation and not a timing guess.
current="$(active_role "${ATTR}")"
[[ "${current}" == "${WANTED_ROLE}" ]] \
  || die "${ATTR} still reports '${current}' after writing '${WANTED_ROLE}'"

log "${PORT} pinned to ${WANTED_ROLE}"
exit 0
