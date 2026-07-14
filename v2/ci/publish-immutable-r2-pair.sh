#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf '%s\n' \
    'Usage: publish-immutable-r2-pair.sh --bundle FILE --sidecar FILE' \
    '       --bucket NAME --endpoint URL --bundle-key bundles/CHANNEL/BOARD/TIMESTAMP.raucb'
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

bundle=''
sidecar=''
bucket=''
endpoint=''
bundle_key=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle) bundle="${2:-}"; shift 2 ;;
    --sidecar) sidecar="${2:-}"; shift 2 ;;
    --bucket) bucket="${2:-}"; shift 2 ;;
    --endpoint) endpoint="${2:-}"; shift 2 ;;
    --bundle-key) bundle_key="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

for name in bundle sidecar bucket endpoint bundle_key; do
  [[ -n "${!name}" ]] || die "--${name//_/-} is required"
done
[[ -f "${bundle}" && -f "${sidecar}" ]] || die 'bundle and sidecar must be regular files'
[[ "${bundle_key}" =~ ^bundles/[a-z0-9._-]+/[a-z0-9._+-]+/[0-9]{8}T[0-9]{6}Z\.raucb$ ]] \
  || die "bundle key is not a release bundle path: ${bundle_key}"
command -v aws >/dev/null 2>&1 || die 'aws CLI is required'
command -v jq >/dev/null 2>&1 || die 'jq is required'
command -v openssl >/dev/null 2>&1 || die 'openssl is required'

release_name="$(basename -- "${bundle_key}")"
mapfile -t sidecar_lines <"${sidecar}"
(( ${#sidecar_lines[@]} == 1 )) || die 'sidecar must contain exactly one checksum record'
read -r expected_sha expected_name extra <<<"${sidecar_lines[0]}"
[[ "${expected_sha}" =~ ^[0-9a-f]{64}$ && "${expected_name}" == "${release_name}" && -z "${extra:-}" ]] \
  || die 'sidecar does not bind the requested release filename and SHA-256'
actual_sha="$(sha256sum "${bundle}" | cut -d' ' -f1)"
[[ "${actual_sha}" == "${expected_sha}" ]] || die 'sidecar SHA-256 does not match the bundle'

tmp="$(mktemp -d)"
publication_token="$(openssl rand -hex 16)"
sidecar_key="${bundle_key}.sha256"
writes_started=0
pair_verified=0
cleanup_uncertain=0

cleanup_owned_object() {
  local key="$1" metadata owner_token error_file="${tmp}/head-error"
  if ! metadata="$(
    aws s3api head-object --bucket "${bucket}" --key "${key}" \
      --endpoint-url "${endpoint}" 2>"${error_file}"
  )"; then
    if grep -Eq '(404|NoSuchKey|Not Found)' "${error_file}"; then
      return 0
    fi
    printf 'ERROR: cannot determine cleanup ownership for %s: %s\n' \
      "${key}" "$(tr '\n' ' ' <"${error_file}")" >&2
    return 1
  fi
  if ! owner_token="$(
    jq -er '
      if type == "object" and (((.Metadata? // {}) | type) == "object") then
        (.Metadata? // {})["publication-token"] // ""
      else
        error("invalid head-object response")
      end
    ' <<<"${metadata}" 2>/dev/null
  )"; then
    printf 'ERROR: cannot parse cleanup ownership metadata for %s\n' "${key}" >&2
    return 1
  fi
  [[ "${owner_token}" == "${publication_token}" ]] || return 0
  if ! aws s3api delete-object --bucket "${bucket}" --key "${key}" \
    --endpoint-url "${endpoint}" >/dev/null 2>"${error_file}"; then
    printf 'ERROR: remove token-owned unverified R2 object manually: %s (%s)\n' \
      "${key}" "$(tr '\n' ' ' <"${error_file}")" >&2
    return 1
  fi
}

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  if (( writes_started == 1 && pair_verified == 0 )); then
    cleanup_owned_object "${bundle_key}" || cleanup_uncertain=1
    cleanup_owned_object "${sidecar_key}" || cleanup_uncertain=1
  fi
  rm -rf "${tmp}"
  if (( cleanup_uncertain == 1 )); then
    printf 'ERROR: R2 cleanup is uncertain; do not retry or register this release until reconciled\n' >&2
    (( rc != 0 )) || rc=1
  fi
  exit "${rc}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

bundle_md5="$(openssl dgst -md5 -binary "${bundle}" | base64 -w0)"
sidecar_md5="$(openssl dgst -md5 -binary "${sidecar}" | base64 -w0)"
writes_started=1

# Sidecar-first means an interrupted second write never exposes a bundle without
# its checksum. Conditional PUTs make release keys immutable.
aws s3api put-object --bucket "${bucket}" --key "${sidecar_key}" --body "${sidecar}" \
  --endpoint-url "${endpoint}" --if-none-match '*' --content-md5 "${sidecar_md5}" \
  --metadata "publication-token=${publication_token}" \
  --content-type 'text/plain; charset=utf-8' >/dev/null
aws s3api put-object --bucket "${bucket}" --key "${bundle_key}" --body "${bundle}" \
  --endpoint-url "${endpoint}" --if-none-match '*' --content-md5 "${bundle_md5}" \
  --metadata "publication-token=${publication_token}" \
  --content-type application/vnd.rauc.bundle >/dev/null

aws s3api get-object --bucket "${bucket}" --key "${bundle_key}" \
  --endpoint-url "${endpoint}" "${tmp}/${release_name}" >/dev/null
aws s3api get-object --bucket "${bucket}" --key "${sidecar_key}" \
  --endpoint-url "${endpoint}" "${tmp}/${release_name}.sha256" >/dev/null
cmp "${bundle}" "${tmp}/${release_name}"
cmp "${sidecar}" "${tmp}/${release_name}.sha256"
( cd "${tmp}" && sha256sum -c "${release_name}.sha256" )
pair_verified=1
printf 'immutable R2 bundle pair verified: s3://%s/%s\n' "${bucket}" "${bundle_key}"
