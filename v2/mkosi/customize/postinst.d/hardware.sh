#!/usr/bin/env bash
#
# postinst.d/hardware.sh — boot-time HARDWARE policy units.
#
# Sourced by customize/postinst-lib.sh (never executed). Concern: the small
# sysfs writes this image performs on the board's own hardware at boot —
# the Type-C connector role, the pwm-fan thermal trip, the fan's dead-start
# kick, and the indicator LEDs. Every one of them installs a COMMITTED
# standalone artifact from "${CERALIVE_RUNTIME_SRC}" and enables its unit; none
# of them inlines a script or a unit file here.
#
# All four are called from configure_services (postinst.d/services.sh) on EVERY
# board, because the applicability decision belongs to the hardware at runtime
# rather than to a manifest that would have to be kept in sync by hand — each
# shipped script is a clean no-op on a board that does not have the device.
#
# CHROOT-SAFE STANDALONE: like every module under postinst.d/, this file carries
# its own declare -F-guarded log()/die() fallbacks. The modules are sourced
# inside mkosi SUBIMAGE CHROOTS where the repo's lib/ is NOT mounted, so a module
# must never assume that anything else has already been sourced. The guards mean
# a caller that DID source lib/common.sh (the customize modules) keeps its own
# structured loggers, exactly as postinst-lib.sh does.
#
# shellcheck shell=bash

if ! declare -F log >/dev/null 2>&1; then
  log() { printf '[runtime-lib] %s\n' "$*" >&2; }
fi
if ! declare -F die >/dev/null 2>&1; then
  die() { log "FATAL: $*"; exit 1; }
fi

# USB-C capture reliability: pin the Type-C connector to the SOURCE role at boot.
#
# /sys/class/typec/port0 is an FUSB302 TCPM connector (feac0000.i2c/i2c-4/4-0022)
# that drives the DWC3 controller fc000000.usb through a usb-role-switch. The
# device tree leaves it DRP (dual-role), so every fresh boot reads
# `port_type = [dual] source sink` and the port does not CHOOSE a role — it
# toggles, and Try.SRC/Try.SNK arbitration on the CC lines decides. The capture
# camera (DJI Osmo Pocket 3) is dual-role too, so both ends toggle and the
# arbitration is a real race: the TCPM trace shows the port cycling
# `SNK_TRY_WAIT -> SRC_TRYWAIT` rather than converging. Whenever it lands on
# SINK the SoC is running as a USB peripheral, so the camera is not "slow to be
# detected" — its bus (usb9/9-1) is entirely absent from /sys/bus/usb/devices/.
# That is the mechanism behind the long-standing "camera sometimes isn't detected
# over USB-C" complaint. Writing `source` removes the arbitration outright and
# the camera enumerated on every attempt in live testing (1-19 s to full UVC mode
# switch), including straight after a cold power-cycle.
#
# It has to be a BOOT-TIME mechanism because `port_type` is live sysfs state: it
# reverts to `dual` on every reboot, and there is no device-tree property we own
# in this repo (the DT comes from the Armbian BSP kernel package, see the BSP
# pin/drift contract) that would set it.
#
# WHY A SYSTEMD ONESHOT AND NOT A UDEV RULE. udev would sidestep the "does the
# sysfs path exist yet" race for free, but it loses on three counts that matter
# more here: (1) it cannot express ordering against cerastream.service — the unit
# that actually opens the camera — whereas Before= can, and that ordering is the
# actual requirement; (2) a failed ATTR{} write is a silent udevd log line, not a
# failed unit, and this image's boot-config discipline is fail-loud with journal
# evidence; (3) the obvious `ATTR{port_type}=="dual"` guard that would make such a
# rule idempotent can NEVER match, because the kernel prints the whole menu with
# the active entry bracketed (`[dual] source sink`) — a trap that yields a rule
# that looks correct and does nothing. On top of that, a role change makes TCPM
# emit KOBJ_CHANGE on the same device, so an unguarded rule re-triggers itself.
# The service pays for this with a bounded poll (never a fixed sleep) for the
# asynchronously-probed attribute; see the script header.
#
# Installed from the committed standalone artifacts under CERALIVE_RUNTIME_SRC
# (same idiom as setup_boot_healthcheck / setup_provisioning), never inlined.
# TYPEC_UNIT_DIR / TYPEC_SBIN_DIR override the install dirs for the offline test.
setup_typec_source_role() {
  log "pinning the USB-C connector to the Type-C source role at boot (ceralive-typec-source.service — DRP arbitration must not decide whether the camera enumerates)"
  local src="${CERALIVE_RUNTIME_SRC:-}"
  [[ -n "${src}" && -f "${src}/ceralive-typec-source.sh" ]] \
    || die "typec-source script not found: ${src}/ceralive-typec-source.sh (is \$SRCDIR/runtime mounted?)"
  [[ -f "${src}/ceralive-typec-source.service" ]] \
    || die "typec-source unit not found: ${src}/ceralive-typec-source.service (is \$SRCDIR/runtime mounted?)"

  local sbin_dir="${TYPEC_SBIN_DIR:-/usr/local/sbin}"
  local unit_dir="${TYPEC_UNIT_DIR:-/etc/systemd/system}"
  install -D -m 0755 "${src}/ceralive-typec-source.sh" "${sbin_dir}/ceralive-typec-source"
  install -D -m 0644 "${src}/ceralive-typec-source.service" "${unit_dir}/ceralive-typec-source.service"

  enable_service ceralive-typec-source.service
}

