#!/usr/bin/env bash
# Compact root profiles require completed growth and usable update staging.
set -euo pipefail
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
systemctl is-active --quiet ceralive-grow-data.service || refuse 'partition growth failed or is pending'
systemctl is-active --quiet systemd-growfs@data.service || refuse 'filesystem growth failed or is pending'
[[ "$(findmnt -nro TARGET /data)" == /data ]] || refuse '/data is not mounted'
data=$(readlink -f "$(findmnt -nro SOURCE /data)")
root_parent=$(lsblk -dnro PKNAME "$root")
[[ "$root_parent" =~ ^[a-zA-Z0-9._-]+$ && "$(lsblk -dnro PKNAME "$data")" == "$root_parent" ]] || refuse '/data is not on the boot disk'
case "$(lsblk -dnro PARTLABEL "$data")" in data|xdata) ;; *) refuse 'wrong data partition label' ;; esac
[[ "$(findmnt -nro FSTYPE /data)" == ext4 ]] || refuse '/data is not ext4'
[[ ",$(findmnt -nro OPTIONS /data)," == *,rw,* ]] || refuse '/data is not writable'
partition_bytes=$(lsblk -bdnro SIZE "$data")
read -r blocks block_size available < <(stat -f -c '%b %S %a' /data)
[[ "$partition_bytes" =~ ^[0-9]+$ && "$blocks" =~ ^[0-9]+$ && "$block_size" =~ ^[0-9]+$ && "$available" =~ ^[0-9]+$ ]] || refuse 'invalid capacity inventory'
# ext4 metadata accounts for a small difference; an old 256 MiB filesystem
# inside a grown partition must never satisfy readiness.
(( blocks * block_size >= partition_bytes * 95 / 100 )) || refuse 'filesystem has not filled the grown partition'
(( available * block_size >= 1073741824 )) || refuse 'less than 1 GiB available for update staging'
echo 'data readiness: partition/filesystem growth complete; update staging available'
