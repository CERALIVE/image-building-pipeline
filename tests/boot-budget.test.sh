#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"
CHECK="${PIPELINE_DIR}/ci/check-boot-budget.sh"
QEMU_CHECK="${PIPELINE_DIR}/tests/qemu-x86.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

[[ -x "${CHECK}" ]] || { printf 'FAIL boot-budget checker is not executable: %s\n' "${CHECK}" >&2; exit 1; }

cat >"${TMP}/passing.tsv" <<'EOF'
schema_version	board	artifact	slot	peripherals	uplink	kernel_ms	userspace_ms
1	rock-5b-plus	candidate-sha256:A	A	modem-farm-v1	offline	3500	9800
1	rock-5b-plus	candidate-sha256:A	A	modem-farm-v1	offline	3400	9400
1	rock-5b-plus	candidate-sha256:A	A	modem-farm-v1	offline	3600	10100
EOF

run_check() {
  "${CHECK}" \
    --samples "$1" \
    --board rock-5b-plus \
    --max-userspace-ms 10000 \
    --basis 'three matched synthetic cold-boot fixtures; parser contract only' 2>&1
}

output="$(run_check "${TMP}/passing.tsv")"
[[ "${output}" == *'userspace_ms median=9800 range=9400-10100 budget=10000'* ]]
[[ "${output}" == *'boot budget: PASS'* ]]
printf 'PASS matched three-boot fixture reports median + range and passes its threshold\n'

cat >"${TMP}/slow.tsv" <<'EOF'
schema_version	board	artifact	slot	peripherals	uplink	kernel_ms	userspace_ms
1	rock-5b-plus	candidate-sha256:A	A	modem-farm-v1	offline	3500	10100
1	rock-5b-plus	candidate-sha256:A	A	modem-farm-v1	offline	3400	10300
1	rock-5b-plus	candidate-sha256:A	A	modem-farm-v1	offline	3600	10500
EOF
if output="$(run_check "${TMP}/slow.tsv")"; then
  printf 'FAIL slowed fixture passed the board budget\n%s\n' "${output}" >&2
  exit 1
fi
[[ "${output}" == *'boot budget exceeded'* ]]
printf 'PASS slowed three-boot fixture is rejected\n'

cat >"${TMP}/mismatched.tsv" <<'EOF'
schema_version	board	artifact	slot	peripherals	uplink	kernel_ms	userspace_ms
1	rock-5b-plus	candidate-sha256:A	A	modem-farm-v1	offline	3500	9000
1	rock-5b-plus	candidate-sha256:A	A	modem-farm-v1	ethernet-live	3400	9100
1	rock-5b-plus	candidate-sha256:A	A	modem-farm-v1	offline	3600	9200
EOF
if output="$(run_check "${TMP}/mismatched.tsv")"; then
  printf 'FAIL unmatched uplink states were accepted\n%s\n' "${output}" >&2
  exit 1
fi
[[ "${output}" == *'uplink state changed'* ]]
printf 'PASS unmatched artifact/slot/peripheral/uplink controls are rejected\n'

cat >"${TMP}/too-few.tsv" <<'EOF'
schema_version	board	artifact	slot	peripherals	uplink	kernel_ms	userspace_ms
1	rock-5b-plus	candidate-sha256:A	A	modem-farm-v1	offline	3500	9000
1	rock-5b-plus	candidate-sha256:A	A	modem-farm-v1	offline	3400	9100
EOF
if output="$(run_check "${TMP}/too-few.tsv")"; then
  printf 'FAIL two-boot fixture passed the three-boot floor\n%s\n' "${output}" >&2
  exit 1
fi
[[ "${output}" == *'need at least 3'* ]]
printf 'PASS fewer than three cold boots are rejected\n'

if output="$("${CHECK}" --samples "${TMP}/passing.tsv" --board rock-5b-plus --max-userspace-ms 10000 2>&1)"; then
  printf 'FAIL threshold without a measurement basis was accepted\n%s\n' "${output}" >&2
  exit 1
fi
[[ "${output}" == *'--basis is required'* ]]
printf 'PASS an unbased threshold is rejected\n'

output="$(CERALIVE_QEMU_SELFTEST=1 "${QEMU_CHECK}" 2>&1)"
[[ "${output}" == *'auxiliary x86 timing parser guard'* ]]
[[ "${output}" == *'engine correctly FAILS a slowed transcript above the auxiliary x86 budget'* ]]
[[ "${output}" == *'QEMU x86 VALIDATION OK'* ]]
printf 'PASS x86 QEMU assertion engine labels timing as auxiliary and rejects its slowed fixture\n'

printf 'boot-budget regression contract: PASS\n'
