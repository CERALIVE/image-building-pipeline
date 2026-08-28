#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
#
# variant-contract.bats — family variants + kernel-build-from-source (Task 26) — variant
# resolution and overlay precedence, pin verification, the two config modes, and
# the suppression/uniqueness contract between the built and fetched kernels.
#
# Split out of the former tests/manifest.bats with the cases moved VERBATIM;
# the shared setup and every fixture helper live in manifest-helpers.bash.
#
# Run:  run-tests              (CI entrypoint)
#   or: bats tests/variant-contract.bats

load manifest-helpers

# lib/build-kernel.sh is an ENTRY plus the lib/kernel/ concern modules it sources.
# A check that extracts a FUNCTION BODY out of the stage by TEXT must read the
# whole SET in the entry's own source order — pointed at the entry alone the
# extraction yields nothing and the assertion built on it goes vacuous. The module
# list is derived from the entry's real `source` lines, so a module dropped from
# that list drops out of the check too.
write_build_kernel_source_set() {
  local out="$1" entry="$LIB_DIR/build-kernel.sh" module
  {
    cat "$entry"
    while read -r module; do
      cat "$LIB_DIR/kernel/$module"
    done < <(sed -n 's#^source "${KERNEL_LIB_DIR}/\(.*\)"$#\1#p' "$entry")
  } >"$out"
  [ -s "$out" ]
}

# ===========================================================================
# 26. Family variants + kernel-build-from-source (Task 26).
#
#     The load-bearing property of this whole feature is a NEGATIVE one: adding
#     an opt-in variant must not move the production vendor path by a single
#     byte. That is pinned first (against committed golden fixtures), and pinned
#     with an explicit non-vacuity leg, because a golden-file comparison that
#     silently compares nothing is worse than no comparison at all.
# ===========================================================================

@test "variants: shipped rk3588 family declares edge and still validates" {
  run validate_manifest "$PIPELINE_DIR/manifests/families/rk3588.yaml" "$FAMILY_SCHEMA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"VALID"* ]]
  grep -Eq '^variants:' "$PIPELINE_DIR/manifests/families/rk3588.yaml"
  grep -Eq '^  edge:' "$PIPELINE_DIR/manifests/families/rk3588.yaml"
}

@test "variants: VENDOR PATH IS BYTE-IDENTICAL for every shipped board" {
  # THE hard requirement of task 26. The fixtures were captured from the
  # resolver BEFORE variants existed; if declaring one moved any production
  # parameter, this fails with a readable diff.
  local board
  for board in rock-5b-plus orange-pi-5-plus x86-minipc; do
    run bash -c "'$RESOLVE_SH' '$board' 2>/dev/null"
    [ "$status" -eq 0 ]
    if ! diff -u "$(VENDOR_BASELINE_DIR)/${board}.params" <(printf '%s\n' "$output") >&2; then
      printf 'vendor path moved for %s\n' "$board" >&2
      false
    fi
  done
}

@test "variants: explicit --variant default is also byte-identical to the baseline" {
  run bash -c "'$RESOLVE_SH' rock-5b-plus --variant default 2>/dev/null"
  [ "$status" -eq 0 ]
  diff -u "$(VENDOR_BASELINE_DIR)/rock-5b-plus.params" <(printf '%s\n' "$output") >&2
}

@test "variants: CERALIVE_KERNEL_VARIANT=default is byte-identical too" {
  run bash -c "CERALIVE_KERNEL_VARIANT=default '$RESOLVE_SH' rock-5b-plus 2>/dev/null"
  [ "$status" -eq 0 ]
  diff -u "$(VENDOR_BASELINE_DIR)/rock-5b-plus.params" <(printf '%s\n' "$output") >&2
}

@test "variants: the byte-identity proof HAS TEETH (a real change makes it fail)" {
  # Non-vacuity. Resolve with the edge variant — which genuinely changes the
  # kernel package and branch — and require the SAME comparison to fail. Without
  # this leg a broken fixture path would make the guard above pass forever.
  run bash -c "'$RESOLVE_SH' rock-5b-plus --variant edge 2>/dev/null"
  [ "$status" -eq 0 ]
  run diff -q "$(VENDOR_BASELINE_DIR)/rock-5b-plus.params" <(printf '%s\n' "$output")
  [ "$status" -ne 0 ]
}

@test "variants: the variants: block never reaches the flattened param set" {
  # A leaked VARIANTS_* key would (a) move the vendor path and (b) hand the
  # orchestrator a second, unselected kernel pin in its environment.
  local board
  for board in rock-5b-plus orange-pi-5-plus x86-minipc; do
    run bash -c "'$RESOLVE_SH' '$board' 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" != *"VARIANTS_"* ]]
    run bash -c "'$RESOLVE_SH' rock-5b-plus --variant edge 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" != *"VARIANTS_"* ]]
  done
}

@test "variants: merge order is family -> variant -> board (board still wins last)" {
  fam="$BATS_TEST_TMPDIR/vfam.yaml"
  brd="$BATS_TEST_TMPDIR/vbrd.yaml"
  cat > "$fam" <<'YAML'
from_family: family
overridden_by_variant: family
overridden_by_board: family
variants:
  edge:
    overridden_by_variant: variant
    overridden_by_board: variant
YAML
  cat > "$brd" <<'YAML'
family: vfam
overridden_by_board: board
YAML
  run python3 "$RESOLVE_PY" merge --family "$fam" --board "$brd" --variant edge
  [ "$status" -eq 0 ]
  [[ "$output" == *$'FROM_FAMILY\tfamily'* ]]
  [[ "$output" == *$'OVERRIDDEN_BY_VARIANT\tvariant'* ]]
  [[ "$output" == *$'OVERRIDDEN_BY_BOARD\tboard'* ]]
}

@test "variants: an unknown variant fails loudly and lists what IS available" {
  run bash -c "'$RESOLVE_SH' rock-5b-plus --variant does-not-exist 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does-not-exist"* ]]
  [[ "$output" == *"available: edge"* ]]
}

@test "variants: --variant with no name is refused (never silently defaults)" {
  run bash -c "'$RESOLVE_SH' rock-5b-plus --variant '' 2>&1"
  [ "$status" -ne 0 ]
}

@test "variants: x86 has no variants, so an edge build of x86-minipc is refused" {
  # x86_64 declares no variants at all. Asking for one must fail rather than
  # silently resolve the vendor path under a name that promises otherwise.
  run bash -c "'$RESOLVE_SH' x86-minipc --variant edge 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown variant 'edge'"* ]]
  [[ "$output" == *"available: <none>"* ]]
}

@test "variants: schema rejects a variant named 'default' (reserved)" {
  local f="$BATS_TEST_TMPDIR/default-variant.yaml"
  write_variant_family "$f" "  default:
    armbian_branch: edge"
  run validate_manifest "$f" "$FAMILY_SCHEMA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"variants"* ]]
}

@test "variants: schema rejects an unknown field inside a variant overlay" {
  # This used to use firmware_packages as its example of an out-of-scope field.
  # That field is now IN scope (see the leg below), so the example moved to one
  # that is still genuinely image-shape rather than kernel-track: a variant that
  # could retarget the bootloader would be able to reshape the whole image, which
  # is exactly what `additionalProperties: false` is here to prevent.
  local f="$BATS_TEST_TMPDIR/wide-variant.yaml"
  write_variant_family "$f" "  edge:
    uboot_packages: [something-else]"
  run validate_manifest "$f" "$FAMILY_SCHEMA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"uboot_packages"* ]]

  # ... and a second still-forbidden shape, so the leg does not rest on one name.
  local g="$BATS_TEST_TMPDIR/wide-variant-2.yaml"
  write_variant_family "$g" "  edge:
    partition_template: something-else"
  run validate_manifest "$g" "$FAMILY_SCHEMA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"partition_template"* ]]
}

@test "variants: firmware_packages IS an accepted overlay field (the GPU userspace is a kernel-track fact)" {
  # Admitted deliberately and narrowly: the vendor kernel drives the Mali-G610
  # through Rockchip's out-of-tree module + the libmali blob, while mainline
  # drives the same silicon through the in-tree panthor driver + Mesa. The two
  # userspaces are not interchangeable and cannot coexist (libmali's
  # 00-aarch64-mali.conf captures libEGL/libGLESv2/libgbm image-wide), so which
  # one ships is decided by the kernel track — the same logic that already
  # admits kernel_extension_packages. Pinned here so a future narrowing of the
  # schema cannot silently put libmali back on the mainline path.
  local f="$BATS_TEST_TMPDIR/fw-variant.yaml"
  write_variant_family "$f" "  edge:
    firmware_packages: [armbian-firmware]"
  run validate_manifest "$f" "$FAMILY_SCHEMA"
  [ "$status" -eq 0 ]

  # An EMPTY list is legal too (minItems: 0), matching kernel_extension_packages.
  local g="$BATS_TEST_TMPDIR/fw-variant-empty.yaml"
  write_variant_family "$g" "  edge:
    firmware_packages: []"
  run validate_manifest "$g" "$FAMILY_SCHEMA"
  [ "$status" -eq 0 ]
}

