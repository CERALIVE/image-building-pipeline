#!/bin/sh
# Signed install-check runs before any slot write, including on older images.
set -eu
[ "${1:-}" = install-check ] || exit 1
refuse() {
    echo 'Unsupported root partition geometry; expected 4 GiB root slots.' >&2
    exit 78
}
for label in rootfs_a rootfs_b; do
    device=$(readlink -f "/dev/disk/by-partlabel/$label") || refuse
    bytes=$(lsblk -bdnro SIZE "$device") || refuse
    [ "$bytes" = 4294967296 ] || refuse
done
