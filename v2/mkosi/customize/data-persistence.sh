#!/usr/bin/env bash
#
# customize/data-persistence.sh — relocate ALL user-mutable state onto the shared
# `/data` partition so an A/B (RAUC) OS-slot swap never wipes user config, and
# wire the device-side OS-update entrypoint.
#
# SINGLE SOURCE OF TRUTH (Task 6): the implementation lives ONCE in
# customize/postinst-lib.sh::setup_data_persistence and is sourced here. This
# module used to carry its own copy that "dual-tracked" — and silently drifted
# from — the inline twin in the wired runtime executor
# mkosi.images/runtime/mkosi.postinst.chroot (e.g. the migrate script's /data
# skeleton diverged: cert-incoming / rauc-downloads / hawkbit-updater dirs). Both
# tracks now share postinst-lib.sh; v2/ci/postinst-drift-check.sh fails CI if an
# inline twin is reintroduced. See .omo/evidence/task-6-*.
#
# WHY (Stage 4, task 30): the two rootfs slots (rootfs_a / rootfs_b) are
# overwritten atomically by a RAUC update — anything written into a slot is lost
# on the next swap. The frozen partition contract (docs/partition-contract.md §6)
# makes the trailing `data` partition (PARTLABEL=data, mounted at /data) the
# SINGLE source of truth for everything the user/runtime mutates. setup_data_
# persistence binds the live state directories onto /data, ships the one-time
# migration off the legacy /etc/ceralive location, and installs the RAUC update
# entrypoint (/usr/local/bin/ceralive-update).
#
# STRICT semantics (common.sh DESIGN RULE): the BUILD-TIME logic is strict — no
# `|| true`. The emitted RUNTIME payload scripts (migrate + update) run on the
# LIVE device against transient state and keep their own narrow, justified guards.
#
# CONTRACT: sourced by run-all.sh (chroot context). Strict; no build-time `|| true`.
# Depends on /opt/ceralive + /etc/ceralive existing (structure.sh) and the
# ceralive.service unit shipped by the CeraUI .deb (drop-in is additive).
#
# shellcheck shell=bash

set -euo pipefail

# shellcheck source=../../lib/common.sh
source "${CERALIVE_COMMON_SH:-"$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd)/common.sh"}"

DATA_PERSISTENCE_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=postinst-lib.sh
source "${DATA_PERSISTENCE_DIR}/postinst-lib.sh"

setup_data_persistence "$@"
