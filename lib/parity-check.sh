#!/usr/bin/env bash
#
# parity-check.sh — assert a built CeraLive rootfs reproduces today's image.
#
#   parity-check.sh <rootfs-tree>
#
# The canonical parity reference is the v2 package manifests:
# manifests/packages/shared.list plus every <family>.delta.list — the same
# runtime set mkosi installs and tests/package-migration-coverage.sh guards.
# The checklist verifies, against the built tree:
#
#   A. PACKAGES   every shared.list (+ family delta) package is installed (empty
#                 diff). Class:
#                   debian       — must be installed now (hard FAIL if missing)
#                   armbian-bsp  — gstreamer1.0-rockchip1 / rockchip-multimedia-config
#                                  (families/rk3588.yaml HW-accel + runtime)
#                   first-party  — CeraLive SRT/ceraui/cerastream/srtla-send-rs (CI: apt; offline → WARN)
#   B. USER       `ceralive` user exists + is in audio/video/dialout/plugdev/
#                 netdev/sudo/gpio/i2c/spi
#   C. SERVICES   NetworkManager, ModemManager, ssh, chrony, avahi-daemon,
#                 systemd-resolved, ceralive-hostname enabled
#   D. ROUTING    the retired SRTLA source-policy routing assets are ABSENT
#                 (rt_tables reservations, dhclient hook, NM dispatcher)
#   E. UDEV/APT   udev hardware rules + deb822 Debian sources + apt.ceralive.tv,
#                 plus two properties dpkg itself cannot report: no packaged udev
#                 rules file shadowed by an image-owned /etc basename, and exactly
#                 one owner for every modem-support file present
#
# Pure filesystem reads — NO dpkg/chroot needed (host may be Arch). Exit 0 only
# when there are zero hard FAILs; CI-gated gaps (first-party offline) are WARNs.
#
# shellcheck shell=bash

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${HERE}/common.sh"
# shellcheck source=lib/shared/modem-support-lib.sh
source "${HERE}/shared/modem-support-lib.sh"

# common.sh installs an ERR trap that exits 1; this script intentionally collects
# failures and reports a summary, so drop the trap and own the exit code.
trap - ERR

SHARED_LIST="${SHARED_LIST:-${HERE}/../manifests/packages/shared.list}"
PKG_MANIFEST_DIR="${PKG_MANIFEST_DIR:-${HERE}/../manifests/packages}"
MODEM_SUPPORT_LEDGER="${MODEM_SUPPORT_LEDGER:-${HERE}/../manifests/modem-support-ownership.txt}"

# Reference names that the real .deb ships under another name. Without these
# aliases the gate could never clear the app-layer check even after a real
# install — the installed names never match the reference names.
# (The legacy belacoder→ceracoder alias is gone: ceracoder was retired 2026-06-11;
# cerastream — the sole engine — ships under its own package name, no alias needed.)
declare -A PKG_ALIAS=(
  [media-ctl]=v4l-utils         # media-ctl binary ships in v4l-utils on bookworm
  [ceraui]=ceralive-device      # CeraUI .deb package name = ceralive-device
)
# Rockchip HW GStreamer pair — families/rk3588.yaml hw_accel_gstreamer_plugins +
# gstreamer_runtime_packages, installed from the Armbian pool (platform layer).
ARMBIAN_BSP_PKGS=" gstreamer1.0-rockchip1 rockchip-multimedia-config "
# First-party .debs (App layer) — built upstream, fetched in CI from R2/gh.
# Mirrors fetch-debs.sh REPOS (+ the ceraui alias above). Offline these are
# absent → reported as WARN, never silent.
FIRST_PARTY_PKGS=" libsrt1.5-ceralive ceraui cerastream srtla-send-rs "

PASS=0; WARN=0; FAIL=0
pass() { log_success "PASS  $*"; PASS=$((PASS+1)); }
warn() { log_warn    "WARN  $*"; WARN=$((WARN+1)); }
fail() { log_error   "FAIL  $*"; FAIL=$((FAIL+1)); }

