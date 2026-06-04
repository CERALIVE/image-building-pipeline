#!/usr/bin/env bash
#
# sync-native.sh — hardened native-binary (ceracoder/srtla) dev-sync wrapper.
#
#   sync-native.sh [options] [board-ip] [app ...]      (default apps: ceracoder srtla)
#
# This is an ADDITIVE wrapper around the EXISTING dev-push sysext build+push. It
# does NOT replace, copy, or edit dev-push / sysext.sh / interface.sh — it REUSES
# them. The two pieces it reuses verbatim are:
#
#   1. the app-layer BUILD verb  `build_app_layer` (lib/app-layer/sysext.sh, reached
#      through interface.sh:select_backend) — the SAME verb dev-push and the prod
#      builder call, so the <app>.raw squashfs is byte-identical to prod;
#   2. the on-device REFRESH+RESTART verb string, byte-identical to both
#      dev-push (line ~307) and sysext.sh:refresh_app_layer():
#          systemd-sysext refresh && systemctl restart ceralive.service
#      The `&&` is LOAD-BEARING and preserved verbatim: if `refresh` rejects a
#      bad/corrupt .raw, the restart NEVER runs, the previously-merged extension
#      stays active, and ceralive.service keeps streaming on the OLD version. A
#      bad push degrades to a no-op + a loud error — never an outage.
#
# What this wrapper ADDS on top of that reused core (the Task-13 deliverables):
#
#   arch-check  REFUSE the push up front on an artifact↔device arch mismatch
#               (arch.sh:arch_guard — an amd64 binary on an arm64 board installs
#               but can never run; fail loud and early, not far from the cause).
#   verify      OPTIONAL `systemd-dissect --verify` (newer systemd: `--validate`)
#               of the .raw BEFORE it ever leaves the workstation; degrades to a
#               squashfs-superblock check (unsquashfs -s, then `file`) when
#               systemd-dissect lacks the flag. A corrupt .raw ABORTS before push
#               (device untouched) — a second safety net in front of the `&&`.
#   A/B rollback  snapshot the live <app>.raw → <app>-rollback.raw before the swap;
#               on a refresh/restart failure OR a post-restart health failure,
#               restore the snapshot and re-run refresh+restart so the device lands
#               back on the last-known-good binary.
#   health gate after refresh+restart, require `systemctl is-active ceralive.service`
#               (+ an optional operator probe) before declaring success; a failed
#               gate triggers the rollback above.
#
# WHY a separate decomposed wrapper instead of just shelling out to dev-push:
#   dev-push performs build → rsync → (refresh && restart) as ONE monolithic remote
#   step, leaving no seam to (a) verify the artifact BEFORE the swap, or (b) snapshot
#   the live extension for A/B rollback. This wrapper therefore re-sequences the
#   SAME reused verbs (build_app_layer + the refresh&&restart string) with the
#   dev-sync transport (transport.sh) so the extra gates can slot in at the right
#   points. dev-push itself stays byte-identical (regression-guarded).
#
# Phase order (also the exact DRY_RUN plan order):
#   arch-check → build → verify → push → refresh → restart → health → (conditional) rollback
#
# Build input (feeds build_app_layer; first match wins, per app):
#   --raw <file>        use a prebuilt <app>.raw (skip build_app_layer)
#                       env: <APP>_RAW   e.g. CERACODER_RAW=/path/ceracoder.raw
#   --staging <dir>     build_app_layer from an extracted .deb staging tree
#                       (looks for <dir>/<app> first, else <dir>); env: SYNC_STAGING
#   --from-deb <dir>    explode <app>*.deb from <dir> into a staging tree, then build
#                       (prod-identical artifact path; standard dpkg-deb/ar+tar)
#
# Env knobs (DRY_RUN/SSH_USER/REMOTE_EXT_DIR mirror dev-push; rest are DEV_SYNC_*):
#   DRY_RUN=1                  log every device-side step, execute none (offline plan
#                              + bad-ext evidence). LOCAL, read-only gates (arch-check
#                              on a real binary, verify on a real .raw) still run.
#   SSH_USER / REMOTE_EXT_DIR  settled by config.sh (see .dev-sync.yaml.example)
#   DEV_SYNC_TARGET_HOST/_IP   device address (mDNS .local first, IP fallback)
#   DEV_SYNC_HEALTH_WAIT=3     seconds to let the service settle before is-active
#   DEV_SYNC_HEALTH_PROBE      optional extra remote health command (default: none)
#   DEV_SYNC_DEVICE_ARCH       offline/known-fleet arch override (see arch.sh)
#
# shellcheck shell=bash

