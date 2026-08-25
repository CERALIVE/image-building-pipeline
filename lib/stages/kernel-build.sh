#!/usr/bin/env bash
#
# stages/kernel-build.sh — orchestrator stage [2b/9]: kernel from pinned source.
#
# Sourced by lib/orchestrate.sh. See stages/resolve.sh for the dynamic-scoping
# contract every stage module relies on.
#
# shellcheck shell=bash
# shellcheck disable=SC2154

# ---------------------------------------------------------------------------
# stage_kernel_build — [2b/9]
#
# Inert unless the resolved manifest carried a kernel_source: block, i.e. only
# under an explicitly selected variant. Runs AFTER [2/9] so the uniqueness check
# sees the complete fetched set, and BEFORE [3/9] so the built .deb flows through
# exactly the same classification and staging path as a fetched one.
#
# Reads from main()'s frame: board, variant, kernel_from_source, staging,
# kernel_build_dir, kernel_extension_build_dir.
# ---------------------------------------------------------------------------
stage_kernel_build() {
  if [[ "${kernel_from_source}" == "1" ]]; then
    log_info "[2b/9] building kernel from pinned source (variant '${KERNEL_VARIANT:-${variant}}') → ${kernel_build_dir}"
    "${BUILD_KERNEL_SH}" --board "${board}" --out "${kernel_build_dir}" \
      || die "kernel-build-from-source failed for board '${board}'"
  fi

  if [[ -n "${KERNEL_EXTENSION_PACKAGES:-}" ]]; then
    log_info "[2b/9] building kernel extension(s) for the prebuilt vendor kernel → ${kernel_extension_build_dir}"
    KERNEL_EXTENSION_PACKAGES="${KERNEL_EXTENSION_PACKAGES}" \
      "${BUILD_KERNEL_EXTENSION_SH}" --out "${kernel_extension_build_dir}" \
      || die "kernel-extension build failed for board '${board}'"
  fi

  if [[ "${DRY_RUN:-0}" != "1" && "${kernel_from_source}" == "1" ]]; then
    assert_staged_packages_unique "${staging}/debs" "${kernel_build_dir}"
    shopt -s nullglob
    local _kdeb
    for _kdeb in "${kernel_build_dir}"/*.deb; do
      "${MKOSI_PACKAGE_STAGING_SH}" "${_kdeb}" "${staging}/debs"
    done
    shopt -u nullglob
  fi

  if [[ "${DRY_RUN:-0}" != "1" && -n "${KERNEL_EXTENSION_PACKAGES:-}" ]]; then
    assert_staged_packages_unique "${staging}/debs" "${kernel_extension_build_dir}"
    shopt -s nullglob
    local _ext_deb
    for _ext_deb in "${kernel_extension_build_dir}"/*.deb; do
      "${MKOSI_PACKAGE_STAGING_SH}" "${_ext_deb}" "${staging}/debs"
    done
    shopt -u nullglob
  fi
}
