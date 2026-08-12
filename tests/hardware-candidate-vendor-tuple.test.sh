#!/usr/bin/env bash
#
# hardware-candidate-vendor-tuple.test.sh — proof that
# ci/build-hardware-candidates.sh can emit a VALID artifact tuple for a candidate
# whose kernel is the PREBUILT vendor BSP package rather than a source build.
#
# THE FOUR EDGE-ONLY GATES THIS LOCKS DOWN. Before this, every path in the tuple
# recorder assumed a `kernel_source:` variant, so a vendor candidate failed four
# separate ways, each of which would have looked like a broken artifact rather
# than a broken recorder:
#
#   (c1) TUPLE FIELDS — the recorder required KERNEL_SOURCE_KERNEL_RELEASE, which
#        the vendor resolve legitimately does not carry.
#   (c2) PACKAGE LOCATION — it searched only .staging/<board>/kernel-build for a
#        source-built package. The vendor kernel is a FETCHED .deb under the BSP
#        staging area, and both its release string and its config must be read out
#        of that package (identity-checked against the committed pin) rather than
#        resolved or composed from a version.
#   (c3) SYMBOL CLOSURE — it applied the EDGE required/forbidden manifests to every
#        non-debug candidate, and required-symbols.list demands
#        CONFIG_VIDEO_SYNOPSYS_HDMIRX, the MAINLINE HDMI-RX driver. The vendor
#        kernel carries rk_hdmirx instead, so the edge closure would have FAILED a
#        correct vendor artifact. The vendor gate is the vendor claim.
#   (c4) CANDIDATE MAPPING — `rock-vendor` is the resolver's reserved `default`,
#        i.e. a bare `./build <board>`; passing `--variant default` would be an
#        error, so the absence of the flag is asserted where it matters — in the
#        argv `./build` actually receives.
#
# Every leg drives the REAL shipped script inside a throwaway pipeline tree. No
# kernel is compiled and no image is written.
#
# Profile: contract-test (docs/shell-profiles.md) — set -uo pipefail, no -e, the
# harness owns its exit code so one failure does not hide the rest.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"
TOOL="${PIPELINE_DIR}/ci/build-hardware-candidates.sh"

# shellcheck source=tests/lib/assertions.sh
source "${HERE}/lib/assertions.sh"

printf 'hardware-candidate-vendor-tuple: the prebuilt-vendor candidate contract\n'

