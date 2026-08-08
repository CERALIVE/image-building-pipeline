#!/usr/bin/env bash
#
# postinst-module-contract.test.sh — the customize/postinst.d/ module contract.
#
# customize/postinst-lib.sh is a thin ENTRY that sources per-concern modules from
# customize/postinst.d/. Two properties make that split safe, and neither is
# visible to the bats suite, because bats sources the library from a shell that
# has already run its own setup:
#
#   A. RESOLUTION — sourcing ONLY the entry, in a bare shell with a scrubbed
#      environment and nothing else pre-sourced, must define every function in
#      postinst-drift-check.sh's CONSOLIDATED_FUNCS registry. That registry is
#      READ from the gate rather than restated here, so a function added there
#      is automatically covered.
#
#   B. CHROOT-SAFE STANDALONE — each module must also survive being sourced ON
#      ITS OWN, because these files run inside mkosi SUBIMAGE CHROOTS where the
#      repo's lib/ is NOT mounted and no common.sh has been sourced. Every module
#      therefore carries declare -F-guarded log()/die() fallbacks; without them a
#      module resolves neither, and the first log line in a postinst that has
#      already half-configured the image dies with `command not found`.
#
# Both legs run under `env -i` — no PATH inheritance, no BASH_ENV, no functions
# exported from this shell — so a helper that happens to exist on the developer's
# machine cannot make a broken module look fine.
#
# Run:  v2/tests/postinst-module-contract.test.sh   (wired into v2/run-tests)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2="$(cd "${HERE}/.." && pwd)"
ENTRY="${V2}/mkosi/customize/postinst-lib.sh"
POSTINST_D="${V2}/mkosi/customize/postinst.d"
DRIFT_CHECK="${V2}/ci/postinst-drift-check.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok   %s\n' "$*"; }

[[ -f "${ENTRY}" ]] || fail "missing entry: ${ENTRY}"
[[ -d "${POSTINST_D}" ]] || fail "missing module dir: ${POSTINST_D}"
[[ -f "${DRIFT_CHECK}" ]] || fail "missing drift gate: ${DRIFT_CHECK}"

# A bare chroot has none of this shell's environment. `env -i` with only a
# minimal PATH is the closest faithful reproduction available offline.
bare_bash() {
  env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    bash --noprofile --norc -c "$1"
}

# The registry lives in the gate; read it instead of copying it, or this test
# goes stale exactly when a new consolidated function needs covering.
mapfile -t CONSOLIDATED_FUNCS < <(
  awk '/^readonly CONSOLIDATED_FUNCS=\(/{f=1;next} f&&/^\)/{exit} f{print}' "${DRIFT_CHECK}" \
    | tr -s ' \t' '\n' | grep -E '^[a-z_][a-z0-9_]*$'
)
(( ${#CONSOLIDATED_FUNCS[@]} > 0 )) \
  || fail "could not read CONSOLIDATED_FUNCS out of ${DRIFT_CHECK}"

printf '=== postinst.d module contract (%d consolidated functions) ===\n' "${#CONSOLIDATED_FUNCS[@]}"

# --- A. every consolidated function resolves from the entry alone ------------
missing="$(bare_bash "
  source '${ENTRY}' >/dev/null 2>&1 || { echo 'SOURCE_FAILED'; exit 0; }
  for fn in ${CONSOLIDATED_FUNCS[*]}; do
    declare -F \"\$fn\" >/dev/null 2>&1 || printf '%s ' \"\$fn\"
  done
")"
[[ "${missing}" != *SOURCE_FAILED* ]] \
  || fail "sourcing ${ENTRY} in a bare shell FAILED — the chroot postinst cannot load its own library"
[[ -z "${missing// /}" ]] \
  || fail "not declare -F-resolvable after sourcing only the entry in a bare shell: ${missing}"
pass "all ${#CONSOLIDATED_FUNCS[@]} consolidated functions resolve from a bare 'source postinst-lib.sh'"

# --- B. each module is chroot-safe when sourced entirely on its own ----------
shopt -s nullglob
modules=("${POSTINST_D}"/*.sh)
shopt -u nullglob
(( ${#modules[@]} > 0 )) || fail "no modules under ${POSTINST_D}"

for module in "${modules[@]}"; do
  base="$(basename "${module}")"
  out="$(bare_bash "
    source '${module}' >/dev/null 2>&1 || { echo 'SOURCE_FAILED'; exit 0; }
    declare -F log >/dev/null 2>&1 || { echo 'NO_LOG'; exit 0; }
    declare -F die >/dev/null 2>&1 || { echo 'NO_DIE'; exit 0; }
    log 'probe' 2>/dev/null || { echo 'LOG_UNUSABLE'; exit 0; }
    echo OK
  ")"
  [[ "${out}" == OK ]] \
    || fail "${base}: standalone bare-chroot source contract broken (${out}) — the module must define its own declare -F-guarded log()/die()"
  pass "${base}: sources standalone in a bare shell with working log()/die()"
done

# --- C. non-vacuity: a module WITHOUT the fallbacks must be caught ------------
# Proves leg B is a real assertion and not something every bash shell satisfies.
probe_dir="$(mktemp -d)"
trap 'rm -rf "${probe_dir}"' EXIT
grep -v -e 'declare -F log ' -e 'declare -F die ' "${modules[0]}" \
  | grep -v -e '^  log() { printf' -e '^  die() { log' >"${probe_dir}/stripped.sh"
stripped_out="$(bare_bash "
  source '${probe_dir}/stripped.sh' >/dev/null 2>&1
  declare -F log >/dev/null 2>&1 && echo HAS_LOG || echo NO_LOG
")"
[[ "${stripped_out}" == NO_LOG ]] \
  || fail "non-vacuity leg is broken: a module stripped of its fallback header still resolved log()"
pass "non-vacuity: stripping the fallback header from a module DOES lose log()"

# --- D. the entry fails LOUDLY when a listed module is absent ----------------
# Fail-closed is the whole reason the module list is explicit instead of a glob.
staged="$(mktemp -d)"
trap 'rm -rf "${probe_dir}" "${staged}"' EXIT
cp "${ENTRY}" "${staged}/postinst-lib.sh"
mkdir -p "${staged}/postinst.d"
cp "${modules[@]}" "${staged}/postinst.d/"
rm -f "${staged}/postinst.d/$(basename "${modules[0]}")"
if bare_bash "source '${staged}/postinst-lib.sh'" >/dev/null 2>&1; then
  fail "the entry SILENTLY accepted a missing module — a lost module must fail the build, not surface later as 'command not found'"
fi
pass "a missing postinst.d module makes the entry die loudly (fail-closed)"

printf 'postinst.d module contract: PASS\n'
