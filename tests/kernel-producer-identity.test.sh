#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${ROOT}/tests/lib/assertions.sh"
source "${ROOT}/tests/lib/kernel-release-fixtures.sh"
WORK="$(mktemp -d)"
trap 'rm -rf -- "${WORK}"' EXIT
export ROOT WORK

# Independent stack digests bind both the producer bytes and its coverage list.
(cd "${ROOT}" && sha256sum --check tests/fixtures/kernel-producer.sha256)
ok 'production inputs match the reviewed kernel and reset-evidence producer snapshot'

kernel_test_repo "${WORK}/repo"
fixture_version=7.2.0-ceralive8
kernel_test_artifact "${WORK}/artifact" "${fixture_version}" "${WORK}/repo"
expected="$(jq -r .input_fingerprint "${WORK}/artifact/kernel-artifact.json")"
fingerprint() (
  set -a
  eval "$("${WORK}/repo/lib/resolve.sh" rock-5b-plus)"
  set +a
  unset KERNEL_VARIANT
  export KERNEL_SOURCE_PACKAGE_VERSION="${fixture_version}"
  bash "${WORK}/repo/lib/kernel/released.sh" --board rock-5b-plus \
    --fingerprint-from "${WORK}/artifact/kernel-artifact.json"
)

assert_eq "unmodified producer matches the fixture version" "${expected}" "$(fingerprint)"

# The reset-evidence producer inputs must invalidate cached kernel artifacts.
for file in lib/kernel/ramoops.sh manifests/kernel/rk3588-ramoops.dtsi; do
  cp "${WORK}/repo/${file}" "${WORK}/original"
  printf '\n' >>"${WORK}/repo/${file}"
  actual="$(fingerprint)"
  if [[ "${actual}" == "${expected}" ]]; then
    bad "${file} must change the kernel fingerprint"
  else
    ok "${file} changes the kernel fingerprint"
  fi
  cp "${WORK}/original" "${WORK}/repo/${file}"
done

# Changing release orchestration may not become a kernel input through a wrapper.
for file in lib/kernel/released.sh lib/kernel_release.py ci/check-kernel-version-monotonic.py \
  ci/kernel-floor-lib.sh lib/orchestrate.sh lib/stages/kernel-build.sh; do
  cp "${WORK}/repo/${file}" "${WORK}/original"
  printf '\n# release-only identity boundary probe\n' >>"${WORK}/repo/${file}"
  assert_eq "${file} stays outside the kernel fingerprint" "${expected}" "$(fingerprint)"
  cp "${WORK}/original" "${WORK}/repo/${file}"
done
printf 'Kernel producer identity contract: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" == 0 ]]
