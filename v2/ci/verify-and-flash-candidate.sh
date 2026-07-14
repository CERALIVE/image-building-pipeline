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

image="" bundle="" keyring="" loader="" board="" board_ip="" candidate_commit=""
expected_sha="" loader_sha="" serial_dev="" uart_log="" authorized_key=""
access_id="" access_expires="" host_epoch="" authorized_line_out="" identity_out=""
ssh_identity="" challenge=""
ssh_known_hosts=""
expected_maskrom_id_sha="" uart_signing_key=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) image="${2:-}"; shift 2 ;;
    --bundle) bundle="${2:-}"; shift 2 ;;
    --keyring) keyring="${2:-}"; shift 2 ;;
    --loader) loader="${2:-}"; shift 2 ;;
    --loader-sha256) loader_sha="${2:-}"; shift 2 ;;
    --board) board="${2:-}"; shift 2 ;;
    --board-ip) board_ip="${2:-}"; shift 2 ;;
    --candidate-commit) candidate_commit="${2:-}"; shift 2 ;;
    --image-sha256) expected_sha="${2:-}"; shift 2 ;;
    --serial-dev) serial_dev="${2:-}"; shift 2 ;;
    --uart-log) uart_log="${2:-}"; shift 2 ;;
    --authorized-key) authorized_key="${2:-}"; shift 2 ;;
    --access-id) access_id="${2:-}"; shift 2 ;;
    --access-expires) access_expires="${2:-}"; shift 2 ;;
    --host-epoch) host_epoch="${2:-}"; shift 2 ;;
    --ssh-identity) ssh_identity="${2:-}"; shift 2 ;;
    --challenge) challenge="${2:-}"; shift 2 ;;
    --expected-maskrom-id-sha256) expected_maskrom_id_sha="${2:-}"; shift 2 ;;
    --uart-signing-key) uart_signing_key="${2:-}"; shift 2 ;;
    --known-hosts) ssh_known_hosts="${2:-}"; shift 2 ;;
    --authorized-line-out) authorized_line_out="${2:-}"; shift 2 ;;
    --identity-out) identity_out="${2:-}"; shift 2 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

for value in image bundle keyring loader board board_ip candidate_commit expected_sha \
  loader_sha serial_dev uart_log authorized_key access_id access_expires host_epoch \
  ssh_identity challenge expected_maskrom_id_sha uart_signing_key ssh_known_hosts \
  authorized_line_out identity_out; do
  [[ -n "${!value}" ]] || { printf '%s is required\n' "$value" >&2; exit 2; }
done
[[ -f "${image}" && -f "${bundle}" && -f "${keyring}" && -f "${loader}" ]]
[[ -e "${serial_dev}" && -r "${serial_dev}" && -w "${serial_dev}" && \
   -r "${authorized_key}" && -r "${ssh_identity}" ]]
[[ -f "${uart_signing_key}" && ! -L "${uart_signing_key}" && \
   "$(stat -c %a "${uart_signing_key}")" == 600 ]]
[[ "${expected_sha}" =~ ^[0-9a-f]{64}$ && "${loader_sha}" =~ ^[0-9a-f]{64}$ && \
   "${expected_maskrom_id_sha}" =~ ^[0-9a-f]{64}$ ]]
[[ "${candidate_commit}" =~ ^[0-9a-f]{40}$ && "${challenge}" =~ ^[0-9a-f]{64}$ ]]
[[ "${access_id}" =~ ^[A-Za-z0-9._-]{1,80}$ ]]
[[ "${access_expires}" =~ ^[0-9]{14}Z$ && "${host_epoch}" =~ ^[0-9]{10}$ ]]
[[ "${board}" == rock-5b-plus ]] || { printf 'hardware gate supports only rock-5b-plus\n' >&2; exit 1; }
[[ "${SSH_USER:-root}" == root ]] || { printf 'UART bootstrap provisions only root SSH access\n' >&2; exit 1; }

