#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
#
# bootloader-variant.bats — per-variant bootloader selection (todo 12).
#
# THREE coordinated halves, and the whole point is that they cannot drift apart:
#
#   (A) the board schema admits `uboot_packages` inside a variant override and
#       STILL refuses anything else,
#   (B) the resolver makes a board's `variant_overrides.<v>.uboot_packages` win
#       over its top-level one, family -> variant -> board order intact, while
#       the production vendor path stays BYTE-IDENTICAL to its golden fixtures,
#   (C) lib/write-bootloader.sh selects blobs on the SAME board x variant tuple,
#       refuses an unmapped one, and proves what it wrote by reading it back and
#       hashing it against a committed SHA-256.
#
# The load-bearing property is negative, exactly as it is for `variants:` itself:
# giving the edge track its own U-Boot must not move the production path by a
# byte. That is pinned against the committed vendor-baseline fixtures AND with an
# explicit non-vacuity leg, because a golden comparison that silently compares
# nothing is worse than no comparison at all.
#
# Run:  run-tests              (CI entrypoint)
#   or: bats tests/bootloader-variant.bats

load manifest-helpers

WRITER() { printf '%s' "$LIB_DIR/write-bootloader.sh"; }
BLOB_MAP() { printf '%s' "$PIPELINE_DIR/manifests/bootloader-blobs.tsv"; }
BSP_PINS() { printf '%s' "$PIPELINE_DIR/manifests/armbian-bsp-deb-versions.txt"; }

# The two boards that reach the RK3588 raw-gap writer, with the exact package
# todo 1's feasibility gate pinned for each on the edge track.
EDGE_PIN_rock_5b_plus='linux-u-boot-rock-5b-plus-edge'
EDGE_PIN_orange_pi_5_plus='linux-u-boot-orangepi5-plus-edge'

# ---------------------------------------------------------------------------
# Writer fixtures. The real blobs are 9-10 MB payloads inside signed Armbian
# .debs and are not committed anywhere, so the writer legs run against a
# test-local map + synthetic blobs via --blob-map. That keeps the assertions
# about the WRITER'S LOGIC (tuple selection, identity, readback, refusal) rather
# than about a payload the test would have to ship. The committed map is
# exercised separately, by the structural legs.
#
# A blob must begin with the Rockchip idblock magic or assert_rkns — deliberately
# retained and unweakened — fails the happy path for the wrong reason.
# ---------------------------------------------------------------------------
make_blob() {
  local path="$1" filler="$2" size="${3:-4096}"
  printf 'RKNS' >"$path"
  head -c "$(( size - 4 ))" /dev/zero | tr '\0' "$filler" >>"$path"
}

sha_of() { sha256sum "$1" | awk '{print $1}'; }

# A 16 MB + 1 MB image: big enough that a gap write can never reach p1.
make_image() {
  local img="$1"
  head -c $(( 17 * 1024 * 1024 )) /dev/zero >"$img"
}

# ===========================================================================
# (A) SCHEMA — widened by exactly one key, and still closed.
# ===========================================================================

@test "schema: a variant override MAY carry uboot_packages" {
  local f="$BATS_TEST_TMPDIR/ovr-uboot.yaml"
  write_override_board "$f" "  edge:
    uboot_packages:
      - linux-u-boot-fixture-edge"
  run validate_manifest "$f" "$BOARD_SCHEMA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"VALID"* ]]
}

@test "schema: a variant override MAY carry dtb_name and uboot_packages together" {
  local f="$BATS_TEST_TMPDIR/ovr-both.yaml"
  write_override_board "$f" "  edge:
    dtb_name: rk3588-fixture-mainline.dtb
    uboot_packages:
      - linux-u-boot-fixture-edge"
  run validate_manifest "$f" "$BOARD_SCHEMA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"VALID"* ]]
}

@test "schema: the widening did NOT become additionalProperties:true" {
  # THE regression this file exists to prevent. Adding one permitted key must
  # not turn a deliberately narrow override into a general escape hatch, so an
  # unknown key is still refused — checked with a key that is a REAL board
  # field, which is the plausible mistake, not a nonsense one.
  local f key
  for key in "kernel_packages: [linux-image-something]" \
             "board_id: fixture-other" \
             "firmware_packages: [armbian-firmware]" \
             "ubot_packages: [typo-package]"; do
    f="$BATS_TEST_TMPDIR/wide-$RANDOM.yaml"
    write_override_board "$f" "  edge:
    ${key}"
    run validate_manifest "$f" "$BOARD_SCHEMA"
    [ "$status" -ne 0 ]
  done
}

