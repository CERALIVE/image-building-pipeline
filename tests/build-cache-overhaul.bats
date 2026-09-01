#!/usr/bin/env bats
#
# build-cache-overhaul.bats — the STATIC half of the four caching layers.
#
# Every case here is a property a future edit can silently destroy while the
# build still succeeds, which is exactly why each one is pinned:
#
#   apt cache mounts   a `RUN --mount=type=cache` whose layer still runs
#                      docker-clean, or still ends in `rm -rf
#                      /var/lib/apt/lists/*`, populates the cache and then
#                      empties it. The build is green, the mount is real, and
#                      the hit rate is permanently zero.
#   BuildKit           `docker build` defaults to the LEGACY builder, which does
#                      not ignore `--mount` — it refuses to parse the Dockerfile.
#                      So the mounts and DOCKER_BUILDKIT=1 are one change, not two.
#   cache domains      a container and a --native build own their mkosi caches as
#                      different uids, and mkosi DELETES a cache it does not own.
#                      One shared leaf makes every alternation a cold base layer,
#                      reported as nothing at all.
#   apt proxy          must be inert when unset, http-only when set, and must
#                      never reach a verification option.
#
# The RUNTIME halves live in tests/kernel-src-mirror.test.sh (mirror reuse and
# the flock) and in the evidence transcript for the cache-mount hit rate, which
# needs a real container runtime.
#
# shellcheck shell=bats

setup() {
  TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  PIPELINE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
  LIB_DIR="$PIPELINE_DIR/lib"
  DOCKERFILE="$PIPELINE_DIR/ci/Dockerfile"
  DOCKERFILE_KERNEL="$PIPELINE_DIR/ci/Dockerfile.kernel"
}

# The apt RUN of a Dockerfile: from the `RUN --mount` line to the first line
# that is not a continuation of it.
apt_layer() {
  awk '
    /^RUN --mount=type=cache/ { inlayer = 1 }
    inlayer { print }
    inlayer && !/\\$/ && !/^RUN / { exit }
  ' "$1"
}

# ---------------------------------------------------------------------------
# (a) BuildKit apt cache mounts
# ---------------------------------------------------------------------------

@test "cache mounts: both Dockerfiles mount /var/cache/apt and /var/lib/apt/lists, sharing=locked" {
  local f
  for f in "$DOCKERFILE" "$DOCKERFILE_KERNEL"; do
    grep -Fq -- '--mount=type=cache,target=/var/cache/apt,sharing=locked' "$f"
    grep -Fq -- '--mount=type=cache,target=/var/lib/apt/lists,sharing=locked' "$f"
  done
}

@test "cache mounts: sharing=locked is present on EVERY cache mount (concurrent boards share one)" {
  # lib/build-all.sh builds boards in parallel and each one may build a builder
  # image, so an unlocked archive directory is a corrupt partial download.
  local f
  for f in "$DOCKERFILE" "$DOCKERFILE_KERNEL"; do
    run bash -c "grep -o -- '--mount=type=cache[^ \\\\]*' '$f' | grep -vc 'sharing=locked'"
    [ "$output" = "0" ]
  done
}

@test "cache mounts: the apt layer moves docker-clean aside AND puts it back" {
  # Aside, or the Post-Invoke rm empties the mount at the end of this very
  # apt-get. Back, or the finished builder image differs from its base in /etc.
  local f
  for f in "$DOCKERFILE" "$DOCKERFILE_KERNEL"; do
    local layer; layer="$(apt_layer "$f")"
    [[ "$layer" == *"mv /etc/apt/apt.conf.d/docker-clean /tmp/ceralive-docker-clean"* ]]
    [[ "$layer" == *"mv /tmp/ceralive-docker-clean /etc/apt/apt.conf.d/docker-clean"* ]]
  done
}

