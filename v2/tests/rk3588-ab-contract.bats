#!/usr/bin/env bats
#
# Rock 5B+ production A/B contract. This suite is deliberately hardware-free:
# it proves the factory image shape that must exist before the real arm64 RAUC
# install/rollback run is allowed to touch a board.

setup() {
  TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  V2="$(cd "$TESTS_DIR/.." && pwd)"
  REPO_ROOT="$(cd "$V2/.." && pwd)"
  ASSEMBLE="$V2/lib/assemble-disk.sh"
  RESOLVE="$V2/lib/resolve.sh"
  PREFLASH="$TESTS_DIR/preflash-verify.sh"
  BOOT_DIR="$V2/mkosi/platform/boot"
}

require_disk_tools() {
  local tool
  for tool in sgdisk systemd-repart mkfs.ext4 debugfs mkfs.vfat mcopy mkimage dumpimage \
    fdtget fdtput sha256sum flock rauc dtc fdtdump cpio; do
    command -v "$tool" >/dev/null 2>&1 || {
      printf 'missing required contract-test tool: %s\n' "$tool" >&2
      return 1
    }
  done
}

part_field() {
  local image="$1" part="$2" key="$3"
  sgdisk -i "$part" "$image" 2>/dev/null |
    sed -n "s/.*${key}: \([0-9][0-9]*\).*/\1/p"
}

write_small_repart_defs() {
  local defs="$1"
  mkdir -p "$defs"
  cp "$V2/mkosi/repart/10-boot.conf" "$defs/10-boot.conf"
  cat >"$defs/20-rootfs_a.conf" <<'EOF'
[Partition]
Type=linux-generic
Label=rootfs_a
Format=ext4
SizeMinBytes=16M
SizeMaxBytes=16M
GrowFileSystem=off
EOF
  cat >"$defs/30-rootfs_b.conf" <<'EOF'
[Partition]
Type=linux-generic
Label=rootfs_b
Format=ext4
SizeMinBytes=16M
SizeMaxBytes=16M
GrowFileSystem=off
EOF
  cat >"$defs/40-data.conf" <<'EOF'
[Partition]
Type=linux-generic
Label=data
Format=ext4
SizeMinBytes=16M
GrowFileSystem=off
EOF
}

make_rootfs_tree() {
  local tree="$1"
  mkdir -p "$tree/sbin" "$tree/etc/rauc" "$tree/boot/dtb/rockchip"
  printf '#!/bin/sh\nexit 0\n' >"$tree/sbin/init"
  chmod +x "$tree/sbin/init"
  printf 'factory-baseline\n' >"$tree/etc/ceralive-ab-baseline"
  cp "$V2/.dev-keys/dev-root-ca.pem" "$tree/etc/rauc/ceralive-keyring.pem"
  truncate -s 8M "$tree/boot/Image"
  printf '\x41\x52\x4d\x64' | dd of="$tree/boot/Image" bs=1 seek=56 conv=notrunc status=none
  printf '/dts-v1/; / { model = "Rock 5B+ contract fixture"; compatible = "radxa,rock-5b-plus"; };\n' \
    | dtc -I dts -O dtb -p 4096 -o "$tree/boot/dtb/rockchip/rk3588-rock-5b-plus.dtb"
  mkdir -p "$tree/.initrd-fixture"
  printf '#!/bin/sh\nexec /sbin/init\n' >"$tree/.initrd-fixture/init"
  chmod +x "$tree/.initrd-fixture/init"
  head -c 2097152 /dev/zero | openssl enc -aes-256-ctr \
    -K 0000000000000000000000000000000000000000000000000000000000000000 \
    -iv 00000000000000000000000000000000 >"$tree/.initrd-fixture/payload"
  (cd "$tree/.initrd-fixture" && find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -n >"../boot/initrd.img")
  rm -rf "$tree/.initrd-fixture"
}