@test "variant_overrides: OPi 5+ --variant edge resolves the MAINLINE DTB name" {
  # Mainline's rockchip Makefile at the pinned v7.2 builds
  # rk3588-orangepi-5-plus.dtb (confirmed in the v7.2 compile evidence: `DTC
  # arch/arm64/boot/dts/rockchip/rk3588-orangepi-5-plus.dtb`), and the override
  # states that explicitly rather than inheriting it, so a future mainline rename
  # moves exactly one line.
  run bash -c "'$RESOLVE_SH' orange-pi-5-plus --variant edge 2>/dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DTB_NAME='rk3588-orangepi-5-plus.dtb'"* ]]
  [[ "$output" != *"rk3588s-orangepi-5-plus.dtb"* ]]
}

@test "variant_overrides: OPi 5+ PRODUCTION path resolves the VENDOR DTB name" {
  # REGRESSION GUARD. The board shipped dtb_name 'rk3588s-orangepi-5-plus.dtb'
  # from its first commit, inferred from the "5 Plus (RK3588S)" marketing name.
  # It is wrong: the 5 Plus carries the full RK3588. The pinned vendor package
  # linux-dtb-vendor-rk35xx 26.5.1 ships rk3588-orangepi-5-plus.dtb and has NO
  # rk3588s-orangepi-5-plus.dtb — verified by extraction, and true of every
  # version in the Armbian archive back to 24.5.1, so this was never drift.
  # A real production build failed the [6b/9] boot-artifact gate on it; the
  # DRY_RUN-only PR gate never runs that stage, which is what this test replaces.
  run bash -c "'$RESOLVE_SH' orange-pi-5-plus 2>/dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DTB_NAME='rk3588-orangepi-5-plus.dtb'"* ]]
  [[ "$output" != *"rk3588s-orangepi-5-plus.dtb"* ]]
}

@test "variant_overrides: no shipped board claims an rk3588s- DTB (the '5 Plus' trap)" {
  # The bug class, not just the one instance: an RK3588S-looking board name does
  # not make the DTB rk3588s-. Both shipped RK3588 boards are full-RK3588 parts,
  # so the prefix must appear on neither, on either kernel path.
  local board path
  for board in rock-5b-plus orange-pi-5-plus; do
    run ! grep -Eq '^\s*dtb_name:\s*rk3588s-' "$PIPELINE_DIR/manifests/boards/${board}.yaml"
    for path in "" "--variant edge"; do
      run bash -c "'$RESOLVE_SH' '$board' $path 2>/dev/null"
      [ "$status" -eq 0 ]
      [[ "$output" != *"DTB_NAME='rk3588s-"* ]]
    done
  done
}

@test "variant_overrides: Rock 5B+ DTB is UNAFFECTED with and without the variant" {
  # It declares no dtb_name override and needs none — mainline and vendor agree
  # on this board's spelling. Asserted explicitly on BOTH paths so a future
  # accidental divergence (either tree renaming it) is caught here, not at build.
  #
  # The board DOES declare variant_overrides now — for uboot_packages, since the
  # edge track fetches Armbian's mainline-TF-A -edge U-Boot (todo 12). So the
  # claim under test is narrowed to the DTB key it was always really about:
  # the override block must not name dtb_name on this board.
  local path
  for path in "" "--variant edge"; do
    run bash -c "'$RESOLVE_SH' rock-5b-plus $path 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"DTB_NAME='rk3588-rock-5b-plus.dtb'"* ]]
  done
  run ! grep -Eq '^\s+dtb_name:' <(sed -n '/^variant_overrides:/,$p' \
    "$PIPELINE_DIR/manifests/boards/rock-5b-plus.yaml")
}

@test "variant_overrides: the mechanism is OPT-IN, not a silent global change" {
  # Non-vacuity. A board that declares NO override must resolve its ordinary
  # board dtb_name under a variant, exactly as before this existed. Without
  # this leg the change could be rewriting DTB names fleet-wide unnoticed.
  local fam="$BATS_TEST_TMPDIR/no-ovr-fam.yaml"
  local brd="$BATS_TEST_TMPDIR/no-ovr-brd.yaml"
  cat > "$fam" <<'YAML'
dtb_name: family-default.dtb
variants:
  edge:
    armbian_branch: edge
YAML
  cat > "$brd" <<'YAML'
family: no-ovr-fam
dtb_name: board-own.dtb
YAML
  run python3 "$RESOLVE_PY" merge --family "$fam" --board "$brd" --variant edge
  [ "$status" -eq 0 ]
  [[ "$output" == *$'DTB_NAME\tboard-own.dtb'* ]]
}

@test "variant_overrides: the block never reaches the flattened param set" {
  # A leaked VARIANT_OVERRIDES_* key would move the vendor path and hand the
  # orchestrator a second, unselected DTB name in its environment.
  local path
  for path in "" "--variant edge"; do
    run bash -c "'$RESOLVE_SH' orange-pi-5-plus $path 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" != *"VARIANT_OVERRIDES"* ]]
  done
}

@test "variant_overrides: an override applies AFTER the board, not before it" {
  # Board-wins-last is untouched: a plain variant overlay still loses to the
  # board, and only the board's OWN per-variant entry wins.
  local fam="$BATS_TEST_TMPDIR/ovr-order-fam.yaml"
  local brd="$BATS_TEST_TMPDIR/ovr-order-brd.yaml"
  cat > "$fam" <<'YAML'
variants:
  edge:
    dtb_name: from-variant.dtb
    other_field: from-variant
YAML
  cat > "$brd" <<'YAML'
family: ovr-order-fam
dtb_name: from-board.dtb
other_field: from-board
variant_overrides:
  edge:
    dtb_name: from-board-override.dtb
YAML
  run python3 "$RESOLVE_PY" merge --family "$fam" --board "$brd" --variant edge
  [ "$status" -eq 0 ]
  [[ "$output" == *$'DTB_NAME\tfrom-board-override.dtb'* ]]
  [[ "$output" == *$'OTHER_FIELD\tfrom-board'* ]]
}

@test "variant_overrides: an override for a variant the family lacks is FATAL" {
  # The PR #83 defect-3 class: a mechanism that silently never triggers. A
  # typo'd variant name must fail the resolve, not sit there looking effective.
  local fam="$BATS_TEST_TMPDIR/typo-fam.yaml"
  local brd="$BATS_TEST_TMPDIR/typo-brd.yaml"
  cat > "$fam" <<'YAML'
variants:
  edge:
    armbian_branch: edge
YAML
  cat > "$brd" <<'YAML'
family: typo-fam
dtb_name: board-own.dtb
variant_overrides:
  edg:
    dtb_name: never-applies.dtb
YAML
  # Fatal on the DEFAULT path too — the typo is a manifest defect either way.
  run python3 "$RESOLVE_PY" merge --family "$fam" --board "$brd"
  [ "$status" -eq 2 ]
  [[ "$output" == *"variant 'edg'"* ]]
  [[ "$output" == *"never apply"* ]]
}

@test "variant_overrides: schema rejects an entry named 'default' (reserved)" {
  local f="$BATS_TEST_TMPDIR/default-override.yaml"
  write_override_board "$f" "  default:
    dtb_name: rk3588-other.dtb"
  run validate_manifest "$f" "$BOARD_SCHEMA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"variant_overrides"* ]]
}

@test "variant_overrides: schema rejects any field outside the permitted set" {
  # Deliberately narrow. The permitted keys are dtb_name and uboot_packages —
  # the two board facts that genuinely come from whichever tree/branch a variant
  # builds — and NOT a general board-overrides-the-variant escape hatch. The
  # per-key legs live in tests/bootloader-variant.bats; this one pins that the
  # override stayed closed at all.
  local f="$BATS_TEST_TMPDIR/wide-override.yaml"
  write_override_board "$f" "  edge:
    kernel_packages: [linux-image-something]"
  run validate_manifest "$f" "$BOARD_SCHEMA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"kernel_packages"* ]]
}

@test "variant_overrides: shipped OPi 5+ board manifest declares edge and validates" {
  run validate_manifest "$PIPELINE_DIR/manifests/boards/orange-pi-5-plus.yaml" "$BOARD_SCHEMA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"VALID"* ]]
  grep -Eq '^variant_overrides:' "$PIPELINE_DIR/manifests/boards/orange-pi-5-plus.yaml"
  grep -Eq '^  edge:' "$PIPELINE_DIR/manifests/boards/orange-pi-5-plus.yaml"
}

