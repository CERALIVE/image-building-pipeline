#!/usr/bin/env bash
#
# common.sh — strict shared bash library for the CeraLive image-building v2 pipeline.
#
# This is the single foundation every v2 script sources. It establishes:
#   - the `build-strict` shell profile: set -euo pipefail plus a loud ERR trap
#     that reports the failing file:line and command (docs/shell-profiles.md)
#   - the canonical loggers, by sourcing lib/shared/log-lib.sh
#   - die() for fatal exits and require_cmd() for dependency preconditions
#
# DESIGN RULE: there is intentionally NO `|| true` / best-effort error swallowing
# anywhere in this file — and, by extension, none on the sacred fetch path that
# sources it. Silent apt/dpkg failures were the root cause of v1 unreliability
# (see customize-image.sh:170-174,231-232). v2 fails loudly, always: the `trap
# err_trap ERR` installed below converts ANY unguarded non-zero command into an
# immediate, file:line-reported exit. A stray `|| true` would defeat that trap by
# resetting the failing command's exit status to 0 BEFORE the trap can see it — so
# the two rules are one and the same: keep commands unguarded and let err_trap
# report them. The ONLY sanctioned way to say "this command does not run now" is
# the explicit DRY_RUN plan path (fetch-debs.sh `run_or_plan`), which LOGS the
# command and returns 0 deliberately — never the silent `|| true` shortcut.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
#
# shellcheck shell=bash

set -euo pipefail

# ---------------------------------------------------------------------------
# Loggers — the ONE formatter, extracted to a standalone file so a script on the
# device-daemon or contract-test profile can have the format without inheriting
# this file's strict mode and ERR trap. See docs/shell-profiles.md.
# ---------------------------------------------------------------------------
# shellcheck source=shared/log-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/shared/log-lib.sh"

# ---------------------------------------------------------------------------
# Error trap — fail loudly with file:line context.
# ---------------------------------------------------------------------------
err_trap() {
  # Capture the exit status of the command that tripped the trap first.
  local exit_code=$?
  log_error "ERROR at ${BASH_SOURCE[1]:-?}:${BASH_LINENO[0]:-?}: ${BASH_COMMAND} (exit ${exit_code})"
  exit 1
}
trap err_trap ERR

# ---------------------------------------------------------------------------
# die — log a fatal message and exit non-zero.
# ---------------------------------------------------------------------------
die() {
  log_error "$*"
  exit 1
}

# ---------------------------------------------------------------------------
# require_cmd — assert an external command exists, or die with guidance.
#   require_cmd mkosi || die "..."   # explicit form
#   require_cmd mkosi                # also dies on its own with a default msg
# ---------------------------------------------------------------------------
require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    die "command '${cmd}' not found, install it first"
  fi
}

# ---------------------------------------------------------------------------
# resolve_source_date_epoch [repo-dir] — echo a STABLE epoch for reproducible
# builds: env override > HEAD commit time (pins epoch to source state) > frozen
# fallback. Callers EXPORT it as SOURCE_DATE_EPOCH so every embedded mtime
# (tar/squashfs/ext4/CMS) clamps to one value. The git probe sits in the `if`
# condition so a non-repo dir cannot trip the ERR trap.
# ---------------------------------------------------------------------------
resolve_source_date_epoch() {
  local repo_dir="${1:-.}" epoch=""
  if [[ -n "${SOURCE_DATE_EPOCH:-}" ]]; then
    printf '%s' "${SOURCE_DATE_EPOCH}"
    return 0
  fi
  if epoch="$(git -C "${repo_dir}" log -1 --pretty=%ct 2>/dev/null)" && [[ -n "${epoch}" ]]; then
    printf '%s' "${epoch}"
    return 0
  fi
  printf '%s' "${CERALIVE_EPOCH_FALLBACK:-1577836800}"   # 2020-01-01T00:00:00Z
}

# ---------------------------------------------------------------------------
# partlabel_prefix / resolve_partlabel <name> — the GPT PARTLABEL to use for a
# contract partition role (boot | rootfs_a | rootfs_b | data).
#
# Default: the FROZEN production label, verbatim (docs/partition-contract.md §3).
#
# CERALIVE_BENCH_LABELS=1 (bench-only, opt-in) returns the `x`-prefixed twin —
# xboot / xrootfs_a / xrootfs_b / xdata. A bench microSD gets booted on a board
# whose eMMC already carries a production image, and every mount/slot lookup in
# the contract is by PARTLABEL, so duplicate labels across the two media make
# `PARTLABEL=rootfs_a` ambiguous on the running kernel. Renaming the bench set
# makes that collision structurally impossible. It is NEVER set on a release
# path; the frozen contract itself is unchanged.
#
# EVERY producer of a PARTLABEL reference must go through this (or its
# self-contained twin in customize/postinst-lib.sh and platform/boot/install-boot.sh):
# a GPT relabelled without its fstab/RAUC/boot-selector counterparts does not
# boot at all, which is worse than the collision it was meant to avoid.
# ---------------------------------------------------------------------------
partlabel_prefix() {
  [[ "${CERALIVE_BENCH_LABELS:-0}" == "1" ]] && printf 'x'
  return 0
}

