#!/usr/bin/env bash
#
# test-x86-grub.sh — offline proof of the x86 RAUC-NATIVE bootloader=grub path
# (Task 12). The grub twin of test-x86-fallback.sh (which proves the RETAINED
# bootloader=custom countdown engine). No qemu, no GRUB, no root, no image: it
# drives the SHIPPED installer (install-x86-grub.sh) and asserts the artifacts that
# the produced .raw carries — system.conf (bootloader=grub), the grub.cfg RAUC
# ORDER/OK/TRY selector, and the seeded grubenv — then proves the slot-switch
# contract (flip grubenv ORDER -> the other slot is selected).
#
# The slot SELECTION evaluator below (select_slot) is a faithful shell MIRROR of the
# grub-ab.cfg `for s in ${ORDER}` loop — the same first-OK/untried rule. It is the
# verification twin of the on-device GRUB script (analogous to how x86-boot-state.sh
# mirrors grub.cfg.tmpl for the custom engine). The test also greps the real grub.cfg
# to confirm it carries the same selection structure, so the mirror cannot silently
# drift from what ships.
#
# shellcheck shell=bash

set -uo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALL="${SCRIPT_DIR}/install-x86-grub.sh"

PASS=0; FAIL=0
ok()   { printf '  ok   %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL %s\n' "$*"; FAIL=$((FAIL + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 [$2]"; fi; }

WORK="$(mktemp -d)"
cleanup() { rm -rf "${WORK}"; }
trap cleanup EXIT

# Force the bash grubenv fallback (no grub-editenv dependency) so this runs anywhere.
export GRUB_EDITENV=/nonexistent-grub-editenv
export GRUB_MKSTANDALONE=/nonexistent-grub-mkstandalone

# grubenv_get <file> <key> — read one var from a grubenv block (KEY=VALUE lines).
grubenv_get() {
  awk -F= -v k="$2" '$1==k{print $2; exit}' \
    < <(tr -d '#' <"$1" | grep -E '^[A-Za-z_][A-Za-z0-9_]*=')
}

# select_slot <grubenv> — MIRROR of grub-ab.cfg: first slot in ORDER with OK=1 and
# TRY=0; else (none) the head of ORDER (last-resort). Echoes "<slot> <rootfs_label>".
select_slot() {
  local f="$1" order chosen="" s ok try
  order="$(grubenv_get "${f}" ORDER)"
  for s in ${order}; do
    ok="$(grubenv_get "${f}" "${s}_OK")"
    try="$(grubenv_get "${f}" "${s}_TRY")"
    if [[ -z "${chosen}" && "${ok}" == "1" && "${try}" == "0" ]]; then chosen="${s}"; fi
  done
  [[ -n "${chosen}" ]] || chosen="${order%% *}"
  local label="rootfs_a"; [[ "${chosen}" == "B" ]] && label="rootfs_b"
  printf '%s %s' "${chosen}" "${label}"
}

echo "=== test-x86-grub: RAUC-native bootloader=grub path (offline, no qemu/grub/root) ==="
[[ -x "${INSTALL}" ]] || { echo "FAIL installer not executable: ${INSTALL}"; exit 1; }

# --- 1. system.conf renders bootloader=grub (A/B) -----------------------------
echo "### 1. install-x86-grub.sh rootfs renders bootloader=grub system.conf (A/B)"
ab_root="${WORK}/ab-root"
ROOT="${ab_root}" SERIAL_CONSOLE="ttyS0:115200" COMPATIBLE_STRING="ceralive-x86-minipc" \
  SINGLE_SLOT_FALLBACK="false" bash "${INSTALL}" rootfs >/dev/null
sysconf="${ab_root}/etc/rauc/system.conf"
check "system.conf exists" "[[ -f '${sysconf}' ]]"
check "bootloader=grub" "grep -qx 'bootloader=grub' '${sysconf}'"
check "compatible is board-specific" "grep -qx 'compatible=ceralive-x86-minipc' '${sysconf}'"
check "grubenv= points at the ESP" "grep -qx 'grubenv=/boot/efi/EFI/BOOT/grubenv' '${sysconf}'"
check "keyring path is the device root CA" "grep -qx 'path=/etc/rauc/ceralive-keyring.pem' '${sysconf}'"
check "slot A maps to rootfs_a" "grep -q 'by-partlabel/rootfs_a' '${sysconf}'"
check "slot B maps to rootfs_b" "grep -q 'by-partlabel/rootfs_b' '${sysconf}'"
check "bootname A present" "grep -qx 'bootname=A' '${sysconf}'"
check "bootname B present" "grep -qx 'bootname=B' '${sysconf}'"
check "NOT bootloader=custom" "! grep -q 'bootloader=custom' '${sysconf}'"
check "ESP fstab mount written" "grep -qE 'PARTLABEL=boot[[:space:]]+/boot/efi[[:space:]]+vfat' '${ab_root}/etc/fstab'"

# --- 1b. single-slot system.conf omits the B slot -----------------------------
echo "### 1b. single-slot system.conf omits the B slot"
ss_root="${WORK}/ss-root"
ROOT="${ss_root}" SERIAL_CONSOLE="ttyS0:115200" COMPATIBLE_STRING="ceralive-x86-minipc" \
  SINGLE_SLOT_FALLBACK="true" bash "${INSTALL}" rootfs >/dev/null
ss_conf="${ss_root}/etc/rauc/system.conf"
check "single-slot keeps bootloader=grub" "grep -qx 'bootloader=grub' '${ss_conf}'"
check "single-slot has slot A" "grep -q 'by-partlabel/rootfs_a' '${ss_conf}'"
check "single-slot OMITS slot B" "! grep -q 'by-partlabel/rootfs_b' '${ss_conf}'"

# --- 2. ESP staging: grub.cfg selector + seeded grubenv + BOOTX64.EFI ----------
echo "### 2. install-x86-grub.sh esp stages grub.cfg + grubenv + BOOTX64.EFI"
esp="${WORK}/esp"
SERIAL_CONSOLE="ttyS0:115200" SINGLE_SLOT_FALLBACK="false" \
  bash "${INSTALL}" esp "${esp}" >/dev/null 2>&1
cfg="${esp}/EFI/BOOT/grub.cfg"; env="${esp}/EFI/BOOT/grubenv"; efi="${esp}/EFI/BOOT/BOOTX64.EFI"
check "grub.cfg at removable EFI/BOOT path" "[[ -f '${cfg}' ]]"
check "grubenv at removable EFI/BOOT path" "[[ -f '${env}' ]]"
check "BOOTX64.EFI at removable path" "[[ -f '${efi}' ]]"
check "grub.cfg iterates ORDER" "grep -q 'for s in \${ORDER}' '${cfg}'"
check "grub.cfg reads A_OK/A_TRY" "grep -q 'A_OK' '${cfg}' && grep -q 'A_TRY' '${cfg}'"
check "grub.cfg reads B_OK/B_TRY" "grep -q 'B_OK' '${cfg}' && grep -q 'B_TRY' '${cfg}'"
check "grub.cfg selects rootfs_a/rootfs_b by label" "grep -q 'label --set=root rootfs_a' '${cfg}' && grep -q 'label --set=root rootfs_b' '${cfg}'"
check "grub.cfg console substituted (no placeholder)" "! grep -q '@CONSOLE@' '${cfg}' && grep -q 'ttyS0,115200' '${cfg}'"
check "grubenv is a 1024-byte GRUB block" "[[ \$(stat -c%s '${env}') -eq 1024 ]]"
check "grubenv seeds ORDER=A B" "[[ \"\$(grubenv_get '${env}' ORDER)\" == 'A B' ]]"
check "grubenv seeds A_OK=1 A_TRY=0" "[[ \"\$(grubenv_get '${env}' A_OK)\" == '1' && \"\$(grubenv_get '${env}' A_TRY)\" == '0' ]]"
check "grubenv seeds B_OK=1 B_TRY=0" "[[ \"\$(grubenv_get '${env}' B_OK)\" == '1' && \"\$(grubenv_get '${env}' B_TRY)\" == '0' ]]"

# --- 3. fresh A/B selects slot A ----------------------------------------------
echo "### 3. fresh A/B grubenv selects slot A (primary)"
sel="$(select_slot "${env}")"
check "fresh selection is 'A rootfs_a'" "[[ '${sel}' == 'A rootfs_a' ]]"

# --- 4. SLOT-SWITCH: flip grubenv ORDER to prefer B -> B is selected ----------
echo "### 4. slot-switch: set grubenv ORDER='B A' -> selector picks slot B (rootfs_b)"
bash "${INSTALL}" grubenv-set "${env}" "ORDER=B A" >/dev/null
check "ORDER is now 'B A'" "[[ \"\$(grubenv_get '${env}' ORDER)\" == 'B A' ]]"
sel_b="$(select_slot "${env}")"
check "switched selection is 'B rootfs_b'" "[[ '${sel_b}' == 'B rootfs_b' ]]"
check "A is still OK (not destroyed by the switch)" "[[ \"\$(grubenv_get '${env}' A_OK)\" == '1' ]]"

# --- 5. ROLLBACK: B tried-but-unconfirmed -> falls back to A -------------------
echo "### 5. rollback: B attempted (TRY=1) without mark-good -> falls back to A"
bash "${INSTALL}" grubenv-set "${env}" "B_TRY=1" >/dev/null
sel_rb="$(select_slot "${env}")"
check "B exhausted its try -> selector returns to 'A rootfs_a'" "[[ '${sel_rb}' == 'A rootfs_a' ]]"

# --- 6. single-slot ESP grubenv has no live B ---------------------------------
echo "### 6. single-slot ESP grubenv has ORDER=A and B not bootable"
esp_ss="${WORK}/esp-ss"
SERIAL_CONSOLE="ttyS0:115200" SINGLE_SLOT_FALLBACK="true" \
  bash "${INSTALL}" esp "${esp_ss}" >/dev/null 2>&1
env_ss="${esp_ss}/EFI/BOOT/grubenv"
check "single-slot ORDER=A" "[[ \"\$(grubenv_get '${env_ss}' ORDER)\" == 'A' ]]"
check "single-slot B_OK=0 (no phantom B)" "[[ \"\$(grubenv_get '${env_ss}' B_OK)\" == '0' ]]"
check "single-slot selects 'A rootfs_a'" "[[ \"\$(select_slot '${env_ss}')\" == 'A rootfs_a' ]]"

echo
echo "=== test-x86-grub: ${PASS} pass / ${FAIL} fail ==="
(( FAIL == 0 )) || { echo "X86-GRUB TEST FAILED"; exit 1; }
echo "X86-GRUB TEST OK"
