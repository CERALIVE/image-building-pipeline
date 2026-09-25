#!/usr/bin/env bash
#
# reprune-hook.test.sh — Todo 29 (update-system-overhaul): the device
# DPkg::Post-Invoke reprune hook, the apt cache on /data, and the runtime
# executor's writer for all three (setup_prune_reprune_and_cache).
#
# Part A — static contract: the runtime executor writes the reprune hook, the
#          apt-cache config and installs the reprune script, and is wired into
#          main() right after setup_ceralive_repository.
# Part B — the REAL ceralive-reprune.sh script, driven against synthetic
#          fixtures: glob removal, doc-to-copyright reduction, graceful
#          no-op on a missing prune-paths file, and — the load-bearing
#          property — NEVER exits non-zero even when a target is unremovable.
#
# contract-test shell profile (docs/shell-profiles.md).
#
# shellcheck shell=bash

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"
POSTINST="${PIPELINE_DIR}/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"
REPRUNE_SCRIPT="${PIPELINE_DIR}/mkosi/runtime/ceralive-reprune.sh"

fail() { printf 'reprune-hook regression: %s\n' "$1" >&2; exit 1; }

[[ -f "${POSTINST}" ]] || fail "missing runtime executor: ${POSTINST}"
[[ -f "${REPRUNE_SCRIPT}" ]] || fail "missing device reprune script: ${REPRUNE_SCRIPT}"

# ===========================================================================
# Part A — static contract
# ===========================================================================
fn_body="$(awk '
  /^setup_prune_reprune_and_cache\(\) \{/ { f=1 }
  f { print }
  f && /^\}/ { exit }
' "${POSTINST}")"
[[ -n "${fn_body}" ]] || fail "could not extract setup_prune_reprune_and_cache() from the runtime executor"

grep -q '/usr/lib/ceralive/prune-paths.list' <<<"${fn_body}" \
  || fail "setup_prune_reprune_and_cache() no longer writes /usr/lib/ceralive/prune-paths.list"
grep -q 'CERALIVE_PRUNE_PATHS_B64' <<<"${fn_body}" \
  || fail "setup_prune_reprune_and_cache() no longer reads CERALIVE_PRUNE_PATHS_B64"
grep -q '/etc/apt/apt.conf.d/80ceralive-reprune' <<<"${fn_body}" \
  || fail "setup_prune_reprune_and_cache() no longer writes the 80ceralive-reprune hook"
grep -q 'DPkg::Post-Invoke' <<<"${fn_body}" \
  || fail "80ceralive-reprune is not a DPkg::Post-Invoke hook"
grep -q '/usr/libexec/ceralive/ceralive-reprune' <<<"${fn_body}" \
  || fail "setup_prune_reprune_and_cache() no longer installs /usr/libexec/ceralive/ceralive-reprune"
grep -q '/etc/apt/apt.conf.d/81ceralive-cache' <<<"${fn_body}" \
  || fail "setup_prune_reprune_and_cache() no longer writes the 81ceralive-cache apt config"
grep -q 'Dir::Cache::archives' <<<"${fn_body}" \
  || fail "81ceralive-cache does not set Dir::Cache::archives"
grep -q '/data/ceralive/apt-archives' <<<"${fn_body}" \
  || fail "the apt cache is not pointed at /data/ceralive/apt-archives"

grep -qE '^  setup_prune_reprune_and_cache' "${POSTINST}" \
  || fail "main() no longer calls setup_prune_reprune_and_cache — none of Todo 29's device artifacts would ship"

# Ordering: must run after setup_ceralive_repository (which configures the apt
# source these apt.conf.d entries govern) and before setup_hawkbit_updater
# (which is unrelated but anchors "runs early in the layer", matching the
# call-site placement).
main_order="$(awk '/^main\(\) \{/,/^\}/' "${POSTINST}")"
repo_line="$(grep -n 'setup_ceralive_repository' <<<"${main_order}" | head -1 | cut -d: -f1)"
prune_line="$(grep -n 'setup_prune_reprune_and_cache' <<<"${main_order}" | head -1 | cut -d: -f1)"
[[ -n "${repo_line}" && -n "${prune_line}" ]] || fail "could not locate both call sites in main()"
(( prune_line > repo_line )) \
  || fail "setup_prune_reprune_and_cache runs BEFORE setup_ceralive_repository — apt.conf.d entries would predate the apt source they govern"

