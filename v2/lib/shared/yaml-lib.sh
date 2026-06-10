#!/usr/bin/env bash
#
# yaml-lib.sh — shared, dependency-free YAML readers for the CeraLive v2 pipeline.
#
# Pure-awk so no caller needs yq/PyYAML at fetch time. Two readers:
#   * read_yaml_list  — emit every "- item" under a top-level "<key>:" block
#   * read_yaml_value — emit the scalar value of a top-level "<key>: value" pair
#
# Both die loudly when <file> is missing (no silent empty); an absent-but-present
# key yields empty output with success, exactly as the original call sites relied
# on. read_yaml_list is extracted VERBATIM from fetch-debs.sh; read_yaml_value is
# the reconciled top-level key/value reader from dev-sync/config.sh. No behaviour
# change — this file is a relocation of existing logic into one shared home.
#
# shellcheck shell=bash

YAML_LIB_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# common.sh provides strict mode, the loud ERR trap, loggers, die, require_cmd.
# shellcheck source=../common.sh
source "${YAML_LIB_HERE}/../common.sh"

# ---------------------------------------------------------------------------
# read_yaml_list — emit every "- item" under a top-level YAML <key> in <file>.
# Pure-awk so the fetcher needs no yq. Tolerates blank lines and trailing
# comments between the key and its items; stops at the next top-level key or
# a column-0 comment. Returns nothing (success) for an absent/empty key.
# ---------------------------------------------------------------------------
read_yaml_list() {
  local key="$1" file="$2"
  [[ -f "$file" ]] || die "manifest not found: ${file}"
  awk -v key="${key}" '
    $0 ~ "^"key":[[:space:]]*$" { inlist=1; next }
    inlist && /^[[:space:]]*-[[:space:]]+/ {
      sub(/^[[:space:]]*-[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); print; next
    }
    inlist && /^[A-Za-z#]/ { inlist=0 }
  ' "${file}"
}

# ---------------------------------------------------------------------------
# read_yaml_value — emit the scalar value of a top-level "<key>: value" pair in
# <file>. Strips an inline "# comment" and surrounding whitespace, prints the
# first match and stops. Returns nothing (success) for an absent key; dies when
# the file is missing (no silent empty). The top-level key/value reader the
# dev-sync config parser settled on, lifted here unchanged.
# ---------------------------------------------------------------------------
read_yaml_value() {
  local key="$1" file="$2"
  [[ -f "$file" ]] || die "manifest not found: ${file}"
  awk -v key="${key}" '
    $0 ~ "^"key":[[:space:]]+" {
      sub("^"key":[[:space:]]*", "")
      sub(/[[:space:]]*#.*$/, "")
      sub(/[[:space:]]+$/, "")
      print; exit
    }
  ' "${file}"
}
