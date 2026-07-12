#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2="$(cd "${HERE}/.." && pwd)"
VERIFY="${V2}/ci/verify-and-flash-candidate.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

[[ -x "${VERIFY}" ]]
printf 'candidate-bytes\n' >"${TMP}/candidate.raw"
truncate -s 4096 "${TMP}/candidate.raw"
printf 'bundle\n' >"${TMP}/candidate.raucb"
printf 'keyring\n' >"${TMP}/keyring.pem"
printf 'loader\n' >"${TMP}/loader.bin"
sha="$(sha256sum "${TMP}/candidate.raw" | cut -d' ' -f1)"

cat >"${TMP}/preflash" <<'EOF'
#!/usr/bin/env bash
exit 0
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
cmd="${*: -1}"
printf 'ssh %s\n' "${cmd}" >>"${MOCK_FLASH_LOG}"
state="$(cat "${MOCK_DEVICE_STATE_FILE}" 2>/dev/null || printf online)"
case "${cmd}" in
  *blockdev*)
    printf 'old-host-key\n' >"${known_hosts}"
    printf '100000000\n'
    ;;
  *'/device/cid'*)
    if [[ "${state}" == booting && -n "${MOCK_POST_MEDIA_CID:-}" ]]; then
      printf '%s\n' "${MOCK_POST_MEDIA_CID}"
    else
      printf '%s\n' "${MOCK_MEDIA_CID}"
    fi
    ;;
  true)
    if [[ "${state}" == maskrom ]]; then
      [[ "${MOCK_DISCONNECT_MODE:-disconnect}" == remain-online ]] && exit 0
      exit 1
    fi
    if grep -q '^old-host-key$' "${known_hosts}"; then
      exit 92
    fi
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
cat >"${TMP}/power" <<'EOF'
#!/usr/bin/env bash
printf 'power %s\n' "$*" >>"${MOCK_FLASH_LOG}"
printf 'maskrom\n' >"${MOCK_DEVICE_STATE_FILE}"
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
    printf 'DevNo=1 Vid=0x2207,Pid=0x350b,LocationID=101 Mode=Maskrom SerialNo=mock\n'
    if [[ "${MOCK_USB_MODE:-single}" == multiple ]]; then
      printf 'DevNo=2 Vid=0x2207,Pid=0x350b,LocationID=102 Mode=Maskrom SerialNo=other\n'
    fi
    ;;
  db)
    if [[ "${MOCK_FLASH_MODE:-exact}" == db-wait ]]; then wait_for_interrupt; fi
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
chmod +x "${TMP}/preflash" "${TMP}/ssh" "${TMP}/power" "${TMP}/rkdeveloptool"

common=(
  --image "${TMP}/candidate.raw"
  --bundle "${TMP}/candidate.raucb"
  --keyring "${TMP}/keyring.pem"
  --board rock-5b-plus
  --board-ip 192.0.2.10
  --candidate-commit deadbeef
  --image-sha256 "${sha}"
  --identity-out "${TMP}/identity.txt"
)
media_cid="0123456789abcdef0123456789abcdef"
base_env=(
  "RUNNER_TEMP=${TMP}"
  "MOCK_MEDIA_CID=${media_cid}"
  "CERALIVE_RK3588_POWER_HELPER=${TMP}/power"
  "RK3588_LOADER=${TMP}/loader.bin"
  "CERALIVE_RKDEVELOPTOOL_BIN=${TMP}/rkdeveloptool"
  "CERALIVE_PREFLASH_BIN=${TMP}/preflash"
  "CERALIVE_SSH_BIN=${TMP}/ssh"
  "CERALIVE_DISCONNECT_ATTEMPTS=2"
  "CERALIVE_DISCONNECT_DELAY=0"
  "CERALIVE_RECONNECT_ATTEMPTS=3"
  "CERALIVE_RECONNECT_DELAY=0"
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

if env "${base_env[@]}" MOCK_DISCONNECT_MODE=remain-online \
    MOCK_MEDIA="${TMP}/media-online.raw" MOCK_SSH_COUNT_FILE="${TMP}/count-online" \
    MOCK_FLASH_LOG="${TMP}/flash-online.log" MOCK_DEVICE_STATE_FILE="${TMP}/state-online" \
    "${VERIFY}" "${common[@]}"; then
  printf 'board that remained reachable after maskrom was accepted\n' >&2
  exit 1
fi
if grep -q '^rkdeveloptool ld' "${TMP}/flash-online.log"; then
  printf 'reachable board advanced to USB target enumeration\n' >&2
  exit 1
fi

if env "${base_env[@]}" MOCK_USB_MODE=multiple \
    MOCK_MEDIA="${TMP}/media-multi.raw" MOCK_SSH_COUNT_FILE="${TMP}/count-multi" \
    MOCK_FLASH_LOG="${TMP}/flash-multi.log" MOCK_DEVICE_STATE_FILE="${TMP}/state-multi" \
    "${VERIFY}" "${common[@]}"; then
  printf 'ambiguous Rockchip USB target selection was accepted\n' >&2
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
  local mode="$1" label="$2" case_dir
  local verify_pid watchdog_pid rk_pid rc
  case_dir="${TMP}/interrupt-${label}"
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
  (
    sleep 3
    kill -KILL "${verify_pid}" 2>/dev/null || true
  ) &
  watchdog_pid=$!
  kill -TERM "${verify_pid}"
  set +e
  wait "${verify_pid}"
  rc=$?
  set -e
  kill "${watchdog_pid}" 2>/dev/null || true
  wait "${watchdog_pid}" 2>/dev/null || true
  if kill -0 "${rk_pid}" 2>/dev/null; then
    kill -KILL "${rk_pid}" 2>/dev/null || true
    wait "${rk_pid}" 2>/dev/null || true
  fi
  [[ "${rc}" -eq 143 ]]
  if kill -0 "${rk_pid}" 2>/dev/null; then
    printf '%s rkdeveloptool child survived cancellation\n' "${label}" >&2
    exit 1
  fi
  grep -q "^rkdeveloptool ${label}" "${case_dir}/flash.log"
  [[ ! -e "${TMP}/identity.txt" ]]
  if find "${TMP}" -maxdepth 1 -type d -name 'ceralive-verify.*' -print -quit | grep -q .; then
    printf '%s cancellation leaked verifier scratch\n' "${label}" >&2
    exit 1
  fi
  printf '%s cancellation cleaned child and scratch (rc=%s)\n' "${label}" "${rc}"
}

