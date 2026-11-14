#!/bin/bash
# systemd 257 matches repart definitions by type and order, not Label.
set -euo pipefail
# shellcheck source=mkosi/runtime/ceralive-data-capacity-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/ceralive-data-capacity-lib.sh"

# Input: lsblk --bytes --raw --paths --output TYPE,PARTLABEL,PARTTYPE,SIZE,PARTN,START (arbitrary order).
# Validate the entire known layout before permitting any disk mutation. Generate
# one ordered definition per existing partition; never invent a missing B slot.
grow_data_definitions() {
  local dest="$1" data_label="$2" prefix kind label type bytes number start extra previous_end=0 index=0 names=""
  case "$data_label" in data) prefix="" ;; xdata) prefix=x ;; *) return 1 ;; esac
  local generic=0fc63daf-8483-4772-8e79-3d69d8477de4
  local boot=bc13c2ff-59e6-4262-a352-b275fd6f7172 expected_type conf
  while read -r kind label type bytes number start extra; do
    [[ "$kind" != disk ]] || continue
    [[ "$kind" == part && "$bytes" =~ ^[0-9]+$ && "$number" =~ ^[0-9]+$ ]] || return 1
    [[ "$start" =~ ^[1-9][0-9]{0,15}$ && -z "$extra" ]] || return 1
    (( number == index + 1 )) || return 1
    (( bytes >= 268435456 && bytes % 4096 == 0 )) || return 1
    # START is always in 512-byte sectors, including on 4K-sector devices.
    # Partition numbers alone cannot establish physical order or non-overlap.
    (( start >= previous_end )) || return 1
    previous_end=$((start + bytes / 512))
    expected_type="$generic"
    case "$label" in
      "${prefix}boot") expected_type="$boot"; [[ "$bytes" == 268435456 ]] || return 1 ;;
      "${prefix}rootfs_a"|"${prefix}rootfs_b")
        [[ "$bytes" == 4294967296 ]] || return 1 ;;
      "$data_label") ;;
      *) return 1 ;;
    esac
    [[ "${type,,}" == "$expected_type" ]] || return 1
    index=$((index + 1))
    names+="${label} "
    printf -v conf '%s/%02d.conf' "$dest" "$index"
    {
      printf '[Partition]\nType=%s\nSizeMinBytes=%s\n' "$type" "$bytes"
      if [[ "$label" != "$data_label" ]]; then printf 'SizeMaxBytes=%s\n' "$bytes"; fi
      # No Format, CopyFiles or Label: preserve existing contents and identity.
    } >"$conf"
  done < <(LC_ALL=C sort -k5,5n)
  [[ "$names" == "${prefix}boot ${prefix}rootfs_a ${prefix}rootfs_b ${data_label} " \
    || "$names" == "${prefix}boot ${prefix}rootfs_a ${data_label} " ]]
}

grow_data_is_block_device() { [[ -b "$1" ]]; }

grow_data_main() {
  local data_label="$1" root parent disk table root_label prefix media root_bytes minimum ro
  case "$data_label" in data) prefix="" ;; xdata) prefix=x ;; *) return 1 ;; esac
  root="$(findmnt -nro SOURCE /)"
  root="$(readlink -f "$root")"
  grow_data_is_block_device "$root" || return 1
  root_label="$(lsblk -dnro PARTLABEL "$root")"
  [[ "$root_label" == "${prefix}rootfs_a" || "$root_label" == "${prefix}rootfs_b" ]] || return 1
  parent="$(lsblk -dnro PKNAME "$root")"
  [[ "$parent" =~ ^[a-zA-Z0-9._-]+$ ]] || return 1
  disk="/dev/$parent"
  grow_data_is_block_device "$disk" || return 1
  # Refuse before repart can write GPT or touch an already failing card.
  root_bytes=$(lsblk -bdnro SIZE "$root")
  [[ "$root_bytes" == 4294967296 ]] || return 1
  minimum=$CERALIVE_MIN_MEDIA_BYTES
  media=$(lsblk -bdnro SIZE "$disk")
  [[ "$media" =~ ^[1-9][0-9]{0,14}$ ]] || return 1
  (( media >= minimum )) || { echo 'Refusing to grow data: card too small' >&2; return 78; }
  ro=$(lsblk -dnro RO "$disk")
  [[ "$ro" == 0 ]] || { echo 'Refusing to grow data: card read-only or unknown' >&2; return 78; }
  table="$(lsblk --bytes --noheadings --raw --paths --sort PARTN --output TYPE,PARTLABEL,PARTTYPE,SIZE,PARTN,START "$disk")"
  GROW_DATA_DEFS="$(mktemp -d /run/ceralive-grow-data.XXXXXX)"
  trap 'rm -rf -- "$GROW_DATA_DEFS"' EXIT
  grow_data_definitions "$GROW_DATA_DEFS" "$data_label" <<<"$table" || {
    echo 'Refusing to grow data: unexpected boot-disk partition layout' >&2
    return 1
  }
  # Repart otherwise discards unallocated space, including the raw bootloader.
  systemd-repart --definitions="$GROW_DATA_DEFS" --empty=refuse --dry-run=no --discard=no "$disk"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then grow_data_main "${1:?data partition label required}"; fi
