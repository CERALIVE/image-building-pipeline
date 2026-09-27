#!/usr/bin/env bash
#
# hardware-candidate-bench-labels.test.sh — proof that
# ci/build-hardware-candidates.sh can never build a candidate whose PARTLABEL set
# was decided by an ambient environment.
#
# THE DEFECT THIS LOCKS DOWN (2026-08-10, real Rock 5B+). The script invoked
# `./build` without ever exporting CERALIVE_BENCH_LABELS, so the value came from
# whatever the dispatch shell happened to carry. Orchestrator dispatches are
# stateless, so some candidates got the bench overlay and some silently fell
# through to lib/orchestrate.sh's `:-0` default (correct for a DIRECT ./build,
# catastrophic here). One `rock-edge-test` candidate was therefore built with the
# FROZEN production PARTLABELs and booted on a bench board that carries BOTH a
# bench microSD (`x`-prefixed) and an onboard eMMC using the plain set: its fstab
# resolved /boot and /data on the eMMC, a RAUC recovery transition wrote A/B
# state to the wrong physical device, and the board needed hand recovery.
#
# The four properties below are the fix, and the FIRST one is the load-bearing
# one — a default of any kind, including an ambient one, reopens the defect.
#
#   (a) the script REFUSES to run without --bench-labels, even with
#       CERALIVE_BENCH_LABELS already exported in the environment;
#   (b) --bench-labels 1 exports CERALIVE_BENCH_LABELS=1 to the ./build process;
#   (c) --bench-labels 0 exports CERALIVE_BENCH_LABELS=0 to the ./build process;
#   (d) the artifact tuple records which mode built that specific artifact.
#
# (b)/(c) are observed at the ONLY place that matters — the environment `./build`
# actually receives — by driving the real shipped script inside a throwaway
# pipeline tree whose `./build` is a stub that dumps its own environment. No
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

printf 'hardware-candidate-bench-labels: the --bench-labels contract\n'