resolve_partlabel() {
  printf '%s%s' "$(partlabel_prefix)" "${1:?resolve_partlabel needs a partition role}"
}

# ---------------------------------------------------------------------------
# DEV_DELTA_BASENAME + runtime_pkg_list_files <shared-list> <packages-dir>
#
# The canonical runtime package lists for a build, in read order. The shared list
# is passed separately from the directory because both consumers expose them as
# independent overrides (SHARED_LIST / PKG_MANIFEST_DIR).
#
# `development.delta.list` is keyed on the BUILD VARIANT, not on the board
# family, but it shares the `.delta.list` suffix because it is the same format —
# so every `*.delta.list` DIRECTORY GLOB in this repo would otherwise swallow it
# and require its 18 debug packages in a PRODUCTION rootfs (parity-check.sh's
# expected set, realhw-suite.sh's synthesized dpkg status). That is the exact
# defect this helper exists to make impossible: the debug delta is skipped by
# name, then re-appended ONLY when CERALIVE_DEBUG_IMAGE=1.
#
# Every consumer that globs the directory MUST go through this. A consumer that
# keeps its own glob silently reintroduces the production/debug leak.
# ---------------------------------------------------------------------------
DEV_DELTA_BASENAME='development.delta.list'

runtime_pkg_list_files() {
  local shared="${1:?runtime_pkg_list_files needs the shared list}"
  local dir="${2:?runtime_pkg_list_files needs the packages dir}" f
  [[ -f "${shared}" ]] && printf '%s\n' "${shared}"
  for f in "${dir}"/*.delta.list; do
    [[ -f "${f}" ]] || continue
    [[ "${f##*/}" == "${DEV_DELTA_BASENAME}" ]] && continue
    printf '%s\n' "${f}"
  done
  if [[ "${CERALIVE_DEBUG_IMAGE:-0}" == "1" && -f "${dir}/${DEV_DELTA_BASENAME}" ]]; then
    printf '%s\n' "${dir}/${DEV_DELTA_BASENAME}"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# assert_container_daemon_supported <runtime> — refuse a container daemon whose
# bind mounts cannot carry a Linux rootfs.
#
# Every containerized stage here bind-mounts the checkout and then has ROOT
# inside the container create, own, delete and re-create trees on it. The mkosi
# package cache is the sharpest case: mkosi/cache/<board>/*base.cache is a real
# rootfs snapshot, written as uid 0, and mkosi 26 both REFUSES to reuse a cache
# tree whose owner uid differs from its own (`have_cache`) and then DELETES it
# (`run_clean` -> `remove_cache_entries` -> `mkosi.tree.rmtree`, whose `rm -rf`
# runs with check=True, so a failed unlink fails the build).
#
# A Docker Desktop daemon breaks that in two ways, both observed on this repo's
# own hardware-candidate build rather than reasoned about:
#
#   * its bind mount is a VM share whose host-side I/O runs as the DESKTOP USER,
#     so even a `--privileged` root container cannot unlink a host-uid-0 file.
#     The invalidation above then dies in a wall of `rm: cannot remove
#     '/work/work/mkosi/cache/…/etc/ucf.conf': Permission denied`, naming a path
#     no filesystem the operator can see contains — the leading /work is mkosi's
#     own sandbox remapping (`mkosi.run.workdir`), the second our `-v :/work`.
#   * that share has no POSIX ACL/xattr support, and mkosi extracts every
#     subimage with `tar --acls --xattrs`, so the base layer dies with
#     `acl_set_file_at: Operation not supported` before one package is installed.
#
# Chowning the cache to the invoking user is NOT the escape: mkosi's uid check
# would then reject it on every later containerized run — a permanently cold
# cache wearing the costume of a fix. The daemon is the defect, so it is refused.
#
# podman on Linux is not a VM share and reports a different `info` schema, so the
# check is scoped to docker.
# ---------------------------------------------------------------------------
assert_container_daemon_supported() {
  local runtime="${1:?assert_container_daemon_supported needs a runtime}" daemon_os
  [[ "${runtime}" == "docker" ]] || return 0

  daemon_os="$("${runtime}" info --format '{{.OperatingSystem}}')" \
    || die "cannot query the ${runtime} daemon ('${runtime} info' failed). Start it, or point DOCKER_CONTEXT/DOCKER_HOST at a live Linux daemon."

  if [[ "${daemon_os}" == *"Docker Desktop"* ]]; then
    die "containerized build refuses the Docker Desktop daemon (OperatingSystem='${daemon_os}'). Its bind mount is a VM share: root in the container cannot unlink host-root-owned files (mkosi's cache invalidation dies in 'rm: cannot remove …: Permission denied'), and it supports no POSIX ACLs/xattrs (mkosi's 'tar --acls --xattrs' dies in 'acl_set_file_at: Operation not supported'). Select a native Linux daemon — e.g. DOCKER_CONTEXT=default with unix:///var/run/docker.sock — and re-run."
  fi

  log_info "container daemon: ${daemon_os} (native bind mounts — real uids, ACLs and xattrs)"
  return 0
}

