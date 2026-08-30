# Bookworm → Trixie OTA transition contract and validation

**Status:** `[EXISTS]` — the transition is complete. The corrected Trixie/mainline
image built and OTA-booted on both RK3588 bench boards; the Orange Pi also completed
the deliberate-failure fallback and restoration arm.

## Verdict

```yaml
transition: ota
hardware-gated: complete
fleet-installer: rauc-1.8
first-trixie-bundle-format: plain
```

This is an OTA-compatible boot-protocol transition, not a bootloader update.
The conclusion rests on four independently checkable facts:

1. RAUC writes only the inactive `rootfs` slot. The 16 MiB raw gap containing
   idbloader, U-Boot and ATF, and the shared FAT boot partition containing
   `boot.scr`, `cera_board.env` and `boot_state.txt`, are not RAUC slots.
   `mkosi/platform/boot/install-boot.sh` installs those boot-partition artifacts
   only while assembling a full `.raw`; `mkosi/runtime/rauc/system.conf` exposes
   only `rootfs_a`, `rootfs_b`, and the data-backed certificate placeholder to
   RAUC. The deployed bootloader therefore remains in place during the OTA.
2. The deployed selector already boots a mainline slot through the stable arm64
   `booti` protocol. A real Rock 5B+ running RAUC 1.8 installed and booted an
   edge v7.1 bundle in the prior bench campaign
   (`.omo/evidence/device-platform-wave4/task-rauc-ota-validation.md`). The
   current image still supplies the same inputs: a raw arm64 `Image` carrying
   `ARM\x64` magic at offset 56, the board DTB, optional initrd, and the same
   `root=PARTLABEL=… rauc.slot=…` arguments. The `[6b/9]` boot-artifact gate
   checks those properties. Linux's arm64 boot contract is version-independent
   across this 7.1 → 7.2 move; neither a Debian suite name nor a kernel minor is
   part of the `booti` interface.
3. RAUC explicitly intends bundles created by newer versions to remain
   installable by older versions when new bundle features are not enabled. RAUC
   1.13 still defaults to `plain`, and RAUC 1.8 accepts `plain`. The first Trixie
   bundle pins `[bundle] format=plain` explicitly and uses only the common
   `[update]` + `[image.rootfs]` fields.
4. The fleet identity and trust chain do not change. `compatible` remains the
   exact board-specific `ceralive-<board-id>` string in both the installed
   `system.conf` and signed manifest. The signing path remains leaf key +
   intermediate chain, verified to the same baked root. `check-purpose` stays
   unset, so both RAUC 1.8 and 1.13 use OpenSSL's `smime_sign` purpose and accept
   the existing dual-EKU leaf.

The attempted drill also established one Trixie-only config constraint. RAUC
1.13 hard-rejects `bootloader=custom` combined with RAUC's native
`boot-attempts=` key, which is supported only by `uboot` and `barebox`. The
RK3588 custom backend already owns the attempt budget in FAT `boot_state.txt`, so
the three custom config writers now omit that key with no substitute. The
opt-in real-RAUC contract loads the authoritative generated config and starts the
service; an injected `boot-attempts=3` is its negative control.

Primary references:

- [RAUC 1.13 compatibility policy](https://rauc.readthedocs.io/en/v1.13/basic.html#forward-and-backward-compatibility)
- [RAUC 1.13 bundle formats](https://rauc.readthedocs.io/en/v1.13/reference.html#bundle-formats)
- [RAUC 1.8 bundle formats](https://rauc.readthedocs.io/en/v1.8/reference.html#sec-ref-formats)
- [Linux arm64 boot protocol](https://docs.kernel.org/7.1/arch/arm64/booting.html)
- [U-Boot `booti`](https://docs.u-boot.org/en/v2025.04/usage/cmd/booti.html)

### Validation record

The earlier offline-only judgment is superseded by the completed release chain.
Todo 31 passed on the exact Trixie/mainline/PipeWire image; todo 37 then released
cerastream v2026.8.4 and ceralive-device v2026.8.8, built signed parity-clean images
for both boards, and installed them by RAUC. Both boards booted the released stack
healthy. The Orange Pi additionally marked its released slot bad, rebooted into the
known-good alternate slot, then restored and revalidated the released slot. This is
the explicit fallback proof; the Rock OTA separately completed its healthy final-slot
validation. Full evidence is in
`.omo/evidence/cerastream-glibc-pipewire-network-ui/todo37-release-chain.md`.

## Trixie bundle compatibility profile

The released Trixie image keeps all of these invariants:

```ini
[update]
compatible=ceralive-<exact-board-id>

[bundle]
format=plain

[image.rootfs]
filename=rootfs.tar
sha256=<generated>
size=<generated>
```

- Do not enable `verity`, `crypt`, artifact repositories, conversion sections,
  or any other post-1.8 manifest feature for this transition release.
- Do not change the compatible string, root CA, intermediate chain, signer leaf,
  or verification purpose during the suite transition.
- Do not add a restrictive `bundle-formats=` system setting that excludes
  `plain`.
- Future releases may tighten the format only after an explicit compatibility
  decision; this release record does not authorize that change.

Guards: `tests/rauc-transition-contract.test.sh` checks the real bundle writer
and all three custom `system.conf` writers, including the absence of RAUC-native
attempt counting. `tests/real-rauc-contract.sh` starts a real daemon with the
authoritative rendered config. Both suites carry mutations that must be rejected.

## Completed A/B validation

The historical Bookworm-to-Trixie runbook is retired with the completed transition.
For future Trixie-to-Trixie updates, follow `docs/RELEASE-PROCESS.md` and retain the
same evidence class: signed-bundle identity, RAUC install result, slot order and
healthcheck state before reboot, post-reboot service and package verification, and
an explicit fallback drill when the change warrants one. A green offline contract
test is not a substitute for those hardware receipts.
