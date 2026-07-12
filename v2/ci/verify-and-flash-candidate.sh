#!/usr/bin/env bash
set -euo pipefail

image="" bundle="" keyring="" board="" board_ip="" candidate_commit=""
expected_sha="" identity_out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) image="${2:-}"; shift 2 ;;
    --bundle) bundle="${2:-}"; shift 2 ;;
    --keyring) keyring="${2:-}"; shift 2 ;;
    --board) board="${2:-}"; shift 2 ;;
    --board-ip) board_ip="${2:-}"; shift 2 ;;
    --candidate-commit) candidate_commit="${2:-}"; shift 2 ;;
    --image-sha256) expected_sha="${2:-}"; shift 2 ;;
    --identity-out) identity_out="${2:-}"; shift 2 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

for value in image bundle keyring board board_ip candidate_commit expected_sha identity_out; do
  [[ -n "${!value}" ]] || { printf '%s is required\n' "$value" >&2; exit 2; }
done
[[ -f "${image}" && -f "${bundle}" && -f "${keyring}" ]]
[[ "${expected_sha}" =~ ^[0-9a-f]{64}$ ]]
[[ "${candidate_commit}" =~ ^[0-9a-f]{7,40}$ ]]

actual_sha="$(sha256sum "${image}" | cut -d' ' -f1)"
[[ "${actual_sha}" == "${expected_sha}" ]] || {
  printf 'candidate raw digest mismatch: expected %s, got %s\n' "${expected_sha}" "${actual_sha}" >&2
  exit 1
}

ssh_bin="${CERALIVE_SSH_BIN:-ssh}"
preflash="${CERALIVE_PREFLASH_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/preflash-verify.sh}"
ssh_user="${SSH_USER:-ceralive}"
ssh_port="${SSH_PORT:-22}"
flash_device="${CERALIVE_FLASH_DEVICE:-/dev/mmcblk0}"
rkdeveloptool="${CERALIVE_RKDEVELOPTOOL_BIN:-rkdeveloptool}"
power_helper="${CERALIVE_RK3588_POWER_HELPER:-}"
loader="${RK3588_LOADER:-}"
ssh_opts=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -p "${ssh_port}")
remote="${ssh_user}@${board_ip}"

target_bytes="$("${ssh_bin}" "${ssh_opts[@]}" "${remote}" "sudo blockdev --getsize64 '${flash_device}'")"
[[ "${target_bytes}" =~ ^[1-9][0-9]*$ ]]
"${preflash}" --image "${image}" --bundle "${bundle}" --board "${board}" \
  --keyring "${keyring}" --target-size-bytes "${target_bytes}"

[[ -n "${power_helper}" && -x "${power_helper}" ]] \
  || { printf 'CERALIVE_RK3588_POWER_HELPER must be an executable maskrom helper\n' >&2; exit 1; }
[[ -n "${loader}" && -s "${loader}" ]] \
  || { printf 'RK3588_LOADER must name the exact loader binary\n' >&2; exit 1; }
command -v "${rkdeveloptool}" >/dev/null 2>&1 \
  || { printf 'rkdeveloptool is required for safe whole-media flashing\n' >&2; exit 1; }
"${power_helper}" maskrom
"${rkdeveloptool}" ld
"${rkdeveloptool}" db "${loader}"
"${rkdeveloptool}" wl 0 "${image}"
"${rkdeveloptool}" rd

attempts="${CERALIVE_RECONNECT_ATTEMPTS:-18}"
delay="${CERALIVE_RECONNECT_DELAY:-5}"
reconnected=0
for _ in $(seq 1 "${attempts}"); do
  sleep "${delay}"
  if "${ssh_bin}" "${ssh_opts[@]}" "${remote}" true >/dev/null 2>&1; then
    reconnected=1
    break
  fi
done
(( reconnected == 1 )) || { printf 'board did not reconnect after %s attempts\n' "${attempts}" >&2; exit 1; }

image_bytes="$(stat -c %s "${image}")"
remote_sha="$("${ssh_bin}" "${ssh_opts[@]}" "${remote}" \
  "sudo head -c '${image_bytes}' '${flash_device}' | sha256sum" | awk '{print $1}')"
[[ "${remote_sha}" == "${expected_sha}" ]] || {
  printf 'post-flash media digest mismatch: expected %s, got %s\n' "${expected_sha}" "${remote_sha}" >&2
  exit 1
}

cat >"${identity_out}" <<EOF
candidate_commit=${candidate_commit}
raw_file=$(basename "${image}")
raw_size=${image_bytes}
raw_sha256=${expected_sha}
bundle_file=$(basename "${bundle}")
keyring_sha256=$(sha256sum "${keyring}" | cut -d' ' -f1)
post_flash_identity=verified
flash_transport=maskrom-rkdeveloptool
EOF
