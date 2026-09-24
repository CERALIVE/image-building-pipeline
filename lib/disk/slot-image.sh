#!/usr/bin/env bash
# Shared offline 4096 MiB ext4 slot writer. Sourced by factory assembly and OTA.
# SLOT_IMAGE_LABEL selects the initial filesystem label; the OTA image uses a
# neutral label which the device post-install handler replaces from GPT.

SLOT_IMAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/shared/slot-reserve.sh
source "${SLOT_IMAGE_DIR}/../shared/slot-reserve.sh"

det_uuid() {
  local h; h="$(printf '%s' "$1" | sha256sum | cut -c1-32)"
  printf '%s-%s-%s-%s-%s' "${h:0:8}" "${h:8:4}" "${h:12:4}" "${h:16:4}" "${h:20:12}"
}

# make_slot_image <tree> <out> — caller owns the temporary output lifecycle.
make_slot_image() {
  local tree="$1" out="$2" label="${SLOT_IMAGE_LABEL:-rootfs}" uuid runtime image img_dir img_base
  [[ -d "${tree}" ]] || { printf 'rootfs tree not found: %s\n' "${tree}" >&2; return 1; }
  [[ -n "${label}" ]] || { printf 'empty slot image label\n' >&2; return 1; }
  uuid="$(det_uuid "${COMPATIBLE_STRING:-ceralive}-${label}")"
  truncate -s $((4096 * 1024 * 1024)) "${out}"
  if tar -C "${tree}" -cf /dev/null . 2>/dev/null; then
    require_cmd mkfs.ext4
    mkfs.ext4 -q -L "${label}" -U "${uuid}" -E hash_seed="${uuid}" \
      -d "${tree}" "${out}" || return 1
  else
    if command -v docker >/dev/null 2>&1; then runtime=docker
    elif command -v podman >/dev/null 2>&1; then runtime=podman
    else printf 'rootfs tree is unreadable and no container runtime is available\n' >&2; return 1; fi
    image="${MKOSI_BUILDER_IMAGE:-debian:trixie-slim}"
    img_dir="$(dirname "${out}")"; img_base="$(basename "${out}")"
    "${runtime}" run --rm \
      -e "SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-0}" \
      -e "FS_UUID=${uuid}" -e "FS_LABEL=${label}" \
      -v "${tree}:/rootfs-tree:ro" -v "${img_dir}:/out" "${image}" \
      bash -euo pipefail -c '
        export DEBIAN_FRONTEND=noninteractive
        if ! command -v mkfs.ext4 >/dev/null 2>&1; then
          apt-get update -qq
          apt-get install -y --no-install-recommends \
            -o Dpkg::Options::=--force-unsafe-io e2fsprogs >/dev/null
        fi
        mkfs.ext4 -q -L "${FS_LABEL}" -U "${FS_UUID}" -E hash_seed="${FS_UUID}" \
          -d /rootfs-tree "/out/'"${img_base}"'"
      ' || return 1
  fi
  slot_reserve_assert_ext4 "${out}" "${label}" || {
    printf 'populated %s fails ext4 available-byte/inode reserve\n' "${label}" >&2
    return 1
  }
  [[ "$(stat -c '%s' "${out}")" == "$((4096 * 1024 * 1024))" ]]
}
