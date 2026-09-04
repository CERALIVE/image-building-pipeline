#!/usr/bin/env bash
#
# build-kernel.sh — kernel-build-from-source stage for the CeraLive v2 pipeline.
#
# This stage runs when, and only when, the resolved manifest carries a
# `kernel_source:` block. On rk3588 that is EVERY build, because the family
# declares `default_variant: edge` and both its variants build from source; a
# family or variant that declares no such block (x86-minipc) never reaches this
# file.
#
# BACKEND (decided, pinned — see manifests/schema/family.schema.json $defs):
#   plain kernel `make bindeb-pkg` from the pinned source tree + the applied
#   patch series + the resolved kernel config, inside the digest-pinned builder
#   container. The Armbian build framework is consulted ONLY for the branch/tag
#   mapping (done upstream in the CERALIVE kernel-patch repos' scripts/preflight.sh
#   and recorded in their kernel-pin.env) and — in CONFIG-FILE mode — for the
#   plain `.config` FILE it publishes; it is NEVER invoked as the build system.
#   That is a deliberate choice: Armbian's framework brings its own patch stack,
#   packaging and userspace assumptions, and adopting it would make "what
#   exactly is in this kernel" unanswerable from this repo.
#
# TWO SOURCE-CHECKOUT SHAPES. `commit` is always THE pin. `tag` is optional:
#   * tag present  -> `git clone --depth 1 --branch <tag>`, then assert HEAD == commit
#                     (a moved tag fails loudly instead of silently building
#                     different source).
#   * tag absent   -> shallow-fetch the pinned SHA directly, then assert HEAD ==
#                     commit. This is the ONLY correct shape for a rolling BSP
#                     branch that publishes no tags at all (armbian/linux-rockchip
#                     rk-6.1-rkr5.1). A synthetic tag would misrepresent the source.
#
# TWO CONFIG MODES, exactly one of which the manifest declares:
#   * DEFCONFIG mode    (defconfig_base + defconfig_fragment): `make <target>` then
#                       merge the repo-local Kconfig fragment on top.
#   * CONFIG-FILE mode  (config_git_url + config_commit + config_path): fetch a
#                       COMPLETE `.config` as a plain file from a pinned revision of
#                       another repo and use it verbatim as the starting .config.
#                       The vendor BSP works this way — Armbian publishes the exact
#                       full config the shipped kernel is built from, and a bare
#                       `make defconfig` would produce a materially different
#                       driver/feature set, i.e. NOT the kernel that runs on the
#                       board today.
#   Both modes then run the SAME olddefconfig -> syncconfig -> verify-kernel-config
#   sequence; the declared source config is the gate's expectation set either way.
#
# OUTPUT CONTRACT:
#   exactly ONE linux-image-* .deb, carrying the kernel AND the in-tree DTBs.
#   `make bindeb-pkg` also emits linux-headers-* and linux-libc-dev; those are
#   DISCARDED before staging (the device image installs neither). The build fails
#   if the expected linux-image deb is absent or if more than one matches.
#
# EVERY input is exact-pinned, and each pin is VERIFIED after checkout rather
# than trusted: the kernel tag must resolve to the pinned commit, and the patches
# repo is fetched at an immutable commit. A moved tag fails loudly instead of
# silently building different source.
#
# NETWORK RESILIENCE, AND THE ONE FAILURE THAT MUST NOT BE RETRIED. All three
# pinned fetches go through fetch_pinned_tree: each attempt runs under
# `timeout(1)` in an ATTEMPT-PRIVATE directory destroyed BEFORE it runs, because
# a half-cloned tree left at the destination makes every later retry fail
# deterministically ("destination path already exists", a stale index.lock) and
# reads as a hard outage when it is really the first blip plus our own debris.
#   A PIN MISMATCH IS NEVER RETRIED. It is checked after the retry loop and
# fails immediately: a moved tag or an orphaned SHA is a PERMANENT fact about
# the remote, so retrying it fetches the same wrong tree three times and reports
# a network problem instead of a pin problem. Only a fully pin-verified tree is
# renamed into the path the build reads.
#
# Usage:
#   build-kernel.sh --board <board> --out <dir> [--ccache-dir <dir>]
#
# Inputs arrive through the environment, already resolved by lib/resolve.sh and
# exported by lib/orchestrate.sh:
#   ARCH DTB_NAME KERNEL_PACKAGES
#   KERNEL_SOURCE_GIT_URL KERNEL_SOURCE_TAG KERNEL_SOURCE_COMMIT
#   KERNEL_SOURCE_PATCHES_GIT_URL KERNEL_SOURCE_PATCHES_COMMIT
#   KERNEL_SOURCE_PATCHES_SERIES
#   KERNEL_SOURCE_DEFCONFIG_BASE KERNEL_SOURCE_DEFCONFIG_FRAGMENT
#   KERNEL_SOURCE_DEFCONFIG_FRAGMENTS
#   KERNEL_SOURCE_CONFIG_GIT_URL KERNEL_SOURCE_CONFIG_COMMIT KERNEL_SOURCE_CONFIG_PATH
#   KERNEL_SOURCE_CONFIG_ABSENT_SYMBOLS
#   KERNEL_SOURCE_BUILDER_IMAGE KERNEL_SOURCE_LOCAL_VERSION
#   KERNEL_SOURCE_KERNEL_RELEASE KERNEL_SOURCE_PACKAGE_VERSION
#   KERNEL_SOURCE_DTB_DEB_DIR
#   SOURCE_DATE_EPOCH
#
# DRY_RUN=1 emits the full plan (every pinned coordinate and the exact make
# invocation) and touches no network, no container and no disk beyond the plan.
#
# shellcheck shell=bash
# shellcheck disable=SC2016  # injected bash -c payload expands inside the container

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${HERE}/common.sh"
# shellcheck source=lib/paths.sh
source "${HERE}/paths.sh"
# shellcheck source=lib/shared/resource-lib.sh
source "${HERE}/shared/resource-lib.sh"

PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"
KERNEL_BUILDER_DOCKERFILE="${PIPELINE_DIR}/ci/Dockerfile.kernel"
KERNEL_BUILDER_IMAGE_TAG=""
# Resolved by derive_kernel_build_jobs() in main(), not at source time: the
# derivation reads MemAvailable, and reading it once when the file is sourced
# would sample a moment that has nothing to do with when `make` runs.
KERNEL_BUILD_JOBS=""
# Bounded so a hung fetch cannot wedge a build host indefinitely, and retried so
# one blip does not discard an already-paid-for container and checkout. These
# defaults are mirrored by fetch_pinned_tree's own `:-` fallbacks, which is what
# lets that function run standalone; the agreement is pinned by a test.
KERNEL_GIT_ATTEMPTS="${CERALIVE_KERNEL_GIT_ATTEMPTS:-3}"
KERNEL_GIT_TIMEOUT="${CERALIVE_KERNEL_GIT_TIMEOUT:-1800}"
KERNEL_GIT_BACKOFF="${CERALIVE_KERNEL_GIT_BACKOFF:-5}"

# ---------------------------------------------------------------------------
# CONCERN MODULES (lib/kernel/) — this file stays the STAGE: the CLI, the
# locations, the env-overridable knobs, the container ENVIRONMENT CONTRACT (the
# injected container script and its -e list) and main(). Each helper concern
# lives in its own module:
#
#   config.sh    input validation + DEFCONFIG vs CONFIG-FILE resolution
#   checkout.sh  pinned fetch: bounded retry, pin assertion, publish
#   builder.sh   builder container + the `make -j` memory preflight
#   package.sh   built-.deb identity and four-axis validation
#
# EXPLICIT and ORDERED, never a glob (the customize/postinst-lib.sh rule): a
# module lost or never wired up must fail HERE, at source time, not halfway
# through a real build as `command not found`. The order is stage order, so a
# static test that reads this stage by TEXT can concatenate entry + modules and
# still assert ordering.
# ---------------------------------------------------------------------------
KERNEL_LIB_DIR="${HERE}/kernel"
# shellcheck source=kernel/config.sh
source "${KERNEL_LIB_DIR}/config.sh"
# shellcheck source=kernel/checkout.sh
source "${KERNEL_LIB_DIR}/checkout.sh"
# shellcheck source=kernel/builder.sh
source "${KERNEL_LIB_DIR}/builder.sh"
# shellcheck source=kernel/package.sh
source "${KERNEL_LIB_DIR}/package.sh"

