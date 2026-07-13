#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2="$(cd "${HERE}/.." && pwd)"
REPO="$(cd "${V2}/.." && pwd)"
WORKFLOW="${WORKFLOW:-${REPO}/.github/workflows/release.yml}"

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

realhw = workflow["jobs"]["realhw"]
assert realhw["needs"] == "candidate"
assert realhw["uses"] == "./.github/workflows/realhw-job.yml"

print("release workflow baseline characterization: PASS")
print("candidate=production rock-5b-plus self-hosted builder")
print("realhw=required workflow_call after candidate")
print("artifact_upload=immutable candidate artifact")
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

def step_index(predicate):
    return next(index for index, step in enumerate(steps) if predicate(step))

def require_guard(step):
    condition = step.get("if", "")
    assert "github.event_name == 'push'" in condition, step
    assert "github.ref" in condition, step

meta_index = step_index(lambda step: step.get("id") == "cache-meta")
setup_index = step_index(lambda step: step.get("uses") == "docker/setup-buildx-action@v4")
builder_index = step_index(lambda step: step.get("uses") == "docker/build-push-action@v7")
trust_index = step_index(lambda step: step.get("name") == "Materialize release trust inputs")
build_index = step_index(lambda step: step.get("name") == "Build exact production candidate")
restore_index = step_index(lambda step: step.get("uses") == "actions/cache/restore@v6")
save_index = step_index(lambda step: step.get("uses") == "actions/cache/save@v6")
bound_index = step_index(lambda step: step.get("name") == "Bound board-scoped mkosi cache")

assert meta_index < setup_index < builder_index < trust_index < build_index
assert restore_index < trust_index < build_index < bound_index < save_index

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
