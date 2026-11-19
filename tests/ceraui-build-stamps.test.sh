#!/usr/bin/env bash
#
# ceraui-build-stamps.test.sh — CeraUI's `revision` and `version` stamps follow
# the booted slot through the /data bind over /opt/ceralive.
#
# THE BUG. CeraUI reads `revision` (its commit) and `version` (its CalVer) from
# its working dir, /opt/ceralive, for the CeraUI row in Settings -> Versions. On
# the device /data/ceralive is bound over that dir, and ceralive-migrate-data
# seeded `revision` onto /data once and never again. After an OTA the row put
# the first image's commit next to the new slot's package version. `version` was
# never seeded, so the stamp CeraUI prefers was hidden on bind-mounted images.
#
# THE FIX. The app layer keeps both stamps in /usr/libexec/ceralive/ceraui-stamps/
# together with the ceralive-device version they came from
# (keep_ceraui_build_stamps, non-fatal, old copies cleared, marker written
# last). On every boot ceralive-migrate-data links /data/ceralive/{revision,version}
# to them while the slot's installed ceralive-device is still that version.
# Otherwise (in-place package upgrade) links to the kept stamps are removed, and
# regular files are kept or removed by the md5sums dpkg-query reports for the
# installed instance; without one valid entry, or when dpkg cannot name the
# package, regular files are left alone.
#
# Part A — the app layer keeps the stamps (sourced function, stubbed dpkg-query).
# Part B — the migrate-data block, extracted verbatim and run on synthetic trees.
# Part C — both halves name the same directory and stamps.
#
# shellcheck disable=SC2016

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"
APP_POSTINST="${PIPELINE_DIR}/mkosi/mkosi.images/app/mkosi.postinst.chroot"
PERSISTENCE="${PIPELINE_DIR}/mkosi/customize/postinst.d/persistence.sh"
STAMPS_REL=usr/libexec/ceralive/ceraui-stamps

fail() { printf 'ceraui-build-stamps regression: %s\n' "$1" >&2; exit 1; }

[[ -f "${APP_POSTINST}" ]] || fail "missing app postinst: ${APP_POSTINST}"
[[ -f "${PERSISTENCE}" ]] || fail "missing persistence module: ${PERSISTENCE}"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ceraui-build-stamps.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

# dpkg-query stub: answers $STUB_DPKG_VERSION for ceralive-device, fails when it
# is unset (package not installed), and records its arguments.
mkdir -p "${TMP}/bin"
cat >"${TMP}/bin/dpkg-query" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_DPKG_LOG:-/dev/null}"
[[ " $* " == *" ceralive-device "* && -n "${STUB_DPKG_VERSION:-}" ]] || exit 1
# --control-show: the md5sums of the installed instance, as dpkg resolves it.
if [[ " $* " == *" --control-show ceralive-device md5sums "* ]]; then
  [[ -f "${STUB_MD5SUMS:-}" ]] || exit 2
  exec cat "${STUB_MD5SUMS}"
fi
printf '%s' "${STUB_DPKG_VERSION}"
STUB
chmod +x "${TMP}/bin/dpkg-query"

# ---------------------------------------------------------------------------
# Part A — app layer
# ---------------------------------------------------------------------------
run_keep() { # $1=root [env...]
  local root="$1"; shift
  env PATH="${TMP}/bin:${PATH}" STUB_DPKG_LOG="${TMP}/dpkg.log" "$@" \
    bash -c 'set -euo pipefail; source "$1"; keep_ceraui_build_stamps "$2"' _ "${APP_POSTINST}" "${root}" \
    2>"${TMP}/keep.log"
}

A1="${TMP}/a1"; mkdir -p "${A1}/opt/ceralive"
printf '3333333\n' >"${A1}/opt/ceralive/revision"
printf '2026.11.3\n' >"${A1}/opt/ceralive/version"
chmod 0600 "${A1}/opt/ceralive/revision"
: >"${TMP}/dpkg.log"
run_keep "${A1}" STUB_DPKG_VERSION=2026.11.3-20261101T120000.3333333 \
  || fail "A1: keep_ceraui_build_stamps failed: $(<"${TMP}/keep.log")"
