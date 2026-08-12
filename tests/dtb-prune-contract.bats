#!/usr/bin/env bats
#
# Installed-rootfs device-tree prune — the contract that says a shipped image
# carries the board's OWN device tree and not 227 other boards'.
#
# WHY THIS FILE EXISTS. `make bindeb-pkg` puts every in-tree arm64 DTB inside the
# linux-image deb (228 `rockchip/*.dtb` on the edge build), and the Armbian
# `linux-dtb-vendor-rk35xx` package does the same for the vendor path. A board
# boots exactly ONE of them: `boot.scr.cmd` and `recovery.scr.cmd` load
# `/boot/dtb/rockchip/${fdtfile}` and nothing else — there is no overlay load
# anywhere in the CeraLive boot path. Because the kernel rides inside a RAUC slot
# (docs/partition-contract.md rule 3), the rest is carried in BOTH slots of every
# image and inside every OTA bundle.
#
# TWO LOCATIONS, NOT ONE. The package-payload directory
# (/usr/lib/linux-image-<REL>/rockchip) stays in the rootfs after installation,
# so trimming only the /boot copy leaves the full set shipping anyway. Both are
# asserted here, for both boards.
#
# THE SOURCE `.deb` IS NOT TOUCHED, and this suite proves it: nothing is
# repacked, and the staged package must list exactly the same members before and
# after the prune runs. A smaller INSTALLED rootfs is the claim; a smaller
# package is not.
#
# Hardware-free and root-free: the real shipped functions are lifted out of
# mkosi/mkosi.images/platform/mkosi.postinst and executed against synthetic
# trees.

bats_require_minimum_version 1.5.0

setup() {
  TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  PIPELINE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
  POSTINST="$PIPELINE_DIR/mkosi/mkosi.images/platform/mkosi.postinst"
  WORK="$(mktemp -d)"

  # The shipped functions, lifted by TEXT so this suite can never drift into
  # testing a copy. `log` is a one-liner in the source and is restated here
  # rather than extracted, because a one-line function body defeats a
  # /^name()/,/^}/ range read.
  FNS="$WORK/dtb-fns.sh"
  {
    echo 'log() { printf "[platform] %s\n" "$*" >&2; }'
    sed -n '/^prune_dtb_dir()/,/^}/p' "$POSTINST"
    sed -n '/^prune_vendor_dtbs()/,/^}/p' "$POSTINST"
    sed -n '/^install_kernel_source_dtbs()/,/^}/p' "$POSTINST"
  } >"$FNS"

  # Non-vacuity: a renamed or reshaped function would otherwise make every case
  # below pass against an empty file.
  grep -q '^prune_dtb_dir()' "$FNS"
  grep -q '^prune_vendor_dtbs()' "$FNS"
  grep -q '^install_kernel_source_dtbs()' "$FNS"
  bash -n "$FNS"
}

teardown() {
  rm -rf "$WORK"
}

# Board facts are read from the shipped manifests, never restated, so a manifest
# change that renames a DTB moves these cases with it.
board_dtb() {
  grep -oE '^dtb_name: .*$' "$PIPELINE_DIR/manifests/boards/$1.yaml" | awk '{print $2}'
}

# A stand-in for the 228-blob rockchip directory a real kernel package ships.
seed_dtb_dir() {
  local dir="$1" board_dtb="$2"
  mkdir -p "$dir/overlay"
  local n
  for n in rk3588-rock-5b-plus rk3588-orangepi-5-plus rk3588-evb1-v10 \
           rk3588s-orangepi-5 rk3568-bpi-r2-pro rk3399-nanopi-m4; do
    printf 'dtb:%s\n' "$n" >"$dir/${n}.dtb"
  done
  printf 'dtb:%s\n' "$board_dtb" >"$dir/${board_dtb}"
  printf 'dtbo\n' >"$dir/overlay/rk3588-example.dtbo"
  printf 'dtbo\n' >"$dir/overlay/rk3588-unused.dtbo"
}

