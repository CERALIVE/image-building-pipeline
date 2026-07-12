# Deferred and Hardware-Gated Work

**Status:** `[EXISTS]`

This index consolidates every item that is explicitly deferred or blocked on
physical hardware access. Each entry records what the item is, why it is
deferred, where the relevant code or spec lives, and what must happen before
work can resume.

Items are documentation-only. None are resolved here.

---

## 1. OPi 5+ Interface ID_PATH Placeholders

**Status:** Deferred (hardware-gated)
**Location:** `v2/manifests/boards/orange-pi-5-plus.yaml:45-47`
**Also referenced:** `AGENTS.md` → *KNOWN ISSUES / DEFERRED* → "OPi 5+ interface ID_PATHs are FIXME placeholders"
**Cross-repo:** tracked in the workspace-root `docs/DEFERRED-WORK.md` as item 3 (*Orange Pi 5+ interface ID_PATHs*); owned here.

**What it is:** The `interfaces:` block in the Orange Pi 5+ board manifest
carries `FIXME-…` placeholder values for all three network interfaces
(`eth0`, `eth1`, `wlan0`). The OPi 5+ has two onboard r8169 NICs on the same
driver and bus, so a generic `Type=ether` udev match races between them.
Deterministic renaming requires the real `ID_PATH` values read from the
physical board.

**Why deferred:** The board is not in hand. `ID_PATH` values are
hardware-specific and cannot be fabricated from specs or emulation. Until they
are filled in, `install_interface_naming()` skips the FIXME entries and emits
only the generic `Type=wlan → wlan0` rule; the dual NICs stay non-deterministic.

**Unblock condition:** Obtain a physical Orange Pi 5+. Run
`udevadm info /sys/class/net/<iface> | grep ID_PATH` for each onboard NIC and
the wifi adapter, then replace each FIXME in
`v2/manifests/boards/orange-pi-5-plus.yaml:45-47` with the real value.
Re-run `v2/run-tests` to confirm the manifest validates.

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
`v2/manifests/boards/<board>.yaml` (or a shared family manifest) using the
real `ID_PATH` values. Note: any change to the modem interface naming block
also touches the drift-gated SRTLA payloads (`v2/ci/postinst-drift-check.sh`
CHECK 2) and requires a twin-update of both `networking-srtla.sh` and the `§6`
block in `mkosi.postinst.chroot`.

---

## 3. x86 ESP + GRUB A/B Disk Assembly — RESOLVED (Task 12)

**Status:** RESOLVED (Task 12, this round). The former `TODO(x86-disk)` is closed.
**Location:** `v2/lib/orchestrate.sh` (efi/grub branch); `v2/lib/assemble-disk-x86.sh`

**What it was:** When `RAUC_BOOTLOADER_ADAPTER` was `efi` or `grub`, the
orchestrator's Stage-4 disk assembly step was explicitly skipped — the x86 build
produced a `rootfs.tar` only, no flashable `.raw`.

**How it was resolved:** Task 12 wired x86 disk assembly. Its VERIFY-FIRST gate
found mkosi's native `Bootloader=grub` INCOMPATIBLE with the `Format=none` +
offline-assemble model (mkosi `disk` is `Bootable=no`; the producer is the offline
`assemble-disk.sh`), so GRUB is **script-installed** with RAUC's **native
`bootloader=grub`** backend:

- `v2/lib/assemble-disk-x86.sh` — offline x86 producer (parallel to the RK3588
  `assemble-disk.sh`): lays an ESP (`grub-mkstandalone` removable-path
  `/EFI/BOOT/BOOTX64.EFI` + `grub.cfg` + `grubenv`) plus the FROZEN
  `rootfs_a`/`rootfs_b`/`data` slots (reused verbatim; `repart/` zero-diff, G3).
- `v2/mkosi/platform/x86/install-x86-grub.sh` — `rootfs` (system.conf
  `bootloader=grub` + ESP fstab), `esp` (grub.cfg + grubenv + BOOTX64.EFI),
  `grubenv-set`; `grub-ab.cfg` is the `ORDER`/`<slot>_OK`/`<slot>_TRY` selector.
- `v2/mkosi/mkosi.images/platform/mkosi.finalize` — x86 branch installs the
  `bootloader=grub` system.conf into the rootfs.
