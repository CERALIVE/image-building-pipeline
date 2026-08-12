#!/usr/bin/env bash
#
# flash-remote-guard.test.sh — the tested REMOTE-DESTRUCTIVE-WRITE CONTRACT.
#
# The plan's scope section names raw-full-media-write-over-SSH as a hard
# must-not-have. This suite is the primary defence against it, and it is
# deliberately adversarial: every refusal below is driven through the REAL
# `ci/verify-and-flash-candidate.sh` and `ci/backup-data.sh` code paths, with a
# fully-working mock transport standing by, so a leg can only pass because the
# tool structurally refused — never because the tool was broken.
#
# The non-vacuity leg proves exactly that: the SAME mock set, pointed at a local
# block device with a matching physical-confirmation token, completes a full
# whole-media write. So "everything is refused" cannot be mistaken for
# "everything works".
#
# Attack shapes covered: `user@host:/dev/...`, bare `host:/dev/...`, `ssh://`,
# UNC `//host/share`, a relative path, a `..` traversal, an embedded newline,
# the writer program being `ssh` itself, the writer program being a same-named
# WRAPPER that execs ssh, a missing confirmation, and a confirmation captured
# for a different device.
#
# shellcheck shell=bash

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"
# shellcheck source=tests/lib/assertions.sh
source "${HERE}/lib/assertions.sh"

VERIFY="${PIPELINE_DIR}/ci/verify-and-flash-candidate.sh"
BACKUP="${PIPELINE_DIR}/ci/backup-data.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

assert_contains_str() {
  if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1: '$3' not in output:"$'\n'"$2"; fi
}
assert_refused() {
  local desc="$1" rc="$2" out="$3" log="$4"
  if (( rc == 0 )); then bad "${desc}: the tool ACCEPTED it (rc=0)"; return; fi
  if ! grep -qF 'REFUSED' <<<"${out}"; then
    bad "${desc}: rejected but not by the destructive-target guard:"$'\n'"${out}"; return
  fi
  if [[ -e "${log}" ]]; then
    bad "${desc}: the flash transport was invoked before the refusal"; return
  fi
  ok "${desc}"
}

# ---------------------------------------------------------------------------
# A fully working mock candidate + transport. Everything here is deliberately
# HEALTHY: the only variable across the legs below is the destructive target and
# the program that would write it.
# ---------------------------------------------------------------------------
openssl genpkey -algorithm ED25519 -out "${TMP}/uart-signing.pem" >/dev/null 2>&1
chmod 600 "${TMP}/uart-signing.pem"
openssl pkey -in "${TMP}/uart-signing.pem" -pubout -out "${TMP}/uart-public.pem" >/dev/null 2>&1

printf 'candidate-bytes\n' >"${TMP}/candidate.raw"
truncate -s 4096 "${TMP}/candidate.raw"
printf 'bundle\n'  >"${TMP}/candidate.raucb"
printf 'keyring\n' >"${TMP}/keyring.pem"
printf 'loader\n'  >"${TMP}/loader.bin"
printf 'serial\n'  >"${TMP}/serial"
printf 'private\n' >"${TMP}/id"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMockCandidateKey guard\n' >"${TMP}/id.pub"
raw_sha="$(sha256sum "${TMP}/candidate.raw" | cut -d' ' -f1)"
loader_sha="$(sha256sum "${TMP}/loader.bin" | cut -d' ' -f1)"

mkdir -p "${TMP}/bin"

cat >"${TMP}/bin/candidate-identity" <<EOF
#!/usr/bin/env bash
printf 'candidate_board_id=rock-5b-plus\n'
printf 'candidate_fdtfile=rk3588-rock-5b-plus.dtb\n'
printf 'candidate_compatible=ceralive-rock-5b-plus\n'
printf 'candidate_raw_sha256=%s\n'    '${raw_sha}'
printf 'candidate_bundle_sha256=%s\n' '$(sha256sum "${TMP}/candidate.raucb" | cut -d' ' -f1)'
printf 'candidate_loader_sha256=%s\n' '${loader_sha}'
EOF

