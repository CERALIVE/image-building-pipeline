#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source lib/shared/layout.sh
[[ "$(BOARD_ID=rock-5b-plus ceralive_min_media_bytes)" == 15000000000 ]]
grep -q 'Unsupported root partition geometry' mkosi/runtime/ceralive-layout-install-check.sh
if grep -q 'CERALIVE_LAYOUT_PROFILE' lib/shared/layout.sh; then exit 1; fi

# Exercise the real install-check against the same geometry and device mapping
# as the privileged RAUC fixture, without mounting devices on this host.
source tests/real-rauc-fixture-lib.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
rauc_fixture_slot_images "$work"
rauc_fixture_gpt "$work"
for part in 1 2; do
  sectors=$(sgdisk -i "$part" "$work/gpt.raw" | awk '/Partition size:/{print $3}')
  [[ "$((sectors * 512))" == 4294967296 ]]
done
rauc_fixture_device_map "$work" "$work/slot-a.ext4" "$work/slot-b.ext4"
[[ "$(PATH="$work/bin:$PATH" readlink -f /dev/disk/by-partlabel/rootfs_a)" == "$work/slot-a.ext4" ]]
ln -s slot-a.ext4 "$work/unrelated"
[[ "$(PATH="$work/bin:$PATH" readlink -f "$work/unrelated")" == "$work/slot-a.ext4" ]]
# Only the block-device I/O is replaced: validate actual sparse fixture bytes.
cat >"$work/bin/lsblk" <<'EOF'
#!/bin/sh
[ "$1" = -bdnro ] && [ "$2" = SIZE ] || exit 2
stat -c %s "$3"
EOF
chmod +x "$work/bin/lsblk"
PATH="$work/bin:$PATH" sh mkosi/runtime/ceralive-layout-install-check.sh install-check
for slot in a b; do
  truncate -s 1M "$work/slot-$slot.ext4"
  rc=0
  PATH="$work/bin:$PATH" sh mkosi/runtime/ceralive-layout-install-check.sh install-check >"$work/refused" 2>&1 || rc=$?
  [[ "$rc" == 78 ]]
  grep -q 'expected 4 GiB root slots' "$work/refused"
  rauc_fixture_slot_images "$work"
done
# The mapping can switch to GPT partitions without changing the signed hook.
rauc_fixture_device_map "$work" "$work/unrelated" "$work/slot-b.ext4"
PATH="$work/bin:$PATH" sh mkosi/runtime/ceralive-layout-install-check.sh install-check
echo 'real RAUC fixture geometry and signed install-check boundary pass'