# Rework a rootfs tree's /boot into the REAL Armbian kernel-package layout that
# broke check_rootfs_populated: /boot/Image and /boot/dtb become symlinks, and
# the initrd exists ONLY under its versioned name (no bare /boot/initrd.img).
# The plain-file make_rootfs_tree never exercised this, so debugfs's
# terminal-symlink dump bug stayed invisible to the suite.
make_armbian_symlink_rootfs_tree() {
  local tree="$1" ver=6.1.115-vendor-rk35xx
  make_rootfs_tree "$tree"
  mv "$tree/boot/Image" "$tree/boot/vmlinuz-$ver"
  ln -s "vmlinuz-$ver" "$tree/boot/Image"
  mv "$tree/boot/dtb" "$tree/boot/dtb-$ver"
  ln -s "dtb-$ver" "$tree/boot/dtb"
  mv "$tree/boot/initrd.img" "$tree/boot/initrd.img-$ver"
}

slot_contains_init() {
  local image="$1" part="$2" slot="$3"
  local start size slice
  start="$(part_field "$image" "$part" 'First sector')"
  size="$(part_field "$image" "$part" 'Partition size')"
  slice="$BATS_TEST_TMPDIR/${slot}.ext4"
  dd if="$image" of="$slice" bs=512 skip="$start" count="$size" conv=sparse status=none
  debugfs -R 'stat /sbin/init' "$slice" 2>/dev/null | grep -q 'Inode:'
}

build_preflash_fixture() { build_preflash_fixture_variant preflash make_rootfs_tree; }

# build_preflash_fixture_variant <slug> <tree_fn> — assemble a full, signed
# rock-5b-plus factory image + bundle into $BATS_FILE_TMPDIR/<slug>, populating
# both rootfs slots from <tree_fn>. Default (preflash/make_rootfs_tree) feeds the
# plain-file positives and negatives; the armbian-symlink variant proves the gate
# passes on the real symlink /boot layout.
build_preflash_fixture_variant() {
  local slug="$1" tree_fn="$2"
  local base="$BATS_FILE_TMPDIR/$slug"
  (
    flock 9
    [ -s "$base/image.raw" ] && exit 0
    mkdir -p "$base/bsp"
    "$tree_fn" "$base/rootfs"
    ROOT="$base/rootfs" SERIAL_CONSOLE=ttyS2:1500000 \
      DTB_NAME=rk3588-rock-5b-plus.dtb BOARD_ID=rock-5b-plus \
      COMPATIBLE_STRING=ceralive-rock-5b-plus SINGLE_SLOT_FALLBACK=false \
      bash "$BOOT_DIR/install-boot.sh" rootfs >/dev/null
    truncate -s 4096 "$base/fit-payload.bin"
    cat >"$base/fit.its" <<'EOF'
/dts-v1/;
/ {
  description = "CeraLive contract FIT";
  images {
    firmware {
      description = "U-Boot contract payload";
      data = /incbin/("fit-payload.bin");
      type = "firmware";
      arch = "arm64";
      compression = "none";
      hash { algo = "sha256"; };
    };
  };
  configurations {
    default = "conf";
    conf { firmware = "firmware"; };
  };
};
EOF
    (cd "$base" && mkimage -f fit.its u-boot.itb >/dev/null)
    cat >"$base/write-bootloader" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
image=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --image) image="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$image" ]
base="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
printf 'RKNS' | dd of="$image" bs=512 seek=64 conv=notrunc status=none
dd if="$base/u-boot.itb" of="$image" bs=512 seek=16384 conv=notrunc status=none
EOF
    chmod +x "$base/write-bootloader"
    env WRITE_BOOTLOADER_SH="$base/write-bootloader" \
      SOURCE_DATE_EPOCH=1700000000 DTB_NAME=rk3588-rock-5b-plus.dtb \
      SERIAL_CONSOLE=ttyS2:1500000 COMPATIBLE_STRING=ceralive-rock-5b-plus \
      bash "$ASSEMBLE" build --output "$base/image.raw" --total-mb 10513 \
        --bootloader-adapter custom --board rock-5b-plus --bsp-dir "$base/bsp" \
        --rootfs-tree "$base/rootfs" >/dev/null
    COMPATIBLE_STRING=ceralive-rock-5b-plus BUNDLE_VERSION=contract \
      BUNDLE_OUT_DIR="$base" BUNDLE_TS=update CERALIVE_RAUC_PKI_DIR="$V2/.dev-keys" \
      REPRODUCIBLE=1 bash "$V2/lib/build-bundle.sh" rock-5b-plus "$base/rootfs" >/dev/null
    cp "$V2/.dev-keys/dev-root-ca.pem" "$base/keyring.pem"
  ) 9>"$BATS_FILE_TMPDIR/.$slug.lock"
}

