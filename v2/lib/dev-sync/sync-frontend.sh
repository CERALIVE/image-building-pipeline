#!/usr/bin/env bash
#
# sync-frontend.sh — build the CeraUI frontend and ATOMICALLY publish it to the
# device's binary-served static dir, WITHOUT restarting ceralive.service.
#
# WHY no restart (the whole point of this script): CeraUI's Bun backend serves
# the frontend bundle straight off disk, per request (rpc/server.ts:serveStatic
# reads public/<file> at request time — see CeraUI/apps/backend AGENTS.md). New
# files therefore go live the instant they appear on disk; a service restart
# would needlessly tear down the in-process ceracoder/srtla FFI bindings and
# interrupt an active stream. dev-push restarts because it swaps the BINARY;
# a frontend-only sync must NOT. This is the stream-safety contract.
#
# WHY atomic (temp + rename): a plain rsync straight into the live static dir
# would briefly expose a half-synced tree — an index.html that references hashed
# asset chunks not yet written → broken page mid-stream. Instead we:
#   1. rsync the freshly-built bundle into a sibling staging dir (`<dest>.dev-sync.tmp`)
#      with --delete so the staged tree is an exact, complete copy;
#   2. swap it in with two back-to-back renames (move the old tree aside, move the
#      new tree into place) in a SINGLE ssh round-trip. The only visible window is
#      a sub-millisecond gap between two rename(2) calls during which the SPA index
#      404s → client-side fallback; a partial bundle is NEVER visible.
# `--delete` is used ONLY against the throwaway staging dir, never the live tree.
#
# Static path (resolved by setup.sh / Task 5): the backend's WorkingDirectory is
# /opt/ceralive, it serves ./public, and /opt/ceralive/public is a symlink to the
# real bundle dir /var/www/ceralive (staged there by the .deb). We sync into the
# REAL dir (/var/www/ceralive), never the /opt/ceralive/public symlink — renaming
# the symlink aside would destroy setup.sh's bridge. DEV_SYNC_CERAUI_REMOTE
# (=/opt/ceralive by default) is the component root; the served leaf is its
# public/ symlink, whose target is what we publish to.
#
# Reuses the Task 4 transport layer verbatim: config.sh settles every DEV_SYNC_*
# knob and transport.sh provides resolve_target + transport_ssh + the shared
# ssh/rsync option helpers. We do NOT duplicate host resolution or ssh wrapping.
#
# Env knobs (all optional; mirror dev-push / the rest of dev-sync):
#   DRY_RUN=1                         log every build/ssh/rsync/rename, run nothing
#   DEV_SYNC_CERAUI_DIR               CeraUI workspace root (default: <workspace>/CeraUI)
#   DEV_SYNC_FRONTEND_DIST            local build output (default: <CeraUI>/dist/public)
#   DEV_SYNC_FRONTEND_BUILD_CMD       build command (default: pnpm --filter frontend build)
#   DEV_SYNC_FRONTEND_SKIP_BUILD=1    sync the existing dist without rebuilding
#   DEV_SYNC_CERAUI_STATIC            remote served dir (default: /var/www/ceralive)
#   …plus every config.sh knob (SSH_USER, DEV_SYNC_TARGET_HOST/_IP, …).
#
# Usage:
#   sync-frontend.sh [--dry-run]
#
# shellcheck shell=bash

set -euo pipefail

SYNC_FE_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# config.sh sources common.sh (strict mode, loggers, die, require_cmd) and settles
# every DEV_SYNC_* / SSH_USER / DRY_RUN. transport.sh re-sources config.sh (the
# _DEV_SYNC_CONFIG_LOADED sentinel keeps that to a single settle) and adds
# resolve_target / transport_ssh / the shared ssh+rsync option helpers.
# shellcheck source=config.sh
source "${SYNC_FE_HERE}/config.sh"
# shellcheck source=transport.sh
source "${SYNC_FE_HERE}/transport.sh"

