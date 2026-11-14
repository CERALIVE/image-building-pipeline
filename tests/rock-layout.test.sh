#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source lib/shared/layout.sh
[[ "$(BOARD_ID=rock-5b-plus ceralive_rootfs_mb)" == 4096 ]]
[[ "$(BOARD_ID=orange-pi-5-plus ceralive_rootfs_mb)" == 4096 ]]
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
bash lib/assemble-disk.sh build --board rock-5b-plus --output "$work/disk" --no-format
source tests/preflash-verify.sh
source lib/common.sh
source lib/verify-disk.sh
check_gpt_geometry "$work/disk" rock-5b-plus
[[ "$FAILS" == 0 ]]
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
# Grow the actual GPT at the physical minimum before growing to larger media.
truncate -s "$CERALIVE_MIN_MEDIA_BYTES" "$work/disk"
systemd-repart --offline=yes --definitions="$work/defs" --empty=refuse --dry-run=no --discard=no "$work/disk"
minimum_data_bytes=$(( (CERALIVE_MIN_MEDIA_BYTES / 1048576 - 16 - 256 - 2 * 4096 - 1) * 1024 * 1024 ))
[[ "$(part_field "$work/disk" 4 'Partition size')" -ge "$((minimum_data_bytes / 512))" ]]
# Real ext4 metadata/reservations after growing a factory-size filesystem at
# that conservative floor must leave 1 GiB even after budgeting 256 MiB payload.
truncate -s 256M "$work/data.ext4"
mkfs.ext4 -q -F "$work/data.ext4"
truncate -s "$minimum_data_bytes" "$work/data.ext4"
resize2fs "$work/data.ext4" >/dev/null 2>&1
source lib/shared/slot-reserve.sh
reserve=$(slot_reserve_assert_ext4 "$work/data.ext4" data)
metadata=$(dumpe2fs -h "$work/data.ext4" 2>/dev/null)
read -r fs_blocks fs_block_size < <(awk -F: '$1=="Block count" {b=$2} $1=="Block size" {s=$2} END {print b,s}' <<<"$metadata")
(( fs_blocks * fs_block_size >= minimum_data_bytes - 1048576 ))
available=$(sed -n 's/.*field=bavail free=\([0-9]*\).*/\1/p' <<<"$reserve")
(( available - 256 * 1024 * 1024 >= CERALIVE_DATA_MIN_AVAILABLE_BYTES ))
printf 'minimum media data partition floor=%s; grown ext4 available=%s; factory payload budget=268435456\n' "$minimum_data_bytes" "$available"
truncate -s 32G "$work/disk"
systemd-repart --offline=yes --definitions="$work/defs" --empty=refuse --dry-run=no "$work/disk"
for n in 1 2 3; do sgdisk -i "$n" "$work/disk" >"$work/after$n"; cmp "$work/before$n" "$work/after$n"; done
[[ "$(part_field "$work/disk" 4 'First sector')" == "$start" ]]
[[ "$(part_field "$work/disk" 4 'Partition size')" -gt "$((256*2048))" ]]
sgdisk --backup="$work/gpt1" "$work/disk"
systemd-repart --offline=yes --definitions="$work/defs" --empty=refuse --dry-run=no "$work/disk"
sgdisk --backup="$work/gpt2" "$work/disk"
cmp "$work/gpt1" "$work/gpt2"
grep -q 'x-systemd.growfs' mkosi/customize/postinst.d/persistence.sh
echo 'ROCK geometry acceptance, mutation rejection and CLI precedence pass'
