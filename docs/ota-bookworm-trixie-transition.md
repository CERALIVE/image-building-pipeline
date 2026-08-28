# Bookworm → Trixie OTA transition contract and drill

**Status:** `[PARTIAL]` — the transition is **OTA-feasible**, and the bundle
compatibility contract is enforced offline. The current mainline v7.2 image has
not yet completed this drill on hardware; todo 16 owns that execution.

## Verdict

```yaml
transition: ota
hardware-gated: not-run
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

Primary references:

- [RAUC 1.13 compatibility policy](https://rauc.readthedocs.io/en/v1.13/basic.html#forward-and-backward-compatibility)
- [RAUC 1.13 bundle formats](https://rauc.readthedocs.io/en/v1.13/reference.html#bundle-formats)
- [RAUC 1.8 bundle formats](https://rauc.readthedocs.io/en/v1.8/reference.html#sec-ref-formats)
- [Linux arm64 boot protocol](https://docs.kernel.org/7.1/arch/arm64/booting.html)
- [U-Boot `booti`](https://docs.u-boot.org/en/v2025.04/usage/cmd/booti.html)

### Evidence boundary

The bench network was genuinely probed while recording this verdict. The former
Rock address `192.168.78.131` returned `No route to host`. `ceralive.local` and
`192.168.78.132` completed an SSH handshake and identified Debian Bookworm's
OpenSSH server, but refused the available non-interactive credentials. No remote
command ran, so this is a documented judgment from repository contracts, RAUC's
compatibility policy, the earlier v7.1 hardware OTA, and the stable boot protocol
— **not** a claim that v7.2 booted during todo 12.

If todo 16 finds that the deployed U-Boot cannot boot the exact v7.2 candidate,
stop. Change this verdict to `transition: reflash-only`, retain the evidence, and
use the full-image flash procedure in `DEVICE-BRINGUP.md`. That outcome is
acceptable for this DIY, not-for-sale bench fleet under the workspace
`docs/DIY-POSTURE.md`; it must not be disguised as a successful OTA.

## First-Trixie bundle compatibility profile

The **first** Trixie release must keep all of these invariants:

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
- Later releases may tighten the format only after every device has booted a
  Trixie slot and therefore runs the newer RAUC.

Guard: `tests/rauc-transition-contract.test.sh`. It checks the real bundle
writer and both `system.conf` writers, and carries format/compatible mutations
that must be rejected.

## Todo 16 A/B transition drill (runbook only; not executed here)

Run on one board at a time with UART attached. Use a production-labelled A/B
medium, a candidate signed by the root installed on that board, and a temporary
SSH credential provisioned by the existing hardware-candidate workflow.

```bash
export BOARD_IP=<bench-ip>
export SSH_USER=ceralive
export SSH_IDENTITY_FILE=<temporary-run-key>
export GOOD_BUNDLE=images/rock-5b-plus/<candidate>.raucb
export BAD_BUNDLE=<purpose-built-trixie-bundle-with-cerastream-removed>.raucb
SSH=(ssh -o BatchMode=yes -o IdentitiesOnly=yes -i "$SSH_IDENTITY_FILE" \
  "$SSH_USER@$BOARD_IP")
```

Expected precondition: Bookworm, RAUC 1.8, a confirmed-good current slot, and a
different inactive slot. Never reboot into a candidate if the current Bookworm
slot has no remaining boot budget.

```bash
"${SSH[@]}" 'grep -E "^(VERSION_ID|VERSION_CODENAME)=" /etc/os-release; rauc --version; cat /proc/cmdline; ceralive-boot-state dump; rauc status'
# expected: VERSION_ID="12" / bookworm; rauc 1.8; rauc.slot=A|B;
#           current Bookworm slot reports good with a non-zero budget

mkdir -p /tmp/todo16-config/bookworm /tmp/todo16-config/trixie
scp -o BatchMode=yes -o IdentitiesOnly=yes -i "$SSH_IDENTITY_FILE" \
  "$SSH_USER@$BOARD_IP:/data/ceralive/config.json" /tmp/todo16-config/bookworm/
scp -o BatchMode=yes -o IdentitiesOnly=yes -i "$SSH_IDENTITY_FILE" \
  "$SSH_USER@$BOARD_IP:/data/ceralive/setup.json" /tmp/todo16-config/bookworm/
