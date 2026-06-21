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
#   2. First-party   — cerastream / ceralive-device (CeraUI) / srtla /
#                      srtla-send-rs .debs, PULLED FROM apt.ceralive.tv via a
#                      GPG-verified, mTLS-authenticated apt source (`apt-get
#                      download`). System libsrt (`libsrt1.5-openssl`) is installed
#                      by the runtime OS layer (shared.list); gstlibuvch264src
#                      (`gstreamer1.0-libuvch264src`) and the libgstreamer* plugins
#                      are NOT staged here — they are resolved as transitive
#                      cerastream Depends by the app layer's own `apt-get install`
#                      from apt.ceralive.tv + bookworm main at install time
#                      (mkosi.images/app/mkosi.postinst.chroot).
#
# This REPLACES the Armbian-chroot fetch of scripts/fetch-debs.sh. mkosi installs
# the staged .debs into the rootfs tree directly; there is no Armbian build here.
#
# ── Modes ────────────────────────────────────────────────────────────────────
#   Real fetch : BSP from the Armbian apt pool (apt-get on Debian hosts, curl
#                fallback elsewhere); first-party from apt.ceralive.tv via an
#                isolated-state `apt-get update` + `apt-get download` (GPG keyring
#                + mTLS client cert injected from the environment).
#   Dry-run    : DRY_RUN=1 (auto when APT_GPG_PUBLIC_B64 is unset — no credential
#                to do a GPG-verified first-party fetch with)
#                -> log the EXACT command(s) + source that WOULD run; download
#                   nothing. Used for offline evidence and CI plan inspection. NOT
#                   `|| true`: an explicit, logged branch, never silent failure.
#
# ── Usage ────────────────────────────────────────────────────────────────────
#   fetch-debs.sh --family <manifest.yaml> [--dest <dir>]
#   fetch-debs.sh assert-sibling <workspace_root>     # guard self-test hook
#
# ── Env ──────────────────────────────────────────────────────────────────────
#   CHANNEL            stable|beta            (default: stable)
#   ARCH               arm64|amd64            (default: arm64)
#   DEST               staging root           (default: ./out)  -> debs in $DEST/debs/
#   DRY_RUN            1 to plan-only         (default: auto)
#   CERALIVE_WORKSPACE override sibling-root  (default: resolved repo parent)
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
# shellcheck source=lib/shared/sibling-layout-lib.sh
source "${HERE}/shared/sibling-layout-lib.sh"

# ---------------------------------------------------------------------------
# Configuration (env-overridable; never hardcode versions — pins come from
# versions.yaml for first-party, and from the family manifest for BSP names).
# ---------------------------------------------------------------------------
CHANNEL="${CHANNEL:-stable}"
ARCH="${ARCH:-arm64}"
DEST="${DEST:-./out}"
ARMBIAN_APT_URL="${ARMBIAN_APT_URL:-https://apt.armbian.com}"
ARMBIAN_SUITE="${ARMBIAN_SUITE:-bookworm}"

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

# versions.yaml lives at the workspace root: v2/lib -> v2 -> image-building-pipeline
# -> <workspace>. Same registry scripts/fetch-debs.sh reads.
VERSIONS_YAML="${VERSIONS_YAML:-${HERE}/../../../versions.yaml}"

# REPOS — first-party device .debs. CASE AND ORDER ARE SACRED: downstream apt,
# mkosi install ordering and the versions.yaml keys all match these exact names.
# ceralive-platform is CLOUD-ONLY and MUST NEVER appear here.
#
# cerastream is the SOLE streaming engine (ceracoder retired 2026-06-11 after the
# boot-parity gate passed on the generic profile — cerastream/docs/notes/
# boot-parity-results.md). The hardware-gated profiles (Jetson/RK3588) now track
# as cerastream hardware-validation work, not as a retention condition.
#
# srtla-send-rs is the Rust sender fork (v1.0.0+) added at cutover (Task 20).
# srtla .deb provides receiver-only after cutover; srtla-send-rs provides the sender.
# Conflict declaration: srtla-send-rs Conflicts/Replaces srtla (<< 2026.6.2)
# (SRTLA_CUTOVER_VERSION). Any pre-cutover srtla (<< 2026.6.2, which still bundled the
# C sender) is correctly blocked from coinstall; srtla v2026.6.2 — the first
# receiver-only release — is NOT << 2026.6.2, so it coinstalls with the Rust sender.
REPOS=("srtla" "cerastream" "CeraUI" "srtla-send-rs")

