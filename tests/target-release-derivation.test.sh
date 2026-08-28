#!/usr/bin/env bash
#
# target-release-derivation.test.sh — the contract for the ONE target-release
# mapping, manifests/target-release.env.
#
# WHAT IT PINS, and why each part is here rather than left to review:
#
#   A. THE MAPPING ITSELF — it exists, it declares every key, and the derived
#      apt suites re-expand from RELEASE rather than being frozen strings.
#
#   B. THE GATE — ci/check-suite-literals.sh passes on the shipped tree AND its
#      own --self-test passes. Running the audit's self-test from here is what
#      stops the gate going vacuous: an audit that silently read nothing would
#      report a clean sweep forever.
#
#   C. EVERY CONSUMER DERIVES — a static contract per consumer named in the
#      mapping's own header. These are text checks on purpose: the failure they
#      guard against is a re-introduced literal, which is a property of the
#      source, not of a run.
#
#   D. THE PARAMETERISATION ACTUALLY WORKS — a scratch copy of the tree with a
#      DIFFERENT mapping is resolved for real, and every derived value must move
#      with it. Without this leg, C could pass on a tree where the derivation is
#      wired up but produces a constant.
#
#   E. ARMBIAN_SUITE STAYS SEPARATE — a named regression pin. Merging the BSP-deb
#      suite into RELEASE would repoint the kernel/DTB/U-Boot/firmware fetch at a
#      suite that may not carry the RK35xx vendor BSP at all, and the symptom
#      would be a fetch failure far from the edit that caused it.
#
#   F. THE ADD-ON FIXTURES AGREE with the mapping. They are static JSON that the
#      literal sweep deliberately does not read (tests/ is excluded), so a
#      release bump would otherwise leave them failing for a confusing reason.
#
# PROFILE: contract-test (docs/shell-profiles.md) — `set -uo pipefail` with no
# `-e`, tests/lib/assertions.sh for bookkeeping, and the harness owns its exit
# code so one failure never hides the rest.
#
# shellcheck shell=bash

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"

# shellcheck source=lib/assertions.sh
source "${HERE}/lib/assertions.sh"
# shellcheck source=../lib/shared/target-release-lib.sh
source "${PIPELINE_DIR}/lib/shared/target-release-lib.sh"

ENV_FILE="${PIPELINE_DIR}/manifests/target-release.env"
AUDIT="${PIPELINE_DIR}/ci/check-suite-literals.sh"

# has <file> <fixed-string> — a fixed-string presence check reported as one
# assertion. Fixed-string because most needles are shell fragments full of `$`
# and `{`, which a regex search would silently mis-match.
has() {
  local desc="$1" file="$2" needle="$3"
  if grep -qF -- "${needle}" "${file}" 2>/dev/null; then ok "${desc}"
  else bad "${desc}: '${needle}' not in ${file#"${PIPELINE_DIR}"/}"; fi
}

lacks() {
  local desc="$1" file="$2" needle="$3"
  if grep -qF -- "${needle}" "${file}" 2>/dev/null; then
    bad "${desc}: '${needle}' still present in ${file#"${PIPELINE_DIR}"/}"
  else ok "${desc}"; fi
}

echo "== A. the mapping =="
if [[ -r "${ENV_FILE}" ]]; then ok "manifests/target-release.env exists"
else bad "manifests/target-release.env is missing — there is no source of truth"; fi

target_release_load
for key in RELEASE OS_VERSION_ID APT_SUITE APT_SUITE_UPDATES APT_SUITE_SECURITY; do
  if [[ -n "${!key-}" ]]; then ok "mapping declares ${key} (${!key})"
  else bad "mapping declares no ${key}"; fi
done
assert_eq "APT_SUITE is the plain suite" "${RELEASE}" "${APT_SUITE}"
assert_eq "APT_SUITE_UPDATES derives from RELEASE" "${RELEASE}-updates" "${APT_SUITE_UPDATES}"
assert_eq "APT_SUITE_SECURITY derives from RELEASE" "${RELEASE}-security" "${APT_SUITE_SECURITY}"

echo
echo "== B. the audit gate =="
if bash "${AUDIT}" >/dev/null 2>&1; then ok "ci/check-suite-literals.sh passes on the shipped tree"
else
  bad "ci/check-suite-literals.sh FAILS — an unannotated suite literal or a drifted mirror"
  bash "${AUDIT}" 2>&1 | sed 's/^/      /'
fi
if bash "${AUDIT}" --self-test >/dev/null 2>&1; then ok "the audit's own --self-test passes (the gate has teeth)"
else
  bad "ci/check-suite-literals.sh --self-test FAILS — the gate cannot be trusted to reject anything"
  bash "${AUDIT}" --self-test 2>&1 | sed 's/^/      /'
