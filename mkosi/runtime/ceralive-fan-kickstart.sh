#!/bin/bash
#
# ceralive-fan-kickstart — give the board's `pwm-fan` a brief full-PWM nudge the
# instant the kernel's thermal governor first asks it to spin, then put the
# governor's own commanded state straight back.
#
# WHY (measured on a real Orange Pi 5 Plus). The measurement below was taken on
# the Armbian vendor 6.1 BSP kernel, which is RETIRED — the board now runs the
# source-built mainline 7.2 track. The unit is kept because the defect is a BOARD
# fact, not a kernel one: the stiction asymmetry lives in the fan motor and in the
# device tree's `cooling-levels`, and the mainline kernel binds the same `pwm-fan`
# cooling device on the same hardware. Todo 16's board qualification confirmed that
# directly — BOTH Rock 5B+ and Orange Pi 5 Plus, booted on 7.2.0-ceralive-rk3588,
# reported "thermal zones responsive; PWM fan cooling device present". So the
# subject of this unit still exists and is still governed the same way.
#
#   The fan gets stuck at a stop and needs a manual push to start turning. That
#   is NOT the "fan never gets asked to run" problem — ceralive-fan-curve
#   already fixed that by lowering the first `active` trip to 45 °C, and the
#   governor demonstrably does step the fan up at that crossing. It is the
#   NEXT problem: the state it steps up INTO is too weak to break stiction.
#
#     cooling_device*/type      = pwm-fan
#     cooling_device*/max_state = 4
#     of_node/cooling-levels    = 0 70 75 80 100      (out of 255)
#
#   So the FIRST active state (state 1) is 70/255 ~= 27.5 % duty. That is a
#   classic DC-motor stiction asymmetry: enough torque to KEEP a spinning rotor
#   spinning, not enough to START a stopped one. The fan sits energised and
#   stalled, and a fingertip nudge is all it needs — which is exactly the
#   operator's report.
#
#   Upstream Linux agrees this is a real hardware behaviour and has since grown
#   an in-driver fix for it: `fan-stop-to-start-percent` / `fan-stop-to-start-us`
#   in Documentation/devicetree/bindings/hwmon/pwm-fan.yaml, implemented in
#   pwm-fan.c's __set_pwm() as "boost, usleep_range(), then apply the real
#   target". That is a DEVICE-TREE knob, and this pipeline authors no device tree
#   (zero .dts/.dtsi files in the repo) — so even where the driver supports the
#   properties, a board DTS that does not declare them gets no boost, and neither
#   shipped board's DTS does. The equivalent therefore still has to be done from
#   userspace. This unit is a faithful userspace port of that upstream mechanism,
#   including its explicit restore step. Setting the DT properties instead is a
#   kernel-patch change in CERALIVE/rk3588-kernel-patches with its own bench
#   evidence, not a pipeline change.
#
# THE LOAD-BEARING KERNEL FACT: A USERSPACE cur_state WRITE IS **STICKY**
#
#   It is tempting to write max_state and simply walk away, assuming the
#   governor's next scheduled poll overwrites the nudge with whatever the real
#   temperature calls for. That assumption was proven FALSE, and acting on it
#   would leave the fan at 100 % indefinitely. Verified by reading the tree the
#   board ran at the time (armbian/linux-rockchip @ 95e85f6c — the now retired
#   vendor BSP); the same three functions have NOT been re-read against the
#   mainline v7.2 tree, so treat the mechanism as proven there and unverified
#   here. That does not change the design: the restore write is correct either
#   way, because it writes back exactly the state the governor itself commanded,
#   and it is skipped entirely when the governor made a fresher decision during
#   the kick window.
#
#     * drivers/thermal/thermal_sysfs.c cur_state_store() calls
#       cdev->ops->set_cur_state() and does NOT clear cdev->updated.
#     * drivers/thermal/thermal_helpers.c thermal_cdev_update() is
#       `if (!cdev->updated) { __thermal_cdev_update(cdev); ... }` — when
#       cdev->updated is true it re-asserts NOTHING.
#     * drivers/thermal/gov_step_wise.c clears cdev->updated ONLY when its newly
#       computed target differs from the old one
#       (`if (instance->initialized && old_target == instance->target) continue;`).
#
#   Compose those three and the governor's next poll is a no-op for as long as
#   the temperature stays in the same trip band — so the nudge would persist,
#   unbounded, at full speed. Worse, step_wise's get_target_state() derives its
#   next step from the REAL current state (`clamp(cur_state + 1, lower, upper)`),
#   so on a rising trend the governor READS BACK the kicked value and adopts
#   max_state as its own target: the nudge latches itself in.
#
#   Hence the design below: kick, wait a bounded time, then EXPLICITLY write the
#   governor's own commanded state back. That restores the driver's cached state
#   so step_wise's `cur_state + 1` arithmetic resumes from the correct rung, and
#   it leaves the hardware state in agreement with instance->target, which is
#   precisely the consistent condition the governor expects. The governor is
#   never disabled, never overridden beyond the kick window, and its next real
#   decision proceeds exactly as it would have.
#
# WHAT THIS DOES NOT DO
#
#     * does NOT write hwmon pwm1 / pwm1_enable — the cooling device's own
#       cur_state is this board's sanctioned control surface, and driving the
#       hwmon node directly means owning the fan forever, including across
#       suspend and shutdown;
#     * does NOT write thermal_zone*/mode — disabling a zone would also disable
#       its critical trip;
#     * does NOT touch any trip point — that is ceralive-fan-curve's job and
#       this unit deliberately does not overlap with it;
#     * does NOT re-kick while the fan is already spinning — only a genuine
#       0 -> nonzero edge fires, never nonzero -> nonzero and never anything -> 0.
#
# WHY A RESIDENT MONITOR AND NOT A ONESHOT
#
#   Unlike ceralive-fan-curve / ceralive-led-status / ceralive-typec-policy,
#   this cannot be a boot-time oneshot. The fan returns to state 0 whenever the
#   board cools below the trip and re-enters an active state when it warms up
#   again — many times over a device's uptime. Every one of those re-entries is
#   a fresh dead start that needs the same nudge, so the edge has to be watched
#   for the life of the device.
#
# WHY DISCOVERY IS GENERIC AND NOT `cooling_device4`/`hwmon7`
#
#   The cooling-device index is a registration-order artefact: it differs
#   between boards and can move when an unrelated driver's probe order changes.
#   The same hard-won
#   lesson is already written into ceralive-fan-curve. So the device is found by
#   scanning cooling_device*/type for the exact string `pwm-fan`, and BOTH the
#   kick value and the skip decision are read from that device's own max_state —
#   never from a hand-invented "100 %" constant and never from this board's
#   particular `0 70 75 80 100` levels, which are not read at all. This script
#   works purely in cooling-state space, so it is independent of whatever duty
#   cycles a given board's device tree maps those states onto.
#
# BOARD-AGNOSTIC BY CONSTRUCTION. No thermal class, no `pwm-fan` cooling device
# (x86-minipc), or a device whose max_state is below 2 are all INFORMATIONAL
# no-ops that exit 0. max_state < 2 matters specifically: if the only active
# state IS max_state then entering it already commands full PWM and there is no
# room to kick above the target, so kicking would be a pointless write. This
# mirrors upstream's own skip condition, which boosts only when the target duty
# is BELOW the from-stopped duty.
#
# Kernel ABI reference: Documentation/ABI/testing/sysfs-class-thermal
# (`cooling_deviceX/type`, `cooling_deviceX/cur_state`, `cooling_deviceX/max_state`).
#
# Test seams (production uses every default):
#   CERALIVE_FAN_KICK_THERMAL_DIR — thermal class dir     (default /sys/class/thermal)
#   CERALIVE_FAN_KICK_MS          — kick duration, ms     (default 1000)
#   CERALIVE_FAN_KICK_POLL        — poll interval seconds (default 0.25)
#   CERALIVE_FAN_KICK_WAIT        — discovery deadline s  (default 10)
#   CERALIVE_FAN_KICK_MAX_CYCLES  — stop after N polls    (default 0 = run forever)