@test "kernel_source: schema rejects a FLOATING patches reference" {
  # The single most important pin in the block: a branch name here would make
  # the built kernel unreproducible while still looking pinned.
  local f="$BATS_TEST_TMPDIR/floating-patches.yaml"
  write_variant_family "$f" "  edge:
    kernel_source:
      git_url: https://example.invalid/linux.git
      tag: v7.1.7
      commit: c7ba9d6de43e9d9bd755b1f3c19501a38898c6b6
      patches_git_url: https://example.invalid/patches.git
      patches_commit: main
      patches_series: patches/series
      defconfig_base: defconfig
      defconfig_fragment: manifests/kernel/f.fragment
      builder_image: debian:trixie-slim@sha256:28de0877c2189802884ccd20f15ee41c203573bd87bb6b883f5f46362d24c5c2
      local_version: -ceralive-rk3588
      kernel_release: 7.1.7-ceralive-rk3588
      package_version: 7.1.7-ceralive1
      dtb_deb_dir: /usr/lib/linux-image-7.1.7-ceralive-rk3588/rockchip
      dtb_boot_dir: /boot/dtb/rockchip"
  run validate_manifest "$f" "$FAMILY_SCHEMA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"patches_commit"* ]]
}

@test "kernel_source: schema rejects a builder_image without a digest" {
  local f="$BATS_TEST_TMPDIR/floating-image.yaml"
  write_variant_family "$f" "  edge:
    kernel_source:
      git_url: https://example.invalid/linux.git
      tag: v7.1.7
      commit: c7ba9d6de43e9d9bd755b1f3c19501a38898c6b6
      patches_git_url: https://example.invalid/patches.git
      patches_commit: 4809354656a16443c0b69f1e72b77f3fea1cbdae
      patches_series: patches/series
      defconfig_base: defconfig
      defconfig_fragment: manifests/kernel/f.fragment
      builder_image: debian:trixie-slim
      local_version: -ceralive-rk3588
      kernel_release: 7.1.7-ceralive-rk3588
      package_version: 7.1.7-ceralive1
      dtb_deb_dir: /usr/lib/linux-image-7.1.7-ceralive-rk3588/rockchip
      dtb_boot_dir: /boot/dtb/rockchip"
  run validate_manifest "$f" "$FAMILY_SCHEMA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"builder_image"* ]]
}

@test "kernel_source: schema rejects an incomplete pin (missing commit)" {
  local f="$BATS_TEST_TMPDIR/incomplete-pin.yaml"
  write_variant_family "$f" "  edge:
    kernel_source:
      git_url: https://example.invalid/linux.git
      tag: v7.1.7
      patches_git_url: https://example.invalid/patches.git
      patches_commit: 4809354656a16443c0b69f1e72b77f3fea1cbdae
      patches_series: patches/series
      defconfig_base: defconfig
      defconfig_fragment: manifests/kernel/f.fragment
      builder_image: debian:trixie-slim@sha256:28de0877c2189802884ccd20f15ee41c203573bd87bb6b883f5f46362d24c5c2
      local_version: -ceralive-rk3588
      kernel_release: 7.1.7-ceralive-rk3588
      package_version: 7.1.7-ceralive1
      dtb_deb_dir: /usr/lib/linux-image-7.1.7-ceralive-rk3588/rockchip
      dtb_boot_dir: /boot/dtb/rockchip"
  run validate_manifest "$f" "$FAMILY_SCHEMA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"commit"* ]]
}

@test "kernel_source: suppressed_packages is DERIVED, and a manifest cannot author it" {
  local f="$BATS_TEST_TMPDIR/authored-suppression.yaml"
  write_variant_family "$f" "  edge:
    kernel_source:
      git_url: https://example.invalid/linux.git
      tag: v7.1.7
      commit: c7ba9d6de43e9d9bd755b1f3c19501a38898c6b6
      patches_git_url: https://example.invalid/patches.git
      patches_commit: 4809354656a16443c0b69f1e72b77f3fea1cbdae
      patches_series: patches/series
      defconfig_base: defconfig
      defconfig_fragment: manifests/kernel/f.fragment
      builder_image: debian:trixie-slim@sha256:28de0877c2189802884ccd20f15ee41c203573bd87bb6b883f5f46362d24c5c2
      local_version: -ceralive-rk3588
      kernel_release: 7.1.7-ceralive-rk3588
      package_version: 7.1.7-ceralive1
      dtb_deb_dir: /usr/lib/linux-image-7.1.7-ceralive-rk3588/rockchip
      dtb_boot_dir: /boot/dtb/rockchip
      suppressed_packages: [linux-image-vendor-rk35xx]"
  run validate_manifest "$f" "$FAMILY_SCHEMA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"suppressed_packages"* ]]
}

@test "kernel_source: the edge resolve replaces the kernel package and empties DTB_PACKAGES" {
  run bash -c "'$RESOLVE_SH' rock-5b-plus --variant edge 2>/dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"KERNEL_PACKAGES='linux-image-7.2.0-ceralive-rk3588'"* ]]
  [[ "$output" == *"DTB_PACKAGES=''"* ]]
  [[ "$output" == *"KERNEL_VARIANT='edge'"* ]]
  # U-Boot and firmware are still PREBUILT-FETCHED, never built from source —
  # that is what kernel_source's suppression set does and does not cover, and it
  # is unchanged. What DID change (todo 12) is WHICH prebuilt U-Boot the edge
  # track fetches: the board's variant_overrides.edge names Armbian's
  # mainline-TF-A -edge package.
  [[ "$output" == *"UBOOT_PACKAGES='linux-u-boot-rock-5b-plus-edge'"* ]]

  # FIRMWARE is no longer untouched by this variant, and that is the point.
  # This assertion used to read `armbian-firmware libmali-valhall-g610-…`; the
  # mainline track drops the blob because it is ABI-bound to Rockchip's
  # out-of-tree Mali module and its /dev/mali0 node, which a mainline kernel
  # never creates (armbian/build#10320). Worse, libmali ships
  # /etc/ld.so.conf.d/00-aarch64-mali.conf, whose `00-` prefix sorts first and
  # captures libEGL.so.1 / libGLESv2.so.2 / libgbm.so.1 for the WHOLE image — so
  # leaving it here would not degrade GL on a mainline board, it would remove it,
  # with nothing falling back. armbian-firmware stays: it carries the WiFi/BT
  # blobs and the GPU's own CSF firmware, which panthor loads exactly as the
  # vendor driver did.
  [[ "$output" == *"FIRMWARE_PACKAGES='armbian-firmware'"* ]]
  [[ "$output" != *"libmali"* ]]
}

@test "kernel_source: the VENDOR resolve still ships libmali (the edge drop is track-scoped, not a retirement)" {
  # The inverse of the leg above, and the one that proves the change did not leak
  # onto the production path. Retiring the pin outright belongs to the
  # vendor-kernel retirement, not to the GPU-stack flip.
  run bash -c "'$RESOLVE_SH' rock-5b-plus 2>/dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"FIRMWARE_PACKAGES='armbian-firmware libmali-valhall-g610-g24p0-wayland-gbm'"* ]]

  # vendor-patched is still the vendor kernel track, so it keeps the blob too.
  run bash -c "'$RESOLVE_SH' rock-5b-plus --variant vendor-patched 2>/dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"FIRMWARE_PACKAGES='armbian-firmware libmali-valhall-g610-g24p0-wayland-gbm'"* ]]

  # edge-test INHERITS the edge overlay rather than restating it — the whole
  # reason `extends` exists, checked here so a debug build can never drift onto a
  # different GPU stack than the production edge it is a debug build OF.
  run bash -c "'$RESOLVE_SH' rock-5b-plus --variant edge-test 2>/dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"FIRMWARE_PACKAGES='armbian-firmware'"* ]]
  [[ "$output" != *"libmali"* ]]
}

@test "kernel_source: the derived suppression set is pre-overlay UNION post-overlay" {
  # Both halves matter. The pre-overlay vendor names are still in the family
  # file (fetch-debs reads it directly); the post-overlay built name exists in
  # no remote archive. Missing either half means a failed or wrong fetch.
  run bash -c "'$RESOLVE_SH' rock-5b-plus --variant edge 2>/dev/null"
  [ "$status" -eq 0 ]
  local line
  line="$(grep '^KERNEL_SOURCE_SUPPRESSED_PACKAGES=' <<<"$output")"
  [[ "$line" == *"linux-image-vendor-rk35xx"* ]]
  [[ "$line" == *"linux-dtb-vendor-rk35xx"* ]]
  [[ "$line" == *"linux-image-7.2.0-ceralive-rk3588"* ]]
  # U-Boot / firmware must NEVER be suppressed.
  [[ "$line" != *"linux-u-boot"* ]]
  [[ "$line" != *"armbian-firmware"* ]]
}

