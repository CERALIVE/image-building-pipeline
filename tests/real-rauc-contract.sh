#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/var/tmp}/ceralive-rauc-contract.XXXXXX")"
CONF="${WORK}/system.conf"
BUNDLE="${WORK}/bundle/probe.raucb"
service_pid=""
client_pid=""
priority_dir=/dev/disk/by-partlabel
priority_link="${priority_dir}/ceralive-rauc-${WORK##*.}"
priority_parent_created=0
priority_dir_created=0
priority_link_owned=0
priority_cmdline_mounted=0

remove_priority_fixture() {
  local rc=0
  if (( priority_cmdline_mounted )); then
    sudo -n umount /proc/cmdline || rc=1
    (( rc != 0 )) || priority_cmdline_mounted=0
  fi
  if (( priority_link_owned )); then
    if [[ "$(readlink -- "${priority_link}" 2>/dev/null)" == "${WORK}/slot-b.ext4" ]]; then
      sudo -n rm -- "${priority_link}" || rc=1
      (( rc != 0 )) || priority_link_owned=0
    else
      printf 'RAUC priority fixture link changed: %s\n' "${priority_link}" >&2
      rc=1
    fi
  fi
  if (( priority_dir_created )); then
    sudo -n rmdir -- "${priority_dir}" 2>/dev/null || true
    priority_dir_created=0
  fi
  if (( priority_parent_created )); then
    sudo -n rmdir -- "${priority_dir%/*}" 2>/dev/null || true
    priority_parent_created=0
  fi
  return "${rc}"
}

create_priority_partlabel() {
  # A unique label cannot overwrite a real board's rootfs_b udev link.
  [[ ! -e "${priority_link}" && ! -L "${priority_link}" ]] || {
    printf 'RAUC priority fixture link already exists: %s\n' "${priority_link}" >&2
    return 1
  }
  [[ -d "${priority_dir%/*}" ]] || priority_parent_created=1
  [[ -d "${priority_dir}" ]] || priority_dir_created=1
  sudo -n mkdir -p -- "${priority_dir}"
  sudo -n ln -s -- "${WORK}/slot-b.ext4" "${priority_link}"
  priority_link_owned=1
  [[ "$(readlink -e -- "${priority_link}")" == "${WORK}/slot-b.ext4" ]]
}

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

