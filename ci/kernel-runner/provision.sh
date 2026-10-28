#!/usr/bin/env bash
# Runs as root INSIDE the pristine VM, never on the workstation.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
  docker.io docker-buildx git gh curl ca-certificates gnupg jq python3 python3-venv python3-yaml \
  build-essential cpio dbus avahi-daemon avahi-utils bats shellcheck ripgrep \
  device-tree-compiler dosfstools e2fsprogs gdisk iproute2 iptables kmod \
  libcurl4-openssl-dev libdbus-1-dev libfdisk-dev libglib2.0-dev \
  libjson-glib-dev libnl-genl-3-dev libssl-dev libicu74 meson mtools \
  ninja-build pkg-config procps rsync socat squashfs-tools systemd \
  u-boot-tools util-linux zstd xz-utils unzip openssl "linux-modules-extra-$(uname -r)"
modprobe qemu_fw_cfg
test -d /sys/firmware/qemu_fw_cfg/by_name/opt/ceralive
python3 -m venv /opt/kernel-floor-aws
/opt/kernel-floor-aws/bin/pip install --quiet awscli==1.46.2
ln -s /opt/kernel-floor-aws/bin/aws /usr/local/bin/aws
systemctl enable --now docker
docker buildx version
usermod -aG docker ubuntu
install -d -o ubuntu -g ubuntu /opt/actions-runner
curl -fSL --connect-timeout 30 --max-time 600 \
  "https://github.com/actions/runner/releases/download/v$1/actions-runner-linux-x64-$1.tar.gz" \
  -o /var/tmp/runner.tar.gz
printf '%s  /var/tmp/runner.tar.gz\n' "$2" | sha256sum -c -
tar -xzf /var/tmp/runner.tar.gz -C /opt/actions-runner
rm /var/tmp/runner.tar.gz
chown -R ubuntu:ubuntu /opt/actions-runner
systemctl enable ceralive-runner.service
printf 'qemu_fw_cfg\n' >/etc/modules-load.d/ceralive-runner.conf
# Discard the provisioning seed and disable the unused inbound SSH service.
touch /etc/cloud/cloud-init.disabled
systemctl disable --now ssh.service ssh.socket
systemctl mask --now serial-getty@ttyS0.service getty@tty1.service
printf '\nCERALIVE_BASE_READY\n' >/dev/ttyS0
