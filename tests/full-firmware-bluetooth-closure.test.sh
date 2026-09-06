#!/usr/bin/env bash
# Real closure/prune entry, with an ELF metadata fixture at the modinfo boundary.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
source "${HERE}/lib/assertions.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
CHECK="${REPO}/lib/check-bluetooth-firmware.sh"
MANIFEST="${REPO}/manifests/rk3588-bluetooth-firmware-roots.txt"
[[ -f "${CHECK}" && -f "${MANIFEST}" ]] || { bad 'Bluetooth closure checker/manifest absent'; exit 1; }
mkdir -p "${WORK}/bin" "${WORK}/root/usr/lib/firmware" "${WORK}/root/usr/lib/modules/test/kernel/drivers/bluetooth"
FW="${WORK}/root/usr/lib/firmware"
MODULES="${WORK}/root/usr/lib/modules/test"
cat >"${WORK}/bin/modinfo" <<'EOF'
#!/usr/bin/env bash
[[ "${MODINFO_FAIL:-0}" == 0 ]] || exit 1
name="${3##*/}"; name="${name%.ko}"
case "$2" in
  name) printf '%s\n' "${name}" ;;
  depends) [[ "${name}" != btusb ]] || printf 'btmtk,btmrvl_sdio,btrtl\n' ;;
  firmware)
    case "${name}" in
      btmtk) printf 'mediatek/mt7927/BT_RAM_CODE_MT6639_2_1_hdr.bin\n' ;;
      btmrvl_sdio) printf 'mrvl/sd8987_uapsta.bin\n' ;;
      btrtl) printf 'rtl_bt/rtl8852bu_fw.bin\n'; [[ -z "${EXTRA_REF:-}" ]] || printf '%s\n' "${EXTRA_REF}" ;;
    esac ;;
esac
exit 0
EOF
chmod +x "${WORK}/bin/modinfo"
export PATH="${WORK}/bin:${PATH}"
for module in btusb btmtk btmrvl_sdio btrtl; do
  touch "${MODULES}/kernel/drivers/bluetooth/${module}.ko"