for name in revision version; do
  cmp -s "${A1}/opt/ceralive/${name}" "${A1}/${STAMPS_REL}/${name}" \
    || fail "A1: no faithful copy of ${name} at /${STAMPS_REL}"
  [[ "$(stat -c '%a' "${A1}/${STAMPS_REL}/${name}")" == 644 ]] \
    || fail "A1: /${STAMPS_REL}/${name} is not world-readable"
  [[ -f "${A1}/opt/ceralive/${name}" ]] || fail "A1: the .deb's own ${name} was moved"
done
[[ "$(<"${A1}/${STAMPS_REL}/package-version")" == 2026.11.3-20261101T120000.3333333 ]] \
  || fail "A1: package-version is '$(<"${A1}/${STAMPS_REL}/package-version")'"
grep -Fq -- "--admindir=${A1}/var/lib/dpkg" "${TMP}/dpkg.log" \
  || fail "A1: the package version was not read from the image's own dpkg database"
echo "ceraui-build-stamps: A1 app layer keeps the stamps OK"

# A CeraUI without stamps is not an error and leaves nothing behind.
A2="${TMP}/a2"; mkdir -p "${A2}/opt/ceralive"
run_keep "${A2}" || fail "A2: a .deb without stamps failed the layer: $(<"${TMP}/keep.log")"
[[ ! -e "${A2}/${STAMPS_REL}" ]] || fail "A2: stamps kept without a source"
echo "ceraui-build-stamps: A2 no stamps, nothing kept OK"

# Stamps without an installed package version would never be linked: the layer
# keeps nothing, and the build goes on.
A3="${TMP}/a3"; mkdir -p "${A3}/opt/ceralive"
printf 'abc1234\n' >"${A3}/opt/ceralive/revision"
run_keep "${A3}" || fail "A3: a missing package version failed the layer: $(<"${TMP}/keep.log")"
[[ ! -e "${A3}/${STAMPS_REL}" ]] || fail "A3: stamps kept without a ceralive-device version"
grep -Fq 'WARN:' "${TMP}/keep.log" || fail "A3: no warning logged"
echo "ceraui-build-stamps: A3 no package version, nothing kept, build continues OK"

# A copy that fails is not fatal either, and leaves no partial directory.
A4="${TMP}/a4"; mkdir -p "${A4}/opt/ceralive" "${TMP}/failbin"
printf '3333333\n' >"${A4}/opt/ceralive/revision"
printf '2026.11.3\n' >"${A4}/opt/ceralive/version"
printf '#!/bin/sh\nexit 1\n' >"${TMP}/failbin/install"; chmod +x "${TMP}/failbin/install"
env PATH="${TMP}/failbin:${TMP}/bin:${PATH}" STUB_DPKG_VERSION=2026.11.3-20261101T120000.3333333 \
  bash -c 'set -euo pipefail; source "$1"; keep_ceraui_build_stamps "$2"' _ "${APP_POSTINST}" "${A4}" \
  2>"${TMP}/keep.log" || fail "A4: a failed copy failed the layer: $(<"${TMP}/keep.log")"
[[ ! -e "${A4}/${STAMPS_REL}" ]] || fail "A4: a partial stamp directory was left behind"
echo "ceraui-build-stamps: A4 a failed copy is non-fatal OK"

# A failed cleanup after a failed lookup is non-fatal too, and what is left
# behind carries no package-version, so the boot side never links it.
A5="${TMP}/a5"; mkdir -p "${A5}/opt/ceralive" "${TMP}/rmfail"
printf '3333333\n' >"${A5}/opt/ceralive/revision"
cat >"${TMP}/rmfail/rm" <<'STUB'
#!/usr/bin/env bash
[[ " $* " == *" -rf "* && -e "${@: -1}" ]] && exit 1
exec /bin/rm "$@"
STUB
chmod +x "${TMP}/rmfail/rm"
env PATH="${TMP}/rmfail:${TMP}/bin:${PATH}" \
  bash -c 'set -euo pipefail; source "$1"; keep_ceraui_build_stamps "$2"; echo continued' _ "${APP_POSTINST}" "${A5}" \
  >"${TMP}/keep.out" 2>"${TMP}/keep.log" || fail "A5: a failed cleanup stopped the layer: $(<"${TMP}/keep.log")"
