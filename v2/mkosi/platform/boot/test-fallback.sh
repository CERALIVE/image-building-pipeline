#!/usr/bin/env bash
#
# test-fallback.sh — offline proof of the CeraLive A/B failed-boot rollback.
#
# No hardware, no root, no U-Boot. It drives the SAME state engine the on-device
# U-Boot selector uses (ceralive-boot-state.sh `boot-select`, the byte-for-byte
# twin of boot.scr.cmd) plus the RAUC custom backend, and ASSERTS:
#
#   1. Fresh A/B: A is primary, both slots good.
#   2. Failed boots of A decrement BOOT_A_LEFT 3->2->1->0; once exhausted A is
#      "bad" and the NEXT boot AUTOMATICALLY falls back to B (the core rollback).
#   3. RAUC backend roundtrip: get-primary / set-primary / get-state / set-state.
#   4. mark-good resets the attempt counter (a healthy slot stops counting down).
#   5. Single-slot: only A ever selected; B is "bad"; no phantom fallback.
#   6. install-boot.sh boot-partition renders board specifics FROM THE MANIFEST
#      ENV (console/fdtfile differ per board) — nothing hardcoded.
#   7. boot.scr.cmd statically contains the decrement + manifest-sourced console/
#      fdtfile + PARTLABEL slot selection (U-Boot path matches the tested twin).
#   8. Corruption resilience: a truncated / empty / missing / bad-CRC state file
#      yields the safe defaults (A B, full budget) + a clean rewrite and NEVER
#      crashes, while a well-formed no-CRC file (the U-Boot env-export write) is
#      trusted so the bootcount is not wiped.
#
# Run:  v2/mkosi/platform/boot/test-fallback.sh
#
# shellcheck shell=bash

set -uo pipefail

BOOT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STATE_HELPER="${BOOT_DIR}/ceralive-boot-state.sh"
ADAPTER="${BOOT_DIR}/ceralive-rauc-boot-adapter.sh"
INSTALL="${BOOT_DIR}/install-boot.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
STATE="${WORK}/boot_state.txt"

PASS=0; FAIL=0
ok()   { printf '  ok   %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL %s\n' "$*"; FAIL=$((FAIL+1)); }
assert_eq() { # <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then ok "$1 ($3)"; else bad "$1: expected '$2', got '$3'"; fi
}
assert_contains() { # <desc> <file> <needle>
  if grep -qF -- "$3" "$2"; then ok "$1"; else bad "$1: '$3' not in $2"; fi
}

# State helper / adapter bound to the throwaway state file + 3-attempt budget.
bs()      { CERALIVE_BOOT_STATE_FILE="${STATE}" CERALIVE_BOOT_ATTEMPTS=3 bash "${STATE_HELPER}" "$@"; }
adapter() { CERALIVE_BOOT_STATE_FILE="${STATE}" CERALIVE_BOOT_ATTEMPTS=3 \
            CERALIVE_BOOT_STATE_BIN="${STATE_HELPER}" bash "${ADAPTER}" "$@"; }

echo "=============================================================="
echo " CeraLive Stage 4 — A/B failed-boot rollback verification"
echo " Backend: RAUC bootloader=custom (vendor U-Boot, no fw_setenv — D3)"
echo " Engine : ceralive-boot-state.sh (twin of boot.scr.cmd)"
echo "=============================================================="

echo
echo "### 1. Fresh A/B install"
bs init
assert_eq "BOOT_ORDER seeded A B" "A B" "$(bs get-order)"
assert_eq "primary is A"          "A"   "$(bs get-primary)"
assert_eq "slot A good"           "good" "$(bs get-state A)"
assert_eq "slot B good"           "good" "$(bs get-state B)"
assert_eq "A_LEFT = 3"            "3"   "$(bs get-left A)"

echo
echo "### 2. Failed boots of A -> counter decrements -> FALLBACK to B"
out="$(bs boot-select)"; assert_eq "boot 1 selects A"            "A rootfs_a" "${out}"
assert_eq "  A_LEFT 3->2"        "2" "$(bs get-left A)"
out="$(bs boot-select)"; assert_eq "boot 2 selects A"            "A rootfs_a" "${out}"
assert_eq "  A_LEFT 2->1"        "1" "$(bs get-left A)"
out="$(bs boot-select)"; assert_eq "boot 3 selects A"            "A rootfs_a" "${out}"
assert_eq "  A_LEFT 1->0"        "0" "$(bs get-left A)"
assert_eq "A now BAD (exhausted)" "bad" "$(bs get-state A)"
assert_eq "primary rolls to B"    "B"   "$(bs get-primary)"
out="$(bs boot-select)"; assert_eq "boot 4 FALLS BACK to B"      "B rootfs_b" "${out}"
assert_eq "  B_LEFT 3->2"        "2" "$(bs get-left B)"