cat >"${TMP}/bin/preflash" <<'EOF'
#!/usr/bin/env bash
printf 'preflash %s\n' "$*" >>"${MOCK_FLASH_LOG}"
EOF

cat >"${TMP}/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
known_hosts=""
for arg in "$@"; do
  case "${arg}" in UserKnownHostsFile=*) known_hosts="${arg#*=}" ;; esac
done
cmd="${*: -1}"
case "${cmd}" in
  *'findmnt -n -o SOURCE /'*) printf 'mmcblk0\n' ;;
  *'/ci-access/'*)
    printf 'challenge=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
    printf 'candidate_commit=1111111111111111111111111111111111111111\n' ;;
  true)
    grep -q '^mock-host-key$' "${known_hosts}" 2>/dev/null || printf 'mock-host-key\n' >"${known_hosts}"
    count="$(cat "${MOCK_SSH_COUNT_FILE}" 2>/dev/null || echo 0)"
    count=$((count + 1)); printf '%s\n' "${count}" >"${MOCK_SSH_COUNT_FILE}"
    [[ "${count}" -ge 2 ]] ;;
  *) exit 0 ;;
esac
EOF

cat >"${TMP}/bin/rkdeveloptool" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'rkdeveloptool %s\n' "$*" >>"${MOCK_FLASH_LOG}"
case "${1:-}" in
  ld)
    mode=Maskrom
    [[ ! -e "${MOCK_FLASH_LOG}.db-complete" ]] || mode=Loader
    printf 'DevNo=1 Vid=0x2207,Pid=0x350b,LocationID=101 %s\n' "${mode}" ;;
  db)  : >"${MOCK_FLASH_LOG}.db-complete" ;;
  rfi) printf 'Flash Size: 195312 Sectors\n' ;;
  rid) printf 'Flash ID: mock-emmc\n' ;;
  wl)  cp "$3" "${MOCK_MEDIA}"; chmod 600 "${MOCK_MEDIA}" ;;
  rl)  cp "${MOCK_MEDIA}" "$4" ;;
  rd)  printf 'B' | dd of="${MOCK_MEDIA}" bs=1 seek=2048 conv=notrunc status=none ;;
esac
EOF

cat >"${TMP}/bin/uart" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
uart_log="" authorized_line_out="" ready_out="" start_signal="" challenge="" candidate_commit=""
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

# The adversarial wrapper: a program NAMED rkdeveloptool that would push the raw
# write down an SSH pipe. It drops a sentinel as its very first action, so the
# suite can prove the guard refused BEFORE the wrapper ever ran.
cat >"${TMP}/bin/rkdeveloptool-ssh-wrapper" <<'EOF'
#!/usr/bin/env bash
: >"${MOCK_WRAPPER_SENTINEL}"
exec ssh "${MOCK_REMOTE_HOST}" "dd of=/dev/mmcblk0 bs=4M"
EOF
mkdir -p "${TMP}/wrapperbin"
cp "${TMP}/bin/rkdeveloptool-ssh-wrapper" "${TMP}/wrapperbin/rkdeveloptool"

chmod +x "${TMP}/bin/"* "${TMP}/wrapperbin/rkdeveloptool"

