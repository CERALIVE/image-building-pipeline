#!/usr/bin/env bash
#
# preflash-cross-board.test.sh — the CROSS-BOARD REJECTION contract.
#
# `ci/verify-and-flash-candidate.sh` used to be hardcoded to rock-5b-plus, which
# means it could not tell a Rock candidate from an Orange Pi one. This suite
# proves the parameterized tool now derives every identity axis from the board
# manifest and REFUSES a candidate built for the other board — in both
# directions, and per axis, with REAL fixtures: a genuine FAT boot partition
# carrying a real `cera_board.env` and a genuine squashfs RAUC bundle carrying a
# real `manifest.raucm`.
#
# Hardware-free: no USB, no UART, no board, no destructive write. The tool's
# `--check-identity-only` mode is the whole subject.
#
# shellcheck shell=bash

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"
# shellcheck source=tests/lib/assertions.sh
source "${HERE}/lib/assertions.sh"

assert_contains_str() {
  if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1: '$3' not in output"; fi
}
assert_file_has() {
  if [[ -f "$2" ]] && grep -qxF -- "$3" "$2"; then ok "$1"; else bad "$1: '$3' not a line of $2"; fi
}
assert_absent() {
  if [[ ! -e "$2" ]]; then ok "$1"; else bad "$1: $2 exists"; fi
}
assert_ne() {
  if [[ "$2" != "$3" ]]; then ok "$1 (rc=$3)"; else bad "$1: got the refused value '$3'"; fi
}

VERIFY="${PIPELINE_DIR}/ci/verify-and-flash-candidate.sh"
READER="${PIPELINE_DIR}/ci/read-candidate-identity.sh"

for tool in mformat mcopy mtype mksquashfs unsquashfs; do
  command -v "${tool}" >/dev/null 2>&1 || {
    printf 'FAIL required tool not on PATH: %s\n' "${tool}" >&2
    exit 2
  }
done

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

GAP_BYTES=$((16 * 1024 * 1024))

# append_be64 <file> <value> — the .raucb 8-byte big-endian signature-length
# trailer. Written byte-wise because the layout, not a tool, is the contract.
append_be64() {
  local file="$1" value="$2" shift_bits byte
  for shift_bits in 56 48 40 32 24 16 8 0; do
    byte=$(( (value >> shift_bits) & 255 ))
    printf '%b' "$(printf '\\x%02x' "${byte}")" >>"${file}"
  done
}

# make_candidate <name> <board_id> <fdtfile> <compatible> — a real artifact set.
make_candidate() {
  local name="$1" board_id="$2" fdtfile="$3" compatible="$4"
  local dir="${TMP}/${name}" boot="${TMP}/${name}-boot.img" siglen

  mkdir -p "${dir}/bundle"
  printf 'console=ttyS2,1500000\nfdtfile=%s\nboard_id=%s\n' "${fdtfile}" "${board_id}" \
    >"${dir}/cera_board.env"

  truncate -s 8M "${boot}"
  mformat -i "${boot}" ::
  mcopy -i "${boot}" "${dir}/cera_board.env" ::/cera_board.env

  truncate -s $((GAP_BYTES + 8 * 1024 * 1024)) "${dir}/candidate.raw"
  dd if="${boot}" of="${dir}/candidate.raw" bs=1M seek=16 conv=notrunc status=none

  printf 'compatible=%s\nversion=2026.8.1\n[image.rootfs]\nfilename=rootfs.img\n' \
    "${compatible}" >"${dir}/bundle/manifest.raucm"
  printf 'rootfs-bytes\n' >"${dir}/bundle/rootfs.img"
  mksquashfs "${dir}/bundle" "${dir}/payload.squashfs" -no-progress -quiet -noappend

  printf 'not-a-real-cms-signature-identity-reads-do-not-verify\n' >"${dir}/signature.cms"
  siglen="$(stat -c %s "${dir}/signature.cms")"
  cat "${dir}/payload.squashfs" "${dir}/signature.cms" >"${dir}/candidate.raucb"
  append_be64 "${dir}/candidate.raucb" "${siglen}"

  printf 'rk3588-loader-%s\n' "${name}" >"${dir}/loader.bin"
}

check_identity() {
  local dir="$1" board="$2" out="$3"
  "${VERIFY}" --check-identity-only \
    --board "${board}" \
    --image "${dir}/candidate.raw" \
    --bundle "${dir}/candidate.raucb" \
    --loader "${dir}/loader.bin" \
    --image-sha256 "$(sha256sum "${dir}/candidate.raw" | cut -d' ' -f1)" \
    --loader-sha256 "$(sha256sum "${dir}/loader.bin" | cut -d' ' -f1)" \
    --identity-out "${out}" 2>&1
}

echo "### 1. real fixtures are readable and self-describing"
make_candidate rock   rock-5b-plus   rk3588-rock-5b-plus.dtb     ceralive-rock-5b-plus
make_candidate orange orangepi5-plus rk3588-orangepi-5-plus.dtb  ceralive-orangepi5-plus
xz -T1 -1 -c "${TMP}/rock/candidate.raw" >"${TMP}/rock/candidate.raw.xz"

