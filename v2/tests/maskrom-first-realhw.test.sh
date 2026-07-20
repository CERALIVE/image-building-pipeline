#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2="$(cd "${HERE}/.." && pwd)"
REPO="$(cd "${V2}/.." && pwd)"
VERIFY="${V2}/ci/verify-and-flash-candidate.sh"
UART="${V2}/ci/uart-provision-ssh.sh"
BOOT_SCRIPT="${V2}/mkosi/platform/boot/boot.scr.cmd"
SSH_FIRSTBOOT="${V2}/mkosi/runtime/ceralive-ssh-firstboot.sh"
SSH_FIRSTBOOT_UNIT="${V2}/mkosi/runtime/ceralive-ssh-firstboot.service"
UART_BOOTSTRAP="${V2}/mkosi/runtime/ceralive-ci-uart-bootstrap.sh"
UART_BOOTSTRAP_UNIT="${V2}/mkosi/runtime/ceralive-ci-uart-bootstrap.service"
UART_BOOTSTRAP_PUBLIC="${V2}/mkosi/runtime/ceralive-ci-uart-bootstrap-public.pem"
POSTINST_LIB="${V2}/mkosi/customize/postinst-lib.sh"
RELEASE_WORKFLOW="${REPO}/.github/workflows/release.yml"
REVOKE="${V2}/ci/revoke-ephemeral-ssh.sh"
LOADER_FETCH="${V2}/ci/fetch-rk3588-loader.sh"
DEV_PUSH="${V2}/dev-push"
TMP="$(mktemp -d)"
openssl genpkey -algorithm ED25519 -out "${TMP}/uart-signing.pem" >/dev/null 2>&1
chmod 0600 "${TMP}/uart-signing.pem"
openssl pkey -in "${TMP}/uart-signing.pem" -pubout -out "${TMP}/uart-public.pem" >/dev/null 2>&1
socat_pid=""
sim_pid=""
cleanup() {
  stop_pid "${sim_pid}"
  stop_pid "${socat_pid}"
  rm -rf "${TMP}"
}
stop_pid() {
  local pid="$1"
  [[ -n "${pid}" ]] || return 0
  kill -TERM "${pid}" 2>/dev/null || true
  for _ in $(seq 1 50); do
    kill -0 "${pid}" 2>/dev/null || break
    sleep 0.02
  done
  kill -KILL "${pid}" 2>/dev/null || true
  wait "${pid}" 2>/dev/null || true
}
trap cleanup EXIT

line_of() {
  local pattern="$1" file="$2"
  local line
  line="$(grep -n -m1 -- "${pattern}" "${file}" | cut -d: -f1)"
  [[ "${line}" =~ ^[0-9]+$ ]] || {
    printf 'Maskrom-first regression: missing %s in %s\n' "${pattern}" "${file}" >&2
    exit 1
  }
  printf '%s\n' "${line}"
}

db_function_line="$(line_of '^run_owned_db() {' "${VERIFY}")"
db_startup_int_trap_line="$(line_of 'db_startup_signal=130' "${VERIFY}")"
db_startup_term_trap_line="$(line_of 'db_startup_signal=143' "${VERIFY}")"
db_setsid_line="$(line_of 'setsid bash -c' "${VERIFY}")"
db_pid_capture_line="$(line_of 'db_leader_pid=\$!' "${VERIFY}")"
db_session_owned_line="$(line_of 'db_session_owned=1' "${VERIFY}")"
db_pending_signal_line="$(line_of 'db_startup_signal == 0' "${VERIFY}")"
db_line="$(line_of '^run_owned_db$' "${VERIFY}")"
rfi_line="$(line_of 'run_rkdeveloptool rfi' "${VERIFY}")"
preflight_line="$(line_of --target-size-bytes "${VERIFY}")"
uart_arm_line="$(line_of "\"\${uart_helper}\" --serial-dev" "${VERIFY}")"
write_line="$(line_of 'run_rkdeveloptool wl' "${VERIFY}")"
if ! (( db_function_line < db_line && db_line < rfi_line && rfi_line < preflight_line && preflight_line < uart_arm_line && uart_arm_line < write_line )); then
  printf 'Maskrom-first regression: loader capacity/preflight/write ordering is unsafe\n' >&2
  exit 1
