#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2="$(cd "${HERE}/.." && pwd)"
VERIFY="${V2}/ci/verify-and-flash-candidate.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
openssl genpkey -algorithm ED25519 -out "${TMP}/uart-signing.pem" >/dev/null 2>&1
chmod 0600 "${TMP}/uart-signing.pem"
openssl pkey -in "${TMP}/uart-signing.pem" -pubout -out "${TMP}/uart-public.pem" >/dev/null 2>&1
openssl genpkey -algorithm ED25519 -out "${TMP}/wrong-uart-signing.pem" >/dev/null 2>&1
openssl pkey -in "${TMP}/wrong-uart-signing.pem" -pubout -out "${TMP}/wrong-uart-public.pem" >/dev/null 2>&1

[[ -x "${VERIFY}" ]]
printf 'candidate-bytes\n' >"${TMP}/candidate.raw"
truncate -s 4096 "${TMP}/candidate.raw"
printf 'bundle\n' >"${TMP}/candidate.raucb"
printf 'keyring\n' >"${TMP}/keyring.pem"
printf 'loader\n' >"${TMP}/loader.bin"
printf 'serial\n' >"${TMP}/serial"
printf 'private\n' >"${TMP}/id"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMockCandidateKey contract\n' >"${TMP}/id.pub"
sha="$(sha256sum "${TMP}/candidate.raw" | cut -d' ' -f1)"
loader_sha="$(sha256sum "${TMP}/loader.bin" | cut -d' ' -f1)"

cat >"${TMP}/preflash" <<'EOF'
#!/usr/bin/env bash
printf 'preflash %s\n' "$*" >>"${MOCK_FLASH_LOG}"
EOF
cat >"${TMP}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
known_hosts="" global_known_hosts=""
for arg in "$@"; do
  case "${arg}" in
    UserKnownHostsFile=*) known_hosts="${arg#*=}" ;;
    GlobalKnownHostsFile=*) global_known_hosts="${arg#*=}" ;;
  esac
done
[[ -n "${known_hosts}" && "${global_known_hosts}" == /dev/null ]]
[[ " $* " == *" -i ${MOCK_SSH_IDENTITY} "* && " $* " == *" IdentitiesOnly=yes "* ]]
cmd="${*: -1}"
printf 'ssh %s\n' "${cmd}" >>"${MOCK_FLASH_LOG}"
state="$(cat "${MOCK_DEVICE_STATE_FILE}" 2>/dev/null || printf online)"
case "${cmd}" in
  *'/device/cid'*)
    if [[ -n "${MOCK_POST_MEDIA_CID:-}" ]]; then
      printf '%s\n' "${MOCK_POST_MEDIA_CID}"
    else
      printf '%s\n' "${MOCK_MEDIA_CID}"
    fi
    ;;
  *'/usr/local/sbin/ceralive-rockchip-chip-info'*)
    printf '%s\n' "${MOCK_POST_SOC_ID:-${MOCK_SOC_ID}}"
    ;;
  *'findmnt -n -o SOURCE /'*)
    printf '%s\n' "${MOCK_BOOT_ROOT_PARENT:-mmcblk0}"
    ;;
  *'/ci-access/'*)
    printf 'challenge=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
    printf 'candidate_commit=1111111111111111111111111111111111111111\n'
    printf 'soc_id=%s\n' "${MOCK_SOC_ID}"
    ;;
  true)
    grep -q '^new-host-key$' "${known_hosts}" || printf 'new-host-key\n' >"${known_hosts}"
    count_file="${MOCK_SSH_COUNT_FILE}"
    count="$(cat "${count_file}" 2>/dev/null || echo 0)"
    count=$((count + 1)); printf '%s\n' "${count}" >"${count_file}"
    [[ "${MOCK_RECONNECT_MODE:-success}" == success && "${count}" -ge 2 ]]
    ;;
  *sha256sum*)
    printf 'mutable post-boot media must not be used for candidate identity\n' >&2
    exit 90
    ;;
  *) exit 0 ;;
