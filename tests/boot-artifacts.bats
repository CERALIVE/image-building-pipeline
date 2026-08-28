#!/usr/bin/env bats
#
# /boot artifact completeness — the contract the U-Boot A/B selector depends on,
# proved for BOTH kernel paths.
#
# WHY THIS FILE EXISTS. A real Rock 5B+ was left in an infinite crash-reboot loop
# by an `edge` (kernel-built-from-source) bench image. BootROM, SPL, U-Boot and the
# CeraLive selector all ran correctly; the selector resolved slot A correctly; then:
#
#     Failed to load '/boot/Image'
#     106449 bytes read in 21 ms          <- the DTB, which WAS present
#     Failed to load '/boot/initrd.img'
#     Starting kernel ...
#     "Synchronous Abort" handler, esr 0x02000000
#
# The rootfs had `vmlinuz-7.2.0-ceralive-rk3588` and no `Image` at all, because the
# two kernel paths populate /boot by DIFFERENT mechanisms:
#
#   vendor  — Armbian's linux-image-* postinst runs `ln -sfv vmlinuz-<rel>
#             /boot/Image` and the package Depends: on initramfs-tools, so the
#             /etc/kernel/postinst.d hook also writes initrd.img-<rel>.
#             linux-dtb-* symlinks /boot/dtb -> dtb-<rel>/.
#   source  — `make bindeb-pkg` emits a postinst that only run-parts an EMPTY
#             /etc/kernel/postinst.d, and ships no Image symlink at all.
#
# One path being complete says nothing about the other. That asymmetry is the
# defect class, so every case below runs against BOTH layouts.
#
# Hardware-free and root-free: the subject is the normalized rootfs tar the build
# already emits, so symlinks and sizes are readable with no loop device.

setup() {
  TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  PIPELINE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
  VERIFY="$PIPELINE_DIR/lib/verify-boot-artifacts.sh"
  RESOLVE_SH="$PIPELINE_DIR/lib/resolve.sh"
  DTB=rk3588-rock-5b-plus.dtb
  SOURCE_REL=7.2.0-ceralive-rk3588
  WORK="$(mktemp -d)"
}

teardown() {
  rm -rf "$WORK"
}

# A raw, self-decompressing ARM64 Linux Image: a 64-byte header whose only field
# any boot loader keys on is the magic 0x644d5241 ("ARM\x64", little-endian) at
# offset 56 (Documentation/arm64/booting.rst §4 "Call the kernel image"). The rest
# is zero-padded to the requested size — the checks under test read the magic, not
# the code0/code1 branch instructions.
_write_arm64_image() {
  local path="$1" bytes="${2:-12000000}"
  {
    head -c 56 /dev/zero
    printf 'ARM\x64'
    head -c $((bytes - 60)) /dev/zero
  } >"$path"
}

# What `make bindeb-pkg` actually ships as vmlinuz-<rel> on arm64: gzip. Only the
# header is load-bearing for the verifier (it never decompresses), so this pads a
# real gzip member out to a realistic kernel size rather than gzipping 12 MB.
_write_gzip_image() {
  local path="$1" bytes="${2:-12000000}"
  {
    printf 'x' | gzip -c
    head -c "$bytes" /dev/zero
  } >"$path"
}

# A rootfs skeleton with the artifact sizes AND the artifact FORMATS the real
# packages produce, so the verifier's size floors and its Image-format check are
# both exercised rather than sidestepped by empty or zero-filled files.
_seed_common() {
  local root="$1" rel="$2"
  mkdir -p "$root/boot"
  _write_arm64_image "$root/boot/vmlinuz-$rel" 12000000
  head -c 250000   /dev/zero >"$root/boot/config-$rel"
  head -c 7000000  /dev/zero >"$root/boot/System.map-$rel"
}

_seed_dtbs() {
  local dir="$1"
  mkdir -p "$dir"
  head -c 106449 /dev/zero >"$dir/$DTB"
  head -c 90000  /dev/zero >"$dir/rk3588s-orangepi-5-plus.dtb"
}