[[ -x "${TOOL}" ]] || { printf '  FAIL tool not executable: %s\n' "${TOOL}"; exit 1; }
for dep in git ar tar python3; do
  command -v "${dep}" >/dev/null 2>&1 \
    || { printf '  FAIL missing test dependency: %s\n' "${dep}"; exit 1; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/bench-labels-XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

KERNEL_RELEASE="9.9.9-test-rk3588"
BOARD="rock-5b-plus"

# ---------------------------------------------------------------------------
# A throwaway pipeline tree: a clean git worktree holding the REAL tool plus the
# minimum set of stubs it shells out to. The tool resolves everything relative to
# its own checkout, so a copied tree is a complete, isolated fixture.
# ---------------------------------------------------------------------------
make_fake_pipeline() {
  local root="$1" resolver="${2:-stub}"
  mkdir -p "${root}/ci" "${root}/lib" "${root}/manifests/kernel" \
           "${root}/mkosi/.staging/${BOARD}/kernel-build" "${root}/out"
  cp "${TOOL}" "${root}/ci/build-hardware-candidates.sh"

  # The REAL board→loader table: the recorded recovery loader is board-specific,
  # so a stub would leave that binding untested.
  cp "${PIPELINE_DIR}/ci/fetch-rk3588-loader.sh" "${root}/ci/fetch-rk3588-loader.sh"

  # The stub build: record the environment it was handed, then emit the two
  # artifacts and the two log lines record_tuple parses out of the build log.
  cat >"${root}/build" <<STUB
#!/usr/bin/env bash
set -euo pipefail
printf 'CERALIVE_BENCH_LABELS=%s\n' "\${CERALIVE_BENCH_LABELS-<UNSET>}" >"\${CERALIVE_BENCH_PROBE}"
printf 'CERALIVE_BUILD_MODE=%s\n'   "\${CERALIVE_BUILD_MODE-<UNSET>}"  >>"\${CERALIVE_BENCH_PROBE}"
printf 'CERALIVE_DEBUG_IMAGE=%s\n'  "\${CERALIVE_DEBUG_IMAGE-<UNSET>}" >>"\${CERALIVE_BENCH_PROBE}"
printf 'CERALIVE_FIRST_PARTY_LOCAL_DEBS_DIR=%s\n' "\${CERALIVE_FIRST_PARTY_LOCAL_DEBS_DIR-<UNSET>}" >>"\${CERALIVE_BENCH_PROBE}"
if [[ -n "\${CERALIVE_FIRST_PARTY_LOCAL_DEBS_DIR:-}" ]]; then
  printf '[{"package":"ceralive-device","version":"99.2","arch":"arm64","sha256":"%s","filename":"ceralive-device_99.2_arm64.deb"}]\n' \
    "\$(printf x | sha256sum | cut -d' ' -f1)" >"${root}/mkosi/.staging/${BOARD}/first-party-local-override.json"
fi
raw="${root}/out/image.raw"
bundle="${root}/out/image.raucb"
printf 'raw\n' >"\${raw}"
printf 'bundle\n' >"\${bundle}"
printf 'emitted flashable image: %s\n' "\${raw}"
printf 'emitted signed bundle: %s\n' "\${bundle}"
STUB
  chmod +x "${root}/build"

  if [[ "${resolver}" == real ]]; then
    # Resolve the actual family and board manifests, not a second copy of their pins.
    cat >"${root}/lib/resolve.sh" <<RESOLVE
#!/usr/bin/env bash
exec "${PIPELINE_DIR}/lib/resolve.sh" "\$@"
RESOLVE
  else
    cat >"${root}/lib/resolve.sh" <<RESOLVE
#!/usr/bin/env bash
printf "KERNEL_SOURCE_COMMIT='%s'\n" deadbeef
printf "KERNEL_SOURCE_TAG='%s'\n" v9.9.9
printf "KERNEL_SOURCE_PATCHES_COMMIT='%s'\n" cafebabe
printf "KERNEL_SOURCE_KERNEL_RELEASE='%s'\n" "${KERNEL_RELEASE}"
printf "DTB_NAME='%s'\n" rk3588-rock-5b-plus.dtb
printf "BOARD_ID='%s'\n" "${BOARD}"
printf "KERNEL_PACKAGES='%s'\n" "linux-image-${KERNEL_RELEASE}"
RESOLVE
  fi
  chmod +x "${root}/lib/resolve.sh"

  printf '#!/usr/bin/env bash\nexit 0\n' >"${root}/lib/verify-kernel-config.sh"
  chmod +x "${root}/lib/verify-kernel-config.sh"
  : >"${root}/manifests/kernel/required-symbols.list"
  : >"${root}/manifests/kernel/forbidden-symbols.list"

  make_kernel_deb "${root}/mkosi/.staging/${BOARD}/kernel-build/linux-image-${KERNEL_RELEASE}_1_arm64.deb"

  printf 'mkosi/\nout/\n' >"${root}/.gitignore"
  git -C "${root}" init -q .
  git -C "${root}" add -A
  git -C "${root}" -c user.email=t@t -c user.name=t commit -q -m fixture
}

# A real ar-format .deb whose data tarball carries /boot/config-<release>. The
# tool reads the resolved config out of the package the build produced, so a
# stubbed extraction would leave the whole tuple path untested.
make_kernel_deb() {
  local dest="$1" stage
  stage="$(mktemp -d "${WORK}/deb-XXXXXX")"
  mkdir -p "${stage}/root/boot"
  printf 'CONFIG_ARCH_ROCKCHIP=y\nCONFIG_DMABUF_HEAPS=y\n' \
    >"${stage}/root/boot/config-${KERNEL_RELEASE}"
  if [[ "${2:-}" == debug ]]; then
    printf 'CONFIG_ROCKCHIP_MPP_CERALIVE_TEST=y\n' >>"${stage}/root/boot/config-${KERNEL_RELEASE}"
  fi
  tar -C "${stage}/root" -czf "${stage}/data.tar.gz" ./boot
  mkdir -p "${stage}/ctl"
  printf 'Package: linux-image-%s\nVersion: 1\nArchitecture: arm64\n' "${KERNEL_RELEASE}" \
    >"${stage}/ctl/control"
  tar -C "${stage}/ctl" -czf "${stage}/control.tar.gz" ./control
  printf '2.0\n' >"${stage}/debian-binary"
  ( cd "${stage}" && ar rc "${dest}" debian-binary control.tar.gz data.tar.gz ) >/dev/null 2>&1
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

# run_candidate <root> <inputs> <evidence> <probe> [extra args...]
run_candidate() {
  local root="$1" inputs="$2" ev="$3" probe="$4"; shift 4
  CERALIVE_BENCH_PROBE="${probe}" "${root}/ci/build-hardware-candidates.sh" \
    --only rock-edge \
    --trust-verdict "${inputs}/verdict.json" \
    --signing-env "${inputs}/sign.env" \
    --evidence "${ev}" \
    --skip-probes "$@"
}

tuple_field() {
  python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))[sys.argv[2]]))' "$1" "$2"
}

