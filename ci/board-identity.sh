#!/usr/bin/env bash
#
# board-identity.sh — the ONE board-derived identity reader for the bench
# flash/backup/drill tooling.
#
# WHY this exists: `ci/verify-and-flash-candidate.sh` used to hardcode
# `rock-5b-plus`, the RK3588 Maskrom VID/PID and (through the preflash gate) the
# Rock board DTB. A tool that is hardcoded to one board cannot reject a candidate
# built for a DIFFERENT board — which is the exact mistake that bricks a bench
# board and costs a Maskrom recovery. Every board-varying fact is now READ from
# `manifests/boards/<board>.yaml` + `manifests/families/<family>.yaml`.
#
# It is deliberately a tiny top-level-scalar YAML reader rather than a call into
# `lib/resolve.sh`: this library runs on an operator's bench box against a
# candidate artifact set, must not require python3/jsonschema, and needs exactly
# five scalars. A manifest that cannot supply them fails loudly.
#
# Usage:
#   source ci/board-identity.sh
#   board_identity_load rock-5b-plus [<manifests-dir>]
#   printf '%s\n' "${BOARD_IDENTITY_BOARD_ID}"
#
# Exported on success:
#   BOARD_IDENTITY_BOARD            manifest stem, e.g. rock-5b-plus
#   BOARD_IDENTITY_BOARD_ID         `board_id:` from the board manifest
#   BOARD_IDENTITY_FAMILY           `family:` from the board manifest
#   BOARD_IDENTITY_ARCH             `arch:` from the family manifest
#   BOARD_IDENTITY_DTB              `dtb_name:` (variant override applied)
#   BOARD_IDENTITY_COMPATIBLE       RAUC `compatible=` — ceralive-<board_id>
#   BOARD_IDENTITY_FLASH_TRANSPORT  maskrom-rkdeveloptool | unsupported
#   BOARD_IDENTITY_MASKROM_VID      e.g. 0x2207 (empty when unsupported)
#   BOARD_IDENTITY_MASKROM_PID      e.g. 0x350b (empty when unsupported)
#   BOARD_IDENTITY_VARIANT          the resolved variant name (default: default)
#
# shellcheck shell=bash

BOARD_IDENTITY_BOARD=""
BOARD_IDENTITY_BOARD_ID=""
BOARD_IDENTITY_FAMILY=""
BOARD_IDENTITY_ARCH=""
BOARD_IDENTITY_DTB=""
BOARD_IDENTITY_COMPATIBLE=""
BOARD_IDENTITY_FLASH_TRANSPORT=""
BOARD_IDENTITY_MASKROM_VID=""
BOARD_IDENTITY_MASKROM_PID=""
BOARD_IDENTITY_VARIANT=""

# The whole-media Maskrom transport is a FAMILY fact, not a board fact: every
# rk3588 board enumerates as the same RK3588 BootROM device. A family absent from
# this table has no sanctioned destructive whole-media transport in this tool and
# is refused rather than defaulted — the x86 family boots UEFI and is flashed by
# an entirely different path.
board_identity_family_transport() {
  case "$1" in
    rk3588) printf 'maskrom-rkdeveloptool 0x2207 0x350b\n' ;;
    *)      printf 'unsupported  \n' ;;
  esac
}

