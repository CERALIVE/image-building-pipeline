#!/usr/bin/env bats

@test "offline Debian replay rejects stale pins and accepts the exact native APT plan" {
  run python3 -B "${BATS_TEST_DIRNAME}/image_apt_replay_test.py"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}
