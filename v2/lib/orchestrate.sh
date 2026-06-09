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
#   6. assemble  mkosi build (base → platform → runtime → app layers) in a trixie builder
#   7. emit      normalized images/<board>/<timestamp>.rootfs.tar (+ .sha256)
#   8. verify    lib/parity-check.sh <rootfs>   → parity vs v2 package manifests
#   9. disk      lib/assemble-disk.sh build → images/<board>/<timestamp>.raw
#                (Stage-4 flashable GPT image). FAMILY-GATED: only the custom-uboot
#                bootloader adapter (RK3588) has a raw bootloader gap to fill; x86
#                (efi) is skipped here — its disk path is task 14.
#
# DESIGN (inherited from common.sh + learnings):
#   * strict mode + loud ERR trap; NO `|| true` swallowing. Any mkosi/apt/dpkg
#     failure aborts the whole build (MUST-NOT: don't swallow build errors).
#   * ZERO hardcoded board names / package lists / device paths. Everything
#     board-specific flows manifest → resolve.sh → environment → mkosi configs.
#   * The rootfs.tar emit (step 7) is the parity artifact and is ALWAYS produced;
#     step 9 lays it onto the frozen A/B GPT geometry only for the RK3588
#     custom-uboot adapter, single-slot or A/B per the manifest's
#     single_slot_fallback flag.
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
ASSEMBLE_DISK_SH="${HERE}/assemble-disk.sh"
BUILD_BUNDLE_SH="${HERE}/build-bundle.sh"
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
# RAUC bundle signing PKI (Stage-4 .raucb, build-bundle.sh). Local/dev builds
# sign with the throwaway NON-PRODUCTION dev keypair in v2/.dev-keys; CI/prod
# inject the real cert-work/rauc keys by setting this env before invocation.
CERALIVE_RAUC_PKI_DIR="${CERALIVE_RAUC_PKI_DIR:-${V2_DIR}/.dev-keys}"
export CERALIVE_RAUC_PKI_DIR
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
  log_info "[1/9] resolving manifest → build params"
  local params
  params="$("${RESOLVE_SH}" "${board}")" || die "manifest resolution failed for board '${board}'"
  eval "${params}"
  # Export BSP package vars immediately so fetch-debs.sh (step 2) can read them.
  # run_mkosi_build() re-exports the full set at step 6; this early export covers
  # the fetch step which runs before mkosi.
  export UBOOT_PACKAGES KERNEL_PACKAGES DTB_PACKAGES FIRMWARE_PACKAGES \
         HW_ACCEL_GSTREAMER_PLUGINS GSTREAMER_RUNTIME_PACKAGES

  # The resolver guarantees these via JSON-Schema, but assert anyway — a missing
  # BSP declaration must fail BEFORE any fetch/build, never as a half-image.
  require_field ARCH "${ARCH:-}"
  require_field BOARD_ID "${BOARD_ID:-}"
  require_field FAMILY "${FAMILY:-}"
  require_field KERNEL_PACKAGES "${KERNEL_PACKAGES:-}"
  require_field FIRMWARE_PACKAGES "${FIRMWARE_PACKAGES:-}"
  # DTB/U-Boot are required only when installing the boot BSP (rk3588 carries
  # both; x86 legitimately has neither — ACPI + UEFI). Gating on INSTALL_BOOT_BSP
  # fixes task-32 gap G2 without changing the arm64 boot build (still =1 there).
  if [[ "${INSTALL_BOOT_BSP}" == "1" ]]; then
    require_field DTB_PACKAGES "${DTB_PACKAGES:-}"
    require_field UBOOT_PACKAGES "${UBOOT_PACKAGES:-}"
  fi

  local family_manifest="${MKOSI_DIR}/../manifests/families/${FAMILY}.yaml"
  [[ -f "${family_manifest}" ]] || die "family manifest not found: ${family_manifest}"

  # shared.list (+ resolved family delta) → $SHARED_PACKAGES for the runtime layer.
  local pkg_dir="${V2_DIR}/manifests/packages"
  local shared_list="${pkg_dir}/shared.list" delta_list="${pkg_dir}/${FAMILY}.delta.list"
  [[ -f "${shared_list}" ]] || die "canonical package list not found: ${shared_list}"
  SHARED_PACKAGES="$(read_pkg_list "${shared_list}" "${delta_list}")"
  [[ -n "${SHARED_PACKAGES}" ]] || die "shared.list resolved to an empty package set — refusing to build"
  export SHARED_PACKAGES
  local _delta_note=""
  [[ -f "${delta_list}" ]] && _delta_note=" + $(basename "${delta_list}")"
  log_info "runtime packages: $(wc -w <<<"${SHARED_PACKAGES}") pkg(s) from shared.list${_delta_note}"

  # mkosi has no 'amd64'; its identifier is 'x86-64' (task 13). arm64 stays arm64.
  local mkosi_arch
  case "${ARCH}" in
    arm64) mkosi_arch="arm64" ;;
    amd64|x86-64) mkosi_arch="x86-64" ;;
    *) die "unsupported arch '${ARCH}' (manifest); expected arm64|amd64|x86-64" ;;
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

  log_info "[2/9] fetching .debs (BSP from Armbian + first-party from R2/gh) → ${staging}"
  DEST="${staging}" "${FETCH_DEBS_SH}" --family "${family_manifest}" --dest "${staging}" \
    || die "fetch-debs failed for board '${board}'"

  log_info "[3/9] partitioning staged .debs into BSP vs first-party by package name"
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
    log_info "[4/9] verifying boot BSP packages are obtainable"
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
    log_warn "[4/9] INSTALL_BOOT_BSP=0 — config+package parity build; boot BSP (kernel/DTB/U-Boot/firmware) deferred to the hardware build (task 17)"
  fi

  # DRY_RUN=1 (v2-ci build matrix): resolve+fetch ran with network suppressed
  # (fetch-debs run_or_plan, task 14); emit the mkosi plan and stop before
  # mkosi/docker so CI needs no network, privileged container or board.
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log_info "[5/9] DRY_RUN=1 — would build with: mkosi --architecture=${mkosi_arch} --with-network=yes --package-directory ${STAGING_ROOT}/${board}/bsp --extra-tree ${STAGING_ROOT}/${board}/firstparty:/opt/ceralive-staging --force build"
    log_success "=== DRY-RUN complete: board='${board}' (${mkosi_arch}) resolved → builder plan emitted; no network/hardware touched ==="
    exit 0
  fi

  # -------------------------------------------------------------------------
  # 6. Assemble: mkosi builds base → platform → runtime → app in the trixie builder.
  # -------------------------------------------------------------------------
  local ts rootfs_tree
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  rootfs_tree="${MKOSI_DIR}/build/app"
  log_info "[5/9] building image layers with mkosi (${mkosi_arch}) — base → platform → runtime → app"
  run_mkosi_build "${mkosi_arch}" "${bsp_dir}" "${firstparty_dir}"
  [[ -d "${rootfs_tree}" ]] || die "mkosi did not produce an app rootfs at ${rootfs_tree}"

  # -------------------------------------------------------------------------
  # 7. Emit normalized output + checksum (NOT Armbian-unofficial_*).
  # -------------------------------------------------------------------------
  log_info "[6/9] emitting normalized artifact images/${board}/${ts}.rootfs.tar"
  local out_dir="${IMAGES_DIR}/${board}" artifact
  mkdir -p "${out_dir}"
  artifact="${out_dir}/${ts}.rootfs.tar"
  emit_artifact "${rootfs_tree}" "${artifact}"
  log_success "artifact: ${artifact} ($(du -h "${artifact}" | cut -f1)), sha256 in ${artifact}.sha256"

  # -------------------------------------------------------------------------
  # 8. Parity verification vs the v2 package manifests. The app layer now
  #    installs the first-party .debs (Stage 3, app/mkosi.postinst.chroot), so in
  #    CI mode (debs fetched) the gate clears the first-party check via the
  #    ceraui→ceralive-device / belacoder→ceracoder aliases in parity-check.sh. An
  #    offline/dev build stages no debs → installs nothing → the gate WARNs on the
  #    absent first-party packages, by design. Documented in LAYER-MAP.md §Layer 4.
  # -------------------------------------------------------------------------
  log_info "[7/9] verifying parity vs v2 package manifests"
  "${PARITY_CHECK_SH}" "${rootfs_tree}" \
    || die "parity check FAILED for board '${board}' — image does not match the canonical package/service/user/routing set"

  # -------------------------------------------------------------------------
  # 9. Stage-4 disk assembly. Lay the rootfs onto the FROZEN A/B GPT geometry and
  #    (RK3588) write the U-Boot blob into the 16 MB raw gap, emitting a flashable
  #    .raw ALONGSIDE the rootfs.tar above. FAMILY-GATED on the resolved
  #    rauc_bootloader_adapter: only `custom` (RK3588 vendor U-Boot, decision D3 —
  #    the "custom-uboot" adapter) has a raw bootloader gap to fill. x86 resolves
  #    `efi` and boots from the EFI System Partition; its disk path is task 14, so
  #    it is skipped here. The gap write needs the staged U-Boot .deb, so a
  #    config+package parity build (INSTALL_BOOT_BSP=0, no BSP staged) defers disk
  #    assembly to the full device build — exactly like the boot-BSP gate above.
  # -------------------------------------------------------------------------
  if [[ "${RAUC_BOOTLOADER_ADAPTER:-}" == "custom" ]]; then
    if [[ "${INSTALL_BOOT_BSP}" == "1" ]]; then
      local raw_artifact="${out_dir}/${ts}.raw" single_slot_flag=()
      [[ "${SINGLE_SLOT_FALLBACK:-false}" == "true" ]] && single_slot_flag+=(--single-slot)
      log_info "[8/9] Stage-4 disk assembly → ${raw_artifact} (bootloader_adapter=custom single_slot=${SINGLE_SLOT_FALLBACK:-false})"
      "${ASSEMBLE_DISK_SH}" build \
        --output "${raw_artifact}" \
        "${single_slot_flag[@]}" \
        --board "${BOARD_ID}" \
        --bootloader-adapter "${RAUC_BOOTLOADER_ADAPTER}" \
        --bsp-dir "${bsp_dir}" \
        --rootfs-tree "${rootfs_tree}" \
        || die "Stage-4 disk assembly failed for board '${board}'"
      log_success "flashable image: ${raw_artifact} ($(du -h "${raw_artifact}" | cut -f1))"

      # Stage-4 FINAL artifact: a signed RAUC OTA bundle (.raucb + .sha256),
      # stamped with the same board-specific COMPATIBLE_STRING and timestamp as
      # the .raw, emitted ALONGSIDE it. format=plain (no dm-verity, G4 deferred).
      local bundle_artifact="${out_dir}/${ts}.raucb"
      log_info "[8/9] Stage-4 RAUC bundle → ${bundle_artifact} (signed, compatible=${COMPATIBLE_STRING:-unset}, pki=${CERALIVE_RAUC_PKI_DIR})"
      BUNDLE_VERSION="${ts}" BUNDLE_OUT_DIR="${out_dir}" BUNDLE_TS="${ts}" \
        "${BUILD_BUNDLE_SH}" "${BOARD_ID}" "${artifact}" \
        || die "Stage-4 RAUC bundle build failed for board '${board}'"
      log_success "signed bundle: ${bundle_artifact} ($(du -h "${bundle_artifact}" | cut -f1)), sha256 in ${bundle_artifact}.sha256"
    else
      log_warn "[8/9] INSTALL_BOOT_BSP=0 — config+package parity build; Stage-4 disk assembly (flashable .raw) deferred to the full device build"
    fi
  elif [[ "${RAUC_BOOTLOADER_ADAPTER:-}" == "efi" || "${RAUC_BOOTLOADER_ADAPTER:-}" == "grub" ]]; then
    # x86 EFI/GRUB disk assembly is DEFERRED — explicitly, not skipped-and-forgotten.
    # efi/grub boots from an EFI System Partition + GRUB A/B grubenv engine (exercised
    # by tests/qemu-x86.sh --fallback-selftest), not the RK3588 raw idbloader gap that
    # assemble-disk.sh/write-bootloader.sh write. Routing x86 through the `custom` .raw
    # path would emit a NON-BOOTABLE image, so this branch produces NO .raw and stops
    # cleanly after the step-7 rootfs.tar (no partial disk state).
    # TODO(x86-disk): wire x86 ESP + GRUB A/B disk assembly behind this gate
    #   (ESP/grub-install layout, grubenv A/B slot selection, RAUC efi adapter).
    log_info "[8/9] bootloader_adapter='${RAUC_BOOTLOADER_ADAPTER}' — x86 ESP+GRUB disk assembly DEFERRED (TODO(x86-disk)); rootfs.tar is the only artifact, no .raw produced for board '${board}'"
  else
    die "[8/9] unsupported bootloader_adapter '${RAUC_BOOTLOADER_ADAPTER:-unset}' for board '${board}' — no Stage-4 disk-assembly path is wired (expected 'custom' for RK3588 or 'efi'/'grub' for x86); refusing to emit a partial image"
  fi

  log_info "[9/9] done"
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
    ARCH RELEASE CHANNEL VARIANT BOARD_ID FAMILY SERIAL_CONSOLE DTB_NAME
    INSTALL_BOOT_BSP ARMBIAN_APT_URL ARMBIAN_SUITE
    KERNEL_PACKAGES DTB_PACKAGES UBOOT_PACKAGES FIRMWARE_PACKAGES
    HW_ACCEL_GSTREAMER_PLUGINS GSTREAMER_RUNTIME_PACKAGES
    SHARED_PACKAGES SINGLE_SLOT_FALLBACK
    APT_CLIENT_CRT_B64 APT_CLIENT_KEY_B64 APT_GPG_PUBLIC_B64
    RAUC_ROOT_CA_B64 COMPATIBLE_STRING
  )
  # Export each (default empty for the secrets) so both `--environment NAME`
  # inheritance and docker `-e NAME` passthrough resolve. DTB_NAME feeds the
  # platform bootloader integration (mkosi.finalize → install-boot.sh): the U-Boot
  # boot.scr / extlinux fdtfile and the board env come from the manifest, never
  # hardcoded.
  export ARCH RELEASE CHANNEL VARIANT BOARD_ID FAMILY SERIAL_CONSOLE DTB_NAME
  export INSTALL_BOOT_BSP ARMBIAN_APT_URL ARMBIAN_SUITE
  export KERNEL_PACKAGES DTB_PACKAGES UBOOT_PACKAGES FIRMWARE_PACKAGES
  export HW_ACCEL_GSTREAMER_PLUGINS="${HW_ACCEL_GSTREAMER_PLUGINS:-}"
  export GSTREAMER_RUNTIME_PACKAGES="${GSTREAMER_RUNTIME_PACKAGES:-}"
  export SHARED_PACKAGES="${SHARED_PACKAGES:-}"
  # Stage 4 disk-assembly flag (manifest single_slot_fallback) consumed by
  # lib/assemble-disk.sh; default false (A/B). See v2/mkosi/repart/README.md.
  export SINGLE_SLOT_FALLBACK="${SINGLE_SLOT_FALLBACK:-false}"
  export APT_CLIENT_CRT_B64="${APT_CLIENT_CRT_B64:-}"
  export APT_CLIENT_KEY_B64="${APT_CLIENT_KEY_B64:-}"
  export APT_GPG_PUBLIC_B64="${APT_GPG_PUBLIC_B64:-}"

  # RAUC device keyring (task 26): the IMMUTABLE root CA baked in at first flash,
  # committed (PUBLIC) at mkosi/runtime/rauc/ceralive-keyring.pem. Forwarded base64
  # (like the apt GPG key) so the self-contained runtime postinst can write it
  # without repo access.
  local rauc_keyring="${MKOSI_DIR}/runtime/rauc/ceralive-keyring.pem"
  if [[ -z "${RAUC_ROOT_CA_B64:-}" && -s "${rauc_keyring}" ]]; then
    RAUC_ROOT_CA_B64="$(base64 -w0 <"${rauc_keyring}")"
  fi
  export RAUC_ROOT_CA_B64="${RAUC_ROOT_CA_B64:-}"

  # RAUC `compatible` — the single source of truth (T12), BOARD-specific not
  # family-wide. A family default (ceralive-rk3588) lets an Orange Pi 5+ bundle
  # install on a Rock 5B+; deriving from board_id and having install-boot.sh +
  # build-bundle.sh read THIS env (no own default) keeps device + bundle in lockstep.
  export COMPATIBLE_STRING="${COMPATIBLE_STRING:-ceralive-${BOARD_ID}}"

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
    -e "CERALIVE_V2_DIR=/work" \
    -v "${V2_DIR}:/work" \
    "${MKOSI_BUILDER_IMAGE}" \
    bash -euo pipefail -c '
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -y --no-install-recommends \
        mkosi debian-archive-keyring apt-utils dpkg-dev ca-certificates reprepro >/dev/null
      cd /work/mkosi
      mkosi \
        --architecture='"${mkosi_arch}"' \
        --with-network=yes \
        '"${env_cli_str}"' \
        --package-directory /work/mkosi/.staging/'"${BOARD_ID}"'/bsp \
        --extra-tree /work/mkosi/.staging/'"${BOARD_ID}"'/firstparty:/opt/ceralive-staging \
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
      tar -C "/work/build/app" -cf "/out/$(basename "${artifact}")" .
  fi
  ( cd "$(dirname "${artifact}")" && sha256sum "$(basename "${artifact}")" >"$(basename "${artifact}").sha256" )
}

main "$@"
