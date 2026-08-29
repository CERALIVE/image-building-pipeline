#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
#
# package-contract.bats — package-set contracts — add-on descriptors and signed feature
# sysexts, BSP provenance and the drift-guard, the WWAN advisory check, the
# fetch-debs guards, apt.ceralive.tv repo correctness, first-party staging, the
# Mesa prune, the debug/production package split, and the kernel freeze.
#
# Split out of the former tests/manifest.bats with the cases moved VERBATIM;
# the shared setup and every fixture helper live in manifest-helpers.bash.
#
# Run:  run-tests              (CI entrypoint)
#   or: bats tests/package-contract.bats

load manifest-helpers

# ===========================================================================
# 13. Add-on descriptor format + conflict model (Task 21).
#     addon.schema.json is the per-descriptor gate: G1 sysext merge identity
#     (sysextLevel const "1", versionId const mirroring OS_VERSION_ID in
#     manifests/target-release.env) and G2 the /usr+/opt-only
#     provides[] boundary. validate-manifests.py layers the cross-descriptor E6
#     model on top: no two add-ons may claim the same provides[] path unless they
#     mutually declare each other in conflicts[] (the provides/conflicts model).
#     Pure static validation (no image, no sysext merge) so it fits this UNIT
#     suite.
# ===========================================================================

@test "schema: addon.schema.json is a valid draft-2020-12 schema" {
  run check_schema_metaschema "$ADDON_SCHEMA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SCHEMA-OK"* ]]
}

@test "valid: shipped debug-toolset descriptor validates against addon schema" {
  run validate_manifest "$PIPELINE_DIR/manifests/addons/debug-toolset.json" "$ADDON_SCHEMA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"VALID"* ]]
}

@test "addon: validate-manifests.py passes clean on the shipped descriptors (exit 0)" {
  run bash -c "python3 '$VALIDATE_PY' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"debug-toolset.json"* ]]
  [[ "$output" == *"0 errors"* ]]
}

@test "invalid: addon with an /etc path in provides[] is REJECTED (G2), names provides" {
  run validate_manifest "$FIXTURES/invalid-addon-etc-provides.json" "$ADDON_SCHEMA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"provides"* ]]
}

@test "invalid: addon missing sysextLevel is REJECTED (G1), names sysextLevel" {
  run validate_manifest "$FIXTURES/invalid-addon-missing-sysextlevel.json" "$ADDON_SCHEMA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"sysextLevel"* ]]
}

@test "addon conflict: two descriptors claiming the same provides[] path are flagged (E6)" {
  local adir="$BATS_TEST_TMPDIR/addons-collide"
  mkdir -p "$adir"
  write_addon "$adir" addon-a '[]' "/usr/bin/shared-tool"
  write_addon "$adir" addon-b '[]' "/usr/bin/shared-tool"
  run bash -c "ADDONS_DIR='$adir' python3 '$VALIDATE_PY' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"collision"* ]]
  [[ "$output" == *"/usr/bin/shared-tool"* ]]
}

@test "addon conflict: a shared provides[] path is ALLOWED when both declare mutual conflicts[] (provides/conflicts model)" {
  local adir="$BATS_TEST_TMPDIR/addons-resolved"
  mkdir -p "$adir"
  write_addon "$adir" addon-a '["addon-b"]' "/usr/bin/shared-tool"
  write_addon "$adir" addon-b '["addon-a"]' "/usr/bin/shared-tool"
  run bash -c "ADDONS_DIR='$adir' python3 '$VALIDATE_PY' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 errors"* ]]
  [[ "$output" != *"collision"* ]]
}

# ===========================================================================
# 14. Signed per-board/per-OS feature sysext build (Task 24).
#     lib/build-feature-sysext.sh turns a .deb staging tree into a SIGNED add-on
#     sysext: <feature>-<board>-<os>.raw + .raw.sha256 + .raw.sig, verifiable with
#     gpgv against the image-baked add-on PUBLIC keyring. Guards proven here:
#       * artifact set + sha256 integrity + GPG authenticity (gpgv OK)
#       * G1 — the produced extension-release carries SYSEXT_LEVEL=1 plus the
#         VERSION_ID the target-release mapping declares (never a literal)
#       * G2 — a staging tree with /etc (escapes the /usr+/opt boundary) is REFUSED
#       * tamper — a flipped byte in the .raw makes gpgv FAIL (signing has teeth)
#       * the baked keyring is PUBLIC-only and a DISTINCT trust domain from RAUC
#     Hermetic: a throwaway gpg home under BATS_FILE_TMPDIR signs the fixture, so
#     the suite never touches the repo dev keys. Skips (still green) if the signing
#     toolchain (mksquashfs/gpg/gpgv/unsquashfs) is unavailable on the host.
# ===========================================================================

@test "t24 sysext: build emits .raw + .raw.sha256 + .raw.sig + addon-keyring.gpg" {
  feature_prereqs || skip "mksquashfs/gpg/gpgv/unsquashfs not available"
  build_feature_fixture
  local out="$BATS_FILE_TMPDIR/out"
  [ -f "$out/demo-feature-rock-5b-plus-${OS_VERSION_ID}.raw" ]
  [ -f "$out/demo-feature-rock-5b-plus-${OS_VERSION_ID}.raw.sha256" ]
  [ -f "$out/demo-feature-rock-5b-plus-${OS_VERSION_ID}.raw.sig" ]
  [ -f "$out/addon-keyring.gpg" ]
}

@test "t24 sysext: sha256 sidecar matches the produced .raw" {
  feature_prereqs || skip "signing toolchain not available"
  build_feature_fixture
  local out="$BATS_FILE_TMPDIR/out"
  run bash -c "cd '$out' && sha256sum -c demo-feature-rock-5b-plus-${OS_VERSION_ID}.raw.sha256"
  [ "$status" -eq 0 ]
  [[ "$output" == *": OK"* ]]
}

@test "t24 sysext: detached signature verifies against the baked add-on keyring (gpgv OK)" {
  feature_prereqs || skip "signing toolchain not available"
  build_feature_fixture
  local out="$BATS_FILE_TMPDIR/out"
  run gpgv --keyring "$out/addon-keyring.gpg" \
        "$out/demo-feature-rock-5b-plus-${OS_VERSION_ID}.raw.sig" \
        "$out/demo-feature-rock-5b-plus-${OS_VERSION_ID}.raw"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Good signature"* ]]
}

@test "t24 sysext G1: produced extension-release carries SYSEXT_LEVEL=1 + the mapped VERSION_ID" {
  feature_prereqs || skip "signing toolchain not available"
  build_feature_fixture
  local out="$BATS_FILE_TMPDIR/out"
  run unsquashfs -no-progress -cat \
        "$out/demo-feature-rock-5b-plus-${OS_VERSION_ID}.raw" \
        usr/lib/extension-release.d/extension-release.demo-feature
  [ "$status" -eq 0 ]
  [[ "$output" == *"SYSEXT_LEVEL=1"* ]]
  [[ "$output" == *"VERSION_ID=${OS_VERSION_ID}"* ]]
}

@test "t24 sysext G2: a staging tree with /etc is REFUSED (escapes /usr+/opt boundary)" {
  feature_prereqs || skip "signing toolchain not available"
  local stg="$BATS_TEST_TMPDIR/g2-staging" out="$BATS_TEST_TMPDIR/g2-out"
  mkdir -p "$stg/usr/bin" "$stg/etc"
  printf 'x\n'   > "$stg/usr/bin/t"
  printf 'cfg\n' > "$stg/etc/foo.conf"
  run bash "$LIB_DIR/build-feature-sysext.sh" \
        --feature bad --board rock-5b-plus --os-version "${OS_VERSION_ID}" \
        --deb-staging "$stg" --out "$out" --keyring "$BATS_FILE_TMPDIR/gnupg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"G2 boundary"* ]]
  [ ! -f "$out/bad-rock-5b-plus-${OS_VERSION_ID}.raw" ]
}

@test "t24 sysext tamper: a flipped byte in the .raw makes gpgv FAIL (signing has teeth)" {
  feature_prereqs || skip "signing toolchain not available"
  build_feature_fixture
  local out="$BATS_FILE_TMPDIR/out"
  local tampered="$BATS_TEST_TMPDIR/tampered.raw"
  cp "$out/demo-feature-rock-5b-plus-${OS_VERSION_ID}.raw" "$tampered"
  printf '\xff' | dd of="$tampered" bs=1 seek=64 count=1 conv=notrunc 2>/dev/null
  run gpgv --keyring "$out/addon-keyring.gpg" \
        "$out/demo-feature-rock-5b-plus-${OS_VERSION_ID}.raw.sig" "$tampered"
  [ "$status" -ne 0 ]
  [[ "$output" != *"Good signature"* ]]
}

@test "t24 keyring: committed baked add-on keyring exists and is PUBLIC-only (no secret packets)" {
  command -v gpg >/dev/null 2>&1 || skip "gpg not available"
  local baked="$PIPELINE_DIR/mkosi/runtime/addon-keyring/addon-keyring.gpg"
  [ -s "$baked" ]
  # It must be a usable OpenPGP public keyring...
  run gpg --show-keys --with-colons "$baked"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\npub:'* || "$output" == pub:* ]]
  # ...and must NOT carry any secret-key material (a device only verifies).
  run gpg --list-packets "$baked"
  [ "$status" -eq 0 ]
  [[ "$output" != *"secret key"* ]]
  run ! grep -aq 'PRIVATE KEY' "$baked"
}

@test "t24 keyring: add-on keyring is a DISTINCT trust domain from the RAUC keyring" {
  local baked="$PIPELINE_DIR/mkosi/runtime/addon-keyring/addon-keyring.gpg"
  local rauc="$PIPELINE_DIR/mkosi/runtime/rauc/ceralive-keyring.pem"
  [ -s "$baked" ]
  [ -s "$rauc" ]
  # Different files, different bytes — add-on signing never reuses the RAUC anchor.
  run cmp -s "$baked" "$rauc"
  [ "$status" -ne 0 ]
}

# ===========================================================================
# 14b. Build-time descriptor schema fail-fast (C6b).
#     build-feature-sysext.sh validates its target add-on descriptor against
#     addon.schema.json (reusing ci/validate-manifests.py --file) BEFORE any
#     build side-effect. A corrupt descriptor aborts non-zero with the path in
#     stderr and produces no artifact; a schema-valid descriptor proceeds. The
#     cross-descriptor G1/G2/E6 semantics stay CI-only (glob mode) — build time
#     is schema-only. Needs python3 + jsonschema (a suite-wide assumption, §13).
# ===========================================================================

@test "c6b: --file mode of validate-manifests.py rejects a corrupt descriptor, names its path" {
  local desc="$FIXTURES/invalid-addon-build-fixture.json"
  run bash -c "python3 '$VALIDATE_PY' --file '$desc' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$desc"* ]]
  [[ "$output" == *"name"* ]]
}

@test "c6b: --file mode of validate-manifests.py passes a shipped descriptor (exit 0)" {
  run bash -c "python3 '$VALIDATE_PY' --file '$PIPELINE_DIR/manifests/addons/debug-toolset.json' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"debug-toolset.json"* ]]
}

@test "c6b build: a corrupt descriptor is REJECTED before any build side-effect, names the path" {
  local stg="$BATS_TEST_TMPDIR/c6b-staging" out="$BATS_TEST_TMPDIR/c6b-out"
  local desc="$FIXTURES/invalid-addon-build-fixture.json"
  mkdir -p "$stg/usr/bin"
  printf 'x\n' > "$stg/usr/bin/t"
  run bash "$LIB_DIR/build-feature-sysext.sh" \
        --feature demo-feature --board rock-5b-plus --os-version "${OS_VERSION_ID}" \
        --deb-staging "$stg" --out "$out" --descriptor "$desc" \
        --keyring "$BATS_TEST_TMPDIR/c6b-gnupg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$desc"* ]]
  # No build side-effect: the output dir is never created past the fail-fast gate.
  [ ! -e "$out" ]
}

@test "c6b build: a schema-valid descriptor passes validation and the build proceeds" {
  feature_prereqs || skip "signing toolchain not available"
  local stg="$BATS_TEST_TMPDIR/c6b-ok-staging" out="$BATS_TEST_TMPDIR/c6b-ok-out"
  mkdir -p "$stg/usr/bin"
  printf '#!/bin/sh\necho hi\n' > "$stg/usr/bin/demo-tool"
  run bash "$LIB_DIR/build-feature-sysext.sh" \
        --feature demo-feature --board rock-5b-plus --os-version "${OS_VERSION_ID}" \
        --deb-staging "$stg" --out "$out" \
        --descriptor "$PIPELINE_DIR/manifests/addons/debug-toolset.json" \
        --keyring "$BATS_TEST_TMPDIR/c6b-ok-gnupg"
  [ "$status" -eq 0 ]
  [[ "$output" == *"descriptor schema-valid"* ]]
  [ -f "$out/demo-feature-rock-5b-plus-${OS_VERSION_ID}.raw" ]
}

# ===========================================================================
# 15. BSP provenance + advisory kernel drift-guard (Task 3).
#     fetch-debs.sh records the exact-versioned kernel BSP's resolved version +
#     content sha256 into a gitignored bsp-provenance.json, then runs a drift
#     guard against the committed manifests/bsp-baseline.json. It warns by
#     default and is fatal only with BSP_DRIFT_STRICT=1; it compares the CONTENT
#     hash (not just the version), so a same-version re-spin is still caught, and
#     seeds the baseline on first run. These tests source the fetch helpers
#     directly and drive the guard with synthetic version/hash inputs
#     — no apt, no real .deb — so they fit this UNIT suite.
# ===========================================================================

@test "bsp drift: matching version+hash is no-drift (exit 0, no 'BSP drift' banner)" {
  local base="$BATS_TEST_TMPDIR/baseline-match.json"
  printf '{ "schema_version": 1, "package": "linux-image-generic-rk35xx", "version": "6.1.0-generic", "sha256": "%s" }\n' "$BSP_SHA_A" > "$base"
  run bash -c "source '$FETCH_DEBS'; bsp_drift_check '$base' linux-image-generic-rk35xx 6.1.0-generic $BSP_SHA_A"
  [ "$status" -eq 0 ]
  [[ "$output" != *"BSP drift"* ]]
  [[ "$output" == *"matches known-good baseline"* ]]
}

