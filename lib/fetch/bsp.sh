#!/usr/bin/env bash
#
# fetch/bsp.sh — the Armbian BSP family: which BSP packages this build declares,
# their exact reviewed versions, and the two transports that stage them
# (native apt-get on Debian hosts, curl over the signed index elsewhere).
#
# Sourced by lib/fetch-debs.sh; not standalone. Reads the ARMBIAN_* / ARCH /
# BSP_DEB_VERSIONS_FILE configuration from the entry point, the pool globals
# from fetch/pool.sh, and calls into fetch/verify.sh for every verdict.
#
# Bodies moved VERBATIM from fetch-debs.sh; no behaviour change.
#
# shellcheck shell=bash
bsp_download_specs() {
  [[ -f "${BSP_DEB_VERSIONS_FILE}" ]] \
    || die "exact BSP Debian version file missing: ${BSP_DEB_VERSIONS_FILE}"
  local pkg version
  local -a versions=()
  for pkg in "$@"; do
    mapfile -t versions < <(
      awk -F= -v pkg="${pkg}" '$1==pkg { print substr($0, length($1) + 2) }' \
        "${BSP_DEB_VERSIONS_FILE}"
    )
    (( ${#versions[@]} == 1 )) \
      || die "expected exactly one BSP Debian version for ${pkg}, found ${#versions[@]}"
    version="${versions[0]}"
    [[ "${version}" =~ ^[^[:space:]=]+$ ]] \
      || die "invalid exact BSP Debian version for ${pkg}: ${version}"
    printf '%s=%s\n' "${pkg}" "${version}"
  done
}
# _fetch_bsp_native_one — bounded-pool worker: download ONE BSP .deb into a
# private temp dir, then atomically rename the result into ${_BSP_DEBS}. A killed
# apt-get leaves files only in the throwaway .fetch-* dir, never a partial final.
_fetch_bsp_native_one() {
  local spec="$1" pkg="${1%%=*}"
  [[ "${spec}" == *=* && -n "${pkg}" && -n "${spec#*=}" ]] \
    || die "invalid BSP package spec: ${spec}"
  log_info "BSP fetch: ${spec} (${ARMBIAN_SUITE}/${ARCH})"
  if [[ -n "${DRY_RUN}" ]]; then
    run_or_plan bash -c \
      "cd $(printf '%q' "${_BSP_DEBS}") && apt-get $(printf '%q ' "${_APT_OPTS[@]}")download $(printf '%q' "${spec}")"
    return 0
  fi
  # A cache HIT needs the expected hash BEFORE anything is downloaded, and on the
  # apt transport the only pre-download source of one is the Packages list apt
  # itself verified against the pinned-keyring InRelease. No list, no hit — the
  # fetch then behaves exactly as it did before the cache existed.
  local hit_resolved hit_file hit_sha
  if [[ -n "${_BSP_APT_INDEX}" ]]; then
    hit_resolved="$(auth_lookup_package "${_BSP_APT_INDEX}" "${pkg}" "${spec#*=}" "${ARCH}" || true)"
    if [[ -n "${hit_resolved}" ]]; then
      IFS=$'\t' read -r hit_file hit_sha _ <<<"${hit_resolved}"
      if debcache_try_hit "$(basename "${hit_file}")" "${hit_sha}" \
          "${_BSP_DEBS}/$(basename "${hit_file}")"; then
        return 0
      fi
    fi
  fi

  # `apt-get download` writes to the CWD and honours no destination option, so
  # the cd stays OUTSIDE retry_transient — the retried unit is the bare apt-get.
  local tmpd; tmpd="$(mktemp -d "${_BSP_DEBS}/.fetch-XXXXXX")"
  if ! ( cd "${tmpd}" && retry_transient "BSP download ${spec}" \
      apt-get "${_APT_OPTS[@]}" download "${spec}" ); then
    rm -rf "${tmpd}"
    return 1
  fi
  local actual_pkg actual_version actual_arch
  local -a staged=()
  shopt -s nullglob
  staged=("${tmpd}"/*.deb)
  shopt -u nullglob
  if (( ${#staged[@]} != 1 )); then
    log_error "BSP fetch produced ${#staged[@]} .deb files for ${spec}; expected exactly one"
    rm -rf "${tmpd}"
    return 1
  fi
  actual_pkg="$(deb_pkg_name "${staged[0]}")"
  actual_version="$(deb_pkg_version "${staged[0]}")"
  actual_arch="$(deb_pkg_arch "${staged[0]}")"
  if [[ "${actual_pkg}" != "${pkg}" || "${actual_version}" != "${spec#*=}" \
      || ( "${actual_arch}" != "${ARCH}" && "${actual_arch}" != "all" ) ]]; then
    log_error "BSP fetch control mismatch for ${spec}: package=${actual_pkg:-<missing>} version=${actual_version:-<missing>} architecture=${actual_arch:-<missing>}"
    rm -rf "${tmpd}"
    return 1
  fi
  if ! publish_staged_deb "${staged[0]}" "${_BSP_DEBS}/$(basename "${staged[0]}")"; then
    rm -rf "${tmpd}"
    return 1
  fi
  rm -rf "${tmpd}"
}

# ---------------------------------------------------------------------------
# _fetch_bsp_native — native apt-get path (Debian/Ubuntu hosts).
# Isolated apt state so the host apt config is never touched. The Armbian repo
# is declared in a throwaway sources list; `apt-get download` fetches the .deb
# for the current suite into $debs. The per-package downloads run through the
# bounded fetch pool; the shared apt state is prepared once, serially, first.
# ---------------------------------------------------------------------------
_fetch_bsp_native() {
  local debs="$1"; shift
  local bsp_pkgs=("$@")

  # Materialise the shared scratch dir BEFORE the bounded pool forks: a worker
  # subshell does not inherit the EXIT trap, so a dir first created inside one
  # would never be reaped.
  fetch_scratch_init

  local apt_state="${debs}/.apt-state"
  run_or_plan mkdir -p "${apt_state}/lists/partial" "${apt_state}/cache/archives/partial"
  local src_list="${apt_state}/armbian.list"
  if [[ -z "${DRY_RUN}" ]]; then
    printf 'deb [arch=%s signed-by=%s] %s %s main\n' \
      "${ARCH}" "${ARMBIAN_APT_KEYRING}" "${ARMBIAN_APT_URL}" "${ARMBIAN_SUITE}" >"${src_list}"
  else
    log_info "DRY-RUN would write Armbian source: deb [arch=${ARCH}] ${ARMBIAN_APT_URL} ${ARMBIAN_SUITE} main -> ${src_list}"
  fi

  local apt_opts=(
    -o "Dir::Etc::SourceList=${src_list}"
    -o "Dir::Etc::SourceParts=-"
    -o "Dir::State::Lists=${apt_state}/lists"
    -o "Dir::Cache=${apt_state}/cache"
    -o "Dir::Cache::Archives=${apt_state}/cache/archives"
    -o "APT::Architecture=${ARCH}"
  )

  run_or_plan_retry "Armbian apt-get update" apt-get "${apt_opts[@]}" update
  if [[ -z "${DRY_RUN}" ]]; then
    bsp_verify_native_release \
      "${apt_state}" "${ARMBIAN_APT_KEYRING}" "${ARMBIAN_SUITE}" main "${ARCH}" \
      "${ARMBIAN_APT_KEY_FINGERPRINTS[@]}" \
      || die "BSP fetch failed native dual-signature/identity verification"
  fi

  _BSP_DEBS="${debs}"
  _APT_OPTS=("${apt_opts[@]}")
  _BSP_APT_INDEX=""
  if [[ -z "${DRY_RUN}" ]] && debcache_enabled; then
    _BSP_APT_INDEX="$(debcache_apt_index "${apt_state}")"
  fi
  local jobs="${FETCH_JOBS}"; [[ -n "${DRY_RUN}" ]] && jobs=1
  _run_bounded "${jobs}" _fetch_bsp_native_one "${bsp_pkgs[@]}" \
    || die "BSP fetch failed (native apt path): one or more packages did not download"
}

# _fetch_bsp_curl_one — bounded-pool worker: resolve ONE exact BSP package spec to its
# pool path via the cached Packages index (${_PKG_INDEX}), curl it to a private
# .tmp-* file, then atomically rename into ${_BSP_DEBS}. A killed curl leaves
# only the .tmp-* partial, never a half-written final .deb.
_fetch_bsp_curl_one() {
  local spec="$1" pkg="${1%%=*}" wanted_version=""
  local resolved="" filename="" sha256="" version=""
  if [[ "${spec}" == *=* ]]; then
    wanted_version="${spec#*=}"
  fi
  [[ "${spec}" == *=* && -n "${pkg}" && -n "${wanted_version}" ]] \
    || die "invalid BSP package spec: ${spec}"
  if [[ -z "${DRY_RUN}" ]]; then
    resolved="$(auth_lookup_package "${_PKG_INDEX}" "${pkg}" "${wanted_version}" "${ARCH}")"
    [[ -n "${resolved}" ]] \
      || die "exact BSP package '${spec}' unavailable in ${ARMBIAN_SUITE}/main/binary-${ARCH} Packages index"
    IFS=$'\t' read -r filename sha256 version <<<"${resolved}"
  fi
  log_info "BSP fetch (curl): ${spec}"
  if [[ -n "${DRY_RUN}" ]]; then
    run_or_plan curl -fsSL --retry 3 "${CURL_TIMEOUT_OPTS[@]}" \
      -o "${_BSP_DEBS}/$(basename "${filename:-${pkg}.deb}")" \
      "${ARMBIAN_APT_URL}/${filename:-DRYRUN}"
    return 0
  fi
  local final tmp actual_pkg actual_version actual_arch
  final="${_BSP_DEBS}/$(basename "${filename}")"
  # ${sha256} came from the gpgv-verified Packages index, so a cache hit is held
  # to the same signed-metadata hash the download would have been.
  if debcache_try_hit "$(basename "${filename}")" "${sha256}" "${final}"; then
    return 0
  fi
  tmp="$(mktemp "${_BSP_DEBS}/.tmp-XXXXXX")"
  if ! curl -fsSL --retry 3 "${CURL_TIMEOUT_OPTS[@]}" -o "${tmp}" "${ARMBIAN_APT_URL}/${filename}"; then
    rm -f "${tmp}"
    return 1
  fi
  if ! auth_verify_file "${tmp}" "${sha256}"; then
    log_error "BSP package checksum mismatch for ${pkg}=${version}"
    rm -f "${tmp}"
    return 1
  fi
  actual_pkg="$(deb_pkg_name "${tmp}")"
  actual_version="$(deb_pkg_version "${tmp}")"
  actual_arch="$(deb_pkg_arch "${tmp}")"
  if [[ "${actual_pkg}" != "${pkg}" || "${actual_version}" != "${wanted_version}" \
      || ( "${actual_arch}" != "${ARCH}" && "${actual_arch}" != "all" ) ]]; then
    log_error "BSP package control mismatch for ${spec}: package=${actual_pkg:-<missing>} version=${actual_version:-<missing>} architecture=${actual_arch:-<missing>}"
    rm -f "${tmp}"
    return 1
  fi
  if ! publish_staged_deb "${tmp}" "${final}"; then
    rm -f "${tmp}"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# _fetch_bsp_curl — curl-based fallback for non-Debian hosts (e.g. Arch Linux).
# Downloads the Armbian Packages.gz index, preflights every exact BSP package spec,
# its pool URL, then curl-fetches the .deb. No apt-get, no Docker, no GPG key
# import required. Works on any host with curl + gzip. The index is fetched once;
# per-package downloads run through the bounded fetch pool.
# ---------------------------------------------------------------------------
_fetch_bsp_curl() {
  local debs="$1"; shift
  local bsp_pkgs=("$@")
  require_cmd curl
  require_cmd gzip

  log_info "apt-get not found (non-Debian host) — fetching BSP via curl from ${ARMBIAN_APT_URL}"

  local release_base="${ARMBIAN_APT_URL}/dists/${ARMBIAN_SUITE}"
  local packages_rel="main/binary-${ARCH}/Packages.gz"
  local packages_url="${release_base}/${packages_rel}"
  fetch_scratch_init
  local packages_file="${FETCH_TMPDIR}/Packages"
  local inrelease="${FETCH_TMPDIR}/InRelease"
  local verified_release="${FETCH_TMPDIR}/Release" expected_sha actual_sha
  run_or_plan curl -fsSL --retry 3 "${CURL_TIMEOUT_OPTS[@]}" -o "${inrelease}" "${release_base}/InRelease" \
    || die "failed to download Armbian InRelease"
  if [[ -z "${DRY_RUN}" ]]; then
    auth_verify_release_to_file \
      "${ARMBIAN_APT_KEYRING}" "${inrelease}" "${verified_release}" \
      "${ARMBIAN_APT_KEY_FINGERPRINTS[@]}" \
      || die "Armbian InRelease signature verification failed"
    auth_release_has_identity "${verified_release}" "${ARMBIAN_SUITE}" main "${ARCH}" \
      || die "Armbian InRelease identity mismatch: expected suite=${ARMBIAN_SUITE} component=main arch=${ARCH}"
    expected_sha="$(awk -v path="${packages_rel}" '
      /^SHA256:/{inside=1;next} /^[A-Za-z0-9-]+:/{inside=0}
      inside && $3==path{print $1;exit}
    ' "${verified_release}")"
    [[ -n "${expected_sha}" ]] || die "Armbian InRelease lacks ${packages_rel} SHA256"
  fi
  run_or_plan curl -fsSL --retry 3 "${CURL_TIMEOUT_OPTS[@]}" -o "${packages_file}.gz" "${packages_url}" \
    || die "failed to download Armbian Packages index: ${packages_url}"

  if [[ -z "${DRY_RUN}" ]]; then
    actual_sha="$(sha256sum "${packages_file}.gz" | cut -d' ' -f1)"
    [[ "${actual_sha}" == "${expected_sha}" ]] \
      || die "Armbian Packages.gz checksum mismatch"
    gzip -df "${packages_file}.gz" || die "failed to decompress Armbian Packages.gz"
  else
    log_info "DRY-RUN: would decompress ${packages_file}.gz"
  fi

  _BSP_DEBS="${debs}"
  _PKG_INDEX="${packages_file}"
  if [[ -z "${DRY_RUN}" ]]; then
    bsp_assert_index_specs "${_PKG_INDEX}" "${ARCH}" "${bsp_pkgs[@]}" \
      || die "BSP signed index preflight failed before package downloads"
  fi
  local jobs="${FETCH_JOBS}"; [[ -n "${DRY_RUN}" ]] && jobs=1
  _run_bounded "${jobs}" _fetch_bsp_curl_one "${bsp_pkgs[@]}" \
    || die "BSP fetch failed (curl path): one or more packages did not download"
  return 0
}
# ---------------------------------------------------------------------------
# collect_declared_bsp_pkgs <family> — echo the deduped, order-preserving set of
# BSP-class package NAMES this build declares: the family manifest's
# kernel/dtb/uboot/firmware/hw-accel-gstreamer/gstreamer-runtime lists UNIONED with
# the same-named board override env vars (resolve.py flattens board-over-family into
# ${*_PACKAGES}; board arrays REPLACE family arrays on merge, so the env value is
# authoritative and the union+dedup collapses the family duplicate). One name per
# line. Single source of truth for "what packages does this build declare",
# consumed by BOTH fetch_bsp (the Armbian set, minus userspace pins) and
# fetch_rk3588_userspace (the pinned-URL subset).
#
# KERNEL-FROM-SOURCE SUPPRESSION (task 26). When an opt-in family variant builds
# the kernel from source, CERALIVE_KERNEL_SOURCE_SUPPRESSED_PKGS names exactly the
# kernel/DTB packages that must NOT be fetched remotely — both the pre-overlay
# vendor names (which the family file still lists) and the post-overlay built
# names (which no remote archive carries). Filtering HERE rather than in each
# fetcher means a suppressed package is invisible to every remote path at once.
# U-Boot and firmware are deliberately never in that set: they stay prebuilt-
# fetched. The list is DERIVED by resolve.py, never authored, so it cannot drift
# from the replacement set. Empty/unset on the production vendor path.
# ---------------------------------------------------------------------------
collect_declared_bsp_pkgs() {
  local family="$1"
  local -a pkgs=()
  local field item pkg
  local fields=(
    kernel_packages
    dtb_packages
    uboot_packages
    firmware_packages
    hw_accel_gstreamer_plugins
    gstreamer_runtime_packages
  )
  for field in "${fields[@]}"; do
    while IFS= read -r item; do
      [[ -n "${item}" ]] && pkgs+=("${item}")
    done < <(read_yaml_list "${field}" "${family}")
  done
  for pkg in ${UBOOT_PACKAGES:-} ${KERNEL_PACKAGES:-} ${DTB_PACKAGES:-} \
             ${FIRMWARE_PACKAGES:-} ${HW_ACCEL_GSTREAMER_PLUGINS:-} \
             ${GSTREAMER_RUNTIME_PACKAGES:-}; do
    [[ -n "${pkg}" ]] && pkgs+=("${pkg}")
  done
  local suppressed=" ${CERALIVE_KERNEL_SOURCE_SUPPRESSED_PKGS:-} "
  local -a deduped=()
  local seen="|" p
  for p in "${pkgs[@]}"; do
    if [[ "${suppressed}" == *" ${p} "* ]]; then
      continue
    fi
    [[ "${seen}" == *"|${p}|"* ]] || { deduped+=("${p}"); seen+="${p}|"; }
  done
  (( ${#deduped[@]} > 0 )) && printf '%s\n' "${deduped[@]}"
  return 0
}
# ---------------------------------------------------------------------------
# fetch_bsp — read BSP package names from the resolved family manifest, bind each
# to its reviewed exact version, and pull it from the Armbian apt pool into
# $DEST/debs/. Decision D3's vendor branch remains encoded in the package name.
#
# On Debian/Ubuntu hosts with apt-get, uses native path. On other hosts (e.g.
# Arch Linux), delegates to Docker/Podman fallback.
# ---------------------------------------------------------------------------
fetch_bsp() {
  local family="$1" debs="$2"
  [[ -n "${family}" ]] || die "fetch_bsp: --family manifest required for BSP packages"
  [[ -f "${family}" ]] || die "fetch_bsp: family manifest not found: ${family}"

  local -a declared=()
  mapfile -t declared < <(collect_declared_bsp_pkgs "${family}")
  if (( ${#declared[@]} == 0 )); then
    die "fetch_bsp: no BSP packages found in ${family} or env (expected kernel/dtb/uboot/firmware names)"
  fi

  # RK3588 HW-accel userspace packages (Mali blob, MPP, RGA, gst-rockchip,
  # multimedia-config) are NOT in the Armbian pool — fetch_rk3588_userspace stages
  # them from SHA-256-verified pinned URLs. Exclude them here so bsp_download_specs
  # never tries to resolve an Armbian version for a package Armbian does not carry.
  local -A _userspace=()
  local uname
  while IFS= read -r uname; do
    [[ -n "${uname}" ]] && _userspace["${uname}"]=1
  done < <(rk3588_userspace_pkg_names)
  local -a bsp_pkgs=()
  local bp
  for bp in "${declared[@]}"; do
    [[ -n "${_userspace[${bp}]:-}" ]] || bsp_pkgs+=("${bp}")
  done
  if (( ${#bsp_pkgs[@]} == 0 )); then
    die "fetch_bsp: every declared package in ${family} is an RK3588 userspace pin — expected at least one Armbian BSP package (kernel/dtb/uboot/firmware)"
  fi

  log_info "BSP set from $(basename "${family}") (${#bsp_pkgs[@]} pkgs): ${bsp_pkgs[*]}"
  local armbian_branch
  armbian_branch="$(read_yaml_value armbian_branch "${family}")"
  if [[ "${armbian_branch}" == "none" ]]; then
    if [[ -n "${DRY_RUN}" ]]; then
      log_info "non-Armbian family: BSP fetch omitted from DRY_RUN plan"
      return 0
    fi
    die "authenticated non-Armbian BSP fetch is not implemented for $(basename "${family}"); refusing an unpinned download"
  fi

  local -a bsp_specs=()
  local specs_text
  specs_text="$(bsp_download_specs "${bsp_pkgs[@]}")" \
    || die "failed to resolve exact BSP Debian package versions"
  mapfile -t bsp_specs <<<"${specs_text}"
  (( ${#bsp_specs[@]} == ${#bsp_pkgs[@]} )) \
    || die "BSP version registry resolved ${#bsp_specs[@]} specs for ${#bsp_pkgs[@]} packages"
  log_info "BSP apt specs: ${bsp_specs[*]}"
  log_info "Armbian source: ${ARMBIAN_APT_URL} suite=${ARMBIAN_SUITE} arch=${ARCH}"

  if [[ -z "${DRY_RUN}" ]]; then
    [[ -s "${ARMBIAN_APT_KEYRING}" ]] \
      || die "ARMBIAN_APT_KEYRING is required for authenticated BSP fetches"
    auth_keyring_has_exact_fingerprints \
      "${ARMBIAN_APT_KEYRING}" "${ARMBIAN_APT_KEY_FINGERPRINTS[@]}" \
      || die "Armbian keyring primary fingerprints do not exactly match pinned set: ${ARMBIAN_APT_KEY_FINGERPRINTS[*]}"
  fi

  if command -v apt-get >/dev/null 2>&1; then
    _fetch_bsp_native "${debs}" "${bsp_specs[@]}"
  else
    _fetch_bsp_curl "${debs}" "${bsp_specs[@]}"
  fi

  # Provenance + content drift-guard for the exact-versioned kernel BSP. The board
  # KERNEL_PACKAGES override (resolve.py) wins over the family field, mirroring
  # the array-REPLACE merge above. Real-fetch only — DRY_RUN stages no .deb.
  #
  # A suppressed kernel package was never fetched here, so there is no staged
  # .deb to hash: the drift-guard's subject is the ARMBIAN archive's bytes, and a
  # kernel built from a pinned source tree + pinned patch commit is pinned by
  # construction. Capturing provenance for it would either fail or, worse, seed
  # the baseline with a locally-built hash and make a real Armbian re-spin look
  # clean forever.
  local suppressed=" ${CERALIVE_KERNEL_SOURCE_SUPPRESSED_PKGS:-} "
  local -a kernel_pkgs=()
  if [[ -n "${KERNEL_PACKAGES:-}" ]]; then
    for pkg in ${KERNEL_PACKAGES}; do
      if [[ -n "${pkg}" && "${suppressed}" != *" ${pkg} "* ]]; then
        kernel_pkgs+=("${pkg}")
      fi
    done
  else
    while IFS= read -r item; do
      if [[ -n "${item}" && "${suppressed}" != *" ${item} "* ]]; then
        kernel_pkgs+=("${item}")
      fi
    done < <(read_yaml_list kernel_packages "${family}")
  fi
  if [[ -z "${DRY_RUN}" && ${#kernel_pkgs[@]} -gt 0 ]]; then
    bsp_capture_provenance "$(dirname "${debs}")" "${debs}" "${kernel_pkgs[0]}"
  fi
}
