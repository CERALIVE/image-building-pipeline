#!/usr/bin/env bash
#
# write-bootloader.sh — RK3588 raw-gap bootloader writer for the CeraLive v2
# disk assembler (Stage 4).
#
# Writes the board's U-Boot bootloader blob(s) into the 16 MB raw gap
# (sectors 0..32767, NO GPT entry) of an already-assembled GPT disk image, then
# verifies what actually landed. The 16 MB gap is mandated by
# docs/partition-contract.md §2/§3; partition 1 (`boot`) starts at sector 32768,
# so every blob write below stays strictly before it — the GPT and all
# partitions are left untouched.
#
# FAMILY-GATED: this is the rauc_bootloader_adapter == `custom` (RK3588 U-Boot)
# path ONLY. x86 (`efi`) boots from an EFI System Partition and has NO raw
# idbloader gap — assemble-disk.sh never calls this for x86.
#
# WHICH BLOBS: board AND variant, from a COMMITTED map, never a guess.
#
#   The blob set is keyed on the (board, variant) tuple and read from
#   manifests/bootloader-blobs.tsv — the same tuple the resolver keys
#   `variant_overrides.<variant>.uboot_packages` on, so the package the fetcher
#   staged and the blob this writer accepts can never disagree. A tuple with no
#   rows in that file is REFUSED rather than defaulted: a bootloader is the one
#   artifact whose wrong-but-plausible version bricks a board.
#
#   The `edge` variant tracks Armbian's `-edge` U-Boot package, built from the
#   `tpl-blob-atf-mainline` boot scenario (TF-A compiled from upstream
#   ARM-software v2.13.0); `default` keeps each board's shipped `-vendor`
#   package. Both are pinned by exact version in armbian-bsp-deb-versions.txt.
#
# ON-DISK GEOMETRY: one table, here, never a call site.
#
#   `u-boot-rockchip.bin` @ sector 64 — the UNIFIED layout. A single dd lays
#   BOTH the idbloader (RKNS at blob offset 0 -> disk sector 64) AND the U-Boot
#   FIT (d00dfeed at blob offset 0x7f8000 -> disk sector 16384). The FIT carries
#   ATF/BL31 + OP-TEE internally — there is NO separate trust.bin. DO NOT split
#   this blob. Every `-current`/`-edge` package on both boards ships this shape,
#   as does the Rock's `-vendor` package.
#
#   `idbloader.img` @ 64 + `u-boot.itb` @ 16384 — the historical SPLIT layout,
#   shipped by exactly one pinned package: linux-u-boot-orangepi5-plus-vendor
#   (the 2017.09 Rockchip fork). It is retained for that production path only.
#
#   Both shapes yield the SAME on-disk byte layout (idbloader@64, FIT@16384);
#   only the packaging differs.
#
# WHAT IS VERIFIED, and why `assert_rkns` alone was not enough:
#
#   1. IDENTITY, before the write — the source blob's SHA-256 must equal the one
#      committed for this exact (board, variant, blob) tuple. This is what
#      catches a silently-wrong .deb: an archive re-spin under an unchanged
#      version, a stale staged package, or the OTHER board's payload.
#   2. READBACK, after the write — each written range is read back OUT OF THE
#      IMAGE and hashed against the source blob. `assert_rkns` proves only that
#      AN idblock begins at sector 64; it cannot tell one U-Boot from another,
#      and it says nothing at all about the second blob of a split pair.
#   3. RKNS, retained unchanged — the cheap structural sanity check that the
#      thing at sector 64 is a Rockchip idblock at all.
#
# The blob ships inside the staged BSP `.deb` (the same `bsp/` dir orchestrate.sh
# stages Armbian packages into). We extract it with `ar` + `tar` (the host may be
# Arch with no dpkg — mirrors orchestrate.sh's deb_pkg_name technique), or use a
# loose blob if one is already present in the BSP dir.
#
# Usage:
#   write-bootloader.sh write  --image <raw> --board <board_id> --bsp-dir <dir>
#                              [--variant <name>] [--gap-mb N] [--blob-map <tsv>]
#   write-bootloader.sh verify --image <raw> [--gap-mb N]
#   write-bootloader.sh plan   --board <board_id> [--variant <name>] [--blob-map <tsv>]
#
#   write   Locate the tuple's blob(s) under <dir>, assert each one's committed
#           SHA-256, dd them into the raw gap (conv=notrunc — partitions/GPT
#           preserved), read each written range back and re-assert it, then
#           assert RKNS.
#   verify  Re-read sector 64 of <raw> and assert the RKNS idblock magic only.
#   plan    Print the resolved blob plan for a tuple and exit (no image needed).
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

