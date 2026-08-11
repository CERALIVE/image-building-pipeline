#!/usr/bin/env bash
#
# mkosi-cache-privilege-domain.test.sh — contract for the two guards that keep
# the mkosi package cache inside ONE privilege domain.
#
# WHAT THIS EXISTS FOR
#
# mkosi/cache/<board>/*base.cache is a real rootfs snapshot. The containerized
# build writes it as uid 0 and a --native build writes it as the invoking user,
# and mkosi 26 will not reuse a cache tree owned by another uid — it deletes it
# instead (`have_cache` -> `run_clean` -> `remove_cache_entries` ->
# `mkosi.tree.rmtree`, whose `rm -rf` runs check=True). That deletion succeeds
# for a domain with authority over the tree and FAILS the build for one without,
# in a wall of `rm: cannot remove …: Permission denied`.
#
# Two guards close it, and this suite pins both plus the fix that must never be
# reintroduced:
#
#   assert_container_daemon_supported — refuses a Docker Desktop daemon, whose
#     VM-share bind mount performs host I/O as the desktop user (so container
#     root cannot unlink a host-uid-0 file) and carries no POSIX ACLs/xattrs
#     (so mkosi's `tar --acls --xattrs` cannot extract a subimage at all).
#   assert_cache_privilege_domain — reports a cache the incoming build cannot
#     use, and DIES for the one case mkosi cannot recover from itself.
#
# NEGATIVE CONTRACT: nothing may chown the mkosi cache to the invoking user.
# That looks like the obvious repair and is the opposite of one — mkosi's own
# uid check would then reject the cache on every later containerized run, which
# is a permanently cold cache wearing the costume of a fix.
#
# Profile: contract-test (docs/shell-profiles.md) — collects, owns its exit code.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"
COMMON_SH="${PIPELINE_DIR}/lib/common.sh"
MKOSI_STAGE="${PIPELINE_DIR}/lib/stages/mkosi.sh"
KERNEL_BUILDER="${PIPELINE_DIR}/lib/kernel/builder.sh"

# shellcheck source=lib/assertions.sh
source "${HERE}/lib/assertions.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# Run one guard in a pristine child shell and report "<rc>\n<output>". The guards
# die() via exit, so each leg needs its own process; sourcing common.sh also
# installs strict mode plus an ERR trap that must not leak into this harness.
run_guard() {
  local snippet="$1" out rc
  out="$(bash -c "
    source '${COMMON_SH}'
    source '${MKOSI_STAGE}'
    ${snippet}
  " 2>&1)"
  rc=$?
  printf '%s\n' "${rc}"
  printf '%s\n' "${out}" >"${WORK}/last-output"
}

stub_docker() {
  local dir="$1" body="$2"
  mkdir -p "${dir}"
  { printf '#!/usr/bin/env bash\n'; printf '%s\n' "${body}"; } >"${dir}/docker"
  chmod +x "${dir}/docker"
}

printf '== static wiring\n'

assert_contains "mkosi stage refuses an unsupported daemon before it builds the image" \
  "${MKOSI_STAGE}" 'assert_container_daemon_supported "${runtime}"'
assert_contains "mkosi stage gates the cache domain on the CONTAINER path (uid 0)" \
  "${MKOSI_STAGE}" 'assert_cache_privilege_domain "${MKOSI_DIR}/${cache_dir}" 0'
assert_contains "mkosi stage gates the cache domain on the NATIVE path (invoking uid)" \
  "${MKOSI_STAGE}" 'assert_cache_privilege_domain "${MKOSI_DIR}/${cache_dir}" "$(id -u)"'
assert_contains "the kernel-build container is gated too, so the refusal lands at [2b/9]" \
  "${KERNEL_BUILDER}" 'assert_container_daemon_supported "${runtime}"'

# The guards must not be able to pass by swallowing a failure — this repo's
# no-`|| true` rule, applied to the exact functions that own the failure.
guards_body="${WORK}/guards.sh"
sed -n '/^assert_container_daemon_supported()/,/^}/p' "${COMMON_SH}" >"${guards_body}"
sed -n '/^assert_cache_privilege_domain()/,/^}/p' "${MKOSI_STAGE}" >>"${guards_body}"
[[ -s "${guards_body}" ]] || bad "could not extract the guard bodies"
if grep -qE '\|\|[[:space:]]*true|2>/dev/null' "${guards_body}"; then
  bad "a guard swallows its own failure (|| true / 2>/dev/null)"
