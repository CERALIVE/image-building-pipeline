#!/usr/bin/env bash
#
# preflash-verify.sh — consolidated PRE-FLASH GREEN gate for a CeraLive v2
# rock-5b-plus (RK3588) device image. This is the offline, hardware-free check
# that AUTHORIZES hardware bring-up: it inspects the produced `.raw` disk image
# and signed `.raucb` RAUC bundle and prints PASS or FAIL for each sub-check,
# exiting non-zero if ANY sub-check fails. A red gate means DO NOT flash.
#
# Nine sub-checks (all must PASS):
#   1. GPT geometry   — exact A/B starts/sizes, unique labels, clean sgdisk -v.
#   2. Gap idblock    — Rockchip "RKNS" at sector 64.
#   3. Gap FIT        — parseable U-Boot FIT at sector 16384 whose embedded or
#                       external payload extents are bounded and SHA-256-valid.
#   4. Boot partition — compiled boot.scr, Rock board metadata, boot_state.txt and
#                       recovery.scr are all present on the FAT boot
#                       partition (offset GAP_MB * 1 MiB).
#   5. Boot state     — boot_state.txt starts with BOOT_ORDER=A B and a positive
#                       attempt budget for both populated factory slots.
#   6. RAUC bundle    — CMS verifies to the release root and manifest Compatible matches
#                       is ceralive-<board>. The dev/prod leaf carries
#                       EKU=codeSigning only, so verification MUST pass
#                       `-C keyring:check-purpose=codesign` (see T13 findings).
#   7. Factory A      — init, kernel, Rock DTB, initrd, shared p1 /boot mount.
#   8. Factory B      — the same complete boot artifact set in rootfs_b.
#                       An empty or state-isolated B blocks production flash.
#   9. Target media   — the operator-supplied capacity is at least the exact raw
#                       image size; an undersized eMMC/SD/NVMe is rejected.
#
# Everything is image inspection: no loop mount, no root, no hardware. The
# boot partition is read with mtools (mdir/mtype) at its raw byte offset; the
# GPT with sgdisk; the gap magic with dd + xxd (od fallback when xxd is absent).
#
# Usage:
#   preflash-verify.sh [--image <raw>] [--bundle <raucb>] [--board <id>]
#                      [--keyring <pem>] [--gap-mb N] --target-size-bytes N
#   preflash-verify.sh --self-test [--board <id>] ...   # built-in negative test
#
#   (no mode)   Run all sub-checks against the artifacts and exit non-zero
#               on any FAIL. --image/--bundle default to the newest files under
#               v2/images/<board>/ ; --board defaults to rock-5b-plus.
#   --self-test Prove the gate is NOT vacuous: copy the image, zero the gap
#               bytes, re-run the checks against the copy and assert the gap
#               magic sub-check FAILS. Exits 0 only when the corruption was
#               correctly detected.
#
# shellcheck shell=bash

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2_DIR="$(cd "${HERE}/.." && pwd)"
# shellcheck source=lib/rauc-bundle-inspect.sh
source "${V2_DIR}/lib/rauc-bundle-inspect.sh"
IMAGES_DIR="${IMAGES_DIR:-${V2_DIR}/images}"

# ---------------------------------------------------------------------------
# FROZEN contract constants (docs/partition-contract.md §3 + T1/T11 spike).
# ---------------------------------------------------------------------------
SECTOR=512
GAP_MB_DEFAULT=16            # raw idbloader+U-Boot+ATF gap before p1 (16 MiB)
RKNS_SECTOR=64               # Rockchip idblock lands at sector 64 (byte 32768)
RKNS_MAGIC="52 4b 4e 53"     # "RKNS" on media (NOT literal "RK35"; spike Div #3)
FIT_SECTOR=16384
FIT_MAGIC="d0 0d fe ed"
FIT_MAX_BYTES=8388608
FIT_MAX_IMAGES=32
FIT_MAX_HASH_NODES=8
BOOT_START=32768
BOOT_SIZE=524288
ROOTFS_SIZE=8388608
ROOTFS_A_START=557056
ROOTFS_B_START=8945664
DATA_START=17334272
# ---------------------------------------------------------------------------
# Reporting — every sub-check prints exactly one PASS/FAIL line and feeds FAILS.
# ---------------------------------------------------------------------------
FAILS=0
pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*"; FAILS=$(( FAILS + 1 )); }
info() { printf '       %s\n' "$*"; }

# ---------------------------------------------------------------------------
# newest_artifact <board> <glob> — newest file matching v2/images/<board>/<glob>.
# ---------------------------------------------------------------------------
newest_artifact() {
  local board="$1" glob="$2"
  # ls -t for mtime ordering; the glob MUST expand (build-timestamp filenames).
  # shellcheck disable=SC2012,SC2086
  ls -1t "${IMAGES_DIR}/${board}/"${glob} 2>/dev/null | head -1
}

