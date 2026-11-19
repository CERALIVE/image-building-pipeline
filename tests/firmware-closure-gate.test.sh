#!/usr/bin/env bash
# Final-artifact closure, using the real CLI and sourced orchestrator stage.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"
source "${HERE}/lib/assertions.sh"
WORK="$(mktemp -d)"
trap 'chmod -R u+rwX "${WORK}"; rm -rf -- "${WORK}"' EXIT
CLI="${PIPELINE_DIR}/lib/check-firmware-closure.sh"
mkdir -p "${WORK}/bin"
cat >"${WORK}/bin/modinfo" <<'SH'
#!/usr/bin/env bash
[[ "$1" == -F && "$2" == firmware && $# == 3 ]] || exit 2
cat -- "$3"
[[ "$3" != *broken.ko ]]
SH
chmod +x "${WORK}/bin/modinfo"
export PATH="${WORK}/bin:${PATH}"
FW=nvidia/gm20b/acr/bl.bin
ROOT="${WORK}/root"
MODS="${ROOT}/usr/lib/modules/fixture"
EXCEPTIONS="${WORK}/exceptions"

seed() {
  chmod -R u+rwX "${ROOT}" 2>/dev/null
  rm -rf -- "${ROOT}"
  mkdir -p "${MODS}/kernel" "${ROOT}/usr/lib/firmware/nvidia/gm20b/acr" \
    "${ROOT}/var/lib/dpkg/info"
  ln -s usr/lib "${ROOT}/lib"
  printf '%s\n' "${FW}" >"${MODS}/kernel/nouveau.ko"
  : >"${MODS}/modules.builtin"
  printf 'blob\n' >"${ROOT}/usr/lib/firmware/${FW}"
  # A payload package, beside a firmware metapackage with no files.
  printf '/usr/lib/firmware/%s\n' "${FW}" >"${ROOT}/var/lib/dpkg/info/payload-data.list"
  printf '/.\n' >"${ROOT}/var/lib/dpkg/info/firmware-meta.list"
  printf '# path<TAB>reason\n' >"${EXCEPTIONS}"
}

run_case() {
  local name="$1" expected="$2" input="${3:-${ROOT}}" rc=0
  bash "${CLI}" "${input}" "${EXCEPTIONS}" >"${WORK}/${name}.log" 2>&1 || rc=$?
  if [[ "${expected}" == pass ]]; then
    assert_eq "${name}: exits successfully" 0 "${rc}"
  elif (( rc != 0 )); then
    ok "${name}: fails closed (${rc})"
    assert_contains "${name}: gate reports the refusal" "${WORK}/${name}.log" 'firmware closure: FATAL'
  else
    bad "${name}: accepted invalid closure"
  fi
}

seed
run_case complete pass
assert_contains "complete: reports checked references" "${WORK}/complete.log" 'checked=1'
printf 'not-in-any-package.bin\n' >>"${MODS}/kernel/nouveau.ko"
run_case never-shipped pass
assert_contains "never shipped: diagnostic names path" "${WORK}/never-shipped.log" 'not-in-any-package.bin'
assert_contains "never shipped: counted separately" "${WORK}/never-shipped.log" 'never-shipped=1'
seed
rm "${ROOT}/usr/lib/firmware/${FW}"
run_case nouveau-missing fail
assert_contains "missing: diagnostic names module" "${WORK}/nouveau-missing.log" 'nouveau.ko'
assert_contains "missing: diagnostic names shipped path" "${WORK}/nouveau-missing.log" "${FW}"
printf '%s\t%s\n' "${FW}" 'Fixture: intentionally unavailable hardware' >>"${EXCEPTIONS}"
run_case explicit-exception pass
assert_contains "exception: reason is auditable" "${WORK}/explicit-exception.log" 'intentionally unavailable hardware'
for bad_exception in "${FW}" "${FW}"$'\t' '*'$'\ttoo broad' '../escape'$'\tinvalid'; do
  printf '%s\n' "${bad_exception}" >"${EXCEPTIONS}"
  run_case malformed-exception fail
done

for suffix in .zst .xz; do
  seed
  mv "${ROOT}/usr/lib/firmware/${FW}" "${ROOT}/usr/lib/firmware/${FW}${suffix}"
  printf '/usr/lib/firmware/%s%s\n' "${FW}" "${suffix}" >"${ROOT}/var/lib/dpkg/info/payload-data.list"
  run_case "compressed${suffix}" pass
  rm "${ROOT}/usr/lib/firmware/${FW}${suffix}"
  run_case "missing-compressed${suffix}" fail
done
seed
printf 'switch.file=drivers/net/switch\0switch.firmware=microchip/switch.bin\0' >"${MODS}/modules.builtin.modinfo"
printf 'kernel/drivers/net/switch.ko\n' >"${MODS}/modules.builtin"
printf '/usr/lib/firmware/microchip/switch.bin\n' >>"${ROOT}/var/lib/dpkg/info/payload-data.list"
run_case builtin-missing fail
assert_contains "built-in: diagnostic names driver" "${WORK}/builtin-missing.log" 'switch (built-in)'
mkdir -p "${ROOT}/usr/lib/firmware/microchip"
printf 'blob\n' >"${ROOT}/usr/lib/firmware/microchip/switch.bin"
run_case builtin-complete pass
rm "${MODS}/kernel/nouveau.ko"
run_case builtin-only pass

for scenario in no-modules empty-inventory missing-metadata truncated-metadata interrupted-modinfo \
  unreadable-metadata unreadable-list unreadable-subtree malformed-ref missing-builtin-inventory \
  truncated-package-list missing-package-lists conflicting-module-roots truncated-builtin-list; do
  seed
  case "${scenario}" in
    no-modules) rm -rf "${ROOT}/usr/lib/modules" ;;
    empty-inventory) rm "${MODS}/kernel/nouveau.ko" ;;
    missing-metadata) printf 'kernel/switch.ko\n' >"${MODS}/modules.builtin" ;;
    truncated-metadata) printf 'switch.license=GPL\0switch.firmwa' >"${MODS}/modules.builtin.modinfo" ;;
    interrupted-modinfo) cp "${MODS}/kernel/nouveau.ko" "${MODS}/kernel/broken.ko" ;;
    unreadable-metadata)
      printf 'switch.license=GPL\0' >"${MODS}/modules.builtin.modinfo"
      chmod 000 "${MODS}/modules.builtin.modinfo" ;;
    unreadable-list) chmod 000 "${ROOT}/var/lib/dpkg/info/payload-data.list" ;;
    unreadable-subtree) mkdir "${MODS}/inaccessible"; chmod 000 "${MODS}/inaccessible" ;;
    malformed-ref) printf '../host-file\n' >>"${MODS}/kernel/nouveau.ko" ;;
    missing-builtin-inventory) rm "${MODS}/modules.builtin" ;;
    truncated-package-list) printf '/usr/lib/firmware/%s' "${FW}" >"${ROOT}/var/lib/dpkg/info/late.list" ;;
    missing-package-lists) rm "${ROOT}/var/lib/dpkg/info/"*.list ;;
    conflicting-module-roots)
      rm "${ROOT}/lib"
      mkdir -p "${ROOT}/lib/modules/other"
      printf 'deleted.bin\n' >"${ROOT}/lib/modules/other/other.ko" ;;
    truncated-builtin-list)
      printf 'kernel/switch.ko' >"${MODS}/modules.builtin"
      printf 'switch.license=GPL\0' >"${MODS}/modules.builtin.modinfo" ;;
  esac
  run_case "${scenario}" fail
