#!/usr/bin/env bash
#
# arch.sh — architecture guard for the dev-sync loop.
#
# The CeraLive first-party components (ceracoder, srtla) are PURE BINARIES. An
# RK3588 board is arm64; a developer laptop is usually amd64. Pushing an amd64
# binary to an arm64 device produces an artifact that installs but can NEVER run
# ("Exec format error"), and the failure surfaces far from its cause. This guard
# REFUSES that push up front.
#
# It compares two normalized arches:
#   - the ARTIFACT arch, read from the binary itself via `file` (content truth,
#     not a guess from the build host);
#   - the DEVICE arch, read from the board via `ssh … uname -m` (or the
#     DEV_SYNC_DEVICE_ARCH override for offline use / known fleets).
#
# Both are normalized to the Debian names the rest of the pipeline speaks:
#   x86_64  → amd64        aarch64 / arm64 → arm64
# Anything else dies loudly rather than guessing.
#
# DRY_RUN=1 (mirrors dev-push): the device-side `ssh … uname -m` is LOGGED, not
# executed; the artifact arch is still read locally (cheap, offline) and printed,
# so the planned comparison is fully visible without touching the device.
#
# shellcheck shell=bash

ARCH_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# config.sh → common.sh (strict mode, loggers, die, require_cmd) + DEV_SYNC_*.
# shellcheck source=config.sh
source "${ARCH_HERE}/config.sh"
# transport.sh gives us resolve_target + transport_ssh for the device probe.
# shellcheck source=transport.sh
source "${ARCH_HERE}/transport.sh"

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

# ---------------------------------------------------------------------------
# CLI — sourceable as a library; runnable for QA.
#   arch.sh host
#   arch.sh artifact <path>
#   arch.sh device
#   arch.sh guard <artifact>
# ---------------------------------------------------------------------------
_arch_main() {
  local sub="${1:-}"
  shift || true
  case "${sub}" in
    host)     host_arch; printf '\n' ;;
    artifact) [[ $# -ge 1 ]] || die "usage: arch.sh artifact <path>"; artifact_arch "$1"; printf '\n' ;;
    device)   device_arch; printf '\n' ;;
    guard)    [[ $# -ge 1 ]] || die "usage: arch.sh guard <artifact>"; arch_guard "$1" ;;
    ""|-h|--help)
      cat >&2 <<EOF
Usage: arch.sh <host|artifact <path>|device|guard <artifact>>
  host                normalized arch of this build host
  artifact <path>     normalized arch of a binary (via 'file')
  device              normalized arch of the target (ssh uname -m / override)
  guard <artifact>    REFUSE (non-zero) on artifact↔device arch mismatch
Env: DEV_SYNC_DEVICE_ARCH overrides the ssh probe; DRY_RUN logs the probe.
EOF
      [[ "${sub}" == "" ]] && return 1 || return 0
      ;;
    *) die "arch.sh: unknown subcommand '${sub}' (host|artifact|device|guard)" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  _arch_main "$@"
fi
