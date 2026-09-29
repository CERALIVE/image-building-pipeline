#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "${tmp}"' EXIT
mkdir -p "${tmp}/bin" "${tmp}/dev"
for n in 1 2 3 4 5; do : >"${tmp}/dev/disk0p${n}"; done
: >"${tmp}/dev/disk1p1"
cat >"${tmp}/fstab" <<'EOF'
PARTLABEL=boot /boot vfat defaults 0 2
PARTLABEL=data /data ext4 defaults 0 2
EOF
cat >"${tmp}/system.conf" <<'EOF'
[slot.rootfs.0]
device=/dev/disk/by-partlabel/rootfs_a
[slot.rootfs.1]
device=/dev/disk/by-partlabel/rootfs_b
EOF
cat >"${tmp}/bin/lsblk" <<'EOF'
#!/bin/bash
printf '%s\n' "$(<"${LSBLK_FIXTURE}")"
EOF
cat >"${tmp}/bin/findmnt" <<'EOF'
#!/bin/bash
case "${*: -1}" in
  /) printf '%s\n' "${TEST_DEV}/disk0p2" ;;
  /boot) printf '%s\n' "${TEST_DEV}/${BOOT_SOURCE:-disk0p1}" ;;
  /data) printf '%s\n' "${TEST_DEV}/disk0p4" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "${tmp}/bin/lsblk" "${tmp}/bin/findmnt"
export TEST_DEV="${tmp}/dev" LSBLK_FIXTURE="${tmp}/lsblk.txt"
export CERALIVE_PARTLABEL_FSTAB="${tmp}/fstab" CERALIVE_PARTLABEL_RAUC_CONF="${tmp}/system.conf"
export CERALIVE_PARTLABEL_LSBLK="${tmp}/bin/lsblk" CERALIVE_PARTLABEL_FINDMNT="${tmp}/bin/findmnt"
export CERALIVE_PARTLABEL_FAILURE="${tmp}/partlabel-guard.failed"
export CERALIVE_HEALTHCHECK_BOOT_ID_FILE="${tmp}/boot-id"
printf '%s\n' '00000000-0000-0000-0000-000000000001' >"${tmp}/boot-id"

inventory() {
  cat >"${LSBLK_FIXTURE}" <<EOF
PATH="${TEST_DEV}/disk0p1" PKNAME="disk0" PARTLABEL="boot" TYPE="part"
PATH="${TEST_DEV}/disk0p2" PKNAME="disk0" PARTLABEL="rootfs_a" TYPE="part"
PATH="${TEST_DEV}/disk0p3" PKNAME="disk0" PARTLABEL="rootfs_b" TYPE="part"
PATH="${TEST_DEV}/disk0p4" PKNAME="disk0" PARTLABEL="data" TYPE="part"
EOF
}
guard() { bash "${ROOT}/mkosi/runtime/ceralive-healthcheck.sh" --partlabel-guard; }
check_failure() {
  local needle="$1" out
  [[ -f "${CERALIVE_PARTLABEL_FAILURE}" ]] || { printf 'FAIL: missing guard marker\n' >&2; exit 1; }
  grep -Fq -- "${needle}" "${CERALIVE_PARTLABEL_FAILURE}" || {
    printf 'FAIL: expected %s, got %s\n' "${needle}" "$(<"${CERALIVE_PARTLABEL_FAILURE}")" >&2; exit 1;
  }
  out="$(CERALIVE_HEALTHCHECK_CONF="${tmp}/absent" CERALIVE_HEALTHCHECK_MARKER="${tmp}/marked" \
    bash "${ROOT}/mkosi/runtime/ceralive-healthcheck.sh" 2>&1)" && {
    printf 'FAIL: healthcheck accepted guard failure\n' >&2; exit 1;
  }
  [[ "${out}" == *"${needle}"* ]] || { printf 'FAIL: healthcheck did not report guard failure\n' >&2; exit 1; }
  [[ ! -e "${tmp}/marked" ]] || { printf 'FAIL: slot marked good\n' >&2; exit 1; }
  printf 'PASS: %s and mark-good refused\n' "${needle}"
}