release_harness_mounts() {
  local target source loop backing remaining attempt
  while read -r target source; do
    [[ -n "${target}" ]] || continue
    backing=""
    [[ "${source}" == /dev/loop* ]] && backing="$(losetup -n -O BACK-FILE "${source}" 2>/dev/null || true)"
    # A verity bundle mounts through a dm-verity device (source /dev/dm-N)
    # layered on the loop device, so neither the WORK-prefix nor the
    # loop-backing check above ever matches it directly. RAUC's own
    # mount-prefix default (unconfigured by every fixture here) is
    # /mnt/rauc/, which nothing else in this harness ever mounts onto, so
    # matching on TARGET is the unambiguous, harness-scoped signal. RAUC
    # opens the verity mapping with deferred-remove, so this umount alone
    # releases both the dm device and its underlying loop.
    if [[ "${source}" == "${WORK}"/* || "${backing}" == "${WORK}"/* || "${target}" == /mnt/rauc/* ]]; then
      sudo -n umount "${target}" 2>/dev/null || true
    fi
  done < <(findmnt -rn -o TARGET,SOURCE 2>/dev/null || true)
  for (( attempt=0; attempt<20; attempt++ )); do
    remaining=0
    while read -r loop backing; do
      [[ "${backing}" == "${WORK}"/* ]] || continue
      remaining=1
      sudo -n losetup -d "${loop}" 2>/dev/null || true
    done < <(losetup -l -n -O NAME,BACK-FILE 2>/dev/null || true)
    (( remaining == 0 )) && return 0
    sleep 0.1
  done
  return 1
}

cleanup() {
  local source backing leaked=0
  if [[ -n "${client_pid}" ]] && kill -0 "${client_pid}" 2>/dev/null; then
    kill -TERM "${client_pid}" 2>/dev/null || true
    wait "${client_pid}" 2>/dev/null || true
  fi
  stop_service
  stop_descendants
  remove_priority_fixture || leaked=1
  release_harness_mounts
  while read -r _ source; do
    [[ "${source}" == "${WORK}"/* ]] && leaked=1
  done < <(findmnt -rn -o TARGET,SOURCE 2>/dev/null || true)
  while read -r _ backing; do
    [[ "${backing}" == "${WORK}"/* ]] && leaked=1
  done < <(losetup -l -n -O NAME,BACK-FILE 2>/dev/null || true)
  if pgrep -f "${WORK}/" >/dev/null 2>&1; then
    leaked=1
    printf 'remaining RAUC fixture descendants:\n' >&2
    pgrep -af "${WORK}/" >&2 || true
  fi
  if (( leaked != 0 )); then
    printf 'remaining RAUC fixture mount/loop state:\n' >&2
    findmnt -rn -o TARGET,SOURCE >&2 || true
    losetup -l -n -O NAME,BACK-FILE >&2 || true
  fi
  sudo -n rm -rf "${WORK}"
  (( leaked == 0 ))
}

on_exit() {
  local rc=$?
  trap - EXIT INT TERM
  if (( rc != 0 )); then
    local log
    for log in "${WORK}"/{bundle-build,service-interrupted,client-interrupted,service-retry,client-retry,rotation-build,rotation-extract,rotation-sign,service-rotation,client-rotation}.log; do
      if [[ -s "${log}" ]]; then
        printf 'real RAUC failure context: %s\n' "${log##*/}" >&2
        sed -n '1,80p' "${log}" >&2
      fi
    done
  fi
  cleanup || { printf 'real RAUC cleanup left a harness mount or loop\n' >&2; (( rc == 0 )) && rc=1; }
  exit "${rc}"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

start_service() {
  local log="$1" _
  run_service() { exec sudo -n env PATH="${WORK}/bin:${PATH}" rauc -d -c "${CONF}" service --override-boot-slot=A; }
  run_service >"${log}" 2>&1 &
  service_pid=$!
  for _ in $(seq 1 100); do
    if rauc -c "${CONF}" status >/dev/null 2>&1 && \
      busctl --system --auto-start=no status de.pengutronix.rauc >/dev/null 2>&1; then
      return 0
    fi
    kill -0 "${service_pid}" 2>/dev/null || break
    sleep 0.1
  done
  sed -n '1,200p' "${log}" >&2
  return 1
}

# start_service_auto <log> — the BOOT_SLOT_PRIORITY leg's own twin of
# start_service(), deliberately WITHOUT --override-boot-slot: this leg exists
# specifically to exercise RAUC's real (non-overridden) booted-slot detection
# (r_context's get_bootname(), which --override-boot-slot bypasses entirely).
start_service_auto() {
  local log="$1" _
  run_service() { exec sudo -n env PATH="${WORK}/bin:${PATH}" rauc -d -c "${CONF}" service; }
  run_service >"${log}" 2>&1 &
  service_pid=$!
  for _ in $(seq 1 100); do
    if rauc -c "${CONF}" status >/dev/null 2>&1 && \
      busctl --system --auto-start=no status de.pengutronix.rauc >/dev/null 2>&1; then
      return 0
    fi
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
for tool in rauc mkfs.ext4 debugfs findmnt losetup sudo timeout flock openssl busctl sgdisk e2label lsblk; do
  command -v "${tool}" >/dev/null 2>&1 || { printf 'missing real RAUC prerequisite: %s\n' "${tool}" >&2; exit 127; }
done
sudo -n true
mkdir -p "${WORK}"/{bundle,data,pki,slot-a-tree/{etc,sbin},slot-b-tree/{etc,sbin},update-tree/{etc,sbin}}
mkdir -p "${WORK}/data/certs"
printf 'cert-slot-initial\n' >"${WORK}/data/certs/.rauc-certs-slot"
for tree in slot-a-tree slot-b-tree update-tree; do
  printf '#!/bin/sh\nexit 0\n' >"${WORK}/${tree}/sbin/init"
  chmod +x "${WORK}/${tree}/sbin/init"
done
printf 'factory-slot-a\n' >"${WORK}/slot-a-tree/etc/ceralive-rauc-probe"
printf 'factory-slot-b\n' >"${WORK}/slot-b-tree/etc/ceralive-rauc-probe"
printf 'updated-arm64-bundle\n' >"${WORK}/update-tree/etc/ceralive-rauc-probe"
truncate -s 4096M "${WORK}/slot-a.ext4" "${WORK}/slot-b.ext4"
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
sed -e "s|^data-directory=/data/ceralive/rauc$|data-directory=${WORK}/data/rauc|" \
  -e "s|^bootloader-custom-backend=.*$|bootloader-custom-backend=${WORK}/backend.sh|" \
  -e "s|^path=/etc/rauc/ceralive-keyring.pem$|path=${WORK}/pki/root-ca.pem|" \
  -e "s|^device=/dev/disk/by-partlabel/rootfs_a$|device=${WORK}/slot-a.ext4|" \
  -e "s|^device=/dev/disk/by-partlabel/rootfs_b$|device=${WORK}/slot-b.ext4|" \
  -e "s|^device=/data/ceralive/certs/.rauc-certs-slot$|device=${WORK}/data/certs/.rauc-certs-slot|" \
  -e 's|^post-install=/usr/lib/rauc/ceralive-post-install$|post-install=/bin/true|' \
  "${generated_root}/etc/rauc/system.conf" >"${CONF}"
sudo -n mkdir -p "${WORK}/data/rauc"
getent passwd ceralive-ota >/dev/null

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
  BUNDLE_TS=probe CERALIVE_RAUC_PKI_DIR="${WORK}/pki" \
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
release_harness_mounts
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
release_harness_mounts
[[ "$(state get-primary)" == A ]]
[[ "$(debugfs -R 'cat /etc/ceralive-rauc-probe' "${WORK}/slot-b.ext4" 2>/dev/null)" == updated-arm64-bundle ]]
[[ "$(debugfs -R 'cat /etc/ceralive-rauc-probe' "${WORK}/slot-a.ext4" 2>/dev/null)" == factory-slot-a ]]
[[ "$(sha256sum "${WORK}/slot-a.ext4" | cut -d' ' -f1)" == "${a_before}" ]]
printf 'RETRY=PASS primary=A inactive-slot-updated-not-activated\n'

rauc info --keyring="${WORK}/pki/root-ca.pem" "${BUNDLE}" >"${WORK}/rauc-info.txt"
grep -Fq 'Bundle Format:  verity' "${WORK}/rauc-info.txt"
grep -Fq 'Adaptive:  block-hash-index' "${WORK}/rauc-info.txt"
printf 'VERITY_INFO=PASS adaptive block-hash-index\n'

truncate -s 8300M "${WORK}/gpt.raw"
sgdisk -o -n 1:2048:+4096M -c 1:rootfs_a -n 2:0:+4096M -c 2:rootfs_b "${WORK}/gpt.raw" >/dev/null
gpt_loop="$(sudo -n losetup --find --show --partscan "${WORK}/gpt.raw")"
for _ in $(seq 1 30); do
  [[ -b "${gpt_loop}p1" && -b "${gpt_loop}p2" ]] && break
  sleep 0.1
done
# --partscan makes the kernel register both partitions in sysfs, but a
# harness container with no udev running never gets the matching /dev nodes
# from that alone. Fall back to mknod from the devt sysfs already publishes,
# so this leg does not depend on udev being present in the execution
# environment.
if [[ ! -b "${gpt_loop}p1" || ! -b "${gpt_loop}p2" ]]; then
  gpt_loop_base="${gpt_loop#/dev/}"
  for part in 1 2; do
    node="${gpt_loop}p${part}"
    [[ -b "${node}" ]] && continue
    sys_dev="/sys/class/block/${gpt_loop_base}/${gpt_loop_base}p${part}/dev"
    [[ -r "${sys_dev}" ]] || continue
    devt="$(<"${sys_dev}")"
    sudo -n mknod -m 0660 "${node}" b "${devt%%:*}" "${devt##*:}"
    sudo -n chown root:disk "${node}" 2>/dev/null || true
  done
fi
[[ -b "${gpt_loop}p1" && -b "${gpt_loop}p2" ]]
sudo -n mkfs.ext4 -q -F -L rootfs_a "${gpt_loop}p1"
sudo -n mkfs.ext4 -q -F -L rootfs_b "${gpt_loop}p2"
[[ "$(sudo -n lsblk -ndo PARTLABEL "${gpt_loop}p2")" == rootfs_b ]]
sed -e "s|^device=${WORK}/slot-a.ext4$|device=${gpt_loop}p1|" \
    -e "s|^device=${WORK}/slot-b.ext4$|device=${gpt_loop}p2|" \
    -e "s|^post-install=/bin/true$|post-install=${generated_root}/usr/lib/rauc/ceralive-post-install|" \
    "${CONF}" >"${WORK}/gpt-system.conf"
CONF="${WORK}/gpt-system.conf"
start_service "${WORK}/service-gpt.log"
timeout 120 rauc -c "${CONF}" install "${BUNDLE}" >"${WORK}/client-gpt.log" 2>&1
stop_service
[[ "$(sudo -n e2label "${gpt_loop}p2")" == rootfs_b ]]
[[ "$(sudo -n lsblk -ndo PARTLABEL "${gpt_loop}p2")" == rootfs_b ]]
printf 'GPT_LABEL=PASS installed verity rootfs_b has its own GPT PARTLABEL as ext4 label\n'
sudo -n losetup -d "${gpt_loop}"
# A runner's udev removes the last by-partlabel entry (and sometimes its
# directory) after loop detach. Wait for that removal before creating our link.
if command -v udevadm >/dev/null 2>&1; then
  sudo -n udevadm settle --timeout=10
fi
CONF="${WORK}/system.conf"

# BOOT_SLOT_PRIORITY — RAUC 1.15 (PR #1712) now consults the bootloader-custom
# backend's own get-current BEFORE falling back to generic root= kernel-cmdline
# parsing (previously get-current was tried only as a last resort AFTER root=
# parsing failed). The Todo-22 RAUC-version ruling flagged this for
# re-validation against CeraLive's real adapter, not assumption.
# --override-boot-slot cannot exercise this at all: it bypasses RAUC's own
# get_bootname() resolution entirely, which is why every earlier leg above
# uses it and none of them proves anything about slot-detection priority.
#
# The real (faked) /proc/cmdline carries root=PARTLABEL=<our unique label> — no
# rauc.slot= — and the label is a REAL, valid symlink resolving to slot B's own
# device, so root= parsing alone would genuinely resolve to B. The real
# backend.sh wrapper's adapter (unaffected by this fake — it reads
# CERALIVE_KERNEL_CMDLINE_FILE=${WORK}/cmdline, which still carries
# rauc.slot=A) answers "A". Only if RAUC 1.15.2 actually asks the custom
# backend before falling through to root= does the service resolve slot A.
create_priority_partlabel
printf 'root=PARTLABEL=%s console=ttyS2\n' "${priority_link##*/}" >"${WORK}/priority-cmdline"
sudo -n mount --bind "${WORK}/priority-cmdline" /proc/cmdline
priority_cmdline_mounted=1
priority_log="${WORK}/service-priority.log"
start_service_auto "${priority_log}"
priority_status="$(rauc -c "${CONF}" status --output-format=json)"
stop_service
remove_priority_fixture
python3 -c '
import json, sys
data = json.loads(sys.argv[1])
booted = data.get("booted")
assert booted == "A", (
    "expected booted=A (custom-backend get-current outranking a validly-"
    f"resolvable conflicting root=), got {booted!r}"
)
' "${priority_status}"
grep -Fq 'Resolved custom backend bootname to A' "${priority_log}"
printf 'BOOT_SLOT_PRIORITY=PASS custom-backend get-current outranks a validly-resolvable conflicting root= (RAUC 1.15 PR#1712)\n'

start_service "${WORK}/service-activation.log"
rauc -c "${CONF}" status mark-active other >/dev/null
stop_service
[[ "$(state get-primary)" == B ]]
printf 'ACTIVATION=PASS explicit-mark-active-after-install\n'

# Build with the real rotation producer and a NEW test leaf under the same
# non-production intermediate. Re-sign only after relocating the install hook's
# absolute /data path into this private fixture; never let a hook write to the host.
openssl req -new -newkey rsa:2048 -nodes -sha256 \
  -keyout "${WORK}/pki/next-leaf.key" -out "${WORK}/pki/next-leaf.csr" \
  -subj '/CN=CeraLive rotation contract (NON-PRODUCTION)' >"${WORK}/openssl.log" 2>&1
printf '%s\n' 'basicConstraints=critical,CA:FALSE' 'keyUsage=critical,digitalSignature' \
  'extendedKeyUsage=emailProtection,codeSigning' >"${WORK}/pki/next-leaf.ext"
openssl x509 -req -sha256 -days 2 -set_serial 41 \
  -in "${WORK}/pki/next-leaf.csr" \
  -CA "${PIPELINE_DIR}/.dev-keys/dev-intermediate-ca.pem" \
  -CAkey "${PIPELINE_DIR}/.dev-keys/dev-intermediate-ca.key" \
  -out "${WORK}/pki/next-leaf.pem" -extfile "${WORK}/pki/next-leaf.ext" \
  >>"${WORK}/openssl.log" 2>&1
CERALIVE_RAUC_PKI_DIR="${WORK}/pki" bash -c '
  source "$1/lib/build-cert-rotation-bundle.sh"
  IMAGES_DIR="$2"
  build-cert-rotation-bundle rock-5b-plus "$3" "$4" "$5"
' _ "${PIPELINE_DIR}" "${WORK}/images" \
  "${PIPELINE_DIR}/.dev-keys/dev-intermediate-ca.pem" \
  "${WORK}/pki/next-leaf.pem" "${WORK}/pki/next-leaf.key" \
  >"${WORK}/rotation-build.log" 2>&1
rotation_bundles=("${WORK}"/images/rock-5b-plus/cert-bundles/*.raucb)
[[ ${#rotation_bundles[@]} -eq 1 && -f "${rotation_bundles[0]}" ]]
rotation_bundle="${rotation_bundles[0]}"
rauc --keyring="${WORK}/pki/root-ca.pem" extract "${rotation_bundle}" "${WORK}/rotation" \
  >"${WORK}/rotation-extract.log" 2>&1
tar -tf "${WORK}/rotation/certs.tar" >"${WORK}/certs-members.txt"
grep -q './leaf.pem' "${WORK}/certs-members.txt"
if grep -qE '\.(key|csr)$' "${WORK}/certs-members.txt"; then
  printf 'rotation bundle contains private signing material\n' >&2
  exit 1
fi
sed -i "s|INCOMING=\"/data/ceralive/certs/incoming\"|INCOMING=\"${WORK}/data/certs/incoming\"|" \
  "${WORK}/rotation/hook.sh"
sed -i '/^sha256=/d; /^size=/d' "${WORK}/rotation/manifest.raucm"
# The hook's unit handoff cannot run on the host. A test-only systemctl shim
# records that RAUC actually executed slot-install; it starts no host service.
mkdir -p "${WORK}/bin"
cat >"${WORK}/bin/systemctl" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>'${WORK}/rotation-hook.calls'
EOF
chmod +x "${WORK}/bin/systemctl"
# Re-signing this tiny extracted content (matching build-cert-rotation-bundle.sh's
# own RAUC_BUNDLE_MKSQUASHFS_ARGS use) needs the same squashfs-floor workaround:
# compressed, it lands at or under RAUC's 4096-byte verity minimum.
rauc bundle --cert="${WORK}/pki/leaf-signing.pem" \
  --key="${WORK}/pki/leaf-signing.key" --intermediate="${WORK}/pki/chain.pem" \
  --mksquashfs-args="-noD -noF" \
  "${WORK}/rotation" "${WORK}/bundle/rotation-fixture.raucb" \
  >"${WORK}/rotation-sign.log" 2>&1
cert_before="$(sha256sum "${WORK}/data/certs/.rauc-certs-slot" | cut -d' ' -f1)"
start_service "${WORK}/service-rotation.log"
timeout 60 rauc -c "${CONF}" install "${WORK}/bundle/rotation-fixture.raucb" \
  >"${WORK}/client-rotation.log" 2>&1
stop_service
[[ "$(state get-primary)" == B ]]
[[ "$(sha256sum "${WORK}/slot-a.ext4" | cut -d' ' -f1)" == "${a_before}" ]]
[[ "$(debugfs -R 'cat /etc/ceralive-rauc-probe' "${WORK}/slot-b.ext4" 2>/dev/null)" == updated-arm64-bundle ]]
[[ "$(sha256sum "${WORK}/data/certs/.rauc-certs-slot" | cut -d' ' -f1)" == "${cert_before}" ]]
[[ "$(sudo -n stat -c '%u' "${WORK}/data/certs/incoming")" == 0 ]]
sudo -n cmp "${WORK}/pki/next-leaf.pem" "${WORK}/data/certs/incoming/leaf.pem"
sudo -n grep -Fxq 'start --no-block cert-rotation.service' "${WORK}/rotation-hook.calls"
printf 'CERT_ROTATION=PASS signed-rotation-bundle-installed hook-staged-new-leaf rootfs-unchanged\n'

[[ "$(state boot-select)" == "B rootfs_b" ]]
[[ "$(state boot-select)" == "B rootfs_b" ]]
[[ "$(state boot-select)" == "B rootfs_b" ]]
[[ "$(state get-primary)" == A ]]
[[ "$(state boot-select)" == "A rootfs_a" ]]
printf 'ROLLBACK=PASS primary=A after-three-unconfirmed-boots\n'
printf 'RESULT=PASS\n'
