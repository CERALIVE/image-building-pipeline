#!/usr/bin/env bash
#
# check-wwan-modules.sh — build-time WWAN kernel-module presence check.
#
# The cellular datapath cannot enumerate a USB/M.2 LTE/5G modem without a
# specific set of kernel modules (see docs/modem-matrix.md). Two different gates
# make two different claims about them, and only the second one is this file:
# lib/verify-kernel-config.sh proves a SYMBOL RESOLVED in the built .config,
# while this check proves a .ko actually SHIPPED in the built .deb. A kernel
# whose config gate is green can still hand the fleet a package with a module
# missing, which is exactly the drop this exists to catch. It inspects the kernel
# .deb (or an already-extracted module tree) and reports each module as:
#   * loadable (=m)  — a <mod>.ko[.xz|.gz|.zst] file under lib/modules/.../kernel/
#   * built-in (=y)  — an entry in modules.builtin
#   * alias          — a MODULE_ALIAS line in modules.alias (last token = module)
#
# SEVERITY IS SPLIT, and the split IS the design:
#
#   REQUIRED — the USB modem datapath and the control ports that drive it. Every
#   one of these binds hardware both shipped boards are qualified with, so a drop
#   is a fleet-visible "no modem" rather than a theoretical risk. A missing
#   required module NAMES itself and FAILS the check with a non-zero exit. This
#   is a deliberate change from the pre-2026-09 behaviour, where the whole check
#   was advisory: a warning nobody has to act on is not a gate, and the only
#   signal for a shipped-.ko drop was being spent on a log line.
#
#   ADVISORY — the PCIe/MHI transport, plus host-side RNDIS. No CeraLive board
#   has qualified a PCIe/M.2 modem, so failing a build over a transport no
#   shipped hardware is proven to use would be a gate with no evidence behind it.
#   A missing advisory module prints an ADVISORY line and the check still passes.
#
# ESCAPE HATCH — CERALIVE_WWAN_CHECK_ADVISORY=1 restores the pre-change
# behaviour exactly: every module, required ones included, is reported ADVISORY
# and the check always exits 0. It is for bisecting a kernel change or probing a
# deliberately narrow tree, never for silencing a real drop on a release build,
# and it announces itself in the log so a transcript can never hide it.
#
# It never edits shared.list and never edits the kernel config. The only thing
# this check changes is its own exit status.
#
# Usage:
#   check-wwan-modules.sh <kernel.deb | module-tree-dir>
#   check-wwan-modules.sh -h | --help
#
# Environment:
#   CERALIVE_WWAN_CHECK_ADVISORY=0|1
#       1 — report every module ADVISORY and always exit 0 (pre-2026-09
#           behaviour). 0, or unset, is the default: required modules fail
#           closed. Any other value is refused rather than guessed at.
#
# shellcheck shell=bash

set -euo pipefail

CHECK_WWAN_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# deb-lib.sh pulls in common.sh (strict mode, loggers, die, require_cmd) and the
# dpkg-less .deb extraction helper (explode_deb: dpkg-deb if present, else ar+tar).
# shellcheck source=shared/deb-lib.sh
source "${CHECK_WWAN_HERE}/shared/deb-lib.sh"
# args-lib.sh is the one home for `-h|--help` recognition; it sets no shell
# options and sources nothing, so taking it costs this script no profile change.
# shellcheck source=shared/args-lib.sh
source "${CHECK_WWAN_HERE}/shared/args-lib.sh"

