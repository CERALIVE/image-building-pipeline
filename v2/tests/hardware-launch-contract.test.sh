#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2="$(cd "${HERE}/.." && pwd)"
REPO="$(cd "${V2}/.." && pwd)"
CHIP_INFO="${V2}/mkosi/runtime/ceralive-rockchip-chip-info.sh"
BOOTSTRAP="${V2}/mkosi/runtime/ceralive-ci-uart-bootstrap.sh"
VERIFY="${V2}/ci/verify-and-flash-candidate.sh"
POSTINST="${V2}/mkosi/customize/postinst-lib.sh"
REALHW="${REPO}/.github/workflows/realhw-job.yml"
ACTIONLINT_CONFIG="${REPO}/.github/actionlint.yaml"
HARDWARE_DOC="${V2}/docs/hardware-gated-completion.md"
RUNNER_DOC="${V2}/ci/runner-setup.md"
RELEASE_DOC="${REPO}/docs/RELEASE-PROCESS.md"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

[[ -x "${CHIP_INFO}" ]] || {
  printf 'Rockchip chip-info helper is missing\n' >&2
  exit 1
}
printf '\x52\x4b\x35\x88\x91\xfe\x21\x41\x5a\x43\x39\x36\x00\x00\x00\x00extra' \
  >"${TMP}/nvmem"
chip_info="$(CERALIVE_ROCKCHIP_NVMEM_FILE="${TMP}/nvmem" "${CHIP_INFO}")"
[[ "${chip_info}" == 524b358891fe21415a43393600000000 ]]
printf '\x01\x02\x03' >"${TMP}/short-nvmem"
if CERALIVE_ROCKCHIP_NVMEM_FILE="${TMP}/short-nvmem" "${CHIP_INFO}" >/dev/null 2>&1; then
  printf 'short Rockchip NVMEM identity was accepted\n' >&2
  exit 1
fi

grep -Fq 'CERALIVE_CHIP_INFO_BIN' "${BOOTSTRAP}"
grep -Fq '/usr/local/sbin/ceralive-rockchip-chip-info' "${BOOTSTRAP}" "${VERIFY}"
grep -Fq 'ceralive-rockchip-chip-info.sh' "${POSTINST}"
if grep -Fq '/sys/module/rockchip_cpuinfo/parameters/id' "${BOOTSTRAP}" "${VERIFY}"; then
  printf 'nonexistent Rockchip module-parameter identity path is still wired\n' >&2
  exit 1
fi

realhw_job="$(awk '/^  realhw:/{found=1} found{print} /^    steps:/{exit}' "${REALHW}")"
grep -Fq 'environment: image-hardware' <<<"${realhw_job}"
grep -Fq "github.repository == 'CERALIVE/image-building-pipeline'" <<<"${realhw_job}"
grep -Fq "github.event_name == 'push'" <<<"${realhw_job}"
grep -Fq "refs/heads/release/" <<<"${realhw_job}"
grep -Fq "refs/tags/v" <<<"${realhw_job}"
grep -Fq 'CERALIVE/image-building-pipeline/.github/workflows/release.yml@' <<<"${realhw_job}"
grep -Fq 'runs-on: [self-hosted, ceralive-rk3588, rock-5b-plus]' <<<"${realhw_job}"
if grep -Eq 'ACCESS_DIR:.*runner\.temp' <<<"${realhw_job}"; then
  printf 'real-HW workflow uses runner context before a runner exists\n' >&2
  exit 1
fi
initialize_access_script="$(awk '
  $0 == "      - name: Initialize run-local access path" { found=1; next }
  found && $0 ~ /^[[:space:]]+run: \|/ { in_run=1; next }
  in_run && $0 ~ /^      - / { exit }
  in_run { sub(/^          /, ""); print }
' "${REALHW}")"
[[ -n "${initialize_access_script}" ]]
mkdir -p "${TMP}/runner temp"
RUNNER_TEMP="${TMP}/runner temp" GITHUB_RUN_ID=123 GITHUB_RUN_ATTEMPT=1 \
  GITHUB_ENV="${TMP}/github-env" bash -euo pipefail -c "${initialize_access_script}"
grep -Fxq "ACCESS_DIR=${TMP}/runner temp/ceralive-realhw-access-123-1" "${TMP}/github-env"
initialize_line="$(grep -n -m1 -F -- '- name: Initialize run-local access path' "${REALHW}" | cut -d: -f1)"
first_consumer_line="$(grep -n -m1 -F 'rm -rf -- "${ACCESS_DIR}"' "${REALHW}" | cut -d: -f1)"
(( initialize_line < first_consumer_line ))
if grep -Fq "release-*" "${REPO}/.github/workflows/release.yml"; then
  printf 'legacy broad release branch trigger is still enabled\n' >&2
  exit 1
fi
grep -Eq '^[[:space:]]+- rock-5b-plus$' "${ACTIONLINT_CONFIG}" || {
  printf 'actionlint does not allow the dedicated Rock 5B+ runner label\n' >&2
  exit 1
}

if grep -Fq 'rauc status mark-bad booted' "${HARDWARE_DOC}"; then
  printf 'hardware acceptance still permits an attended rollback substitute\n' >&2
  exit 1
fi
if grep -Fq 'aws s3 rm' "${RELEASE_DOC}"; then
  printf 'release rollback still permits deleting an immutable bundle pair\n' >&2
  exit 1
fi
grep -Fq 'never delete' "${RELEASE_DOC}"

if grep -Eq 'cat[[:space:]]+/dev/(ttyUSB|ttyACM)' "${RUNNER_DOC}" "${HARDWARE_DOC}"; then
  printf 'hardware guidance still permits a competing UART reader during the hardware gate\n' >&2
  exit 1
fi
grep -Fq '`uart-provision-ssh.sh` is the **exclusive owner' "${RUNNER_DOC}"
grep -Fq 'artifacts/first-boot-uart.log' "${RUNNER_DOC}"
grep -Fq 'Do not start `screen`, `minicom`, or a second background reader while the gate' \
  "${RUNNER_DOC}"
grep -Fq 'uart-provision-ssh.sh owns UART' "${HARDWARE_DOC}"
grep -Fq 'Do not start screen, minicom, or a second reader during the gate' \
  "${HARDWARE_DOC}"
grep -Fq 'artifacts/first-boot-uart.log' "${HARDWARE_DOC}"

printf 'hardware launch identity/access/documentation contract: PASS\n'
