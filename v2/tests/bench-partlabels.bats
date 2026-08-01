#!/usr/bin/env bats
#
# CERALIVE_BENCH_LABELS=1 — the opt-in bench PARTLABEL overlay.
#
# A bench microSD is booted on a board whose eMMC is ALREADY flashed with a
# production image, and the production contract selects slots and mounts by
# PARTLABEL (docs/partition-contract.md §3). Two media carrying the SAME
# `boot`/`rootfs_a`/`rootfs_b`/`data` labels make every `PARTLABEL=` lookup on
# the running kernel ambiguous. The overlay renames the bench build's labels to
# `xboot`/`xrootfs_a`/`xrootfs_b`/`xdata`, so a collision is structurally
# impossible.
#
# Two properties are proved here, and the FIRST one is the important one:
#
#   1. UNFLAGGED IS UNCHANGED. The default build still lays the committed
#      pre-overlay GPT baseline (fixtures/gpt-baseline/*.gpt, captured at
#      1af9116) and still writes the frozen production labels into fstab, the
#      RAUC system.conf and the compiled U-Boot selector.
#   2. FLAGGED IS CONSISTENT. With the overlay on, the GPT, fstab, RAUC
#      system.conf and boot selector all name the SAME x-prefixed set — a
#      renamed GPT with an un-renamed fstab would fail on the first mount,
#      which is the whole failure mode this overlay exists to prevent.
#
# Hardware-free; the assembly path is fully offline (`systemd-repart --offline`).

setup() {
  TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  V2="$(cd "$TESTS_DIR/.." && pwd)"
  ASSEMBLE="$V2/lib/assemble-disk.sh"
  VERIFY="$V2/lib/verify-disk.sh"
  BOOT_DIR="$V2/mkosi/platform/boot"
  FIXTURES="$TESTS_DIR/fixtures/gpt-baseline"
}

require_disk_tools() {
  local tool
  for tool in sgdisk systemd-repart; do
    command -v "$tool" >/dev/null 2>&1 || {
      printf 'missing required contract-test tool: %s\n' "$tool" >&2
      return 1
    }
  done
}

# gpt_table <img> — the DETERMINISTIC part of a produced GPT, one line per
# partition: "p<N> <PARTLABEL> start=<sector> size=<sectors>". Partition/disk
# GUIDs are random per run and are deliberately excluded.
gpt_table() {
  local img="$1" count i info
  count="$(sgdisk -p "$img" 2>/dev/null | awk '/^[[:space:]]+[0-9]+[[:space:]]/{c++} END{print c+0}')"
  for (( i = 1; i <= count; i++ )); do
    info="$(sgdisk -i "$i" "$img" 2>/dev/null)"
    printf 'p%s %s start=%s size=%s\n' "$i" \
      "$(sed -n "s/.*Partition name: '\(.*\)'.*/\1/p" <<<"$info")" \
      "$(sed -n 's/.*First sector: \([0-9]*\).*/\1/p' <<<"$info")" \
      "$(sed -n 's/.*Partition size: \([0-9]*\).*/\1/p' <<<"$info")"
  done
}

# install_rootfs_into <root> [env...] — run the platform boot installer against a
# staging root (ROOT=), exactly as v2/mkosi/mkosi.images/platform/mkosi.finalize
# runs it inside the chroot.
install_rootfs_into() {
  local root="$1"; shift
  env ROOT="$root" \
    SERIAL_CONSOLE=ttyS2:1500000 \
    DTB_NAME=rk3588-rock-5b-plus.dtb \
    BOARD_ID=rock-5b-plus \
    COMPATIBLE_STRING=ceralive-rock-5b-plus \
    SINGLE_SLOT_FALLBACK=false \
    "$@" bash "$BOOT_DIR/install-boot.sh" rootfs
}

# --- 1. the unflagged path did not move -------------------------------------

