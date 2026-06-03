#!/usr/bin/env bash
#
# orchestrate.sh — end-to-end builder for the CeraLive v2 image pipeline.
#
# `build <board>` (v2/build) execs this with --board/--manifest. It turns a board
# manifest into a flashable RK3588 rootfs by chaining the pieces built in tasks
# 9-14:
#
#   1. resolve   lib/resolve.sh <board>        → flat KEY=value build params (eval'd)
#   2. gate      required BSP package sets present                (fail loud, pre-build)
#   3. fetch     lib/fetch-debs.sh --family …   → stage BSP + first-party .debs
#   4. partition split staged .debs into BSP vs first-party by package name
#   5. gate      every boot-BSP package obtainable (when INSTALL_BOOT_BSP=1)
#                → else: "cannot resolve package <name>"  ABORT, no half-image
#   6. assemble  mkosi build (base → platform → runtime layers) in a trixie builder
#   7. emit      normalized images/<board>/<timestamp>.rootfs.tar (+ .sha256)
#   8. verify    lib/parity-check.sh <rootfs>   → parity vs configs/base/ceraui-base.conf
#
# DESIGN (inherited from common.sh + learnings):
#   * strict mode + loud ERR trap; NO `|| true` swallowing. Any mkosi/apt/dpkg
#     failure aborts the whole build (MUST-NOT: don't swallow build errors).
#   * ZERO hardcoded board names / package lists / device paths. Everything
#     board-specific flows manifest → resolve.sh → environment → mkosi configs.
#   * No A/B partitions yet (Stage 4). Stage 1 emits a single rootfs to reach
#     PARITY with today's Armbian image first.
#
# shellcheck shell=bash

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${HERE}/common.sh"

# ---------------------------------------------------------------------------
# Locations.
# ---------------------------------------------------------------------------
V2_DIR="$(cd "${HERE}/.." && pwd)"
RESOLVE_SH="${HERE}/resolve.sh"
FETCH_DEBS_SH="${HERE}/fetch-debs.sh"
PARITY_CHECK_SH="${HERE}/parity-check.sh"
MKOSI_DIR="${V2_DIR}/mkosi"
IMAGES_DIR="${V2_DIR}/images"
# Staged .debs live under the mkosi dir (so the builder container, which mounts
# MKOSI_DIR, can see them) but OUTSIDE build/ — `mkosi --force` wipes build/ image
# outputs, and we must not lose the staging mid-build. Gitignored via mkosi/.gitignore.
STAGING_ROOT="${MKOSI_DIR}/.staging"

# ---------------------------------------------------------------------------
# Configuration (env-overridable; never hardcode product constants in logic).
# ---------------------------------------------------------------------------
# Full device builds install the heavy boot BSP (kernel/DTB/U-Boot/firmware).
# Set INSTALL_BOOT_BSP=0 to reach config+package PARITY without the emulated
# kernel install (the boot BSP is hardware-validated in task 17). This is a
# build-scope flag, NOT error swallowing.
INSTALL_BOOT_BSP="${INSTALL_BOOT_BSP:-1}"
CHANNEL="${CHANNEL:-stable}"
VARIANT="${VARIANT:-standard}"
RELEASE="${RELEASE:-bookworm}"
ARMBIAN_APT_URL="${ARMBIAN_APT_URL:-https://apt.armbian.com}"
ARMBIAN_SUITE="${ARMBIAN_SUITE:-bookworm}"
# Trixie builder: mkosi 26 needs Python >= 3.12; bookworm can't run it, native
# Arch lacks apt/keyring (task 2/13). One pinned builder image for both.
MKOSI_BUILDER_IMAGE="${MKOSI_BUILDER_IMAGE:-debian:trixie-slim}"

