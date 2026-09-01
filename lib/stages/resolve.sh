#!/usr/bin/env bash
#
# stages/resolve.sh — orchestrator stage [1/9]: manifest -> flat build params.
#
# Sourced by lib/orchestrate.sh (see its STAGE MODULES registry). Defines
# functions only; nothing runs at source time. Every stage_* function is called
# FROM main(), so bash's dynamic scoping gives it main()'s locals exactly as it
# had them when all nine bodies lived inline there — that is what makes this a
# pure relocation rather than a rewrite of the data flow.
#
# shellcheck shell=bash
# SC2154: every "referenced but not assigned" name in a stage module is one of
# main()'s locals, reached by the dynamic scoping described above. Checked
# standalone, shellcheck cannot see that frame.
# shellcheck disable=SC2154

# ---------------------------------------------------------------------------
# read_pkg_list <file...> — emit a space-joined package set from CeraLive *.list
# files (one package per line; `#` comments and blank lines ignored; inline
# comments stripped). Missing files are skipped (a family may carry no delta).
# This is how the runtime layer "references shared.list": the canonical Task-18
# manifests/packages/shared.list (+ resolved <family>.delta.list) is read here and
# forwarded to runtime/mkosi.postinst.chroot as $SHARED_PACKAGES — no duplicated
# inline package list in mkosi.conf.
# ---------------------------------------------------------------------------
read_pkg_list() {
  local f
  for f in "$@"; do
    [[ -f "${f}" ]] || continue
    sed -e 's/#.*//' "${f}" | awk 'NF{print $1}'
  done | sort -u | tr '\n' ' ' | sed -e 's/[[:space:]]\+$//'
}

# ---------------------------------------------------------------------------
# resolve_debug_image_flag — normalize + validate the debug/production seam.
#
# `CERALIVE_DEBUG_IMAGE` selects the whole variant: the development package
# delta, the baked password hash, SSH enablement, and the /etc/ceralive/debug-image
# marker. It used to be normalized inside run_mkosi_build(), which runs at step
# [6/9] — LONG after the runtime package set is resolved at step [1/9]. Resolving
# packages against an unvalidated value would let `CERALIVE_DEBUG_IMAGE=yes`
# silently produce a PRODUCTION package set and only fail two stages later, so the
# normalization happens here and is called before anything reads the flag.
# Idempotent: run_mkosi_build() re-exports the already-normalized value.
# ---------------------------------------------------------------------------
resolve_debug_image_flag() {
  export CERALIVE_DEBUG_IMAGE="${CERALIVE_DEBUG_IMAGE:-0}"
  export CERALIVE_DEBUG_PASSWORD_HASH="${CERALIVE_DEBUG_PASSWORD_HASH:-}"
  case "${CERALIVE_DEBUG_IMAGE}" in
    0|1) ;;
    *) die "CERALIVE_DEBUG_IMAGE must be 0 or 1" ;;
  esac
  if [[ -n "${CERALIVE_DEBUG_PASSWORD_HASH}" && "${CERALIVE_DEBUG_IMAGE}" != "1" ]]; then
    die "CERALIVE_DEBUG_PASSWORD_HASH requires CERALIVE_DEBUG_IMAGE=1"
  fi
  if [[ "${CERALIVE_DEBUG_IMAGE}" == "1" && -z "${CERALIVE_DEBUG_PASSWORD_HASH}" ]]; then
    die "CERALIVE_DEBUG_IMAGE=1 requires CERALIVE_DEBUG_PASSWORD_HASH"
  fi
}

# ---------------------------------------------------------------------------
# require_field — die loudly if a resolved param is empty (no silent defaults).
# ---------------------------------------------------------------------------
require_field() {
  local name="$1" val="$2"
  [[ -n "${val}" ]] || die "manifest did not resolve required field '${name}' — refusing to build a half-image"
}

