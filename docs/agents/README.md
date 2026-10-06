# Pipeline agent reference

[Entry rules](../../AGENTS.md). Read the applicable contract before editing its subsystem.

Every original section is preserved below, including historical findings and deferred work; status and scope remain as recorded.

| Original heading | Preserved file | Governed paths / scope |
|---|---|---|
| Overview (preamble) | [overview.md](overview.md) | `docs/uvc-package-migration.md` |
| ROLE IN THE GROUP | [role-in-the-group.md](role-in-the-group.md) | Repository role, layout and contribution scope |
| STRUCTURE | [structure.md](structure.md) | Repository role, layout and contribution scope |
| WHERE TO LOOK | [where-to-look.md](where-to-look.md) | `docs/dev-loop.md`; `manifests/target-release.env`; `lib/shared/target-release-lib.sh::target_release_load`; `ci/check-suite-literals.sh`; `tests/target-release-derivation.test.sh`; `lib/stages/<stage>.sh`; `lib/build-kernel.sh`; `lib/kernel/{config,checkout,builder,package}.sh`; `manifests/families/rk3588.yaml`; `lib/resolve.py::resolve_default_variant`; `tests/variant-contract.bats`; `manifests/kernel/rk3588-edge.fragment` |
| KEY FACTS | [key-facts.md](key-facts.md) | `ci/check-first-party-pins.py`; `manifests/first-party-releases.json`; `manifests/first-party-pin-overrides.json`; `docs/first-party-pin-currency.md`; `tests/healthcheck-boot-marker.bats`; `tests/apt-mtls-and-dedupe.test.sh`; `tests/real-avahi-hostname-contract.sh`; `tests/runtime-services.bats`; `tests/mkosi-contract.bats`; `docs/bluetooth-firmware-closure.md`; `tests/variant-contract.bats`; `docs/kernel-build-from-source.md` |
| ADD-ON SUBSYSTEM [EXISTS] | [add-on-subsystem.md](add-on-subsystem.md) | `manifests/schema/addon.schema.json`; `lib/app-layer/sysext.sh`; `lib/upload-addons.sh`; `docs/addon-sysext-refresh.md`; `mkosi/runtime/`; `docs/ssh-hardening.md`; `lib/parity-check.sh`; `/usr/lib/systemd/system-preset/80-mkosi-ssh.preset`; `tests/ssh-enablement-contract.test.sh`; `tests/systemd-ordering-cycle.test.sh`; `ci/uart-provision-ssh.sh`; `tests/uart-console-path.test.sh` |
| KIOSK STACK | [kiosk-stack.md](kiosk-stack.md) | `manifests/kernel/required-symbols.list`; `manifests/families/rk3588.yaml`; `docs/cog-display-addon.md`; `docs/kiosk-display.md §7`; `docs/kiosk-display.md §3` |
| ANTI-PATTERNS | [anti-patterns.md](anti-patterns.md) | `manifests/target-release.env`; `ci/check-suite-literals.sh`; `mkosi/mkosi.conf`; `tests/dongle-netns-retirement.test.sh`; `ci/fetch-rk3588-loader.sh`; `manifests/kernel/required-symbols.list`; `ci/build-hardware-candidates.sh`; `lib/orchestrate.sh`; `tests/fixtures/gpt-baseline/*.gpt`; `tests/manifests/fixtures/vendor-baseline/*.params`; `tools/gen-hdmirx-edid.py` |
| KNOWN ISSUES / DEFERRED | [known-issues-deferred.md](known-issues-deferred.md) | `docs/DEFERRED.md`; `mkosi/mkosi.conf`; `manifests/boards/orange-pi-5-plus.yaml`; `tests/manifests/fixtures/vendor-baseline/orange-pi-5-plus.params`; `mkosi/customize/networking-srtla.sh`; `ci/postinst-drift-check.sh`; `lib/parity-check.sh`; `tests/dongle-netns-retirement.test.sh`; `docs/cog-display-addon.md §7` |
