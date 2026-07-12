#!/usr/bin/env bash
#
# write-bootloader.sh — RK3588 raw-gap bootloader writer for the CeraLive v2
# disk assembler (Stage 4).
#
# Writes the board's U-Boot bootloader blob(s) into the 16 MB raw gap
# (sectors 0..32767, NO GPT entry) of an already-assembled GPT disk image, then
# verifies the Rockchip idblock magic "RKNS" landed at sector 64. The 16 MB gap
# is mandated by docs/partition-contract.md §2/§3; partition 1 (`boot`) starts at
# sector 32768, so every blob write below stays strictly before it — the GPT and
# all partitions are left untouched.
#
# FAMILY-GATED: this is the rauc_bootloader_adapter == `custom` (RK3588 vendor
# U-Boot, decision D3) path ONLY. x86 (`efi`) boots from an EFI System Partition
# and has NO raw idbloader gap — assemble-disk.sh never calls this for x86.
#
# Per-board blob layout — ground truth is the T1 spike (test-results/g3a-spike.txt),
# which extracted the real Armbian `linux-u-boot-<board>-vendor` packages:
#
#   rock-5b-plus    (current staged vendor package): ONE unified blob
#                   `u-boot-rockchip.bin`.
#                   A single dd at sector 64 lays BOTH the idbloader (RKNS @ blob
#                   offset 0 -> disk sector 64) AND the U-Boot FIT (d00dfeed @
#                   blob offset 0x7f8000 -> disk sector 16384). The FIT carries
#                   ATF/BL31 + OP-TEE internally — there is NO separate trust.bin.
#                   DO NOT split this blob.
#
#   orangepi5-plus  (staged vendor package): TWO blobs — `idbloader.img` at sector 64
#                   and `u-boot.itb` (FIT, ATF/BL31 embedded) at sector 16384.
#
# Both boards yield the SAME on-disk byte layout (idbloader@64, FIT@16384); only
# the package's blob packaging differs. Offsets live in ONE board-keyed lookup
# below — never hardcoded at the call sites.
#
# The blob ships inside the staged BSP `.deb` (the same `bsp/` dir orchestrate.sh
# stages Armbian packages into). We extract it with `ar` + `tar` (the host may be
# Arch with no dpkg — mirrors orchestrate.sh's deb_pkg_name technique), or use a
# loose blob if one is already present in the BSP dir.
#
# Usage:
#   write-bootloader.sh write  --image <raw> --board <board_id> --bsp-dir <dir> [--gap-mb N]
#   write-bootloader.sh verify --image <raw> [--gap-mb N]
#
#   write   Locate the board's blob(s) under <dir>, dd them into the raw gap of
#           <raw> (conv=notrunc — partitions/GPT preserved), then assert RKNS.
#   verify  Re-read sector 64 of <raw> and assert the RKNS idblock magic only.
#
# shellcheck shell=bash

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${HERE}/common.sh"

# ---------------------------------------------------------------------------
# FROZEN on-disk geometry (docs/partition-contract.md §3 + T1 spike).
# Sectors are 512 B. The gap is [0 .. GAP_END_SECTOR); p1 boot starts at its end.
# ---------------------------------------------------------------------------
SECTOR=512
GAP_MB_DEFAULT=16
# Rockchip idblock magic ("RKNS") on media — NOT literal "RK35" (spike Divergence #3).
RKNS_MAGIC="52 4b 4e 53"

