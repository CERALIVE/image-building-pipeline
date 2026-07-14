#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2="$(cd "${HERE}/.." && pwd)"
REPO="$(cd "${V2}/.." && pwd)"
WORKFLOW="${WORKFLOW:-${REPO}/.github/workflows/release.yml}"
RELEASE_DOC="${REPO}/docs/RELEASE-PROCESS.md"
R2_PUBLISHER="${REPO}/v2/ci/publish-immutable-r2-pair.sh"

python3 - "${WORKFLOW}" <<'PY'
from pathlib import Path
import sys

import yaml

workflow_path = Path(sys.argv[1])
workflow = yaml.load(workflow_path.read_text(), Loader=yaml.BaseLoader)
candidate = workflow["jobs"]["candidate"]
steps = candidate["steps"]

assert candidate["runs-on"] == ["self-hosted", "ceralive-image-builder"]
assert workflow["permissions"]["contents"] == "read"
assert workflow["concurrency"]["cancel-in-progress"] == "false"
assert any(step.get("uses") == "actions/checkout@v7" for step in steps)
assert any(step.get("name") == "Materialize release trust inputs" for step in steps)
assert any(
    step.get("name") == "Build exact production candidate"
    and step.get("run") == "./v2/build rock-5b-plus"
    and step.get("env", {}).get("CERALIVE_BUILD_MODE") == "production"
    for step in steps
)
assert any(step.get("id") == "upload" and step.get("uses") == "actions/upload-artifact@v7" for step in steps)
assert candidate["outputs"]["artifact_name"].startswith("${{ steps.meta.outputs.")
assert candidate["outputs"]["artifact_digest"] == "sha256:${{ steps.upload.outputs.artifact-digest }}", (
    "BUG: upload-artifact emits bare hex but the real-HW consumer requires sha256:<hex>"
)

realhw = workflow["jobs"]["realhw"]
assert realhw["needs"] == "candidate"
assert realhw["uses"] == "./.github/workflows/realhw-job.yml"

print("release workflow baseline characterization: PASS")
print("candidate=production rock-5b-plus self-hosted builder")
print("realhw=required workflow_call after candidate")
print("artifact_upload=immutable candidate artifact")
PY

grep -Fq "test \"\${run_event}\" = push" "${RELEASE_DOC}" || {
  echo 'BUG: manual publication does not reject non-push workflow events' >&2
  exit 1
}
grep -Fq "[[ \"\${run_branch}\" == release/* || \"\${run_branch}\" == release-* ]]" "${RELEASE_DOC}" || {
  echo 'BUG: manual publication does not reject tag and non-release branch runs' >&2
  exit 1
}
grep -Fq "test \"\${run_workflow}\" = 'Release candidate real-HW gate'" "${RELEASE_DOC}" || {
  echo 'BUG: manual publication does not require the production release workflow' >&2
  exit 1
}
grep -Fq "actions/workflows/\${workflow_id}" "${RELEASE_DOC}" || {
  echo 'BUG: manual publication does not resolve the workflow identity by database ID' >&2
  exit 1
}
grep -Fq "test \"\${workflow_path}\" = '.github/workflows/release.yml'" "${RELEASE_DOC}" || {
  echo 'BUG: manual publication does not pin the release workflow file path' >&2
  exit 1
}
grep -Fq "compare/\${merge_sha}...master" "${RELEASE_DOC}" || {
  echo 'BUG: manual publication does not prove the candidate commit is merged to master' >&2
  exit 1
}
grep -Fq "realhw_artifact_name=\"realhw-\${board}-\${run_id}\"" "${RELEASE_DOC}" || {
  echo 'BUG: manual publication does not select the candidate-bound real-HW evidence' >&2
  exit 1
}
grep -Fq "grep -Fx \"artifact_digest=\${artifact_digest}\" \"\${identity}\"" "${RELEASE_DOC}" || {
  echo 'BUG: manual publication does not bind hardware identity to the candidate digest' >&2
  exit 1
}
grep -Fq "grep -Fx \"media_cid=\${expected_media_cid}\" \"\${identity}\"" "${RELEASE_DOC}" || {
  echo 'BUG: manual publication does not bind proof to the approved physical test medium' >&2
  exit 1
}
grep -Fq "grep -F 'RESULT: 4 PASS / 0 FAIL / 0 SKIP'" "${RELEASE_DOC}" || {
  echo 'BUG: manual publication does not inspect the successful physical acceptance record' >&2
  exit 1
}
grep -Fq "openssl x509 -in \"\${approved_root}\" -outform DER" "${RELEASE_DOC}" || {
  echo 'BUG: manual publication does not pin the candidate to an approved production root' >&2
  exit 1
}
grep -Fq "rauc info --keyring \"\${approved_root}\"" "${RELEASE_DOC}" || {
  echo 'BUG: manual publication verifies RAUC with an artifact-supplied root' >&2
  exit 1
}

