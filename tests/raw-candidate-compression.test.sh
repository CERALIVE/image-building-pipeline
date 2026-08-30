#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"
SEALER="${PIPELINE_DIR}/ci/seal-raw-candidate.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

raw="${TMP}/20260829T120000Z.raw"
candidate="${TMP}/candidate"
roundtrip="${TMP}/roundtrip.raw"
log="${TMP}/seal.log"

truncate -s 64M "${raw}"
printf 'CERALIVE-RAW-CANDIDATE\n' | dd of="${raw}" bs=1 seek=1048576 conv=notrunc status=none
raw_sha="$(sha256sum "${raw}" | cut -d' ' -f1)"

"${SEALER}" --raw "${raw}" --candidate-dir "${candidate}" >"${log}"

compressed="${candidate}/$(basename "${raw}").xz"
compressed_sidecar="${compressed}.sha256"

[[ -f "${raw}" ]]
[[ ! -e "${candidate}/$(basename "${raw}")" ]]
[[ -s "${compressed}" ]]
[[ -s "${candidate}/raw.sha256" ]]
[[ -s "${compressed_sidecar}" ]]
[[ "$(awk 'NR == 1 { print $1 }' "${candidate}/raw.sha256")" == "${raw_sha}" ]]
( cd "${candidate}" && sha256sum -c "$(basename "${compressed_sidecar}")" )
xz -t "${compressed}"
xz -dc "${compressed}" >"${roundtrip}"
cmp -s "${raw}" "${roundtrip}"

local_dir="${TMP}/local"
local_raw_sidecar="${local_dir}/$(basename "${raw}").sha256"
"${SEALER}" --raw "${raw}" --candidate-dir "${local_dir}" --raw-sha256 "${local_raw_sidecar}"
[[ -s "${local_raw_sidecar}" ]]
[[ ! -e "${local_dir}/raw.sha256" ]]
[[ "$(awk 'NR == 1 { print $1 }' "${local_raw_sidecar}")" == "${raw_sha}" ]]
( cd "${local_dir}" && sha256sum -c "$(basename "${raw}").xz.sha256" )

grep -Fq 'xz level=6 threads=0' "${log}"
grep -Eq 'raw_bytes=[0-9]+ compressed_bytes=[0-9]+ elapsed_seconds=[0-9]+' "${log}"
if grep -Fq 'CERALIVE_RAW_XZ_LEVEL' "${SEALER}" \
  || grep -Fq 'CERALIVE_RAW_XZ_THREADS' "${SEALER}"; then
  printf 'release compression settings must not be environment-overridable\n' >&2
  exit 1
fi

printf 'raw candidate compression contract: PASS\n'
