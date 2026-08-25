#!/usr/bin/env bash
set -euo pipefail

: "${PACKAGE_NAME:?}"
: "${PACKAGE_VERSION:?}"
: "${KERNEL_RELEASE:?}"
: "${KERNEL_IMAGE_PACKAGE:?}"
: "${KERNEL_IMAGE_VERSION:?}"
: "${HEADERS_PACKAGE:?}"
: "${HEADERS_VERSION:?}"

work=/work
headers_root="${work}/headers-root"
headers="${headers_root}/usr/src/linux-headers-${KERNEL_RELEASE}"
module_dir="${work}/module"
package_root="${work}/package-root"

rm -rf "${headers_root}" "${module_dir}" "${package_root}"
mkdir -p "${headers_root}" "${module_dir}" "${package_root}"

# dpkg-deb -x attempts ownership changes on bind-mounted symlinks. Extracting the
# same data tar with --no-same-owner keeps this rootless and byte-equivalent.
dpkg-deb --fsys-tarfile "${work}/headers.deb" \
  | tar --no-same-owner -xf - -C "${headers_root}"
[[ -f "${headers}/Module.symvers" ]] || { echo "headers lack Module.symvers" >&2; exit 1; }
grep -qx 'CONFIG_MODVERSIONS=y' "${headers}/.config" \
  || { echo "headers do not describe a modversions kernel" >&2; exit 1; }

cp "${work}/cls_fw.c" "${module_dir}/cls_fw.c"
printf 'obj-m := cls_fw.o\n' >"${module_dir}/Makefile"

# Armbian's headers postinst prepares these host tools natively on an arm64
# device. This builder performs the equivalent cross-host preparation, then
# restores Armbian's packaged generated state before compiling the extension.
make -C "${headers}" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
make -C "${headers}" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)" scripts
make -C "${headers}" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)" M=scripts/mod
if [[ -f "${headers}/include/generated/.armbian-build.tar.gz" ]]; then
  tar -C "${headers}" -xzf "${headers}/include/generated/.armbian-build.tar.gz"
fi
make -C "${headers}" M="${module_dir}" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- modules

expected_vermagic="${KERNEL_RELEASE} SMP mod_unload modversions aarch64"
actual_vermagic="$(modinfo -F vermagic "${module_dir}/cls_fw.ko" | sed 's/[[:space:]]*$//')"
[[ "${actual_vermagic}" == "${expected_vermagic}" ]] \
  || { echo "vermagic mismatch: expected '${expected_vermagic}', got '${actual_vermagic}'" >&2; exit 1; }
[[ "$(modinfo -F name "${module_dir}/cls_fw.ko")" == cls_fw ]] \
  || { echo "built module is not cls_fw" >&2; exit 1; }

module_path="${package_root}/usr/lib/modules/${KERNEL_RELEASE}/updates/ceralive/cls_fw.ko"
install -D -m 0644 "${module_dir}/cls_fw.ko" "${module_path}"
install -d -m 0755 "${package_root}/usr/lib/modules-load.d" "${package_root}/DEBIAN"
printf 'cls_fw\n' >"${package_root}/usr/lib/modules-load.d/ceralive-cls-fw.conf"

cat >"${package_root}/DEBIAN/control" <<EOF
Package: ${PACKAGE_NAME}
Version: ${PACKAGE_VERSION}
Architecture: arm64
Maintainer: CeraLive <engineering@ceralive.tv>
Depends: ${KERNEL_IMAGE_PACKAGE} (= ${KERNEL_IMAGE_VERSION}), kmod
Section: kernel
Priority: optional
Description: firewall-mark tc classifier for CeraLive vendor kernel
 Out-of-tree build of the pinned vendor kernel's net/sched/cls_fw.c.
EOF
cat >"${package_root}/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e
depmod -a "${KERNEL_RELEASE}"
EOF
cat >"${package_root}/DEBIAN/postrm" <<EOF
#!/bin/sh
set -e
depmod -a "${KERNEL_RELEASE}"
EOF
chmod 0755 "${package_root}/DEBIAN/postinst" "${package_root}/DEBIAN/postrm"

dpkg-deb --build --root-owner-group "${package_root}" \
  "/out/${PACKAGE_NAME}_${PACKAGE_VERSION}_arm64.deb"