@test "default RK3588 assembly still lays the committed pre-overlay GPT baseline" {
  require_disk_tools
  local ab="$BATS_TEST_TMPDIR/ab.img" ss="$BATS_TEST_TMPDIR/ss.img"

  run bash "$ASSEMBLE" build --output "$ab" --total-mb 10513 --no-format
  [ "$status" -eq 0 ]
  run bash "$ASSEMBLE" build --output "$ss" --total-mb 8192 --no-format --single-slot
  [ "$status" -eq 0 ]

  [ "$(gpt_table "$ab")" = "$(cat "$FIXTURES/rk3588-ab.gpt")" ]
  [ "$(gpt_table "$ss")" = "$(cat "$FIXTURES/rk3588-single-slot.gpt")" ]
}

@test "an unset, empty or non-1 CERALIVE_BENCH_LABELS is the production label set" {
  require_disk_tools
  local value
  for value in "" 0 true yes 11 x; do
    local image="$BATS_TEST_TMPDIR/off-${value:-unset}.img"
    run env CERALIVE_BENCH_LABELS="$value" \
      bash "$ASSEMBLE" build --output "$image" --total-mb 10513 --no-format
    [ "$status" -eq 0 ]
    [ "$(gpt_table "$image")" = "$(cat "$FIXTURES/rk3588-ab.gpt")" ]
  done
}

@test "default install-boot.sh keeps the production fstab and RAUC slot labels" {
  local root="$BATS_TEST_TMPDIR/root-default"
  run install_rootfs_into "$root"
  [ "$status" -eq 0 ]
  run grep -Fq 'PARTLABEL=boot /boot vfat' "$root/etc/fstab"
  [ "$status" -eq 0 ]
  run grep -Fq 'device=/dev/disk/by-partlabel/rootfs_a' "$root/etc/rauc/system.conf"
  [ "$status" -eq 0 ]
  run grep -Fq 'device=/dev/disk/by-partlabel/rootfs_b' "$root/etc/rauc/system.conf"
  [ "$status" -eq 0 ]
}

@test "default compiled boot selector is byte-identical with the overlay off" {
  command -v mkimage >/dev/null 2>&1 || skip "mkimage (u-boot-tools) not installed"
  local a="$BATS_TEST_TMPDIR/boot-default" b="$BATS_TEST_TMPDIR/boot-off"
  run env SERIAL_CONSOLE=ttyS2:1500000 DTB_NAME=rk3588-rock-5b-plus.dtb \
    BOARD_ID=rock-5b-plus SOURCE_DATE_EPOCH=1700000000 \
    bash "$BOOT_DIR/install-boot.sh" boot-partition "$a"
  [ "$status" -eq 0 ]
  run env SERIAL_CONSOLE=ttyS2:1500000 DTB_NAME=rk3588-rock-5b-plus.dtb \
    BOARD_ID=rock-5b-plus SOURCE_DATE_EPOCH=1700000000 CERALIVE_BENCH_LABELS=0 \
    bash "$BOOT_DIR/install-boot.sh" boot-partition "$b"
  [ "$status" -eq 0 ]
  run cmp -s "$a/boot.scr" "$b/boot.scr"
  [ "$status" -eq 0 ]
  run cmp -s "$a/recovery.scr" "$b/recovery.scr"
  [ "$status" -eq 0 ]
  run grep -aFq 'rootfs_a' "$a/boot.scr"
  [ "$status" -eq 0 ]
  run grep -aFq 'xrootfs_a' "$a/boot.scr"
  [ "$status" -ne 0 ]
}

# --- 2. the flagged path renames every reference site ------------------------

