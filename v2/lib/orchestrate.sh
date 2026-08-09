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
#               (staging is always recreated and authenticated for each build)
#   4. partition split staged .debs into BSP vs first-party by package name
#   5. gate      every boot-BSP package obtainable (when INSTALL_BOOT_BSP=1)
#                → else: "cannot resolve package <name>"  ABORT, no half-image
#   6. assemble  mkosi build (base → platform → runtime → app layers) in a trixie builder
#   7. emit      normalized images/<board>/<timestamp>.rootfs.tar (+ .sha256)
#  7b. gate      lib/verify-boot-artifacts.sh   [6b/9] → /boot carries a resolvable
#                Image + board DTB + versioned initrd (arm64 boot-BSP builds only)
#  7c. gate      lib/measure-size.sh            [6c/9] → rootfs CONTENT is within the
#                per-board rootfs_bytes_max in manifests/size-budget.json. BLOCKING:
#                an over-budget image fails HERE, so no .raw and no .raucb are cut.
#   8. verify    lib/parity-check.sh <rootfs>   → parity vs v2 package manifests
#   9. disk      lib/assemble-disk.sh build → images/<board>/<timestamp>.raw
#                (Stage-4 flashable GPT image). FAMILY-GATED on the bootloader adapter:
#                custom-uboot (RK3588) fills the raw idbloader gap via assemble-disk.sh;
#                efi/grub (x86) lays an ESP + RAUC-native GRUB A/B via assemble-disk-x86.sh.
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
DEARMOR_APT_KEYRING_SH="${HERE}/dearmor-apt-keyring.sh"
MKOSI_PACKAGE_STAGING_SH="${HERE}/stage-mkosi-package.sh"
BUILD_KERNEL_SH="${HERE}/build-kernel.sh"
PARITY_CHECK_SH="${HERE}/parity-check.sh"
VERIFY_BOOT_ARTIFACTS_SH="${HERE}/verify-boot-artifacts.sh"
MEASURE_SIZE_SH="${HERE}/measure-size.sh"
CHECK_SIZE_REGRESSION_SH="${V2_DIR}/ci/check-size-regression.sh"
SIZE_BASELINE_DIR="${V2_DIR}/ci"
ASSEMBLE_DISK_SH="${HERE}/assemble-disk.sh"
ASSEMBLE_DISK_X86_SH="${HERE}/assemble-disk-x86.sh"
BUILD_BUNDLE_SH="${HERE}/build-bundle.sh"
RAUC_PKI_CONTRACT_SH="${HERE}/rauc-pki-contract.sh"
MKOSI_DIR="${V2_DIR}/mkosi"
IMAGES_DIR="${V2_DIR}/images"
# Staged .debs live under the mkosi dir (so the builder container, which mounts
# MKOSI_DIR, can see them) but OUTSIDE build/ — `mkosi --force` wipes build/ image
# outputs, and we must not lose the staging mid-build. Gitignored via mkosi/.gitignore.
STAGING_ROOT="${MKOSI_DIR}/.staging"
BUILD_LOCK_DIR="${CERALIVE_BUILD_LOCK_DIR:-${STAGING_ROOT}/.locks}"
BUILD_LOCK_TIMEOUT="${CERALIVE_BUILD_LOCK_TIMEOUT:-3600}"
BUILD_LOCK_FD=""

# ---------------------------------------------------------------------------
# Configuration (env-overridable; never hardcode product constants in logic).
# ---------------------------------------------------------------------------
# Full device builds install the heavy boot BSP (kernel/DTB/U-Boot/firmware).
# Set INSTALL_BOOT_BSP=0 to reach config+package PARITY without the emulated
# kernel install (the boot BSP is hardware-validated in task 17). This is a
# build-scope flag, NOT error swallowing.
INSTALL_BOOT_BSP="${INSTALL_BOOT_BSP:-1}"
# shellcheck source=lib/rauc-pki-contract.sh
source "${RAUC_PKI_CONTRACT_SH}"
CERALIVE_BUILD_MODE="${CERALIVE_BUILD_MODE:-development}"
rauc_pki_resolve "${CERALIVE_BUILD_MODE}" "${CERALIVE_RAUC_PKI_DIR:-}" "${RAUC_KEYRING_FILE:-}"
export CERALIVE_BUILD_MODE CERALIVE_RAUC_PKI_DIR RAUC_KEYRING_FILE RAUC_ROOT_SHA256
CHANNEL="${CHANNEL:-stable}"
VARIANT="${VARIANT:-standard}"
RELEASE="${RELEASE:-bookworm}"
ARMBIAN_APT_URL="${ARMBIAN_APT_URL:-https://apt.armbian.com}"
ARMBIAN_SUITE="${ARMBIAN_SUITE:-bookworm}"
# ---------------------------------------------------------------------------
# Builder selection (task 9). The CANONICAL build runs mkosi inside a pinned
# Debian trixie container baked from v2/ci/Dockerfile; native host mkosi is
# opt-in only (--native / MKOSI_NATIVE=1). Rationale: mkosi 26 (the
# .mkosi-version pin) needs Python >= 3.12, which bookworm (the target rootfs
# release) can't provide and a non-Debian host lacks apt/keyring for — one pinned
# trixie builder gives a reproducible toolchain on any host.
MKOSI_NATIVE="${MKOSI_NATIVE:-}"
# mkosi pin — single source of truth is v2/.mkosi-version (= 26).
MKOSI_VERSION_PIN="$(tr -d '[:space:]' <"${V2_DIR}/.mkosi-version" 2>/dev/null || true)"
MKOSI_VERSION_PIN="${MKOSI_VERSION_PIN:-26}"
# Python floor mkosi 26 requires. Trixie ships python3 3.13.x (no python3.12
# package exists there); 3.13 satisfies the >= 3.12 floor.
MKOSI_PYTHON_FLOOR="3.12"
# Dockerfile that bakes the canonical builder (mkosi ${MKOSI_VERSION_PIN} + deps).
MKOSI_BUILDER_DOCKERFILE="${V2_DIR}/ci/Dockerfile"
# Builder image. An operator MAY pin their own (registry/local) via
# MKOSI_BUILDER_IMAGE — we then honour it verbatim and never auto-build. Unset →
# use, and auto-build when absent, the canonical baked tag.
if [[ -n "${MKOSI_BUILDER_IMAGE:-}" ]]; then
  MKOSI_BUILDER_IMAGE_OVERRIDDEN=1