@test "bsp drift: a version mismatch fires an advisory 'BSP drift' warning (exit 0)" {
  local base="$BATS_TEST_TMPDIR/baseline-ver.json"
  printf '{ "schema_version": 1, "package": "linux-image-generic-rk35xx", "version": "6.1.0-generic", "sha256": "%s" }\n' "$BSP_SHA_A" > "$base"
  run bash -c "source '$FETCH_DEBS'; bsp_drift_check '$base' linux-image-generic-rk35xx 6.1.99-generic $BSP_SHA_A"
  [ "$status" -eq 0 ]
  [[ "$output" =~ [Dd]rift ]]
  [[ "$output" == *"BSP drift"* ]]
}

@test "bsp drift: SAME version but DIFFERENT content hash still drifts (content-hash compare, exit 0)" {
  local base="$BATS_TEST_TMPDIR/baseline-hash.json"
  printf '{ "schema_version": 1, "package": "linux-image-generic-rk35xx", "version": "6.1.0-generic", "sha256": "%s" }\n' "$BSP_SHA_A" > "$base"
  run bash -c "source '$FETCH_DEBS'; bsp_drift_check '$base' linux-image-generic-rk35xx 6.1.0-generic $BSP_SHA_B"
  [ "$status" -eq 0 ]
  [[ "$output" =~ [Dd]rift ]]
  # the re-spin note proves the guard compared the hash, not just the version
  [[ "$output" == *"re-spin"* ]]
}

@test "bsp drift: first run with NO baseline seeds it, notes it, exits 0" {
  local base="$BATS_TEST_TMPDIR/seed-me.json"
  [ ! -f "$base" ]
  run bash -c "source '$FETCH_DEBS'; bsp_drift_check '$base' linux-image-generic-rk35xx 6.1.0-generic $BSP_SHA_A"
  [ "$status" -eq 0 ]
  [[ "$output" == *"first run"* ]]
  [ -f "$base" ]
  run cat "$base"
  [[ "$output" == *'"version": "6.1.0-generic"'* ]]
  [[ "$output" == *"$BSP_SHA_A"* ]]
}

@test "bsp drift: an UNSEEDED (null) baseline scaffold is treated as first run (seeds, exit 0)" {
  local base="$BATS_TEST_TMPDIR/scaffold.json"
  printf '{ "schema_version": 1, "package": "linux-image-generic-rk35xx", "version": null, "sha256": null }\n' > "$base"
  run bash -c "source '$FETCH_DEBS'; bsp_drift_check '$base' linux-image-generic-rk35xx 6.1.0-generic $BSP_SHA_A"
  [ "$status" -eq 0 ]
  [[ "$output" == *"first run"* ]]
  run cat "$base"
  [[ "$output" == *"$BSP_SHA_A"* ]]
}

@test "bsp drift (C6b): default (STRICT unset) with drift warns and exits 0" {
  local base="$BATS_TEST_TMPDIR/baseline-default.json"
  printf '{ "schema_version": 1, "package": "linux-image-generic-rk35xx", "version": "6.1.0-generic", "sha256": "%s" }\n' "$BSP_SHA_A" > "$base"
  run bash -c "source '$FETCH_DEBS'; bsp_drift_check '$base' linux-image-generic-rk35xx 6.1.99-generic $BSP_SHA_A"
  [ "$status" -eq 0 ]
  [[ "$output" == *"BSP drift"* ]]
  [[ "$output" == *"advisory — build continues"* ]]
}

@test "bsp drift (C6b): BSP_DRIFT_STRICT=1 with drift fails (non-zero)" {
  local base="$BATS_TEST_TMPDIR/baseline-strict.json"
  printf '{ "schema_version": 1, "package": "linux-image-generic-rk35xx", "version": "6.1.0-generic", "sha256": "%s" }\n' "$BSP_SHA_A" > "$base"
  run bash -c "source '$FETCH_DEBS'; BSP_DRIFT_STRICT=1 bsp_drift_check '$base' linux-image-generic-rk35xx 6.1.99-generic $BSP_SHA_A"
  [ "$status" -ne 0 ]
  [[ "$output" == *"BSP drift"* ]]
  [[ "$output" == *"BSP_DRIFT_STRICT=1"* ]]
}

@test "bsp drift (C6b): no drift is exit 0 in BOTH default and strict modes" {
  local base="$BATS_TEST_TMPDIR/baseline-match-modes.json"
  printf '{ "schema_version": 1, "package": "linux-image-generic-rk35xx", "version": "6.1.0-generic", "sha256": "%s" }\n' "$BSP_SHA_A" > "$base"
  run bash -c "source '$FETCH_DEBS'; bsp_drift_check '$base' linux-image-generic-rk35xx 6.1.0-generic $BSP_SHA_A"
  [ "$status" -eq 0 ]
  run bash -c "source '$FETCH_DEBS'; BSP_DRIFT_STRICT=1 bsp_drift_check '$base' linux-image-generic-rk35xx 6.1.0-generic $BSP_SHA_A"
  [ "$status" -eq 0 ]
  [[ "$output" == *"matches known-good baseline"* ]]
}

@test "bsp drift (C6b): BSP_DRIFT_STRICT=1 with an UNSEEDED baseline seeds and exits 0 (seeding is exempt)" {
  local base="$BATS_TEST_TMPDIR/scaffold-strict.json"
  printf '{ "schema_version": 1, "package": "linux-image-generic-rk35xx", "version": null, "sha256": null }\n' > "$base"
  run bash -c "source '$FETCH_DEBS'; BSP_DRIFT_STRICT=1 bsp_drift_check '$base' linux-image-generic-rk35xx 6.1.0-generic $BSP_SHA_A"
  [ "$status" -eq 0 ]
  [[ "$output" == *"first run"* ]]
  run cat "$base"
  [[ "$output" == *"$BSP_SHA_A"* ]]
}

@test "bsp provenance: bsp_write_json emits valid JSON with schema_version + 64-hex sha256" {
  local out="$BATS_TEST_TMPDIR/prov/bsp-provenance.json"
  run bash -c "source '$FETCH_DEBS'; bsp_write_json '$out' linux-image-generic-rk35xx 6.1.0-generic $BSP_SHA_A"
  [ "$status" -eq 0 ]
  [ -f "$out" ]
  # parses as JSON and carries the expected shape
  run python3 -c "import json,sys; d=json.load(open('$out')); assert d['schema_version']==1; assert d['package']=='linux-image-generic-rk35xx'; assert len(d['sha256'])==64; print('JSON-OK')"
  [ "$status" -eq 0 ]
  [[ "$output" == *"JSON-OK"* ]]
}

@test "bsp provenance: the committed baseline is valid JSON and carries a valid seed state" {
  # It is UNSEEDED (all three fields null) and that is the correct state: the
  # drift-guard's subject is a PREBUILT kernel .deb's bytes, and no family this
  # pipeline ships fetches one any more — rk3588 builds from pinned source and
  # x86_64 has no Armbian BSP at all. bsp_drift_check treats a null version/sha
  # as "first run" and seeds it, so the mechanism stays armed for a future family
  # without pinning a package that is never downloaded.
  run python3 -c "import json,re; d=json.load(open('$BSP_BASELINE_JSON')); assert d['schema_version']==1; p=d.get('package'); v=d.get('version'); s=d.get('sha256'); assert (p is None and v is None and s is None) or (isinstance(p,str) and isinstance(v,str) and re.fullmatch(r'[0-9a-f]{64}', s or '')); print('BASELINE-OK')"
  [ "$status" -eq 0 ]
  [[ "$output" == *"BASELINE-OK"* ]]
}

@test "bsp provenance: artifact is gitignored and absent from the determinism hash set" {
  # The provenance artifact lands in the image output dir ($DEST, default ./out);
  # the bare-filename .gitignore pattern matches it at any depth.
  run git -C "$REPO_ROOT" check-ignore -q out/bsp-provenance.json
  [ "$status" -eq 0 ]
  # The determinism job hashes the NORMALIZED build-plan string ('would build
  # with:'), never a file tree — so the floating provenance artifact can never
  # enter the sha256 comparison. Assert the plan-line anchor exists and the
  # artifact name is nowhere in that workflow.
  grep -q "would build with:" "$REPO_ROOT/.github/workflows/v2-ci.yml"
  run ! grep -q "bsp-provenance" "$REPO_ROOT/.github/workflows/v2-ci.yml"
}

@test "v2 CI: resolver dependency cache is content-addressed and covers every resolver job" {
  run python3 - "$REPO_ROOT" <<'PY'
import sys
from pathlib import Path

import yaml

repo_root = Path(sys.argv[1])
workflow = yaml.safe_load((repo_root / ".github/workflows/v2-ci.yml").read_text())
requirements = repo_root / "ci/requirements-ci.txt"
assert requirements.read_text().splitlines()[-2:] == ["jsonschema==4.26.0", "PyYAML==6.0.3"]

expected_key = "pip-${{ runner.os }}-${{ runner.arch }}-${{ hashFiles('ci/requirements-ci.txt') }}"
for job_id in ("schema-validate", "bats", "build-matrix", "build-plan-xrunner"):
    steps = workflow["jobs"][job_id]["steps"]
    cache = next(step for step in steps if step.get("uses") == "actions/cache@v6")
    assert cache["with"] == {
        "path": "~/.cache/pip",
        "key": expected_key,
    }, f"{job_id}: unexpected pip cache declaration: {cache!r}"
    install = next(step["run"] for step in steps if step.get("name", "").startswith("Install "))
    assert "pip install --quiet --requirement ci/requirements-ci.txt" in install, job_id

print("V2-CI-PIP-CACHE-OK")
PY
  [ "$status" -eq 0 ]
  [[ "$output" == *"V2-CI-PIP-CACHE-OK"* ]]
}

@test "v2 CI: qemu job honestly runs only the assertion-engine selftest" {
  run python3 -c "import yaml; workflow = yaml.safe_load(open('$REPO_ROOT/.github/workflows/v2-ci.yml')); job = workflow['jobs']['qemu']; runs = '\n'.join(step.get('run', '') for step in job['steps']); assert 'CERALIVE_QEMU_SELFTEST' in str(job['steps']); assert 'IMAGE_PATH=' not in runs; assert 'skip mode' not in runs; print('QEMU-SELFTEST-SCOPE-OK')"
  [ "$status" -eq 0 ]
  [[ "$output" == *"QEMU-SELFTEST-SCOPE-OK"* ]]
}

# ===========================================================================
# 17. Advisory WWAN module-presence check (Task 5).
#     lib/check-wwan-modules.sh inspects a kernel .deb (or an extracted
#     module tree) and reports whether the six WWAN modules ship — loadable
#     (=m, a <mod>.ko file), built-in (=y, modules.builtin), or via a
#     modules.alias entry. It is ADVISORY: a missing module WARNS but the check
#     ALWAYS exits 0 (like the BSP drift-guard). The option module is matched by
#     option.ko / modules.builtin / alias, NEVER a bare "option" substring. These
#     tests build fixture .debs (ar+tar) and module trees in $BATS_TEST_TMPDIR —
#     no real BSP, UNIT scope.
# ===========================================================================

@test "wwan: all six modules present in a kernel .deb (happy path, mix of =m and =y)" {
  local stage="$BATS_TEST_TMPDIR/stage" deb="$BATS_TEST_TMPDIR/linux-image-generic-rk35xx.deb"
  mkdir -p "$stage"
  wwan_stage_six "$stage"
  make_kernel_deb "$stage" "$deb"
  run "$CHECK_WWAN" "$deb"
  [ "$status" -eq 0 ]
  [[ "$output" == *"all 6 required modules present"* ]]
  [[ "$output" != *"MISSING"* ]]
  # cdc-wdm.ko (hyphen) satisfies cdc_wdm — the -/_ normalisation has teeth
  [[ "$output" == *"cdc_wdm — loadable"* ]]
  # compressed cdc_ether.ko.xz is recognised as loadable
  [[ "$output" == *"cdc_ether — loadable"* ]]
  # built-in modules recognised via modules.builtin
  [[ "$output" == *"cdc_ncm — built-in"* ]]
}

@test "wwan: a missing module WARNS and still exits 0 (advisory, missing cdc_ncm)" {
  local root="$BATS_TEST_TMPDIR/tree"
  wwan_stage_six "$root"
  # drop cdc_ncm from modules.builtin (option stays) so exactly one is absent
  printf 'kernel/drivers/usb/serial/option.ko\n' > "$root/lib/modules/6.1.0-generic/modules.builtin"
  run "$CHECK_WWAN" "$root"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WWAN module MISSING: cdc_ncm"* ]]
  [[ "$output" == *"5/6 present, 1 missing"* ]]
  [[ "$output" == *"ADVISORY"* ]]
}

@test "wwan: a =y built-in module is recognised via modules.builtin (no .ko false-negative)" {
  local root="$BATS_TEST_TMPDIR/tree"
  wwan_stage_six "$root"   # option ships ONLY in modules.builtin, no option.ko
  run "$CHECK_WWAN" "$root"
  [ "$status" -eq 0 ]
  [[ "$output" == *"option — built-in (=y, modules.builtin)"* ]]
  [[ "$output" != *"WWAN module MISSING: option"* ]]
}

@test "wwan: bare 'option' decoys do NOT satisfy the option module (false-positive guard)" {
  local root="$BATS_TEST_TMPDIR/tree" kv="6.1.0-generic"
  wwan_stage_six "$root"
  local md="$root/lib/modules/$kv"
  # remove the only legitimate option signal (built-in), keep cdc_ncm built-in
  printf 'kernel/drivers/net/usb/cdc_ncm.ko\n' > "$md/modules.builtin"
  # decoys that all contain the word "option" but are NOT the option module:
  printf 'the option driver is mentioned here\n' > "$md/optionnotes.txt"
  printf 'ELF' > "$md/kernel/drivers/net/usb/snd_usb_option_helper.ko"
  printf 'alias usb:v1234p5678option cdc_ncm\n' > "$md/modules.alias"
  run "$CHECK_WWAN" "$root"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WWAN module MISSING: option"* ]]
  # the other five remain present → exactly one missing
  [[ "$output" == *"5/6 present, 1 missing"* ]]
}

