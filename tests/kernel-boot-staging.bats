#!/usr/bin/env bats
# Real shipped CLI against dpkg-deb fixtures; no root, network or hardware.

load lib/kernel-boot-fixtures

setup() {
  PIPELINE="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  STAGING="${KERNEL_BOOT_STAGING_UNDER_TEST:-${PIPELINE}/mkosi/runtime/ceralive-kernel-boot-staging.sh}"
  VERIFY="${KERNEL_BOOT_VERIFY_UNDER_TEST:-${PIPELINE}/lib/verify-boot-artifacts.sh}"
  REL=7.2.0-ceralive-rk3588
  DTB=rk3588-rock-5b-plus.dtb
  WORK="$(mktemp -d)"
  ROOT="${WORK}/root"
  kernel_fixture_deb "${REL}" 7.2.0-ceralive2
  kernel_fixture_root "${ROOT}"
}

teardown() { rm -rf "${WORK}"; }

stage() {
  run bash "${STAGING}" "${ROOT}" --kernel-release "${REL}" "$@"
  [ "${status}" -eq 0 ]
}

verdicts_equal() {
  local expected="$1"
  shift
  tar -cf "${WORK}/root.tar" -C "${ROOT}" .
  run bash "${VERIFY}" "${WORK}/root.tar" --dtb-name "${DTB}" "$@"
  [ "${status}" -eq "${expected}" ]
  local tar_verdict="${status}"
  run bash "${VERIFY}" --root-dir "${ROOT}" --dtb-name "${DTB}" "$@"
  [ "${status}" -eq "${tar_verdict}" ]
}

@test "kernel staging CLI: gzip produces raw magic and byte-identical pruned DTBs" {
  stage
  [ ! -L "${ROOT}/boot/Image" ]
  cmp "${ROOT}/boot/Image" "${WORK}/raw-image"
  [ "$(od -An -tx1 -j56 -N4 "${ROOT}/boot/Image" | tr -d ' \n')" = 41524d64 ]
  cmp "${ROOT}/boot/dtb/rockchip/${DTB}" "${ROOT}/usr/lib/linux-image-${REL}/rockchip/${DTB}"
  cmp "${ROOT}/boot/dtb/rockchip/${DTB}" "${WORK}/pkg-${REL}-7.2.0-ceralive2-gzip/usr/lib/linux-image-${REL}/rockchip/${DTB}"
  [ "$(find "${ROOT}/boot/dtb/rockchip" -type f | wc -l)" -eq 1 ]
  [ "$(find "${ROOT}/usr/lib/linux-image-${REL}/rockchip" -type f | wc -l)" -eq 1 ]
  verdicts_equal 0
}

@test "kernel staging CLI: raw Image retains a relative symlink" {
  kernel_fixture_deb "${REL}" 7.2.0-ceralive2 raw
  kernel_fixture_root "${ROOT}"
  stage
  [ -L "${ROOT}/boot/Image" ]
  [ "$(readlink "${ROOT}/boot/Image")" = "vmlinuz-${REL}" ]
  verdicts_equal 0
}

@test "kernel staging CLI: xz is rejected with an explicit reason" {
  kernel_fixture_deb "${REL}" 7.2.0-ceralive2 xz
  kernel_fixture_root "${ROOT}"
  run bash "${STAGING}" "${ROOT}" --kernel-release "${REL}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"xz-compressed"* ]]
}

@test "kernel staging CLI: missing DTB cannot reuse a stale boot copy" {
  stage
  rm "${ROOT}/usr/lib/linux-image-${REL}/rockchip/${DTB}"
  run bash "${STAGING}" "${ROOT}" --kernel-release "${REL}"
  [ "${status}" -ne 0 ]
}

@test "kernel staging CLI: wrong release and missing board identity are rejected" {
  run bash "${STAGING}" "${ROOT}" --kernel-release 7.3.0-ceralive-rk3588
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"vmlinuz-7.3.0-ceralive-rk3588 is absent"* ]]
  rm "${ROOT}/usr/lib/ceralive/board-boot.json"
  run bash "${STAGING}" "${ROOT}" --kernel-release "${REL}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"missing board-boot.json"* ]]
}

@test "kernel staging CLI: revision rerun replaces same-release DTB bytes" {
  stage
  cp "${ROOT}/boot/dtb/rockchip/${DTB}" "${WORK}/old.dtb"
  kernel_fixture_deb "${REL}" 7.2.0-ceralive3 gzip revision-three
  dpkg-deb -x "${WORK}/kernel.deb" "${ROOT}"
  stage
  run cmp "${WORK}/old.dtb" "${ROOT}/boot/dtb/rockchip/${DTB}"
  [ "${status}" -ne 0 ]
  cmp "${ROOT}/boot/dtb/rockchip/${DTB}" "${ROOT}/usr/lib/linux-image-${REL}/rockchip/${DTB}"
}

