#!/usr/bin/env bash
#
# kernel/checkout.sh — pinned source checkout with bounded retry and pin
# verification, for lib/build-kernel.sh.
#
# Sourced by lib/build-kernel.sh, never executed.
#
# BOTH functions here are ALSO the container's own checkout code: build-kernel.sh
# injects them into the containerized build with `declare -f`, so the retry /
# verify / publish loop the real build runs is byte-identical to the one the test
# suite drives against a stubbed git. That is why they take every input as a
# positional argument and read their knobs through `:-` fallbacks rather than the
# file-scope KERNEL_GIT_* defaults — inside the container there is no
# build-kernel.sh to have set them, only the -e forwarded environment. The two
# spellings of each default are pinned equal by tests/kernel-build-resilience.bats.
#
# shellcheck shell=bash

# ---------------------------------------------------------------------------
# fetch_pinned_tree_once <work> <url> <ref> <commit> <timeout> [mirror]
#
# ONE attempt at materialising a pinned tree in <work>. Three shapes, and the
# choice between them is the manifest's (plus the cache's), not a fallback:
#   mirror carries <commit> -> a local `git clone --shared` off the read-only
#                    bare mirror. NO network at all, and no object copy either:
#                    the clone records an alternates entry, so a 5 GB tree
#                    materialises in about the time it takes to write its refs.
#   ref non-empty -> `git clone --depth 1 --branch <ref>`
#   ref empty     -> commit-only source (the pinned branch publishes no tags, so
#                    there is no ref to clone). Inventing a tag would be a lie
#                    about provenance, and cloning the branch tip would silently
#                    build newer source under an unchanged pin.
#
# The mirror is consulted ONLY when the caller passes one AND it already holds
# the pinned commit — a mirror that has fallen behind the pin is a cache miss,
# never a reason to build something else, and the caller's own HEAD == commit
# assertion still runs either way. Callers that must stay fresh (the patch series
# and the kernel config) simply pass no mirror.
#
# Every network verb is wrapped in `timeout` — a git that has stopped making
# progress does not exit on its own. The local clone is wrapped too: a mirror on
# a wedged filesystem hangs exactly as thoroughly as a wedged remote.
# ---------------------------------------------------------------------------
fetch_pinned_tree_once() {
  local work="$1" url="$2" ref="$3" commit="$4" timeout_s="$5" mirror="${6:-}"

  if [ -n "${mirror}" ] && [ -d "${mirror}" ]; then
    if git -C "${mirror}" cat-file -e "${commit}^{commit}" 2>/dev/null; then
      echo "== mirror hit: ${commit} is already in ${mirror} — cloning locally, no network"
      timeout "${timeout_s}" git clone -q --shared --no-checkout "${mirror}" "${work}" || return 1
      timeout "${timeout_s}" git -C "${work}" checkout -q --detach "${commit}" || return 1
      return 0
    fi
    echo "== mirror miss: ${mirror} does not carry ${commit} — falling back to the network" >&2
  fi

  if [ -n "${ref}" ]; then
    timeout "${timeout_s}" git clone --depth 1 --branch "${ref}" "${url}" "${work}" || return 1
    return 0
  fi

  git init -q "${work}" || return 1
  git -C "${work}" remote add origin "${url}" || return 1
  timeout "${timeout_s}" git -C "${work}" fetch --depth 1 origin "${commit}" || return 1
  git -C "${work}" checkout -q FETCH_HEAD || return 1
}

# ---------------------------------------------------------------------------
# fetch_pinned_tree <dest> <url> <ref> <commit> <label> [mirror]
#
# Bounded retry around fetch_pinned_tree_once, then a pin assertion, then the
# publish. The ORDER of those three is the whole point:
#
#   1. Retry loop. Each attempt gets a private directory that is destroyed
#      BEFORE it runs, never merely after it fails — a tree half-written by a
#      killed clone turns attempt 2 into a deterministic "destination path
#      already exists" and makes one blip look like a total outage.
#   2. Pin assertion, OUTSIDE the loop. A wrong HEAD is not a transient
#      condition: the tag moved, or the SHA was orphaned by a squash-merge.
#      Retrying re-fetches the same wrong tree and then blames the network.
#   3. Publish. <dest> only ever appears once the tree at it is pin-verified, so
#      no later stage can read a partial or wrong checkout.
# ---------------------------------------------------------------------------
fetch_pinned_tree() {
  local dest="$1" url="$2" ref="$3" commit="$4" label="$5" mirror="${6:-}"
  local attempts="${CERALIVE_KERNEL_GIT_ATTEMPTS:-3}"
  local timeout_s="${CERALIVE_KERNEL_GIT_TIMEOUT:-1800}"
  local backoff="${CERALIVE_KERNEL_GIT_BACKOFF:-5}"
  local work="${dest}.attempt"
  local attempt=1 delay have

  rm -rf "${dest}"
  while : ; do
    rm -rf "${work}"
    if fetch_pinned_tree_once "${work}" "${url}" "${ref}" "${commit}" "${timeout_s}" "${mirror}"; then
      break
    fi
    rm -rf "${work}"
    if [ "${attempt}" -ge "${attempts}" ]; then
      echo "FATAL: ${label}: ${attempts} attempt(s) to obtain ${url} at ${ref:-${commit}} all failed" >&2
      return 1
    fi
    delay=$(( backoff * attempt ))
    echo "== ${label}: attempt ${attempt}/${attempts} failed, retrying in ${delay}s" >&2
    sleep "${delay}"
    attempt=$(( attempt + 1 ))
  done

  have="$(git -C "${work}" rev-parse HEAD)"
  if [ "${have}" != "${commit}" ]; then
    echo "FATAL: ${label} checked out ${have}, pinned commit is ${commit} — a moved ref or an orphaned SHA is permanent, so this is NOT retried" >&2
    rm -rf "${work}"
    return 1
  fi

  mv "${work}" "${dest}"
  echo "== ${label}: ${commit} verified in ${dest} (attempt ${attempt}/${attempts})"
}

