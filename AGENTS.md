# image-building-pipeline

Parent: [`../AGENTS.md`](../AGENTS.md)

## ROLE IN THE GROUP

Assembly hub for the device image. Pulls every device-side first-party component
(.deb packages from `srtla`, `srt`, `ceracoder`, `CeraUI`), drives a mkosi v2 build,
and produces a flashable image for RK3588 targets (Orange Pi 5+, Radxa Rock 5B+).

Relates to:
- `cert-work/` — GPG signing key injected into image; mTLS certs baked in
- `apt-worker/` — runtime apt source on device points to `apt.ceralive.tv` (Cloudflare R2)
- `versions.yaml` — pin registry; `fetch-debs.sh` reads pin versions from `../versions.yaml` [EXISTS]

## STRUCTURE

```
image-building-pipeline/
├── v2/                       # current build system (mkosi)
│   ├── build                 # entry point: ./v2/build <board>
│   ├── manifests/            # board and family manifests + package lists
│   ├── lib/                  # orchestrate.sh, assemble-disk.sh, build-bundle.sh, …
│   ├── docs/                 # dev-loop.md, kiosk-display.md, deferred items
│   └── tests/                # manifest.bats, preflash-verify.sh
├── scripts/
│   └── fetch-debs.sh         # downloads .deb packages for REPOS array
└── CONTRIBUTING.md           # contribution rules
```

## WHERE TO LOOK

| Task | Location |
|------|----------|
| Start a build | `./v2/build <board>` — see [`v2/docs/dev-loop.md`](v2/docs/dev-loop.md) |
| Add/change .deb packages | `scripts/fetch-debs.sh` → `REPOS` array |
| Board/kernel customisation | `v2/manifests/boards/<board>.yaml` |
| Contribution rules | [`CONTRIBUTING.md`](CONTRIBUTING.md) |
| **Dev-sync live-reload loop** | [`v2/docs/dev-loop.md`](v2/docs/dev-loop.md) |
| Manifest schema / validation | `v2/manifests/schema/{board,family}.schema.json` (enforced by `v2/lib/resolve.py`; an invalid manifest fails at validation, not at build) |
| v2 unit tests / x86 boot fallback | `v2/tests/manifest.bats` via `v2/run-tests`; forced-primary-failure rollback proof: `v2/tests/qemu-x86.sh --fallback-selftest` |
| **Kiosk display stack (chassis)** | [`v2/docs/kiosk-display.md`](v2/docs/kiosk-display.md) — units, packages, OOM, wvkbd build |
| Cross-repo kiosk architecture | [`CeraUI/docs/ON_DEVICE_DISPLAY.md`](../CeraUI/docs/ON_DEVICE_DISPLAY.md) — DC-1..DC-4, Phase-3 deferral register |

## KEY FACTS

**Build entry point** [EXISTS]
```bash
./v2/build <board>                       # single board, e.g. ./v2/build rock-5b-plus
./v2/build --all                         # every manifest in manifests/boards/
./v2/build --only rock-5b-plus,x86-minipc  # validated subset
DRY_RUN=1 ./v2/build <board>             # resolve + fetch plan only
```
Entry: `v2/build` → `v2/lib/orchestrate.sh`. Produces `.raw` sysext bundles and
`.raucb` A/B RAUC OTA packages. See [`v2/docs/dev-loop.md`](v2/docs/dev-loop.md).

Dispatch is by the **count of resolved boards**, not the flag: a single resolved
board (`<board>`, or `--only`/`--all` that resolves to exactly one) execs the
orchestrator as today; a multi-board selection is handed to the parallel runner
(task 12). Until that lands, a multi-board selection is preview-only under
`DRY_RUN=1` (prints the resolved board list, exits 0) and otherwise fails loudly.
An unknown board in `--only` exits non-zero, names the offender, and lists the
available boards — it is never silently skipped.

**REPOS array — case and order are sacred**
```bash
REPOS=("srtla" "srt" "ceracoder" "CeraUI")
```

**CI vs local .deb fetch**
- `R2_ACCESS_KEY_ID` set → fetch from R2 (`dists/{CHANNEL}/binary-{ARCH}/`)
- unset → `gh release download` from GitHub releases

**versions.yaml** [EXISTS]
`fetch-debs.sh` reads pin versions from `../versions.yaml` instead of resolving latest.
Don't hardcode versions in the script.

