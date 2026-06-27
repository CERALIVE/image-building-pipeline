#!/usr/bin/env bats
#
# x86-raucb-bundle.bats — the canonical acceptance gate for the x86 signed-OTA
# wiring (T10). An OFFLINE, REAL-bundle sign + verify + tamper proof that the x86
# (efi/grub) Stage-4 path emits a genuine signed `.raucb` the device would accept.
#
# This is the END-TO-END twin of manifest.bats §11 (reproducibility): there the
# focus is bit-determinism on the RK3588 board; here it is the x86 board's signed
# OTA artifact — driven through the SAME board-agnostic build-bundle.sh, against
# the committed dev PKI (v2/.dev-keys), stamped with the x86 compatible.
#
# Scope (no image boot, no orchestrator run, no network):
#   1. STATIC WIRING : orchestrate.sh's efi/grub Stage-4 branch invokes
#                      BUILD_BUNDLE_SH — the x86 path actually produces a bundle.
#   2. REAL SIGN+VERIFY : build-bundle.sh x86-minipc <rootfs> produces a real
#                      `.raucb`; its CMS chain verifies leaf -> intermediate ->
#                      root against the dev root-CA keyring (openssl cms -verify).
#   3. TAMPER : flipping one byte of the bundle payload makes verification FAIL
#                      (the signature has teeth — a mutated slot image is rejected).
#   4. MANIFEST : the manifest.raucm embedded IN the produced bundle carries
#                      compatible=ceralive-x86-minipc (what `rauc install` matches
#                      against the device system.conf).
#
# PKI: the THROWAWAY dev keypair under v2/.dev-keys (root-ca.pem, chain.pem,
# leaf-signing.pem, leaf-signing.key — symlinks onto the dev-* files). This NEVER
# touches the production signing PKI, and uses only a repo-local path
# (CERALIVE_RAUC_PKI_DIR="$V2/.dev-keys") — no path escapes this checkout (Rule D).
#
# Dependency: bats-core + mksquashfs + unsquashfs + openssl. Missing toolchain ->
# the real-bundle sections SKIP (still green), exactly like §11/§14 — a host
# without squashfs-tools never false-fails. The dev PKI is committed, so the
# signing chain is always exercised for real when the toolchain is present.
#
# Run:  v2/run-tests              (CI entrypoint — registered alongside manifest.bats)
#   or: bats v2/tests/x86-raucb-bundle.bats

