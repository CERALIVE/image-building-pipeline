#!/usr/bin/env bash
#
# common.sh — strict shared bash library for the CeraLive image-building v2 pipeline.
#
# This is the single foundation every v2 script sources. It establishes:
#   - strict mode (set -euo pipefail)
#   - a loud ERR trap that reports the failing file:line and command
#   - one canonical set of structured loggers (log_info/log_warn/log_error/log_success)
#   - die() for fatal exits and require_cmd() for dependency preconditions
#
# DESIGN RULE: there is intentionally NO `|| true` / best-effort error swallowing
# anywhere in this file — and, by extension, none on the sacred fetch path that
# sources it. Silent apt/dpkg failures were the root cause of v1 unreliability
# (see customize-image.sh:170-174,231-232). v2 fails loudly, always: the `trap
# err_trap ERR` installed below converts ANY unguarded non-zero command into an
# immediate, file:line-reported exit. A stray `|| true` would defeat that trap by
# resetting the failing command's exit status to 0 BEFORE the trap can see it — so
# the two rules are one and the same: keep commands unguarded and let err_trap
# report them. The ONLY sanctioned way to say "this command does not run now" is
# the explicit DRY_RUN plan path (fetch-debs.sh `run_or_plan`), which LOGS the
# command and returns 0 deliberately — never the silent `|| true` shortcut.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
#
# shellcheck shell=bash

set -euo pipefail

# ---------------------------------------------------------------------------
# Error trap — fail loudly with file:line context.
# ---------------------------------------------------------------------------
err_trap() {
  # Capture the exit status of the command that tripped the trap first.
  local exit_code=$?
  log_error "ERROR at ${BASH_SOURCE[1]:-?}:${BASH_LINENO[0]:-?}: ${BASH_COMMAND} (exit ${exit_code})"
  exit 1
}
trap err_trap ERR

# ---------------------------------------------------------------------------
# Structured logging — all to stderr, timestamp-prefixed, single canonical impl.
# ---------------------------------------------------------------------------
_log() {
  local level="$1"
  shift
  printf '[%s] %s %s\n' "${level}" "$(date '+%H:%M:%S')" "$*" >&2
}

log_info()    { _log 'INFO ' "$@"; }
log_warn()    { _log 'WARN ' "$@"; }
log_error()   { _log 'ERROR' "$@"; }
log_success() { _log 'OK   ' "$@"; }

# ---------------------------------------------------------------------------
# die — log a fatal message and exit non-zero.
# ---------------------------------------------------------------------------
die() {
  log_error "$*"
  exit 1
}

# ---------------------------------------------------------------------------
# require_cmd — assert an external command exists, or die with guidance.
#   require_cmd mkosi || die "..."   # explicit form
#   require_cmd mkosi                # also dies on its own with a default msg
# ---------------------------------------------------------------------------
require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    die "command '${cmd}' not found, install it first"
  fi
}

# ---------------------------------------------------------------------------
# resolve_source_date_epoch [repo-dir] — echo a STABLE epoch for reproducible
# builds: env override > HEAD commit time (pins epoch to source state) > frozen
# fallback. Callers EXPORT it as SOURCE_DATE_EPOCH so every embedded mtime
# (tar/squashfs/ext4/CMS) clamps to one value. The git probe sits in the `if`
# condition so a non-repo dir cannot trip the ERR trap.
# ---------------------------------------------------------------------------
resolve_source_date_epoch() {
  local repo_dir="${1:-.}" epoch=""
  if [[ -n "${SOURCE_DATE_EPOCH:-}" ]]; then
    printf '%s' "${SOURCE_DATE_EPOCH}"
    return 0
  fi
  if epoch="$(git -C "${repo_dir}" log -1 --pretty=%ct 2>/dev/null)" && [[ -n "${epoch}" ]]; then
    printf '%s' "${epoch}"
    return 0
  fi
  printf '%s' "${CERALIVE_EPOCH_FALLBACK:-1577836800}"   # 2020-01-01T00:00:00Z
}