fi
if ! (( db_function_line < db_startup_int_trap_line &&
        db_function_line < db_startup_term_trap_line &&
        db_startup_int_trap_line < db_setsid_line &&
        db_startup_term_trap_line < db_setsid_line &&
        db_setsid_line < db_pid_capture_line &&
        db_pid_capture_line < db_session_owned_line &&
        db_session_owned_line < db_pending_signal_line )); then
  printf 'Maskrom-first regression: loader startup cancellation is not ownership-safe\n' >&2
  exit 1
fi
if grep -Fq 'blockdev --getsize64' "${VERIFY}"; then
  printf 'Maskrom-first regression: verifier still requires pre-flash SSH\n' >&2
  exit 1
fi

[[ -x "${UART}" ]] || {
  printf 'Maskrom-first regression: UART bootstrap helper is absent\n' >&2
  exit 1
}
grep -Fq 'cera_transient_bootargs' "${BOOT_SCRIPT}" || {
  printf 'Maskrom-first regression: boot selector has no volatile UART boot-argument seam\n' >&2
  exit 1
}
if ! grep -Fq 'STATE_DIR="/data/ceralive/ssh"' "${SSH_FIRSTBOOT}" || \
   ! grep -Eq '^ROOT_AUTHORIZED_KEYS=.*root_authorized_keys' "${SSH_FIRSTBOOT}"; then
  printf 'Maskrom-first regression: authorized keys do not persist across A/B slots\n' >&2
  exit 1
fi
if grep -Eq 'ssh-(rsa|ed25519) [A-Za-z0-9+/=]{32,}' "${SSH_FIRSTBOOT}" "${BOOT_SCRIPT}"; then
  printf 'Maskrom-first regression: immutable image source embeds an SSH public key\n' >&2
  exit 1
fi

grep -Fq 'expiry-time=' "${UART}" || {
  printf 'Maskrom-first regression: UART-provisioned key has no bounded expiry\n' >&2
  exit 1
}
grep -Fq 'ConditionKernelCommandLine=ceralive.ci_uart=1' "${UART_BOOTSTRAP_UNIT}"
grep -Fq 'Restart=no' "${UART_BOOTSTRAP_UNIT}"
grep -Fq 'Before=ssh.service ssh.socket' "${SSH_FIRSTBOOT_UNIT}"
grep -Fq 'RequiredBy=ssh.service ssh.socket' "${SSH_FIRSTBOOT_UNIT}" || {
  printf 'Maskrom-first regression: sshd does not require successful CI-key guarding\n' >&2
  exit 1
}
mkdir -p "${TMP}/unit-root/etc/systemd/system"
cp "${SSH_FIRSTBOOT_UNIT}" "${TMP}/unit-root/etc/systemd/system/"
systemctl --root "${TMP}/unit-root" enable ceralive-ssh-firstboot.service >/dev/null
for ssh_unit in ssh.service ssh.socket; do
  [[ -L "${TMP}/unit-root/etc/systemd/system/${ssh_unit}.requires/ceralive-ssh-firstboot.service" ]] || {
    printf 'Maskrom-first regression: %s can start without the CI-key guard\n' "${ssh_unit}" >&2
    exit 1
  }
done
openssl pkey -pubin -in "${UART_BOOTSTRAP_PUBLIC}" -noout
grep -Fq 'ceralive-ci-uart-bootstrap-public.pem' "${POSTINST_LIB}"
if grep -Fq 'PRIVATE KEY' "${UART_BOOTSTRAP_PUBLIC}"; then
  printf 'Maskrom-first regression: immutable image embeds the UART signing private key\n' >&2
  exit 1
fi
if grep -Fq 'systemd.debug_shell' "${UART}" || grep -Fq 'base64 -d | /bin/sh' "${UART}"; then
  printf 'Maskrom-first regression: UART path exposes a general-purpose root shell\n' >&2
  exit 1