[[ -x "${R2_PUBLISHER}" ]] || {
  echo 'BUG: immutable R2 pair publisher is missing or not executable' >&2
  exit 1
}

python3 - "${RELEASE_DOC}" <<'PY'
from pathlib import Path
import sys

runbook = Path(sys.argv[1]).read_text()
operator = runbook.index("### Operator steps (today, until this is automated)")
block_start = runbook.index("```bash", operator)
block_end = runbook.index("```", block_start + len("```bash"))
publication = runbook[block_start:block_end]
helper = publication.index('"${publisher}" \\')
for required in (
    'compare/${merge_sha}...master',
    'grep -Fx "artifact_digest=${artifact_digest}" "${identity}"',
    'grep -Fx "media_cid=${expected_media_cid}" "${identity}"',
    "grep -F 'RESULT: 4 PASS / 0 FAIL / 0 SKIP'",
    'rauc info --keyring "${approved_root}"',
    'sha256sum -c good.raucb.sha256',
    'git show "${merge_sha}:v2/ci/publish-immutable-r2-pair.sh"',
):
    assert publication.index(required) < helper, f"proof must precede R2 helper: {required}"
assert '--bundle "${bundle}" --sidecar "${sha}"' in publication[helper:]
assert 'GIT_NO_REPLACE_OBJECTS=1 git show' in publication[:helper]
assert '--expected-sha256 "${approved_bundle_sha}"' in publication[helper:]
assert '--bucket "${R2_BUCKET}" --endpoint "${R2_ENDPOINT}"' in publication[helper:]
assert '--bundle-key "bundles/${channel}/${board}/${release_name}"' in publication[helper:]
assert "aws s3api put-object" not in publication, (
    "BUG: untested inline R2 writes bypass the immutable pair helper"
)
assert 'actions: ["GetObject", "PutObject"]' in runbook
assert "paths.objectPaths" in runbook
assert "Do not use a long-lived or prefix-scoped publication token" in runbook
assert "session token" in runbook
assert "no `DeleteObject`" in runbook
print("manual immutable R2 publication contract: PASS")
PY

python3 - "${WORKFLOW}" <<'PY'
from pathlib import Path
import sys

import yaml

workflow_path = Path(sys.argv[1])
raw_workflow = workflow_path.read_text()
workflow = yaml.load(raw_workflow, Loader=yaml.BaseLoader)
candidate = workflow["jobs"]["candidate"]
steps = candidate["steps"]
job_env = candidate.get("env", {})
assert job_env, "candidate job is missing release cache metadata"
assert job_env.get("DOCKER_CONTEXT") == "default", (
    "BUG: production candidate can inherit the interactive Docker Desktop context"
)
assert job_env.get("CERALIVE_RESOURCE_MEMINFO_FILE") == "/proc/meminfo", (
    "BUG: production candidate can inherit a synthetic host-memory probe"
)

def step_index(predicate):
    return next(index for index, step in enumerate(steps) if predicate(step))

def require_guard(step):
    condition = step.get("if", "")
    assert "github.event_name == 'push'" in condition, step
    assert "github.ref" in condition, step

meta_index = step_index(lambda step: step.get("id") == "cache-meta")
resource_index = step_index(lambda step: step.get("name") == "Verify production builder resource budget")
setup_index = step_index(lambda step: step.get("uses") == "docker/setup-buildx-action@v4")
builder_index = step_index(lambda step: step.get("uses") == "docker/build-push-action@v7")
trust_index = step_index(lambda step: step.get("name") == "Materialize release trust inputs")
build_index = step_index(lambda step: step.get("name") == "Build exact production candidate")
restore_index = step_index(lambda step: step.get("uses") == "actions/cache/restore@v6")
save_index = step_index(lambda step: step.get("uses") == "actions/cache/save@v6")
bound_index = step_index(lambda step: step.get("name") == "Bound board-scoped mkosi cache")

assert meta_index < resource_index < setup_index < builder_index < trust_index < build_index
assert restore_index < trust_index < build_index < bound_index < save_index

resource_step = steps[resource_index]
assert resource_step.get("run") == "./v2/ci/check-builder-resources.sh", (
    "BUG: production candidate does not fail early on an unsafe daemon/resource budget"
)

