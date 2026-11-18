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

python3 - "${PIPELINE_DIR}/.github/workflows/v2-ci.yml" "${PIPELINE_DIR}/ci/Dockerfile" <<'PY'
import re
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

# The only upstream mkosi source must be a full commit. Installing that
# checkout must depend on verifying HEAD against the same pin.
dockerfile_path = Path(sys.argv[2])
dockerfile = dockerfile_path.read_text()
instructions = re.sub(r"\\\n[ \t]*", " ", dockerfile).splitlines()
source = [line.strip() for line in instructions
          if "github.com/systemd/mkosi" in line and not line.lstrip().startswith("#")]
pin = re.compile(r"^RUN mkosi_commit=[0-9a-f]{40}\s*&&")
assert len(source) == 1 and pin.match(source[0]), "mkosi source must pin a full Git commit"
git = r'git -C "\$\{mkosi_src\}" '
assert re.search(
    git + r'fetch --depth=1 --no-tags https://github\.com/systemd/mkosi\.git "\$\{mkosi_commit\}"\s*&&\s*'
    + git + r'checkout --detach FETCH_HEAD\s*&&\s*'
    r'test "\$\(' + git + r'rev-parse HEAD\)" = "\$\{mkosi_commit\}"\s*&&\s*'
    r'wheelhouse="\$\(mktemp -d\)"\s*&&\s*'
    r'python3 -m venv /opt/mkosi\s*&&\s*'
    r'/opt/mkosi/bin/python -m pip download --disable-pip-version-check --no-cache-dir\s+'
    r'--index-url https://pypi\.org/simple --only-binary=:all: --require-hashes\s+'
    r'--requirement /opt/mkosi-build-requirements\.txt --dest "\$\{wheelhouse\}"\s*&&\s*'
    r'/opt/mkosi/bin/python -m pip install --no-cache-dir\s+'
    r'--no-index --find-links "\$\{wheelhouse\}" "\$\{mkosi_src\}"(?:\s*&&|$)',
    source[0],
), "mkosi install must verify HEAD and install offline from hash-checked wheels"
assert instructions.count("COPY mkosi-build-requirements.txt /opt/mkosi-build-requirements.txt") == 1, (
    "mkosi builder must copy in its hashed requirements"
)
assert not any(re.search(r"\bpipx\s+install\b", line) for line in instructions
               if not line.lstrip().startswith("#")), "pipx install bypasses the verified wheelhouse"

locked = []
for line in dockerfile_path.with_name("mkosi-build-requirements.txt").read_text().splitlines():
    line = line.strip()
    if line and not line.startswith("#"):
        requirement = re.fullmatch(r"([a-z-]+)==[0-9]+(?:\.[0-9]+)+ --hash=sha256:[0-9a-f]{64}", line)
        assert requirement, f"mkosi build requirement must pin a version and wheel SHA-256: {line}"
        locked.append(requirement[1])
assert sorted(locked) == ["packaging", "setuptools", "setuptools-scm", "vcs-versioning"], (
    "mkosi build lock must list each dependency in the Python 3.13 closure exactly once"
)
PY

# Given the CI cache-miss RAUC source GET, when its curl command is inspected,
# then SSL-read retry coverage must match the shipped build fetchers.
awk '
  /^[[:space:]]*curl .*RAUC_PIN_URL/ {
    seen++
    if ($0 !~ /[[:space:]]--retry-all-errors([[:space:]]|$)/) {
      print "CI RAUC fetch lacks --retry-all-errors" > "/dev/stderr"
      failed = 1
    }
  }
  END { exit failed || seen != 1 }
' "${PIPELINE_DIR}/.github/workflows/v2-ci.yml"

printf 'production CI/scope contract: PASS\n'
