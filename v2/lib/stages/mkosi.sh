#!/usr/bin/env bash
#
# stages/mkosi.sh — orchestrator stage [5/9]: build the image layers with mkosi.
#
# Also holds the builder-mode selection and the invocation itself. The ENVIRONMENT
# CONTRACT that invocation carries — the env_names list and its exports — deliberately
# stays in lib/orchestrate.sh::run_mkosi_build, in lockstep with mkosi.conf
# PassEnvironment=. mkosi_invoke below is only the "how do we actually run mkosi"
# half, and reads mkosi_args / env_names / cache_dir out of that caller's frame.
#
# Sourced by lib/orchestrate.sh. See stages/resolve.sh for the dynamic-scoping
# contract every stage module relies on.
#
# shellcheck shell=bash
# SC2154/SC2034: names that look unassigned, or assigned-and-unused, are main()'s
# locals read or written through the dynamic scoping described above. Checked
# standalone, shellcheck cannot see that frame.
# shellcheck disable=SC2154,SC2034

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
# stage_dry_run_plan — [5/9] under DRY_RUN=1 (v2-ci build matrix).
#
# Reads from main()'s frame: board, mkosi_arch. Exits the build when it fires.
# ---------------------------------------------------------------------------
stage_dry_run_plan() {
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
}

# ---------------------------------------------------------------------------
# stage_mkosi — [5/9]
#
# Reads from main()'s frame: mkosi_arch, bsp_dir, firstparty_dir.
# Writes into main()'s frame: ts, build_version, rootfs_tree.
# ---------------------------------------------------------------------------
stage_mkosi() {
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  # Bundle VERSION is embedded in manifest.raucm, so it must be deterministic
  # (the filename ts may stay wall-clock — it is not part of the .raucb bytes).
  build_version="$(git -C "${V2_DIR}" rev-parse --short HEAD 2>/dev/null || true)"
  [[ -n "${build_version}" ]] || build_version="$(date -u -d "@${SOURCE_DATE_EPOCH}" +%Y%m%dT%H%M%SZ 2>/dev/null || printf '%s' "${SOURCE_DATE_EPOCH}")"
  rootfs_tree="${MKOSI_DIR}/build/app"
  log_info "[5/9] building image layers with mkosi (${mkosi_arch}) — base → platform → runtime → app"
  run_mkosi_build "${mkosi_arch}" "${bsp_dir}" "${firstparty_dir}"
  [[ -d "${rootfs_tree}" ]] || die "mkosi did not produce an app rootfs at ${rootfs_tree}"
}

# ---------------------------------------------------------------------------
# mkosi_invoke — run mkosi natively or in the pinned builder container.
#
# Called by run_mkosi_build (lib/orchestrate.sh) with NO arguments: everything it
# needs — mkosi_arch, cache_dir, mkosi_args, env_names, bsp_dir, firstparty_dir —
# is in that caller's frame.
# ---------------------------------------------------------------------------
mkosi_invoke() {
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
