#!/usr/bin/env bash
# Parse the workflow security boundary; WORKFLOWS_DIR permits isolated mutations.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "${WORKFLOWS_DIR:-${ROOT}/.github/workflows}" "${BASH_SOURCE[0]}" <<'PY'
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

HOSTED = {"ubuntu-latest", "ubuntu-24.04", "ubuntu-22.04"}
RUNNER_FILES = {
    "kernel-release.yml", "publish-release.yml", "real-build-audit.yml", "release.yml",
}
FORBIDDEN_EVENTS = {"pull_request_target", "workflow_run", "issue_comment"}
MATRIX_RUNNER = re.compile(r"\$\{\{\s*matrix\.([A-Za-z_][A-Za-z0-9_-]*)\s*\}\}")
SECRET = re.compile(r"\bsecrets\s*[.\[]|\$\{\{[^}]*\bsecrets\b", re.IGNORECASE)
errors = []


def literal_hosted(value):
    labels = value if isinstance(value, list) else [value]
    return bool(labels) and all(isinstance(v, str) and v in HOSTED for v in labels)


def hosted_runner(job):
    """Resolve only literal hosted labels and fully known matrix runner values."""
    runner = job.get("runs-on")
    labels = runner if isinstance(runner, list) else [runner]
    if not labels:
        return False
    for label in labels:
        if isinstance(label, str) and label in HOSTED:
            continue
        match = MATRIX_RUNNER.fullmatch(label) if isinstance(label, str) else None
        strategy = job.get("strategy", {})
        matrix = strategy.get("matrix") if isinstance(strategy, dict) else None
        if match is None or not isinstance(matrix, dict):
            return False
        key = match.group(1)
        includes = matrix.get("include", [])
        if not isinstance(includes, list) or not all(isinstance(v, dict) for v in includes):
            return False
        values = matrix.get(key, [])
        if not isinstance(values, list):
            return False
        if key not in matrix and any(key not in entry for entry in includes):
            return False
        values = values + [entry[key] for entry in includes if key in entry]
        if not values or not all(literal_hosted(value) for value in values):
            return False
    return True


def strings(value):
    """Walk YAML values and keys without looping on recursive aliases."""
    pending = [value]
    seen = set()
    while pending:
        item = pending.pop()
        if isinstance(item, str):
            yield item
        elif isinstance(item, (dict, list)) and id(item) not in seen:
            seen.add(id(item))
            pending.extend([*item.keys(), *item.values()] if isinstance(item, dict) else item)


def fail(location, rule, message):
    errors.append(f"FAIL {location}: rule {rule}: {message}")


def permissions_readonly(value):
    return isinstance(value, dict) and all(
        key in {"contents", "pull-requests"} and access == "read"
        for key, access in value.items()
    )


def check_uses(step, location):
    uses = step.get("uses")
    if uses is None:
        return
    if not isinstance(uses, str):
        fail(location, 4, "uses must be an action or workflow reference")
        return
    action, _, ref = uses.rpartition("@")
    if uses.split("@", 1)[0].lower() == "actions/checkout":
        inputs = step.get("with", {})
        if not isinstance(inputs, dict) or inputs.get("persist-credentials") != "false":
            fail(location, 3, "actions/checkout requires persist-credentials: false")
    if not uses.lower().startswith(("./", "actions/", "ceralive/")):
        if not action or re.fullmatch(r"[0-9a-fA-F]{40}", ref) is None:
            fail(location, 4, "third-party uses requires a full 40-hex commit SHA")


directory = Path(sys.argv[1])
files = sorted(p for p in directory.iterdir() if p.suffix in {".yml", ".yaml"}) \
    if directory.is_dir() else []
if not files:
    fail(str(directory), "input", "no workflow YAML files found")
