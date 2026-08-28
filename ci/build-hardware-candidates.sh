#!/usr/bin/env bash
#
# build-hardware-candidates.sh — build the hardware-qualification candidates and
# record what each one actually IS.
#
# WHY this exists rather than a hand-run `./build`: a candidate that is going to
# be written to a real board has to answer three questions that a bare build
# never asks itself.
#
#   1. WHICH SOURCE. The artifact is only evidence if the exact revision that
#      produced it is recorded beside it. So this refuses a dirty worktree and
#      stamps the committed HEAD and its TREE hash into every tuple: a tree hash
#      survives a squash-merge, which is what lets the merged branch later be
#      proven to be the thing that was tested.
#   2. WHICH TRUST. `CERALIVE_BUILD_MODE`, `CERALIVE_RAUC_PKI_DIR` and
#      `RAUC_KEYRING_FILE` are exported EXPLICITLY from the recorded verdict,
#      never inherited and never defaulted. An implicit signing state is the one
#      failure that still produces a plausible bundle — one the board rejects
#      after the update has already been staged.
#   3. WHICH SYMBOLS. A debug candidate and a production candidate differ by a
#      handful of Kconfig symbols and nothing an operator can see from the
#      filename. Each build's own resolved `/boot/config-<release>` is read out
#      of the kernel package it produced and asserted in BOTH directions.
#   4. WHICH LABELS. `CERALIVE_BENCH_LABELS` decides whether the baked fstab,
#      RAUC slot devices and boot selector address the frozen production
#      PARTLABEL set or the `x`-prefixed bench twin. It is exported EXPLICITLY
#      from `--bench-labels`, which is REQUIRED — see the incident note below.
#   5. WHICH RECOVERY LOADER. The MaskROM loader is the path an operator reaches
#      for once a candidate has already bricked the board, and it is matched to a
#      BOARD (its DDR initialiser), not to the SoC. It is therefore resolved per
#      board from ci/fetch-rk3588-loader.sh's table, never as one constant.
#
# WHY EVERY EVIDENCE PATH CARRIES THE BENCH-LABELS MODE. The same candidate is
# legitimately built twice — once with the bench PARTLABEL overlay for staging
# media and once with the frozen production set for the final medium — and those
# two artifacts are NOT interchangeable. Naming logs, configs and tuples by
# candidate alone let the second run silently overwrite the first's evidence, so
# every file is `<candidate>.bench-labels-<0|1>.<ext>`.
#
# A `production` build mode is claimed only when the verdict says the chain
# terminates at a production trust anchor. Otherwise the mode is `development`
# and the artifacts are labelled `development-hardware-candidate` — there is no
# path here that upgrades a NON-PRODUCTION root into a release claim.
#
# WHY `--bench-labels` HAS NO DEFAULT (2026-08-10 incident):
#   A `rock-edge-test` candidate was built by a dispatch that did not export
#   `CERALIVE_BENCH_LABELS`, so `lib/orchestrate.sh`'s own `:-0` default (correct
#   for a DIRECT `./build`) silently produced a PRODUCTION-labelled image for a
#   bench Rock 5B+ that carries BOTH a bench microSD (`x`-prefixed PARTLABELs)
#   and an onboard eMMC holding an unrelated plain-labelled image. Its `/etc/fstab`
#   then resolved `/boot` and `/data` on the eMMC, so a RAUC recovery transition
#   wrote A/B state to the WRONG PHYSICAL DEVICE and the board had to be recovered
#   by hand. Every other candidate that day was built with the flag. An ambient
#   environment is therefore not an acceptable input for this value: it is
#   dispatch-visible only when it is stated, so this tool refuses to guess.
#
# Usage:
#   build-hardware-candidates.sh --only <list> --trust-verdict <path>
#       --signing-env <path> [--debug-env <path>] --evidence <dir>
#       --bench-labels 0|1
#   build-hardware-candidates.sh --self-test
#
#   --only          all | a comma-separated subset of:
#                     rock-edge        rock-5b-plus    --variant edge       (non-debug)
#                     orange-edge      orange-pi-5-plus --variant edge      (non-debug)
#                     rock-edge-test   rock-5b-plus    --variant edge-test  (debug)
#                     rock-vendor      rock-5b-plus    --variant vendor     (the
#                                      PREBUILT Armbian vendor BSP kernel) —
#                                      opt-in by name only, deliberately NOT in
#                                      `all`: it is a comparison/smoke artifact,
#                                      not one of the qualification set. It became
#                                      an explicit --variant when the mainline
#                                      source-built track was promoted to the
#                                      family default; a bare ./build now resolves
#                                      `edge`, so passing no variant here would
#                                      silently build the WRONG kernel track.
#   --trust-verdict the ci/verify-bench-rauc-trust.sh verdict JSON
#   --signing-env   a PATHS-ONLY env file defining CERALIVE_RAUC_PKI_DIR and
#                   RAUC_KEYRING_FILE
#   --debug-env     an env file defining CERALIVE_DEBUG_PASSWORD_HASH; REQUIRED
#                   when a debug candidate is selected, refused otherwise
#   --evidence      output directory for logs, configs and artifact tuples
#   --bench-labels  REQUIRED, 0 or 1, no default and no ambient fallback:
#                     1 = bench PARTLABEL overlay (xboot/xrootfs_a/xrootfs_b/xdata)
#                         — for a bench card sharing a board with another image
#                     0 = the frozen production PARTLABEL set
#   --skip-probes   skip the nine DRY_RUN probes (they are the default)
#
# Every path argument is generic: this repo is built and tested standalone, so
# it never resolves a bench PKI, a verdict or an evidence root by proximity to
# its own checkout.
#
# Exit codes:
#   0  every selected candidate built and verified
#   1  a probe, a build or a verification failed
#   2  usage / unreadable input / refused precondition
#
# shellcheck shell=bash

set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"

TOOL_NAME="ci/build-hardware-candidates.sh"
# 2 adds `bench_labels`. The bump is the point: a schema-1 tuple was emitted by
# tooling that could not state which PARTLABEL set built the artifact, which is
# exactly the artifact class that is unsafe to deploy on a dual-media bench rig.
# 3 makes `loader_sha256` BOARD-SPECIFIC and adds `loader_name`/`loader_url`: a
# schema-2 tuple recorded the Radxa loader's digest for every board, so an Orange
# Pi tuple named a loader that board's BootROM cannot be recovered with. It also
# adds `evidence_stem`, because evidence paths are now per bench-labels mode.
SCHEMA_VERSION=3

