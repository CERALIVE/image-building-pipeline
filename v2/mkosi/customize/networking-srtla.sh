#!/usr/bin/env bash
#
# customize/networking-srtla.sh — SRTLA source-policy routing for bonded links.
#
# DECOMPOSED FROM: userpatches/customize-image.sh:configure_srtla_routing()
# (L286-431). This is LOAD-BEARING for SRTLA multi-link bonding — do not break
# the table numbers or the hook/dispatcher logic.
#
#   * rt_tables  : 100-107 = modem0..modem7 (USB modems), 120-124 = wlan0..wlan4 (WiFi).
#   * dhclient   : /etc/dhcp/dhclient-exit-hooks.d/srtla-source-routing installs a
#                  per-source default route in the matching table when a modem /
#                  wired iface gets a DHCP lease, and tears it down on release.
#                  RISK: NM defaults to dhcp=internal in bookworm and does NOT exec
#                  dhclient-exit-hooks.d/ — modem routing may never fire for
#                  NM-managed interfaces. See AGENTS.md §KNOWN ISSUES.
#   * NM dispatch: /etc/NetworkManager/dispatcher.d/90-srtla-wifi-routing does the
#                  same for NetworkManager-managed wlan0..wlan4 interfaces, each in
#                  its own table 120+N (per srtla/docs/NETWORK_SETUP.md).
#                  NOTE: wlan* matches because postinst-lib.sh install_interface_naming()
#                  emits a systemd .link file renaming the onboard wifi to wlan0
#                  before NM brings it up. Same applies to eth* (→ eth0).
#
# The runtime payload scripts keep their internal `2>/dev/null || true` guards:
# those run on the LIVE device against transient kernel routing state (a rule
# that does not exist yet is normal), NOT during image build. The BUILD-TIME
# logic in this module is strict with no `|| true`.
#
# CONTRACT: sourced by run-all.sh (chroot context). Strict; no build-time
# `|| true`. ipcalc + iproute2 are installed declaratively (runtime mkosi.conf),
# replacing v1's in-chroot `apt-get install -y ipcalc … || true` (L427-428).
#
# shellcheck shell=bash

set -euo pipefail

# shellcheck source=../../lib/common.sh
source "${CERALIVE_COMMON_SH:-"$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd)/common.sh"}"

# Reserve routing tables for bonded interfaces. v1 L294-308.
install_rt_tables() {
  if grep -q "^100[[:space:]]\+modem0" /etc/iproute2/rt_tables 2>/dev/null; then
    log_info "SRTLA routing tables already present in /etc/iproute2/rt_tables"
    return 0
  fi
  log_info "reserving SRTLA routing tables 100-107 (modems) + 120-124 (wlan0..wlan4)"
  cat >>/etc/iproute2/rt_tables <<'EOF'

# SRTLA bonding routing tables
100     modem0
101     modem1
102     modem2
103     modem3
104     modem4
105     modem5
106     modem6
107     modem7
120     wlan0
121     wlan1
122     wlan2
123     wlan3
124     wlan4
EOF
}

# dhclient exit hook: source-policy routing for DHCP modems/wired ifaces.
# v1 L310-376. Payload runs on the live device, hence its own transient guards.
install_dhclient_hook() {
  log_info "installing dhclient SRTLA source-routing hook"
  mkdir -p /etc/dhcp/dhclient-exit-hooks.d
  cat >/etc/dhcp/dhclient-exit-hooks.d/srtla-source-routing <<'HOOKEOF'
#!/bin/bash
# SRTLA Source Policy Routing for DHCP interfaces
# Routes packets out the correct interface based on source IP.

case "$interface" in
    usb*|eth*|enx*) ;;
    *) exit 0 ;;
esac

case "$interface" in
    usb0|enx*0) TABLE=100 ;;
    usb1|enx*1) TABLE=101 ;;
    usb2|enx*2) TABLE=102 ;;
    usb3|enx*3) TABLE=103 ;;
    usb4|enx*4) TABLE=104 ;;
    usb5|enx*5) TABLE=105 ;;
    usb6|enx*6) TABLE=106 ;;
    usb7|enx*7) TABLE=107 ;;
    *) TABLE="" ;;
