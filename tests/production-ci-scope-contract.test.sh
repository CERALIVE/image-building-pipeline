#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"
REPO="${PIPELINE_DIR}"

reject_pattern() {
  local pattern="$1" file="$2"
  if grep -q "${pattern}" "${file}"; then
    printf 'forbidden pattern %s in %s\n' "${pattern}" "${file}" >&2
    exit 1
  fi
}

grep -Eq '^jsonschema==[0-9]+\.[0-9]+\.[0-9]+$' "${PIPELINE_DIR}/ci/requirements-ci.txt"
grep -Eq '^PyYAML==[0-9]+\.[0-9]+\.[0-9]+$' "${PIPELINE_DIR}/ci/requirements-ci.txt"
grep -Eq '^FROM debian:trixie-[0-9]{8}-slim@sha256:[0-9a-f]{64}$' "${PIPELINE_DIR}/ci/Dockerfile"
reject_pattern 'no x86 disk artifact present.*skip' "${REPO}/.github/workflows/v2-ci.yml"
reject_pattern 'if ! ./ci/check-size-regression.sh' "${REPO}/.github/workflows/v2-ci.yml"
if rg -n 'REPO_ROOT/\.\./CeraUI|PIPELINE_DIR/\.\./\.\.|DEV_SYNC_HERE}/\.\./\.\./\.\./\.\.' \
    "${PIPELINE_DIR}"/tests/{manifest-schema,package-contract,postinst-wiring,mkosi-image-contract,runtime-services,variant-contract}.bats \
    "${PIPELINE_DIR}/tests/manifest-helpers.bash" "${PIPELINE_DIR}/tests/realhw-suite.sh" \
    "${PIPELINE_DIR}/lib/build-bundle.sh" "${PIPELINE_DIR}/lib/dev-sync/config.sh"; then
  printf 'tracked code escapes the repository root\n' >&2
  exit 1
fi
[[ -s "${PIPELINE_DIR}/ci/size-exceptions.txt" ]]

python3 - "${PIPELINE_DIR}/.github/workflows/v2-ci.yml" <<'PY'
import sys
from pathlib import Path
import yaml

workflow = yaml.safe_load(Path(sys.argv[1]).read_text())
steps = workflow["jobs"]["bats"]["steps"]
checks = [step for step in steps
          if step.get("run", "").strip() == "python3 ci/upstream-watch.py --self-test"]
assert len(checks) == 1, "PR unit job must run the offline upstream watcher self-test once"
assert "if" not in checks[0] and not checks[0].get("continue-on-error"), checks[0]
assert not checks[0].get("env"), "offline self-test must not require credentials"
PY

printf 'production CI/scope contract: PASS\n'
