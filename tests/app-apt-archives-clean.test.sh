#!/usr/bin/env bash
#
# app-apt-archives-clean.test.sh — the finished rootfs must not ship downloaded
# packages in /var/cache/apt/archives.
#
# WHY: the runtime layer installs shared.list into apt's default archive
# directory and only afterwards writes 81ceralive-cache, which points the DEVICE's
# apt at /data/ceralive/apt-archives/. The app layer inherits that file, so its
# bare `apt-get clean` cleaned the /data path instead and the slot shipped every
# downloaded .deb. clean_apt_archives names the shipped directory explicitly and
# fails the build if any package is left.
#
# Offline and rootless: real apt-get against a scratch directory, no chroot.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "${here}/.." && pwd)"
APP_POSTINST="${repo}/mkosi/mkosi.images/app/mkosi.postinst.chroot"
RUNTIME_POSTINST="${repo}/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"
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

# --- Part A: static contract -------------------------------------------------
# The cause: packages are installed before the device cache redirect is written.
# (An earlier main() sits inside the ceralive-hawkbit-provision heredoc; take the last one.)
runtime_main="$(awk '/^main\(\) \{/{buf=""} {buf=buf $0 "\n"} /^main\(\) \{/{f=1} f && /^\}/{out=buf; f=0} END{printf "%s", out}' "${RUNTIME_POSTINST}")"
install_line="$(grep -n '^  install_runtime_packages' <<<"${runtime_main}" | cut -d: -f1)"
redirect_line="$(grep -n '^  setup_prune_reprune_and_cache' <<<"${runtime_main}" | cut -d: -f1)"
[[ -n "${install_line}" && -n "${redirect_line}" && "${install_line}" -lt "${redirect_line}" ]] \
  && ok 'runtime layer downloads packages before it redirects the device cache' \
  || bad 'runtime main() order changed; re-check which directory holds the downloaded packages'
grep -Fq 'Dir::Cache::archives "/data/ceralive/apt-archives/"' "${RUNTIME_POSTINST}" \
  && ok 'the device apt cache is redirected to /data (inherited by the app layer)' \
  || bad '81ceralive-cache no longer redirects Dir::Cache::archives; the clean contract may be obsolete'

app_clean="$(awk '/^clean_package_download_metadata\(\) \{/{f=1} f{print} f && /^\}/{exit}' "${APP_POSTINST}")"
[[ -n "${app_clean}" ]] || { bad 'could not extract clean_package_download_metadata()'; exit 1; }
grep -Eq '^[[:space:]]*clean_apt_archives[[:space:]]*$' <<<"${app_clean}" \
  && ok 'clean_package_download_metadata() empties the archives through clean_apt_archives' \
  || bad 'clean_package_download_metadata() no longer calls clean_apt_archives'
grep -Eq '^[[:space:]]*apt-get[[:space:]]+clean' "${APP_POSTINST}" \
  && bad 'a bare "apt-get clean" follows the /data cache redirect and leaves the shipped packages' \
  || ok 'no bare "apt-get clean" in the app layer'

# --- Part B: behaviour -------------------------------------------------------
command -v apt-get >/dev/null 2>&1 || { echo 'app-apt-archives-clean: apt-get unavailable, behaviour leg skipped'; exit 0; }
work="$(mktemp -d "${TMPDIR:-/var/tmp}/apt-archives-clean.XXXXXX")" || { bad 'fixture: mktemp'; exit 1; }
shipped="${work}/var/cache/apt/archives"
mkdir -p "${work}/state/lists/partial" "${work}/etc"
: >"${work}/status"
# The same redirect 81ceralive-cache installs, plus scratch state so apt-get
# never touches the host's /var/lib/apt.
cat >"${work}/etc/apt.conf" <<CONF
Dir::State "${work}/state/";
Dir::State::status "${work}/status";
Dir::Cache "${work}/cache/";
Dir::Cache::pkgcache "";
Dir::Cache::srcpkgcache "";
Dir::Cache::archives "${work}/data/ceralive/apt-archives/";
CONF
fill_archives() {
  rm -rf "${shipped}"; mkdir -p "${shipped}/partial"
  local i; for i in 1 2 3; do printf 'deb %s\n' "${i}" >"${shipped}/pkg${i}_1.0_arm64.deb"; done
}

# Control: the bare command the app layer used to run keeps the packages, so the
# assertions below can fail.
fill_archives
APT_CONFIG="${work}/etc/apt.conf" apt-get clean >/dev/null 2>&1
bare_left="$(find "${shipped}" -name '*.deb' | wc -l)"
assert_eq 'bare apt-get clean under the /data redirect leaves the packages (control)' 3 "${bare_left}"

run_clean() {
  ( # shellcheck source=mkosi/mkosi.images/app/mkosi.postinst.chroot
    source "${APP_POSTINST}"
    export APT_CONFIG="${work}/etc/apt.conf" SHIPPED_APT_ARCHIVES="${shipped}"
    "$@"
  )
}

fill_archives
run_clean clean_apt_archives >/dev/null 2>&1 \
  && ok 'clean_apt_archives succeeds' || bad 'clean_apt_archives failed on a populated archive directory'
assert_eq 'no .deb remains in the shipped archive directory' 0 "$(find "${shipped}" -name '*.deb' | wc -l)"
[[ -d "${shipped}/partial" ]] && ok 'partial/ is kept' || bad 'partial/ was removed'

# Fail closed: if the clean leaves a package behind the build must stop.
fill_archives
clean_that_removes_nothing() { apt-get() { :; }; clean_apt_archives; }
if run_clean clean_that_removes_nothing >"${work}/out" 2>&1; then
  bad 'a package left behind did not fail the build'
else
  grep -q 'downloaded packages remain' "${work}/out" \
    && ok 'a package left behind fails the build with a clear message' \
    || bad "failed without the expected message: $(cat "${work}/out")"
fi

[[ "${FAIL}" -eq 0 ]]
