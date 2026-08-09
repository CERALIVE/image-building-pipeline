#!/usr/bin/env bats
#
# build-kernel.sh resilience — the two ways a source-built kernel dies for
# reasons that have nothing to do with the kernel.
#
# WHY THIS FILE EXISTS. `[2b/9]` is invisible to the PR gate: that gate is
# `DRY_RUN=1` and never clones, never fetches and never runs `make`. So every
# property of the real stage has to be pinned by a static or synthetic guard
# here, the same way §26 of manifest.bats pins the olddefconfig/syncconfig
# ordering. Two failure modes are covered:
#
#   1. A TRANSIENT fetch failure that is made PERMANENT by our own debris. The
#      stage performs three network fetches back to back. A blip on any of them
#      used to abort a build that had already paid for the builder image, the
#      container and (for fetches 2 and 3) a multi-minute kernel checkout — and
#      the half-written tree it left behind at the destination turned every
#      manual re-run into a deterministic "destination path already exists".
#      The retry must therefore start each attempt from a directory it has just
#      destroyed, and it must publish nothing that has not verified.
#
#   2. A PIN MISMATCH quietly reclassified as a network problem. A moved tag or
#      a SHA orphaned by a squash-merge is PERMANENT. Retrying it re-fetches the
#      same wrong tree N times and then reports N failed attempts, which reads
#      as an outage and sends the next person looking at the wrong layer.
#
# Plus the preflight for the third way it dies: `make -j$(nproc)` OOM-killed on
# a core-rich, memory-thin host, half an hour in, after every pin has already
# been verified.
#
# Hardware-free, network-free and root-free: git is a stub on PATH, `timeout(1)`
# is the real one, and the memory figures come from fixture meminfo files.
#
# NOTE ON NEGATIVE ASSERTIONS. Every "must NOT be present" check below uses
# `run ! <cmd>`, never a bare `! <cmd>`. Bash exempts `!`-inverted commands from
# errexit, so a bare `! grep` that FINDS the forbidden pattern does not fail the
# test unless it happens to be the last command in the body — which makes the
# guard silently positional, and vacuous the moment a line is appended after it.

bats_require_minimum_version 1.5.0

setup() {
  TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  V2="$(cd "$TESTS_DIR/.." && pwd)"
  SCRIPT="$V2/lib/build-kernel.sh"
  WORK="$(mktemp -d)"
  STUB_BIN="$WORK/bin"
  GIT_STUB_DIR="$WORK/gitstub"
  PINNED_SHA="1111111111111111111111111111111111111111"
  MOVED_SHA="2222222222222222222222222222222222222222"
  mkdir -p "$STUB_BIN" "$GIT_STUB_DIR"
  printf '%s' "$PINNED_SHA" >"$GIT_STUB_DIR/head_sha"
  local knob
  for knob in fail_until partial_until sleep_until attempts; do
    printf '0' >"$GIT_STUB_DIR/$knob"
  done
  : >"$GIT_STUB_DIR/log"
  write_git_stub
}

teardown() {
  rm -rf "$WORK"
}

# --- fixtures ---------------------------------------------------------------

