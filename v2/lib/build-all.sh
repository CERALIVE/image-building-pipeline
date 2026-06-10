#!/usr/bin/env bash
#
# build-all.sh — bounded-parallel multi-board runner for the CeraLive v2 pipeline.
#
# `build --all` / `build --only b1,b2` (v2/build) resolve a multi-board selection
# and hand it here. This runner spawns ONE orchestrate.sh per board with bounded
# concurrency, isolates each board's output to its own log file, waits for ALL of
# them (no early abort), aggregates the exit codes, and prints a summary table.
#
#   build-all.sh <board1> <board2> ...
#
# Per-board state is already isolated upstream (task 11): orchestrate.sh scopes
# STAGING_ROOT/<board>, IMAGES_DIR/<board> and the mkosi cache/<BOARD_ID>, so the
# only thing this runner has to isolate is the LOG stream — interleaving N heavy
# mkosi builds onto one terminal would be unreadable. Each board therefore gets
# its own logs/<board>-<ts>.log; nothing board-specific reaches our stdout except
# the final summary table.
#
# DESIGN (inherited from common.sh + fetch-debs.sh::_run_bounded):
#   * bounded fan-out: at most JOBS orchestrators in flight (mkosi is heavy —
#     default = min(nproc, 4); JOBS env overrides). Never an unbounded `&` storm.
#   * aggregate, never swallow: each board's exit is captured via `wait <pid>` and
#     recorded; ANY non-zero board makes the whole run non-zero. There is NO
#     `|| true` — a failed board is reported, never masked.
#   * no early abort: one board failing does NOT stop the others; every board runs
#     to completion so a single flake never strands the rest of the matrix.
#
# Env (all overridable; defaults keep `build --all` working with zero config):
#   JOBS          max boards built concurrently   (default: min(nproc, 4))
#   ORCHESTRATOR  single-board builder to spawn    (default: <here>/orchestrate.sh)
#   BOARDS_DIR    manifest dir for find_manifest   (default: <v2>/manifests/boards)
#   LOGS_DIR      per-board log destination        (default: <v2>/logs)
#   …plus every env orchestrate.sh honours (DRY_RUN, INSTALL_BOOT_BSP, …): each
#   spawned orchestrator inherits this process's environment unchanged.
#
# shellcheck shell=bash

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${HERE}/common.sh"

V2_DIR="$(cd "${HERE}/.." && pwd)"

# ---------------------------------------------------------------------------
# Configuration (env-overridable; never hardcode product constants in logic).
# ORCHESTRATOR/BOARDS_DIR/LOGS_DIR are overridable so the runner is unit-testable
# in isolation (a stub orchestrator + fixture manifests) without a real build.
# ---------------------------------------------------------------------------
ORCHESTRATOR="${ORCHESTRATOR:-${HERE}/orchestrate.sh}"
BOARDS_DIR="${BOARDS_DIR:-${V2_DIR}/manifests/boards}"
LOGS_DIR="${LOGS_DIR:-${V2_DIR}/logs}"

# default_jobs — bounded concurrency ceiling: min(nproc, 4). mkosi peaks RAM/IO,
# so 4 is a deliberate safety cap (MUST-NOT: don't exhaust memory) even on hosts
# with many cores. nproc is probed defensively so a missing nproc never aborts.
default_jobs() {
  local n
  n="$(nproc 2>/dev/null || echo 1)"
  [[ "${n}" =~ ^[1-9][0-9]*$ ]] || n=1
  (( n > 4 )) && n=4
  printf '%s' "${n}"
}

# JOBS — sanitised to a positive integer; a bogus override falls back to the cap.
JOBS="${JOBS:-$(default_jobs)}"
[[ "${JOBS}" =~ ^[1-9][0-9]*$ ]] || JOBS="$(default_jobs)"

usage() {
  cat >&2 <<EOF
Usage: build-all.sh <board1> <board2> ...

Builds each board in parallel (bounded by JOBS), one orchestrate.sh per board,
each board's output captured to its own log under:
  ${LOGS_DIR}/<board>-<ts>.log

Exit status is non-zero if ANY board fails (all boards still run to completion).

Env: JOBS (default min(nproc,4)) ORCHESTRATOR BOARDS_DIR LOGS_DIR
     + every env orchestrate.sh honours (DRY_RUN, INSTALL_BOOT_BSP, …)
EOF
}

# find_manifest <board> — resolve a board name to its manifest path on stdout
# (first matching extension wins). Mirrors v2/build::find_manifest; kept local so
# the runner is self-contained and standalone-testable. Non-zero + no output when
# no manifest exists for the board.
find_manifest() {
  local board="$1" ext
  for ext in yaml yml toml conf; do
    if [[ -f "${BOARDS_DIR}/${board}.${ext}" ]]; then
      printf '%s\n' "${BOARDS_DIR}/${board}.${ext}"
      return 0
    fi
  done
  return 1
}

