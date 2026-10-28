#!/usr/bin/env bash
# Real signed-index, fetch, staging, config and boot gates; external byte transport only is stubbed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${ROOT}/tests/lib/assertions.sh"
source "${ROOT}/tests/lib/kernel-release-fixtures.sh"
WORK="$(mktemp -d)"
finish() {
  gpgconf --homedir "${WORK}/gnupg" --kill all 2>/dev/null || true
  rm -rf -- "${WORK}"
}
trap finish EXIT
export ROOT WORK
repo="${WORK}/repo"
kernel_test_repo "${repo}"
kernel_test_version "${repo}" 7.2.0-ceralive2
export CERALIVE_KERNEL_HISTORY_DIR="${WORK}/history"
kernel_test_artifact "${WORK}/history/7.2.0-ceralive2" 7.2.0-ceralive2 "${repo}"
name=linux-image-7.2.0-ceralive-rk3588_7.2.0-ceralive2_arm64.deb
mkdir -p "${WORK}/apt/pool" "${WORK}/gnupg" "${WORK}/bin"
chmod 700 "${WORK}/gnupg"
gpg --homedir "${WORK}/gnupg" --batch --passphrase '' \
  --quick-generate-key 'Kernel fixture <fixture@example.invalid>' rsa2048 sign 0 >/dev/null 2>&1
export APT_GPG_PUBLIC_B64
APT_GPG_PUBLIC_B64="$(gpg --homedir "${WORK}/gnupg" --batch --export | base64 -w0)"
export APT_CLIENT_CRT_B64=Y2VydA== APT_CLIENT_KEY_B64=a2V5
export CERALIVE_DEBCACHE=0 CERALIVE_REMOTE_CACHE=0 CERALIVE_APT_PROXY=off
export FETCH_DEBS_FIRST_PARTY_TRANSPORT=curl CERALIVE_KERNEL_ARTIFACT_CACHE=0
export KERNEL_TEST_APT="${WORK}/apt" KERNEL_TEST_CURL_LOG="${WORK}/curl.log"
export KERNEL_TEST_RUNTIME_LOG="${WORK}/runtime.log"
cat >"${WORK}/bin/curl" <<'PY'
#!/usr/bin/env python3
import os, pathlib, shutil, sys
args = sys.argv[1:]
dest = pathlib.Path(args[args.index('-o') + 1])
url = args[-1]
prefixes = ('https://apt.ceralive.tv/dists/stable/binary-arm64/',
            'https://foreign.invalid/dists/stable/binary-arm64/')
relative = next((url.removeprefix(p) for p in prefixes if url.startswith(p)), None)
if relative is None and url.startswith('https://foreign.invalid/'):
    relative = 'pool/' + url.rsplit('/', 1)[1]
assert relative is not None, url
for flag in ('--cert', '--key'):
    assert flag in args and pathlib.Path(args[args.index(flag)+1]).is_file()
with open(os.environ['KERNEL_TEST_CURL_LOG'], 'a') as log:
    log.write(url + '\n')
shutil.copyfile(pathlib.Path(os.environ['KERNEL_TEST_APT']) / relative, dest)
PY
cat >"${WORK}/bin/docker" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${KERNEL_TEST_RUNTIME_LOG}"
exit 99
SH
cp "${WORK}/bin/docker" "${WORK}/bin/podman"
chmod 755 "${WORK}/bin/"*
export PATH="${WORK}/bin:${PATH}"

