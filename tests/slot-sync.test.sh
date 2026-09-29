#!/usr/bin/env bash
#
# tests/slot-sync.test.sh — contract test for ceralive-slot-sync (task 26,
# Metis G3/G4/G14: verified local mirror of the healthy booted slot onto the
# other, lagged one).
#
# ONE file, two tiers — the same shape as tests/mkosi-package-staging.test.sh's
# internal CERALIVE_RUN_REAL_PRIVILEGE_DROP_CONTRACT gate, not a second opt-in
# file. Everything that needs no privilege — the full refusal-gate matrix, the
# `check` JSON, the dpkg --verify comparison logic, mark-bad/mark-good call
# ordering, SIGTERM handling, the adaptive-index cleanup and rsync's
# `--checksum` behaviour on plain directories — runs unconditionally as
# `default-shell`. Only the REAL loop-mounted ext4 target + real mount/rsync/
# e2fsck leg (xattrs, ACLs, file capabilities, hardlinks, sparse files, and the
# hidden-/boot-under-a-bind-mount trick) needs root or passwordless sudo, and
# is gated internally by CERALIVE_RUN_REAL_SLOT_SYNC_CONTRACT
# (required|skip, default skip; any other value is a usage error, exit 2) —
# the same shape as this repo's other real-* contract gates.
#
# contract-test profile (docs/shell-profiles.md): `set -uo pipefail`, no `-e`
# — every scenario is independent and the harness owns its own exit code via
# tests/lib/assertions.sh's PASS/FAIL counters.
#
# shellcheck shell=bash

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck source=lib/assertions.sh
source "${HERE}/lib/assertions.sh"

SCRIPT="${ROOT}/mkosi/runtime/ceralive-slot-sync.sh"
EXCLUDE_SRC="${ROOT}/mkosi/runtime/ceralive-slot-sync.exclude"
SERVICE_SRC="${ROOT}/mkosi/runtime/ceralive-slot-sync.service"

[[ -f "${SCRIPT}" ]] || { printf 'FAIL: missing %s\n' "${SCRIPT}" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/var/tmp}/ceralive-slot-sync.XXXXXX")"
cleanup() { rm -rf -- "${WORK}"; }
trap cleanup EXIT

mkdir -p "${WORK}/bin" "${WORK}/data/ceralive/update-state" "${WORK}/data/ceralive/rauc" \
  "${WORK}/run/lock" "${WORK}/mnt"

# ---------------------------------------------------------------------------
# Command stubs (unprivileged tier). Every stub records its argv so a test can
# assert both WHAT ran and in WHAT ORDER.
# ---------------------------------------------------------------------------

RAUC_CALLS="${WORK}/rauc-calls.log"
RSYNC_CALLS="${WORK}/rsync-calls.log"
MOUNT_CALLS="${WORK}/mount-calls.log"
UMOUNT_CALLS="${WORK}/umount-calls.log"
: >"${RAUC_CALLS}"; : >"${RSYNC_CALLS}"; : >"${MOUNT_CALLS}"; : >"${UMOUNT_CALLS}"
: >"${WORK}/empty"

cat >"${WORK}/bin/rauc" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"${RAUC_CALLS}"
case "\$*" in
  "status --detailed --output-format=json")
    cat "\${RAUC_JSON_FIXTURE}" ;;
  "status mark-bad other")
    [[ "\${RAUC_MARK_BAD_FAIL:-0}" == 1 ]] && exit 1; exit 0 ;;
  "status mark-good other")
    [[ "\${RAUC_MARK_GOOD_FAIL:-0}" == 1 ]] && exit 1; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "${WORK}/bin/rauc"

cat >"${WORK}/bin/busctl" <<'EOF'
#!/bin/bash
printf 's "%s"\n' "${RAUC_OPERATION_FIXTURE:-idle}"
EOF
chmod +x "${WORK}/bin/busctl"

cat >"${WORK}/bin/systemctl" <<'EOF'
#!/bin/bash
if [[ "$1" == "is-active" ]]; then
  [[ "${HAWKBIT_ACTIVE_FIXTURE:-0}" == 1 ]] && exit 0
  exit 3
fi
exit 0
EOF
chmod +x "${WORK}/bin/systemctl"

# --root=<path> --verify prints whichever fixture matches the root suffix, so a
# test can independently script the source-side and target-side dpkg --verify
# answer without a real dpkg database.
cat >"${WORK}/bin/dpkg" <<EOF
#!/bin/bash
if [[ "\$1" == "--audit" ]]; then
  cat "\${DPKG_AUDIT_FIXTURE:-${WORK}/empty}"
  exit 0
fi
for arg in "\$@"; do
  case "\$arg" in
    --root=*source*) cat "\${DPKG_VERIFY_SOURCE_FIXTURE:-${WORK}/empty}"; exit 0 ;;
    --root=*target*) cat "\${DPKG_VERIFY_TARGET_FIXTURE:-${WORK}/empty}"; exit 0 ;;
  esac
done
exit 0
EOF
chmod +x "${WORK}/bin/dpkg"

cat >"${WORK}/bin/rsync" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"${RSYNC_CALLS}"
[[ -n "\${RSYNC_SLEEP:-}" ]] && sleep "\${RSYNC_SLEEP}"
exit "\${RSYNC_EXIT:-0}"
EOF
chmod +x "${WORK}/bin/rsync"

cat >"${WORK}/bin/mount" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"${MOUNT_CALLS}"
exit "\${MOUNT_EXIT:-0}"
EOF
chmod +x "${WORK}/bin/mount"

cat >"${WORK}/bin/umount" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"${UMOUNT_CALLS}"
exit 0
EOF
chmod +x "${WORK}/bin/umount"

cat >"${WORK}/bin/e2fsck" <<'EOF'
#!/bin/bash
exit "${E2FSCK_EXIT:-0}"
EOF
chmod +x "${WORK}/bin/e2fsck"

# ---------------------------------------------------------------------------
# Environment: every path the script reads is overridden into WORK, so the
# unprivileged tier never touches a real device path.
# ---------------------------------------------------------------------------

export RAUC_BIN="${WORK}/bin/rauc"
export SYSTEMCTL_BIN="${WORK}/bin/systemctl"
export CERALIVE_BUSCTL="${WORK}/bin/busctl"
export DPKG_BIN="${WORK}/bin/dpkg"
export RSYNC_BIN="${WORK}/bin/rsync"
export MOUNT_BIN="${WORK}/bin/mount"
export UMOUNT_BIN="${WORK}/bin/umount"
export E2FSCK_BIN="${WORK}/bin/e2fsck"
export SYNC_BIN="true"
export SHA256SUM_BIN="sha256sum"

