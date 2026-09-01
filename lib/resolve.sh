#!/usr/bin/env bash
#
# resolve.sh — manifest loader/resolver for the CeraLive v2 image pipeline.
#
# Stage 1. Given a board name it:
#   1. locates manifests/boards/<board>.yaml          (dies loudly + lists boards)
#   2. reads the required `family:` ref
#   3. locates manifests/families/<family>.yaml       (dies loudly + lists families)
#   4. validates BOTH against their JSON Schemas       (dies "schema invalid: <field>")
#   5. deep-merges family (defaults) <- [variant overlay] <- board (overrides); board wins
#   6. resolves any `@versions:<key>` defer token via versions.yaml get_pin
#   7. emits a flat, sorted, source-able KEY=value param set on stdout
#
# The emitted param set is what the builder orchestrator (task 16) consumes:
#   eval "$(resolve.sh rock-5b-plus)"      # or: source <(resolve.sh rock-5b-plus)
#
# FAMILY VARIANTS (task 26)
# -------------------------
# A family may declare named `variants:` overlays (e.g. `edge`, which retargets
# the kernel to a build-from-source pin). Selection is EXPLICIT ONLY — via
# `--variant <name>` or CERALIVE_KERNEL_VARIANT — and is never inferred from the
# board, the host or the environment beyond that one variable. With no variant
# the reserved name `default` applies, which resolves the family's own
# `default_variant:` (rk3588: `edge`, the production mainline track) or no
# overlay at all for a family that declares none. Both `variants:` and
# `default_variant:` are stripped before flattening, so an unselected overlay
# can never leak a second kernel pin into the resolved params.
#
# Design rules (inherited from lib/common.sh + learnings):
#   * strict mode + loud ERR trap (common.sh); NO `|| true` anywhere.
#   * generic over ANY manifest — zero board-specific branches here.
#   * never silently default a missing required field — fail loudly.
#
# versions.yaml DEFER convention
# ------------------------------
# Any manifest field VALUE of the form `@versions:<key>` is replaced by that
# component's `pin:` from the repo-root versions.yaml, resolved through the ONE
# shared reader `lib/shared/versions-lib.sh::get_pin`. A deferred-but-absent pin is
# a hard error (we never emit a half-resolved token). Real rk3588 manifests
# currently defer nothing, so resolution is a no-op pass-through for them; the
# mechanism is exercised by the synthetic fixtures in tests/resolve.test.sh.
#
# shellcheck shell=bash

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${HERE}/common.sh"
# shellcheck source=lib/shared/versions-lib.sh
source "${HERE}/shared/versions-lib.sh"

# ---------------------------------------------------------------------------
# Locations (HERE = lib).
# ---------------------------------------------------------------------------
MANIFESTS_DIR="${HERE}/../manifests"
BOARDS_DIR="${MANIFESTS_DIR}/boards"
FAMILIES_DIR="${MANIFESTS_DIR}/families"
SCHEMA_DIR="${MANIFESTS_DIR}/schema"
BOARD_SCHEMA="${SCHEMA_DIR}/board.schema.json"
FAMILY_SCHEMA="${SCHEMA_DIR}/family.schema.json"
RESOLVE_PY="${HERE}/resolve.py"

# Repo-root pin registry (lib -> repo root).
# Mirrors the fetch-debs.sh relative-path convention; override with VERSIONS_YAML.
VERSIONS_YAML="${VERSIONS_YAML:-${HERE}/../versions.yaml}"

# Manifest file extensions we accept, in precedence order.
MANIFEST_EXTS=(yaml yml)

# Reserved variant name meaning "whatever the family declares as its own default"
# — the family's `default_variant:`, or no overlay when it declares none.
DEFAULT_KERNEL_VARIANT="default"

# ---------------------------------------------------------------------------
# resolve_pins — substitute every @versions:<key> token in a raw value.
# Dies loudly if a deferred pin is absent/empty (no half-resolved output).
# ---------------------------------------------------------------------------
resolve_pins() {
  local val="$1" key pin
  while [[ "$val" =~ @versions:([A-Za-z0-9._-]+) ]]; do
    key="${BASH_REMATCH[1]}"
    pin="$(get_pin "$key")"
    [[ -n "$pin" ]] || die "manifest defers to versions.yaml pin '${key}' but it is absent/empty in ${VERSIONS_YAML}"
    val="${val//@versions:${key}/${pin}}"
  done
  printf '%s' "$val"
}

# ---------------------------------------------------------------------------
# shquote — single-quote a value so the flat output is safely source-able.
# ---------------------------------------------------------------------------
shquote() {
  local s="$1"
  printf "'%s'" "${s//\'/\'\\\'\'}"
}

