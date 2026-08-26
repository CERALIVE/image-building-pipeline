#!/usr/bin/env bash
#
# check-wwan-modules.sh — ADVISORY build-time WWAN kernel-module presence check.
#
# The cellular datapath needs six WWAN kernel modules to enumerate USB/M.2 LTE/5G
# modems (see docs/modem-matrix.md). The kernel BSP is exact-versioned, but a
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

# Native M.2 modem drivers that are NOT part of the six-module USB datapath and
# are therefore checked SEPARATELY, and only on the kernel track that provides
# them. mtk_t7xx is the MediaTek T700 PCIe/WWAN driver a Fibocom FM350-GL binds to
# natively (PCI 14c3:4d75, MBIM over the wwan subsystem).
#
# SCOPE — this is the whole reason the check is split in two. The FM350's NATIVE
# PCIe personality and its bench USB personality (0e8d:7127, RNDIS/serial) are
# different device classes: a working USB adapter is not evidence that the native
# driver is present, and the six USB modules above say nothing about it either.
# Production ships the Armbian vendor 6.1 BSP, whose module set is a property of
# the exact-versioned .deb, so the gate is meaningful there and is asserted there.
# On the mainline `edge` track the answer is a Kconfig question owned by
# manifests/kernel/rk3588-edge.fragment + verify-kernel-config.sh, not by an
# Armbian package's bytes — so this check reports OUT OF SCOPE rather than
# guessing. Do NOT widen the marker to a bare "vendor": the release strings that
# actually carry this driver are 6.1.115-vendor-rk35xx (prebuilt) and
# 6.1.115-ceralive-vendor-rk35xx (the vendor-patched variant).
WWAN_NATIVE_M2_MODULES=(mtk_t7xx)
WWAN_VENDOR_RELEASE_MARKER="vendor-rk35xx"

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

# wwan_collect_kernel_releases <root> — the `lib/modules/<release>` directory
# names present in the tree. Read from the tree itself rather than composed from a
# manifest field, because a .deb's payload is the only thing that can answer which
# kernel this actually is.
declare -ga WWAN_KERNEL_RELEASES
wwan_collect_kernel_releases() {
  local root="$1" moddir sub
  WWAN_KERNEL_RELEASES=()
  while IFS= read -r -d '' moddir; do
    [[ "${moddir}" == */lib/modules ]] || continue
    while IFS= read -r -d '' sub; do
      WWAN_KERNEL_RELEASES+=("${sub##*/}")
    done < <(find "${moddir}" -mindepth 1 -maxdepth 1 -type d -print0)
  done < <(find "${root}" -type d -name modules -print0)
}

wwan_tree_is_vendor_track() {
  local release
  for release in "${WWAN_KERNEL_RELEASES[@]}"; do
    [[ "${release}" == *"${WWAN_VENDOR_RELEASE_MARKER}"* ]] && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# wwan_check_native_m2 — the FM350 `mtk_t7xx` presence gate, scoped to the vendor
# track (see WWAN_NATIVE_M2_MODULES above). Consumes the maps wwan_check already
# populated. Advisory like everything else here: ALWAYS returns 0.
#
# The out-of-scope branch deliberately says nothing about presence. Reporting a
# non-vendor tree as "missing" would be a false negative dressed as a finding —
# the driver's absence from a mainline tree is a config question, not a drop.
# ---------------------------------------------------------------------------
wwan_check_native_m2() {
  local mod nmod releases
  releases="${WWAN_KERNEL_RELEASES[*]:-<none>}"
  if ! wwan_tree_is_vendor_track; then
    log_info "native M.2 modem driver gate: OUT OF SCOPE for this tree (kernel release(s): ${releases}; the gate binds *${WWAN_VENDOR_RELEASE_MARKER} — the production vendor 6.1 BSP). On the mainline edge track mtk_t7xx is governed by manifests/kernel/rk3588-edge.fragment + verify-kernel-config.sh."
    return 0
  fi
  log_info "native M.2 modem driver gate: vendor track detected (${releases})"
  for mod in "${WWAN_NATIVE_M2_MODULES[@]}"; do
    nmod="$(_wwan_norm "${mod}")"
    if [[ -n "${WWAN_LOADABLE[${nmod}]:-}" ]]; then
      log_success "native M.2 modem driver present: ${mod} — loadable (=m) [${WWAN_LOADABLE[${nmod}]}]"
    elif [[ -n "${WWAN_BUILTIN[${nmod}]:-}" ]]; then
      log_success "native M.2 modem driver present: ${mod} — built-in (=y, modules.builtin) [${WWAN_BUILTIN[${nmod}]}]"
    elif [[ -n "${WWAN_ALIAS[${nmod}]:-}" ]]; then
      log_success "native M.2 modem driver present: ${mod} — alias (modules.alias)"
    else
      log_warn "native M.2 modem driver ABSENT: ${mod} — a Fibocom FM350-GL in its NATIVE PCIe personality (14c3:4d75) cannot bind on this kernel; its bench USB personality (0e8d:7127) is a different device class and is not evidence either way. Advisory only; see docs/modem-matrix.md §8"
    fi
  done
  return 0
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
  wwan_collect_kernel_releases "${root}"

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
      log_warn "WWAN module MISSING: ${mod} — advisory only; see docs/modem-matrix.md"
      missing=$((missing + 1))
    fi
  done

  if (( missing > 0 )); then
    log_warn "WWAN module-presence check: ${present}/${#WWAN_REQUIRED_MODULES[@]} present, ${missing} missing (ADVISORY — build continues)"
  else
    log_success "WWAN module-presence check: all ${#WWAN_REQUIRED_MODULES[@]} required modules present"
  fi

  wwan_check_native_m2
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