# A git that can be told to fail, to die half-written, or to hang — and that
# refuses a dirty destination exactly the way the real one does, so a retry
# landing in uncleaned debris FAILS the suite instead of passing by luck.
write_git_stub() {
  cat >"$STUB_BIN/git" <<'STUB'
#!/usr/bin/env bash
set -u
D="${GIT_STUB_DIR}"
ctl() { cat "$D/$1"; }
note() { printf '%s\n' "$*" >>"$D/log"; }
bump() {
  local n
  n=$(( $(cat "$D/attempts") + 1 ))
  printf '%s' "$n" >"$D/attempts"
  printf '%s' "$n"
}

repo=""
args=()
while [ $# -gt 0 ]; do
  if [ "$1" = "-C" ]; then repo="$2"; shift 2; else args+=("$1"); shift; fi
done
set -- ${args[@]+"${args[@]}"}
verb="${1:-}"
[ $# -eq 0 ] || shift

case "$verb" in
  clone)
    work=""
    for a in "$@"; do work="$a"; done
    n="$(bump)"
    if [ -e "$work" ] && [ -n "$(ls -A "$work" 2>/dev/null)" ]; then
      note "clone attempt=$n DIRTY $work"
      printf "fatal: destination path '%s' already exists and is not an empty directory.\n" "$work" >&2
      exit 128
    fi
    note "clone attempt=$n CLEAN $work"
    if [ "$n" -le "$(ctl sleep_until)" ]; then exec sleep 30; fi
    if [ "$n" -le "$(ctl partial_until)" ]; then
      mkdir -p "$work/.git"
      : >"$work/.git/index.lock"
      : >"$work/.git/partial.pack"
      echo 'fatal: the remote end hung up unexpectedly' >&2
      exit 128
    fi
    if [ "$n" -le "$(ctl fail_until)" ]; then
      echo 'fatal: could not read from remote repository' >&2
      exit 128
    fi
    mkdir -p "$work/.git"
    printf '%s' "$(ctl head_sha)" >"$work/.git/CERALIVE_HEAD"
    ;;
  init)
    work=""
    for a in "$@"; do case "$a" in -*) ;; *) work="$a" ;; esac; done
    mkdir -p "$work/.git"
    ;;
  remote|config|am) ;;
  fetch)
    n="$(bump)"
    if [ -e "$repo/.git/index.lock" ]; then
      note "fetch attempt=$n DIRTY $repo"
      printf "fatal: Unable to create '%s/.git/index.lock': File exists.\n" "$repo" >&2
      exit 128
    fi
    note "fetch attempt=$n CLEAN $repo"
    if [ "$n" -le "$(ctl sleep_until)" ]; then exec sleep 30; fi
    if [ "$n" -le "$(ctl partial_until)" ]; then
      : >"$repo/.git/index.lock"
      : >"$repo/.git/partial.pack"
      echo 'fatal: early EOF' >&2
      exit 128
    fi
    if [ "$n" -le "$(ctl fail_until)" ]; then
      echo 'fatal: could not read from remote repository' >&2
      exit 128
    fi
    printf '%s' "$(ctl head_sha)" >"$repo/.git/FETCH_HEAD_SHA"
    ;;
  checkout)
    printf '%s' "$(cat "$repo/.git/FETCH_HEAD_SHA")" >"$repo/.git/CERALIVE_HEAD"
    ;;
  rev-parse)
    cat "${repo:-.}/.git/CERALIVE_HEAD"
    ;;
  *)
    echo "git stub: unhandled verb '$verb'" >&2
    exit 2
    ;;
esac
exit 0
STUB
  chmod +x "$STUB_BIN/git"
}

write_nproc_stub() {
  printf '#!/bin/sh\necho %s\n' "$1" >"$STUB_BIN/nproc"
  chmod +x "$STUB_BIN/nproc"
}

write_meminfo() {
  local path="$WORK/meminfo" mib="$1"
  printf 'MemTotal:       %s kB\nMemAvailable:   %s kB\nSwapFree:       0 kB\n' \
    $(( mib * 1024 )) $(( mib * 1024 )) >"$path"
  printf '%s' "$path"
}

# Drive the real derive_kernel_build_jobs with a stubbed nproc and a fixture
# meminfo, so the arithmetic under test is the shipped one.
run_jobs() {
  local cores="$1" mem_mib="$2" meminfo
  write_nproc_stub "$cores"
  meminfo="$(write_meminfo "$mem_mib")"
  run env PATH="$STUB_BIN:$PATH" CERALIVE_RESOURCE_MEMINFO_FILE="$meminfo" \
    bash -c "source '$SCRIPT'; derive_kernel_build_jobs"
}

# Drive the real fetch_pinned_tree. BACKOFF defaults to 0 so a retry leg does
# not add real seconds to the suite; the backoff arithmetic itself is asserted
# separately from the log line.
run_fetch() {
  local dest="$1" ref="$2" commit="${3:-$PINNED_SHA}"
  run env PATH="$STUB_BIN:$PATH" GIT_STUB_DIR="$GIT_STUB_DIR" \
    CERALIVE_KERNEL_GIT_ATTEMPTS="${ATTEMPTS:-3}" \
    CERALIVE_KERNEL_GIT_TIMEOUT="${TIMEOUT:-30}" \
    CERALIVE_KERNEL_GIT_BACKOFF="${BACKOFF:-0}" \
    bash -c "source '$SCRIPT'; fetch_pinned_tree '$dest' https://example.invalid/r.git '$ref' '$commit' 'test tree'"
}

