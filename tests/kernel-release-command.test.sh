#!/usr/bin/env bash
# Offline local-command integration; real metadata, fingerprints and version gates.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${ROOT}/tests/lib/assertions.sh"
source "${ROOT}/tests/lib/kernel-release-fixtures.sh"
WORK="$(mktemp -d)"
trap 'chmod -R u+rwX "${WORK}"; rm -rf -- "${WORK}"' EXIT
export WORK ROOT GIT_MASTER=1
repo="${WORK}/repo"
kernel_test_repo "${repo}"
# Keep the revision-1 candidate and revision-2 successor scenarios independent of the live pin.
kernel_test_version "${repo}" 7.2.0-ceralive1
cp "${ROOT}/.gitignore" "${repo}/"
cp "${ROOT}/mkosi/.gitignore" "${repo}/mkosi/"
mkdir -p "${WORK}/history" "${WORK}/os" "${WORK}/bin"
kernel_test_artifact "${WORK}/input" 7.2.0-ceralive1 "${repo}"
export CERALIVE_KERNEL_HISTORY_DIR="${WORK}/history"
export KERNEL_CLI_INPUT="${WORK}/input" KERNEL_CLI_OS="${WORK}/os"
export KERNEL_CLI_LOG="${WORK}/calls" KERNEL_CLI_NETWORK="${WORK}/network"
for name in gh curl wget aws docker podman; do
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$KERNEL_CLI_NETWORK"\nexit 99\n' >"${WORK}/bin/${name}"
  chmod 755 "${WORK}/bin/${name}"
done
export PATH="${WORK}/bin:${PATH}"
mv "${repo}/ci/check-kernel-version-monotonic.py" "${repo}/ci/kernel-version-real.py"
cat >"${repo}/ci/check-kernel-version-monotonic.py" <<'PY'
import os, pathlib, subprocess, sys
mode = next(a for a in sys.argv[1:] if a in ('--metadata', '--candidate', '--published', '--floor'))
label = mode + ('-artifact' if '--artifact' in sys.argv else '')
with open(os.environ['KERNEL_CLI_LOG'], 'a') as log:
    log.write(label + '\n')
if os.environ.get('KERNEL_CLI_FAIL_GATE') == label:
    sys.exit('injected gate refusal: ' + label)
sys.exit(subprocess.call([sys.executable, str(pathlib.Path(__file__).with_name('kernel-version-real.py')), *sys.argv[1:]]))
PY
cat >"${repo}/build" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == "rk3588 --kernel-only" ]]
printf 'build\n' >>"${KERNEL_CLI_LOG}"
[[ "${KERNEL_CLI_CASE:-}" != build-failure ]] || exit 7
out="mkosi/build/kernel-only/rk3588"
mkdir -p "${out}"
cp "${KERNEL_CLI_INPUT}/"* "${out}/"
case "${KERNEL_CLI_CASE:-}" in
  missing) rm "${out}/resolved.config" ;;
  bytes) printf 'altered' >>"${out}/"*.deb ;;
  config-checksum) printf '# altered\n' >>"${out}/resolved.config" ;;
  checksum-path) printf '%064d  ../../outside\n' 0 >"${out}/SHA256SUMS" ;;
  duplicate-checksum) cat "${KERNEL_CLI_INPUT}/SHA256SUMS" >>"${out}/SHA256SUMS" ;;
  fingerprint)
    jq '.input_fingerprint = ("f"*64)' "${out}/kernel-artifact.json" >"${out}/changed"
    mv "${out}/changed" "${out}/kernel-artifact.json"
    (cd "${out}"; sha256sum ./*.deb resolved.config built-modules.txt kernel-artifact.json >SHA256SUMS) ;;
  board)
    jq '.validated_boards = ["rock-5b-plus"]' "${out}/kernel-artifact.json" >"${out}/changed"
    mv "${out}/changed" "${out}/kernel-artifact.json"
    (cd "${out}"; sha256sum ./*.deb resolved.config built-modules.txt kernel-artifact.json >SHA256SUMS) ;;
  raise-floor)
    printf '{"schema":1,"board":"rock-5b-plus","os_version":"2026.10.1","kernel":{"package":"linux-image-7.2.0-ceralive-rk3588","version":"7.2.0-ceralive2","deb_sha256":"%064d"}}\n' 0 >"${KERNEL_CLI_OS}/kernel.json" ;;
  collision) mkdir -p "${KERNEL_CLI_DEST}"; printf 'preserved\n' >"${KERNEL_CLI_DEST}/sentinel" ;;
esac
SH
chmod 755 "${repo}/build"
# Fixture sources are committed before invocation, just as the real command requires.
git -C "${repo}" add -- lib manifests ci versions.yaml mkosi build .gitignore
git -C "${repo}" -c user.name=Fixture -c user.email=fixture@example.invalid \
  -c commit.gpgsign=false commit -qm 'offline local command fixture'
commit="$(git -C "${repo}" rev-parse HEAD)"
selected=7.2.0-ceralive1
store=""
invoke() {
  python3 "${repo}/ci/kernel-release.py" rk3588 --candidate-run-id 12345 \
    --os-releases "${WORK}/os" --output-dir "${store}" "$@"
}
choose() {
  store="${repo}/mkosi/build/candidates-$1"
  export KERNEL_CLI_CASE="" KERNEL_CLI_FAIL_GATE=""
  rm -f "${KERNEL_CLI_LOG}"
  rm -rf "${repo}/mkosi/build/kernel-only"
}
refuse() {
  local label="$1" diagnostic="$2"; shift 2
  if invoke "$@" >"${WORK}/refused" 2>&1; then bad "${label}: accepted"
  elif grep -Fq -- "${diagnostic}" "${WORK}/refused"; then ok "${label}"
  else bad "${label}: wrong guard"; cat "${WORK}/refused"; fi
}
choose happy
invoke
bundle="${store}/${selected}"
(cd "${bundle}"; sha256sum -c SHA256SUMS; sha256sum -c BUNDLE.SHA256SUMS)
for name in "${WORK}/input/"*; do cmp "${name}" "${bundle}/${name##*/}"; done
ok 'candidate retains all five builder outputs byte-identically'
python3 - "${bundle}" "${commit}" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
record = json.loads((root/'kernel-artifact.json').read_text())
assert json.loads((root/'publish-authorization.inputs.json').read_text()) == {
    'mode':'apt-publish', 'publish_run_id':None, 'run_attempt':None,
    'candidate_run_id':'12345', 'tag':'kernel/v7.2.0-ceralive1', 'commit':sys.argv[2],
    'package':'linux-image-7.2.0-ceralive-rk3588', 'version':'7.2.0-ceralive1',
    'deb_sha256':record['deb_sha256'], 'channel':'beta', 'bench_report_sha256':None}