esac
EOF
cat >"${TMP}/rkdeveloptool" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'rkdeveloptool %s\n' "$*" >>"${MOCK_FLASH_LOG}"
wait_for_interrupt() {
  [[ -z "${MOCK_RK_PID_FILE:-}" ]] || printf '%s\n' "$$" >"${MOCK_RK_PID_FILE}"
  trap 'exit 143' TERM INT
  while :; do sleep 1; done
}
case "${1:-}" in
  ld)
    usb_mode=Maskrom
    [[ "${MOCK_USB_MODE:-single}" == loader ]] && usb_mode=Loader
    if [[ "${MOCK_USB_MODE:-single}" == wrong-soc ]]; then
      printf 'DevNo=1 Vid=0x2207,Pid=0x330c,LocationID=101 Maskrom\n'
    else
      printf 'DevNo=1 Vid=0x2207,Pid=0x350b,LocationID=101 %s\n' "${usb_mode}"
    fi
    if [[ "${MOCK_USB_MODE:-single}" == multiple ]]; then
      printf 'DevNo=2 Vid=0x2207,Pid=0x350b,LocationID=102 Maskrom\n'
    fi
    if [[ -n "${MOCK_REPLACE_LOADER_AFTER_VALIDATION:-}" ]]; then
      printf 'replacement-loader\n' >"${MOCK_LOADER_SOURCE}"
    fi
    ;;
  db)
    if [[ -n "${MOCK_REPLACE_LOADER_AFTER_VALIDATION:-}" ]]; then
      [[ "$2" != "${MOCK_LOADER_SOURCE}" ]]
      grep -qx 'loader' "$2"
    fi
    if [[ "${MOCK_FLASH_MODE:-exact}" == db-wait ]]; then wait_for_interrupt; fi
    [[ "${MOCK_FLASH_MODE:-exact}" != db-fail ]] || exit 70
    ;;
  rfi)
    printf 'Flash Size: %s Sectors\n' "${MOCK_TARGET_SECTORS:-195312}"
    ;;
  rid)
    printf 'Flash ID: mock-emmc\n'
    ;;
  rci)
    printf 'Chip Info: 1 2 3 4 5 6 7 8 9 A B C D E F 10\n'
    ;;
  wl)
    if [[ "${MOCK_FLASH_MODE:-exact}" == wl-wait ]]; then wait_for_interrupt; fi
    cp "$3" "${MOCK_MEDIA}"
    chmod 600 "${MOCK_MEDIA}"
    case "${MOCK_FLASH_MODE:-exact}" in
      wrong) printf 'X' | dd of="${MOCK_MEDIA}" bs=1 seek=1024 conv=notrunc status=none ;;
      snapshot-grow)
        chmod 600 "$3"
        truncate -s $(( $(stat -c %s "$3") + 512 )) "$3"
        ;;
    esac
    ;;
  rl)
    [[ "$2" == 0 && "$3" == 8 ]]
    [[ -z "${MOCK_READBACK_PATH_FILE:-}" ]] || printf '%s\n' "$4" >"${MOCK_READBACK_PATH_FILE}"
    case "${MOCK_FLASH_MODE:-exact}" in
      readback-fail) exit 71 ;;
      readback-wait|rl-wait) wait_for_interrupt ;;
      *) cp "${MOCK_MEDIA}" "$4" ;;
    esac
    ;;
  rd)
    if [[ "${MOCK_FLASH_MODE:-exact}" == rd-wait ]]; then wait_for_interrupt; fi
    printf 'B' | dd of="${MOCK_MEDIA}" bs=1 seek=2048 conv=notrunc status=none
    printf 'booting\n' >"${MOCK_DEVICE_STATE_FILE}"
    ;;
esac
EOF
cat >"${TMP}/uart" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
uart_log="" authorized_line_out="" ready_out="" start_signal=""
challenge="" candidate_commit=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --uart-log) uart_log="$2"; shift 2 ;;
    --authorized-line-out) authorized_line_out="$2"; shift 2 ;;
    --ready-out) ready_out="$2"; shift 2 ;;
    --start-signal) start_signal="$2"; shift 2 ;;
    --challenge) challenge="$2"; shift 2 ;;
    --candidate-commit) candidate_commit="$2"; shift 2 ;;
    *) shift 2 ;;
  esac
done
printf 'restrict,expiry-time="20990101000000Z" ssh-ed25519 AAAA mock\n' >"${authorized_line_out}"
: >"${ready_out}"
while [[ ! -e "${start_signal}" ]]; do sleep 0.02; done
printf 'CERALIVE_UART_PROVISIONED %s %s\n' "${challenge}" "${candidate_commit}" >"${uart_log}"
EOF
chmod +x "${TMP}/preflash" "${TMP}/ssh" "${TMP}/rkdeveloptool" "${TMP}/uart"

