#!/usr/bin/env bash
#
# build-kernel.sh — kernel-build-from-source stage for the CeraLive v2 pipeline.
#
# OPT-IN ONLY. This stage runs when, and only when, the resolved manifest carries
# a `kernel_source:` block — which today happens only under an explicitly
# selected family variant (`v2/build <board> --variant edge`). The production
# vendor path never reaches this file.
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

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${HERE}/common.sh"

V2_DIR="$(cd "${HERE}/.." && pwd)"
KERNEL_BUILDER_DOCKERFILE="${V2_DIR}/ci/Dockerfile.kernel"
KERNEL_BUILDER_IMAGE_TAG=""
# Bounded so a hung clone cannot wedge a build host indefinitely.
KERNEL_BUILD_JOBS="${CERALIVE_KERNEL_BUILD_JOBS:-$(nproc 2>/dev/null || echo 4)}"

usage() {
  cat >&2 <<EOF
Usage: build-kernel.sh --board <board> --out <dir> [--ccache-dir <dir>]

Builds the manifest-pinned kernel from source and stages exactly one
linux-image-* .deb into <dir>. Requires a resolved kernel_source: block in the
environment (see the header of this file).

Env:
  DRY_RUN=1                      plan only; no network, container or build
  CERALIVE_KERNEL_BUILD_JOBS     make -j (default: nproc)
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
EOF
}

require_kernel_source_field() {
  local name="$1" val="$2"
  [[ -n "${val}" ]] \
    || die "kernel_source did not resolve required field '${name}' — refusing to build a kernel from a half-specified pin"
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

# ---------------------------------------------------------------------------
# deb_control_field <deb> <field> — read one Debian control field without dpkg
# (the host may be non-Debian). Mirrors orchestrate.sh::deb_pkg_name.
# ---------------------------------------------------------------------------
deb_control_field() {
  local deb="$1" field="$2" tmp value=""
  tmp="$(mktemp -d)"
  if ar p "${deb}" control.tar.gz 2>/dev/null | tar -xzO ./control 2>/dev/null >"${tmp}/control"; then
    :
  elif ar p "${deb}" control.tar.xz 2>/dev/null | tar -xJO ./control 2>/dev/null >"${tmp}/control"; then
    :
  elif ar p "${deb}" control.tar.zst 2>/dev/null | tar --zstd -xO ./control 2>/dev/null >"${tmp}/control"; then
    :
  fi
  if [[ -s "${tmp}/control" ]]; then
    value="$(awk -F': ' -v f="${field}" '$0 ~ "^" f ":" {print $2; exit}' "${tmp}/control")"
  fi
  rm -rf "${tmp}"
  printf '%s' "${value}"
}

# ---------------------------------------------------------------------------
# deb_data_list <deb> — emit the data member's tar listing, one path per line.
#
# The member is discovered from `ar t` rather than guessed, so a dpkg-deb that
# switches compressor (trixie ships .xz today, .zst is the way the wind blows)
# does not silently produce an empty listing.
# ---------------------------------------------------------------------------
deb_data_list() {
  local deb="$1" members member="" m
  members="$(ar t "${deb}" 2>/dev/null)" || return 1
  for m in ${members}; do
    case "${m}" in data.tar.*) member="${m}"; break ;; esac
  done
  [[ -n "${member}" ]] || return 1
  case "${member}" in
    *.zst)  ar p "${deb}" "${member}" 2>/dev/null | tar --zstd -t 2>/dev/null ;;
    *.xz)   ar p "${deb}" "${member}" 2>/dev/null | tar -Jt     2>/dev/null ;;
    *.gz)   ar p "${deb}" "${member}" 2>/dev/null | tar -zt     2>/dev/null ;;
    *.bz2)  ar p "${deb}" "${member}" 2>/dev/null | tar -jt     2>/dev/null ;;
    *.lzma) ar p "${deb}" "${member}" 2>/dev/null | tar --lzma -t 2>/dev/null ;;
    data.tar) ar p "${deb}" "${member}" 2>/dev/null | tar -t    2>/dev/null ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# deb_lists_path <deb> <path> — true when the .deb data archive contains <path>.
