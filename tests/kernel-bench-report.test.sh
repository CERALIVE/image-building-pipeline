#!/usr/bin/env bash
# Canonical schema and executable bench identity gate; no network or hardware.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${ROOT}/tests/lib/assertions.sh"
WORK="$(mktemp -d)"
trap 'rm -rf -- "${WORK}"' EXIT
assert_eq 'canonical apt-worker schema bytes' \
  ed54aa4a797b664a11c1409e671b5b95a65785adf9aa49dfbf16b4cc1148d7f3 \
  "$(sha256sum "${ROOT}/ci/kernel-bench-report.schema.json" | cut -d ' ' -f1)"
python3 - "${WORK}" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
observation = {'result':'pass', 'evidence':['artifacts/proof.txt']}
board = {name:observation for name in ('happy','forced_rollback','restored')}
report = {'type':'kernel-lane', 'candidate_run_id':'12345',
          'tag':'kernel/v7.2.0-ceralive3', 'commit':'1'*40, 'deb_sha256':'2'*64,
          'boards':{'rock-5b-plus':board, 'orange-pi-5-plus':board}}
(root/'valid.json').write_text(json.dumps(report))
for name in ('not-run','missing-board','sha','run-id','extra','evidence','newline','control','control-c1'):
    row = json.loads(json.dumps(report))
    match name:
        case 'not-run': row['boards']['rock-5b-plus']['happy']['result'] = 'not-run'
        case 'missing-board': del row['boards']['orange-pi-5-plus']
        case 'sha': row['deb_sha256'] = '3'*64
        case 'run-id': row['candidate_run_id'] = '67890'
        case 'extra': row['extra'] = 'refused'
        case 'evidence': row['boards']['orange-pi-5-plus']['restored']['evidence'] = []
        case 'newline': row['candidate_run_id'] = '12345\n'
        case 'control': row['boards']['rock-5b-plus']['happy']['evidence'] = ['proof\x00.txt']
        case 'control-c1': row['boards']['rock-5b-plus']['happy']['evidence'] = ['proof\x9f.txt']
    (root/f'{name}.json').write_text(json.dumps(row))
bootstrap = {'type':'bootstrap', 'version':'7.2.0-ceralive3', 'deb_sha256':'2'*64,
             'approving_owner':'andrescera', 'statement':'No kernel-apt-stage image is published.'}
(root/'bootstrap.json').write_text(json.dumps(bootstrap))
PY
gate() {
  python3 "${ROOT}/ci/validate-kernel-bench-report.py" "${WORK}/$1.json" \
    12345 kernel/v7.2.0-ceralive3 \
    1111111111111111111111111111111111111111 \
    2222222222222222222222222222222222222222222222222222222222222222 7.2.0-ceralive3
}
gate valid
ok 'matching complete two-board evidence accepted'
gate bootstrap
ok 'bootstrap schema accepted without claiming publisher state eligibility'
for name in not-run missing-board sha run-id extra evidence newline control control-c1 absent; do
  if gate "${name}" >"${WORK}/${name}.log" 2>&1; then bad "${name}: accepted"
  elif grep -Fq 'Kernel bench report refused:' "${WORK}/${name}.log"; then ok "${name}: refused"
  else bad "${name}: wrong failure"; fi
done
printf 'Kernel bench report contract: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" == 0 ]]
