#!/bin/bash
# Real flock and archive/copy operations; exact command boundaries are stubbed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
source "${HERE}/lib/assertions.sh"
source "${HERE}/lib/kernel-stage-fixture.sh"
WORK="$(mktemp -d)"
trap 'rm -rf -- "${WORK}"' EXIT

# Execute the real installer with its root destinations redirected, not grepped.
(
  source "${REPO}/mkosi/customize/postinst-lib.sh"
  export CERALIVE_RUNTIME_SRC="${WORK}/install-src/runtime" CERALIVE_BOARD=fixture
  mkdir -p "${CERALIVE_RUNTIME_SRC}" "${WORK}/install-src/.staging/fixture"
  cp "${REPO}/mkosi/runtime/ceralive-slot-sync."{sh,service,exclude} \
    "${REPO}/mkosi/runtime/ceralive-slot-mirror-lib.sh" \
    "${REPO}/mkosi/runtime/ceralive-kernel-state-lib.sh" \
    "${REPO}/mkosi/runtime/ceralive-kernel-stage.sh" "${CERALIVE_RUNTIME_SRC}/"
  cp "${REPO}/lib/shared/slot-reserve.sh" "${WORK}/install-src/.staging/fixture/slot-reserve.sh"
  install() { command install "$1" "$2" "$3" "$4" "${WORK}/payload$5"; }
  setup_slot_sync
  unset -f install
  cp "${REPO}/mkosi/runtime/ceralive-kernel-boot-staging.sh" "${CERALIVE_RUNTIME_SRC}/"
  cp "${REPO}/lib/verify-boot-artifacts.sh" "${WORK}/install-src/.staging/fixture/verify-boot-artifacts.sh"
  eval "$(awk '/^install_kernel_boot_staging\(\) \{/,/^}/' "${REPO}/mkosi/mkosi.images/platform/mkosi.postinst")"
  export BUILDROOT="${WORK}/payload" SRCDIR="${WORK}/install-src"
  export KERNEL_SOURCE_KERNEL_RELEASE=7.2.0-ceralive-rk3588
  export KERNEL_SOURCE_DTB_DEB_DIR=/usr/lib/linux-image-7.2.0-ceralive-rk3588/rockchip
  export KERNEL_SOURCE_DTB_BOOT_DIR=/boot/dtb/rockchip DTB_NAME=rk3588-test.dtb
  install_kernel_boot_staging
) >"${WORK}/installer.out" 2>&1
assert_eq "runtime installer succeeds" 0 "$?"
[[ -x "${WORK}/payload/usr/lib/ceralive/ceralive-kernel-stage" ]] && ok "stager installed executable at contract path" || bad "stager install path/mode"
cmp -s "${REPO}/lib/shared/slot-reserve.sh" "${WORK}/payload/usr/lib/ceralive/slot-reserve.sh" \
  && ok "shipped reserve is the exact build-time shared library" || bad "reserve library drift"

stage_fixture_init || exit 1
STATE="${FIXTURE}/state/kernel-state.json"
OVERLAY="${FIXTURE}/state/slot-overlay-B.json"

run_refused() {
  local reason="$1"
  stage_run >"${WORK}/out" 2>&1
  assert_eq "${reason}: exit 75" 75 "$?"
  assert_contains "${reason}: exact refusal" "${WORK}/out" "${reason}"
}

stage_fixture_reset
before="$(stage_tree_hash)"
stage_run >"${WORK}/out" 2>&1
assert_eq "owned parent flock stages" 0 "$?"
assert_eq "commit point persisted" staged "$(jq -r .state "${STATE}")"
assert_eq "pending overlay persisted" pending "$(jq -r .status "${OVERLAY}")"
cp "${STATE}" "${WORK}/staged-state.json"
cp "${OVERLAY}" "${WORK}/pending-overlay.json"
python3 - "${STATE}" "${OVERLAY}" "${FIXTURE}/rauc.json" <<'PY'
import datetime, json, pathlib, sys, uuid
state, overlay, rauc = [json.loads(pathlib.Path(path).read_text()) for path in sys.argv[1:]]
assert set(state) == {"schema", "attempt", "package", "version", "deb_sha256", "target_slot",
                      "booted_slot_at_stage", "boot_id_at_activation", "state", "reason", "timestamps"}