fi
if grep -Fq 'systemctl restart ssh.service' "${UART_BOOTSTRAP}"; then
  printf 'Maskrom-first regression: UART bootstrap synchronously starts its ordered-after SSH service\n' >&2
  exit 1
fi
run_workflow_guard() {
  local workflow="$1" name="$2" attempt="$3" script
  script="$(awk -v name="${name}" '
    index($0, "- name: " name) { found=1; next }
    found && $0 ~ /^[[:space:]]+run: \|/ { in_run=1; next }
    in_run && $0 ~ /^      - / { exit }
    in_run { sub(/^          /, ""); print }
  ' "${workflow}")"
  [[ -n "${script}" ]]
  RUN_ATTEMPT="${attempt}" bash -euo pipefail -c "${script}"
}
run_workflow_guard "${RELEASE_WORKFLOW}" 'Reject reruns of immutable release candidates' 1
if run_workflow_guard "${RELEASE_WORKFLOW}" 'Reject reruns of immutable release candidates' 2; then
  printf 'Maskrom-first regression: release rerun guard accepted attempt 2\n' >&2
  exit 1
fi
grep -Fq 'CERALIVE_UART_PUBLIC_KEY_FILE' "${VERIFY}" || {
  printf 'Maskrom-first regression: runner signing key is not bound to the baked verifier key\n' >&2
  exit 1
}
grep -Fq 'boot_nonce' "${UART}" || {
  printf 'Maskrom-first regression: host request is not bound to a device nonce\n' >&2
  exit 1
}
grep -Fq 'ci-epoch-floor' "${UART_BOOTSTRAP}" || {
  printf 'Maskrom-first regression: device does not retain an anti-rollback epoch floor\n' >&2
  exit 1
}
grep -Fq '.retain-once' "${V2}/tests/rauc-rollback.sh" || {
  printf 'Maskrom-first regression: RAUC reboot does not arm boot-scoped SSH retention\n' >&2
  exit 1
}
grep -Fq -- "-name 'srtla-send-rs_*.deb'" "${RELEASE_WORKFLOW}"
if grep -Fq 'path (4.4)' "${V2}/ci/runner-setup.md"; then
  printf 'Maskrom-first regression: runner guide still advertises an SSH/dd production flash path\n' >&2
  exit 1
fi

grep -Fq '26baab70e6b915364f7d73d88298366db1bfc346e34683e95d3d11b52492047f' \
  "${LOADER_FETCH}" || {
  printf 'Maskrom-first regression: loader fetch is not digest-pinned\n' >&2
  exit 1
}
mkdir "${TMP}/loader-output"
if "${LOADER_FETCH}" "${TMP}/loader-output" >/dev/null 2>&1; then
  printf 'Maskrom-first regression: loader fetch accepted a directory output\n' >&2
  exit 1
fi

printf 'serial\n' >"${TMP}/serial"
printf 'private\n' >"${TMP}/id"
: >"${TMP}/known-hosts"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMaskromContractKey test\n' >"${TMP}/id.pub"
cat >"${TMP}/uart-driver" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
request="$(cat "$2")"
read -r version payload_b64 signature_b64 <<<"${request}"
[[ "${version}" == CERALIVE3 ]]
printf '%s' "${payload_b64}" | base64 -d >"${TMPDIR}/uart-payload"
printf '%s' "${signature_b64}" | base64 -d >"${TMPDIR}/uart-signature"
openssl pkeyutl -verify -pubin -inkey "${MOCK_UART_PUBLIC_KEY}" -rawin \
  -in "${TMPDIR}/uart-payload" -sigfile "${TMPDIR}/uart-signature" >/dev/null
