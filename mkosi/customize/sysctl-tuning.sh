#!/usr/bin/env bash
#
# customize/sysctl-tuning.sh — streaming performance tuning.
#
# DECOMPOSED FROM: userpatches/customize-image.sh:apply_streaming_optimizations()
# (L433-469). Three coupled streaming-tuning concerns kept together because v1
# treated them as one unit:
#   * sysctl  : network buffer sizes, TCP rmem/wmem, BBR, swappiness, dirty ratios
#               → /etc/sysctl.d/99-ceralive-streaming.conf
#   * cpufreq : performance governor → /etc/default/cpufrequtils
#   * tmpfs   : /tmp on tmpfs (noatime, 1G) → /etc/fstab
#
# v1 GATED the governor write on a sysfs path that does not exist inside the
# build chroot (L461), so the governor file was NEVER written at build time. v2
# writes it unconditionally (cpufrequtils reads it at boot on the real device);
# this fixes a latent v1 no-op rather than preserving a build-chroot accident.
#
# /etc/fstab is an /etc write left IN PLACE here (data-persistence relocation is
# task 30, not this task).
#
# CONTRACT: sourced by run-all.sh (chroot context). Strict; no `|| true`.
#
# shellcheck shell=bash

set -euo pipefail

# shellcheck source=../../lib/common.sh
source "${CERALIVE_COMMON_SH:-"$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd)/common.sh"}"

apply_streaming_optimizations() {
  log_info "writing streaming sysctl tuning (/etc/sysctl.d/99-ceralive-streaming.conf)"
  mkdir -p /etc/sysctl.d
  cat >/etc/sysctl.d/99-ceralive-streaming.conf <<'EOF'
# CeraLive Streaming Optimizations

# Network buffer sizes for streaming
net.core.rmem_default = 262144
net.core.rmem_max = 16777216
net.core.wmem_default = 262144
net.core.wmem_max = 16777216

# TCP optimizations
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_congestion_control = bbr

# Reduce swappiness for better performance
vm.swappiness = 10

# File system optimizations
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
EOF

  log_info "selecting performance CPU governor (/etc/default/cpufrequtils)"
  echo 'GOVERNOR="performance"' >/etc/default/cpufrequtils

  log_info "configuring tmpfs /tmp (noatime, 1G) in /etc/fstab"
  if ! grep -q '^tmpfs[[:space:]]\+/tmp[[:space:]]' /etc/fstab 2>/dev/null; then
    echo 'tmpfs /tmp tmpfs defaults,noatime,size=1G 0 0' >>/etc/fstab
  fi

  log_success "streaming optimizations applied"
}

apply_streaming_optimizations "$@"
