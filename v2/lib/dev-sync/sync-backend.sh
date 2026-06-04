#!/usr/bin/env bash
#
# sync-backend.sh — build + deploy the CeraUI backend binary to a dev device,
# behind an arch guard, with a health gate and automatic rollback.
#
# This is the dev-sync component path for the CeraUI backend (the Bun-compiled
# single-file `ceralive` binary the device runs as ceralive.service). Unlike the
# frontend (disk-served static files), the backend is a binary that REPLACES a
# running process — so it needs a restart, a health probe, and a way to undo a
# bad push. The flow is:
#
#   resolve device → ARCH GUARD → build (device arch) → verify artifact arch →
#   back up current binary as `ceralive-old` → ATOMIC rsync new binary into
#   place → restart ceralive.service → HEALTH GATE (is-active + HTTP probe) →
#   on failure: ROLLBACK (restore ceralive-old → restart → verify active) and
#   exit non-zero.
#
# It is a DEVELOPER CONVENIENCE loop, NOT a production deploy path. It must never
# leave the device with a failed/non-running service: either the new binary is
# healthy, or the previous binary is restored and verified healthy, or we die
# loudly having done our best to keep the old one running.
#
# Reuses the Task-4 dev-sync foundation verbatim:
#   config.sh    — device target + DEV_SYNC_* knobs + DRY_RUN
#   transport.sh — resolve_target, ssh_preflight, transport_ssh, transport_rsync
#                  (already does --temp-dir + atomic `<dest>.dev-sync.tmp`→mv -f)
#   arch.sh      — host_arch, artifact_arch, device_arch, arch_guard
#
# Env knobs (in addition to the config.sh / transport.sh family):
#   DRY_RUN=1                      log the full plan, execute NOTHING.
#   DEV_SYNC_CERAUI_REMOTE         remote dir holding the binary (def /opt/ceralive).
#   DEV_SYNC_BACKEND_BINARY        binary basename on the device (def "ceralive").
#   DEV_SYNC_HEALTH_PORT           device HTTP port to probe (def 80; prod server
#                                  binds 80→8080→81, there is NO /health route —
#                                  `/` returns the SPA index.html with 200).
#   DEV_SYNC_HEALTH_PATH           HTTP path to probe (def "/").
#   DEV_SYNC_HEALTH_RETRIES        health probe attempts (def 15).
#   DEV_SYNC_HEALTH_INTERVAL       seconds between attempts (def 2).
#   DEV_SYNC_ALLOW_CROSS_BUILD=1   skip the host==device pre-build guard (you are
#                                  knowingly cross-compiling via bun --target).
#   DEV_SYNC_FORCE_HEALTH_FAIL=1   QA fault-injection: force the health gate to
#                                  fail so the rollback path can be exercised.
#
# shellcheck shell=bash

set -euo pipefail

SYNC_BACKEND_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Task-4 foundation. Source order per Task-4 contract: config first, then
# transport, then arch (arch re-sources both; a sentinel keeps config's load
# idempotent so we never double-parse the yaml).
# shellcheck source=config.sh
source "${SYNC_BACKEND_HERE}/config.sh"
# shellcheck source=transport.sh
source "${SYNC_BACKEND_HERE}/transport.sh"
# shellcheck source=arch.sh
source "${SYNC_BACKEND_HERE}/arch.sh"

# ---------------------------------------------------------------------------
# Settled config for this component.
# ---------------------------------------------------------------------------
# CeraUI lives as a sibling of image-building-pipeline under the workspace root
# (config.sh resolves DEV_SYNC_WORKSPACE_ROOT to that parent).
CERAUI_DIR="${DEV_SYNC_WORKSPACE_ROOT}/CeraUI"
BACKEND_DIR="${CERAUI_DIR}/apps/backend"
# `bun run build:backend-only` (run from apps/backend) emits ../../dist/ceralive.
BUILT_BINARY="${CERAUI_DIR}/dist/ceralive"

# Remote destination: the binary the ceralive.service ExecStart points at
# (/opt/ceralive/ceralive), plus its rollback shadow copy.
DEV_SYNC_BACKEND_BINARY="${DEV_SYNC_BACKEND_BINARY:-ceralive}"
REMOTE_DIR="${DEV_SYNC_CERAUI_REMOTE%/}"
REMOTE_BINARY="${REMOTE_DIR}/${DEV_SYNC_BACKEND_BINARY}"
REMOTE_BINARY_OLD="${REMOTE_BINARY}-old"

# Health gate tunables.
DEV_SYNC_HEALTH_PORT="${DEV_SYNC_HEALTH_PORT:-80}"
DEV_SYNC_HEALTH_PATH="${DEV_SYNC_HEALTH_PATH:-/}"
DEV_SYNC_HEALTH_RETRIES="${DEV_SYNC_HEALTH_RETRIES:-15}"
DEV_SYNC_HEALTH_INTERVAL="${DEV_SYNC_HEALTH_INTERVAL:-2}"
DEV_SYNC_SERVICE="${DEV_SYNC_SERVICE:-ceralive.service}"

# Behaviour knobs.
DEV_SYNC_ALLOW_CROSS_BUILD="${DEV_SYNC_ALLOW_CROSS_BUILD:-0}"
DEV_SYNC_FORCE_HEALTH_FAIL="${DEV_SYNC_FORCE_HEALTH_FAIL:-0}"