build_missing_artifact_image() {
  local artifact="$1" output="$2" base="$BATS_FILE_TMPDIR/preflash" tree="$BATS_TEST_TMPDIR/rootfs-missing"
  local defs="$BATS_TEST_TMPDIR/repart-missing"
  build_preflash_fixture
  cp -a --sparse=always "$base/rootfs" "$tree"
  rm -f "$tree/$artifact"
  if [[ "$artifact" == etc/rauc/ceralive-keyring.pem ]]; then
    cp "$V2/mkosi/runtime/rauc/ceralive-keyring.pem" "$tree/$artifact"
  fi
  write_small_repart_defs "$defs"
  env REPART_DIR="$defs" WRITE_BOOTLOADER_SH="$base/write-bootloader" \
    SOURCE_DATE_EPOCH=1700000000 DTB_NAME=rk3588-rock-5b-plus.dtb \
    SERIAL_CONSOLE=ttyS2:1500000 COMPATIBLE_STRING=ceralive-rock-5b-plus \
    bash "$ASSEMBLE" build --output "$output" --total-mb 10513 \
      --bootloader-adapter custom --board rock-5b-plus --bsp-dir "$base/bsp" \
      --rootfs-tree "$tree" >/dev/null
}

@test "rock-5b-plus resolves the production rk3588 A/B contract" {
  run bash "$RESOLVE" rock-5b-plus
  [ "$status" -eq 0 ]
  [[ "$output" == *"PARTITION_TEMPLATE='rk3588-ab'"* ]]
  [[ "$output" == *"RAUC_BOOTLOADER_ADAPTER='custom'"* ]]
  [[ "$output" == *"SINGLE_SLOT_FALLBACK='false'"* ]]
}

@test "rk3588 A/B geometry has unique ordered labels and frozen slot sizes" {
  require_disk_tools
  local image="$BATS_TEST_TMPDIR/rk3588-ab.img"
  run bash "$ASSEMBLE" build --output "$image" --total-mb 10513 --no-format
  [ "$status" -eq 0 ]

  local labels
  labels="$(sgdisk -p "$image" | awk '/^[[:space:]]+[0-9]+[[:space:]]/{print $NF}')"
  [ "$labels" = $'boot\nrootfs_a\nrootfs_b\ndata' ]
  [ "$(printf '%s\n' "$labels" | sort -u | wc -l)" -eq 4 ]
  [ "$(part_field "$image" 1 'First sector')" -eq 32768 ]
  [ "$(part_field "$image" 2 'Partition size')" -eq 8388608 ]
  [ "$(part_field "$image" 3 'Partition size')" -eq 8388608 ]
  [ "$(part_field "$image" 4 'Partition size')" -ge 4194304 ]
}

@test "rk3588 A/B assembly refuses media below the exact 10513 MiB floor" {
  require_disk_tools
  run bash "$ASSEMBLE" build \
    --output "$BATS_TEST_TMPDIR/too-small.img" --total-mb 10512 --no-format
  [ "$status" -ne 0 ]
  [[ "$output" == *"A/B layout requires at least 10513 MiB"* ]]
}

@test "default RK3588 factory image fits the smallest supported 16 GB target" {
  require_disk_tools
  local image="$BATS_TEST_TMPDIR/default-rk3588-ab.img"
  run bash "$ASSEMBLE" build --output "$image" --no-format
  [ "$status" -eq 0 ]
  [ "$(stat -c '%s' "$image")" -eq $((14800 * 1024 * 1024)) ]
  [ "$(stat -c '%s' "$image")" -le 16000000000 ]
}