identity_dir="$(dirname -- "${identity_out}")"
[[ -d "${identity_dir}" && ! -L "${identity_out}" && \
   -d "$(dirname -- "${ssh_known_hosts}")" && ! -L "${ssh_known_hosts}" ]] || {
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
loader_file="$(basename -- "${loader}")"
validate_identity_filename raw_file "${raw_file}"
validate_identity_filename bundle_file "${bundle_file}"
validate_identity_filename loader_file "${loader_file}"

scratch_root="${RUNNER_TEMP:-/tmp}"
[[ -d "${scratch_root}" && -w "${scratch_root}" && ! -L "${scratch_root}" ]] || {
  printf 'RUNNER_TEMP must be a writable non-symlink directory: %s\n' "${scratch_root}" >&2
  exit 1
}
verify_tmp="$(mktemp -d "${scratch_root}/ceralive-verify.XXXXXX")"
chmod 700 "${verify_tmp}"
flash_image="${verify_tmp}/candidate.raw"
flash_loader="${verify_tmp}/loader.bin"
readback_image="${verify_tmp}/readback.raw"
ld_output_file="${verify_tmp}/rkdeveloptool-ld.log"
rfi_output_file="${verify_tmp}/rkdeveloptool-rfi.log"
rid_output_file="${verify_tmp}/rkdeveloptool-rid.log"
rci_output_file="${verify_tmp}/rkdeveloptool-rci.log"
uart_ready_file="${verify_tmp}/uart-ready"
uart_start_file="${verify_tmp}/uart-start"
identity_tmp=""
rkdeveloptool_pid=""
uart_pid=""
stop_rkdeveloptool() {
  local pid="${rkdeveloptool_pid}"
  rkdeveloptool_pid=""
  if [[ -n "${pid}" ]]; then
    kill -TERM "${pid}" >/dev/null 2>&1 || true
    wait "${pid}" >/dev/null 2>&1 || true
  fi
}
stop_uart() {
  local pid="${uart_pid}"
  uart_pid=""
  if [[ -n "${pid}" ]]; then
    kill -TERM "${pid}" >/dev/null 2>&1 || true
    wait "${pid}" >/dev/null 2>&1 || true
  fi
}
cleanup() {
  stop_rkdeveloptool
  stop_uart
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
cp -- "${loader}" "${flash_loader}"
chmod 400 "${flash_loader}"
actual_loader_sha="$(sha256sum "${flash_loader}" | cut -d' ' -f1)"
[[ "${actual_loader_sha}" == "${loader_sha}" ]] || {
  printf 'RK3588 loader digest mismatch: expected %s, got %s\n' \
    "${loader_sha}" "${actual_loader_sha}" >&2
  exit 1
}
install -m 600 /dev/null "${ssh_known_hosts}"

ssh_bin="${CERALIVE_SSH_BIN:-ssh}"
preflash="${CERALIVE_PREFLASH_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/preflash-verify.sh}"
ssh_user="${SSH_USER:-root}"
ssh_port="${SSH_PORT:-22}"
flash_device="${CERALIVE_FLASH_DEVICE:-/dev/mmcblk0}"
rkdeveloptool="${CERALIVE_RKDEVELOPTOOL_BIN:-rkdeveloptool}"
uart_helper="${CERALIVE_UART_HELPER_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/uart-provision-ssh.sh}"
uart_public_key="${CERALIVE_UART_PUBLIC_KEY_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../mkosi/runtime" && pwd)/ceralive-ci-uart-bootstrap-public.pem}"
ssh_opts=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
  -o "UserKnownHostsFile=${ssh_known_hosts}" -o GlobalKnownHostsFile=/dev/null \
  -o IdentitiesOnly=yes -i "${ssh_identity}" -p "${ssh_port}")
remote="${ssh_user}@${board_ip}"
media_node="$(basename -- "${flash_device}")"

command -v "${rkdeveloptool}" >/dev/null 2>&1 \
  || { printf 'rkdeveloptool is required for safe whole-media flashing\n' >&2; exit 1; }