ROOT="${WORK}/pipeline"
INPUTS="${WORK}/inputs"
mkdir -p "${INPUTS}"
make_inputs "${INPUTS}"
make_fake_pipeline "${ROOT}"

# ---------------------------------------------------------------------------
# (a) REFUSAL — the single most important property. An exported
#     CERALIVE_BENCH_LABELS must NOT satisfy the requirement: that ambient value
#     is precisely what the incident proved unreviewable.
# ---------------------------------------------------------------------------
probe_a="${WORK}/probe-a"
out_a="$( CERALIVE_BENCH_LABELS=1 run_candidate "${ROOT}" "${INPUTS}" "${WORK}/ev-a" "${probe_a}" 2>&1 )"
rc_a=$?
if (( rc_a == 0 )); then
  bad "(a) a candidate was built with no --bench-labels"
else
  ok "(a) a candidate build with no --bench-labels is REFUSED (exit ${rc_a})"
fi
case "${out_a}" in
  *"refusing to build without --bench-labels"*)
    ok "(a) the refusal names the flag and explains why" ;;
  *) bad "(a) the refusal did not explain itself: ${out_a}" ;;
esac
if [[ -e "${probe_a}" ]]; then
  bad "(a) ./build was invoked despite the missing flag"
else
  ok "(a) the refusal happens BEFORE ./build is invoked"
fi

# ---------------------------------------------------------------------------
# (b) --bench-labels 1 -> CERALIVE_BENCH_LABELS=1 in ./build's own environment
# ---------------------------------------------------------------------------
probe_b="${WORK}/probe-b"
log_b="${WORK}/log-b"
run_candidate "${ROOT}" "${INPUTS}" "${WORK}/ev-b" "${probe_b}" --bench-labels 1 >"${log_b}" 2>&1
rc_b=$?
if (( rc_b == 0 )); then
  ok "(b) --bench-labels 1 completed the candidate"
else
  bad "(b) --bench-labels 1 failed (exit ${rc_b}):"$'\n'"$(cat "${log_b}")"
fi
assert_contains "(b) ./build received CERALIVE_BENCH_LABELS=1" "${probe_b}" 'CERALIVE_BENCH_LABELS=1'
assert_contains "(b) the active mode is logged for the build" "${log_b}" \
  'CERALIVE_BENCH_LABELS=1 (bench PARTLABEL overlay: ON'

# ---------------------------------------------------------------------------
# (c) --bench-labels 0 -> CERALIVE_BENCH_LABELS=0, never unset and never inherited
# ---------------------------------------------------------------------------
probe_c="${WORK}/probe-c"
log_c="${WORK}/log-c"
CERALIVE_BENCH_LABELS=1 \
  run_candidate "${ROOT}" "${INPUTS}" "${WORK}/ev-c" "${probe_c}" --bench-labels 0 >"${log_c}" 2>&1
rc_c=$?
if (( rc_c == 0 )); then
  ok "(c) --bench-labels 0 completed the candidate"
else
  bad "(c) --bench-labels 0 failed (exit ${rc_c}):"$'\n'"$(cat "${log_c}")"
