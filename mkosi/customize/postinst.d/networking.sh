#!/usr/bin/env bash
#
# postinst.d/networking.sh — the device's network stack and its edges.
#
# Sourced by customize/postinst-lib.sh (never executed). Concern: everything
# about how the board reaches, and is reached over, a network —
#
#   * configure_networking      NetworkManager + mDNS + the resolved stub symlink
#   * install_interface_naming  the eth0/eth1/wlan0 .link units SRTLA bonding globs
#     (+ link_path_match)       depend on, and the loose rp_filter multi-WAN needs
#   * setup_provisioning        the first-boot WiFi AP + captive portal, i.e. how a
#                               board with NO network gets one
#   * setup_ingest_firewall     the WAN-side DROP that keeps the unauthenticated
#                               RTMP/SRT ingest on the LAN
#   * setup_uplink_sharing_carrier
#                               the ceralive-share.service carrier + its teardown
#                               script + the CeraUI After=nftables.service drop-in
#
# The ingest firewall lives here rather than beside setup_rtmp_gateway on purpose:
# it is an interface-class policy (usb*/enx*/ww*/ppp*, the same classes the SRTLA
# dispatcher keys on), and reading it next to the interface naming above is what
# makes that overlap checkable.
#
# CHROOT-SAFE STANDALONE: like every module under postinst.d/, this file carries
# its own declare -F-guarded log()/die() fallbacks. The modules are sourced
# inside mkosi SUBIMAGE CHROOTS where the repo's lib/ is NOT mounted, so a module
# must never assume that anything else has already been sourced.
#
# shellcheck shell=bash

if ! declare -F log >/dev/null 2>&1; then
  log() { printf '[runtime-lib] %s\n' "$*" >&2; }
fi
if ! declare -F die >/dev/null 2>&1; then
  die() { log "FATAL: $*"; exit 1; }
fi

