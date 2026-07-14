#!/usr/bin/env bash
#
# check-wwan-modules.sh — ADVISORY build-time WWAN kernel-module presence check.
#
# The cellular datapath needs six WWAN kernel modules to enumerate USB/M.2 LTE/5G
# modems (see v2/docs/modem-matrix.md). The kernel BSP is exact-versioned, but a
# same-version Armbian re-spin could still drop a module without this signal.
# This check inspects the kernel .deb (or an already-extracted module tree) and
# reports which of the six ship, distinguishing:
#   * loadable (=m)  — a <mod>.ko[.xz|.gz|.zst] file under lib/modules/.../kernel/
#   * built-in (=y)  — an entry in modules.builtin
#   * alias          — a MODULE_ALIAS line in modules.alias (last token = module)
#
# It is ADVISORY ONLY, mirroring the BSP drift-guard: a missing module prints a
# WARNING and the check STILL exits 0 — it never fails the build and never edits
# shared.list or the kernel config. Acting on a warning is a human decision.
#
# Usage:  check-wwan-modules.sh <kernel.deb | module-tree-dir>
#
# shellcheck shell=bash

set -euo pipefail

CHECK_WWAN_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# deb-lib.sh pulls in common.sh (strict mode, loggers, die, require_cmd) and the
# dpkg-less .deb extraction helper (explode_deb: dpkg-deb if present, else ar+tar).
# shellcheck source=shared/deb-lib.sh
source "${CHECK_WWAN_HERE}/shared/deb-lib.sh"

# The six WWAN modules the modem stack depends on (modem-matrix.md is the doc).
WWAN_REQUIRED_MODULES=(qmi_wwan cdc_mbim cdc_wdm option cdc_ether cdc_ncm)

# modprobe treats '-' and '_' as equivalent, and on-disk filenames disagree with
# the loaded module name (e.g. the cdc_wdm module ships as cdc-wdm.ko). Normalise
# both sides to '_' before comparing so cdc-wdm.ko satisfies cdc_wdm.
_wwan_norm() { printf '%s' "${1//-/_}"; }

# ---------------------------------------------------------------------------
# wwan_assert_deb_tools — assert a .deb extractor is available (dpkg-deb, or the
# ar+tar fallback). Returns non-zero + a WARN when none is present so the caller
# can skip .deb inspection gracefully (the check stays advisory).
# ---------------------------------------------------------------------------
wwan_assert_deb_tools() {
  if command -v dpkg-deb >/dev/null 2>&1; then
    return 0
  fi
  if command -v ar >/dev/null 2>&1 && command -v tar >/dev/null 2>&1; then
    return 0
  fi
  log_warn "no .deb extractor available — need 'dpkg-deb', or both 'ar' and 'tar'"
  return 1
}

# ---------------------------------------------------------------------------
# Collection — populate three name->path maps from a scan root. Keys are the
# normalised module name; values are the first matching path (for the report).
# ---------------------------------------------------------------------------
declare -gA WWAN_LOADABLE WWAN_BUILTIN WWAN_ALIAS

# wwan_collect_loadable <root> — every <mod>.ko[.xz|.gz|.zst] file. The basename
# is matched EXACTLY (the .ko/compression suffix is stripped), so a file that
# merely contains the word "option" — without an option.ko basename — is ignored
# (the option false-positive trap).
wwan_collect_loadable() {
  local root="$1" f base name
  while IFS= read -r -d '' f; do
    base="${f##*/}"
    name="${base%%.ko*}"
    [[ -n "${name}" ]] || continue
    WWAN_LOADABLE["$(_wwan_norm "${name}")"]="${f}"
  done < <(find "${root}" -type f \
    \( -name '*.ko' -o -name '*.ko.xz' -o -name '*.ko.gz' -o -name '*.ko.zst' \) -print0)
}