usage() { sed -n '2,91p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; }
say()  { printf '[cand] %s\n' "$*" >&2; }
fail() { printf 'build-hardware-candidates: %s\n' "$*" >&2; }
die()  { fail "$*"; exit "${2:-2}"; }

# The candidate table. Deliberately a closed set: a candidate is a board, a
# variant and a debug posture together, because those three are what decide
# whether an artifact may ever be deployed.
candidate_board() {
  case "$1" in
    rock-edge|rock-edge-test|rock-vendor) printf 'rock-5b-plus\n' ;;
    orange-edge)                          printf 'orange-pi-5-plus\n' ;;
    *) return 1 ;;
  esac
}
# Every candidate names its variant EXPLICITLY, including the vendor one. A bare
# `./build <board>` resolves the family's declared `default_variant:`, which is
# the mainline source-built `edge` track — so the vendor candidate must ask for
# `--variant vendor` or it would quietly produce an edge artifact under a name
# that promises a prebuilt vendor BSP kernel.
candidate_variant() {
  case "$1" in
    rock-edge|orange-edge) printf 'edge\n' ;;
    rock-edge-test)        printf 'edge-test\n' ;;
    rock-vendor)           printf 'vendor\n' ;;
    *) return 1 ;;
  esac
}
candidate_is_debug() { [[ "$1" == "rock-edge-test" ]]; }

# A candidate whose kernel comes from a `kernel_source:` variant, i.e. one whose
# resolve output carries KERNEL_SOURCE_* fields and whose package lands in the
# per-board kernel-build staging tree. The vendor candidate installs a PREBUILT
# BSP kernel instead, so those fields are legitimately absent for it.
candidate_is_source_built() { [[ "$(candidate_variant "$1")" != "vendor" ]]; }

# Evidence file stem. The bench-labels mode is part of the NAME, not just of the
# content: the same candidate is built once per mode and the two artifacts are
# not interchangeable, so one must never overwrite the other's evidence.
evidence_stem() { printf '%s.bench-labels-%s\n' "$1" "${BENCH_LABELS}"; }

bench_labels_desc() {
  case "${BENCH_LABELS:-}" in
    1) printf 'ON — xboot/xrootfs_a/xrootfs_b/xdata\n' ;;
    0) printf 'OFF — frozen production label set\n' ;;
    *) printf 'UNSET\n' ;;
  esac
}

# The three CeraLive test symbols. Production must resolve all three OFF; the
# debug variant must resolve all three ON. Both directions are asserted, because
# a debug build that silently lost its instrumentation passes every other gate
# and then produces no fault-injection surface on the bench.
CERALIVE_TEST_SYMBOLS=(
  CONFIG_VIDEO_ROCKCHIP_RKVENC_CERALIVE_TEST
  CONFIG_VIDEO_ROCKCHIP_HDMIRX_CERALIVE_TEST
  CONFIG_DMABUF_HEAPS_CERALIVE_TEST
)

# The vendor BSP's own HDMI-RX driver symbol (rk_hdmirx). The mainline/edge
# contract's CONFIG_VIDEO_SYNOPSYS_HDMIRX is a DIFFERENT driver and is correctly
# absent here — that difference is why the vendor candidate gets its own gate.
VENDOR_HDMIRX_SYMBOL="CONFIG_VIDEO_ROCKCHIP_HDMIRX"

# The value arrives on ARGV, never on stdin. A stdin-reading helper called from
# inside a `while read` loop silently eats the loop's remaining input — which is
# how the signer's second EKU went missing from the first tuple this emitted.
json_str() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }

json_str_list() {
  python3 -c 'import json,sys; print(json.dumps([p for p in sys.argv[1].split(",") if p]))' "$1"
}

# A dirty worktree cannot be recorded, so it cannot be built from: the tuple
# would otherwise name a tree hash the artifact was not produced from. There is
# deliberately NO override flag — an escape hatch here silently detaches every
# downstream hardware receipt from the source it claims to attest.
assert_clean_worktree() {
  local repo="$1" dirty
  dirty="$(git -C "${repo}" status --porcelain 2>/dev/null)" \
    || die "not a git worktree: ${repo}"
  [[ -z "${dirty}" ]] \
    || die "refusing to build from a DIRTY worktree (${repo}):"$'\n'"${dirty}"
}

# ---------------------------------------------------------------------------
# read_verdict <verdict.json> <board> — echo "<verdict>|<build_mode>|<pki_dir>|
# <root_fpr>|<leaf_fpr>|<eku_csv>|<production_anchor>"
#
# A board absent from the verdict, or one whose verdict is not RAUC/PHYSICAL, is
# refused rather than defaulted: "we could not evaluate this board" and "this
# board takes the physical path" are different answers and only one of them
# authorises a build that will be signed for it.
# ---------------------------------------------------------------------------
read_verdict() {
  python3 - "$1" "$2" <<'PY'
import json, sys
path, board = sys.argv[1], sys.argv[2]
with open(path) as fh:
    doc = json.load(fh)
for entry in doc.get("boards", []):
    if entry.get("board") != board:
        continue
    verdict = entry.get("verdict") or ""
    mode = entry.get("build_mode") or ""
    signer = entry.get("candidate_signer") or {}
    root = entry.get("installed_root") or {}
    checks = entry.get("checks") or {}
    print("|".join([
        verdict,
        mode,
        signer.get("pki_dir") or "",
        root.get("sha256_fingerprint") or "",
        signer.get("leaf_sha256_fingerprint") or "",
        ",".join(signer.get("extended_key_usage_observed") or []),
        "true" if checks.get("production_trust_anchor") else "false",
    ]))
    sys.exit(0)
sys.exit(3)
PY
}

# ---------------------------------------------------------------------------
# load_env_file <path> <VAR>... — source a file in a subshell and export only
# the named variables back. The file is a PATHS/secret carrier written by other
# tooling; reading it must not be able to redefine this script's own state.
# ---------------------------------------------------------------------------
load_env_file() {
  local path="$1"; shift
  [[ -s "${path}" ]] || die "env file is missing or empty: ${path}"
  local dump var value
  dump="$(
    set -a
    # shellcheck disable=SC1090
    . "${path}"
    set +a
    for var in "$@"; do printf '%s=%s\n' "${var}" "${!var-}"; done
  )" || die "could not read env file: ${path}"
  while IFS='=' read -r var value; do
    [[ -n "${value}" ]] || die "${path} does not define ${var}"
    printf -v "${var}" '%s' "${value}"
    export "${var?}"
  done <<<"${dump}"
}