@test "factory A/B assembly puts a bootable baseline in both rootfs slots" {
  require_disk_tools
  local defs="$BATS_TEST_TMPDIR/repart" tree="$BATS_TEST_TMPDIR/rootfs"
  local image="$BATS_TEST_TMPDIR/factory-ab.img"
  write_small_repart_defs "$defs"
  make_rootfs_tree "$tree"

  run env REPART_DIR="$defs" SOURCE_DATE_EPOCH=1700000000 \
    bash "$ASSEMBLE" build --output "$image" --total-mb 10513 --no-format \
      --bootloader-adapter efi --rootfs-tree "$tree"
  [ "$status" -eq 0 ]
  slot_contains_init "$image" 2 rootfs_a
  slot_contains_init "$image" 3 rootfs_b
}

@test "RK3588 boot paths identify the booted slot explicitly to RAUC" {
  local uboot_slot_arg="rauc.slot=\${cera_slot}"
  run grep -F "$uboot_slot_arg" "$BOOT_DIR/boot.scr.cmd"
  [ "$status" -eq 0 ]
  run bash "$V2/tests/recovery-script-contract.test.sh"
  [ "$status" -eq 0 ]
}

@test "RK3588 rootfs explicitly and exclusively mounts shared XBOOTLDR state at /boot" {
  local root="$BATS_TEST_TMPDIR/rootfs-boot-mount"
  local conflict="$BATS_TEST_TMPDIR/rootfs-conflicting-boot-mount"
  local state_file_default="STATE_FILE=\"\${CERALIVE_BOOT_STATE_FILE:-/boot/boot_state.txt}\""
  local install_env=(
    SERIAL_CONSOLE=ttyS2:1500000
    DTB_NAME=rk3588-rock-5b-plus.dtb
    BOARD_ID=rock-5b-plus
    COMPATIBLE_STRING=ceralive-rock-5b-plus
    SINGLE_SLOT_FALLBACK=false
  )
  run env ROOT="$root" SERIAL_CONSOLE=ttyS2:1500000 \
    DTB_NAME=rk3588-rock-5b-plus.dtb BOARD_ID=rock-5b-plus \
    COMPATIBLE_STRING=ceralive-rock-5b-plus SINGLE_SLOT_FALLBACK=false \
    bash "$BOOT_DIR/install-boot.sh" rootfs
  [ "$status" -eq 0 ]
  run grep -F 'PARTLABEL=boot /boot vfat rw,nodev,nosuid,noexec,umask=0077,shortname=mixed,errors=remount-ro 0 2' \
    "$root/etc/fstab"
  [ "$status" -eq 0 ]
  run grep -F "$state_file_default" "$root/usr/bin/ceralive-boot-state"
  [ "$status" -eq 0 ]

  run env ROOT="$root" "${install_env[@]}" bash "$BOOT_DIR/install-boot.sh" rootfs
  [ "$status" -eq 0 ]
  [ "$(grep -Fxc 'PARTLABEL=boot /boot vfat rw,nodev,nosuid,noexec,umask=0077,shortname=mixed,errors=remount-ro 0 2' \
    "$root/etc/fstab")" -eq 1 ]

  mkdir -p "$conflict/etc"
  printf '  tmpfs /boot tmpfs defaults 0 0\n' >"$conflict/etc/fstab"
  run env ROOT="$conflict" "${install_env[@]}" bash "$BOOT_DIR/install-boot.sh" rootfs
  [ "$status" -ne 0 ]
  [[ "$output" == *"already has a conflicting /boot mount"* ]]
}

@test "Rock preflash gate requires A/B, both factory slots, and sufficient target media" {
  require_disk_tools
  build_preflash_fixture
  local base="$BATS_FILE_TMPDIR/preflash" bytes
  bytes="$(stat -c '%s' "$base/image.raw")"

  run bash "$PREFLASH" \
    --image "$base/image.raw" --bundle "$base/update.raucb" \
    --board rock-5b-plus --keyring "$base/keyring.pem" \
    --target-size-bytes "$bytes"
  [ "$status" -eq 0 ]
  [[ "$output" == *"GPT geometry: exact A/B starts/sizes and unique labels"* ]]
  [[ "$output" == *"rootfs_b populated + kernel + board DTB + initrd"* ]]
  [[ "$output" == *"Target media capacity"* ]]

  run bash "$PREFLASH" \
    --image "$base/image.raw" --bundle "$base/update.raucb" \
    --board rock-5b-plus --keyring "$base/keyring.pem" \
    --target-size-bytes "$((bytes - 1))"
  [ "$status" -ne 0 ]
  [[ "$output" == *"[FAIL] Target media capacity"* ]]
}

