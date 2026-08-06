#!/bin/bash
#
# ceralive-fan-curve — lower the FIRST `active` thermal trip point of the zone
# that drives the board's `pwm-fan` cooling device, so the fan starts moving air
# at a gentle, early temperature instead of staying silent until the kernel
# default.
#
# WHY (measured on a real Rock 5B+, this repo's reference board):
#
#   The RK3588 package thermal zone ships from the device tree with two `active`
#   trips at 55 °C and 65 °C plus one `critical` trip at 115 °C, and its
#   `pwm-fan` cooling device (backed by hwmon `pwmfan`) declares
#   `cooling-levels = <0 120 150 180 210 240 255>`. Those levels are healthy — a
#   Rockchip kernel maintainer confirmed that range reliably spins the fan, which
#   rules out the well-known community "cooling-levels start too low to overcome
#   stiction" defect class. The fan is not broken; it is simply never ASKED to
#   run, because at idle the SoC sits below the first trip.
#
#   So the board is silent, the die creeps up, and the first thing the operator
#   hears is the fan snapping on at 55 °C. Moving the first `active` trip down
#   trades that for a fan that idles gently and rarely has to catch up.
#
# WHAT THIS DOES — AND, MUCH MORE IMPORTANTLY, WHAT IT DOES NOT
#
#   It reduces to ONE sysfs write: the temperature of the FIRST `active`-type
#   trip in the zone bound to the `pwm-fan` cooling device. That is the whole
#   change. Specifically it does NOT:
#
#     * touch `critical` (or `hot`, or `passive`) trips — the 115 °C emergency
#       shutdown threshold is the board's last line of defence and is never
#       read for writing here;
#     * write `thermal_zone*/mode` — disabling a zone would ALSO disable that
#       critical trip, which is categorically unacceptable;
#     * write `cooling_device*/cur_state` or the hwmon `pwm1` node — driving the
#       fan directly means owning it forever, including on shutdown and resume;
#     * poll, monitor, or re-evaluate anything after it exits.
#
#   The kernel's `step_wise` governor already does 100 % of the fan control, and
#   it was live-proven to do it correctly on this board: `cur_state` auto-steps
#   0 -> 1 exactly at a real trip crossing and auto-reverts to 0 when the
#   temperature falls back. The governor is not the problem, so this moves the
#   goalpost rather than replacing the referee. Re-implementing the governor in
#   userspace would be strictly more code and strictly more risk for no gain.
#
# WHY DISCOVERY IS GENERIC AND NOT `thermal_zone0`/`cooling_device4`
#
#   Both index spaces are registration-order artefacts. They differ between
#   boards, between the vendor 6.1 BSP and the mainline/edge tree, and can move
#   when an unrelated driver's probe order changes — this was confirmed
#   differently-numbered on real hardware. Hardcoding either index is how a
#   "working" fix silently starts writing an unrelated zone's trip. So:
#
#     1. scan /sys/class/thermal/cooling_device*/type for the exact string
#        `pwm-fan`;
#     2. for every thermal_zone*, resolve its `cdevN` symlinks and keep the zones
#        whose bound cooling device is one of those;
#     3. in each such zone, walk trip_point_0.. in NUMERIC order and take the
#        FIRST whose trip_point_N_type reads exactly `active`;
#     4. lower that trip's temperature — and only that one.
#
#   Kernel ABI reference: Documentation/ABI/testing/sysfs-class-thermal
#   (`cooling_deviceX/type`, `thermal_zoneX/cdevY`, `thermal_zoneX/
#   trip_point_Y_type`, `thermal_zoneX/trip_point_Y_temp`; temperatures are
#   millidegrees Celsius).
#
# BOARD-AGNOSTIC BY CONSTRUCTION. A board with no thermal class, no `pwm-fan`
# cooling device (x86-minipc), no zone bound to one, or no `active` trip in that
# zone is an INFORMATIONAL no-op that exits 0. None of those is a failure — they
# are the expected shape of hardware that simply does not have this fan.
#
# WHY A BOUNDED POLL AND NOT A SLEEP: the cooling device is created by an
# asynchronous platform-driver probe, ordered against DT/PWM bring-up rather
# than against any systemd target. A fixed sleep would be either too short
# (silently no-op) or a permanent boot tax. This polls to a deadline and gives
# up cleanly. The deadline is deliberately SHORT, because a board that will
# never have a `pwm-fan` pays it on every boot.
#
# WHY A WRITE FAILURE IS A WARNING BUT A BAD READ-BACK IS FATAL: the kernel ABI
# documents `trip_point_Y_temp` as "RO, Optional", so a zone whose driver offers
# no trip-temperature setter is a LEGAL configuration, not a defect — the board
# simply keeps its stock curve and nothing is broken. A write the kernel ACCEPTS
# and then does not honour is a different thing entirely: the hardware shape was
# already proven present, so that is a genuine anomaly and it fails loudly.
#
# Test seams (production uses every default):
#   CERALIVE_FAN_THERMAL_DIR   — thermal class dir     (default /sys/class/thermal)
#   CERALIVE_FAN_TRIP_MILLIC   — target trip, m°C      (default 45000)
#   CERALIVE_FAN_WAIT          — poll deadline seconds (default 10)
#   CERALIVE_FAN_POLL          — poll interval seconds (default 0.25)