sign_index() {
  gzip -nc "${WORK}/apt/Packages" >"${WORK}/apt/Packages.gz"
  printf 'SHA256:\n %s %s Packages.gz\n' \
    "$(sha256sum "${WORK}/apt/Packages.gz" | cut -d' ' -f1)" \
    "$(stat -c %s "${WORK}/apt/Packages.gz")" >"${WORK}/Release"
  gpg --homedir "${WORK}/gnupg" --batch --yes --clearsign \
    --output "${WORK}/apt/InRelease" "${WORK}/Release"
}
good_index() {
  cp "${WORK}/history/7.2.0-ceralive2/${name}" "${WORK}/apt/pool/${name}"
  printf 'Package: linux-image-7.2.0-ceralive-rk3588\nVersion: 7.2.0-ceralive2\nArchitecture: arm64\nFilename: pool/%s\nSHA256: %s\n\n' \
    "${name}" "$(sha256sum "${WORK}/apt/pool/${name}" | cut -d' ' -f1)" >"${WORK}/apt/Packages"
  sign_index
}
fetch_kernel() (
  local stage="$1"
  set -a
  eval "$("${repo}/lib/resolve.sh" rock-5b-plus)"
  set +a
  unset KERNEL_VARIANT
  source "${repo}/lib/fetch-debs.sh"
  DEST="${stage}"; DRY_RUN=""
  FIRST_PARTY_APT_PKGS=()
  export FIRST_PARTY_APT_PKGS
  mkdir -p "${stage}/debs" "${stage}/kernel-build"
  fetch_first_party "${stage}/debs"
  fetch_lock_sidecar
)
stage_kernel() (
  local board="$1" staging="$2" variant=default kernel_from_source=1
  local kernel_build_dir="${staging}/kernel-build"
  set -a
  eval "$("${repo}/lib/resolve.sh" "${board}")"
  set +a
  unset KERNEL_VARIANT
  source "${repo}/lib/common.sh"
  source "${repo}/lib/shared/deb-lib.sh"
  source "${repo}/lib/stages/partition.sh"
  source "${repo}/lib/stages/kernel-build.sh"
  RESOLVE_SH="${repo}/lib/resolve.sh"
  BUILD_KERNEL_SH="${repo}/lib/kernel/released.sh"
  MKOSI_PACKAGE_STAGING_SH="${repo}/lib/stage-mkosi-package.sh"
  stage_kernel_build
  [[ " ${CERALIVE_KERNEL_SOURCE_SUPPRESSED_PKGS} " != *" ${KERNEL_PACKAGES} "* ]]
  local root="${staging}/scratch"
  mkdir -p "${root}/usr/lib/ceralive"
  dpkg-deb -x "${kernel_build_dir}/${name}" "${root}"
  printf '{"dtb_name":"%s","dtb_deb_dir_template":"/usr/lib/linux-image-{kernel_release}/rockchip","dtb_boot_dir":"/boot/dtb/rockchip","kernel_package_regex":"^linux-image-[0-9]+[.][0-9]+[.][0-9]+-ceralive-rk3588$"}\n' \
    "${DTB_NAME}" >"${root}/usr/lib/ceralive/board-boot.json"
  bash "${repo}/mkosi/runtime/ceralive-kernel-boot-staging.sh" "${root}" --kernel-release "${KERNEL_SOURCE_KERNEL_RELEASE}" --no-initrd
  bash "${repo}/lib/verify-boot-artifacts.sh" --root-dir "${root}" --dtb-name "${DTB_NAME}" --skip-initrd
)
refuse() {
  local label="$1" diagnostic="$2"; shift 2
  if "$@" >"${WORK}/refused" 2>&1; then bad "${label}: accepted"
  elif grep -Fq "${diagnostic}" "${WORK}/refused"; then ok "${label}"
  else bad "${label}: wrong guard"; cat "${WORK}/refused"; fi
}
good_index
for board in rock-5b-plus orange-pi-5-plus; do
  stage="${WORK}/${board}"
  fetch_kernel "${stage}"
  stage_kernel "${board}" "${stage}"
  cmp "${stage}/kernel-build/resolved.config" "${WORK}/history/7.2.0-ceralive2/resolved.config"
  cmp "${stage}/kernel-build/built-modules.txt" "${WORK}/history/7.2.0-ceralive2/built-modules.txt"
  cmp "${stage}/debs/${name}" "${WORK}/apt/pool/${name}"
  jq -e 'select(.name=="linux-image-7.2.0-ceralive-rk3588") | .origin=="ceralive-kernel"' \
    "${stage}/packages-lock/fetch.jsonl" >/dev/null
  ok "clean-host ${board} reuses APT bytes and restores metadata through real board gates"
done
[[ ! -e "${WORK}/runtime.log" && ! -e "${repo}/mkosi/cache/kernel-artifacts" ]]
ok 'APT reuse never invokes a compiler/container or the local kernel artifact cache'
APT_CERALIVE_URL=https://foreign.invalid refuse 'foreign configured origin refuses before download' \
  kernel_origin_mismatch fetch_kernel "${WORK}/foreign"
sed "s|Filename: pool/|Filename: https://foreign.invalid/|" "${WORK}/apt/Packages" >"${WORK}/other-origin"
cp "${WORK}/other-origin" "${WORK}/apt/Packages"; sign_index
refuse 'same-name foreign package URL is refused' kernel_origin_mismatch fetch_kernel "${WORK}/foreign-url"
if grep -q '^https://foreign.invalid/' "${WORK}/curl.log"; then bad 'kernel credentials reached a foreign origin'
else ok 'origin guards reject both foreign forms before any foreign request'; fi
good_index
cp "${WORK}/apt/Packages" "${WORK}/duplicate"
cat "${WORK}/duplicate" >>"${WORK}/apt/Packages"
sign_index
refuse 'duplicate exact kernel records cannot become a local-build miss' \
  'ambiguous or malformed' fetch_kernel "${WORK}/duplicate-record"
