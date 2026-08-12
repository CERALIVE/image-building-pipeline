#!/usr/bin/env bash
#
# Firmware prune — the contract that says nothing is deleted without proof that
# no installed module can ask for it.
#
# WHY THIS FILE EXISTS. `armbian-firmware` ships blobs for a great many parts an
# RK3588 streaming appliance does not have, and every one of them is carried in
# both RAUC slots and inside every OTA bundle. Deleting them by family NAME is
# the obvious approach and it is the dangerous one: this repository has already
# lost Wi-Fi once to a symbol nobody noticed was off, and a missing firmware file
# fails exactly the same way — at probe time, on a device, with a build log that
# says nothing.
#
# So the shipped prune does not work from a list of "families we believe are
# unused". It reads every installed module with `modinfo -F firmware`, builds the
# real consumer set, and KEEPS — loudly — any candidate family a module can
# actually request. The list of candidates is an input to that check, not the
# decision itself, which is what makes a wrong entry a caught mistake instead of
# a dead radio.
#
# THE PRESERVED FAMILIES ARE STRUCTURAL, NOT INCIDENTAL. brcm/, rtl_bt/, rtw88/,
# rtw89/ and rockchip/ carry the two shipped boards' own Wi-Fi, Bluetooth and SoC
# blobs. mediatek/ and iwlwifi/ are preserved for a different reason: no
# dual-board module/firmware inventory exists yet to judge them, and this suite
# refuses to let "probably unused" become a deletion.
#
# Hardware-free and root-free: the real shipped function is lifted out of
# mkosi/mkosi.images/platform/mkosi.postinst and driven against synthetic roots
# with a stubbed `modinfo`, plus one leg against the REAL `modinfo` so the flag
# and invocation cannot silently rot.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"
POSTINST="${PIPELINE_DIR}/mkosi/mkosi.images/platform/mkosi.postinst"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$(( PASS + 1 )); printf 'ok   %s\n' "$*"; }
bad()  { FAIL=$(( FAIL + 1 )); printf 'FAIL %s\n' "$*"; }
check() { if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 (want '$1', got '$2')"; fi; }

# The shipped functions, lifted by TEXT so this suite can never drift into
# testing a copy of them.
FNS="${WORK}/fw-fns.sh"
{
  echo 'log() { printf "[platform] %s\n" "$*" >&2; }'
  sed -n '/^installed_module_firmware_refs()/,/^}/p' "${POSTINST}"
  sed -n '/^prune_irrelevant_rk3588_firmware()/,/^}/p' "${POSTINST}"
} >"${FNS}"

grep -q '^installed_module_firmware_refs()' "${FNS}" \
  || { echo "FATAL: could not lift installed_module_firmware_refs from ${POSTINST}"; exit 1; }
grep -q '^prune_irrelevant_rk3588_firmware()' "${FNS}" \
  || { echo "FATAL: could not lift prune_irrelevant_rk3588_firmware from ${POSTINST}"; exit 1; }
bash -n "${FNS}"

# ---------------------------------------------------------------------------
# Fixture: a rootfs carrying every family this contract cares about, plus a
# stubbed `modinfo` whose answer is whatever the caller writes into REFS_FILE.
# ---------------------------------------------------------------------------
FAMILIES=(
  qcom intel ath10k ath11k ath12k updates microchip nvidia tegra renesas
  brcm rtl_bt rtw88 rtw89 rockchip mediatek iwlwifi
)

seed_root() {
  local root="$1"
  rm -rf "${root}"
  local fam
  for fam in "${FAMILIES[@]}"; do
    mkdir -p "${root}/usr/lib/firmware/${fam}"
    printf 'blob\n' >"${root}/usr/lib/firmware/${fam}/${fam}-fw.bin"
  done
  printf 'blob\n' >"${root}/usr/lib/firmware/r8a779x_usb3_rom.mem"
  mkdir -p "${root}/usr/lib/modules/7.1.7-ceralive-rk3588/kernel/drivers/net"
  printf 'elf\n' >"${root}/usr/lib/modules/7.1.7-ceralive-rk3588/kernel/drivers/net/fake.ko"
}

make_modinfo_stub() {
  local dir="$1" refs="$2"
  mkdir -p "${dir}"
  cat >"${dir}/modinfo" <<EOF
#!/usr/bin/env bash
# Every invocation answers the same recorded reference set; the shipped function
# batches module paths through xargs, so the stub must not depend on its args.
cat "${refs}"
EOF
  chmod +x "${dir}/modinfo"
}

run_prune() {
  local root="$1" refs="$2"
  local stub="${WORK}/bin.$$"
  make_modinfo_stub "${stub}" "${refs}"
  PATH="${stub}:${PATH}" BUILDROOT="${root}" \
    bash -c "set -euo pipefail; source '${FNS}'; prune_irrelevant_rk3588_firmware" 2>&1
}

present() { [[ -e "$1/usr/lib/firmware/$2" ]] && echo yes || echo no; }

# ---------------------------------------------------------------------------
# 1. With no module referencing anything, every candidate family goes and every
#    preserved family stays.
# ---------------------------------------------------------------------------
ROOT="${WORK}/r1"
seed_root "${ROOT}"
: >"${WORK}/refs-empty"
OUT="$(run_prune "${ROOT}" "${WORK}/refs-empty")"

for fam in qcom intel ath10k ath11k ath12k updates microchip nvidia tegra renesas; do
  check "no" "$(present "${ROOT}" "${fam}")" "unreferenced candidate family '${fam}' is pruned"
done
check "no" "$(present "${ROOT}" r8a779x_usb3_rom.mem)" "unreferenced r8a779x USB3 ROM file is pruned"

for fam in brcm rtl_bt rtw88 rtw89 rockchip mediatek iwlwifi; do
  check "yes" "$(present "${ROOT}" "${fam}")" "preserved family '${fam}' is never touched"
done

# ---------------------------------------------------------------------------
# 2. THE REFUSAL. A family a loaded module needs must not be pruned, even though
#    it is on the candidate list — the sweep is the authorisation, not the list.
# ---------------------------------------------------------------------------
ROOT="${WORK}/r2"
seed_root "${ROOT}"
cat >"${WORK}/refs-nvidia" <<'EOF'
nvidia/tegra234/xusb.bin
rtw89/rtw8852b_fw.bin
EOF
OUT="$(run_prune "${ROOT}" "${WORK}/refs-nvidia")"

check "yes" "$(present "${ROOT}" nvidia)" "a REFERENCED candidate family is refused, not pruned"
case "${OUT}" in
  *"KEPT nvidia (referenced by an installed module: nvidia/tegra234/xusb.bin)"*)
    ok "the refusal names the exact module reference that blocked it" ;;
  *) bad "the refusal must name the blocking reference; got: ${OUT}" ;;