else
  MKOSI_BUILDER_IMAGE_OVERRIDDEN=0
fi
MKOSI_BUILDER_IMAGE="${MKOSI_BUILDER_IMAGE:-ceralive-mkosi-builder:${MKOSI_VERSION_PIN}}"

# ---------------------------------------------------------------------------
# STAGE MODULES (lib/stages/) — one module per [N/9] step; this file sequences
# them. EXPLICIT and ORDERED, never a glob (the customize/postinst-lib.sh rule):
# a module lost or never wired up must fail HERE, not halfway through a build as
# `command not found`. The order is PIPELINE order, so a static test that reads
# the orchestrator by TEXT can concatenate entry + modules and still assert
# stage ordering.
# ---------------------------------------------------------------------------
STAGE_DIR="${HERE}/stages"
# shellcheck source=stages/resolve.sh
source "${STAGE_DIR}/resolve.sh"
# shellcheck source=stages/fetch.sh
source "${STAGE_DIR}/fetch.sh"
# shellcheck source=stages/kernel-build.sh
source "${STAGE_DIR}/kernel-build.sh"
# shellcheck source=stages/partition.sh
source "${STAGE_DIR}/partition.sh"

usage() {
  cat >&2 <<EOF
Usage: orchestrate.sh --board <board> --manifest <file> [options]

Builds the CeraLive v2 image for <board> from its manifest.

Options:
  --native           build with HOST mkosi instead of the default container
                     (same as MKOSI_NATIVE=1)
  --variant <name>   apply an OPT-IN family variant overlay (default: 'default',
                     the production vendor path). Never inferred.

Env:
  INSTALL_BOOT_BSP   1 (default) full device build incl. kernel/DTB/U-Boot/firmware
                     0           config+package parity only (boot BSP via task 17)
  MKOSI_NATIVE       1 = native host mkosi; unset/0 (default) = container builder
  MKOSI_BUILDER_IMAGE  pin a custom builder image (default: auto-built from
                       v2/ci/Dockerfile, tag ceralive-mkosi-builder:${MKOSI_VERSION_PIN})
  CHANNEL VARIANT RELEASE ARMBIAN_APT_URL ARMBIAN_SUITE
  APT_CLIENT_CRT_B64 APT_CLIENT_KEY_B64 APT_GPG_PUBLIC_B64   (CI secrets, mTLS+GPG)
  PASETO_PUBLIC_KEY_B64                                      (CI: device-token Ed25519 PUBLIC key)
  CERALIVE_BUILD_LOCK_TIMEOUT seconds to wait for another build of the same board
EOF
}

acquire_board_lock() {
  local board="$1" lock_file
  [[ "${BUILD_LOCK_TIMEOUT}" =~ ^[0-9]+$ ]] \
    || die "CERALIVE_BUILD_LOCK_TIMEOUT must be a non-negative integer"
  mkdir -p "${BUILD_LOCK_DIR}"
  lock_file="${BUILD_LOCK_DIR}/${board}.lock"
  exec {BUILD_LOCK_FD}>"${lock_file}"
  if ! flock -w "${BUILD_LOCK_TIMEOUT}" "${BUILD_LOCK_FD}"; then
    die "build already active for board '${board}' (lock: ${lock_file})"
  fi
  log_info "build lock acquired for board '${board}'"
}