# ---------------------------------------------------------------------------
# The nine DRY_RUN probes: the eight valid board x kernel-track cells plus one
# multi-board dispatch probe. They run before any real build so a plan-level
# regression is reported in seconds rather than after a kernel compile. The bare
# board probes now exercise the mainline source-built default, so `--variant
# vendor` is probed explicitly — otherwise the prebuilt path would lose its only
# plan-level coverage the moment it stopped being the default.
# ---------------------------------------------------------------------------
run_dry_run_probes() {
  local log="$1" rc=0
  local -a probes=(
    "rock-5b-plus"
    "orange-pi-5-plus"
    "x86-minipc"
    "rock-5b-plus --variant vendor"
    "rock-5b-plus --variant edge"
    "orange-pi-5-plus --variant edge"
    "rock-5b-plus --variant vendor-patched"
    "orange-pi-5-plus --variant vendor-patched"
    "--all"
  )
  : >"${log}"
  local probe
  for probe in "${probes[@]}"; do
    say "DRY_RUN probe: ./build ${probe}"
    {
      printf '\n===== DRY_RUN probe: ./build %s =====\n' "${probe}"
    } >>"${log}"
    if ! ( cd "${PIPELINE_DIR}" \
             && DRY_RUN=1 INSTALL_BOOT_BSP=0 ./build ${probe} ) >>"${log}" 2>&1; then
      fail "DRY_RUN probe FAILED: ./build ${probe}"
      rc=1
    fi
  done
  return "${rc}"
}

# ---------------------------------------------------------------------------
# extract_kernel_config <staged-kernel-deb> <dest>
#
# The resolved config is read out of the package the build itself produced, not
# out of a host-side re-resolution: only the former is what the board will run.
# ---------------------------------------------------------------------------
deb_data_tarfile() {
  local deb="$1" tmp="$2"
  if command -v dpkg-deb >/dev/null 2>&1; then
    dpkg-deb --fsys-tarfile "${deb}" >"${tmp}/data.tar"
    return
  fi
  ( cd "${tmp}" && ar x "${deb}" ) || return 1
  local member
  member="$(find "${tmp}" -maxdepth 1 -name 'data.tar*' -print -quit)"
  [[ -n "${member}" ]] || return 1
  case "${member}" in
    *.tar)    mv "${member}" "${tmp}/data.tar" ;;
    *.tar.gz) gzip  -dc "${member}" >"${tmp}/data.tar" ;;
    *.tar.xz) xz    -dc "${member}" >"${tmp}/data.tar" ;;
    *.tar.zst) zstd -dc "${member}" >"${tmp}/data.tar" ;;
    *) return 1 ;;
  esac
}

extract_kernel_config() {
  local deb="$1" dest="$2" tmp
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
  deb_data_tarfile "${deb}" "${tmp}" || return 1
  local name
  name="$(tar -tf "${tmp}/data.tar" | grep -E '(^|\./)boot/config-' | head -n1)"
  [[ -n "${name}" ]] || return 1
  tar -xf "${tmp}/data.tar" -O "${name}" >"${dest}"
  [[ -s "${dest}" ]]
}

# ---------------------------------------------------------------------------
# prebuilt_kernel_release <deb> — the kernel release the PREBUILT BSP package
# actually carries, read from its own /boot/config-<release> member. It is not
# taken from the resolver: the vendor path has no KERNEL_SOURCE_KERNEL_RELEASE,
# and a release string composed from a package version would be a guess.
# ---------------------------------------------------------------------------
prebuilt_kernel_release() {
  local deb="$1" tmp name
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
  deb_data_tarfile "${deb}" "${tmp}" || return 1
  name="$(tar -tf "${tmp}/data.tar" | grep -E '(^|\./)boot/config-' | head -n1)" || true
  [[ -n "${name}" ]] || return 1
  printf '%s' "${name##*/boot/config-}"
}

# The identity read goes through lib/shared/deb-lib.sh — the repo's ONE control
# reader — in a SUBSHELL, because that library sources lib/common.sh, whose ERR
# trap and loggers would otherwise replace this tool's own error handling.
deb_field() (
  set +Eeuo pipefail
  # shellcheck source=../lib/shared/deb-lib.sh
  source "${PIPELINE_DIR}/lib/shared/deb-lib.sh" >/dev/null 2>&1
  deb_control_field "$1" "$2"
)

# ---------------------------------------------------------------------------
# assert_prebuilt_kernel_identity <deb> <expected-package>
#
# A staged .deb is only evidence if it is the package the manifest named at the
# version the repo pinned. Without this the vendor tuple would faithfully record
# whatever archive re-spin happened to be lying in the staging tree.
# ---------------------------------------------------------------------------
assert_prebuilt_kernel_identity() {
  local deb="$1" want_pkg="$2" got_pkg got_ver want_ver rc=0
  got_pkg="$(deb_field "${deb}" Package)"
  got_ver="$(deb_field "${deb}" Version)"
  [[ "${got_pkg}" == "${want_pkg}" ]] || {
    fail "staged prebuilt kernel package is '${got_pkg:-<unreadable>}', expected '${want_pkg}' (${deb})"; rc=1
  }
  want_ver="$(sed -n "s/^${want_pkg}=\(.*\)$/\1/p" \
    "${PIPELINE_DIR}/manifests/armbian-bsp-deb-versions.txt" 2>/dev/null | head -n1)"
  if [[ -n "${want_ver}" && "${got_ver}" != "${want_ver}" ]]; then
    fail "staged '${want_pkg}' is version '${got_ver:-<unreadable>}', but manifests/armbian-bsp-deb-versions.txt pins '${want_ver}'"
    rc=1
  fi
  (( rc == 0 )) && say "  prebuilt kernel package: ${got_pkg} ${got_ver} (pin-verified)"
  return "${rc}"
}

# ---------------------------------------------------------------------------
# assert_test_symbols <config> <expect: on|off>
# ---------------------------------------------------------------------------
assert_test_symbols() {
  local config="$1" expect="$2" sym rc=0
  for sym in "${CERALIVE_TEST_SYMBOLS[@]}"; do
    if grep -qx "${sym}=y" "${config}"; then
      if [[ "${expect}" == "off" ]]; then
        fail "${sym} is ON in a NON-DEBUG candidate config (${config})"; rc=1
      else
        say "  ${sym}=y (expected ON)"
      fi
    else
      if [[ "${expect}" == "on" ]]; then
        fail "${sym} is NOT ON in the DEBUG candidate config (${config})"; rc=1
      else
        say "  ${sym} not set (expected OFF)"
      fi
    fi
  done
  return "${rc}"
}

