#!/usr/bin/env bash
#
# customize/users.sh — create the CeraLive runtime user + hardware groups.
#
# DECOMPOSED FROM: userpatches/customize-image.sh:create_ceraui_user() (L30-50)
# + the hardware-group additions of setup_hardware_access() (L274-280).
#
# UNIFIED NAMING: v1 created the user `ceraui`; v2 unifies on `ceralive`
# (the "ceraui → ceralive" rename).
#
# LAYER: this module MUST run in the BASE OS layer (base/mkosi.finalize) so the
# `ceralive` account exists in the base rootfs BEFORE the sysext app layer
# (task 22) merges /usr/bin/ceracoder + /usr/bin/srtla and runs services as it.
#
# CONTRACT: sourced by run-all.sh (chroot context). Idempotent. Strict; no
# `|| true`; loud on any failure via common.sh's ERR trap.
#
# shellcheck shell=bash

set -euo pipefail

# shellcheck source=../../lib/common.sh
source "${CERALIVE_COMMON_SH:-"$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd)/common.sh"}"

# Hardware/admin groups the user must belong to for streaming-appliance access.
# (audio/video capture, dialout=modems, plugdev/netdev, gpio/i2c/spi=RK3588.)
readonly CERALIVE_USER_GROUPS="sudo audio video dialout plugdev netdev gpio i2c spi"

configure_users() {
  log_info "creating '${CERALIVE_USER:-ceralive}' user and hardware groups"
  local user="${CERALIVE_USER:-ceralive}"

  # Ensure every required group exists before referencing it (--system: no UID).
  # Replaces v1's `groupadd -f "$grp" || true` (L35) with a real guard.
  local grp
  for grp in ${CERALIVE_USER_GROUPS}; do
    if ! getent group "${grp}" >/dev/null; then
      groupadd --system "${grp}"
    fi
  done

  # Create the account once. v1 used `id -u … || useradd` (L39).
  if ! id -u "${user}" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash "${user}"
  fi

  # Images ship with NO static password; the account is locked and provisioned
  # over-the-air / first-boot. v1 L41,47 did the same but with `|| true`.
  passwd -l "${user}"
  passwd -l root

  # Comma-join the group list for usermod (v1 L44).
  local joined="${CERALIVE_USER_GROUPS// /,}"
  usermod -aG "${joined}" "${user}"

  log_success "user '${user}' present in groups: ${joined}"
}

configure_users "$@"