# Used to prove the DTB the board manifest names is really inside the built
# kernel package, so the platform-layer install mapping is machine-verified
# rather than merely declared.
#
# The listing is materialised BEFORE it is searched. Piping `tar -t` straight
# into `grep -q` looks equivalent and is not: grep exits at the first match,
# tar dies of SIGPIPE, and under this file's `set -o pipefail` the pipeline
# reports failure — so a path that IS present reads as absent, every time, for
# every board.
# ---------------------------------------------------------------------------
deb_lists_path() {
  local deb="$1" want="$2" listing
  listing="$(deb_data_list "${deb}")" || return 1
  grep -Fqx -e "./${want#/}" -e "${want}" <<<"${listing}"
}

# ---------------------------------------------------------------------------
# validate_built_kernel_deb — assert the produced .deb is EXACTLY what the
# manifest declared, on all four axes the rest of the pipeline keys on:
# package name, Debian version, architecture, and the in-deb DTB path. Any
# mismatch is fatal: the orchestrator's package-name replacement and the boot
# script's fdtfile lookup both depend on these being true, and a mismatch here
# would surface much later as an unbootable image.
# ---------------------------------------------------------------------------
validate_built_kernel_deb() {
  local deb="$1" want_pkg="$2" want_version="$3" want_arch="$4" dtb_path="$5"
  local got_pkg got_version got_arch
  got_pkg="$(deb_control_field "${deb}" Package)"
  got_version="$(deb_control_field "${deb}" Version)"
  got_arch="$(deb_control_field "${deb}" Architecture)"

  [[ "${got_pkg}" == "${want_pkg}" ]] \
    || die "built kernel .deb Package is '${got_pkg:-<unreadable>}' but the manifest declares '${want_pkg}' — the resolver/orchestrator package-name replacement would target a package that does not exist"
  [[ "${got_version}" == "${want_version}" ]] \
    || die "built kernel .deb Version is '${got_version:-<unreadable>}' but the manifest declares kernel_source.package_version '${want_version}'"
  [[ "${got_arch}" == "${want_arch}" ]] \
    || die "built kernel .deb Architecture is '${got_arch:-<unreadable>}' but the resolved family arch is '${want_arch}'"
  log_success "built kernel .deb control identity verified: ${got_pkg}=${got_version}/${got_arch}"

  if ! deb_lists_path "${deb}" "${dtb_path}"; then
    log_error "built kernel .deb does not contain the board DTB at ${dtb_path}"
    log_error "the platform-layer install mapping (kernel_source.dtb_deb_dir + the board's dtb_name) is what makes a source-built kernel satisfy the same DTB expectation an Armbian linux-dtb-* package would; it cannot be satisfied by a DTB that is not there."
    log_error "mainline and the Armbian vendor BSP do NOT always agree on RK3588 DTB filenames; a board whose name differs per tree declares the mainline spelling in variant_overrides.edge.dtb_name. DTBs actually present in the built package:"
    deb_data_list "${deb}" | grep -F "$(dirname "${dtb_path}")/" >&2 || true
    die "built kernel .deb is missing ${dtb_path}"
  fi
  log_success "board DTB present inside the built kernel .deb: ${dtb_path}"
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

  require_kernel_source_field git_url "${git_url}"
  require_kernel_source_field commit "${commit}"
  require_kernel_source_field patches_git_url "${patches_url}"
  require_kernel_source_field patches_commit "${patches_commit}"
  require_kernel_source_field patches_series "${patches_series}"
  require_kernel_source_field builder_image "${builder_image}"
  require_kernel_source_field local_version "${local_version}"
  require_kernel_source_field kernel_release "${kernel_release}"
  require_kernel_source_field package_version "${package_version}"
  require_kernel_source_field dtb_deb_dir "${dtb_deb_dir}"
  require_kernel_source_field ARCH "${arch}"
  require_kernel_source_field DTB_NAME "${dtb_name}"

  # A floating patches reference would make the built kernel unreproducible
  # while still LOOKING pinned — the exact failure mode the schema pattern and
  # this assertion exist to make impossible.
  [[ "${commit}" =~ ^[0-9a-f]{40}$ ]] \
    || die "kernel_source.commit must be an exact 40-character SHA (got '${commit}')"
  [[ "${patches_commit}" =~ ^[0-9a-f]{40}$ ]] \
    || die "kernel_source.patches_commit must be an exact 40-character SHA, never a branch or tag (got '${patches_commit}')"

  # Validated here rather than at mount time so a mistyped bench path fails
  # before any container work, like every other input assertion in this block.
  local local_patches="${CERALIVE_KERNEL_PATCHES_LOCAL_REPO:-}"
  [[ -z "${local_patches}" || ( "${local_patches}" == /* && -d "${local_patches}/.git" ) ]] \
    || die "CERALIVE_KERNEL_PATCHES_LOCAL_REPO must be an absolute path to a git clone (got '${local_patches}')"

  [[ "${arch}" == "arm64" ]] \
    || die "kernel-build-from-source is wired for arm64 only (resolved arch '${arch}'); an x86 family has no kernel_source block and must never reach this stage"

  # The schema already enforces exactly-one-of, but a half-specified config is
  # the one mistake that would still BUILD — producing a kernel whose driver set
  # nobody chose — so it is re-asserted here rather than trusted.
  local config_mode="" config_desc="" fragment="" absent_list=""
  if [[ -n "${config_git_url}${config_commit}${config_path}" ]]; then
    config_mode="config-file"
    require_kernel_source_field config_git_url "${config_git_url}"
    require_kernel_source_field config_commit "${config_commit}"
    require_kernel_source_field config_path "${config_path}"
    [[ -z "${defconfig_base}" && -z "${fragment_rel}" ]] \
      || die "kernel_source declares BOTH config-file mode (config_git_url/config_commit/config_path) and defconfig mode (defconfig_base/defconfig_fragment); exactly one config source may be declared"
    [[ "${config_commit}" =~ ^[0-9a-f]{40}$ ]] \
      || die "kernel_source.config_commit must be an exact 40-character SHA, never a branch or tag (got '${config_commit}')"
    config_desc="${config_path} @ ${config_commit} (${config_git_url})"
    if [[ -n "${absent_rel}" ]]; then
      absent_list="${V2_DIR}/${absent_rel}"
      [[ -f "${absent_list}" ]] \
        || die "config_absent_symbols list not found: ${absent_list} (kernel_source.config_absent_symbols='${absent_rel}', resolved against ${V2_DIR})"
      config_desc="${config_desc} [allow-absent: ${absent_rel}]"
    fi
  else
    config_mode="defconfig"
    require_kernel_source_field defconfig_base "${defconfig_base}"
    require_kernel_source_field defconfig_fragment "${fragment_rel}"
    [[ -z "${absent_rel}" ]] \
      || die "kernel_source.config_absent_symbols is only meaningful in config-file mode; a repo-local defconfig fragment declares exactly what it means and has no upstream-injected symbols to except"
    fragment="${V2_DIR}/${fragment_rel}"
    [[ -f "${fragment}" ]] \
      || die "defconfig fragment not found: ${fragment} (kernel_source.defconfig_fragment='${fragment_rel}', resolved against ${V2_DIR})"
    config_desc="${defconfig_base} + ${fragment_rel}"
  fi

  local kernel_pkg="${KERNEL_PACKAGES:-}"
  # The manifest's kernel_packages under a kernel_source variant is the single
  # BUILT package name; more than one has no meaning here (bindeb-pkg produces
  # one linux-image deb) and would leave the second name unsatisfiable.
  [[ "$(wc -w <<<"${kernel_pkg}")" == "1" ]] \
    || die "a kernel_source variant must declare exactly ONE kernel_packages entry (the built linux-image deb); got '${kernel_pkg}'"
  kernel_pkg="$(tr -d '[:space:]' <<<"${kernel_pkg}")"

  local dtb_path="${dtb_deb_dir%/}/${dtb_name}"
  local epoch="${SOURCE_DATE_EPOCH:-0}"

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
      log_info "DRY-RUN would run: make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- ${defconfig_base} && scripts/kconfig/merge_config.sh -m .config ${fragment_rel}"
      log_info "DRY-RUN would run: verify-kernel-config.sh ${fragment_rel} .config (fragment-survival gate, after olddefconfig)"
    fi
    log_info "DRY-RUN would run: make -j${KERNEL_BUILD_JOBS} ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION=${local_version} KDEB_PKGVERSION=${package_version} KBUILD_BUILD_TIMESTAMP=@${epoch} bindeb-pkg"
    log_info "DRY-RUN would stage: ${kernel_pkg}_${package_version}_${arch}.deb -> ${out_dir} (linux-headers-*/linux-libc-dev discarded)"
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

  ccache_dir="${ccache_dir:-${V2_DIR}/mkosi/cache/kernel-ccache}"
  install -d -m 0755 "${ccache_dir}"
  log_info "ccache: ${ccache_dir}"

  # BENCH ONLY: fetch the SAME pinned commit from a local clone. The manifest
  # keeps its real https URL and its real SHA; only the transport moves, and the
  # post-checkout `have_p != PATCHES_COMMIT` assertion below still proves the
  # exact commit was obtained.
  #
  # The generated gitconfig is not optional and cannot be replaced by -c or
  # GIT_CONFIG_COUNT: git deliberately honours safe.directory ONLY from the
  # system or global config, and the bind-mounted clone is owned by the invoking
  # user while git in the container runs as root.
  local -a patches_mount=() patches_env=()
  local patches_fetch_url="${patches_url}"
  if [[ -n "${local_patches}" ]]; then
    cat >"${work}/gitconfig" <<-EOF
	[safe]
		directory = /in/patches-src
		directory = /in/patches-src/.git
	EOF
    patches_mount=(
      -v "${local_patches}:/in/patches-src:ro"
      -v "${work}/gitconfig:/in/gitconfig:ro"
    )
    patches_env=(-e "GIT_CONFIG_GLOBAL=/in/gitconfig")
    patches_fetch_url="file:///in/patches-src"
    log_warn "BENCH: patch series fetched from local clone ${local_patches} instead of ${patches_url}"
    log_warn "BENCH: commit ${patches_commit} is still asserted after checkout; do NOT use this on a release path"
  fi

  # In config-file mode there IS no repo-local fragment, so the mount is added
  # only for defconfig mode; a `-v :/in/fragment.config` with an empty source is
  # a runtime error, not a no-op.
  local -a fragment_mount=()
  [[ -n "${fragment}" ]] && fragment_mount=(-v "${fragment}:/in/fragment.config:ro")
  local -a absent_mount=()
  [[ -n "${absent_list}" ]] && absent_mount=(-v "${absent_list}:/in/allow-absent.list:ro")

  # The whole pinned-input dance runs INSIDE the container so the git, make and
  # toolchain versions are the pinned ones end to end — a host-side clone would
  # reintroduce exactly the host dependence the container exists to remove.
  "${runtime}" run --rm \
    -e "KERNEL_GIT_URL=${git_url}" \
    -e "KERNEL_TAG=${tag}" \
    -e "KERNEL_COMMIT=${commit}" \
    -e "PATCHES_GIT_URL=${patches_fetch_url}" \
    -e "PATCHES_COMMIT=${patches_commit}" \
    -e "PATCHES_SERIES=${patches_series}" \
    -e "DEFCONFIG_BASE=${defconfig_base}" \
    -e "CONFIG_GIT_URL=${config_git_url}" \
    -e "CONFIG_COMMIT=${config_commit}" \
    -e "CONFIG_PATH=${config_path}" \
    -e "CONFIG_ALLOW_ABSENT=${absent_list:+/in/allow-absent.list}" \
    -e "LOCAL_VERSION=${local_version}" \
    -e "KERNEL_RELEASE=${kernel_release}" \
    -e "PACKAGE_VERSION=${package_version}" \
    -e "KERNEL_PACKAGE=${kernel_pkg}" \
    -e "BUILD_JOBS=${KERNEL_BUILD_JOBS}" \
    -e "SOURCE_DATE_EPOCH=${epoch}" \
    "${patches_mount[@]}" \
    "${patches_env[@]}" \
    "${fragment_mount[@]}" \
    "${absent_mount[@]}" \
    -v "${KERNEL_CONFIG_VERIFIER_SH:-${HERE}/verify-kernel-config.sh}:/in/verify-kernel-config.sh:ro" \
    -v "${work}/out:/out" \
    -v "${ccache_dir}:/ccache" \
    "${KERNEL_BUILDER_IMAGE_TAG}" \
    bash -euo pipefail -c '
      export ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
      export KBUILD_BUILD_TIMESTAMP="@${SOURCE_DATE_EPOCH}"
      export KBUILD_BUILD_USER=ceralive KBUILD_BUILD_HOST=ceralive-builder

      if [ -n "${KERNEL_TAG}" ]; then
        echo "== cloning ${KERNEL_GIT_URL} at ${KERNEL_TAG}"
        git clone --depth 1 --branch "${KERNEL_TAG}" "${KERNEL_GIT_URL}" /src/linux
        cd /src/linux
      else
        # Commit-only source: the pinned branch publishes no tags, so there is no
        # ref to clone. A server that serves an arbitrary reachable SHA gives the
        # exact tree for one shallow fetch; inventing a tag would be a lie about
        # provenance, and cloning the branch tip would silently build newer source.
        echo "== fetching ${KERNEL_GIT_URL} at ${KERNEL_COMMIT} (no tag on the pinned branch)"
        mkdir -p /src/linux
        git init -q /src/linux
        cd /src/linux
        git remote add origin "${KERNEL_GIT_URL}"
        git fetch --depth 1 origin "${KERNEL_COMMIT}"
        git checkout -q FETCH_HEAD
      fi
      have="$(git rev-parse HEAD)"
      if [ "${have}" != "${KERNEL_COMMIT}" ]; then
        echo "FATAL: kernel source checked out ${have}, pinned commit is ${KERNEL_COMMIT} — refusing to build different source under the same pin" >&2
        exit 1
      fi
      git config user.email kernel-build@ceralive.tv
      git config user.name  "CeraLive kernel build"

      echo "== fetching patch series at ${PATCHES_COMMIT}"
      git init -q /src/patches
      git -C /src/patches fetch --depth 1 "${PATCHES_GIT_URL}" "${PATCHES_COMMIT}"
      git -C /src/patches checkout -q FETCH_HEAD
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
        git init -q /src/kconfig
        git -C /src/kconfig fetch --depth 1 "${CONFIG_GIT_URL}" "${CONFIG_COMMIT}"
        git -C /src/kconfig checkout -q FETCH_HEAD
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
        echo "== config: ${DEFCONFIG_BASE} + fragment"
        declared_config=/in/fragment.config
        make -j"${BUILD_JOBS}" "${DEFCONFIG_BASE}"
        ./scripts/kconfig/merge_config.sh -m .config "${declared_config}"
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

      # bindeb-pkg writes its .debs into the parent of the source tree.
      cp /src/"${KERNEL_PACKAGE}"_*.deb /out/
    ' || die "kernel build failed for board '${board}' (see the container log above)"

  shopt -s nullglob
  local built=("${work}/out/${kernel_pkg}"_*.deb)
  shopt -u nullglob
  (( ${#built[@]} == 1 )) \
    || die "kernel build produced ${#built[@]} '${kernel_pkg}' .deb(s); the output contract is exactly one linux-image deb"

  validate_built_kernel_deb "${built[0]}" "${kernel_pkg}" "${package_version}" "${arch}" "${dtb_path}"

  "${MKOSI_PACKAGE_STAGING_SH:-${HERE}/stage-mkosi-package.sh}" "${built[0]}" "${out_dir}"
  log_success "kernel-build-from-source: staged $(basename "${built[0]}") -> ${out_dir}"
}

# Only run main when executed directly; sourcing (tests) gets the functions only.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
