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

# Wave-0 shared libs: arch guard, health gate, rollback verbs.
# shellcheck source=../shared/arch-lib.sh
source "${SYNC_BACKEND_HERE}/../shared/arch-lib.sh"
# shellcheck source=../shared/health-gate-lib.sh
source "${SYNC_BACKEND_HERE}/../shared/health-gate-lib.sh"
# shellcheck source=../shared/rollback-lib.sh
source "${SYNC_BACKEND_HERE}/../shared/rollback-lib.sh"

# ---------------------------------------------------------------------------
# Settled config for this component.
# ---------------------------------------------------------------------------
CERAUI_DIR="${DEV_SYNC_CERAUI_DIR:-}"
[[ -n "${CERAUI_DIR}" ]] || die "DEV_SYNC_CERAUI_DIR must name the CeraUI checkout"
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
