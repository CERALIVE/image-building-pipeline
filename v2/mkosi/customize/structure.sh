#!/usr/bin/env bash
#
# customize/structure.sh — CeraLive directory layout + branding.
#
# DECOMPOSED FROM: userpatches/customize-image.sh:create_ceraui_structure()
# (L634-770).
#
# UNIFIED NAMING: v1 split paths between /etc/opt/ceraui + /opt/ceraui +
# /var/opt/ceraui + /home/ceraui (internal "ceraui") and /etc/ceralive
# (branding). v2 unifies ALL of it on `ceralive`; the legacy /etc/opt/ceraui ->
# /etc/ceralive/conf.d compatibility symlink (v1 L763) is dropped because nothing
# in the v2 image references the ceraui path anymore.
#
# The /etc/ceralive/conf.d/*.conf default seeds (srtla/streaming/network/hardware/
# modems) were removed: an audit found NO consumer reads any of them.
#
# /etc + /var writes are left IN PLACE here (data-persistence relocation of
# /var/opt/ceralive is task 30, not this task).
#
# CONTRACT: sourced by run-all.sh (chroot context). Strict; no `|| true`.
# Depends on the `ceralive` user/group existing (created in the base layer by
# users.sh) for the chown of /home/ceralive + /var/opt/ceralive.
#
# shellcheck shell=bash

set -euo pipefail

# shellcheck source=../../lib/common.sh
source "${CERALIVE_COMMON_SH:-"$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd)/common.sh"}"

readonly CERALIVE_USER="${CERALIVE_USER:-ceralive}"

create_ceralive_structure() {
  log_info "creating /etc/ceralive + /opt/ceralive + /var/opt/ceralive layout"
  mkdir -p /etc/opt/ceralive
  mkdir -p /opt/ceralive/bin /opt/ceralive/lib /opt/ceralive/share
  mkdir -p /var/opt/ceralive/cache /var/opt/ceralive/logs
  mkdir -p "/home/${CERALIVE_USER}/.config/ceralive" "/home/${CERALIVE_USER}/.local/share/ceralive"
  mkdir -p /etc/ceralive

  log_info "writing /etc/ceralive/release branding"
  cat >/etc/ceralive/release <<'EOF'
NAME="CeraLive"
PRETTY_NAME="CeraLive Streaming Appliance"
ID=ceralive
VERSION_ID="1"
BUILD_BRANCH="stable"
EOF

  log_info "setting ownership for ${CERALIVE_USER} home + var tree"
  chown -R "${CERALIVE_USER}:${CERALIVE_USER}" "/home/${CERALIVE_USER}" /var/opt/ceralive

  log_info "writing login banners"
  echo 'CeraLive Streaming Appliance' >/etc/issue
  echo 'CeraLive Streaming Appliance' >/etc/issue.net

  log_success "CeraLive structure created"
}

create_ceralive_structure "$@"
