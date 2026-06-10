#!/usr/bin/env bash
#
# measure-size.sh — measure rootfs CONTENT size and compare it to the per-board
# budget in manifests/size-budget.json.
#
# REPORT-ONLY SCAFFOLDING (Task 8). While a board's rootfs_bytes_max is null this
# NEVER fails on size — it prints `measured=<N> budget=null (report-only)` and
# exits 0. Task 20 flips the gate to blocking by setting a non-null threshold; the
# enforcement branch below is already wired so that flip is a one-line manifest
# edit, not a code change.
#
# G4/E5 GUARDRAIL: this measures rootfs CONTENT — the apparent byte size of the
# artifact/tree via `du --apparent-size -sb` — NOT the frozen 4096 MB A/B
# partition geometry and NOT a mounted partition (block-rounded, flaky). Pass the
# emitted images/<board>/<ts>.rootfs.tar or the mkosi build/app tree; both are
# content. --apparent-size sums real file bytes, so the result is deterministic
# for a fixed input and ignores filesystem/block overhead.
#
# Usage:  measure-size.sh <board> <rootfs-artifact>
#
# Exit:   0         measurement done (report-only: size never fails the gate)
#         non-zero  bad args / missing artifact / malformed size-budget.json /
#                   unknown board / (Task 20) measured > a non-null budget
#
# shellcheck shell=bash

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${HERE}/common.sh"

V2_DIR="$(cd "${HERE}/.." && pwd)"
SIZE_BUDGET_JSON="${SIZE_BUDGET_JSON:-${V2_DIR}/manifests/size-budget.json}"

usage() {
  cat >&2 <<EOF
usage: measure-size.sh <board> <rootfs-artifact>
  <board>           board key present in ${SIZE_BUDGET_JSON}
  <rootfs-artifact> rootfs tar OR mkosi app tree (content, NOT a mounted partition)
EOF
  exit 2
}

[[ $# -eq 2 ]] || usage
board="$1"
artifact="$2"

require_cmd du
require_cmd python3

[[ -e "${artifact}" ]] || die "rootfs artifact not found: ${artifact}"
[[ -f "${SIZE_BUDGET_JSON}" ]] || die "size budget file not found: ${SIZE_BUDGET_JSON}"

# Parse + validate the budget file. A malformed JSON document, a non-object root,
# a missing board entry, or a mis-typed rootfs_bytes_max all fail LOUDLY here
# (Task 8 negative test). Emits the board budget as a bare token: a positive
# integer, or the literal "null".
budget="$(python3 - "${SIZE_BUDGET_JSON}" "${board}" <<'PY'
import json
import sys

path, board = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
except (OSError, ValueError) as exc:
    sys.stderr.write("malformed size-budget.json: %s\n" % exc)
    sys.exit(1)

if not isinstance(data, dict):
    sys.stderr.write("size-budget.json root must be an object of <board> entries\n")
    sys.exit(1)
if board not in data:
    sys.stderr.write("no size budget entry for board '%s' in %s\n" % (board, path))
    sys.exit(1)

entry = data[board]
if not isinstance(entry, dict) or "rootfs_bytes_max" not in entry:
    sys.stderr.write("board '%s' entry must be an object with 'rootfs_bytes_max'\n" % board)
    sys.exit(1)

limit = entry["rootfs_bytes_max"]
if limit is None:
    print("null")
elif isinstance(limit, int) and not isinstance(limit, bool) and limit > 0:
    print(limit)
else:
    sys.stderr.write("rootfs_bytes_max for '%s' must be a positive integer or null\n" % board)
    sys.exit(1)
PY
)" || die "failed to read size budget for board '${board}' from ${SIZE_BUDGET_JSON}"

# Measure rootfs CONTENT via apparent size: real file bytes, no block rounding,
# no partition/filesystem overhead. Deterministic for a fixed tree/tar.
measured="$(du --apparent-size -sb "${artifact}" | awk '{print $1}')"
[[ "${measured}" =~ ^[0-9]+$ ]] || die "du did not return a byte count for ${artifact}"

if [[ "${budget}" == "null" ]]; then
  printf 'measured=%s budget=%s (report-only)\n' "${measured}" "null"
  log_info "size-gate: board=${board} measured=${measured}B budget=null (report-only, not enforced)"
  exit 0
fi

# Budget is set (Task 20 territory) — enforce it.
printf 'measured=%s budget=%s (enforced)\n' "${measured}" "${budget}"
if (( measured > budget )); then
  die "size-gate: board=${board} measured=${measured}B exceeds budget=${budget}B"
fi
log_success "size-gate: board=${board} measured=${measured}B within budget=${budget}B"
exit 0