drive() {
  run bash -c "set -euo pipefail; source '$FNS'; $1"
}

# --- prune_dtb_dir, the primitive -------------------------------------------

@test "dtb prune: one directory is reduced to the board DTB and nothing else" {
  local dtb; dtb="$(board_dtb rock-5b-plus)"
  seed_dtb_dir "$WORK/d" "$dtb"
  [ "$(find "$WORK/d" -type f | wc -l)" -gt 1 ]

  drive "CERALIVE_DTB_KEEP_OVERLAYS='' prune_dtb_dir '$WORK/d' payload '$dtb'"
  [ "$status" -eq 0 ]

  [ -f "$WORK/d/$dtb" ]
  [ "$(find "$WORK/d" -type f | wc -l)" -eq 1 ]
  # An emptied overlay/ directory is removed too — a rootfs that still carries
  # the tree structure has not really been trimmed.
  [ ! -d "$WORK/d/overlay" ]
}

@test "dtb prune: explicitly named overlays are kept, unnamed ones are not" {
  local dtb; dtb="$(board_dtb rock-5b-plus)"
  seed_dtb_dir "$WORK/d" "$dtb"

  drive "CERALIVE_DTB_KEEP_OVERLAYS='overlay/rk3588-example.dtbo' prune_dtb_dir '$WORK/d' payload '$dtb'"
  [ "$status" -eq 0 ]

  [ -f "$WORK/d/$dtb" ]
  [ -f "$WORK/d/overlay/rk3588-example.dtbo" ]
  [ ! -f "$WORK/d/overlay/rk3588-unused.dtbo" ]
  [ "$(find "$WORK/d" -type f | wc -l)" -eq 2 ]
}

@test "dtb prune: a missing board DTB REFUSES to delete anything" {
  # Verify-before-delete is the whole safety property: a prune that removes first
  # and discovers the board DTB was absent afterwards has already produced an
  # unbootable slot.
  seed_dtb_dir "$WORK/d" rk3588-rock-5b-plus.dtb
  local before; before="$(find "$WORK/d" -type f | sort)"

  drive "CERALIVE_DTB_KEEP_OVERLAYS='' prune_dtb_dir '$WORK/d' payload 'rk3588-not-a-board.dtb'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to prune"* ]]
  [ "$(find "$WORK/d" -type f | sort)" = "$before" ]
}

@test "dtb prune: a named overlay that does not exist REFUSES to delete anything" {
  local dtb; dtb="$(board_dtb rock-5b-plus)"
  seed_dtb_dir "$WORK/d" "$dtb"
  local before; before="$(find "$WORK/d" -type f | sort)"

  drive "CERALIVE_DTB_KEEP_OVERLAYS='overlay/absent.dtbo' prune_dtb_dir '$WORK/d' payload '$dtb'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"absent.dtbo"* ]]
  [ "$(find "$WORK/d" -type f | sort)" = "$before" ]
}

@test "dtb prune: a missing directory and an unset board DTB both fail loudly" {
  drive "prune_dtb_dir '$WORK/nonexistent' payload 'x.dtb'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a directory"* ]]

  mkdir -p "$WORK/e"
  drive "prune_dtb_dir '$WORK/e' payload ''"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no board DTB name resolved"* ]]
}

@test "dtb prune: re-running it is a no-op, not a failure" {
  local dtb; dtb="$(board_dtb rock-5b-plus)"
  seed_dtb_dir "$WORK/d" "$dtb"
  drive "CERALIVE_DTB_KEEP_OVERLAYS='' prune_dtb_dir '$WORK/d' payload '$dtb'"
  [ "$status" -eq 0 ]
  drive "CERALIVE_DTB_KEEP_OVERLAYS='' prune_dtb_dir '$WORK/d' payload '$dtb'"
  [ "$status" -eq 0 ]
  [ -f "$WORK/d/$dtb" ]
}

# --- the source-built (edge) path, both boards, both locations ---------------

