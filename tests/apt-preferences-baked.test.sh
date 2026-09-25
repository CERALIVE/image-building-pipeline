#!/usr/bin/env bash
#
# apt-preferences-baked.test.sh — guard that the apt.ceralive.tv origin pin
# (Pin-Priority 990) is baked by the function the REAL build runs, not only by an
# isolated customize module that `./build` never invokes.
#
# THE GAP THIS CLOSES. Todo 8 added install_apt_preferences() to
# customize/apt-ceralive-repo.sh (orchestrated by run-all.sh), and package-contract.bats
# T2.6 tested THAT function in a temp dir. But the runtime image is built solely by
# mkosi.images/runtime/mkosi.postinst.chroot::setup_ceralive_repository(), whose
# inline twin never wrote the pin — run-all.sh's runtime modules do not run in
# `./build` (only `run-all.sh base` for user creation). So the module test
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
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"
POSTINST="${PIPELINE_DIR}/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"

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
grep -Eq '/etc/apt/preferences\.d/ceralive-origin' <<<"${fn_body}" \
  || fail "setup_ceralive_repository() no longer writes /etc/apt/preferences.d/ceralive-origin — the apt.ceralive.tv origin pin never ships (run-all.sh's module is not run by ./build)"
grep -Eq 'Pin: origin apt\.ceralive\.tv' <<<"${fn_body}" \
  || fail "setup_ceralive_repository() no longer pins the apt.ceralive.tv origin"
grep -Eq 'Pin-Priority: 990' <<<"${fn_body}" \
  || fail "setup_ceralive_repository() no longer sets Pin-Priority: 990"
grep -Eq 'Pin: release o=Debian' <<<"${fn_body}" \
  || fail "setup_ceralive_repository() no longer refuses a same-name Debian package (Pin: release o=Debian) — Todo 29's -1 stanza is missing"
grep -Eq "rm -f /etc/apt/preferences\.d/ceralive\$" <<<"${fn_body}" \
  || fail "setup_ceralive_repository() no longer removes the RETIRED /etc/apt/preferences.d/ceralive wildcard file"

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
# CERALIVE_FIRST_PARTY_NAMES_B64 supplies a real test name (Todo 29) so the
# generated per-name file is non-vacuous.
log() { :; }
CHANNEL="stable"
export CERALIVE_FIRST_PARTY_NAMES_B64="\$(printf 'cerastream\n' | base64 -w0)"
eval "\$(awk '/^setup_ceralive_repository\(\) \{/,/^}/' "${POSTINST}")"
setup_ceralive_repository

[ ! -e /etc/apt/preferences.d/ceralive ] || { echo "FAIL: the retired /etc/apt/preferences.d/ceralive wildcard file still exists"; exit 1; }
[ -f /etc/apt/preferences.d/ceralive-origin ] || { echo "FAIL: setup_ceralive_repository did not create /etc/apt/preferences.d/ceralive-origin (the pin would not ship)"; exit 1; }
grep -qxF 'Package: cerastream' /etc/apt/preferences.d/ceralive-origin || { echo "FAIL: ceralive-origin missing 'Package: cerastream'"; exit 1; }
grep -qxF 'Pin: origin apt.ceralive.tv' /etc/apt/preferences.d/ceralive-origin || { echo "FAIL: ceralive-origin missing 'Pin: origin apt.ceralive.tv'"; exit 1; }
grep -qxF 'Pin-Priority: 990' /etc/apt/preferences.d/ceralive-origin || { echo "FAIL: ceralive-origin missing 'Pin-Priority: 990'"; exit 1; }
grep -qxF 'Pin: release o=Debian' /etc/apt/preferences.d/ceralive-origin || { echo "FAIL: ceralive-origin missing the -1 Debian-refusal stanza"; exit 1; }
grep -qxF 'Pin-Priority: -1' /etc/apt/preferences.d/ceralive-origin || { echo "FAIL: ceralive-origin missing 'Pin-Priority: -1'"; exit 1; }
# and the source it pins must be present too (sanity: same function writes both).
grep -q '^URIs: https://apt.ceralive.tv/' /etc/apt/sources.list.d/ceralive.sources || { echo "FAIL: ceralive.sources not written alongside the pin"; exit 1; }
REPRO_EOF

if unshare -rm --map-root-user bash "${REPRO}"; then
  echo "apt-preferences-baked: Part B runtime OK (build-path setup_ceralive_repository bakes preferences.d/ceralive-origin with per-name 990/-1 pins)"
else
  fail "the real setup_ceralive_repository() did not bake /etc/apt/preferences.d/ceralive-origin with the per-name origin pin"
fi

echo "apt-preferences-baked regression: PASS"
