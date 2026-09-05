#!/usr/bin/env bash
#
# postinst.d/hardware.sh — boot-time HARDWARE policy units.
#
# Sourced by customize/postinst-lib.sh (never executed). Concern: the small
# device writes this image performs on the board's own hardware at boot —
# the Type-C connector role, the pwm-fan thermal trip, the fan's dead-start
# kick, the indicator LEDs, and the HDMI-RX receiver's EDID. Every one of them
# installs a COMMITTED standalone artifact from "${CERALIVE_RUNTIME_SRC}" and
# enables its unit; none of them inlines a script or a unit file here.
#
# All five are called from configure_services (postinst.d/services.sh) on EVERY
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

# USB-C capture reliability: keep the connector dual-role and request the
# role-only DR_SWAP for any settled sink/device attach.
# udev hands port/partner add events to the same serialized systemd oneshot; the
# enabled unit retains deterministic coldplug ordering before the media services.
# Installed from committed artifacts under CERALIVE_RUNTIME_SRC, never inlined.
# TYPEC_{UNIT,SBIN,RULES}_DIR override install dirs for the offline contract.
setup_typec_policy() {
  log "installing the adaptive USB-C data-role policy (ceralive-typec-policy.service — preserve DRP and swap any settled sink/device attach to host)"
  local src="${CERALIVE_RUNTIME_SRC:-}"
  [[ -n "${src}" && -f "${src}/ceralive-typec-policy.sh" ]] \
    || die "typec-policy script not found: ${src}/ceralive-typec-policy.sh (is \$SRCDIR/runtime mounted?)"
  [[ -f "${src}/ceralive-typec-policy.service" ]] \
    || die "typec-policy unit not found: ${src}/ceralive-typec-policy.service (is \$SRCDIR/runtime mounted?)"
  [[ -f "${src}/99-ceralive-typec-policy.rules" ]] \
    || die "typec-policy udev rules not found: ${src}/99-ceralive-typec-policy.rules (is \$SRCDIR/runtime mounted?)"

  local sbin_dir="${TYPEC_SBIN_DIR:-/usr/local/sbin}"
  local unit_dir="${TYPEC_UNIT_DIR:-/etc/systemd/system}"
  local rules_dir="${TYPEC_RULES_DIR:-/etc/udev/rules.d}"
  install -D -m 0755 "${src}/ceralive-typec-policy.sh" "${sbin_dir}/ceralive-typec-policy"
  install -D -m 0644 "${src}/ceralive-typec-policy.service" "${unit_dir}/ceralive-typec-policy.service"
  install -D -m 0644 "${src}/99-ceralive-typec-policy.rules" "${rules_dir}/99-ceralive-typec-policy.rules"

  enable_service ceralive-typec-policy.service
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
# (same idiom as setup_typec_policy / setup_provisioning), never inlined.
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

# Pin the CPU scaling governor for sustained hardware encode.
#
# THIS IS A REPLACEMENT, NOT A NEW FEATURE. The governor has been pinned to
# `performance` on every CeraLive image; what changed at the trixie migration
# (todo 10) is WHO applies it. The pin used to be delivered entirely by the
# `cpufrequtils` package's own sysv init script, which read `GOVERNOR=` out of
# `/etc/default/cpufrequtils` at boot — the only thing this repo wrote was that
# config line.
#
# Debian REMOVED `cpufrequtils` (out of testing 2023-10-28, out of unstable
# 2024-06-16), so it has no installation candidate on trixie. Its successor
# `linux-cpupower` ships EXACTLY ONE file, `/usr/bin/cpupower` — no unit, no
# init script, no `/etc/default` hook (verified with `dpkg -L` in a real trixie
# arm64 container), and nothing in trixie reads `/etc/default/cpufrequtils`.
#
# So the package rename alone would have been silent: a config write with no
# reader, a green build, a booting image, and a governor that is never applied
# again. The `/etc/default/cpufrequtils` writes are therefore GONE from both the
# live runtime postinst and its customize twin, and this unit is the applier.
setup_cpu_governor() {
  log "pinning the CPU scaling governor at boot (ceralive-cpu-governor.service — replaces the cpufrequtils sysv mechanism Debian removed)"
  local src="${CERALIVE_RUNTIME_SRC:-}"
  [[ -n "${src}" && -f "${src}/ceralive-cpu-governor.sh" ]] \
    || die "cpu-governor script not found: ${src}/ceralive-cpu-governor.sh (is \$SRCDIR/runtime mounted?)"
  [[ -f "${src}/ceralive-cpu-governor.service" ]] \
    || die "cpu-governor unit not found: ${src}/ceralive-cpu-governor.service (is \$SRCDIR/runtime mounted?)"

  local sbin_dir="${CPU_GOVERNOR_SBIN_DIR:-/usr/local/sbin}"
  local unit_dir="${CPU_GOVERNOR_UNIT_DIR:-/etc/systemd/system}"
  install -D -m 0755 "${src}/ceralive-cpu-governor.sh" "${sbin_dir}/ceralive-cpu-governor"
  install -D -m 0644 "${src}/ceralive-cpu-governor.service" "${unit_dir}/ceralive-cpu-governor.service"

  enable_service ceralive-cpu-governor.service
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
# (same idiom as setup_fan_curve / setup_typec_policy), never inlined.
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
# setup_fan_curve/setup_led_status/setup_typec_policy would fix only the first
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
# HDMI capture: write the CeraLive product EDID into the SoC's HDMI-RX receiver.
#
# THIS IS A DRIVER REQUIREMENT, NOT A TUNING KNOB. The Synopsys DesignWare
# HDMI-RX driver ships with no EDID of its own and its Kconfig says a real
# product is expected to load a custom branded one from userspace — the receiver
# is deliberately not functional until something does. With no EDID an attached
# source reads nothing on the DDC lines and either falls back to its most
# conservative mode or refuses to output at all, which on a bench reads as
# "HDMI capture is broken". The blob claims 3840x2160p60 plus SCDC Present and a
# 600 MHz maximum TMDS character rate, which is the pair that makes 4K60 legal
# for a source to offer.
#
# FOUR ARTIFACTS, NOT TWO — and the two extra ones are why this block differs
# from its four siblings above. Besides the script and the unit, this installs
# BOTH committed BINARIES, mkosi/runtime/edid/ceralive-hdmirx-<profile>.edid,
# generated byte-exact by tools/gen-hdmirx-edid.py and gated in CI against
# generator drift. They land in /etc/ceralive because that is where this image
# already installs read-only runtime data (ingest-firewall.nft,
# uart-bootstrap-public.pem) and because postinst.d/persistence.sh's
# /etc/ceralive -> /data relocation loop is a NAMED list, so new files there are
# not swept onto /data. Those paths are what the script's own
# CERALIVE_HDMIRX_EDID_DIR default resolves to: producer and consumer must agree.
#
# BOTH PROFILES SHIP ON EVERY IMAGE; the image does not choose. Which one is
# written is a per-device runtime decision read from `hdmirx.edid_profile` in
# /data/ceralive/hdmirx.conf — on the shared partition precisely so an operator's
# choice survives an A/B OTA. Baking the selection into the image instead would
# put a per-device answer in a per-release artifact and lose it on every update.
#
# HDMIRX_EDID_PROFILES IS ONE OF THREE COPIES OF THIS LIST — a subimage chroot
# can source neither the generator nor the runtime script, so the set is written
# out here, in ceralive-hdmirx-edid.sh's KNOWN_PROFILES, and in the generator's
# PROFILES. tests/hdmirx-edid-contract.bats pins all three against
# `gen-hdmirx-edid.py --list-profiles`, so adding a profile in one place and not
# the others fails a test rather than shipping a blob nothing installs.
#
# BOARD-AGNOSTIC, like the four above: a target with no HDMI-RX platform exits 0
# ("nothing to program"), while a board that HAS one whose driver did not bind
# fails loudly with `hdmirx device absent on rk3588 platform` — the Orange Pi 5+
# BL31 probe-failure class, which a silent no-op would hide until a shoot.
#
# Installed from the committed standalone artifacts under CERALIVE_RUNTIME_SRC
# (same idiom as setup_typec_policy / setup_fan_curve), never inlined.
# HDMIRX_EDID_UNIT_DIR / HDMIRX_EDID_SBIN_DIR / HDMIRX_EDID_BLOB_DIR override the
# install dirs for the offline test.
HDMIRX_EDID_PROFILES=("full" "robust-4k60")

setup_hdmirx_edid() {
  log "installing the CeraLive product EDIDs for the HDMI-RX receiver (ceralive-hdmirx-edid.service — the receiver ships with NO EDID and is not functional until one is written)"
  local src="${CERALIVE_RUNTIME_SRC:-}"
  [[ -n "${src}" && -f "${src}/ceralive-hdmirx-edid.sh" ]] \
    || die "hdmirx-edid script not found: ${src}/ceralive-hdmirx-edid.sh (is \$SRCDIR/runtime mounted?)"
  [[ -f "${src}/ceralive-hdmirx-edid.service" ]] \
    || die "hdmirx-edid unit not found: ${src}/ceralive-hdmirx-edid.service (is \$SRCDIR/runtime mounted?)"

  local profile
  for profile in "${HDMIRX_EDID_PROFILES[@]}"; do
    [[ -s "${src}/edid/ceralive-hdmirx-${profile}.edid" ]] \
      || die "hdmirx EDID blob not found: ${src}/edid/ceralive-hdmirx-${profile}.edid (is \$SRCDIR/runtime mounted?)"
  done

  local sbin_dir="${HDMIRX_EDID_SBIN_DIR:-/usr/local/sbin}"
  local unit_dir="${HDMIRX_EDID_UNIT_DIR:-/etc/systemd/system}"
  local blob_dir="${HDMIRX_EDID_BLOB_DIR:-/etc/ceralive}"
  install -D -m 0755 "${src}/ceralive-hdmirx-edid.sh" "${sbin_dir}/ceralive-hdmirx-edid"
  install -D -m 0644 "${src}/ceralive-hdmirx-edid.service" "${unit_dir}/ceralive-hdmirx-edid.service"
  for profile in "${HDMIRX_EDID_PROFILES[@]}"; do
    install -D -m 0644 "${src}/edid/ceralive-hdmirx-${profile}.edid" \
      "${blob_dir}/hdmirx-${profile}.edid"
  done

  enable_service ceralive-hdmirx-edid.service
}

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

# Board hardware-QUIRK udev rows — the only board-MANIFEST-gated writes this
# image performs, and the reason they live here rather than in
# setup_hardware_access is that they must NOT apply to every board.
#
# WHY THIS IS NOT LEFT TO customize/quirks.sh. That module holds the same
# dispatch (dispatch_quirks + handle_m2_modem_sim_workaround) and it is correct —
# but it is a run-all.sh RUNTIME module and ./build runs `run-all.sh base` ONLY,
# so nothing it writes has ever reached an emitted rootfs. Same dead-writer trap
# as /dev/hdmi-in. This function is on the LIVE path: mkosi.postinst.chroot calls
# it immediately after setup_hardware_access, which TRUNCATES the rules file, so
# these rows are appended to the policy that writer just wrote.
#
# HOW THE BOARD FACT GETS HERE. A subimage chroot has no board manifest and no
# way to resolve one, so the gate arrives as CERALIVE_BOARD_QUIRKS: the manifest
# `quirks:` block flattened by resolve.py to QUIRKS_<NAME>, collapsed by
# lib/orchestrate.sh into a space-separated `name=value` list and forwarded on
# the env_names <-> mkosi.conf PassEnvironment= lockstep. Exactly the mechanism
# CERALIVE_MODEM_PORTS_SLOTS already uses. UNSET/EMPTY (a board with no `quirks:`
# block) emits NOTHING — the gate is fail-closed in the direction that matters.
#
# VALUE SEMANTICS are deliberately one notch STRICTER than quirks.sh, which
# parses keys and ignores values entirely (so `foo: false` would still apply).
# Here a declared quirk applies unless its value is falsey, because the schema
# admits booleans and "declared false, applied anyway" is not a defensible
# reading of a manifest. Absent/empty value = declared by presence = applies.
apply_board_quirks() {
  local rules="${CERALIVE_SYSROOT:-}/etc/udev/rules.d/99-ceralive-hardware.rules"
  local declared="${CERALIVE_BOARD_QUIRKS:-}"

  if [[ -z "${declared}" ]]; then
    log "board quirks: this board's manifest declares none — no quirk udev rules emitted"
    return 0
  fi

  log "board quirks: dispatching from CERALIVE_BOARD_QUIRKS (${declared})"
  mkdir -p "$(dirname -- "${rules}")"

  local -a entries=()
  read -r -a entries <<<"${declared}"

  local entry name value applied=0
  for entry in ${entries[@]+"${entries[@]}"}; do
    name="${entry%%=*}"
    value=""
    [[ "${entry}" == *=* ]] && value="${entry#*=}"

    case "${value,,}" in
      false | 0 | no | off)
        log "board quirks: '${name}' declared with a falsey value ('${value}') — NOT applied"
        continue
        ;;
    esac

    case "${name}" in
      m2_modem_sim_workaround)
        log "board quirks: applying m2_modem_sim_workaround (ModemManager SIM-detection env for M.2 B-key modems)"
        cat >>"${rules}" <<'QUIRK_M2_SIM'

# =============================================================================
# QUIRK m2_modem_sim_workaround — force ModemManager probe for M.2 modems
# Board-gated: emitted only for a board whose manifest `quirks:` block declares
# it (CERALIVE_BOARD_QUIRKS). M.2 B-key modems need ModemManager forced to probe
# and to treat the port as a candidate, or SIM detection never happens.
# =============================================================================
SUBSYSTEM=="usb", ATTRS{idVendor}=="2c7c", ENV{ID_MM_DEVICE_PROCESS}="1", ENV{ID_MM_CANDIDATE}="1"
SUBSYSTEM=="usb", ATTRS{idVendor}=="1199", ENV{ID_MM_DEVICE_PROCESS}="1", ENV{ID_MM_CANDIDATE}="1"
QUIRK_M2_SIM
        applied=$((applied + 1))
        ;;
      usb_power_optimization)
        # NOT ported to the live writer on purpose. quirks.sh's handler turns USB
        # autosuspend ON for every USB device, which is a real runtime behaviour
        # change on a board whose whole job is holding several cellular modems
        # up — and it has never shipped, so there is no regression to preserve.
        # Enabling it needs its own change with its own hardware evidence.
        log "board quirks: 'usb_power_optimization' declared — NOT applied by the live writer (USB autosuspend is a runtime behaviour change on a modem-bearing board and needs its own hardware-evidenced change; see customize/quirks.sh)"
        ;;
      hdmi_input_emi_shield)
        log "board quirks: 'hdmi_input_emi_shield' declared — DEFERRED (DT/hardware-level; needs a vendor kernel DT overlay, not applicable at config level)"
        ;;
      *)
        log "board quirks: unknown quirk '${name}' — skipping (no handler), continuing"
        ;;
    esac
  done

  log "board quirks: dispatch complete — ${applied} applied"
}
