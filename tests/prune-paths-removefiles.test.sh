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
export MKOSI_DIR="${SCRATCH_MKOSI}"
CERALIVE_PRUNE_PATHS_MANIFEST="${FIXTURE}" generate_prune_local_conf >/dev/null 2>&1 \
  || fail "Part B: generate_prune_local_conf() (the real shipped stage function) failed"

GENERATED="${SCRATCH_MKOSI}/mkosi.images/runtime/mkosi.local.conf"
[[ -f "${GENERATED}" ]] || fail "Part B: generate_prune_local_conf() did not write ${GENERATED}"
grep -qxF '[Content]' "${GENERATED}" || fail "Part B: generated file missing [Content] section header"
grep -qxF "RemoveFiles=${expected_csv}" "${GENERATED}" \
  || fail "Part B: generated file's RemoveFiles= does not match the manifest CSV.\n$(cat "${GENERATED}")"

echo "prune-paths-removefiles: Part B OK (real generate_prune_local_conf() writes a valid mkosi.local.conf)"

FIXTURE2="${WORK}/fixture2.list"
printf '/only/this/glob/*\n' >"${FIXTURE2}"
prune_local_conf_cleanup
[[ ! -e "${GENERATED}" ]] || fail "Part B: cleanup left a generated mkosi config behind"
CERALIVE_PRUNE_PATHS_MANIFEST="${FIXTURE2}" generate_prune_local_conf >/dev/null 2>&1 \
  || fail "Part B (idempotency leg): second generate_prune_local_conf() call failed"
grep -qxF 'RemoveFiles=/only/this/glob/*' "${GENERATED}" \
  || fail "Part B (idempotency leg): regenerated file does not carry the new manifest's globs"
grep -qF '/trailing/whitespace/glob/*' "${GENERATED}" \
  && fail "Part B (idempotency leg): regenerated file STILL carries the FIRST manifest's globs — not an overwrite"

echo "prune-paths-removefiles: Part B (clean regeneration) OK"

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
STATIC_REMOVE="$(grep '^RemoveFiles=' "${PIPELINE_DIR}/mkosi/mkosi.images/runtime/mkosi.conf")"
[[ "${STATIC_REMOVE}" == *'/usr/lib/aarch64-linux-gnu/libgallium-*.so'* ]] \
  || fail "Part C: shipped static Mesa prune missing before real mkosi check"
cat >"${MKOSI_PROJECT}/mkosi.conf" <<EOF
[Distribution]
Distribution=debian
Release=trixie

[Output]
Format=none

[Content]
${STATIC_REMOVE}
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
[[ "${after_summary}" == *'/usr/lib/aarch64-linux-gnu/libgallium-*.so'* &&
   "${after_summary}" == *'/usr/lib/aarch64-linux-gnu/libLLVM*.so*'* &&
   "${after_summary}" == *'/usr/lib/aarch64-linux-gnu/dri/*_dri.so'* ]] \
  || fail "Part C: actual static Mesa/LLVM/DRI globs lost after generated merge"
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

# Part D — run the shipped stage in a child process, not a reimplementation.
# The fixture has no package fetch, secrets or real mkosi invocation.
HARNESS="${WORK}/stage-harness.sh"
cat >"${HARNESS}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "${REPO}/lib/shared/prune-paths-lib.sh"
source "${REPO}/lib/stages/mkosi.sh"
log_info() { :; }
log_success() { :; }
die() { printf 'stage refusal: %s\n' "$*" >&2; exit 1; }
select_build_mode() { BUILD_MODE=native; }
ceralive_mkosi_cache_domain() { printf native; }
container_build_proxy_args() { :; }
PIPELINE_DIR="${ROOT}"
MKOSI_DIR="${ROOT}/mkosi"
STAGING_ROOT="${ROOT}/staging"
mkdir -p "${MKOSI_DIR}/mkosi.images/runtime" "${STAGING_ROOT}"
CERALIVE_PRUNE_PATHS_MANIFEST="${REPO}/manifests/prune-paths.list"
board=fixture RELEASE=trixie CERALIVE_REL_MKOSI_WORKSPACE_DIR=.mkosi-workspace
mkosi_arch=x86-64 bsp_dir=/unused firstparty_dir=/unused SOURCE_DATE_EPOCH=0
run_mkosi_build() {
  [[ -f "${MKOSI_DIR}/mkosi.images/runtime/mkosi.local.conf" ]] || exit 91
  printf 'entered\n' >"${ROOT}/entered"
  case "${MODE}" in
    success) mkdir -p "${MKOSI_DIR}/build/app" ;;
    failure) return 42 ;;
    replaced)
      rm -- "${MKOSI_DIR}/mkosi.images/runtime/mkosi.local.conf"
      printf '[Content]\nRemoveFiles=/operator/new\n' >"${MKOSI_DIR}/mkosi.images/runtime/mkosi.local.conf"
      return 42 ;;
    wait) while :; do sleep 0.1; done ;;
  esac
}
prune_local_conf_install_traps
prune_local_conf_preflight
[[ ! -e "${MKOSI_DIR}/mkosi.images/runtime/mkosi.local.conf" ]] || exit 92
[[ "${MODE}" != pre-stage-failure ]] || exit 41
if [[ "${MODE}" == dry-run ]]; then
  stage_dry_run_plan
  exit 93