# --- 8. Networking (verbatim from postinst section 8) ---------------------
configure_networking() {
  log "configuring networking (NetworkManager + mDNS)"
  echo "ceralive" >/etc/hostname
  if grep -q '^127.0.1.1' /etc/hosts; then
    sed -i 's/^127.0.1.1.*/127.0.1.1\tceralive/g' /etc/hosts
  else
    printf '127.0.1.1\tceralive\n' >>/etc/hosts
  fi

  if ! grep -q '^hosts:.*mdns' /etc/nsswitch.conf 2>/dev/null; then
    sed -i 's/^hosts:.*/hosts: files mdns4_minimal [NOTFOUND=return] dns mdns4/g' /etc/nsswitch.conf
  fi

  mkdir -p /etc/NetworkManager/conf.d
  cat >/etc/NetworkManager/conf.d/ceralive.conf <<'EOF'
[main]
dns=systemd-resolved
systemd-resolved=true
# firewall-backend PIN (REQ-USB-082). NetworkManager runs its shared-mode NAT
# (`ipv4.method shared`, which is what the hotspot and a shared-LAN ethernet port
# use) through a firewall backend it picks ITSELF at start-up — iptables if it
# finds an iptables binary, nftables otherwise. That choice is therefore a
# property of the build and of PATH, not of this device's intent, and an
# unpinned device can flip backends across an image update with nothing saying so.
#
# Pinned to `nftables` and NOT to `none`, deliberately. NM's own NAT is the
# WORKING FLOOR for basic client internet: if CeraUI's per-uplink steering layer
# (`table inet ceralive_share`, applied by ceralive-share.service) is down,
# degraded, or not yet reconciled, hotspot clients still reach the network
# through NM's masquerade. `none` would make our table load-bearing for plain
# hotspot function — an availability regression with no upside. The two coexist
# by construction: NM's rules and ours live in different tables, and ours are
# additionally scoped by the CLIENT_FLOW conntrack bit plus a client-zone
# `ip saddr` match, so neither can silently shadow the other.
#
# Pinning it to the SAME backend our own layer uses also removes the split-stack
# case entirely — one `nft` view of the ruleset, which is what makes CeraUI's
# read-only coexistence diagnostic able to see NM's NAT and our own at once and
# tell them apart by table provenance. That diagnostic already treats an ABSENT
# key as `firewall_backend_unpinned` (degraded-but-tolerated, the pre-pin fleet
# state), so this line is what turns that reading green — do not remove it
# expecting a neutral result.
firewall-backend=nftables

[device]
wifi.scan-rand-mac-address=yes

# IPv4 link-local fallback on the wired control port. Without this, a network
# that offers no DHCP/RA (dead or hostile DHCP server, dumb switch, a laptop
# plugged in directly) leaves the appliance with NO IPv4 address at all and
# unreachable over v4. link-local=enabled (=3) always assigns a 169.254/16
# address (RFC 3927) alongside any lease, so combined with avahi mDNS the device
# is reachable at its selected .local name on ANY network out of the box. Scoped to eth0
# ONLY: bonded SRTLA modems / wlan_bond must never get a competing 169.254 route.
[connection-eth0-llv4]
match-device=interface-name:eth0
ipv4.link-local=3
EOF

  # dns=systemd-resolved above makes NetworkManager DELEGATE DNS to resolved (it
  # forwards DHCP servers over D-Bus, never writing resolv.conf itself). resolved
  # only manages /etc/resolv.conf when it IS the symlink to its stub; on a plain
  # file it reports `resolv.conf mode: foreign` and stands down (safety behavior).
  # This minimal mkosi rootfs never ran resolved's postinst trigger, so it ships
  # resolv.conf as an empty 0-byte regular file — with delegation on and resolved
  # refusing a foreign file, NOTHING populates it and every glibc/getent/curl
  # lookup fails despite a valid lease (confirmed live: `resolvectl status` shows
  # the server + `mode: foreign`, `getent hosts` exits 2, CeraUI logs constant
  # "DNS timeout"). `ln -sf` is force+idempotent — fixes the empty file, a stale
  # link, or an already-correct link, safe on every A/B rebuild.
  #
  # In a containerized mkosi build, mkosi ro-binds the host resolv.conf over this
  # path for networked postinst scripts, making it an un-replaceable mountpoint so
  # a bare `ln -sf` dies EBUSY. Do NOT "fix" that by skipping when busy: mkosi's
  # empty 0-byte placeholder would then bake into the image as the permanent
  # resolv.conf and ship a device with ZERO DNS. Unmount the overlay first (safe:
  # privileged customize chroot), then symlink so it persists into the built image;
  # die loudly rather than degrade. Capture the nameservers mkosi provided and seed
  # resolved's stub so LATER postinst steps that hit the network still resolve
  # (e.g. setup_rtmp_gateway fetches MediaMTX from github) — /run is tmpfs at device
  # boot, so this build-only seed never ships and resolved recreates the stub live.
  local mkosi_nameservers=""
  if mountpoint -q /etc/resolv.conf 2>/dev/null; then
    mkosi_nameservers="$(cat /etc/resolv.conf 2>/dev/null || true)"
    umount /etc/resolv.conf \
      || die "could not unmount the mkosi /etc/resolv.conf bind overlay — refusing to bake an empty resolv.conf that leaves the device with no DNS"
  fi
  ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
  if [[ -n "${mkosi_nameservers}" ]]; then
    mkdir -p /run/systemd/resolve
    printf '%s\n' "${mkosi_nameservers}" >/run/systemd/resolve/stub-resolv.conf
  fi

  install_interface_naming
}