good_index
printf corrupt >>"${WORK}/apt/pool/${name}"
refuse 'APT bytes with wrong signed-index digest fail' 'kernel APT digest/control' fetch_kernel "${WORK}/bad-apt"
good_index
cp -a "${WORK}/history/7.2.0-ceralive2" "${WORK}/saved-release"
jq '.deb_sha256 = ("f"*64)' "${WORK}/saved-release/kernel-artifact.json" >"${WORK}/history/7.2.0-ceralive2/kernel-artifact.json"
(
  cd "${WORK}/history/7.2.0-ceralive2"
  sha256sum resolved.config built-modules.txt kernel-artifact.json >SHA256SUMS
)
# Use an internally consistent release checksum list, varying only the .deb identity.
python3 - "${WORK}/history/7.2.0-ceralive2/SHA256SUMS" "${name}" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
rows = [line for line in p.read_text().splitlines() if not line.endswith('  '+sys.argv[2])]
p.write_text('\n'.join(rows) + '\n' + 'f'*64 + '  ' + sys.argv[2] + '\n')
PY
fetch_kernel "${WORK}/bad-release"
refuse 'APT digest differing from released version fails without compiling' \
  'APT kernel digest differs' stage_kernel rock-5b-plus "${WORK}/bad-release"
rm -rf "${WORK}/history/7.2.0-ceralive2"
cp -a "${WORK}/saved-release" "${WORK}/history/7.2.0-ceralive2"
fetch_kernel "${WORK}/changed-inputs"
printf '\nCONFIG_NEW_INPUT=y\n' >>"${repo}/manifests/kernel/rk3588-edge.fragment"
refuse 'released fingerprint mismatch fails without compiling' input_fingerprint \
  stage_kernel rock-5b-plus "${WORK}/changed-inputs"
cp "${ROOT}/manifests/kernel/rk3588-edge.fragment" "${repo}/manifests/kernel/rk3588-edge.fragment"
jq '.validated_boards = ["rock-5b-plus"]' "${WORK}/saved-release/kernel-artifact.json" >"${WORK}/history/7.2.0-ceralive2/kernel-artifact.json"
(cd "${WORK}/history/7.2.0-ceralive2" && sha256sum "${name}" resolved.config built-modules.txt kernel-artifact.json >SHA256SUMS)
fetch_kernel "${WORK}/unvalidated-board"
refuse 'unvalidated Orange board fails without compiling' validated_boards \
  stage_kernel orange-pi-5-plus "${WORK}/unvalidated-board"
printf 'Package: unrelated\nVersion: 1\nArchitecture: arm64\nFilename: pool/unrelated.deb\nSHA256: %064d\n\n' 0 >"${WORK}/apt/Packages"
sign_index
CERALIVE_REQUIRE_KERNEL_APT=1 refuse 'production missing version refuses with no build fallback' \
  kernel_not_on_apt fetch_kernel "${WORK}/unpublished-production"
fetch_kernel "${WORK}/unpublished-local"
[[ ! -s "${WORK}/unpublished-local/packages-lock/fetch.jsonl" ]]
ok 'unpublished local kernel has no fake APT receipt'
[[ ! -e "${WORK}/runtime.log" ]]
ok 'all released-artifact negative controls fail before any compilation'

# An unpublished higher version takes the real build entrypoint, with only the
# container/compiler boundary replaced by a deterministic offline archive.
kernel_test_version "${repo}" 7.2.0-ceralive3
kernel_test_artifact "${WORK}/source-result" 7.2.0-ceralive3 "${repo}"
export KERNEL_TEST_BUILD_INPUT="${WORK}/source-result" CERALIVE_KERNEL_SRC_MIRROR=0
kernel_test_builder_stub "${WORK}/bin"
(
  set -a
  eval "$("${repo}/lib/resolve.sh" rock-5b-plus)"
  set +a
  unset KERNEL_VARIANT
  bash "${repo}/lib/kernel/released.sh" --board rock-5b-plus --out "${WORK}/local-built"
)
test -f "${WORK}/local-built/linux-image-7.2.0-ceralive-rk3588_7.2.0-ceralive3_arm64.deb"
grep -qxF COMPILE "${WORK}/runtime.log"
ok 'unpublished higher version executes the source compile path and its real output gates'
printf 'Kernel artifact reuse contract: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" == 0 ]]
