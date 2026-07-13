#!/usr/bin/env bash
#
# verify-disk.sh — Stage 4 disk-image CONTRACT VERIFIER for the CeraLive v2 pipeline.
#
# The partition/gap/label assertions that prove a produced disk image matches the
# FROZEN A/B layout (docs/partition-contract.md §3, contract v2). Extracted from
# assemble-disk.sh (task 6) so the checks live in one place, run STANDALONE, and so
# the assembler's build path can reuse part_field without duplicating it.
#
#   (16 MB raw gap, NO GPT entry)  idbloader + U-Boot + ATF
#   p1 boot      vfat   256 MB             PARTLABEL=boot
#   p2 rootfs_a  ext4   4096 MB            PARTLABEL=rootfs_a   (RAUC slot A)
#   p3 rootfs_b  ext4   4096 MB            PARTLABEL=rootfs_b   (RAUC slot B)  *
#   p4 data      ext4   remainder >=2048   PARTLABEL=data       (shared)
#     * rootfs_b is OMITTED in the single-slot fallback (3 partitions).
#
# Sizes are FROZEN. NEVER change without a fleet re-flash (docs/partition-contract.md).
#
# Usage:
#   verify-disk.sh do_verify <img> <board>
#
#   do_verify  Assert a PRE-BUILT disk image against the contract and exit non-zero
#              on the first failed assertion. The layout (A/B vs single-slot) is
#              discriminated by the GPT partition count — 4 == A/B, 3 == single-slot.
#              <board> is recorded for context only; the contract is board-invariant.
#
# This file is ALSO sourced by assemble-disk.sh, which calls do_verify directly and
# reuses part_field on its build path. When sourced, the standalone main() is skipped.
#
# shellcheck shell=bash

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${HERE}/common.sh"

# ---------------------------------------------------------------------------
# FROZEN contract constants (docs/partition-contract.md §3). Sizes in MB == MiB.
# Mirrors assemble-disk.sh so this verifier is fully self-contained / standalone.
# ---------------------------------------------------------------------------
SECTOR=512
GAP_MB=16            # raw idbloader+U-Boot+ATF region (no GPT entry)
BOOT_MB=256          # p1 boot (vfat)
ROOTFS_MB=4096       # p2/p3 rootfs slots (ext4)
DATA_FLOOR_MB=2048   # p4 data minimum (ext4, else remainder)
# Boot starts after the 16 MB gap: 16 MiB / 512 B = 32768 sectors.
BOOT_START_SECTOR=$(( GAP_MB * 1024 * 1024 / SECTOR ))

# ---------------------------------------------------------------------------
# part_field <img> <num> <First sector|Partition size|Partition name>
# Pull one field from `sgdisk -i`. Sizes/sectors returned as raw integers (sectors)
# for "First sector"/"Partition size"; the quoted label for "Partition name".
# ---------------------------------------------------------------------------
part_field() {
  local img="$1" num="$2" key="$3" line
  line="$(sgdisk -i "${num}" "${img}" 2>/dev/null | grep -F "${key}:")" || return 1
  case "${key}" in
    "Partition name")
      sed -E "s/.*: '([^']*)'.*/\1/" <<<"${line}" ;;
    *)  # "First sector: 32768 (at ...)" / "Partition size: 524288 sectors (...)"
      sed -E 's/[^0-9]*([0-9]+).*/\1/' <<<"${line}" ;;
  esac
}

# part_count <img> — number of partitions in the GPT.
part_count() { sgdisk --print "$1" 2>/dev/null | awk '/^[[:space:]]+[0-9]+[[:space:]]/{n++} END{print n+0}'; }

# sectors_to_mib <sectors>
sectors_to_mib() { echo $(( $1 * SECTOR / 1024 / 1024 )); }