common=(
  --image "${TMP}/candidate.raw"
  --bundle "${TMP}/candidate.raucb"
  --keyring "${TMP}/keyring.pem"
  --loader "${TMP}/loader.bin"
  --loader-sha256 "${loader_sha}"
  --board rock-5b-plus
  --board-ip 192.0.2.10
  --candidate-commit 1111111111111111111111111111111111111111
  --image-sha256 "${sha}"
  --serial-dev "${TMP}/serial"
  --uart-log "${TMP}/uart.log"
  --authorized-key "${TMP}/id.pub"
  --access-id gh-123-1
  --access-expires 20990101000000Z
  --host-epoch 4070908800
  --ssh-identity "${TMP}/id"
  --challenge aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  --expected-maskrom-id-sha256 "$(printf '%s' 'Vid=0x2207,Pid=0x350b,LocationID=101 Maskrom' | sha256sum | cut -d' ' -f1)"
  --uart-signing-key "${TMP}/uart-signing.pem"
  --known-hosts "${TMP}/known-hosts"
  --authorized-line-out "${TMP}/authorized-line"
  --identity-out "${TMP}/identity.txt"
)
media_cid="0123456789abcdef0123456789abcdef"
soc_id="0102030405060708090a0b0c0d0e0f10"
base_env=(
  "RUNNER_TEMP=${TMP}"
  "MOCK_MEDIA_CID=${media_cid}"
  "MOCK_SOC_ID=${soc_id}"
  "MOCK_SSH_IDENTITY=${TMP}/id"
  "CERALIVE_RKDEVELOPTOOL_BIN=${TMP}/rkdeveloptool"
  "CERALIVE_UART_HELPER_BIN=${TMP}/uart"
  "CERALIVE_PREFLASH_BIN=${TMP}/preflash"
  "CERALIVE_SSH_BIN=${TMP}/ssh"
  "CERALIVE_RECONNECT_ATTEMPTS=3"
  "CERALIVE_RECONNECT_DELAY=0"
  "CERALIVE_UART_PUBLIC_KEY_FILE=${TMP}/uart-public.pem"
)

assert_identity_name_rejected() {
  local label="$1" flag="$2" path="$3" output
  rm -f "${TMP}/identity.txt"
  if output="$(env "${base_env[@]}" MOCK_MEDIA="${TMP}/malformed-media.raw" \
      MOCK_SSH_COUNT_FILE="${TMP}/malformed-count" MOCK_FLASH_LOG="${TMP}/malformed.log" \
      MOCK_DEVICE_STATE_FILE="${TMP}/malformed-state" "${VERIFY}" "${common[@]}" \
      "${flag}" "${path}" 2>&1)"; then
    printf '%s identity name was accepted\n' "${label}" >&2
    exit 1
  fi
  [[ "${output}" == *"identity filename"* ]]
  [[ ! -e "${TMP}/identity.txt" ]]
  printf '%s identity name rejected: %s\n' "${label}" "${output}"
}

malformed_image="${TMP}/candidate=malformed.raw"
cp "${TMP}/candidate.raw" "${malformed_image}"
assert_identity_name_rejected "equals image" --image "${malformed_image}"
malformed_bundle="${TMP}/candidate
malformed.raucb"
printf 'bundle\n' >"${malformed_bundle}"
assert_identity_name_rejected "newline bundle" --bundle "${malformed_bundle}"

if env "${base_env[@]}" "${VERIFY}" "${common[@]}" \
    --image-sha256 "$(printf bad | sha256sum | cut -d' ' -f1)"; then
  printf 'candidate digest mismatch was accepted\n' >&2
  exit 1
fi

if env "${base_env[@]}" MOCK_FLASH_LOG="${TMP}/flash-loader-digest.log" \
    "${VERIFY}" "${common[@]}" \
    --loader-sha256 "$(printf bad | sha256sum | cut -d' ' -f1)"; then
  printf 'loader digest mismatch was accepted\n' >&2
  exit 1
fi
[[ ! -e "${TMP}/flash-loader-digest.log" ]]

