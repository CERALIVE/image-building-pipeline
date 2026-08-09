#!/usr/bin/env bash
#
# kernel-freeze-guardrails.test.sh — guard that the shipped image freezes its boot
# stack (kernel / DTB / U-Boot / firmware) against on-device apt, and that it never
# freezes a first-party CeraLive package.
#
# WHY THIS EXISTS. `docs/partition-contract.md` rule 3 puts kernel/DTB/initrd
# INSIDE each RAUC rootfs slot, so the only sanctioned way to change them is a
# full-image update that writes a whole new slot. Nothing enforced that: the image
# shipped with zero dpkg holds, so `apt-get upgrade` on a running device would
# happily replace the kernel underneath a slot the A/B selector had already
# committed to. postinst-lib.sh::freeze_boot_packages bakes the guardrails; this
# file proves they are baked, that they actually stop apt, and — the inverse that
# matters just as much — that cerastream / CeraUI / srtla-send-rs stay upgradable.
#
# PART A  static contract   — the freeze function and its wiring exist as shipped.
# PART B  runtime behaviour — the REAL function against stubbed dpkg/apt-mark:
#                             correct hold set, correct pin file, nothing extra.
# PART C  fail-closed legs  — first-party package in the freeze set aborts; a hold
#                             that does not land aborts; a missing boot package on
#                             a full build aborts; a parity build skips cleanly.
# PART D  real apt proof    — a synthetic apt root with a NEWER kernel available:
#                             `apt-get -s upgrade` must not offer it (held, and
#                             separately pin-only), while cerastream must still be
#                             offered. Auto-skipped where apt is unavailable.
# PART E  built rootfs      — opt-in: assert the holds in a real emitted image.
#                             Set CERALIVE_FREEZE_ROOTFS_TAR=<rootfs.tar>.
#
# shellcheck disable=SC2016

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2="$(cd "${HERE}/.." && pwd)"
LIB="${V2}/mkosi/customize/postinst-lib.sh"
POSTINST_D="${V2}/mkosi/customize/postinst.d"
POSTINST="${V2}/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"
PREF_PATH_TAIL="preferences.d/ceralive-kernel-freeze"

fail() { printf 'kernel-freeze-guardrails regression: %s\n' "$1" >&2; exit 1; }
pass() { printf 'kernel-freeze: %s\n' "$1"; }

[[ -f "${LIB}" ]] || fail "missing ${LIB}"
[[ -d "${POSTINST_D}" ]] || fail "missing module dir: ${POSTINST_D}"
[[ -f "${POSTINST}" ]] || fail "missing runtime executor: ${POSTINST}"

# postinst-lib.sh is the thin entry that SOURCES the per-concern modules under
# postinst.d/, so Part B keeps sourcing it — but freeze_boot_packages itself lives
# in a module, and extracting from the entry alone would leave every Part A
# assertion below matching an empty body.
#
# Materialized ONCE into a variable, never piped: the reader below stops early,
# which closes the pipe, kills `cat` with SIGPIPE, and `set -o pipefail` then
# reports a correct read as a failure. Whether it fires depends on the unread
# bytes left against the 64 KiB pipe buffer, so the pipe form survives until a
# module is added and then breaks a test unrelated to the change.
POSTINST_SRC="$(cat "${LIB}" "${POSTINST_D}"/*.sh)"

TMPROOT="$(mktemp -d)"
trap 'rm -rf "${TMPROOT}"' EXIT

# ---------------------------------------------------------------------------
# PART A — static contract
# ---------------------------------------------------------------------------
fn_body="$(awk '
  /^freeze_boot_packages\(\) \{/ { f=1 }
  f { print }
  f && /^\}/ { exit }
' <<<"${POSTINST_SRC}")"
[[ -n "${fn_body}" ]] || fail "could not extract freeze_boot_packages() from the postinst library"

# Assert against the EXECUTABLE body: the header prose names both apt-mark forms
# while explaining them, so grepping the whole function lets a deleted call pass.
fn_code="$(grep -vE "^[[:space:]]*#|printf '#" <<<"${fn_body}")"
grep -q 'apt-mark hold' <<<"${fn_code}" \
  || fail "freeze_boot_packages() no longer runs 'apt-mark hold' — the dpkg hold is the PRIMARY freeze mechanism"
