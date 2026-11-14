#!/usr/bin/env bash
# Shared geometry and service-only device lookup for the real RAUC fixture.
# shellcheck source=lib/shared/layout.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/shared/layout.sh"

rauc_fixture_slot_images() {
  local work="$1" mb
  mb=$(BOARD_ID=rock-5b-plus ceralive_rootfs_mb)
  truncate -s "${mb}M" "${work}/slot-a.ext4" "${work}/slot-b.ext4"
}

rauc_fixture_gpt() {
  local work="$1" mb
  mb=$(BOARD_ID=rock-5b-plus ceralive_rootfs_mb)
  truncate -s "$((2 * mb + 108))M" "${work}/gpt.raw"
  sgdisk -o -n "1:2048:+${mb}M" -c 1:rootfs_a -n "2:0:+${mb}M" -c 2:rootfs_b "${work}/gpt.raw" >/dev/null
}

rauc_fixture_device_map() {
  local work="$1" slot_a="$2" slot_b="$3"
  mkdir -p "${work}/bin" "${work}/partlabels"
  ln -sfn -- "${slot_a}" "${work}/partlabels/rootfs_a"
  ln -sfn -- "${slot_b}" "${work}/partlabels/rootfs_b"
  # Only the service's PATH gets this shim. The signed production hook remains
  # byte-identical and lsblk reads the real fixture loop devices, never host slots.
  cat >"${work}/bin/readlink" <<'SH'
#!/bin/sh
if [ "$#" = 2 ] && [ "$1" = -f ]; then
  case "$2" in
    /dev/disk/by-partlabel/rootfs_a|/dev/disk/by-partlabel/rootfs_b)
      work=$(dirname "$(dirname "$0")")
      exec /usr/bin/readlink -f "$work/partlabels/${2##*/}"
      ;;
  esac
fi
exec /usr/bin/readlink "$@"
SH
  chmod +x "${work}/bin/readlink"
}