grep -qx continued "${TMP}/keep.out" || fail "A5: the layer did not continue after a failed cleanup"
[[ ! -e "${A5}/${STAMPS_REL}/package-version" ]] || fail "A5: a package-version marker authorizes leftover copies"
grep -Fq 'could not remove' "${TMP}/keep.log" || fail "A5: the failed cleanup was not logged"
# A marker from an earlier capture is cleared before new copies are made.
A6="${TMP}/a6"; mkdir -p "${A6}/opt/ceralive" "${A6}/${STAMPS_REL}"
printf '3333333\n' >"${A6}/opt/ceralive/revision"
printf 'old\n' >"${A6}/${STAMPS_REL}/package-version"
run_keep "${A6}" || fail "A6: the layer failed: $(<"${TMP}/keep.log")"
[[ ! -e "${A6}/${STAMPS_REL}/package-version" ]] || fail "A6: an earlier marker survived a failed capture"
echo "ceraui-build-stamps: A5 a failed cleanup is non-fatal and leaves no marker OK"

# A reused capture directory: an old copy whose source is gone this time must
# not survive under the new marker.
A7="${TMP}/a7"; mkdir -p "${A7}/opt/ceralive" "${A7}/${STAMPS_REL}"
printf '2026.11.2\n' >"${A7}/${STAMPS_REL}/version"
printf '2222222\n' >"${A7}/${STAMPS_REL}/revision"
printf '2026.11.2-20261020T100000.2222222\n' >"${A7}/${STAMPS_REL}/package-version"
printf '3333333\n' >"${A7}/opt/ceralive/revision"
run_keep "${A7}" STUB_DPKG_VERSION=2026.11.3-20261101T120000.3333333 \
  || fail "A7: the layer failed: $(<"${TMP}/keep.log")"
[[ ! -e "${A7}/${STAMPS_REL}/version" ]] || fail "A7: an old version copy survived under the new marker"
[[ "$(<"${A7}/${STAMPS_REL}/revision")" == 3333333 ]] || fail "A7: the new revision was not kept"
[[ "$(<"${A7}/${STAMPS_REL}/package-version")" == 2026.11.3-20261101T120000.3333333 ]] \
  || fail "A7: the marker does not name this capture's package"
echo "ceraui-build-stamps: A7 a reused directory keeps only this capture's copies OK"

# ---------------------------------------------------------------------------
# Part B — the migrate-data block
# ---------------------------------------------------------------------------
block="$(awk '
  index($0, "CERAUI_STAMPS=/usr/libexec/ceralive/ceraui-stamps") { f=1 }
  f { print }
  f && $0 ~ /^fi$/ { exit }
' "${PERSISTENCE}")"
[[ -n "${block}" ]] || fail "could not extract the CeraUI stamp block from ${PERSISTENCE}"
# It must sit in the generated ceralive-migrate-data, not around it.
awk '/cat >>\/usr\/local\/sbin\/ceralive-migrate-data <<.EOF./{on=1; next} on && /^EOF$/{exit} on' "${PERSISTENCE}" \
  | grep -Fq 'CERAUI_STAMPS=/usr/libexec/ceralive/ceraui-stamps' \
  || fail "the stamp block is not part of the generated ceralive-migrate-data"

run_block() { # $1=box [env...]
  local box="$1"; shift
  local runner="${TMP}/runner.sh"
  {
    echo 'set -euo pipefail'
    echo 'log() { :; }'
    printf 'DATA=%q\n' "${box}/data"
    printf '%s\n' "${block/CERAUI_STAMPS=\/usr\/libexec\/ceralive\/ceraui-stamps/CERAUI_STAMPS=${box}/${STAMPS_REL}}"
  } >"${runner}"
  env PATH="${TMP}/bin:${PATH}" STUB_MD5SUMS="${box}/dpkg-info/ceralive-device.md5sums" "$@" bash "${runner}"
}