if ! env "${base_env[@]}" MOCK_REPLACE_LOADER_AFTER_VALIDATION=1 \
    MOCK_LOADER_SOURCE="${TMP}/loader.bin" MOCK_RECONNECT_MODE=success \
    MOCK_MEDIA="${TMP}/media-loader-snapshot.raw" \
    MOCK_SSH_COUNT_FILE="${TMP}/count-loader-snapshot" \
    MOCK_FLASH_LOG="${TMP}/flash-loader-snapshot.log" \
    MOCK_DEVICE_STATE_FILE="${TMP}/state-loader-snapshot" \
    "${VERIFY}" "${common[@]}"; then
  printf 'verified private loader snapshot was not used after source replacement\n' >&2
  exit 1
fi
grep -Eq "^rkdeveloptool db ${TMP}/ceralive-verify\\.[^/]+/loader.bin$" \
  "${TMP}/flash-loader-snapshot.log"
printf 'loader\n' >"${TMP}/loader.bin"

if env "${base_env[@]}" MOCK_USB_MODE=multiple \
    MOCK_MEDIA="${TMP}/media-multi.raw" MOCK_SSH_COUNT_FILE="${TMP}/count-multi" \
    MOCK_FLASH_LOG="${TMP}/flash-multi.log" MOCK_DEVICE_STATE_FILE="${TMP}/state-multi" \
    "${VERIFY}" "${common[@]}"; then
  printf 'ambiguous Rockchip USB target selection was accepted\n' >&2
  exit 1
fi

if env "${base_env[@]}" MOCK_USB_MODE=loader \
    MOCK_MEDIA="${TMP}/media-loader.raw" MOCK_SSH_COUNT_FILE="${TMP}/count-loader" \
    MOCK_FLASH_LOG="${TMP}/flash-loader.log" MOCK_DEVICE_STATE_FILE="${TMP}/state-loader" \
    "${VERIFY}" "${common[@]}"; then
  printf 'loader-mode target was accepted as a Maskrom starting state\n' >&2
  exit 1
fi

if env "${base_env[@]}" MOCK_USB_MODE=wrong-soc \
    MOCK_MEDIA="${TMP}/media-wrong-soc.raw" MOCK_SSH_COUNT_FILE="${TMP}/count-wrong-soc" \
    MOCK_FLASH_LOG="${TMP}/flash-wrong-soc.log" MOCK_DEVICE_STATE_FILE="${TMP}/state-wrong-soc" \
    "${VERIFY}" "${common[@]}"; then
  printf 'wrong single Maskrom SoC was accepted\n' >&2
  exit 1
fi
if grep -q '^rkdeveloptool db' "${TMP}/flash-wrong-soc.log"; then
  printf 'wrong single Maskrom SoC advanced to loader download\n' >&2
  exit 1
fi

if env "${base_env[@]}" MOCK_FLASH_MODE=db-fail \
    MOCK_MEDIA="${TMP}/media-db-fail.raw" MOCK_SSH_COUNT_FILE="${TMP}/count-db-fail" \
    MOCK_FLASH_LOG="${TMP}/flash-db-fail.log" MOCK_DEVICE_STATE_FILE="${TMP}/state-db-fail" \
    "${VERIFY}" "${common[@]}"; then
  printf 'loader transfer failure was accepted\n' >&2
  exit 1
fi
if grep -Eq '^rkdeveloptool (rfi|wl|rl|rd)' "${TMP}/flash-db-fail.log"; then
  printf 'loader transfer failure advanced to capacity, write, readback, or reset\n' >&2
  exit 1
fi

if env "${base_env[@]}" \
    MOCK_MEDIA="${TMP}/media-unapproved.raw" MOCK_SSH_COUNT_FILE="${TMP}/count-unapproved" \
    MOCK_FLASH_LOG="${TMP}/flash-unapproved.log" MOCK_DEVICE_STATE_FILE="${TMP}/state-unapproved" \
    "${VERIFY}" "${common[@]}" \
    --expected-maskrom-id-sha256 "$(printf unapproved | sha256sum | cut -d' ' -f1)"; then
  printf 'unapproved Rock 5B+ fixture was accepted\n' >&2
  exit 1
fi
if grep -q '^rkdeveloptool wl' "${TMP}/flash-unapproved.log"; then
  printf 'unapproved Rock 5B+ fixture reached media write\n' >&2
  exit 1
