#!/usr/bin/env bash
set -euo pipefail

serial_dev="" authorized_key="" access_id="" expires="" host_epoch=""
challenge="" candidate_commit="" uart_log="" authorized_line_out="" ready_out=""
soc_id="" signing_key="" start_signal=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --serial-dev) serial_dev="${2:-}"; shift 2 ;;
    --authorized-key) authorized_key="${2:-}"; shift 2 ;;
    --access-id) access_id="${2:-}"; shift 2 ;;
    --expires) expires="${2:-}"; shift 2 ;;
    --host-epoch) host_epoch="${2:-}"; shift 2 ;;
    --challenge) challenge="${2:-}"; shift 2 ;;
    --candidate-commit) candidate_commit="${2:-}"; shift 2 ;;
    --soc-id) soc_id="${2:-}"; shift 2 ;;
    --signing-key) signing_key="${2:-}"; shift 2 ;;
    --start-signal) start_signal="${2:-}"; shift 2 ;;
    --uart-log) uart_log="${2:-}"; shift 2 ;;
    --authorized-line-out) authorized_line_out="${2:-}"; shift 2 ;;
    --ready-out) ready_out="${2:-}"; shift 2 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
for value in serial_dev authorized_key access_id expires host_epoch challenge candidate_commit \
  soc_id signing_key start_signal uart_log authorized_line_out ready_out; do
  [[ -n "${!value}" ]] || { printf '%s is required\n' "${value}" >&2; exit 2; }
done
[[ -e "${serial_dev}" && -r "${authorized_key}" ]]
[[ "${access_id}" =~ ^[A-Za-z0-9._-]{1,80}$ ]]
[[ "${expires}" =~ ^[0-9]{14}Z$ && "${host_epoch}" =~ ^[0-9]{10}$ ]]
[[ "${challenge}" =~ ^[0-9a-f]{64}$ && "${candidate_commit}" =~ ^[0-9a-f]{40}$ ]]
[[ "${soc_id}" =~ ^[0-9a-f]{32}$ ]]
[[ -f "${signing_key}" && ! -L "${signing_key}" && "$(stat -c %a "${signing_key}")" == 600 ]]
for output in "${uart_log}" "${authorized_line_out}" "${ready_out}"; do
  [[ -d "$(dirname -- "${output}")" && ! -L "${output}" ]] || {
    printf 'output must be a non-symlink path in an existing directory: %s\n' "${output}" >&2
    exit 1
  }
done

read -r key_type key_body _ <"${authorized_key}"
[[ "${key_type}" == ssh-ed25519 && "${key_body}" =~ ^[A-Za-z0-9+/=]+$ ]]
authorized_line="restrict,expiry-time=\"${expires}\" ${key_type} ${key_body} ceralive-ci-${access_id}"
printf '%s\n' "${authorized_line}" >"${authorized_line_out}"
chmod 0600 "${authorized_line_out}"

request_dir="$(mktemp -d)"
trap 'rm -rf -- "${request_dir}"' EXIT
request="${request_dir}/request"
payload_file="${request_dir}/payload"
signature_file="${request_dir}/signature"
expected_marker="CERALIVE_UART_PROVISIONED ${challenge} ${candidate_commit}"

build_request() {
  # soc_id here is the coarse SoC-family guard value: the RK3588 OTP cpu_code family
  # identity (35880000...), which the device re-derives from its OTP and the host
  # derives from the differently-encoded rci read. It is NOT a per-device id; the
  # per-device binding is the eMMC CID in the post-boot marker.
  local boot_nonce="$1"
  [[ "${boot_nonce}" =~ ^[0-9a-f]{64}$ ]]
  printf 'access_id=%s\nexpires=%s\nhost_epoch=%s\nchallenge=%s\ncandidate_commit=%s\nsoc_id=%s\nboot_nonce=%s\nkey_type=%s\nkey_body=%s\n' \
    "${access_id}" "${expires}" "${host_epoch}" "${challenge}" "${candidate_commit}" \
    "${soc_id}" "${boot_nonce}" "${key_type}" "${key_body}" >"${payload_file}"
  openssl pkeyutl -sign -inkey "${signing_key}" -rawin -in "${payload_file}" \
    -out "${signature_file}"
  printf 'CERALIVE3 %s %s\n' "$(base64 -w0 <"${payload_file}")" \
    "$(base64 -w0 <"${signature_file}")" >"${request}"
}