@test "wwan: the native FM350 mtk_t7xx gate reports PRESENT on a tree that ships it" {
  # The gate used to be kernel-track-scoped: it ran only on a `*vendor-rk35xx`
  # release and reported OUT OF SCOPE anywhere else, because the interesting
  # subject was the prebuilt Armbian package's own bytes. That track is retired
  # and every kernel is now built from pinned source, whose module set is exactly
  # as inspectable — so the scoping is gone and the probe runs on any tree.
  local root="$BATS_TEST_TMPDIR/tree" kv="7.2.0-ceralive-rk3588"
  wwan_stage_six "$root" "$kv"
  mkdir -p "$root/lib/modules/$kv/kernel/drivers/net/wwan"
  printf 'ELF' > "$root/lib/modules/$kv/kernel/drivers/net/wwan/mtk_t7xx.ko"
  run "$CHECK_WWAN" "$root"
  [ "$status" -eq 0 ]
  [[ "$output" == *"native M.2 modem driver gate: scanning"* ]]
  [[ "$output" == *"native M.2 modem driver present: mtk_t7xx — loadable"* ]]
  [[ "$output" != *"OUT OF SCOPE"* ]]
}

@test "wwan: the native FM350 mtk_t7xx gate WARNS on a tree without it, and still exits 0" {
  # This is the CURRENT answer for a real production kernel, and it is a true
  # finding rather than a regression: CONFIG_MTK_T7XX is declared in neither
  # rk3588-edge.fragment nor required-symbols.list, so the FM350's native PCIe
  # personality cannot bind. The retired out-of-scope branch skipped this
  # silently; the gate now says it out loud, advisory as ever.
  local root="$BATS_TEST_TMPDIR/tree"
  wwan_stage_six "$root" "7.2.0-ceralive-rk3588"
  run "$CHECK_WWAN" "$root"
  [ "$status" -eq 0 ]
  [[ "$output" == *"native M.2 modem driver ABSENT: mtk_t7xx"* ]]
  [[ "$output" == *"14c3:4d75"* ]]
  [[ "$output" == *"0e8d:7127"* ]]
  [[ "$output" == *"all 6 required modules present"* ]]
}

@test "wwan: the native-M.2 gate is NO LONGER kernel-track-scoped" {
  # ABSENCE GUARD for the retired release-marker branch. Re-introducing it would
  # make the probe silent on every tree this pipeline now builds.
  # Code only, never comments: the retirement is EXPLAINED in the script's header
  # and that prose must stay readable.
  local code
  code="$(grep -v '^[[:space:]]*#' "$CHECK_WWAN")"
  run ! grep -q 'WWAN_VENDOR_RELEASE_MARKER' <<<"$code"
  run ! grep -q 'wwan_tree_is_vendor_track' <<<"$code"
  run ! grep -q 'OUT OF SCOPE' <<<"$code"
  run bash -c "source '$CHECK_WWAN'; printf '%s' \"\${WWAN_NATIVE_M2_MODULES[*]}\""
  [ "$output" = "mtk_t7xx" ]
}

@test "modem recovery: uhubctl ships as a manual binary with no automatic invoker" {
  grep -Ex 'uhubctl[[:space:]]*(#.*)?' "$REPO_ROOT/manifests/packages/shared.list"
  ! grep -rF 'uhubctl' "$REPO_ROOT/mkosi/runtime" "$REPO_ROOT/mkosi/customize"
}

@test "RK3588 multimedia config: libv4l-0 is in the earlier runtime transaction" {
  local shared="$REPO_ROOT/manifests/packages/shared.list"
  run grep -Ex 'libv4l-0[[:space:]]*(#.*)?' "$shared"
  [ "$status" -eq 0 ]
  run grep -n -E '^(v4l-utils|libv4l-0)[[:space:]]' "$shared"
  [ "$status" -eq 0 ]
  [ "$(sed -n 's/^v4l-utils[[:space:]]*//p' "$shared" | head -n 1 >/dev/null; grep -n '^v4l-utils[[:space:]]' "$shared" | cut -d: -f1)" -lt "$(grep -n '^libv4l-0[[:space:]]' "$shared" | cut -d: -f1)" ]
}

@test "RK3588 multimedia config: generated libv4l-0 compat package carries exactly the t64 library symlink" {
  local debs="$BATS_TEST_TMPDIR/libv4l-compat-debs"
  local root="$BATS_TEST_TMPDIR/libv4l-compat-root"
  mkdir -p "$debs" "$root"

  run env ARCH=arm64 SOURCE_DATE_EPOCH=1 bash -c \
    'source "$1"; build_libv4l0_compat_deb "$2"' bash "$FETCH_DEBS" "$debs"
  [ "$status" -eq 0 ]

  local deb="$debs/libv4l-0_1.30.1-1+ceralive1_arm64.deb"
  [ -f "$deb" ]
  [ "$(bash -c 'source "$1"; deb_pkg_name "$2"' bash "$FETCH_DEBS" "$deb")" = "libv4l-0" ]
  [ "$(bash -c 'source "$1"; deb_pkg_version "$2"' bash "$FETCH_DEBS" "$deb")" = "1.30.1-1+ceralive1" ]
  [ "$(bash -c 'source "$1"; deb_pkg_arch "$2"' bash "$FETCH_DEBS" "$deb")" = "arm64" ]
  [ "$(bash -c 'source "$1"; deb_control_field "$2" Depends' bash "$FETCH_DEBS" "$deb")" = "libv4l-0t64" ]

  bash -c 'source "$1"; explode_deb "$2" "$3"' bash "$FETCH_DEBS" "$deb" "$root"
  [ "$(find "$root" -type f | wc -l)" -eq 0 ]
  [ "$(find "$root" -type l | wc -l)" -eq 1 ]
  local link="$root/usr/share/libv4l-0-compat/libv4l2.so.0.0.0"
  [ -L "$link" ]
  [ "$(readlink "$link")" = "/usr/lib/aarch64-linux-gnu/libv4l2.so.0.0.0" ]

  grep -Fq 'work="$(mktemp -d "${debs}/.libv4l-0-compat.XXXXXX")"' \
    "$REPO_ROOT/lib/fetch/userspace.sh"
  grep -Fq 'tmp="${work}/libv4l-0.deb"' \
    "$REPO_ROOT/lib/fetch/userspace.sh"
  run ! grep -Fq 'tmp="${out}.tmp"' "$REPO_ROOT/lib/fetch/userspace.sh"
}

@test "RK3588 multimedia config: libv4l-0 compat is staged and named first in the platform transaction" {
  local userspace="$REPO_ROOT/lib/fetch/userspace.sh"
  local partition="$REPO_ROOT/lib/stages/partition.sh"
  local platform="$REPO_ROOT/mkosi/mkosi.images/platform/mkosi.postinst"

  grep -Fq 'build_libv4l0_compat_deb "${debs}"' "$userspace"
  grep -Eq 'bsp_names=.*libv4l-0' "$partition"
  grep -Fq 'compat_pkgs+=(libv4l-0)' "$platform"
  grep -Fq 'mkosi-install -y --no-install-recommends "${compat_pkgs[@]}" "${hw_gst[@]}" "${gst_runtime[@]}"' "$platform"
}

@test "wwan: the check asserts a .deb extractor (dpkg-deb or ar+tar) is available" {
  # with a normal PATH the assertion passes (ar + tar are on the host)
  run bash -c "source '$CHECK_WWAN'; wwan_assert_deb_tools"
  [ "$status" -eq 0 ]
  # with an empty PATH (no dpkg-deb, no ar/tar) it fails loudly and names the tools
  run bash -c "source '$CHECK_WWAN'; PATH='' wwan_assert_deb_tools"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ar"* ]]
  [[ "$output" == *"tar"* ]]
}

# ===========================================================================
# 19. fetch-debs defensive guards (Task 23) — REPOS integrity + apt URL scheme.
#     fetch-debs.sh asserts the sacred device REPOS constant (a `die` that can
#     ONLY fire on a wrong EDIT, never on a valid run) and WARNS — never dies —
#     when APT_CERALIVE_URL is not https:// (legitimate local/dev http:// overrides
#     must keep working; the fetch path gains no new failure mode). These tests
#     source the helpers directly (main is BASH_SOURCE-guarded) — no apt, no .deb.
# ===========================================================================

@test "fetch-debs REPOS guard: a REPOS without the sacred device entries trips the assert (die, non-zero)" {
  run bash -c "source '$FETCH_DEBS'; REPOS=(cerastream CeraUI); assert_repos_integrity 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"REPOS integrity"* ]]
}

@test "fetch-debs registry defaults to this checkout instead of the parent workspace" {
  run env -u VERSIONS_YAML bash -c "source '$FETCH_DEBS'; realpath \"\$VERSIONS_YAML\""
  [ "$status" -eq 0 ]
  [ "$output" = "$REPO_ROOT/versions.yaml" ]
}

@test "fetch-debs CeraUI registry pin matches the concrete device package release" {
  local expected_ceraui_pin="v2026.8.7"
  local arch expected_device_version device_version

  [ "$(get_pin CeraUI)" = "$expected_ceraui_pin" ]
  for arch in amd64 arm64; do
    case "$arch" in
      amd64) expected_device_version="2026.8.7-20260829T223639.e955538" ;;
      arm64) expected_device_version="2026.8.7-20260829T223625.e955538" ;;
    esac
    device_version="$(ARCH="$arch" bash -c 'source "$1" >/dev/null; first_party_pinned_version ceralive-device' _ "$FETCH_DEBS")"
    [ "$device_version" = "$expected_device_version" ]
    [[ "$device_version" == "${expected_ceraui_pin#v}-"* ]]
  done
}

@test "fetch-debs srt pin ships libsrt1.5-ceralive bundling /usr/bin/srt-live-transmit" {
  # srt 1.5.6+ceralive.1 (upstream v1.5.6 KMREQ CVE fixes, built off master) still
  # bundles srt-live-transmit into the EXISTING libsrt1.5-ceralive .deb (PR #18 "Path A"),
  # linked against the same shared GnuTLS libsrt.so.1.5 (single-libsrt invariant) — so it
  # needs NO new FIRST_PARTY_APT_PKGS entry, only the version bump. Live + GPG-signed on
  # apt.ceralive.tv (arm64+amd64).
  local expected_srt_pin="v1.5.6+ceralive.1"
  [ "$(get_pin srt)" = "$expected_srt_pin" ]
  local libsrt_version
  libsrt_version="$(awk -F= '$1 == "libsrt1.5-ceralive" { print $2; exit }' \
    "$REPO_ROOT/manifests/first-party-deb-versions.txt")"
  [ "$libsrt_version" = "${expected_srt_pin#v}" ]
  # The rootfs build/install-test asserts the bundled tool actually lands on-device.
  grep -Fq '/usr/bin/srt-live-transmit' "$PIPELINE_DIR/tests/realhw-smoke.sh"
}

@test "fetch-debs BSP set deduplicates the first family package against board overrides" {
  local family="$BATS_TEST_TMPDIR/family.yaml"
  local pins="$BATS_TEST_TMPDIR/bsp-versions.txt"
  cat >"$family" <<'YAML'
armbian_branch: vendor
kernel_packages:
  - linux-image-test
dtb_packages:
  - linux-dtb-test
uboot_packages: []
firmware_packages:
  - firmware-test
hw_accel_gstreamer_plugins: []
gstreamer_runtime_packages: []
YAML
  cat >"$pins" <<'PINS'
linux-image-test=1.0
linux-dtb-test=1.0
firmware-test=1.0
u-boot-test=1.0
PINS

  run bash -c "{ export DRY_RUN=1 BSP_DEB_VERSIONS_FILE='$pins' KERNEL_PACKAGES=linux-image-test DTB_PACKAGES=linux-dtb-test UBOOT_PACKAGES=u-boot-test FIRMWARE_PACKAGES=firmware-test; source '$FETCH_DEBS'; fetch_bsp '$family' '$BATS_TEST_TMPDIR/debs'; } 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"(4 pkgs): linux-image-test linux-dtb-test firmware-test u-boot-test"* ]]
  [[ "$output" == *"BSP apt specs: linux-image-test=1.0 linux-dtb-test=1.0 firmware-test=1.0 u-boot-test=1.0"* ]]
}

# ===========================================================================
# 19b. RK3588 HW-accel userspace fetch (pinned URL + SHA-256) —
#      fetch_rk3588_userspace stages ONLY the pinned userspace packages the
#      resolved family declares (Mali blob / MPP / RGA / gst-rockchip / config),
#      and fetch_bsp EXCLUDES exactly that set from the Armbian fetch because the
#      Armbian bookworm arm64 feed does NOT carry them. DRY_RUN logs the exact
#      pinned URL + hash and stages nothing. Self-contained: temp pin files, no
#      network (DRY_RUN plan-only).
# ===========================================================================

@test "fetch-debs RK3588 userspace: DRY_RUN logs the pinned URL + sha and stages no .deb" {
  local family="$BATS_TEST_TMPDIR/family.yaml"
  local pins="$BATS_TEST_TMPDIR/userspace.txt"
  mkdir -p "$BATS_TEST_TMPDIR/debs"
  cat >"$family" <<'YAML'
armbian_branch: vendor
kernel_packages:
  - linux-image-test
dtb_packages: []
uboot_packages: []
firmware_packages:
  - libmali-test
hw_accel_gstreamer_plugins: []
gstreamer_runtime_packages: []
YAML
  cat >"$pins" <<'PINS'
libmali-test  libmali-test_1.0_arm64.deb  0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef  https://example.invalid/libmali-test_1.0_arm64.deb
PINS
  run bash -c "{ export DRY_RUN=1 ARCH=arm64 RK3588_USERSPACE_DEB_VERSIONS_FILE='$pins' KERNEL_PACKAGES=linux-image-test FIRMWARE_PACKAGES=libmali-test; source '$FETCH_DEBS'; fetch_rk3588_userspace '$family' '$BATS_TEST_TMPDIR/debs'; } 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RK3588 userspace set from"* ]]
  [[ "$output" == *"libmali-test"* ]]
  [[ "$output" == *"https://example.invalid/libmali-test_1.0_arm64.deb"* ]]
  [[ "$output" == *"DRY-RUN would run:"* ]]
  # plan-only: not one .deb was staged
  run bash -c "shopt -s nullglob; f=('$BATS_TEST_TMPDIR/debs'/*.deb); echo \${#f[@]}"
  [ "$output" -eq 0 ]
}