python3 -m json.tool /tmp/todo16-config/bookworm/config.json >/dev/null
python3 -m json.tool /tmp/todo16-config/bookworm/setup.json >/dev/null
(cd /tmp/todo16-config/bookworm && sha256sum config.json setup.json) \
  | tee /tmp/ceralive-bookworm-config.sha256
# expected: both host-side JSON parses succeed and two SHA-256 rows print

rauc info -C keyring:check-purpose=codesign \
  --keyring=<candidate-pki>/root-ca.pem "$GOOD_BUNDLE"
# expected: Bundle Format: plain; Compatible: ceralive-<this-board>
```

### Failure arm — prove automatic rollback to Bookworm

Run this arm **before** the successful arm, or restore the original Bookworm A/B
baseline first. The inactive slot must still be expendable and the known-good
slot must still contain Bookworm.

```bash
CERALIVE_ROLLBACK_MODE=live \
BOARD_IP="$BOARD_IP" SSH_USER="$SSH_USER" \
SSH_IDENTITY_FILE="$SSH_IDENTITY_FILE" \
CERALIVE_CI_ACCESS_ID=<provisioned-run-access-id> \
BAD_BUNDLE="$BAD_BUNDLE" GOOD_BUNDLE="$GOOD_BUNDLE" \
bash tests/rauc-rollback.sh | tee /tmp/todo16-bookworm-trixie-ab.log
```

The harness installs the deliberately unhealthy Trixie bundle without forcing a
slot. Expected decisive lines include:

```text
bad slot B failed healthcheck → NOT marked good
bad slot exhausted its bootcount
automatic rollback returned to last-known-good slot A
good slot healthcheck PASSED → rauc mark-good
```

After the failure phase, independently prove the rollback target is Bookworm:

```bash
"${SSH[@]}" 'grep -E "^(VERSION_ID|VERSION_CODENAME)=" /etc/os-release; cat /proc/cmdline; rauc status; journalctl -u ceralive-healthcheck.service -b --no-pager'
# expected: VERSION_ID="12" / bookworm; rauc.slot=<original-slot>;
#           failed Trixie slot bad, Bookworm slot booted and good
```

### Success arm — apply and confirm Trixie

The same harness continues with the healthy bundle after returning to Bookworm.
Once it exits `RESULT: PASS`, verify the actual transition and persistent data:

```bash
"${SSH[@]}" 'grep -E "^(VERSION_ID|VERSION_CODENAME)=" /etc/os-release; rauc --version; cat /proc/cmdline; systemctl is-active ceralive-healthcheck.service; rauc status'
# expected: VERSION_ID="13" / trixie; rauc 1.13.x; new rauc.slot booted;
#           healthcheck active/exited-success and the Trixie slot good

scp -o BatchMode=yes -o IdentitiesOnly=yes -i "$SSH_IDENTITY_FILE" \
  "$SSH_USER@$BOARD_IP:/data/ceralive/config.json" /tmp/todo16-config/trixie/
scp -o BatchMode=yes -o IdentitiesOnly=yes -i "$SSH_IDENTITY_FILE" \
  "$SSH_USER@$BOARD_IP:/data/ceralive/setup.json" /tmp/todo16-config/trixie/
python3 -m json.tool /tmp/todo16-config/trixie/config.json >/dev/null
python3 -m json.tool /tmp/todo16-config/trixie/setup.json >/dev/null
(cd /tmp/todo16-config/trixie && sha256sum config.json setup.json) \
  | tee /tmp/ceralive-trixie-config.sha256
diff -u /tmp/ceralive-bookworm-config.sha256 /tmp/ceralive-trixie-config.sha256
# expected: both JSON parses succeed and diff emits no output

"${SSH[@]}" 'sudo systemctl reboot'
# reconnect, then:
"${SSH[@]}" 'grep VERSION_ID /etc/os-release; rauc status; ceralive-boot-state dump'
# expected: still Trixie on the same confirmed-good slot; no spontaneous reversion
```

Archive the UART log, harness transcript, pre/post JSON hashes, `rauc status`,
healthcheck journal, and exact candidate digest. A green offline contract test is
not a substitute for those hardware receipts.
