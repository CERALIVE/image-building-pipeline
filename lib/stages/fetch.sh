#!/usr/bin/env bash
#
# stages/fetch.sh — orchestrator stage [2/9]: stage the build's .debs.
#
# Sourced by lib/orchestrate.sh. See stages/resolve.sh for the dynamic-scoping
# contract every stage module relies on.
#
# shellcheck shell=bash
# shellcheck disable=SC2154

# ---------------------------------------------------------------------------
# stage_fetch — [2/9]
#
# Recreating the staging tree is part of this stage, not setup: the tree must be
# freshly authenticated on every build, which is why CERALIVE_REUSE_STAGING is
# refused rather than honoured.
#
# Reads from main()'s frame: board, staging, bsp_dir, firstparty_dir,
# kernel_build_dir, family_manifest.
# ---------------------------------------------------------------------------
stage_fetch() {
  [[ "${CERALIVE_REUSE_STAGING:-0}" != "1" ]] \
    || die "CERALIVE_REUSE_STAGING is forbidden: build inputs must be freshly authenticated"
  rm -rf "${staging}"
  mkdir -p "${staging}"
  install -d -m 0755 "${bsp_dir}" "${firstparty_dir}" "${kernel_build_dir}"

  log_info "[2/9] fetching .debs (BSP from Armbian + first-party from R2/gh) → ${staging}"
  DEST="${staging}" "${FETCH_DEBS_SH}" --family "${family_manifest}" --dest "${staging}" \
    || die "fetch-debs failed for board '${board}'"
}