for path in files:
    try:
        # BaseLoader preserves 'on' and boolean-looking inputs as strings.
        workflow = yaml.load(path.read_text(), Loader=yaml.BaseLoader)
    except (OSError, yaml.YAMLError) as exc:
        fail(path.name, "input", f"cannot parse workflow ({type(exc).__name__})")
        continue
    if not isinstance(workflow, dict):
        fail(path.name, "input", "workflow must be a mapping")
        continue
    triggers = workflow.get("on", {})
    if not isinstance(triggers, (str, list, dict)):
        fail(path.name, "input", "on must be an event string, list or mapping")
        continue
    events = [triggers] if isinstance(triggers, str) else list(triggers)
    if not all(isinstance(event, str) for event in events):
        fail(path.name, "input", "event names must be strings")
        continue
    if FORBIDDEN_EVENTS.intersection(events):
        fail(path.name, 1, "forbidden workflow trigger")
    jobs = workflow.get("jobs")
    if not isinstance(jobs, dict) or not jobs:
        fail(path.name, "input", "jobs must be a nonempty mapping")
        continue
    shared = {key: value for key, value in workflow.items() if key != "jobs"}
    for name, job in jobs.items():
        location = f"{path.name} job {name}"
        if not isinstance(job, dict):
            fail(location, "input", "job must be a mapping")
            continue
        hosted = hosted_runner(job)
        if "pull_request" in events:
            if not hosted:
                fail(location, 2, "pull_request requires allowlisted GitHub-hosted runners")
            if "environment" in job:
                fail(location, 2, "pull_request cannot use an environment")
            if "uses" in job:
                fail(location, 2, "pull_request cannot call a reusable workflow")
            if any(SECRET.search(value) for value in strings([shared, job])):
                fail(location, 2, "pull_request cannot reference secrets")
            for scope in (workflow, job):
                if not permissions_readonly(scope.get("permissions", {})):
                    fail(location, 2, "pull_request permissions allow only contents: read "
                         "and pull-requests: read; id-token is forbidden")
        if "runs-on" in job:
            if not hosted and path.name not in RUNNER_FILES:
                fail(location, 5, "non-hosted runner outside the workflow file allowlist")
        elif "uses" not in job:
            fail(location, "input", "job requires runs-on or reusable workflow uses")
        check_uses(job, location)
        steps = job.get("steps", [])
        if not isinstance(steps, list):
            fail(location, "input", "steps must be a list")
            continue
        for index, step in enumerate(steps, 1):
            if not isinstance(step, dict):
                fail(location, "input", f"step {index} must be a mapping")
                continue
            check_uses(step, f"{location} step {index}")

if not errors and not os.environ.get("WORKFLOWS_DIR"):
    cases = (
        ("lowercase-dot", "${{ secrets.X }}"),
        ("lowercase-bracket", "${{ secrets['X'] }}"),
        ("lowercase-context", "${{ toJSON(secrets) }}"),
        ("mixed-dot", "${{ Secrets.X }}"),
        ("uppercase-dot", "${{ SECRETS.X }}"),
        ("mixed-bracket", "${{ Secrets['X'] }}"),
        ("mixed-context", "${{ toJSON(Secrets) }}"),
    )
    script = str(Path(sys.argv[2]).resolve())
    with tempfile.TemporaryDirectory(prefix="workflow-secrets-") as scratch:
        for name, expression in cases:
            Path(scratch, "secrets.yml").write_text(
                "on: pull_request\npermissions: {contents: read}\njobs:\n"
                "  shellcheck:\n    runs-on: ubuntu-latest\n    env:\n"
                f"      PROBE: {expression}\n    steps:\n      - run: echo checked\n"
            )
            check = subprocess.run(
                ["bash", script], env={**os.environ, "WORKFLOWS_DIR": scratch},
                capture_output=True, text=True, timeout=10, check=False,
            )
            expected = "secrets.yml job shellcheck: rule 2: pull_request cannot reference secrets"
            if (check.returncode != 1 or expected not in check.stderr
                    or "contract: PASS" in check.stdout):
                fail(f"secrets regression {name}", 2,
                     f"expected job shellcheck rejection with exit 1; got {check.returncode}")
            else:
                print(f"secrets regression {name}: rule 2, job shellcheck, exit 1")

for error in errors:
    print(error, file=sys.stderr)
if errors:
    print(f"workflow security contract: FAIL ({len(errors)} violations)", file=sys.stderr)
    sys.exit(1)
print(f"workflow security contract: PASS ({len(files)} workflows)")
PY