# ===========================================================================
# THE PERSISTENT KERNEL-SOURCE MIRROR — everything below this line is HOST-SIDE
# ONLY and is deliberately NOT part of the `declare -f` injection above.
#
# The build re-downloaded the whole pinned kernel tree on every run. A shallow
# clone of the pin is still a few hundred MB, paid once per board per build, and
# `build --all` pays it per board in parallel. A bare mirror turns that into one
# download ever, plus an incremental fetch only when the pin actually moves.
#
# THREE THINGS HERE ARE LOAD-BEARING:
#
#   1. THE PER-MIRROR flock IS A CORRECTNESS FIX, NOT A SPEEDUP. lib/build-all.sh
#      runs boards CONCURRENTLY and every board resolves the same kernel pin, so
#      without a lock two `git fetch`es write one object store at once — which
#      git does not defend against and which leaves a corrupt mirror that then
#      fails every subsequent build until someone deletes it by hand. The lock is
#      per MIRROR (the resource), never per board or per caller: a lock name that
#      carries the caller's identity excludes nothing, which is the exact bug
#      tests/manifest-helpers.bash::serialize already shipped once.
#   2. FETCH UNDER THE LOCK, READ AFTERWARDS. The lock is released before the
#      builder container starts, and the container mounts the mirror READ-ONLY,
#      so a concurrent fetch by another board can only ADD objects while this
#      build reads. `gc.auto=0` is set at creation for the other half of that:
#      an automatic gc is the one git operation that would DELETE objects a
#      concurrent reader is using.
#   3. EVERY FAILURE IS NON-FATAL. The mirror is an optimisation, so an
#      unwritable cache dir, a lock timeout, a failed fetch or a pin the mirror
#      cannot supply all degrade to exactly the pre-mirror network path.
#
# MODE (CERALIVE_KERNEL_SRC_MIRROR): `auto` (default) uses a mirror that already
# exists and never creates one; `1` creates it; `0` disables it entirely. `auto`
# is the default because the payoff is strictly for a host that builds REPEATEDLY:
# mkosi/cache is on the CI cleanup allowlist, so an ephemeral runner pays the full
# mirror clone once per job and never reads it back — a guaranteed loss. Opting a
# long-lived builder in is one documented env var, once.
# ===========================================================================
# Every knob is read AT CALL TIME through a `:-` fallback, never latched into a
# file-scope variable at source time. Latching gives two spellings of one setting
# that agree only until something sets the env var after sourcing — which is both
# how a caller would reasonably use it and how a test would drive it.
kernel_src_mirror_mode() {
  printf '%s' "${CERALIVE_KERNEL_SRC_MIRROR:-auto}"
}

kernel_src_mirror_lock_timeout() {
  printf '%s' "${CERALIVE_KERNEL_SRC_MIRROR_LOCK_TIMEOUT:-3600}"
}

kernel_src_mirror_dir() {
  printf '%s' "${CERALIVE_KERNEL_SRC_MIRROR_DIR:-${PIPELINE_DIR}/${CERALIVE_REL_KERNEL_SRC_MIRROR_DIR}}"
}

# Published by kernel_src_mirror_prepare instead of echoed, because the caller
# needs BOTH the path and the reason it was or was not usable, and a command
# substitution would discard the second.
#
# shellcheck disable=SC2034  # read by lib/build-kernel.sh::main, not by this module
KERNEL_SRC_MIRROR_PATH=""
# shellcheck disable=SC2034  # ditto
KERNEL_SRC_MIRROR_BASIS=""