uuid.UUID(state["attempt"])
assert (state["target_slot"], state["booted_slot_at_stage"], state["reason"]) == ("B", "A", None)
assert set(state["timestamps"]) == {"staging", "staged"}
for stamp in state["timestamps"].values():
    assert stamp.endswith("Z")
    datetime.datetime.fromisoformat(stamp)
source = rauc["slots"][0]["rootfs.0"]["slot_status"]
assert overlay["base_bundle_identity"] == {
    "slot": "rootfs.0", "bundleHash": source["bundle"]["hash"], "checksum": source["checksum"]["sha256"],
    "installedAt": source["installed"]["timestamp"], "installedCount": source["installed"]["count"]
}
assert overlay["reason"] is None and overlay["attempt"] == state["attempt"]
assert set(overlay) == {"status", "attempt", "reason", "base_bundle_identity", "kernel"}
assert set(overlay["kernel"]) == {"package", "version", "deb_sha256"}
PY
assert_eq "real state and pending overlay use the adopted consumer encoding" 0 "$?"
assert_eq "booted fixture byte-identical" "${before}" "$(stage_tree_hash)"
[[ ! -s "${FIXTURE}/mounts" ]] && ok "success unmounted every child and slot" || bad "leaked mounts"
assert_eq "target eligible only after verification" good "$(<"${FIXTURE}/eligibility")"
[[ -s "${FIXTURE}/chroot-script" ]] && ok "bounded chroot worker receives its install script" || bad "chroot stdin lost"
python3 - "${FIXTURE}/events" <<'PY'
import pathlib, sys
events = pathlib.Path(sys.argv[1]).read_text().splitlines()
assert events.index("mirror") > events.index("rauc status mark-bad other")
assert events.index("reserve") > max(i for i,v in enumerate(events) if v.startswith("umount "))
assert events.index("reserve") < next(i for i,v in enumerate(events) if v.startswith("fsck -fn "))
assert next(i for i,v in enumerate(events) if v.startswith("fsck -fn ")) < events.index("rauc status mark-good other")
PY
assert_eq "write-ahead, unmount/reserve/fsck/eligibility ordering" 0 "$?"

# RAUC configuration is the label authority, including explicit bench overlays.
stage_fixture_reset
ln -s "${FIXTURE}/mnt/target" "${FIXTURE}/by-partlabel/xrootfs_b"
jq -c --arg device "${FIXTURE}/by-partlabel/xrootfs_b" '.slots[1]["rootfs.1"].device=$device' \
  "${FIXTURE}/rauc.json" >"${WORK}/bench-status"
cp "${WORK}/bench-status" "${FIXTURE}/rauc.json"
stage_run >"${WORK}/out" 2>&1
assert_eq "explicit bench PARTLABEL stages without a production-label guess" 0 "$?"
assert_eq "configured-label target committed" staged "$(jq -r .state "${STATE}")"

# Manual CLI artifact uses the production argv, with no helper shell in between.
stage_fixture_reset
before="$(stage_tree_hash)"
stage_args
flock -n -E 75 -x "${CERALIVE_UPDATE_LOCK_PATH}" bash "${CERALIVE_STAGE_SCRIPT}" "${STAGE_ARGS[@]}" >"${WORK}/manual" 2>&1
assert_eq "manual CLI exact flock parent" 0 "$?"
if [[ -n "${KERNEL_STAGE_QA_ARTIFACT:-}" ]]; then
  {
    printf 'guarded exit=0 state=%s overlay=%s\n' "$(jq -r .state "${STATE}")" "$(jq -r .status "${OVERLAY}")"
    printf 'booted before=%s\nbooted after=%s\n' "${before}" "$(stage_tree_hash)"
  } >"${KERNEL_STAGE_QA_ARTIFACT}"
