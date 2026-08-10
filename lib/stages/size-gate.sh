#!/usr/bin/env bash
#
# stages/size-gate.sh — orchestrator stage [6c/9]: the rootfs size budget.
#
# stage_size_gate MUST stay above compare_size_against_baseline in this file:
# manifest.bats extracts the shipped block by taking the FIRST `  if [[ … fi`
# that mentions [6c/9], and the comparator's own early-return guards mention it
# too. Reordering them silently swaps which block the gate's tests execute.
#
# Sourced by lib/orchestrate.sh. See stages/resolve.sh for the dynamic-scoping
# contract every stage module relies on.
#
# shellcheck shell=bash
# shellcheck disable=SC2154

# ---------------------------------------------------------------------------
# stage_size_gate — [6c/9]
#
# Reads from main()'s frame: board, artifact.
# ---------------------------------------------------------------------------
stage_size_gate() {

  # The rootfs_bytes_max in manifests/size-budget.json is documented as a BLOCKING
  # ceiling, and until this stage existed NOTHING enforced it on a real artifact: the
  # only live caller was the v2-ci "size gate" job, which measures a synthetic 4 KB
  # tree. That is how both RK3588 boards shipped 65-72 MB over budget while the docs
  # claimed the gate ran after every build. It runs here, against the same emitted
  # tar as [6b/9] and for the same reason — the earliest point where the real answer
  # exists. Deliberately NOT arch-gated: every shipped board carries a non-null
  # ceiling, and gating on arm64 would exempt the one board whose size has never been
  # measured. INSTALL_BOOT_BSP=0 IS skipped, because a kernel-less parity rootfs is
  # not the shipped image and measuring it would be a vacuous pass.
  if [[ "${INSTALL_BOOT_BSP}" == "1" ]]; then
    log_info "[6c/9] enforcing the rootfs size budget for ${artifact}"
    "${MEASURE_SIZE_SH}" "${board}" "${artifact}" \
      || die "rootfs size budget EXCEEDED for board '${board}' (measured/budget bytes above) — slim the image (docs/size-notes.md), do NOT raise rootfs_bytes_max"
    compare_size_against_baseline "${board}" "${artifact}"
  else
    log_warn "[6c/9] INSTALL_BOOT_BSP=0 — config+package parity build; rootfs size budget not enforced (a kernel-less rootfs is not the shipped image)"
  fi
}

# ---------------------------------------------------------------------------
# compare_size_against_baseline <board> <artifact.tar>
#
# The RELATIVE size gate, run against the REAL emitted tar. It was previously
# reachable only from the v2-ci "size gate" job, which measures a synthetic 4 KB
# tree — so it compared 4096 bytes against a ~1.4 GB baseline and could only ever
# report an enormous shrink. That is the same vacuity that let both RK3588 boards
# ship over the ABSOLUTE ceiling before [6c/9] existed; fixing one gate and
# leaving the other measuring 4 KB just moves the blind spot.
#
# Exit policy is deliberately split, and NOT the same as the absolute gate's:
#   exit 2 (missing/malformed baseline, or a baseline for a DIFFERENT board) is
#          FATAL — that is a repository misconfiguration, and a silent cross-board
#          comparison produces a confident, meaningless delta.
#   exit 1 (growth beyond the comparator's threshold) is a loud WARNING, matching
#          what v2-ci already does: the blocking size rule is the absolute ceiling
#          in size-budget.json, and an intentional feature addition must not be
#          able to fail a build that is still comfortably under it.
# The baseline is resolved ONLY as size-baseline.<board>.json, with no
# un-suffixed fallback: the legacy ci/size-baseline.json is rock-5b-plus's
# file, so a fallback would hand it to every board that lacks one. A board with
# no committed baseline yet warns and passes, the same newly-added-board
# allowance measure-size.sh makes for a null ceiling.
# ---------------------------------------------------------------------------
compare_size_against_baseline() {
  local board="$1" artifact="$2" baseline measured rc=0

  # A debug image is production + the development delta (~58 MB on rock-5b-plus),
  # so it exceeds the comparator's 50 MB growth threshold BY CONSTRUCTION. Warning
  # about that is worse than useless: the warning's own remedy is "update the
  # baseline in the same PR", and doing that from a debug build would overwrite the
  # PRODUCTION baseline with a number no production image can ever reproduce, then
  # desync it from size-budget.json (which manifest.bats fails on). The ABSOLUTE
  # ceiling above still ran and still applies — only this relative comparison,
  # whose reference is a production artifact, is skipped.
  if [[ "${CERALIVE_DEBUG_IMAGE:-0}" == "1" ]]; then
    log_warn "[6c/9] CERALIVE_DEBUG_IMAGE=1 — relative size baseline SKIPPED (the committed baseline is a PRODUCTION artifact; do NOT update it from a debug build). The absolute ceiling was enforced above."
    return 0
  fi

  baseline="${SIZE_BASELINE_DIR}/size-baseline.${board}.json"
  if [[ ! -f "${baseline}" ]]; then
    log_warn "[6c/9] no committed size baseline for board '${board}' — relative regression check skipped (record one in ${SIZE_BASELINE_DIR})"
    return 0
  fi

  measured="$(du --apparent-size -sb "${artifact}" | awk '{print $1}')"

  "${CHECK_SIZE_REGRESSION_SH}" "${measured}" "${baseline}" "${board}" || rc=$?
  case "${rc}" in
    0) log_success "[6c/9] size baseline: board=${board} within threshold of $(basename "${baseline}")" ;;
    1) log_warn "[6c/9] size baseline: board=${board} GREW beyond the regression threshold vs $(basename "${baseline}") — justify the growth and update the baseline in the same PR (docs/size-notes.md §4)" ;;
    *) die "[6c/9] size baseline unusable for board '${board}': ${baseline} (missing, malformed, or recorded for a different board)" ;;
  esac
}
