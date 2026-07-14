#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2="$(cd "${HERE}/.." && pwd)"
PUBLISH="${V2}/ci/publish-immutable-r2-pair.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

[[ -x "${PUBLISH}" ]] || { printf 'publisher is missing or not executable\n' >&2; exit 1; }
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
key= body= metadata= output=
while [[ $# -gt 0 ]]; do
  case "$1" in
    --key) key="$2"; shift 2 ;;
    --body) body="$2"; shift 2 ;;
    --metadata) metadata="$2"; shift 2 ;;
    --bucket|--endpoint-url|--if-none-match|--content-md5|--content-type) shift 2 ;;
    *) output="$1"; shift ;;
  esac
done
object="${MOCK_R2_STATE}/objects/${key}"
token_file="${object}.token"
case "${operation}" in
  put-object)
    if [[ -e "${object}" ]]; then
      printf 'An error occurred (412) when calling PutObject: Precondition Failed\n' >&2
      exit 42
    fi
    mkdir -p "$(dirname "${object}")"
    cp "${body}" "${object}"
    printf '%s\n' "${metadata#publication-token=}" >"${token_file}"
    [[ "${MOCK_ACCEPT_THEN_FAIL_KEY:-}" != "${key}" ]] || exit 99
    printf '{}\n'
    ;;
  head-object)
    if [[ "${MOCK_HEAD_ERROR_KEY:-}" == "${key}" ]]; then
      printf 'An error occurred (403) when calling HeadObject: Forbidden\n' >&2
      exit 77
    fi
    if [[ "${MOCK_HEAD_MALFORMED_KEY:-}" == "${key}" ]]; then
      printf 'not-json\n'
      exit 0
    fi
    if [[ ! -e "${object}" ]]; then
      printf 'An error occurred (404) when calling HeadObject: Not Found\n' >&2
      exit 44
    fi
    printf '{"Metadata":{"publication-token":"%s"}}\n' "$(<"${token_file}")"
    ;;
  delete-object)
    if [[ "${MOCK_DELETE_FAIL_KEY:-}" == "${key}" ]]; then
      printf 'An error occurred (503) when calling DeleteObject: unavailable\n' >&2
      exit 66
    fi
    rm -f "${object}" "${token_file}"
    printf '{}\n'
    ;;
  get-object)
    [[ "${MOCK_GET_FAIL_KEY:-}" != "${key}" ]] || exit 88
    cp "${object}" "${output}"
    printf '{}\n'
    ;;
  *) exit 91 ;;
esac
MOCK
chmod +x "${TMP}/bin/aws"

release_name=20260714T010203Z.raucb
bundle_key="bundles/stable/rock-5b-plus/${release_name}"
sidecar_key="${bundle_key}.sha256"
printf 'signed-bundle-fixture\n' >"${TMP}/bundle"
printf '%s  %s\n' "$(sha256sum "${TMP}/bundle" | cut -d' ' -f1)" "${release_name}" >"${TMP}/sidecar"

reset_state() {
  rm -rf "${TMP}/state"
  mkdir -p "${TMP}/state"
}

run_publish() {
  env PATH="${TMP}/bin:/usr/bin:/bin" MOCK_R2_STATE="${TMP}/state" \
    MOCK_ACCEPT_THEN_FAIL_KEY="${MOCK_ACCEPT_THEN_FAIL_KEY:-}" \
    MOCK_HEAD_ERROR_KEY="${MOCK_HEAD_ERROR_KEY:-}" \
    MOCK_HEAD_MALFORMED_KEY="${MOCK_HEAD_MALFORMED_KEY:-}" \
    MOCK_DELETE_FAIL_KEY="${MOCK_DELETE_FAIL_KEY:-}" \
    MOCK_GET_FAIL_KEY="${MOCK_GET_FAIL_KEY:-}" \
    "${PUBLISH}" --bundle "${TMP}/bundle" --sidecar "${TMP}/sidecar" \
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
printf 'successful create-only pair and read-back: PASS\n'

reset_state
MOCK_ACCEPT_THEN_FAIL_KEY="${sidecar_key}"
expect_failure 'accepted sidecar then client failure cleans ownership token' ''
[[ ! -e "${TMP}/state/objects/${sidecar_key}" ]]
MOCK_ACCEPT_THEN_FAIL_KEY=

reset_state
MOCK_ACCEPT_THEN_FAIL_KEY="${bundle_key}"
expect_failure 'accepted bundle then client failure cleans both objects' ''
[[ ! -e "${TMP}/state/objects/${bundle_key}" && ! -e "${TMP}/state/objects/${sidecar_key}" ]]
MOCK_ACCEPT_THEN_FAIL_KEY=

reset_state
MOCK_GET_FAIL_KEY="${bundle_key}"
expect_failure 'read-back failure cleans unverified pair' ''
[[ ! -e "${TMP}/state/objects/${bundle_key}" && ! -e "${TMP}/state/objects/${sidecar_key}" ]]
MOCK_GET_FAIL_KEY=

reset_state
MOCK_ACCEPT_THEN_FAIL_KEY="${sidecar_key}"
MOCK_HEAD_ERROR_KEY="${sidecar_key}"
expect_failure 'metadata lookup uncertainty is explicit' 'R2 cleanup is uncertain'
[[ -e "${TMP}/state/objects/${sidecar_key}" ]]
MOCK_ACCEPT_THEN_FAIL_KEY=''
MOCK_HEAD_ERROR_KEY=''

reset_state
MOCK_ACCEPT_THEN_FAIL_KEY="${sidecar_key}"
MOCK_HEAD_MALFORMED_KEY="${sidecar_key}"
expect_failure 'malformed ownership metadata is explicit' 'R2 cleanup is uncertain'
[[ -e "${TMP}/state/objects/${sidecar_key}" ]]
MOCK_ACCEPT_THEN_FAIL_KEY=''
MOCK_HEAD_MALFORMED_KEY=''

reset_state
MOCK_ACCEPT_THEN_FAIL_KEY="${sidecar_key}"
MOCK_DELETE_FAIL_KEY="${sidecar_key}"
expect_failure 'delete failure is explicit' 'remove token-owned unverified R2 object manually'
[[ -e "${TMP}/state/objects/${sidecar_key}" ]]
MOCK_ACCEPT_THEN_FAIL_KEY=''
MOCK_DELETE_FAIL_KEY=''

reset_state
mkdir -p "$(dirname "${TMP}/state/objects/${sidecar_key}")"
printf 'foreign\n' >"${TMP}/state/objects/${sidecar_key}"
printf 'foreign-token\n' >"${TMP}/state/objects/${sidecar_key}.token"
expect_failure 'immutable-key collision does not overwrite or delete foreign object' 'Precondition Failed'
[[ "$(<"${TMP}/state/objects/${sidecar_key}")" == foreign ]]

reset_state
mkdir -p "$(dirname "${TMP}/state/objects/${bundle_key}")"
printf 'foreign\n' >"${TMP}/state/objects/${bundle_key}"
printf 'foreign-token\n' >"${TMP}/state/objects/${bundle_key}.token"
expect_failure 'bundle-key collision preserves foreign bundle and removes owned sidecar' 'Precondition Failed'
[[ "$(<"${TMP}/state/objects/${bundle_key}")" == foreign ]]
[[ ! -e "${TMP}/state/objects/${sidecar_key}" ]]

printf 'immutable R2 publication behavioral regression: PASS\n'
