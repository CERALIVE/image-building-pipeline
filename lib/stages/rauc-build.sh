#!/usr/bin/env bash
#
# stages/rauc-build.sh — orchestrator stage [2c/9]: RAUC from pinned upstream
# source + Debian's own packaging (Todo 22 RAUC-version-path follow-up,
# decisions.md 2026-09-24 "Todo 22 RAUC version path — FINAL RULING").
#
# Sourced by lib/orchestrate.sh. See stages/resolve.sh for the dynamic-scoping
# contract every stage module relies on.
#
# UNCONDITIONAL, unlike stage_kernel_build ([2b/9], gated on kernel_source:):
# both shipped families (rk3588, x86_64) ship RAUC, and neither carries a
# CeraLive-owned RAUC fork, so there is no per-family gate to read. Runs AFTER
# [2/9] so the uniqueness check below sees the complete fetched set, and BEFORE
# [3/9] so the built .deb pair flows through the SAME classification/staging
# path as anything fetched — mirrors stage_kernel_build exactly.
#
# shellcheck shell=bash
# shellcheck disable=SC2154

# ---------------------------------------------------------------------------
# stage_rauc_build — [2c/9]
#
# Reads from main()'s frame: board, staging, rauc_build_dir, mkosi_arch.
# ---------------------------------------------------------------------------
stage_rauc_build() {
  local rauc_arch="amd64"
  [[ "${mkosi_arch}" == "arm64" ]] && rauc_arch="arm64"

  log_info "[2c/9] building rauc from pinned upstream source (arch '${rauc_arch}') → ${rauc_build_dir}"
  "${BUILD_RAUC_SH}" --arch "${rauc_arch}" --out "${rauc_build_dir}" \
    || die "rauc-build failed for board '${board}'"

  if [[ "${DRY_RUN:-0}" != "1" ]]; then
    assert_staged_packages_unique "${staging}/debs" "${rauc_build_dir}"
    shopt -s nullglob
    local _rdeb
    for _rdeb in "${rauc_build_dir}"/*.deb; do
      "${MKOSI_PACKAGE_STAGING_SH}" "${_rdeb}" "${staging}/debs"
    done
    shopt -u nullglob
  fi
}
