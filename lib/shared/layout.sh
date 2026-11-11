#!/usr/bin/env bash
# Fresh ROCK 5B+ geometry. Other boards retain the v2 layout.
# Shared by factory slots, signed OTA slot images and the offline verifier.
ceralive_rootfs_mb() {
  if [[ "${BOARD_ID:-}" == rock-5b-plus ]]; then echo 2560; else echo 4096; fi
}
ceralive_data_floor_mb() {
  if [[ "${BOARD_ID:-}" == rock-5b-plus ]]; then echo 256; else echo 2048; fi
}
