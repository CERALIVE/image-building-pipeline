#!/usr/bin/env bash
#
# board-quirk-udev-rules.test.sh — the board-MANIFEST-gated M.2 SIM quirk rows
# must reach a real rootfs, and must reach ONLY the boards that declare them.
#
# THE DEFECT THIS GUARDS. mkosi/customize/quirks.sh holds a real, correct
# dispatch (dispatch_quirks + handle_m2_modem_sim_workaround) emitting
# ID_MM_DEVICE_PROCESS / ID_MM_CANDIDATE for Quectel 2c7c and Sierra 1199 — and
# it is a run-all.sh RUNTIME module, while ./build runs `run-all.sh base` ONLY.
# Its rows therefore reached NO emitted image, for the whole life of the feature.
# Same dead-writer trap as /dev/hdmi-in.
#
# Porting it was not a mechanical row-move, because the quirk is BOARD-GATED
# (`quirks:` in manifests/boards/*.yaml) and a subimage chroot has no board
# manifest and no way to resolve one. The board fact reaches the live writer the
# same way every other board-derived value does — the lib/orchestrate.sh
# `env_names` <-> mkosi/mkosi.conf `PassEnvironment=` lockstep, in the exact shape
# CERALIVE_MODEM_PORTS_SLOTS already uses:
#
#   manifests/boards/<b>.yaml `quirks:`
#     -> resolve.py flatten        -> QUIRKS_<NAME>=<value>
#     -> orchestrate.sh collapse   -> CERALIVE_BOARD_QUIRKS="name=value name=value"
#     -> env_names + PassEnvironment=
#     -> postinst.d/hardware.sh::apply_board_quirks (called by the LIVE writer)
#     -> /etc/udev/rules.d/99-ceralive-hardware.rules
#
# Every arrow above is EXECUTED here, not grepped: the real resolver runs against
# the real board manifests, the real collapse block is lifted out of
# orchestrate.sh and run on its output, and the real apply_board_quirks writes
# into a scratch sysroot seeded with the live writer's own rules heredoc. Both
# directions are proven — rock-5b-plus (declares the quirk) gets the rows,
# orange-pi-5-plus (no `quirks:` block at all) gets none.
#
# PROFILE: contract-test (docs/shell-profiles.md).
#
# shellcheck shell=bash

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"

ORCHESTRATE="${PIPELINE_DIR}/lib/orchestrate.sh"
RESOLVE_SH="${PIPELINE_DIR}/lib/resolve.sh"
MKOSI_CONF="${PIPELINE_DIR}/mkosi/mkosi.conf"
LIVE_WRITER="${PIPELINE_DIR}/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"
HARDWARE_MOD="${PIPELINE_DIR}/mkosi/customize/postinst.d/hardware.sh"
DRIFT_CHECK="${PIPELINE_DIR}/ci/postinst-drift-check.sh"

BOARD_WITH_QUIRK='rock-5b-plus'
BOARD_WITHOUT_QUIRK='orange-pi-5-plus'

RULES_PATH='/etc/udev/rules.d/99-ceralive-hardware.rules'
ENV_NAME='CERALIVE_BOARD_QUIRKS'

# The two rows the quirk exists to ship, and an anchor row the BASE policy owns.
# The anchor is the non-vacuity instrument: an extraction or a seed that produced
# nothing would make every "absent" assertion below pass for the wrong reason.
QUIRK_ROW_QUECTEL='SUBSYSTEM=="usb", ATTRS{idVendor}=="2c7c", ENV{ID_MM_DEVICE_PROCESS}="1", ENV{ID_MM_CANDIDATE}="1"'
QUIRK_ROW_SIERRA='SUBSYSTEM=="usb", ATTRS{idVendor}=="1199", ENV{ID_MM_DEVICE_PROCESS}="1", ENV{ID_MM_CANDIDATE}="1"'
BASE_ANCHOR_ROW='KERNEL=="ttyUSB[0-9]*", GROUP="dialout", MODE="0664"'

# shellcheck source=lib/assertions.sh
source "${HERE}/lib/assertions.sh"

TMPROOT="$(mktemp -d)"
trap 'rm -rf "${TMPROOT}"' EXIT

for f in "${ORCHESTRATE}" "${RESOLVE_SH}" "${MKOSI_CONF}" "${LIVE_WRITER}" "${HARDWARE_MOD}" "${DRIFT_CHECK}"; do
  [[ -e "${f}" ]] || {
    printf 'board-quirk-udev-rules: missing source file: %s\n' "${f}" >&2
    exit 2
  }
done