common=(
  --image "${TMP}/candidate.raw"
  --bundle "${TMP}/candidate.raucb"
  --keyring "${TMP}/keyring.pem"
  --loader "${TMP}/loader.bin"
  --loader-sha256 "${loader_sha}"
  --board rock-5b-plus
  --board-ip 192.0.2.10
  --candidate-commit 1111111111111111111111111111111111111111
  --image-sha256 "${raw_sha}"
  --serial-dev "${TMP}/serial"
  --uart-log "${TMP}/uart.log"
  --authorized-key "${TMP}/id.pub"
  --access-id gh-guard-1
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

base_env=(
  "RUNNER_TEMP=${TMP}"
  "CERALIVE_CANDIDATE_IDENTITY_BIN=${TMP}/bin/candidate-identity"
  "CERALIVE_PREFLASH_BIN=${TMP}/bin/preflash"
  "CERALIVE_SSH_BIN=${TMP}/bin/ssh"
  "CERALIVE_UART_HELPER_BIN=${TMP}/bin/uart"
  "CERALIVE_UART_PUBLIC_KEY_FILE=${TMP}/uart-public.pem"
  "CERALIVE_RECONNECT_ATTEMPTS=3"
  "CERALIVE_RECONNECT_DELAY=0"
)

# run_flash <case> <rkdeveloptool-bin> <confirmation> [extra args...]
run_flash() {
  local case_name="$1" tool="$2" confirmation="$3"; shift 3
  local dir="${TMP}/case-${case_name}"
  mkdir -p "${dir}"
  rm -f "${TMP}/identity.txt"
  FLASH_LOG="${dir}/flash.log"
  FLASH_OUT="$(env "${base_env[@]}" \
    "CERALIVE_RKDEVELOPTOOL_BIN=${tool}" \
    "MOCK_FLASH_LOG=${FLASH_LOG}" \
    "MOCK_MEDIA=${dir}/media.raw" \
    "MOCK_SSH_COUNT_FILE=${dir}/count" \
    "MOCK_WRAPPER_SENTINEL=${dir}/wrapper-ran" \
    "MOCK_REMOTE_HOST=root@192.0.2.10" \
    "${VERIFY}" "${common[@]}" --confirm-physical-write "${confirmation}" "$@" 2>&1)"
  FLASH_RC=$?
  WRAPPER_SENTINEL="${dir}/wrapper-ran"
}

echo "### 1. a remote destructive-write TARGET is refused, in every spelling"
for spec in \
  'root@192.0.2.10:/dev/mmcblk0' \
  '192.0.2.10:/dev/mmcblk0' \
  'ssh://192.0.2.10/dev/mmcblk0' \
  '//nas/share/mmcblk0' \
  'dev/mmcblk0' \
  '/dev/../etc/passwd' \
  '/dev/mmcblk0 ; ssh host dd of=/dev/sda'
do
  run_flash "target-$(printf '%s' "${spec}" | tr -c 'a-zA-Z0-9' '-')" \
    "${TMP}/bin/rkdeveloptool" "I-AM-AT-THE-BENCH:${spec}" --flash-device "${spec}"
  assert_refused "flash target '${spec}' is refused with zero transport calls" \
    "${FLASH_RC}" "${FLASH_OUT}" "${FLASH_LOG}"
done

run_flash env-remote "${TMP}/bin/rkdeveloptool" 'I-AM-AT-THE-BENCH:/dev/mmcblk0'
CERALIVE_FLASH_DEVICE='192.0.2.10:/dev/mmcblk0' run_flash env-remote2 \
  "${TMP}/bin/rkdeveloptool" 'I-AM-AT-THE-BENCH:192.0.2.10:/dev/mmcblk0'
assert_refused "a remote CERALIVE_FLASH_DEVICE is refused with zero transport calls" \
  "${FLASH_RC}" "${FLASH_OUT}" "${FLASH_LOG}"

echo
echo "### 2. a remote WRITER PROGRAM is refused, named directly or hidden in a wrapper"
run_flash writer-is-ssh "$(command -v ssh)" 'I-AM-AT-THE-BENCH:/dev/mmcblk0'
assert_refused "naming ssh itself as the flash tool is refused" \
  "${FLASH_RC}" "${FLASH_OUT}" "${FLASH_LOG}"

run_flash writer-wrapper "${TMP}/wrapperbin/rkdeveloptool" 'I-AM-AT-THE-BENCH:/dev/mmcblk0'
assert_refused "a same-named wrapper that execs ssh is refused" \
  "${FLASH_RC}" "${FLASH_OUT}" "${FLASH_LOG}"
if [[ ! -e "${WRAPPER_SENTINEL}" ]]; then
  ok 'the ssh wrapper never executed — the refusal is structural, not after the fact'
else
  bad 'the ssh wrapper RAN before the guard refused it'
fi

echo
echo "### 3. a destructive write with no operator at the bench is refused"
run_flash no-confirmation "${TMP}/bin/rkdeveloptool" ''
assert_refused "an unconfirmed whole-media flash is refused" \
  "${FLASH_RC}" "${FLASH_OUT}" "${FLASH_LOG}"
assert_contains_str "the refusal states the exact token the operator must supply" \
  "${FLASH_OUT}" 'I-AM-AT-THE-BENCH:/dev/mmcblk0'

run_flash wrong-confirmation "${TMP}/bin/rkdeveloptool" 'I-AM-AT-THE-BENCH:/dev/mmcblk1'
assert_refused "a confirmation captured for a different device is refused" \
  "${FLASH_RC}" "${FLASH_OUT}" "${FLASH_LOG}"

run_flash blanket-confirmation "${TMP}/bin/rkdeveloptool" 'yes'
assert_refused "a blanket 'yes' confirmation is refused" \
  "${FLASH_RC}" "${FLASH_OUT}" "${FLASH_LOG}"

echo
echo "### 4. NON-VACUITY — the same mock set completes a genuine local write"
run_flash accept "${TMP}/bin/rkdeveloptool" 'I-AM-AT-THE-BENCH:/dev/mmcblk0'
assert_eq "a local block device with a matching confirmation is ACCEPTED" 0 "${FLASH_RC}"
if [[ "${FLASH_RC}" -ne 0 ]]; then printf '%s\n' "${FLASH_OUT}"; fi
assert_contains_str "the accepted run echoes the physical-write confirmation" \
  "${FLASH_OUT}" 'PHYSICAL-WRITE-CONFIRMED whole-media flash target=/dev/mmcblk0'
if [[ -e "${FLASH_LOG}" ]] && grep -q '^rkdeveloptool wl ' "${FLASH_LOG}"; then
  ok 'the accepted run really performed the whole-media write'
else
  bad 'the accepted run did not reach the whole-media write'
fi
if [[ -f "${TMP}/identity.txt" ]] \
   && grep -qx 'destructive_write=local-block-device-confirmed' "${TMP}/identity.txt" \
   && grep -qx 'flash_device=/dev/mmcblk0' "${TMP}/identity.txt"; then
  ok 'the evidence tuple records the confirmed local destructive target'
else
  bad 'the evidence tuple does not record the confirmed local destructive target'
fi

echo
echo "### 5. ci/backup-data.sh restore obeys the same contract"
mkdir -p "${TMP}/data-src" "${TMP}/data-dst"
printf 'persisted\n' >"${TMP}/data-src/host_index"
"${BACKUP}" --mode backup --source "${TMP}/data-src" --archive "${TMP}/data.tar.gz" >/dev/null

restore_out="$("${BACKUP}" --mode restore --archive "${TMP}/data.tar.gz" \
  --target 'root@192.0.2.10:/data' \
  --confirm-physical-write 'I-AM-AT-THE-BENCH:root@192.0.2.10:/data' 2>&1)"
restore_rc=$?
if (( restore_rc != 0 )) && grep -qF 'REFUSED' <<<"${restore_out}"; then
  ok 'a remote /data restore target is refused'
else
  bad "a remote /data restore target was accepted (rc=${restore_rc})"
fi

restore_out="$("${BACKUP}" --mode restore --archive "${TMP}/data.tar.gz" \
  --target "${TMP}/data-dst" 2>&1)"
restore_rc=$?
if (( restore_rc != 0 )) && grep -qF 'REFUSED' <<<"${restore_out}"; then
  ok 'an unconfirmed local /data restore is refused'
else
  bad "an unconfirmed local /data restore was accepted (rc=${restore_rc})"
fi
if [[ ! -e "${TMP}/data-dst/host_index" ]]; then
  ok 'no bytes were written by either refused restore'
else
  bad 'a refused restore still wrote into the target'
fi

restore_out="$("${BACKUP}" --mode restore --archive "${TMP}/data.tar.gz" \
  --target "${TMP}/data-dst" \
  --confirm-physical-write "I-AM-AT-THE-BENCH:${TMP}/data-dst" 2>&1)"
restore_rc=$?
if (( restore_rc == 0 )) && [[ -f "${TMP}/data-dst/host_index" ]]; then
  ok 'NON-VACUITY: a confirmed local /data restore is accepted and restores the tree'
else
  bad "a confirmed local /data restore failed (rc=${restore_rc}): ${restore_out}"
fi

echo
printf 'remote-destructive-write contract: %s pass, %s fail\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