- Offline proof: `v2/mkosi/platform/x86/test-x86-grub.sh` (34 assertions incl. the
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
**Location:** `v2/docs/cog-display-addon.md` §7 (*Hardware-gated caveats (render QA)*), `v2/docs/cog-display-hw-checklist.md` (full runbook), `AGENTS.md` → *KNOWN ISSUES / DEFERRED* → "Cog render QA hardware-gated", `AGENTS.md` → *KIOSK STACK* → "Cog display add-on (W4)"

**What it is:** The Cog + WPEWebKit display add-on packaging is fully
validated in software (apt index, layer contract, build+sign pipeline). The
`cog.sysext.conf` descriptor and build wrapper exist as inert scaffolds. They
are not wired into the build or CI `addon-publish` path until a physical RK3588
board validates render.

The hardware-gated items are:

- Cog renders at all via the real Mali-G610 Valhall GPU userspace
  (`libmali-valhall-g610-g24p0-wayland-gbm`) providing EGL/GBM
- OKLCH and Tailwind v4 CSS correctness on WebKit 2.38.6 (the bookworm version
  may predate the Chromium ≥111 floor assumed by the cage + Chromium kiosk path)
- `cog` platform choice: direct-DRM/KMS vs under `cage` (DRM node mapping is
  itself a Task 28 hardware item)
- Touch input through the WPE/Wayland seat (requires DSI touchscreen + calibration)
- GLVND vs `dpkg-divert` libmali wiring
- Measured `cog.raw` size and size-budget impact

**Why deferred:** No RK3588 board is reachable from the dev environment (Task 1
spike verdict: NO-GO). The Mali-G610 GPU userspace is a proprietary Rockchip
blob not present in Debian bookworm or Armbian's main feed; it cannot be
emulated. Everything provable without hardware is already green and recorded in
`test-results/task-39-cog-qa.txt`.

**Unblock condition:** Run the full checklist in
`v2/docs/cog-display-hw-checklist.md` on a physical Radxa Rock 5B+ or Orange
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
`pin: null`. The apt-index-validated versions (cog `0.16.1-1`,
`libwpewebkit-1.1-0` `2.38.6-1`) are recorded in comments but not pinned,
because pinning before render QA passes would lock a version that may need to
change (e.g. if WebKit 2.38.6 proves insufficient for OKLCH/Tailwind v4 and a
trixie/backport snapshot is needed instead).

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
`v2/docs/cog-display-addon.md` §9 (*Known technical debt* → TD-C1).

**Unblock condition:** Same gate as item 4. After the Cog render QA checklist
passes on hardware, fill the real `artifact.sha256` in `cog-display.json`, then
set `pin: 0.16.1-1` and `pin: 2.38.6-1` (or the trixie/backport equivalents if
the bookworm versions proved insufficient) in `versions.yaml:157` and
`versions.yaml:164`. Re-run `python3 v2/ci/validate-manifests.py` to confirm.

---

## 6. DEVICE-BRINGUP.md Hardware-Evidence Placeholders

**Status:** Deferred (hardware-gated)
**Location:** `docs/DEVICE-BRINGUP.md:296`, `docs/DEVICE-BRINGUP.md:328`, `docs/DEVICE-BRINGUP.md:413`, `docs/DEVICE-BRINGUP.md:669`

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
  frontend path is specced (`v2/dev-sync`; see `v2/docs/dev-loop.md`) but the
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
**Location:** `v2/mkosi/runtime/rtmp-gateway/mediamtx.yml` — the SINGLE config
surface for both legs (`authInternalUsers` for auth; `srt`/`srtAddress` for the SRT
listener); installed by `v2/mkosi/customize/postinst-lib.sh::setup_rtmp_gateway`;
`v2/mkosi/runtime/ingest-firewall/` (the ingress firewall that enforces the LAN
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
firewall** (`v2/mkosi/runtime/ingest-firewall/ingest-firewall.nft` +
`ceralive-ingest-firewall.service`, staged by
`postinst-lib.sh::setup_ingest_firewall`, `nftables` added to `shared.list`). The
`inet ceralive_ingest_fw` table DROPs inbound `:1935` (RTMP) and `:4001`
(SRT) — both served by the single MediaMTX gateway (Todo 14) — on the
**WAN/modem/WWAN/ppp** uplink interface classes
(`usb*`/`enx*`/`ww*`/`ppp*` — the SAME classes the SRTLA source-routing dispatcher
in `networking-srtla.sh`/postinst §6 uses; loopback and LAN/hotspot ifaces are
untouched). So a publisher out on the public internet (a modem's public/CGNAT
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
**Location:** `v2/mkosi/runtime/rtmp-gateway/` (Todo 14 — the single MediaMTX
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

## Related Documents

| Document | Scope |
|----------|-------|
| `v2/docs/hardware-gated-completion.md` | **Consolidated execution runbook** — exact commands, file:line targets, and acceptance criteria for all 6 gated items |
| `v2/docs/cog-display-addon.md` | Cog packaging recipe, libmali strategy, §7 hardware caveats |
| `v2/docs/cog-display-hw-checklist.md` | Ready-to-run RK3588 render QA runbook (clears item 4) |
| `v2/docs/kiosk-display.md` | Kiosk chassis, Phase-3 deferral register (e-ink, dual-display, live-video preview, battery telemetry) |
| `docs/DEVICE-BRINGUP.md` | Public bring-up guide with hardware-evidence TODOs (item 6) |
| `v2/manifests/boards/orange-pi-5-plus.yaml` | OPi 5+ board manifest with FIXME ID_PATHs (item 1) |
| `v2/lib/orchestrate.sh` | x86 disk assembly — RESOLVED Task 12 (item 3); efi/grub → `assemble-disk-x86.sh` |
| `AGENTS.md §KNOWN ISSUES / DEFERRED` | Prose summary of items 1, 2, and 4 |
| CeraUI `AGENTS.md §NETWORK-INGEST GATEWAY` | Cross-repo consumer: backend probe surface, streaming-start gate, and the LiveView Network Ingest card that item 8's checklist exercises |

## Cross-Repo Note

Item 8 (network-ingest on-device relay verification) spans two repositories: the
gateway unit is baked here (`v2/mkosi/runtime/rtmp-gateway/`, Todo 14 — one MediaMTX
process for both RTMP and SRT); the runtime verification surface (LAN status probe,
stream-start gate, LiveView card) lives
in `ceralive/CeraUI` (Todos 16–19, see `CeraUI/AGENTS.md` → NETWORK-INGEST
GATEWAY). The on-device checklist in item 8 exercises BOTH halves end-to-end —
it is not resolvable by changes in either repo alone.