usage() {
  cat >&2 <<EOF
Usage: orchestrate.sh --board <board> --manifest <file> [options]

Builds the CeraLive v2 image for <board> from its manifest.

Env:
  INSTALL_BOOT_BSP   1 (default) full device build incl. kernel/DTB/U-Boot/firmware
                     0           config+package parity only (boot BSP via task 17)
  CHANNEL VARIANT RELEASE ARMBIAN_APT_URL ARMBIAN_SUITE MKOSI_BUILDER_IMAGE
  APT_CLIENT_CRT_B64 APT_CLIENT_KEY_B64 APT_GPG_PUBLIC_B64   (CI secrets, mTLS+GPG)
EOF
}

# ---------------------------------------------------------------------------
# deb_pkg_name — read the Package: field of a .deb without dpkg (host is Arch).
# Uses `ar` + tar on control.tar.* . Echoes the package name or empty.
# ---------------------------------------------------------------------------
deb_pkg_name() {
  local deb="$1" tmp name=""
  tmp="$(mktemp -d)"
  if ar p "${deb}" control.tar.gz 2>/dev/null | tar -xzO -C "${tmp}" ./control 2>/dev/null >"${tmp}/control"; then
    :
  elif ar p "${deb}" control.tar.xz 2>/dev/null | tar -xJO ./control 2>/dev/null >"${tmp}/control"; then
    :
  elif ar p "${deb}" control.tar.zst 2>/dev/null | tar --zstd -xO ./control 2>/dev/null >"${tmp}/control"; then
    :
  fi
  if [[ -s "${tmp}/control" ]]; then
    name="$(awk -F': ' '/^Package:/{print $2; exit}' "${tmp}/control")"
  fi
  rm -rf "${tmp}"
  printf '%s' "${name}"
}

# ---------------------------------------------------------------------------
# require_field — die loudly if a resolved param is empty (no silent defaults).
# ---------------------------------------------------------------------------
require_field() {
  local name="$1" val="$2"
  [[ -n "${val}" ]] || die "manifest did not resolve required field '${name}' — refusing to build a half-image"
}

