#!/bin/bash
# Private directory-backed slots. Real flock, .deb control/archive and rsync.
stage_fixture_init() {
  export FIXTURE="${WORK}/fixture"
  mkdir -p "${FIXTURE}/bin"
  local tool
  for tool in rauc busctl systemctl id mount umount findmnt e2fsck stat chroot \
    boot-staging boot-verify dumpe2fs rsync sync cp; do
    ln -s "${REPO}/tests/fixtures/kernel-stage-tool.sh" "${FIXTURE}/bin/${tool}"
  done
  export PATH="${FIXTURE}/bin:${PATH}"
  export CERALIVE_STAGE_SCRIPT="${STAGE_SCRIPT_OVERRIDE:-${REPO}/mkosi/runtime/ceralive-kernel-stage.sh}"
  export CERALIVE_SLOT_SYNC_LIB="${REPO}/mkosi/runtime/ceralive-slot-sync.sh"
  export CERALIVE_KERNEL_STATE_LIB="${REPO}/mkosi/runtime/ceralive-kernel-state-lib.sh"
  export CERALIVE_SLOT_RESERVE_LIB="${REPO}/lib/shared/slot-reserve.sh"
  export CERALIVE_KERNEL_STAGE_SOURCE="${FIXTURE}/mnt/source"
  export CERALIVE_KERNEL_STAGE_TARGET="${FIXTURE}/mnt/target"
  export CERALIVE_SLOT_SYNC_SOURCE="${CERALIVE_KERNEL_STAGE_SOURCE}"
  export CERALIVE_SLOT_SYNC_TARGET="${CERALIVE_KERNEL_STAGE_TARGET}"
  export CERALIVE_SLOT_SYNC_BIND_SOURCE="${FIXTURE}/booted"
  export CERALIVE_SLOT_SYNC_EXCLUDE="${REPO}/mkosi/runtime/ceralive-slot-sync.exclude"
  export CERALIVE_UPDATE_STATE_DIR="${FIXTURE}/state"
  export CERALIVE_UPDATE_LOCK_PATH="${FIXTURE}/update.lock"
  export CERALIVE_DPKG_LOCK_FRONTEND="${FIXTURE}/dpkg.lock"
  export CERALIVE_PARTLABEL_DIR="${FIXTURE}/by-partlabel"
  export CERALIVE_PARTLABEL_FAILURE="${FIXTURE}/partlabel-failed"
  export CERALIVE_HEALTHY_STATE_FILE="${FIXTURE}/state/healthy-state.json"
  export CERALIVE_SYNC_RECEIPT_FILE="${FIXTURE}/state/sync-receipt.json"
  export CERALIVE_RAUC_DATA_DIR="${FIXTURE}/rauc-data"
  export CERALIVE_HEALTHCHECK_BOOT_ID_FILE="${FIXTURE}/boot-id"
  export CERALIVE_DPKG_STATUS_FILE="${FIXTURE}/booted/var/lib/dpkg/status"
  export CERALIVE_OS_RELEASE_FILE="${FIXTURE}/booted/etc/os-release"
  export CERALIVE_IMAGE_VERSION_FILE="${FIXTURE}/absent-image"
  export CERALIVE_OS_RELEASE_VERSION_FILE="${FIXTURE}/absent-version"
  export CERALIVE_UPDATE_CAPABILITIES="${FIXTURE}/capabilities.json"
  export CERALIVE_BOARD_BOOT="${FIXTURE}/booted/usr/lib/ceralive/board-boot.json"
  export CERALIVE_KERNEL_BOOT_STAGING="${FIXTURE}/bin/boot-staging"
  export CERALIVE_KERNEL_BOOT_VERIFY="${FIXTURE}/bin/boot-verify"
  export CERALIVE_PRUNE_PATHS_LIST="${FIXTURE}/absent-prune"
  export RAUC_BIN="${FIXTURE}/bin/rauc" SYSTEMCTL_BIN="${FIXTURE}/bin/systemctl"
  export CERALIVE_BUSCTL="${FIXTURE}/bin/busctl"
  export CHROOT_BIN="${FIXTURE}/bin/chroot"
  export MOUNT_BIN="${FIXTURE}/bin/mount" UMOUNT_BIN="${FIXTURE}/bin/umount"
  export FINDMNT_BIN="${FIXTURE}/bin/findmnt" E2FSCK_BIN="${FIXTURE}/bin/e2fsck"
  export RSYNC_BIN="${FIXTURE}/bin/rsync" SYNC_BIN="${FIXTURE}/bin/sync"
  export DPKG_BIN="${FIXTURE}/bin/dpkg"
  ln -s "${REPO}/tests/fixtures/kernel-stage-tool.sh" "${DPKG_BIN}"
  export TEST_PACKAGE=linux-image-7.2.0-ceralive-rk3588 TEST_VERSION=7.2.0-ceralive2
  export TEST_ATTEMPT=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
  mkdir -p "${FIXTURE}/package/DEBIAN" "${FIXTURE}/package/boot"
  cat >"${FIXTURE}/package/DEBIAN/control" <<EOF
Package: ${TEST_PACKAGE}
Version: ${TEST_VERSION}
Architecture: arm64
Maintainer: CeraLive <test@ceralive.tv>
Installed-Size: 8
Description: offline kernel-stage fixture
EOF
  printf 'fixture kernel\n' >"${FIXTURE}/package/boot/vmlinuz-7.2.0-ceralive-rk3588"
  export TEST_DEB="${FIXTURE}/candidate.deb"
  dpkg-deb --build --root-owner-group "${FIXTURE}/package" "${TEST_DEB}" >/dev/null || return 1
  TEST_SHA="$(sha256sum "${TEST_DEB}" | cut -d' ' -f1)"
  export TEST_SHA
}