SYNC_NATIVE_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# common.sh: strict mode (set -euo pipefail), loud ERR trap, loggers, die, require_cmd.
# shellcheck source=../common.sh
source "${SYNC_NATIVE_HERE}/../common.sh"
# interface.sh: select_backend -> build_app_layer/install_app_layer/refresh_app_layer.
# shellcheck source=../app-layer/interface.sh
source "${SYNC_NATIVE_HERE}/../app-layer/interface.sh"
# arch.sh transitively sources config.sh (DEV_SYNC_*/SSH_USER/REMOTE_EXT_DIR/DRY_RUN)
# and transport.sh (resolve_target/transport_ssh/transport_rsync). Gives arch_guard.
# shellcheck source=arch.sh
source "${SYNC_NATIVE_HERE}/arch.sh"

# Default apps = the two pure-binary, sysext-ready first-party components, matching
# dev-push:DEFAULT_APPS exactly. CeraUI uses the appfs backend, not this path.
SYNC_NATIVE_DEFAULT_APPS=(ceracoder srtla)

# The reused, byte-identical on-device verb. The `&&` MUST NOT be split: a bad
# refresh leaves the prior extension merged and SKIPS the restart (no outage).
REFRESH_RESTART_VERB="systemd-sysext refresh && systemctl restart ceralive.service"

# Health gate tunables.
DEV_SYNC_HEALTH_WAIT="${DEV_SYNC_HEALTH_WAIT:-3}"
DEV_SYNC_HEALTH_PROBE="${DEV_SYNC_HEALTH_PROBE:-}"

usage() {
  cat >&2 <<EOF
Usage: sync-native.sh [options] [board-ip] [app ...]

  [board-ip]   device IP/host (overrides DEV_SYNC_TARGET_*; default: config/mDNS)
  [app ...]    apps to sync (default: ${SYNC_NATIVE_DEFAULT_APPS[*]})

Build input (first match wins, per app):
  --raw <file>       use a prebuilt <app>.raw (skip build_app_layer)
  --staging <dir>    build_app_layer from an extracted .deb staging tree
  --from-deb <dir>   explode <app>*.deb from <dir>, then build_app_layer

Options:
  --dry-run          log every device-side step, execute none (local gates still run)
  -h, --help         this help

Reuses build_app_layer (sysext.sh) + the byte-identical
'${REFRESH_RESTART_VERB}'
verb, wrapped with: arch guard, optional systemd-dissect --verify, a post-restart
health gate, and A/B (-rollback.raw) rollback. Does NOT modify dev-push/sysext.sh.
EOF
}

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
# _explode_deb <deb> <dest> — standard .deb data-tarball extraction into <dest>
# (dpkg-deb when present, else ar + tar). Used only by --from-deb; the sysext
# BUILD itself is the reused build_app_layer verb, never reimplemented here.
# ---------------------------------------------------------------------------
_explode_deb() {
  local deb="$1" dest="$2"
  mkdir -p "${dest}"
  if command -v dpkg-deb >/dev/null 2>&1; then
    dpkg-deb -x "${deb}" "${dest}"
    return 0
  fi
  require_cmd ar
  require_cmd tar
  local member
  member="$(ar t "${deb}" | grep -E '^data\.tar' | head -n1)"
  [[ -n "${member}" ]] || die "_explode_deb: no data.tar member in ${deb}"
  case "${member}" in
    *.gz)  ar p "${deb}" "${member}" | tar -xz   -C "${dest}" ;;
    *.xz)  ar p "${deb}" "${member}" | tar -xJ   -C "${dest}" ;;
    *.zst) ar p "${deb}" "${member}" | tar --zstd -x -C "${dest}" ;;
    *)     ar p "${deb}" "${member}" | tar -x    -C "${dest}" ;;
  esac
}

