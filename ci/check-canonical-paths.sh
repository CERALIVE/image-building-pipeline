#!/usr/bin/env bash
#
# check-canonical-paths.sh — fail unless the CI-declared generated paths are
# exactly the ones the build resolves.
#
# WHY: a workflow restores a cache into a literal it declares in `env:`, while
# the build writes into a path `lib/paths.sh` resolves. When those two drift the
# build still succeeds — it just never reuses anything, and the only evidence is
# a slow job. This turns that silent drift into a failed step, and it is also
# what lets the cleanup step delete by an explicit ALLOWLIST rather than a glob.
#
# Usage:
#   check-canonical-paths.sh --board <board> \
#       --cache-dir <declared board mkosi cache dir> \
#       --cleanup "<space-separated declared cleanup paths>"
#
# Every flag is optional; only what is supplied is checked.
#
# shellcheck shell=bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"

# shellcheck source=lib/paths.sh
source "${PIPELINE_DIR}/lib/paths.sh"

usage() {
  cat >&2 <<'EOF'
usage: check-canonical-paths.sh [--board <board>] [--cache-dir <path>] [--cleanup "<paths>"]
EOF
}

board=""
declared_cache=""
declared_cleanup=""
have_cleanup=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --board)     board="${2:-}"; shift 2 ;;
    --cache-dir) declared_cache="${2:-}"; shift 2 ;;
    --cleanup)   declared_cleanup="${2:-}"; have_cleanup=1; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *) usage; echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

fail() { echo "ERROR: $*" >&2; exit 1; }

if [[ -n "${declared_cache}" ]]; then
  [[ -n "${board}" ]] || fail "--cache-dir needs --board to resolve the board id"
  resolved="$("${HERE}/emit-canonical-paths.sh" --board "${board}" --get board_mkosi_cache_dir)"
  [[ "${declared_cache}" == "${resolved}" ]] \
    || fail "declared mkosi cache dir '${declared_cache}' != build-resolved '${resolved}' (board ${board})"
  echo "mkosi cache dir matches build-resolved path: ${resolved}"
fi

if (( have_cleanup )); then
  # shellcheck disable=SC2206  # deliberate word split: the declaration is a
  # space-separated list and every element is validated as a literal below.
  declared_list=( ${declared_cleanup} )
  (( ${#declared_list[@]} > 0 )) || fail "--cleanup list is empty"
  ceralive_assert_cleanup_allowed "${declared_list[@]}" \
    || fail "declared cleanup paths are not the generated-path allowlist"
  [[ "${declared_list[*]}" == "${CERALIVE_REL_CLEANUP_PATHS[*]}" ]] \
    || fail "declared cleanup paths '${declared_list[*]}' != allowlist '${CERALIVE_REL_CLEANUP_PATHS[*]}'"
  echo "cleanup paths match the generated-path allowlist: ${CERALIVE_REL_CLEANUP_PATHS[*]}"
fi

exit 0
