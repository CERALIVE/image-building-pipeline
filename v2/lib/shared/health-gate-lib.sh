#!/usr/bin/env bash
#
# health-gate-lib.sh — shared post-deploy health gate for the CeraLive v2 pipeline.
#
#   * health_gate — the deploy verdict. Passes only when ceralive.service is
#                   `active` AND an HTTP probe of the SPA root returns success,
#                   retried up to DEV_SYNC_HEALTH_RETRIES times. There is no
#                   dedicated /health route on the backend (Bun.serve serves
#                   static + WS only); `/` returning index.html with 200 is the
#                   liveness signal. Returns 0 healthy, 1 unhealthy.
#
# Body extracted VERBATIM from dev-sync/sync-backend.sh. No behaviour change —
# this file is a relocation of existing logic into one shared home.
#
# health_gate reads the dev-sync transport+config symbols a consumer supplies
# (RESOLVED_TARGET, SSH_USER, DRY_RUN, transport_ssh) plus the backend health
# tunables it defines (DEV_SYNC_HEALTH_*, DEV_SYNC_SERVICE, DEV_SYNC_FORCE_HEALTH_FAIL).
#
# shellcheck shell=bash
# shellcheck disable=SC2154  # DEV_SYNC_HEALTH_*/DEV_SYNC_SERVICE/SSH_USER/RESOLVED_TARGET/DRY_RUN supplied by the sourcing consumer (config.sh/transport.sh/sync-backend.sh)

HEALTH_GATE_LIB_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# common.sh provides strict mode, the loud ERR trap, loggers, die, require_cmd.
# shellcheck source=../common.sh
source "${HEALTH_GATE_LIB_HERE}/../common.sh"

# ---------------------------------------------------------------------------
# health_gate — the deploy verdict. Passes only when the service is `active`
# AND an HTTP probe of the SPA root returns success, retried up to
# DEV_SYNC_HEALTH_RETRIES times. There is no dedicated /health route on the
# backend (Bun.serve in server.ts serves static + WS only); `/` returning the
# index.html with a 200 is the liveness signal. Returns 0 healthy, 1 unhealthy.
# ---------------------------------------------------------------------------
health_gate() {
  local url="http://127.0.0.1:${DEV_SYNC_HEALTH_PORT}${DEV_SYNC_HEALTH_PATH}"

  if [[ "${DEV_SYNC_FORCE_HEALTH_FAIL}" == "1" ]]; then
    log_warn "sync-backend: DEV_SYNC_FORCE_HEALTH_FAIL=1 — forcing health gate FAILURE (QA fault-injection)."
    return 1
  fi

  if [[ "${DRY_RUN}" == "1" ]]; then
    log_info "[DRY_RUN] health gate: poll up to ${DEV_SYNC_HEALTH_RETRIES}× every ${DEV_SYNC_HEALTH_INTERVAL}s:"
    log_info "[DRY_RUN]   ssh ${SSH_USER}@${RESOLVED_TARGET} systemctl is-active ${DEV_SYNC_SERVICE}  # expect: active"
    log_info "[DRY_RUN]   ssh ${SSH_USER}@${RESOLVED_TARGET} curl -fsS -o /dev/null --max-time 5 ${url}  # expect: 2xx"
    log_success "[DRY_RUN] health gate assumed PASS"
    return 0
  fi

  # Remote one-liner: service active AND HTTP probe ok. curl preferred; wget
  # fallback for minimal images. Exits non-zero if either check fails.
  local probe
  probe="systemctl is-active --quiet '${DEV_SYNC_SERVICE}' && { command -v curl >/dev/null 2>&1 && curl -fsS -o /dev/null --max-time 5 '${url}' || wget -q -O /dev/null -T 5 '${url}'; }"

  local attempt
  for (( attempt = 1; attempt <= DEV_SYNC_HEALTH_RETRIES; attempt++ )); do
    if transport_ssh "${probe}"; then
      log_success "sync-backend: health gate PASS (attempt ${attempt}/${DEV_SYNC_HEALTH_RETRIES}) — ${DEV_SYNC_SERVICE} active + ${url} ok."
      return 0
    fi
    log_warn "sync-backend: health probe not ready (attempt ${attempt}/${DEV_SYNC_HEALTH_RETRIES}); retrying in ${DEV_SYNC_HEALTH_INTERVAL}s…"
    sleep "${DEV_SYNC_HEALTH_INTERVAL}"
  done

  log_error "sync-backend: health gate FAILED after ${DEV_SYNC_HEALTH_RETRIES} attempts."
  return 1
}
