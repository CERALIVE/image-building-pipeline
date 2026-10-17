#!/usr/bin/env bash
# Sourced by both image publishers. Caller owns bucket, endpoint and private tmp.
# shellcheck disable=SC2154
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
