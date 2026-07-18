#!/usr/bin/env bash
#
# apt-preferences-baked.test.sh — guard that the apt.ceralive.tv origin pin
# (Pin-Priority 990) is baked by the function the REAL build runs, not only by an
# isolated customize module that `./v2/build` never invokes.
#
# THE GAP THIS CLOSES. Todo 8 added install_apt_preferences() to
# customize/apt-ceralive-repo.sh (orchestrated by run-all.sh), and manifest.bats
# T2.6 tested THAT function in a temp dir. But the runtime image is built solely by
# mkosi.images/runtime/mkosi.postinst.chroot::setup_ceralive_repository(), whose
# inline twin never wrote the pin — run-all.sh's runtime modules do not run in
# `./v2/build` (only `run-all.sh base` for user creation). So the module test
# stayed green while the shipped image carried an EMPTY /etc/apt/preferences.d
# (confirmed on a real rock-5b-plus rootfs). This test targets the executor the
# build ACTUALLY runs.
#
# Part A — static contract: the runtime executor's setup_ceralive_repository()
#          writes /etc/apt/preferences.d/ceralive with the exact 990 origin pin.
# Part B — runtime: run the REAL setup_ceralive_repository() (extracted from the
#          runtime executor, no secrets → placeholder branches) against a scratch
#          chroot filesystem in a rootless user+mount namespace, and assert the pin
#          file exists in the resulting tree — i.e. the build path bakes it.
#
# shellcheck disable=SC2016

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2="$(cd "${HERE}/.." && pwd)"
POSTINST="${V2}/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"

fail() { printf 'apt-preferences-baked regression: %s\n' "$1" >&2; exit 1; }

[[ -f "${POSTINST}" ]] || fail "missing runtime executor: ${POSTINST}"

fn_body="$(awk '
  /^setup_ceralive_repository\(\) \{/ { f=1 }
  f { print }
  f && /^\}/ { exit }
' "${POSTINST}")"
[[ -n "${fn_body}" ]] || fail "could not extract setup_ceralive_repository() from the runtime executor"

# ---------------------------------------------------------------------------
# Part A — static contract (always enforced)
# ---------------------------------------------------------------------------
grep -Eq '/etc/apt/preferences\.d/ceralive' <<<"${fn_body}" \
  || fail "setup_ceralive_repository() no longer writes /etc/apt/preferences.d/ceralive — the apt.ceralive.tv origin pin never ships (run-all.sh's module is not run by ./v2/build)"
grep -Eq '^Pin: origin apt\.ceralive\.tv$' <<<"${fn_body}" \
  || fail "setup_ceralive_repository() no longer pins the apt.ceralive.tv origin"
grep -Eq '^Pin-Priority: 990$' <<<"${fn_body}" \
  || fail "setup_ceralive_repository() no longer sets Pin-Priority: 990"

echo "apt-preferences-baked: Part A static contract OK (runtime executor writes the 990 origin pin)"

# ---------------------------------------------------------------------------
# Part B — runtime reproduction in a rootless user+mount namespace (best effort)
# ---------------------------------------------------------------------------
if ! unshare -rm --map-root-user true 2>/dev/null; then
  echo "apt-preferences-baked: rootless user+mount namespaces unavailable — skipping Part B (static contract enforced)"
  echo "apt-preferences-baked regression: PASS (static only)"
  exit 0
fi

REPRO="$(mktemp)"
trap 'rm -f "${REPRO}"' EXIT
cat >"${REPRO}" <<REPRO_EOF
set -euo pipefail
# Scratch chroot filesystem: tmpfs over the absolute trees the function writes, so
# the host is never touched and we inspect exactly what the build would bake.
# /usr/share (not /usr/bin) is tmpfs'd for the keyring write — binaries stay intact.
mount -t tmpfs none /etc
mount -t tmpfs none /usr/share
mkdir -p /usr/share/keyrings
mkdir -p /etc/apt/sources.list.d /etc/apt/apt.conf.d /etc/apt/certs

# Run the REAL build-path function with no secrets (placeholder keyring, mTLS
# skipped). Only 'log' and CHANNEL are ambient in the executor; stub/seed them.
log() { :; }
CHANNEL="stable"
eval "\$(awk '/^setup_ceralive_repository\(\) \{/,/^}/' "${POSTINST}")"
setup_ceralive_repository

[ -f /etc/apt/preferences.d/ceralive ] || { echo "FAIL: setup_ceralive_repository did not create /etc/apt/preferences.d/ceralive (the pin would not ship)"; exit 1; }
grep -qxF 'Package: *' /etc/apt/preferences.d/ceralive || { echo "FAIL: preferences.d/ceralive missing 'Package: *'"; exit 1; }
grep -qxF 'Pin: origin apt.ceralive.tv' /etc/apt/preferences.d/ceralive || { echo "FAIL: preferences.d/ceralive missing 'Pin: origin apt.ceralive.tv'"; exit 1; }
grep -qxF 'Pin-Priority: 990' /etc/apt/preferences.d/ceralive || { echo "FAIL: preferences.d/ceralive missing 'Pin-Priority: 990'"; exit 1; }
# and the source it pins must be present too (sanity: same function writes both).
grep -q '^URIs: https://apt.ceralive.tv/' /etc/apt/sources.list.d/ceralive.sources || { echo "FAIL: ceralive.sources not written alongside the pin"; exit 1; }
REPRO_EOF

if unshare -rm --map-root-user bash "${REPRO}"; then
  echo "apt-preferences-baked: Part B runtime OK (build-path setup_ceralive_repository bakes preferences.d/ceralive with the 990 pin)"
else
  fail "the real setup_ceralive_repository() did not bake /etc/apt/preferences.d/ceralive with the 990 origin pin"
fi

echo "apt-preferences-baked regression: PASS"
