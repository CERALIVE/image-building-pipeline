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
# a bare "Killed". min(cpus, memory budget / 2 GiB) is the cheap guard, floored
# at 1 (a serial build beats no build) and ceilinged at the CPU count (spare
# memory buys no extra cores).
#
# BOTH INPUTS ARE CGROUP-AWARE (lib/shared/resource-lib.sh). `nproc` and
# `MemAvailable` describe the MACHINE, and this stage runs inside a container in
# CI: a 4-CPU cgroup on a 32-core host answered 32, and a memory-thin cgroup
# answered the HOST's generous MemAvailable right up to the OOM kill. The
# derivation therefore walks the whole cgroup v2 chain, leaf to root, and takes
# the minimum. An unconstrained host finds no limits and collapses to exactly the
# pre-cgroup answer, so nothing changes there.
#
# CERALIVE_KERNEL_BUILD_JOBS is CLAMPED to the memory-derived ceiling rather than
# obeyed unconditionally. An operator who has measured their own host still
# outranks the heuristic — but a stale override inherited from a roomier machine
# (or from a CI variable set before the job was containerized) is the same dead
# build the ceiling exists to prevent, and it fails in a way that reads as a
# kernel problem. CERALIVE_KERNEL_BUILD_JOBS_FORCE=1 is the explicit,
# self-documenting way to say "yes, I mean it, including upward".
# ---------------------------------------------------------------------------
derive_kernel_build_jobs() {
  local meminfo="${CERALIVE_RESOURCE_MEMINFO_FILE:-/proc/meminfo}"
  local cpus mem_kib mem_jobs jobs override force ceiling per_job_mib

  per_job_mib=$((KERNEL_BUILD_MEM_PER_JOB_KIB / 1024))
  override="${CERALIVE_KERNEL_BUILD_JOBS:-}"
  force="${CERALIVE_KERNEL_BUILD_JOBS_FORCE:-0}"

  if [[ -n "${override}" ]]; then
    [[ "${override}" =~ ^[1-9][0-9]*$ ]] \
      || die "CERALIVE_KERNEL_BUILD_JOBS must be a positive integer (got '${override}')"
  fi
  # Refused rather than guessed at: `FORCE=true` silently reading as "off" is an
  # operator who believes the clamp is disabled while it is armed.
  [[ "${force}" =~ ^[01]$ ]] \
    || die "CERALIVE_KERNEL_BUILD_JOBS_FORCE must be 0 or 1 (got '${force}')"

  if [[ -n "${override}" && "${force}" == "1" ]]; then
    log_warn "build jobs: ${override} (CERALIVE_KERNEL_BUILD_JOBS override, FORCED by CERALIVE_KERNEL_BUILD_JOBS_FORCE=1 — memory ceiling NOT applied)"
    printf '%s' "${override}"
    return 0
  fi

  resource_effective_cpus
  cpus="${RESOURCE_EFFECTIVE_CPUS}"

  if ! resource_mem_budget_kib; then
    # Inventing a memory figure here would silently reintroduce the OOM default
    # under a name that claims to have prevented it, so say what happened.
    if [[ -n "${override}" ]]; then
      log_warn "build jobs: ${override} (CERALIVE_KERNEL_BUILD_JOBS override — neither MemAvailable in ${meminfo} nor a cgroup v2 memory.max is readable, so NO memory ceiling could be applied)"
      printf '%s' "${override}"
      return 0
    fi
    log_warn "build jobs: ${cpus} — no readable MemAvailable in ${meminfo} and no cgroup v2 memory.max, falling back to ${RESOURCE_CPU_BASIS} with NO memory ceiling"
    printf '%s' "${cpus}"
    return 0
  fi

  mem_kib="${RESOURCE_MEM_BUDGET_KIB}"
  mem_jobs="$(resource_jobs_for_mem "${mem_kib}" "${KERNEL_BUILD_MEM_PER_JOB_KIB}")"

  if [[ -n "${override}" ]]; then
    ceiling="${mem_jobs}"
    (( ceiling >= 1 )) || ceiling=1
    if (( override > ceiling )); then
      log_warn "build jobs: ${ceiling} — CERALIVE_KERNEL_BUILD_JOBS=${override} CLAMPED to the memory-derived ceiling (${mem_kib} kB / ${per_job_mib} MiB per job; ${RESOURCE_MEM_BASIS}); set CERALIVE_KERNEL_BUILD_JOBS_FORCE=1 to override the clamp"
      printf '%s' "${ceiling}"
      return 0
    fi
    log_info "build jobs: ${override} (CERALIVE_KERNEL_BUILD_JOBS override, within the memory-derived ceiling of ${ceiling})"
    printf '%s' "${override}"
    return 0
  fi

  jobs=$(( mem_jobs < cpus ? mem_jobs : cpus ))
  (( jobs >= 1 )) || jobs=1

  log_info "build jobs: ${jobs} = min(nproc=${RESOURCE_NPROC} -> cpus ${cpus}, MemAvailable ${RESOURCE_MEM_AVAILABLE_KIB:-unreadable} kB -> budget ${mem_kib} kB / ${per_job_mib} MiB per job = ${mem_jobs}) — floor 1, ceiling cpus; cpu: ${RESOURCE_CPU_BASIS}; mem: ${RESOURCE_MEM_BASIS}"
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