# ---------------------------------------------------------------------------
# preflight_guard — resolve the device, then assert the host can produce a
# binary the device can actually run. bun `--compile --target=` can technically
# cross-compile, but the Task brief requires host arch == device arch (the
# bytecode/native path is most reliable built natively); DEV_SYNC_ALLOW_CROSS_BUILD=1
# is the deliberate escape hatch.
# ---------------------------------------------------------------------------
preflight_guard() {
  log_info "sync-backend: resolving device target…"
  resolve_target   # sets RESOLVED_TARGET / RESOLVED_VIA (DRY_RUN assumes first candidate)

  local host want
  host="$(host_arch)"
  want="$(device_arch)"   # DEV_SYNC_DEVICE_ARCH override / ssh uname -m / DRY_RUN=host

  if [[ "${host}" != "${want}" ]]; then
    if [[ "${DEV_SYNC_ALLOW_CROSS_BUILD}" == "1" ]]; then
      log_warn "sync-backend: host=${host} != device=${want}, but DEV_SYNC_ALLOW_CROSS_BUILD=1 — cross-building via bun --target=${want}."
    else
      die "sync-backend: REFUSING build — host is ${host} but device is ${want}. Build on a ${want} host, or set DEV_SYNC_ALLOW_CROSS_BUILD=1 to cross-compile via 'bun --target'."
    fi
  else
    log_success "sync-backend: arch pre-check OK — host ${host} == device ${want}."
  fi

  # Export the resolved device arch for the build step (BUILD_ARCH speaks amd64/arm64).
  BUILD_TARGET_ARCH="${want}"
}

# ---------------------------------------------------------------------------
# build_backend — produce the device-arch binary via the canonical CeraUI build
# script (keeps the --compile/--minify/--bytecode/--target flags in ONE place:
# apps/backend/package.json `build:backend-only`). Then verify the produced
# artifact's arch against the device with the Task-4 arch_guard.
# ---------------------------------------------------------------------------
build_backend() {
  [[ -d "${BACKEND_DIR}" ]] || die "build_backend: backend dir not found: ${BACKEND_DIR}"

  if [[ "${DRY_RUN}" == "1" ]]; then
    log_info "[DRY_RUN] (cd ${BACKEND_DIR} && BUILD_ARCH=${BUILD_TARGET_ARCH} bun run build:backend-only)  # → ${BUILT_BINARY}"
    log_info "[DRY_RUN] arch_guard ${BUILT_BINARY}  # verify artifact arch == device ${BUILD_TARGET_ARCH}"
    return 0
  fi

  require_cmd bun
  log_info "sync-backend: building backend for ${BUILD_TARGET_ARCH} (bun run build:backend-only)…"
  ( cd "${BACKEND_DIR}" && BUILD_ARCH="${BUILD_TARGET_ARCH}" bun run build:backend-only )

  [[ -f "${BUILT_BINARY}" ]] || die "build_backend: expected artifact missing after build: ${BUILT_BINARY}"

  # Reuse the Task-4 guard on the REAL artifact (reads its arch via `file`).
  arch_guard "${BUILT_BINARY}"
  log_success "sync-backend: built ${BUILT_BINARY} ($(artifact_arch "${BUILT_BINARY}"))."
}

# ---------------------------------------------------------------------------
# backup_current — snapshot the in-place binary as `<binary>-old` so rollback
# has a known-good target. No-op (logged) on a first-ever deploy.
# ---------------------------------------------------------------------------
backup_current() {
  log_info "sync-backend: backing up current ${REMOTE_BINARY} → ${REMOTE_BINARY_OLD} (if present)"
  transport_ssh "if [ -f '${REMOTE_BINARY}' ]; then cp -af '${REMOTE_BINARY}' '${REMOTE_BINARY_OLD}'; else echo 'no existing binary to back up'; fi"
}

# ---------------------------------------------------------------------------
# deploy_binary — atomic rsync of the freshly-built binary into place, then mark
# it executable. transport_rsync handles the --temp-dir + `<dest>.dev-sync.tmp`
# → `mv -f` atomic swap and uses --checksum for --binary pushes.
# ---------------------------------------------------------------------------
deploy_binary() {
  transport_rsync "${BUILT_BINARY}" "${REMOTE_BINARY}" --binary
  transport_ssh "chmod +x '${REMOTE_BINARY}'"
}

# ---------------------------------------------------------------------------
# restart_service <reason> — restart ceralive.service. Returns the systemctl
# exit status (guarded by callers; never trips the ERR trap on its own).
# ---------------------------------------------------------------------------
restart_service() {
  local reason="${1:-deploy}"
  log_info "sync-backend: systemctl restart ${DEV_SYNC_SERVICE} (${reason})"
  transport_ssh "systemctl restart '${DEV_SYNC_SERVICE}'"
}

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
# main — the full sync-backend pipeline.
# ---------------------------------------------------------------------------
main() {
  log_info "==== sync-backend: CeraUI backend → ${SSH_USER}@${DEV_SYNC_TARGET_HOST:-${DEV_SYNC_TARGET_IP}} (DRY_RUN=${DRY_RUN}) ===="

  preflight_guard
  build_backend
  backup_current
  deploy_binary

  if ! restart_service "deploy"; then
    log_error "sync-backend: ${DEV_SYNC_SERVICE} restart FAILED after deploy."
    rollback
    die "sync-backend: deploy aborted (restart failed); rollback completed."
  fi

  if health_gate; then
    log_success "==== sync-backend: DEPLOY HEALTHY — new ${DEV_SYNC_BACKEND_BINARY} live on the device. ===="
    return 0
  fi

  log_error "sync-backend: post-deploy health gate FAILED — rolling back."
  rollback
  die "sync-backend: deploy FAILED health gate; rolled back to previous binary."
}

# Sourceable as a library; runnable for the loop / QA.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