grep -q 'apt-mark showhold' <<<"${fn_code}" \
  || fail "freeze_boot_packages() no longer VERIFIES the holds landed — a silently-unapplied hold ships an apt-upgradable kernel"
grep -q 'CERALIVE_APT_PREFERENCES_DIR:-/etc/apt/preferences.d' <<<"${fn_body}" \
  || fail "freeze_boot_packages() no longer defaults its preferences dir to /etc/apt/preferences.d"
grep -q '/ceralive-kernel-freeze' <<<"${fn_body}" \
  || fail "freeze_boot_packages() no longer writes /etc/apt/${PREF_PATH_TAIL}"
grep -q 'Pin: version' <<<"${fn_body}" \
  || fail "freeze_boot_packages() no longer emits a name+version pin ('Pin: version <installed>')"
grep -q 'Pin-Priority: 1001' <<<"${fn_body}" \
  || fail "freeze_boot_packages() no longer emits Pin-Priority: 1001"
grep -q 'Pin: origin' <<<"${fn_code}" \
  && fail "freeze_boot_packages() emits an origin pin — locally-installed boot .debs carry NO apt-origin identity on the device, so an origin pin can never match them"

# The freeze set must come from the resolved manifest, never a hardcoded name:
# the U-Boot package differs per board (linux-u-boot-rock-5b-plus-vendor vs
# linux-u-boot-orangepi5-plus-vendor), so a literal would freeze one board only.
for var in KERNEL_PACKAGES DTB_PACKAGES UBOOT_PACKAGES FIRMWARE_PACKAGES; do
  grep -q "\${${var}" <<<"${fn_body}" \
    || fail "freeze_boot_packages() no longer reads \$${var} — the freeze set must come from the resolved manifest"
done
grep -Eq 'linux-image-vendor-rk35xx|linux-u-boot-|armbian-firmware' <<<"${fn_body}" \
  && fail "freeze_boot_packages() hardcodes a BSP package name — the set is manifest-resolved so every board (and the per-board U-Boot package) is covered"

# Every first-party package must be refused by name.
never="$(sed -n 's/^CERALIVE_NEVER_FREEZE_PKGS=.*:-\(.*\)}"$/\1/p' <<<"${POSTINST_SRC}")"
[[ -n "${never}" ]] || fail "could not read CERALIVE_NEVER_FREEZE_PKGS from the postinst library"
for pkg in cerastream ceralive-device srtla-send-rs libsrt1.5-ceralive gstreamer1.0-libuvch264src modemmanager; do
  [[ " ${never} " == *" ${pkg} "* ]] \
    || fail "CERALIVE_NEVER_FREEZE_PKGS does not protect '${pkg}' — a first-party package could be frozen and would stop being apt-updatable"
done

grep -qE '^  freeze_boot_packages( |$)' "${POSTINST}" \
  || fail "the runtime executor's main() no longer calls freeze_boot_packages — the guardrails would never ship (run-all.sh's runtime modules are NOT run by ./v2/build)"
# It must run after every apt transaction this layer performs, so the pinned
# versions are the final ones. setup_hawkbit_updater() apt-get installs a .deb.
main_order="$(awk '/^main\(\) \{/,/^\}/' "${POSTINST}")"
if [[ "$(grep -n 'freeze_boot_packages' <<<"${main_order}" | cut -d: -f1)" \
      -lt "$(grep -n 'setup_hawkbit_updater' <<<"${main_order}" | cut -d: -f1)" ]]; then
  fail "freeze_boot_packages runs BEFORE setup_hawkbit_updater in main() — it must run after every apt transaction in this layer"
fi

pass "Part A static contract OK (manifest-resolved hold set, verified holds, name+version pin, first-party refused, executor wired last)"

