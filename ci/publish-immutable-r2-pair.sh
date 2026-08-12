#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf '%s\n' \
    'Usage: publish-immutable-r2-pair.sh --bundle FILE --sidecar FILE --expected-sha256 HEX' \
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
expected_sha256=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle) bundle="${2:-}"; shift 2 ;;
    --sidecar) sidecar="${2:-}"; shift 2 ;;
    --bucket) bucket="${2:-}"; shift 2 ;;
    --endpoint) endpoint="${2:-}"; shift 2 ;;
    --bundle-key) bundle_key="${2:-}"; shift 2 ;;
    --expected-sha256) expected_sha256="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

for name in bundle sidecar bucket endpoint bundle_key expected_sha256; do
  [[ -n "${!name}" ]] || die "--${name//_/-} is required"
done
[[ -f "${bundle}" && -f "${sidecar}" ]] || die 'bundle and sidecar must be regular files'
[[ "${expected_sha256}" =~ ^[0-9a-f]{64}$ ]] || die 'expected SHA-256 must be 64 lowercase hex characters'
[[ "${bundle_key}" =~ ^bundles/[a-z0-9._-]+/[a-z0-9._+-]+/[0-9]{8}T[0-9]{6}Z\.raucb$ ]] \
  || die "bundle key is not a release bundle path: ${bundle_key}"
command -v aws >/dev/null 2>&1 || die 'aws CLI is required'
command -v openssl >/dev/null 2>&1 || die 'openssl is required'

umask 077
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
bundle_snapshot="${tmp}/approved-input.raucb"
sidecar_snapshot="${tmp}/approved-input.raucb.sha256"
cp --reflink=auto --sparse=always -- "${bundle}" "${bundle_snapshot}"
cp -- "${sidecar}" "${sidecar_snapshot}"
chmod 0400 "${bundle_snapshot}" "${sidecar_snapshot}"

release_name="$(basename -- "${bundle_key}")"
mapfile -t sidecar_lines <"${sidecar_snapshot}"
(( ${#sidecar_lines[@]} == 1 )) || die 'sidecar must contain exactly one checksum record'
read -r sidecar_sha expected_name extra <<<"${sidecar_lines[0]}"
[[ "${sidecar_sha}" =~ ^[0-9a-f]{64}$ && "${expected_name}" == "${release_name}" && -z "${extra:-}" ]] \
  || die 'sidecar does not bind the requested release filename and SHA-256'
actual_sha="$(sha256sum "${bundle_snapshot}" | cut -d' ' -f1)"
[[ "${actual_sha}" == "${sidecar_sha}" ]] || die 'sidecar SHA-256 does not match the bundle snapshot'
[[ "${actual_sha}" == "${expected_sha256}" ]] || die 'bundle snapshot does not match the approved candidate SHA-256'

sidecar_key="${bundle_key}.sha256"

bundle_md5="$(openssl dgst -md5 -binary "${bundle_snapshot}" | base64 -w0)"
sidecar_md5="$(openssl dgst -md5 -binary "${sidecar_snapshot}" | base64 -w0)"

put_or_verify() {
  local key="$1" body="$2" content_md5="$3" content_type="$4"
  local error_file="${tmp}/put-error" existing="${tmp}/existing-object"

  if aws s3api put-object --bucket "${bucket}" --key "${key}" --body "${body}" \
    --endpoint-url "${endpoint}" --if-none-match '*' --content-md5 "${content_md5}" \
    --content-type "${content_type}" >/dev/null 2>"${error_file}"; then
    return 0
  fi
  if ! grep -Eq '(\((412|PreconditionFailed)\)|Precondition Failed)' "${error_file}"; then
    printf 'ERROR: conditional R2 write failed for %s: %s\n' \
      "${key}" "$(tr '\n' ' ' <"${error_file}")" >&2
    return 1
  fi
  rm -f "${existing}"
  if ! aws s3api get-object --bucket "${bucket}" --key "${key}" \
    --endpoint-url "${endpoint}" "${existing}" >/dev/null 2>"${error_file}"; then
    printf 'ERROR: cannot verify existing immutable R2 object %s: %s\n' \
      "${key}" "$(tr '\n' ' ' <"${error_file}")" >&2
    return 1
  fi
  chmod 0400 "${existing}"
  if ! cmp -s "${body}" "${existing}"; then
    printf 'ERROR: immutable R2 key exists with different bytes: %s\n' "${key}" >&2
    return 1
  fi
  printf 'immutable R2 object already matches: s3://%s/%s\n' "${bucket}" "${key}"
}

# Sidecar-first means an interrupted second write never exposes a bundle without
# its checksum. Exact-byte collision recovery makes accepted writes retry-safe.
put_or_verify "${sidecar_key}" "${sidecar_snapshot}" "${sidecar_md5}" 'text/plain; charset=utf-8'
put_or_verify "${bundle_key}" "${bundle_snapshot}" "${bundle_md5}" application/vnd.rauc.bundle

aws s3api get-object --bucket "${bucket}" --key "${bundle_key}" \
  --endpoint-url "${endpoint}" "${tmp}/${release_name}" >/dev/null
chmod 0400 "${tmp}/${release_name}"
aws s3api get-object --bucket "${bucket}" --key "${sidecar_key}" \
  --endpoint-url "${endpoint}" "${tmp}/${release_name}.sha256" >/dev/null
chmod 0400 "${tmp}/${release_name}.sha256"
cmp "${bundle_snapshot}" "${tmp}/${release_name}"
cmp "${sidecar_snapshot}" "${tmp}/${release_name}.sha256"
( cd "${tmp}" && sha256sum -c "${release_name}.sha256" )
printf 'immutable R2 bundle pair verified: s3://%s/%s\n' "${bucket}" "${bundle_key}"
