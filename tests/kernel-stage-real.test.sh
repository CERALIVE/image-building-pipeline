#!/bin/bash
# Native Debian rootfs, real loop ext4 slots and chroot dpkg. No network.
set -euo pipefail
export TMPDIR="${TMPDIR:-${RUNNER_TEMP:-/var/tmp}}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
case "${CERALIVE_RUN_REAL_KERNEL_STAGE_CONTRACT:-skip}" in
  skip) printf 'SKIP real kernel stage (CERALIVE_RUN_REAL_KERNEL_STAGE_CONTRACT=required)\n'; exit 0 ;;
  required) ;;
  *) printf 'CERALIVE_RUN_REAL_KERNEL_STAGE_CONTRACT must be required or skip\n' >&2; exit 2 ;;
esac
if [[ "$(id -u)" -ne 0 ]]; then
  sudo -n true || { printf 'FAIL real kernel stage: root or passwordless sudo required\n' >&2; exit 1; }
  exec sudo -n env TMPDIR="${TMPDIR:?}" \
    CERALIVE_KERNEL_STAGE_ROOTFS="${CERALIVE_KERNEL_STAGE_ROOTFS:?native Debian rootfs export required}" \
    CERALIVE_RUN_REAL_KERNEL_STAGE_CONTRACT=required bash "$0"
fi
[[ -f "${CERALIVE_KERNEL_STAGE_ROOTFS:?native Debian rootfs export required}" ]]
for tool in losetup mkfs.ext4 mount umount chroot dpkg-deb rsync e2fsck jq; do command -v "${tool}" >/dev/null; done
source "${HERE}/lib/kernel-stage-fixture.sh"
WORK="$(mktemp -d)"
boot_loop="" target_loop=""
cleanup() {
  local path
  for path in /run /dev/pts /dev /sys /proc ""; do
    umount "${FIXTURE}/mnt/target${path}" 2>/dev/null || true
  done
  umount "${FIXTURE}/mnt/source" 2>/dev/null || true
  umount "${FIXTURE}/inspect" 2>/dev/null || true
  umount "${FIXTURE}/booted" 2>/dev/null || true
  umount "${FIXTURE}/native/dev" 2>/dev/null || true
  if findmnt -rn -o TARGET | awk -v root="${WORK}/" 'index($0,root)==1 {found=1} END {exit !found}'; then
    printf 'FAIL cleanup: fixture mounts remain; retaining %s\n' "${WORK}" >&2
    return 1
  fi
  [[ -z "${boot_loop}" ]] || losetup -d "${boot_loop}"
  [[ -z "${target_loop}" ]] || losetup -d "${target_loop}"
  rm -rf -- "${WORK}"
}
trap cleanup EXIT
stage_fixture_init
stage_fixture_reset
# The fixture provides only RAUC/control-plane seams. All data-plane tools below
# resolve to the host's real binaries, not the directory-backed mount stubs.
SYSTEM_PATH="${PATH#*:}"
export PATH="${SYSTEM_PATH}" MOUNT_BIN=mount UMOUNT_BIN=umount E2FSCK_BIN=e2fsck FINDMNT_BIN=findmnt
export RSYNC_BIN=rsync SYNC_BIN=sync CHROOT_BIN=chroot
mkdir -p "${FIXTURE}/native"
tar --numeric-owner -xpf "${CERALIVE_KERNEL_STAGE_ROOTFS}" -C "${FIXTURE}/native"
chroot "${FIXTURE}/native" dpkg --add-architecture arm64
stage_fixture_native_apt "${FIXTURE}/native"
mkdir -p "${FIXTURE}/native"/{proc,sys,dev/pts,run,boot,etc/apt/preferences.d,etc/kernel/postinst.d,usr/libexec/ceralive,usr/lib/ceralive}
cp "${REPO}/mkosi/runtime/ceralive-reprune.sh" "${FIXTURE}/native/usr/libexec/ceralive/ceralive-reprune"
chmod +x "${FIXTURE}/native/usr/libexec/ceralive/ceralive-reprune"
cp "${CERALIVE_BOARD_BOOT}" "${FIXTURE}/native/usr/lib/ceralive/board-boot.json"
cat >"${FIXTURE}/native/etc/kernel/postinst.d/test-initrd" <<'EOF'
#!/bin/sh
dd if=/dev/zero of="/boot/initrd.img-$1" bs=1024 count=300 status=none
EOF
chmod +x "${FIXTURE}/native/etc/kernel/postinst.d/test-initrd"
cat >"${FIXTURE}/native/etc/apt/preferences.d/ceralive-kernel-freeze" <<'EOF'
Package: linux-image-7.2.0-ceralive-rk3588
Pin: version 7.2.0-ceralive1
Pin-Priority: 1001

