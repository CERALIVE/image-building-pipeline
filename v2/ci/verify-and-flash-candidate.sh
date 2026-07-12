#!/usr/bin/env bash
set -euo pipefail

reset_ignored_cancellation_signals() {
  local ignored
  [[ -r "/proc/$$/status" ]] || return 0
  ignored="$(awk '$1 == "SigIgn:" { print $2 }' "/proc/$$/status")"
  [[ "${ignored}" =~ ^[0-9a-fA-F]{16}$ ]] || return 0
  if (( (16#${ignored} & 0x4002) != 0 )); then
    exec env --default-signal=INT --default-signal=TERM \
      "${BASH}" "${BASH_SOURCE[0]}" "$@"
  fi
}
reset_ignored_cancellation_signals "$@"

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

identity_dir="$(dirname -- "${identity_out}")"
[[ -d "${identity_dir}" && ! -L "${identity_out}" ]] || {
  printf 'identity output must be a non-symlink path in an existing directory: %s\n' "${identity_out}" >&2
  exit 1
}
rm -f -- "${identity_out}"

validate_identity_filename() {
  local field="$1" value="$2"
  [[ "${value}" =~ ^[A-Za-z0-9._+-]+$ ]] || {
    printf '%s identity filename contains unsupported characters\n' "${field}" >&2
    exit 1
  }
}

raw_file="$(basename -- "${image}")"
bundle_file="$(basename -- "${bundle}")"
validate_identity_filename raw_file "${raw_file}"
validate_identity_filename bundle_file "${bundle_file}"

scratch_root="${RUNNER_TEMP:-/tmp}"
[[ -d "${scratch_root}" && -w "${scratch_root}" && ! -L "${scratch_root}" ]] || {
  printf 'RUNNER_TEMP must be a writable non-symlink directory: %s\n' "${scratch_root}" >&2
  exit 1
}
verify_tmp="$(mktemp -d "${scratch_root}/ceralive-verify.XXXXXX")"
chmod 700 "${verify_tmp}"
flash_image="${verify_tmp}/candidate.raw"
readback_image="${verify_tmp}/readback.raw"
ld_output_file="${verify_tmp}/rkdeveloptool-ld.log"
ssh_known_hosts="${verify_tmp}/known_hosts"
identity_tmp=""
rkdeveloptool_pid=""
stop_rkdeveloptool() {
  local pid="${rkdeveloptool_pid}"
  rkdeveloptool_pid=""
  if [[ -n "${pid}" ]]; then
    kill -TERM "${pid}" >/dev/null 2>&1 || true
    wait "${pid}" >/dev/null 2>&1 || true
  fi
}
cleanup() {
  stop_rkdeveloptool
  [[ -z "${identity_tmp}" ]] || rm -f -- "${identity_tmp}"
  rm -rf -- "${verify_tmp}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

run_rkdeveloptool() {
  local status
  "${rkdeveloptool}" "$@" &
  rkdeveloptool_pid=$!
  if wait "${rkdeveloptool_pid}"; then
    status=0
  else
    status=$?
  fi
  rkdeveloptool_pid=""
  return "${status}"
}

cp --reflink=auto --sparse=always -- "${image}" "${flash_image}"
chmod 400 "${flash_image}"
actual_sha="$(sha256sum "${flash_image}" | cut -d' ' -f1)"
[[ "${actual_sha}" == "${expected_sha}" ]] || {
  printf 'candidate raw digest mismatch: expected %s, got %s\n' "${expected_sha}" "${actual_sha}" >&2
  exit 1
}
image_bytes="$(stat -c %s "${flash_image}")"
(( image_bytes > 0 && image_bytes % 512 == 0 )) || {
  printf 'candidate raw size must be a positive multiple of 512 bytes: %s\n' "${image_bytes}" >&2
  exit 1
}
image_sectors=$((image_bytes / 512))
install -m 600 /dev/null "${ssh_known_hosts}"

ssh_bin="${CERALIVE_SSH_BIN:-ssh}"
preflash="${CERALIVE_PREFLASH_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/preflash-verify.sh}"
ssh_user="${SSH_USER:-ceralive}"
ssh_port="${SSH_PORT:-22}"
flash_device="${CERALIVE_FLASH_DEVICE:-/dev/mmcblk0}"
rkdeveloptool="${CERALIVE_RKDEVELOPTOOL_BIN:-rkdeveloptool}"
power_helper="${CERALIVE_RK3588_POWER_HELPER:-}"
loader="${RK3588_LOADER:-}"
ssh_opts=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
  -o "UserKnownHostsFile=${ssh_known_hosts}" -o GlobalKnownHostsFile=/dev/null -p "${ssh_port}")
remote="${ssh_user}@${board_ip}"
media_node="$(basename -- "${flash_device}")"

target_bytes="$("${ssh_bin}" "${ssh_opts[@]}" "${remote}" "sudo blockdev --getsize64 '${flash_device}'")"
[[ "${target_bytes}" =~ ^[1-9][0-9]*$ ]]
media_cid="$("${ssh_bin}" "${ssh_opts[@]}" "${remote}" \
  "cat '/sys/class/block/${media_node}/device/cid'" | tr -d '[:space:]')"
[[ "${media_cid}" =~ ^[0-9a-fA-F]{32}$ ]] || {
  printf 'unable to read a valid pre-flash media CID for %s\n' "${flash_device}" >&2
  exit 1
}
media_cid="${media_cid,,}"
pre_flash_known_hosts_sha256="$(sha256sum "${ssh_known_hosts}" | cut -d' ' -f1)"
"${preflash}" --image "${flash_image}" --bundle "${bundle}" --board "${board}" \
  --keyring "${keyring}" --target-size-bytes "${target_bytes}"

[[ -n "${power_helper}" && -x "${power_helper}" ]] \
  || { printf 'CERALIVE_RK3588_POWER_HELPER must be an executable maskrom helper\n' >&2; exit 1; }
[[ -n "${loader}" && -s "${loader}" ]] \
  || { printf 'RK3588_LOADER must name the exact loader binary\n' >&2; exit 1; }
command -v "${rkdeveloptool}" >/dev/null 2>&1 \
  || { printf 'rkdeveloptool is required for safe whole-media flashing\n' >&2; exit 1; }

"${power_helper}" maskrom
disconnect_attempts="${CERALIVE_DISCONNECT_ATTEMPTS:-10}"
disconnect_delay="${CERALIVE_DISCONNECT_DELAY:-1}"
disconnected=0
for _ in $(seq 1 "${disconnect_attempts}"); do
  if ! "${ssh_bin}" "${ssh_opts[@]}" "${remote}" true >/dev/null 2>&1; then
    disconnected=1
    break
  fi
  sleep "${disconnect_delay}"
done
(( disconnected == 1 )) || {
  printf 'board remained reachable after maskrom transition\n' >&2
  exit 1
}

if ! run_rkdeveloptool ld >"${ld_output_file}" 2>&1; then
  printf 'rkdeveloptool could not enumerate the maskrom target\n%s\n' "$(<"${ld_output_file}")" >&2
  exit 1
fi
ld_output="$(<"${ld_output_file}")"
printf '%s\n' "${ld_output}"
mapfile -t usb_devices < <(grep 'DevNo=' <<<"${ld_output}" || true)
(( ${#usb_devices[@]} == 1 )) || {
  printf 'expected exactly one rkdeveloptool target, found %s\n' "${#usb_devices[@]}" >&2
  exit 1
}
usb_device_sha256="$(printf '%s\n' "${usb_devices[0]}" | sha256sum | cut -d' ' -f1)"
run_rkdeveloptool db "${loader}"
run_rkdeveloptool wl 0 "${flash_image}"
[[ "$(stat -c %s "${flash_image}")" == "${image_bytes}" ]] || {
  printf 'private candidate snapshot changed size while flashing\n' >&2
  exit 1
}
chmod 600 "${flash_image}"
rm -f -- "${flash_image}"

if ! run_rkdeveloptool rl 0 "${image_sectors}" "${readback_image}"; then
  printf 'failed to read back flashed candidate before reset\n' >&2
  exit 1
fi
[[ "$(stat -c %s "${readback_image}")" == "${image_bytes}" ]] || {
  printf 'flashed candidate readback size mismatch\n' >&2
  exit 1
}
readback_sha="$(sha256sum "${readback_image}" | cut -d' ' -f1)"
[[ "${readback_sha}" == "${expected_sha}" ]] || {
  printf 'pre-boot media readback digest mismatch: expected %s, got %s\n' \
    "${expected_sha}" "${readback_sha}" >&2
  exit 1
}
rm -f -- "${readback_image}"
: >"${ssh_known_hosts}"
run_rkdeveloptool rd

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
[[ -s "${ssh_known_hosts}" ]] || {
  printf 'SSH reconnect did not record the candidate host identity\n' >&2
  exit 1
}
post_boot_media_cid="$("${ssh_bin}" "${ssh_opts[@]}" "${remote}" \
  "cat '/sys/class/block/${media_node}/device/cid'" | tr -d '[:space:]')"
post_boot_media_cid="${post_boot_media_cid,,}"
[[ "${post_boot_media_cid}" == "${media_cid}" ]] || {
  printf 'reconnected media CID mismatch: expected %s, got %s\n' \
    "${media_cid}" "${post_boot_media_cid}" >&2
  exit 1
}
post_boot_known_hosts_sha256="$(sha256sum "${ssh_known_hosts}" | cut -d' ' -f1)"

identity_tmp="$(mktemp "${identity_dir}/.candidate-identity.XXXXXX")"
chmod 600 "${identity_tmp}"
cat >"${identity_tmp}" <<EOF
candidate_commit=${candidate_commit}
raw_file=${raw_file}
raw_size=${image_bytes}
raw_sha256=${expected_sha}
bundle_file=${bundle_file}
keyring_sha256=$(sha256sum "${keyring}" | cut -d' ' -f1)
identity_contract=pre-boot-whole-media-sha256
pre_boot_media_sha256=${readback_sha}
pre_boot_media_identity=verified
media_cid=${media_cid}
usb_device_sha256=${usb_device_sha256}
pre_flash_known_hosts_sha256=${pre_flash_known_hosts_sha256}
post_boot_known_hosts_sha256=${post_boot_known_hosts_sha256}
post_boot_reconnect=verified
flash_transport=maskrom-rkdeveloptool
EOF
mv -f -- "${identity_tmp}" "${identity_out}"
identity_tmp=""