[[ -x "${TOOL}" ]] || { printf '  FAIL tool not executable: %s\n' "${TOOL}"; exit 1; }
for dep in git ar tar python3; do
  command -v "${dep}" >/dev/null 2>&1 \
    || { printf '  FAIL missing test dependency: %s\n' "${dep}"; exit 1; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vendor-tuple-XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

BOARD="rock-5b-plus"
VENDOR_PKG="linux-image-vendor-rk35xx"
VENDOR_VERSION="26.5.1"
VENDOR_RELEASE="6.1.115-vendor-rk35xx"

# A real ar-format .deb: control fields plus /boot/config-<release>.
make_vendor_deb() {
  local dest="$1" pkg="$2" version="$3" release="$4" config_body="$5" stage
  stage="$(mktemp -d "${WORK}/deb-XXXXXX")"
  mkdir -p "${stage}/root/boot"
  printf '%s' "${config_body}" >"${stage}/root/boot/config-${release}"
  tar -C "${stage}/root" -czf "${stage}/data.tar.gz" ./boot
  mkdir -p "${stage}/ctl"
  printf 'Package: %s\nVersion: %s\nArchitecture: arm64\n' "${pkg}" "${version}" \
    >"${stage}/ctl/control"
  tar -C "${stage}/ctl" -czf "${stage}/control.tar.gz" ./control
  printf '2.0\n' >"${stage}/debian-binary"
  ( cd "${stage}" && ar rc "${dest}" debian-binary control.tar.gz data.tar.gz ) >/dev/null 2>&1
}

VENDOR_CONFIG_OK=$'CONFIG_ARCH_ROCKCHIP=y\nCONFIG_VIDEO_ROCKCHIP_HDMIRX=y\nCONFIG_VIDEO_ROCKCHIP_HDMIRX_CLASS=y\n'
VENDOR_CONFIG_NO_HDMIRX=$'CONFIG_ARCH_ROCKCHIP=y\n# CONFIG_VIDEO_ROCKCHIP_HDMIRX is not set\n'

make_fake_pipeline() {
  local root="$1"
  mkdir -p "${root}/ci" "${root}/lib/shared" "${root}/manifests/kernel" \
           "${root}/mkosi/.staging/${BOARD}/bsp" \
           "${root}/mkosi/.staging/${BOARD}/kernel-build" "${root}/out"
  cp "${TOOL}" "${root}/ci/build-hardware-candidates.sh"
  # The REAL loader table, so the board→loader binding under test is the shipped one.
  cp "${PIPELINE_DIR}/ci/fetch-rk3588-loader.sh" "${root}/ci/fetch-rk3588-loader.sh"
  cp "${PIPELINE_DIR}/lib/common.sh" "${root}/lib/common.sh"
  cp "${PIPELINE_DIR}/lib/shared/log-lib.sh" "${root}/lib/shared/log-lib.sh"
  cp "${PIPELINE_DIR}/lib/shared/deb-lib.sh" "${root}/lib/shared/deb-lib.sh"

  cat >"${root}/build" <<STUB
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >"\${CERALIVE_ARGV_PROBE}"
raw="${root}/out/image.raw"
bundle="${root}/out/image.raucb"
printf 'raw\n' >"\${raw}"
printf 'bundle\n' >"\${bundle}"
printf 'emitted flashable image: %s\n' "\${raw}"
printf 'emitted signed bundle: %s\n' "\${bundle}"
STUB
  chmod +x "${root}/build"

  # The vendor resolve carries NO KERNEL_SOURCE_* fields — (c1) is exactly that
  # absence — and refuses a --variant it was never given.
  cat >"${root}/lib/resolve.sh" <<RESOLVE
#!/usr/bin/env bash
set -euo pipefail
for a in "\$@"; do
  [[ "\${a}" == "--variant" ]] && { printf 'resolve stub: vendor path must not be given --variant\n' >&2; exit 3; }
done
printf "DTB_NAME='%s'\n" rk3588-rock-5b-plus.dtb
printf "BOARD_ID='%s'\n" "${BOARD}"
printf "KERNEL_PACKAGES='%s'\n" "${VENDOR_PKG}"
RESOLVE
  chmod +x "${root}/lib/resolve.sh"

  # A SPY, not a stub: the edge closure must never run for a vendor candidate.
  cat >"${root}/lib/verify-kernel-config.sh" <<'SPY'
#!/usr/bin/env bash
printf 'edge-closure-invoked\n' >>"${CERALIVE_CLOSURE_SPY}"
exit 1
SPY
  chmod +x "${root}/lib/verify-kernel-config.sh"

  # The REAL edge manifests' load-bearing line: a mainline-only symbol the vendor
  # kernel does not carry, so applying this list to it would fail a good artifact.
  printf 'CONFIG_VIDEO_SYNOPSYS_HDMIRX=m\n' >"${root}/manifests/kernel/required-symbols.list"
  : >"${root}/manifests/kernel/forbidden-symbols.list"
  printf '%s=%s\n' "${VENDOR_PKG}" "${VENDOR_VERSION}" \
    >"${root}/manifests/armbian-bsp-deb-versions.txt"

  printf 'mkosi/\nout/\n' >"${root}/.gitignore"
  git -C "${root}" init -q .
  git -C "${root}" add -A
  git -C "${root}" -c user.email=t@t -c user.name=t commit -q -m fixture
}

make_inputs() {
  local dir="$1"
  mkdir -p "${dir}/pki"
  printf 'keyring\n' >"${dir}/keyring.pem"
  cat >"${dir}/verdict.json" <<JSON
{"schema_version":1,"boards":[
 {"board":"${BOARD}","verdict":"RAUC","build_mode":"development",
  "installed_root":{"sha256_fingerprint":"aa:bb"},
  "candidate_signer":{"pki_dir":"${dir}/pki","leaf_sha256_fingerprint":"cc:dd",
                      "extended_key_usage_observed":["emailProtection","codeSigning"]},
  "checks":{"production_trust_anchor":false}}
]}
JSON
  printf 'CERALIVE_RAUC_PKI_DIR=%s\nRAUC_KEYRING_FILE=%s\n' \
    "${dir}/pki" "${dir}/keyring.pem" >"${dir}/sign.env"
}

stage_vendor_deb() {
  local root="$1" pkg="$2" version="$3" release="$4" body="$5"
  rm -f "${root}/mkosi/.staging/${BOARD}/bsp/"*.deb
  make_vendor_deb \
    "${root}/mkosi/.staging/${BOARD}/bsp/${pkg}_${version}_arm64.deb" \
    "${pkg}" "${version}" "${release}" "${body}"
}

run_vendor() {
  local root="$1" inputs="$2" ev="$3" argv_probe="$4" spy="$5"
  CERALIVE_ARGV_PROBE="${argv_probe}" CERALIVE_CLOSURE_SPY="${spy}" \
    "${root}/ci/build-hardware-candidates.sh" \
      --only rock-vendor \
      --trust-verdict "${inputs}/verdict.json" \
      --signing-env "${inputs}/sign.env" \
      --evidence "${ev}" \
      --skip-probes --bench-labels 1
}

tuple_field() {
  python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))[sys.argv[2]]))' "$1" "$2"
}