fi
for lock_case in free unrelated; do
  stage_fixture_reset
  before="$(stage_tree_hash)"
  stage_args
  if [[ "${lock_case}" == unrelated ]]; then
    exec 7>"${CERALIVE_UPDATE_LOCK_PATH}"; flock -x 7
  fi
  bash "${CERALIVE_STAGE_SCRIPT}" "${STAGE_ARGS[@]}" >"${WORK}/out" 2>&1
  assert_eq "${lock_case} lock: refuses" 75 "$?"
  assert_contains "${lock_case} lock: reason" "${WORK}/out" update_lock_not_owned
  [[ ! -f "${STATE}" && ! -e "${FIXTURE}/events" ]] && ok "${lock_case} lock: zero target writes" || bad "unowned lock performed writes"
  assert_eq "${lock_case} lock: booted bytes preserved" "${before}" "$(stage_tree_hash)"
  if [[ "${lock_case}" == free && -n "${KERNEL_STAGE_QA_ARTIFACT:-}" ]]; then
    printf 'unguarded exit=75 reason=update_lock_not_owned target_writes=0\n' >>"${KERNEL_STAGE_QA_ARTIFACT}"
  fi
  if [[ "${lock_case}" == unrelated ]]; then flock -u 7; exec 7>&-; fi
done

for gate in root capability primary selected target-state target-device nested-device same-device armed pending partlabel audit operation hawkbit healthy boot-id dpkg-sha build-id healthy-slot active-state board; do
  stage_fixture_reset
  case "${gate}" in
    root) export UID_FIXTURE=1000; reason=root_required ;;
    capability) printf '{"features":[]}\n' >"${CERALIVE_UPDATE_CAPABILITIES}"; reason=capability_missing ;;
    primary|selected) jq -c '.boot_primary="rootfs.1"' "${FIXTURE}/rauc.json" >"${WORK}/json"; cp "${WORK}/json" "${FIXTURE}/rauc.json"; reason=boot_primary_mismatch ;;
    target-state) jq -c '.slots[1]["rootfs.1"].state="active"' "${FIXTURE}/rauc.json" >"${WORK}/json"; cp "${WORK}/json" "${FIXTURE}/rauc.json"; reason=target_not_inactive ;;
    target-device) jq -c '.slots[1]["rootfs.1"].device="/dev/invalid"' "${FIXTURE}/rauc.json" >"${WORK}/json"; cp "${WORK}/json" "${FIXTURE}/rauc.json"; reason=target_partlabel_invalid ;;
    nested-device)
      mkdir "${FIXTURE}/by-partlabel/nested"
      ln -s "${FIXTURE}/mnt/target" "${FIXTURE}/by-partlabel/nested/rootfs_b"
      jq -c --arg device "${FIXTURE}/by-partlabel/nested/rootfs_b" '.slots[1]["rootfs.1"].device=$device' "${FIXTURE}/rauc.json" >"${WORK}/json"
      cp "${WORK}/json" "${FIXTURE}/rauc.json"
      reason=target_partlabel_invalid ;;
    same-device) ln -sfn "${FIXTURE}/booted" "${FIXTURE}/by-partlabel/rootfs_b"; reason=target_is_booted ;;
    armed) touch "${FIXTURE}/state/activation-armed"; reason=activation_armed ;;
    pending) jq -c 'del(.slots[1]["rootfs.1"].slot_status.activated)' "${FIXTURE}/rauc.json" >"${WORK}/json"; cp "${WORK}/json" "${FIXTURE}/rauc.json"; reason="other-slot-pending-activation" ;;
    partlabel) touch "${CERALIVE_PARTLABEL_FAILURE}"; reason=partlabel-guard-failed ;;
    audit) export AUDIT_OUTPUT=broken; reason=dpkg-audit-nonempty ;;
    operation) export TEST_RAUC_OPERATION=installing; reason=rauc-operation-busy ;;
    hawkbit) export HAWKBIT_ACTIVE=1; reason=hawkbit-updater-active ;;
    healthy) rm "${CERALIVE_HEALTHY_STATE_FILE}"; reason=healthy-state-missing ;;
    boot-id) printf 'changed\n' >"${CERALIVE_HEALTHCHECK_BOOT_ID_FILE}"; reason=healthy-state-mismatch ;;
    dpkg-sha) printf 'changed\n' >>"${CERALIVE_DPKG_STATUS_FILE}"; reason=healthy-state-mismatch ;;
    build-id) printf 'BUILD_ID=changed\n' >"${CERALIVE_OS_RELEASE_FILE}"; reason=healthy-state-mismatch ;;
    healthy-slot) jq -c '.slot="B"' "${CERALIVE_HEALTHY_STATE_FILE}" >"${WORK}/json"; cp "${WORK}/json" "${CERALIVE_HEALTHY_STATE_FILE}"; reason=healthy_slot_mismatch ;;
    active-state) printf '{"state":"armed"}\n' >"${STATE}"; reason=kernel_staged_pending ;;
    board) printf '{}\n' >"${CERALIVE_BOARD_BOOT}"; reason=board_identity_invalid ;;
  esac
  run_refused "${reason}"
  [[ ! -s "${FIXTURE}/mounts" ]] && ! grep -q 'mark-bad' "${FIXTURE}/events" 2>/dev/null && ok "${gate}: no mutation" || bad "${gate}: gate mutated target"