fi
assert_contains "(c) ./build received CERALIVE_BENCH_LABELS=0" "${probe_c}" 'CERALIVE_BENCH_LABELS=0'
assert_contains "(c) the active mode is logged for the build" "${log_c}" \
  'CERALIVE_BENCH_LABELS=0 (bench PARTLABEL overlay: OFF'

# The flag WINS over a contradicting ambient value; without that, (c) would pass
# for the wrong reason on a shell that happens to export the same number.
if grep -qF 'CERALIVE_BENCH_LABELS=0' "${probe_c}"; then
  ok "(c) --bench-labels overrides a contradicting ambient CERALIVE_BENCH_LABELS=1"
else
  bad "(c) an ambient CERALIVE_BENCH_LABELS leaked into ./build"
fi

# ---------------------------------------------------------------------------
# (d) the tuple records the mode that built THAT artifact
# ---------------------------------------------------------------------------
tuple_b="${WORK}/ev-b/rock-edge.bench-labels-1.tuple.json"
tuple_c="${WORK}/ev-c/rock-edge.bench-labels-0.tuple.json"
for t in "${tuple_b}" "${tuple_c}"; do
  [[ -s "${t}" ]] || bad "(d) tuple not emitted: ${t}"
done
if [[ -s "${tuple_b}" && -s "${tuple_c}" ]]; then
  assert_eq "(d) bench build tuple records bench_labels"      "true"  "$(tuple_field "${tuple_b}" bench_labels)"
  assert_eq "(d) bench build tuple records partlabel_set"     '"bench-x-prefixed"' "$(tuple_field "${tuple_b}" partlabel_set)"
  assert_eq "(d) production build tuple records bench_labels" "false" "$(tuple_field "${tuple_c}" bench_labels)"
  assert_eq "(d) production build tuple records partlabel_set" '"production-frozen"' "$(tuple_field "${tuple_c}" partlabel_set)"
fi

# ---------------------------------------------------------------------------
# (e) NO COLLISION — the same candidate built in both modes into ONE evidence
#     directory keeps both artifacts' evidence. Named by candidate alone, the
#     second run silently overwrote the first, and an operator holding two
#     artifacts had one artifact's evidence.
# ---------------------------------------------------------------------------
shared_ev="${WORK}/ev-shared"
run_candidate "${ROOT}" "${INPUTS}" "${shared_ev}" "${WORK}/probe-e1" --bench-labels 1 >/dev/null 2>&1
run_candidate "${ROOT}" "${INPUTS}" "${shared_ev}" "${WORK}/probe-e0" --bench-labels 0 >/dev/null 2>&1
missing=""
for f in rock-edge.bench-labels-1.tuple.json rock-edge.bench-labels-0.tuple.json \
         rock-edge.bench-labels-1.log rock-edge.bench-labels-0.log \
         rock-edge.bench-labels-1.config rock-edge.bench-labels-0.config; do
  [[ -s "${shared_ev}/${f}" ]] || missing+=" ${f}"
done
if [[ -z "${missing}" ]]; then
  ok "(e) both label modes coexist in one evidence dir (log, config and tuple each per-mode)"
else
  bad "(e) evidence collided across label modes; missing:${missing}"
fi
if [[ -s "${shared_ev}/rock-edge.bench-labels-1.tuple.json" ]]; then
  assert_eq "(e) the bench-labels-1 tuple survived the later bench-labels-0 run" \
    "true" "$(tuple_field "${shared_ev}/rock-edge.bench-labels-1.tuple.json" bench_labels)"
fi

# ---------------------------------------------------------------------------
# (f) schema 4: first_party_local_overrides is always present, [] when unused
# ---------------------------------------------------------------------------
if [[ -s "${tuple_c}" ]]; then
  assert_eq "(f) tuple is schema_version 4" "4" "$(tuple_field "${tuple_c}" schema_version)"
  assert_eq "(f) unused override records an empty array" "[]" "$(tuple_field "${tuple_c}" first_party_local_overrides)"
  assert_eq "(f) edge candidate without --debug-image is not a debug image" "false" "$(tuple_field "${tuple_c}" debug_image)"
