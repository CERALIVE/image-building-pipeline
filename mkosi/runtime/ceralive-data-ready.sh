#!/usr/bin/env bash
# ROCK root profiles require completed growth and usable update staging.
set -euo pipefail
# shellcheck source=mkosi/runtime/ceralive-data-capacity-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/ceralive-data-capacity-lib.sh"
# A fixed, numeric-only receipt in volatile storage; never expose journals or paths.
reason=readiness-failed
status_file=${CERALIVE_DATA_STATUS_FILE:-/run/ceralive-data-status}
record_status() {
  local rc=$?
  if (( rc != 0 )); then
    ( umask 022
      printf '%s %s %s %s %s\n' "$reason" "${media_bytes:-unknown}" \
        "${partition_bytes:-unknown}" "${filesystem_bytes:-unknown}" "${available_bytes:-unknown}" >"${status_file}.tmp"
      mv -f "${status_file}.tmp" "$status_file"
    ) || true
  else
    rm -f "$status_file"
  fi
}
trap record_status EXIT
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
[[ "$root_bytes" == 4294967296 ]] || refuse 'unsupported root partition size'
minimum_media=$CERALIVE_MIN_MEDIA_BYTES
root_parent=$(lsblk -dnro PKNAME "$root")
[[ "$root_parent" =~ ^[a-zA-Z0-9._-]+$ ]] || refuse 'invalid boot disk parent'
media_bytes=$(lsblk -bdnro SIZE "/dev/$root_parent")
[[ "$media_bytes" =~ ^[1-9][0-9]{0,14}$ ]] || refuse 'invalid boot media capacity'
reason=media-too-small
(( media_bytes >= minimum_media )) || capacity_refuse "boot media needs at least $minimum_media measured bytes; got $media_bytes"
reason=partition-growth
systemctl is-active --quiet ceralive-grow-data.service || refuse 'partition growth failed or is pending'
reason=filesystem-growth
systemctl is-active --quiet systemd-growfs@data.service || refuse 'filesystem growth failed or is pending'
reason='data-unusable'
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
reason=filesystem-incomplete
filesystem_bytes=$((filesystem_blocks * filesystem_block_size))
available_bytes=$((available * block_size))
(( filesystem_blocks * filesystem_block_size >= partition_bytes - 1048576 )) || refuse 'filesystem has not filled the grown partition'
reason='data-full'
(( available * block_size >= CERALIVE_DATA_MIN_AVAILABLE_BYTES )) || capacity_refuse 'less than 1 GiB available for update staging'
echo 'data readiness: partition/filesystem growth complete; update staging available'
