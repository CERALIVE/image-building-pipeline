#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
source "${HERE}/lib/assertions.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

printf 'CONFIG_CACHE_TEST=y\n# CONFIG_CACHE_BAD is not set\n' >"${WORK}/fragment"
cp "${WORK}/fragment" "${WORK}/resolved.config"
printf 'CONFIG_CACHE_TEST=y\n' >"${WORK}/required"
printf 'CONFIG_CACHE_BAD\n' >"${WORK}/forbidden"
if bash "${ROOT}/lib/verify-kernel-config.sh" --config "${WORK}/resolved.config" \
  --declared "${WORK}/fragment" --required "${WORK}/required" \
  --forbidden "${WORK}/forbidden" >/dev/null; then
  ok 'baseline: real survival and closure verifier accepts a valid resolved config'
else
  bad 'baseline: real config verifier rejected valid fixture'
fi
printf '# CONFIG_CACHE_TEST is not set\nCONFIG_CACHE_BAD=y\n' >"${WORK}/invalid.config"
if bash "${ROOT}/lib/verify-kernel-config.sh" --config "${WORK}/invalid.config" \
  --declared "${WORK}/fragment" --required "${WORK}/required" \
  --forbidden "${WORK}/forbidden" >/dev/null 2>&1; then
  bad 'baseline: dropped/forbidden symbols were accepted'
else
  ok 'baseline: real verifier rejects dropped and forbidden symbols'
fi

if [[ -f "${ROOT}/lib/kernel/artifact-cache.sh" ]] &&
  grep -Fq 'kernel_artifact_cache_hit' "${ROOT}/lib/build-kernel.sh"; then
  ok 'cache hit is wired into the real stage'
else
  bad 'cache hit is not wired into the real stage'
fi

source "${ROOT}/lib/kernel/artifact-cache.sh"
export CERALIVE_REMOTE_CACHE=0
source "${ROOT}/lib/kernel/package.sh"
log_info() { :; }
log_warn() { printf '%s\n' "$*" >>"${WORK}/warnings"; }
log_error() { printf '%s\n' "$*" >&2; }
log_success() { :; }
die() { printf '%s\n' "$*" >&2; return 1; }
PIPELINE_DIR="${ROOT}"
HERE="${ROOT}/lib"
KERNEL_LIB_DIR="${ROOT}/lib/kernel"
KERNEL_BUILDER_DOCKERFILE="${ROOT}/ci/Dockerfile.kernel"
CERALIVE_REL_MKOSI_CACHE_ROOT="cache"
kernel_artifact_cache_root() { printf '%s/cache' "${WORK}"; }
git_url='https://example.test/kernel'
tag=v7.2
commit="$(printf 'a%.0s' {1..40})"
patches_url='https://example.test/patches'
patches_commit="$(printf 'b%.0s' {1..40})"
patches_series='series'
config_mode=defconfig
defconfig_base=defconfig
config_git_url=''
config_commit=''
config_path=''
builder_image='base@sha256:123'
builder_digest='sha256:builder'
KERNEL_VARIANT=edge
arch=arm64
kernel_pkg=linux-image-cache-test
kernel_release=7.2.0-cache
local_version=-cache
package_version=1
epoch=100
dtb_path='/usr/lib/linux-image-7.2.0-cache/rockchip/test.dtb'
absent_list=''
fragments=("${WORK}/fragment")
BASE_KEY="$(kernel_artifact_cache_key)"
[[ "${BASE_KEY}" =~ ^[0-9a-f]{64}$ ]] && ok 'key is a SHA-256 digest' || bad 'invalid key'

check_key_mutation() {
  local label="$1" name="$2" replacement="$3" old="${!2}"
  printf -v "${name}" '%s' "${replacement}"
  [[ "$(kernel_artifact_cache_key)" != "${BASE_KEY}" ]] && ok "key changes with ${label}" || bad "key ignores ${label}"
  printf -v "${name}" '%s' "${old}"
}
for name in git_url commit patches_commit patches_url patches_series config_mode \
  defconfig_base builder_image builder_digest KERNEL_VARIANT kernel_pkg \
  package_version kernel_release local_version arch epoch dtb_path \
  config_git_url config_commit config_path; do
  check_key_mutation "${name}" "${name}" "changed-${!name}"