set -euo pipefail

# 1000 ms. Upstream's in-driver default is 250 ms
# (pwm-fan.c: `ctx->pwm_usec_from_stopped = 250000`, applied as
# usleep_range(250000, 500000) => 250-500 ms), and that is the floor this is
# reasoned from rather than a number picked by feel. Four times that is chosen
# deliberately for three reasons:
#
#   1. Upstream boosts in the SAME pwm_apply that first energises the fan, so
#      its clock starts at the instant of power-on. A polled userspace watcher
#      necessarily applies the boost LATER — up to one poll interval after the
#      governor commanded the state — by which point the rotor is not "about to
#      start" but already energised and stalled. Breaking out of a stall wants
#      more margin than never entering one.
#   2. The 40-80 mm 5 V fans used on these SBCs reach steady-state RPM in
#      roughly 300-800 ms from a dead stop; 1000 ms clears the top of that band
#      while still reading as a brief acoustic transient rather than a fan ramp.
#   3. The risk is asymmetric. Because the kick always ends in an explicit
#      restore, erring long costs a fraction of a second of extra fan noise and
#      nothing else — it can never be a thermal risk and can never strand the
#      fan. Erring short risks not solving the problem at all. When one
#      direction is cheap and the other is a silent non-fix, take the cheap one.
KICK_MILLISECONDS="${CERALIVE_FAN_KICK_MS:-1000}"
readonly KICK_MIN_MILLISECONDS=100
readonly KICK_MAX_MILLISECONDS=5000
readonly WANTED_CDEV_TYPE="pwm-fan"
# A device needs at least an off state, a first active state and something above
# it before a kick can mean anything.
readonly MIN_KICKABLE_MAX_STATE=2