done

for identity_case in missing-status missing-hash missing-checksum missing-installed invalid-count invalid-time; do
  stage_fixture_reset
  case "${identity_case}" in
    missing-status) expression='del(.slots[0]["rootfs.0"].slot_status)' ;;
    missing-hash) expression='del(.slots[0]["rootfs.0"].slot_status.bundle.hash)' ;;
    missing-checksum) expression='del(.slots[0]["rootfs.0"].slot_status.checksum)' ;;
    missing-installed) expression='del(.slots[0]["rootfs.0"].slot_status.installed)' ;;
    invalid-count) expression='.slots[0]["rootfs.0"].slot_status.installed.count=0' ;;
    invalid-time) expression='.slots[0]["rootfs.0"].slot_status.installed.timestamp="not-a-date"' ;;
  esac
  jq -c "${expression}" "${FIXTURE}/rauc.json" >"${WORK}/json"
  cp "${WORK}/json" "${FIXTURE}/rauc.json"
  run_refused kernel_identity_mismatch
  [[ ! -e "${STATE}" && "$(<"${FIXTURE}/eligibility")" == good ]] \
    && ok "${identity_case}: no write-ahead or eligibility mutation" || bad "${identity_case}: mutated without byte identity"
  assert_eq "${identity_case}: never publishes pending overlay" confirmed "$(jq -r .status "${OVERLAY}")"
done

for state in staged armed activating activated; do
  stage_fixture_reset
  printf '{"state":"%s"}\n' "${state}" >"${STATE}"
  run_refused kernel_staged_pending
done

stage_fixture_reset
exec 7>"${CERALIVE_DPKG_LOCK_FRONTEND}"; flock -x 7
run_refused dpkg_lock_busy
flock -u 7; exec 7>&-

for dimension in sha package version attempt corrupt control-package control-version arch; do
  stage_fixture_reset
  stage_args
  case "${dimension}" in
    sha) STAGE_ARGS[9]="$(printf '0%.0s' {1..64})" ;;
    package) STAGE_ARGS[5]=linux-headers-7.2.0-ceralive-rk3588 ;;
    version) STAGE_ARGS[7]='7.2.0-ceralive2;echo' ;;
    attempt) STAGE_ARGS[1]='../escape' ;;
    corrupt) printf broken >"${WORK}/corrupt.deb"; STAGE_ARGS[3]="${WORK}/corrupt.deb"; STAGE_ARGS[9]="$(sha256sum "${WORK}/corrupt.deb" | cut -d' ' -f1)" ;;
    control-package) STAGE_ARGS[5]=linux-image-7.3.0-ceralive-rk3588; STAGE_ARGS[7]=7.3.0-ceralive1 ;;
    control-version) STAGE_ARGS[7]=7.2.0-ceralive3 ;;
    arch)
      mkdir -p "${WORK}/wrong-arch"
      dpkg-deb -R "${TEST_DEB}" "${WORK}/wrong-arch"
      sed -i 's/Architecture: arm64/Architecture: amd64/' "${WORK}/wrong-arch/DEBIAN/control"
      dpkg-deb --build --root-owner-group "${WORK}/wrong-arch" "${WORK}/wrong-arch.deb" >/dev/null
      STAGE_ARGS[3]="${WORK}/wrong-arch.deb"
      STAGE_ARGS[9]="$(sha256sum "${WORK}/wrong-arch.deb" | cut -d' ' -f1)"
      ;;
  esac
  flock -n -E 75 -x "${CERALIVE_UPDATE_LOCK_PATH}" bash "${CERALIVE_STAGE_SCRIPT}" "${STAGE_ARGS[@]}" >"${WORK}/out" 2>&1
  assert_eq "${dimension} malformed input refused" 75 "$?"
  [[ ! -e "${STATE}" ]] && ok "${dimension}: no staging record or target writes" || bad "${dimension}: mutated"
