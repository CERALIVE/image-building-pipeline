#!/usr/bin/env bash
#
# test-x86-fallback.sh — offline proof of the CeraLive x86 (GRUB) A/B failed-boot
# rollback. The x86 twin of platform/boot/test-fallback.sh.
#
# No GRUB, no qemu, no root, no hardware. It drives the SAME state engine the
# on-device grub.cfg uses (x86-boot-state.sh `boot-select`, the byte-for-byte twin
# of the grub.cfg selector) plus the RAUC custom backend, and ASSERTS:
#
#   1. Fresh A/B: A is primary, both slots good, stored in a grubenv block.
#   2. Failed boots of A decrement BOOT_A_LEFT 3->2->1->0; once exhausted A is
#      "bad" and the NEXT boot AUTOMATICALLY falls back to B (the core rollback).
#   3. RAUC backend roundtrip: get-primary / set-primary / get-state / set-state.
#   4. mark-good resets the attempt counter.
#   5. Single-slot: only A ever selected; B is "bad"; no phantom fallback.
#   6. The grubenv written by the bash fallback is a grub-editenv-COMPATIBLE
#      1024-byte block ("# GRUB Environment Block" header) -> GRUB load_env can read it.
#   7. install-x86-boot.sh esp renders grub.cfg FROM THE MANIFEST ENV (console +
#      decrement ladder), seeds grubenv, and selects rootfs_a/rootfs_b by PARTLABEL.
#   8. grub.cfg.tmpl + rendered grub.cfg statically contain the selector algorithm
#      (load_env/save_env, LEFT>0 `-gt` test, decrement ladder, /vmlinuz, PARTLABEL).
#   9. install-x86-boot.sh rootfs renders the RAUC system.conf (bootloader=custom).
#  10. x86-encode.sh writes the D1 encode config (qsv primary, x264 fallback, n100
#      family, bps caveat) and is NOT relay-only.
#
# Run:  v2/mkosi/platform/x86/test-x86-fallback.sh
#
# shellcheck shell=bash
# Assertions grep for LITERAL GRUB-script text; single quotes must NOT expand.
# shellcheck disable=SC2016

set -uo pipefail

X86_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STATE_HELPER="${X86_DIR}/x86-boot-state.sh"
ADAPTER="${X86_DIR}/x86-rauc-boot-adapter.sh"
INSTALL="${X86_DIR}/install-x86-boot.sh"
ENCODE="${X86_DIR}/x86-encode.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
GRUBENV="${WORK}/grubenv"

PASS=0; FAIL=0
ok()   { printf '  ok   %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL %s\n' "$*"; FAIL=$((FAIL+1)); }
assert_eq() { # <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then ok "$1 ($3)"; else bad "$1: expected '$2', got '$3'"; fi
}
assert_contains() { # <desc> <file> <needle>
  if grep -qF -- "$3" "$2"; then ok "$1"; else bad "$1: '$3' not in $2"; fi
}

# Force the bash grubenv fallback (this host has no grub-editenv) so the test
# exercises the self-contained path AND proves block-format compatibility.
bs()      { CERALIVE_GRUBENV="${GRUBENV}" CERALIVE_BOOT_ATTEMPTS=3 GRUB_EDITENV=/nonexistent-grub-editenv \
            bash "${STATE_HELPER}" "$@"; }
adapter() { CERALIVE_GRUBENV="${GRUBENV}" CERALIVE_BOOT_ATTEMPTS=3 GRUB_EDITENV=/nonexistent-grub-editenv \
            CERALIVE_BOOT_STATE_BIN="${STATE_HELPER}" bash "${ADAPTER}" "$@"; }

echo "=============================================================="
echo " CeraLive Stage 5 — x86 (GRUB) A/B failed-boot rollback verify"
echo " Backend: RAUC bootloader=custom (UEFI/GRUB, grubenv via grub-editenv)"
echo " Engine : x86-boot-state.sh (twin of grub.cfg) — bash grubenv fallback"
echo "=============================================================="