# Thermal comfort: lower the pwm-fan zone's FIRST `active` trip at boot.
#
# The RK3588 package thermal zone ships from the device tree with `active` trips
# at 55 C and 65 C plus a `critical` trip at 115 C, and its pwm-fan cooling
# device declares `cooling-levels = <0 120 150 180 210 240 255>` — a range a
# Rockchip kernel maintainer confirmed reliably spins the fan, which rules out
# the well-known "cooling-levels too low to overcome stiction" defect class. So
# the fan is not broken; it is simply never asked to run, because the board idles
# below 55 C. The result is a board that sits silent while heat accumulates and
# then snaps the fan on audibly. Measured live on a Rock 5B+: 46-52 C at rest,
# low 50s under light load, with `trip_point_1_temp` confirmed runtime-writable
# (55000 -> 40000 -> 55000 round-trip).
#
# THE FIX IS ONE SYSFS WRITE, AND THAT IS THE ENTIRE SAFETY ARGUMENT. It lowers
# the temperature of the first `active`-type trip in the zone bound to the
# pwm-fan cooling device — nothing else. It does NOT write thermal_zone*/mode
# (which would also disable the 115 C critical trip — categorically
# unacceptable), does NOT write cur_state or the hwmon pwm node, and runs no
# polling/monitoring loop. The kernel's step_wise governor already does 100% of
# the fan control and was live-proven correct on this board: cur_state
# auto-steps 0 -> 1 at a real trip crossing and auto-reverts when the
# temperature falls. Move the goalpost, do not replace the referee.
#
# WHY THE SCRIPT DISCOVERS EVERYTHING GENERICALLY. `thermal_zoneN` and
# `cooling_deviceN` are registration-order artefacts: they differ per board, per
# kernel tree (vendor 6.1 BSP vs mainline/edge), and were confirmed
# differently-numbered on real hardware. A hardcoded index is how a "working"
# fix silently starts rewriting an unrelated zone's trip. The script therefore
# matches cooling_device*/type == `pwm-fan`, resolves each zone's cdevN symlinks
# to find the binding zone, and takes the FIRST trip whose type is `active`.
#
# BOARD-AGNOSTIC: a board with no thermal class, no pwm-fan cooling device
# (x86-minipc), no zone bound to one, or no active trip logs an informational
# line and exits 0. Called from configure_services on every board for exactly
# that reason — the applicability decision belongs to the hardware at runtime,
# not to a manifest that would have to be kept in sync by hand.
#
# Installed from the committed standalone artifacts under CERALIVE_RUNTIME_SRC
# (same idiom as setup_typec_source_role / setup_provisioning), never inlined.
# FAN_CURVE_UNIT_DIR / FAN_CURVE_SBIN_DIR override the install dirs for the
# offline test.
setup_fan_curve() {
  log "lowering the pwm-fan thermal zone's first active trip at boot (ceralive-fan-curve.service — the fan should idle gently, not wait for 55 C)"
  local src="${CERALIVE_RUNTIME_SRC:-}"
  [[ -n "${src}" && -f "${src}/ceralive-fan-curve.sh" ]] \
    || die "fan-curve script not found: ${src}/ceralive-fan-curve.sh (is \$SRCDIR/runtime mounted?)"
  [[ -f "${src}/ceralive-fan-curve.service" ]] \
    || die "fan-curve unit not found: ${src}/ceralive-fan-curve.service (is \$SRCDIR/runtime mounted?)"

  local sbin_dir="${FAN_CURVE_SBIN_DIR:-/usr/local/sbin}"
  local unit_dir="${FAN_CURVE_UNIT_DIR:-/etc/systemd/system}"
  install -D -m 0755 "${src}/ceralive-fan-curve.sh" "${sbin_dir}/ceralive-fan-curve"
  install -D -m 0644 "${src}/ceralive-fan-curve.service" "${unit_dir}/ceralive-fan-curve.service"

  enable_service ceralive-fan-curve.service
}

