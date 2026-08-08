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
# ---------------------------------------------------------------------------
# get_pin — read a component pin from versions.yaml (graceful: "" when absent).
# Mirrors scripts/fetch-debs.sh get_pin so behaviour stays identical post-rework.
# ---------------------------------------------------------------------------
get_pin() {
  local key="$1" file="${2:-$VERSIONS_YAML}"
  [[ -f "$file" ]] || { printf ''; return; }
  awk -v key="$key" '$0==key":"{f=1;next} f&&/^[a-zA-Z]/{f=0}
    f&&/^[[:space:]]+pin:/{gsub(/^[[:space:]]+pin:[[:space:]]*/,"");print;exit}' "$file"
}

first_party_download_specs() {
  local pkg version
  [[ -f "${FIRST_PARTY_DEB_VERSIONS_FILE}" ]] \
    || die "exact first-party Debian version file missing: ${FIRST_PARTY_DEB_VERSIONS_FILE}"
  for pkg in "${FIRST_PARTY_APT_PKGS[@]}"; do
    version="$(awk -F= -v pkg="${pkg}" '$1==pkg{print substr($0,length($1)+2); exit}' "${FIRST_PARTY_DEB_VERSIONS_FILE}")"
    [[ -n "${version}" ]] || die "exact Debian version missing for first-party package ${pkg}"
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
  local expected_sha actual_sha

  local -a curl_auth=()
  if [[ -n "${APT_CLIENT_CRT_B64:-}" ]]; then
    curl_auth+=(--cert "${certs_dir}/client.crt" --key "${certs_dir}/client.key")
  fi

  log_info "apt-get not found (non-Debian host) — fetching first-party packages via verified curl from ${repo_base}"
  curl -fsSL --retry 3 "${CURL_TIMEOUT_OPTS[@]}" "${curl_auth[@]}" -o "${inrelease}" "${repo_base}/InRelease"
  auth_verify_release_to_file "${keyring}" "${inrelease}" "${verified_release}" \
    || die "first-party InRelease signature verification failed for ${repo_base}"

  expected_sha="$(awk '
    /^SHA256:/{ in_sha=1; next }
    /^[A-Za-z0-9-]+:/{ in_sha=0 }
    in_sha && $3 == "Packages.gz" { print $1; exit }
  ' "${verified_release}")"
  [[ -n "${expected_sha}" ]] \
    || die "first-party InRelease does not list Packages.gz SHA256 for ${repo_base}"

  curl -fsSL --retry 3 "${CURL_TIMEOUT_OPTS[@]}" "${curl_auth[@]}" -o "${packages_gz}" "${repo_base}/Packages.gz"
  actual_sha="$(sha256sum "${packages_gz}" | awk '{print $1}')"
  [[ "${actual_sha}" == "${expected_sha}" ]] \
    || die "first-party Packages.gz checksum mismatch: expected ${expected_sha}, got ${actual_sha}"
  gzip -dc "${packages_gz}" >"${packages}"

  _FIRST_PARTY_DEBS="${debs}"
  _FIRST_PARTY_INDEX="${packages}"
  _FIRST_PARTY_BASE_URL="${repo_base}"
  _FIRST_PARTY_CURL_AUTH=("${curl_auth[@]}")
  local jobs="${FETCH_JOBS}"; [[ -n "${DRY_RUN}" ]] && jobs=1
  _run_bounded "${jobs}" _fetch_first_party_curl_one "${download_specs[@]}" \
    || die "first-party fetch failed (curl path): one or more packages did not download"
}
# ---------------------------------------------------------------------------
# apt sandbox plumbing for the build-time first-party fetch.
#
# apt drops its acquire methods to `_apt` WHENEVER it is invoked as root, so a
# root-owned 0600 client key is unreadable to it — the device-side twin of this
# path already paid for that once (AGENTS.md, "Baked mTLS client key MUST be
# `_apt`-owned"). The old answer HERE was apt's sandbox-user override pinned to
# root, which fixes no permission: it turns the sandbox OFF for the whole
# build-time fetch. That override must never reappear in the emitted apt
# options — the guard greps this file for its literal spelling, so do not write
# it out even in a comment.
#
# Privilege-aware, because unlike the device this runs on the HOST (before any
# container, orchestrate.sh) and is frequently NOT root: as root, hand `_apt`
# the key and a tree it can traverse; unprivileged, apt never drops privileges
# so the invoking user's own credentials are already the right ones; with no
# `_apt` at all the host is non-Debian and the curl fallback owns the path.
# ---------------------------------------------------------------------------
APT_SANDBOX_USER="${APT_SANDBOX_USER:-_apt}"