# The reserved no-variant name, matching lib/resolve.sh's DEFAULT_KERNEL_VARIANT.
DEFAULT_VARIANT="default"

# Committed blob-identity map. One tracked file is the whole point: a build that
# writes a blob nobody committed a hash for must fail, not proceed.
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"
BLOB_MAP_DEFAULT="${BOOTLOADER_BLOB_MAP:-${PIPELINE_DIR}/manifests/bootloader-blobs.tsv}"

# ---------------------------------------------------------------------------
# blob_target_sector <blob_name>
# Echo the 512 B sector a named blob is written at, or empty for an unknown name.
# This is the ONLY place an offset lives — the map file deliberately carries no
# offset column, because these are frozen on-disk geometry (upstream U-Boot's
# rockchip layout: idbloader at 32 KiB, second stage at 8 MiB), not per-package
# data that could drift with an archive re-spin.
# ---------------------------------------------------------------------------
blob_target_sector() {
  case "$1" in
    u-boot-rockchip.bin) printf '64'    ;;  # unified: idbloader + FIT in one blob
    idbloader.img)       printf '64'    ;;
    u-boot.itb)          printf '16384' ;;  # 8 MiB — second-stage FIT
    *)                   printf ''      ;;
  esac
}

# ---------------------------------------------------------------------------
# board_blob_plan <board_id> <variant> <blob_map>
# Echo the write plan for a (board, variant) tuple as newline-separated
# `BLOB<TAB>SECTOR<TAB>DDBS<TAB>SHA256<TAB>PACKAGE<TAB>VERSION` records, one dd
# per line, IN MAP ORDER (the map's row order is the write order).
#
# Dies loudly for a tuple the map does not cover — an x86 board reaching here is
# a caller bug (x86 is gated out upstream), and an unmapped variant means someone
# added a variant without deciding which bootloader it ships.
#
#   DDBS = the dd block size token; SECTOR is expressed in 512 B units so the
#   contract's sector numbers (64, 16384) are literal. For a unified blob we
#   still express it as sector 64 with bs=512 (== the spike's bs=32k seek=1;
#   64*512 == 1*32768 == byte 32768). One code path, no special bs math.
# ---------------------------------------------------------------------------
board_blob_plan() {
  local board_id="$1" variant="$2" blob_map="$3"
  [[ -f "${blob_map}" ]] || die "bootloader blob map not found: ${blob_map} (it is a TRACKED file — manifests/bootloader-blobs.tsv)"

  local rows found=0
  rows="$(awk -F'\t' -v b="${board_id}" -v v="${variant}" \
    '!/^[[:space:]]*#/ && NF >= 6 && $1 == b && $2 == v { print }' "${blob_map}")"

  local blob pkg version sha sector
  while IFS=$'\t' read -r _ _ pkg version blob sha; do
    [[ -n "${blob}" ]] || continue
    sector="$(blob_target_sector "${blob}")"
    [[ -n "${sector}" ]] || die "bootloader blob map names blob '${blob}' for ${board_id}/${variant}, which has NO target sector in write-bootloader.sh's frozen geometry table — refusing to guess where a bootloader goes"
    [[ "${sha}" =~ ^[0-9a-f]{64}$ ]] || die "bootloader blob map row for ${board_id}/${variant}/${blob} carries a malformed SHA-256: '${sha}'"
    printf '%s\t%s\t512\t%s\t%s\t%s\n' "${blob}" "${sector}" "${sha}" "${pkg}" "${version}"
    found=1
  done <<< "${rows}"

  if (( found == 0 )); then
    local known
    known="$(awk -F'\t' '!/^[[:space:]]*#/ && NF >= 6 { print $1 "/" $2 }' "${blob_map}" | sort -u | tr '\n' ' ')"
    die "no RK3588 raw-gap bootloader plan for board '${board_id}' variant '${variant}' — ${blob_map} maps: ${known:-<none>}. Every board×variant that reaches the writer must be mapped; x86/efi must be gated out before reaching write-bootloader.sh."
  fi
}

