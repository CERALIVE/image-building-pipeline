#!/usr/bin/env bash
#
# fetch/pool.sh — the bounded fetch pool and the atomic staging publish step,
# shared by all three fetch families (BSP, RK3588 userspace, first-party).
#
# Sourced by lib/fetch-debs.sh; not standalone. The _* globals below are the
# ONLY channel a pool worker has for its inputs, because each worker runs in a
# background subshell — see the launch-order and trap notes in the body.
#
# Bodies moved VERBATIM from fetch-debs.sh; no behaviour change.
#
# shellcheck shell=bash
# ---------------------------------------------------------------------------
# Bounded fetch pool. _run_bounded runs <worker> for each arg with at most
# <max> in flight (sliding window — never an unbounded `&` fan-out). Args are
# launched in order, so REPOS/BSP ordering (G3) is the launch order. Each child
# is waited on exactly once; any non-zero child makes the whole run non-zero so
# one failed download fails the entire fetch (aggregate exit).
#
# State the workers need is passed via these script globals (background subshells
# inherit them); each worker downloads into a private .tmp/.fetch-* path under
# the staging dir and atomically renames the finished .deb into place, so an
# interrupted download never leaves a half-written final .deb.
# ---------------------------------------------------------------------------
_BSP_DEBS=""
_PKG_INDEX=""
_APT_OPTS=()
_FIRST_PARTY_DEBS=""
_FIRST_PARTY_INDEX=""
_FIRST_PARTY_BASE_URL=""
_FIRST_PARTY_CURL_AUTH=()
_RK3588_USERSPACE_DEBS=""

publish_staged_deb() {
  local source="$1" destination="$2"
  chmod 0644 "${source}" || return 1
  mv -f "${source}" "${destination}" || return 1
}

_run_bounded() {
  local max="$1" worker="$2"; shift 2
  (( max >= 1 )) || max=1
  local rc=0 arg pid
  local -a window=()
  for arg in "$@"; do
    "${worker}" "${arg}" &
    window+=("$!")
    if (( ${#window[@]} >= max )); then
      wait "${window[0]}" || rc=1
      window=("${window[@]:1}")
    fi
  done
  for pid in "${window[@]}"; do
    wait "${pid}" || rc=1
  done
  return "${rc}"
}
