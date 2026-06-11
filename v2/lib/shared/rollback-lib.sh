#!/usr/bin/env bash
#
# rollback-lib.sh — shared dev-sync rollback verbs for the CeraLive v2 pipeline.
#
# Two flavours, one per deploy path:
#   * rollback        — restore the previous CeraUI backend binary (`<binary>-old`)
#                       and bring ceralive.service back to `active`. Used by the
#                       backend (binary-replace) path.
#   * phase_rollback  — restore each app's `<app>-rollback.raw` snapshot over
#                       `<app>.raw` and re-run the reused refresh+restart verb so
#                       the device returns to the last-known-good extension. Used
#                       by the native (srtla sysext) path.
#
# Bodies extracted VERBATIM from dev-sync/sync-backend.sh (rollback) and
# dev-sync/sync-native.sh (phase_rollback). No behaviour change — this file is a
# relocation of existing logic into one shared home.
#
# Both read symbols a consumer supplies: rollback needs REMOTE_BINARY/-OLD,
# DEV_SYNC_SERVICE, DEV_SYNC_HEALTH_*, restart_service, transport_ssh, DRY_RUN,
# SSH_USER, RESOLVED_TARGET; phase_rollback needs REMOTE_EXT_DIR,
# REFRESH_RESTART_VERB, transport_ssh. config.sh + transport.sh are sourced by the
# consumer (sync-backend.sh / sync-native.sh) before these are called.
#
# shellcheck shell=bash
# shellcheck disable=SC2154  # REMOTE_*/DEV_SYNC_*/REFRESH_RESTART_VERB/SSH_USER/RESOLVED_TARGET/DRY_RUN supplied by the sourcing consumer (config.sh/transport.sh/sync-backend.sh/sync-native.sh)

ROLLBACK_LIB_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# common.sh provides strict mode, the loud ERR trap, loggers, die, require_cmd.
# shellcheck source=../common.sh
source "${ROLLBACK_LIB_HERE}/../common.sh"

# ---------------------------------------------------------------------------
# rollback — restore the previous binary and bring the service back to `active`.
# Invoked only when the post-deploy health gate fails. Always exits the script
# non-zero afterwards: a failed deploy is a failure even if rollback succeeds.
# ---------------------------------------------------------------------------
rollback() {
  log_error "sync-backend: initiating ROLLBACK to ${REMOTE_BINARY_OLD}."

  if [[ "${DRY_RUN}" == "1" ]]; then
    log_info "[DRY_RUN] ssh ${SSH_USER}@${RESOLVED_TARGET} 'if [ -f ${REMOTE_BINARY_OLD} ]; then mv -f ${REMOTE_BINARY_OLD} ${REMOTE_BINARY}; fi'"
    log_info "[DRY_RUN] ssh ${SSH_USER}@${RESOLVED_TARGET} systemctl restart ${DEV_SYNC_SERVICE}"
    log_info "[DRY_RUN] ssh ${SSH_USER}@${RESOLVED_TARGET} systemctl is-active ${DEV_SYNC_SERVICE}  # expect: active"
    log_warn "[DRY_RUN] rollback plan logged; exiting non-zero to signal the failed deploy."
    return 0
  fi

  # No backup means a first-ever deploy went bad: nothing to restore. The
  # service has Restart=always, so leave it; surface a loud error.
  if ! transport_ssh "[ -f '${REMOTE_BINARY_OLD}' ]"; then
    die "sync-backend: ROLLBACK IMPOSSIBLE — no ${REMOTE_BINARY_OLD} to restore (first deploy?). ${DEV_SYNC_SERVICE} may be crash-looping; investigate the device."
  fi

  transport_ssh "mv -f '${REMOTE_BINARY_OLD}' '${REMOTE_BINARY}' && chmod +x '${REMOTE_BINARY}'"

  if ! restart_service "rollback"; then
    die "sync-backend: ROLLBACK restart of ${DEV_SYNC_SERVICE} FAILED — device needs manual recovery."
  fi

  # Verify the restored binary brings the service back to active.
  local attempt
  for (( attempt = 1; attempt <= DEV_SYNC_HEALTH_RETRIES; attempt++ )); do
    if transport_ssh "systemctl is-active --quiet '${DEV_SYNC_SERVICE}'"; then
      log_success "sync-backend: ROLLBACK OK — ${DEV_SYNC_SERVICE} is active on the previous binary."
      return 0
    fi
    log_warn "sync-backend: post-rollback service not active yet (attempt ${attempt}/${DEV_SYNC_HEALTH_RETRIES})…"
    sleep "${DEV_SYNC_HEALTH_INTERVAL}"
  done

  die "sync-backend: ROLLBACK restored the old binary but ${DEV_SYNC_SERVICE} did not return to active — manual recovery required."
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
