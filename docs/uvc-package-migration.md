# UVC package migration [EXISTS]

The pipeline selects `gstreamer1.0-libuvcsrc=2026.9.0`, produced by
[`gstlibuvcsrc` v2026.9.0](https://github.com/CERALIVE/gstlibuvcsrc/releases/tag/v2026.9.0).
The release was published on 2026-09-16 after producer PR #29 merged at
`8fe5ba50e8c28ceeffba8a3b896b245fff53bd96`. Both stable APT architectures serve
the canonical package. The APT index, downloaded payload, GitHub asset and
release checksum sidecar agree on these SHA-256 values:

| Architecture | SHA-256 |
|---|---|
| arm64 | `4fcc86fbb782c1361b07814071ff561cb14a4bfe396c441109ed3a85a590594b` |
| amd64 | `08a7e50ff37a446f6d4fc779428589642b0b6888916e0ade7945255fc57a5879` |

## Name-keyed contracts

- `manifests/first-party-deb-versions.txt`: unprefixed Debian version `2026.9.0`.
- `versions.yaml`: canonical producer key, path and URL; tag pin `v2026.9.0`.
- `lib/fetch-debs.sh`: `FIRST_PARTY_APT_PKGS` fetches the canonical package only.
- `mkosi/mkosi.images/app/mkosi.postinst.chroot`: `SYSEXT_APP_PKGS` installs it.
- `lib/stages/partition.sh`: staged-package classification routes it to the app input.
- `mkosi/customize/postinst.d/persistence.sh`: never-freeze policy keeps it apt-updatable.
- `ci/pin_versions.py`: `APP_COMPONENTS` maps it to `gstlibuvcsrc` and must still
  equal the fetch list exactly.
- `manifests/first-party-releases.json`: refreshed release evidence records the
  actual canonical package identities on both architectures, not renamed old assets.
- Package, install, migration-coverage and freeze tests assert the same contract.
  The fetch-plan regression asserts the exact package and version. The digit-bearing
  YAML parser fixture retains its digits under a neutral fixture name.

Historical input: `gstreamer1.0-libuvch264src=2026.8.0` was the pre-migration pin.
The producer owns its versioned compatibility Provides/Conflicts/Replaces; the
image neither fetches a second payload nor keeps an old-name classifier alias.
The plugin filename and libuvc SONAME chain are unchanged. There is no UVC-specific
sysext filename exclusion to rename. Capture is portable; RK3588 acceleration
remains a separate platform dependency.

## Verification boundary

Run `python3 ci/check-first-party-pins.py --refresh` to rediscover every producer
release, then `./run-tests` and `DRY_RUN=1 ./build <board>` for each RK3588 board.
The guard's stale-pin, package/registry mismatch and missing-evidence refusals stay
unchanged; no override is added. The existing plugin pin is untouched.

This records released inputs and pipeline wiring only. No image build, flash,
board installation or new hardware qualification accompanies this migration.
