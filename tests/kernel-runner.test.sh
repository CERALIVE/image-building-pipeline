#!/usr/bin/env bash
# QEMU and gh are stubbed; fd handoff and cleanup are real host operations.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${ROOT}/tests/lib/assertions.sh"
WORK="$(mktemp -d)"
trap 'rm -rf -- "${WORK}"' EXIT
mkdir "${WORK}/bin"
mkdir "${WORK}/trust"
cp "${ROOT}/ci/kernel-runner/"{keyring.sh,armbian-old.asc,armbian-new.asc} "${WORK}/trust/"
if bash "${WORK}/trust/keyring.sh" "${WORK}/armbian.gpg"; then
  source "${ROOT}/lib/fetch-debs-auth.sh"
  if auth_keyring_has_exact_fingerprints "${WORK}/armbian.gpg" \
      DF00FAF1C577104B50BF1D0093D6889F9F0E78D5 \
      8CFA83D13EB2181EEF5843E41EB30FAF236099FE; then
    ok 'provided digest-pinned public keys produce the exact firmware trust set'
  else bad 'provided keyring has wrong primary keys'; fi
else bad 'provided public keyring refused'; fi
rm "${WORK}/armbian.gpg" "${WORK}/trust/armbian-new.asc"
if bash "${WORK}/trust/keyring.sh" "${WORK}/armbian.gpg"; then
  bad 'missing public key accepted'
else
  [[ ! -e "${WORK}/armbian.gpg" ]] && ok 'missing public key refuses without output' \
    || bad 'missing public key left an output'
fi
cp "${ROOT}/ci/kernel-runner/armbian-new.asc" "${WORK}/trust/"
printf '\n' >>"${WORK}/trust/armbian-new.asc"
if bash "${WORK}/trust/keyring.sh" "${WORK}/armbian.gpg"; then
  bad 'wrong public key digest accepted'
else
  [[ ! -e "${WORK}/armbian.gpg" ]] && ok 'wrong public key digest refuses without output' \
    || bad 'wrong public key digest left an output'
fi
touch "${WORK}/base.qcow2"
printf 'exit 0\n' >"${WORK}/check.sh"
printf 'PUBLIC_SOURCE_CAPSULE\n' >"${WORK}/source.tar"
export VM_WORK="${WORK}"
cat >"${WORK}/bin/qemu-img" <<'SH'
#!/usr/bin/env bash
touch "${@: -1}"
SH
cat >"${WORK}/bin/gh" <<'PY'
#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
assert args[:4] == ['api','--method','POST','orgs/CERALIVE/actions/runners/generate-jitconfig']
assert 'runner_group_id=9' in args and 'labels[]=ceralive-kernel-vm' in args
pathlib.Path(os.environ['VM_WORK'],'gh-called').touch()
if os.environ.get('VM_FAIL') == 'gh': sys.exit(7)
print(json.dumps({'encoded_jit_config':'SINGLE_USE_SECRET'}))
PY
cat >"${WORK}/bin/qemu-system-x86_64" <<'PY'
#!/usr/bin/env python3
import os, pathlib, sys
args = sys.argv[1:]
assert not os.isatty(0), 'a background VM must not inherit the terminal input'
assert not any(x in ('-virtfs','-fsdev','-virtiofs','-smb','-chardev') for x in args)
assert not any('hostfwd=' in x or 'smb=' in x or '9p' in x or 'vhost-user' in x for x in args)
assert 'user,id=net0' in args
assert 'virtio-blk-pci,drive=system,bootindex=1' in args
if 'virtio-blk-pci,drive=source,serial=ceralive-source' in args:
    capsule = next(a for a in args if 'id=source,' in a)
    assert capsule.endswith(',readonly=on')
    assert pathlib.Path(capsule.split(',')[0].split('=',1)[1]).read_bytes() == b'PUBLIC_SOURCE_CAPSULE\n'
assert 'GH_TOKEN' not in os.environ and 'CERALIVE_DISPATCH_TOKEN' not in os.environ
entry = args[args.index('-fw_cfg')+1]
path = entry.split('file=',1)[1]
assert path.startswith('/proc/self/fd/')
data = pathlib.Path(path).read_bytes()
assert data == (b'exit 0\n' if '/check,' in entry else b'SINGLE_USE_SECRET')
assert os.readlink(path).startswith('/memfd:ceralive-job')
disk = args[args.index('-drive')+1].split(',')[0].split('=',1)[1]
assert disk.startswith('/proc/self/fd/')
disk_path = os.readlink(disk)
assert disk_path.endswith(' (deleted)'), 'job disk must be unlinked before the VM starts'
work = pathlib.Path(disk_path.removesuffix(' (deleted)')).parent
assert not any(b'SINGLE_USE_SECRET' in p.read_bytes() for p in work.rglob('*')
               if p.is_file() and 'bin' not in p.relative_to(work).parts)