export CERALIVE_UPDATE_LOCK_PATH="${WORK}/run/lock/ceralive-update.lock"
export CERALIVE_DPKG_LOCK_FRONTEND="${WORK}/run/lock/dpkg-lock-frontend"
export CERALIVE_PARTLABEL_FAILURE="${WORK}/run/partlabel-guard.failed"
export CERALIVE_SLOT_SYNC_DATA_ROOT="${WORK}/data"
export CERALIVE_UPDATE_STATE_DIR="${WORK}/data/ceralive/update-state"
export CERALIVE_HEALTHY_STATE_FILE="${WORK}/data/ceralive/update-state/healthy-state.json"
export CERALIVE_SYNC_RECEIPT_FILE="${WORK}/data/ceralive/update-state/sync-receipt.json"
export CERALIVE_RAUC_DATA_DIR="${WORK}/data/ceralive/rauc"
export CERALIVE_SLOT_SYNC_SOURCE="${WORK}/mnt/source"
export CERALIVE_SLOT_SYNC_TARGET="${WORK}/mnt/target"
export CERALIVE_SLOT_SYNC_BIND_SOURCE="${WORK}/srcroot"
export CERALIVE_SLOT_SYNC_EXCLUDE="${EXCLUDE_SRC}"
export CERALIVE_PRUNE_PATHS_LIST="${WORK}/prune-paths.list.absent"
export CERALIVE_HEALTHCHECK_BOOT_ID_FILE="${WORK}/boot-id"
export CERALIVE_DPKG_STATUS_FILE="${WORK}/dpkg-status"
export CERALIVE_HAWKBIT_SERVICE="rauc-hawkbit-updater.service"
export CERALIVE_OS_RELEASE_FILE="${WORK}/os-release"
export CERALIVE_IMAGE_VERSION_FILE="${WORK}/image-version.absent"
export RAUC_JSON_FIXTURE="${WORK}/rauc-status.json"

mkdir -p "${WORK}/srcroot"
printf '00000000-0000-0000-0000-00000000dead\n' >"${WORK}/boot-id"
printf 'a dpkg status db\n' >"${WORK}/dpkg-status"
printf 'BUILD_ID="2026.9.99"\n' >"${WORK}/os-release"

BOOT_ID="00000000-0000-0000-0000-00000000dead"
BUILD_ID="2026.9.99"
DPKG_SHA="$(sha256sum "${WORK}/dpkg-status" | awk '{print $1}')"

healthy_state_write() {
  cat >"${CERALIVE_HEALTHY_STATE_FILE}" <<EOF
{"boot_id":"$1","slot":"rootfs.0","build_id":"$3","dpkg_status_sha256":"$2","recorded_at":"2026-09-23T00:00:00Z"}
EOF
}

# rauc_json_fixture <other-slot-extra-json-fragment> — a two-slot rootfs.0
# (booted, class rootfs) / rootfs.1 (other, class rootfs) status document,
# matching RAUC's own emitted shape (json_slot_names/json_slot_object depend on
# this exact nesting: name -> {class, device, ..., [bundle], [installed],
# [activated], status}).
rauc_json_fixture() {
  local other_extra="${1:-}"
  cat >"${RAUC_JSON_FIXTURE}" <<EOF
{"compatible":"ceralive-test","variant":"","booted":"A","boot_primary":"rootfs.0","slots":[{"rootfs.0":{"class":"rootfs","device":"${WORK}/mnt/source","type":"ext4","bootname":"A","state":"booted","parent":null,"mountpoint":"/","boot_status":"good","bundle":{"compatible":"ceralive-test","version":"${BUILD_ID}"},"installed":{"timestamp":"2026-09-20T00:00:00Z","count":3},"activated":{"timestamp":"2026-09-20T00:00:05Z","count":3},"status":"ok"}},{"rootfs.1":{"class":"rootfs","device":"${WORK}/mnt/target","type":"ext4","bootname":"B","state":"inactive","parent":null,"mountpoint":null,"boot_status":"good"${other_extra},"status":"ok"}}]}
EOF
}

reset_happy_fixtures() {
  rm -f "${CERALIVE_PARTLABEL_FAILURE}"
  unset DPKG_AUDIT_FIXTURE DPKG_VERIFY_SOURCE_FIXTURE DPKG_VERIFY_TARGET_FIXTURE
  unset RAUC_OPERATION_FIXTURE HAWKBIT_ACTIVE_FIXTURE RAUC_MARK_BAD_FAIL RAUC_MARK_GOOD_FAIL
  unset RSYNC_EXIT RSYNC_SLEEP MOUNT_EXIT E2FSCK_EXIT
  rauc_json_fixture ""   # other slot NEVER installed -> not pending
  healthy_state_write "${BOOT_ID}" "${DPKG_SHA}" "${BUILD_ID}"
  rm -f "${CERALIVE_SYNC_RECEIPT_FILE}"
  : >"${RAUC_CALLS}"; : >"${RSYNC_CALLS}"; : >"${MOUNT_CALLS}"; : >"${UMOUNT_CALLS}"
}

run_check() { "${SCRIPT}" check; }
run_run()   { "${SCRIPT}" run; }

# ===========================================================================
# 1. Refusal-gate matrix (run) — each gate + each lock produces exit 75 and a
#    distinguishable, named reason, and NEVER reaches mark-bad/mark-good.
# ===========================================================================

reset_happy_fixtures
touch "${CERALIVE_PARTLABEL_FAILURE}"
out="$(run_run 2>&1)"; rc=$?
assert_eq "gate 1 (partlabel-guard-failed) exit code" 75 "${rc}"
assert_contains "gate 1 reason in stderr" <(printf '%s' "${out}") "partlabel-guard-failed" 2>/dev/null \
  || { printf '%s' "${out}" | grep -qF 'partlabel-guard-failed' && ok "gate 1 reason in stderr" || bad "gate 1 reason in stderr: ${out}"; }
[[ ! -s "${RAUC_CALLS}" ]] && ok "gate 1 never reaches rauc" || bad "gate 1 called rauc: $(<"${RAUC_CALLS}")"