usage() {
  cat >&2 <<EOF
Usage: build-kernel.sh --board <board> --out <dir> [--ccache-dir <dir>]

Builds the manifest-pinned kernel from source and stages exactly one
linux-image-* .deb into <dir>. Requires a resolved kernel_source: block in the
environment (see the header of this file).

Env:
  DRY_RUN=1                      plan only; no network, container or build
  CERALIVE_KERNEL_BUILD_JOBS     make -j; wins unconditionally
                                 (default: min(nproc, MemAvailable / 2 GiB),
                                 floor 1, ceiling nproc)
  CERALIVE_RESOURCE_MEMINFO_FILE meminfo read for that derivation
                                 (default: /proc/meminfo)
  CERALIVE_KERNEL_GIT_ATTEMPTS   attempts per pinned fetch (default: 3). A pin
                                 MISMATCH is never one of them -- it fails on
                                 the spot.
  CERALIVE_KERNEL_GIT_TIMEOUT    per-attempt timeout(1) seconds (default: 1800)
  CERALIVE_KERNEL_GIT_BACKOFF    seconds x attempt number between retries
                                 (default: 5)
  CERALIVE_KERNEL_BUILDER_IMAGE  builder image tag (default: ceralive-kernel-builder)
  CERALIVE_KERNEL_PATCHES_LOCAL_REPO
                                 BENCH ONLY. Absolute path to a local clone of
                                 the patches repo, fetched instead of
                                 kernel_source.patches_git_url. It is a MIRROR
                                 override, not a pin override: patches_commit
                                 still selects the content and is still asserted
                                 after checkout, so this cannot build different
                                 patches -- only obtain the same immutable SHA
                                 from somewhere the manifest URL cannot serve it
                                 yet (an unpushed commit). Never set it on a
                                 release path.
  CERALIVE_KERNEL_SRC_MIRROR     persistent bare mirror of the pinned kernel
                                 source: auto (default -- use one that exists,
                                 never create it), 1 (create + use), 0 (off).
                                 A mirror that carries the pinned commit is
                                 cloned locally with NO network at all; one that
                                 does not is a cache miss, never a different
                                 build.
  CERALIVE_KERNEL_SRC_MIRROR_DIR mirror location (default:
                                 ${CERALIVE_REL_KERNEL_SRC_MIRROR_DIR})
  CERALIVE_KERNEL_SRC_MIRROR_LOCK_TIMEOUT
                                 seconds to wait for the per-mirror flock
                                 (default: 3600). Boards build concurrently and
                                 share one mirror, so the lock is what keeps two
                                 fetches from corrupting one object store.
EOF
}

