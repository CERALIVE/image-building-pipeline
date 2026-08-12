#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFLASH="${HERE}/preflash-verify.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

for tool in mkimage dumpimage fdtget fdtput sha256sum; do
  command -v "${tool}" >/dev/null 2>&1 || {
    printf 'missing required FIT contract-test tool: %s\n' "${tool}" >&2
    exit 1
  }
done

DD_FAULT_MODE=""
dd() {
  local arg payload_read=0 full_copy=0 count_value=0
  local -a adjusted=()
  for arg in "$@"; do
    [[ "${arg}" == if=*/full.itb ]] && payload_read=1
    [[ "${arg}" == of=*/full.itb ]] && full_copy=1
  done
  if [[ "${DD_FAULT_MODE}" == read-error ]] && (( payload_read == 1 )); then
    command dd "$@"
    return 42
  fi
  if { [[ "${DD_FAULT_MODE}" == short-payload ]] && (( payload_read == 1 )); } \
      || { [[ "${DD_FAULT_MODE}" == short-extent ]] && (( full_copy == 1 )); }; then
    for arg in "$@"; do
      if [[ "${arg}" == count=* ]]; then
        count_value="${arg#count=}"
        adjusted+=("count=$((count_value - 1))")
      else
        adjusted+=("${arg}")
      fi
    done
    command dd "${adjusted[@]}"
    return 0
  fi
  command dd "$@"
}

HASH_FAULT_MODE=0
sha256sum() {
  if (( HASH_FAULT_MODE == 1 )); then
    return 42
  fi
  command sha256sum "$@"
}

truncate -s 8192 "${TMP}/payload.bin"
printf 'FIRSTPAYLOAD1234' |
  command dd of="${TMP}/payload.bin" bs=1 conv=notrunc status=none
truncate -s 4096 "${TMP}/payload-two.bin"
printf '\x52\x4f\x43\x4b\x35\x42\x2b\x21' |
  command dd of="${TMP}/payload-two.bin" bs=1 conv=notrunc status=none
cat >"${TMP}/external.its" <<'EOF'
/dts-v1/;
/ {
  description = "CeraLive external-data FIT contract";
  #address-cells = <1>;
  images {
    firmware {
      description = "U-Boot contract payload";
      data = /incbin/("payload.bin");
      type = "firmware";
      arch = "arm64";
      compression = "none";
      hash-1 { algo = "sha256"; };
    };
  };
  configurations {
    default = "conf";
    conf { firmware = "firmware"; };
  };
};
EOF
cat >"${TMP}/multi-embedded.its" <<'EOF'
/dts-v1/;
/ {
  description = "CeraLive multi-image embedded FIT contract";
  #address-cells = <1>;
  images {
    firmware-one {
      description = "first embedded payload";
      data = /incbin/("payload.bin");
      type = "firmware";
      arch = "arm64";
      compression = "none";
      hash-1 { algo = "sha256"; };
    };
    firmware-two {
      description = "second embedded payload";
      data = /incbin/("payload-two.bin");
      type = "firmware";
      arch = "arm64";
      compression = "none";
      hash-1 { algo = "sha256"; };
    };
  };
  configurations {
    default = "conf";
    conf {
      firmware = "firmware-one";
      loadables = "firmware-two";
    };
  };
};
EOF
payload_digest_bytes="$(sha256sum "${TMP}/payload.bin" | cut -d' ' -f1 | sed 's/../& /g')"
cat >"${TMP}/fake-hash.its" <<EOF
/dts-v1/;
/ {
  description = "CeraLive non-hash-child rejection contract";
  #address-cells = <1>;
  images {
    firmware {
      description = "payload with a fake digest child";
      data = /incbin/("payload.bin");
      type = "firmware";
      arch = "arm64";
      compression = "none";
      metadata {
        algo = "sha256";
        value = [${payload_digest_bytes}];
      };
    };
  };
  configurations {
    default = "conf";
    conf { firmware = "firmware"; };
  };
};
EOF
cat >"${TMP}/unsupported-hash.its" <<'EOF'
/dts-v1/;
/ {
  description = "CeraLive unsupported-hash rejection contract";
  #address-cells = <1>;
  images {
    firmware {
      description = "payload with mixed hash algorithms";
      data = /incbin/("payload.bin");
      type = "firmware";
      arch = "arm64";
      compression = "none";
      hash-1 { algo = "sha256"; };
      hash-2 { algo = "crc32"; };
    };
  };
  configurations {
    default = "conf";
    conf { firmware = "firmware"; };
  };
};
EOF
{
  printf '%s\n' '/dts-v1/;' '/ {' \
    '  description = "CeraLive image-count rejection contract";' \
    '  #address-cells = <1>;' '  images {'
  for index in $(seq 1 33); do
    printf '%s\n' \
      "    firmware-${index} {" \
      "      description = \"payload ${index}\";" \
      '      data = /incbin/("payload-two.bin");' \
      '      type = "firmware";' \
      '      arch = "arm64";' \
      '      compression = "none";' \
      '      hash-1 { algo = "sha256"; };' \
      '    };'
  done
  printf '%s\n' '  };' '  configurations {' '    default = "conf";' \
    '    conf { firmware = "firmware-1"; };' '  };' '};'
} >"${TMP}/too-many-images.its"