THERMAL_DIR="${CERALIVE_FAN_KICK_THERMAL_DIR:-/sys/class/thermal}"
POLL_INTERVAL="${CERALIVE_FAN_KICK_POLL:-0.25}"
WAIT_SECONDS="${CERALIVE_FAN_KICK_WAIT:-10}"
MAX_CYCLES="${CERALIVE_FAN_KICK_MAX_CYCLES:-0}"

log() { printf 'ceralive-fan-kickstart: %s\n' "$*"; }
warn() { printf 'ceralive-fan-kickstart: WARNING: %s\n' "$*"; }
die() { printf 'ceralive-fan-kickstart: %s\n' "$*" >&2; exit 1; }

[[ "${KICK_MILLISECONDS}" =~ ^[0-9]+$ ]] \
  || die "CERALIVE_FAN_KICK_MS must be an unsigned integer of milliseconds"
(( KICK_MILLISECONDS >= KICK_MIN_MILLISECONDS && KICK_MILLISECONDS <= KICK_MAX_MILLISECONDS )) \
  || die "CERALIVE_FAN_KICK_MS=${KICK_MILLISECONDS} is outside the accepted ${KICK_MIN_MILLISECONDS}..${KICK_MAX_MILLISECONDS} ms band (a nudge must stay a nudge — anything longer is a sustained override of the governor)"
[[ "${WAIT_SECONDS}" =~ ^[0-9]+$ ]] || die "CERALIVE_FAN_KICK_WAIT must be an unsigned integer"
[[ "${MAX_CYCLES}" =~ ^[0-9]+$ ]] || die "CERALIVE_FAN_KICK_MAX_CYCLES must be an unsigned integer"

# `sleep` takes seconds; keep the configured value in whole milliseconds so the
# bound above is expressed in the unit an operator would actually reason about.
KICK_SECONDS="$(printf '%d.%03d' "$(( KICK_MILLISECONDS / 1000 ))" "$(( KICK_MILLISECONDS % 1000 ))")"