# ---------------------------------------------------------------------------
# PART B/C — run the REAL function against stubbed dpkg-query / apt-mark
# ---------------------------------------------------------------------------
# harness <name> — build an isolated stub dir + state file for one scenario.
make_stubs() {
  local dir="$1" installed="$2" holds_land="${3:-1}"
  mkdir -p "${dir}/bin"
  printf '%s\n' "${installed}" >"${dir}/installed"
  : >"${dir}/holds"
  cat >"${dir}/bin/dpkg-query" <<'STUB'
#!/usr/bin/env bash
# Only the -W -f='${db:Status-Status} ${Version}' <pkg> form the freeze uses.
pkg="${!#}"
while read -r line; do
  name="${line%% *}"; ver="${line##* }"
  [[ "${name}" == "${pkg}" ]] || continue
  printf 'installed %s' "${ver}"
  exit 0
done <"${CERALIVE_STUB_DIR}/installed"
exit 1
STUB
  cat >"${dir}/bin/apt-mark" <<STUB
#!/usr/bin/env bash
case "\$1" in
  hold)
    shift
    if [[ "${holds_land}" == "1" ]]; then printf '%s\n' "\$@" >>"\${CERALIVE_STUB_DIR}/holds"; fi
    ;;
  showhold) sort -u "\${CERALIVE_STUB_DIR}/holds" ;;
  *) echo "unexpected apt-mark \$*" >&2; exit 2 ;;
esac
STUB
  chmod +x "${dir}/bin/dpkg-query" "${dir}/bin/apt-mark"
}

# run_freeze <stubdir> <prefdir> -- runs the real function with the caller's env.
run_freeze() {
  local stub="$1" prefdir="$2"
  CERALIVE_STUB_DIR="${stub}" PATH="${stub}/bin:${PATH}" \
  CERALIVE_APT_PREFERENCES_DIR="${prefdir}" \
  KERNEL_PACKAGES="${KERNEL_PACKAGES:-}" DTB_PACKAGES="${DTB_PACKAGES:-}" \
  UBOOT_PACKAGES="${UBOOT_PACKAGES:-}" FIRMWARE_PACKAGES="${FIRMWARE_PACKAGES:-}" \
  INSTALL_BOOT_BSP="${INSTALL_BOOT_BSP:-1}" \
  bash -c '
    set -euo pipefail
    log() { :; }
    die() { printf "DIE: %s\n" "$*" >&2; exit 9; }
    source "'"${LIB}"'"
    freeze_boot_packages
  '
}

# --- B1: the happy path, modelled on the real rock-5b-plus resolve ------------
B1="${TMPROOT}/b1"; mkdir -p "${B1}/etc/apt/preferences.d"
make_stubs "${B1}" "linux-image-vendor-rk35xx 26.5.1
linux-dtb-vendor-rk35xx 26.5.1
linux-u-boot-rock-5b-plus-vendor 26.5.1
armbian-firmware 26.8.1
libmali-valhall-g610-g24p0-wayland-gbm 1.9-1
cerastream 2026.6.1
ceralive-device 2026.6.4"
KERNEL_PACKAGES="linux-image-vendor-rk35xx" \
DTB_PACKAGES="linux-dtb-vendor-rk35xx" \
UBOOT_PACKAGES="linux-u-boot-rock-5b-plus-vendor" \
FIRMWARE_PACKAGES="armbian-firmware libmali-valhall-g610-g24p0-wayland-gbm" \
  run_freeze "${B1}" "${B1}/etc/apt/preferences.d" >/dev/null

held_b1="$(sort -u "${B1}/holds" | tr '\n' ' ')"
expected_b1="armbian-firmware libmali-valhall-g610-g24p0-wayland-gbm linux-dtb-vendor-rk35xx linux-image-vendor-rk35xx linux-u-boot-rock-5b-plus-vendor "
[[ "${held_b1}" == "${expected_b1}" ]] \
  || fail "B1 hold set wrong.\n  got:      ${held_b1}\n  expected: ${expected_b1}"
for pkg in cerastream ceralive-device; do
  grep -qxF "${pkg}" "${B1}/holds" \
    && fail "B1 froze the first-party package '${pkg}' — it must stay apt-updatable"
done

