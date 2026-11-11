#!/usr/bin/env bash
# Fresh ROCK 5B+ geometry. Other boards retain the v2 layout.
# Shared by factory slots, signed OTA slot images and the offline verifier.
ceralive_rootfs_mb() {
  if [[ "${BOARD_ID:-}" == rock-5b-plus ]]; then echo 2560; else echo 4096; fi
}
ceralive_data_floor_mb() {
  if [[ "${BOARD_ID:-}" == rock-5b-plus ]]; then echo 256; else echo 2048; fi
}

# One policy shared with the installed runtime readiness check.
# shellcheck source=mkosi/runtime/ceralive-data-capacity-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../mkosi/runtime/ceralive-data-capacity-lib.sh"
ceralive_min_media_bytes() {
  if [[ "${BOARD_ID:-}" == rock-5b-plus ]]; then echo "$CERALIVE_COMPACT_MIN_MEDIA_BYTES"; else echo 0; fi
}
