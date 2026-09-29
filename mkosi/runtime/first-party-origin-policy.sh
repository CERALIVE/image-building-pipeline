#!/usr/bin/env bash
validate_first_party_names() {
  local supplied="$1" authority="${BASH_SOURCE[0]%/*}/first-party-origin-names.txt"
  [[ -r "$authority" ]] || { printf 'origin-protection authority missing: %s\n' "$authority" >&2; return 1; }
  local names expected missing extra
  names="$(awk '
    /^[[:space:]]*(#|$)/ { next }
    !/^[a-z0-9][a-z0-9+.-]*$/ { print "invalid first-party package name: " $0 > "/dev/stderr"; exit 1 }
    seen[$0]++ { print "duplicate: " $0 > "/dev/stderr"; exit 1 }
    { print }
  ' <<<"$supplied")" || return 1
  [[ -n "$names" ]] || { printf 'first-party names list is empty\n' >&2; return 1; }
  expected="$(awk '
    /^[[:space:]]*(#|$)/ { next }
    !/^[a-z0-9][a-z0-9+.-]*$/ { print "invalid origin-protection authority name: " $0 > "/dev/stderr"; exit 1 }
    seen[$0]++ { print "duplicate origin-protection authority name: " $0 > "/dev/stderr"; exit 1 }
    { print }
  ' "$authority")" || return 1
  [[ -n "$expected" ]] || { printf 'origin-protection authority is empty\n' >&2; return 1; }
  missing="$(comm -23 <(sort <<<"$expected") <(sort <<<"$names"))"
  extra="$(comm -13 <(sort <<<"$expected") <(sort <<<"$names"))"
  if [[ -n "$missing" || -n "$extra" ]]; then
    [[ -z "$missing" ]] || printf 'missing: %s\n' "${missing//$'\n'/, }" >&2
    [[ -z "$extra" ]] || printf 'unexpected: %s\n' "${extra//$'\n'/, }" >&2
    return 1
  fi
  # shellcheck disable=SC2034 # Read by both sourcing pin writers.
  mapfile -t FIRST_PARTY_NAMES <<<"$names"
}