fi

echo
echo "== C. every consumer derives =="
ORCH="${PIPELINE_DIR}/lib/orchestrate.sh"
has   "orchestrate.sh sources the ONE reader" "${ORCH}" 'shared/target-release-lib.sh'
has   "orchestrate.sh calls target_release_load" "${ORCH}" 'target_release_load'
lacks "orchestrate.sh no longer defaults RELEASE to a literal" "${ORCH}" 'RELEASE="${RELEASE:-bookworm}"'
has   "orchestrate.sh plumbs --release to mkosi" "${ORCH}" '--release="${RELEASE}"'
has   "orchestrate.sh forwards the mapping keys in env_names" "${ORCH}" \
      'OS_VERSION_ID APT_SUITE APT_SUITE_UPDATES APT_SUITE_SECURITY'

MKOSI_CONF="${PIPELINE_DIR}/mkosi/mkosi.conf"
has   "mkosi.conf propagates the mapping keys into every subimage" "${MKOSI_CONF}" \
      'PassEnvironment=OS_VERSION_ID APT_SUITE APT_SUITE_UPDATES APT_SUITE_SECURITY'
assert_eq "mkosi.conf Release= mirrors the mapping" \
  "$(target_release_declared RELEASE)" \
  "$(sed -n 's/^Release=//p' "${MKOSI_CONF}" | head -n1)"

CONTAINER_STAGE="${PIPELINE_DIR}/lib/stages/mkosi.sh"
has   "the containerized invocation passes --release too" "${CONTAINER_STAGE}" '--release='
has   "the DRY_RUN plan names the resolved release" "${CONTAINER_STAGE}" '--release=${RELEASE}'

POSTINST="${PIPELINE_DIR}/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"
lacks "the runtime chroot has no literal suite default" "${POSTINST}" 'RELEASE="${RELEASE:-bookworm}"'
has   "the runtime chroot fails closed on an unset RELEASE" "${POSTINST}" ': "${RELEASE:?'
has   "the runtime chroot writes the DERIVED security suite" "${POSTINST}" 'Suites: ${APT_SUITE_SECURITY}'
has   "the runtime chroot writes the DERIVED updates suite" "${POSTINST}" 'Suites: ${APT_SUITE_UPDATES}'

APT_MODULE="${PIPELINE_DIR}/mkosi/customize/apt-ceralive-repo.sh"
lacks "the customize twin has no literal suite default" "${APT_MODULE}" '${RELEASE:-bookworm}'
has   "the customize twin resolves the suite set" "${APT_MODULE}" 'resolve_target_suites'
has   "the customize twin writes the DERIVED security suite" "${APT_MODULE}" 'Suites: ${APT_SUITE_SEC}'

SYSEXT="${PIPELINE_DIR}/lib/app-layer/sysext.sh"
has   "the sysext backend loads the mapping" "${SYSEXT}" 'target_release_load'
has   "the sysext backend derives the merge-key VERSION_ID" "${SYSEXT}" \
      'SYSEXT_OS_VERSION_ID="${SYSEXT_OS_VERSION_ID:-${OS_VERSION_ID}}"'
has   "the app sysext-build lib loads the mapping BEFORE sourcing a descriptor" \
      "${PIPELINE_DIR}/mkosi/app/sysext-build.lib.sh" 'target_release_load'