done

# A killed attempt's dirty slot is always replaced, never resumed in place.
stage_fixture_reset
printf 'untrusted previous attempt\n' >"${CERALIVE_KERNEL_STAGE_TARGET}/leftover"
stage_run >"${WORK}/out" 2>&1
assert_eq "dirty target overwritten by verified mirror" 0 "$?"
[[ ! -e "${CERALIVE_KERNEL_STAGE_TARGET}/leftover" ]] && ok "dirty leftover removed" || bad "dirty target survived mirror"

mkfifo "${WORK}/hang"
export HANG_FIFO="${WORK}/hang"
for boundary in mount e2fsck chroot; do
  stage_fixture_reset
  export HANG_TOOL="${boundary}" CERALIVE_KERNEL_STAGE_COMMAND_TIMEOUT=1
  stage_run >"${WORK}/out" 2>&1
  assert_eq "hung ${boundary}: bounded refusal" 75 "$?"
  assert_eq "hung ${boundary}: failed state" failed "$(jq -r .state "${STATE}")"
  assert_eq "hung ${boundary}: remains bad" bad "$(<"${FIXTURE}/eligibility")"
  flock -n "${CERALIVE_UPDATE_LOCK_PATH}" true \
    && ok "hung ${boundary}: lock released" || bad "hung ${boundary}: leaked child"
done

for failure in bavail inodes mirror verify mount cache-hash dpkg boot-staging boot-verify firmware firmware-usage final-fsck reserve pending-sync staged-sync mark-good unmount mounted; do
  stage_fixture_reset
  rm -f "${FIXTURE}/installed"
  case "${failure}" in
    bavail) export CAPACITY_AVAILABLE=131072; reason=insufficient_bavail ;;
    inodes) export CAPACITY_FREE=15000; reason=insufficient_inodes ;;
    verify) export VERIFY_MISMATCH=1; reason='dpkg --verify mismatch' ;;
    cache-hash) export TAMPER_CACHED_DEB=1; reason=kernel_origin_mismatch ;;
    firmware) export FIRMWARE_RC=1; reason=firmware_missing ;;
    firmware-usage) export FIRMWARE_RC=2; reason=firmware_missing ;;
    reserve) export CAPACITY_FINAL_FREE=19999; reason=slot_reserve_failed ;;
    unmount) export FAIL_TOOL=umount; reason=unmount_failed ;;
    mounted) export FINAL_MOUNT_LEAK=1; reason=target_still_mounted ;;
    *) export FAIL_TOOL="${failure}"; reason="" ;;
  esac
  stage_run >"${WORK}/out" 2>&1
  assert_eq "${failure}: exit 75" 75 "$?"
  assert_eq "${failure}: durable failed state" failed "$(jq -r .state "${STATE}")"
  assert_eq "${failure}: target bad" bad "$(<"${FIXTURE}/eligibility")"
  assert_eq "${failure}: invalid overlay" invalid "$(jq -r .status "${OVERLAY}")"
  jq -e 'keys==["attempt","reason","status"] and .reason=="kernel_staging"' "${OVERLAY}" >/dev/null
  assert_eq "${failure}: lean invalid envelope" 0 "$?"
  if [[ "${failure}" == cache-hash ]]; then expected_reason=kernel_origin_mismatch; else expected_reason=kernel_staging_failed; fi
  assert_eq "${failure}: adopted shared reason" "${expected_reason}" "$(jq -r .reason "${STATE}")"
  [[ -z "${reason}" ]] || assert_contains "${failure}: reason" "${WORK}/out" "${reason}"
  unset CAPACITY_FINAL_FREE
done

