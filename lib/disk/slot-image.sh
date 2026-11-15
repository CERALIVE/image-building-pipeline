#!/usr/bin/env bash
# Shared offline 4096 MiB ext4 slot writer. Sourced by factory assembly and OTA.
# SLOT_IMAGE_LABEL selects the initial filesystem label; the OTA image uses a
# neutral label which the device post-install handler replaces from GPT.
#
# Block-level identity. Every slot image is formatted with ONE label-independent
# checksum seed and directory hash seed (slot_image_seed_uuid); the per-slot
# filesystem UUID is applied afterwards with `tune2fs -U`. With metadata_csum_seed
# that rewrites the superblock (primary and backups) only, so factory slots and the
# OTA image of the same tree differ in a handful of blocks instead of nearly every
# inode-table, directory and bitmap block. That keeps RAUC adaptive
# (block-hash-index) updates from fetching metadata the slot already holds.
# shellcheck disable=SC2016 # Single-quoted script expands inside the container.

SLOT_IMAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/shared/slot-reserve.sh
source "${SLOT_IMAGE_DIR}/../shared/slot-reserve.sh"

det_uuid() {
  local h; h="$(printf '%s' "$1" | sha256sum | cut -c1-32)"
  printf '%s-%s-%s-%s-%s' "${h:0:8}" "${h:8:4}" "${h:12:4}" "${h:16:4}" "${h:20:12}"
}

# slot_image_seed_uuid — the label-independent UUID that seeds the metadata
# checksums and the directory hash of every slot image. Only the compatible string
# feeds it, so a rootfs_a, rootfs_b and OTA image of one tree share their blocks.
slot_image_seed_uuid() {
  det_uuid "${COMPATIBLE_STRING:-ceralive}-slot-image-seed"
}

# inject_boot_payload <ext4-image> <payload-dir> — add the compiled boot.scr and its
# SHA-256 line (install-boot.sh boot-payload) under /usr/lib/ceralive/boot/ of a finished
# slot image, for ceralive-boot-script-sync. Done on the image, not the tree: the tree is
# mkosi output and may be root-owned or unreadable to this user.
inject_boot_payload() {
  local img="$1" dir="$2" cmds epoch dest=/usr/lib/ceralive/boot
  require_cmd debugfs
  require_cmd e2fsck
  [[ -f "${dir}/boot.scr" && -f "${dir}/boot.scr.sha256" ]] \
    || { printf 'boot payload incomplete in %s\n' "${dir}" >&2; return 1; }
  epoch="$(date -u -d "@${SOURCE_DATE_EPOCH:-0}" +%Y%m%d%H%M%S)" || return 1
  cmds="$(mktemp)" || return 1
  {
    printf 'set_current_time %s\n' "${epoch}"
    printf 'mkdir %s\n' "${dest}"
    printf 'cd %s\n' "${dest}"
    printf 'write %s boot.scr\n' "${dir}/boot.scr"
    printf 'write %s boot.scr.sha256\n' "${dir}/boot.scr.sha256"
    printf 'sif %s mode 040755\nsif %s uid 0\nsif %s gid 0\n' "${dest}" "${dest}" "${dest}"
    local f
    for f in boot.scr boot.scr.sha256; do
      printf 'sif %s mode 0100644\nsif %s uid 0\nsif %s gid 0\n' "${f}" "${f}" "${f}"
    done
  } >"${cmds}"
  debugfs -w -f "${cmds}" "${img}" >/dev/null 2>&1 || { rm -f "${cmds}"; return 1; }
  rm -f "${cmds}"
  local name
  for name in boot.scr boot.scr.sha256; do
    debugfs -R "cat ${dest}/${name}" "${img}" 2>/dev/null | cmp -s - "${dir}/${name}" \
      || { printf 'boot payload %s did not read back from %s\n' "${name}" "${img}" >&2; return 1; }
  done
  e2fsck -fn "${img}" >/dev/null 2>&1 \
    || { printf 'ext4 check failed after the boot payload injection\n' >&2; return 1; }
}

# make_slot_image <tree> <out> — caller owns the temporary output lifecycle.
make_slot_image() {
  local tree="$1" out="$2" label="${SLOT_IMAGE_LABEL:-rootfs}" uuid seed runtime image img_dir img_base
  [[ -d "${tree}" ]] || { printf 'rootfs tree not found: %s\n' "${tree}" >&2; return 1; }
  [[ -n "${label}" ]] || { printf 'empty slot image label\n' >&2; return 1; }
  uuid="$(det_uuid "${COMPATIBLE_STRING:-ceralive}-${label}")"
  seed="$(slot_image_seed_uuid)"
  truncate -s $((4096 * 1024 * 1024)) "${out}"
  if tar -C "${tree}" -cf /dev/null . 2>/dev/null; then
    require_cmd mkfs.ext4
    require_cmd tune2fs
    # Older mke2fs ignores SOURCE_DATE_EPOCH but honors its own clock override.
    E2FSPROGS_FAKE_TIME="${SOURCE_DATE_EPOCH:-0}" mkfs.ext4 -q -L "${label}" -U "${seed}" \
      -O metadata_csum,metadata_csum_seed -E hash_seed="${seed}" \
      -d "${tree}" "${out}" || return 1
    E2FSPROGS_FAKE_TIME="${SOURCE_DATE_EPOCH:-0}" tune2fs -U "${uuid}" "${out}" >/dev/null || return 1
  else
    if command -v docker >/dev/null 2>&1; then runtime=docker
    elif command -v podman >/dev/null 2>&1; then runtime=podman
    else printf 'rootfs tree is unreadable and no container runtime is available\n' >&2; return 1; fi
    image="${MKOSI_BUILDER_IMAGE:-debian:trixie-slim}"
    img_dir="$(dirname "${out}")"; img_base="$(basename "${out}")"
    "${runtime}" run --rm \
      -e "SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-0}" \
      -e "E2FSPROGS_FAKE_TIME=${SOURCE_DATE_EPOCH:-0}" \
      -e "FS_UUID=${uuid}" -e "FS_SEED=${seed}" -e "FS_LABEL=${label}" \
      -v "${tree}:/rootfs-tree:ro" -v "${img_dir}:/out" "${image}" \
      bash -euo pipefail -c '
        export DEBIAN_FRONTEND=noninteractive
        if ! command -v mkfs.ext4 >/dev/null 2>&1 || ! command -v tune2fs >/dev/null 2>&1; then
          apt-get update -qq
          apt-get install -y --no-install-recommends \
            -o Dpkg::Options::=--force-unsafe-io e2fsprogs >/dev/null
        fi
        mkfs.ext4 -q -L "${FS_LABEL}" -U "${FS_SEED}" \
          -O metadata_csum,metadata_csum_seed -E hash_seed="${FS_SEED}" \
          -d /rootfs-tree "/out/'"${img_base}"'"
        tune2fs -U "${FS_UUID}" "/out/'"${img_base}"'" >/dev/null
      ' || return 1
  fi
  if [[ -n "${CERALIVE_BOOT_PAYLOAD_DIR:-}" ]]; then
    inject_boot_payload "${out}" "${CERALIVE_BOOT_PAYLOAD_DIR}" || return 1
  fi
  slot_reserve_assert_ext4 "${out}" "${label}" || {
    printf 'populated %s fails ext4 available-byte/inode reserve\n' "${label}" >&2
    return 1
  }
  [[ "$(stat -c '%s' "${out}")" == "$((4096 * 1024 * 1024))" ]]
}