echo
echo "### 3. RAUC custom backend roundtrip (get/set primary + state)"
bs init >/dev/null
assert_eq "backend get-primary = A" "A" "$(adapter get-primary)"
adapter set-primary B
assert_eq "after set-primary B"     "B" "$(adapter get-primary)"
assert_eq "B_LEFT reset to 3"       "3" "$(bs get-left B)"
assert_eq "backend get-state A"     "good" "$(adapter get-state A)"
adapter set-state A bad
assert_eq "A marked bad -> dropped" "bad" "$(adapter get-state A)"
assert_eq "BOOT_ORDER drops A"      "B" "$(bs get-order)"
adapter set-state A good
assert_eq "A marked good -> back"   "good" "$(adapter get-state A)"

echo
echo "### 4. mark-good resets the attempt counter (healthy slot stops counting)"
bs init >/dev/null
bs boot-select >/dev/null; bs boot-select >/dev/null
assert_eq "A_LEFT drained to 1"     "1" "$(bs get-left A)"
bs mark-good A
assert_eq "mark-good restores 3"    "3" "$(bs get-left A)"
assert_eq "A good after mark-good"  "good" "$(bs get-state A)"

echo
echo "### 5. Single-slot fallback image (no B slot — contract §4)"
bs init --single-slot
assert_eq "single-slot order = A"   "A" "$(bs get-order)"
assert_eq "B is bad (no slot)"      "bad" "$(bs get-state B)"
bs boot-select >/dev/null; bs boot-select >/dev/null; bs boot-select >/dev/null
last="$(bs boot-select)"
assert_eq "exhausted A last-resorts to A (never phantom B)" "A rootfs_a" "${last}"

echo
echo "### 6. Board specifics come from the manifest env (NOT hardcoded)"
# Render the boot-partition artifacts for two different boards and prove the
# console/DTB track the env, never a baked-in value.
r5b="${WORK}/rock5b"; opi="${WORK}/opi5"
SERIAL_CONSOLE="ttyS2:1500000" DTB_NAME="rk3588-rock-5b-plus.dtb" BOARD_ID="rock-5b-plus" \
  FAMILY="rk3588" SINGLE_SLOT_FALLBACK="false" \
  bash "${INSTALL}" boot-partition "${r5b}" --allow-uncompiled >/dev/null
SERIAL_CONSOLE="ttyS2:1500000" DTB_NAME="rk3588s-orangepi-5-plus.dtb" BOARD_ID="orangepi5-plus" \
  FAMILY="rk3588" SINGLE_SLOT_FALLBACK="false" \
  bash "${INSTALL}" boot-partition "${opi}" --allow-uncompiled >/dev/null

assert_contains "rock-5b cera_board.env: console rewritten : -> ," "${r5b}/cera_board.env" "console=ttyS2,1500000"
assert_contains "rock-5b cera_board.env: fdtfile from manifest" "${r5b}/cera_board.env" "fdtfile=rk3588-rock-5b-plus.dtb"
assert_contains "rock-5b cera_board.env: board_id from manifest" "${r5b}/cera_board.env" "board_id=rock-5b-plus"
assert_contains "opi5 cera_board.env: DIFFERENT fdtfile" "${opi}/cera_board.env" "fdtfile=rk3588s-orangepi-5-plus.dtb"
assert_contains "extlinux selects rootfs_a by PARTLABEL" "${r5b}/extlinux/extlinux.conf" "root=PARTLABEL=rootfs_a"
assert_contains "extlinux selects rootfs_b by PARTLABEL" "${r5b}/extlinux/extlinux.conf" "root=PARTLABEL=rootfs_b"
assert_contains "extlinux console from manifest" "${r5b}/extlinux/extlinux.conf" "console=ttyS2,1500000"
if [[ -f "${r5b}/boot.scr" ]]; then ok "boot.scr compiled (mkimage present)"; \
  else assert_contains "boot.scr.cmd staged (mkimage absent)" "${r5b}/boot.scr.cmd" "CeraLive A/B boot selector"; fi
# differing DTB across boards proves nothing is hardcoded
if ! diff -q "${r5b}/cera_board.env" "${opi}/cera_board.env" >/dev/null; then \
  ok "two boards render DIFFERENT cera_board.env (not hardcoded)"; \
  else bad "two boards rendered identical cera_board.env (hardcoded?)"; fi

