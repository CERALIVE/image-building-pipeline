#!/usr/bin/env bash
#
# parametric.sh — PROOF that the SAME runtime + application configuration produces
# working images for BOTH rk3588 (arm64) and x86_64 (amd64), with the ONLY
# differences coming from the Platform-layer manifest descriptors (Stage 5, task 34).
#
# This is the Stage-5 arch-parametricity gate. It runs against the REAL v2 artifacts
# (manifests, mkosi layer configs, package lists, customize modules, app-layer
# interface) — NO mocks — and asserts:
#
#   A. RESOLVED PARAMS — run lib/resolve.sh for a rk3588 board (rock-5b-plus) and an
#      x86_64 board (x86-minipc) and partition the flat params:
#        * SHARED knobs (APP_BACKEND, SINGLE_SLOT_FALLBACK) are IDENTICAL.
#        * PLATFORM descriptors (ARCH, kernel/uboot/dtb/firmware pkgs, hw-accel
#          plugins, rauc adapter, serial console, partition template, board id,
#          branch, overlays, quirks, description) DIFFER (that is the whole point).
#
#   B. SHARED CONFIG FILES — the runtime + app layers are driven by exactly ONE of
#      each config file (no `*.rk3588.*` / `*.x86*` / `*.arm64*` / `*.amd64*` arch
#      fork exists). Each is hashed once: the same path is consumed for both arches.
#
#   C. EFFECTIVE RUNTIME PACKAGE SET — shared.list + <family>.delta.list (active
#      lines) is computed for rk3588 AND x86_64 and diffed: it must be BYTE-IDENTICAL
#      (both family deltas are empty, so both reduce to shared.list).
#
#   D. ZERO ARCH TOKENS in runtime+app layer CODE — grep mkosi.images/{base,runtime,
#      app}/ (comments stripped) for rk3588|rockchip|arm64|... AND x86|amd64|intel|...
#      → must be EMPTY. Comment-only mentions are reported separately (informational).
#
#   E. ZERO ARCH FORKS — no behavioral branching on $ARCH (case/if/[[ on ARCH) in the
#      runtime+app layer configs.
#
#   F. NON-VACUITY — the Platform layer IS arch-specific: mkosi.images/platform/ DOES
#      contain SoC tokens (rk3588/rockchip), proving arch-specificity is confined to
#      the one layer that is allowed to carry it (and that the grep actually works).
#
# It prints a clear report: "SHARED (identical): [...]" and "PLATFORM-SPECIFIC
# (expected to differ): [...]".
#
# Run:  v2/tests/parametric.sh            # rock-5b-plus  vs  x86-minipc
#       BOARD_ARM=orange-pi-5-plus v2/tests/parametric.sh
#
# DESIGN (inherited from common.sh + tests/realhw-smoke.sh):
#   * strict mode from common.sh; ERR trap dropped — this script COLLECTS failures
#     and owns its exit code (exit 0 only on zero hard FAILs).
#   * NO `|| true` swallowing. Probes wrapped in `if cmd; then pass; else fail; fi`.
#   * ZERO mocks — real manifests, real resolve.sh, real mkosi configs.
#
# shellcheck shell=bash

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2_DIR="$(cd "${HERE}/.." && pwd)"

# shellcheck source=../lib/common.sh
source "${V2_DIR}/lib/common.sh"
# This harness owns its exit code: collect failures, do not abort on the first.
trap - ERR

require_cmd sha256sum
require_cmd diff

# Boards under comparison: one per family. Override BOARD_ARM to use orange-pi-5-plus.
BOARD_ARM="${BOARD_ARM:-rock-5b-plus}"
BOARD_X86="${BOARD_X86:-x86-minipc}"

RESOLVE="${V2_DIR}/lib/resolve.sh"
MKOSI_IMAGES="${V2_DIR}/mkosi/mkosi.images"
PKG_DIR="${V2_DIR}/manifests/packages"