setup() {
  TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  V2="$(cd "$TESTS_DIR/.." && pwd)"
  LIB_DIR="$V2/lib"
  BUILD_BUNDLE="$LIB_DIR/build-bundle.sh"
  ORCH="$LIB_DIR/orchestrate.sh"
  DEV_KEYS="$V2/.dev-keys"
  COMPAT="ceralive-x86-minipc"
  BOARD="x86-minipc"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# raucb_prereqs — the real signer/verifier needs mksquashfs + unsquashfs +
# openssl, plus the committed dev PKI. Anything missing -> the test SKIPs (still
# green) rather than false-fail on a host without squashfs-tools.
raucb_prereqs() {
  command -v mksquashfs >/dev/null 2>&1 || return 1
  command -v unsquashfs >/dev/null 2>&1 || return 1
  command -v openssl    >/dev/null 2>&1 || return 1
  [ -s "$DEV_KEYS/leaf-signing.key" ] || return 1
  [ -s "$DEV_KEYS/root-ca.pem" ]       || return 1
  return 0
}

# efi_branch — extract ONLY the efi/grub adapter branch of orchestrate.sh's
# Stage-4 dispatch: from the `RAUC_BOOTLOADER_ADAPTER == "efi"` guard down to the
# unsupported-adapter die that terminates the dispatch. Starting at the efi guard
# guarantees any BUILD_BUNDLE_SH match is the x86 invocation, never the RK3588
# custom branch's.
efi_branch() {
  awk '
    /RAUC_BOOTLOADER_ADAPTER.*== "efi"/ { f = 1 }
    f                                   { print }
    f && /unsupported bootloader_adapter/ { exit }
  ' "$ORCH"
}

# build_x86_bundle — build a REAL signed x86 `.raucb` ONCE per file into
# BATS_FILE_TMPDIR (idempotent), driving the board-agnostic build-bundle.sh with
# the dev PKI + the x86 compatible. Under `bats --jobs N` the four sections call
# this concurrently, so the build runs inside a flock'd subshell: exactly one
# test populates the shared fixture, the rest see it already built. Echoes
# nothing; the bundle lands at $BATS_FILE_TMPDIR/out/x86.raucb.
build_x86_bundle() {
  local out="$BATS_FILE_TMPDIR/out"
  local bundle="$out/x86.raucb"
  (
    command -v flock >/dev/null 2>&1 && flock 9
    [ -f "$bundle" ] && exit 0          # idempotency check INSIDE the lock (no TOCTOU)
    local tree="$BATS_FILE_TMPDIR/rootfs"
    mkdir -p "$tree/etc" "$tree/usr/bin"
    printf 'ceralive\n' > "$tree/etc/hostname"
    printf 'slot-image\n' > "$tree/usr/bin/app"
    mkdir -p "$out"
    env CERALIVE_RAUC_PKI_DIR="$DEV_KEYS" \
        COMPATIBLE_STRING="$COMPAT" \
        BUNDLE_VERSION="x86raucbtest" BUNDLE_TS="x86" BUNDLE_OUT_DIR="$out" \
        SOURCE_DATE_EPOCH=1700000000 \
        bash "$BUILD_BUNDLE" "$BOARD" "$tree" >/dev/null 2>&1
  ) 9>"$BATS_FILE_TMPDIR/.serialize.x86raucb.lock"
}

# ===========================================================================
# 1. STATIC WIRING — orchestrate.sh's efi/grub Stage-4 branch calls
#    BUILD_BUNDLE_SH. T10 closed the gap where the x86 path assembled a .raw but
#    never produced the signed .raucb OTA; this asserts the producer is invoked
#    inside the efi/grub branch (and that build-bundle.sh exists to be called).
# ===========================================================================

@test "x86 wiring: orchestrate.sh efi/grub Stage-4 branch invokes BUILD_BUNDLE_SH" {
  [ -f "$ORCH" ]
  [ -f "$BUILD_BUNDLE" ]
  run efi_branch
  [ "$status" -eq 0 ]
  # The branch we extracted is genuinely the x86 (efi/grub) one...
  [[ "$output" == *'RAUC_BOOTLOADER_ADAPTER'* ]]
  [[ "$output" == *'"efi"'* ]]
  [[ "$output" == *'"grub"'* ]]
  # ...and it invokes the signed-bundle producer on the assembled rootfs artifact.
  [[ "$output" == *'BUILD_BUNDLE_SH'* ]]
  [[ "$output" == *'"${BUILD_BUNDLE_SH}" "${BOARD_ID}"'* ]]
  # The bundle is stamped with the board-specific compatible the device matches.
  [[ "$output" == *'COMPATIBLE_STRING'* ]]
}

# ===========================================================================
# 2. REAL SIGN + VERIFY — build-bundle.sh x86-minipc <rootfs> produces a real
#    signed .raucb whose CMS chain verifies leaf -> intermediate -> root against
#    the dev root-CA keyring. This is the meaningful artifact: the SAME signer
#    chain the device trusts, exercised end-to-end (no DRY_RUN, no mock signer).
# ===========================================================================

@test "x86 raucb: build-bundle.sh produces a real signed .raucb (CMS verifies to root)" {
  raucb_prereqs || skip "mksquashfs/unsquashfs/openssl/dev-PKI not available"
  local tree="$BATS_TEST_TMPDIR/rootfs" out="$BATS_TEST_TMPDIR/out"
  mkdir -p "$tree/etc" "$out"
  printf 'ceralive\n' > "$tree/etc/hostname"
  run env CERALIVE_RAUC_PKI_DIR="$DEV_KEYS" \
      COMPATIBLE_STRING="$COMPAT" \
      BUNDLE_VERSION="x86raucbtest" BUNDLE_TS="x86" BUNDLE_OUT_DIR="$out" \
      SOURCE_DATE_EPOCH=1700000000 \
      bash "$BUILD_BUNDLE" "$BOARD" "$tree"
  [ "$status" -eq 0 ]
  # The real signing chain verified — not a mocked/echoed signature.
  [[ "$output" == *"signature verified: leaf -> intermediate -> root"* ]]
  # A real artifact landed and is a genuine squashfs-payload RAUC bundle (magic 'hsqs').
  [ -s "$out/x86.raucb" ]
  [ -f "$out/x86.raucb.sha256" ]
  local magic
  magic="$(head -c 4 "$out/x86.raucb")"
  [ "$magic" = "hsqs" ]
}

# ===========================================================================
# 3. TAMPER — flipping one byte of the bundle payload makes verification FAIL.
#    Proves the signature has teeth: a mutated rootfs slot image (the exact
#    attack RAUC's CMS chain exists to stop) is REJECTED by verify_openssl_bundle
#    against the root keyring. We drive the SHIPPED verifier (sourced from
#    build-bundle.sh) so the test exercises the real device-equivalent check.
# ===========================================================================

@test "x86 raucb tamper: a flipped payload byte makes the bundle FAIL verification" {
  raucb_prereqs || skip "mksquashfs/unsquashfs/openssl/dev-PKI not available"
  build_x86_bundle
  local bundle="$BATS_FILE_TMPDIR/out/x86.raucb"
  [ -s "$bundle" ]

  # Sanity: the pristine bundle verifies (so a later failure is the tamper, not setup).
  run env CERALIVE_RAUC_PKI_DIR="$DEV_KEYS" bash -c \
      "source '$BUILD_BUNDLE'; verify_openssl_bundle '$bundle'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"signature verified"* ]]

  # Flip one byte INSIDE the squashfs payload (offset 64 — well inside the
  # superblock, far from the trailing CMS+length), leaving the trailer intact so
  # the verifier still splits payload/sig correctly and the CMS content mismatch
  # is what trips it.
  local tampered="$BATS_TEST_TMPDIR/tampered.raucb"
  cp "$bundle" "$tampered"
  printf '\xff' | dd of="$tampered" bs=1 seek=64 count=1 conv=notrunc 2>/dev/null

  run env CERALIVE_RAUC_PKI_DIR="$DEV_KEYS" bash -c \
      "source '$BUILD_BUNDLE'; verify_openssl_bundle '$tampered'"
  [ "$status" -ne 0 ]
  [[ "$output" != *"signature verified"* ]]
  [[ "$output" == *"did NOT verify"* ]]
}

# ===========================================================================
# 4. MANIFEST — the manifest.raucm EMBEDDED in the produced bundle carries
#    compatible=ceralive-x86-minipc. Re-extracting it FROM the bundle (not
#    echoing what we passed) proves the x86 compatible the orchestrator exports
#    (ceralive-<board-id>) is actually baked in — the string `rauc install`
#    matches against the device system.conf, or rejects the bundle.
# ===========================================================================

@test "x86 raucb manifest: embedded manifest.raucm has compatible=ceralive-x86-minipc" {
  raucb_prereqs || skip "mksquashfs/unsquashfs/openssl/dev-PKI not available"
  build_x86_bundle
  local bundle="$BATS_FILE_TMPDIR/out/x86.raucb"
  [ -s "$bundle" ]
  run unsquashfs -no-progress -cat "$bundle" manifest.raucm
  [ "$status" -eq 0 ]
  [[ "$output" == *"compatible=ceralive-x86-minipc"* ]]
  # Non-vacuity: the board-agnostic builder did NOT leak the RK3588 compatible.
  [[ "$output" != *"compatible=ceralive-rock-5b-plus"* ]]
}