read_attr() {
  local raw
  raw="$(cat -- "$1" 2>/dev/null)" || return 1
  printf '%s' "${raw//[[:space:]]/}"
}

write_attr() {
  { printf '%s\n' "$2" >"$1"; } 2>/dev/null
}

if [[ ! -d "${THERMAL_DIR}" ]]; then
  log "no thermal class at ${THERMAL_DIR} — no fan to kick-start"
  exit 0
fi

# --- Discovery -------------------------------------------------------------
# Bounded poll rather than a fixed sleep, for the same reason ceralive-fan-curve
# uses one: the cooling device is created by an asynchronous platform-driver
# probe that is ordered against DT/PWM bring-up, not against any systemd target.
FAN_CDEVS=()
FAN_MAX_STATES=()

find_pwm_fan_cdevs() {
  local cdev type max_state
  FAN_CDEVS=()
  FAN_MAX_STATES=()
  for cdev in "${THERMAL_DIR}"/cooling_device*; do
    [[ -d "${cdev}" ]] || continue
    type="$(read_attr "${cdev}/type")" || continue
    [[ "${type}" == "${WANTED_CDEV_TYPE}" ]] || continue
    max_state="$(read_attr "${cdev}/max_state")" || continue
    [[ "${max_state}" =~ ^[0-9]+$ ]] || continue
    FAN_CDEVS+=("${cdev}")
    FAN_MAX_STATES+=("${max_state}")
  done
  (( ${#FAN_CDEVS[@]} > 0 ))
}

deadline=$(( SECONDS + WAIT_SECONDS ))
while ! find_pwm_fan_cdevs; do
  if (( SECONDS >= deadline )); then
    log "no '${WANTED_CDEV_TYPE}' cooling device under ${THERMAL_DIR} after ${WAIT_SECONDS}s — this board has no fan to kick-start, nothing to do"
    exit 0
  fi
  sleep "${POLL_INTERVAL}"
done

# Drop devices with no room to kick above the first active state.
WATCH_CDEVS=()
WATCH_MAX_STATES=()
for (( i = 0; i < ${#FAN_CDEVS[@]}; i++ )); do
  cdev="${FAN_CDEVS[i]}"
  max_state="${FAN_MAX_STATES[i]}"
  if (( max_state < MIN_KICKABLE_MAX_STATE )); then
    log "${cdev##*/}: max_state=${max_state}, so its only active state already commands full PWM — there is nothing to kick above, skipping it"
    continue
  fi
  WATCH_CDEVS+=("${cdev}")
  WATCH_MAX_STATES+=("${max_state}")
done

if (( ${#WATCH_CDEVS[@]} == 0 )); then
  log "found ${WANTED_CDEV_TYPE} cooling device(s) but none has room for a kick above its first active state — nothing to do"
  exit 0
fi

# --- Prime -----------------------------------------------------------------
# Seed each device's previous state from what it reads RIGHT NOW rather than
# assuming 0. Without this, starting (or restarting) while the fan is already
# spinning would look like a 0 -> nonzero edge and fire a spurious kick.
PREV_STATES=()
for (( i = 0; i < ${#WATCH_CDEVS[@]}; i++ )); do
  cdev="${WATCH_CDEVS[i]}"
  state="$(read_attr "${cdev}/cur_state" || true)"
  [[ "${state}" =~ ^[0-9]+$ ]] || state=0
  PREV_STATES+=("${state}")
  log "watching ${cdev##*/} (max_state=${WATCH_MAX_STATES[i]}, currently state ${state}); a 0 -> nonzero transition gets a ${KICK_MILLISECONDS} ms full-PWM nudge, then the governor's own state is written straight back"
done

# --- Monitor ---------------------------------------------------------------
cycles=0
while :; do
  # Collect this tick's edges first, so that a board with several pwm-fan
  # devices kicks them together and shares ONE kick window instead of
  # serialising a full window per device.
  kick_indices=()
  edge_states=()
  for (( i = 0; i < ${#WATCH_CDEVS[@]}; i++ )); do
    cdev="${WATCH_CDEVS[i]}"
    state="$(read_attr "${cdev}/cur_state" || true)"
    if [[ ! "${state}" =~ ^[0-9]+$ ]]; then
      # The device can disappear if its driver is unbound. That is not an error
      # worth crashing a resident unit over; stop watching and let the next
      # boot rediscover it.
      warn "${cdev##*/}/cur_state is no longer readable — the cooling device went away, exiting"
      exit 0
    fi

    # THE edge test: previously stopped, now active. nonzero -> nonzero (the fan
    # is already turning, and climbing/descending under governor control) and
    # anything -> 0 are both deliberately ignored. A governor that jumped
    # straight to max_state is already commanding full PWM, so there is nothing
    # to kick it above and it is left alone too.
    if (( PREV_STATES[i] == 0 && state > 0 && state < WATCH_MAX_STATES[i] )); then
      kick_indices+=("${i}")
      edge_states[i]="${state}"
    fi
    PREV_STATES[i]="${state}"
  done

  if (( ${#kick_indices[@]} > 0 )); then
    # Phase 1 — boost. The kick value is the device's OWN max_state, read from
    # that device's sysfs at discovery, never a hand-invented "100 %".
    for i in "${kick_indices[@]}"; do
      cdev="${WATCH_CDEVS[i]}"
      log "${cdev##*/}: governor moved it 0 -> ${edge_states[i]} from a dead stop; nudging to state ${WATCH_MAX_STATES[i]} (max_state) for ${KICK_MILLISECONDS} ms to break stiction"
      if ! write_attr "${cdev}/cur_state" "${WATCH_MAX_STATES[i]}"; then
        warn "${cdev##*/}/cur_state refused the kick write — leaving this transition to the governor alone"
      fi
    done

    # Phase 2 — the bounded window. This sleep IS the bound: the full-PWM period
    # lasts exactly this long by construction, rather than lasting until
    # something else happens to take the fan back down.
    sleep "${KICK_SECONDS}"

    # Phase 3 — restore. Mandatory, not cosmetic: see the STICKY note in the
    # header. Without this write the governor would never take the fan back off
    # max_state for as long as the temperature stayed inside one trip band.
    for i in "${kick_indices[@]}"; do
      cdev="${WATCH_CDEVS[i]}"
      now="$(read_attr "${cdev}/cur_state" || true)"
      if [[ "${now}" != "${WATCH_MAX_STATES[i]}" ]]; then
        # Something moved the state during the kick window — that can only be
        # the governor making a fresher decision than the one we interrupted.
        # Its verdict is newer than ours, so leave it exactly as it is.
        log "${cdev##*/}: governor re-asserted state ${now} during the nudge — honouring its newer decision instead of restoring ${edge_states[i]}"
        PREV_STATES[i]="${now}"
        continue
      fi
      if write_attr "${cdev}/cur_state" "${edge_states[i]}"; then
        log "${cdev##*/}: nudge over, governor's own state ${edge_states[i]} handed back; the kernel drives it from here"
        PREV_STATES[i]="${edge_states[i]}"
      else
        warn "${cdev##*/}/cur_state refused the restore write — the fan may stay at state ${WATCH_MAX_STATES[i]} until the governor's next real decision"
        PREV_STATES[i]="${WATCH_MAX_STATES[i]}"
      fi
    done
  fi

  cycles=$(( cycles + 1 ))
  if (( MAX_CYCLES > 0 && cycles >= MAX_CYCLES )); then
    log "reached CERALIVE_FAN_KICK_MAX_CYCLES=${MAX_CYCLES} — exiting (test seam; production runs unbounded)"
    exit 0
  fi

  sleep "${POLL_INTERVAL}"
done