# --- 8b. Deterministic interface naming (eth0/eth1/wlan0 .link units) ------
# RK3588 predictable names (wlP2p33s0, enP4p65s0) never matched SRTLA's wlan*/
# eth* routing globs, so wifi/wired uplinks were silently dropped from bonding.
# These .link units rename onboard NICs to stable roles. Per-role Path= rules
# (keyed on the manifest ID_PATH, stable per board model) are required on OPi 5+
# where the dual r8169 NICs would otherwise race a generic Type=ether match.
#
# PROPAGATION CONTRACT: this runs in the RUNTIME SUBIMAGE chroot, so the
# per-role Path= values reach it ONLY via CERALIVE_INTERFACES_eth0/eth1/wlan0
# in mkosi.conf's PassEnvironment=. orchestrate.sh exporting them to the
# top-level image is NOT enough — --environment populates the MAIN image only.
# If a CERALIVE_INTERFACES_* name is ever dropped from PassEnvironment= (it once
# was), "${!var}" reads EMPTY here and eth0/eth1 get NO .link file (only wlan0
# has a generic Type=wlan fallback), so ethernet keeps its kernel name and falls
# out of SRTLA bonding — silently. mkosi.conf's PassEnvironment= MUST stay in
# lockstep with orchestrate.sh:run_mkosi_build()'s env_names; the guard is
# mkosi-image-contract.bats "mkosi PassEnvironment stays in lockstep with … env_names".
#
# KERNEL-PORTABLE Path= MATCHING — why the literal manifest value is not enough.
# An ID_PATH for a PCIe NIC is `platform-<controller>-pci-<domain:bus:dev.fn>`,
# and <controller> is the PLATFORM DEVICE name, which Linux derives from the
# FIRST `reg` entry of the DT node. The vendor BSP and mainline order that node's
# `reg` cells differently: the vendor DTS puts the APB window first, so the
# controller is `fe190000.pcie`, while mainline puts the ECAM window first, so
# the SAME controller is `a41000000.pcie`. The manifest values were captured on a
# vendor-BSP board, so on the `edge` (mainline) kernel the literal Path= matched
# NOTHING and systemd fell through to /usr/lib/systemd/network/99-default.link.
# Confirmed live on a Rock 5B+ running 7.1.5: the .link files were present and
# correct, yet the NIC stayed `enP4p65s0`, `udevadm test-builtin net_setup_link`
# reported `ID_NET_LINK_FILE=/usr/lib/systemd/network/99-default.link`, and the
# real ID_PATH read `platform-a41000000.pcie-pci-0004:41:00.0` against a manifest
# saying `platform-fe190000.pcie-pci-0004:41:00.0`. eth0 therefore fell out of
# SRTLA's `eth*` bonding glob on every edge image.
#
# systemd.link(5) Path= takes a WHITESPACE-SEPARATED LIST OF GLOBS, so the fix is
# to emit the literal value AND a controller-agnostic glob keyed on the part that
# is genuinely stable across kernels — the PCI domain:bus:device.function, which
# comes from `linux,pci-domain` and the board's physical topology, not from node
# naming. Two controllers cannot host the same PCI domain, so the glob cannot
# over-match. Non-PCI ID_PATHs (an onboard MAC like `platform-fe1c0000.ethernet`)
# have no such suffix and are emitted literally, unchanged.

# link_path_match <id-path> — the Path= value for a role's .link unit: the
# literal manifest ID_PATH, plus a `platform-*.<devtype>-pci-<bdf>` glob when the
# ID_PATH is a platform-hosted PCI device (see the block comment above).
link_path_match() {
  local id_path="$1" devtype pci_suffix
  if [[ "${id_path}" =~ ^platform-[0-9a-f]+\.([a-z0-9_]+)-(pci-.+)$ ]]; then
    devtype="${BASH_REMATCH[1]}"
    pci_suffix="${BASH_REMATCH[2]}"
    printf '%s platform-*.%s-%s\n' "${id_path}" "${devtype}" "${pci_suffix}"
  else
    printf '%s\n' "${id_path}"
  fi
}

install_interface_naming() {
  log "installing deterministic interface naming (.link units + loose rp_filter)"
  mkdir -p /etc/systemd/network

  local role var val match
  for role in eth0 eth1 wlan0; do
    var="CERALIVE_INTERFACES_${role}"
    val="${!var:-}"
    [[ -n "${val}" && "${val}" != FIXME* ]] || continue
    match="$(link_path_match "${val}")"
    cat >"/etc/systemd/network/10-ceralive-${role}.link" <<EOF
[Match]
Path=${match}

[Link]
Name=${role}
EOF
  done

  # Fallback ONLY when the board manifest has no onboard-wifi Path: match by
  # Type=wlan. A Path= rule (emitted above) is onboard-scoped and lets USB wifi
  # dongles keep their kernel names (wlan1+/wlx<mac>); a Type=wlan rule would
  # instead try to rename EVERY wireless NIC to wlan0 and collide (EEXIST).
  local wlan0_path="${CERALIVE_INTERFACES_wlan0:-}"
  if [[ -z "${wlan0_path}" || "${wlan0_path}" == FIXME* ]]; then
    cat >/etc/systemd/network/10-ceralive-wlan0.link <<'EOF'
[Match]
Type=wlan

[Link]
Name=wlan0
EOF
  fi

  # rp_filter=2 (loose) validates the return path on ANY interface, not just the
  # arrival one — strict RPF silently drops modem return traffic under multi-WAN
  # source-policy routing.
  mkdir -p /etc/sysctl.d
  cat >/etc/sysctl.d/60-ceralive-rp-filter.conf <<'EOF'
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
EOF
}

