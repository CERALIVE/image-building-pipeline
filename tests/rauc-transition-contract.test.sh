#!/usr/bin/env bash
#
# rauc-transition-contract.test.sh — pin the first Trixie bundle to the subset
# accepted by the deployed Bookworm RAUC 1.8 fleet.
#
# PROFILE: contract-test (docs/shell-profiles.md).
# shellcheck shell=bash
# shellcheck disable=SC2016 # needles intentionally match unexpanded source text

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"

# shellcheck source=lib/assertions.sh
source "${HERE}/lib/assertions.sh"

BUNDLE="${PIPELINE_DIR}/lib/build-bundle.sh"
INSTALL_BOOT="${PIPELINE_DIR}/mkosi/platform/boot/install-boot.sh"
SYSTEM_CONF="${PIPELINE_DIR}/mkosi/runtime/rauc/system.conf"

has() {
  local desc="$1" file="$2" needle="$3"
  if grep -qF -- "${needle}" "${file}"; then ok "${desc}"
  else bad "${desc}: '${needle}' not found in ${file#"${PIPELINE_DIR}"/}"; fi
}

lacks_active_key() {
  local desc="$1" file="$2" key="$3"
  if grep -Ev '^[[:space:]]*(#|$)' "${file}" | grep -qE "^[[:space:]]*${key}[[:space:]]*="; then
    bad "${desc}: active ${key}= found in ${file#"${PIPELINE_DIR}"/}"
  else
    ok "${desc}"
  fi
}

transition_contract_check() {
  local bundle="$1" install_boot="$2" system_conf="$3"
  local failures_before="${FAIL}"

  has "bundle manifest explicitly pins the RAUC 1.8-compatible format" \
    "${bundle}" 'format=plain'
  has "bundle manifest copies the resolved compatible byte-for-byte" \
    "${bundle}" 'compatible=${compatible}'
  has "bundle compatible comes from COMPATIBLE_STRING with no guessed value" \
    "${bundle}" 'compatible="${COMPATIBLE_STRING:-}"'
  has "on-device arm64 system.conf copies that same resolved compatible" \
    "${install_boot}" 'compatible=${COMPATIBLE}'
  has "arm64 installer reads COMPATIBLE_STRING verbatim" \
    "${install_boot}" 'COMPATIBLE="${COMPATIBLE_STRING:-}"'
  has "fallback system.conf retains the compatible substitution token" \
    "${system_conf}" 'compatible=@COMPATIBLE_STRING@'
  lacks_active_key "fleet system.conf does not exclude plain bundles" \
    "${system_conf}" 'bundle-formats'
  lacks_active_key "verification purpose stays unchanged across the transition" \
    "${system_conf}" 'check-purpose'
  has "bundle signer remains the leaf key" "${bundle}" '"--key=${RAUC_LEAF_KEY}"'
  has "bundle embeds the existing intermediate chain" "${bundle}" '"--intermediate=${RAUC_CHAIN}"'
  has "bundle verifies to the existing baked root" "${bundle}" 'RAUC_ROOT_CA="${RAUC_PKI_DIR}/root-ca.pem"'

  (( FAIL == failures_before ))
}

echo "== first-Trixie bundle contract =="
transition_contract_check "${BUNDLE}" "${INSTALL_BOOT}" "${SYSTEM_CONF}"

echo
echo "== mutation controls =="
scratch="$(mktemp -d)"
trap 'rm -rf "${scratch}"' EXIT
cp "${BUNDLE}" "${scratch}/build-bundle.sh"
cp "${INSTALL_BOOT}" "${scratch}/install-boot.sh"
cp "${SYSTEM_CONF}" "${scratch}/system.conf"

sed -i 's/format=plain/format=verity/' "${scratch}/build-bundle.sh"
saved_fail="${FAIL}"
transition_contract_check "${scratch}/build-bundle.sh" "${scratch}/install-boot.sh" "${scratch}/system.conf" >/dev/null 2>&1
if (( FAIL > saved_fail )); then
  ok "mutation: a verity-format transition bundle is rejected"
  FAIL="${saved_fail}"
else
  bad "mutation: format=verity escaped the RAUC 1.8 transition gate"
fi

cp "${BUNDLE}" "${scratch}/build-bundle.sh"
sed -i 's/compatible=${compatible}/compatible=ceralive-wrong-board/' "${scratch}/build-bundle.sh"
saved_fail="${FAIL}"
transition_contract_check "${scratch}/build-bundle.sh" "${scratch}/install-boot.sh" "${scratch}/system.conf" >/dev/null 2>&1
if (( FAIL > saved_fail )); then
  ok "mutation: a hardcoded incompatible board identity is rejected"
  FAIL="${saved_fail}"
else
  bad "mutation: a hardcoded compatible escaped the transition gate"
fi

echo
if (( FAIL == 0 )); then
  echo "rauc transition contract: PASS (${PASS} assertions)"
  exit 0
fi
echo "rauc transition contract: FAIL (${FAIL} failure(s), ${PASS} pass(es))" >&2
exit 1