# kernel_src_mirror_has_commit <mirror> <commit>
kernel_src_mirror_has_commit() {
  git -C "$1" cat-file -e "${2}^{commit}" 2>/dev/null
}

# kernel_src_mirror_sync <mirror> <url> <commit> — create-or-update, under the
# lock the caller has already taken. Returns 0 only when the mirror holds
# <commit> afterwards.
kernel_src_mirror_sync() {
  local mirror="$1" url="$2" commit="$3"

  if [[ ! -d "${mirror}" ]]; then
    log_info "kernel source mirror: creating ${mirror} from ${url} (one-time full mirror clone)"
    git clone --mirror --quiet "${url}" "${mirror}" || return 1
    git -C "${mirror}" config gc.auto 0 || return 1
  fi

  # The commit is checked BEFORE any network verb: once the pin is in the mirror
  # there is nothing a fetch could add that this build needs, and skipping it is
  # what makes a repeat build touch the network zero times.
  if kernel_src_mirror_has_commit "${mirror}" "${commit}"; then
    return 0
  fi

  log_info "kernel source mirror: ${commit} absent — fetching ${url}"
  git -C "${mirror}" remote set-url origin "${url}" 2>/dev/null \
    || git -C "${mirror}" remote add origin "${url}" || return 1
  git -C "${mirror}" fetch --prune --quiet origin || return 1
  kernel_src_mirror_has_commit "${mirror}" "${commit}"
}

# kernel_src_mirror_prepare <url> <commit> — publish KERNEL_SRC_MIRROR_PATH (the
# host path to bind-mount, or empty) and KERNEL_SRC_MIRROR_BASIS (why).
kernel_src_mirror_prepare() {
  local url="${1:?kernel_src_mirror_prepare needs a url}"
  local commit="${2:?kernel_src_mirror_prepare needs a commit}"
  local mirror lock rc=0 mode timeout_s

  KERNEL_SRC_MIRROR_PATH=""
  KERNEL_SRC_MIRROR_BASIS=""
  mode="$(kernel_src_mirror_mode)"
  timeout_s="$(kernel_src_mirror_lock_timeout)"

  case "${mode}" in
    0|1|auto) ;;
    # Refused rather than guessed at, for the same reason
    # CERALIVE_KERNEL_BUILD_JOBS_FORCE is: a value silently read as "off" is an
    # operator who believes a cache is armed while it is not.
    *) die "CERALIVE_KERNEL_SRC_MIRROR must be 0, 1 or auto (got '${mode}')" ;;
  esac

  if [[ "${mode}" == "0" ]]; then
    KERNEL_SRC_MIRROR_BASIS="disabled by CERALIVE_KERNEL_SRC_MIRROR=0"
    return 1
  fi

  mirror="$(kernel_src_mirror_dir)"

  if [[ "${mode}" == "auto" && ! -d "${mirror}" ]]; then
    KERNEL_SRC_MIRROR_BASIS="no mirror at ${mirror}; CERALIVE_KERNEL_SRC_MIRROR=1 creates one (repeat builds then fetch no kernel source at all)"
    return 1
  fi

  if ! command -v flock >/dev/null 2>&1; then
    KERNEL_SRC_MIRROR_BASIS="flock(1) is unavailable, and an unlocked fetch into a shared mirror corrupts it"
    return 1
  fi
  if ! command -v git >/dev/null 2>&1; then
    KERNEL_SRC_MIRROR_BASIS="git is unavailable on the host"
    return 1
  fi

  lock="${mirror}.lock"
  if ! mkdir -p "$(dirname "${mirror}")" 2>/dev/null; then
    KERNEL_SRC_MIRROR_BASIS="cannot create $(dirname "${mirror}")"
    return 1
  fi

  (
    flock -w "${timeout_s}" 9 || exit 2
    kernel_src_mirror_sync "${mirror}" "${url}" "${commit}" || exit 3
  ) 9>"${lock}" || rc=$?

  case "${rc}" in
    0)
      # shellcheck disable=SC2034  # read by lib/build-kernel.sh::main
      KERNEL_SRC_MIRROR_PATH="${mirror}"
      KERNEL_SRC_MIRROR_BASIS="mirror ${mirror} carries ${commit}"
      log_info "kernel source mirror: ${KERNEL_SRC_MIRROR_BASIS}"
      return 0
      ;;
    2) KERNEL_SRC_MIRROR_BASIS="timed out after ${timeout_s}s waiting for ${lock}" ;;
    3) KERNEL_SRC_MIRROR_BASIS="mirror ${mirror} could not be brought to ${commit}" ;;
    *) KERNEL_SRC_MIRROR_BASIS="mirror preparation failed (rc=${rc})" ;;
  esac
  log_warn "kernel source mirror: ${KERNEL_SRC_MIRROR_BASIS} — falling back to a network clone"
  return 1
}