# ---------------------------------------------------------------------------
# find_manifest — echo the first existing <dir>/<name>.<ext>, or empty.
# ---------------------------------------------------------------------------
find_manifest() {
  local dir="$1" name="$2" ext
  for ext in "${MANIFEST_EXTS[@]}"; do
    if [[ -f "${dir}/${name}.${ext}" ]]; then
      printf '%s' "${dir}/${name}.${ext}"
      return 0
    fi
  done
  printf ''
}

# ---------------------------------------------------------------------------
# list_manifests — echo the available manifest stems in a directory.
# ---------------------------------------------------------------------------
list_manifests() {
  local dir="$1" f name out=()
  for ext in "${MANIFEST_EXTS[@]}"; do
    for f in "${dir}"/*."${ext}"; do
      [[ -e "$f" ]] || continue
      name="$(basename "$f")"
      out+=("${name%.*}")
    done
  done
  printf '%s' "${out[*]:-<none>}"
}

usage() {
  cat >&2 <<EOF
Usage: resolve.sh <board> [--variant <name>]

Resolves a board manifest into a flat KEY=value build-parameter set on stdout:
  family defaults <- [variant overlay] <- board overrides (board wins),
  versions.yaml pins resolved.

  <board>            manifest stem under ${BOARDS_DIR}/
  --variant <name>   family variant overlay to apply (default: '${DEFAULT_KERNEL_VARIANT}'
                     = the family's own default_variant, or no overlay when it
                     declares none). Also settable with CERALIVE_KERNEL_VARIANT.
                     NEVER inferred.
EOF
}

# ---------------------------------------------------------------------------
# resolve — the public entry. Prints flat KEY=value params on stdout.
# ---------------------------------------------------------------------------
resolve() {
  require_cmd python3

  local board="" variant="${CERALIVE_KERNEL_VARIANT:-${DEFAULT_KERNEL_VARIANT}}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --variant)   variant="${2:-}"; shift 2 ;;
      --variant=*) variant="${1#--variant=}"; shift ;;
      -h|--help)   usage; return 0 ;;
      -*)          usage; die "unknown option: '$1'" ;;
      *)
        [[ -z "$board" ]] || { usage; die "only one positional <board> is allowed (got '${board}' and '$1')"; }
        board="$1"; shift ;;
    esac
  done

  if [[ -z "$board" ]]; then
    usage
    die "missing required argument: <board>"
  fi
  [[ -n "$variant" ]] || die "--variant requires a name (use '${DEFAULT_KERNEL_VARIANT}' for the family's own default track)"

  # 1. Locate the board manifest.
  local board_file
  board_file="$(find_manifest "$BOARDS_DIR" "$board")"
  if [[ -z "$board_file" ]]; then
    log_error "board not found: '${board}'"
    log_error "available boards: $(list_manifests "$BOARDS_DIR")"
    exit 1
  fi

  # 2. Read the required family ref (loud on a malformed/family-less board).
  local family
  family="$(python3 "$RESOLVE_PY" get "$board_file" family)" \
    || die "could not read required 'family' field from ${board_file}"

  # 3. Locate the family manifest.
  local family_file
  family_file="$(find_manifest "$FAMILIES_DIR" "$family")"
  if [[ -z "$family_file" ]]; then
    log_error "family not found: '${family}' (referenced by board '${board}' in ${board_file})"
    log_error "available families: $(list_manifests "$FAMILIES_DIR")"
    exit 1
  fi

  if [[ "$variant" == "$DEFAULT_KERNEL_VARIANT" ]]; then
    log_info "resolving board '${board}' (family '${family}')"
  else
    log_info "resolving board '${board}' (family '${family}', variant '${variant}')"
  fi

  # 4+5. Validate both against their schemas, then deep-merge (board wins).
  #      python emits sorted, tab-delimited KEY<TAB>RAW-VALUE lines.
  local merged
  merged="$(python3 "$RESOLVE_PY" merge \
      --family "$family_file" --board "$board_file" --variant "$variant" \
      --family-schema "$FAMILY_SCHEMA" --board-schema "$BOARD_SCHEMA")" \
    || die "manifest validation/merge failed for board '${board}' (variant '${variant}'; see 'schema invalid:' above)"

  # 6+7. Resolve versions.yaml defer tokens, shell-quote, emit flat KEY=value.
  # resolve_pins' die() runs in a command substitution, so its exit cannot abort
  # the parent: the explicit status check below is what propagates the failure.
  local key rest resolved
  while IFS=$'\t' read -r key rest; do
    [[ -n "$key" ]] || continue
    if ! resolved="$(resolve_pins "$rest")"; then
      die "failed to resolve versions.yaml defer token in '${key}' for board '${board}'"
    fi
    printf '%s=%s\n' "$key" "$(shquote "$resolved")"
  done <<< "$merged"
}

# Run when executed directly; expose `resolve` when sourced by the builder.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  resolve "$@"
fi