ROOT="${WORK}/pipeline"
INPUTS="${WORK}/inputs"
mkdir -p "${INPUTS}"
make_inputs "${INPUTS}"
make_fake_pipeline "${ROOT}"
stage_vendor_deb "${ROOT}" "${VENDOR_PKG}" "${VENDOR_VERSION}" "${VENDOR_RELEASE}" "${VENDOR_CONFIG_OK}"

# ---------------------------------------------------------------------------
# HAPPY PATH — a vendor candidate builds and emits a complete tuple
# ---------------------------------------------------------------------------
ARGV="${WORK}/argv"; SPY="${WORK}/spy"; LOG="${WORK}/vendor.log"
run_vendor "${ROOT}" "${INPUTS}" "${WORK}/ev" "${ARGV}" "${SPY}" >"${LOG}" 2>&1
rc=$?
if (( rc == 0 )); then
  ok "the vendor candidate completes (exit 0)"
else
  bad "the vendor candidate failed (exit ${rc}):"$'\n'"$(cat "${LOG}")"
fi

# (c4) the resolver `default` reaches ./build as NO --variant flag at all
if [[ -s "${ARGV}" ]]; then
  assert_eq "(c4) ./build is invoked bare, with no --variant" "${BOARD}" "$(cat "${ARGV}")"
else
  bad "(c4) ./build was never invoked"
fi

# (c3) the edge closure never ran
if [[ -e "${SPY}" ]]; then
  bad "(c3) the EDGE symbol manifests were applied to the vendor candidate"
else
  ok "(c3) the edge required/forbidden closure is NOT applied to the vendor candidate"
fi
assert_contains "(c3) the vendor gate names the vendor HDMI-RX symbol" "${LOG}" \
  'CONFIG_VIDEO_ROCKCHIP_HDMIRX=y present'

