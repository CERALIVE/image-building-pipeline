#!/bin/bash
#
# ceralive-led-status — give the board's indicator LEDs a default meaning at
# boot, so an operator gets visual status feedback from a headless device.
#
# WHY (read on real hardware, an Orange Pi 5 Plus, this session):
#
#   The kernel registers three LEDs on that board:
#
#     /sys/class/leds/blue:indicator-1   -> platform/gpio-leds
#     /sys/class/leds/green:indicator-2  -> platform/pwm-leds
#     /sys/class/leds/mmc0::             -> platform/fe2e0000.mmc
#
#   The two INDICATOR LEDs are completely unconfigured: `trigger` reads
#   `[none] …` and `brightness` reads 0. They exist, they are wired, and they do
#   nothing at all — for the entire life of the device. A headless streaming
#   appliance with no screen therefore gives its operator zero visual evidence
#   that it is alive, let alone that it is doing any work.
#
#   `mmc0::` is a DIFFERENT thing and is deliberately out of scope: it is the
#   MMC host controller's OWN activity LED, registered by the mmc core and
#   already driven by the kernel. It is not one of the indicator LEDs and it is
#   not broken.
#
#   There is NO red LED anywhere in the kernel's LED class on this board. The
#   red LED an operator can see next to the others is, on the evidence, a
#   hardwired power-rail indicator with no software visibility at all — nothing
#   here can address it, and looking for it in sysfs is time wasted.
#
# WHAT THIS DOES
#
#   It assigns a TRIGGER to at most two discovered indicator LEDs:
#
#     1st LED -> `heartbeat`  — the standard kernel "system is alive" blink,
#                               load-modulated, so a glance says "the kernel is
#                               scheduling" rather than "power is applied".
#     2nd LED -> `mmc1`       — SD/removable-card activity, so a second glance
#                               says "the board is actually doing I/O".
#
#   Both trigger names are verified to be OFFERED BY THIS KERNEL, read out of
#   the LED's own `trigger` attribute, before anything is written. A kernel that
#   does not offer one of them is logged and skipped, never forced.
#
# WHAT THIS DELIBERATELY DOES NOT DO
#
#   * It never writes `brightness`. Assigning a trigger hands ownership of the
#     LED to the kernel; writing brightness afterwards fights the very trigger
#     just installed, exactly as writing `cur_state` would fight the thermal
#     governor in ceralive-fan-curve. Set the policy, let the kernel drive.
#   * It never touches an `mmc*` LED (see the exclusion rule below) — that is
#     the kernel's own, already-working, SD/eMMC activity LED.
#   * It never re-points an LED that already HAS a trigger, whether from the
#     device tree's `default-trigger`, from a previous run of this unit, or from
#     an operator. An LED that already means something keeps meaning it.
#
# THE EXCLUSION RULE, AND WHY IT IS WRITTEN THIS WAY
#
#   An LED's class name is its identity — the directory basename IS the name —
#   and Linux spells it as colon-separated fields
#   (`devicename:colour:function`, Documentation/leds/leds-class.rst). Real
#   boards populate those fields inconsistently: this board's vendor DTS emits
#   `blue:indicator-1` (colour first, no devicename) while the MMC core emits
#   `mmc0::` (devicename first, no colour and no function). So keying on FIELD
#   POSITION is not portable. The rule is therefore: split the name on `:` and
#   reject the LED if ANY field matches a reserved pattern.
#
#     * `mmc[0-9]*` — an MMC host's own activity LED, kernel-managed.
#     * `power`     — a power-rail indicator. Its whole job is to mean
#                     "this board has power"; repurposing it for a heartbeat
#                     would destroy information rather than add it.
#
#   That is the entire list, on purpose. A broader denylist would start guessing
#   at vendor spellings, and a name-based ALLOWLIST would be worse still: the
#   names on this board are `indicator-1` / `indicator-2`, which carry no
#   semantics whatsoever, so there is nothing meaningful to match on. Anything
#   left after the two exclusions is, by construction, an unclaimed indicator.
#
# WHY NOTHING IS HARDCODED
#
#   `blue:indicator-1` / `green:indicator-2` are vendor DTS labels. They differ
#   per board, per kernel tree, and would differ again the moment the DT gains a
#   proper `function` property. Matching either string is how a "working" fix
#   silently stops working on the next board. Discovery is therefore purely
#   structural: enumerate, exclude, sort for determinism, take the first two.
#   Same principle as ceralive-fan-curve's refusal to hardcode `thermal_zone0`.
#
# WHY A BOUNDED POLL AND NOT A SLEEP: the indicator LEDs come from the
# `gpio-leds` and `pwm-leds` platform drivers, which probe asynchronously and
# are ordered against GPIO/PWM bring-up rather than against any systemd target.
# A fixed sleep would be either too short (silently no-op) or a permanent boot
# tax. This polls to a short deadline and gives up cleanly — a board with no
# LEDs at all must not pay for one that has them.
#
# BOARD-AGNOSTIC BY CONSTRUCTION. No LED class, zero candidate LEDs, one
# candidate, or five candidates are all informational, exit-0 outcomes. Only a
# write the kernel ACCEPTS and then does not honour is fatal, because by then
# the hardware shape has already been proven present.
#
# Test seams (production uses every default):
#   CERALIVE_LED_CLASS_DIR   — LED class dir         (default /sys/class/leds)
#   CERALIVE_LED_TRIGGERS    — ordered trigger list  (default "heartbeat mmc1")
#   CERALIVE_LED_WAIT        — poll deadline seconds (default 10)
#   CERALIVE_LED_POLL        — poll interval seconds (default 0.25)