set -euo pipefail

# ---------------------------------------------------------------------------
# THE ONE TUNABLE.
#
# 45000 millidegrees Celsius = 45 °C, the temperature at which the fan is asked
# to start. Raise it for a quieter board, lower it for a cooler one.
#
# How 45 was chosen: on a Rock 5B+ at rest the SoC measured 46-52 °C, reaching
# the low 50s under light load. 45 °C therefore sits just under the idle band,
# which is the intended behaviour — the fan idles at its LOWEST cooling level
# (`cooling-levels` entry 1 of 6) and keeps a little air moving, instead of
# staying silent while heat accumulates and then snapping on audibly at 55 °C.
# Be honest about the trade: at the bottom of that idle band the fan will be
# turning most of the time. That is the point, and it is why this is one named
# constant rather than a hardcoded literal buried in the write.
#
# The accepted band is clamped below. In particular a value near the 115 °C
# critical trip is REFUSED: the whole safety property of this script is that it
# only ever lowers an `active` trip, and a tunable that could push one up next
# to `critical` would quietly defeat that.
# ---------------------------------------------------------------------------
FAN_TRIP_MILLICELSIUS="${CERALIVE_FAN_TRIP_MILLIC:-45000}"
readonly FAN_TRIP_MIN_MILLICELSIUS=20000   # 20 °C — below ambient, pointless
readonly FAN_TRIP_MAX_MILLICELSIUS=90000   # 90 °C — must stay far from critical

# The cooling-device `type` string this fix is about. Exact match, never a
# substring: `pwm-fan` must not be confused with a CPUFreq cooling device
# (`thermal-cpufreq-0`) or a devfreq one bound to the very same zone.
readonly WANTED_CDEV_TYPE="pwm-fan"

# The trip type to lower. `critical`/`hot`/`passive` are NEVER candidates.
readonly WANTED_TRIP_TYPE="active"

# Defensive ceiling on the trip-index walk. Trip points are contiguous from 0,
# so the loop breaks on the first gap; this only bounds a pathological sysfs.
readonly MAX_TRIP_INDEX=64

THERMAL_DIR="${CERALIVE_FAN_THERMAL_DIR:-/sys/class/thermal}"
WAIT_SECONDS="${CERALIVE_FAN_WAIT:-10}"
POLL_INTERVAL="${CERALIVE_FAN_POLL:-0.25}"

log() { printf 'ceralive-fan-curve: %s\n' "$*"; }
warn() { printf 'ceralive-fan-curve: WARNING: %s\n' "$*"; }
die() { printf 'ceralive-fan-curve: %s\n' "$*" >&2; exit 1; }