fi
if grep -q '^rkdeveloptool db' "${TMP}/flash-loader.log"; then
  printf 'loader-mode target advanced to loader download\n' >&2
  exit 1
fi

if key_mismatch_output="$(env "${base_env[@]}" \
    CERALIVE_UART_PUBLIC_KEY_FILE="${TMP}/wrong-uart-public.pem" \
    MOCK_MEDIA="${TMP}/media-key-mismatch.raw" MOCK_SSH_COUNT_FILE="${TMP}/count-key-mismatch" \
    MOCK_FLASH_LOG="${TMP}/flash-key-mismatch.log" MOCK_DEVICE_STATE_FILE="${TMP}/state-key-mismatch" \
    "${VERIFY}" "${common[@]}" 2>&1)"; then
  printf 'mismatched UART signing key and baked public key were accepted\n' >&2
  exit 1
fi
[[ "${key_mismatch_output}" == *'does not match the public key baked into the candidate'* ]]
if [[ -e "${TMP}/flash-key-mismatch.log" ]] && \
   grep -q '^rkdeveloptool ' "${TMP}/flash-key-mismatch.log"; then
  printf 'mismatched UART signing key touched the Rockchip USB fixture\n' >&2
  exit 1
fi

if env "${base_env[@]}" MOCK_TARGET_SECTORS=7 \
    MOCK_MEDIA="${TMP}/media-small.raw" MOCK_SSH_COUNT_FILE="${TMP}/count-small" \
    MOCK_FLASH_LOG="${TMP}/flash-small.log" MOCK_DEVICE_STATE_FILE="${TMP}/state-small" \
    "${VERIFY}" "${common[@]}"; then
  printf 'undersized eMMC capacity was accepted\n' >&2
  exit 1
fi
if grep -q '^rkdeveloptool wl' "${TMP}/flash-small.log"; then
  printf 'undersized eMMC capacity reached media write\n' >&2
  exit 1
fi
if grep -q '^rkdeveloptool db' "${TMP}/flash-multi.log"; then
  printf 'ambiguous Rockchip USB targets advanced to loader download\n' >&2
  exit 1
fi

printf 'stale-identity\n' >"${TMP}/identity.txt"
if env "${base_env[@]}" MOCK_RECONNECT_MODE=never MOCK_MEDIA="${TMP}/media-never.raw" \
    MOCK_SSH_COUNT_FILE="${TMP}/count-never" MOCK_FLASH_LOG="${TMP}/flash-never.log" \
    MOCK_DEVICE_STATE_FILE="${TMP}/state-never" CERALIVE_RECONNECT_ATTEMPTS=2 \
    "${VERIFY}" "${common[@]}"; then
  printf 'reconnect exhaustion was accepted\n' >&2
  exit 1
fi
[[ ! -e "${TMP}/identity.txt" ]]

if env "${base_env[@]}" MOCK_RECONNECT_MODE=success MOCK_FLASH_MODE=wrong \
    MOCK_MEDIA="${TMP}/media-wrong.raw" MOCK_SSH_COUNT_FILE="${TMP}/count-wrong" \
    MOCK_FLASH_LOG="${TMP}/flash-wrong.log" MOCK_DEVICE_STATE_FILE="${TMP}/state-wrong" \
    "${VERIFY}" "${common[@]}"; then
  printf 'wrong flashed candidate was accepted\n' >&2
  exit 1
fi
if grep -q '^rkdeveloptool rd' "${TMP}/flash-wrong.log"; then
  printf 'wrong flashed candidate reached reset before readback rejection\n' >&2
  exit 1
fi

if env "${base_env[@]}" MOCK_RECONNECT_MODE=success MOCK_FLASH_MODE=snapshot-grow \
    MOCK_MEDIA="${TMP}/media-grow.raw" MOCK_SSH_COUNT_FILE="${TMP}/count-grow" \
    MOCK_FLASH_LOG="${TMP}/flash-grow.log" MOCK_DEVICE_STATE_FILE="${TMP}/state-grow" \
    "${VERIFY}" "${common[@]}"; then
  printf 'candidate snapshot growth during flash was accepted\n' >&2
  exit 1
fi
if grep -q '^rkdeveloptool rl' "${TMP}/flash-grow.log"; then
  printf 'candidate snapshot growth reached media readback\n' >&2
  exit 1
fi
if grep -q '^rkdeveloptool rd' "${TMP}/flash-grow.log"; then
  printf 'candidate snapshot growth reached reset\n' >&2
  exit 1