**Reproducible builds** [EXISTS]
Same source state → bit-identical `.raucb`. The orchestrator pins one
`SOURCE_DATE_EPOCH` (env override → HEAD commit time → frozen fallback, via
`common.sh::resolve_source_date_epoch`) and exports it so every embedded mtime
(rootfs.tar, squashfs, ext4, mkosi) clamps to it. `build-bundle.sh` signs the RAUC
bundle through a deterministic OpenSSL CMS path (`-noattr` → no wall-clock
`signingTime`; real leaf key + chain, still `rauc`-verifiable) because `rauc`
itself bakes an uncontrollable CMS timestamp. `REPRODUCIBLE=0` opts back into the
native `rauc bundle` signer (NOT bit-reproducible). Proof: `v2/run-tests` section
11; double-build the same board and compare `.raucb` sha256.

## KIOSK STACK

The image ships a kiosk display stack (cage + Chromium + wvkbd) **installed but inert by default**. All kiosk units are masked at first boot. CeraUI enables kiosk mode at runtime via systemctl — no reflash needed.

**Repo boundary (DC-1):** the image owns the chassis (units, packages, OOM config, `OnFailure` handler). CeraUI owns the content, control, and lifecycle state (toggle RPC, token mint, state machine).

**Implementation status:** Tasks 26 (systemd units), 27 (packages), 28 (RK3588 dual-GPU udev + touch calibration), and 30 (integration validation) are **hardware-blocked** — no RK3588 board is reachable from the dev environment (Task 1 spike: NO-GO). The architecture is fully specced; implementation waits for hardware access.

**Phase-3 deferrals:** e-ink kernel DRM driver + device-tree, dual-display hybrid, on-device live-video preview, and #61 battery/power telemetry (document-only: current boards are mains-powered, no fuel-gauge IC). Full register: [`v2/docs/kiosk-display.md §7`](v2/docs/kiosk-display.md).

## ANTI-PATTERNS

- Don't change REPOS order or casing — downstream scripts key on exact names
- Don't add `ceralive-platform` to REPOS — cloud-only, not in device image
- Don't commit GPG private keys or mTLS certs — those come from `cert-work/` at build time
- Don't implement kiosk units/packages without clearing the Task 1 hardware gate first

## KNOWN ISSUES / DEFERRED

**OPi 5+ interface ID_PATHs are FIXME placeholders.** `manifests/boards/orange-pi-5-plus.yaml`
ships the `interfaces:` block with `FIXME-…` values because the board is not in
hand. The OPi 5+ has two onboard r8169 NICs on the same driver/bus, so a generic
`Type=ether` match races. Before building an OPi 5+ image, read the real ID_PATHs
on the device (`udevadm info /sys/class/net/<iface> | grep ID_PATH`) and replace
each FIXME. Until then `install_interface_naming()` skips the FIXME values and
emits only the generic `Type=wlan → wlan0` rule; the dual NICs stay
non-deterministic.

**Modem source-routing may not fire (NM `dhcp=internal`).** The SRTLA dhclient
exit hook (`/etc/dhcp/dhclient-exit-hooks.d/srtla-source-routing`) installs
per-modem source-policy routes on DHCP `BOUND` events. NetworkManager in Debian
bookworm defaults to `dhcp=internal` (its own DHCP client), which does NOT execute
`dhclient-exit-hooks.d/`. Modem routing may therefore never trigger for
NM-managed interfaces. The wifi path is unaffected (it uses the NM dispatcher,
`/etc/NetworkManager/dispatcher.d/90-srtla-wifi-routing`). Verify with a modem
attached: check `journalctl -t srtla-routing` and `ip rule show` after the modem
connects. If the hook doesn't fire, extend `90-srtla-wifi-routing` to also match
`usb*|wwan*` and assign tables 100–107 by index — but that touches the
drift-gated SRTLA payloads (`v2/ci/postinst-drift-check.sh` CHECK 2) and requires
a deliberate twin-update of both `networking-srtla.sh` and the `§6` block in
`mkosi.postinst.chroot`.

**Modem `usb0..7` naming is hardware-gated.** Deterministic modem renames need a
physical modem to read its ID_PATH; not implemented here. Only `eth0/eth1/wlan0`
are pinned today.