fi
if grep -qF 'CERALIVE_FIRST_PARTY_LOCAL_DEBS_DIR=<UNSET>' "${probe_c}"; then
  ok "(f) no override variable reaches ./build when the flag is absent"
else
  bad "(f) override variable leaked into ./build without the flag"
fi

mkdir -p "${INPUTS}/local-debs"
printf "CERALIVE_DEBUG_PASSWORD_HASH='\$6\$fake\$hash'\n" >"${INPUTS}/debug.env"
probe_g="${WORK}/probe-g"
run_candidate "${ROOT}" "${INPUTS}" "${WORK}/ev-g" "${probe_g}" --bench-labels 1 \
  --first-party-local-debs "${INPUTS}/local-debs" --debug-image --debug-env "${INPUTS}/debug.env" \
  >"${WORK}/log-g" 2>&1
rc_g=$?
if (( rc_g == 0 )); then
  ok "(g) development edge candidate accepts --first-party-local-debs and --debug-image"
else
  bad "(g) override/debug-image candidate failed (exit ${rc_g}):"$'\n'"$(cat "${WORK}/log-g")"
fi
assert_contains "(g) ./build received the local override dir" "${probe_g}" \
  "CERALIVE_FIRST_PARTY_LOCAL_DEBS_DIR=${INPUTS}/local-debs"
assert_contains "(g) --debug-image exports CERALIVE_DEBUG_IMAGE=1 on an edge candidate" "${probe_g}" \
  'CERALIVE_DEBUG_IMAGE=1'
tuple_g="${WORK}/ev-g/rock-edge.bench-labels-1.tuple.json"
if [[ -s "${tuple_g}" ]]; then
  assert_eq "(g) tuple debug_image reflects --debug-image" "true" "$(tuple_field "${tuple_g}" debug_image)"
  assert_eq "(g) --debug-image does not flip the kernel test-seam expectation" '"off"' \
    "$(tuple_field "${tuple_g}" ceralive_test_symbols)"
  if python3 - "${tuple_g}" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1]))["first_party_local_overrides"]
assert isinstance(rows, list) and len(rows) == 1
assert set(rows[0]) == {"package", "version", "arch", "sha256", "filename"}
assert rows[0]["package"] == "ceralive-device" and rows[0]["version"] == "99.2"
PY
  then ok "(g) tuple carries the build's override manifest"; else bad "(g) tuple override shape"; fi
else
  bad "(g) tuple not emitted: ${tuple_g}"
fi

if run_candidate "${ROOT}" "${INPUTS}" "${WORK}/ev-h" "${WORK}/probe-h" --bench-labels 1 \
     --debug-image >/dev/null 2>&1; then
  bad "(h) --debug-image without --debug-env was accepted"
else
  ok "(h) --debug-image requires --debug-env"
fi

sed 's/"build_mode":"development"/"build_mode":"production"/; s/"production_trust_anchor":false/"production_trust_anchor":true/' \
  "${INPUTS}/verdict.json" >"${INPUTS}/verdict-prod.json"
cp "${INPUTS}/verdict.json" "${INPUTS}/verdict-dev.json"
cp "${INPUTS}/verdict-prod.json" "${INPUTS}/verdict.json"
for extra in "--first-party-local-debs ${INPUTS}/local-debs" "--debug-image --debug-env ${INPUTS}/debug.env"; do
  probe_p="${WORK}/probe-prod-${extra%% *}"
  # shellcheck disable=SC2086
  out_p="$(run_candidate "${ROOT}" "${INPUTS}" "${WORK}/ev-p" "${probe_p}" --bench-labels 0 ${extra} 2>&1)"
  rc_p=$?
  if (( rc_p != 0 )) && [[ "${out_p}" == *"board '${BOARD}' has production build_mode"* ]] && [[ ! -e "${probe_p}" ]]; then
    ok "(i) production verdict refuses ${extra%% *} before ./build, naming the board"
  else
    bad "(i) production verdict did not refuse ${extra%% *} (exit ${rc_p}): ${out_p}"
  fi
done
cp "${INPUTS}/verdict-dev.json" "${INPUTS}/verdict.json"

