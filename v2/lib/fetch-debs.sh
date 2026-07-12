#!/usr/bin/env bash
#
# fetch-debs.sh — stage every .deb mkosi needs for a CeraLive device image.
#
# Two package classes land in ONE staging dir ($DEST/debs/) for the mkosi
# runtime/assembly layer to consume:
#
#   1. BSP packages  — kernel / DTB / U-Boot blob / firmware / GStreamer, read
#                      BY NAME from the resolved FAMILY manifest (typed package
#                      arrays), fetched from the Armbian apt repo. On Debian/Ubuntu
#                      hosts, apt-get is used directly. On non-Debian hosts (e.g.
#                      Arch Linux), the fetch runs inside the pinned trixie builder
#                      container via Docker/Podman.
#   2. First-party   — CeraLive SRT / cerastream / gstreamer1.0-libuvch264src /
#                      ceralive-device (CeraUI) / srtla-send-rs .debs, PULLED FROM
#                      apt.ceralive.tv via a GPG-verified, mTLS-authenticated apt
#                      source. The app layer installs the staged local .debs with
#                      no downloads. Debian's TLS-flavor libsrt packages are replaced
#                      by the single CeraLive runtime package during that transaction.
#
# This REPLACES the Armbian-chroot fetch of scripts/fetch-debs.sh. mkosi installs
# the staged .debs into the rootfs tree directly; there is no Armbian build here.
#
# ── Modes ────────────────────────────────────────────────────────────────────
#   Real fetch : BSP from the Armbian apt pool (apt-get on Debian hosts, curl
#                fallback elsewhere); first-party from apt.ceralive.tv with apt-get
#                when present, otherwise a curl fallback that verifies InRelease and
#                Packages.gz before downloading .debs.
#   Dry-run    : DRY_RUN=1 (auto when APT_GPG_PUBLIC_B64 is unset — no credential
#                to do a GPG-verified first-party fetch with)
#                -> log the EXACT command(s) + source that WOULD run; download
#                   nothing. Used for offline evidence and CI plan inspection. NOT
#                   `|| true`: an explicit, logged branch, never silent failure.
#
# ── Usage ────────────────────────────────────────────────────────────────────
#   fetch-debs.sh --family <manifest.yaml> [--dest <dir>]
#
# ── Env ──────────────────────────────────────────────────────────────────────
#   CHANNEL            stable|beta            (default: stable)
#   ARCH               arm64|amd64|x86-64     (default: arm64; Debian-normalized)
#   DEST               staging root           (default: ./out)  -> debs in $DEST/debs/
#   DRY_RUN            1 to plan-only         (default: auto)
#   ARMBIAN_APT_URL    Armbian apt base       (default: https://apt.armbian.com)
#   ARMBIAN_SUITE      Armbian apt suite      (default: bookworm)
#   APT_CERALIVE_URL   first-party apt base   (default: https://apt.ceralive.tv)
#   APT_GPG_PUBLIC_B64 first-party GPG keyring (base64; required for a real fetch)
#   APT_CLIENT_CRT_B64 / APT_CLIENT_KEY_B64   first-party mTLS client cert/key (base64)
#
# shellcheck shell=bash

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${HERE}/lib/common.sh" 2>/dev/null || source "${HERE}/common.sh"

# Shared libs (lib/shared/): no private copies of these readers/guards live here.
# shellcheck source=lib/shared/yaml-lib.sh
source "${HERE}/shared/yaml-lib.sh"
# shellcheck source=lib/shared/deb-lib.sh
source "${HERE}/shared/deb-lib.sh"
# shellcheck source=lib/fetch-debs-auth.sh
source "${HERE}/fetch-debs-auth.sh"

# ---------------------------------------------------------------------------
# Configuration (env-overridable; never hardcode versions — pins come from
# versions.yaml for first-party, and from the family manifest for BSP names).
# ---------------------------------------------------------------------------
CHANNEL="${CHANNEL:-stable}"
ARCH="${ARCH:-arm64}"
case "${ARCH}" in
  arm64|amd64) ;;
  x86-64) ARCH="amd64" ;;
  *) die "unsupported Debian package architecture '${ARCH}'; expected arm64|amd64|x86-64" ;;