# ---------------------------------------------------------------------------
# Frontend-sync configuration (env-overridable; sane defaults from the layout).
# ---------------------------------------------------------------------------
# CeraUI lives as a sibling of image-building-pipeline under the workspace root.
DEV_SYNC_CERAUI_DIR="${DEV_SYNC_CERAUI_DIR:-${DEV_SYNC_WORKSPACE_ROOT}/CeraUI}"
# vite.config.ts builds the frontend to <CeraUI>/dist/public (outDir ../../dist/public).
DEV_SYNC_FRONTEND_DIST="${DEV_SYNC_FRONTEND_DIST:-${DEV_SYNC_CERAUI_DIR}/dist/public}"
# Build verb run from the CeraUI workspace root (package.json filters the frontend).
DEV_SYNC_FRONTEND_BUILD_CMD="${DEV_SYNC_FRONTEND_BUILD_CMD:-pnpm --filter frontend build}"
DEV_SYNC_FRONTEND_SKIP_BUILD="${DEV_SYNC_FRONTEND_SKIP_BUILD:-0}"
# Remote served bundle dir = setup.sh's symlink target (/opt/ceralive/public →).
DEV_SYNC_CERAUI_STATIC="${DEV_SYNC_CERAUI_STATIC:-/var/www/ceralive}"

# ---------------------------------------------------------------------------
# sync_frontend_build — build the frontend bundle into DEV_SYNC_FRONTEND_DIST.
# Honours DEV_SYNC_FRONTEND_SKIP_BUILD (sync-only) and DRY_RUN (log-only).
# ---------------------------------------------------------------------------
sync_frontend_build() {
  local dir="${DEV_SYNC_CERAUI_DIR}" cmd="${DEV_SYNC_FRONTEND_BUILD_CMD}"

  if [[ "${DEV_SYNC_FRONTEND_SKIP_BUILD}" == "1" ]]; then
    log_warn "frontend build SKIPPED (DEV_SYNC_FRONTEND_SKIP_BUILD=1) — syncing existing ${DEV_SYNC_FRONTEND_DIST}"
    return 0
  fi

  if [[ "${DRY_RUN}" == "1" ]]; then
    log_info "[DRY_RUN] (cd ${dir} && ${cmd})  # build frontend → ${DEV_SYNC_FRONTEND_DIST}"
    return 0
  fi

  [[ -d "${dir}" ]] || die "frontend build: CeraUI dir not found: ${dir} (set DEV_SYNC_CERAUI_DIR)"
  require_cmd pnpm

  # Split the configurable command string into argv (no eval).
  local -a build_argv
  # shellcheck disable=SC2206  # intentional word-split of the configurable build command
  build_argv=(${cmd})

  log_info "building frontend: ${cmd} (cwd ${dir})"
  ( cd "${dir}" && "${build_argv[@]}" )

  [[ -d "${DEV_SYNC_FRONTEND_DIST}" ]] \
    || die "frontend build: expected output missing after build: ${DEV_SYNC_FRONTEND_DIST}"
}