# Regression for the real Armbian kernel-package /boot layout (2026-07-16):
# /boot/Image is a symlink to vmlinuz-<ver> and only the versioned
# /boot/initrd.img-<ver> exists. `debugfs dump -p` does not dereference a
# terminal-component symlink, so the pre-fix gate extracted a 0-byte "kernel"
# and could not find the initrd — failing BOTH factory slots on an image whose
# artifacts are actually intact. Fails without the preflash-verify.sh fix.
@test "Rock preflash gate PASSES on the real Armbian symlink /boot layout" {
  require_disk_tools
  build_preflash_fixture_variant armbian-symlink make_armbian_symlink_rootfs_tree
  local base="$BATS_FILE_TMPDIR/armbian-symlink" bytes
  bytes="$(stat -c '%s' "$base/image.raw")"

  run bash "$PREFLASH" \
    --image "$base/image.raw" --bundle "$base/update.raucb" \
    --board rock-5b-plus --keyring "$base/keyring.pem" \
    --target-size-bytes "$bytes"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[PASS] rootfs_a populated + kernel + board DTB + initrd"* ]]
  [[ "$output" == *"[PASS] rootfs_b populated + kernel + board DTB + initrd"* ]]
}

@test "Rock preflash rejects idblock-only images without a second-stage FIT" {
  require_disk_tools
  build_preflash_fixture
  local base="$BATS_FILE_TMPDIR/preflash" bytes
  bytes="$(stat -c '%s' "$base/image.raw")"

  local corrupt="$BATS_TEST_TMPDIR/no-fit.raw"
  cp --sparse=always "$base/image.raw" "$corrupt"
  dd if=/dev/zero of="$corrupt" bs=512 seek=16384 count=16 conv=notrunc status=none
  run bash "$PREFLASH" \
    --image "$corrupt" --bundle "$base/update.raucb" \
    --board rock-5b-plus --keyring "$base/keyring.pem" \
    --target-size-bytes "$bytes"
  [ "$status" -ne 0 ]
  [[ "$output" == *"second-stage FIT"* ]]
}

@test "Rock preflash rejects factory slots without kernel DTB and initrd" {
  require_disk_tools
  build_preflash_fixture
  local base="$BATS_FILE_TMPDIR/preflash" bytes
  bytes="$(stat -c '%s' "$base/image.raw")"
  local artifact name corrupt
  for artifact in boot/Image boot/dtb/rockchip/rk3588-rock-5b-plus.dtb boot/initrd.img; do
    name="$(basename "$artifact")"
    corrupt="$BATS_TEST_TMPDIR/missing-${name}.raw"
    build_missing_artifact_image "$artifact" "$corrupt"
    run bash "$PREFLASH" \
      --image "$corrupt" --bundle "$base/update.raucb" \
      --board rock-5b-plus --keyring "$base/keyring.pem" \
      --target-size-bytes "$bytes"
    [ "$status" -ne 0 ]
  done
}

@test "Rock preflash rejects rootfs keyrings outside the bundle trust root" {
  require_disk_tools
  build_preflash_fixture
  local base="$BATS_FILE_TMPDIR/preflash" bytes corrupt
  bytes="$(stat -c '%s' "$base/image.raw")"
  corrupt="$BATS_TEST_TMPDIR/mismatched-root.raw"
  build_missing_artifact_image etc/rauc/ceralive-keyring.pem "$corrupt"
  run bash "$PREFLASH" \
    --image "$corrupt" --bundle "$base/update.raucb" \
    --board rock-5b-plus --keyring "$base/keyring.pem" \
    --target-size-bytes "$bytes"
  [ "$status" -ne 0 ]
}

@test "Rock preflash built-in negative self-test rejects bootloader corruption" {
  require_disk_tools
  build_preflash_fixture
  local base="$BATS_FILE_TMPDIR/preflash" bytes
  bytes="$(stat -c '%s' "$base/image.raw")"

  run bash "$PREFLASH" --self-test \
    --image "$base/image.raw" --bundle "$base/update.raucb" \
    --board rock-5b-plus --keyring "$base/keyring.pem" \
    --target-size-bytes "$bytes"
  [ "$status" -eq 0 ]
  [[ "$output" == *"NEGATIVE TEST PASS"* ]]
}