set -euo pipefail

# ---------------------------------------------------------------------------
# THE POLICY, IN ONE PLACE.
#
# An ORDERED list: the Nth discovered indicator LED gets the Nth trigger. More
# LEDs than triggers means the surplus is left alone (and logged); fewer LEDs
# than triggers means the surplus triggers are simply unused. Both are normal.
#
# `heartbeat` first because it is the one signal that is meaningful on every
# board and in every state — it says the kernel is running. `mmc1` second
# because "the board is touching storage" is the next most useful thing an
# operator can read from across a room, and it is distinct from the heartbeat's
# steady double-blink. Both are stock kernel triggers and both were confirmed
# present in this board's own `trigger` menu.
# ---------------------------------------------------------------------------
read -r -a WANTED_TRIGGERS <<<"${CERALIVE_LED_TRIGGERS:-heartbeat mmc1}"

# Name FIELDS that disqualify an LED from being treated as a free indicator.
# See "THE EXCLUSION RULE" above — deliberately two entries, not a denylist.
readonly RESERVED_FIELD_PATTERNS=('mmc[0-9]*' 'power')

LED_CLASS_DIR="${CERALIVE_LED_CLASS_DIR:-/sys/class/leds}"
WAIT_SECONDS="${CERALIVE_LED_WAIT:-10}"
POLL_INTERVAL="${CERALIVE_LED_POLL:-0.25}"

log() { printf 'ceralive-led-status: %s\n' "$*"; }
warn() { printf 'ceralive-led-status: WARNING: %s\n' "$*"; }
die() { printf 'ceralive-led-status: %s\n' "$*" >&2; exit 1; }