payload="$(<"${TMPDIR}/uart-payload")"
grep -Fxq 'host_epoch=4070908800' <<<"${payload}"
grep -Fxq 'challenge=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' <<<"${payload}"
grep -Fxq 'candidate_commit=1111111111111111111111111111111111111111' <<<"${payload}"
grep -Fxq 'boot_nonce=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' <<<"${payload}"
if grep -Fq 'PRIVATE KEY' <<<"${payload}"; then exit 90; fi
printf 'CERALIVE_UART_PROVISIONED aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 1111111111111111111111111111111111111111\n' >"$3"
EOF
chmod +x "${TMP}/uart-driver"
: >"${TMP}/uart-start"
TMPDIR="${TMP}" MOCK_UART_PUBLIC_KEY="${TMP}/uart-public.pem" \
  CERALIVE_UART_BOOT_NONCE=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
CERALIVE_UART_DRIVER="${TMP}/uart-driver" "${UART}" \
  --serial-dev "${TMP}/serial" --authorized-key "${TMP}/id.pub" \
  --access-id gh-123-1 --expires 20990101005000Z --host-epoch 4070908800 \
  --challenge aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --candidate-commit 1111111111111111111111111111111111111111 \
  --signing-key "${TMP}/uart-signing.pem" --start-signal "${TMP}/uart-start" \
  --uart-log "${TMP}/uart.log" --authorized-line-out "${TMP}/authorized-line" \
  --ready-out "${TMP}/uart-ready"
grep -Fxq 'restrict,expiry-time="20990101005000Z" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMaskromContractKey ceralive-ci-gh-123-1' \
  "${TMP}/authorized-line"

cat >"${TMP}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
payload="$(cat)"
grep -Fq '/data/ceralive/ssh/root_authorized_keys' <<<"${payload}"
grep -Fq "awk -v line=\"\${line}\" '\$0 != line'" <<<"${payload}"
grep -Fq 'gh-123-1.retain-once' <<<"${payload}"
printf 'ephemeral_ssh_access=revoked\naccess_id=gh-123-1\n'
EOF
chmod +x "${TMP}/ssh"
PATH="${TMP}:${PATH}" "${REVOKE}" --board-ip 192.0.2.10 --ssh-user root \
  --ssh-port 22 --ssh-identity "${TMP}/id" --known-hosts "${TMP}/known-hosts" \
  --authorized-line "${TMP}/authorized-line" --access-id gh-123-1 \
  --receipt "${TMP}/cleanup-receipt"
grep -Fxq 'ephemeral_ssh_access=revoked' "${TMP}/cleanup-receipt"

mkdir -p "${TMP}/device-state/ci-access" "${TMP}/device-state/ci-nonces"
: >"${TMP}/device-state/root_authorized_keys"
printf '%s\n' 1111111111111111111111111111111111111111 >"${TMP}/image-commit"
cat >"${TMP}/mock-ok" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"${TMP}/mock-date" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ " $* " == *" -d "* ]]; then
  [[ " $* " =~ [[:space:]]2099-01-01T00:(50:00|48:20)Z[[:space:]] ]]
  exec /usr/bin/date "$@"
fi
[[ " $* " == *" -s @4070908800 "* ]]
EOF
chmod +x "${TMP}/mock-ok" "${TMP}/mock-date"
device_payload="$(printf 'access_id=%s\nexpires=%s\nhost_epoch=%s\nchallenge=%s\ncandidate_commit=%s\nboot_nonce=%s\nkey_type=%s\nkey_body=%s\n' \
  gh-123-1 20990101005000Z 4070908800 \
  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  1111111111111111111111111111111111111111 \
  bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ssh-ed25519 \
  AAAAC3NzaC1lZDI1NTE5AAAAIMaskromContractKey)"
printf '%s' "${device_payload}" >"${TMP}/device-payload"
openssl pkeyutl -sign -inkey "${TMP}/uart-signing.pem" -rawin \
  -in "${TMP}/device-payload" -out "${TMP}/device-signature"
printf 'CERALIVE3 %s %s\n' "$(base64 -w0 <"${TMP}/device-payload")" \
  "$(base64 -w0 <"${TMP}/device-signature")" >"${TMP}/device-request"