echo
echo "### 1. Fresh A/B install (grubenv seed)"
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
echo "### 6. grubenv is a grub-editenv-COMPATIBLE 1024-byte block (GRUB load_env safe)"
bs init >/dev/null
size="$(wc -c <"${GRUBENV}")"
assert_eq "grubenv is exactly 1024 bytes" "1024" "${size}"
assert_contains "grubenv has the GRUB Environment Block header" "${GRUBENV}" "# GRUB Environment Block"
assert_contains "grubenv carries BOOT_ORDER" "${GRUBENV}" "BOOT_ORDER=A B"
assert_contains "grubenv carries BOOT_A_LEFT" "${GRUBENV}" "BOOT_A_LEFT=3"

echo
echo "### 7. install-x86-boot.sh esp renders grub.cfg + grubenv from the manifest env"
esp_n100="${WORK}/esp_n100"; esp_alt="${WORK}/esp_alt"
SERIAL_CONSOLE="ttyS0:115200" FAMILY="x86_64" SINGLE_SLOT_FALLBACK="false" \
  bash "${INSTALL}" esp "${esp_n100}" >/dev/null
SERIAL_CONSOLE="ttyS1:57600" FAMILY="x86_64" SINGLE_SLOT_FALLBACK="false" \
  bash "${INSTALL}" esp "${esp_alt}" >/dev/null
cfg="${esp_n100}/EFI/ceralive/grub.cfg"
assert_contains "grub.cfg console rewritten : -> ," "${cfg}" 'cera_console="ttyS0,115200"'
assert_contains "alt board grub.cfg DIFFERENT console" "${esp_alt}/EFI/ceralive/grub.cfg" 'cera_console="ttyS1,57600"'
assert_contains "grub.cfg selects rootfs_a by PARTLABEL" "${cfg}" "root=/dev/disk/by-partlabel/rootfs_a"
assert_contains "grub.cfg selects rootfs_b by PARTLABEL" "${cfg}" "root=/dev/disk/by-partlabel/rootfs_b"
assert_contains "grub.cfg boots /vmlinuz" "${cfg}" "linux /vmlinuz"
assert_contains "grub.cfg loads initrd /initrd.img" "${cfg}" "initrd /initrd.img"
assert_contains "grub.cfg load_env (reads grubenv)" "${cfg}" "load_env"
assert_contains "grub.cfg save_env A (persists countdown)" "${cfg}" "save_env BOOT_A_LEFT"
assert_contains "grub.cfg LEFT>0 selection via -gt" "${cfg}" '"${BOOT_A_LEFT}" -gt 0'
assert_contains "grub.cfg generated decrement ladder 3->2" "${cfg}" 'if [ "${BOOT_A_LEFT}" = "3" ]; then set BOOT_A_LEFT="2"'
assert_contains "grub.cfg generated decrement ladder 1->0" "${cfg}" 'elif [ "${BOOT_A_LEFT}" = "1" ]; then set BOOT_A_LEFT="0"'
assert_contains "esp grubenv seeded BOOT_ORDER" "${esp_n100}/EFI/ceralive/grubenv" "BOOT_ORDER=A B"
if ! diff -q "${cfg}" "${esp_alt}/EFI/ceralive/grub.cfg" >/dev/null; then \
  ok "two boards render DIFFERENT grub.cfg (console not hardcoded)"; \
  else bad "two boards rendered identical grub.cfg (hardcoded?)"; fi
# template placeholders must be fully substituted (no @...@ left in the output)
if grep -qE '@[A-Z_]+@' "${cfg}"; then bad "grub.cfg still has unsubstituted @PLACEHOLDER@"; \
  else ok "grub.cfg has no leftover @PLACEHOLDER@ tokens"; fi

echo
echo "### 7b. single-slot esp seeds grubenv with no live B"
esp_ss="${WORK}/esp_ss"
SERIAL_CONSOLE="ttyS0:115200" FAMILY="x86_64" SINGLE_SLOT_FALLBACK="true" \
  bash "${INSTALL}" esp "${esp_ss}" >/dev/null
assert_contains "single-slot grubenv BOOT_ORDER=A" "${esp_ss}/EFI/ceralive/grubenv" "BOOT_ORDER=A"
assert_contains "single-slot grubenv BOOT_B_LEFT=0" "${esp_ss}/EFI/ceralive/grubenv" "BOOT_B_LEFT=0"