fi

if env "${base_env[@]}" MOCK_RECONNECT_MODE=success MOCK_FLASH_MODE=readback-fail \
    MOCK_MEDIA="${TMP}/media-readfail.raw" MOCK_SSH_COUNT_FILE="${TMP}/count-readfail" \
    MOCK_FLASH_LOG="${TMP}/flash-readfail.log" MOCK_DEVICE_STATE_FILE="${TMP}/state-readfail" \
    MOCK_READBACK_PATH_FILE="${TMP}/readfail-path" "${VERIFY}" "${common[@]}"; then
  printf 'rkdeveloptool readback failure was accepted\n' >&2
  exit 1
fi
readfail_path="$(cat "${TMP}/readfail-path")"
[[ ! -e "${readfail_path}" ]]
if grep -q '^rkdeveloptool rd' "${TMP}/flash-readfail.log"; then
  printf 'failed media readback reached reset\n' >&2
  exit 1
fi

term_log="${TMP}/term.out"
env "${base_env[@]}" MOCK_RECONNECT_MODE=success MOCK_FLASH_MODE=readback-wait \
  MOCK_MEDIA="${TMP}/media-term.raw" MOCK_SSH_COUNT_FILE="${TMP}/count-term" \
  MOCK_FLASH_LOG="${TMP}/flash-term.log" MOCK_DEVICE_STATE_FILE="${TMP}/state-term" \
  MOCK_READBACK_PATH_FILE="${TMP}/term-path" MOCK_RK_PID_FILE="${TMP}/term-rk-pid" \
  "${VERIFY}" "${common[@]}" >"${term_log}" 2>&1 &
verify_pid=$!
for _ in $(seq 1 100); do
  [[ -s "${TMP}/term-path" && -s "${TMP}/term-rk-pid" ]] && break
  sleep 0.02
done
[[ -s "${TMP}/term-path" && -s "${TMP}/term-rk-pid" ]]
term_readback_path="$(cat "${TMP}/term-path")"
rk_pid="$(cat "${TMP}/term-rk-pid")"
kill -TERM "${verify_pid}"
set +e
wait "${verify_pid}"
term_rc=$?
set -e
[[ "${term_rc}" -eq 143 ]]
if kill -0 "${rk_pid}" 2>/dev/null; then
  printf 'interrupted verifier left rkdeveloptool running\n' >&2
  exit 1
fi
[[ ! -e "${term_readback_path}" ]]
[[ ! -e "${TMP}/identity.txt" ]]
if grep -q '^rkdeveloptool rd' "${TMP}/flash-term.log"; then
  printf 'interrupted media readback reached reset\n' >&2
  exit 1
fi

assert_interrupt_cleanup() {
  local mode="$1" label="$2" signal="$3" expected_rc="$4" case_dir
  local verify_pid watchdog_pid rk_pid rc started elapsed child_survived=0
  case_dir="${TMP}/interrupt-${signal,,}-${label}"
  mkdir -p "${case_dir}"
  rm -f "${TMP}/identity.txt"
  env "${base_env[@]}" MOCK_FLASH_MODE="${mode}" \
    MOCK_MEDIA="${case_dir}/media.raw" MOCK_SSH_COUNT_FILE="${case_dir}/count" \
    MOCK_FLASH_LOG="${case_dir}/flash.log" MOCK_DEVICE_STATE_FILE="${case_dir}/state" \
    MOCK_RK_PID_FILE="${case_dir}/rk.pid" "${VERIFY}" "${common[@]}" \
    >"${case_dir}/verify.log" 2>&1 &
  verify_pid=$!
  for _ in $(seq 1 150); do
    [[ -s "${case_dir}/rk.pid" ]] && break
    sleep 0.02
  done
  [[ -s "${case_dir}/rk.pid" ]]
  rk_pid="$(cat "${case_dir}/rk.pid")"
  started="${SECONDS}"
  (
    sleep 3
    kill -KILL "${verify_pid}" 2>/dev/null || true
  ) &
  watchdog_pid=$!
  kill "-${signal}" "${verify_pid}"
  set +e
  wait "${verify_pid}"
  rc=$?
  set -e
  elapsed=$((SECONDS - started))
  kill "${watchdog_pid}" 2>/dev/null || true
  wait "${watchdog_pid}" 2>/dev/null || true
  if kill -0 "${rk_pid}" 2>/dev/null; then
    child_survived=1
    kill -KILL "${rk_pid}" 2>/dev/null || true
    wait "${rk_pid}" 2>/dev/null || true
  fi
  if [[ "${rc}" -ne "${expected_rc}" ]]; then
    printf '%s %s cancellation returned %s, expected %s (elapsed=%ss)\n' \
      "${signal}" "${label}" "${rc}" "${expected_rc}" "${elapsed}" >&2
    exit 1
  fi
  if (( child_survived == 1 )); then
    printf '%s %s rkdeveloptool child survived cancellation\n' "${signal}" "${label}" >&2
    exit 1
  fi
  (( elapsed < 3 )) || {
    printf '%s %s cancellation reached the 3s watchdog\n' "${signal}" "${label}" >&2
    exit 1
  }
  grep -q "^rkdeveloptool ${label}" "${case_dir}/flash.log"
  [[ ! -e "${TMP}/identity.txt" ]]
  if find "${TMP}" -maxdepth 1 -type d -name 'ceralive-verify.*' -print -quit | grep -q .; then
    printf '%s %s cancellation leaked verifier scratch\n' "${signal}" "${label}" >&2
    exit 1
  fi
  printf '%s %s cancellation cleaned verifier, child, and scratch (rc=%s elapsed=%ss)\n' \
    "${signal}" "${label}" "${rc}" "${elapsed}"
}