main() {
  local board="" manifest="" variant="${CERALIVE_KERNEL_VARIANT:-default}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --board)     board="${2:-}"; shift 2 ;;
      --manifest)  manifest="${2:-}"; shift 2 ;;
      --native)    MKOSI_NATIVE=1; shift ;;
      --variant)   variant="${2:-}"; shift 2 ;;
      --variant=*) variant="${1#--variant=}"; shift ;;
      -h|--help)   usage; exit 0 ;;
      *) usage; die "unknown argument: $1" ;;
    esac
  done
  [[ -n "${variant}" ]] || die "--variant requires a name (use 'default' for the production vendor path)"

  [[ -n "${board}" ]]    || { usage; die "--board is required"; }
  [[ -n "${manifest}" ]] || { usage; die "--manifest is required"; }
  require_cmd python3
  require_cmd ar
  require_cmd tar
  require_cmd flock
  acquire_board_lock "${board}"

  log_info "=== CeraLive v2 build: board='${board}' ==="
  log_info "manifest=${manifest} install_boot_bsp=${INSTALL_BOOT_BSP} channel=${CHANNEL} variant=${VARIANT} kernel_variant=${variant}"

  # Cross-stage state. Declared in THIS frame so every stage_* module assigns
  # into one place — the stages are called from here, so bash's dynamic scoping
  # hands them these names exactly as the inline bodies had them.
  local kernel_from_source=0 family_manifest="" mkosi_arch=""

  stage_resolve

  # -------------------------------------------------------------------------
  # 2-4. Fetch + stage .debs, then partition them into BSP vs first-party.
  # -------------------------------------------------------------------------
  # Staging key = the board MANIFEST STEM: unique by construction, and the same
  # key acquire_board_lock() serialises on. The app subimage rebuilds this exact
  # path from inside its chroot (--extra-tree does not reach a subimage), so the
  # key is forwarded as CERALIVE_BOARD via env_names AND mkosi.conf
  # PassEnvironment=. NOT ${BOARD_ID} — that Armbian BOARD= value equals the stem
  # only on rock-5b-plus, and the app layer keying off it installed ZERO
  # first-party .debs on orange-pi-5-plus. Unrelated to cache/${BOARD_ID} below.
  local staging="${STAGING_ROOT}/${board}"
  export CERALIVE_BOARD="${board}"
  local bsp_dir="${staging}/bsp" firstparty_dir="${staging}/firstparty"
  local kernel_build_dir="${staging}/kernel-build"
  stage_fetch

  stage_kernel_build

  stage_partition

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
  # (fetch-debs run_or_plan, task 14); emit the mkosi plan and stop before the
  # real mkosi/container run so CI needs no network, privileged container or
  # board. select_build_mode still runs so the plan names the concrete path
  # (containerized default vs --native) and surfaces a missing-runtime error.
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    select_build_mode
    local package_dir_plan="${STAGING_ROOT}/${board}/bsp"
    local firstparty_dir_plan="${STAGING_ROOT}/${board}/firstparty"
    if [[ "${BUILD_MODE}" != "native" ]]; then
      package_dir_plan="/run/ceralive-bsp"
      firstparty_dir_plan="/run/ceralive-firstparty"
    fi
    log_info "[5/9] DRY_RUN=1 (${BUILD_MODE}) — would build with: mkosi --architecture=${mkosi_arch} --with-network=yes --cache-directory=cache/${board} --package-directory ${package_dir_plan} --extra-tree ${firstparty_dir_plan}:/opt/ceralive-staging --force build"
    log_success "=== DRY-RUN complete: board='${board}' (${mkosi_arch}) resolved → ${BUILD_MODE} builder plan emitted; no network/hardware touched ==="
    exit 0
  fi

  # -------------------------------------------------------------------------
  # 6. Assemble: mkosi builds base → platform → runtime → app in the trixie builder.
  # -------------------------------------------------------------------------
  local ts rootfs_tree build_version
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  # Bundle VERSION is embedded in manifest.raucm, so it must be deterministic
  # (the filename ts may stay wall-clock — it is not part of the .raucb bytes).
  build_version="$(git -C "${V2_DIR}" rev-parse --short HEAD 2>/dev/null || true)"
  [[ -n "${build_version}" ]] || build_version="$(date -u -d "@${SOURCE_DATE_EPOCH}" +%Y%m%dT%H%M%SZ 2>/dev/null || printf '%s' "${SOURCE_DATE_EPOCH}")"
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

  # Everything the U-Boot selector loads must actually be in that rootfs, on EVERY
  # kernel path. This is checked here, against the emitted tar, because it is the
  # earliest point where the real answer exists: DRY_RUN CI never runs the layers
  # that populate /boot, and preflash-verify.sh (which does check) only runs on a
  # production-labelled .raw an operator is about to flash — a bench image fails its
  # PARTLABEL assertions first and never reaches the artifact checks. That gap is
  # exactly how an `edge` image with no /boot/Image reached a board.
  if [[ "${ARCH}" == "arm64" && "${INSTALL_BOOT_BSP}" == "1" ]]; then
    log_info "[6b/9] verifying boot artifacts in ${artifact}"
    "${VERIFY_BOOT_ARTIFACTS_SH}" "${artifact}" --dtb-name "${DTB_NAME}" \
      || die "boot artifacts INCOMPLETE for board '${board}' — this image would not boot"
  fi

  # The rootfs_bytes_max in manifests/size-budget.json is documented as a BLOCKING
  # ceiling, and until this stage existed NOTHING enforced it on a real artifact: the
  # only live caller was the v2-ci "size gate" job, which measures a synthetic 4 KB
  # tree. That is how both RK3588 boards shipped 65-72 MB over budget while the docs
  # claimed the gate ran after every build. It runs here, against the same emitted
  # tar as [6b/9] and for the same reason — the earliest point where the real answer
  # exists. Deliberately NOT arch-gated: every shipped board carries a non-null
  # ceiling, and gating on arm64 would exempt the one board whose size has never been
  # measured. INSTALL_BOOT_BSP=0 IS skipped, because a kernel-less parity rootfs is
  # not the shipped image and measuring it would be a vacuous pass.
  if [[ "${INSTALL_BOOT_BSP}" == "1" ]]; then
    log_info "[6c/9] enforcing the rootfs size budget for ${artifact}"
    "${MEASURE_SIZE_SH}" "${board}" "${artifact}" \
      || die "rootfs size budget EXCEEDED for board '${board}' (measured/budget bytes above) — slim the image (v2/docs/size-notes.md), do NOT raise rootfs_bytes_max"
    compare_size_against_baseline "${board}" "${artifact}"
  else
    log_warn "[6c/9] INSTALL_BOOT_BSP=0 — config+package parity build; rootfs size budget not enforced (a kernel-less rootfs is not the shipped image)"
  fi

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
      BUNDLE_VERSION="${build_version}" BUNDLE_OUT_DIR="${out_dir}" BUNDLE_TS="${ts}" \
        "${BUILD_BUNDLE_SH}" "${BOARD_ID}" "${artifact}" \
        || die "Stage-4 RAUC bundle build failed for board '${board}'"
      log_success "signed bundle: ${bundle_artifact} ($(du -h "${bundle_artifact}" | cut -f1)), sha256 in ${bundle_artifact}.sha256"
    else
      log_warn "[8/9] INSTALL_BOOT_BSP=0 — config+package parity build; Stage-4 disk assembly (flashable .raw) deferred to the full device build"
    fi
  elif [[ "${RAUC_BOOTLOADER_ADAPTER:-}" == "efi" || "${RAUC_BOOTLOADER_ADAPTER:-}" == "grub" ]]; then
    # x86 (UEFI/GRUB) Stage-4 disk assembly (Task 12 — x86-disk wiring landed).
    # x86 boots from an EFI System Partition with RAUC's NATIVE bootloader=grub backend
    # (GRUB at the removable path /EFI/BOOT/BOOTX64.EFI + grubenv on the ESP), NOT the
    # RK3588 raw idbloader gap, so it has its OWN offline producer lib/assemble-disk-x86.sh
    # (ESP + the FROZEN rootfs_a/rootfs_b/data slots; repart/ untouched). Same
    # INSTALL_BOOT_BSP gate as the custom path — the x86 .raw needs the Debian kernel
    # inside rootfs_a, so a config+package parity build (BSP=0) defers disk assembly.
    if [[ "${INSTALL_BOOT_BSP}" == "1" ]]; then
      local raw_artifact="${out_dir}/${ts}.raw" single_slot_flag=()
      [[ "${SINGLE_SLOT_FALLBACK:-false}" == "true" ]] && single_slot_flag+=(--single-slot)
      log_info "[8/9] Stage-4 x86 ESP+GRUB disk assembly → ${raw_artifact} (bootloader_adapter=${RAUC_BOOTLOADER_ADAPTER} single_slot=${SINGLE_SLOT_FALLBACK:-false})"
      # BOARD_ID/COMPATIBLE_STRING/SERIAL_CONSOLE/SINGLE_SLOT_FALLBACK are already
      # exported by run_mkosi_build (step 6) and read from the env by the assembler
      # and install-x86-grub.sh esp; the flags below pin the per-run artifact + tree.
      "${ASSEMBLE_DISK_X86_SH}" build \
        --output "${raw_artifact}" \
        "${single_slot_flag[@]}" \
        --board "${BOARD_ID}" \
        --rootfs-tree "${rootfs_tree}" \
        || die "Stage-4 x86 disk assembly failed for board '${board}'"
      log_success "flashable image: ${raw_artifact} ($(du -h "${raw_artifact}" | cut -f1))"

      # Stage-4 FINAL artifact: a signed RAUC OTA bundle (.raucb + .sha256),
      # stamped with the same board-specific COMPATIBLE_STRING and timestamp as
      # the .raw, emitted ALONGSIDE it. build-bundle.sh is board-agnostic (it reads
      # COMPATIBLE_STRING from the env), so the x86 path mirrors the custom path
      # verbatim — same rootfs.tar artifact, same BUNDLE_* env. format=plain.
      local bundle_artifact="${out_dir}/${ts}.raucb"
      log_info "[8/9] Stage-4 RAUC bundle → ${bundle_artifact} (signed, compatible=${COMPATIBLE_STRING:-unset}, pki=${CERALIVE_RAUC_PKI_DIR})"
      BUNDLE_VERSION="${build_version}" BUNDLE_OUT_DIR="${out_dir}" BUNDLE_TS="${ts}" \
        "${BUILD_BUNDLE_SH}" "${BOARD_ID}" "${artifact}" \
        || die "Stage-4 RAUC bundle build failed for board '${board}'"
      log_success "signed bundle: ${bundle_artifact} ($(du -h "${bundle_artifact}" | cut -f1)), sha256 in ${bundle_artifact}.sha256"
    else
      log_warn "[8/9] INSTALL_BOOT_BSP=0 — config+package parity build; Stage-4 x86 disk assembly (flashable .raw) deferred to the full device build"
    fi
  else
    die "[8/9] unsupported bootloader_adapter '${RAUC_BOOTLOADER_ADAPTER:-unset}' for board '${board}' — no Stage-4 disk-assembly path is wired (expected 'custom' for RK3588 or 'efi'/'grub' for x86); refusing to emit a partial image"
  fi

  log_info "[9/9] done"
  log_success "=== build complete: board='${board}' → ${artifact} ==="
}