done

# Runtime absolute links belong to the rootfs, never the build host.
for target in '../../blob.bin' '/usr/lib/firmware/blob.bin' 'loop.bin' \
  '../../../../../../host-only.bin'; do
  seed
  printf 'blob\n' >"${ROOT}/usr/lib/firmware/blob.bin"
  rm "${ROOT}/usr/lib/firmware/${FW}"
  ln -s "${target}" "${ROOT}/usr/lib/firmware/${FW}"
  ln -s bl.bin "${ROOT}/usr/lib/firmware/nvidia/gm20b/acr/loop.bin"
  want=fail
  [[ "${target}" != '../../blob.bin' ]] || want=pass
  # Relative path from acr/ to firmware/ needs three parent components.
  if [[ "${target}" == '../../blob.bin' ]]; then
    mkdir -p "${ROOT}/usr/lib/firmware/nvidia"
    printf 'blob\n' >"${ROOT}/usr/lib/firmware/nvidia/blob.bin"
  fi
  [[ "${target}" != /usr/lib/firmware/blob.bin ]] || want=pass
  run_case runtime-symlink "${want}"
  tar -C "${ROOT}" -cf "${WORK}/rootfs.tar" . || exit 1
  run_case artifact-symlink "${want}" "${WORK}/rootfs.tar"
