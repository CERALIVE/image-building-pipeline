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
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"

POSTINST_LIB="${PIPELINE_DIR}/mkosi/customize/postinst-lib.sh"
POSTINST_D="${PIPELINE_DIR}/mkosi/customize/postinst.d"

fail() { echo "interface-naming-path-match: FAIL — $*" >&2; exit 1; }

[[ -f "${POSTINST_LIB}" ]] || fail "missing source file: ${POSTINST_LIB}"
[[ -d "${POSTINST_D}" ]] || fail "missing module dir: ${POSTINST_D}"

# postinst-lib.sh is the thin entry that SOURCES the per-concern modules under
# postinst.d/, so it stays the path Part B sources — but the function bodies live
# in the modules, and grepping the entry alone would fail every check below for
# the wrong reason.
#
# Materialized ONCE into a variable, never piped: the reader below stops early,
# which closes the pipe, kills `cat` with SIGPIPE, and `set -o pipefail` then
# reports a correct read as a failure. Whether it fires depends on the unread
# bytes left against the 64 KiB pipe buffer, so the pipe form survives until a
# module is added and then breaks a test unrelated to the change.
POSTINST_SRC="$(cat "${POSTINST_LIB}" "${POSTINST_D}"/*.sh)"

# ---------------------------------------------------------------------------
# Part A — static contract
# ---------------------------------------------------------------------------

grep -q 'link_path_match()' <<<"${POSTINST_SRC}" \
  || fail "link_path_match() is gone from the postinst library — the .link Path= is literal again and edge images will not rename"

grep -q 'Path=${match}' <<<"${POSTINST_SRC}" \
  || fail "install_interface_naming() no longer interpolates the computed match into Path= (regressed to the literal manifest value)"

grep -q 'platform-\*\.%s-%s' <<<"${POSTINST_SRC}" \
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
CERALIVE_INTERFACES_eth0='${VENDOR_ETH0}'
CERALIVE_INTERFACES_wlan0='${VENDOR_WLAN0}'
CERALIVE_INTERFACES_eth1=''
# Redirect only filesystem destinations; execute the production function body.
eval "\$(declare -f install_interface_naming | sed 's|/etc/|${WORK}/root/etc/|g')"
install_interface_naming

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

# Part C: emitted policy, with systemd 257 first-match/NamePolicy semantics.
# Stock policies are the Debian 257 files observed on both bench boards.
# This is an offline contract; real net_setup_link/coldplug proof is a board gate.
python3 - "${PIPELINE_DIR}" "${WORK}" <<'PY'
import configparser
import fnmatch
import os
from pathlib import Path
import subprocess
import sys

import yaml

pipeline, work = map(Path, sys.argv[1:])
usb = "73-usb-net-by-mac.link"
default = "99-default.link"
assert "10-ceralive-wlan0.link" < usb < default
stock = {
    usb: "[Match]\nPath=*-usb-*\nProperty=ID_NET_NAME_MAC=*\n[Link]\nNamePolicy=mac\n",
    default: "[Match]\nOriginalName=*\n[Link]\n"
             "NamePolicy=keep kernel database onboard slot path\n"
             "AlternativeNamesPolicy=database onboard slot path mac\nMACAddressPolicy=persistent\n",
}
# Independent pre-change physical contract, not derived from the writer's output.
physical_paths = {
    "rock-5b-plus": {
        "eth0": "platform-fe190000.pcie-pci-0004:41:00.0 platform-*.pcie-pci-0004:41:00.0",
        "wlan0": "platform-fe170000.pcie-pci-0002:21:00.0 platform-*.pcie-pci-0002:21:00.0",
    },
    "orange-pi-5-plus": {
        "eth0": "platform-a40c00000.pcie-pci-0003:31:00.0 platform-*.pcie-pci-0003:31:00.0",
        "eth1": "platform-a41000000.pcie-pci-0004:41:00.0 platform-*.pcie-pci-0004:41:00.0",
    },
    "x86-minipc": {},
}
errors = []


def check(condition: bool, message: str) -> None:
    if not condition:
        errors.append(message)


def parse(text: str) -> configparser.ConfigParser:
    policy = configparser.ConfigParser(interpolation=None)
    policy.optionxform = str
    policy.read_string(text)
    return policy