@test "fetch-debs RK3588 userspace: fetch_bsp EXCLUDES pinned userspace pkgs from the Armbian set" {
  local family="$BATS_TEST_TMPDIR/family.yaml"
  local bsp_pins="$BATS_TEST_TMPDIR/bsp.txt"
  local us_pins="$BATS_TEST_TMPDIR/userspace.txt"
  cat >"$family" <<'YAML'
armbian_branch: vendor
kernel_packages:
  - linux-image-test
dtb_packages: []
uboot_packages: []
firmware_packages:
  - armbian-firmware
  - libmali-test
hw_accel_gstreamer_plugins:
  - gst-rockchip-test
gstreamer_runtime_packages: []
YAML
  cat >"$bsp_pins" <<'PINS'
linux-image-test=1.0
armbian-firmware=1.0
PINS
  cat >"$us_pins" <<'PINS'
libmali-test  libmali-test_1.0_arm64.deb  0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef  https://example.invalid/libmali-test_1.0_arm64.deb
gst-rockchip-test  gst-rockchip-test_1.0_arm64.deb  fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210  https://example.invalid/gst-rockchip-test_1.0_arm64.deb
PINS
  run bash -c "{ export DRY_RUN=1 ARCH=arm64 BSP_DEB_VERSIONS_FILE='$bsp_pins' RK3588_USERSPACE_DEB_VERSIONS_FILE='$us_pins' KERNEL_PACKAGES=linux-image-test FIRMWARE_PACKAGES='armbian-firmware libmali-test' HW_ACCEL_GSTREAMER_PLUGINS=gst-rockchip-test; source '$FETCH_DEBS'; fetch_bsp '$family' '$BATS_TEST_TMPDIR/debs'; } 2>&1"
  [ "$status" -eq 0 ]
  # the pinned userspace names never enter the Armbian BSP set / apt specs
  [[ "$output" != *"libmali-test"* ]]
  [[ "$output" != *"gst-rockchip-test"* ]]
  # the real Armbian BSP packages DO
  [[ "$output" == *"BSP set from"* ]]
  [[ "$output" == *"linux-image-test"* ]]
  [[ "$output" == *"armbian-firmware"* ]]
}

@test "fetch-debs RK3588 userspace: a family declaring no pinned userspace pkg fetches nothing" {
  local family="$BATS_TEST_TMPDIR/family.yaml"
  local us_pins="$BATS_TEST_TMPDIR/userspace.txt"
  cat >"$family" <<'YAML'
armbian_branch: none
kernel_packages: []
dtb_packages: []
uboot_packages: []
firmware_packages: []
hw_accel_gstreamer_plugins: []
gstreamer_runtime_packages: []
YAML
  cat >"$us_pins" <<'PINS'
libmali-test  libmali-test_1.0_arm64.deb  0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef  https://example.invalid/libmali-test_1.0_arm64.deb
PINS
  run bash -c "{ export DRY_RUN=1 ARCH=x86-64 RK3588_USERSPACE_DEB_VERSIONS_FILE='$us_pins'; source '$FETCH_DEBS'; fetch_rk3588_userspace '$family' '$BATS_TEST_TMPDIR/debs'; } 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"declares no pinned userspace package"* ]]
}

@test "fetch-debs URL guard: a non-HTTPS APT_CERALIVE_URL WARNS but does NOT die (sourcing proceeds)" {
  run bash -c "{ export APT_CERALIVE_URL=http://localhost:8080; source '$FETCH_DEBS' && echo SOURCED_OK; } 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not https"* ]]
  [[ "$output" == *"SOURCED_OK"* ]]
}

# ===========================================================================
# 20. fetch-debs DRY_RUN reliability (Task 24) — fetch_first_party under DRY_RUN
#     logs the EXACT planned `apt-get download` and stages NOTHING. This locks the
#     "plan-only, no side effects" contract that the run_or_plan / NO-`|| true`
#     design rule (common.sh) and the CI build-matrix (DRY_RUN=1) depend on. The
#     test sources the helper directly (main is BASH_SOURCE-guarded) — no apt.
# ===========================================================================

@test "fetch-debs DRY_RUN: fetch_first_party logs the planned apt-get download and stages no .deb" {
  local debs="$BATS_TEST_TMPDIR/debs"
  mkdir -p "$debs"
  run bash -c "{ export DRY_RUN=1 VERSIONS_YAML='$VERSIONS_YAML'; source '$FETCH_DEBS'; fetch_first_party '$debs'; } 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN would run:"* ]]
  [[ "$output" == *"download"* ]]
  [[ "$output" == *"cerastream"* ]]
  [[ "$output" == *"gstreamer1.0-libuvch264src"* ]]
  [[ "$output" == *"ceralive-device"* ]]
  [[ "$output" == *"srtla-send-rs"* ]]
  # and NOT ONE .deb was staged (plan-only, zero side effects)
  run bash -c "shopt -s nullglob; f=('$debs'/*.deb); echo \${#f[@]}"
  [ "$output" -eq 0 ]
}

@test "first-party validation: ceralive-modem-support Architecture: all accepts one artifact for arm64 and amd64" {
  command -v dpkg-deb >/dev/null || skip "dpkg-deb is required to build the fixture"
  local root="$BATS_TEST_TMPDIR/arch-all-allowed"
  local debs="$root/debs"
  mkdir -p "$root/pkg/DEBIAN" "$debs"
  cat >"$root/pkg/DEBIAN/control" <<'CONTROL'
Package: ceralive-modem-support
Version: 1.0.0
Architecture: all
Maintainer: Test <test@example.invalid>
Description: fixture
CONTROL
  dpkg-deb --build "$root/pkg" "$debs/ceralive-modem-support_1.0.0_all.deb" >/dev/null
  local deb="$debs/ceralive-modem-support_1.0.0_all.deb" digest
  digest="$(sha256sum "$deb" | awk '{print $1}')"

  run env ARCH=arm64 bash -c '
    source "$1"
    FIRST_PARTY_APT_PKGS=(ceralive-modem-support)
    validate_first_party_staged_debs "$2" ceralive-modem-support=1.0.0
  ' bash "$FETCH_DEBS" "$debs"
  [ "$status" -eq 0 ]

  run env ARCH=amd64 bash -c '
    source "$1"
    FIRST_PARTY_APT_PKGS=(ceralive-modem-support)
    validate_first_party_staged_debs "$2" ceralive-modem-support=1.0.0
  ' bash "$FETCH_DEBS" "$debs"
  [ "$status" -eq 0 ]
  [ "$(sha256sum "$deb" | awk '{print $1}')" = "$digest" ]
}

@test "first-party validation: arch-dependent package still rejects an architecture mismatch" {
  command -v dpkg-deb >/dev/null || skip "dpkg-deb is required to build the fixture"
  local root="$BATS_TEST_TMPDIR/arch-dependent"
  local debs="$root/debs"
  mkdir -p "$root/pkg/DEBIAN" "$debs"
  cat >"$root/pkg/DEBIAN/control" <<'CONTROL'
Package: cerastream
Version: 1.0.0
Architecture: arm64
Maintainer: Test <test@example.invalid>
Description: fixture
CONTROL
  dpkg-deb --build "$root/pkg" "$debs/cerastream_1.0.0_arm64.deb" >/dev/null

  run env ARCH=amd64 bash -c '
    source "$1"
    FIRST_PARTY_APT_PKGS=(cerastream)
    validate_first_party_staged_debs "$2" cerastream=1.0.0
  ' bash "$FETCH_DEBS" "$debs"
  [ "$status" -ne 0 ]
  [[ "$output" == *"staged package identity mismatch for cerastream"* ]]
}

@test "first-party validation: an unallowlisted Architecture: all package is rejected" {
  command -v dpkg-deb >/dev/null || skip "dpkg-deb is required to build the fixture"
  local root="$BATS_TEST_TMPDIR/arch-all-rejected"
  local debs="$root/debs"
  mkdir -p "$root/pkg/DEBIAN" "$debs"
  cat >"$root/pkg/DEBIAN/control" <<'CONTROL'
Package: unrelated-all-package
Version: 1.0.0
Architecture: all
Maintainer: Test <test@example.invalid>
Description: fixture
CONTROL
  dpkg-deb --build "$root/pkg" "$debs/unrelated-all-package_1.0.0_all.deb" >/dev/null

  run env ARCH=amd64 bash -c '
    source "$1"
    FIRST_PARTY_APT_PKGS=(unrelated-all-package)
    validate_first_party_staged_debs "$2" unrelated-all-package=1.0.0
  ' bash "$FETCH_DEBS" "$debs"
  [ "$status" -ne 0 ]
  [[ "$output" == *"staged package identity mismatch for unrelated-all-package"* ]]
}

# ===========================================================================
# 22. apt.ceralive.tv repo correctness (T2.6) — the customize module
#     apt-ceralive-repo.sh writes the device's own apt source (deb822 with a
#     Signed-By keyring), installs the GPG keyring from env-injected
#     APT_GPG_PUBLIC_B64 (the empty-keyring placeholder is a DEV-ONLY branch that
#     MUST NOT ship in a credentialed build), and pins the apt.ceralive.tv origin
#     at Pin-Priority 990 so OUR first-party updates win for the packages the
#     origin carries while the rest of the Debian archive keeps its 500 default.
#     These drive the SHIPPED functions (sourced with APT_CERALIVE_REPO_NO_AUTORUN=1
#     so the chroot auto-run is suppressed) against scratch dirs
#     (APT_SOURCES_DIR / APT_PREFERENCES_DIR / APT_KEYRING_FILE) — no chroot, no
#     image, UNIT scope. Secret VALUES are never echoed: the keyring fixture is a
#     synthetic non-secret payload whose bytes are asserted ABSENT from output.
# ===========================================================================

@test "apt ceralive (T2.6): ceralive.sources is written with a Signed-By keyring reference" {
  local dir="$BATS_TEST_TMPDIR/apt-src/sources.list.d"
  run env APT_CERALIVE_REPO_NO_AUTORUN=1 APT_SOURCES_DIR="$dir" \
    bash -c "source '$APT_CERALIVE_REPO'; configure_ceralive_source"
  [ "$status" -eq 0 ]
  [ -f "$dir/ceralive.sources" ]
  grep -q '^Signed-By: /usr/share/keyrings/ceralive-archive-keyring.gpg$' "$dir/ceralive.sources"
  grep -q '^URIs: https://apt.ceralive.tv/' "$dir/ceralive.sources"
  printf '%s\n' "$output"
}

@test "apt ceralive (T2.6): a credentialed build installs a NON-EMPTY keyring, never the empty placeholder" {
  local root="$BATS_TEST_TMPDIR/apt-keyring"
  mkdir -p "$root"
  local keyring="$root/ceralive-archive-keyring.gpg"
  local payload="SYNTHETIC-NON-SECRET-KEYRING-BYTES"
  local b64; b64="$(printf '%s' "$payload" | base64 -w0)"
  run env APT_CERALIVE_REPO_NO_AUTORUN=1 APT_KEYRING_FILE="$keyring" \
    APT_GPG_PUBLIC_B64="$b64" \
    bash -c "source '$APT_CERALIVE_REPO'; install_gpg_keyring"
  [ "$status" -eq 0 ]
  [ -s "$keyring" ]
  [[ "$output" != *"$b64"* ]]
  [[ "$output" != *"$payload"* ]]

  local placeholder="$root/placeholder.gpg"
  run env -u APT_GPG_PUBLIC_B64 APT_CERALIVE_REPO_NO_AUTORUN=1 APT_KEYRING_FILE="$placeholder" \
    bash -c "source '$APT_CERALIVE_REPO'; install_gpg_keyring"
  [ "$status" -eq 0 ]
  [ ! -s "$placeholder" ]
  [[ "$output" == *"empty placeholder"* ]]
}

@test "apt ceralive (T2.6): the apt.ceralive.tv origin is pinned at Pin-Priority 990" {
  local dir="$BATS_TEST_TMPDIR/apt-prefs/preferences.d"
  run env APT_CERALIVE_REPO_NO_AUTORUN=1 APT_PREFERENCES_DIR="$dir" \
    bash -c "source '$APT_CERALIVE_REPO'; install_apt_preferences"
  [ "$status" -eq 0 ]
  [ -f "$dir/ceralive" ]
  grep -q '^Package: \*$' "$dir/ceralive"
  grep -q '^Pin: origin apt.ceralive.tv$' "$dir/ceralive"
  grep -q '^Pin-Priority: 990$' "$dir/ceralive"
  grep -q '^  install_apt_preferences$' "$APT_CERALIVE_REPO"
  printf '%s\n' "$output"
}

# The guard ABOVE proves the customize MODULE (apt-ceralive-repo.sh) pins the origin
# — but `./build` never runs that module; it runs the runtime executor
# (mkosi.postinst.chroot::setup_ceralive_repository). Todo 8's pin shipped absent
# from real images precisely because only the module was tested. This guard drives
# the REAL build-path function against a scratch chroot filesystem and asserts the
# pin is baked there.
@test "apt ceralive (T2.6): the RUNTIME EXECUTOR (the ./build path) bakes the 990 origin pin" {
  run bash "$TESTS_DIR/apt-preferences-baked.test.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Part A static contract OK"* ]]
  [[ "$output" == *"regression: PASS"* ]]
  printf '%s\n' "$output"
}