Package: armbian-firmware-full
Pin: version 26.8.3
Pin-Priority: 1001
EOF
make_kernel() {
  local base="$1" revision="$2" fail="$3" release="${1}-ceralive-rk3588" tree="${FIXTURE}/pkg-${1}"
  mkdir -p "${tree}/DEBIAN" "${tree}/boot" "${tree}/usr/lib/linux-image-${release}/rockchip" "${tree}/usr/lib/modules/${release}"
  cat >"${tree}/DEBIAN/control" <<EOF
Package: linux-image-${release}
Version: ${base}-ceralive${revision}
Architecture: arm64
Maintainer: CeraLive <test@ceralive.tv>
Installed-Size: 5000
Description: native chroot kernel fixture
EOF
  dd if=/dev/zero of="${tree}/Image" bs=1M count=5 status=none
  printf 'ARM\144' | dd of="${tree}/Image" bs=1 seek=56 conv=notrunc status=none
  gzip -cn "${tree}/Image" >"${tree}/boot/vmlinuz-${release}"
  rm "${tree}/Image"
  dd if=/dev/zero of="${tree}/usr/lib/linux-image-${release}/rockchip/rk3588-test.dtb" bs=4096 count=2 status=none
  printf '\320\015\376\355' | dd of="${tree}/usr/lib/linux-image-${release}/rockchip/rk3588-test.dtb" bs=1 conv=notrunc status=none
  cat >"${tree}/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e
[ '${fail}' = 0 ] || exit 1
run-parts --arg='${release}' --arg='/boot/vmlinuz-${release}' /etc/kernel/postinst.d
EOF
  chmod +x "${tree}/DEBIAN/postinst"
  dpkg-deb --build --root-owner-group "${tree}" "${FIXTURE}/${base}-${revision}.deb" >/dev/null
}
make_kernel 7.2.0 1 0
make_kernel 7.2.0 2 0
make_kernel 7.3.0 1 0
make_kernel 7.3.0 2 1
cp "${FIXTURE}/7.2.0-1.deb" "${FIXTURE}/native/old.deb"
# Initial fixture install needs no initrd hook execution or bind mounts.
chroot "${FIXTURE}/native" dpkg --unpack /old.deb
rm "${FIXTURE}/native/old.deb"
# This fixture's baseline must be configured before the mirror's dpkg audit.
mkdir -p "${FIXTURE}/native/dev"
mount --bind /dev "${FIXTURE}/native/dev"
chroot "${FIXTURE}/native" dpkg --configure -a
chroot "${FIXTURE}/native" apt-mark hold linux-image-7.2.0-ceralive-rk3588
umount "${FIXTURE}/native/dev"
truncate -s 2G "${FIXTURE}/boot.img" "${FIXTURE}/target.img"
mkfs.ext4 -q -F -d "${FIXTURE}/native" "${FIXTURE}/boot.img"
mkfs.ext4 -q -F "${FIXTURE}/target.img"
boot_loop="$(losetup --find --show "${FIXTURE}/boot.img")"
target_loop="$(losetup --find --show "${FIXTURE}/target.img")"
mount -o ro "${boot_loop}" "${FIXTURE}/booted"
ln -sfn "${target_loop}" "${FIXTURE}/by-partlabel/rootfs_b"
printf '{"boot_id":"fixture-boot","slot":"A","build_id":"fixture-build","dpkg_status_sha256":"%s"}\n' \
  "$(sha256sum "${CERALIVE_DPKG_STATUS_FILE}" | cut -d' ' -f1)" >"${CERALIVE_HEALTHY_STATE_FILE}"
printf 'BUILD_ID="fixture-build"\n' >"${FIXTURE}/os-release"
export CERALIVE_OS_RELEASE_FILE="${FIXTURE}/os-release"
export CERALIVE_KERNEL_BOOT_STAGING="${REPO}/mkosi/runtime/ceralive-kernel-boot-staging.sh"
export CERALIVE_KERNEL_BOOT_VERIFY="${REPO}/lib/verify-boot-artifacts.sh"
# Todo 7 supplies closure semantics; the contract is stubbed even in this suite.
cat >"${FIXTURE}/firmware-and-boot" <<EOF
#!/bin/bash
if [[ "\$1" == firmware-check ]]; then
  [[ "\$#" -eq 6 && "\$3" == --kernel-release && "\$5" == --firmware-root ]]
