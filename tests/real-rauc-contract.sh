#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"
WORK="$(mktemp -d /tmp/ceralive-rauc-contract.XXXXXX)"
CONF="${WORK}/system.conf"
BUNDLE="${WORK}/bundle/probe.raucb"
service_pid=""
client_pid=""

stop_service() {
  if [[ -n "${service_pid}" ]] && kill -0 "${service_pid}" 2>/dev/null; then
    sudo -n kill -TERM "${service_pid}" 2>/dev/null || true
  fi
  if [[ -n "${service_pid}" ]]; then
    wait "${service_pid}" 2>/dev/null || true
    service_pid=""
  fi
}

stop_descendants() {
  local pid
  local -a pids=()
  mapfile -t pids < <(pgrep -f "${WORK}/" 2>/dev/null || true)
  for pid in "${pids[@]}"; do
    sudo -n kill -TERM "${pid}" 2>/dev/null || true
  done
  for _ in $(seq 1 20); do
    mapfile -t pids < <(pgrep -f "${WORK}/" 2>/dev/null || true)
    (( ${#pids[@]} == 0 )) && return 0
    sleep 0.1
  done
  for pid in "${pids[@]}"; do
    sudo -n kill -KILL "${pid}" 2>/dev/null || true
  done
  for _ in $(seq 1 20); do
    pgrep -f "${WORK}/" >/dev/null 2>&1 || return 0
    sleep 0.1
  done
  return 1
}

cleanup() {
  local target source loop backing leaked=0
  if [[ -n "${client_pid}" ]] && kill -0 "${client_pid}" 2>/dev/null; then
    kill -TERM "${client_pid}" 2>/dev/null || true
    wait "${client_pid}" 2>/dev/null || true
  fi
  stop_service
  stop_descendants
  while read -r target source; do
    [[ -n "${target}" ]] || continue
    backing=""
    [[ "${source}" == /dev/loop* ]] && backing="$(losetup -n -O BACK-FILE "${source}" 2>/dev/null || true)"
    if [[ "${source}" == "${WORK}"/* || "${backing}" == "${WORK}"/* ]]; then
      sudo -n umount "${target}" 2>/dev/null || true
    fi
  done < <(findmnt -rn -o TARGET,SOURCE 2>/dev/null || true)
  while read -r loop backing; do
    [[ "${backing}" == "${WORK}"/* ]] || continue
    sudo -n losetup -d "${loop}" 2>/dev/null || true
  done < <(losetup -l -n -O NAME,BACK-FILE 2>/dev/null || true)
  while read -r _ source; do
    [[ "${source}" == "${WORK}"/* ]] && leaked=1
  done < <(findmnt -rn -o TARGET,SOURCE 2>/dev/null || true)
  while read -r _ backing; do
    [[ "${backing}" == "${WORK}"/* ]] && leaked=1
  done < <(losetup -l -n -O NAME,BACK-FILE 2>/dev/null || true)
  pgrep -f "${WORK}/" >/dev/null 2>&1 && leaked=1
  sudo -n rm -rf "${WORK}"
  (( leaked == 0 ))
}

on_exit() {
  local rc=$?
  trap - EXIT INT TERM
  cleanup || { printf 'real RAUC cleanup left a harness mount or loop\n' >&2; (( rc == 0 )) && rc=1; }
  exit "${rc}"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

start_service() {
  local log="$1" _
  run_service() { exec sudo -n rauc -d -c "${CONF}" service --override-boot-slot=A; }
  run_service >"${log}" 2>&1 &
  service_pid=$!
  for _ in $(seq 1 100); do
    rauc -c "${CONF}" status >/dev/null 2>&1 && return 0
    kill -0 "${service_pid}" 2>/dev/null || break
    sleep 0.1
  done
  sed -n '1,200p' "${log}" >&2
  return 1
}

state() {
  sudo -n env CERALIVE_BOOT_STATE_FILE="${WORK}/boot_state.txt" \
    CERALIVE_BOOT_STATE_BIN="${WORK}/ceralive-boot-state.sh" \
    CERALIVE_BOOT_STATE_CORE="${WORK}/boot-state-core.sh" CERALIVE_BOOT_ATTEMPTS=3 \
    bash "${WORK}/ceralive-boot-state.sh" "$@"
}

exec 9>/tmp/ceralive-real-rauc-contract.lock
flock 9
for tool in rauc mkfs.ext4 debugfs findmnt losetup sudo timeout flock; do
  command -v "${tool}" >/dev/null 2>&1 || { printf 'missing real RAUC prerequisite: %s\n' "${tool}" >&2; exit 127; }
done
sudo -n true
mkdir -p "${WORK}"/{bundle,data,pki,slot-a-tree/{etc,sbin},slot-b-tree/{etc,sbin},update-tree/{etc,sbin}}
for tree in slot-a-tree slot-b-tree update-tree; do
  printf '#!/bin/sh\nexit 0\n' >"${WORK}/${tree}/sbin/init"
  chmod +x "${WORK}/${tree}/sbin/init"
done
printf 'factory-slot-a\n' >"${WORK}/slot-a-tree/etc/ceralive-rauc-probe"
printf 'factory-slot-b\n' >"${WORK}/slot-b-tree/etc/ceralive-rauc-probe"
printf 'updated-arm64-bundle\n' >"${WORK}/update-tree/etc/ceralive-rauc-probe"
truncate -s 64M "${WORK}/slot-a.ext4" "${WORK}/slot-b.ext4"
mkfs.ext4 -q -F -L rootfs_a -d "${WORK}/slot-a-tree" "${WORK}/slot-a.ext4"
mkfs.ext4 -q -F -L rootfs_b -d "${WORK}/slot-b-tree" "${WORK}/slot-b.ext4"
cp "${PIPELINE_DIR}/mkosi/platform/boot/ceralive-boot-state.sh" "${WORK}/ceralive-boot-state.sh"
# The adapter SOURCES the shared slot-state core, resolving it as a repo-relative
# sibling or at its installed device path. A mktemp staging dir is neither, so the
# core must be staged with it and named via CERALIVE_BOOT_STATE_CORE at every call.
cp "${PIPELINE_DIR}/mkosi/platform/boot-state-core.sh" "${WORK}/boot-state-core.sh"
cp "${PIPELINE_DIR}/mkosi/platform/boot/ceralive-rauc-boot-adapter.sh" "${WORK}/ceralive-rauc-boot-adapter.sh"
chmod +x "${WORK}"/ceralive-*.sh
ln -s "${PIPELINE_DIR}/.dev-keys/dev-root-ca.pem" "${WORK}/pki/root-ca.pem"
ln -s "${PIPELINE_DIR}/.dev-keys/dev-chain.pem" "${WORK}/pki/chain.pem"
ln -s "${PIPELINE_DIR}/.dev-keys/dev-leaf-signing.pem" "${WORK}/pki/leaf-signing.pem"
ln -s "${PIPELINE_DIR}/.dev-keys/dev-leaf-signing.key" "${WORK}/pki/leaf-signing.key"

cat >"${WORK}/backend.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
work="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
printf '%s\n' "$*" >>"${work}/backend.calls"
CERALIVE_BOOT_STATE_FILE="${work}/boot_state.txt" CERALIVE_BOOT_STATE_BIN="${work}/ceralive-boot-state.sh" \
  CERALIVE_BOOT_STATE_CORE="${work}/boot-state-core.sh" \
  CERALIVE_KERNEL_CMDLINE_FILE="${work}/cmdline" CERALIVE_BOOT_ATTEMPTS=3 \
  bash "${work}/ceralive-rauc-boot-adapter.sh" "$@"
if [[ -f "${work}/interrupt" && "$*" == "set-state B bad" ]]; then
  touch "${work}/interruption-checkpoint"
  sleep 30
fi
EOF
chmod +x "${WORK}/backend.sh"
touch "${WORK}/backend.calls"
chmod 0666 "${WORK}/backend.calls"
printf 'root=PARTLABEL=rootfs_a rauc.slot=A rw\n' >"${WORK}/cmdline"

generated_root="${WORK}/generated-root"
ROOT="${generated_root}" SERIAL_CONSOLE="ttyS2:1500000" \
  DTB_NAME="rk3588-rock-5b-plus.dtb" BOARD_ID="rock-5b-plus" \
  COMPATIBLE_STRING="ceralive-rock-5b-plus" SINGLE_SLOT_FALLBACK="false" \
  bash "${PIPELINE_DIR}/mkosi/platform/boot/install-boot.sh" rootfs >/dev/null
sed -e "/^bootloader=custom$/a data-directory=${WORK}/data" \
  -e "s|^bootloader-custom-backend=.*$|bootloader-custom-backend=${WORK}/backend.sh|" \
  -e "s|^path=/etc/rauc/ceralive-keyring.pem$|path=${WORK}/pki/root-ca.pem|" \
  -e "s|^device=/dev/disk/by-partlabel/rootfs_a$|device=${WORK}/slot-a.ext4|" \
  -e "s|^device=/dev/disk/by-partlabel/rootfs_b$|device=${WORK}/slot-b.ext4|" \
  "${generated_root}/etc/rauc/system.conf" >"${CONF}"

invalid_conf="${WORK}/system-invalid.conf"
sed '/^bootloader=custom$/a boot-attempts=3' "${CONF}" >"${invalid_conf}"
set +e
timeout 10 sudo -n rauc -d -c "${invalid_conf}" service --override-boot-slot=A \
  >"${WORK}/invalid-config.log" 2>&1
invalid_rc=$?
set -e
[[ "${invalid_rc}" -ne 0 && "${invalid_rc}" -ne 124 ]]
grep -Fq 'Configuring boot attempts is valid for uboot or barebox only (not for custom)' \
  "${WORK}/invalid-config.log"
printf 'INVALID_CONFIG_CONTROL=PASS boot-attempts-rejected-for-custom\n'

CERALIVE_BOOT_STATE_FILE="${WORK}/boot_state.txt" CERALIVE_BOOT_STATE_CORE="${WORK}/boot-state-core.sh" \
  CERALIVE_BOOT_ATTEMPTS=3 bash "${WORK}/ceralive-boot-state.sh" init
COMPATIBLE_STRING=ceralive-rock-5b-plus BUNDLE_VERSION=runtime-contract BUNDLE_OUT_DIR="${WORK}/bundle" \
  BUNDLE_TS=probe CERALIVE_RAUC_PKI_DIR="${WORK}/pki" REPRODUCIBLE=1 \
  bash "${PIPELINE_DIR}/lib/build-bundle.sh" rock-5b-plus "${WORK}/update-tree" >"${WORK}/bundle-build.log" 2>&1

printf 'RAUC_VERSION=%s\n' "$(rauc --version)"
a_before="$(sha256sum "${WORK}/slot-a.ext4" | cut -d' ' -f1)"
touch "${WORK}/interrupt"
start_service "${WORK}/service-interrupted.log"
[[ "${CERALIVE_REAL_RAUC_FAIL_AFTER_SERVICE:-0}" == 0 ]] || exit 99
if [[ "${CERALIVE_REAL_RAUC_PAUSE_AFTER_SERVICE:-0}" =~ ^[1-9][0-9]*$ ]]; then
  sleep "${CERALIVE_REAL_RAUC_PAUSE_AFTER_SERVICE}"
fi
rauc -c "${CONF}" install "${BUNDLE}" >"${WORK}/client-interrupted.log" 2>&1 &
client_pid=$!
checkpoint=0
for _ in $(seq 1 100); do
  [[ -e "${WORK}/interruption-checkpoint" ]] && { checkpoint=1; break; }
  kill -0 "${client_pid}" 2>/dev/null || break
  sleep 0.1
done
[[ "${checkpoint}" -eq 1 ]]
stop_service
set +e
wait "${client_pid}"
interrupted_rc=$?
set -e
client_pid=""
[[ "${interrupted_rc}" -ne 0 && "$(state get-primary)" == A && "$(state get-state B)" == bad ]]
if grep -q '^set-primary ' "${WORK}/backend.calls"; then
  printf 'interrupted install activated the target prematurely\n' >&2
  exit 1
fi
[[ "$(sha256sum "${WORK}/slot-a.ext4" | cut -d' ' -f1)" == "${a_before}" ]]
printf 'INTERRUPTION=PASS primary=A target=B-bad slot-a-unchanged\n'

rm -f "${WORK}/interrupt" "${WORK}/interruption-checkpoint"
start_service "${WORK}/service-retry.log"
timeout 60 rauc -c "${CONF}" install "${BUNDLE}" >"${WORK}/client-retry.log" 2>&1
stop_service
[[ "$(state get-primary)" == B ]]
[[ "$(debugfs -R 'cat /etc/ceralive-rauc-probe' "${WORK}/slot-b.ext4" 2>/dev/null)" == updated-arm64-bundle ]]
[[ "$(debugfs -R 'cat /etc/ceralive-rauc-probe' "${WORK}/slot-a.ext4" 2>/dev/null)" == factory-slot-a ]]
[[ "$(sha256sum "${WORK}/slot-a.ext4" | cut -d' ' -f1)" == "${a_before}" ]]
printf 'RETRY=PASS primary=B inactive-slot-updated\n'

[[ "$(state boot-select)" == "B rootfs_b" ]]
[[ "$(state boot-select)" == "B rootfs_b" ]]
[[ "$(state boot-select)" == "B rootfs_b" ]]
[[ "$(state get-primary)" == A ]]
[[ "$(state boot-select)" == "A rootfs_a" ]]
printf 'ROLLBACK=PASS primary=A after-three-unconfirmed-boots\n'
printf 'RESULT=PASS\n'