# The RUNTIME EXECUTOR (./build path) must ALSO hand the mTLS client.key to the
# _apt sandbox user (else apt-get update dies "Could not load client certificate"),
# dedupe to exactly ONE Debian source (else "configured multiple times" warnings),
# and write an arch-qualified apt.ceralive.tv URI (else the Release file 404s).
@test "apt ceralive (T2.6): the build path makes client.key _apt-readable and dedupes Debian sources" {
  run bash "$TESTS_DIR/apt-mtls-and-dedupe.test.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Part A static contract OK"* ]]
  [[ "$output" == *"regression: PASS"* ]]
  printf '%s\n' "$output"
}

# The build path must normalize the armored CI secret before the runtime executor
# writes it: the device carries apt/gpgv, not gpg or file(1).
@test "apt ceralive (T2.6): the build dearmors its keyring and the RUNTIME EXECUTOR consumes binary input" {
  command -v gpg >/dev/null || skip "gpg is required for the synthetic OpenPGP fixture"
  command -v file >/dev/null || skip "file is required for the keyring-magic guard"
  unshare -rm --map-root-user true 2>/dev/null || skip "rootless mount namespaces are required"

  local fixture_home="$BATS_TEST_TMPDIR/apt-keyring-gnupg"
  local armored="$BATS_TEST_TMPDIR/ceralive-archive-keyring.asc"
  local repro="$BATS_TEST_TMPDIR/runtime-keyring-repro.sh"
  local dearmor="$PIPELINE_DIR/lib/dearmor-apt-keyring.sh"
  mkdir -m 700 "$fixture_home"
  run gpg --batch --homedir "$fixture_home" --passphrase '' \
    --quick-generate-key 'CeraLive test archive <test-archive@example.invalid>' ed25519 sign 1d
  [ "$status" -eq 0 ]
  run gpg --batch --homedir "$fixture_home" --armor --export test-archive@example.invalid
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" >"$armored"

  local armored_b64 binary_b64
  armored_b64="$(base64 -w0 "$armored")"
  run env APT_GPG_PUBLIC_B64="$armored_b64" "$dearmor"
  [ "$status" -eq 0 ]
  binary_b64="$output"
  printf '%s' "$binary_b64" | base64 -d >"$BATS_TEST_TMPDIR/build-keyring.gpg"
  run file -b "$BATS_TEST_TMPDIR/build-keyring.gpg"
  [ "$status" -eq 0 ]
  [[ "$output" == OpenPGP\ Public\ Key\ Version* ]]
  local binary_magic="$output"

  run env APT_GPG_PUBLIC_B64="$binary_b64" "$dearmor"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | base64 -d >"$BATS_TEST_TMPDIR/reaccepted-binary-keyring.gpg"
  run file -b "$BATS_TEST_TMPDIR/reaccepted-binary-keyring.gpg"
  [ "$status" -eq 0 ]
  [[ "$output" == "$binary_magic" ]]

  run env APT_GPG_PUBLIC_B64='@@@@' "$dearmor"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not decode APT_GPG_PUBLIC_B64"* ]]

  local fake_bin="$BATS_TEST_TMPDIR/fake-gpg"
  mkdir -p "$fake_bin"
  cat >"$fake_bin/gpg" <<'FAKE_GPG'
#!/usr/bin/env bash
set -euo pipefail
output=''
input=''
while (( $# )); do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    *) input="$1"; shift ;;
  esac
done
cat "$input" >"$output"
FAKE_GPG
  chmod +x "$fake_bin/gpg"
  run env PATH="$fake_bin:$PATH" APT_GPG_PUBLIC_B64="$armored_b64" "$dearmor"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a binary OpenPGP public key (PGP public key block Public-Key (old))"* ]]

  cat >"$repro" <<'REPRO'
set -euo pipefail
postinst="$1"
key_b64="$2"
work="$3"
final=/usr/share/keyrings/ceralive-archive-keyring.gpg
expected="$work/expected-runtime-keyring.gpg"
old="$work/old-runtime-keyring.gpg"

extract_fn() {
  awk -v fn="$1" '
    $0 ~ "^" fn "\\(\\) \\{" { found=1 }
    found { print }
    found && /^}/ { exit }
  ' "$2"
}

mkdir -p "$work/bin"
mount -t tmpfs tmpfs /etc
mount -t tmpfs tmpfs /usr/share
mkdir -p /etc/opt/ceralive /etc/apt/certs /etc/apt/apt.conf.d /etc/apt/sources.list.d \
  /etc/apt/preferences.d /usr/share/keyrings
cat >"$work/bin/dpkg" <<'DPKG'
#!/usr/bin/env bash
printf 'amd64\n'
DPKG
chmod +x "$work/bin/dpkg"
export PATH="$work/bin:$PATH"

printf '%s' "$key_b64" | base64 -d >"$expected"
printf '\x00old-ceralive-keyring\xff\n' >"$old"

fail() {
  printf 'runtime-keyring regression: FAIL: %s\n' "$*" >&2
  exit 1
}

assert_no_temp() {
  local leaked
  leaked="$(find /usr/share/keyrings -maxdepth 1 -type f \
    -name 'ceralive-archive-keyring.gpg.??????' -print -quit)"
  [[ -z "$leaked" ]] || fail "$1 left temporary keyring $leaked"
}

seed_old() {
  cp "$old" "$final"
  old_sha="$(sha256sum "$final" | awk '{print $1}')"
}

assert_old_preserved() {
  local actual_sha
  [[ -f "$final" ]] || fail "$1 removed the pre-existing final keyring"
  actual_sha="$(sha256sum "$final" | awk '{print $1}')"
  [[ "$actual_sha" == "$old_sha" ]] \
    || fail "$1 changed the pre-existing final keyring: expected $old_sha, got $actual_sha"
  cmp -s "$old" "$final" || fail "$1 changed the pre-existing final keyring bytes"
  assert_no_temp "$1"
  printf 'runtime-keyring: %s preserved old sha256=%s and cleaned temp\n' "$1" "$actual_sha"
}

log() { printf '[runtime-test] %s\n' "$*" >&2; }
eval "$(extract_fn setup_ceralive_repository "$postinst")"
CHANNEL=stable

seed_old
APT_GPG_PUBLIC_B64='@@@@'
if setup_ceralive_repository; then
  fail "malformed base64 unexpectedly succeeded"
fi
assert_old_preserved "decode failure"

cat >"$work/bin/mktemp" <<'MKTEMP'
#!/usr/bin/env bash
exit 74
MKTEMP
chmod +x "$work/bin/mktemp"
seed_old
APT_GPG_PUBLIC_B64="$key_b64"
if setup_ceralive_repository; then
  fail "temporary preparation failure unexpectedly succeeded"
fi
assert_old_preserved "temporary preparation failure"
rm -f "$work/bin/mktemp"
hash -r

cat >"$work/bin/mv" <<'MV'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == "-f" && "$2" == "--" && "$#" -eq 4 ]]
source_path="$3"
final_path="$4"
[[ "$final_path" == /usr/share/keyrings/ceralive-archive-keyring.gpg ]]
cmp -s "$TEST_EXPECTED_KEYRING" "$source_path"
[[ "$(stat -c '%a' "$source_path")" == 644 ]]
[[ "$(stat -c '%u:%g' "$source_path")" == 0:0 ]]
printf 'prepared source bytes, mode, and owner verified\n' >"$TEST_MV_MARKER"
exit 73
MV
chmod +x "$work/bin/mv"
seed_old
export TEST_EXPECTED_KEYRING="$expected"
export TEST_MV_MARKER="$work/mv-preparation-verified"
APT_GPG_PUBLIC_B64="$key_b64"
if setup_ceralive_repository; then
  fail "final replacement failure unexpectedly succeeded"
fi
[[ -s "$TEST_MV_MARKER" ]] \
  || fail "final replacement failure was not injected after full temporary preparation"
assert_old_preserved "final replacement failure"
rm -f "$work/bin/mv"
hash -r

APT_GPG_PUBLIC_B64="$key_b64"
setup_ceralive_repository
cmp -s "$expected" "$final" || fail "successful handoff published unexpected bytes"
[[ "$(stat -c '%a' "$final")" == 644 ]] || fail "successful handoff mode is not 0644"
[[ "$(stat -c '%u:%g' "$final")" == 0:0 ]] || fail "successful handoff owner is not root:root"
assert_no_temp "successful handoff"
cp "$final" "$work/runtime-keyring.gpg"
printf 'runtime-keyring: success published expected bytes mode=0644 owner=root:root and cleaned temp\n'
REPRO

  run unshare -rm --map-root-user bash "$repro" "$PIPELINE_DIR/mkosi/mkosi.images/runtime/mkosi.postinst.chroot" \
    "$binary_b64" "$BATS_TEST_TMPDIR"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
  [[ "$output" != *"$binary_b64"* ]]
  run file -b "$BATS_TEST_TMPDIR/runtime-keyring.gpg"
  [ "$status" -eq 0 ]
  [[ "$output" == OpenPGP\ Public\ Key\ Version* ]]
  [[ "$output" == "$binary_magic" ]]

  local runtime_fn
  runtime_fn="$(awk '/^setup_ceralive_repository\(\) \{/{f=1} f{print} f && /^}/{exit}' "$PIPELINE_DIR/mkosi/mkosi.images/runtime/mkosi.postinst.chroot")"
  [[ "$runtime_fn" == *'mv -f -- "${keyring_tmp}" /usr/share/keyrings/ceralive-archive-keyring.gpg'* ]]
  [[ "$runtime_fn" != *'install -m 0644 "${keyring_tmp}" /usr/share/keyrings/ceralive-archive-keyring.gpg'* ]]
  [[ "$runtime_fn" != *"gpg --"* ]]
  [[ "$runtime_fn" != *"file -b"* ]]
  grep -q 'DEARMOR_APT_KEYRING_SH=' "$PIPELINE_DIR/lib/orchestrate.sh"
  # DEARMOR_APT_KEYRING_SH is resolved by the orchestrator entry; both call sites
  # are in the [5/9] mkosi module, so read that file or match nothing.
  grep -q 'APT_GPG_PUBLIC_B64="$("${DEARMOR_APT_KEYRING_SH}")"' "$PIPELINE_DIR/lib/stages/mkosi.sh"
  grep -q '/work/lib/dearmor-apt-keyring.sh' "$PIPELINE_DIR/lib/stages/mkosi.sh"
  local failing_container_helper="$BATS_TEST_TMPDIR/failing-container-dearmor"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 37' >"$failing_container_helper"
  chmod +x "$failing_container_helper"
  local container_prepare
  container_prepare="$(awk '
    /if \[\[ -n "\$\{APT_GPG_PUBLIC_B64:-\}" \]\]; then/ { found=1 }
    found { print }
    found && /^[[:space:]]*fi$/ { exit }
  ' "$PIPELINE_DIR/lib/stages/mkosi.sh")"
  [[ "$container_prepare" == *'/work/lib/dearmor-apt-keyring.sh'* ]]
  run env APT_GPG_PUBLIC_B64='must-fail' bash -euo pipefail -c "${container_prepare//\/work\/lib\/dearmor-apt-keyring.sh/$failing_container_helper}"$'\nprintf "mkosi_started=yes\\n"'
  [ "$status" -eq 1 ]
  [[ "$output" == *'could not prepare the binary CeraLive apt keyring for mkosi'* ]]
  [[ "$output" != *'mkosi_started=yes'* ]]
  local passing_container_helper="$BATS_TEST_TMPDIR/passing-container-dearmor"
  printf '%s\n' '#!/usr/bin/env bash' 'printf binary-keyring-b64' >"$passing_container_helper"
  chmod +x "$passing_container_helper"
  run env APT_GPG_PUBLIC_B64='normalizes' bash -euo pipefail -c "${container_prepare//\/work\/lib\/dearmor-apt-keyring.sh/$passing_container_helper}"$'\nprintf "mkosi_started=yes keyring=%s\\n" "$APT_GPG_PUBLIC_B64"'
  [ "$status" -eq 0 ]
  [[ "$output" == 'mkosi_started=yes keyring=binary-keyring-b64' ]]
  grep -Eq '^[[:space:]]+file \\' "$PIPELINE_DIR/ci/Dockerfile"
  grep -Eq '^[[:space:]]+gpg \\' "$PIPELINE_DIR/ci/Dockerfile"
  printf 'binary magic: %s\narmored fixture rejected by build guard\nruntime consumed build-validated binary keyring\n' "$binary_magic"
}

@test "image hygiene: hardware udev rules do not queue the retired optimize unit" {
  # Scope: mkosi SOURCE only. The generated siblings must be excluded, and both
  # exclusions are load-bearing on any machine that has run a real build:
  #   -r not -R — mkosi's cached base rootfs carries absolute symlinks into /dev,
  #     /proc and /run, and -R dereferences them straight out of the repo onto the
  #     host, where one blocking open() on a FIFO or tty hangs the suite forever.
  #   --exclude-dir — that same cache is root-owned and partly mode 0700, so grep
  #     exits 2 (error) instead of 1 (no match) and the assertion below fails even
  #     though nothing matched.
  # CI sees neither because it wipes mkosi/{build,cache} before the job.
  run grep -rE --exclude-dir=cache --exclude-dir=build --exclude-dir=.staging \
    '^[[:space:]]*[^#[:space:]].*(ceralive-optimize@|SYSTEMD_WANTS.*optimize)' "$PIPELINE_DIR/mkosi"
  [ "$status" -eq 1 ]
}

@test "image hygiene: portable check detects a planted retired optimize unit" {
  local fixture="$BATS_TEST_TMPDIR/planted-udev.rules"
  printf '%s\n' 'ACTION=="add", ENV{SYSTEMD_WANTS}="ceralive-optimize@.service"' >"$fixture"

  run grep -E 'ceralive-optimize@|SYSTEMD_WANTS.*optimize' "$fixture"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ceralive-optimize@"* ]]
}