@test "kernel staging CLI: package-name upgrade purges 7.2 and stages 7.3 DTB directory" {
  mkdir -p "${ROOT}/var/lib/dpkg"
  dpkg --root="${ROOT}" --force-not-root --force-architecture --install "${WORK}/kernel.deb"
  stage
  local old="${REL}"
  REL=7.3.0-ceralive-rk3588
  kernel_fixture_deb "${REL}" 7.3.0-ceralive1 gzip upstream-three
  dpkg --root="${ROOT}" --force-not-root --force-architecture --install "${WORK}/kernel.deb"
  dpkg --root="${ROOT}" --force-not-root --purge "linux-image-${old}"
  stage
  [ ! -e "${ROOT}/usr/lib/linux-image-${old}" ]
  [ ! -e "${ROOT}/boot/vmlinuz-${old}" ]
  [ ! -e "${ROOT}/boot/initrd.img-${old}" ]
  cmp "${ROOT}/boot/dtb/rockchip/${DTB}" "${ROOT}/usr/lib/linux-image-${REL}/rockchip/${DTB}"
  verdicts_equal 0
}

@test "kernel staging CLI: rerunning produces an identical tree manifest" {
  stage
  kernel_tree_manifest "${ROOT}" >"${WORK}/before"
  stage
  kernel_tree_manifest "${ROOT}" >"${WORK}/after"
  cmp "${WORK}/before" "${WORK}/after"
}

@test "boot verifier: root and tar verdicts match missing and corrupted fixtures" {
  stage
  local path
  for path in boot/Image "boot/dtb/rockchip/${DTB}" "boot/initrd.img-${REL}"; do
    mv "${ROOT}/${path}" "${WORK}/saved"
    verdicts_equal 1
    mv "${WORK}/saved" "${ROOT}/${path}"
  done
  printf '\xfd7zXZ\x00' | dd of="${ROOT}/boot/Image" conv=notrunc status=none
  printf '\0\0\0\0' | dd of="${ROOT}/boot/Image" seek=56 bs=1 conv=notrunc status=none
  verdicts_equal 1
}

@test "kernel staging CLI: malformed release and foreign package suffix are rejected" {
  run bash "${STAGING}" "${ROOT}" --kernel-release '../escape'
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"invalid --kernel-release"* ]]
  cp "${ROOT}/boot/vmlinuz-${REL}" "${ROOT}/boot/vmlinuz-7.2.0-foreign"
  cp "${ROOT}/boot/initrd.img-${REL}" "${ROOT}/boot/initrd.img-7.2.0-foreign"
  cp -a "${ROOT}/usr/lib/linux-image-${REL}" "${ROOT}/usr/lib/linux-image-7.2.0-foreign"
  run bash "${STAGING}" "${ROOT}" --kernel-release 7.2.0-foreign
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"kernel_package_regex"* ]]
}

@test "kernel staging CLI: successful gzip decompression without ARM64 magic is rejected" {
  head -c 5242880 /dev/zero | gzip -c >"${ROOT}/boot/vmlinuz-${REL}"
  run bash "${STAGING}" "${ROOT}" --kernel-release "${REL}" --no-initrd
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"no raw ARM64 Image magic"* ]]
}

@test "kernel staging CLI: environment identity cannot override the board file" {
  run env DTB_NAME=other-board.dtb KERNEL_SOURCE_DTB_DEB_DIR=/wrong \
    KERNEL_SOURCE_DTB_BOOT_DIR=/wrong bash "${STAGING}" "${ROOT}" --kernel-release "${REL}"
  [ "${status}" -eq 0 ]
  cmp "${ROOT}/boot/dtb/rockchip/${DTB}" "${ROOT}/usr/lib/linux-image-${REL}/rockchip/${DTB}"
  [ ! -e "${ROOT}/wrong" ]
}

@test "boot verifier: skip-initrd skips only initrd in root and tar modes" {
  stage
  rm "${ROOT}/boot/initrd.img-${REL}"
  verdicts_equal 1
  verdicts_equal 0 --skip-initrd
  mv "${ROOT}/boot/Image" "${WORK}/saved"
  verdicts_equal 1 --skip-initrd
  mv "${WORK}/saved" "${ROOT}/boot/Image"
  rm "${ROOT}/boot/dtb/rockchip/${DTB}"
  verdicts_equal 1 --skip-initrd
}

