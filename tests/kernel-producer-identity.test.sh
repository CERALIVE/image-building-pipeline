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
ok 'all production fingerprint inputs and the coverage function equal stack 9b89e6f'

kernel_test_repo "${WORK}/repo"
kernel_test_artifact "${WORK}/artifact" 7.2.0-ceralive1 "${WORK}/repo"
expected="$(jq -r .input_fingerprint "${WORK}/artifact/kernel-artifact.json")"
fingerprint() (
  set -a
  eval "$("${WORK}/repo/lib/resolve.sh" rock-5b-plus)"
  set +a
  unset KERNEL_VARIANT
  bash "${WORK}/repo/lib/kernel/released.sh" --board rock-5b-plus \
    --fingerprint-from "${WORK}/artifact/kernel-artifact.json"
)

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