# ---------------------------------------------------------------------------
# board_blob_plan <board_id>
# Echo the write plan for a board as newline-separated `BLOB<TAB>SECTOR<TAB>DDBS`
# records (one dd per line). This single lookup is the ONLY place blob filenames
# and their target sectors live — callers never hardcode an offset. Dies loudly
# for a board that has no RK3588 raw-gap plan (e.g. an x86 board reaching here is
# a caller bug — x86 is gated out upstream).
#   DDBS = the dd block size token; SECTOR is expressed in 512 B units so the
#   contract's sector numbers (64, 16384) are literal. For the unified Rock 5B+
#   blob we still express it as sector 64 with bs=512 (== the spike's bs=32k
#   seek=1; 64*512 == 1*32768 == byte 32768). One code path, no special bs math.
# ---------------------------------------------------------------------------
board_blob_plan() {
  local board_id="$1"
  case "${board_id}" in
    rock-5b-plus)
      # ONE unified blob; idbloader(RKNS)@0 + FIT@0x7f8000 are inside it.
      printf 'u-boot-rockchip.bin\t64\t512\n'
      ;;
    orangepi5-plus)
      # TWO blobs: idbloader @ sector 64, U-Boot FIT @ sector 16384.
      printf 'idbloader.img\t64\t512\n'
      printf 'u-boot.itb\t16384\t512\n'
      ;;
    *)
      die "no RK3588 raw-gap bootloader plan for board '${board_id}' (custom-uboot boards: rock-5b-plus, orangepi5-plus). x86/efi must be gated out before reaching write-bootloader.sh."
      ;;
  esac
}

