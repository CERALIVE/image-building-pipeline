#!/usr/bin/env bash
#
# paths.sh — the SINGLE definition of every path this pipeline GENERATES.
#
# WHY THIS FILE EXISTS: before the v2→root promotion the same generated paths
# were spelled out independently in `lib/orchestrate.sh`, `lib/build-kernel.sh`,
# `lib/build-all.sh` and twice more inside `.github/workflows/release.yml`. A
# CI runner therefore restored a cache into one literal while the build resolved
# another, and the only symptom was a silently cold cache. Every consumer now
# derives from the constants below, and `ci/emit-canonical-paths.sh` exposes
# them to non-bash consumers (workflows, tests) so a workflow literal can be
# compared against the value the build actually resolves.
#
# Every value here is REPO-RELATIVE on purpose. Absolute paths are formed by the
# consumer against its own resolved `PIPELINE_DIR`, so the same constants
# describe a local checkout, a CI workspace and the `/work` bind mount inside
# the builder container.
#
# shellcheck shell=bash
# This file only DECLARES; each constant is read by a different consumer.
# shellcheck disable=SC2034

# mkosi's own tree: config, subimage definitions, and everything it generates.
CERALIVE_REL_MKOSI_DIR="mkosi"
# mkosi image output tree (`mkosi --force` wipes this).
CERALIVE_REL_MKOSI_BUILD_DIR="${CERALIVE_REL_MKOSI_DIR}/build"
# Root of the per-board mkosi package caches (`CacheDirectory=cache/${BOARD_ID}`).
CERALIVE_REL_MKOSI_CACHE_ROOT="${CERALIVE_REL_MKOSI_DIR}/cache"
# Staged .debs. Deliberately a SIBLING of build/ so `mkosi --force` cannot wipe
# a staging tree mid-build; gitignored via mkosi/.gitignore.
CERALIVE_REL_STAGING_DIR="${CERALIVE_REL_MKOSI_DIR}/.staging"
# Persistent ccache for the opt-in kernel-from-source variants.
CERALIVE_REL_KERNEL_CCACHE_DIR="${CERALIVE_REL_MKOSI_CACHE_ROOT}/kernel-ccache"
# mkosi's scratch workspace (`--workspace-directory`). Every finished subimage is
# RENAMED out of here into CERALIVE_REL_MKOSI_BUILD_DIR, so the two must be on one
# filesystem: mkosi's default is /var/tmp, and on a normal dev box or CI runner
# that is a different device from the checkout, which downgraded all eight of
# those renames to full multi-GB COPIES ("Could not rename … falling back to
# copying" — census row 20).
#
# It is a REPO-ROOT dotdir rather than mkosi/.workspace because mkosi's
# check_workspace_directory() refuses a workspace inside any BuildSources= source
# directory, and the build runs with the mkosi/ tree as its build source (that is
# the same $SRCDIR the app layer reads first-party .debs from). Repo root is the
# nearest location that is both outside that tree and on the output filesystem.
CERALIVE_REL_MKOSI_WORKSPACE_DIR=".mkosi-workspace"
# Final per-board artifacts (.raw / .raucb / .rootfs.tar).
CERALIVE_REL_IMAGES_DIR="images"
# Per-board build logs emitted by the parallel runner.
CERALIVE_REL_LOGS_DIR="logs"

# Generated paths a CI runner is permitted to delete between jobs.
#
# This is an EXPLICIT ALLOWLIST, not a pattern: the runner is persistent and
# holds the checkout, staged inputs, image outputs, QEMU state, release
# artifacts and trust material beside these. No entry may contain a glob, `..`,
# or a leading `/` — `ceralive_assert_cleanup_allowed` enforces that, so a
# future edit cannot widen a bounded delete into a workspace wipe.
CERALIVE_REL_CLEANUP_PATHS=(
  "${CERALIVE_REL_MKOSI_BUILD_DIR}"
  "${CERALIVE_REL_MKOSI_CACHE_ROOT}"
  "${CERALIVE_REL_MKOSI_WORKSPACE_DIR}"
)

# Board-scoped mkosi cache directory. `BOARD_ID` (the Armbian board id from the
# board manifest) is the key mkosi itself uses via `CacheDirectory=`.
ceralive_rel_board_mkosi_cache_dir() {
  printf '%s/%s\n' "${CERALIVE_REL_MKOSI_CACHE_ROOT}" "$1"
}

# Fail unless every supplied path is on the cleanup allowlist verbatim.
ceralive_assert_cleanup_allowed() {
  local candidate allowed hit
  for candidate in "$@"; do
    case "${candidate}" in
      /*|*..*|*'*'*|*'?'*|*'['*)
        echo "cleanup path is not a literal repo-relative path: ${candidate}" >&2
        return 1
        ;;
    esac
    hit=0
    for allowed in "${CERALIVE_REL_CLEANUP_PATHS[@]}"; do
      [[ "${candidate}" == "${allowed}" ]] && { hit=1; break; }
    done
    if (( hit == 0 )); then
      echo "cleanup path is not on the generated-path allowlist: ${candidate}" >&2
      return 1
    fi
  done
  return 0
}