CERALIVE_UART_STATE_DIR="${TMP}/device-state" \
  CERALIVE_IMAGE_COMMIT_FILE="${TMP}/image-commit" \
  CERALIVE_UART_PUBLIC_KEY_FILE="${TMP}/uart-public.pem" \
  CERALIVE_UART_BOOT_NONCE=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  CERALIVE_UART_VERIFY_ROOT="${TMP}" \
  CERALIVE_UART_DATE_BIN="${TMP}/mock-date" CERALIVE_UART_CHOWN_BIN="${TMP}/mock-ok" \
  CERALIVE_UART_INSTALL_BIN="${TMP}/mock-ok" \
  "${UART_BOOTSTRAP}" <"${TMP}/device-request" >"${TMP}/device-uart.log"
grep -Fxq 'CERALIVE_UART_PROVISIONED aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 1111111111111111111111111111111111111111' \
  "${TMP}/device-uart.log"
grep -Fxq 'challenge=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  "${TMP}/device-state/ci-access/gh-123-1"
grep -Fxq '4070908800' "${TMP}/device-state/ci-epoch-floor"
test -f "${TMP}/device-state/ci-nonces/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

if replay_output="$(CERALIVE_UART_STATE_DIR="${TMP}/device-state" \
  CERALIVE_IMAGE_COMMIT_FILE="${TMP}/image-commit" \
  CERALIVE_UART_PUBLIC_KEY_FILE="${TMP}/uart-public.pem" \
  CERALIVE_UART_BOOT_NONCE=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  CERALIVE_UART_VERIFY_ROOT="${TMP}" \
  CERALIVE_UART_DATE_BIN="${TMP}/mock-date" CERALIVE_UART_CHOWN_BIN="${TMP}/mock-ok" \
  CERALIVE_UART_INSTALL_BIN="${TMP}/mock-ok" \
  "${UART_BOOTSTRAP}" <"${TMP}/device-request" 2>&1)"; then
  printf 'Maskrom-first regression: UART bootstrap replayed a consumed device nonce\n' >&2
  exit 1
fi
[[ "${replay_output}" == *'CERALIVE_UART_BOOTSTRAP_ERROR nonce-replay'* ]]

rollback_payload="${device_payload/host_epoch=4070908800/host_epoch=4070908700}"
rollback_payload="${rollback_payload/expires=20990101005000Z/expires=20990101004820Z}"
rollback_payload="${rollback_payload/boot_nonce=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/boot_nonce=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc}"
printf '%s' "${rollback_payload}" >"${TMP}/rollback-payload"
openssl pkeyutl -sign -inkey "${TMP}/uart-signing.pem" -rawin \
  -in "${TMP}/rollback-payload" -out "${TMP}/rollback-signature"
printf 'CERALIVE3 %s %s\n' "$(base64 -w0 <"${TMP}/rollback-payload")" \
  "$(base64 -w0 <"${TMP}/rollback-signature")" >"${TMP}/rollback-request"
if rollback_output="$(CERALIVE_UART_STATE_DIR="${TMP}/device-state" \
  CERALIVE_IMAGE_COMMIT_FILE="${TMP}/image-commit" \
  CERALIVE_UART_PUBLIC_KEY_FILE="${TMP}/uart-public.pem" \
  CERALIVE_UART_BOOT_NONCE=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc \
  CERALIVE_UART_VERIFY_ROOT="${TMP}" \
  CERALIVE_UART_DATE_BIN="${TMP}/mock-date" CERALIVE_UART_CHOWN_BIN="${TMP}/mock-ok" \
  CERALIVE_UART_INSTALL_BIN="${TMP}/mock-ok" \
  "${UART_BOOTSTRAP}" <"${TMP}/rollback-request" 2>&1)"; then
  printf 'Maskrom-first regression: UART bootstrap accepted a decreasing signed host epoch\n' >&2
  exit 1
fi
[[ "${rollback_output}" == *'CERALIVE_UART_BOOTSTRAP_ERROR epoch-rollback'* ]]