# board_identity_scalar <file> <key> — read a TOP-LEVEL `key: value` scalar.
# Column-one keys only, so a nested `dtb_name:` under `variant_overrides:` can
# never be mistaken for the board default. Quotes and inline comments stripped.
board_identity_scalar() {
  local file="$1" key="$2" value
  value="$(sed -nE "s/^${key}:[[:space:]]*(.*)$/\\1/p" "${file}" | head -1)"
  value="${value%%#*}"
  value="${value%"${value##*[![:space:]]}"}"
  value="${value#\"}"; value="${value%\"}"
  value="${value#\'}"; value="${value%\'}"
  printf '%s\n' "${value}"
}

# board_identity_variant_dtb <file> <variant> — read
# variant_overrides.<variant>.dtb_name, or nothing. The override is the only key
# a board may restate per variant (see the pipeline AGENTS.md variant contract),
# so this reader deliberately understands exactly that one path.
board_identity_variant_dtb() {
  local file="$1" variant="$2"
  [[ -n "${variant}" && "${variant}" != default ]] || return 0
  awk -v want="${variant}" '
    /^variant_overrides:[[:space:]]*$/ { in_block = 1; next }
    in_block && /^[^[:space:]#]/       { in_block = 0 }
    in_block && $0 ~ "^  " want ":[[:space:]]*$" { in_variant = 1; next }
    in_block && in_variant && /^  [^[:space:]]/  { in_variant = 0 }
    in_block && in_variant && /^    dtb_name:/ {
      sub(/^    dtb_name:[[:space:]]*/, "")
      sub(/[[:space:]]*#.*$/, "")
      print
      exit
    }
  ' "${file}"
}

board_identity_fail() {
  printf 'board-identity: %s\n' "$*" >&2
  return 1
}

# board_identity_load <board> [manifests-dir] [variant]
board_identity_load() {
  local board="$1" manifests="${2:-}" variant="${3:-default}"
  local here board_file family_file transport override

  [[ "${board}" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
    || { board_identity_fail "board name is not a manifest stem: '${board}'"; return 1; }
  if [[ -z "${manifests}" ]]; then
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    manifests="${here}/../manifests"
  fi
  [[ -d "${manifests}/boards" ]] \
    || { board_identity_fail "no board manifests under ${manifests}"; return 1; }

  board_file="${manifests}/boards/${board}.yaml"
  [[ -f "${board_file}" ]] || {
    board_identity_fail "unknown board '${board}'; available: $(
      find "${manifests}/boards" -maxdepth 1 -name '*.yaml' -printf '%f\n' 2>/dev/null \
        | sed 's/\.yaml$//' | sort | tr '\n' ' ')"
    return 1
  }

  BOARD_IDENTITY_BOARD="${board}"
  BOARD_IDENTITY_VARIANT="${variant}"
  BOARD_IDENTITY_BOARD_ID="$(board_identity_scalar "${board_file}" board_id)"
  BOARD_IDENTITY_FAMILY="$(board_identity_scalar "${board_file}" family)"
  BOARD_IDENTITY_DTB="$(board_identity_scalar "${board_file}" dtb_name)"
  override="$(board_identity_variant_dtb "${board_file}" "${variant}")"
  [[ -z "${override}" ]] || BOARD_IDENTITY_DTB="${override}"

  [[ -n "${BOARD_IDENTITY_BOARD_ID}" ]] \
    || { board_identity_fail "${board}: board_id is missing"; return 1; }
  [[ -n "${BOARD_IDENTITY_FAMILY}" ]] \
    || { board_identity_fail "${board}: family is missing"; return 1; }
  [[ -n "${BOARD_IDENTITY_DTB}" ]] \
    || { board_identity_fail "${board}: dtb_name is missing"; return 1; }
  # `none` is the schema's sentinel for a board with no device tree (x86). It is
  # accepted here and refused by board_identity_require_maskrom, which is the
  # check that actually gates a destructive whole-media flash.
  [[ "${BOARD_IDENTITY_DTB}" == *.dtb || "${BOARD_IDENTITY_DTB}" == none ]] \
    || { board_identity_fail "${board}: dtb_name '${BOARD_IDENTITY_DTB}' is neither a .dtb nor 'none'"; return 1; }

  family_file="${manifests}/families/${BOARD_IDENTITY_FAMILY}.yaml"
  [[ -f "${family_file}" ]] \
    || { board_identity_fail "${board}: unknown family '${BOARD_IDENTITY_FAMILY}'"; return 1; }
  BOARD_IDENTITY_ARCH="$(board_identity_scalar "${family_file}" arch)"
  [[ -n "${BOARD_IDENTITY_ARCH}" ]] \
    || { board_identity_fail "${BOARD_IDENTITY_FAMILY}: arch is missing"; return 1; }

  # The PRODUCER is lib/orchestrate.sh: `COMPATIBLE_STRING=ceralive-${BOARD_ID}`.
  # Deriving this from the manifest STEM instead would agree on rock-5b-plus and
  # silently disagree on orange-pi-5-plus (stem orange-pi-5-plus vs board_id
  # orangepi5-plus) — which is exactly the cross-board class this tooling exists
  # to catch, so it must be read from the same field the builder stamps.
  BOARD_IDENTITY_COMPATIBLE="ceralive-${BOARD_IDENTITY_BOARD_ID}"

  read -r transport BOARD_IDENTITY_MASKROM_VID BOARD_IDENTITY_MASKROM_PID \
    < <(board_identity_family_transport "${BOARD_IDENTITY_FAMILY}")
  BOARD_IDENTITY_FLASH_TRANSPORT="${transport}"
  return 0
}

# board_identity_require_maskrom — refuse a family with no whole-media transport.
board_identity_require_maskrom() {
  [[ "${BOARD_IDENTITY_FLASH_TRANSPORT}" == maskrom-rkdeveloptool ]] || {
    board_identity_fail \
      "family '${BOARD_IDENTITY_FAMILY}' has no Maskrom whole-media flash transport"
    return 1
  }
  [[ "${BOARD_IDENTITY_MASKROM_VID}" =~ ^0x[0-9a-f]{4}$ && \
     "${BOARD_IDENTITY_MASKROM_PID}" =~ ^0x[0-9a-f]{4}$ ]] || {
    board_identity_fail "family '${BOARD_IDENTITY_FAMILY}' has a malformed Maskrom USB identity"
    return 1
  }
}

board_identity_print() {
  printf 'board=%s\n' "${BOARD_IDENTITY_BOARD}"
  printf 'board_id=%s\n' "${BOARD_IDENTITY_BOARD_ID}"
  printf 'family=%s\n' "${BOARD_IDENTITY_FAMILY}"
  printf 'arch=%s\n' "${BOARD_IDENTITY_ARCH}"
  printf 'variant=%s\n' "${BOARD_IDENTITY_VARIANT}"
  printf 'dtb_name=%s\n' "${BOARD_IDENTITY_DTB}"
  printf 'compatible=%s\n' "${BOARD_IDENTITY_COMPATIBLE}"
  printf 'flash_transport=%s\n' "${BOARD_IDENTITY_FLASH_TRANSPORT}"
  printf 'maskrom_vid=%s\n' "${BOARD_IDENTITY_MASKROM_VID}"
  printf 'maskrom_pid=%s\n' "${BOARD_IDENTITY_MASKROM_PID}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  [[ $# -ge 1 ]] || { printf 'usage: board-identity.sh <board> [manifests-dir] [variant]\n' >&2; exit 2; }
  board_identity_load "$@"
  board_identity_print
fi
