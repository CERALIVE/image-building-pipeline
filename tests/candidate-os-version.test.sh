#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${ROOT}/tests/lib/assertions.sh"
WORK="$(mktemp -d)"
trap 'rm -rf -- "${WORK}"' EXIT

guard() { bash "${ROOT}/ci/check-candidate-os-version.sh" "$@"; }
stamp() { mkdir -p "${WORK}/$1"; printf '%s\n' "$2" >"${WORK}/$1/os-release-version"; }

stamp match 2026.10.103
if guard "${WORK}/match" 2026.10.103 >/dev/null 2>&1; then ok 'candidate baking the requested version is accepted'
else bad 'candidate baking the requested version was refused'; fi

stamp mismatch 2026.10.101
if guard "${WORK}/mismatch" 2026.10.102 >"${WORK}/mismatch.log" 2>&1; then bad 'candidate baking a different version was accepted'
else ok 'candidate baking a different version is refused'; fi
grep -q 'bakes OS version 2026.10.101 but 2026.10.102 was requested' "${WORK}/mismatch.log" \
  && ok 'refusal names both versions' || bad 'refusal does not name both versions'

mkdir -p "${WORK}/absent"
if guard "${WORK}/absent" 2026.10.102 >/dev/null 2>&1; then bad 'candidate without a version stamp was accepted'
else ok 'candidate without a version stamp is refused'; fi

stamp malformed 'latest'
if guard "${WORK}/malformed" 2026.10.102 >/dev/null 2>&1; then bad 'candidate with a non-CalVer stamp was accepted'
else ok 'candidate with a non-CalVer stamp is refused'; fi

python3 - "${ROOT}" <<'PY' && ok 'build writes the stamp and publish runs the guard' || bad 'workflows are not wired to the guard'
import pathlib, sys, yaml
root = pathlib.Path(sys.argv[1])
release = yaml.safe_load((root / '.github/workflows/release-candidate-build.yml').read_text())
seal = next(s for s in release['jobs']['candidate']['steps'] if s.get('name') == 'Seal candidate metadata')
assert 'candidate/os-release-version' in seal['run'] and 'CERALIVE_OS_RELEASE_VERSION' in seal['run']
publish = yaml.safe_load((root / '.github/workflows/publish-release.yml').read_text())
step = next(s for s in publish['jobs']['publish']['steps'] if s.get('name') == 'Publish, promote, refresh, or prune')
assert 'ci/check-candidate-os-version.sh "$dir" "$VERSION"' in step['run']
PY

printf 'Candidate OS version guard: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" == 0 ]]