@test "CERALIVE_BENCH_LABELS=1 relabels every RK3588 GPT partition with the x prefix" {
  require_disk_tools
  local ab="$BATS_TEST_TMPDIR/bench-ab.img" ss="$BATS_TEST_TMPDIR/bench-ss.img"

  run env CERALIVE_BENCH_LABELS=1 \
    bash "$ASSEMBLE" build --output "$ab" --total-mb 10513 --no-format
  [ "$status" -eq 0 ]
  run env CERALIVE_BENCH_LABELS=1 \
    bash "$ASSEMBLE" build --output "$ss" --total-mb 8192 --no-format --single-slot
  [ "$status" -eq 0 ]

  local labels
  labels="$(sgdisk -p "$ab" | awk '/^[[:space:]]+[0-9]+[[:space:]]/{print $NF}')"
  [ "$labels" = $'xboot\nxrootfs_a\nxrootfs_b\nxdata' ]
  labels="$(sgdisk -p "$ss" | awk '/^[[:space:]]+[0-9]+[[:space:]]/{print $NF}')"
  [ "$labels" = $'xboot\nxrootfs_a\nxdata' ]
}

@test "the bench overlay moves ONLY the labels — geometry stays the frozen contract" {
  require_disk_tools
  local ab="$BATS_TEST_TMPDIR/geo-ab.img"
  run env CERALIVE_BENCH_LABELS=1 \
    bash "$ASSEMBLE" build --output "$ab" --total-mb 10513 --no-format
  [ "$status" -eq 0 ]

  # Strip the 'x' prefix back off and the table must be the frozen baseline.
  local stripped
  stripped="$(gpt_table "$ab" | sed -E 's/^(p[0-9]+) x/\1 /')"
  [ "$stripped" = "$(cat "$FIXTURES/rk3588-ab.gpt")" ]

  # Non-vacuity: the same comparison MUST fail without the strip, or the test
  # above would pass on an image that was never relabelled at all.
  [ "$(gpt_table "$ab")" != "$(cat "$FIXTURES/rk3588-ab.gpt")" ]
}

@test "CERALIVE_BENCH_LABELS=1 verify-disk asserts the bench label set" {
  require_disk_tools
  local ab="$BATS_TEST_TMPDIR/verify-ab.img" ss="$BATS_TEST_TMPDIR/verify-ss.img"
  run env CERALIVE_BENCH_LABELS=1 \
    bash "$ASSEMBLE" build --output "$ab" --total-mb 10513 --no-format
  [ "$status" -eq 0 ]
  run env CERALIVE_BENCH_LABELS=1 bash "$VERIFY" do_verify "$ab" rock-5b-plus
  [ "$status" -eq 0 ]
  [[ "$output" == *"xrootfs_a"* ]]

  # A bench image must NOT verify against the production contract, and a
  # production image must NOT verify against the bench one.
  run bash "$VERIFY" do_verify "$ab" rock-5b-plus
  [ "$status" -ne 0 ]

  run env CERALIVE_BENCH_LABELS=1 \
    bash "$ASSEMBLE" build --output "$ss" --total-mb 8192 --no-format --single-slot
  [ "$status" -eq 0 ]
  run env CERALIVE_BENCH_LABELS=1 bash "$VERIFY" do_verify "$ss" rock-5b-plus
  [ "$status" -eq 0 ]
  [[ "$output" == *"xrootfs_b ABSENT"* ]]
}

@test "CERALIVE_BENCH_LABELS=1 fstab and RAUC system.conf name the bench labels" {
  local root="$BATS_TEST_TMPDIR/root-bench"
  run install_rootfs_into "$root" CERALIVE_BENCH_LABELS=1
  [ "$status" -eq 0 ]

  run grep -Fq 'PARTLABEL=xboot /boot vfat' "$root/etc/fstab"
  [ "$status" -eq 0 ]
  run grep -Fq 'PARTLABEL=boot ' "$root/etc/fstab"
  [ "$status" -ne 0 ]

  run grep -Fq 'device=/dev/disk/by-partlabel/xrootfs_a' "$root/etc/rauc/system.conf"
  [ "$status" -eq 0 ]
  run grep -Fq 'device=/dev/disk/by-partlabel/xrootfs_b' "$root/etc/rauc/system.conf"
  [ "$status" -eq 0 ]
  run grep -Eq 'by-partlabel/rootfs_[ab]$' "$root/etc/rauc/system.conf"
  [ "$status" -ne 0 ]
}