for signal_case in TERM INT; do
  if [[ "${signal_case}" == TERM ]]; then
    expected_signal_rc=143
  else
    expected_signal_rc=130
  fi
  assert_interrupt_cleanup db-wait db "${signal_case}" "${expected_signal_rc}"
  assert_interrupt_cleanup wl-wait wl "${signal_case}" "${expected_signal_rc}"
  assert_interrupt_cleanup rl-wait rl "${signal_case}" "${expected_signal_rc}"
  assert_interrupt_cleanup rd-wait rd "${signal_case}" "${expected_signal_rc}"
done

if env "${base_env[@]}" MOCK_RECONNECT_MODE=success \
    MOCK_POST_MEDIA_CID="invalid-cid" \
    MOCK_MEDIA="${TMP}/media-cid.raw" MOCK_SSH_COUNT_FILE="${TMP}/count-cid" \
    MOCK_FLASH_LOG="${TMP}/flash-cid.log" MOCK_DEVICE_STATE_FILE="${TMP}/state-cid" \
    "${VERIFY}" "${common[@]}"; then
  printf 'reconnect with an invalid media CID was accepted\n' >&2
  exit 1
fi
[[ ! -e "${TMP}/identity.txt" ]]

if env "${base_env[@]}" MOCK_RECONNECT_MODE=success \
    MOCK_POST_SOC_ID="ffffffffffffffffffffffffffffffff" \
    MOCK_MEDIA="${TMP}/media-soc-mismatch.raw" MOCK_SSH_COUNT_FILE="${TMP}/count-soc-mismatch" \
    MOCK_FLASH_LOG="${TMP}/flash-soc-mismatch.log" MOCK_DEVICE_STATE_FILE="${TMP}/state-soc-mismatch" \
    "${VERIFY}" "${common[@]}"; then
  printf 'reconnect from a different SoC was accepted\n' >&2
  exit 1
fi
[[ ! -e "${TMP}/identity.txt" ]]

if env "${base_env[@]}" MOCK_RECONNECT_MODE=success MOCK_BOOT_ROOT_PARENT=mmcblk1 \
    MOCK_MEDIA="${TMP}/media-root-mismatch.raw" MOCK_SSH_COUNT_FILE="${TMP}/count-root-mismatch" \
    MOCK_FLASH_LOG="${TMP}/flash-root-mismatch.log" MOCK_DEVICE_STATE_FILE="${TMP}/state-root-mismatch" \
    "${VERIFY}" "${common[@]}"; then
  printf 'boot from a different media device was accepted\n' >&2
  exit 1
fi
[[ ! -e "${TMP}/identity.txt" ]]