@test "Rock preflash rejects stale out-of-budget boot state" {
  require_disk_tools
  build_preflash_fixture
  local base="$BATS_FILE_TMPDIR/preflash" bytes corrupt state
  bytes="$(stat -c '%s' "$base/image.raw")"
  corrupt="$BATS_TEST_TMPDIR/stale-state.raw"
  state="$BATS_TEST_TMPDIR/boot_state.txt"
  cp --sparse=always "$base/image.raw" "$corrupt"
  printf 'BOOT_ORDER=A B\nBOOT_A_LEFT=99\nBOOT_B_LEFT=3\n' >"$state"
  mcopy -o -i "$corrupt@@16777216" "$state" ::/boot_state.txt

  run bash "$PREFLASH" \
    --image "$corrupt" --bundle "$base/update.raucb" \
    --board rock-5b-plus --keyring "$base/keyring.pem" \
    --target-size-bytes "$bytes"
  [ "$status" -ne 0 ]
  [[ "$output" == *"[FAIL] Boot state"* ]]
}

@test "blocking v2 gate includes boot fallback rollback real RAUC and preflash negatives" {
  run bash "$V2/tests/production-ci-scope-contract.test.sh"
  [ "$status" -eq 0 ]
}

@test "single-slot data overlaps the future B slot, so migration is reflash-only" {
  require_disk_tools
  local single="$BATS_TEST_TMPDIR/single.img" ab="$BATS_TEST_TMPDIR/ab.img"
  run bash "$ASSEMBLE" build --output "$single" --total-mb 8192 --single-slot --no-format
  [ "$status" -eq 0 ]
  run bash "$ASSEMBLE" build --output "$ab" --total-mb 10513 --no-format
  [ "$status" -eq 0 ]

  local single_data_start ab_b_start
  single_data_start="$(part_field "$single" 3 'First sector')"
  ab_b_start="$(part_field "$ab" 3 'First sector')"
  [ "$single_data_start" -eq "$ab_b_start" ]
  run grep -F 'full re-flash' "$REPO_ROOT/docs/partition-contract.md"
  [ "$status" -eq 0 ]
}

# Regression coverage for the proof-5 EDQUOT failure (2026-07-15): the per-slot
# scratch image must live on the persistent output filesystem, never a bare
# `mktemp` /tmp (a fixed 16 GiB tmpfs on the self-hosted runner that a 4 GiB slot
# exhausts), and it must be removed on the `die` failure path — not only after a
# successful dd.

# Emit an mkfs.ext4 shim that intercepts ONLY the rootfs-slot populate call —
# `mkfs.ext4 … -d <tree> <img>` for the exact <tree> this test drives — and
# records its target image (the last arg) to <log>. systemd-repart's own ext4
# formatting also passes -d, but with its private `.#repart*` staging dir, so
# gating on the driven tree keeps repart's calls flowing to the real mkfs.ext4.
# <tail> runs after recording: empty on the success shim (falls through to the
# real mkfs), or `exit 1` on the negative shim (forces the populate `die` path).
write_mkfs_recording_shim() {
  local path="$1" log="$2" tree="$3" real_mkfs="$4" tail="$5"
  cat >"$path" <<EOF
#!/usr/bin/env bash
mine=0 prev=
for a in "\$@"; do
  [[ "\$prev" == "-d" && "\$a" == "$tree" ]] && mine=1
  prev="\$a"
done
if (( mine )); then
  t=
  for t; do :; done
  printf '%s\n' "\$t" >>"$log"
  $tail
fi
exec "$real_mkfs" "\$@"
EOF
  chmod +x "$path"
}