echo
echo "### 6b. RAUC system.conf rendered for the rootfs (bootloader=custom)"
abroot="${WORK}/abroot"; ssroot="${WORK}/ssroot"
ROOT="${abroot}" SERIAL_CONSOLE="ttyS2:1500000" DTB_NAME="rk3588-rock-5b-plus.dtb" \
  BOARD_ID="rock-5b-plus" COMPATIBLE_STRING="ceralive-rock-5b-plus" SINGLE_SLOT_FALLBACK="false" \
  bash "${INSTALL}" rootfs >/dev/null
ROOT="${ssroot}" SERIAL_CONSOLE="ttyS2:1500000" DTB_NAME="rk3588-rock-5b-plus.dtb" \
  BOARD_ID="rock-5b-plus" COMPATIBLE_STRING="ceralive-rock-5b-plus" SINGLE_SLOT_FALLBACK="true" \
  bash "${INSTALL}" rootfs >/dev/null
sysconf="${abroot}/etc/rauc/system.conf"
assert_contains "system.conf bootloader=custom"        "${sysconf}" "bootloader=custom"
assert_contains "system.conf backend = adapter"        "${sysconf}" "bootloader-custom-backend=/usr/lib/rauc/ceralive-rauc-boot-adapter"
# T12: compatible is BOARD-specific (ceralive-rock-5b-plus), read verbatim from
# COMPATIBLE_STRING — NOT the family-wide ceralive-rk3588 that diverged from the bundle.
assert_contains "system.conf compatible board-specific" "${sysconf}" "compatible=ceralive-rock-5b-plus"
if grep -qF "compatible=ceralive-rk3588" "${sysconf}"; then \
  bad "system.conf must NOT carry the family-wide compatible (T12 regression)"; \
  else ok "no family-wide ceralive-rk3588 compatible leaked into system.conf"; fi
assert_contains "slot A by PARTLABEL rootfs_a"         "${sysconf}" "device=/dev/disk/by-partlabel/rootfs_a"
assert_contains "slot A bootname=A"                    "${sysconf}" "bootname=A"
assert_contains "slot B by PARTLABEL rootfs_b"         "${sysconf}" "device=/dev/disk/by-partlabel/rootfs_b"
assert_contains "adapter installed to /usr/lib/rauc"   "${abroot}/usr/lib/rauc/ceralive-rauc-boot-adapter" "RAUC custom bootloader backend"
assert_contains "state helper installed to /usr/bin"   "${abroot}/usr/bin/ceralive-boot-state" "A/B boot-state"
if grep -qF "rootfs_b" "${ssroot}/etc/rauc/system.conf"; then \
  bad "single-slot system.conf must NOT reference rootfs_b"; \
  else ok "single-slot system.conf omits the B slot"; fi

echo
echo "### 6c. COMPATIBLE_STRING guard — empty compatible MUST fail loud (T12)"
# A missing compatible would silently brick OTA (device rejects every bundle); the
# installer must refuse rather than write an unusable/guessed system.conf.
guardroot="${WORK}/guardroot"; guard_rc=0
ROOT="${guardroot}" SERIAL_CONSOLE="ttyS2:1500000" DTB_NAME="rk3588-rock-5b-plus.dtb" \
  BOARD_ID="rock-5b-plus" COMPATIBLE_STRING="" SINGLE_SLOT_FALLBACK="false" \
  bash "${INSTALL}" rootfs >/dev/null 2>&1 || guard_rc=$?
if [[ "${guard_rc}" -ne 0 ]]; then ok "empty COMPATIBLE_STRING aborts install (rc=${guard_rc})"; \
  else bad "empty COMPATIBLE_STRING did NOT abort install"; fi
if [[ ! -f "${guardroot}/etc/rauc/system.conf" ]]; then ok "no system.conf written on guard abort"; \
  else bad "system.conf was written despite empty COMPATIBLE_STRING"; fi

echo
echo "### 7. boot.scr.cmd (U-Boot path) matches the tested engine — static check"
assert_contains "decrements A counter (bootcount)" "${BOOT_DIR}/boot.scr.cmd" "setexpr BOOT_A_LEFT \${BOOT_A_LEFT} - 1"
assert_contains "decrements B counter (bootcount)" "${BOOT_DIR}/boot.scr.cmd" "setexpr BOOT_B_LEFT \${BOOT_B_LEFT} - 1"
assert_contains "persists state via fatwrite"      "${BOOT_DIR}/boot.scr.cmd" "fatwrite \${devtype} \${devnum}:1 \${loadaddr} boot_state.txt"
assert_contains "console from manifest env"        "${BOOT_DIR}/boot.scr.cmd" "console=\${console}"
assert_contains "fdtfile from manifest env"        "${BOOT_DIR}/boot.scr.cmd" "/boot/dtb/\${fdtfile}"
assert_contains "selects rootfs_a slot"            "${BOOT_DIR}/boot.scr.cmd" "cera_root rootfs_a"
assert_contains "selects rootfs_b slot"            "${BOOT_DIR}/boot.scr.cmd" "cera_root rootfs_b"

