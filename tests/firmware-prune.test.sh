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
# Hardware-free and root-free: the real shipped sweep is sourced and
# driven against synthetic roots
# with a stubbed `modinfo`, plus one leg against the REAL `modinfo` so the flag
# and invocation cannot silently rot.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"
POSTINST="${PIPELINE_DIR}/mkosi/mkosi.images/platform/mkosi.postinst"
SWEEP="${PIPELINE_DIR}/mkosi/customize/firmware-sweep.sh"
eval "$(bash "${PIPELINE_DIR}/lib/resolve.sh" rock-5b-plus)"
export FIRMWARE_SWEEP_PREFIXES FIRMWARE_SWEEP_FILES FIRMWARE_PRESERVED_ROOTS

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
  printf 'source "%s"\n' "${PIPELINE_DIR}/mkosi/runtime/ceralive-kernel-boot-staging.sh" "${SWEEP}"
} >"${FNS}"

bash -c 'source "$1"; declare -F installed_module_firmware_refs firmware_sweep' _ "${FNS}" >/dev/null \
  || { echo "FATAL: shipped firmware functions absent"; exit 1; }
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
# Every invocation answers the same recorded reference set.
cat "${refs}"
EOF
  chmod +x "${dir}/modinfo"
}

run_prune() {
  local root="$1" refs="$2"
  local stub="${WORK}/bin.$$"
  make_modinfo_stub "${stub}" "${refs}"
  PATH="${stub}:${PATH}" BUILDROOT="${root}" \
    bash -c "set -euo pipefail; source '${FNS}'; firmware_sweep '${root}'" 2>&1
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
  *"KEPT nvidia (referenced by an installed module: 7.1.7-ceralive-rk3588/kernel/drivers/net/fake.ko: nvidia/tegra234/xusb.bin)"*)
    ok "the refusal names the exact module reference that blocked it" ;;
  *) bad "the refusal must name the blocking reference; got: ${OUT}" ;;
esac
check "no" "$(present "${ROOT}" qcom)" "an unreferenced sibling family is still pruned in the same run"

ROOT="${WORK}/r3"
seed_root "${ROOT}"
printf 'r8a779x_usb3_rom.mem\n' >"${WORK}/refs-r8a"
OUT="$(run_prune "${ROOT}" "${WORK}/refs-r8a")"
check "yes" "$(present "${ROOT}" r8a779x_usb3_rom.mem)" "a referenced single FILE is refused too"

# Policy inputs must reach the real sweep, including nested prefixes.
ROOT="${WORK}/policy"
seed_root "${ROOT}"
for fam in amdgpu radeon i915 xe mellanox netronome intel/ipu vendorx/server; do
  mkdir -p "${ROOT}/usr/lib/firmware/${fam}"
  touch "${ROOT}/usr/lib/firmware/${fam}/blob.bin"
done
touch "${ROOT}/usr/lib/firmware/intel/ibt-0040.sfi" "${ROOT}/usr/lib/firmware/vendorx/radio.bin"
printf 'intel/ibt-0040.sfi\nvendorx/radio.bin\nnvidia/gm20b/acr/bl.bin\n' >"${WORK}/refs-policy"
OUT="$(FIRMWARE_SWEEP_PREFIXES='intel intel/ipu vendorx/server amdgpu radeon i915 xe mellanox netronome nvidia' \
  run_prune "${ROOT}" "${WORK}/refs-policy")"
for fam in intel/ipu vendorx/server amdgpu radeon i915 xe mellanox netronome; do
  check no "$(present "${ROOT}" "${fam}")" "policy removes unreferenced prefix '${fam}'"
done
for fam in intel/ibt-0040.sfi vendorx/radio.bin nvidia; do
  check yes "$(present "${ROOT}" "${fam}")" "policy keeps referenced sibling '${fam}'"
done
[[ "${OUT}" == *fake.ko*"nvidia/gm20b/acr/bl.bin"* ]] \
  && ok "kept policy candidate names its referencing module and path" \
  || bad "kept policy candidate lost its module identity: ${OUT}"

ROOT="${WORK}/builtin"
seed_root "${ROOT}"
printf 'switch.firmware=microchip/mscc_vsc8584_revb_int8051_fb48.bin\0switch.alias=fixture\0' \
  >"${ROOT}/usr/lib/modules/7.1.7-ceralive-rk3588/modules.builtin.modinfo"
