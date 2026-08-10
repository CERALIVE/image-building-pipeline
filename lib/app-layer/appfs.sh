#!/usr/bin/env bash
#
# appfs.sh — full-filesystem app-layer backend (per-board FALLBACK).
#
# Sourced by interface.sh; relies on common.sh (already sourced there) for the
# loud loggers, die() and require_cmd(). For boards where the sysext /usr-only
# constraint is unworkable, or for components that write heavily outside /usr
# and /opt (CeraUI's /etc + /var/www footprint — task-4 boundary). The payload
# is staged as a plain directory tree with no /usr restriction.
#
# shellcheck shell=bash

# Where the appfs payload lands on the image/device. Overridable so the builder
# can target an image rootfs without touching the build host.
APPFS_DIR="${APPFS_DIR:-/opt/ceralive/appfs}"

# ---------------------------------------------------------------------------
# build_app_layer <app_name> <deb_staging_dir> <output_dir>
#   Stage the full .deb payload to <output_dir>/<app_name>/ verbatim (no /usr
#   boundary). Echoes the artifact directory path on stdout.
# ---------------------------------------------------------------------------
build_app_layer() {
  local app_name="$1" deb_staging_dir="$2" output_dir="$3"
  [[ -n "$app_name" ]] || die "build_app_layer: missing <app_name>"
  [[ -d "$deb_staging_dir" ]] \
    || die "build_app_layer: deb staging dir not found: ${deb_staging_dir}"
  [[ -n "$output_dir" ]] || die "build_app_layer: missing <output_dir>"

  local artifact="${output_dir}/${app_name}"
  mkdir -p "$artifact"
  log_info "appfs: staging payload for '${app_name}' -> ${artifact}"
  cp -a "${deb_staging_dir}/." "${artifact}/"

  printf '%s\n' "$artifact"
}

# ---------------------------------------------------------------------------
# install_app_layer <app_name> <artifact>
#   Copy the staged directory onto the appfs slot.
# ---------------------------------------------------------------------------
install_app_layer() {
  local app_name="$1" artifact="$2"
  [[ -n "$app_name" ]] || die "install_app_layer: missing <app_name>"
  [[ -d "$artifact" ]] || die "install_app_layer: artifact dir not found: ${artifact}"

  local target="${APPFS_DIR}/${app_name}"
  mkdir -p "$target"
  log_info "appfs: installing ${artifact} -> ${target}"
  cp -a "${artifact}/." "${target}/"
}

# ---------------------------------------------------------------------------
# refresh_app_layer <app_name>
#   Hot-update a running device. The payload is already on disk, so a service
#   restart picks it up (and reloads CeraUI's in-process FFI bindings).
# ---------------------------------------------------------------------------
refresh_app_layer() {
  local app_name="$1"
  [[ -n "$app_name" ]] || die "refresh_app_layer: missing <app_name>"

  require_cmd systemctl

  log_info "appfs: restarting ceralive.service for '${app_name}'"
  systemctl restart ceralive.service
}
