#!/usr/bin/env bash
# Write image-owned data, never executable shell input. The caller runs as root
# in the image; the file belongs to the rootfs slot, not persistent user state.
write_board_identity() {
  local destination="$1" board="$2" family="$3" capabilities="$4"
  local capability_list='^([a-z0-9][a-z0-9-]*( [a-z0-9][a-z0-9-]*)*)?$'
  [[ "$board" =~ ^[a-z0-9][a-z0-9_-]*$ && "$family" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || return 1
  [[ "$capabilities" =~ $capability_list ]] || return 1
  local update_board="${UPDATE_BOARD:-}" compatible="${COMPATIBLE_STRING:-}" arch="${ARCH:-}"
  # The image resolver uses mkosi's spelling; release consumers use Debian's.
  [[ "$arch" != x86-64 ]] || arch=amd64
  [[ "$update_board" =~ ^[a-z0-9-]*$ && "$compatible" =~ ^[a-z0-9-]*$ && "$arch" =~ ^(arm64|amd64)?$ ]] || return 1
  if [[ " $capabilities " != *" os-updates "* ]]; then update_board=""; compatible=""; fi
  cat >"$destination" <<RECORD
NAME="CeraLive"
PRETTY_NAME="CeraLive Streaming Appliance"
ID=ceralive
VERSION_ID="1"
BUILD_BRANCH="stable"
BOARD=$board
FAMILY=$family
CAPABILITIES="$capabilities"
UPDATE_BOARD=$update_board
UPDATE_COMPATIBLE=$compatible
KERNEL_ARCH=$arch
RECORD
  chmod 0444 "$destination"
}