# ---------------------------------------------------------------------------
# select_build_mode — decide HOW mkosi runs and set the global BUILD_MODE to one
# of: native | docker | podman. Containerized is the CANONICAL default (task 9);
# native is opt-in (--native / MKOSI_NATIVE=1). For the container path the runtime
# is auto-detected (docker first, then podman). Logs the chosen plan incl. the
# pinned mkosi/Python versions, and dies with an ACTIONABLE message (not a stack
# trace) when the container path has no runtime. Called by both the DRY_RUN plan
# and the real run_mkosi_build, so the two never diverge.
# ---------------------------------------------------------------------------
select_build_mode() {
  if [[ "${MKOSI_NATIVE:-}" == "1" ]]; then
    BUILD_MODE="native"
    log_info "mkosi: NATIVE build (opt-in --native/MKOSI_NATIVE=1) — host mkosi (pin: mkosi ${MKOSI_VERSION_PIN}, Python ${MKOSI_PYTHON_FLOOR}+)"
    return 0
  fi

  if command -v docker >/dev/null 2>&1; then
    BUILD_MODE="docker"
  elif command -v podman >/dev/null 2>&1; then
    BUILD_MODE="podman"
  else
    die "containerized build is the default but no container runtime is installed. Install docker or podman, or re-run with --native (MKOSI_NATIVE=1) to build with host mkosi ${MKOSI_VERSION_PIN} (needs Python ${MKOSI_PYTHON_FLOOR}+)."
  fi
  log_info "mkosi: containerized build (DEFAULT) — runtime=${BUILD_MODE}, builder ${MKOSI_BUILDER_IMAGE} (pinned: mkosi ${MKOSI_VERSION_PIN}, Python ${MKOSI_PYTHON_FLOOR}+)"
  return 0
}