# Operator feedback: give the board's indicator LEDs a default meaning at boot.
#
# The kernel registers this board's LEDs and then leaves the INDICATOR ones
# entirely unconfigured — read on a live Orange Pi 5 Plus, both
# `blue:indicator-1` (gpio-leds) and `green:indicator-2` (pwm-leds) sit at
# `trigger = [none]` with `brightness = 0` forever. They are wired, they work,
# and nothing ever asks them to do anything, so a headless streaming appliance
# offers its operator zero visual evidence that it is even alive.
#
# The unit assigns `heartbeat` to the first discovered indicator LED (kernel is
# scheduling) and `mmc1` to the second (the board is doing card I/O). Both are
# stock kernel triggers and both are verified present in that LED's own
# `trigger` menu before anything is written.
#
# IT NEVER WRITES `brightness`. A trigger hands the LED to the kernel; writing
# brightness afterwards fights the trigger just installed — the same
# "kernel does 100% of the driving" principle setup_fan_curve established for
# the thermal governor. Set the policy, then get out of the way.
#
# `mmc0::` (the MMC host's own activity LED) is EXCLUDED and left exactly as the
# kernel set it — it is not an indicator LED, it already works, and it is not
# ours. There is NO red LED in the kernel's LED class on this board at all: the
# red one an operator can see is, on the evidence, a hardwired power-rail
# indicator with no software visibility. Nothing here can address it.
#
# WHY DISCOVERY IS GENERIC. `blue:indicator-1` / `green:indicator-2` are vendor
# DTS labels with no semantics — they are not `status`/`activity`/`power` — and
# they differ per board and per kernel tree. Matching either string is how a
# "working" fix silently stops working on the next board, so the script
# enumerates /sys/class/leds, rejects any name with a reserved field
# (`mmc[0-9]*`, `power`), sorts for determinism and takes the first two. Same
# never-hardcode-an-index principle as setup_fan_curve.
#
# BOARD-AGNOSTIC: no LED class, zero, one, or five candidate LEDs are all
# informational log-and-exit-0 outcomes. Called from configure_services on every
# board for exactly that reason — the applicability decision belongs to the
# hardware at runtime, not to a manifest kept in sync by hand.
#
# Installed from the committed standalone artifacts under CERALIVE_RUNTIME_SRC
# (same idiom as setup_fan_curve / setup_typec_source_role), never inlined.
# LED_STATUS_UNIT_DIR / LED_STATUS_SBIN_DIR override the install dirs for the
# offline test.
setup_led_status() {
  log "assigning default status-LED triggers at boot (ceralive-led-status.service — the indicator LEDs ship at trigger=none and never light up)"
  local src="${CERALIVE_RUNTIME_SRC:-}"
  [[ -n "${src}" && -f "${src}/ceralive-led-status.sh" ]] \
    || die "led-status script not found: ${src}/ceralive-led-status.sh (is \$SRCDIR/runtime mounted?)"
  [[ -f "${src}/ceralive-led-status.service" ]] \
    || die "led-status unit not found: ${src}/ceralive-led-status.service (is \$SRCDIR/runtime mounted?)"

  local sbin_dir="${LED_STATUS_SBIN_DIR:-/usr/local/sbin}"
  local unit_dir="${LED_STATUS_UNIT_DIR:-/etc/systemd/system}"
  install -D -m 0755 "${src}/ceralive-led-status.sh" "${sbin_dir}/ceralive-led-status"
  install -D -m 0644 "${src}/ceralive-led-status.service" "${unit_dir}/ceralive-led-status.service"

  enable_service ceralive-led-status.service
}

