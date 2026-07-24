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
PARITY_CHECK_SH="${HERE}/parity-check.sh"
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

usage() {
  cat >&2 <<EOF
Usage: orchestrate.sh --board <board> --manifest <file> [options]

Builds the CeraLive v2 image for <board> from its manifest.

Options:
  --native           build with HOST mkosi instead of the default container
                     (same as MKOSI_NATIVE=1)

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
      --native)   MKOSI_NATIVE=1; shift ;;
      -h|--help)  usage; exit 0 ;;
      *) usage; die "unknown argument: $1" ;;
    esac
  done

  [[ -n "${board}" ]]    || { usage; die "--board is required"; }
  [[ -n "${manifest}" ]] || { usage; die "--manifest is required"; }
  require_cmd python3
  require_cmd ar
  require_cmd tar
  require_cmd flock
  acquire_board_lock "${board}"

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
  # Export the resolved architecture and BSP package vars immediately so
  # fetch-debs.sh (step 2) can read them. run_mkosi_build() re-exports the full
  # set at step 6; this early export covers the fetch step which runs before mkosi.
  export ARCH UBOOT_PACKAGES KERNEL_PACKAGES DTB_PACKAGES FIRMWARE_PACKAGES \
         HW_ACCEL_GSTREAMER_PLUGINS GSTREAMER_RUNTIME_PACKAGES

  # Reproducible builds (task 14): pin ONE epoch for the whole run so every
  # embedded mtime (mkosi rootfs, rootfs.tar, squashfs, ext4, CMS) clamps to it.
  # Exported here so fetch/mkosi/assemble-disk/build-bundle all inherit the value.
  SOURCE_DATE_EPOCH="$(resolve_source_date_epoch "${V2_DIR}")"
  CERALIVE_IMAGE_BUILD_COMMIT="${CERALIVE_IMAGE_BUILD_COMMIT:-$(git -C "${V2_DIR}/.." rev-parse HEAD)}"
  [[ "${CERALIVE_IMAGE_BUILD_COMMIT}" =~ ^[0-9a-f]{40}$ ]] \
    || die "CERALIVE_IMAGE_BUILD_COMMIT must be an exact 40-character commit SHA"
  export SOURCE_DATE_EPOCH CERALIVE_IMAGE_BUILD_COMMIT
  log_info "reproducible build: SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH} ($(date -u -d "@${SOURCE_DATE_EPOCH}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo n/a))"

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
  local bsp_dir="${staging}/bsp" firstparty_dir="${staging}/firstparty"
  [[ "${CERALIVE_REUSE_STAGING:-0}" != "1" ]] \
    || die "CERALIVE_REUSE_STAGING is forbidden: build inputs must be freshly authenticated"
  {
    rm -rf "${staging}"
    mkdir -p "${staging}"
    install -d -m 0755 "${bsp_dir}" "${firstparty_dir}"

    log_info "[2/9] fetching .debs (BSP from Armbian + first-party from R2/gh) → ${staging}"
    DEST="${staging}" "${FETCH_DEBS_SH}" --family "${family_manifest}" --dest "${staging}" \
      || die "fetch-debs failed for board '${board}'"

    log_info "[3/9] partitioning staged .debs into BSP vs first-party by package name"
    # The set of BSP package names (manifest-declared) is the partition key.
    local bsp_names=" ${KERNEL_PACKAGES} ${DTB_PACKAGES} ${UBOOT_PACKAGES} ${FIRMWARE_PACKAGES} ${HW_ACCEL_GSTREAMER_PLUGINS:-} ${GSTREAMER_RUNTIME_PACKAGES:-} "
    # MUST stay a superset of fetch-debs.sh FIRST_PARTY_APT_PKGS: the 5 core packages
    # + the 9-package ModemManager 1.24 closure (modem-stack v0.2.0, ~ceralive0.2.0).
    # The fetcher stages all 14 into debs/; a name missing here fails the build as
    # "unclassified staged package" on a real (non-DRY_RUN) build. Guarded by
    # v2/tests/firstparty-classification.test.sh.
    local firstparty_names=" libsrt1.5-ceralive cerastream gstreamer1.0-libuvch264src ceralive-device srtla-send-rs modemmanager libmm-glib0 libmbim-glib4 libmbim-proxy libmbim-utils libqmi-glib5 libqmi-proxy libqmi-utils libqrtr-glib0 "
    local deb pkg
    shopt -s nullglob
    for deb in "${staging}/debs"/*.deb; do
      pkg="$(deb_pkg_name "${deb}")"
      if [[ -n "${pkg}" && "${bsp_names}" == *" ${pkg} "* ]]; then
        "${MKOSI_PACKAGE_STAGING_SH}" "${deb}" "${bsp_dir}"
      elif [[ -n "${pkg}" && "${firstparty_names}" == *" ${pkg} "* ]]; then
        "${MKOSI_PACKAGE_STAGING_SH}" "${deb}" "${firstparty_dir}"
      else
        die "unclassified staged package: ${pkg:-<unreadable>} ($(basename "${deb}"))"
      fi
    done
    shopt -u nullglob
  }
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
    HW_ACCEL_GSTREAMER_PLUGINS GSTREAMER_RUNTIME_PACKAGES
    SHARED_PACKAGES SINGLE_SLOT_FALLBACK
    APT_CLIENT_CRT_B64 APT_CLIENT_KEY_B64 APT_GPG_PUBLIC_B64
    RAUC_ROOT_CA_B64 ADDON_KEYRING_B64 PASETO_PUBLIC_KEY_B64 COMPATIBLE_STRING
    CERALIVE_INTERFACES_eth0 CERALIVE_INTERFACES_eth1 CERALIVE_INTERFACES_wlan0
    CERALIVE_MODEM_PORTS_STATUS CERALIVE_MODEM_PORTS_SLOTS
    CERALIVE_DEBUG_IMAGE CERALIVE_DEBUG_PASSWORD_HASH CERALIVE_IMAGE_BUILD_COMMIT
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
  export HW_ACCEL_GSTREAMER_PLUGINS="${HW_ACCEL_GSTREAMER_PLUGINS:-}"
  export GSTREAMER_RUNTIME_PACKAGES="${GSTREAMER_RUNTIME_PACKAGES:-}"
  export SHARED_PACKAGES="${SHARED_PACKAGES:-}"
  export CERALIVE_IMAGE_BUILD_COMMIT
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

main "$@"