# ---------------------------------------------------------------------------
# build_candidate <name>
# ---------------------------------------------------------------------------
build_candidate() {
  local name="$1"
  local board variant
  board="$(candidate_board "${name}")"
  variant="$(candidate_variant "${name}")"

  local verdict_line verdict mode pki root_fpr leaf_fpr eku prod_anchor
  verdict_line="$(read_verdict "${TRUST_VERDICT}" "${board}")" \
    || die "no trust verdict recorded for board '${board}' in ${TRUST_VERDICT}"
  IFS='|' read -r verdict mode pki root_fpr leaf_fpr eku prod_anchor <<<"${verdict_line}"

  case "${verdict}" in
    RAUC|PHYSICAL) ;;
    *) die "board '${board}' has verdict '${verdict:-<none>}' — refusing to build a candidate for a board whose trust could not be evaluated" ;;
  esac
  case "${mode}" in
    development) ;;
    production)
      [[ "${prod_anchor}" == "true" ]] \
        || die "verdict asks for production mode on '${board}' while production_trust_anchor is false — refusing to make a release claim" ;;
    *) die "board '${board}' has no usable build_mode in the verdict (got '${mode:-<none>}')" ;;
  esac

  local label="development-hardware-candidate"
  [[ "${mode}" == "production" ]] && label="production-hardware-candidate"

  # The signing state is exported EXPLICITLY for every real build. Nothing here
  # falls back to an ambient value or to a repo-local default.
  [[ -d "${CERALIVE_RAUC_PKI_DIR}" ]] || die "CERALIVE_RAUC_PKI_DIR is not a directory: ${CERALIVE_RAUC_PKI_DIR}"
  [[ -s "${RAUC_KEYRING_FILE}" ]]     || die "RAUC_KEYRING_FILE is missing or empty: ${RAUC_KEYRING_FILE}"
  if [[ -n "${pki}" && "${pki}" != "${CERALIVE_RAUC_PKI_DIR}" ]]; then
    die "signing env PKI dir (${CERALIVE_RAUC_PKI_DIR}) does not match the verdict's evaluated signer (${pki})"
  fi
  export CERALIVE_BUILD_MODE="${mode}"
  export CERALIVE_RAUC_PKI_DIR RAUC_KEYRING_FILE

  if candidate_is_debug "${name}"; then
    [[ -n "${DEBUG_PASSWORD_HASH:-}" ]] \
      || die "candidate '${name}' is a DEBUG artifact and no CERALIVE_DEBUG_PASSWORD_HASH was supplied (--debug-env)"
    export CERALIVE_DEBUG_IMAGE=1
    export CERALIVE_DEBUG_PASSWORD_HASH="${DEBUG_PASSWORD_HASH}"
  else
    export CERALIVE_DEBUG_IMAGE=0
    unset CERALIVE_DEBUG_PASSWORD_HASH || true
  fi

  # Exported from the REQUIRED --bench-labels, never inherited. orchestrate.sh's
  # own `:-0` default is correct for a direct ./build and catastrophic here: it
  # silently bakes production PARTLABELs into an artifact destined for a bench
  # board whose second medium already carries them (see the header incident note).
  export CERALIVE_BENCH_LABELS="${BENCH_LABELS}"

  # The recovery loader is resolved for THIS board. Recording another board's
  # loader digest here would name an unusable recovery path in the evidence an
  # operator reads precisely when the candidate has already bricked the board.
  local loader_entry
  loader_entry="$("${HERE}/fetch-rk3588-loader.sh" --print-identity "${board}")" \
    || die "no MaskROM recovery loader is pinned for board '${board}' in ci/fetch-rk3588-loader.sh — refusing to emit a candidate whose recorded recovery path is another board's"
  IFS=$'\t' read -r LOADER_NAME LOADER_SHA256 LOADER_URL <<<"${loader_entry}"

  local -a build_args=("${board}" --variant "${variant}")

  local stem log
  stem="$(evidence_stem "${name}")"
  log="${EVIDENCE_DIR}/${stem}.log"
  say "building ${name}: ./build ${build_args[*]}"
  say "  build mode=${CERALIVE_BUILD_MODE} label=${label} debug=${CERALIVE_DEBUG_IMAGE}"
  say "  CERALIVE_BENCH_LABELS=${CERALIVE_BENCH_LABELS} (bench PARTLABEL overlay: $(bench_labels_desc))"
  say "  recovery loader (${board}): ${LOADER_NAME} sha256=${LOADER_SHA256}"
  say "  pki=${CERALIVE_RAUC_PKI_DIR} keyring=${RAUC_KEYRING_FILE}"

  # pipefail is already set; tee must not be allowed to mask a failed build.
  ( cd "${PIPELINE_DIR}" && ./build "${build_args[@]}" ) 2>&1 | tee "${log}"

  record_tuple "${name}" "${board}" "${variant}" "${label}" \
    "${verdict}" "${root_fpr}" "${leaf_fpr}" "${eku}" "${log}"
}