write_hash_count_its() {
  local file="$1" count="$2" index
  {
    printf '%s\n' '/dts-v1/;' '/ {' \
      '  description = "CeraLive hash-count contract";' \
      '  #address-cells = <1>;' '  images {' '    firmware {' \
      '      description = "payload with repeated SHA-256 hashes";' \
      '      data = /incbin/("payload.bin");' \
      '      type = "firmware";' '      arch = "arm64";' \
      '      compression = "none";'
    for index in $(seq 1 "${count}"); do
      printf '      hash-%s { algo = "sha256"; };\n' "${index}"
    done
    printf '%s\n' '    };' '  };' '  configurations {' \
      '    default = "conf";' '    conf { firmware = "firmware"; };' \
      '  };' '};'
  } >"${file}"
}

write_hash_count_its "${TMP}/two-hashes.its" 2
write_hash_count_its "${TMP}/too-many-hashes.its" 9
(cd "${TMP}" && mkimage -E -B 4 -f external.its external.itb >/dev/null)
(cd "${TMP}" && mkimage -E -B 4 -p 0x1000 -f external.its positioned.itb >/dev/null)
(cd "${TMP}" && mkimage -f external.its embedded.itb >/dev/null)
(cd "${TMP}" && mkimage -f multi-embedded.its multi-embedded.itb >/dev/null)
(cd "${TMP}" && mkimage -f fake-hash.its fake-hash.itb >/dev/null)
(cd "${TMP}" && mkimage -f unsupported-hash.its unsupported-hash.itb >/dev/null)
(cd "${TMP}" && mkimage -f too-many-images.its too-many-images.itb >/dev/null)
(cd "${TMP}" && mkimage -f two-hashes.its two-hashes.itb >/dev/null)
(cd "${TMP}" && mkimage -f too-many-hashes.its too-many-hashes.itb >/dev/null)