assert_interrupt_cleanup db-wait db
assert_interrupt_cleanup wl-wait wl
assert_interrupt_cleanup rl-wait rl
assert_interrupt_cleanup rd-wait rd

if env "${base_env[@]}" MOCK_RECONNECT_MODE=success \
    MOCK_POST_MEDIA_CID="ffffffffffffffffffffffffffffffff" \
    MOCK_MEDIA="${TMP}/media-cid.raw" MOCK_SSH_COUNT_FILE="${TMP}/count-cid" \
    MOCK_FLASH_LOG="${TMP}/flash-cid.log" MOCK_DEVICE_STATE_FILE="${TMP}/state-cid" \
    "${VERIFY}" "${common[@]}"; then
  printf 'reconnect to a different media CID was accepted\n' >&2
  exit 1
fi
[[ ! -e "${TMP}/identity.txt" ]]

if ! env "${base_env[@]}" MOCK_RECONNECT_MODE=success MOCK_MEDIA="${TMP}/media-ok.raw" \
  MOCK_SSH_COUNT_FILE="${TMP}/count-ok" MOCK_FLASH_LOG="${TMP}/flash-ok.log" \
  MOCK_DEVICE_STATE_FILE="${TMP}/state-ok" "${VERIFY}" "${common[@]}"; then
  printf 'healthy candidate was rejected after expected first-boot media mutation\n' >&2
  exit 1
fi
grep -qx "candidate_commit=deadbeef" "${TMP}/identity.txt"
grep -qx 'raw_file=candidate.raw' "${TMP}/identity.txt"
grep -qx 'raw_size=4096' "${TMP}/identity.txt"
grep -qx "raw_sha256=${sha}" "${TMP}/identity.txt"
grep -qx 'bundle_file=candidate.raucb' "${TMP}/identity.txt"
grep -qx "keyring_sha256=$(sha256sum "${TMP}/keyring.pem" | cut -d' ' -f1)" \
  "${TMP}/identity.txt"
grep -qx 'identity_contract=pre-boot-whole-media-sha256' "${TMP}/identity.txt"
grep -qx "pre_boot_media_sha256=${sha}" "${TMP}/identity.txt"
grep -qx 'pre_boot_media_identity=verified' "${TMP}/identity.txt"
grep -qx "media_cid=${media_cid}" "${TMP}/identity.txt"
usb_identity='DevNo=1 Vid=0x2207,Pid=0x350b,LocationID=101 Mode=Maskrom SerialNo=mock'
grep -qx "usb_device_sha256=$(printf '%s\n' "${usb_identity}" | sha256sum | cut -d' ' -f1)" \
  "${TMP}/identity.txt"
grep -Eq '^pre_flash_known_hosts_sha256=[0-9a-f]{64}$' "${TMP}/identity.txt"
grep -Eq '^post_boot_known_hosts_sha256=[0-9a-f]{64}$' "${TMP}/identity.txt"
[[ "$(grep '^pre_flash_known_hosts_sha256=' "${TMP}/identity.txt")" != \
   "$(grep '^post_boot_known_hosts_sha256=' "${TMP}/identity.txt")" ]]
grep -qx 'post_boot_reconnect=verified' "${TMP}/identity.txt"
grep -qx 'flash_transport=maskrom-rkdeveloptool' "${TMP}/identity.txt"
grep -qx 'power maskrom' "${TMP}/flash-ok.log"
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
