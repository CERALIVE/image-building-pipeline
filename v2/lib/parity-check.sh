#!/usr/bin/env bash
#
# parity-check.sh — assert a built CeraLive rootfs reproduces today's image.
#
#   parity-check.sh <rootfs-tree>
#
# The canonical parity reference is configs/base/ceraui-base.conf (richer than
# customize-image.sh — it also names gstreamer1.0-rockchip1, rockchip-multimedia-
# config and pulseaudio). The checklist verifies, against the built tree:
#
#   A. PACKAGES   every ceraui-base.conf package is installed (empty diff). Class:
#                   debian       — must be installed now (hard FAIL if missing)
#                   armbian-bsp  — gstreamer1.0-rockchip1 / rockchip-multimedia-config
#                   first-party  — ceraui/belacoder/srtla/srt (CI: R2/gh; offline → WARN)
#   B. USER       `ceralive` user exists + is in audio/video/dialout/plugdev/
#                 netdev/sudo/gpio/i2c/spi
#   C. SERVICES   NetworkManager, ModemManager, ssh, chrony, avahi-daemon,
#                 systemd-resolved, ceralive-hostname enabled
#   D. ROUTING    SRTLA source-policy routing files present (rt_tables tables,
#                 dhclient hook, NM dispatcher)
#   E. UDEV/APT   udev hardware rules + deb822 Debian sources + apt.ceralive.tv
#
# Pure filesystem reads — NO dpkg/chroot needed (host may be Arch). Exit 0 only
# when there are zero hard FAILs; CI-gated gaps (first-party offline) are WARNs.
#
# shellcheck shell=bash

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${HERE}/common.sh"

# common.sh installs an ERR trap that exits 1; this script intentionally collects
# failures and reports a summary, so drop the trap and own the exit code.
trap - ERR

CERAUI_BASE_CONF="${CERAUI_BASE_CONF:-${HERE}/../../configs/base/ceraui-base.conf}"

# Packages that ceraui-base.conf names but Debian ships inside another package.
declare -A PKG_ALIAS=(
  [media-ctl]=v4l-utils         # media-ctl binary ships in v4l-utils on bookworm
)
# The Rockchip HW GStreamer set — installed from the Armbian pool (platform layer).
ARMBIAN_BSP_PKGS=" gstreamer1.0-rockchip1 rockchip-multimedia-config "
# First-party .debs (ceraui-base.conf CERAUI_PACKAGES) — built upstream, fetched
# in CI from R2/gh. Offline these are absent → reported as WARN, never silent.
FIRST_PARTY_PKGS=" ceraui belacoder srtla srt "

PASS=0; WARN=0; FAIL=0
pass() { log_success "PASS  $*"; PASS=$((PASS+1)); }
warn() { log_warn    "WARN  $*"; WARN=$((WARN+1)); }
fail() { log_error   "FAIL  $*"; FAIL=$((FAIL+1)); }

# ---------------------------------------------------------------------------
# extract_array <conf> <ARRAY_NAME> — echo the quoted items of a bash array
# literal spanning NAME=( ... ), ignoring comments. No sourcing (untrusted-ish).
# ---------------------------------------------------------------------------
extract_array() {
  local conf="$1" name="$2"
  awk -v name="${name}" '
    $0 ~ "^"name"=\\(" { inarr=1; sub("^"name"=\\(", ""); }
    inarr {
      line=$0
      sub(/#.*/, "", line)
      n=split(line, toks, /"/)
      for (i=2; i<=n; i+=2) if (toks[i] != "") print toks[i]
      if (line ~ /\)/) inarr=0
    }
  ' "${conf}"
}

main() {
  local root="${1:-}"
  [[ -n "${root}" ]] || die "usage: parity-check.sh <rootfs-tree>"
  [[ -d "${root}" ]] || die "rootfs tree not found: ${root}"
  [[ -f "${CERAUI_BASE_CONF}" ]] || die "canonical parity reference not found: ${CERAUI_BASE_CONF}"

  log_info "=== CeraLive parity check ==="
  log_info "rootfs=${root}"
  log_info "reference=${CERAUI_BASE_CONF}"

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

  # ---- A. PACKAGE PARITY vs ceraui-base.conf ----
  log_info "--- A. package parity (vs ceraui-base.conf) ---"
  local expected=() arr p
  for arr in BASE_PACKAGES STREAMING_PACKAGES CERAUI_PACKAGES; do
    while IFS= read -r p; do [[ -n "${p}" ]] && expected+=("${p}"); done \
      < <(extract_array "${CERAUI_BASE_CONF}" "${arr}")
  done
  log_info "ceraui-base.conf declares ${#expected[@]} packages across BASE/STREAMING/CERAUI"

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
    pass "all Debian-sourced ceraui-base.conf packages installed (diff empty)"
  else
    fail "Debian packages MISSING from rootfs: ${debian_missing[*]}"
  fi
  if (( ${#armbian_missing[@]} == 0 )); then
    pass "Armbian-BSP GStreamer packages installed (gstreamer1.0-rockchip1, rockchip-multimedia-config)"
  else
    warn "Armbian-BSP packages not installed (need Armbian pool at build time): ${armbian_missing[*]}"
  fi
  if (( ${#firstparty_missing[@]} == 0 )); then
    pass "first-party packages installed (ceraui/belacoder/srtla/srt)"
  else
    warn "first-party packages not installed: ${firstparty_missing[*]} — require R2/gh creds (CI mode); offline dev build cannot fetch them"
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

  # ---- C. SERVICES ENABLED ----
  log_info "--- C. services enabled ---"
  local svc svc_missing=()
  for svc in NetworkManager ModemManager ssh chrony avahi-daemon systemd-resolved ceralive-hostname; do
    if find "${root}/etc/systemd/system" "${root}/usr/lib/systemd/system" \
         -name "${svc}.service" -type l 2>/dev/null | grep -q . \
       || find "${root}/etc/systemd/system" -name "${svc}.service" 2>/dev/null | grep -q .; then
      :
    else
      svc_missing+=("${svc}")
    fi
  done
  if (( ${#svc_missing[@]} == 0 )); then
    pass "all required services enabled (NetworkManager/ModemManager/ssh/chrony/avahi-daemon/systemd-resolved/ceralive-hostname)"
  else
    fail "service(s) not enabled: ${svc_missing[*]}"
  fi

  # ---- D. SRTLA SOURCE-POLICY ROUTING ----
  log_info "--- D. SRTLA source-policy routing ---"
  local routing_ok=1
  if grep -qE '^100[[:space:]]+modem0' "${root}/etc/iproute2/rt_tables" 2>/dev/null \
     && grep -qE '^110[[:space:]]+wlan_bond' "${root}/etc/iproute2/rt_tables" 2>/dev/null; then
    pass "rt_tables has SRTLA bonding tables (modem0..modem7 + wlan_bond)"
  else
    fail "rt_tables missing SRTLA bonding tables"; routing_ok=0
  fi
  if [[ -x "${root}/etc/dhcp/dhclient-exit-hooks.d/srtla-source-routing" ]]; then
    pass "dhclient SRTLA source-routing hook present + executable"
  else
    fail "dhclient SRTLA source-routing hook missing/not executable"; routing_ok=0
  fi
  if [[ -x "${root}/etc/NetworkManager/dispatcher.d/90-srtla-wifi-routing" ]]; then
    pass "NetworkManager SRTLA wifi-routing dispatcher present + executable"
  else
    fail "NetworkManager SRTLA wifi-routing dispatcher missing/not executable"; routing_ok=0
  fi
  [[ "${routing_ok}" == 1 ]] || true

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
