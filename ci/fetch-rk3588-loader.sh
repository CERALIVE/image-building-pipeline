#!/usr/bin/env bash
set -euo pipefail

readonly LOADER_URL="https://dl.radxa.com/rock5/sw/images/loader/rk3588_spl_loader_v1.15.113.bin"
readonly LOADER_SHA256="26baab70e6b915364f7d73d88298366db1bfc346e34683e95d3d11b52492047f"

output="${1:-}"
[[ -n "${output}" ]] || { printf 'usage: %s OUTPUT\n' "$0" >&2; exit 2; }
output_dir="$(dirname -- "${output}")"
[[ -d "${output_dir}" && ! -L "${output}" && ! -d "${output}" ]] || {
  printf 'loader output must be a non-symlink path in an existing directory\n' >&2
  exit 1
}

tmp="$(mktemp "${output_dir}/.rk3588-loader.XXXXXX")"
trap 'rm -f -- "${tmp}"' EXIT
curl --fail --location --proto '=https' --tlsv1.2 --silent --show-error \
  "${LOADER_URL}" --output "${tmp}"
actual="$(sha256sum "${tmp}" | cut -d' ' -f1)"
[[ "${actual}" == "${LOADER_SHA256}" ]] || {
  printf 'RK3588 loader digest mismatch: expected %s, got %s\n' "${LOADER_SHA256}" "${actual}" >&2
  exit 1
}
chmod 0444 "${tmp}"
mv -f -- "${tmp}" "${output}"
trap - EXIT
printf '%s  %s\n' "${LOADER_SHA256}" "$(basename -- "${output}")"