rock_read="$("${READER}" --image "${TMP}/rock/candidate.raw" \
  --bundle "${TMP}/rock/candidate.raucb" --loader "${TMP}/rock/loader.bin")"
assert_contains_str "the reader recovers the Rock board_id from the real FAT boot partition" \
  "${rock_read}" 'candidate_board_id=rock-5b-plus'
assert_contains_str "the reader recovers the Rock fdtfile" \
  "${rock_read}" 'candidate_fdtfile=rk3588-rock-5b-plus.dtb'
assert_contains_str "the reader recovers the Rock compatible from the real squashfs manifest" \
  "${rock_read}" 'candidate_compatible=ceralive-rock-5b-plus'

rock_xz_read="$("${READER}" --image "${TMP}/rock/candidate.raw.xz" \
  --bundle "${TMP}/rock/candidate.raucb" --loader "${TMP}/rock/loader.bin")"
assert_contains_str "the reader accepts the sealed .raw.xz transport" \
  "${rock_xz_read}" 'candidate_board_id=rock-5b-plus'
assert_contains_str "the compressed reader reports the DECOMPRESSED raw digest" \
  "${rock_xz_read}" "candidate_raw_sha256=$(sha256sum "${TMP}/rock/candidate.raw" | cut -d' ' -f1)"

real_xz="$(command -v xz)"
mkdir "${TMP}/bin"
cat >"${TMP}/bin/xz" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --robot && "${2:-}" == --list ]]; then
  printf 'totals\t1\t1\t1\t17179869185\t---\tCRC64\t0\t1\n'
  exit 0
fi
exec "${REAL_XZ}" "$@"
EOF
chmod +x "${TMP}/bin/xz"
oversized_output="$(REAL_XZ="${real_xz}" PATH="${TMP}/bin:${PATH}" "${READER}" \
  --image "${TMP}/rock/candidate.raw.xz" --bundle "${TMP}/rock/candidate.raucb" \
  --loader "${TMP}/rock/loader.bin" 2>&1)"
oversized_rc=$?
assert_ne "the reader rejects a declared decompressed size above 16 GiB" 0 "${oversized_rc}"
assert_contains_str "the oversized rejection names the decompression safety limit" \
  "${oversized_output}" 'decompressed candidate exceeds 16 GiB safety limit'

orange_read="$("${READER}" --image "${TMP}/orange/candidate.raw" \
  --bundle "${TMP}/orange/candidate.raucb" --loader "${TMP}/orange/loader.bin")"
assert_contains_str "the reader recovers the Orange Pi board_id" \
  "${orange_read}" 'candidate_board_id=orangepi5-plus'
assert_contains_str "the reader recovers the Orange Pi compatible" \
  "${orange_read}" 'candidate_compatible=ceralive-orangepi5-plus'

echo
echo "### 2. matched candidate/board pairs are ACCEPTED with a full evidence tuple"
out="$(check_identity "${TMP}/rock" rock-5b-plus "${TMP}/rock-identity.txt")"
rc=$?
assert_eq "a Rock candidate against rock-5b-plus is accepted" 0 "${rc}"
assert_file_has "the Rock evidence tuple records the board" \
  "${TMP}/rock-identity.txt" 'board=rock-5b-plus'
assert_file_has "the Rock evidence tuple records the board_id" \
  "${TMP}/rock-identity.txt" 'board_id=rock-5b-plus'
assert_file_has "the Rock evidence tuple records the compatible string" \
  "${TMP}/rock-identity.txt" 'compatible=ceralive-rock-5b-plus'
assert_file_has "the Rock evidence tuple records the DTB" \
  "${TMP}/rock-identity.txt" 'dtb_name=rk3588-rock-5b-plus.dtb'
assert_file_has "the Rock evidence tuple records the variant" \
  "${TMP}/rock-identity.txt" 'variant=default'
assert_file_has "the Rock evidence tuple records the raw artifact digest" \
  "${TMP}/rock-identity.txt" "raw_sha256=$(sha256sum "${TMP}/rock/candidate.raw" | cut -d' ' -f1)"
assert_file_has "the Rock evidence tuple records the bundle artifact digest" \
  "${TMP}/rock-identity.txt" "bundle_sha256=$(sha256sum "${TMP}/rock/candidate.raucb" | cut -d' ' -f1)"
assert_file_has "the Rock evidence tuple records the loader artifact digest" \
  "${TMP}/rock-identity.txt" "loader_sha256=$(sha256sum "${TMP}/rock/loader.bin" | cut -d' ' -f1)"
assert_file_has "an identity-only check performs no destructive write" \
  "${TMP}/rock-identity.txt" 'destructive_write=none'