TUPLE="${WORK}/ev/rock-vendor.bench-labels-1.tuple.json"
if [[ -s "${TUPLE}" ]]; then
  ok "the vendor tuple is emitted at a bench-labels-scoped path"
  # (c1) valid without any source-build field
  assert_eq "(c1) the tuple carries no kernel source tag"    '""' "$(tuple_field "${TUPLE}" kernel_source_tag)"
  assert_eq "(c1) the tuple carries no kernel source commit" '""' "$(tuple_field "${TUPLE}" kernel_source_commit)"
  assert_eq "(c1) the tuple carries no patches commit"       '""' "$(tuple_field "${TUPLE}" patches_commit)"
  assert_eq "(c1) the tuple states the kernel provenance"    '"prebuilt-bsp"' "$(tuple_field "${TUPLE}" kernel_source)"
  # (c2) the release string comes out of the PACKAGE, not the resolver
  assert_eq "(c2) the kernel release is read from the staged package" \
    "\"${VENDOR_RELEASE}\"" "$(tuple_field "${TUPLE}" kernel_release)"
  assert_eq "(c2) the tuple names the prebuilt kernel package" \
    "\"${VENDOR_PKG}\"" "$(tuple_field "${TUPLE}" kernel_package)"
  assert_eq "the tuple records the variant as the resolver default" \
    '"default"' "$(tuple_field "${TUPLE}" variant)"
  assert_eq "the tuple records the bench-labels mode" 'true' "$(tuple_field "${TUPLE}" bench_labels)"
  # (a) the recorded recovery loader is THIS board's
  assert_eq "the tuple binds the board's own recovery loader" \
    "\"$("${PIPELINE_DIR}/ci/fetch-rk3588-loader.sh" --print-sha256 "${BOARD}")\"" \
    "$(tuple_field "${TUPLE}" loader_sha256)"
else
  bad "no vendor tuple at ${TUPLE}"
fi

# (c2) the config in evidence is the package's own
CONFIG="${WORK}/ev/rock-vendor.bench-labels-1.config"
if [[ -s "${CONFIG}" ]] && grep -qx 'CONFIG_VIDEO_ROCKCHIP_HDMIRX=y' "${CONFIG}"; then
  ok "(c2) the evidence config is the staged package's own /boot/config-<release>"
else
  bad "(c2) the evidence config was not extracted from the staged package"
fi

# ---------------------------------------------------------------------------
# NON-VACUITY — each vendor-specific check must be able to FAIL
# ---------------------------------------------------------------------------
stage_vendor_deb "${ROOT}" "${VENDOR_PKG}" "${VENDOR_VERSION}" "${VENDOR_RELEASE}" "${VENDOR_CONFIG_NO_HDMIRX}"
out="$(run_vendor "${ROOT}" "${INPUTS}" "${WORK}/ev-nohdmirx" "${WORK}/argv2" "${WORK}/spy2" 2>&1)"
if [[ $? -eq 0 ]]; then
  bad "a vendor kernel with NO HDMI-RX driver was accepted"
else
  case "${out}" in
    *"has no vendor HDMI-RX driver"*) ok "a vendor kernel without ${VENDOR_PKG}'s HDMI-RX driver is REFUSED, and says why" ;;
    *) bad "the no-HDMI-RX refusal did not explain itself: ${out}" ;;
  esac
fi

stage_vendor_deb "${ROOT}" "${VENDOR_PKG}" "99.9.9" "${VENDOR_RELEASE}" "${VENDOR_CONFIG_OK}"
out="$(run_vendor "${ROOT}" "${INPUTS}" "${WORK}/ev-badver" "${WORK}/argv3" "${WORK}/spy3" 2>&1)"
if [[ $? -eq 0 ]]; then
  bad "a staged vendor package whose version contradicts the committed pin was accepted"
else
  case "${out}" in
    *"pins '${VENDOR_VERSION}'"*) ok "a staged package off the committed BSP pin is REFUSED" ;;
    *) bad "the pin-mismatch refusal did not explain itself: ${out}" ;;
  esac
fi

stage_vendor_deb "${ROOT}" "linux-image-some-other-kernel" "${VENDOR_VERSION}" "${VENDOR_RELEASE}" "${VENDOR_CONFIG_OK}"
out="$(run_vendor "${ROOT}" "${INPUTS}" "${WORK}/ev-nopkg" "${WORK}/argv4" "${WORK}/spy4" 2>&1)"
if [[ $? -eq 0 ]]; then
  bad "a vendor candidate was recorded with NO staged kernel package"
else
  case "${out}" in
    *"no staged prebuilt kernel package"*) ok "a missing staged vendor package is REFUSED" ;;
    *) bad "the missing-package refusal did not explain itself: ${out}" ;;
  esac
fi

printf '\n== %d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