else
  exec bash "${CERALIVE_KERNEL_BOOT_STAGING}" "\$@"
fi
EOF
chmod +x "${FIXTURE}/firmware-and-boot"
export CERALIVE_KERNEL_BOOT_STAGING="${FIXTURE}/firmware-and-boot"
# RAUC stub checks the observed target state. Mounted state is checked with real findmnt.
before="$(sha256sum "${FIXTURE}/boot.img")"
for tuple in '7.2.0 2' '7.3.0 1'; do
  read -r base revision <<<"${tuple}"
  rm -f "${FIXTURE}/state/kernel-state.json"
  TEST_PACKAGE="linux-image-${base}-ceralive-rk3588" TEST_VERSION="${base}-ceralive${revision}"
  TEST_DEB="${FIXTURE}/${base}-${revision}.deb"
  TEST_SHA="$(sha256sum "${TEST_DEB}" | cut -d' ' -f1)"
  export TEST_PACKAGE TEST_VERSION TEST_DEB TEST_SHA
  if [[ "${base}" == 7.2.0 ]]; then
    export TEST_ATTEMPT=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
  else
    export TEST_ATTEMPT=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb
  fi
  timeout --kill-after=15 300 bash -c '
    exec flock -n -E 75 -x "$CERALIVE_UPDATE_LOCK_PATH" "$CERALIVE_STAGE_SCRIPT" \
      --attempt "$TEST_ATTEMPT" --deb "$TEST_DEB" --package "$TEST_PACKAGE" --version "$TEST_VERSION" --sha256 "$TEST_SHA"
  '
  [[ "$(jq -r .state "${FIXTURE}/state/kernel-state.json")" == staged ]]
  mkdir -p "${FIXTURE}/inspect"
  mount -o ro "${target_loop}" "${FIXTURE}/inspect"
  [[ "$(chroot "${FIXTURE}/inspect" dpkg-query -W -f='${Version}' "${TEST_PACKAGE}")" == "${TEST_VERSION}" ]]
  chroot "${FIXTURE}/inspect" apt-mark showhold | grep -qxF "${TEST_PACKAGE}"
  grep -qxF "Pin: version ${TEST_VERSION}" "${FIXTURE}/inspect/etc/apt/preferences.d/ceralive-kernel-freeze"
  grep -qxF 'Package: armbian-firmware-full' "${FIXTURE}/inspect/etc/apt/preferences.d/ceralive-kernel-freeze"
  if [[ "${base}" == 7.3.0 ]]; then
    [[ ! -e "${FIXTURE}/inspect/boot/vmlinuz-7.2.0-ceralive-rk3588" ]]
    ! chroot "${FIXTURE}/inspect" apt-mark showhold | grep -qxF linux-image-7.2.0-ceralive-rk3588
  fi
  umount "${FIXTURE}/inspect"
  [[ "${before}" == "$(sha256sum "${FIXTURE}/boot.img")" ]]
done
rm -f "${FIXTURE}/state/kernel-state.json"
TEST_VERSION=7.3.0-ceralive2 TEST_DEB="${FIXTURE}/7.3.0-2.deb"
TEST_SHA="$(sha256sum "${TEST_DEB}" | cut -d' ' -f1)"
export TEST_VERSION TEST_DEB TEST_SHA
set +e
timeout --kill-after=15 300 flock -n -E 75 -x "${CERALIVE_UPDATE_LOCK_PATH}" "${CERALIVE_STAGE_SCRIPT}" \
  --attempt cccccccc-cccc-4ccc-8ccc-cccccccccccc --deb "${TEST_DEB}" --package "${TEST_PACKAGE}" --version "${TEST_VERSION}" --sha256 "${TEST_SHA}"
rc=$?
set -e
[[ "${rc}" -eq 75 && "$(<"${FIXTURE}/eligibility")" == bad ]]
[[ "$(jq -r .state "${FIXTURE}/state/kernel-state.json")" == failed ]]
[[ "$(jq -r .status "${FIXTURE}/state/slot-overlay-B.json")" == invalid ]]
[[ "${before}" == "$(sha256sum "${FIXTURE}/boot.img")" ]]
printf 'PASS real kernel stage: chroot install, freeze/hold, name change, failure, booted bytes\n'
