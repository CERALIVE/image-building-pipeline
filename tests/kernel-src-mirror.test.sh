#!/usr/bin/env bash
#
# kernel-src-mirror.test.sh — the RUNTIME contract for the persistent kernel
# source mirror (lib/kernel/checkout.sh). Static wiring is pinned separately by
# tests/build-cache-overhaul.bats; this file executes the real shipped functions
# against real git repositories and a real flock.
#
# THE PROOF TECHNIQUE, because it is what makes the result unfakeable. A cache is
# only proven when the thing it caches CANNOT be obtained any other way. So every
# reuse leg here builds the mirror from an upstream repository and then DESTROYS
# that upstream before the checkout runs. A checkout that still succeeds cannot
# have gone to the network; a checkout that fails proves the leg was measuring
# something real. Both directions are asserted — the same run drives the
# no-mirror case against the same destroyed upstream and requires it to FAIL.
#
# LEGS
#   reuse         a mirror carrying the pin serves a checkout with the upstream gone
#   non-vacuity   the identical checkout WITHOUT the mirror fails
#   no re-clone   a second prepare against a warm mirror touches no remote at all
#   flock         a concurrent holder of the mirror lock BLOCKS prepare, and two
#                 real concurrent prepares leave an fsck-clean mirror
#   miss          a mirror that does not carry the pin is a cache miss, not a
#                 different build: the checkout falls back and the pin still holds
#   modes         0 / auto / 1 semantics, and a bogus value is refused
#
# Profile: contract-test (docs/shell-profiles.md) — `set -uo pipefail`, no -e, the
# harness owns its exit code so one failure cannot hide the rest.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"

# shellcheck source=tests/lib/assertions.sh
source "${HERE}/lib/assertions.sh"

echo "== kernel source mirror: runtime contract"

for tool in git flock; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "  SKIP ${tool} is unavailable — this suite drives the real thing or nothing"
    exit 0
  fi
done

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# prepare_result — run kernel_src_mirror_prepare in a subshell and bring BOTH its
# exit status and the KERNEL_SRC_MIRROR_BASIS it published back across.
#
# Capturing them separately does not work, and the failure is silent: a command
# substitution whose last statement is `printf "${BASIS}"` always exits 0, so a
# `basis="$(...)" || rc=$?` reads every miss as a success. The status has to
# travel INSIDE the captured value. (The globals themselves cannot cross a
# subshell at all, which is why prepare publishes them for its real caller and
# this helper re-serialises them for the test.)
#
# Sets: PREPARE_RC, PREPARE_BASIS.
prepare_result() {
  local out
  out="$(
    set -uo pipefail
    load_lib
    kernel_src_mirror_prepare "$@" >/dev/null 2>&1
    printf '%s|%s' "$?" "${KERNEL_SRC_MIRROR_BASIS}"
  )"
  PREPARE_RC="${out%%|*}"
  PREPARE_BASIS="${out#*|}"
}

# The library under test, loaded exactly as lib/build-kernel.sh loads it, into a
# shell carrying only the loggers and PIPELINE_DIR it reads.
load_lib() {
  # shellcheck source=lib/shared/log-lib.sh
  source "${PIPELINE_DIR}/lib/shared/log-lib.sh"
  die() { log_error "$*"; exit 1; }
  # shellcheck source=lib/paths.sh
  source "${PIPELINE_DIR}/lib/paths.sh"
  # shellcheck source=lib/kernel/checkout.sh
  source "${PIPELINE_DIR}/lib/kernel/checkout.sh"
}

# make_upstream <dir> -> echoes the HEAD commit
make_upstream() {
  local dir="$1"
  git init -q -b main "${dir}"
  git -C "${dir}" config user.email t@ceralive.tv
  git -C "${dir}" config user.name  "mirror test"
  printf 'obj-y += ceralive.o\n' >"${dir}/Makefile"
  git -C "${dir}" add -A
  git -C "${dir}" -c commit.gpgsign=false commit -q -m "kernel source fixture"
  git -C "${dir}" rev-parse HEAD
}

# ---------------------------------------------------------------------------
# 1. reuse: the mirror serves a checkout after the upstream is destroyed
# ---------------------------------------------------------------------------
UP="${WORK}/upstream"
COMMIT="$(make_upstream "${UP}")"
MIRROR="${WORK}/cache/kernel-src.git"

out="$(
  set -uo pipefail
  load_lib
  CERALIVE_KERNEL_SRC_MIRROR=1 \
  CERALIVE_KERNEL_SRC_MIRROR_DIR="${MIRROR}" \
    kernel_src_mirror_prepare "${UP}" "${COMMIT}" >/dev/null 2>&1 || exit 1
  printf 'ok'
)"
assert_eq "prepare creates the mirror when CERALIVE_KERNEL_SRC_MIRROR=1" "ok" "${out}"
[[ -d "${MIRROR}" ]] && ok "the mirror exists at the requested path" \
  || bad "no mirror at ${MIRROR}"