# assert_part <img> <num> <expect_label> <expect_mib|min:N>
assert_part() {
  local img="$1" num="$2" exp_label="$3" exp_size="$4" label size_sectors size_mib
  label="$(part_field "${img}" "${num}" 'Partition name')" \
    || die "partition ${num} missing in ${img}"
  size_sectors="$(part_field "${img}" "${num}" 'Partition size')"
  size_mib="$(sectors_to_mib "${size_sectors}")"
  [[ "${label}" == "${exp_label}" ]] \
    || die "partition ${num} label '${label}' != expected '${exp_label}' (contract)"
  if [[ "${exp_size}" == min:* ]]; then
    local floor="${exp_size#min:}"
    (( size_mib >= floor )) \
      || die "partition ${num} (${label}) size ${size_mib} MiB < contract floor ${floor} MiB"
    printf '  p%s %-9s %6s MiB  (>= %s MiB floor) OK\n' "${num}" "${label}" "${size_mib}" "${floor}"
  else
    (( size_mib == exp_size )) \
      || die "partition ${num} (${label}) size ${size_mib} MiB != contract ${exp_size} MiB"
    printf '  p%s %-9s %6s MiB  (== contract) OK\n' "${num}" "${label}" "${size_mib}"
  fi
}

# assert_no_label <img> <label> — die if any partition carries <label>.
assert_no_label() {
  local img="$1" want="$2" n count
  count="$(part_count "${img}")"
  for (( n=1; n<=count; n++ )); do
    [[ "$(part_field "${img}" "${n}" 'Partition name')" != "${want}" ]] \
      || die "single-slot image MUST NOT contain a '${want}' partition"
  done
}

# assert_gap <img> — boot (p1) must start at the 16 MB sector (no GPT entry before).
assert_gap() {
  local img="$1" start
  start="$(part_field "${img}" 1 'First sector')"
  (( start == BOOT_START_SECTOR )) \
    || die "boot starts at sector ${start}, expected ${BOOT_START_SECTOR} (16 MB raw gap)"
  printf '  16 MB raw gap: boot starts at sector %s (== %s MiB, no GPT entry before) OK\n' \
    "${start}" "${GAP_MB}"
}

# ---------------------------------------------------------------------------
# do_verify <img> <board>
# Assert a PRE-BUILT disk image against the frozen contract. The layout is
# discriminated by GPT partition count: 4 == A/B (boot+rootfs_a+rootfs_b+data),
# 3 == single-slot (boot+rootfs_a+data, NO rootfs_b). <board> is recorded for
# context only — the contract is identical across boards. Dies on the first
# failed assertion (loud, non-zero exit).
# ---------------------------------------------------------------------------
do_verify() {
  local img="$1" board="${2:-}" count
  [[ -n "${img}" ]] || die "do_verify: <img> is required"
  [[ -f "${img}" ]] || die "do_verify: image not found: ${img}"
  count="$(part_count "${img}")"
  log_info "verifying ${img} (board=${board:-unspecified}, ${count} partitions)"
  echo "--- contract assertions ---"
  case "${count}" in
    4)
      echo "  partition count = 4 (boot + rootfs_a + rootfs_b + data) OK"
      assert_gap "${img}"
      assert_part "${img}" 1 boot     "${BOOT_MB}"
      assert_part "${img}" 2 rootfs_a "${ROOTFS_MB}"
      assert_part "${img}" 3 rootfs_b "${ROOTFS_MB}"
      assert_part "${img}" 4 data     "min:${DATA_FLOOR_MB}"
      ;;
    3)
      echo "  partition count = 3 (boot + rootfs_a + data) OK"
      assert_gap "${img}"
      assert_part "${img}" 1 boot     "${BOOT_MB}"
      assert_part "${img}" 2 rootfs_a "${ROOTFS_MB}"
      assert_part "${img}" 3 data     "min:${DATA_FLOOR_MB}"
      assert_no_label "${img}" rootfs_b
      echo "  rootfs_b ABSENT (single-slot fallback honored) OK"
      ;;
    *)
      die "unexpected partition count ${count} in ${img} (expected 4=A/B or 3=single-slot)"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# main — standalone entrypoint. Skipped when this file is sourced.
# ---------------------------------------------------------------------------
main() {
  local mode="${1:-}"; shift || true
  case "${mode}" in
    do_verify)
      do_verify "$@"
      ;;
    -h|--help|"")
      sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      ;;
    *) die "unknown mode '${mode}' (expected: do_verify)" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
