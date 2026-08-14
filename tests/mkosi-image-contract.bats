#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
#
# mkosi-image-contract.bats — mkosi/orchestrator image contracts — x86 boot fallback and the
# RAUC-native grub disk artifacts, multi-device rootfs non-regression, the
# size-gate scaffolding and its build gate, reproducible builds, and the
# bounded-parallel multi-board runner.
#
# Split out of the former tests/manifest.bats with the cases moved VERBATIM;
# the shared setup and every fixture helper live in manifest-helpers.bash.
#
# Run:  run-tests              (CI entrypoint)
#   or: bats tests/mkosi-image-contract.bats

load manifest-helpers

# ===========================================================================
# 7. x86 boot fallback — a forced primary-slot failure rolls back to the known-
#    good slot. The qemu-x86 harness' --fallback-selftest drives the SHIPPED x86
#    grubenv A/B engine (no qemu/GRUB/root); a green run is the proof. Engine-only
#    (no image boot), so it fits this UNIT suite.
# ===========================================================================

@test "x86 fallback: forced primary-slot failure rolls back to the known-good slot" {
  run env CERALIVE_QEMU_FALLBACK_SELFTEST=1 bash "$QEMU_X86"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ROLLBACK: forced A failure fell back to known-good slot B"* ]]
  [[ "$output" == *"QEMU x86 VALIDATION OK"* ]]
  [[ "$output" != *"FAIL"* ]]
}

# ===========================================================================
# 9. Multi-device rootfs non-regression + x86 disk-path guard (Task 14).
#    All three shipped boards must drive the orchestrator through to the build
#    plan (the rootfs.tar producer, step 6) without aborting; x86 (efi) must
#    NOT take the RK3588 `custom` .raw path — its disk assembly is deferred.
#
#    These run `DRY_RUN=1` (orchestrate stops at [5/9], before mkosi/Stage-4 —
#    no network, no qemu, no privileged container) with INSTALL_BOOT_BSP=0
#    (offline host stages no BSP .debs; the default BSP=1 path aborts at the
#    require_field / missing-BSP gate, which is a SEPARATE guard tested by the
#    pipeline itself, not what Task 14 verifies). Reaching the DRY-RUN banner
#    proves resolve + fetch-plan + every pre-mkosi gate passed for that board.
# ===========================================================================

@test "t14 rootfs: rock-5b-plus reaches the build plan (exit 0, custom/rk3588)" {
  serialize build-plan
  run env INSTALL_BOOT_BSP=0 DRY_RUN=1 bash "$PIPELINE_DIR/build" rock-5b-plus
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN complete"* ]]
}

@test "t14 rootfs: orange-pi-5-plus reaches the build plan (exit 0, custom/rk3588)" {
  serialize build-plan
  run env INSTALL_BOOT_BSP=0 DRY_RUN=1 bash "$PIPELINE_DIR/build" orange-pi-5-plus
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN complete"* ]]
}

@test "t14 rootfs: x86-minipc reaches the build plan (exit 0, efi)" {
  serialize build-plan
  run env INSTALL_BOOT_BSP=0 DRY_RUN=1 bash "$PIPELINE_DIR/build" x86-minipc
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN complete"* ]]
}

@test "fetch staging: x86-minipc maps resolved x86-64 to Debian amd64" {
  serialize build-plan
  run env INSTALL_BOOT_BSP=0 DRY_RUN=1 bash "$PIPELINE_DIR/build" x86-minipc
  [ "$status" -eq 0 ]
  [[ "$output" == *"resolved: family=x86_64 arch=x86-64 (mkosi=x86-64)"* ]]
  [[ "$output" == *"channel=stable arch=amd64"* ]]
  [[ "$output" == *"non-Armbian family: BSP fetch omitted from DRY_RUN plan"* ]]
  [[ "$output" != *"DRY-RUN would write Armbian source:"* ]]
  [[ "$output" != *"https://apt.armbian.com"* ]]
  [[ "$output" == *"first-party source: https://apt.ceralive.tv/dists/stable/binary-amd64/"* ]]
  [[ "$output" == *"APT::Architecture=amd64"* ]]
  [[ "$output" != *"binary-arm64"* ]]
}

@test "fetch staging: RK3588 boards keep Debian arm64" {
  serialize build-plan
  local board
  for board in rock-5b-plus orange-pi-5-plus; do
    run env INSTALL_BOOT_BSP=0 DRY_RUN=1 bash "$PIPELINE_DIR/build" "$board"
    [ "$status" -eq 0 ]
    [[ "$output" == *"resolved: family=rk3588 arch=arm64 (mkosi=arm64)"* ]]
    [[ "$output" == *"channel=stable arch=arm64"* ]]
    assert_bsp_architecture_plan arm64
    [[ "$output" == *"first-party source: https://apt.ceralive.tv/dists/stable/binary-arm64/"* ]]
    [[ "$output" == *"APT::Architecture=arm64"* ]]
    [[ "$output" != *"binary-amd64"* ]]
  done
}

@test "t14 x86 guard: x86-minipc DRY_RUN emits no .raw (resolve+plan only, before Stage-4)" {
  serialize build-plan
  run env INSTALL_BOOT_BSP=0 DRY_RUN=1 bash "$PIPELINE_DIR/build" x86-minipc
  [ "$status" -eq 0 ]
  # DRY_RUN stops at [5/9], before ANY board reaches Stage-4 disk assembly, so no
  # artifact is written (the preview contract). x86 disk assembly itself is now WIRED
  # (lib/assemble-disk-x86.sh) and exercised by the x86-grub test below.
  local raws=()
  if [[ -d "$PIPELINE_DIR/images/x86-minipc" ]]; then
    while IFS= read -r f; do raws+=("$f"); done \
      < <(find "$PIPELINE_DIR/images/x86-minipc" -maxdepth 1 -type f -name '*.raw')
  fi
  [ "${#raws[@]}" -eq 0 ]
}

@test "t14 x86 guard: resolved adapter routes x86 to efi, rk3588 to custom (non-vacuity)" {
  run "$RESOLVE_SH" x86-minipc
  [ "$status" -eq 0 ]
  [[ "$output" == *"RAUC_BOOTLOADER_ADAPTER='efi'"* ]]
  run "$RESOLVE_SH" rock-5b-plus
  [ "$status" -eq 0 ]
  [[ "$output" == *"RAUC_BOOTLOADER_ADAPTER='custom'"* ]]
}