wait_for_start() {
  local deadline=$((SECONDS + ${CERALIVE_UART_ARM_TIMEOUT_SECONDS:-900}))
  while [[ ! -e "${start_signal}" && ${SECONDS} -lt ${deadline} ]]; do sleep 0.05; done
  [[ -e "${start_signal}" ]] || { printf 'UART start signal was not received\n' >&2; return 1; }
}

if [[ -n "${CERALIVE_UART_DRIVER:-}" ]]; then
  boot_nonce="${CERALIVE_UART_BOOT_NONCE:-}"
  build_request "${boot_nonce}"
  : >"${ready_out}"
  wait_for_start
  "${CERALIVE_UART_DRIVER}" "${serial_dev}" "${request}" "${uart_log}"
  grep -Fxq "${expected_marker}" "${uart_log}"
  exit 0
fi

command -v flock >/dev/null
stty -F "${serial_dev}" 1500000 raw -echo -ixon -ixoff cs8 -cstopb -parenb
exec {serial_fd}<>"${serial_dev}"
flock -n "${serial_fd}"
: >"${uart_log}"
: >"${ready_out}"

wait_for_start

buffer=""
read_uart() {
  local char
  if IFS= read -r -N1 -t 0.1 char <&"${serial_fd}"; then
    printf '%s' "${char}" >>"${uart_log}"
    buffer="${buffer}${char}"
    if (( ${#buffer} > 8192 )); then
      buffer="${buffer: -8192}"
    fi
  fi
}

deadline=$((SECONDS + ${CERALIVE_UBOOT_TIMEOUT_SECONDS:-30}))
while [[ "${buffer}" != *'=>'* && ${SECONDS} -lt ${deadline} ]]; do
  printf ' ' >&"${serial_fd}"
  read_uart
done
[[ "${buffer}" == *'=>'* ]] || { printf 'UART did not reach the U-Boot prompt\n' >&2; exit 1; }

# Mask the getty on the LIVE Linux-phase console so it does not contend with the
# one-shot bootstrap's TTYPath=/dev/ttyFIQ0. On RK3588 the Rockchip FIQ debugger
# owns UART2 under Linux and systemd spawns serial-getty@ttyFIQ0.service (there is
# no serial-getty@ttyS2.service at runtime, so masking ttyS2 was a no-op that left
# the real ttyFIQ0 getty fighting for the port).
printf '%s\r' "setenv cera_transient_bootargs 'ceralive.ci_uart=1 systemd.mask=serial-getty@ttyFIQ0.service'" >&"${serial_fd}"
buffer=""
deadline=$((SECONDS + 5))
while [[ "${buffer}" != *'=>'* && ${SECONDS} -lt ${deadline} ]]; do read_uart; done
[[ "${buffer}" == *'=>'* ]] || { printf 'UART did not confirm transient boot arguments\n' >&2; exit 1; }
printf 'run bootcmd\r' >&"${serial_fd}"

buffer=""
deadline=$((SECONDS + ${CERALIVE_BOOTSTRAP_TIMEOUT_SECONDS:-180}))
boot_nonce=""
while [[ ${SECONDS} -lt ${deadline} ]]; do
  read_uart
  if [[ "${buffer}" =~ CERALIVE_UART_BOOTSTRAP_READY[[:space:]]+([0-9a-f]{64}) ]]; then
    boot_nonce="${BASH_REMATCH[1]}"
    break
  fi
done
[[ "${boot_nonce}" =~ ^[0-9a-f]{64}$ ]] || {
  printf 'UART did not reach the one-shot bootstrap\n' >&2
  exit 1
}
build_request "${boot_nonce}"

printf '%s\r' "$(<"${request}")" >&"${serial_fd}"
buffer=""
deadline=$((SECONDS + ${CERALIVE_PROVISION_TIMEOUT_SECONDS:-180}))
while [[ "${buffer}" != *"${expected_marker}"* && ${SECONDS} -lt ${deadline} ]]; do read_uart; done
[[ "${buffer}" == *"${expected_marker}"* ]] || {
  printf 'UART provisioning did not complete\n' >&2
  exit 1
}