# ===========================================================================
# 27. First-party staging key — producer/consumer agreement across the subimage
#     boundary.
#
#     The orchestrator stages the 14 first-party .debs under the board MANIFEST
#     STEM; the app subimage rebuilds that path from inside its own chroot,
#     because mkosi's --extra-tree never reaches a subimage and the source-mount
#     fallback is the ONLY live delivery route. Keying the consumer off BOARD_ID
#     (the Armbian BOARD= value) made those two agree on rock-5b-plus alone —
#     the one board built regularly — so orange-pi-5-plus installed ZERO
#     first-party packages for a whole release. These tests therefore drive the
#     REAL shipped stager against the REAL shipped manifests, and every leg is
#     paired with a non-vacuity leg, because an identity mapping is exactly what
#     hid the defect.
# ===========================================================================

@test "firstparty-staging: the REAL stager finds the tree for EVERY shipped board manifest" {
  # The producer/consumer contract, exercised end to end per board: lay the tree
  # out exactly as orchestrate.sh does (STAGING_ROOT/<manifest-stem>/firstparty)
  # and hand the stager that board's REAL board_id at the same time, which is
  # what the broken code read. orange-pi-5-plus is the leg that fails on the
  # pre-fix consumer.
  local manifest board board_id divergent=0
  for manifest in "$PIPELINE_DIR"/manifests/boards/*.yaml; do
    board="$(basename "$manifest" .yaml)"
    board_id="$(sed -n 's/^board_id:[[:space:]]*//p' "$manifest" | head -1)"
    [ -n "$board_id" ]
    [ "$board" = "$board_id" ] || divergent=1

    local srcdir="$BATS_TEST_TMPDIR/src-$board"
    local dest="$BATS_TEST_TMPDIR/dest-$board"
    mkdir -p "$srcdir/.staging/$board/firstparty" "$dest"
    make_stub_deb "$srcdir/.staging/$board/firstparty/cerastream_1_arm64.deb" \
      cerastream 1 arm64

    run_source_mount_stager "$srcdir" "$board" "$board_id" "$dest"
    [ "$status" -eq 0 ]
    [ -f "$dest/cerastream_1_arm64.deb" ] \
      || { echo "stager did not deliver for board=$board board_id=$board_id"; false; }
  done

  # NON-VACUITY: at least one shipped board must have stem != board_id, or the
  # whole matrix above is an identity test that passes on the broken consumer.
  [ "$divergent" -eq 1 ]
}

@test "firstparty-staging: a tree staged under BOARD_ID is NOT picked up (the actual defect)" {
  # The inverse of the test above, and the one that would have caught this the
  # day it shipped: with the tree at .staging/<board_id>/ and nothing at
  # .staging/<manifest-stem>/, the stager must deliver NOTHING — proving it
  # follows the orchestrator's key and not the Armbian device identity.
  local board=orange-pi-5-plus
  local board_id
  board_id="$(sed -n 's/^board_id:[[:space:]]*//p' "$PIPELINE_DIR/manifests/boards/$board.yaml" | head -1)"
  [ "$board_id" = orangepi5-plus ]
  [ "$board_id" != "$board" ]

  local srcdir="$BATS_TEST_TMPDIR/src" dest="$BATS_TEST_TMPDIR/dest"
  mkdir -p "$srcdir/.staging/$board_id/firstparty" "$dest"
  make_stub_deb "$srcdir/.staging/$board_id/firstparty/cerastream_1_arm64.deb" \
    cerastream 1 arm64

  run_source_mount_stager "$srcdir" "$board" "$board_id" "$dest"
  [ "$status" -eq 0 ]
  run bash -c "ls '$dest'/*.deb 2>/dev/null"
  [ "$status" -ne 0 ]
}

@test "firstparty-staging: a miss NAMES the probed path instead of returning silently" {
  # The silent `return 0` is why a zero-package image built to completion. An
  # offline/dev build legitimately stages nothing, so this stays non-fatal — but
  # the log line must carry the exact path, which is the entire diagnosis.
  local srcdir="$BATS_TEST_TMPDIR/src" dest="$BATS_TEST_TMPDIR/dest"
  mkdir -p "$srcdir" "$dest"

  run_source_mount_stager "$srcdir" rock-5b-plus rock-5b-plus "$dest"
  [ "$status" -eq 0 ]
  [[ "$output" == *".staging/rock-5b-plus/firstparty"* ]]

  # An unset CERALIVE_BOARD is the PassEnvironment-drift failure mode; it must
  # say so rather than look like an ordinary offline build.
  run_source_mount_stager "$srcdir" "" rock-5b-plus "$dest"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CERALIVE_BOARD"* ]]
}

@test "firstparty-staging: the ExtraTree still wins when it did reach the subimage" {
  # The fallback must stay a fallback: if /opt/ceralive-staging is already
  # populated, the source mount is not consulted at all.
  local srcdir="$BATS_TEST_TMPDIR/src" dest="$BATS_TEST_TMPDIR/dest"
  mkdir -p "$srcdir/.staging/rock-5b-plus/firstparty" "$dest"
  make_stub_deb "$srcdir/.staging/rock-5b-plus/firstparty/from-source_1_arm64.deb" \
    from-source 1 arm64
  make_stub_deb "$dest/from-extratree_1_arm64.deb" from-extratree 1 arm64

  run_source_mount_stager "$srcdir" rock-5b-plus rock-5b-plus "$dest"
  [ "$status" -eq 0 ]
  [ -f "$dest/from-extratree_1_arm64.deb" ]
  [ ! -f "$dest/from-source_1_arm64.deb" ]
}

@test "firstparty-staging: orchestrate.sh exports the SAME key it stages under" {
  # Cross-file agreement, statically. The producer's staging path and the
  # exported key must be the same shell variable, or the two halves drift again.
  local orchestrate="$LIB_DIR/orchestrate.sh"
  grep -Fq 'local staging="${STAGING_ROOT}/${board}"' "$orchestrate"
  grep -Fq 'export CERALIVE_BOARD="${board}"' "$orchestrate"

  # And the per-board mkosi cache stays keyed by BOARD_ID — a DIFFERENT tree for
  # a different purpose, deliberately not aliased onto the staging key.
  grep -Fq 'local cache_dir="cache/${BOARD_ID}"' "$orchestrate"
}

@test "firstparty-staging: the consumer never re-slips to BOARD_ID" {
  # Explicit re-slip guard (same discipline as the hdmi-in DRIVERS== rule): the
  # source-mount path expression must not mention BOARD_ID at all.
  local postinst="$PIPELINE_DIR/mkosi/mkosi.images/app/mkosi.postinst.chroot"
  local fn
  fn="$(sed -n '/^stage_first_party_from_source_mount()/,/^}/p' "$postinst")"
  [ -n "$fn" ]
  [[ "$fn" == *'.staging/${board}/firstparty'* ]]
  [[ "$fn" != *'${BOARD_ID}'* ]]
}

@test "firstparty-staging: CERALIVE_BOARD reaches the app SUBIMAGE (env_names + PassEnvironment)" {
  # Explicit regression pin on top of the structural lockstep guard: this value
  # is consumed inside a subimage chroot, so a name in env_names alone reads
  # EMPTY there — silently — and the stager degrades to installing nothing.
  grep -Eq '^[[:space:]]+CERALIVE_BENCH_LABELS CERALIVE_BOARD$' "$LIB_DIR/orchestrate.sh"

  local pass_names
  pass_names="$(sed -n 's/^PassEnvironment=//p' "$PIPELINE_DIR/mkosi/mkosi.conf")"
  [ -n "$pass_names" ]

  local n found=0
  for n in $pass_names; do
    [ "$n" = CERALIVE_BOARD ] && found=1
  done
  [ "$found" -eq 1 ]
}

# ===========================================================================
# 28. Mesa software-GL prune — the RemoveFiles contract.
#
#     `gstreamer1.0-plugins-bad` reaches `libgl1-mesa-dri`, which reaches Mesa's
#     Gallium megadriver, LLVM's JIT and Z3 for a software rasterizer the device
#     can never execute — no base-image component instantiates a GL element, and
#     the only other Mesa entry point needs an X server this image does not ship.
#     (Historically the argument also leaned on libmali's stubs winning the
#     EGL/GLES/GBM lookup; that blob went with the vendor kernel track, and the
#     no-GL-consumer half of the argument stands on its own.) `apt remove`
#     cascades into the plugin set cerastream needs, so the lever is file-level,
#     like the locale strip.
#
#     RETARGETED AT THE TRIXIE MIGRATION (todo 10). Trixie ships Mesa 25.0.7 and
#     LLVM 19, and BOTH previous globs went stale in ways that fail SILENTLY:
#     `libLLVM-15.so*` matches nothing (the real object is `libLLVM.so.19.1`),
#     and the Gallium megadriver moved out of `libgl1-mesa-dri` entirely into a
#     new `mesa-libgallium` package as `libgallium-<version>.so` at the library
#     root, which no glob covered. Unfixed the prune recovers ~27 MB instead of
#     ~185 MB and both RK3588 boards blow the 1.5 GB `[6c/9]` gate.
#
#     These are STATIC guards because the prune only happens on a wet build and
#     the PR gate is DRY_RUN=1 plan-only — the same blind spot that shipped the
#     OPi DTB name and the four kernel-from-source defects. The dri glob leg is
#     the one that matters most: libva resolves VA-API drivers as
#     `<name>_drv_video.so` out of the SAME directory, so widening the glob to
#     `dri/*` would silently delete a hardware video driver on a future x86 build.
# ===========================================================================

@test "mesa-prune: the runtime layer strips libgallium, libLLVM, libz3 and the Mesa DRI shims" {
  local entries
  entries="$(removefiles_runtime)"
  [ -n "$entries" ]

  [[ "$entries" == *'/usr/lib/aarch64-linux-gnu/libgallium-*.so'* ]]
  [[ "$entries" == *'/usr/lib/aarch64-linux-gnu/libLLVM*.so*'* ]]
  [[ "$entries" == *'/usr/lib/aarch64-linux-gnu/libz3.so*'* ]]
  [[ "$entries" == *'/usr/lib/aarch64-linux-gnu/dri/*_dri.so'* ]]
}

@test "mesa-prune: the LLVM and Gallium globs are version-WILDCARDED, never pinned" {
  # This is the regression the trixie migration actually caught. A version-pinned
  # glob does not fail loudly when the version moves — it matches zero files, the
  # build stays green, and ~158 MB of unreachable payload ships. `libgallium`'s
  # filename embeds the FULL Debian revision (libgallium-25.0.7-2+deb13u1.so), so
  # a pinned name breaks on any Mesa point release, not just a major bump.
  local entries
  entries="$(removefiles_runtime)"

  # The exact stale spelling that shipped before must never come back.
  [[ "$entries" != *'libLLVM-15.so'* ]]
  # No LLVM/Gallium entry may carry a literal version digit run. The check is on
  # the BASENAME, not the whole path — the `aarch64-linux-gnu` triplet in the
  # directory prefix legitimately contains digits.
  local tok base
  while IFS= read -r tok; do
    base="${tok##*/}"
    case "$base" in
      libLLVM*|libgallium*)
        [[ "$base" != *[0-9]* ]] || {
          echo "version-pinned Mesa/LLVM prune glob: $tok" >&2
          return 1
        }
        ;;
    esac
  done < <(printf '%s\n' "${entries//,/$'\n'}")
}

@test "mesa-prune: the DRI glob never widens to dri/* (it would eat VA-API drivers)" {
  local entries
  entries="$(removefiles_runtime)"
  # libva looks up <name>_drv_video.so in /usr/lib/<triplet>/dri; only the
  # `*_dri.so` suffix may be removed. Reject a bare directory glob outright.
  [[ "$entries" != *'/dri/*,'* ]]
  [[ "$entries" != *'/dri/*' ]]
  [[ "$entries" != *'/dri,'* ]]
}

@test "mesa-prune: the locale strip it shares the key with is not clobbered" {
  # RemoveFiles is ONE comma-separated key; appending to it is exactly how the
  # Task-19 locale entries could be lost without any test noticing.
  local entries
  entries="$(removefiles_runtime)"
  [[ "$entries" == *'/usr/share/locale/*'* ]]
  [[ "$entries" == *'/usr/lib/locale/locale-archive'* ]]

  # And every OTHER layer keeps its own locale strip untouched by this change.
  local layer
  for layer in base platform app; do
    grep -Fq 'RemoveFiles=/usr/share/locale/*,/usr/lib/locale/locale-archive' \
      "$PIPELINE_DIR/mkosi/mkosi.images/$layer/mkosi.conf"
  done
}

@test "mesa-prune: the pruned packages are NOT removed from shared.list or apt" {
  # The whole point of the file-level lever is that the metapackage STAYS
  # installed — `apt remove libgl1-mesa-dri` cascades into gstreamer1.0-plugins-bad,
  # which cerastream needs. Nothing may start uninstalling it.
  local shared="$PIPELINE_DIR/manifests/packages/shared.list"
  grep -Eq '^gstreamer1\.0-plugins-bad$' "$shared"

  local postinst="$PIPELINE_DIR/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"
  run ! grep -Eq 'apt-get[[:space:]]+(-y[[:space:]]+)?(remove|purge)[^|;&]*libgl1-mesa-dri' "$postinst"
  run ! grep -Eq 'apt-get[[:space:]]+(-y[[:space:]]+)?(remove|purge)[^|;&]*(libllvm[0-9]+|libz3-4|mesa-libgallium)' "$postinst"
}

# ===========================================================================
# 28b. Trixie package-list migration — the names that CHANGED (todo 10).
#
#      Every name in shared.list was resolved against a real trixie arm64 index
#      (main+contrib+non-free+non-free-firmware). Exactly two diverged, and both
#      are pinned here because both fail in a way a plan-only PR gate cannot see:
#      a removed package fails at `apt-get install` on a WET build only, and the
#      governor half fails at BOOT with no error at all.
# ===========================================================================

