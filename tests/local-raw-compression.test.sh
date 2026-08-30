#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"
STAGE="${PIPELINE_DIR}/lib/stages/assemble.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

out_dir="${TMP}/images"
ts="20260829T120000Z"
raw_artifact="${out_dir}/${ts}.raw"

cat >"${TMP}/assemble-disk" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    *) shift ;;
  esac
done
truncate -s 8M "${output}"
printf 'CERALIVE-LOCAL-RAW\n' | dd of="${output}" bs=1 seek=1048576 conv=notrunc status=none
EOF
cat >"${TMP}/build-bundle" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'bundle\n' >"${BUNDLE_OUT_DIR}/${BUNDLE_TS}.raucb"
EOF
chmod +x "${TMP}/assemble-disk" "${TMP}/build-bundle"

log_info() { :; }
log_success() { :; }
die() { printf '%s\n' "$*" >&2; exit 1; }

board='fixture-board'
variant='default'
RAUC_BOOTLOADER_ADAPTER='custom'
INSTALL_BOOT_BSP=1
SINGLE_SLOT_FALLBACK=false
BOARD_ID='fixture-board'
COMPATIBLE_STRING='ceralive-fixture-board'
CERALIVE_RAUC_PKI_DIR="${TMP}/pki"
bsp_dir="${TMP}/bsp"
rootfs_tree="${TMP}/rootfs"
artifact="${TMP}/rootfs.tar"
build_version='fixture'
ASSEMBLE_DISK_SH="${TMP}/assemble-disk"
BUILD_BUNDLE_SH="${TMP}/build-bundle"
SEAL_RAW_CANDIDATE_SH="${PIPELINE_DIR}/ci/seal-raw-candidate.sh"
export board variant RAUC_BOOTLOADER_ADAPTER INSTALL_BOOT_BSP SINGLE_SLOT_FALLBACK
export BOARD_ID COMPATIBLE_STRING CERALIVE_RAUC_PKI_DIR bsp_dir rootfs_tree
export artifact build_version ASSEMBLE_DISK_SH BUILD_BUNDLE_SH SEAL_RAW_CANDIDATE_SH
mkdir -p "${out_dir}" "${bsp_dir}" "${rootfs_tree}"

# shellcheck disable=SC1090 # STAGE resolves to the repository's shipped stage module.
source "${STAGE}"
stage_assemble

raw_sha="$(sha256sum "${raw_artifact}" | cut -d' ' -f1)"
[[ -s "${raw_artifact}" ]]
[[ -s "${raw_artifact}.xz" ]]
[[ -s "${raw_artifact}.xz.sha256" ]]
[[ -s "${raw_artifact}.sha256" ]]
[[ "$(awk 'NR == 1 { print $1 }' "${raw_artifact}.sha256")" == "${raw_sha}" ]]
( cd "${out_dir}" && sha256sum -c "$(basename "${raw_artifact}").xz.sha256" )
[[ "$(xz -dc -- "${raw_artifact}.xz" | sha256sum | cut -d' ' -f1)" == "${raw_sha}" ]]
[[ -s "${out_dir}/${ts}.raucb" ]]

printf 'local raw compression wiring: PASS\n'
