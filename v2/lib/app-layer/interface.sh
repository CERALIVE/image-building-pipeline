#!/usr/bin/env bash
#
# interface.sh — the MINIMAL app-layer backend contract for the CeraLive v2
# image pipeline.
#
# There is exactly ONE contract, with exactly THREE verbs, served by exactly TWO
# backends. The builder, the dev loop and the on-device update path all consume
# the SAME three verbs — so a sysext artifact built in dev is byte-identical to
# the one shipped in prod (no dev-vs-prod divergence).
#
#   build_app_layer   <app_name> <deb_staging_dir> <output_dir>
#       Build the app artifact from an extracted .deb staging tree.
#       sysext -> a squashfs <app_name>.raw ; appfs -> an <app_name>/ directory.
#       Echoes the resulting artifact path on stdout (loggers go to stderr).
#
#   install_app_layer <app_name> <artifact>
#       Place the artifact into the image / device.
#       sysext -> copy .raw to /var/lib/extensions + `systemd-sysext refresh`.
#       appfs  -> copy the directory onto the appfs slot.
#
#   refresh_app_layer <app_name>
#       Hot-update a RUNNING device after the artifact is in place.
#       sysext -> `systemd-sysext refresh` + restart ceralive.service.
#       appfs  -> restart ceralive.service.
#
# Backend selection reads the APP_BACKEND env var (emitted upper-cased by
# resolve.sh from the manifest `app_backend:` field). It defaults to `sysext`.
#
# DESIGN RULE — this interface is deliberately MINIMAL: 3 verbs, 2 backends, no
# registry, no plugin discovery, no speculative extension points. Adding a verb
# or a backend is a contract change, not a config knob.
#
# Usage (from the builder/orchestrator):
#   source "v2/lib/app-layer/interface.sh"
#   select_backend                         # sources $APP_BACKEND.sh, validates it
#   artifact="$(build_app_layer ceracoder "$staging" "$out")"
#   install_app_layer ceracoder "$artifact"
#
# shellcheck shell=bash

APP_LAYER_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../common.sh
source "${APP_LAYER_HERE}/../common.sh"

# The three-verb contract. Exactly these — no fourth verb.
APP_LAYER_VERBS=(build_app_layer install_app_layer refresh_app_layer)

# The only two backends. No plugin discovery, no registry.
APP_LAYER_BACKENDS=(sysext appfs)

# ---------------------------------------------------------------------------
# select_backend — resolve APP_BACKEND, source its backend file, and verify it
# implements all three verbs. Dies loudly on an unknown backend, a missing
# backend file, or a backend that fails to define every verb.
# ---------------------------------------------------------------------------
select_backend() {
  local backend="${APP_BACKEND:-sysext}"

  # Validate the backend name is one of the two known backends.
  local known=0 b
  for b in "${APP_LAYER_BACKENDS[@]}"; do
    if [[ "$b" == "$backend" ]]; then
      known=1
      break
    fi
  done
  [[ "$known" -eq 1 ]] \
    || die "unknown app_backend '${backend}' (expected one of: ${APP_LAYER_BACKENDS[*]})"

  local backend_file="${APP_LAYER_HERE}/${backend}.sh"
  [[ -f "$backend_file" ]] || die "app-layer backend file not found: ${backend_file}"

  # shellcheck source=/dev/null
  source "$backend_file"

  # The backend MUST implement every verb in the contract.
  local verb
  for verb in "${APP_LAYER_VERBS[@]}"; do
    declare -F "$verb" >/dev/null \
      || die "app-layer backend '${backend}' does not implement required verb '${verb}'"
  done

  log_info "app-layer backend selected: ${backend}"
}