# find_first <name> [find-predicates…] -- <dir…> — first match, or empty.
#
# NEVER `find … | grep -q .`: find keeps traversing after the match it printed,
# `grep -q` closes the pipe on that first line, find dies of SIGPIPE, and under
# common.sh's `set -o pipefail` the whole condition reads FALSE for a unit that IS
# enabled. Here that mode is a false PASS on the production ssh check — the gate
# would certify an SSH-reachable production image. Capture in a substitution and
# stop find itself with -quit, so nothing closes a pipe early.
find_first() {
  local name="$1"; shift
  local preds=()
  while (( $# )) && [[ "$1" != "--" ]]; do preds+=("$1"); shift; done
  shift || true
  find "$@" -name "${name}" "${preds[@]}" -print -quit 2>/dev/null
}

# ---------------------------------------------------------------------------
# read_manifest_packages — echo every active package in the canonical v2 runtime
# package lists: manifests/packages/shared.list plus every <family>.delta.list,
# plus the variant-keyed development.delta.list when CERALIVE_DEBUG_IMAGE=1.
# Comments and blank lines are stripped.
#
# File selection is delegated to common.sh::runtime_pkg_list_files so the debug
# delta cannot leak into a PRODUCTION parity run: a bare `*.delta.list` glob here
# would demand python3/strace/tcpdump/… in every production rootfs and fail the
# [7/9] gate on the very image that is correct.
# ---------------------------------------------------------------------------
read_manifest_packages() {
  local f
  while IFS= read -r f; do
    [[ -n "${f}" ]] || continue
    sed -e 's/#.*//' "${f}" | awk 'NF{print $1}'
  done < <(runtime_pkg_list_files "${SHARED_LIST}" "${PKG_MANIFEST_DIR}")
}

main() {
  local root="${1:-}"
  [[ -n "${root}" ]] || die "usage: parity-check.sh <rootfs-tree>"
  [[ -d "${root}" ]] || die "rootfs tree not found: ${root}"
  [[ -f "${SHARED_LIST}" ]] || die "canonical parity reference not found: ${SHARED_LIST}"

  log_info "=== CeraLive parity check ==="
  log_info "rootfs=${root}"
  log_info "reference=${SHARED_LIST}"

  local status_file="${root}/var/lib/dpkg/status"
  [[ -f "${status_file}" ]] || die "no dpkg status in rootfs (${status_file}) — not a Debian rootfs?"

  # Installed package set (Status: install ok installed) — pure parse, no dpkg.
  local installed
  installed=" $(awk '
    /^Package: / { pkg=$2 }
    /^Status: / { st=$0 }
    /^$/ { if (st ~ /install ok installed/ && pkg!="") print pkg; pkg=""; st="" }
    END { if (st ~ /install ok installed/ && pkg!="") print pkg }
  ' "${status_file}" | sort -u | tr '\n' ' ') "
  local n_installed
  n_installed="$(echo "${installed}" | wc -w)"
  log_info "rootfs has ${n_installed} installed packages"

  # ---- A. PACKAGE PARITY vs v2 manifests ----
  log_info "--- A. package parity (vs v2 manifests: shared.list + family deltas) ---"
  local expected=() p
  while IFS= read -r p; do [[ -n "${p}" ]] && expected+=("${p}"); done \
    < <(read_manifest_packages)
  local n_manifest="${#expected[@]}"
  # The Armbian-BSP GStreamer pair (family manifest) and the first-party .debs
  # (App layer) live OUTSIDE the runtime package lists, so the gate must add them
  # to the checked set to keep their WARN classification below.
  local bsp_arr=() firstparty_arr=()
  read -ra bsp_arr        <<< "${ARMBIAN_BSP_PKGS}"
  read -ra firstparty_arr <<< "${FIRST_PARTY_PKGS}"
  expected+=("${bsp_arr[@]}" "${firstparty_arr[@]}")
  log_info "v2 manifests declare ${n_manifest} runtime packages (shared.list + family deltas)"

  local debian_missing=() armbian_missing=() firstparty_missing=() check
  for p in "${expected[@]}"; do
    check="${PKG_ALIAS[$p]:-$p}"
    if [[ "${installed}" == *" ${check} "* ]]; then
      continue
    fi
    if [[ "${FIRST_PARTY_PKGS}" == *" ${p} "* ]]; then
      firstparty_missing+=("${p}")
    elif [[ "${ARMBIAN_BSP_PKGS}" == *" ${p} "* ]]; then
      armbian_missing+=("${p}")
    else
      debian_missing+=("${p}")
    fi
  done

  if (( ${#debian_missing[@]} == 0 )); then
    pass "all Debian-sourced shared.list packages installed (diff empty)"
  else
    fail "Debian packages MISSING from rootfs: ${debian_missing[*]}"
  fi
  if (( ${#armbian_missing[@]} == 0 )); then
    pass "Armbian-BSP GStreamer packages installed (gstreamer1.0-rockchip1, rockchip-multimedia-config)"
  else
    warn "Armbian-BSP packages not installed (need Armbian pool at build time): ${armbian_missing[*]}"
  fi
  if (( ${#firstparty_missing[@]} == 0 )); then
    pass "first-party packages installed (libsrt1.5-ceralive/ceraui/cerastream/srtla-send-rs)"
  else
    fail "first-party packages MISSING from rootfs: ${firstparty_missing[*]}"
  fi

  # ---- B. ceralive USER + GROUPS ----
  log_info "--- B. ceralive user + hardware groups ---"
  if grep -q '^ceralive:' "${root}/etc/passwd" 2>/dev/null; then
    pass "user 'ceralive' exists"
    local grp grp_missing=()
    for grp in sudo audio video dialout plugdev netdev gpio i2c spi; do
      if grep -qE "^${grp}:.*[:,]ceralive(,|$)" "${root}/etc/group" 2>/dev/null; then :; else grp_missing+=("${grp}"); fi
    done
    if (( ${#grp_missing[@]} == 0 )); then
      pass "ceralive is a member of all hardware groups (audio/video/dialout/plugdev/netdev/sudo/gpio/i2c/spi)"
    else
      fail "ceralive NOT in group(s): ${grp_missing[*]}"
    fi
  else
    fail "user 'ceralive' not present in /etc/passwd"
  fi
  if [[ -x "${root}/usr/bin/sudo" ]]; then
    pass "sudo binary present for CeraUI privileged helper"
  else
    fail "sudo binary missing — CeraUI add-on sudoers drop-in cannot execute"
  fi

  # ---- C. SERVICES ENABLED ----
  log_info "--- C. services enabled ---"
  local svc svc_missing=()
  for svc in NetworkManager ModemManager chrony avahi-daemon systemd-resolved ceralive-hostname; do
    if [[ -n "$(find_first "${svc}.service" -type l -- \
                  "${root}/etc/systemd/system" "${root}/usr/lib/systemd/system")" \
       || -n "$(find_first "${svc}.service" -- "${root}/etc/systemd/system")" ]]; then
      :
    else
      svc_missing+=("${svc}")
    fi
  done
  if (( ${#svc_missing[@]} == 0 )); then
    pass "all required services enabled (NetworkManager/ModemManager/chrony/avahi-daemon/systemd-resolved/ceralive-hostname)"
  else
    fail "service(s) not enabled: ${svc_missing[*]}"
  fi

  # ssh.service enablement is image-kind-gated (PR #60 / Todo-42): a production
  # image (CERALIVE_DEBUG_IMAGE != 1) ships ssh NOT enabled — the operator turns
  # SSH on from CeraUI — while a lab debug image (=1) keeps it enabled by default.
  # configure_ssh_enablement() actively `systemctl disable ssh.service`s on
  # production, so assert the correct per-kind invariant rather than a blanket
  # "ssh enabled" (which regressed here once #60 landed disabled-by-default).
  local ssh_enabled=0
  if [[ -n "$(find_first ssh.service -type l -- "${root}/etc/systemd/system")" ]]; then
    ssh_enabled=1
  fi
  if [[ "${CERALIVE_DEBUG_IMAGE:-0}" == "1" ]]; then
    if (( ssh_enabled == 1 )); then
      pass "lab debug image: ssh.service enabled by default"
    else
      fail "lab debug image: ssh.service expected enabled but is not"
    fi
  elif (( ssh_enabled == 0 )); then
    pass "production image: ssh.service NOT enabled by default (operator enables via CeraUI) — Todo-42/PR#60"
  else
    fail "production image: ssh.service is enabled but MUST be disabled-by-default — Todo-42/PR#60"
  fi
  local cera_service="${root}/etc/systemd/system/ceralive.service"
  if [[ -f "${cera_service}" ]]; then
    local cera_exec
    cera_exec="$(sed -n 's/^ExecStart=//p' "${cera_service}" | awk 'NR == 1 { print $1 }')"
    if [[ -n "${cera_exec}" && -x "${root}${cera_exec}" ]]; then
      pass "ceralive.service ExecStart target exists and is executable (${cera_exec})"
    else
      fail "ceralive.service ExecStart target missing/not executable: ${cera_exec:-<empty>}"
    fi
    if [[ -L "${root}/etc/systemd/system/multi-user.target.wants/ceralive.service" ]]; then
      pass "ceralive.service enabled for multi-user boot"
    else
      fail "ceralive.service is not enabled for multi-user boot"
    fi
  else
    warn "ceralive.service absent — first-party CeraUI package not installed"
  fi

  # ---- D. RETIRED SRTLA SOURCE-POLICY ROUTING ----
  # Inverted from a presence check: the layer is retired (evidence/todo38.md).
  # Bonding pins egress per link with SO_BINDTODEVICE, and on the shipped edge
  # kernel `ip rule` is unsupported, so these assets could only mis-route.
  log_info "--- D. retired SRTLA source-policy routing (must be absent) ---"
  if grep -qE '^1(0[0-7]|2[0-4])[[:space:]]+(modem|wlan)[0-7]' \
       "${root}/etc/iproute2/rt_tables" 2>/dev/null; then
    fail "rt_tables still reserves the retired SRTLA bonding tables"
  else
    pass "rt_tables carries no retired SRTLA bonding tables"
  fi
  if [[ -e "${root}/etc/dhcp/dhclient-exit-hooks.d/srtla-source-routing" ]]; then
    fail "retired dhclient SRTLA source-routing hook is present"
  else
    pass "dhclient SRTLA source-routing hook absent"
  fi
  if [[ -e "${root}/etc/NetworkManager/dispatcher.d/90-srtla-wifi-routing" ]]; then
    fail "retired NetworkManager SRTLA wifi-routing dispatcher is present"
  else
    pass "NetworkManager SRTLA wifi-routing dispatcher absent"
  fi

  # ---- E. UDEV + APT ----
  log_info "--- E. udev rules + apt sources ---"
  if [[ -f "${root}/etc/udev/rules.d/99-ceralive-hardware.rules" ]]; then
    pass "udev hardware-access rules present"
  else
    fail "udev hardware-access rules missing"
  fi
  if [[ -f "${root}/etc/apt/sources.list.d/debian.sources" ]]; then
    pass "deb822 Debian apt sources present"
  else
    fail "deb822 Debian apt sources missing"
  fi
  if [[ -f "${root}/etc/apt/sources.list.d/ceralive.sources" ]]; then
    pass "apt.ceralive.tv repository configured"
  else
    fail "apt.ceralive.tv repository missing"
  fi
  # The build-time Armbian pool must NOT leak into the final image.
  if [[ -f "${root}/etc/apt/sources.list.d/armbian.sources" ]]; then
    fail "build-time Armbian pool leaked into the final image apt config"
  else
    pass "no build-time Armbian pool in final image (clean apt config)"
  fi
  # udev resolves rules by BASENAME and /etc wins over /usr/lib, so an image-owned
  # /etc file sharing a packaged basename replaces the packaged rules entirely —
  # while dpkg keeps reporting them installed and intact. No dpkg check can see it.
  local shadowed
  if shadowed="$(udev_shadow_scan_rootfs "${root}")"; then
    pass "no packaged udev rules file is shadowed by an image-owned /etc/udev/rules.d basename"
  else
    fail "shadowed udev rule basename(s): $(tr '\n' '; ' <<<"${shadowed}")"
  fi
  local ownership
  if ownership="$(modem_support_ownership_violations "${root}" "${MODEM_SUPPORT_LEDGER}")"; then
    pass "every present modem-support file has exactly one owner (no orphans, no double ownership)"
  else
    fail "modem-support ownership violation(s): $(tr '\n' '; ' <<<"${ownership}")"
  fi

  # ---- F. INTERFACE NAMING ----
  log_info "--- F. deterministic interface naming (.link units) ---"
  if [[ -f "${root}/etc/systemd/network/10-ceralive-wlan0.link" ]]; then
    pass "wlan0 .link file present (interface naming standardization)"
  else
    fail "wlan0 .link file missing — wlan0 rename won't apply, SRTLA wifi routing broken"
  fi

  # ---- summary ----
  log_info "=== parity summary: ${PASS} pass / ${WARN} warn / ${FAIL} fail ==="
  if (( FAIL > 0 )); then
    log_error "PARITY FAILED (${FAIL} hard failure(s))"
    return 1
  fi
  if (( WARN > 0 )); then
    log_warn "parity OK with ${WARN} CI-gated warning(s) (first-party / Armbian-BSP debs need network+creds)"
  fi
  log_success "PARITY OK"
  return 0
}

main "$@"