head_of() { cat "$1/.git/CERALIVE_HEAD"; }
attempt_count() { grep -c 'attempt=' "$GIT_STUB_DIR/log"; }

# The container script is a single-quoted literal, so it is extracted as text
# rather than executed — the same static-contract approach §26 uses.
container_script_body() {
  sed -n "/^  container_script=/,/^'\$/p" "$SCRIPT"
}

# ===========================================================================
# 1. Memory-aware build-job preflight.
# ===========================================================================

@test "build jobs: 64 GiB of MemAvailable on 8 cores uses all 8 cores" {
  run_jobs 8 65536
  [ "$status" -eq 0 ]
  [[ "$output" == *"8" ]]
  [[ "$output" == *"min(nproc=8"* ]]
}

@test "build jobs: 6 GiB of MemAvailable on 8 cores is capped at 3 by memory" {
  # The whole point of the preflight: 8 cores are available and using them
  # would OOM the builder.
  run_jobs 8 6144
  [ "$status" -eq 0 ]
  [[ "$output" == *"3" ]]
  [[ "$output" == *"= 3)"* ]]
}

@test "build jobs: CERALIVE_KERNEL_BUILD_JOBS=2 wins over a 64 GiB/8-core derivation" {
  write_nproc_stub 8
  local meminfo
  meminfo="$(write_meminfo 65536)"
  run env PATH="$STUB_BIN:$PATH" CERALIVE_RESOURCE_MEMINFO_FILE="$meminfo" \
    CERALIVE_KERNEL_BUILD_JOBS=2 \
    bash -c "source '$SCRIPT'; derive_kernel_build_jobs"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2" ]]
  [[ "$output" == *"override"* ]]
}

@test "build jobs: the override also wins UPWARD (memory alone would say 1)" {
  # "Unconditionally" has to include the direction the heuristic dislikes, or
  # an operator who has measured their own host cannot act on it.
  write_nproc_stub 8
  local meminfo
  meminfo="$(write_meminfo 512)"
  run env PATH="$STUB_BIN:$PATH" CERALIVE_RESOURCE_MEMINFO_FILE="$meminfo" \
    CERALIVE_KERNEL_BUILD_JOBS=16 \
    bash -c "source '$SCRIPT'; derive_kernel_build_jobs"
  [ "$status" -eq 0 ]
  [[ "$output" == *"16" ]]
}

@test "build jobs: the floor is 1 — a memory-starved host builds serially, not with -j0" {
  run_jobs 8 512
  [ "$status" -eq 0 ]
  [[ "$output" == *"1" ]]
  [[ "$output" != *"-j0"* ]]
}

@test "build jobs: the ceiling is nproc — spare memory buys no extra cores" {
  run_jobs 2 65536
  [ "$status" -eq 0 ]
  [[ "$output" == *"2" ]]
}

@test "build jobs: an unreadable MemAvailable falls back to nproc and SAYS SO" {
  # Silently inventing a memory figure would reintroduce the OOM default under
  # a name that claims to have prevented it.
  write_nproc_stub 8
  run env PATH="$STUB_BIN:$PATH" CERALIVE_RESOURCE_MEMINFO_FILE="$WORK/absent" \
    bash -c "source '$SCRIPT'; derive_kernel_build_jobs"
  [ "$status" -eq 0 ]
  [[ "$output" == *"8" ]]
  [[ "$output" == *"NO memory ceiling"* ]]
}

@test "build jobs: a non-numeric override is refused rather than silently ignored" {
  write_nproc_stub 8
  local meminfo
  meminfo="$(write_meminfo 65536)"
  run env PATH="$STUB_BIN:$PATH" CERALIVE_RESOURCE_MEMINFO_FILE="$meminfo" \
    CERALIVE_KERNEL_BUILD_JOBS=all \
    bash -c "source '$SCRIPT'; derive_kernel_build_jobs"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CERALIVE_KERNEL_BUILD_JOBS"* ]]
}