setup = steps[setup_index]
builder = steps[builder_index]
builder_with = builder["with"]
assert builder_with["context"] == "v2/ci"
assert builder_with["file"] == "v2/ci/Dockerfile"
assert builder_with["load"] == "true"
assert "type=gha" in builder_with["cache-from"]
assert "type=gha" in builder_with["cache-to"]
assert "mode=min" in builder_with["cache-to"]
assert builder_with["cache-from"] == "type=gha,scope=${{ steps.cache-meta.outputs.builder_scope }}"
assert builder_with["cache-to"] == "type=gha,mode=min,scope=${{ steps.cache-meta.outputs.builder_scope }}"
assert "${{ steps.cache-meta.outputs.builder_source_key }}" in builder_with["labels"]
assert "${{ secrets." not in str(builder_with)
cache_meta = steps[meta_index]
cache_meta_env = cache_meta["env"]
assert "${{ github.repository }}" == cache_meta_env["REPOSITORY"]
assert "${{ runner.os }}" == cache_meta_env["RUNNER_OS_NAME"]
assert "${{ runner.arch }}" == cache_meta_env["RUNNER_ARCH_NAME"]
assert "hashFiles('v2/.mkosi-version')" in cache_meta_env["MKOSI_TOOL_KEY"]
assert "hashFiles('v2/build'" in cache_meta_env["MKOSI_SOURCE_KEY"]
assert "v2/lib/**/*.sh" in cache_meta_env["MKOSI_SOURCE_KEY"]
assert "v2/mkosi/**/*" in cache_meta_env["MKOSI_SOURCE_KEY"]
assert "hashFiles('v2/ci/Dockerfile'" in cache_meta_env["BUILDER_SOURCE_KEY"]
for key_fragment in ("REPOSITORY", "RUNNER_OS_NAME", "RUNNER_ARCH_NAME", "rock-5b-plus", "MKOSI_TOOL_KEY", "MKOSI_SOURCE_KEY"):
    assert key_fragment in cache_meta["run"]
assert "builder_scope=" in cache_meta["run"]
assert "builder_image=" in cache_meta["run"]
require_guard(setup)
require_guard(builder)

assert job_env["CERALIVE_MKOSI_CACHE_DIR"] == "v2/mkosi/cache/rock-5b-plus"
assert int(job_env["CERALIVE_MKOSI_CACHE_MAX_BYTES"]) < 10 * 1024**3

restore = steps[restore_index]
save = steps[save_index]
assert restore["with"]["path"] == "${{ env.CERALIVE_MKOSI_CACHE_DIR }}"
assert restore["with"]["key"] == "${{ steps.cache-meta.outputs.mkosi_key }}"
assert restore["with"]["restore-keys"] == "${{ steps.cache-meta.outputs.mkosi_restore_prefix }}"
assert save["with"]["path"] == "${{ env.CERALIVE_MKOSI_CACHE_DIR }}"
assert save["with"]["key"] == "${{ steps.cache-meta.outputs.mkosi_key }}"
require_guard(restore)
require_guard(save)

build_env = steps[build_index]["env"]
assert build_env["MKOSI_BUILDER_IMAGE"] == "${{ steps.cache-meta.outputs.builder_image }}"
assert "${{ secrets." not in str(job_env)
assert "${{ secrets." not in str(restore.get("with", {}))
assert "${{ secrets." not in str(save.get("with", {}))

meta_run = steps[step_index(lambda step: step.get("id") == "meta")]["run"]
assert 'ln "${raws[0]}" candidate/' in meta_run, (
    "BUG: candidate staging allocates a second multi-GiB raw image instead of a hard link"
)
assert 'cp "${raws[0]}"' not in meta_run
assert 'bundle_release_name="$(basename "${bundles[0]}")"' in meta_run, (
    "BUG: the sealed candidate loses the production bundle's publish filename"
)
assert '( cd candidate && sha256sum good.raucb > good.raucb.sha256 )' in meta_run, (
    "BUG: the hardware-tested bundle has no candidate-bound checksum sidecar"
)
assert 'candidate/release-bundle-name.txt' in meta_run, (
    "BUG: manual publication cannot recover the hardware-tested bundle's release name"
)
upload = steps[step_index(lambda step: step.get("id") == "upload")]
assert upload["with"].get("compression-level") == "6", (
    "BUG: sparse candidate transport compression is not explicit"
)

bound_run = steps[bound_index]["run"]
assert "du -sb" in bound_run
assert "CERALIVE_MKOSI_CACHE_MAX_BYTES" in bound_run
assert "docker run" in bound_run
assert "find" in bound_run and "rm -rf" in bound_run
assert "CACHE_UID" in bound_run and "CACHE_GID" in bound_run
assert "CACHE_MAX_BYTES" in bound_run
assert "chown -R" in bound_run
assert "final_bytes" in bound_run
assert "cache/rock-5b-plus" not in bound_run or "CERALIVE_MKOSI_CACHE_DIR" in bound_run

cache_paths = [
    step.get("with", {}).get("path", "")
    for step in steps
    if step.get("uses", "").startswith("actions/cache/")
]
assert cache_paths == ["${{ env.CERALIVE_MKOSI_CACHE_DIR }}"] * 2
assert all(token not in path.lower() for path in cache_paths for token in ("apt", "qemu", "images", "staging", "build/"))
assert "pull_request:" not in raw_workflow
assert all("continue-on-error" not in step for step in steps)
assert "continue-on-error" not in str(workflow["jobs"]["realhw"])

print("release workflow cache contract: PASS")
PY