done
printf 'CONFIG_OTHER=y\n' >>"${WORK}/fragment"
[[ "$(kernel_artifact_cache_key)" != "${BASE_KEY}" ]] && ok 'fragment byte mutation changes key' || bad 'fragment bytes ignored'
printf 'CONFIG_CACHE_TEST=y\n# CONFIG_CACHE_BAD is not set\n' >"${WORK}/fragment"
touch "${WORK}/fragment"
[[ "$(kernel_artifact_cache_key)" == "${BASE_KEY}" ]] && ok 'fragment mtime is not a key input' || bad 'mtime changed key'
cp "${WORK}/fragment" "${WORK}/fragment-2"
fragments+=("${WORK}/fragment-2")
[[ "$(kernel_artifact_cache_key)" != "${BASE_KEY}" ]] && ok 'ordered fragment list changes key' || bad 'fragment count ignored'
fragments=("${WORK}/fragment")

KEY_HERE="${WORK}/source/lib"
mkdir -p "${KEY_HERE}/kernel" "${KEY_HERE}/shared" "${WORK}/source/ci"
cp "${ROOT}/lib/build-kernel.sh" "${ROOT}/lib/verify-kernel-config.sh" "${KEY_HERE}/"
cp "${ROOT}/lib/kernel/"*.sh "${KEY_HERE}/kernel/"
cp "${ROOT}/lib/shared/remote-cache.sh" "${KEY_HERE}/shared/"
cp "${ROOT}/ci/Dockerfile.kernel" "${WORK}/source/ci/"
HERE="${KEY_HERE}"
KERNEL_LIB_DIR="${HERE}/kernel"
KERNEL_BUILDER_DOCKERFILE="${WORK}/source/ci/Dockerfile.kernel"
SOURCE_KEY="$(kernel_artifact_cache_key)"
for file in "${HERE}/build-kernel.sh" "${HERE}/verify-kernel-config.sh" \
  "${KERNEL_LIB_DIR}/config.sh" "${KERNEL_LIB_DIR}/checkout.sh" \
  "${KERNEL_LIB_DIR}/builder.sh" "${KERNEL_LIB_DIR}/package.sh" \
  "${KERNEL_LIB_DIR}/artifact-cache.sh" "${KEY_HERE}/shared/remote-cache.sh" "${KERNEL_BUILDER_DOCKERFILE}"; do
  printf '\n' >>"${file}"
  [[ "$(kernel_artifact_cache_key)" != "${SOURCE_KEY}" ]] && ok "key changes with $(basename "${file}") bytes" || bad "key ignores ${file}"
  truncate -s -1 "${file}"
done
HERE="${ROOT}/lib"
KERNEL_LIB_DIR="${ROOT}/lib/kernel"
KERNEL_BUILDER_DOCKERFILE="${ROOT}/ci/Dockerfile.kernel"

mkdir -p "${WORK}/payload/usr/lib/linux-image-7.2.0-cache/rockchip" "${WORK}/control/DEBIAN" "${WORK}/built" "${WORK}/staged"
printf 'test dtb\n' >"${WORK}/payload${dtb_path}"
printf 'Package: %s\nVersion: %s\nArchitecture: %s\nMaintainer: Test <test@example.test>\nDescription: test\n' \
  "${kernel_pkg}" "${package_version}" "${arch}" >"${WORK}/control/DEBIAN/control"
cp -a "${WORK}/payload/." "${WORK}/control/"
dpkg-deb --build --root-owner-group "${WORK}/control" "${WORK}/built/${kernel_pkg}_${package_version}_${arch}.deb" >/dev/null
cp "${WORK}/resolved.config" "${WORK}/built/resolved.config"
printf 'drivers/test.ko\n' >"${WORK}/built/built-modules.txt"
if validate_built_kernel_deb "${WORK}/built/${kernel_pkg}_${package_version}_${arch}.deb" \
  "${kernel_pkg}" "${package_version}" "${arch}" "${dtb_path}" >/dev/null; then
  ok 'baseline: real deb validator accepts synthetic Debian archive and DTB'
