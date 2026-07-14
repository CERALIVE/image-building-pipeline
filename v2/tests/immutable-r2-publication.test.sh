#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2="$(cd "${HERE}/.." && pwd)"
PUBLISH="${PUBLISH:-${V2}/ci/publish-immutable-r2-pair.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

[[ -x "${PUBLISH}" ]] || { printf 'publisher is missing or not executable\n' >&2; exit 1; }
if grep -Fq 'delete-object' "${PUBLISH}"; then
  printf 'BUG: immutable publication helper contains a destructive delete path\n' >&2
  exit 1
fi
help_output="$("${PUBLISH}" --help)"
[[ "${help_output}" == *'--bundle FILE --sidecar FILE'* ]]
if bad_output="$("${PUBLISH}" --bundle /missing 2>&1)"; then
  printf 'BUG: incomplete arguments were accepted\n' >&2
  exit 1
fi
[[ "${bad_output}" == *'--sidecar is required'* ]]
printf 'CLI help and bad-input boundary: PASS\n'
mkdir -p "${TMP}/bin" "${TMP}/state"
cat >"${TMP}/bin/aws" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == s3api ]] || exit 90
operation="${2:-}"; shift 2
key= body= output=
while [[ $# -gt 0 ]]; do
  case "$1" in
    --key) key="$2"; shift 2 ;;
    --body) body="$2"; shift 2 ;;
    --bucket|--endpoint-url|--if-none-match|--content-md5|--content-type) shift 2 ;;
    *) output="$1"; shift ;;
  esac
done
object="${MOCK_R2_STATE}/objects/${key}"
case "${operation}" in
  put-object)
    if [[ "${MOCK_PUT_ERROR_KEY:-}" == "${key}" ]]; then
      printf 'An error occurred (403) when calling PutObject: Forbidden (request-id=412noise)\n' >&2
      exit 77
    fi
    if [[ "${MOCK_MUTATE_SOURCE_ON_PUT:-}" == 1 && ! -e "${MOCK_R2_STATE}/source-mutated" ]]; then
      printf 'replaced-after-snapshot\n' >"${MOCK_SOURCE_BUNDLE}"
      printf 'replaced-after-snapshot\n' >"${MOCK_SOURCE_SIDECAR}"
      : >"${MOCK_R2_STATE}/source-mutated"
    fi
    if [[ -e "${object}" ]]; then
      printf 'An error occurred (PreconditionFailed) when calling PutObject: At least one condition failed\n' >&2
      exit 42
    fi
    mkdir -p "$(dirname "${object}")"
    cp "${body}" "${object}"
    [[ "${MOCK_ACCEPT_THEN_FAIL_KEY:-}" != "${key}" ]] || exit 99
    printf '{}\n'
    ;;
  get-object)
    if [[ "${MOCK_GET_FAIL_KEY:-}" == "${key}" ]]; then
      printf 'An error occurred (503) when calling GetObject: unavailable\n' >&2
      exit 88
    fi
    if [[ "${MOCK_REPLACE_BEFORE_GET_KEY:-}" == "${key}" ]]; then
      cp "${MOCK_REPLACEMENT}" "${object}"
    fi
    cp "${object}" "${output}"
    chmod 0600 "${output}"
    printf '{}\n'
    ;;
  head-object|delete-object)
    printf 'unexpected mutating cleanup operation: %s\n' "${operation}" >&2
    exit 92
    ;;
  *) exit 91 ;;
esac
MOCK
chmod +x "${TMP}/bin/aws"
cat >"${TMP}/bin/cmp" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
files=()
for arg in "$@"; do
  [[ "${arg}" == -* ]] || files+=("${arg}")