done
seed
rm "${ROOT}/usr/lib/firmware/${FW}"
ln -s "${PIPELINE_DIR}/README.md" "${ROOT}/usr/lib/firmware/${FW}"
run_case host-absolute-link fail
seed
mkdir -p "${ROOT}/usr/share"
printf 'ordinary data\n' >"${ROOT}/usr/share/literal [doc].txt"
tar -C "${ROOT}" -cf "${WORK}/rootfs.tar" . || exit 1
run_case artifact-complete pass "${WORK}/rootfs.tar"
ln -s /usr/src/missing-headers "${MODS}/build"
ln -s /usr/src/missing-source "${MODS}/source"
run_case development-links pass
rm "${MODS}/build" "${MODS}/source"
ln "${ROOT}/usr/lib/firmware/${FW}" "${ROOT}/usr/lib/firmware/hardlink.bin"
tar -C "${ROOT}" -cf "${WORK}/hardlink.tar" . || exit 1
run_case artifact-hardlink pass "${WORK}/hardlink.tar"
tar -C "${ROOT}" --transform='s,^./usr/share,../outside,' -cf "${WORK}/traversal.tar" . || exit 1
run_case artifact-traversal fail "${WORK}/traversal.tar"
tar -C "${ROOT}" --transform='s,^./usr/share,/host-absolute,' -cf "${WORK}/absolute.tar" . || exit 1
run_case artifact-absolute-member fail "${WORK}/absolute.tar"
# Inject failures only at process boundaries, after genuine partial output.
REAL_FIND="$(command -v find)"
REAL_TAR="$(command -v tar)"
printf '#!/usr/bin/env bash\n"%s" "$@"\nexit 9\n' "${REAL_FIND}" >"${WORK}/bin/find"
chmod +x "${WORK}/bin/find"
run_case interrupted-find fail
rm "${WORK}/bin/find"
printf '#!/usr/bin/env bash\n"%s" "$@"\nexit 9\n' "${REAL_TAR}" >"${WORK}/bin/tar"
chmod +x "${WORK}/bin/tar"
run_case interrupted-tar fail "${WORK}/rootfs.tar"
rm "${WORK}/bin/tar"
printf 'not a tar\n' >"${WORK}/corrupt.tar"
run_case corrupt-artifact fail "${WORK}/corrupt.tar"
head -c 2048 "${WORK}/rootfs.tar" >"${WORK}/truncated.tar"
run_case truncated-artifact fail "${WORK}/truncated.tar"

# The actual sourced stage must inspect the passed artifact and propagate failure.
run_stage() {
  INSTALL_BOOT_BSP="$1" artifact="$2" \
    bash -c '
      set -euo pipefail
      PIPELINE_DIR="$1"; HERE="${PIPELINE_DIR}/lib"
      source "${HERE}/common.sh"
      source "${HERE}/stages/firmware-closure-gate.sh"
      stage_firmware_closure_gate
    ' _ "${PIPELINE_DIR}"
}
if run_stage 1 "${WORK}/rootfs.tar" >"${WORK}/stage-pass.log" 2>&1; then
  ok "source stage executes complete artifact"
else
  bad "source stage rejects complete artifact"
fi
assert_contains "stage invokes actual gate" "${WORK}/stage-pass.log" 'checked=1'
if run_stage 1 "${WORK}/corrupt.tar" >"${WORK}/stage-fail.log" 2>&1; then
  bad "source stage swallows artifact failure"
else
  ok "source stage propagates artifact failure"
fi
if run_stage 0 "${WORK}/absent.tar" >"${WORK}/stage-skip.log" 2>&1; then
  ok "kernel-less parity stage skips like size gate"
else
  bad "kernel-less parity stage inspects nonexistent artifact"
fi
assert_contains "parity skip explains itself" "${WORK}/stage-skip.log" 'INSTALL_BOOT_BSP=0'

# A plan must reach the same pre-artifact exit on EFI/GRUB without DTB/U-Boot.
# Resolve the real x86 manifest, replacing only the adapter for boundary cases.
run_resolution() {
  local resolver="$1"
  env -i PATH="${PATH}" HOME="${HOME}" TMPDIR="${TMPDIR:-/tmp}" \
    bash -c '
      PIPELINE_DIR="$1"; HERE="${PIPELINE_DIR}/lib"
      source "${HERE}/common.sh"
      source "${HERE}/paths.sh"
      source "${HERE}/shared/target-release-lib.sh"
      source "${HERE}/stages/resolve.sh"
      target_release_load
      RESOLVE_SH="$2"; MKOSI_DIR="${PIPELINE_DIR}/mkosi"
      INSTALL_BOOT_BSP=1; board=x86-minipc; variant=default
      stage_resolve
    ' _ "${PIPELINE_DIR}" "${resolver}"
}
for adapter in efi grub custom; do
  resolver="${PIPELINE_DIR}/lib/resolve.sh"
  if [[ "${adapter}" != efi ]]; then
    resolver="${WORK}/resolve-${adapter}"
    printf '#!/usr/bin/env bash\n"%s/lib/resolve.sh" "$@" || exit\nprintf "RAUC_BOOTLOADER_ADAPTER=%s\\n"\n' \
      "${PIPELINE_DIR}" "${adapter}" >"${resolver}"
    chmod +x "${resolver}"
  fi
  if run_resolution "${resolver}" >"${WORK}/resolve-${adapter}.log" 2>&1; then
    if [[ "${adapter}" == custom ]]; then
      bad "custom boot adapter accepted missing DTB/U-Boot"
    else
      ok "${adapter} plan resolves without DTB/U-Boot packages"
    fi
  elif [[ "${adapter}" == custom ]]; then
    ok "custom boot adapter still requires DTB/U-Boot"
    assert_contains "custom adapter names missing requirement" "${WORK}/resolve-custom.log" 'DTB_PACKAGES'
  else
    bad "${adapter} plan rejects its intentionally empty DTB/U-Boot packages"
  fi
done
printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