if ! env "${base_env[@]}" MOCK_RECONNECT_MODE=success MOCK_MEDIA="${TMP}/media-ok.raw" \
  MOCK_SSH_COUNT_FILE="${TMP}/count-ok" MOCK_FLASH_LOG="${TMP}/flash-ok.log" \
  MOCK_DEVICE_STATE_FILE="${TMP}/state-ok" "${VERIFY}" "${common[@]}"; then
  printf 'healthy candidate was rejected after expected first-boot media mutation\n' >&2
  exit 1
fi
grep -qx "candidate_commit=1111111111111111111111111111111111111111" "${TMP}/identity.txt"
grep -qx 'raw_file=candidate.raw' "${TMP}/identity.txt"
grep -qx 'raw_size=4096' "${TMP}/identity.txt"
grep -qx "raw_sha256=${sha}" "${TMP}/identity.txt"
grep -qx 'bundle_file=candidate.raucb' "${TMP}/identity.txt"
grep -qx "keyring_sha256=$(sha256sum "${TMP}/keyring.pem" | cut -d' ' -f1)" \
  "${TMP}/identity.txt"
grep -qx 'loader_file=loader.bin' "${TMP}/identity.txt"
grep -qx "loader_sha256=${loader_sha}" "${TMP}/identity.txt"
grep -qx 'identity_contract=pre-boot-whole-media-sha256' "${TMP}/identity.txt"
grep -qx "pre_boot_media_sha256=${sha}" "${TMP}/identity.txt"
grep -qx 'pre_boot_media_identity=verified' "${TMP}/identity.txt"
grep -qx 'target_capacity_sectors=195312' "${TMP}/identity.txt"
grep -Eq '^flash_id_sha256=[0-9a-f]{64}$' "${TMP}/identity.txt"
grep -qx "soc_id_sha256=$(printf '%s' "${soc_id}" | sha256sum | cut -d' ' -f1)" \
  "${TMP}/identity.txt"
grep -qx "media_cid=${media_cid}" "${TMP}/identity.txt"
grep -qx 'boot_root_parent=mmcblk0' "${TMP}/identity.txt"
usb_identity='Vid=0x2207,Pid=0x350b,LocationID=101 Maskrom'
grep -qx "usb_device_sha256=$(printf '%s' "${usb_identity}" | sha256sum | cut -d' ' -f1)" \
  "${TMP}/identity.txt"
grep -Eq '^bootstrap_challenge_sha256=[0-9a-f]{64}$' "${TMP}/identity.txt"
grep -Eq '^post_boot_known_hosts_sha256=[0-9a-f]{64}$' "${TMP}/identity.txt"
grep -qx 'post_boot_reconnect=verified' "${TMP}/identity.txt"
grep -Eq '^uart_log_sha256=[0-9a-f]{64}$' "${TMP}/identity.txt"
grep -qx 'ephemeral_ssh_access=gh-123-1' "${TMP}/identity.txt"
grep -qx 'flash_transport=maskrom-rkdeveloptool' "${TMP}/identity.txt"
grep -qx 'rkdeveloptool db .*loader.bin' "${TMP}/flash-ok.log"
grep -qx 'rkdeveloptool rfi' "${TMP}/flash-ok.log"
grep -qx 'rkdeveloptool rid' "${TMP}/flash-ok.log"
grep -qx 'rkdeveloptool rci' "${TMP}/flash-ok.log"
grep -q 'preflash .*--target-size-bytes 99999744' "${TMP}/flash-ok.log"
grep -Eq "^rkdeveloptool wl 0 ${TMP}/ceralive-verify\.[^/]+/candidate.raw$" "${TMP}/flash-ok.log"
grep -Eq "^rkdeveloptool rl 0 8 ${TMP}/ceralive-verify\.[^/]+/readback.raw$" "${TMP}/flash-ok.log"
grep -qx 'rkdeveloptool rd' "${TMP}/flash-ok.log"
if grep -q 'sha256sum' "${TMP}/flash-ok.log"; then
  printf 'candidate identity used mutable post-boot media bytes\n' >&2
  exit 1
fi
if find "${TMP}" -maxdepth 1 -type d -name 'ceralive-verify.*' -print -quit | grep -q .; then
  printf 'verifier scratch directory leaked\n' >&2
  exit 1
fi
if find "${TMP}" -maxdepth 1 -type f -name '.candidate-identity.*' -print -quit | grep -q .; then
  printf 'candidate identity temporary file leaked\n' >&2
  exit 1
fi

printf 'release candidate identity/flash contract: PASS\n'
