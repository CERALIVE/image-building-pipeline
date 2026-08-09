# image-building-pipeline

## ROLE IN THE GROUP

Assembly hub for the device image. Pulls every device-side first-party component
(.deb packages from `srtla-send-rs`, `cerastream`, `CeraUI`), drives a
containerized mkosi v26 build, and produces a flashable image for RK3588 targets
(Orange Pi 5+, Radxa Rock 5B+).

Relates to:
- `cert-work/` — GPG signing key injected into image; mTLS certs baked in; add-on keyring sourced from here; PASETO device-token PUBLIC key (`paseto/`) provisioned into the CeraUI runtime env
- `apt-worker/` — runtime apt source on device points to `apt.ceralive.tv` (Cloudflare R2); add-on `.raw` artifacts served from R2 path `addons/{os_version}/{board}/{feature}.raw`
- `versions.yaml` — standalone pin registry consumed by `fetch-debs.sh` [EXISTS]

## STRUCTURE

```
image-building-pipeline/
├── v2/                       # current build system (mkosi v26)
│   ├── build                 # entry point: ./v2/build <board>
│   ├── ci/
│   │   ├── Dockerfile        # pinned debian:trixie-slim builder (mkosi 26)
│   │   └── publish-immutable-r2-pair.sh # approved-digest-bound RAUC publisher
│   ├── manifests/            # board/family manifests + exact package registries
│   │   └── schema/
│   │       └── addon.schema.json   # add-on descriptor JSON Schema (T21)
│   ├── lib/                  # orchestrate.sh (thin SEQUENCER), assemble-disk.sh,
│   │   │                     #   build-bundle.sh, build-all.sh (parallel runner),
│   │   │                     #   build-feature-sysext.sh, measure-size.sh, parity-check.sh,
│   │   │                     #   fetch-debs.sh (REPOS array + FIRST_PARTY_APT_PKGS), …
│   │   ├── stages/           # one module per orchestrator [N/9] stage body
│   │   └── app-layer/
│   │       └── sysext.sh     # sysext build lib (extract → prune → squashfs)
│   ├── docs/                 # dev-loop.md, kiosk-display.md, host-support.md,
│   │   │                     #   size-notes.md, cog-display-addon.md,
│   │   │                     #   cog-display-hw-checklist.md,
│   │   │                     #   addon-sysext-refresh.md, DEFERRED.md
│   │   └── fast-reload.md    # dev-sync live-reload loop
│   └── tests/                # manifests, RK3588 A/B/preflash, x86 rollback
├── docs/
│   ├── FIRST-BOOT.md         # operator first-boot guide: flash → WiFi portal → SSH → CeraUI [EXISTS]
│   ├── DEVICE-BRINGUP.md     # developer bring-up guide: build, flash, dev loop, E2E smoke test
│   └── partition-contract.md # frozen GPT layout contract
└── CONTRIBUTING.md           # contribution rules
```

## WHERE TO LOOK