@test "build jobs: the derivation is LOGGED (an unexplained -j is unactionable)" {
  run_jobs 8 6144
  [ "$status" -eq 0 ]
  [[ "$output" == *"MemAvailable"* ]]
  [[ "$output" == *"floor 1, ceiling nproc"* ]]
}

# ===========================================================================
# 2. Bounded retry — transient failures.
# ===========================================================================

@test "retry: a transient failure is retried and the second attempt succeeds" {
  printf '1' >"$GIT_STUB_DIR/fail_until"
  run_fetch "$WORK/linux" v7.1.5
  [ "$status" -eq 0 ]
  [ -d "$WORK/linux" ]
  [ "$(head_of "$WORK/linux")" = "$PINNED_SHA" ]
  [ "$(attempt_count)" -eq 2 ]
  [[ "$output" == *"attempt 1/3 failed"* ]]
}

@test "retry: NON-VACUOUS — the same fixture with no retries left still fails" {
  # Without this leg a retry loop that silently swallowed the failure would
  # look identical to one that recovered from it.
  printf '1' >"$GIT_STUB_DIR/fail_until"
  ATTEMPTS=1 run_fetch "$WORK/linux" v7.1.5
  [ "$status" -ne 0 ]
  [ ! -e "$WORK/linux" ]
  [ "$(attempt_count)" -eq 1 ]
}

@test "retry: attempt 1 killed mid-clone leaves debris; attempt 2 starts CLEAN" {
  # The stub refuses a non-empty destination exactly as real git does, so if
  # the attempt directory were not destroyed first, attempt 2 would fail
  # deterministically and this test would go red.
  printf '1' >"$GIT_STUB_DIR/partial_until"
  run_fetch "$WORK/linux" v7.1.5
  [ "$status" -eq 0 ]
  [ -d "$WORK/linux" ]
  [ ! -e "$WORK/linux/.git/index.lock" ]
  [ "$(grep -c 'DIRTY' "$GIT_STUB_DIR/log")" -eq 0 ]
  [ "$(grep -c 'clone attempt=2 CLEAN' "$GIT_STUB_DIR/log")" -eq 1 ]
}

@test "retry: the same debris recovery holds for the commit-only fetch shape" {
  # The vendor BSP branch publishes no tags, so this shape is not a fallback —
  # it is how that whole variant is built, and its debris is a stale index.lock
  # inside an already-initialised repo rather than a non-empty clone target.
  printf '1' >"$GIT_STUB_DIR/partial_until"
  run_fetch "$WORK/patches" ""
  [ "$status" -eq 0 ]
  [ "$(head_of "$WORK/patches")" = "$PINNED_SHA" ]
  [ ! -e "$WORK/patches/.git/index.lock" ]
  [ "$(grep -c 'DIRTY' "$GIT_STUB_DIR/log")" -eq 0 ]
}

@test "retry: a stale attempt dir from an EARLIER run is removed before attempt 1" {
  # "Removed before the next try" has to mean before EVERY try, including the
  # first — otherwise an interrupted previous build poisons the next one.
  mkdir -p "$WORK/linux.attempt/.git"
  : >"$WORK/linux.attempt/.git/index.lock"
  : >"$WORK/linux.attempt/leftovers"
  run_fetch "$WORK/linux" v7.1.5
  [ "$status" -eq 0 ]
  [ "$(attempt_count)" -eq 1 ]
  [ "$(grep -c 'clone attempt=1 CLEAN' "$GIT_STUB_DIR/log")" -eq 1 ]
  [ ! -e "$WORK/linux/leftovers" ]
}

@test "retry: the budget is bounded and a total outage publishes nothing" {
  printf '99' >"$GIT_STUB_DIR/fail_until"
  run_fetch "$WORK/linux" v7.1.5
  [ "$status" -ne 0 ]
  [ "$(attempt_count)" -eq 3 ]
  [[ "$output" == *"3 attempt(s)"* ]]
  [ ! -e "$WORK/linux" ]
  [ ! -e "$WORK/linux.attempt" ]
}

@test "retry: debris from the FINAL failed attempt is not left behind either" {
  # Distinct from the pre-attempt cleanup: here EVERY attempt dies half-written,
  # so the last one has no successor to tidy up after it and the failed stage
  # would otherwise hand the operator a corrupt tree next to the real path.
  printf '99' >"$GIT_STUB_DIR/partial_until"
  run_fetch "$WORK/linux" v7.1.5
  [ "$status" -ne 0 ]
  [ "$(attempt_count)" -eq 3 ]
  [ ! -e "$WORK/linux" ]
  [ ! -e "$WORK/linux.attempt" ]
}

