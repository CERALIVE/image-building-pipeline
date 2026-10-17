#!/usr/bin/env bash
#
# rauc-build/builder.sh — builder-container management for lib/build-rauc.sh.
#
# Sourced by lib/build-rauc.sh, never executed.
#
# Deliberately much smaller than kernel/builder.sh: RAUC's meson build has no
# multi-hour compile, no ccache, and no memory-derived -j clamp worth the code —
# a plain `nproc` is fine for a project this size. Only the pieces that ARE
# shared in spirit (container runtime selection, content-addressed builder tag,
# build-once-then-reuse) are mirrored, at RAUC's own scale.
#
# shellcheck shell=bash
# shellcheck disable=SC2154

# ---------------------------------------------------------------------------
# select_rauc_container_runtime — docker first, then podman. Same contract as
# kernel/builder.sh::select_container_runtime: no host-native fallback, so the
# built package is never silently bound to an unpinned host toolchain/libc.
# ---------------------------------------------------------------------------
select_rauc_container_runtime() {
  if command -v docker >/dev/null 2>&1; then
    printf 'docker'
  elif command -v podman >/dev/null 2>&1; then
    printf 'podman'
  else
    die "rauc-build needs a container runtime (docker or podman). There is deliberately no host-native fallback: a host build would bind the package to an unpinned toolchain/libc."
  fi
}

# ---------------------------------------------------------------------------
# resolve_rauc_builder_tag <base_image> <platform> — content-addressed tag, same
# reasoning as kernel/builder.sh::resolve_kernel_builder_tag: embeds a digest of
# the Dockerfile AND the base image pin so an edited Dockerfile or a bumped pin
# is never silently served stale layers by the "tag already exists"
# short-circuit. <platform> (e.g. "linux/arm64") is ALSO part of the tag —
# unlike the kernel builder (one native-host container + a cross toolchain),
# this builder is run under `--platform` per target arch (native on this host
# for amd64, qemu-emulated for arm64), and a single shared tag across two
# actually-different image contents (one per platform) is exactly the
# "docker image inspect finds SOMETHING under this tag and skips the build"
# trap — confirmed by hitting it directly: an amd64-only image built first
# left the arm64 run silently trying to pull a nonexistent registry image
# under the same tag.
# ---------------------------------------------------------------------------
resolve_rauc_builder_tag() {
  local base_image="$1" platform="$2" key platform_slug
  if [[ -n "${CERALIVE_RAUC_BUILDER_IMAGE:-}" ]]; then
    printf '%s' "${CERALIVE_RAUC_BUILDER_IMAGE}"
    return 0
  fi
  platform_slug="${platform//\//-}"
  key="$( { printf '%s\n' "${base_image}" "${platform}"; cat "${RAUC_BUILDER_DOCKERFILE}"; } \
    | sha256sum | cut -c1-12 )"
  printf 'ceralive-rauc-builder-%s:%s' "${platform_slug}" "${key}"
}

ensure_rauc_builder_image() {
  local runtime="$1" base_image="$2" tag="$3" platform="$4"
  assert_container_daemon_supported "${runtime}"
  [[ -f "${RAUC_BUILDER_DOCKERFILE}" ]] \
    || die "rauc builder Dockerfile missing: ${RAUC_BUILDER_DOCKERFILE}"
  if "${runtime}" image inspect "${tag}" >/dev/null 2>&1; then
    log_info "rauc builder image ${tag} present"
    return 0
  fi
  log_info "building rauc builder image ${tag} (platform=${platform}) FROM ${base_image}"
  local -a proxy_args=()
  mapfile -t proxy_args < <(container_build_proxy_args)
  (( ${#proxy_args[@]} )) && log_info "apt proxy: ${proxy_args[*]} (http only; https DIRECT)"
  container_image_build "${runtime}" \
    --platform "${platform}" \
    --build-arg "BASE_IMAGE=${base_image}" \
    "${proxy_args[@]}" \
    -t "${tag}" \
    -f "${RAUC_BUILDER_DOCKERFILE}" \
    "$(dirname "${RAUC_BUILDER_DOCKERFILE}")" \
    || die "failed to build the rauc builder image from ${RAUC_BUILDER_DOCKERFILE}"
}

# ---------------------------------------------------------------------------
# rauc_docker_platform <arch> — the Debian package arch this repo already uses
# ("arm64"/"amd64", see lib/fetch-debs.sh's own ARCH normalization) mapped to the
# `--platform` value `docker run`/`docker build` expect. Native on this build
# host when it matches; emulated via qemu-user-static/binfmt otherwise — the
# SAME emulation ci/Dockerfile's own mkosi container build already depends on
# for arm64, so no new host capability is introduced.
# ---------------------------------------------------------------------------
rauc_docker_platform() {
  case "$1" in
    arm64) printf 'linux/arm64' ;;
    amd64) printf 'linux/amd64' ;;
    *) die "rauc-build: unsupported Debian package architecture '$1' (expected arm64|amd64)" ;;
  esac
}