PKG4=2026.11.4-20261125T100000.4444444
# A box running the new image: its app layer kept the stamps of the new CeraUI.
# The installed package's md5sums, as dpkg keeps them in /var/lib/dpkg/info.
pkg_sums() { # $1=box $2=revision $3=version
  mkdir -p "$1/dpkg-info"
  printf '%s  opt/ceralive/revision\n%s  opt/ceralive/version\n' \
    "$(printf '%s\n' "$2" | md5sum | awk '{print $1}')" \
    "$(printf '%s\n' "$3" | md5sum | awk '{print $1}')" >"$1/dpkg-info/ceralive-device.md5sums"
}
new_box() { # $1=dir
  mkdir -p "$1/data/ceralive" "$1/${STAMPS_REL}"
  printf '4444444\n' >"$1/${STAMPS_REL}/revision"
  printf '2026.11.4\n' >"$1/${STAMPS_REL}/version"
  printf '%s\n' "${PKG4}" >"$1/${STAMPS_REL}/package-version"
  pkg_sums "$1" 4444444 2026.11.4
}
assert_linked() { # $1=box $2=label
  local name
  for name in revision version; do
    [[ -L "$1/data/ceralive/${name}" && "$(readlink "$1/data/ceralive/${name}")" == "$1/${STAMPS_REL}/${name}" ]] \
      || fail "$2: /data/ceralive/${name} is not a link to this slot's stamp"
  done
  # What CeraUI reads through the bind.
  [[ "$(<"$1/data/ceralive/revision")" == 4444444 && "$(<"$1/data/ceralive/version")" == 2026.11.4 ]] \
    || fail "$2: CeraUI would read revision $(<"$1/data/ceralive/revision") version $(<"$1/data/ceralive/version")"
}

# B1: the OTA case. /data was seeded by the older image (a regular revision
# file, no version); after the switch to the new image both name the new CeraUI.
B1="${TMP}/b1"; new_box "${B1}"
printf '3333333\n' >"${B1}/data/ceralive/revision"
run_block "${B1}" STUB_DPKG_VERSION="${PKG4}"
assert_linked "${B1}" B1
echo "ceraui-build-stamps: B1 an older image's stamp is replaced after an OTA OK"

# B2: later boots are no-ops (the link stays the same link).
before="$(stat -c '%i' "${B1}/data/ceralive/revision")"
run_block "${B1}" STUB_DPKG_VERSION="${PKG4}"
[[ "$(stat -c '%i' "${B1}/data/ceralive/revision")" == "${before}" ]] || fail "B2: a re-run replaced the link"
assert_linked "${B1}" B2
echo "ceraui-build-stamps: B2 re-run is a no-op OK"

# B3: first boot of a fresh card (seed loop already copied revision) and a box
# with nothing on /data at all.
B3="${TMP}/b3"; new_box "${B3}"
printf '4444444\n' >"${B3}/data/ceralive/revision"
run_block "${B3}" STUB_DPKG_VERSION="${PKG4}"
assert_linked "${B3}" B3
B3b="${TMP}/b3b"; new_box "${B3b}"
run_block "${B3b}" STUB_DPKG_VERSION="${PKG4}"
assert_linked "${B3b}" B3b
echo "ceraui-build-stamps: B3 fresh /data gets the links OK"

# B4: rollback. A link left by the other slot points at the same path, so it
# already names the booted slot's stamp; a dangling one is replaced.
B4="${TMP}/b4"; new_box "${B4}"
ln -s /nonexistent/ceraui-stamps/revision "${B4}/data/ceralive/revision"
run_block "${B4}" STUB_DPKG_VERSION="${PKG4}"
assert_linked "${B4}" B4
echo "ceraui-build-stamps: B4 a dangling link is replaced OK"

# B5: an in-place CeraUI upgrade in this slot wrote its own stamps through the
# bind; dpkg now names a different version, so they are left alone.
B5="${TMP}/b5"; new_box "${B5}"
printf '5555555\n' >"${B5}/data/ceralive/revision"
printf '2026.11.5\n' >"${B5}/data/ceralive/version"
pkg_sums "${B5}" 5555555 2026.11.5
run_block "${B5}" STUB_DPKG_VERSION=2026.11.5-20261201T100000.5555555
[[ ! -L "${B5}/data/ceralive/revision" && "$(<"${B5}/data/ceralive/revision")" == 5555555 ]] \
  || fail "B5: the upgraded package's revision was replaced"