main() {
  local board="" manifest=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --board)    board="${2:-}"; shift 2 ;;
      --manifest) manifest="${2:-}"; shift 2 ;;
      -h|--help)  usage; exit 0 ;;
      *) usage; die "unknown argument: $1" ;;
    esac
  done

  [[ -n "${board}" ]]    || { usage; die "--board is required"; }
  [[ -n "${manifest}" ]] || { usage; die "--manifest is required"; }
  require_cmd python3
  require_cmd ar
  require_cmd tar

  log_info "=== CeraLive v2 build: board='${board}' ==="
  log_info "manifest=${manifest} install_boot_bsp=${INSTALL_BOOT_BSP} channel=${CHANNEL} variant=${VARIANT}"

  # -------------------------------------------------------------------------
  # 1. Resolve manifest → flat build params, into THIS shell's environment.
  #    resolve.sh dies loudly on unknown board/family, schema violations and
  #    unresolved versions.yaml defer tokens; its failure propagates here.
  # -------------------------------------------------------------------------
  log_info "[1/8] resolving manifest → build params"
  local params
  params="$("${RESOLVE_SH}" "${board}")" || die "manifest resolution failed for board '${board}'"
  eval "${params}"

  # The resolver guarantees these via JSON-Schema, but assert anyway — a missing
  # BSP declaration must fail BEFORE any fetch/build, never as a half-image.
  require_field ARCH "${ARCH:-}"
  require_field BOARD_ID "${BOARD_ID:-}"
  require_field FAMILY "${FAMILY:-}"
  require_field KERNEL_PACKAGES "${KERNEL_PACKAGES:-}"
  require_field DTB_PACKAGES "${DTB_PACKAGES:-}"
  require_field UBOOT_PACKAGES "${UBOOT_PACKAGES:-}"
  require_field FIRMWARE_PACKAGES "${FIRMWARE_PACKAGES:-}"

  local family_manifest="${MKOSI_DIR}/../manifests/families/${FAMILY}.yaml"
  [[ -f "${family_manifest}" ]] || die "family manifest not found: ${family_manifest}"

  # mkosi has no 'amd64'; its identifier is 'x86-64' (task 13). arm64 stays arm64.
  local mkosi_arch
  case "${ARCH}" in
    arm64) mkosi_arch="arm64" ;;
    amd64) mkosi_arch="x86-64" ;;
    *) die "unsupported arch '${ARCH}' (manifest); expected arm64|amd64" ;;
  esac
  log_info "resolved: family=${FAMILY} arch=${ARCH} (mkosi=${mkosi_arch}) board_id=${BOARD_ID}"

  # -------------------------------------------------------------------------
  # 2-4. Fetch + stage .debs, then partition them into BSP vs first-party.
  # -------------------------------------------------------------------------
  local staging="${STAGING_ROOT}/${board}"
  rm -rf "${staging}"
  mkdir -p "${staging}"
  local bsp_dir="${staging}/bsp" firstparty_dir="${staging}/firstparty"
  mkdir -p "${bsp_dir}" "${firstparty_dir}"

  log_info "[2/8] fetching .debs (BSP from Armbian + first-party from R2/gh) → ${staging}"
  DEST="${staging}" "${FETCH_DEBS_SH}" --family "${family_manifest}" --dest "${staging}" \
    || die "fetch-debs failed for board '${board}'"

  log_info "[3/8] partitioning staged .debs into BSP vs first-party by package name"
  # The set of BSP package names (manifest-declared) is the partition key.
  local bsp_names=" ${KERNEL_PACKAGES} ${DTB_PACKAGES} ${UBOOT_PACKAGES} ${FIRMWARE_PACKAGES} ${HW_ACCEL_GSTREAMER_PLUGINS:-} ${GSTREAMER_RUNTIME_PACKAGES:-} "
  local deb pkg
  shopt -s nullglob
  for deb in "${staging}/debs"/*.deb; do
    pkg="$(deb_pkg_name "${deb}")"
    if [[ -n "${pkg}" && "${bsp_names}" == *" ${pkg} "* ]]; then
      cp "${deb}" "${bsp_dir}/"
    else
      cp "${deb}" "${firstparty_dir}/"
    fi
  done
  shopt -u nullglob
  log_info "staged: $(find "${bsp_dir}" -name '*.deb' | wc -l) BSP, $(find "${firstparty_dir}" -name '*.deb' | wc -l) first-party .deb(s)"

  # -------------------------------------------------------------------------
  # 5. Missing-BSP gate. For a full device build the kernel/DTB/U-Boot/firmware
  #    MUST be obtainable; if any is not staged, abort BEFORE mkosi — clean
  #    failure, no half-image (MUST-DO: fail cleanly on missing BSP pin).
  # -------------------------------------------------------------------------
  if [[ "${INSTALL_BOOT_BSP}" == "1" ]]; then
    log_info "[4/8] verifying boot BSP packages are obtainable"
    local boot_bsp_names name missing=()
    read -ra boot_bsp_names <<<"${KERNEL_PACKAGES} ${DTB_PACKAGES} ${UBOOT_PACKAGES} ${FIRMWARE_PACKAGES}"
    for name in "${boot_bsp_names[@]}"; do
      if ! compgen -G "${bsp_dir}/${name}_*.deb" >/dev/null \
         && ! compgen -G "${bsp_dir}/${name}-*.deb" >/dev/null; then
        missing+=("${name}")
      fi
    done
    if (( ${#missing[@]} > 0 )); then
      for name in "${missing[@]}"; do
        log_error "cannot resolve package '${name}': no .deb staged from ${ARMBIAN_APT_URL} (${ARMBIAN_SUITE}/${ARCH})"
      done
      die "missing ${#missing[@]} required BSP package(s); aborting before mkosi — no half-image produced. (Set INSTALL_BOOT_BSP=0 for a config+package parity build, or provide R2/Armbian access.)"
    fi
    log_success "all ${#boot_bsp_names[@]} boot BSP package(s) staged"
  else
    log_warn "[4/8] INSTALL_BOOT_BSP=0 — config+package parity build; boot BSP (kernel/DTB/U-Boot/firmware) deferred to the hardware build (task 17)"
  fi

  # -------------------------------------------------------------------------
  # 6. Assemble: mkosi builds base → platform → runtime in the trixie builder.
  # -------------------------------------------------------------------------
  local ts rootfs_tree
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  rootfs_tree="${MKOSI_DIR}/build/runtime"
  log_info "[5/8] building image layers with mkosi (${mkosi_arch}) — base → platform → runtime"
  run_mkosi_build "${mkosi_arch}" "${bsp_dir}" "${firstparty_dir}"
  [[ -d "${rootfs_tree}" ]] || die "mkosi did not produce a runtime rootfs at ${rootfs_tree}"

  # -------------------------------------------------------------------------
  # 7. Emit normalized output + checksum (NOT Armbian-unofficial_*).
  # -------------------------------------------------------------------------
  log_info "[6/8] emitting normalized artifact images/${board}/${ts}.rootfs.tar"
  local out_dir="${IMAGES_DIR}/${board}" artifact
  mkdir -p "${out_dir}"
  artifact="${out_dir}/${ts}.rootfs.tar"
  emit_artifact "${rootfs_tree}" "${artifact}"
  log_success "artifact: ${artifact} ($(du -h "${artifact}" | cut -f1)), sha256 in ${artifact}.sha256"

  # -------------------------------------------------------------------------
  # 8. Parity verification vs configs/base/ceraui-base.conf.
  # -------------------------------------------------------------------------
  log_info "[7/8] verifying parity vs configs/base/ceraui-base.conf"
  "${PARITY_CHECK_SH}" "${rootfs_tree}" \
    || die "parity check FAILED for board '${board}' — image does not match the canonical package/service/user/routing set"

  log_info "[8/8] done"
  log_success "=== build complete: board='${board}' → ${artifact} ==="
}

# ---------------------------------------------------------------------------
# run_mkosi_build <mkosi_arch> <bsp_dir> <firstparty_dir>
#
# Runs `mkosi build` for the full layer chain. Native if the host can (Debian +
# mkosi + keyring); otherwise inside the pinned trixie builder container (the
# Arch-host path, task 2/13). qemu-user F-flag (kernel-global) handles arm64.
# All board/secret values flow via the environment → mkosi Environment= → scripts.
# ---------------------------------------------------------------------------
run_mkosi_build() {
  local mkosi_arch="$1" bsp_dir="$2" firstparty_dir="$3"

  # The board/product/secret values mkosi must forward into the post-install
  # scripts. Passed as `--environment NAME` CLI flags (bare name = inherit from
  # the invoking environment) so the same set works on host mkosi 26 and the
  # trixie-builder mkosi 25.3 (which disagree on the [Content]/[Build] section).
  local env_names=(
    ARCH RELEASE CHANNEL VARIANT BOARD_ID FAMILY SERIAL_CONSOLE
    INSTALL_BOOT_BSP ARMBIAN_APT_URL ARMBIAN_SUITE
    KERNEL_PACKAGES DTB_PACKAGES UBOOT_PACKAGES FIRMWARE_PACKAGES
    HW_ACCEL_GSTREAMER_PLUGINS GSTREAMER_RUNTIME_PACKAGES
    APT_CLIENT_CRT_B64 APT_CLIENT_KEY_B64 APT_GPG_PUBLIC_B64
  )
  # Export each (default empty for the secrets) so both `--environment NAME`
  # inheritance and docker `-e NAME` passthrough resolve.
  export ARCH RELEASE CHANNEL VARIANT BOARD_ID FAMILY SERIAL_CONSOLE
  export INSTALL_BOOT_BSP ARMBIAN_APT_URL ARMBIAN_SUITE
  export KERNEL_PACKAGES DTB_PACKAGES UBOOT_PACKAGES FIRMWARE_PACKAGES
  export HW_ACCEL_GSTREAMER_PLUGINS="${HW_ACCEL_GSTREAMER_PLUGINS:-}"
  export GSTREAMER_RUNTIME_PACKAGES="${GSTREAMER_RUNTIME_PACKAGES:-}"
  export APT_CLIENT_CRT_B64="${APT_CLIENT_CRT_B64:-}"
  export APT_CLIENT_KEY_B64="${APT_CLIENT_KEY_B64:-}"
  export APT_GPG_PUBLIC_B64="${APT_GPG_PUBLIC_B64:-}"

  local env_cli=() n
  for n in "${env_names[@]}"; do env_cli+=(--environment "${n}"); done

  local mkosi_args=(
    --architecture="${mkosi_arch}"
    --with-network=yes
    "${env_cli[@]}"
    --package-directory "${bsp_dir}"
    --extra-tree "${firstparty_dir}:/opt/ceralive-staging"
    --force
    build
  )

  if [[ "${MKOSI_NATIVE:-}" == "1" ]] \
     || { command -v mkosi >/dev/null 2>&1 && [[ -f /usr/share/keyrings/debian-archive-keyring.gpg ]]; }; then
    log_info "mkosi: native build (host has apt keyring)"
    ( cd "${MKOSI_DIR}" && mkosi "${mkosi_args[@]}" ) \
      || die "mkosi build failed (native)"
    return
  fi

  # Container path (Arch host → trixie builder). docker `-e NAME` forwards the
  # value; the in-container mkosi re-declares the same names via --environment.
  local runtime=""
  if command -v docker >/dev/null 2>&1; then runtime="docker"
  elif command -v podman >/dev/null 2>&1; then runtime="podman"
  else die "no native mkosi keyring and neither docker nor podman present — cannot run the trixie builder"; fi

  log_info "mkosi: ${runtime} builder ${MKOSI_BUILDER_IMAGE} (Arch host → trixie container)"
  local env_flags=() env_cli_str=""
  for n in "${env_names[@]}"; do
    env_flags+=(-e "${n}")
    env_cli_str+=" --environment ${n}"
  done

  "${runtime}" run --rm --privileged \
    "${env_flags[@]}" \
    -v "${MKOSI_DIR}:/work" \
    "${MKOSI_BUILDER_IMAGE}" \
    bash -euo pipefail -c '
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -y --no-install-recommends \
        mkosi debian-archive-keyring apt-utils dpkg-dev ca-certificates >/dev/null
      cd /work
      mkosi \
        --architecture='"${mkosi_arch}"' \
        --with-network=yes \
        '"${env_cli_str}"' \
        --package-directory /work/.staging/'"${BOARD_ID}"'/bsp \
        --extra-tree /work/.staging/'"${BOARD_ID}"'/firstparty:/opt/ceralive-staging \
        --force \
        build
    ' || die "mkosi build failed (container)"
}

# ---------------------------------------------------------------------------
# emit_artifact <rootfs_tree> <artifact.tar>
# Produce a normalized, deterministic tarball + sha256. Runs in the builder
# container when the tree is root-owned and the host can't read/tar it.
# ---------------------------------------------------------------------------
emit_artifact() {
  local tree="$1" artifact="$2"
  if tar -C "${tree}" -cf "${artifact}" . 2>/dev/null; then
    :
  else
    log_info "rootfs is root-owned — tarring inside the builder container"
    local runtime="docker"; command -v docker >/dev/null 2>&1 || runtime="podman"
    "${runtime}" run --rm \
      -v "${MKOSI_DIR}:/work" -v "$(dirname "${artifact}")":/out \
      "${MKOSI_BUILDER_IMAGE}" \
      tar -C "/work/build/runtime" -cf "/out/$(basename "${artifact}")" .
  fi
  ( cd "$(dirname "${artifact}")" && sha256sum "$(basename "${artifact}")" >"$(basename "${artifact}").sha256" )
}

main "$@"