if git -C "${MIRROR}" cat-file -e "${COMMIT}^{commit}" 2>/dev/null; then
  ok "the mirror carries the pinned commit"
else
  bad "the mirror does not carry ${COMMIT}"
fi
assert_eq "automatic gc is disabled (it is the one op that would prune under a reader)" \
  "0" "$(git -C "${MIRROR}" config --get gc.auto)"

# Destroy the upstream. From here on, ANY success is the mirror's doing.
mv "${UP}" "${WORK}/upstream.gone"

dest="${WORK}/co-mirror"
rc=0
(
  set -uo pipefail
  load_lib
  fetch_pinned_tree "${dest}" "${UP}" "" "${COMMIT}" "kernel source" "${MIRROR}"
) >"${WORK}/mirror-hit.log" 2>&1 || rc=$?
assert_eq "a mirror-backed checkout succeeds with the upstream GONE" "0" "${rc}"
assert_contains "the checkout announces the mirror hit" "${WORK}/mirror-hit.log" "mirror hit"
assert_eq "the checked-out tree is at the pinned commit" \
  "${COMMIT}" "$(git -C "${dest}" rev-parse HEAD 2>/dev/null)"

# ---------------------------------------------------------------------------
# 2. non-vacuity: the SAME checkout without a mirror must fail
# ---------------------------------------------------------------------------
rc=0
(
  set -uo pipefail
  load_lib
  CERALIVE_KERNEL_GIT_ATTEMPTS=1 CERALIVE_KERNEL_GIT_BACKOFF=0 \
    fetch_pinned_tree "${WORK}/co-nomirror" "${UP}" "" "${COMMIT}" "kernel source" ""
) >/dev/null 2>&1 || rc=$?
if (( rc != 0 )); then
  ok "the same checkout WITHOUT the mirror fails — leg 1 measured the cache, not luck"
else
  bad "a mirror-less checkout of a destroyed upstream succeeded; leg 1 proves nothing"
fi

# ---------------------------------------------------------------------------
# 3. no re-clone: a warm mirror needs no remote at all
# ---------------------------------------------------------------------------
# The upstream is still gone, so a prepare that tried to fetch would fail. It must
# instead observe that the pin is already present and return without a network verb.
CERALIVE_KERNEL_SRC_MIRROR_DIR="${MIRROR}" CERALIVE_KERNEL_SRC_MIRROR=auto \
  prepare_result "${UP}" "${COMMIT}"
assert_eq "a second prepare against a warm mirror succeeds with no reachable remote" "0" "${PREPARE_RC}"
case "${PREPARE_BASIS}" in
  *"carries ${COMMIT}"*) ok "prepare reports the mirror already carries the pin" ;;
  *) bad "unexpected basis: '${PREPARE_BASIS}'" ;;
esac

# ---------------------------------------------------------------------------
# 4. the per-mirror flock
# ---------------------------------------------------------------------------
# 4a. an external holder BLOCKS prepare for as long as it holds the lock. This is
#     the property that makes concurrent board builds safe; without it two
#     `git fetch`es write one object store and corrupt it.
LOCK="${MIRROR}.lock"
flock -x "${LOCK}" sleep 2 &
holder=$!
sleep 0.3
start="$(date +%s%N)"
rc=0
(
  set -uo pipefail
  load_lib
  CERALIVE_KERNEL_SRC_MIRROR_DIR="${MIRROR}" CERALIVE_KERNEL_SRC_MIRROR=auto \
    kernel_src_mirror_prepare "${UP}" "${COMMIT}"
) >/dev/null 2>&1 || rc=$?
elapsed_ms=$(( ( $(date +%s%N) - start ) / 1000000 ))
wait "${holder}" 2>/dev/null
assert_eq "prepare still succeeds after waiting out the lock holder" "0" "${rc}"
if (( elapsed_ms >= 1200 )); then
  ok "prepare BLOCKED on the per-mirror lock (${elapsed_ms} ms behind a 2 s holder)"
else
  bad "prepare returned in ${elapsed_ms} ms while the mirror lock was held — it is not taking the lock"
fi

# 4b. a held lock plus a short timeout is a clean, non-fatal miss, not a hang.
flock -x "${LOCK}" sleep 3 &
holder=$!
sleep 0.3
CERALIVE_KERNEL_SRC_MIRROR_DIR="${MIRROR}" CERALIVE_KERNEL_SRC_MIRROR=auto \
CERALIVE_KERNEL_SRC_MIRROR_LOCK_TIMEOUT=1 \
  prepare_result "${UP}" "${COMMIT}"
kill "${holder}" 2>/dev/null; wait "${holder}" 2>/dev/null
assert_eq "a lock timeout is a MISS (non-zero), never a build failure" "1" "${PREPARE_RC}"
case "${PREPARE_BASIS}" in
  *"timed out"*) ok "the timeout is reported as the reason, not swallowed" ;;
  *) bad "a lock timeout produced basis '${PREPARE_BASIS}'" ;;