def resulting_name(
    policies: dict[str, configparser.ConfigParser], device: dict[str, str | int]
) -> tuple[str, str]:
    for filename, policy in sorted(policies.items()):
        match = policy["Match"]
        if "Path" in match and not any(
            fnmatch.fnmatchcase(str(device["id_path"]), token) for token in match["Path"].split()
        ):
            continue
        if "Type" in match and match["Type"] != device["type"]:
            continue
        if "Property" in match and not device["mac"]:
            continue
        link = policy["Link"]
        # link-config.c::link_generate_new_name, with NamePolicy enabled.
        for token in link.get("NamePolicy", "").split():
            if token == "keep" and device["assign"] in (3, 4):
                return filename, str(device["name"])
            if token == "kernel" and device["assign"] == 2:
                return filename, str(device["name"])
            value = device.get(token, "")
            if value:
                return filename, str(value)
        return filename, link.get("Name", str(device["name"]))
    raise AssertionError(f"no first-match policy for {device}")


for board, paths in physical_paths.items():
    root = work / board
    manifest = yaml.safe_load((pipeline / "manifests/boards" / f"{board}.yaml").read_text())
    env = {key: value for key, value in os.environ.items() if not key.startswith("CERALIVE_INTERFACES_")}
    env.update({f"CERALIVE_INTERFACES_{role}": value
                for role, value in manifest.get("interfaces", {}).items()})
    subprocess.run(["bash", "-euc", r'''
source "$1/mkosi/customize/postinst-lib.sh"
log() { :; }
body="$(declare -f install_interface_naming)"
eval "${body//\/etc\//$2/etc/}"
install_interface_naming
''', "installer", str(pipeline), str(root)], env=env, check=True)
    network = root / "etc/systemd/network"
    old = {f"10-ceralive-{role}.link": f"[Match]\nPath={path}\n\n[Link]\nName={role}\n"
           for role, path in paths.items()}
    if "wlan0" not in paths:
        old["10-ceralive-wlan0.link"] = "[Match]\nType=wlan\n\n[Link]\nName=wlan0\n"
    emitted = {path.name: path.read_text() for path in network.glob("*.link")}
    check(emitted.keys() == old.keys(),
          f"I-PHYSICAL-NAMES {board}: expected only existing link files; got {sorted(emitted)}")
    for filename, text in old.items():
        actual = parse(emitted[filename])
        baseline = parse(text)
        if filename == "10-ceralive-wlan0.link":
            check(actual["Link"].pop("NamePolicy", "") == "keep",
                  f"I-USER-NO-RENAME {board}: WLAN policy must start with keep")
        check(dict(actual["Match"]) == dict(baseline["Match"])
              and dict(actual["Link"]) == dict(baseline["Link"]),
              f"I-PHYSICAL-NAMES {board}: changed physical match/name policy in {filename}")
    previous = {filename: parse(text) for filename, text in (stock | old).items()}
    current = {filename: parse(text) for filename, text in (stock | emitted).items()}
    dropin = network / f"{usb}.d/10-ceralive-keep.conf"
    dropins = sorted(network.glob("*.link.d/*.conf"))
    check(dropins == [dropin],
          f"I-USER-NO-RENAME {board}: expected one drop-in on stock USB73")
    if dropin in dropins:
        text = dropin.read_text()
        override = parse(text)
        check(override.sections() == ["Link"] and not override.defaults()
              and dict(override["Link"]) == {"NamePolicy": "keep mac"},
              f"I-USER-NO-RENAME {board}: USB73 drop-in must only set NamePolicy=keep mac")
        # Apply the emitted drop-in to the packaged rule without changing its matches.
        current[usb].read_string(text)
    # USB73 still MAC-names physical coldplug; keep also honors an explicit rename.
    for label, path, mac, renamed in (
        ("USB Ethernet", "platform-xhci-usb-0:3:1.0", "enx001122334455", "uplink0"),
        ("USB ECM modem", "platform-xhci-usb-0:4:1.0", "enx001122334466", "modem0"),
        ("USB RNDIS modem", "platform-xhci-usb-0:5:1.0", "enx001122334477", "rndis0"),
    ):
        for assign, current_name, expected_name in (
            (1, "eth9", mac), (2, "enp0s1u3", mac), (4, mac, mac), (4, renamed, renamed),
        ):
            device = dict(id_path=path, type="ether", name=current_name,
                          mac=mac, path="enp0s1u3", assign=assign)
            before = resulting_name(previous, device)
            after = resulting_name(current, device)
            check(before == (usb, mac),
                  f"I-PHYSICAL-NAMES {board} {label}: fixture missed stock USB73: {before}")
            check(after == (usb, expected_name),
                  f"I-PHYSICAL-NAMES {board} {label} type={assign} current={current_name}: "
                  f"old={before} new={after}, expected={(usb, expected_name)}")
            print(f"I-PHYSICAL-NAMES {board} {label} type={assign} current={current_name}: "
                  f"old={before} new={after}")
    # Include onboard vendor/mainline, second PCIe, USB MAC and missing-MAC paths.
    cases = [
        ("platform-fe170000.pcie-pci-0002:21:00.0", "wlan", "wlan0", "wlx001122334455", "wlP2p33s0"),
        ("platform-a40800000.pcie-pci-0002:21:00.0", "wlan", "wlan0", "wlx001122334455", "wlP2p33s0"),
        ("pci-0000:03:00.0", "wlan", "wlan1", "wlx001122334466", "wlp3s0"),
        ("platform-xhci-usb-0:1:1.0", "wlan", "wlan2", "wlx001122334477", "wlp0s1u1"),
        ("platform-xhci-usb-0:2:1.0", "wlan", "wlan3", "", "wlp0s1u2"),
        ("platform-fe1c0000.ethernet", "ether", "eth2", "enx001122334488", "end0"),
    ]
    for role, path in paths.items():
        if role.startswith("eth"):
            cases.extend((token.replace("*", "a41000000"), "ether", role,
                          "enx001122334499", "enP4p65s0") for token in path.split())
    for path, kind, name, mac, path_name in cases:
        device = dict(id_path=path, type=kind, name=name, mac=mac, path=path_name)
        for assign in (1, 2):
            device["assign"] = assign
            before = resulting_name(previous, device)
            after = resulting_name(current, device)
            expected_winner = before[0]
            check(after == before,
                  f"I-PHYSICAL-NAMES {board} type={assign} {path}: {before} != {after}")
            print(f"I-PHYSICAL-NAMES {board} type={assign} {path}: {after}")
        if kind == "wlan":
            for assign in (3, 4):
                for userspace_name in ("clap-wlan0", "clap-a1b2c3d4", "custom-ap"):
                    device.update(assign=assign, name=userspace_name)
                    winner, result = resulting_name(current, device)
                    check((winner, result) == (expected_winner, userspace_name),
                          f"I-USER-NO-RENAME {board} type={assign} {path}: {winner} -> {result}")
        # Initramfs has already assigned the final physical name; coldplug keeps it.
        device.update(assign=1, name=name)
        _, settled = resulting_name(previous, device)
        device.update(assign=4, name=settled)
        check(resulting_name(current, device)[1] == settled,
              f"I-PHYSICAL-NAMES {board}: coldplug changed initramfs name {settled}")
        if kind == "wlan":
            # N-3: a DIFFERENT physical name from initramfs exposes keep's limit.
            device.update(assign=4, name=path_name)
            before = resulting_name(previous, device)
            after = resulting_name(current, device)
            check(after[1] == path_name,
                  f"N-3 {board}: pre-named physical assignment 4 was not kept")
            if before[0] == "10-ceralive-wlan0.link":
                check(before[1] == "wlan0" and before[1] != after[1],
                      f"N-3 {board}: fixture did not expose old-rule re-renaming")
            print(f"N-3-COLDPLUG {board} {path}: old={before} new={after}; "
                  "S-NAMES requires built-initrd/early-boot reachability proof")

if errors:
    raise SystemExit("\n".join(errors))
print("I-USER-NO-RENAME / I-PHYSICAL-NAMES: PASS (offline kernel-name fixtures; N-3 artifact proof separate)")
PY

echo "interface-naming-path-match regression: PASS"