@test "schema: a variant override's uboot_packages must be a non-empty package-name array" {
  local f
  f="$BATS_TEST_TMPDIR/ovr-empty.yaml"
  write_override_board "$f" "  edge:
    uboot_packages: []"
  run validate_manifest "$f" "$BOARD_SCHEMA"
  [ "$status" -ne 0 ]

  f="$BATS_TEST_TMPDIR/ovr-scalar.yaml"
  write_override_board "$f" "  edge:
    uboot_packages: linux-u-boot-fixture-edge"
  run validate_manifest "$f" "$BOARD_SCHEMA"
  [ "$status" -ne 0 ]

  f="$BATS_TEST_TMPDIR/ovr-badname.yaml"
  write_override_board "$f" "  edge:
    uboot_packages:
      - 'Not A Package Name'"
  run validate_manifest "$f" "$BOARD_SCHEMA"
  [ "$status" -ne 0 ]
}

@test "schema: both shipped RK3588 board manifests still validate" {
  local board
  for board in rock-5b-plus orange-pi-5-plus; do
    run validate_manifest "$PIPELINE_DIR/manifests/boards/${board}.yaml" "$BOARD_SCHEMA"
    [ "$status" -eq 0 ]
    [[ "$output" == *"VALID"* ]]
  done
}

# ===========================================================================
# (B) RESOLVER — edge exact, vendor byte-identical, and both proven non-vacuous.
# ===========================================================================

@test "resolver: --variant edge resolves EXACTLY todo-1's pinned U-Boot package per board" {
  run bash -c "'$RESOLVE_SH' rock-5b-plus --variant edge 2>/dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"UBOOT_PACKAGES='${EDGE_PIN_rock_5b_plus}'"* ]]

  run bash -c "'$RESOLVE_SH' orange-pi-5-plus --variant edge 2>/dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"UBOOT_PACKAGES='${EDGE_PIN_orange_pi_5_plus}'"* ]]
}

@test "resolver: the per-variant package REPLACES the board's own, it does not append" {
  # Arrays replace wholesale (the LOCKED merge semantic). A build that fetched
  # BOTH packages would stage two U-Boots into one bsp dir and let a find(1)
  # decide which bootloader the board gets.
  local board line
  for board in rock-5b-plus orange-pi-5-plus; do
    line="$(bash -c "'$RESOLVE_SH' '$board' --variant edge 2>/dev/null" \
            | sed -n "s/^UBOOT_PACKAGES='\(.*\)'$/\1/p")"
    [ -n "$line" ]
    [ "$(printf '%s\n' "$line" | wc -w)" -eq 1 ]
    case "$line" in
      *-vendor) printf 'vendor U-Boot survived into the edge resolve for %s: %s\n' "$board" "$line" >&2; false ;;
    esac
  done
}

@test "resolver: PRODUCTION resolve is BYTE-IDENTICAL to the committed vendor baselines" {
  # These fixtures were captured before any of this existed. A diff here is a
  # defect in the change, never a reason to regenerate the fixture.
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

@test "resolver: the byte-identity proof HAS TEETH on the U-Boot field" {
  # Non-vacuity, aimed at THIS change specifically: the same comparison must
  # FAIL on the edge resolve, and the diff must be the U-Boot line — otherwise
  # a broken fixture path would let the guard above pass forever.
  local board
  for board in rock-5b-plus orange-pi-5-plus; do
    run bash -c "'$RESOLVE_SH' '$board' --variant edge 2>/dev/null"
    [ "$status" -eq 0 ]
    local resolved="$output"
    run diff -q "$(VENDOR_BASELINE_DIR)/${board}.params" <(printf '%s\n' "$resolved")
    [ "$status" -ne 0 ]
    run diff "$(VENDOR_BASELINE_DIR)/${board}.params" <(printf '%s\n' "$resolved")
    [[ "$output" == *"UBOOT_PACKAGES"* ]]
  done
}

@test "resolver: a per-variant uboot_packages wins over the board's top-level one" {
  # The merge-order proof in isolation: family -> variant -> board, then the
  # board's OWN per-variant override last. A plain family-variant value must
  # still LOSE to the board (board-wins-last is strengthened, not weakened).
  local fam="$BATS_TEST_TMPDIR/ub-fam.yaml"
  local brd="$BATS_TEST_TMPDIR/ub-brd.yaml"
  cat > "$fam" <<'YAML'
uboot_packages: [from-family]
other_field: from-family
variants:
  edge:
    uboot_packages: [from-variant]
    other_field: from-variant
YAML
  cat > "$brd" <<'YAML'
family: ub-fam
dtb_name: board-own.dtb
uboot_packages: [from-board]
other_field: from-board
variant_overrides:
  edge:
    uboot_packages: [from-board-override]
YAML
  run python3 "$RESOLVE_PY" merge --family "$fam" --board "$brd" --variant edge
  [ "$status" -eq 0 ]
  [[ "$output" == *$'UBOOT_PACKAGES\tfrom-board-override'* ]]
  [[ "$output" == *$'OTHER_FIELD\tfrom-board'* ]]

  # …and the DEFAULT path is untouched by the override's mere presence.
  run python3 "$RESOLVE_PY" merge --family "$fam" --board "$brd"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'UBOOT_PACKAGES\tfrom-board'* ]]
}