esac
check "no" "$(present "${ROOT}" qcom)" "an unreferenced sibling family is still pruned in the same run"

ROOT="${WORK}/r3"
seed_root "${ROOT}"
printf 'r8a779x_usb3_rom.mem\n' >"${WORK}/refs-r8a"
OUT="$(run_prune "${ROOT}" "${WORK}/refs-r8a")"
check "yes" "$(present "${ROOT}" r8a779x_usb3_rom.mem)" "a referenced single FILE is refused too"

# A leading slash is how some modules spell the reference; it must still match.
ROOT="${WORK}/r4"
seed_root "${ROOT}"
printf '/microchip/mscc_vsc8574_revb_int8051_29e8.bin\n' >"${WORK}/refs-slash"
OUT="$(run_prune "${ROOT}" "${WORK}/refs-slash")"
check "yes" "$(present "${ROOT}" microchip)" "an absolute-path reference still blocks the prune"

# ---------------------------------------------------------------------------
# 3. FAIL SAFE. Without modinfo there is no proof, so nothing may be deleted.
# ---------------------------------------------------------------------------
ROOT="${WORK}/r5"
seed_root "${ROOT}"
OUT="$(PATH=/nonexistent BUILDROOT="${ROOT}" \
  "${BASH}" -c "set -euo pipefail; source '${FNS}'; prune_irrelevant_rk3588_firmware" 2>&1 || true)"
check "yes" "$(present "${ROOT}" qcom)" "with no modinfo available NOTHING is pruned"
case "${OUT}" in
  *"cannot prove"*) ok "the no-modinfo path says why it declined" ;;
  *) bad "the no-modinfo path must explain itself; got: ${OUT}" ;;
esac

# ---------------------------------------------------------------------------
# 3b. An UNPARSEABLE module must not abort the build, and a run in which NOTHING
#     parsed must not authorise deleting everything. Batching these through
#     xargs made one bad .ko kill the whole postinstall under `set -e`; the
#     naive fix (swallow every failure) is worse, because an empty consumer set
#     reads as "no module needs any of this".
# ---------------------------------------------------------------------------
ROOT="${WORK}/r5b"
seed_root "${ROOT}"
printf 'not-an-elf\n' >"${ROOT}/usr/lib/modules/7.1.7-ceralive-rk3588/kernel/drivers/net/broken.ko"
STUB="${WORK}/bin-partial"
mkdir -p "${STUB}"
cat >"${STUB}/modinfo" <<'STUBEOF'
#!/usr/bin/env bash
status=0
for arg in "$@"; do
  case "${arg}" in
    -F|firmware) continue ;;
    *broken.ko) status=1 ;;
    *) echo "nvidia/tegra234/xusb.bin" ;;
  esac
