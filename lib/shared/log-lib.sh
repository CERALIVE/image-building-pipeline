#!/usr/bin/env bash
#
# log-lib.sh — the ONE runtime log-message formatter for the pipeline.
#
# STANDALONE ON PURPOSE. It sets no shell options, installs no trap, sources
# nothing, and defines nothing but the five functions below, so it can be sourced
# from any of the three shell profiles in docs/shell-profiles.md without dragging
# `set -e` or an ERR trap into a script that must not have them. lib/common.sh
# sources it and adds the build-strict half (strict mode + err_trap) on top; a
# contract-test harness or a diagnostic that only wants the formatter can source
# this file alone.
#
# FORMAT IS A CONTRACT, not a preference:
#
#     [LEVEL] HH:MM:SS message
#
# with a five-character, space-padded level and everything on STDERR. Build logs
# are parsed by ci/check-build-log.sh against a frozen 34-signature census
# (docs/build-log-census.md), and orchestrator stage lines are compared
# byte-for-byte across builds. Changing the padding, the separator, the clock
# format or the stream is a change to every one of those comparisons.
#
# Re-sourcing is harmless: the definitions are idempotent and carry no state.
#
# shellcheck shell=bash

_log() {
  local level="$1"
  shift
  printf '[%s] %s %s\n' "${level}" "$(date '+%H:%M:%S')" "$*" >&2
}

log_info()    { _log 'INFO ' "$@"; }
log_warn()    { _log 'WARN ' "$@"; }
log_error()   { _log 'ERROR' "$@"; }
log_success() { _log 'OK   ' "$@"; }
