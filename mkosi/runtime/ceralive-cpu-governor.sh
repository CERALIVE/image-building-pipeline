#!/usr/bin/env bash
#
# ceralive-cpu-governor.sh — pin the CPU scaling governor for sustained encode.
#
# WHY THIS FILE EXISTS AT ALL (the trixie migration, todo 10)
# ---------------------------------------------------------------------------
# It replaces a mechanism Debian deleted. Until trixie the image installed
# `cpufrequtils`, and the governor pin was entirely that package's doing: it
# shipped `/etc/init.d/cpufrequtils` plus `S01cpufrequtils`/`S01loadcpufreq`
# sysv links, which read `GOVERNOR=` out of `/etc/default/cpufrequtils` at
# boot. All this repo ever wrote was that one config line.
#
# Debian REMOVED `cpufrequtils` (out of testing 2023-10-28, out of unstable
# 2024-06-16), so on trixie it resolves to nothing. Its accepted successor is
# `linux-cpupower`, and the successor is NOT drop-in: `dpkg -L linux-cpupower`
# on a real trixie arm64 container lists EXACTLY ONE file, `/usr/bin/cpupower`.
# No init script, no systemd unit, no `/etc/default` hook — and nothing else in
# trixie reads `/etc/default/cpufrequtils` either.
#
# So swapping the package name alone would not have produced an error. It would
# have produced a DEAD WRITER: the postinst would keep writing a config file
# with no reader, every build would stay green, the image would boot, and the
# encode-performance governor pin would simply never be applied again. That is
# the exact defect class this repo has shipped before (`quirks.sh`, the
# `/dev/hdmi-in` symlink rule) and it is why the applier is now ours.
#
# WHAT IT DOES, AND WHAT IT DELIBERATELY DOES NOT
# ---------------------------------------------------------------------------
# It asks `cpupower` to set one governor across all policies and then VERIFIES
# the kernel actually took it. It does not write `scaling_setspeed`, does not
# touch `scaling_min_freq`/`scaling_max_freq`, does not disable any CPU, and
# does not loop — cpufreq keeps doing all of the actual frequency selection;
# this only chooses which governor makes those decisions. Same principle as
# `ceralive-fan-curve`: move the policy, never replace the kernel's driver.
#
# `cpufreq-set -g X` maps to `cpupower frequency-set -g X`, and `cpufreq-info`
# to `cpupower frequency-info`.
#
# FAIL-SOFT, because "no cpufreq" is a legitimate board configuration. A board
# whose kernel exposes no cpufreq policies at all (an x86 box on `intel_pstate`
# in passive-less mode, a VM, a kernel built without CPU_FREQ) logs one
# informational line and exits 0 — it is not a broken device, it just has no
# governor to pin. A board that HAS policies but refuses the governor is a
# different thing and is reported loudly, because by then the hardware shape has
# already been proven present.
#
# Shell profile: device-daemon (docs/shell-profiles.md) — `set -uo pipefail`,
# no `-e`, no ERR trap, self-contained log/die. `lib/` is not mounted here.

set -uo pipefail

log() { printf '[ceralive-cpu-governor] %s\n' "$*"; }
die() { printf '[ceralive-cpu-governor] ERROR: %s\n' "$*" >&2; exit 1; }

# The governor to pin. `performance` is the historical value this image has
# always used (it was `GOVERNOR="performance"` in /etc/default/cpufrequtils):
# sustained hardware encode is latency-sensitive and a ramping governor costs
# frames at exactly the wrong moment. Overridable so a bench can retune without
# editing the unit.
GOVERNOR="${CERALIVE_CPU_GOVERNOR:-performance}"

# Test seam. Every sysfs read below goes through this prefix so the contract
# test can drive the real script against a synthetic policy tree.
CPUFREQ_DIR="${CERALIVE_CPUFREQ_DIR:-/sys/devices/system/cpu/cpufreq}"

# `cpupower` is the writer, but it is resolved rather than hardcoded so the
# test can substitute a stub and so a PATH-less early-boot environment still
# finds it.
CPUPOWER_BIN="${CERALIVE_CPUPOWER_BIN:-/usr/bin/cpupower}"

# Every cpufreq policy the kernel currently exposes. Bounded and glob-based —
# a board with no cpufreq has no policy* entries and this is simply empty.
list_policies() {
  local p
  for p in "${CPUFREQ_DIR}"/policy*; do
    [[ -d "${p}" ]] || continue
    printf '%s\n' "${p}"
  done
}

main() {
  local policies
  mapfile -t policies < <(list_policies)

  if [[ ${#policies[@]} -eq 0 ]]; then
    log "no cpufreq policies under ${CPUFREQ_DIR} — this kernel/board exposes no scaling governor; nothing to pin"
    return 0
  fi

  # A governor the kernel does not offer can never be set, and asking for one
  # is a configuration error rather than a hardware fact — so it is named
  # explicitly instead of surfacing as an opaque cpupower failure. The
  # available list is per-policy; policy0 is representative on every SoC this
  # image targets (all policies share one driver).
  local avail_file="${policies[0]}/scaling_available_governors"
  if [[ -r "${avail_file}" ]]; then
    local avail
    avail="$(cat "${avail_file}" 2>/dev/null)"
    if [[ " ${avail} " != *" ${GOVERNOR} "* ]]; then
      die "governor '${GOVERNOR}' is not offered by this kernel (available: ${avail}). Refusing to guess a substitute."
    fi
  fi

  [[ -x "${CPUPOWER_BIN}" ]] \
    || die "${CPUPOWER_BIN} not found or not executable — the linux-cpupower package provides it (it replaced cpufrequtils at the trixie migration)"

  log "pinning CPU scaling governor to '${GOVERNOR}' across ${#policies[@]} cpufreq policy/policies"
  if ! "${CPUPOWER_BIN}" frequency-set -g "${GOVERNOR}" >/dev/null 2>&1; then
    log "WARNING: '${CPUPOWER_BIN} frequency-set -g ${GOVERNOR}' returned non-zero; verifying the kernel state directly before deciding"
  fi

  # VERIFY, do not trust the exit status. `cpupower frequency-set` can report
  # success per-CPU while a policy silently keeps its old governor, and a
  # governor that did not land is precisely the silent regression this whole
  # file exists to prevent — so the checked property is the resulting kernel
  # state, never the writer's return code. Same discipline as the boot-artifact
  # gate asserting the ARM64 Image magic rather than gzip's exit status.
  local p cur bad=0
  for p in "${policies[@]}"; do
    cur="$(cat "${p}/scaling_governor" 2>/dev/null)"
    if [[ "${cur}" != "${GOVERNOR}" ]]; then
      log "WARNING: ${p##*/} reports governor '${cur}', expected '${GOVERNOR}'"
      bad=$((bad + 1))
    fi
  done

  [[ ${bad} -eq 0 ]] \
    || die "${bad} of ${#policies[@]} cpufreq policies did not accept governor '${GOVERNOR}'"

  log "governor '${GOVERNOR}' applied and verified on all ${#policies[@]} policy/policies"
}

main "$@"
