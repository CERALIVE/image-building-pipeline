#!/usr/bin/env bash
#
# build-srtla-sysext.sh — produce srtla.raw (Stage 3, task 22).
#
# Consumes a first-party .deb staging dir, extracts /usr/bin/srtla_send and
# /usr/bin/srtla_rec (pruning any Runtime-owned libsrt that a .deb wrongly
# bundled), and emits a signed-matchable systemd-sysext squashfs via the
# app-layer contract.
#
# Usage: build-srtla-sysext.sh <deb_staging_dir> [output_dir]
#   <deb_staging_dir>  dir holding srtla_*.deb (orchestrator's firstparty dir)
#   [output_dir]       where srtla.raw lands (default: CWD)
# Echoes the resulting srtla.raw path on stdout.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=sysext-build.lib.sh
source "${HERE}/sysext-build.lib.sh"

build_sysext_main "${HERE}/srtla.sysext.conf" "$@"