done
mkdir -p "${MODULES}/kernel/lib"
mv "${MODULES}/kernel/drivers/bluetooth/btrtl.ko" "${MODULES}/kernel/lib/btrtl.ko"
# Given: all declared required objects, and exactly the two reviewed absences.
while read -r kind module pattern rest; do
  case "${kind}" in ''|'#'*|reviewed-hardware-gap) continue ;; esac
  object="${pattern//\*/fixture}"
  [[ "${object}" != */ ]] || object+="fixture.bin"
  mkdir -p "${FW}/${object%/*}"
  [[ "${object}" == */* ]] || rmdir "${FW}/${object}"
  printf 'firmware\n' >"${FW}/${object}"
done <"${MANIFEST}"
run_check() { bash "${CHECK}" "${MODULES}" "${FW}" "${1:-${MANIFEST}}"; }
if run_check >"${WORK}/pass" 2>&1; then ok 'two reviewed static hardware gaps accepted'; else bad "$(<"${WORK}/pass")"; fi
assert_contains 'Marvell absence is not runtime-composed' "${WORK}/pass" 'reviewed-hardware-gap module=btmrvl_sdio firmware=mrvl/sd8987_uapsta.bin'
assert_contains 'MT7927 absence is not runtime-composed' "${WORK}/pass" 'reviewed-hardware-gap module=btmtk firmware=mediatek/mt7927/BT_RAM_CODE_MT6639_2_1_hdr.bin'
# When: a third static reference is absent. Then: refuse and name it.
if EXTRA_REF=mrvl/third-missing.bin run_check >"${WORK}/third" 2>&1; then bad 'third missing object accepted'; else ok 'third missing object RED'; fi
assert_contains 'third-object diagnostic names reference' "${WORK}/third" 'mrvl/third-missing.bin'
if run_check >/dev/null 2>&1; then ok 'third-object mutation removed: GREEN'; else bad 'restored closure fails'; fi
# When: a known static object disappears, even though its runtime family remains.
mv "${FW}/rtl_bt/rtl8852bu_fw.bin" "${WORK}/saved"
if run_check >"${WORK}/missing" 2>&1; then bad 'missing known object accepted'; else ok 'missing known object refused'; fi
mv "${WORK}/saved" "${FW}/rtl_bt/rtl8852bu_fw.bin"
mkdir -p "${FW}/mrvl"; touch "${FW}/mrvl/unknown.bin"
if EXTRA_REF=mrvl/unknown.bin run_check >/dev/null 2>&1; then bad 'unreviewed static reference accepted'; else ok 'unknown static reference refused even when present'; fi
for mutation in 'runtime-composed btrtl ../escape/ # invalid' 'runtime-composed btrtl */ # invalid' 'runtime-composed btrtl a* # invalid' 'runtime-composed btrtl mediatek/* # invalid' 'reviewed-hardware-gap btrtl rtl_bt/third.bin # unapproved'; do
  cp "${MANIFEST}" "${WORK}/manifest"
  printf '%s\n' "${mutation}" >>"${WORK}/manifest"
  if run_check "${WORK}/manifest" >/dev/null 2>&1; then bad "accepted ${mutation}"; else ok "refused ${mutation}"; fi
done
cp "${MANIFEST}" "${WORK}/manifest"
awk '$1=="static" {print; exit}' "${MANIFEST}" >>"${WORK}/manifest"
if run_check "${WORK}/manifest" >/dev/null 2>&1; then bad 'duplicate accepted'; else ok 'duplicate refused'; fi
mv "${FW}/ti-connectivity" "${WORK}/ti"
if run_check >/dev/null 2>&1; then bad 'missing TI root accepted'; else ok 'missing TI root refused'; fi
mv "${WORK}/ti" "${FW}/ti-connectivity"
if MODINFO_FAIL=1 run_check >/dev/null 2>&1; then bad 'zero parsed modules accepted'; else ok 'zero parsed modules refused'; fi
mv "${MODULES}/kernel/lib/btrtl.ko" "${WORK}/dep"
if run_check >"${WORK}/dep-error" 2>&1; then bad 'missing recursive dependency accepted'; else ok 'missing recursive dependency refused'; fi
assert_contains 'recursive failure names module' "${WORK}/dep-error" 'missing dependency module btrtl'
mv "${WORK}/dep" "${MODULES}/kernel/lib/btrtl.ko"
if PATH=/nonexistent "${BASH}" "${CHECK}" "${MODULES}" "${FW}" "${MANIFEST}" >"${WORK}/tool" 2>&1; then bad 'missing modinfo accepted'; else ok 'missing modinfo refused'; fi
assert_contains 'missing-tool diagnostic is explicit' "${WORK}/tool" 'modinfo'
POSTINST="${REPO}/mkosi/mkosi.images/platform/mkosi.postinst"
assert_contains 'platform stages the same committed roots' "${REPO}/lib/stages/partition.sh" 'rk3588-bluetooth-firmware-roots.txt'
prepare_line="$(grep -n '^    bluetooth_firmware_prepare' "${POSTINST}" | cut -d: -f1)"
prune_line="$(grep -n '^  prune_irrelevant_rk3588_firmware$' "${POSTINST}" | cut -d: -f1)"
if [[ -n "${prepare_line}" && -n "${prune_line}" && "${prepare_line}" -lt "${prune_line}" ]]; then ok 'production prepares closure before pruning'; else bad 'closure preflight not wired before prune'; fi
# Given: runtime-only Intel/TI roots and an unconsumed non-Bluetooth candidate.
mkdir -p "${FW}/qcom"; touch "${FW}/qcom/unconsumed.bin"
source "${REPO}/mkosi/customize/bluetooth-firmware.sh"
eval "$(sed -n '/^installed_module_firmware_refs()/,/^}/p; /^prune_irrelevant_rk3588_firmware()/,/^}/p' "${REPO}/mkosi/mkosi.images/platform/mkosi.postinst")"
log() { printf '%s\n' "$*"; }
export BUILDROOT="${WORK}/root"
bluetooth_firmware_prepare "${MODULES}" "${FW}" "${MANIFEST}" || exit 1
# When: real prune runs. Then: all snapshotted objects survive, qcom does not.
if (set -e; prune_irrelevant_rk3588_firmware) >"${WORK}/prune" 2>&1; then ok 'real prune passes'; else bad "$(<"${WORK}/prune")"; fi
if bluetooth_firmware_assert_retained "${FW}"; then ok 'every closure object survives real prune'; else bad 'prune lost a closure object'; fi
if [[ ! -e "${FW}/qcom" ]]; then ok 'unconsumed non-Bluetooth family removed'; else bad 'blanket preservation'; fi
if [[ -f "${FW}/ti-connectivity/TIInit_fixture.bts" ]]; then ok 'TI runtime firmware survives'; else bad 'TI firmware removed'; fi
# A candidate-list accident must fail BEFORE any deletion, not quietly preserve.
eval "$(declare -f prune_irrelevant_rk3588_firmware | sed 's/qcom intel/qca qcom intel/')"
if (set -e; prune_irrelevant_rk3588_firmware) >"${WORK}/candidate" 2>&1; then bad 'Bluetooth deletion candidate accepted'; else ok 'Bluetooth candidate mutation refused'; fi
rm "${FW}/rtl_bt/rtl8852bu_fw.bin"
if bluetooth_firmware_assert_retained "${FW}" >/dev/null 2>&1; then bad 'closure deletion accepted'; else ok 'closure deletion mutation refused'; fi
printf '%s passed, %s failed\n' "${PASS}" "${FAIL}"
(( FAIL == 0 ))
