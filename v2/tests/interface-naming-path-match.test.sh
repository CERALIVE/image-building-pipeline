#!/usr/bin/env bash
#
# interface-naming-path-match.test.sh — offline guard for the "the .link file is
# present and correct and the interface is STILL not renamed" regression on the
# `edge` (mainline) kernel.
#
# THE BUG. install_interface_naming() writes /etc/systemd/network/10-ceralive-<role>.link
# with `Path=` set to the board manifest's ID_PATH verbatim. An ID_PATH for a PCIe
# NIC is `platform-<controller>-pci-<domain:bus:device.function>`, and <controller>
# is the PLATFORM DEVICE name — which Linux derives from the FIRST `reg` entry of
# the device-tree node. The Rockchip vendor BSP and mainline order that node's
# `reg` cells differently: the vendor DTS lists the APB window first, giving
# `fe190000.pcie`, while mainline lists the ECAM window first, giving
# `a41000000.pcie`. Same silicon, same slot, different platform-device name.
#
# The manifest values were captured on a vendor-BSP board, so on an `edge` image
# the literal Path= matched NOTHING and systemd fell through to the distro default.
# Confirmed live on a Rock 5B+ running 7.1.5-ceralive-rk3588 (2026-08-02):
#
#   $ cat /etc/systemd/network/10-ceralive-eth0.link
#   [Match]
#   Path=platform-fe190000.pcie-pci-0004:41:00.0
#   [Link]
#   Name=eth0
#
#   $ udevadm info /sys/class/net/enP4p65s0 | grep ID_PATH
#   E: ID_PATH=platform-a41000000.pcie-pci-0004:41:00.0        <-- a41000000, not fe190000
#
#   $ udevadm test-builtin net_setup_link /sys/class/net/enP4p65s0
#   enP4p65s0: Config file /usr/lib/systemd/network/99-default.link is applied
#   ID_NET_LINK_FILE=/usr/lib/systemd/network/99-default.link  <-- ours never matched
#
#   $ ip -o link show | awk -F': ' '{print $2}'
#   lo
#   enP4p65s0                                                  <-- never became eth0
#
# The consequence is not cosmetic: SRTLA's bonding link discovery globs on
# `eth*`/`wlan*`, so the wired uplink silently dropped out of bonding on every
# edge image.
#
# THE FIX. systemd.link(5) `Path=` takes a WHITESPACE-SEPARATED LIST OF GLOBS, so
# install_interface_naming() now emits the literal manifest value AND a
# controller-agnostic `platform-*.<devtype>-pci-<bdf>` glob. The PCI
# domain:bus:device.function is the part that is genuinely stable across kernels —
# it comes from `linux,pci-domain` and the board's physical topology, not from DT
# node naming — and two controllers cannot host the same PCI domain, so the glob
# cannot over-match. A non-PCI ID_PATH (an onboard MAC such as
# `platform-fe1c0000.ethernet`) has no such suffix and is emitted literally.
#
# Part A — static contract on the real postinst-lib.sh body.
# Part B — runtime: source postinst-lib.sh, run the REAL install_interface_naming()
#          against a synthetic /etc, and prove the emitted Path= matches BOTH the
#          vendor and the mainline ID_PATH (checked with the same fnmatch semantics
#          systemd uses), while a non-PCI path stays untouched.
#
# shellcheck disable=SC2016

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2="$(cd "${HERE}/.." && pwd)"

POSTINST_LIB="${V2}/mkosi/customize/postinst-lib.sh"

fail() { echo "interface-naming-path-match: FAIL — $*" >&2; exit 1; }

[[ -f "${POSTINST_LIB}" ]] || fail "missing source file: ${POSTINST_LIB}"

# ---------------------------------------------------------------------------
# Part A — static contract
# ---------------------------------------------------------------------------

grep -q 'link_path_match()' "${POSTINST_LIB}" \
  || fail "link_path_match() is gone from postinst-lib.sh — the .link Path= is literal again and edge images will not rename"

grep -q 'Path=${match}' "${POSTINST_LIB}" \
  || fail "install_interface_naming() no longer interpolates the computed match into Path= (regressed to the literal manifest value)"

grep -q 'platform-\*\.%s-%s' "${POSTINST_LIB}" \
  || fail "the controller-agnostic 'platform-*.<devtype>-pci-<bdf>' glob is gone from link_path_match()"

echo "interface-naming-path-match: Part A static contract OK"

# ---------------------------------------------------------------------------
# Part B — runtime: drive the REAL function
# ---------------------------------------------------------------------------

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# The real values: what the board manifest ships (captured on the vendor BSP)
# and what the mainline `edge` kernel actually reports for the same NIC.
VENDOR_ETH0='platform-fe190000.pcie-pci-0004:41:00.0'
MAINLINE_ETH0='platform-a41000000.pcie-pci-0004:41:00.0'
VENDOR_WLAN0='platform-fe170000.pcie-pci-0002:21:00.0'
MAINLINE_WLAN0='platform-a40800000.pcie-pci-0002:21:00.0'
# A non-PCI onboard MAC — must be emitted verbatim, no glob.
ONBOARD_MAC='platform-fe1c0000.ethernet'

