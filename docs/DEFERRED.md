# Deferred and Hardware-Gated Work

**Status:** `[EXISTS]`

This index consolidates every item that is explicitly deferred or blocked on
physical hardware access. Each entry records what the item is, why it is
deferred, where the relevant code or spec lives, and what must happen before
work can resume.

Items are documentation-only. None are resolved here.

---

## 1. OPi 5+ Interface ID_PATH Placeholders — RESOLVED (both wired NICs read off hardware)

**Status:** RESOLVED for the dual-NIC race, which was the whole defect. No
placeholder remains in the manifest.
**Location:** `manifests/boards/orange-pi-5-plus.yaml` (`interfaces:` block)
**Also referenced:** `AGENTS.md` → *KNOWN ISSUES / DEFERRED* → "OPi 5+ interface ID_PATHs"
**Cross-repo:** tracked in the workspace-root `docs/DEFERRED-WORK.md` as item 3 (*Orange Pi 5+ interface ID_PATHs*); owned here.

**What it was:** The `interfaces:` block carried `FIXME-…` placeholders for
`eth0`, `eth1` and `wlan0`. The OPi 5+ has two onboard r8169 NICs on the same
driver and bus, so a generic `Type=ether` udev match races between them and the
two wired roles were assigned non-deterministically across boots.

**How it was resolved:** A physical Orange Pi 5 Plus (DT model *Xunlong Orange Pi
5 Plus*, running `7.1.5-ceralive-rk3588`) was read over SSH with
`udevadm info /sys/class/net/<iface>`:

| Kernel name | `ID_PATH` | MAC | Manifest role |
|---|---|---|---|
| `enP3p49s0` | `platform-a40c00000.pcie-pci-0003:31:00.0` | `…:8d:c6` | `eth0` |
| `enP4p65s0` | `platform-a41000000.pcie-pci-0004:41:00.0` | `…:8d:c7` | `eth1` |

Both are RTL8125 (`0x10ec:0x8125`) on `r8169`, so the role assignment follows the
board's own deterministic hardware ordering — lower PCIe controller base address
first, which the vendor's sequential MAC assignment agrees with. The values carry
the MAINLINE/edge ECAM controller spelling; `link_path_match()` also emits the
controller-agnostic `platform-*.pcie-pci-<bdf>` glob, so the vendor BSP's
`fe170000`/`fe180000` spelling matches too.

**Residual, and it is NOT the deferred defect:** `wlan0` is deliberately absent
from the map rather than filled. That bench unit has no wireless netdev at all —
no `/sys/class/ieee80211`, no wireless driver loaded, only an empty
`rfkill-pcie-wlan` stub for an unpopulated M.2 slot — so there is no `ID_PATH` to
read and none may be invented. The schema makes `wlan0` optional precisely for
this case, and `install_interface_naming()` emits its generic `Type=wlan → wlan0`
rule, which is the correct behaviour for a single wireless adapter fitted later.
Add the key only from a real reading on a board that has one.

---

## 2. Modem Interface Naming (usb0..7)

**Status:** Deferred (hardware-gated)
**Location:** `AGENTS.md` → *KNOWN ISSUES / DEFERRED* → "Modem `usb0..7` naming is hardware-gated"

**What it is:** Deterministic udev rename rules for USB modem interfaces
(`usb0`..`usb7`) are not implemented. Only `eth0`, `eth1`, and `wlan0` are
pinned today. Modem interfaces keep their kernel-assigned names, which can
shift across reboots or when multiple modems are present.