pref_b1="${B1}/etc/apt/preferences.d/ceralive-kernel-freeze"
[[ -f "${pref_b1}" ]] || fail "B1 did not write ${pref_b1}"
grep -qxF 'Package: linux-image-vendor-rk35xx' "${pref_b1}" || fail "B1 pin file missing the kernel package stanza"
grep -qxF 'Pin: version 26.5.1' "${pref_b1}" || fail "B1 pin file does not pin the INSTALLED version (26.5.1)"
grep -qxF 'Package: linux-u-boot-rock-5b-plus-vendor' "${pref_b1}" || fail "B1 pin file missing the board U-Boot package"
grep -qxF 'Pin: version 26.8.1' "${pref_b1}" || fail "B1 pin file does not carry armbian-firmware's own installed version"
[[ "$(grep -c '^Pin-Priority: 1001$' "${pref_b1}")" == "5" ]] \
  || fail "B1 pin file should carry exactly 5 pinned packages"
grep -q 'LIMITATION' "${pref_b1}" \
  || fail "B1 pin file does not document the pin's bypass limitation"
grep -q 'RAUC' "${pref_b1}" \
  || fail "B1 pin file does not name the RAUC-only update contract"
grep -qE '^Package: (cerastream|ceralive-device)$' "${pref_b1}" \
  && fail "B1 pinned a first-party package"
grep -qE '^Pin: (origin|release) ' "${pref_b1}" \
  && fail "B1 emitted an origin/release pin — the staged local boot .debs have no apt-origin identity for one to match"

pass "Part B1 OK (5 boot packages held + pinned to their installed versions; cerastream/ceralive-device untouched)"

# --- B2: the OTHER board's U-Boot package, same code path --------------------
B2="${TMPROOT}/b2"; mkdir -p "${B2}/prefs"
make_stubs "${B2}" "linux-image-vendor-rk35xx 26.5.1
linux-dtb-vendor-rk35xx 26.5.1
linux-u-boot-orangepi5-plus-vendor 26.5.1
armbian-firmware 26.8.1
libmali-valhall-g610-g24p0-wayland-gbm 1.9-1"
KERNEL_PACKAGES="linux-image-vendor-rk35xx" \
DTB_PACKAGES="linux-dtb-vendor-rk35xx" \
UBOOT_PACKAGES="linux-u-boot-orangepi5-plus-vendor" \
FIRMWARE_PACKAGES="armbian-firmware libmali-valhall-g610-g24p0-wayland-gbm" \
  run_freeze "${B2}" "${B2}/prefs" >/dev/null
grep -qxF 'linux-u-boot-orangepi5-plus-vendor' "${B2}/holds" \
  || fail "B2 did not hold the orange-pi-5-plus U-Boot package — the per-board name is not being picked up from the manifest"
grep -qxF 'linux-u-boot-rock-5b-plus-vendor' "${B2}/holds" \
  && fail "B2 held the WRONG board's U-Boot package"

pass "Part B2 OK (per-board U-Boot package resolved from the manifest, not hardcoded)"

# --- C1: a first-party package in the freeze set must ABORT ------------------
C1="${TMPROOT}/c1"; mkdir -p "${C1}/prefs"
make_stubs "${C1}" "linux-image-vendor-rk35xx 26.5.1
cerastream 2026.6.1"
if KERNEL_PACKAGES="linux-image-vendor-rk35xx" FIRMWARE_PACKAGES="cerastream" \
     run_freeze "${C1}" "${C1}/prefs" >"${C1}/out" 2>"${C1}/err"; then
  fail "C1: freeze_boot_packages ACCEPTED a first-party package (cerastream) in the freeze set"
fi
grep -q "refusing to hold first-party package 'cerastream'" "${C1}/err" \
  || fail "C1 aborted but not with the first-party refusal: $(cat "${C1}/err")"
[[ -s "${C1}/holds" ]] && fail "C1 held something before aborting — the guard must run before any hold"

pass "Part C1 OK (a first-party package in the boot-BSP fields aborts the build, holding nothing)"

