#!/usr/bin/env bash
#
# generated-paths-contract.test.sh — the CI-declared generated paths must be the
# paths the build actually resolves, and the release cache keys must rotate when
# (and only when) a real build input changes.
#
# WHY THIS EXISTS: promoting the retired `v2` subtree to the repository root moved every generated
# path at once. The failure mode that move can produce is not a red build — it
# is a workflow that restores a cache into one directory while the build writes
# another, so every production candidate rebuilds from cold and nothing ever
# says so. The same class of drift also decides what a persistent runner is
# allowed to delete between jobs, which is why the cleanup ALLOWLIST is pinned
# here too rather than left as two hand-copied literals in the workflow.
#
# Run:  tests/generated-paths-contract.test.sh   (also wired into ./run-tests)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"
RELEASE_WORKFLOW="${RELEASE_WORKFLOW:-${PIPELINE_DIR}/.github/workflows/release.yml}"

fail() { echo "BUG: $*" >&2; exit 1; }

# --- 1. the emitter and the build agree, and the emitter is the only edge -----
emitted="$("${PIPELINE_DIR}/ci/emit-canonical-paths.sh" --board rock-5b-plus)"
for required in \
  'mkosi_dir=mkosi' \
  'mkosi_build_dir=mkosi/build' \
  'mkosi_cache_root=mkosi/cache' \
  'staging_dir=mkosi/.staging' \
  'kernel_ccache_dir=mkosi/cache/kernel-ccache' \
  'kernel_src_mirror_dir=mkosi/cache/kernel-src.git' \
  'images_dir=images' \
  'board_mkosi_cache_dir=mkosi/cache/rock-5b-plus' \
  'board_mkosi_cache_dir_container=mkosi/cache/rock-5b-plus/container' \
  'board_mkosi_cache_dir_native=mkosi/cache/rock-5b-plus/native'
do
  grep -Fqx "${required}" <<<"${emitted}" \
    || fail "emit-canonical-paths.sh does not emit '${required}'"
done

# The two privilege domains must be LEAVES of the board root, not siblings of it:
# release.yml saves and restores the board root, so a domain outside it would be
# a cache CI silently never persists.
board_root="$("${PIPELINE_DIR}/ci/emit-canonical-paths.sh" --board rock-5b-plus --get board_mkosi_cache_dir)"
for domain in container native; do
  leaf="$("${PIPELINE_DIR}/ci/emit-canonical-paths.sh" --board rock-5b-plus --get "board_mkosi_cache_dir_${domain}")"
  [[ "${leaf}" == "${board_root}/${domain}" ]] \
    || fail "the ${domain} mkosi cache '${leaf}' is not a leaf of the board root '${board_root}'"
done

# The kernel-source mirror is a SIBLING of the per-board caches, so a per-board
# wipe cannot reach it, and it is under the cache root the CI cleanup allowlist
# already covers.
mirror_dir="$("${PIPELINE_DIR}/ci/emit-canonical-paths.sh" --get kernel_src_mirror_dir)"
[[ "${mirror_dir}" == "$("${PIPELINE_DIR}/ci/emit-canonical-paths.sh" --get mkosi_cache_root)/"* ]] \
  || fail "the kernel source mirror '${mirror_dir}' is not under the mkosi cache root"
[[ "${mirror_dir}" != "${board_root}/"* ]] \
  || fail "the kernel source mirror '${mirror_dir}' sits under a per-board cache a board wipe would delete"

# The orchestrator, kernel builder and parallel runner must DERIVE, not restate.
grep -Fq 'source "${HERE}/paths.sh"' "${PIPELINE_DIR}/lib/orchestrate.sh" \
  || fail "orchestrate.sh does not source the canonical path definitions"
for pair in \
  'lib/orchestrate.sh:CERALIVE_REL_MKOSI_DIR' \
  'lib/orchestrate.sh:CERALIVE_REL_IMAGES_DIR' \
  'lib/orchestrate.sh:CERALIVE_REL_STAGING_DIR' \
  'lib/build-kernel.sh:CERALIVE_REL_KERNEL_CCACHE_DIR' \
  'lib/build-all.sh:CERALIVE_REL_LOGS_DIR'
