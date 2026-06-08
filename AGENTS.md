# image-building-pipeline

Parent: [`../AGENTS.md`](../AGENTS.md)

## ROLE IN THE GROUP

Assembly hub for the device image. Pulls every device-side first-party component
(.deb packages from `srtla`, `srt`, `ceracoder`, `CeraUI`), drives an Armbian build,
and produces a flashable image for RK3588 targets (Orange Pi 5+, Radxa Rock 5B+).

Relates to:
- `cert-work/` — GPG signing key injected into image; mTLS certs baked in
- `apt-worker/` — runtime apt source on device points to `apt.ceralive.tv` (Cloudflare R2)
- `versions.yaml` — pin registry; `fetch-debs.sh` reads pin versions from `../versions.yaml` [EXISTS]

## STRUCTURE

```
image-building-pipeline/
├── build.sh                  # main entry: clones Armbian, calls compile.sh
├── scripts/
│   └── fetch-debs.sh         # downloads .deb packages for REPOS array
├── userpatches/              # Armbian overlay: kernel config, board hooks, rootfs
├── QUICKSTART.md             # fastest path to a working build
├── ARMBIAN_NATIVE.md         # native-build setup (no Docker)
└── CONTRIBUTING.md           # contribution rules
```

## WHERE TO LOOK

| Task | Location |
|------|----------|
| Start a build | [`QUICKSTART.md`](QUICKSTART.md) |
| Native (no Docker) build | [`ARMBIAN_NATIVE.md`](ARMBIAN_NATIVE.md) |
| Add/change .deb packages | `scripts/fetch-debs.sh` → `REPOS` array |
| Board/kernel customisation | `userpatches/` |
| Armbian framework entry | `build.sh` lines ~379-492 |
| Contribution rules | [`CONTRIBUTING.md`](CONTRIBUTING.md) |
| **Dev-sync live-reload loop** | [`v2/lib/dev-sync/README.md`](v2/lib/dev-sync/README.md) |
| Manifest schema / validation | `v2/manifests/schema/{board,family}.schema.json` (enforced by `v2/lib/resolve.py`; an invalid manifest fails at validation, not at build) |
| v2 unit tests / x86 boot fallback | `v2/tests/manifest.bats` via `v2/run-tests`; forced-primary-failure rollback proof: `v2/tests/qemu-x86.sh --fallback-selftest` |
| **Kiosk display stack (chassis)** | [`v2/docs/kiosk-display.md`](v2/docs/kiosk-display.md) — units, packages, OOM, wvkbd build |
| Cross-repo kiosk architecture | [`CeraUI/docs/ON_DEVICE_DISPLAY.md`](../CeraUI/docs/ON_DEVICE_DISPLAY.md) — DC-1..DC-4, Phase-3 deferral register |

## KEY FACTS

**Armbian external entry**
```bash
git clone --depth=1 https://github.com/armbian/build.git
# then: ./compile.sh  (checked for existence before use)
```

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

**Build system: mkosi (`v2/`)** [EXISTS]
The current build path is `v2/` using mkosi, producing reproducible `.raw` sysext bundles
and `.raucb` A/B RAUC OTA packages. The Armbian `build.sh` flow is legacy/superseded.
See [`v2/docs/dev-loop.md`](v2/docs/dev-loop.md) for the canonical dev loop.

## KIOSK STACK

The image ships a kiosk display stack (cage + Chromium + wvkbd) **installed but inert by default**. All kiosk units are masked at first boot. CeraUI enables kiosk mode at runtime via systemctl — no reflash needed.

**Repo boundary (DC-1):** the image owns the chassis (units, packages, OOM config, `OnFailure` handler). CeraUI owns the content, control, and lifecycle state (toggle RPC, token mint, state machine).

**Implementation status:** Tasks 26 (systemd units), 27 (packages), 28 (RK3588 dual-GPU udev + touch calibration), and 30 (integration validation) are **hardware-blocked** — no RK3588 board is reachable from the dev environment (Task 1 spike: NO-GO). The architecture is fully specced; implementation waits for hardware access.

**Phase-3 deferrals:** e-ink kernel DRM driver + device-tree, dual-display hybrid, on-device live-video preview, and #61 battery/power telemetry (document-only: current boards are mains-powered, no fuel-gauge IC). Full register: [`v2/docs/kiosk-display.md §7`](v2/docs/kiosk-display.md).

## ANTI-PATTERNS

- Don't change REPOS order or casing — downstream scripts key on exact names
- Don't duplicate `ARMBIAN_NATIVE.md` content here or in PRs — link to it
- Don't add `ceralive-platform` to REPOS — cloud-only, not in device image
- Don't commit GPG private keys or mTLS certs — those come from `cert-work/` at build time
- Don't implement kiosk units/packages without clearing the Task 1 hardware gate first