[[ ! -L "${B5}/data/ceralive/version" && "$(<"${B5}/data/ceralive/version")" == 2026.11.5 ]] \
  || fail "B5: the upgraded package's version was replaced"
echo "ceraui-build-stamps: B5 a package upgrade's stamps are kept OK"

# B6: dpkg cannot name the package: a regular file stays (nothing to compare
# it with), but a link to the kept stamps goes, since it cannot be verified.
B6="${TMP}/b6"; new_box "${B6}"
printf '3333333\n' >"${B6}/data/ceralive/revision"
ln -s "${B6}/${STAMPS_REL}/version" "${B6}/data/ceralive/version"
run_block "${B6}"
[[ ! -L "${B6}/data/ceralive/revision" && "$(<"${B6}/data/ceralive/revision")" == 3333333 ]] \
  || fail "B6: a regular file was touched although dpkg named no package"
[[ ! -e "${B6}/data/ceralive/version" && ! -L "${B6}/data/ceralive/version" ]] \
  || fail "B6: an unverifiable link to the kept stamps was left"
# The image kept no stamps: nothing is linked, and a file that is not the
# installed package's goes, so CeraUI shows the dpkg version.
rm -rf "${B6:?}/${STAMPS_REL}"
run_block "${B6}" STUB_DPKG_VERSION="${PKG4}"
[[ ! -e "${B6}/data/ceralive/revision" && ! -L "${B6}/data/ceralive/revision" && ! -e "${B6}/data/ceralive/version" ]] \
  || fail "B6: a stale stamp survived without kept stamps"
echo "ceraui-build-stamps: B6 nothing to match, nothing unverified kept OK"

# B7: a failure is non-fatal: the rest of ceralive-migrate-data (every /data bind)
# must still run. A directory in the way cannot be replaced by a link.
B7="${TMP}/b7"; new_box "${B7}"
mkdir -p "${B7}/data/ceralive/revision/sub"
run_block "${B7}" STUB_DPKG_VERSION="${PKG4}" || fail "B7: an unlinkable entry stopped ceralive-migrate-data"
[[ -d "${B7}/data/ceralive/revision/sub" ]] || fail "B7: a directory in the way was removed"
[[ ! -e "${B7}/data/ceralive/revision.stamp-link" && ! -L "${B7}/data/ceralive/revision.stamp-link" ]] \
  || fail "B7: a temporary link was left behind"
[[ -L "${B7}/data/ceralive/version" ]] || fail "B7: one failing stamp stopped the other"
echo "ceraui-build-stamps: B7 a failure is non-fatal OK"