@test "t14 x86 guard: orchestrate.sh wires the x86 ESP/GRUB disk path (TODO(x86-disk) closed)" {
  local orch
  orch="$(orch_source_set)"
  # Task 12 closed the deferral: the former active TODO(x86-disk) marker is GONE.
  run grep -q 'TODO(x86-disk)' "$orch"
  [ "$status" -ne 0 ]
  # Each adapter has exactly ONE .raw producer under its own branch: RK3588 custom
  # -> assemble-disk.sh, x86 efi/grub -> assemble-disk-x86.sh.
  [ "$(grep -c 'ASSEMBLE_DISK_SH}" build' "$orch")" -eq 1 ]
  [ "$(grep -c 'ASSEMBLE_DISK_X86_SH}" build' "$orch")" -eq 1 ]
}

# ===========================================================================
# 9b. x86 RAUC-native bootloader=grub disk-path artifacts (Task 12). The shipped
#     installer (install-x86-grub.sh) renders the bootloader=grub system.conf, the
#     grub.cfg ORDER/OK/TRY selector, and the seeded grubenv; test-x86-grub.sh
#     drives it offline (no qemu/GRUB/root/image) and proves the slot-switch
#     contract (flip grubenv ORDER -> the OTHER slot is selected). Engine/artifact
#     only, so it fits this UNIT suite.
# ===========================================================================

@test "x86 grub: bootloader=grub system.conf + grub.cfg selector + grubenv slot-switch (selects B)" {
  run bash "$PIPELINE_DIR/mkosi/platform/x86/test-x86-grub.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"switched selection is 'B rootfs_b'"* ]]
  [[ "$output" == *"X86-GRUB TEST OK"* ]]
  [[ "$output" != *"FAIL"* ]]
}

# ===========================================================================
# 10. Size-gate measurement scaffolding (Task 8) — REPORT-ONLY.
#     measure-size.sh sizes rootfs CONTENT (du --apparent-size -sb on the
#     artifact/tree, NOT the frozen 4096 MB partition — G4/E5) and compares it to
#     manifests/size-budget.json. While every rootfs_bytes_max is null the gate
#     only REPORTS (prints measured vs budget, exits 0). Pure static measurement —
#     no chroot/build/mount — so it fits this UNIT suite. Task 20 flips it to
#     blocking by setting a non-null threshold; the enforcement branch is proven
#     here so that flip stays a one-line manifest edit.
# ===========================================================================

@test "size-budget: every shipped board carries a positive-integer blocking ceiling (Task-20 flip landed)" {
  run python3 - "$SIZE_BUDGET_JSON" "$PIPELINE_DIR/manifests/boards" <<'PY'
import json, sys
from pathlib import Path

budget = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert isinstance(budget, dict), "root must be an object"
boards = {p.stem for p in Path(sys.argv[2]).glob("*.yaml")}
entries = {k: v for k, v in budget.items() if not k.startswith("_")}
missing = boards - set(entries)
assert not missing, "boards missing a size-budget entry: %s" % sorted(missing)
for name, entry in entries.items():
    limit = entry.get("rootfs_bytes_max")
    assert isinstance(limit, int) and not isinstance(limit, bool) and limit > 0, (
        "%s: rootfs_bytes_max must be a positive int (blocking), got %r" % (name, limit)
    )
print("BUDGET-OK")
PY
  [ "$status" -eq 0 ]
  [[ "$output" == *"BUDGET-OK"* ]]
}

@test "size-gate: a null budget is report-only (retained path for newly-added boards) and exits 0" {
  local tree="$BATS_TEST_TMPDIR/rootfs"
  mkdir -p "$tree"
  head -c 4096 /dev/zero > "$tree/a.bin"
  local nullbudget="$BATS_TEST_TMPDIR/null-budget.json"
  printf '{ "rock-5b-plus": { "rootfs_bytes_max": null, "measured": null } }\n' > "$nullbudget"
  run env SIZE_BUDGET_JSON="$nullbudget" "$MEASURE_SH" rock-5b-plus "$tree"
  [ "$status" -eq 0 ]
  [[ "$output" =~ measured=[0-9]+\ budget=null\ \(report-only\) ]]
}

@test "size-gate: apparent-size measurement is deterministic (identical bytes across runs)" {
  local tree="$BATS_TEST_TMPDIR/rootfs-det"
  mkdir -p "$tree/sub"
  head -c 8192 /dev/zero > "$tree/a.bin"
  head -c 333  /dev/zero > "$tree/sub/b.bin"
  run "$MEASURE_SH" rock-5b-plus "$tree"
  [ "$status" -eq 0 ]
  local first="${output%% *}"          # "measured=<N>"
  run "$MEASURE_SH" rock-5b-plus "$tree"
  [ "$status" -eq 0 ]
  [[ "${output%% *}" == "$first" ]]
}

@test "size-gate: malformed size-budget.json fails loudly (non-vacuity negative)" {
  local tree="$BATS_TEST_TMPDIR/rootfs-bad"
  mkdir -p "$tree"
  head -c 16 /dev/zero > "$tree/a.bin"
  local bad="$BATS_TEST_TMPDIR/bad-budget.json"
  printf '{ this is not json\n' > "$bad"
  run env SIZE_BUDGET_JSON="$bad" "$MEASURE_SH" rock-5b-plus "$tree"
  [ "$status" -ne 0 ]
  [[ "$output" == *"malformed size-budget.json"* ]]
}

@test "size-gate: unknown board fails loudly (no silent pass on a missing budget)" {
  local tree="$BATS_TEST_TMPDIR/rootfs-unknown"
  mkdir -p "$tree"
  head -c 16 /dev/zero > "$tree/a.bin"
  run "$MEASURE_SH" definitely-not-a-board "$tree"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no size budget entry"* ]]
}

@test "size-gate: a non-null budget enforces (over-budget fails) — proves Task-20 flip works" {
  local tree="$BATS_TEST_TMPDIR/rootfs-enf"
  mkdir -p "$tree"
  head -c 65536 /dev/zero > "$tree/big.bin"   # ~64 KiB of content
  local tight="$BATS_TEST_TMPDIR/tight-budget.json"
  printf '{ "rock-5b-plus": { "rootfs_bytes_max": 1024, "measured": null } }\n' > "$tight"
  run env SIZE_BUDGET_JSON="$tight" "$MEASURE_SH" rock-5b-plus "$tree"
  [ "$status" -ne 0 ]
  [[ "$output" == *"exceeds budget"* ]]
}

@test "size-gate: a generous non-null budget passes and reports 'enforced'" {
  local tree="$BATS_TEST_TMPDIR/rootfs-ok"
  mkdir -p "$tree"
  head -c 256 /dev/zero > "$tree/small.bin"
  local roomy="$BATS_TEST_TMPDIR/roomy-budget.json"
  printf '{ "rock-5b-plus": { "rootfs_bytes_max": 1073741824, "measured": null } }\n' > "$roomy"
  run env SIZE_BUDGET_JSON="$roomy" "$MEASURE_SH" rock-5b-plus "$tree"
  [ "$status" -eq 0 ]
  [[ "$output" =~ measured=[0-9]+\ budget=1073741824\ \(enforced\) ]]
}

@test "size-gate: the COMMITTED size-budget.json enforces (non-null) for every shipped board" {
  local tree="$BATS_TEST_TMPDIR/rootfs-committed"
  mkdir -p "$tree"
  head -c 4096 /dev/zero > "$tree/a.bin"
  for board in orange-pi-5-plus rock-5b-plus x86-minipc; do
    run "$MEASURE_SH" "$board" "$tree"
    [ "$status" -eq 0 ]
    [[ "$output" =~ measured=[0-9]+\ budget=[0-9]+\ \(enforced\) ]]
    [[ "$output" != *"report-only"* ]]
  done
}

@test "size-gate: a tree over the COMMITTED ceiling fails the gate (sparse 2 GiB > 1.5 GB budget)" {
  local tree="$BATS_TEST_TMPDIR/rootfs-over"
  mkdir -p "$tree"
  truncate -s 2G "$tree/oversize.img"
  run "$MEASURE_SH" rock-5b-plus "$tree"
  [ "$status" -ne 0 ]
  [[ "$output" == *"exceeds budget"* ]]
}

@test "size-gate: final app layer strips apt caches while preserving dpkg status" {
  run grep -qx 'CleanPackageMetadata=no' "$PIPELINE_DIR/mkosi/mkosi.images/app/mkosi.conf"
  [ "$status" -eq 0 ]

  run grep -F 'clean_package_download_metadata' "$PIPELINE_DIR/mkosi/mkosi.images/app/mkosi.postinst.chroot"
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean_package_download_metadata"* ]]

  run grep -F 'rm -rf /var/lib/apt/lists/* /var/cache/apt/pkgcache.bin /var/cache/apt/srcpkgcache.bin' "$PIPELINE_DIR/mkosi/mkosi.images/app/mkosi.postinst.chroot"
  [ "$status" -eq 0 ]
}

@test "size-gate: platform prunes RK3588 firmware and final app prunes headless payload" {
  run grep -F 'prune_final_image_payload' "$PIPELINE_DIR/mkosi/mkosi.images/app/mkosi.postinst.chroot"
  [ "$status" -eq 0 ]

  # The prune is no longer a literal list of absolute paths — it is a candidate
  # list gated on a `modinfo -F firmware` sweep of the installed modules, so the
  # firmware ROOT and the candidate NAME are asserted separately.
  run grep -F 'usr/lib/firmware' "$PIPELINE_DIR/mkosi/mkosi.images/platform/mkosi.postinst"
  [ "$status" -eq 0 ]
  run grep -E '^\s+qcom intel ath10k' "$PIPELINE_DIR/mkosi/mkosi.images/platform/mkosi.postinst"
  [ "$status" -eq 0 ]
  run grep -F 'modinfo' "$PIPELINE_DIR/mkosi/mkosi.images/platform/mkosi.postinst"
  [ "$status" -eq 0 ]

  run grep -F '/usr/lib/firmware/intel' "$PIPELINE_DIR/mkosi/mkosi.images/app/mkosi.postinst.chroot"
  [ "$status" -ne 0 ]

  run grep -F '/usr/share/icons/Adwaita' "$PIPELINE_DIR/mkosi/mkosi.images/app/mkosi.postinst.chroot"
  [ "$status" -eq 0 ]
}

@test "size-gate wiring: orchestrate.sh resolves measure-size.sh and invokes it" {
  run grep -Fx 'MEASURE_SIZE_SH="${HERE}/measure-size.sh"' "$PIPELINE_DIR/lib/orchestrate.sh"
  [ "$status" -eq 0 ]
  [ -x "$MEASURE_SH" ]

  run grep -F '"${MEASURE_SIZE_SH}" "${board}" "${artifact}"' "$PIPELINE_DIR/lib/stages/size-gate.sh"
  [ "$status" -eq 0 ]
}

@test "size-gate wiring: the gate runs after the tar is emitted and before parity/disk assembly" {
  # Position is the whole point: measuring before the emit has nothing to measure,
  # and measuring after Stage-4 would already have cut a .raw and a signed .raucb
  # from an over-budget image.
  local orch emit_line gate_line parity_line disk_line
  orch="$(orch_source_set)"
  emit_line="$(grep -n '\[6/9\] emitting normalized artifact' "$orch" | head -1 | cut -d: -f1)"
  gate_line="$(grep -n '\[6c/9\] enforcing the rootfs size budget' "$orch" | head -1 | cut -d: -f1)"
  parity_line="$(grep -n '\[7/9\] verifying parity' "$orch" | head -1 | cut -d: -f1)"
  disk_line="$(grep -n '\[8/9\] Stage-4 disk assembly' "$orch" | head -1 | cut -d: -f1)"
  [ -n "$emit_line" ] && [ -n "$gate_line" ] && [ -n "$parity_line" ] && [ -n "$disk_line" ]
  [ "$emit_line" -lt "$gate_line" ]
  [ "$gate_line" -lt "$parity_line" ]
  [ "$parity_line" -lt "$disk_line" ]
}

@test "size-gate wiring: DRY_RUN exits the orchestrator before the gate can run" {
  # DRY_RUN ships no rootfs at all, so the gate must be unreachable there — by
  # placement, not by a condition that a later edit could drop.
  local orch dryrun_exit_line gate_line
  orch="$(orch_source_set)"
  dryrun_exit_line="$(grep -n '=== DRY-RUN complete' "$orch" | head -1 | cut -d: -f1)"
  gate_line="$(grep -n '\[6c/9\] enforcing the rootfs size budget' "$orch" | head -1 | cut -d: -f1)"
  [ -n "$dryrun_exit_line" ] && [ -n "$gate_line" ]
  [ "$dryrun_exit_line" -lt "$gate_line" ]
}

@test "size-gate wiring: main() calls the DRY_RUN plan before the gate" {
  # Companion to the source-order case above. Now that the stage bodies are
  # modules, the thing that actually decides reachability is main()'s CALL order,
  # so assert that directly rather than trusting text position alone.
  local body dry_pos gate_pos
  body="$(sed -n '/^main() {/,/^}/p' "$PIPELINE_DIR/lib/orchestrate.sh")"
  [ -n "$body" ]
  dry_pos="$(printf '%s\n' "$body" | grep -n '^  stage_dry_run_plan$' | head -1 | cut -d: -f1)"
  gate_pos="$(printf '%s\n' "$body" | grep -n '^  stage_size_gate$' | head -1 | cut -d: -f1)"
  [ -n "$dry_pos" ] && [ -n "$gate_pos" ]
  [ "$dry_pos" -lt "$gate_pos" ]
}

@test "size-gate wiring: the shipped block PASSES an under-budget artifact" {
  local tree="$BATS_TEST_TMPDIR/wired-ok"
  mkdir -p "$tree"
  head -c 4096 /dev/zero > "$tree/a.bin"
  run_size_gate_block 1 "$SIZE_BUDGET_JSON" "$tree"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[6c/9] enforcing the rootfs size budget"* ]]
  [[ "$output" =~ measured=[0-9]+\ budget=1500000000\ \(enforced\) ]]
}

@test "size-gate wiring: the shipped block ABORTS the build on an over-budget artifact" {
  # The non-vacuity leg. Without it an always-passing gate looks identical to a
  # working one — which is exactly the state this stage was added to end.
  local tree="$BATS_TEST_TMPDIR/wired-over"
  mkdir -p "$tree"
  head -c 65536 /dev/zero > "$tree/big.bin"
  local tight="$BATS_TEST_TMPDIR/wired-tight.json"
  printf '{ "rock-5b-plus": { "rootfs_bytes_max": 1024 } }\n' > "$tight"
  run_size_gate_block 1 "$tight" "$tree"
  [ "$status" -ne 0 ]
  [[ "$output" == *"exceeds budget"* ]]
  [[ "$output" == *"rootfs size budget EXCEEDED for board 'rock-5b-plus'"* ]]
  [[ "$output" == *"do NOT raise rootfs_bytes_max"* ]]
}

@test "size-gate wiring: a NON-SHIPPING kernel variant is measured and reported, never aborted" {
  # A KASAN+lockdep bench kernel is ~170 MB over by construction. Aborting it
  # protects a fleet the artifact can never reach — ci/check-release-variant.sh
  # refuses to release it — while blocking the negative-path QA campaign.
  local tree="$BATS_TEST_TMPDIR/wired-nonship"
  mkdir -p "$tree"
  head -c 65536 /dev/zero > "$tree/big.bin"
  local tight="$BATS_TEST_TMPDIR/wired-nonship-tight.json"
  printf '{ "rock-5b-plus": { "rootfs_bytes_max": 1024 } }\n' > "$tight"
  local guard="$BATS_TEST_TMPDIR/refuse-guard.sh"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$guard"; chmod +x "$guard"

  run_size_gate_block 1 "$tight" "$tree" "$MEASURE_SH" "" "$guard" edge-test
  [ "$status" -eq 0 ]
  [[ "$output" == *"NON-SHIPPING"* ]]
  [[ "$output" == *"exceeds budget"* ]]
  [[ "$output" != *"rootfs size budget EXCEEDED for board"* ]]
}

@test "size-gate wiring: a RELEASABLE variant is still aborted (the exemption is not a blanket)" {
  # The non-vacuity half. Same over-budget artifact, same wiring, a guard that
  # ACCEPTS the variant — the build must still die.
  local tree="$BATS_TEST_TMPDIR/wired-ship"
  mkdir -p "$tree"
  head -c 65536 /dev/zero > "$tree/big.bin"
  local tight="$BATS_TEST_TMPDIR/wired-ship-tight.json"
  printf '{ "rock-5b-plus": { "rootfs_bytes_max": 1024 } }\n' > "$tight"
  local guard="$BATS_TEST_TMPDIR/accept-guard.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$guard"; chmod +x "$guard"

  run_size_gate_block 1 "$tight" "$tree" "$MEASURE_SH" "" "$guard" edge
  [ "$status" -ne 0 ]
  [[ "$output" == *"rootfs size budget EXCEEDED for board 'rock-5b-plus'"* ]]
}

@test "size-gate wiring: an UNRESOLVABLE release guard fails CLOSED (budget enforced)" {
  # With no guard path the gate may not assume the artifact is non-shipping.
  local tree="$BATS_TEST_TMPDIR/wired-noguard"
  mkdir -p "$tree"
  head -c 65536 /dev/zero > "$tree/big.bin"
  local tight="$BATS_TEST_TMPDIR/wired-noguard-tight.json"
  printf '{ "rock-5b-plus": { "rootfs_bytes_max": 1024 } }\n' > "$tight"

  run_size_gate_block 1 "$tight" "$tree" "$MEASURE_SH" "" "" edge-test
  [ "$status" -ne 0 ]
  [[ "$output" == *"rootfs size budget EXCEEDED for board 'rock-5b-plus'"* ]]
}

@test "size-gate wiring: the REAL release guard refuses edge-test and accepts edge" {
  # The exemption is only as good as the property it keys on, so drive the
  # shipped guard rather than a stub.
  run "$PIPELINE_DIR/ci/check-release-variant.sh" --variant edge-test
  [ "$status" -ne 0 ]
  run "$PIPELINE_DIR/ci/check-release-variant.sh" --variant edge
  [ "$status" -eq 0 ]
}

@test "builder image: the auto-built mkosi tag is content-addressed over ci/Dockerfile" {
  # ensure_builder_image skips `docker build` when the tag already exists, so a
  # constant tag pins every host to whatever layers it first built — an edit to
  # ci/Dockerfile would then silently never take effect on the machine that cuts
  # the artifacts. Same defect the kernel builder already fixed.
  run bash -c "grep -n 'ceralive-mkosi-builder:\${MKOSI_VERSION_PIN}-\$(sha256sum' '$PIPELINE_DIR/lib/orchestrate.sh'"
  [ "$status" -eq 0 ]

  local plan_a plan_b
  plan_a="$(DRY_RUN=1 INSTALL_BOOT_BSP=0 "$PIPELINE_DIR/build" rock-5b-plus 2>&1 \
    | sed -n 's/.*builder \(ceralive-mkosi-builder:[^ ]*\).*/\1/p' | head -1)"
  [[ "$plan_a" =~ ^ceralive-mkosi-builder:[0-9]+-[0-9a-f]{12}$ ]]

  plan_b="$(DRY_RUN=1 INSTALL_BOOT_BSP=0 "$PIPELINE_DIR/build" rock-5b-plus 2>&1 \
    | sed -n 's/.*builder \(ceralive-mkosi-builder:[^ ]*\).*/\1/p' | head -1)"
  [ "$plan_a" = "$plan_b" ]

  # An operator-pinned image is honoured verbatim and never content-addressed.
  local pinned
  pinned="$(MKOSI_BUILDER_IMAGE=example.invalid/custom:1 DRY_RUN=1 INSTALL_BOOT_BSP=0 \
    "$PIPELINE_DIR/build" rock-5b-plus 2>&1 | sed -n 's/.*builder \(example.invalid[^ ]*\).*/\1/p' | head -1)"
  [ "$pinned" = "example.invalid/custom:1" ]
}

@test "builder image: a widened umask can NEVER make mkosi's policy-rc.d executable" {
  # The premise of the whole fix, and the reason the first attempt (relaxing
  # mkosi's umask from ~0o644 to ~0o755) was a silent no-op that shipped looking
  # plausible: umask only CLEARS permission bits, and Python's open(...,"w")
  # requests base mode 0o666, which carries no execute bit to keep. Both umasks
  # therefore land on 0644, which invoke-rc.d reports as MISSING, not as denying.
  run python3 - <<'PY'
import os, sys, tempfile
d = tempfile.mkdtemp()
modes = []
for u in (~0o644, ~0o755):
    old = os.umask(u & 0o777)
    p = os.path.join(d, "p%o" % (u & 0o777))
    open(p, "w").write("#!/bin/sh\nexit 101\n")
    os.umask(old)
    modes.append(os.stat(p).st_mode & 0o777)
print(" ".join("%04o" % m for m in modes))
sys.exit(0 if modes == [0o644, 0o644] else 1)
PY
  [ "$status" -eq 0 ]
  [ "$output" = "0644 0644" ]
}

@test "builder image: ci/Dockerfile's policy-rc.d patch makes the helper executable, and is asserted to apply" {
  # The patch is a sed into third-party Python source, so it is executed here
  # against a fixture reproducing mkosi 26's write site rather than merely
  # grepped for. A silent no-op restores census rows 8/9/21 on every real build.
  local sed_line
  sed_line="$(sed -n 's/^ *&& \(sed -i .*policyrcd\\\.write_text.*\) \\$/\1/p' "$PIPELINE_DIR/ci/Dockerfile")"
  [ -n "$sed_line" ]

  local work="$BATS_TEST_TMPDIR/apt-fixture"
  mkdir -p "$work"
  cat >"$work/apt.py" <<'PY'
from mkosi.util import umask


class Apt:
    @classmethod
    def install(cls, context, packages):
        policyrcd = context.root / "usr/sbin/policy-rc.d"
        with umask(~0o755):
            policyrcd.parent.mkdir(parents=True, exist_ok=True)
        with umask(~0o644):
            policyrcd.write_text("#!/bin/sh\nexit 101\n")
PY

  # Non-vacuity: the UNPATCHED write site produces 0644.
  run python3 "$PIPELINE_DIR/tests/fixtures/apt-policyrcd-mode.py" "$work/apt.py"
  [ "$status" -eq 0 ]
  [ "$output" = "0644" ]

  APT_PY="$work/apt.py" bash -c "$sed_line"
  run python3 -m py_compile "$work/apt.py"
  [ "$status" -eq 0 ]
  run grep -cE '^ *policyrcd\.chmod\(0o755\)$' "$work/apt.py"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]

  # The patched write site produces an EXECUTABLE helper.
  run python3 "$PIPELINE_DIR/tests/fixtures/apt-policyrcd-mode.py" "$work/apt.py"
  [ "$status" -eq 0 ]
  [ "$output" = "0755" ]

  # Apply-or-fail drift guards: the write site must be found exactly once and the
  # chmod must be absent before / present exactly once after.
  run grep -F "test \"\$(grep -c '^ *policyrcd\\.write_text(' \"\${APT_PY}\")\" = 1" "$PIPELINE_DIR/ci/Dockerfile"
  [ "$status" -eq 0 ]
  run grep -F "test \"\$(grep -c 'policyrcd\\.chmod' \"\${APT_PY}\")\" = 0" "$PIPELINE_DIR/ci/Dockerfile"
  [ "$status" -eq 0 ]
  run grep -F "test \"\$(grep -c '^ *policyrcd\\.chmod(0o755)\$' \"\${APT_PY}\")\" = 1" "$PIPELINE_DIR/ci/Dockerfile"
  [ "$status" -eq 0 ]
}

@test "chroot service policy: every layer that runs its OWN apt/dpkg installs an executable policy-rc.d" {
  # mkosi UNLINKS its helper when its own apt transaction ends, and only the base
  # image declares Packages= — so platform/runtime/app run every one of their
  # transactions with the path absent unless they re-assert it themselves. This
  # is the half the ci/Dockerfile patch cannot reach (census rows 9 and 21).
  local f
  for f in "$PIPELINE_DIR/mkosi/customize/postinst.d/services.sh" \
           "$PIPELINE_DIR/mkosi/mkosi.images/app/mkosi.postinst.chroot" \
           "$PIPELINE_DIR/mkosi/mkosi.images/platform/mkosi.postinst"; do
    run grep -cE '^install_chroot_service_policy\(\) \{' "$f"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
    run grep -F 'chmod 0755 "${policy}"' "$f"
    [ "$status" -eq 0 ]
  done

  # Called before the layer's first package transaction, in all three layers.
  run grep -n 'install_chroot_service_policy' "$PIPELINE_DIR/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"
  [ "$status" -eq 0 ]
  local policy_at apt_at
  policy_at="$(grep -n '^  install_chroot_service_policy' "$PIPELINE_DIR/mkosi/mkosi.images/runtime/mkosi.postinst.chroot" | cut -d: -f1)"
  apt_at="$(grep -n '^  install_runtime_packages' "$PIPELINE_DIR/mkosi/mkosi.images/runtime/mkosi.postinst.chroot" | cut -d: -f1)"
  [ -n "$policy_at" ] && [ -n "$apt_at" ] && [ "$policy_at" -lt "$apt_at" ]

  policy_at="$(grep -n '^  install_chroot_service_policy' "$PIPELINE_DIR/mkosi/mkosi.images/app/mkosi.postinst.chroot" | cut -d: -f1)"
  apt_at="$(grep -n '^  remove_chroot_service_policy' "$PIPELINE_DIR/mkosi/mkosi.images/app/mkosi.postinst.chroot" | cut -d: -f1)"
  [ -n "$policy_at" ] && [ -n "$apt_at" ] && [ "$policy_at" -lt "$apt_at" ]

  policy_at="$(grep -n '^install_chroot_service_policy$' "$PIPELINE_DIR/mkosi/mkosi.images/platform/mkosi.postinst" | cut -d: -f1)"
  apt_at="$(grep -n '^  mkosi-install -y --no-install-recommends "\${hw_gst\[@\]}"' "$PIPELINE_DIR/mkosi/mkosi.images/platform/mkosi.postinst" | cut -d: -f1)"
  [ -n "$policy_at" ] && [ -n "$apt_at" ] && [ "$policy_at" -lt "$apt_at" ]
}

@test "chroot service policy: the shipped installer really produces an executable exit-101 helper" {
  # Drive the REAL function out of the library rather than asserting on its text:
  # the whole defect class here is a helper that exists at the right path with
  # the wrong mode.
  local root="$BATS_TEST_TMPDIR/policy-root"
  mkdir -p "$root"
  run bash -c "
    set -euo pipefail
    source '$PIPELINE_DIR/mkosi/customize/postinst-lib.sh'
    CERALIVE_POLICY_RCD='$root/usr/sbin/policy-rc.d' install_chroot_service_policy
  "
  [ "$status" -eq 0 ]
  [ -x "$root/usr/sbin/policy-rc.d" ]
  run stat -c '%a' "$root/usr/sbin/policy-rc.d"
  [ "$output" = "755" ]
  run "$root/usr/sbin/policy-rc.d" dbus force-reload
  [ "$status" -eq 101 ]

  # Idempotent: a second call over an existing helper leaves it executable.
  run bash -c "
    set -euo pipefail
    source '$PIPELINE_DIR/mkosi/customize/postinst-lib.sh'
    CERALIVE_POLICY_RCD='$root/usr/sbin/policy-rc.d' install_chroot_service_policy
  "
  [ "$status" -eq 0 ]
  [ -x "$root/usr/sbin/policy-rc.d" ]

  # …and the app layer still removes it, fail-loud, so nothing ships.
  run bash -c "
    set -euo pipefail
    log() { :; }
    die() { printf 'FATAL: %s\n' \"\$*\" >&2; exit 1; }
    eval \"\$(sed -n '/^remove_chroot_service_policy() {/,/^}/p' '$PIPELINE_DIR/mkosi/mkosi.images/app/mkosi.postinst.chroot')\"
    CERALIVE_POLICY_RCD='$root/usr/sbin/policy-rc.d' remove_chroot_service_policy
  "
  [ "$status" -eq 0 ]
  [ ! -e "$root/usr/sbin/policy-rc.d" ]
}

@test "size-gate wiring: orchestrate.sh resolves the release guard the size gate consults" {
  run grep -Fx 'CHECK_RELEASE_VARIANT_SH="${PIPELINE_DIR}/ci/check-release-variant.sh"' "$PIPELINE_DIR/lib/orchestrate.sh"
  [ "$status" -eq 0 ]
}

@test "size-gate wiring: an INSTALL_BOOT_BSP=0 parity build skips the gate LOUDLY" {
  # A kernel-less parity rootfs is not the shipped image, so measuring it would be
  # a vacuous pass. Skipping is correct; skipping silently is not.
  local tree="$BATS_TEST_TMPDIR/wired-parity"
  mkdir -p "$tree"
  head -c 65536 /dev/zero > "$tree/big.bin"
  local tight="$BATS_TEST_TMPDIR/wired-parity-tight.json"
  printf '{ "rock-5b-plus": { "rootfs_bytes_max": 1024 } }\n' > "$tight"

  local sentinel="$BATS_TEST_TMPDIR/measure-ran"
  local spy="$BATS_TEST_TMPDIR/measure-spy.sh"
  printf '#!/usr/bin/env bash\ntouch "%s"\n' "$sentinel" > "$spy"
  chmod +x "$spy"

  run_size_gate_block 0 "$tight" "$tree" "$spy"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[6c/9] INSTALL_BOOT_BSP=0"* ]]
  [ ! -e "$sentinel" ]
}

@test "size-gate wiring: the shipped block runs the relative baseline check after the absolute gate" {
  # The absolute ceiling and the relative baseline are different questions. Wiring
  # only the ceiling leaves size-baseline.json dead data that no real build reads.
  local tree="$BATS_TEST_TMPDIR/wired-baseline"
  mkdir -p "$tree"
  head -c 4096 /dev/zero > "$tree/a.bin"
  local spy="$BATS_TEST_TMPDIR/baseline-compare-ran"
  run_size_gate_block 1 "$SIZE_BUDGET_JSON" "$tree" "$MEASURE_SH" "$spy"
  [ "$status" -eq 0 ]
  [ -e "$spy" ]

  local block
  block="$(extract_size_gate_block)"
  local measure_pos baseline_pos
  measure_pos="$(printf '%s\n' "$block" | grep -n 'MEASURE_SIZE_SH' | head -1 | cut -d: -f1)"
  baseline_pos="$(printf '%s\n' "$block" | grep -n 'compare_size_against_baseline' | head -1 | cut -d: -f1)"
  [ -n "$measure_pos" ] && [ -n "$baseline_pos" ]
  [ "$measure_pos" -lt "$baseline_pos" ]
}

@test "size-baseline: every shipped RK3588 board has a REAL committed per-board baseline" {
  # "Real" means: recorded from an actual measured artifact, not a placeholder.
  # A baseline with no artifact/sha256/commit provenance cannot be re-derived, and
  # a baseline above the blocking ceiling would be a baseline for an image that
  # could never have shipped.
  run python3 - "$PIPELINE_DIR/ci" "$SIZE_BUDGET_JSON" <<'PY'
import json, re, sys
from pathlib import Path

ci, budget_path = Path(sys.argv[1]), Path(sys.argv[2])
budget = json.loads(budget_path.read_text(encoding="utf-8"))

for board in ("rock-5b-plus", "orange-pi-5-plus"):
    f = ci / ("size-baseline.%s.json" % board)
    assert f.is_file(), "missing per-board baseline: %s" % f.name
    d = json.loads(f.read_text(encoding="utf-8"))
    assert d.get("board") == board, "%s: board field is %r" % (f.name, d.get("board"))
    b = d.get("bytes")
    assert isinstance(b, int) and not isinstance(b, bool) and b > 0, (
        "%s: bytes must be a positive int, got %r" % (f.name, b)
    )
    assert b > 100_000_000, (
        "%s: bytes=%d is not a real rootfs measurement (placeholder?)" % (f.name, b)
    )
    assert re.fullmatch(r"\d{4}-\d{2}-\d{2}", str(d.get("recorded_at", ""))), (
        "%s: recorded_at must be an ISO date" % f.name
    )
    for prov in ("artifact", "artifact_sha256", "commit"):
        assert d.get(prov), "%s: missing provenance field %r" % (f.name, prov)
    assert re.fullmatch(r"[0-9a-f]{64}", d["artifact_sha256"]), (
        "%s: artifact_sha256 must be lowercase hex sha256" % f.name
    )
    ceiling = budget[board]["rootfs_bytes_max"]
    assert b <= ceiling, (
        "%s: baseline %d exceeds the blocking ceiling %d" % (f.name, b, ceiling)
    )
print("BASELINE-REAL-OK")
PY
  [ "$status" -eq 0 ]
  [[ "$output" == *"BASELINE-REAL-OK"* ]]
}

@test "size-baseline: size-budget.json 'measured' agrees byte-for-byte with the per-board baseline" {
  # The measured value is recorded in two registries. They are read by different
  # consumers (the budget file by measure-size.sh's operators, the baseline file by
  # the relative gate), so a silent divergence would make one of them a lie.
  run python3 - "$PIPELINE_DIR/ci" "$SIZE_BUDGET_JSON" <<'PY'
import json, sys
from pathlib import Path

ci, budget_path = Path(sys.argv[1]), Path(sys.argv[2])
budget = json.loads(budget_path.read_text(encoding="utf-8"))

for board in ("rock-5b-plus", "orange-pi-5-plus"):
    d = json.loads((ci / ("size-baseline.%s.json" % board)).read_text(encoding="utf-8"))
    entry = budget[board]
    assert entry.get("measured") == d["bytes"], (
        "%s: size-budget measured=%r != baseline bytes=%r"
        % (board, entry.get("measured"), d["bytes"])
    )
    for a, b in (("measured_at", "recorded_at"), ("measured_commit", "commit"),
                 ("measured_artifact", "artifact")):
        assert entry.get(a) == d.get(b), (
            "%s: size-budget %s=%r != baseline %s=%r"
            % (board, a, entry.get(a), b, d.get(b))
        )
print("BASELINE-AGREE-OK")
PY
  [ "$status" -eq 0 ]
  [[ "$output" == *"BASELINE-AGREE-OK"* ]]
}

@test "size-baseline: the comparator REFUSES a baseline recorded for a different board" {
  # Baselines differ between boards by tens of MB, so an unchecked file argument
  # yields a confident, meaningless delta. This is the non-vacuity leg.
  run "$PIPELINE_DIR/ci/check-size-regression.sh" 1412259840 "$PIPELINE_DIR/ci/size-baseline.rock-5b-plus.json" orange-pi-5-plus
  [ "$status" -eq 2 ]
  [[ "$output" == *"baseline is for board"* ]]

  run "$PIPELINE_DIR/ci/check-size-regression.sh" 1412259840 "$PIPELINE_DIR/ci/size-baseline.rock-5b-plus.json" rock-5b-plus
  [ "$status" -eq 0 ]
}

@test "size-baseline: the shipped compare function DIES on a cross-board baseline and SKIPS a missing one" {
  local tree="$BATS_TEST_TMPDIR/baseline-art"
  mkdir -p "$tree"
  head -c 4096 /dev/zero > "$tree/a.bin"

  # A board with no committed baseline is the newly-added-board allowance: warn,
  # do not fail. Crucially it must NOT silently fall back to another board's file.
  local empty="$BATS_TEST_TMPDIR/baselines-empty"
  mkdir -p "$empty"
  cp "$PIPELINE_DIR/ci/size-baseline.rock-5b-plus.json" "$empty/size-baseline.json"
  run_baseline_compare x86-minipc "$tree" "$empty"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no committed size baseline"* ]]

  # A per-board file whose own board field disagrees is a misconfiguration, not a
  # size event, so it must abort rather than report a delta.
  local bad="$BATS_TEST_TMPDIR/baselines-bad"
  mkdir -p "$bad"
  cp "$PIPELINE_DIR/ci/size-baseline.rock-5b-plus.json" "$bad/size-baseline.x86-minipc.json"
  run_baseline_compare x86-minipc "$tree" "$bad"
  [ "$status" -ne 0 ]
  [[ "$output" == *"size baseline unusable"* ]]
}

@test "size-gate wiring: the gate is NOT arch-gated (x86 carries a real ceiling too)" {
  # Gating on arm64 would exempt the one board whose size has never been measured.
  # Every shipped board has a non-null ceiling, so the gate applies to all of them.
  local block
  block="$(extract_size_gate_block)"
  [ -n "$block" ]
  [[ "$block" != *'${ARCH}'* ]]
  [[ "$block" != *'arm64'* ]]

  run python3 -c "
import json, sys
d = json.load(open('$SIZE_BUDGET_JSON', encoding='utf-8'))
e = {k: v for k, v in d.items() if not k.startswith('_')}
assert 'x86-minipc' in e, 'x86-minipc has no size-budget entry'
assert isinstance(e['x86-minipc']['rootfs_bytes_max'], int), 'x86-minipc ceiling must be a real integer'
print('X86-CEILING-OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"X86-CEILING-OK"* ]]
}

@test "size-gate: no board's ceiling may be raised above 1.5 GB" {
  # Raising rootfs_bytes_max to match an overage launders it into a passing gate.
  # Both RK3588 boards were 65-76 MB over and the ceiling was never moved; that is
  # the precedent this pins. Lowering stays allowed.
  run python3 -c "
import json
d = json.load(open('$SIZE_BUDGET_JSON', encoding='utf-8'))
for name, entry in d.items():
    if name.startswith('_'):
        continue
    limit = entry['rootfs_bytes_max']
    assert limit <= 1500000000, '%s: rootfs_bytes_max %d exceeds the 1.5 GB policy ceiling' % (name, limit)
print('CEILING-POLICY-OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CEILING-POLICY-OK"* ]]
}

@test "app-layer: first-party packages can be copied from mkosi source staging" {
  run grep -F 'stage_first_party_from_source_mount' "$PIPELINE_DIR/mkosi/mkosi.images/app/mkosi.postinst.chroot"
  [ "$status" -eq 0 ]

  run grep -F 'src="${src%/}/.staging/${board}/firstparty"' "$PIPELINE_DIR/mkosi/mkosi.images/app/mkosi.postinst.chroot"
  [ "$status" -eq 0 ]

  run grep -F 'cp -a "${src}"/*.deb "${FIRST_PARTY_DIR}/"' "$PIPELINE_DIR/mkosi/mkosi.images/app/mkosi.postinst.chroot"
  [ "$status" -eq 0 ]
}

@test "app-layer: first-party install is closed over staged packages and runtime deps" {
  run grep -F 'gstreamer1.0-libuvch264src' "$FETCH_DEBS"
  [ "$status" -eq 0 ]

  run grep -F 'dpkg -i "${debs[@]}"' "$PIPELINE_DIR/mkosi/mkosi.images/app/mkosi.postinst.chroot"
  [ "$status" -eq 0 ]

  run grep -F -- 'apt-get install -y --no-install-recommends --no-download -f' "$PIPELINE_DIR/mkosi/mkosi.images/app/mkosi.postinst.chroot"
  [ "$status" -eq 0 ]

  run grep -F 'apt-get update' "$PIPELINE_DIR/mkosi/mkosi.images/app/mkosi.postinst.chroot"
  [ "$status" -ne 0 ]
}

@test "runtime packages: sudo is installed for the CeraUI add-on helper" {
  run grep -Ex 'sudo[[:space:]]*(#.*)?' "$PIPELINE_DIR/manifests/packages/shared.list"
  [ "$status" -eq 0 ]
}

@test "runtime packages: gstreamer1.0-alsa is installed so alsasrc is available" {
  # Audio-capable capture pipelines construct an ALSA leg even when the source
  # selection has no configured audio. Keep this explicit because the plugin
  # is not pulled by the GStreamer base packages with --no-install-recommends.
  run grep -Ex 'gstreamer1\.0-alsa[[:space:]]*(#.*)?' "$PIPELINE_DIR/manifests/packages/shared.list"
  [ "$status" -eq 0 ]
}

@test "runtime packages: gstreamer1.0-nice is installed so nicesrc is available" {
  # WebRTC ICE pipelines require the libnice GStreamer source. Keep this explicit
  # because the plugin is not pulled by the GStreamer base packages with --no-install-recommends.
  run grep -Ex 'gstreamer1\.0-nice[[:space:]]*(#.*)?' "$PIPELINE_DIR/manifests/packages/shared.list"
  [ "$status" -eq 0 ]
}

@test "runtime packages: wireless-regdb is installed so cfg80211 loads regulatory.db" {
  # The runtime layer installs shared.list with --no-install-recommends
  # (runtime/mkosi.postinst.chroot), so wpasupplicant's `Recommends: wireless-regdb`
  # is NOT pulled transitively. Without an explicit entry the kernel cfg80211
  # subsystem fails to load /lib/firmware/regulatory.db at boot
  # ("Direct firmware load for regulatory.db failed with error -2") and
  # NetworkManager reports no usable WiFi interface (confirmed on real hardware).
  run grep -Ex 'wireless-regdb[[:space:]]*(#.*)?' "$PIPELINE_DIR/manifests/packages/shared.list"
  [ "$status" -eq 0 ]
}

@test "runtime packages: iw is installed so the regulatory domain can be applied" {
  # `wireless-tools` looks like it covers this and does NOT: it ships only the
  # legacy WEXT binaries (iwconfig/iwlist/iwgetid/iwpriv/iwspy). The nl80211 `iw`
  # binary is a SEPARATE Debian package, is nothing else's dependency in this
  # list, and is what CeraUI shells out to for `iw reg set <CC>` (apply the
  # operator's country) and `iw phy` (read the AP-usable channels back out).
  # Absent it, wireless-regdb is loaded but no country can ever be selected and
  # the hotspot is stuck on the conservative world domain.
  run grep -Ex 'iw[[:space:]]*(#.*)?' "$PIPELINE_DIR/manifests/packages/shared.list"
  [ "$status" -eq 0 ]
}

@test "runtime packages: squashfs-tools is installed so rauc can unsquashfs bundles" {
  # rauc info/install shells out to /usr/bin/unsquashfs to extract the manifest
  # (and rootfs image) from a plain-format .raucb. Without squashfs-tools on the
  # device, install fails right after signature verification with
  # "Failed to start unsquashfs: ... No such file or directory" (real Rock 5B+
  # hardware). build-time mksquashfs runs on the HOST/CI, so this runtime-only gap
  # was invisible until OTA was exercised on-device.
  run grep -Ex 'squashfs-tools[[:space:]]*(#.*)?' "$PIPELINE_DIR/manifests/packages/shared.list"
  [ "$status" -eq 0 ]
}

@test "runtime packages: e2fsprogs is installed so rauc can format ext4 slots" {
  # rauc install shells out to /sbin/mkfs.ext4 to format the target ext4 slot
  # before copying the new rootfs image during the slot-write phase, after
  # signature and manifest checks. Without e2fsprogs, real Rock 5B+ hardware
  # reported "Failed to execute child process 'mkfs.ext4' (No such file or
  # directory)"; build-time tooling never needed it, so this runtime-only gap
  # was invisible until OTA was exercised on-device.
  run grep -Ex 'e2fsprogs[[:space:]]*(#.*)?' "$PIPELINE_DIR/manifests/packages/shared.list"
  [ "$status" -eq 0 ]
}

@test "runtime packages: net-tools is installed so CeraUI's ifconfig poll works" {
  # CeraUI's backend polls /sbin/ifconfig every ~5s (apps/backend
  # network-interfaces.ts run("ifconfig", [])) to build the `netif` broadcast
  # (WiFi/Ethernet/cellular/bonded-link status). This minimal bookworm image ships
  # only modern iproute2, so without net-tools every poll tick fails ("Executable
  # not found in $PATH: \"ifconfig\"") and the Network destination renders empty
  # ("No WiFi/wired interfaces", "No SIM cards", "No active links") plus a missing
  # Ethernet entry in Bonded Links — confirmed on real Rock 5B+ hardware.
  run grep -Ex 'net-tools[[:space:]]*(#.*)?' "$PIPELINE_DIR/manifests/packages/shared.list"
  [ "$status" -eq 0 ]
}

@test "runtime packages: net-tools reaches the resolved runtime package set (rk3588 + x86)" {
  # net-tools is arch-independent (shared.list), so it must appear in the runtime
  # package set the runtime layer installs for EVERY board family — the same
  # sed|awk projection make_parity_rootfs uses to model the installed set. A
  # missing/misplaced entry (e.g. accidentally landing in a delta list only) would
  # break ifconfig on one family; this asserts the shared list carries it.
  local pkgs
  pkgs="$(sed -e 's/#.*//' "$PIPELINE_DIR/manifests/packages/shared.list" | awk 'NF{print $1}')"
  [[ "$pkgs" == *net-tools* ]]
}

@test "production image leaves debug access disabled without failing finalization" {
  run env \
    CERALIVE_DEBUG_IMAGE=0 \
    CERALIVE_DEBUG_PASSWORD_HASH='' \
    bash -c 'source "$1"; configure_debug_access' bash "$POSTINST_ENTRY"

  [ "$status" -eq 0 ]
}

@test "mkosi passes lab debug settings to every subimage" {
  run grep -Fx 'PassEnvironment=CERALIVE_DEBUG_IMAGE CERALIVE_DEBUG_PASSWORD_HASH CERALIVE_IMAGE_BUILD_COMMIT' "$PIPELINE_DIR/mkosi/mkosi.conf"

  [ "$status" -eq 0 ]
}

@test "mkosi PassEnvironment stays in lockstep with orchestrate.sh env_names" {
  # STRUCTURAL DRIFT GUARD (the actual bug class, not just two instances).
  #
  # orchestrate.sh:run_mkosi_build() exports+CLI-passes `env_names` to the
  # TOP-LEVEL mkosi image, but only PassEnvironment= in mkosi.conf propagates a
  # value from there into the base/platform/runtime/app SUBIMAGES, where the
  # postinst scripts that consume it actually run. A name in env_names that is
  # missing from PassEnvironment reads EMPTY in every subimage chroot — silently.
  # That drift shipped two production bugs: eth0/eth1 never renamed (dropped from
  # SRTLA's eth*/wlan* bonding globs) and an empty add-on keyring (rejects every
  # add-on signature). This test asserts env_names is a SUBSET of PassEnvironment
  # so any FUTURE name added to env_names without a matching PassEnvironment=
  # entry fails here — the lockstep the mkosi.conf comment already demands.
  local orchestrate="$LIB_DIR/orchestrate.sh"
  local mkosi_conf="$PIPELINE_DIR/mkosi/mkosi.conf"

  # Extract the multi-line `local env_names=( … )` bash array literal: every line
  # between the opener and the first line that is only a closing paren.
  local env_names
  env_names="$(awk '
    /local env_names=\(/ { grab=1; next }
    grab && /^[[:space:]]*\)/ { grab=0 }
    grab { print }
  ' "$orchestrate")"

  # Extract every whitespace-separated name from ALL PassEnvironment= lines.
  local pass_names
  pass_names="$(sed -n 's/^PassEnvironment=//p' "$mkosi_conf")"

  # Guard against a parser that silently yields nothing (which would make the
  # subset assertion vacuously pass).
  [ -n "$env_names" ]
  [ -n "$pass_names" ]

  local -A in_pass=()
  local n
  for n in $pass_names; do in_pass["$n"]=1; done

  # Names legitimately in env_names but NOT in PassEnvironment. SOURCE_DATE_EPOCH
  # is a reproducible-builds variable consumed ONLY by host-side orchestrator
  # scripts (never inside a subimage chroot — verified: zero references under
  # mkosi.images/); mkosi also handles it natively, so it needs no propagation.
  local -A env_only_ok=( [SOURCE_DATE_EPOCH]=1 )

  local missing=()
  for n in $env_names; do
    [ -n "${in_pass[$n]:-}" ] && continue
    [ -n "${env_only_ok[$n]:-}" ] && continue
    missing+=("$n")
  done

  if [ "${#missing[@]}" -ne 0 ]; then
    printf 'env_names not propagated via PassEnvironment=: %s\n' "${missing[*]}" >&2
  fi
  [ "${#missing[@]}" -eq 0 ]
}

@test "mkosi PassEnvironment forwards interface-naming + add-on keyring into subimages" {
  # Explicit regression pin for the two instances the lockstep guard above closed:
  #   * CERALIVE_INTERFACES_eth0/eth1/wlan0 → runtime install_interface_naming()
  #     emits per-role .link Path= rules; empty ⇒ ethernet keeps its kernel name
  #     (enP4p65s0) and SRTLA's eth*/wlan* glob never matches the wired uplink.
  #   * ADDON_KEYRING_B64 → runtime setup_addon_keyring() bakes the PUBLIC add-on
  #     keyring; empty ⇒ EMPTY placeholder that rejects ALL add-on signatures.
  local pass_names
  pass_names="$(sed -n 's/^PassEnvironment=//p' "$PIPELINE_DIR/mkosi/mkosi.conf")"

  local -A in_pass=()
  local n
  for n in $pass_names; do in_pass["$n"]=1; done

  local want missing=()
  for want in CERALIVE_INTERFACES_eth0 CERALIVE_INTERFACES_eth1 \
              CERALIVE_INTERFACES_wlan0 ADDON_KEYRING_B64; do
    [ -n "${in_pass[$want]:-}" ] || missing+=("$want")
  done

  if [ "${#missing[@]}" -ne 0 ]; then
    printf 'PassEnvironment= missing: %s\n' "${missing[*]}" >&2
  fi
  [ "${#missing[@]}" -eq 0 ]
}

@test "lab debug password requires an explicitly marked debug image" {
  local bin="$BATS_TEST_TMPDIR/debug-password-bin"
  local calls="$BATS_TEST_TMPDIR/debug-password-calls"
  mkdir -p "$bin"

  for command in id usermod chage install; do
    cat >"$bin/$command" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >>"$DEBUG_PASSWORD_CALLS"
case "$(basename "$0")" in
  id) exit 0 ;;
esac
SH
    chmod +x "$bin/$command"
  done

  run env \
    PATH="$bin:$PATH" \
    DEBUG_PASSWORD_CALLS="$calls" \
    CERALIVE_DEBUG_IMAGE=0 \
    CERALIVE_DEBUG_PASSWORD_HASH='$6$test$hash' \
    bash -c 'source "$1"; configure_debug_access' bash "$POSTINST_ENTRY"

  [ "$status" -ne 0 ]
  [[ "$output" == *"CERALIVE_DEBUG_PASSWORD_HASH requires CERALIVE_DEBUG_IMAGE=1"* ]]
}

@test "lab debug image unlocks ceralive with an injected password hash" {
  local bin="$BATS_TEST_TMPDIR/debug-password-bin"
  local calls="$BATS_TEST_TMPDIR/debug-password-calls"
  mkdir -p "$bin"

  for command in id usermod chage install; do
    cat >"$bin/$command" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >>"$DEBUG_PASSWORD_CALLS"
case "$(basename "$0")" in
  id) exit 0 ;;
esac
SH
    chmod +x "$bin/$command"
  done

  run env \
    PATH="$bin:$PATH" \
    DEBUG_PASSWORD_CALLS="$calls" \
    CERALIVE_DEBUG_IMAGE=1 \
    CERALIVE_DEBUG_PASSWORD_HASH='$6$test$hash' \
    bash -c 'source "$1"; configure_debug_access' bash "$POSTINST_ENTRY"

  [ "$status" -eq 0 ]
  run cat "$calls"
  [ "$status" -eq 0 ]
  [[ "$output" == *'usermod --password $6$test$hash ceralive'* ]]
  [[ "$output" == *'chage -d -1 ceralive'* ]]
  [[ "$output" == *'install -Dm 0600 /dev/null /etc/ceralive/debug-image'* ]]
}

@test "production image leaves ssh.service NOT enabled (disabled-by-default)" {
  # Todo 42: on a production image (CERALIVE_DEBUG_IMAGE=0/unset) ssh MUST NOT be
  # enabled. The base layer's openssh-server preset already enables ssh.service, so
  # configure_ssh_enablement must actively DISABLE it — never call `enable ssh`.
  local bin="$BATS_TEST_TMPDIR/ssh-enable-bin"
  local calls="$BATS_TEST_TMPDIR/ssh-enable-calls"
  local systemd_etc="$BATS_TEST_TMPDIR/ssh-systemd-etc"
  local systemd_presets="$BATS_TEST_TMPDIR/ssh-systemd-presets"
  mkdir -p "$bin" "$systemd_etc" "$systemd_presets"

  cat >"$bin/systemctl" <<'SH'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$SSH_ENABLE_CALLS"
# disable_service greps list-unit-files output for the unit before disabling; echo
# the unit so it treats it as present (the base-layer-enabled state).
case "$1" in
  list-unit-files) printf '%s enabled\n' "$2" ;;
esac
exit 0
SH
  chmod +x "$bin/systemctl"

  run env \
    PATH="$bin:$PATH" \
    SSH_ENABLE_CALLS="$calls" \
    CERALIVE_DEBUG_IMAGE=0 \
    CERALIVE_SYSTEMD_ETC_UNIT_DIR="$systemd_etc" \
    CERALIVE_SYSTEMD_PRESET_DIR="$systemd_presets" \
    bash -c 'source "$1"; configure_ssh_enablement' bash "$POSTINST_ENTRY"

  [ "$status" -eq 0 ]
  run cat "$calls"
  [ "$status" -eq 0 ]
  [[ "$output" != *"enable ssh"* ]]
  [[ "$output" == *"disable ssh.service"* ]]
}

@test "lab debug image enables ssh.service by default" {
  # Todo 42: the debug branch (CERALIVE_DEBUG_IMAGE=1) keeps the historical
  # enabled-by-default behavior — `enable ssh`, no disable.
  local bin="$BATS_TEST_TMPDIR/ssh-enable-bin"
  local calls="$BATS_TEST_TMPDIR/ssh-enable-calls"
  mkdir -p "$bin"

  cat >"$bin/systemctl" <<'SH'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$SSH_ENABLE_CALLS"
case "$1" in
  list-unit-files) printf '%s enabled\n' "$2" ;;
esac
exit 0
SH
  chmod +x "$bin/systemctl"

  run env \
    PATH="$bin:$PATH" \
    SSH_ENABLE_CALLS="$calls" \
    CERALIVE_DEBUG_IMAGE=1 \
    bash -c 'source "$1"; configure_ssh_enablement' bash "$POSTINST_ENTRY"

  [ "$status" -eq 0 ]
  run cat "$calls"
  [ "$status" -eq 0 ]
  [[ "$output" == *"enable ssh"* ]]
  [[ "$output" != *"disable ssh"* ]]
}