# The Armbian vendor layout, exactly as read off a known-good built image:
# Image -> vmlinuz-<rel>, dtb -> dtb-<rel>/, and only the VERSIONED initrd.
seed_vendor_layout() {
  local root="$WORK/vendor" rel=6.1.115-vendor-rk35xx
  _seed_common "$root" "$rel"
  ln -s "vmlinuz-$rel" "$root/boot/Image"
  _seed_dtbs "$root/boot/dtb-$rel/rockchip"
  ln -sT "dtb-$rel" "$root/boot/dtb"
  head -c 9980030 /dev/zero >"$root/boot/initrd.img-$rel"
  : >"$root/boot/.next"
  printf '%s\n' "$root"
}

# The source-built layout — which since the mainline flip is the PRODUCTION one:
# bindeb-pkg ships DTBs under a real /boot/dtb/<vendor>/ directory (no versioned
# dir, so no symlink to make), the platform layer adds the Image symlink, and
# initramfs-tools writes the initrd. The release string here is the one the
# manifest's default resolve produces; the case at the end of this file fails if
# the two ever drift.
seed_source_layout() {
  local root="$WORK/source" rel=7.2.0-ceralive-rk3588
  _seed_common "$root" "$rel"
  ln -s "vmlinuz-$rel" "$root/boot/Image"
  _seed_dtbs "$root/boot/dtb/rockchip"
  head -c 8000000 /dev/zero >"$root/boot/initrd.img-$rel"
  : >"$root/boot/.next"
  printf '%s\n' "$root"
}

# The exact pre-fix state that reached the board.
seed_broken_source_layout() {
  local root="$WORK/broken" rel=7.2.0-ceralive-rk3588
  _seed_common "$root" "$rel"
  _seed_dtbs "$root/boot/dtb/rockchip"
  printf '%s\n' "$root"
}

pack() {
  local root="$1" tar="$WORK/$(basename "$root").tar"
  tar -cf "$tar" -C "$root" .
  printf '%s\n' "$tar"
}

run_verify() {
  run bash "$VERIFY" "$1" --dtb-name "$DTB"
}

# --- the two shipped layouts both satisfy the selector -----------------------

@test "boot artifacts: the Armbian vendor layout passes (Image/dtb symlinks)" {
  run_verify "$(pack "$(seed_vendor_layout)")"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/boot/Image -> boot/vmlinuz-6.1.115-vendor-rk35xx"* ]]
  [[ "$output" == *"boot/dtb-6.1.115-vendor-rk35xx/rockchip/$DTB"* ]]
  [[ "$output" == *"boot/initrd.img-6.1.115-vendor-rk35xx"* ]]
}

@test "boot artifacts: the source-built layout passes (real dtb dir)" {
  run_verify "$(pack "$(seed_source_layout)")"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/boot/Image -> boot/vmlinuz-7.2.0-ceralive-rk3588"* ]]
  [[ "$output" == *"boot/dtb/rockchip/$DTB"* ]]
  [[ "$output" == *"boot/initrd.img-7.2.0-ceralive-rk3588"* ]]
}

# --- the regression itself ---------------------------------------------------

@test "boot artifacts: the shipped pre-fix source layout is REJECTED" {
  run_verify "$(pack "$(seed_broken_source_layout)")"
  [ "$status" -ne 0 ]
  [[ "$output" == *"/boot/Image is absent"* ]]
  [[ "$output" == *"no /boot/initrd.img-<release>"* ]]
}

@test "boot artifacts: rejecting the pre-fix layout names what IS in /boot" {
  # A bare "missing" verdict sent the last investigation to the bootloader. The
  # listing is what identifies this as a packaging gap in one read.
  run_verify "$(pack "$(seed_broken_source_layout)")"
  [ "$status" -ne 0 ]
  [[ "$output" == *"boot/vmlinuz-7.2.0-ceralive-rk3588"* ]]
}

# --- each artifact is independently load-bearing, on BOTH layouts ------------

@test "boot artifacts: a missing Image fails on either layout" {
  local root
  for root in "$(seed_vendor_layout)" "$(seed_source_layout)"; do
    rm -f "$root/boot/Image"
    run_verify "$(pack "$root")"
    [ "$status" -ne 0 ]
    [[ "$output" == *"/boot/Image is absent"* ]]
  done
}

