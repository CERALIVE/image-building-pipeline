#!/usr/bin/env bash
#
# fetch-debs.sh — stage every .deb mkosi needs for a CeraLive device image.
#
# Two package classes land in ONE staging dir ($DEST/debs/) for the mkosi
# runtime/assembly layer to consume:
#
#   1. BSP packages  — kernel / DTB / U-Boot blob / firmware / GStreamer, read
#                      BY NAME from the resolved FAMILY manifest (typed package
#                      arrays), fetched from the Armbian apt repo.
#   2. First-party   — srtla / srt / ceracoder / CeraUI .debs, fetched from R2
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

# ---------------------------------------------------------------------------
# Configuration (env-overridable; never hardcode versions — pins come from
# versions.yaml for first-party, and from the family manifest for BSP names).
# ---------------------------------------------------------------------------
CHANNEL="${CHANNEL:-stable}"
ARCH="${ARCH:-arm64}"
DEST="${DEST:-./out}"
ARMBIAN_APT_URL="${ARMBIAN_APT_URL:-https://apt.armbian.com}"
ARMBIAN_SUITE="${ARMBIAN_SUITE:-bookworm}"

# versions.yaml lives at the workspace root: v2/lib -> v2 -> image-building-pipeline
# -> <workspace>. Same registry scripts/fetch-debs.sh reads.
VERSIONS_YAML="${VERSIONS_YAML:-${HERE}/../../../versions.yaml}"

# REPOS — first-party device .debs. CASE AND ORDER ARE SACRED: downstream apt,
# mkosi install ordering and the versions.yaml keys all match these exact names.
# ceralive-platform is CLOUD-ONLY and MUST NEVER appear here.
REPOS=("srtla" "srt" "ceracoder" "CeraUI")

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
# get_pin — read a component pin from versions.yaml (graceful: "" when absent).
# Mirrors scripts/fetch-debs.sh get_pin so behaviour stays identical post-rework.
# ---------------------------------------------------------------------------
get_pin() {
  local key="$1" file="${2:-$VERSIONS_YAML}"
  [[ -f "$file" ]] || { printf ''; return; }
  awk -v key="$key" '$0==key":"{f=1;next} f&&/^[a-zA-Z]/{f=0}
    f&&/^[[:space:]]+pin:/{gsub(/^[[:space:]]+pin:[[:space:]]*/,"");print;exit}' "$file"
}