reset_happy_fixtures
printf 'some malformed conffile\n' >"${WORK}/dpkg-audit.txt"
export DPKG_AUDIT_FIXTURE="${WORK}/dpkg-audit.txt"
out="$(run_run 2>&1)"; rc=$?
assert_eq "gate 2 (dpkg-audit-nonempty) exit code" 75 "${rc}"
printf '%s' "${out}" | grep -qF 'dpkg-audit-nonempty' && ok "gate 2 reason in stderr" || bad "gate 2 reason: ${out}"
unset DPKG_AUDIT_FIXTURE

reset_happy_fixtures
export RAUC_OPERATION_FIXTURE="installing"
out="$(run_run 2>&1)"; rc=$?
assert_eq "gate 3 (rauc-operation-busy) exit code" 75 "${rc}"
printf '%s' "${out}" | grep -qF 'rauc-operation-busy' && ok "gate 3 reason in stderr" || bad "gate 3 reason: ${out}"
unset RAUC_OPERATION_FIXTURE

reset_happy_fixtures
rauc_json_fixture ',"installed":{"timestamp":"2026-09-22T00:00:00Z","count":1}'
out="$(run_run 2>&1)"; rc=$?
assert_eq "gate 4 (other-slot-pending-activation) exit code" 75 "${rc}"
printf '%s' "${out}" | grep -qF 'other-slot-pending-activation' && ok "gate 4 reason in stderr" || bad "gate 4 reason: ${out}"

reset_happy_fixtures
export HAWKBIT_ACTIVE_FIXTURE=1
out="$(run_run 2>&1)"; rc=$?
assert_eq "gate 5 (hawkbit-updater-active) exit code" 75 "${rc}"
printf '%s' "${out}" | grep -qF 'hawkbit-updater-active' && ok "gate 5 reason in stderr" || bad "gate 5 reason: ${out}"
unset HAWKBIT_ACTIVE_FIXTURE

reset_happy_fixtures
rm -f "${CERALIVE_HEALTHY_STATE_FILE}"
out="$(run_run 2>&1)"; rc=$?
assert_eq "gate 6a (healthy-state-missing) exit code" 75 "${rc}"
printf '%s' "${out}" | grep -qF 'healthy-state-missing' && ok "gate 6a reason in stderr" || bad "gate 6a reason: ${out}"

reset_happy_fixtures
healthy_state_write "wrong-boot-id" "${DPKG_SHA}" "${BUILD_ID}"
out="$(run_run 2>&1)"; rc=$?
assert_eq "gate 6b (healthy-state-mismatch, boot_id) exit code" 75 "${rc}"
printf '%s' "${out}" | grep -qF 'healthy-state-mismatch' && ok "gate 6b reason in stderr" || bad "gate 6b reason: ${out}"

reset_happy_fixtures
healthy_state_write "${BOOT_ID}" "deadbeef" "${BUILD_ID}"
out="$(run_run 2>&1)"; rc=$?
assert_eq "gate 6c (healthy-state-mismatch, dpkg sha) exit code" 75 "${rc}"

reset_happy_fixtures
healthy_state_write "${BOOT_ID}" "${DPKG_SHA}" "some-other-build"
out="$(run_run 2>&1)"; rc=$?
assert_eq "gate 6d (healthy-state-mismatch, build_id) exit code" 75 "${rc}"

reset_happy_fixtures
exec 7>"${CERALIVE_UPDATE_LOCK_PATH}"
flock -x 7
out="$(run_run 2>&1)"; rc=$?
flock -u 7; exec 7>&-
assert_eq "lock 1 (update-lock-busy) exit code" 75 "${rc}"
printf '%s' "${out}" | grep -qF 'update-lock-busy' && ok "lock 1 reason in stderr" || bad "lock 1 reason: ${out}"

reset_happy_fixtures
exec 7>"${CERALIVE_DPKG_LOCK_FRONTEND}"
flock -x 7
out="$(run_run 2>&1)"; rc=$?
flock -u 7; exec 7>&-
assert_eq "lock 2 (dpkg-lock-busy) exit code" 75 "${rc}"
printf '%s' "${out}" | grep -qF 'dpkg-lock-busy' && ok "lock 2 reason in stderr" || bad "lock 2 reason: ${out}"

# ===========================================================================
# 2. `check` — read-only, takes no locks, reports gate inputs as JSON.
# ===========================================================================

reset_happy_fixtures
cp "${HERE}/fixtures/rauc-1.15.2-rock-status.json" "${RAUC_JSON_FIXTURE}"
eval "$(sed -n '/^json_slots_array()/,/^}/p; /^json_slot_names()/,/^}/p; /^json_slot_object()/,/^}/p' "${SCRIPT}")"
real_rauc_json="$(<"${RAUC_JSON_FIXTURE}")"
assert_eq "real RAUC 1.15.2: names exclude all nested bundle keys" $'rootfs.1\nrootfs.0\ncerts.0' "$(json_slot_names "${real_rauc_json}")"
real_slot="$(json_slot_object "${real_rauc_json}" rootfs.0)"
[[ "${real_slot}" == *'"slot_status":{"bundle":{"compatible":null}}}' ]] && ok "real RAUC 1.15.2: slot object includes the complete nested bundle" || bad "truncated slot object: ${real_slot}"
deep_replacement='"compatible":{"extra":{"depth":4}}'
deep_json="${real_rauc_json//\"compatible\":null/${deep_replacement}}"
deep_slot="$(json_slot_object "${deep_json}" rootfs.0)"
[[ "${deep_slot}" == *'"compatible":{"extra":{"depth":4}}}}}' ]] && ok "nested object depth beyond RAUC 1.15.2 stays balanced" || bad "truncated deep slot object: ${deep_slot}"
healthy_state_write "wrong-boot-id" "${DPKG_SHA}" "${BUILD_ID}"
out="$(run_check)"; rc=$?
assert_eq "real RAUC 1.15.2: check exits successfully" 0 "${rc}"
printf '%s' "${out}" | grep -qF '"other_slot":"rootfs.0"' && ok "real RAUC 1.15.2: only the inactive rootfs slot is selected" || bad "check output: ${out}"
printf '%s' "${out}" | grep -qF '"other_slot_device":"/dev/disk/by-partlabel/rootfs_a"' && ok "real RAUC 1.15.2: complete nested slot object exposes device" || bad "check output: ${out}"
printf '%s' "${out}" | grep -qF '"refuse_reason":"healthy-state-mismatch"' && ok "real RAUC 1.15.2: reports the actual blocking gate" || bad "check output: ${out}"

