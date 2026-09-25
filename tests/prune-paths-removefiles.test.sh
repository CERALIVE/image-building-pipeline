#!/usr/bin/env bash
#
# prune-paths-removefiles.test.sh — proves the Todo 29 (update-system-overhaul)
# single-source mechanism: manifests/prune-paths.list -> generated runtime
# mkosi.local.conf -> a REAL mkosi RemoveFiles= merge. This is the central
# design decision the task exists to resolve (RemoveFiles= is a static mkosi
# setting with no file-read/env-expand capability; the manifest cannot be read
# from inside a subimage chroot), so this test is deliberately an EXECUTABLE
# integration proof against the real pinned mkosi, not a text assertion alone.
#
# Part A — prune-paths-lib.sh: comment/blank stripping, CSV join.
# Part B — the SHIPPED generate_prune_local_conf() (lib/stages/mkosi.sh),
#          sourced for real, run against a scratch MKOSI_DIR, producing the
#          exact [Content]/RemoveFiles= shape mkosi.local.conf must have.
# Part C — REAL mkosi (mkosi.1.md's own documented cascade: "settings that take
#          a collection of values are merged by appending") parses a synthetic
#          mkosi.conf + the Part-B-generated mkosi.local.conf and reports BOTH
#          the static baseline AND the manifest-sourced globs in its resolved
#          RemoveFiles=. Skipped (not failed) if mkosi is not on PATH.
#
# contract-test shell profile (docs/shell-profiles.md).
#
# shellcheck shell=bash

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"

