#!/usr/bin/env bash
#
# read-candidate-identity.sh — read the BOARD IDENTITY a candidate artifact set
# actually carries, so the flash tool can compare it against the board it was
# pointed at.
#
# This answers "which board is this image FOR", never "is this image trusted".
# Trust (CMS signature, keyring, GPT geometry, FIT payload hashes) stays in
# tests/preflash-verify.sh; duplicating it here would give two answers to one
# question. Consequently the bundle manifest is read WITHOUT verifying its
# signature — a candidate that fails the identity comparison is rejected before
# the preflash gate ever runs, and one that passes still has to clear it.
#
# Sources, all offline, no loop mount, no root:
#   board_id / fdtfile  <- cera_board.env on the FAT boot partition (mtools)
#   compatible          <- manifest.raucm inside the .raucb squashfs payload
#   *_sha256            <- sha256sum of the three artifacts
#
# Usage:
#   read-candidate-identity.sh --image <raw> --bundle <raucb> --loader <bin>
#                              [--gap-mb 16]
#
# Emits KEY=value on stdout and exits non-zero if any field cannot be read.
#
# shellcheck shell=bash

set -euo pipefail

image="" bundle="" loader="" gap_mb=16
while [[ $# -gt 0 ]]; do
  case "$1" in
    --image)  image="${2:-}"; shift 2 ;;
    --bundle) bundle="${2:-}"; shift 2 ;;
    --loader) loader="${2:-}"; shift 2 ;;
    --gap-mb) gap_mb="${2:-}"; shift 2 ;;
    -h|--help)
      sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

die() { printf 'read-candidate-identity: %s\n' "$*" >&2; exit 1; }

for pair in "image:${image}" "bundle:${bundle}" "loader:${loader}"; do
  [[ -n "${pair#*:}" ]] || { printf '--%s is required\n' "${pair%%:*}" >&2; exit 2; }
  [[ -f "${pair#*:}" ]] || die "${pair%%:*} not found: ${pair#*:}"
done
[[ "${gap_mb}" =~ ^[1-9][0-9]*$ ]] || { printf -- '--gap-mb must be a positive integer\n' >&2; exit 2; }

for tool in mtype unsquashfs sha256sum; do
  command -v "${tool}" >/dev/null 2>&1 || die "required tool not on PATH: ${tool}"
done

boot_off=$(( gap_mb * 1024 * 1024 ))
board_env="$(mtype -i "${image}@@${boot_off}" ::/cera_board.env 2>/dev/null || true)"
[[ -n "${board_env}" ]] \
  || die "no cera_board.env on the FAT boot partition at byte offset ${boot_off}"

candidate_board_id="$(sed -n 's/^board_id=//p' <<<"${board_env}" | head -1 | tr -d '\r')"
candidate_fdtfile="$(sed -n 's/^fdtfile=//p'  <<<"${board_env}" | head -1 | tr -d '\r')"
[[ -n "${candidate_board_id}" ]] || die "cera_board.env carries no board_id"
[[ -n "${candidate_fdtfile}" ]] || die "cera_board.env carries no fdtfile"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# The .raucb layout is <squashfs payload><CMS signature><8-byte big-endian
# signature length>; the same split lib/rauc-bundle-inspect.sh performs before it
# verifies. Reading the trailer is what makes the payload boundary knowable.
total="$(stat -c '%s' "${bundle}")"
trailer="$(tail -c 8 "${bundle}" | od -An -tx1 | tr -d ' \n')"
[[ "${trailer}" =~ ^[0-9a-f]{16}$ ]] || die "bundle has no readable signature-length trailer"
sig_len=$((16#${trailer}))
payload_len=$((total - 8 - sig_len))
(( payload_len > 0 && sig_len > 0 )) || die "bundle payload/signature extents are not sane"
head -c "${payload_len}" "${bundle}" >"${work}/payload.squashfs"
unsquashfs -no-progress -cat "${work}/payload.squashfs" manifest.raucm >"${work}/manifest.raucm" 2>/dev/null \
  || die "bundle payload has no readable manifest.raucm"
candidate_compatible="$(sed -n 's/^compatible=//p' "${work}/manifest.raucm" | head -1)"
[[ -n "${candidate_compatible}" ]] || die "bundle manifest carries no compatible="

printf 'candidate_board_id=%s\n'      "${candidate_board_id}"
printf 'candidate_fdtfile=%s\n'       "${candidate_fdtfile}"
printf 'candidate_compatible=%s\n'    "${candidate_compatible}"
printf 'candidate_raw_sha256=%s\n'    "$(sha256sum "${image}"  | cut -d' ' -f1)"
printf 'candidate_bundle_sha256=%s\n' "$(sha256sum "${bundle}" | cut -d' ' -f1)"
printf 'candidate_loader_sha256=%s\n' "$(sha256sum "${loader}" | cut -d' ' -f1)"
