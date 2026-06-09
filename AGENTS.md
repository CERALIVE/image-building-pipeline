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
./v2/build <board>          # e.g. ./v2/build rock-5b-plus
DRY_RUN=1 ./v2/build <board>   # resolve + fetch plan only
```
Entry: `v2/build` → `v2/lib/orchestrate.sh`. Produces `.raw` sysext bundles and
`.raucb` A/B RAUC OTA packages. See [`v2/docs/dev-loop.md`](v2/docs/dev-loop.md).

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