@test "parity: ceralive.service fails when ExecStart target is missing" {
  local root="$BATS_TEST_TMPDIR/parity-rootfs"
  make_parity_rootfs "$root"
  cat >"$root/etc/systemd/system/ceralive.service" <<'UNIT'
[Service]
ExecStart=/opt/ceralive/ceralive
UNIT

  run "$LIB_DIR/parity-check.sh" "$root"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ceralive.service ExecStart target missing/not executable: /opt/ceralive/ceralive"* ]]
}

@test "parity: ceralive.service must be enabled for multi-user boot" {
  local root="$BATS_TEST_TMPDIR/parity-rootfs"
  make_parity_rootfs "$root"
  mkdir -p "$root/usr/local/bin"
  : >"$root/usr/local/bin/ceralive"
  chmod +x "$root/usr/local/bin/ceralive"
  cat >"$root/etc/systemd/system/ceralive.service" <<'UNIT'
[Service]
ExecStart=/usr/local/bin/ceralive
UNIT

  run "$LIB_DIR/parity-check.sh" "$root"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ceralive.service is not enabled for multi-user boot"* ]]
}

@test "rauc: service guard checks installed unit files without relying on systemctl list output" {
  run grep -F '[[ ! -f /lib/systemd/system/rauc.service && ! -f /usr/lib/systemd/system/rauc.service ]]' "$PIPELINE_DIR/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"
  [ "$status" -eq 0 ]

  run grep -F '[[ ! -f /lib/systemd/system/rauc.service && ! -f /usr/lib/systemd/system/rauc.service ]]' "$PIPELINE_DIR/mkosi/customize/rauc-setup.sh"
  [ "$status" -eq 0 ]

  run grep -F 'systemctl list-unit-files rauc.service' "$PIPELINE_DIR/mkosi/mkosi.images/runtime/mkosi.postinst.chroot" "$PIPELINE_DIR/mkosi/customize/rauc-setup.sh"
  [ "$status" -ne 0 ]
}