out="$(check_identity "${TMP}/orange" orange-pi-5-plus "${TMP}/orange-identity.txt")"
rc=$?
assert_eq "an Orange Pi candidate against orange-pi-5-plus is accepted" 0 "${rc}"
assert_file_has "the Orange Pi evidence tuple records its own board_id" \
  "${TMP}/orange-identity.txt" 'board_id=orangepi5-plus'
assert_file_has "the Orange Pi evidence tuple records its own compatible string" \
  "${TMP}/orange-identity.txt" 'compatible=ceralive-orangepi5-plus'

echo
echo "### 3. CROSS-BOARD candidates are REJECTED, in both directions"
rm -f "${TMP}/xboard.txt"
out="$(check_identity "${TMP}/rock" orange-pi-5-plus "${TMP}/xboard.txt")"
rc=$?
assert_ne "a Rock candidate pointed at Orange Pi identity data is REJECTED" 0 "${rc}"
assert_contains_str "the rejection names the board_id axis" "${out}" \
  'cross-board candidate REJECTED: board_id expected orangepi5-plus'
assert_contains_str "the rejection names the dtb_name axis" "${out}" \
  'cross-board candidate REJECTED: dtb_name expected rk3588-orangepi-5-plus.dtb'
assert_contains_str "the rejection names the compatible axis" "${out}" \
  'cross-board candidate REJECTED: compatible expected ceralive-orangepi5-plus'
assert_absent "a rejected cross-board candidate writes no identity/evidence record" \
  "${TMP}/xboard.txt"

rm -f "${TMP}/xboard2.txt"
out="$(check_identity "${TMP}/orange" rock-5b-plus "${TMP}/xboard2.txt")"
rc=$?
assert_ne "an Orange Pi candidate pointed at Rock identity data is REJECTED" 0 "${rc}"
assert_contains_str "the reverse rejection names the Rock board_id" "${out}" \
  'cross-board candidate REJECTED: board_id expected rock-5b-plus'
assert_absent "the reverse rejection writes no identity/evidence record" \
  "${TMP}/xboard2.txt"

echo
echo "### 4. per-axis negatives: one wrong field is enough to reject"
make_candidate wrong-dtb rock-5b-plus rk3588-orangepi-5-plus.dtb ceralive-rock-5b-plus
rm -f "${TMP}/axis.txt"
out="$(check_identity "${TMP}/wrong-dtb" rock-5b-plus "${TMP}/axis.txt")"
rc=$?
assert_ne "a Rock candidate carrying the Orange Pi DTB is REJECTED" 0 "${rc}"
assert_contains_str "the DTB-only rejection names the dtb_name axis" "${out}" \
  'cross-board candidate REJECTED: dtb_name'
assert_absent "the DTB-only rejection writes no evidence record" "${TMP}/axis.txt"

make_candidate wrong-compat rock-5b-plus rk3588-rock-5b-plus.dtb ceralive-orangepi5-plus
rm -f "${TMP}/axis2.txt"
out="$(check_identity "${TMP}/wrong-compat" rock-5b-plus "${TMP}/axis2.txt")"
rc=$?
assert_ne "a Rock candidate whose bundle is Compatible with the other board is REJECTED" 0 "${rc}"
assert_contains_str "the compatible-only rejection names the compatible axis" "${out}" \
  'cross-board candidate REJECTED: compatible'

echo
echo "### 5. a swapped artifact is rejected on its digest"
rm -f "${TMP}/axis3.txt"
out="$("${VERIFY}" --check-identity-only --board rock-5b-plus \
  --image "${TMP}/rock/candidate.raw" \
  --bundle "${TMP}/rock/candidate.raucb" \
  --loader "${TMP}/orange/loader.bin" \
  --image-sha256 "$(sha256sum "${TMP}/rock/candidate.raw" | cut -d' ' -f1)" \
  --loader-sha256 "$(sha256sum "${TMP}/rock/loader.bin" | cut -d' ' -f1)" \
  --identity-out "${TMP}/axis3.txt" 2>&1)"
rc=$?
assert_ne "a loader from the other board's candidate set is REJECTED" 0 "${rc}"
assert_contains_str "the loader swap is named on the loader_sha256 axis" "${out}" \
  'cross-board candidate REJECTED: loader_sha256'

echo
echo "### 6. an unknown board is refused, never defaulted to rock-5b-plus"
rm -f "${TMP}/axis4.txt"
out="$(check_identity "${TMP}/rock" definitely-not-a-board "${TMP}/axis4.txt")"
rc=$?
assert_ne "an unknown board name is refused" 0 "${rc}"
assert_contains_str "the refusal lists the boards that do exist" "${out}" \
  "unknown board 'definitely-not-a-board'"

echo
echo "### 7. a family with no whole-media Maskrom transport is refused"
rm -f "${TMP}/axis5.txt"
out="$(check_identity "${TMP}/rock" x86-minipc "${TMP}/axis5.txt")"
rc=$?
assert_ne "x86-minipc is refused rather than silently flashed over USB" 0 "${rc}"

echo
printf 'preflash cross-board contract: %s pass, %s fail\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
