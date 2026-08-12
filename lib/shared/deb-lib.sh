#!/usr/bin/env bash
#
# deb-lib.sh — the ONE home for Debian package introspection/extraction.
#
# No dpkg dependency on the read path (build hosts may be Arch): every helper
# falls back to ar + tar over the control/data tarballs.
#
#   * deb_control_field   — the single control-tarball parser (all readers use it)
#   * deb_pkg_name        — Package: field        (thin wrapper)
#   * deb_pkg_version     — Version: field        (thin wrapper)
#   * deb_pkg_arch        — Architecture: field   (thin wrapper)
#   * assert_deb_identity — the single package/version/architecture check
#   * explode_deb         — extract a .deb's data tarball into <dest>
#
# Before consolidation the control-tarball walk existed five times (twice
# verbatim in this file, once each in lib/stages/partition.sh, lib/build-kernel.sh
# and — as data extraction — in dev-push and lib/dev-sync/build-input-lib.sh), and
# the identity check three more times across the fetch modules. Behaviour is
# unchanged; only the number of copies is.
#
# shellcheck shell=bash

DEB_LIB_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# common.sh provides strict mode, the loud ERR trap, loggers, die, require_cmd.
# shellcheck source=../common.sh
source "${DEB_LIB_HERE}/../common.sh"

# ---------------------------------------------------------------------------
# deb_control_field <deb> <field> — read ONE Debian control field without dpkg.
#
# The control member may be gz/xz/zst-compressed; each is tried in turn and a
# member that is absent or undecodable simply falls through to the next. An
# unreadable/corrupt archive yields the empty string — callers treat empty as
# "unknown" and fail their own identity check, which is what makes a corrupt
# .deb a rejection rather than a crash.
# ---------------------------------------------------------------------------
deb_control_field() {
  local deb="$1" field="$2" tmp value=""
  tmp="$(mktemp -d)"
  if ar p "${deb}" control.tar.gz 2>/dev/null | tar -xzO ./control 2>/dev/null >"${tmp}/control"; then
    :
  elif ar p "${deb}" control.tar.xz 2>/dev/null | tar -xJO ./control 2>/dev/null >"${tmp}/control"; then
    :
  elif ar p "${deb}" control.tar.zst 2>/dev/null | tar --zstd -xO ./control 2>/dev/null >"${tmp}/control"; then
    :
  fi
  if [[ -s "${tmp}/control" ]]; then
    value="$(awk -F': ' -v key="${field}" '$1 == key {print $2; exit}' "${tmp}/control")"
  fi
  rm -rf "${tmp}"
  printf '%s' "${value}"
}

deb_pkg_name() {
  deb_control_field "$1" Package
}

deb_pkg_version() {
  deb_control_field "$1" Version
}

deb_pkg_arch() {
  deb_control_field "$1" Architecture
}

# ---------------------------------------------------------------------------
# assert_deb_identity <deb> <expected_pkg> <expected_version|''> <expected_arch> \
#                     [--arch-all-ok]
#
# The single identity check behind every staged-package guard. An empty
# <expected_version> skips the version leg (the URL-pinned userspace family has
# no version to assert); --arch-all-ok additionally accepts `all` (arch-any
# packages such as armbian-firmware).
#
# Reads the control ONCE and publishes what it found in DEB_ACTUAL_PKG /
# DEB_ACTUAL_VERSION / DEB_ACTUAL_ARCH so each caller can keep its own
# family-specific diagnostic wording. Returns 0 on match, 1 on mismatch —
# it never dies, because the fetch families differ on whether a mismatch is
# fatal or retryable.
# ---------------------------------------------------------------------------
DEB_ACTUAL_PKG=""
DEB_ACTUAL_VERSION=""
DEB_ACTUAL_ARCH=""

assert_deb_identity() {
  local deb="$1" want_pkg="$2" want_version="$3" want_arch="$4" arch_all_ok=0
  shift 4
  local opt
  for opt in "$@"; do
    case "${opt}" in
      --arch-all-ok) arch_all_ok=1 ;;
      *) die "assert_deb_identity: unknown option '${opt}'" ;;
    esac
  done

  DEB_ACTUAL_PKG="$(deb_pkg_name "${deb}")"
  DEB_ACTUAL_VERSION="$(deb_pkg_version "${deb}")"
  DEB_ACTUAL_ARCH="$(deb_pkg_arch "${deb}")"

  [[ "${DEB_ACTUAL_PKG}" == "${want_pkg}" ]] || return 1
  [[ -z "${want_version}" || "${DEB_ACTUAL_VERSION}" == "${want_version}" ]] || return 1
  if [[ "${DEB_ACTUAL_ARCH}" != "${want_arch}" ]]; then
    (( arch_all_ok == 1 )) && [[ "${DEB_ACTUAL_ARCH}" == "all" ]] || return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# explode_deb <deb> <dest> — standard .deb data-tarball extraction into <dest>
# (dpkg-deb when present, else ar + tar). The one extractor: dev-push's
# --from-deb staging and dev-sync's build-input staging both route here, as does
# the WWAN module inspection.
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
  [[ -n "${member}" ]] || die "explode_deb: no data.tar member in ${deb}"
  case "${member}" in
    *.gz)  ar p "${deb}" "${member}" | tar -xz   -C "${dest}" ;;
    *.xz)  ar p "${deb}" "${member}" | tar -xJ   -C "${dest}" ;;
    *.zst) ar p "${deb}" "${member}" | tar --zstd -x -C "${dest}" ;;
    *)     ar p "${deb}" "${member}" | tar -x    -C "${dest}" ;;
  esac
}
