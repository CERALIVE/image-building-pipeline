# Boot dpkg recovery and healthy-state record [PARTIAL]

The image installs and enables `ceralive-dpkg-recover.service` from
`postinst.d/services.sh::setup_dpkg_recovery`, called by `configure_services()`.
The oneshot runs after local filesystems and before `ceralive.service` and
`ceralive-healthcheck.service`. It checks both `/var/lib/dpkg/updates/` and
`dpkg --audit`; when either is non-clean it gives `dpkg --configure -a` exactly
600 seconds. Its `/run/ceralive/dpkg-recovered` marker says `result=success` or
`result=failure`. A failure does not confirm the slot: healthcheck independently
rechecks dpkg even when a same-boot `.slot-marked-good` marker is present.

Healthcheck also rejects `/run/ceralive/partlabel-guard.failed`. Only after a
successful `rauc status mark-good` does it atomically replace
`/data/ceralive/update-state/healthy-state.json`. That record carries the kernel
boot ID, boot-selected A/B slot, build ID, SHA-256 of `/var/lib/dpkg/status`, and
UTC recording time. Build ID comes from `/etc/os-release` `BUILD_ID`, or the
already-baked `/etc/ceralive/image-build-commit` if absent; the slot-sync gate
reads the same inputs. An unidentifiable slot or build refuses confirmation.

The deliberate-failure drill requires **both** `/etc/ceralive/debug-image` and
`/etc/ceralive/testing/force-healthcheck-fail`. Either file alone is inert;
normal production cannot arm the hook with only the testing file. This is an
offline contract, not a claim of a new built/booted image or a completed updater.

Proof: `bats tests/healthcheck-boot-marker.bats`,
`bash tests/systemd-ordering-cycle.test.sh`, and
`ci/postinst-drift-check.sh`. The RAUC 1.13 / Linux 7.2 verity incompatibility
was resolved in this branch by building RAUC 1.15.2 from source (see
[`rauc-build-from-source.md`](rauc-build-from-source.md)); the image and board
validation of this combination remain separate from these host tests.