done
exit "${status}"
STUBEOF
chmod +x "${STUB}/modinfo"
OUT="$(PATH="${STUB}:${PATH}" BUILDROOT="${ROOT}" \
  bash -c "set -euo pipefail; source '${FNS}'; prune_irrelevant_rk3588_firmware" 2>&1)"
check "yes" "$(present "${ROOT}" nvidia)" "one unparseable module does not abort the sweep, and the readable ones still block"
check "no" "$(present "${ROOT}" qcom)" "the sweep still prunes what nothing references"

ROOT="${WORK}/r5c"
seed_root "${ROOT}"
STUB="${WORK}/bin-allfail"
mkdir -p "${STUB}"
printf '#!/usr/bin/env bash\nexit 1\n' >"${STUB}/modinfo"
chmod +x "${STUB}/modinfo"
OUT="$(PATH="${STUB}:${PATH}" BUILDROOT="${ROOT}" \
  bash -c "set -euo pipefail; source '${FNS}'; prune_irrelevant_rk3588_firmware" 2>&1)"
check "yes" "$(present "${ROOT}" qcom)" "a modinfo that reads NOTHING must not authorise deleting everything"
case "${OUT}" in
  *"unprovable"*) ok "the unprovable-consumer-set path says why it declined" ;;
  *) bad "the unprovable path must explain itself; got: ${OUT}" ;;
esac

# ---------------------------------------------------------------------------
# 4. The real modinfo, so the flag and the invocation cannot rot silently.
# ---------------------------------------------------------------------------
if command -v modinfo >/dev/null 2>&1; then
  # Materialise the candidate list into a FILE before scanning it. A `break`
  # inside a `find | head | while` closes the pipe, `head` and `find` die of
  # SIGPIPE, and `set -o pipefail` turns a correct early exit into a failure —
  # the exact trap `deb_lists_path` already shipped once in this repo.
  find /usr/lib/modules /lib/modules -type f -name '*.ko*' 2>/dev/null >"${WORK}/host-modules" || true
  REAL_KO=""
  while IFS= read -r ko; do
    if [[ -n "$(modinfo -F firmware "${ko}" 2>/dev/null)" ]]; then REAL_KO="${ko}"; break; fi
  done < <(head -300 "${WORK}/host-modules")
  if [[ -n "${REAL_KO}" ]]; then
    ROOT="${WORK}/r6"
    seed_root "${ROOT}"
    cp "${REAL_KO}" "${ROOT}/usr/lib/modules/7.1.7-ceralive-rk3588/kernel/drivers/net/real.ko"
    EXPECT="$(modinfo -F firmware "${REAL_KO}" | sed 's#^/*##' | awk 'NF' | sort -u)"
    GOT="$(BUILDROOT="${ROOT}" bash -c "set -euo pipefail; source '${FNS}'; installed_module_firmware_refs '${ROOT}'")"
    if [[ -n "${EXPECT}" ]] && grep -qxF -- "$(head -1 <<<"${EXPECT}")" <<<"${GOT}"; then
      ok "the real modinfo sweep reads a real module's firmware references"
    else
      bad "the real modinfo sweep lost a reference (expected '${EXPECT}', got '${GOT}')"
    fi
  else
    ok "SKIP real-modinfo leg: no host module on this box declares firmware"
  fi
else
  ok "SKIP real-modinfo leg: modinfo not installed"
fi

# ---------------------------------------------------------------------------
# 5. Static contract. These are the properties a synthetic-tree run cannot see.
# ---------------------------------------------------------------------------
CAND_BLOCK="$(sed -n '/^prune_irrelevant_rk3588_firmware()/,/^}/p' "${POSTINST}")"

for fam in brcm rtl_bt rtw88 rtw89 rockchip mediatek iwlwifi; do
  if grep -qE "^\s+${fam}\b|[( ]${fam} " <<<"$(sed -n '/local -a candidates=(/,/)/p' <<<"${CAND_BLOCK}")"; then
    bad "preserved family '${fam}' must never appear in the prune candidate list"
  else
    ok "preserved family '${fam}' is absent from the candidate list"
  fi
done

if grep -q 'modinfo' <<<"${CAND_BLOCK}"; then
  ok "the prune is gated on modinfo, not on a static family list alone"
else
  bad "the prune must consult modinfo"
fi

if grep -q 'armbian-firmware\|libmali\|hostapd' <<<"${CAND_BLOCK}"; then
  bad "no package removal belongs in the firmware prune"
else
  ok "the prune removes FILES only — armbian-firmware, libmali and hostapd stay installed"
fi

if grep -q 'prune_irrelevant_rk3588_firmware$' "${POSTINST}"; then
  ok "the prune is wired into the boot-BSP branch"
else
  bad "the prune is defined but never called"
fi

printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