assert json.loads((root/'candidate.json').read_text()) == {
    'schema':1, 'family':'rk3588', 'commit':sys.argv[2], 'candidate_run_id':'12345',
    'kernel_floor':'none', 'publication':'blocked-pending-owner'}
assert root.stat().st_mode & 0o222 == 0
assert all(p.stat().st_mode & 0o222 == 0 for p in root.iterdir())
PY
ok 'exact publisher input fields distinguish unavailable approvals from local identity'
before="$(sha256sum "${bundle}/BUNDLE.SHA256SUMS")"
rm -f "${KERNEL_CLI_LOG}"
refuse 'same version cannot be rebuilt or overwritten' 'immutable candidate already exists'
assert_eq 'existing bundle manifest unchanged' "${before}" "$(sha256sum "${bundle}/BUNDLE.SHA256SUMS")"
[[ ! -e "${KERNEL_CLI_LOG}" ]] && ok 'collision refused before build or version gates' || bad 'collision called dependencies'
for gate in --candidate --published --floor --candidate-artifact --metadata; do
  choose "gate-${gate#--}"
  export KERNEL_CLI_FAIL_GATE="${gate}"
  refuse "${gate} refuses without a bundle" "injected gate refusal: ${gate}"
  [[ ! -e "${store}" ]] && ok "${gate} left no output store" || bad "${gate} left output state"
done
for pair in 'build-failure:returned non-zero' 'missing:No such file' \
  'bytes:SHA256SUMS' 'config-checksum:metadata checksum mismatch' 'checksum-path:malformed/duplicate' 'duplicate-checksum:duplicate' \
  'fingerprint:fingerprint mismatch' 'board:all family board'; do
  label="${pair%%:*}"; diagnostic="${pair#*:}"
  choose "${label}"; export KERNEL_CLI_CASE="${label}"
  refuse "${label} rejected" "${diagnostic}"
  [[ ! -e "${store}" ]] && ok "${label} left no output store" || bad "${label} left output state"
