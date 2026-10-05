<!-- Moved verbatim from AGENTS.md on 2026-10-05 by lean-rules-docs-landing-latam -->

## KNOWN ISSUES / DEFERRED

Full index with file:line anchors and unblock conditions: [`docs/DEFERRED.md`](../DEFERRED.md).

**RK3588 predictable names — the subimage env-propagation contract.** The
deterministic `eth0/eth1/wlan0` renames (`install_interface_naming()` in
`postinst-lib.sh`, run from the runtime `mkosi.postinst.chroot`) and the add-on
signing keyring (`setup_addon_keyring()`) run inside a SUBIMAGE chroot. Their
inputs — `CERALIVE_INTERFACES_eth0/eth1/wlan0`, `ADDON_KEYRING_B64` — reach that
chroot ONLY through `PassEnvironment=` in `mkosi/mkosi.conf`. `orchestrate.sh`
exporting a name and listing it in `run_mkosi_build()`'s `env_names` is NOT
enough: mkosi's `--environment` populates the TOP-LEVEL image's script env only,
and the base/platform/runtime/app subimages each parse config in isolation. A
name present in `env_names` but MISSING from `PassEnvironment=` reads EMPTY in
every subimage — silently. That exact drift shipped two production bugs (eth0/eth1
never renamed → dropped from SRTLA's `eth*`/`wlan*` bonding globs, confirmed on
Rock 5B+ hardware; and an empty add-on keyring → all add-on signatures rejected).
`CERALIVE_BOARD` (the first-party staging key) is a third value on this contract:
read empty in the app subimage it installs ZERO first-party packages, so it is in
both lists and additionally pinned by `package-contract.bats` §27.
`PassEnvironment=` MUST stay in lockstep with `env_names`; the structural guard is
`mkosi-image-contract.bats` "mkosi PassEnvironment stays in lockstep with … env_names" (it
fails the build if a future `env_names` addition skips `PassEnvironment=`).
`SOURCE_DATE_EPOCH` (host-side/mkosi-native) and `CERALIVE_PIPELINE_DIR` (forwarded via
a separate `-e`/`--environment` mechanism) are the two documented legitimate
asymmetries.

**OPi 5+ interface ID_PATHs — FIXED for both wired NICs, read off real hardware.**
`manifests/boards/orange-pi-5-plus.yaml` used to ship the `interfaces:` block with
`FIXME-…` values because the board was not in hand, so the two onboard r8169 NICs
raced under a generic `Type=ether` match. A physical Orange Pi 5 Plus (DT model
*Xunlong Orange Pi 5 Plus*, `7.1.5-ceralive-rk3588`) has now been read with
`udevadm info /sys/class/net/<iface>`:

```
enP3p49s0  ID_PATH=platform-a40c00000.pcie-pci-0003:31:00.0  MAC …:8d:c6  -> eth0
enP4p65s0  ID_PATH=platform-a41000000.pcie-pci-0004:41:00.0  MAC …:8d:c7  -> eth1
```

Both are RTL8125 (`0x10ec:0x8125`) on `r8169`, so nothing distinguishes them but
topology: the role assignment follows the lower PCIe controller base address, and
the vendor's sequential MAC assignment agrees. These are the MAINLINE/edge ECAM
controller names — correct and deliberate, because `link_path_match()` also emits
the controller-agnostic `platform-*.pcie-pci-<bdf>` glob that covers the vendor
BSP's `fe170000`/`fe180000` spelling (see the `.link` `Path=` KEY FACT above).
**Do NOT rewrite them to the vendor spelling to "fix" a future mismatch.**

**`wlan0` is deliberately ABSENT from the map, and that is not a leftover
placeholder.** The bench unit has no wireless netdev to read at all — no
`/sys/class/ieee80211`, no wireless driver loaded, only an empty
`rfkill-pcie-wlan` stub for an unpopulated M.2 slot — so there is no ID_PATH to
capture and none may be invented. The schema makes `wlan0` optional exactly for
this, and `install_interface_naming()` then emits its generic `Type=wlan → wlan0`
rule, which is the right rule for a single adapter fitted later. Add the key only
from a real reading on a board that has one; never copy the Rock 5B+'s value
(entirely different PCIe topology).

**This moved `tests/manifests/fixtures/vendor-baseline/orange-pi-5-plus.params`,
and that is the ONE sanctioned reason to touch it.** The anti-pattern against
regenerating those fixtures stands: a diff there means the production path moved.
Here it moved deliberately and the diff is exactly three lines — the two filled
`INTERFACES_ETH*` values plus the removed `INTERFACES_WLAN0` placeholder. The
baseline was edited surgically on those keys, never re-captured wholesale, so the
fixture still proves what it exists to prove (that declaring a family variant is
inert on the vendor path). A diff of any other key is still a defect.

**SRTLA source-policy routing is RETIRED — and it did NOT fail closed** [REMOVED]

The NM dispatcher `90-srtla-wifi-routing`, the dhclient hook
`/etc/dhcp/dhclient-exit-hooks.d/srtla-source-routing`, the `rt_tables`
reservations that named their tables (`100-107 modem0..7`, `120-124 wlan0..4`),
and the whole `mkosi/customize/networking-srtla.sh` module are GONE. Bonding pins
egress per link in the socket (`SO_BINDTODEVICE` + a source-address bind), so
policy routing has no consumer.

