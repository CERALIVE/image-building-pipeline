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
# shellcheck disable=SC2154,SC2034

# ---------------------------------------------------------------------------
# stage_rauc_build — [2c/9]
#
# Reads from main()'s frame: board, staging, rauc_build_dir, mkosi_arch;
# writes rauc_build_dir_host for the Stage-4 bundle-build tool.
#
# The target-arch pair built below is device-rootfs-bound (RAUC must run ON
# the device to OTA there) and is staged into staging/debs unchanged. The
# Stage-4 bundle-build tool (build-bundle.sh::bundle_with_rauc) is a separate
# concern: it runs rauc INSIDE the amd64-native MKOSI_BUILDER_IMAGE container
# just to squashfs+sign bytes, so it needs an amd64-runnable rauc, never the
# target board's arch. Mixing the two in one apt transaction is the original
# bug, so whenever the target differs from amd64 a SECOND host-native pair is
# built into its own directory and never staged; when the target already is
# amd64 the pair above is already host-native and is reused.
# ---------------------------------------------------------------------------
stage_rauc_build() {
  local rauc_arch="amd64"
  [[ "${mkosi_arch}" == "arm64" ]] && rauc_arch="arm64"

  log_info "[2c/9] building rauc from pinned upstream source (arch '${rauc_arch}') → ${rauc_build_dir}"
  "${BUILD_RAUC_SH}" --arch "${rauc_arch}" --out "${rauc_build_dir}" \
    || die "rauc-build failed for board '${board}'"

  if [[ "${rauc_arch}" == "amd64" ]]; then
    rauc_build_dir_host="${rauc_build_dir}"
  else
    rauc_build_dir_host="${staging}/rauc-build-host"
    log_info "[2c/9] building a second, host-native (amd64) rauc pair for the Stage-4 bundle-build tool → ${rauc_build_dir_host}"
    "${BUILD_RAUC_SH}" --arch amd64 --out "${rauc_build_dir_host}" \
      || die "host-native rauc-build failed for board '${board}'"
  fi

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
