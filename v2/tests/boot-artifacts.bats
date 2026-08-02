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
# The rootfs had `vmlinuz-7.1.5-ceralive-rk3588` and no `Image` at all, because the
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
  V2="$(cd "$TESTS_DIR/.." && pwd)"
  VERIFY="$V2/lib/verify-boot-artifacts.sh"
  DTB=rk3588-rock-5b-plus.dtb
  WORK="$(mktemp -d)"
}

teardown() {
  rm -rf "$WORK"
}

# A rootfs skeleton with the artifact sizes the real packages produce, so the
# verifier's size floors are exercised rather than sidestepped by empty files.
_seed_common() {
  local root="$1" rel="$2"
  mkdir -p "$root/boot"
  head -c 12000000 /dev/zero >"$root/boot/vmlinuz-$rel"
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

# The source-built layout AFTER this change: bindeb-pkg ships DTBs under a real
# /boot/dtb/<vendor>/ directory (no versioned dir, so no symlink to make), the
# platform layer adds the Image symlink, and initramfs-tools writes the initrd.
seed_source_layout() {
  local root="$WORK/source" rel=7.1.5-ceralive-rk3588
  _seed_common "$root" "$rel"
  ln -s "vmlinuz-$rel" "$root/boot/Image"
  _seed_dtbs "$root/boot/dtb/rockchip"
  head -c 8000000 /dev/zero >"$root/boot/initrd.img-$rel"
  : >"$root/boot/.next"
  printf '%s\n' "$root"
}

# The exact pre-fix state that reached the board.
seed_broken_source_layout() {
  local root="$WORK/broken" rel=7.1.5-ceralive-rk3588
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
  [[ "$output" == *"/boot/Image -> boot/vmlinuz-7.1.5-ceralive-rk3588"* ]]
  [[ "$output" == *"boot/dtb/rockchip/$DTB"* ]]
  [[ "$output" == *"boot/initrd.img-7.1.5-ceralive-rk3588"* ]]
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
  [[ "$output" == *"boot/vmlinuz-7.1.5-ceralive-rk3588"* ]]
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
  rm -f "$root/boot/vmlinuz-7.1.5-ceralive-rk3588"
  run_verify "$(pack "$root")"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a file in this rootfs"* ]]
}

@test "boot artifacts: a truncated kernel fails" {
  local root; root="$(seed_source_layout)"
  head -c 4096 /dev/zero >"$root/boot/vmlinuz-7.1.5-ceralive-rk3588"
  run_verify "$(pack "$root")"
  [ "$status" -ne 0 ]
  [[ "$output" == *"bytes"* ]]
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
  local postinst="$V2/mkosi/mkosi.images/platform/mkosi.postinst"
  grep -q 'install_kernel_source_boot_artifacts' "$postinst"
  grep -qE 'ln -sfn "vmlinuz-\$\{release\}"' "$postinst"
}

@test "platform layer: initramfs-tools is installed BEFORE the source kernel" {
  # Ordering is the mechanism: the kernel postinst run-parts /etc/kernel/postinst.d,
  # so the hook must already be configured. Reverse these and the initrd is silently
  # never generated — which is exactly what shipped.
  local postinst="$V2/mkosi/mkosi.images/platform/mkosi.postinst"
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
  local postinst="$V2/mkosi/mkosi.images/platform/mkosi.postinst"
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
  local postinst="$V2/mkosi/mkosi.images/platform/mkosi.postinst"
  run bash -c "
    set -euo pipefail
    BUILDROOT=$WORK/noinitrd
    mkdir -p \"\$BUILDROOT/boot\"
    : >\"\$BUILDROOT/boot/vmlinuz-7.1.5-ceralive-rk3588\"
    KERNEL_SOURCE_KERNEL_RELEASE=7.1.5-ceralive-rk3588
    log() { printf '%s\n' \"\$*\"; }
    $(sed -n '/^install_kernel_source_boot_artifacts()/,/^}/p' "$postinst")
    install_kernel_source_boot_artifacts
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"initrd.img-7.1.5-ceralive-rk3588 was not generated"* ]]
}

@test "platform layer: the boot-artifact step creates Image for a source kernel" {
  local postinst="$V2/mkosi/mkosi.images/platform/mkosi.postinst"
  run bash -c "
    set -euo pipefail
    BUILDROOT=$WORK/good
    mkdir -p \"\$BUILDROOT/boot\"
    : >\"\$BUILDROOT/boot/vmlinuz-7.1.5-ceralive-rk3588\"
    : >\"\$BUILDROOT/boot/initrd.img-7.1.5-ceralive-rk3588\"
    KERNEL_SOURCE_KERNEL_RELEASE=7.1.5-ceralive-rk3588
    log() { :; }
    $(sed -n '/^install_kernel_source_boot_artifacts()/,/^}/p' "$postinst")
    install_kernel_source_boot_artifacts
    readlink \"\$BUILDROOT/boot/Image\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "vmlinuz-7.1.5-ceralive-rk3588" ]
}

# --- the wiring that makes it a build gate rather than a manual tool ---------

@test "orchestrator: the build verifies boot artifacts before shipping the tar" {
  grep -q 'VERIFY_BOOT_ARTIFACTS_SH' "$V2/lib/orchestrate.sh"
  grep -q 'boot artifacts INCOMPLETE' "$V2/lib/orchestrate.sh"
}

@test "orchestrator: KERNEL_SOURCE_KERNEL_RELEASE reaches the platform subimage" {
  # env_names alone is not enough — mkosi's --environment populates only the TOP
  # image; every subimage needs PassEnvironment=. This exact drift has shipped
  # three separate production bugs in this repo.
  grep -qE '^\s*KERNEL_SOURCE_KERNEL_RELEASE' "$V2/lib/orchestrate.sh"
  grep -q 'PassEnvironment=KERNEL_SOURCE_KERNEL_RELEASE' "$V2/mkosi/mkosi.conf"
}