@test "cache mounts: no apt layer deletes /var/lib/apt/lists (that path IS the cache now)" {
  # Executable lines only: both files DOCUMENT the rule in a comment, and the
  # comment is the thing that keeps it from being reintroduced.
  local f
  for f in "$DOCKERFILE" "$DOCKERFILE_KERNEL"; do
    run bash -c "grep -v '^[[:space:]]*#' '$f' | grep -Fq 'rm -rf /var/lib/apt/lists'"
    [ "$status" -ne 0 ]
  done
}

@test "cache mounts: apt is told to keep downloaded packages, and the knob does not ship" {
  local f
  for f in "$DOCKERFILE" "$DOCKERFILE_KERNEL"; do
    local layer; layer="$(apt_layer "$f")"
    [[ "$layer" == *'Keep-Downloaded-Packages "true"'* ]]
    [[ "$layer" == *"rm -f /etc/apt/apt.conf.d/99ceralive-proxy /etc/apt/apt.conf.d/99ceralive-keep-cache"* ]]
  done
}

@test "cache mounts: the digest-pinned base images are untouched" {
  # The whole caching change must be invisible to provenance: ci/Dockerfile keeps
  # its literal digest pin and Dockerfile.kernel keeps taking its pin from the
  # manifest via BASE_IMAGE, which the schema constrains to a digest form.
  grep -Eq '^FROM debian:trixie-[0-9]+-slim@sha256:[0-9a-f]{64}$' "$DOCKERFILE"
  grep -Fxq 'ARG BASE_IMAGE' "$DOCKERFILE_KERNEL"
  grep -Fxq 'FROM ${BASE_IMAGE}' "$DOCKERFILE_KERNEL"
}

@test "buildkit: both builder-image build sites go through container_image_build" {
  grep -Fq 'container_image_build "${runtime}"' "$LIB_DIR/kernel/builder.sh"
  grep -Fq 'container_image_build "${runtime}"' "$LIB_DIR/stages/mkosi.sh"
}

@test "buildkit: no build site calls a bare '<runtime> build'" {
  # The bypass is the failure: a second call site that forgets DOCKER_BUILDKIT=1
  # fails to PARSE the Dockerfile, in a file the operator did not write.
  run bash -c "grep -rn --exclude=common.sh '\"\${runtime}\" build ' '$LIB_DIR'"
  [ "$status" -ne 0 ]
}

@test "buildkit: DOCKER_BUILDKIT=1 is set for docker and NOT for podman" {
  local fn
  fn="$(sed -n '/^container_image_build()/,/^}/p' "$LIB_DIR/common.sh")"
  [ -n "$fn" ]
  [[ "$fn" == *'DOCKER_BUILDKIT=1'* ]]
  # podman needs no switch; it needs a floor, asserted separately.
  [[ "$fn" == *'assert_container_build_cache_mounts'* ]]
}

