#!/usr/bin/env bash
#
# v2/ci/check-deferred-anchors.sh — CI gate against STALE anchors in DEFERRED.md.
#
# WHY: v2/docs/DEFERRED.md indexes every deferred / hardware-gated item with
# `path:line` anchors that point at the concrete in-tree marker each item is
# about (a FIXME placeholder, a "Pending hardware run" note, a `pin: null`). # justified: FIXME here is a keyword class name, not a deferred-work marker
# Those line numbers rot the moment the anchored file is edited above the anchor.
# A rotted anchor turns the deferral ledger into a liar: it claims a marker lives
# at a line that has since moved or vanished. This gate makes that observable —
# it extracts every `path:line` anchor from DEFERRED.md and asserts the target
# file exists AND the target line(s) still carry the keyword the entry claims.
#
# KEYWORD CLASSES (the marker an anchored line MUST contain), keyed by path:
#   FIXME                 — board-manifest interface placeholders awaiting the # justified: keyword class name, not a deferred-work marker
#                           real udevadm ID_PATH (orange-pi-5-plus.yaml)
#   Pending hardware run  — DEVICE-BRINGUP.md hardware-evidence placeholders
#   null                  — versions.yaml hardware-gated cog/wpewebkit pins
#
# RULE D (self-contained repo): this script NEVER reads a path above the
# image-building-pipeline checkout root. `versions.yaml` lives at the workspace
# root (one level ABOVE this repo) and does not exist in standalone CI, so its
# anchors are recognised, reported as SKIP (cross-repo), and verified
# out-of-band — never resolved upward, never a failure.
#
# Exit 0  — every in-repo anchor resolves and carries its keyword.
# Exit 1  — one or more stale/broken anchors (each is listed).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEFERRED="$REPO_ROOT/v2/docs/DEFERRED.md"

if [[ ! -f "$DEFERRED" ]]; then
  printf 'FATAL: DEFERRED.md not found at %s\n' "$DEFERRED" >&2
  exit 2
fi

# Paths that legitimately live ABOVE the repo root (workspace-root files).
# Never resolved upward (Rule D) — reported and skipped, verified out-of-band.
is_cross_repo() {
  case "$1" in
    versions.yaml) return 0 ;;
    *) return 1 ;;
  esac
}

# The marker keyword the anchored file MUST carry at its target line(s).
# An empty result means "no keyword class" → the anchor is bounds-checked only
# (line must exist and be non-blank), which still catches an anchor that has
# slid past the end of its file or onto a blank line.
keyword_for() {
  case "$1" in
    *orange-pi-5-plus.yaml) printf 'FIXME' ;; # justified: emitting the keyword string to match, not a deferred-work marker
    */DEVICE-BRINGUP.md)    printf 'Pending hardware run' ;;
    versions.yaml)          printf 'null' ;;
    *)                      printf '' ;;
  esac
}

# Extract every `path:line` / `path:start-end` anchor. Restricted to source-ish
# extensions so version strings ("2.38.6-1") and IPs ("192.168.42.1") never match.
mapfile -t ANCHORS < <(
  grep -oE '[A-Za-z0-9._/-]+\.(yaml|yml|md|sh|py|json):[0-9]+(-[0-9]+)?' "$DEFERRED" \
    | sort -u
)

if [[ ${#ANCHORS[@]} -eq 0 ]]; then
  printf 'FATAL: no path:line anchors extracted from DEFERRED.md (parser broke?)\n' >&2
  exit 2
fi

fail=0
checked=0
skipped=0

for anchor in "${ANCHORS[@]}"; do
  path="${anchor%%:*}"
  span="${anchor#*:}"
  start="${span%%-*}"
  end="${span##*-}"   # equals start when the span has no '-'

  if is_cross_repo "$path"; then
    kw="$(keyword_for "$path")"
    printf 'SKIP  %-44s (cross-repo workspace-root file; keyword "%s" verified out-of-band, Rule D)\n' \
      "$anchor" "$kw"
    skipped=$((skipped + 1))
    continue
  fi

  file="$REPO_ROOT/$path"
  if [[ ! -f "$file" ]]; then
    printf 'FAIL  %-44s (file not found in repo: %s)\n' "$anchor" "$path"
    fail=$((fail + 1))
    continue
  fi

  kw="$(keyword_for "$path")"
  total_lines="$(wc -l < "$file")"

  for (( ln = start; ln <= end; ln++ )); do
    if (( ln > total_lines )); then
      printf 'FAIL  %s:%d (line %d beyond EOF — file has %d lines; anchor is stale)\n' \
        "$path" "$ln" "$ln" "$total_lines"
      fail=$((fail + 1))
      continue
    fi
    line_text="$(sed -n "${ln}p" "$file")"
    if [[ -n "$kw" ]]; then
      if [[ "$line_text" != *"$kw"* ]]; then
        printf 'FAIL  %s:%d (expected keyword "%s" absent; line reads: %s)\n' \
          "$path" "$ln" "$kw" "${line_text:0:72}"
        fail=$((fail + 1))
      else
        checked=$((checked + 1))
      fi
    else
      if [[ -z "${line_text// /}" ]]; then
        printf 'FAIL  %s:%d (anchor lands on a blank line — likely stale)\n' "$path" "$ln"
        fail=$((fail + 1))
      else
        checked=$((checked + 1))
      fi
    fi
  done
done

printf -- '----\n'
printf 'anchors: %d line(s) verified, %d cross-repo skipped, %d failed\n' \
  "$checked" "$skipped" "$fail"

if (( fail > 0 )); then
  printf 'RESULT: STALE ANCHORS — reconcile v2/docs/DEFERRED.md\n'
  exit 1
fi
printf 'RESULT: every DEFERRED.md anchor resolves to its claimed marker\n'
