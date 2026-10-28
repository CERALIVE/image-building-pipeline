#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${ROOT}/tests/lib/assertions.sh"
source "${ROOT}/tests/lib/kernel-release-fixtures.sh"
WORK="$(mktemp -d)"
trap 'rm -rf -- "${WORK}"' EXIT
export ROOT WORK
repo="${WORK}/repo"
history="${WORK}/history"
kernel_test_repo "${repo}"
mkdir -p "${history}" "${WORK}/os"
kernel_test_artifact "${history}/7.2.0-ceralive1" 7.2.0-ceralive1 "${repo}"
kernel_test_artifact "${history}/7.2.0-ceralive3" 7.2.0-ceralive3 "${repo}"
kernel_test_gh_stub "${WORK}/bin"
export PATH="${WORK}/bin:${PATH}" KERNEL_TEST_GH_LOG="${WORK}/gh.log"
export KERNEL_TEST_HISTORY="${history}" KERNEL_TEST_TAGS=kernel/v7.2.0-ceralive1
unset CERALIVE_KERNEL_HISTORY_DIR
GIT_MASTER=1 git -C "${repo}" tag kernel/v7.2.0-ceralive1
gate() { python3 "${ROOT}/ci/check-kernel-version-monotonic.py" --repo "${repo}" "$@"; }
refuse() {
  local label="$1" diagnostic="$2"; shift 2
  if gate "$@" >"${WORK}/refused" 2>&1; then bad "${label}: accepted"
  elif grep -Fq "${diagnostic}" "${WORK}/refused"; then ok "${label}"
  else bad "${label}: wrong guard"; cat "${WORK}/refused"; fi
}

kernel_test_version "${repo}" 7.2.0-ceralive2
gate --candidate
ok 'higher candidate passes with local full tag history and stubbed gh'
GIT_MASTER=1 git -C "${repo}" tag kernel/v7.2.0-ceralive2
gate --candidate
ok 'equal new tag with no release yet admits its first publication'
GIT_MASTER=1 git -C "${repo}" tag --delete kernel/v7.2.0-ceralive2 >/dev/null
kernel_test_version "${repo}" 7.2.0-ceralive1
gate --candidate
ok 'equal version with unchanged family fingerprint passes'
printf '\nCONFIG_NEW_FRAGMENT_INPUT=y\n' >>"${repo}/manifests/kernel/rk3588-edge.fragment"
refuse 'equal version with changed fragment fails' 'bump package_version' --candidate
cp "${ROOT}/manifests/kernel/rk3588-edge.fragment" "${repo}/manifests/kernel/rk3588-edge.fragment"
jq '.kernel_epoch += 1' "${history}/7.2.0-ceralive1/kernel-artifact.json" >"${WORK}/changed-epoch.json"
refuse 'equal version with changed epoch input fails' 'bump package_version' \
  --candidate --artifact "${WORK}/changed-epoch.json"
jq '.builder_closure.packages = ["gcc-aarch64-linux-gnu=15.1 arm64"]' \
  "${history}/7.2.0-ceralive1/kernel-artifact.json" >"${WORK}/changed-builder.json"
refuse 'equal version with changed toolchain closure fails' 'bump package_version' \
  --candidate --artifact "${WORK}/changed-builder.json"
jq '.deb_sha256 = ("f"*64)' "${history}/7.2.0-ceralive1/kernel-artifact.json" >"${WORK}/changed-bytes.json"
refuse 'equal version with changed candidate archive bytes fails' 'candidate artifact identity changed' \
  --candidate --artifact "${WORK}/changed-bytes.json"

GIT_MASTER=1 git -C "${repo}" tag kernel/v7.2.0-ceralive3
kernel_test_version "${repo}" 7.2.0-ceralive2
refuse 'candidate lower than newest tag fails' 'bump package_version' --candidate
KERNEL_TEST_TAGS=kernel/v7.2.0-ceralive3 refuse 'publishing ceralive2 after ceralive3 fails' \
  'bump package_version' --published
