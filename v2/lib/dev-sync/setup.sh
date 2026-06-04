#!/usr/bin/env bash
#
# setup.sh — idempotent preflight for device static-root path
#
# Verifies and creates the symlink needed for frontend sync:
#   /opt/ceralive/public → /var/www/ceralive
#
# The backend serves static files from ./public relative to WorkingDirectory
# /opt/ceralive/, but the .deb stages the bundle to /var/www/ceralive.
# This symlink bridges the gap on dev devices.
#
# Usage:
#   setup.sh [--dry-run]
#
# Environment:
#   DRY_RUN=1    print what would be done, don't execute ln -s
#
# Exit codes:
#   0  success (symlink created or already correct)
#   1  error (real directory exists, cannot overwrite)
#   2  error (other failure)
#
# shellcheck shell=bash

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

STATIC_LINK="${STATIC_LINK:-/opt/ceralive/public}"
STATIC_TARGET="${STATIC_TARGET:-/var/www/ceralive}"
DRY_RUN="${DRY_RUN:-0}"

# ============================================================================
# Logging
# ============================================================================

log_info() {
  echo "[INFO] $*" >&2
}

log_success() {
  echo "[SUCCESS] $*" >&2
}

log_error() {
  echo "[ERROR] $*" >&2
}

log_warn() {
  echo "[WARN] $*" >&2
}

# ============================================================================
# Main logic
# ============================================================================

main() {
  log_info "=== Device Static-Root Path Preflight ==="
  log_info "Link: ${STATIC_LINK}"
  log_info "Target: ${STATIC_TARGET}"
  
  # Check if the link already exists
  if [[ -L "${STATIC_LINK}" ]]; then
    # It's a symlink — check where it points
    local current_target
    current_target="$(readlink -f "${STATIC_LINK}")"
    
    if [[ "${current_target}" == "${STATIC_TARGET}" ]]; then
      log_success "already correct: ${STATIC_LINK} → ${STATIC_TARGET}"
      return 0
    else
      log_error "symlink exists but points to wrong target: ${current_target} (expected ${STATIC_TARGET})"
      return 2
    fi
  fi
  
  # Check if the path exists as a real directory (not a symlink)
  if [[ -d "${STATIC_LINK}" && ! -L "${STATIC_LINK}" ]]; then
    log_error "refusing to overwrite real directory: ${STATIC_LINK} is not a symlink"
    log_error "manually remove or rename ${STATIC_LINK} and retry"
    return 1
  fi
  
  # Check if the path exists as a file (not a directory)
  if [[ -f "${STATIC_LINK}" ]]; then
    log_error "refusing to overwrite file: ${STATIC_LINK}"
    return 1
  fi
  
  # Path doesn't exist — create the symlink
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_info "DRY_RUN: would create symlink: ln -s ${STATIC_TARGET} ${STATIC_LINK}"
    return 0
  fi
  
  log_info "creating symlink: ${STATIC_LINK} → ${STATIC_TARGET}"
  ln -s "${STATIC_TARGET}" "${STATIC_LINK}"
  log_success "symlink created"
  return 0
}

# ============================================================================
# Entry point
# ============================================================================

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    *)
      log_error "unknown option: $1"
      exit 2
      ;;
  esac
done

main "$@"