@test "resolver: no VARIANT_OVERRIDES_* key leaks into the flattened params" {
  local board path
  for board in rock-5b-plus orange-pi-5-plus; do
    for path in "" "--variant edge"; do
      run bash -c "'$RESOLVE_SH' '$board' $path 2>/dev/null"
      [ "$status" -eq 0 ]
      [[ "$output" != *"VARIANT_OVERRIDES"* ]]
    done
  done
}

@test "pins: every U-Boot package any shipped variant resolves is version-pinned exactly once" {
  # fetch/bsp.sh dies unless armbian-bsp-deb-versions.txt names EXACTLY one
  # version for each declared package, and the PR gate is DRY_RUN-only, so an
  # unpinned edge package would first surface as a failed real build.
  local board variant pkg hits
  for board in rock-5b-plus orange-pi-5-plus; do
    for variant in "" "--variant edge"; do
      pkg="$(bash -c "'$RESOLVE_SH' '$board' $variant 2>/dev/null" \
             | sed -n "s/^UBOOT_PACKAGES='\(.*\)'$/\1/p")"
      [ -n "$pkg" ]
      hits="$(grep -c "^${pkg}=" "$(BSP_PINS)" || true)"
      [ "$hits" -eq 1 ]
    done
  done
}

# ===========================================================================
# (C) WRITER — tuple selection, committed identity, readback, and refusal.
# ===========================================================================

@test "writer: the committed map covers EVERY board x variant tuple that can reach it" {
  # A family variant added without deciding which bootloader it ships would
  # otherwise fail at the far end of a real build. Every rk3588 board x every
  # declared variant (plus the production default) must resolve to a plan.
  local variants board variant
  variants="$(python3 -c "
import yaml
d = yaml.safe_load(open('$PIPELINE_DIR/manifests/families/rk3588.yaml'))
print(' '.join(sorted(d.get('variants', {}))))")"
  [ -n "$variants" ]
  for board in rock-5b-plus orange-pi-5-plus; do
    local board_id
    board_id="$(bash -c "'$RESOLVE_SH' '$board' 2>/dev/null" \
                | sed -n "s/^BOARD_ID='\(.*\)'$/\1/p")"
    for variant in default $variants; do
      run "$(WRITER)" plan --board "$board_id" --variant "$variant"
      [ "$status" -eq 0 ]
      [ -n "$output" ]
    done
  done
}

@test "writer: the committed map agrees with the resolver on WHICH package ships the blob" {
  # The two halves are keyed on the same tuple on purpose; if they disagree the
  # writer would demand a blob from a package the fetcher never staged.
  local board variant flag board_id pkg mapped
  for board in rock-5b-plus orange-pi-5-plus; do
    board_id="$(bash -c "'$RESOLVE_SH' '$board' 2>/dev/null" \
                | sed -n "s/^BOARD_ID='\(.*\)'$/\1/p")"
    for variant in default edge; do
      flag=""
      [ "$variant" = edge ] && flag="--variant edge"
      pkg="$(bash -c "'$RESOLVE_SH' '$board' $flag 2>/dev/null" \
             | sed -n "s/^UBOOT_PACKAGES='\(.*\)'$/\1/p")"
      mapped="$("$(WRITER)" plan --board "$board_id" --variant "$variant" \
                | awk -F'\t' '{print $5}' | sort -u)"
      [ "$mapped" = "$pkg" ]
    done
  done
}