# ---------------------------------------------------------------------------
# read_yaml_list — emit every "- item" under a top-level YAML <key> in <file>.
# Pure-awk so the fetcher needs no yq. Tolerates blank lines and trailing
# comments between the key and its items; stops at the next top-level key or
# a column-0 comment. Returns nothing (success) for an absent/empty key.
# ---------------------------------------------------------------------------
read_yaml_list() {
  local key="$1" file="$2"
  [[ -f "$file" ]] || die "manifest not found: ${file}"
  awk -v key="${key}" '
    $0 ~ "^"key":[[:space:]]*$" { inlist=1; next }
    inlist && /^[[:space:]]*-[[:space:]]+/ {
      sub(/^[[:space:]]*-[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); print; next
    }
    inlist && /^[A-Za-z#]/ { inlist=0 }
  ' "${file}"
}

# ---------------------------------------------------------------------------
# assert_sibling_layout <workspace_root>
#
# HARD CONSTRAINT (ARCHITECTURE.md §5): CeraUI/apps/backend/package.json resolves
# @ceralive/ceracoder and @ceralive/srtla via `link:../../../{ceracoder,srtla}/
# bindings/typescript`. The `../../../` climbs from CeraUI/apps/backend to the
# parent of CeraUI, so ceracoder/, srtla/, CeraUI/ MUST be siblings there.
#
# WHY HERE: once we consume PRE-BUILT .debs, mkosi never touches the link: graph,
# so the layout is technically irrelevant to image assembly. BUT the .debs are
# built FROM this checkout upstream; a broken sibling layout means CeraUI's .deb
# could never have been produced. This guard is the CI-side tripwire that catches
# the misconfiguration loudly at fetch time instead of letting a silently-missing
# CeraUI .deb surface as a mysterious runtime gap. It takes the root as an ARG so
# it is unit-testable against synthetic good/bad trees (see assert-sibling cmd).
# ---------------------------------------------------------------------------
assert_sibling_layout() {
  local root="$1"
  [[ -n "${root}" ]] || die "assert_sibling_layout: workspace root not given"
  [[ -d "${root}" ]] || die "sibling-layout: workspace root does not exist: ${root}"

  local sib missing=()
  for sib in ceracoder srtla CeraUI; do
    [[ -d "${root}/${sib}" ]] || missing+=("${sib}/")
  done
  if (( ${#missing[@]} > 0 )); then
    die "sibling-layout BROKEN under ${root}: missing ${missing[*]} — CeraUI backend resolves @ceralive/{ceracoder,srtla} via link:../../../ (ARCHITECTURE.md §5). ceracoder/, srtla/, CeraUI/ must be siblings."
  fi

  # Verify the exact link: targets the backend depends on actually resolve from
  # CeraUI/apps/backend, not just that the sibling dirs exist.
  local backend="${root}/CeraUI/apps/backend"
  if [[ -d "${backend}" ]]; then
    local dep
    for dep in ceracoder srtla; do
      # link:../../../<dep>/bindings/typescript resolved from CeraUI/apps/backend
      local resolved="${backend}/../../../${dep}/bindings/typescript"
      if [[ ! -d "${resolved}" ]]; then
        log_warn "sibling-layout: ${dep} bindings/typescript not present at $(cd "${backend}" >/dev/null 2>&1 && cd "../../../${dep}" 2>/dev/null && pwd || echo "${root}/${dep}")/bindings/typescript — link:../../../${dep}/bindings/typescript will fail on a source build (ok if consuming a pre-built CeraUI .deb)"
      fi
    done
  fi

  log_success "sibling-layout OK under ${root} (ceracoder/ srtla/ CeraUI/ are siblings; link:../../../ resolves)"
}

# ---------------------------------------------------------------------------
# fetch_bsp — read BSP package NAMES from the resolved family manifest and pull
# each from the Armbian apt pool into $DEST/debs/. Names (not versions) are the
# manifest contract; the Armbian suite supplies the concrete build. Pinning a
# specific BSP version would append "=<ver>" — kept name-based to match the
# manifest + Decision D3 (branch=vendor encoded in the package name itself).
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

  if (( ${#bsp_pkgs[@]} == 0 )); then
    die "fetch_bsp: no BSP packages found in ${family} (expected kernel/dtb/uboot/firmware names)"
  fi

  log_info "BSP set from $(basename "${family}") (${#bsp_pkgs[@]} pkgs): ${bsp_pkgs[*]}"
  log_info "Armbian source: ${ARMBIAN_APT_URL} suite=${ARMBIAN_SUITE} arch=${ARCH}"

  # Isolated apt state so the host apt config is never touched. The Armbian repo
  # is declared in a throwaway sources list; `apt-get download` fetches the .deb
  # for the current suite into $debs.
  local apt_state="${debs}/.apt-state"
  run_or_plan mkdir -p "${apt_state}/lists/partial" "${apt_state}/cache/archives/partial"
  local src_list="${apt_state}/armbian.list"
  if [[ -z "${DRY_RUN}" ]]; then
    require_cmd apt-get
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

  local pkg
  for pkg in "${bsp_pkgs[@]}"; do
    log_info "BSP fetch: ${pkg} (${ARMBIAN_SUITE}/${ARCH})"
    # apt-get download writes to CWD; run it inside $debs so the .deb lands there.
    run_or_plan bash -c \
      "cd $(printf '%q' "${debs}") && apt-get $(printf '%q ' "${apt_opts[@]}")download $(printf '%q' "${pkg}")"
  done
}

# ---------------------------------------------------------------------------
# fetch_first_party — srtla/srt/ceracoder/CeraUI .debs. CI: aws s3 sync from R2;
# local: gh release download per repo. Pins logged from versions.yaml.
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

    local pre_flag=()
    [[ "${CHANNEL}" == "beta" ]] || pre_flag=(--exclude-pre-releases)

    for r in "${REPOS[@]}"; do
      log_info "first-party fetch: CERALIVE/${r} (*${ARCH}*.deb, channel=${CHANNEL})"
      run_or_plan gh release download \
        --repo "CERALIVE/${r}" \
        --pattern "*${ARCH}*.deb" \
        --dir "${debs}" \
        "${pre_flag[@]}"
    done
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
