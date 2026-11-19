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

@test "image profile transport uses Python stand-ins, never QEMU" {
  run python3 "${BATS_TEST_DIRNAME}/image_profile_test.py" --transport
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

@test "image profile ownership faults preserve descriptors and reap the child" {
  run python3 "${BATS_TEST_DIRNAME}/image_profile_test.py" --ownership
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

@test "image profile post-spawn failures reap VM and helper children" {
  run python3 "${BATS_TEST_DIRNAME}/image_profile_test.py" --process
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

@test "kernel runner preparation and registration helpers share child cleanup" {
  run python3 "${BATS_TEST_DIRNAME}/image_profile_test.py" --helper-process
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

@test "image launcher drains a lost spawn before terminal receipts" {
  run python3 "${BATS_TEST_DIRNAME}/image_profile_test.py" --lost-child
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

@test "image launcher fails closed on QEMU main path allocation faults" {
  run python3 "${BATS_TEST_DIRNAME}/image_profile_test.py" --qemu-memory
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

@test "image launcher fails closed on disk helper allocation faults" {
  run python3 "${BATS_TEST_DIRNAME}/image_profile_test.py" --disk-memory
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

@test "image profile shutdown signals preserve lifecycle guarantees" {
  run python3 "${BATS_TEST_DIRNAME}/image_profile_test.py" --shutdown
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

@test "image profile receipt faults preserve the committed outcome" {
  run python3 "${BATS_TEST_DIRNAME}/image_profile_test.py" --receipts
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

@test "image launcher retires the journal and retries commit after allocation faults" {
  run python3 "${BATS_TEST_DIRNAME}/image_profile_test.py" --finalization
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

@test "image launcher reaps at the blocked serial write boundary" {
  run python3 "${BATS_TEST_DIRNAME}/image_profile_test.py" --term-boundary
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

@test "image launcher retries tail I/O and releases owned directory descriptors" {
  run python3 "${BATS_TEST_DIRNAME}/image_profile_test.py" --tail-syscalls
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

@test "image launcher closes receipt descriptors after allocation faults" {
  run python3 "${BATS_TEST_DIRNAME}/image_profile_test.py" --receipt-fd-allocation
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

@test "image launcher preserves the receipt if terminal masking needs signal dispositions" {
  run python3 "${BATS_TEST_DIRNAME}/image_profile_test.py" --terminal-fallback
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

@test "image launcher prepares directories and recovers journal I/O" {
  run python3 "${BATS_TEST_DIRNAME}/image_profile_test.py" --attempt-preparation
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

@test "image launcher recovers I/O while preparing the active journal" {
  run python3 "${BATS_TEST_DIRNAME}/image_profile_test.py" --active-journal-preparation
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

@test "image launcher recovers I/O while preparing the started journal" {
  run python3 "${BATS_TEST_DIRNAME}/image_profile_test.py" --started-journal-preparation
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

@test "image validation retries positioned reads and tolerates unsupported durability" {
  run python3 "${BATS_TEST_DIRNAME}/image_profile_test.py" --read-and-sync
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

@test "image terminal publication shares one sync and readback budget" {
  run python3 "${BATS_TEST_DIRNAME}/image_profile_test.py" --terminal-io-budget
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

@test "image admission restarts store and priority observations" {
  run python3 "${BATS_TEST_DIRNAME}/image_profile_test.py" --admission-restart
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

@test "image profile pair publication and admission preserve lifecycle guarantees" {
  run python3 "${BATS_TEST_DIRNAME}/image_profile_test.py" --pair-and-admission
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
