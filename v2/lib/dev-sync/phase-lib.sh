#!/usr/bin/env bash
#
# phase-lib.sh — the ordered phase verbs of the native (ceracoder/srtla) dev-sync.
#
# Each phase is a single seam in the documented order:
#   arch-check → build → verify → push → refresh+restart → health → (rollback)
#
#   * phase_arch_check     — REFUSE on an artifact↔device arch mismatch
#   * phase_build          — produce <app>.raw (prebuilt --raw, else build_app_layer)
#   * phase_verify         — gate the .raw BEFORE any device mutation
#   * phase_push           — A/B snapshot, then atomic rsync of the .raw
#   * phase_refresh_restart— the reused, byte-identical refresh+restart verb
#   * phase_health         — post-restart is-active gate (+ optional operator probe)
#   * _verify_supported_flag — helper: which systemd-dissect verify flag this host has
#
# The 7th phase, phase_rollback, lives in the shared rollback-lib.sh (its body is
# byte-identical to the backend path's snapshot/restore verb and is owned there).
#
# Bodies extracted VERBATIM from dev-sync/sync-native.sh. No behaviour change —
# this file is a relocation of existing logic into one focused home.
#
# These read symbols the consumer (sync-native.sh) supplies before any phase is
# called: DRY_RUN, RESOLVED_TARGET, REMOTE_EXT_DIR (config.sh/transport.sh);
# REFRESH_RESTART_VERB, DEV_SYNC_HEALTH_WAIT, DEV_SYNC_HEALTH_PROBE, RAW_OVERRIDE
# (sync-native.sh); arch_guard/device_arch/host_arch (arch-lib.sh);
# _find_staged_binary (build-input-lib.sh); build_app_layer (interface.sh);
# transport_ssh/transport_rsync (transport.sh).
#
# shellcheck shell=bash
# shellcheck disable=SC2154  # DRY_RUN/RESOLVED_TARGET/REMOTE_EXT_DIR/REFRESH_RESTART_VERB/DEV_SYNC_HEALTH_*/RAW_OVERRIDE supplied by the sourcing consumer (config.sh/transport.sh/sync-native.sh)

PHASE_LIB_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# common.sh provides strict mode, the loud ERR trap, loggers, die, require_cmd.
# shellcheck source=../common.sh
source "${PHASE_LIB_HERE}/../common.sh"

# ---------------------------------------------------------------------------
# _verify_supported_flag — echo the systemd-dissect verification flag this host
# supports (`--verify` on older systemd, `--validate` on >=257), or nothing.
# ---------------------------------------------------------------------------
_verify_supported_flag() {
  command -v systemd-dissect >/dev/null 2>&1 || return 0
  local help
  help="$(systemd-dissect --help 2>&1)" || true
  if [[ "${help}" == *"--verify"* ]]; then
    printf '%s' "--verify"
  elif [[ "${help}" == *"--validate"* ]]; then
    printf '%s' "--validate"
  fi
}

# ---------------------------------------------------------------------------
# phase_arch_check <app> <staging|""> — REFUSE on an artifact↔device arch
# mismatch. Prefers arch_guard on a real staged binary (content truth). For a
# prebuilt-raw-only run (no binary to read) it compares host_arch vs device_arch
# and WARNS on mismatch (the operator explicitly supplied the .raw). DRY_RUN's
# device probe is logged by arch.sh; the local artifact read still runs.
# ---------------------------------------------------------------------------
phase_arch_check() {
  local app="$1" staging="$2"
  log_info "[arch-check] ${app}: artifact arch must match device arch"
  local bin=""
  [[ -n "${staging}" ]] && bin="$(_find_staged_binary "${staging}")"
  if [[ -n "${bin}" ]]; then
    arch_guard "${bin}"          # dies (non-zero) on mismatch — the hard gate
    return 0
  fi
  # No ELF to read (prebuilt .raw): best-effort host-vs-device comparison.
  local want host
  want="$(device_arch)"
  host="$(host_arch)"
  if [[ "${want}" != "${host}" ]]; then
    log_warn "[arch-check] ${app}: prebuilt .raw, cannot read inner ELF; build host is ${host} but device is ${want} — ensure the .raw was built for ${want}."
  else
    log_success "[arch-check] ${app}: build host ${host} matches device ${want} (prebuilt .raw heuristic)"
  fi
}