reset_happy_fixtures
out="$(run_check)"; rc=$?
assert_eq "check exit code on healthy fixture" 0 "${rc}"
printf '%s' "${out}" | grep -qF '"would_refuse":false' && ok "check: healthy fixture would not refuse" || bad "check output: ${out}"
printf '%s' "${out}" | grep -qF '"rauc_operation":"idle"' && ok "check: reports rauc_operation" || bad "check output: ${out}"
printf '%s' "${out}" | grep -qF '"other_slot":"rootfs.1"' && ok "check: resolves other_slot by name (never a PARTLABEL)" || bad "check output: ${out}"
printf '%s' "${out}" | grep -qF "\"other_slot_device\":\"${WORK}/mnt/target\"" && ok "check: resolves other_slot_device from rauc status" || bad "check output: ${out}"
grep -qF 'status --detailed --output-format=json' "${RAUC_CALLS}" && ok "check calls rauc status --detailed --output-format=json" || bad "check did not query rauc status"
[[ ! -e "${CERALIVE_UPDATE_LOCK_PATH}.held" ]] && ok "check takes no destructive action" || bad "check acted destructively"

reset_happy_fixtures
rauc_json_fixture ',"installed":{"timestamp":"2026-09-22T00:00:00Z","count":1}'
out="$(run_check)"
printf '%s' "${out}" | grep -qF '"would_refuse":true' && ok "check: pending-activation fixture reports would_refuse" || bad "check output: ${out}"
printf '%s' "${out}" | grep -qF '"refuse_reason":"other-slot-pending-activation"' && ok "check: reports the exact refuse reason" || bad "check output: ${out}"
printf '%s' "${out}" | grep -qF '"other_slot_installed":true' && ok "check: other_slot_installed true" || bad "check output: ${out}"
printf '%s' "${out}" | grep -qF '"other_slot_activated":false' && ok "check: other_slot_activated false" || bad "check output: ${out}"

# ===========================================================================
# 3. Happy path: full run, stubbed mount/rsync/e2fsck, real filesystem ops for
#    adaptive-index deletion and the sync-receipt.
# ===========================================================================

reset_happy_fixtures
mkdir -p "${CERALIVE_RAUC_DATA_DIR}/slot.rootfs.1/hash-deadbeef" "${CERALIVE_RAUC_DATA_DIR}/slot.rootfs.0/hash-untouched"
printf 'stale-index-bytes\n' >"${CERALIVE_RAUC_DATA_DIR}/slot.rootfs.1/hash-deadbeef/block-hash-index"
printf 'must-not-be-touched\n' >"${CERALIVE_RAUC_DATA_DIR}/slot.rootfs.0/hash-untouched/block-hash-index"

out="$(run_run 2>&1)"; rc=$?
assert_eq "happy path exit code" 0 "${rc}"

grep -qF 'status mark-bad other' "${RAUC_CALLS}" && ok "happy path calls mark-bad other" || bad "happy path did not call mark-bad: $(<"${RAUC_CALLS}")"
grep -qF 'status mark-good other' "${RAUC_CALLS}" && ok "happy path calls mark-good other" || bad "happy path did not call mark-good: $(<"${RAUC_CALLS}")"
bad_line="$(grep -n 'mark-bad other' "${RAUC_CALLS}" | head -n1 | cut -d: -f1)"
good_line="$(grep -n 'mark-good other' "${RAUC_CALLS}" | head -n1 | cut -d: -f1)"
if [[ -n "${bad_line}" && -n "${good_line}" && "${bad_line}" -lt "${good_line}" ]]; then
  ok "mark-bad precedes mark-good"
else
  bad "mark-bad/mark-good ordering wrong: ${bad_line} vs ${good_line}"
fi

grep -qF -- '--checksum' "${RSYNC_CALLS}" && ok "rsync invoked with --checksum" || bad "rsync call missing --checksum: $(<"${RSYNC_CALLS}")"
grep -qF -- '--delete' "${RSYNC_CALLS}" && ok "rsync invoked with --delete" || bad "rsync call missing --delete"
grep -qF -- '-aHAXS' "${RSYNC_CALLS}" && ok "rsync invoked with -aHAXS" || bad "rsync call missing -aHAXS"
grep -qF -- "--exclude-from=${EXCLUDE_SRC}" "${RSYNC_CALLS}" && ok "rsync uses the shipped exclude file" || bad "rsync exclude-from missing: $(<"${RSYNC_CALLS}")"

[[ -e "${CERALIVE_RAUC_DATA_DIR}/slot.rootfs.1/hash-deadbeef" ]] && bad "stale adaptive index for the target slot survived" \
  || ok "stale adaptive index for the mirrored (target) slot was deleted"
[[ -e "${CERALIVE_RAUC_DATA_DIR}/slot.rootfs.0/hash-untouched" ]] && ok "the OTHER slot's own adaptive index was left untouched" \
  || bad "deletion was not scoped to the target slot — it touched a different slot's data"

[[ -f "${CERALIVE_SYNC_RECEIPT_FILE}" ]] && ok "sync-receipt.json written" || bad "sync-receipt.json missing"
receipt="$(<"${CERALIVE_SYNC_RECEIPT_FILE}")"
printf '%s' "${receipt}" | grep -qF "\"state_sha256\": \"${DPKG_SHA}\"" && ok "receipt state_sha256 == current dpkg status sha256" || bad "receipt: ${receipt}"
printf '%s' "${receipt}" | grep -qF "\"build_id\": \"${BUILD_ID}\"" && ok "receipt build_id from /etc/os-release BUILD_ID" || bad "receipt: ${receipt}"
printf '%s' "${receipt}" | grep -qF "\"image_version\": \"${BUILD_ID}\"" && ok "receipt image_version from the BOOTED slot's bundle version" || bad "receipt: ${receipt}"
printf '%s' "${receipt}" | grep -qF '"target_slot": "rootfs.1"' && ok "receipt target_slot is the mirrored (other) slot" || bad "receipt: ${receipt}"

