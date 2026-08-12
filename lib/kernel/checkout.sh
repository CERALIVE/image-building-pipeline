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
# fetch_pinned_tree_once <work> <url> <ref> <commit> <timeout>
#
# ONE attempt at materialising a pinned tree in <work>. Two shapes, and the
# choice between them is the manifest's, not a fallback:
#   ref non-empty -> `git clone --depth 1 --branch <ref>`
#   ref empty     -> commit-only source (the pinned branch publishes no tags, so
#                    there is no ref to clone). Inventing a tag would be a lie
#                    about provenance, and cloning the branch tip would silently
#                    build newer source under an unchanged pin.
#
# Every network verb is wrapped in `timeout` — a git that has stopped making
# progress does not exit on its own.
# ---------------------------------------------------------------------------
fetch_pinned_tree_once() {
  local work="$1" url="$2" ref="$3" commit="$4" timeout_s="$5"

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
# fetch_pinned_tree <dest> <url> <ref> <commit> <label>
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
  local dest="$1" url="$2" ref="$3" commit="$4" label="$5"
  local attempts="${CERALIVE_KERNEL_GIT_ATTEMPTS:-3}"
  local timeout_s="${CERALIVE_KERNEL_GIT_TIMEOUT:-1800}"
  local backoff="${CERALIVE_KERNEL_GIT_BACKOFF:-5}"
  local work="${dest}.attempt"
  local attempt=1 delay have

  rm -rf "${dest}"
  while : ; do
    rm -rf "${work}"
    if fetch_pinned_tree_once "${work}" "${url}" "${ref}" "${commit}" "${timeout_s}"; then
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