# ---------------------------------------------------------------------------
# sha256_of <file>
# Echo the lowercase hex SHA-256 of a file.
# ---------------------------------------------------------------------------
sha256_of() {
  sha256sum "$1" | awk '{print $1}'
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
# assert_blob_identity <blob_path> <expected_sha> <board> <variant> <name> <pkg> <ver>
# Die unless the located blob's bytes hash to the SHA-256 committed for this
# exact tuple. This runs BEFORE the dd, so a wrong blob never reaches the image.
# The diagnostic names the tuple, the committed source and both hashes, because
# the two realistic causes — an upstream same-version re-spin and the wrong
# board's payload — need different responses.
# ---------------------------------------------------------------------------
assert_blob_identity() {
  local blob="$1" want="$2" board_id="$3" variant="$4" name="$5" pkg="$6" ver="$7"
  local got; got="$(sha256_of "${blob}")"
  if [[ "${got}" != "${want}" ]]; then
    die "bootloader blob IDENTITY check FAILED for ${board_id}/${variant}/${name}: ${blob} hashes to ${got}, but manifests/bootloader-blobs.tsv pins ${want} (from ${pkg}=${ver}). Either the staged .deb is not the pinned one, or upstream replaced the payload under an unchanged version — do NOT update the committed hash without re-verifying the package against the signed Armbian index."
  fi
  log_info "blob identity verified: ${name} sha256 ${got} (${pkg}=${ver}, ${board_id}/${variant})"
}

# ---------------------------------------------------------------------------
# assert_readback <img> <sector> <size> <expected_sha> <name>
# Read the range just written BACK OUT of the image and hash it against the
# source blob. assert_rkns proves an idblock exists at sector 64; it cannot tell
# which U-Boot it is, and it never looks at a split pair's second blob at all.
# ---------------------------------------------------------------------------
assert_readback() {
  local img="$1" sector="$2" size="$3" want="$4" name="$5"
  local got
  got="$(dd if="${img}" bs="${SECTOR}" skip="${sector}" \
           count="$(( (size + SECTOR - 1) / SECTOR ))" status=none 2>/dev/null \
         | head -c "${size}" | sha256sum | awk '{print $1}')"
  if [[ "${got}" != "${want}" ]]; then
    die "bootloader READBACK check FAILED for ${name}: ${size} B read back from sector ${sector} of ${img} hash to ${got}, expected ${want}. The dd did not land the blob it was given."
  fi
  log_success "readback verified byte-identical: ${name} (${size} B @ sector ${sector})"
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
# T11 acceptance check: a written idbloader always starts "RKNS". RETAINED
# UNCHANGED — the readback check above is ADDITIONAL, not a replacement.
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
# do_write — locate + verify + dd the tuple's blob(s), read each back, then RKNS.
# ---------------------------------------------------------------------------
do_write() {
  local img="$1" board_id="$2" bsp_dir="$3" gap_mb="$4" variant="$5" blob_map="$6"
  require_cmd dd
  require_cmd od
  require_cmd ar
  require_cmd tar
  require_cmd find
  require_cmd stat
  require_cmd sha256sum
  [[ -f "${img}" ]]      || die "disk image not found: ${img}"
  [[ -n "${board_id}" ]] || die "write: --board <board_id> is required"
  [[ -n "${variant}" ]]  || die "write: --variant must name a variant (use '${DEFAULT_VARIANT}' for the production path)"
  [[ -d "${bsp_dir}" ]]  || die "BSP staging dir not found: ${bsp_dir}"

  local gap_end=$(( gap_mb * 1024 * 1024 / SECTOR ))
  log_info "RK3588 raw-gap bootloader write: board=${board_id} variant=${variant} bsp=${bsp_dir} gap=${gap_mb} MiB (end sector ${gap_end})"

  # Resolve the plan BEFORE any extraction: an unmapped tuple must fail fast,
  # not after unpacking every staged .deb.
  local plan; plan="$(board_blob_plan "${board_id}" "${variant}" "${blob_map}")"

  # Stage loose blobs from any .deb under the BSP dir (Armbian U-Boot package).
  local work; work="$(mktemp -d)"
  extract_debs "${bsp_dir}" "${work}"

  local blob_name sector ddbs sha pkg version blob size
  while IFS=$'\t' read -r blob_name sector ddbs sha pkg version; do
    [[ -n "${blob_name}" ]] || continue
    blob="$(locate_blob "${blob_name}" "${bsp_dir}" "${work}")"
    if [[ -z "${blob}" ]]; then
      rm -rf "${work}"
      die "bootloader blob '${blob_name}' for ${board_id}/${variant} not found in ${bsp_dir} (loose or inside a staged .deb). Did fetch-debs stage ${pkg}=${version}?"
    fi
    assert_blob_identity "${blob}" "${sha}" "${board_id}" "${variant}" "${blob_name}" "${pkg}" "${version}"
    size="$(stat -c %s "${blob}")"
    write_one "${img}" "${blob}" "${sector}" "${ddbs}" "${gap_end}"
    assert_readback "${img}" "${sector}" "${size}" "${sha}" "${blob_name}"
  done <<< "${plan}"

  rm -rf "${work}"

  # The contract guarantees idbloader (RKNS) lands at sector 64 on BOTH layouts.
  assert_rkns "${img}"
  log_success "bootloader written into the 16 MB gap of ${img} (board ${board_id}, variant ${variant})"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
  local mode="${1:-}"; shift || true
  local img="" board_id="" bsp_dir="" gap_mb="${GAP_MB_DEFAULT}"
  local variant="${DEFAULT_VARIANT}" blob_map="${BLOB_MAP_DEFAULT}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --image)    img="${2:-}"; shift 2 ;;
      --board)    board_id="${2:-}"; shift 2 ;;
      --bsp-dir)  bsp_dir="${2:-}"; shift 2 ;;
      --gap-mb)   gap_mb="${2:-}"; shift 2 ;;
      --variant)  variant="${2:-}"; shift 2 ;;
      --blob-map) blob_map="${2:-}"; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  # An empty --variant is the production path, not an error: the orchestrator
  # forwards KERNEL_VARIANT, which resolve.py emits ONLY for a kernel-from-source
  # variant, so the vendor path legitimately arrives as "".
  [[ -n "${variant}" ]] || variant="${DEFAULT_VARIANT}"

  case "${mode}" in
    write)
      [[ -n "${img}" ]] || die "write: --image <raw> is required"
      do_write "${img}" "${board_id}" "${bsp_dir}" "${gap_mb}" "${variant}" "${blob_map}"
      ;;
    verify)
      [[ -n "${img}" ]] || die "verify: --image <raw> is required"
      [[ -f "${img}" ]] || die "disk image not found: ${img}"
      assert_rkns "${img}"
      ;;
    plan)
      [[ -n "${board_id}" ]] || die "plan: --board <board_id> is required"
      board_blob_plan "${board_id}" "${variant}" "${blob_map}"
      ;;
    -h|--help|"")
      # 2..76 is the whole header block, up to the shellcheck directive. Adding
      # a line inside it without moving this range truncates the help mid-word.
      sed -n '2,76p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      ;;
    *) die "unknown mode '${mode}' (expected: write | verify | plan)" ;;
  esac
}

main "$@"
