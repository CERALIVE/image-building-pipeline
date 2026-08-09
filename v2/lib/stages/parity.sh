#!/usr/bin/env bash
#
# stages/parity.sh — orchestrator stage [7/9]: parity vs the v2 package manifests.
#
# Sourced by lib/orchestrate.sh. See stages/resolve.sh for the dynamic-scoping
# contract every stage module relies on.
#
# shellcheck shell=bash
# shellcheck disable=SC2154

# ---------------------------------------------------------------------------
# stage_parity — [7/9]
#
# Reads from main()'s frame: board, rootfs_tree.
# ---------------------------------------------------------------------------
stage_parity() {
  # -------------------------------------------------------------------------
  # 8. Parity verification vs the v2 package manifests. The app layer now
  #    installs the first-party .debs (Stage 3, app/mkosi.postinst.chroot), so in
  #    CI mode (debs fetched) the gate clears the first-party check via the
  #    ceraui→ceralive-device alias in parity-check.sh. An
  #    offline/dev build stages no debs → installs nothing → the gate WARNs on the
  #    absent first-party packages, by design. Documented in LAYER-MAP.md §Layer 4.
  # -------------------------------------------------------------------------
  log_info "[7/9] verifying parity vs v2 package manifests"
  "${PARITY_CHECK_SH}" "${rootfs_tree}" \
    || die "parity check FAILED for board '${board}' — image does not match the canonical package/service/user/routing set"
}
