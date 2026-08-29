#!/usr/bin/env bash
#
# fetch/userspace.sh — the RK3588 HW-accel userspace family (Mali blob, MPP, RGA,
# gst-rockchip, multimedia-config): the packages Armbian does not carry, staged
# from exact pinned upstream URLs and verified by SHA-256.
#
# This family is deliberately URL-pinned rather than apt-sourced, so it is the
# one fetch path with no live trust root to rotate — see the body for why that
# is a property to preserve rather than an inconsistency to tidy away.
#
# Sourced by lib/fetch-debs.sh; not standalone. Reads
# RK3588_USERSPACE_DEB_VERSIONS_FILE / ARCH from the entry point, the pool
# globals from fetch/pool.sh, and collect_declared_bsp_pkgs from fetch/bsp.sh.
#
# Bodies moved VERBATIM from fetch-debs.sh; no behaviour change.
#
# shellcheck shell=bash

LIBV4L0_COMPAT_VERSION="1.30.1-1+ceralive1"
LIBV4L0_COMPAT_LINK="usr/share/libv4l-0-compat/libv4l2.so.0.0.0"
LIBV4L0_T64_LIBRARY="/usr/lib/aarch64-linux-gnu/libv4l2.so.0.0.0"

# build_libv4l0_compat_deb <debs-dir> — generate the real old-name package that
# rockchip-multimedia-config's pre-t64 postinst asks dpkg to list. Trixie's
# libv4l-0t64 Provides: libv4l-0 satisfies apt, but `dpkg -L libv4l-0` still has
# no package record. A fileless transitional package also fails because the
# postinst greps that listing for libv4l2.so.0.0.0 before copying it.
#
# The sole payload is therefore a collision-free symlink under /usr/share. Plain
# `cp` in the pinned postinst dereferences it to libv4l-0t64's real library; this
# package never owns either library path. The version sorts above 1.30.1-1 so it
# is not caught by libv4l-0t64's `Breaks: libv4l-0 (<< 1.30.1-1)` relation.
build_libv4l0_compat_deb() (
  local debs="$1"
  [[ "${ARCH}" == "arm64" ]] \
    || die "libv4l-0 compatibility package is arm64-only (got ARCH=${ARCH})"
  if ! command -v ar >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; then
    die "building libv4l-0 compatibility package requires ar and tar"
  fi

  local epoch="${SOURCE_DATE_EPOCH:-0}"
  [[ "${epoch}" =~ ^[0-9]+$ ]] \
    || die "SOURCE_DATE_EPOCH must be an integer (got '${epoch}')"
  install -d -m 0755 "${debs}"

  local work out tmp
  work="$(mktemp -d "${debs}/.libv4l-0-compat.XXXXXX")"
  trap 'rm -rf "${work}" "${tmp:-}"' EXIT
  out="${debs}/libv4l-0_${LIBV4L0_COMPAT_VERSION}_arm64.deb"
  tmp="${work}/libv4l-0.deb"

  install -d -m 0755 "${work}/control" \
    "${work}/data/$(dirname "${LIBV4L0_COMPAT_LINK}")"
  cat >"${work}/control/control" <<EOF
Package: libv4l-0
Version: ${LIBV4L0_COMPAT_VERSION}
Architecture: arm64
Section: oldlibs
Priority: optional
Depends: libv4l-0t64
Maintainer: CeraLive <engineering@ceralive.tv>
Description: compatibility package for pre-t64 Rockchip multimedia configuration
 This transitional package supplies the old dpkg package name and a collision-free
 symlink to libv4l-0t64's libv4l2 library for legacy maintainer scripts.
EOF
  ln -s "${LIBV4L0_T64_LIBRARY}" "${work}/data/${LIBV4L0_COMPAT_LINK}"
  printf '2.0\n' >"${work}/debian-binary"

  tar --sort=name --mtime="@${epoch}" --owner=0 --group=0 --numeric-owner \
    -C "${work}/control" -czf "${work}/control.tar.gz" ./control
  tar --sort=name --mtime="@${epoch}" --owner=0 --group=0 --numeric-owner \
    -C "${work}/data" -czf "${work}/data.tar.gz" .
  ar rcD "${tmp}" "${work}/debian-binary" "${work}/control.tar.gz" "${work}/data.tar.gz"
  chmod 0644 "${tmp}"

  if ! assert_deb_identity "${tmp}" libv4l-0 "${LIBV4L0_COMPAT_VERSION}" arm64; then
    die "generated libv4l-0 compatibility package has invalid Debian control identity"
  fi
  mv -f "${tmp}" "${out}"
  log_success "RK3588 userspace: built libv4l-0 compatibility package -> ${out}"
)