grep -qF "${WORK}/srcroot" "${MOUNT_CALLS}" && ok "bind-mounts BIND_SOURCE_ROOT at the source mountpoint" || bad "mount calls: $(<"${MOUNT_CALLS}")"
grep -qE '^--bind ' "${MOUNT_CALLS}" && ok "source mount uses --bind (non-recursive, never --rbind)" || bad "mount calls: $(<"${MOUNT_CALLS}")"
grep -qF -- '--rbind' "${MOUNT_CALLS}" && bad "source mount used --rbind (must be non-recursive --bind)" || ok "source mount never uses --rbind"
grep -qF "${WORK}/mnt/target" "${UMOUNT_CALLS}" && grep -qF "${WORK}/srcroot" "${MOUNT_CALLS}" \
  && ok "both mounts were exercised" || bad "expected both source and target mount activity"
grep -qF "${CERALIVE_SLOT_SYNC_SOURCE}" "${UMOUNT_CALLS}" && grep -qF "${CERALIVE_SLOT_SYNC_TARGET}" "${UMOUNT_CALLS}" \
  && ok "both mountpoints were unmounted on success" || bad "unmount calls: $(<"${UMOUNT_CALLS}")"

# ===========================================================================
# 4. dpkg --verify comparison: mismatch aborts, identical non-empty passes,
#    and prune-paths.list filtering makes a pruned-only difference a non-issue.
# ===========================================================================

reset_happy_fixtures
printf '??5?????? c /etc/only-on-source.conf\n' >"${WORK}/verify-source.txt"
printf '\n' >"${WORK}/verify-target.txt"
export DPKG_VERIFY_SOURCE_FIXTURE="${WORK}/verify-source.txt"
export DPKG_VERIFY_TARGET_FIXTURE="${WORK}/verify-target.txt"
out="$(run_run 2>&1)"; rc=$?
assert_eq "dpkg-verify mismatch aborts (exit code)" 1 "${rc}"
grep -qF 'status mark-good other' "${RAUC_CALLS}" && bad "mark-good called despite a verify mismatch" || ok "mark-good NEVER called on a verify mismatch"
grep -qF "${CERALIVE_SLOT_SYNC_TARGET}" "${UMOUNT_CALLS}" && ok "target unmounted after an aborted verify comparison" || bad "target was not unmounted: $(<"${UMOUNT_CALLS}")"

reset_happy_fixtures
printf '??5?????? c /etc/modified-conffile.conf\n' >"${WORK}/verify-both.txt"
export DPKG_VERIFY_SOURCE_FIXTURE="${WORK}/verify-both.txt"
export DPKG_VERIFY_TARGET_FIXTURE="${WORK}/verify-both.txt"
out="$(run_run 2>&1)"; rc=$?
assert_eq "identical non-empty verify output (conffile modified on both) does not fail" 0 "${rc}"
grep -qF 'status mark-good other' "${RAUC_CALLS}" && ok "mark-good called when verify output is identical, even though non-empty" || bad "mark-good not called: $(<"${RAUC_CALLS}")"

reset_happy_fixtures
printf '??5?????? c /var/log/pruned.log\n' >"${WORK}/verify-source-pruned.txt"
: >"${WORK}/verify-target-pruned.txt"
printf '/var/log/*\n' >"${WORK}/prune-paths.list"
export CERALIVE_PRUNE_PATHS_LIST="${WORK}/prune-paths.list"
export DPKG_VERIFY_SOURCE_FIXTURE="${WORK}/verify-source-pruned.txt"
export DPKG_VERIFY_TARGET_FIXTURE="${WORK}/verify-target-pruned.txt"
out="$(run_run 2>&1)"; rc=$?
assert_eq "a prune-paths.list-matched difference is not a verify failure" 0 "${rc}"
export CERALIVE_PRUNE_PATHS_LIST="${WORK}/prune-paths.list.absent"

# ===========================================================================
# 5. Operational abort mid-rsync leaves the target marked bad.
# ===========================================================================

reset_happy_fixtures
export RSYNC_EXIT=1
out="$(run_run 2>&1)"; rc=$?
assert_eq "rsync failure aborts (not a refusal — operational exit code)" 1 "${rc}"
grep -qF 'status mark-bad other' "${RAUC_CALLS}" && ok "target was marked bad before the failing rsync" || bad "mark-bad missing: $(<"${RAUC_CALLS}")"
grep -qF 'status mark-good other' "${RAUC_CALLS}" && bad "mark-good called despite a failed rsync" || ok "mark-good NEVER called after a failed rsync — target stays bad"
grep -qF "${CERALIVE_SLOT_SYNC_TARGET}" "${UMOUNT_CALLS}" && ok "target unmounted after a failed rsync" || bad "target not unmounted: $(<"${UMOUNT_CALLS}")"
unset RSYNC_EXIT

# ===========================================================================
# 6. SIGTERM mid-rsync: unmount, leave bad, exit 143.
# ===========================================================================

reset_happy_fixtures
export RSYNC_SLEEP=10
"${SCRIPT}" run >"${WORK}/sigterm-run.out" 2>&1 &
run_pid=$!
deadline=$((SECONDS + 20))
while [[ ! -s "${RSYNC_CALLS}" ]] && [[ ${SECONDS} -lt ${deadline} ]]; do sleep 0.1; done
if [[ -s "${RSYNC_CALLS}" ]]; then
  ok "SIGTERM scenario: reached the rsync phase before signalling"
  kill -TERM "${run_pid}" 2>/dev/null
  wait "${run_pid}"
  term_rc=$?
  assert_eq "SIGTERM exit code" 143 "${term_rc}"
  grep -qF 'status mark-bad other' "${RAUC_CALLS}" && ok "SIGTERM: target had already been marked bad" || bad "SIGTERM: mark-bad missing"
  grep -qF 'status mark-good other' "${RAUC_CALLS}" && bad "SIGTERM: mark-good was called — target must stay bad" || ok "SIGTERM: mark-good NEVER called"
  grep -qF "${CERALIVE_SLOT_SYNC_TARGET}" "${UMOUNT_CALLS}" && ok "SIGTERM: target unmounted" || bad "SIGTERM: target not unmounted: $(<"${UMOUNT_CALLS}")"
  grep -qF "${CERALIVE_SLOT_SYNC_SOURCE}" "${UMOUNT_CALLS}" && ok "SIGTERM: source unmounted" || bad "SIGTERM: source not unmounted: $(<"${UMOUNT_CALLS}")"
else
  bad "SIGTERM scenario never reached the rsync phase within the deadline: $(<"${WORK}/sigterm-run.out")"
  kill -KILL "${run_pid}" 2>/dev/null || true