done
choose os-floor
export KERNEL_CLI_CASE=raise-floor
refuse 'OS floor advanced during build refuses commit' 'os_kernel_below_floor'
[[ ! -e "${store}" ]] && ok 'advanced floor leaves no output store' || bad 'advanced floor left output state'
rm "${WORK}/os/kernel.json"
choose collision
export KERNEL_CLI_CASE=collision KERNEL_CLI_DEST="${store}/${selected}"
refuse 'late collision preserves existing directory' 'immutable candidate already exists'
assert_eq 'late collision sentinel unchanged' preserved "$(<"${store}/${selected}/sentinel")"
choose atomic-collision
mkdir "${WORK}/injection"
cat >"${WORK}/injection/sitecustomize.py" <<'PY'
import ctypes, os, pathlib
real_loader = ctypes.CDLL
class Boundary:
    def __init__(self, *args, **kwargs):
        native = real_loader(*args, **kwargs).renameat2
        native.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        native.restype = ctypes.c_int
        def collide(oldfd, old, newfd, new, flags):
            path = pathlib.Path(os.fsdecode(new))
            path.mkdir()
            (path/'sentinel').write_text('atomic-preserved\n')
            return native(oldfd, old, newfd, new, flags)
        self.renameat2 = collide
ctypes.CDLL = Boundary
PY
PYTHONPATH="${WORK}/injection" refuse 'syscall-time collision is create-only' 'immutable candidate already exists'
assert_eq 'atomic collision sentinel unchanged' atomic-preserved "$(<"${store}/${selected}/sentinel")"
choose bench
jq -n --arg commit "${commit}" --arg sha "$(jq -r .deb_sha256 "${WORK}/input/kernel-artifact.json")" \
  '{type:"kernel-lane",candidate_run_id:"12345",tag:"kernel/v7.2.0-ceralive1",
    commit:$commit,deb_sha256:$sha,boards:(
      {happy:{result:"pass",evidence:["proof/happy.txt"]},
       forced_rollback:{result:"pass",evidence:["proof/rollback.txt"]},
       restored:{result:"pass",evidence:["proof/restored.txt"]}} |
      {"rock-5b-plus":.,"orange-pi-5-plus":.})}' >"${WORK}/bench.json"
invoke --bench-report "${WORK}/bench.json" --channel stable
cmp "${WORK}/bench.json" "${store}/${selected}/bench-${selected}.json"
assert_eq 'bench raw-byte digest bound to authorization inputs' \
  "$(sha256sum "${WORK}/bench.json" | cut -d ' ' -f1)" \
  "$(jq -r .bench_report_sha256 "${store}/${selected}/publish-authorization.inputs.json")"
assert_eq 'channel bound to authorization inputs' stable \
  "$(jq -r .channel "${store}/${selected}/publish-authorization.inputs.json")"
choose invalid-bench
jq '.candidate_run_id = "98765"' "${WORK}/bench.json" >"${WORK}/invalid-bench.json"
refuse 'bench mismatch prevents bundle creation' 'candidate_run_id' --bench-report "${WORK}/invalid-bench.json"
[[ ! -e "${store}" ]] && ok 'invalid bench left no output store' || bad 'invalid bench left output state'
choose nested
parent="${store}"
store="${parent}/child/grandchild"
export KERNEL_CLI_CASE=bytes
refuse 'nested output failure rejected' SHA256SUMS
[[ ! -e "${parent}" ]] && ok 'attempt-created parents removed' || bad 'nested output parents remain'
sha256sum "${bundle}/"* >"${WORK}/preserved.sha256"
kernel_test_version "${repo}" 7.2.0-ceralive2
git -C "${repo}" add -- manifests/families/rk3588.yaml
git -C "${repo}" -c user.name=Fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false commit -qm 'next fixture version'
kernel_test_artifact "${WORK}/input-next" 7.2.0-ceralive2 "${repo}"
choose preserve
store="$(dirname "${bundle}")"
export KERNEL_CLI_CASE=bytes KERNEL_CLI_INPUT="${WORK}/input-next"
refuse 'failed next version preserves completed candidate' SHA256SUMS
sha256sum -c "${WORK}/preserved.sha256"
assert_eq 'existing store contains only completed version' "${selected}" "$(find "${store}" -mindepth 1 -maxdepth 1 -printf '%f\n')"
kernel_test_version "${repo}" 7.2.0-ceralive1
git -C "${repo}" add -- manifests/families/rk3588.yaml
git -C "${repo}" -c user.name=Fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false commit -qm 'restore fixture version'
export KERNEL_CLI_INPUT="${WORK}/input"
choose lock
lock_inode="$(stat -c %i "${repo}/mkosi/.kernel-release.lock")"
exec 9>"${repo}/mkosi/.kernel-release.lock"
flock --exclusive 9
refuse 'concurrent local producer refuses without building' 'Resource temporarily unavailable'
[[ ! -e "${KERNEL_CLI_LOG}" || "$(grep -c '^build$' "${KERNEL_CLI_LOG}")" == 0 ]] \
  && ok 'foreign lock prevents build' || bad 'foreign lock allowed build'
