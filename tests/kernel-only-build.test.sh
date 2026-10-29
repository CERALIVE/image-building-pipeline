#!/usr/bin/env bash
# Offline real entrypoints; only compiler/fetch/modinfo boundaries are doubled.
# shellcheck disable=SC2016
set -uo pipefail
TESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${TESTS}/.." && pwd)"
source "${TESTS}/lib/assertions.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
export WORK ROOT
export CERALIVE_APT_PROXY=off
MANIFEST="${ROOT}/manifests/rk3588-bluetooth-firmware-roots.txt"
mkdir -p "${WORK}/bin" "${WORK}/firmware" "${WORK}/built"
while read -r kind _module pattern _; do
  case "${kind}" in ''|'#'*|reviewed-hardware-gap) continue ;; esac
  object="${pattern//\*/fixture}"; [[ "${object}" != */ ]] || object+=fixture.bin
  mkdir -p "$(dirname "${WORK}/firmware/${object}")"
  printf 'blob\n' >"${WORK}/firmware/${object}"
done <"${MANIFEST}"
cat >"${WORK}/bin/modinfo" <<'SH'
#!/usr/bin/env bash
[[ "$1" == -F && -f "$3" ]] || exit 2
[[ "$(<"$3")" != unparseable ]] || exit 1
awk -v field="$2=" 'index($0,field)==1 {print substr($0,length(field)+1)}' "$3"
SH
chmod +x "${WORK}/bin/modinfo"
export PATH="${WORK}/bin:${PATH}"
R=7.2.0-ceralive-rk3588
eval "$("${ROOT}/lib/resolve.sh" rock-5b-plus)"
EXPECTED_V="${KERNEL_SOURCE_PACKAGE_VERSION}"
V="${EXPECTED_V}"
DEB="linux-image-${R}_${V}_arm64.deb"
export R V DEB

make_deb() {
  local format="${1:-gzip}" omit="${2:-}" pkg="${WORK}/package"
  rm -rf "${pkg}"
  mkdir -p "${pkg}/DEBIAN" "${pkg}/boot" "${pkg}/usr/lib/linux-image-${R}/rockchip" \
    "${pkg}/lib/modules/${R}/kernel/drivers/bluetooth" "${pkg}/lib/modules/${R}/kernel/lib"
  printf 'Package: linux-image-%s\nVersion: %s\nArchitecture: arm64\nMaintainer: Fixture <fixture@example.invalid>\nDescription: kernel-only offline gate\n' \
    "${R}" "${V}" >"${pkg}/DEBIAN/control"
  { head -c 56 /dev/zero; printf 'ARM\x64'; head -c $((5*1024*1024-60)) /dev/zero; } >"${WORK}/Image"
  case "${format}" in
    gzip) gzip -nc "${WORK}/Image" >"${pkg}/boot/vmlinuz-${R}" ;;
    xz) xz -c "${WORK}/Image" >"${pkg}/boot/vmlinuz-${R}" ;;
  esac
  local dtb
  for dtb in rk3588-rock-5b-plus.dtb rk3588-orangepi-5-plus.dtb; do
    [[ "${dtb}" != "${omit}" ]] || continue
    head -c 8192 /dev/zero >"${pkg}/usr/lib/linux-image-${R}/rockchip/${dtb}"
  done
  printf 'depends=btintel\n' >"${pkg}/lib/modules/${R}/kernel/drivers/bluetooth/btusb.ko"
  printf 'firmware=intel/ibt-11-5.sfi\n' >"${pkg}/lib/modules/${R}/kernel/lib/btintel.ko"
  dpkg-deb --build --root-owner-group "${pkg}" "${WORK}/built/${DEB}" >/dev/null || return 1
  printf 'CONFIG_FIXTURE=y\n' >"${WORK}/built/resolved.config"
  printf 'kernel/drivers/bluetooth/btusb.ko\nkernel/lib/btintel.ko\n' >"${WORK}/built/built-modules.txt"
  local sha
  sha="$(sha256sum "${WORK}/built/${DEB}")"; sha="${sha%% *}"
  printf '{"package":"linux-image-%s","version":"%s","arch":"arm64","kernel_release":"%s","deb_sha256":"%s","input_fingerprint":"%064d","kernel_epoch":1700000000,"validated_boards":[]}\n' \
    "${R}" "${V}" "${R}" "${sha}" 0 >"${WORK}/built/kernel-artifact.json"
}
cat >"${WORK}/builder" <<'SH'
#!/usr/bin/env bash
[[ "$1" == --board && "$3" == --out ]] || exit 2
mkdir -p "$4"
cp "${WORK}/built/"* "$4/"
SH
chmod +x "${WORK}/builder"
run_lane() {
  env DRY_RUN=0 bash -euo pipefail -c '
    source "${ROOT}/lib/common.sh"
    PIPELINE_DIR="${ROOT}"
    RESOLVE_SH="${ROOT}/lib/resolve.sh"
    VERIFY_BOOT_ARTIFACTS_SH="${ROOT}/lib/verify-boot-artifacts.sh"
    source "${ROOT}/lib/kernel/only.sh"
    BUILD_KERNEL_SH="${WORK}/builder"
    MKOSI_DIR="${WORK}/outputs"
    FAMILY=rk3588; board=rock-5b-plus; variant=edge; kernel_from_source=1
    kernel_only_firmware() {
      mkdir -p "$1/root/usr/lib"
      cp -a "${WORK}/firmware" "$1/root/usr/lib/firmware"
    }
    stage_kernel_only
  '
}
OUT="${WORK}/outputs/build/kernel-only/rk3588"
expect_lane_failure() {
  local label="$1" diagnostic="$2"
  if run_lane >"${WORK}/failure" 2>&1; then
    bad "${label}: success exit"; return
  fi
  if [[ ! -e "${OUT}" ]] && grep -Fq "${diagnostic}" "${WORK}/failure"; then
    ok "${label}: correct guard, non-zero and no outputs"
  else bad "${label}: wrong guard or outputs written: $(<"${WORK}/failure")"; fi
}

