#!/usr/bin/env bash
#
# sync-native.sh — hardened native-binary (srtla) dev-sync wrapper.
#
#   sync-native.sh [options] [board-ip] [app ...]      (default apps: srtla)
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
#                       env: <APP>_RAW   e.g. SRTLA_RAW=/path/srtla.raw
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
# config.sh + transport.sh: previously pulled in transitively by arch.sh. Sourced
# explicitly now because arch-lib.sh (below) does NOT re-source them.
# shellcheck source=config.sh
source "${SYNC_NATIVE_HERE}/config.sh"
# shellcheck source=transport.sh
source "${SYNC_NATIVE_HERE}/transport.sh"

# Wave-0 shared libs. arch_guard/device_arch/host_arch (arch-lib) and the native
# phase_rollback (rollback-lib) are called below; health-gate-lib's health_gate is
# the backend HTTP gate — the native post-restart gate is phase_health (phase-lib).
# shellcheck source=../shared/arch-lib.sh
source "${SYNC_NATIVE_HERE}/../shared/arch-lib.sh"
# shellcheck source=../shared/health-gate-lib.sh
source "${SYNC_NATIVE_HERE}/../shared/health-gate-lib.sh"
# shellcheck source=../shared/rollback-lib.sh
source "${SYNC_NATIVE_HERE}/../shared/rollback-lib.sh"

# Native phases + build-input resolution, split out of this orchestrator.
# shellcheck source=build-input-lib.sh
source "${SYNC_NATIVE_HERE}/build-input-lib.sh"
# shellcheck source=phase-lib.sh
source "${SYNC_NATIVE_HERE}/phase-lib.sh"

# Default apps = the pure-binary, sysext-ready first-party components, matching
# dev-push:DEFAULT_APPS exactly. CeraUI uses the appfs backend, not this path.
# cerastream dev-sync is a follow-on (IPC-driven engine, different sync shape)
SYNC_NATIVE_DEFAULT_APPS=(srtla)

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