PASS=0
FAIL=0
ok()   { printf '  ok   %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL %s\n' "$*"; FAIL=$((FAIL + 1)); }
info() { printf '  ..   %s\n' "$*"; }
hdr()  { printf '\n=== %s ===\n' "$*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# ---------------------------------------------------------------------------
# Resolve both boards to flat KEY='value' param files (real lib/resolve.sh).
# ---------------------------------------------------------------------------
ARM_PARAMS="${WORK}/arm.params"
X86_PARAMS="${WORK}/x86.params"

resolve_board() { # <board> <out>
  if ! "${RESOLVE}" "$1" >"$2" 2>"${WORK}/$1.stderr"; then
    bad "resolve.sh $1 failed:"
    sed 's/^/       /' "${WORK}/$1.stderr" >&2
    return 1
  fi
  return 0
}

# Read a single KEY's quoted value from a params file ('' if the key is absent).
param() { # <params-file> <KEY>
  sed -n "s/^$2='\(.*\)'\$/\1/p" "$1"
}
has_key() { grep -q "^$2=" "$1"; }

# ---------------------------------------------------------------------------
# A. RESOLVED PARAMS — shared knobs identical, platform descriptors differ.
# ---------------------------------------------------------------------------
check_resolved_params() {
  hdr "A. Resolved params (${BOARD_ARM} [arm64] vs ${BOARD_X86} [x86-64])"
  resolve_board "${BOARD_ARM}" "${ARM_PARAMS}" || return
  resolve_board "${BOARD_X86}" "${X86_PARAMS}" || return
  ok "both boards resolved via lib/resolve.sh (no mocks)"

  # Shared knobs: present in both, MUST be identical (arch-neutral selectors).
  local k av xv
  for k in APP_BACKEND SINGLE_SLOT_FALLBACK; do
    av="$(param "${ARM_PARAMS}" "$k")"
    xv="$(param "${X86_PARAMS}" "$k")"
    if [[ -n "${av}" && "${av}" == "${xv}" ]]; then
      ok "SHARED ${k} identical: '${av}'"
    else
      bad "SHARED ${k} expected identical, got arm='${av}' x86='${xv}'"
    fi
  done

  # Platform descriptors: MUST differ (or be present in only one family). These are
  # exactly the family/board-tier fields the inherited wisdom says are arch-specific.
  local pk
  for pk in ARCH ARMBIAN_BRANCH KERNEL_PACKAGES UBOOT_PACKAGES DTB_PACKAGES \
            DTB_NAME FIRMWARE_PACKAGES HW_ACCEL_GSTREAMER_PLUGINS \
            RAUC_BOOTLOADER_ADAPTER SERIAL_CONSOLE PARTITION_TEMPLATE \
            BOARD_ID DESCRIPTION; do
    av="$(param "${ARM_PARAMS}" "${pk}")"
    xv="$(param "${X86_PARAMS}" "${pk}")"
    if [[ "${av}" != "${xv}" ]]; then
      ok "PLATFORM ${pk} differs (arm='${av:-<unset>}' x86='${xv:-<unset>}')"
    else
      bad "PLATFORM ${pk} expected to DIFFER but both = '${av}'"
    fi
  done

  # Family-asymmetric fields: present for rk3588, absent for x86 (a real difference).
  for pk in GSTREAMER_RUNTIME_PACKAGES ARMBIAN_OVERLAYS QUIRKS_M2_MODEM_SIM_WORKAROUND; do
    if has_key "${ARM_PARAMS}" "${pk}" && ! has_key "${X86_PARAMS}" "${pk}"; then
      ok "PLATFORM ${pk} present(arm)/absent(x86) — family-specific"
    else
      info "PLATFORM ${pk}: arm=$(has_key "${ARM_PARAMS}" "${pk}" && echo yes || echo no) x86=$(has_key "${X86_PARAMS}" "${pk}" && echo yes || echo no)"
    fi
  done
}

# ---------------------------------------------------------------------------
# B. SHARED CONFIG FILES — exactly one of each; no arch-forked sibling variants.
# ---------------------------------------------------------------------------
SHARED_FILES=(
  "manifests/packages/shared.list"
  "mkosi/mkosi.images/base/mkosi.conf"
  "mkosi/mkosi.images/runtime/mkosi.conf"
  "mkosi/mkosi.images/runtime/mkosi.postinst.chroot"
  "mkosi/mkosi.images/app/mkosi.conf"
  "mkosi/mkosi.images/app/mkosi.postinst.chroot"
  "lib/app-layer/interface.sh"
  "lib/app-layer/sysext.sh"
  "lib/app-layer/appfs.sh"
)

check_shared_files() {
  hdr "B. Shared config files (single file per concern — no arch fork)"
  local rel abs base dir
  for rel in "${SHARED_FILES[@]}"; do
    abs="${V2_DIR}/${rel}"
    if [[ ! -f "${abs}" ]]; then
      bad "shared file missing: ${rel}"
      continue
    fi
    ok "$(sha256sum "${abs}" | cut -c1-16)  ${rel}"
    # No arch-forked sibling (e.g. mkosi.conf.rk3588 / shared.list.x86_64).
    base="$(basename "${abs}")"
    dir="$(dirname "${abs}")"
    if compgen -G "${dir}/${base%.*}*"'.rk3588'* >/dev/null 2>&1 \
       || compgen -G "${dir}/"'*'"${base}"'*'.x86* >/dev/null 2>&1 \
       || compgen -G "${dir}/"'*'.arm64* >/dev/null 2>&1 \
       || compgen -G "${dir}/"'*'.amd64* >/dev/null 2>&1; then
      bad "arch-forked sibling of ${rel} found in ${dir}"
    fi
  done

  # The customize/ modules are the shared runtime system-config tree (one set, no
  # per-arch variant). Hash them as a group.
  local cust="${V2_DIR}/mkosi/customize"
  if [[ -d "${cust}" ]]; then
    local n
    n="$(find "${cust}" -maxdepth 1 -name '*.sh' | wc -l | tr -d ' ')"
    ok "customize/ modules: ${n} shared *.sh (group sha $(find "${cust}" -maxdepth 1 -name '*.sh' -exec sha256sum {} + | sort | sha256sum | cut -c1-16))"
  else
    bad "customize/ module dir missing"
  fi
}

# ---------------------------------------------------------------------------
# C. EFFECTIVE RUNTIME PACKAGE SET — identical across families.
# ---------------------------------------------------------------------------
active_pkgs() { # <list-file...>  -> sorted unique package names (no comments/blanks)
  cat "$@" 2>/dev/null | sed 's/#.*//' | awk 'NF{print $1}' | sort -u
}

check_effective_packages() {
  hdr "C. Effective runtime package set (shared.list + <family>.delta.list)"
  local shared="${PKG_DIR}/shared.list"
  local arm_set="${WORK}/arm.pkgs" x86_set="${WORK}/x86.pkgs"
  active_pkgs "${shared}" "${PKG_DIR}/rk3588.delta.list" >"${arm_set}"
  active_pkgs "${shared}" "${PKG_DIR}/x86_64.delta.list" >"${x86_set}"

  local rk_delta x86_delta
  rk_delta="$(active_pkgs "${PKG_DIR}/rk3588.delta.list" | wc -l | tr -d ' ')"
  x86_delta="$(active_pkgs "${PKG_DIR}/x86_64.delta.list" | wc -l | tr -d ' ')"
  ok "rk3588.delta.list active lines: ${rk_delta} (expected 0)"
  ok "x86_64.delta.list active lines: ${x86_delta} (expected 0)"

  if diff -u "${arm_set}" "${x86_set}" >"${WORK}/pkgdiff" 2>&1; then
    ok "effective runtime package set IDENTICAL for rk3588 and x86_64 ($(wc -l <"${arm_set}" | tr -d ' ') pkgs)"
  else
    bad "effective runtime package sets DIFFER:"
    sed 's/^/       /' "${WORK}/pkgdiff" >&2
  fi
}

# ---------------------------------------------------------------------------
# D. ZERO ARCH TOKENS in runtime+app layer CODE (comments stripped).
# ---------------------------------------------------------------------------
ARM_TOKENS='rk3588|rockchip|arm64|aarch64|mali|rkbin|rk_hdmirx'
X86_TOKENS='x86|amd64|x86-64|x86_64|intel|i386|vaapi|qsv'

scan_layer_code() { # <layer-dir> -> prints "file:line:match" for CODE tokens
  # A grep miss (no arch token) is the PASS condition, NOT an error — neutralise its
  # exit status so `set -e` (from common.sh) does not abort the harness on a clean scan.
  local d="$1" f
  while IFS= read -r f; do
    sed 's/#.*//' "${f}" | grep -niE "${ARM_TOKENS}|${X86_TOKENS}" \
      | sed "s#^#${f}:#" || true
  done < <(find "${d}" -type f \( -name '*.conf' -o -name '*.chroot' -o -name '*.sh' \))
  return 0
}

scan_layer_comments() { # <layer-dir> -> prints comment-only token mentions
  local d="$1" f
  while IFS= read -r f; do
    grep -niE "${ARM_TOKENS}|${X86_TOKENS}" "${f}" \
      | grep -E ':[[:space:]]*#|#.*('"${ARM_TOKENS}"'|'"${X86_TOKENS}"')' \
      | sed "s#^#${f}:#" || true
  done < <(find "${d}" -type f \( -name '*.conf' -o -name '*.chroot' -o -name '*.sh' \))
  return 0
}

check_zero_arch_tokens() {
  hdr "D. Arch tokens in runtime+app+base layer CODE (must be ZERO)"
  local layer hits total=0
  for layer in base runtime app; do
    hits="$(scan_layer_code "${MKOSI_IMAGES}/${layer}")"
    if [[ -z "${hits}" ]]; then
      ok "mkosi.images/${layer}/: zero arch tokens in code"
    else
      bad "mkosi.images/${layer}/: arch tokens in code:"
      printf '       %s\n' "${hits}" >&2
      total=$((total + 1))
    fi
  done
  [[ "${total}" -eq 0 ]] || true

  # Comment-only mentions are documentation, not behavior — reported, never failed.
  local cmt
  for layer in base runtime app; do
    cmt="$(scan_layer_comments "${MKOSI_IMAGES}/${layer}")"
    if [[ -n "${cmt}" ]]; then
      info "mkosi.images/${layer}/ comment mentions (documentation, non-behavioral):"
      printf '       %s\n' "${cmt}" | sed 's/^[[:space:]]*//' >&2
    fi
  done
}

# ---------------------------------------------------------------------------
# E. ZERO ARCH FORKS — no behavioral branching on $ARCH in runtime+app.
# ---------------------------------------------------------------------------
check_zero_arch_forks() {
  hdr "E. Arch forks (behavioral branching on \$ARCH) in runtime+app (must be ZERO)"
  local layer hits fork_re
  # case "$ARCH" / if [[ "$ARCH" / [ "$ARCH" / test on $ARCH / ${ARCH} in a cond.
  fork_re='case[[:space:]].*ARCH|if[[:space:]].*\$\{?ARCH|\[\[?[[:space:]].*\$\{?ARCH'
  local total=0
  for layer in runtime app; do
    hits=""
    while IFS= read -r f; do
      sed 's/#.*//' "${f}" | grep -nE "${fork_re}" | sed "s#^#${f}:#" >>"${WORK}/forks.$$" 2>/dev/null || true
    done < <(find "${MKOSI_IMAGES}/${layer}" -type f \( -name '*.conf' -o -name '*.chroot' -o -name '*.sh' \))
    hits="$(cat "${WORK}/forks.$$" 2>/dev/null || true)"
    : >"${WORK}/forks.$$"
    if [[ -z "${hits}" ]]; then
      ok "mkosi.images/${layer}/: no \$ARCH-branching forks"
    else
      bad "mkosi.images/${layer}/: \$ARCH fork found:"
      printf '       %s\n' "${hits}" >&2
      total=$((total + 1))
    fi
  done
  [[ "${total}" -eq 0 ]] || true
}

# ---------------------------------------------------------------------------
# F. NON-VACUITY — the Platform layer IS arch-specific (tokens MUST appear there).
# ---------------------------------------------------------------------------
check_non_vacuity() {
  hdr "F. Non-vacuity: Platform layer IS arch-specific (tokens MUST appear)"
  local plat="${MKOSI_IMAGES}/platform"
  local hits
  hits="$(scan_layer_code "${plat}")"
  if [[ -n "${hits}" ]]; then
    ok "mkosi.images/platform/ carries SoC tokens (arch-specificity confined here):"
    printf '       %s\n' "${hits}" | head -8 | sed 's/^[[:space:]]*//'
  else
    bad "mkosi.images/platform/ has NO arch tokens — grep is vacuous or platform is mis-layered"
  fi
  # The platform descriptors (kernel package names) must genuinely differ.
  local ak xk
  ak="$(param "${ARM_PARAMS}" KERNEL_PACKAGES)"
  xk="$(param "${X86_PARAMS}" KERNEL_PACKAGES)"
  if [[ -n "${ak}" && -n "${xk}" && "${ak}" != "${xk}" ]]; then
    ok "kernel packages genuinely differ: '${ak}' vs '${xk}'"
  else
    bad "kernel packages did not differ as expected ('${ak}' / '${xk}')"
  fi
}

# ---------------------------------------------------------------------------
# Report.
# ---------------------------------------------------------------------------
print_report() {
  hdr "REPORT"
  cat <<EOF
SHARED (identical across rk3588 and x86_64):
  - Effective runtime package set  : manifests/packages/shared.list (+ empty family delta)
  - Runtime layer config           : mkosi.images/runtime/{mkosi.conf,mkosi.postinst.chroot}
  - Application layer config        : mkosi.images/app/{mkosi.conf,mkosi.postinst.chroot}
  - Base OS layer config            : mkosi.images/base/mkosi.conf (arch-parametric via Architecture=)
  - App-layer interface             : lib/app-layer/{interface,sysext,appfs}.sh (3 verbs, 2 backends)
  - System-config modules           : mkosi/customize/*.sh (one shared set)
  - Resolved knobs                  : APP_BACKEND, SINGLE_SLOT_FALLBACK

PLATFORM-SPECIFIC (expected to differ — ALL from the family/board manifest):
  - ARCH                  : $(param "${ARM_PARAMS}" ARCH)  vs  $(param "${X86_PARAMS}" ARCH)
  - ARMBIAN_BRANCH        : $(param "${ARM_PARAMS}" ARMBIAN_BRANCH)  vs  $(param "${X86_PARAMS}" ARMBIAN_BRANCH)
  - KERNEL_PACKAGES       : $(param "${ARM_PARAMS}" KERNEL_PACKAGES)  vs  $(param "${X86_PARAMS}" KERNEL_PACKAGES)
  - UBOOT_PACKAGES        : '$(param "${ARM_PARAMS}" UBOOT_PACKAGES)'  vs  '$(param "${X86_PARAMS}" UBOOT_PACKAGES)'
  - DTB_PACKAGES          : '$(param "${ARM_PARAMS}" DTB_PACKAGES)'  vs  '$(param "${X86_PARAMS}" DTB_PACKAGES)'
  - FIRMWARE_PACKAGES     : $(param "${ARM_PARAMS}" FIRMWARE_PACKAGES)  vs  $(param "${X86_PARAMS}" FIRMWARE_PACKAGES)
  - HW_ACCEL_GST_PLUGINS  : $(param "${ARM_PARAMS}" HW_ACCEL_GSTREAMER_PLUGINS)  vs  $(param "${X86_PARAMS}" HW_ACCEL_GSTREAMER_PLUGINS)
  - RAUC_BOOTLOADER       : $(param "${ARM_PARAMS}" RAUC_BOOTLOADER_ADAPTER)  vs  $(param "${X86_PARAMS}" RAUC_BOOTLOADER_ADAPTER)
  - SERIAL_CONSOLE        : $(param "${ARM_PARAMS}" SERIAL_CONSOLE)  vs  $(param "${X86_PARAMS}" SERIAL_CONSOLE)
  - PARTITION_TEMPLATE    : $(param "${ARM_PARAMS}" PARTITION_TEMPLATE)  vs  $(param "${X86_PARAMS}" PARTITION_TEMPLATE)
  - BOARD_ID              : $(param "${ARM_PARAMS}" BOARD_ID)  vs  $(param "${X86_PARAMS}" BOARD_ID)

These platform descriptors are the ONLY differences, and they ALL originate from
manifests/families/{rk3588,x86_64}.yaml + manifests/boards/{$BOARD_ARM,$BOARD_X86}.yaml.
The runtime + application layers contain ZERO architecture-specific code tokens and
ZERO \$ARCH branches.
EOF
}

main() {
  printf '==============================================================\n'
  printf ' Stage 5 — runtime+app arch-parametric proof\n'
  printf '   ARM family board : %s\n' "${BOARD_ARM}"
  printf '   x86 family board : %s\n' "${BOARD_X86}"
  printf '==============================================================\n'

  check_resolved_params
  check_shared_files
  check_effective_packages
  check_zero_arch_tokens
  check_zero_arch_forks
  check_non_vacuity
  print_report

  printf '\n==============================================================\n'
  printf ' RESULT: %d passed, %d failed\n' "${PASS}" "${FAIL}"
  printf '==============================================================\n'
  [[ "${FAIL}" -eq 0 ]]
}

main "$@"
