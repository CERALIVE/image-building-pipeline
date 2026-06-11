#!/usr/bin/env bash
#
# x86-encode.sh — set up the CeraLive x86 video-encode path (task 33, decision D1).
#
# DECISION D1 (locked; decided for ceracoder — RETIRED 2026-06-11, cerastream is
# the sole engine and selects its encode element at runtime via its HAL profiles.
# The VA-driver/x264 package guarantees below still stand; the legacy pipeline-dir
# symlink resolves only if a legacy pipeline tree is present):
# ceracoder is ENCODER-AGNOSTIC — the encode element is runtime-selected from a TEXT
# pipeline file (gst_parse_launch), not compiled in. There is NO ceracoder source
# change for x86 and NO MPP dependency. x86 supports FULL bonded streaming:
#   * PRIMARY  : Intel Quick Sync / VA-API hardware encode — the ceracoder/pipeline/
#                n100/* files invoke qsvh265enc / qsvh264dec / vajpegdec (Gen12 iGPU).
#   * FALLBACK : pure-software x264 — the ceracoder/pipeline/generic/* files invoke
#                x264enc; runs on ANY x86 CPU with no GPU.
# x86 is NOT relay-only — full streaming is confirmed. This script therefore does
# NOT configure any relay-only degradation; it wires the real encode path.
#
# WHAT THIS SCRIPT DOES (in the platform chroot, or a staging ROOT for tests):
#   1. ensure the Intel VA driver + GStreamer VA-API plugins are present (idempotent
#      apt-get; they are normally already installed by the platform layer from the
#      family manifest hw_accel_gstreamer_plugins — this is a belt-and-braces guard
#      and the place that fails LOUDLY if the iHD driver is missing).
#   2. write the encode-selection config (/etc/ceralive/conf.d/10-encode-x86.conf):
#      qsv primary, x264 fallback, pipeline families n100 -> generic.
#   3. point the active pipeline directory at the n100 family (symlink if the
#      ceracoder pipelines are already present; otherwise the config records the
#      family for ceracoder/CeraUI to resolve once the app layer installs them).
#   4. record the D1 `bps` caveat: dynamic bitrate needs a PATCHED GStreamer.
#
# MUST NOT pretend VA-API works without the Intel media driver: step 1 verifies the
# iHD driver and fails loudly if it is absent on a real build.
#
# shellcheck shell=bash

set -euo pipefail

log()  { printf '[x86-encode] %s\n' "$*" >&2; }
warn() { printf '[x86-encode] WARN: %s\n' "$*" >&2; }
die()  { printf '[x86-encode] ERROR: %s\n' "$*" >&2; exit 1; }

ROOT="${ROOT:-}"
# Skip the apt/dpkg steps when staging into a ROOT prefix or when explicitly asked
# (the offline test only needs the config + symlink behaviour, not a real install).
SKIP_PKG="${SKIP_PKG_INSTALL:-}"
[[ -n "${ROOT}" ]] && SKIP_PKG="${SKIP_PKG:-1}"

# Intel VA-API encode dependencies (x86-specific; the qsv*/va* ELEMENTS themselves
# ship in gstreamer1.0-plugins-bad, already in shared.list — NOT duplicated here):
#   intel-media-va-driver-non-free : the iHD VA driver backing QSV/VA-API on N100/N200
#   gstreamer1.0-vaapi             : VA-API GStreamer elements (vaapi*)
#   vainfo                         : runtime VA-API capability probe (diagnostics)
ENCODE_PACKAGES=(intel-media-va-driver-non-free gstreamer1.0-vaapi vainfo)

# Active hardware pipeline family for x86 N100/N200 (Intel QSV), with the pure
# software family as the universal fallback.
PIPELINE_FAMILY="${CERALIVE_PIPELINE_FAMILY:-n100}"
PIPELINE_FALLBACK_FAMILY="${CERALIVE_PIPELINE_FALLBACK_FAMILY:-generic}"

# LEGACY-COMPAT: where the retired ceracoder .deb installed its pipeline tree.
# Kept so the symlink behaviour (and its offline test) is unchanged; on a
# cerastream image the tree never appears and the link stays dangling (harmless).
# The symlink target; resolved lazily if the dir is not present yet at platform time.
CERACODER_PIPELINE_DIR="${CERACODER_PIPELINE_DIR:-/usr/share/ceracoder/pipeline}"