else
  bad 'baseline: real deb validator rejected synthetic archive'
fi

eval "$(declare -f validate_built_kernel_deb | sed '1s/validate_built_kernel_deb/real_validate_built_kernel_deb/')"
validate_built_kernel_deb() {
  printf 'deb\n' >>"${WORK}/spy"
  real_validate_built_kernel_deb "$@"
}
eval "$(declare -f kernel_artifact_verify_config | sed '1s/kernel_artifact_verify_config/real_kernel_artifact_verify_config/')"
kernel_artifact_verify_config() {
  printf 'config\n' >>"${WORK}/spy"
  bash "${ROOT}/lib/verify-kernel-config.sh" --config "$1" \
    --declared "${WORK}/fragment" --required "${WORK}/required" \
    --forbidden "${WORK}/forbidden" >/dev/null
}
MKOSI_PACKAGE_STAGING_SH="${ROOT}/lib/stage-mkosi-package.sh"
kernel_artifact_cache_store "${BASE_KEY}" "${WORK}/built/${kernel_pkg}_${package_version}_${arch}.deb" "${WORK}/built"
ENTRY="$(kernel_artifact_cache_root)/${BASE_KEY}"
[[ -f "${ENTRY}/manifest.json" ]] && ok 'store publishes SHA256 manifest' || bad 'no manifest'
if kernel_artifact_cache_hit "${BASE_KEY}" "${WORK}/staged" "${kernel_pkg}_${package_version}_${arch}.deb"; then
  ok 'hit stages verified deb/config/modules'
else
  bad 'cache hit failed'
fi
[[ "$(wc -l <"${WORK}/spy")" == 2 ]] && ok 'hit reruns deb and config validators' || bad 'validator skipped on hit'
[[ -s "${WORK}/staged/resolved.config" && -s "${WORK}/staged/built-modules.txt" ]] && ok 'hit stages both metadata files' || bad 'missing staged metadata'
printf x >>"${ENTRY}/${kernel_pkg}_${package_version}_${arch}.deb"
if kernel_artifact_cache_hit "${BASE_KEY}" "${WORK}/staged" "${kernel_pkg}_${package_version}_${arch}.deb" 2>/dev/null; then
  bad 'one-byte corrupt deb was accepted'
else
  ok 'one-byte corrupt deb forces miss'
fi
[[ ! -d "${ENTRY}" ]] && ok 'corrupt cache entry removed for rebuild' || bad 'corrupt entry retained'
[[ -s "${WORK}/warnings" ]] && ok 'corruption is logged' || bad 'corruption was silent'
kernel_artifact_cache_store "${BASE_KEY}" "${WORK}/built/${kernel_pkg}_${package_version}_${arch}.deb" "${WORK}/built"
printf '# CONFIG_CACHE_TEST is not set\nCONFIG_CACHE_BAD=y\n' >"${ENTRY}/resolved.config"
kernel_artifact_cache_manifest "${ENTRY}" "${kernel_pkg}_${package_version}_${arch}.deb"
if kernel_artifact_cache_hit "${BASE_KEY}" "${WORK}/staged" "${kernel_pkg}_${package_version}_${arch}.deb" 2>/dev/null; then
  bad 'hash-valid but invalid config was accepted'
else
  ok 'config-survival/closure failure evicts hash-valid entry'
fi
[[ ! -d "${ENTRY}" ]] && ok 'invalid config entry removed' || bad 'invalid config retained'
for mode in auto 0 invalid; do
  CERALIVE_KERNEL_ARTIFACT_CACHE="$mode"
  result="$(kernel_artifact_cache_mode 2>/dev/null)"; rc=$?
  if [[ "$mode" == invalid ]]; then
    (( rc != 0 )) && ok 'invalid mode rejected' || bad 'invalid mode accepted'
  else
    [[ "$result" == "$mode" ]] && ok "mode ${mode} accepted" || bad "mode ${mode} refused"
  fi
