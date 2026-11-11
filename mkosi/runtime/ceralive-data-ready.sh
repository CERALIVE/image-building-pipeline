#!/usr/bin/env bash
# Compact root profiles require completed growth and usable update staging.
set -euo pipefail
# shellcheck source=mkosi/runtime/ceralive-data-capacity-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/ceralive-data-capacity-lib.sh"
capacity_refuse() {
  echo "data readiness: capacity refusal: $*; slot remains unconfirmed; no automatic retry or reboot. Use local rescue to free data or move to supported larger media before retrying." >&2
  exit 78
}
refuse() {
  echo "data readiness: $*; refusing health confirmation/updates. Inspect ceralive-grow-data and systemd-growfs@data journals; repair and reboot to retry." >&2
  exit 1
}
root=$(readlink -f "$(findmnt -nro SOURCE /)")
root_bytes=$(lsblk -bdnro SIZE "$root")
# Legacy geometry is not made dependent on repart success.
case "$root_bytes" in
  2684354560) ;;
  4294967296) exit 0 ;;
  *) refuse 'unknown root partition size' ;;
esac
root_parent=$(lsblk -dnro PKNAME "$root")
[[ "$root_parent" =~ ^[a-zA-Z0-9._-]+$ ]] || refuse 'invalid boot disk parent'
media_bytes=$(lsblk -bdnro SIZE "/dev/$root_parent")
[[ "$media_bytes" =~ ^[1-9][0-9]{0,14}$ ]] || refuse 'invalid boot media capacity'
(( media_bytes >= CERALIVE_COMPACT_MIN_MEDIA_BYTES )) || capacity_refuse "boot media needs at least $CERALIVE_COMPACT_MIN_MEDIA_BYTES bytes (7 GiB); got $media_bytes"
systemctl is-active --quiet ceralive-grow-data.service || refuse 'partition growth failed or is pending'
systemctl is-active --quiet systemd-growfs@data.service || refuse 'filesystem growth failed or is pending'
[[ "$(findmnt -nro TARGET /data)" == /data ]] || refuse '/data is not mounted'
data=$(readlink -f "$(findmnt -nro SOURCE /data)")
[[ "$root_parent" =~ ^[a-zA-Z0-9._-]+$ && "$(lsblk -dnro PKNAME "$data")" == "$root_parent" ]] || refuse '/data is not on the boot disk'
case "$(lsblk -dnro PARTLABEL "$data")" in data|xdata) ;; *) refuse 'wrong data partition label' ;; esac
[[ "$(findmnt -nro FSTYPE /data)" == ext4 ]] || refuse '/data is not ext4'
[[ ",$(findmnt -nro OPTIONS /data)," == *,rw,* ]] || refuse '/data is not writable'
partition_bytes=$(lsblk -bdnro SIZE "$data")
read -r blocks block_size available < <(stat -f -c '%b %S %a' /data)
[[ "$partition_bytes" =~ ^[1-9][0-9]{0,14}$ && "$blocks" =~ ^[0-9]{1,15}$ && "$block_size" =~ ^[1-9][0-9]{0,5}$ && "$available" =~ ^[0-9]{1,15}$ ]] || refuse 'invalid capacity inventory'
# statfs excludes ext4 overhead from total blocks. Compare the superblock's
# physical filesystem extent, not statfs payload capacity, to the partition.
metadata=$(LC_ALL=C dumpe2fs -h "$data" 2>/dev/null) || refuse 'cannot read data filesystem geometry'
read -r filesystem_blocks filesystem_block_size < <(awk -F: '
  $1=="Block count" {blocks=$2; n++}
  $1=="Block size" {size=$2; m++}
  END {if(n==1 && m==1) print blocks,size}
' <<<"$metadata") || refuse 'invalid data filesystem geometry'
[[ "$filesystem_blocks" =~ ^[1-9][0-9]{0,14}$ && "$filesystem_block_size" =~ ^[1-9][0-9]{0,5}$ ]] || refuse 'invalid data filesystem geometry'
case "$filesystem_block_size" in 1024|2048|4096|8192|16384|32768|65536) ;; *) refuse 'unsupported filesystem block size' ;; esac
(( block_size == filesystem_block_size && filesystem_blocks <= partition_bytes / filesystem_block_size && available <= blocks && blocks <= filesystem_blocks )) || refuse 'inconsistent data filesystem geometry'
(( filesystem_blocks * filesystem_block_size >= partition_bytes - 1048576 )) || refuse 'filesystem has not filled the grown partition'
(( available * block_size >= CERALIVE_DATA_MIN_AVAILABLE_BYTES )) || capacity_refuse 'less than 1 GiB available for update staging'
echo 'data readiness: partition/filesystem growth complete; update staging available'