# ---------------------------------------------------------------------------
# sync_frontend_push — atomically publish DEV_SYNC_FRONTEND_DIST to the device's
# served static dir. Stages into <dest>.dev-sync.tmp, then a single-round-trip
# rename swap. NEVER restarts ceralive.service. Requires resolve_target first.
# ---------------------------------------------------------------------------
sync_frontend_push() {
  [[ -n "${RESOLVED_TARGET}" ]] || die "sync_frontend_push: call resolve_target first"

  local src="${DEV_SYNC_FRONTEND_DIST%/}/"     # trailing slash → copy contents
  local dest="${DEV_SYNC_CERAUI_STATIC%/}"
  local tmp="${dest}.dev-sync.tmp"
  local old="${dest}.dev-sync.old"
  local parent
  parent="$(dirname "${dest}")"
  local remote_ref="${SSH_USER}@${RESOLVED_TARGET}"

  # rsync into the staging dir: archive + --delete so the staged tree is an exact
  # copy (orphaned old hashed chunks removed), --temp-dir so per-file partials
  # never land in place even within staging.
  local -a rsync_opts=(-a --delete --temp-dir="${DEV_SYNC_REMOTE_TMP}")
  local -a excludes
  mapfile -t excludes < <(_transport_rsync_excludes)
  (( ${#excludes[@]} > 0 )) && rsync_opts+=("${excludes[@]}")
  local -a ssh_opts
  mapfile -t ssh_opts < <(_transport_ssh_opts)
  rsync_opts+=(-e "ssh ${ssh_opts[*]}")

  # Atomic swap, one ssh round-trip: ensure parent, clear any stale .old, move the
  # current tree aside, move the freshly-staged tree into place, drop the old tree.
  # Two back-to-back rename(2)s — sub-ms window, no half-written bundle. NO RESTART.
  local swap
  swap="set -e; mkdir -p '${parent}'; rm -rf '${old}'; "
  swap+="if [ -e '${dest}' ] || [ -L '${dest}' ]; then mv '${dest}' '${old}'; fi; "
  swap+="mv '${tmp}' '${dest}'; rm -rf '${old}'"

  if [[ "${DRY_RUN}" == "1" ]]; then
    log_info "[DRY_RUN] ssh ${ssh_opts[*]} ${remote_ref} 'rm -rf ${tmp}'  # clear stale staging"
    log_info "[DRY_RUN] rsync ${rsync_opts[*]} ${src} ${remote_ref}:${tmp}/"
    log_info "[DRY_RUN] ssh ${ssh_opts[*]} ${remote_ref} '${swap}'  # atomic temp→rename swap (NO service restart)"
    return 0
  fi

  log_info "clearing stale staging ${remote_ref}:${tmp}"
  transport_ssh "rm -rf '${tmp}'"
  log_info "rsync ${src} → ${remote_ref}:${tmp}/ (atomic staging)"
  rsync "${rsync_opts[@]}" "${src}" "${remote_ref}:${tmp}/"
  log_info "atomic swap ${tmp} → ${dest} (backend serves from disk; no restart)"
  transport_ssh "${swap}"
}

# ---------------------------------------------------------------------------
# sync_frontend_main — build, resolve the device, publish. No restart, ever.
# ---------------------------------------------------------------------------
sync_frontend_main() {
  log_info "=== dev-sync: frontend (build + atomic static sync, NO restart) ==="
  log_info "CeraUI dir   = ${DEV_SYNC_CERAUI_DIR}"
  log_info "dist (local) = ${DEV_SYNC_FRONTEND_DIST}"
  log_info "static (dev) = ${DEV_SYNC_CERAUI_STATIC}"

  sync_frontend_build
  resolve_target
  [[ "${DRY_RUN}" == "1" ]] || require_cmd rsync
  sync_frontend_push

  log_success "frontend sync complete → ${SSH_USER}@${RESOLVED_TARGET}:${DEV_SYNC_CERAUI_STATIC} (no restart, stream-safe)"
}

# ---------------------------------------------------------------------------
# Entry point — sourceable as a library; runnable for the dev loop / QA.
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=1; shift ;;
      -h|--help)
        cat >&2 <<EOF
Usage: sync-frontend.sh [--dry-run]
  Build the CeraUI frontend and atomically publish it to the device's served
  static dir (temp + rename swap). Never restarts ceralive.service.
Env: DRY_RUN, DEV_SYNC_CERAUI_DIR, DEV_SYNC_FRONTEND_DIST, DEV_SYNC_FRONTEND_BUILD_CMD,
     DEV_SYNC_FRONTEND_SKIP_BUILD, DEV_SYNC_CERAUI_STATIC, plus all config.sh knobs.
EOF
        exit 0 ;;
      *) die "sync-frontend.sh: unknown option '$1' (--dry-run|--help)" ;;
    esac
  done
  sync_frontend_main
fi