**Why deferred:** Deterministic modem renames require reading the `ID_PATH` of
a physical modem from a live device. The naming uncertainty is distinct from
the source-routing issue (the NM `dhcp=internal` hook problem — now FIXED in
software; see `AGENTS.md` → *KNOWN ISSUES / DEFERRED* → "Modem source-routing
under NM `dhcp=internal` — FIXED"): routing was addressed in software, but the
rename rules need hardware evidence.

**Unblock condition:** Attach a supported USB or M.2 modem to a running
CeraLive device. Read `udevadm info /sys/class/net/<iface> | grep ID_PATH` for
each modem interface. Add deterministic `.link` rules to
`manifests/boards/<board>.yaml` (or a shared family manifest) using the
real `ID_PATH` values. (The SRTLA source-policy routing twin-update this note
used to require is GONE — that layer is retired; see `AGENTS.md` → "SRTLA
source-policy routing is RETIRED".)

---

## 3. x86 ESP + GRUB A/B Disk Assembly — RESOLVED (Task 12)

**Status:** RESOLVED (Task 12, this round). The former `TODO(x86-disk)` is closed.
**Location:** `lib/orchestrate.sh` (efi/grub branch); `lib/assemble-disk-x86.sh`

**What it was:** When `RAUC_BOOTLOADER_ADAPTER` was `efi` or `grub`, the
orchestrator's Stage-4 disk assembly step was explicitly skipped — the x86 build
produced a `rootfs.tar` only, no flashable `.raw`.

**How it was resolved:** Task 12 wired x86 disk assembly. Its VERIFY-FIRST gate
found mkosi's native `Bootloader=grub` INCOMPATIBLE with the `Format=none` +
offline-assemble model (mkosi `disk` is `Bootable=no`; the producer is the offline
`assemble-disk.sh`), so GRUB is **script-installed** with RAUC's **native
`bootloader=grub`** backend:

- `lib/assemble-disk-x86.sh` — offline x86 producer (parallel to the RK3588
  `assemble-disk.sh`): lays an ESP (`grub-mkstandalone` removable-path
  `/EFI/BOOT/BOOTX64.EFI` + `grub.cfg` + `grubenv`) plus the FROZEN
  `rootfs_a`/`rootfs_b`/`data` slots (reused verbatim; `repart/` zero-diff, G3).
- `mkosi/platform/x86/install-x86-grub.sh` — `rootfs` (system.conf
  `bootloader=grub` + ESP fstab), `esp` (grub.cfg + grubenv + BOOTX64.EFI),
  `grubenv-set`; `grub-ab.cfg` is the `ORDER`/`<slot>_OK`/`<slot>_TRY` selector.
- `mkosi/mkosi.images/platform/mkosi.finalize` — x86 branch installs the
  `bootloader=grub` system.conf into the rootfs.
- Offline proof: `mkosi/platform/x86/test-x86-grub.sh` (34 assertions incl. the
  grubenv slot-switch → slot B); the retained `qemu-x86.sh --fallback-selftest`
  still proves the custom-engine rollback contract (G4 untouched). Full rationale:
  [`../mkosi/platform/x86/README.md`](../mkosi/platform/x86/README.md) §2.

**Residual follow-up (NOT this task):** the `docs/partition-contract.md` `x86-ab`
addendum (ESP p1 vs the RK raw idbloader gap). The x86 OTA bundle (`.raucb`) is
now wired: `orchestrate.sh`'s `efi`/`grub` Stage-4 branch calls `build-bundle.sh`
after `assemble-disk-x86.sh` (T10 wired, T11 offline-proven).

---

## 4. Cog + WPEWebKit Render QA (Hardware-Gated)

**Status:** Hardware-gated
**Location:** `docs/cog-display-addon.md` §7 (*Hardware-gated caveats (render QA)*), `docs/cog-display-hw-checklist.md` (full runbook), `AGENTS.md` → *KNOWN ISSUES / DEFERRED* → "Cog render QA hardware-gated", `AGENTS.md` → *KIOSK STACK* → "Cog display add-on (W4)"

**What it is:** The Cog + WPEWebKit display add-on packaging is fully
validated in software (apt index, layer contract, build+sign pipeline). The
`cog.sysext.conf` descriptor and build wrapper exist as inert scaffolds. They
are not wired into the build or CI `addon-publish` path until a physical RK3588
board validates render.

The hardware-gated items are:

- Cog renders at all through the **Panthor + Mesa** stack — the in-tree
  `panthor` DRM driver plus Mesa's `dri/panthor_dri.so` providing EGL/GBM
- The merged sysext's Mesa half actually resolves at runtime (the base image
  prunes those four paths; only a merged board proves the overlay supplies them)
- `renderD*` node mapping and permissions for the kiosk user
- OKLCH and Tailwind v4 CSS correctness on WebKit **2.48.3** — risk materially
  reduced versus the 2.38.6 this item was written against, but unverified
- `cog` platform choice: direct-DRM/KMS vs under `cage` (DRM node mapping is
  itself a Task 28 hardware item)
- Touch input through the WPE/Wayland seat (requires DSI touchscreen + calibration)
- Measured `.raw` size **on the device** and its `/data` impact

**What is no longer gated (closed at the trixie/mainline migration):** the
closure itself. `cog` `0.18.4-1+b1` + `libwpewebkit-2.0-1` `2.48.3-1` resolve,
download, extract, prune and squash for real against the trixie arm64 index
(353 172 379 B installed / 111 521 792 B squashed), and the retired bookworm pins
demonstrably do not resolve at all. Evidence:
`.omo/evidence/cerastream-glibc-pipewire-network-ui/todo14-cog-closure.txt` and
`…/todo14-old-pins-negative.txt`. The former "GLVND vs `dpkg-divert` libmali
wiring" item is **retired outright**, not deferred: `libmali` is off the mainline
path entirely, so there is no blob to divert to.

**Why the rest is still deferred:** No RK3588 board is reachable from the dev
environment (Task 1 spike verdict: NO-GO). A GPU cannot be emulated, and the
specific failure mode that matters here — Mesa silently falling back to
`llvmpipe` when it cannot reach the Panthor render node — renders *correctly*
and so cannot be distinguished from success by anything but a board. Everything
provable without hardware is green and recorded in
`test-results/task-39-cog-qa.txt` plus the two evidence files above.

**Unblock condition:** Run the full checklist in
`docs/cog-display-hw-checklist.md` on a physical Radxa Rock 5B+ or Orange
Pi 5+ with a display attached. Every REQUIRED item in §1 through §4 and §6
must pass with evidence captured to `test-results/`. On sign-off: flip
`cog-display-addon.md` and `kiosk-display.md` Cog status from `[PARTIAL]` to
`[EXISTS]`; resolve TD-C1/TD-C3/TD-C4; wire `cog-display.sysext.conf` into
the build and CI `addon-publish` path; pin `cog`/`wpewebkit` versions in
`versions.yaml` (see item 5 below).

---

## 5. versions.yaml Null Pins for cog and wpewebkit

**Status:** Deferred (hardware-gated, same gate as item 4)
**Location:** `versions.yaml:153-165` (workspace root, consumed by `scripts/fetch-debs.sh`)

**What it is:** The `cog` and `wpewebkit` entries in `versions.yaml` carry
`pin: null`. The comment values recorded beside them are **stale** — they name
the retired bookworm pins (cog `0.16.1-1`, `libwpewebkit-1.1-0` `2.38.6-1`),
neither of which resolves on the target suite any more. The apt-index-validated
trixie versions are **cog `0.18.4-1+b1`** and **`libwpewebkit-2.0-1` `2.48.3-1`**
(note the package RENAME — `libwpewebkit-1.1-0` no longer exists in the archive).
They remain unpinned because pinning before render QA passes would lock a version
that may still need to change.

```yaml
# versions.yaml:153-165
cog:
  kind: debian-apt
  source: bookworm/main
  package: cog
  pin: null  # 0.16.1-1 validated from apt index; pin after hardware render QA
  channel: stable

wpewebkit:
  kind: debian-apt
  source: bookworm/main
  package: libwpewebkit-1.1-0
  pin: null  # 2.38.6-1 validated from apt index; pin after hardware render QA
  channel: stable
```

**Why deferred:** Pinning is intentionally deferred until render QA confirms
the bookworm versions are sufficient. The technical debt is tracked as TD-C1 in
`docs/cog-display-addon.md` §9 (*Known technical debt* → TD-C1).

**Unblock condition:** Same gate as item 4. After the Cog render QA checklist
passes on hardware, fill the real `artifact.sha256` in `cog-display.json`, then
set `pin: 0.18.4-1+b1` and `pin: 2.48.3-1` in `versions.yaml:157` and
`versions.yaml:164` — and correct the `package:` field of the `wpewebkit` entry
to `libwpewebkit-2.0-1` and the `source:` field of both entries to the target
suite while doing so, because those are wrong today regardless of the pin.
Re-run `python3 ci/validate-manifests.py` to confirm.

---

## 6. DEVICE-BRINGUP.md Hardware-Evidence Placeholders

**Status:** Deferred (hardware-gated)
**Location:** `docs/DEVICE-BRINGUP.md:478`, `docs/DEVICE-BRINGUP.md:618`, `docs/DEVICE-BRINGUP.md:753`, `docs/DEVICE-BRINGUP.md:1021`

**What it is:** Four **Pending hardware run** placeholders in the public device
bring-up guide await evidence from physical board runs. Each is a literal
"**Pending hardware run**" note in the guide (not a `[TODO]` marker), and each
points at `test-results/boot-log-<date>.txt` as its evidence target:

- **Line 296** — maskrom mode entry procedure for Rock 5B+: the general
  RK3588 steps are documented but the board-specific button location and
  confirmed `rkdeveloptool ld` / USB detection output are placeholders pending a
  real bring-up run.
- **Line 328** — first-boot sequence: the expected U-Boot → kernel → health
  gate → CeraUI sequence is described, but the boot-log timestamps and exact
  console output are pending because no board has been booted with a CeraLive
  image yet.
- **Line 413** — `dev-sync --frontend` invocation and behavior: the dev-sync
  frontend path is specced (`dev-sync`; see `docs/dev-loop.md`) but the
  confirmed invocation and timing are placeholders pending hardware evidence.
- **Line 669** — first-boot network troubleshooting: the "board does not appear
  on the network" section is a placeholder pending hardware evidence.

**Why deferred:** All four items require a physical RK3588 board running a
CeraLive image. The build system is functional; the hardware-specific evidence
(boot logs, maskrom confirmation, network bring-up) cannot be fabricated.

**Unblock condition:** Complete a physical bring-up run on a Radxa Rock 5B+ or
Orange Pi 5+. Capture boot logs to `test-results/boot-log-<date>.txt` (the
reference each placeholder already names). Replace each "**Pending hardware
run**" note with the observed procedure and output.

---

## 7. LAN ingest gateway — no v1 SRT/RTMP auth (LAN-scoped)

**Status:** Deferred (placeholder — extend/formalize in Todo 22). The LAN-only
INGRESS BOUNDARY is now SHIPPED (nftables firewall, below); only the auth model
(RTMP password / SRT passphrase / streamid) remains deferred. Post-Todo-14 the
deferred auth now names ONE config surface: `mediamtx.yml`.
**Location:** `mkosi/runtime/rtmp-gateway/mediamtx.yml` — the SINGLE config
surface for both legs (`authInternalUsers` for auth; `srt`/`srtAddress` for the SRT
listener); installed by `mkosi/customize/postinst-lib.sh::setup_rtmp_gateway`;
`mkosi/runtime/ingest-firewall/` (the ingress firewall that enforces the LAN
boundary — ruleset + oneshot unit) + `postinst-lib.sh::setup_ingest_firewall`

**What it is:** The LAN ingest gateway is a single MediaMTX process
(`ceralive-rtmp-gateway.service`, Todo 14) whose built-in SRT server listens on
`:4001` (`srt: yes` + `srtAddress: :4001` in `mediamtx.yml`) alongside its RTMP
listener on `:1935`. cerastream pulls the SRT read stream on loopback
(`srt://127.0.0.1:4001?streamid=read:publish/live`, cerastream `sources/spec.rs`
`InputKind::SrtIngest`). In v1 the SRT listener carries **NO passphrase** and **no
streamid ACL**, and the RTMP listener carries **no publish password** (the
`authInternalUsers` rule is anonymous `any`), so anything on the LAN that can reach
`:1935`/`:4001` can publish to the device's ingest.

**Why deferred:** v1 is LAN-scoped — the gateway is expected to be reached only from
the same trusted local network the operator controls (the same trust boundary as the
CeraUI control plane on the LAN). Adding a passphrase/password needs a place to
provision + surface the secret (device config + CeraUI UI + the publisher side),
which is a coordinated cross-repo change, not a one-line config edit. Shipping the
LAN-only listeners first unblocks the ingest datapath without prematurely committing
a key-management design.

**INGRESS BOUNDARY — SHIPPED (was the security gap in this LAN-scoped posture).**
The "expected to be reached only from a trusted LAN" assumption above is no longer
just an expectation: it is enforced in the image by the **LAN-ingest ingress
firewall** (`mkosi/runtime/ingest-firewall/ingest-firewall.nft` +
`ceralive-ingest-firewall.service`, staged by
`postinst-lib.sh::setup_ingest_firewall`, `nftables` added to `shared.list`). The
`inet ceralive_ingest_fw` table DROPs inbound `:1935` (RTMP) and `:4001`
(SRT) — both served by the single MediaMTX gateway (Todo 14) — on the
**WAN/modem/WWAN/ppp** uplink interface classes
(`usb*`/`enx*`/`ww*`/`ppp*`; loopback and LAN/hotspot ifaces are untouched). So a publisher out on the public internet (a modem's public/CGNAT
address) can NEVER reach the anonymous ingest, while a phone/OBS on the LAN or the
device hotspot still can. Verified on nftables v1.1.6 by a veth/netns packet test:
`:1935`/`:4001` ingress on a modem-class iface (`usb9`) is DROPPED (drop counters
fire); the same ports on a LAN-class iface (`eth9`) connect/deliver bytes.

**RESIDUAL THREAT (still deferred):** the accepted surface is **unauthenticated LAN
ingest** — anything reachable on the LAN, the device hotspot, or a bonded
wifi-STATION link (also a `wlan*` iface, deliberately NOT dropped so the hotspot
keeps working) can still publish. That is the intended v1 boundary; closing it needs
the passphrase/streamid auth model below, NOT a firewall change. Do NOT add a
passphrase to `mediamtx.yml` as a workaround — the firewall is the v1 mitigation; the
auth model is the v1.next hardening.

**Unblock condition (Todo 22 to formalize):** Decide the ingest auth model
(per-device SRT passphrase + RTMP password provisioned onto `/data` like the TLS
cert, or a streamid ACL), then set it in the SINGLE `mediamtx.yml` surface — the
`srtPassphrase`/path-scoped SRT auth for the SRT listener plus a real
`authInternalUsers` password for RTMP — sourced from a `/data`-persisted secret, wire
the secret into CeraUI (generate/rotate/display), and document the publisher-side
URIs (`srt://<device>:4001?streamid=publish:publish/live&passphrase=…`). Both legs
now live in one config file, so a single edit covers RTMP and SRT together.

**Cross-reference:** the SEPARATE on-device functional QA for the ingest gateway
(does a real publisher actually reach cerastream end-to-end) is item 8 below — this
item is the auth/security posture only, not the relay-verification checklist.

---

## 8. Network-ingest gateway on-device relay verification (RTMP + SRT)

**Status:** Deferred (hardware-gated — formalized by CeraUI Todo 22, extends the
Todo 14 placeholder in item 7 without duplicating it)
**Location:** `mkosi/runtime/rtmp-gateway/` (Todo 14 — the single MediaMTX
gateway terminating both RTMP and SRT); consumed on the CeraUI side by
`apps/backend/src/modules/network/network-ingest.ts`,
`apps/backend/src/modules/streaming/gateway-availability.ts`, and
`apps/frontend/src/lib/components/custom/NetworkIngestSection.svelte`
(`ceralive/CeraUI` repo — see `CeraUI/AGENTS.md` → NETWORK-INGEST GATEWAY).

**DEPLOY-ORDER CONSTRAINT (Todo 14 B2 — MediaMTX terminates SRT).** This image no
longer ships `ceralive-srt-gateway.service`; MediaMTX's built-in SRT server serves
`:4001` instead (`srt: yes` + `srtAddress: :4001` in `mediamtx.yml`). CeraUI's
pre-Todo-16 probe detects the SRT leg by calling `systemctl is-active
ceralive-srt-gateway.service` (`network-ingest.ts` `SRT_GATEWAY_UNIT`) — which no
longer exists on this image — so it would report SRT as unavailable even though the
listener is up. CeraUI **Todo 16** replaces that name-probe with a dual-topology
probe that parses `/etc/mediamtx.yml` for `srt: yes` + `srtAddress: :4001`. **This
image MUST NOT be released to the fleet until CeraUI Todo 16 has shipped to those
devices**, or the SRT publish surface goes dark in the LiveView Network Ingest card.
(This is a documentation constraint only — no image-side code change is possible or
required to enforce it.)

**What it is:** The single LAN ingest gateway (`ceralive-rtmp-gateway.service` /
MediaMTX, terminating RTMP :1935 + SRT :4001), plus the LAN-only ingress firewall
that fronts it (`ceralive-ingest-firewall.service` / nftables — see item 7), are
fully validated in software — unit files pass `systemd-analyze verify`, the RTMP
publish→ffprobe-pull and SRT publish→loopback-read round-trips pass on the build host
against the exact shipped `mediamtx.yml`, the firewall's drop/allow logic is proven
by a veth/netns packet test, the CeraUI backend probes gateway state and surfaces LAN
publish URLs, and the `requires_gateway` stream-start gate is unit-tested against a
mocked `GatewayProbe`. What is NOT yet proven is that a REAL publisher on the REAL LAN
can push media through the gateway into a REAL cerastream process and have it appear
as a live stream — and that the firewall REFUSES the same publisher on a REAL
modem/WAN NIC. The checklist to close this gap:

1. **RTMP path:** on a physical device, point a phone's RTMP-capable broadcaster
   app at `rtmp://<device-lan-ip>:1935/publish/live` (the exact hardcoded path
   from item — Todo 14). Confirm in CeraUI's LiveView that the stream starts with
   `pipeline=rtmp` selected (via the Network Ingest card,
   `data-testid="network-ingest-select-rtmp"`) and that live video/audio is
   flowing through to the configured server destination.
2. **SRT path:** on the same physical device, point OBS Studio's SRT output at
   `srt://<device-lan-ip>:4001?streamid=publish:publish/live` (caller mode; the
   `streamid=publish:publish/live` selects the MediaMTX path — MediaMTX's SRT server
   requires a streamid, unlike the former bare srt-live-transmit listener). Confirm
   in CeraUI's LiveView that the stream starts with `pipeline=srt` selected
   (`data-testid="network-ingest-select-srt"`) and that live video/audio flows
   through identically to the RTMP path.
3. **INGRESS BOUNDARY path (firewall):** with a modem/WWAN uplink attached (a
   `usb*`/`enx*`/`ww*`/`ppp*` interface holding a routable address), confirm the
   ingress firewall (`ceralive-ingest-firewall.service`) is active
   (`systemctl is-active` = `active`; `nft list table inet ceralive_ingest_fw`
   shows the two drop rules) and that a publisher reaching the device's **modem/WAN
   address** on `:1935` / `:4001` is REFUSED while the **LAN/hotspot address**
   still accepts (the host-side veth/netns packet proof only exercises the rule
   logic, not a real modem NIC). Capture the `nft` drop-counter deltas.
4. **All three** confirmations must be captured with evidence (screen recording or
   `test-results/` capture showing the LiveView active-encode state, plus the
   `journalctl` output for the corresponding gateway unit and the `nft list
   ruleset` counter output during the session).

**Why deferred:** No physical RK3588/x86 board with a real LAN and a real
mobile/OBS publisher is reachable from this dev environment — the same
constraint documented in items 1, 2, 4, and 6. MediaMTX's RTMP and SRT listeners
are third-party-binary surfaces; their runtime relay behavior (not just "the unit
starts and the port opens") can only be proven by actually publishing media into
them and observing it exit correctly through cerastream's loopback inputs
(`InputKind::RtmpLocalhost` / `InputKind::SrtIngest`).

**Unblock condition:** Flash a physical device with an image containing the
gateway (and confirm CeraUI Todo 16 is on the device — see the DEPLOY-ORDER
CONSTRAINT above). Run the two-step checklist above (phone→RTMP, OBS→SRT) on the
same LAN as the device. Capture evidence to `test-results/network-ingest-qa-<date>.txt`
(mirroring the `boot-log-<date>.txt` convention in item 6). On sign-off, update
this entry's status to RESOLVED and note the evidence file here.

---

## 9. Kernel-build-from-source variant — RESOLVED on the released Trixie image

**Status:** RESOLVED for the platform migration. The production-default `edge`
variant builds mainline `v7.2` plus its in-tree DTBs from pinned source, and the
released image carries cerastream v2026.8.4 with ceralive-device v2026.8.8.
**Location:** `docs/kernel-build-from-source.md`, `manifests/families/rk3588.yaml`
(`variants.edge`), `lib/build-kernel.sh`

**What completed it:** the todo-31 PipeWire drill passed on the exact
Trixie/mainline image. Todo 37 then built signed, parity-clean images for both
RK3588 boards, released the engine and device packages, and verified their OTA
deployment. Both boards booted the released Trixie/mainline/PipeWire stack healthy.
The Orange Pi additionally completed the deliberate-failure fallback and restoration
drill, proving the RAUC rollback mechanism rather than only a happy-path update.

The earlier `v7.1.7` and Bookworm direct-encode records remain historical evidence;
they are no longer the qualification boundary for the current production image. The
PR gate remains intentionally `DRY_RUN=1`; a real source build is still too costly
for that PR path, but the release chain has now performed and validated the actual
image build and OTA steps.

**Independent work that remains open:** publishing add-on artifacts for
`os_version=13` is still a real availability gap, and Bluetooth B4 validation remains
hardware-gated. Neither gap invalidates the completed base-image, PipeWire, kernel or
OTA/rollback validation recorded above.

Two consequences worth stating plainly:

* The **defconfig fragment** (`manifests/kernel/rk3588-edge.fragment`) now
  demonstrably resolves and compiles (re-verified at `v7.2`: 169/169 declared
  symbols survive, 0 forbidden violations). Direct v7.2 MPP encode on both boards
  is supporting hardware evidence, but the fragment remains unqualified as the
  exact current image because artifact provenance and the Trixie userspace were not
  exercised.
* **A board's DTB filename comes from whichever kernel tree built it, and the two
  trees need not agree — RESOLVED.** Since the board wins the merge
  last, the **board** now declares the per-variant name via `variant_overrides:`
  (`kernel-build-from-source.md` §8). For the Orange Pi 5+ both trees in fact
  spell it `rk3588-orangepi-5-plus.dtb`; the manifest's original `rk3588s-`
  spelling was a bad inference from the board's marketing name, corrected on the
  production path, and the override is retained as an explicit assertion. A real
  `build orange-pi-5-plus --variant edge` then compiles the kernel and passes
  all four `validate_built_kernel_deb` axes, installing
  `rockchip/rk3588-orangepi-5-plus.dtb` from the built `.deb`. `rock-5b-plus`
  declares no override and never needed one.

**Surfaced by that build and now RESOLVED — the app layer staged first-party
`.deb`s by `BOARD_ID` instead of by the board manifest stem.** mkosi's CLI
`--extra-tree …:/opt/ceralive-staging` does not reach the `app` subimage, so what
actually delivers the 14 first-party packages on **every** board is the fallback
`stage_first_party_from_source_mount` in
`mkosi/mkosi.images/app/mkosi.postinst.chroot`. It read
`${SRCDIR}/.staging/${BOARD_ID}/firstparty` while the orchestrator stages into
`.staging/<board-manifest-stem>/`. Those two agree **only** on `rock-5b-plus`
(`board_id: rock-5b-plus`); on `orange-pi-5-plus` (`board_id: orangepi5-plus`) the
fallback path did not exist, the function returned silently, **zero** first-party
packages installed, and the build stopped at `[7/9]` parity with `first-party
packages MISSING from rootfs`. Board-specific, variant-independent (nothing on
that path reads the variant), and identical on the vendor path — the same
silently-inert-mechanism class as the `PassEnvironment=` drift in `AGENTS.md`,
masked because the only regularly-built board has an identity mapping.

The fix forwards the producer's own key: `orchestrate.sh` exports the manifest
stem as `CERALIVE_BOARD` at the point it computes the staging dir, adds it to
`env_names` **and** `mkosi.conf` `PassEnvironment=` (a name in one list only reads
empty in a subimage — the very contract this bug rhymes with), and the consumer
keys off that. The stem, not `BOARD_ID`, because it is unique by construction and
is the key `acquire_board_lock()` already serialises on; `cache/${BOARD_ID}` is a
separate tree for a separate purpose and is untouched. A miss now logs the probed
path instead of returning silently. Guards: `package-contract.bats` §27 — the real shipped
stager driven against every shipped board manifest with that manifest's real
`board_id`, plus the inverse leg proving a `BOARD_ID`-keyed tree is *not* picked
up, plus a non-vacuity assertion that at least one shipped board really does have
stem ≠ `board_id`.

**No platform-migration unblock condition remains.** **D3's kernel half is
answered** — the shipped kernel is the mainline source-built track
(`default_variant: edge`), and the Armbian vendor BSP track is retired. D3's
bootloader-adapter half (`rauc_bootloader_adapter: custom`) is unchanged.

---

## 9b. Vendor-BSP HDMI-RX audio variant — **CLOSED (item retired with the track)**

**Status:** No longer deferred, because the thing it deferred no longer exists.
**Closed:** on the mainline cutover, alongside the vendor kernel retirement.

This item tracked the rk3588 family's source-built Armbian vendor 6.1 BSP
overlay — the one that rebuilt the shipped BSP with
`CERALIVE/rk3588-vendor-kernel-patches` applied to restore HDMI-RX audio capture.
It was deferred because the kernel `.deb` built and validated but no image had
ever been assembled or booted from it.

That overlay, its allow-absent symbol list, its bootloader rows, its fixtures and
its tests were all removed when the vendor kernel track was retired; every byte is
preserved at the annotated tag `vendor-kernel-final`. There is therefore no build
left to unblock. Two facts survive the closure and are recorded here so they are
not lost with it:

* **The audio fix itself remains board-proven on a hand-built kernel** (Tier 1),
  including a CeraUI audio-meter validation through the production cerastream
  sidecar. That evidence is about the PATCH SERIES, which still lives in its own
  repository, not about this pipeline.
* **HDMI-RX audio on the PRODUCTION mainline kernel is a different question with
  its own answer.** It is carried by patches `0005` + `0006` of the mainline
  series (`0006` supplies the DT sound card `0005` alone does not create) — see
  the `AGENTS.md` KEY FACT on that pair. Nothing about this closure asserts that
  HDMI-RX audio works on a shipped image; it asserts only that the retired
  vendor-BSP route to it is gone.

---

## 10. `fw` classifier — on-device tc behavior

**Status:** Hardware-gated; the static config contract is complete
**Location:** `manifests/kernel/rk3588-edge.fragment` (`CONFIG_NET_CLS_FW=y`),
`manifests/kernel/required-symbols.list`,
`docs/notes/sharing-kernel-capability.md` §7

**SCOPE CHANGED 2026-08-28.** This item used to gate the out-of-tree
`ceralive-cls-fw` module the image built for the prebuilt vendor kernel. The
production kernel is now built from source with `CONFIG_NET_CLS_FW=y` in-tree, so
that package and its whole `kernel_extension_packages` mechanism are retired
(absence-guarded by `tests/packaging-hygiene.bats`). Two of the four steps below
went with it: there is no module to `modprobe`, and no `modules-load.d` entry
whose effect needs observing.

**What is proven without hardware:** the symbol is declared in the production
fragment, pinned in `required-symbols.list`, and `lib/verify-kernel-config.sh`
asserts it survived `olddefconfig` inside the builder — the gate that already
caught four capabilities silently dropped by an undeclared `menuconfig` parent.

**What remains:** on a board booted from a built image, require both of:

1. an isolated test qdisc accepts `tc filter add … handle <mark> fw classid …`;
2. marked packets increment only the selected class counter.

Capture the commands and counters under `test-results/uplink-sharing/`. This is
the behavioral/HW gate; CI intentionally asserts config text only.

---

## 11. Uplink-sharing carrier — on-device apply, reload and teardown

**Status:** Hardware-gated; static package/config/unit contract is complete
**Location:** `mkosi/runtime/uplink-sharing/`,
`mkosi/customize/postinst.d/networking.sh::setup_uplink_sharing_carrier`,
`tests/uplink-sharing-carrier.bats`, `docs/notes/sharing-qdisc-matrix.md`

**What is proven without hardware:** `nftables` and `conntrack-tools` reach the
resolved runtime package set; the qdisc/netfilter availability matrix is measured
and recorded for both kernel tracks; the image bakes no `ip_forward=1`;
NetworkManager is pinned to `firewall-backend=nftables`; and
`ceralive-share.service` satisfies the REQ-USB-020..026 carrier contract by text
(two ordered validate-then-apply `ExecStart=` lines with no shell operator, an
apply-only `ExecReload=`, an `ExecStop=` pointing at the committed teardown
script, `After=nftables.service`, no `[Install]` section).

**Why it is gated.** This repo's CI has no privileged network namespace and no
VM, so nothing here may claim that a ruleset applies, that a reload is gap-free,
or that a teardown restores anything. The netns half is CeraUI's required
`unshare -rn` job; the on-device half is this item.

**What remains:** on a board booted from a built image, with sharing enabled from
the UI, require all of:

1. `systemctl start ceralive-share.service` succeeds and `nft list table inet
   ceralive_share` shows the rendered ruleset;
2. a reweight delivered as `systemctl reload ceralive-share.service` leaves a
   client download uninterrupted (no rule-gap), and `systemctl show -p ExecStop`
   confirms no teardown ran;
3. `systemctl stop ceralive-share.service` leaves no `ceralive_share` table, no
   `ip rule` at priority 110, and no `ca00:` root qdisc on any interface;
4. a hotspot client still reaches the internet after that stop — proving NM's
   shared-mode NAT survived as the working floor and that `ip_forward` was not
   zeroed out from under it.

Capture the commands and outputs under `test-results/uplink-sharing/`.

---

## 12. `CERALIVE_BENCH_LABELS` has no verification against the physical target

**Status:** Open technical debt; no automated safeguard exists. The flag's
no-default design is CORRECT and stays as it is, so this item is about the
MISSING second half, not about the flag.
**Location:** `lib/orchestrate.sh` (`CERALIVE_BENCH_LABELS` export + the
`stage_repart_dir` label rewrite), `mkosi/customize/postinst.d/persistence.sh`
(the `/data` fstab entry), `mkosi/platform/boot/install-boot.sh` (the `/boot`
fstab entry, RAUC `system.conf` slot devices, compiled `boot.scr`),
`ci/build-hardware-candidates.sh` (`--bench-labels 0|1`),
`tests/preflash-verify.sh` (production-label assertion),
`AGENTS.md` KEY FACTs "Bench PARTLABEL overlay" and "A hardware candidate that
does not STATE its PARTLABEL set…"

**What is already correct, and must not be undone.** Requiring the operator to
state the PARTLABEL set explicitly, with no default and no ambient fallback, is
the deliberate half of this design and it rests on real incident history. The
2026-08-10 incident recorded in `AGENTS.md` is exactly what an inherited ambient
value produces: a `rock-edge-test` candidate built with the frozen production
label set, run from a bench microSD on a board whose eMMC carried an unrelated
plain-labelled image, addressing `/boot` and `rauc status mark-bad` on the wrong
physical medium while looking entirely healthy. That is why
`ci/build-hardware-candidates.sh` REFUSES a build with no `--bench-labels`, why
the value is validated to be exactly `0` or `1`, why every candidate build logs
the active mode, and why the artifact tuple records `bench_labels` +
`partlabel_set`. None of that is in question here, and none of it should be
softened on the strength of this item.

**What is missing.** Nothing anywhere verifies the human's choice against the
board it is about to be deployed to. The chain is: operator remembers the flag →
build bakes an fstab → RAUC installs the bundle → the board tries to mount. Only
the last step consults physical reality, and by then the image is already on the
device. There is no preflight that reads the target block device's actual GPT
PARTLABELs and compares them against the candidate image's baked-in `/etc/fstab`
expectations. `tests/preflash-verify.sh` is not that check: it asserts the FROZEN
production label set on a `.raw` an operator is about to flash, so a bench image
fails it by design and a bench-labelled board is outside its scope entirely.
RAUC is not that check either: it verifies the bundle signature and manifest and
writes the slot, and it neither reads nor cares about in-rootfs fstab content.

**The incident this entry records (2026-08-27).** A `rock-5b-plus --variant edge`
build was made WITHOUT `CERALIVE_BENCH_LABELS=1` and deployed via `rauc install`
to a board whose actual GPT uses the bench (`x`-prefixed) labels
`xboot`/`xrootfs_a`/`xrootfs_b`/`xdata`, established in an earlier deployment
specifically to avoid colliding with a production eMMC layout. The install
SUCCEEDED cleanly: bundle verified, signature checked, slot B written. The
failure surfaced only at boot, where systemd's
`dev-disk-by-partlabel-boot.device` and `-data.device` units waited for devices
that were never going to appear, because the rootfs's `/etc/fstab` asked for the
production `boot` and `data` labels and this board's GPT has only `xboot` and
`xdata`. `/boot` and `/data` never mounted, every dependent unit failed, and the
board dropped to emergency mode. The cascade did not stop at mounts: the
account's password-hardening step depends on `/data`, so it never completed and
login was rejected with every credential, over every path. The UI RPC route and
direct SSH were both unusable for the same reason. Recovery needed a UART serial
console (`/dev/ttyUSB0`, 1500000 baud) to observe the emergency-mode diagnosis,
and the actual repair came from U-Boot's own A/B bootcount safety net: slot B
exhausted its attempts across two failed boots and the third power-cycle fell
through to slot A, which worked because slot A had been explicitly marked good
before the risky install.

**This is a general risk, not a one-off.** Any future `edge` or bench-labelled
build for this same board, or for any board whose GPT carries the bench label
set, can reproduce it identically. The dangerous property is the shape of the
failure: the build succeeds, the bundle validates, the install succeeds, and the
first signal is an unbootable slot on a board that may be physically remote. The
flag is one input among several on a long-running dispatch, and human memory is
currently the only thing standing between a correct build and this outcome.

**Unblock condition.** Add a preflight that cross-checks the candidate image's
baked-in fstab expectations against the target device's real GPT before the
image can boot from it, and make a mismatch a loud refusal rather than a silent
write. Either placement works:

1. **At RAUC install time**, as a pre-install hook on the device, which has the
   advantage of running on the actual target with the actual bundle in hand; or
2. **As a new build/deploy helper** in `ci/`, invoked before `rauc install`,
   reading the target's PARTLABELs over the same channel the deployment uses.

Either way the check must derive BOTH sides empirically: parse the
`PARTLABEL=` entries out of the candidate rootfs's `/etc/fstab` (plus the RAUC
`system.conf` slot devices, which move with the same overlay), enumerate the real
labels present on the target block device, and refuse on any expected label that
is absent. Deriving one side from a hardcoded list, or from the operator's stated
intent rather than from the artifact, reintroduces the same class of error one
layer up. Verify against both label sets, and include a non-vacuity leg proving
the check actually fails a deliberately mismatched pair.

**Not in scope here.** This entry is documentation of the gap. Implementing the
preflight is separate work, and it must not weaken the explicit-flag requirement
above, which remains the correct first line of defence.

---

## Related Documents

| Document | Scope |
|----------|-------|
| `docs/hardware-gated-completion.md` | **Consolidated execution runbook** — exact commands, file:line targets, and acceptance criteria for all 6 gated items |
| `docs/cog-display-addon.md` | Cog packaging recipe, libmali strategy, §7 hardware caveats |
| `docs/cog-display-hw-checklist.md` | Ready-to-run RK3588 render QA runbook (clears item 4) |
| `docs/kiosk-display.md` | Kiosk chassis, Phase-3 deferral register (e-ink, dual-display, live-video preview, battery telemetry) |
| `docs/DEVICE-BRINGUP.md` | Public bring-up guide with hardware-evidence TODOs (item 6) |
| `manifests/boards/orange-pi-5-plus.yaml` | OPi 5+ board manifest with FIXME ID_PATHs (item 1) |
| `lib/orchestrate.sh` | x86 disk assembly — RESOLVED Task 12 (item 3); efi/grub → `assemble-disk-x86.sh` |
| `docs/kernel-build-from-source.md` | Opt-in kernel-from-source variants: pins, backend, integration semantics, and items 9 / 9b's gaps |
| `docs/notes/sharing-kernel-capability.md` | Measured vendor-kernel symbol closure for sharing, the retired out-of-tree `cls_fw` remediation, and §7 on the production-track flip (item 10) |
| `docs/notes/sharing-qdisc-matrix.md` | qdisc/netfilter availability per kernel track, including the runtime cake→HTB fallback (item 11) |
| `AGENTS.md §KNOWN ISSUES / DEFERRED` | Prose summary of items 1, 2, and 4 |
| CeraUI `AGENTS.md §NETWORK-INGEST GATEWAY` | Cross-repo consumer: backend probe surface, streaming-start gate, and the LiveView Network Ingest card that item 8's checklist exercises |

## Cross-Repo Note

Item 8 (network-ingest on-device relay verification) spans two repositories: the
gateway unit is baked here (`mkosi/runtime/rtmp-gateway/`, Todo 14 — one MediaMTX
process for both RTMP and SRT); the runtime verification surface (LAN status probe,
stream-start gate, LiveView card) lives
in `ceralive/CeraUI` (Todos 16–19, see `CeraUI/AGENTS.md` → NETWORK-INGEST
GATEWAY). The on-device checklist in item 8 exercises BOTH halves end-to-end —
it is not resolvable by changes in either repo alone.