fi
stage_mkosi
EOF

run_fixture() {
  REPO="${PIPELINE_DIR}" ROOT="${WORK}/lifecycle" MODE="$1" DRY_RUN="${DRY_RUN:-0}" \
    bash "${HARNESS}"
}

LIFECYCLE="${WORK}/lifecycle/mkosi/mkosi.images/runtime/mkosi.local.conf"
mkdir -p "$(dirname "${LIFECYCLE}")"
# Reproduce an aborted older invocation by leaving its exact generated payload.
cp "${GENERATED}" "${LIFECYCLE}"
DRY_RUN=1 run_fixture dry-run || fail "Part D: DRY_RUN fixture failed"
[[ ! -e "${LIFECYCLE}" ]] || fail "Part D: DRY_RUN retained an old generated RemoveFiles= config"
[[ ! -e "${WORK}/lifecycle/entered" ]] || fail "Part D: DRY_RUN invoked mkosi"
cp "${GENERATED}" "${LIFECYCLE}"
if run_fixture pre-stage-failure; then fail "Part D: pre-stage abort succeeded"; fi
[[ ! -e "${LIFECYCLE}" ]] || fail "Part D: pre-stage abort retained stale generated config"

run_fixture success || fail "Part D: success fixture failed"
[[ ! -e "${LIFECYCLE}" ]] || fail "Part D: successful mkosi left a generated config behind"
if run_fixture failure; then fail "Part D: failed mkosi was reported successful"; fi
[[ ! -e "${LIFECYCLE}" ]] || fail "Part D: failed mkosi left a generated config behind"

for signal in INT TERM; do
  if MODE=wait DRY_RUN=0 REPO="${PIPELINE_DIR}" ROOT="${WORK}/lifecycle" \
    timeout -s "${signal}" 1s bash "${HARNESS}"; then
    fail "Part D: ${signal} fixture incorrectly succeeded"
  fi
  [[ -e "${WORK}/lifecycle/entered" ]] || fail "Part D: ${signal} fixture never reached mkosi"
  [[ ! -e "${LIFECYCLE}" ]] || fail "Part D: ${signal} left a generated config behind"
done

# Ambiguous operator config is neither overwritten nor removed on a dry run.
printf '[Content]\nRemoveFiles=/operator/keep\n' >"${LIFECYCLE}"
cp "${LIFECYCLE}" "${WORK}/operator-copy"
if DRY_RUN=1 run_fixture dry-run; then fail "Part D: operator-owned config was admitted"; fi
cmp -s "${LIFECYCLE}" "${WORK}/operator-copy" || fail "Part D: operator-owned config was clobbered"
rm -- "${LIFECYCLE}"
ln -s "${WORK}/operator-copy" "${LIFECYCLE}"
if DRY_RUN=1 run_fixture dry-run; then fail "Part D: operator-owned symlink was admitted"; fi
[[ -L "${LIFECYCLE}" ]] || fail "Part D: operator-owned symlink was removed"
cmp -s "${WORK}/operator-copy" "${LIFECYCLE}" || fail "Part D: symlink target changed"
rm -- "${LIFECYCLE}"
if run_fixture replaced; then fail "Part D: replaced config was admitted"; fi
cmp -s "${LIFECYCLE}" "${WORK}/operator-copy" \
  && fail "Part D: replacement did not carry the changed operator value"
grep -qxF 'RemoveFiles=/operator/new' "${LIFECYCLE}" \
  || fail "Part D: cleanup removed or rewrote a replaced operator config"
echo "prune-paths-removefiles: Part D OK (stale/dry-run, success, failure, INT, TERM, ambiguous owner)"

ORCHESTRATOR="${PIPELINE_DIR}/lib/orchestrate.sh"
grep -Fq 'prune_local_conf_install_traps' "${ORCHESTRATOR}" \
  || fail "Part D: orchestrator no longer installs EXIT/INT/TERM cleanup"
preflight_line="$(grep -nF '  prune_local_conf_preflight' "${ORCHESTRATOR}" | cut -d: -f1)"
fetch_line="$(grep -nF '  stage_fetch' "${ORCHESTRATOR}" | cut -d: -f1)"
[[ -n "${preflight_line}" && -n "${fetch_line}" && ${preflight_line} -lt ${fetch_line} ]] \
  || fail "Part D: stale-file cleanup must precede fetch and DRY_RUN early exit"

echo "prune-paths-removefiles regression: PASS"
