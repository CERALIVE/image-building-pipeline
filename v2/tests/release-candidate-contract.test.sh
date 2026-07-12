#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2="$(cd "${HERE}/.." && pwd)"
VERIFY="${V2}/ci/verify-and-flash-candidate.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

[[ -x "${VERIFY}" ]]
printf 'candidate-bytes\n' >"${TMP}/candidate.raw"
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
cmd="${*: -1}"
case "${cmd}" in
  *blockdev*) printf '100000000\n' ;;
  true)
    count_file="${MOCK_SSH_COUNT_FILE}"
    count="$(cat "${count_file}" 2>/dev/null || echo 0)"
    count=$((count + 1)); printf '%s\n' "${count}" >"${count_file}"
    [[ "${MOCK_RECONNECT_MODE:-success}" == success && "${count}" -ge 2 ]]
    ;;
  *sha256sum*) printf '%s  -\n' "${MOCK_REMOTE_SHA256}" ;;
  *) exit 0 ;;
esac
EOF
cat >"${TMP}/power" <<'EOF'
#!/usr/bin/env bash
printf 'power %s\n' "$*" >>"${MOCK_FLASH_LOG}"
EOF
cat >"${TMP}/rkdeveloptool" <<'EOF'
#!/usr/bin/env bash
printf 'rkdeveloptool %s\n' "$*" >>"${MOCK_FLASH_LOG}"
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

if CERALIVE_PREFLASH_BIN="${TMP}/preflash" CERALIVE_SSH_BIN="${TMP}/ssh" \
    "${VERIFY}" "${common[@]}" --image-sha256 "$(printf bad | sha256sum | cut -d' ' -f1)"; then
  printf 'candidate digest mismatch was accepted\n' >&2
  exit 1
fi

if MOCK_RECONNECT_MODE=never MOCK_REMOTE_SHA256="${sha}" MOCK_SSH_COUNT_FILE="${TMP}/count-never" \
    MOCK_FLASH_LOG="${TMP}/flash-never.log" CERALIVE_RK3588_POWER_HELPER="${TMP}/power" \
    RK3588_LOADER="${TMP}/loader.bin" CERALIVE_RKDEVELOPTOOL_BIN="${TMP}/rkdeveloptool" \
    CERALIVE_PREFLASH_BIN="${TMP}/preflash" CERALIVE_SSH_BIN="${TMP}/ssh" \
    CERALIVE_RECONNECT_ATTEMPTS=2 CERALIVE_RECONNECT_DELAY=0 \
    "${VERIFY}" "${common[@]}"; then
  printf 'reconnect exhaustion was accepted\n' >&2
  exit 1
fi

MOCK_RECONNECT_MODE=success MOCK_REMOTE_SHA256="${sha}" MOCK_SSH_COUNT_FILE="${TMP}/count-ok" \
  MOCK_FLASH_LOG="${TMP}/flash-ok.log" CERALIVE_RK3588_POWER_HELPER="${TMP}/power" \
  RK3588_LOADER="${TMP}/loader.bin" CERALIVE_RKDEVELOPTOOL_BIN="${TMP}/rkdeveloptool" \
  CERALIVE_PREFLASH_BIN="${TMP}/preflash" CERALIVE_SSH_BIN="${TMP}/ssh" \
  CERALIVE_RECONNECT_ATTEMPTS=3 CERALIVE_RECONNECT_DELAY=0 \
  "${VERIFY}" "${common[@]}"
grep -qx "candidate_commit=deadbeef" "${TMP}/identity.txt"
grep -qx "raw_sha256=${sha}" "${TMP}/identity.txt"
grep -qx 'post_flash_identity=verified' "${TMP}/identity.txt"
grep -qx 'flash_transport=maskrom-rkdeveloptool' "${TMP}/identity.txt"
grep -qx 'power maskrom' "${TMP}/flash-ok.log"
grep -qx "rkdeveloptool wl 0 ${TMP}/candidate.raw" "${TMP}/flash-ok.log"

printf 'release candidate identity/flash contract: PASS\n'