[[ "${WAIT_SECONDS}" =~ ^[0-9]+$ ]] || die "CERALIVE_FAN_WAIT must be an unsigned integer"
[[ "${FAN_TRIP_MILLICELSIUS}" =~ ^[0-9]+$ ]] \
  || die "CERALIVE_FAN_TRIP_MILLIC must be an unsigned integer of millidegrees Celsius"
(( FAN_TRIP_MILLICELSIUS >= FAN_TRIP_MIN_MILLICELSIUS \
   && FAN_TRIP_MILLICELSIUS <= FAN_TRIP_MAX_MILLICELSIUS )) \
  || die "CERALIVE_FAN_TRIP_MILLIC=${FAN_TRIP_MILLICELSIUS} is outside the accepted ${FAN_TRIP_MIN_MILLICELSIUS}..${FAN_TRIP_MAX_MILLICELSIUS} m°C band (a trip near the critical threshold would defeat the point of this unit)"

# read_attr <file> — trimmed contents, or empty when unreadable. Sysfs reads can
# legitimately fail (EACCES on a restricted node, ENODEV on a device that
# disappeared mid-scan), and none of those is a reason to abort the whole run.
read_attr() {
  local raw
  raw="$(cat -- "$1" 2>/dev/null)" || return 1
  printf '%s' "${raw//[[:space:]]/}"
}

# cdev_type_of <zone-cdev-symlink> — the `type` of the cooling device a zone's
# cdevN link points at, resolved WITHOUT canonicalising the path.
#
# Primary key is the symlink's target basename matched against the pwm-fan set
# discovered from /sys/class/thermal/cooling_device*/type, exactly as the sysfs
# layout intends. The fallback reads `<link>/type` directly, which works even if
# a future kernel ever changes the link's spelling — cheap insurance for a
# discovery step whose whole job is to not depend on layout trivia.
link_target_name() {
  local target
  target="$(readlink -- "$1" 2>/dev/null)" || return 1
  target="${target%/}"
  printf '%s' "${target##*/}"
}

# ---------------------------------------------------------------------------
# 1. Is there a thermal class at all?
# ---------------------------------------------------------------------------
if [[ ! -d "${THERMAL_DIR}" ]]; then
  log "no thermal class at ${THERMAL_DIR} — no fan curve to adjust"
  exit 0
fi

