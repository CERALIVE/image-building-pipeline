#!/usr/bin/env bash
#
# customize/run-all.sh — dispatcher that sources the CeraLive customize modules
# in a fixed, dependency-correct order.
#
# This replaces the 822-line monolithic userpatches/customize-image.sh: each
# concern now lives in its own focused, shellcheck-clean, strict module under
# this directory; this dispatcher is the single ordered entry point that the
# mkosi hooks invoke (base/mkosi.finalize for the base layer, the runtime layer
# for the rest).
#
# USAGE
#   run-all.sh [SELECTOR | MODULE...]
#     base      -> the BASE OS layer set: users
#     runtime   -> the runtime/customize set: apt-ceralive-repo udev
#                  networking-srtla sysctl-tuning services structure
#     (no args) -> defaults to `runtime`
#     MODULE... -> an explicit, space-separated list of module names (no .sh)
#
# Modules are SOURCED (not executed) so they share this process's strict mode +
# common.sh ERR trap; any module failure aborts the whole run loudly.
#
# shellcheck shell=bash

set -euo pipefail

CUSTOMIZE_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly CUSTOMIZE_DIR

# Resolve common.sh ONCE and export the path so every sourced module finds the
# exact same library regardless of how it was staged into the build/chroot.
: "${CERALIVE_COMMON_SH:="$(CDPATH='' cd -- "${CUSTOMIZE_DIR}/../../lib" && pwd)/common.sh"}"
export CERALIVE_COMMON_SH

# shellcheck source=../../lib/common.sh
source "${CERALIVE_COMMON_SH}"

# Layer -> ordered module list. Order is load-bearing:
#   apt-ceralive-repo first (sources/keyring), then hardware/udev, then the
#   network routing + tuning, then services (which enable what the above set up),
#   then the directory structure (chowns to the ceralive user from the base),
#   then data-persistence LAST — it binds /opt/ceralive + /etc/NetworkManager +
#   /var/log onto /data, so it must run after structure has created those dirs.
readonly BASE_MODULES="users"
readonly RUNTIME_MODULES="apt-ceralive-repo udev networking-srtla sysctl-tuning services structure data-persistence"

resolve_modules() {
  case "${1:-runtime}" in
    base)    echo "${BASE_MODULES}" ;;
    runtime) echo "${RUNTIME_MODULES}" ;;
    *)       echo "$@" ;;
  esac
}

main() {
  local modules
  modules="$(resolve_modules "$@")"

  log_info "run-all: dispatching modules -> ${modules}"
  local mod path
  for mod in ${modules}; do
    path="${CUSTOMIZE_DIR}/${mod}.sh"
    [[ -f "${path}" ]] || die "unknown customize module: ${mod} (${path} not found)"
    log_info "==> sourcing ${mod}.sh"
    # shellcheck source=/dev/null
    source "${path}"
  done

  log_success "run-all: all modules completed (${modules})"
}

main "$@"
