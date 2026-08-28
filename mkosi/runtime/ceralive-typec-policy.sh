#!/bin/bash
#
# ceralive-typec-policy — preserve the connector's dual-role policy and request
# host data role whenever a settled attach leaves the board as a sink/device.
#
# The connector remains DRP permanently. Charger and power-bank peers must still
# be able to make the board a sink, so this policy never changes the connector's
# supported port role or its device-tree Try preference. DR_SWAP eligibility is
# deliberately role-only: a charge-only peer may reject the host request, which
# is harmless because the write/readback path stops after two logged attempts.
#
# PR_SWAP is intentionally not implemented. Todo 20 recorded MIXED, not the
# required zero-failure ACCEPTED verdict, and todo 26 records the same hardware
# result in the kernel-patch repository. Evidence:
#   rk3588-kernel-patches/README.md
#   rk3588-kernel-patches/docs/UPSTREAM-STATUS.md
# The camera-identification condition applied only to that omitted PR_SWAP path.
# Consequently this script has no code path that writes the live power role.
# The connector mode and preferred-role attributes are likewise read-only policy
# owned by the kernel/device tree; the sole writable surface here is data_role.
#
# udev starts the systemd oneshot on partner and port add events. The boot enable
# is a second coldplug path, so every run inspects CURRENT sysfs state and is safe
# when the partner was already attached before userspace started.
#
# Test seams (production uses every default):
#   CERALIVE_TYPEC_CLASS_DIR   Type-C class dir (default /sys/class/typec)
#   CERALIVE_TYPEC_PORT        connector name (default port0)
#   CERALIVE_TYPEC_WAIT        settle deadline seconds (default 10)
#   CERALIVE_TYPEC_POLL        settle poll interval seconds (default 0.25)
#   CERALIVE_TYPEC_DATA_ROLE_WRITE write target (default current data_role;
#                                  test-only rejected/readback seam)

set -uo pipefail

CLASS_DIR="${CERALIVE_TYPEC_CLASS_DIR:-/sys/class/typec}"
PORT="${CERALIVE_TYPEC_PORT:-port0}"
WAIT_SECONDS="${CERALIVE_TYPEC_WAIT:-10}"
POLL_INTERVAL="${CERALIVE_TYPEC_POLL:-0.25}"

log() { printf 'ceralive-typec-policy: %s\n' "$*"; }
die() { printf 'ceralive-typec-policy: %s\n' "$*" >&2; exit 1; }

[[ "${WAIT_SECONDS}" =~ ^[0-9]+$ ]] || die "CERALIVE_TYPEC_WAIT must be an unsigned integer"

PORT_DIR="${CLASS_DIR}/${PORT}"
PARTNER_DIR="${PORT_DIR}-partner"
DATA_ROLE="${PORT_DIR}/data_role"
POWER_ROLE="${PORT_DIR}/power_role"
DATA_ROLE_WRITE="${CERALIVE_TYPEC_DATA_ROLE_WRITE:-${DATA_ROLE}}"

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

if [[ ! -d "${CLASS_DIR}" ]]; then
  log "no Type-C connector class at ${CLASS_DIR} — nothing to inspect"
  exit 0
fi

# A port-add event without a partner is not an attachment. Returning immediately
# avoids imposing the settle deadline on ordinary boot while the partner-add rule
# and the enabled boot service still cover live attach and coldplug respectively.
if [[ ! -e "${PARTNER_DIR}" ]]; then
  log "${PORT} has no attached partner — no action"
  exit 0
fi

deadline=$((SECONDS + WAIT_SECONDS))
while :; do
  if [[ -r "${POWER_ROLE}" && -r "${DATA_ROLE}" ]]; then
    power="$(active_role "${POWER_ROLE}")"
    data="$(active_role "${DATA_ROLE}")"

    if [[ "${power}" != "sink" || "${data}" != "device" ]]; then
      log "${PORT} settled as power_role=${power:-unknown} data_role=${data:-unknown} — no data-role swap needed"
      exit 0
    fi

    break
  fi

  if (( SECONDS >= deadline )); then
    log "${PORT} role attributes did not settle within ${WAIT_SECONDS}s — no action"
    exit 0
  fi
  sleep "${POLL_INTERVAL}"
done

for attempt in 1 2; do
  log "DR_SWAP attempt ${attempt}/2: requesting ${PORT} data_role=host"
  if ! printf '%s\n' host >"${DATA_ROLE_WRITE}"; then
    log "WARNING: DR_SWAP attempt ${attempt}/2 write was rejected"
    continue
  fi

  data="$(active_role "${DATA_ROLE}")"
  if [[ "${data}" == "host" ]]; then
    log "DR_SWAP attempt ${attempt}/2 succeeded: ${PORT} data_role=host"
    exit 0
  fi
  log "WARNING: DR_SWAP attempt ${attempt}/2 readback is '${data:-unknown}', expected 'host'"
done

die "DR_SWAP failed after 2 attempts; leaving ${PORT} dual-role policy unchanged"
