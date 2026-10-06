<!-- Moved verbatim from AGENTS.md on 2026-10-05 by lean-rules-docs-landing-latam -->

## STRUCTURE

```
image-building-pipeline/          # build system lives at the root (mkosi v26)
├── build                     # entry point: ./build <board>
├── run-tests                 # canonical test entrypoint
├── dev-push / dev-sync       # dev-loop helpers
├── ci/
│   ├── Dockerfile            # pinned debian:trixie-slim builder (mkosi 26)
│   ├── seal-raw-candidate.sh # post-preflash .raw → .raw.xz + both SHA-256 records
│   └── publish-immutable-r2-pair.sh # approved-digest-bound RAUC publisher
├── manifests/                # board/family manifests + exact package registries
│   └── schema/
│       └── addon.schema.json # add-on descriptor JSON Schema (T21)
├── lib/                      # orchestrate.sh (thin SEQUENCER), assemble-disk.sh,
│   │                         #   build-bundle.sh, build-all.sh (parallel runner),
│   │                         #   build-feature-sysext.sh, measure-size.sh, parity-check.sh,
│   │                         #   fetch-debs.sh (REPOS array + FIRST_PARTY_APT_PKGS), …
│   ├── stages/               # one module per orchestrator [N/9] stage body
│   ├── kernel/               # build-kernel.sh concern modules (config/checkout/builder/package)
│   ├── disk/                 # assemble-disk.sh concern modules (repart/slot/boot/gap/verify)
│   └── app-layer/
│       └── sysext.sh         # sysext build lib (extract → prune → squashfs)
├── mkosi/                    # mkosi config, customize hooks, runtime artifacts, platform
├── fleet/                    # hawkBit provisioning + platform bridge
├── tests/                    # manifests, RK3588 A/B/preflash, x86 rollback
├── docs/                     # ONE docs tree — dev-loop.md, kiosk-display.md,
│   │                         #   host-support.md, size-notes.md, cog-display-addon.md,
│   │                         #   cog-display-hw-checklist.md, addon-sysext-refresh.md,
│   │                         #   DEFERRED.md, fast-reload.md (dev-sync live-reload loop)
│   ├── FIRST-BOOT.md         # operator first-boot guide: flash → WiFi portal → SSH → CeraUI [EXISTS]
│   ├── DEVICE-BRINGUP.md     # developer bring-up guide: build, flash, dev loop, E2E smoke test
│   └── partition-contract.md # frozen GPT layout contract
└── CONTRIBUTING.md           # contribution rules
```