# ---------------------------------------------------------------------------
# ensure_builder_image <runtime> — guarantee the canonical builder image exists.
# An operator-pinned MKOSI_BUILDER_IMAGE is used verbatim (registry/local) and
# never auto-built; the default baked tag is built from v2/ci/Dockerfile when not
# already present locally.
# ---------------------------------------------------------------------------
ensure_builder_image() {
  local runtime="$1"
  [[ "${MKOSI_BUILDER_IMAGE_OVERRIDDEN}" == "1" ]] && return 0
  if "${runtime}" image inspect "${MKOSI_BUILDER_IMAGE}" >/dev/null 2>&1; then
    return 0
  fi
  [[ -f "${MKOSI_BUILDER_DOCKERFILE}" ]] \
    || die "canonical builder Dockerfile missing: ${MKOSI_BUILDER_DOCKERFILE}"
  log_info "builder image ${MKOSI_BUILDER_IMAGE} absent — building from ${MKOSI_BUILDER_DOCKERFILE} (mkosi ${MKOSI_VERSION_PIN} + Python ${MKOSI_PYTHON_FLOOR}+)"
  "${runtime}" build -t "${MKOSI_BUILDER_IMAGE}" -f "${MKOSI_BUILDER_DOCKERFILE}" "$(dirname "${MKOSI_BUILDER_DOCKERFILE}")" \
    || die "failed to build the canonical mkosi builder image from ${MKOSI_BUILDER_DOCKERFILE}"
}