# Break the fan's static friction when the governor first asks it to spin.
#
# setup_fan_curve (above) fixed WHEN the fan is asked to run. This fixes the fact
# that the state it is asked into is too WEAK to start it from a stop: measured on
# a live Orange Pi 5 Plus, the pwm-fan's first active state is 70/255 (~27.5% duty),
# which sustains a turning rotor but does not break stiction on a stopped one. The
# fan sits energised and stalled until someone nudges it by hand — the exact
# operator report. Upstream Linux ships an in-driver equivalent
# (`fan-stop-to-start-percent`/`-us` in pwm-fan.c), but those properties postdate
# both v6.1 and v6.6, so this kernel has no DT knob and the fix must be userspace.
#
# THE FIRST RESIDENT UNIT IN THIS FAMILY, and necessarily so: the fan returns to
# state 0 whenever the board cools below the trip and re-enters an active state
# when it warms again, many times over a device's uptime. A boot-time oneshot like
# setup_fan_curve/setup_led_status/setup_typec_source_role would fix only the first
# dead start. Type=exec + Restart=on-failure follows the repo's existing long-running
# precedent (ceralive-rtmp-gateway.service).
#
# UNLIKE setup_fan_curve, THIS ONE DOES WRITE cur_state — and that is deliberate,
# bounded, and not a contradiction of the fan-curve rule. It writes exactly twice per
# 0 -> nonzero edge: max_state, then the governor's own commanded state back again.
# The restore is MANDATORY, not cosmetic: on this kernel a userspace cur_state write
# is STICKY (cur_state_store never clears cdev->updated, thermal_cdev_update()
# short-circuits on it, and step_wise clears it only when its target CHANGES), so
# "write and let the governor's next poll correct it" would leave the fan at 100%
# for as long as the temperature stayed in one trip band. Full mechanism, with the
# exact kernel sources: the script header.
#
# BOARD-AGNOSTIC: no thermal class, no pwm-fan cooling device (x86-minipc), or a
# max_state below 2 (no room to kick above the first active state) are informational
# log-and-exit-0 outcomes. Called from configure_services on every board for that
# reason — the applicability decision belongs to the hardware at runtime.
#
# Installed from the committed standalone artifacts under CERALIVE_RUNTIME_SRC
# (same idiom as setup_fan_curve / setup_led_status), never inlined.
# FAN_KICKSTART_UNIT_DIR / FAN_KICKSTART_SBIN_DIR override the install dirs for the
# offline test.
setup_fan_kickstart() {
  log "monitoring the pwm-fan for dead starts (ceralive-fan-kickstart.service — its first active state is too weak to break stiction)"
  local src="${CERALIVE_RUNTIME_SRC:-}"
  [[ -n "${src}" && -f "${src}/ceralive-fan-kickstart.sh" ]] \
    || die "fan-kickstart script not found: ${src}/ceralive-fan-kickstart.sh (is \$SRCDIR/runtime mounted?)"
  [[ -f "${src}/ceralive-fan-kickstart.service" ]] \
    || die "fan-kickstart unit not found: ${src}/ceralive-fan-kickstart.service (is \$SRCDIR/runtime mounted?)"

  local sbin_dir="${FAN_KICKSTART_SBIN_DIR:-/usr/local/sbin}"
  local unit_dir="${FAN_KICKSTART_UNIT_DIR:-/etc/systemd/system}"
  install -D -m 0755 "${src}/ceralive-fan-kickstart.sh" "${sbin_dir}/ceralive-fan-kickstart"
  install -D -m 0644 "${src}/ceralive-fan-kickstart.service" "${unit_dir}/ceralive-fan-kickstart.service"

  enable_service ceralive-fan-kickstart.service
}