make_deb
if run_lane >"${WORK}/good" 2>&1; then
  ok 'good gzip Image passes both board scratch gates'
else
  bad "good gzip Image: $(<"${WORK}/good")"
fi
if [[ -d "${OUT}" ]] && [[ "$(find "${OUT}" -maxdepth 1 -type f | wc -l)" == 5 ]] &&
  (cd "${OUT}" && sha256sum -c SHA256SUMS >/dev/null) &&
  jq -e '.validated_boards == ["orange-pi-5-plus","rock-5b-plus"]' "${OUT}/kernel-artifact.json" >/dev/null; then
  ok 'success writes all five outputs and exact validated board list'
else
  bad 'five-output or board-list contract'
fi
cp -a "${OUT}" "${WORK}/previous"
make_deb gzip rk3588-orangepi-5-plus.dtb
if run_lane >"${WORK}/failure" 2>&1; then bad 'stale output: invalid replacement accepted'
elif diff -qr "${OUT}" "${WORK}/previous" >/dev/null; then ok 'failure preserves previous complete output bytes'
else bad 'failure changed existing outputs'; fi
rm -rf "${WORK}/outputs"
expect_lane_failure 'fixture lacking only Orange Pi DTB fails family gate' 'missing /usr/lib/linux-image-7.2.0-ceralive-rk3588/rockchip/rk3588-orangepi-5-plus.dtb'
make_deb gzip rk3588-rock-5b-plus.dtb
expect_lane_failure 'fixture lacking Rock DTB fails family gate' 'missing /usr/lib/linux-image-7.2.0-ceralive-rk3588/rockchip/rk3588-rock-5b-plus.dtb'
make_deb xz
expect_lane_failure 'xz vmlinuz fails raw boot gate' 'is xz-compressed'
make_deb
mv "${WORK}/firmware/intel/ibt-11-5.sfi" "${WORK}/blob"
expect_lane_failure 'missing firmware reference fails' 'missing: intel/ibt-11-5.sfi'
grep -qxF 'missing: intel/ibt-11-5.sfi' "${WORK}/failure" \
  && ok 'missing firmware diagnostic is exact' || bad 'missing reference diagnostic'
