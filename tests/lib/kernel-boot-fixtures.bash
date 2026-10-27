#!/usr/bin/env bash
# Offline .deb fixtures shared by the boot-staging CLI tests and manual QA.

kernel_fixture_deb() {
  local release="$1" version="$2" format="${3:-gzip}" label="${4:-fixture}"
  local pkg="${WORK}/pkg-${release}-${version}-${format}"
  mkdir -p "${pkg}/DEBIAN" "${pkg}/boot" "${pkg}/usr/lib/linux-image-${release}/rockchip"
  printf 'Package: linux-image-%s\nVersion: %s\nArchitecture: arm64\nMaintainer: Fixture <fixture@example.invalid>\nDescription: offline boot fixture\n' \
    "${release}" "${version}" >"${pkg}/DEBIAN/control"
  {
    head -c 56 /dev/zero
    printf 'ARM\x64'
    head -c $((5 * 1024 * 1024 - 60)) /dev/zero
  } >"${WORK}/raw-image"
  case "${format}" in
    gzip) gzip -nc "${WORK}/raw-image" >"${pkg}/boot/vmlinuz-${release}" ;;
    raw) cp "${WORK}/raw-image" "${pkg}/boot/vmlinuz-${release}" ;;
    xz) xz -c "${WORK}/raw-image" >"${pkg}/boot/vmlinuz-${release}" ;;
  esac
  head -c 300000 /dev/zero >"${pkg}/boot/initrd.img-${release}"
  {
    printf '%s\n' "${label}"
    head -c 8192 /dev/zero
  } >"${pkg}/usr/lib/linux-image-${release}/rockchip/${DTB}"
  head -c 8192 /dev/zero >"${pkg}/usr/lib/linux-image-${release}/rockchip/other-board.dtb"
  dpkg-deb --build --root-owner-group "${pkg}" "${WORK}/kernel.deb" >/dev/null
}

kernel_fixture_root() {
  local root="$1"
  mkdir -p "${root}/usr/lib/ceralive"
  dpkg-deb -x "${WORK}/kernel.deb" "${root}"
  printf '{\n  "dtb_name": "%s",\n  "dtb_deb_dir_template": "/usr/lib/linux-image-{kernel_release}/rockchip",\n  "dtb_boot_dir": "/boot/dtb/rockchip",\n  "kernel_package_regex": "^linux-image-[0-9]+[.][0-9]+[.][0-9]+-ceralive-rk3588$"\n}\n' \
    "${DTB}" >"${root}/usr/lib/ceralive/board-boot.json"
}

kernel_tree_manifest() {
  (
    cd "$1" || exit 1
    find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum
    find . -type l -printf '%p -> %l\n' | LC_ALL=C sort
    find . -printf '%y %m %p\n' | LC_ALL=C sort
  )
}