@test "trixie-migration: cpufrequtils is gone and linux-cpupower replaced it" {
  local shared="$PIPELINE_DIR/manifests/packages/shared.list"
  # Debian removed cpufrequtils (out of testing 2023-10-28, unstable 2024-06-16).
  # It has no installation candidate on trixie, so an active entry is a build
  # failure — `E: Unable to locate package cpufrequtils`.
  run ! grep -Eq '^cpufrequtils([[:space:]]|$)' "$shared"
  grep -Eq '^linux-cpupower([[:space:]]|$)' "$shared"
}

@test "trixie-migration: the dead /etc/default/cpufrequtils write is gone from BOTH writers" {
  # linux-cpupower ships exactly one file, /usr/bin/cpupower — no init script, no
  # unit, no /etc/default hook — and nothing in trixie reads this path. Keeping
  # the write would be a config file with no reader: a green build, a booting
  # image, and a governor silently never applied. Both the LIVE runtime postinst
  # and its customize twin must be clean.
  #
  # Both files now EXPLAIN the removal in a comment, and that comment necessarily
  # quotes the retired line — so the assertion is on executable text only, with
  # comments stripped. Grepping the raw file would match the explanation and make
  # this test unfixable-by-construction.
  local f code
  for f in "$PIPELINE_DIR/mkosi/mkosi.images/runtime/mkosi.postinst.chroot" \
           "$PIPELINE_DIR/mkosi/customize/sysctl-tuning.sh"; do
    code="$(grep -Ev '^[[:space:]]*#' "$f")"
    [[ "$code" != */etc/default/cpufrequtils* ]]
    [[ "$code" != *GOVERNOR=* ]]
  done
}

@test "trixie-migration: ceralive-cpu-governor is the replacement applier and is wired" {
  # Artifacts exist...
  [ -f "$PIPELINE_DIR/mkosi/runtime/ceralive-cpu-governor.sh" ]
  [ -f "$PIPELINE_DIR/mkosi/runtime/ceralive-cpu-governor.service" ]
  # ...the installer installs and enables both halves...
  local hw="$PIPELINE_DIR/mkosi/customize/postinst.d/hardware.sh"
  grep -q 'setup_cpu_governor()' "$hw"
  grep -q 'ceralive-cpu-governor.sh' "$hw"
  grep -q 'ceralive-cpu-governor.service' "$hw"
  grep -q 'enable_service ceralive-cpu-governor.service' "$hw"
  # ...and configure_services actually calls it (an installed-but-uncalled setup
  # function is the dead-writer trap this repo has already shipped twice).
  grep -q '^[[:space:]]*setup_cpu_governor$' "$PIPELINE_DIR/mkosi/customize/postinst.d/services.sh"
}

@test "trixie-migration: the governor unit pins a governor the encoder wants and writes nothing else" {
  local sh="$PIPELINE_DIR/mkosi/runtime/ceralive-cpu-governor.sh"
  grep -q 'performance' "$sh"
  # It may drive the governor and NOTHING else — the same "move the policy, never
  # replace the kernel's driver" rule setup_fan_curve established. The script's
  # header states that restraint in prose, so the assertion runs on executable
  # text with comments stripped rather than on the raw file.
  local code
  code="$(grep -Ev '^[[:space:]]*#' "$sh")"
  [[ "$code" != *scaling_setspeed* ]]
  [[ "$code" != *scaling_max_freq* ]]
  [[ "$code" != *scaling_min_freq* ]]
  # The only sysfs node it may READ per policy is the governor and its menu.
  [[ "$code" == *scaling_governor* ]]
}

@test "trixie-migration: rauc-hawkbit-updater stays a comment, not an active apt line" {
  # There is still no trixie-native package (verified against the real trixie
  # index with every component enabled); Debian's 1.4-1 reached sid/forky only.
  # An active line here breaks the whole-list install on any host lacking the
  # pre-staged backport.
  local shared="$PIPELINE_DIR/manifests/packages/shared.list"
  run ! grep -Eq '^rauc-hawkbit-updater([[:space:]]|$)' "$shared"
  grep -q 'rauc-hawkbit-updater' "$shared"
}

# ===========================================================================
# 30. Debug/production package split — the CERALIVE_DEBUG_IMAGE variant seam.
#
#     manifests/packages/development.delta.list is the debug-only package set:
#     python3 + strace/tcpdump + the fifteen T17 packages the debug-toolset
#     sysext add-on carries. It is installed ONLY when CERALIVE_DEBUG_IMAGE=1;
#     a production build's package set must stay byte-identical to what todo 31
#     measured and baselined.
#
#     THE TRAP THESE TESTS EXIST FOR: the file shares the `.delta.list` suffix
#     with the two FAMILY deltas because it is the same format, but it is keyed
#     on the BUILD VARIANT instead. Three places in this repo globbed
#     `manifests/packages/*.delta.list` as a directory — lib/parity-check.sh's
#     expected set, tests/realhw-suite.sh's synthesized dpkg status, and this
#     file's own make_parity_rootfs fixture. Left alone, every one of them would
#     have folded 18 debug packages into the PRODUCTION contract: parity-check
#     would fail the [7/9] gate on a correct production image, and the fixture
#     would have hidden it by declaring those packages installed. All three now
#     go through common.sh::runtime_pkg_list_files, which skips the debug delta
#     by name and re-appends it only under the flag.
#
#     Static + real-execution, UNIT scope: no image boot, no orchestrator run.
# ===========================================================================

@test "dev delta: development.delta.list exists and carries exactly the debug-only set" {
  [ -f "$(DEV_DELTA_LIST)" ]
  run diff <(dev_delta_expected) <(active_pkgs_of "$(DEV_DELTA_LIST)")
  [ "$status" -eq 0 ]
}

@test "dev delta: python3 is in the delta and NOT in the production shared list" {
  # python3 is the content-diff probe for the two variants: a real production
  # rootfs has 552 installed packages and zero python3*, so its presence is an
  # unambiguous signal that the debug branch actually took effect.
  run grep -Ex 'python3[[:space:]]*(#.*)?' "$(DEV_DELTA_LIST)"
  [ "$status" -eq 0 ]
  run grep -qxF python3 <(active_pkgs_of "$PIPELINE_DIR/manifests/packages/shared.list")
  [ "$status" -ne 0 ]
}

@test "dev delta: no package is duplicated from shared.list or a family delta" {
  # A duplicate would make "debug == production + exactly this delta" untrue and
  # would silently pull a debug package into the production image.
  local dupes
  dupes="$(comm -12 <(active_pkgs_of "$(DEV_DELTA_LIST)") \
                    <(active_pkgs_of "$PIPELINE_DIR/manifests/packages/shared.list"))"
  [ -z "$dupes" ]

  local f
  for f in "$PIPELINE_DIR/manifests/packages"/rk3588.delta.list "$PIPELINE_DIR/manifests/packages"/x86_64.delta.list; do
    dupes="$(comm -12 <(active_pkgs_of "$(DEV_DELTA_LIST)") <(active_pkgs_of "$f"))"
    [ -z "$dupes" ]
  done
}

@test "dev delta: the PRODUCTION list selection is exactly shared.list + the family deltas" {
  # The reference is todo 31's merged baseline: shared.list + both family deltas,
  # nothing else. Drives the SHIPPED common.sh helper, flag unset.
  local got
  got="$(CERALIVE_DEBUG_IMAGE= runtime_pkg_lists | xargs -n1 basename | sort)"
  run diff <(printf '%s\n' rk3588.delta.list shared.list x86_64.delta.list) <(printf '%s\n' "$got")
  [ "$status" -eq 0 ]

  # …and explicitly with the flag set to 0.
  got="$(CERALIVE_DEBUG_IMAGE=0 runtime_pkg_lists | xargs -n1 basename | sort)"
  run diff <(printf '%s\n' rk3588.delta.list shared.list x86_64.delta.list) <(printf '%s\n' "$got")
  [ "$status" -eq 0 ]
}

@test "dev delta: CERALIVE_DEBUG_IMAGE=1 adds the development delta and NOTHING else" {
  local got
  got="$(CERALIVE_DEBUG_IMAGE=1 runtime_pkg_lists | xargs -n1 basename | sort)"
  run diff <(printf '%s\n' development.delta.list rk3588.delta.list shared.list x86_64.delta.list) \
           <(printf '%s\n' "$got")
  [ "$status" -eq 0 ]
}

@test "dev delta: the resolved debug package SET equals production plus exactly the delta" {
  local prod debug
  prod="$(CERALIVE_DEBUG_IMAGE=0 runtime_pkg_lists | xargs sed -e 's/#.*//' | awk 'NF{print $1}' | sort -u)"
  debug="$(CERALIVE_DEBUG_IMAGE=1 runtime_pkg_lists | xargs sed -e 's/#.*//' | awk 'NF{print $1}' | sort -u)"

  # Nothing may be REMOVED by the debug branch.
  [ -z "$(comm -23 <(printf '%s\n' "$prod") <(printf '%s\n' "$debug"))" ]
  # What it ADDS is exactly the delta.
  run diff <(dev_delta_expected) <(comm -13 <(printf '%s\n' "$prod") <(printf '%s\n' "$debug"))
  [ "$status" -eq 0 ]
}

@test "dev delta: orchestrate.sh resolves the family delta by NAME and gates the dev delta on the flag" {
  # The [1/9] body lives in the stages/resolve.sh module; the orchestrator entry
  # sequences it. Read the module, or these assertions match nothing and pass.
  local orch="$LIB_DIR/stages/resolve.sh"
  # The family delta stays a ${FAMILY}-keyed lookup — never a directory glob,
  # which is what would swallow development.delta.list on every board.
  grep -Fq 'delta_list="${pkg_dir}/${FAMILY}.delta.list"' "$orch"
  run ! grep -Eq 'pkg_dir\}?"?/\*\.delta\.list' "$orch"

  # The dev delta is appended ONLY inside a CERALIVE_DEBUG_IMAGE=1 branch, and a
  # debug build with the file missing fails closed instead of silently shipping
  # a production package set under a debug label.
  grep -Fq 'dev_delta_list="${pkg_dir}/${DEV_DELTA_BASENAME}"' "$orch"
  grep -Fq 'CERALIVE_DEBUG_IMAGE=1 but the development package delta is missing' "$orch"
}

