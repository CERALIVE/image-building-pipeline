#!/usr/bin/env bash
#
# deb-lib.test.sh — contract for lib/shared/deb-lib.sh, the ONE home for Debian
# control parsing, package-identity assertion and .deb extraction.
#
# Three legs the consolidation must not lose:
#   happy   — a well-formed .deb reads back its exact Package/Version/Architecture
#             and explodes its data tarball
#   wrong   — every identity axis (package, version, architecture) is rejected
#             individually, so a mismatch can never be waved through
#   corrupt — a truncated / non-ar / control-less archive yields empty fields and
#             therefore FAILS the identity assertion instead of crashing
#
# It also asserts the single-definition property the refactor exists for: no
# helper in this library is defined twice, and no other library re-implements it.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"
DEB_LIB="${PIPELINE_DIR}/lib/shared/deb-lib.sh"

PASS=0
fail() { printf 'deb-lib: FAIL: %s\n' "$*" >&2; exit 1; }
ok()   { PASS=$(( PASS + 1 )); printf 'deb-lib: ok  %s\n' "$*"; }

[[ -f "${DEB_LIB}" ]] || fail "missing library: ${DEB_LIB}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

command -v ar >/dev/null 2>&1 || fail "'ar' (binutils) is required to build the fixtures"

# make_deb <path> <pkg> <version> <arch> [payload-relative-path]
make_deb() {
  local out="$1" pkg="$2" version="$3" arch="$4" payload="${5:-}"
  [[ -n "${payload}" ]] || payload="usr/bin/${pkg}"
  local d; d="$(mktemp -d "${WORK}/mk-XXXXXX")"
  mkdir -p "${d}/data/$(dirname "${payload}")" "${d}/control"
  printf '#!/bin/sh\nexit 0\n' >"${d}/data/${payload}"
  chmod +x "${d}/data/${payload}"
  printf 'Package: %s\nVersion: %s\nArchitecture: %s\nMaintainer: CI <ci@example.invalid>\nDescription: fixture\n' \
    "${pkg}" "${version}" "${arch}" >"${d}/control/control"
  ( cd "${d}/data" && tar -czf ../data.tar.gz . )
  ( cd "${d}/control" && tar -czf ../control.tar.gz . )
  printf '2.0\n' >"${d}/debian-binary"
  ( cd "${d}" && ar rc "${out}" debian-binary control.tar.gz data.tar.gz )
}

# Every leg runs the library in its own subshell so one leg cannot poison the next.
# common.sh's loud ERR trap is disarmed there — a deliberately-rejecting assertion is
# an expected outcome, not a crash to report — while `set -e` stays on so a real
# strict-mode fault still fails the leg.
lib_eval() {
  local code="$1"; shift
  DEB_LIB="${DEB_LIB}" bash -c "
    set -euo pipefail
    # shellcheck disable=SC1090
    source \"\${DEB_LIB}\"
    trap - ERR
    ${code}
  " _ "$@"
}