@test "writer: the committed map's version column agrees with the BSP version pins" {
  local line pkg version
  while IFS=$'\t' read -r _ _ pkg version _ _; do
    [[ -n "$pkg" ]] || continue
    grep -qx "${pkg}=${version}" "$(BSP_PINS)"
  done < <(grep -v '^[[:space:]]*#' "$(BLOB_MAP)" | awk -F'\t' 'NF >= 6')
}

@test "writer: edge resolves the UNIFIED blob at sector 64 on BOTH boards" {
  # todo 1 confirmed every -edge/-current package on both boards ships one
  # u-boot-rockchip.bin and NO idbloader.img/u-boot.itb pair — so no split
  # handling may be invented for the edge track.
  local board_id
  for board_id in rock-5b-plus orangepi5-plus; do
    run "$(WRITER)" plan --board "$board_id" --variant edge
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
    [[ "$output" == $'u-boot-rockchip.bin\t64\t512\t'* ]]
  done
}

@test "writer: the PRODUCTION OPi split layout is preserved verbatim" {
  # linux-u-boot-orangepi5-plus-vendor is the ONE pinned package that still
  # ships the 2017.09 idbloader.img + u-boot.itb pair. Losing it would brick
  # the shipped production image, which is not what this change is about.
  run "$(WRITER)" plan --board orangepi5-plus --variant default
  [ "$status" -eq 0 ]
  [[ "$output" == *$'idbloader.img\t64\t512\t'* ]]
  [[ "$output" == *$'u-boot.itb\t16384\t512\t'* ]]

  # The Rock's vendor package is unified, and that asymmetry is real.
  run "$(WRITER)" plan --board rock-5b-plus --variant default
  [ "$status" -eq 0 ]
  [[ "$output" == $'u-boot-rockchip.bin\t64\t512\t'* ]]
}

@test "writer: happy path writes, reads back and verifies RKNS" {
  local bsp="$BATS_TEST_TMPDIR/bsp" map="$BATS_TEST_TMPDIR/map.tsv"
  local img="$BATS_TEST_TMPDIR/disk.raw"
  mkdir -p "$bsp"
  make_blob "$bsp/u-boot-rockchip.bin" 'A'
  printf 'orangepi5-plus\tedge\tlinux-u-boot-orangepi5-plus-edge\t26.5.1\tu-boot-rockchip.bin\t%s\n' \
    "$(sha_of "$bsp/u-boot-rockchip.bin")" >"$map"
  make_image "$img"

  run "$(WRITER)" write --image "$img" --board orangepi5-plus --variant edge \
    --bsp-dir "$bsp" --blob-map "$map"
  [ "$status" -eq 0 ]
  [[ "$output" == *"blob identity verified"* ]]
  [[ "$output" == *"readback verified byte-identical"* ]]
  [[ "$output" == *"RKNS idblock magic verified"* ]]

  # And the bytes really are at sector 64.
  run bash -c "dd if='$img' bs=512 skip=64 count=8 status=none | head -c 4"
  [ "$output" = "RKNS" ]
}

@test "writer: a TAMPERED blob aborts with the identity diagnostic, before any dd" {
  local bsp="$BATS_TEST_TMPDIR/bsp-t" map="$BATS_TEST_TMPDIR/map-t.tsv"
  local img="$BATS_TEST_TMPDIR/disk-t.raw"
  mkdir -p "$bsp"
  make_blob "$bsp/u-boot-rockchip.bin" 'A'
  local good; good="$(sha_of "$bsp/u-boot-rockchip.bin")"
  printf 'rock-5b-plus\tedge\tlinux-u-boot-rock-5b-plus-edge\t26.5.1\tu-boot-rockchip.bin\t%s\n' \
    "$good" >"$map"
  make_image "$img"

  # Flip ONE byte deep inside the blob — the shape a same-version upstream
  # re-spin has, and one no length or magic check could ever catch.
  printf '\xff' | dd of="$bsp/u-boot-rockchip.bin" bs=1 seek=2048 count=1 conv=notrunc status=none
  [ "$(sha_of "$bsp/u-boot-rockchip.bin")" != "$good" ]

  run "$(WRITER)" write --image "$img" --board rock-5b-plus --variant edge \
    --bsp-dir "$bsp" --blob-map "$map"
  [ "$status" -ne 0 ]
  [[ "$output" == *"IDENTITY check FAILED"* ]]
  [[ "$output" == *"rock-5b-plus/edge/u-boot-rockchip.bin"* ]]
  [[ "$output" == *"$good"* ]]

  # The refusal happened BEFORE the write: sector 64 is still untouched.
  run bash -c "dd if='$img' bs=512 skip=64 count=1 status=none | head -c 4 | od -An -tx1 | tr -d ' \n'"
  [ "$output" = "00000000" ]
}

