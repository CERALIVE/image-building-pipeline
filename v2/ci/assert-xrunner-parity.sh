#!/usr/bin/env bash
#
# assert-xrunner-parity.sh — cross-runner build-plan determinism gate (C6b).
#
# Given a directory of per-runner sidecar files — each a
# "<sha256>  <board>.buildplan" line emitted by emit-build-plan-sha.sh on an
# INDEPENDENT runner — assert that for EVERY board all runners resolved a
# BYTE-IDENTICAL normalized build plan (same sha256). This IS the explicit
# hash-equality assertion the cross-runner gate turns red on.
#
# It FAILS (exit 1) when:
#   * two runners disagree on a board's plan sha — a determinism regression: the
#     plan leaked host state (hostname / arch / toolchain version / an
#     un-normalized absolute path / a non-deterministic nonce / …), OR
#   * --expect-runners N is given and a board is covered by fewer than N runners
#     (a missing leg would otherwise make the gate vacuously green).
#
# The runner identity for each vote is the sidecar FILENAME (without .sha256); the
# board is read from the sidecar CONTENT ("<board>.buildplan") and cross-checked.
#
# SCOPE GUARD: compares the deterministic PLAN / input closure ONLY — this is NOT
# a dual-host full .raucb image build (that needs a privileged mkosi run this gate
# deliberately never performs). Full-artifact determinism remains future work — see
# docs/RELEASE-PROCESS.md §4 "CI determinism coverage — cross-runner build-plan gate (C6b)".
#
# Usage: assert-xrunner-parity.sh <sidecar-dir> [--expect-runners N]
#
# shellcheck shell=bash
set -euo pipefail

usage() {
  cat >&2 <<EOF
usage: assert-xrunner-parity.sh <sidecar-dir> [--expect-runners N]
  <sidecar-dir>       directory of per-runner "<sha>  <board>.buildplan" sidecars
  --expect-runners N  require each board to be covered by exactly N runners
                      (non-vacuous: a missing leg fails the gate)
EOF
}

dir=""
expect_runners=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --expect-runners) expect_runners="${2:-0}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) usage; echo "ERROR: unknown flag: $1" >&2; exit 2 ;;
    *)
      if [[ -z "${dir}" ]]; then dir="$1"; shift
      else usage; echo "ERROR: unexpected argument: $1" >&2; exit 2; fi ;;
  esac
done

[[ -n "${dir}" ]] || { usage; exit 2; }
[[ -d "${dir}" ]] || { echo "ERROR: sidecar dir not found: ${dir}" >&2; exit 2; }
if ! [[ "${expect_runners}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --expect-runners must be a non-negative integer, got: ${expect_runners}" >&2
  exit 2
fi

mapfile -t files < <(find "${dir}" -type f -name '*.sha256' | sort)
if [[ ${#files[@]} -eq 0 ]]; then
  echo "ERROR: no *.sha256 sidecars under ${dir} — nothing to compare (refusing a vacuous pass)" >&2
  exit 2
fi

# board -> space-joined list of "<runner>=<sha>" votes ; board -> vote count.
declare -A board_votes
declare -A board_count

for f in "${files[@]}"; do
  runner="$(basename "${f}" .sha256)"
  while read -r sha tag _rest; do
    [[ -n "${sha}" ]] || continue
    board="${tag%.buildplan}"
    if [[ "${board}" == "${tag}" || -z "${board}" ]]; then
      echo "ERROR: malformed sidecar line in ${f}: '${sha} ${tag}' (expected '<sha>  <board>.buildplan')" >&2
      exit 2
    fi
    board_votes["${board}"]+="${runner}=${sha} "
    board_count["${board}"]=$(( ${board_count["${board}"]:-0} + 1 ))
  done < "${f}"
done

echo "cross-runner build-plan determinism gate (C6b) — PLAN-ONLY (not a full .raucb build)"
echo "sidecar dir: ${dir}  (${#files[@]} runner sidecar file(s))"
[[ "${expect_runners}" -gt 0 ]] && echo "expecting ${expect_runners} runner(s) per board"
echo "---"

fail=0
# Deterministic board ordering for a stable, readable log.
mapfile -t boards < <(printf '%s\n' "${!board_votes[@]}" | sort)
for board in "${boards[@]}"; do
  votes="${board_votes[${board}]}"
  count="${board_count[${board}]}"

  # Collect the distinct shas voted for this board.
  declare -A seen=()
  distinct=()
  for v in ${votes}; do
    s="${v#*=}"
    if [[ -z "${seen[${s}]:-}" ]]; then
      seen["${s}"]=1
      distinct+=("${s}")
    fi
  done

  if [[ "${expect_runners}" -gt 0 && "${count}" -lt "${expect_runners}" ]]; then
    echo "MISSING  board=${board}: only ${count} runner(s) reported, expected ${expect_runners}"
    echo "         votes: ${votes}"
    fail=1
  elif [[ "${#distinct[@]}" -eq 1 ]]; then
    echo "OK       board=${board}: ${count} runner(s) agree → sha256=${distinct[0]}"
    echo "         votes: ${votes}"
  else
    echo "MISMATCH board=${board}: ${#distinct[@]} DISTINCT plan sha256 across runners — determinism regression"
    echo "         votes: ${votes}"
    fail=1
  fi
  unset seen
done

echo "---"
if [[ "${fail}" -ne 0 ]]; then
  echo "::error::cross-runner build-plan determinism gate FAILED — runners resolved divergent normalized plans (see MISMATCH/MISSING above)"
  exit 1
fi
echo "cross-runner build-plan determinism gate PASSED — every board's normalized plan sha256 is identical across all runners"
exit 0
