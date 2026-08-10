#!/usr/bin/env bash
#
# kernel/package.sh — built-.deb identity: the package name the manifest declares
# and the four-axis validation of what `make bindeb-pkg` actually produced.
#
# Sourced by lib/build-kernel.sh, never executed.
#
# DYNAMIC SCOPING (the lib/stages/ contract): resolve_kernel_package_name ASSIGNS
# `kernel_pkg`, which build-kernel.sh::main() declares `local`. That declaration
# looks unused in main() and must not be "cleaned up".
#
# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034

# ---------------------------------------------------------------------------
# resolve_kernel_package_name — normalise KERNEL_PACKAGES into the ONE built
# linux-image package name.
#
# The manifest's kernel_packages under a kernel_source variant is the single
# BUILT package name; more than one has no meaning here (bindeb-pkg produces one
# linux-image deb) and would leave the second name unsatisfiable.
#
# ASSIGNS into main()'s frame: kernel_pkg.
# ---------------------------------------------------------------------------
resolve_kernel_package_name() {
  kernel_pkg="${KERNEL_PACKAGES:-}"
  [[ "$(wc -w <<<"${kernel_pkg}")" == "1" ]] \
    || die "a kernel_source variant must declare exactly ONE kernel_packages entry (the built linux-image deb); got '${kernel_pkg}'"
  kernel_pkg="$(tr -d '[:space:]' <<<"${kernel_pkg}")"
}

# ---------------------------------------------------------------------------
# deb_control_field <deb> <field> — read one Debian control field without dpkg
# (the host may be non-Debian). Mirrors orchestrate.sh::deb_pkg_name.
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
    value="$(awk -F': ' -v f="${field}" '$0 ~ "^" f ":" {print $2; exit}' "${tmp}/control")"
  fi
  rm -rf "${tmp}"
  printf '%s' "${value}"
}

# ---------------------------------------------------------------------------
# deb_data_list <deb> — emit the data member's tar listing, one path per line.
#
# The member is discovered from `ar t` rather than guessed, so a dpkg-deb that
# switches compressor (trixie ships .xz today, .zst is the way the wind blows)
# does not silently produce an empty listing.
# ---------------------------------------------------------------------------
deb_data_list() {
  local deb="$1" members member="" m
  members="$(ar t "${deb}" 2>/dev/null)" || return 1
  for m in ${members}; do
    case "${m}" in data.tar.*) member="${m}"; break ;; esac
  done
  [[ -n "${member}" ]] || return 1
  case "${member}" in
    *.zst)  ar p "${deb}" "${member}" 2>/dev/null | tar --zstd -t 2>/dev/null ;;
    *.xz)   ar p "${deb}" "${member}" 2>/dev/null | tar -Jt     2>/dev/null ;;
    *.gz)   ar p "${deb}" "${member}" 2>/dev/null | tar -zt     2>/dev/null ;;
    *.bz2)  ar p "${deb}" "${member}" 2>/dev/null | tar -jt     2>/dev/null ;;
    *.lzma) ar p "${deb}" "${member}" 2>/dev/null | tar --lzma -t 2>/dev/null ;;
    data.tar) ar p "${deb}" "${member}" 2>/dev/null | tar -t    2>/dev/null ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# deb_lists_path <deb> <path> — true when the .deb data archive contains <path>.
# Used to prove the DTB the board manifest names is really inside the built
# kernel package, so the platform-layer install mapping is machine-verified
# rather than merely declared.
#
# The listing is materialised BEFORE it is searched. Piping `tar -t` straight
# into `grep -q` looks equivalent and is not: grep exits at the first match,
# tar dies of SIGPIPE, and under this file's `set -o pipefail` the pipeline
# reports failure — so a path that IS present reads as absent, every time, for
# every board.
# ---------------------------------------------------------------------------
deb_lists_path() {
  local deb="$1" want="$2" listing
  listing="$(deb_data_list "${deb}")" || return 1
  grep -Fqx -e "./${want#/}" -e "${want}" <<<"${listing}"
}

# ---------------------------------------------------------------------------
# validate_built_kernel_deb — assert the produced .deb is EXACTLY what the
# manifest declared, on all four axes the rest of the pipeline keys on:
# package name, Debian version, architecture, and the in-deb DTB path. Any
# mismatch is fatal: the orchestrator's package-name replacement and the boot
# script's fdtfile lookup both depend on these being true, and a mismatch here
# would surface much later as an unbootable image.
# ---------------------------------------------------------------------------
validate_built_kernel_deb() {
  local deb="$1" want_pkg="$2" want_version="$3" want_arch="$4" dtb_path="$5"
  local got_pkg got_version got_arch
  got_pkg="$(deb_control_field "${deb}" Package)"
  got_version="$(deb_control_field "${deb}" Version)"
  got_arch="$(deb_control_field "${deb}" Architecture)"

  [[ "${got_pkg}" == "${want_pkg}" ]] \
    || die "built kernel .deb Package is '${got_pkg:-<unreadable>}' but the manifest declares '${want_pkg}' — the resolver/orchestrator package-name replacement would target a package that does not exist"
  [[ "${got_version}" == "${want_version}" ]] \
    || die "built kernel .deb Version is '${got_version:-<unreadable>}' but the manifest declares kernel_source.package_version '${want_version}'"
  [[ "${got_arch}" == "${want_arch}" ]] \
    || die "built kernel .deb Architecture is '${got_arch:-<unreadable>}' but the resolved family arch is '${want_arch}'"
  log_success "built kernel .deb control identity verified: ${got_pkg}=${got_version}/${got_arch}"

  if ! deb_lists_path "${deb}" "${dtb_path}"; then
    log_error "built kernel .deb does not contain the board DTB at ${dtb_path}"
    log_error "the platform-layer install mapping (kernel_source.dtb_deb_dir + the board's dtb_name) is what makes a source-built kernel satisfy the same DTB expectation an Armbian linux-dtb-* package would; it cannot be satisfied by a DTB that is not there."
    log_error "mainline and the Armbian vendor BSP do NOT always agree on RK3588 DTB filenames; a board whose name differs per tree declares the mainline spelling in variant_overrides.edge.dtb_name. DTBs actually present in the built package:"
    deb_data_list "${deb}" | grep -F "$(dirname "${dtb_path}")/" >&2 || true
    die "built kernel .deb is missing ${dtb_path}"
  fi
  log_success "board DTB present inside the built kernel .deb: ${dtb_path}"
}