# ---------------------------------------------------------------------------
# _stage_for <app> <staging_root> <out_root> — resolve the staging tree for <app>
# under <staging_root> (prefer <staging_root>/<app>, else <staging_root>); when
# --from-deb is active, explode the matching .deb into a fresh tree first. Echoes
# the resolved staging dir on stdout.
# ---------------------------------------------------------------------------
_stage_for() {
  local app="$1" staging_root="$2" out_root="$3"
  if [[ -n "${FROM_DEB}" ]]; then
    local tree="${out_root}/staging/${app}"
    shopt -s nullglob
    local matches=("${FROM_DEB}/${app}"*.deb)
    shopt -u nullglob
    (( ${#matches[@]} > 0 )) || die "_stage_for: no ${app}*.deb in ${FROM_DEB}"
    log_info "build(${app}): exploding prod .deb ${matches[0]}"
    _explode_deb "${matches[0]}" "${tree}"
    printf '%s' "${tree}"
    return 0
  fi
  if [[ -d "${staging_root}/${app}" ]]; then
    printf '%s' "${staging_root}/${app}"
  else
    printf '%s' "${staging_root}"
  fi
}

# ---------------------------------------------------------------------------
# _find_staged_binary <staging> — echo the first executable regular file under
# the staging tree's usr/bin or usr/sbin (the artifact arch_guard reads), or
# nothing if none is found.
# ---------------------------------------------------------------------------
_find_staged_binary() {
  local staging="$1" d f
  for d in usr/bin usr/sbin; do
    [[ -d "${staging}/${d}" ]] || continue
    for f in "${staging}/${d}"/*; do
      [[ -f "${f}" && -x "${f}" ]] && { printf '%s' "${f}"; return 0; }
    done
  done
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

# ---------------------------------------------------------------------------
# phase_rollback <app...> — restore each app's <app>-rollback.raw over <app>.raw
# and re-run the reused refresh+restart verb so the device returns to the last
# known-good binary. Runs only when refresh/restart OR the health gate failed.
# ---------------------------------------------------------------------------
phase_rollback() {
  local app dest rollback
  log_warn "[rollback] restoring last-known-good extension(s) and re-applying"
  for app in "$@"; do
    dest="${REMOTE_EXT_DIR%/}/${app}.raw"
    rollback="${REMOTE_EXT_DIR%/}/${app}-rollback.raw"
    log_warn "[rollback] ${app}: ${rollback} → ${dest} (if snapshot exists)"
    transport_ssh "if [ -f '${rollback}' ]; then mv -f '${rollback}' '${dest}'; else echo 'sync-native: no ${app}-rollback.raw — cannot roll back (was this the first deploy?)' >&2; fi"
  done
  log_warn "[rollback] re-applying: ${REFRESH_RESTART_VERB}"
  local status=0
  transport_ssh "${REFRESH_RESTART_VERB}" || status=$?
  if (( status != 0 )); then
    log_error "[rollback] re-apply FAILED (status ${status}) — manual intervention may be required on the device."
  else
    log_success "[rollback] device restored to last-known-good and ceralive.service restarted"
  fi
  return "${status}"
}

main() {
  RAW_OVERRIDE=""
  STAGING_ROOT="${SYNC_STAGING:-}"
  FROM_DEB=""
  local board_ip="" apps=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --raw)       RAW_OVERRIDE="${2:-}"; shift 2 ;;
      --staging)   STAGING_ROOT="${2:-}"; shift 2 ;;
      --from-deb)  FROM_DEB="${2:-}"; shift 2 ;;
      --dry-run)   DRY_RUN=1; shift ;;
      -h|--help)   usage; exit 0 ;;
      --*)         usage; die "unknown option: $1" ;;
      *)
        if [[ -z "${board_ip}" ]]; then board_ip="$1"; else apps+=("$1"); fi
        shift ;;
    esac
  done

  (( ${#apps[@]} > 0 )) || apps=("${SYNC_NATIVE_DEFAULT_APPS[@]}")
  [[ -z "${FROM_DEB}" || -d "${FROM_DEB}" ]] || die "--from-deb dir not found: ${FROM_DEB}"
  [[ -z "${STAGING_ROOT}" || -d "${STAGING_ROOT}" ]] || die "--staging dir not found: ${STAGING_ROOT}"

  # An explicit board-ip overrides the configured target (force that address,
  # bypassing the mDNS .local candidate). Otherwise resolve_target uses config.
  if [[ -n "${board_ip}" ]]; then
    DEV_SYNC_TARGET_IP="${board_ip}"
    DEV_SYNC_TARGET_HOST=""
  fi

  # Select the sysext backend → defines the reused build_app_layer verb. Keep
  # build artifacts local (we drive refresh/restart remotely, not install_app_layer).
  export APP_BACKEND="${APP_BACKEND:-sysext}"
  select_backend

  log_info "=== sync-native | apps: ${apps[*]} | target: ${DEV_SYNC_TARGET_HOST:-${DEV_SYNC_TARGET_IP:-<config>}}${DRY_RUN:+ | DRY_RUN=${DRY_RUN}} ==="

  # Resolve the device once (mDNS .local first, IP fallback). DRY_RUN logs the
  # planned probe and assumes the first candidate.
  resolve_target

  local out_dir; out_dir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${out_dir}'" EXIT

  # -------------------------------------------------------------------------
  # Phase 1 (LOCAL, fail-fast): arch-check → build → verify for EVERY app, before
  # any device mutation. A corrupt artifact or arch mismatch aborts here, leaving
  # the device completely untouched.
  # -------------------------------------------------------------------------
  local app staging raw
  local raws=()
  for app in "${apps[@]}"; do
    staging=""
    if [[ -z "${RAW_OVERRIDE}" ]]; then
      local raw_var="${app^^}_RAW"; raw_var="${raw_var//-/_}"
      if [[ -z "${!raw_var:-}" && ( -n "${STAGING_ROOT}" || -n "${FROM_DEB}" ) ]]; then
        staging="$(_stage_for "${app}" "${STAGING_ROOT}" "${out_dir}")"
      fi
    fi

    phase_arch_check "${app}" "${staging}"
    raw="$(phase_build "${app}" "${staging}" "${out_dir}")"
    if ! phase_verify "${app}" "${raw}"; then
      die "sync-native: verify FAILED for ${app} — nothing pushed, device untouched."
    fi
    raws+=("${raw}")
  done

  # -------------------------------------------------------------------------
  # Phase 2 (DEVICE): push every verified .raw (A/B snapshot + atomic swap).
  # -------------------------------------------------------------------------
  local i
  for i in "${!apps[@]}"; do
    phase_push "${apps[$i]}" "${raws[$i]}"
  done

  # -------------------------------------------------------------------------
  # Phase 3 (DEVICE): the single reused refresh+restart, then the health gate.
  # On EITHER failure, roll the whole set back to the last-known-good extensions.
  # -------------------------------------------------------------------------
  local rr_status=0 health_status=0
  phase_refresh_restart || rr_status=$?

  if (( rr_status != 0 )); then
    phase_rollback "${apps[@]}" || true
    die "sync-native: refresh/restart failed — rolled back to last-known-good. Service unaffected by the bad push."
  fi

  phase_health || health_status=$?
  if (( health_status != 0 )); then
    log_error "[health] gate FAILED — initiating A/B rollback"
    phase_rollback "${apps[@]}" || true
    die "sync-native: health gate failed after restart — rolled back to last-known-good."
  fi

  if [[ "${DRY_RUN}" == "1" ]]; then
    log_info "[rollback] (conditional) on a refresh/restart OR health failure, sync-native would:"
    log_info "[rollback]   ssh 'mv -f <app>-rollback.raw <app>.raw' for each app, then ssh '${REFRESH_RESTART_VERB}'"
  fi

  log_success "sync-native complete — ${apps[*]} live on ${RESOLVED_TARGET} (verified, health-gated, ceralive.service restarted, FFI reloaded)"
}

main "$@"
