#!/usr/bin/env bash
#
# tests/lib/assertions.sh — the ONE result-bookkeeping + assertion library for the
# repository's collecting shell harnesses (the `contract-test` shell profile, see
# docs/shell-profiles.md).
#
# WHY THIS EXISTS
#
# `PASS`/`FAIL` plus `ok`/`bad`/`assert_eq`/`assert_contains` were re-derived
# verbatim in the three A/B fallback + rollback harnesses:
#
#   mkosi/platform/boot/test-fallback.sh    (RK3588 offline fallback proof)
#   mkosi/platform/x86/test-x86-fallback.sh (x86/GRUB offline fallback proof)
#   tests/rauc-rollback.sh                  (live/mock RAUC rollback proof)
#
# rauc-rollback.sh even carried the comment "mirrors test-fallback.sh" over its
# copy. Three copies of a counter is how two of them silently drift into
# disagreeing about what a failure prints, which matters here because these are
# the harnesses that decide whether an A/B rollback works.
#
# CONTRACT — the output format is load-bearing, not cosmetic.
#
# Every function below emits BYTE-IDENTICAL text to the copies it replaced:
#   ok    -> '  ok   %s\n'   on stdout, PASS+1
#   bad   -> '  FAIL %s\n'   on stdout, FAIL+1
# Harness transcripts are captured as evidence and compared across runs, so a
# format change here is a change to every one of those transcripts. Do not
# "improve" the spacing.
#
# PROFILE — this file assumes the `contract-test` profile: `set -uo pipefail`
# WITHOUT `-e`. A collecting harness must reach its own footer and own its exit
# code (`[[ "${FAIL}" -eq 0 ]]`); an `-e` abort on the first failed assertion
# would report one defect and hide the rest. It therefore sets no shell options
# and installs no ERR trap of its own — sourcing it never changes the caller's
# shell mode.
#
# NOT CONSOLIDATED HERE, DELIBERATELY:
#   * tests/resolve.test.sh's `ok`/`bad` print 'PASS: %s' / 'FAIL: %s' and its
#     `assert_contains` takes a STRING haystack, not a FILE. Same names, different
#     contract and different transcript — folding it in would be a behaviour
#     change disguised as deduplication.
#   * tests/qemu-x86.sh and tests/realhw-smoke.sh route their counters through
#     lib/common.sh loggers (stderr, timestamped) rather than plain stdout.
#
# Usage:
#   source "<repo-root>/tests/lib/assertions.sh"
#
# shellcheck shell=bash

# Result bookkeeping. Declared here so a harness that sources this file does not
# need its own `PASS=0; FAIL=0` preamble; both stay ordinary globals so the
# harness footer can read them directly.
PASS=0
FAIL=0

# ok <description...>   — record a passing assertion.
ok() { printf '  ok   %s\n' "$*"; PASS=$((PASS + 1)); }

# bad <description...>  — record a failing assertion. NEVER exits: the harness
# owns its exit code so that one failure does not hide the remaining checks.
bad() { printf '  FAIL %s\n' "$*"; FAIL=$((FAIL + 1)); }

# assert_eq <desc> <expected> <actual> — exact string equality. The actual value
# is echoed on success because these harnesses are read as evidence transcripts:
# "ok slot after rollback (B)" is auditable, a bare "ok" is not.
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1 ($3)"; else bad "$1: expected '$2', got '$3'"; fi
}

# assert_contains <desc> <file> <needle> — FIXED-STRING (`grep -F`) search inside
# a FILE. Fixed-string is deliberate: the needles are literal U-Boot / GRUB script
# fragments full of `$`, `{`, `[` and `*`, which a regex search would silently
# mis-match.
assert_contains() {
  if grep -qF -- "$3" "$2"; then ok "$1"; else bad "$1: '$3' not in $2"; fi
}
