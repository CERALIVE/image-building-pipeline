#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "${here}/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/var/tmp}/rauc-bundle-arch.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
mkdir -p "${work}/bin" "${work}/out" "${work}/content"

# ---------------------------------------------------------------------------
# Part 1 — bundle_with_rauc() is the REVERTED, plain original form: no
# RAUC_ARCH requirement, no apt-get arch override. The container only ever
# sees a self-consistent host-native pair, so ordinary apt resolution needs
# no help.
# ---------------------------------------------------------------------------
cat >"${work}/bin/docker" <<'EOF'
#!/usr/bin/env bash
while [[ "$1" != bash ]]; do
  if [[ "$1" == -e ]]; then export "$2"; shift 2; else shift; fi
done
"$@"
EOF
cat >"${work}/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${APT_LOG}"
EOF
cat >"${work}/bin/rauc" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${work}/bin/"*

export PATH="${work}/bin:${PATH}" APT_LOG="${work}/apt.log"
export CERALIVE_RAUC_PKI_DIR="${work}/unused-pki" RAUC_DEB_DIR="${work}/rauc-debs"
export MKOSI_BUILDER_IMAGE=fixture-builder MKOSI_NATIVE=0
mkdir -p "${RAUC_DEB_DIR}"
# shellcheck source=lib/build-bundle.sh
source "${repo}/lib/build-bundle.sh"

bundle_with_rauc "${work}/content" "${work}/out/test.raucb"
grep -Fxq -- 'update -qq' "${APT_LOG}"
grep -Fxq -- 'install -y --no-install-recommends squashfs-tools /rauc-debs/rauc_*.deb /rauc-debs/rauc-service_*.deb' "${APT_LOG}"
if grep -Fq 'APT::Architecture' "${APT_LOG}"; then
  printf 'apt-get install line still carries an APT::Architecture override\n' >&2
  exit 1
fi
if grep -Fq 'RAUC_ARCH' "${repo}/lib/build-bundle.sh"; then
  printf 'lib/build-bundle.sh still references the retired RAUC_ARCH mechanism\n' >&2
  exit 1
fi

if ( unset RAUC_DEB_DIR; bundle_with_rauc "${work}/content" "${work}/out/test2.raucb" ) \
    >"${work}/missing.log" 2>&1; then
  printf 'bundle_with_rauc accepted an unset RAUC_DEB_DIR\n' >&2
  exit 1
fi
grep -Fq 'RAUC_DEB_DIR is required' "${work}/missing.log"
printf 'bundle_with_rauc: plain apt-get install, no RAUC_ARCH mechanism: PASS\n'

# ---------------------------------------------------------------------------
# Part 2 — the corrected design: stage_rauc_build() builds a second,
# host-native pair only when the target board's arch differs from the
# builder's own amd64, and stage_assemble() forwards the HOST-native
# directory to build-bundle.sh — never the target-arch one.
# ---------------------------------------------------------------------------

# make-fixture-deb <path> <pkg> <arch> — a real, minimal ar/tar .deb whose
# control.tar.gz carries just enough for deb_pkg_name() (lib/shared/deb-lib.sh)
# to read the Package: field, so assert_staged_packages_unique() and the
# staging helper below operate on real archives, not shell-script stand-ins.
cat >"${work}/bin/make-fixture-deb" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
path="$1" pkg="$2" arch="$3"
tmp="$(mktemp -d)"
mkdir -p "${tmp}/root"
printf 'Package: %s\nVersion: 1.15.2-1+ceralive.1\nArchitecture: %s\n' "${pkg}" "${arch}" \
  >"${tmp}/root/control"
( cd "${tmp}/root" && tar czf "${tmp}/control.tar.gz" ./control )
( cd "${tmp}" && ar rc "$(basename "${path}")" control.tar.gz )
mv "${tmp}/$(basename "${path}")" "${path}"
rm -rf "${tmp}"
EOF
cat >"${work}/bin/build-rauc" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >>"\${RAUC_BUILD_LOG}"
arch="" out=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --arch) arch="\$2"; shift 2 ;;
    --out)  out="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p "\${out}"
"${work}/bin/make-fixture-deb" "\${out}/rauc_1.15.2-1+ceralive.1_\${arch}.deb" rauc "\${arch}"
"${work}/bin/make-fixture-deb" "\${out}/rauc-service_1.15.2-1+ceralive.1_all.deb" rauc-service all
EOF
cat >"${work}/bin/stage-mkosi-package" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${STAGE_LOG}"
mkdir -p "$2"
cp "$1" "$2/"
EOF
cat >"${work}/bin/assemble" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  if [[ "$1" == --output ]]; then truncate -s 4096 "$2"; exit; fi
  shift
done
exit 1
EOF
cat >"${work}/bin/bundle" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${RAUC_DEB_DIR}" >>"${ASSEMBLE_LOG}"
printf 'bundle\n' >"${BUNDLE_OUT_DIR}/${BUNDLE_TS}.raucb"
EOF
cat >"${work}/bin/seal" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  if [[ "$1" == --raw ]]; then touch "$2.xz"; exit; fi
  shift
done
exit 1
EOF
chmod +x "${work}/bin/"*

