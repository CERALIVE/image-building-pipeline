#!/usr/bin/env bash
set -euo pipefail

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log_info() { printf 'build cache: %s\n' "$*"; }
log_warn() { printf 'build cache WARN: %s\n' "$*" >&2; }
log_error() { printf 'build cache ERROR: %s\n' "$*" >&2; }

[[ "${GITHUB_ACTIONS:-}" == true ]] || die 'upload is CI-only'
case "${GITHUB_WORKFLOW:-}" in
  'Release candidate build'|'Scheduled real image build audit') ;;
  *) die 'only release.yml and real-build-audit.yml may upload the build cache' ;;
esac
[[ -n "${R2_BUILD_CACHE_ACCOUNT_ID:-}" && -n "${R2_BUILD_CACHE_BUCKET:-}" &&
   -n "${R2_BUILD_CACHE_ACCESS_KEY_ID:-}" && -n "${R2_BUILD_CACHE_SECRET_ACCESS_KEY:-}" ]] \
  || die 'all R2_BUILD_CACHE_* secrets are required for CI upload'
[[ "${R2_BUILD_CACHE_ACCOUNT_ID}" =~ ^[a-f0-9]{32}$ && "${R2_BUILD_CACHE_BUCKET}" =~ ^[a-z0-9-]+$ ]] \
  || die 'invalid R2 build-cache account or bucket identifier'