# ---------------------------------------------------------------------------
# record_tuple — the artifact tuple. Everything a later receipt has to be able
# to bind: which board, which compatible string, which variant, which kernel
# source and patch series, which A tree, which bytes.
# ---------------------------------------------------------------------------
record_tuple() {
  local name="$1" board="$2" variant="$3" label="$4" verdict="$5"
  local root_fpr="$6" leaf_fpr="$7" eku="$8" log="$9"

  local raw bundle
  raw="$(sed -E 's/\r$//' "${log}" | sed -n 's/.*flashable image: \([^ ]*\.raw\).*/\1/p' | tail -n1)"
  bundle="$(sed -E 's/\r$//' "${log}" | sed -n 's/.*signed bundle: \([^ ]*\.raucb\).*/\1/p' | tail -n1)"
  [[ -s "${raw}" ]]    || die "could not resolve the emitted .raw from ${log}" 1
  [[ -s "${bundle}" ]] || die "could not resolve the emitted .raucb from ${log}" 1

  local resolved
  if candidate_is_source_built "${name}"; then
    resolved="$( cd "${PIPELINE_DIR}" && CERALIVE_KERNEL_VARIANT="${variant}" \
      lib/resolve.sh "${board}" --variant "${variant}" 2>/dev/null )" \
      || die "could not re-resolve the manifest for ${board}/${variant}" 1
  else
    resolved="$( cd "${PIPELINE_DIR}" && lib/resolve.sh "${board}" 2>/dev/null )" \
      || die "could not re-resolve the manifest for ${board} (no variant overlay)" 1
  fi
  local kernel_commit patches_commit kernel_tag dtb_name board_id kernel_release kernel_pkg
  kernel_commit="$(sed -n "s/^KERNEL_SOURCE_COMMIT='\(.*\)'$/\1/p" <<<"${resolved}")"
  kernel_tag="$(sed -n "s/^KERNEL_SOURCE_TAG='\(.*\)'$/\1/p" <<<"${resolved}")"
  patches_commit="$(sed -n "s/^KERNEL_SOURCE_PATCHES_COMMIT='\(.*\)'$/\1/p" <<<"${resolved}")"
  kernel_release="$(sed -n "s/^KERNEL_SOURCE_KERNEL_RELEASE='\(.*\)'$/\1/p" <<<"${resolved}")"
  dtb_name="$(sed -n "s/^DTB_NAME='\(.*\)'$/\1/p" <<<"${resolved}")"
  board_id="$(sed -n "s/^BOARD_ID='\(.*\)'$/\1/p" <<<"${resolved}")"
  kernel_pkg="$(sed -n "s/^KERNEL_PACKAGES='\(.*\)'$/\1/p" <<<"${resolved}" | awk '{print $1}')"

  local kdeb config expect="off" kernel_source="prebuilt-bsp"
  config="${EVIDENCE_DIR}/$(evidence_stem "${name}").config"

  if candidate_is_source_built "${name}"; then
    kernel_source="built-from-source"
    [[ -n "${kernel_release}" ]] \
      || die "candidate '${name}' resolves a kernel_source variant but no KERNEL_SOURCE_KERNEL_RELEASE" 1
    # The resolved config comes out of the kernel package this build produced.
    kdeb="$(find "${PIPELINE_DIR}/mkosi/.staging/${board}/kernel-build" -maxdepth 1 \
              -name "linux-image-${kernel_release}_*.deb" -print -quit 2>/dev/null || true)"
    [[ -n "${kdeb}" ]] || die "no built kernel package found for ${kernel_release}" 1
    extract_kernel_config "${kdeb}" "${config}" \
      || die "could not extract /boot/config-${kernel_release} from ${kdeb}" 1
  else
    # The vendor candidate ships a PREBUILT BSP kernel, so the truth about which
    # kernel this artifact runs is the fetched .deb under the board's BSP staging
    # area — identity-checked against the committed pin, with the release string
    # and the config both read out of the package payload rather than resolved.
    [[ -n "${kernel_pkg}" ]] \
      || die "candidate '${name}' resolves no KERNEL_PACKAGES to identity-check" 1
    kdeb="$(find "${PIPELINE_DIR}/mkosi/.staging/${board}/bsp" -maxdepth 1 \
              -name "${kernel_pkg}_*.deb" -print -quit 2>/dev/null || true)"
    [[ -n "${kdeb}" ]] \
      || die "no staged prebuilt kernel package '${kernel_pkg}' under mkosi/.staging/${board}/bsp" 1
    assert_prebuilt_kernel_identity "${kdeb}" "${kernel_pkg}" || exit 1
    kernel_release="$(prebuilt_kernel_release "${kdeb}")" \
      || die "could not derive a kernel release from ${kdeb} (no /boot/config-<release>)" 1
    extract_kernel_config "${kdeb}" "${config}" \
      || die "could not extract /boot/config-${kernel_release} from ${kdeb}" 1
  fi

  candidate_is_debug "${name}" && expect="on"
  say "verifying CeraLive test symbols in ${name} (expect ${expect})"
  assert_test_symbols "${config}" "${expect}" || exit 1

  if ! candidate_is_source_built "${name}"; then
    # The edge closure manifests are the MAINLINE contract — required-symbols.list
    # demands CONFIG_VIDEO_SYNOPSYS_HDMIRX, which the vendor kernel does not and
    # must not carry (its HDMI-RX driver is rk_hdmirx). Applying them here would
    # fail a correct vendor artifact, so the vendor gate is the vendor claim:
    # the package's own config exists and carries the vendor HDMI-RX driver.
    grep -qx "${VENDOR_HDMIRX_SYMBOL}=y" "${config}" \
      || die "the vendor candidate '${name}' resolves ${VENDOR_HDMIRX_SYMBOL}=y nowhere in ${config} — this artifact has no vendor HDMI-RX driver" 1
    say "  vendor gate: ${VENDOR_HDMIRX_SYMBOL}=y present in ${kernel_release}'s own config"
  # The production closure gate is the manifest, not a hand list: run the real
  # forbidden manifest against a non-debug candidate's own resolved config.
  elif [[ "${expect}" == "off" ]]; then
    ( cd "${PIPELINE_DIR}" && lib/verify-kernel-config.sh \
        --config "${config}" \
        --required manifests/kernel/required-symbols.list \
        --forbidden manifests/kernel/forbidden-symbols.list ) \
      || die "the non-debug candidate '${name}' violates the required/forbidden symbol manifests" 1
  else
    ( cd "${PIPELINE_DIR}" && lib/verify-kernel-config.sh \
        --config "${config}" \
        --required manifests/kernel/required-symbols.list ) \
      || die "the debug candidate '${name}' lost a REQUIRED symbol" 1
  fi

  local raw_sha bundle_sha
  raw_sha="$(sha256sum "${raw}" | cut -d' ' -f1)"
  bundle_sha="$(sha256sum "${bundle}" | cut -d' ' -f1)"

  local eku_json
  eku_json="$(json_str_list "${eku}")"

  local bench_json="false" partlabel_set="production-frozen"
  if [[ "${CERALIVE_BENCH_LABELS}" == "1" ]]; then
    bench_json="true"; partlabel_set="bench-x-prefixed"
  fi

  {
    printf '{\n'
    printf '  "schema_version": %s,\n' "${SCHEMA_VERSION}"
    printf '  "tool": %s,\n'            "$(json_str "${TOOL_NAME}")"
    printf '  "candidate": %s,\n'       "$(json_str "${name}")"
    printf '  "label": %s,\n'           "$(json_str "${label}")"
    printf '  "built_at": %s,\n'        "$(json_str "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
    printf '  "board": %s,\n'           "$(json_str "${board}")"
    printf '  "board_id": %s,\n'        "$(json_str "${board_id}")"
    printf '  "compatible": %s,\n'      "$(json_str "ceralive-${board_id}")"
    printf '  "variant": %s,\n'         "$(json_str "${variant}")"
    printf '  "dtb_name": %s,\n'        "$(json_str "${dtb_name}")"
    printf '  "kernel_release": %s,\n'  "$(json_str "${kernel_release}")"
    printf '  "kernel_source_tag": %s,\n'    "$(json_str "${kernel_tag}")"
    printf '  "kernel_source_commit": %s,\n' "$(json_str "${kernel_commit}")"
    printf '  "patches_commit": %s,\n'  "$(json_str "${patches_commit}")"
    printf '  "tested_a_commit": %s,\n' "$(json_str "${A_COMMIT}")"
    printf '  "tested_a_tree": %s,\n'   "$(json_str "${A_TREE}")"
    printf '  "raw": %s,\n'             "$(json_str "$(basename "${raw}")")"
    printf '  "raw_path": %s,\n'        "$(json_str "${raw}")"
    printf '  "raw_sha256": %s,\n'      "$(json_str "${raw_sha}")"
    printf '  "bundle": %s,\n'          "$(json_str "$(basename "${bundle}")")"
    printf '  "bundle_path": %s,\n'     "$(json_str "${bundle}")"
    printf '  "bundle_sha256": %s,\n'   "$(json_str "${bundle_sha}")"
    printf '  "kernel_source": %s,\n'   "$(json_str "${kernel_source}")"
    printf '  "kernel_package": %s,\n'  "$(json_str "${kernel_pkg}")"
    printf '  "loader_board": %s,\n'    "$(json_str "${board}")"
    printf '  "loader_name": %s,\n'     "$(json_str "${LOADER_NAME:-}")"
    printf '  "loader_url": %s,\n'      "$(json_str "${LOADER_URL:-}")"
    printf '  "loader_sha256": %s,\n'   "$(json_str "${LOADER_SHA256:-}")"
    printf '  "build_mode": %s,\n'      "$(json_str "${CERALIVE_BUILD_MODE}")"
    printf '  "debug_image": %s,\n'     "$( [[ "${CERALIVE_DEBUG_IMAGE}" == "1" ]] && echo true || echo false )"
    printf '  "bench_labels": %s,\n'    "${bench_json}"
    printf '  "partlabel_set": %s,\n'   "$(json_str "${partlabel_set}")"
    printf '  "ceralive_test_symbols": %s,\n' "$(json_str "${expect}")"
    printf '  "deployment_verdict": %s,\n'    "$(json_str "${verdict}")"
    printf '  "rauc_pki_dir": %s,\n'    "$(json_str "${CERALIVE_RAUC_PKI_DIR}")"
    printf '  "rauc_keyring_file": %s,\n' "$(json_str "${RAUC_KEYRING_FILE}")"
    printf '  "installed_root_sha256_fingerprint": %s,\n' "$(json_str "${root_fpr}")"
    printf '  "signer_leaf_sha256_fingerprint": %s,\n'    "$(json_str "${leaf_fpr}")"
    printf '  "signer_eku": %s,\n'      "${eku_json}"
    printf '  "evidence_stem": %s,\n'   "$(json_str "$(evidence_stem "${name}")")"
    printf '  "config": %s,\n'          "$(json_str "$(basename "${config}")")"
    printf '  "build_log": %s\n'        "$(json_str "$(basename "${log}")")"
    printf '}\n'
  } >"${EVIDENCE_DIR}/$(evidence_stem "${name}").tuple.json"

  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' \
    "${EVIDENCE_DIR}/$(evidence_stem "${name}").tuple.json" \
    || die "emitted a non-parseable tuple for ${name}" 1
  say "tuple: ${EVIDENCE_DIR}/$(evidence_stem "${name}").tuple.json"
}