apt_sandbox_user_exists() {
  if command -v getent >/dev/null 2>&1; then
    getent passwd "${APT_SANDBOX_USER}" >/dev/null 2>&1
  else
    grep -q "^${APT_SANDBOX_USER}:" /etc/passwd 2>/dev/null
  fi
}

# True only when apt will actually drop privileges for this fetch.
apt_sandbox_active() {
  (( EUID == 0 )) || return 1
  apt_sandbox_user_exists
}

# `_apt` must be able to TRAVERSE every directory apt reads or writes through.
# Explicit modes, never the ambient umask — the same reason the mkosi consumer
# directories are created with an explicit `install -d -m 0755`: a restrictive
# runner umask otherwise hides the tree from an unprivileged helper.
apt_sandbox_make_traversable() {
  local dir
  for dir in "$@"; do
    [[ -d "${dir}" ]] || continue
    chmod 0755 "${dir}"
  done
}

# apt WRITES the acquired .deb into the download directory as `_apt`, so
# traversal is not enough there: a mode-0755 root-owned download dir still
# degrades to "Download is performed unsandboxed as root". Hand the directory
# to `_apt` exactly the way apt hands itself its own `partial/` dirs.
apt_sandbox_own_download_dir() {
  local dir="$1"
  chown "${APT_SANDBOX_USER}:root" "${dir}"
  chmod 0700 "${dir}"
}

# ---------------------------------------------------------------------------
# fetch_first_party — pull the first-party device .debs from apt.ceralive.tv via a
# GPG-verified, mTLS-authenticated apt source. REPLACES the retired R2
# `aws s3 sync` (CI) and `gh release download` (local) paths.
#
# Secrets arrive ONLY through the environment, base64-encoded, exactly as
# v2/mkosi/customize/apt-ceralive-repo.sh consumes them (APT_GPG_PUBLIC_B64 +
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
    log_info "  ${r} = $(get_pin "${r}" || true)"
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

  run_or_plan mkdir -p "${apt_state}/lists/partial" \
    "${apt_state}/cache/archives/partial" "${certs_dir}"

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

  local apt_opts=(
    -o "Dir::Etc::SourceList=${src_list}"
    -o "Dir::Etc::SourceParts=-"
    -o "Dir::State::Lists=${apt_state}/lists"
    -o "Dir::Cache=${apt_state}/cache"
    -o "Dir::Cache::Archives=${apt_state}/cache/archives"
    -o "APT::Architecture=${ARCH}"
  )
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

    local tmpd; tmpd="$(mktemp -d "${debs}/.fetch-firstparty-XXXXXX")"
    # mktemp -d is 0700 root-owned and apt writes the .deb here AS `_apt`.
    if apt_sandbox_active; then
      apt_sandbox_own_download_dir "${tmpd}"
    fi
    if ! ( cd "${tmpd}" && retry_transient "first-party apt-get download" \
        apt-get "${apt_opts[@]}" download "${download_specs[@]}" ); then
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
    actual_pkg="$(deb_pkg_name "${staged[0]}")"; actual_version="$(deb_pkg_version "${staged[0]}")"
    actual_arch="$(deb_pkg_arch "${staged[0]}")"
    [[ "${actual_pkg}" == "${expected}" && "${actual_version}" == "${expected_version}" && "${actual_arch}" == "${ARCH}" ]] \
      || die "staged package identity mismatch for ${expected}: got ${actual_pkg}=${actual_version}/${actual_arch}"
  done
  log_success "first-party: staged ${staged_total} .deb(s) from ${APT_CERALIVE_URL}/dists/${CHANNEL}/binary-${ARCH}/"
}
