# UVC package migration [PARTIAL]

Canonical repository: `gstlibuvcsrc`. Canonical package:
`gstreamer1.0-libuvcsrc`, providing/replacing `gstreamer1.0-libuvch264src`.
The payload remains one `libgstlibuvch264src.so` plus the libuvc SONAME chain.
Capture is portable; RK3588 acceleration is a separate platform dependency.

Partition classification and the never-freeze contract accept the canonical
package. Pin-currency resolution maps the published package to `gstlibuvcsrc`.
The recorded release catalog retains actual old-name package identities: a
repository rename does not rename a published archive's Package field.

**Do not merge this migration PR until the producer is released and served.**
The active fetch list and `gstreamer1.0-libuvch264src=2026.8.0` pin remain real
published inputs. Complete this same PR, without a second transition release:

1. Verify the new release's arm64 and amd64 packages are served by APT.
2. Replace the UVC row in `manifests/first-party-deb-versions.txt` with the exact
   published new-name version; refresh `manifests/first-party-releases.json`.
3. Switch `FIRST_PARTY_APT_PKGS` in `lib/fetch-debs.sh` and matching install,
   migration-coverage and package-contract expectations to the new name.
   Switch `APP_COMPONENTS` in `ci/pin_versions.py` at the same time: its keys must
   equal the fetch list exactly, so pre-adding an unpinned package is rejected.
4. Run the full gate and both board-variant dry runs. No hardware is needed.

There is no UVC-specific sysext filename exclusion to rename. The exact-name
fetch, partition and freeze contracts above must remain aligned. Existing
digit-bearing YAML-key fixtures test parser coverage, not a live repository name.
