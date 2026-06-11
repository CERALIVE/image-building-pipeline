#!/usr/bin/env bash
#
# sysext-build.lib.sh — shared builder for the first-party app sysext images
# (srtla) — Stage 3, task 22. (ceracoder retired 2026-06-11; a cerastream
# sysext descriptor is a follow-on — cerastream installs via the app layer .deb.)
#
# build-srtla-sysext.sh is a thin wrapper that
# picks a *.sysext.conf descriptor and calls build_sysext_main here. The actual
# squashfs creation + extension-release stamping is NOT reimplemented: it is
# delegated to the ONE app-layer contract (v2/lib/app-layer/interface.sh →
# build_app_layer), so a sysext built here is byte-identical to one the device
# update path produces. This file only adds the app-specific .deb EXTRACTION and
# the Runtime-owned-lib PRUNE that the generic backend has no business knowing.
#
# Host-portable: extracts .deb via `ar` + `tar` (no dpkg-deb — the build host is
# Arch, see orchestrate.sh::deb_pkg_name).
#
# shellcheck shell=bash

SYSEXT_BUILD_LIB_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The app-layer contract. interface.sh sources ../common.sh itself (strict mode,
# loggers, die, require_cmd) — so we source ONLY interface.sh to avoid a double
# ERR trap.
# shellcheck source=../../lib/app-layer/interface.sh
source "${SYSEXT_BUILD_LIB_HERE}/../../lib/app-layer/interface.sh"

# ---------------------------------------------------------------------------
# deb_extract_data <deb> <dest_dir>
#   Unpack a .deb's data.tar.{zst,xz,gz} payload into <dest_dir>. No dpkg needed.
# ---------------------------------------------------------------------------
deb_extract_data() {
  local deb="$1" dest="$2" member
  [[ -f "$deb" ]] || die "deb_extract_data: not a file: ${deb}"
  mkdir -p "$dest"

  member="$(ar t "$deb" | grep -E '^data\.tar\.(zst|xz|gz)$' | head -n1)"
  [[ -n "$member" ]] || die "deb_extract_data: no data.tar.{zst,xz,gz} member in ${deb}"

  case "$member" in
    data.tar.zst) ar p "$deb" "$member" | tar --zstd -x -C "$dest" ;;
    data.tar.xz)  ar p "$deb" "$member" | tar -xJ      -C "$dest" ;;
    data.tar.gz)  ar p "$deb" "$member" | tar -xz      -C "$dest" ;;
  esac
}

# ---------------------------------------------------------------------------
# prune_excluded <tree> <name-glob...>
#   Delete every entry whose BASENAME matches any glob, anywhere in <tree>.
#   This is how Runtime/Platform-owned shared objects (libsrt, MPP plugins) are
#   kept OUT of the app sysext even if a .deb wrongly bundled a copy.
# ---------------------------------------------------------------------------
prune_excluded() {
  local tree="$1"
  shift
  local glob
  for glob in "$@"; do
    [[ -n "$glob" ]] || continue
    find "$tree" -depth -name "$glob" -exec rm -rf {} +
  done
}

# ---------------------------------------------------------------------------
# build_sysext_main <conf> <deb_staging_dir> [output_dir]
#   Extract the descriptor's .deb from the staging dir, prune Runtime-owned
#   libs, assert the required binaries survive, then hand the pruned /usr tree to
#   the app-layer sysext backend. Echoes the resulting <NAME>.raw path on stdout.
# ---------------------------------------------------------------------------
build_sysext_main() {
  local conf="$1" deb_staging_dir="${2:-}" output_dir="${3:-$PWD}"
  [[ -f "$conf" ]] || die "build_sysext_main: descriptor not found: ${conf}"
  [[ -n "$deb_staging_dir" ]] || die "usage: $(basename "$0") <deb_staging_dir> [output_dir]"
  [[ -d "$deb_staging_dir" ]] || die "deb staging dir not found: ${deb_staging_dir}"

  require_cmd ar
  require_cmd tar

  # Load the declarative descriptor (KEY=value only).
  SYSEXT_NAME="" SYSEXT_DEB_PACKAGE="" SYSEXT_REQUIRED_BINARIES="" SYSEXT_EXCLUDE_NAMES=""
  # shellcheck source=/dev/null
  source "$conf"
  [[ -n "$SYSEXT_NAME" ]]        || die "${conf}: SYSEXT_NAME is required"
  [[ -n "$SYSEXT_DEB_PACKAGE" ]] || die "${conf}: SYSEXT_DEB_PACKAGE is required"
  [[ -n "$SYSEXT_REQUIRED_BINARIES" ]] || die "${conf}: SYSEXT_REQUIRED_BINARIES is required"

  # The sysext backend stamps extension-release from these — export so the
  # values in the descriptor win over the backend defaults when it is sourced.
  export SYSEXT_OS_ID SYSEXT_OS_VERSION_ID SYSEXT_LEVEL

  # Locate the descriptor's .deb in the staging dir (versioned filename).
  local deb=""
  local cand
  shopt -s nullglob
  for cand in "${deb_staging_dir}/${SYSEXT_DEB_PACKAGE}"_*.deb "${deb_staging_dir}/${SYSEXT_DEB_PACKAGE}".deb; do
    deb="$cand"
    break
  done
  shopt -u nullglob
  [[ -n "$deb" ]] || die "no '${SYSEXT_DEB_PACKAGE}' .deb in ${deb_staging_dir} (expected ${SYSEXT_DEB_PACKAGE}_*.deb)"
  log_info "sysext(${SYSEXT_NAME}): payload .deb = $(basename "$deb")"

  # Extract → prune Runtime-owned libs → assert the boundary held.
  local tree
  tree="$(mktemp -d)"
  deb_extract_data "$deb" "$tree"

  # shellcheck disable=SC2086  # word-split the space-separated glob list on purpose
  prune_excluded "$tree" ${SYSEXT_EXCLUDE_NAMES}

  local bin remaining glob
  for bin in $SYSEXT_REQUIRED_BINARIES; do
    [[ -f "${tree}/${bin}" ]] \
      || { rm -rf "$tree"; die "sysext(${SYSEXT_NAME}): required binary missing after extract/prune: /${bin}"; }
  done
  for glob in $SYSEXT_EXCLUDE_NAMES; do
    remaining="$(find "$tree" -name "$glob" -print -quit)"
    [[ -z "$remaining" ]] \
      || { rm -rf "$tree"; die "sysext(${SYSEXT_NAME}): excluded lib survived prune: ${remaining}"; }
  done
  log_success "sysext(${SYSEXT_NAME}): required binaries present; Runtime-owned libs excluded"

  # Delegate squashfs + extension-release to the ONE app-layer contract.
  APP_BACKEND=sysext select_backend
  local artifact
  artifact="$(build_app_layer "$SYSEXT_NAME" "$tree" "$output_dir")"

  rm -rf "$tree"
  printf '%s\n' "$artifact"
}
