#!/usr/bin/env bash
# Fresh ROCK 5B+ geometry: 4 GiB root slots and a small factory data partition
# that grows on first boot. Other boards retain the v2 data floor.
# Shared by factory slots, signed OTA slot images and the offline verifier.
ceralive_rootfs_mb() {
  echo 4096
}
ceralive_data_floor_mb() {
  if [[ "${BOARD_ID:-}" == rock-5b-plus ]]; then echo 256; else echo 2048; fi
}

# One policy shared with the installed runtime readiness check.
# shellcheck source=mkosi/runtime/ceralive-data-capacity-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../mkosi/runtime/ceralive-data-capacity-lib.sh"
ceralive_min_media_bytes() {
  if [[ "${BOARD_ID:-}" == rock-5b-plus ]]; then
    ceralive_rootfs_mb >/dev/null || return $?
    echo "$CERALIVE_MIN_MEDIA_BYTES"
  else echo 0; fi
}