else
  ok "neither guard swallows a failure (no || true, no 2>/dev/null)"
fi

# The repair that must never be reintroduced.
if grep -rn 'chown' "${PIPELINE_DIR}/lib" | grep -q 'MKOSI_CACHE\|mkosi/cache'; then
  bad "something chowns the mkosi cache — mkosi 26 rejects a cache whose uid is not its own"
else
  ok "nothing in lib/ chowns the mkosi cache"
fi

printf '== assert_container_daemon_supported\n'

stub_docker "${WORK}/desktop" 'printf "Docker Desktop\n"'
rc="$(PATH="${WORK}/desktop:${PATH}" run_guard 'assert_container_daemon_supported docker')"
assert_eq "a Docker Desktop daemon is refused" 1 "${rc}"
assert_contains "the refusal names Docker Desktop" "${WORK}/last-output" 'Docker Desktop'
assert_contains "the refusal names the permission failure it prevents" \
  "${WORK}/last-output" 'Permission denied'
assert_contains "the refusal names the ACL failure it prevents" \
  "${WORK}/last-output" 'acl_set_file_at'
assert_contains "the refusal says how to recover" "${WORK}/last-output" 'DOCKER_CONTEXT=default'

stub_docker "${WORK}/native" 'printf "Arch Linux\n"'
rc="$(PATH="${WORK}/native:${PATH}" run_guard 'assert_container_daemon_supported docker')"
assert_eq "a native Linux daemon is accepted" 0 "${rc}"

stub_docker "${WORK}/dead" 'exit 1'
rc="$(PATH="${WORK}/dead:${PATH}" run_guard 'assert_container_daemon_supported docker')"
assert_eq "an unreachable daemon is a loud failure, not a pass" 1 "${rc}"

# Non-vacuity for the podman scope: the SAME stub that fails the docker leg must
# be skipped for podman, so the scoping is proven rather than assumed.
rc="$(PATH="${WORK}/desktop:${PATH}" run_guard 'assert_container_daemon_supported podman')"
assert_eq "podman is out of scope (different info schema, no VM share)" 0 "${rc}"

printf '== assert_cache_privilege_domain\n'

CACHE_ENV="PIPELINE_DIR='${PIPELINE_DIR}' MKOSI_BUILDER_IMAGE=builder:test"
CACHE_ENV+=" CERALIVE_REL_MKOSI_CACHE_ROOT=mkosi/cache"

mkdir -p "${WORK}/cache/board"
SELF_UID="$(id -u)"

rc="$(run_guard "${CACHE_ENV} assert_cache_privilege_domain '${WORK}/absent' '${SELF_UID}'")"
assert_eq "a cache that does not exist yet is not a failure" 0 "${rc}"

rc="$(run_guard "${CACHE_ENV} assert_cache_privilege_domain '${WORK}/cache/board' '${SELF_UID}'")"
assert_eq "a cache owned by the uid mkosi will run as is accepted" 0 "${rc}"

rc="$(run_guard "${CACHE_ENV} assert_cache_privilege_domain '${WORK}/cache/board' 0")"
assert_eq "container root may discard a user-owned cache (warn, never die)" 0 "${rc}"
assert_contains "the cold-cache cost is stated rather than hidden" \
  "${WORK}/last-output" 'discard and rebuild it'

rc="$(run_guard "${CACHE_ENV} assert_cache_privilege_domain '${WORK}/cache/board' 4294967290")"
assert_eq "an unprivileged build meeting a foreign-owned cache dies" 1 "${rc}"
assert_contains "the refusal names the failure the operator would otherwise see" \
  "${WORK}/last-output" 'Permission denied'
assert_contains "the refusal offers a privileged removal" "${WORK}/last-output" 'rm -rf'

printf '\nmkosi-cache-privilege-domain: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