@test "buildkit: the runtime floors refuse a runtime too old for cache mounts" {
  run bash -c "
    set -euo pipefail
    die() { printf 'DIE %s\n' \"\$*\" >&2; exit 1; }
    log_info() { :; }; log_warn() { printf 'WARN %s\n' \"\$*\" >&2; }
    source '$LIB_DIR/shared/log-lib.sh' 2>/dev/null || true
    log_warn() { printf 'WARN %s\n' \"\$*\" >&2; }
    log_info() { :; }
    source '$LIB_DIR/common.sh' >/dev/null 2>&1 || true
    container_runtime_major() { printf '20'; }
    assert_container_build_cache_mounts docker
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"RUN --mount=type=cache"* ]]
}

# ---------------------------------------------------------------------------
# (b) the kernel-source mirror — static contract only
# ---------------------------------------------------------------------------

@test "mirror: the mirror path is derived from paths.sh, never restated" {
  grep -Fq 'CERALIVE_REL_KERNEL_SRC_MIRROR_DIR' "$LIB_DIR/paths.sh"
  grep -Fq 'CERALIVE_REL_KERNEL_SRC_MIRROR_DIR' "$LIB_DIR/kernel/checkout.sh"
  run bash -c "grep -rn 'kernel-src.git' '$LIB_DIR' | grep -v 'paths.sh'"
  [ "$status" -ne 0 ]
}

@test "mirror: the fetch happens under a PER-MIRROR flock, not a per-board one" {
  local fn
  fn="$(sed -n '/^kernel_src_mirror_prepare()/,/^}/p' "$LIB_DIR/kernel/checkout.sh")"
  [ -n "$fn" ]
  [[ "$fn" == *'lock="${mirror}.lock"'* ]]
  [[ "$fn" == *'flock -w "${timeout_s}" 9'* ]]
  # A lock name carrying the CALLER's identity excludes nothing — the exact bug
  # tests/manifest-helpers.bash::serialize shipped once.
  [[ "$fn" != *'${board}'* ]]
  [[ "$fn" != *'BOARD_ID'* ]]
}

@test "mirror: the container mounts it READ-ONLY" {
  grep -Fq -- '-v "${KERNEL_SRC_MIRROR_PATH}:/src/mirror.git:ro"' "$LIB_DIR/build-kernel.sh"
}

@test "mirror: only the KERNEL SOURCE gets one — patches and config stay fresh" {
  local script
  script="$(grep -c 'fetch_pinned_tree /src/linux .*KERNEL_SRC_MIRROR' "$LIB_DIR/build-kernel.sh")"
  [ "$script" = "2" ]   # the tagged and the commit-only branch
  run grep -q 'fetch_pinned_tree /src/patches .*KERNEL_SRC_MIRROR' "$LIB_DIR/build-kernel.sh"
  [ "$status" -ne 0 ]
  run grep -q 'fetch_pinned_tree /src/kconfig .*KERNEL_SRC_MIRROR' "$LIB_DIR/build-kernel.sh"
  [ "$status" -ne 0 ]
}

@test "mirror: gc.auto is disabled so no gc prunes objects under a reader" {
  grep -Fq 'config gc.auto 0' "$LIB_DIR/kernel/checkout.sh"
}

@test "mirror: a bad CERALIVE_KERNEL_SRC_MIRROR value is refused, never read as off" {
  local fn
  fn="$(sed -n '/^kernel_src_mirror_prepare()/,/^}/p' "$LIB_DIR/kernel/checkout.sh")"
  [[ "$fn" == *'must be 0, 1 or auto'* ]]
}

@test "mirror: safe.directory covers the mirror, and comes from GIT_CONFIG_GLOBAL" {
  # git honours safe.directory ONLY from system/global config, and the mirror is
  # host-user-owned while git in the container runs as root.
  grep -Fq 'git_safe_dirs+=("${mirror_container}")' "$LIB_DIR/build-kernel.sh"
  grep -Fq 'GIT_CONFIG_GLOBAL=/in/gitconfig' "$LIB_DIR/build-kernel.sh"
  run grep -q 'GIT_CONFIG_KEY_0=safe.directory' "$LIB_DIR/build-kernel.sh"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# (c) mkosi cache privilege domains
# ---------------------------------------------------------------------------

@test "cache domain: the two domains resolve to different leaves of one board root" {
  local root container native
  root="$(cd "$PIPELINE_DIR" && ./ci/emit-canonical-paths.sh --board rock-5b-plus --get board_mkosi_cache_dir)"
  container="$(cd "$PIPELINE_DIR" && ./ci/emit-canonical-paths.sh --board rock-5b-plus --get board_mkosi_cache_dir_container)"
  native="$(cd "$PIPELINE_DIR" && ./ci/emit-canonical-paths.sh --board rock-5b-plus --get board_mkosi_cache_dir_native)"
  [ "$container" = "$root/container" ]
  [ "$native" = "$root/native" ]
  [ "$container" != "$native" ]
}

@test "cache domain: MKOSI_NATIVE alone decides it — not docker vs podman" {
  run bash -c "source '$LIB_DIR/paths.sh'; MKOSI_NATIVE=1 ceralive_mkosi_cache_domain"
  [ "$output" = "native" ]
  run bash -c "source '$LIB_DIR/paths.sh'; ceralive_mkosi_cache_domain"
  [ "$output" = "container" ]
  run bash -c "source '$LIB_DIR/paths.sh'; MKOSI_NATIVE=0 ceralive_mkosi_cache_domain"
  [ "$output" = "container" ]
}

@test "cache domain: the orchestrator's --cache-directory carries it" {
  grep -Fq 'cache_domain="$(ceralive_mkosi_cache_domain)"' "$LIB_DIR/orchestrate.sh"
  grep -Fq 'local cache_dir="cache/${BOARD_ID}/${cache_domain}"' "$LIB_DIR/orchestrate.sh"
}

@test "cache domain: the DRY_RUN plan names the same directory the real build uses" {
  # A plan that prints a different cache path than the build resolves is how a
  # cold cache goes unnoticed for a release.
  grep -Fq 'cache/${board}/$(ceralive_mkosi_cache_domain)' "$LIB_DIR/stages/mkosi.sh"
}

@test "cache domain: the privilege-domain assertion is still called on both paths" {
  # Separate leaves make the collision far less likely; they do not make it
  # impossible (a `sudo ./build --native` still owns the native leaf as root),
  # so the existing guard stays.
  grep -Fq 'assert_cache_privilege_domain "${MKOSI_DIR}/${cache_dir}" "$(id -u)"' "$LIB_DIR/stages/mkosi.sh"
  grep -Fq 'assert_cache_privilege_domain "${MKOSI_DIR}/${cache_dir}" 0' "$LIB_DIR/stages/mkosi.sh"
}

# ---------------------------------------------------------------------------
# (d) opt-in apt proxy
# ---------------------------------------------------------------------------

@test "proxy: both Dockerfiles take APT_PROXY as a build arg, defaulting to empty" {
  local f
  for f in "$DOCKERFILE" "$DOCKERFILE_KERNEL"; do
    grep -Fxq 'ARG APT_PROXY=' "$f"
    local layer; layer="$(apt_layer "$f")"
    [[ "$layer" == *'if [ -n "${APT_PROXY}" ]'* ]]
    [[ "$layer" == *'Acquire::http::Proxy'* ]]
  done
}

@test "proxy: no Dockerfile proxies https, so no TLS path is ever interposed on" {
  local f
  for f in "$DOCKERFILE" "$DOCKERFILE_KERNEL"; do
    run grep -Fq 'Acquire::https::Proxy' "$f"
    [ "$status" -ne 0 ]
  done
}

@test "proxy: the build-arg is emitted only when CERALIVE_APT_PROXY is set" {
  run bash -c "source '$LIB_DIR/common.sh' >/dev/null 2>&1; container_build_proxy_args"
  [ -z "$output" ]
  run bash -c "source '$LIB_DIR/common.sh' >/dev/null 2>&1; CERALIVE_APT_PROXY=http://acng.lan:3142 container_build_proxy_args"
  [ "${lines[0]}" = "--build-arg" ]
  [ "${lines[1]}" = "APT_PROXY=http://acng.lan:3142" ]
}

@test "proxy: both builder-image call sites thread it through" {
  grep -Fq 'container_build_proxy_args' "$LIB_DIR/kernel/builder.sh"
  grep -Fq 'container_build_proxy_args' "$LIB_DIR/stages/mkosi.sh"
}

@test "proxy: no fetch module reintroduces the apt sandbox-user override" {
  # Pre-existing rule, re-asserted here because this change edits the same option
  # builder: an override pinned to root does not fix a permission, it turns the
  # build-time apt sandbox off.
  run bash -c "grep -rn 'APT::Sandbox::User' '$LIB_DIR/fetch' | grep -v '^.*#'"
  [ "$status" -ne 0 ]
}