# ---------------------------------------------------------------------------
# WWAN_MODULE_TABLE — the ONE place the modem module set is written down.
#
# Rows are `<kernel CONFIG symbol>|<module name>|<severity>`. The symbol column
# is not decoration: it is what binds this file to
# manifests/kernel/required-symbols.list, which is the source of truth for WHICH
# symbols the finished kernel must carry. The module NAME cannot be derived from
# the symbol — CONFIG_USB_WDM builds cdc-wdm.ko, CONFIG_USB_ACM builds
# cdc-acm.ko, CONFIG_USB_SERIAL_QUALCOMM builds qcserial.ko, and no naming rule
# covers all three — so the binding has to be written once, here, rather than
# discovered. Keeping the symbol beside it is what makes that single write
# CHECKABLE instead of merely conventional: package-contract.bats §17 fails if a
# symbol in this table is missing from the manifest, AND if a valued
# CONFIG_USB_NET_* / CONFIG_USB_SERIAL_* / CONFIG_MHI_* row in the manifest never
# reaches this table. The second direction is the regression that already
# happened once — PR #144 added CONFIG_USB_NET_RNDIS_HOST to the kernel fragment
# and this checker never heard about it.
#
# Do NOT add a second array of module names anywhere. Derive from this table.
# ---------------------------------------------------------------------------
WWAN_MODULE_TABLE=(
  # REQUIRED — the USB modem datapath: the two vendor control/data protocols
  # (QMI, MBIM), their shared /dev/cdc-wdm control character device, and the
  # generic CDC data interfaces a modem falls back to.
  'CONFIG_USB_NET_QMI_WWAN|qmi_wwan|required'
  'CONFIG_USB_NET_CDC_MBIM|cdc_mbim|required'
  'CONFIG_USB_WDM|cdc_wdm|required'
  'CONFIG_USB_NET_CDCETHER|cdc_ether|required'
  'CONFIG_USB_NET_CDC_NCM|cdc_ncm|required'
  # REQUIRED — the serial control ports ModemManager drives the modem through.
  # `option` and `qcserial` cover the two USB interface layouts between them, and
  # `usb_wwan` is the promptless helper BOTH of them select, so losing it takes
  # both with it while their own symbols still look satisfied. cdc_acm is the
  # /dev/ttyACM* AT port a large share of modems expose instead.
  'CONFIG_USB_SERIAL_OPTION|option|required'
  'CONFIG_USB_SERIAL_QUALCOMM|qcserial|required'
  'CONFIG_USB_SERIAL_WWAN|usb_wwan|required'
  'CONFIG_USB_ACM|cdc_acm|required'
  # ADVISORY — the PCIe/M.2 (MHI) transport. mhi is the bus, mhi_wwan_ctrl the
  # AT/MBIM/QMI/DIAG control channels and mhi_wwan_mbim the data netdev. Advisory
  # because no CeraLive board has qualified a PCIe modem: the symbols are pinned
  # so the capability cannot vanish unnoticed, but a build must not FAIL over
  # hardware nobody has proven on a bench.
  'CONFIG_MHI_BUS|mhi|advisory'
  'CONFIG_MHI_WWAN_CTRL|mhi_wwan_ctrl|advisory'
  'CONFIG_MHI_WWAN_MBIM|mhi_wwan_mbim|advisory'
  # ADVISORY — host-side RNDIS, for modems and tethered peripherals whose only
  # mode is RNDIS. It is a USB module, not an MHI one, and it is advisory for its
  # own reason rather than the MHI one: QMI and MBIM above already cover every
  # modem in the known-good table, so RNDIS is the fallback path and no shipped
  # board depends on it. Promoting it to required needs a board that does.
  'CONFIG_USB_NET_RNDIS_HOST|rndis_host|advisory'
)

# wwan_table_column <severity|'' > <field-index> — project the table. An empty
# severity selects every row; field 1 is the CONFIG symbol, 2 the module name.
wwan_table_column() {
  local want="$1" field="$2" row sym mod sev
  for row in "${WWAN_MODULE_TABLE[@]}"; do
    IFS='|' read -r sym mod sev <<<"${row}"
    [[ -z "${want}" || "${sev}" == "${want}" ]] || continue
    case "${field}" in
      1) printf '%s\n' "${sym}" ;;
      2) printf '%s\n' "${mod}" ;;
      *) die "wwan_table_column: bad field '${field}'" ;;
    esac
  done
}

mapfile -t WWAN_REQUIRED_MODULES < <(wwan_table_column required 2)
mapfile -t WWAN_ADVISORY_MODULES < <(wwan_table_column advisory 2)

# Native M.2 modem drivers that are NOT part of the USB datapath above and are
# therefore checked SEPARATELY. mtk_t7xx is the MediaTek T700 PCIe/WWAN driver a
# Fibocom FM350-GL binds to natively (PCI 14c3:4d75, MBIM over the wwan
# subsystem).
#
# IT IS DELIBERATELY NOT A WWAN_MODULE_TABLE ROW, and the reason is the same fact
# the HONEST CONSEQUENCE paragraph below records: CONFIG_MTK_T7XX is in neither
# the fragment nor required-symbols.list, so it has no manifest row to be
# cross-checked against and adding it to that table would break the lockstep gate
# in exactly the direction the gate exists to protect. It joins the table the day
# the symbol is declared — that is the same hardware-evidence decision, not an
# extra one.
#
# SCOPE — this is the whole reason the check is split in two. The FM350's NATIVE
# PCIe personality and its bench USB personality (0e8d:7127, RNDIS/serial) are
# different device classes: a working USB adapter is not evidence that the native
# driver is present, and the USB modules above say nothing about it either.
#
# THE GATE USED TO BE KERNEL-TRACK-SCOPED, AND IS NOT ANY MORE. It ran only on a
# `*vendor-rk35xx` release and reported OUT OF SCOPE elsewhere, because the
# interesting subject was the prebuilt Armbian package's own bytes. That track is
# retired: every kernel this pipeline ships is built from pinned source, and the
# module set of the built .deb is exactly as real and as inspectable. So the
# release-marker branch is gone and the probe runs on ANY tree it is pointed at.
#
# HONEST CONSEQUENCE, STATED RATHER THAN IMPLIED: the retired branch claimed that
# on the mainline track mtk_t7xx was "a Kconfig question owned by
# manifests/kernel/rk3588-edge.fragment + verify-kernel-config.sh". It is not —
# CONFIG_MTK_T7XX appears in neither that fragment nor
# manifests/kernel/required-symbols.list, so this advisory probe is currently the
# ONLY signal about the FM350's native personality. Declaring the symbol (and
# thereby moving the answer to the config gate) is a deliberate change with its
# own hardware evidence; until then this warns truthfully instead of skipping.
WWAN_NATIVE_M2_MODULES=(mtk_t7xx)

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