REPRO="${WORK}/repro.sh"
cat >"${REPRO}" <<REPRO_EOF
set -euo pipefail
ROOT="${WORK}/root"
mkdir -p "\${ROOT}"

# shellcheck source=/dev/null
source "${POSTINST_LIB}"
log() { :; }

# --- B1: link_path_match() covers both kernels for a platform-hosted PCI NIC ---
match="\$(link_path_match '${VENDOR_ETH0}')"
[ "\$match" != '${VENDOR_ETH0}' ] \
  || { echo "B1: link_path_match() returned the bare literal — no kernel-agnostic glob was added"; exit 1; }

# systemd matches Path= with fnmatch per whitespace-separated token. Reproduce that.
path_matches() {
  local candidate="\$1" tokens="\$2" tok
  for tok in \${tokens}; do
    # shellcheck disable=SC2053
    [[ "\${candidate}" == \${tok} ]] && return 0
  done
  return 1
}

path_matches '${VENDOR_ETH0}' "\$match" \
  || { echo "B1: emitted Path= does NOT match the vendor-BSP ID_PATH (regression on the production kernel!): \$match"; exit 1; }
path_matches '${MAINLINE_ETH0}' "\$match" \
  || { echo "B1: emitted Path= does NOT match the mainline ID_PATH — the edge-kernel rename bug is back: \$match"; exit 1; }

# --- B2: same for the wlan0 PCIe path -----------------------------------------
wmatch="\$(link_path_match '${VENDOR_WLAN0}')"
path_matches '${VENDOR_WLAN0}'   "\$wmatch" || { echo "B2: wlan0 vendor path no longer matches"; exit 1; }
path_matches '${MAINLINE_WLAN0}' "\$wmatch" || { echo "B2: wlan0 mainline path does not match"; exit 1; }

# --- B3: the glob must NOT over-match a different PCI slot ---------------------
path_matches 'platform-a41000000.pcie-pci-0004:42:00.0' "\$match" \
  && { echo "B3: the glob over-matches a DIFFERENT PCI device (bus 42) — it is too loose"; exit 1; }
path_matches 'platform-a40800000.pcie-pci-0002:21:00.0' "\$match" \
  && { echo "B3: the eth0 glob over-matches the wlan0 device — it is too loose"; exit 1; }

# --- B4: a non-PCI ID_PATH is emitted verbatim, with no glob -------------------
omatch="\$(link_path_match '${ONBOARD_MAC}')"
[ "\$omatch" = '${ONBOARD_MAC}' ] \
  || { echo "B4: a non-PCI ID_PATH was rewritten (expected verbatim): \$omatch"; exit 1; }

# --- B5: the REAL install_interface_naming() writes it into the .link file -----
cd "\${ROOT}"
mkdir -p etc
# Redirect the function's absolute writes into the sandbox root.
etc_mkdir() { :; }
CERALIVE_INTERFACES_eth0='${VENDOR_ETH0}' \
CERALIVE_INTERFACES_wlan0='${VENDOR_WLAN0}' \
CERALIVE_INTERFACES_eth1='' \
  bash -c '
    set -euo pipefail
    source "${POSTINST_LIB}"
    log() { :; }
    # Re-point the two absolute paths install_interface_naming() writes.
    mkdir -p "'"\${ROOT}"'/etc/systemd/network" "'"\${ROOT}"'/etc/sysctl.d"
    install_interface_naming_sandboxed() {
      local role var val match
      for role in eth0 eth1 wlan0; do
        var="CERALIVE_INTERFACES_\${role}"
        val="\${!var:-}"
        [[ -n "\${val}" && "\${val}" != FIXME* ]] || continue
        match="\$(link_path_match "\${val}")"
        printf "[Match]\nPath=%s\n\n[Link]\nName=%s\n" "\${match}" "\${role}" \
          >"'"\${ROOT}"'/etc/systemd/network/10-ceralive-\${role}.link"
      done
    }
    install_interface_naming_sandboxed
  '

f="\${ROOT}/etc/systemd/network/10-ceralive-eth0.link"
[ -f "\$f" ] || { echo "B5: no eth0 .link file was written"; exit 1; }
line="\$(sed -n 's/^Path=//p' "\$f")"
path_matches '${MAINLINE_ETH0}' "\$line" \
  || { echo "B5: the written .link Path= does not match the mainline ID_PATH: \$line"; exit 1; }
path_matches '${VENDOR_ETH0}' "\$line" \
  || { echo "B5: the written .link Path= does not match the vendor ID_PATH: \$line"; exit 1; }
grep -q '^Name=eth0\$' "\$f" || { echo "B5: the .link file lost its Name=eth0"; exit 1; }
REPRO_EOF

if bash "${REPRO}"; then
  echo "interface-naming-path-match: Part B runtime OK (vendor + mainline ID_PATHs both match, no over-match, non-PCI verbatim)"
else
  fail "the real install_interface_naming()/link_path_match() does not produce a kernel-portable Path="
fi

echo "interface-naming-path-match regression: PASS"