do
  file="${pair%%:*}"; sym="${pair##*:}"
  grep -Fq "${sym}" "${PIPELINE_DIR}/${file}" \
    || fail "${file} restates a generated path instead of deriving ${sym}"
done

# The mkosi CLI cache flag is spelled relative to the mkosi CONFIG DIR, so it is
# the one place a bare `cache/<board>` is correct. Prove it composes onto the
# canonical repo-relative root rather than being an independent second literal.
mkosi_rel_cache="$(sed -n 's/^  local cache_dir="\(.*\)\/\${BOARD_ID}\/.*"$/\1/p' "${PIPELINE_DIR}/lib/orchestrate.sh")"
[[ -n "${mkosi_rel_cache}" ]] || fail "could not read the mkosi CLI cache dir out of orchestrate.sh"
canonical_root="$("${PIPELINE_DIR}/ci/emit-canonical-paths.sh" --get mkosi_cache_root)"
canonical_mkosi="$("${PIPELINE_DIR}/ci/emit-canonical-paths.sh" --get mkosi_dir)"
[[ "${canonical_mkosi}/${mkosi_rel_cache}" == "${canonical_root}" ]] \
  || fail "orchestrate.sh's mkosi cache dir '${mkosi_rel_cache}' does not compose onto '${canonical_root}'"

# --- 2. the workflow's declarations equal the build-resolved paths ------------
python3 - "${RELEASE_WORKFLOW}" "${PIPELINE_DIR}" <<'PY'
from pathlib import Path
import subprocess
import sys

import yaml

workflow_path, pipeline_dir = Path(sys.argv[1]), Path(sys.argv[2])
raw = workflow_path.read_text()
job = yaml.load(raw, Loader=yaml.BaseLoader)["jobs"]["candidate"]
env = job["env"]
steps = job["steps"]

cache_dir = env["CERALIVE_MKOSI_CACHE_DIR"]
cleanup = env["CERALIVE_GENERATED_CLEANUP_PATHS"]

# The workflow must submit its own declarations to the build-resolved check.
subprocess.run(
    [
        str(pipeline_dir / "ci/check-canonical-paths.sh"),
        "--board", "rock-5b-plus",
        "--cache-dir", cache_dir,
        "--cleanup", cleanup,
    ],
    check=True,
    stdout=subprocess.DEVNULL,
)

assert any(
    step.get("name") == "Assert canonical generated paths"
    and "ci/check-canonical-paths.sh" in step.get("run", "")
    for step in steps
), "BUG: the release workflow never proves its declared paths against the build"

# A declaration is only single-sourced if it appears exactly once.
assert raw.count(cache_dir) == 1, (
    f"BUG: the mkosi cache literal '{cache_dir}' is restated "
    f"{raw.count(cache_dir)} times in release.yml"
)
assert raw.count(f"CERALIVE_GENERATED_CLEANUP_PATHS: '{cleanup}'") == 1

# Cleanup deletes from that declaration, element by element — never a glob.
cleanup_steps = [s for s in steps if "CLEANUP_PATHS" in s.get("env", {})]
assert len(cleanup_steps) == 2, "BUG: expected a pre-checkout and a post-job cleanup step"
for step in cleanup_steps:
    run = step["run"]
    assert step["env"]["CLEANUP_PATHS"] == "${{ env.CERALIVE_GENERATED_CLEANUP_PATHS }}"
    assert 'rm -rf -- "${targets[@]}"' in run
    assert "refusing to delete non-literal path" in run, (
        "BUG: cleanup accepts a non-literal path"
    )
    assert "rm -rf -- /work\n" not in run and "rm -rf -- /work " not in run
    assert "*" not in run.split("rm -rf")[1].split("\n")[0]

print("release workflow generated-path contract: PASS")
PY

# --- 3. the cleanup allowlist actually refuses a widened path ----------------
if "${PIPELINE_DIR}/ci/check-canonical-paths.sh" --cleanup 'mkosi/build mkosi' >/dev/null 2>&1; then
  fail "the cleanup allowlist accepted a widened path"