@test "boot artifacts: an Image symlink dangling inside the rootfs fails" {
  # The failure U-Boot actually reports is identical to an absent file, so a
  # verifier that only checked for the NAME would pass a rootfs that cannot boot.
  local root; root="$(seed_source_layout)"
  rm -f "$root/boot/vmlinuz-7.2.0-ceralive-rk3588"
  run_verify "$(pack "$root")"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a file in this rootfs"* ]]
}

@test "boot artifacts: a truncated kernel fails" {
  local root; root="$(seed_source_layout)"
  head -c 4096 /dev/zero >"$root/boot/vmlinuz-7.2.0-ceralive-rk3588"
  run_verify "$(pack "$root")"
  [ "$status" -ne 0 ]
  [[ "$output" == *"bytes"* ]]
}

# --- the Image must be the RAW format booti can actually start ----------------
#
# Second real board incident, on the OTHER board. With every artifact above
# present and correct, an Orange Pi 5 Plus loaded 15,928,530 bytes of /boot/Image
# and the DTB, then answered:
#
#     Bad Linux ARM64 Image magic!
#
# `md.b 0x00400000 0x40` after the load read `1f 8b 08 00 ...` — gzip. arm64's
# KBUILD_IMAGE defaults to arch/arm64/boot/Image.gz, so `make bindeb-pkg` ships a
# COMPRESSED vmlinuz, and that board's U-Boot (2017.09, no CONFIG_GZIP at all)
# cannot decompress on the way in. Existence and size say nothing about this, so
# the verifier reads the format too.

@test "boot artifacts: a gzip-compressed /boot/Image is REJECTED" {
  local root; root="$(seed_source_layout)"
  _write_gzip_image "$root/boot/vmlinuz-7.2.0-ceralive-rk3588" 16000000
  run_verify "$(pack "$root")"
  [ "$status" -ne 0 ]
  [[ "$output" == *"gzip"* ]]
  [[ "$output" == *"ARM64 Image magic"* ]]
}

@test "boot artifacts: a raw ARM64 Image passes the format check on either layout" {
  local root
  for root in "$(seed_vendor_layout)" "$(seed_source_layout)"; do
    run_verify "$(pack "$root")"
    [ "$status" -eq 0 ]
    [[ "$output" == *"raw ARM64 Image"* ]]
  done
}

@test "boot artifacts: an Image with no ARM64 magic at offset 56 fails" {
  # Not every wrong Image is a recognised compression format — a truncated or
  # byte-shifted one is not, and booti rejects it identically. The check is a
  # POSITIVE assertion on the magic, not a blocklist of signatures.
  local root; root="$(seed_source_layout)"
  head -c 12000000 /dev/zero >"$root/boot/vmlinuz-7.2.0-ceralive-rk3588"
  run_verify "$(pack "$root")"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ARM64 Image magic"* ]]
}

@test "boot artifacts: an xz-compressed /boot/Image is REJECTED and named" {
  local root; root="$(seed_source_layout)"
  { printf '\xfd7zXZ\x00'; head -c 16000000 /dev/zero; } \
    >"$root/boot/vmlinuz-7.2.0-ceralive-rk3588"
  run_verify "$(pack "$root")"
  [ "$status" -ne 0 ]
  [[ "$output" == *"xz"* ]]
}

@test "boot artifacts: a real file /boot/Image is format-checked, not just symlinks" {
  # After the fix the source path ships /boot/Image as a REAL decompressed file
  # rather than a symlink, so the check must resolve both shapes.
  local root; root="$(seed_source_layout)"
  rm -f "$root/boot/Image"
  _write_gzip_image "$root/boot/Image" 16000000
  run_verify "$(pack "$root")"
  [ "$status" -ne 0 ]
  [[ "$output" == *"gzip"* ]]
}

@test "boot artifacts: a missing board DTB fails on either layout" {
  local root
  for root in "$(seed_vendor_layout)" "$(seed_source_layout)"; do
    find "$root/boot" -name "$DTB" -delete
    run_verify "$(pack "$root")"
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not resolve to a file"* ]]
  done
}

@test "boot artifacts: a missing versioned initrd fails on either layout" {
  local root
  for root in "$(seed_vendor_layout)" "$(seed_source_layout)"; do
    rm -f "$root"/boot/initrd.img-*
    run_verify "$(pack "$root")"
    [ "$status" -ne 0 ]
    [[ "$output" == *"initramfs hook never ran"* ]]
  done
}