@test "kernel_source: the pinned patches commit is the next hardware-candidate series tip" {
  # A regression pin on the actual value: the CERALIVE/rk3588-kernel-patches
  # `main` commit the hardware candidates are built from — currently the
  # squash-merge that re-anchored the 22-member series onto the v7.2 base. A
  # silent bump here would change what the kernel contains with no other signal,
  # and would detach the hardware evidence from the series it claims to attest.
  #
  # PIN SHAPE, not just the value: a squash-merge ORPHANS the pre-merge branch
  # head, so this must always be the resulting `main` commit and never a PR-head
  # SHA — a fresh clone cannot reach the latter.
  run bash -c "'$RESOLVE_SH' rock-5b-plus --variant edge 2>/dev/null"
  [ "$status" -eq 0 ]
   [[ "$output" == *"KERNEL_SOURCE_PATCHES_COMMIT='b28a187269f2db993e490278788e348767aa24a8'"* ]]
  [[ "$output" == *"KERNEL_SOURCE_PATCHES_GIT_URL='https://github.com/CERALIVE/rk3588-kernel-patches.git'"* ]]
  [[ "$output" == *"KERNEL_SOURCE_TAG='v7.2'"* ]]
  [[ "$output" == *"KERNEL_SOURCE_COMMIT='8d3ae59288f1e7d58d76558a6ee96d533bc5019f'"* ]]
}

@test "kernel_source: the defconfig fragment the manifest names actually exists" {
  local frag
  frag="$(bash -c "'$RESOLVE_SH' rock-5b-plus --variant edge 2>/dev/null" \
          | sed -n "s/^KERNEL_SOURCE_DEFCONFIG_FRAGMENT='\(.*\)'$/\1/p")"
  [ -n "$frag" ]
  [ -f "$PIPELINE_DIR/$frag" ]
  # The two symbols the whole variant exists for.
  grep -q 'CONFIG_VIDEO_ROCKCHIP_RKVENC=' "$PIPELINE_DIR/$frag"
  grep -q 'CONFIG_VIDEO_SYNOPSYS_HDMIRX=' "$PIPELINE_DIR/$frag"
  # Determinism switch: an auto localversion would change the package NAME.
  grep -q 'CONFIG_LOCALVERSION_AUTO=n' "$PIPELINE_DIR/$frag"
}

# --- vendor-patched: commit-only source + full-config mode -------------------
#
# The vendor BSP differs from `edge` in two STRUCTURAL ways, and both were
# generalizations of build-kernel.sh rather than special cases:
#   Gap A  rk-6.1-rkr5.1 publishes NO tags, so `tag` had to become optional and
#          the checkout had to learn a shallow-fetch-by-SHA shape.
#   Gap B  Armbian ships a COMPLETE .config for this kernel; `make defconfig`
#          would build a materially different driver set, so the config source
#          had to learn "start from a fetched full .config".

@test "vendor-patched: the variant resolves a commit-only source (NO tag) " {
  run bash -c "'$RESOLVE_SH' rock-5b-plus --variant vendor-patched 2>/dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"KERNEL_SOURCE_COMMIT='95e85f6cb496c75807c5b16f158853578e7e7d1b'"* ]]
  # A synthetic tag would misrepresent the source: there is no such ref.
  [[ "$output" != *"KERNEL_SOURCE_TAG="* ]]
}

@test "vendor-patched: the variant resolves the FULL Armbian .config, not a defconfig target" {
  run bash -c "'$RESOLVE_SH' rock-5b-plus --variant vendor-patched 2>/dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"KERNEL_SOURCE_CONFIG_PATH='config/kernel/linux-rk35xx-vendor.config'"* ]]
  [[ "$output" == *"KERNEL_SOURCE_CONFIG_COMMIT='5e2fa21ab509e9cf6afb05f3df46c9bd2b0cfa39'"* ]]
  # Substituting a bare defconfig would silently build a different kernel.
  [[ "$output" != *"KERNEL_SOURCE_DEFCONFIG_BASE="* ]]
  [[ "$output" != *"KERNEL_SOURCE_DEFCONFIG_FRAGMENT="* ]]
}

@test "vendor-patched: the built package name CANNOT collide with the stock vendor kernel" {
  # A collision is the one failure that yields a plausible image instead of an
  # error: the local repo would pick one by version and the board could boot the
  # UNPATCHED kernel. The stock name must also still be suppressed from fetch.
  run bash -c "'$RESOLVE_SH' rock-5b-plus --variant vendor-patched 2>/dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"KERNEL_PACKAGES='linux-image-6.1.115-ceralive-vendor-rk35xx'"* ]]
  [[ "$output" != *"KERNEL_PACKAGES='linux-image-vendor-rk35xx'"* ]]
  local line
  line="$(grep '^KERNEL_SOURCE_SUPPRESSED_PACKAGES=' <<<"$output")"
  [[ "$line" == *"linux-image-vendor-rk35xx"* ]]
  [[ "$line" == *"linux-dtb-vendor-rk35xx"* ]]
}

@test "vendor-patched: the allow-absent list the manifest names actually exists" {
  local rel
  rel="$(bash -c "'$RESOLVE_SH' rock-5b-plus --variant vendor-patched 2>/dev/null" \
         | sed -n "s/^KERNEL_SOURCE_CONFIG_ABSENT_SYMBOLS='\(.*\)'$/\1/p")"
  [ -n "$rel" ]
  [ -f "$PIPELINE_DIR/$rel" ]
}

@test "vendor-patched: the pinned patches commit is an exact 40-hex SHA of the VENDOR repo" {
  run bash -c "'$RESOLVE_SH' rock-5b-plus --variant vendor-patched 2>/dev/null"
  [ "$status" -eq 0 ]
  # The mainline sibling's patches do not apply to this tree and vice versa.
  [[ "$output" == *"KERNEL_SOURCE_PATCHES_GIT_URL='https://github.com/CERALIVE/rk3588-vendor-kernel-patches.git'"* ]]
  local sha
  sha="$(sed -n "s/^KERNEL_SOURCE_PATCHES_COMMIT='\(.*\)'$/\1/p" <<<"$output")"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]]
}

@test "vendor-patched: DRY_RUN plans a fetch-by-SHA checkout and a fetched full .config" {
  serialize build-plan
  run env INSTALL_BOOT_BSP=0 DRY_RUN=1 bash "$PIPELINE_DIR/build" rock-5b-plus --variant vendor-patched
  [ "$status" -eq 0 ]
  [[ "$output" == *"kernel_variant=vendor-patched"* ]]
  [[ "$output" == *"git fetch --depth 1 https://github.com/armbian/linux-rockchip.git 95e85f6cb496c75807c5b16f158853578e7e7d1b"* ]]
  [[ "$output" == *"commit-only source: the pinned branch publishes no tag"* ]]
  [[ "$output" == *"cp config/kernel/linux-rk35xx-vendor.config .config (full config, no defconfig target)"* ]]
  [[ "$output" == *"config-survival gate"* ]]
  [[ "$output" == *"linux-image-6.1.115-ceralive-vendor-rk35xx_6.1.115-ceralive1_arm64.deb"* ]]
  # The plan must not perform anything.
  [[ "$output" != *"docker run"* ]]
}

@test "vendor-patched: selecting it does NOT move the edge variant" {
  run bash -c "'$RESOLVE_SH' rock-5b-plus --variant edge 2>/dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"KERNEL_SOURCE_TAG='v7.2'"* ]]
  [[ "$output" == *"KERNEL_SOURCE_DEFCONFIG_BASE='defconfig'"* ]]
  [[ "$output" == *"KERNEL_PACKAGES='linux-image-7.2.0-ceralive-rk3588'"* ]]
  [[ "$output" == *"BUILDER_IMAGE='debian:trixie-"* ]]
  # edge declares no config-file trio at all.
  [[ "$output" != *"KERNEL_SOURCE_CONFIG_GIT_URL="* ]]
}

@test "bench patch clone: the override is a MIRROR, never a pin override" {
  local src="$LIB_DIR/build-kernel.sh"
  # The clone is read-only and reached over file://, so the container cannot
  # write to the operator's checkout and shallow fetch still works.
  grep -q 'CERALIVE_KERNEL_PATCHES_LOCAL_REPO' "$src"
  grep -q '/in/patches-src:ro' "$src"
  grep -q 'patches_fetch_url="file:///in/patches-src"' "$src"
  # The pin assertion must stay UNCONDITIONAL: this may change where the commit
  # comes from, never which commit is built.
  grep -q 'have_p="\$(git -C /src/patches rev-parse HEAD)"' "$src"
  grep -q 'FATAL: patches repo checked out' "$src"
  # ... and the manifest URL keeps flowing into the log line, so a bench build
  # still says which pin it is standing in for.
  grep -q 'BENCH: patch series fetched from local clone' "$src"
  grep -q 'do NOT use this on a release path' "$src"
}