Four measurements on a live `7.1.7-ceralive-rk3588` board, in the order that
matters. They are a historical record of that image, and the first one no longer
describes the current `edge` config: `rk3588-edge.fragment` now declares
`CONFIG_IP_ADVANCED_ROUTER=y` above its pre-existing `CONFIG_IP_MULTIPLE_TABLES=y`,
so at the `v7.2` pin `ip rule` IS built. That does not resurrect anything below —
the retirement stands on bonding pinning egress in the socket, not on a missing
kernel symbol.

- **`ip rule` was unsupported on that image.** `# CONFIG_IP_ADVANCED_ROUTER is not set`, so
  `CONFIG_IP_MULTIPLE_TABLES` was absent entirely and `ip rule show` answered
  `RTNETLINK answers: Operation not supported` (exit 255). No rule ever installed.
- **`ip route add … table N` SILENTLY WRITES INTO MAIN.** Proven with a
  documentation prefix: `ip route add 203.0.113.0/24 … table 121` exits 0,
  `ip route show table 121` is EMPTY, and the route is in the MAIN table. So the
  dispatcher's "per-modem default route" could install a `proto boot`, **metric-0**
  default that outranks every DHCP route (metrics 101-107) — the metric-0
  captive-portal hazard this bench has already paid for once.
- **It then logged a success that was false.** After both mutations failed it still
  emitted `srtla-routing: Source routing: <if> (<ip>) via <gw> table 104`.
- **The dhclient half could never run at all** — `dhclient` is not installed and NM
  uses `dhcp=internal`.

A kernel-capability guard was REJECTED rather than overlooked: on the vendor 6.1
kernel, where `ip rule` does work, the rules are keyed `from <source-ip>` and this
fleet's HiLink twins both lease `192.168.8.100` — an address that cannot name a
device, i.e. exactly the ambiguity `SO_BINDTODEVICE` exists to remove. Plan todo 40
states the position directly: Scope forbids reopening SNAT/policy-routing bonding.

`ci/postinst-drift-check.sh` CHECK 2 was INVERTED from a payload-parity check into a
residue guard, and `lib/parity-check.sh` §D now fails if any of these assets is
present in a built rootfs. `iproute2` STAYS in `shared.list` — CeraUI still shells
out to `ip` for its read-only route/policy diagnostics. Full decision record with
verbatim traces: `.omo/notepads/modem-phase-c-quality/evidence/todo38.md`.

**The router-dongle netns layer is RETIRED — and its one leftover is on `/data`** [REMOVED]

The per-dongle network-namespace layer (`ceralive-dongle-netns@.service`, its
reconcile timer, the `85-ceralive-dongle-netns.rules` udev claim, the
NetworkManager unmanaged-devices snippet, the three `/usr/local/sbin/ceralive-dongle-*`
scripts and the `rt_tables` 110-117 reservation) is not installed by any image.
A router-mode dongle is CLASSIFIED from its USB descriptors and bonds through its
OWN `enx…`/`eth…` interface instead, which is what every shipped image already did
— the layer never reached a published release, so this is a retirement of an
unmerged design rather than the removal of a deployed one.

**It is not a no-op retirement, and the reason is a single deliberate design
decision.** Every artifact above lives in the rootfs, so a RAUC slot swap boots
without it; the namespaces, the `dg<N>h` veths, the rules/tables and
`/run/ceralive/dongles` are kernel/tmpfs state, so the reboot that swap requires
clears them. The durable slot store `/data/ceralive/dongle-slots.json` (+ its
`.lock`) is the exception BY CONSTRUCTION: it was put on the data partition
precisely so a slot swap would NOT wipe it and renumber every dongle across an
OTA. That is exactly what makes it the one piece of residue an image update
cannot clear by being a new image.

`ceralive-dongle-netns-retire.service` is therefore shipped — the only part of the
layer this image carries. It is a boot oneshot, ordered `RequiresMountsFor=/data`
and `Before=NetworkManager.service`/`ceralive.service`, idempotent, and an exit-0
no-op on a board that never ran the layer. Every name it removes is enumerated
from the retired contract's own eight-slot allocation table, so a namespace, veth,
rule or table the layer did not create cannot be caught by it. Contract:
`tests/dongle-netns-retirement.test.sh` (absence from every installer + the
teardown legs, incl. the bounded-slot and unsupported-`ip rule` negatives).

CeraUI keeps its `/run/ceralive/dongles` READER, deliberately: it is tolerant of
the directory being absent, which is what lets an old-image board and a
post-retirement board degrade to the same silence. Do not delete it as dead code.

**Modem `usb0..7` naming is hardware-gated.** Deterministic modem renames need a
physical modem to read its ID_PATH; not implemented here. Only `eth0/eth1/wlan0`
are pinned today.

**Cog render QA hardware-gated.** `cog-display.sysext.conf` + build wrapper are
inert scaffolds until a physical RK3588 validates render. The gated items moved
at the trixie/mainline flip: **Panthor + Mesa EGL/GBM** wiring (not libmali), and
OKLCH/Tailwind v4 on WebKit **2.48.3** — a far newer engine than the 2.38.6 that
made the CSS item the deciding one, so that risk is materially reduced but still
unverified. The closure itself is no longer gated: it resolves, downloads,
prunes and squashes for real against the trixie arm64 index. See
[`docs/cog-display-addon.md §7`](../cog-display-addon.md).