echo
echo "### 8. grub.cfg.tmpl (source) matches the tested engine — static check"
TMPL="${X86_DIR}/grub.cfg.tmpl"
assert_contains "tmpl loads grubenv state"          "${TMPL}" "load_env"
assert_contains "tmpl persists A countdown"         "${TMPL}" "save_env BOOT_A_LEFT"
assert_contains "tmpl persists B countdown"         "${TMPL}" "save_env BOOT_B_LEFT"
assert_contains "tmpl LEFT>0 via integer -gt"       "${TMPL}" '"${BOOT_A_LEFT}" -gt 0'
assert_contains "tmpl decrement placeholder A"      "${TMPL}" "@DECREMENT_A@"
assert_contains "tmpl decrement placeholder B"      "${TMPL}" "@DECREMENT_B@"
assert_contains "tmpl selects rootfs_a"             "${TMPL}" "rootfs_a"
assert_contains "tmpl selects rootfs_b"             "${TMPL}" "rootfs_b"
assert_contains "tmpl iterates BOOT_ORDER"          "${TMPL}" "for s in \${BOOT_ORDER}"

echo
echo "### 9. install-x86-boot.sh rootfs renders RAUC system.conf (bootloader=custom)"
abroot="${WORK}/abroot"; ssroot="${WORK}/ssroot"
ROOT="${abroot}" SERIAL_CONSOLE="ttyS0:115200" FAMILY="x86_64" SINGLE_SLOT_FALLBACK="false" \
  bash "${INSTALL}" rootfs >/dev/null
ROOT="${ssroot}" SERIAL_CONSOLE="ttyS0:115200" FAMILY="x86_64" SINGLE_SLOT_FALLBACK="true" \
  bash "${INSTALL}" rootfs >/dev/null
sysconf="${abroot}/etc/rauc/system.conf"
assert_contains "system.conf bootloader=custom"      "${sysconf}" "bootloader=custom"
assert_contains "system.conf backend = adapter"      "${sysconf}" "bootloader-custom-backend=/usr/lib/rauc/ceralive-rauc-boot-adapter"
assert_contains "system.conf compatible from family" "${sysconf}" "compatible=ceralive-x86_64"
assert_contains "slot A by PARTLABEL rootfs_a"       "${sysconf}" "device=/dev/disk/by-partlabel/rootfs_a"
assert_contains "slot B by PARTLABEL rootfs_b"       "${sysconf}" "device=/dev/disk/by-partlabel/rootfs_b"
assert_contains "adapter installed to /usr/lib/rauc" "${abroot}/usr/lib/rauc/ceralive-rauc-boot-adapter" "RAUC custom bootloader backend"
assert_contains "state helper installed to /usr/bin" "${abroot}/usr/bin/ceralive-boot-state" "x86 A/B boot-state"
if grep -qF "rootfs_b" "${ssroot}/etc/rauc/system.conf"; then \
  bad "single-slot system.conf must NOT reference rootfs_b"; \
  else ok "single-slot system.conf omits the B slot"; fi

echo
echo "### 10. x86-encode.sh writes the D1 encode config (NOT relay-only)"
encroot="${WORK}/encroot"
ROOT="${encroot}" SKIP_PKG_INSTALL=1 bash "${ENCODE}" >/dev/null
enccfg="${encroot}/etc/ceralive/conf.d/10-encode-x86.conf"
assert_contains "encode primary = qsv (Intel QuickSync)" "${enccfg}" "CERALIVE_ENCODE_PRIMARY=qsv"
assert_contains "encode fallback = x264 (software)"      "${enccfg}" "CERALIVE_ENCODE_FALLBACK=x264"
assert_contains "pipeline family = n100"                 "${enccfg}" "CERALIVE_PIPELINE_FAMILY=n100"
assert_contains "fallback family = generic"              "${enccfg}" "CERALIVE_PIPELINE_FALLBACK_FAMILY=generic"
assert_contains "NOT relay-only (D1)"                    "${enccfg}" "CERALIVE_RELAY_ONLY=false"
assert_contains "bps caveat recorded (patched gst)"      "${enccfg}" "CERALIVE_DYNAMIC_BITRATE_REQUIRES_PATCHED_GST=true"
if [[ -L "${encroot}/etc/ceralive/pipeline" ]]; then \
  ok "active pipeline symlink created (-> n100)"; \
  else bad "active pipeline symlink missing"; fi

echo
echo "=============================================================="
printf ' RESULT: %d passed, %d failed\n' "${PASS}" "${FAIL}"
echo "=============================================================="
[[ "${FAIL}" -eq 0 ]]