mv "${WORK}/blob" "${WORK}/firmware/intel/ibt-11-5.sfi"
V=7.2.0-wrong
make_deb
expect_lane_failure 'wrong package control version fails identity gate' "but the manifest declares kernel_source.package_version '${EXPECTED_V}'"
V="${EXPECTED_V}"
make_deb
jq '.deb_sha256 = ("0"*64)' "${WORK}/built/kernel-artifact.json" >"${WORK}/wrong-identity"
mv "${WORK}/wrong-identity" "${WORK}/built/kernel-artifact.json"
expect_lane_failure 'metadata digest mismatch fails without outputs' 'kernel artifact digest disagrees with gated bytes'
make_deb
if bash -euo pipefail -c '
  set -a
  eval "$("${ROOT}/lib/resolve.sh" rock-5b-plus)"
  set +a
  source "${ROOT}/lib/build-kernel.sh"
  KERNEL_SOURCE_COMMIT=bad
  main --board rock-5b-plus --out "${WORK}/bad-pin"
' >"${WORK}/bad-pin-log" 2>&1; then bad 'malformed source pin accepted'
elif grep -q 'kernel_source.commit must be an exact 40-character SHA' "${WORK}/bad-pin-log" && [[ ! -e "${WORK}/bad-pin" ]]; then
  ok 'bad source pin fails at pin guard with no output'
else bad "malformed pin failed at wrong guard: $(<"${WORK}/bad-pin-log")"; fi

# The public CLI chooses the family and skips every non-kernel stage.
for selector in rock-5b-plus rk3588; do
  if DRY_RUN=1 "${ROOT}/build" "${selector}" --kernel-only >"${WORK}/dry" 2>&1 &&
    grep -Fq '[1/9]' "${WORK}/dry" && grep -Fq '[2b/9]' "${WORK}/dry" &&
    ! grep -Eq '\[(2|2c|3|4|5|6|6b|6c|6d|7|8|9)/9\]' "${WORK}/dry"; then
    ok "real CLI ${selector}: only resolve and kernel stages"
  else bad "real CLI ${selector}: $(<"${WORK}/dry")"; fi
done
if DRY_RUN=1 "${ROOT}/build" rk3588 --kernel-only --release --variant edge-test >"${WORK}/debug" 2>&1; then
  bad 'edge-test release accepted'
elif grep -q 'REJECT edge-test enables forbidden' "${WORK}/debug" && ! grep -q '\[2b/9\]' "${WORK}/debug"; then
  ok 'edge-test release fails before building'
else bad "release failed at wrong guard: $(<"${WORK}/debug")"; fi
if DRY_RUN=1 "${ROOT}/build" --all --kernel-only >/dev/null 2>&1; then bad 'multi-board kernel-only accepted'
else ok 'multi-board selection rejected'; fi

# Exercise the installed interface against exactly the image closure.
ROOTFS="${WORK}/check-root"
mkdir -p "${ROOTFS}/usr/lib/ceralive"
dpkg-deb -x "${WORK}/built/${DEB}" "${ROOTFS}"
cat >"${ROOTFS}/usr/lib/ceralive/board-boot.json" <<'JSON'
{
 "dtb_name": "rk3588-rock-5b-plus.dtb",
 "dtb_deb_dir_template": "/usr/lib/linux-image-{kernel_release}/rockchip",
 "dtb_boot_dir": "/boot/dtb/rockchip",
 "kernel_package_regex": "^linux-image-[0-9]+[.][0-9]+[.][0-9]+-ceralive-rk3588$"
}
JSON
cp "${ROOT}/mkosi/customize/bluetooth-firmware.sh" "${ROOTFS}/usr/lib/ceralive/kernel-firmware-rules.sh"
cp "${MANIFEST}" "${ROOTFS}/usr/lib/ceralive/kernel-firmware-rules.txt"
cp "${ROOT}/mkosi/runtime/ceralive-kernel-boot-staging.sh" "${ROOTFS}/usr/lib/ceralive/ceralive-kernel-boot-staging"
check_fw() {
  bash "${ROOTFS}/usr/lib/ceralive/ceralive-kernel-boot-staging" firmware-check "${ROOTFS}" \
    --kernel-release "${R}" --firmware-root "${WORK}/firmware" "$@"
}
MODULES="${ROOTFS}/lib/modules/${R}"
image_check() { bash "${ROOT}/lib/check-bluetooth-firmware.sh" "${MODULES}" "${WORK}/firmware" "${MANIFEST}"; }
tree_manifest() {
  (cd "$1" || exit; find . -printf '%y %p %l\n' | LC_ALL=C sort; find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum)
}
tree_manifest "${ROOTFS}" >"${WORK}/before-root"
tree_manifest "${WORK}/firmware" >"${WORK}/before-fw"
if check_fw >"${WORK}/refs" 2>&1 && image_check >"${WORK}/image-good" 2>&1; then
  ok 'installed interface and image checker accept the same Bluetooth closure'
