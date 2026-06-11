#!/usr/bin/env bash
#
# build-ceraui-appfs.sh — package CeraUI into the APP layer via the appfs backend.
#
# CeraUI is the ONLY first-party component that CANNOT ship as a systemd-sysext:
# it writes heavily OUTSIDE the /usr+/opt sysext merge boundary (task-4 map):
#
#   /usr/local/bin/ceralive                      Bun --compile backend binary
#   /usr/local/bin/{override-belaui,reset-to-default}.sh
#   /etc/systemd/system/ceralive.service         systemd unit  (under /etc!)
#   /etc/systemd/system/ceralive.socket          activation socket
#   /etc/udev/rules.d/98-ceralive-audio.rules    udev rules     (under /etc!)
#   /etc/udev/rules.d/99-ceralive-check-usb-devices.rules
#   /etc/ceralive/config.json                    runtime config (under /etc!)
#   /var/www/ceralive/                           PWA static assets (under /var!)
#
# A sysext overlays ONLY /usr and /opt and CANNOT merge /etc or /var, so a sysext
# would silently DROP the unit, the udev rules, the config and the whole web root —
# leaving an unstartable, unreachable UI. Therefore CeraUI uses the appfs backend
# (full-filesystem payload, no /usr-only restriction). srtla — a pure
# /usr/bin binary — stays on the sysext backend (build-*-sysext.sh, task 22).
#
# Becoming sysext-ready is a CeraUI-REPO change (relocate units/udev/config/www to
# /usr + confext), NOT pipeline work — fully specified in
# v2/docs/deferred-ceraui-sysext.md. Until then, appfs is the only viable backend.
#
# ── FFI RESOLUTION (in-process, NOT IPC) ─────────────────────────────────────
# The CeraUI backend is a single Bun binary that holds IN-PROCESS native FFI
# handles to srtla — it does not spawn it over a socket (cerastream, by contrast,
# is an IPC-driven engine consumed via @ceralive/cerastream). srtla handles
# resolve at process start against the MERGED /usr view of three independent layers:
#
#   Runtime OS slot (RAUC)  → libsrt1.5-openssl  → /usr/lib/<triplet>/libsrt.so.*
#   App .deb   (cerastream) → cerastream binary  → /usr/bin/cerastream
#   App sysext (srtla)      → srtla binaries     → /usr/bin/srtla_{send,rec}
#   App appfs  (CeraUI)     → ceralive binary    → /usr/local/bin/ceralive
#
# Because the sysext merges srtla into the live /usr and the runtime slot
# provides libsrt in /usr/lib, the appfs CeraUI binary sees them all through the
# normal loader path — no bundling, no IPC. CRITICAL CONSEQUENCE: after a sysext
# refresh swaps the srtla binaries, the FFI handles are stale until the
# process reloads them; refresh_app_layer (sysext.sh) therefore restarts
# ceralive.service. The link:../../../ sibling-checkout (ARCHITECTURE.md §5) is a
# BUILD-time concern of the CeraUI .deb — by the time we package here it is already
# baked into the compiled binary; this script never touches that layout.
#
# Usage:
#   build-ceraui-appfs.sh <ceraui_deb_staging_dir> <output_dir>
#     <ceraui_deb_staging_dir>  extracted CeraUI .deb tree (dpkg-deb -x output)
#     <output_dir>              where the appfs artifact directory is written
#   Echoes the artifact path (the staged ceraui/ directory) on stdout.
#
# shellcheck shell=bash

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The app-layer contract lives in v2/lib/app-layer/ (this file is v2/mkosi/app/).
# shellcheck source=../../lib/app-layer/interface.sh
source "${HERE}/../../lib/app-layer/interface.sh"

# The app name is the on-device identity used by every backend verb and by
# ceralive.service. Fixed — CeraUI is a single app, not a config knob.
CERAUI_APP_NAME="ceraui"

# ---------------------------------------------------------------------------
# assert_full_filesystem_payload <staging_dir>
#   CeraUI's reason-for-being on appfs is its footprint OUTSIDE /usr+/opt. Prove
#   the staging tree actually carries that footprint before packaging — a tree
#   that fits the sysext boundary would mean the .deb layout changed and this
#   script (and the deferred sysext doc) must be revisited. Loud, not silent.
# ---------------------------------------------------------------------------
assert_full_filesystem_payload() {
  local staging_dir="$1"

  # The unit + udev + config + web root are the load-bearing non-/usr paths. If
  # ANY is missing the appfs payload would ship a broken UI, so demand them all.
  local required=(
    "etc/systemd/system/ceralive.service"
    "etc/udev/rules.d/98-ceralive-audio.rules"
    "etc/ceralive/config.json"
    "var/www/ceralive"
  )
  local rel missing=()
  for rel in "${required[@]}"; do
    [[ -e "${staging_dir}/${rel}" ]] || missing+=("${rel}")
  done
  if [[ "${#missing[@]}" -ne 0 ]]; then
    die "ceraui appfs payload incomplete — missing: ${missing[*]} (CeraUI .deb layout changed? re-check v2/docs/deferred-ceraui-sysext.md)"
  fi

  # The compiled backend binary must be present (the FFI host process itself).
  [[ -e "${staging_dir}/usr/local/bin/ceralive" ]] \
    || die "ceraui appfs payload missing the backend binary usr/local/bin/ceralive"

  # Non-vacuity check: this MUST be a full-filesystem payload. If the tree had
  # ONLY /usr + /opt it would (wrongly) qualify for sysext — assert it does not.
  local has_nonusr=0 top
  for top in etc var; do
    if [[ -d "${staging_dir}/${top}" ]]; then
      has_nonusr=1
      break
    fi
  done
  [[ "${has_nonusr}" -eq 1 ]] \
    || die "ceraui staging has no /etc or /var — that would fit sysext; appfs is the wrong backend for a /usr-only tree"

  log_info "ceraui: full-filesystem payload verified (units, udev, config, web root, binary all present)"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
  local staging_dir="${1:-}" output_dir="${2:-}"
  [[ -n "$staging_dir" ]] || die "usage: build-ceraui-appfs.sh <ceraui_deb_staging_dir> <output_dir>"
  [[ -d "$staging_dir" ]] || die "ceraui deb staging dir not found: ${staging_dir}"
  [[ -n "$output_dir" ]]  || die "usage: build-ceraui-appfs.sh <ceraui_deb_staging_dir> <output_dir>"

  # CeraUI is pinned to the appfs backend regardless of the board manifest's
  # default app_backend (sysext). Forcing it here keeps the per-component backend
  # decision explicit and local — srtla reads the manifest default;
  # CeraUI does NOT, because its /etc+/var footprint makes sysext non-viable.
  export APP_BACKEND="appfs"
  select_backend

  log_info "ceraui: packaging via appfs backend (full filesystem, no /usr-only restriction)"
  assert_full_filesystem_payload "$staging_dir"

  local artifact
  artifact="$(build_app_layer "$CERAUI_APP_NAME" "$staging_dir" "$output_dir")"

  log_success "ceraui: appfs artifact staged at ${artifact}"
  printf '%s\n' "$artifact"
}

main "$@"