# --- 17. First-boot WiFi provisioning portal (tasks 11 + 14) ------------------
# Installs the committed canonical artifacts under mkosi/runtime/ (single source of
# truth — no inline twin, Task 6 pattern), mirroring setup_boot_healthcheck /
# setup_cert_rotation. The provision script brings up an NM-native AP-mode hotspot ONLY
# when there are no stored (non-AP) WiFi profiles on /data AND no link-up connectivity
# appears within a boot grace window; a /data force flag (factory-reset hook) re-triggers
# it even when profiles exist.
#
# Task 14 adds the captive portal: ceralive-portal.sh (the inetd-style bash HTTP handler)
# plus its socket-activation units ceralive-portal.{socket,@.service}. The socket + the
# per-connection template are installed but NOT enabled — ceralive-provision starts the
# socket imperatively when the AP comes up and stops it on teardown, so port 80 is taken
# from CeraUI only for the duration of provisioning. CERALIVE_RUNTIME_SRC must point at
# the runtime/ source dir.
setup_provisioning() {
  log "installing first-boot WiFi provisioning portal (ceralive-provision.service + captive portal)"
  local src="${CERALIVE_RUNTIME_SRC:-}"
  [[ -n "${src}" && -f "${src}/ceralive-provision.sh" ]] \
    || die "provisioning source not found: ${src}/ceralive-provision.sh (is \$SRCDIR/runtime mounted?)"
  [[ -f "${src}/ceralive-portal.sh" ]] \
    || die "captive-portal source not found: ${src}/ceralive-portal.sh (is \$SRCDIR/runtime mounted?)"
  mkdir -p /usr/local/sbin
  install -m 0755 "${src}/ceralive-provision.sh" /usr/local/sbin/ceralive-provision
  install -m 0755 "${src}/ceralive-portal.sh"    /usr/local/sbin/ceralive-portal
  install -m 0644 "${src}/ceralive-provision.service"  /etc/systemd/system/ceralive-provision.service
  install -m 0644 "${src}/ceralive-portal.socket"      /etc/systemd/system/ceralive-portal.socket
  install -m 0644 "${src}/ceralive-portal@.service"    /etc/systemd/system/ceralive-portal@.service
  # Only the trigger service is enabled at boot; the portal socket + template are driven
  # imperatively by ceralive-provision (start on AP up, stop on teardown).
  enable_service ceralive-provision.service
}

# ---------------------------------------------------------------------------
# LAN-ingest ingress firewall (Todo 14/15 INGRESS BOUNDARY): the security half
# of the ingest gateway above. Stages the committed nftables ruleset +
# oneshot unit under mkosi/runtime/ingest-firewall/ (single source of truth,
# Task-6 pattern) and enables the unit.
#
# The single MediaMTX gateway accepts an UNAUTHENTICATED publish on BOTH its RTMP
# (:1935) and SRT (:4001) listeners in v1 (no RTMP password, no SRT passphrase —
# DEFERRED.md items 7 & 8), which is only safe on the LAN. The ruleset DROPS both
# ports on the WAN/modem/WWAN/ppp uplink classes (usb*/enx*/ww*/ppp* — the SAME
# classes the SRTLA dispatcher in §6 uses), so the anonymous ingest is reachable
# from LAN/hotspot ONLY. `nft` is provided by the `nftables` package (shared.list);
# this function only stages + enables. CERALIVE_RUNTIME_SRC must point at the
# runtime/ source dir.
# ---------------------------------------------------------------------------
setup_ingest_firewall() {
  log "installing LAN-ingest ingress firewall (ceralive-ingest-firewall.service — drop :1935/:4001 on WAN/modem uplinks; LAN/hotspot only)"
  local src="${CERALIVE_RUNTIME_SRC:-}/ingest-firewall"
  [[ -n "${CERALIVE_RUNTIME_SRC:-}" && -f "${src}/ingest-firewall.nft" ]] \
    || die "ingest-firewall ruleset not found: ${src}/ingest-firewall.nft (is \$SRCDIR/runtime mounted?)"
  [[ -f "${src}/ceralive-ingest-firewall.service" ]] \
    || die "ingest-firewall unit not found: ${src}/ceralive-ingest-firewall.service"

  install -D -m 0644 "${src}/ingest-firewall.nft" /etc/ceralive/ingest-firewall.nft
  install -m 0644 "${src}/ceralive-ingest-firewall.service" /etc/systemd/system/ceralive-ingest-firewall.service

  enable_service ceralive-ingest-firewall.service
}