for descriptor in "${PIPELINE_DIR}"/mkosi/app/*.sysext.conf; do
  has "$(basename "${descriptor}") derives its VERSION_ID stamp" "${descriptor}" \
      'SYSEXT_OS_VERSION_ID="${OS_VERSION_ID'
done

has "build-feature-sysext.sh defaults --os-version from the mapping" \
    "${PIPELINE_DIR}/lib/build-feature-sysext.sh" 'os_version="${OS_VERSION_ID}"'
# The publisher addresses the artifact by the stem the builder stamped, so both
# must default from the SAME mapping or a release bump publishes to a key nothing
# resolves. The delivery path's {os_version} axis is that same value.
has "upload-addons.sh loads the mapping" \
    "${PIPELINE_DIR}/lib/upload-addons.sh" 'target_release_load'
has "upload-addons.sh defaults --os-version from the mapping" \
    "${PIPELINE_DIR}/lib/upload-addons.sh" 'os_version="${OS_VERSION_ID}"'
has "the addon-publish CI job derives its os_version axis" \
    "${PIPELINE_DIR}/.github/workflows/v2-ci.yml" 'addons/${OS_VERSION_ID}/'
has "validate-manifests.py reads the mapping" \
    "${PIPELINE_DIR}/ci/validate-manifests.py" 'TARGET_RELEASE["OS_VERSION_ID"]'
has "the board-preflight self-test fixture derives its os-release" \
    "${PIPELINE_DIR}/ci/capture-board-preflight.sh" 'VERSION_ID="${OS_VERSION_ID}"'

echo
echo "== D. the parameterisation actually moves =="
# Resolve every derived value against a DIFFERENT mapping. A wiring that reads
# the file but returns a constant passes every check in C and fails here.
SCRATCH="$(mktemp -d)"
trap 'rm -rf "${SCRATCH}"' EXIT
printf ': "${RELEASE:=scratchsuite}"\n: "${OS_VERSION_ID:=99}"\n: "${APT_SUITE:=${RELEASE}}"\n: "${APT_SUITE_UPDATES:=${RELEASE}-updates}"\n: "${APT_SUITE_SECURITY:=${RELEASE}-security}"\n' \
  >"${SCRATCH}/target-release.env"

flip() { # <KEY>
  env -u RELEASE -u OS_VERSION_ID -u APT_SUITE -u APT_SUITE_UPDATES -u APT_SUITE_SECURITY \
    CERALIVE_TARGET_RELEASE_ENV="${SCRATCH}/target-release.env" \
    bash -c "source '${PIPELINE_DIR}/lib/shared/target-release-lib.sh'; target_release_load; printf '%s' \"\${$1}\""
}
assert_eq "a flipped mapping moves RELEASE"            "scratchsuite"          "$(flip RELEASE)"
assert_eq "a flipped mapping moves OS_VERSION_ID"      "99"                    "$(flip OS_VERSION_ID)"
assert_eq "a flipped mapping moves APT_SUITE_UPDATES"  "scratchsuite-updates"  "$(flip APT_SUITE_UPDATES)"
assert_eq "a flipped mapping moves APT_SUITE_SECURITY" "scratchsuite-security" "$(flip APT_SUITE_SECURITY)"

# The sysext merge key is the one derived value whose drift is silent on-device,
# so it is resolved through the SHIPPED backend rather than the reader alone.
scratch_sysext="$(env -u OS_VERSION_ID -u SYSEXT_OS_VERSION_ID \
  CERALIVE_TARGET_RELEASE_ENV="${SCRATCH}/target-release.env" \
  bash -c "source '${PIPELINE_DIR}/lib/app-layer/sysext.sh' 2>/dev/null; printf '%s' \"\${SYSEXT_OS_VERSION_ID}\"")"
assert_eq "a flipped mapping moves the sysext merge VERSION_ID" "99" "${scratch_sysext}"

# PYTHONDONTWRITEBYTECODE: importing the validator by path would otherwise leave
# an untracked ci/__pycache__ behind after every test run.
scratch_validator="$(env PYTHONDONTWRITEBYTECODE=1 CERALIVE_TARGET_RELEASE_ENV="${SCRATCH}/target-release.env" \
  python3 -c "
import importlib.util, sys
spec = importlib.util.spec_from_file_location('vm', '${PIPELINE_DIR}/ci/validate-manifests.py')
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
sys.stdout.write(mod.SYSEXT_VERSION_ID)" 2>/dev/null)"
assert_eq "a flipped mapping moves the validator's G1 VERSION_ID" "99" "${scratch_validator}"

echo
echo "== E. ARMBIAN_SUITE stays a separate knob =="
has   "orchestrate.sh still declares ARMBIAN_SUITE independently" "${ORCH}" \
      'ARMBIAN_SUITE="${ARMBIAN_SUITE:-bookworm}"'
lacks "ARMBIAN_SUITE is never derived from RELEASE in the orchestrator" "${ORCH}" \
      'ARMBIAN_SUITE="${RELEASE'
lacks "ARMBIAN_SUITE is never derived from RELEASE in the fetcher" \
      "${PIPELINE_DIR}/lib/fetch-debs.sh" 'ARMBIAN_SUITE="${RELEASE'
lacks "ARMBIAN_SUITE is never derived from APT_SUITE in the fetcher" \
      "${PIPELINE_DIR}/lib/fetch-debs.sh" 'ARMBIAN_SUITE="${APT_SUITE'

echo
echo "== F. static add-on fixtures agree with the mapping =="
declared_version="$(target_release_declared OS_VERSION_ID)"
for fixture in "${PIPELINE_DIR}"/tests/manifests/fixtures/*.json \
               "${PIPELINE_DIR}"/manifests/addons/*.json; do
  [[ -r "${fixture}" ]] || continue
  got="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("versionId",""))' "${fixture}" 2>/dev/null)"
  [[ -n "${got}" ]] || continue
  assert_eq "$(basename "${fixture}") versionId tracks the mapping" "${declared_version}" "${got}"
done

echo
printf 'target-release-derivation: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