# B8: two slots on one /data. Both slots keep their stamps at the same path, so
# the kept directory's contents stand for whichever slot is booted.
slot_stamps() { # $1=box $2=commit $3=calver $4=package version
  printf '%s\n' "$2" >"$1/${STAMPS_REL}/revision"
  printf '%s\n' "$3" >"$1/${STAMPS_REL}/version"
  printf '%s\n' "$4" >"$1/${STAMPS_REL}/package-version"
}
reads() { # $1=box -> "revision|version" as CeraUI would read them ("-" = absent)
  local r=- v=-
  [[ -r "$1/data/ceralive/revision" ]] && r="$(<"$1/data/ceralive/revision")"
  [[ -r "$1/data/ceralive/version" ]] && v="$(<"$1/data/ceralive/version")"
  printf '%s|%s' "$r" "$v"
}
PKG5=2026.11.5-20261201T100000.5555555
PKG6=2026.11.6-20261210T100000.6666666
PKG7=2026.11.7-20261220T100000.7777777
B8="${TMP}/b8"; new_box "${B8}"
# Slot A runs the image with CeraUI 4.
run_block "${B8}" STUB_DPKG_VERSION="${PKG4}"
[[ "$(reads "${B8}")" == '4444444|2026.11.4' ]] || fail "B8 step 1: slot A reads $(reads "${B8}")"
# In-place upgrade to CeraUI 5 on slot A: dpkg replaces both links with files.
rm -f "${B8}/data/ceralive/revision" "${B8}/data/ceralive/version"
printf '5555555\n' >"${B8}/data/ceralive/revision"
printf '2026.11.5\n' >"${B8}/data/ceralive/version"
pkg_sums "${B8}" 5555555 2026.11.5
run_block "${B8}" STUB_DPKG_VERSION="${PKG5}"
[[ "$(reads "${B8}")" == '5555555|2026.11.5' ]] || fail "B8 step 2: upgraded slot A reads $(reads "${B8}")"
# OTA to slot B, whose image carries CeraUI 6.
slot_stamps "${B8}" 6666666 2026.11.6 "${PKG6}"; pkg_sums "${B8}" 6666666 2026.11.6
run_block "${B8}" STUB_DPKG_VERSION="${PKG6}"
[[ "$(reads "${B8}")" == '6666666|2026.11.6' ]] || fail "B8 step 3: slot B reads $(reads "${B8}")"
# Rollback to slot A: its image kept CeraUI 4, but CeraUI 5 is installed. The
# links must not name 4 (nor 6); with no stamps CeraUI shows the dpkg version.
slot_stamps "${B8}" 4444444 2026.11.4 "${PKG4}"; pkg_sums "${B8}" 5555555 2026.11.5
run_block "${B8}" STUB_DPKG_VERSION="${PKG5}"
[[ "$(reads "${B8}")" == '-|-' ]] || fail "B8 step 4: rolled-back slot A reads $(reads "${B8}") with ${PKG5} installed"
[[ ! -L "${B8}/data/ceralive/revision" && ! -L "${B8}/data/ceralive/version" ]] \
  || fail "B8 step 4: a link to the kept stamps was left"
# And it stays that way on the next boot.
run_block "${B8}" STUB_DPKG_VERSION="${PKG5}"
[[ "$(reads "${B8}")" == '-|-' ]] || fail "B8 step 5: reboot after rollback reads $(reads "${B8}")"
echo "ceraui-build-stamps: B8 upgrade, OTA, rollback never names another build OK"

# B9: the other slot's in-place upgrade wrote files; after switching to a slot
# whose own package was also upgraded, they are not this slot's: removed.
B9="${TMP}/b9"; new_box "${B9}"
printf '7777777\n' >"${B9}/data/ceralive/revision"
printf '2026.11.7\n' >"${B9}/data/ceralive/version"
pkg_sums "${B9}" 5555555 2026.11.5
run_block "${B9}" STUB_DPKG_VERSION="${PKG5}"
[[ "$(reads "${B9}")" == '-|-' ]] || fail "B9: the other slot's upgrade stamps survive: $(reads "${B9}")"
# While the same files on the slot that installed CeraUI 7 are kept.
printf '7777777\n' >"${B9}/data/ceralive/revision"
printf '2026.11.7\n' >"${B9}/data/ceralive/version"
pkg_sums "${B9}" 7777777 2026.11.7
run_block "${B9}" STUB_DPKG_VERSION="${PKG7}"
[[ "$(reads "${B9}")" == '7777777|2026.11.7' ]] || fail "B9: the installed package's stamps were removed"
echo "ceraui-build-stamps: B9 files are kept only for the installed package OK"

# B10: provenance comes from the package's md5sums, not from the version string.
# Versions with a suffix after the commit, or no commit at all, keep the files
# the installed package wrote; a stale file under the same version goes.
for ver in 2026.11.5-20261201T100000.5555555+deb1 2026.11.5-1 2026.11.5-20261201T100000.5555555~bpo1; do
  B10="${TMP}/b10-${ver//[^0-9A-Za-z]/_}"; new_box "${B10}"
  printf '5555555\n' >"${B10}/data/ceralive/revision"
  printf '2026.11.5\n' >"${B10}/data/ceralive/version"
  pkg_sums "${B10}" 5555555 2026.11.5
  run_block "${B10}" STUB_DPKG_VERSION="${ver}"
  [[ "$(reads "${B10}")" == '5555555|2026.11.5' ]] \
    || fail "B10: ${ver} lost the installed package's own stamps: $(reads "${B10}")"
  printf '3333333\n' >"${B10}/data/ceralive/revision"
  run_block "${B10}" STUB_DPKG_VERSION="${ver}"
  [[ "$(reads "${B10}")" == '-|2026.11.5' ]] \
    || fail "B10: ${ver} kept a stale revision or dropped the matching version: $(reads "${B10}")"
