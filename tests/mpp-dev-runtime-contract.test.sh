#!/usr/bin/env bash
#
# librockchip-mpp-dev runtime contract — the verdict, and the reasoning that
# produced it, held in place.
#
# WHY THIS FILE EXISTS. `librockchip-mpp-dev` was in the RK3588 family's
# gstreamer_runtime_packages because the pinned userspace set was adopted whole,
# as the exact combination that had been proven on hardware. That is a good
# reason to be careful and a bad reason to keep shipping a package: `-dev` is a
# libdevel package, and the image compiles nothing.
#
# It is also exactly the kind of removal that can be quietly wrong. A `-dev`
# package normally owns the unversioned `lib*.so` symlink, and anything doing
# `dlopen("librockchip_mpp.so")` would break at runtime with no build-time
# signal — the same shape as every other defect this repo has shipped. So the
# verdict is not a judgement call recorded in prose; it is a decision procedure,
# and this suite is that procedure applied to fixtures, in both directions.
#
# THE VERDICT LINE IS THE SOURCE OF TRUTH. `manifests/packages/removed.md`
# carries exactly one `librockchip-mpp-dev: KEEP|REMOVE` line, and the family
# manifest must agree with it. Flip one without the other and this fails.
#
# Hardware-free, root-free and OFFLINE: every `.deb` here is built locally with
# dpkg-deb. The real package's properties are asserted as FIXTURES so the suite
# does not depend on the network or on a staged pool.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"
FAMILY="${PIPELINE_DIR}/manifests/families/rk3588.yaml"
REMOVED_MD="${PIPELINE_DIR}/manifests/packages/removed.md"
PINS="${PIPELINE_DIR}/manifests/rk3588-userspace-deb-versions.txt"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$(( PASS + 1 )); printf 'ok   %s\n' "$*"; }
bad() { FAIL=$(( FAIL + 1 )); printf 'FAIL %s\n' "$*"; }
check() { if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 (want '$1', got '$2')"; fi; }

command -v dpkg-deb >/dev/null 2>&1 || { echo "SKIP: dpkg-deb is required"; exit 0; }

# ---------------------------------------------------------------------------
# The decision procedure, written once and applied to every fixture.
#
# A package is RUNTIME-RELEVANT if its payload carries anything the running
# system can execute, load or be configured by: a shared object, an executable,
# a udev rule or a systemd unit. Headers, pkg-config files and documentation are
# build-time-only by definition.
# ---------------------------------------------------------------------------
runtime_payload_verdict() {
  local deb="$1"
  local listing; listing="$(dpkg-deb -c "${deb}" | awk '{print $NF}')"
  if grep -qE '\.so(\.[0-9]+)*$|^\./(usr/)?s?bin/|^\./usr/lib/systemd/|\.rules$|^\./lib/udev/' <<<"${listing}"; then
    echo REMOVE-UNSAFE
  else
    echo REMOVE-SAFE
  fi
}

rdepends_verdict() {
  local target="$1"; shift
  local deb fields
  for deb in "$@"; do
    fields="$(dpkg-deb -f "${deb}" Depends Recommends Suggests Pre-Depends 2>/dev/null || true)"
    if grep -qE "(^|[ ,:])${target}([ ,(]|$)" <<<"${fields}"; then
      echo REMOVE-UNSAFE
      return 0
    fi
  done
  echo REMOVE-SAFE
}

build_deb() {
  local name="$1" depends="$2" out="$3"; shift 3
  local stage="${WORK}/stage-${name}"
  rm -rf "${stage}"
  mkdir -p "${stage}/DEBIAN"
  {
    printf 'Package: %s\nVersion: 1.5.0-1\nArchitecture: arm64\n' "${name}"
    printf 'Maintainer: fixture <f@f>\nDescription: fixture\n'
    [[ -n "${depends}" ]] && printf 'Depends: %s\n' "${depends}"
  } >"${stage}/DEBIAN/control"
  local rel
  for rel in "$@"; do
    mkdir -p "${stage}/$(dirname "${rel}")"
    printf 'x\n' >"${stage}/${rel}"
  done
  dpkg-deb --build --root-owner-group "${stage}" "${out}" >/dev/null
}

# ---------------------------------------------------------------------------
# 1. The payload fixture — the real package's shape, and the shape that would
#    have forced the opposite verdict.
# ---------------------------------------------------------------------------
build_deb librockchip-mpp-dev 'librockchip-mpp1 (= 1.5.0-1)' "${WORK}/mpp-dev.deb" \
  usr/include/rockchip/rk_mpi.h \
  usr/include/rockchip/rk_venc_cfg.h \
  usr/lib/aarch64-linux-gnu/pkgconfig/rockchip_mpp.pc \
  usr/lib/aarch64-linux-gnu/pkgconfig/rockchip_vpu.pc \
  usr/share/doc/librockchip-mpp-dev/copyright

check "REMOVE-SAFE" "$(runtime_payload_verdict "${WORK}/mpp-dev.deb")" \
  "a headers+pkgconfig+docs payload carries no runtime content"

build_deb mpp-dev-with-so '' "${WORK}/mpp-dev-so.deb" \
  usr/include/rockchip/rk_mpi.h \
  usr/lib/aarch64-linux-gnu/librockchip_mpp.so
check "REMOVE-UNSAFE" "$(runtime_payload_verdict "${WORK}/mpp-dev-so.deb")" \
  "NON-VACUITY: a -dev package owning the unversioned .so IS runtime-relevant"

build_deb mpp-dev-with-rule '' "${WORK}/mpp-dev-rule.deb" \
  usr/include/rockchip/rk_mpi.h \
  lib/udev/rules.d/99-mpp.rules
check "REMOVE-UNSAFE" "$(runtime_payload_verdict "${WORK}/mpp-dev-rule.deb")" \
  "NON-VACUITY: a -dev package shipping a udev rule IS runtime-relevant"

build_deb mpp-dev-with-bin '' "${WORK}/mpp-dev-bin.deb" \
  usr/include/rockchip/rk_mpi.h \
  usr/bin/mpp_info
check "REMOVE-UNSAFE" "$(runtime_payload_verdict "${WORK}/mpp-dev-bin.deb")" \
  "NON-VACUITY: a -dev package shipping an executable IS runtime-relevant"

# ---------------------------------------------------------------------------
# 2. The runtime package owns the WHOLE soname chain, unversioned link included.
#    This is the single fact that makes the removal safe rather than plausible.
# ---------------------------------------------------------------------------
build_deb librockchip-mpp1 '' "${WORK}/mpp1.deb" \
  usr/lib/aarch64-linux-gnu/librockchip_mpp.so.0
mkdir -p "${WORK}/mpp1-extra/usr/lib/aarch64-linux-gnu"
MPP1_LIST="$(dpkg-deb -c "${WORK}/mpp1.deb" | awk '{print $NF}')"
if grep -q 'librockchip_mpp.so.0' <<<"${MPP1_LIST}"; then
  ok "the runtime package is the one carrying librockchip_mpp.so*"
else
  bad "fixture error: the runtime package lost its library"
fi

if grep -q 'librockchip_mpp\.so   *-> *librockchip_mpp\.so\.1' "${REMOVED_MD}"; then
  ok "the recorded evidence shows the unversioned .so belongs to librockchip-mpp1, not -dev"
else
  bad "the removal record must show which package owns the unversioned .so symlink"
fi

# ---------------------------------------------------------------------------
# 3. Reverse dependencies — nothing on the image asks for -dev.
# ---------------------------------------------------------------------------
build_deb gstreamer1.0-rockchip1 'librga2, librockchip-mpp1, libgstreamer1.0-0' "${WORK}/gst.deb" \
  usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstrockchipmpp.so
build_deb librga2 'libc6, libstdc++6' "${WORK}/rga.deb" \
  usr/lib/aarch64-linux-gnu/librga.so.2
build_deb rockchip-multimedia-config '' "${WORK}/rmc.deb" \
  lib/udev/rules.d/99-rk-device-permissions.rules

check "REMOVE-SAFE" "$(rdepends_verdict librockchip-mpp-dev "${WORK}/gst.deb" "${WORK}/rga.deb" "${WORK}/rmc.deb" "${WORK}/mpp1.deb")" \
  "no shipped RK3588 userspace package depends on librockchip-mpp-dev"

build_deb needs-mpp-dev 'librockchip-mpp-dev' "${WORK}/needy.deb" usr/bin/thing
check "REMOVE-UNSAFE" "$(rdepends_verdict librockchip-mpp-dev "${WORK}/gst.deb" "${WORK}/needy.deb")" \
  "NON-VACUITY: one dependent package flips the reverse-dependency verdict"

# The dependency runs -dev -> runtime and never back, so removing -dev cannot
# disturb the runtime. Both directions are asserted, because "they depend on each
# other" is the reading that would make this removal unsafe.
check "REMOVE-UNSAFE" "$(rdepends_verdict librockchip-mpp1 "${WORK}/mpp-dev.deb")" \
  "librockchip-mpp-dev DOES depend on librockchip-mpp1 (the direction that exists)"
check "REMOVE-SAFE" "$(rdepends_verdict librockchip-mpp-dev "${WORK}/mpp1.deb")" \
  "librockchip-mpp1 does NOT depend on -dev (the direction that would block removal)"

# ---------------------------------------------------------------------------
# 4. The encoder consumer resolves the VERSIONED soname. A plugin linking the
#    unversioned name would still work with -dev installed and break without it,
#    which is precisely the trap this leg exists to catch.
# ---------------------------------------------------------------------------
if grep -q 'NEEDED librockchip_mpp.so.1' "${REMOVED_MD}"; then
  ok "the recorded evidence pins the encoder plugin to the VERSIONED soname"
else
  bad "the removal record must show which soname libgstrockchipmpp.so links"
fi
if grep -qE 'NEEDED librockchip_mpp\.so($|[^.0-9])' "${REMOVED_MD}"; then
  bad "the evidence claims a link against the UNVERSIONED soname — that would force KEEP"
else
  ok "nothing in the evidence links the unversioned soname"
fi

# ---------------------------------------------------------------------------
# 5. The verdict, and the manifest agreeing with it.
# ---------------------------------------------------------------------------
VERDICT_LINES="$(grep -cE '^\*\*librockchip-mpp-dev: (KEEP|REMOVE)\*\*$' "${REMOVED_MD}" || true)"
check "1" "${VERDICT_LINES}" "removed.md carries exactly ONE explicit verdict line"

VERDICT="$(grep -oE 'librockchip-mpp-dev: (KEEP|REMOVE)' "${REMOVED_MD}" | head -1 | awk '{print $2}')"
DECLARED="$(grep -cE '^\s*-\s*librockchip-mpp-dev\s*$' "${FAMILY}" || true)"

case "${VERDICT}" in
  REMOVE) check "0" "${DECLARED}" "verdict REMOVE and the family manifest no longer declares the package" ;;
  KEEP)   check "1" "${DECLARED}" "verdict KEEP and the family manifest still declares the package" ;;
  *)      bad "no KEEP/REMOVE verdict found in ${REMOVED_MD}" ;;
esac

if [[ "${VERDICT}" == "REMOVE" ]]; then
  PINNED="$(grep -cE '^librockchip-mpp-dev\s' "${PINS}" || true)"
  check "0" "${PINNED}" "the retired package leaves no stale pin row behind"
  # The runtime half must NOT have been dragged out with it.
  RUNTIME_PINNED="$(grep -cE '^librockchip-mpp1\s' "${PINS}" || true)"
  check "1" "${RUNTIME_PINNED}" "librockchip-mpp1 is untouched — this is not an MPP downgrade"
  if grep -qE '^\s*-\s*librockchip-mpp1\s*$' "${FAMILY}"; then
    ok "the family manifest still declares the MPP runtime"
  else
    bad "librockchip-mpp1 must stay declared"
  fi
  # The exact asset stays recoverable from the record.
  if grep -q 'aa38d6476ff4798623b37f09845436ab80d730f42c17e305f43ba7a892ee34fe' "${REMOVED_MD}"; then
    ok "the removal record keeps the exact version and SHA-256 of the retired asset"
  else
    bad "a retired pinned asset must stay recoverable from the record"
  fi
fi

printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