inventory
guard
[[ ! -e "${CERALIVE_PARTLABEL_FAILURE}" ]] || { printf 'FAIL: clean disk marked unsafe\n' >&2; exit 1; }
printf 'PASS: same-disk mounts and unique labels\n'

printf 'PATH="%s/disk1p1" PKNAME="disk1" PARTLABEL="spare" TYPE="part"\n' "${TEST_DEV}" >>"${LSBLK_FIXTURE}"
BOOT_SOURCE=disk1p1 guard
check_failure 'cross-disk mount: / on disk0, /boot on disk1'
unset BOOT_SOURCE

inventory
printf 'PATH="%s/disk1p1" PKNAME="disk1" PARTLABEL="boot" TYPE="part"\n' "${TEST_DEV}" >>"${LSBLK_FIXTURE}"
guard
check_failure 'duplicate PARTLABEL=boot across disks disk0 disk1'

inventory
guard
[[ ! -e "${CERALIVE_PARTLABEL_FAILURE}" ]] || { printf 'FAIL: stale failure marker survived clean guard\n' >&2; exit 1; }
printf 'PASS: clean next run clears boot-scoped failure marker\n'

[[ "$(<"${ROOT}/mkosi/runtime/ceralive-partlabel-guard.service")" == *'Before=ceralive-healthcheck.service'* ]]
grep -Fq 'enable_service ceralive-partlabel-guard.service' "${ROOT}/mkosi/customize/postinst.d/services.sh"
printf 'PASS: unit ordering and installer enablement\n'

cat >"${tmp}/bin/sgdisk" <<'EOF'
#!/bin/bash
case "$2" in
  1) label=boot; start=32768 ;;
  2) label=rootfs_a; start=557056 ;;
  3) label=rootfs_b; start=8945664 ;;
  4) label=data; start=17334272 ;;
  *) exit 1 ;;
esac
printf "Partition name: '%s'\nFirst sector: %s\nPartition size: 8388608 sectors\n" "${label}" "${start}"
EOF
cat >"${tmp}/bin/dd" <<'EOF'
#!/bin/bash
for arg in "$@"; do
  case "${arg}" in of=*) output="${arg#of=}" ;; skip=*) skip="${arg#skip=}" ;; esac
done
printf '%s\n' "${skip}" >"${output}"
EOF
cat >"${tmp}/bin/debugfs" <<'EOF'
#!/bin/bash
if [[ "$2" == 'cat /etc/fstab' ]]; then
  if [[ "$(<"$3")" == 8945664 && -n "${PRE_BAD_B:-}" ]]; then
    printf 'PARTLABEL=wrong /boot vfat defaults 0 2\nPARTLABEL=data /data ext4 defaults 0 2\n'
  else
    printf 'PARTLABEL=boot /boot vfat defaults 0 2\nPARTLABEL=data /data ext4 defaults 0 2\n'
  fi
else
  printf '[slot.rootfs.0]\ndevice=/dev/disk/by-partlabel/rootfs_a\n[slot.rootfs.1]\ndevice=/dev/disk/by-partlabel/rootfs_b\n'
fi
EOF
chmod +x "${tmp}/bin/sgdisk" "${tmp}/bin/dd" "${tmp}/bin/debugfs"
: >"${tmp}/candidate.raw"
preflash() { PATH="${tmp}/bin:${PATH}" bash "${ROOT}/tests/preflash-verify.sh" --labels-only --image "${tmp}/candidate.raw"; }
preflash >/dev/null || { printf 'FAIL: matching GPT and baked labels refused\n' >&2; exit 1; }
printf 'PASS: preflash both rootfs slots match GPT\n'
out="$(PRE_BAD_B=1 preflash 2>&1)" && { printf 'FAIL: mismatched B fstab passed preflash\n' >&2; exit 1; }
[[ "${out}" == *'rootfs p3 boot expects wrong but GPT p1 is boot'* ]] || {
  printf 'FAIL: mismatched B fstab not diagnosed: %s\n' "${out}" >&2; exit 1;
}
printf 'PASS: preflash mismatched B fstab refused before write\n'
grep -Fq -- "--labels-only --image \"\${flash_image}\"" "${ROOT}/ci/verify-and-flash-candidate.sh"
printf 'PASS: flash tool calls label gate on verified private raw\n'
