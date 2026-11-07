#!/bin/bash
#
# ceralive-typec-policy — request host data role on settled sink/device attaches.
#
# Rock 5B+ exception (CeraUI#414): its kernel must start sink-first so a front
# charger cannot cut the board's only supply during probe. Only a confirmed back
# input (SARADC channel 6, two readings) permits source preference and a bounded
# source->dual cycle to make an attached camera charge. Absent/unknown back power
# leaves the connector alone. Other boards retain their existing DR_SWAP policy.
# PR_SWAP is never requested: the proven correction is a port_type cycle, always
# restoring dual, rather than writing power_role. A tmpfs marker suppresses the
# cycle's partner-add recursion; a failed-attach marker prevents charger loops.
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
#   CERALIVE_TYPEC_DT_ROOT     device tree (default /proc/device-tree)
#   CERALIVE_TYPEC_IIO_DIR     IIO devices (default /sys/bus/iio/devices)
#   CERALIVE_TYPEC_RUN_DIR     volatile state (default /run/ceralive-typec)
#   CERALIVE_TYPEC_ADC_RETRY   unknown ADC retry seconds (default 15)
#   CERALIVE_TYPEC_MODE        recheck skips ADC retry and the DR_SWAP loop
#   CERALIVE_TYPEC_SETTLED_POWER_ROLE post-cycle readback (default power_role)
#   CERALIVE_TYPEC_NOPARTNER_MAX      recheck cycles per boot with no partner (default 3)
#   CERALIVE_TYPEC_NOPARTNER_SPACING  seconds between those cycles (default 30)

set -uo pipefail

CLASS_DIR="${CERALIVE_TYPEC_CLASS_DIR:-/sys/class/typec}"
PORT="${CERALIVE_TYPEC_PORT:-port0}"
WAIT_SECONDS="${CERALIVE_TYPEC_WAIT:-10}"
POLL_INTERVAL="${CERALIVE_TYPEC_POLL:-0.25}"

log() { printf 'ceralive-typec-policy: %s\n' "$*"; }
die() { printf 'ceralive-typec-policy: %s\n' "$*" >&2; exit 1; }

[[ "${WAIT_SECONDS}" =~ ^[0-9]+$ ]] || die "CERALIVE_TYPEC_WAIT must be an unsigned integer"
NOPARTNER_MAX="${CERALIVE_TYPEC_NOPARTNER_MAX:-3}"
NOPARTNER_SPACING="${CERALIVE_TYPEC_NOPARTNER_SPACING:-30}"
[[ "${NOPARTNER_MAX}" =~ ^[0-9]+$ && "${NOPARTNER_SPACING}" =~ ^[0-9]+$ ]] \
  || die "CERALIVE_TYPEC_NOPARTNER_MAX and _SPACING must be unsigned integers"

PORT_DIR="${CLASS_DIR}/${PORT}"
PARTNER_DIR="${PORT_DIR}-partner"
DATA_ROLE="${PORT_DIR}/data_role"
POWER_ROLE="${PORT_DIR}/power_role"
DATA_ROLE_WRITE="${CERALIVE_TYPEC_DATA_ROLE_WRITE:-${DATA_ROLE}}"
RUN_DIR="${CERALIVE_TYPEC_RUN_DIR:-/run/ceralive-typec}"
MODE="${CERALIVE_TYPEC_MODE:-normal}"
rock_settled_source=0

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

