#!/usr/bin/env bash
#
# build-ceracoder-sysext.sh — produce ceracoder.raw (Stage 3, task 22).
#
# Consumes a first-party .deb staging dir, extracts /usr/bin/ceracoder (pruning
# any Runtime-owned libsrt / Platform-owned MPP that a .deb wrongly bundled), and
# emits a signed-matchable systemd-sysext squashfs via the app-layer contract.
#
# Usage: build-ceracoder-sysext.sh <deb_staging_dir> [output_dir]
#   <deb_staging_dir>  dir holding ceracoder_*.deb (orchestrator's firstparty dir)
#   [output_dir]       where ceracoder.raw lands (default: CWD)
# Echoes the resulting ceracoder.raw path on stdout.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=sysext-build.lib.sh
source "${HERE}/sysext-build.lib.sh"

build_sysext_main "${HERE}/ceracoder.sysext.conf" "$@"
