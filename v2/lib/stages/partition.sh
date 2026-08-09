#!/usr/bin/env bash
#
# stages/partition.sh — orchestrator stage [3/9]: classify the staged .debs.
#
# Also holds the two package-identity helpers the classification rests on:
# deb_pkg_name (used here) and assert_staged_packages_unique (used by [2b/9]).
#
# Sourced by lib/orchestrate.sh. See stages/resolve.sh for the dynamic-scoping
# contract every stage module relies on.
#
# shellcheck shell=bash
# shellcheck disable=SC2154

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
# assert_staged_packages_unique <debs-dir> <built-dir>
#
# The kernel-from-source stage and the remote fetcher both feed the SAME local
# package directory mkosi later resolves from. If a package name arrives from
# both, mkosi's local repository silently picks one by version and the image
# ships a kernel nobody chose — the worst possible failure mode for this feature,
# because it produces a plausible image rather than an error.
#
# Suppression (CERALIVE_KERNEL_SOURCE_SUPPRESSED_PKGS) is what should make a
# collision impossible; this check is what proves it did. Fail closed on ANY
# name present in both directories.
# ---------------------------------------------------------------------------
assert_staged_packages_unique() {
  local fetched_dir="$1" built_dir="$2"
  local deb pkg
  local -A fetched=()
  local -a collisions=()

  shopt -s nullglob
  for deb in "${fetched_dir}"/*.deb; do
    pkg="$(deb_pkg_name "${deb}")"
    [[ -n "${pkg}" ]] || die "unreadable staged package: $(basename "${deb}")"
    fetched["${pkg}"]="$(basename "${deb}")"
  done
  for deb in "${built_dir}"/*.deb; do
    pkg="$(deb_pkg_name "${deb}")"
    [[ -n "${pkg}" ]] || die "unreadable built package: $(basename "${deb}")"
    if [[ -n "${fetched[${pkg}]:-}" ]]; then
      collisions+=("${pkg} (fetched: ${fetched[${pkg}]}, built: $(basename "${deb}"))")
    fi
  done
  shopt -u nullglob

  if (( ${#collisions[@]} > 0 )); then
    for pkg in "${collisions[@]}"; do
      log_error "duplicate candidate for staged package ${pkg}"
    done
    die "${#collisions[@]} package name(s) have BOTH a fetched and a locally-built candidate; the local package directory must have exactly one candidate per name. Check that kernel_source.suppressed_packages covers every name the variant replaces."
  fi
  log_success "staged package uniqueness verified: no name has both a fetched and a built candidate"
}
# ---------------------------------------------------------------------------
# stage_partition — [3/9]
#
# Reads from main()'s frame: staging, bsp_dir, firstparty_dir.
# ---------------------------------------------------------------------------
stage_partition() {
  log_info "[3/9] partitioning staged .debs into BSP vs first-party by package name"
  # The set of BSP package names (manifest-declared) is the partition key.
  local bsp_names=" ${KERNEL_PACKAGES} ${DTB_PACKAGES} ${UBOOT_PACKAGES} ${FIRMWARE_PACKAGES} ${HW_ACCEL_GSTREAMER_PLUGINS:-} ${GSTREAMER_RUNTIME_PACKAGES:-} "
  # MUST stay a superset of fetch-debs.sh FIRST_PARTY_APT_PKGS: the 5 core packages
  # + the 9-package ModemManager 1.24 closure (modem-stack v0.2.0, ~ceralive0.2.0).
  # The fetcher stages all 14 into debs/; a name missing here fails the build as
  # "unclassified staged package" on a real (non-DRY_RUN) build. Guarded by
  # v2/tests/firstparty-classification.test.sh.
  local firstparty_names=" libsrt1.5-ceralive cerastream gstreamer1.0-libuvch264src ceralive-device srtla-send-rs modemmanager libmm-glib0 libmbim-glib4 libmbim-proxy libmbim-utils libqmi-glib5 libqmi-proxy libqmi-utils libqrtr-glib0 "
  local deb pkg
  shopt -s nullglob
  for deb in "${staging}/debs"/*.deb; do
    pkg="$(deb_pkg_name "${deb}")"
    if [[ -n "${pkg}" && "${bsp_names}" == *" ${pkg} "* ]]; then
      "${MKOSI_PACKAGE_STAGING_SH}" "${deb}" "${bsp_dir}"
    elif [[ -n "${pkg}" && "${firstparty_names}" == *" ${pkg} "* ]]; then
      "${MKOSI_PACKAGE_STAGING_SH}" "${deb}" "${firstparty_dir}"
    else
      die "unclassified staged package: ${pkg:-<unreadable>} ($(basename "${deb}"))"
    fi
  done
  shopt -u nullglob
  log_info "staged: $(find "${bsp_dir}" -name '*.deb' | wc -l) BSP, $(find "${firstparty_dir}" -name '*.deb' | wc -l) first-party .deb(s)"
}