# ---------------------------------------------------------------------------
# run_mkosi_build <mkosi_arch> <bsp_dir> <firstparty_dir>
#
# Runs `mkosi build` for the full layer chain. CANONICAL path is the pinned trixie
# builder container (mkosi ${MKOSI_VERSION_PIN}); --native/MKOSI_NATIVE=1 opts into
# host mkosi instead. The mode is chosen by select_build_mode(). qemu-user F-flag
# (kernel-global) handles arm64. All board/secret values flow via the environment
# → mkosi Environment= → scripts.
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
    KERNEL_VARIANT KERNEL_SOURCE_DTB_DEB_DIR KERNEL_SOURCE_DTB_BOOT_DIR
    KERNEL_SOURCE_KERNEL_RELEASE
    HW_ACCEL_GSTREAMER_PLUGINS GSTREAMER_RUNTIME_PACKAGES
    SHARED_PACKAGES SINGLE_SLOT_FALLBACK
    APT_CLIENT_CRT_B64 APT_CLIENT_KEY_B64 APT_GPG_PUBLIC_B64
    RAUC_ROOT_CA_B64 ADDON_KEYRING_B64 PASETO_PUBLIC_KEY_B64 COMPATIBLE_STRING
    CERALIVE_INTERFACES_eth0 CERALIVE_INTERFACES_eth1 CERALIVE_INTERFACES_wlan0
    CERALIVE_MODEM_PORTS_STATUS CERALIVE_MODEM_PORTS_SLOTS
    CERALIVE_DEBUG_IMAGE CERALIVE_DEBUG_PASSWORD_HASH CERALIVE_IMAGE_BUILD_COMMIT
    CERALIVE_BENCH_LABELS CERALIVE_BOARD
    SOURCE_DATE_EPOCH
  )
  # Export each (default empty for the secrets) so both `--environment NAME`
  # inheritance and docker `-e NAME` passthrough resolve. DTB_NAME feeds the
  # platform bootloader integration (mkosi.finalize → install-boot.sh): the U-Boot
  # boot.scr / recovery.scr fdtfile and the board env come from the manifest, never
  # hardcoded.
  export ARCH RELEASE CHANNEL VARIANT BOARD_ID FAMILY SERIAL_CONSOLE DTB_NAME
  export INSTALL_BOOT_BSP ARMBIAN_APT_URL ARMBIAN_SUITE
  export KERNEL_PACKAGES DTB_PACKAGES UBOOT_PACKAGES FIRMWARE_PACKAGES
  # Kernel-from-source DTB install mapping. EMPTY on the production vendor path,
  # which is what makes the platform layer's copy step a strict no-op there:
  # a source-built kernel ships its DTBs inside the linux-image deb, an Armbian
  # linux-dtb-* package already puts them where the boot script looks.
  export KERNEL_VARIANT="${KERNEL_VARIANT:-}"
  export KERNEL_SOURCE_DTB_DEB_DIR="${KERNEL_SOURCE_DTB_DEB_DIR:-}"
  export KERNEL_SOURCE_DTB_BOOT_DIR="${KERNEL_SOURCE_DTB_BOOT_DIR:-}"
  # Also the platform layer's /boot artifact gate: an Armbian linux-image-*
  # postinst creates /boot/Image and pulls initramfs-tools in; `make bindeb-pkg`
  # does neither, so the release is what tells the platform layer to do it itself.
  export KERNEL_SOURCE_KERNEL_RELEASE="${KERNEL_SOURCE_KERNEL_RELEASE:-}"
  export HW_ACCEL_GSTREAMER_PLUGINS="${HW_ACCEL_GSTREAMER_PLUGINS:-}"
  export GSTREAMER_RUNTIME_PACKAGES="${GSTREAMER_RUNTIME_PACKAGES:-}"
  export SHARED_PACKAGES="${SHARED_PACKAGES:-}"
  export CERALIVE_IMAGE_BUILD_COMMIT
  # Stage 4 disk-assembly flag (manifest single_slot_fallback) consumed by
  # lib/assemble-disk.sh; default false (A/B). See v2/mkosi/repart/README.md.
  export SINGLE_SLOT_FALLBACK="${SINGLE_SLOT_FALLBACK:-false}"
  # Opt-in bench PARTLABEL overlay (main() normalizes it). The runtime chroot
  # writes the /data fstab entry and the fallback RAUC slot devices, so it has to
  # reach the SUBIMAGES too — hence the matching mkosi.conf PassEnvironment= entry.
  export CERALIVE_BENCH_LABELS="${CERALIVE_BENCH_LABELS:-0}"
  export APT_CLIENT_CRT_B64="${APT_CLIENT_CRT_B64:-}"
  export APT_CLIENT_KEY_B64="${APT_CLIENT_KEY_B64:-}"
  export APT_GPG_PUBLIC_B64="${APT_GPG_PUBLIC_B64:-}"

  # RAUC device keyring (task 26): the IMMUTABLE root CA baked in at first flash,
  # committed (PUBLIC) at mkosi/runtime/rauc/ceralive-keyring.pem. Forwarded base64
  # (like the apt GPG key) so the self-contained runtime postinst can write it
  # without repo access.
  RAUC_ROOT_CA_B64="$(base64 -w0 <"${RAUC_KEYRING_FILE}")"
  export RAUC_ROOT_CA_B64

  # Add-on signing keyring (task 24): the PUBLIC add-on keyring baked at
  # /usr/share/ceralive/addon-keyring.gpg so the device can verify optional add-on
  # sysext payloads (.raw + detached .sig). SEPARATE trust domain from the RAUC
  # root CA above — committed (PUBLIC) dev copy at mkosi/runtime/addon-keyring/
  # addon-keyring.gpg. Forwarded base64 (like RAUC_ROOT_CA_B64) so the runtime
  # postinst can write it without repo access. CI injects the real public key.
  local addon_keyring="${MKOSI_DIR}/runtime/addon-keyring/addon-keyring.gpg"
  if [[ -z "${ADDON_KEYRING_B64:-}" && -s "${addon_keyring}" ]]; then
    ADDON_KEYRING_B64="$(base64 -w0 <"${addon_keyring}")"
  fi
  export ADDON_KEYRING_B64="${ADDON_KEYRING_B64:-}"

  # PASETO device-token verification key (ADR-0006 D2): the PUBLIC Ed25519 key the
  # CeraUI backend uses to verify device-control / relay-config tokens. Baked into
  # the ceralive.service runtime env as PASETO_PUBLIC_KEY (its PRESENCE gates real
  # verification; absent → CeraUI runs the MVP opaque-token path). Forwarded base64
  # (like the apt GPG key / add-on keyring) so the self-contained runtime postinst
  # can write it without repo access. The decoded payload is the raw-32-byte Ed25519
  # PUBLIC key in standard base64 (cert-work/paseto/gen-keys.sh → paseto.public.raw.b64).
  # PUBLIC ONLY — there is no committed default and NEVER any k4.secret; CI injects it.
  export PASETO_PUBLIC_KEY_B64="${PASETO_PUBLIC_KEY_B64:-}"

  # RAUC `compatible` — the single source of truth (T12), BOARD-specific not
  # family-wide. A family default (ceralive-rk3588) lets an Orange Pi 5+ bundle
  # install on a Rock 5B+; deriving from board_id and having install-boot.sh +
  # build-bundle.sh read THIS env (no own default) keeps device + bundle in lockstep.
  export COMPATIBLE_STRING="${COMPATIBLE_STRING:-ceralive-${BOARD_ID}}"

  # Deterministic interface naming (postinst-lib.sh::install_interface_naming).
  # The manifest interfaces: block flattens to INTERFACES_ETH0/ETH1/WLAN0; forward
  # each as CERALIVE_INTERFACES_<role> so the runtime postinst emits per-role
  # systemd .link Path= rules. Empty/FIXME values are skipped on-device.
  export CERALIVE_INTERFACES_eth0="${INTERFACES_ETH0:-}"
  export CERALIVE_INTERFACES_eth1="${INTERFACES_ETH1:-}"
  export CERALIVE_INTERFACES_wlan0="${INTERFACES_WLAN0:-}"

  # Fail-closed modem slot-UID naming (udev.sh::generate_modem_slot_uid_rules).
  # The manifest modem_ports: block flattens to MODEM_PORTS_STATUS + one
  # MODEM_PORTS_SLOTS_<NAME> per slot; forward the status and collapse the slot
  # leaves into a single space-separated `name=ID_PATH` list the generator parses.
  # status=unverified (the shipped default) carries no slots -> the generator
  # emits NO slot-uid rules on-device.
  export CERALIVE_MODEM_PORTS_STATUS="${MODEM_PORTS_STATUS:-unverified}"
  local _modem_slots="" _slot_var _slot_name
  for _slot_var in $(compgen -v MODEM_PORTS_SLOTS_ 2>/dev/null || true); do
    _slot_name="${_slot_var#MODEM_PORTS_SLOTS_}"
    [[ -n "${!_slot_var:-}" ]] || continue
    _modem_slots+="${_slot_name,,}=${!_slot_var} "
  done
  export CERALIVE_MODEM_PORTS_SLOTS="${_modem_slots% }"
  # Already normalized + validated by main()'s resolve_debug_image_flag, which has
  # to run before the runtime package set is resolved. Re-run here so the contract
  # holds no matter which call site changes first — it is idempotent.
  resolve_debug_image_flag

  local env_cli=() n
  for n in "${env_names[@]}"; do env_cli+=(--environment "${n}"); done

  # Per-board cache isolation (T11): scope the incremental apt cache to this
  # board so concurrent multi-board builds never share one cache dir (the race
  # T12 parallelises on). This CLI flag is the authoritative plumb; it overrides
  # the env-expanded default in mkosi/mkosi.conf and they resolve to the same
  # path. Relative to the mkosi config dir (MKOSI_DIR / /work/mkosi in-container).
  local cache_dir="cache/${BOARD_ID}"

  local mkosi_args=(
    --architecture="${mkosi_arch}"
    --with-network=yes
    "${env_cli[@]}"
    --cache-directory="${cache_dir}"
    --package-directory "${bsp_dir}"
    --extra-tree "${firstparty_dir}:/opt/ceralive-staging"
    --force
    build
  )

  select_build_mode   # sets BUILD_MODE (native|docker|podman); logs the plan

  if [[ "${BUILD_MODE}" == "native" ]]; then
    command -v mkosi >/dev/null 2>&1 \
      || die "native build (--native/MKOSI_NATIVE=1) requested but 'mkosi' is not on PATH — install mkosi ${MKOSI_VERSION_PIN} (needs Python ${MKOSI_PYTHON_FLOOR}+), or drop --native to use the container builder"
    [[ -f /usr/share/keyrings/debian-archive-keyring.gpg ]] \
      || log_warn "native build: /usr/share/keyrings/debian-archive-keyring.gpg absent — mkosi may fail to verify the Debian repos (install debian-archive-keyring)"
    if [[ -n "${APT_GPG_PUBLIC_B64}" ]]; then
      APT_GPG_PUBLIC_B64="$("${DEARMOR_APT_KEYRING_SH}")" \
        || die "could not prepare the binary CeraLive apt keyring for mkosi"
      export APT_GPG_PUBLIC_B64
    fi
    ( cd "${MKOSI_DIR}" && mkosi "${mkosi_args[@]}" ) \
      || die "mkosi build failed (native)"
    return
  fi

  # Containerized (default). BUILD_MODE is the detected runtime; docker `-e NAME`
  # forwards each value and the in-container mkosi re-declares them via --environment.
  local runtime="${BUILD_MODE}"
  ensure_builder_image "${runtime}"

  log_info "mkosi: ${runtime} builder ${MKOSI_BUILDER_IMAGE} (containerized, mkosi ${MKOSI_VERSION_PIN} pinned)"
  # Stage lib/common.sh into MKOSI_DIR/lib/ so finalize scripts can source it at
  # /work/lib/common.sh in mkosi's mount namespace (/work = mkosi workspace root).
  mkdir -p "${MKOSI_DIR}/lib"
  cp "${HERE}/common.sh" "${MKOSI_DIR}/lib/common.sh"
  local env_flags=() env_cli_str=""
  for n in "${env_names[@]}"; do
    env_flags+=(-e "${n}")
    env_cli_str+=" --environment ${n}"
  done

  "${runtime}" run --rm --privileged \
    "${env_flags[@]}" \
    -e "CERALIVE_V2_DIR=/work" \
    -v "${V2_DIR}:/work" \
    -v "${bsp_dir}:/run/ceralive-bsp:ro" \
    -v "${firstparty_dir}:/run/ceralive-firstparty:ro" \
    "${MKOSI_BUILDER_IMAGE}" \
    bash -euo pipefail -c '
      command -v mkosi >/dev/null 2>&1 || {
        echo "FATAL: builder image lacks mkosi — an overridden MKOSI_BUILDER_IMAGE must bake mkosi '"${MKOSI_VERSION_PIN}"' (see v2/ci/Dockerfile)" >&2
        exit 1
      }
      if [[ -n "${APT_GPG_PUBLIC_B64:-}" ]]; then
        APT_GPG_PUBLIC_B64="$(/work/lib/dearmor-apt-keyring.sh)" || {
          echo "FATAL: could not prepare the binary CeraLive apt keyring for mkosi" >&2
          exit 1
        }
        export APT_GPG_PUBLIC_B64
      fi
      cd /work/mkosi
      mkosi \
        --architecture='"${mkosi_arch}"' \
        --with-network=yes \
        '"${env_cli_str}"' \
        --environment CERALIVE_V2_DIR \
        --cache-directory='"${cache_dir}"' \
        --package-directory /run/ceralive-bsp \
        --extra-tree /run/ceralive-firstparty:/opt/ceralive-staging \
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
  # Deterministic ordering + owner + clamped mtime so the same tree always tars
  # to the same bytes (task 14). --sort=name pins entry order; gnu format avoids
  # the per-file pax atime/ctime headers that would re-introduce wall-clock drift.
  local -a tar_repro=(
    --sort=name --numeric-owner --owner=0 --group=0
    --mtime="@${SOURCE_DATE_EPOCH:-0}" --format=gnu
  )
  if tar -C "${tree}" "${tar_repro[@]}" -cf "${artifact}" . 2>/dev/null; then
    :
  else
    log_info "rootfs is root-owned — tarring inside the builder container"
    local runtime="docker"; command -v docker >/dev/null 2>&1 || runtime="podman"
    "${runtime}" run --rm \
      -e "SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-0}" \
      -v "${MKOSI_DIR}:/work" -v "$(dirname "${artifact}")":/out \
      "${MKOSI_BUILDER_IMAGE}" \
      tar -C "/work/build/app" "${tar_repro[@]}" -cf "/out/$(basename "${artifact}")" .
  fi
  ( cd "$(dirname "${artifact}")" && sha256sum "$(basename "${artifact}")" >"$(basename "${artifact}").sha256" )
}