fi
unset RSYNC_SLEEP

# ===========================================================================
# 7. --checksum genuinely matters: same size + same mtime, different content.
#    Extracts the shipped rsync flags by TEXT from the real script (the
#    "static test reads by TEXT" rule) and drives the REAL rsync binary
#    directly on plain directories — no mount needed for this property.
# ===========================================================================

shipped_rsync_flags="$(grep -A1 'local -a rsync_args=' "${SCRIPT}" | tr -d '\n')"
printf '%s' "${shipped_rsync_flags}" | grep -qF -- '--checksum' \
  && ok "shipped rsync invocation carries --checksum (extracted by text from the real script)" \
  || bad "shipped rsync invocation is missing --checksum: ${shipped_rsync_flags}"

if command -v rsync >/dev/null 2>&1; then
  mkdir -p "${WORK}/checksum-src" "${WORK}/checksum-dst"
  printf 'AAAA' >"${WORK}/checksum-src/same-size-same-mtime.bin"
  printf 'BBBB' >"${WORK}/checksum-dst/same-size-same-mtime.bin"
  touch -t 202601010000 "${WORK}/checksum-src/same-size-same-mtime.bin" "${WORK}/checksum-dst/same-size-same-mtime.bin"
  rsync -aHAXS --checksum --numeric-ids --delete \
    "${WORK}/checksum-src/" "${WORK}/checksum-dst/" >/dev/null
  if [[ "$(<"${WORK}/checksum-dst/same-size-same-mtime.bin")" == "AAAA" ]]; then
    ok "--checksum copies a same-size/same-mtime file whose CONTENT differs"
  else
    bad "--checksum did not catch a content-only difference (quick-check would have skipped it)"
  fi
else
  bad "rsync is not available on this host — cannot prove the --checksum property"
fi

# ===========================================================================
# 8. Static contract: the unit, the exclude list, and the wiring.
# ===========================================================================

[[ -f "${SERVICE_SRC}" ]] && ok "ceralive-slot-sync.service exists" || bad "missing ${SERVICE_SRC}"
grep -qE '^\[Install\]' "${SERVICE_SRC}" && bad "ceralive-slot-sync.service carries an [Install] section — it must not be boot-enabled" \
  || ok "ceralive-slot-sync.service carries NO [Install] section"
grep -qF 'Type=oneshot' "${SERVICE_SRC}" && ok "unit is Type=oneshot" || bad "unit is not Type=oneshot"
grep -qF 'IOSchedulingClass=idle' "${SERVICE_SRC}" && ok "unit sets IOSchedulingClass=idle" || bad "unit missing IOSchedulingClass=idle"
grep -qF 'Nice=19' "${SERVICE_SRC}" && ok "unit sets Nice=19" || bad "unit missing Nice=19"
grep -qF '/usr/libexec/ceralive/ceralive-slot-sync run' "${SERVICE_SRC}" && ok "unit's ExecStart targets /usr/libexec/ceralive/ceralive-slot-sync run" || bad "unit ExecStart wrong"

for entry in '/var/cache/apt/archives/\*' '/tmp/\*' '/var/tmp/\*' '/run/\*' '/proc/\*' '/sys/\*' '/dev/\*' '/lost\+found'; do
  grep -qE "^${entry}$" "${EXCLUDE_SRC}" && ok "exclude list carries ${entry}" || bad "exclude list missing ${entry}"
done

grep -qF 'setup_slot_sync' "${ROOT}/mkosi/customize/postinst.d/services.sh" \
  && ok "setup_slot_sync is wired into configure_services()" \
  || bad "setup_slot_sync is not called anywhere in postinst.d/services.sh"
grep -qF 'setup_slot_sync() {' "${ROOT}/mkosi/customize/postinst.d/persistence.sh" \
  && ok "setup_slot_sync is defined in postinst.d/persistence.sh" \
  || bad "setup_slot_sync is not defined in postinst.d/persistence.sh"
# This effort's Todo 22 (verity bundles) is uncommitted WIP in
# mkosi.images/runtime/mkosi.postinst.chroot; this task must not touch it —
# confirm the wiring above does not depend on editing that file.
grep -qF 'setup_slot_sync' "${ROOT}/mkosi/mkosi.images/runtime/mkosi.postinst.chroot" \
  && bad "setup_slot_sync must not be called directly from mkosi.postinst.chroot (Todo 22 owns that file right now)" \
  || ok "no new call added to mkosi.postinst.chroot — wiring goes through configure_services() instead"

# ===========================================================================
# 9. PRIVILEGED leg: real loop-mounted ext4 target + real mount/rsync/e2fsck.
#    Proves xattr/ACL/file-cap/hardlink/sparse preservation and the hidden
#    ext4-under-a-non-recursive-bind-mount trick. Gated like the other real-*
#    contracts in this repo: skip by default, required fails hard if the host
#    cannot actually run it.
# ===========================================================================

SLOT_SYNC_CONTRACT="${CERALIVE_RUN_REAL_SLOT_SYNC_CONTRACT:-skip}"
case "${SLOT_SYNC_CONTRACT}" in
  required | skip) ;;
  *)
    echo "ERROR: CERALIVE_RUN_REAL_SLOT_SYNC_CONTRACT must be 'required' or 'skip'" >&2
    exit 2
    ;;
esac

real_slot_sync_available() {
  [[ "$(id -u)" == "0" ]] || sudo -n true 2>/dev/null || return 1
  for tool in losetup mkfs.ext4 mount umount e2fsck setfacl getfacl setcap getcap rsync; do
    command -v "${tool}" >/dev/null 2>&1 || return 1
  done
  return 0
}

as_root() {
  if [[ "$(id -u)" == "0" ]]; then "$@"; else sudo -n "$@"; fi
}