OUT="$(run_prune "${ROOT}" "${WORK}/refs-empty")"
check yes "$(present "${ROOT}" microchip)" "built-in firmware reference blocks deletion"
[[ "${OUT}" == *switch*"microchip/mscc_vsc8584_revb_int8051_fb48.bin"* ]] \
  && ok "kept built-in candidate names its referencing driver" \
  || bad "built-in blocker not named: ${OUT}"

ROOT="${WORK}/x86"
seed_root "${ROOT}"
mkdir -p "${ROOT}/usr/lib/firmware/i915"
touch "${ROOT}/usr/lib/firmware/i915/skl_dmc_ver1_27.bin"
mv "${ROOT}/usr/lib/modules/7.1.7-ceralive-rk3588/kernel/drivers/net/fake.ko" \
  "${ROOT}/usr/lib/modules/7.1.7-ceralive-rk3588/kernel/drivers/net/i915.ko"
printf 'i915/skl_dmc_ver1_27.bin\n' >"${WORK}/refs-i915"
OUT="$(FIRMWARE_SWEEP_PREFIXES=i915 run_prune "${ROOT}" "${WORK}/refs-i915")"
check yes "$(present "${ROOT}" i915)" "x86-shaped i915 consumer keeps integrated-GPU firmware"
[[ "${OUT}" == *i915.ko*"i915/skl_dmc_ver1_27.bin"* ]] \
  && ok "x86 refusal names i915 module and firmware" || bad "x86 refusal missing: ${OUT}"
seed_root "${ROOT}"
OUT="$(FIRMWARE_SWEEP_PREFIXES='' run_prune "${ROOT}" "${WORK}/refs-empty")"
check yes "$(present "${ROOT}" qcom)" "empty policy removes nothing"
check yes "$(present "${ROOT}" r8a779x_usb3_rom.mem)" "empty prefix policy also leaves file candidates intact"
[[ "${OUT}" == *"no sweep candidates for this family"* ]] \
  && ok "empty policy logs the family no-op" || bad "empty policy diagnostic missing: ${OUT}"
OUT="$(FIRMWARE_SWEEP_PREFIXES='' run_prune "${WORK}/absent-root" "${WORK}/refs-empty")"
[[ "${OUT}" == *"no sweep candidates for this family"* ]] \
  && ok "empty policy is checked before firmware directory existence" || bad "empty policy checked too late"

for preserved in brcm rtl_bt rtw88 rtw89 rockchip mediatek iwlwifi; do
  ROOT="${WORK}/preserved-${preserved}"
  seed_root "${ROOT}"
  if OUT="$(FIRMWARE_SWEEP_PREFIXES="qcom ${preserved}" run_prune "${ROOT}" "${WORK}/refs-empty")"; then
    bad "preserved candidate '${preserved}' accepted"
  else
    ok "preserved candidate '${preserved}' is fatal"
  fi
  check yes "$(present "${ROOT}" qcom)" "preserved candidate '${preserved}' refuses before any deletion"
done

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
  "${BASH}" -c "set -euo pipefail; source '${FNS}'; firmware_sweep '${ROOT}'" 2>&1 || true)"
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
  bash -c "set -euo pipefail; source '${FNS}'; firmware_sweep '${ROOT}'" 2>&1)"
check "yes" "$(present "${ROOT}" nvidia)" "one unparseable module does not abort the sweep, and the readable ones still block"
check "no" "$(present "${ROOT}" qcom)" "the sweep still prunes what nothing references"

ROOT="${WORK}/r5c"
seed_root "${ROOT}"
STUB="${WORK}/bin-allfail"
mkdir -p "${STUB}"
printf '#!/usr/bin/env bash\nexit 1\n' >"${STUB}/modinfo"
chmod +x "${STUB}/modinfo"
OUT="$(PATH="${STUB}:${PATH}" BUILDROOT="${ROOT}" \
  bash -c "set -euo pipefail; source '${FNS}'; firmware_sweep '${ROOT}'" 2>&1)"
check "yes" "$(present "${ROOT}" qcom)" "a modinfo that reads NOTHING must not authorise deleting everything"
case "${OUT}" in
  *"unprovable"*) ok "the unprovable-consumer-set path says why it declined" ;;
  *) bad "the unprovable path must explain itself; got: ${OUT}" ;;
esac

