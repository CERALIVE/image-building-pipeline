#!/usr/bin/env bats

@test "host capsule producer uses fixture HTTPS and original archive authentication" {
  run python3 "${BATS_TEST_DIRNAME}/capsule_producer_test.py"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}