echo
echo "### 8. Corruption resilience — atomic write + CRC validation + safe defaults"
# A power-loss during the FAT rewrite can leave boot_state.txt truncated, empty or
# byte-flipped. The engine MUST never crash on a corrupt file: it validates an
# embedded CRC line and, on ANY failure, returns the safe defaults (A B, full budget)
# AND rewrites a clean, CRC-armoured file. A file written by the U-Boot selector has
# NO CRC line (its `env export` cannot emit one) — that is NOT corruption, so a
# well-formed no-CRC file is trusted (else every real boot's bootcount would be wiped).

# 8a. A healthy write embeds a CRC line (the atomic write stages it then mv-s it in).
bs init >/dev/null
assert_contains "init writes a BOOT_CRC checksum line" "${STATE}" "BOOT_CRC="

# 8b. A valid CRC is trusted: a decremented (non-default) state is NOT reset.
bs boot-select >/dev/null            # A_LEFT 3 -> 2, rewritten with a fresh CRC
assert_eq "valid CRC preserved (no false reset)" "2" "$(bs get-left A)"

# 8c. BAD CRC -> safe defaults + clean rewrite (the byte-flip / partial-write case).
printf 'BOOT_ORDER=B A\nBOOT_A_LEFT=1\nBOOT_B_LEFT=1\nBOOT_CRC=0\n' >"${STATE}"
crc_rc=0; order="$(bs get-order)" || crc_rc=$?
assert_eq "bad-CRC never crashes (exit 0)"         "0"   "${crc_rc}"
assert_eq "bad-CRC -> BOOT_ORDER safe default A B" "A B" "${order}"
assert_eq "bad-CRC -> attempts reset to budget"    "3"   "$(bs get-left A)"
assert_contains "bad-CRC rewrote a clean order"    "${STATE}" "BOOT_ORDER=A B"

# 8d. TRUNCATED file (cut off mid-write) -> safe defaults + clean rewrite.
printf 'BOOT_ORDER=A B\nBOOT_A_LEFT=2\nBOOT_B_' >"${STATE}"
tr_rc=0; order="$(bs get-order)" || tr_rc=$?
assert_eq "truncated never crashes (exit 0)"       "0"   "${tr_rc}"
assert_eq "truncated -> BOOT_ORDER safe default"   "A B" "${order}"
assert_eq "truncated -> attempts reset to budget"  "3"   "$(bs get-left A)"
assert_contains "truncated rewrote a clean CRC file" "${STATE}" "BOOT_CRC="

# 8e. EMPTY file (0 bytes) -> safe defaults + clean rewrite.
: >"${STATE}"
empty_rc=0; order="$(bs get-order)" || empty_rc=$?
assert_eq "empty never crashes (exit 0)"           "0"   "${empty_rc}"
assert_eq "empty -> BOOT_ORDER safe default"       "A B" "${order}"
assert_contains "empty rewrote a clean CRC file"   "${STATE}" "BOOT_CRC="

# 8f. MISSING file -> safe defaults + a fresh clean file is created.
rm -f "${STATE}"
miss_rc=0; order="$(bs get-order)" || miss_rc=$?
assert_eq "missing never crashes (exit 0)"         "0"   "${miss_rc}"
assert_eq "missing -> BOOT_ORDER safe default"     "A B" "${order}"
if [[ -f "${STATE}" ]]; then ok "missing -> a clean state file was created"; else bad "missing -> no state file created"; fi
assert_contains "created file carries a CRC line"  "${STATE}" "BOOT_CRC="

# 8g. LEGACY no-CRC file (the U-Boot selector's env-export write) is TRUSTED, not
#     reset — otherwise the bootcount the bootloader just decremented would be lost.
printf 'BOOT_ORDER=A B\nBOOT_A_LEFT=2\nBOOT_B_LEFT=3\n' >"${STATE}"
assert_eq "legacy no-CRC well-formed file is trusted" "2" "$(bs get-left A)"