done
if (( ${#files[@]} >= 2 )); then
  printf '%s %s\n' "$(stat -c '%a' "${files[0]}")" "$(stat -c '%a' "${files[1]}")" >>"${MOCK_MODE_LOG}"
fi
exec /usr/bin/cmp "$@"
MOCK
chmod +x "${TMP}/bin/cmp"

release_name=20260714T010203Z.raucb
bundle_key="bundles/stable/rock-5b-plus/${release_name}"
sidecar_key="${bundle_key}.sha256"
printf 'signed-bundle-fixture\n' >"${TMP}/bundle"
approved_sha="$(sha256sum "${TMP}/bundle" | cut -d' ' -f1)"
printf '%s  %s\n' "${approved_sha}" "${release_name}" >"${TMP}/sidecar"
cp "${TMP}/bundle" "${TMP}/approved-bundle"
cp "${TMP}/sidecar" "${TMP}/approved-sidecar"

reset_state() {
  rm -rf "${TMP}/state"
  mkdir -p "${TMP}/state"
  : >"${TMP}/compared-modes"
}

run_publish() {
  env PATH="${TMP}/bin:/usr/bin:/bin" MOCK_R2_STATE="${TMP}/state" \
    MOCK_ACCEPT_THEN_FAIL_KEY="${MOCK_ACCEPT_THEN_FAIL_KEY:-}" \
    MOCK_PUT_ERROR_KEY="${MOCK_PUT_ERROR_KEY:-}" \
    MOCK_GET_FAIL_KEY="${MOCK_GET_FAIL_KEY:-}" \
    MOCK_REPLACE_BEFORE_GET_KEY="${MOCK_REPLACE_BEFORE_GET_KEY:-}" \
    MOCK_REPLACEMENT="${TMP}/replacement" \
    MOCK_MUTATE_SOURCE_ON_PUT="${MOCK_MUTATE_SOURCE_ON_PUT:-}" \
    MOCK_SOURCE_BUNDLE="${TMP}/bundle" MOCK_SOURCE_SIDECAR="${TMP}/sidecar" \
    MOCK_MODE_LOG="${TMP}/compared-modes" \
    "${PUBLISH}" --bundle "${TMP}/bundle" --sidecar "${TMP}/sidecar" \
      --expected-sha256 "${EXPECTED_SHA256:-${approved_sha}}" \
      --bucket releases --endpoint https://r2.invalid --bundle-key "${bundle_key}" 2>&1
}

expect_failure() {
  local label="$1" expected="$2" output
  if output="$(run_publish)"; then
    printf 'BUG: %s unexpectedly succeeded\n%s\n' "${label}" "${output}" >&2
    exit 1
  fi
  [[ "${output}" == *"${expected}"* ]] || {
    printf 'BUG: %s lacked diagnostic %q\n%s\n' "${label}" "${expected}" "${output}" >&2
    exit 1
  }
  printf '%s: PASS\n' "${label}"
}

reset_state
output="$(run_publish)"
[[ "${output}" == *'immutable R2 bundle pair verified'* ]]
[[ -f "${TMP}/state/objects/${bundle_key}" && -f "${TMP}/state/objects/${sidecar_key}" ]]
[[ -s "${TMP}/compared-modes" ]]
if grep -Ev '^400 400$' "${TMP}/compared-modes"; then
  printf 'BUG: publication compared a writable snapshot or readback\n' >&2
  exit 1
fi
printf 'successful create-only pair and read-back: PASS\n'

reset_state
printf 'unapproved-pre-invocation-replacement\n' >"${TMP}/bundle"
replacement_sha="$(sha256sum "${TMP}/bundle" | cut -d' ' -f1)"
printf '%s  %s\n' "${replacement_sha}" "${release_name}" >"${TMP}/sidecar"
expect_failure 'pre-invocation replacement is rejected by approved digest' \
  'bundle snapshot does not match the approved candidate SHA-256'
[[ ! -e "${TMP}/state/objects/${bundle_key}" && ! -e "${TMP}/state/objects/${sidecar_key}" ]]
cp "${TMP}/approved-bundle" "${TMP}/bundle"
cp "${TMP}/approved-sidecar" "${TMP}/sidecar"

reset_state
MOCK_MUTATE_SOURCE_ON_PUT=1
output="$(run_publish)"
[[ "${output}" == *'immutable R2 bundle pair verified'* ]]
cmp "${TMP}/approved-bundle" "${TMP}/state/objects/${bundle_key}"
cmp "${TMP}/approved-sidecar" "${TMP}/state/objects/${sidecar_key}"
( cd "$(dirname "${TMP}/state/objects/${bundle_key}")" && sha256sum -c "${release_name}.sha256" >/dev/null )
MOCK_MUTATE_SOURCE_ON_PUT=
cp "${TMP}/approved-bundle" "${TMP}/bundle"
cp "${TMP}/approved-sidecar" "${TMP}/sidecar"
printf 'private snapshot prevents an inconsistent pair during caller mutation: PASS\n'

reset_state
EXPECTED_SHA256="$(printf '0%.0s' {1..64})"
expect_failure 'approved candidate digest mismatch is fatal' 'bundle snapshot does not match the approved candidate SHA-256'
[[ ! -e "${TMP}/state/objects/${sidecar_key}" ]]
EXPECTED_SHA256=

reset_state
MOCK_ACCEPT_THEN_FAIL_KEY="${sidecar_key}"
expect_failure 'accepted sidecar then client failure leaves exact immutable object' 'conditional R2 write failed'
cmp "${TMP}/sidecar" "${TMP}/state/objects/${sidecar_key}"
MOCK_ACCEPT_THEN_FAIL_KEY=
output="$(run_publish)"
[[ "${output}" == *'immutable R2 object already matches'* ]]
[[ -f "${TMP}/state/objects/${bundle_key}" ]]
printf 'accepted sidecar converges on retry: PASS\n'

reset_state
MOCK_ACCEPT_THEN_FAIL_KEY="${bundle_key}"
expect_failure 'accepted bundle then client failure leaves exact immutable pair' 'conditional R2 write failed'
cmp "${TMP}/bundle" "${TMP}/state/objects/${bundle_key}"
cmp "${TMP}/sidecar" "${TMP}/state/objects/${sidecar_key}"
MOCK_ACCEPT_THEN_FAIL_KEY=
output="$(run_publish)"
[[ "${output}" == *'immutable R2 bundle pair verified'* ]]
printf 'accepted bundle converges on retry: PASS\n'

reset_state
MOCK_GET_FAIL_KEY="${bundle_key}"
expect_failure 'read-back failure preserves exact immutable pair' 'GetObject: unavailable'
cmp "${TMP}/bundle" "${TMP}/state/objects/${bundle_key}"
cmp "${TMP}/sidecar" "${TMP}/state/objects/${sidecar_key}"
MOCK_GET_FAIL_KEY=
output="$(run_publish)"
[[ "${output}" == *'immutable R2 bundle pair verified'* ]]
printf 'read-back interruption converges on retry: PASS\n'

reset_state
mkdir -p "$(dirname "${TMP}/state/objects/${sidecar_key}")"
printf 'foreign\n' >"${TMP}/state/objects/${sidecar_key}"
expect_failure 'sidecar collision preserves foreign object' 'immutable R2 key exists with different bytes'
[[ "$(<"${TMP}/state/objects/${sidecar_key}")" == foreign ]]

reset_state
mkdir -p "$(dirname "${TMP}/state/objects/${bundle_key}")"
printf 'foreign\n' >"${TMP}/state/objects/${bundle_key}"
expect_failure 'bundle collision preserves foreign bundle and exact sidecar' 'immutable R2 key exists with different bytes'
[[ "$(<"${TMP}/state/objects/${bundle_key}")" == foreign ]]
cmp "${TMP}/sidecar" "${TMP}/state/objects/${sidecar_key}"

reset_state
mkdir -p "$(dirname "${TMP}/state/objects/${sidecar_key}")"
cp "${TMP}/sidecar" "${TMP}/state/objects/${sidecar_key}"
printf 'replacement\n' >"${TMP}/replacement"
MOCK_REPLACE_BEFORE_GET_KEY="${sidecar_key}"
expect_failure 'replacement race is detected without deletion' 'immutable R2 key exists with different bytes'
[[ "$(<"${TMP}/state/objects/${sidecar_key}")" == replacement ]]
MOCK_REPLACE_BEFORE_GET_KEY=

reset_state
MOCK_PUT_ERROR_KEY="${sidecar_key}"
expect_failure 'non-precondition write failure is explicit' 'conditional R2 write failed'
[[ ! -e "${TMP}/state/objects/${sidecar_key}" ]]
MOCK_PUT_ERROR_KEY=

reset_state
mkdir -p "$(dirname "${TMP}/state/objects/${sidecar_key}")"
cp "${TMP}/sidecar" "${TMP}/state/objects/${sidecar_key}"
MOCK_GET_FAIL_KEY="${sidecar_key}"
expect_failure 'collided object verification failure is explicit' 'cannot verify existing immutable R2 object'
cmp "${TMP}/sidecar" "${TMP}/state/objects/${sidecar_key}"
MOCK_GET_FAIL_KEY=

printf 'immutable R2 publication behavioral regression: PASS\n'