@test "bench patch clone: safe.directory comes from GIT_CONFIG_GLOBAL, not -c" {
  local src="$LIB_DIR/build-kernel.sh"
  # git honours safe.directory ONLY from system/global config. A -c flag or a
  # GIT_CONFIG_COUNT entry is silently ignored and the fetch dies with
  # "detected dubious ownership", which is a real failure this already hit.
  grep -q 'GIT_CONFIG_GLOBAL=/in/gitconfig' "$src"
  run ! grep -q 'GIT_CONFIG_KEY_0=safe.directory' "$src"
  run ! grep -qE -- '-c[[:space:]]+safe\.directory' "$src"
}

@test "bench patch clone: unset means the manifest URL is used verbatim" {
  local src="$LIB_DIR/build-kernel.sh"
  grep -q 'local patches_fetch_url="\${patches_url}"' "$src"
  # And no shipped manifest may hardcode the bench path.
  run ! grep -rq 'CERALIVE_KERNEL_PATCHES_LOCAL_REPO' "$PIPELINE_DIR/manifests"
}

@test "bench patch clone: a relative path or a non-git dir is refused" {
  run env DRY_RUN=0 CERALIVE_KERNEL_PATCHES_LOCAL_REPO=relative/path \
    ARCH=arm64 DTB_NAME=x.dtb KERNEL_PACKAGES=linux-image-x \
    KERNEL_SOURCE_GIT_URL=https://example.invalid/linux.git \
    KERNEL_SOURCE_COMMIT=c7ba9d6de43e9d9bd755b1f3c19501a38898c6b6 \
    KERNEL_SOURCE_PATCHES_GIT_URL=https://example.invalid/patches.git \
    KERNEL_SOURCE_PATCHES_COMMIT=acb519c101fefa31f51300779f3a139bcabf6a1c \
    KERNEL_SOURCE_PATCHES_SERIES=patches/series \
    KERNEL_SOURCE_DEFCONFIG_BASE=defconfig \
    KERNEL_SOURCE_DEFCONFIG_FRAGMENT=manifests/kernel/rk3588-edge.fragment \
    KERNEL_SOURCE_BUILDER_IMAGE='debian:trixie-slim@sha256:28de0877c2189802884ccd20f15ee41c203573bd87bb6b883f5f46362d24c5c2' \
    KERNEL_SOURCE_LOCAL_VERSION=-x KERNEL_SOURCE_KERNEL_RELEASE=1.0-x \
    KERNEL_SOURCE_PACKAGE_VERSION=1.0-x1 \
    KERNEL_SOURCE_DTB_DEB_DIR=/usr/lib/linux-image-x/rockchip \
    bash "$LIB_DIR/build-kernel.sh" --board rock-5b-plus --out "$BATS_TEST_TMPDIR/kobench"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CERALIVE_KERNEL_PATCHES_LOCAL_REPO"* ]]
}

@test "build-kernel: a half-declared config-file mode is refused before anything runs" {
  run env DRY_RUN=1 \
    ARCH=arm64 DTB_NAME=x.dtb KERNEL_PACKAGES=linux-image-x \
    KERNEL_SOURCE_GIT_URL=https://example.invalid/linux.git \
    KERNEL_SOURCE_COMMIT=c7ba9d6de43e9d9bd755b1f3c19501a38898c6b6 \
    KERNEL_SOURCE_PATCHES_GIT_URL=https://example.invalid/patches.git \
    KERNEL_SOURCE_PATCHES_COMMIT=acb519c101fefa31f51300779f3a139bcabf6a1c \
    KERNEL_SOURCE_PATCHES_SERIES=patches/series \
    KERNEL_SOURCE_CONFIG_GIT_URL=https://example.invalid/build.git \
    KERNEL_SOURCE_BUILDER_IMAGE='debian:trixie-slim@sha256:28de0877c2189802884ccd20f15ee41c203573bd87bb6b883f5f46362d24c5c2' \
    KERNEL_SOURCE_LOCAL_VERSION=-x KERNEL_SOURCE_KERNEL_RELEASE=1.0-x \
    KERNEL_SOURCE_PACKAGE_VERSION=1.0-x1 \
    KERNEL_SOURCE_DTB_DEB_DIR=/usr/lib/linux-image-x/rockchip \
    bash "$LIB_DIR/build-kernel.sh" --board rock-5b-plus --out "$BATS_TEST_TMPDIR/ko3"
  [ "$status" -ne 0 ]
  [[ "$output" == *"config_commit"* ]]
}

@test "build-kernel: declaring BOTH config modes is refused" {
  run env DRY_RUN=1 \
    ARCH=arm64 DTB_NAME=x.dtb KERNEL_PACKAGES=linux-image-x \
    KERNEL_SOURCE_GIT_URL=https://example.invalid/linux.git \
    KERNEL_SOURCE_COMMIT=c7ba9d6de43e9d9bd755b1f3c19501a38898c6b6 \
    KERNEL_SOURCE_PATCHES_GIT_URL=https://example.invalid/patches.git \
    KERNEL_SOURCE_PATCHES_COMMIT=acb519c101fefa31f51300779f3a139bcabf6a1c \
    KERNEL_SOURCE_PATCHES_SERIES=patches/series \
    KERNEL_SOURCE_CONFIG_GIT_URL=https://example.invalid/build.git \
    KERNEL_SOURCE_CONFIG_COMMIT=5e2fa21ab509e9cf6afb05f3df46c9bd2b0cfa39 \
    KERNEL_SOURCE_CONFIG_PATH=config/kernel/x.config \
    KERNEL_SOURCE_DEFCONFIG_BASE=defconfig \
    KERNEL_SOURCE_DEFCONFIG_FRAGMENT=manifests/kernel/rk3588-edge.fragment \
    KERNEL_SOURCE_BUILDER_IMAGE='debian:trixie-slim@sha256:28de0877c2189802884ccd20f15ee41c203573bd87bb6b883f5f46362d24c5c2' \
    KERNEL_SOURCE_LOCAL_VERSION=-x KERNEL_SOURCE_KERNEL_RELEASE=1.0-x \
    KERNEL_SOURCE_PACKAGE_VERSION=1.0-x1 \
    KERNEL_SOURCE_DTB_DEB_DIR=/usr/lib/linux-image-x/rockchip \
    bash "$LIB_DIR/build-kernel.sh" --board rock-5b-plus --out "$BATS_TEST_TMPDIR/ko4"
  [ "$status" -ne 0 ]
  [[ "$output" == *"exactly one config source"* ]]
}

@test "build-kernel: a floating config_commit is refused before anything runs" {
  run env DRY_RUN=1 \
    ARCH=arm64 DTB_NAME=x.dtb KERNEL_PACKAGES=linux-image-x \
    KERNEL_SOURCE_GIT_URL=https://example.invalid/linux.git \
    KERNEL_SOURCE_COMMIT=c7ba9d6de43e9d9bd755b1f3c19501a38898c6b6 \
    KERNEL_SOURCE_PATCHES_GIT_URL=https://example.invalid/patches.git \
    KERNEL_SOURCE_PATCHES_COMMIT=acb519c101fefa31f51300779f3a139bcabf6a1c \
    KERNEL_SOURCE_PATCHES_SERIES=patches/series \
    KERNEL_SOURCE_CONFIG_GIT_URL=https://example.invalid/build.git \
    KERNEL_SOURCE_CONFIG_COMMIT=main \
    KERNEL_SOURCE_CONFIG_PATH=config/kernel/x.config \
    KERNEL_SOURCE_BUILDER_IMAGE='debian:trixie-slim@sha256:28de0877c2189802884ccd20f15ee41c203573bd87bb6b883f5f46362d24c5c2' \
    KERNEL_SOURCE_LOCAL_VERSION=-x KERNEL_SOURCE_KERNEL_RELEASE=1.0-x \
    KERNEL_SOURCE_PACKAGE_VERSION=1.0-x1 \
    KERNEL_SOURCE_DTB_DEB_DIR=/usr/lib/linux-image-x/rockchip \
    bash "$LIB_DIR/build-kernel.sh" --board rock-5b-plus --out "$BATS_TEST_TMPDIR/ko5"
  [ "$status" -ne 0 ]
  [[ "$output" == *"never a branch or tag"* ]]
}