# --- single-definition property --------------------------------------------
for fn in deb_control_field deb_pkg_name deb_pkg_version deb_pkg_arch assert_deb_identity explode_deb; do
  n="$(grep -c "^${fn}() {" "${DEB_LIB}" || true)"
  [[ "${n}" == "1" ]] || fail "${fn} is defined ${n} times in deb-lib.sh (expected exactly 1)"
done
ok "each helper is defined exactly once in deb-lib.sh"

# No sibling library may carry a private copy of the consolidated readers. The
# kernel builder keeps its own dpkg-less reader for its self-contained in-builder
# leg and is out of this library's scope; everything else routes here.
dupes="$(cd "${PIPELINE_DIR}" && grep -rln '^deb_pkg_\(name\|version\|arch\)() {\|^explode_deb() {\|^_explode_deb() {' \
  --include='*.sh' lib dev-push 2>/dev/null | grep -v '^lib/shared/deb-lib.sh$' || true)"
[[ -z "${dupes}" ]] || fail "duplicate deb helper definitions still present in: ${dupes}"
ok "no sibling library re-defines the shared deb helpers"

# --- happy path -------------------------------------------------------------
good="${WORK}/cerastream_2026.6.1_arm64.deb"
make_deb "${good}" cerastream 2026.6.1 arm64

[[ "$(lib_eval 'deb_pkg_name "$1"' "${good}")" == "cerastream" ]] \
  || fail "deb_pkg_name did not read Package back"
[[ "$(lib_eval 'deb_pkg_version "$1"' "${good}")" == "2026.6.1" ]] \
  || fail "deb_pkg_version did not read Version back"
[[ "$(lib_eval 'deb_pkg_arch "$1"' "${good}")" == "arm64" ]] \
  || fail "deb_pkg_arch did not read Architecture back"
[[ "$(lib_eval 'deb_control_field "$1" Maintainer' "${good}")" == "CI <ci@example.invalid>" ]] \
  || fail "deb_control_field did not read an arbitrary field back"
ok "happy: control fields read back exactly"

lib_eval 'assert_deb_identity "$1" cerastream 2026.6.1 arm64' "${good}" \
  || fail "assert_deb_identity rejected a matching package"
ok "happy: assert_deb_identity accepts the exact triple"

lib_eval 'assert_deb_identity "$1" cerastream "" arm64' "${good}" \
  || fail "assert_deb_identity with an empty expected version rejected a matching package"
ok "happy: an empty expected version skips the version leg"

allpkg="${WORK}/armbian-firmware_1_all.deb"
make_deb "${allpkg}" armbian-firmware 1 all
lib_eval 'assert_deb_identity "$1" armbian-firmware 1 arm64 --arch-all-ok' "${allpkg}" \
  || fail "--arch-all-ok rejected an Architecture: all package"
if lib_eval 'assert_deb_identity "$1" armbian-firmware 1 arm64' "${allpkg}"; then
  fail "an Architecture: all package was accepted WITHOUT --arch-all-ok"
fi
ok "happy: 'all' is accepted only under --arch-all-ok"

exploded="${WORK}/exploded"
lib_eval 'explode_deb "$1" "$2"' "${good}" "${exploded}" >/dev/null
[[ -x "${exploded}/usr/bin/cerastream" ]] \
  || fail "explode_deb did not lay the data tarball into the destination"
ok "happy: explode_deb extracts the data tarball"

# --- wrong identity ---------------------------------------------------------
if lib_eval 'assert_deb_identity "$1" srtla-send-rs 2026.6.1 arm64' "${good}"; then
  fail "a WRONG PACKAGE NAME was accepted"
fi
ok "wrong: a mismatched package name is rejected"

if lib_eval 'assert_deb_identity "$1" cerastream 2026.6.2 arm64' "${good}"; then
  fail "a WRONG VERSION was accepted"
fi
ok "wrong: a mismatched version is rejected"

if lib_eval 'assert_deb_identity "$1" cerastream 2026.6.1 amd64' "${good}"; then
  fail "a WRONG ARCHITECTURE was accepted"
fi
if lib_eval 'assert_deb_identity "$1" cerastream 2026.6.1 amd64 --arch-all-ok' "${good}"; then
  fail "a WRONG ARCHITECTURE was accepted under --arch-all-ok (arm64 is not 'all')"
fi
ok "wrong: a mismatched architecture is rejected, --arch-all-ok included"

# The actuals must be published for the caller's own diagnostic, not swallowed.
actual="$(lib_eval 'assert_deb_identity "$1" wrong-name 1 arm64 || printf "%s|%s|%s" "${DEB_ACTUAL_PKG}" "${DEB_ACTUAL_VERSION}" "${DEB_ACTUAL_ARCH}"' "${good}")"
[[ "${actual}" == "cerastream|2026.6.1|arm64" ]] \
  || fail "DEB_ACTUAL_* did not publish what was actually found (got '${actual}')"
ok "wrong: DEB_ACTUAL_* publishes the observed identity for the caller's message"

# --- corrupt archives -------------------------------------------------------
truncated="${WORK}/truncated.deb"
head -c 64 "${good}" >"${truncated}"
[[ "$(lib_eval 'deb_pkg_name "$1"' "${truncated}")" == "" ]] \
  || fail "a truncated .deb produced a package name"
if lib_eval 'assert_deb_identity "$1" cerastream 2026.6.1 arm64' "${truncated}"; then
  fail "a TRUNCATED .deb passed the identity assertion"
fi
ok "corrupt: a truncated archive reads empty and fails the assertion"

notanar="${WORK}/notanar.deb"
printf 'this is not an ar archive at all\n' >"${notanar}"
if lib_eval 'assert_deb_identity "$1" cerastream 2026.6.1 arm64' "${notanar}"; then
  fail "a NON-AR file passed the identity assertion"
fi
ok "corrupt: a non-ar file fails the assertion"

nocontrol="${WORK}/nocontrol.deb"
( cd "${WORK}" && printf '2.0\n' >db && tar -czf empty.tar.gz db && ar rc "${nocontrol}" db empty.tar.gz )
[[ "$(lib_eval 'deb_pkg_arch "$1"' "${nocontrol}")" == "" ]] \
  || fail "an archive with no control member produced an architecture"
if lib_eval 'assert_deb_identity "$1" cerastream 2026.6.1 arm64' "${nocontrol}"; then
  fail "an archive with NO CONTROL MEMBER passed the identity assertion"
fi
ok "corrupt: an archive without a control member fails the assertion"

if lib_eval 'explode_deb "$1" "$2"' "${notanar}" "${WORK}/nowhere" >/dev/null 2>&1; then
  fail "explode_deb silently succeeded on a non-ar file"
fi
ok "corrupt: explode_deb fails loudly on a non-ar file"

printf '\ndeb-lib: %d checks passed\n' "${PASS}"