edge_env() {
  local board="$1" root="$2"
  local dtb; dtb="$(board_dtb "$board")"
  printf "BUILDROOT='%s' DTB_NAME='%s' KERNEL_SOURCE_DTB_DEB_DIR='%s' KERNEL_SOURCE_DTB_BOOT_DIR='%s' CERALIVE_DTB_KEEP_OVERLAYS='%s'" \
    "$root" "$dtb" /usr/lib/linux-image-7.1.7-ceralive-rk3588/rockchip /boot/dtb/rockchip "${3:-}"
}

@test "edge dtb install: rock-5b-plus keeps ONE dtb in BOTH installed locations" {
  local dtb; dtb="$(board_dtb rock-5b-plus)"
  local root="$WORK/root"
  local payload="$root/usr/lib/linux-image-7.1.7-ceralive-rk3588/rockchip"
  seed_dtb_dir "$payload" "$dtb"

  drive "$(edge_env rock-5b-plus "$root") install_kernel_source_dtbs"
  [ "$status" -eq 0 ]

  [ -f "$payload/$dtb" ]
  [ "$(find "$payload" -type f | wc -l)" -eq 1 ]
  [ -f "$root/boot/dtb/rockchip/$dtb" ]
  [ "$(find "$root/boot/dtb/rockchip" -type f | wc -l)" -eq 1 ]
}

@test "edge dtb install: orange-pi-5-plus keeps ONE dtb in BOTH installed locations" {
  # Different board, different DTB name, same contract — and the OPi 5+ name is
  # the one this repo has already got wrong once (rk3588s- vs rk3588-).
  local dtb; dtb="$(board_dtb orange-pi-5-plus)"
  [[ "$dtb" != rk3588s-* ]]
  local root="$WORK/root"
  local payload="$root/usr/lib/linux-image-7.1.7-ceralive-rk3588/rockchip"
  seed_dtb_dir "$payload" "$dtb"

  drive "$(edge_env orange-pi-5-plus "$root") install_kernel_source_dtbs"
  [ "$status" -eq 0 ]

  [ -f "$payload/$dtb" ]
  [ "$(find "$payload" -type f | wc -l)" -eq 1 ]
  [ -f "$root/boot/dtb/rockchip/$dtb" ]
  [ "$(find "$root/boot/dtb/rockchip" -type f | wc -l)" -eq 1 ]
  # The OTHER board's DTB is exactly what must be gone.
  [ ! -f "$root/boot/dtb/rockchip/$(board_dtb rock-5b-plus)" ]
}

@test "edge dtb install: a named overlay survives into BOTH locations" {
  local dtb; dtb="$(board_dtb rock-5b-plus)"
  local root="$WORK/root"
  local payload="$root/usr/lib/linux-image-7.1.7-ceralive-rk3588/rockchip"
  seed_dtb_dir "$payload" "$dtb"

  drive "$(edge_env rock-5b-plus "$root" 'overlay/rk3588-example.dtbo') install_kernel_source_dtbs"
  [ "$status" -eq 0 ]

  [ -f "$payload/overlay/rk3588-example.dtbo" ]
  [ -f "$root/boot/dtb/rockchip/overlay/rk3588-example.dtbo" ]
  [ ! -f "$root/boot/dtb/rockchip/overlay/rk3588-unused.dtbo" ]
}

@test "edge dtb install: the production vendor path is still a strict no-op" {
  # Both mapping variables are empty with no kernel_source variant selected, and
  # that must remain a clean return rather than a prune of something.
  drive "BUILDROOT='$WORK/root' DTB_NAME='x.dtb' KERNEL_SOURCE_DTB_DEB_DIR='' KERNEL_SOURCE_DTB_BOOT_DIR='' install_kernel_source_dtbs"
  [ "$status" -eq 0 ]
  [ ! -d "$WORK/root/boot" ]
}

