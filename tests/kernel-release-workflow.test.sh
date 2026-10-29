#!/usr/bin/env bash
# Offline workflow sequence: real producer gates/metadata, fake GitHub transport.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${ROOT}/tests/lib/assertions.sh"
source "${ROOT}/tests/lib/kernel-release-fixtures.sh"
WORK="$(mktemp -d)"
trap 'rm -rf -- "${WORK}"' EXIT
export ROOT WORK GIT_MASTER=1
python3 - "${ROOT}" <<'PY'
import pathlib, sys, yaml
root = pathlib.Path(sys.argv[1])
workflow = yaml.load((root/'.github/workflows/kernel-release.yml').read_text(), Loader=yaml.BaseLoader)
assert workflow['on']['push'] == {'tags':['kernel/v*']}
assert set(workflow['on']) == {'push', 'workflow_dispatch'}
assert workflow['permissions'] == {'contents':'read'}
assert workflow['concurrency']['cancel-in-progress'] == 'false'
tag_input = workflow['on']['workflow_dispatch']['inputs']['tag']
assert tag_input['type'] == 'string' and tag_input['required'] == 'true'
def permits(condition: str, event: str, ref: str, mode: str) -> bool:
    expression = condition.replace('&&',' and ').replace('||',' or ')
    for field,value in {'github.event_name':event,'github.ref':ref,'inputs.mode':mode}.items():
        expression = expression.replace(field,repr(value))
    return bool(eval(expression,{'__builtins__':{}}))
jobs = workflow['jobs']
assert set(jobs['candidate']['needs']) == {'lint','tests'}
assert set(jobs['publish']['needs']) == {'lint','tests'}
vm_jobs = {name:job for name,job in jobs.items() if job['runs-on'] != 'ubuntu-latest'}
assert set(vm_jobs) == {'tests','candidate','publish'}
for name,job in vm_jobs.items():
    assert job['runs-on'] == {'group':'kernel-release','labels':'ceralive-kernel-vm'}
    assert job['environment'] == 'kernel-release'
    clauses = [part.strip() for part in job['if'].split('&&')]
    assert "github.event_name == 'workflow_dispatch'" in clauses, (name,'event_name')
    assert "github.ref == 'refs/heads/master'" in clauses, (name,'ref')
    assert '||' not in job['if']
    assert any('test "$GITHUB_RUN_ATTEMPT" = 1' in step.get('run','') for step in job['steps'])
    for event,ref in (
        ('push','refs/tags/kernel/v7.2.0-ceralive2'),
        ('workflow_dispatch','refs/tags/kernel/v7.2.0-ceralive2'),
        ('workflow_dispatch','refs/heads/untrusted'),
        ('pull_request','refs/pull/1/merge'),
    ):
        for mode in workflow['on']['workflow_dispatch']['inputs']['mode']['options']:
            assert not permits(job['if'],event,ref,mode), (name,event,ref,mode)
    assert any(permits(job['if'],'workflow_dispatch','refs/heads/master',mode)
               for mode in workflow['on']['workflow_dispatch']['inputs']['mode']['options'])
for name in ('candidate','publish'):
    assert jobs[name]['env']['KERNEL_RELEASE_TAG'] == '${{ inputs.tag }}'
assert jobs['publish']['concurrency'] == {'group':'ceralive-kernel-floor','cancel-in-progress':'false'}
image = yaml.load((root/'.github/workflows/publish-release.yml').read_text(), Loader=yaml.BaseLoader)
assert image['jobs']['publish']['concurrency'] == jobs['publish']['concurrency']
steps = jobs['publish']['steps']
authorize = next(i for i,s in enumerate(steps) if '--publish authorize' in s.get('run',''))
upload = next(i for i,s in enumerate(steps) if s.get('with',{}).get('name') == 'publish-authorization')
dispatch = next(i for i,s in enumerate(steps) if '--publish dispatch' in s.get('run',''))
assert authorize < upload < dispatch
assert all(s['with']['fetch-depth'] == '0' for job in jobs.values()
           for s in job['steps'] if s.get('uses','').startswith('actions/checkout@'))