# ---------------------------------------------------------------------------
# 2. Bounded poll for a cooling device whose type is exactly `pwm-fan`.
#    Never a fixed sleep: the pwm-fan platform driver probes asynchronously.
# ---------------------------------------------------------------------------
find_pwm_fan_cdevs() {
  local cdev name type
  FAN_CDEVS=()
  for cdev in "${THERMAL_DIR}"/cooling_device*; do
    [[ -d "${cdev}" ]] || continue
    type="$(read_attr "${cdev}/type")" || continue
    [[ "${type}" == "${WANTED_CDEV_TYPE}" ]] || continue
    name="${cdev##*/}"
    FAN_CDEVS+=("${name}")
  done
  (( ${#FAN_CDEVS[@]} > 0 ))
}

deadline=$((SECONDS + WAIT_SECONDS))
while ! find_pwm_fan_cdevs; do
  if (( SECONDS >= deadline )); then
    log "no '${WANTED_CDEV_TYPE}' cooling device under ${THERMAL_DIR} after ${WAIT_SECONDS}s — this board has no fan to re-curve, nothing to do"
    exit 0
  fi
  sleep "${POLL_INTERVAL}"
done

log "found ${WANTED_CDEV_TYPE} cooling device(s): ${FAN_CDEVS[*]}"

# ---------------------------------------------------------------------------
# 3. Which thermal zone(s) drive one of them? Resolve each zone's cdevN links.
# ---------------------------------------------------------------------------
zone_binds_fan() {
  local zone="$1" link name target type candidate
  for link in "${zone}"/cdev*; do
    name="${link##*/}"
    # cdevN only — never cdevN_trip_point / cdevN_weight, which are plain files.
    [[ "${name}" =~ ^cdev[0-9]+$ ]] || continue
    target="$(link_target_name "${link}" || true)"
    if [[ -n "${target}" ]]; then
      for candidate in "${FAN_CDEVS[@]}"; do
        [[ "${target}" == "${candidate}" ]] && return 0
      done
    fi
    # Fallback: ask the pointed-at device for its own type.
    type="$(read_attr "${link}/type" || true)"
    [[ "${type}" == "${WANTED_CDEV_TYPE}" ]] && return 0
  done
  return 1
}

# first_active_trip <zone> — index of the FIRST `active` trip, walked in NUMERIC
# order (a glob would sort trip_point_10 before trip_point_2). Empty when the
# zone has no active trip.
first_active_trip() {
  local zone="$1" i type
  for (( i = 0; i < MAX_TRIP_INDEX; i++ )); do
    [[ -e "${zone}/trip_point_${i}_type" ]] || break
    type="$(read_attr "${zone}/trip_point_${i}_type" || true)"
    if [[ "${type}" == "${WANTED_TRIP_TYPE}" ]]; then
      printf '%s' "${i}"
      return 0
    fi
  done
  return 1
}

matched_zone=0
for zone in "${THERMAL_DIR}"/thermal_zone*; do
  [[ -d "${zone}" ]] || continue
  zone_binds_fan "${zone}" || continue
  matched_zone=1

  zone_name="${zone##*/}"
  zone_type="$(read_attr "${zone}/type" || true)"

  if ! trip_index="$(first_active_trip "${zone}")"; then
    log "${zone_name} (${zone_type:-unknown}) drives the fan but declares no '${WANTED_TRIP_TYPE}' trip — leaving it untouched"
    continue
  fi

  temp_attr="${zone}/trip_point_${trip_index}_temp"
  if [[ ! -e "${temp_attr}" ]]; then
    warn "${zone_name}: trip ${trip_index} is '${WANTED_TRIP_TYPE}' but exposes no temperature attribute — leaving it untouched"
    continue
  fi

  current="$(read_attr "${temp_attr}" || true)"
  if [[ ! "${current}" =~ ^-?[0-9]+$ ]]; then
    warn "${zone_name}: ${temp_attr} reads '${current}', which is not a temperature — leaving it untouched"
    continue
  fi

  # Only ever LOWER. This is what makes the unit idempotent across reboots and
  # re-runs, and it also means the worst a bad tunable can do is nothing.
  if (( current <= FAN_TRIP_MILLICELSIUS )); then
    log "${zone_name}: first ${WANTED_TRIP_TYPE} trip (index ${trip_index}) is already ${current} m°C, at or below the ${FAN_TRIP_MILLICELSIUS} m°C target — no change"
    continue
  fi

  log "${zone_name} (${zone_type:-unknown}): lowering ${WANTED_TRIP_TYPE} trip ${trip_index} from ${current} to ${FAN_TRIP_MILLICELSIUS} m°C (every other trip in this zone, including critical, is left exactly as the kernel set it)"

  # The group's stderr is redirected BEFORE the inner redirect is attempted, so a
  # refused open is reported by our own warn() and not by a raw shell diagnostic.
  if ! { printf '%s\n' "${FAN_TRIP_MILLICELSIUS}" >"${temp_attr}"; } 2>/dev/null; then
    warn "${temp_attr} refused the write — this zone's driver exposes the trip read-only (a legal ABI configuration), so the board keeps its stock fan curve"
    continue
  fi

  # The thermal core commits a trip-temperature change synchronously, so the
  # read-back is a real confirmation rather than a timing guess.
  readback="$(read_attr "${temp_attr}" || true)"
  [[ "${readback}" == "${FAN_TRIP_MILLICELSIUS}" ]] \
    || die "${temp_attr} still reports '${readback}' after accepting a write of '${FAN_TRIP_MILLICELSIUS}'"

  log "${zone_name}: fan now engages at ${FAN_TRIP_MILLICELSIUS} m°C; the kernel step_wise governor drives it from here"
done

if (( matched_zone == 0 )); then
  log "no thermal zone binds a ${WANTED_CDEV_TYPE} cooling device — nothing to do"
fi

exit 0
