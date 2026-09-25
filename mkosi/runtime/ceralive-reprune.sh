#!/bin/bash
#
# ceralive-reprune.sh — re-apply manifests/prune-paths.list after every future
# apt transaction (Todo 29, update-system-overhaul).
#
# WHY THIS EXISTS: the build-time prune (mkosi RemoveFiles= generated from
# manifests/prune-paths.list, plus the app layer's own deferred payload strip)
# is a ONE-TIME action. A later apt transaction — once apt-all-packages
# capability lands (Todo 35), or even a first-party package reinstall today —
# can reintroduce a pruned path (e.g. locale files shipped by a newly upgraded
# dependency). This script is installed as an apt DPkg::Post-Invoke hook
# (/etc/apt/apt.conf.d/80ceralive-reprune) so every future transaction is
# followed by the SAME prune, keeping the build-time decision durable "across
# upgrades" rather than a one-off.
#
# TWO PASSES:
#   1. glob removal — every non-comment, non-blank line of
#      /usr/lib/ceralive/prune-paths.list (the on-device copy of the manifest;
#      see that file's own header for the single-source design), `rm -rf`'d.
#   2. doc reduction — /usr/share/doc reduced to copyright files only, the
#      SAME rule the app layer's prune_package_docs() applies at build time
#      (mkosi.images/app/mkosi.postinst.chroot). Kept as its own pass rather
#      than glob-list-driven because it is a "keep this one filename, strip
#      the rest" rule, not a glob-removal rule.
#
# NEVER FAILS DPKG: this hook runs after dpkg has already committed the
# transaction (Post-Invoke, not Pre-Invoke), so a prune failure here must never
# be allowed to surface as a broken apt run. Every step is best-effort: errors
# are logged and the script always exits 0.
#
# device-daemon shell profile (docs/shell-profiles.md): no `set -e`, no ERR
# trap, self-contained log().
#
# shellcheck shell=bash

set -uo pipefail

PROG="ceralive-reprune"
PRUNE_PATHS_FILE="${CERALIVE_PRUNE_PATHS_LIST:-/usr/lib/ceralive/prune-paths.list}"
DOC_ROOT="${CERALIVE_DOC_ROOT:-/usr/share/doc}"

log() { printf '%s: %s\n' "${PROG}" "$*" >&2; }

prune_manifest_globs() {
  [[ -r "${PRUNE_PATHS_FILE}" ]] || { log "no readable ${PRUNE_PATHS_FILE} — nothing to reprune"; return 0; }
  local line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -n "${line}" ]] || continue
    case "${line}" in \#*) continue ;; esac
    # shellcheck disable=SC2086 # deliberately unquoted: prune-paths.list entries are globs
    rm -rf -- ${line} 2>/dev/null || log "could not remove glob (non-fatal): ${line}"
  done <"${PRUNE_PATHS_FILE}"
}

prune_docs_to_copyright() {
  [[ -d "${DOC_ROOT}" ]] || return 0
  find "${DOC_ROOT}" -type f ! -name copyright -delete 2>/dev/null \
    || log "doc reduction: some entries under ${DOC_ROOT} could not be removed (non-fatal)"
  find "${DOC_ROOT}" -mindepth 1 -type d -empty -delete 2>/dev/null || true
}

main() {
  prune_manifest_globs
  prune_docs_to_copyright
  exit 0
}

main "$@"