PY
ok 'workflow gates, immutable attempts, VM routing and publication ordering'
repo="${WORK}/repo"
kernel_test_repo "${repo}"
kernel_test_version "${repo}" 7.2.0-ceralive2
mkdir -p "${WORK}/bin" "${WORK}/os" "${WORK}/state"
kernel_test_artifact "${WORK}/candidate" 7.2.0-ceralive2 "${repo}"
git -C "${repo}" add -- ci lib manifests versions.yaml mkosi
git -C "${repo}" -c user.name=Fixture -c user.email=fixture@example.invalid \
  -c commit.gpgsign=false commit -qm 'workflow fixture'
commit="$(git -C "${repo}" rev-parse HEAD)"
git -C "${repo}" tag kernel/v7.2.0-ceralive2
export GITHUB_ACTIONS=true GITHUB_REPOSITORY=CERALIVE/image-building-pipeline
export GITHUB_WORKFLOW_REF=CERALIVE/image-building-pipeline/.github/workflows/kernel-release.yml@refs/heads/master
export GITHUB_REF=refs/heads/master GITHUB_RUN_ATTEMPT=1 GITHUB_EVENT_NAME=workflow_dispatch
export GITHUB_RUN_ID=67890 KERNEL_PUBLISH_JOB_ID=100
export KERNEL_RELEASE_TAG=kernel/v7.2.0-ceralive2
export WF_STATE="${WORK}/state" WF_CANDIDATE="${WORK}/candidate" WF_COMMIT="${commit}"
export CERALIVE_DISPATCH_TOKEN=fixture-token
unset CERALIVE_KERNEL_HISTORY_DIR
cat >"${WORK}/bin/gh" <<'PY'
#!/usr/bin/env python3
import io, json, os, pathlib, shutil, sys, zipfile
args = sys.argv[1:]
state = pathlib.Path(os.environ['WF_STATE'])
candidate = pathlib.Path(os.environ['WF_CANDIDATE'])
commit = os.environ['WF_COMMIT']
fault = os.environ.get('WF_FAULT','')
selected = os.environ.get('WF_VERSION','7.2.0-ceralive2')
release = state/'release'/selected
with (state/'calls').open('a') as log: log.write(' '.join(args)+'\n')
if args[:1] == ['api']:
    path = next(a for a in args[1:] if a.startswith(('repos/','orgs/')))
    if path.endswith('/releases'):
        if (state/'release').exists():
            for existing in sorted((state/'release').iterdir()): print('kernel/v'+existing.name)
    elif '/concurrency_groups/' in path:
        print(json.dumps({'group_name':'ceralive-kernel-floor','group_members':[
            {'run_id':67890 if fault != 'lease' else 9,'job_id':100,'status':'in_progress'}]}))
    elif path.endswith('/approvals'):
        print(json.dumps([] if fault == 'approval' else [
            {'state':'approved','environments':[{'name':'kernel-release'}]}]))
    elif '/artifacts?' in path:
        current = '/67890/' in path
        row = {'name':'publish-authorization' if current else 'kernel-candidate-'+commit,
               'id':99 if current else 88,'expired':fault == 'expired',
               'workflow_run':{'id':67890 if current else 12345,'head_sha':commit}}
        print(json.dumps(row))
        if fault == 'duplicate': print(json.dumps(row))
    elif '/artifacts/' in path and path.endswith('/zip'):
        stream = io.BytesIO()
        directory = state/'uploaded' if '/99/' in path else candidate
        with zipfile.ZipFile(stream,'w') as archive:
            for file in sorted(directory.iterdir()): archive.write(file, file.name)
            if fault == 'archive-path': archive.writestr('../escape','unsafe')
        sys.stdout.buffer.write(stream.getvalue())
    elif '/actions/runs/' in path:
        current = path.endswith('/67890')
        print(json.dumps({'id':67890 if current else 12345,'run_attempt':2 if fault == 'attempt' else 1,
            'path':'.github/workflows/other.yml' if fault == 'path' else '.github/workflows/kernel-release.yml',
            'head_sha':'0'*40 if fault == 'commit' else commit,'head_branch':'master',
            'event':'push' if fault == 'event' else 'workflow_dispatch',
            'status':'in_progress' if current else 'completed',
            'conclusion':'failure' if fault == 'conclusion' else 'success',
            'repository':{'full_name':'CERALIVE/image-building-pipeline'}}))
    elif path.endswith('/dispatches'):
        assert os.environ['GH_TOKEN'] == 'fixture-token'
        (state/'dispatch.json').write_text(sys.stdin.read())
    else: sys.exit('unhandled API: '+path)
