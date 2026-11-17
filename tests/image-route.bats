#!/usr/bin/env bats

@test "image artifact stream contracts need no privileged tools" {
  run python3 "${BATS_TEST_DIRNAME}/image_route_test.py"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

@test "image profile lifecycle uses Python stand-ins, never QEMU" {
  run python3 "${BATS_TEST_DIRNAME}/image_profile_test.py"
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