@test "rootfs slot scratch image lands next to the output image, not in TMPDIR" {
  require_disk_tools
  local defs="$BATS_TEST_TMPDIR/repart" tree="$BATS_TEST_TMPDIR/rootfs"
  local outdir="$BATS_TEST_TMPDIR/out-loc"; mkdir -p "$outdir"
  local image="$outdir/scratch-loc.img"
  local faketmp="$BATS_TEST_TMPDIR/fake-tmpfs"; mkdir -p "$faketmp"
  local shim="$BATS_TEST_TMPDIR/shim-loc"; mkdir -p "$shim"
  local log="$BATS_TEST_TMPDIR/mkfs-loc.log"
  write_small_repart_defs "$defs"
  make_rootfs_tree "$tree"

  # Record the populate target, then hand off to the real mkfs.ext4 so the slot is
  # validly populated and the build still succeeds.
  local real_mkfs; real_mkfs="$(command -v mkfs.ext4)"
  write_mkfs_recording_shim "$shim/mkfs.ext4" "$log" "$tree" "$real_mkfs" ""

  # TMPDIR points OUTSIDE the output tree. Unfixed code (bare `mktemp`) honours
  # TMPDIR and lands the scratch there; the fix must ignore TMPDIR and use
  # $(dirname img) — the persistent filesystem the .raw itself lands on.
  run env PATH="$shim:$PATH" TMPDIR="$faketmp" REPART_DIR="$defs" \
    SOURCE_DATE_EPOCH=1700000000 \
    bash "$ASSEMBLE" build --output "$image" --total-mb 10513 --no-format \
      --bootloader-adapter efi --rootfs-tree "$tree"
  [ "$status" -eq 0 ]

  # Both slot populates were seen, and every recorded scratch path sits under the
  # output image's directory and never under TMPDIR (the tmpfs stand-in).
  [ "$(wc -l <"$log")" -eq 2 ]
  local p
  while IFS= read -r p; do
    [[ "$p" == "$outdir/"* ]]
    [[ "$p" != "$faketmp/"* ]]
  done <"$log"

  # And the success path leaves no scratch behind in the output dir.
  run bash -c "ls -A '$outdir' | grep -c '^\.rootfs-slot\.' || true"
  [ "$output" -eq 0 ]
}

@test "a failed mkfs.ext4 populate leaves no leftover rootfs-slot scratch image" {
  require_disk_tools
  local defs="$BATS_TEST_TMPDIR/repart-fail" tree="$BATS_TEST_TMPDIR/rootfs-fail"
  local outdir="$BATS_TEST_TMPDIR/out-fail"; mkdir -p "$outdir"
  local image="$outdir/scratch-fail.img"
  local faketmp="$BATS_TEST_TMPDIR/fake-tmpfs-fail"; mkdir -p "$faketmp"
  local shim="$BATS_TEST_TMPDIR/shim-fail"; mkdir -p "$shim"
  local log="$BATS_TEST_TMPDIR/mkfs-fail.log"
  write_small_repart_defs "$defs"
  make_rootfs_tree "$tree"

  # Let systemd-repart format normally (real mkfs), but fail the FIRST rootfs-slot
  # populate — the exact proof-5 mode (EDQUOT mid-populate), driving
  # populate_rootfs_slot down its `die` path with the scratch already created.
  local real_mkfs; real_mkfs="$(command -v mkfs.ext4)"
  write_mkfs_recording_shim "$shim/mkfs.ext4" "$log" "$tree" "$real_mkfs" \
    'echo "mkfs.ext4: Disk quota exceeded while populating file system" >&2; exit 1'

  run env PATH="$shim:$PATH" TMPDIR="$faketmp" REPART_DIR="$defs" \
    SOURCE_DATE_EPOCH=1700000000 \
    bash "$ASSEMBLE" build --output "$image" --total-mb 10513 --no-format \
      --bootloader-adapter efi --rootfs-tree "$tree"
  # The build must fail (the populate mkfs died)…
  [ "$status" -ne 0 ]

  # …and the scratch image the populate created must be gone wherever it was put.
  # Unfixed code leaked the bare-`mktemp` file into TMPDIR on the `die` path; the
  # fix removes it via the EXIT-driven scratch cleanup.
  [ -s "$log" ]
  local p
  while IFS= read -r p; do
    [ ! -e "$p" ]
  done <"$log"
  run bash -c "ls -A '$outdir' 2>/dev/null | grep -c '^\.rootfs-slot\.' || true"
  [ "$output" -eq 0 ]
}