check_gpt_geometry() {
  local img="$1"
  require_tool sgdisk || { fail "GPT geometry: A/B (boot + rootfs_a + rootfs_b + data)"; return; }
  local labels count verify_out
  if ! verify_out="$(sgdisk -v "${img}" 2>&1)" \
      || ! grep -q 'No problems found' <<<"${verify_out}"; then
    fail "GPT integrity: sgdisk -v reports no structural errors"
    info "$(printf '%s' "${verify_out}" | tail -1)"
    return
  fi
  # Partition rows in `sgdisk -p` start with whitespace + the partition number;
  # the PARTLABEL is the last column. Collect them in table order.
  labels="$(sgdisk -p "${img}" 2>/dev/null \
    | awk '/^[[:space:]]+[0-9]+[[:space:]]/{print $NF}')"
  count="$(printf '%s\n' "${labels}" | grep -c .)"
  local norm; norm="$(printf '%s\n' "${labels}" | tr '\n' ' ' | sed 's/ *$//')"
  local p1_start p1_size p2_start p2_size p3_start p3_size p4_start p4_size p4_last expected_last
  p1_start="$(part_value "${img}" 1 'First sector')"; p1_size="$(part_value "${img}" 1 'Partition size')"
  p2_start="$(part_value "${img}" 2 'First sector')"; p2_size="$(part_value "${img}" 2 'Partition size')"
  p3_start="$(part_value "${img}" 3 'First sector')"; p3_size="$(part_value "${img}" 3 'Partition size')"
  p4_start="$(part_value "${img}" 4 'First sector')"; p4_size="$(part_value "${img}" 4 'Partition size')"
  p4_last="$(part_value "${img}" 4 'Last sector')"
  expected_last=$(( (($(stat -c %s "${img}") / SECTOR - 33) / 8) * 8 - 1 ))
  if [[ "${norm}" == "boot rootfs_a rootfs_b data" ]] \
      && [[ "$(printf '%s\n' "${labels}" | sort -u | wc -l)" -eq 4 ]] \
      && [[ "${p1_start}" == "${BOOT_START}" && "${p1_size}" == "${BOOT_SIZE}" ]] \
      && [[ "${p2_start}" == "${ROOTFS_A_START}" && "${p2_size}" == "${ROOTFS_SIZE}" ]] \
      && [[ "${p3_start}" == "${ROOTFS_B_START}" && "${p3_size}" == "${ROOTFS_SIZE}" ]] \
      && [[ "${p4_start}" == "${DATA_START}" && "${p4_size}" -ge 4194304 ]] \
      && [[ "${p4_last}" -eq "${expected_last}" && "${p4_size}" -eq $((expected_last - DATA_START + 1)) ]]; then
    pass "GPT geometry: exact A/B starts/sizes and unique labels"
    info "partitions (${count}): ${norm}"
  else
    fail "GPT geometry: exact A/B starts/sizes and unique labels"
    info "got labels='${norm}' starts=${p1_start},${p2_start},${p3_start},${p4_start} sizes=${p1_size},${p2_size},${p3_size},${p4_size}"
  fi
}

part_value() {
  local img="$1" part="$2" field="$3"
  sgdisk -i "${part}" "${img}" 2>/dev/null | sed -n "s/.*${field}: \([0-9][0-9]*\).*/\1/p"
}

# ---------------------------------------------------------------------------
# Check 2 — Gap magic: RKNS idblock at sector 64 (U-Boot in the 16 MB gap).
# The reference command is `dd if=<raw> bs=512 skip=64 count=1 | xxd | head -1`;
# xxd is absent on the dev host so od renders byte-identical hex when needed.
# ---------------------------------------------------------------------------
check_gap_magic() {
  local img="$1" line got
  if command -v xxd >/dev/null 2>&1; then
    line="$(dd if="${img}" bs="${SECTOR}" skip="${RKNS_SECTOR}" count=1 status=none 2>/dev/null \
      | xxd | head -1)"
    # xxd column layout: "00000000: 524b 4e53 ...  RKNS...". Pull the first 4 bytes.
    got="$(printf '%s' "${line}" | sed -E 's/^[0-9a-f]+: ([0-9a-f]{2})([0-9a-f]{2}) ([0-9a-f]{2})([0-9a-f]{2}).*/\1 \2 \3 \4/')"
  else
    line="$(dd if="${img}" bs="${SECTOR}" skip="${RKNS_SECTOR}" count=1 status=none 2>/dev/null \
      | od -An -v -tx1 | head -1 | tr -s ' ' | sed -e 's/^ //' -e 's/ $//')"
    got="$(printf '%s' "${line}" | cut -d' ' -f1-4)"
  fi
  if [[ "${got}" == "${RKNS_MAGIC}" ]]; then
    pass "Gap magic: RKNS (52 4b 4e 53) at sector ${RKNS_SECTOR}"
    info "sector ${RKNS_SECTOR} first bytes: ${got}"
  else
    fail "Gap magic: RKNS (52 4b 4e 53) at sector ${RKNS_SECTOR}"
    info "sector ${RKNS_SECTOR} first bytes: '${got}' (expected '${RKNS_MAGIC}') — bootloader not written"
  fi
}