KERNEL_TEST_TAGS=kernel/v7.2.0-ceralive2 refuse 'republishing equal version fails' \
  'bump package_version' --published
KERNEL_TEST_TAGS=kernel/v7.2.0-ceralive9 gate --published --version 7.2.0-ceralive10
ok 'Debian ceralive10 sorts above ceralive9'
KERNEL_TEST_TAGS=kernel/v7.2.0-ceralive10 refuse 'Debian ceralive9 sorts below ceralive10' \
  'bump package_version' --published --version 7.2.0-ceralive9

printf '{"schema":1,"board":"rock-5b-plus","os_version":"2026.10.1","kernel":{"package":"linux-image-7.2.0-ceralive-rk3588","version":"7.2.0-ceralive9","deb_sha256":"%064d"}}\n' 0 >"${WORK}/os/kernel.json"
floor="$(KERNEL_TEST_TAGS=kernel/v7.2.0-ceralive3 gate --floor --os-releases "${WORK}/os")"
assert_eq 'floor includes every published OS kernel' 7.2.0-ceralive9 "${floor}"
refuse 'OS kernel below floor is refused' os_kernel_below_floor \
  --floor --os-releases "${WORK}/os" --version 7.2.0-ceralive2
printf '{"schema":1}\n' >"${WORK}/os/bad.json"
refuse 'malformed published sidecar fails closed' 'kernel release:' --floor --os-releases "${WORK}/os"
rm "${WORK}/os/bad.json"
KERNEL_TEST_TAGS=kernel/vbad refuse 'malformed published kernel tag fails closed' \
  'invalid kernel version' --floor
GIT_MASTER=1 git -C "${repo}" tag kernel/bad
refuse 'malformed local kernel tag fails closed' 'malformed kernel tag' --candidate
for invalid in 7.2.0-ceralive0 7.2.0-ceralive2+test1 7.2-ceralive2 bad; do
  refuse "malformed candidate version ${invalid}" 'invalid kernel version' --published --version "${invalid}"
done
if grep -Eq -- '--pattern [^ ]*\.deb' "${WORK}/gh.log"; then bad 'release byte download was attempted'
else ok 'gh retrieves only the four release metadata files'; fi
export CERALIVE_KERNEL_HISTORY_DIR="${history}"
assert_eq 'local published metadata is usable without gh' 7.2.0-ceralive3 "$(gate --floor)"
python3 - "${ROOT}" <<'PY'
import pathlib, sys, yaml
root = pathlib.Path(sys.argv[1])
for filename, job_name in (('v2-ci.yml', 'schema-validate'), ('release.yml', 'candidate')):
    job = yaml.load((root/'.github/workflows'/filename).read_text(), Loader=yaml.BaseLoader)['jobs'][job_name]
    steps = job['steps']
    gate = next(s for s in steps if '--candidate' in s.get('run','') and 'check-kernel-version-monotonic.py' in s['run'])
    checkout = next(s for s in steps if s.get('uses','').startswith('actions/checkout@'))
    assert checkout['with']['fetch-depth'] == '0'
    assert steps.index(checkout) < steps.index(gate)
    builds = [i for i,s in enumerate(steps) if './build ' in s.get('run','')]
    assert all(steps.index(gate) < i for i in builds)
workflow = yaml.load((root/'.github/workflows/publish-release.yml').read_text(), Loader=yaml.BaseLoader)
assert workflow['jobs']['publish']['concurrency'] == {'group':'ceralive-kernel-floor','cancel-in-progress':'false'}
assert 'concurrency' not in workflow, 'publish/promote critical section must be the shared job group'
PY
ok 'both candidate gates fetch full tags and every publish order shares the non-cancelling floor group'
printf 'Kernel monotonic contract: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" == 0 ]]
