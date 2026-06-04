#!/usr/bin/env bash
#
# customize/quirks.sh — board hardware-quirk dispatch.
#
# Reads the per-quirk flags declared in a board manifest's `quirks:` block (see
# v2/manifests/boards/*.yaml) and invokes a focused handler for each quirk we can
# satisfy at IMAGE/CONFIG level. Hardware/DT-level quirks are logged as DEFERRED.
# Unknown quirks NEVER hard-fail: they emit a warning and the loop continues
# (a manifest can legitimately predate a handler).
#
# IMPLEMENTED (config-level handlers):
#   usb_power_optimization   -> USB autosuspend udev policy (power budget tuning)
#   m2_modem_sim_workaround  -> ModemManager SIM-detection udev env for M.2 modems
#
# DEFERRED (NOT implementable at config level — documented only):
#   hdmi_input_emi_shield    -> DT/hardware-level; requires a vendor kernel DT
#                               overlay change. Owned by the hardware/DT track,
#                               not this image customize layer.
#
# MANIFEST RESOLUTION: this module is SOURCED by run-all.sh, which passes its own
# selector args (e.g. "runtime"), NOT a manifest path. So resolution order is:
#   1. a positional arg that is an existing file  (standalone / unit testing)
#   2. ${CERALIVE_BOARD_MANIFEST}                 (set by the orchestrator)
#   3. neither -> log a warning and SKIP (return 0). A run without a resolvable
#      board manifest is a legitimate no-op, not a build failure.
#
# SYSROOT PREFIX: handlers write under ${CERALIVE_SYSROOT} (empty in the chroot,
# so writes land on the real image root). Tests set it to a tmpdir to keep
# dispatch hermetic and non-root-safe. The rules file matches udev.sh's canonical
# 99-ceralive-hardware.rules and is APPENDED — quirks runs AFTER udev in run-all.
#
# CONTRACT: sourced by run-all.sh (chroot context). Strict; no `|| true` on real
# work (only on bash arithmetic post-increment, which returns the pre-value).
#
# shellcheck shell=bash

set -euo pipefail

# shellcheck source=../../lib/common.sh
source "${CERALIVE_COMMON_SH:-"$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd)/common.sh"}"

# Empty in production (writes hit the real image root); a tmpdir in tests.
readonly CERALIVE_SYSROOT="${CERALIVE_SYSROOT:-}"
readonly QUIRKS_RULES_FILE="${CERALIVE_SYSROOT}/etc/udev/rules.d/99-ceralive-hardware.rules"