fit_has_property() {
  local fit="$1" node="$2" property="$3"
  fdtget -p "${fit}" "${node}" 2>/dev/null | grep -Fxq "${property}"
}

fit_u32_property() {
  local fit="$1" node="$2" property="$3" raw
  local -a values
  raw="$(fdtget -t u "${fit}" "${node}" "${property}" 2>/dev/null)" || return 1
  read -r -a values <<<"${raw}"
  (( ${#values[@]} == 1 )) && [[ "${values[0]}" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$((10#${values[0]}))"
}

fit_sha256_property() {
  local fit="$1" node="$2" property="$3" raw byte padded digest=""
  local -a bytes
  raw="$(fdtget -t bx "${fit}" "${node}" "${property}" 2>/dev/null)" || return 1
  read -r -a bytes <<<"${raw}"
  (( ${#bytes[@]} == 32 )) || return 1
  for byte in "${bytes[@]}"; do
    [[ "${byte}" =~ ^[0-9a-fA-F]{1,2}$ ]] || return 1
    printf -v padded '%02x' "$((16#${byte}))"
    digest+="${padded}"
  done
  printf '%s\n' "${digest}"
}

check_second_stage_fit() {
  local img="$1" got size_hex metadata_size=0 image_bytes available_bytes
  local fit_start=$((FIT_SECTOR * SECTOR)) external_base=0 full_extent=0 valid=1 reason=""
  local tmp metadata_fit full_fit metadata_bytes full_bytes nodes_out node path properties
  local has_data has_offset has_position data_size data_offset data_position payload_start payload_end
  local children_out child hash_path algo expected actual payload payload_bytes verified_hashes=0 image_index hash_nodes
  local -a image_nodes expected_hashes

  require_tool dumpimage || {
    fail "Bootloader second-stage FIT: valid FDT header and extent at sector ${FIT_SECTOR}"
    return
  }
  require_tool fdtget || {
    fail "Bootloader second-stage FIT: valid FDT header and extent at sector ${FIT_SECTOR}"
    return
  }
  require_tool sha256sum || {
    fail "Bootloader second-stage FIT: valid FDT header and extent at sector ${FIT_SECTOR}"
    return
  }

  got="$(dd if="${img}" bs=1 skip="${fit_start}" count=4 status=none 2>/dev/null \
    | od -An -v -tx1 | tr -s ' ' | sed 's/^ //;s/ $//')"
  size_hex="$(dd if="${img}" bs=1 skip=$((fit_start + 4)) count=4 status=none 2>/dev/null \
    | od -An -v -tx1 | tr -d ' \n')"
  [[ "${size_hex}" =~ ^[0-9a-fA-F]{8}$ ]] && metadata_size=$((16#${size_hex}))
  image_bytes="$(stat -c %s "${img}" 2>/dev/null || printf 0)"
  available_bytes=$(( image_bytes > fit_start ? image_bytes - fit_start : 0 ))
  if ! tmp="$(mktemp -d)"; then
    fail "Bootloader second-stage FIT: valid FDT header and extent at sector ${FIT_SECTOR}"
    info "could not create private FIT inspection directory"
    return
  fi
  metadata_fit="${tmp}/metadata.itb"
  full_fit="${tmp}/full.itb"

  if [[ "${got}" != "${FIT_MAGIC}" ]]; then
    valid=0; reason="invalid FIT magic '${got}'"
  elif (( metadata_size < 40 || metadata_size > FIT_MAX_BYTES )); then
    valid=0; reason="invalid FDT metadata size ${metadata_size}"
  elif (( metadata_size > available_bytes )); then
    valid=0; reason="FDT metadata exceeds available FIT bytes"
  elif ! dd if="${img}" of="${metadata_fit}" bs=1 skip="${fit_start}" \
      count="${metadata_size}" status=none 2>/dev/null; then
    valid=0; reason="could not read FDT metadata"
  elif ! metadata_bytes="$(stat -c %s "${metadata_fit}" 2>/dev/null)" \
      || [[ "${metadata_bytes}" != "${metadata_size}" ]]; then
    valid=0; reason="could not read complete FDT metadata"
  elif ! dumpimage -l "${metadata_fit}" >/dev/null 2>&1; then
    valid=0; reason="dumpimage rejected FDT metadata"
  fi

  image_nodes=()
  if (( valid == 1 )); then
    if ! nodes_out="$(fdtget -l "${metadata_fit}" /images 2>/dev/null)"; then
      valid=0; reason="FIT has no parseable /images node"
    else
      while IFS= read -r node; do
        [[ -n "${node}" ]] && image_nodes+=("${node}")
      done <<<"${nodes_out}"
      if (( ${#image_nodes[@]} == 0 )); then
        valid=0; reason="FIT contains no image payloads"
      elif (( ${#image_nodes[@]} > FIT_MAX_IMAGES )); then
        valid=0; reason="FIT contains more than ${FIT_MAX_IMAGES} image payloads"
      fi
    fi
  fi

  external_base=$(( (metadata_size + 3) / 4 * 4 ))
  full_extent="${metadata_size}"
  if (( valid == 1 )); then
    for image_index in "${!image_nodes[@]}"; do
      node="${image_nodes[$image_index]}"
      path="/images/${node}"
      properties="$(fdtget -p "${metadata_fit}" "${path}" 2>/dev/null || true)"
      has_data=0; has_offset=0; has_position=0
      grep -Fxq data <<<"${properties}" && has_data=1
      grep -Fxq data-offset <<<"${properties}" && has_offset=1
      grep -Fxq data-position <<<"${properties}" && has_position=1

      if (( has_data == 1 )); then
        if (( has_offset == 1 || has_position == 1 )); then
          valid=0; reason="image '${node}' mixes embedded and external payload locations"; break
        fi
        continue
      fi
      if ! fit_has_property "${metadata_fit}" "${path}" data-size \
          || ! data_size="$(fit_u32_property "${metadata_fit}" "${path}" data-size)" \
          || (( data_size <= 0 )); then
        valid=0; reason="image '${node}' has no bounded payload size"; break
      fi
      if (( has_offset + has_position != 1 )); then
        valid=0; reason="image '${node}' has an ambiguous external payload location"; break
      fi
      if (( has_offset == 1 )); then
        if ! data_offset="$(fit_u32_property "${metadata_fit}" "${path}" data-offset)" \
            || (( data_offset > FIT_MAX_BYTES - external_base )); then
          valid=0; reason="image '${node}' has an invalid data-offset"; break
        fi
        payload_start=$((external_base + data_offset))
      else
        if ! data_position="$(fit_u32_property "${metadata_fit}" "${path}" data-position)" \
            || (( data_position < metadata_size || data_position > FIT_MAX_BYTES )); then
          valid=0; reason="image '${node}' has an invalid data-position"; break
        fi
        payload_start="${data_position}"
      fi
      if (( payload_start > FIT_MAX_BYTES || data_size > FIT_MAX_BYTES - payload_start )); then
        valid=0; reason="image '${node}' payload extent exceeds ${FIT_MAX_BYTES}-byte FIT budget"; break
      fi
      payload_end=$((payload_start + data_size))
      if (( payload_end > available_bytes )); then
        valid=0; reason="image '${node}' payload extent exceeds available FIT bytes"; break
      fi
      (( payload_end > full_extent )) && full_extent="${payload_end}"
    done
  fi

  if (( valid == 1 )); then
    if ! dd if="${img}" of="${full_fit}" bs=1 skip="${fit_start}" \
        count="${full_extent}" status=none 2>/dev/null; then
      valid=0; reason="could not read complete FIT extent"
    elif ! full_bytes="$(stat -c %s "${full_fit}" 2>/dev/null)" \
        || [[ "${full_bytes}" != "${full_extent}" ]]; then
      valid=0; reason="could not read complete FIT extent"
    elif ! dumpimage -l "${full_fit}" >/dev/null 2>&1; then
      valid=0; reason="dumpimage rejected the full FIT extent"
    fi
  fi

  if (( valid == 1 )); then
    for image_index in "${!image_nodes[@]}"; do
      node="${image_nodes[$image_index]}"
      path="/images/${node}"
      expected_hashes=()
      hash_nodes=0
      children_out="$(fdtget -l "${metadata_fit}" "${path}" 2>/dev/null || true)"
      while IFS= read -r child; do
        [[ -n "${child}" ]] || continue
        [[ "${child}" == hash* ]] || continue
        hash_nodes=$((hash_nodes + 1))
        if (( hash_nodes > FIT_MAX_HASH_NODES )); then
          valid=0; reason="image '${node}' has more than ${FIT_MAX_HASH_NODES} hash nodes"; break
        fi
        hash_path="${path}/${child}"
        algo="$(fdtget -t s "${metadata_fit}" "${hash_path}" algo 2>/dev/null || true)"
        if [[ "${algo}" != sha256 ]]; then
          valid=0; reason="image '${node}' has unsupported hash algorithm '${algo:-missing}'"; break
        fi
        if ! expected="$(fit_sha256_property "${metadata_fit}" "${hash_path}" value)"; then
          valid=0; reason="image '${node}' has a malformed SHA-256 value"; break
        fi
        expected_hashes+=("${expected}")
      done <<<"${children_out}"
      (( valid == 1 )) || break
      if (( ${#expected_hashes[@]} == 0 )); then
        valid=0; reason="image '${node}' has no SHA-256 payload hash"; break
      fi

      if fit_has_property "${metadata_fit}" "${path}" data; then
        payload="${tmp}/payload-${image_index}.bin"
        if ! dumpimage -T flat_dt -p "${image_index}" -o "${payload}" \
            "${full_fit}" >/dev/null 2>&1; then
          valid=0; reason="could not extract embedded payload for image '${node}'"; break
        fi
        if ! actual="$(sha256sum "${payload}" | cut -d' ' -f1)"; then
          valid=0; reason="could not hash payload for image '${node}'"; break
        fi
      else
        data_size="$(fit_u32_property "${metadata_fit}" "${path}" data-size)"
        if fit_has_property "${metadata_fit}" "${path}" data-offset; then
          data_offset="$(fit_u32_property "${metadata_fit}" "${path}" data-offset)"
          payload_start=$((external_base + data_offset))
        else
          payload_start="$(fit_u32_property "${metadata_fit}" "${path}" data-position)"
        fi
        payload="${tmp}/payload-${image_index}.bin"
        if ! dd if="${full_fit}" of="${payload}" bs=1 skip="${payload_start}" \
            count="${data_size}" status=none 2>/dev/null; then
          valid=0; reason="could not read external payload for image '${node}'"; break
        fi
        if ! payload_bytes="$(stat -c %s "${payload}" 2>/dev/null)" \
            || [[ "${payload_bytes}" != "${data_size}" ]]; then
          valid=0; reason="short external payload read for image '${node}'"; break
        fi
        if ! actual="$(sha256sum "${payload}" | cut -d' ' -f1)"; then
          valid=0; reason="could not hash payload for image '${node}'"; break
        fi
      fi
      for expected in "${expected_hashes[@]}"; do
        if [[ "${actual}" != "${expected}" ]]; then
          valid=0; reason="image '${node}' payload hash mismatch"; break
        fi
      done
      (( valid == 1 )) || break
      verified_hashes=$((verified_hashes + ${#expected_hashes[@]}))
    done
  fi

  if (( valid == 1 )); then
    pass "Bootloader second-stage FIT: valid FDT header and extent at sector ${FIT_SECTOR}"
    info "FIT metadata=${metadata_size} bytes, full extent=${full_extent} bytes; ${verified_hashes} payload hash(es) verified"
  else
    fail "Bootloader second-stage FIT: valid FDT header and extent at sector ${FIT_SECTOR}"
    info "${reason}; magic='${got}' metadata=${metadata_size} available=${available_bytes}"
  fi
  rm -rf "${tmp}"
}

# ---------------------------------------------------------------------------
# Check 3 — Boot partition holds automatic and manual A/B scripts plus state.
# ---------------------------------------------------------------------------
check_boot_partition() {
  local img="$1" boot_off="$2"
  require_tool mdir || { fail "Boot partition: boot.scr + cera_board.env + boot_state.txt + recovery.scr"; return; }
  require_tool mtype || { fail "Boot partition: staged selector and board metadata"; return; }
  require_tool mcopy || { fail "Boot partition: staged selector and board metadata"; return; }
  require_tool mkimage || { fail "Boot partition: staged selector and board metadata"; return; }
  local f missing="" tmp script recovery board_env valid=1
  for f in boot.scr cera_board.env boot_state.txt recovery.scr; do
    mdir -i "${img}@@${boot_off}" "::/${f}" >/dev/null 2>&1 || missing="${missing} ${f}"
  done
  tmp="$(mktemp -d)"
  script="${tmp}/boot.scr"
  recovery="${tmp}/recovery.scr"
  mcopy -i "${img}@@${boot_off}" ::/boot.scr "${script}" >/dev/null 2>&1 || valid=0
  mcopy -i "${img}@@${boot_off}" ::/recovery.scr "${recovery}" >/dev/null 2>&1 || valid=0
  mkimage -l "${script}" 2>/dev/null | grep -q 'AArch64 Linux Script' || valid=0
  mkimage -l "${recovery}" 2>/dev/null | grep -q 'AArch64 Linux Script' || valid=0
  board_env="$(mtype -i "${img}@@${boot_off}" ::/cera_board.env 2>/dev/null || true)"
  grep -qx 'board_id=rock-5b-plus' <<<"${board_env}" || valid=0
  grep -qx 'fdtfile=rk3588-rock-5b-plus.dtb' <<<"${board_env}" || valid=0
  rm -rf "${tmp}"
  if [[ -z "${missing}" ]] && (( valid == 1 )); then
    pass "Boot partition: compiled AArch64 selector + Rock board metadata + recovery files"
    info "boot partition @ offset ${boot_off} — selector parses and board DTB metadata matches"
  else
    fail "Boot partition: compiled AArch64 selector + Rock board metadata + recovery files"
    [[ -z "${missing}" ]] || info "missing from boot partition @ offset ${boot_off}:${missing}"
    (( valid == 1 )) || info "boot.scr, recovery.scr, or Rock board metadata is malformed"
  fi
}

check_boot_state() {
  local img="$1" boot_off="$2" state
  require_tool mtype || { fail "Boot state: BOOT_ORDER=A B with positive A/B attempts"; return; }
  state="$(mtype -i "${img}@@${boot_off}" ::/boot_state.txt 2>/dev/null)"
  if grep -qx 'BOOT_ORDER=A B' <<<"${state}" \
      && grep -qE '^BOOT_A_LEFT=[1-3]$' <<<"${state}" \
      && grep -qE '^BOOT_B_LEFT=[1-3]$' <<<"${state}"; then
    pass "Boot state: BOOT_ORDER=A B with positive A/B attempts"
    info "$(grep -E '^BOOT_ORDER=|^BOOT_[AB]_LEFT=' <<<"${state}" | tr '\n' ' ')"
  else
    fail "Boot state: BOOT_ORDER=A B with positive A/B attempts"
    info "boot_state.txt: $(grep -E '^BOOT_ORDER=|^BOOT_[AB]_LEFT=' <<<"${state}" | tr '\n' ' ' || true)"
  fi
}

# ---------------------------------------------------------------------------
# Check 5 — RAUC bundle parses and is Compatible with this board.
# ---------------------------------------------------------------------------
check_rauc_bundle() {
  local bundle="$1" board="$2" keyring="$3" out compatible expect
  expect="ceralive-${board}"
  require_tool openssl || { fail "RAUC bundle: parses + Compatible '${expect}'"; return; }
  require_tool unsquashfs || { fail "RAUC bundle: parses + Compatible '${expect}'"; return; }
  [[ -s "${keyring}" ]] || { fail "RAUC bundle: parses + Compatible '${expect}'"; info "keyring not found: ${keyring}"; return; }
  if ! out="$(rauc_bundle_verify_and_compatible "${bundle}" "${keyring}" 2>&1)"; then
    fail "RAUC bundle: parses + Compatible '${expect}'"
    info "bundle signature/manifest verification failed: $(printf '%s' "${out}" | tail -1)"
    return
  fi
  compatible="$(printf '%s\n' "${out}" | tail -1)"
  if [[ "${compatible}" == "${expect}" ]]; then
    pass "RAUC bundle: parses + Compatible '${expect}'"
    info "Compatible: '${compatible}'; signature verified (check-purpose=codesign)"
  else
    fail "RAUC bundle: parses + Compatible '${expect}'"
    info "Compatible: '${compatible}' (expected '${expect}')"
  fi
}

# debugfs has no byte-offset flag and cannot seek a pipe, so each rootfs slot
# is sliced into a sparse temp file at its raw offset and inspected offline — no
# loop mount, no root. The slot is GREEN
# when the systemd init binary OR /sbin/init exists inside it.
# ---------------------------------------------------------------------------
check_rootfs_populated() {
  local img="$1" part="$2" label="$3" expected_keyring="$4" start_sector size_sectors tmp
  local fstab boot_mount='PARTLABEL=boot /boot vfat rw,nodev,nosuid,noexec,umask=0077,shortname=mixed,errors=remount-ro 0 2'
  require_tool sgdisk  || { fail "${label} populated + shared /boot mount present"; return; }
  require_tool debugfs || { fail "${label} populated + shared /boot mount present"; return; }
  require_tool fdtdump || { fail "${label} populated + kernel + board DTB + initrd + shared /boot mount"; return; }
  start_sector="$(sgdisk -i "${part}" "${img}" 2>/dev/null | sed -n 's/.*First sector: \([0-9]\+\).*/\1/p')"
  size_sectors="$(sgdisk -i "${part}" "${img}" 2>/dev/null | sed -n 's/.*Partition size: \([0-9]\+\).*/\1/p')"
  if [[ -z "${start_sector}" || -z "${size_sectors}" ]]; then
    fail "${label} populated + shared /boot mount present"
    info "could not read ${label} (partition ${part}) geometry from ${img}"
    return
  fi
  tmp="$(mktemp)"
  # conv=sparse keeps the slice ~rootfs-sized on disk despite the 4 GiB logical size.
  dd if="${img}" of="${tmp}" bs="${SECTOR}" skip="${start_sector}" count="${size_sectors}" \
    conv=sparse status=none 2>/dev/null
  local found=""
  local p
  for p in /usr/lib/systemd/systemd /sbin/init; do
    if debugfs -R "stat ${p}" "${tmp}" 2>/dev/null | grep -q 'Inode:'; then
      found="${p}"; break
    fi
  done
  fstab="$(debugfs -R 'cat /etc/fstab' "${tmp}" 2>/dev/null || true)"
  local artifacts_ok=1 artifact_dir kernel dtb initrd embedded_keyring kernel_magic dtb_magic initrd_magic
  artifact_dir="$(mktemp -d)"
  kernel="${artifact_dir}/Image"; dtb="${artifact_dir}/board.dtb"; initrd="${artifact_dir}/initrd.img"
  embedded_keyring="${artifact_dir}/ceralive-keyring.pem"
  debugfs -R "dump -p /boot/Image ${kernel}" "${tmp}" >/dev/null 2>&1 || artifacts_ok=0
  debugfs -R "dump -p /boot/dtb/rockchip/rk3588-rock-5b-plus.dtb ${dtb}" "${tmp}" >/dev/null 2>&1 || artifacts_ok=0
  debugfs -R "dump -p /boot/initrd.img ${initrd}" "${tmp}" >/dev/null 2>&1 || artifacts_ok=0
  debugfs -R "dump -p /etc/rauc/ceralive-keyring.pem ${embedded_keyring}" "${tmp}" >/dev/null 2>&1 || artifacts_ok=0
  kernel_magic="$(dd if="${kernel}" bs=1 skip=56 count=4 status=none 2>/dev/null | od -An -v -tx1 | tr -d ' \n')"
  dtb_magic="$(dd if="${dtb}" bs=1 count=4 status=none 2>/dev/null | od -An -v -tx1 | tr -d ' \n')"
  initrd_magic="$(dd if="${initrd}" bs=1 count=6 status=none 2>/dev/null | od -An -v -tx1 | tr -d ' \n')"
  [[ -f "${kernel}" && "$(stat -c %s "${kernel}" 2>/dev/null || echo 0)" -ge 8388608 && "${kernel_magic}" == 41524d64 ]] || artifacts_ok=0
  [[ -f "${dtb}" && "$(stat -c %s "${dtb}" 2>/dev/null || echo 0)" -ge 4096 && "${dtb_magic}" == d00dfeed ]] \
    && fdtdump "${dtb}" >/dev/null 2>&1 || artifacts_ok=0
  [[ -f "${initrd}" && "$(stat -c %s "${initrd}" 2>/dev/null || echo 0)" -ge 1048576 ]] || artifacts_ok=0
  initrd_is_coherent "${initrd}" "${initrd_magic}" || artifacts_ok=0
  [[ -s "${embedded_keyring}" ]] \
    && [[ "$(openssl x509 -in "${embedded_keyring}" -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1)" \
       == "$(openssl x509 -in "${expected_keyring}" -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1)" ]] \
    || artifacts_ok=0
  rm -rf "${artifact_dir}" "${tmp}"
  if [[ -n "${found}" ]] && grep -Fxq "${boot_mount}" <<<"${fstab}" && (( artifacts_ok == 1 )); then
    pass "${label} populated + kernel + board DTB + initrd + shared /boot mount"
    info "${label} (p${part} @ sector ${start_sector}): complete arm64 boot artifact set"
  else
    fail "${label} populated + kernel + board DTB + initrd + shared /boot mount"
    [[ -n "${found}" ]] || info "${label} (p${part} @ sector ${start_sector}) has no init"
    grep -Fxq "${boot_mount}" <<<"${fstab}" \
      || info "${label} lacks the explicit writable PARTLABEL=boot /boot mount"
    (( artifacts_ok == 1 )) || info "${label} lacks a coherent kernel + board DTB + initrd artifact set"
  fi
}

check_target_capacity() {
  local img="$1" target_bytes="$2" image_bytes
  image_bytes="$(stat -c '%s' "${img}")"
  if (( target_bytes >= image_bytes )); then
    pass "Target media capacity: ${target_bytes} bytes >= image ${image_bytes} bytes"
  else
    fail "Target media capacity: ${target_bytes} bytes < image ${image_bytes} bytes"
  fi
}

# require_tool <name> — return non-zero (and report) if a needed tool is absent.
require_tool() {
  command -v "$1" >/dev/null 2>&1 && return 0
  info "required tool not found on PATH: $1"
  return 1
}

initrd_is_coherent() {
  local initrd="$1" magic="$2" listing=""
  require_tool cpio || return 1
  case "${magic}" in
    1f8b*) require_tool gzip || return 1; listing="$(gzip -dc "${initrd}" 2>/dev/null | cpio -it 2>/dev/null)" ;;
    28b52ffd*) require_tool zstd || return 1; listing="$(zstd -q -dc "${initrd}" 2>/dev/null | cpio -it 2>/dev/null)" ;;
    fd377a585a00) require_tool xz || return 1; listing="$(xz -dc "${initrd}" 2>/dev/null | cpio -it 2>/dev/null)" ;;
    04224d18*) require_tool lz4 || return 1; listing="$(lz4 -q -dc "${initrd}" 2>/dev/null | cpio -it 2>/dev/null)" ;;
    303730373031|303730373032) listing="$(cpio -it <"${initrd}" 2>/dev/null)" ;;
    *) return 1 ;;
  esac
  grep -Eq '^\.?/?init$' <<<"${listing}"
}

run_gate() {
  local raw="$1" bundle="$2" board="$3" keyring="$4" gap_mb="$5" target_bytes="$6"
  local boot_off=$(( gap_mb * 1024 * 1024 ))
  FAILS=0

  echo "=============================================================="
  echo " CeraLive pre-flash verification gate — board ${board}"
  echo " image:   ${raw}"
  echo " bundle:  ${bundle}"
  echo " keyring: ${keyring}"
  echo "=============================================================="

  [[ -f "${raw}" ]]    || { fail "image present: ${raw}"; }
  [[ -f "${bundle}" ]] || { fail "bundle present: ${bundle}"; }
  if [[ -f "${raw}" ]]; then
    check_gpt_geometry "${raw}"
    check_gap_magic    "${raw}"
    check_second_stage_fit "${raw}"
    check_boot_partition "${raw}" "${boot_off}"
    check_boot_state     "${raw}" "${boot_off}"
    check_rootfs_populated "${raw}" 2 rootfs_a "${keyring}"
    check_rootfs_populated "${raw}" 3 rootfs_b "${keyring}"
    check_target_capacity "${raw}" "${target_bytes}"
  fi
  [[ -f "${bundle}" ]] && check_rauc_bundle "${bundle}" "${board}" "${keyring}"

  echo "--------------------------------------------------------------"
  if (( FAILS == 0 )); then
    echo "RESULT: PASS — pre-flash gate GREEN. Hardware bring-up AUTHORIZED."
  else
    echo "RESULT: FAIL — ${FAILS} sub-check(s) failed. DO NOT FLASH."
  fi
  echo "=============================================================="
  return "${FAILS}"
}

# ---------------------------------------------------------------------------
# self_test — negative / non-vacuity proof. Copy the image (sparse, cheap),
# zero the 16 MB gap, run the gate on the copy and assert the gap-magic
# sub-check FAILS. Exits 0 only when the corruption is correctly detected.
# ---------------------------------------------------------------------------
self_test() {
  local raw="$1" bundle="$2" board="$3" keyring="$4" gap_mb="$5" target_bytes="$6"
  [[ -f "${raw}" ]] || { echo "self-test: image not found: ${raw}" >&2; return 2; }
  local tmp corrupt
  tmp="$(mktemp -d)"
  corrupt="${tmp}/$(basename "${raw}").zeroed-gap"
  echo "### NEGATIVE TEST — zeroing the bootloader gap to prove the gate is not vacuous"
  echo "    source image : ${raw}"
  echo "    corrupt copy : ${corrupt}"
  cp --sparse=always "${raw}" "${corrupt}"
  # Wipe the RKNS idblock at sector 64 only — sectors 64..127 are inside the 16 MB
  # gap, so the GPT (sectors 0..33) and boot partition (sector 32768+) stay intact
  # and exactly ONE sub-check (gap magic) flips to FAIL.
  dd if=/dev/zero of="${corrupt}" bs="${SECTOR}" count=64 seek="${RKNS_SECTOR}" conv=notrunc status=none
  echo
  echo "--- gate output against the zeroed-gap image (expecting a gap-magic FAIL) ---"
  local out rc
  set +e
  out="$(run_gate "${corrupt}" "${bundle}" "${board}" "${keyring}" "${gap_mb}" "${target_bytes}")"
  rc=$?
  set -e
  printf '%s\n' "${out}"
  rm -rf "${tmp}"
  echo
  if printf '%s\n' "${out}" | grep -q '^\[FAIL\] Gap magic:' && (( rc != 0 )); then
    echo "NEGATIVE TEST PASS — zeroed gap was correctly REJECTED on the gap-magic check (gate is non-vacuous)."
    return 0
  fi
  echo "NEGATIVE TEST FAIL — zeroed gap was NOT rejected (gate would let a bootloader-less image through!)." >&2
  return 1
}

usage() { sed -n '2,44p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
  local image="" bundle="" board="rock-5b-plus" keyring="" gap_mb="${GAP_MB_DEFAULT}" target_size_bytes=""
  local mode="gate"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --image)     image="${2:-}"; shift 2 ;;
      --bundle)    bundle="${2:-}"; shift 2 ;;
      --board)     board="${2:-}"; shift 2 ;;
      --keyring)   keyring="${2:-}"; shift 2 ;;
      --gap-mb)    gap_mb="${2:-}"; shift 2 ;;
      --target-size-bytes) target_size_bytes="${2:-}"; shift 2 ;;
      --self-test) mode="self-test"; shift ;;
      -h|--help)   usage; exit 0 ;;
      *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
    esac
  done

  [[ -n "${keyring}" ]] || { echo "--keyring is required; production verification has no dev-key default" >&2; exit 2; }
  [[ -n "${image}" ]]   || image="$(newest_artifact "${board}" '*.raw')"
  [[ -n "${bundle}" ]]  || bundle="$(newest_artifact "${board}" '*.raucb')"
  [[ "${target_size_bytes}" =~ ^[1-9][0-9]*$ ]] \
    || { echo "--target-size-bytes is required and must be a positive integer" >&2; exit 2; }
  [[ -n "${image}" ]]   || { echo "no .raw found under ${IMAGES_DIR}/${board}/ — pass --image" >&2; exit 2; }
  [[ -n "${bundle}" ]]  || { echo "no .raucb found under ${IMAGES_DIR}/${board}/ — pass --bundle" >&2; exit 2; }

  case "${mode}" in
    gate)      run_gate  "${image}" "${bundle}" "${board}" "${keyring}" "${gap_mb}" "${target_size_bytes}" ;;
    self-test) self_test "${image}" "${bundle}" "${board}" "${keyring}" "${gap_mb}" "${target_size_bytes}" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