rock_back_power_correction() {
  local adc first second decision=unknown previous="" retry deadline stamp=0
  local settled_power identity=unknown original_port_type
  local blind=0 tries=0 last=0 now
  retry="${CERALIVE_TYPEC_ADC_RETRY:-15}"
  [[ "${MODE}" != recheck ]] || retry=0
  [[ "${retry}" =~ ^[0-9]+$ ]] || die "CERALIVE_TYPEC_ADC_RETRY must be an unsigned integer"

  # A detached partner starts a new attach, regardless of the current ADC result.
  if [[ ! -e "${PARTNER_DIR}" ]]; then
    rm -f "${RUN_DIR}/failed"
  fi
  deadline=$((SECONDS + retry))
  while :; do
    for adc in "${CERALIVE_TYPEC_IIO_DIR:-/sys/bus/iio/devices}"/iio:device*; do
      [[ -r "${adc}/name" && "$(cat "${adc}/name")" == fec10000.adc ]] || continue
      first="$(cat "${adc}/in_voltage6_raw" 2>/dev/null)"
      sleep 0.1
      second="$(cat "${adc}/in_voltage6_raw" 2>/dev/null)"
      if [[ "${first}" =~ ^[0-9]+$ && "${second}" =~ ^[0-9]+$ ]]; then
        if (( 10#${first} >= 500 && 10#${second} >= 500 )); then
          decision=present
        elif (( 10#${first} <= 100 && 10#${second} <= 100 )); then
          decision=absent
        fi
      fi
      break
    done
    [[ "${decision}" == unknown ]] && (( SECONDS < deadline )) || break
    sleep 1
  done
  [[ ! -r "${RUN_DIR}/state" ]] || previous="$(cat "${RUN_DIR}/state")"
  if [[ "${MODE}" != recheck || "${previous}" != "${decision}" ]]; then
    log "INFO: Rock back power=${decision}"
  fi
  printf '%s\n' "${decision}" >"${RUN_DIR}/state" || log "ERROR: cannot record Rock back-power state"
  [[ "${decision}" == present ]] || return 0

  # Set Try.SRC before the no-partner exit, so the next attach needs no reset.
  if [[ ! -r "${PORT_DIR}/preferred_role" ||
        "$(active_role "${PORT_DIR}/preferred_role")" != source ]]; then
    log "INFO: Rock back power present: requesting preferred_role=source"
    if ! printf '%s\n' source >"${PORT_DIR}/preferred_role"; then
      log "ERROR: cannot set Rock source preference"
      return 0
    fi
  fi
  if [[ -e "${PARTNER_DIR}" ]]; then
    # A partner that reappears right after our cycle (a plain charger flaps) must
    # not earn fresh tries; only one that has stayed up for a minute does.
    if [[ -r "${RUN_DIR}/nopartner" ]]; then
      read -r tries last <"${RUN_DIR}/nopartner"
      if [[ ! "${last}" =~ ^[0-9]+$ ]] || (( $(date +%s) - last >= 60 )); then
        rm -f "${RUN_DIR}/nopartner"
      fi
      tries=0 last=0
    fi
    [[ ! -e "${RUN_DIR}/failed" ]] || return 0
  else
    # A camera that advertises Rp but never drives VBUS leaves tcpm waiting in
    # SNK_DEBOUNCED and no partner is ever created. Only the ten-second recheck
    # (coldplug has settled by then) looks for it, a bounded number of times.
    [[ "${MODE}" == recheck ]] || return 0
    [[ ! -r "${RUN_DIR}/nopartner" ]] || read -r tries last <"${RUN_DIR}/nopartner"
    [[ "${tries}" =~ ^[0-9]+$ && "${last}" =~ ^[0-9]+$ ]] || { tries=0; last=0; }
    now="$(date +%s)"
    (( tries < NOPARTNER_MAX && now - last >= NOPARTNER_SPACING )) || return 0
    if ! mkdir -p "${RUN_DIR}" || ! printf '%s %s\n' "$((tries + 1))" "${now}" >"${RUN_DIR}/nopartner"; then
      log "ERROR: cannot record Rock no-partner try — no port_type write"
      return 0
    fi
    blind=1
  fi
  if (( blind == 0 )); then
    deadline=$((SECONDS + WAIT_SECONDS))
    while [[ ! -r "${POWER_ROLE}" ]]; do
      (( SECONDS < deadline )) || return 0
      sleep "${POLL_INTERVAL}"
    done
    [[ -e "${PARTNER_DIR}" && "$(active_role "${POWER_ROLE}")" == sink ]] || return 0
    if [[ -e "${RUN_DIR}/corrected" ]]; then
      stamp="$(stat -c %Y "${RUN_DIR}/corrected")" || return 0
      (( $(date +%s) - stamp >= 10 )) || return 0
    fi
  fi
  original_port_type="$(active_role "${PORT_DIR}/port_type")"
  case "${original_port_type}" in
    dual | sink | source) ;;
    *)
      log "ERROR: cannot record Rock port_type before correction — no port_type write"
      return 0
      ;;
  esac
  if ! mkdir -p "${RUN_DIR}" || ! touch "${RUN_DIR}/corrected"; then
    log "ERROR: cannot record Rock correction marker — no port_type write"
    return 0
  fi
  if (( blind )); then
    log "INFO: Rock back power present, no partner seen: cycling port_type=source then dual (try $((tries + 1))/${NOPARTNER_MAX})"
  else
    log "INFO: Rock back power present: cycling port_type=source then dual"
  fi
  if ! printf '%s\n' source >"${PORT_DIR}/port_type"; then
    log "ERROR: Rock port_type=source write was rejected"
    return 0
  fi
  if ! printf '%s\n' dual >"${PORT_DIR}/port_type"; then
    log "ERROR: Rock port_type=dual write was rejected — retrying restoration"
    if ! printf '%s\n' dual >"${PORT_DIR}/port_type"; then
      log "ERROR: Rock port_type=dual retry was rejected — restoring recorded port_type=${original_port_type}"
      if ! printf '%s\n' "${original_port_type}" >"${PORT_DIR}/port_type"; then
        log "ERROR: Rock port_type=${original_port_type} restoration was rejected — interface rejected every restoration"
      fi
      if [[ -r "${PARTNER_DIR}/identity/id_header" ]]; then
        identity="$(cat "${PARTNER_DIR}/identity/id_header")"
      fi
      printf '%s\n' "${identity}" >"${RUN_DIR}/failed" \
        || log "ERROR: cannot record failed Rock attachment"
      return 1
    fi
  fi

  # The cycle removes and re-adds the partner asynchronously. This wait and its
  # failure receipt also run under the periodic recheck, without any DR_SWAP.
  deadline=$((SECONDS + WAIT_SECONDS))
  rock_settle_deadline="${deadline}"
  settled_power="${CERALIVE_TYPEC_SETTLED_POWER_ROLE:-${POWER_ROLE}}"
  while :; do
    if [[ -e "${PARTNER_DIR}" && -r "${settled_power}" ]]; then
      case "$(active_role "${settled_power}")" in
        source) rock_settled_source=1; return 0 ;;
        sink)
          # A sink read immediately after the write may still be the old attach.
          if (( SECONDS >= deadline )); then
            if [[ -r "${PARTNER_DIR}/identity/id_header" ]]; then
              identity="$(cat "${PARTNER_DIR}/identity/id_header")"
            fi
            break
          fi
          ;;
      esac
    fi
    (( SECONDS < deadline )) || break
    sleep "${POLL_INTERVAL}"
  done
  printf '%s\n' "${identity}" >"${RUN_DIR}/failed" \
    || log "ERROR: cannot record failed Rock attachment"
}