# REPOS integrity guard — belt-and-suspenders on the hardcoded constant above.
# `die` is SAFE here: this asserts a compile-time constant, so it can ONLY fire on
# a wrong EDIT to the REPOS line (an added/removed/reordered/recased entry), NEVER
# on a valid run. Downstream apt install ordering, the FIRST_PARTY_APT_PKGS mapping
# and the versions.yaml keys all key off these exact four names in this exact order.
assert_repos_integrity() {
  local -a _sacred=("srtla" "cerastream" "CeraUI" "srtla-send-rs")
  (( ${#REPOS[@]} == ${#_sacred[@]} )) \
    || die "REPOS integrity: expected exactly ${#_sacred[@]} sacred entries, found ${#REPOS[@]} (${REPOS[*]:-}) — REPOS contents are sacred"
  local i
  for i in "${!_sacred[@]}"; do
    [[ "${REPOS[$i]:-}" == "${_sacred[$i]}" ]] \
      || die "REPOS integrity: entry ${i} is '${REPOS[$i]:-}', expected '${_sacred[$i]}' — REPOS order/case is sacred"
  done
}
assert_repos_integrity

# FIRST_PARTY_APT_PKGS — the Debian Package: NAMES pulled from apt.ceralive.tv,
# a deliberate mapping off REPOS (the directory/pin names above), NOT a copy:
#   srtla->srtla  cerastream->cerastream  CeraUI->ceralive-device
#   srtla-send-rs->srtla-send-rs
# `srt` is gone from this set AND from REPOS: it is a build-time vendored libsrt
# source that produces no .deb. Runtime libsrt is the SYSTEM `libsrt1.5-openssl`,
# installed by the runtime OS layer (manifests/packages/shared.list), not here.
# gstlibuvch264src (`gstreamer1.0-libuvch264src`) and the libgstreamer* plugins are
# resolved as transitive cerastream Depends by the app layer's own `apt-get install`
# from apt.ceralive.tv + bookworm main, so they are not download targets here either.
FIRST_PARTY_APT_PKGS=("cerastream" "ceralive-device" "srtla" "srtla-send-rs")

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

# assert_sibling_layout (lib/shared/sibling-layout-lib.sh) is the fetch-time
# tripwire that srtla/ and CeraUI/ are siblings — see that lib and
# ARCHITECTURE.md §5 for why a broken layout means CeraUI's .deb is unbuildable.

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

# bsp_drift_check <baseline> <pkg> <version> <sha256> — advisory drift-guard.
# First run (no/unseeded baseline) seeds it and notes that. A match is silent-ok.
# A mismatch prints a "BSP drift" banner to stdout (the user-facing advisory signal)
# plus structured detail on stderr. ALWAYS returns 0 — drift is never fatal.
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

  printf 'BSP drift: %s differs from the known-good baseline (advisory — build continues)\n' "${pkg}"
  log_warn "BSP drift detail — baseline: version=${base_ver} sha256=${base_sha}"
  log_warn "BSP drift detail — current : version=${version} sha256=${sha}"
  if [[ "${base_ver}" == "${version}" ]]; then
    log_warn "BSP drift: SAME version, DIFFERENT content hash — kernel BSP re-spin detected"
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
    printf 'deb [trusted=yes arch=%s] %s %s main\n' \
      "${ARCH}" "${ARMBIAN_APT_URL}" "${ARMBIAN_SUITE}" >"${src_list}"
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
  local pkg="$1" filename=""
  if [[ -z "${DRY_RUN}" ]]; then
    filename="$(awk -v want="${pkg}" '
      /^Package: /{ p=($2==want) }
      p && /^Filename: /{ print $2; exit }
    ' "${_PKG_INDEX}")"
    [[ -n "${filename}" ]] \
      || die "BSP package '${pkg}' not found in ${ARMBIAN_SUITE}/main/binary-${ARCH} Packages index"
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

  local packages_url="${ARMBIAN_APT_URL}/dists/${ARMBIAN_SUITE}/main/binary-${ARCH}/Packages.gz"
  local packages_file; packages_file="$(mktemp)"
  run_or_plan curl -fsSL --retry 3 -o "${packages_file}.gz" "${packages_url}" \
    || die "failed to download Armbian Packages index: ${packages_url}"

  if [[ -z "${DRY_RUN}" ]]; then
    gzip -df "${packages_file}.gz" || die "failed to decompress Armbian Packages.gz"
  else
    log_info "DRY-RUN: would decompress ${packages_file}.gz"
  fi

  _BSP_DEBS="${debs}"
  _PKG_INDEX="${packages_file}"
  local jobs="${FETCH_JOBS}"; [[ -n "${DRY_RUN}" ]] && jobs=1
  _run_bounded "${jobs}" _fetch_bsp_curl_one "${bsp_pkgs[@]}" \
    || die "BSP fetch failed (curl path): one or more packages did not download"

  [[ -z "${DRY_RUN}" ]] && rm -f "${packages_file}"
  return 0
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
  local seen="" p
  for p in "${bsp_pkgs[@]}"; do
    [[ "${seen}" == *"|${p}|"* ]] || { deduped+=("${p}"); seen+="${p}|"; }
  done
  bsp_pkgs=("${deduped[@]}")

  if (( ${#bsp_pkgs[@]} == 0 )); then
    die "fetch_bsp: no BSP packages found in ${family} or env (expected kernel/dtb/uboot/firmware names)"
  fi

  log_info "BSP set from $(basename "${family}") (${#bsp_pkgs[@]} pkgs): ${bsp_pkgs[*]}"
  log_info "Armbian source: ${ARMBIAN_APT_URL} suite=${ARMBIAN_SUITE} arch=${ARCH}"

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
# Exactly the four TOP-LEVEL packages in FIRST_PARTY_APT_PKGS are `apt-get
# download`ed into $DEST/debs/; their first-party dependency `srt` (the libsrt
# fork) is dependency-resolved by the app layer at install time, not staged here.
# REPOS still drives the versions.yaml pin log below — it is unchanged.
#
# Secrets arrive ONLY through the environment, base64-encoded, exactly as
# v2/mkosi/customize/apt-ceralive-repo.sh consumes them (APT_GPG_PUBLIC_B64 +
# APT_CLIENT_CRT_B64/APT_CLIENT_KEY_B64). They are NEVER hardcoded, NEVER logged,
# NEVER committed. A half-supplied mTLS pair is fatal (same loud contract).
#
# Isolated apt state (mirrors _fetch_bsp_native): the host apt config is never
# touched. The .debs land in a throwaway temp dir and are atomically renamed into
# place, so an interrupted apt-get never leaves a half-written final .deb. One
# apt-get transaction fetches all four, so the per-package bounded pool used by the
# BSP path does not apply here.
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
    require_cmd apt-get
    require_cmd base64
    printf '%s' "${APT_GPG_PUBLIC_B64}" | base64 -d >"${keyring}"
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
      -o "Acquire::https::apt.ceralive.tv::SslCert=${certs_dir}/client.crt"
      -o "Acquire::https::apt.ceralive.tv::SslKey=${certs_dir}/client.key"
    )
  fi

  if [[ -n "${DRY_RUN}" ]]; then
    log_info "DRY-RUN would run: apt-get $(printf '%q ' "${apt_opts[@]}")update"
    log_info "DRY-RUN would run: (cd ${debs} && apt-get $(printf '%q ' "${apt_opts[@]}")download ${FIRST_PARTY_APT_PKGS[*]})  # from ${APT_CERALIVE_URL}/dists/${CHANNEL}/"
    return 0
  fi

  run_or_plan apt-get "${apt_opts[@]}" update

  local tmpd; tmpd="$(mktemp -d "${debs}/.fetch-firstparty-XXXXXX")"
  ( cd "${tmpd}" && apt-get "${apt_opts[@]}" download "${FIRST_PARTY_APT_PKGS[@]}" ) \
    || die "first-party fetch failed (apt-get download from ${APT_CERALIVE_URL})"
  local f staged=0
  shopt -s nullglob
  for f in "${tmpd}"/*.deb; do
    mv -f "${f}" "${debs}/$(basename "${f}")"
    staged=$((staged + 1))
  done
  shopt -u nullglob
  rm -rf "${tmpd}"
  (( staged > 0 )) \
    || die "first-party fetch staged 0 .debs from ${APT_CERALIVE_URL} (expected ${#FIRST_PARTY_APT_PKGS[@]})"
  log_success "first-party: staged ${staged} .deb(s) from ${APT_CERALIVE_URL}/dists/${CHANNEL}/binary-${ARCH}/"
}

usage() {
  cat >&2 <<EOF
Usage:
  fetch-debs.sh --family <manifest.yaml> [--dest <dir>]
  fetch-debs.sh assert-sibling <workspace_root>

Env: CHANNEL ARCH DEST DRY_RUN CERALIVE_WORKSPACE ARMBIAN_APT_URL ARMBIAN_SUITE
     APT_CERALIVE_URL APT_GPG_PUBLIC_B64 APT_CLIENT_CRT_B64 APT_CLIENT_KEY_B64
EOF
}

main() {
  # Hidden subcommand: guard self-test hook (used by task-14-sibling evidence).
  if [[ "${1:-}" == "assert-sibling" ]]; then
    assert_sibling_layout "${2:-}"
    exit 0
  fi

  local family=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --family) family="${2:-}"; shift 2 ;;
      --dest)   DEST="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) usage; die "unknown argument: $1" ;;
    esac
  done

  # Resolve the workspace root that must hold the sibling checkouts. Default:
  # parent of the image-building-pipeline repo (v2/lib -> v2 -> repo -> parent).
  local workspace="${CERALIVE_WORKSPACE:-$(cd "${HERE}/../../.." && pwd)}"

  # Auto-enable dry-run offline: without the apt.ceralive.tv GPG keyring there is
  # no credential to do a GPG-verified first-party fetch, so plan only.
  if [[ -z "${DRY_RUN}" && -z "${APT_GPG_PUBLIC_B64:-}" ]]; then
    DRY_RUN=1
    log_warn "no apt.ceralive.tv GPG key (APT_GPG_PUBLIC_B64) in env — auto dry-run (plan only, downloads nothing)"
  fi

  [[ -n "${family}" ]] || { usage; die "--family <manifest.yaml> is required"; }

  log_info "=== fetch-debs (mkosi staging) ==="
  log_info "channel=${CHANNEL} arch=${ARCH} dest=${DEST} dry_run=${DRY_RUN:-0}"

  # GUARD FIRST: fail before any download if the sibling layout is broken.
  # NOTE (Task 14): first-party .debs now come PRE-BUILT from apt.ceralive.tv, so
  # the IMAGE build no longer needs srtla/ + CeraUI/ sibling checkouts. The guard is
  # kept CONSERVATIVELY as an upstream-build sanity tripwire — those .debs are
  # produced FROM these checkouts upstream, and a broken layout means a CeraUI/srtla
  # .deb could never have been published. TODO: demote to a soft warning once the
  # first-party CI publish is fully decoupled from this workspace.
  assert_sibling_layout "${workspace}"

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
