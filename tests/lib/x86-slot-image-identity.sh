#!/usr/bin/env bash
# Real x86 factory partition versus the OTA writer, without privileged tools.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SOURCE_DATE_EPOCH=1700000000
export COMPATIBLE_STRING=ceralive-x86-minipc
unset CERALIVE_BOOT_PAYLOAD_DIR
# The assembler's help entry only prints usage; its production functions remain.
# shellcheck source=lib/assemble-disk-x86.sh
source "${repo}/lib/assemble-disk-x86.sh" --help >/dev/null
# shellcheck source=lib/disk/slot-image.sh
source "${repo}/lib/disk/slot-image.sh"

for tool in sgdisk mkfs.ext4 tune2fs dumpe2fs python3; do require_cmd "${tool}"; done
work="$(mktemp -d "${TMPDIR:-/var/tmp}/x86-slot-identity.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
export TMPDIR="${work}"
tree="${work}/tree"
mkdir -p "${tree}/etc" "${tree}/usr/lib/many"
printf 'ceralive\n' >"${tree}/etc/hostname"
for n in $(seq 1 600); do
  printf 'file %s\n' "${n}" >"${tree}/usr/lib/many/entry-with-a-long-name-${n}"
done
ln -s ../usr/lib/many "${tree}/etc/files"
ota="${work}/ota.ext4"
SLOT_IMAGE_LABEL=rootfs make_slot_image "${tree}" "${ota}"

# Force only the unreadable-tree decision. The runtime shim executes the real
# container payload with paths translated into this fixture; no daemon runs.
shim="${work}/bin"
mkdir -p "${shim}"
cat >"${shim}/tar" <<'SH'
#!/usr/bin/env bash
exit 1
SH
cat >"${shim}/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == run && "$2" == --rm ]]
shift 2
envs=()
tree='' out=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    -e) envs+=("$2"); shift 2 ;;
    -v)
      case "$2" in
        *:/rootfs-tree:ro) tree="${2%:/rootfs-tree:ro}" ;;
        *:/out) out="${2%:/out}" ;;
        *) exit 2 ;;
      esac
      shift 2 ;;
    *) [[ "$1" == identity-container-contract ]]; shift; break ;;
  esac
done
[[ -d "${tree}" && -d "${out}" && "$1" == bash && "$4" == -c ]]
payload="${5//\/rootfs-tree/${tree}}"
payload="${payload//\/out\//${out}/}"
env "${envs[@]}" "$1" "$2" "$3" "$4" "${payload}"
SH
chmod +x "${shim}/tar" "${shim}/docker"

for mode in native container; do
  disk="${work}/${mode}.raw"
  # Real GPT, p2 at the production x86 offset (1 MiB ESP start + 256 MiB).
  # Keep sentinel bytes on either side of p2 to detect an incorrect dd offset.
  truncate -s 4354M "${disk}"
  sgdisk --clear -n 1:2048:+256M -c 1:boot -t 1:EF00 \
    -n 2:526336:+4096M -c 2:rootfs_a "${disk}" >/dev/null
  printf before | dd of="${disk}" bs=1 seek=$((257 * 1024 * 1024 - 6)) conv=notrunc status=none
  printf after | dd of="${disk}" bs=1 seek=$((4353 * 1024 * 1024)) conv=notrunc status=none
  sgdisk --backup="${work}/gpt-before" "${disk}" >/dev/null
  if [[ "${mode}" == native ]]; then
    populate_rootfs_a "${disk}" "${tree}"
  else
    PATH="${shim}:${PATH}" MKOSI_BUILDER_IMAGE=identity-container-contract \
      populate_rootfs_a "${disk}" "${tree}"
  fi
  sgdisk --backup="${work}/gpt-after" "${disk}" >/dev/null
  cmp "${work}/gpt-before" "${work}/gpt-after"
  [[ "$(stat -c %s "${disk}")" == "$((4354 * 1024 * 1024))" ]]

  # Compare the actual partition bytes in place, rather than a copied formatter.
  # Superblock locations come from the OTA filesystem, not a hard-coded list.
  superblocks="$(dumpe2fs "${ota}" 2>/dev/null |
    sed -nE 's/^[[:space:]]*(Primary|Backup) superblock at ([0-9]+).*/\2/p')"
  python3 - "${disk}" "${ota}" "${mode}" "${superblocks}" <<'PY'
import sys

disk, ota, mode, superblocks = sys.argv[1:]
allowed = {int(block) for block in superblocks.split()}
assert len(allowed) >= 2, allowed
block_size = 4096
slot_size = 4096 * 1024 * 1024
offset = 257 * 1024 * 1024
different: set[int] = set()
with open(disk, "rb") as factory, open(ota, "rb") as bundle:
    factory.seek(offset - 6)
    assert factory.read(6) == b"before", "write before p2"
    for start in range(0, slot_size, block_size * 256):
        a = factory.read(block_size * 256)
        b = bundle.read(block_size * 256)
        assert len(a) == len(b) == block_size * 256, "short slot read"
        if a != b:
            different.update((start + i) // block_size
                             for i in range(0, len(a), block_size)
                             if a[i:i + block_size] != b[i:i + block_size])
    assert factory.read(5) == b"after", "write after p2"
    factory.seek(offset + 1024)
    sb = factory.read(1024)
    assert sb[120:136].rstrip(b"\0") == b"rootfs_a", "factory label changed"
    # Pin the old label-derived identity independently of the production helper.
    assert sb[104:120].hex() == "7cc2e9ed5d6f8fe12d81be9fd4fc88e3", "factory UUID changed"
extra = different - allowed
print(f"{mode} x86 factory vs OTA: {len(different)} differing blocks, "
      f"{len(extra)} non-superblock blocks", flush=True)
assert different and not extra, sorted(extra)[:10]
assert int.from_bytes(sb[96:100], "little") & 0x2000, "metadata_csum_seed absent"
PY
  rm -f "${disk}"
done
disk="${work}/wrong-size.raw"
truncate -s 770M "${disk}"
sgdisk --clear -n 1:2048:+256M -c 1:boot -t 1:EF00 \
  -n 2:526336:+512M -c 2:rootfs_a "${disk}" >/dev/null
before="$(sha256sum <"${disk}")"
if (populate_rootfs_a "${disk}" "${tree}") >"${work}/wrong-size.log" 2>&1; then
  printf 'FAIL x86 accepted a slot outside the frozen size contract\n' >&2
  exit 1
fi
grep -qF 'does not match the frozen 4096 MiB slot' "${work}/wrong-size.log"
[[ "${before}" == "$(sha256sum <"${disk}")" ]]
printf 'PASS x86 rejects wrong-size GPT p2 before writing\n'
printf 'PASS x86 factory native/container metadata identity, UUID, label and geometry\n'