@test "writer: an UNMAPPED board x variant tuple aborts" {
  local bsp="$BATS_TEST_TMPDIR/bsp-u" map="$BATS_TEST_TMPDIR/map-u.tsv"
  local img="$BATS_TEST_TMPDIR/disk-u.raw"
  mkdir -p "$bsp"
  make_blob "$bsp/u-boot-rockchip.bin" 'A'
  printf 'rock-5b-plus\tedge\tlinux-u-boot-rock-5b-plus-edge\t26.5.1\tu-boot-rockchip.bin\t%s\n' \
    "$(sha_of "$bsp/u-boot-rockchip.bin")" >"$map"
  make_image "$img"

  # Same board, a variant the map does not cover.
  run "$(WRITER)" write --image "$img" --board rock-5b-plus --variant some-new-variant \
    --bsp-dir "$bsp" --blob-map "$map"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no RK3588 raw-gap bootloader plan"* ]]

  # Same variant, a board the map does not cover.
  run "$(WRITER)" write --image "$img" --board x86-minipc --variant edge \
    --bsp-dir "$bsp" --blob-map "$map"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no RK3588 raw-gap bootloader plan"* ]]
}

@test "writer: the WRONG BOARD's blob is refused even though the filename matches" {
  # Both boards' edge packages ship a file called u-boot-rockchip.bin, so a
  # mis-staged bsp dir presents a perfectly plausible blob. Only the hash tells
  # them apart, which is the entire reason the map is committed.
  local bsp="$BATS_TEST_TMPDIR/bsp-w" map="$BATS_TEST_TMPDIR/map-w.tsv"
  local img="$BATS_TEST_TMPDIR/disk-w.raw"
  mkdir -p "$bsp"
  local opi="$BATS_TEST_TMPDIR/opi.bin" rock="$BATS_TEST_TMPDIR/rock.bin"
  make_blob "$opi"  'O'
  make_blob "$rock" 'R'
  {
    printf 'orangepi5-plus\tedge\tlinux-u-boot-orangepi5-plus-edge\t26.5.1\tu-boot-rockchip.bin\t%s\n' "$(sha_of "$opi")"
    printf 'rock-5b-plus\tedge\tlinux-u-boot-rock-5b-plus-edge\t26.5.1\tu-boot-rockchip.bin\t%s\n' "$(sha_of "$rock")"
  } >"$map"
  make_image "$img"

  # Stage the ROCK payload and ask for the ORANGE PI.
  cp "$rock" "$bsp/u-boot-rockchip.bin"
  run "$(WRITER)" write --image "$img" --board orangepi5-plus --variant edge \
    --bsp-dir "$bsp" --blob-map "$map"
  [ "$status" -ne 0 ]
  [[ "$output" == *"IDENTITY check FAILED"* ]]
  [[ "$output" == *"orangepi5-plus/edge/u-boot-rockchip.bin"* ]]

  # Non-vacuity: the CORRECT payload through the identical invocation succeeds.
  cp "$opi" "$bsp/u-boot-rockchip.bin"
  run "$(WRITER)" write --image "$img" --board orangepi5-plus --variant edge \
    --bsp-dir "$bsp" --blob-map "$map"
  [ "$status" -eq 0 ]
}