# ---------------------------------------------------------------------------
# heredoc_for <file> <dest-substr> — the body of the `cat >DEST <<DELIM` here-doc
# whose redirect target contains <dest-substr>. Keyed on the DESTINATION PATH,
# never the delimiter name: postinst.chroot reuses `EOF` for a dozen unrelated
# payloads, so a delimiter-keyed extractor reads the wrong one. Same extractor
# shape as ci/postinst-drift-check.sh.
# ---------------------------------------------------------------------------
heredoc_for() {
  awk -v dest="$2" '
    !f && index($0, "cat ") && index($0, "<<") && index($0, dest) {
      s = $0; sub(/.*<</, "", s); gsub(/[ \t"'"'"']/, "", s); delim = s; f = 1; next
    }
    f && $0 == delim { exit }
    f { print }
  ' "$1"
}

# ---------------------------------------------------------------------------
# The REAL collapse block, lifted out of orchestrate.sh by its own markers and
# wrapped in a function so its `local` declarations are legal. Executing the
# shipped text is the point: a re-derived copy here would keep passing after the
# shipped one broke.
# ---------------------------------------------------------------------------
COLLAPSE_FN="${TMPROOT}/collapse.sh"
{
  printf 'log_warn() { printf "[warn] %%s\\n" "$*" >&2; }\n'
  printf 'collapse_board_quirks() {\n'
  awk '/^  # --- CERALIVE_BOARD_QUIRKS/ {f=1} f {print} f && /^  export CERALIVE_BOARD_QUIRKS=/ {exit}' "${ORCHESTRATE}"
  printf '}\n'
} >"${COLLAPSE_FN}"

collapse_lines="$(grep -c . "${COLLAPSE_FN}")"
if ((collapse_lines >= 10)); then
  ok "collapse block extracted from orchestrate.sh (${collapse_lines} lines — non-vacuous)"
else
  bad "collapse block extraction yielded ${collapse_lines} lines — the markers moved; every leg below would pass vacuously"
fi
if bash -n "${COLLAPSE_FN}"; then
  ok "extracted collapse block parses as bash"
else
  bad "extracted collapse block does not parse — extraction is truncated"
fi

# ---------------------------------------------------------------------------
# quirks_env_for <board> — run the REAL resolver for <board>, then the REAL
# collapse block, and print the resulting CERALIVE_BOARD_QUIRKS.
# ---------------------------------------------------------------------------
quirks_env_for() {
  local board="$1"
  (
    set +u
    eval "$("${RESOLVE_SH}" "${board}" 2>/dev/null)" || exit 1
    # shellcheck source=/dev/null
    source "${COLLAPSE_FN}"
    collapse_board_quirks
    printf '%s\n' "${CERALIVE_BOARD_QUIRKS}"
  )
}

# ---------------------------------------------------------------------------
# emit_rules <sysroot> <quirks-env> — seed the scratch sysroot with the LIVE
# writer's own rules heredoc (so the append lands in exactly the file ./build
# produces), then run the REAL apply_board_quirks against it.
# ---------------------------------------------------------------------------
emit_rules() {
  local sysroot="$1" quirks="$2"
  mkdir -p "${sysroot}/etc/udev/rules.d"
  heredoc_for "${LIVE_WRITER}" "${RULES_PATH}" >"${sysroot}${RULES_PATH}"
  (
    set +u
    export CERALIVE_SYSROOT="${sysroot}"
    export CERALIVE_BOARD_QUIRKS="${quirks}"
    # shellcheck source=/dev/null
    source "${HARDWARE_MOD}"
    apply_board_quirks
  ) >"${sysroot}/apply.log" 2>&1
}

printf '\n--- 1. the board fact reaches the subimage chroot (env_names <-> PassEnvironment) ---\n'

if grep -Eq "^[[:space:]]*CERALIVE_MODEM_PORTS_STATUS .*${ENV_NAME}|^[[:space:]]*${ENV_NAME}\b" "${ORCHESTRATE}"; then
  ok "${ENV_NAME} is in orchestrate.sh env_names"
else
  bad "${ENV_NAME} missing from orchestrate.sh env_names — mkosi never forwards it"
fi

pass_names="$(sed -n 's/^PassEnvironment=//p' "${MKOSI_CONF}" | tr ' ' '\n' | grep -c "^${ENV_NAME}$")"
assert_eq "${ENV_NAME} appears exactly once in mkosi.conf PassEnvironment=" "1" "${pass_names}"

if grep -q "export ${ENV_NAME}=" "${ORCHESTRATE}"; then
  ok "${ENV_NAME} is EXPORTED (a bare --environment name inherits nothing otherwise)"