# --- C2: a hold that does not land must ABORT --------------------------------
C2="${TMPROOT}/c2"; mkdir -p "${C2}/prefs"
make_stubs "${C2}" "linux-image-vendor-rk35xx 26.5.1" 0
if KERNEL_PACKAGES="linux-image-vendor-rk35xx" \
     run_freeze "${C2}" "${C2}/prefs" >"${C2}/out" 2>"${C2}/err"; then
  fail "C2: a hold that silently did not land was accepted — that ships an apt-upgradable kernel"
fi
grep -q 'did not land' "${C2}/err" || fail "C2 aborted but not on the hold verification: $(cat "${C2}/err")"
[[ -f "${C2}/prefs/ceralive-kernel-freeze" ]] \
  && fail "C2 wrote the pin file despite the hold not landing"

pass "Part C2 OK (a hold that does not land fails the build; no pin file is written)"

# --- C3: full device build with a declared-but-absent boot package -> ABORT ---
C3="${TMPROOT}/c3"; mkdir -p "${C3}/prefs"
make_stubs "${C3}" "linux-image-vendor-rk35xx 26.5.1"
if KERNEL_PACKAGES="linux-image-vendor-rk35xx" DTB_PACKAGES="linux-dtb-vendor-rk35xx" \
   INSTALL_BOOT_BSP=1 run_freeze "${C3}" "${C3}/prefs" >"${C3}/out" 2>"${C3}/err"; then
  fail "C3: INSTALL_BOOT_BSP=1 with an uninstalled declared boot package was accepted — the freeze would be silently partial"
fi
grep -q 'linux-dtb-vendor-rk35xx' "${C3}/err" || fail "C3 abort message does not name the absent package: $(cat "${C3}/err")"

# --- C4: parity build (INSTALL_BOOT_BSP=0) skips cleanly ---------------------
C4="${TMPROOT}/c4"; mkdir -p "${C4}/prefs"
make_stubs "${C4}" ""
KERNEL_PACKAGES="linux-image-vendor-rk35xx" DTB_PACKAGES="linux-dtb-vendor-rk35xx" \
  INSTALL_BOOT_BSP=0 run_freeze "${C4}" "${C4}/prefs" >/dev/null \
  || fail "C4: a kernel-less parity build (INSTALL_BOOT_BSP=0) must not fail the freeze"
[[ -s "${C4}/holds" ]] && fail "C4 held a package that is not installed"
[[ -f "${C4}/prefs/ceralive-kernel-freeze" ]] \
  && fail "C4 wrote a pin file on a parity build with nothing installed"

pass "Part C3/C4 OK (partial freeze on a full build aborts; a parity build is a clean no-op)"

# ---------------------------------------------------------------------------
# PART D — real apt proof: a simulated upgrade cannot touch the frozen packages
# ---------------------------------------------------------------------------
if ! command -v apt-get >/dev/null 2>&1 || ! command -v dpkg-deb >/dev/null 2>&1; then
  echo "kernel-freeze: apt-get/dpkg-deb unavailable on this host — skipping Part D (run it on a Debian host or in the builder container)"
  echo "kernel-freeze-guardrails regression: PASS (Parts A-C; D skipped)"
  exit 0
fi

APTROOT="${TMPROOT}/apt"
REPO="${APTROOT}/repo"
mkdir -p "${REPO}" "${APTROOT}/lists/partial" "${APTROOT}/cache/archives/partial" \
         "${APTROOT}/etc/preferences.d" "${APTROOT}/etc/sources.list.d"

# Two packages, each with a NEWER version available than the one "installed":
# the kernel (frozen) and cerastream (must stay upgradable).
build_deb() {
  local name="$1" version="$2" root="${APTROOT}/pkg/${1}"
  rm -rf "${root}"; mkdir -p "${root}/DEBIAN"
  cat >"${root}/DEBIAN/control" <<CTRL
Package: ${name}
Version: ${version}
Architecture: all
Maintainer: CeraLive test fixture <noreply@ceralive.tv>
Description: kernel-freeze test fixture
CTRL
  dpkg-deb --build --root-owner-group "${root}" "${REPO}/${name}_${version}_all.deb" >/dev/null
}
build_deb linux-image-vendor-rk35xx 99.9.9
# CalVer: the available version must sort ABOVE the installed 2026.6.1, and dpkg
# compares the leading numeric component, so "99.9.9" would be a DOWNGRADE here.
build_deb cerastream 2026.9.9

