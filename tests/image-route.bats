#!/usr/bin/env bats

@test "single-board x86 dry-run succeeds without PKI in either build mode" {
  for mode in production development; do
    run env -i PATH="${PATH}" HOME="${BATS_TEST_TMPDIR}" TMPDIR="${BATS_TEST_TMPDIR}" \
      CERALIVE_BUILD_MODE="${mode}" CERALIVE_APT_PROXY=off CERALIVE_BUILD_LOCK_TIMEOUT=0 \
      DRY_RUN=1 "${BATS_TEST_DIRNAME}/../build" x86-minipc
    printf '%s\n' "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN complete: board='x86-minipc' (x86-64)"* ]]
  done
}

@test "single-board x86 dry-run never accesses configured PKI paths" {
  local pki="${BATS_TEST_TMPDIR}/unused-pki" trace="${BATS_TEST_TMPDIR}/pki.trace"
  mkdir "${pki}"
  for mode in production development; do
    run env -i PATH="${PATH}" HOME="${BATS_TEST_TMPDIR}" TMPDIR="${BATS_TEST_TMPDIR}" \
      CERALIVE_BUILD_MODE="${mode}" CERALIVE_APT_PROXY=off CERALIVE_BUILD_LOCK_TIMEOUT=0 \
      CERALIVE_RAUC_PKI_DIR="${pki}" RAUC_KEYRING_FILE="${pki}/device-root.pem" \
      DRY_RUN=1 MKOSI_NATIVE=1 strace -f -qq -e trace=%file -o "${trace}" \
      "${BATS_TEST_DIRNAME}/../build" x86-minipc
    printf '%s\n' "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN complete: board='x86-minipc' (x86-64)"* ]]
    run grep -F -- "${pki}" "${trace}"
    [ "$status" -eq 1 ]
  done
}

@test "single-board x86 non-dry-run still fails closed without PKI" {
  run env -i PATH="${PATH}" HOME="${BATS_TEST_TMPDIR}" TMPDIR="${BATS_TEST_TMPDIR}" \
    CERALIVE_BUILD_MODE=production DRY_RUN=0 \
    "${BATS_TEST_DIRNAME}/../build" x86-minipc
  printf '%s\n' "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"production RAUC PKI requires explicit CERALIVE_RAUC_PKI_DIR and RAUC_KEYRING_FILE"* ]]
  [[ "$output" != *"[1/9]"* ]]
}

@test "image artifact stream contracts need no privileged tools" {
  run python3 "${BATS_TEST_DIRNAME}/image_route_test.py"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

@test "image profile lifecycle uses Python stand-ins, never QEMU" {
  run python3 "${BATS_TEST_DIRNAME}/image_profile_test.py" --lifecycle
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

@test "image profile startup normalizes inherited process state before spawning" {
  run python3 "${BATS_TEST_DIRNAME}/image_profile_test.py" --startup
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

@test "sealed input import preserves original authentication and identity gates" {
  run python3 "${BATS_TEST_DIRNAME}/sealed_inputs_test.py"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

@test "rootfs measurement remains separate from normal signer-required builds" {
  run python3 "${BATS_TEST_DIRNAME}/rootfs_measurement_test.py"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

@test "parity inspects executable metadata when noexec denies execution access" {
  run python3 "${BATS_TEST_DIRNAME}/parity_noexec_test.py"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

@test "bootstrap metadata validity is enforced before mirror delivery" {
  run python3 "${BATS_TEST_DIRNAME}/bootstrap_metadata_test.py"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}
