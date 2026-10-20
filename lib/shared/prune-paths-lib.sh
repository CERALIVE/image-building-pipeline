#!/usr/bin/env bash
#
# shared/prune-paths-lib.sh — the SINGLE reader for manifests/prune-paths.list
# (Todo 29, update-system-overhaul). Every consumer of the prune-paths manifest
# — the generated runtime mkosi.local.conf RemoveFiles=, and the base64 content
# forwarded to the device — goes through these two pure functions so there is
# exactly one place that knows the file's comment/blank-line syntax.
#
# Sourced by lib/stages/mkosi.sh and lib/orchestrate.sh; not standalone.
# CERALIVE_PRUNE_PATHS_MANIFEST overrides the manifest path for tests.
#
# shellcheck shell=bash

# prune_paths_manifest_file — resolve the manifest path. PIPELINE_DIR is set by
# every caller in this codebase's entry points (orchestrate.sh, fetch-debs.sh);
# fall back to resolving relative to this file so a standalone `source` (e.g.
# from a test) still finds the real manifest without requiring the caller to
# export PIPELINE_DIR first.
prune_paths_manifest_file() {
  if [[ -n "${CERALIVE_PRUNE_PATHS_MANIFEST:-}" ]]; then
    printf '%s\n' "${CERALIVE_PRUNE_PATHS_MANIFEST}"
    return 0
  fi
  local here
  here="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s\n' "$(CDPATH='' cd -- "${here}/../.." && pwd)/manifests/prune-paths.list"
}

# prune_paths_read [file] — emit one glob per line, comments/blanks stripped.
# Trailing/leading whitespace on a glob line is trimmed so a stray space
# cannot silently produce a glob that matches nothing.
prune_paths_read() {
  local file="${1:-$(prune_paths_manifest_file)}"
  [[ -f "${file}" ]] || { printf 'prune-paths-lib: manifest not found: %s\n' "${file}" >&2; return 1; }
  local line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"   # trim leading whitespace
    line="${line%"${line##*[![:space:]]}"}"   # trim trailing whitespace
    [[ -n "${line}" ]] || continue
    case "${line}" in \#*) continue ;; esac
    printf '%s\n' "${line}"
  done <"${file}"
}

# prune_paths_csv [file] — the same globs, comma-joined (mkosi RemoveFiles=
# shape). Empty input yields an empty string, never a trailing/leading comma.
prune_paths_csv() {
  local file="${1:-$(prune_paths_manifest_file)}"
  local -a globs=()
  mapfile -t globs < <(prune_paths_read "${file}")
  (( ${#globs[@]} > 0 )) || { printf '\n'; return 0; }
  local IFS=,
  printf '%s\n' "${globs[*]}"
}