else bad 'valid Bluetooth closure rejected'; fi
tree_manifest "${ROOTFS}" >"${WORK}/after-root"
tree_manifest "${WORK}/firmware" >"${WORK}/after-fw"
if cmp -s "${WORK}/before-root" "${WORK}/after-root" && cmp -s "${WORK}/before-fw" "${WORK}/after-fw"; then
  ok 'firmware-check modifies neither root nor firmware'
else bad 'firmware-check mutated its inputs'; fi
MODS="${MODULES}/kernel/drivers/net"
mkdir -p "${MODS}"
printf 'depends=absent_wifi_core\nfirmware=vendor/missing.bin\n' >"${MODS}/wifi.ko"
printf 'unparseable\n' >"${MODS}/other.ko"
if check_fw && image_check >/dev/null; then
  ok 'unrelated modules and their firmware are outside both image and kernel gates'
else bad 'firmware-check widened the image module scope'; fi
printf 'depends=recursive_bt\n' >"${MODULES}/kernel/drivers/bluetooth/btusb.ko"
printf 'firmware=third/present.bin\n' >"${MODS}/recursive_bt.ko"
mkdir -p "${WORK}/firmware/third"; printf blob >"${WORK}/firmware/third/present.bin"
check_fw >/dev/null 2>&1; rc=$?
[[ "${rc}" == 2 ]] && ok 'recursive Bluetooth closure refuses unreviewed static reference even if present' \
  || bad 'Bluetooth review classification bypassed'
rm "${MODS}/recursive_bt.ko"
check_fw >"${WORK}/deps" 2>&1; rc=$?
[[ "${rc}" == 2 ]] && ok 'missing recursive dependency refuses unprovable closure' || bad 'dependency closure silently incomplete'
printf 'depends=btintel\n' >"${MODULES}/kernel/drivers/bluetooth/btusb.ko"
cp "${MODULES}/kernel/lib/btintel.ko" "${WORK}/btintel-metadata"
printf 'unparseable\n' >"${MODULES}/kernel/lib/btintel.ko"
check_fw >/dev/null 2>&1; rc=$?
[[ "${rc}" == 2 ]] && ok 'one unparseable closure module fails closed' || bad 'unparseable closure module accepted'
mv "${WORK}/btintel-metadata" "${MODULES}/kernel/lib/btintel.ko"
mkdir -p "${MODULES}/kernel/net/bluetooth" "${MODULES}/kernel/drivers/hid"
printf 'depends=absent_protocol_core\n' >"${MODULES}/kernel/net/bluetooth/bluetooth.ko"
check_fw >/dev/null 2>&1; rc=$?
[[ "${rc}" == 2 ]] && ok 'net/bluetooth modules are closure roots' || bad 'Bluetooth protocol module ignored'
rm "${MODULES}/kernel/net/bluetooth/bluetooth.ko"
printf 'depends=absent_uhid_core\n' >"${MODULES}/kernel/drivers/hid/uhid.ko"
check_fw >/dev/null 2>&1; rc=$?
[[ "${rc}" == 2 ]] && ok 'UHID modules are closure roots' || bad 'UHID module ignored'
rm "${MODULES}/kernel/drivers/hid/uhid.ko"
touch "${MODULES}/kernel/drivers/bluetooth/btbcm.ko" "${MODULES}/kernel/drivers/bluetooth/btqca.ko"
if check_fw; then ok 'btbcm and btqca zero-static-ref runtime roots pass'
else bad 'runtime root gate'; fi
rm -rf "${WORK}/firmware/qca"
check_fw >"${WORK}/runtime-missing" 2>&1; rc=$?
if [[ "${rc}" == 1 && "$(<"${WORK}/runtime-missing")" == 'missing: qca/' ]]; then
  ok 'missing runtime root: exit 1 and exact stderr'
