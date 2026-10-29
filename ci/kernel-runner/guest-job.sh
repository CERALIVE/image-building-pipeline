#!/usr/bin/env bash
# The root wrapper only hands off the payload and powers off the disposable VM.
set -euo pipefail
fw=/sys/firmware/qemu_fw_cfg/by_name/opt/ceralive
code=1
finish() {
  printf '\nCERALIVE_JOB_DONE=%s\n' "${code}" >/dev/ttyS0
  systemctl poweroff
}
trap finish EXIT
modprobe qemu_fw_cfg
install -d -m 0700 -o ubuntu -g ubuntu /run/ceralive-runner
export ARMBIAN_APT_KEYRING=/run/ceralive-runner/armbian.gpg
bash /usr/local/lib/ceralive-kernel-runner/keyring.sh "${ARMBIAN_APT_KEYRING}"
if [[ ! -e "${fw}/jit/raw" && ! -e "${fw}/check/raw" ]]; then
  find -L /sys/firmware/qemu_fw_cfg -maxdepth 5 -name name -exec cat {} \; >/dev/ttyS0
  exit 1
fi
if [[ -e "${fw}/jit/raw" ]]; then
  # Runner-side admission, independent of ci/kernel-release.py's --publish guard:
  # the JIT config is single-use, but the JOB context is whatever GitHub delivers.
  hook=/usr/local/lib/ceralive-kernel-runner/admit-job.sh
  [[ -x "${hook}" ]] || { printf 'runner admission hook missing\n' >/dev/ttyS0; exit 1; }
  runuser -u ubuntu -- bash -c '[[ -r "$1" && ! -w "$1" ]]' _ "${hook}" \
    || { printf 'runner admission hook not read-only for the runner user\n' >/dev/ttyS0; exit 1; }
  export ACTIONS_RUNNER_HOOK_JOB_STARTED="${hook}"
  install -m 0600 -o ubuntu -g ubuntu "${fw}/jit/raw" /run/ceralive-runner/jit
  runuser -u ubuntu -- bash -c '
    set -euo pipefail
    config="$(</run/ceralive-runner/jit)"
    rm /run/ceralive-runner/jit
    cd /opt/actions-runner
    exec ./run.sh --jitconfig "$config"
  ' && code=0
else
  bash "${fw}/check/raw" && code=0
fi
