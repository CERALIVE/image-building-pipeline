#!/usr/bin/env bash
#
# app-build-logs-dropped.test.sh — the finished rootfs must not carry the build's
# apt and dpkg transcripts.
#
# They record how the image was assembled (build timestamps, full dpkg output),
# nothing on the device reads them, and first boot copies /var/log into /data/log
# once, so they would also be seeded onto the data partition. Everything else under
# /var/log, and the /var/log/apt directory itself, must stay.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "${here}/.." && pwd)"
APP_POSTINST="${repo}/mkosi/mkosi.images/app/mkosi.postinst.chroot"
# shellcheck source=tests/lib/assertions.sh
source "${repo}/tests/lib/assertions.sh"

work=''
finish() {
  local status=$?
  [[ "${status}" -eq 0 || "${FAIL}" -gt 0 ]] || bad "unexpected exit: ${status}"
  [[ -z "${work}" ]] || rm -rf "${work}"
  printf ' RESULT: %d passed, %d failed\n' "${PASS}" "${FAIL}"
  [[ "${FAIL}" -eq 0 ]]
}
trap 'finish; exit $?' EXIT

# --- static: the drop runs in main(), after the last apt/dpkg transaction -----
app_main="$(awk '/^main\(\) \{/{f=1} f{print} f && /^\}/{exit}' "${APP_POSTINST}")"
line_of() { grep -n "^[[:space:]]*$1" <<<"${app_main}" | head -1 | cut -d: -f1; }
install_l="$(line_of install_first_party_apps)"; lock_l="$(line_of 'bash "\${SRCDIR')"
clean_l="$(line_of clean_package_download_metadata)"; drop_l="$(line_of drop_build_package_logs)"
if [[ -n "${install_l}" && -n "${lock_l}" && -n "${clean_l}" && -n "${drop_l}" ]] \
  && (( install_l < lock_l && lock_l < clean_l && clean_l < drop_l )); then
  ok 'drop_build_package_logs runs after the app install, the lock capture and the apt clean'
else
  bad "main() order is not install < lock capture < clean < drop (${install_l:-?} ${lock_l:-?} ${clean_l:-?} ${drop_l:-?})"
fi

# --- behaviour on a scratch /var/log ---------------------------------------
work="$(mktemp -d "${TMPDIR:-/var/tmp}/app-build-logs.XXXXXX")" || { bad 'fixture: mktemp'; exit 1; }
logs="${work}/var/log"
mkdir -p "${logs}/apt" "${logs}/journal" "${logs}/nginx"
for f in dpkg.log dpkg.log.1 dpkg.log.2.gz alternatives.log alternatives.log.1 \
         apt/history.log apt/term.log apt/eipp.log.xz apt/history.log.1.gz; do
  printf 'build\n' >"${logs}/${f}"
done
for f in btmp wtmp lastlog fontconfig.log README nginx/access.log; do printf 'keep\n' >"${logs}/${f}"; done

( # shellcheck source=mkosi/mkosi.images/app/mkosi.postinst.chroot
  source "${APP_POSTINST}"
  BUILD_LOG_DIR="${logs}" drop_build_package_logs
) >/dev/null 2>&1 && ok 'drop_build_package_logs succeeds' || bad 'drop_build_package_logs failed'

left="$(cd "${logs}" && ls dpkg.log* alternatives.log* apt/* 2>/dev/null | wc -l)"
assert_eq 'no apt, dpkg or alternatives log remains' 0 "${left}"
[[ -d "${logs}/apt" ]] && ok '/var/log/apt directory is kept' || bad '/var/log/apt was removed'
[[ -d "${logs}/journal" && -d "${logs}/nginx" ]] && ok 'journal/ and nginx/ are kept' || bad 'an unrelated log directory was removed'
kept=0
for f in btmp wtmp lastlog fontconfig.log README nginx/access.log; do [[ -f "${logs}/${f}" ]] && kept=$((kept + 1)); done
assert_eq 'unrelated log files are untouched' 6 "${kept}"

# idempotent, and tolerant of a tree without /var/log/apt
rm -rf "${logs}/apt"
( source "${APP_POSTINST}"; BUILD_LOG_DIR="${logs}" drop_build_package_logs ) >/dev/null 2>&1 \
  && ok 'a second run on a tree without /var/log/apt succeeds' || bad 'drop_build_package_logs is not idempotent'

[[ "${FAIL}" -eq 0 ]]