ensure_packages() {
  if [[ -n "${SKIP_PKG}" ]]; then
    log "package install skipped (staging/test mode); required: ${ENCODE_PACKAGES[*]}"
    return 0
  fi
  command -v apt-get >/dev/null 2>&1 || die "apt-get not found — cannot install VA-API encode packages ${ENCODE_PACKAGES[*]}"
  log "ensuring Intel VA-API encode packages: ${ENCODE_PACKAGES[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${ENCODE_PACKAGES[@]}" >&2

  # Verify the iHD driver actually landed — do NOT pretend VA-API works without it.
  local ihd
  ihd="$(dpkg-query -W -f='${Status}' intel-media-va-driver-non-free 2>/dev/null || true)"
  [[ "${ihd}" == *"install ok installed"* ]] \
    || die "intel-media-va-driver-non-free is NOT installed — VA-API/QSV hardware encode would silently fail. Refusing to ship a half-configured x86 encode path."
  log "verified: intel-media-va-driver-non-free present (iHD VA driver)"
  if command -v vainfo >/dev/null 2>&1; then
    log "vainfo present — run 'vainfo' on real N100 hardware to confirm the iHD entrypoints (VAEntrypointEncSlice)."
  fi
}

write_encode_config() {
  local conf_dir="${ROOT}/etc/ceralive/conf.d"
  local conf="${conf_dir}/10-encode-x86.conf"
  mkdir -p "${conf_dir}"
  log "writing x86 encode selection -> ${conf}"
  cat >"${conf}" <<EOF
# CeraLive x86 encode selection — task 33, decision D1.
# The encoder was agnostic; the encode element came from the pipeline FILE (legacy).
# x86 = FULL bonded streaming. This is NOT relay-only.

# Primary path: Intel Quick Sync / VA-API hardware encode (N100/N200 Gen12 iGPU).
# The ${PIPELINE_FAMILY} pipelines invoke qsvh265enc / qsvh264dec / vajpegdec.
CERALIVE_ENCODE_PRIMARY=qsv

# Fallback path: pure-software x264 (any x86 CPU, no GPU). The
# ${PIPELINE_FALLBACK_FAMILY} pipelines invoke x264enc.
CERALIVE_ENCODE_FALLBACK=x264

# Pipeline families selected from, in order (legacy ceracoder-era contract).
CERALIVE_PIPELINE_FAMILY=${PIPELINE_FAMILY}
CERALIVE_PIPELINE_FALLBACK_FAMILY=${PIPELINE_FALLBACK_FAMILY}

# x86 is NOT relay-only — full streaming is supported (D1).
CERALIVE_RELAY_ONLY=false

# D1 caveat (RUNTIME, ceracoder-era): the legacy encoder always did
# g_object_set("bps", ...). Stock distro qsvh265enc / x264enc expose "bitrate"
# (kbps), NOT "bps" — a BELABOX/CERALIVE-PATCHED GStreamer adds the "bps" property.
# On UNPATCHED distro GStreamer encode still works but DYNAMIC BITRATE CONTROL
# SILENTLY NO-OPS. Ship the patched gst encoders OR run static-bitrate on x86.
# Validate on real N100 hardware (gst-inspect-1.0 qsvh265enc | grep -i bps).
CERALIVE_DYNAMIC_BITRATE_REQUIRES_PATCHED_GST=true
EOF
  chmod 0644 "${conf}"
}

link_pipelines() {
  local link_dir="${ROOT}/etc/ceralive"
  local link="${link_dir}/pipeline"
  local target="${CERACODER_PIPELINE_DIR}/${PIPELINE_FAMILY}"
  mkdir -p "${link_dir}"

  # If a legacy pipeline tree is already present (app layer installed first, or a
  # combined build), point the stable /etc/ceralive/pipeline at the n100 family.
  if [[ -d "${ROOT}${target}" ]]; then
    ln -sfn "${target}" "${link}"
    log "active pipeline dir: ${link} -> ${target} (n100/QSV)"
  else
    # Platform layer runs BEFORE the app layer installs the first-party .debs, so the
    # pipeline tree may not exist yet. Create the stable symlink to the conventional
    # install path (resolves only if a legacy pipeline tree lands) and record the choice in config.
    ln -sfn "${target}" "${link}"
    warn "legacy pipeline tree not present (${ROOT}${target}); symlinked ${link} -> ${target} (legacy-compat; cerastream selects encoders via its HAL at runtime). Family also recorded in 10-encode-x86.conf."
  fi
}

main() {
  log "configuring x86 encode path (D1: VAAPI/QSV primary + x264 software fallback; NOT relay-only)"
  ensure_packages
  write_encode_config
  link_pipelines
  log "x86 encode path configured (primary=qsv family=${PIPELINE_FAMILY}, fallback=x264 family=${PIPELINE_FALLBACK_FAMILY})"
}

main "$@"