# ---------------------------------------------------------------------------
# self-test — the refusals, not the builds. Each leg drives the shipped code.
# ---------------------------------------------------------------------------
self_test() {
  local t rc=0 pass=0 fail_n=0
  t="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${t}'" RETURN

  ok()  { printf '  ok   %s\n' "$*"; pass=$((pass+1)); }
  bad() { printf '  FAIL %s\n' "$*"; fail_n=$((fail_n+1)); rc=1; }

  cat >"${t}/verdict.json" <<'JSON'
{"schema_version":1,"boards":[
 {"board":"rock-5b-plus","verdict":"RAUC","build_mode":"development",
  "installed_root":{"sha256_fingerprint":"aa:bb"},
  "candidate_signer":{"pki_dir":"PKI_DIR","leaf_sha256_fingerprint":"cc:dd",
                      "extended_key_usage_observed":["emailProtection","codeSigning"]},
  "checks":{"production_trust_anchor":false}},
 {"board":"orange-pi-5-plus","verdict":"UNKNOWN","build_mode":null,
  "installed_root":{},"candidate_signer":{},"checks":{"production_trust_anchor":false}},
 {"board":"x86-minipc","verdict":"RAUC","build_mode":"production",
  "installed_root":{"sha256_fingerprint":"ee:ff"},
  "candidate_signer":{"pki_dir":"PKI_DIR","leaf_sha256_fingerprint":"11:22",
                      "extended_key_usage_observed":["codeSigning"]},
  "checks":{"production_trust_anchor":false}}
]}
JSON
  mkdir -p "${t}/pki"; : >"${t}/keyring.pem"; printf 'x\n' >"${t}/keyring.pem"
  sed -i "s#PKI_DIR#${t}/pki#g" "${t}/verdict.json"
  printf 'CERALIVE_RAUC_PKI_DIR=%s\nRAUC_KEYRING_FILE=%s\n' "${t}/pki" "${t}/keyring.pem" >"${t}/sign.env"
  printf 'CERALIVE_DEBUG_PASSWORD_HASH=$6$fake$hash\n' >"${t}/debug.env"

  # 1. the verdict reader returns the recorded tuple, not a default
  local line
  line="$(read_verdict "${t}/verdict.json" rock-5b-plus)"
  [[ "${line}" == "RAUC|development|${t}/pki|aa:bb|cc:dd|emailProtection,codeSigning|false" ]] \
    && ok "verdict reader returns the recorded trust tuple" \
    || bad "verdict reader returned: ${line}"

  # 2. an unevaluated board is refused, not defaulted
  read_verdict "${t}/verdict.json" orange-pi-5-plus >/dev/null \
    && [[ "$(read_verdict "${t}/verdict.json" orange-pi-5-plus)" == "UNKNOWN|"* ]] \
    && ok "an UNKNOWN board is reported as UNKNOWN (never as a usable mode)" \
    || bad "UNKNOWN board handling"

  # 3. a board with no entry at all is an error
  if read_verdict "${t}/verdict.json" no-such-board >/dev/null 2>&1; then
    bad "a board absent from the verdict was accepted"
  else
    ok "a board absent from the verdict is refused"
  fi

  # 4. a dirty worktree is refused, and the check is non-vacuous on a clean one
  mkdir -p "${t}/repo"
  ( cd "${t}/repo" && git init -q . \
      && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m x ) >/dev/null 2>&1
  ( assert_clean_worktree "${t}/repo" ) >/dev/null 2>&1 \
    && ok "a clean worktree passes the worktree check" \
    || bad "the worktree check rejected a clean worktree"
  : >"${t}/repo/dirty"
  if ( assert_clean_worktree "${t}/repo" ) >/dev/null 2>&1; then
    bad "a dirty worktree was accepted"
  else
    ok "a dirty worktree is refused"
  fi

  # 5. a debug candidate with no --debug-env is refused
  if "${BASH_SOURCE[0]}" --only rock-edge-test --trust-verdict "${t}/verdict.json" \
       --signing-env "${t}/sign.env" --evidence "${t}/ev" --skip-probes \
       --bench-labels 1 >/dev/null 2>&1; then
    bad "a debug candidate without --debug-env was accepted"
  else
    ok "a debug candidate without --debug-env is refused"
  fi

  # 6. an unset signing env is refused
  printf 'CERALIVE_RAUC_PKI_DIR=%s\n' "${t}/pki" >"${t}/half.env"
  if "${BASH_SOURCE[0]}" --only rock-edge --trust-verdict "${t}/verdict.json" \
       --signing-env "${t}/half.env" --evidence "${t}/ev" --skip-probes \
       --bench-labels 0 >/dev/null 2>&1; then
    bad "a half-specified signing env was accepted"
  else
    ok "a half-specified signing env is refused"
  fi

  # 7. a candidate name outside the closed table is refused
  if "${BASH_SOURCE[0]}" --only x86-edge --trust-verdict "${t}/verdict.json" \
       --signing-env "${t}/sign.env" --evidence "${t}/ev" --skip-probes \
       --bench-labels 0 >/dev/null 2>&1; then
    bad "an unknown candidate name was accepted"
  else
    ok "an unknown candidate name is refused"
  fi

  # 7b. --bench-labels is REQUIRED, and only 0 or 1 is a value. An ambient
  # CERALIVE_BENCH_LABELS must not satisfy it — that is the whole defect.
  local out
  out="$( CERALIVE_BENCH_LABELS=1 "${BASH_SOURCE[0]}" --only rock-edge \
            --trust-verdict "${t}/verdict.json" --signing-env "${t}/sign.env" \
            --evidence "${t}/ev" --skip-probes 2>&1 )" \
    && bad "a build with no --bench-labels was accepted" \
    || {
      [[ "${out}" == *"refusing to build without --bench-labels"* ]] \
        && ok "a build with no --bench-labels is refused, and says why" \
        || bad "the no---bench-labels refusal did not name the flag: ${out}"
    }
  local badval
  for badval in "" yes 2 true on; do
    if "${BASH_SOURCE[0]}" --only rock-edge --trust-verdict "${t}/verdict.json" \
         --signing-env "${t}/sign.env" --evidence "${t}/ev" --skip-probes \
         --bench-labels "${badval}" >/dev/null 2>&1; then
      bad "--bench-labels accepted the non-boolean value '${badval}'"
    else
      ok "--bench-labels refuses the non-boolean value '${badval:-<empty>}'"
    fi
  done

  # 8. the symbol assertion is non-vacuous in BOTH directions
  printf 'CONFIG_X=y\n' >"${t}/prod.config"
  assert_test_symbols "${t}/prod.config" off >/dev/null 2>&1 \
    && ok "a clean config passes the production symbol assertion" \
    || bad "production symbol assertion rejected a clean config"
  assert_test_symbols "${t}/prod.config" on >/dev/null 2>&1 \
    && bad "the debug symbol assertion passed a config with no test symbols" \
    || ok "the debug symbol assertion REJECTS a config with no test symbols"
  { printf 'CONFIG_VIDEO_ROCKCHIP_RKVENC_CERALIVE_TEST=y\n'
    printf 'CONFIG_VIDEO_ROCKCHIP_HDMIRX_CERALIVE_TEST=y\n'
    printf 'CONFIG_DMABUF_HEAPS_CERALIVE_TEST=y\n'; } >"${t}/dbg.config"
  assert_test_symbols "${t}/dbg.config" on >/dev/null 2>&1 \
    && ok "a debug config passes the debug symbol assertion" \
    || bad "debug symbol assertion rejected a debug config"
  assert_test_symbols "${t}/dbg.config" off >/dev/null 2>&1 \
    && bad "the production symbol assertion passed a LEAKED debug config" \
    || ok "the production symbol assertion REJECTS a leaked debug config"

  # 9. the candidate table: the vendor candidate names the prebuilt overlay
  [[ "$(candidate_board rock-vendor)" == "rock-5b-plus" ]] \
    && ok "rock-vendor maps to board rock-5b-plus" \
    || bad "rock-vendor board mapping"
  [[ "$(candidate_variant rock-vendor)" == "vendor" ]] \
    && ok "rock-vendor maps to variant 'vendor' (the prebuilt Armbian BSP kernel)" \
    || bad "rock-vendor variant mapping is not 'vendor'"
  [[ "$(candidate_variant rock-vendor)" != "default" ]] \
    && ok "rock-vendor never relies on the bare default (which now resolves edge)" \
    || bad "rock-vendor still relies on the bare default"
  candidate_is_source_built rock-vendor \
    && bad "rock-vendor is treated as a source-built candidate" \
    || ok "rock-vendor is NOT source-built (no KERNEL_SOURCE_* expected)"
  candidate_is_source_built rock-edge \
    && ok "rock-edge IS source-built" \
    || bad "rock-edge lost its source-built classification"

  # 10. each board binds its OWN recovery loader, and they differ
  local rock_loader opi_loader
  rock_loader="$("${HERE}/fetch-rk3588-loader.sh" --print-sha256 rock-5b-plus)"
  opi_loader="$("${HERE}/fetch-rk3588-loader.sh" --print-sha256 orange-pi-5-plus)"
  [[ -n "${rock_loader}" && -n "${opi_loader}" && "${rock_loader}" != "${opi_loader}" ]] \
    && ok "the two RK3588 boards pin DIFFERENT recovery loaders" \
    || bad "the recovery loaders did not resolve to two distinct digests"
  if "${HERE}/fetch-rk3588-loader.sh" --print-sha256 x86-minipc >/dev/null 2>&1; then
    bad "a board with no pinned loader was answered anyway"
  else
    ok "a board with no pinned recovery loader is refused, never defaulted"
  fi

  # 11. evidence stems separate the two bench-labels modes
  local stem_one stem_zero
  stem_one="$(BENCH_LABELS=1; evidence_stem rock-edge)"
  stem_zero="$(BENCH_LABELS=0; evidence_stem rock-edge)"
  [[ "${stem_one}" != "${stem_zero}" ]] \
    && ok "evidence stems differ across --bench-labels modes (${stem_one} vs ${stem_zero})" \
    || bad "both bench-labels modes resolve to the same evidence stem"

  printf '\n== %d passed, %d failed\n' "${pass}" "${fail_n}"
  return "${rc}"
}

