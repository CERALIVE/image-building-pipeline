#!/usr/bin/env bash
#
# customize/postinst-lib.sh — SINGLE SOURCE OF TRUTH for the runtime customization
# logic that used to be duplicated ("dual-track") between the wired runtime
# executor mkosi.images/runtime/mkosi.postinst.chroot and the decomposed
# customize/*.sh modules (see Task 6).
#
# This file is the ENTRY POINT ONLY: the chroot-safe fallback helpers plus the
# explicit list of per-concern modules under customize/postinst.d/ that carry the
# implementation. Sourcing it yields the COMPLETE API in one `source`; callers
# never reach into postinst.d/ themselves.
#
# It is SOURCED (never executed) by:
#   * mkosi.images/runtime/mkosi.postinst.chroot — via "${SRCDIR}/customize/
#     postinst-lib.sh" (mkosi mounts $SRCDIR=mkosi inside the .chroot postinst),
#   * customize/services.sh and customize/data-persistence.sh — via their own dir,
#     so the canonical decomposed modules and the wired postinst share ONE copy.
#
# SELF-CONTAINED: it does NOT hard-depend on lib/common.sh (the runtime postinst
# is standalone and runs in a chroot where the repo tree's lib/ is not mounted).
# It provides FALLBACK log()/die() only when the caller has not already defined
# them, so callers that DO source common.sh (the customize modules) keep their
# own structured loggers, and the standalone postinst keeps its own log().
#
# Payload scripts and units are NOT re-embedded as heredocs — they are INSTALLED
# from the committed canonical artifacts under "${CERALIVE_RUNTIME_SRC}" (the
# runtime/ source dir), exactly as customize/services.sh does, so callers MUST
# export CERALIVE_RUNTIME_SRC. postinst.d/hostname.sh is the one deliberate
# exception, for the reason its own header gives.
#
# WHERE THINGS LIVE — customize/postinst.d/:
#   networking.sh   NetworkManager/mDNS/resolv.conf, .link interface naming, the
#                   first-boot WiFi portal, the WAN-side ingest firewall
#   hostname.sh     the deterministic Avahi-arbitrated <hostname>.local claim
#   services.sh     enable/disable/mask policy + the unit-helper primitives
#   hardware.sh     Type-C source role, fan curve, fan kick-start, status LEDs
#   persistence.sh  the /data skeleton and bind mounts, plus the boot-stack freeze
#   tls-ssh.sh      SSH enablement/hardening, the nginx TLS front, cert rotation,
#                   the PASETO verification key
#
# shellcheck shell=bash

# --- Fallback helpers (defined only if the caller has not) -------------------
if ! declare -F log >/dev/null 2>&1; then
  log() { printf '[runtime-lib] %s\n' "$*" >&2; }
fi
if ! declare -F die >/dev/null 2>&1; then
  die() { log "FATAL: $*"; exit 1; }
fi
# Same fallback contract as log()/die() above: callers that already sourced
# lib/common.sh keep its copy, the standalone chroot postinst gets this one.
# CERALIVE_BENCH_LABELS=1 is the opt-in bench overlay (xboot/xrootfs_a/xrootfs_b/
# xdata) that keeps a bench microSD's PARTLABELs off the production set on the
# eMMC it boots beside; it reaches this chroot via mkosi.conf PassEnvironment=.
if ! declare -F partlabel_prefix >/dev/null 2>&1; then
  partlabel_prefix() {
    [[ "${CERALIVE_BENCH_LABELS:-0}" == "1" ]] && printf 'x'
    return 0
  }
fi
if ! declare -F resolve_partlabel >/dev/null 2>&1; then
  resolve_partlabel() {
    printf '%s%s' "$(partlabel_prefix)" "${1:?resolve_partlabel needs a partition role}"
  }
fi

# --- Concern modules ---------------------------------------------------------
# The implementation lives in per-concern modules under customize/postinst.d/.
# Sourcing this file is unchanged for every caller: it still defines the whole
# API in one `source`, and postinst-drift-check.sh still requires each
# consolidated function to be defined EXACTLY ONCE across the entry + modules.
#
# The list is EXPLICIT and ordered, never a glob: a module that is renamed, lost
# from the mkosi source mount, or added under postinst.d/ but never wired up must
# fail HERE and loudly, not later with `command not found` halfway through a
# postinst that has already half-configured the image. Load order does not affect
# correctness — modules only DEFINE functions; nothing calls across at source time.
CERALIVE_POSTINST_D="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/postinst.d"
CERALIVE_POSTINST_MODULES=(
  hardware.sh
  hostname.sh
  networking.sh
  persistence.sh
  services.sh
  tls-ssh.sh
)

for _ceralive_postinst_module in "${CERALIVE_POSTINST_MODULES[@]}"; do
  [[ -f "${CERALIVE_POSTINST_D}/${_ceralive_postinst_module}" ]] \
    || die "postinst module missing: ${CERALIVE_POSTINST_D}/${_ceralive_postinst_module} (is \$SRCDIR/customize mounted?)"
  # shellcheck source=/dev/null
  source "${CERALIVE_POSTINST_D}/${_ceralive_postinst_module}"
done
unset _ceralive_postinst_module
