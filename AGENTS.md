# image-building-pipeline

Parent: [`../AGENTS.md`](../AGENTS.md)

## ROLE IN THE GROUP

Assembly hub for the device image. Pulls every device-side first-party component
(.deb packages from `srtla`, `srt`, `ceracoder`, `CeraUI`), drives an Armbian build,
and produces a flashable image for RK3588 targets (Orange Pi 5+, Radxa Rock 5B+).

Relates to:
- `cert-work/` — GPG signing key injected into image; mTLS certs baked in
- `apt-worker/` — runtime apt source on device points to `apt.ceralive.tv` (Cloudflare R2)
- `versions.yaml` — pin registry; `fetch-debs.sh` will read it after Task 24 wiring

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

**versions.yaml**
After Task 24 wiring, `fetch-debs.sh` reads pin versions from `../versions.yaml`
instead of resolving latest. Don't hardcode versions in the script.

## ANTI-PATTERNS

- Don't change REPOS order or casing — downstream scripts key on exact names
- Don't duplicate `ARMBIAN_NATIVE.md` content here or in PRs — link to it
- Don't add `ceralive-platform` to REPOS — cloud-only, not in device image
- Don't commit GPG private keys or mTLS certs — those come from `cert-work/` at build time