exec 9>&-
assert_eq 'persistent producer lock inode preserved' "${lock_inode}" "$(stat -c %i "${repo}/mkosi/.kernel-release.lock")"
[[ ! -e "${store}" ]] && ok 'foreign lock leaves no output store' || bad 'foreign lock created output state'
choose invalid
refuse 'newline candidate ID rejected' 'invalid candidate_run_id' --candidate-run-id $'12\n34'
DRY_RUN=1 refuse 'dry run cannot seal a candidate' 'DRY_RUN'
refuse 'outside repository bundle store rejected' 'inside this repository' --output-dir "${WORK}/external"
refuse 'producer lock cannot be inside output store' 'must not contain the producer lock' --output-dir "${repo}/mkosi"
git -C "${repo}" tag "kernel/v${selected}" HEAD^
refuse 'existing tag at another commit refused' 'tag commit differs'
git -C "${repo}" tag --delete "kernel/v${selected}" >/dev/null
git -C "${repo}" rev-parse HEAD >"${repo}/.git/shallow"
refuse 'shallow history refused' 'complete local tag history'
rm "${repo}/.git/shallow"
printf '\n# local dirty source\n' >>"${repo}/lib/kernel/only.sh"
refuse 'dirty source rejected' 'clean source checkout'
# Publish refusal must not even read a repository, resolve inputs, or create output.
mkdir "${WORK}/standalone"
cp "${ROOT}/ci/kernel-release.py" "${WORK}/standalone/"
# A wedged transport must be unreachable from the local publish refusal.
export KERNEL_CLI_HANG_FIFO="${WORK}/gh-hang"
mkfifo "${KERNEL_CLI_HANG_FIFO}"
printf '#!/usr/bin/env bash\nprintf "called\\n" >>"$KERNEL_CLI_NETWORK"\nIFS= read -r _ <"$KERNEL_CLI_HANG_FIFO"\n' >"${WORK}/bin/gh"
for args in none with-inputs; do
  extra=()
  if [[ "${args}" == with-inputs ]]; then
    extra=(rk3588 --candidate-run-id 12345 --os-releases "${WORK}/os" --channel stable)
  fi
  code=0
  timeout --kill-after=2 10 python3 "${WORK}/standalone/kernel-release.py" --publish \
    --output-dir "${WORK}/never-created-${args}" "${extra[@]}" >"${WORK}/publish-error" 2>&1 || code=$?
  [[ "${code}" == 1 ]] && ok 'publish exits nonzero' || bad "publish returned ${code}"
  for token in 'owner decision' kernel-release.yml workflow_dispatch kernel-release 'on this PC' 'apt-worker contract change'; do
    grep -Fq "${token}" "${WORK}/publish-error" || bad "missing publication decision: ${token}"
  done
  [[ ! -e "${WORK}/never-created-${args}" ]] && ok 'publish touches no output' || bad 'publish created output'
done
for context in partial wrong; do
  code=0
  (
    source "${ROOT}/tests/lib/clear-workflow-env.sh"
    export GITHUB_ACTIONS=true
    if [[ "${context}" == wrong ]]; then
      export GITHUB_REPOSITORY=CERALIVE/image-building-pipeline
      export GITHUB_WORKFLOW_REF=CERALIVE/image-building-pipeline/.github/workflows/kernel-release.yml@refs/heads/master
      export GITHUB_REF=refs/heads/untrusted GITHUB_RUN_ATTEMPT=1 GITHUB_EVENT_NAME=workflow_dispatch
    fi
    timeout --kill-after=2 10 python3 "${WORK}/standalone/kernel-release.py" --publish
  ) >"${WORK}/context-error" 2>&1 || code=$?
  assert_eq "${context} workflow context exits at the publication guard" 1 "${code}"
  if cmp -s "${WORK}/publish-error" "${WORK}/context-error"; then
    ok "${context} workflow context gives the exact local publication refusal"
  else
    bad "${context} workflow context gave a different refusal"
    cat "${WORK}/context-error"
  fi
done
[[ ! -e "${KERNEL_CLI_NETWORK}" ]] && ok 'every test completed without network tools' || bad 'network boundary reached'
[[ ! -e "${WORK}/standalone/__pycache__" ]] && ok 'publish creates no bytecode cache' || bad 'publish wrote bytecode'
printf 'Local kernel release contract: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" == 0 ]]
