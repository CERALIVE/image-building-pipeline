#!/usr/bin/env bash
#
# deb-lib.sh — shared .deb introspection/extraction helpers for the v2 pipeline.
#
# No dpkg dependency on the read path (build hosts may be Arch): both helpers
# fall back to ar + tar over the control/data tarballs.
#   * deb_pkg_name — echo the Package: field of a .deb (control.tar.{gz,xz,zst})
#   * explode_deb  — extract a .deb's data tarball into <dest>
#
# Bodies extracted VERBATIM from orchestrate.sh (deb_pkg_name) and
# dev-sync/sync-native.sh (_explode_deb). No behaviour change — this file is a
# relocation of existing logic into one shared home.
#
# shellcheck shell=bash

DEB_LIB_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# common.sh provides strict mode, the loud ERR trap, loggers, die, require_cmd.
# shellcheck source=../common.sh
source "${DEB_LIB_HERE}/../common.sh"

# ---------------------------------------------------------------------------
# deb_pkg_name — read the Package: field of a .deb without dpkg (host is Arch).
# Uses `ar` + tar on control.tar.* . Echoes the package name or empty.
# ---------------------------------------------------------------------------
deb_pkg_name() {
  local deb="$1" tmp name=""
  tmp="$(mktemp -d)"
  if ar p "${deb}" control.tar.gz 2>/dev/null | tar -xzO -C "${tmp}" ./control 2>/dev/null >"${tmp}/control"; then
    :
  elif ar p "${deb}" control.tar.xz 2>/dev/null | tar -xJO ./control 2>/dev/null >"${tmp}/control"; then
    :
  elif ar p "${deb}" control.tar.zst 2>/dev/null | tar --zstd -xO ./control 2>/dev/null >"${tmp}/control"; then
    :
  fi
  if [[ -s "${tmp}/control" ]]; then
    name="$(awk -F': ' '/^Package:/{print $2; exit}' "${tmp}/control")"
  fi
  rm -rf "${tmp}"
  printf '%s' "${name}"
}

# ---------------------------------------------------------------------------
# deb_pkg_version — read the Version: field of a .deb without dpkg (host is Arch).
# Mirrors deb_pkg_name: ar + tar over control.tar.* . Echoes the version or empty.
# Used by the BSP provenance/drift-guard to record the EXACT resolved kernel
# version string for the exact Armbian vendor package alongside its content hash.
# ---------------------------------------------------------------------------
deb_pkg_version() {
  local deb="$1" tmp version=""
  tmp="$(mktemp -d)"
  if ar p "${deb}" control.tar.gz 2>/dev/null | tar -xzO -C "${tmp}" ./control 2>/dev/null >"${tmp}/control"; then
    :
  elif ar p "${deb}" control.tar.xz 2>/dev/null | tar -xJO ./control 2>/dev/null >"${tmp}/control"; then
    :
  elif ar p "${deb}" control.tar.zst 2>/dev/null | tar --zstd -xO ./control 2>/dev/null >"${tmp}/control"; then
    :
  fi
  if [[ -s "${tmp}/control" ]]; then
    version="$(awk -F': ' '/^Version:/{print $2; exit}' "${tmp}/control")"
  fi
  rm -rf "${tmp}"
  printf '%s' "${version}"
}

deb_pkg_arch() {
  local deb="$1" tmp arch=""
  tmp="$(mktemp -d)"
  if ar p "${deb}" control.tar.gz 2>/dev/null | tar -xzO ./control 2>/dev/null >"${tmp}/control"; then
    :
  elif ar p "${deb}" control.tar.xz 2>/dev/null | tar -xJO ./control 2>/dev/null >"${tmp}/control"; then
    :
  elif ar p "${deb}" control.tar.zst 2>/dev/null | tar --zstd -xO ./control 2>/dev/null >"${tmp}/control"; then
    :
  fi
  if [[ -s "${tmp}/control" ]]; then
    arch="$(awk -F': ' '/^Architecture:/{print $2; exit}' "${tmp}/control")"
  fi
  rm -rf "${tmp}"
  printf '%s' "${arch}"
}

deb_pkg_arch() {
  local deb="$1" tmp arch=""
  tmp="$(mktemp -d)"
  if ar p "${deb}" control.tar.gz 2>/dev/null | tar -xzO ./control 2>/dev/null >"${tmp}/control"; then
    :
  elif ar p "${deb}" control.tar.xz 2>/dev/null | tar -xJO ./control 2>/dev/null >"${tmp}/control"; then
    :
  elif ar p "${deb}" control.tar.zst 2>/dev/null | tar --zstd -xO ./control 2>/dev/null >"${tmp}/control"; then
    :
  fi
  if [[ -s "${tmp}/control" ]]; then
    arch="$(awk -F': ' '/^Architecture:/{print $2; exit}' "${tmp}/control")"
  fi
  rm -rf "${tmp}"
  printf '%s' "${arch}"
}

# ---------------------------------------------------------------------------
# explode_deb <deb> <dest> — standard .deb data-tarball extraction into <dest>
# (dpkg-deb when present, else ar + tar). Used only by --from-deb; the sysext
# BUILD itself is the reused build_app_layer verb, never reimplemented here.
# ---------------------------------------------------------------------------
explode_deb() {
  local deb="$1" dest="$2"
  mkdir -p "${dest}"
  if command -v dpkg-deb >/dev/null 2>&1; then
    dpkg-deb -x "${deb}" "${dest}"
    return 0
  fi
  require_cmd ar
  require_cmd tar
  local member
  member="$(ar t "${deb}" | grep -E '^data\.tar' | head -n1)"
  [[ -n "${member}" ]] || die "_explode_deb: no data.tar member in ${deb}"
  case "${member}" in
    *.gz)  ar p "${deb}" "${member}" | tar -xz   -C "${dest}" ;;
    *.xz)  ar p "${deb}" "${member}" | tar -xJ   -C "${dest}" ;;
    *.zst) ar p "${deb}" "${member}" | tar --zstd -x -C "${dest}" ;;
    *)     ar p "${deb}" "${member}" | tar -x    -C "${dest}" ;;
  esac
}