[[ -x "${uart_helper}" ]] || { printf 'UART provisioning helper is not executable\n' >&2; exit 1; }
[[ -f "${uart_public_key}" && ! -L "${uart_public_key}" ]] || {
  printf 'baked UART bootstrap public key is unavailable\n' >&2
  exit 1
}
openssl pkey -in "${uart_signing_key}" -pubout -outform DER \
  -out "${verify_tmp}/runner-uart-public.der" >/dev/null 2>&1 || {
  printf 'runner UART signing key is not a usable Ed25519 private key\n' >&2
  exit 1
}
openssl pkey -pubin -in "${uart_public_key}" -pubout -outform DER \
  -out "${verify_tmp}/image-uart-public.der" >/dev/null 2>&1 || {
  printf 'image UART bootstrap public key is invalid\n' >&2
  exit 1
}
cmp -s "${verify_tmp}/runner-uart-public.der" "${verify_tmp}/image-uart-public.der" || {
  printf 'runner UART signing key does not match the public key baked into the candidate\n' >&2
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
[[ "${usb_devices[0]}" =~ (^|[[:space:]])(Mode=)?Maskrom($|[[:space:]]) ]] || {
  printf 'Rockchip target is not in Maskrom mode\n' >&2
  exit 1
}
[[ "${usb_devices[0]}" =~ Vid=0x2207,Pid=0x350b ]] || {
  printf 'Maskrom target is not an RK3588 device\n' >&2
  exit 1
}
maskrom_identity="$(sed -E \
  's/^DevNo=[0-9]+[[:space:]]+//; s/[[:space:]]+/ /g; s/[[:space:]]+$//' \
  <<<"${usb_devices[0]}")"
[[ "${maskrom_identity}" =~ ^Vid=0x2207,Pid=0x350b,LocationID=[0-9]+[[:space:]]+Maskrom$ ]]
usb_device_sha256="$(printf '%s' "${maskrom_identity}" | sha256sum | cut -d' ' -f1)"
[[ "${usb_device_sha256}" == "${expected_maskrom_id_sha}" ]] || {
  printf 'Maskrom target is not the approved USB fixture\n' >&2
  exit 1
}
run_rkdeveloptool db "${flash_loader}"
run_rkdeveloptool rfi >"${rfi_output_file}"
mapfile -t flash_sector_values < <(
  sed -nE 's/.*Flash Size:[[:space:]]*([0-9]+)[[:space:]]+Sectors.*/\1/p' "${rfi_output_file}"
)
(( ${#flash_sector_values[@]} == 1 )) || {
  printf 'rkdeveloptool did not report exactly one flash capacity\n' >&2
  exit 1
}
target_sectors="${flash_sector_values[0]}"
[[ "${target_sectors}" =~ ^[1-9][0-9]*$ ]]
(( image_sectors <= target_sectors )) || {
  printf 'candidate requires %s sectors but target reports %s\n' \
    "${image_sectors}" "${target_sectors}" >&2
  exit 1
}
target_bytes=$((target_sectors * 512))
run_rkdeveloptool rid >"${rid_output_file}"
flash_id_sha256="$(sha256sum "${rid_output_file}" | cut -d' ' -f1)"
run_rkdeveloptool rci >"${rci_output_file}"
chip_info_line="$(grep -E '^Chip Info:([[:space:]]+[0-9A-Fa-f]{1,2}){16}[[:space:]]*$' "${rci_output_file}")" || {
  printf 'rkdeveloptool did not report one 16-byte chip identity\n' >&2
  exit 1
}
read -r -a chip_info_tokens <<<"${chip_info_line#Chip Info:}"
(( ${#chip_info_tokens[@]} == 16 ))
usb_soc_id=""
for token in "${chip_info_tokens[@]}"; do
  printf -v octet '%02x' "0x${token}"
  usb_soc_id+="${octet}"
done
[[ "${usb_soc_id}" =~ ^[0-9a-f]{32}$ ]]
soc_id_sha256="$(printf '%s' "${usb_soc_id}" | sha256sum | cut -d' ' -f1)"
"${preflash}" --image "${flash_image}" --bundle "${bundle}" --board "${board}" \
  --keyring "${keyring}" --target-size-bytes "${target_bytes}"
"${uart_helper}" --serial-dev "${serial_dev}" --authorized-key "${authorized_key}" \
  --access-id "${access_id}" --expires "${access_expires}" --host-epoch "${host_epoch}" \
  --challenge "${challenge}" --candidate-commit "${candidate_commit}" \
  --soc-id "${usb_soc_id}" --signing-key "${uart_signing_key}" \
  --start-signal "${uart_start_file}" \
  --uart-log "${uart_log}" --authorized-line-out "${authorized_line_out}" \
  --ready-out "${uart_ready_file}" &
uart_pid=$!
for _ in $(seq 1 250); do
  [[ -e "${uart_ready_file}" ]] && break
  kill -0 "${uart_pid}" 2>/dev/null || break
  sleep 0.02
done
[[ -e "${uart_ready_file}" ]] || {
  wait "${uart_pid}" 2>/dev/null || true
  uart_pid=""
  printf 'UART preflight could not obtain read/write access and an exclusive lock\n' >&2
  exit 1
}
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
: >"${uart_start_file}"
run_rkdeveloptool rd
set +e
wait "${uart_pid}"
uart_status=$?
set -e
if (( uart_status != 0 )); then
  uart_pid=""
  printf 'UART first-boot provisioning failed with status %s\n' "${uart_status}" >&2
  exit 1
fi
uart_pid=""

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
[[ "${post_boot_media_cid}" =~ ^[0-9a-f]{32}$ ]] || {
  printf 'reconnected board did not report a valid media CID\n' >&2
  exit 1
}
boot_root_parent="$("${ssh_bin}" "${ssh_opts[@]}" "${remote}" \
  "root_source=\$(findmnt -n -o SOURCE /); root_device=\$(readlink -f -- \"\${root_source}\"); lsblk -ndo PKNAME \"\${root_device}\"" \
  | tr -d '[:space:]')"
[[ "${boot_root_parent}" == "${media_node}" ]] || {
  printf 'running root filesystem is not on the flashed eMMC device\n' >&2
  exit 1
}
post_boot_soc_id="$("${ssh_bin}" "${ssh_opts[@]}" "${remote}" \
  "/usr/local/sbin/ceralive-rockchip-chip-info" | tr -d '[:space:]')"
post_boot_soc_id="${post_boot_soc_id,,}"
[[ "${post_boot_soc_id}" =~ ^[0-9a-f]{32}$ ]] || {
  printf 'reconnected board did not report a valid Rockchip SoC identity\n' >&2
  exit 1
}
[[ "${post_boot_soc_id}" == "${usb_soc_id}" ]] || {
  printf 'USB-flashed SoC identity does not match the UART/SSH endpoint\n' >&2
  exit 1
}
marker="$("${ssh_bin}" "${ssh_opts[@]}" "${remote}" \
  "cat '/data/ceralive/ssh/ci-access/${access_id}'")"
[[ "${marker}" == $'challenge='"${challenge}"$'\ncandidate_commit='"${candidate_commit}"$'\nsoc_id='"${usb_soc_id}" ]] || {
  printf 'post-boot endpoint did not present the UART-bound candidate challenge\n' >&2
  exit 1
}
post_boot_known_hosts_sha256="$(sha256sum "${ssh_known_hosts}" | cut -d' ' -f1)"
uart_log_sha256="$(sha256sum "${uart_log}" | cut -d' ' -f1)"

identity_tmp="$(mktemp "${identity_dir}/.candidate-identity.XXXXXX")"
chmod 600 "${identity_tmp}"
cat >"${identity_tmp}" <<EOF
candidate_commit=${candidate_commit}
raw_file=${raw_file}
raw_size=${image_bytes}
raw_sha256=${expected_sha}
bundle_file=${bundle_file}
keyring_sha256=$(sha256sum "${keyring}" | cut -d' ' -f1)
loader_file=${loader_file}
loader_sha256=${loader_sha}
identity_contract=pre-boot-whole-media-sha256
pre_boot_media_sha256=${readback_sha}
pre_boot_media_identity=verified
target_capacity_sectors=${target_sectors}
flash_id_sha256=${flash_id_sha256}
soc_id_sha256=${soc_id_sha256}
media_cid=${post_boot_media_cid}
boot_root_parent=${boot_root_parent}
usb_device_sha256=${usb_device_sha256}
bootstrap_challenge_sha256=$(printf '%s' "${challenge}" | sha256sum | cut -d' ' -f1)
post_boot_known_hosts_sha256=${post_boot_known_hosts_sha256}
post_boot_reconnect=verified
uart_log_sha256=${uart_log_sha256}
ephemeral_ssh_access=${access_id}
flash_transport=maskrom-rkdeveloptool
EOF
mv -f -- "${identity_tmp}" "${identity_out}"
identity_tmp=""
