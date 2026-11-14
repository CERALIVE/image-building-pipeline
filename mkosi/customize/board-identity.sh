#!/usr/bin/env bash
# Write image-owned data, never executable shell input. The caller runs as root
# in the image; the file belongs to the rootfs slot, not persistent user state.
write_board_identity() {
  local destination="$1" board="$2" family="$3" capabilities="$4"
  local capability_list='^([a-z0-9][a-z0-9-]*( [a-z0-9][a-z0-9-]*)*)?$'
  [[ "$board" =~ ^[a-z0-9][a-z0-9_-]*$ && "$family" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || return 1
  [[ "$capabilities" =~ $capability_list ]] || return 1
  cat >"$destination" <<RECORD
NAME="CeraLive"
PRETTY_NAME="CeraLive Streaming Appliance"
ID=ceralive
VERSION_ID="1"
BUILD_BRANCH="stable"
BOARD=$board
FAMILY=$family
CAPABILITIES="$capabilities"
RECORD
  chmod 0444 "$destination"
}