# ---------------------------------------------------------------------------
# phase_build <app> <staging|""> <out_dir> — produce <app>.raw. With a prebuilt
# --raw it is used as-is (build skipped). Otherwise the SAME build_app_layer verb
# prod/dev-push use is invoked (stdout suppressed per the documented mksquashfs
# stdout caveat; the deterministic <out_dir>/<app>.raw path is referenced). In
# DRY_RUN with no real staging the build is logged, not executed. Echoes the .raw.
# ---------------------------------------------------------------------------
phase_build() {
  local app="$1" staging="$2" out_dir="$3"
  local raw_var raw
  raw_var="${app^^}_RAW"; raw_var="${raw_var//-/_}"
  raw="${!raw_var:-${RAW_OVERRIDE:-}}"

  if [[ -n "${raw}" ]]; then
    [[ -f "${raw}" ]] || die "[build] ${app}: --raw '${raw}' not found"
    log_info "[build] ${app}: using prebuilt raw ${raw} (skipping build_app_layer)"
    printf '%s' "${raw}"
    return 0
  fi

  local artifact="${out_dir}/${app}.raw"
  if [[ -n "${staging}" && -d "${staging}" ]]; then
    log_info "[build] ${app}: build_app_layer (sysext) from ${staging} → ${artifact}"
    # Same caveat as dev-push: mksquashfs can pollute stdout; drive the side
    # effect and reference the deterministic artifact path, never the capture.
    build_app_layer "${app}" "${staging}" "${out_dir}" >/dev/null
    [[ -f "${artifact}" ]] || die "[build] ${app}: build_app_layer did not produce ${artifact}"
    log_success "[build] ${app}: built ${artifact} ($(du -h "${artifact}" | cut -f1))"
  elif [[ "${DRY_RUN}" == "1" ]]; then
    log_info "[build] ${app}: [DRY_RUN] would build_app_layer ${app} <staging> ${out_dir} → ${artifact}"
  else
    die "[build] ${app}: no build input — pass --raw <file>, --staging <dir>, or --from-deb <dir>"
  fi
  printf '%s' "${artifact}"
}

# ---------------------------------------------------------------------------
# phase_verify <app> <raw> — gate the .raw BEFORE any device mutation. Optional
# systemd-dissect (--verify/--validate) when available; then a squashfs-superblock
# check (unsquashfs -s, then `file`) as the always-available net. A corrupt/invalid
# .raw returns non-zero → caller ABORTS before push (device untouched). When the
# .raw doesn't exist yet (DRY_RUN planned path), the verify is logged, not run.
# ---------------------------------------------------------------------------
phase_verify() {
  local app="$1" raw="$2"
  if [[ ! -f "${raw}" ]]; then
    log_info "[verify] ${app}: [DRY_RUN] would systemd-dissect --verify / unsquashfs -s ${raw}"
    return 0
  fi

  local flag; flag="$(_verify_supported_flag)"
  if [[ -n "${flag}" ]]; then
    log_info "[verify] ${app}: systemd-dissect ${flag} ${raw}"
    if systemd-dissect "${flag}" "${raw}" >/dev/null 2>&1; then
      log_success "[verify] ${app}: systemd-dissect ${flag} OK"
      return 0
    fi
    log_error "[verify] ${app}: systemd-dissect ${flag} REJECTED ${raw} — aborting BEFORE push (device untouched)"
    return 1
  fi

  # Graceful degrade: systemd-dissect lacks a verify flag (or is absent).
  log_warn "[verify] ${app}: systemd-dissect verify flag unavailable — using squashfs superblock check"
  if command -v unsquashfs >/dev/null 2>&1; then
    log_info "[verify] ${app}: unsquashfs -s ${raw}"
    if unsquashfs -s "${raw}" >/dev/null 2>&1; then
      log_success "[verify] ${app}: valid squashfs superblock"
      return 0
    fi
    log_error "[verify] ${app}: NOT a valid squashfs — aborting BEFORE push (device untouched)"
    return 1
  fi
  log_info "[verify] ${app}: file ${raw}"
  if file -bL "${raw}" | grep -qi 'squashfs'; then
    log_success "[verify] ${app}: file reports a squashfs filesystem"
    return 0
  fi
  log_error "[verify] ${app}: not a squashfs filesystem — aborting BEFORE push (device untouched)"
  return 1
}

