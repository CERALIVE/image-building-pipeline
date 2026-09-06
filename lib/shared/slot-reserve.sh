#!/usr/bin/env bash
# Profile-neutral, offline assertion for CLEAN, populated ext4 slot images.

slot_reserve_assert_values() {
  local slot="$1" available="$2" total_inodes="$3" free_inodes="$4" value
  for value in "${available}" "${total_inodes}" "${free_inodes}"; do
    [[ "${value}" =~ ^(0|[1-9][0-9]{0,14})$ ]] || {
      printf 'slot=%s field=bavail free=%s required=536870912 invalid reserve metadata\n' "${slot}" "${available}" >&2
      return 1
    }
  done
  local required_inodes=$(( (total_inodes + 9) / 10 ))
  (( required_inodes >= 20000 )) || required_inodes=20000
  printf 'slot=%s field=bavail free=%s required=536870912 inode_free=%s inode_required=%s inode_total=%s\n' \
    "${slot}" "${available}" "${free_inodes}" "${required_inodes}" "${total_inodes}"
  (( available >= 536870912 && total_inodes > 0 && free_inodes <= total_inodes && free_inodes >= required_inodes ))
}

slot_reserve_assert_ext4() {
  local image="$1" slot="$2" metadata fields blocks free reserved block_size total_inodes free_inodes value
  metadata="$(LC_ALL=C dumpe2fs -h "${image}" 2>/dev/null)" || {
    printf 'slot=%s field=bavail free=unreadable required=536870912 cannot read ext4 metadata\n' "${slot}" >&2
    return 1
  }
  # Linux v7.2 fs/ext4/super.c: ext4_statfs excludes r_blocks AND s_resv_clusters.
  # Fresh mkfs images have no dirty clusters. Extent reserve is min(blocks/50,4096)
  # on ordinary (non-bigalloc) ext4; reject other/unclean formats rather than guess.
  fields="$(awk -F: '
    { key=$1; value=substr($0,index($0,":")+1); gsub(/^[ \t]+|[ \t]+$/, "", value); fields[key]=value; counts[key]++ }
    END {
      if (fields["Filesystem state"] != "clean" || fields["Filesystem magic number"] != "0xEF53" ||
          fields["Filesystem features"] !~ /(^| )extent( |$)/ || fields["Filesystem features"] ~ /(^| )(bigalloc|needs_recovery)( |$)/) exit 1
      split("Block count,Free blocks,Reserved block count,Block size,Inode count,Free inodes", keys, ",")
      for(i=1;i<=6;i++) {if(counts[keys[i]]!=1 || fields[keys[i]] !~ /^[0-9]+$/) exit 1; printf "%s%s", fields[keys[i]], i==6 ? "\n" : " "}
    }
  ' <<<"${metadata}")" || {
    printf 'slot=%s field=bavail free=unprovable required=536870912 requires clean non-bigalloc ext4\n' "${slot}" >&2
    return 1
  }
  read -r blocks free reserved block_size total_inodes free_inodes <<<"${fields}"
  for value in "${blocks}" "${free}" "${reserved}" "${block_size}" "${total_inodes}" "${free_inodes}"; do
    [[ "${value}" =~ ^(0|[1-9][0-9]{0,9})$ ]] || return 1
  done
  (( blocks > 0 && free <= blocks && reserved <= blocks && block_size >= 1024 && block_size <= 65536 )) || return 1
  local extent_reserve=$(( blocks / 50 )) available_blocks
  (( extent_reserve <= 4096 )) || extent_reserve=4096
  available_blocks=$(( free - reserved - extent_reserve ))
  (( available_blocks >= 0 )) || available_blocks=0
  slot_reserve_assert_values "${slot}" "$((available_blocks * block_size))" "${total_inodes}" "${free_inodes}"
}