# ---------------------------------------------------------------------------
# extract_debs <bsp_dir> <dest>
# Unpack the data payload of every *.deb under <bsp_dir> into <dest> so the
# bootloader blobs become loose files. Handles xz/gz/zst data.tar (Armbian ships
# data.tar.xz). No dpkg required (Arch-host safe). Idempotent best-effort: a deb
# without a recognised data.tar is skipped (only the U-Boot deb carries blobs).
# ---------------------------------------------------------------------------
extract_debs() {
  local bsp_dir="$1" dest="$2" deb
  mkdir -p "${dest}"
  shopt -s nullglob
  for deb in "${bsp_dir}"/*.deb; do
    if   ar p "${deb}" data.tar.xz  2>/dev/null | tar -xJ  -C "${dest}" 2>/dev/null; then :
    elif ar p "${deb}" data.tar.gz  2>/dev/null | tar -xz  -C "${dest}" 2>/dev/null; then :
    elif ar p "${deb}" data.tar.zst 2>/dev/null | tar --zstd -x -C "${dest}" 2>/dev/null; then :
    fi
  done
  shopt -u nullglob
}

# ---------------------------------------------------------------------------
# locate_blob <name> <root...>
# Echo the first file named exactly <name> found under any <root>, or empty.
# ---------------------------------------------------------------------------
locate_blob() {
  local name="$1"; shift
  local root hit
  for root in "$@"; do
    [[ -d "${root}" ]] || continue
    hit="$(find "${root}" -type f -name "${name}" 2>/dev/null | head -1)"
    [[ -n "${hit}" ]] && { printf '%s' "${hit}"; return 0; }
  done
  printf ''
}

# ---------------------------------------------------------------------------
# magic_at_sector <img> <sector>
# Echo the first 4 bytes at <sector> as lowercase space-separated hex
# (e.g. "52 4b 4e 53"). xxd is unavailable on the Arch dev host (T1 spike note),
# so `od` is used — its byte output is identical to xxd's.
# ---------------------------------------------------------------------------
magic_at_sector() {
  local img="$1" sector="$2"
  dd if="${img}" bs="${SECTOR}" skip="${sector}" count=1 status=none 2>/dev/null \
    | dd bs=1 count=4 status=none 2>/dev/null \
    | od -An -v -tx1 \
    | tr -s ' ' | sed -e 's/^ //' -e 's/ $//'
}

# ---------------------------------------------------------------------------
# assert_rkns <img>
# Die unless the RKNS idblock magic is at sector 64 (byte 32768). This is the
# T11 acceptance check: a written idbloader always starts "RKNS".
# ---------------------------------------------------------------------------
assert_rkns() {
  local img="$1" got
  got="$(magic_at_sector "${img}" 64)"
  if [[ "${got}" != "${RKNS_MAGIC}" ]]; then
    die "RKNS magic check FAILED: sector 64 of ${img} = '${got}', expected '${RKNS_MAGIC}' (RKNS). Bootloader was not written correctly."
  fi
  log_success "RKNS idblock magic verified at sector 64 (${got}) in ${img}"
}

# ---------------------------------------------------------------------------
# write_one <img> <blob> <sector> <ddbs> <gap_end_sector>
# dd a single blob into the raw gap, asserting it ends before the gap boundary
# so it can never collide with the GPT or partition 1. conv=notrunc preserves
# everything already laid down (GPT + adopted boot + ext4 slots).
# ---------------------------------------------------------------------------
write_one() {
  local img="$1" blob="$2" sector="$3" ddbs="$4" gap_end="$5"
  [[ -f "${blob}" ]] || die "bootloader blob not found: ${blob}"
  local size end_sector seek_units
  size="$(stat -c %s "${blob}")"
  # End sector = ceil((sector*512 + size) / 512). Guard: must fit inside the gap.
  end_sector=$(( (sector * SECTOR + size + SECTOR - 1) / SECTOR ))
  if (( end_sector > gap_end )); then
    die "blob $(basename "${blob}") (${size} B @ sector ${sector}) ends at sector ${end_sector}, past the ${gap_end}-sector (16 MB) gap — refusing to overwrite the GPT/partitions."
  fi
  # seek is expressed in <ddbs>-sized units. We keep ddbs=512 so seek == sector.
  seek_units=$(( sector * SECTOR / ddbs ))
  log_info "writing $(basename "${blob}") (${size} B) -> sector ${sector} (bs=${ddbs} seek=${seek_units}, ends sector ${end_sector} < gap ${gap_end})"
  dd if="${blob}" of="${img}" bs="${ddbs}" seek="${seek_units}" conv=notrunc status=none
}

# ---------------------------------------------------------------------------
# do_write — locate + dd the board's blob(s), then assert RKNS.
# ---------------------------------------------------------------------------
do_write() {
  local img="$1" board_id="$2" bsp_dir="$3" gap_mb="$4"
  require_cmd dd
  require_cmd od
  require_cmd ar
  require_cmd tar
  require_cmd find
  require_cmd stat
  [[ -f "${img}" ]]     || die "disk image not found: ${img}"
  [[ -n "${board_id}" ]] || die "write: --board <board_id> is required"
  [[ -d "${bsp_dir}" ]] || die "BSP staging dir not found: ${bsp_dir}"

  local gap_end=$(( gap_mb * 1024 * 1024 / SECTOR ))
  log_info "RK3588 raw-gap bootloader write: board=${board_id} bsp=${bsp_dir} gap=${gap_mb} MiB (end sector ${gap_end})"

  # Stage loose blobs from any .deb under the BSP dir (Armbian U-Boot package).
  local work; work="$(mktemp -d)"
  extract_debs "${bsp_dir}" "${work}"

  local plan; plan="$(board_blob_plan "${board_id}")"
  local blob_name sector ddbs blob
  while IFS=$'\t' read -r blob_name sector ddbs; do
    [[ -n "${blob_name}" ]] || continue
    blob="$(locate_blob "${blob_name}" "${bsp_dir}" "${work}")"
    [[ -n "${blob}" ]] || die "bootloader blob '${blob_name}' for board '${board_id}' not found in ${bsp_dir} (loose or inside a staged .deb). Did fetch-debs stage linux-u-boot-${board_id}-vendor?"
    write_one "${img}" "${blob}" "${sector}" "${ddbs}" "${gap_end}"
  done <<< "${plan}"

  rm -rf "${work}"

  # The contract guarantees idbloader (RKNS) lands at sector 64 on BOTH boards.
  assert_rkns "${img}"
  log_success "bootloader written into the 16 MB gap of ${img} (board ${board_id})"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
  local mode="${1:-}"; shift || true
  local img="" board_id="" bsp_dir="" gap_mb="${GAP_MB_DEFAULT}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --image)   img="${2:-}"; shift 2 ;;
      --board)   board_id="${2:-}"; shift 2 ;;
      --bsp-dir) bsp_dir="${2:-}"; shift 2 ;;
      --gap-mb)  gap_mb="${2:-}"; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done

  case "${mode}" in
    write)
      [[ -n "${img}" ]] || die "write: --image <raw> is required"
      do_write "${img}" "${board_id}" "${bsp_dir}" "${gap_mb}"
      ;;
    verify)
      [[ -n "${img}" ]] || die "verify: --image <raw> is required"
      [[ -f "${img}" ]] || die "disk image not found: ${img}"
      assert_rkns "${img}"
      ;;
    -h|--help|"")
      sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      ;;
    *) die "unknown mode '${mode}' (expected: write | verify)" ;;
  esac
}

main "$@"
