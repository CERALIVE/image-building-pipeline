#!/usr/bin/env bash
#
# orchestrate.sh — end-to-end builder for the CeraLive v2 image pipeline.
#
# `build <board>` (build) execs this with --board/--manifest. This file is the
# SEQUENCER: locations, configuration, the CLI, the per-board lock, the mkosi
# environment contract, and main(). Each [N/9] stage BODY lives in its own module
# under lib/stages/ and is documented there:
#
#   [1/9]  resolve       manifest → flat build params        stages/resolve.sh
#   [2/9]  fetch         stage BSP + first-party .debs       stages/fetch.sh
#   [2b/9] kernel-build  kernel from pinned source (variant) stages/kernel-build.sh
#   [3/9]  partition     classify staged .debs               stages/partition.sh
#   [4/9]  bsp-gate      every boot-BSP package obtainable   stages/bsp-gate.sh
#   [5/9]  mkosi         base → platform → runtime → app     stages/mkosi.sh
#   [6/9]  tar-emit      normalized <timestamp>.rootfs.tar   stages/tar-emit.sh
#   [6b/9] boot-verify   /boot is complete and loadable      stages/boot-verify.sh
#   [6c/9] size-gate     rootfs is within its size budget    stages/size-gate.sh
#   [7/9]  parity        parity vs the v2 package manifests  stages/parity.sh
#   [8/9]  assemble      Stage-4 .raw + signed .raucb        stages/assemble.sh
#
# DESIGN (inherited from common.sh + learnings):
#   * strict mode + loud ERR trap; NO `|| true` swallowing. Any mkosi/apt/dpkg
#     failure aborts the whole build (MUST-NOT: don't swallow build errors).
#   * ZERO hardcoded board names / package lists / device paths. Everything
#     board-specific flows manifest → resolve.sh → environment → mkosi configs.
#   * [6/9]'s rootfs.tar is the parity artifact and is ALWAYS produced; [8/9] lays
#     it onto the frozen A/B GPT geometry only for the RK3588 custom-uboot adapter,
#     single-slot or A/B per the manifest's single_slot_fallback flag.
#
# shellcheck shell=bash

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${HERE}/common.sh"
# shellcheck source=lib/paths.sh
source "${HERE}/paths.sh"

# ---------------------------------------------------------------------------
# Locations.
# ---------------------------------------------------------------------------
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"
RESOLVE_SH="${HERE}/resolve.sh"
FETCH_DEBS_SH="${HERE}/fetch-debs.sh"
DEARMOR_APT_KEYRING_SH="${HERE}/dearmor-apt-keyring.sh"
MKOSI_PACKAGE_STAGING_SH="${HERE}/stage-mkosi-package.sh"
BUILD_KERNEL_SH="${HERE}/build-kernel.sh"
PARITY_CHECK_SH="${HERE}/parity-check.sh"
VERIFY_BOOT_ARTIFACTS_SH="${HERE}/verify-boot-artifacts.sh"
MEASURE_SIZE_SH="${HERE}/measure-size.sh"
CHECK_SIZE_REGRESSION_SH="${PIPELINE_DIR}/ci/check-size-regression.sh"
SIZE_BASELINE_DIR="${PIPELINE_DIR}/ci"
ASSEMBLE_DISK_SH="${HERE}/assemble-disk.sh"
ASSEMBLE_DISK_X86_SH="${HERE}/assemble-disk-x86.sh"
BUILD_BUNDLE_SH="${HERE}/build-bundle.sh"
RAUC_PKI_CONTRACT_SH="${HERE}/rauc-pki-contract.sh"
MKOSI_DIR="${PIPELINE_DIR}/${CERALIVE_REL_MKOSI_DIR}"
IMAGES_DIR="${PIPELINE_DIR}/${CERALIVE_REL_IMAGES_DIR}"
# Staged .debs live under the mkosi dir (so the builder container, which mounts
# MKOSI_DIR, can see them) but OUTSIDE build/ — `mkosi --force` wipes build/ image
# outputs, and we must not lose the staging mid-build. Gitignored via mkosi/.gitignore.
STAGING_ROOT="${PIPELINE_DIR}/${CERALIVE_REL_STAGING_DIR}"
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
# Debian trixie container baked from ci/Dockerfile; native host mkosi is
# opt-in only (--native / MKOSI_NATIVE=1). Rationale: mkosi 26 (the
# .mkosi-version pin) needs Python >= 3.12, which bookworm (the target rootfs
# release) can't provide and a non-Debian host lacks apt/keyring for — one pinned
# trixie builder gives a reproducible toolchain on any host.
MKOSI_NATIVE="${MKOSI_NATIVE:-}"
# mkosi pin — single source of truth is .mkosi-version (= 26).
MKOSI_VERSION_PIN="$(tr -d '[:space:]' <"${PIPELINE_DIR}/.mkosi-version" 2>/dev/null || true)"
MKOSI_VERSION_PIN="${MKOSI_VERSION_PIN:-26}"
# Python floor mkosi 26 requires. Trixie ships python3 3.13.x (no python3.12
# package exists there); 3.13 satisfies the >= 3.12 floor.
MKOSI_PYTHON_FLOOR="3.12"
# Dockerfile that bakes the canonical builder (mkosi ${MKOSI_VERSION_PIN} + deps).
MKOSI_BUILDER_DOCKERFILE="${PIPELINE_DIR}/ci/Dockerfile"
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
# shellcheck source=stages/bsp-gate.sh
source "${STAGE_DIR}/bsp-gate.sh"
# shellcheck source=stages/mkosi.sh
source "${STAGE_DIR}/mkosi.sh"
# shellcheck source=stages/tar-emit.sh
source "${STAGE_DIR}/tar-emit.sh"
# shellcheck source=stages/boot-verify.sh
source "${STAGE_DIR}/boot-verify.sh"
# shellcheck source=stages/size-gate.sh
source "${STAGE_DIR}/size-gate.sh"
# shellcheck source=stages/parity.sh
source "${STAGE_DIR}/parity.sh"
# shellcheck source=stages/assemble.sh
source "${STAGE_DIR}/assemble.sh"

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
                       ci/Dockerfile, tag ceralive-mkosi-builder:${MKOSI_VERSION_PIN})
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
  local ts="" rootfs_tree="" build_version=""
  local out_dir="" artifact=""

  stage_resolve

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
  stage_bsp_gate
  stage_dry_run_plan
  stage_mkosi
  stage_tar_emit
  stage_boot_verify
  stage_size_gate
  stage_parity
  stage_assemble

  log_info "[9/9] done"
  log_success "=== build complete: board='${board}' → ${artifact} ==="
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
  # lib/assemble-disk.sh; default false (A/B). See mkosi/repart/README.md.
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

  # Native vs containerized invocation lives in stages/mkosi.sh; it reads
  # mkosi_args / env_names / cache_dir out of THIS frame.
  mkosi_invoke
}

main "$@"