[[ "${WAIT_SECONDS}" =~ ^[0-9]+$ ]] || die "CERALIVE_LED_WAIT must be an unsigned integer"
(( ${#WANTED_TRIGGERS[@]} > 0 )) || die "CERALIVE_LED_TRIGGERS must name at least one trigger"

# active_trigger <trigger-file> — the entry the kernel marked active. The
# attribute prints the WHOLE menu with the active entry in brackets
# (`[none] rfkill-any heartbeat mmc0 mmc1 …`), so a naive literal compare is
# never true — the same bracket trap ceralive-typec-source documents for
# `port_type`. Falls back to the raw trimmed value if a kernel ever drops the
# brackets, which degrades to "compare literally" rather than "always rewrite".
active_trigger() {
  local raw token
  raw="$(cat -- "$1" 2>/dev/null)" || return 1
  token="$(printf '%s\n' "${raw}" | sed -n 's/.*\[\([^][]\{1,\}\)\].*/\1/p')"
  if [[ -n "${token}" ]]; then
    printf '%s' "${token}"
  else
    printf '%s' "${raw//[[:space:]]/}"
  fi
}

# trigger_offered <trigger-file> <name> — is <name> in the kernel's own menu for
# this LED? Whitespace-delimited word match, with the active entry's brackets
# stripped first so an already-selected trigger still counts as offered.
trigger_offered() {
  local raw word
  raw="$(cat -- "$1" 2>/dev/null)" || return 1
  raw="${raw//[/ }"
  raw="${raw//]/ }"
  for word in ${raw}; do
    [[ "${word}" == "$2" ]] && return 0
  done
  return 1
}

# is_reserved <led-name> — true when any colon-separated field of the name
# matches a reserved pattern (see THE EXCLUSION RULE).
is_reserved() {
  local name="$1" field pattern
  local IFS=':'
  # Deliberate field split on the LED name's colons (IFS=':' set above).
  # shellcheck disable=SC2086
  for field in ${name}; do
    [[ -n "${field}" ]] || continue
    for pattern in "${RESERVED_FIELD_PATTERNS[@]}"; do
      # RHS is a glob pattern by design.
      # shellcheck disable=SC2053
      [[ "${field}" == ${pattern} ]] && return 0
    done
  done
  return 1
}

# ---------------------------------------------------------------------------
# 1. Is there an LED class at all?
# ---------------------------------------------------------------------------
if [[ ! -d "${LED_CLASS_DIR}" ]]; then
  log "no LED class at ${LED_CLASS_DIR} — no status LEDs to configure"
  exit 0
fi

# ---------------------------------------------------------------------------
# 2. Bounded poll for at least one candidate indicator LED. Never a fixed sleep:
#    gpio-leds/pwm-leds probe asynchronously.
# ---------------------------------------------------------------------------
find_candidate_leds() {
  local dir name sorted=()
  CANDIDATE_LEDS=()
  RESERVED_LEDS=()
  # Sorted for determinism: which physical LED gets the heartbeat must not
  # depend on readdir order, or a reboot could silently swap the two meanings.
  # Read through mapfile rather than command substitution + word splitting, so
  # the scan cannot be broken by an unusual character in a path component.
  mapfile -t sorted < <(printf '%s\n' "${LED_CLASS_DIR}"/* | LC_ALL=C sort)
  for dir in "${sorted[@]}"; do
    [[ -d "${dir}" ]] || continue
    # The directory basename IS the LED name (leds-class.rst); there is no
    # separate `name` attribute to read.
    name="${dir##*/}"
    [[ -e "${dir}/trigger" ]] || continue
    if is_reserved "${name}"; then
      RESERVED_LEDS+=("${name}")
      continue
    fi
    CANDIDATE_LEDS+=("${name}")
  done
  (( ${#CANDIDATE_LEDS[@]} > 0 ))
}

deadline=$((SECONDS + WAIT_SECONDS))
while ! find_candidate_leds; do
  if (( SECONDS >= deadline )); then
    if (( ${#RESERVED_LEDS[@]} > 0 )); then
      log "the only LEDs under ${LED_CLASS_DIR} after ${WAIT_SECONDS}s are kernel-managed or reserved (${RESERVED_LEDS[*]}) — nothing to configure"
    else
      log "no LEDs under ${LED_CLASS_DIR} after ${WAIT_SECONDS}s — this board exposes no status LEDs, nothing to do"
    fi
    exit 0
  fi
  sleep "${POLL_INTERVAL}"
done

if (( ${#RESERVED_LEDS[@]} > 0 )); then
  log "leaving kernel-managed/reserved LED(s) untouched: ${RESERVED_LEDS[*]}"
fi
log "indicator LED(s) available: ${CANDIDATE_LEDS[*]}"

# ---------------------------------------------------------------------------
# 3. Assign the ordered policy to the discovered LEDs, one for one.
# ---------------------------------------------------------------------------
assigned=0
for (( i = 0; i < ${#CANDIDATE_LEDS[@]}; i++ )); do
  led="${CANDIDATE_LEDS[i]}"

  if (( i >= ${#WANTED_TRIGGERS[@]} )); then
    log "${led}: no trigger left in the policy (${WANTED_TRIGGERS[*]}) — leaving it as the kernel set it"
    continue
  fi

  wanted="${WANTED_TRIGGERS[i]}"
  trigger_attr="${LED_CLASS_DIR}/${led}/trigger"

  current="$(active_trigger "${trigger_attr}" || true)"
  if [[ -z "${current}" ]]; then
    warn "${led}: ${trigger_attr} is unreadable — leaving it untouched"
    continue
  fi

  # An LED that already means something keeps meaning it. This is also what
  # makes the unit idempotent: the second boot finds `heartbeat`/`mmc1` already
  # active and changes nothing.
  if [[ "${current}" != "none" ]]; then
    log "${led}: already driven by the '${current}' trigger — leaving it alone"
    continue
  fi

  if ! trigger_offered "${trigger_attr}" "${wanted}"; then
    log "${led}: this kernel does not offer a '${wanted}' trigger — leaving it unconfigured rather than guessing"
    continue
  fi

  log "${led}: assigning the '${wanted}' trigger (the kernel drives the LED from here — brightness is never written by hand)"

  # The group's stderr is redirected BEFORE the inner redirect is attempted, so
  # a refused open is reported by our own warn() and not by a raw shell
  # diagnostic. A read-only `trigger` is odd but survivable: the board simply
  # keeps a dark LED, which is exactly the state it shipped in.
  if ! { printf '%s\n' "${wanted}" >"${trigger_attr}"; } 2>/dev/null; then
    warn "${trigger_attr} refused the write — ${led} keeps its unconfigured state"
    continue
  fi

  # The LED core installs a trigger synchronously, so the read-back is a real
  # confirmation rather than a timing guess. A write that is accepted and then
  # not honoured is a genuine anomaly and fails loudly.
  readback="$(active_trigger "${trigger_attr}" || true)"
  [[ "${readback}" == "${wanted}" ]] \
    || die "${trigger_attr} still reports '${readback}' after accepting a write of '${wanted}'"

  assigned=$(( assigned + 1 ))
done

if (( assigned == 0 )); then
  log "no LED trigger needed changing"
else
  log "configured ${assigned} status LED(s)"
fi

exit 0