@test "kernel staging CLI: no-initrd still requires a valid Image and DTB" {
  rm "${ROOT}/boot/initrd.img-${REL}"
  run bash "${STAGING}" "${ROOT}" --kernel-release "${REL}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"was not generated"* ]]
  stage --no-initrd
  verdicts_equal 0 --skip-initrd
  rm "${ROOT}/usr/lib/linux-image-${REL}/rockchip/${DTB}"
  run bash "${STAGING}" "${ROOT}" --kernel-release "${REL}" --no-initrd
  [ "${status}" -ne 0 ]
}

@test "kernel staging CLI: firmware refs select only the candidate release" {
  mkdir -p "${WORK}/bin" "${ROOT}/usr/lib/modules/${REL}" "${ROOT}/usr/lib/modules/old"
  printf 'candidate\n' >"${ROOT}/usr/lib/modules/${REL}/wifi.ko"
  printf 'stale\n' >"${ROOT}/usr/lib/modules/old/wifi.ko"
  printf '#!/usr/bin/env bash\nprintf "/rtw89/%%s.bin\\n" "$(<"$3")"\n' >"${WORK}/bin/modinfo"
  chmod +x "${WORK}/bin/modinfo"
  run env PATH="${WORK}/bin:${PATH}" bash "${STAGING}" firmware-refs "${ROOT}" --kernel-release "${REL}"
  [ "${status}" -eq 0 ]
  [ "${output}" = rtw89/candidate.bin ]
  printf '#!/usr/bin/env bash\nexit 1\n' >"${WORK}/bin/modinfo"
  run env PATH="${WORK}/bin:${PATH}" bash "${STAGING}" firmware-refs "${ROOT}" --kernel-release "${REL}"
  [ "${status}" -ne 0 ]
}

@test "platform installs executable staging and verifier with manifest-derived board identity" {
  local src="${WORK}/src" board
  mkdir -p "${src}/runtime" "${src}/customize" "${src}/.staging/fixture"
  cp "${STAGING}" "${src}/runtime/ceralive-kernel-boot-staging.sh"
  cp "${VERIFY}" "${src}/.staging/fixture/verify-boot-artifacts.sh"
  cp "${PIPELINE}/mkosi/customize/bluetooth-firmware.sh" "${src}/customize/bluetooth-firmware.sh"
  cp "${PIPELINE}/manifests/rk3588-bluetooth-firmware-roots.txt" "${src}/.staging/fixture/"
  for board in rock-5b-plus orange-pi-5-plus; do
    run env BUILDROOT="${ROOT}" SRCDIR="${src}" CERALIVE_BOARD=fixture bash -c '
      set -euo pipefail
      eval "$(bash "$1/lib/resolve.sh" "$2")"
      log() { printf "%s\n" "$*" >&2; }
      eval "$(sed -n "/^install_kernel_boot_staging()/,/^}/p" "$1/mkosi/mkosi.images/platform/mkosi.postinst")"
      install_kernel_boot_staging
    ' _ "${PIPELINE}" "${board}"
    [ "${status}" -eq 0 ]
    [ -x "${ROOT}/usr/lib/ceralive/ceralive-kernel-boot-staging" ]
    [ -x "${ROOT}/usr/lib/ceralive/verify-boot-artifacts.sh" ]
    cmp "${STAGING}" "${ROOT}/usr/lib/ceralive/ceralive-kernel-boot-staging"
    cmp "${VERIFY}" "${ROOT}/usr/lib/ceralive/verify-boot-artifacts.sh"
    cmp "${PIPELINE}/mkosi/customize/bluetooth-firmware.sh" "${ROOT}/usr/lib/ceralive/kernel-firmware-rules.sh"
    cmp "${PIPELINE}/manifests/rk3588-bluetooth-firmware-roots.txt" "${ROOT}/usr/lib/ceralive/kernel-firmware-rules.txt"
    run python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert d["dtb_deb_dir_template"] == "/usr/lib/linux-image-{kernel_release}/rockchip"
assert d["dtb_boot_dir"] == "/boot/dtb/rockchip"
assert d["kernel_package_regex"] == "^linux-image-[0-9]+[.][0-9]+[.][0-9]+-ceralive-rk3588$"
assert d["dtb_name"] == sys.argv[2]
' "${ROOT}/usr/lib/ceralive/board-boot.json" "$(bash "${PIPELINE}/lib/resolve.sh" "${board}" | sed -n "s/^DTB_NAME='\(.*\)'$/\1/p")"
    [ "${status}" -eq 0 ]
  done
}

@test "boot verifier: root mode follows root-absolute directory and Image links like tar" {
  stage
  mv "${ROOT}/boot/dtb" "${ROOT}/boot/dtb-${REL}"
  ln -s "/boot/dtb-${REL}" "${ROOT}/boot/dtb"
  mv "${ROOT}/boot/Image" "${ROOT}/boot/raw-image"
  ln -s /boot/raw-image "${ROOT}/boot/Image"
  verdicts_equal 0
}