@test "edge dtb install: a board DTB absent from the package still fails BEFORE any prune" {
  local root="$WORK/root"
  local payload="$root/usr/lib/linux-image-7.1.7-ceralive-rk3588/rockchip"
  seed_dtb_dir "$payload" rk3588-rock-5b-plus.dtb
  local before; before="$(find "$payload" -type f | sort)"

  drive "BUILDROOT='$root' DTB_NAME='rk3588-no-such-board.dtb' KERNEL_SOURCE_DTB_DEB_DIR='/usr/lib/linux-image-7.1.7-ceralive-rk3588/rockchip' KERNEL_SOURCE_DTB_BOOT_DIR='/boot/dtb/rockchip' install_kernel_source_dtbs"
  [ "$status" -ne 0 ]
  [ "$(find "$payload" -type f | sort)" = "$before" ]
}

# --- the source .deb is NOT repacked -----------------------------------------

@test "dtb prune: the source .deb listing is byte-identical before and after" {
  # The trim is an INSTALLED-ROOTFS operation. If this ever starts failing it
  # means something began rewriting the staged package, which would break its
  # SHA-256 pin and its provenance.
  command -v dpkg-deb >/dev/null || skip "dpkg-deb not available"
  local dtb; dtb="$(board_dtb rock-5b-plus)"

  local stage="$WORK/pkg"
  local payload_rel="usr/lib/linux-image-7.1.7-ceralive-rk3588/rockchip"
  mkdir -p "$stage/DEBIAN" "$stage/$payload_rel"
  printf 'Package: linux-image-7.1.7-ceralive-rk3588\nVersion: 7.1.7-ceralive1\nArchitecture: arm64\nMaintainer: t <t@t>\nDescription: fixture\n' >"$stage/DEBIAN/control"
  seed_dtb_dir "$stage/$payload_rel" "$dtb"
  dpkg-deb --build --root-owner-group "$stage" "$WORK/kernel.deb" >/dev/null

  local before after sha_before sha_after
  before="$(dpkg-deb -c "$WORK/kernel.deb" | awk '{print $NF}' | sort)"
  sha_before="$(sha256sum "$WORK/kernel.deb" | cut -d' ' -f1)"

  local root="$WORK/root"
  mkdir -p "$root"
  dpkg-deb -x "$WORK/kernel.deb" "$root"
  drive "$(edge_env rock-5b-plus "$root") install_kernel_source_dtbs"
  [ "$status" -eq 0 ]

  after="$(dpkg-deb -c "$WORK/kernel.deb" | awk '{print $NF}' | sort)"
  sha_after="$(sha256sum "$WORK/kernel.deb" | cut -d' ' -f1)"
  [ "$before" = "$after" ]
  [ "$sha_before" = "$sha_after" ]

  # …and the point of the exercise: the INSTALLED copy did shrink.
  [ "$(find "$root/$payload_rel" -type f | wc -l)" -eq 1 ]
  [ "$(printf '%s\n' "$before" | grep -c '\.dtb$')" -gt 1 ]
}

# --- the prebuilt vendor path -------------------------------------------------

# bats test_tags=vendor
@test "vendor dtb prune: the versioned /boot dtb directory is trimmed to the board DTB" {
  local dtb; dtb="$(board_dtb rock-5b-plus)"
  local root="$WORK/root"
  local versioned="$root/boot/dtb-6.1.115-vendor-rk35xx/rockchip"
  seed_dtb_dir "$versioned" "$dtb"
  ln -s "dtb-6.1.115-vendor-rk35xx" "$root/boot/dtb"

  drive "BUILDROOT='$root' DTB_NAME='$dtb' KERNEL_SOURCE_KERNEL_RELEASE='' CERALIVE_DTB_KEEP_OVERLAYS='' DTB_PACKAGES='linux-dtb-vendor-rk35xx' prune_vendor_dtbs"
  [ "$status" -eq 0 ]

  [ -f "$versioned/$dtb" ]
  [ "$(find "$versioned" -type f | wc -l)" -eq 1 ]
  # The /boot/dtb symlink is the path the U-Boot selector resolves; the prune
  # must not have replaced or broken it.
  [ -L "$root/boot/dtb" ]
  [ -f "$root/boot/dtb/rockchip/$dtb" ]
}