esac

[ -z "$TABLE" ] && exit 0

case "$reason" in
    BOUND|RENEW|REBIND|REBOOT)
        if [ -n "$new_ip_address" ] && [ -n "$new_routers" ]; then
            GATEWAY=$(echo "$new_routers" | awk '{print $1}')
            ip rule del from "$new_ip_address" table "$TABLE" 2>/dev/null || true
            ip route flush table "$TABLE" 2>/dev/null || true
            ip rule add from "$new_ip_address" table "$TABLE" priority 100
            ip route add default via "$GATEWAY" dev "$interface" table "$TABLE"
            if [ -n "$new_subnet_mask" ]; then
                NETWORK=$(ipcalc -n "$new_ip_address" "$new_subnet_mask" 2>/dev/null | grep -oP 'NETWORK=\K.*' || echo "")
                PREFIX=$(ipcalc -p "$new_ip_address" "$new_subnet_mask" 2>/dev/null | grep -oP 'PREFIX=\K.*' || echo "24")
                if [ -n "$NETWORK" ]; then
                    ip route add "$NETWORK/$PREFIX" dev "$interface" table "$TABLE" 2>/dev/null || true
                fi
            fi
            logger -t srtla-routing "Added source routing for $interface ($new_ip_address) via $GATEWAY table $TABLE"
        fi
        ;;
    EXPIRE|FAIL|RELEASE|STOP)
        ip rule del from "$old_ip_address" table "$TABLE" 2>/dev/null || true
        ip route flush table "$TABLE" 2>/dev/null || true
        logger -t srtla-routing "Removed source routing for $interface table $TABLE"
        ;;
esac
HOOKEOF
  chmod +x /etc/dhcp/dhclient-exit-hooks.d/srtla-source-routing
}

# NetworkManager dispatcher: source-policy routing for wlan0..wlan4 (tables 120-124).
# v1 L378-425. Payload runs on the live device, hence its own transient guards.
install_nm_dispatcher() {
  log_info "installing NetworkManager SRTLA WiFi-routing dispatcher"
  mkdir -p /etc/NetworkManager/dispatcher.d
  cat >/etc/NetworkManager/dispatcher.d/90-srtla-wifi-routing <<'DISPEOF'
#!/bin/bash
# SRTLA Source Routing for WiFi interfaces managed by NetworkManager
INTERFACE="$1"
ACTION="$2"

case "$INTERFACE" in
    wlan[0-4]) ;;
    *) exit 0 ;;
esac

TABLE=$((120 + ${INTERFACE#wlan}))

case "$ACTION" in
    up|dhcp4-change)
        IP=$(ip -4 addr show "$INTERFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
        GATEWAY=$(ip route show dev "$INTERFACE" | grep default | awk '{print $3}' | head -1)
        if [ -n "$IP" ] && [ -n "$GATEWAY" ]; then
            ip rule del from "$IP" table "$TABLE" 2>/dev/null || true
            ip route flush table "$TABLE" 2>/dev/null || true
            ip rule add from "$IP" table "$TABLE" priority 100
            ip route add default via "$GATEWAY" dev "$INTERFACE" table "$TABLE"
            logger -t srtla-routing "WiFi source routing: $INTERFACE ($IP) via $GATEWAY table $TABLE"
        fi
        ;;
    down)
        IP=$(ip -4 addr show "$INTERFACE" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
        [ -n "$IP" ] && ip rule del from "$IP" table "$TABLE" 2>/dev/null || true
        ip route flush table "$TABLE" 2>/dev/null || true
        logger -t srtla-routing "WiFi source routing removed for $INTERFACE table $TABLE"
        ;;
esac
DISPEOF
  chmod +x /etc/NetworkManager/dispatcher.d/90-srtla-wifi-routing
}

configure_srtla_routing() {
  install_rt_tables
  install_dhclient_hook
  install_nm_dispatcher
  log_success "SRTLA source-policy routing configured (tables 100-107 + 120-124)"
}

configure_srtla_routing "$@"
