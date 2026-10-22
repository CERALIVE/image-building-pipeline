#!/usr/bin/env bash
# Static contract complements the offline behavioural RAUC fetch tests.
set -uo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/assertions.sh
source "${repo}/tests/lib/assertions.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

check_retry_flags() {
  awk '
    /^[[:space:]]*#/ { next }
    {
      if (statement == "") start = FNR
      continued = sub(/\\$/, "")
      statement = statement " " $0
      if (continued) next
      if (statement ~ /(^|[[:space:];])curl[[:space:]]/ &&
          statement ~ /[[:space:]]--retry([[:space:]=]|$)/) {
        seen++
        if (statement !~ /[[:space:]]--retry-all-errors([[:space:];]|$)/) {
          printf "%s:%d: curl retry lacks --retry-all-errors\n", FILENAME, start
          failed = 1
        }
      }
      statement = ""
    }
    END { if (!seen) print "no curl retry calls scanned"; exit failed || !seen }
  ' "$@"
}

# Given the complete build module set, when retrying curl GETs are scanned,
# then every call must retry exit 56 as well as curl-default transient errors.
# Exclusions: none. All current retrying calls are idempotent GETs into -o files.
shopt -s globstar nullglob
files=("${repo}"/lib/**/*.sh "${repo}"/mkosi/customize/**/*.sh)
if check_retry_flags "${files[@]}"; then
  ok 'all build curl retries carry --retry-all-errors'
else
  bad 'a build curl retry omits --retry-all-errors'
fi

# Given each real flagged call in turn, when only its flag is removed in a
# scratch copy, then the same guard must reject that per-site mutant.
mutants=0
for file in "${files[@]}"; do
  while IFS=: read -r line _; do
    awk -v target="${line}" 'NR == target { sub(/--retry-all-errors/, "") } { print }' \
      "${file}" >"${work}/mutant.sh"
    if check_retry_flags "${work}/mutant.sh" >"${work}/diagnostic"; then
      bad "flag-removal mutant survived: ${file#"${repo}/"}:${line}"
    else
      ok "flag-removal mutant killed: ${file#"${repo}/"}:${line}"
    fi
    mutants=$((mutants + 1))
  done < <(grep -nE '^[[:space:]]*[^#].*curl .*--retry .*--retry-all-errors' "${file}")
done
if (( mutants > 0 )); then
  ok "non-vacuous per-site mutation sweep (${mutants} calls)"
else
  bad 'no flag-removal mutants exercised'
fi
printf ' RESULT: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