stage_fixture_reset() {
  unset FAIL_TOOL KILL_AT CAPACITY_AVAILABLE CAPACITY_ROOT_FREE CAPACITY_FREE CAPACITY_TOTAL FIRMWARE_RC \
    TEST_RAUC_OPERATION HAWKBIT_ACTIVE AUDIT_OUTPUT PRIMARY_SLOT UID_FIXTURE VERIFY_MISMATCH \
    MOUNT_TABLE_ERROR FINAL_MOUNT_LEAK FAIL_SYNC BIND_SAME_DEVICE HANG_TOOL \
    CERALIVE_KERNEL_STAGE_COMMAND_TIMEOUT TAMPER_CACHED_DEB
  rm -rf "${FIXTURE:?}/state" "${FIXTURE:?}/mnt" "${FIXTURE:?}/booted" "${FIXTURE:?}/rauc-data" "${FIXTURE:?}/by-partlabel"
  rm -f "${CERALIVE_PARTLABEL_FAILURE}" "${FIXTURE}/events" "${FIXTURE}/mounts" "${FIXTURE}/installed"
  mkdir -p "${FIXTURE}/state" "${FIXTURE}/mnt/source" "${FIXTURE}/mnt/target" \
    "${FIXTURE}/booted/etc/apt/preferences.d" "${FIXTURE}/booted/var/lib/dpkg" \
    "${FIXTURE}/booted/usr/lib/ceralive" "${FIXTURE}/by-partlabel" \
    "${FIXTURE}/rauc-data/slot.rootfs.1/hash-old"
  ln -s "${FIXTURE}/booted" "${FIXTURE}/by-partlabel/rootfs_a"
  ln -s "${FIXTURE}/mnt/target" "${FIXTURE}/by-partlabel/rootfs_b"
  printf 'stale\n' >"${FIXTURE}/rauc-data/slot.rootfs.1/hash-old/block-hash-index"
  printf '{"old":"receipt"}\n' >"${CERALIVE_SYNC_RECEIPT_FILE}"
  printf '{"status":"confirmed","attempt":"obsolete"}\n' >"${FIXTURE}/state/slot-overlay-B.json"
  printf 'original booted dpkg status\n' >"${CERALIVE_DPKG_STATUS_FILE}"
  printf 'BUILD_ID="fixture-build"\n' >"${CERALIVE_OS_RELEASE_FILE}"
  printf 'fixture-boot\n' >"${CERALIVE_HEALTHCHECK_BOOT_ID_FILE}"
  printf '{"features":["kernel-apt-stage"]}\n' >"${CERALIVE_UPDATE_CAPABILITIES}"
  cat >"${CERALIVE_BOARD_BOOT}" <<'EOF'
{
  "dtb_name": "rk3588-test.dtb",
  "dtb_deb_dir_template": "/usr/lib/linux-image-{kernel_release}/rockchip",
  "dtb_boot_dir": "/boot/dtb/rockchip",
  "kernel_package_regex": "^linux-image-[0-9]+[.][0-9]+[.][0-9]+-ceralive-rk3588$"
}
EOF
  printf '{"boot_id":"fixture-boot","slot":"A","build_id":"fixture-build","dpkg_status_sha256":"%s"}\n' \
    "$(sha256sum "${CERALIVE_DPKG_STATUS_FILE}" | cut -d' ' -f1)" >"${CERALIVE_HEALTHY_STATE_FILE}"
  cat >"${FIXTURE}/rauc.json" <<EOF
{"booted":"A","boot_primary":"rootfs.0","slots":[{"rootfs.0":{"class":"rootfs","device":"${FIXTURE}/by-partlabel/rootfs_a","bootname":"A","state":"booted","boot_status":"good","bundle":{"version":"2026.10.99"},"slot_status":{"bundle":{"hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"checksum":{"sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"installed":{"timestamp":"2026-10-01T00:00:00Z","count":3},"activated":{"timestamp":"2026-10-01T00:00:05Z","count":3}}}},{"rootfs.1":{"class":"rootfs","device":"${FIXTURE}/by-partlabel/rootfs_b","bootname":"B","state":"inactive","boot_status":"good","slot_status":{"bundle":{"hash":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"},"checksum":{"sha256":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"},"installed":{"timestamp":"2026-09-01T00:00:00Z","count":2},"activated":{"timestamp":"2026-09-01T00:00:05Z","count":2}}}}]}
EOF
  : >"${FIXTURE}/mounts"
  printf good >"${FIXTURE}/eligibility"
}

stage_args() {
  STAGE_ARGS=(--attempt "${TEST_ATTEMPT}" --deb "${TEST_DEB}" --package "${TEST_PACKAGE}" --version "${TEST_VERSION}" --sha256 "${TEST_SHA}")
}

# Exercise the same A/B contract in the other direction without changing labels.
stage_fixture_boot_b() {
  local updated
  updated="$(jq -c '.booted="B" | .boot_primary="rootfs.1" |
    .slots[0]["rootfs.0"].state="inactive" | .slots[1]["rootfs.1"].state="booted"' "${FIXTURE}/rauc.json")"
  printf '%s\n' "${updated}" >"${FIXTURE}/rauc.json"
  ln -sfn "${FIXTURE}/mnt/target" "${FIXTURE}/by-partlabel/rootfs_a"
  ln -sfn "${FIXTURE}/booted" "${FIXTURE}/by-partlabel/rootfs_b"
  updated="$(jq -c '.slot="B"' "${CERALIVE_HEALTHY_STATE_FILE}")"
  printf '%s\n' "${updated}" >"${CERALIVE_HEALTHY_STATE_FILE}"
  mv "${FIXTURE}/state/slot-overlay-B.json" "${FIXTURE}/state/slot-overlay-A.json"
  mv "${FIXTURE}/rauc-data/slot.rootfs.1" "${FIXTURE}/rauc-data/slot.rootfs.0"
}

# Native userspace stays host-architecture; APT sees the fixture's arm64 target.
stage_fixture_native_apt() {
  mkdir -p "${1:?}/etc/apt/apt.conf.d"
  printf 'APT::Architecture "arm64";\nAPT::Architectures { "arm64"; "amd64"; };\n' \
    >"${1}/etc/apt/apt.conf.d/99kernel-stage-fixture-architecture"
}

stage_run() {
  stage_args
  flock -n -E 75 -x "${CERALIVE_UPDATE_LOCK_PATH}" bash -c \
    'export STAGE_PID=$$; exec bash "$@"' stage "${CERALIVE_STAGE_SCRIPT}" "${STAGE_ARGS[@]}"
}

stage_recover() {
  flock -n -E 75 -x "${CERALIVE_UPDATE_LOCK_PATH}" bash "${CERALIVE_STAGE_SCRIPT}" --recover
}

stage_tree_hash() {
  (cd "${FIXTURE}/booted" && find . -type f -print0 | sort -z | xargs -0 sha256sum) | sha256sum
}