@test "boot artifacts: a DTB under the wrong SoC-vendor subdir fails" {
  # /boot/dtb/${fdtfile} without the rockchip/ component is the older mistake this
  # path already had once; the selector resolves the subdir, so the check must too.
  local root; root="$(seed_source_layout)"
  mv "$root/boot/dtb/rockchip/$DTB" "$root/boot/dtb/$DTB"
  run_verify "$(pack "$root")"
  [ "$status" -ne 0 ]
}

# --- the producing mechanisms, statically ------------------------------------

@test "platform layer: the source-built kernel gets an Image symlink" {
  local postinst="$PIPELINE_DIR/mkosi/mkosi.images/platform/mkosi.postinst"
  grep -q 'install_kernel_source_boot_artifacts' "$postinst"
  grep -qE 'ln -sfn "vmlinuz-\$\{release\}"' "$postinst"
}

@test "platform layer: initramfs-tools is installed BEFORE the source kernel" {
  # Ordering is the mechanism: the kernel postinst run-parts /etc/kernel/postinst.d,
  # so the hook must already be configured. Reverse these and the initrd is silently
  # never generated — which is exactly what shipped.
  local postinst="$PIPELINE_DIR/mkosi/mkosi.images/platform/mkosi.postinst"
  local initramfs_line kernel_line
  initramfs_line="$(grep -n 'mkosi-install .* initramfs-tools' "$postinst" | head -1 | cut -d: -f1)"
  kernel_line="$(grep -n 'mkosi-install -y --no-install-recommends "\${boot_bsp\[@\]}"' "$postinst" | head -1 | cut -d: -f1)"
  [ -n "$initramfs_line" ]
  [ -n "$kernel_line" ]
  [ "$initramfs_line" -lt "$kernel_line" ]
}

@test "platform layer: the boot-artifact step is a no-op on the vendor path" {
  # The vendor kernel package already does all of this. The gate is the resolved
  # release, which is empty unless a kernel_source variant was selected.
  local postinst="$PIPELINE_DIR/mkosi/mkosi.images/platform/mkosi.postinst"
  run bash -c "
    set -euo pipefail
    BUILDROOT=$WORK/novendor
    mkdir -p \"\$BUILDROOT/boot\"
    KERNEL_SOURCE_KERNEL_RELEASE=''
    $(sed -n '/^install_kernel_source_boot_artifacts()/,/^}/p' "$postinst" | sed 's/^log()/_log()/')
    log() { :; }
    install_kernel_source_boot_artifacts
    ls -A \"\$BUILDROOT/boot\"
  "
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "platform layer: a missing initrd fails the build loudly" {
  # Silence here is what turned a packaging gap into a field crash loop.
  local postinst="$PIPELINE_DIR/mkosi/mkosi.images/platform/mkosi.postinst"
  mkdir -p "$WORK/noinitrd/boot"
  _write_arm64_image "$WORK/noinitrd/boot/vmlinuz-7.2.0-ceralive-rk3588" 4096
  run bash -c "
    set -euo pipefail
    BUILDROOT=$WORK/noinitrd
    mkdir -p \"\$BUILDROOT/boot\"
    KERNEL_SOURCE_KERNEL_RELEASE=7.2.0-ceralive-rk3588
    log() { printf '%s\n' \"\$*\"; }
    $(sed -n '/^install_kernel_source_boot_artifacts()/,/^}/p' "$postinst")
    install_kernel_source_boot_artifacts
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"initrd.img-7.2.0-ceralive-rk3588 was not generated"* ]]
}

@test "platform layer: the boot-artifact step creates Image for a source kernel" {
  local postinst="$PIPELINE_DIR/mkosi/mkosi.images/platform/mkosi.postinst"
  mkdir -p "$WORK/good/boot"
  _write_arm64_image "$WORK/good/boot/vmlinuz-7.2.0-ceralive-rk3588" 4096
  run bash -c "
    set -euo pipefail
    BUILDROOT=$WORK/good
    mkdir -p \"\$BUILDROOT/boot\"
    : >\"\$BUILDROOT/boot/initrd.img-7.2.0-ceralive-rk3588\"
    KERNEL_SOURCE_KERNEL_RELEASE=7.2.0-ceralive-rk3588
    log() { :; }
    $(sed -n '/^install_kernel_source_boot_artifacts()/,/^}/p' "$postinst")
    install_kernel_source_boot_artifacts
    readlink \"\$BUILDROOT/boot/Image\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "vmlinuz-7.2.0-ceralive-rk3588" ]
}

