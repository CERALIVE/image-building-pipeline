#!/usr/bin/env bash
#
# kernel/builder.sh — builder-container management and the build-job preflight
# for lib/build-kernel.sh.
#
# Sourced by lib/build-kernel.sh, never executed.
#
# DYNAMIC SCOPING (the lib/stages/ contract): resolve_kernel_builder_tag and
# ensure_kernel_builder_image read KERNEL_BUILDER_DOCKERFILE, which is a LOCATION
# and therefore stays declared in the build-kernel.sh entry alongside the other
# locations. Do not re-declare it here.
#
# shellcheck shell=bash
# shellcheck disable=SC2154

# Peak RSS of one kernel compile job, rounded up. Both the ceiling and the unit
# are empirical, so they live next to the arithmetic that consumes them.
KERNEL_BUILD_MEM_PER_JOB_KIB=$((2 * 1024 * 1024))

# ---------------------------------------------------------------------------
# derive_kernel_build_jobs — echo the `make -j` width, and log how it got there.
#
# The failure this exists to prevent is not a slow build, it is a DEAD one:
# `make -j$(nproc)` on a core-rich but memory-thin host gets OOM-killed deep
# inside bindeb-pkg, after the clone, the patch series and the config gate have
# all already passed — so the build burns half an hour to report a link error or
# a bare "Killed". min(nproc, MemAvailable / 2 GiB) is the cheap guard, floored
# at 1 (a serial build beats no build) and ceilinged at nproc (spare memory buys
# no extra cores).
#
# CERALIVE_KERNEL_BUILD_JOBS wins UNCONDITIONALLY: an operator who has measured
# their own host outranks a heuristic, including upward.
# ---------------------------------------------------------------------------
derive_kernel_build_jobs() {
  local meminfo="${CERALIVE_RESOURCE_MEMINFO_FILE:-/proc/meminfo}"
  local cpus mem_kib mem_jobs jobs

  if [[ -n "${CERALIVE_KERNEL_BUILD_JOBS:-}" ]]; then
    [[ "${CERALIVE_KERNEL_BUILD_JOBS}" =~ ^[1-9][0-9]*$ ]] \
      || die "CERALIVE_KERNEL_BUILD_JOBS must be a positive integer (got '${CERALIVE_KERNEL_BUILD_JOBS}')"
    log_info "build jobs: ${CERALIVE_KERNEL_BUILD_JOBS} (CERALIVE_KERNEL_BUILD_JOBS override — memory ceiling not applied)"
    printf '%s' "${CERALIVE_KERNEL_BUILD_JOBS}"
    return 0
  fi

  cpus="$(nproc 2>/dev/null || echo 4)"
  [[ "${cpus}" =~ ^[1-9][0-9]*$ ]] || cpus=4

  mem_kib="$(awk '$1 == "MemAvailable:" { print $2; found = 1 } END { if (!found) exit 1 }' \
    "${meminfo}" 2>/dev/null)" || mem_kib=""
  if [[ ! "${mem_kib}" =~ ^[0-9]+$ ]]; then
    # Inventing a memory figure here would silently reintroduce the OOM default
    # under a name that claims to have prevented it, so say what happened.
    log_warn "build jobs: ${cpus} — no readable MemAvailable in ${meminfo}, falling back to nproc with NO memory ceiling"
    printf '%s' "${cpus}"
    return 0
  fi

  mem_jobs=$(( mem_kib / KERNEL_BUILD_MEM_PER_JOB_KIB ))
  jobs=$(( mem_jobs < cpus ? mem_jobs : cpus ))
  (( jobs >= 1 )) || jobs=1

  log_info "build jobs: ${jobs} = min(nproc=${cpus}, MemAvailable ${mem_kib} kB / $((KERNEL_BUILD_MEM_PER_JOB_KIB / 1024)) MiB per job = ${mem_jobs}) — floor 1, ceiling nproc"
  printf '%s' "${jobs}"
}

# ---------------------------------------------------------------------------
# select_container_runtime — docker first, then podman. The kernel build is a
# containerized stage by construction: a host-native build would silently bind
# the produced kernel to whatever toolchain that host happens to carry.
# ---------------------------------------------------------------------------
select_container_runtime() {
  if command -v docker >/dev/null 2>&1; then
    printf 'docker'
  elif command -v podman >/dev/null 2>&1; then
    printf 'podman'
  else
    die "kernel-build-from-source needs a container runtime (docker or podman). There is deliberately no host-native fallback: a host build would bind the kernel to an unpinned toolchain."
  fi
}

# ---------------------------------------------------------------------------
# resolve_kernel_builder_tag <base_image> — the builder tag, content-addressed.
#
# The tag embeds a digest of the Dockerfile AND the manifest's builder_image pin,
# because ensure_kernel_builder_image below skips the build when the tag already
# exists locally. A constant tag makes that short-circuit permanent: an edited
# Dockerfile or a bumped builder_image pin is silently ignored on every host that
# ever built the image once, and the stale layers keep being used. This mirrors
# the mkosi builder, whose tag carries its version pin.
# ---------------------------------------------------------------------------
resolve_kernel_builder_tag() {
  local base_image="$1" key
  if [[ -n "${CERALIVE_KERNEL_BUILDER_IMAGE:-}" ]]; then
    printf '%s' "${CERALIVE_KERNEL_BUILDER_IMAGE}"
    return 0
  fi
  key="$( { printf '%s\n' "${base_image}"; cat "${KERNEL_BUILDER_DOCKERFILE}"; } \
    | sha256sum | cut -c1-12 )"
  printf 'ceralive-kernel-builder:%s' "${key}"
}

ensure_kernel_builder_image() {
  local runtime="$1" base_image="$2" tag="$3"
  assert_container_daemon_supported "${runtime}"
  [[ -f "${KERNEL_BUILDER_DOCKERFILE}" ]] \
    || die "kernel builder Dockerfile missing: ${KERNEL_BUILDER_DOCKERFILE}"
  if "${runtime}" image inspect "${tag}" >/dev/null 2>&1; then
    log_info "kernel builder image ${tag} present"
    return 0
  fi
  log_info "building kernel builder image ${tag} FROM ${base_image}"
  "${runtime}" build \
    --build-arg "BASE_IMAGE=${base_image}" \
    -t "${tag}" \
    -f "${KERNEL_BUILDER_DOCKERFILE}" \
    "$(dirname "${KERNEL_BUILDER_DOCKERFILE}")" \
    || die "failed to build the kernel builder image from ${KERNEL_BUILDER_DOCKERFILE}"
}
