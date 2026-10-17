#!/usr/bin/env bash
#
# rauc-build/package.sh — built .deb identity validation for lib/build-rauc.sh.
#
# Sourced by lib/build-rauc.sh, never executed. Mirrors kernel/package.sh's
# role (the OUTPUT-CONTRACT gate) at RAUC's own, much simpler shape: exactly two
# packages, `rauc` (arch-specific) and `rauc-service` (Architecture: all), both
# at exactly the built version.
#
# shellcheck shell=bash
# shellcheck disable=SC2154

# ---------------------------------------------------------------------------
# validate_built_rauc_debs <out_dir> <built_version> <arch>
#
# Fails closed on anything other than EXACTLY one rauc_<version>_<arch>.deb and
# EXACTLY one rauc-service_<version>_all.deb in <out_dir> — a partial or
# duplicated build output is never silently accepted.
# ---------------------------------------------------------------------------
validate_built_rauc_debs() {
  local out_dir="$1" built_version="$2" arch="$3"
  local -a rauc_debs=() service_debs=()
  shopt -s nullglob
  rauc_debs=("${out_dir}/rauc_"*"_${arch}.deb")
  service_debs=("${out_dir}/rauc-service_"*"_all.deb")
  shopt -u nullglob

  (( ${#rauc_debs[@]} == 1 )) \
    || die "rauc-build: expected exactly one rauc_*_${arch}.deb, found ${#rauc_debs[@]}"
  (( ${#service_debs[@]} == 1 )) \
    || die "rauc-build: expected exactly one rauc-service_*_all.deb, found ${#service_debs[@]}"

  assert_deb_identity "${rauc_debs[0]}" rauc "${built_version}" "${arch}" \
    || die "rauc-build: built rauc .deb control identity does not match name=rauc version=${built_version} arch=${arch}"
  assert_deb_identity "${service_debs[0]}" rauc-service "${built_version}" all \
    || die "rauc-build: built rauc-service .deb control identity does not match name=rauc-service version=${built_version} arch=all"

  log_success "rauc-build: validated $(basename "${rauc_debs[0]}") + $(basename "${service_debs[0]}")"
  printf '%s\n%s\n' "${rauc_debs[0]}" "${service_debs[0]}"
}
