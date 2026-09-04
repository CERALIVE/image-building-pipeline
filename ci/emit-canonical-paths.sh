#!/usr/bin/env bash
#
# emit-canonical-paths.sh — print the BUILD-RESOLVED generated paths.
#
# The values come from `lib/paths.sh`, which is the same file the orchestrator,
# the kernel builder and the parallel runner derive from. That makes this the
# machine-readable edge of one definition rather than a second copy of it: a
# workflow (or a contract test) can assert its own literal against what the
# build will actually resolve, instead of the two drifting silently.
#
# Usage:
#   emit-canonical-paths.sh [--board <board>] [--get <key>]
#
#   --board  resolve the board-scoped mkosi cache directories too (needs the
#            board manifest; the key is the manifest's `board_id`, exactly what
#            mkosi's `CacheDirectory=cache/${BOARD_ID}` expands to). Emits the
#            board ROOT — the unit release.yml saves and restores — plus the two
#            privilege-domain leaves a real build actually points mkosi at.
#   --get    print only that key's value, unquoted and newline-terminated
#
# Default output is `key=value`, one per line, sorted by emission order.
#
# shellcheck shell=bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"

# shellcheck source=lib/paths.sh
source "${PIPELINE_DIR}/lib/paths.sh"

usage() {
  cat >&2 <<'EOF'
usage: emit-canonical-paths.sh [--board <board>] [--get <key>]
  --board  also emit board_id + board_mkosi_cache_dir for that board manifest
  --get    print only this key's value
EOF
}

board=""
want=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --board) board="${2:-}"; shift 2 ;;
    --get)   want="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

declare -a keys=() values=()
emit() { keys+=("$1"); values+=("$2"); }

emit pipeline_dir            "${PIPELINE_DIR}"
emit mkosi_dir               "${CERALIVE_REL_MKOSI_DIR}"
emit mkosi_build_dir         "${CERALIVE_REL_MKOSI_BUILD_DIR}"
emit mkosi_cache_root        "${CERALIVE_REL_MKOSI_CACHE_ROOT}"
emit mkosi_workspace_dir     "${CERALIVE_REL_MKOSI_WORKSPACE_DIR}"
emit staging_dir             "${CERALIVE_REL_STAGING_DIR}"
emit kernel_ccache_dir       "${CERALIVE_REL_KERNEL_CCACHE_DIR}"
emit kernel_src_mirror_dir   "${CERALIVE_REL_KERNEL_SRC_MIRROR_DIR}"
emit images_dir              "${CERALIVE_REL_IMAGES_DIR}"
emit logs_dir                "${CERALIVE_REL_LOGS_DIR}"
emit cleanup_paths           "${CERALIVE_REL_CLEANUP_PATHS[*]}"

if [[ -n "${board}" ]]; then
  manifest="${PIPELINE_DIR}/manifests/boards/${board}.yaml"
  [[ -f "${manifest}" ]] || { echo "ERROR: no board manifest: ${manifest}" >&2; exit 2; }
  board_id="$(python3 -c '
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
value = doc.get("board_id")
if not value:
    sys.exit("board manifest declares no board_id")
print(value)
' "${manifest}")"
  emit board_id              "${board_id}"
  emit board_mkosi_cache_dir "$(ceralive_rel_board_mkosi_cache_dir "${board_id}")"
  emit board_mkosi_cache_dir_container "$(ceralive_rel_board_mkosi_cache_dir "${board_id}" container)"
  emit board_mkosi_cache_dir_native    "$(ceralive_rel_board_mkosi_cache_dir "${board_id}" native)"
fi

if [[ -n "${want}" ]]; then
  for i in "${!keys[@]}"; do
    if [[ "${keys[$i]}" == "${want}" ]]; then
      printf '%s\n' "${values[$i]}"
      exit 0
    fi
  done
  echo "ERROR: unknown key: ${want}" >&2
  exit 2
fi

for i in "${!keys[@]}"; do
  printf '%s=%s\n' "${keys[$i]}" "${values[$i]}"
done