if os.environ.get('VM_FAIL') == 'qemu': sys.exit(8)
print('CERALIVE_JOB_DONE=0')
PY
# QEMU has an intentionally minimal env; select failure via the executable itself.
chmod 755 "${WORK}/bin/"*
export PATH="${WORK}/bin:${PATH}"
if python3 "${ROOT}/ci/kernel-runner/vm.py" check --base "${WORK}/base.qcow2" \
    --check-script "${WORK}/check.sh" >"${WORK}/unlocked.log" 2>&1; then
  bad 'unlocked launcher was accepted'
else
  ok 'unlocked launcher refuses before starting a guest'
fi
invoke() {
  flock --exclusive --close "${WORK}/runner.lock" \
    python3 "${ROOT}/ci/kernel-runner/vm.py" "$@" --base "${WORK}/base.qcow2"
}
invoke check --check-script "${WORK}/check.sh"
invoke check --check-script "${WORK}/check.sh" --source-bundle "${WORK}/source.tar"
[[ ! -e "${WORK}/gh-called" ]] && ok 'offline stand-in never registers a runner' || bad 'registered during check'
GH_TOKEN=host-secret CERALIVE_DISPATCH_TOKEN=host-secret invoke run --group-id 9
[[ -e "${WORK}/gh-called" ]] && ok 'JIT registration is host-only and single-use' || bad 'missing JIT'
[[ "$(find "${WORK}" -maxdepth 1 -name 'job-*' | wc -l)" == 0 ]] \
  && ok 'overlay removed after success' || bad 'overlay survived'
if VM_FAIL=gh invoke run --group-id 9; then bad 'gh failure accepted'; else ok 'gh failure refuses'; fi
[[ "$(find "${WORK}" -maxdepth 1 -name 'job-*' | wc -l)" == 0 ]] \
  && ok 'overlay removed after registration failure' || bad 'overlay survived gh failure'
printf '#!/usr/bin/env bash\nexit 8\n' >"${WORK}/bin/qemu-system-x86_64"
if invoke check --check-script "${WORK}/check.sh"; then bad 'qemu failure accepted'; else ok 'qemu failure refuses'; fi
[[ "$(find "${WORK}" -maxdepth 1 -name 'job-*' | wc -l)" == 0 ]] \
  && ok 'overlay removed after guest failure' || bad 'overlay survived guest failure'
cat >"${WORK}/bin/qemu-system-x86_64" <<'PY'
#!/usr/bin/env python3
import os, signal
os.kill(os.getppid(), signal.SIGTERM)
signal.pause()
PY
if invoke check --check-script "${WORK}/check.sh"; then bad 'stop signal accepted'; else ok 'stop signal aborts'; fi
[[ "$(find "${WORK}" -maxdepth 1 -name 'job-*' | wc -l)" == 0 ]] \
  && ok 'overlay removed after owner stop signal' || bad 'overlay survived stop signal'
cat >"${WORK}/bin/qemu-system-x86_64" <<'PY'
#!/usr/bin/env python3
import os, signal
print(f'FORCED_CHILD_READY={os.getpid()}:{os.getppid()}', flush=True)
signal.pause()
PY
for victim in python flock; do
  if python3 - "${ROOT}" "${WORK}" "${victim}" <<'PY'
import os, pathlib, select, selectors, signal, subprocess, sys
root, work = map(pathlib.Path, sys.argv[1:3])
args = [sys.executable, str(root/'ci/kernel-runner/vm.py'), 'check',
        '--base', str(work/'base.qcow2'), '--check-script', str(work/'check.sh')]
args = ['flock','--exclusive','--close',str(work/'parent-death.lock'),*args]
handles = []
with subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT) as process:
    try:
        with selectors.DefaultSelector() as readiness:
            readiness.register(process.stdout, selectors.EVENT_READ)
            assert readiness.select(timeout=5), 'guest never signaled readiness'
        line = process.stdout.readline().decode().strip()
        assert line.startswith('FORCED_CHILD_READY='), line
        guest, launcher = map(int, line.split('=',1)[1].split(':'))
        handles = [os.pidfd_open(pid) for pid in (guest, launcher)]
        exits = []
        for handle in handles:
            state = select.poll()
            state.register(handle, select.POLLIN)
            exits.append(state)
        if sys.argv[3] == 'python':
            signal.pidfd_send_signal(handles[1],signal.SIGKILL)
        else:
            process.kill()
        process.communicate(timeout=5)
        for state in exits:
            assert state.poll(5000), 'forced parent death left a child running'
        assert not list(work.glob('job-*')), 'forced parent death left an overlay'
    finally:
        for handle in handles:
            state = select.poll()
            state.register(handle, select.POLLIN)
            if not state.poll(0):
                signal.pidfd_send_signal(handle, signal.SIGKILL)
            os.close(handle)
        if process.poll() is None:
            process.kill()
        process.communicate(timeout=5)
PY
  then ok "${victim} SIGKILL stops guest and removes overlay"
  else bad "${victim} SIGKILL leaked guest or overlay"; fi
  # Failed pre-fix controls leave only this test's private files after pidfd cleanup.
  rm -rf -- "${WORK}"/job-*
