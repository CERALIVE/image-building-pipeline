#!/usr/bin/env bash
#
# check-release-variant.sh — refuse to release a kernel variant that carries
# debug/fault-injection symbols.
#
# WHY THIS IS NOT A NAME BLOCKLIST. `edge-test` is the first non-shippable
# variant, but "reject the string edge-test" would be a guard that only knows
# about the variant that existed the day it was written. The property that
# actually makes a variant non-shippable is that its Kconfig fragments turn ON a
# symbol production is gated OFF — manifests/kernel/forbidden-symbols.list is
# already the authoritative statement of "must not be in a shipped kernel", and
# lib/verify-kernel-config.sh --forbidden already enforces it against a RESOLVED
# config. This script enforces the same list one step earlier, against the
# DECLARED fragments, so a non-shippable variant is rejected before a release
# build starts rather than after it has produced an artifact.
#
# A future debug variant is therefore covered automatically, and a variant that
# merely renames itself gains nothing.
#
# Usage:
#   ci/check-release-variant.sh --variant <name>   # exit 0 releasable, 1 not
#   ci/check-release-variant.sh --list             # print every variant + verdict
#   ci/check-release-variant.sh --self-test        # prove both verdicts
#
# With no --variant it reads CERALIVE_KERNEL_VARIANT, and an empty/`default`
# variant is the production vendor path, which is always releasable.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"

FORBIDDEN_LIST="${CERALIVE_FORBIDDEN_SYMBOLS:-${PIPELINE_DIR}/manifests/kernel/forbidden-symbols.list}"
FAMILY_DIR="${CERALIVE_FAMILY_DIR:-${PIPELINE_DIR}/manifests/families}"

die() { printf 'check-release-variant: %s\n' "$*" >&2; exit 2; }

usage() {
  sed -n '2,27p' "${BASH_SOURCE[0]}"
}

# Print "<variant>\t<fragment> <fragment> ..." for every variant that declares
# defconfig fragments, in either the singular or the ordered-list spelling.
enumerate_variant_fragments() {
  python3 - "$@" <<'PY'
import glob, os, sys
import yaml

family_dir = sys.argv[1]
for path in sorted(glob.glob(os.path.join(family_dir, "*.yaml"))):
    with open(path, encoding="utf-8") as handle:
        data = yaml.safe_load(handle) or {}
    variants = data.get("variants")
    if not isinstance(variants, dict):
        continue
    for name, overlay in sorted(variants.items()):
        if not isinstance(overlay, dict):
            continue
        # An `extends` child may declare no fragments of its own; the parent's
        # are then what it builds, so the chain has to be walked.
        frags, seen, cursor = [], set(), name
        while cursor is not None and cursor not in seen:
            seen.add(cursor)
            node = variants.get(cursor)
            if not isinstance(node, dict):
                break
            source = node.get("kernel_source")
            if isinstance(source, dict) and not frags:
                one = source.get("defconfig_fragment")
                many = source.get("defconfig_fragments")
                if isinstance(many, list):
                    frags = [str(item) for item in many]
                elif isinstance(one, str):
                    frags = [one]
            cursor = node.get("extends")
        if frags:
            print(f"{name}\t" + " ".join(frags))
PY
}

forbidden_symbols_enabled_by() {
  local fragment_rel symbol hits=""
  local -a fragments=("$@")

  [[ -r "${FORBIDDEN_LIST}" ]] || die "forbidden-symbol list not readable: ${FORBIDDEN_LIST}"

  for fragment_rel in "${fragments[@]}"; do
    local fragment="${PIPELINE_DIR}/${fragment_rel}"
    [[ -r "${fragment}" ]] || die "fragment not readable: ${fragment}"
    while read -r symbol; do
      [[ -n "${symbol}" && "${symbol}" != \#* ]] || continue
      # `=n` and `# ... is not set` are the fragment DISABLING the symbol, which
      # is exactly what production wants; only an enabling assignment counts.
      if grep -qE "^${symbol}=(y|m|[0-9]|\")" "${fragment}"; then
        hits="${hits:+${hits} }${symbol}"
      fi
    done <"${FORBIDDEN_LIST}"
  done
  printf '%s' "${hits}"
}

verdict_for() {
  local want="$1" name frags hits
  local found=0

  while IFS=$'\t' read -r name frags; do
    [[ "${name}" == "${want}" ]] || continue
    found=1
    # shellcheck disable=SC2086  # deliberate word split: frags is a path list
    hits="$(forbidden_symbols_enabled_by ${frags})"
    if [[ -n "${hits}" ]]; then
      printf 'REJECT %s enables forbidden symbol(s): %s\n' "${want}" "${hits}"
      return 1
    fi
  done < <(enumerate_variant_fragments "${FAMILY_DIR}")

  if (( found == 0 )); then
    printf 'OK %s declares no Kconfig fragment (prebuilt-kernel path)\n' "${want}"
    return 0
  fi
  printf 'OK %s enables no forbidden symbol\n' "${want}"
  return 0
}

cmd_list() {
  local name frags hits
  while IFS=$'\t' read -r name frags; do
    # shellcheck disable=SC2086
    hits="$(forbidden_symbols_enabled_by ${frags})"
    if [[ -n "${hits}" ]]; then
      printf 'NOT-RELEASABLE\t%s\t%s\n' "${name}" "${hits}"
    else
      printf 'RELEASABLE\t%s\t-\n' "${name}"
    fi
  done < <(enumerate_variant_fragments "${FAMILY_DIR}")
}

cmd_self_test() {
  local rc=0 out

  # A guard that can only say "yes" proves nothing, so both verdicts are driven.
  if out="$(verdict_for edge)"; then
    printf 'self-test: releasable leg OK (%s)\n' "${out}"
  else
    printf 'self-test: FAILED — production `edge` was rejected: %s\n' "${out}" >&2
    rc=1
  fi

  if out="$(verdict_for edge-test)"; then
    printf 'self-test: FAILED — debug `edge-test` was accepted: %s\n' "${out}" >&2
    rc=1
  else
    printf 'self-test: non-releasable leg OK (%s)\n' "${out}"
  fi

  return "${rc}"
}

main() {
  local variant="${CERALIVE_KERNEL_VARIANT:-}"

  while (( $# )); do
    case "$1" in
      --variant)   variant="${2:-}"; shift 2 ;;
      --variant=*) variant="${1#--variant=}"; shift ;;
      --list)      cmd_list; return 0 ;;
      --self-test) cmd_self_test; return $? ;;
      -h|--help)   usage; return 0 ;;
      *) usage >&2; die "unknown argument: $1" ;;
    esac
  done

  if [[ -z "${variant}" || "${variant}" == "default" ]]; then
    printf 'OK default (production vendor path) carries no Kconfig fragment\n'
    return 0
  fi

  local out
  if out="$(verdict_for "${variant}")"; then
    printf '%s\n' "${out}"
    return 0
  fi
  printf '%s\n' "${out}" >&2
  printf 'This variant exists for bench/QA only and must never be published.\n' >&2
  return 1
}

main "$@"