else bad "runtime root status ${rc}: $(<"${WORK}/runtime-missing")"; fi
mkdir -p "${WORK}/firmware/qca"; printf blob >"${WORK}/firmware/qca/fixture.bin"
ln -s absent.bin "${WORK}/firmware/qca/z-dangling.bin"
check_fw >"${WORK}/dangling" 2>&1; rc=$?
if [[ "${rc}" == 1 && "$(<"${WORK}/dangling")" == 'missing: qca/z-dangling.bin' ]]; then
  ok 'valid first runtime object cannot hide a dangling later object'
else bad 'non-first dangling runtime closure object accepted'; fi
rm "${WORK}/firmware/qca/z-dangling.bin"
printf blob >"${WORK}/outside.bin"
ln -s "${WORK}/outside.bin" "${WORK}/firmware/qca/z-escaping.bin"
check_fw >"${WORK}/escaping" 2>&1; rc=$?
if [[ "${rc}" == 1 && "$(<"${WORK}/escaping")" == 'missing: qca/z-escaping.bin' ]]; then
  ok 'valid first runtime object cannot hide an escaping later object'
else bad 'non-first escaping runtime closure object accepted'; fi
rm "${WORK}/firmware/qca/z-escaping.bin"
for mutation in 'reviewed-hardware-gap btrtl rtl_bt/third.bin # unapproved' 'reviewed-hardware-gap btrtl rtl_bt/*.bin # unapproved'; do
  cp "${MANIFEST}" "${ROOTFS}/usr/lib/ceralive/kernel-firmware-rules.txt"
  printf '%s\n' "${mutation}" >>"${ROOTFS}/usr/lib/ceralive/kernel-firmware-rules.txt"
  check_fw >"${WORK}/policy-mutation" 2>&1; rc=$?
  if [[ "${rc}" == 2 ]]; then ok "installed parser rejects ${mutation}"
  else bad "installed parser accepted ${mutation}"; fi
done
cp "${MANIFEST}" "${ROOTFS}/usr/lib/ceralive/kernel-firmware-rules.txt"
if check_fw; then ok 'restored reviewed policy passes after gap mutations'
else bad 'restored policy rejected'; fi
check_fw --bogus >/dev/null 2>&1; rc=$?
[[ "${rc}" == 2 ]] && ok 'usage error exits 2' || bad 'usage exit code'
mv "${ROOTFS}/usr/lib/ceralive/board-boot.json" "${WORK}/board.json"
check_fw >/dev/null 2>&1; rc=$?
[[ "${rc}" == 2 ]] && ok 'identity error exits 2' || bad 'identity exit code'
mv "${WORK}/board.json" "${ROOTFS}/usr/lib/ceralive/board-boot.json"