# ===========================================================================
# 11. Reproducible builds (Task 14) — a double-build of the SAME inputs yields a
#     BIT-IDENTICAL signed .raucb. build-bundle.sh clamps every embedded mtime to
#     SOURCE_DATE_EPOCH (rootfs.tar + squashfs) and signs the CMS without the
#     wall-clock signingTime attribute — the only non-determinism real `rauc`
#     cannot suppress — so two runs collide on sha256. A mock rootfs (no
#     mkosi/network/board) keeps it in this UNIT suite while exercising the REAL
#     bundle assembly + RSA signing chain against the committed dev PKI.
# ===========================================================================

@test "repro: double-build of rock-5b-plus yields a bit-identical .raucb (same sha256)" {
  repro_prereqs || skip "mksquashfs/openssl/dev-PKI not available"
  build_repro_bundle "$BATS_TEST_TMPDIR/r1" 1700000000
  build_repro_bundle "$BATS_TEST_TMPDIR/r2" 1700000000
  [ -f "$BATS_TEST_TMPDIR/r1/fixed.raucb" ]
  [ -f "$BATS_TEST_TMPDIR/r2/fixed.raucb" ]
  local h1 h2
  h1="$(sha256sum "$BATS_TEST_TMPDIR/r1/fixed.raucb" | cut -d' ' -f1)"
  h2="$(sha256sum "$BATS_TEST_TMPDIR/r2/fixed.raucb" | cut -d' ' -f1)"
  [ -n "$h1" ]
  [ "$h1" = "$h2" ]
}

