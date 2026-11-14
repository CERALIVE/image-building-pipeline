#!/usr/bin/env bash
#
# tests/boot-script-sync.test.sh — the boot.scr field-update path: the device script
# (ceralive-boot-script-sync), the build side (install-boot.sh boot-payload) and the
# slot-image injection (inject_boot_payload). Needs no root and no hardware; it does
# need mkimage, mke2fs, debugfs and e2fsck, which the CI job installs.
#
# contract-test profile (docs/shell-profiles.md): `set -uo pipefail`, no `-e`.
#
# shellcheck shell=bash

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck source=lib/assertions.sh
source "${HERE}/lib/assertions.sh"

SYNC="${ROOT}/mkosi/runtime/ceralive-boot-script-sync.sh"
UNIT="${ROOT}/mkosi/runtime/ceralive-boot-script-sync.service"
INSTALL_BOOT="${ROOT}/mkosi/platform/boot/install-boot.sh"

for tool in mkimage mke2fs debugfs e2fsck; do
  command -v "${tool}" >/dev/null 2>&1 || { printf 'FAIL: %s is required\n' "${tool}" >&2; exit 1; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

hdr() { head -c 64 /dev/zero | tr '\0' "$1"; }
mkscr() { { hdr "$1"; printf '%s\n' "$2"; } >"$3"; }

fixture() {
  D="$(mktemp -d "${WORK}/case.XXXXXX")"
  mkdir -p "${D}/src" "${D}/boot"
  mkscr N "new selector body" "${D}/src/boot.scr"
  (cd "${D}/src" && sha256sum boot.scr >boot.scr.sha256)
  mkscr O "old selector body" "${D}/boot/boot.scr"
  cp "${D}/boot/boot.scr" "${D}/old.scr"
  printf '#!/bin/sh\necho "vfat rw,relatime"\n' >"${D}/findmnt"
  chmod +x "${D}/findmnt"
}

run_sync() {
  env CERALIVE_BOOT_SCRIPT_SRC="${D}/src/boot.scr" CERALIVE_BOOT_DIR="${D}/boot" \
    CERALIVE_ACTIVATION_ARMED="${D}/armed" CERALIVE_FINDMNT_BIN="${D}/findmnt" \
    CERALIVE_ACTIVATION_LOCK="${D}/lock" \
    "$@" bash "${SYNC}" >"${D}/out" 2>&1
}

echo "== device script"

fixture
run_sync; rc=$?
{ [[ ${rc} -eq 0 ]] && cmp -s "${D}/src/boot.scr" "${D}/boot/boot.scr" \
  && cmp -s "${D}/old.scr" "${D}/boot/boot.scr.prev" && [[ ! -e "${D}/boot/boot.scr.new" ]]; } \
  && ok "a different selector is replaced byte for byte, the old one kept, no .new left" \
  || bad "replace case (rc=${rc}): $(cat "${D}/out")"

fixture
mkscr X "new selector body" "${D}/boot/boot.scr"
cp "${D}/boot/boot.scr" "${D}/before.scr"
run_sync; rc=$?
{ [[ ${rc} -eq 0 ]] && cmp -s "${D}/before.scr" "${D}/boot/boot.scr" && [[ ! -e "${D}/boot/boot.scr.prev" ]]; } \
  && ok "the same body under a different mkimage header is current: no write, no backup" \
  || bad "same-body case (rc=${rc}): $(cat "${D}/out")"

fixture
mkscr X "new selector body" "${D}/boot/boot.scr"
printf 'junk' >"${D}/boot/boot.scr.new"
run_sync; rc=$?
{ [[ ${rc} -eq 0 ]] && [[ ! -e "${D}/boot/boot.scr.new" ]]; } \
  && ok "a stale boot.scr.new from a power cut is removed" \
  || bad "stale .new case (rc=${rc})"

fixture
printf '%064d  boot.scr\n' 0 >"${D}/src/boot.scr.sha256"
run_sync; rc=$?
{ [[ ${rc} -eq 1 ]] && cmp -s "${D}/old.scr" "${D}/boot/boot.scr"; } \
  && ok "a shipped boot.scr that fails its checksum is refused, the live one untouched" \
  || bad "checksum case (rc=${rc})"

fixture
: >"${D}/armed"
run_sync; rc=$?
{ [[ ${rc} -eq 0 ]] && cmp -s "${D}/old.scr" "${D}/boot/boot.scr"; } \
  && ok "an armed kernel activation defers the sync" \
  || bad "armed case (rc=${rc})"

fixture
rm -f "${D}/boot/boot.scr"
run_sync; rc=$?
{ [[ ${rc} -eq 1 ]] && [[ ! -e "${D}/boot/boot.scr" ]]; } \
  && ok "an absent /boot/boot.scr is never created" \
  || bad "absent target case (rc=${rc})"

for info in "ext4 rw,relatime" "vfat ro,relatime"; do
  fixture
  printf '#!/bin/sh\necho "%s"\n' "${info}" >"${D}/findmnt"
  run_sync; rc=$?
  { [[ ${rc} -eq 1 ]] && cmp -s "${D}/old.scr" "${D}/boot/boot.scr"; } \
    && ok "refuses a boot mount reported as '${info}'" \
    || bad "mount case '${info}' (rc=${rc})"
done

fixture
rm -f "${D}/src/boot.scr"
run_sync; rc=$?
[[ ${rc} -eq 0 ]] && ok "an image that ships no boot.scr is a clean no-op" || bad "no-source case (rc=${rc})"

fixture
printf '#!/bin/bash\ncp "$@" && printf X >>"${@: -1}"\n' >"${D}/cp-corrupt"
chmod +x "${D}/cp-corrupt"
run_sync CERALIVE_BOOT_SCRIPT_CP_BIN="${D}/cp-corrupt"; rc=$?
{ [[ ${rc} -eq 1 ]] && cmp -s "${D}/old.scr" "${D}/boot/boot.scr" && [[ ! -e "${D}/boot/boot.scr.new" ]]; } \
  && ok "a bad readback of the new file leaves the live boot.scr untouched" \
  || bad "cp-corrupt case (rc=${rc}): $(cat "${D}/out")"

fixture
cat >"${D}/mv-corrupt" <<'EOF'
#!/bin/bash
flag="$(dirname "$0")/mv.once"
if [[ ! -e "${flag}" ]]; then : >"${flag}"; mv "$@" && printf X >>"${@: -1}"; else mv "$@"; fi
EOF
chmod +x "${D}/mv-corrupt"
run_sync CERALIVE_BOOT_SCRIPT_MV_BIN="${D}/mv-corrupt"; rc=$?
{ [[ ${rc} -eq 1 ]] && cmp -s "${D}/old.scr" "${D}/boot/boot.scr" && [[ ! -e "${D}/boot/boot.scr.new" ]]; } \
  && ok "a bad readback after the rename restores the previous boot.scr" \
  || bad "mv-corrupt case (rc=${rc}): $(cat "${D}/out")"

fixture
printf '#!/bin/bash\nmv "$@" && printf X >>"${@: -1}"\n' >"${D}/mv-always-corrupt"
chmod +x "${D}/mv-always-corrupt"
run_sync CERALIVE_BOOT_SCRIPT_MV_BIN="${D}/mv-always-corrupt"; rc=$?
{ [[ ${rc} -eq 2 ]] && ! cmp -s "${D}/old.scr" "${D}/boot/boot.scr" && cmp -s "${D}/old.scr" "${D}/boot/boot.scr.prev"; } \
  && ok "a restore that also fails exits 2 and keeps the previous copy" \
  || bad "failed-restore case (rc=${rc}): $(cat "${D}/out")"

fixture
exec {lk}>"${D}/lock"; flock "${lk}"
run_sync CERALIVE_ACTIVATION_LOCK_WAIT=1; rc=$?
exec {lk}>&-
{ [[ ${rc} -eq 0 ]] && cmp -s "${D}/old.scr" "${D}/boot/boot.scr" && [[ ! -e "${D}/boot/boot.scr.prev" ]]; } \
  && ok "while an activation holds the lock the boot partition is not touched" \
  || bad "lock-held case (rc=${rc}): $(cat "${D}/out")"

echo "== build side: install-boot.sh boot-payload"

BOARD_ENV=(SERIAL_CONSOLE=ttyS2:1500000 DTB_NAME=rockchip/rk3588-rock-5b-plus.dtb
  BOARD_ID=rock-5b-plus COMPATIBLE_STRING=ceralive-rock-5b-plus SINGLE_SLOT_FALLBACK=false)
PAYLOAD="${WORK}/payload"
PARTITION="${WORK}/partition"
env "${BOARD_ENV[@]}" bash "${INSTALL_BOOT}" boot-payload "${PAYLOAD}" >"${WORK}/payload.log" 2>&1; rc=$?
{ [[ ${rc} -eq 0 ]] && [[ -f "${PAYLOAD}/boot.scr" ]] && (cd "${PAYLOAD}" && sha256sum -c boot.scr.sha256 >/dev/null 2>&1) \
  && mkimage -l "${PAYLOAD}/boot.scr" 2>/dev/null | grep -q 'Script'; } \
  && ok "boot-payload writes a compiled script image and a matching SHA-256 line" \
  || bad "boot-payload (rc=${rc}): $(tail -3 "${WORK}/payload.log")"

env "${BOARD_ENV[@]}" bash "${INSTALL_BOOT}" boot-partition "${PARTITION}" >/dev/null 2>&1
cmp -s -i 64 "${PAYLOAD}/boot.scr" "${PARTITION}/boot.scr" \
  && ok "the shipped script has the same body as the one the boot partition gets" \
  || bad "payload body differs from the boot-partition boot.scr"

env "${BOARD_ENV[@]}" bash "${INSTALL_BOOT}" boot-payload >/dev/null 2>&1 \
  && bad "boot-payload accepted a missing destination" \
  || ok "boot-payload requires a destination directory"

mkdir "${WORK}/badbin"
printf '#!/bin/bash\nfor a; do last="$a"; done\nprintf partial >"$last"\nexit 1\n' >"${WORK}/badbin/mkimage"
chmod +x "${WORK}/badbin/mkimage"
env PATH="${WORK}/badbin:${PATH}" "${BOARD_ENV[@]}" bash "${INSTALL_BOOT}" boot-payload "${WORK}/bad-payload" >/dev/null 2>&1; rc=$?
{ [[ ${rc} -ne 0 ]] && [[ ! -e "${WORK}/bad-payload/boot.scr" ]]; } \
  && ok "a failing mkimage fails boot-payload and ships no boot.scr" \
  || bad "boot-payload shipped output after a mkimage failure (rc=${rc})"
env PATH="${WORK}/badbin:${PATH}" "${BOARD_ENV[@]}" bash "${INSTALL_BOOT}" boot-partition "${WORK}/bad-partition" >/dev/null 2>&1 \
  && bad "boot-partition succeeded although mkimage failed" \
  || ok "a failing mkimage fails boot-partition"

echo "== slot image: inject_boot_payload"

TREE="${WORK}/tree"
mkdir -p "${TREE}/usr/lib/ceralive"
printf 'x\n' >"${TREE}/usr/lib/ceralive/marker"
BASE="${WORK}/base.ext4"
truncate -s 16M "${BASE}"
E2FSPROGS_FAKE_TIME=0 mke2fs -q -F -t ext4 -d "${TREE}" "${BASE}" >/dev/null 2>&1

inject() {
  bash -c 'source "$1/lib/common.sh"; source "$1/lib/disk/slot-image.sh"; inject_boot_payload "$2" "$3"' _ "${ROOT}" "$1" "$2"
}

cp "${BASE}" "${WORK}/a.ext4"
SOURCE_DATE_EPOCH=1700000000 inject "${WORK}/a.ext4" "${PAYLOAD}" >"${WORK}/inject.log" 2>&1; rc=$?
stat_out="$(debugfs -R 'stat /usr/lib/ceralive/boot/boot.scr' "${WORK}/a.ext4" 2>/dev/null)"
{ [[ ${rc} -eq 0 ]] \
  && debugfs -R 'cat /usr/lib/ceralive/boot/boot.scr' "${WORK}/a.ext4" 2>/dev/null | cmp -s - "${PAYLOAD}/boot.scr" \
  && debugfs -R 'cat /usr/lib/ceralive/boot/boot.scr.sha256' "${WORK}/a.ext4" 2>/dev/null | cmp -s - "${PAYLOAD}/boot.scr.sha256" \
  && grep -q 'Mode:  0644' <<<"${stat_out}" && grep -qE 'User: +0 +Group: +0' <<<"${stat_out}" \
  && e2fsck -fn "${WORK}/a.ext4" >/dev/null 2>&1; } \
  && ok "the payload lands root-owned 0644 under /usr/lib/ceralive/boot and the filesystem stays clean" \
  || bad "inject (rc=${rc}): $(tail -3 "${WORK}/inject.log")"

cp "${BASE}" "${WORK}/b.ext4"
SOURCE_DATE_EPOCH=1700000000 inject "${WORK}/b.ext4" "${PAYLOAD}" >/dev/null 2>&1
[[ "$(sha256sum <"${WORK}/a.ext4")" == "$(sha256sum <"${WORK}/b.ext4")" ]] \
  && ok "two injections of the same payload give a byte-identical image" \
  || bad "injection is not reproducible"

mkdir -p "${WORK}/partial"
cp "${PAYLOAD}/boot.scr" "${WORK}/partial/"
cp "${BASE}" "${WORK}/c.ext4"
inject "${WORK}/c.ext4" "${WORK}/partial" >/dev/null 2>&1 \
  && bad "an incomplete payload was accepted" \
  || ok "an incomplete payload is refused"

echo "== wiring"

grep -qF 'setup_boot_script_sync() {' "${ROOT}/mkosi/customize/postinst.d/persistence.sh" \
  && grep -qE '^  setup_boot_script_sync$' "${ROOT}/mkosi/customize/postinst.d/services.sh" \
  && ok "setup_boot_script_sync is defined and called from configure_services" \
  || bad "setup_boot_script_sync is not wired"

{ grep -qxF 'Requires=ceralive-mark-good.service' "${UNIT}" && grep -qxF 'After=ceralive-mark-good.service' "${UNIT}" \
  && grep -qxF 'ConditionPathExists=/usr/lib/ceralive/boot/boot.scr' "${UNIT}" && grep -qxF 'WantedBy=multi-user.target' "${UNIT}"; } \
  && ok "the unit needs a successful healthcheck, is inert without a payload and is enabled at boot" \
  || bad "unit gating is wrong"

[[ "$(grep -c 'CERALIVE_BOOT_PAYLOAD_DIR=' "${ROOT}/lib/stages/assemble.sh")" -eq 2 ]] \
  && grep -qF 'inject_boot_payload "${out}" "${CERALIVE_BOOT_PAYLOAD_DIR}"' "${ROOT}/lib/disk/slot-image.sh" \
  && ok "the disk assembly and the bundle build both receive the payload" \
  || bad "payload is not handed to both the disk and the bundle"

printf '\nRESULT: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