fit="${TMP}/external.itb"
fit_offset=$((16384 * 512))
metadata_hex="$(command dd if="${fit}" bs=1 skip=4 count=4 status=none | od -An -v -tx1 | tr -d ' \n')"
metadata_size=$((16#${metadata_hex}))
fit_size="$(stat -c %s "${fit}")"
data_offset="$(fdtget -t u "${fit}" /images/firmware data-offset)"
data_size="$(fdtget -t u "${fit}" /images/firmware data-size)"
payload_start=$((metadata_size + data_offset))
payload_end=$((payload_start + data_size))

(( metadata_size > 0 && metadata_size < 4096 ))
(( payload_end > metadata_size && payload_end <= fit_size ))

valid="${TMP}/valid.raw"
truncate -s $((fit_offset + fit_size)) "${valid}"
command dd if="${fit}" of="${valid}" bs=512 seek=16384 conv=notrunc status=none

# Source the production verifier so this focused contract invokes the same
# function that authorizes the hardware workflow without constructing a disk.
# shellcheck source=preflash-verify.sh
source "${PREFLASH}"

run_fit_check() {
  local image="$1"
  FAILS=0
  check_second_stage_fit "${image}"
}

raw_from_fit() {
  local fit_image="$1" raw_image="$2" fit_bytes
  fit_bytes="$(stat -c %s "${fit_image}")"
  truncate -s $((fit_offset + fit_bytes)) "${raw_image}"
  command dd if="${fit_image}" of="${raw_image}" bs=512 seek=16384 conv=notrunc status=none
}

expect_fit_failure() {
  local raw_image="$1" expected_reason="$2" output
  output="$(run_fit_check "${raw_image}")"
  printf '%s\n' "${output}"
  grep -Fq '[FAIL] Bootloader second-stage FIT:' <<<"${output}"
  grep -Fq "${expected_reason}" <<<"${output}"
}

valid_output="$(run_fit_check "${valid}")"
printf '%s\n' "${valid_output}"
grep -Fq '[PASS] Bootloader second-stage FIT:' <<<"${valid_output}"
grep -Fq "metadata=${metadata_size} bytes, full extent=${payload_end} bytes" <<<"${valid_output}"

positioned_fit="${TMP}/positioned.itb"
positioned_metadata_hex="$(command dd if="${positioned_fit}" bs=1 skip=4 count=4 status=none \
  | od -An -v -tx1 | tr -d ' \n')"
positioned_metadata_size=$((16#${positioned_metadata_hex}))
data_position="$(fdtget -t u "${positioned_fit}" /images/firmware data-position)"
positioned_data_size="$(fdtget -t u "${positioned_fit}" /images/firmware data-size)"
positioned_end=$((data_position + positioned_data_size))
positioned="${TMP}/positioned.raw"
truncate -s $((fit_offset + positioned_end)) "${positioned}"
command dd if="${positioned_fit}" of="${positioned}" bs=512 seek=16384 conv=notrunc status=none
positioned_output="$(run_fit_check "${positioned}")"
printf '%s\n' "${positioned_output}"
grep -Fq '[PASS] Bootloader second-stage FIT:' <<<"${positioned_output}"
grep -Fq "metadata=${positioned_metadata_size} bytes, full extent=${positioned_end} bytes" \
  <<<"${positioned_output}"

embedded_fit="${TMP}/embedded.itb"
embedded_size="$(stat -c %s "${embedded_fit}")"
embedded="${TMP}/embedded.raw"
truncate -s $((fit_offset + embedded_size)) "${embedded}"
command dd if="${embedded_fit}" of="${embedded}" bs=512 seek=16384 conv=notrunc status=none
embedded_output="$(run_fit_check "${embedded}")"
printf '%s\n' "${embedded_output}"
grep -Fq '[PASS] Bootloader second-stage FIT:' <<<"${embedded_output}"
grep -Fq "metadata=${embedded_size} bytes, full extent=${embedded_size} bytes" <<<"${embedded_output}"

multi_embedded_fit="${TMP}/multi-embedded.itb"
multi_embedded_size="$(stat -c %s "${multi_embedded_fit}")"
multi_embedded="${TMP}/multi-embedded.raw"
truncate -s $((fit_offset + multi_embedded_size)) "${multi_embedded}"
command dd if="${multi_embedded_fit}" of="${multi_embedded}" bs=512 seek=16384 conv=notrunc status=none
multi_embedded_output="$(run_fit_check "${multi_embedded}")"
printf '%s\n' "${multi_embedded_output}"
grep -Fq '[PASS] Bootloader second-stage FIT:' <<<"${multi_embedded_output}"
grep -Fq '2 payload hash(es) verified' <<<"${multi_embedded_output}"

multi_embedded_corrupt="${TMP}/multi-embedded-corrupt.raw"
cp "${multi_embedded}" "${multi_embedded_corrupt}"
first_payload_offset="$(LC_ALL=C grep -aobm1 'FIRSTPAYLOAD1234' "${multi_embedded_corrupt}" | cut -d: -f1)"
[[ "${first_payload_offset}" =~ ^[0-9]+$ ]]
printf '\xff' | command dd of="${multi_embedded_corrupt}" bs=1 seek="${first_payload_offset}" conv=notrunc status=none
multi_embedded_corrupt_output="$(run_fit_check "${multi_embedded_corrupt}")"
printf '%s\n' "${multi_embedded_corrupt_output}"
grep -Fq '[FAIL] Bootloader second-stage FIT:' <<<"${multi_embedded_corrupt_output}"
grep -Fq "image 'firmware-one' payload hash mismatch" <<<"${multi_embedded_corrupt_output}"

fake_hash_fit="${TMP}/fake-hash.itb"
fake_hash_size="$(stat -c %s "${fake_hash_fit}")"
fake_hash="${TMP}/fake-hash.raw"
truncate -s $((fit_offset + fake_hash_size)) "${fake_hash}"
command dd if="${fake_hash_fit}" of="${fake_hash}" bs=512 seek=16384 conv=notrunc status=none
fake_hash_output="$(run_fit_check "${fake_hash}")"
printf '%s\n' "${fake_hash_output}"
grep -Fq '[FAIL] Bootloader second-stage FIT:' <<<"${fake_hash_output}"
grep -Fq "image 'firmware' has no SHA-256 payload hash" <<<"${fake_hash_output}"

unsupported_hash_fit="${TMP}/unsupported-hash.itb"
unsupported_hash_size="$(stat -c %s "${unsupported_hash_fit}")"
unsupported_hash="${TMP}/unsupported-hash.raw"
truncate -s $((fit_offset + unsupported_hash_size)) "${unsupported_hash}"
command dd if="${unsupported_hash_fit}" of="${unsupported_hash}" bs=512 seek=16384 conv=notrunc status=none
unsupported_hash_output="$(run_fit_check "${unsupported_hash}")"
printf '%s\n' "${unsupported_hash_output}"
grep -Fq '[FAIL] Bootloader second-stage FIT:' <<<"${unsupported_hash_output}"
grep -Fq "image 'firmware' has unsupported hash algorithm 'crc32'" <<<"${unsupported_hash_output}"

two_hashes="${TMP}/two-hashes.raw"
raw_from_fit "${TMP}/two-hashes.itb" "${two_hashes}"
two_hashes_output="$(run_fit_check "${two_hashes}")"
printf '%s\n' "${two_hashes_output}"
grep -Fq '[PASS] Bootloader second-stage FIT:' <<<"${two_hashes_output}"
grep -Fq '2 payload hash(es) verified' <<<"${two_hashes_output}"

too_many_hashes="${TMP}/too-many-hashes.raw"
raw_from_fit "${TMP}/too-many-hashes.itb" "${too_many_hashes}"
expect_fit_failure "${too_many_hashes}" "image 'firmware' has more than 8 hash nodes"

cp "${TMP}/embedded.itb" "${TMP}/malformed-hash.itb"
fdtput -t bx "${TMP}/malformed-hash.itb" /images/firmware/hash-1 value 01
malformed_hash="${TMP}/malformed-hash.raw"
raw_from_fit "${TMP}/malformed-hash.itb" "${malformed_hash}"
expect_fit_failure "${malformed_hash}" "image 'firmware' has a malformed SHA-256 value"

cp "${TMP}/external.itb" "${TMP}/absent-location.itb"
fdtput -d "${TMP}/absent-location.itb" /images/firmware data-offset
absent_location="${TMP}/absent-location.raw"
raw_from_fit "${TMP}/absent-location.itb" "${absent_location}"
expect_fit_failure "${absent_location}" "image 'firmware' has an ambiguous external payload location"

cp "${TMP}/external.itb" "${TMP}/mixed-location.itb"
fdtput -t u "${TMP}/mixed-location.itb" /images/firmware data-position 4096
mixed_location="${TMP}/mixed-location.raw"
raw_from_fit "${TMP}/mixed-location.itb" "${mixed_location}"
expect_fit_failure "${mixed_location}" "image 'firmware' has an ambiguous external payload location"

cp "${TMP}/external.itb" "${TMP}/malformed-offset.itb"
fdtput -t s "${TMP}/malformed-offset.itb" /images/firmware data-offset nope
malformed_offset="${TMP}/malformed-offset.raw"
raw_from_fit "${TMP}/malformed-offset.itb" "${malformed_offset}"
expect_fit_failure "${malformed_offset}" "image 'firmware' has an invalid data-offset"

cp "${TMP}/external.itb" "${TMP}/malformed-position.itb"
fdtput -d "${TMP}/malformed-position.itb" /images/firmware data-offset
fdtput -t s "${TMP}/malformed-position.itb" /images/firmware data-position nope
malformed_position="${TMP}/malformed-position.raw"
raw_from_fit "${TMP}/malformed-position.itb" "${malformed_position}"
expect_fit_failure "${malformed_position}" "image 'firmware' has an invalid data-position"

cp "${TMP}/external.itb" "${TMP}/malformed-size.itb"
fdtput -t s "${TMP}/malformed-size.itb" /images/firmware data-size nope
malformed_size="${TMP}/malformed-size.raw"
raw_from_fit "${TMP}/malformed-size.itb" "${malformed_size}"
expect_fit_failure "${malformed_size}" "image 'firmware' has no bounded payload size"

cp "${TMP}/embedded.itb" "${TMP}/embedded-mixed.itb"
fdtput -t u "${TMP}/embedded-mixed.itb" /images/firmware data-offset 0
embedded_mixed="${TMP}/embedded-mixed.raw"
raw_from_fit "${TMP}/embedded-mixed.itb" "${embedded_mixed}"
expect_fit_failure "${embedded_mixed}" "image 'firmware' mixes embedded and external payload locations"

cp "${TMP}/external.itb" "${TMP}/over-budget.itb"
fdtput -t u "${TMP}/over-budget.itb" /images/firmware data-size "${FIT_MAX_BYTES}"
over_budget="${TMP}/over-budget.raw"
raw_from_fit "${TMP}/over-budget.itb" "${over_budget}"
expect_fit_failure "${over_budget}" "image 'firmware' payload extent exceeds 8388608-byte FIT budget"

invalid_metadata_size="${TMP}/invalid-metadata-size.raw"
cp "${valid}" "${invalid_metadata_size}"
printf '\x00\x00\x00\x27' | command dd of="${invalid_metadata_size}" bs=1 \
  seek=$((fit_offset + 4)) conv=notrunc status=none
expect_fit_failure "${invalid_metadata_size}" 'invalid FDT metadata size 39'

truncated_metadata="${TMP}/truncated-metadata.raw"
cp "${valid}" "${truncated_metadata}"
truncate -s $((fit_offset + metadata_size - 1)) "${truncated_metadata}"
expect_fit_failure "${truncated_metadata}" 'FDT metadata exceeds available FIT bytes'

too_many_fit="${TMP}/too-many-images.itb"
too_many_size="$(stat -c %s "${too_many_fit}")"
too_many="${TMP}/too-many-images.raw"
truncate -s $((fit_offset + too_many_size)) "${too_many}"
command dd if="${too_many_fit}" of="${too_many}" bs=512 seek=16384 conv=notrunc status=none
too_many_output="$(run_fit_check "${too_many}")"
printf '%s\n' "${too_many_output}"
grep -Fq '[FAIL] Bootloader second-stage FIT:' <<<"${too_many_output}"
grep -Fq 'FIT contains more than 32 image payloads' <<<"${too_many_output}"

corrupt="${TMP}/corrupt-payload.raw"
cp "${valid}" "${corrupt}"
printf '\xff' | command dd of="${corrupt}" bs=1 seek=$((fit_offset + payload_start)) conv=notrunc status=none
corrupt_output="$(run_fit_check "${corrupt}")"
printf '%s\n' "${corrupt_output}"
grep -Fq '[FAIL] Bootloader second-stage FIT:' <<<"${corrupt_output}"
grep -Fq 'payload hash mismatch' <<<"${corrupt_output}"

truncated="${TMP}/truncated-payload.raw"
cp "${valid}" "${truncated}"
truncate -s $((fit_offset + payload_end - 1)) "${truncated}"
truncated_output="$(run_fit_check "${truncated}")"
printf '%s\n' "${truncated_output}"
grep -Fq '[FAIL] Bootloader second-stage FIT:' <<<"${truncated_output}"
grep -Fq 'payload extent exceeds available FIT bytes' <<<"${truncated_output}"

# A reader that emits all requested bytes and then reports failure must never be
# treated as success merely because the resulting digest happens to match.
DD_FAULT_MODE=read-error
read_error_output="$(run_fit_check "${valid}")"
DD_FAULT_MODE=""
printf '%s\n' "${read_error_output}"
grep -Fq '[FAIL] Bootloader second-stage FIT:' <<<"${read_error_output}"
grep -Fq "could not read external payload for image 'firmware'" <<<"${read_error_output}"

# A successful short read is also a failure, independently of the later hash.
DD_FAULT_MODE=short-payload
short_payload_output="$(run_fit_check "${valid}")"
DD_FAULT_MODE=""
printf '%s\n' "${short_payload_output}"
grep -Fq '[FAIL] Bootloader second-stage FIT:' <<<"${short_payload_output}"
grep -Fq "short external payload read for image 'firmware'" <<<"${short_payload_output}"

# The complete FIT snapshot itself must be exactly the computed extent.
DD_FAULT_MODE=short-extent
short_extent_output="$(run_fit_check "${valid}")"
DD_FAULT_MODE=""
printf '%s\n' "${short_extent_output}"
grep -Fq '[FAIL] Bootloader second-stage FIT:' <<<"${short_extent_output}"
grep -Fq 'could not read complete FIT extent' <<<"${short_extent_output}"

HASH_FAULT_MODE=1
hash_error_output="$(run_fit_check "${valid}")"
HASH_FAULT_MODE=0
printf '%s\n' "${hash_error_output}"
grep -Fq '[FAIL] Bootloader second-stage FIT:' <<<"${hash_error_output}"
grep -Fq "could not hash payload for image 'firmware'" <<<"${hash_error_output}"

printf 'preflash external-data FIT extent/hash contract: PASS\n'
