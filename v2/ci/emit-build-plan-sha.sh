#!/usr/bin/env bash
#
# emit-build-plan-sha.sh — resolve the DRY_RUN mkosi build plan for ONE board and
# emit the NORMALIZED plan's sha256 as a board-tagged sidecar line.
#
# This factors out the EXACT normalization the v2-ci `build-matrix` job's
# "Emit host sha256 sidecar (cross-host build-plan parity, task 15)" step already
# performs inline, so the same bytes are hashed on every runner AND the logic is
# reproducible locally. It underpins the cross-runner build-plan determinism gate
# (C6b): each INDEPENDENT runner calls this, then assert-xrunner-parity.sh compares
# the resulting per-runner sidecars and fails on any mismatch.
#
# NORMALIZATION (byte-identical to task 15):
#   1. DRY_RUN=1 ./v2/build <board> resolves the containerized mkosi plan and logs
#      one "… would build with: mkosi …" line (orchestrate.sh step 5/9).
#   2. Assert the CONTAINER path was resolved ("DRY_RUN=1 (docker|podman)"), never
#      the --native opt-in whose plan differs — this guards against a runner with no
#      container runtime silently changing the hash.
#   3. Strip THIS checkout's ABSOLUTE repo path to a stable "<REPO>" token (the raw
#      plan embeds .../v2/mkosi/.staging/<board>/… — a per-runner absolute path that
#      must NOT leak into the digest, else the sha would encode the runner's workdir).
#   4. sha256sum the single normalized line.
#
# SCOPE: hashes the deterministic build PLAN / input closure ONLY — NOT a full
# .raucb image build (which needs a privileged mkosi run this deliberately never
# performs). Full-artifact determinism remains future work — see docs/RELEASE-
# PROCESS.md §4 "CI determinism coverage — cross-runner build-plan gate (C6b)".
#
# Usage:
#   emit-build-plan-sha.sh --board <board> --out <sidecar-file> [--log <file>]
#
#   --board  board manifest name (e.g. rock-5b-plus, x86-minipc)
#   --out    sidecar file to write: "<sha256>  <board>.buildplan"
#   --log    reuse an EXISTING DRY_RUN build log instead of re-resolving (the
#            resolve is re-run into a temp log by default)
#
# Echoes "<sha256>  <board>.buildplan" to stdout. Exits non-zero if the plan can't
# be resolved or the container path was not chosen.
#
# shellcheck shell=bash
set -euo pipefail

usage() {
  cat >&2 <<EOF
usage: emit-build-plan-sha.sh --board <board> --out <sidecar-file> [--log <file>]
  --board  board manifest name (e.g. rock-5b-plus, x86-minipc)
  --out    sidecar file to write ("<sha256>  <board>.buildplan")
  --log    reuse an existing DRY_RUN build log instead of re-resolving
EOF
}

# Resolve the repo root from this script's location (v2/ci/…) so the invocation and
# the path-stripping token are correct from any CWD.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/../.." && pwd)"

board=""
out=""
log=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --board) board="${2:-}"; shift 2 ;;
    --out)   out="${2:-}"; shift 2 ;;
    --log)   log="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "${board}" ]] || { usage; echo "ERROR: --board is required" >&2; exit 2; }
[[ -n "${out}" ]]   || { usage; echo "ERROR: --out is required" >&2; exit 2; }

# 1. Resolve the DRY_RUN plan (unless an existing log was handed in). DRY_RUN=1
#    suppresses every real download/build; INSTALL_BOOT_BSP=0 keeps it to a
#    config+package parity resolve (no emulated kernel install needed to emit the
#    plan). Both mirror the build-matrix job's env exactly.
cleanup_log=""
if [[ -z "${log}" ]]; then
  log="$(mktemp)"
  cleanup_log="${log}"
  if ! DRY_RUN=1 INSTALL_BOOT_BSP=0 "${REPO_ROOT}/v2/build" "${board}" >"${log}" 2>&1; then
    echo "ERROR: DRY_RUN resolve failed for board '${board}':" >&2
    cat "${log}" >&2
    [[ -n "${cleanup_log}" ]] && rm -f "${cleanup_log}"
    exit 1
  fi
fi
[[ -f "${log}" ]] || { echo "ERROR: build log not found: ${log}" >&2; exit 2; }

# 2. Container-path assertion — the resolve MUST pick the containerized builder
#    (docker/podman), never the --native opt-in whose plan differs.
if ! grep -Eq 'DRY_RUN=1 \((docker|podman)\)' "${log}"; then
  echo "ERROR: build-plan resolve did not choose the container path (expected docker/podman) for '${board}'" >&2
  [[ -n "${cleanup_log}" ]] && rm -f "${cleanup_log}"
  exit 1
fi

# 3. Extract + normalize the plan line: strip the absolute repo path to <REPO>.
plan="$(grep -F 'would build with:' "${log}" \
        | sed -E 's/^.*would build with: //' \
        | sed "s#${REPO_ROOT}#<REPO>#g")"
if [[ -z "${plan}" ]]; then
  echo "ERROR: no resolved mkosi plan ('would build with:') in the log for '${board}'" >&2
  [[ -n "${cleanup_log}" ]] && rm -f "${cleanup_log}"
  exit 1
fi

# 4. Hash the single normalized line (printf adds the trailing newline the task-15
#    step hashes; keep it identical so the digest matches that mechanism).
sha="$(printf '%s\n' "${plan}" | sha256sum | cut -d' ' -f1)"

# sha256sum-style, board-tagged line (machine-checkable; a multi-board run never
# produces an ambiguous "which board?" digest).
line="${sha}  ${board}.buildplan"
mkdir -p "$(dirname "${out}")"
printf '%s\n' "${line}" > "${out}"

echo "board=${board} normalized-plan-sha256=${sha}" >&2
echo "  plan: ${plan}" >&2
echo "  wrote: ${out}" >&2
printf '%s\n' "${line}"

[[ -n "${cleanup_log}" ]] && rm -f "${cleanup_log}"
exit 0
