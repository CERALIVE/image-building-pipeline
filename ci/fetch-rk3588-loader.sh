#!/usr/bin/env bash
#
# fetch-rk3588-loader.sh — download the MaskROM recovery loader for ONE board,
# verified against a committed SHA-256, and print its identity.
#
# WHY THIS IS A PER-BOARD TABLE AND NOT ONE CONSTANT. The loader's first stage is
# the DDR initialiser the BootROM runs before any of the board's own boot chain,
# so it is matched to the memory topology of a specific board, not to the SoC.
# The Radxa-published loader below is Rock-specific; an Orange Pi 5 Plus was
# empirically matched to a DIFFERENT artifact by comparing the DDR build hash the
# running board reports in `androidboot.fwver` (`ddr-v1.16-9fffbe1e78`) against
# the string embedded in each candidate loader — the OPi's own running first
# stage IS the one pinned here, which is a stronger board match than provenance
# alone. Recording one board's loader digest beside another board's artifact is
# not a cosmetic error: the loader is the recovery path an operator reaches for
# when a candidate has already bricked the board.
#
# Usage:
#   fetch-rk3588-loader.sh [--board <board-id>] OUTPUT   # download + verify
#   fetch-rk3588-loader.sh --print-identity <board-id>   # name<TAB>sha256<TAB>url
#   fetch-rk3588-loader.sh --print-sha256   <board-id>
#
# --board defaults to rock-5b-plus so every existing caller (release.yml, the
# bench flash gate) keeps its exact previous behaviour.
set -euo pipefail

readonly DEFAULT_BOARD="rock-5b-plus"

# board_id -> filename | sha256 | url
loader_entry() {
  case "$1" in
    rock-5b-plus)
      printf '%s\t%s\t%s\n' \
        'rk3588_spl_loader_v1.15.113.bin' \
        '26baab70e6b915364f7d73d88298366db1bfc346e34683e95d3d11b52492047f' \
        'https://dl.radxa.com/rock5/sw/images/loader/rk3588_spl_loader_v1.15.113.bin'
      ;;
    orange-pi-5-plus)
      printf '%s\t%s\t%s\n' \
        'rk3588_spl_loader_v1.16.113.bin' \
        '4cc43c2ff29e08b5491b4d52528346aa7da6948128c17e670ff8a000029c9408' \
        'https://raw.githubusercontent.com/armbian/rkbin/master/rk35/rk3588_spl_loader_v1.16.113.bin'
      ;;
    *) return 1 ;;
  esac
}

usage() {
  printf 'usage: %s [--board <board-id>] OUTPUT\n       %s --print-identity|--print-sha256 <board-id>\n' \
    "$0" "$0" >&2
}

board="${DEFAULT_BOARD}"
output=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --board) board="${2:-}"; shift 2 ;;
    --print-identity)
      loader_entry "${2:-}" || { printf 'no recovery loader is pinned for board %s\n' "${2:-}" >&2; exit 2; }
      exit 0 ;;
    --print-sha256)
      loader_entry "${2:-}" | cut -f2 \
        || { printf 'no recovery loader is pinned for board %s\n' "${2:-}" >&2; exit 2; }
      exit 0 ;;
    -h|--help) usage; exit 0 ;;
    -*) usage; exit 2 ;;
    *) output="$1"; shift ;;
  esac
done

[[ -n "${output}" ]] || { usage; exit 2; }
entry="$(loader_entry "${board}")" \
  || { printf 'no recovery loader is pinned for board %s\n' "${board}" >&2; exit 2; }
IFS=$'\t' read -r loader_name loader_sha256 loader_url <<<"${entry}"

output_dir="$(dirname -- "${output}")"
[[ -d "${output_dir}" && ! -L "${output}" && ! -d "${output}" ]] || {
  printf 'loader output must be a non-symlink path in an existing directory\n' >&2
  exit 1
}

tmp="$(mktemp "${output_dir}/.rk3588-loader.XXXXXX")"
trap 'rm -f -- "${tmp}"' EXIT
curl --fail --location --proto '=https' --tlsv1.2 --silent --show-error \
  "${loader_url}" --output "${tmp}"
actual="$(sha256sum "${tmp}" | cut -d' ' -f1)"
[[ "${actual}" == "${loader_sha256}" ]] || {
  printf 'RK3588 loader digest mismatch (%s, %s): expected %s, got %s\n' \
    "${board}" "${loader_name}" "${loader_sha256}" "${actual}" >&2
  exit 1
}
chmod 0444 "${tmp}"
mv -f -- "${tmp}" "${output}"
trap - EXIT
printf '%s  %s\n' "${loader_sha256}" "$(basename -- "${output}")"