# Each checkpoint sends SIGKILL synchronously from the real command boundary.
# No sleeps or polling: flock waits for the killed child before recovery starts.
for point in mirror dpkg after_overlay after_mark_good before_staged; do
  stage_fixture_reset
  export KILL_AT="${point}"
  stage_run >"${WORK}/out" 2>&1
  assert_eq "${point}: SIGKILL reached" 137 "$?"
  assert_eq "${point}: commit not published" staging "$(jq -r .state "${STATE}")"
  unset KILL_AT
  stage_recover >"${WORK}/out" 2>&1
  assert_eq "${point}: recovery exit 75" 75 "$?"
  assert_eq "${point}: failed/interrupted" kernel_interrupted "$(jq -r .reason "${STATE}")"
  assert_eq "${point}: target bad" bad "$(<"${FIXTURE}/eligibility")"
  assert_eq "${point}: overlay invalid" invalid "$(jq -r .status "${OVERLAY}")"
  jq '.acknowledged=true' "${STATE}" >"${WORK}/ack"; cp "${WORK}/ack" "${STATE}"
  stage_recover >"${WORK}/out" 2>&1
  assert_eq "${point}: restart after ack settles" 0 "$?"
  assert_eq "${point}: ack retains invalid identity" invalid "$(jq -r .status "${OVERLAY}")"
  # The activation predicate from todo 10 cannot accept any intermediate state.
  jq -e '.state=="staged" or .state=="armed"' "${STATE}" >/dev/null \
    && bad "${point}: activation could proceed" || ok "${point}: activation refused"
done

for bootname in A B; do
  stage_fixture_reset
  if [[ "${bootname}" == A ]]; then target=B; else stage_fixture_boot_b; target=A; fi
  if [[ "${bootname}" == B ]]; then
    stage_run >"${WORK}/out" 2>&1
    assert_eq "B->A: full staging succeeds" 0 "$?"
    jq -e '.target_slot=="A" and .booted_slot_at_stage=="B" and .reason==null' "${STATE}" >/dev/null
    assert_eq "B->A: successful writer keeps bootname encoding" 0 "$?"
    jq -e '.status=="pending" and .base_bundle_identity.slot=="rootfs.1"' "${FIXTURE}/state/slot-overlay-A.json" >/dev/null
    assert_eq "B->A: pending base retains the actual booted RAUC name" 0 "$?"
    stage_fixture_reset
    stage_fixture_boot_b
  fi
  jq --arg target "${target}" --arg booted "${bootname}" \
    '.state="staging" | .target_slot=$target | .booted_slot_at_stage=$booted | .reason=null |
     .timestamps={staging:"2026-10-01T00:00:00Z",staged:"2026-10-02T00:00:00.123Z"}' \
    "${WORK}/staged-state.json" >"${STATE}"
  jq '.status="confirmed"' "${WORK}/pending-overlay.json" >"${FIXTURE}/state/slot-overlay-${target}.json"
  stage_recover >"${WORK}/out" 2>&1
  assert_eq "${bootname}->${target}: conformant A/B recovery refuses interrupted attempt" 75 "$?"
  assert_eq "${bootname}->${target}: recovered target is a bootname" "${target}" "$(jq -r .target_slot "${STATE}")"
  assert_eq "${bootname}->${target}: recovered booted slot is a bootname" "${bootname}" "$(jq -r .booted_slot_at_stage "${STATE}")"
  assert_eq "${bootname}->${target}: interruption uses adopted token" kernel_interrupted "$(jq -r .reason "${STATE}")"
  assert_eq "${bootname}->${target}: recovery marks target bad" bad "$(<"${FIXTURE}/eligibility")"
  jq -e 'keys==["attempt","reason","status"] and .status=="invalid"' "${FIXTURE}/state/slot-overlay-${target}.json" >/dev/null
  assert_eq "${bootname}->${target}: recovery invalidates lean overlay" 0 "$?"
  jq -e '.state=="failed" and .timestamps.staging=="2026-10-01T00:00:00Z" and
    .timestamps.staged=="2026-10-02T00:00:00.123Z" and (.timestamps.failed | endswith("Z"))' "${STATE}" >/dev/null
  assert_eq "${bootname}->${target}: state entry anchors retained during recovery" 0 "$?"
  jq '.acknowledged=true' "${STATE}" >"${WORK}/ack"
  cp "${WORK}/ack" "${STATE}"
  stage_recover >"${WORK}/out" 2>&1
  assert_eq "${bootname}->${target}: acknowledged restart is settled" 0 "$?"
  cmp -s "${WORK}/ack" "${STATE}" && ok "${bootname}->${target}: acknowledgement retains exact anchors" \
    || bad "${bootname}->${target}: restart rewrote acknowledged record"
done