# Pins and closure define artifact identity, not board or local container IDs.
if bash -euo pipefail -c '
  source "${ROOT}/lib/build-kernel.sh"
  eval "$("${ROOT}/lib/resolve.sh" rock-5b-plus)"
  git_url="$KERNEL_SOURCE_GIT_URL"; tag="$KERNEL_SOURCE_TAG"; commit="$KERNEL_SOURCE_COMMIT"
  patches_url="$KERNEL_SOURCE_PATCHES_GIT_URL"; patches_commit="$KERNEL_SOURCE_PATCHES_COMMIT"
  patches_series="$KERNEL_SOURCE_PATCHES_SERIES"; defconfig_base="$KERNEL_SOURCE_DEFCONFIG_BASE"
  fragment_rel="$KERNEL_SOURCE_DEFCONFIG_FRAGMENT"; fragments_rel=""
  config_git_url=""; config_commit=""; config_path=""; absent_rel=""
  config_mode=""; config_desc=""; absent_list=""; fragments=(); fragments_rel_list=()
  resolve_kernel_config_mode
  builder_image="$KERNEL_SOURCE_BUILDER_IMAGE"; builder_digest=id1
  builder_packages="gcc-aarch64-linux-gnu=14.2 amd64"; builder_compiler="gcc 14.2"
  arch="$ARCH"; kernel_pkg="$KERNEL_PACKAGES"; kernel_release="$KERNEL_SOURCE_KERNEL_RELEASE"
  local_version="$KERNEL_SOURCE_LOCAL_VERSION"; package_version="$KERNEL_SOURCE_PACKAGE_VERSION"
  epoch=1700000000; dtb_path="$KERNEL_SOURCE_DTB_DEB_DIR/$DTB_NAME"
  a="$(kernel_input_fingerprint)"; cache="$(kernel_artifact_cache_key)"
  eval "$("${ROOT}/lib/resolve.sh" orange-pi-5-plus)"
  dtb_path="$KERNEL_SOURCE_DTB_DEB_DIR/$DTB_NAME"
  [[ "$(kernel_input_fingerprint)" == "$a" && "$(kernel_artifact_cache_key)" != "$cache" ]]
  builder_digest=id2
  [[ "$(kernel_input_fingerprint)" == "$a" ]]
  builder_packages="gcc-aarch64-linux-gnu=14.3 amd64"
  [[ "$(kernel_input_fingerprint)" != "$a" ]]
  builder_packages="gcc-aarch64-linux-gnu=14.2 amd64"; builder_compiler="gcc 14.3"
  [[ "$(kernel_input_fingerprint)" != "$a" ]]
  builder_compiler="gcc 14.2"; epoch=1700000001
  [[ "$(kernel_input_fingerprint)" != "$a" ]]
  epoch=1700000000; input_fingerprint="$a"
  kernel_artifact_identity "${WORK}/built" "${WORK}/built/${DEB}"
  jq -e --arg fingerprint "$a" --arg release "$R" --arg version "$V" \
    --arg sha "$(sha256sum "${WORK}/built/${DEB}" | cut -d" " -f1)" \
    '\''
      .input_fingerprint == $fingerprint and .kernel_epoch == 1700000000 and
      .package == ("linux-image-" + $release) and .version == $version and
      .arch == "arm64" and .kernel_release == $release and .deb_sha256 == $sha and
      .validated_boards == [] and
      .builder_closure.packages == ["gcc-aarch64-linux-gnu=14.2 amd64"] and
      .builder_closure.compiler == "gcc 14.2" and
      (.builder_closure.dockerfile_sha256 | test("^[0-9a-f]{64}$"))
    '\'' "${WORK}/built/kernel-artifact.json" >/dev/null
' >"${WORK}/fingerprint" 2>&1; then
  ok 'family fingerprint excludes board/local image ID and real metadata retains closure, compiler, epoch and byte identity'
else bad "fingerprint split: $(<"${WORK}/fingerprint")"; fi

# Execute the shipped epoch block with real git, a fixed pin and a newer HEAD.
mkdir -p "${WORK}/kernel-source"
GIT_MASTER=1 git -C "${WORK}/kernel-source" init -q
GIT_AUTHOR_DATE=@1600000000 GIT_COMMITTER_DATE=@1700000000 GIT_MASTER=1 git -C "${WORK}/kernel-source" \
  -c user.name=Fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null \
  commit --allow-empty -qm pinned
PIN="$(GIT_MASTER=1 git -C "${WORK}/kernel-source" rev-parse HEAD)"
GIT_AUTHOR_DATE=@1800000000 GIT_COMMITTER_DATE=@1800000000 GIT_MASTER=1 git -C "${WORK}/kernel-source" \
  -c user.name=Fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null \
  commit --allow-empty -qm unrelated-head