else
  bad "${ENV_NAME} is never exported in orchestrate.sh"
fi

printf '\n--- 2. the live writer calls the handler, after the writer that truncates the file ---\n'

if grep -Eq '^[[:space:]]*apply_board_quirks\b' "${LIVE_WRITER}"; then
  ok "mkosi.postinst.chroot calls apply_board_quirks (the LIVE ./build writer)"
else
  bad "mkosi.postinst.chroot never calls apply_board_quirks — the rows have no ./build path"
fi

hw_line="$(grep -nE '^[[:space:]]*setup_hardware_access[[:space:]]*($|#)' "${LIVE_WRITER}" | tail -n1 | cut -d: -f1)"
quirk_line="$(grep -nE '^[[:space:]]*apply_board_quirks\b' "${LIVE_WRITER}" | tail -n1 | cut -d: -f1)"
if [[ -n "${hw_line}" && -n "${quirk_line}" ]] && ((quirk_line > hw_line)); then
  ok "apply_board_quirks runs AFTER setup_hardware_access (line ${quirk_line} > ${hw_line}) — the append survives the truncate"
else
  bad "apply_board_quirks does not follow setup_hardware_access (setup=${hw_line:-none}, quirks=${quirk_line:-none}) — the quirk rows would be truncated away"
fi

if grep -cE '^apply_board_quirks\(\) \{' "${HARDWARE_MOD}" | grep -q '^1$'; then
  ok "apply_board_quirks is defined exactly once in postinst.d/hardware.sh"
else
  bad "apply_board_quirks is not defined exactly once in postinst.d/hardware.sh"
fi

if grep -q 'apply_board_quirks' "${DRIFT_CHECK}"; then
  ok "apply_board_quirks is registered in postinst-drift-check.sh CONSOLIDATED_FUNCS"
else
  bad "apply_board_quirks is not registered in the drift gate — a re-inline into the executor would go unnoticed"
fi

printf '\n--- 3. POSITIVE: %s declares the quirk -> the rows land in the emitted rules ---\n' "${BOARD_WITH_QUIRK}"

quirks_with="$(quirks_env_for "${BOARD_WITH_QUIRK}")"
if [[ "${quirks_with}" == *m2_modem_sim_workaround=* ]]; then
  ok "resolver+collapse yields m2_modem_sim_workaround for ${BOARD_WITH_QUIRK} (${quirks_with})"
else
  bad "resolver+collapse produced no m2_modem_sim_workaround for ${BOARD_WITH_QUIRK}: '${quirks_with}'"
fi

ROOT_WITH="${TMPROOT}/with"
emit_rules "${ROOT_WITH}" "${quirks_with}"
RULES_WITH="${ROOT_WITH}${RULES_PATH}"

assert_contains "base policy seeded from the LIVE writer's own heredoc (non-vacuity anchor)" \
  "${RULES_WITH}" "${BASE_ANCHOR_ROW}"
assert_contains "Quectel 2c7c ID_MM row emitted for ${BOARD_WITH_QUIRK}" "${RULES_WITH}" "${QUIRK_ROW_QUECTEL}"
assert_contains "Sierra 1199 ID_MM row emitted for ${BOARD_WITH_QUIRK}" "${RULES_WITH}" "${QUIRK_ROW_SIERRA}"

# The rows are worthless if udev cannot key them: both must carry BOTH env
# assignments on the same line, which is what the fixed-string rows above pin.
id_mm_rows="$(grep -c 'ID_MM_DEVICE_PROCESS' "${RULES_WITH}")"
assert_eq "exactly two ID_MM rows emitted (one per M.2 vendor, no duplication)" "2" "${id_mm_rows}"

if grep -q 'usb_power_optimization' "${ROOT_WITH}/apply.log"; then
  ok "usb_power_optimization is reported as declared-but-not-applied (never silently dropped)"
else
  bad "usb_power_optimization vanished from the dispatch log — a declared quirk must never be silent"
fi
if grep -q 'ATTR{power/control}' "${RULES_WITH}"; then
  bad "USB autosuspend rows were emitted — that handler is deliberately NOT on the live path"
else
  ok "no USB autosuspend rows emitted (deliberately out of scope; needs its own hardware-evidenced change)"
fi
if grep -q 'hdmi_input_emi_shield' "${ROOT_WITH}/apply.log"; then
  ok "hdmi_input_emi_shield is reported as DEFERRED (DT-level, no config-level handler)"
else
  bad "hdmi_input_emi_shield vanished from the dispatch log"
fi

printf '\n--- 4. NEGATIVE: %s declares no quirks -> nothing is emitted ---\n' "${BOARD_WITHOUT_QUIRK}"

