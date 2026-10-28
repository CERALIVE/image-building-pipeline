#!/usr/bin/env bash
# Native CI prerequisites in the disposable VM. Never run on the workstation.
set -euo pipefail
[[ "$(systemd-detect-virt --vm)" == kvm || "$(systemd-detect-virt --vm)" == qemu ]]
[[ -d /sys/firmware/qemu_fw_cfg/by_name/opt/ceralive ]]
sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "${ROOT}"
python3 -m venv "${RUNNER_TEMP}/python"
export PATH="${RUNNER_TEMP}/python/bin:${PATH}"
pip install --quiet --requirement ci/requirements-ci.txt
work="$(mktemp -d)"
trap 'rm -rf -- "${work}"' EXIT
pin() { awk -F= -v key="$1" '$1 == key {print $2; exit}' manifests/rauc-deb-versions.txt; }
version="$(pin UPSTREAM_VERSION)"
curl -fsSL --connect-timeout 30 --max-time 300 "$(pin UPSTREAM_URL)" -o "${work}/rauc.tar.xz"
printf '%s  %s\n' "$(pin UPSTREAM_SHA256)" "${work}/rauc.tar.xz" | sha256sum -c -
mkdir "${work}/source"
tar -xf "${work}/rauc.tar.xz" -C "${work}/source" --strip-components=1
meson setup "${work}/build" "${work}/source" --prefix=/usr/local \
  -Dtests=false -Dgpt=enabled -Dstreaming=true -Djson=enabled \
  -Dsystemdunitdir=/usr/lib/systemd/system \
  -Ddbussystemservicedir=/usr/share/dbus-1/system-services \
  -Ddbuspolicydir=/usr/share/dbus-1/system.d
meson compile -C "${work}/build"
sudo meson install -C "${work}/build"
[[ "$(rauc --version)" == "rauc ${version}" ]]
getent passwd ceralive-ota >/dev/null || sudo useradd --system --no-create-home --shell /usr/sbin/nologin ceralive-ota
sudo busctl call --system org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus ReloadConfig
source manifests/target-release.env
docker pull "debian:${RELEASE}"
docker pull "debian:${RELEASE}-slim"
container="$(docker create --network none "debian:${RELEASE}")"
trap 'docker rm "${container}"; rm -rf -- "${work}"' EXIT
docker export "${container}" >"${RUNNER_TEMP}/kernel-stage-rootfs.tar"
export CERALIVE_KERNEL_STAGE_ROOTFS="${RUNNER_TEMP}/kernel-stage-rootfs.tar"
CERALIVE_RUN_REAL_AVAHI_CONTRACT=required \
  CERALIVE_RUN_REAL_RAUC_CONTRACT=required \
  CERALIVE_RUN_REAL_KERNEL_STAGE_CONTRACT=required \
  CERALIVE_RUN_REAL_PRIVILEGE_DROP_CONTRACT=required ./run-tests