@test "kernel_source schema: tag is OPTIONAL, but a half config-file mode is rejected" {
  local f="$BATS_TEST_TMPDIR/commit-only.yaml"
  # No tag + full config-file mode: the vendor-patched shape. Must VALIDATE.
  # The `edge:` stub is required because this fixture family is merged against
  # the REAL rock-5b-plus board, whose variant_overrides names edge — and an
  # override for a variant the family does not declare is fatal on every
  # resolve, by design (it would otherwise sit there looking effective).
  write_variant_family "$f" "  edge:
    armbian_branch: edge
  vendor-patched:
    kernel_source:
      git_url: https://example.invalid/linux.git
      commit: c7ba9d6de43e9d9bd755b1f3c19501a38898c6b6
      patches_git_url: https://example.invalid/p.git
      patches_commit: acb519c101fefa31f51300779f3a139bcabf6a1c
      patches_series: patches/series
      config_git_url: https://example.invalid/build.git
      config_commit: 5e2fa21ab509e9cf6afb05f3df46c9bd2b0cfa39
      config_path: config/kernel/x.config
      builder_image: debian:trixie-slim@sha256:28de0877c2189802884ccd20f15ee41c203573bd87bb6b883f5f46362d24c5c2
      local_version: -x
      kernel_release: 1.0-x
      package_version: 1.0-x1
      dtb_deb_dir: /usr/lib/linux-image-x/rockchip
      dtb_boot_dir: /boot/dtb/rockchip"
  run python3 "$RESOLVE_PY" merge --family "$f" --board "$PIPELINE_DIR/manifests/boards/rock-5b-plus.yaml" \
    --family-schema "$PIPELINE_DIR/manifests/schema/family.schema.json" --variant vendor-patched
  [ "$status" -eq 0 ]

  # Drop config_path -> neither mode is fully declared -> rejected.
  local g="$BATS_TEST_TMPDIR/half-config.yaml"
  sed '/config_path:/d' "$f" >"$g"
  run python3 "$RESOLVE_PY" merge --family "$g" --board "$PIPELINE_DIR/manifests/boards/rock-5b-plus.yaml" \
    --family-schema "$PIPELINE_DIR/manifests/schema/family.schema.json" --variant vendor-patched
  [ "$status" -ne 0 ]
}

@test "fetch suppression: suppressed kernel/DTB names leave the declared BSP set" {
  # The built-kernel name here is an ENV-DRIVEN STUB, not the shipped pin: the
  # subject is `collect_declared_bsp_pkgs`' set arithmetic, which is indifferent
  # to the string. It is deliberately left at the older release so a reader
  # cannot mistake it for an assertion about the current manifest — the legs that
  # DO assert that run the real resolver.
  run bash -c "
    set -euo pipefail
    export CERALIVE_KERNEL_SOURCE_SUPPRESSED_PKGS='linux-image-vendor-rk35xx linux-dtb-vendor-rk35xx linux-image-7.1.7-ceralive-rk3588'
    export KERNEL_PACKAGES='linux-image-7.1.7-ceralive-rk3588'
    export DTB_PACKAGES=''
    source '$FETCH_DEBS'
    collect_declared_bsp_pkgs '$PIPELINE_DIR/manifests/families/rk3588.yaml'
  "
  [ "$status" -eq 0 ]
  [[ "$output" != *"linux-image-vendor-rk35xx"* ]]
  [[ "$output" != *"linux-dtb-vendor-rk35xx"* ]]
  [[ "$output" != *"linux-image-7.1.7-ceralive-rk3588"* ]]
  # Everything else the family declares is untouched.
  [[ "$output" == *"armbian-firmware"* ]]
  [[ "$output" == *"gstreamer1.0-rockchip1"* ]]
}

@test "fetch suppression: NON-VACUOUS — without it the vendor names are still declared" {
  run bash -c "
    set -euo pipefail
    unset CERALIVE_KERNEL_SOURCE_SUPPRESSED_PKGS KERNEL_PACKAGES DTB_PACKAGES
    source '$FETCH_DEBS'
    collect_declared_bsp_pkgs '$PIPELINE_DIR/manifests/families/rk3588.yaml'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"linux-image-vendor-rk35xx"* ]]
  [[ "$output" == *"linux-dtb-vendor-rk35xx"* ]]
}

@test "orchestrate: an edge DRY_RUN reaches the plan for BOTH rk3588 boards" {
  serialize build-plan
  local board
  for board in rock-5b-plus orange-pi-5-plus; do
    run env INSTALL_BOOT_BSP=0 DRY_RUN=1 bash "$PIPELINE_DIR/build" "$board" --variant edge
    [ "$status" -eq 0 ]
    [[ "$output" == *"kernel_variant=edge"* ]]
    [[ "$output" == *"DRY-RUN complete: board='${board}'"* ]]
    # The Armbian BSP set no longer contains the kernel or the DTB package …
    [[ "$output" != *"BSP set from rk3588.yaml (4 pkgs)"* ]]
    [[ "$output" == *"BSP set from rk3588.yaml (2 pkgs)"* ]]
    # … but U-Boot and firmware are still fetched.
    [[ "$output" == *"armbian-firmware"* ]]
    [[ "$output" == *"linux-u-boot-"* ]]
    # The kernel-build stage ran and emitted its plan.
    [[ "$output" == *"[2b/9] building kernel from pinned source"* ]]
    [[ "$output" == *"kernel-build plan emitted"* ]]
  done
}

@test "orchestrate: NON-VACUOUS — the vendor DRY_RUN still fetches kernel + DTB" {
  serialize build-plan
  run env INSTALL_BOOT_BSP=0 DRY_RUN=1 bash "$PIPELINE_DIR/build" rock-5b-plus
  [ "$status" -eq 0 ]
  [[ "$output" == *"BSP set from rk3588.yaml (4 pkgs)"* ]]
  [[ "$output" == *"linux-image-vendor-rk35xx"* ]]
  [[ "$output" == *"linux-dtb-vendor-rk35xx"* ]]
  # Production builds only the ABI-bound extension; they never rebuild the kernel.
  [[ "$output" == *"[2b/9] building kernel extension(s) for the prebuilt vendor kernel"* ]]
  [[ "$output" != *"building kernel from pinned source"* ]]
}

@test "orchestrate: x86 DRY_RUN is unaffected by the variant machinery" {
  serialize build-plan
  run env INSTALL_BOOT_BSP=0 DRY_RUN=1 bash "$PIPELINE_DIR/build" x86-minipc
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN complete"* ]]
  [[ "$output" == *"kernel_variant=default"* ]]
  [[ "$output" != *"[2b/9]"* ]]
  [[ "$output" != *"kernel from source"* ]]
  [[ "$output" == *"non-Armbian family: BSP fetch omitted from DRY_RUN plan"* ]]
}