mkdir -p "${TMP}/guard-state/ci-access"
printf '%s\n' \
  'ssh-ed25519 AAAA operator@example' \
  'restrict,expiry-time="20990101005000Z" ssh-ed25519 BBBB ceralive-ci-gh-123-1' \
  'restrict,expiry-time="20990101005000Z" ssh-ed25519 CCCC ceralive-ci-orphan' \
  >"${TMP}/guard-state/root_authorized_keys"
printf 'challenge=test\n' >"${TMP}/guard-state/ci-access/gh-123-1"
CERALIVE_SSH_STATE_DIR="${TMP}/guard-state" CERALIVE_SSH_GUARD_ONLY=1 \
  bash "${SSH_FIRSTBOOT}"
grep -Fxq 'ssh-ed25519 AAAA operator@example' "${TMP}/guard-state/root_authorized_keys"
if grep -Fq 'ceralive-ci-' "${TMP}/guard-state/root_authorized_keys" || \
   [[ -e "${TMP}/guard-state/ci-access/gh-123-1" ]]; then
  printf 'Maskrom-first regression: cold boot retained unarmed CI SSH access\n' >&2
  exit 1
fi

printf '%s\n' \
  'ssh-ed25519 AAAA operator@example' \
  'restrict,expiry-time="20990101005000Z" ssh-ed25519 BBBB ceralive-ci-gh-123-1' \
  >"${TMP}/guard-state/root_authorized_keys"
printf 'challenge=test\n' >"${TMP}/guard-state/ci-access/gh-123-1"
printf 'access_id=gh-123-1\n' >"${TMP}/guard-state/ci-access/gh-123-1.retain-once"
CERALIVE_SSH_STATE_DIR="${TMP}/guard-state" CERALIVE_SSH_GUARD_ONLY=1 \
  bash "${SSH_FIRSTBOOT}"
grep -Fq 'ceralive-ci-gh-123-1' "${TMP}/guard-state/root_authorized_keys"
[[ ! -e "${TMP}/guard-state/ci-access/gh-123-1.retain-once" ]]
CERALIVE_SSH_STATE_DIR="${TMP}/guard-state" CERALIVE_SSH_GUARD_ONLY=1 \
  bash "${SSH_FIRSTBOOT}"
if grep -Fq 'ceralive-ci-gh-123-1' "${TMP}/guard-state/root_authorized_keys"; then
  printf 'Maskrom-first regression: one-shot reboot retention was reusable\n' >&2
  exit 1
fi

mkdir -p "${TMP}/guard-orphan-state"
printf '%s\n' \
  'ssh-ed25519 AAAA operator@example' \
  'restrict,expiry-time="20990101005000Z" ssh-ed25519 DDDD ceralive-ci-orphan-without-directory' \
  >"${TMP}/guard-orphan-state/root_authorized_keys"
CERALIVE_SSH_STATE_DIR="${TMP}/guard-orphan-state" CERALIVE_SSH_GUARD_ONLY=1 \
  bash "${SSH_FIRSTBOOT}"
grep -Fxq 'ssh-ed25519 AAAA operator@example' "${TMP}/guard-orphan-state/root_authorized_keys"
if grep -Fq 'ceralive-ci-' "${TMP}/guard-orphan-state/root_authorized_keys"; then
  printf 'Maskrom-first regression: absent ci-access directory retained an orphan CI key\n' >&2
  exit 1
fi

access_store_line="$(line_of 'fail access-store' "${UART_BOOTSTRAP}")"
key_publish_line="$(line_of 'authorized_line=' "${UART_BOOTSTRAP}")"
if ! (( access_store_line < key_publish_line )); then
  printf 'Maskrom-first regression: UART key publication precedes access-store creation\n' >&2
  exit 1
fi

wrong_payload="${device_payload/1111111111111111111111111111111111111111/2222222222222222222222222222222222222222}"
printf '%s' "${wrong_payload}" >"${TMP}/wrong-payload"
openssl pkeyutl -sign -inkey "${TMP}/uart-signing.pem" -rawin \
  -in "${TMP}/wrong-payload" -out "${TMP}/wrong-signature"