# ---------------------------------------------------------------------------
# resolve_manifest — pick the board manifest path (see header for order).
#   Echoes the resolved path on success; returns 1 if none is resolvable.
# ---------------------------------------------------------------------------
resolve_manifest() {
  local arg="${1:-}"
  if [[ -n "${arg}" && -f "${arg}" ]]; then
    printf '%s\n' "${arg}"
    return 0
  fi
  if [[ -n "${CERALIVE_BOARD_MANIFEST:-}" && -f "${CERALIVE_BOARD_MANIFEST}" ]]; then
    printf '%s\n' "${CERALIVE_BOARD_MANIFEST}"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# parse_quirks — emit the quirk key names under the manifest's `quirks:` block,
# one per line. Minimal, dependency-free YAML slice (no yq in the chroot):
# enter on a top-level `quirks:` line, stop at the next top-level key.
# ---------------------------------------------------------------------------
parse_quirks() {
  local manifest="$1"
  local in_quirks=0 line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" =~ ^quirks:[[:space:]]*$ ]]; then
      in_quirks=1
      continue
    fi
    if [[ ${in_quirks} -eq 1 ]]; then
      # Next top-level key (non-space, non-comment) ends the block.
      if [[ "${line}" =~ ^[a-zA-Z] ]]; then
        break
      fi
      # Indented `  quirk_name: value` -> capture the key.
      if [[ "${line}" =~ ^[[:space:]]+([a-z_][a-z0-9_]*):[[:space:]] ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
      fi
    fi
  done <"${manifest}"
}

# ---------------------------------------------------------------------------
# Handler: usb_power_optimization
#   Enable USB autosuspend so power-hungry modems share the board's USB budget
#   (Rock 5B+ ~5.45 A). Pure udev policy — no daemon, no DT change.
# ---------------------------------------------------------------------------
handle_usb_power_optimization() {
  log_info "quirks: applying usb_power_optimization (USB autosuspend power policy)"
  cat >>"${QUIRKS_RULES_FILE}" <<'EOF'

# =============================================================================
# QUIRK usb_power_optimization — USB autosuspend power budget tuning
# =============================================================================
ACTION=="add", SUBSYSTEM=="usb", TEST=="power/control", ATTR{power/control}="auto"
ACTION=="add", SUBSYSTEM=="usb", TEST=="power/autosuspend_delay_ms", ATTR{power/autosuspend_delay_ms}="2000"
EOF
  log_success "quirks: usb_power_optimization applied"
}

# ---------------------------------------------------------------------------
# Handler: m2_modem_sim_workaround
#   M.2 B-key modems need ModemManager forced to probe + treat the port as a
#   candidate so SIM detection works. Adds ENV{ID_MM_*} to the modem vendor IDs
#   already group-tagged in udev.sh (Quectel 2c7c / Sierra 1199).
# ---------------------------------------------------------------------------
handle_m2_modem_sim_workaround() {
  log_info "quirks: applying m2_modem_sim_workaround (ModemManager SIM-detection env)"
  cat >>"${QUIRKS_RULES_FILE}" <<'EOF'

# =============================================================================
# QUIRK m2_modem_sim_workaround — force ModemManager probe for M.2 modems
# =============================================================================
SUBSYSTEM=="usb", ATTRS{idVendor}=="2c7c", ENV{ID_MM_DEVICE_PROCESS}="1", ENV{ID_MM_CANDIDATE}="1"
SUBSYSTEM=="usb", ATTRS{idVendor}=="1199", ENV{ID_MM_DEVICE_PROCESS}="1", ENV{ID_MM_CANDIDATE}="1"
EOF
  log_success "quirks: m2_modem_sim_workaround applied"
}

# ---------------------------------------------------------------------------
# dispatch_quirks — resolve the manifest, then route each declared quirk.
# ---------------------------------------------------------------------------
dispatch_quirks() {
  local manifest
  if ! manifest="$(resolve_manifest "${1:-}")"; then
    log_warn "quirks: no board manifest resolvable (arg not a file; CERALIVE_BOARD_MANIFEST unset/missing) — skipping quirk dispatch"
    return 0
  fi

  log_info "quirks: dispatching from manifest ${manifest}"
  mkdir -p "$(dirname -- "${QUIRKS_RULES_FILE}")"

  local handled=0 deferred=0 unknown=0 quirk
  while IFS= read -r quirk; do
    [[ -n "${quirk}" ]] || continue
    case "${quirk}" in
      usb_power_optimization)
        handle_usb_power_optimization
        handled=$((handled + 1))
        ;;
      m2_modem_sim_workaround)
        handle_m2_modem_sim_workaround
        handled=$((handled + 1))
        ;;
      hdmi_input_emi_shield)
        # DT/hardware-level: requires a vendor kernel DT overlay change. Cannot
        # be satisfied at config level — documented + deferred, never handled.
        log_warn "quirks: hdmi_input_emi_shield — DEFERRED (DT/hardware-level; vendor kernel DT overlay; not applicable at config level)"
        deferred=$((deferred + 1))
        ;;
      *)
        log_warn "quirks: unknown quirk '${quirk}' — skipping (no handler), continuing"
        unknown=$((unknown + 1))
        ;;
    esac
  done < <(parse_quirks "${manifest}")

  log_success "quirks: dispatch complete — ${handled} applied, ${deferred} deferred, ${unknown} unknown"
}

dispatch_quirks "$@"