# ---------------------------------------------------------------------------
# phase_push <app> <raw> — A/B snapshot then push. First snapshots the live
# <ext>/<app>.raw → <ext>/<app>-rollback.raw (if present) so a failed deploy can
# be reverted, then transport_rsync's the new .raw into place atomically
# (--temp-dir + atomic rename, --checksum for the binary). DRY_RUN logs both.
# ---------------------------------------------------------------------------
phase_push() {
  local app="$1" raw="$2"
  local dest="${REMOTE_EXT_DIR%/}/${app}.raw"
  local rollback="${REMOTE_EXT_DIR%/}/${app}-rollback.raw"

  log_info "[push] ${app}: snapshot live ${dest} → ${rollback} (A/B rollback point)"
  transport_ssh "[ -f '${dest}' ] && cp -f '${dest}' '${rollback}' || echo 'sync-native: no live ${app}.raw to snapshot (first deploy)'"

  log_info "[push] ${app}: ${raw} → ${RESOLVED_TARGET}:${dest} (atomic, --binary)"
  transport_rsync "${raw}" "${dest}" --binary
}

# ---------------------------------------------------------------------------
# phase_refresh_restart — run the reused, byte-identical refresh+restart verb on
# the device. Returns the remote status WITHOUT tearing down (so the `&&` graceful
# path is observable and a non-zero status routes into rollback).
# ---------------------------------------------------------------------------
phase_refresh_restart() {
  log_info "[refresh] + [restart] remote: ${REFRESH_RESTART_VERB}"
  local status=0
  transport_ssh "${REFRESH_RESTART_VERB}" || status=$?
  if (( status != 0 )); then
    log_error "[refresh/restart] FAILED (status ${status}) — 'systemd-sysext refresh' rejected the .raw; the '&&' skipped the restart, so the PREVIOUS extension stays merged and ceralive.service keeps running the OLD version (graceful)."
  fi
  return "${status}"
}

# ---------------------------------------------------------------------------
# phase_health — post-restart gate. Lets the service settle, then requires
# `systemctl is-active ceralive.service` == active, plus an optional operator
# probe (DEV_SYNC_HEALTH_PROBE). Returns non-zero on an unhealthy service. DRY_RUN
# logs the planned checks and passes.
# ---------------------------------------------------------------------------
phase_health() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    local probe_note=""
    [[ -n "${DEV_SYNC_HEALTH_PROBE}" ]] && probe_note="; ssh ${DEV_SYNC_HEALTH_PROBE}"
    log_info "[health] [DRY_RUN] would sleep ${DEV_SYNC_HEALTH_WAIT}s; ssh systemctl is-active ceralive.service${probe_note}"
    return 0
  fi

  log_info "[health] settling ${DEV_SYNC_HEALTH_WAIT}s before probe"
  sleep "${DEV_SYNC_HEALTH_WAIT}"

  local active=""
  active="$(transport_ssh "systemctl is-active ceralive.service" 2>/dev/null || true)"
  active="${active//[$'\r\n']/}"
  if [[ "${active}" != "active" ]]; then
    log_error "[health] ceralive.service is '${active:-unknown}' (expected 'active')"
    return 1
  fi
  log_success "[health] ceralive.service is active"

  if [[ -n "${DEV_SYNC_HEALTH_PROBE}" ]]; then
    log_info "[health] probe: ${DEV_SYNC_HEALTH_PROBE}"
    if ! transport_ssh "${DEV_SYNC_HEALTH_PROBE}"; then
      log_error "[health] probe FAILED: ${DEV_SYNC_HEALTH_PROBE}"
      return 1
    fi
    log_success "[health] probe OK"
  fi
  return 0
}