block="$(sed -n '/^      # Read before git am/,/^      git config user.email/p' "${ROOT}/lib/build-kernel.sh")"
block="${block%git config user.email*}"
block="${block//\/out\/kernel-epoch/${WORK}/kernel-epoch}"
if (cd "${WORK}/kernel-source"; export SOURCE_DATE_EPOCH=1900000000 KERNEL_COMMIT="${PIN}" KERNEL_EPOCH_ONLY=0; eval "${block}"; \
  [[ "${SOURCE_DATE_EPOCH}" == 1700000000 && "${KBUILD_BUILD_TIMESTAMP}" == @1700000000 ]]); then
  ok 'epoch is pinned committer time regardless of newer HEAD and ambient epoch'
else bad 'epoch derivation'; fi

# Exercise the pinned mkdebian timestamp expression and real archive writer
# under two clocks, not just the epoch calculation above.
mkdir -p "${WORK}/packaging/scripts/package" "${WORK}/clock"
cat >"${WORK}/clock/date" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == -R ]]; then
  exec /usr/bin/date -u -R -d "@${WALL_CLOCK}"
fi
exec /usr/bin/date "$@"
SH
chmod +x "${WORK}/clock/date"
packaging_block="$(sed -n '/^      # Pin Debian packaging/,/^      echo "== make bindeb-pkg/p' "${ROOT}/lib/build-kernel.sh")"
packaging_block="${packaging_block%echo \"== make bindeb-pkg*}"
if (
  set -e
  cd "${WORK}/packaging"
  export SOURCE_DATE_EPOCH=1700000000 PATH="${WORK}/clock:${PATH}"
  for clock in 1800000000 1900000000; do
    export WALL_CLOCK="${clock}"
    cat >scripts/package/mkdebian <<'SH'
#!/bin/sh
# Timestamp expression from the pinned kernel's scripts/package/mkdebian.
mkdir -p package/DEBIAN package/usr/share/doc/kernel
cat <<EOF >package/usr/share/doc/kernel/changelog.Debian
linux-upstream (1-fixture) unstable; urgency=low

  * Custom built Linux kernel.

 -- Fixture <fixture@example.invalid>  $(date -R)
EOF
SH
    eval "${packaging_block}" || exit 1
    sh scripts/package/mkdebian || exit 1
    printf 'Package: kernel\nVersion: 1-fixture\nArchitecture: arm64\nMaintainer: Fixture <fixture@example.invalid>\nDescription: packaging clock regression\n' >package/DEBIAN/control
    dpkg-deb --build --root-owner-group package "${clock}.deb" >/dev/null || exit 1
    dpkg-deb -x "${clock}.deb" "unpacked-${clock}" || exit 1
    grep -qxF ' -- Fixture <fixture@example.invalid>  Tue, 14 Nov 2023 22:13:20 +0000' \
      "unpacked-${clock}/usr/share/doc/kernel/changelog.Debian" || exit 1
  done
  cmp 1800000000.deb 1900000000.deb
); then
  ok 'packaging changelog and complete deb bytes use pinned epoch under different wall clocks'
else bad 'wall clock leaked into Debian packaging'; fi

# File names, symlink targets and modinfo metadata from the real pinned tuple;
# no firmware or ELF payload bytes are needed to exercise closure semantics.
RECORDED="${WORK}/recorded"
eval "$("${ROOT}/lib/resolve.sh" rock-5b-plus)"
python3 - "${ROOT}/tests/fixtures/kernel-firmware-v7.2.json" "${RECORDED}" \
  "${KERNEL_SOURCE_COMMIT}" "${KERNEL_SOURCE_PATCHES_COMMIT}" "${KERNEL_SOURCE_KERNEL_RELEASE}" \
  "${KERNEL_SOURCE_PACKAGE_VERSION}" "${ROOT}/manifests/armbian-firmware-content.json" <<'PY'