if real_slot_sync_available; then
  PRIV_WORK="${WORK}/priv"
  mkdir -p "${PRIV_WORK}"
  loop_dev=""

  priv_cleanup() {
    as_root umount "${PRIV_WORK}/mnt-check" 2>/dev/null || true
    if [[ -n "${loop_dev}" ]]; then
      as_root losetup -d "${loop_dev}" 2>/dev/null || true
    fi
    as_root umount "${PRIV_WORK}/hidden-boot-check" 2>/dev/null || true
    as_root umount "${PRIV_WORK}/fixture/boot" 2>/dev/null || true
  }
  trap 'priv_cleanup; cleanup' EXIT

  truncate -s 96M "${PRIV_WORK}/target.img"
  loop_dev="$(as_root losetup --find --show "${PRIV_WORK}/target.img")"
  if [[ -z "${loop_dev}" ]]; then
    bad "privileged leg: could not attach a loop device"
  else
    as_root mkfs.ext4 -q -F -L rootfs_test "${loop_dev}"
    as_root chmod 0666 "${loop_dev}"

    # Bind-source fixture: a plain directory tree with a real /boot subdir
    # (the ext4-level content the FAT mount hides), plus xattr/ACL/cap/
    # hardlink/sparse special files.
    mkdir -p "${PRIV_WORK}/fixture/boot" "${PRIV_WORK}/fixture/usr/bin" "${PRIV_WORK}/fixture/etc"
    printf 'ext4-level-boot-content\n' >"${PRIV_WORK}/fixture/boot/hidden-marker.txt"

    # Hardlink pair.
    printf 'hardlinked payload\n' >"${PRIV_WORK}/fixture/etc/original"
    ln "${PRIV_WORK}/fixture/etc/original" "${PRIV_WORK}/fixture/etc/hardlinked"

    # Sparse file: a real 8 MiB hole with two written bytes at each end.
    dd if=/dev/zero of="${PRIV_WORK}/fixture/etc/sparse.bin" bs=1 count=1 seek=8388606 conv=notrunc status=none 2>/dev/null || true
    truncate -s 8388607 "${PRIV_WORK}/fixture/etc/sparse.bin"

    # xattr + ACL + file capability, each best-effort so an unsupported
    # underlying test-host filesystem degrades a single sub-check rather than
    # the whole privileged leg.
    if setfattr -n user.ceralive.test -v hello "${PRIV_WORK}/fixture/etc/original" 2>/dev/null; then
      xattr_ok=1
    else
      xattr_ok=0
    fi
    if setfacl -m u:nobody:r "${PRIV_WORK}/fixture/etc/original" 2>/dev/null; then
      acl_ok=1
    else
      acl_ok=0
    fi
    printf '#!/bin/sh\nexit 0\n' >"${PRIV_WORK}/fixture/usr/bin/capped"
    chmod +x "${PRIV_WORK}/fixture/usr/bin/capped"
    if as_root setcap cap_net_bind_service=+ep "${PRIV_WORK}/fixture/usr/bin/capped" 2>/dev/null; then
      cap_ok=1
    else
      cap_ok=0
    fi

    # The hidden-/boot-under-a-non-recursive-bind-mount property, proven in
    # isolation first: mount a tmpfs OVER the fixture's own ext4-level /boot
    # (simulating the FAT mount install-boot.sh:171-180 documents), then
    # non-recursively bind the fixture root elsewhere and confirm /boot there
    # resolves to the ORIGINAL content, not the tmpfs.
    as_root mount -t tmpfs tmpfs "${PRIV_WORK}/fixture/boot"
    printf 'fat-level-content-must-not-appear\n' | as_root tee "${PRIV_WORK}/fixture/boot/fat-marker.txt" >/dev/null
    mkdir -p "${PRIV_WORK}/hidden-boot-check"
    as_root mount --bind "${PRIV_WORK}/fixture" "${PRIV_WORK}/hidden-boot-check"
    if [[ -f "${PRIV_WORK}/hidden-boot-check/boot/hidden-marker.txt" && ! -e "${PRIV_WORK}/hidden-boot-check/boot/fat-marker.txt" ]]; then
      ok "non-recursive bind mount exposes the ext4-level /boot content, not the tmpfs mounted over it"
    else
      bad "non-recursive bind mount did not expose the hidden ext4-level /boot content as documented"
    fi
    as_root umount "${PRIV_WORK}/hidden-boot-check" 2>/dev/null || true
    as_root umount "${PRIV_WORK}/fixture/boot" 2>/dev/null || true

    # Full end-to-end run against the real loop device, still with the
    # unprivileged rauc/busctl/systemctl/dpkg stubs (no real D-Bus/RAUC
    # service or dpkg database needed to prove the filesystem-level contract).
    export MOUNT_BIN="mount"
    export UMOUNT_BIN="umount"
    export RSYNC_BIN="rsync"
    export E2FSCK_BIN="e2fsck"
    reset_happy_fixtures
    export CERALIVE_SLOT_SYNC_BIND_SOURCE="${PRIV_WORK}/fixture"
    rauc_json_fixture ""
    # rewrite the device in the fixture to the real loop device
    sed -i "s#${WORK}/mnt/target#${loop_dev}#" "${RAUC_JSON_FIXTURE}"

    priv_run_log="${PRIV_WORK}/run.log"
    # RAUC_BIN/SYSTEMCTL_BIN/CERALIVE_BUSCTL/DPKG_BIN are absolute stub paths
    # and need no PATH help. MOUNT_BIN/UMOUNT_BIN/RSYNC_BIN/E2FSCK_BIN are bare
    # names that must resolve to the REAL binaries via the unmodified system
    # PATH — a "${WORK}/bin:${PATH}" prefix here would resolve them to this
    # same file's own mount/rsync/e2fsck STUBS instead, which only record argv
    # and exit 0, so the leg would "succeed" while mounting and copying nothing.
    as_root env \
      RAUC_BIN="${WORK}/bin/rauc" SYSTEMCTL_BIN="${WORK}/bin/systemctl" \
      CERALIVE_BUSCTL="${WORK}/bin/busctl" DPKG_BIN="${WORK}/bin/dpkg" \
      MOUNT_BIN=mount UMOUNT_BIN=umount RSYNC_BIN=rsync E2FSCK_BIN=e2fsck SYNC_BIN=sync \
      SHA256SUM_BIN=sha256sum \
      RAUC_JSON_FIXTURE="${RAUC_JSON_FIXTURE}" \
      CERALIVE_UPDATE_LOCK_PATH="${CERALIVE_UPDATE_LOCK_PATH}" \
      CERALIVE_DPKG_LOCK_FRONTEND="${CERALIVE_DPKG_LOCK_FRONTEND}" \
      CERALIVE_PARTLABEL_FAILURE="${CERALIVE_PARTLABEL_FAILURE}" \
      CERALIVE_SLOT_SYNC_DATA_ROOT="${CERALIVE_SLOT_SYNC_DATA_ROOT}" \
      CERALIVE_UPDATE_STATE_DIR="${CERALIVE_UPDATE_STATE_DIR}" \
      CERALIVE_HEALTHY_STATE_FILE="${CERALIVE_HEALTHY_STATE_FILE}" \
      CERALIVE_SYNC_RECEIPT_FILE="${CERALIVE_SYNC_RECEIPT_FILE}" \
      CERALIVE_RAUC_DATA_DIR="${CERALIVE_RAUC_DATA_DIR}" \
      CERALIVE_SLOT_SYNC_SOURCE="${CERALIVE_SLOT_SYNC_SOURCE}" \
      CERALIVE_SLOT_SYNC_TARGET="${CERALIVE_SLOT_SYNC_TARGET}" \
      CERALIVE_SLOT_SYNC_BIND_SOURCE="${PRIV_WORK}/fixture" \
      CERALIVE_SLOT_SYNC_EXCLUDE="${EXCLUDE_SRC}" \
      CERALIVE_PRUNE_PATHS_LIST="${WORK}/prune-paths.list.absent" \
      CERALIVE_HEALTHCHECK_BOOT_ID_FILE="${WORK}/boot-id" \
      CERALIVE_DPKG_STATUS_FILE="${WORK}/dpkg-status" \
      CERALIVE_HAWKBIT_SERVICE="rauc-hawkbit-updater.service" \
      CERALIVE_OS_RELEASE_FILE="${WORK}/os-release" \
      CERALIVE_IMAGE_VERSION_FILE="${WORK}/image-version.absent" \
      bash "${SCRIPT}" run >"${priv_run_log}" 2>&1
    priv_rc=$?
    if [[ "${priv_rc}" -eq 0 ]]; then
      ok "privileged leg: real end-to-end run succeeded"
    else
      bad "privileged leg: real end-to-end run failed (rc=${priv_rc}): $(<"${priv_run_log}")"
    fi

    # Inspect the mirrored content by mounting the loop device read-only.
    mkdir -p "${PRIV_WORK}/mnt-check"
    as_root mount -o ro "${loop_dev}" "${PRIV_WORK}/mnt-check"

    [[ -f "${PRIV_WORK}/mnt-check/boot/hidden-marker.txt" ]] \
      && ok "privileged leg: hidden ext4-level /boot content was mirrored onto the target" \
      || bad "privileged leg: /boot/hidden-marker.txt missing on the target"

    src_links="$(stat -c '%h' "${PRIV_WORK}/fixture/etc/original")"
    dst_links="$(as_root stat -c '%h' "${PRIV_WORK}/mnt-check/etc/original" 2>/dev/null || echo 0)"
    if [[ -f "${PRIV_WORK}/mnt-check/etc/hardlinked" ]] && [[ "${dst_links}" -ge 2 ]]; then
      ok "privileged leg: hardlink pair preserved (link count ${dst_links}, source ${src_links})"
    else
      bad "privileged leg: hardlink was not preserved (target link count: ${dst_links})"
    fi

    src_blocks="$(stat -c '%b' "${PRIV_WORK}/fixture/etc/sparse.bin")"
    dst_blocks="$(as_root stat -c '%b' "${PRIV_WORK}/mnt-check/etc/sparse.bin" 2>/dev/null || echo -1)"
    dst_size="$(as_root stat -c '%s' "${PRIV_WORK}/mnt-check/etc/sparse.bin" 2>/dev/null || echo -1)"
    if [[ "${dst_size}" == "8388607" && "${dst_blocks}" -le $(( src_blocks + 16 )) ]]; then
      ok "privileged leg: sparse file preserved as sparse (size=${dst_size}, blocks src=${src_blocks} dst=${dst_blocks})"
    else
      bad "privileged leg: sparse file was materialised or truncated (size=${dst_size}, blocks src=${src_blocks} dst=${dst_blocks})"
    fi

    if [[ "${xattr_ok}" -eq 1 ]]; then
      if as_root getfattr -n user.ceralive.test --only-values "${PRIV_WORK}/mnt-check/etc/original" 2>/dev/null | grep -qF hello; then
        ok "privileged leg: xattr preserved"
      else
        bad "privileged leg: xattr NOT preserved"
      fi
    else
      echo "== SKIP xattr preservation check (setfattr unsupported on this host filesystem) =="
    fi

    if [[ "${acl_ok}" -eq 1 ]]; then
      if as_root getfacl -p "${PRIV_WORK}/mnt-check/etc/original" 2>/dev/null | grep -qF 'user:nobody:r'; then
        ok "privileged leg: ACL preserved"
      else
        bad "privileged leg: ACL NOT preserved"
      fi
    else
      echo "== SKIP ACL preservation check (setfacl unsupported on this host filesystem) =="
    fi

    if [[ "${cap_ok}" -eq 1 ]]; then
      if as_root getcap "${PRIV_WORK}/mnt-check/usr/bin/capped" 2>/dev/null | grep -qF 'cap_net_bind_service'; then
        ok "privileged leg: file capability preserved (getcap)"
      else
        bad "privileged leg: file capability NOT preserved"
      fi
    else
      echo "== SKIP file-capability preservation check (setcap unsupported on this host filesystem) =="
    fi

    as_root umount "${PRIV_WORK}/mnt-check" 2>/dev/null || true
    as_root e2fsck -fn "${loop_dev}" >"${PRIV_WORK}/e2fsck.log" 2>&1
    fsck_rc=$?
    [[ "${fsck_rc}" -eq 0 ]] && ok "privileged leg: e2fsck -fn on the mirrored target is clean" \
      || bad "privileged leg: e2fsck -fn reported errors (rc=${fsck_rc}): $(<"${PRIV_WORK}/e2fsck.log")"

    as_root losetup -d "${loop_dev}"
    loop_dev=""
  fi
else
  if [[ "${SLOT_SYNC_CONTRACT}" == "required" ]]; then
    echo "FAIL: CERALIVE_RUN_REAL_SLOT_SYNC_CONTRACT=required but this host cannot run the real loop/ext4/xattr/ACL/cap leg (needs root or passwordless sudo, plus losetup/mkfs.ext4/mount/umount/e2fsck/setfacl/getfacl/setcap/getcap/rsync)" >&2
    exit 1
  fi
  echo "== SKIP real loop-mounted-ext4 slot-sync contract (set CERALIVE_RUN_REAL_SLOT_SYNC_CONTRACT=required) =="
fi

printf '\nRESULT: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
