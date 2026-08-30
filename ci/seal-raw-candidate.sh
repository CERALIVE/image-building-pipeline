#!/usr/bin/env bash
set -euo pipefail

raw=""
candidate_dir=""
raw_sidecar=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --raw) raw="${2:-}"; shift 2 ;;
    --candidate-dir) candidate_dir="${2:-}"; shift 2 ;;
    --raw-sha256) raw_sidecar="${2:-}"; shift 2 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[[ -n "${raw}" ]] || { printf '%s\n' '--raw is required' >&2; exit 2; }
[[ -n "${candidate_dir}" ]] || { printf '%s\n' '--candidate-dir is required' >&2; exit 2; }
[[ -f "${raw}" && ! -L "${raw}" ]] || {
  printf 'raw image must be a regular, non-symlink file: %s\n' "${raw}" >&2
  exit 1
}
for tool in date sha256sum stat xz; do
  command -v "${tool}" >/dev/null 2>&1 || {
    printf 'required tool not on PATH: %s\n' "${tool}" >&2
    exit 1
  }
done

level=6
threads=0

install -d -m 0755 "${candidate_dir}"
raw_name="$(basename -- "${raw}")"
compressed="${candidate_dir}/${raw_name}.xz"
compressed_tmp="${candidate_dir}/.${raw_name}.xz.tmp"
raw_sidecar="${raw_sidecar:-${candidate_dir}/raw.sha256}"
compressed_sidecar="${compressed}.sha256"
raw_sidecar_tmp="${candidate_dir}/.raw.sha256.tmp"
compressed_sidecar_tmp="${candidate_dir}/.${raw_name}.xz.sha256.tmp"

[[ -d "$(dirname -- "${raw_sidecar}")" ]] || {
  printf 'raw SHA-256 sidecar parent directory does not exist: %s\n' "${raw_sidecar}" >&2
  exit 1
}

for output in "${compressed}" "${compressed_tmp}" \
  "${raw_sidecar}" "${raw_sidecar_tmp}" "${compressed_sidecar}" \
  "${compressed_sidecar_tmp}"; do
  [[ ! -e "${output}" && ! -L "${output}" ]] || {
    printf 'refusing to replace existing candidate output: %s\n' "${output}" >&2
    exit 1
  }
done
sealed=0
cleanup() {
  rm -f -- "${compressed_tmp}" "${raw_sidecar_tmp}" "${compressed_sidecar_tmp}"
  if (( sealed == 0 )); then
    rm -f -- "${compressed}" "${raw_sidecar}" "${compressed_sidecar}"
  fi
}
trap cleanup EXIT

# Pin the opened inode so a pathname replacement cannot make the digest and XZ
# payload refer to different source files. An in-place mutation is caught by the
# decompression digest comparison below.
exec {raw_fd}<"${raw}"
raw_fd_path="/proc/self/fd/${raw_fd}"
[[ -f "${raw_fd_path}" ]] || {
  printf 'opened raw image is not a regular file: %s\n' "${raw}" >&2
  exit 1
}
raw_sha="$(sha256sum "${raw_fd_path}" | cut -d' ' -f1)"
raw_bytes="$(stat -Lc %s "${raw_fd_path}")"
started="$(date +%s)"
printf 'sealing %s with xz level=%s threads=%s\n' "${raw_name}" "${level}" "${threads}"
xz -T"${threads}" -"${level}" --check=crc64 --stdout -- "${raw_fd_path}" >"${compressed_tmp}"
roundtrip_sha="$(xz -dc -- "${compressed_tmp}" | sha256sum | cut -d' ' -f1)"
[[ "${roundtrip_sha}" == "${raw_sha}" ]] || {
  printf 'compressed raw round-trip digest mismatch: expected %s, got %s\n' \
    "${raw_sha}" "${roundtrip_sha}" >&2
  exit 1
}
printf '%s  %s\n' "${raw_sha}" "${raw_name}" >"${raw_sidecar_tmp}"
compressed_sha="$(sha256sum "${compressed_tmp}" | cut -d' ' -f1)"
printf '%s  %s\n' "${compressed_sha}" "$(basename -- "${compressed}")" \
  >"${compressed_sidecar_tmp}"
mv -- "${compressed_tmp}" "${compressed}"
mv -- "${raw_sidecar_tmp}" "${raw_sidecar}"
mv -- "${compressed_sidecar_tmp}" "${compressed_sidecar}"
sealed=1
compressed_bytes="$(stat -c %s "${compressed}")"
elapsed=$(( $(date +%s) - started ))
printf 'sealed raw_bytes=%s compressed_bytes=%s elapsed_seconds=%s\n' \
  "${raw_bytes}" "${compressed_bytes}" "${elapsed}"
