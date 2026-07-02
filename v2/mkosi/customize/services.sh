#!/usr/bin/env bash
#
# customize/services.sh — systemd service enablement + network-service config +
# the first-boot unique-hostname service + the boot healthcheck (task 29) and
# cert rotation (task 42) units.
#
# SINGLE SOURCE OF TRUTH (Task 6): the actual logic lives ONCE in
# customize/postinst-lib.sh and is sourced here. This module used to carry its
# own copies of configure_network_services / configure_services /
# install_hostname_service / install_healthcheck_service / install_cert_rotation
# that "dual-tracked" the inline twins in the wired runtime executor
# mkosi.images/runtime/mkosi.postinst.chroot and silently drifted from them. Both
# tracks now share postinst-lib.sh, and v2/ci/postinst-drift-check.sh fails CI if
# an inline twin is ever reintroduced.
#
# The decomposition is functionally unchanged from v1
# (userpatches/customize-image.sh): configure_services() L511-542, the service/
# network half of configure_networking() L471-509, setup_hostname_service()
# L544-622, plus the committed boot-healthcheck + cert-rotation artifacts under
# v2/mkosi/runtime/.
#
# v1 CONTRADICTION RESOLVED (now in postinst-lib.sh): v1 BOTH enabled (L519) and
# disabled (L534) ModemManager. v2 ENABLES it (cellular modems are core to bonded
# streaming) and drops it from the disable set.
#
# STRICT semantics (common.sh DESIGN RULE): enable a unit we EXPECT must be
# enableable (no `|| true`); disabling a never-installed unit is a guarded no-op.
#
# CONTRACT: sourced by run-all.sh (chroot context). Strict; no `|| true`.
#
# shellcheck shell=bash

set -euo pipefail

# shellcheck source=../../lib/common.sh
source "${CERALIVE_COMMON_SH:-"$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd)/common.sh"}"

SERVICES_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Committed source artifacts (boot healthcheck + cert rotation) live under
# v2/mkosi/runtime/; postinst-lib.sh installs them from CERALIVE_RUNTIME_SRC.
CERALIVE_RUNTIME_SRC="$(CDPATH='' cd -- "${SERVICES_DIR}/../runtime" 2>/dev/null && pwd)" || true
export CERALIVE_RUNTIME_SRC

# shellcheck source=postinst-lib.sh
source "${SERVICES_DIR}/postinst-lib.sh"

# Service enablement + network config + hostname + healthcheck + cert rotation,
# in the same dependency-correct order as before — every function is defined in
# postinst-lib.sh (the single source shared with the runtime postinst).
configure_network_services() {
  configure_networking          # static hostname/hosts, mDNS, NetworkManager conf
  configure_services            # enable required services, disable unneeded
  setup_hostname_service        # first-boot unique-hostname service
  setup_boot_healthcheck        # task 29: gate rauc mark-good on streaming health
  setup_cert_rotation           # task 42: baked-in intermediate/leaf rotation
  setup_provisioning            # task 11: first-boot WiFi provisioning AP (trigger + AP mode)
  setup_tls_proxy               # task 15: nginx TLS front on 443 -> 127.0.0.1:80 (port 80 kept; SC3)
  setup_rtmp_gateway            # todo 14: pinned MediaMTX RTMP ingest relay (LAN publish/live -> loopback for cerastream)
  setup_srt_gateway             # todo 15: srt-live-transmit SRT ingest gateway (LAN :4001 -> loopback udp://127.0.0.1:4000 for cerastream)
  setup_ingest_firewall         # todo 14/15: LAN-ingest ingress firewall (drop :1935/:4001 on WAN/modem uplinks; LAN/hotspot only)
  log_success "services configured"
}

configure_network_services "$@"