main() {
  local board="" out_dir="" ccache_dir=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --board)      board="${2:-}"; shift 2 ;;
      --out)        out_dir="${2:-}"; shift 2 ;;
      --ccache-dir) ccache_dir="${2:-}"; shift 2 ;;
      -h|--help)    usage; exit 0 ;;
      *) usage; die "unknown argument: $1" ;;
    esac
  done
  [[ -n "${board}" ]]   || { usage; die "--board is required"; }
  [[ -n "${out_dir}" ]] || { usage; die "--out is required"; }

  local git_url="${KERNEL_SOURCE_GIT_URL:-}"
  local tag="${KERNEL_SOURCE_TAG:-}"
  local commit="${KERNEL_SOURCE_COMMIT:-}"
  local patches_url="${KERNEL_SOURCE_PATCHES_GIT_URL:-}"
  local patches_commit="${KERNEL_SOURCE_PATCHES_COMMIT:-}"
  local patches_series="${KERNEL_SOURCE_PATCHES_SERIES:-}"
  local defconfig_base="${KERNEL_SOURCE_DEFCONFIG_BASE:-}"
  local fragment_rel="${KERNEL_SOURCE_DEFCONFIG_FRAGMENT:-}"
  local fragments_rel="${KERNEL_SOURCE_DEFCONFIG_FRAGMENTS:-}"
  local config_git_url="${KERNEL_SOURCE_CONFIG_GIT_URL:-}"
  local config_commit="${KERNEL_SOURCE_CONFIG_COMMIT:-}"
  local config_path="${KERNEL_SOURCE_CONFIG_PATH:-}"
  local absent_rel="${KERNEL_SOURCE_CONFIG_ABSENT_SYMBOLS:-}"
  local builder_image="${KERNEL_SOURCE_BUILDER_IMAGE:-}"
  local local_version="${KERNEL_SOURCE_LOCAL_VERSION:-}"
  local kernel_release="${KERNEL_SOURCE_KERNEL_RELEASE:-}"
  local package_version="${KERNEL_SOURCE_PACKAGE_VERSION:-}"
  local dtb_deb_dir="${KERNEL_SOURCE_DTB_DEB_DIR:-}"
  local arch="${ARCH:-}"
  local dtb_name="${DTB_NAME:-}"
  local local_patches="${CERALIVE_KERNEL_PATCHES_LOCAL_REPO:-}"

  # These four are declared HERE and assigned by the kernel/ modules through bash
  # dynamic scoping (the lib/stages/ contract). They look unused in this frame and
  # must not be "cleaned up".
  local config_mode="" config_desc="" absent_list=""
  local kernel_pkg=""
  local -a fragments=() fragments_rel_list=()

  validate_kernel_source_inputs
  resolve_kernel_config_mode
  resolve_kernel_package_name

  local dtb_path="${dtb_deb_dir%/}/${dtb_name}"
  local epoch="${SOURCE_DATE_EPOCH:-0}"

  KERNEL_BUILD_JOBS="$(derive_kernel_build_jobs)"

  log_info "=== kernel-build-from-source: board='${board}' ==="
  log_info "  kernel      ${git_url} tag=${tag:-<none: commit-only source>} commit=${commit}"
  log_info "  patches     ${patches_url} commit=${patches_commit} series=${patches_series}"
  log_info "  config      ${config_mode}: ${config_desc}"
  log_info "  builder     ${builder_image}"
  log_info "  release     ${kernel_release} (LOCALVERSION=${local_version})"
  log_info "  package     ${kernel_pkg}=${package_version}/${arch}"
  log_info "  board DTB   ${dtb_path}"

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    if [[ -n "${tag}" ]]; then
      log_info "DRY-RUN would run: git clone --branch ${tag} ${git_url} && git rev-parse HEAD == ${commit}"
    else
      log_info "DRY-RUN would run: git fetch --depth 1 ${git_url} ${commit} && git rev-parse HEAD == ${commit} (commit-only source: the pinned branch publishes no tag)"
    fi
    log_info "DRY-RUN would run: git fetch ${patches_url} ${patches_commit} && git am \$(series ${patches_series})"
    log_info "DRY-RUN would run: <runtime> build --build-arg BASE_IMAGE=${builder_image} -t $(resolve_kernel_builder_tag "${builder_image}") -f ${KERNEL_BUILDER_DOCKERFILE}"
    if [[ "${config_mode}" == "config-file" ]]; then
      log_info "DRY-RUN would run: git fetch --depth 1 ${config_git_url} ${config_commit} && cp ${config_path} .config (full config, no defconfig target)"
      log_info "DRY-RUN would run: verify-kernel-config.sh ${config_path} .config ${absent_rel} (config-survival gate, after olddefconfig)"
    else
      log_info "DRY-RUN would run: make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- ${defconfig_base} && scripts/kconfig/merge_config.sh -m .config ${fragments_rel_list[*]} (merged in this order)"
      log_info "DRY-RUN would run: verify-kernel-config.sh ${fragments_rel_list[*]} .config (fragment-survival gate, after olddefconfig)"
    fi
    log_info "DRY-RUN would run: make -j${KERNEL_BUILD_JOBS} ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION=${local_version} KDEB_PKGVERSION=${package_version} KBUILD_BUILD_TIMESTAMP=@${epoch} bindeb-pkg"
    log_info "DRY-RUN would stage: ${kernel_pkg}_${package_version}_${arch}.deb -> ${out_dir} (linux-headers-*/linux-libc-dev discarded)"
    log_info "DRY-RUN fetch policy: each pinned fetch runs under timeout ${KERNEL_GIT_TIMEOUT}s, up to ${KERNEL_GIT_ATTEMPTS} attempt(s) in a private attempt dir; a pin mismatch is NEVER retried"
    log_info "DRY-RUN source mirror: CERALIVE_KERNEL_SRC_MIRROR=$(kernel_src_mirror_mode), mirror dir $(kernel_src_mirror_dir) (a mirror holding ${commit} is cloned locally with no network; the patch series and config are always fetched fresh)"
    log_success "=== DRY-RUN complete: kernel-build plan emitted; no network, container or build touched ==="
    return 0
  fi

  require_cmd ar
  require_cmd tar

  local runtime
  runtime="$(select_container_runtime)"
  KERNEL_BUILDER_IMAGE_TAG="$(resolve_kernel_builder_tag "${builder_image}")"
  ensure_kernel_builder_image "${runtime}" "${builder_image}" "${KERNEL_BUILDER_IMAGE_TAG}"

  local work
  work="$(mktemp -d)"
  # shellcheck disable=SC2064  # expand $work now: the trap must survive the local going out of scope
  trap "rm -rf '${work}'" EXIT
  install -d -m 0755 "${work}/out" "${out_dir}"

  ccache_dir="${ccache_dir:-${PIPELINE_DIR}/${CERALIVE_REL_KERNEL_CCACHE_DIR}}"
  install -d -m 0755 "${ccache_dir}"
  log_info "ccache: ${ccache_dir}"

  # The persistent kernel-source mirror, prepared (and locked) HOST-side, then
  # mounted READ-ONLY so the container can only read it. See lib/kernel/checkout.sh.
  local -a mirror_mount=()
  local mirror_container=""
  if kernel_src_mirror_prepare "${git_url}" "${commit}"; then
    mirror_mount=(-v "${KERNEL_SRC_MIRROR_PATH}:/src/mirror.git:ro")
    mirror_container="/src/mirror.git"
  else
    log_info "kernel source: no mirror (${KERNEL_SRC_MIRROR_BASIS}) — fetching from ${git_url}"
  fi

  # BENCH ONLY: fetch the SAME pinned commit from a local clone. The manifest
  # keeps its real https URL and its real SHA; only the transport moves, and the
  # post-checkout `have_p != PATCHES_COMMIT` assertion below still proves the
  # exact commit was obtained.
  local -a patches_mount=()
  local patches_fetch_url="${patches_url}"
  if [[ -n "${local_patches}" ]]; then
    patches_mount=(-v "${local_patches}:/in/patches-src:ro")
    patches_fetch_url="file:///in/patches-src"
    log_warn "BENCH: patch series fetched from local clone ${local_patches} instead of ${patches_url}"
    log_warn "BENCH: commit ${patches_commit} is still asserted after checkout; do NOT use this on a release path"
  fi

  # The generated gitconfig is not optional and cannot be replaced by -c or
  # GIT_CONFIG_COUNT: git deliberately honours safe.directory ONLY from the
  # system or global config, and every host tree mounted here is owned by the
  # invoking user while git in the container runs as root. Both the bench patch
  # clone and the source mirror need an entry, so the file is built from whatever
  # is actually mounted rather than being owned by either feature.
  local -a git_safe_dirs=() patches_env=()
  [[ -n "${local_patches}" ]] && git_safe_dirs+=(/in/patches-src /in/patches-src/.git)
  [[ -n "${mirror_container}" ]] && git_safe_dirs+=("${mirror_container}")
  if (( ${#git_safe_dirs[@]} > 0 )); then
    {
      printf '[safe]\n'
      printf '\tdirectory = %s\n' "${git_safe_dirs[@]}"
    } >"${work}/gitconfig"
    patches_mount+=(-v "${work}/gitconfig:/in/gitconfig:ro")
    patches_env=(-e "GIT_CONFIG_GLOBAL=/in/gitconfig")
  fi

  # In config-file mode there IS no repo-local fragment, so `fragments` is empty
  # and this loop adds no mount at all; a `-v :/in/fragment.config` with an empty
  # source is a runtime error, not a no-op.
  # Fragment N>1 is mounted as /in/fragment-N.config; the FIRST keeps the historical
  # /in/fragment.config so a single-fragment build is byte-identical to before the
  # ordered-list key existed. FRAGMENT_LIST carries the container-side paths in
  # merge order, and it is the ONLY thing the container branches on.
  local -a fragment_mount=()
  local fragment_list="" idx=0 frag_path
  for frag_path in "${fragments[@]}"; do
    idx=$(( idx + 1 ))
    local container_path="/in/fragment.config"
    (( idx > 1 )) && container_path="/in/fragment-${idx}.config"
    fragment_mount+=(-v "${frag_path}:${container_path}:ro")
    fragment_list="${fragment_list:+${fragment_list} }${container_path}"
  done
  local -a absent_mount=()
  [[ -n "${absent_list}" ]] && absent_mount=(-v "${absent_list}:/in/allow-absent.list:ro")

  # fetch_pinned_tree is defined host-side and INJECTED rather than written out a
  # second time inline, so the retry/verify/publish loop the real build runs is
  # byte-identical to the one the test suite drives against a stubbed git.
  local container_script
  container_script="$(declare -f fetch_pinned_tree_once fetch_pinned_tree)
"'
      export ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
      export KBUILD_BUILD_TIMESTAMP="@${SOURCE_DATE_EPOCH}"
      export KBUILD_BUILD_USER=ceralive KBUILD_BUILD_HOST=ceralive-builder

      # KERNEL_SRC_MIRROR is the ONLY fetch here that gets one: the patch series
      # and the kernel config below deliberately stay fresh network fetches.
      if [ -n "${KERNEL_TAG}" ]; then
        echo "== cloning ${KERNEL_GIT_URL} at ${KERNEL_TAG}"
        fetch_pinned_tree /src/linux "${KERNEL_GIT_URL}" "${KERNEL_TAG}" "${KERNEL_COMMIT}" "kernel source" "${KERNEL_SRC_MIRROR}"
      else
        echo "== fetching ${KERNEL_GIT_URL} at ${KERNEL_COMMIT} (no tag on the pinned branch)"
        fetch_pinned_tree /src/linux "${KERNEL_GIT_URL}" "" "${KERNEL_COMMIT}" "kernel source" "${KERNEL_SRC_MIRROR}"
      fi
      cd /src/linux
      # Re-asserted on the PUBLISHED path: fetch_pinned_tree gates the rename on
      # this same equality, so a mismatch here means the rename landed the wrong
      # tree, which is a different bug from a moved pin and must still be fatal.
      have="$(git rev-parse HEAD)"
      if [ "${have}" != "${KERNEL_COMMIT}" ]; then
        echo "FATAL: kernel source checked out ${have}, pinned commit is ${KERNEL_COMMIT} — refusing to build different source under the same pin" >&2
        exit 1
      fi
      git config user.email kernel-build@ceralive.tv
      git config user.name  "CeraLive kernel build"

      echo "== fetching patch series at ${PATCHES_COMMIT}"
      fetch_pinned_tree /src/patches "${PATCHES_GIT_URL}" "" "${PATCHES_COMMIT}" "patches repo"
      have_p="$(git -C /src/patches rev-parse HEAD)"
      if [ "${have_p}" != "${PATCHES_COMMIT}" ]; then
        echo "FATAL: patches repo checked out ${have_p}, pinned ${PATCHES_COMMIT}" >&2
        exit 1
      fi

      series_dir="$(dirname "/src/patches/${PATCHES_SERIES}")"
      applied=0
      while read -r patch; do
        case "${patch}" in ""|\#*) continue ;; esac
        echo "== git am ${patch}"
        git am --keep-non-patch "${series_dir}/${patch}"
        applied=$((applied + 1))
      done < "/src/patches/${PATCHES_SERIES}"
      if [ "${applied}" -eq 0 ]; then
        echo "FATAL: patch series ${PATCHES_SERIES} applied 0 patches — an empty series means the CeraLive RK3588 changes are silently absent" >&2
        exit 1
      fi
      echo "== applied ${applied} patch(es)"

      # Both config modes converge on ONE olddefconfig/syncconfig/verify sequence;
      # only the way the starting .config is obtained differs. `declared_config`
      # is the expectation set the survival gate is run against.
      if [ -n "${CONFIG_GIT_URL}" ]; then
        echo "== config: full .config ${CONFIG_PATH} @ ${CONFIG_COMMIT}"
        fetch_pinned_tree /src/kconfig "${CONFIG_GIT_URL}" "" "${CONFIG_COMMIT}" "config repo"
        have_c="$(git -C /src/kconfig rev-parse HEAD)"
        if [ "${have_c}" != "${CONFIG_COMMIT}" ]; then
          echo "FATAL: config repo checked out ${have_c}, pinned ${CONFIG_COMMIT}" >&2
          exit 1
        fi
        if [ ! -f "/src/kconfig/${CONFIG_PATH}" ]; then
          echo "FATAL: ${CONFIG_PATH} does not exist at ${CONFIG_COMMIT} in ${CONFIG_GIT_URL}" >&2
          exit 1
        fi
        declared_config=/src/declared.config
        cp "/src/kconfig/${CONFIG_PATH}" "${declared_config}"
        cp "${declared_config}" .config
      else
        echo "== config: ${DEFCONFIG_BASE} + fragment(s) ${FRAGMENT_LIST}"
        declared_config=/in/fragment.config
        make -j"${BUILD_JOBS}" "${DEFCONFIG_BASE}"
        for frag in ${FRAGMENT_LIST}; do
          echo "== merging ${frag}"
          ./scripts/kconfig/merge_config.sh -m .config "${frag}"
        done
        case "${FRAGMENT_LIST}" in
        *" "*)
          # With more than one fragment the survival gate has to be run against
          # everything that was declared, not just the first file — otherwise a
          # symbol olddefconfig drops from a later fragment passes unnoticed,
          # which is the exact failure mode this gate exists for.
          declared_config=/src/declared-fragments.config
          : >"${declared_config}"
          for frag in ${FRAGMENT_LIST}; do
            cat "${frag}" >>"${declared_config}"
          done
          ;;
        esac
      fi
      make olddefconfig
      # `kernelrelease` is in the kernel no-sync-config-targets list, so it reads a
      # STALE include/config/auto.conf. Without this, setlocalversion still sees the
      # defconfig CONFIG_LOCALVERSION_AUTO=y and appends the git-describe suffix.
      make syncconfig

      # Neither merge_config.sh -m nor a straight `cp` reports a symbol the
      # following olddefconfig DROPS for an unmet visibility condition — which is
      # how 7.1.5 shipped with no rtw89 WiFi driver, and how a config-file build
      # would silently lose e.g. BTF when its host tool is absent. Runs before
      # bindeb-pkg so the failure is fast.
      echo "== verifying the declared config survived olddefconfig"
      bash /in/verify-kernel-config.sh "${declared_config}" .config ${CONFIG_ALLOW_ABSENT}

      # Retain the exact post-olddefconfig answer, rather than asking a later
      # audit to reconstruct it from the fragment and toolchain.
      cp .config /out/resolved.config

      release="$(make -s kernelrelease LOCALVERSION="${LOCAL_VERSION}")"
      if [ "${release}" != "${KERNEL_RELEASE}" ]; then
        echo "FATAL: kernelrelease is ${release}, manifest declares ${KERNEL_RELEASE} — the source version moved under the pin, or LOCALVERSION drifted" >&2
        exit 1
      fi

      echo "== make bindeb-pkg (-j${BUILD_JOBS})"
      make -j"${BUILD_JOBS}" \
        LOCALVERSION="${LOCAL_VERSION}" \
        KDEB_PKGVERSION="${PACKAGE_VERSION}" \
        bindeb-pkg

      # Inventory the modules that this compile actually produced. Paths are
      # source-tree-relative and sorted so the artifact is stable and diffable.
      find . -type f -name "*.ko" -printf "%P\n" | LC_ALL=C sort > /out/built-modules.txt
      if [ ! -s /out/built-modules.txt ]; then
        echo "FATAL: kernel build produced no modules inventory" >&2
        exit 1
      fi

      # bindeb-pkg writes its .debs into the parent of the source tree.
      cp /src/"${KERNEL_PACKAGE}"_*.deb /out/
'

  # The whole pinned-input dance runs INSIDE the container so the git, make and
  # toolchain versions are the pinned ones end to end — a host-side clone would
  # reintroduce exactly the host dependence the container exists to remove.
  "${runtime}" run --rm \
    -e "KERNEL_GIT_URL=${git_url}" \
    -e "KERNEL_TAG=${tag}" \
    -e "KERNEL_COMMIT=${commit}" \
    -e "KERNEL_SRC_MIRROR=${mirror_container}" \
    -e "PATCHES_GIT_URL=${patches_fetch_url}" \
    -e "PATCHES_COMMIT=${patches_commit}" \
    -e "PATCHES_SERIES=${patches_series}" \
    -e "DEFCONFIG_BASE=${defconfig_base}" \
    -e "FRAGMENT_LIST=${fragment_list}" \
    -e "CONFIG_GIT_URL=${config_git_url}" \
    -e "CONFIG_COMMIT=${config_commit}" \
    -e "CONFIG_PATH=${config_path}" \
    -e "CONFIG_ALLOW_ABSENT=${absent_list:+/in/allow-absent.list}" \
    -e "LOCAL_VERSION=${local_version}" \
    -e "KERNEL_RELEASE=${kernel_release}" \
    -e "PACKAGE_VERSION=${package_version}" \
    -e "KERNEL_PACKAGE=${kernel_pkg}" \
    -e "BUILD_JOBS=${KERNEL_BUILD_JOBS}" \
    -e "CERALIVE_KERNEL_GIT_ATTEMPTS=${KERNEL_GIT_ATTEMPTS}" \
    -e "CERALIVE_KERNEL_GIT_TIMEOUT=${KERNEL_GIT_TIMEOUT}" \
    -e "CERALIVE_KERNEL_GIT_BACKOFF=${KERNEL_GIT_BACKOFF}" \
    -e "SOURCE_DATE_EPOCH=${epoch}" \
    "${mirror_mount[@]}" \
    "${patches_mount[@]}" \
    "${patches_env[@]}" \
    "${fragment_mount[@]}" \
    "${absent_mount[@]}" \
    -v "${KERNEL_CONFIG_VERIFIER_SH:-${HERE}/verify-kernel-config.sh}:/in/verify-kernel-config.sh:ro" \
    -v "${work}/out:/out" \
    -v "${ccache_dir}:/ccache" \
    "${KERNEL_BUILDER_IMAGE_TAG}" \
    bash -euo pipefail -c "${container_script}" \
    || die "kernel build failed for board '${board}' (see the container log above)"

  shopt -s nullglob
  local built=("${work}/out/${kernel_pkg}"_*.deb)
  shopt -u nullglob
  (( ${#built[@]} == 1 )) \
    || die "kernel build produced ${#built[@]} '${kernel_pkg}' .deb(s); the output contract is exactly one linux-image deb"

  validate_built_kernel_deb "${built[0]}" "${kernel_pkg}" "${package_version}" "${arch}" "${dtb_path}"

  "${MKOSI_PACKAGE_STAGING_SH:-${HERE}/stage-mkosi-package.sh}" "${built[0]}" "${out_dir}"
  install -m 0644 "${work}/out/resolved.config" "${out_dir}/resolved.config"
  install -m 0644 "${work}/out/built-modules.txt" "${out_dir}/built-modules.txt"
  log_success "kernel-build-from-source: staged $(basename "${built[0]}") -> ${out_dir}"
  log_success "kernel-build-from-source: retained resolved.config + built-modules.txt -> ${out_dir}"
}

# Only run main when executed directly; sourcing (tests) gets the functions only.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