done
unset CERALIVE_KERNEL_ARTIFACT_CACHE
if grep -Fq 'if [[ "${cache_mode}" == '\''auto'\'' ]]' "${ROOT}/lib/build-kernel.sh"; then
  ok 'off mode bypasses cache lookup and store in the stage'
else
  bad 'off mode can still enter cache path'
fi

kernel_artifact_cache_store "${BASE_KEY}" "${WORK}/built/${kernel_pkg}_${package_version}_${arch}.deb" "${WORK}/built"
REMOTE_ENTRY="${WORK}/http-root/kernel/${BASE_KEY}"
mkdir -p "${REMOTE_ENTRY}"
cp "${ENTRY}/"* "${REMOTE_ENTRY}/"
rm -rf "${ENTRY}"
cat >"${WORK}/server.py" <<'PY'
import http.server
import pathlib
import sys

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), lambda *args, **kwargs: http.server.SimpleHTTPRequestHandler(*args, directory=sys.argv[1], **kwargs))
pathlib.Path(sys.argv[2]).write_text(str(server.server_port))
server.serve_forever()
PY
python3 "${WORK}/server.py" "${WORK}/http-root" "${WORK}/port" >"${WORK}/http.log" 2>&1 &
HTTP_PID=$!
for _ in $(seq 1 50); do [[ -s "${WORK}/port" ]] && break; sleep 0.1; done
CERALIVE_REMOTE_CACHE=auto
CERALIVE_REMOTE_CACHE_URL="http://127.0.0.1:$(<"${WORK}/port")"
export CERALIVE_REMOTE_CACHE_URL
if kernel_artifact_cache_hit "${BASE_KEY}" "${WORK}/staged" "${kernel_pkg}_${package_version}_${arch}.deb" && [[ -f "${ENTRY}/manifest.json" ]]; then
  ok 'remote kernel HTTP hit verifies manifest, deb and config before local publication'
else
  bad 'remote kernel HTTP hit failed'
fi
printf x >>"${ENTRY}/${kernel_pkg}_${package_version}_${arch}.deb"
if kernel_artifact_cache_hit "${BASE_KEY}" "${WORK}/staged" "${kernel_pkg}_${package_version}_${arch}.deb" &&
   cmp -s "${ENTRY}/${kernel_pkg}_${package_version}_${arch}.deb" "${REMOTE_ENTRY}/${kernel_pkg}_${package_version}_${arch}.deb"; then
  ok 'corrupt local kernel entry is evicted and refilled from validated remote bytes'
else
  bad 'corrupt local kernel entry skipped the remote tier'
fi
rm -rf "${ENTRY}"
printf '# CONFIG_CACHE_TEST is not set\nCONFIG_CACHE_BAD=y\n' >"${REMOTE_ENTRY}/resolved.config"
kernel_artifact_cache_manifest "${REMOTE_ENTRY}" "${kernel_pkg}_${package_version}_${arch}.deb"
if kernel_artifact_cache_hit "${BASE_KEY}" "${WORK}/staged" "${kernel_pkg}_${package_version}_${arch}.deb" 2>/dev/null; then
  bad 'hash-valid remote kernel config bypassed semantic validation'
else
  ok 'hash-valid remote kernel with invalid config falls back to source build'
fi
[[ ! -d "${ENTRY}" ]] && ok 'invalid remote kernel entry never reached local cache' || bad 'invalid remote kernel entry published locally'
CERALIVE_REMOTE_CACHE=0
requests_before="$(wc -l <"${WORK}/http.log")"
kernel_artifact_cache_hit "${BASE_KEY}" "${WORK}/staged" "${kernel_pkg}_${package_version}_${arch}.deb" 2>/dev/null
[[ "$(wc -l <"${WORK}/http.log")" == "${requests_before}" ]] && ok 'remote-disabled kernel lookup does no HTTP' || bad 'remote-disabled kernel lookup contacted HTTP'
kill "${HTTP_PID}"; wait "${HTTP_PID}" 2>/dev/null || :
printf 'Kernel artifact cache contract: %s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
