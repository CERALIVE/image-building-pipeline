#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${ROOT}/tests/lib/assertions.sh"

guard() { bash "${ROOT}/ci/check-os-version-month.sh" "$@"; }

if guard 2026.11.1 2026.11 >/dev/null 2>&1; then ok 'version in the current month is accepted'
else bad 'version in the current month was refused'; fi

if guard 2026.10.103 2026.11 >"${ROOT}/.month-guard.log" 2>&1; then bad 'past-month version was accepted'
else ok 'past-month version is refused'; fi
grep -q 'not in the current month (2026.11)' "${ROOT}/.month-guard.log" \
  && ok 'refusal names the current month' || bad 'refusal does not name the current month'
rm -f -- "${ROOT}/.month-guard.log"

if guard 2026.1.1 2026.11 >/dev/null 2>&1; then bad 'month 1 was accepted as month 11'
else ok 'month match is exact, not a prefix'; fi

if guard 2025.11.1 2026.11 >/dev/null 2>&1; then bad 'previous-year version was accepted'
else ok 'previous-year version is refused'; fi

if guard latest 2026.11 >/dev/null 2>&1; then bad 'non-CalVer version was accepted'
else ok 'non-CalVer version is refused'; fi

if guard "$(date -u +%Y.%-m).1" >/dev/null 2>&1; then ok 'default clock accepts the current UTC month'
else bad 'default clock refused the current UTC month'; fi

python3 - "${ROOT}" <<'PY' && ok 'build and publish run the month guard' || bad 'workflows are not wired to the month guard'
import pathlib, sys, yaml
root = pathlib.Path(sys.argv[1])
release = yaml.safe_load((root / '.github/workflows/release-candidate-build.yml').read_text())
step = next(s for s in release['jobs']['candidate']['steps'] if s.get('name') == 'Resolve OS release version')
assert 'ci/check-os-version-month.sh "${version}"' in step['run']
publish = yaml.safe_load((root / '.github/workflows/publish-release.yml').read_text())
step = next(s for s in publish['jobs']['publish']['steps'] if s.get('name') == 'Validate dispatch and candidate provenance')
assert 'ci/check-os-version-month.sh "$VERSION"' in step['run']
PY

printf 'OS version month guard: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" == 0 ]]