@test "retry: a hung fetch is bounded by timeout(1), and the next attempt succeeds" {
  # An unbounded git that has stopped making progress does not exit on its own;
  # this is the leg that proves the wrapper is real and not decorative.
  printf '1' >"$GIT_STUB_DIR/sleep_until"
  TIMEOUT=1 run_fetch "$WORK/linux" v7.1.5
  [ "$status" -eq 0 ]
  [ "$(attempt_count)" -eq 2 ]
  [ "$(head_of "$WORK/linux")" = "$PINNED_SHA" ]
}

@test "retry: the backoff grows with the attempt number" {
  printf '2' >"$GIT_STUB_DIR/fail_until"
  BACKOFF=1 run_fetch "$WORK/linux" v7.1.5
  [ "$status" -eq 0 ]
  [[ "$output" == *"attempt 1/3 failed, retrying in 1s"* ]]
  [[ "$output" == *"attempt 2/3 failed, retrying in 2s"* ]]
}

# ===========================================================================
# 3. Pin mismatch — permanent, never retried, never published.
# ===========================================================================

@test "retry: a PIN MISMATCH fails IMMEDIATELY and is never retried" {
  # A moved tag or a squash-merge-orphaned SHA is a permanent fact about the
  # remote. Retrying it fetches the same wrong tree three times and reports a
  # network problem, sending the next person to the wrong layer entirely.
  printf '%s' "$MOVED_SHA" >"$GIT_STUB_DIR/head_sha"
  run_fetch "$WORK/linux" v7.1.5 "$PINNED_SHA"
  [ "$status" -ne 0 ]
  [ "$(attempt_count)" -eq 1 ]
  [[ "$output" == *"pinned commit is $PINNED_SHA"* ]]
  [[ "$output" == *"NOT retried"* ]]
  [[ "$output" != *"retrying in"* ]]
}

@test "retry: a pin mismatch publishes NOTHING — no dest, no attempt debris" {
  printf '%s' "$MOVED_SHA" >"$GIT_STUB_DIR/head_sha"
  run_fetch "$WORK/linux" v7.1.5 "$PINNED_SHA"
  [ "$status" -ne 0 ]
  [ ! -e "$WORK/linux" ]
  [ ! -e "$WORK/linux.attempt" ]
}

@test "retry: a pre-existing dest is never left standing by a failed fetch" {
  # A stale tree at the destination would be read by every later stage as if it
  # were the pinned one.
  mkdir -p "$WORK/linux/.git"
  printf '%s' "$MOVED_SHA" >"$WORK/linux/.git/CERALIVE_HEAD"
  printf '99' >"$GIT_STUB_DIR/fail_until"
  run_fetch "$WORK/linux" v7.1.5
  [ "$status" -ne 0 ]
  [ ! -e "$WORK/linux" ]
}

@test "retry: the tagged and commit-only shapes each use their own git verb" {
  run_fetch "$WORK/linux" v7.1.5
  [ "$status" -eq 0 ]
  [ "$(grep -c '^clone ' "$GIT_STUB_DIR/log")" -eq 1 ]
  [ "$(grep -c '^fetch ' "$GIT_STUB_DIR/log")" -eq 0 ]

  : >"$GIT_STUB_DIR/log"
  printf '0' >"$GIT_STUB_DIR/attempts"
  run_fetch "$WORK/patches" ""
  [ "$status" -eq 0 ]
  [ "$(grep -c '^fetch ' "$GIT_STUB_DIR/log")" -eq 1 ]
  [ "$(grep -c '^clone ' "$GIT_STUB_DIR/log")" -eq 0 ]
}

# ===========================================================================
# 4. Wiring — the shipped stage really uses all of the above.
# ===========================================================================