@test "writer: READBACK is not vacuous — a dd that does not land aborts before RKNS" {
  # assert_rkns would also notice a completely missing write, but only for the
  # blob at sector 64 and only as "some idblock is absent". The readback leg is
  # what makes the check per-blob and content-exact, so it must fire FIRST and
  # name itself. A PATH stub swallows the write while leaving the read intact.
  local bsp="$BATS_TEST_TMPDIR/bsp-r" map="$BATS_TEST_TMPDIR/map-r.tsv"
  local img="$BATS_TEST_TMPDIR/disk-r.raw" stub="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$bsp" "$stub"
  make_blob "$bsp/u-boot-rockchip.bin" 'A'
  printf 'rock-5b-plus\tedge\tlinux-u-boot-rock-5b-plus-edge\t26.5.1\tu-boot-rockchip.bin\t%s\n' \
    "$(sha_of "$bsp/u-boot-rockchip.bin")" >"$map"
  make_image "$img"

  cat >"$stub/dd" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in of=*) exit 0 ;; esac
done
exec /usr/bin/env -i PATH=/usr/bin:/bin dd "$@"
EOF
  chmod +x "$stub/dd"

  run env PATH="$stub:$PATH" "$(WRITER)" write --image "$img" \
    --board rock-5b-plus --variant edge --bsp-dir "$bsp" --blob-map "$map"
  [ "$status" -ne 0 ]
  [[ "$output" == *"READBACK check FAILED"* ]]
  [[ "$output" != *"RKNS idblock magic verified"* ]]
}

@test "writer: assert_rkns is RETAINED and still runs after the readback" {
  # The readback is ADDITIONAL verification, never a replacement. Structural,
  # because the happy-path leg alone cannot prove the older check survived.
  local src; src="$(WRITER)"
  grep -q '^assert_rkns()' "$src"
  grep -q 'RKNS_MAGIC="52 4b 4e 53"' "$src"
  # do_write calls the readback inside its per-blob loop and RKNS once, after it.
  local rb rk
  rb="$(grep -n 'assert_readback "\${img}"' "$src" | head -1 | cut -d: -f1)"
  rk="$(grep -n 'assert_rkns "\${img}"' "$src" | tail -1 | cut -d: -f1)"
  [ -n "$rb" ] && [ -n "$rk" ] && [ "$rb" -lt "$rk" ]
}

@test "writer: no board or variant is hardcoded outside the geometry table" {
  # The blob set must come from the committed map. A board name in a case arm
  # would be exactly the drift this replaced.
  local src; src="$(WRITER)"
  run ! grep -Eq '^\s*(rock-5b-plus|orangepi5-plus)\)' "$src"
}

# ===========================================================================
# Assembler wiring — the tuple has to actually reach the writer.
# ===========================================================================

@test "wiring: assemble-disk.sh forwards --variant to the gap writer" {
  grep -q -- '--variant)             variant=' "$LIB_DIR/assemble-disk.sh"
  grep -q 'write_gap_bootloader "${img}" "${adapter}" "${board_id}" "${bsp_dir}" "${variant}"' \
    "$LIB_DIR/assemble-disk.sh"
  grep -q -- '--variant "${variant:-default}"' "$LIB_DIR/disk/gap.sh"
}

@test "wiring: the orchestrator's [8/9] stage passes the resolved variant" {
  grep -q -- '--variant "${KERNEL_VARIANT:-${variant}}"' "$LIB_DIR/stages/assemble.sh"
}

@test "wiring: an empty variant is the PRODUCTION path, not an error" {
  # KERNEL_VARIANT is emitted by the resolver ONLY for a kernel-from-source
  # variant, so the vendor path legitimately arrives as the empty string. If the
  # writer rejected it, every production build would fail at Stage 4.
  local bsp="$BATS_TEST_TMPDIR/bsp-e" map="$BATS_TEST_TMPDIR/map-e.tsv"
  local img="$BATS_TEST_TMPDIR/disk-e.raw"
  mkdir -p "$bsp"
  make_blob "$bsp/u-boot-rockchip.bin" 'A'
  printf 'rock-5b-plus\tdefault\tlinux-u-boot-rock-5b-plus-vendor\t26.5.1\tu-boot-rockchip.bin\t%s\n' \
    "$(sha_of "$bsp/u-boot-rockchip.bin")" >"$map"
  make_image "$img"

  run "$(WRITER)" write --image "$img" --board rock-5b-plus --variant "" \
    --bsp-dir "$bsp" --blob-map "$map"
  [ "$status" -eq 0 ]
  [[ "$output" == *"variant=default"* ]]
}
