#!/usr/bin/env bats

@test "capsule transport enforces independent credential and BSP policies" {
  run python3 "${BATS_TEST_DIRNAME}/capsule_transport_policy_test.py"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

@test "host capsule producer uses fixture HTTPS and original archive authentication" {
  run python3 "${BATS_TEST_DIRNAME}/capsule_producer_test.py"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

@test "metadata discovery authenticates identities without package requests" {
  run python3 "${BATS_TEST_DIRNAME}/metadata_discovery_test.py"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

@test "source discovery authenticates every staged source file without payload requests" {
  run python3 "${BATS_TEST_DIRNAME}/source_discovery_test.py"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}
