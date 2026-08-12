#!/usr/bin/env bash
#
# versions-lib.sh — the ONE reader for the repo-root `versions.yaml` pin registry.
#
# `get_pin <key> [file]` echoes a component's `pin:` value, or nothing when the
# key, the `pin:` field or the file itself is absent. A missing pin is NOT an
# error here: `resolve.sh` treats an empty result for an `@versions:<key>` defer
# token as fatal, while the first-party fetch prints it as "no pin" — the two
# disagree, so the decision stays with the caller.
#
# This is a pure relocation of the awk that `lib/resolve.sh` and
# `lib/fetch/firstparty.sh` each carried a private copy of. Behaviour is
# unchanged, including the three properties the extraction had to preserve:
#
#   * the key match is EXACT (`$0 == key":"`), so `srt` never reads `srtla`'s pin
#     and no key is treated as a regular expression;
#   * a top-level key line (anything starting in column 1 with a letter) closes
#     the current block, so a `pin:` belonging to a later component is never
#     attributed to an earlier one;
#   * the FIRST matching pin wins and the scan stops there.
#
# The two former copies differed only in their missing-file spelling — `echo ""`
# in resolve.sh, `printf ''` in firstparty.sh. Every call site is a command
# substitution, which strips trailing newlines, so the observable results were
# identical; the shared reader keeps the `printf ''` form.
#
# shellcheck shell=bash

# ---------------------------------------------------------------------------
# get_pin <key> [file] — read a component's `pin:` from versions.yaml.
# Defaults to $VERSIONS_YAML, which every consumer sets before calling.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2154  # VERSIONS_YAML is supplied by the sourcing consumer
get_pin() {
  local key="$1" file="${2:-$VERSIONS_YAML}"
  [[ -f "$file" ]] || { printf ''; return; }
  awk -v key="$key" '$0==key":"{f=1;next} f&&/^[a-zA-Z]/{f=0}
    f&&/^[[:space:]]+pin:/{gsub(/^[[:space:]]+pin:[[:space:]]*/,"");print;exit}' "$file"
}
