#!/usr/bin/env bash
#
# test-quirks.sh — hermetic unit test for customize/quirks.sh dispatch.
#
# Runs quirks.sh as a STANDALONE script (passing a fixture manifest as $1) with
# CERALIVE_SYSROOT pointed at a tmpdir, so handler udev writes are sandboxed and
# the test needs no root. Asserts the four contract guarantees:
#   1. usb_power_optimization  -> handler invoked
#   2. m2_modem_sim_workaround  -> handler invoked
#   3. hdmi_input_emi_shield    -> logged DEFERRED, NO config handler
#   4. unknown quirk            -> warned + continue (exit 0, handler count intact)
#
# shellcheck shell=bash

set -uo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
QUIRKS_SCRIPT="${SCRIPT_DIR}/quirks.sh"
PASS=0
FAIL=0

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT

# Fixture manifest: all 3 known quirks + 1 deliberately unknown quirk.
cat >"${TMPDIR_TEST}/test-manifest.yaml" <<'EOF'
board_id: test-board
quirks:
  usb_power_optimization: true
  m2_modem_sim_workaround: required
  hdmi_input_emi_shield: true
  totally_unknown_quirk: true
single_slot_fallback: false
EOF

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if printf '%s' "${haystack}" | grep -qF -- "${needle}"; then
    echo "PASS: ${desc}"
    PASS=$((PASS + 1))
  else
    echo "FAIL: ${desc}"
    FAIL=$((FAIL + 1))
  fi
}

assert_absent() {
  local desc="$1" haystack="$2" needle="$3"
  if printf '%s' "${haystack}" | grep -qF -- "${needle}"; then
    echo "FAIL: ${desc}"
    FAIL=$((FAIL + 1))
  else
    echo "PASS: ${desc}"
    PASS=$((PASS + 1))
  fi
}

echo "=== Test 1: full manifest dispatch (all 3 known + 1 unknown) ==="
output="$(CERALIVE_SYSROOT="${TMPDIR_TEST}/sysroot" bash "${QUIRKS_SCRIPT}" "${TMPDIR_TEST}/test-manifest.yaml" 2>&1)"
rc=$?
echo "${output}"
echo "(exit ${rc})"
echo

assert_contains "usb_power_optimization handler invoked" "${output}" "usb_power_optimization applied"
assert_contains "m2_modem_sim_workaround handler invoked" "${output}" "m2_modem_sim_workaround applied"
assert_contains "hdmi_input_emi_shield logged DEFERRED" "${output}" "hdmi_input_emi_shield — DEFERRED"
assert_absent  "hdmi_input_emi_shield has NO 'applied' handler line" "${output}" "hdmi_input_emi_shield applied"
assert_contains "unknown quirk warned" "${output}" "unknown quirk 'totally_unknown_quirk'"
assert_contains "dispatch summary = 2 applied, 1 deferred, 1 unknown" "${output}" "2 applied, 1 deferred, 1 unknown"

if [[ ${rc} -eq 0 ]]; then
  echo "PASS: exit code 0 (unknown quirk did not hard-fail)"
  PASS=$((PASS + 1))
else
  echo "FAIL: non-zero exit (${rc}) on manifest with unknown quirk"
  FAIL=$((FAIL + 1))
fi

# The two config handlers must have actually written their udev rules.
RULES_FILE="${TMPDIR_TEST}/sysroot/etc/udev/rules.d/99-ceralive-hardware.rules"
if [[ -f "${RULES_FILE}" ]]; then
  rules="$(cat "${RULES_FILE}")"
  assert_contains "udev rule: USB autosuspend written"        "${rules}" "QUIRK usb_power_optimization"
  assert_contains "udev rule: ModemManager SIM env written"   "${rules}" "QUIRK m2_modem_sim_workaround"
  assert_absent  "udev rule: NO emi_shield rule written"      "${rules}" "emi_shield"
else
  echo "FAIL: rules file not written to sysroot (${RULES_FILE})"
  FAIL=$((FAIL + 1))
fi

echo
echo "Results: ${PASS} pass, ${FAIL} fail"
[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