@test "repro: the reproducible bundle still verifies leaf->intermediate->root (signing not faked)" {
  repro_prereqs || skip "mksquashfs/openssl/dev-PKI not available"
  local tree="$BATS_TEST_TMPDIR/repro-vtree"; mkdir -p "$tree/etc"
  printf 'x\n' > "$tree/etc/hostname"
  local out="$BATS_TEST_TMPDIR/rv"; mkdir -p "$out"
  run env CERALIVE_RAUC_PKI_DIR="$PIPELINE_DIR/.dev-keys" \
      COMPATIBLE_STRING="ceralive-rock-5b-plus" \
      BUNDLE_VERSION="reprotest" BUNDLE_TS="fixed" BUNDLE_OUT_DIR="$out" \
      SOURCE_DATE_EPOCH=1700000000 \
      bash "$PIPELINE_DIR/lib/build-bundle.sh" rock-5b-plus "$tree"
  [ "$status" -eq 0 ]
  [[ "$output" == *"signature verified: leaf -> intermediate -> root"* ]]
  [ -f "$out/fixed.raucb" ]
}

@test "repro: changing SOURCE_DATE_EPOCH changes the artifact (test has teeth / not vacuous)" {
  repro_prereqs || skip "mksquashfs/openssl/dev-PKI not available"
  build_repro_bundle "$BATS_TEST_TMPDIR/t1" 1700000000
  build_repro_bundle "$BATS_TEST_TMPDIR/t2" 1800000000
  local h1 h2
  h1="$(sha256sum "$BATS_TEST_TMPDIR/t1/fixed.raucb" | cut -d' ' -f1)"
  h2="$(sha256sum "$BATS_TEST_TMPDIR/t2/fixed.raucb" | cut -d' ' -f1)"
  [ -n "$h1" ]
  [ "$h1" != "$h2" ]
}