esac
DEST="${DEST:-./out}"
ARMBIAN_APT_URL="${ARMBIAN_APT_URL:-https://apt.armbian.com}"
ARMBIAN_SUITE="${ARMBIAN_SUITE:-bookworm}"
ARMBIAN_APT_KEYRING="${ARMBIAN_APT_KEYRING:-}"
ARMBIAN_APT_KEY_FINGERPRINT="${ARMBIAN_APT_KEY_FINGERPRINT:-DF00FAF1C577104B50BF1D0093D6889F9F0E78D5}"
FIRST_PARTY_DEB_VERSIONS_FILE="${FIRST_PARTY_DEB_VERSIONS_FILE:-${HERE}/../manifests/first-party-deb-versions.txt}"

# First-party apt source (apt.ceralive.tv). The deb822 source appends
# /dists/${CHANNEL}/ (apt-worker two-axis layout: channel x arch; arch is selected
# by APT::Architecture, never a board axis). Env-overridable; no trailing slash.
APT_CERALIVE_URL="${APT_CERALIVE_URL:-https://apt.ceralive.tv}"

# WARN-ONLY (never die): a non-https first-party apt base is almost always a
# mistake in production, but legitimate local/dev overrides DO use http:// (a LAN
# mirror, a localhost apt proxy). A hard die would break those AND add a new
# failure mode to the sacred fetch path — so we surface the signal loudly and let
# the fetch proceed. The transport-verification contract is still carried by GPG
# (Signed-By) + mTLS below, independent of the URL scheme.
[[ "${APT_CERALIVE_URL}" == https://* ]] \
  || log_warn "APT_CERALIVE_URL is not https:// (${APT_CERALIVE_URL}) — proceeding; transport is unverified (intended only for local/dev overrides)"

# FETCH_JOBS — bounded fetch concurrency. FETCH_JOBS=1 is the strict serial
# baseline; sanitised to a positive integer, default 4.
FETCH_JOBS="${FETCH_JOBS:-4}"
[[ "${FETCH_JOBS}" =~ ^[1-9][0-9]*$ ]] || FETCH_JOBS=4

# The release registry is repo-local so standalone image builds do not depend on
# the surrounding development workspace.
VERSIONS_YAML="${VERSIONS_YAML:-${HERE}/../../versions.yaml}"

# REPOS — first-party device .debs. CASE AND ORDER ARE SACRED: downstream apt,
# mkosi install ordering and the versions.yaml keys all match these exact names.
# ceralive-platform is CLOUD-ONLY and MUST NEVER appear here.
#
# cerastream is the SOLE streaming engine (ceracoder retired 2026-06-11 after the
# boot-parity gate passed on the generic profile — cerastream/docs/notes/
# boot-parity-results.md). RK3588 hardware-gated profiles now track as
# cerastream hardware-validation work; Jetson is deferred and not currently planned.
#
REPOS=("srt" "cerastream" "CeraUI" "srtla-send-rs")

# REPOS integrity guard — belt-and-suspenders on the hardcoded constant above.
assert_repos_integrity() {
  local -a _sacred=("srt" "cerastream" "CeraUI" "srtla-send-rs")
  (( ${#REPOS[@]} == ${#_sacred[@]} )) \
    || die "REPOS integrity: expected exactly ${#_sacred[@]} sacred entries, found ${#REPOS[@]} (${REPOS[*]:-}) — REPOS contents are sacred"
  local i
  for i in "${!_sacred[@]}"; do
    [[ "${REPOS[$i]:-}" == "${_sacred[$i]}" ]] \
      || die "REPOS integrity: entry ${i} is '${REPOS[$i]:-}', expected '${_sacred[$i]}' — REPOS order/case is sacred"
  done
}
assert_repos_integrity

FIRST_PARTY_APT_PKGS=("libsrt1.5-ceralive" "cerastream" "gstreamer1.0-libuvch264src" "ceralive-device" "srtla-send-rs")
# ---------------------------------------------------------------------------
# Dry-run plumbing. run_or_plan executes in normal mode, logs-only in dry-run.
# This is the SOLE bridge between "real fetch" and "offline evidence" — there is
# deliberately no `|| true`; a real command that fails still trips the ERR trap.
# ---------------------------------------------------------------------------
: "${DRY_RUN:=}"

run_or_plan() {
  if [[ -n "${DRY_RUN}" ]]; then
    log_info "DRY-RUN would run: $*"
    return 0
  fi
  log_info "exec: $*"
  "$@"
}

# ---------------------------------------------------------------------------
# Bounded fetch pool. _run_bounded runs <worker> for each arg with at most
# <max> in flight (sliding window — never an unbounded `&` fan-out). Args are
# launched in order, so REPOS/BSP ordering (G3) is the launch order. Each child
# is waited on exactly once; any non-zero child makes the whole run non-zero so
# one failed download fails the entire fetch (aggregate exit).
#
# State the workers need is passed via these script globals (background subshells
# inherit them); each worker downloads into a private .tmp/.fetch-* path under
# the staging dir and atomically renames the finished .deb into place, so an
# interrupted download never leaves a half-written final .deb.
# ---------------------------------------------------------------------------
_BSP_DEBS=""
_PKG_INDEX=""
_APT_OPTS=()
_FIRST_PARTY_DEBS=""
_FIRST_PARTY_INDEX=""
_FIRST_PARTY_BASE_URL=""
_FIRST_PARTY_CURL_AUTH=()

_run_bounded() {
  local max="$1" worker="$2"; shift 2
  (( max >= 1 )) || max=1
  local rc=0 arg pid
  local -a window=()
  for arg in "$@"; do
    "${worker}" "${arg}" &
    window+=("$!")
    if (( ${#window[@]} >= max )); then
      wait "${window[0]}" || rc=1
      window=("${window[@]:1}")
    fi
  done
  for pid in "${window[@]}"; do
    wait "${pid}" || rc=1
  done
  return "${rc}"
}

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

# BSP provenance + advisory kernel drift-guard.
#
# The kernel BSP is fetched NAME-based and FLOATING (Decision D3 — no version pin;
# the Armbian vendor suite supplies whatever concrete build it currently holds).
# That float is intentional but invisible: a silent kernel re-spin can change the
# image with no signal. These helpers make the float OBSERVABLE without pinning it.
#
# HARD CONTRACTS:
#   * ADVISORY ONLY — every path returns 0; a drift NEVER fails the build.
#   * Content hash, not just version — a same-version re-spin is still caught.
#   * The provenance artifact is gitignored build output, deliberately EXCLUDED
#     from the sha256 determinism comparison (a floating BSP would break it).

BSP_BASELINE="${BSP_BASELINE:-${HERE}/../manifests/bsp-baseline.json}"

# _bsp_json_field <file> <field> — read a flat JSON string field (no jq dep; the
# baseline is a small flat object). A null/absent/empty value yields empty output,
# which the drift-guard reads as "unseeded" (first run).
_bsp_json_field() {
  local file="$1" field="$2"
  [[ -f "${file}" ]] || { printf ''; return 0; }
  sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "${file}" | head -n1
}

# bsp_write_json <path> <pkg> <version> <sha256> — emit the flat provenance/baseline
# document (schema_version 1). Used for BOTH the gitignored provenance artifact and
# the committed baseline seed, so the two files share one shape.
bsp_write_json() {
  local out="$1" pkg="$2" version="$3" sha="$4"
  mkdir -p "$(dirname "${out}")"
  cat >"${out}" <<EOF
{
  "schema_version": 1,
  "package": "${pkg}",
  "version": "${version}",
  "sha256": "${sha}"
}
EOF
}

# bsp_drift_check <baseline> <pkg> <version> <sha256> — drift-guard.
# First run (no/unseeded baseline) seeds it and notes that. A match is silent-ok.
# A mismatch prints a "BSP drift" banner to stdout (the user-facing advisory signal)
# plus structured detail on stderr.
#
# Exit policy is opt-in (C6b):
#   * DEFAULT (BSP_DRIFT_STRICT unset/≠1) — WARN-ONLY: drift prints the banner and
#     still returns 0. Drift is NOT fatal by default; the BSP stays floating and
#     this is observability, not a pin. This is the byte-for-byte historical path.
#   * BSP_DRIFT_STRICT=1 — STRICT: a real version/hash mismatch against a SEEDED
#     baseline returns non-zero, failing the build. The seeding run (unseeded/first
#     run) and a clean match are ALWAYS exit 0 regardless of this flag — a fresh
#     baseline can never fail a strict build.
#
# Promotion criterion (why default is still warn): flipping the default to strict
# (blocking) is deferred to a FUTURE change, NOT this one. Two conditions must both
# hold before that flip: (1) the committed baseline v2/manifests/bsp-baseline.json
# is SEEDED with a real known-good version+sha256 (it currently ships UNSEEDED /
# null), and (2) a fleet manifest run confirms every board resolves to that same
# known-good BSP with no outstanding drift. Until both are true, strict-by-default
# would fail green builds on the very first authenticated fetch. Operators/CI that
# want the gate today opt in with BSP_DRIFT_STRICT=1.
bsp_drift_check() {
  local baseline="$1" pkg="$2" version="$3" sha="$4"
  local base_ver base_sha
  base_ver="$(_bsp_json_field "${baseline}" version)"
  base_sha="$(_bsp_json_field "${baseline}" sha256)"

  if [[ ! -f "${baseline}" || -z "${base_ver}" || -z "${base_sha}" ]]; then
    printf 'BSP baseline: no known-good baseline for %s — seeding it (first run, advisory)\n' "${pkg}"
    bsp_write_json "${baseline}" "${pkg}" "${version}" "${sha}"
    log_info "BSP baseline seeded -> ${baseline} (version=${version} sha256=${sha})"
    return 0
  fi

  if [[ "${base_ver}" == "${version}" && "${base_sha}" == "${sha}" ]]; then
    log_info "BSP provenance: ${pkg} matches known-good baseline (version=${version})"
    return 0
  fi

  local strict=0
  [[ "${BSP_DRIFT_STRICT:-}" == "1" ]] && strict=1

  if [[ "${strict}" -eq 1 ]]; then
    printf 'BSP drift: %s differs from the known-good baseline (BSP_DRIFT_STRICT=1 — failing the build)\n' "${pkg}"
  else
    printf 'BSP drift: %s differs from the known-good baseline (advisory — build continues)\n' "${pkg}"
  fi
  log_warn "BSP drift detail — baseline: version=${base_ver} sha256=${base_sha}"
  log_warn "BSP drift detail — current : version=${version} sha256=${sha}"
  if [[ "${base_ver}" == "${version}" ]]; then
    log_warn "BSP drift: SAME version, DIFFERENT content hash — kernel BSP re-spin detected"
  fi

  if [[ "${strict}" -eq 1 ]]; then
    log_warn "BSP drift: strict mode (BSP_DRIFT_STRICT=1) — returning non-zero to fail the build"
    return 1
  fi
  return 0
}

# bsp_capture_provenance <out_dir> <debs_dir> <kernel_pkg> — locate the fetched
# kernel .deb, record its resolved version + content sha256 to <out_dir>/
# bsp-provenance.json, then run the advisory drift-guard. Scope is the kernel BSP
# package ONLY (provenance is intentionally not widened to the rest of the BSP set).
bsp_capture_provenance() {
  local out_dir="$1" debs_dir="$2" kpkg="$3"
  local deb="" f name
  shopt -s nullglob
  for f in "${debs_dir}"/*.deb; do
    name="$(deb_pkg_name "${f}")"
    if [[ "${name}" == "${kpkg}" ]]; then deb="${f}"; break; fi
  done
  shopt -u nullglob

  if [[ -z "${deb}" ]]; then
    log_warn "BSP provenance: kernel package '${kpkg}' .deb not staged in ${debs_dir} — skipping capture"
    return 0
  fi

  local version sha
  version="$(deb_pkg_version "${deb}")"
  sha="$(sha256sum "${deb}" | awk '{print $1}')"
  bsp_write_json "${out_dir}/bsp-provenance.json" "${kpkg}" "${version}" "${sha}"
  log_info "BSP provenance: ${kpkg} version=${version} sha256=${sha} -> ${out_dir}/bsp-provenance.json"

  bsp_drift_check "${BSP_BASELINE}" "${kpkg}" "${version}" "${sha}"
}

# _fetch_bsp_native_one — bounded-pool worker: download ONE BSP .deb into a
# private temp dir, then atomically rename the result into ${_BSP_DEBS}. A killed
# apt-get leaves files only in the throwaway .fetch-* dir, never a partial final.
_fetch_bsp_native_one() {
  local pkg="$1"
  log_info "BSP fetch: ${pkg} (${ARMBIAN_SUITE}/${ARCH})"
  if [[ -n "${DRY_RUN}" ]]; then
    run_or_plan bash -c \
      "cd $(printf '%q' "${_BSP_DEBS}") && apt-get $(printf '%q ' "${_APT_OPTS[@]}")download $(printf '%q' "${pkg}")"
    return 0
  fi
  local tmpd; tmpd="$(mktemp -d "${_BSP_DEBS}/.fetch-XXXXXX")"
  ( cd "${tmpd}" && apt-get "${_APT_OPTS[@]}" download "${pkg}" )
  local f
  shopt -s nullglob
  for f in "${tmpd}"/*.deb; do
    mv -f "${f}" "${_BSP_DEBS}/$(basename "${f}")"
  done
  shopt -u nullglob
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

  run_or_plan apt-get "${apt_opts[@]}" update

  _BSP_DEBS="${debs}"
  _APT_OPTS=("${apt_opts[@]}")
  local jobs="${FETCH_JOBS}"; [[ -n "${DRY_RUN}" ]] && jobs=1
  _run_bounded "${jobs}" _fetch_bsp_native_one "${bsp_pkgs[@]}" \
    || die "BSP fetch failed (native apt path): one or more packages did not download"
}

# _fetch_bsp_curl_one — bounded-pool worker: resolve ONE BSP package name to its
# pool path via the cached Packages index (${_PKG_INDEX}), curl it to a private
# .tmp-* file, then atomically rename into ${_BSP_DEBS}. A killed curl leaves
# only the .tmp-* partial, never a half-written final .deb.
_fetch_bsp_curl_one() {
  local pkg="$1" resolved="" filename="" sha256="" version=""
  if [[ -z "${DRY_RUN}" ]]; then
    resolved="$(auth_lookup_package "${_PKG_INDEX}" "${pkg}" "" "${ARCH}")"
    [[ -n "${resolved}" ]] \
      || die "BSP package '${pkg}' not found in ${ARMBIAN_SUITE}/main/binary-${ARCH} Packages index"
    IFS=$'\t' read -r filename sha256 version <<<"${resolved}"
  fi
  log_info "BSP fetch (curl): ${pkg}"
  if [[ -n "${DRY_RUN}" ]]; then
    run_or_plan curl -fsSL --retry 3 \
      -o "${_BSP_DEBS}/$(basename "${filename:-${pkg}.deb}")" \
      "${ARMBIAN_APT_URL}/${filename:-DRYRUN}"
    return 0
  fi
  local final tmp
  final="${_BSP_DEBS}/$(basename "${filename}")"
  tmp="$(mktemp "${_BSP_DEBS}/.tmp-XXXXXX")"
  curl -fsSL --retry 3 -o "${tmp}" "${ARMBIAN_APT_URL}/${filename}"
  auth_verify_file "${tmp}" "${sha256}" \
    || die "BSP package checksum mismatch for ${pkg}=${version}"
  mv -f "${tmp}" "${final}"
}

# ---------------------------------------------------------------------------
# _fetch_bsp_curl — curl-based fallback for non-Debian hosts (e.g. Arch Linux).
# Downloads the Armbian Packages.gz index, resolves each BSP package name to
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
  local packages_file; packages_file="$(mktemp)"
  local inrelease="${packages_file}.InRelease" expected_sha actual_sha
  run_or_plan curl -fsSL --retry 3 -o "${inrelease}" "${release_base}/InRelease" \
    || die "failed to download Armbian InRelease"
  if [[ -z "${DRY_RUN}" ]]; then
    auth_verify_release_signature "${ARMBIAN_APT_KEYRING}" "${inrelease}" \
      || die "Armbian InRelease signature verification failed"
    expected_sha="$(awk -v path="${packages_rel}" '
      /^SHA256:/{inside=1;next} /^[A-Za-z0-9-]+:/{inside=0}
      inside && $3==path{print $1;exit}
    ' "${inrelease}")"
    [[ -n "${expected_sha}" ]] || die "Armbian InRelease lacks ${packages_rel} SHA256"
  fi
  run_or_plan curl -fsSL --retry 3 -o "${packages_file}.gz" "${packages_url}" \
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
  local jobs="${FETCH_JOBS}"; [[ -n "${DRY_RUN}" ]] && jobs=1
  _run_bounded "${jobs}" _fetch_bsp_curl_one "${bsp_pkgs[@]}" \
    || die "BSP fetch failed (curl path): one or more packages did not download"

  [[ -z "${DRY_RUN}" ]] && rm -f "${packages_file}" "${inrelease}"
  return 0
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
  curl -fsSL --retry 3 "${_FIRST_PARTY_CURL_AUTH[@]}" -o "${tmp}" "${url}"
  actual="$(sha256sum "${tmp}" | awk '{print $1}')"
  [[ "${actual}" == "${sha256}" ]] \
    || die "first-party package checksum mismatch for ${spec}: expected ${sha256}, got ${actual}"
  mv -f "${tmp}" "${final}"
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
  local expected_sha actual_sha

  local -a curl_auth=()
  if [[ -n "${APT_CLIENT_CRT_B64:-}" ]]; then
    curl_auth+=(--cert "${certs_dir}/client.crt" --key "${certs_dir}/client.key")
  fi

  log_info "apt-get not found (non-Debian host) — fetching first-party packages via verified curl from ${repo_base}"
  curl -fsSL --retry 3 "${curl_auth[@]}" -o "${inrelease}" "${repo_base}/InRelease"
  auth_verify_release_signature "${keyring}" "${inrelease}" \
    || die "first-party InRelease signature verification failed for ${repo_base}"

  expected_sha="$(awk '
    /^SHA256:/{ in_sha=1; next }
    /^[A-Za-z0-9-]+:/{ in_sha=0 }
    in_sha && $3 == "Packages.gz" { print $1; exit }
  ' "${inrelease}")"
  [[ -n "${expected_sha}" ]] \
    || die "first-party InRelease does not list Packages.gz SHA256 for ${repo_base}"

  curl -fsSL --retry 3 "${curl_auth[@]}" -o "${packages_gz}" "${repo_base}/Packages.gz"
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
# fetch_bsp — read BSP package NAMES from the resolved family manifest and pull
# each from the Armbian apt pool into $DEST/debs/. Names (not versions) are the
# manifest contract; the Armbian suite supplies the concrete build. Pinning a
# specific BSP version would append "=<ver>" — kept name-based to match the
# manifest + Decision D3 (branch=vendor encoded in the package name itself).
#
# On Debian/Ubuntu hosts with apt-get, uses native path. On other hosts (e.g.
# Arch Linux), delegates to Docker/Podman fallback.
# ---------------------------------------------------------------------------
fetch_bsp() {
  local family="$1" debs="$2"
  [[ -n "${family}" ]] || die "fetch_bsp: --family manifest required for BSP packages"
  [[ -f "${family}" ]] || die "fetch_bsp: family manifest not found: ${family}"

  local fields=(
    kernel_packages
    dtb_packages
    uboot_packages
    firmware_packages
    hw_accel_gstreamer_plugins
    gstreamer_runtime_packages
  )

  local -a bsp_pkgs=()
  local field item
  for field in "${fields[@]}"; do
    while IFS= read -r item; do
      [[ -n "${item}" ]] && bsp_pkgs+=("${item}")
    done < <(read_yaml_list "${field}" "${family}")
  done

  # Board manifests override family-level package arrays via env vars resolved
  # by resolve.py (orchestrate.sh exports them before calling fetch-debs.sh).
  # e.g. UBOOT_PACKAGES=linux-u-boot-rock-5b-plus-vendor from rock-5b-plus.yaml.
  for pkg in ${UBOOT_PACKAGES:-} ${KERNEL_PACKAGES:-} ${DTB_PACKAGES:-} \
             ${FIRMWARE_PACKAGES:-} ${HW_ACCEL_GSTREAMER_PLUGINS:-} \
             ${GSTREAMER_RUNTIME_PACKAGES:-}; do
    [[ -n "${pkg}" ]] && bsp_pkgs+=("${pkg}")
  done
  # Deduplicate while preserving order
  local -a deduped=()
  local seen="|" p
  for p in "${bsp_pkgs[@]}"; do
    [[ "${seen}" == *"|${p}|"* ]] || { deduped+=("${p}"); seen+="${p}|"; }
  done
  bsp_pkgs=("${deduped[@]}")

  if (( ${#bsp_pkgs[@]} == 0 )); then
    die "fetch_bsp: no BSP packages found in ${family} or env (expected kernel/dtb/uboot/firmware names)"
  fi

  log_info "BSP set from $(basename "${family}") (${#bsp_pkgs[@]} pkgs): ${bsp_pkgs[*]}"
  log_info "Armbian source: ${ARMBIAN_APT_URL} suite=${ARMBIAN_SUITE} arch=${ARCH}"

  if [[ -z "${DRY_RUN}" ]]; then
    [[ -s "${ARMBIAN_APT_KEYRING}" ]] \
      || die "ARMBIAN_APT_KEYRING is required for authenticated BSP fetches"
    auth_keyring_has_fingerprint "${ARMBIAN_APT_KEYRING}" "${ARMBIAN_APT_KEY_FINGERPRINT}" \
      || die "Armbian keyring does not contain pinned fingerprint ${ARMBIAN_APT_KEY_FINGERPRINT}"
  fi

  if command -v apt-get >/dev/null 2>&1; then
    _fetch_bsp_native "${debs}" "${bsp_pkgs[@]}"
  else
    _fetch_bsp_curl "${debs}" "${bsp_pkgs[@]}"
  fi

  # Provenance + advisory drift-guard for the floating kernel BSP. The board
  # KERNEL_PACKAGES override (resolve.py) wins over the family field, mirroring
  # the array-REPLACE merge above. Real-fetch only — DRY_RUN stages no .deb.
  local -a kernel_pkgs=()
  if [[ -n "${KERNEL_PACKAGES:-}" ]]; then
    for pkg in ${KERNEL_PACKAGES}; do
      [[ -n "${pkg}" ]] && kernel_pkgs+=("${pkg}")
    done
  else
    while IFS= read -r item; do
      [[ -n "${item}" ]] && kernel_pkgs+=("${item}")
    done < <(read_yaml_list kernel_packages "${family}")
  fi
  if [[ -z "${DRY_RUN}" && ${#kernel_pkgs[@]} -gt 0 ]]; then
    bsp_capture_provenance "$(dirname "${debs}")" "${debs}" "${kernel_pkgs[0]}"
  fi
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
      -o "APT::Sandbox::User=root"
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
    run_or_plan apt-get "${apt_opts[@]}" update

    local tmpd; tmpd="$(mktemp -d "${debs}/.fetch-firstparty-XXXXXX")"
    ( cd "${tmpd}" && apt-get "${apt_opts[@]}" download "${download_specs[@]}" ) \
      || die "first-party fetch failed (apt-get download from ${APT_CERALIVE_URL})"
    local f
    shopt -s nullglob
    for f in "${tmpd}"/*.deb; do
      mv -f "${f}" "${debs}/$(basename "${f}")"
    done
    shopt -u nullglob
    rm -rf "${tmpd}"
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

usage() {
  cat >&2 <<EOF
Usage:
  fetch-debs.sh --family <manifest.yaml> [--dest <dir>]

Env: CHANNEL ARCH DEST DRY_RUN ARMBIAN_APT_URL ARMBIAN_SUITE ARMBIAN_APT_KEYRING
     APT_CERALIVE_URL APT_GPG_PUBLIC_B64 APT_CLIENT_CRT_B64 APT_CLIENT_KEY_B64
EOF
}

main() {
  local family=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --family) family="${2:-}"; shift 2 ;;
      --dest)   DEST="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) usage; die "unknown argument: $1" ;;
    esac
  done

  # Auto-enable dry-run offline: without the apt.ceralive.tv GPG keyring there is
  # no credential to do a GPG-verified first-party fetch, so plan only.
  if [[ -z "${DRY_RUN}" && -z "${APT_GPG_PUBLIC_B64:-}" ]]; then
    DRY_RUN=1
    log_warn "no apt.ceralive.tv GPG key (APT_GPG_PUBLIC_B64) in env — auto dry-run (plan only, downloads nothing)"
  fi

  [[ -n "${family}" ]] || { usage; die "--family <manifest.yaml> is required"; }

  log_info "=== fetch-debs (mkosi staging) ==="
  log_info "channel=${CHANNEL} arch=${ARCH} dest=${DEST} dry_run=${DRY_RUN:-0}"

  local debs="${DEST}/debs"
  run_or_plan mkdir -p "${debs}"

  fetch_bsp "${family}" "${debs}"
  fetch_first_party "${debs}"

  log_success "staging complete -> ${debs} (mkosi runtime/assembly layer consumes this)"
}

# Only run main when executed directly; sourcing (tests) gets the functions only.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