printf 'CERALIVE3 %s %s\n' "$(printf '%s' "${wrong_payload}" | base64 -w0)" \
  "$(base64 -w0 <"${TMP}/wrong-signature")" >"${TMP}/wrong-request"
if CERALIVE_UART_STATE_DIR="${TMP}/device-state" \
  CERALIVE_IMAGE_COMMIT_FILE="${TMP}/image-commit" \
  CERALIVE_UART_PUBLIC_KEY_FILE="${TMP}/uart-public.pem" \
  CERALIVE_UART_BOOT_NONCE=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  CERALIVE_UART_VERIFY_ROOT="${TMP}" \
  CERALIVE_UART_DATE_BIN="${TMP}/mock-ok" CERALIVE_UART_CHOWN_BIN="${TMP}/mock-ok" \
  CERALIVE_UART_INSTALL_BIN="${TMP}/mock-ok" \
  "${UART_BOOTSTRAP}" <"${TMP}/wrong-request" >/dev/null 2>&1; then
  printf 'Maskrom-first regression: UART bootstrap accepted a mismatched candidate commit\n' >&2
  exit 1
fi

printf 'X' | dd of="${TMP}/wrong-signature" bs=1 seek=0 conv=notrunc status=none
printf 'CERALIVE3 %s %s\n' "$(base64 -w0 <"${TMP}/device-payload")" \
  "$(base64 -w0 <"${TMP}/wrong-signature")" >"${TMP}/tampered-request"
if CERALIVE_UART_STATE_DIR="${TMP}/device-state" \
  CERALIVE_IMAGE_COMMIT_FILE="${TMP}/image-commit" \
  CERALIVE_UART_PUBLIC_KEY_FILE="${TMP}/uart-public.pem" \
  CERALIVE_UART_BOOT_NONCE=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  CERALIVE_UART_VERIFY_ROOT="${TMP}" \
  CERALIVE_UART_DATE_BIN="${TMP}/mock-ok" CERALIVE_UART_CHOWN_BIN="${TMP}/mock-ok" \
  CERALIVE_UART_INSTALL_BIN="${TMP}/mock-ok" \
  "${UART_BOOTSTRAP}" <"${TMP}/tampered-request" >/dev/null 2>&1; then
  printf 'Maskrom-first regression: UART bootstrap accepted a forged request\n' >&2
  exit 1
fi

mkdir -p "${TMP}/debwork/data/usr/bin" "${TMP}/debwork/control" "${TMP}/debs"
printf '#!/bin/sh\nexit 0\n' >"${TMP}/debwork/data/usr/bin/srtla_send"
chmod +x "${TMP}/debwork/data/usr/bin/srtla_send"
printf 'Package: srtla\nVersion: 1\nArchitecture: arm64\nMaintainer: CI <ci@example.invalid>\nDescription: transport fixture\n' \
  >"${TMP}/debwork/control/control"
( cd "${TMP}/debwork/data" && tar -czf ../data.tar.gz . )
( cd "${TMP}/debwork/control" && tar -czf ../control.tar.gz . )
printf '2.0\n' >"${TMP}/debwork/debian-binary"
( cd "${TMP}/debwork" && ar rc "${TMP}/debs/srtla_1_arm64.deb" debian-binary control.tar.gz data.tar.gz )
DRY_RUN=1 SSH_USER=root SSH_PORT=2222 SSH_IDENTITY_FILE="${TMP}/id" \
  SSH_KNOWN_HOSTS_FILE="${TMP}/known-hosts" \
  "${DEV_PUSH}" --from-deb "${TMP}/debs" 192.0.2.10 srtla >"${TMP}/dev-push.log" 2>&1
grep -Eq "DRY-RUN ssh: ssh .*IdentitiesOnly=yes -i ${TMP}/id .*UserKnownHostsFile=${TMP}/known-hosts .* -p 2222 root@192.0.2.10" \
  "${TMP}/dev-push.log"