echo
echo "### 9-10. Streaming health gate — offline satisfiable, dead encoder fatal (T15)"
# A fresh OFFLINE first boot (no SRT receiver, no link) MUST be able to mark-good,
# else the boot counter bleeds and the slot rolls back into a brick loop (RISK-2).
# But the binary-load check stays STRICT: a slot whose ceracoder cannot load its
# shared libs (boots-but-can't-encode) MUST be refused. Drive the REAL healthcheck
# with a throwaway stub toolchain — no systemd, no rauc, no network, no encoder.
HEALTHCHECK="${BOOT_DIR}/../../runtime/ceralive-healthcheck.sh"
HC_STUBS="${WORK}/hc-stubs"
mkdir -p "${HC_STUBS}"

mk_stub() { # <name> <line...> ; writes an executable stub of those body lines
  local f="${HC_STUBS}/$1"; shift
  { printf '#!/usr/bin/env bash\n'; printf '%s\n' "$@"; } >"${f}"
  chmod +x "${f}"
}
mk_stub systemctl  'exit 0'
mk_stub rauc       'exit 0'
mk_stub ceracoder  'echo "ceracoder (stub) 0.0.0"; exit 0'
mk_stub srtla_send 'echo "srtla_send (stub)"; exit 0'
mk_stub ceracoder_dead \
  'echo "ceracoder: error while loading shared libraries: libsrt.so.1.5: cannot open shared object file" >&2' \
  'exit 127'
mk_stub ip 'echo "1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000"'

run_healthcheck() { # <conf> <marker> [ceracoder-bin] -> healthcheck exit code
  CERALIVE_HEALTHCHECK_CONF="$1" CERALIVE_HEALTHCHECK_MARKER="$2" \
  SYSTEMCTL_BIN="${HC_STUBS}/systemctl" RAUC_BIN="${HC_STUBS}/rauc" \
  CERACODER_BIN="${3:-${HC_STUBS}/ceracoder}" SRTLA_SEND_BIN="${HC_STUBS}/srtla_send" \
  IP_BIN="${HC_STUBS}/ip" \
    bash "${HEALTHCHECK}" >/dev/null 2>&1
}

# 9a. OFFLINE, no upstream configured (IRL_SERVER_HOST unset) -> reach SKIPPED.
printf 'HEALTHCHECK_TIMEOUT=5\nHEALTHCHECK_RETRY_INTERVAL=1\n' >"${WORK}/hc-offline.conf"
hc_rc=0; run_healthcheck "${WORK}/hc-offline.conf" "${WORK}/marker-offline" || hc_rc=$?
assert_eq "offline (no SRT host) gate marks good -> exit 0" "0" "${hc_rc}"
if [[ -f "${WORK}/marker-offline" ]]; then ok "offline gate wrote the mark-good marker"; else bad "offline gate wrote NO marker"; fi

# 9b. OFFLINE with a host configured but NO link up -> reach SKIPPED by the new
#     no-network guard (host is unreachable TEST-NET, only loopback is up).
printf 'IRL_SERVER_HOST=192.0.2.1\nIRL_SERVER_SRT_PORT=9000\nHEALTHCHECK_TIMEOUT=5\nHEALTHCHECK_RETRY_INTERVAL=1\n' >"${WORK}/hc-nolink.conf"
hc_rc=0; run_healthcheck "${WORK}/hc-nolink.conf" "${WORK}/marker-nolink" || hc_rc=$?
assert_eq "host set but no link up -> reach skipped -> exit 0" "0" "${hc_rc}"

# 10. STRICT: a non-loadable ceracoder is the boots-but-can't-encode signature and
#     MUST fail the gate (no mark-good) even offline. TIMEOUT=0 -> fail first pass.
printf 'HEALTHCHECK_TIMEOUT=0\nHEALTHCHECK_RETRY_INTERVAL=1\n' >"${WORK}/hc-dead.conf"
hc_rc=0; run_healthcheck "${WORK}/hc-dead.conf" "${WORK}/marker-dead" "${HC_STUBS}/ceracoder_dead" || hc_rc=$?
if [[ "${hc_rc}" -ne 0 ]]; then ok "dead-encoder gate FAILS (exit ${hc_rc}, no mark-good)"; else bad "dead-encoder gate exited 0 — would brick"; fi
if [[ ! -f "${WORK}/marker-dead" ]]; then ok "dead-encoder gate wrote NO mark-good marker"; else bad "dead-encoder gate wrote a marker despite failure"; fi

echo
echo "=============================================================="
printf ' RESULT: %d passed, %d failed\n' "${PASS}" "${FAIL}"
echo "=============================================================="
[[ "${FAIL}" -eq 0 ]]