@test "dev delta: the debug flag is validated BEFORE the runtime package set is resolved" {
  # Ordering is the whole point: the package set now depends on the flag, so a
  # value like `yes` must abort rather than quietly resolve a PRODUCTION set and
  # fail three stages later at mkosi.
  local orch="$LIB_DIR/stages/resolve.sh"
  local call_line res_line
  call_line="$(grep -n '^  resolve_debug_image_flag$' "$orch" | head -1 | cut -d: -f1)"
  res_line="$(grep -n 'SHARED_PACKAGES="\$(read_pkg_list' "$orch" | head -1 | cut -d: -f1)"
  [ -n "$call_line" ]
  [ -n "$res_line" ]
  [ "$call_line" -lt "$res_line" ]
}

@test "dev delta: no consumer keeps a bare delta-list directory glob" {
  # STRUCTURAL GUARD, not three instances: any future consumer that re-adds the
  # glob silently reintroduces the debug-into-production leak.
  # Comments are stripped first: this test's own prose names the offending glob.
  local f
  for f in "$LIB_DIR/parity-check.sh" "$TESTS_DIR/realhw-suite.sh" "$BATS_TEST_FILENAME"; do
    run bash -c "sed 's/#.*//' \"\$1\" | grep -nE 'PKG_MANIFEST_DIR\}?\"?/\\*\\.delta\\.list|packages\"?/\\*\\.delta\\.list'" bash "$f"
    [ "$status" -ne 0 ]
  done
  # …and each of them routes through the one shared selector instead.
  grep -Fq 'runtime_pkg_list_files' "$LIB_DIR/parity-check.sh"
  grep -Fq 'runtime_pkg_list_files' "$TESTS_DIR/realhw-suite.sh"
  grep -Fq 'runtime_pkg_list_files' "$BATS_TEST_FILENAME"
}

@test "dev delta: parity accepts a production rootfs WITHOUT the debug packages" {
  # Scoped to check A (the Debian package diff) rather than the overall exit
  # status: the shared fixture deliberately omits libsrt1.5-ceralive, so a bare
  # make_parity_rootfs already fails on a first-party gap that predates this seam
  # and has nothing to do with it.
  local root="$BATS_TEST_TMPDIR/devdelta-prod-rootfs"
  make_parity_rootfs "$root"

  # Rebuild the dpkg status from an EXPLICITLY production-only set — shared.list
  # plus the two family deltas, named, never globbed. Reusing the fixture's own
  # selection would make this vacuous: a selector that wrongly folds the debug
  # delta in feeds BOTH the rootfs and the expectation, so they agree and the leak
  # is invisible. Modelling a real production image is what exposes it.
  local packages=() package
  while IFS= read -r package; do [[ -n "$package" ]] && packages+=("$package"); done \
    < <(sed -e 's/#.*//' \
          "$PIPELINE_DIR/manifests/packages/shared.list" \
          "$PIPELINE_DIR/manifests/packages/rk3588.delta.list" \
          "$PIPELINE_DIR/manifests/packages/x86_64.delta.list" | awk 'NF{print $1}')
  packages+=(gstreamer1.0-rockchip1 rockchip-multimedia-config ceralive-device cerastream srtla-send-rs)
  write_installed_package_status "$root/var/lib/dpkg/status" "${packages[@]}"

  run "$LIB_DIR/parity-check.sh" "$root"
  [[ "$output" == *"all Debian-sourced shared.list packages installed"* ]]
  [[ "$output" != *"python3"* ]]
  [[ "$output" != *"strace"* ]]
}

@test "dev delta: parity DEMANDS the debug packages when CERALIVE_DEBUG_IMAGE=1 (non-vacuity)" {
  # The inverse leg. Without it the test above passes even if the seam does
  # nothing at all, because "absent and never checked" looks like "absent and
  # correctly not required".
  local root="$BATS_TEST_TMPDIR/devdelta-debug-rootfs"
  make_parity_rootfs "$root"          # production package set only
  run env CERALIVE_DEBUG_IMAGE=1 "$LIB_DIR/parity-check.sh" "$root"
  [ "$status" -ne 0 ]
  [[ "$output" == *"python3"* ]]
  [[ "$output" == *"strace"* ]]
}

@test "dev delta: CERALIVE_DEBUG_IMAGE reaches every subimage via PassEnvironment" {
  # The package set is forwarded as $SHARED_PACKAGES (already propagated), but the
  # runtime postinst also branches on the flag itself for ssh enablement, the
  # password hash and the /etc/ceralive/debug-image marker. Read empty in a
  # subimage chroot, a debug image would install the delta and then behave like a
  # production one.
  local pass_names
  pass_names="$(sed -n 's/^PassEnvironment=//p' "$PIPELINE_DIR/mkosi/mkosi.conf")"
  local -A in_pass=()
  local n
  for n in $pass_names; do in_pass["$n"]=1; done
  [ -n "${in_pass[CERALIVE_DEBUG_IMAGE]:-}" ]
  [ -n "${in_pass[CERALIVE_DEBUG_PASSWORD_HASH]:-}" ]
  [ -n "${in_pass[SHARED_PACKAGES]:-}" ]
}

@test "dev delta: the debug image keeps its access behaviour (password + ssh + marker)" {
  # The seam gained packages; it must not have lost the three things that already
  # defined a debug image.
  grep -Fq '/etc/ceralive/debug-image' "$POSTINST_LIB"
  grep -Fq 'usermod --password' "$POSTINST_LIB"
  run grep -cE '^configure_ssh_enablement\(\) \{' "$POSTINST_LIB"
  [ "$output" -eq 1 ]
}

@test "dev delta: the debug-toolset sysext add-on is untouched and stays the field path" {
  # BOTH paths, not either: the add-on is the runtime/field-diagnostics route on a
  # production image; the delta is the bench route baked at build time. The sysext
  # builder must keep reading a --deb-staging tree and no package .list at all.
  local descriptor="$PIPELINE_DIR/manifests/addons/debug-toolset.json"
  [ -f "$descriptor" ]
  grep -Fq '"id": "debug-toolset"' "$descriptor"
  run grep -nE '\.delta\.list|packages/shared\.list' "$LIB_DIR/build-feature-sysext.sh"
  [ "$status" -ne 0 ]

  # Every package the add-on's `provides` paths come from is also in the delta, so
  # an operator gets the same toolbox whichever route they are on.
  #
  # `pulseaudio` was REMOVED from BOTH sides at todo 28 rather than dropped from one:
  # `pipewire-alsa` (now mandatory in shared.list) declares `Conflicts: pulseaudio`,
  # so a debug image carrying it fails its single apt transaction. The two routes
  # therefore still carry the IDENTICAL set, which is the property this loop exists
  # to pin — and the assertion below makes the removal explicit on both sides so a
  # future re-add has to break a test rather than a build.
  local p
  for p in alsa-utils usbutils pciutils lsof i2c-tools can-utils htop \
           iotop nethogs vnstat nano iperf3 socat netcat-openbsd; do
    grep -qxF "$p" <(active_pkgs_of "$(DEV_DELTA_LIST)")
  done
  run grep -qxF pulseaudio <(active_pkgs_of "$(DEV_DELTA_LIST)")
  [ "$status" -ne 0 ]
  run grep -Fq '/usr/bin/pulseaudio' "$descriptor"
  [ "$status" -ne 0 ]
}

@test "dev delta: 'development' is not a board family, so no board can resolve the delta as one" {
  # The lookup orchestrate.sh performs is ${FAMILY}.delta.list. If a family named
  # `development` ever existed, a board could pull the debug set into a production
  # build through the ordinary family path.
  [ ! -e "$PIPELINE_DIR/manifests/families/development.yaml" ]
  run grep -rl '^family:[[:space:]]*development' "$PIPELINE_DIR/manifests/boards"
  [ "$status" -ne 0 ]
}

@test "dev delta: the relative size baseline is SKIPPED for a debug build, absolute ceiling is not" {
  # A debug image is production + ~58 MB, so it trips the comparator's 50 MB
  # growth threshold by construction. The warning's own remedy is "update the
  # baseline in the same PR" — from a debug build that would overwrite the
  # PRODUCTION baseline and desync it from size-budget.json, which another test in
  # this file fails on. Only the RELATIVE check is skipped; the absolute ceiling
  # runs for both variants.
  local orch="$LIB_DIR/stages/size-gate.sh"
  local body
  body="$(awk '/^compare_size_against_baseline\(\) \{/{grab=1} grab{print} grab && /^}/{exit}' "$orch")"
  [ -n "$body" ]
  grep -Fq 'CERALIVE_DEBUG_IMAGE:-0' <<<"$body"
  grep -Fq 'relative size baseline SKIPPED' <<<"$body"

  # The absolute gate is a SEPARATE call and must NOT have grown a debug branch.
  local stage
  stage="$(awk '/\[6c\/9\] enforcing the rootfs size budget/{grab=1} grab{print} grab && /^  fi$/{exit}' "$orch")"
  [ -n "$stage" ]
  grep -Fq 'MEASURE_SIZE_SH' <<<"$stage"
  run ! grep -Fq 'CERALIVE_DEBUG_IMAGE' <<<"$stage"
}

# ===========================================================================
# 31. Kernel freeze guardrails — the boot stack is RAUC-only, never apt.
#
#     docs/partition-contract.md rule 3 puts kernel/DTB/initrd INSIDE each RAUC
#     rootfs slot, so the only sanctioned way to change them is writing a whole
#     new slot. Nothing enforced that: the shipped image carried ZERO dpkg holds,
#     so an `apt-get upgrade` on a running device would replace the kernel
#     underneath a slot the A/B selector had already committed to.
#     postinst-lib.sh::freeze_boot_packages bakes `apt-mark hold` (primary) plus
#     a supplementary name+version apt pin.
#
#     THE TWO TRAPS THESE TESTS EXIST FOR:
#       (a) A hardcoded package list would freeze ONE board. The U-Boot package
#           name differs per board (linux-u-boot-rock-5b-plus-edge vs
#           linux-u-boot-orangepi5-plus-edge), so the set must come from the
#           resolved manifest env, and the four env vars must therefore stay on
#           the orchestrate.sh env_names <-> mkosi.conf PassEnvironment= lockstep.
#       (b) Freezing a FIRST-PARTY package would break the ordinary software
#           update CeraUI drives. cerastream / ceralive-device / srtla-send-rs
#           must never be held, and the negative assertion below is what fails if
#           one is ever added.
#
#     Behavioural coverage (hold set, pin content, fail-closed legs, and a REAL
#     `apt-get -s upgrade` dry run) lives in tests/kernel-freeze-guardrails.test.sh;
#     these are the structural guards that belong beside the rest of the manifest
#     and executor contracts.
# ===========================================================================

@test "kernel freeze: the freeze set is resolved from the manifest, never hardcoded" {
  local body
  body="$(awk '/^freeze_boot_packages\(\) \{/{grab=1} grab{print} grab && /^}/{exit}' "$POSTINST_LIB")"
  [ -n "$body" ]

  local v
  for v in KERNEL_PACKAGES DTB_PACKAGES UBOOT_PACKAGES FIRMWARE_PACKAGES; do
    grep -Fq "\${$v" <<<"$body"
  done

  # A literal BSP package name here would silently freeze one board only.
  run grep -nE 'linux-(image|dtb|u-boot)-|armbian-firmware' <<<"$body"
  [ "$status" -ne 0 ]
}

@test "kernel freeze: both shipped RK3588 boards resolve a U-Boot package for it to hold" {
  # The env the freeze reads is populated by the RESOLVER, so this asserts the
  # resolved default rather than a grep of the manifest text.
  local board out
  for board in rock-5b-plus orange-pi-5-plus; do
    out="$(bash -c "'$RESOLVE_SH' '$board' 2>/dev/null")"
    [[ "$out" == *"UBOOT_PACKAGES='linux-u-boot-"*"-edge'"* ]]
    [[ "$out" == *"KERNEL_PACKAGES='linux-image-7.2.0-ceralive-rk3588'"* ]]
    [[ "$out" == *"FIRMWARE_PACKAGES='armbian-firmware'"* ]]
    # No separate DTB package on any track now — bindeb-pkg ships the in-tree
    # DTBs inside the linux-image deb, so the freeze is a 3-package set.
    [[ "$out" == *"DTB_PACKAGES=''"* ]]
  done

  # The debug sibling inherits the board's TOP-LEVEL U-Boot instead of the
  # production `-edge` override, so the freeze must follow the manifest there too
  # rather than assuming one package name per board.
  out="$(bash -c "'$RESOLVE_SH' rock-5b-plus --variant edge-test 2>/dev/null")"
  [[ "$out" == *"UBOOT_PACKAGES='linux-u-boot-rock-5b-plus-vendor'"* ]]
  [[ "$out" == *"KERNEL_PACKAGES='linux-image-7.2.0-ceralive-rk3588-test'"* ]]
}

@test "kernel freeze: NO first-party CeraLive package may ever be held" {
  # This is the assertion that fails if someone adds an app-layer package to the
  # freeze. cerastream and CeraUI ship over apt from apt.ceralive.tv and a hold
  # would break `system.startUpdate()` for good.
  local never
  never="$(sed -n 's/^CERALIVE_NEVER_FREEZE_PKGS=.*:-\(.*\)}"$/\1/p' "$POSTINST_LIB")"
  [ -n "$never" ]

  local p
  for p in cerastream ceralive-device srtla-send-rs libsrt1.5-ceralive \
           gstreamer1.0-libuvch264src modemmanager; do
    [[ " $never " == *" $p "* ]]
  done

  # The refusal must be a hard abort, and it must be checked BEFORE any hold runs.
  local body
  body="$(awk '/^freeze_boot_packages\(\) \{/{grab=1} grab{print} grab && /^}/{exit}' "$POSTINST_LIB")"
  grep -Fq 'refusing to hold first-party package' <<<"$body"
  local guard_line hold_line
  guard_line="$(grep -n 'refusing to hold first-party package' <<<"$body" | head -1 | cut -d: -f1)"
  hold_line="$(grep -n 'apt-mark hold' <<<"$body" | head -1 | cut -d: -f1)"
  [ "$guard_line" -lt "$hold_line" ]
}

@test "kernel freeze: the shipped image installs no unattended-upgrades" {
  # The freeze answers "apt must not change the kernel". Adding an automatic
  # upgrade daemon would be answering the opposite question, and this appliance
  # updates through RAUC only.
  run grep -rnE '^[[:space:]]*unattended-upgrades[[:space:]]*$' "$PIPELINE_DIR/manifests/packages"
  [ "$status" -ne 0 ]
  run grep -rn 'unattended-upgrade' "$PIPELINE_DIR/mkosi/customize" "$PIPELINE_DIR/mkosi/mkosi.images"
  [ "$status" -ne 0 ]
}

@test "kernel freeze: the hold is verified, not assumed" {
  # Same fail-closed discipline as mask_service: a hold that silently did not
  # apply ships an apt-upgradable kernel on an image that passes every other gate.
  # Assert against the EXECUTABLE body — the header prose names `apt-mark
  # showhold` too, and a mutation that deleted the real call still passed while
  # this grep could see the comment.
  local body code
  body="$(awk '/^freeze_boot_packages\(\) \{/{grab=1} grab{print} grab && /^}/{exit}' "$POSTINST_LIB")"
  code="$(grep -vE "^[[:space:]]*#|printf '#" <<<"$body")"
  grep -Fq 'apt-mark showhold' <<<"$code"
  grep -Fq 'did not land' <<<"$code"
}

@test "kernel freeze: the pin is name+version, and the origin form is documented as unusable" {
  local body
  body="$(awk '/^freeze_boot_packages\(\) \{/{grab=1} grab{print} grab && /^}/{exit}' "$POSTINST_LIB")"
  grep -Fq 'Pin: version' <<<"$body"
  grep -Fq 'Pin-Priority: 1001' <<<"$body"

  # An emitted origin pin cannot match a locally-installed .deb; only the
  # explanatory prose may mention one.
  run grep -Fq 'Pin: origin' <<<"$(grep -v "printf '#" <<<"$body")"
  [ "$status" -ne 0 ]

  # The generated file must carry the bypass limitation with it onto the device.
  grep -Fq 'LIMITATION' <<<"$body"
}

@test "kernel freeze: the runtime executor calls it, last, after every apt transaction" {
  local postinst="$PIPELINE_DIR/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"
  run grep -cE '^  freeze_boot_packages( |$)' "$postinst"
  [ "$output" -eq 1 ]

  # run-all.sh's runtime modules are NOT executed by ./build, so the wiring in
  # this executor is the only thing that makes the freeze ship.
  local main_body
  main_body="$(awk '/^main\(\) \{/,/^\}/' "$postinst")"
  local freeze_at hawkbit_at
  freeze_at="$(grep -n 'freeze_boot_packages' <<<"$main_body" | cut -d: -f1)"
  hawkbit_at="$(grep -n 'setup_hawkbit_updater' <<<"$main_body" | cut -d: -f1)"
  [ "$freeze_at" -gt "$hawkbit_at" ]
}

@test "kernel freeze: freeze_boot_packages is on the drift gate's consolidated list" {
  serialize working-tree   # postinst-wiring.bats mutates the tree this gate reads
  grep -Fq 'freeze_boot_packages' "$PIPELINE_DIR/ci/postinst-drift-check.sh"
  run bash "$PIPELINE_DIR/ci/postinst-drift-check.sh"
  [ "$status" -eq 0 ]
}

@test "kernel freeze: its behavioural suite is wired into the CI entrypoint" {
  local suite="$TESTS_DIR/kernel-freeze-guardrails.test.sh"
  [ -x "$suite" ]
  # The entrypoint's suite list moved into tests/registry.tsv, which run-tests
  # reads; `--list` is the resolved default set, so asserting against it is the
  # same claim against the current source of truth (and a stronger one than a
  # text grep, which would also have matched a commented-out line).
  run "$PIPELINE_DIR/run-tests" --list
  [ "$status" -eq 0 ]
  [[ "$output" == *"tests/kernel-freeze-guardrails.test.sh"* ]]
}
