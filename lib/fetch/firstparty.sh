#!/usr/bin/env bash
#
# fetch/firstparty.sh — the first-party family: the CeraLive device .debs pulled
# from apt.ceralive.tv over a GPG-verified, mTLS-authenticated apt source, with a
# verified-curl fallback for non-Debian hosts.
#
# Also home to the privilege-aware apt-sandbox plumbing. apt drops its acquire
# methods to `_apt` only when invoked as root, and this path runs on the HOST
# before any container — so it branches on that rather than reaching for apt's
# sandbox-user override, which disables the sandbox instead of fixing the
# permission. Read the block comment there before touching it.
#
# Sourced by lib/fetch-debs.sh; not standalone. It reads the sacred
# FIRST_PARTY_APT_PKGS / REPOS constants and the APT_CERALIVE_URL / CHANNEL /
# ARCH configuration, all of which stay in the entry point.
#
# Bodies moved VERBATIM from fetch-debs.sh; no behaviour change.
#
# shellcheck shell=bash
first_party_pinned_version() {
  local pkg="$1" arch_key="${1}[${ARCH}]"
  local -a values=()

  mapfile -t values < <(awk -F= -v key="${arch_key}" '$1==key{print substr($0,length($1)+2)}' "${FIRST_PARTY_DEB_VERSIONS_FILE}")
  (( ${#values[@]} <= 1 )) \
    || die "duplicate architecture-specific Debian versions for first-party package ${pkg}/${ARCH}"
  if (( ${#values[@]} == 1 )); then
    [[ -n "${values[0]}" ]] \
      || die "empty architecture-specific Debian version for first-party package ${pkg}/${ARCH}"
    printf '%s\n' "${values[0]}"
    return 0
  fi

  mapfile -t values < <(awk -F= -v key="${pkg}" '$1==key{print substr($0,length($1)+2)}' "${FIRST_PARTY_DEB_VERSIONS_FILE}")
  (( ${#values[@]} <= 1 )) \
    || die "duplicate generic Debian versions for first-party package ${pkg}"
  if (( ${#values[@]} != 1 )) || [[ -z "${values[0]}" ]]; then
    die "exact Debian version missing for first-party package ${pkg}/${ARCH}"
  fi
  printf '%s\n' "${values[0]}"
}

first_party_download_specs() {
  local pkg version
  [[ -f "${FIRST_PARTY_DEB_VERSIONS_FILE}" ]] \
    || die "exact first-party Debian version file missing: ${FIRST_PARTY_DEB_VERSIONS_FILE}"
  for pkg in "${FIRST_PARTY_APT_PKGS[@]}"; do
    version="$(first_party_pinned_version "${pkg}")"
    printf '%s=%s\n' "${pkg}" "${version}"
  done
}

first_party_curl_url() {
  local filename="$1"
  case "${filename}" in
    http://*|https://*) printf '%s\n' "${filename}" ;;
    ./*) printf '%s/%s\n' "${_FIRST_PARTY_BASE_URL}" "${filename#./}" ;;
    /*) die "first-party package index contains absolute Filename: ${filename}" ;;
    *) printf '%s/%s\n' "${_FIRST_PARTY_BASE_URL}" "${filename}" ;;
  esac
}

first_party_lookup() {
  local spec="$1" pkg version
  pkg="${spec%%=*}"
  [[ "${spec}" == *=* ]] || die "first-party package lacks exact version: ${spec}"
  version="${spec#*=}"
  auth_lookup_package "${_FIRST_PARTY_INDEX}" "${pkg}" "${version}" "${ARCH}"
}

_fetch_first_party_curl_one() {
  local spec="$1" resolved filename sha256 version url final tmp actual
  resolved="$(first_party_lookup "${spec}")"
  [[ -n "${resolved}" ]] \
    || die "first-party package '${spec}' not found in ${APT_CERALIVE_URL}/dists/${CHANNEL}/binary-${ARCH}/Packages"
  IFS=$'\t' read -r filename sha256 version <<<"${resolved}"

  url="$(first_party_curl_url "${filename}")"
  final="${_FIRST_PARTY_DEBS}/$(basename "${filename}")"
  # ${sha256} is the signed-InRelease-anchored Packages hash — the same verdict
  # the download below is held to, so reuse cannot be the weaker path.
  if debcache_try_hit "$(basename "${filename}")" "${sha256}" "${final}"; then
    return 0
  fi
  tmp="$(mktemp "${_FIRST_PARTY_DEBS}/.tmp-firstparty-XXXXXX")"
  log_info "first-party fetch (curl): ${spec} resolved=${version}"
  curl -fsSL --retry 3 "${CURL_TIMEOUT_OPTS[@]}" "${_FIRST_PARTY_CURL_AUTH[@]}" -o "${tmp}" "${url}"
  actual="$(sha256sum "${tmp}" | awk '{print $1}')"
  [[ "${actual}" == "${sha256}" ]] \
    || die "first-party package checksum mismatch for ${spec}: expected ${sha256}, got ${actual}"
  if ! publish_staged_deb "${tmp}" "${final}"; then
    rm -f "${tmp}"
    return 1
  fi
}

_fetch_first_party_curl() {
  local debs="$1" keyring="$2" certs_dir="$3"; shift 3
  local download_specs=("$@")
  require_cmd curl
  require_cmd gzip
  require_cmd gpgv
  require_cmd sha256sum

  local repo_base="${APT_CERALIVE_URL}/dists/${CHANNEL}/binary-${ARCH}"
  local inrelease="${debs}/.apt-state-firstparty/InRelease"
  local packages_gz="${debs}/.apt-state-firstparty/Packages.gz"
  local packages="${debs}/.apt-state-firstparty/Packages"
  local verified_release="${debs}/.apt-state-firstparty/Release"
  local expected_sha

  local -a curl_auth=()
  if [[ -n "${APT_CLIENT_CRT_B64:-}" ]]; then
    curl_auth+=(--cert "${certs_dir}/client.crt" --key "${certs_dir}/client.key")
  fi

  log_info "apt-get not found (non-Debian host) — fetching first-party packages via verified curl from ${repo_base}"
  curl -fsSL --retry 3 "${CURL_TIMEOUT_OPTS[@]}" "${curl_auth[@]}" -o "${inrelease}" "${repo_base}/InRelease"
  auth_verify_release_to_file "${keyring}" "${inrelease}" "${verified_release}" \
    || die "first-party InRelease signature verification failed for ${repo_base}"

  expected_sha="$(index_release_digest "${verified_release}" Packages.gz)" \
    || die "first-party InRelease does not list Packages.gz SHA256 for ${repo_base}"

  curl -fsSL --retry 3 "${CURL_TIMEOUT_OPTS[@]}" "${curl_auth[@]}" -o "${packages_gz}" "${repo_base}/Packages.gz"
  index_verify_digest "${packages_gz}" "${expected_sha}" "first-party Packages.gz" \
    || die "first-party Packages.gz checksum mismatch"
  index_decompress_gz "${packages_gz}" "${packages}"

  _FIRST_PARTY_DEBS="${debs}"
  _FIRST_PARTY_INDEX="${packages}"
  _FIRST_PARTY_BASE_URL="${repo_base}"
  _FIRST_PARTY_CURL_AUTH=("${curl_auth[@]}")
  local jobs="${FETCH_JOBS}"; [[ -n "${DRY_RUN}" ]] && jobs=1
  _run_bounded "${jobs}" _fetch_first_party_curl_one "${download_specs[@]}" \
    || die "first-party fetch failed (curl path): one or more packages did not download"
}
# ---------------------------------------------------------------------------
# fetch_first_party — pull the first-party device .debs from apt.ceralive.tv via a
# GPG-verified, mTLS-authenticated apt source. REPLACES the retired R2
# `aws s3 sync` (CI) and `gh release download` (local) paths.
#
# Secrets arrive ONLY through the environment, base64-encoded, exactly as
# mkosi/customize/apt-ceralive-repo.sh consumes them (APT_GPG_PUBLIC_B64 +
# APT_CLIENT_CRT_B64/APT_CLIENT_KEY_B64). They are NEVER hardcoded, NEVER logged,
# NEVER committed. A half-supplied mTLS pair is fatal (same loud contract).
#
# Isolated apt state (mirrors _fetch_bsp_native): the host apt config is never
# touched. The .debs land in a throwaway temp dir and are atomically renamed into
# place, so an interrupted apt-get never leaves a half-written final .deb. One
# ---------------------------------------------------------------------------
fetch_first_party() {
  local debs="$1"
  local r

  fetch_scratch_init

  log_info "first-party pins (versions.yaml):"
  for r in "${REPOS[@]}"; do
    log_info "  ${r} = $(get_pin "${r}")"
  done

  log_info "first-party source: ${APT_CERALIVE_URL}/dists/${CHANNEL}/binary-${ARCH}/ (GPG Signed-By + mTLS)"
  log_info "first-party packages: ${FIRST_PARTY_APT_PKGS[*]}"
  local -a download_specs=()
  mapfile -t download_specs < <(first_party_download_specs)
  log_info "first-party apt specs: ${download_specs[*]}"

  # mTLS pair must be whole (both or neither) — apt-ceralive-repo.sh contract.
  local crt="${APT_CLIENT_CRT_B64:-}" key="${APT_CLIENT_KEY_B64:-}"
  if [[ -n "${crt}" && -z "${key}" ]] || [[ -z "${crt}" && -n "${key}" ]]; then
    die "incomplete mTLS pair: set BOTH APT_CLIENT_CRT_B64 and APT_CLIENT_KEY_B64, or neither"
  fi

  local apt_state="${debs}/.apt-state-firstparty"
  local certs_dir="${apt_state}/certs"
  local keyring="${apt_state}/ceralive-archive-keyring.gpg"
  local src_list="${apt_state}/ceralive.sources"

  apt_isolated_state_init "${apt_state}" "${certs_dir}"

  # deb822 source — the apt-ceralive-repo.sh pattern (arch-specific repo dists/{channel}/binary-{arch}/ +
  # Suites ./, GPG Signed-By); arch is chosen by APT::Architecture below.
  if [[ -z "${DRY_RUN}" ]]; then
    cat >"${src_list}" <<EOF
Types: deb
URIs: ${APT_CERALIVE_URL}/dists/${CHANNEL}/binary-${ARCH}/
Suites: ./
Signed-By: ${keyring}
EOF
  else
    log_info "DRY-RUN would write deb822 source -> ${src_list}: Types=deb URIs=${APT_CERALIVE_URL}/dists/${CHANNEL}/binary-${ARCH}/ Suites=./ Signed-By=${keyring}"
  fi

  # GPG keyring + mTLS certs from the environment. A real fetch with no GPG key is
  # refused — never pull unverified packages. Secret VALUES are never logged.
  if [[ -z "${DRY_RUN}" ]]; then
    [[ -n "${APT_GPG_PUBLIC_B64:-}" ]] \
      || die "APT_GPG_PUBLIC_B64 not set — refusing an unverified first-party fetch from ${APT_CERALIVE_URL} (CI injects the GPG public key)"
    require_cmd base64
    local raw_keyring="${apt_state}/ceralive-archive-keyring.raw"
    printf '%s' "${APT_GPG_PUBLIC_B64}" | base64 -d >"${raw_keyring}"
    if command -v gpg >/dev/null 2>&1 && gpg --dearmor <"${raw_keyring}" >"${keyring}" 2>/dev/null; then
      :
    else
      cp "${raw_keyring}" "${keyring}"
    fi
    chmod 644 "${keyring}"
    if [[ -n "${crt}" ]]; then
      printf '%s' "${crt}" | base64 -d >"${certs_dir}/client.crt"
      printf '%s' "${key}" | base64 -d >"${certs_dir}/client.key"
      chmod 644 "${certs_dir}/client.crt"
      chmod 600 "${certs_dir}/client.key"
    fi
    if apt_sandbox_active; then
      apt_sandbox_make_traversable "$(dirname "${debs}")" "${debs}" "${apt_state}" \
        "${apt_state}/lists" "${apt_state}/cache" "${apt_state}/cache/archives" "${certs_dir}"
      log_info "first-party apt sandbox: root — isolated apt state made ${APT_SANDBOX_USER}-traversable"
      if [[ -n "${crt}" ]]; then
        chown "${APT_SANDBOX_USER}:root" "${certs_dir}/client.key"
        chmod 400 "${certs_dir}/client.key"
        log_info "first-party apt sandbox: mTLS client key handed to ${APT_SANDBOX_USER} (0400)"
      fi
    else
      log_info "first-party apt sandbox: uid ${EUID} — apt keeps the invoking user's credentials, no override emitted"
      if [[ -n "${crt}" ]]; then
        [[ -r "${certs_dir}/client.key" ]] \
          || die "mTLS client key is not readable by the invoking user (uid ${EUID}): ${certs_dir}/client.key"
      fi
    fi
  else
    log_info "DRY-RUN: would install GPG keyring from APT_GPG_PUBLIC_B64 -> ${keyring}"
    if [[ -n "${crt}" ]]; then
      log_info "DRY-RUN: would install mTLS client cert/key from APT_CLIENT_CRT_B64/APT_CLIENT_KEY_B64 -> ${certs_dir}/"
    fi
  fi

  local -a apt_opts=()
  mapfile -t apt_opts < <(apt_isolated_opts "${apt_state}" "${src_list}" "${ARCH}")
  if [[ -n "${crt}" ]]; then
    apt_opts+=(
      -o "Acquire::https::apt.ceralive.tv::SslCert=${certs_dir}/client.crt"
      -o "Acquire::https::apt.ceralive.tv::SslKey=${certs_dir}/client.key"
    )
  fi

  if [[ -n "${DRY_RUN}" ]]; then
    log_info "DRY-RUN would run: apt-get $(printf '%q ' "${apt_opts[@]}")update"
    log_info "DRY-RUN would run: (cd ${debs} && apt-get $(printf '%q ' "${apt_opts[@]}")download ${download_specs[*]})  # from ${APT_CERALIVE_URL}/dists/${CHANNEL}/"
    return 0
  fi

  if [[ "${FETCH_DEBS_FIRST_PARTY_TRANSPORT:-}" == "curl" ]] || ! command -v apt-get >/dev/null 2>&1; then
    _fetch_first_party_curl "${debs}" "${keyring}" "${certs_dir}" "${download_specs[@]}"
  else
    run_or_plan_retry "first-party apt-get update" apt-get "${apt_opts[@]}" update

    # apt downloads the whole spec list in ONE invocation, so a cache hit has to
    # be expressed by removing the spec from that list rather than by skipping a
    # per-package download. The expected hash comes from the Packages list apt
    # verified against the GPG-signed InRelease; with no list, nothing is removed
    # and the transport behaves exactly as it did before the cache existed.
    local fp_index=""
    if debcache_enabled; then
      fp_index="$(debcache_apt_index "${apt_state}")"
    fi
    local -a wanted=()
    local spec hit_resolved hit_file hit_sha hit_rc
    for spec in "${download_specs[@]}"; do
      if [[ -n "${fp_index}" ]]; then
        hit_rc=0
        hit_resolved="$(index_lookup_optional "${fp_index}" "${spec%%=*}" "${spec#*=}" "${ARCH}")" \
          || hit_rc=$?
        if (( hit_rc == INDEX_LOOKUP_UNUSABLE )); then
          die "first-party cache probe for ${spec}: apt's verified Packages list is unusable — refusing to continue on an unverifiable index"
        fi
        if (( hit_rc == 0 )) && [[ -n "${hit_resolved}" ]]; then
          IFS=$'\t' read -r hit_file hit_sha _ <<<"${hit_resolved}"
          if debcache_try_hit "$(basename "${hit_file}")" "${hit_sha}" \
              "${debs}/$(basename "${hit_file}")"; then
            continue
          fi
        fi
      fi
      wanted+=("${spec}")
    done

    if (( ${#wanted[@]} > 0 )); then
      local tmpd; tmpd="$(mktemp -d "${debs}/.fetch-firstparty-XXXXXX")"
      # mktemp -d is 0700 root-owned and apt writes the .deb here AS `_apt`.
      if apt_sandbox_active; then
        apt_sandbox_own_download_dir "${tmpd}"
      fi
      if ! ( cd "${tmpd}" && retry_transient "first-party apt-get download" \
          apt-get "${apt_opts[@]}" download "${wanted[@]}" ); then
        rm -rf "${tmpd}"
        die "first-party fetch failed (apt-get download from ${APT_CERALIVE_URL})"
      fi
      local f publish_failed=0
      shopt -s nullglob
      for f in "${tmpd}"/*.deb; do
        if ! publish_staged_deb "${f}" "${debs}/$(basename "${f}")"; then
          publish_failed=1
          break
        fi
      done
      shopt -u nullglob
      rm -rf "${tmpd}"
      (( publish_failed == 0 )) || return 1
    else
      log_info "first-party: every package served from the .deb cache — no apt download needed"
    fi
  fi

  local pkg
  local -a staged=()
  shopt -s nullglob
  for pkg in "${FIRST_PARTY_APT_PKGS[@]}"; do
    staged+=("${debs}/${pkg}"_*.deb)
  done
  shopt -u nullglob
  (( ${#staged[@]} == ${#FIRST_PARTY_APT_PKGS[@]} )) \
    || die "first-party fetch staged ${#staged[@]} .debs (expected exactly ${#FIRST_PARTY_APT_PKGS[@]})"
  local expected spec expected_version actual_pkg actual_version actual_arch staged_total
  staged_total="${#staged[@]}"
  for spec in "${download_specs[@]}"; do
    expected="${spec%%=*}"; expected_version="${spec#*=}"
    mapfile -t staged < <(find "${debs}" -maxdepth 1 -type f -name "${expected}_*.deb" -print)
    (( ${#staged[@]} == 1 )) || die "expected exactly one staged ${expected} .deb"
    assert_deb_identity "${staged[0]}" "${expected}" "${expected_version}" "${ARCH}" \
      || { actual_pkg="${DEB_ACTUAL_PKG}"; actual_version="${DEB_ACTUAL_VERSION}"; actual_arch="${DEB_ACTUAL_ARCH}"
           die "staged package identity mismatch for ${expected}: got ${actual_pkg}=${actual_version}/${actual_arch}"; }
  done
  log_success "first-party: staged ${staged_total} .deb(s) from ${APT_CERALIVE_URL}/dists/${CHANNEL}/binary-${ARCH}/"
}