elif args[:2] == ['release','create']:
    release.mkdir(parents=True)
    for arg in args[3:]:
        file = pathlib.Path(arg)
        if file.is_file(): shutil.copyfile(file, release/file.name)
elif args[:2] == ['release','download']:
    assert release.exists(), 'Release is missing'
    dest = pathlib.Path(args[args.index('--dir')+1])
    for i,arg in enumerate(args[:-1]):
        if arg == '--pattern': shutil.copyfile(release/args[i+1], dest/args[i+1])
else: sys.exit('unhandled gh: '+repr(args))
PY
chmod 755 "${WORK}/bin/gh"
export PATH="${WORK}/bin:${PATH}"
invoke() {
  python3 "${repo}/ci/kernel-release.py" --publish "$1" \
    --candidate-run-id 12345 --channel "${WF_CHANNEL:-beta}" --os-releases "${WORK}/os" \
    --authorization "${WORK}/publish-authorization.json"
}
refuse() {
  local label="$1"; shift
  if invoke "$@" >"${WORK}/refused" 2>&1; then bad "${label}: accepted"; else ok "${label}"; fi
  [[ ! -e "${WF_STATE}/dispatch.json" ]] && ok "${label}: zero dispatches" || bad "${label}: dispatched"
}
refuse 'APT refuses a missing identity Release' authorize
invoke release
[[ -d "${WF_STATE}/release" && ! -e "${WF_STATE}/dispatch.json" ]] \
  && ok 'release establishes identity without bench or APT dispatch' || bad 'release sequence'
refuse 'APT blocked until a report is attached to existing Release' authorize
sha="$(jq -r .deb_sha256 "${WORK}/candidate/kernel-artifact.json")"
report="${WF_STATE}/release/7.2.0-ceralive2/bench-7.2.0-ceralive2.json"
jq -n --arg commit "${commit}" --arg sha "${sha}" \
  '{type:"kernel-lane",candidate_run_id:"12345",tag:"kernel/v7.2.0-ceralive2",commit:$commit,
    deb_sha256:$sha,boards:({happy:{result:"pass",evidence:["proof/happy"]},
    forced_rollback:{result:"pass",evidence:["proof/rollback"]},restored:{result:"pass",evidence:["proof/restore"]}} |
    {"rock-5b-plus":.,"orange-pi-5-plus":.})}' >"${report}"
for fault in approval lease path event attempt commit conclusion expired duplicate archive-path; do
  WF_FAULT="${fault}" refuse "${fault} provenance refuses" authorize
done
KERNEL_RELEASE_TAG=kernel/v7.2.0-ceralive9 refuse 'requested tag must match candidate' authorize
for field in not-run missing-board wrong-sha wrong-run; do
  cp "${report}" "${WORK}/report-original"
  case "${field}" in
    not-run) expression='.boards["rock-5b-plus"].happy.result = "not-run"' ;;
    missing-board) expression='del(.boards["orange-pi-5-plus"])' ;;
    wrong-sha) expression='.deb_sha256 = ("0"*64)' ;;
    wrong-run) expression='.candidate_run_id = "98765"' ;;
  esac
  jq "${expression}" "${WORK}/report-original" >"${report}"
  refuse "${field} bench refuses" authorize
  cp "${WORK}/report-original" "${report}"