# bats test_tags=vendor
@test "vendor dtb prune: the directory is DISCOVERED, not composed from a release string" {
  # A hardcoded /boot/dtb-<REL> would silently no-op the moment the Armbian
  # package's version moved — the directory name comes from that package, not
  # from anything this repo resolves.
  local dtb; dtb="$(board_dtb orange-pi-5-plus)"
  local root="$WORK/root"
  local versioned="$root/boot/dtb-9.9.9-some-other-vendor-name/rockchip"
  seed_dtb_dir "$versioned" "$dtb"

  drive "BUILDROOT='$root' DTB_NAME='$dtb' KERNEL_SOURCE_KERNEL_RELEASE='' CERALIVE_DTB_KEEP_OVERLAYS='' prune_vendor_dtbs"
  [ "$status" -eq 0 ]
  [ "$(find "$versioned" -type f | wc -l)" -eq 1 ]
  [ -f "$versioned/$dtb" ]
}

# bats test_tags=vendor
@test "vendor dtb prune: a board DTB missing from /boot fails the build" {
  local root="$WORK/root"
  mkdir -p "$root/boot/dtb-6.1.115-vendor-rk35xx/rockchip"
  printf 'dtb\n' >"$root/boot/dtb-6.1.115-vendor-rk35xx/rockchip/rk3588-evb1-v10.dtb"

  drive "BUILDROOT='$root' DTB_NAME='rk3588-rock-5b-plus.dtb' KERNEL_SOURCE_KERNEL_RELEASE='' prune_vendor_dtbs"
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not present anywhere under /boot"* ]]
}

# bats test_tags=vendor
@test "vendor dtb prune: it declines on the source-built path and on a DTB-less board" {
  local root="$WORK/root"
  local versioned="$root/boot/dtb-6.1.115-vendor-rk35xx/rockchip"
  seed_dtb_dir "$versioned" rk3588-rock-5b-plus.dtb
  local before; before="$(find "$versioned" -type f | sort)"

  # A kernel_source variant carries its own DTBs and is trimmed by
  # install_kernel_source_dtbs; running both would prune the same tree twice.
  drive "BUILDROOT='$root' DTB_NAME='rk3588-rock-5b-plus.dtb' KERNEL_SOURCE_KERNEL_RELEASE='7.1.7-ceralive-rk3588' prune_vendor_dtbs"
  [ "$status" -eq 0 ]
  [ "$(find "$versioned" -type f | sort)" = "$before" ]

  # x86 has no device tree at all.
  drive "BUILDROOT='$root' DTB_NAME='none' KERNEL_SOURCE_KERNEL_RELEASE='' prune_vendor_dtbs"
  [ "$status" -eq 0 ]
  [ "$(find "$versioned" -type f | sort)" = "$before" ]
}

# bats test_tags=vendor
@test "vendor dtb prune: persistence rides the EXISTING kernel freeze, with no second hold" {
  # The plan allows a dpkg path-exclude contract ONLY if a reinstall can bypass
  # the freeze in a supported workflow. It cannot, for a structural reason: the
  # boot BSP is installed from mkosi's build-time-only local `file:/repository`,
  # which does not exist on the shipped device, so apt has no candidate for the
  # DTB package to reinstall FROM — on top of the apt-mark hold and the
  # name+version pin that freeze_boot_packages already applies to it.
  local persistence="$PIPELINE_DIR/mkosi/customize/postinst.d/persistence.sh"

  # The DTB package reaches the freeze set through DTB_PACKAGES, which is the
  # same manifest field prune_vendor_dtbs reports on.
  grep -q 'DTB_PACKAGES' "$persistence"
  grep -q 'apt-mark hold' "$persistence"

  # No parallel hold mechanism was invented anywhere in the platform layer.
  # Comments are stripped first: the function's own header explains why none of
  # these is used, and matching that prose would make this pass for the wrong
  # reason on a file that actually grew one.
  run bash -c "grep -vE '^[[:space:]]*#' '$POSTINST' | grep -nE 'path-exclude|path-include|dpkg\.cfg\.d|apt-mark'"
  [ "$status" -ne 0 ]

  # And the freeze file itself is written by exactly one function.
  [ "$(grep -c '^freeze_boot_packages()' "$persistence")" -eq 1 ]
}