fail() { printf 'prune-paths-removefiles regression: %s\n' "$1" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# ===========================================================================
# Part A — prune_paths_read / prune_paths_csv: comments and blanks stripped,
# leading/trailing whitespace trimmed, deterministic comma join.
# ===========================================================================
# shellcheck source=/dev/null
source "${PIPELINE_DIR}/lib/shared/prune-paths-lib.sh"

FIXTURE="${WORK}/fixture-prune-paths.list"
cat >"${FIXTURE}" <<'EOF'
# a comment line, ignored

  /usr/share/locale/*
/usr/lib/locale/locale-archive
# another comment
   /trailing/whitespace/glob/*
EOF

got_read="$(prune_paths_read "${FIXTURE}" | tr '\n' '|')"
expected_read="/usr/share/locale/*|/usr/lib/locale/locale-archive|/trailing/whitespace/glob/*|"
[[ "${got_read}" == "${expected_read}" ]] \
  || fail "Part A: prune_paths_read comments/blanks/whitespace handling wrong.\n  got:      ${got_read}\n  expected: ${expected_read}"

got_csv="$(prune_paths_csv "${FIXTURE}")"
expected_csv="/usr/share/locale/*,/usr/lib/locale/locale-archive,/trailing/whitespace/glob/*"
[[ "${got_csv}" == "${expected_csv}" ]] \
  || fail "Part A: prune_paths_csv join wrong.\n  got:      ${got_csv}\n  expected: ${expected_csv}"

echo "prune-paths-removefiles: Part A OK (comment/blank/whitespace stripping, CSV join)"

# Empty manifest -> empty CSV, never a stray leading/trailing comma.
EMPTY_FIXTURE="${WORK}/empty.list"
: >"${EMPTY_FIXTURE}"
got_empty_csv="$(prune_paths_csv "${EMPTY_FIXTURE}")"
[[ -z "${got_empty_csv}" ]] || fail "Part A: an empty manifest must yield an empty CSV, got: '${got_empty_csv}'"
echo "prune-paths-removefiles: Part A (empty-manifest leg) OK"

# ===========================================================================
# Part B — the SHIPPED generate_prune_local_conf() (lib/stages/mkosi.sh),
# sourced for real (not re-implemented) and run against a scratch tree.
# ===========================================================================
# common.sh imposes build-strict mode (set -euo pipefail + an ERR trap); this
# harness is contract-test profile (docs/shell-profiles.md), so restore that
# immediately after sourcing — generate_prune_local_conf() only needs
# common.sh's log_info/log_success, never its strict-mode side effects here.
# shellcheck source=/dev/null
source "${PIPELINE_DIR}/lib/common.sh"
set +e
trap - ERR
set -uo pipefail
# shellcheck source=/dev/null
source "${PIPELINE_DIR}/lib/stages/mkosi.sh"

SCRATCH_MKOSI="${WORK}/mkosi-scratch"
mkdir -p "${SCRATCH_MKOSI}/mkosi.images/runtime"
MKOSI_DIR="${SCRATCH_MKOSI}" PIPELINE_DIR="${WORK}" CERALIVE_PRUNE_PATHS_MANIFEST="${FIXTURE}" \
  generate_prune_local_conf >/dev/null 2>&1 \
  || fail "Part B: generate_prune_local_conf() (the real shipped stage function) failed"

GENERATED="${SCRATCH_MKOSI}/mkosi.images/runtime/mkosi.local.conf"
[[ -f "${GENERATED}" ]] || fail "Part B: generate_prune_local_conf() did not write ${GENERATED}"
grep -qxF '[Content]' "${GENERATED}" || fail "Part B: generated file missing [Content] section header"
grep -qxF "RemoveFiles=${expected_csv}" "${GENERATED}" \
  || fail "Part B: generated file's RemoveFiles= does not match the manifest CSV.\n$(cat "${GENERATED}")"

echo "prune-paths-removefiles: Part B OK (real generate_prune_local_conf() writes a valid mkosi.local.conf)"

# Idempotent overwrite: a second call with a DIFFERENT manifest must fully
# replace the content, never append to a stale file from a prior build.
FIXTURE2="${WORK}/fixture2.list"
printf '/only/this/glob/*\n' >"${FIXTURE2}"
MKOSI_DIR="${SCRATCH_MKOSI}" PIPELINE_DIR="${WORK}" CERALIVE_PRUNE_PATHS_MANIFEST="${FIXTURE2}" \
  generate_prune_local_conf >/dev/null 2>&1 \
  || fail "Part B (idempotency leg): second generate_prune_local_conf() call failed"
grep -qxF 'RemoveFiles=/only/this/glob/*' "${GENERATED}" \
  || fail "Part B (idempotency leg): regenerated file does not carry the new manifest's globs"
grep -qF '/trailing/whitespace/glob/*' "${GENERATED}" \
  && fail "Part B (idempotency leg): regenerated file STILL carries the FIRST manifest's globs — not an overwrite"

echo "prune-paths-removefiles: Part B (idempotent overwrite) OK"

# ===========================================================================
# Part C — REAL mkosi: a synthetic top-level project proves mkosi's own
# documented list-merge cascade actually APPENDS mkosi.local.conf's
# RemoveFiles= to the static mkosi.conf's, rather than replacing it — the
# property generate_prune_local_conf's whole design depends on.
# ===========================================================================
if ! command -v mkosi >/dev/null 2>&1; then
  echo "prune-paths-removefiles: mkosi not on PATH — skipping Part C (Parts A/B are the offline contract)"
  echo "prune-paths-removefiles regression: PASS (A/B only; C skipped)"
  exit 0
fi

MKOSI_PROJECT="${WORK}/mkosi-project"
mkdir -p "${MKOSI_PROJECT}"
cat >"${MKOSI_PROJECT}/mkosi.conf" <<'EOF'
[Distribution]
Distribution=debian
Release=trixie

[Output]
Format=none

[Content]
RemoveFiles=/usr/share/locale/*,/usr/lib/locale/locale-archive
EOF

before_summary="$(cd "${MKOSI_PROJECT}" && mkosi summary 2>&1)"
[[ "${before_summary}" == *'/usr/share/locale/*'* ]] \
  || fail "Part C (baseline): the static RemoveFiles= did not appear in mkosi summary at all — mkosi environment problem, not this mechanism"
[[ "${before_summary}" != *'/trailing/whitespace/glob/*'* ]] \
  || fail "Part C (baseline): the manifest's glob appeared BEFORE mkosi.local.conf was even written — test is not isolating the mechanism"

# Now drop in exactly what generate_prune_local_conf() produces.
cp "${GENERATED}" "${MKOSI_PROJECT}/mkosi.local.conf"

after_summary="$(cd "${MKOSI_PROJECT}" && mkosi summary 2>&1)"
[[ "${after_summary}" == *'/usr/share/locale/*'* ]] \
  || fail "Part C: after adding mkosi.local.conf, the STATIC baseline RemoveFiles= entry is GONE — mkosi.local.conf REPLACED instead of merging"
[[ "${after_summary}" == *'/usr/lib/locale/locale-archive'* ]] \
  || fail "Part C: static baseline's second entry lost after merge"
[[ "${after_summary}" == *'/only/this/glob/*'* ]] \
  || fail "Part C: the manifest-sourced glob from mkosi.local.conf is ABSENT from mkosi's resolved RemoveFiles= — the single-source mechanism does not actually reach mkosi"

echo "prune-paths-removefiles: Part C OK (real mkosi merges mkosi.local.conf's RemoveFiles= additively with the static mkosi.conf's — the exact mechanism generate_prune_local_conf() relies on)"

# ---------------------------------------------------------------------------
# Mutation proof (plan acceptance criteria: "remove the -1 stanza in a test
# copy ⇒ the higher Debian version wins ⇒ test fails" — the RemoveFiles-side
# analogue). Prove the ASSERTION ABOVE is non-vacuous: if mkosi.local.conf were
# silently NOT merged (e.g. mkosi read it but the setting were mis-typed so it
# landed in the wrong section), the exact same assertion must FAIL.
# ---------------------------------------------------------------------------
MUTATED_PROJECT="${WORK}/mkosi-project-mutated"
mkdir -p "${MUTATED_PROJECT}"
cp "${MKOSI_PROJECT}/mkosi.conf" "${MUTATED_PROJECT}/mkosi.conf"
# Wrong section on purpose — [Match] cannot carry RemoveFiles=, so mkosi must
# ignore or reject it, proving the assertion above is not trivially always-true.
printf '[Match]\nRemoveFiles=/only/this/glob/*\n' >"${MUTATED_PROJECT}/mkosi.local.conf"
mutated_summary="$(cd "${MUTATED_PROJECT}" && mkosi summary 2>&1)"
if [[ "${mutated_summary}" == *'/only/this/glob/*'* ]]; then
  fail "mutation proof FAILED: a RemoveFiles= key mis-sectioned into [Match] was still merged — the Part C assertion is vacuous and cannot distinguish a working merge from a broken one"
fi
echo "prune-paths-removefiles: mutation proof OK (a mis-sectioned RemoveFiles= is correctly NOT merged, proving the Part C assertion is non-vacuous)"

echo "prune-paths-removefiles regression: PASS"
