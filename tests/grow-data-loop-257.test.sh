#!/usr/bin/env bash
# Privileged, opt-in: execute the shipped growth path on a disposable loop disk.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $EUID == 0 ]] || { echo 'run as root (loop devices required)' >&2; exit 1; }
repart=${CERALIVE_REPART_TEST_BINARY:?select an extracted builder systemd-repart wrapper}
[[ "$($repart --version)" == 'systemd 257 '* ]]
work=$(mktemp -d)
loop=""
trap '[[ -z "$loop" ]] || losetup -d "$loop"; rm -rf "$work"' EXIT
bash lib/assemble-disk.sh build --board rock-5b-plus --output "$work/disk" --no-format
# Fill the bootloader gap and seed boot/root sentinels, sparsely
# within the large roots, then hash whole partitions (including their holes).
python3 - "$work/disk" <<'PY'
import sys
with open(sys.argv[1], 'r+b') as f:
    f.seek(34*512); f.write(bytes(range(256))*((32768-34)*2))
    for sector in (32768,557056,5799936):
        f.seek(sector*512); f.write(b'partition-sentinel'*4096)
PY
truncate -s 8G "$work/disk"
loop=$(losetup --find --show --partscan "$work/disk")
source mkosi/runtime/ceralive-grow-data.sh
# Mock boot-root discovery only; table reads, validation and repart are real.
findmnt() { echo "${loop}p2"; }
# util-linux versions without PARTN support still expose the kernel's number.
# Read real sysfs partition numbers, and deliberately emit the hardware order.
lsblk() {
  if [[ "$*" == --bytes* ]]; then
    for n in ${CERALIVE_GROW_TEST_ORDER:-3 1 4 2}; do
      node="${loop}p$n"
      command lsblk -bdnro TYPE,PARTLABEL,PARTTYPE,SIZE "$node" | awk -v n="$n" -v start="$(cat "/sys/class/block/${node##*/}/start")" '{print $0, n, start}'
    done
  else command lsblk "$@"; fi
}
systemd-repart() { "$repart" "$@"; }
snapshot() {
  dd if="$loop" bs=512 skip=34 count=$((32768-34)) status=none | sha256sum >"$work/$1.gap"
  for n in 1 2 3; do
    sha256sum "${loop}p$n" | awk '{print $1}' >"$work/$1.bytes$n"
    sgdisk -i "$n" "$loop" >"$work/$1.entry$n"
  done
}
snapshot before
(grow_data_main data)
snapshot after
printf 'gap before/after: '
cat "$work/before.gap" "$work/after.gap"
for name in gap bytes1 bytes2 bytes3 entry1 entry2 entry3; do cmp "$work/before.$name" "$work/after.$name"; done
# Includes GPT CRC/end placement validation, and full-card data growth.
sgdisk -v "$loop" | tee "$work/verify"
grep -q 'No problems found' "$work/verify"
last=$(sgdisk -i 4 "$loop" | awk '/Last sector:/{print $3}')
(( last > 8*1024*1024*1024/512-2048 ))
sgdisk --backup="$work/once" "$loop"
(grow_data_main data)
sgdisk --backup="$work/twice" "$loop"
cmp "$work/once" "$work/twice"
snapshot repeated
for name in gap bytes1 bytes2 bytes3 entry1 entry2 entry3; do cmp "$work/before.$name" "$work/repeated.$name"; done
echo 'target257 loop: shuffled inventory, gap and boot/root bytes + GPT entries preserved; data fills disk; idempotent'