@test "orchestrate: a fetched AND built candidate for one name FAILS the build" {
  # The uniqueness check is the backstop for suppression. Two candidates for one
  # name would let mkosi's local repository pick a kernel nobody chose — a
  # plausible-looking image instead of an error, the worst outcome available.
  local fetched="$BATS_TEST_TMPDIR/uniq/debs" built="$BATS_TEST_TMPDIR/uniq/kernel"
  mkdir -p "$fetched" "$built"
  make_stub_deb "$fetched/linux-image-collide_1_arm64.deb" linux-image-collide 1 arm64
  make_stub_deb "$built/linux-image-collide_2_arm64.deb"   linux-image-collide 2 arm64

  run bash -c "
    set -euo pipefail
    ORCH='$LIB_DIR/stages/partition.sh'
    DEBLIB='$LIB_DIR/shared/deb-lib.sh'
    # Lift the orchestrator's function bodies without running main(). deb_pkg_name
    # lives in the shared deb library, so the static read must cover BOTH files.
    eval \"\$(sed -n '/^deb_pkg_name()/,/^}/p;/^deb_control_field()/,/^}/p' \"\$DEBLIB\"; sed -n '/^assert_staged_packages_unique()/,/^}/p' \"\$ORCH\")\"
    log_error() { printf 'ERROR %s\n' \"\$*\" >&2; }
    log_success() { printf 'OK %s\n' \"\$*\" >&2; }
    die() { printf 'DIE %s\n' \"\$*\" >&2; exit 1; }
    assert_staged_packages_unique '$fetched' '$built' 2>&1
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"linux-image-collide"* ]]
  [[ "$output" == *"DIE"* ]]
}

@test "orchestrate: distinct fetched and built package names PASS the uniqueness check" {
  local fetched="$BATS_TEST_TMPDIR/uniq2/debs" built="$BATS_TEST_TMPDIR/uniq2/kernel"
  mkdir -p "$fetched" "$built"
  make_stub_deb "$fetched/armbian-firmware_1_all.deb" armbian-firmware 1 all
  make_stub_deb "$built/linux-image-built_2_arm64.deb" linux-image-built 2 arm64

  run bash -c "
    set -euo pipefail
    ORCH='$LIB_DIR/stages/partition.sh'
    DEBLIB='$LIB_DIR/shared/deb-lib.sh'
    eval \"\$(sed -n '/^deb_pkg_name()/,/^}/p;/^deb_control_field()/,/^}/p' \"\$DEBLIB\"; sed -n '/^assert_staged_packages_unique()/,/^}/p' \"\$ORCH\")\"
    log_error() { printf 'ERROR %s\n' \"\$*\" >&2; }
    log_success() { printf 'OK %s\n' \"\$*\" >&2; }
    die() { printf 'DIE %s\n' \"\$*\" >&2; exit 1; }
    assert_staged_packages_unique '$fetched' '$built' 2>&1
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"uniqueness verified"* ]]
}

@test "build-kernel: a non-40-hex patches pin is refused before anything runs" {
  run env DRY_RUN=1 \
    ARCH=arm64 DTB_NAME=rk3588-rock-5b-plus.dtb \
    KERNEL_PACKAGES=linux-image-7.1.7-ceralive-rk3588 \
    KERNEL_SOURCE_GIT_URL=https://example.invalid/linux.git \
    KERNEL_SOURCE_TAG=v7.1.7 \
    KERNEL_SOURCE_COMMIT=c7ba9d6de43e9d9bd755b1f3c19501a38898c6b6 \
    KERNEL_SOURCE_PATCHES_GIT_URL=https://example.invalid/patches.git \
    KERNEL_SOURCE_PATCHES_COMMIT=main \
    KERNEL_SOURCE_PATCHES_SERIES=patches/series \
    KERNEL_SOURCE_DEFCONFIG_BASE=defconfig \
    KERNEL_SOURCE_DEFCONFIG_FRAGMENT=manifests/kernel/rk3588-edge.fragment \
    KERNEL_SOURCE_BUILDER_IMAGE='debian:trixie-slim@sha256:28de0877c2189802884ccd20f15ee41c203573bd87bb6b883f5f46362d24c5c2' \
    KERNEL_SOURCE_LOCAL_VERSION=-ceralive-rk3588 \
    KERNEL_SOURCE_KERNEL_RELEASE=7.1.7-ceralive-rk3588 \
    KERNEL_SOURCE_PACKAGE_VERSION=7.1.7-ceralive1 \
    KERNEL_SOURCE_DTB_DEB_DIR=/usr/lib/linux-image-7.1.7-ceralive-rk3588/rockchip \
    bash "$LIB_DIR/build-kernel.sh" --board rock-5b-plus --out "$BATS_TEST_TMPDIR/ko"
  [ "$status" -ne 0 ]
  [[ "$output" == *"patches_commit"* ]]
  [[ "$output" == *"never a branch"* ]]
}

@test "build-kernel: a half-specified pin is refused (no partial kernel build)" {
  run env DRY_RUN=1 ARCH=arm64 DTB_NAME=x.dtb KERNEL_PACKAGES=linux-image-x \
    KERNEL_SOURCE_GIT_URL=https://example.invalid/linux.git \
    bash "$LIB_DIR/build-kernel.sh" --board rock-5b-plus --out "$BATS_TEST_TMPDIR/ko2"
  [ "$status" -ne 0 ]
  [[ "$output" == *"half-specified pin"* ]]
}

@test "build-kernel: the DRY_RUN plan names every pinned coordinate" {
  serialize build-plan
  run env INSTALL_BOOT_BSP=0 DRY_RUN=1 bash "$PIPELINE_DIR/build" rock-5b-plus --variant edge
  [ "$status" -eq 0 ]
  [[ "$output" == *"git clone --branch v7.2"* ]]
  [[ "$output" == *"git rev-parse HEAD == 8d3ae59288f1e7d58d76558a6ee96d533bc5019f"* ]]
   [[ "$output" == *"b28a187269f2db993e490278788e348767aa24a8"* ]]
  [[ "$output" == *"BASE_IMAGE=debian:trixie-20260623-slim@sha256:"* ]]
  [[ "$output" == *"bindeb-pkg"* ]]
  [[ "$output" == *"linux-headers-*/linux-libc-dev discarded"* ]]
  # The plan must not perform anything.
  [[ "$output" != *"docker run"* ]]
}

@test "build-kernel: ccache is wired (a rebuild must not be a cold kernel build)" {
  grep -q 'CCACHE_DIR' "$PIPELINE_DIR/ci/Dockerfile.kernel"
  grep -q '/usr/lib/ccache/aarch64-linux-gnu-gcc' "$PIPELINE_DIR/ci/Dockerfile.kernel"
  grep -q -- '-v "${ccache_dir}:/ccache"' "$LIB_DIR/build-kernel.sh"
}

@test "build-kernel: syncconfig refreshes auto.conf between olddefconfig and the kernelrelease assertion" {
  # `make kernelrelease` is in the kernel no-sync-config-targets list, so it skips
  # syncconfig and reads include/config/auto.conf as written by `make defconfig` —
  # still CONFIG_LOCALVERSION_AUTO=y. setlocalversion reads auto.conf, NOT .config,
  # so without an explicit syncconfig the fragment override never takes effect and
  # the assertion below rejects a git-describe-suffixed release on EVERY build, on
  # every board. Only a real (non-DRY_RUN) build executes that container script, so
  # this ordering is asserted statically.
  local script="$LIB_DIR/build-kernel.sh"
  local olddefconfig syncconfig release_assert

  olddefconfig="$(grep -n '^ *make olddefconfig$' "$script" | cut -d: -f1)"
  syncconfig="$(grep -n '^ *make syncconfig$' "$script" | cut -d: -f1)"
  release_assert="$(grep -n 'make -s kernelrelease' "$script" | cut -d: -f1)"

  [ "$(printf '%s\n' "$olddefconfig" | wc -l)" -eq 1 ]
  [ "$(printf '%s\n' "$syncconfig" | wc -l)" -eq 1 ]
  [ "$(printf '%s\n' "$release_assert" | wc -l)" -eq 1 ]

  (( olddefconfig < syncconfig )) \
    || { echo "make syncconfig must come AFTER make olddefconfig"; false; }
  (( syncconfig < release_assert )) \
    || { echo "make syncconfig must come BEFORE the kernelrelease assertion"; false; }
}

@test "build-kernel: the kernelrelease assertion stays an EXACT match (never relaxed to a prefix)" {
  # The assertion is the only thing between this pipeline and a non-deterministic
  # kernel package name: `git am` restamps committer dates, so an AUTO release
  # string embeds a different SHA on every run. Relaxing it is not a valid fix for
  # a stale auto.conf.
  local script="$LIB_DIR/build-kernel.sh"
  grep -Fq 'if [ "${release}" != "${KERNEL_RELEASE}" ]; then' "$script"
  run grep -Eq '\$\{release#|\$\{release\*|release. == .\$\{KERNEL_RELEASE\}\*' "$script"
  [ "$status" -ne 0 ]
}

@test "build-kernel: deb_lists_path finds a present path in a LARGE deb (no pipefail/SIGPIPE false negative)" {
  # Regression: `tar -t | grep -Fqx` under `set -o pipefail` reports FAILURE when
  # the path IS present — grep exits at the first match and tar dies of SIGPIPE.
  # It only misfires once the listing outgrows the pipe buffer, so a tiny fixture
  # passes and a real kernel deb (thousands of DTBs and modules) never does.
  local script="$BATS_TEST_TMPDIR/build-kernel-sources.sh"
  write_build_kernel_source_set "$script"
  local deb="$BATS_TEST_TMPDIR/big.deb" stage="$BATS_TEST_TMPDIR/stage"
  local want='/usr/lib/linux-image-x/rockchip/rk3588-rock-5b-plus.dtb'

  mkdir -p "$stage/usr/lib/linux-image-x/rockchip"
  printf 'dtb\n' >"$stage$want"
  local i
  for i in $(seq 1 6000); do printf 'm\n' >"$stage/usr/lib/linux-image-x/rockchip/pad-$i.dtb"; done
  tar -C "$stage" -czf "$BATS_TEST_TMPDIR/data.tar.gz" .
  printf '2.0\n' >"$BATS_TEST_TMPDIR/debian-binary"
  mkdir -p "$BATS_TEST_TMPDIR/ctl"
  printf 'Package: linux-image-x\nVersion: 1\nArchitecture: arm64\n' >"$BATS_TEST_TMPDIR/ctl/control"
  tar -C "$BATS_TEST_TMPDIR/ctl" -czf "$BATS_TEST_TMPDIR/control.tar.gz" ./control
  ( cd "$BATS_TEST_TMPDIR" && ar rc "$deb" debian-binary control.tar.gz data.tar.gz )

  run bash -c "
    set -euo pipefail
    $(sed -n '/^deb_data_list()/,/^}/p;/^deb_lists_path()/,/^}/p' "$script")
    deb_lists_path '$deb' '$want' && echo PRESENT
    deb_lists_path '$deb' '/usr/lib/linux-image-x/rockchip/absent.dtb' && echo BUG-FALSE-POSITIVE
    echo DONE
  "
  [[ "$output" == *"PRESENT"* ]]
  [[ "$output" != *"BUG-FALSE-POSITIVE"* ]]
}

@test "build-kernel: the builder image satisfies the CROSS build-deps dpkg-checkbuilddeps demands" {
  # bindeb-pkg runs dpkg-buildpackage -a arm64, so the kernel Build-Depends-Arch
  # resolves `libssl-dev:native` against amd64 and a bare `libssl-dev` against the
  # arm64 HOST arch. Installing only the amd64 one aborts the package build at
  # dpkg-checkbuilddeps, before any compilation — invisible to a DRY_RUN gate.
  local df="$PIPELINE_DIR/ci/Dockerfile.kernel"
  grep -Eq '^RUN dpkg --add-architecture arm64' "$df"
  grep -Eq '^ +libssl-dev \\$' "$df"
  grep -Eq '^ +libssl-dev:arm64 \\$' "$df"
  grep -Eq '^ +libdw-dev \\$' "$df"
  grep -Eq '^ +libelf-dev \\$' "$df"
  # install-extmod-build rebuilds the headers package host tools with the CROSS
  # gcc, which resolves libc only via /usr/include/aarch64-linux-gnu.
  grep -Eq '^ +libc6-dev:arm64 \\$' "$df"
}

@test "build-kernel: the builder image tag is content-addressed (an edited Dockerfile invalidates it)" {
  # ensure_kernel_builder_image skips `docker build` when the tag already exists,
  # so a constant tag would pin every host to whatever layers it first built.
  local script="$BATS_TEST_TMPDIR/build-kernel-sources.sh"
  write_build_kernel_source_set "$script"
  local base='debian:trixie-20260623-slim@sha256:28de0877c2189802884ccd20f15ee41c203573bd87bb6b883f5f46362d24c5c2'
  local tag_a tag_b tag_edited edited

  tag_a="$(bash -c "KERNEL_BUILDER_DOCKERFILE='$PIPELINE_DIR/ci/Dockerfile.kernel'; \
    $(sed -n '/^resolve_kernel_builder_tag()/,/^}/p' "$script"); \
    resolve_kernel_builder_tag '$base'")"
  [[ "$tag_a" == ceralive-kernel-builder:* ]]

  tag_b="$(bash -c "KERNEL_BUILDER_DOCKERFILE='$PIPELINE_DIR/ci/Dockerfile.kernel'; \
    $(sed -n '/^resolve_kernel_builder_tag()/,/^}/p' "$script"); \
    resolve_kernel_builder_tag '$base'")"
  [ "$tag_a" = "$tag_b" ]

  # A different builder_image pin must yield a different tag.
  tag_b="$(bash -c "KERNEL_BUILDER_DOCKERFILE='$PIPELINE_DIR/ci/Dockerfile.kernel'; \
    $(sed -n '/^resolve_kernel_builder_tag()/,/^}/p' "$script"); \
    resolve_kernel_builder_tag 'debian:trixie-slim@sha256:0000000000000000000000000000000000000000000000000000000000000000'")"
  [ "$tag_a" != "$tag_b" ]

  # An edited Dockerfile must yield a different tag.
  edited="$BATS_TEST_TMPDIR/Dockerfile.kernel"
  { cat "$PIPELINE_DIR/ci/Dockerfile.kernel"; echo '# drift'; } >"$edited"
  tag_edited="$(bash -c "KERNEL_BUILDER_DOCKERFILE='$edited'; \
    $(sed -n '/^resolve_kernel_builder_tag()/,/^}/p' "$script"); \
    resolve_kernel_builder_tag '$base'")"
  [ "$tag_a" != "$tag_edited" ]

  # An operator override is still used verbatim.
  tag_b="$(bash -c "KERNEL_BUILDER_DOCKERFILE='$PIPELINE_DIR/ci/Dockerfile.kernel'; \
    CERALIVE_KERNEL_BUILDER_IMAGE=myregistry/kbuilder:9; \
    $(sed -n '/^resolve_kernel_builder_tag()/,/^}/p' "$script"); \
    resolve_kernel_builder_tag '$base'")"
  [ "$tag_b" = "myregistry/kbuilder:9" ]
}

@test "build-kernel: the builder base image is the MANIFEST pin, not a Dockerfile default" {
  # A FROM with a baked default would let the manifest's builder_image drift
  # into decoration. ARG BASE_IMAGE with no default makes the manifest load-bearing.
  grep -Eq '^ARG BASE_IMAGE$' "$PIPELINE_DIR/ci/Dockerfile.kernel"
  grep -Eq '^FROM \$\{BASE_IMAGE\}$' "$PIPELINE_DIR/ci/Dockerfile.kernel"
  run grep -Eq '^ARG BASE_IMAGE=' "$PIPELINE_DIR/ci/Dockerfile.kernel"
  [ "$status" -ne 0 ]
}

@test "platform DTB mapping: no-op with an empty mapping, fail-loud when half-specified" {
  local postinst="$PIPELINE_DIR/mkosi/mkosi.images/platform/mkosi.postinst"
  local fn
  fn="$(sed -n '/^install_kernel_source_dtbs()/,/^}/p' "$postinst")"
  [ -n "$fn" ]

  # Empty mapping (the production vendor path) -> clean no-op.
  run bash -c "
    set -euo pipefail
    log() { printf '[platform] %s\n' \"\$*\" >&2; }
    BUILDROOT='$BATS_TEST_TMPDIR/pr'; mkdir -p \"\$BUILDROOT\"
    KERNEL_SOURCE_DTB_DEB_DIR='' KERNEL_SOURCE_DTB_BOOT_DIR=''
    $fn
    install_kernel_source_dtbs
    echo NOOP-OK
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOOP-OK"* ]]

  # Half-specified -> fatal (a silent skip here ships a DTB-less image).
  run bash -c "
    set -euo pipefail
    log() { printf '[platform] %s\n' \"\$*\" >&2; }
    BUILDROOT='$BATS_TEST_TMPDIR/pr2'; mkdir -p \"\$BUILDROOT\"
    KERNEL_SOURCE_DTB_DEB_DIR='/usr/lib/linux-image-x/rockchip' KERNEL_SOURCE_DTB_BOOT_DIR=''
    $fn
    install_kernel_source_dtbs
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"half-specified"* ]]
}

@test "platform DTB mapping: copies the board DTB where the boot script looks" {
  local postinst="$PIPELINE_DIR/mkosi/mkosi.images/platform/mkosi.postinst"
  local fn
  # The whole SET, not just the entry: install_kernel_source_dtbs calls
  # prune_dtb_dir, and lifting the caller alone yields a function that dies on an
  # undefined helper. Same rule the postinst.d and orchestrate.sh splits already
  # record — a static test that reads by TEXT must read every function it runs.
  fn="$(sed -n '/^prune_dtb_dir()/,/^}/p;/^install_kernel_source_dtbs()/,/^}/p' "$postinst")"
  local root="$BATS_TEST_TMPDIR/dtbroot"
  mkdir -p "$root/usr/lib/linux-image-7.1.7-ceralive-rk3588/rockchip"
  printf 'dtb\n' > "$root/usr/lib/linux-image-7.1.7-ceralive-rk3588/rockchip/rk3588-rock-5b-plus.dtb"

  run bash -c "
    set -euo pipefail
    log() { printf '[platform] %s\n' \"\$*\" >&2; }
    BUILDROOT='$root'
    KERNEL_SOURCE_DTB_DEB_DIR='/usr/lib/linux-image-7.1.7-ceralive-rk3588/rockchip'
    KERNEL_SOURCE_DTB_BOOT_DIR='/boot/dtb/rockchip'
    DTB_NAME='rk3588-rock-5b-plus.dtb'
    $fn
    install_kernel_source_dtbs
  "
  [ "$status" -eq 0 ]
  # /boot/dtb/rockchip/\${fdtfile} is exactly what boot.scr.cmd resolves.
  [ -f "$root/boot/dtb/rockchip/rk3588-rock-5b-plus.dtb" ]

  # And it is fail-loud when the board's own DTB is missing from the package —
  # mainline and the Armbian vendor BSP do not always agree on RK3588 DTB names.
  run bash -c "
    set -euo pipefail
    log() { printf '[platform] %s\n' \"\$*\" >&2; }
    BUILDROOT='$root'
    KERNEL_SOURCE_DTB_DEB_DIR='/usr/lib/linux-image-7.1.7-ceralive-rk3588/rockchip'
    KERNEL_SOURCE_DTB_BOOT_DIR='/boot/dtb/rockchip'
    DTB_NAME='rk3588s-orangepi-5b.dtb'
    $fn
    install_kernel_source_dtbs
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"rk3588s-orangepi-5b.dtb"* ]]
}

@test "build: --variant is refused for a multi-board selection" {
  run bash "$PIPELINE_DIR/build" --only rock-5b-plus,x86-minipc --variant edge
  [ "$status" -ne 0 ]
  [[ "$output" == *"single-board only"* ]]
}

@test "build: --variant with no value is refused" {
  run bash "$PIPELINE_DIR/build" rock-5b-plus --variant
  [ "$status" -ne 0 ]
  [[ "$output" == *"--variant requires a name"* ]]
}