# Check the board before creating state or opening a lock: non-Rock runs retain
# the original behavior, including when the state directory is unwritable.
compat="${CERALIVE_TYPEC_DT_ROOT:-/proc/device-tree}/compatible"
if [[ -r "${compat}" ]] && tr '\0' '\n' <"${compat}" | grep -Fxq 'radxa,rock-5b-plus'; then
  if ! mkdir -p "${RUN_DIR}"; then
    log "ERROR: cannot create Rock Type-C run directory"
  elif { exec {rock_lock}>"${RUN_DIR}/lock"; } 2>/dev/null; then
    if flock -w 20 "${rock_lock}"; then
      # A recorded restoration fault must not reach DR_SWAP or fail media startup.
      rock_back_power_correction || exit 0
      flock -u "${rock_lock}"
    elif [[ "${MODE}" == recheck ]]; then
      log "INFO: Rock correction lock timed out — next tick will recheck"
    else
      log "ERROR: Rock correction lock timed out"
    fi
    exec {rock_lock}>&-
  else
    log "ERROR: cannot open Rock Type-C lock"
  fi
fi
[[ "${MODE}" != recheck && "${rock_settled_source}" == 0 ]] || exit 0

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

# Share the post-cycle deadline rather than adding a third settle budget.
deadline="${rock_settle_deadline:-$((SECONDS + WAIT_SECONDS))}"
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

# A partner that cannot swap (a plain charger has no data role) is a clean stop,
# not a unit failure: the port is left unchanged and the journal keeps the warning.
log "WARNING: DR_SWAP failed after 2 attempts; leaving ${PORT} dual-role policy unchanged"
exit 0
