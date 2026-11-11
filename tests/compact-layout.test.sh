#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source lib/shared/layout.sh
[[ "$(BOARD_ID=rock-5b-plus ceralive_rootfs_mb)" == 2560 ]]
[[ "$(BOARD_ID=orange-pi-5-plus ceralive_rootfs_mb)" == 4096 ]]
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
unset BOARD_ID
bash lib/assemble-disk.sh build --board rock-5b-plus --output "$work/disk" --no-format
[[ "$(stat -c %s "$work/disk")" == "$((5649*1024*1024))" ]]
# Run the production preflash geometry checker, not a duplicated oracle.
source tests/preflash-verify.sh
check_gpt_geometry "$work/disk" rock-5b-plus
[[ "$FAILS" -eq 0 ]]
check_gpt_geometry "$work/disk" orange-pi-5-plus
[[ "$FAILS" -eq 1 ]] # wrong board must reject the compact geometry
FAILS=0
# Mutating a root slot size still fails the compact gate.
cp --sparse=always "$work/disk" "$work/bad"
sgdisk -d 3 -n 3:5799936:+2559M -c 3:rootfs_b "$work/bad" >/dev/null
check_gpt_geometry "$work/bad" rock-5b-plus
[[ "$FAILS" -eq 1 ]]
# The release entrypoint forwards its selected board to the same gate.
grep -Fq 'BOARD_ID="${CERALIVE_RELEASE_BOARD}" tests/preflash-verify.sh' .github/workflows/release.yml
source lib/common.sh
source lib/verify-disk.sh
do_verify "$work/disk" rock-5b-plus
BOARD_ID=rock-5b-plus bash lib/assemble-disk.sh build --board orange-pi-5-plus --output "$work/legacy" --no-format
check_gpt_geometry "$work/legacy" orange-pi-5-plus
# Previous negative controls deliberately incremented FAILS.
[[ "$FAILS" -eq 1 ]]
FAILS=0
for n in 1 2 3; do sgdisk -i "$n" "$work/disk" >"$work/before$n"; done
start=$(part_field "$work/disk" 4 'First sector')
mkdir "$work/defs"
# Lift the shipped definition (substitute only its chroot-rendered label).
sed -n '/^\[Partition\]/,/^EOF/p' mkosi/customize/postinst.d/persistence.sh | sed '$d;s/${data_partlabel}/data/' >"$work/defs/40-data.conf"
truncate -s 8192M "$work/disk"
systemd-repart --offline=yes --definitions="$work/defs" --empty=refuse --dry-run=no "$work/disk"
for n in 1 2 3; do sgdisk -i "$n" "$work/disk" >"$work/after$n"; cmp "$work/before$n" "$work/after$n"; done
[[ "$(part_field "$work/disk" 4 'First sector')" == "$start" ]]
[[ "$(part_field "$work/disk" 4 'Partition size')" -gt "$((256*2048))" ]]
sgdisk --backup="$work/gpt1" "$work/disk"
systemd-repart --offline=yes --definitions="$work/defs" --empty=refuse --dry-run=no "$work/disk"
sgdisk --backup="$work/gpt2" "$work/disk"
cmp "$work/gpt1" "$work/gpt2"
grep -q 'x-systemd.growfs' mkosi/customize/postinst.d/persistence.sh
echo 'compact factory geometry, partition growth, preserved roots and idempotence pass'