fi
if "${PIPELINE_DIR}/ci/check-canonical-paths.sh" --cleanup 'mkosi/build mkosi/cache/*' >/dev/null 2>&1; then
  fail "the cleanup allowlist accepted a glob"
fi
if "${PIPELINE_DIR}/ci/check-canonical-paths.sh" --cleanup '/work' >/dev/null 2>&1; then
  fail "the cleanup allowlist accepted an absolute path"
fi
if "${PIPELINE_DIR}/ci/check-canonical-paths.sh" --board rock-5b-plus \
     --cache-dir 'mkosi/cache/not-the-board' >/dev/null 2>&1; then
  fail "the cache-dir check accepted a path the build never resolves"
fi

# --- 4. source-input changes rotate the mkosi cache key ----------------------
python3 - "${RELEASE_WORKFLOW}" "${PIPELINE_DIR}" <<'PY'
from pathlib import Path
import hashlib
import subprocess
import sys

import yaml

workflow_path, pipeline_dir = Path(sys.argv[1]), Path(sys.argv[2])
job = yaml.load(workflow_path.read_text(), Loader=yaml.BaseLoader)["jobs"]["candidate"]
meta = next(s for s in job["steps"] if s.get("id") == "cache-meta")
source_key_expr = meta["env"]["MKOSI_SOURCE_KEY"]

# The globs the release cache key is computed over, read out of the workflow so
# this test can never pass against a key that stopped covering a build input.
globs = [
    fragment.strip().strip("'")
    for fragment in source_key_expr.split("hashFiles(", 1)[1].rsplit(")", 1)[0].split(",")
]
assert globs == ["build", "lib/**/*.sh", "mkosi/**/*", "manifests/**/*", "ci/Dockerfile"], globs

tracked = subprocess.run(
    ["git", "-C", str(pipeline_dir), "ls-files"],
    capture_output=True, text=True, check=True,
).stdout.split()


def matches(rel: str) -> bool:
    for pattern in globs:
        if pattern.endswith("/**/*"):
            if rel.startswith(pattern[: -len("**/*")]):
                return True
        elif pattern == "lib/**/*.sh":
            if rel.startswith("lib/") and rel.endswith(".sh"):
                return True
        elif rel == pattern:
            return True
    return False


def hash_files(overrides: dict[str, bytes]) -> str:
    # GitHub's hashFiles(): sha256 over each matching file's sha256, in path order.
    outer = hashlib.sha256()
    for rel in sorted(r for r in tracked if matches(r)):
        if rel in overrides:
            payload = overrides[rel]
        else:
            payload = (pipeline_dir / rel).read_bytes()
        outer.update(hashlib.sha256(payload).hexdigest().encode())
    return outer.hexdigest()


baseline = hash_files({})

# A real build input changing MUST rotate the key…
for changed in ("build", "lib/orchestrate.sh", "mkosi/mkosi.conf", "ci/Dockerfile"):
    assert changed in tracked, changed
    mutated = hash_files({changed: (pipeline_dir / changed).read_bytes() + b"\n# rotate\n"})
    assert mutated != baseline, f"BUG: changing {changed} does not rotate the mkosi cache key"

# …and something outside the build inputs must NOT (non-vacuity: the key is a
# real filter, not a hash of the whole tree).
outsider = next(r for r in tracked if r.startswith("docs/"))
assert hash_files({outsider: b"unrelated"}) == baseline, (
    f"BUG: {outsider} is not a build input yet rotates the mkosi cache key"
)

# The builder image key must rotate on its own inputs, independently.
builder_expr = meta["env"]["BUILDER_SOURCE_KEY"]
for required in ("ci/Dockerfile", "ci/requirements-ci.txt", ".mkosi-version"):
    assert f"'{required}'" in builder_expr, (
        f"BUG: the builder cache key does not cover {required}"
    )

print("release cache-key rotation contract: PASS")
PY

echo "generated-paths contract: PASS"
