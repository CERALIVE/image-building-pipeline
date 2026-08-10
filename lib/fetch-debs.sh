#!/usr/bin/env bash
#
# fetch-debs.sh — stage every .deb mkosi needs for a CeraLive device image.
#
# Two package classes land in ONE staging dir ($DEST/debs/) for the mkosi
# runtime/assembly layer to consume:
#
#   1. BSP packages  — kernel / DTB / U-Boot blob / firmware / GStreamer, named
#                      by the resolved FAMILY manifest and exact-versioned by the
#                      BSP package registry, fetched from the Armbian apt repo. On Debian/Ubuntu
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
#   BSP_DEB_VERSIONS_FILE exact BSP package pins (default: manifests registry)
#   APT_CERALIVE_URL   first-party apt base   (default: https://apt.ceralive.tv)
#   APT_GPG_PUBLIC_B64 first-party GPG keyring (base64; required for a real fetch)
#   APT_CLIENT_CRT_B64 / APT_CLIENT_KEY_B64   first-party mTLS client cert/key (base64)
#   CERALIVE_DEBCACHE  0 disables the verified .deb download cache (default: on)
#   CERALIVE_DEBCACHE_MAX_BYTES  cache ceiling, LRU-evicted   (default: 4 GiB)
#   CERALIVE_DEBCACHE_DIR        cache location (default: ../mkosi/.staging/.debcache)
#
# shellcheck shell=bash

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${HERE}/common.sh"

# Shared libs (lib/shared/): no private copies of these readers/guards live here.
# shellcheck source=lib/shared/yaml-lib.sh
source "${HERE}/shared/yaml-lib.sh"
# shellcheck source=lib/shared/deb-lib.sh
source "${HERE}/shared/deb-lib.sh"
# shellcheck source=lib/shared/versions-lib.sh
source "${HERE}/shared/versions-lib.sh"
# shellcheck source=lib/fetch-debs-auth.sh
source "${HERE}/fetch-debs-auth.sh"

# Function-family modules (lib/fetch/). This file is the thin entry point: it
# keeps the sacred REPOS / FIRST_PARTY_APT_PKGS constants, the env-overridable
# configuration every module reads, and the CLI — nothing else.
# shellcheck source=fetch/retry.sh
source "${HERE}/fetch/retry.sh"
# shellcheck source=fetch/debcache.sh
source "${HERE}/fetch/debcache.sh"
# shellcheck source=fetch/pool.sh
source "${HERE}/fetch/pool.sh"
# shellcheck source=fetch/apt-lib.sh
source "${HERE}/fetch/apt-lib.sh"
# shellcheck source=fetch/index.sh
source "${HERE}/fetch/index.sh"
# shellcheck source=fetch/verify.sh
source "${HERE}/fetch/verify.sh"
# shellcheck source=fetch/bsp.sh
source "${HERE}/fetch/bsp.sh"
# shellcheck source=fetch/userspace.sh
source "${HERE}/fetch/userspace.sh"
# shellcheck source=fetch/firstparty.sh
source "${HERE}/fetch/firstparty.sh"

# ---------------------------------------------------------------------------
# Configuration (env-overridable; package names come from manifests and exact
# Debian versions come from the repo-local package registries).
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
ARMBIAN_APT_KEY_FINGERPRINTS=(
  "DF00FAF1C577104B50BF1D0093D6889F9F0E78D5"
  "8CFA83D13EB2181EEF5843E41EB30FAF236099FE"
)
BSP_DEB_VERSIONS_FILE="${BSP_DEB_VERSIONS_FILE:-${HERE}/../manifests/armbian-bsp-deb-versions.txt}"
FIRST_PARTY_DEB_VERSIONS_FILE="${FIRST_PARTY_DEB_VERSIONS_FILE:-${HERE}/../manifests/first-party-deb-versions.txt}"
# RK3588 HW-accel userspace (Mali blob, MPP, RGA, gst-rockchip, multimedia-config)
# is NOT in the Armbian pool; it is pinned to exact upstream release-asset URLs and
# verified by SHA-256. package<TAB-or-space>filename<...>sha256<...>url per line.
RK3588_USERSPACE_DEB_VERSIONS_FILE="${RK3588_USERSPACE_DEB_VERSIONS_FILE:-${HERE}/../manifests/rk3588-userspace-deb-versions.txt}"

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
VERSIONS_YAML="${VERSIONS_YAML:-${HERE}/../versions.yaml}"

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

# The device first-party set: the CeraLive runtime .debs (libsrt/cerastream/
# CeraUI/srtla-send) + the capture plugin, PLUS the ModemManager 1.24 closure —
# the 9-package modem-stack set forked and published by modem-stack v0.2.0 on
# apt.ceralive.tv. The closure is self-contained: modemmanager depends on
# libmm-glib0, and the libmbim/libqmi/libqrtr packages provide the QMI/MBIM
# transport its glib libs bind to — all nine carry the ~ceralive0.2.0 fork suffix.
# They are staged like every other first-party .deb (exact pins in
# first-party-deb-versions.txt) and installed by the app layer (RUNTIME_APP_PKGS).
# External deps (glib, libgudev, polkit, …) come from Debian via shared.list; the
# origin-990 pin (customize/apt-ceralive-repo.sh, Package: *) keeps the fork
# winning on-device.
FIRST_PARTY_APT_PKGS=(
  "libsrt1.5-ceralive" "cerastream" "gstreamer1.0-libuvch264src" "ceralive-device" "srtla-send-rs"
  "modemmanager" "libmm-glib0"
  "libmbim-glib4" "libmbim-proxy" "libmbim-utils"
  "libqmi-glib5" "libqmi-proxy" "libqmi-utils"
  "libqrtr-glib0"
)
usage() {
  cat >&2 <<EOF
Usage:
  fetch-debs.sh --family <manifest.yaml> [--dest <dir>]

Env: CHANNEL ARCH DEST DRY_RUN ARMBIAN_APT_URL ARMBIAN_SUITE ARMBIAN_APT_KEYRING BSP_DEB_VERSIONS_FILE
     APT_CERALIVE_URL APT_GPG_PUBLIC_B64 APT_CLIENT_CRT_B64 APT_CLIENT_KEY_B64
     CERALIVE_DEBCACHE CERALIVE_DEBCACHE_MAX_BYTES CERALIVE_DEBCACHE_DIR
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
  fetch_rk3588_userspace "${family}" "${debs}"
  fetch_first_party "${debs}"

  log_success "staging complete -> ${debs} (mkosi runtime/assembly layer consumes this)"
}

# Only run main when executed directly; sourcing (tests) gets the functions only.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