done
cp "${WF_STATE}/release/7.2.0-ceralive2/resolved.config" "${WORK}/config"
printf '\nchanged\n' >>"${WF_STATE}/release/7.2.0-ceralive2/resolved.config"
refuse 'released bytes must equal candidate checksums' authorize
cp "${WORK}/config" "${WF_STATE}/release/7.2.0-ceralive2/resolved.config"
invoke authorize
[[ ! -e "${WF_STATE}/dispatch.json" ]] && ok 'authorization alone never dispatches' || bad 'early dispatch'
mkdir "${WF_STATE}/uploaded"
cp "${WORK}/publish-authorization.json" "${WF_STATE}/uploaded/"
invoke dispatch
python3 - "${WF_STATE}/dispatch.json" "${sha}" <<'PY'
import json, sys
assert json.load(open(sys.argv[1])) == {'event_type':'apt-reindex','client_payload':{
    'component':'ceralive-kernel','repo':'image-building-pipeline','channel':'beta',
    'tag':'kernel/v7.2.0-ceralive2','version':'7.2.0-ceralive2',
    'kernel_package':'linux-image-7.2.0-ceralive-rk3588',
    'kernel_artifact_sha256':sys.argv[2],'publish_run_id':'67890'}}
PY
ok 'matching two-board report dispatches the exact sole-publisher inputs'
rm "${WF_STATE}/dispatch.json" "${WORK}/publish-authorization.json"
export WF_CHANNEL=stable
jq -n --arg sha "${sha}" '{type:"bootstrap",version:"7.2.0-ceralive2",deb_sha256:$sha,
  approving_owner:"andrescera",statement:"No kernel-apt-stage image is published."}' >"${report}"
invoke authorize
cp "${WORK}/publish-authorization.json" "${WF_STATE}/uploaded/"
invoke dispatch
[[ -e "${WF_STATE}/dispatch.json" ]] && ok 'bootstrap authorizes without invented upstream eligibility' || bad 'bootstrap'
assert_eq 'bootstrap targets the stable channel consumed by the OS fixture' stable \
  "$(jq -r .client_payload.channel "${WF_STATE}/dispatch.json")"
KERNEL_REUSE_FIXTURE_BUNDLE="${WF_STATE}/release/7.2.0-ceralive2" \
  bash "${ROOT}/tests/kernel-artifact-reuse.test.sh"
ok 'bootstrap Release bytes feed the capable OS authenticated APT fixture'
rm "${WF_STATE}/dispatch.json"
printf 'tampered\n' >>"${WF_STATE}/uploaded/publish-authorization.json"
refuse 'uploaded authorization must match raw reviewed bytes' dispatch
calls_before="$(wc -l <"${WF_STATE}/calls")"
GITHUB_RUN_ATTEMPT=2 refuse 'reruns refuse before workflow code or API access' authorize
assert_eq 'rerun refusal is the publication guard diagnostic' \
  'kernel release: publication blocked pending owner decision: apt-worker requires a kernel-release.yml workflow_dispatch run approved in the kernel-release environment; choose a self-hosted kernel-release.yml on this PC or an apt-worker contract change' \
  "$(<"${WORK}/refused")"
assert_eq 'rerun performs no API calls' "${calls_before}" "$(wc -l <"${WF_STATE}/calls")"
rm "${WORK}/publish-authorization.json"
export WF_CHANNEL=beta
kernel_test_version "${repo}" 7.2.0-ceralive3
git -C "${repo}" add -- manifests/families/rk3588.yaml
git -C "${repo}" -c user.name=Fixture -c user.email=fixture@example.invalid \
  -c commit.gpgsign=false commit -qm 'next workflow fixture'