# No installed driver metadata is not proof of zero firmware consumers.
ROOT="${WORK}/no-modules"
seed_root "${ROOT}"
rm -rf "${ROOT}/usr/lib/modules"
OUT="$(run_prune "${ROOT}" "${WORK}/refs-empty")"
check yes "$(present "${ROOT}" qcom)" "missing module metadata declines the sweep"
[[ "${OUT}" == *unprovable* ]] && ok "missing metadata explains the refusal" || bad "missing metadata diagnostic absent"

ROOT="${WORK}/policy-file"
seed_root "${ROOT}"
touch "${ROOT}/usr/lib/firmware/custom.bin"
OUT="$(FIRMWARE_SWEEP_FILES=custom.bin run_prune "${ROOT}" "${WORK}/refs-empty")"
check no "$(present "${ROOT}" custom.bin)" "file candidates come from family policy"
check yes "$(present "${ROOT}" r8a779x_usb3_rom.mem)" "a file outside the family policy survives"

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
CAND_BLOCK="$(<"${SWEEP}")"

for fam in brcm rtl_bt rtw88 rtw89 rockchip mediatek iwlwifi; do
  if [[ " ${FIRMWARE_SWEEP_PREFIXES} " == *" ${fam} "* ]]; then
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
  ok "the firmware prune removes FILES only, never packages"
fi

if grep -q '^  firmware_sweep "\${BUILDROOT}"$' "${POSTINST}"; then
  ok "the prune is wired into the boot-BSP branch"
else
  bad "the prune is defined but never called"
fi

# Every platform firmware-install transaction must precede the sweep. Drive the
# same contract against a scratch ordering mutation to prove it can fail.
check_firmware_order() {
  python3 - "$1" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text()
lines = text.splitlines()
installs = [i for i, line in enumerate(lines)
            if line.strip().startswith("mkosi-install ")
            and any(token in line for token in ("boot_bsp[@]", "FIRMWARE_PACKAGES", "_f[@]"))]
sweeps = [i for i, line in enumerate(lines)
          if line.strip() == 'firmware_sweep "${BUILDROOT}"']
assert installs and sweeps, "firmware install or sweep is not wired"
for install in installs:
    assert any(sweep > install for sweep in sweeps), "firmware_sweep precedes firmware install"
PY
}
if check_firmware_order "${POSTINST}"; then ok "every firmware install precedes its sweep"; else bad "firmware install ordering broken"; fi
awk '
  /^  mkosi-install .*boot_bsp/ { print "  firmware_sweep \"${BUILDROOT}\"" }
  /^  firmware_sweep / { next }
  { print }
' "${POSTINST}" >"${WORK}/postinst-before-install"
if check_firmware_order "${WORK}/postinst-before-install" >"${WORK}/ordering-error" 2>&1; then
  bad "firmware ordering mutation accepted"
else
  ok "firmware ordering contract rejects sweep-before-install mutation"
fi

# ---------------------------------------------------------------------------
# 6. The BUILDER IMAGE must actually provide modinfo.
#
# Everything above proves the sweep is correct WHEN modinfo is present, including
# the fail-safe that declines when it is not — so a builder without `kmod` takes
# the decline branch on every real build and the whole prune is a no-op that no
# synthetic-tree case can see. Same shape as the call-site check above: a
# capability the function depends on, asserted where it is provisioned.
#
# mkosi.postinst is a NON-chroot script, so `modinfo` resolves from the builder
# image, never from the rootfs being built — kmod does not belong in the device
# package set.
# ---------------------------------------------------------------------------
BUILDER_DOCKERFILE="${PIPELINE_DIR}/ci/Dockerfile"
if [[ -f "${BUILDER_DOCKERFILE}" ]]; then
  if grep -qE '^ +kmod \\$' "${BUILDER_DOCKERFILE}"; then
    ok "the canonical builder image installs kmod, so modinfo is available to the prune"
  else
    bad "ci/Dockerfile must install kmod — without modinfo the firmware prune declines on every build"
  fi
  if grep -q 'command -v modinfo' "${BUILDER_DOCKERFILE}"; then
    ok "the builder image build FAILS if modinfo is missing"
  else
    bad "ci/Dockerfile must assert modinfo is present, like its mkosi/pefile pin checks"
  fi
else
  bad "canonical builder Dockerfile not found at ${BUILDER_DOCKERFILE}"
fi

printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
