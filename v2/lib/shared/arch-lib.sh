#!/usr/bin/env bash
#
# arch-lib.sh — shared architecture-guard helpers for the CeraLive v2 pipeline.
#
# The CeraLive first-party components (ceracoder, srtla, the CeraUI backend) are
# PURE BINARIES. An RK3588 board is arm64; a developer laptop is usually amd64.
# Pushing an amd64 binary to an arm64 device produces an artifact that installs
# but can NEVER run ("Exec format error"). These helpers REFUSE that push up front.
#
#   * arch_normalize  — fold a uname/file arch token to amd64 | arm64
#   * host_arch       — normalized arch of THIS build host (`uname -m`)
#   * artifact_arch   — normalized arch read from a binary via `file`
#   * device_arch     — normalized arch of the target (override / ssh uname -m)
#   * arch_guard      — REFUSE (non-zero) on an artifact↔device arch mismatch
#
# Bodies extracted VERBATIM from dev-sync/arch.sh. No behaviour change — this
# file is a relocation of existing logic into one shared home.
#
# device_arch / arch_guard read the dev-sync transport+config symbols
# (RESOLVED_TARGET, SSH_USER, DRY_RUN, resolve_target, transport_ssh); a
# consumer (sync-backend.sh, sync-native.sh) sources config.sh + transport.sh
# before calling them. DEV_SYNC_DEVICE_ARCH set → no ssh probe (offline/fleet).
#
# shellcheck shell=bash
# shellcheck disable=SC2154  # RESOLVED_TARGET/SSH_USER/DRY_RUN supplied by the sourcing consumer (config.sh/transport.sh)

ARCH_LIB_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# common.sh provides strict mode, the loud ERR trap, loggers, die, require_cmd.
# shellcheck source=../common.sh
source "${ARCH_LIB_HERE}/../common.sh"

# Optional override: skip the ssh probe and assert the device arch directly
# (offline QA, or a known homogeneous fleet). Normalized like everything else.
DEV_SYNC_DEVICE_ARCH="${DEV_SYNC_DEVICE_ARCH:-}"

# ---------------------------------------------------------------------------
# arch_normalize <raw> — fold a uname/file arch token to amd64 | arm64.
# Dies on anything unrecognised (no silent guessing).
# ---------------------------------------------------------------------------
arch_normalize() {
  local raw="$1"
  case "${raw}" in
    x86_64|amd64|x86-64|x86_64-*)  printf 'amd64' ;;
    aarch64|arm64|aarch64-*)       printf 'arm64' ;;
    *) die "arch_normalize: unsupported arch '${raw}' (expected x86_64/amd64 or aarch64/arm64)" ;;
  esac
}

# ---------------------------------------------------------------------------
# host_arch — normalized arch of THIS build host (`uname -m`).
# ---------------------------------------------------------------------------
host_arch() {
  arch_normalize "$(uname -m)"
}

# ---------------------------------------------------------------------------
# artifact_arch <path> — normalized arch read from the binary via `file`.
# Recognises the two ELF machine strings file emits: "x86-64" and "aarch64".
# ---------------------------------------------------------------------------
artifact_arch() {
  local path="$1"
  [[ -e "${path}" ]] || die "artifact_arch: artifact not found: ${path}"
  require_cmd file
  local desc
  desc="$(file -bL "${path}")"
  case "${desc}" in
    *x86-64*|*x86_64*) printf 'amd64' ;;
    *aarch64*)         printf 'arm64' ;;
    *) die "artifact_arch: could not determine arch of '${path}' from: ${desc}" ;;
  esac
}

# ---------------------------------------------------------------------------
# device_arch — normalized arch of the target device. Uses DEV_SYNC_DEVICE_ARCH
# if set; otherwise resolves the target and reads `uname -m` over ssh. DRY_RUN
# logs the planned ssh probe and (since it cannot read the real device) returns
# the override or, failing that, the host arch as the assumed value.
# ---------------------------------------------------------------------------
device_arch() {
  if [[ -n "${DEV_SYNC_DEVICE_ARCH}" ]]; then
    arch_normalize "${DEV_SYNC_DEVICE_ARCH}"
    return 0
  fi

  [[ -n "${RESOLVED_TARGET}" ]] || resolve_target

  if [[ "${DRY_RUN}" == "1" ]]; then
    log_info "[DRY_RUN] ssh ${SSH_USER}@${RESOLVED_TARGET} uname -m  # device arch probe (assuming host arch offline)" >&2
    arch_normalize "$(uname -m)"
    return 0
  fi

  local raw
  raw="$(transport_ssh "uname -m")"
  raw="${raw//[$'\r\n']/}"
  [[ -n "${raw}" ]] || die "device_arch: empty 'uname -m' from device"
  arch_normalize "${raw}"
}

# ---------------------------------------------------------------------------
# arch_guard <artifact> — REFUSE (non-zero) when the artifact's arch differs
# from the device's. The single gate dev-push-style loops must clear before any
# binary leaves the workstation.
# ---------------------------------------------------------------------------
arch_guard() {
  local artifact="$1"
  [[ -n "${artifact}" ]] || die "arch_guard: missing <artifact>"

  local want got
  got="$(artifact_arch "${artifact}")"
  want="$(device_arch)"

  if [[ "${got}" != "${want}" ]]; then
    die "arch_guard: REFUSING push — artifact '${artifact}' is ${got} but device is ${want}. Build the artifact for ${want} (build on a ${want} host or stage a ${want} .deb)."
  fi
  log_success "arch_guard: OK — artifact ${got} matches device ${want}"
}