for malformed in foreign-key non-utc invalid-calendar duplicate; do
  stage_fixture_reset
  python3 - "${WORK}/staged-state.json" "${STATE}" "${malformed}" <<'PY'
import json, pathlib, sys
record = json.loads(pathlib.Path(sys.argv[1]).read_text())
record["state"] = "staging"
kind = sys.argv[3]
record["timestamps"] = {
    "foreign-key": {"updated_at": "2026-10-01T00:00:00Z"},
    "non-utc": {"staging": "2026-10-01T00:00:00+02:00"},
    "invalid-calendar": {"staging": "2026-02-30T00:00:00Z"},
    "duplicate": None,
}[kind]
text = json.dumps(record, separators=(",", ":"))
if kind == "duplicate":
    text = text.replace('"timestamps":null', '"timestamps":{"staging":"2026-10-01T00:00:00Z","staging":"2026-10-02T00:00:00Z"}')
pathlib.Path(sys.argv[2]).write_text(text + "\n")
PY
  cp "${STATE}" "${WORK}/malformed-state"
  stage_recover >"${WORK}/out" 2>&1
  assert_eq "${malformed}: malformed entry map refused" 75 "$?"
  assert_contains "${malformed}: identified invalid authority" "${WORK}/out" kernel_identity_mismatch
  cmp -s "${WORK}/malformed-state" "${STATE}" && [[ "$(<"${FIXTURE}/eligibility")" == good ]] \
    && ok "${malformed}: no invented replacement anchors" || bad "${malformed}: malformed authority rewritten"
done

# A later verified mirror is the only local repair that replaces invalid identity.
stage_fixture_reset
printf '{"status":"invalid","attempt":"failed"}\n' >"${OVERLAY}"
printf '{"status":"confirmed","attempt":"booted","kernel":{"package":"fixture"}}\n' >"${FIXTURE}/state/slot-overlay-A.json"
# Drive the real shared overlay writer after the real copy/verify primitive.
(
  # shellcheck source=mkosi/runtime/ceralive-slot-sync.sh
  source "${CERALIVE_SLOT_SYNC_LIB}"
  OTHER_SLOT_OBJECT='{"bootname":"B"}'
  mkdir -p "${SOURCE_MNT}" "${TARGET_MNT}"
  export RSYNC_BIN=/usr/bin/rsync
  slot_mirror_copy_verify -a --checksum --delete
  mirror_slot_overlay
) >"${WORK}/out" 2>&1
assert_eq "verified mirror replaces invalid overlay" 0 "$?"
cmp -s "${OVERLAY}" "${FIXTURE}/state/slot-overlay-A.json" \
  && ok "target reports booted overlay, never retained bundle" || bad "overlay not mirrored"

bash "${HERE}/kernel-stage-contract-fixtures.sh" "${WORK}/contract" >"${WORK}/contract.log" 2>&1
assert_eq "contract emitter runs actual successful and failing producer paths" 0 "$?"
python3 - "${WORK}/contract" "${HERE}/fixtures/kernel-stage-contract" <<'PY'
import datetime, json, pathlib, sys, uuid
for directory in sys.argv[1:]:
    root = pathlib.Path(directory)
    records = {name: json.loads((root / f"{name}.json").read_text())
               for name in ("staged-state", "failed-state", "pending-overlay", "invalid-overlay")}
    for name in ("staged-state", "failed-state"):
        record = records[name]
        uuid.UUID(record["attempt"])
        assert (record["target_slot"], record["booted_slot_at_stage"]) == ("B", "A")
        for stamp in record["timestamps"].values():
            assert stamp.endswith("Z")
            datetime.datetime.fromisoformat(stamp)
    assert records["staged-state"]["reason"] is None
    assert set(records["staged-state"]["timestamps"]) == {"staging", "staged"}
    assert records["failed-state"]["reason"] == "kernel_staging_failed"
    assert set(records["failed-state"]["timestamps"]) == {"staging", "failed"}
    assert set(records["invalid-overlay"]) == {"status", "attempt", "reason"}
    assert records["invalid-overlay"]["status"] == "invalid"
    assert records["pending-overlay"]["base_bundle_identity"]["slot"] == "rootfs.0"
PY
assert_eq "emitted records retain consumer slot, reason, envelope and timestamp contracts" 0 "$?"

printf '\nRESULT: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