# ---------------------------------------------------------------------------
# wwan_check_native_m2 — the FM350 `mtk_t7xx` presence gate (see
# WWAN_NATIVE_M2_MODULES above). Consumes the maps wwan_check already populated.
# Advisory like everything else here: ALWAYS returns 0.
#
# It runs on EVERY tree. The kernel-track scoping it used to carry existed only
# for the retired prebuilt vendor BSP; a source-built module set is just as
# inspectable, and skipping the probe would turn a real finding into silence.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# wwan_check_advisory_modules — report the ADVISORY set (the MHI/PCIe transport
# plus host-side RNDIS). Consumes the maps wwan_check already populated and
# ALWAYS returns 0: it exists to make an absence visible, never to decide a
# build. Every missing line carries the literal word ADVISORY, because the whole
# value of the split is that a reader can tell the two severities apart in one
# grep of a build log.
# ---------------------------------------------------------------------------
wwan_check_advisory_modules() {
  local mod state present=0 missing=0
  for mod in "${WWAN_ADVISORY_MODULES[@]}"; do
    if state="$(wwan_module_state "${mod}")"; then
      log_success "WWAN advisory module present: ${mod} — ${state}"
      present=$((present + 1))
    else
      log_warn "WWAN advisory module MISSING: ${mod} — ADVISORY (no CeraLive board has qualified this path); build continues. See docs/modem-matrix.md"
      missing=$((missing + 1))
    fi
  done

  if (( missing > 0 )); then
    log_warn "WWAN advisory module check: ${present}/${#WWAN_ADVISORY_MODULES[@]} present, ${missing} missing (ADVISORY — never fails the check)"
  else
    log_success "WWAN advisory module check: all ${#WWAN_ADVISORY_MODULES[@]} advisory modules present"
  fi
  return 0
}

wwan_check_native_m2() {
  local mod nmod releases
  releases="${WWAN_KERNEL_RELEASES[*]:-<none>}"
  log_info "native M.2 modem driver gate: scanning (kernel release(s): ${releases})"
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
# wwan_advisory_only — true when CERALIVE_WWAN_CHECK_ADVISORY=1 has demoted the
# whole check to its pre-2026-09 warn-and-pass behaviour. Any value other than
# 0/1 is REFUSED rather than interpreted: `=true` silently reading as "off"
# would be a required-module gate that an operator believes they disabled and a
# build believes is armed, which is the worst of both.
# ---------------------------------------------------------------------------
wwan_advisory_only() {
  local flag="${CERALIVE_WWAN_CHECK_ADVISORY:-0}"
  case "${flag}" in
    0) return 1 ;;
    1) return 0 ;;
    *) die "CERALIVE_WWAN_CHECK_ADVISORY must be 0 or 1, got '${flag}'" ;;
  esac
}

