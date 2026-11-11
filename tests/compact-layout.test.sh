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
# Transport minimum is not the supported physical media minimum.
for target in 5923405824 7516192767; do
  FAILS=0
  check_target_capacity "$work/disk" "$target" rock-5b-plus
  [[ "$FAILS" == 1 ]]
done
FAILS=0
check_target_capacity "$work/disk" 7516192768 rock-5b-plus
[[ "$FAILS" == 0 ]]
# Other boards keep their image-fit rule.
check_target_capacity "$work/disk" 5923405824 orange-pi-5-plus
[[ "$FAILS" == 0 ]]
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
# Retain the default host growth regression too; the opt-in suite additionally
# exercises the target version and all supported layout forms.
source mkosi/runtime/ceralive-grow-data.sh
mkdir "$work/defs"
: >"$work/table"
for n in 1 2 3 4; do
  info=$(sgdisk -i "$n" "$work/disk")
  label=$(sed -n "s/Partition name: '\(.*\)'/\1/p" <<<"$info")
  type=$(sed -n 's/Partition GUID code: \([^ ]*\).*/\1/p' <<<"$info")
  sectors=$(awk '/Partition size:/{print $3}' <<<"$info")
  first=$(awk '/First sector:/{print $3}' <<<"$info")
  printf 'part %s %s %s %s %s\n' "$label" "$type" "$((sectors * 512))" "$n" "$first" >>"$work/table"
  if (( n < 4 )); then printf '%s\n' "$info" >"$work/before$n"; fi
done
grow_data_definitions "$work/defs" data <"$work/table"
start=$(part_field "$work/disk" 4 'First sector')
# Grow the actual GPT at the physical minimum before retaining the 8 GiB case.
truncate -s "$CERALIVE_COMPACT_MIN_MEDIA_BYTES" "$work/disk"
systemd-repart --offline=yes --definitions="$work/defs" --empty=refuse --dry-run=no --discard=no "$work/disk"
minimum_data_bytes=$(( (7168 - 16 - 256 - 2 * 2560 - 1) * 1024 * 1024 ))
[[ "$(part_field "$work/disk" 4 'Partition size')" -ge "$((minimum_data_bytes / 512))" ]]
# Real ext4 metadata/reservations after growing a factory-size filesystem at
# that conservative floor must leave 1 GiB even after budgeting 256 MiB payload.
truncate -s 256M "$work/data.ext4"
mkfs.ext4 -q -F "$work/data.ext4"
truncate -s "$minimum_data_bytes" "$work/data.ext4"
resize2fs "$work/data.ext4" >/dev/null 2>&1
source lib/shared/slot-reserve.sh
reserve=$(slot_reserve_assert_ext4 "$work/data.ext4" data)
available=$(sed -n 's/.*field=bavail free=\([0-9]*\).*/\1/p' <<<"$reserve")
(( available - 256 * 1024 * 1024 >= CERALIVE_DATA_MIN_AVAILABLE_BYTES ))
printf 'minimum media data partition floor=%s; grown ext4 available=%s; factory payload budget=268435456\n' "$minimum_data_bytes" "$available"
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
echo 'compact and legacy geometry acceptance, mutation rejection and CLI precedence pass'