# run_one_board <board> <manifest> <log> — spawn target. Runs the single-board
# orchestrator with stdout+stderr funnelled into <log>, and RETURNS the
# orchestrator's exit code (captured via `|| rc=$?`, so the strict-mode ERR trap
# never fires here and the real status survives for the parent's `wait`). This is
# capture-and-propagate, NOT error swallowing.
run_one_board() {
  local board="$1" manifest="$2" log="$3" rc=0
  "${ORCHESTRATOR}" --board "${board}" --manifest "${manifest}" >"${log}" 2>&1 || rc=$?
  return "${rc}"
}

main() {
  [[ $# -gt 0 ]] || { usage; die "no boards given — expected at least one board name"; }

  local -a boards=("$@")
  [[ -x "${ORCHESTRATOR}" ]] \
    || die "orchestrator not executable at ${ORCHESTRATOR} (set ORCHESTRATOR= to override)"

  mkdir -p "${LOGS_DIR}"
  local ts; ts="$(date -u +%Y%m%dT%H%M%SZ)"

  log_info "=== CeraLive v2 multi-board build: ${#boards[@]} board(s), JOBS=${JOBS} ==="
  log_info "boards: ${boards[*]}"
  log_info "logs:   ${LOGS_DIR}/<board>-${ts}.log"

  # Resolve + validate every manifest BEFORE launching anything — a single bad
  # board name fails the whole run loudly up front, never half a matrix.
  local -A board_manifest=() board_log=()
  local b manifest
  for b in "${boards[@]}"; do
    manifest="$(find_manifest "${b}")" \
      || die "unknown board '${b}': no manifest in ${BOARDS_DIR}/ (expected ${b}.yaml|yml|toml|conf)"
    board_manifest["${b}"]="${manifest}"
    board_log["${b}"]="${LOGS_DIR}/${b}-${ts}.log"
  done

  # ---------------------------------------------------------------------------
  # Bounded fan-out. Sliding window of at most JOBS in-flight orchestrators,
  # mirroring fetch-debs.sh::_run_bounded: launch in selection order, and when the
  # window is full block on its FRONT pid (`wait <pid>` returns THAT board's exit
  # code — recorded per board, never lost). Drain the tail after the loop. No
  # early abort: every board is launched and waited on exactly once.
  # ---------------------------------------------------------------------------
  local -A board_rc=()
  local -a win_pids=() win_boards=()
  local pid rc front fb
  for b in "${boards[@]}"; do
    run_one_board "${b}" "${board_manifest[$b]}" "${board_log[$b]}" &
    pid=$!
    win_pids+=("${pid}")
    win_boards+=("${b}")
    log_info "launched board '${b}' (pid ${pid}) -> ${board_log[$b]}"
    if (( ${#win_pids[@]} >= JOBS )); then
      front="${win_pids[0]}"; fb="${win_boards[0]}"
      rc=0; wait "${front}" || rc=$?
      board_rc["${fb}"]="${rc}"
      win_pids=("${win_pids[@]:1}")
      win_boards=("${win_boards[@]:1}")
    fi
  done
  # Drain whatever is still in flight.
  local i
  for i in "${!win_pids[@]}"; do
    rc=0; wait "${win_pids[$i]}" || rc=$?
    board_rc["${win_boards[$i]}"]="${rc}"
  done

  # ---------------------------------------------------------------------------
  # Summary table + aggregate exit. Print to STDOUT (the runner's primary result;
  # per-board build chatter stays in the log files). ANY non-zero board → exit 1.
  # ---------------------------------------------------------------------------
  local width=5 failures=0 status
  for b in "${boards[@]}"; do (( ${#b} > width )) && width=${#b}; done

  printf '\n'
  printf '%-*s | %-8s | %s\n' "${width}" "board" "status" "log"
  printf '%-*s-+-%-8s-+-%s\n' "${width}" "$(printf '%*s' "${width}" '' | tr ' ' '-')" \
    "--------" "----------------------------------------"
  for b in "${boards[@]}"; do
    rc="${board_rc[$b]:-127}"
    if [[ "${rc}" == "0" ]]; then
      status="OK"
    else
      status="FAIL(${rc})"
      failures=$((failures + 1))
    fi
    printf '%-*s | %-8s | %s\n' "${width}" "${b}" "${status}" "${board_log[$b]}"
  done
  printf '\n'

  if (( failures > 0 )); then
    log_error "${failures}/${#boards[@]} board(s) FAILED — see the per-board logs above"
    exit 1
  fi
  log_success "=== all ${#boards[@]} board(s) built OK ==="
}

# Only run main when executed directly; sourcing (tests) gets the functions only.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