: >"${REPO}/Packages"
for deb in "${REPO}"/*.deb; do
  {
    dpkg-deb -f "${deb}"
    printf 'Filename: %s\n' "$(basename "${deb}")"
    printf 'Size: %s\n' "$(stat -c%s "${deb}")"
    printf 'SHA256: %s\n' "$(sha256sum "${deb}" | cut -d' ' -f1)"
    printf '\n'
  } >>"${REPO}/Packages"
done
printf 'deb [trusted=yes] file://%s ./\n' "${REPO}" >"${APTROOT}/etc/sources.list"

# The device's dpkg status: both packages installed at an OLDER version. The
# kernel carries the dpkg HOLD the image bakes; cerastream deliberately does not.
write_status() {
  local kernel_status="$1"
  cat >"${APTROOT}/status" <<STATUS
Package: linux-image-vendor-rk35xx
Status: ${kernel_status}
Priority: optional
Section: kernel
Installed-Size: 1
Maintainer: CeraLive test fixture <noreply@ceralive.tv>
Architecture: all
Version: 26.5.1
Description: kernel-freeze test fixture

Package: cerastream
Status: install ok installed
Priority: optional
Section: video
Installed-Size: 1
Maintainer: CeraLive test fixture <noreply@ceralive.tv>
Architecture: all
Version: 2026.6.1
Description: kernel-freeze test fixture
STATUS
}

apt_sim() {
  apt-get -qq \
    -o Dir::Etc::sourcelist="${APTROOT}/etc/sources.list" \
    -o Dir::Etc::sourceparts="${APTROOT}/etc/sources.list.d" \
    -o Dir::Etc::preferences="${APTROOT}/etc/preferences" \
    -o Dir::Etc::preferencesparts="${APTROOT}/etc/preferences.d" \
    -o Dir::State::lists="${APTROOT}/lists" \
    -o Dir::State::status="${APTROOT}/status" \
    -o Dir::Cache="${APTROOT}/cache" \
    -o Acquire::Languages=none \
    -o APT::Get::AllowUnauthenticated=true \
    "$@"
}

# --- D0 non-vacuity: with NO freeze at all, apt DOES offer the kernel upgrade -
: >"${APTROOT}/etc/preferences"
rm -f "${APTROOT}/etc/preferences.d/"*
write_status "install ok installed"
apt_sim update >/dev/null 2>&1
d0="$(apt_sim -s upgrade 2>&1 || true)"
grep -q '^Inst linux-image-vendor-rk35xx' <<<"${d0}" \
  || fail "D0 non-vacuity FAILED: apt does not offer the kernel upgrade even without a freeze, so the fixture proves nothing.\n${d0}"

pass "Part D0 OK (non-vacuity: unfrozen, 'apt-get -s upgrade' DOES offer linux-image-vendor-rk35xx 26.5.1 -> 99.9.9)"

# --- D1 the dpkg hold alone stops it -----------------------------------------
write_status "hold ok installed"
d1="$(apt_sim -s upgrade 2>&1 || true)"
grep -q '^Inst linux-image-vendor-rk35xx' <<<"${d1}" \
  && fail "D1: the dpkg hold did NOT stop 'apt-get -s upgrade' from replacing the kernel.\n${d1}"

# …and it also stops the EXPLICIT install form, which the pin cannot.
d1b="$(apt_sim -s install linux-image-vendor-rk35xx 2>&1 || true)"
grep -q '^Inst linux-image-vendor-rk35xx' <<<"${d1b}" \
  && fail "D1: the dpkg hold did NOT stop an explicit 'apt-get install linux-image-vendor-rk35xx'.\n${d1b}"

pass "Part D1 OK (dpkg hold blocks both 'upgrade' and an explicit 'install' of the kernel)"

# --- D2 the supplementary name+version pin alone also stops it ---------------
# Generated by the REAL function, from the REAL installed version, so this tests
# the shipped pin format rather than a hand-written approximation.
write_status "install ok installed"
D2="${TMPROOT}/d2"; make_stubs "${D2}" "linux-image-vendor-rk35xx 26.5.1"
KERNEL_PACKAGES="linux-image-vendor-rk35xx" \
  run_freeze "${D2}" "${APTROOT}/etc/preferences.d" >/dev/null
[[ -f "${APTROOT}/etc/preferences.d/ceralive-kernel-freeze" ]] \
  || fail "D2: the freeze function wrote no pin file into the synthetic apt root"
d2="$(apt_sim -s upgrade 2>&1 || true)"
grep -q '^Inst linux-image-vendor-rk35xx' <<<"${d2}" \
  && fail "D2: the shipped name+version pin did NOT hold the kernel at its installed version.\n${d2}"

pass "Part D2 OK (the shipped name+version pin alone holds the kernel, with no dpkg hold in play)"

# --- D3 first-party packages stay upgradable WITH the freeze file present -----
grep -q '^Inst cerastream' <<<"${d2}" \
  || fail "D3: cerastream is NOT offered for upgrade while the kernel-freeze pin file is installed — the app layer must stay apt-updatable.\n${d2}"
write_status "hold ok installed"
d3="$(apt_sim -s install cerastream 2>&1 || true)"
grep -q '^Inst cerastream' <<<"${d3}" \
  || fail "D3: 'apt-get install cerastream' is blocked with the freeze in place — CeraLive app packages must stay apt-updatable.\n${d3}"

pass "Part D3 OK (cerastream still upgrades and installs with the kernel freeze fully in place)"

# ---------------------------------------------------------------------------
# PART E — opt-in assertion against a REAL emitted rootfs
# ---------------------------------------------------------------------------
if [[ -n "${CERALIVE_FREEZE_ROOTFS_TAR:-}" ]]; then
  [[ -f "${CERALIVE_FREEZE_ROOTFS_TAR}" ]] \
    || fail "CERALIVE_FREEZE_ROOTFS_TAR is set but not a file: ${CERALIVE_FREEZE_ROOTFS_TAR}"
  E="${TMPROOT}/e"; mkdir -p "${E}"
  tar -xf "${CERALIVE_FREEZE_ROOTFS_TAR}" -C "${E}" ./var/lib/dpkg/status "./etc/apt/${PREF_PATH_TAIL}" 2>/dev/null \
    || tar -xf "${CERALIVE_FREEZE_ROOTFS_TAR}" -C "${E}" var/lib/dpkg/status "etc/apt/${PREF_PATH_TAIL}" \
    || fail "could not extract dpkg status + the freeze pin file from ${CERALIVE_FREEZE_ROOTFS_TAR}"

  status_file="${E}/var/lib/dpkg/status"
  held_in_image="$(awk '/^Package: /{p=$2} /^Status: hold /{print p}' "${status_file}" | sort -u)"
  for pkg in linux-image-vendor-rk35xx linux-dtb-vendor-rk35xx armbian-firmware; do
    grep -qxF "${pkg}" <<<"${held_in_image}" \
      || fail "E: '${pkg}' is NOT held in the built rootfs — the shipped image's kernel can be replaced by apt"
  done
  grep -qE '^linux-u-boot-.*-vendor$' <<<"${held_in_image}" \
    || fail "E: no board U-Boot package is held in the built rootfs"
  for pkg in cerastream ceralive-device srtla-send-rs libsrt1.5-ceralive; do
    grep -qxF "${pkg}" <<<"${held_in_image}" \
      && fail "E: first-party package '${pkg}' is HELD in the built rootfs — it must stay apt-updatable"
  done
  grep -q '^Pin-Priority: 1001$' "${E}/etc/apt/${PREF_PATH_TAIL}" \
    || fail "E: the built rootfs carries no name+version pin"
  pass "Part E OK (real rootfs: boot stack held, first-party packages untouched) — $(basename "${CERALIVE_FREEZE_ROOTFS_TAR}")"
else
  echo "kernel-freeze: CERALIVE_FREEZE_ROOTFS_TAR unset — skipping Part E (built-image assertion)"
fi

echo "kernel-freeze-guardrails regression: PASS"