done
echo "ceraui-build-stamps: B10 +deb1, ~bpo1 and commit-less versions keep the package's files OK"

# B11: no md5sums to decide with: regular files are left alone, links still go.
B11="${TMP}/b11"; new_box "${B11}"
rm -f "${B11}/dpkg-info/ceralive-device.md5sums"
printf '3333333\n' >"${B11}/data/ceralive/revision"
ln -s "${B11}/${STAMPS_REL}/version" "${B11}/data/ceralive/version"
run_block "${B11}" STUB_DPKG_VERSION="${PKG5}"
[[ ! -L "${B11}/data/ceralive/revision" && "$(<"${B11}/data/ceralive/revision")" == 3333333 ]] \
  || fail "B11: an undecidable regular file was removed"
[[ ! -e "${B11}/data/ceralive/version" && ! -L "${B11}/data/ceralive/version" ]] \
  || fail "B11: a link to the kept stamps survived a package mismatch"
echo "ceraui-build-stamps: B11 no md5sums, regular files left alone OK"

# B12: the md5sums come from dpkg's installed instance, not from a file name. A
# decoy manifest next to it changes nothing; an entry that is not exactly one
# valid digest decides nothing.
B12="${TMP}/b12"; new_box "${B12}"
printf '5555555\n' >"${B12}/data/ceralive/revision"
printf '2026.11.5\n' >"${B12}/data/ceralive/version"
pkg_sums "${B12}" 5555555 2026.11.5
printf '%s  opt/ceralive/revision\n%s  opt/ceralive/version\n' "$(printf x | md5sum | awk '{print $1}')" \
  "$(printf x | md5sum | awk '{print $1}')" >"${B12}/dpkg-info/ceralive-device:aaa.md5sums"
run_block "${B12}" STUB_DPKG_VERSION="${PKG5}"
[[ "$(reads "${B12}")" == '5555555|2026.11.5' ]] || fail "B12: a decoy manifest decided: $(reads "${B12}")"
printf '3333333\n' >"${B12}/data/ceralive/revision"
printf 'not-a-digest  opt/ceralive/revision\n' >"${B12}/dpkg-info/ceralive-device.md5sums"
run_block "${B12}" STUB_DPKG_VERSION="${PKG5}"
[[ "$(reads "${B12}")" == '3333333|2026.11.5' ]] || fail "B12: an invalid digest removed a file: $(reads "${B12}")"
d="$(printf 'x\n' | md5sum | awk '{print $1}')"
printf '%s  opt/ceralive/revision\n%s  opt/ceralive/revision\n' "$d" "$d" >"${B12}/dpkg-info/ceralive-device.md5sums"
run_block "${B12}" STUB_DPKG_VERSION="${PKG5}"
[[ "$(reads "${B12}")" == '3333333|2026.11.5' ]] || fail "B12: a duplicated entry removed a file: $(reads "${B12}")"
echo "ceraui-build-stamps: B12 only one valid entry of the installed instance decides OK"

# ---------------------------------------------------------------------------
# Part C — both halves agree
# ---------------------------------------------------------------------------
grep -Fq "CERAUI_BUILD_STAMPS_DIR=\"/${STAMPS_REL}\"" "${APP_POSTINST}" \
  || fail "C: the app layer no longer keeps stamps in /${STAMPS_REL}"
grep -Fxq 'CERAUI_BUILD_STAMPS=(revision version)' "${APP_POSTINST}" \
  || fail "C: the app layer's stamp list changed; update the migrate-data loop with it"
grep -Fq 'for name in revision version; do' <<<"${block}" \
  || fail "C: the migrate-data loop no longer links revision and version"
awk '/^main\(\) \{/{m=1} m && /install_first_party_apps$/{getline; print; exit}' "${APP_POSTINST}" \
  | grep -Fq 'keep_ceraui_build_stamps' \
  || fail "C: main() no longer keeps the stamps right after installing the first-party apps"
echo "ceraui-build-stamps: C both halves agree OK"

echo "ceraui-build-stamps regression: PASS"