@test "CERALIVE_BENCH_LABELS=1 compiled selectors boot the bench rootfs labels" {
  command -v mkimage >/dev/null 2>&1 || skip "mkimage (u-boot-tools) not installed"
  local dest="$BATS_TEST_TMPDIR/boot-bench"
  run env SERIAL_CONSOLE=ttyS2:1500000 DTB_NAME=rk3588-rock-5b-plus.dtb \
    BOARD_ID=rock-5b-plus CERALIVE_BENCH_LABELS=1 \
    bash "$BOOT_DIR/install-boot.sh" boot-partition "$dest"
  [ "$status" -eq 0 ]

  local scr
  for scr in boot.scr recovery.scr; do
    run grep -aFq 'setenv cera_root xrootfs_a' "$dest/$scr"
    [ "$status" -eq 0 ]
    run grep -aFq 'setenv cera_root xrootfs_b' "$dest/$scr"
    [ "$status" -eq 0 ]
    run grep -aEq 'setenv cera_root rootfs_[ab]' "$dest/$scr"
    [ "$status" -ne 0 ]
  done

  # The staging dir is mcopy'd wholesale into the FAT boot partition, so the
  # relabelled sources must never be left behind next to the compiled scripts.
  [ ! -e "$dest/boot.scr.cmd" ]
  [ ! -e "$dest/recovery.scr.cmd" ]
}

# --- 3. the chroot consumers resolve the same set ---------------------------

@test "resolve_partlabel is the single label resolver on both the host and chroot tracks" {
  local probe
  for probe in "$V2/lib/common.sh" "$V2/mkosi/customize/postinst-lib.sh"; do
    run bash -c "source '$probe' >/dev/null 2>&1
      printf '%s %s ' \"\$(resolve_partlabel boot)\" \"\$(resolve_partlabel data)\"
      CERALIVE_BENCH_LABELS=1
      printf '%s %s' \"\$(resolve_partlabel boot)\" \"\$(resolve_partlabel data)\""
    [ "$status" -eq 0 ]
    [ "$output" = "boot data xboot xdata" ]
  done
}

@test "the /data fstab entry is resolved, never a hardcoded PARTLABEL=data" {
  # setup_data_persistence writes /etc/fstab, /usr/local/sbin and systemd units
  # in a chroot; the label derivation is contract-checked statically here and the
  # resolver itself is exercised functionally above.
  run grep -Fq 'data_partlabel="$(resolve_partlabel data)"' \
    "$V2/mkosi/customize/postinst-lib.sh"
  [ "$status" -eq 0 ]
  run grep -Fq 'data_partlabel="data"' "$V2/mkosi/customize/postinst-lib.sh"
  [ "$status" -ne 0 ]
}

@test "both RAUC fallback system.conf tracks resolve their slot labels" {
  local track
  for track in "$V2/mkosi/customize/rauc-setup.sh" \
               "$V2/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"; do
    run grep -Eq 'by-partlabel/\$\{(rootfs_a|slot_a)[^}]*\}' "$track"
    [ "$status" -eq 0 ]
    run grep -Eq 'by-partlabel/rootfs_[ab]$' "$track"
    [ "$status" -ne 0 ]
  done
}

@test "CERALIVE_BENCH_LABELS reaches every subimage chroot (env_names + PassEnvironment)" {
  run grep -Fq 'CERALIVE_BENCH_LABELS' "$V2/lib/orchestrate.sh"
  [ "$status" -eq 0 ]
  run grep -Eq '^PassEnvironment=.*CERALIVE_BENCH_LABELS' "$V2/mkosi/mkosi.conf"
  [ "$status" -eq 0 ]
}