import hashlib
import json
import pathlib
import sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
provenance = data['provenance']
# The captured revision-1 archive stays historical; only the packaging revision advances.
assert sys.argv[6] == '7.2.0-ceralive2'
assert [provenance[key] for key in ('kernel_source_commit', 'patches_commit', 'kernel_release', 'kernel_package_version')] == [*sys.argv[3:6], '7.2.0-ceralive1']
firmware = json.loads(pathlib.Path(sys.argv[7]).read_text())
assert [provenance[key] for key in ('firmware_package', 'firmware_version', 'firmware_archive_sha256')] == [firmware[key] for key in ('package', 'version', 'archive_sha256')]
paths = [row[0].removeprefix('kernel/') for row in data['modules']]
inventory = ''.join(path + '\n' for path in sorted(prefix + path
                    for prefix in data['built_modules_prefixes'] for path in paths))
assert hashlib.sha256(inventory.encode()).hexdigest() == provenance['built_modules_sha256']
root = pathlib.Path(sys.argv[2])
modules = root / 'root/lib/modules' / data['provenance']['kernel_release']
modules.mkdir(parents=True)
for path, depends, refs in data['modules']:
    file = modules / path
    file.parent.mkdir(parents=True, exist_ok=True)
    file.write_text('depends=' + depends + '\n' + ''.join('firmware=' + ref + '\n' for ref in refs))
(modules / 'modules.builtin').write_text('\n'.join(data['builtin']) + '\n')
fw = root / 'firmware'
for entry in data['firmware']:
    file = fw / entry[0]
    file.parent.mkdir(parents=True, exist_ok=True)
    if len(entry) == 1:
        file.touch()
for entry in data['firmware']:
    if len(entry) == 2:
        (fw / entry[0]).symlink_to(entry[1])
PY
if [[ $? == 0 ]]; then ok 'revision-1 metadata matches current source/firmware pins and the revision-2 transition'
else bad 'stale real metadata fixture or unreviewed package revision'; exit 1; fi
mkdir -p "${RECORDED}/root/usr/lib" "${RECORDED}/root/boot"
cp -a "${ROOTFS}/usr/lib/ceralive" "${RECORDED}/root/usr/lib/"
cp "${ROOTFS}/boot/vmlinuz-${R}" "${RECORDED}/root/boot/"
recorded_check() {
  bash "${RECORDED}/root/usr/lib/ceralive/ceralive-kernel-boot-staging" firmware-check \
    "${RECORDED}/root" --kernel-release "${R}" --firmware-root "${RECORDED}/firmware"
}
if recorded_check >"${WORK}/recorded-good" 2>&1; then
  ok 'actual v7.2 module set passes the exact pinned firmware archive inventory'
else
  bad "actual v7.2 closure rejected: $(<"${WORK}/recorded-good")"
fi
for required in intel/ibt-11-5.sfi mediatek/mt7925/BT_RAM_CODE_MT7925_1_1_hdr.bin; do
  mv "${RECORDED}/firmware/${required}" "${WORK}/required-blob"
  recorded_check >"${WORK}/recorded-missing" 2>&1; rc=$?
  if [[ "${rc}" == 1 && "$(<"${WORK}/recorded-missing")" == "missing: ${required}" ]]; then
    ok "actual v7.2 set refuses missing required Bluetooth blob ${required}"
  else bad "actual required reference was waived: ${required}"; fi
  mv "${WORK}/required-blob" "${RECORDED}/firmware/${required}"
done
# The current inventory includes absent non-Bluetooth declarations; neither
# gate may turn them into new scope or hide an in-scope required object.
for ungated in arm/mali/arch10.8/mali_csffw.bin mediatek/mt7925/WIFI_RAM_CODE_MT7925_1_1.bin; do
  mv "${RECORDED}/firmware/${ungated}" "${WORK}/ungated-blob"
  if recorded_check && bash "${ROOT}/lib/check-bluetooth-firmware.sh" \
    "${RECORDED}/root/lib/modules/${R}" "${RECORDED}/firmware" >/dev/null; then
    ok "both gates leave non-Bluetooth firmware outside scope: ${ungated}"
  else bad "non-Bluetooth firmware gated: ${ungated}"; fi
  mv "${WORK}/ungated-blob" "${RECORDED}/firmware/${ungated}"
done

printf 'Kernel-only build contract: %s passed, %s failed\n' "${PASS}" "${FAIL}"
(( FAIL == 0 ))