grep -Eq 'local .*mkosi_arch="" rauc_build_dir_host=""' "${repo}/lib/orchestrate.sh"
# shellcheck source=lib/shared/deb-lib.sh
source "${repo}/lib/shared/deb-lib.sh"
# shellcheck source=lib/stages/partition.sh
source "${repo}/lib/stages/partition.sh"
# shellcheck source=lib/stages/rauc-build.sh
source "${repo}/lib/stages/rauc-build.sh"
# shellcheck source=lib/stages/assemble.sh
source "${repo}/lib/stages/assemble.sh"
log_info() { :; }
log_success() { :; }
log_warn() { :; }
die() { printf '%s\n' "$*" >&2; exit 1; }

exercise_stage() {
  local mkosi_arch="$1" adapter="$2" expect_second_build="$3" rauc_build_dir_host=""
  local board=fixture staging="${work}/staging-${adapter}-${mkosi_arch}"
  local rauc_build_dir="${staging}/rauc-build"
  local out_dir="${work}/out" ts="fixture-${adapter}-${mkosi_arch}" build_version=fixture
  local bsp_dir="${work}" rootfs_tree="${work}/content" variant=default
  local BUILD_RAUC_SH="${work}/bin/build-rauc" MKOSI_PACKAGE_STAGING_SH="${work}/bin/stage-mkosi-package"
  local ASSEMBLE_DISK_SH="${work}/bin/assemble" ASSEMBLE_DISK_X86_SH="${work}/bin/assemble"
  local BUILD_BUNDLE_SH="${work}/bin/bundle" SEAL_RAW_CANDIDATE_SH="${work}/bin/seal"
  local BOARD_ID=fixture COMPATIBLE_STRING=ceralive-fixture INSTALL_BOOT_BSP=1
  local RAUC_BOOTLOADER_ADAPTER="${adapter}" SINGLE_SLOT_FALLBACK=false DRY_RUN=0
  local RAUC_BUILD_LOG="${work}/build-${adapter}-${mkosi_arch}.log"
  local STAGE_LOG="${work}/stage-${adapter}-${mkosi_arch}.log"
  local ASSEMBLE_LOG="${work}/assemble-${adapter}-${mkosi_arch}.log"
  export RAUC_BUILD_LOG STAGE_LOG ASSEMBLE_LOG
  mkdir -p "${staging}/debs"
  : >"${RAUC_BUILD_LOG}"
  : >"${STAGE_LOG}"
  : >"${ASSEMBLE_LOG}"

  stage_rauc_build

  local invocations
  invocations="$(wc -l <"${RAUC_BUILD_LOG}")"
  if [[ "${expect_second_build}" == yes ]]; then
    [[ "${invocations}" -eq 2 ]] \
      || { printf 'expected 2 build-rauc invocations for %s/%s, got %s\n' "${adapter}" "${mkosi_arch}" "${invocations}" >&2; exit 1; }
    [[ "${rauc_build_dir_host}" != "${rauc_build_dir}" ]] \
      || { printf 'rauc_build_dir_host aliased rauc_build_dir for an arm64 target\n' >&2; exit 1; }
    grep -Fxq -- "--arch arm64 --out ${rauc_build_dir}" "${RAUC_BUILD_LOG}"
    grep -Fxq -- "--arch amd64 --out ${rauc_build_dir_host}" "${RAUC_BUILD_LOG}"
  else
    [[ "${invocations}" -eq 1 ]] \
      || { printf 'expected exactly 1 build-rauc invocation for %s/%s (no wasted duplicate build), got %s\n' "${adapter}" "${mkosi_arch}" "${invocations}" >&2; exit 1; }
    [[ "${rauc_build_dir_host}" == "${rauc_build_dir}" ]] \
      || { printf 'rauc_build_dir_host did not alias rauc_build_dir for an amd64 target\n' >&2; exit 1; }
  fi

  # The single most important correctness property: the host-native pair's
  # contents must NEVER reach staging/debs.
  if [[ "${rauc_build_dir_host}" != "${rauc_build_dir}" ]] \
      && grep -Fq "${rauc_build_dir_host}/" "${STAGE_LOG}"; then
    printf 'the host-native rauc pair was staged into staging/debs (dir=%s)\n' "${rauc_build_dir_host}" >&2
    exit 1
  fi
  grep -Fq "${rauc_build_dir}/" "${STAGE_LOG}" \
    || { printf 'the target-arch rauc pair was never staged (dir=%s)\n' "${rauc_build_dir}" >&2; exit 1; }

  stage_assemble
  [[ "$(<"${ASSEMBLE_LOG}")" == "${rauc_build_dir_host}" ]] \
    || { printf 'stage_assemble passed RAUC_DEB_DIR=%s, expected the host-native dir %s\n' "$(<"${ASSEMBLE_LOG}")" "${rauc_build_dir_host}" >&2; exit 1; }
}

# arm64 target (RK3588, custom bootloader adapter): TWO pairs, different dirs,
# host one never staged, stage_assemble forwards the host dir.
exercise_stage arm64 custom yes

# amd64 target (x86-minipc): both x86 call sites (efi and grub adapters), ONE
# pair reused for both purposes, no duplicate build.
exercise_stage x86-64 efi no
exercise_stage x86-64 grub no

printf 'RAUC bundle architecture and cross-stage wiring: PASS\n'