# ===========================================================================
# 12. Bounded-parallel multi-board runner (Task 12) — lib/build-all.sh.
#     Two guards:
#       * REGRESSION: `build --all` under DRY_RUN=1 still resolves the full board
#         list and exits 0 BEFORE the runner is reached (the preview contract the
#         runner must not break).
#       * AGGREGATE + ISOLATION: build-all.sh run directly against a STUB
#         orchestrator (no real mkosi/network/board) — one board passes, one
#         fails. The overall run must exit non-zero (failure never masked), yet
#         the passing board must still complete with its OWN log file (no early
#         abort, logs not interleaved). A stub keeps this in the UNIT suite.
# ===========================================================================

@test "t12 parallel: build --all under DRY_RUN=1 exits 0 and prints the resolved board list" {
  run env DRY_RUN=1 bash "$PIPELINE_DIR/build" --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY_RUN"* ]]
  # every shipped board manifest must appear in the previewed selection
  local f board
  for f in "$PIPELINE_DIR"/manifests/boards/*.yaml; do
    board="$(basename "$f" .yaml)"
    [[ "$output" == *"$board"* ]] || { echo "missing board in preview: $board"; false; }
  done
}

@test "t12 parallel: build-all.sh fails overall if any board fails, but the passing board still completes (isolated logs)" {
  local bdir="$BATS_TEST_TMPDIR/boards" ldir="$BATS_TEST_TMPDIR/logs"
  mkdir -p "$bdir" "$ldir"
  # Fixture manifests: content is irrelevant — the STUB orchestrator ignores it,
  # find_manifest only needs the files to exist.
  : > "$bdir/passboard.yaml"
  : > "$bdir/failboard.yaml"

  # STUB orchestrator: echoes a marker (so we can prove the log is its OWN output)
  # and exits non-zero for any board whose name contains 'fail'.
  local stub="$BATS_TEST_TMPDIR/stub-orchestrate.sh"
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
board=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --board)    board="$2"; shift 2 ;;
    --manifest) shift 2 ;;
    *)          shift ;;
  esac
done
echo "stub orchestrator ran for board=${board}"
case "$board" in
  *fail*) echo "stub: simulating failure for ${board}" >&2; exit 7 ;;
  *)      exit 0 ;;
esac
SH
  chmod +x "$stub"

  run env ORCHESTRATOR="$stub" BOARDS_DIR="$bdir" LOGS_DIR="$ldir" JOBS=2 \
    bash "$PIPELINE_DIR/lib/build-all.sh" passboard failboard

  # A failed board makes the whole run non-zero (aggregate, never swallowed).
  [ "$status" -ne 0 ]
  # Summary table reports BOTH outcomes with the real per-board exit code.
  [[ "$output" == *"passboard"* ]]
  [[ "$output" == *"failboard"* ]]
  [[ "$output" == *"FAIL(7)"* ]]
  [[ "$output" == *"board(s) FAILED"* ]]

  # The passing board completed despite the other's failure: its OWN log exists
  # and carries the stub's stdout (per-board isolation, not interleaved).
  local passlog faillog
  passlog="$(echo "$ldir"/passboard-*.log)"
  faillog="$(echo "$ldir"/failboard-*.log)"
  [ -f "$passlog" ]
  [ -f "$faillog" ]
  grep -q "stub orchestrator ran for board=passboard" "$passlog"
  # the failing board's stderr was captured into ITS log, not the passing one
  grep -q "simulating failure for failboard" "$faillog"
  run ! grep -q "failboard" "$passlog"
}