[[ $# == 1 && "$1" =~ ^[a-z0-9-]+$ ]] || die 'usage: upload-build-cache.sh <board>'
board="$1"
root="$(cd "$(dirname "$0")/.." && pwd)"
staging="${root}/mkosi/.staging/${board}"
debs="${staging}/debs"
[[ -d "${debs}" ]] || die 'verified build staging is absent'
for tool in aws gpgv python3 sha256sum dpkg-deb; do command -v "${tool}" >/dev/null || die "missing ${tool}"; done

export AWS_ACCESS_KEY_ID="${R2_BUILD_CACHE_ACCESS_KEY_ID}"
export AWS_SECRET_ACCESS_KEY="${R2_BUILD_CACHE_SECRET_ACCESS_KEY}"
export AWS_DEFAULT_REGION=auto
endpoint="https://${R2_BUILD_CACHE_ACCOUNT_ID}.r2.cloudflarestorage.com"
bucket="${R2_BUILD_CACHE_BUCKET}"
umask 077
work="$(mktemp -d "${RUNNER_TEMP:-/tmp}/build-cache-upload.XXXXXXXX")"
trap 'rm -rf -- "${work}"' EXIT

# The same signed metadata/pin origins the fetch families used supply the
# expected hashes. Never derive an upload key solely from the staged bytes.
# shellcheck source=../lib/fetch-debs-auth.sh
source "${root}/lib/fetch-debs-auth.sh"
# shellcheck source=../lib/fetch/index.sh
source "${root}/lib/fetch/index.sh"
# shellcheck source=../lib/shared/deb-lib.sh
source "${root}/lib/shared/deb-lib.sh"

printf '%s' "${APT_GPG_PUBLIC_B64:?signed first-party key required}" | base64 -d >"${work}/apt-key.raw"
if ! gpg --dearmor <"${work}/apt-key.raw" >"${work}/apt-key.gpg" 2>/dev/null; then
  cp "${work}/apt-key.raw" "${work}/apt-key.gpg"
fi
[[ -s "${ARMBIAN_APT_KEYRING:?signed BSP keyring required}" ]] || die 'BSP keyring missing'

verify_native_index() {
  local state="$1" keyring="$2" index="$3" release="$4"
  local -a inreleases=()
  shopt -s nullglob
  inreleases=("${state}/lists/"*_InRelease)
  shopt -u nullglob
  (( ${#inreleases[@]} == 1 )) || die "expected one signed InRelease in ${state}"
  auth_verify_release_to_file "${keyring}" "${inreleases[0]}" "${release}" \
    || die "signed InRelease verification failed: ${state}"
  [[ -s "${index}" ]] || die "apt-verified Packages list missing: ${index}"
}

bsp_index=''; first_index=''
if [[ -d "${debs}/.apt-state/lists" ]]; then
  bsp_index="$(printf '%s\n' "${debs}/.apt-state/lists/"*_Packages)"
  [[ -f "${bsp_index}" ]] || die 'ambiguous or missing BSP apt index'
  verify_native_index "${debs}/.apt-state" "${ARMBIAN_APT_KEYRING}" "${bsp_index}" "${work}/bsp-release"
elif [[ -f "${debs}/.apt-state/Packages" ]]; then
  bsp_index="${debs}/.apt-state/Packages"
  auth_verify_release_to_file "${ARMBIAN_APT_KEYRING}" "${debs}/.apt-state/InRelease" "${work}/bsp-release" \
    || die 'BSP curl release signature invalid'
else
  die 'BSP signed index not staged'
fi
if [[ -d "${debs}/.apt-state-firstparty/lists" ]]; then
  first_index="$(printf '%s\n' "${debs}/.apt-state-firstparty/lists/"*_Packages)"
  [[ -f "${first_index}" ]] || die 'ambiguous or missing first-party apt index'
  verify_native_index "${debs}/.apt-state-firstparty" "${work}/apt-key.gpg" "${first_index}" "${work}/first-release"
elif [[ -f "${debs}/.apt-state-firstparty/Packages" ]]; then
  first_index="${debs}/.apt-state-firstparty/Packages"
  auth_verify_release_to_file "${work}/apt-key.gpg" "${debs}/.apt-state-firstparty/InRelease" "${work}/first-release" \
    || die 'first-party curl release signature invalid'
  expected_index="$(index_release_digest "${work}/first-release" Packages.gz)"
  index_verify_digest "${debs}/.apt-state-firstparty/Packages.gz" "${expected_index}" 'first-party Packages.gz' \
    || die 'first-party Packages.gz differs from signed release'
  gzip -dc "${debs}/.apt-state-firstparty/Packages.gz" | cmp - "${first_index}" \
    || die 'first-party Packages differs from signed compressed index'
else
  die 'first-party signed index not staged'
fi

put_verified() {
  local file="$1" key="$2" md5 existing="${work}/existing" err="${work}/put.err"
  md5="$(openssl dgst -md5 -binary "${file}" | base64 -w0)"
  if aws s3api put-object --endpoint-url "${endpoint}" --bucket "${bucket}" \
      --key "${key}" --body "${file}" --if-none-match '*' --content-md5 "${md5}" \
      >/dev/null 2>"${err}"; then
    log_info "created ${key}"
    return 0
  fi
  if ! grep -Eq '(412|PreconditionFailed|Precondition Failed)' "${err}"; then
    die "conditional upload failed for ${key}"
  fi
  rm -f -- "${existing}"
  aws s3api get-object --endpoint-url "${endpoint}" --bucket "${bucket}" \
    --key "${key}" "${existing}" >/dev/null || die "cannot inspect existing immutable key ${key}"
  cmp -s "${file}" "${existing}" || die "immutable key collision with different bytes: ${key}"
  log_info "already matches ${key}"
}

while IFS= read -r -d '' file; do
  name="$(basename "${file}")"
  pkg="$(deb_pkg_name "${file}")"
  version="$(deb_pkg_version "${file}")"
  arch="$(deb_pkg_arch "${file}")"
  [[ -n "${pkg}" && -n "${version}" && -n "${arch}" ]] || die "bad staged Debian identity: ${name}"
  expected=''
  while read -r pin_pkg pin_name pin_sha _; do
    [[ "${pin_pkg}" == "${pkg}" && "${pin_name}" == "${name}" ]] || continue
    [[ -z "${expected}" ]] || die "duplicate userspace pin for ${name}"
    expected="${pin_sha}"
  done <"${root}/manifests/rk3588-userspace-deb-versions.txt"
  if [[ -z "${expected}" ]]; then
    found=0
    for index in "${bsp_index}" "${first_index}"; do
      resolved="$(auth_lookup_package "${index}" "${pkg}" "${version}" "${arch}")" || continue
      IFS=$'\t' read -r filename digest _ <<<"${resolved}"
      [[ "$(basename "${filename}")" == "${name}" ]] || continue
      (( found += 1 ))
      expected="${digest}"
    done
    if (( found == 0 )) && [[ "${pkg}" == libv4l-0 ]]; then continue; fi
    (( found == 1 )) || die "no unique authenticated index record for ${name}"
  fi
  [[ "${expected}" =~ ^[a-f0-9]{64}$ ]] || die "malformed signed/pinned digest for ${name}"
  [[ "$(sha256sum "${file}" | cut -d' ' -f1)" == "${expected}" ]] || die "staged ${name} differs from signed/pinned digest"
  [[ -f "${root}/mkosi/.staging/.debcache/${name}" ]] || continue
  snapshot="${work}/${name}"
  cp -- "${file}" "${snapshot}"
  [[ "$(sha256sum "${snapshot}" | cut -d' ' -f1)" == "${expected}" ]] || die "snapshot changed: ${name}"
  put_verified "${snapshot}" "debs/${expected}/${name}"
done < <(find "${debs}" -maxdepth 1 -type f -name '*.deb' -print0)

# Reuse the local kernel verifier (manifest digests, four-axis deb identity/DTB,
# declared Kconfig survival, and required/forbidden closure) before each upload.
# shellcheck source=../lib/build-kernel.sh
source "${root}/lib/build-kernel.sh"
eval "$("${root}/lib/resolve.sh" "${board}")"
arch="${ARCH}"
kernel_pkg="${KERNEL_PACKAGES%% *}"
package_version="${KERNEL_SOURCE_PACKAGE_VERSION}"
dtb_path="${KERNEL_SOURCE_DTB_DEB_DIR%/}/${DTB_NAME}"
config_mode=defconfig
fragments=()
for fragment in ${KERNEL_SOURCE_DEFCONFIG_FRAGMENT:-${KERNEL_SOURCE_DEFCONFIG_FRAGMENTS:-}}; do
  fragments+=("${root}/${fragment}")
done
(( ${#fragments[@]} > 0 )) || die 'kernel config declaration missing'
for entry in "${root}/mkosi/cache/kernel-artifacts/"[0-9a-f]*; do
  [[ -d "${entry}" ]] || continue
  key="$(basename "${entry}")"
  [[ "${key}" =~ ^[0-9a-f]{64}$ ]] || continue
  deb_name="${kernel_pkg}_${package_version}_${arch}.deb"
  [[ -f "${entry}/${deb_name}" ]] || continue
  staged="${staging}/kernel-build/${deb_name}"
  [[ -f "${staged}" ]] || die 'built kernel not staged'
  cmp -s "${entry}/${deb_name}" "${staged}" || die 'kernel cache differs from verified staged build'
  kernel_artifact_cache_intact "${entry}" "${deb_name}" || die 'kernel cache manifest invalid'
  validate_built_kernel_deb "${entry}/${deb_name}" "${kernel_pkg}" "${package_version}" "${arch}" "${dtb_path}" \
    || die 'kernel deb failed four-axis validation'
  kernel_artifact_verify_config "${entry}/resolved.config" || die 'kernel config closure failed'
  for part in manifest.json "${deb_name}" resolved.config built-modules.txt; do
    snapshot="${work}/kernel-${part}"
    cp -- "${entry}/${part}" "${snapshot}"
    cmp -s "${entry}/${part}" "${snapshot}" || die 'kernel cache changed during snapshot'
    put_verified "${snapshot}" "kernel/${key}/${part}"
  done
done