quirks_without="$(quirks_env_for "${BOARD_WITHOUT_QUIRK}")"
assert_eq "resolver+collapse yields an EMPTY quirk set for ${BOARD_WITHOUT_QUIRK}" "" "${quirks_without}"

ROOT_WITHOUT="${TMPROOT}/without"
emit_rules "${ROOT_WITHOUT}" "${quirks_without}"
RULES_WITHOUT="${ROOT_WITHOUT}${RULES_PATH}"

assert_contains "base policy still seeded for ${BOARD_WITHOUT_QUIRK} (non-vacuity anchor)" \
  "${RULES_WITHOUT}" "${BASE_ANCHOR_ROW}"
if grep -q 'ID_MM_DEVICE_PROCESS\|ID_MM_CANDIDATE' "${RULES_WITHOUT}"; then
  bad "${BOARD_WITHOUT_QUIRK} received M.2 SIM ID_MM rows — the board gate is broken"
else
  ok "${BOARD_WITHOUT_QUIRK} received NO ID_MM rows — the board gate holds"
fi

if cmp -s <(heredoc_for "${LIVE_WRITER}" "${RULES_PATH}") "${RULES_WITHOUT}"; then
  ok "a no-quirk board's rules file is byte-identical to the live writer's own payload"
else
  bad "a no-quirk board's rules file diverges from the live writer's payload — something was appended"
fi

printf '\n--- 5. gate semantics: falsey values, unknown quirks, unset env ---\n'

ROOT_FALSE="${TMPROOT}/false"
emit_rules "${ROOT_FALSE}" 'm2_modem_sim_workaround=false'
if grep -q 'ID_MM_DEVICE_PROCESS' "${ROOT_FALSE}${RULES_PATH}"; then
  bad "a quirk declared 'false' was applied anyway — the value is not being read"
else
  ok "a quirk declared 'false' is NOT applied (stricter than quirks.sh, which ignores values)"
fi

ROOT_TRUTHY="${TMPROOT}/truthy"
emit_rules "${ROOT_TRUTHY}" 'm2_modem_sim_workaround=required'
assert_contains "value 'required' (the shipped manifest spelling) applies the quirk" \
  "${ROOT_TRUTHY}${RULES_PATH}" "${QUIRK_ROW_QUECTEL}"

ROOT_BARE="${TMPROOT}/bare"
emit_rules "${ROOT_BARE}" 'm2_modem_sim_workaround='
assert_contains "an empty value still applies (declaration by presence, as quirks.sh reads it)" \
  "${ROOT_BARE}${RULES_PATH}" "${QUIRK_ROW_QUECTEL}"

ROOT_UNKNOWN="${TMPROOT}/unknown"
emit_rules "${ROOT_UNKNOWN}" 'not_a_real_quirk=true m2_modem_sim_workaround=required'
unknown_rc=$?
assert_eq "an unknown quirk does not fail the dispatch (warn-and-continue)" "0" "${unknown_rc}"
assert_contains "a known quirk beside an unknown one is still applied" \
  "${ROOT_UNKNOWN}${RULES_PATH}" "${QUIRK_ROW_SIERRA}"
if grep -q "unknown quirk 'not_a_real_quirk'" "${ROOT_UNKNOWN}/apply.log"; then
  ok "the unknown quirk is NAMED in the dispatch log"
else
  bad "the unknown quirk was skipped silently"
fi

ROOT_EMPTY="${TMPROOT}/empty"
emit_rules "${ROOT_EMPTY}" ''
if grep -q 'ID_MM_DEVICE_PROCESS' "${ROOT_EMPTY}${RULES_PATH}"; then
  bad "an EMPTY CERALIVE_BOARD_QUIRKS emitted quirk rows — the fail-closed direction is broken"
else
  ok "an EMPTY CERALIVE_BOARD_QUIRKS emits nothing (fail-closed; this is also the PassEnvironment-drift state)"
fi

printf '\n--- 6. the runtime module still exists and still agrees on the rows ---\n'

QUIRKS_MOD="${PIPELINE_DIR}/mkosi/customize/quirks.sh"
if grep -qF "${QUIRK_ROW_QUECTEL}" "${QUIRKS_MOD}" && grep -qF "${QUIRK_ROW_SIERRA}" "${QUIRKS_MOD}"; then
  ok "customize/quirks.sh emits the SAME two rows (the live writer is a port, not a fork)"
else
  bad "customize/quirks.sh and the live writer disagree on the M.2 SIM rows — one of them has drifted"
fi

printf '\n=== board-quirk-udev-rules: %d passed, %d failed ===\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