WF_COMMIT="$(git -C "${repo}" rev-parse HEAD)"
export WF_COMMIT WF_VERSION=7.2.0-ceralive3
export KERNEL_RELEASE_TAG=kernel/v7.2.0-ceralive3
git -C "${repo}" tag kernel/v7.2.0-ceralive3
kernel_test_artifact "${WORK}/candidate" 7.2.0-ceralive3 "${repo}"
rm "${WORK}/candidate/"*_7.2.0-ceralive2_arm64.deb
invoke release
sha="$(jq -r .deb_sha256 "${WORK}/candidate/kernel-artifact.json")"
jq -n --arg sha "${sha}" '{type:"bootstrap",version:"7.2.0-ceralive3",deb_sha256:$sha,
  approving_owner:"andrescera",statement:"No kernel-apt-stage image is published."}' \
  >"${WF_STATE}/release/7.2.0-ceralive3/bench-7.2.0-ceralive3.json"
invoke authorize
cp "${WORK}/publish-authorization.json" "${WF_STATE}/uploaded/"
invoke dispatch
[[ -e "${WF_STATE}/dispatch.json" ]] && ok 'later bootstrap is dispatched for publisher adjudication' || bad 'later bootstrap'
# Drive the actual publisher function, not an invented upstream eligibility check.
source "${ROOT}/tests/fixtures/kernel-bootstrap-publisher.sh"
STAGING_DIR="${WORK}/publisher"; mkdir "${STAGING_DIR}"
R2_BUCKET=fixture R2_ENDPOINT=https://fixture.invalid CHANNEL=beta
KERNEL_PACKAGE=linux-image-7.2.0-ceralive-rk3588 VERSION=7.2.0-ceralive3
KERNEL_ARTIFACT_SHA256="${sha}"
KERNEL_BOOTSTRAP_KEY=kernel-publications/bootstrap.json
KERNEL_RECEIPT_KEY="kernel-publications/beta/${KERNEL_PACKAGE}_${VERSION}.json"
KERNEL_COMPLETE_KEY="kernel-publications/beta/${KERNEL_PACKAGE}_${VERSION}.verified.json"
die() { printf '%s\n' "$*" >&2; exit 1; }
aws() {
  [[ "$1 $2" == 's3api list-objects-v2' ]] || { printf 'write\n' >>"${WORK}/publisher-writes"; return 99; }
  printf 'kernel-publications/stable/linux-image-7.2.0-ceralive-rk3588_7.2.0-ceralive2.json\n'
}
if (kernel_check_bootstrap_state) >"${WORK}/publisher-refusal" 2>&1; then
  bad 'publisher accepted a second bootstrap'
else
  ok 'actual publisher validator rejects later bootstrap after first publication'
fi
[[ ! -e "${WORK}/publisher-writes" ]] && ok 'publisher rejected bootstrap with zero uploads' || bad 'publisher wrote'
cat >"${WORK}/bin/aws" <<'SH'
#!/usr/bin/env bash
[[ "$1 $2" == 's3api list-objects-v2' ]] || exit 99
printf '{"Contents":[],"IsTruncated":false}\n'
SH
chmod 755 "${WORK}/bin/aws"
R2_IMAGES_ENDPOINT=https://fixture.invalid AWS_ACCESS_KEY_ID=fixture AWS_SECRET_ACCESS_KEY=fixture \
  bash "${repo}/ci/publish-release.sh" kernel-floor --kernel-version 7.2.0-ceralive3 \
    --os-releases "${WORK}/floor"
[[ -d "${WORK}/floor" ]] && ok 'read-only floor mode exports complete authenticated inventory' || bad 'floor output'
assert_eq 'only release operations create identity Releases' 2 "$(grep -c '^release create ' "${WF_STATE}/calls")"
printf 'Kernel release workflow contract: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" == 0 ]]
