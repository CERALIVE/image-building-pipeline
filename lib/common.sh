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

# ---------------------------------------------------------------------------
# partlabel_prefix / resolve_partlabel <name> — the GPT PARTLABEL to use for a
# contract partition role (boot | rootfs_a | rootfs_b | data).
#
# Default: the FROZEN production label, verbatim (docs/partition-contract.md §3).
#
# CERALIVE_BENCH_LABELS=1 (bench-only, opt-in) returns the `x`-prefixed twin —
# xboot / xrootfs_a / xrootfs_b / xdata. A bench microSD gets booted on a board
# whose eMMC already carries a production image, and every mount/slot lookup in
# the contract is by PARTLABEL, so duplicate labels across the two media make
# `PARTLABEL=rootfs_a` ambiguous on the running kernel. Renaming the bench set
# makes that collision structurally impossible. It is NEVER set on a release
# path; the frozen contract itself is unchanged.
#
# EVERY producer of a PARTLABEL reference must go through this (or its
# self-contained twin in customize/postinst-lib.sh and platform/boot/install-boot.sh):
# a GPT relabelled without its fstab/RAUC/boot-selector counterparts does not
# boot at all, which is worse than the collision it was meant to avoid.
# ---------------------------------------------------------------------------
partlabel_prefix() {
  [[ "${CERALIVE_BENCH_LABELS:-0}" == "1" ]] && printf 'x'
  return 0
}

resolve_partlabel() {
  printf '%s%s' "$(partlabel_prefix)" "${1:?resolve_partlabel needs a partition role}"
}

# ---------------------------------------------------------------------------
# DEV_DELTA_BASENAME + runtime_pkg_list_files <shared-list> <packages-dir>
#
# The canonical runtime package lists for a build, in read order. The shared list
# is passed separately from the directory because both consumers expose them as
# independent overrides (SHARED_LIST / PKG_MANIFEST_DIR).
#
# `development.delta.list` is keyed on the BUILD VARIANT, not on the board
# family, but it shares the `.delta.list` suffix because it is the same format —
# so every `*.delta.list` DIRECTORY GLOB in this repo would otherwise swallow it
# and require its 18 debug packages in a PRODUCTION rootfs (parity-check.sh's
# expected set, realhw-suite.sh's synthesized dpkg status). That is the exact
# defect this helper exists to make impossible: the debug delta is skipped by
# name, then re-appended ONLY when CERALIVE_DEBUG_IMAGE=1.
#
# Every consumer that globs the directory MUST go through this. A consumer that
# keeps its own glob silently reintroduces the production/debug leak.
# ---------------------------------------------------------------------------
DEV_DELTA_BASENAME='development.delta.list'

runtime_pkg_list_files() {
  local shared="${1:?runtime_pkg_list_files needs the shared list}"
  local dir="${2:?runtime_pkg_list_files needs the packages dir}" f
  [[ -f "${shared}" ]] && printf '%s\n' "${shared}"
  for f in "${dir}"/*.delta.list; do
    [[ -f "${f}" ]] || continue
    [[ "${f##*/}" == "${DEV_DELTA_BASENAME}" ]] && continue
    printf '%s\n' "${f}"
  done
  if [[ "${CERALIVE_DEBUG_IMAGE:-0}" == "1" && -f "${dir}/${DEV_DELTA_BASENAME}" ]]; then
    printf '%s\n' "${dir}/${DEV_DELTA_BASENAME}"
  fi
  return 0
}