# ---------------------------------------------------------------------------
# Uplink-sharing CARRIER (REQ-USB-020..026): the systemd half of the internet-
# sharing subsystem. CeraUI's uplink-steering module is the DECIDER — it renders
# a complete desired-state nftables ruleset to /run/ceralive/share.nft — and this
# unit is the CARRIER that validates and applies it. Same split, and the same
# committed-artifact staging pattern, as setup_ingest_firewall above.
#
# THREE artifacts, and each one is load-bearing:
#   1. ceralive-share.service          the oneshot carrier itself
#   2. ceralive-share-teardown         its ExecStop backstop (REQ-USB-024 requires
#                                      a committed SCRIPT, not an inline command)
#   3. 40-nftables-ordering.conf       an additive After=nftables.service drop-in
#                                      on ceralive.service — the unit that
#                                      actually issues start/reload/stop, and so
#                                      the one that can race a system ruleset load
#
# DELIBERATELY NOT ENABLED, unlike ceralive-ingest-firewall.service. The ruleset
# lives on /run (tmpfs) and is authored by CeraUI at runtime, so at boot there is
# nothing to apply and an enabled unit would fail on every boot reading a file
# that cannot exist yet. The unit file carries no [Install] section at all, which
# is what keeps systemd's first-boot `preset-all` (this image ships
# /etc/machine-id holding `uninitialized`) from enabling it behind our backs.
#
# CERALIVE_RUNTIME_SRC must point at the runtime/ source dir. Test seams:
#   UPLINK_SHARING_UNIT_DIR      — systemd unit dir      (default /etc/systemd/system)
#   UPLINK_SHARING_SBIN_DIR      — teardown install dir  (default /usr/local/sbin)
#   UPLINK_SHARING_DROPIN_DIR    — ceralive.service drop-in dir
# ---------------------------------------------------------------------------
setup_uplink_sharing_carrier() {
  log "installing uplink-sharing carrier (ceralive-share.service — validate-then-apply /run/ceralive/share.nft; NOT enabled, CeraUI drives it at runtime)"
  local src="${CERALIVE_RUNTIME_SRC:-}/uplink-sharing"
  [[ -n "${CERALIVE_RUNTIME_SRC:-}" && -f "${src}/ceralive-share.service" ]] \
    || die "uplink-sharing unit not found: ${src}/ceralive-share.service (is \$SRCDIR/runtime mounted?)"
  [[ -f "${src}/ceralive-share-teardown.sh" ]] \
    || die "uplink-sharing teardown script not found: ${src}/ceralive-share-teardown.sh"
  [[ -f "${src}/ceralive-nftables-ordering.dropin.conf" ]] \
    || die "uplink-sharing nftables-ordering drop-in not found: ${src}/ceralive-nftables-ordering.dropin.conf"

  local unit_dir="${UPLINK_SHARING_UNIT_DIR:-/etc/systemd/system}"
  local sbin_dir="${UPLINK_SHARING_SBIN_DIR:-/usr/local/sbin}"
  local dropin_dir="${UPLINK_SHARING_DROPIN_DIR:-/etc/systemd/system/ceralive.service.d}"

  mkdir -p "${unit_dir}" "${sbin_dir}" "${dropin_dir}"
  install -m 0644 "${src}/ceralive-share.service" "${unit_dir}/ceralive-share.service"
  install -m 0755 "${src}/ceralive-share-teardown.sh" "${sbin_dir}/ceralive-share-teardown"
  install -m 0644 "${src}/ceralive-nftables-ordering.dropin.conf" "${dropin_dir}/40-nftables-ordering.conf"
}