| Task | Location |
|------|----------|
| Start a build | `./v2/build <board>` — see [`v2/docs/dev-loop.md`](v2/docs/dev-loop.md) |
| **A specific `[N/9]` build stage** | `v2/lib/stages/<stage>.sh` — see the "orchestrate.sh is an ENTRY plus per-stage modules" KEY FACT below |
| Add/change .deb packages | `v2/lib/fetch-debs.sh` → `REPOS` array (first-party Debian package names: `FIRST_PARTY_APT_PKGS`) |
| **Verified `.deb` download cache (`CERALIVE_DEBCACHE`)** | `v2/lib/fetch/debcache.sh` + the store site in `v2/lib/fetch/pool.sh::publish_staged_deb` — see the KEY FACT below |
| **Production vs debug package split (`CERALIVE_DEBUG_IMAGE`)** | `v2/manifests/packages/development.delta.list` + `v2/lib/common.sh::runtime_pkg_list_files` + `v2/lib/orchestrate.sh` (`resolve_debug_image_flag`, the `[1/9]` package resolution) — see the KEY FACT below |
| Board/kernel customisation | `v2/manifests/boards/<board>.yaml` |
| **Supported-modem matrix / WWAN modules** | [`v2/docs/modem-matrix.md`](v2/docs/modem-matrix.md) — cellular stack (ModemManager 1.24 fork closure §1) + the advisory check `v2/lib/check-wwan-modules.sh` + fail-closed `modem_ports` slot-UID discovery runbook (§7) |
| **Modem slot-UID udev generator (fail-closed)** | `v2/mkosi/customize/udev.sh` `generate_modem_slot_uid_rules` — emits nothing while board `modem_ports.status: unverified`; permanent generic modem rules in `setup_hardware_access` are separate and always ship |
| **Runtime postinst library — which module holds which function** | `v2/mkosi/customize/postinst-lib.sh` is a thin ENTRY; the implementations live in `v2/mkosi/customize/postinst.d/{networking,hostname,services,hardware,persistence,tls-ssh}.sh` — see the KEY FACT below. Every `postinst-lib.sh::<fn>` reference in this file means "the postinst library", and resolves through that entry |
| **USB-C Type-C source-role pinning (camera enumeration)** | `v2/mkosi/customize/postinst-lib.sh` `setup_typec_source_role` + `v2/mkosi/runtime/ceralive-typec-source.{sh,service}` — pins `/sys/class/typec/port0/port_type` to `source` before `cerastream.service`; see the KEY FACT below for the DRP root cause |
| **Fan curve — lower the pwm-fan zone's first `active` thermal trip** | `v2/mkosi/customize/postinst-lib.sh` `setup_fan_curve` + `v2/mkosi/runtime/ceralive-fan-curve.{sh,service}` — generically discovers the zone bound to the `pwm-fan` cooling device and lowers its first `active` trip to 45 °C; the `critical` trip and `thermal_zone*/mode` are never touched. See the KEY FACT below |
| **Fan kick-start — brief full-PWM nudge so the fan can start from a dead stop** | `v2/mkosi/customize/postinst-lib.sh` `setup_fan_kickstart` + `v2/mkosi/runtime/ceralive-fan-kickstart.{sh,service}` — the RESIDENT monitor (not a oneshot) that watches the `pwm-fan` cooling device's `cur_state` for a 0 → nonzero edge, drives it to `max_state` for ~1 s, then writes the governor's own state back. The restore is mandatory, not cosmetic — a userspace `cur_state` write is STICKY on this kernel. See the KEY FACT below |
| **Status LEDs — give the board's unconfigured indicator LEDs a default trigger** | `v2/mkosi/customize/postinst-lib.sh` `setup_led_status` + `v2/mkosi/runtime/ceralive-led-status.{sh,service}` — generically discovers the non-`mmc*`, non-`power` indicator LEDs and assigns `heartbeat` to the first and `mmc1` to the second; `brightness` is never written and the kernel's own `mmc0::` LED is never touched. See the KEY FACT below |
| **Boot-time dead-weight unit masks (networkd stack, machine-id commit, standalone dnsmasq, chrony-wait)** | `v2/mkosi/customize/postinst-lib.sh` `suppress_unusable_boot_units` + `mask_service` — see the KEY FACT below for why a `disable` is silently undone on first boot |
| Contribution rules | [`CONTRIBUTING.md`](CONTRIBUTING.md) |
| **Operator first-boot guide** | [`docs/FIRST-BOOT.md`](docs/FIRST-BOOT.md) — flash → WiFi portal → SSH → CeraUI |
| **Manual bench flashing (dev/debug only, real-HW validated)** | [`docs/DEVICE-BRINGUP.md`](docs/DEVICE-BRINGUP.md) §4 "Manual bench flashing" — direct `rkdeveloptool db`/`wl`/`rd`, timeout discipline, UART baud, and log-parsing gotchas; NOT a production/recovery path (see the CI release gate in the same section) |
| **Dev-sync live-reload loop** | [`v2/docs/dev-loop.md`](v2/docs/dev-loop.md) |
| Manifest schema / validation | `v2/manifests/schema/{board,family}.schema.json` (enforced by `v2/lib/resolve.py`; an invalid manifest fails at validation, not at build). The family schema also carries the `variants:` map + `kernel_source:` `$defs` — see the kernel-build-from-source KEY FACT |
| Armbian BSP Debian version pins | `v2/manifests/armbian-bsp-deb-versions.txt` |
| v2 unit tests / boot fallback | `v2/tests/manifest.bats`, `v2/tests/rk3588-ab-contract.bats`, and `v2/tests/packaging-hygiene.bats` (absence guards for the removed conf.d seeds / `ceralive-optimize@` want / ceracoder x86 refs) via `v2/run-tests` (GNU-parallel runs files in parallel but cases within each file stay serial; shared build-plan probes also lock staging); RK3588 bootcount proof: `v2/mkosi/platform/boot/test-fallback.sh`; x86 forced-primary proof: `v2/tests/qemu-x86.sh --fallback-selftest` |
| **`/boot` completeness (both kernel paths)** | `v2/lib/verify-boot-artifacts.sh` (the `[6b/9]` build gate), `v2/tests/boot-artifacts.bats` — see the KEY FACT below |
| **A/B selector arithmetic + load guards + its own scratch `loadaddr`** | `v2/mkosi/platform/boot/boot.scr.cmd`, proof `v2/tests/boot-script-sanitize.test.sh` — see the no-`setexpr` and the undefined-`loadaddr` SError KEY FACTs below |
| **x86 ESP + GRUB A/B disk assembly** | `v2/lib/assemble-disk-x86.sh` (offline producer); `v2/mkosi/platform/x86/{install-x86-grub.sh,grub-ab.cfg,10-esp.conf}`; offline proof `v2/mkosi/platform/x86/test-x86-grub.sh`; rationale in [`v2/mkosi/platform/x86/README.md`](v2/mkosi/platform/x86/README.md) §2 |
| **x86-minipc bring-up/validation runbook** (device discovery, build/flash, first-boot, `hw-smoke.sh n100` encoder validation, `.raucb` OTA install+rollback) | [`v2/docs/X86-MINIPC-BRINGUP.md`](v2/docs/X86-MINIPC-BRINGUP.md) — **NOT YET VALIDATED ON HARDWARE**, runbook only |
| **Kiosk display stack (chassis)** | [`v2/docs/kiosk-display.md`](v2/docs/kiosk-display.md) — units, packages, OOM, wvkbd build |
| Cross-repo kiosk architecture | [CeraUI on-device display](https://github.com/CERALIVE/CeraUI/blob/main/docs/ON_DEVICE_DISPLAY.md) — DC-1..DC-4, Phase-3 deferral register |
| **Build host support matrix** | [`v2/docs/host-support.md`](v2/docs/host-support.md) — which hosts work, what they need |
| **Image size notes / levers** | [`v2/docs/size-notes.md`](v2/docs/size-notes.md) — locale strip, firmware audit, size-gate |
| **Kernel freeze / update contract (`apt-mark hold` + apt pin; RAUC-only boot stack)** | [`v2/docs/kernel-freeze-contract.md`](v2/docs/kernel-freeze-contract.md) + `v2/mkosi/customize/postinst-lib.sh::freeze_boot_packages` — see the KEY FACT below |
| **Cog display add-on recipe** | [`v2/docs/cog-display-addon.md`](v2/docs/cog-display-addon.md) — Cog+WPEWebKit packaging, libmali strategy |
| **Cog on-hardware render QA checklist** | [`v2/docs/cog-display-hw-checklist.md`](v2/docs/cog-display-hw-checklist.md) — ready-to-run RK3588 render gate (software path proven in `test-results/task-39-cog-qa.txt`) |
| **sysext refresh protocol** | [`v2/docs/addon-sysext-refresh.md`](v2/docs/addon-sysext-refresh.md) — update/disable lifecycle |
| **Deferred / hardware-gated items** | [`v2/docs/DEFERRED.md`](v2/docs/DEFERRED.md) — index of every deferred item with file:line anchors and unblock conditions |
| **Kernel currency watch** | [`v2/docs/kernel-currency-watch.md`](v2/docs/kernel-currency-watch.md) — vendor 6.1 lock decision, 7-way evidence, and the two precise revisit triggers |
| **Kernel build from source (opt-in variants)** | [`v2/docs/kernel-build-from-source.md`](v2/docs/kernel-build-from-source.md) — the `variants:` model (`edge` = mainline 7.1, `vendor-patched` = vendor 6.1 BSP + HDMI-RX audio fix), `kernel_source:` pins, the two source-checkout shapes (§2b, tagged vs commit-only) and the two config modes (§2c, defconfig-fragment vs fetched full `.config`), `make bindeb-pkg` backend, fetch suppression / package replacement / uniqueness check, and the DTB install mapping |
| **Bench PARTLABEL overlay (`CERALIVE_BENCH_LABELS=1`)** | [`v2/docs/dev-loop.md`](v2/docs/dev-loop.md) → "Bench PARTLABEL overlay" — see the KEY FACT below |
| Add-on descriptor schema | `v2/manifests/schema/addon.schema.json` |
| Build a feature sysext add-on | `v2/lib/build-feature-sysext.sh` |
| Publish a signed add-on to R2 | `v2/lib/upload-addons.sh` (CI: `v2-ci.yml` `addon-publish` job) |
| Publish a hardware-approved RAUC bundle pair to R2 | `v2/ci/publish-immutable-r2-pair.sh` via [`docs/RELEASE-PROCESS.md`](docs/RELEASE-PROCESS.md) §5; requires the independently approved candidate SHA-256 and performs private, read-only input snapshots plus create-only exact-byte recovery |
| **PASETO device-token key provisioning** | [`docs/paseto-key-provisioning.md`](docs/paseto-key-provisioning.md) — generate per-env keypair, route the 3 values; verify with `v2/lib/verify-paseto-key-encodings.sh` |
| **End-to-end release process** (build/sign → immutable candidate → manual hand-test on real HW → manual R2 publish) | [`docs/RELEASE-PROCESS.md`](docs/RELEASE-PROCESS.md) §1-6 |
| **apt.ceralive.tv build-credential rotation** (`APT_GPG_PUBLIC_B64`/`APT_CLIENT_CRT_B64`/`APT_CLIENT_KEY_B64`) | [`docs/RELEASE-PROCESS.md`](docs/RELEASE-PROCESS.md) §7 |
| **OTA-rollback runbook** (bad `.raucb` fleet response, A/B fallback, pulling a published bundle) | [`docs/RELEASE-PROCESS.md`](docs/RELEASE-PROCESS.md) §8 |

## KEY FACTS

**The runtime postinst library is an ENTRY plus per-concern modules — "one source
of truth" now means "one source SET"** [EXISTS]

`v2/mkosi/customize/postinst-lib.sh` is a thin entry (~84 lines): the chroot-safe
`log`/`die`/`resolve_partlabel` fallbacks and an explicit list of the modules under
`v2/mkosi/customize/postinst.d/` that carry the implementation. Sourcing the entry
still yields the COMPLETE API in one `source`, so nothing about how
`mkosi.postinst.chroot`, `customize/services.sh` or `customize/data-persistence.sh`
consume it changed, and `main()`'s call order in the runtime executor is untouched
— including `freeze_boot_packages` running LAST, after every apt transaction in
that layer.

| Module | Holds |
|---|---|
| `postinst.d/networking.sh` | `configure_networking`, `install_interface_naming` + `link_path_match`, `setup_provisioning`, `setup_ingest_firewall` |
| `postinst.d/hostname.sh` | `setup_hostname_service` — the Avahi-arbitrated `<hostname>.local` claim |
| `postinst.d/services.sh` | `ensure_group`/`enable_service`/`disable_service`/`mask_service`, `configure_ntp`, `install_console_font_service`, `configure_services`, `suppress_unusable_boot_units`, `setup_boot_healthcheck`, `setup_avahi_restart`, `setup_cerastream_ordering`, `setup_rtmp_gateway` |
| `postinst.d/hardware.sh` | `setup_typec_source_role`, `setup_fan_curve`, `setup_fan_kickstart`, `setup_led_status` |
| `postinst.d/persistence.sh` | `setup_data_persistence`, `CERALIVE_NEVER_FREEZE_PKGS` + `freeze_boot_packages` |
| `postinst.d/tls-ssh.sh` | `configure_debug_access`, `configure_ssh_enablement`, `setup_ssh_firstboot`, `setup_tls_proxy`, `setup_cert_rotation`, `setup_paseto_public_key` |

Every `postinst-lib.sh::<fn>` reference elsewhere in this file means "the postinst
library" and still resolves — through the entry, in whichever module now holds it.

**Two rules make the split safe, and both are gated.** First, EVERY module carries
its own `declare -F`-guarded `log()`/`die()` fallbacks: the modules are sourced
inside mkosi SUBIMAGE CHROOTS where the repo's `lib/` is NOT mounted, so a module
may never assume anything else has been sourced. Second, the entry's module list is
EXPLICIT, never a glob — a module that is renamed, missing from the source mount, or
added under `postinst.d/` but never wired up must fail loudly at source time rather
than surface later as a `command not found` in a half-configured image.

`v2/ci/postinst-drift-check.sh` resolves each `CONSOLIDATED_FUNCS` entry across the
entry + `postinst.d/` SET (still exactly one definition, still zero re-inlines into
`mkosi.postinst.chroot`/`services.sh`/`data-persistence.sh`), and CHECK 1c enforces
both rules above. `v2/tests/postinst-module-contract.test.sh` proves, in a scrubbed
`env -i` shell with nothing pre-sourced, that every registry function resolves from a
bare `source postinst-lib.sh` and that each module also sources standalone.

**A static test that reads the library by TEXT must read the whole set.** Several
harnesses extract function bodies or generated payloads out of the source
(`real-avahi-hostname-contract.sh`, `systemd-ordering-cycle.test.sh`,
`kernel-freeze-guardrails.test.sh`, `data-persistence-public-symlink.test.sh`, the
`resolv-conf-*` pair, `interface-naming-path-match.test.sh`,
`package-migration-coverage.sh`, `manifest.bats`, `bench-partlabels.bats`). Pointed
at the entry alone they extract NOTHING, and most of their assertions then pass
vacuously. Each one concatenates the entry + `postinst.d/*.sh` for static reads while
still SOURCING the entry; keep that distinction when adding a new check.

**`orchestrate.sh` is an ENTRY plus per-stage modules — the same shape as
`fetch-debs.sh` and `postinst-lib.sh`** [EXISTS]

`v2/lib/orchestrate.sh` is the thin SEQUENCER (397 lines, was 1,045). It keeps the
locations, the env-overridable configuration every stage reads, `usage()`,
`acquire_board_lock`, the mkosi ENVIRONMENT CONTRACT (`run_mkosi_build`'s
`env_names` + exports), and `main()` — which is now a flat list of `stage_*` calls.
Each `[N/9]` stage BODY lives in one module under `v2/lib/stages/`:

| Stage | Module | Also holds |
|---|---|---|
| `[1/9]` | `resolve.sh` | `read_pkg_list`, `resolve_debug_image_flag`, `require_field` |
| `[2/9]` | `fetch.sh` | staging-tree recreation (must be freshly authenticated) |
| `[2b/9]` | `kernel-build.sh` | — |
| `[3/9]` | `partition.sh` | `deb_pkg_name`, `assert_staged_packages_unique` |
| `[4/9]` | `bsp-gate.sh` | — |
| `[5/9]` | `mkosi.sh` | `select_build_mode`, `ensure_builder_image`, `mkosi_invoke` |
| `[6/9]` | `tar-emit.sh` | `emit_artifact` |
| `[6b/9]` | `boot-verify.sh` | — |
| `[6c/9]` | `size-gate.sh` | `compare_size_against_baseline` |
| `[7/9]` | `parity.sh` | — |
| `[8/9]` | `assemble.sh` | both bootloader-adapter branches |

Four rules make the split safe, and each of them is the answer to a real trap:

- **Stage functions read and write `main()`'s locals through bash DYNAMIC
  SCOPING.** `main()` declares the cross-stage state (`kernel_from_source`,
  `family_manifest`, `mkosi_arch`, `ts`, `rootfs_tree`, `build_version`,
  `out_dir`, `artifact`, plus the `staging`/`bsp_dir`/… block) and the modules
  assign into that one frame — which is what makes this a relocation rather than
  a rewrite of the data flow. Those declarations look unused in `main()` and must
  not be "cleaned up". Every module carries a file-level
  `# shellcheck disable=SC2154,SC2034` for exactly this, with the reason stated.
- **The module list is EXPLICIT and ORDERED, never a glob** (the
  `postinst-lib.sh` rule), and the order is PIPELINE order.
- **Three things deliberately did NOT move**: `acquire_board_lock`, the
  `local env_names=( … )` array, and `export CERALIVE_BOARD="${board}"` next to
  the `local staging=` it keys. `env_names` is one half of the
  `env_names` ↔ `mkosi.conf` `PassEnvironment=` lockstep, so it stays in the file
  the guard reads; only mkosi's *invocation* moved out, as `mkosi_invoke`.
- **A static test that reads the orchestrator by TEXT must read the whole SET**,
  concatenated in the entry's own `source` order — the same lesson the
  `postinst.d/` split already records. Pointed at the entry alone,
  `manifest.bats`'s size-gate/x86/env_names extractions and
  `mkosi-package-staging.test.sh`'s greps match NOTHING and pass vacuously. Both
  harnesses build that set into a FILE and grep the file: piping it into `grep -q`
  SIGPIPEs the writer and `set -o pipefail` turns a correct read into a failure.

`stage_size_gate` must stay ABOVE `compare_size_against_baseline` inside
`size-gate.sh`: `manifest.bats` extracts the shipped gate as the FIRST 2-space
`if … fi` mentioning `[6c/9]`, and the comparator's own early-return guards
mention it too, so reordering silently swaps which block the gate's tests execute.

All 26 runtime `[N/9]` log strings are byte-identical to the pre-split file, and
the `DRY_RUN=1` build plan is byte-identical for all three shipped boards.

**Build entry point** [EXISTS]

The **container build is the canonical path.** The orchestrator runs mkosi v26
inside a pinned `debian:trixie-slim` builder (`v2/ci/Dockerfile`). Native builds
(`--native` / `MKOSI_NATIVE=1`) are opt-in and require mkosi ≥ 26 + Python ≥ 3.12
on a Debian trixie+ host. See [`v2/docs/host-support.md`](v2/docs/host-support.md)
for the full host matrix.

```bash
./v2/build <board>                       # single board, e.g. ./v2/build rock-5b-plus
./v2/build --all                         # every manifest in manifests/boards/
./v2/build --only rock-5b-plus,x86-minipc  # validated subset
DRY_RUN=1 ./v2/build <board>             # resolve + fetch plan only
./v2/build <board> --native              # opt-in native build (trixie+ host only)
MKOSI_NATIVE=1 ./v2/build <board>        # same, env-var form
./v2/build <board> --variant edge        # opt-in family variant (mainline 7.1 kernel from source)
./v2/build <board> --variant vendor-patched  # opt-in: vendor 6.1 BSP from source + HDMI-RX audio fix
```

Entry: `v2/build` → `v2/lib/orchestrate.sh`. Produces `.raw` sysext bundles and
`.raucb` A/B RAUC OTA packages. See [`v2/docs/dev-loop.md`](v2/docs/dev-loop.md).

**x86 disk assembly — full A/B GRUB (Task 12)** [EXISTS]

`v2/build x86-minipc` now produces a flashable `.raw` with RAUC **A/B** boot (was:
deferred `TODO(x86-disk)`, rootfs.tar only). x86 boots UEFI → GRUB from an EFI System
Partition with RAUC's **native `bootloader=grub`** backend: `lib/assemble-disk-x86.sh`
(the offline x86 producer, parallel to the RK3588 `assemble-disk.sh`) lays the ESP
(`grub-mkstandalone` removable-path `/EFI/BOOT/BOOTX64.EFI` + `grub.cfg` + `grubenv`)
plus the **FROZEN** `rootfs_a`/`rootfs_b`/`data` slots — `repart/` and the RK3588
assembly stay zero-diff (G3/SC6). The earlier `bootloader=custom` countdown scaffold
is RETAINED, unchanged, only as the offline rollback-contract harness
(`qemu-x86.sh --fallback-selftest`, `test-x86-fallback.sh`). Full rationale +
VERIFY-FIRST finding: [`v2/mkosi/platform/x86/README.md`](v2/mkosi/platform/x86/README.md) §2.
The signed `.raucb` OTA bundle is now emitted on the x86 path too: the `efi`/`grub`
Stage-4 branch calls `build-bundle.sh` after `assemble-disk-x86.sh`, alongside the
`.raw`, stamped with the board-specific `COMPATIBLE_STRING` (`ceralive-<board-id>`).
`build-bundle.sh` is board-agnostic, so the x86 path mirrors the RK3588 `custom`
path verbatim.

**Rock 5B+ production A/B contract** [EXISTS]

`rock-5b-plus.yaml` resolves `single_slot_fallback: false` with RAUC
`bootloader=custom`. The RK3588 assembler emits a 14,800 MiB factory image, writes
the same bootable baseline into `rootfs_a` and `rootfs_b`, seeds A as primary, and
passes `rauc.slot=A|B` on every automatic/manual boot path. The custom backend marks
the inactive target bad before installation and RAUC activates it only after a
successful write; a three-attempt bootcount rolls an unconfirmed slot back.
Both rootfs slots explicitly mount the shared XBOOTLDR p1 at `/boot`; relying on
automatic discovery would fail because each slot's kernel makes `/boot` non-empty.

`v2/tests/preflash-verify.sh` requires `--target-size-bytes` and rejects wrong GPT
starts/sizes or labels, a missing idblock or second-stage FIT, external FIT payloads
whose declared extents exceed the image/8 MiB budget or whose SHA-256 nodes mismatch,
malformed compiled boot metadata, either slot missing its arm64 kernel/board DTB/initrd, stale boot
state, incompatible/invalid signed bundles, and a destination smaller than the raw
image. Its `check_rootfs_populated` resolves the real Armbian kernel-package `/boot`
layout — `/boot/Image` is a symlink to `vmlinuz-<ver>` and only the versioned
`/boot/initrd.img-<ver>` exists (no bare `/boot/initrd.img`). `debugfs dump -p` does
NOT dereference a symlink that is the FINAL path component (it writes the link
target, so a fast symlink yields a 0-byte file), so the gate `stat`s each artifact,
follows a terminal-component symlink to the versioned target, and globs the versioned
initrd name when the bare one is absent; plain-file `/boot` layouts still pass. `v2/run-tests` blocks on the actual boot-script sanitizer, fallback engine,
mock rollback, preflash adversarial fixtures, and the two privileged hardware-free
contracts required by CI: `CERALIVE_RUN_REAL_RAUC_CONTRACT=required` exercises
real-RAUC interruption/cleanup, while
`CERALIVE_RUN_REAL_AVAHI_CONTRACT=required` exercises real mDNS arbitration in
private namespaces. The RAUC harness uses the supported boot-slot override for
its synthetic file-backed slots, so the same service contract runs across CI
RAUC versions without depending on the runner's boot device. A v1 single-slot
disk cannot migrate by
OTA because its `data` partition starts where v2 places `rootfs_b`; back up required
state and perform a full re-flash. Physical Rock 5B+ install/reboot/rollback remains
the hardware acceptance gate in `v2/docs/hardware-gated-completion.md` Item 4.

The v2 CI Bats job installs the split Ubuntu `rauc` + `rauc-service` packages,
starts a system D-Bus, reloads its installed policy, and then invokes the real
RAUC contract; the harness requires RAUC to own its normal system-bus service
name and does not replace that check with a session bus or a skipped test. The
standalone DRY_RUN build-plan jobs materialize the same ignored NON-PRODUCTION
fixture before resolving, so build-plan checks are self-contained too.

Production builds require one explicit RAUC PKI contract: signer root, chain,
leaf certificate/key, and baked device keyring must match. The release workflow
builds the candidate and uploads the raw image, bundle, keyring, and digest as one
immutable artifact for an operator to download; there is no automated
hardware-flashing gate. An operator hand-tests that exact artifact on real
hardware before a manual release, using the bench flash-and-verify tool
(`v2/ci/verify-and-flash-candidate.sh`), which preflights and flashes a private,
digest-verified snapshot of that exact raw image. While
the board is still in maskrom, the tool reads the exact whole-media sector range
back with `rkdeveloptool rl`, hashes the private readback, and refuses to reset
on mismatch. The candidate artifact also carries the official Radxa Maskrom
loader under an exact SHA-256. The gate starts from Maskrom, derives capacity in
loader mode, and uses UART to enable a bounded, one-shot data-only bootstrap that
installs a restricted, expiring run-local root public key into the empty `/data`
key store. The initial `rkdeveloptool db` runs under a pinned leader in an owned
session/process group with a monotonic 15-second command budget. The leader
stays present until command status and descendant cleanup are proved, preventing
PID/process-group reuse from redirecting cleanup signals. On timeout or
interruption the verifier sends TERM to the whole group, waits one second, sends
KILL to survivors, reaps the leader, and fails unless no live or zombie group
member remains. A clean `db` exit is not readiness: a separate 10-second poll
must observe exactly the same
VID/PID/`LocationID` in `Loader` mode before `rfi`. Zero devices or the same
fixture still in Maskrom are transient; malformed, multiple, changed, or
unexpected-mode listings fail immediately. Neither phase retries `db` or any
later destructive operation, and no `rfi`, identity read, write, readback, or
reset may run after failure. The diagnostics distinguish “rkdeveloptool db
command timed out” from “loader re-enumeration timed out.” Test overrides are
hard-capped at 60 seconds for either phase, 10 seconds for each cleanup grace,
and 5 seconds for the poll interval, so configuration cannot recreate an
unbounded handoff.

The bootstrap accepts no shell commands, does not restart, and binds
an authenticated, one-hour-bounded request containing a device-generated nonce,
the baked candidate commit, and a fresh UART challenge to
the post-boot SSH marker. Consumed nonces and a non-decreasing signed epoch floor
persist on `/data`; the runner private key must derive the public verifier baked
into the candidate before any USB operation. The
image contains only the UART verification public key, never an SSH credential or
password. Only after
the immutable proof does it boot, rotate a run-local SSH host-key record, require
`/` on the booted board to resolve to the flashed eMMC, then run the physical
checks and remove the exact temporary key with a cleanup receipt. Each planned
RAUC reboot consumes a one-use retention marker; any unarmed later boot revokes
leftover CI access before sshd. It never compares mutable post-boot media bytes.
Later `rkdeveloptool` operations retain their existing cancellable-child behavior.
The verifier resets inherited ignored INT/TERM dispositions before Bash starts its
signal traps, so CI shells that launch it asynchronously cannot make SIGINT
cancellation ineffective. The identity record accepts only safe artifact filename
characters so its line-oriented fields cannot be split.
Authenticated BSP fetches require the exact two-key Armbian archive rotation set
(`DF00FAF1…E78D5` + `8CFA83D1…6099FE`, with no extra primary keys) and verify
InRelease, Packages.gz, and every package SHA-256. Manual RK3588 recovery uses
`recovery.scr`, which loads boot artifacts directly from p2 or p3.

**Multi-board dispatch** [EXISTS]

Dispatch is by the **count of resolved boards**, not the flag: a single resolved
board (`<board>`, or `--only`/`--all` that resolves to exactly one) execs the
orchestrator directly; a multi-board selection is handed to the parallel runner
`v2/lib/build-all.sh`. An unknown board in `--only` exits non-zero, names the
offender, and lists the available boards — it is never silently skipped.

**REPOS array — case and order are sacred**
```bash
REPOS=("srt" "cerastream" "CeraUI" "srtla-send-rs")
```
`cerastream` is the sole streaming engine — `ceracoder` was retired 2026-06-11
after the generic boot-parity profile passed
(`cerastream/docs/notes/boot-parity-results.md`); RK3588 hardware-gated profiles
now track as cerastream hardware validation, while Jetson profiles are DEFERRED —
not currently planned. `srtla-send-rs` is
the Rust sender fork (v1.0.0+) added at cutover (Task 20); `srtla` is
receiver-side only after cutover. **Conflict declaration:** `srtla-send-rs` declares
`Conflicts: srtla (<< 2026.6.2)` (SRTLA_CUTOVER_VERSION); any pre-cutover
`srtla (<< 2026.6.2)` — which still bundled the C sender — is correctly blocked from
coinstall, while `srtla` v2026.6.2 (the first receiver-only release) is NOT
`<< 2026.6.2`, so it coinstalls with the Rust sender. REPOS lives in
`v2/lib/fetch-debs.sh`.

**First-party .deb fetch — build-time apt pull from apt.ceralive.tv** [EXISTS]

`fetch_first_party` (in `v2/lib/fetch-debs.sh`) pulls the device first-party
`.deb`s from `apt.ceralive.tv` via a GPG-verified, mTLS-authenticated apt source —
this REPLACES the retired R2 `aws s3 sync` (CI) and `gh release download` (local)
paths. It mirrors `v2/mkosi/customize/apt-ceralive-repo.sh`: a deb822 source
(`URIs: …/dists/{CHANNEL}/`, `Suites: ./`, GPG `Signed-By`), the GPG keyring and
the mTLS client cert/key injected from the environment, all in an **isolated apt
state** under the staging dir (the host apt config is never touched).

- **Packages staged** (`FIRST_PARTY_APT_PKGS`): `libsrt1.5-ceralive`,
  `cerastream ceralive-device srtla-send-rs`, the required capture plugin
  `gstreamer1.0-libuvch264src`, PLUS the **ModemManager 1.24 closure** — the nine
  ceralive-forked (`~ceralive0.2.0`) modem packages `modemmanager libmm-glib0
  libmbim-glib4 libmbim-proxy libmbim-utils libqmi-glib5 libqmi-proxy libqmi-utils
  libqrtr-glib0` (modem-stack v0.2.0). All are downloaded into `$DEST/debs/` using the pins
  from `v2/manifests/first-party-deb-versions.txt` (14 packages total). The modem
  closure is a self-contained dependency set (`modemmanager`→`libmm-glib0`; the
  glib libs bind the qmi/mbim/qrtr transports); external deps (GLib, `libgudev`,
  `polkit`, systemd) come from Debian. The app layer classifies all nine as
  `RUNTIME_APP_PKGS` and their `dpkg -i` **upgrades** the Debian modem packages the
  runtime layer pulled via `shared.list` (`modemmanager`/`libqmi-utils`/`libmbim-utils`
  stay in `shared.list` to resolve that dependency tree; the fork wins on-device via
  the `Package: *` origin-990 pin). `mobile-broadband-provider-info` (ModemManager's
  APN database, a `Recommends:`) is an explicit `shared.list` entry. Debian hosts use isolated `apt-get download`;
  non-Debian hosts use a curl fallback that verifies `InRelease` with `gpgv`,
  checks the `Packages.gz` SHA256 from that signed metadata, then downloads the
  exact package files. Every verified `.deb` is normalized to mode `0644` before
  its atomic staging rename, then copied into explicit mode-`0755` mkosi consumer
  directories as mode `0644` so a restrictive runner umask cannot hide packages
  from mkosi's unprivileged local-repository helper. Containerized builds expose
  only those two consumer leaves through read-only bind mounts; mkosi never has
  to traverse the intentionally mode-`0700` persistent-runner checkout or staging
  ancestors. The platform postinstall is deliberately non-chrooted so mkosi
  exposes its `mkosi-install` wrapper; raw `apt-get` bypasses mkosi's ephemeral
  `file:/repository` package-list state and is forbidden for this path. Mode,
  mount, rename, or local-repository consumption failures fail closed and clean
  private package-temporary artifacts, while package payload modes are
  unaffected. These are Debian **Package** names — a
  deliberate mapping off `REPOS` (the directory/pin names), notably
  `srt → libsrt1.5-ceralive`, `CeraUI → ceralive-device`, and
  `gstlibuvch264src → gstreamer1.0-libuvch264src`.
- **`srt` provides the device SRT runtime.** Its `libsrt1.5-ceralive` package
  replaces Debian's GnuTLS/OpenSSL variants, so GStreamer and cerastream resolve
  one forked `libsrt.so.1.5` implementation. The
  `gstlibuvch264src` stays out of `REPOS`, but its Debian binary
  `gstreamer1.0-libuvch264src` is staged so the app layer can install all
  first-party packages from local `.deb`s with no downloads; `libgstreamer*`
  plugins, including the explicit `gstreamer1.0-alsa` ALSA source plugin (RØDE/ALSA
  capture + always-on audio meter) and `gstreamer1.0-nice` (libnice — the `nicesrc`
  ICE plugin the cerastream WebRTC remote-preview tier requires), come
  from the runtime OS layer (`shared.list`). When that app
  layer installs `ceralive-device`, it explicitly enables `ceralive.service`;
  the runtime layer runs earlier and cannot enable a unit supplied later by the
  CeraUI package.
- **Secrets are env-only, base64-encoded** (same names as the device customize
  script): `APT_GPG_PUBLIC_B64`, `APT_CLIENT_CRT_B64`, `APT_CLIENT_KEY_B64`. They
  are NEVER hardcoded, NEVER logged, NEVER committed; a half-supplied mTLS pair is
  fatal. `APT_GPG_PUBLIC_B64` may encode either the current armored `.asc` public
  key or a binary `.gpg` keyring: `v2/lib/dearmor-apt-keyring.sh` normalizes it
  and checks binary OpenPGP `file(1)` magic in the native/container build context
  before mkosi starts. The runtime postinstall receives only that validated binary
  payload; do not add `gpg` or `file` to the device package set. `APT_CERALIVE_URL`
  (default `https://apt.ceralive.tv`) is overridable.
- **The build-time fetch keeps apt's sandbox, and it is PRIVILEGE-AWARE.** apt
  drops its acquire methods to `_apt` whenever it is invoked as root, so this
  path used to carry an `APT::Sandbox::User=root` override — the same "fix" the
  device-side KEY FACT below forbids, and for the same reason: it disables the
  sandbox rather than repairing a permission. It is gone, and the fetcher now
  branches on whether apt will actually drop privileges. As root with `_apt`
  present it hands `_apt` the mTLS client key (`chown _apt:root` + `chmod 400`,
  mirroring the device mechanism) and gives the isolated apt state tree explicit
  traversable modes; unprivileged it emits nothing at all, because apt keeps the
  invoking user's credentials — orchestrate.sh runs the fetcher on the HOST
  before any container, so unprivileged is the common case. A host with no `_apt`
  at all is non-Debian and already on the curl fallback. **Traversal alone is not
  enough for the download directory**: apt WRITES the `.deb` there as `_apt`, so
  the `mktemp -d` (mode 0700, root-owned) is chowned to `_apt` the way apt chowns
  its own `partial/` dirs — a mode-0755 root-owned download dir still degrades to
  `Download is performed unsandboxed as root`. Guard:
  `v2/tests/fetch-debs-apt-sandbox.test.sh`, which drives the shipped
  `fetch_first_party` with a REAL apt-get against a real GPG-signed fixture
  repository in a container at real UID 0 and unprivileged, asserts the absence
  of that warning under a 0077 umask, and carries a control replay proving the
  assertion is not vacuous.
- **Arch axis only** — the source carries no board axis; `arch` is selected by
  `APT::Architecture` (apt-worker two-axis model: `channel × arch`). Resolved
  mkosi `x86-64` is normalized to Debian `amd64`; RK3588 remains `arm64`.
- **DRY_RUN** logs the exact version-qualified `apt-get … download` plan + source
  and downloads nothing. With no `APT_GPG_PUBLIC_B64` in the env the fetcher
  auto-enables DRY_RUN (no credential for a verified fetch).
- **BSP fetch is authenticated** — kernel/DTB/U-Boot/firmware/GStreamer come
  from signed Armbian metadata, with the exact archive-key fingerprint set and
  all content hashes checked before staging. Family manifests select package
  names; `v2/manifests/armbian-bsp-deb-versions.txt` supplies the exact Debian
  versions. Both native apt and curl fetches re-verify the downloaded InRelease
  with `gpgv`, require signatures from both pinned archive keys, and validate the
  signed suite/component/architecture identity before any package download. The
  curl path parses only that verified Release plaintext and preflights every
  exact spec. The
  current transition set is the
  historical `DF00FAF1C577104B50BF1D0093D6889F9F0E78D5` key plus repository key
  `8CFA83D13EB2181EEF5843E41EB30FAF236099FE`; missing or additional primary keys,
  unusable primary/subkey states, and keyring parsing or normalization failures
  fail before apt runs. Source pins and the stdin-only secret rotation procedure
  are in [`docs/RELEASE-PROCESS.md`](docs/RELEASE-PROCESS.md) §4.
- **Non-Armbian package staging is fail-closed** — a family with
  `armbian_branch: none` emits no Armbian fetch in DRY_RUN and a real `fetch_bsp`
  invocation fails until an authenticated, exact-versioned Debian BSP source is
  implemented. The x86 disk/boot assembly exists, but its production Debian
  kernel/firmware staging path remains [GREENFIELD]; Armbian must not be used as
  an accidental substitute.

**Exact BSP package pins + advisory kernel content drift-guard** [EXISTS]

Decision D3 still selects the vendor branch through package names such as
`linux-image-vendor-rk35xx`; exact Debian versions for every required BSP package
are committed in `v2/manifests/armbian-bsp-deb-versions.txt`. `fetch_bsp`
authenticates the exact Armbian archive-key fingerprint set, verifies `InRelease`
and its configured suite/`main`/architecture identity, verifies the `Packages.gz`
digest from signed metadata, preflights the complete exact package set, and
verifies every staged package SHA-256. `Architecture: all` is compatible with a
target architecture; a stale version, wrong suite/architecture, ambiguous record,
or partial package set fails closed without fallback. It also makes an upstream
same-version content replacement observable:

- **Provenance capture** — after the real BSP fetch, `bsp_capture_provenance`
  records the kernel package's exact resolved **version string** + **content
  `sha256`** into `bsp-provenance.json` in the image output dir (`$DEST`). Scope is
  the **kernel BSP package only** — provenance is deliberately not widened to the
  rest of the BSP set. The artifact is **gitignored, never committed**, and
  deliberately **excluded from the build-matrix `sha256` determinism comparison**
  (that job hashes the normalized build-plan string, never a file tree).
- **Drift-guard (warn-default, strict opt-in, C6b)** — `bsp_drift_check` compares
  the captured version+hash against the committed baseline
  `v2/manifests/bsp-baseline.json`. On a mismatch it prints a `BSP drift` banner to
  stdout. Exit policy is **opt-in**: by DEFAULT (`BSP_DRIFT_STRICT` unset/≠1) it
  **exits 0 — drift is warn-only, never fatal** (build continues, the historical
  byte-for-byte path). With **`BSP_DRIFT_STRICT=1`** a real mismatch against a
  SEEDED baseline **exits non-zero, failing the build** (the seeding run + a clean
  match stay exit 0 regardless — a fresh baseline can never fail a strict build). It
  compares the **content hash, not just the version**, so a same-version re-spin is
  still caught. **Promotion criterion:** flipping the default to strict is a FUTURE
  change gated on (1) the baseline seeded with a real known-good version+sha256 AND
  (2) a fleet manifest run clean of drift — see
  [`v2/docs/kernel-currency-watch.md`](v2/docs/kernel-currency-watch.md).
- **First-run / seeded baseline** — a new scaffold may start with `version` and
  `sha256` as `null`; the first authenticated real build seeds the baseline with
  the actual values, emits an informational note, and exits 0. Commit that seeded
  value to set the known-good content reference. Exact package selection remains
  governed by `armbian-bsp-deb-versions.txt`. Proof:
  `v2/run-tests` section 15.
- **DRY_RUN stages no `.deb`**, so provenance capture is skipped under DRY_RUN — the
  CI build-matrix (DRY_RUN=1) never writes the artifact.

**Kernel build from source — OPT-IN family variants, production path byte-identical** [PARTIAL]

The family manifest gained a `variants:` map: named, **explicitly opt-in** overlays
on the family defaults, applied only via `v2/build <board> --variant <name>` (or
`CERALIVE_KERNEL_VARIANT`). Resolver merge order is **family → variant → board**
(board still wins last, so board facts stay authoritative). `default` is the
reserved no-overlay name and the schema refuses a variant literally called that.

rk3588 ships **two** variants, both building the kernel + in-tree DTBs **from
pinned source** by `git am` + `make bindeb-pkg` inside a **digest-pinned** builder
container with a persistent ccache. They target DIFFERENT kernel tracks with
DIFFERENT patch repos, and neither repo's patches apply to the other's tree:

| Variant | Track | Source pin | Patch repo | Purpose |
|---|---|---|---|---|
| `edge` | mainline 7.1 | `v7.1.7` / `c7ba9d6de43e` | `CERALIVE/rk3588-kernel-patches@acb519c101fe` | mainline option kept pinned + buildable |
| `vendor-patched` | **vendor 6.1 BSP — what the image actually runs** | `rk-6.1-rkr5.1` @ `95e85f6cb496` (**no tag**) | `CERALIVE/rk3588-vendor-kernel-patches@de46c1acba42` | restores HDMI-RX audio capture + diagnostic instrumentation |

Both patch commits are **immutable SHAs**, never branches. Full write-up:
[`v2/docs/kernel-build-from-source.md`](v2/docs/kernel-build-from-source.md).

**`vendor-patched` is the answer to "is the vendor patch repo wired in yet?" — it
is, as of this variant.** It rebuilds the SAME 6.1.115 BSP the production path
installs prebuilt, plus five patches, fixing the board-confirmed regression where
`armbian/linux-rockchip` `78c67d98f221` (PR #430) unconditionally zeroed
`hdmi-audio-codec` capture channels for every instance — a fix for RK3576
HDMI-**TX** that killed RK3588 HDMI-**RX**, because `rk_hdmirx` registers through
that same codec. Build it with
`./v2/build rock-5b-plus --variant vendor-patched`; it produces
`linux-image-6.1.115-ceralive-vendor-rk35xx` = `6.1.115-ceralive1`. **The package
name is deliberately NOT `linux-image-vendor-rk35xx`** — a collision with the
stock name is the one failure that yields a plausible image rather than an error,
because the local repository would resolve one of the two by version and the board
could silently boot the UNPATCHED kernel.

**`0004` is DIAGNOSTIC and `0005` is the fix it found — and NEITHER has been
confirmed on a board.** `0001`-`0003` restored the capture PCM and that half is
board-confirmed, but every `read()` on it still returned `EIO` while `dmesg` —
cleared immediately beforehand — stayed completely empty, including against an
EDID-confirmed audio-capable HDMI source. `0004` changes no behaviour; it raises
the severity of, and adds state to, the failure reports that path already drops
(ALSA's only `-EIO` is at `pcm_dbg()` level, the dmaengine PCM pointer discards
its status, the i2s-tdm overrun interrupt is optional and its absence unlogged,
and a PL330 channel fault is `dev_info()`). What it exposed is that the PCM
lifecycle and the HDMI-RX **audio-domain** lifecycle were never connected:
`GLOBAL_SWENABLE.AUDIO_ENABLE` and `AUDIO_PROC_CONFIG0.I2S_EN` are set ONLY by
`hdmirx_delayed_work_audio()`, whose only triggers are a one-shot deframer IRQ
and an `rk_hdmirx` private V4L2 ioctl no ALSA client issues — so `snd_pcm_open()`
/ `hw_params` / `trigger START` all left the domain off and nothing clocked into
i2s7_8ch. `0005` starts that domain from the capture open and from the paths that
just confirmed HDMI lock. Do NOT read this variant as "HDMI-RX audio works" — it
is instrumented and repaired in source, not proven on hardware. `0004` is
retained in full until `0005` is board-confirmed (`hw_ptr` advancing, `RXS=1`
with a NON-ZERO `RXFIFOLR`, and zero `capture xfer failed` lines); shrinking the
series back to three patches is a follow-up, not pending cleanup.

**`0005` may never wait on the audio WORK ITEM, only on its completion.** Its
first version (`94d20ab0a4f7`) called `flush_delayed_work()` from
`hdmirx_audio_startup()`, which ASoC invokes with hdmi-codec's `hcp->lock` held,
while that work calls back into `plugged_cb()`, which takes the same lock. That
deadlock fires ONLY when the fix works — the no-audio path never reaches
`plugged_cb()`, so a source without audio looked fine and a source with audio
hung the capture open in D state. The shipped pin (`de46c1acba42`) waits on a
`completion` the work signals BEFORE that callback, and disarms the work under a
gate before a synchronous cancel on every teardown path. The statement order
there is load-bearing; do not "simplify" it back to a flush.

**Pin hygiene — a squash-merge in the patches repo ORPHANS the SHA pinned here.**
`db5d0e8a0711` was the predecessor pin and the tip of the 3-commit branch that
became `CERALIVE/rk3588-vendor-kernel-patches` PR #1. Squash-merging it produced a
brand-new commit (`de46c1acba42`) and discarded the originals, so `db5d0e8a0711`
is no longer reachable from that repo's `main` and
`git fetch --depth 1 <url> db5d0e8a0711` from a fresh clone FAILS. The PR gate
cannot catch this — it is `DRY_RUN=1` and never fetches the patch series. After
merging anything in either patch repo, re-pin `patches_commit` to the SHA that
actually landed on `main`, and verify it with
`git ls-remote <patches-url> <sha>` before committing.

**Adding it required generalizing `build-kernel.sh` in exactly two places**, both
of which are now first-class modes rather than special cases:

- **Commit-only source checkout (`tag` is now OPTIONAL).** `rk-6.1-rkr5.1` is a
  rolling BSP branch that publishes **no tags at all**, so there is no ref to
  clone. When `tag` is absent the build does `git init` + `git fetch --depth 1
  <url> <commit>` + `git checkout FETCH_HEAD` and asserts `HEAD == commit` — the
  same guarantee the tagged path gets from its own assertion. **Do NOT invent a
  synthetic tag** to make it look like `edge` (false provenance) and do NOT clone
  the branch tip (silently builds newer source under an unchanged pin).
- **Config-file mode (`config_git_url` + `config_commit` + `config_path`).** The
  vendor kernel has no usable defconfig story: Armbian publishes a COMPLETE 2,753-
  symbol `.config` (`config/kernel/linux-rk35xx-vendor.config`) that IS the config
  the fleet runs. The build fetches that exact file at a pinned `armbian/build`
  revision and uses it verbatim as the starting `.config`. **Do NOT substitute
  `make defconfig`** — it produces a materially different driver/feature set, so
  the resulting kernel would not be comparable to what the board runs, which
  removes the entire point of a vendor-track source build. The schema's `oneOf`
  enforces exactly one config mode; `build-kernel.sh` re-asserts it, because a
  half-specified config is the one mistake that would still BUILD.

Both modes converge on ONE `olddefconfig` → `syncconfig` → `verify-kernel-config.sh`
sequence. Keep it that way: `manifest.bats` statically requires exactly one
occurrence of each of those `make` calls in the file.

- **The production vendor path is BYTE-IDENTICAL.** `variants:` is stripped from
  the family before flattening whether or not one is selected, so a family that
  declares a variant resolves exactly like one that never did. Pinned by committed
  golden fixtures (`v2/tests/manifests/fixtures/vendor-baseline/*.params`, captured
  pre-change) for all three shipped boards, plus an explicit **non-vacuity** leg
  proving the same comparison fails on the `edge` resolve.
- **The Armbian framework is NOT the build system.** It is consulted for the
  `edge` → 7.1 mapping only (upstream, in the patches repo's preflight) and never
  invoked. Adopting it would import its patch stack, config and packaging and make
  "what is in this kernel" unanswerable from this repo.
- **Output contract:** exactly ONE `linux-image-*` deb carrying the kernel AND the
  in-tree DTBs; `linux-headers-*`/`linux-libc-dev` are discarded before staging.
  The built deb is validated against the manifest on four axes — control
  `Package:`/`Version:`/`Architecture:` and the presence of the board's own DTB at
  `kernel_source.dtb_deb_dir`.
- **Three integration semantics, active only under a `kernel_source:` variant:**
  (i) remote fetch of the manifest-named kernel/DTB packages is SUPPRESSED
  (`CERALIVE_KERNEL_SOURCE_SUPPRESSED_PKGS` → `collect_declared_bsp_pkgs`;
  **U-Boot and firmware stay prebuilt-fetched**); (ii) the built package names
  REPLACE `kernel_packages`/`dtb_packages` via the ordinary variant merge;
  (iii) a **staged-package uniqueness check** fails the build if any name has BOTH
  a fetched and a built candidate — suppression should make that impossible, this
  proves it did. Stage order: `[2/9] fetch` → `[2b/9] kernel build` → uniqueness →
  `[3/9] partition`.
- **The suppression list is DERIVED, never authored** (pre-overlay family names ∪
  post-merge names). The schema rejects a manifest that declares it, because a
  hand-written list would drift from the replacement list.
- **DTB install mapping:** `bindeb-pkg` puts arm64 DTBs under
  `/usr/lib/linux-image-<REL>/rockchip/`, but the U-Boot script resolves
  `/boot/dtb/rockchip/${fdtfile}`. `platform/mkosi.postinst::install_kernel_source_dtbs`
  copies source → target. Both paths are EMPTY on the vendor path, so the step is a
  strict no-op there; fail-loud when enabled.
- **`/boot` artifact mapping — the DTB copy was NOT enough, and the gap crash-looped
  a board.** The selector's FIRST load is `/boot/Image`, and on the vendor path that
  file exists only because Armbian's `linux-image-vendor-rk35xx` **postinst** runs
  `ln -sfv vmlinuz-<REL> /boot/Image`; the same postinst's
  `run-parts /etc/kernel/postinst.d` emits `initrd.img-<REL>` only because that
  package `Depends: initramfs-tools`. `make bindeb-pkg` does NEITHER — its generated
  postinst creates no `Image` and declares no initramfs dependency, so replacing the
  vendor kernel package also drops `initramfs-tools` from the closure, leaving
  `/etc/kernel/postinst.d` EMPTY and the `run-parts` a no-op. A real `edge` bench
  image therefore shipped a `/boot` holding `vmlinuz-7.1.5-ceralive-rk3588` and
  nothing else; on hardware: `Failed to load '/boot/Image'` → `booti` into unloaded
  DRAM → `"Synchronous Abort"` → reset, forever.
  `platform/mkosi.postinst::install_kernel_source_boot_artifacts` replicates the
  vendor behaviour, and the platform layer installs `initramfs-tools` in its **own
  transaction before** the kernel package — ordering is the mechanism, because the
  hook must be configured when the kernel postinst run-parts. Gated on
  `KERNEL_SOURCE_KERNEL_RELEASE` (empty on the vendor path ⇒ strict no-op), which
  rides the `env_names` ↔ `PassEnvironment=` lockstep. The **DTB layout is
  deliberately NOT made vendor-identical**: vendor ships `/boot/dtb-<REL>/` plus a
  `/boot/dtb` symlink, this path makes `/boot/dtb` a real dir, and U-Boot resolves
  `/boot/dtb/rockchip/${fdtfile}` either way — proven by the very boot that failed,
  which still read the DTB (`106449 bytes read`) off exactly this layout.
  Full write-up: [`v2/docs/kernel-build-from-source.md`](v2/docs/kernel-build-from-source.md) §4b.
- **`/boot/Image` must also be the RAW Image — `bindeb-pkg` ships `Image.gz`, and
  only ONE of the two boards' U-Boot can cope.** Making the file exist (above) did
  not make it loadable. On a real Orange Pi 5 Plus the selector ran the whole A/B
  sequence cleanly, loaded 15,928,530 bytes of `/boot/Image` and the DTB, and then
  `booti` answered `Bad Linux ARM64 Image magic!`; `md.b 0x00400000 0x40` after a
  hand `ext4load` read `1f 8b 08 00 …` — gzip, deflate. `arch/arm64/Makefile` sets
  `KBUILD_IMAGE := $(boot)/Image.gz` and `scripts/package/builddeb` installs
  `$(make -s image_name)` as `/boot/vmlinuz-<REL>`, so on arm64 **every**
  `bindeb-pkg` kernel — `edge` AND `vendor-patched` — ships a COMPRESSED vmlinuz.
  Armbian's vendor package escapes it only because its framework builds rockchip64
  with `KERNEL_IMAGE_TYPE="Image"`. **The ambiguity this raised is resolved, and it
  is a per-board U-Boot fact, not a per-build artifact difference** — both boards'
  `edge` builds emit the same `Image.gz` (the Rock 5B+ build log says
  `GZIP arch/arm64/boot/Image.gz` in one line), but their staged
  `u-boot-config-target-1` files (both `26.5.1`, SHA-256-verified against todo 44's
  own component manifest) disagree: `rock-5b-plus` ships U-Boot **2026.04** with
  `CONFIG_GZIP=y` / `CONFIG_ZLIB=y` / `CONFIG_CMD_UNZIP=y`, while
  `orange-pi-5-plus` ships the Rockchip **2017.09** fork in which `CONFIG_GZIP`
  does not exist as a symbol at all (`CONFIG_CMD_UNZIP` is `not set`,
  `CONFIG_IMAGE_GZIP` is `not set`). Modern U-Boot's `booti_start()`
  (`cmd/booti.c`) sniffs the compression and runs `image_decomp()` before
  `booti_setup()`; 2017.09 predates that entirely — which is why the SAME kernel
  package booted a Rock 5B+ to userspace and hid this for a release, and why the
  Orange Pi console answers `unzip` with `Unknown command` and has no interactive
  workaround. Same lesson as `setexpr` and `loadaddr`, third instance: **never let
  an artifact contract rest on a board's U-Boot happening to cope.**
  `install_kernel_source_boot_artifacts` now reads the first bytes of
  `vmlinuz-<REL>` and, on gzip, `gzip -dc`s it into `/boot/Image` as a **REAL
  FILE** — a symlink to the still-compressed vmlinuz is the bug, not the fix. An
  already-raw Image keeps the vendor-parity symlink; any other recognised
  container (xz/zstd/bzip2/lz4/lzop/lzma) is FATAL and NAMED, because guessing
  there ships an unbootable slot on every board. It then asserts the magic
  `0x644d5241` (`"ARM\x64"`, little-endian) at **offset 56** of the 64-byte header
  (`Documentation/arm64/booting.rst` §4) on whatever it produced — a `gzip -dc`
  that SUCCEEDS on the wrong payload is still an unbootable slot, so the checked
  property is the resulting magic, never the exit status of the decompressor.
  `verify-boot-artifacts.sh` re-asserts the same magic at `[6b/9]` on the real
  emitted rootfs tar and names the compression it found, so the failure reads as a
  packaging fact rather than a bootloader mystery. The packaged `vmlinuz-<REL>` is
  left exactly as `dpkg` installed it; only `/boot/Image` is materialised, at the
  cost of one extra decompressed kernel in `/boot`. **Invisible to the PR gate**
  like every finding in this class — `DRY_RUN=1` never runs `[6b/9]` — and
  invisible to the previous `[6b/9]` too, which read `tar -tv` metadata only and
  so could see the symlink, its target and its size but never a byte of content.
  Guards: `v2/tests/boot-artifacts.bats` (9 added cases). Full write-up:
  [`v2/docs/kernel-build-from-source.md`](v2/docs/kernel-build-from-source.md) §4c.
- **BOTH RK3588 boards COMPILE end to end; ONE of them has now BOOTED.** A real
  (non-`DRY_RUN`) `v2/build <board> --variant edge` produces
  `linux-image-7.1.7-ceralive-rk3588` (228 `rockchip/*.dtb`), passes all four
  `validate_built_kernel_deb` axes, installs the board DTB to
  `/boot/dtb/rockchip/`, installs all 14 first-party `.deb`s, clears the `[7/9]`
  parity gate and emits a flashable `.raw` + signed `.raucb` — proven on
  `rock-5b-plus` first, and on `orange-pi-5-plus` once the DTB-name override and
  the first-party staging key below were both fixed. A Rock 5B+ has since been
  flashed with a `v7.1.7` edge image and booted `7.1.7-ceralive-rk3588`, which is
  what cleared the MPP KNOWN ISSUE below. `orange-pi-5-plus` has still never
  booted an edge image, so the fragment remains reviewed intent on that board.
  `v2/docs/DEFERRED.md` item 9.
- **A board fact that differs per variant is declared BY THE BOARD, in
  `variant_overrides:`.** The merge order is family → variant → board and the board
  wins last, so a variant can never restate a board fact — which is also why a
  variant could not fix the one thing that legitimately differs per variant AND per
  board: the DTB filename, which comes from whichever kernel tree built it.
  `orange-pi-5-plus.yaml` therefore carries
  `variant_overrides.edge.dtb_name: rk3588-orangepi-5-plus.dtb`. The override is
  applied AFTER
  the board merge — board-wins-last is strengthened, not weakened — is stripped
  before flattening whether or not a variant is selected (so the vendor path stays
  byte-identical, pinned by the same `vendor-baseline/*.params` fixtures), permits
  ONLY `dtb_name`, and is FATAL when it names a variant the family does not
  declare. `rock-5b-plus` needs none: mainline and vendor agree on its spelling.
  With this, a real `v2/build orange-pi-5-plus --variant edge` compiles and passes
  all four validation axes. Full write-up:
  [`v2/docs/kernel-build-from-source.md`](v2/docs/kernel-build-from-source.md) §8.
- **CORRECTION (2026-08-02) — the vendor BSP does NOT ship an `rk3588s-` spelling
  for the Orange Pi 5+, and never did.** The KEY FACT above previously read
  "mainline spells it without the `s`; the vendor BSP ships `rk3588s-`". That
  premise was wrong, and it was the board's DEFAULT `dtb_name` — the production,
  vendor-kernel path — that carried the bad value from the manifest's very first
  commit. `linux-dtb-vendor-rk35xx` 26.5.1 contains `rk3588-orangepi-5-plus.dtb`
  and NO `rk3588s-orangepi-5-plus.dtb`, and that holds for every version in the
  Armbian archive back to 24.5.1, so this is a manifest error rather than archive
  drift (and the BSP drift-guard, whose subject is the KERNEL package's
  version+hash, was correctly silent — nothing upstream changed). Armbian's own
  `config/boards/orangepi5-plus.conf` agrees: `BOOT_SOC="rk3588"`,
  `BOOT_FDT_FILE="rockchip/rk3588-orangepi-5-plus.dtb"`. The `rk3588s-` prefix
  belongs to the genuinely-RK3588S parts (OPi 5 / 5B / 5 Pro), which the same
  package ships separately — the "5 Plus (RK3588S)" board name is the trap. The
  production `dtb_name` is now `rk3588-orangepi-5-plus.dtb`; a real
  `./v2/build orange-pi-5-plus` clears `[6b/9]` and emits `.raw` + `.raucb`. PR
  #84's `variant_overrides.edge.dtb_name` was and is correct — it is retained as
  an explicit per-tree assertion rather than deleted as redundant. **This class of
  defect is invisible to the PR gate**, which is `DRY_RUN=1` plan-only and never
  runs `[6b/9]`, so the static guards in `manifest.bats §26` pin both boards'
  resolved `DTB_NAME` on both kernel paths and forbid an `rk3588s-` prefix on
  either shipped RK3588 board.
- **The first-party staging key is `CERALIVE_BOARD` (the board manifest stem),
  NOT `BOARD_ID` — and the source-mount fallback is the ONLY live delivery
  route.** mkosi's CLI `--extra-tree …:/opt/ceralive-staging` does not reach the
  `app` subimage (the same subimage-isolation trap as `PassEnvironment=`), so on
  every board the 14 first-party `.deb`s are actually delivered by the fallback
  `stage_first_party_from_source_mount` in `app/mkosi.postinst.chroot`. It
  rebuilds the orchestrator's staging path from inside its chroot, so producer
  and consumer must agree on the key. They did not: the consumer read
  `${SRCDIR}/.staging/${BOARD_ID}/firstparty` while `orchestrate.sh` stages into
  `.staging/<board-manifest-stem>/`, and those coincide only on `rock-5b-plus`
  (`board_id: rock-5b-plus`). On `orange-pi-5-plus` (`board_id: orangepi5-plus`)
  the path did not exist, the function returned silently, ZERO first-party
  packages installed, and the build ran to `[7/9]` before failing with
  `first-party packages MISSING from rootfs` — board-specific, variant-independent
  and identical on the vendor path. **FIXED:** `orchestrate.sh` now exports the
  stem as `CERALIVE_BOARD` right where it computes the staging dir (`env_names`
  + `mkosi.conf` `PassEnvironment=`, per the subimage env-propagation contract
  below) and the consumer keys off that. The stem is used rather than `BOARD_ID`
  because it is unique by construction and is the same key `acquire_board_lock()`
  serialises on — keying a tree that gets `rm -rf`'d on the Armbian `BOARD=` value
  would let two manifests sharing a `board_id` clobber each other under different
  locks. `cache/${BOARD_ID}` is a DIFFERENT tree for a different purpose and is
  deliberately not aliased onto this. A miss now LOGS the probed path instead of
  returning silently. Guards: `manifest.bats` §27 (7 tests, incl. the real shipped
  stager driven against every shipped manifest with its real `board_id`, and the
  inverse leg proving a `BOARD_ID`-keyed tree is NOT picked up).
- **The `DRY_RUN` PR gate cannot see this stage — so every fix needs a STATIC
  guard.** The first real build hit four independent, board-independent, fatal
  defects that a plan-only gate had passed for a whole release: `make kernelrelease`
  reading a stale `include/config/auto.conf` (fixed by an explicit `make syncconfig`
  after `olddefconfig` — `kernelrelease` is in the kernel's `no-sync-config-targets`,
  so it never syncs it itself); two missing cross build-deps in `Dockerfile.kernel`
  (`libdw-dev`, plus arm64-multiarch `libssl-dev:arm64` and `libc6-dev:arm64` —
  `install-extmod-build` rebuilds the headers package host tools with the CROSS gcc);
  a constant builder-image tag that made `ensure_kernel_builder_image`'s
  already-present short-circuit permanent (now content-addressed over the Dockerfile
  + `builder_image` pin); and a `deb_lists_path` that reported EVERY present path as
  absent because `grep -q` closed the pipe, `tar` died of `SIGPIPE`, and
  `set -o pipefail` turned that into failure. **An empty "DTBs actually present"
  list in that error means the listing is broken, not that the DTB is missing.**
- **The `edge` `.deb` is NOT byte-reproducible** — `git am` restamps committer dates,
  so post-`am` SHAs differ per run. Content is stable (two builds agreed on package
  versions, rootfs file lists and `/boot/config-*`); archive bytes are not. This is
  precisely why `CONFIG_LOCALVERSION_AUTO=n` plus the exact `kernelrelease` assertion
  matter — without them the package NAME inherits that nondeterminism.
- **D3 is NOT reopened.** The shipped kernel is still the Armbian vendor BSP; this
  is the mainline-track option kept pinned and buildable. See
  `v2/docs/kernel-currency-watch.md`.

- **The three pinned fetches retry into ATTEMPT-PRIVATE dirs, and a PIN MISMATCH
  is never one of the retries.** `build-kernel.sh` performs three network fetches
  back to back (kernel source, patch series, kernel config); a blip on any of
  them used to abort a build that had already paid for the builder image, the
  container and a multi-minute checkout. All three now go through
  `fetch_pinned_tree`: up to 3 attempts, each wrapped in `timeout(1)` (1800s
  default — a git that has stopped making progress does not exit on its own),
  linear backoff. **The load-bearing half is that each attempt's directory is
  destroyed BEFORE the attempt, not merely after it fails** — a tree half-written
  by a killed clone makes attempt 2 fail deterministically with `destination path
  already exists` (or a stale `.git/index.lock` on the fetch shape), so one blip
  presents as a total outage and every manual re-run fails identically. The
  `HEAD == commit` assertion runs **after** the loop and fails immediately: a
  moved tag or a squash-merge-orphaned SHA is PERMANENT, and retrying it
  re-fetches the same wrong tree three times before reporting a *network*
  problem. Only a pin-verified tree is renamed into the path the build reads.
  Knobs: `CERALIVE_KERNEL_GIT_{ATTEMPTS,TIMEOUT,BACKOFF}`. The helper is defined
  host-side and **injected** into the container script with `declare -f`, so the
  shipped loop is the same text the tests drive against a stubbed `git`.
- **`make -j` is DERIVED from memory, not from `nproc`.** A kernel compile job
  peaks around 1-2 GiB RSS, so `-j$(nproc)` on a core-rich, memory-thin host does
  not build slowly — it gets OOM-killed deep inside `bindeb-pkg`, after every pin
  has already verified. The width is `min(nproc, MemAvailable / 2 GiB)`, floor 1,
  ceiling `nproc`, logged on every run. `CERALIVE_KERNEL_BUILD_JOBS` overrides it
  **unconditionally, including upward**; `CERALIVE_RESOURCE_MEMINFO_FILE` (the
  same knob `ci/check-builder-resources.sh` uses) redirects the meminfo read.
  Both of these are **invisible to the PR gate** like everything else in `[2b/9]`
  — it is `DRY_RUN=1` and never fetches or compiles. Guards:
  `v2/tests/kernel-build-resilience.bats` (30 tests, mutation-verified: removing
  the pre-attempt `rm -rf`, folding the pin check into the retry condition,
  publishing before verifying, dropping the final-attempt cleanup, and dropping
  the memory ceiling each fail the suite). Write-up:
  [`v2/docs/kernel-build-from-source.md`](v2/docs/kernel-build-from-source.md) §3b.

Guards: `manifest.bats` §26 (67 tests) + `kernel-build-resilience.bats` (30 tests).

**A Kconfig fragment SYMBOL is not a Kconfig fragment RESULT — `merge_config.sh -m`
will not tell you the difference** [EXISTS]

`scripts/kconfig/merge_config.sh -m` merges TEXT and reports only symbols the
fragment REDEFINES. It says nothing about a symbol the following
`make olddefconfig` DROPS for an unmet visibility condition — and `-m` is exactly
the flag that skips merge_config's own post-merge validation pass. So a fragment
line can vanish in total silence: the build succeeds, `validate_built_kernel_deb`
passes all four axes, `/boot` is complete, the image boots, and the driver is
simply not there.

Confirmed on a live Rock 5B+ running the `edge` 7.1.5 kernel: the RTL8852BE WiFi
enumerated at PCI level (`0x10ec`/`0xb852`, class `0x028000`) with **no driver
bound, no `wl*` interface, and zero `rtw89*` modules under
`/lib/modules/7.1.5-ceralive-rk3588`** — while `/lib/firmware/rtw89/rtw8852b_fw.bin`
(from `armbian-firmware`) was present and `cfg80211` was loaded. `/proc/config.gz`
read `# CONFIG_RTW89 is not set`. The fragment DID name the adapter
(`CONFIG_RTW89_8852BE=m`) but not the `menuconfig RTW89` that gates the family —
a tristate, `depends on MAC80211`, defaulting off — so the leaf was invisible and
discarded. Three releases of build logs said nothing.

`v2/lib/verify-kernel-config.sh` closes it, running **inside the builder container
right after `make syncconfig` and before `bindeb-pkg`** (mounted read-only at
`/in/verify-kernel-config.sh`), asserting every declared symbol against the
RESOLVED `.config`: `=y`/`=m`/`="str"` must match verbatim, `=n` and
`# … is not set` must resolve to not-set (absent counts). Value matching is EXACT
on purpose, and that is what caught the second instance nobody was looking for —
`CONFIG_TYPEC_FUSB302=y` had been resolving to `=m` for three releases because
FUSB302 carries `depends on DRM || DRM=n` and arm64 defconfig builds DRM as a
module. The board proved `=m` is fine (`/sys/class/typec/port0` exists,
`port_type` reads `dual [source] sink`, `fusb302` in `lsmod`) because udev
auto-loads it off the OF modalias and `ceralive-typec-source.service` POLLS for
the port to a deadline — so the fragment now declares the honest `=m`. **Do NOT
"fix" that one by setting `CONFIG_DRM=y`.**

When the gate fires, do NOT silence it by deleting the line: read the symbol's
Kconfig entry, find the `menuconfig` block it sits inside and its `depends on`,
and declare those too. A `select`ed helper (`RTW89_CORE`/`RTW89_PCI`/`RTW89_8852B`)
needs no entry; a `menuconfig` parent always does. Guards:
`v2/tests/kernel-config-fragment.bats` (26 tests, incl. a red/green pair driving
the REAL fragment against a reproduction of the broken 7.1.5 answer). Full
write-up: `v2/docs/kernel-build-from-source.md` §6b.

**A `.link` `Path=` captured on the vendor BSP does NOT match on mainline — the
platform-device name moves, and the rename silently stops** [EXISTS]

`install_interface_naming()` wrote `Path=` with the board manifest's ID_PATH
verbatim. An ID_PATH for a PCIe NIC is
`platform-<controller>-pci-<domain:bus:device.function>`, and `<controller>` is
the **platform device** name, which Linux derives from the **first `reg` entry**
of the DT node. The vendor BSP DTS lists the APB window first (`fe190000.pcie`);
mainline lists the ECAM window first (`a41000000.pcie`). Same silicon, same slot,
different name — so the manifest values, captured on a vendor board, matched
NOTHING on the `edge` kernel. Confirmed live on a Rock 5B+ running 7.1.5: the
`.link` files were present and correct, and yet

```
ID_PATH=platform-a41000000.pcie-pci-0004:41:00.0   # manifest says fe190000
udevadm test-builtin net_setup_link /sys/class/net/enP4p65s0
  -> ID_NET_LINK_FILE=/usr/lib/systemd/network/99-default.link   # ours never matched
ip -o link show -> lo, enP4p65s0                   # never became eth0
```

Not cosmetic: SRTLA's link discovery globs `eth*`/`wlan*`, so the wired uplink
silently dropped out of bonding on every edge image. `systemd.link(5)` `Path=`
takes a **whitespace-separated list of globs**, so `link_path_match()` now emits
the literal manifest value AND a controller-agnostic
`platform-*.<devtype>-pci-<bdf>` glob. The PCI domain:bus:device.function is the
part that is stable across kernels (it comes from `linux,pci-domain` and physical
topology, not node naming), and two controllers cannot host the same PCI domain,
so the glob cannot over-match. A non-PCI ID_PATH (an onboard MAC such as
`platform-fe1c0000.ethernet`) is emitted verbatim. **Do NOT "fix" a future
mismatch by rewriting the manifest to the mainline spelling** — that just breaks
the vendor path instead. Guard:
`v2/tests/interface-naming-path-match.test.sh` (static contract + the real
function driven against BOTH kernels' real ID_PATHs, with over-match legs).

**The SoC HDMI-RX driver is named `rk_hdmirx` on the vendor BSP and
`snps_hdmirx` on mainline — and the symlink rule only ever shipped in DEAD
CODE** [EXISTS]

Two independent defects stacked on the `/dev/hdmi-in` symlink, both confirmed on
a live Rock 5B+ running 7.1.5 (neither symlink existed on the board):

1. **Wrong writer.** The rule lived only in `v2/mkosi/customize/udev.sh`, but
   `./v2/build` runs `mkosi.images/runtime/mkosi.postinst.chroot` — `run-all.sh`'s
   RUNTIME modules are NOT executed by it (only `run-all.sh base`, a fact this
   repo already records in `v2/tests/apt-preferences-baked.test.sh`). The shipped
   `99-ceralive-hardware.rules` was the postinst twin, which had no symlink rule
   at all. The rule is now in the live writer too.
2. **Wrong driver name.** Mainline ships the upstream Synopsys DesignWare HDMI-RX
   driver, whose platform driver name is `snps_hdmirx` (module `synopsys_hdmirx`;
   DT compatible `snps,dw-hdmi-rx` + `rockchip,rk3588-hdmirx-ctrler`), so an
   `rk_hdmirx`-only `DRIVERS==` match produces nothing on an edge image. Both
   spellings are now matched: `DRIVERS=="rk_hdmirx|snps_hdmirx"`.

`snps_hdmirx` is the CORRECT upstream name, not a bug in itself — but it also
leaks into the CeraUI source list as the row's `displayName`, because CeraUI's
`onboard-display-names.ts` friendly-name map only knows the vendor spellings.
That half is a CeraUI change, not a pipeline one. Guards: `manifest.bats`
"hdmi-in: …" × 3 (driver-keyed rule, present in the LIVE writer, both names).

**HDMI-RX audio needs BOTH patch `0005` and patch `0006` — `0005` alone gives a
bound codec and NO ALSA card** [EXISTS]

Same shape as the `DMABUF_HEAPS` finding below: the driver half was fine and
proved nothing. Upstream `0005` makes `snps_hdmirx` register an ASoC
`hdmi-audio-codec` child, and on an edge board that device is **bound** with no
cable attached — `/sys/devices/platform/fdee0000.hdmi_receiver/hdmi-audio-codec.7.auto`.
It is also the entire story: `0005` touches no device tree, and ALSA does not
create a card for a bare codec, so `/proc/asound/cards` showed only `usbaudio`,
`rk3588es8316`, `hdmi0` and `hdmi1` — and the last two are the HDMI
**transmitters**, not the receiver. HDMI-IN embedded audio was uncapturable, with
nothing anywhere reporting an error.

Three DT facts were missing, now supplied by `0006`
(`CERALIVE/rk3588-kernel-patches@9c1cb385098d`, PR #2): `#sound-dai-cells` on
`hdmi_receiver`, an `hdmirx-sound` `simple-audio-card`, and `&hdmirx_sound` +
`&i2s7_8ch` (the capture-only I2S the receiver feeds) enabled per board. The
pipeline authors **no** device tree, so the fix was correctly a patches-repo
change plus this pin bump — but the *diagnosis* belongs here, because the symptom
is a pipeline-shaped one ("the image has no HDMI-IN audio").

Two traps worth naming:

- `hdmi0`/`hdmi1` in `/proc/asound/cards` look like they might be the HDMI input
  miscounted. They are not. They are `simple-card` nodes for the SoC's two HDMI
  **outputs**, and a correct fix adds a **fifth** card, it does not repair those.
- The obvious suspect — `armbian/linux-rockchip` `78c67d98f221`, which zeroes
  `capture.channels_min/max` for every `hdmi-audio-codec` with no TX/RX
  discrimination — is **vendor-BSP only**. Mainline `v7.1.7` already carries the
  upstream `no_i2s_capture` / `no_spdif_capture` pdata flags and only clears a
  direction when the registering driver asks. A parked branch in this repo
  (`fix/hdmi-rx-audio-capture-kernel-patch`, tip `5a51e2f`, deleted after todo 8)
  backported that vendor fix; it is correct for `6.1.115-vendor-rk35xx` and
  **does not apply to the edge kernel at all**. Do not resurrect it for `edge`.

**MPP hardware encode needs `CONFIG_DMABUF_HEAPS` — without it `/dev/dma_heap`
does not exist and `mpph264enc` produces ZERO bytes** [EXISTS]

Third instance of the `menuconfig`-parent class that `CONFIG_RTW89` opened.
`DMABUF_HEAPS` is a `menuconfig bool` defaulting OFF, so arm64 defconfig never
enables it and the fragment never named it. Rockchip MPP userspace
(`librockchip_mpp`, which backs `mpph264enc`/`mpph265enc`) allocates every frame
and stream buffer through its `dma_heap` allocator, which opens
`/dev/dma_heap/<name>` — a directory that simply did not exist. A real functional
test on the board (not an element-presence check) confirmed it:

```
gst-launch-1.0 videotestsrc ! mpph264enc ! filesink   ->  0 bytes, stream error
zcat /proc/config.gz | grep DMABUF_HEAPS  ->  # CONFIG_DMABUF_HEAPS is not set
ls /dev/dma_heap                          ->  No such file or directory
```

The kernel driver half was fine — the CeraLive patch series' `rkvenc` driver was
built and bound to `fdbd0000/fdbe0000.rkvenc-core` + `rkvenc-ccu` + `mpp-srv`,
with `/dev/mpp_service` present. The image also already CONTRADICTED itself:
`rockchip-multimedia-config`'s shipped `99-rk-device-permissions.rules` matches
`KERNEL=="system-dma32"`/`"system-uncached"`/`"system-uncached-dma32"` and runs
`chmod a+rw /dev/dma_heap`. The fragment now declares `CONFIG_DMABUF_HEAPS=y` +
`_SYSTEM=y` + `_CMA=y` (`DMA_CMA` was already `=y`).

**HONEST LIMIT — necessary, PROVEN not sufficient, and now COMPLETED by a fourth
symbol.** The heap names MPP asks for are ROCKCHIP-BSP heaps; stock mainline
registers only `system` and the CMA heaps, and MPP does **not** fall back to
`system` — it fails the allocation and the element never registers. That is why
the fragment also declares `CONFIG_DMABUF_HEAPS_SYSTEM_UNCACHED=y`, the symbol
patch `0009` of the series adds for a mainline `system-uncached` heap. See the
resolved KNOWN ISSUE immediately below. A second, harder gap sits behind it: `librga` wants
the vendor `/dev/rga` char device, and mainline exposes RGA only as a V4L2 M2M
node (`rockchip-rga` → `/dev/video1`). Full analysis:
`.omo/evidence/device-platform-wave4/task-hardware-audit-followup.md` §5.

**MPP hardware video encode was broken on the `edge` 7.1.5 kernel by three
stacked defects — all three are FIXED at the `v7.1.7` pin and board-confirmed**
[RESOLVED 2026-08-09]

Root-caused on a Rock 5B+ on 2026-08-02, and the fixes landed in
`CERALIVE/rk3588-kernel-patches` rather than here — which is why the repair
arrived as a `patches_commit` bump (`acb519c101fe`) rather than a pipeline
change. The one thing this repo did owe is the Kconfig line that switches the
new heap on; without it `0009` compiles and its `dma_heap_add()` never runs. The
diagnosis below is kept in full because it is what a future regression would
look like. The three defects are independent and stack:

1. **`mpph264enc` does not register at all.** `librockchip-mpp`'s dma-heap
   allocator table hard-codes `system-uncached` as the heap for an uncached
   allocation. Mainline registers `system`, `default_cma_region`, `reserved` —
   there is no `system-uncached`, so the H.264 HAL's init-time buffer allocation
   fails, `mpp_init(MPP_CTX_ENC, AVC)` fails, and the plugin's registration probe
   skips the element. MPP's own log names it:
   `mpp_dma_heap: os_allocator_dma_heap_open open dma heap type 0 system-uncached
   failed!` → `hal_h264e_vepu580_init init vepu buffer failed ret: -1`. SoC
   detection is fine (`mpp_soc: match chip name: rk3588`), so the earlier
   "MPP answers no AVC encoder" reading was wrong. H.265 allocates later, which
   is why `mpph265enc` registers and then dies at PLAYING instead.
2. **The `rkvenc` IOVA guardrail fires because imported buffer lengths are
   truncated to 64 KiB.** `rkvenc_dma_import_fd()` records
   `buffer->size = sg_dma_len(sgt->sgl)` — the FIRST DMA segment only — and the
   patch series never calls `dma_set_max_seg_size()`, so
   `dma_get_max_seg_size()` returns the `SZ_64K` default and `__finalise_sg()`
   stops coalescing there. The reported window is always exactly `0x10000`, and
   the rejected register is the source frame's NV12 chroma-plane offset. The
   guardrail is correct and must NOT be silenced — it is catching a real
   out-of-range register produced by a bookkeeping bug one layer below it.
3. **Mainline has no uncached dma-heap, so even a corrected mapping encodes
   garbage.** MPP does no CPU cache maintenance on the heap it believes is
   uncached. Given cached memory it produces different output sizes for identical
   input (1280×720 ×60: 231047 bytes, then 161997 bytes) and intermittent CABAC
   decode failures.

Both real fixes are kernel changes in `CERALIVE/rk3588-kernel-patches`, not here,
and both are now IN the pinned series: patch `0008` sets the rkvenc DMA max
segment size for (2), and patch `0009` adds a mainline `system-uncached` dma-heap
for (1)+(3). There is no userspace escape hatch — MPP's heap-name table has no
environment override and the shipped `librockchip-mpp1 1.5.0-1` lacks the newer
upstream cached-heap fallback — so the heap had to exist under that exact name.

`0009` deliberately did NOT port the ACK/Rockchip heap: its one-time cache flush
goes through `dma_heap_get_dev()`, an ACK-only helper that mainline's
`dma-heap.h` does not export at all. It extends the pinned tree's own
`system_heap.c` (which already registers two heaps off one `system_heap_priv`)
with a third instance and uses `arch_dma_prep_coherent()` — the primitive
`dma_direct_alloc()` already uses — so it introduces no new cache-maintenance
policy. `depends on ARCH_HAS_DMA_PREP_COHERENT` is the no-silent-cached-fallback
contract expressed at build time: on an arch that stubs the clean out, the heap
would hand back ordinary cached memory under an uncached name.

**Board-confirmed on a Rock 5B+ (2026-08-09), all three defects cleared.**
`mpph264enc` registers (`gst-inspect-1.0` exit 0, was `No such element`); a real
1080p encode produced 1,854,524 bytes (was 0 bytes + stream error);
`/dev/dma_heap/system-uncached` is a REAL heap with its own minor (`250,1` vs
`system`'s `250,0`), not an alias; the IOVA guardrail never fired across 1080p,
4K, dual-core and a 10-minute soak while BOTH guardrail strings remain present in
the shipped `rkvenc.ko`, so the silence is a real negative; and output was
byte-identical across 5 repeats, three resolutions, a reboot and 5.2 GiB of
memory pressure, decoding clean with CABAC in use.

**A `/dev/dma_heap/system-uncached` symlink or `mknod` alias is NOT a workaround.**
It makes the element register and the guardrail stop firing, which is exactly why
it is tempting — but it hands MPP cached memory it will not synchronise, and
pointing it at the CMA heap instead caps out below 1080p (32 MiB CMA, fragmented
to a ~1.9 MiB largest run; a 1080p NV12 frame needs ~3.1 MiB contiguous). It was
used here as a diagnostic instrument only.

Never blocking — production ships the vendor BSP (D3 unchanged), whose in-tree
MPP stack always provided all three pieces; this was only ever a gate on the
mainline-track `edge` variant. Full evidence, verbatim logs and the experiment
that isolated each layer:
`.omo/evidence/device-platform-wave4/task-rauc-ota-validation.md` §6.4a; the
clearing run is `.omo/evidence/image-pipeline-quality/hardware-validation-round1.md`.

**Still UNVALIDATED beyond one board.** Everything above is one Rock 5B+. The
Orange Pi 5 Plus column is entirely unrun, and `0008`/`0009` still carry the
patch repo's `UNVALIDATED` marker for that reason. Do not describe edge-track
MPP encode as validated on the fleet.

**eMMC HS400 negotiation is inconsistent under the `edge` 7.1.5 kernel — upstream
behaviour, NOT a pipeline defect, and deliberately unfixed** [KNOWN ISSUE]

Two real-hardware observations now exist on the same board and kernel/patch pins.
The earlier task-28 run observed `sdhci-dwcmshc fe2e0000.mmc: Can't reduce the
clock below 52MHz in HS200/HS400 mode` (×3) → `mmc0: switch to hs400 failed,
err:-110` → `mmc0: Failed to initialize a non-removable card`, and `/dev/mmcblk0`
did not appear. A fresh bench build from commit `7c98213` on 2026-08-02 printed
the same warning (×4), but then successfully negotiated HS400:
`mmc0: new HS400 MMC card at address 0001`, `mmcblk0: mmc0:0001 HCG8e 58.3 GiB`,
and `mmcblk0: p1 p2 p3 p4` (with the boot and RPMB areas also enumerated).
The warning therefore remains real, but eMMC reachability is not deterministic
enough to claim that `/dev/mmcblk0` never appears. Whether the difference is
board-unit-specific controller tuning, boot-order timing, or something else is
not established; it needs a dedicated investigation and is not being fixed here.

Everything this repo controls is correct: the board DTS
(`rk3588-rock-5b-5bp-5t.dtsi`, straight out of the pinned tree) already declares
`mmc-hs400-1_8v` + `mmc-hs400-enhanced-strobe`, the base node carries all five
clocks/resets + `supports-cqe`, the config has `MMC_SDHCI_OF_DWCMSHC=y` /
`MMC_CQHCI=y` / `ROCKCHIP_IODOMAIN=y`, and `sdhci_dwcmshc_rk3588_pdata.revision`
is `1`. Linux **v7.0** added a guard to `dwcmshc_rk3568_set_clock()` that
`goto enable_clk`s past the DLL bypass/reset whenever the requested clock is
≤52 MHz while `ios.timing` still reads HS200/HS400; through v6.17 that block ran
unconditionally, and the guard is still in mainline `master` — current upstream
behaviour, not a regression already fixed. The pipeline authors NO device tree
(zero `.dts`/`.dtsi`/`.dtbo` files in the repo), so it cannot express a repair:
that is a driver patch or a board DT patch in `CERALIVE/rk3588-kernel-patches`,
bench-validated on a spare board, **never** guessed at against a production eMMC.
Not currently blocking — production ships the vendor BSP (D3 unchanged), which
drives this eMMC fine. Do **not** use eMMC being unreachable as proof that a
bench boot did not touch it; prove non-interference from the mount table and
disjoint `PARTLABEL` namespaces instead. Full historical analysis and the
failure observation: `.omo/evidence/device-platform-wave4/task-28-wifi-emmc-findings.md`.
The succeeding observation is recorded in
`.omo/evidence/device-platform-wave4/task-rauc-ota-validation.md` §8a.

**The LAN-ingest firewall needs `CONFIG_NF_TABLES` — the `edge` kernel had no
nftables at all, so the WAN-side ingest boundary silently never applied** [EXISTS]

Fourth instance of the `menuconfig`-parent class `CONFIG_RTW89` opened, and the
first one that is a SECURITY regression rather than a missing feature.
`ceralive-ingest-firewall.service` is what keeps the UNAUTHENTICATED MediaMTX
ingest gateway (RTMP :1935 + SRT :4001, no publish password and no SRT passphrase
in v1) off the WAN: it `nft -f`s a ruleset that DROPs both ports when they arrive
on a `usb*`/`enx*`/`ww*`/`ppp*` uplink. On the `edge` 7.1.5 kernel that unit
failed on EVERY boot and the boundary was simply not there — a publisher on a
modem's public or CGNAT address could reach the anonymous ingest. Confirmed live
on a Rock 5B+ running a fresh bench build:

```
systemctl status ceralive-ingest-firewall.service
  Active: failed (Result: exit-code)
  Process: 182 ExecStart=/usr/sbin/nft -f /etc/ceralive/ingest-firewall.nft (code=exited, status=3)
  nft[182]: mnl.c:60: Unable to initialize Netlink socket: Protocol not supported

modprobe nfnetlink
  FATAL: Module nfnetlink not found in directory /lib/modules/7.1.5-ceralive-rk3588

zcat /proc/config.gz | grep -iE "NFNETLINK|NF_TABLES|NETFILTER"
  # CONFIG_NF_TABLES is not set
  CONFIG_NETFILTER=y
  CONFIG_NETFILTER_ADVANCED=y
  CONFIG_IPV6=y
```

`CONFIG_NF_TABLES` is a tristate with a prompt and **no `default`**, and the
entire family — `NF_TABLES_INET`, every `nft_*` expression module, the IPv4/IPv6
halves — lives inside its `if NF_TABLES` block, so arm64 `defconfig` never turns
it on and `rk3588-edge.fragment` never named it. Everything netfilter-shaped that
WAS in the config (`NETFILTER=y`, `NETFILTER_ADVANCED=y`) is the legacy
`{ip,ip6}_tables` scaffolding and buys nftables nothing.

**Do not chase `nfnetlink` as the missing module.** The error `nft` reports is a
missing netlink PROTOCOL, not a missing table, because the `NETLINK_NETFILTER`
protocol comes from `CONFIG_NETFILTER_NETLINK` — a promptless tristate that
NOTHING selects until `NF_TABLES` is on. `modprobe nfnetlink` therefore fails
with "module not found", which reads like a packaging or firmware gap and is
neither. Fixing the parent makes the protocol appear built-in and the `modprobe`
question moot.

The fragment now declares exactly two symbols: `CONFIG_NF_TABLES=y` (`=y`, not
`=m` — the unit is a `DefaultDependencies=no` oneshot ordered `Before=` the
gateway opens its listeners, so the boundary must exist before any modular
autoload could have run) and `CONFIG_NF_TABLES_INET=y` (the ruleset's table is
`inet`; the symbol is a bool `depends on IPV6`, already `=y` from defconfig, and
it `select`s `NF_TABLES_IPV4`/`NF_TABLES_IPV6`, which therefore need no entry —
same `select`ed-helper rule as `RTW89_CORE`/`RTW89_PCI`).

**`CONFIG_NFT_COUNTER` is deliberately NOT declared, and adding it would fail the
build.** The ruleset's `counter` statement is real and load-bearing, so the
symbol looks obligatory — but v7.1.7 has no such symbol at all:
`net/netfilter/Makefile` compiles `nft_counter.o` unconditionally into
`nf_tables-objs`, alongside `nft_meta.o` (the `iifname` match) and
`nft_chain_filter.o` (the `type filter hook input` base chain). Declared, it
would resolve to nothing and `verify-kernel-config.sh` would correctly reject the
build. This is the same declare-the-honest-resolved-value discipline as
`CONFIG_TYPEC_FUSB302=m`, arrived at the same way — read the symbol's own Kconfig
and Makefile at the pinned tag instead of arguing with the gate.

**Invisible to the PR gate**, like every finding in this class: the gate is
`DRY_RUN=1` and never runs `[2b/9]`, and the unit fails at BOOT, not at build —
the `.deb` validated on all four axes, `/boot` was complete, and the image booted.
Guard: `v2/tests/kernel-config-fragment.bats` — both symbols pinned in the real
fragment with the parent declared ahead of the `inet` child, `=m` rejected,
`CONFIG_NFT_COUNTER` forbidden, and the real fragment driven against a
reproduction of the board's own `# CONFIG_NF_TABLES is not set` answer.

**The A/B selector may use NO arithmetic command, and must ABANDON a slot it cannot
load — both were real infinite-crash-loop defects** [EXISTS]

Two independent bugs in `v2/mkosi/platform/boot/boot.scr.cmd`, both found on a live
Rock 5B+ over UART, both of which made a failing slot retry forever instead of
rolling back.

- **`setexpr` does not exist on this board.** The staged U-Boot is built
  `# CONFIG_CMD_SETEXPR is not set` — read it back from `u-boot-config-target-1`
  inside `linux-u-boot-vendor-rock-5b-plus`. The bootcount decrement called
  `setexpr`, so every boot printed `Unknown command 'setexpr' - try 'help'` and left
  the counter UNCHANGED; 8 consecutive crash-reboots all logged `A=3 B=3`, so the
  documented `3→2→1→0` rollback could never fire. The decrement is now a lookup over
  the closed `0..3` budget the sanitizer already enforces, written across two
  variables (branches read `cera_cur`, assign `cera_next`) because a cascade over one
  variable falls through `3→2→1→0` in a single pass. `itest` and `test` are
  available; **do not reintroduce an arithmetic dependency.**
- **A failed `ext4load` used to reach `booti` anyway.** The kernel/DTB loads were
  unguarded, so on failure the load address still held whatever was in DRAM and
  `booti` jumped into it — `"Synchronous Abort" handler, esr 0x02000000` → reset →
  same slot. The script now `exit`s on a failed kernel or DTB load, which returns to
  the bootflow scan so U-Boot moves to the next boot device (eMMC) instead of
  wedging. The **initrd load stays optional** — the vendor package ships only
  `/boot/initrd.img-<REL>`, so the bare-name load legitimately fails on the
  known-good path.

Guard: `v2/tests/boot-script-sanitize.test.sh` stubs `setexpr` as **absent**, the way
the board really answers, and executes the real script through U-Boot command stubs —
so a decrement that depends on it fails the suite, not the fleet. It walks the whole
budget, proves rollover to B and B's own decrement, and proves an unloadable
kernel/DTB abandons the device. `test-fallback.sh` §7 additionally forbids the token
`setexpr` outside comments.

**The A/B selector must define its OWN scratch address — an inherited `loadaddr`
is a per-board default, and an empty one HALTS the board with an SError** [EXISTS]

Third defect in the same `v2/mkosi/platform/boot/boot.scr.cmd`, found the same way
(live interactive U-Boot over UART) but on the OTHER board, and it is worse than the
two above: it does not crash-loop, it stops the board dead until someone pulls power.

The script used `${loadaddr}` as an implicit scratch DRAM address at all eight of its
`env import` / `env export` / `fatwrite` sites without ever defining it, i.e. it
assumed the board's default U-Boot environment supplies one. **That is a per-board
fact, not a U-Boot guarantee.** On a real Orange Pi 5 Plus:

```
=> printenv loadaddr
## Error: "loadaddr" not defined
=> printenv kernel_addr_r fdt_addr_r ramdisk_addr_r
kernel_addr_r=0x00400000
fdt_addr_r=0x08300000
ramdisk_addr_r=0x0a200000
```

The three addresses the selector uses for the REAL kernel/DTB/initrd loads are fine
on both boards; only the scratch one is absent, and only on this board — which is
exactly why the fix above was authored and validated on a Rock 5B+ and shipped
looking correct. With `${loadaddr}` empty the address argument does not become
"invalid", it **disappears**: `env export -t ${loadaddr} BOOT_ORDER …` becomes
`env export -t BOOT_ORDER …`, U-Boot parses `BOOT_ORDER` as the destination address,
and writing the env blob there faults the SoC memory bus. The board printed the
selector's own `BOOT_ORDER=A B A_LEFT=3 B_LEFT=3` line and then:

```
"Error" handler, esr 0xbe000011

* Reason:        Exception from SError interrupt
...
### ERROR ### Please RESET the board ###
```

Note the handler name: this is an **SError**, a DIFFERENT exception class from the
`"Synchronous Abort" handler, esr 0x02000000` of the unguarded-`ext4load` defect
above. Same script, same board family, two separate signatures — do not conflate
them when reading a UART capture.

No reset loop, no fall-through to the other slot or to eMMC — UART silent across
repeated polls, physical power cycle required. Isolated outside the script by
replaying that single command by hand (identical PC and ESR).

The selector now `setenv loadaddr 0x00c00000` before its first use, so all eight
sites resolve to a fixed address regardless of what the board shipped. **12 MiB is
not an arbitrary pick** — it is clear of `kernel_addr_r` (4 MiB) and far below
`fdt_addr_r` (131 MiB) / `ramdisk_addr_r` (162 MiB), and it was proven on that board
with a full `env export` → `fatwrite` → `fatload` → `env import` round trip that
returned all three variables byte-for-byte with no exception. `recovery.scr.cmd` has
never had this defect — it only ever uses the three `*_addr_r` variables.

Guard: `v2/tests/boot-script-sanitize.test.sh` runs the real script against a stubbed
default environment with **no `loadaddr` at all**, the same way it stubs `setexpr` as
absent, and its stubs treat a vanished address argument as the terminal `SERROR` the
board actually produced rather than a silent no-op — so this fails the suite, not the
fleet. A static leg additionally requires the `setenv` to precede the first use.
**Do not reintroduce a dependency on any board default-environment variable here**;
if another scratch address is ever needed, define it in the script too.

**Before ANY bench reboot into a freshly-installed slot, the OTHER slot MUST be
confirmed-good first — otherwise automatic rollback is already disabled** [KNOWN ISSUE /
SAFETY RULE]

This is an operational precondition, not optional hygiene. With `BOOT_ORDER=A B`, if the
running slot has already reached `BOOT_B_LEFT=0` without being marked good, a reboot into
newly-installed A can exhaust A too and strand the board. The selector's exact
last-resort branch in `v2/mkosi/platform/boot/boot.scr.cmd` is:

```text
# --- all counters exhausted -> last-resort boot the head of BOOT_ORDER (no decrement)
if test "${cera_slot}" = ""; then
  setenv cera_exhausted 1
  for s in ${BOOT_ORDER}; do
    if test "${cera_slot}" = ""; then setenv cera_slot "${s}"; fi
  done
  echo "CeraLive: all slots exhausted — last-resort booting ${cera_slot}"
fi
```

Thus, when **both** `BOOT_A_LEFT` and `BOOT_B_LEFT` are `0`, the loop chooses only the
head of `BOOT_ORDER` — A for `BOOT_ORDER=A B` — and `cera_exhausted=1` skips the later
decrement. Every subsequent reboot therefore boots A again, forever; it never falls
through to B. The A/B safety net requires **at least one slot to have a nonzero counter
at all times**.

A slot can reach `_LEFT=0` and never regain its normal budget of 3 when its booted OS
never completes the mark-good path. This can happen after a manual reset or
power-cycle outside the normal flow, or during bench RAUC installs when
`ceralive-healthcheck.service` / the mark-good mechanism never runs. That was the real
incident: immediately before the 2026-08-03 bench reboot, the running B state was
`BOOT_ORDER=A B`, `BOOT_A_LEFT=3`, `BOOT_B_LEFT=0`; the board did not return after A
was selected and did not return to the network; whether A failed to boot or booted
without network remained undetermined, and automatic rollback to B was unavailable.
See the full failure timeline and selector analysis in
[`.omo/evidence/device-platform-wave4/task-hdmirx-audio-fix-boot-proof.md`](../.omo/evidence/device-platform-wave4/task-hdmirx-audio-fix-boot-proof.md)
§3–§4. Do not infer recovery or hardware state from this incident; the lesson is the
precondition.

**Mandatory rule:** before initiating **any** reboot into a freshly RAUC-installed slot
during bench/dev work, inspect the raw boot state and confirm that the OTHER,
currently-running slot has a nonzero counter and is confirmed-good. If it is not,
explicitly restore it **before** rebooting. On the current image the documented form is
`ceralive-boot-state set-state <currently-running-slot> good`, but operators MUST verify
the exact command name and syntax against the installed board/image (do not guess; use
the installed helper's documentation/help or equivalent). Skipping this check can
strand the board and require physical recovery.

Follow-up recommendation: add an automated guard — for example, a Bats assertion that
locks down the documented all-counters-exhausted/head-of-`BOOT_ORDER` behavior, and/or a
bench-reboot wrapper that checks the other slot and warns or refuses when its counter is
zero. Do not implement that tooling as part of this documentation-only fix.

**`/boot` completeness is a BUILD gate (`[6b/9]`), because the two kernel paths fill
it by different mechanisms** [EXISTS]

`v2/lib/verify-boot-artifacts.sh` asserts the emitted rootfs tar carries a resolvable
`/boot/Image`, `/boot/dtb/<soc-vendor>/${fdtfile}` and a versioned
`/boot/initrd.img-<REL>`; `orchestrate.sh` runs it on every arm64 boot-BSP build
right after the tar is emitted, and fails the build if anything is missing.

- **Layout-agnostic ON PURPOSE.** `Image` may be a symlink or a real file; `dtb` may
  be a symlink to `dtb-<REL>/` or a real directory. It checks what U-Boot can load,
  not which packaging mechanism produced it — the vendor and source-built layouts
  legitimately differ (see the kernel-from-source `/boot` artifact mapping above).
- **Layout-agnostic, but NOT content-agnostic.** It also reads the first 64 bytes of
  the resolved `/boot/Image` and requires the raw ARM64 Image magic at offset 56,
  naming the compression when it finds one. Metadata alone passed a gzip `Image.gz`
  that `booti` refused on a real board — see the `bindeb-pkg` ships `Image.gz` KEY
  FACT above. The member is extracted to a temp file rather than piped through
  `head`: closing that pipe kills `tar` with `SIGPIPE`, and `set -o pipefail` turns
  a correct read into a build failure — the exact bug `deb_lists_path` already
  shipped once.
- **Why it is not left to `tests/preflash-verify.sh`,** whose `check_rootfs_populated`
  already checks these artifacts: that tool runs on a **production-labelled `.raw` an
  operator is about to flash**, and it asserts the frozen PARTLABEL set FIRST — so a
  `CERALIVE_BENCH_LABELS=1` bench image fails there and never reaches its artifact
  checks. Combined with a `DRY_RUN`-only PR gate that never executes the layers which
  populate `/boot`, that is precisely how an `edge` image with no `/boot/Image`
  reached a board. Do not delete this as duplicated coverage.
- **Root-free and fast:** the subject is the normalized rootfs tar, so symlinks and
  sizes are readable with no loop device, no `debugfs` and no privileges — ~1 s on a
  1.5 GB tar, and it runs identically in CI.

Guards: `v2/tests/boot-artifacts.bats` (27 tests — both layouts pass, the exact
pre-fix layout is rejected, each artifact is driven out of BOTH layouts one at a
time, the Image FORMAT is asserted in both the verifier and the real shipped
staging function, plus the producing mechanisms and the orchestrator wiring).

**Bench PARTLABEL overlay — OPT-IN, bench media only, production path byte-identical** [EXISTS]

`CERALIVE_BENCH_LABELS=1 ./v2/build <board>` renames the frozen label set to
`xboot`/`xrootfs_a`/`xrootfs_b`/`xdata`. It exists because a bench microSD is
booted on a board whose **eMMC already carries a production image**, and the
frozen contract selects every slot and mount by `PARTLABEL`
(`docs/partition-contract.md` §3, lines 65/75) — duplicate labels across the two
media make `PARTLABEL=rootfs_a` ambiguous on the running kernel.

- **It is NOT a contract change.** Sizes, roles, partition order and geometry are
  untouched; `docs/partition-contract.md` stays FROZEN and unedited. This is
  additive tooling behaviour layered on top of it. The committed
  `v2/mkosi/repart/*.conf` are never edited either — the `Label=` rewrite happens
  on the STAGED COPY inside `stage_repart_dir`.
- **Every reference site is renamed together, or the card does not boot.** GPT
  labels (`lib/assemble-disk.sh`), the contract verifier (`lib/verify-disk.sh`),
  the `/boot` fstab entry + RAUC `system.conf` slot devices + the compiled U-Boot
  `boot.scr`/`recovery.scr` (`platform/boot/install-boot.sh`), the `/data` fstab
  entry (`customize/postinst-lib.sh`), and the fallback RAUC `system.conf` on both
  dual-track twins (`customize/rauc-setup.sh` + the runtime `mkosi.postinst.chroot`).
  A relabelled GPT whose fstab still says `PARTLABEL=boot` fails on first mount —
  strictly worse than the collision it was meant to prevent.
- **One resolver, three copies by necessity:** `lib/common.sh::resolve_partlabel`
  is canonical; `customize/postinst-lib.sh` carries a `declare -F`-guarded fallback
  (same idiom as its `log`/`die`) and `platform/boot/install-boot.sh` a
  self-contained twin — both run in chroots where `lib/` is not mounted.
- **Subimage propagation.** `CERALIVE_BENCH_LABELS` is in `orchestrate.sh`
  `env_names` AND `mkosi.conf` `PassEnvironment=` — the runtime chroot writes the
  `/data` fstab entry, so skipping `PassEnvironment=` would silently read it empty
  (the exact drift that shipped the eth0/eth1 and add-on-keyring bugs).
- **Also isolates the ext4 filesystem UUIDs.** The slot label seeds `det_uuid`, so
  the bench slots do not carry byte-identical UUIDs to the eMMC beside them.
- **Unflagged is byte-identical to before this existed**, pinned by the committed
  pre-overlay GPT fixtures `v2/tests/fixtures/gpt-baseline/*.gpt` (captured at
  `1af9116`) plus a non-vacuity leg proving the same comparison fails on a bench
  build. Guards: `v2/tests/bench-partlabels.bats` (13 tests).
- **Bench-only, never released.** No `release.yml` job and no apt/R2 publish path
  sets it; the orchestrator logs a loud warning while it is active, and a bench
  image deliberately FAILS `v2/tests/preflash-verify.sh` (which asserts the
  production label set), so the eMMC flash gate refuses it.

**RK3588 HW-accel userspace .deb fetch — pinned upstream URLs + SHA-256** [EXISTS]

The RK3588 GPU/video **userspace** (Mali-G610 blob, Rockchip MPP encode/decode lib,
RGA 2D accelerator, the GStreamer MPP plugin, and the multimedia udev config) is NOT
in the Armbian bookworm arm64 feed, so it is baked from **exact upstream release-asset
URLs verified by SHA-256** — the same fail-closed, no-fallback discipline as the BSP
fetch, but URL-pinned (a pinned URL + SHA-256 needs no rotating apt index or GPG trust
root). This is what makes `mpph264enc`/`mpph265enc`/`mppjpegenc`/`mppvp8enc` register —
proven on real Rock 5B+ hardware (ffprobe-verified H.264/H.265 HW encode).

- **Pin file:** `v2/manifests/rk3588-userspace-deb-versions.txt` — one record per
  package (`package  filename  sha256  url`). Six packages:
  `libmali-valhall-g610-g24p0-wayland-gbm` 1.9-1 (firmware_packages),
  `gstreamer1.0-rockchip1` 1.14-4 (hw_accel_gstreamer_plugins), and
  `rockchip-multimedia-config` 1.0.2-1 / `librga2` 2.2.0-1 / `librockchip-mpp1` 1.5.0-1
  / `librockchip-mpp-dev` 1.5.0-1 (gstreamer_runtime_packages). Sources: tsukumijima
  (`mpp-rockchip`, `rockchip-multimedia-config`, `libmali-rockchip`) + radxa
  `rk3588s2-bookworm` (the gst plugin + its ABI-paired RGA; tsukumijima ships no
  gst-rockchip mirror).
- **Fetcher:** `fetch_rk3588_userspace` in `v2/lib/fetch-debs.sh` stages only the
  pinned packages the resolved family declares (intersection of
  `collect_declared_bsp_pkgs` and the pin file's names); `fetch_bsp` EXCLUDES exactly
  this set from the Armbian fetch. An x86 family declares none. DRY_RUN logs the exact
  URLs + hashes and downloads nothing.
- **DO NOT** convert any of these into a `deb [signed-by=...] https://...` apt line —
  that is a new live trust root, exactly what the pinned-URL + SHA-256 approach avoids.
  **DO NOT** bump a pinned VERSION without re-proving HW encode (the versions are
  empirically proven). See `v2/docs/kernel-currency-watch.md` and
  `v2/docs/cog-display-addon.md`.

**versions.yaml** [EXISTS]
`fetch-debs.sh` and `resolve.sh` read pin versions from the repo-local `versions.yaml`.
Don't hardcode versions in the script.

**CI and release build caches** [EXISTS]
PR CI (`v2-ci.yml`) caches only pip's download/wheel store (`~/.cache/pip`) for
the manifest-validation and build-plan jobs. Its key includes the runner OS,
architecture, and the hash of `v2/ci/requirements-ci.txt`; image outputs, mkosi
caches, QEMU state, and release artifacts remain uncached there.

The protected release candidate (`.github/workflows/release.yml`) persists the
two build-state stores that materially shorten a production rebuild:

- BuildKit's GitHub Actions cache reuses layers from the canonical
  `v2/ci/Dockerfile`. The scope is stable per repository, runner OS/architecture,
  board, and mkosi tool pin, so old commits do not create an unbounded cache
  family. The source hash is carried in the builder image tag and label; the
  Dockerfile/context digests remain BuildKit's layer keys. `mode=min` exports
  only layers needed by the loaded builder image.
- `v2/mkosi/cache/rock-5b-plus` is restored and saved with a key containing the
  repository, runner OS/architecture, board, mkosi pin, and build-source hash.
  Its restore prefix retains those collision boundaries. The cache is capped at
  2 GiB; size measurement, over-limit clearing, and runner-UID/GID
  normalization all happen as root inside the builder container before the save
  step, because mkosi may create mode-700 root-owned entries.

The persistent self-hosted runner also clears exactly the ignored generated
paths `v2/mkosi/build` and `v2/mkosi/cache` in a digest-pinned, network-disabled
cleanup container before checkout and in an `always()` step after the job. The
post-run cleanup happens after a successful cache save. This bounded allowlist
lets `actions/checkout` keep its normal clean checkout while recovering from a
host interruption that skipped post-run cleanup; it never deletes the checkout,
staging inputs, image outputs, QEMU state, release artifacts, or trust material.

Both cache paths are build state only: image outputs, `.staging`, QEMU state,
apt credentials, and release artifacts are excluded. Cache steps are guarded to
release pushes/tags (the workflow has no pull-request trigger), and all
production trust inputs are materialized after cache restore/build, so an
untrusted PR cannot populate or consume this release cache path and secrets
never enter a cache key or build context.

**Production builder resource contract** [EXISTS]
The protected candidate job pins `DOCKER_CONTEXT=default`; the context must
resolve to the native Linux socket `unix:///var/run/docker.sock`, and the daemon
must not identify as Docker Desktop. Before BuildKit or trust materialization,
`v2/ci/check-builder-resources.sh` requires at least 16 GiB daemon-visible RAM,
16 GiB combined `MemAvailable` + `SwapFree` from the workflow-pinned
`/proc/meminfo`, and 24 GiB free on both the workspace and Docker-root
filesystems. A pressure or topology failure aborts before package fetch/build
instead of risking a kernel OOM and runner restart.

After a failed immutable candidate exposes a release-path defect, merge its fix
before proving it: push an untagged `release/**` branch at the exact merge SHA,
require the production candidate and physical real-HW jobs to pass, then create
the next unused patch tag at that same proven commit. Never use a new tag as the
first production execution of the repair, and never move or rerun the failed tag.

The Rock 5B+ raw's 14,800 MiB logical geometry is intentional and starts sparse.
Candidate sealing hard-links that immutable raw into the repo-local `candidate/`
directory, so staging does not allocate a second multi-GiB copy; artifact upload
uses explicit zlib compression level 6. Keep the candidate directory on the same
filesystem, and do not replace the hard link with `cp`. Regression coverage is
in `v2/tests/builder-resource-budget.test.sh` and
`v2/tests/release-cache-contract.test.sh`.

**Reproducible builds** [EXISTS]
Same source state → bit-identical `.raucb`. The orchestrator pins one
`SOURCE_DATE_EPOCH` (env override → HEAD commit time → frozen fallback, via
`common.sh::resolve_source_date_epoch`) and exports it so every embedded mtime
(rootfs.tar, squashfs, ext4, mkosi) clamps to it. `build-bundle.sh` signs the RAUC
bundle through a deterministic OpenSSL CMS path (`-noattr` → no wall-clock
`signingTime`; real leaf key + intermediate chain, still `rauc`-verifiable) because `rauc`
itself bakes an uncontrollable CMS timestamp. `REPRODUCIBLE=0` opts back into the
native `rauc bundle` signer (NOT bit-reproducible). Proof: `v2/run-tests` section
11; double-build the same board and compare `.raucb` sha256.

**RAUC test trust fixture** [EXISTS]

The canonical `v2/run-tests` entrypoint invokes
`v2/tests/generate-dev-rauc-pki.sh` before any RAUC contract suite. The generator
creates or validates only the ignored `v2/.dev-keys/` NON-PRODUCTION fixture
(including the leaf → intermediate → root chain and leaf key pairing); it never
provides a production default. Production image builds still require an explicit
`CERALIVE_RAUC_PKI_DIR` and matching `RAUC_KEYRING_FILE`.

**RAUC 1.8 needs a DUAL-EKU signing leaf, `unsquashfs`, and `mkfs.ext4` on the
device — else OTA is 100% broken** [EXISTS]

The device runs Debian bookworm's `rauc 1.8-2`. `rauc install` (the config-driven
path `ceralive-update` / CeraUI `system.startUpdate()` actually use) failed on real
Rock 5B+ hardware in three stacked ways, all fixed here. A REAL, complete,
end-to-end OTA install with all three fixes combined has now been PROVEN on
physical Rock 5B+ hardware: signature verified, manifest checked, slot B was
written, the bootloader switched to it, and the new slot rebooted healthy.

- **Signing leaf EKU.** RAUC's `check-purpose=codesign` / X.509 key-usage support
  landed in **rauc 1.9** (March 2023); 1.8 predates it entirely — its
  `-C`/`--confopt` CLI flag does not exist and a `[keyring] check-purpose=codesign`
  line in `system.conf` is ignored. So 1.8's `CMS_verify()` falls back to OpenSSL's
  default `smime_sign` purpose, which rejects a **codeSigning-only** leaf with
  `Verify error: unsuitable certificate purpose`. The dev/CI leaf
  (`v2/tests/generate-dev-rauc-pki.sh`) now carries a **dual EKU**
  `emailProtection,codeSigning`: `emailProtection` satisfies 1.8's unconfigured
  `smime_sign` default (install succeeds), `codeSigning` keeps forward-compat with a
  future rauc ≥1.9 `check-purpose=codesign` upgrade (and the modern CI/local `rauc`
  1.15.2 strict path). CA certs (root/intermediate) intentionally carry NO EKU per
  RAUC's own docs — do not add one. The build-time self-check in
  `build-bundle.sh::verify_openssl_bundle()` was `openssl cms -verify -purpose any`
  (accepts anything) — materially weaker than the device, which is why the bug
  shipped silently; it is now `-purpose smimesign`, reproducing rauc 1.8's default
  purpose (same OpenSSL error) so a single-purpose leaf fails at build time.
  Structural guards: `generate-dev-rauc-pki.sh`'s `validate_fixture()` asserts the
  leaf carries both EKUs, and `verify_openssl_bundle()` now fails a single-purpose
  leaf.
- **`unsquashfs` runtime gap.** Even with a verified signature, `rauc info`/`install`
  next fails `Failed to start unsquashfs: ... No such file or directory` — `rauc`
  shells out to `unsquashfs` to extract the plain-format bundle manifest. Build-time
  `mksquashfs` runs on the HOST/CI, so this runtime-only gap was invisible.
  `squashfs-tools` is now in `shared.list` (standard bookworm `main` — no new trust
  source). Guard: `manifest.bats` "squashfs-tools is installed so rauc can unsquashfs
  bundles".
- **`mkfs.ext4` runtime gap.** After signature and manifest checks pass, RAUC's
  slot-write phase shells out to `/sbin/mkfs.ext4` from `e2fsprogs` to format the
  target ext4 slot before copying in the new rootfs image. Without it, the real
  Rock 5B+ install reported exactly: `LastError: Installation error: Failed updating slot rootfs.1: failed to start mkfs.ext4: Failed to execute child process 'mkfs.ext4' (No such file or directory)`. Build-time tooling never needed
  `mkfs.ext4`, so this runtime-only gap was invisible. Adding `e2fsprogs` made the
  REAL end-to-end install complete successfully, activate slot B, and boot the
  fresh slot healthy; guard: `manifest.bats` "e2fsprogs is installed so rauc can
  format ext4 slots".

**PRODUCTION PKI still carries the codeSigning-only leaf and was DELIBERATELY NOT
touched here.** `/mnt/development/ceralive/cert-work/rauc/gen-certs.sh` generates the
production leaf with the same `extendedKeyUsage = codeSigning` only — so it has the
identical RAUC 1.8 defect. It is live security key material (private keys included)
and reissuing it is a separate, explicit decision per `cert-work/ROTATION.md` — out
of scope for this fix. Flagged for the orchestrator/user to action separately before
production OTA can work on a 1.8 device.

**The debug package delta is VARIANT-keyed, and it shares a filename suffix with
the FAMILY deltas — so every directory glob had to be taught the difference** [EXISTS]

`CERALIVE_DEBUG_IMAGE=1` now selects a package set as well as an access posture.
`v2/manifests/packages/development.delta.list` carries 18 packages — `python3`,
`strace`, `tcpdump`, plus the fifteen T17 diagnostics the `debug-toolset` sysext
add-on ships — and `lib/orchestrate.sh` appends it to `$SHARED_PACKAGES` **only**
on that branch. With the flag unset or `0` the resolved set is byte-identical to
todo 31's measured baseline: 48 packages, `shared.list` + the resolved
`<family>.delta.list`, nothing else.

**The trap, and it is the whole reason this is a KEY FACT.** The file is keyed on
the BUILD VARIANT, not on a board family, but it keeps the `.delta.list` suffix
because it is literally the same format. Three places globbed
`manifests/packages/*.delta.list` as a DIRECTORY — `lib/parity-check.sh`'s expected
set, `tests/realhw-suite.sh`'s synthesized dpkg status, and `manifest.bats`'s own
`make_parity_rootfs` fixture. Left alone, each would have folded the 18 debug
packages into the PRODUCTION contract, so `parity-check.sh` would `die` at the
`[7/9]` gate on a **correct** production image for "Debian packages MISSING:
python3 strace tcpdump …" — and the fixture would have hidden it by declaring
those same packages installed in the synthetic rootfs, which is how a leak like
this passes its own test suite.

All three now select their files through `lib/common.sh::runtime_pkg_list_files`,
which skips the debug delta by name and re-appends it only when the flag is set.
**A new consumer must use that helper**; a fresh `*.delta.list` glob silently
reintroduces the leak. `tests/parametric.sh` names `rk3588.delta.list` and
`x86_64.delta.list` explicitly and is unaffected;
`tests/package-migration-coverage.sh` globs deliberately, because it builds an
ACCOUNTING set (does a legacy package have *a* v2 home?) rather than an install
set.

Two ordering/naming facts that are load-bearing:

- **The flag is normalized and validated in `main()`, before `[1/9]` resolves the
  package set** — not in `run_mkosi_build()` at `[6/9]`, where it used to live. The
  package set now depends on it, so `CERALIVE_DEBUG_IMAGE=yes` must abort rather
  than quietly resolve a PRODUCTION set and fail three stages later at mkosi.
- **`development` must never become a board family.** The family lookup is
  `${FAMILY}.delta.list`; a `manifests/families/development.yaml` would let a board
  pull the debug set through the ordinary production path.

**Both diagnostic routes stay, and they are not redundant.** The `debug-toolset`
sysext add-on is untouched and remains the FIELD route — installed at runtime, over
the network, on an ordinary production image, no reflash. The delta is the BENCH
route — baked in so a developer debugging the boot / first-boot window has the tools
before any network or add-on manager exists. `lib/build-feature-sysext.sh` reads a
`--deb-staging` tree and no package `.list` at all, so it is completely unaffected.
Keep the two sets equal.

**On-device BUILD tooling is still refused, in both variants.** `removed.md` §(e)'s
compiler/VCS/runtime entries (`build-essential`, `cmake`, `gdb`, `git`, `nodejs`,
`valgrind`, `linux-headers-*`, …) are deliberately NOT in the delta: nothing is
compiled on a CeraLive board, and a debug image whose only difference from
production should be diagnostic must not become a materially different system.

`pulseaudio` is in the delta because it is in the add-on's `provides`, and it is
inert: bookworm ships only USER units (`/usr/lib/systemd/user/pulseaudio.{service,socket}`)
and this appliance has no user session, so it never autostarts and never contends
with `alsasrc` for the capture device. Do not enable it system-wide.

Guards: `v2/tests/manifest.bats` §30 (15 tests — the exact 18-package content, zero
duplication against `shared.list` or either family delta, the production selection
pinned to shared+family only, the debug selection adding *exactly* the delta and
removing nothing, a real `parity-check.sh` run against a production-modelled rootfs
plus the inverse leg proving it DEMANDS the delta under the flag, the
no-bare-glob structural guard, the validate-before-resolve ordering, the
PassEnvironment propagation, the retained password/ssh/marker behaviour, the
untouched add-on, and the absent `development` family). Mutation-verified: deleting
the name-skip in `runtime_pkg_list_files` fails 5 of them.

**Image size gate — BLOCKING at 1.5 GB, and it is the `[6c/9]` BUILD stage** [EXISTS]

`v2/lib/measure-size.sh` runs as `orchestrate.sh`'s `[6c/9]` stage on every real
build, between the `[6/9]` tar emit and the `[7/9]` parity check. If the normalized
rootfs tar exceeds **1.5 GB** the build `die`s there, so no `.raw` and no `.raucb`
are cut. The threshold is post-slim (locale strip, final apt-cache cleanup,
appliance payload pruning, and the Mesa software-GL prune below already applied).
See [`v2/docs/size-notes.md`](v2/docs/size-notes.md) §10 for the wiring and the
levers used to reach it.

Both RK3588 boards pass it: `rock-5b-plus` 1,412,259,840 B, `orange-pi-5-plus`
1,418,792,960 B (real wet vendor-BSP production builds, 2026-08-02). They were
~70-76 MB OVER until the Mesa software-GL prune below; `rootfs_bytes_max` has never
been moved to accommodate an overage.

**For three releases this "blocking" gate had never once run against a real
image** — and that is why the overage shipped. `orchestrate.sh` had no measurement
stage at all, and the only live caller was `v2-ci.yml`'s *"rootfs size gate
(blocking)"* job, which measures a **synthetic 4 KB tree**. A job that can only ever
measure 4 KB cannot fail on a 1.57 GB image, so the README/AGENTS claim that the
gate "runs after every build" was aspirational until `[6c/9]` landed. Properties
worth knowing before editing it:

- **Not arch-gated.** Every shipped board carries a non-null `rootfs_bytes_max`,
  `x86-minipc` included. Gating on `arm64` would exempt the one board whose size has
  never been measured — the exact shape of the original defect.
- **`INSTALL_BOOT_BSP=0` is skipped, LOUDLY.** A kernel-less parity rootfs is not
  the shipped image, so measuring it is a vacuous pass; the skip logs a `log_warn`
  naming the reason rather than passing quietly.
- **`DRY_RUN=1` never reaches it** — the orchestrator `exit 0`s at `[5/9]`. This is
  placement, not a condition, so the PR gate (which is DRY_RUN plan-only) still
  cannot see this stage. Same blind spot as `[6b/9]`: every fix here needs a static
  guard.
- **The budget rule has exactly one implementation.** The stage invokes
  `measure-size.sh` and propagates its exit status through `die`; it does not
  re-derive the comparison. The CI synthetic-fixture job is retained unchanged as an
  independent fast proof of the gate's own pass/fail legs — `[6c/9]` complements it,
  it does not replace it.

Guards: `manifest.bats` §10 "size-gate wiring:" — the shipped `[6c/9]` block is
extracted from `orchestrate.sh` and EXECUTED against synthetic KB-sized trees
(pass leg, abort leg, spy-proven silent-skip refusal, stage ordering, DRY_RUN
unreachability), plus a policy guard that no board's ceiling may be raised above
1,500,000,000.

**157.6 MB of Mesa software-GL is `RemoveFiles=`d, and the DRI "blob" is 43
hardlinks to ONE file** [EXISTS]

`gstreamer1.0-plugins-bad` hard-`Depends:` its way to `libgl1-mesa-dri`, whose
Gallium software rasterizer links LLVM's JIT, which links Z3:
`libLLVM-15.so.1` (111,631,520 B) + `libz3.so.4` (22,090,928 B) + the DRI
megadriver (23,915,168 B) = **157,637,616 B** the device can never execute.
`apt remove` is off the table — it cascades into the plugin set cerastream needs —
so `mkosi.images/runtime/mkosi.conf` strips the files instead, on the same
`RemoveFiles=` key as the Task-19 locale strip, in the layer that installs
`shared.list`.

- **Unreachable, four ways.** `libmali-valhall-g610-*` ships
  `/etc/ld.so.conf.d/00-aarch64-mali.conf`; the `00-` prefix sorts first, so
  `ld.so.cache` resolves `libEGL.so.1` / `libGLESv2.so.2` / `libgbm.so.1` to the
  Mali vendor stubs and Mesa's `libEGL_mesa`/`libgbm` — the two libraries that
  `dlopen` a DRI driver — are never reached. The one soname Mali does NOT override,
  `libGL.so.1`, loads its driver inside `libGLX_mesa` at GLX context creation, and
  the image ships no X server or Xwayland. Across the whole rootfs,
  `libLLVM-15.so.1` is `NEEDED` by the DRI links and nothing else, and
  `libz3.so.4` by `libLLVM-15.so.1` and nothing else. cerastream instantiates no
  GL element (its WebRTC preview tier is `webrtcbin`+`nicesrc`); of 263 shipped
  plugins only `libgstnvcodec.so` links `libgstgl`, and `libgstopengl.so` is not
  installed at all.
- **The DRI directory is ONE inode under 43 names.** Mesa builds a single Gallium
  megadriver and hardlinks it as `swrast_dri.so`, `rockchip_dri.so`,
  `panfrost_dri.so`, `armada-drm_dri.so` and 39 more. Removing "just the software
  rasterizer" frees **zero** bytes; the 23.9 MB is released only when every link
  goes. That is why the glob covers the whole set — and it costs nothing extra,
  because once `libLLVM-15.so.1` is gone a `dlopen` of any of them already fails.
- **The glob is `dri/*_dri.so`, NEVER `dri/*`.** `libva` resolves VA-API drivers as
  `<name>_drv_video.so` out of that same directory, so widening it would delete a
  future hardware video driver — exactly the `intel-media-va-driver-non-free` the
  x86 path needs. The `aarch64-linux-gnu` prefix additionally makes the entry a
  strict no-op on non-arm64 families.
- **Board-proven, during a LIVE stream.** On a Rock 5B+ the same paths were deleted
  from the running bench rootfs and the board rebooted: it boots, CeraUI answers on
  :80 and :443, a stream starts/stops cleanly with the same bonded-link count and
  the same uplink byte volume, `gst-inspect-1.0` still reports 264 plugins / 1548
  features, and no process maps `libLLVM`/`libz3`/a DRI driver/any GL object. `df`
  on that real ext4 rootfs dropped 157,634,560 B — a third independent measurement
  agreeing with the tar sums.

Guards: `manifest.bats` §28 (entries present; the `dri/*` widening rejected; the
locale strip not clobbered by sharing the key; the packages never `apt remove`d).
Full ledger: [`v2/docs/size-notes.md`](v2/docs/size-notes.md) §9.

**OTA-during-stream guard — refuses to update while a stream is live** [EXISTS]

`/usr/local/bin/ceralive-update` (generated by
`postinst-lib.sh::setup_data_persistence`, invoked by CeraUI
`system.startUpdate()`) installs the RAUC bundle named by `BUNDLE_URL` in
`/data/ceralive/update.conf`. Before it touches RAUC it bails if any active unit
in its stream-guard list is running — `systemctl is-active --quiet` (so a
stopped OR not-installed unit reads `inactive` and never blocks). The list
**must** cover all three live-media units:
`cerastream.service` (encoder), `srtla.service` (bonding RECEIVER), and
`srtla-send.service` (bonding SENDER). The sender unit was missing — a device
mid-broadcast through the bonding sender could be updated out from under the
stream; the guard now checks `srtla-send.service` too. Don't drop the receiver
check: a single image runs either role. Proof: `v2/run-tests` section 16.

**`/data` migration MUST seed the `public` frontend symlink — else `/` 404s** [EXISTS]

`postinst-lib.sh::setup_data_persistence` generates `ceralive-migrate-data`, whose
first-boot seeding loop copies the CeraUI working dir (`/opt/ceralive`) onto
`/data/ceralive` BEFORE the `/data/ceralive:/opt/ceralive` bind mount shadows it.
The CeraUI `.deb` ships the frontend static tree at `/var/www/ceralive` and an
ABSOLUTE symlink `/opt/ceralive/public -> /var/www/ceralive`
(`CeraUI` `build-debian-package.sh`). The loop MUST seed `public` alongside
`*.json`/`revision`: once the bind mount activates, `/opt/ceralive/public` is the
`/data/ceralive/public` entry, so if `/data` never got one the symlink is gone and
CeraUI serves the frontend from a missing dir — `curl http://<device>/` returns 404
while `/status` stays healthy (confirmed on real hardware). `cp -a` copies the
symlink ITSELF (never the `/var/www` asset tree — those stay on the rootfs so
image/OTA updates keep tracking); the loop's `[ -L ]` guards keep it symlink-aware
(a target-absent link isn't skipped as a source, an existing `/data` entry isn't
clobbered on a re-run / A-B swap). Because the link is absolute and `/opt/ceralive`
and `/data/ceralive` sit at the same depth, it resolves identically post-bind. This
is DISTINCT from the systemd ordering-cycle fixes — a content bug the graph check
cannot see. Offline guard: `v2/tests/data-persistence-public-symlink.test.sh`
(static contract on the seeding block + a runtime reproduction that seeds a
synthetic tree and proves the symlink is preserved, resolves after the bind mount,
is idempotent, and never clobbers an existing entry). Wired into `v2/run-tests`.

**`/etc/resolv.conf` MUST be the systemd-resolved stub symlink — else DNS is
totally dead** [EXISTS]

`postinst-lib.sh::configure_networking` writes
`/etc/NetworkManager/conf.d/ceralive.conf` with `dns=systemd-resolved`, so
NetworkManager DELEGATES DNS to systemd-resolved (forwards the DHCP-received
servers over D-Bus, never writing `/etc/resolv.conf` itself). systemd-resolved
only manages `/etc/resolv.conf` when that path IS the symlink to its stub
`/run/systemd/resolve/stub-resolv.conf`; on a plain regular file it reports
`resolv.conf mode: foreign` and stands down (its designed safety behavior). This
minimal mkosi rootfs never ran systemd-resolved's postinst trigger /
`dpkg-reconfigure`, so it ships `/etc/resolv.conf` as an empty 0-byte REGULAR
file — with delegation on and resolved refusing a foreign file, NOTHING ever
populates it and every glibc/`getent`/`curl` lookup fails with zero working DNS
despite a valid IP, gateway, and DHCP-supplied server (confirmed live on
hardware: `resolvectl status` shows the server + `mode: foreign`, `getent hosts
www.google.com` exits 2, and CeraUI logs constant `DNS timeout for
wellknown.belabox.net` / `Failed to resolve www.gstatic.com` health-check
failures). `configure_networking` now runs `ln -sf
/run/systemd/resolve/stub-resolv.conf /etc/resolv.conf` right after the
`dns=systemd-resolved` drop-in (same delegation contract); `-sf` is
force+idempotent, so it fixes the empty file, a stale link, or an
already-correct link, safe on every build and A/B slot swap. This is a content
bug the `systemd-ordering-cycle` graph check cannot see. Offline guard:
`v2/tests/resolv-conf-symlink.test.sh` (static contract on the
`configure_networking()` body + a rootless-namespace runtime reproduction that
seeds the exact 0-byte-regular-file bug state, runs the real function, and proves
the result is the stub symlink — resolves through it, is idempotent, and
force-replaces a stale link). Wired into `v2/run-tests`.

**Six stock units must be MASKED (never merely disabled) — they cost every boot
2 of its 2min 6s and kept the device permanently `degraded`** [EXISTS]

Root-caused on a shipped Rock 5B+ running the PRODUCTION vendor-BSP image on
2026-08-04. `systemd-analyze time` read **`3.925s (kernel) + 2min 2.744s
(userspace)`**, and the userspace half was almost entirely one unit that can never
succeed. Two more units failed on every single boot for structural reasons, and a
fourth blocked `multi-user.target` on an NTP convergence nothing waits for. All
four defects are stock-Debian defaults this repo never asked for; none is fixable
by a package removal, and — the trap that makes this its own KEY FACT — **none is
fixable by `disable_service` either.**

**The 2-minute stall: `systemd-networkd-wait-online.service`.** NetworkManager is
this image's only network stack; no `.network` file ships anywhere, so
`systemd-networkd` manages **zero** links while NM owns everything:

```
networkctl list       ->  lo / eth0 / wlan0 — all "unmanaged"
nmcli device status   ->  eth0  ethernet  connected

journalctl -u systemd-networkd-wait-online.service -b
  16:40:42  Starting systemd-networkd-wait-online.service...
  16:42:42  Timeout occurred while waiting for network connectivity.
  16:42:42  Failed to start systemd-networkd-wait-online.service
```

Exactly 2:00 — the binary's hardcoded default `--timeout=120s` — with the network
fully up. The cost is not the unit, it is `network-online.target`:
`systemctl list-dependencies network-online.target` shows BOTH
`NetworkManager-wait-online.service` and `systemd-networkd-wait-online.service`,
and a target only becomes active once EVERY ordering dependency has reached a
terminal state — **failure counts**. So the target waited on the slower of the two:

```
systemd-analyze critical-chain graphical.target
graphical.target @2min 2.707s
└─multi-user.target @2min 2.707s
  └─nginx.service @2min 2.593s +112ms
    └─ceralive-tls-firstboot.service @2min 2.357s +225ms
      └─ceralive-hostname.service @2min 1.366s +983ms
        └─network-online.target @2min 1.362s
          └─NetworkManager-wait-online.service @11.026s +8.261s
            └─NetworkManager.service @10.307s +714ms
```

The ~100-second gap between `NetworkManager-wait-online` finishing at **19.3s** and
the target activating at **2min 1.362s** IS the hidden networkd timeout — it does
not appear in the chain because the chain prints the slowest *reached* edge, not the
failed one. **This delayed the product itself, not just SSH:**
`systemctl show ceralive.service -p After -p Wants` carries
`ceralive-hostname.service`, which cannot START until `network-online.target`, so
the operator could not reach the CeraUI web UI on port 80 AT ALL for two minutes
after power-on.

**Why `disable` is the WRONG tool, and this is the load-bearing part.** Nothing in
this repo enables networkd. `/etc/machine-id` ships holding the literal string
`uninitialized` (14 bytes, confirmed in the built rootfs), so **every freshly
flashed board is a systemd FIRST BOOT and PID 1 runs `preset-all`** — which
re-applies the vendor presets over anything the build merely disabled. Worse,
Debian's own `90-systemd.preset` contradicts itself and loses:

```
enable systemd-networkd.service              # line 20
disable systemd-networkd-wait-online.service # line 38
```

The `disable` verdict is overridden, because `systemd-networkd.service`'s
`[Install]` carries `Also=systemd-networkd-wait-online.service` and `Also=` is
applied **unconditionally** by `enable`. That is why a preset that explicitly
disables wait-online still ships it enabled. `systemctl enable` REFUSES to act on a
masked unit, so a mask is the only build-time suppression that survives first boot —
and masking `systemd-networkd.service` **itself** (not just wait-online) is what
makes that `Also=` unreachable at the source. This is the same class of trap as
`configure_ssh_enablement` (where the base-layer preset means a production image must
actively disable, not merely skip the enable) — one notch worse, because here even an
active disable is not enough.

**Masking networkd does NOT touch interface naming.** The `.link` files
`install_interface_naming` writes are consumed by udev's **built-in
`net_setup_link`**, which lives in `systemd-udevd` and is a completely separate
mechanism from whether the networkd DAEMON runs. `eth0`/`wlan0` renaming — and
therefore SRTLA's `eth*`/`wlan*` bonding globs — are unaffected. Do NOT widen this
to `NetworkManager`, `systemd-resolved` or `systemd-udevd`.

**`systemd-machine-id-commit.service` fails forever because of OUR OWN bind mount.**
The obvious reading — "this image's `/etc/machine-id` is a plain file on the real
rootfs, so the unit is inert" — is wrong, and the unit's own condition proves it:

```
[Unit]
ConditionPathIsReadWrite=/etc
ConditionPathIsMountPoint=/etc/machine-id
```

A plain file would SKIP the unit silently. It ran and failed:

```
16:40:47  Starting systemd-machine-id-commit.service...
16:40:49  Main process exited, code=exited, status=1/FAILURE
16:40:50  systemd-machine-id-setup[426]: /etc/machine-id is not on a temporary file system.
```

…because `postinst-lib.sh::setup_data_persistence`'s generated
`ceralive-migrate-data` does `mount --bind "$DATA/ceralive/machine-id"
/etc/machine-id` to keep host identity stable across A/B slots. That bind mount
SATISFIES `ConditionPathIsMountPoint`, the unit starts, and
`systemd-machine-id-setup --commit` then correctly refuses because the bind SOURCE
is real ext4 on `/data`, not a tmpfs. The unit exists solely to persist a machine-id
an initrd generated on tmpfs; this image's persistence model is the bind mount, so
the unit is structurally guaranteed to fail on every boot, forever. Note
`ceralive-hostname.service` keeps its historical
`After=systemd-machine-id-commit.service` — that edge was ALREADY vacuous (it was
ordering after a unit that always failed), and the real machine-id guarantee comes
from `ceralive-migrate-data.service`, which is in the same `After=` list.

**`dnsmasq.service` is the STANDALONE Debian unit, and it is NOT the hotspot's
dnsmasq.** It always loses port 53 to `systemd-resolved`, which owns it by design
(the `/etc/resolv.conf` stub-symlink architecture directly above):

```
Loaded: loaded (/lib/systemd/system/dnsmasq.service; enabled; preset: enabled)
Active: failed (Result: exit-code)
dnsmasq: failed to create listening socket for port 53: Address already in use
```

The first-boot WiFi provisioning portal is unaffected: NetworkManager spawns its
**own dnsmasq CHILD PROCESS** for `802-11-wireless.mode ap` + `ipv4.method shared`,
reading `/etc/NetworkManager/dnsmasq-shared.d` — it never starts this unit. The
`dnsmasq` package stays in `shared.list` precisely so that child still has its
binary; masking the unit is deliberately NOT a package removal. **Do not "restore"
`dnsmasq.service` believing it drives the hotspot.**

**`chrony-wait.service` blocks `multi-user.target` for 21s on a wait nothing needs.**
`systemd-analyze blame` put it at `21.092s`, the second-largest single unit and the
tallest remaining pole once the networkd stall is gone:

```
16:40:52  Starting chrony-wait.service - Wait for chrony to synchronize system clock...
16:41:13  Finished chrony-wait.service
```

Its `ExecStart` is `chronyc waitsync 0 0.1 0.0 1` (`TimeoutStartSec=180`) and it is
`WantedBy=multi-user.target`. **Nothing on this device orders itself after
`time-sync.target` or `chrony-wait.service`** — verified across the whole tracked
tree: not `ceralive-tls-firstboot.service` (which generates the per-device
self-signed cert with a plain `openssl req -x509 -days 3650`, no `-not_before`), not
`ceralive-healthcheck.service`, not `cert-rotation.service`, not
`rauc-hawkbit-updater.service`, not `nginx.service`, not `ceralive.service`. Be
precise about what is being given up: the cert today *happens* to be generated after
the clock synced ONLY because the 2-minute networkd stall pushed
`ceralive-tls-firstboot` out to 2min 2.357s — an ACCIDENT of the very defect being
fixed here, not a contract, since there is no ordering edge between the two units.
Masking therefore removes no guarantee that ever existed. `chronyd` itself is
untouched, still enabled by `configure_services`, and still steps the clock
(`makestep 1 3` in `customize/ceralive-ntp.conf`). **Never mask `chrony.service`** —
only its boot-blocking `chrony-wait` sibling. RAUC bundle signature verification IS
time-sensitive, but it is an on-demand OTA operation, not a boot one.

**The fix.** `postinst-lib.sh::suppress_unusable_boot_units` (called from
`configure_services`, via a new `mask_service` helper beside
`enable_service`/`disable_service`) masks all six:
`systemd-networkd.service`, `systemd-networkd.socket`,
`systemd-networkd-wait-online.service`, `systemd-machine-id-commit.service`,
`dnsmasq.service`, `chrony-wait.service`. `mask_service` then **verifies** the
resulting `/etc/systemd/system/<unit> -> /dev/null` symlink and `die`s if it is
absent — a mask that silently did not land would put the defect straight back into
the fleet on an image that otherwise builds, boots and passes every other gate. No
`mkosi.postinst.chroot` line is added (it stays at 925 against the drift gate's 950
ceiling); `suppress_unusable_boot_units` + `mask_service` are registered in
`postinst-drift-check.sh`'s `CONSOLIDATED_FUNCS`.

Expected improvement: the ~100s networkd stall and the 21s chrony-wait both leave
the boot path, so `graphical.target` should land near **~20s instead of 2min 6s**,
with CeraUI on :80 reachable at roughly the same point rather than two minutes in,
and `systemctl is-system-running` reading `running` instead of `degraded`.
**Not yet boot-proven on hardware** — the masks are verified present in the built
artifact, but the timing claim above is a prediction until a board boots it.

Verified in the real emitted rootfs (not merely "the postinst ran"): all six mask
symlinks are present under `./etc/systemd/system/` in the `rock-5b-plus` build tar.
Guards: `manifest.bats` §18e (6 tests — all six masked to `/dev/null`, the `Also=`
resurrection path closed, mask-not-disable, the fail-closed leg proving a
non-landing mask ABORTS the build, an exact masked-unit count of 6 that refuses to
widen to NetworkManager/resolved/udevd/`chrony.service`, and the
`configure_services` wiring).

**PASETO device-token PUBLIC key provisioning (ADR-0006 D2)** [EXISTS]

`setup_paseto_public_key` (in `customize/postinst-lib.sh`, called by the runtime
`mkosi.postinst.chroot`) bakes the device-token verification key into the CeraUI
backend runtime env so the device can VERIFY device-control / relay-config tokens.

- **What it writes** — an ADDITIVE systemd drop-in
  `/etc/systemd/system/ceralive.service.d/20-paseto-public-key.conf` with
  `Environment=PASETO_PUBLIC_KEY=<raw-base64 Ed25519 public key>`. The drop-in is
  additive to the `ceralive.service` unit shipped by the CeraUI `.deb`, exactly
  like `10-data-persistence.conf`. CeraUI reads `PASETO_PUBLIC_KEY` at startup
  (`apps/backend` `device-token.ts` `DEVICE_TOKEN_PUBLIC_KEY_ENV`); its **presence**
  gates real Ed25519 verification (absent → CeraUI runs the MVP opaque-token path,
  so a key-less dev/local build still boots).
- **Secret is env-only, base64-encoded** — `PASETO_PUBLIC_KEY_B64`, mirroring the
  `APT_*_B64` / `ADDON_KEYRING_B64` pattern: orchestrator-forwarded
  (`lib/orchestrate.sh` `env_names` + `PassEnvironment` in `mkosi.conf`), decoded
  once at chroot time. The decoded payload is the raw-32-byte Ed25519 PUBLIC key in
  standard base64 — the `paseto.public.raw.b64` form `cert-work/paseto/gen-keys.sh`
  emits and CeraUI's `importEd25519PublicKey()` consumes. There is **NO committed
  default**; CI injects it. With no env var the step is a graceful no-op.
- **PUBLIC ONLY** — a `k4.secret` (PASERK private) or any PEM `PRIVATE KEY` slipped
  into `PASETO_PUBLIC_KEY_B64` **FAILS the build**. The device only ever verifies;
  baking a private key would let a compromised device FORGE tokens. Proof:
  `v2/run-tests` section 18 (bakes the key, refuses k4.secret/PEM, no-env skip,
  and the cross-repo env-name lockstep against CeraUI's gate).
- **Operator runbook + encoding verifier** — the end-to-end provisioning procedure
  (generate one Ed25519 keypair per environment; route the THREE values — `(a)`
  PASERK `k4.secret` → platform `PASETO_SIGNING_KEY`, `(b)` PASERK `k4.public` →
  platform `PASETO_PUBLIC_KEY`, `(c)` raw-base64 → image-build `PASETO_PUBLIC_KEY_B64`)
  lives in [`docs/paseto-key-provisioning.md`](docs/paseto-key-provisioning.md).
  `v2/lib/verify-paseto-key-encodings.sh` proves `(b)` and `(c)` decode to the **same**
  32-byte public key AND that `setup_paseto_public_key` bakes the build input into the
  drop-in with zero drift (reading PUBLIC files only; never the `k4.secret`).
  `--self-test` (ephemeral keypair, no secrets) is the `v2/run-tests` section-21 gate.

**avahi-daemon restart hardening — else a single mDNS crash kills `<hostname>.local`
until reboot** [EXISTS]

Stock Debian's `avahi-daemon.service` ships **NO `Restart=` directive**, so ANY
signal or crash leaves `avahi-daemon` — and therefore `<hostname>.local` mDNS —
permanently dead until the next reboot. Confirmed live on real hardware
(`journalctl -u avahi-daemon`): the daemon was killed by SIGUSR2 (`Main process
exited, code=killed, status=12/USR2` → `Failed with result 'signal'`), and
`systemctl show avahi-daemon -p NRestarts` read `NRestarts=0` — no restart policy
was active. Operators reach the device by `<hostname>.local` (`docs/FIRST-BOOT.md`
+ the deterministic first-boot unique-hostname service), so mDNS staying up is a
device-reliability requirement. `setup_avahi_restart` (in `customize/postinst-lib.sh`,
called from the runtime `mkosi.postinst.chroot`) bakes an ADDITIVE drop-in
`/etc/systemd/system/avahi-daemon.service.d/10-ceralive-restart.conf` with
`Restart=on-failure` + `RestartSec=2`, installed from the committed standalone
artifact `v2/mkosi/runtime/avahi-daemon-restart.dropin.conf` (the SAME
standalone-artifact + `postinst-lib.sh` setup-function idiom as the nginx TLS
drop-in, never inlined in `mkosi.postinst.chroot` per the drift-gate ceiling).
`on-failure` (not `always`) so a deliberate `systemctl stop` still stops it. This
is the systemd-level **defense-in-depth** layer only — the signal SOURCE (a CeraUI
udev rule's overly-broad `pkill -f ceralive` catching avahi-daemon) is the
ROOT-CAUSE fix, handled separately in the CeraUI repo. Guard: `manifest.bats`
"avahi restart: an additive Restart=on-failure drop-in is baked …" (+ fail-closed
+ executor-wiring cases).

**`net-tools` in `shared.list` — else the CeraUI Network destination is TOTALLY
empty** [EXISTS]

CeraUI's backend (`ceralive.service`) shells out to the legacy `ifconfig` binary
every ~5s (`apps/backend/src/modules/network/network-interfaces.ts`
`run("ifconfig", [])`) to build the `netif` broadcast
(WiFi/Ethernet/cellular/bonded-link status shown on the Network destination). This
minimal Debian bookworm image ships only modern `iproute2`, NOT `net-tools`, so
every poll tick failed since boot (`{"level":"error","msg":"Error getting ifconfig:
Executable not found in $PATH: \"ifconfig\""}`, confirmed live on real Rock 5B+
hardware). That is the root cause of the Network destination rendering completely
empty ("No WiFi interfaces found", "No wired interfaces found", "No SIM cards
detected", "No active links yet") AND the missing Ethernet row in "Bonded Links"
(`BondedLinksSection.svelte` renders an `ethernet`-typed link fine — its input array
is just empty upstream) despite a live, connected Ethernet + WiFi. The fix is one
line — `net-tools` in `v2/manifests/packages/shared.list` (next to `iproute2`,
arch-independent, every board), NOT a rewrite of `network-interfaces.ts` onto `ip`:
CeraUI's `ifconfig` text-parsing is deeply embedded across its test suite
(`MONITOR-NOTES.md`, `netif-migration`/`netif-same-subnet` tests, `mocks/providers/
network.ts`), so swapping binaries is a large unrelated risk — adding the one legacy
binary is correctly scoped. Guards: `manifest.bats` "runtime packages: net-tools is
installed …" + "… reaches the resolved runtime package set …".

**`bluez` in `shared.list` — the Bluetooth KERNEL half already worked; the whole
gap was userspace** [EXISTS]

Same class as the `net-tools` and `iw` entries below: one missing userspace
package silently disabled a whole hardware feature, and the kernel-side
investigation that "found nothing" was a false negative. On a Rock 5B+ the
RTL8852BE's Bluetooth radio enumerates as **USB `13d3:3572`**, `btusb`+`btrtl`
bind it, `/sys/class/bluetooth/hci0` exists and `rfkill` lists it — all correct,
with `CONFIG_BT_HCIBTUSB=m` + `CONFIG_BT_RTL=m` already in the resolved config.
What was missing is entirely userspace: with no `bluez` there is no
`bluetoothd`, `systemctl status bluetooth.service` answers *"Unit
bluetooth.service could not be found"*, and there is no `bluetoothctl`/`btmgmt`,
so the adapter can never be powered up or paired. `libbluetooth3` was present
only as an unrelated package's transitive dependency, which is why
`dpkg -l | grep blue` looked deceptively non-empty.

**This is NOT an edge-kernel regression** — the vendor-BSP images have the same
gap, because `shared.list` never carried `bluez` on any board.

**Beware the dmesg false negative that hid this.** `dmesg | grep -i bluetooth`
returning nothing was NOT evidence of absence: `CONFIG_LOG_BUF_SHIFT=17` (128 KiB)
and the HDMI-RX driver `dev_err`s `hdmirx_query_dv_timings: port has no link`
every 5 s whenever no HDMI cable is attached, so after a few hours **1638 of 1638
lines in the ring buffer were that one message** and every boot-time line had been
evicted. Use `journalctl -k`, `/sys/class/bluetooth/`, and `lsmod` — never a bare
`dmesg` grep — to decide whether a driver bound on this board. Guard:
`manifest.bats` "runtime packages: bluez is installed so the Bluetooth adapter is
usable".

**`iw` in `shared.list` — `wireless-tools` is NOT the same package** [EXISTS]

The same class of gap as `net-tools` above, one layer over. `wireless-regdb` was
already an explicit entry (so the kernel loads `/lib/firmware/regulatory.db`), but
nothing could ever SELECT a regulatory domain: CeraUI applies the operator's
country with `iw reg set <CC>` and then reads the AP-usable hotspot channels back
out of `iw phy` (`apps/backend/src/modules/wifi/regdomain.ts` — the channel list is
derived from the kernel, never from a country→channel table). `iw` is the nl80211
tool and is its OWN Debian package.

The trap is the name: `wireless-tools` reads like it covers this and does not — it
ships only the legacy WEXT binaries (`iwconfig`, `iwlist`, `iwgetid`, `iwpriv`,
`iwspy`, `iwevent`), which was confirmed against the built rootfs
(`v2/mkosi/build/app/usr/sbin/`). Nothing else in `shared.list` depends on `iw`
either, so absent an explicit entry the regulatory country silently cannot be
applied and the hotspot stays on the conservative world domain (2.4 GHz channels
1-11 only — no channel 12/13 in ETSI countries). Guard: `manifest.bats` "runtime
packages: iw is installed so the regulatory domain can be applied".

**Baked mTLS client key MUST be `_apt`-owned, exactly ONE Debian source, AND an
arch-qualified apt.ceralive.tv URI — else on-device `apt-get update` is 100% broken** [EXISTS]

The device apt config (`mkosi.postinst.chroot::setup_ceralive_repository` +
`configure_minimal_apt`, twinned in `customize/apt-ceralive-repo.sh`) had three
device-runtime bugs, confirmed live on real Rock 5B+ hardware:

- **mTLS client KEY unreadable by apt's sandbox.** The key was baked
  `root:root` mode `0600`, but apt runs its https fetcher as the sandbox user
  `_apt` (`APT::Sandbox::User "_apt"`, uid 42/group nogroup) — which cannot read a
  root-owned `0600` file. `apt-get update` failed `Err … apt.ceralive.tv … Could
  not load client certificate (/etc/apt/certs/client.crt, SslCert option) or key
  (…client.key, SslKey option): Error while reading file` (the cert/key PAIR was
  valid + matched — a pure permission bug, not missing/corrupt/wrong-path). Fix:
  `chown _apt:root /etc/apt/certs/client.key` + `chmod 400` (owner-read only); the
  public `client.crt` stays `644 root:root`. Do NOT weaken `APT::Sandbox::User` to
  `root` — that disables apt sandboxing fleet-wide. The BUILD-time fetcher
  (`lib/fetch-debs.sh::fetch_first_party`) carried exactly that override and no
  longer does; see the build-time apt-sandbox bullet in the "First-party .deb
  fetch" KEY FACT above for the privilege-aware replacement.
- **Duplicate Debian source.** mkosi's own release-named bootstrap source
  (`/etc/apt/sources.list.d/${RELEASE}.sources` = `bookworm.sources`, with
  `deb-src` + `bookworm-debug`) leaks into the base rootfs and is inherited down
  base→platform→runtime→app, duplicating the canonical `debian.sources` and making
  apt warn `Target Packages … is configured multiple times`. `configure_minimal_apt`
  now `rm -f`s `${RELEASE}.sources` (+ `armbian.sources` + legacy `sources.list`)
  before writing `debian.sources`, so the device ships EXACTLY ONE Debian source.
  Runtime-layer removal suffices: the app layer inherits the runtime tree
  (`BaseTrees=%O/runtime`) and installs first-party `.deb`s with local `dpkg`
  WITHOUT re-bootstrapping apt repo metadata (`app/mkosi.conf`), so it never
  regenerates the stray. The apt.ceralive.tv origin-990 pin is untouched.
- **Non-arch-qualified apt.ceralive.tv URI (404 on Release).** `setup_ceralive_repository`
  wrote `ceralive.sources` `URIs: …/dists/${CHANNEL}/` — but apt-worker serves the
  first-party repo at `…/dists/${CHANNEL}/binary-${arch}/` (flat `Suites: ./`).
  The bare URI made apt fetch `dists/stable/./Release` → `404 Not Found` → `E: The
  repository … does not have a Release file`, so no origin-990 index ever loaded
  (masked until the mTLS fix let the request reach the origin). The URI is now
  `…/dists/${CHANNEL}/binary-$(dpkg --print-architecture)/`, matching the
  known-working `fetch-debs.sh::fetch_first_party` and the customize module twin
  (which already carried the arch axis — a postinst-vs-module drift, same class as
  the origin-pin drift the `apt-preferences-baked` guard catches).

Guard: `v2/tests/apt-mtls-and-dedupe.test.sh` (Part A static: BOTH tracks
`chown _apt` the key + `rm` the `${RELEASE}.sources` dupe + arch-qualified
`binary-<arch>/` URI + no lingering root-owned `0600` key; Part B rootless-namespace
runtime: the real `configure_minimal_apt` leaves exactly one Debian source), wired
into `v2/run-tests` and `manifest.bats §22` "the build path makes client.key
_apt-readable and dedupes Debian sources".

**The boot stack is frozen against on-device apt — dpkg holds are PRIMARY, the apt
pin is supplementary, and RAUC consults NEITHER** [EXISTS]

`docs/partition-contract.md` §1 rule 3 ("Kernel rides with the rootfs") makes
kernel/DTB/initrd part of a RAUC **slot**, so the only sanctioned way to change them
is writing a whole new slot. Nothing enforced that: the shipped image carried **zero
dpkg holds**, so an `apt-get upgrade` on a running device would replace the kernel
underneath a slot the A/B selector had already committed to — leaving the rollback
target a slot whose kernel nobody tested, with modules, DTBs and the initramfs hook
output all half-swapped mid-uptime.

`postinst-lib.sh::freeze_boot_packages` (called LAST in the runtime executor's
`main()`, after every apt transaction that layer performs) bakes two layers:

- **`apt-mark hold`** on each package — the primary mechanism. It lands in
  `/var/lib/dpkg/status` as `Status: hold ok installed`, and it is the only one of
  the two that also blocks the **explicit** `apt-get install <pkg>` form. The build
  VERIFIES each hold against `apt-mark showhold` and `die`s if one did not land —
  same fail-closed discipline as `mask_service`, for the same reason (a silently
  unapplied hold ships an apt-upgradable kernel on an image that passes every other
  gate).
- **`/etc/apt/preferences.d/ceralive-kernel-freeze`** — one `Package:` / `Pin:
  version <installed>` / `Pin-Priority: 1001` stanza per package.

**The pin is name+version, NOT origin, and that is forced rather than chosen.** The
boot BSP is installed from mkosi's LOCAL, build-time-only `file:/repository`, which
does not exist on the shipped device — those packages carry no apt-origin identity
there at all, so no `Pin: origin …`/`Pin: release …` expression can designate "the
staged local set". Do not "improve" this into an origin pin like the
`apt.ceralive.tv` 990 one; it would match nothing. **The pin is bypassable and that
limitation is documented in the generated file itself**: `apt-get install
<pkg>=<version>`, `--allow-downgrades`, `-o Dir::Etc::Preferences=`, and `dpkg -i`
all ignore apt preferences. That is exactly why the hold is primary.

**RAUC does not consult dpkg holds, and must not be expected to.** It never runs
dpkg or apt — it `mkfs`es and writes the whole **inactive** slot, so the running
slot's holds are not on its code path and a held kernel neither blocks nor filters
an install. Because the kernel rides inside the rootfs, the new slot arrives with
its OWN `/var/lib/dpkg/status` carrying the holds ITS build baked, and those govern
that slot's apt from its first boot. **Each image freezes itself** — the freeze is
not fleet state an update has to preserve, migrate or re-apply, and there is nothing
to unhold before an update or re-hold after one.

**The freeze set is manifest-resolved (`KERNEL_PACKAGES`/`DTB_PACKAGES`/
`UBOOT_PACKAGES`/`FIRMWARE_PACKAGES`), never hardcoded** — the U-Boot package name
differs per board (`linux-u-boot-rock-5b-plus-vendor` vs
`linux-u-boot-orangepi5-plus-vendor`), so a literal list would freeze one board
only, and a `--variant` build's source-built kernel package is picked up
automatically. Those four names are already on the `orchestrate.sh` `env_names` ↔
`mkosi.conf` `PassEnvironment=` lockstep; read empty in the subimage the freeze
would be silently vacuous.

**First-party CeraLive packages are NEVER held** — `cerastream`, `ceralive-device`,
`srtla-send-rs`, `libsrt1.5-ceralive`, `gstreamer1.0-libuvch264src`,
`rauc-hawkbit-updater` and the nine ModemManager closure packages must stay
apt-updatable, because that is the update path CeraUI's `system.startUpdate()`
drives. `CERALIVE_NEVER_FREEZE_PKGS` refuses them **by name before any hold runs**
(a manifest that routed one into a boot-BSP field fails the build), and the function
re-checks the hold list afterwards. **No `unattended-upgrades` is installed**, and
adding one is forbidden: the OS updates through RAUC and the app layer through an
operator-driven apt transaction.

Guards: `v2/tests/kernel-freeze-guardrails.test.sh` (static contract; the real
function against stubbed dpkg/apt-mark for both boards' U-Boot names; four
fail-closed legs — first-party in the set, a hold that does not land, a partial
freeze on a full build, a clean parity-build no-op; and a **real `apt-get -s
upgrade`** against a synthetic apt root offering a newer kernel, with a non-vacuity
leg proving the unfrozen fixture DOES offer it, the hold and the pin each blocking
it independently, and `cerastream` still upgrading with the whole freeze in place)
plus `manifest.bats` §31 (9 structural tests, mutation-verified). Full contract:
[`v2/docs/kernel-freeze-contract.md`](v2/docs/kernel-freeze-contract.md).

**`ceralive.service` ordered `After=cerastream.service` — soft boot-race hint (never
`Requires=`)** [EXISTS]

`ceralive.service`'s boot step `initPipelines()` connects to cerastream's control
socket **exactly once**, so if cerastream isn't up yet the connection fails
permanently for that boot. Confirmed live: `cerastream.service` started ~2 minutes
AFTER `ceralive.service` in one boot instance, and `systemctl show ceralive -p
After` had NO mention of `cerastream.service`. `setup_cerastream_ordering` (in
`customize/postinst-lib.sh`, called from the runtime `mkosi.postinst.chroot`) bakes
an ADDITIVE drop-in
`/etc/systemd/system/ceralive.service.d/30-cerastream-ordering.conf` with
`After=cerastream.service`, installed from the committed standalone artifact
`v2/mkosi/runtime/ceralive-cerastream-ordering.dropin.conf` (the SAME
standalone-artifact + `postinst-lib.sh` setup-function idiom as the avahi/TLS
drop-ins; additive to the `ceralive.service` unit shipped by the CeraUI `.deb`, like
`10-data-persistence.conf` / `20-paseto-public-key.conf`). **ORDERING-ONLY — never
`Requires=`**: `ceralive.service` MUST still boot and serve its "engine unavailable"
degraded state (CeraUI `helpers/boot-guard.ts::guardNonCritical` fail-soft boot
design) if cerastream is ever genuinely absent/masked, and `After=` on an
out-of-transaction unit is a harmless no-op. This is the systemd-level ordering half
only — a CeraUI-side retry/resilience fix for the one-shot connect lands separately
in that repo. Guards: `manifest.bats` "cerastream ordering: an additive
After=cerastream.service drop-in is baked …" + "… is ordering-ONLY (no
Requires=/Requisite=/BindsTo= hard dependency)" (+ fail-closed + executor-wiring
cases).

**Supported-modem matrix + advisory WWAN module-presence check** [EXISTS]

The cellular stack (ModemManager + libqmi/libmbim + usb-modeswitch, SRTLA modem
source-routing, the M.2 SIM quirk, and the known-good modem table) is documented
as-is in [`v2/docs/modem-matrix.md`](v2/docs/modem-matrix.md). That runtime stack
is **not** touched here — the doc only describes it.

Because an upstream repository can replace bytes under the same Debian package
version, a same-version Armbian re-spin could drop one of the six WWAN modules the modem stack
binds to (`qmi_wwan`, `cdc_mbim`, `cdc_wdm`, `option`, `cdc_ether`, `cdc_ncm`)
with no signal. `v2/lib/check-wwan-modules.sh` makes that observable: it inspects
a kernel `.deb` (or an extracted module tree) and reports each module as loadable
(`=m`, a `<mod>.ko` file), built-in (`=y`, in `modules.builtin`), or present via
`modules.alias`.

- Hyphen/underscore aware (the `cdc_wdm` module ships on disk as `cdc-wdm.ko`).
- The `option` module is matched by an exact `option.ko` basename, a
  `…/option.ko` `modules.builtin` entry, or a `modules.alias` module token —
  **never** a bare `option` substring (a known false-positive trap).
- Asserts a `.deb` extractor (`dpkg-deb`, or `ar`+`tar`) before opening a `.deb`.
- **Advisory only**, exactly like the BSP drift-guard: a missing module WARNS but
  the check **always exits 0**. It never fails the build and never edits
  `shared.list` or the kernel config. Proof: `v2/run-tests` section 17.

**ModemManager 1.24 closure — first-party fork, app-layer install** [EXISTS]

The device's core cellular stack is the **CeraLive ModemManager 1.24 fork**
(`~ceralive0.2.0`, modem-stack v0.2.0), not Debian's ModemManager. Nine
ELF-shipping packages — `modemmanager` + `libmm-glib0` + `libmbim-glib4`/`-proxy`/
`-utils` + `libqmi-glib5`/`-proxy`/`-utils` + `libqrtr-glib0` — are staged
first-party (`FIRST_PARTY_APT_PKGS`), exact-pinned in
`v2/manifests/first-party-deb-versions.txt`, and classified `RUNTIME_APP_PKGS` by
the app postinst (`app/mkosi.postinst.chroot`). Their local `dpkg -i` **upgrades**
the Debian modem packages the runtime layer pulled transitively via `shared.list`
(`modemmanager`/`libqmi-utils`/`libmbim-utils` stay there to resolve the full
dependency tree; external deps — GLib/`libgudev`/`polkit`/systemd — come from
Debian). The `Package: *` origin-990 pin keeps the fork winning on-device.
`mobile-broadband-provider-info` (ModemManager's APN database, a `Recommends:`) is
an explicit `shared.list` entry. Full source-of-truth: `v2/docs/modem-matrix.md §1`.
Guards: `manifest.bats §23` (closure membership, RUNTIME_APP_PKGS classification,
exact pins, origin-990 wildcard coverage, DRY_RUN resolution) +
`v2/tests/app-layer-modem-closure.test.sh` (executable install/classification).

**`orchestrate.sh` `[3/9]` partitioner allowlist MUST cover every
`FIRST_PARTY_APT_PKGS` entry.** After the fetcher stages all 14 first-party `.deb`s
into `<staging>/debs/`, the `[3/9]` step in `lib/orchestrate.sh` partitions each
staged `.deb` into BSP vs first-party by an exact package-name allowlist
(`firstparty_names`). A REAL (non-`DRY_RUN`) build `die`s with `unclassified staged
package` if a fetched first-party package is missing from that allowlist. The 9
ModemManager-closure packages were added to `FIRST_PARTY_APT_PKGS` (fetcher) but not
to `firstparty_names` (partitioner), so the first full build after that landed blew
up at `[3/9]` — invisible to CI because the PR gate only runs `DRY_RUN=1` plan-only
builds (the partitioner never runs there). `firstparty_names` now lists all 14. Guard:
`v2/tests/firstparty-classification.test.sh` (sources `FIRST_PARTY_APT_PKGS` from the
fetcher and asserts the partitioner allowlist is a superset). Wired into `v2/run-tests`.

**Fail-closed modem slot-UID naming (`modem_ports`)** [EXISTS]

The board manifest carries an optional `modem_ports` block that gates a udev
generator, `v2/mkosi/customize/udev.sh::generate_modem_slot_uid_rules`. It is
**fail-closed**: while `status: unverified` (the shipped default on every board —
verifying a slot map needs a physical modem on that exact board to read each
slot's real `ID_PATH`) the generator emits **NO** generated
`78-mm-ceralive-slot-uid.rules` and removes any stale one — **no permissive
fallback**. The **permanent generic modem rules** in `setup_hardware_access` (the
"USB Modem Devices (4G/5G)" `dialout` group-tag block) always ship and are NOT
touched. Only when a board is `status: verified` with `slots:` (`modemN` → `ID_PATH`)
does the generator emit one `ENV{ID_MM_PHYSDEV_UID}` rule per slot. The status/slots
reach the runtime subimage chroot via `CERALIVE_MODEM_PORTS_STATUS`/`_SLOTS`
(orchestrate.sh `env_names` ↔ `mkosi.conf` `PassEnvironment=`, same lockstep the
interface-naming vars use). Flipping to `verified` is a separate, hardware-gated
step (`v2/docs/modem-matrix.md §7` discovery runbook) — **do NOT flip it without
reading real hardware ID_PATHs**. Guards: `manifest.bats §23` generator matrix
(unverified ⇒ zero rules; unset ⇒ unverified; verified fixture ⇒ rules emitted;
verified-with-no-slots ⇒ fail-closed; stale-file cleanup; generic-rules-untouched;
env lockstep).

**Stable HDMI-IN capture symlink (`/dev/hdmi-in` + `/dev/hdmirx`)** [EXISTS]

`v2/mkosi/customize/udev.sh::setup_hardware_access` gives the RK3588 SoC HDMI-RX
capture node a persistent, collision-proof name via a `SYMLINK+=` rule keyed on the
parent platform **driver** (`DRIVERS=="rk_hdmirx"`), NOT on the `/dev/videoN` index.
This matters because a USB capture card can grab `/dev/video0` and renumber the SoC
HDMI-RX to a higher index — the enumeration-order conflict a bare node index cannot
avoid. The rule emits BOTH `/dev/hdmi-in` (human-readable) and `/dev/hdmirx`
(cerastream's canonical default HDMI device string, so the engine default resolves to
a real node). It is ADDITIVE: the two existing name-matched HDMI `GROUP="video"`
permission rules are untouched, and the engine still finds the HDMI device by driver
substring (`cerastream driver_is_hdmi_rx`), so the symlink is a stable
operator/diagnostic handle, not a new required routing dependency.

**Why `DRIVERS==`, not `ATTRS{name}==` (#74).** PR #73 first shipped the rule as
`ATTRS{name}=="rk_hdmirx"`. That never matches on real RK3588 hardware: the V4L2
node's sysfs `name` attribute is `stream_hdmirx`, while `rk_hdmirx` is the *driver*
bound to the parent platform device (`fdee0000.hdmirx-controller`). `DRIVERS==`
matches up the parent chain and is the correct key. Verified on device — both
symlinks resolve to the live HDMI-RX node:

```
/dev/hdmi-in -> video0     /dev/hdmirx -> video0
v4l2-ctl -d /dev/video0 --info  →  Driver name: rk_hdmirx
```

Guard: `manifest.bats` "hdmi-in: a driver-keyed SYMLINK rule gives the SoC HDMI-RX a
stable /dev/hdmi-in node" — asserts `DRIVERS==` (and explicitly rejects a re-slip to
`ATTRS{name}==`), not `video0`-pinned, both symlink tokens, and the original
permission rules preserved.

**`snps_hdmirx` fails to PROBE at boot on Orange Pi 5+ — a TF-A/BL31 gap, no
`/dev/video*` HDMI-RX node exists on that board at all** [FINDING — not fixed]

Confirmed live on an Orange Pi 5+ this session (2026-08-08): `snps_hdmirx` never
binds, independent of any HDMI cable or signal being connected, so there is no
HDMI-RX capture node for cerastream or anything else to open. `dmesg` on the
board:

```
snps_hdmirx fdee0000.hdmi_receiver: assigned reserved memory node hdmi-receiver-cma
snps_hdmirx fdee0000.hdmi_receiver: hdmirx_phy_register_read wait cr read done failed
snps_hdmirx fdee0000.hdmi_receiver: error -ETIMEDOUT: interrupt not functioning, open-source TF-A is required by this driver
snps_hdmirx fdee0000.hdmi_receiver: probe with driver snps_hdmirx failed with error -110
```

The driver's own message names the cause: the interrupt path it needs is routed
through an SMC call into ARM Trusted Firmware (BL31), and the board's running
BL31 — `v2.13.0(release):armbian` — apparently does not carry or expose the
support `snps_hdmirx` expects. This is a firmware gap, not a kernel or DT
defect, and it sits upstream of anything in this repo's udev/manifest layer
(the `DRIVERS=="rk_hdmirx|snps_hdmirx"` symlink rule above is correct and
irrelevant here — there is no bound device for it to match).

The same session confirmed the SAME kernel/image family's `snps_hdmirx` probes
and polls **successfully** on a Rock 5B+ — `hdmirx_query_dv_timings port has no
link!` on that board is the expected/healthy "no signal" message, not a probe
failure. Per this file's boot-artifact documentation, each board's ATF/BL31 is
embedded in its own bootloader payload separately (Rock 5B+ ships
`u-boot-rockchip.bin`; Orange Pi ships `idbloader.img` + `u-boot.itb`), with no
shared `trust.bin` — so this narrows the gap to Orange Pi 5+'s own TF-A/BL31
build specifically, not a universal RK3588 or vendor-kernel issue.

This is a FINDING, not a fix: rebuilding ARM Trusted Firmware with the
SMC/interrupt-routing support `snps_hdmirx` requires is out of scope here and
has not been attempted.

**The USB-C connector MUST be pinned to the Type-C `source` role at boot — else the
camera is sometimes not on the USB bus at all** [EXISTS — code merged-ready, NOT in
any shipped release yet]

`/sys/class/typec/port0` is an FUSB302 TCPM connector (`feac0000.i2c/i2c-4/4-0022`)
that drives the DWC3 controller `fc000000.usb` through a `usb-role-switch`. The
device tree describes it as a **DRP** (dual-role) port, so every fresh boot comes up
reading `port_type = [dual] source sink`. A DRP port does not *choose* a role — it
toggles, and the role is settled by Try.SRC/Try.SNK arbitration on the CC lines
against whatever is at the other end of the cable. The capture camera (DJI Osmo
Pocket 3) is dual-role too, so **both** ends toggle and the arbitration is a genuine
race with no stable winner: the TCPM trace
(`/sys/kernel/debug/usb/tcpm-4-0022/log`) shows the port cycling
`SNK_TRY_WAIT -> SRC_TRYWAIT` instead of converging.

When the race lands on **SNK/device role**, the SoC's own controller is running as a
USB *peripheral*. The camera is then not "slow to be detected" — it is *undetectable*:
its bus (`usb9`/`9-1`) is entirely absent from `/sys/bus/usb/devices/`. This is the
mechanism behind the long-standing operator complaint that the camera *sometimes*
isn't detected over USB-C. Confirmed live on a Rock 5B+ repeatedly on 2026-07-30,
including immediately after a genuine cold power-cycle: fresh boot → `port_type`
`[dual] …` → camera absent → `echo source > …/port_type` → camera enumerates in
seconds, full UVC mode switch (`idProduct` 0020→0023), `/dev/video1`+`/dev/video2`
present, `uvcvideo`/`snd-usb-audio` bound. Every single time.

`port_type` is **live sysfs state**: it reverts to `dual` on every reboot, and the
device tree that would otherwise carry the default comes from the Armbian BSP kernel
package (pinned/drift-gated here, not authored here). So the fix has to be applied at
boot. `postinst-lib.sh::setup_typec_source_role` (called from `configure_services`)
installs two committed standalone artifacts under `v2/mkosi/runtime/` —
`ceralive-typec-source.sh` → `/usr/local/sbin/ceralive-typec-source` and
`ceralive-typec-source.service` — and enables the unit.

**Why a systemd oneshot and NOT a udev rule.** A udev rule
(`SUBSYSTEM=="typec", KERNEL=="port0", ATTR{port_type}="source"`) would sidestep the
"has the sysfs path been created yet" race for free, which is genuinely attractive.
It loses on three counts that matter more here:

1. **It cannot express the ordering that is the actual requirement.** The fix must be
   in place before `cerastream.service` opens the capture device; a unit says
   `Before=cerastream.service`, a udev rule can only hope the coldplug wins the race.
2. **It fails silently.** A rejected `ATTR{}` write is a `udevd` log line, not a
   failed unit — the opposite of this image's fail-loud, journal-evidence discipline.
3. **The obvious idempotency guard cannot work, and looks like it does.** The kernel
   prints the *whole menu* with the active entry bracketed — `[dual] source sink` at
   rest, `dual [source] sink` once pinned — so `ATTR{port_type}=="dual"` never
   matches and the rule silently does nothing. (Same trap for a naive
   `[ "$(cat port_type)" = source ]` in a script; the shipped script parses the
   bracket.) On top of that a role change makes TCPM emit `KOBJ_CHANGE` on the same
   device, so an unguarded rule re-triggers itself.

The unit pays for that choice by owning the probe race itself: `port0` is created by
an **asynchronous** fusb302/TCPM probe, so the script **polls to a deadline** (30 s
default, `CERALIVE_TYPEC_WAIT`) — never a fixed settle constant. A board with no
Type-C class at all (x86) and a port that never appears are both clean no-ops; only a
role change that is accepted but does not take (read-back mismatch) fails loudly.

Scope is deliberately ONE attribute on ONE connector: `port0/port_type` ← `source`.
Do **NOT** set `sink` or leave `dual` (`dual` is the broken default; both were settled
by live hardware testing), and do **NOT** extend this to any `dwc3` platform-driver
unbind/rebind — doing that by hand wedges a kernel worker on this board (separate,
confirmed defect). Guards: `manifest.bats` §18d "typec source: …" — install+enable,
`port_type`→`source` (rejecting `sink`/`dual`), `Before=cerastream.service`
ordering-only, the `[dual]`→`source` transition, idempotency against the bracketed
`dual [source] sink`, the bounded wait, fail-loud read-back, fail-closed missing
source, and the `configure_services` wiring. `setup_typec_source_role` is registered
in `postinst-drift-check.sh`'s `CONSOLIDATED_FUNCS`.

**Not yet in a shipped release.** This is code-complete and merged-ready only; it has
not been through this repo's build/flash/release cycle, so no published image carries
it. The persistent version still needs the normal on-hardware board-proof (confirm a
reboot leaves `port_type` pinned and the camera enumerates exactly as the live sysfs
poke did) before it is claimed as shipped.

**The `pwm-fan` cooling device is never ASKED to run below 55 °C — so the fix is to
move ONE trip point, not to take over the fan** [EXISTS — code merged-ready, NOT in
any shipped release yet]

The RK3588 package thermal zone comes out of the device tree with two `active` trips
at 55 °C and 65 °C plus one `critical` trip at 115 °C, and its `pwm-fan` cooling
device (backed by hwmon `pwmfan`) declares
`cooling-levels = <0 120 150 180 210 240 255>`. Read on a live Rock 5B+ on 2026-08-05:
`thermal_zone0` (`package-thermal`) drives `cooling_device4` (`pwm-fan`, `hwmon7`),
and `trip_point_1_temp` is runtime-writable — a live round-trip `55000 → 40000 →
55000` succeeded cleanly. Idle SoC temperature on the same board measured **46-52 °C
at rest**, reaching the low 50s under light load.

So the board is silent through its entire normal operating range and the first thing
an operator hears is the fan snapping on at 55 °C, after heat has already
accumulated. **This is NOT the well-known "cooling-levels start too low to overcome
fan stiction" community defect** — an upstream Rockchip kernel maintainer confirmed
that PWM range reliably spins this fan, and the board's own behaviour agrees. The fan
works. It is simply not asked to run.

`ceralive-fan-curve.service` (a oneshot, installed by
`postinst-lib.sh::setup_fan_curve` from the committed standalone artifacts
`v2/mkosi/runtime/ceralive-fan-curve.{sh,service}`) lowers the FIRST `active` trip of
the zone bound to the `pwm-fan` cooling device to **45000 m°C (45 °C)** — one named,
documented, env-overridable constant (`CERALIVE_FAN_TRIP_MILLIC`), clamped to a
20-90 °C band so a retune can never push a trip up next to `critical`. 45 °C sits just
under the measured idle band on purpose: the fan idles at its lowest cooling level and
keeps a little air moving, instead of staying silent and then becoming audible. Be
honest about the trade — at the bottom of that idle band the fan will be turning most
of the time. That is the intent, and it is why the threshold is a constant rather than
a literal buried in the write.

**The safety property is that the fix reduces to a single sysfs write.** It does NOT
write `thermal_zone*/mode` (disabling a zone would ALSO disable the 115 °C critical
trip — categorically unacceptable), does NOT write `cooling_device*/cur_state` or the
hwmon `pwm1` node, does NOT touch `critical`/`hot`/`passive` trips, and runs no
polling or monitoring loop. It exits, and the kernel's `step_wise` governor does 100 %
of the fan control from that point on — which was live-proven correct on this board:
`cur_state` auto-steps `0 → 1` exactly at a real trip crossing and auto-reverts to `0`
when the temperature falls back. **Move the goalpost; do not replace the referee.**
Re-implementing a working kernel governor in userspace would be strictly more code and
strictly more risk for no gain.

**Discovery is generic, and hardcoding an index is the trap.** `thermal_zoneN` and
`cooling_deviceN` are registration-order artefacts — they differ per board, differ
between the vendor 6.1 BSP and the mainline/`edge` tree, and were confirmed
differently-numbered on real hardware this session. So the script scans
`/sys/class/thermal/cooling_device*/type` for the exact string `pwm-fan`, resolves
every `thermal_zone*/cdevN` symlink to find the binding zone (falling back to reading
`<cdevN>/type` directly), then walks `trip_point_0..` in **numeric** order — a glob
would sort `trip_point_10` before `trip_point_2` — and takes the first whose
`trip_point_N_type` reads exactly `active`. Kernel ABI reference:
`Documentation/ABI/testing/sysfs-class-thermal`.

**Board-agnostic and fail-soft by construction.** No thermal class, no `pwm-fan`
cooling device (x86-minipc, whose ACPI thermal tree is populated but has no such
device), no zone bound to one, or no `active` trip in that zone: informational log,
exit 0. Only ever LOWERS, so re-running is a no-op and a board someone already tuned
cooler keeps its value. A refused write is a **warning**, not a failure — the ABI
documents `trip_point_Y_temp` as "RO, Optional", so a zone with no trip-temperature
setter is a legal configuration and the board simply keeps its stock curve. A write
the kernel **accepts and then ignores** is a different thing and fails loudly, because
by then the exact hardware shape has already been proven present.

Like the Type-C unit, the cooling device is created by an asynchronous platform-driver
probe, so the script polls to a deadline rather than sleeping a fixed amount — but the
deadline is deliberately short (10 s, vs 30 s for Type-C) and the unit is
**deliberately not `Before=` anything**, because a board that will never have a
`pwm-fan` would otherwise pay that wait on the boot critical path.

Guards: `v2/tests/manifest.bats` §18f "fan curve: …" (12 tests). The fixture
deliberately numbers everything DIFFERENTLY from the reference board — `pwm-fan` is
`cooling_device7` (not 4), the zone is `thermal_zone3` (not 0), it hangs off that
zone's `cdev1` behind a CPUFreq `cdev0`, and the first `active` trip is index 1 behind
a `critical` at index 0 — so any hardcoded index fails the suite. It also pins the
critical-never-touched property, a decoy CPUFreq-only zone whose own `active` trip
must not move, the no-`pwm-fan` no-op, idempotency/never-raise, the band clamp, the
loud read-back failure, and the `configure_services` wiring. `setup_fan_curve` is
registered in `postinst-drift-check.sh`'s `CONSOLIDATED_FUNCS`; nothing was added to
`mkosi.postinst.chroot`, which stays at 925 lines against the 950 ceiling.

**Not yet in a shipped release, and not yet boot-proven.** The trip write itself was
proven by hand on real hardware; the unit that performs it at boot has not been
through this repo's build/flash/release cycle. Confirming that a booted board reports
the lowered trip and that the fan audibly idles is the remaining on-hardware step.

**The fan's FIRST active state is 70/255 (~27.5 %) — enough to keep a spinning rotor
spinning, not enough to start a stopped one — and a userspace `cur_state` write is
STICKY, so the nudge MUST hand the governor's own state back** [EXISTS — code
merged-ready, NOT in any shipped release yet]

`setup_fan_curve` above fixed **when** the fan is asked to run. This is the next
problem, and it is a different one: the state it is asked **into** cannot start it
from a dead stop. Read on a live Orange Pi 5 Plus:

```
cooling_device4/type                    -> pwm-fan
cooling_device4/max_state               -> 4
pwm-fan/of_node/cooling-levels          -> 0 70 75 80 100     (out of 255)
hwmon7/name                             -> pwmfan
thermal_zone0/trip_point_1_temp         -> 45000              (fan-curve's fix, active)
```

Five states (0-4), so the FIRST active state — the one the governor enters when the
zone crosses the now-45 °C trip — is `70/255 ≈ 27.5 %` duty. That is a classic
DC-motor stiction asymmetry: sufficient to sustain rotation, insufficient to break
static friction from rest. The fan sits energised and stalled until a fingertip
nudges it, which is exactly the operator's report ("gets stuck, needs a push, then
runs fine").

**This is a real, upstream-acknowledged hardware behaviour with an upstream fix this
kernel does not have.** Current Linux `pwm-fan` grew `fan-stop-to-start-percent` /
`fan-stop-to-start-us` (`Documentation/devicetree/bindings/hwmon/pwm-fan.yaml`),
implemented in `__set_pwm()` as *boost → `usleep_range()` → apply the real target*,
with `ctx->pwm_usec_from_stopped` defaulting to **250 000 µs**. Those properties are
absent from **both v6.1 and v6.6** (checked), so this board's vendor 6.1.115 BSP has
no DT knob and the equivalent has to come from userspace.
`ceralive-fan-kickstart.service` is a faithful userspace port of that mechanism —
**including its explicit restore step**, which is the part that matters most.

**THE LOAD-BEARING KERNEL FACT — DO NOT "SIMPLIFY" THE RESTORE AWAY.** The obvious
design is "write `max_state`, then stop writing and let the governor's next
scheduled poll overwrite it with whatever the real temperature calls for."
**On this kernel that is FALSE**, and shipping it would leave the fan at 100 %
indefinitely. Verified by reading the exact tree the board runs
(`armbian/linux-rockchip` @ `95e85f6cb496`, 6.1.115), three facts that compose:

- `drivers/thermal/thermal_sysfs.c` `cur_state_store()` calls
  `cdev->ops->set_cur_state()` and **does NOT clear `cdev->updated`**.
- `drivers/thermal/thermal_helpers.c` is
  `thermal_cdev_update() { if (!cdev->updated) { __thermal_cdev_update(cdev); … } }`
  — while `updated` is set it re-asserts **nothing at all**.
- `drivers/thermal/gov_step_wise.c` clears `updated` **only when its newly computed
  target differs**: `if (instance->initialized && old_target == instance->target) continue;`.

So while the temperature stays inside one trip band the governor's target does not
change, `updated` stays true, and the governor never writes again — the kick would
persist, unbounded. Worse, `get_target_state()` derives its next step from the REAL
current state (`clamp(cur_state + 1, lower, upper)`), so on a rising trend the
governor **reads back the kicked value and adopts `max_state` as its own target**:
the nudge latches itself in. Both failure modes were confirmed by source reading, and
the kernel's own `cur_state` write path is what makes them possible.

Hence the shipped design, which is a bounded three-phase transaction per edge:
**(1)** write the device's own `max_state`; **(2)** sleep exactly `CERALIVE_FAN_KICK_MS`
(default **1000**); **(3)** write the governor's own pre-kick commanded state back —
*unless* `cur_state` no longer reads the kick value, in which case the governor made a
fresher decision during the window and its newer verdict is honoured instead. The
restore is what makes the full-PWM period equal to the sleep rather than "until the
temperature happens to leave the band", and it restores the driver's cached state so
step_wise's `cur_state + 1` arithmetic resumes from the correct rung.

**Why 1000 ms and not upstream's 250 ms.** Upstream boosts inside the same
`pwm_apply` that first energises the fan, so its clock starts at power-on. A polled
userspace watcher necessarily applies the boost up to one poll interval later, by
which point the rotor is not *about to start* but already energised and stalled —
breaking a stall wants more margin than avoiding one. 1000 ms also clears the top of
the ~300-800 ms spin-up band of the 40-80 mm 5 V fans these SBCs use while still
reading as a brief transient. The risk is asymmetric: because the kick always ends in
an explicit restore, erring long costs a fraction of a second of fan noise and can
never be a thermal risk, while erring short silently fails to fix anything. The value
is one named, band-clamped constant (100-5000 ms) so it can be retuned on the bench.

**THE FIRST RESIDENT UNIT IN THIS FAMILY, and necessarily so.** Unlike
`ceralive-fan-curve` / `-led-status` / `-typec-source`, this cannot be a boot
oneshot: the fan drops back to state 0 whenever the board cools below the trip and
re-enters an active state when it warms again, many times over a device's uptime, and
**every** re-entry is a fresh dead start. `Type=exec` + `Restart=on-failure` +
`RestartSec=5s` follows this repo's existing long-running precedent
(`ceralive-rtmp-gateway.service`); `Type=exec` over the bare `simple` default so a
missing or non-executable script is a start failure rather than a unit that silently
"succeeds" and watches nothing. **`Restart=always` is deliberately WRONG here** — the
script exits 0 on purpose on a board with no fan, and `always` would respawn that in a
hot loop forever. It runs `Nice=10` / `CPUWeight=20` / `IOSchedulingClass=idle`,
because it runs for the life of the device and must never compete with the media path;
the work per tick is one small sysfs read at 4 Hz. **`ProtectKernelTunables=` is
deliberately left at its default (`no`)** — enabling it remounts `/sys` read-only and
would break the one write this unit exists to make.

**Fires ONLY on a genuine 0 → nonzero edge.** `nonzero → nonzero` (the governor
climbing or descending under its own control) and `anything → 0` never fire, and a
governor that jumped straight to `max_state` is already commanding full PWM so there
is nothing to kick above — the same skip condition upstream uses (`update = duty <
from_stopped`). The previous state is **primed from the device at startup**, never
assumed to be 0, so a `Restart=` mid-life does not produce a spurious nudge.

**Discovery is generic, and hardcoding is the trap — same lesson as `setup_fan_curve`.**
`cooling_device4`/`hwmon7` are registration-order artefacts. The script scans
`cooling_device*/type` for the exact string `pwm-fan` and takes BOTH the kick value
and the skip decision from that device's **own `max_state`**, never a hand-invented
"100 %" and never this board's particular `0 70 75 80 100` levels, which it does not
read at all — it works purely in cooling-state space, so it is independent of whatever
duty cycles a given board's DT maps those states onto.

**Board-agnostic and fail-soft:** no thermal class, no `pwm-fan` cooling device
(x86-minipc), or `max_state < 2` are informational log-and-exit-0 outcomes.
`max_state < 2` is its own explicit case: if the only active state IS `max_state`,
entering it already commands full PWM and there is no room to kick above the target,
so kicking would be a pointless write. Like the fan curve it polls to a short deadline
(10 s) for the asynchronous driver probe rather than sleeping a fixed amount, and it is
deliberately **not `Before=` anything**.

**It does NOT write `pwm1`/`pwm1_enable`** (the cooling device's own `cur_state` is
this board's sanctioned control surface; driving the hwmon node means owning the fan
forever, including across suspend and shutdown), does NOT write `thermal_zone*/mode`,
and does NOT touch any trip point — that is `setup_fan_curve`'s job and this unit
deliberately does not overlap with it. `setup_fan_curve` and its two artifacts are
byte-untouched by this change.

Guards: `v2/tests/manifest.bats` §29 "fan kickstart: …" (17 tests). The fixture
deliberately puts `pwm-fan` at `cooling_device6` with `max_state` **6** — not the
reference board's `cooling_device4`/`max_state 4` — behind a decoy CPUFreq
`cooling_device2` that must never be written, so any hardcoded index and any
hand-invented kick value fails the suite. It pins the kick→restore round trip against
an independently sampled `cur_state` timeline, the bounded window, all three
never-fire edges, startup priming, the mid-kick governor-re-assert race, a
second cooldown/reheat cycle firing again (the property that makes a oneshot wrong),
the `max_state`-is-READ-never-a-literal contract, the no-`pwm1`/`mode`/trip rule, the
restore write plus its `STICKY`/`cdev->updated` rationale being present, the
no-`pwm-fan` and single-active-state no-ops, the resident-unit contract, fail-closed
missing source, and the `configure_services` wiring. All 17 were mutation-verified:
deleting the restore, widening the edge test, hardcoding the kick to `4`, dropping the
single-state skip, priming to 0, and dropping the race guard each fail the suite.
`setup_fan_kickstart` is registered in `postinst-drift-check.sh`'s
`CONSOLIDATED_FUNCS`; nothing was added to `mkosi.postinst.chroot`.

**Not yet in a shipped release, and not yet boot-proven.** The stiction diagnosis
rests on live-hardware readings and the sticky-write mechanism on the pinned kernel
sources; the unit itself has not been through this repo's build/flash/release cycle.
The remaining on-hardware step is to confirm that a real 0 → 1 crossing produces an
audible full-speed burst that settles back within ~1 s and that the fan starts every
time without a manual push. It can be logic-verified without root the same way the LED
fix was — mirror the real `/sys/class/thermal` into a writable `/tmp` tree
(`cp -r --dereference` the `cooling_device*` dirs, keeping `type`/`cur_state`/`max_state`)
and point `CERALIVE_FAN_KICK_THERMAL_DIR` at it, then drive `cur_state` 0 → 1 by hand
and watch the monitor's journal lines and the mirrored file.

**The board's indicator LEDs are registered by the kernel and then never
configured — they sit at `trigger=none`, `brightness=0`, dark, forever** [EXISTS —
code merged-ready, NOT in any shipped release yet]

Read on a live Orange Pi 5 Plus. The kernel's LED class holds exactly three
entries, and the two that an operator would actually read as status are doing
nothing at all:

```
/sys/class/leds/blue:indicator-1   -> /sys/devices/platform/gpio-leds/leds/blue:indicator-1
/sys/class/leds/green:indicator-2  -> /sys/devices/platform/pwm-leds/leds/green:indicator-2
/sys/class/leds/mmc0::             -> /sys/devices/platform/fe2e0000.mmc/leds/mmc0::
```

`blue:indicator-1` and `green:indicator-2` both read `trigger = [none]` and
`brightness = 0`. They are wired, the drivers bound, and nothing in the image or
the device tree ever asks them to do anything — so a headless streaming
appliance with no screen gives its operator **zero** visual evidence that it
booted, that the kernel is alive, or that it is doing any work. This is not a
broken LED; it is an unclaimed one, exactly like the `pwm-fan` above was a
working fan that was never asked to run.

`ceralive-led-status.service` (a boot oneshot, installed by
`postinst-lib.sh::setup_led_status` from the committed standalone artifacts
`v2/mkosi/runtime/ceralive-led-status.{sh,service}`) assigns an ORDERED policy
to the discovered indicator LEDs: the **first** gets `heartbeat` (the stock
load-modulated "the kernel is scheduling" blink — meaningful on every board and
in every state), the **second** gets `mmc1` (removable-card activity, so a
second glance says "the board is doing I/O" and reads differently from the
heartbeat's double-blink). Both names are confirmed present in this board's own
trigger menu, and the script re-verifies each against that LED's `trigger`
attribute before writing — a kernel that does not offer one is logged and
skipped, never forced.

**It never writes `brightness`, and that is the safety argument.** Installing a
trigger hands the LED to the kernel; writing `brightness` afterwards fights the
very trigger just installed. Same principle as the fan curve's refusal to write
`cur_state`: set the policy, then get out of the way. The script constructs no
`brightness` path at all, and exactly one sysfs write exists in it — the
`trigger` attribute.

**`mmc0::` is NOT one of the indicator LEDs and is deliberately untouched.** It
is the MMC host controller's own activity LED, registered by the mmc core and
already driven by the kernel — a separate, already-working thing. Do not "fix"
it, and do not read its presence as evidence that the other two are configured.

**There is NO red LED anywhere in the kernel's LED class on this board.** The red
LED an operator can see next to the others is, on the evidence, a hardwired
power-rail indicator with no software visibility whatsoever. Nothing in this
repo — no udev rule, no sysfs write, no DT property this pipeline owns — can
address it. It is recorded here specifically so the next person does not spend
an afternoon looking for it in `/sys`.

**THE EXCLUSION RULE, AND WHY IT IS SHAPED THIS WAY.** An LED's class name IS its
identity (the directory basename; there is no separate `name` attribute), and
Linux spells it `devicename:colour:function`
(`Documentation/leds/leds-class.rst`). Real boards fill those fields
inconsistently — this board's vendor DTS emits `blue:indicator-1` (colour first,
no devicename) while the mmc core emits `mmc0::` (devicename first, no colour,
no function) — so keying on field POSITION is not portable. The rule is
therefore: split the name on `:` and reject the LED if **any** field matches
`mmc[0-9]*` (a kernel-managed MMC activity LED) or `power` (a power-rail
indicator must keep meaning "powered"; repurposing it destroys information
rather than adding it). That is the entire list on purpose. A name-based
ALLOWLIST would be worse than useless here: `indicator-1`/`indicator-2` carry no
semantics at all — they are not `status`/`activity`/`power` — so there is
nothing meaningful to match on, and anything surviving the two exclusions is by
construction an unclaimed indicator.

The script additionally **never re-points an LED that already has a trigger**,
whether from a DT `default-trigger`, a previous run, or an operator. That is
both the right policy (an LED that already means something keeps meaning it) and
what makes the unit idempotent across reboots and A/B slot swaps. Reading the
current trigger goes through the same bracket parse
`ceralive-typec-source` documents for `port_type`: the attribute prints the
WHOLE menu with the active entry bracketed (`[none] rfkill-any heartbeat mmc0
mmc1 …`), so a naive literal compare is never true.

**Board-agnostic and fail-soft by construction.** No LED class, an empty one,
only reserved LEDs, exactly one free LED, or five of them are all informational
log-and-exit-0 outcomes — the surplus beyond the policy's two triggers is logged
and left exactly as the kernel set it. A refused write is a WARNING (the board
keeps a dark LED, which is the state it shipped in) and the run continues to the
next LED; only a write the kernel ACCEPTS and then does not honour is fatal,
because by then the hardware shape has already been proven present. Like the fan
curve it polls to a short deadline (10 s) rather than sleeping — `gpio-leds` and
`pwm-leds` probe asynchronously — and it is **deliberately not `Before=`
anything**, because nothing consumes an LED trigger and a board with no LEDs
must not pay that wait on the boot critical path.

Guards: `v2/tests/manifest.bats` §18g "led status: …" (11 tests). The fixture
deliberately uses LED names the reference board does not have —
`amber:status-a`, `white:status-b`, a `red:power` decoy, and the kernel LED at
`mmc2::` rather than `mmc0::` — so any hardcoded LED name, and any `mmc0`-literal
exclusion, fails the suite. It also pins the never-write-`brightness` property
(both statically and by asserting the fixture's `brightness` nodes are unchanged
after a real run), the zero/one/two/three-LED matrix, idempotency against the
bracketed already-set form, the not-offered-trigger skip, the loud read-back
failure, the RO-node warning, fail-closed missing source, and the
`configure_services` wiring. `setup_led_status` is registered in
`postinst-drift-check.sh`'s `CONSOLIDATED_FUNCS`; nothing was added to
`mkosi.postinst.chroot`, which stays at 925 lines against the 950 ceiling.

**Not yet in a shipped release, and not yet boot-proven.** The discovery and the
policy are proven against synthetic fixtures and the LED inventory above was read
off a real board, but no booted image has yet been observed lighting the LEDs.
Confirming a heartbeat blink and card-activity flicker on hardware is the
remaining step.

## ADD-ON SUBSYSTEM [EXISTS]

Feature sysexts are optional, per-board/per-OS `.raw` artifacts delivered
out-of-band from the base image. They extend `/usr` and `/opt` only
(`SYSEXT_LEVEL=1`, `VERSION_ID=12`) and are managed at runtime by the CeraUI
add-on manager.

**Descriptor format** (`v2/manifests/schema/addon.schema.json`)

Each add-on ships a JSON descriptor baked into the image at
`/usr/share/ceralive/addons/<id>.json`. Required fields:

| Field | Description |
|-------|-------------|
| `id` | Lowercase alphanumeric + hyphens; unique per image |
| `version` | Semver `MAJOR.MINOR.PATCH` |
| `category` | `debug` / `display` / `media` / `network` / `other` |
| `payload.type` | `sysext` (only implemented type; `appfs` reserved) |
| `artifact.urlTemplate` | HTTPS URL with `{os_version}` placeholder |
| `artifact.sha256` | Lowercase hex SHA-256 of the `.raw` |
| `artifact.gpgSigRef` | Reference to the detached GPG signature |
| `artifact.sizeDownload` | Compressed `.raw` size in bytes |
| `artifact.sizeInstalled` | Installed size in bytes |
| `sysext.paths` | List of `/usr/…` or `/opt/…` paths the sysext provides |
| `deps` / `conflicts` | Optional add-on id arrays (uniqueItems) |

**Signing contract** [EXISTS]

Every `.raw` artifact is signed with the add-on keyring GPG key from `cert-work/`.
The signature is a detached `.sig` file co-located with the `.raw` on R2. CeraUI
verifies the GPG signature and the `sha256` field before activating any add-on.
The keyring is baked into the image at build time via `build-feature-sysext.sh`.

**Build a feature sysext** [EXISTS]

```bash
# Build a signed per-board/per-OS sysext .raw:
v2/lib/build-feature-sysext.sh \
  --descriptor v2/manifests/addons/<id>.sysext.conf \
  --board rock-5b-plus \
  --out dist/
# Output: dist/<id>-<board>-<os_version>.raw + dist/<id>-<board>-<os_version>.raw.sig
```

The builder reuses `v2/lib/app-layer/sysext.sh` (extract → prune Platform/Runtime
libs → assert required binaries → squashfs). The exclusion contract
(`SYSEXT_EXCLUDE_NAMES`) prevents GPU/BSP userspace from leaking into add-on
artifacts.

**R2 delivery path**

```
addons/{os_version}/{board}/{feature}.raw
addons/{os_version}/{board}/{feature}.raw.sha256
addons/{os_version}/{board}/{feature}.raw.sig
```

`os_version` is the Debian `VERSION_ID` (e.g. `12` for bookworm). The
`{os_version}` placeholder in `artifact.urlTemplate` is substituted at download
time by the CeraUI add-on manager. `apt-worker` serves these keys (404 on a
missing object, never a 200-empty); see `apt-worker/AGENTS.md`.

**Publishing** [EXISTS]

`v2/lib/upload-addons.sh` publishes a signed add-on to R2, mapping
`build-feature-sysext.sh`'s `<feature>-<board>-<os_version>.raw{,.sha256,.sig}`
onto the delivery path above. It REFUSES to upload an unsigned (or
unchecksummed) artifact, and pins per-file content-type so R2 stores what the
worker serves. CI mode reuses the `fetch-debs.sh` R2 pattern (`aws s3 cp`
+ `R2_ENDPOINT`); the `v2-ci.yml` `addon-publish` job proves the plan +
unsigned-refusal gate under `DRY_RUN` without secrets.

**sysext refresh protocol** — see [`v2/docs/addon-sysext-refresh.md`](v2/docs/addon-sysext-refresh.md)

Services SURVIVE `systemd-sysext refresh` but keep running the old binary. The
add-on manager must:
- **Update:** `systemd-sysext refresh` → `systemctl restart <addon>.service`
- **Disable:** `systemctl stop <addon>.service` → `systemd-sysext refresh`

Never report an add-on "updated" or "disabled" on the strength of the sysext call
alone.

**First-boot SSH hardening** [EXISTS]

`ceralive-ssh-firstboot.service` runs before `ssh.service` and `ssh.socket` on
every boot, and both SSH activation paths require it to succeed. Standalone
artifacts under `v2/mkosi/runtime/`
(`ceralive-ssh-firstboot.{sh,service}`), installed by
`postinst-lib.sh::setup_ssh_firstboot` — NOT inlined in `mkosi.postinst.chroot`
(the drift gate's 950-line ceiling). Scope is locked (SC4): regenerate the baked
shared host keys into a per-device identity (persisted on `/data`, stable across
A/B) and apply the once-only password hardening on initial boot; the per-boot guard
then enforces `PermitRootLogin prohibit-password` and CI-key retention policy.
Persistent authorized-key stores are linked from `/data`; run-local CI keys survive
only an explicitly armed, one-use reboot and are otherwise purged before sshd.
The `ceralive` user ships password-locked (no default password); root retains
key-based recovery access. Full behaviour: [`v2/docs/ssh-hardening.md`](v2/docs/ssh-hardening.md).
For bench-only access, `CERALIVE_DEBUG_IMAGE=1` requires an externally supplied
encrypted `CERALIVE_DEBUG_PASSWORD_HASH`; it is rejected for normal builds and
must never be used for fleet artifacts.

**`ssh.service` systemd enablement is gated on `CERALIVE_DEBUG_IMAGE`
(`postinst-lib.sh::configure_ssh_enablement`, called from `configure_services`).**
Production images (`=0`/default) ship `ssh.service` **NOT enabled** (operator turns
SSH on from the CeraUI UI); debug images (`=1`) keep the historical
enabled-by-default behavior. The base layer installs `openssh-server`, whose Debian
postinst preset already enables `ssh.service`, so the production branch **actively
disables** `ssh.service`/`ssh.socket` — merely skipping the enable would leave the
base-layer preset enablement in place. `ceralive-ssh-firstboot.service` still hardens
SSH whenever it is eventually started, on both image kinds. Guards: `manifest.bats`
"production image leaves ssh.service NOT enabled" + "lab debug image enables
ssh.service by default".

**`Before=ssh.socket` guards MUST be `DefaultDependencies=no` AND
`After=sysinit.target`.** Both `ceralive-ssh-firstboot.service` and
`ceralive-ci-uart-bootstrap.service` are `Before=ssh.socket`. `ssh.socket` is
ordered `Before=sockets.target` (early boot, before `basic.target`), so a guard
that inherits the implicit `After=basic.target` closes an `ssh.socket → guard →
basic.target → sockets.target → ssh.socket` ordering cycle — systemd deletes
`ssh.socket`'s start job and SSH never starts, on every boot (proof-10 UART boot
log, 2026-07-15). `DefaultDependencies=no` breaks that, but it ALSO drops the
implicit `After=sysinit.target`; proof-11 (2026-07-15) then showed
`ceralive-ssh-firstboot` racing ahead of `systemd-sysusers`/`systemd-tmpfiles`/
udev and FAILING under `set -euo pipefail` (host-key gen, authorized-key chowns,
`sshd -t`), taking ssh.service/ssh.socket down with "Dependency failed" — with
**zero** ordering cycles. So each guard must ALSO re-add `After=sysinit.target`
explicitly (the SAFE half of the default deps; `sysinit.target` is ordered before
`sockets.target`, so it never re-closes the ssh.socket loop). NEVER re-add
`After=basic.target`. The same cycle trap (but NOT the sysinit issue) hit
`ceralive-migrate-data.service`, which seeds the `/data` skeleton the
`/var/log`+`/opt/ceralive` bind mounts shadow: it must be `Before=local-fs.target`
(never `After=`) with `DefaultDependencies=no`, and must NOT gain
`After=sysinit.target` (sysinit.target is After=local-fs.target — that would
cycle); it runs as root against `/data`+rootfs only, so it needs no sysinit-phase
ordering. `ConditionKernelCommandLine`/`ConditionPathExists` do NOT remove a
unit's ordering edges — systemd wires them at transaction-build time regardless of
the condition. Offline guard: `v2/tests/systemd-ordering-cycle.test.sh` — static
contract + `systemd-analyze verify` for zero cycles AND an ordering probe that
proves each guard is transitively after `systemd-sysusers`/`systemd-tmpfiles`
(a cycle-only check would miss the proof-11 gap). Wired into `v2/run-tests`.

**RK3588 CI-UART bootstrap owns the LIVE console `/dev/ttyFIQ0`, NOT `/dev/ttyS2`.**
On RK3588 the Rockchip vendor kernel's FIQ debugger claims physical UART2 once Linux
boots and exposes it as `/dev/ttyFIQ0` — systemd spawns `serial-getty@ttyFIQ0.service`
and there is **no `/dev/ttyS2` device node at runtime**. So
`ceralive-ci-uart-bootstrap.service` sets `TTYPath=/dev/ttyFIQ0` (was `/dev/ttyS2`,
which made its `StandardInput=tty` setup fail instantly on real Rock 5B+ hardware — no
handshake, no run-local SSH key installed), and the CI harness
`v2/ci/uart-provision-ssh.sh` masks `serial-getty@ttyFIQ0.service` over the transient
kernel cmdline (`systemd.mask=serial-getty@ttyFIQ0.service`) so the real getty cannot
contend for the port (masking `serial-getty@ttyS2.service` was a no-op — that unit
never exists). This is DISTINCT from the family `serial_console: ttyS2:1500000`, which
stays `ttyS2`: that is the raw UART2 U-Boot/early-kernel `console=ttyS2,1500000` arg,
correct because the bootloader/early kernel drive UART2 directly BEFORE the FIQ
debugger claims it (hence the UART helper's `=>` prompt interaction works). Do NOT
rename `serial_console` to `ttyFIQ0` — that would break the early/bootloader console.
The entire CI-UART path is RK3588-only by construction (`TTYPath` is a hardcoded
literal, not templated; x86 uses `ttyS0` and never runs this gate). Offline guard:
`v2/tests/uart-console-path.test.sh` (bootstrap `TTYPath` + getty mask both target
`ttyFIQ0`, the two agree, and `serial_console` stays the raw-UART2 `ttyS2` early
console). Wired into `v2/run-tests`.

**CI-UART bootstrap `stty` is tty-class-aware — the FIQ tty rejects the baud
ioctl.** Once the console fix above got the bootstrap to actually run on
`/dev/ttyFIQ0`, `ceralive-ci-uart-bootstrap.sh` aborted at `stty 1500000 sane -echo
<&0` under `set -euo pipefail`, BEFORE printing `CERALIVE_UART_BOOTSTRAP_READY`
(real Rock 5B+ regression, 2026-07-19; empirically reproduced — same-line-rate
`stty` on the FIQ tty returns `unable to perform all requested operations`). The FIQ
debugger is a **software** console over the debug UART whose line rate is FIXED by
the kernel `console=ttyS2,1500000` arg, so its baud is not settable and the channel
already works by default (every boot message reaches the host over it). The fix
(`configure_bootstrap_tty()`) is **tty-class-aware**: on a `ttyFIQ*` tty it drops
echo best-effort and NEVER fails (logs `CERALIVE_UART_BOOTSTRAP_INFO
fiq-tty-stty-skipped`); on a real UART (a future `ttyS` board, or x86 `ttyS0`) it
keeps the full `stty 1500000 sane -echo <&0 || fail` — deliberately NOT a blanket
`|| true`, so a genuine mis-provision on a settable-baud board is surfaced, not
masked. Host-side `v2/ci/uart-provision-ssh.sh` still `stty`s the CI runner's USB
adapter at 1500000 (that adapter DOES honor it — unchanged). Offline guard:
`v2/tests/uart-bootstrap-tty.test.sh` (exercises the shipped function against stubbed
FIQ + real-UART ttys: FIQ tolerant even when stty fully fails, real UART fatal on a
baud failure) + a co-located static signature in `uart-console-path.test.sh`. Wired
into `v2/run-tests`.

**`ceralive-ssh-firstboot.sh` MUST create `/run/sshd` before its `sshd -t`.** The
guard's last step validates the sshd config with `sshd -t`, which refuses to run
without the privilege-separation dir `/run/sshd` (`Missing privilege separation
directory: /run/sshd`, exit 255). On a fresh boot that dir does not exist yet:
nothing ships a `tmpfiles.d` entry for it, and its only creator is `ssh.service`'s
`RuntimeDirectory=sshd` — which runs AFTER this `Before=ssh.service` guard. Without
pre-creating it, `sshd -t` exits 255, `set -euo pipefail` fails the unit, and both
`ssh.service` (LAN sshd on :22) and `ssh.socket` DEPEND-fail via `RequiredBy=`,
closing port 22 on EVERY boot with **zero** ordering cycles and an otherwise-healthy
system (proof-13 real-HW UART, 2026-07-16). This is a runtime script failure, NOT a
dependency-graph defect — `systemd-ordering-cycle.test.sh` cannot see it. The
dedicated offline guard is `v2/tests/ssh-firstboot-privsep.test.sh` (static: the
`/run/sshd` creation precedes `sshd -t`; runtime: the real script survives an
empty-`/run` first boot in a rootless namespace). Wired into `v2/run-tests`.

**Deterministic first-boot hostname** [EXISTS]

`ceralive-hostname.service` asks the running Avahi daemon to publish candidates
in the exact sequence `ceralive`, `ceralive2`, `ceralive3`, ... and accepts a
candidate only after Avahi repeatedly reports `RUNNING` with that exact name.
Avahi's automatic hyphenated collision name is treated only as a conflict signal;
it is never persisted. A real local `flock` serializes starts, while Avahi's mDNS
claim protocol arbitrates simultaneous devices. The selected index lives at
`/data/ceralive/host_index` through the `/etc/ceralive/host_index` symlink; the
local service lock is runtime-only state under `/run`.

The unit is ordered `After=`/`Wants=network-online.target` (link actually up), NOT
merely `After=NetworkManager.service` (daemon up). The mDNS claim (`avahi-set-host-name`
+ Avahi `RUNNING` + a publishable LAN address) cannot succeed before an interface
links, and every `Requires=ceralive-hostname.service` consumer (`ceralive.service`,
`ceralive-tls-firstboot.service`, `ceralive-hawkbit-provision.service`, and
transitively `nginx.service`/`ceralive-healthcheck.service`) cascades to "Dependency
failed" if this unit fails on first boot. Confirmed on real Rock 5B+ hardware: the
unit ran at ~15s and failed by ~15.8s while `eth0`'s link only came up at 18.89s, so
the claim failed-closed and the entire appliance stack (plus `dnsmasq`, which shares
the same start batch) never came up (`curl http://<device>/api/health` → connection
refused). Its sibling network-dependent units (`ceralive-healthcheck`,
`ceralive-hawkbit-provision`, `rauc-hawkbit-updater`) already wait for
`network-online.target`; the hostname unit was the lone omission. This is a systemd
ordering fix, distinct from the mDNS-arbitration logic. Offline guards:
`v2/tests/systemd-ordering-cycle.test.sh` (static `After=`/`Wants=` contract + a
dynamic ordering probe proving the unit runs after `network-online.target`) and
`manifest.bats` "hostname:" ordering assertions.

Each service attempt has a 120-second global claim budget, 3-second command
timeouts, and a 10-second local-lock wait. systemd caps the attempt at 150 seconds
and retries a failed attempt after 5 seconds. Missing/malformed Avahi state,
missing tooling, and failure to establish exact ownership all fail closed; there
is no random suffix or DNS-only availability fallback. The isolated provisioning
AP address is not a claimable LAN identity; Ethernet IPv4 link-local remains
eligible. A successful retry non-blockingly requeues identity consumers while
the hostname unit remains active, so an early no-network failure does not strand
CeraUI or TLS. On every restart the service reapplies the persisted identity to
the runtime hostname, `/etc/hostname`, `/etc/hosts`, and Avahi before CeraUI, TLS
certificate creation, or hawkBit enrollment may run. A separate 30-second
reconciliation timer checks strict Avahi and local identity state. Aligned and
`REGISTERING` snapshots cause no allocation or service churn; explicit conflict
or divergence reruns the bounded deterministic claim and restarts identity
consumers only after a successful commit. TLS validates the actual certificate
SAN and key pair, replacing it if the committed hostname advances. CI exercises
the production script against two real Avahi daemons in private D-Bus/network
namespaces for simultaneous boot and late-LAN-merge races. Operator behavior and
diagnostics are documented in [`docs/FIRST-BOOT.md`](docs/FIRST-BOOT.md) §4.

**Baked-hostname `AVAHI_ERR_NO_CHANGE` fix + graceful degradation (2026-07-19).**
After the `network-online.target` ordering fix above, the claim STILL failed on
real Rock 5B+ hardware — for a different, empirically-confirmed reason. The image
bakes `/etc/hostname=ceralive` (`configure_networking`), so the running Avahi daemon
already publishes `ceralive` at boot. `ceralive-set-hostname` (allocate, index 1)
then calls `avahi-set-host-name ceralive`, which returns non-zero
(`AVAHI_ERR_NO_CHANGE`: a no-op set to the daemon's current name in a non-collision
state — reproduced live: same-name set → exit 1, different-name → exit 0). The old
`claim_candidate` treated that non-zero as a lost claim → `die` → and every hard
`Requires=` consumer cascaded to "Dependency failed", killing the whole appliance
(`ceralive.service`, `nginx`, TLS, hawkBit) on first boot. Three fixes, all in
`postinst-lib.sh::setup_hostname_service` unless noted:

- **Root cause** — `claim_candidate` now treats a failed `avahi-set-host-name`
  whose daemon is already `RUNNING` + publishing the exact candidate as SUCCESS
  ("we already own it"); any other set failure retries the SAME candidate within
  the deadline instead of aborting or wrongly advancing the deterministic index.
- **Avahi readiness** — a bounded, best-effort `wait_for_avahi_ready` polls
  `GetState` for a query-ready daemon (REGISTERING/RUNNING) before the first claim,
  since `After=avahi-daemon.service` only guarantees the process started.
- **Graceful degradation** — the appliance consumers now `Wants=` (NOT `Requires=`)
  `ceralive-hostname.service`: `ceralive.service` (drop-in `05-hostname-identity.conf`),
  `ceralive-tls-firstboot.service`, and `ceralive-hawkbit-provision.service`. A failed
  claim no longer cascades; the device boots on the baked default hostname
  (degraded-but-functional), `After=` keeps ordering, the unit's own
  `Restart=on-failure` + the 30s reconcile timer keep retrying, and `ExecStartPost`
  restarts consumers once a claim succeeds. Only `ceralive-hostname-reconcile.service`
  keeps a hard `Requires=` (its failure is harmless — the timer refires). This
  supersedes the "every `Requires=` consumer cascades" description above.

Guards: `manifest.bats` "hostname:" gains an `AVAHI_ERR_NO_CHANGE`-accepted test, a
readiness-wait test, and `Wants=` (not `Requires=`) graceful-degradation assertions;
`real-avahi-hostname-contract.sh` gains a real-avahi PREOWNED scenario (daemon seeded
`ceralive`) proving the fixed allocator claims it instead of dying — the exact CI
blind spot (prior seeds never equalled the first candidate).

**Build concurrency** [EXISTS]

The orchestrator holds a per-board `flock` under `v2/mkosi/.staging/.locks/`
before touching staging, cache, or mkosi output. Different boards remain safe to
build in parallel. A second build of the same board waits for up to one hour by
default; set `CERALIVE_BUILD_LOCK_TIMEOUT=0` for fail-fast behavior or another
non-negative number of seconds for a bounded wait. This also prevents a CI
dry-run from deleting the staging tree of an active hardware image build.

**Verified `.deb` download cache — opt-out, bounded, and NOT protected by the
build lock above** [EXISTS]

`v2/lib/fetch/debcache.sh` gives all three verified fetch families (BSP, RK3588
userspace, first-party) a persistent content-addressed cache at
`v2/mkosi/.staging/.debcache/`, keyed on `<package>_<version>_<arch>.deb` plus
the artifact's expected SHA-256. A second real fetch of the same plan performs
**zero `.deb` payload downloads** — proven end to end on the userspace family
(6 pinned upstream packages, 6 downloads then 0, every one re-verified against
`rk3588-userspace-deb-versions.txt`).

- **Reuse can never weaken verification, and that is the whole safety argument.**
  Every family already holds the expected SHA-256 before it downloads — from the
  `gpgv`-verified Packages index (both BSP transports, both first-party
  transports) or from the committed pin file (userspace) — so a HIT is checked
  against exactly the hash the network path would have been checked against. An
  entry whose hash no longer matches is **deleted**, not skipped: it is either
  corrupt on disk or the archive replaced the bytes under the same filename, and
  keeping it would re-fail every future build.
- **Only final `.deb` payloads are cached.** `InRelease`, `Release`,
  `Packages.gz`, the apt lists and the GPG keyring are DELIBERATELY never cached
  — that is the rotating trust material whose entire job is to be fresh, and a
  stale index is how a cache becomes a downgrade surface. So the "0 downloads"
  claim is about payloads; apt/index metadata is still fetched every run.
- **Writes go through ONE chokepoint.** `publish_staged_deb` (`fetch/pool.sh`) is
  the single atomic-rename step all three families funnel through, and it is
  reached only after that family's SHA + Debian control identity checks. Storing
  there makes "cached bytes are verified bytes" a property of the call graph
  rather than a per-family promise. Do not add a second store site.
- **The per-board build lock does NOT protect this.** `acquire_board_lock` is
  keyed on one board and different boards are explicitly allowed to build in
  parallel, so two concurrent builds are two concurrent writers of the same
  entry. The cache therefore owns a **per-cache-key `flock`** under
  `.debcache/.locks/`, mirroring the `.staging/.locks/` idiom rather than reusing
  that lock.
- **The reader holds its key lock across the WHOLE hit sequence** — existence
  check, SHA re-verification, copy-out. Releasing after the hash check is the bug
  that looks like working code: eviction would then unlink the entry the reader
  had just verified and was about to read. **Eviction takes each victim's own key
  lock with `flock -n` BEFORE unlinking and SKIPS a locked victim.** Skipping
  rather than waiting is what keeps the ordering trivial — no path ever holds two
  key locks, so reader-vs-evictor cannot deadlock in either direction.
- **Bounded:** `CERALIVE_DEBCACHE_MAX_BYTES` (default 4 GiB), LRU by mtime, and a
  reuse refreshes that mtime so "least recently used" is genuinely that and not
  "oldest download". `CERALIVE_DEBCACHE=0` disables lookup, store and eviction
  and creates no directory at all. `CERALIVE_DEBCACHE_DIR` relocates it.
- **Every failure is non-fatal.** An unwritable directory, a lock timeout or a
  failed copy degrades to "download it" — the same behaviour as the disable flag.
- **`DRY_RUN` is byte-unchanged.** The gate excludes DRY_RUN centrally rather than
  at each call site, so a plan-only run downloads nothing, mutates nothing, and
  emits no cache line; the resolved plan is identical to the pre-cache one
  (paired capture, 44 lines).
- **It survives a per-board staging wipe** because it is a SIBLING of the
  per-board `.staging/<board>` dirs, and the existing `/.staging/` ignore rule
  already covers it. Do not move it under a board directory.

Guards: `v2/tests/debcache.test.sh` (25 legs — static contract, unit
hit/miss/corrupt/stale/eviction/LRU-refresh, TWO real concurrent reader-vs-eviction
legs with a live second process holding a real `flock`, and integration legs
driving the shipped userspace fetcher over `file://` pins that count payload
downloads). Mutation-verified: dropping the victim lock, dropping the SHA
re-check, leaving a corrupt entry in place, unwiring a family, and releasing the
reader's lock early each fail the suite. Both concurrency legs are needed and
neither is duplicate coverage — the first slows the reader inside verification,
the second slows the step between verification and the copy, and only the second
detects an early unlock.

**First-boot WiFi provisioning portal** [PARTIAL]

`ceralive-provision.service` brings up a self-hosted WPA2 setup hotspot AND a
captive portal so a headless, never-configured device can be handed WiFi
credentials with no screen or keyboard. Standalone artifacts under
`v2/mkosi/runtime/` (`ceralive-provision.{sh,service}` plus the captive portal
`ceralive-portal.{sh,socket,@.service}`), installed by
`postinst-lib.sh::setup_provisioning` — NOT inlined in `mkosi.postinst.chroot`
(drift-gate 950-line ceiling; `setup_provisioning` is in the gate's
`CONSOLIDATED_FUNCS`). Full end-to-end flow:
[`v2/docs/wifi-provisioning.md`](v2/docs/wifi-provisioning.md).

- **Trigger** (runtime decision, not a static unit Condition): the AP starts IFF
  there are **no stored (non-AP) NM WiFi profiles** on `/data` **AND** no link-up
  connectivity appears within a **60-90s boot grace window** (default 75s). Either
  a stored profile or any connectivity (NM `full`/`limited`/`portal`, or a default
  route) suppresses it. A `/data/ceralive/provision/force-portal` flag
  (factory-reset hook) re-triggers it even when profiles exist.
- **EC4 — OTA-safe:** a RAUC update that preserves `/data` keeps the WiFi profiles,
  so the portal correctly does **not** start after an update.
- **Conflict safety:** the AP only runs when there is zero connectivity (so srtla
  bonding is impossible anyway), and it leaves `wlan0` with no default route, so the
  srtla NM dispatcher (`90-srtla-wifi-routing`) sees an empty gateway and writes no
  rule/route in table 120 — a no-op while the portal is up. WiFi tables 120-124 are
  untouched.
- **AP mode:** NetworkManager-native (`802-11-wireless.mode ap` + `ipv4.method
  shared`) — no extra packages (NM drives wpa_supplicant + its internal dnsmasq;
  `network-manager`/`dnsmasq`/`wpasupplicant` already ship). `hostapd` stays in the
  image only as an evidence-gated fallback. SSID `CeraLive-Setup-<short-id>`
  (machine-id-derived setup identifier), passphrase `ceralive-setup`
  (documented default), gateway `192.168.42.1/24`. **HW caveat:** AP mode also
  requires the onboard wlan driver to support it (RK3588 chip dependent) — to be
  validated on hardware, hence `[PARTIAL]`.
- **Regulatory DB (`wireless-regdb`) is an EXPLICIT `shared.list` entry.** WiFi in
  ANY mode (client or the AP above) needs `/lib/firmware/regulatory.db` (+ `.p7s`),
  which the kernel `cfg80211` subsystem loads at boot to establish a usable
  regulatory domain. It ships in Debian's `wireless-regdb` package — the Linux
  wireless project's regulatory database, NOT chip firmware, so it is **not** part
  of the RK3588 `armbian-firmware` bundle (unlike `rtl8852be-firmware`; see
  `rk3588.delta.list`). It is only `wpasupplicant`'s `Recommends:`, so the runtime
  layer's `apt-get install --no-install-recommends` (runtime/mkosi.postinst.chroot)
  never pulls it transitively — it MUST be named in `shared.list` explicitly. Absent
  it, every boot logs `platform regulatory.0: Direct firmware load for regulatory.db
  failed with error -2` / `cfg80211: failed to load regulatory.db` and NetworkManager
  reports "No WiFi interfaces found" even with a working driver (real-HW UART,
  2026-07-16; the RTL8852BE `rtw89_8852be` chip enumerates + trains PCIe fine — the
  missing DB is a distinct gap). Guard: `manifest.bats` "wireless-regdb is installed
  so cfg80211 loads regulatory.db".
- **Captive portal (Task 14):** while the AP is up, `ceralive-provision` stops the
  CeraUI backend (`ceralive.service`) to free port 80 and starts
  `ceralive-portal.socket` — a systemd socket-activated (`Accept=yes`) **bash** HTTP
  handler on `192.168.42.1:80`. It is the lightest server already in the image (no
  busybox/python3/socat/nc ship — socat/netcat were moved to the debug add-on), and is
  a standalone plain-HTML page, NOT a CeraUI integration (SC2). A
  `address=/#/192.168.42.1` drop-in in `dnsmasq-shared.d` wildcard-captures DNS so any
  hostname pops the operator's captive-portal sign-in. The form's SSID list is the
  pre-AP scan cache (a single radio can't scan in AP mode) plus free-text entry.
- **Credential handoff:** the form POST writes the user's network via
  `nmcli connection add` (credentials land ONLY in NM's `/data`-backed store — never a
  file), answers the browser, then runs a DETACHED `ceralive-provision connect <con>`
  worker (via `systemd-run`, so it outlives the per-connection service that the AP
  teardown kills). The worker drops the AP, joins as a client under a bounded
  `nmcli --wait` + `timeout`, and on a wrong passphrase or hard timeout deletes the bad
  profile, writes a `last-error` marker the portal shows, and re-arms the AP for a
  retry — the device is never left headless-dead.
- **Port-80 coexistence:** the portal owns `192.168.42.1:80` only during provisioning;
  CeraUI's backend (binds `[80, 8080, 81]`, tries 80 first) is stopped for the window
  and restarted on teardown so it re-binds 80 on the new uplink IP. The Task-15 nginx
  TLS front on **443** is unaffected (its `127.0.0.1:80` upstream is just briefly down
  while there is no uplink — and thus no 443 client).
- **Teardown — MAC6 end-state (all four, sandbox-verified):** (a) AP profile deleted;
  (b) device joined the target network; (c) portal unreachable (`ceralive-portal.socket`
  stopped, port 80 freed); (d) CeraUI reachable on the new IP (`ceralive.service`
  restarted). A successful `connect` runs the teardown **keeping** the freshly-joined
  client link; the out-of-band `ceralive-provision teardown` verb (or a
  `/data/ceralive/provision/teardown-requested` flag) also releases `wlan0` and clears
  the portal-active + force flags. Plain `systemctl stop` (ExecStop) is link-down +
  portal-down only and RETAINS the AP profile + flags (shutdown must not disarm a
  pending factory reset). Offline proof harness:
  `v2/tests/provision-portal.test.sh` (gated in `manifest.bats`).

**CeraUI TLS front — nginx on 443 (Task 15, SC3)** [EXISTS]

The device serves the CeraUI control plane over HTTPS on **443** via `nginx-light`,
which terminates TLS and reverse-proxies to the CeraUI backend on `127.0.0.1:80`.
Standalone artifacts under `v2/mkosi/runtime/`
(`ceralive-tls.nginx.conf`, `ceralive-tls-firstboot.{sh,service}`,
`ceralive-tls-nginx.dropin.conf`), installed by
`postinst-lib.sh::setup_tls_proxy` — NOT inlined in `mkosi.postinst.chroot`
(drift-gate 950-line ceiling; `setup_tls_proxy` is wired into BOTH the postinst
executor and `services.sh`, like `setup_provisioning`).

- **SC3 — port 80 is KEPT.** nginx binds **443 only**; the backend keeps serving
  port 80 directly. `setup_tls_proxy` removes the stock nginx `sites-enabled/default`
  (which would otherwise grab :80). There is deliberately **no** 80→443 redirect —
  both ports are a real, supported entry point.
- **EC6 — WebSocket upgrade.** The proxy site sets
  `proxy_http_version 1.1; proxy_set_header Upgrade $http_upgrade; proxy_set_header
  Connection "upgrade";` so CeraUI's same-origin telemetry/RPC WebSocket survives the
  proxy (Task 1 already maps `https:`→`wss:` in the frontend; no UI change needed).
- **Self-signed cert (no ACME/mTLS).** `ceralive-tls-firstboot.service` keeps a
  per-device self-signed key+cert in `/data/ceralive/tls/` across reboots and A/B
  OTA slot swaps. It validates the real SAN and key pair on each run, remaining
  byte-stable while the hostname is unchanged and replacing the pair after a
  deterministic hostname advance. CN/SAN = `<hostname>.local` + the device IPv4.
  **Browser caveat (honest):** the first visit
  to `https://<device>.local` shows a "self-signed / not secure" warning — expected
  for a headless LAN appliance with no public DNS and no ACME path (SC3 forbids
  ACME/Let's Encrypt and mTLS). `openssl` is pinned in `shared.list` for the cert.
- **Ordering.** `ceralive-tls-firstboot.service` runs `Before=nginx.service` (and
  after the unique-hostname service); a `nginx.service.d/10-ceralive-tls.conf`
  drop-in adds `Requires=`/`After=` so nginx never starts without a cert.
- **Healthcheck.** `ceralive-healthcheck.sh` probes BOTH `http://127.0.0.1/status`
  (:80) and `https://127.0.0.1/status` (:443, `-k`); this is **non-fatal** (WARN
  only, like the mDNS probe) — a UI/TLS hiccup must not roll back a slot whose
  streaming stack is healthy and whose port 80 still serves.
- **Coexistence with provisioning (Task 11):** the AP-mode portal uses port 80;
  nginx only binds 443, so there is no conflict.
- **Size:** ~+3–4 MB; see [`v2/docs/size-notes.md §5`](v2/docs/size-notes.md).

## KIOSK STACK

The image ships a kiosk display stack (cage + Chromium + wvkbd) **installed but inert by default**. All kiosk units are masked at first boot. CeraUI enables kiosk mode at runtime via systemctl — no reflash needed.

**Repo boundary (DC-1):** the image owns the chassis (units, packages, OOM config, `OnFailure` handler). CeraUI owns the content, control, and lifecycle state (toggle RPC, token mint, state machine).

**Cog display add-on (W4):** Cog + WPEWebKit is validated as a lighter alternative
display engine, packaged as a feature sysext add-on. Acquisition path: plain `apt`
from bookworm `main` (`cog` 0.16.1, `libwpewebkit-1.1-0` 2.38.6). The Mali-G610
GPU userspace (`libmali-valhall-g610-g24p0-wayland-gbm` 1.9-1) is now **baked into
the base image** (Platform layer) via `firmware_packages` + the pinned userspace file
(see the "RK3588 HW-accel userspace" KEY FACT); it stays **excluded from the sysext**
by contract. Full recipe: [`v2/docs/cog-display-addon.md`](v2/docs/cog-display-addon.md).
**Hardware-gated:** `cog.sysext.conf` wired into the build only after RK3588 render
QA passes (same gate as Tasks 26/27/28) — on-hardware Mali EGL/GBM render is the
gated item, not the package availability.

**Implementation status:** Tasks 26 (systemd units), 27 (packages), 28 (RK3588 dual-GPU udev + touch calibration), and 30 (integration validation) are **hardware-blocked** — no RK3588 board is reachable from the dev environment (Task 1 spike: NO-GO). The architecture is fully specced; implementation waits for hardware access.

**Phase-3 deferrals:** e-ink kernel DRM driver + device-tree, dual-display hybrid, on-device live-video preview, and #61 battery/power telemetry (document-only: current boards are mains-powered, no fuel-gauge IC). Full register: [`v2/docs/kiosk-display.md §7`](v2/docs/kiosk-display.md).

**RK3588 mainline-patch contingency (D3 stays locked):** D3 (`armbian_branch: vendor`) is NOT changing. The Armbian vendor BSP kernel already provides HDMI hdmirx and mature Rockchip MPP H.265. If a mainline pivot is ever forced, the reference patch set is bookmarked in [`v2/docs/kiosk-display.md §3`](v2/docs/kiosk-display.md) (GPU contingency section): three patches from `https://github.com/rcawston/rockchip-rk3588-mainline-patches` covering VEPU580 H.265 encoder (WIP, pinned MPP fork required), HDMIRX EDID set fix, and HDMIRX plugout overflow fix. These are insurance only — do not apply without explicitly re-opening D3.

## ANTI-PATTERNS

- Don't change REPOS order or casing — downstream scripts key on exact names
- Don't add `ceralive-platform` to REPOS — cloud-only, not in device image
- Don't commit GPG private keys or mTLS certs — those come from `cert-work/` at build time
- Don't revert first-party fetch to R2 `aws s3 sync` / `gh release download` — first-party `.debs` are pulled at build time from `apt.ceralive.tv` (GPG + mTLS); see the "First-party .deb fetch" KEY FACT
- Keep `srt` in `REPOS` and map `libsrt1.5-ceralive` through `FIRST_PARTY_APT_PKGS`; do not add a Debian `libsrt1.5-*` runtime package to `shared.list`
- Don't implement kiosk units/packages without clearing the Task 1 hardware gate first
- Don't use `--native` as the default build path — container is canonical; native is opt-in
- Don't put GPU/BSP userspace (`libmali*`, `librockchip_mpp*`) in any add-on sysext — Platform-layer only
- Don't touch runtime apt sources on the device — `E4` guardrail
- Don't reintroduce an `APT::Sandbox::User` override on either apt path. On the device it disables sandboxing fleet-wide; in `fetch-debs.sh::fetch_first_party` it silently hid a permission bug the privilege-aware branch now fixes properly. Don't "fix" a `Download is performed unsandboxed as root` warning with it either — that warning means `_apt` cannot reach a directory, so widen the traversal (and chown the download dir, which apt writes to as `_apt`), never the privileges
- Don't hold a first-party CeraLive package, and don't add `unattended-upgrades`. The kernel freeze exists so apt cannot change the BOOT stack; `cerastream`/`ceralive-device`/`srtla-send-rs` and the ModemManager closure update over apt from apt.ceralive.tv and holding one would break `system.startUpdate()` permanently
- Don't convert the kernel freeze's `Pin: version` into a `Pin: origin` like the apt.ceralive.tv 990 pin. The boot BSP comes from mkosi's build-time-only local repository, so it has no apt-origin identity on the device and an origin pin would match nothing. Don't hardcode a package name there either — the U-Boot package differs per board
- Don't expect RAUC to honour a dpkg hold, or to need one lifted before an update. RAUC writes the whole inactive slot without running dpkg or apt; each image bakes the holds that govern its own slot
- Don't let add-ons gate OTA healthcheck/rollback — add-ons are orthogonal to the RAUC A/B slot
- Don't cache apt index/metadata (`InRelease`, `Release`, `Packages.gz`, the apt lists, the keyring) in the `.deb` cache, and don't reuse a cached `.deb` without re-verifying its SHA-256 against fresh signed metadata. Only final verified payloads are cacheable; the index is the rotating trust material a cache must never make stale
- Don't guard the `.deb` cache with the per-board build `flock` — that lock is keyed on ONE board and different boards build in parallel, so it cannot protect a cache they all share. Don't shorten the reader's hold either: the key lock must span existence check → SHA re-verification → copy-out, or eviction can unlink the entry between the check and the read. Eviction must take each victim's key lock (`flock -n`, skip if held) before unlinking, and no path may ever hold two key locks at once
- Don't fetch BSP packages by bare name or accept apt's latest version. Update `armbian-bsp-deb-versions.txt` only after signed-index review; update `bsp-baseline.json` with the kernel pin when its reviewed bytes change
- Don't make a family variant implicit. `--variant` is the ONLY selector (plus `CERALIVE_KERNEL_VARIANT`); never infer one from a board, host, branch or CI context
- Don't pin `kernel_source.patches_commit` (or `commit`, or `builder_image`) to anything but an exact SHA/digest — a branch there is unreproducible while looking pinned, and both the schema and `build-kernel.sh` reject it
- Don't hand-write `kernel_source.suppressed_packages`; it is derived by `resolve.py` and the schema rejects an authored one
- Don't add a synthetic `kernel_source.tag` to a source whose pinned branch publishes none (the vendor BSP's `rk-6.1-rkr5.1`). `tag` is optional precisely so the pin stays an honest commit; a placeholder tag is a false provenance claim, and cloning the branch tip instead silently builds newer source under an unchanged pin
- Don't replace `vendor-patched`'s fetched Armbian `.config` with `make defconfig`. It is the exact config `linux-image-vendor-rk35xx` ships; a bare defconfig builds a materially different driver set, so the result is no longer comparable to the kernel the fleet runs — which is the only reason this variant exists
- Don't name a source-built kernel package after a stock one. `vendor-patched` builds `linux-image-6.1.115-ceralive-vendor-rk35xx`, never `linux-image-vendor-rk35xx`: a name collision is the one failure that produces a plausible image instead of an error, because the local repository would pick one by version and the board could boot the UNPATCHED kernel
- Don't silence a config-survival failure by widening `kernel_source.config_absent_symbols`. Every entry is a reviewed statement that the symbol names an out-of-tree driver Armbian's framework injects and this pipeline does not; a listed symbol that DID survive fails the build as a stale exception, and that non-vacuity is what stops the list becoming a blanket opt-out of the gate
- Don't duplicate `make olddefconfig` / `make syncconfig` / `make -s kernelrelease` into the per-mode branches of `build-kernel.sh`. Both config modes converge on one sequence, and `manifest.bats` statically requires exactly one occurrence of each
- Don't read a board default-environment variable in `boot.scr.cmd`. `loadaddr` was undefined on the Orange Pi 5 Plus while every `*_addr_r` was fine, and the empty expansion did not degrade the write — it dropped the address argument, wrote the env blob through `BOOT_ORDER`, and halted the board on an SError that only a power cycle clears. The script defines its own scratch address; a new one must be defined there too
- Don't make `/boot/Image` a symlink to a `bindeb-pkg` `vmlinuz-<REL>` without reading its first bytes. arm64's `KBUILD_IMAGE` default is `arch/arm64/boot/Image.gz`, so that vmlinuz is GZIP, and whether `booti` copes is a per-board U-Boot fact the two shipped boards answer differently (2026.04 `CONFIG_GZIP=y` vs the 2017.09 Rockchip fork, which has no such symbol). Decompress it into a real file at staging time — and don't "simplify" the follow-up magic assertion away either: `gzip -dc` exiting 0 on the wrong payload still ships an unbootable slot
- Don't set `CERALIVE_BENCH_LABELS` on any release/publish path — it produces a bench-only image that is not the frozen contract. Don't rename a PARTLABEL at ONE site: the GPT, both fstab entries, the RAUC `system.conf` and the compiled U-Boot selector must move together or the card does not boot
- Don't regenerate `v2/tests/fixtures/gpt-baseline/*.gpt` to make a test pass — like the vendor-baseline `.params`, those fixtures ARE the proof the production layout did not move. A diff there is a fleet re-flash, not a test fix
- Don't regenerate `v2/tests/manifests/fixtures/vendor-baseline/*.params` to make a test pass — those fixtures ARE the proof that the production path did not move. A diff there means the change moved it
- Don't add `bsp-provenance.json` to the build-matrix `sha256` determinism comparison — it is gitignored build output by design
- Don't "simplify" `suppress_unusable_boot_units` to `disable_service`. `/etc/machine-id` ships `uninitialized`, so PID 1 runs `preset-all` on first boot and re-enables anything merely disabled; `systemd-networkd.service`'s `Also=systemd-networkd-wait-online.service` overrides even the preset's own `disable` verdict. Only a mask survives
- Don't unmask `dnsmasq.service` believing it serves the WiFi hotspot — NetworkManager spawns its own dnsmasq CHILD PROCESS for `ipv4.method shared`; the standalone unit only ever fights `systemd-resolved` for port 53. Don't drop `dnsmasq` from `shared.list` either: that child needs the binary
- Don't widen the boot-unit masks to `NetworkManager`, `systemd-resolved`, `systemd-udevd` or `chrony.service`. The `.link` interface-naming files are consumed by udev's built-in `net_setup_link`, not by the networkd daemon, and `chrony-wait` is the boot GATE — `chronyd` itself must keep running
- Don't "improve" the fan curve by writing `thermal_zone*/mode`, `cooling_device*/cur_state` or the hwmon `pwm1` node, and don't add a userspace polling loop to `ceralive-fan-curve`. Disabling a zone also disables its 115 °C `critical` trip; driving `cur_state` means owning the fan forever, including across suspend and shutdown. The kernel `step_wise` governor is board-proven correct — the only thing that was ever wrong for THAT unit is the threshold it acts on. (`ceralive-fan-kickstart` is the one sanctioned exception, and only to the `cur_state`/resident-loop half: it is a separate unit that writes `cur_state` exactly twice per 0 → nonzero edge and always hands the governor's own state back. `mode`, `pwm1` and trip points remain out of bounds for both.)
- Don't delete `ceralive-fan-kickstart`'s restore write as a redundant round trip, and don't rewrite it as "kick, then let the governor's next poll correct it". On this kernel a userspace `cur_state` write is STICKY: `cur_state_store()` never clears `cdev->updated`, `thermal_cdev_update()` short-circuits while that flag is set, and `step_wise` clears it only when its computed target CHANGES — so with the temperature inside one trip band the governor never writes again and the fan stays at 100 % indefinitely. Upstream's own in-driver version restores explicitly too
- Don't kick to a hand-invented "100 %", to `255`, or to the reference board's `max_state` of `4`, and don't read `cooling-levels`. The kick value is the discovered device's OWN `max_state`; the unit works purely in cooling-state space so it does not care what duty cycles a board's DT maps those states onto
- Don't give `ceralive-fan-kickstart` `Restart=always` or `ProtectKernelTunables=yes`. It exits 0 on purpose on a board with no `pwm-fan`, so `always` becomes a hot respawn loop; `ProtectKernelTunables=yes` remounts `/sys` read-only and breaks the one write the unit exists to make
- Don't hardcode `thermal_zone0`/`cooling_device4` in the fan-curve script, and don't lower a trip that is not the FIRST `active` one. Both index spaces are registration-order artefacts confirmed to differ per board and per kernel tree, and the `critical` trip is the board's last line of defence
- Don't write `brightness` on an LED that has a trigger, and don't hardcode `blue:indicator-1`/`green:indicator-2` in the LED script. A trigger hands the LED to the kernel — writing brightness afterwards fights it, exactly as writing `cur_state` would fight the thermal governor — and those names are vendor DTS labels with no semantics that differ per board and per kernel tree
- Don't touch the `mmc0::`/`mmc1::` LED or go looking for a red one. The `mmc*` LEDs are the MMC core's own already-working activity LEDs, and there is NO red LED in the kernel's LED class on this board at all — the visible red one is a hardwired power-rail indicator with no software visibility

## KNOWN ISSUES / DEFERRED

Full index with file:line anchors and unblock conditions: [`v2/docs/DEFERRED.md`](v2/docs/DEFERRED.md).

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
both lists and additionally pinned by `manifest.bats` §27.
`PassEnvironment=` MUST stay in lockstep with `env_names`; the structural guard is
`manifest.bats` "mkosi PassEnvironment stays in lockstep with … env_names" (it
fails the build if a future `env_names` addition skips `PassEnvironment=`).
`SOURCE_DATE_EPOCH` (host-side/mkosi-native) and `CERALIVE_V2_DIR` (forwarded via
a separate `-e`/`--environment` mechanism) are the two documented legitimate
asymmetries.

**OPi 5+ interface ID_PATHs are FIXME placeholders.** `manifests/boards/orange-pi-5-plus.yaml`
ships the `interfaces:` block with `FIXME-…` values because the board is not in
hand. The OPi 5+ has two onboard r8169 NICs on the same driver/bus, so a generic
`Type=ether` match races. Before building an OPi 5+ image, read the real ID_PATHs
on the device (`udevadm info /sys/class/net/<iface> | grep ID_PATH`) and replace
each FIXME. Until then `install_interface_naming()` skips the FIXME values and
emits only the generic `Type=wlan → wlan0` rule; the dual NICs stay
non-deterministic.

**Modem source-routing under NM `dhcp=internal` — FIXED.** NetworkManager in
Debian bookworm defaults to `dhcp=internal` (its own DHCP client), which does NOT
execute `dhclient-exit-hooks.d/`, so the SRTLA dhclient hook
(`/etc/dhcp/dhclient-exit-hooks.d/srtla-source-routing`) never fired for
NM-managed modems. The NM dispatcher
(`/etc/NetworkManager/dispatcher.d/90-srtla-wifi-routing`) now also matches modem
interfaces (`usb0..7` and `enx*0..7`) and installs the same source rule + default
route in tables 100–107, mirroring the dhclient-hook semantics. The dhclient hook
is retained (harmless; still covers non-NM dhclient paths). Both drift-gated SRTLA
payloads were twin-updated in one commit (`networking-srtla.sh` and the `§6` block
in `mkosi.postinst.chroot`); `v2/ci/postinst-drift-check.sh` CHECK 2 confirms
byte-parity. WiFi table assignments (120–124) are unchanged. Verify on hardware
with a modem attached: `journalctl -t srtla-routing` and `ip rule show` after the
modem connects.

**Modem `usb0..7` naming is hardware-gated.** Deterministic modem renames need a
physical modem to read its ID_PATH; not implemented here. Only `eth0/eth1/wlan0`
are pinned today.

**Cog render QA hardware-gated.** `cog.sysext.conf` + build wrapper are inert
scaffolds until a physical RK3588 validates render (OKLCH/Tailwind v4 on WebKit
2.38.6, Mali-G610 EGL/GBM wiring). See [`v2/docs/cog-display-addon.md §7`](v2/docs/cog-display-addon.md).