# wwan_collect_builtin <root> — modules.builtin lists =y modules as paths ending
# in '/<mod>.ko'. Match the basename so '/option.ko' counts but '/usboption.ko'
# (basename usboption) does not.
wwan_collect_builtin() {
  local root="$1" mbf line base name
  while IFS= read -r -d '' mbf; do
    while IFS= read -r line; do
      [[ "${line}" == *.ko ]] || continue
      base="${line##*/}"
      name="${base%.ko}"
      [[ -n "${name}" ]] || continue
      WWAN_BUILTIN["$(_wwan_norm "${name}")"]="${line}"
    done < "${mbf}"
  done < <(find "${root}" -type f -name 'modules.builtin' -print0)
}

# wwan_collect_alias <root> — only the literal modules.alias file, only 'alias '
# lines, taking the LAST whitespace token as the module name. A stray file that
# happens to contain "option", or an alias whose HARDWARE string contains
# "option", never registers the option module.
wwan_collect_alias() {
  local root="$1" maf line tok
  while IFS= read -r -d '' maf; do
    while IFS= read -r line; do
      [[ "${line}" == alias\ * ]] || continue
      tok="${line##* }"
      [[ -n "${tok}" ]] || continue
      WWAN_ALIAS["$(_wwan_norm "${tok}")"]="${line}"
    done < "${maf}"
  done < <(find "${root}" -type f -name 'modules.alias' -print0)
}

# ---------------------------------------------------------------------------
# wwan_check <module-tree-root> — scan the tree and report per-module presence.
# Advisory: warns on any missing module, ALWAYS returns 0.
# ---------------------------------------------------------------------------
wwan_check() {
  local root="$1"
  WWAN_LOADABLE=()
  WWAN_BUILTIN=()
  WWAN_ALIAS=()
  wwan_collect_loadable "${root}"
  wwan_collect_builtin "${root}"
  wwan_collect_alias "${root}"

  local mod nmod present=0 missing=0
  for mod in "${WWAN_REQUIRED_MODULES[@]}"; do
    nmod="$(_wwan_norm "${mod}")"
    if [[ -n "${WWAN_LOADABLE[${nmod}]:-}" ]]; then
      log_success "WWAN module present: ${mod} — loadable (=m) [${WWAN_LOADABLE[${nmod}]}]"
      present=$((present + 1))
    elif [[ -n "${WWAN_BUILTIN[${nmod}]:-}" ]]; then
      log_success "WWAN module present: ${mod} — built-in (=y, modules.builtin) [${WWAN_BUILTIN[${nmod}]}]"
      present=$((present + 1))
    elif [[ -n "${WWAN_ALIAS[${nmod}]:-}" ]]; then
      log_success "WWAN module present: ${mod} — alias (modules.alias)"
      present=$((present + 1))
    else
      log_warn "WWAN module MISSING: ${mod} — advisory only; see v2/docs/modem-matrix.md"
      missing=$((missing + 1))
    fi
  done

  if (( missing > 0 )); then
    log_warn "WWAN module-presence check: ${present}/${#WWAN_REQUIRED_MODULES[@]} present, ${missing} missing (ADVISORY — build continues)"
  else
    log_success "WWAN module-presence check: all ${#WWAN_REQUIRED_MODULES[@]} required modules present"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# check_wwan_main <input> — resolve a scan root (extract a .deb to a temp dir, or
# use a module tree directly), run the check, clean up. Advisory: exit 0 always.
# ---------------------------------------------------------------------------
check_wwan_main() {
  [[ $# -ge 1 ]] || die "usage: check-wwan-modules.sh <kernel.deb | module-tree-dir>"
  local input="$1" root="" tmp=""

  if [[ -d "${input}" ]]; then
    root="${input}"
  elif [[ -f "${input}" && "${input}" == *.deb ]]; then
    if ! wwan_assert_deb_tools; then
      log_warn "skipping WWAN module check: cannot inspect '${input}' without dpkg-deb or ar+tar (ADVISORY)"
      return 0
    fi
    tmp="$(mktemp -d)"
    root="${tmp}"
    explode_deb "${input}" "${root}"
  else
    log_warn "WWAN module check: input is not an existing .deb or directory: '${input}' (ADVISORY)"
    return 0
  fi

  wwan_check "${root}"

  if [[ -n "${tmp}" ]]; then
    rm -rf "${tmp}"
  fi
  return 0
}

# Sourceable for tests (helpers exposed); run only when executed directly.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  check_wwan_main "$@"
fi