# rk3588_userspace_pkg_names — echo every pinned userspace package NAME (col 1)
# from the pin file. Empty (success) when the file is absent — a family that
# declares no RK3588 userspace package simply matches none of these.
rk3588_userspace_pkg_names() {
  [[ -f "${RK3588_USERSPACE_DEB_VERSIONS_FILE}" ]] || return 0
  awk 'NF && $1 !~ /^#/ { print $1 }' "${RK3588_USERSPACE_DEB_VERSIONS_FILE}"
}

# rk3588_userspace_record <pkg> — echo the pin record for <pkg> as
# filename<TAB>sha256<TAB>url, or empty if <pkg> is unpinned.
rk3588_userspace_record() {
  local pkg="$1"
  [[ -f "${RK3588_USERSPACE_DEB_VERSIONS_FILE}" ]] || return 0
  awk -v pkg="${pkg}" 'NF && $1 !~ /^#/ && $1==pkg { print $2 "\t" $3 "\t" $4; exit }' \
    "${RK3588_USERSPACE_DEB_VERSIONS_FILE}"
}

# _fetch_rk3588_userspace_one — bounded-pool worker: download ONE pinned userspace
# .deb by its exact URL into a private .tmp-* file, verify its SHA-256 and Debian
# control identity (package name + architecture), then atomically rename into
# ${_RK3588_USERSPACE_DEBS}. A killed curl leaves only the .tmp-* partial, never a
# half-written final .deb. Fail-closed, no-fallback — no alternate mirror or version.
_fetch_rk3588_userspace_one() {
  local pkg="$1" record filename sha256 url
  record="$(rk3588_userspace_record "${pkg}")"
  [[ -n "${record}" ]] \
    || die "RK3588 userspace package '${pkg}' has no pin in ${RK3588_USERSPACE_DEB_VERSIONS_FILE}"
  IFS=$'\t' read -r filename sha256 url <<<"${record}"
  [[ -n "${filename}" && -n "${sha256}" && -n "${url}" ]] \
    || die "RK3588 userspace pin for '${pkg}' is incomplete (need filename/sha256/url): ${record}"
  [[ "${sha256}" =~ ^[0-9a-f]{64}$ ]] \
    || die "RK3588 userspace pin for '${pkg}' has a malformed SHA-256: ${sha256}"

  log_info "RK3588 userspace fetch: ${pkg} (${filename}) sha256=${sha256} <- ${url}"
  if [[ -n "${DRY_RUN}" ]]; then
    run_or_plan curl -fsSL --retry 3 "${CURL_TIMEOUT_OPTS[@]}" -o "${_RK3588_USERSPACE_DEBS}/${filename}" "${url}"
    return 0
  fi

  local final tmp actual_sha actual_pkg actual_arch
  final="${_RK3588_USERSPACE_DEBS}/${filename}"
  # The pin file IS the expected hash, so a cached entry is re-checked against
  # exactly what the download would have been checked against.
  if debcache_try_hit "${filename}" "${sha256}" "${final}"; then
    return 0
  fi
  tmp="$(mktemp "${_RK3588_USERSPACE_DEBS}/.tmp-userspace-XXXXXX")"
  if ! curl -fsSL --retry 3 "${CURL_TIMEOUT_OPTS[@]}" -o "${tmp}" "${url}"; then
    rm -f "${tmp}"
    return 1
  fi
  actual_sha="$(sha256sum "${tmp}" | awk '{print $1}')"
  if [[ "${actual_sha}" != "${sha256}" ]]; then
    log_error "RK3588 userspace checksum mismatch for ${pkg}: expected ${sha256}, got ${actual_sha}"
    rm -f "${tmp}"
    return 1
  fi
  if ! assert_deb_identity "${tmp}" "${pkg}" "" "${ARCH}" --arch-all-ok; then
    actual_pkg="${DEB_ACTUAL_PKG}"; actual_arch="${DEB_ACTUAL_ARCH}"
    log_error "RK3588 userspace control mismatch for ${pkg}: package=${actual_pkg:-<missing>} architecture=${actual_arch:-<missing>} (expected ${pkg}, arch ${ARCH}|all)"
    rm -f "${tmp}"
    return 1
  fi
  if ! publish_staged_deb "${tmp}" "${final}"; then
    rm -f "${tmp}"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# fetch_rk3588_userspace — stage the RK3588 HW-accel userspace .debs (Mali-G610
# GPU blob, Rockchip MPP encode/decode lib, RGA 2D accelerator, the GStreamer MPP
# plugin, and the multimedia udev config) that the Armbian bookworm arm64 feed  suite-literal-ok: names the upstream Armbian feed these pins are absent from, not the target rootfs suite
# does NOT carry. Each is pinned to an exact upstream release-asset URL and
# verified by SHA-256 (manifests/rk3588-userspace-deb-versions.txt) — the SAME
# fail-closed, no-fallback discipline as fetch_bsp, but URL-pinned: a pinned URL +
# SHA-256 needs no rotating apt index or GPG trust root, so these packages never
# require a live apt source.
#
# Only the pinned packages the RESOLVED family actually declares are fetched — the
# intersection of collect_declared_bsp_pkgs (manifest fields + board env overrides)
# and the pin file's package names. An x86 family declares none, so nothing is
# fetched. fetch_bsp EXCLUDES exactly this set from the Armbian fetch.
# ---------------------------------------------------------------------------
fetch_rk3588_userspace() {
  local family="$1" debs="$2"
  [[ -n "${family}" ]] || die "fetch_rk3588_userspace: --family manifest required"
  [[ -f "${family}" ]] || die "fetch_rk3588_userspace: family manifest not found: ${family}"

  local -A pinned=()
  local name
  while IFS= read -r name; do
    [[ -n "${name}" ]] && pinned["${name}"]=1
  done < <(rk3588_userspace_pkg_names)

  local -a want=()
  while IFS= read -r name; do
    [[ -n "${name}" && -n "${pinned[${name}]:-}" ]] && want+=("${name}")
  done < <(collect_declared_bsp_pkgs "${family}")

  if (( ${#want[@]} == 0 )); then
    log_info "RK3588 userspace: $(basename "${family}") declares no pinned userspace package — nothing to fetch"
    return 0
  fi

  log_info "RK3588 userspace set from $(basename "${family}") (${#want[@]} pkgs): ${want[*]}"
  log_info "RK3588 userspace pins: ${RK3588_USERSPACE_DEB_VERSIONS_FILE}"

  _RK3588_USERSPACE_DEBS="${debs}"
  local jobs="${FETCH_JOBS}"; [[ -n "${DRY_RUN}" ]] && jobs=1
  _run_bounded "${jobs}" _fetch_rk3588_userspace_one "${want[@]}" \
    || die "RK3588 userspace fetch failed: one or more pinned packages did not download/verify"

  local needs_libv4l0_compat=0
  for name in "${want[@]}"; do
    [[ "${name}" == "rockchip-multimedia-config" ]] && needs_libv4l0_compat=1
  done
  if (( needs_libv4l0_compat )); then
    if [[ -n "${DRY_RUN}" ]]; then
      log_info "DRY-RUN would build: libv4l-0_${LIBV4L0_COMPAT_VERSION}_arm64.deb (Depends: libv4l-0t64; one compatibility symlink)"
    else
      build_libv4l0_compat_deb "${debs}"
    fi
  fi

  if [[ -z "${DRY_RUN}" ]]; then
    local pkg
    local -a staged=()
    for pkg in "${want[@]}"; do
      shopt -s nullglob
      staged=("${debs}/${pkg}"_*.deb)
      shopt -u nullglob
      (( ${#staged[@]} >= 1 )) \
        || die "RK3588 userspace fetch staged no .deb for '${pkg}'"
    done
    log_success "RK3588 userspace: staged ${#want[@]} SHA-256-verified pinned .deb(s) into ${debs}"
  fi
}
