#!/usr/bin/env bash
#
# slot-image-identity.test.sh — the OTA slot image and the factory slot images of
# one rootfs tree must be block-identical except for the ext4 superblocks.
#
# WHY: RAUC adaptive (block-hash-index) updates reuse every 4 KiB block of the
# target slot that matches the bundle. mke2fs seeds the metadata checksums (and
# the directory hash) from the filesystem UUID; the UUID is derived from the slot
# label, so formatting rootfs_a, rootfs_b and the OTA image's neutral label with
# their own UUIDs made nearly every inode-table, directory and bitmap block
# differ, and the update fetched them all. make_slot_image now formats with one
# label-independent seed (metadata_csum_seed) and applies the per-slot UUID with
# `tune2fs -U`, which rewrites superblocks only.
#
# Offline and rootless: small tree, sparse 4096 MiB images, no mount, no root.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "${here}/.." && pwd)"
SLOT_IMAGE="${SLOT_IMAGE:-${repo}/lib/disk/slot-image.sh}"
# shellcheck source=tests/lib/assertions.sh
source "${repo}/tests/lib/assertions.sh"

work=''
finish() {
  local status=$?
  [[ "${status}" -eq 0 || "${FAIL}" -gt 0 ]] || bad "unexpected exit: ${status}"
  [[ -z "${work}" ]] || rm -rf "${work}"
  printf ' RESULT: %d passed, %d failed\n' "${PASS}" "${FAIL}"
  [[ "${FAIL}" -eq 0 ]]
}
trap 'finish; exit $?' EXIT

for tool in mkfs.ext4 tune2fs dumpe2fs e2fsck debugfs python3 sha256sum; do
  command -v "${tool}" >/dev/null 2>&1 || { bad "missing required command: ${tool}"; exit 1; }
done

require_cmd() { command -v "$1" >/dev/null 2>&1 || { printf 'missing required command: %s\n' "$1" >&2; return 1; }; }
# shellcheck source=lib/disk/slot-image.sh
source "${SLOT_IMAGE}"

work="$(mktemp -d "${TMPDIR:-/var/tmp}/slot-image-identity.XXXXXX")" || { bad 'fixture: mktemp'; exit 1; }
export SOURCE_DATE_EPOCH=1700000000
export COMPATIBLE_STRING=identity-test

# A tree with ordinary files, a large indexed (htree) directory, a symlink and
# one multi-block file: enough that inode tables, directory blocks and the
# bitmaps all carry checksums that would expose a differing seed.
tree="${work}/tree"
mkdir -p "${tree}/etc" "${tree}/usr/lib/many" "${tree}/usr/share"
for d in $(seq 1 20); do
  mkdir -p "${tree}/usr/share/pkg${d}"
  for f in $(seq 1 25); do printf 'file %s %s\n' "${d}" "${f}" >"${tree}/usr/share/pkg${d}/f${f}"; done
done
for f in $(seq 1 600); do : >"${tree}/usr/lib/many/entry-with-a-long-name-${f}"; done
ln -s ../usr/share "${tree}/etc/share-link"
yes 'block data' | head -c 1048576 >"${tree}/usr/lib/blob.bin"