# ---------------------------------------------------------------------------
# wwan_module_state <module> — print HOW the module is present and return 0, or
# return 1 when it is absent from all three collection maps.
# ---------------------------------------------------------------------------
wwan_module_state() {
  local nmod
  nmod="$(_wwan_norm "$1")"
  if [[ -n "${WWAN_LOADABLE[${nmod}]:-}" ]]; then
    printf 'loadable (=m) [%s]' "${WWAN_LOADABLE[${nmod}]}"
  elif [[ -n "${WWAN_BUILTIN[${nmod}]:-}" ]]; then
    printf 'built-in (=y, modules.builtin) [%s]' "${WWAN_BUILTIN[${nmod}]}"
  elif [[ -n "${WWAN_ALIAS[${nmod}]:-}" ]]; then
    printf 'alias (modules.alias)'
  else
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# wwan_check <module-tree-root> — scan the tree and report per-module presence.
# Returns 1 when a REQUIRED module is missing, 0 otherwise; the advisory set and
# the native-M.2 gate can never change that verdict, and neither can anything at
# all while CERALIVE_WWAN_CHECK_ADVISORY=1.
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

  local advisory_only=0
  if wwan_advisory_only; then
    advisory_only=1
    log_warn "CERALIVE_WWAN_CHECK_ADVISORY=1 — every module is reported ADVISORY and this check will exit 0 even if a REQUIRED module is missing"
  fi

  local mod state present=0 missing=0
  for mod in "${WWAN_REQUIRED_MODULES[@]}"; do
    if state="$(wwan_module_state "${mod}")"; then
      log_success "WWAN module present: ${mod} — ${state}"
      present=$((present + 1))
    elif (( advisory_only == 1 )); then
      log_warn "WWAN module MISSING: ${mod} — REQUIRED, but downgraded to ADVISORY by CERALIVE_WWAN_CHECK_ADVISORY=1; see docs/modem-matrix.md"
      missing=$((missing + 1))
    else
      log_error "WWAN module MISSING: ${mod} — REQUIRED for the USB modem datapath; see docs/modem-matrix.md"
      missing=$((missing + 1))
    fi
  done

  if (( missing == 0 )); then
    log_success "WWAN module-presence check: all ${#WWAN_REQUIRED_MODULES[@]} required modules present"
  elif (( advisory_only == 1 )); then
    log_warn "WWAN module-presence check: ${present}/${#WWAN_REQUIRED_MODULES[@]} required present, ${missing} missing (ADVISORY — CERALIVE_WWAN_CHECK_ADVISORY=1, check still passes)"
  else
    log_error "WWAN module-presence check: ${present}/${#WWAN_REQUIRED_MODULES[@]} required present, ${missing} missing (REQUIRED — this check FAILS)"
  fi

  wwan_check_advisory_modules
  wwan_check_native_m2

  if (( missing > 0 && advisory_only == 0 )); then
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# wwan_usage — the help text. It is the header's Usage/Environment block, kept
# in sync by being short enough to read: the escape hatch has to be discoverable
# from `--help`, not only from the file.
# ---------------------------------------------------------------------------
wwan_usage() {
  cat <<'USAGE'
Usage: check-wwan-modules.sh <kernel.deb | module-tree-dir>
       check-wwan-modules.sh -h | --help

Report whether the modem stack's kernel modules actually SHIPPED in a built
kernel .deb (or an extracted module tree). Severity is split:

  REQUIRED  the USB modem datapath and its control ports. A missing module is
            NAMED and the check exits non-zero.
  ADVISORY  the PCIe/MHI transport and host-side RNDIS. A missing module prints
            an ADVISORY line and the check still exits 0.

Environment:
  CERALIVE_WWAN_CHECK_ADVISORY=0|1
      1  report EVERY module ADVISORY and always exit 0 (the behaviour this
         check had before the severity split). For bisecting a kernel change or
         probing a deliberately narrow tree — not for a release build.
      0  the default: required modules fail closed.
      Any other value is refused.
USAGE
}

# ---------------------------------------------------------------------------
# check_wwan_main <input> — resolve a scan root (extract a .deb to a temp dir, or
# use a module tree directly), run the check, clean up, and PROPAGATE the
# verdict. An input that cannot be inspected at all stays a warn-and-pass: that
# is a statement about the host's tooling, not about the kernel's modules, and
# turning it into a failure would make the check refuse machines it was never
# asked to judge.
# ---------------------------------------------------------------------------
check_wwan_main() {
  if [[ $# -ge 1 ]] && args_is_help "$1"; then
    wwan_usage
    return 0
  fi
  [[ $# -ge 1 ]] || args_usage_die wwan_usage "missing argument: <kernel.deb | module-tree-dir>"
  local input="$1" root="" tmp="" rc=0

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

  wwan_check "${root}" || rc=$?

  if [[ -n "${tmp}" ]]; then
    rm -rf "${tmp}"
  fi

  if (( rc != 0 )); then
    # EXIT rather than `return ${rc}`, and this is not interchangeable. A
    # non-zero RETURN from the top-level call trips common.sh's ERR trap, which
    # prints `ERROR at …:NNN: return "${rc}"` UNDER the verdict and reads as the
    # checker itself having crashed — pointing a reader at this file instead of
    # at the missing module it just named. `exit` never trips the trap, so the
    # verdict stands alone and the trap stays armed for real faults. Disarming
    # it from in here cannot work: with errtrace unset bash removes the ERR trap
    # for the duration of a function and restores it on return, so a
    # `trap - ERR` inside this function is undone before the caller sees it.
    exit "${rc}"
  fi
  return 0
}

# Sourceable for tests (helpers exposed); run only when executed directly.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  check_wwan_main "$@"
fi