# ---------------------------------------------------------------------------
# BUILDER-IMAGE BUILDS — one entry point, because both Dockerfiles depend on
# BuildKit-era `RUN --mount=type=cache` for their apt layers.
#
# `docker build` still selects the LEGACY builder on a plain daemon, and the
# legacy builder does not merely IGNORE a `--mount` flag — it refuses to parse
# the Dockerfile ("Unknown flag: mount"). DOCKER_BUILDKIT=1 is therefore a
# correctness requirement here rather than a speed knob, and it is set in this
# one function so a third build site cannot be added without it.
#
# podman needs no equivalent switch (buildah parses RUN --mount natively) but it
# does need a floor: the `cache` mount TYPE landed in buildah 1.24 / podman 4.0.
# Below that the same Dockerfile fails inside a file the operator did not write,
# so the floor is asserted here with a message that names the real cause.
# ---------------------------------------------------------------------------
CONTAINER_BUILD_MIN_DOCKER_MAJOR="${CONTAINER_BUILD_MIN_DOCKER_MAJOR:-23}"
CONTAINER_BUILD_MIN_PODMAN_MAJOR="${CONTAINER_BUILD_MIN_PODMAN_MAJOR:-4}"

# Echo the leading integer of `<runtime> --version`, or nothing when the output
# has a shape this refuses to guess at.
container_runtime_major() {
  local runtime="${1:?container_runtime_major needs a runtime}" out major
  out="$("${runtime}" --version 2>/dev/null)" || return 0
  major="$(printf '%s' "${out}" | sed -n 's/.*[^0-9]\([0-9][0-9]*\)\.[0-9].*/\1/p' | head -n1)"
  [[ "${major}" =~ ^[0-9]+$ ]] || return 0
  printf '%s' "${major}"
}

assert_container_build_cache_mounts() {
  local runtime="${1:?assert_container_build_cache_mounts needs a runtime}"
  local major floor
  case "${runtime}" in
    docker) floor="${CONTAINER_BUILD_MIN_DOCKER_MAJOR}" ;;
    podman) floor="${CONTAINER_BUILD_MIN_PODMAN_MAJOR}" ;;
    *) return 0 ;;
  esac
  major="$(container_runtime_major "${runtime}")"
  # An unparsable version is not a refusal: the build then fails on its own, with
  # the Dockerfile line in hand, which is a better diagnostic than a guess made
  # from a version string this did not recognise.
  if [[ -z "${major}" ]]; then
    log_warn "could not read a ${runtime} version — proceeding, but ci/Dockerfile* need ${runtime} >= ${floor} for 'RUN --mount=type=cache'"
    return 0
  fi
  (( major >= floor )) && return 0
  die "ci/Dockerfile and ci/Dockerfile.kernel use 'RUN --mount=type=cache' for their apt layers, which needs ${runtime} >= ${floor} (found ${major}). Upgrade ${runtime}, or build the builder image elsewhere and pin it with MKOSI_BUILDER_IMAGE / CERALIVE_KERNEL_BUILDER_IMAGE."
}

# container_image_build <runtime> <build args...>
container_image_build() {
  local runtime="${1:?container_image_build needs a runtime}"; shift
  assert_container_build_cache_mounts "${runtime}"
  if [[ "${runtime}" == "docker" ]]; then
    DOCKER_BUILDKIT=1 "${runtime}" build "$@"
    return
  fi
  "${runtime}" build "$@"
}

# container_build_proxy_args — emit `--build-arg APT_PROXY=<url>` when, and only
# when, CERALIVE_APT_PROXY is set. Unset emits NOTHING, so an unconfigured build
# passes the same argument vector it did before the proxy existed.
container_build_proxy_args() {
  [[ -n "${CERALIVE_APT_PROXY:-}" ]] || return 0
  printf '%s\n' --build-arg "APT_PROXY=${CERALIVE_APT_PROXY}"
}