@test "wiring: all THREE container git fetches go through fetch_pinned_tree" {
  local body dests
  body="$(container_script_body)"
  [ -n "$body" ]
  dests="$(grep -oE '^ *fetch_pinned_tree /src/[a-z]+' <<<"$body" | awk '{print $2}' | sort -u)"
  [ "$dests" = "$(printf '/src/kconfig\n/src/linux\n/src/patches')" ]
  # /src/linux has TWO call sites, not two fetches: the tagged clone and the
  # commit-only fetch are the mutually exclusive branches of one checkout.
  [ "$(grep -c '^ *fetch_pinned_tree /src/linux ' <<<"$body")" -eq 2 ]
}

@test "wiring: no raw clone/fetch/init survives inside the container script" {
  # A fourth fetch added later must not quietly bypass the retry+verify path.
  local body
  body="$(container_script_body)"
  run ! grep -Eq '(^|[^_[:alnum:]])git (clone|fetch|init)([[:space:]]|$)' <<<"$body"
}

@test "wiring: the helper is INJECTED, so shipped and tested code are the same text" {
  grep -Fq 'container_script="$(declare -f fetch_pinned_tree_once fetch_pinned_tree)' "$SCRIPT"
  grep -Fq 'bash -euo pipefail -c "${container_script}"' "$SCRIPT"
}

@test "wiring: the ASSEMBLED container script is valid bash" {
  # The script the container runs is now a concatenation of `declare -f` output
  # and a quoted literal, so a syntax error in either half would surface only on
  # a real (non-DRY_RUN) build — the one path CI never takes.
  local body fns literal
  body="$(container_script_body)"
  [ "$(sed -n '2p' <<<"$body")" = "\"'" ]
  [ "$(tail -n 1 <<<"$body")" = "'" ]
  fns="$(bash -c "source '$SCRIPT'; declare -f fetch_pinned_tree_once fetch_pinned_tree")"
  literal="$(sed '1,2d;$d' <<<"$body")"
  printf '%s\n%s\n' "$fns" "$literal" >"$WORK/assembled.sh"
  run bash -n "$WORK/assembled.sh"
  [ "$status" -eq 0 ]
  grep -q 'make olddefconfig' "$WORK/assembled.sh"
  grep -q 'fetch_pinned_tree_once' "$WORK/assembled.sh"
}

@test "wiring: the retry knobs reach the container" {
  local knob
  for knob in ATTEMPTS TIMEOUT BACKOFF; do
    grep -Fq -- "-e \"CERALIVE_KERNEL_GIT_${knob}=\${KERNEL_GIT_${knob}}\"" "$SCRIPT"
  done
}

@test "wiring: the file-scope knob defaults agree with the helper's own fallbacks" {
  # The helper carries `:-` fallbacks so it can run standalone, which means the
  # default exists twice. Compare the two rather than restating either here.
  local knob raw uniq
  for knob in ATTEMPTS TIMEOUT BACKOFF; do
    raw="$(grep -c "CERALIVE_KERNEL_GIT_${knob}:-" "$SCRIPT")"
    (( raw >= 2 ))
    uniq="$(grep -o "CERALIVE_KERNEL_GIT_${knob}:-[0-9]\+" "$SCRIPT" | sort -u | wc -l)"
    [ "$uniq" -eq 1 ]
  done
}

@test "wiring: build jobs are derived BEFORE they are planned or handed to make" {
  local derive plan pass
  derive="$(grep -n 'KERNEL_BUILD_JOBS="\$(derive_kernel_build_jobs)"' "$SCRIPT" | cut -d: -f1)"
  plan="$(grep -n 'DRY-RUN would run: make -j\${KERNEL_BUILD_JOBS}' "$SCRIPT" | cut -d: -f1)"
  pass="$(grep -n -- '-e "BUILD_JOBS=\${KERNEL_BUILD_JOBS}"' "$SCRIPT" | cut -d: -f1)"
  [ "$(printf '%s\n' "$derive" | wc -l)" -eq 1 ]
  (( derive < plan ))
  (( derive < pass ))
}

@test "wiring: nothing computes a build-job count at source time any more" {
  # The old file-scope `nproc` assignment sampled a number that had nothing to
  # do with when `make` runs, and skipped the memory ceiling entirely.
  run ! grep -Eq '^KERNEL_BUILD_JOBS=.*nproc' "$SCRIPT"
  grep -Fq 'KERNEL_BUILD_JOBS=""' "$SCRIPT"
}