grep -Eq "DRY-RUN scp: scp -r .*IdentitiesOnly=yes -i ${TMP}/id .*UserKnownHostsFile=${TMP}/known-hosts .* -P 2222 .*root@192.0.2.10" \
  "${TMP}/dev-push.log"

command -v socat >/dev/null
pty="${TMP}/pty"
mkdir -p "${pty}"
socat PTY,raw,echo=0,link="${pty}/runner" PTY,raw,echo=0,link="${pty}/sim" &
socat_pid=$!
for _ in $(seq 1 100); do
  [[ -e "${pty}/runner" && -e "${pty}/sim" ]] && break
  sleep 0.02
done
[[ -e "${pty}/runner" && -e "${pty}/sim" ]]
ssh-keygen -q -t ed25519 -N '' -f "${pty}/id_ed25519"
: >"${pty}/uart-start"
exec {locked_uart_fd}<>"${pty}/runner"
flock -n "${locked_uart_fd}"
if timeout 5s env CERALIVE_UART_ARM_TIMEOUT_SECONDS=1 "${UART}" \
  --serial-dev "${pty}/runner" --authorized-key "${pty}/id_ed25519.pub" \
  --access-id locked-contract --expires 20990101005000Z --host-epoch 4070908800 \
  --challenge aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --candidate-commit 1111111111111111111111111111111111111111 \
  --signing-key "${TMP}/uart-signing.pem" --start-signal "${pty}/uart-start" \
  --uart-log "${pty}/locked.log" --authorized-line-out "${pty}/locked-line" \
  --ready-out "${pty}/locked-ready" >/dev/null 2>&1; then
  printf 'Maskrom-first regression: UART helper accepted an already-locked serial device\n' >&2
  exit 1
fi
[[ ! -e "${pty}/locked-ready" ]]
flock -u "${locked_uart_fd}"
exec {locked_uart_fd}>&-
python3 -c '
import os
import sys

fd = os.open(sys.argv[1], os.O_RDWR | os.O_NOCTTY)
with open(sys.argv[2], "w", encoding="ascii"):
    pass
line = bytearray()
prompted = False
while True:
    for byte in os.read(fd, 4096):
        if byte == 32 and not line and not prompted:
            os.write(fd, b"\r\n=> ")
            prompted = True
        elif byte == 13:
            command = bytes(line)
            if b"setenv cera_transient_bootargs" in command:
                os.write(fd, b"\r\n=> ")
            elif command == b"run bootcmd":
                os.write(fd, b"\r\nCERALIVE_UART_BOOTSTRAP_READY bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\r\n")
            elif command.startswith(b"CERALIVE3 "):
                os.write(fd, b"\r\nCERALIVE_UART_PROVISIONED aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 1111111111111111111111111111111111111111\r\n")
                raise SystemExit(0)
            line.clear()
        else:
            line.append(byte)
' "${pty}/sim" "${pty}/sim-ready" &
sim_pid=$!
for _ in $(seq 1 100); do
  [[ -e "${pty}/sim-ready" ]] && break
  sleep 0.02
done
[[ -e "${pty}/sim-ready" ]]
timeout 20s env CERALIVE_UBOOT_TIMEOUT_SECONDS=5 \
  CERALIVE_BOOTSTRAP_TIMEOUT_SECONDS=5 CERALIVE_PROVISION_TIMEOUT_SECONDS=5 \
  "${UART}" --serial-dev "${pty}/runner" --authorized-key "${pty}/id_ed25519.pub" \
  --access-id pty-contract --expires 20990101005000Z --host-epoch 4070908800 \
  --challenge aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --candidate-commit 1111111111111111111111111111111111111111 \
  --signing-key "${TMP}/uart-signing.pem" --start-signal "${pty}/uart-start" \
  --uart-log "${pty}/uart.log" --authorized-line-out "${pty}/authorized-line" \
  --ready-out "${pty}/uart-ready"
wait "${sim_pid}"
sim_pid=""
grep -Fq CERALIVE_UART_PROVISIONED "${pty}/uart.log"

printf 'Maskrom-first real-HW contract: PASS\n'