# The non-default candidate builds with --variant edge-test; its recorder must
# resolve the same overlay. Keep BOTH kernel debs in this fixture so the old
# default-variant path can emit a plausible, but wrong, tuple instead of dying.
debug_root="${WORK}/debug-pipeline"
make_fake_pipeline "${debug_root}" real
debug_resolved="$("${PIPELINE_DIR}/lib/resolve.sh" "${BOARD}" --variant edge-test)"
default_resolved="$("${PIPELINE_DIR}/lib/resolve.sh" "${BOARD}")"
resolved_field() { sed -n "s/^${2}='\(.*\)'$/\1/p" <<<"$1"; }
debug_release="$(resolved_field "${debug_resolved}" KERNEL_SOURCE_KERNEL_RELEASE)"
default_release="$(resolved_field "${default_resolved}" KERNEL_SOURCE_KERNEL_RELEASE)"
if [[ -n "${debug_release}" && -n "${default_release}" && "${debug_release}" != "${default_release}" ]]; then
  ok "(j) real edge-test manifest differs from the default edge release"
else
  bad "(j) resolver did not distinguish edge-test from default edge"
fi
for release in "${debug_release}" "${default_release}"; do
  KERNEL_RELEASE="${release}" make_kernel_deb \
    "${debug_root}/mkosi/.staging/${BOARD}/kernel-build/linux-image-${release}_1_arm64.deb" debug
done
debug_log="${WORK}/debug-log"
debug_probe="${WORK}/debug-probe"
CERALIVE_KERNEL_VARIANT=edge \
  CERALIVE_BENCH_PROBE="${debug_probe}" "${debug_root}/ci/build-hardware-candidates.sh" \
    --only rock-edge-test --trust-verdict "${INPUTS}/verdict.json" \
    --signing-env "${INPUTS}/sign.env" --debug-env "${INPUTS}/debug.env" \
    --evidence "${WORK}/debug-evidence" --skip-probes --bench-labels 1 >"${debug_log}" 2>&1
debug_rc=$?
if (( debug_rc == 0 )); then
  ok "(j) non-default source-built candidate completed against the real resolver"
else
  bad "(j) edge-test candidate failed (exit ${debug_rc}):$(<"${debug_log}")"
fi
debug_tuple="${WORK}/debug-evidence/rock-edge-test.bench-labels-1.tuple.json"
if [[ -s "${debug_tuple}" ]]; then
  assert_eq "(j) tuple records the explicit non-default variant" '"edge-test"' "$(tuple_field "${debug_tuple}" variant)"
  for pair in 'kernel_release KERNEL_SOURCE_KERNEL_RELEASE' \
              'kernel_package KERNEL_PACKAGES' \
              'kernel_source_tag KERNEL_SOURCE_TAG' \
              'kernel_source_commit KERNEL_SOURCE_COMMIT' \
              'patches_commit KERNEL_SOURCE_PATCHES_COMMIT'; do
    read -r tuple_key resolved_key <<<"${pair}"
    assert_eq "(j) ${tuple_key} follows real edge-test resolution" \
      "\"$(resolved_field "${debug_resolved}" "${resolved_key}")\"" \
      "$(tuple_field "${debug_tuple}" "${tuple_key}")"
  done
  if [[ "$(tuple_field "${debug_tuple}" kernel_release)" != "\"${default_release}\"" ]]; then
    ok "(j) tuple did not silently use the default edge release"
  else
    bad "(j) tuple silently used the default edge release"
  fi
else
  bad "(j) edge-test tuple not emitted"
fi
if grep -qF 'command not found' "${debug_log}"; then
  bad "(j) recorder invoked an undefined command"
else
  ok "(j) recorder emitted no command-not-found diagnostic"
fi

# The shipped tool's own refusal legs.
if "${TOOL}" --self-test >"${WORK}/selftest.log" 2>&1; then
  ok "ci/build-hardware-candidates.sh --self-test passes"
else
  bad "ci/build-hardware-candidates.sh --self-test failed:"$'\n'"$(cat "${WORK}/selftest.log")"
fi

printf '\n== %d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
