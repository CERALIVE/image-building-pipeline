#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  BUILD_SCRIPT="${REPO_ROOT}/lib/build-kernel-extension.sh"
  CONTAINER_SCRIPT="${REPO_ROOT}/lib/kernel/build-cls-fw-container.sh"
  PIN_FILE="${REPO_ROOT}/manifests/kernel/vendor-cls-fw.env"
  FAMILY="${REPO_ROOT}/manifests/families/rk3588.yaml"
  ORCHESTRATOR="${REPO_ROOT}/lib/orchestrate.sh"
  STAGE="${REPO_ROOT}/lib/stages/kernel-build.sh"
  PARTITION="${REPO_ROOT}/lib/stages/partition.sh"
  PLATFORM="${REPO_ROOT}/mkosi/mkosi.images/platform/mkosi.postinst"
  PACKAGE_LIST="${REPO_ROOT}/manifests/packages/rk3588-vendor-kernel-extensions.list"
}

@test "vendor cls_fw: exact header and source inputs are pinned" {
  run grep -Fx 'HEADERS_PACKAGE=linux-headers-vendor-rk35xx' "${PIN_FILE}"
  [ "$status" -eq 0 ]
  grep -Fx 'HEADERS_VERSION=26.5.1' "${PIN_FILE}"
  grep -Fx 'KERNEL_RELEASE=6.1.115-vendor-rk35xx' "${PIN_FILE}"
  grep -Fx 'HEADERS_SHA256=12e3626e6e61b2754882f0f625e9092e5b1c13578d9b7555d38dbecabf910bf2' "${PIN_FILE}"
  grep -Fx 'SOURCE_COMMIT=95e85f6cb496c75807c5b16f158853578e7e7d1b' "${PIN_FILE}"
  grep -Fx 'SOURCE_SHA256=c83c4ec07b700f66919d7d54a3546ef30dea91b3e420c9b35bc69f6da92b5694' "${PIN_FILE}"
  grep -Fx 'ceralive-cls-fw' "${PACKAGE_LIST}"
}

@test "vendor cls_fw: build uses external-module kbuild and verifies exact vermagic" {
  grep -F 'M="${module_dir}" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- modules' "${CONTAINER_SCRIPT}"
  grep -F 'expected_vermagic="${KERNEL_RELEASE} SMP mod_unload modversions aarch64"' "${CONTAINER_SCRIPT}"
  grep -F 'usr/lib/modules/${KERNEL_RELEASE}/updates/ceralive/cls_fw.ko' "${CONTAINER_SCRIPT}"
}

@test "vendor cls_fw: package owns boot loading and depmod integration" {
  grep -F 'usr/lib/modules-load.d/ceralive-cls-fw.conf' "${CONTAINER_SCRIPT}"
  grep -F "printf 'cls_fw\\n'" "${CONTAINER_SCRIPT}"
  grep -F 'depmod -a "${KERNEL_RELEASE}"' "${CONTAINER_SCRIPT}"
  grep -F 'Depends: ${KERNEL_IMAGE_PACKAGE} (= ${KERNEL_IMAGE_VERSION}), kmod' "${CONTAINER_SCRIPT}"
}

@test "vendor cls_fw: production family declares it and source-built variants clear it" {
  grep -F 'kernel_extension_packages:' "${FAMILY}"
  grep -F '  - ceralive-cls-fw' "${FAMILY}"
  [ "$(grep -c '^    kernel_extension_packages: \[\]$' "${FAMILY}")" -eq 2 ]
}

@test "vendor cls_fw: orchestrator builds stages classifies and installs the package after the kernel" {
  grep -F 'BUILD_KERNEL_EXTENSION_SH=' "${ORCHESTRATOR}"
  grep -F 'kernel_extension_build_dir=' "${ORCHESTRATOR}"
  grep -F 'KERNEL_EXTENSION_PACKAGES' "${STAGE}"
  grep -F 'KERNEL_EXTENSION_PACKAGES' "${PARTITION}"

  kernel_line="$(grep -n 'mkosi-install -y --no-install-recommends "${boot_bsp\[@\]}"' "${PLATFORM}" | cut -d: -f1)"
  extension_line="$(grep -n 'mkosi-install -y --no-install-recommends "${kernel_extensions\[@\]}"' "${PLATFORM}" | cut -d: -f1)"
  [ -n "${kernel_line}" ]
  [ -n "${extension_line}" ]
  [ "${extension_line}" -gt "${kernel_line}" ]
}

@test "vendor cls_fw: dry-run is network and compiler free" {
  run env DRY_RUN=1 KERNEL_EXTENSION_PACKAGES=ceralive-cls-fw "${BUILD_SCRIPT}" \
    --out "${BATS_TEST_TMPDIR}/out"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN would build ceralive-cls-fw"* ]]
  [ ! -e "${BATS_TEST_TMPDIR}/out" ]
}