echo "reprune-hook: Part A static contract OK"

# ===========================================================================
# Part B — the REAL ceralive-reprune.sh script
# ===========================================================================
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# --- B1: glob removal from a synthetic prune-paths.list ---------------------
B1="${WORK}/b1"
mkdir -p "${B1}/usr/share/locale/en" "${B1}/usr/lib/locale" "${B1}/keep"
: >"${B1}/usr/share/locale/en/messages.mo"
: >"${B1}/usr/lib/locale/locale-archive"
: >"${B1}/keep/me"
PRUNE_LIST_B1="${WORK}/b1-prune.list"
printf '%s/usr/share/locale/*\n%s/usr/lib/locale/locale-archive\n' "${B1}" "${B1}" >"${PRUNE_LIST_B1}"

CERALIVE_PRUNE_PATHS_LIST="${PRUNE_LIST_B1}" CERALIVE_DOC_ROOT="${B1}/no-such-doc-dir" \
  "${REPRUNE_SCRIPT}"
rc=$?
[[ "${rc}" -eq 0 ]] || fail "B1: ceralive-reprune exited ${rc}, must always exit 0"
[[ ! -e "${B1}/usr/share/locale/en" ]] || fail "B1: /usr/share/locale/* was not pruned"
[[ ! -e "${B1}/usr/lib/locale/locale-archive" ]] || fail "B1: locale-archive was not pruned"
[[ -e "${B1}/keep/me" ]] || fail "B1: an UNLISTED path was removed — glob scope leaked"

echo "reprune-hook: Part B1 OK (glob removal, unlisted paths untouched)"

# --- B2: doc reduction (copyright kept, rest stripped) — same rule as the
#         app layer's prune_package_docs() -------------------------------
B2="${WORK}/b2/doc"
mkdir -p "${B2}/libfoo1"
printf 'licence\n' >"${B2}/libfoo1/copyright"
printf 'changelog\n' >"${B2}/libfoo1/changelog.Debian.gz"
CERALIVE_PRUNE_PATHS_LIST="${WORK}/absent.list" CERALIVE_DOC_ROOT="${B2}" "${REPRUNE_SCRIPT}"
[[ -f "${B2}/libfoo1/copyright" ]] || fail "B2: copyright was removed — must always be kept"
[[ ! -e "${B2}/libfoo1/changelog.Debian.gz" ]] || fail "B2: changelog.Debian.gz was not stripped"

echo "reprune-hook: Part B2 OK (doc reduction to copyright-only)"

# --- B3: missing prune-paths.list is a graceful no-op, never a failure ------
B3="${WORK}/b3"
mkdir -p "${B3}/untouched"
: >"${B3}/untouched/file"
out="$(CERALIVE_PRUNE_PATHS_LIST="${WORK}/does-not-exist.list" CERALIVE_DOC_ROOT="${B3}/no-doc-dir" "${REPRUNE_SCRIPT}" 2>&1)"
rc=$?
[[ "${rc}" -eq 0 ]] || fail "B3: a missing prune-paths.list must not make the hook fail (exit ${rc})"
[[ -e "${B3}/untouched/file" ]] || fail "B3: an unrelated file was removed on a missing manifest"
[[ "${out}" == *"nothing to reprune"* ]] || fail "B3: missing-manifest case is not logged"

echo "reprune-hook: Part B3 OK (missing manifest is a graceful no-op)"

# --- B4: NEVER FAILS DPKG — an unremovable target (root-owned inside a
#         rootless namespace, or a glob matching nothing) must still exit 0 --
B4="${WORK}/b4"
mkdir -p "${B4}"
PRUNE_LIST_B4="${WORK}/b4-prune.list"
printf '%s/no/such/path/at/all/*\n' "${B4}" >"${PRUNE_LIST_B4}"
CERALIVE_PRUNE_PATHS_LIST="${PRUNE_LIST_B4}" CERALIVE_DOC_ROOT="${B4}/no-doc-dir" "${REPRUNE_SCRIPT}"
rc=$?
[[ "${rc}" -eq 0 ]] || fail "B4: a glob matching nothing must still exit 0 (got ${rc})"

echo "reprune-hook: Part B4 OK (never fails dpkg, even on an unremovable/nonexistent target)"

echo "reprune-hook regression: PASS"