# --- the staging layer must PRODUCE a raw Image, on every board ---------------
#
# `make bindeb-pkg` obeys arm64's KBUILD_IMAGE, which defaults to
# arch/arm64/boot/Image.gz — so vmlinuz-<REL> in the built .deb is GZIP. Whether
# that boots is then a per-board U-Boot fact, and the two shipped boards answer
# differently (Rock 5B+ ships U-Boot 2026.04 with CONFIG_GZIP=y; Orange Pi 5+
# ships the Rockchip 2017.09 fork, which has no CONFIG_GZIP symbol at all and no
# decompression in its booti path). Inheriting a board capability is exactly the
# mistake the loadaddr fix already cost a board, so this layer decompresses.

_run_boot_artifacts() {
  local dir="$1"
  local postinst="$PIPELINE_DIR/mkosi/mkosi.images/platform/mkosi.postinst"
  run bash -c "
    set -euo pipefail
    BUILDROOT=$dir
    KERNEL_SOURCE_KERNEL_RELEASE=7.2.0-ceralive-rk3588
    log() { printf '%s\n' \"\$*\"; }
    $(sed -n '/^install_kernel_source_boot_artifacts()/,/^}/p' "$postinst")
    install_kernel_source_boot_artifacts
  "
}

@test "platform layer: a gzip vmlinuz is decompressed into a REAL /boot/Image" {
  local dir="$WORK/gz" rel=7.2.0-ceralive-rk3588
  mkdir -p "$dir/boot"
  _write_arm64_image "$WORK/raw-image" 65536
  gzip -c "$WORK/raw-image" >"$dir/boot/vmlinuz-$rel"
  : >"$dir/boot/initrd.img-$rel"

  _run_boot_artifacts "$dir"
  [ "$status" -eq 0 ]

  # A symlink to the still-compressed vmlinuz is the bug, not the fix.
  [ ! -L "$dir/boot/Image" ]
  [ -f "$dir/boot/Image" ]
  cmp "$dir/boot/Image" "$WORK/raw-image"
  [ "$(od -An -tx1 -j56 -N4 -v "$dir/boot/Image" | tr -d ' \n')" = "41524d64" ]
  # The packaged vmlinuz is left exactly as dpkg installed it.
  [ "$(od -An -tx1 -j0 -N2 -v "$dir/boot/vmlinuz-$rel" | tr -d ' \n')" = "1f8b" ]
}

@test "platform layer: an already-raw vmlinuz keeps the vendor-parity symlink" {
  local dir="$WORK/rawpath" rel=7.2.0-ceralive-rk3588
  mkdir -p "$dir/boot"
  _write_arm64_image "$dir/boot/vmlinuz-$rel" 65536
  : >"$dir/boot/initrd.img-$rel"

  _run_boot_artifacts "$dir"
  [ "$status" -eq 0 ]
  [ -L "$dir/boot/Image" ]
  [ "$(readlink "$dir/boot/Image")" = "vmlinuz-$rel" ]
}

@test "platform layer: an unsupported kernel compression fails the build loudly" {
  # xz/zstd/lz4 would all leave booti with a 'Bad Linux ARM64 Image magic!' on
  # EVERY board. Guessing is not an option here, so the build stops.
  local dir="$WORK/xz" rel=7.2.0-ceralive-rk3588
  mkdir -p "$dir/boot"
  { printf '\xfd7zXZ\x00'; head -c 65536 /dev/zero; } >"$dir/boot/vmlinuz-$rel"
  : >"$dir/boot/initrd.img-$rel"

  _run_boot_artifacts "$dir"
  [ "$status" -ne 0 ]
  [[ "$output" == *"xz"* ]]
}

@test "platform layer: a gunzip that yields a non-Image fails the build loudly" {
  # The decompression succeeding is not the property that matters; the resulting
  # magic is. A gzip of the wrong payload must not ship as /boot/Image.
  local dir="$WORK/gzjunk" rel=7.2.0-ceralive-rk3588
  mkdir -p "$dir/boot"
  head -c 65536 /dev/zero | gzip -c >"$dir/boot/vmlinuz-$rel"
  : >"$dir/boot/initrd.img-$rel"

  _run_boot_artifacts "$dir"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ARM64 Image magic"* ]]
}

@test "platform layer: a re-run over an existing decompressed Image is idempotent" {
  # A/B slot rebuilds and mkosi incremental caches both re-enter this path.
  local dir="$WORK/idem" rel=7.2.0-ceralive-rk3588
  mkdir -p "$dir/boot"
  _write_arm64_image "$WORK/idem-src" 65536
  gzip -c "$WORK/idem-src" >"$dir/boot/vmlinuz-$rel"
  : >"$dir/boot/initrd.img-$rel"

  _run_boot_artifacts "$dir"
  [ "$status" -eq 0 ]
  _run_boot_artifacts "$dir"
  [ "$status" -eq 0 ]
  cmp "$dir/boot/Image" "$WORK/idem-src"
}

# --- the wiring that makes it a build gate rather than a manual tool ---------

@test "orchestrator: the build verifies boot artifacts before shipping the tar" {
  # The path constant is resolved by the orchestrator entry; the gate that uses
  # it is the [6b/9] module.
  grep -q 'VERIFY_BOOT_ARTIFACTS_SH' "$PIPELINE_DIR/lib/orchestrate.sh"
  grep -q 'VERIFY_BOOT_ARTIFACTS_SH' "$PIPELINE_DIR/lib/stages/boot-verify.sh"
  grep -q 'boot artifacts INCOMPLETE' "$PIPELINE_DIR/lib/stages/boot-verify.sh"
}

@test "orchestrator: KERNEL_SOURCE_KERNEL_RELEASE reaches the platform subimage" {
  # env_names alone is not enough — mkosi's --environment populates only the TOP
  # image; every subimage needs PassEnvironment=. This exact drift has shipped
  # three separate production bugs in this repo.
  grep -qE '^\s*KERNEL_SOURCE_KERNEL_RELEASE' "$PIPELINE_DIR/lib/orchestrate.sh"
  grep -q 'PassEnvironment=KERNEL_SOURCE_KERNEL_RELEASE' "$PIPELINE_DIR/mkosi/mkosi.conf"
}

# --- the source-built layout IS the production layout ------------------------

@test "boot artifacts: the source-built fixture release is the DEFAULT resolve's" {
  # The fixtures above model the layout a real production rootfs has, so a stale
  # release string would keep the suite green while it stopped describing any
  # image the pipeline builds. Both shipped boards resolve the same release.
  local board rel
  for board in rock-5b-plus orange-pi-5-plus; do
    rel="$(bash -c "'$RESOLVE_SH' '$board' 2>/dev/null" \
           | sed -n "s/^KERNEL_SOURCE_KERNEL_RELEASE='\(.*\)'$/\1/p")"
    [ "$rel" = "$SOURCE_REL" ]
  done
}

@test "boot artifacts: the DEFAULT resolve arms the source-built /boot mapping" {
  # KERNEL_SOURCE_KERNEL_RELEASE is what tells the platform layer to create
  # /boot/Image and pull initramfs-tools in itself; empty, the layer is a strict
  # no-op and the slot ships with neither. It used to be empty on the production
  # path because production installed the Armbian package. It must not be now.
  local board out
  for board in rock-5b-plus orange-pi-5-plus; do
    out="$(bash -c "'$RESOLVE_SH' '$board' 2>/dev/null")"
    [[ "$out" == *"KERNEL_SOURCE_KERNEL_RELEASE='$SOURCE_REL'"* ]]
    [[ "$out" == *"KERNEL_SOURCE_DTB_BOOT_DIR='/boot/dtb/rockchip'"* ]]
    [[ "$out" == *"KERNEL_SOURCE_DTB_DEB_DIR='/usr/lib/linux-image-$SOURCE_REL/rockchip'"* ]]
  done
}
