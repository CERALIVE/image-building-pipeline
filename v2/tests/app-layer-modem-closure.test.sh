#!/usr/bin/env bash
#
# app-layer-modem-closure.test.sh — executable guard that the APP layer installs
# the ModemManager 1.24 closure as runtime-abi packages.
#
# THE CONTRACT THIS PROVES. The nine fork .debs (modemmanager, libmm-glib0,
# libmbim-glib4/proxy/utils, libqmi-glib5/proxy/utils, libqrtr-glib0) are staged
# first-party and MUST be classified RUNTIME_APP_PKGS by
# mkosi.images/app/mkosi.postinst.chroot::install_first_party_apps — never
# SYSEXT/APPFS, never "unclassified" (which is a fatal build error). This test
# sources that function (the script's `main` is BASH_SOURCE-guarded so its
# destructive prune/clean steps never run here), stages fake staged .debs, stubs
# the package tools, and asserts the classification + a clean local install.
#
# Positive: the 9 closure debs each log `runtime-abi` and the transaction runs.
# Negative: a deb whose Package: name is in NO class dies with "unclassified".
#
# shellcheck disable=SC2317  # stub function bodies are reached via PATH, not calls

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2="$(cd "${HERE}/.." && pwd)"
APP_POSTINST="${V2}/mkosi/mkosi.images/app/mkosi.postinst.chroot"

fail() { printf 'app-layer-modem-closure regression: %s\n' "$1" >&2; exit 1; }

[[ -f "${APP_POSTINST}" ]] || fail "missing app postinst: ${APP_POSTINST}"

RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/app-layer-modem-closure.XXXXXX")"
trap 'rm -rf "${RUN_DIR}"' EXIT

MODEM_CLOSURE=(
  modemmanager libmm-glib0
  libmbim-glib4 libmbim-proxy libmbim-utils
  libqmi-glib5 libqmi-proxy libqmi-utils
  libqrtr-glib0
)

# Fake package tools on PATH: dpkg-deb maps a staged file back to the Package name
# encoded in its filename (<pkg>_<ver>_<arch>.deb); dpkg/apt-get/dpkg-query are
# success no-ops so the classification loop — the unit under test — decides the
# outcome, not a real install.
STUB_BIN="${RUN_DIR}/bin"
mkdir -p "${STUB_BIN}"
cat >"${STUB_BIN}/dpkg-deb" <<'SH'
#!/usr/bin/env bash
# `dpkg-deb -f <file> Package` -> the pkg name from "<pkg>_<ver>_<arch>.deb".
if [[ "${1:-}" == "-f" && "${3:-}" == "Package" ]]; then
  base="$(basename "$2")"
  printf '%s\n' "${base%%_*}"
  exit 0
fi
exit 0
SH
printf '#!/usr/bin/env bash\nexit 0\n' >"${STUB_BIN}/dpkg"
printf '#!/usr/bin/env bash\nexit 0\n' >"${STUB_BIN}/apt-get"
printf '#!/usr/bin/env bash\nexit 0\n' >"${STUB_BIN}/dpkg-query"
printf '#!/usr/bin/env bash\nexit 0\n' >"${STUB_BIN}/systemctl"
chmod +x "${STUB_BIN}"/*

# stage_debs <dir> <pkg...> — create empty staged .deb files named so the stub
# dpkg-deb reads the intended Package name back.
stage_debs() {
  local dir="$1"; shift
  mkdir -p "${dir}"
  local pkg
  for pkg in "$@"; do
    : >"${dir}/${pkg}_1.0-test_arm64.deb"
  done
}

# run_install <staging-dir> — source install_first_party_apps (main stays unrun
# via the BASH_SOURCE guard) and run it against the staged dir. Captures output.
run_install() {
  local dir="$1"
  # The script hardcodes FIRST_PARTY_DIR=/opt/ceralive-staging at source time, so
  # override it AFTER sourcing (and before calling the function under test).
  PATH="${STUB_BIN}:${PATH}" bash -c '
    set -euo pipefail
    log() { printf "[app] %s\n" "$*" >&2; }
    die() { printf "[app] FATAL: %s\n" "$*" >&2; exit 1; }
    source "'"${APP_POSTINST}"'"
    FIRST_PARTY_DIR="'"${dir}"'"
    install_first_party_apps
  ' 2>&1
}

# --- Positive: the 9 closure debs classify as runtime-abi and install ---------
POS_DIR="${RUN_DIR}/staging-positive"
stage_debs "${POS_DIR}" "${MODEM_CLOSURE[@]}"
if ! pos_out="$(run_install "${POS_DIR}")"; then
  printf '%s\n' "${pos_out}" >&2
  fail "install_first_party_apps failed on the modem closure (expected exit 0)"
fi
for pkg in "${MODEM_CLOSURE[@]}"; do
  grep -Fq "runtime-abi  : ${pkg}" <<<"${pos_out}" \
    || { printf '%s\n' "${pos_out}" >&2; fail "closure deb '${pkg}' was not classified runtime-abi"; }
done
grep -Fq 'installing 9 first-party .deb(s)' <<<"${pos_out}" \
  || { printf '%s\n' "${pos_out}" >&2; fail "expected a 9-deb local install transaction"; }
# Non-vacuity: none of the closure debs slipped into the sysext or appfs class.
if grep -Eq 'sysext-class : (modemmanager|lib(mm|mbim|qmi|qrtr))' <<<"${pos_out}" \
   || grep -Eq 'appfs-class  : (modemmanager|lib(mm|mbim|qmi|qrtr))' <<<"${pos_out}"; then
  printf '%s\n' "${pos_out}" >&2
  fail "a closure deb was misclassified as sysext/appfs"
fi
echo "app-layer-modem-closure: PASS positive (9 closure debs classify runtime-abi + install)"

# --- Negative: an unclassified deb is a fatal build error (test has teeth) -----
NEG_DIR="${RUN_DIR}/staging-negative"
stage_debs "${NEG_DIR}" modemmanager not-a-known-first-party-package
if neg_out="$(run_install "${NEG_DIR}")"; then
  printf '%s\n' "${neg_out}" >&2
  fail "an unclassified staged package did NOT fail the build (fail-closed classification broken)"
fi
grep -Fq 'unclassified first-party package in staging: not-a-known-first-party-package' <<<"${neg_out}" \
  || { printf '%s\n' "${neg_out}" >&2; fail "unclassified failure did not name the offending package"; }
echo "app-layer-modem-closure: PASS negative (unclassified deb fails the build)"

echo "app-layer-modem-closure regression: PASS"