# ---------------------------------------------------------------------------
# stage_resolve — [1/9]
#
# Reads from main()'s frame: board, variant.
# Writes into main()'s frame: kernel_from_source, family_manifest, mkosi_arch
# (declared there, assigned here — see the module header on dynamic scoping).
# ---------------------------------------------------------------------------
stage_resolve() {
  # -------------------------------------------------------------------------
  # 1. Resolve manifest → flat build params, into THIS shell's environment.
  #    resolve.sh dies loudly on unknown board/family, schema violations and
  #    unresolved versions.yaml defer tokens; its failure propagates here.
  # -------------------------------------------------------------------------
  log_info "[1/9] resolving manifest → build params"
  local params
  params="$("${RESOLVE_SH}" "${board}" --variant "${variant}")" \
    || die "manifest resolution failed for board '${board}' (variant '${variant}')"
  eval "${params}"
  # Export the resolved architecture and BSP package vars immediately so
  # fetch-debs.sh (step 2) can read them. run_mkosi_build() re-exports the full
  # set at step 6; this early export covers the fetch step which runs before mkosi.
  export ARCH DTB_NAME UBOOT_PACKAGES KERNEL_PACKAGES DTB_PACKAGES FIRMWARE_PACKAGES \
         HW_ACCEL_GSTREAMER_PLUGINS GSTREAMER_RUNTIME_PACKAGES

  # Reproducible builds (task 14): pin ONE epoch for the whole run so every
  # embedded mtime (mkosi rootfs, rootfs.tar, squashfs, ext4, CMS) clamps to it.
  # Exported here so fetch/mkosi/assemble-disk/build-bundle all inherit the value.
  SOURCE_DATE_EPOCH="$(resolve_source_date_epoch "${PIPELINE_DIR}")"
  CERALIVE_IMAGE_BUILD_COMMIT="${CERALIVE_IMAGE_BUILD_COMMIT:-$(git -C "${PIPELINE_DIR}" rev-parse HEAD)}"
  [[ "${CERALIVE_IMAGE_BUILD_COMMIT}" =~ ^[0-9a-f]{40}$ ]] \
    || die "CERALIVE_IMAGE_BUILD_COMMIT must be an exact 40-character commit SHA"
  export SOURCE_DATE_EPOCH CERALIVE_IMAGE_BUILD_COMMIT
  log_info "reproducible build: SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH} ($(date -u -d "@${SOURCE_DATE_EPOCH}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo n/a))"

  # Opt-in bench PARTLABEL overlay. Logged ONLY when active so an ordinary build's
  # plan output is unchanged, and logged LOUDLY when it is, because the resulting
  # image is bench-only: it is not the frozen contract and must never be released.
  export CERALIVE_BENCH_LABELS="${CERALIVE_BENCH_LABELS:-0}"
  if [[ -n "$(partlabel_prefix)" ]]; then
    log_warn "CERALIVE_BENCH_LABELS=1 — BENCH IMAGE: partitions will be labelled $(resolve_partlabel boot)/$(resolve_partlabel rootfs_a)/$(resolve_partlabel rootfs_b)/$(resolve_partlabel data), NOT the frozen production set. Never publish this artifact."
  fi

  # Debug/production variant seam. Normalized HERE, before the runtime package set
  # is resolved below, because that set now depends on it.
  resolve_debug_image_flag
  if [[ "${CERALIVE_DEBUG_IMAGE}" == "1" ]]; then
    log_warn "CERALIVE_DEBUG_IMAGE=1 — DEBUG IMAGE: the development package delta is installed, the ceralive password is unlocked from CERALIVE_DEBUG_PASSWORD_HASH, ssh.service is enabled and /etc/ceralive/debug-image is baked. Bench only — never publish this artifact to apt."
  fi

  # The resolver guarantees these via JSON-Schema, but assert anyway — a missing
  # BSP declaration must fail BEFORE any fetch/build, never as a half-image.
  require_field ARCH "${ARCH:-}"
  require_field BOARD_ID "${BOARD_ID:-}"
  require_field FAMILY "${FAMILY:-}"
  require_field KERNEL_PACKAGES "${KERNEL_PACKAGES:-}"
  require_field FIRMWARE_PACKAGES "${FIRMWARE_PACKAGES:-}"

  # Kernel-build-from-source is active IFF the resolved manifest carries a
  # kernel_source: block — on rk3588 that is every build, since both its
  # variants build from source. A prebuilt-BSP resolve (a family or variant
  # declaring no such block) leaves this empty and every branch below is inert.
  kernel_from_source=0
  if [[ -n "${KERNEL_SOURCE_GIT_URL:-}" ]]; then
    kernel_from_source=1
    require_field KERNEL_SOURCE_SUPPRESSED_PACKAGES "${KERNEL_SOURCE_SUPPRESSED_PACKAGES:-}"
    require_field KERNEL_SOURCE_DTB_DEB_DIR "${KERNEL_SOURCE_DTB_DEB_DIR:-}"
    require_field KERNEL_SOURCE_DTB_BOOT_DIR "${KERNEL_SOURCE_DTB_BOOT_DIR:-}"
    # Forwarded to fetch-debs.sh so exactly these names are excluded from every
    # remote fetch path. U-Boot and firmware are NOT in this set and stay
    # prebuilt-fetched.
    export CERALIVE_KERNEL_SOURCE_SUPPRESSED_PKGS="${KERNEL_SOURCE_SUPPRESSED_PACKAGES}"
    # build-kernel.sh is a separate process and reads the whole pin set from the
    # environment; every field it requires must be exported here or it fails
    # closed on a "half-specified pin".
    export KERNEL_SOURCE_GIT_URL KERNEL_SOURCE_COMMIT
    export KERNEL_SOURCE_PATCHES_GIT_URL KERNEL_SOURCE_PATCHES_COMMIT
    export KERNEL_SOURCE_PATCHES_SERIES
    # Optional by schema: `tag` is absent for a commit-only source, and exactly
    # one config mode is declared, so the other mode's keys never resolve. They
    # are defaulted rather than bare-exported so build-kernel.sh always receives
    # a defined value and can branch on emptiness instead of on unset-ness.
    export KERNEL_SOURCE_TAG="${KERNEL_SOURCE_TAG:-}"
    export KERNEL_SOURCE_DEFCONFIG_BASE="${KERNEL_SOURCE_DEFCONFIG_BASE:-}"
    export KERNEL_SOURCE_DEFCONFIG_FRAGMENT="${KERNEL_SOURCE_DEFCONFIG_FRAGMENT:-}"
    export KERNEL_SOURCE_DEFCONFIG_FRAGMENTS="${KERNEL_SOURCE_DEFCONFIG_FRAGMENTS:-}"
    export KERNEL_SOURCE_CONFIG_GIT_URL="${KERNEL_SOURCE_CONFIG_GIT_URL:-}"
    export KERNEL_SOURCE_CONFIG_COMMIT="${KERNEL_SOURCE_CONFIG_COMMIT:-}"
    export KERNEL_SOURCE_CONFIG_PATH="${KERNEL_SOURCE_CONFIG_PATH:-}"
    export KERNEL_SOURCE_CONFIG_ABSENT_SYMBOLS="${KERNEL_SOURCE_CONFIG_ABSENT_SYMBOLS:-}"
    export KERNEL_SOURCE_BUILDER_IMAGE KERNEL_SOURCE_LOCAL_VERSION
    export KERNEL_SOURCE_KERNEL_RELEASE KERNEL_SOURCE_PACKAGE_VERSION
    export KERNEL_SOURCE_DTB_DEB_DIR KERNEL_SOURCE_DTB_BOOT_DIR
    export KERNEL_SOURCE_MIRROR_URL="${KERNEL_SOURCE_MIRROR_URL:-}"
    log_info "kernel from source: variant='${KERNEL_VARIANT:-${variant}}' builds ${KERNEL_PACKAGES}; remote fetch suppressed for: ${KERNEL_SOURCE_SUPPRESSED_PACKAGES}"
  fi

  # DTB/U-Boot are required only when installing the boot BSP (rk3588 carries
  # both; x86 legitimately has neither — ACPI + UEFI). Gating on INSTALL_BOOT_BSP
  # fixes task-32 gap G2 without changing the arm64 boot build (still =1 there).
  if [[ "${INSTALL_BOOT_BSP}" == "1" ]]; then
    # A kernel_source variant legitimately resolves DTB_PACKAGES empty: the
    # built linux-image deb carries the in-tree DTBs itself, and the
    # dtb_deb_dir -> dtb_boot_dir mapping (asserted non-empty above, and
    # machine-verified against the real deb by build-kernel.sh) is what
    # satisfies the board's dtb_name instead of a linux-dtb-* package.
    if [[ "${kernel_from_source}" != "1" ]]; then
      require_field DTB_PACKAGES "${DTB_PACKAGES:-}"
    fi
    require_field UBOOT_PACKAGES "${UBOOT_PACKAGES:-}"
  fi

  family_manifest="${MKOSI_DIR}/../manifests/families/${FAMILY}.yaml"
  [[ -f "${family_manifest}" ]] || die "family manifest not found: ${family_manifest}"

  # shared.list (+ resolved family delta, + the debug-only development delta when
  # CERALIVE_DEBUG_IMAGE=1) → $SHARED_PACKAGES for the runtime layer.
  #
  # development.delta.list is keyed on the BUILD VARIANT, not on the board family,
  # so it is deliberately NOT reachable through the ${FAMILY}.delta.list lookup —
  # it is appended only on the debug branch. With the flag unset/0 this resolves
  # byte-identically to before the file existed.
  local pkg_dir="${PIPELINE_DIR}/manifests/packages"
  local shared_list="${pkg_dir}/shared.list" delta_list="${pkg_dir}/${FAMILY}.delta.list"
  local dev_delta_list="${pkg_dir}/${DEV_DELTA_BASENAME}"
  [[ -f "${shared_list}" ]] || die "canonical package list not found: ${shared_list}"
  local -a pkg_lists=("${shared_list}" "${delta_list}")
  local _delta_note=""
  [[ -f "${delta_list}" ]] && _delta_note=" + $(basename "${delta_list}")"
  if [[ "${CERALIVE_DEBUG_IMAGE}" == "1" ]]; then
    [[ -f "${dev_delta_list}" ]] \
      || die "CERALIVE_DEBUG_IMAGE=1 but the development package delta is missing: ${dev_delta_list}"
    pkg_lists+=("${dev_delta_list}")
    _delta_note+=" + ${DEV_DELTA_BASENAME} (DEBUG)"
  fi
  SHARED_PACKAGES="$(read_pkg_list "${pkg_lists[@]}")"
  [[ -n "${SHARED_PACKAGES}" ]] || die "shared.list resolved to an empty package set — refusing to build"
  export SHARED_PACKAGES
  log_info "runtime packages: $(wc -w <<<"${SHARED_PACKAGES}") pkg(s) from shared.list${_delta_note}"

  # mkosi has no 'amd64'; its identifier is 'x86-64' (task 13). arm64 stays arm64.
  case "${ARCH}" in
    arm64) mkosi_arch="arm64" ;;
    amd64|x86-64) mkosi_arch="x86-64" ;;
    *) die "unsupported arch '${ARCH}' (manifest); expected arm64|amd64|x86-64" ;;
  esac
  log_info "resolved: family=${FAMILY} arch=${ARCH} (mkosi=${mkosi_arch}) board_id=${BOARD_ID}"
}