esac

# 4c. two REAL concurrent prepares against a cold mirror leave it intact. Without
#     the lock this is the shape that corrupts an object store.
UP2="${WORK}/upstream2"
COMMIT2="$(make_upstream "${UP2}")"
MIRROR2="${WORK}/cache/concurrent.git"
race() {
  (
    set -uo pipefail
    load_lib
    CERALIVE_KERNEL_SRC_MIRROR_DIR="${MIRROR2}" CERALIVE_KERNEL_SRC_MIRROR=1 \
      kernel_src_mirror_prepare "${UP2}" "${COMMIT2}"
  ) >/dev/null 2>&1
}
race & a=$!
race & b=$!
wait "${a}"; rc_a=$?
wait "${b}"; rc_b=$?
assert_eq "concurrent prepare A succeeded" "0" "${rc_a}"
assert_eq "concurrent prepare B succeeded" "0" "${rc_b}"
if git -C "${MIRROR2}" fsck --no-progress >/dev/null 2>&1; then
  ok "the mirror is fsck-clean after two concurrent prepares"
else
  bad "git fsck reports damage after two concurrent prepares"
fi

# ---------------------------------------------------------------------------
# 5. miss: a mirror without the pin is a cache miss, never a different build
# ---------------------------------------------------------------------------
UP3="${WORK}/upstream3"
make_upstream "${UP3}" >/dev/null
STALE="${WORK}/cache/stale.git"
git clone --mirror --quiet "${UP3}" "${STALE}"
# Advance the upstream past what the mirror holds.
printf 'obj-y += later.o\n' >>"${UP3}/Makefile"
git -C "${UP3}" add -A
git -C "${UP3}" -c commit.gpgsign=false commit -q -m "later"
NEWER="$(git -C "${UP3}" rev-parse HEAD)"

rc=0
(
  set -uo pipefail
  load_lib
  fetch_pinned_tree "${WORK}/co-miss" "${UP3}" "" "${NEWER}" "kernel source" "${STALE}"
) >"${WORK}/miss.log" 2>&1 || rc=$?
assert_eq "a mirror missing the pin falls back and still checks out" "0" "${rc}"
assert_contains "the miss is announced rather than silent" "${WORK}/miss.log" "mirror miss"
assert_eq "the fallback tree is at the pinned commit" \
  "${NEWER}" "$(git -C "${WORK}/co-miss" rev-parse HEAD 2>/dev/null)"

# And prepare BRINGS a stale mirror forward rather than declaring a miss.
rc=0
(
  set -uo pipefail
  load_lib
  CERALIVE_KERNEL_SRC_MIRROR_DIR="${STALE}" CERALIVE_KERNEL_SRC_MIRROR=auto \
    kernel_src_mirror_prepare "${UP3}" "${NEWER}"
) >/dev/null 2>&1 || rc=$?
assert_eq "prepare fetches a stale mirror forward to a moved pin" "0" "${rc}"

# ---------------------------------------------------------------------------
# 6. modes
# ---------------------------------------------------------------------------
CERALIVE_KERNEL_SRC_MIRROR_DIR="${MIRROR}" CERALIVE_KERNEL_SRC_MIRROR=0 \
  prepare_result "${UP}" "${COMMIT}"
assert_eq "mode 0 declines even when a usable mirror exists" "1" "${PREPARE_RC}"
case "${PREPARE_BASIS}" in
  *"disabled by"*) ok "mode 0 says why" ;;
  *) bad "mode 0 basis: '${PREPARE_BASIS}'" ;;
esac

ABSENT="${WORK}/cache/never-created.git"
rc=0
(
  set -uo pipefail
  load_lib
  CERALIVE_KERNEL_SRC_MIRROR_DIR="${ABSENT}" CERALIVE_KERNEL_SRC_MIRROR=auto \
    kernel_src_mirror_prepare "${UP}" "${COMMIT}"
) >/dev/null 2>&1 || rc=$?
assert_eq "mode auto declines when no mirror exists" "1" "${rc}"
if [[ -e "${ABSENT}" ]]; then
  bad "mode auto CREATED ${ABSENT}; an ephemeral runner would pay for a mirror it never reads"
else
  ok "mode auto creates nothing — the cost is opt-in, once, per long-lived host"
fi

rc=0
(
  set -uo pipefail
  load_lib
  CERALIVE_KERNEL_SRC_MIRROR_DIR="${MIRROR}" CERALIVE_KERNEL_SRC_MIRROR=yes \
    kernel_src_mirror_prepare "${UP}" "${COMMIT}"
) >/dev/null 2>&1 || rc=$?
if (( rc != 0 )); then
  ok "a bogus mode is REFUSED, never read as 'off'"
else
  bad "CERALIVE_KERNEL_SRC_MIRROR=yes was accepted"
fi

echo
printf 'kernel-src-mirror: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
