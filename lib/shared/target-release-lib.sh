#!/usr/bin/env bash
#
# target-release-lib.sh — the ONE reader for manifests/target-release.env.
#
# STANDALONE ON PURPOSE, exactly like log-lib.sh and args-lib.sh: it sets no
# shell options, installs no trap and sources nothing at file scope, so any of
# the three shell profiles in docs/shell-profiles.md can source it without
# inheriting strict mode or an ERR trap.
#
# WHAT IT ANSWERS: "which Debian suite, and which os-release VERSION_ID, does
# this image target?" — from the single source of truth, never from a literal.
#
# TWO READS, and the difference matters:
#
#   target_release_load     the EFFECTIVE values. Sources the env file into the
#                           caller and exports every key. Because the file is a
#                           `: "${KEY:=default}"` fragment, an already-set
#                           environment variable wins and the derived suites
#                           re-expand from it — an overridden RELEASE therefore
#                           yields ITS OWN -updates/-security siblings, never the
#                           mapping's. Idempotent and safe to call twice.
#
#   target_release_declared the value the FILE ITSELF declares, with the ambient
#                           environment scrubbed. This is what an audit or a
#                           lockstep check must compare a mirrored literal
#                           against — reading the effective value there would let
#                           an exported override mask a drifted mirror.
#
# There is deliberately NO literal-suite fallback anywhere in this library. A
# stale default builds a plausible image for the wrong release, which is exactly
# the class of defect the whole mapping exists to close; an unresolvable key is
# fatal, and the message names the path that was searched.
#
# shellcheck shell=bash

# Every key the env file defines, in the order it defines them — the later
# entries expand the earlier ones, so this order is also the export order.
TARGET_RELEASE_KEYS=(RELEASE OS_VERSION_ID APT_SUITE APT_SUITE_UPDATES APT_SUITE_SECURITY)

# ---------------------------------------------------------------------------
# target_release_env_file — echo the resolved path of the env file.
#
# CERALIVE_TARGET_RELEASE_ENV overrides it (the scratch-experiment / fixture
# hook); otherwise it resolves relative to THIS file, which lives at lib/shared/,
# so the pipeline root is two directories up.
# ---------------------------------------------------------------------------
target_release_env_file() {
  if [[ -n "${CERALIVE_TARGET_RELEASE_ENV:-}" ]]; then
    printf '%s\n' "${CERALIVE_TARGET_RELEASE_ENV}"
    return 0
  fi
  local here
  here="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)" || return 1
  printf '%s/manifests/target-release.env\n' "${here}"
}

# ---------------------------------------------------------------------------
# _target_release_fail <message> — fail closed through the caller's own reporter.
#
# Uses die() when the caller has one (every build-strict consumer does) so the
# message carries the pipeline's ERR trap and formatting; otherwise prints and
# exits, so a device-daemon or contract-test caller still stops rather than
# continuing with an empty suite.
# ---------------------------------------------------------------------------
_target_release_fail() {
  if declare -F die >/dev/null 2>&1; then
    die "$1"
  fi
  printf 'FATAL: %s\n' "$1" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# target_release_declared <KEY> — echo the value the ENV FILE declares.
#
# Runs under `env -i` so an exported RELEASE cannot mask what the file says. This
# is the read an audit/lockstep check wants; use target_release_load for the
# value a build should actually act on.
# ---------------------------------------------------------------------------
target_release_declared() {
  local key="${1:?target_release_declared needs a KEY}" file value
  file="$(target_release_env_file)" \
    || _target_release_fail "cannot resolve manifests/target-release.env (set CERALIVE_TARGET_RELEASE_ENV)"
  [[ -r "${file}" ]] \
    || _target_release_fail "target-release env file not readable: ${file}"
  value="$(env -i "PATH=${PATH}" bash -c 'set -eu; . "$1"; printf "%s" "${!2-}"' _ "${file}" "${key}")" \
    || _target_release_fail "target-release env file is not sourceable: ${file}"
  [[ -n "${value}" ]] \
    || _target_release_fail "${file} declares no value for ${key}"
  printf '%s\n' "${value}"
}

# ---------------------------------------------------------------------------
# target_release_load — set AND export every key in TARGET_RELEASE_KEYS.
#
# Sources the env file into the CALLER, which is what gives the environment-wins
# + re-derive semantics documented at the top. Fails closed when the file cannot
# be read, and again if any key came out empty (a truncated or edited-wrong file
# must not resolve to an empty suite).
# ---------------------------------------------------------------------------
target_release_load() {
  local file key
  file="$(target_release_env_file)" \
    || _target_release_fail "cannot resolve manifests/target-release.env (set CERALIVE_TARGET_RELEASE_ENV)"
  [[ -r "${file}" ]] \
    || _target_release_fail "target-release env file not readable: ${file} — the target suite/VERSION_ID has exactly one source of truth and it is missing"
  # shellcheck source=../../manifests/target-release.env
  . "${file}"
  for key in "${TARGET_RELEASE_KEYS[@]}"; do
    [[ -n "${!key-}" ]] \
      || _target_release_fail "${file} left ${key} empty — every target-release key must resolve to a non-empty value"
    export "${key?}"
  done
}