# ---------------------------------------------------------------------------
# compare_size_against_baseline <board> <artifact.tar>
#
# The RELATIVE size gate, run against the REAL emitted tar. It was previously
# reachable only from the v2-ci "size gate" job, which measures a synthetic 4 KB
# tree — so it compared 4096 bytes against a ~1.4 GB baseline and could only ever
# report an enormous shrink. That is the same vacuity that let both RK3588 boards
# ship over the ABSOLUTE ceiling before [6c/9] existed; fixing one gate and
# leaving the other measuring 4 KB just moves the blind spot.
#
# Exit policy is deliberately split, and NOT the same as the absolute gate's:
#   exit 2 (missing/malformed baseline, or a baseline for a DIFFERENT board) is
#          FATAL — that is a repository misconfiguration, and a silent cross-board
#          comparison produces a confident, meaningless delta.
#   exit 1 (growth beyond the comparator's threshold) is a loud WARNING, matching
#          what v2-ci already does: the blocking size rule is the absolute ceiling
#          in size-budget.json, and an intentional feature addition must not be
#          able to fail a build that is still comfortably under it.
# The baseline is resolved ONLY as size-baseline.<board>.json, with no
# un-suffixed fallback: the legacy v2/ci/size-baseline.json is rock-5b-plus's
# file, so a fallback would hand it to every board that lacks one. A board with
# no committed baseline yet warns and passes, the same newly-added-board
# allowance measure-size.sh makes for a null ceiling.
# ---------------------------------------------------------------------------
compare_size_against_baseline() {
  local board="$1" artifact="$2" baseline measured rc=0

  # A debug image is production + the development delta (~58 MB on rock-5b-plus),
  # so it exceeds the comparator's 50 MB growth threshold BY CONSTRUCTION. Warning
  # about that is worse than useless: the warning's own remedy is "update the
  # baseline in the same PR", and doing that from a debug build would overwrite the
  # PRODUCTION baseline with a number no production image can ever reproduce, then
  # desync it from size-budget.json (which manifest.bats fails on). The ABSOLUTE
  # ceiling above still ran and still applies — only this relative comparison,
  # whose reference is a production artifact, is skipped.
  if [[ "${CERALIVE_DEBUG_IMAGE:-0}" == "1" ]]; then
    log_warn "[6c/9] CERALIVE_DEBUG_IMAGE=1 — relative size baseline SKIPPED (the committed baseline is a PRODUCTION artifact; do NOT update it from a debug build). The absolute ceiling was enforced above."
    return 0
  fi

  baseline="${SIZE_BASELINE_DIR}/size-baseline.${board}.json"
  if [[ ! -f "${baseline}" ]]; then
    log_warn "[6c/9] no committed size baseline for board '${board}' — relative regression check skipped (record one in ${SIZE_BASELINE_DIR})"
    return 0
  fi

  measured="$(du --apparent-size -sb "${artifact}" | awk '{print $1}')"

  "${CHECK_SIZE_REGRESSION_SH}" "${measured}" "${baseline}" "${board}" || rc=$?
  case "${rc}" in
    0) log_success "[6c/9] size baseline: board=${board} within threshold of $(basename "${baseline}")" ;;
    1) log_warn "[6c/9] size baseline: board=${board} GREW beyond the regression threshold vs $(basename "${baseline}") — justify the growth and update the baseline in the same PR (v2/docs/size-notes.md §4)" ;;
    *) die "[6c/9] size baseline unusable for board '${board}': ${baseline} (missing, malformed, or recorded for a different board)" ;;
  esac
}

main "$@"