done
for group in 1 5; do
  if invoke run --group-id "${group}"; then bad 'default group accepted'; else ok 'default group refused'; fi
done

# ---- runner-side admission -------------------------------------------------
# The JIT config is single-use, but the JOB context is whatever GitHub delivers.
# admit-job.sh is the independent guard the runner executes before any step; the
# values are exactly ci/kernel-release.py's --publish context.
admit() {
  # admit [VAR=value]... : a bare VAR= UNSETS that variable (fail-closed).
  local -a env=(
    GITHUB_ACTIONS=true
    GITHUB_REPOSITORY=CERALIVE/image-building-pipeline
    GITHUB_EVENT_NAME=workflow_dispatch
    GITHUB_REF=refs/heads/master
    GITHUB_WORKFLOW_REF=CERALIVE/image-building-pipeline/.github/workflows/kernel-release.yml@refs/heads/master
    GITHUB_RUN_ATTEMPT=1
  )
  local spec var i
  for spec in "$@"; do
    var="${spec%%=*}"
    for i in "${!env[@]}"; do
      [[ "${env[i]%%=*}" == "${var}" ]] && unset 'env[i]'
    done
    [[ -n "${spec#*=}" ]] && env+=("${spec}")
  done
  env -i PATH="${PATH}" "${env[@]}" bash "${ROOT}/ci/kernel-runner/admit-job.sh"
}
reject() {
  local label="$1"; shift
  if admit "$@"; then bad "runner admission accepted ${label}"; else ok "runner admission refuses ${label}"; fi
}
if admit; then ok 'runner admission accepts the approved kernel-release dispatch'; else bad 'approved dispatch refused'; fi
reject 'a pull_request' GITHUB_EVENT_NAME=pull_request
reject 'a tag push' GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/kernel/v1
reject 'a ref other than master' GITHUB_REF=refs/heads/release
reject 'another repository' GITHUB_REPOSITORY=someone/image-building-pipeline
reject 'another workflow ref' GITHUB_WORKFLOW_REF=CERALIVE/image-building-pipeline/.github/workflows/kernel-release.yml@refs/tags/kernel/v1
reject 'a missing GITHUB_RUN_ATTEMPT' GITHUB_RUN_ATTEMPT=
reject 'a re-run attempt' GITHUB_RUN_ATTEMPT=2
reject 'a missing GITHUB_ACTIONS' GITHUB_ACTIONS=

# The hook must be installed root-owned by build-base, wired into the runner
# service, and exported by the guest job BEFORE the runner starts.
hooked() { grep -Fq 'Environment=ACTIONS_RUNNER_HOOK_JOB_STARTED=/usr/local/lib/ceralive-kernel-runner/admit-job.sh' "$1"; }
vm_py="${ROOT}/ci/kernel-runner/vm.py"
guest="${ROOT}/ci/kernel-runner/guest-job.sh"
if hooked "${vm_py}"; then ok 'the runner service is started with the admission hook'; else bad 'runner service has no admission hook'; fi
grep -Fq '"admit-job.sh", "/usr/local/lib/ceralive-kernel-runner/admit-job.sh"' "${vm_py}" \
  && ok 'the pristine base installs the hook from the repository file' || bad 'build-base does not install the hook'
grep -Fq 'export ACTIONS_RUNNER_HOOK_JOB_STARTED="${hook}"' "${guest}" \
  && ok 'the guest job exports the admission hook' || bad 'guest job does not export the hook'
if grep -Fq '[[ -x "${hook}" ]]' "${guest}"; then ok 'the guest job fails closed without the hook'; else bad 'missing hook is not refused'; fi
jit_line="$(grep -n 'if \[\[ -e "${fw}/jit/raw" \]\]' "${guest}" | head -1 | cut -d: -f1)"
hook_line="$(grep -n 'export ACTIONS_RUNNER_HOOK_JOB_STARTED=' "${guest}" | head -1 | cut -d: -f1)"
run_line="$(grep -n 'exec ./run.sh --jitconfig' "${guest}" | head -1 | cut -d: -f1)"
check_line="$(grep -n 'bash "${fw}/check/raw"' "${guest}" | head -1 | cut -d: -f1)"
if [[ -n "${jit_line}" && -n "${hook_line}" && -n "${run_line}" && -n "${check_line}" \
  && "${jit_line}" -lt "${hook_line}" && "${hook_line}" -lt "${run_line}" && "${run_line}" -lt "${check_line}" ]]; then
  ok 'admission is wired on the JIT branch before the runner; the check branch runs no runner'
else bad 'admission wiring is missing or misplaced relative to the runner launch'
fi

# MUTATION: dropping the unit Environment= line leaves the JIT runner unguarded.
mutated="${WORK}/vm.py.unhooked"
grep -v 'Environment=ACTIONS_RUNNER_HOOK_JOB_STARTED=' "${vm_py}" >"${mutated}"
if hooked "${mutated}"; then bad 'mutation losing the hook wiring was not caught'; else ok 'mutation losing the hook wiring is caught'; fi

printf 'Kernel VM runner contract: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" == 0 ]]