# ---------------------------------------------------------------------------
main() {
  local only="" evidence="" debug_env="" skip_probes=0
  TRUST_VERDICT=""; SIGNING_ENV=""; BENCH_LABELS=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --only)          only="${2:-}"; shift 2 ;;
      --trust-verdict) TRUST_VERDICT="${2:-}"; shift 2 ;;
      --signing-env)   SIGNING_ENV="${2:-}"; shift 2 ;;
      --debug-env)     debug_env="${2:-}"; shift 2 ;;
      --evidence)      evidence="${2:-}"; shift 2 ;;
      --bench-labels)  BENCH_LABELS="${2:-}"; shift 2 ;;
      --skip-probes)   skip_probes=1; shift ;;
      --self-test)     self_test; exit $? ;;
      -h|--help)       usage; exit 0 ;;
      *) usage; die "unknown option: $1" ;;
    esac
  done

  [[ -n "${only}" ]]           || { usage; die "--only is required"; }
  [[ -n "${TRUST_VERDICT}" ]]  || { usage; die "--trust-verdict is required"; }
  [[ -n "${SIGNING_ENV}" ]]    || { usage; die "--signing-env is required"; }
  [[ -n "${evidence}" ]]       || { usage; die "--evidence is required"; }
  [[ -s "${TRUST_VERDICT}" ]]  || die "trust verdict is missing or empty: ${TRUST_VERDICT}"

  # No default, and deliberately not read from the environment even when one is
  # already exported: a value this tool cannot show in its own argv is a value
  # nobody reviewing the dispatch can audit. AGENTS.md, "Bench PARTLABEL overlay".
  [[ -n "${BENCH_LABELS}" ]] || {
    usage
    die "refusing to build without --bench-labels 0|1 — this script must never silently default this flag; a wrong PARTLABEL set writes A/B recovery state to the WRONG PHYSICAL DEVICE on a dual-media bench rig (see the incident writeup in AGENTS.md, 'Bench PARTLABEL overlay')"
  }
  case "${BENCH_LABELS}" in
    0|1) ;;
    *) die "--bench-labels takes exactly 0 or 1 (got '${BENCH_LABELS}')" ;;
  esac
  say "bench PARTLABEL overlay: CERALIVE_BENCH_LABELS=${BENCH_LABELS} ($(bench_labels_desc))"

  local -a selected=()
  if [[ "${only}" == "all" ]]; then
    selected=(rock-edge orange-edge rock-edge-test)
  else
    local item
    IFS=',' read -r -a selected <<<"${only}"
    for item in "${selected[@]}"; do
      candidate_board "${item}" >/dev/null \
        || die "unknown candidate '${item}' (valid: all rock-edge orange-edge rock-edge-test rock-vendor)"
    done
  fi

  local needs_debug=0 c
  for c in "${selected[@]}"; do candidate_is_debug "${c}" && needs_debug=1; done
  if (( needs_debug )); then
    [[ -n "${debug_env}" ]] || die "a DEBUG candidate is selected but --debug-env was not supplied"
  elif [[ -n "${debug_env}" ]]; then
    die "--debug-env was supplied but no debug candidate is selected"
  fi

  load_env_file "${SIGNING_ENV}" CERALIVE_RAUC_PKI_DIR RAUC_KEYRING_FILE

  # The debug hash is held UNEXPORTED until the one build that may see it. The
  # orchestrator refuses CERALIVE_DEBUG_PASSWORD_HASH without
  # CERALIVE_DEBUG_IMAGE=1, so an exported hash would fail every DRY_RUN probe
  # and every non-debug candidate — and, worse, a version of that pairing that
  # did not fail would ship a debug credential in a production artifact.
  DEBUG_PASSWORD_HASH=""
  if (( needs_debug )); then
    load_env_file "${debug_env}" CERALIVE_DEBUG_PASSWORD_HASH
    DEBUG_PASSWORD_HASH="${CERALIVE_DEBUG_PASSWORD_HASH}"
    unset CERALIVE_DEBUG_PASSWORD_HASH
  fi

  assert_clean_worktree "${PIPELINE_DIR}"
  A_COMMIT="$(git -C "${PIPELINE_DIR}" rev-parse HEAD)"
  A_TREE="$(git -C "${PIPELINE_DIR}" rev-parse 'HEAD^{tree}')"

  EVIDENCE_DIR="$(cd "$(dirname "${evidence}")" 2>/dev/null && pwd)/$(basename "${evidence}")" \
    || die "cannot resolve --evidence parent: ${evidence}"
  mkdir -p "${EVIDENCE_DIR}"

  say "A commit ${A_COMMIT}"
  say "A tree   ${A_TREE}"
  say "candidates: ${selected[*]}"

  if (( skip_probes == 0 )); then
    say "running the eight DRY_RUN probes"
    run_dry_run_probes "${EVIDENCE_DIR}/dry-run-probes.bench-labels-${BENCH_LABELS}.log" \
      || die "one or more DRY_RUN probes failed — no real build was started" 1
    say "all eight DRY_RUN probes exited 0"
  fi

  for c in "${selected[@]}"; do
    build_candidate "${c}"
  done

  say "done: ${#selected[@]} candidate(s) built and verified"
}

main "$@"
