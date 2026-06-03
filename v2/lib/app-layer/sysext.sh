#!/usr/bin/env bash
#
# sysext.sh — systemd-sysext app-layer backend (DEFAULT).
#
# Sourced by interface.sh; relies on common.sh (already sourced there) for the
# loud loggers, die() and require_cmd(). Implements the three-verb contract for
# the pure-binary first-party components (ceracoder, srtla) that fit the sysext
# boundary: a sysext extension overlays ONLY /usr and /opt and CANNOT touch /etc
# or /var (task-4 boundary). Components that write heavily to /etc or /var/www
# (CeraUI) use the appfs backend instead.
#
# extension-release matching (task-4 evidence): the image must carry
#   /usr/lib/extension-release.d/extension-release.<NAME>
# containing `ID=debian` plus a VERSION_ID that matches the host os-release, or
# the kernel refuses to merge the extension ("No suitable extensions found").
# The device OS is Debian bookworm (VERSION_ID=12) across the whole stack.
#
# shellcheck shell=bash

# Host os-release identity the device matches against. Debian bookworm.
SYSEXT_OS_ID="${SYSEXT_OS_ID:-debian}"
SYSEXT_OS_VERSION_ID="${SYSEXT_OS_VERSION_ID:-12}"

# Where installed extensions live on the image/device. Overridable so the
# builder can target an image rootfs without touching the build host.
EXTENSIONS_DIR="${EXTENSIONS_DIR:-/var/lib/extensions}"

# ---------------------------------------------------------------------------
# build_app_layer <app_name> <deb_staging_dir> <output_dir>
#   Build <output_dir>/<app_name>.raw from an extracted .deb staging tree.
#   Only /usr and /opt cross the sysext boundary; everything else is dropped.
#   Echoes the artifact path on stdout.
# ---------------------------------------------------------------------------
build_app_layer() {
  local app_name="$1" deb_staging_dir="$2" output_dir="$3"
  [[ -n "$app_name" ]] || die "build_app_layer: missing <app_name>"
  [[ -d "$deb_staging_dir" ]] \
    || die "build_app_layer: deb staging dir not found: ${deb_staging_dir}"
  [[ -n "$output_dir" ]] || die "build_app_layer: missing <output_dir>"

  require_cmd mksquashfs

  mkdir -p "$output_dir"

  # Assemble the sysext tree from only the merge-eligible subtrees (/usr, /opt).
  local tree
  tree="$(mktemp -d)"

  local copied=0 sub
  for sub in usr opt; do
    if [[ -d "${deb_staging_dir}/${sub}" ]]; then
      mkdir -p "${tree}/${sub}"
      cp -a "${deb_staging_dir}/${sub}/." "${tree}/${sub}/"
      copied=1
    fi
  done
  if [[ "$copied" -ne 1 ]]; then
    rm -rf "$tree"
    die "build_app_layer: '${deb_staging_dir}' has neither /usr nor /opt (nothing fits the sysext boundary)"
  fi

  # Write the extension-release matching file the kernel keys merging on.
  local rel_dir="${tree}/usr/lib/extension-release.d"
  mkdir -p "$rel_dir"
  {
    printf 'ID=%s\n' "$SYSEXT_OS_ID"
    printf 'VERSION_ID=%s\n' "$SYSEXT_OS_VERSION_ID"
  } > "${rel_dir}/extension-release.${app_name}"

  local artifact="${output_dir}/${app_name}.raw"
  log_info "sysext: building squashfs ${artifact} for '${app_name}'"
  mksquashfs "$tree" "$artifact" -noappend -all-root -quiet

  rm -rf "$tree"
  printf '%s\n' "$artifact"
}

# ---------------------------------------------------------------------------
# install_app_layer <app_name> <artifact>
#   Copy the .raw into the extensions dir and refresh the sysext overlay.
# ---------------------------------------------------------------------------
install_app_layer() {
  local app_name="$1" artifact="$2"
  [[ -n "$app_name" ]] || die "install_app_layer: missing <app_name>"
  [[ -f "$artifact" ]] || die "install_app_layer: artifact not found: ${artifact}"

  require_cmd systemd-sysext

  mkdir -p "$EXTENSIONS_DIR"
  log_info "sysext: installing ${artifact} -> ${EXTENSIONS_DIR}/${app_name}.raw"
  install -m 0644 "$artifact" "${EXTENSIONS_DIR}/${app_name}.raw"

  systemd-sysext refresh
}

# ---------------------------------------------------------------------------
# refresh_app_layer <app_name>
#   Hot-update a running device: re-merge the overlay, then restart
#   ceralive.service. The restart is NON-NEGOTIABLE — CeraUI's backend holds
#   IN-PROCESS native FFI bindings to ceracoder/srtla, so a sysext refresh of
#   those binaries does not take effect until the process reloads its bindings.
# ---------------------------------------------------------------------------
refresh_app_layer() {
  local app_name="$1"
  [[ -n "$app_name" ]] || die "refresh_app_layer: missing <app_name>"

  require_cmd systemd-sysext
  require_cmd systemctl

  log_info "sysext: refreshing overlay and restarting ceralive.service for '${app_name}'"
  systemd-sysext refresh
  systemctl restart ceralive.service
}
