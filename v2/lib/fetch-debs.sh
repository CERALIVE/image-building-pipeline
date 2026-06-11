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
#   2. First-party   — srtla / srt / cerastream / CeraUI .debs, fetched from R2
#                      (CI mode) or `gh release download` (local mode).
#
# This REPLACES the Armbian-chroot fetch of scripts/fetch-debs.sh. mkosi installs
# the staged .debs into the rootfs tree directly; there is no Armbian build here.
#
# ── Modes ────────────────────────────────────────────────────────────────────
#   CI mode    : R2_ACCESS_KEY_ID set   -> `aws s3 sync s3://$R2_BUCKET/dists/...`
#   Local mode : no R2 creds            -> `gh release download --repo CERALIVE/<r>`
#   Dry-run    : DRY_RUN=1 (or missing tools/creds with FETCH_ALLOW_DRYRUN=1)
#                -> log the EXACT command that WOULD run; download nothing. Used
#                   for offline evidence and CI plan inspection. NOT `|| true`:
#                   it is an explicit, logged branch, never silent failure.
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
#   R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY / R2_BUCKET / R2_ENDPOINT  (CI mode)
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
REPOS=("srtla" "srt" "cerastream" "CeraUI")

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
_FP_DEBS=""
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
}

# _fetch_first_party_one — bounded-pool worker: download ONE repo's .deb(s) into
# a private temp dir, then atomically rename into ${_FP_DEBS}. A repo with no
# matching release is a warning, not a failure (unchanged semantics). A killed
# gh leaves files only in the throwaway .fetch-* dir, never a partial final.
_fetch_first_party_one() {
  local r="$1"
  log_info "first-party fetch: CERALIVE/${r} (*${ARCH}*.deb, channel=${CHANNEL})"
  if [[ -n "${DRY_RUN}" ]]; then
    log_info "DRY-RUN would run: gh release download --repo CERALIVE/${r} --pattern *${ARCH}*.deb --dir ${_FP_DEBS} --clobber"
    return 0
  fi
  local tmpd; tmpd="$(mktemp -d "${_FP_DEBS}/.fetch-XXXXXX")"
  if gh release download \
       --repo "CERALIVE/${r}" \
       --pattern "*${ARCH}*.deb" \
       --dir "${tmpd}" \
       --clobber 2>&1; then
    local f
    shopt -s nullglob
    for f in "${tmpd}"/*.deb; do
      mv -f "${f}" "${_FP_DEBS}/$(basename "${f}")"
    done
    shopt -u nullglob
  else
    log_warn "first-party: no ${ARCH} .deb release for CERALIVE/${r} (repo has no release or no matching asset) — mkosi app layer will install nothing for this component"
  fi
  rm -rf "${tmpd}"
}

# ---------------------------------------------------------------------------
# fetch_first_party — srtla/srt/cerastream/CeraUI .debs. CI: aws s3 sync from R2;
# local: gh release download per repo (through the bounded fetch pool, launched
# in REPOS order). Pins logged from versions.yaml.
# ---------------------------------------------------------------------------
fetch_first_party() {
  local debs="$1"
  local r

  log_info "first-party pins (versions.yaml):"
  for r in "${REPOS[@]}"; do
    log_info "  ${r} = $(get_pin "${r}" || true)"
  done

  if [[ -n "${R2_ACCESS_KEY_ID:-}" ]]; then
    log_info "CI mode: R2 -> aws s3 sync"
    [[ -n "${R2_BUCKET:-}" ]]   || die "CI mode: R2_BUCKET unset"
    [[ -n "${R2_ENDPOINT:-}" ]] || die "CI mode: R2_ENDPOINT unset"
    [[ -n "${DRY_RUN}" ]] || require_cmd aws

    run_or_plan aws configure set aws_access_key_id "${R2_ACCESS_KEY_ID}"
    run_or_plan aws configure set aws_secret_access_key "${R2_SECRET_ACCESS_KEY:-}"
    run_or_plan aws s3 sync \
      "s3://${R2_BUCKET}/dists/${CHANNEL}/binary-${ARCH}/" \
      "${debs}/" \
      --endpoint-url "${R2_ENDPOINT}" \
      --exclude "*" \
      --include "*.deb"
  else
    log_info "local mode: GitHub releases -> gh release download"
    [[ -n "${DRY_RUN}" ]] || require_cmd gh

    _FP_DEBS="${debs}"
    local jobs="${FETCH_JOBS}"; [[ -n "${DRY_RUN}" ]] && jobs=1
    _run_bounded "${jobs}" _fetch_first_party_one "${REPOS[@]}" \
      || die "first-party fetch failed (gh path)"
  fi
}

usage() {
  cat >&2 <<EOF
Usage:
  fetch-debs.sh --family <manifest.yaml> [--dest <dir>]
  fetch-debs.sh assert-sibling <workspace_root>

Env: CHANNEL ARCH DEST DRY_RUN CERALIVE_WORKSPACE ARMBIAN_APT_URL ARMBIAN_SUITE
     R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET R2_ENDPOINT
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

  # Auto-enable dry-run offline: no R2 creds AND no gh => nothing to fetch with.
  if [[ -z "${DRY_RUN}" && -z "${R2_ACCESS_KEY_ID:-}" ]] && ! command -v gh >/dev/null 2>&1; then
    DRY_RUN=1
    log_warn "no R2 creds and no gh CLI — auto dry-run (plan only, downloads nothing)"
  fi

  [[ -n "${family}" ]] || { usage; die "--family <manifest.yaml> is required"; }

  log_info "=== fetch-debs (mkosi staging) ==="
  log_info "channel=${CHANNEL} arch=${ARCH} dest=${DEST} dry_run=${DRY_RUN:-0}"

  # GUARD FIRST: fail before any download if the sibling layout is broken.
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