# differing_blocks <a> <b> — 4 KiB block numbers whose contents differ.
differing_blocks() {
  python3 -I -c '
import sys
BS = 4096
a, b = sys.argv[1:3]
out = []
n = 0
with open(a, "rb") as fa, open(b, "rb") as fb:
    while True:
        x = fa.read(BS * 256)
        y = fb.read(BS * 256)
        if not x and not y:
            break
        if x != y:
            for i in range(0, max(len(x), len(y)), BS):
                if x[i:i + BS] != y[i:i + BS]:
                    out.append(n + i // BS)
        n += (max(len(x), len(y)) + BS - 1) // BS
print("\n".join(map(str, out)))
' "$1" "$2"
}

# superblock_blocks <image> — primary and backup superblock block numbers.
superblock_blocks() {
  dumpe2fs "$1" 2>/dev/null | sed -nE 's/^[[:space:]]*(Primary|Backup) superblock at ([0-9]+).*/\2/p'
}

field() { dumpe2fs -h "$2" 2>/dev/null | sed -nE "s/^$1:[[:space:]]+//p"; }

build() { # <label> <out>
  SLOT_IMAGE_LABEL="$1" make_slot_image "${tree}" "$2" >/dev/null 2>&1
}

img_a="${work}/rootfs_a.ext4"; img_b="${work}/rootfs_b.ext4"; img_ota="${work}/ota.ext4"
if ! build rootfs_a "${img_a}" || ! build rootfs_b "${img_b}" || ! build rootfs "${img_ota}"; then
  bad 'make_slot_image failed on the fixture tree'
  exit 1
fi
ok 'factory slot A, slot B and the OTA image were built from one tree'

# 1. Each image still carries its own label and a distinct, label-derived UUID.
assert_eq 'slot A label' rootfs_a "$(field 'Filesystem volume name' "${img_a}")"
assert_eq 'slot B label' rootfs_b "$(field 'Filesystem volume name' "${img_b}")"
assert_eq 'OTA image label' rootfs "$(field 'Filesystem volume name' "${img_ota}")"
assert_eq 'slot A UUID' "$(det_uuid identity-test-rootfs_a)" "$(field 'Filesystem UUID' "${img_a}")"
assert_eq 'slot B UUID' "$(det_uuid identity-test-rootfs_b)" "$(field 'Filesystem UUID' "${img_b}")"
assert_eq 'OTA image UUID' "$(det_uuid identity-test-rootfs)" "$(field 'Filesystem UUID' "${img_ota}")"
[[ "$(field 'Filesystem UUID' "${img_a}")" != "$(field 'Filesystem UUID' "${img_b}")" ]] \
  && ok 'slot A and slot B keep distinct filesystem UUIDs' \
  || bad 'slot A and slot B share a filesystem UUID'

# 2. Checksummed metadata with a stored seed, and the filesystems are consistent.
for img in "${img_a}" "${img_b}" "${img_ota}"; do
  features="$(field 'Filesystem features' "${img}")"
  [[ " ${features} " == *' metadata_csum '* && " ${features} " == *' metadata_csum_seed '* ]] \
    && ok "$(basename "${img}") has metadata_csum with a stored checksum seed" \
    || bad "$(basename "${img}") lacks metadata_csum/metadata_csum_seed: ${features}"
  e2fsck -fn "${img}" >/dev/null 2>&1 \
    && ok "$(basename "${img}") passes e2fsck -fn" \
    || bad "$(basename "${img}") fails e2fsck -fn"
done

# 3. The property: only superblocks (primary + backups) differ between slots and
#    the OTA image, so adaptive updates do not refetch inode tables or directories.
mapfile -t sb_blocks < <(superblock_blocks "${img_a}")
[[ "${#sb_blocks[@]}" -ge 2 ]] && ok "found ${#sb_blocks[@]} superblock copies" || bad 'no superblock copies found in dumpe2fs output'
for pair in "rootfs_a rootfs_b ${img_a} ${img_b}" "rootfs_a OTA ${img_a} ${img_ota}" "rootfs_b OTA ${img_b} ${img_ota}"; do
  read -r n1 n2 f1 f2 <<<"${pair}"
  mapfile -t diff_blocks < <(differing_blocks "${f1}" "${f2}")
  extra=()
  for blk in "${diff_blocks[@]}"; do
    [[ -z "${blk}" ]] && continue
    printf '%s\n' "${sb_blocks[@]}" | grep -qx "${blk}" || extra+=("${blk}")
  done
  if [[ "${#extra[@]}" -eq 0 && "${#diff_blocks[@]}" -gt 0 ]]; then
    ok "${n1} vs ${n2}: ${#diff_blocks[@]} differing blocks, all superblocks"
  else
    bad "${n1} vs ${n2}: ${#extra[@]} non-superblock blocks differ (first: ${extra[*]:0:5})"
  fi
done

# 4. Non-vacuity: formatting each image with its own UUID as the seed, the way
#    make_slot_image used to, must be caught by the same comparison.
old_style() { # <label> <out>
  local u; u="$(det_uuid "identity-test-$1")"
  truncate -s $((4096 * 1024 * 1024)) "$2"
  E2FSPROGS_FAKE_TIME="${SOURCE_DATE_EPOCH}" mkfs.ext4 -q -L "$1" -U "${u}" -E hash_seed="${u}" -d "${tree}" "$2"
}
old_style rootfs_a "${work}/old-a.ext4"
old_style rootfs "${work}/old-ota.ext4"
old_diff="$(differing_blocks "${work}/old-a.ext4" "${work}/old-ota.ext4" | grep -c .)"
[[ "${old_diff}" -gt $((${#sb_blocks[@]} * 10)) ]] \
  && ok "per-UUID seeds differ in ${old_diff} blocks, so the comparison above is not vacuous" \
  || bad "the per-UUID-seed control differs in only ${old_diff} blocks; the comparison cannot catch a regression"
rm -f "${work}"/old-*.ext4

# 5. Reproducible: the same inputs give the same image bytes.
build rootfs_a "${work}/rootfs_a.again.ext4"
assert_eq 'rebuild of slot A is byte-identical' "$(sha256sum <"${img_a}")" "$(sha256sum <"${work}/rootfs_a.again.ext4")"

# 6. The seed does not depend on the label (only on the compatible string).
assert_eq 'seed is label-independent' "$(slot_image_seed_uuid)" "$(SLOT_IMAGE_LABEL=anything slot_image_seed_uuid)"
[[ "$(slot_image_seed_uuid)" != "$(COMPATIBLE_STRING=other slot_image_seed_uuid)" ]] \
  && ok 'seed follows the compatible string' || bad 'seed ignores the compatible string'

[[ "${FAIL}" -eq 0 ]]