# bats test_tags=vendor
@test "vendor dtb prune: a simulated package reinstall restores the extras, so the freeze is load-bearing" {
  # Non-vacuity for the case above. The prune is deliberately NOT self-defending
  # — re-unpacking the package puts every blob back — which is exactly why the
  # persistence argument has to rest on the freeze plus the absent apt origin,
  # and why claiming "the prune is permanent" on its own would be false.
  command -v dpkg-deb >/dev/null || skip "dpkg-deb not available"
  local dtb; dtb="$(board_dtb rock-5b-plus)"
  local rel_dir="boot/dtb-6.1.115-vendor-rk35xx/rockchip"

  local stage="$WORK/pkg"
  mkdir -p "$stage/DEBIAN" "$stage/$rel_dir"
  printf 'Package: linux-dtb-vendor-rk35xx\nVersion: 26.5.1\nArchitecture: arm64\nMaintainer: t <t@t>\nDescription: fixture\n' >"$stage/DEBIAN/control"
  seed_dtb_dir "$stage/$rel_dir" "$dtb"
  dpkg-deb --build --root-owner-group "$stage" "$WORK/dtb.deb" >/dev/null

  local root="$WORK/root"
  mkdir -p "$root"
  dpkg-deb -x "$WORK/dtb.deb" "$root"
  drive "BUILDROOT='$root' DTB_NAME='$dtb' KERNEL_SOURCE_KERNEL_RELEASE='' CERALIVE_DTB_KEEP_OVERLAYS='' prune_vendor_dtbs"
  [ "$status" -eq 0 ]
  [ "$(find "$root/$rel_dir" -type f | wc -l)" -eq 1 ]

  dpkg-deb -x "$WORK/dtb.deb" "$root"
  [ "$(find "$root/$rel_dir" -type f | wc -l)" -gt 1 ]
}

# --- wiring -------------------------------------------------------------------

@test "dtb prune: both prune paths are actually WIRED into the boot-BSP branch" {
  # A prune nobody calls is the failure mode a synthetic-tree suite cannot see.
  grep -q 'install_kernel_source_dtbs$' "$POSTINST"
  grep -q 'prune_vendor_dtbs$' "$POSTINST"

  local install_line vendor_line firmware_line
  install_line="$(grep -n '^  install_kernel_source_dtbs$' "$POSTINST" | cut -d: -f1)"
  vendor_line="$(grep -n '^  prune_vendor_dtbs$' "$POSTINST" | cut -d: -f1)"
  firmware_line="$(grep -n '^  prune_irrelevant_rk3588_firmware$' "$POSTINST" | cut -d: -f1)"
  [ -n "$install_line" ]
  [ "$install_line" -lt "$vendor_line" ]
  [ "$vendor_line" -lt "$firmware_line" ]
}

@test "dtb prune: the overlay keep-list is on the env_names <-> PassEnvironment lockstep" {
  # A name in env_names but missing from PassEnvironment= reads EMPTY in every
  # subimage, silently — the drift that has already shipped three bugs here.
  grep -q 'CERALIVE_DTB_KEEP_OVERLAYS' "$PIPELINE_DIR/lib/orchestrate.sh"
  grep -q 'CERALIVE_DTB_KEEP_OVERLAYS' "$PIPELINE_DIR/mkosi/mkosi.conf"
}
