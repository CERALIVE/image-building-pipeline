#!/usr/bin/env bash
#
# build-parallelism.test.sh — the cgroup-aware job derivations, driven against
# fixture cgroup hierarchies and fixture meminfo files.
#
# WHY THIS FILE EXISTS. `nproc` and `MemAvailable` describe the MACHINE, not the
# cgroup the build actually runs in, so every parallelism knob in this pipeline
# used to plan against resources it could not have. lib/shared/resource-lib.sh
# walks the cgroup v2 chain instead, and the three consumers — the kernel `make
# -j` width, the multi-board runner's cap and the fetch concurrency — read it.
#
# THE THREE FIXTURES THAT MATTER, each of which is a way to get the walk wrong:
#
#   leaf-max-but-parent-limited   A leaf whose own cpu.max/memory.max reads `max`
#                                 is NOT unlimited when an ancestor caps it. An
#                                 implementation that reads the leaf and stops
#                                 reports the whole machine and passes every
#                                 single-level test.
#
#   nearly-exhausted memory       memory.max minus memory.current at ~0 must give
#                                 ONE job. This is also where an unsaturated
#                                 subtraction underflows into a gigantic value,
#                                 in precisely the state that must answer "1".
#
#   sibling-exhausted parent      The parent's LIMIT is larger than the leaf's,
#                                 but sibling processes have consumed it, so the
#                                 parent has LESS ROOM LEFT. Headroom must be
#                                 computed PER ANCESTOR and then minimised —
#                                 picking the smallest absolute limit first and
#                                 subtracting there is the subtly wrong version,
#                                 and this fixture is what separates them.
#
# Hardware-free, container-free and root-free: nproc is a stub on PATH, and every
# cgroup / meminfo read is redirected at a fixture tree.
#
# PROFILE: contract-test (docs/shell-profiles.md) — `set -uo pipefail` with no
# `-e`, so one failed assertion reports the rest instead of hiding them.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"
RESOURCE_LIB="${PIPELINE_DIR}/lib/shared/resource-lib.sh"

# shellcheck source=tests/lib/assertions.sh
source "${HERE}/lib/assertions.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

BIN="${WORK}/bin"
mkdir -p "${BIN}"

MIB=$((1024 * 1024))

stub_nproc() {
  printf '#!/bin/sh\necho %s\n' "$1" >"${BIN}/nproc"
  chmod +x "${BIN}/nproc"
}

# meminfo_mib <mib> — echo the path of a fixture meminfo advertising that much
# MemAvailable. `${WORK}/absent` is the deliberate unreadable case.
meminfo_mib() {
  local mib="$1"
  local path="${WORK}/meminfo-${mib}"
  printf 'MemTotal:       %s kB\nMemAvailable:   %s kB\nSwapFree:       0 kB\n' \
    $((mib * 1024)) $((mib * 1024)) >"${path}"
  printf '%s' "${path}"
}

# new_cgroup <name> <rel> — materialize a fixture hierarchy and its matching
# /proc/self/cgroup line; echo the mount root.
new_cgroup() {
  local name="$1" rel="$2"
  local root="${WORK}/cg-${name}"
  mkdir -p "${root}${rel}"
  printf '0::%s\n' "${rel:-/}" >"${root}.proc"
  printf '%s' "${root}"
}

cg_cpu() { printf '%s\n' "$2" >"$1/cpu.max"; }
cg_mem() { printf '%s\n' "$2" >"$1/memory.max"; printf '%s\n' "$3" >"$1/memory.current"; }

# --- output plumbing --------------------------------------------------------
# The derivations log to stderr and print the number to stdout with no trailing
# newline, so the merged stream is "<log lines>\n<number>". assert_contains takes
# a FILE (its needles are literal), so the captured stream is materialized.
OUT=""
RC=0
VALUE=""

capture() {
  OUT="$("$@")"
  RC=$?
  VALUE="${OUT##*$'\n'}"
  printf '%s\n' "${OUT}" >"${WORK}/out"
}

assert_out_has() { assert_contains "$1" "${WORK}/out" "$2"; }
assert_out_lacks() {
  if grep -qF -- "$2" "${WORK}/out"; then bad "$1: '$2' IS in the output"; else ok "$1"; fi
}

# --- runners ----------------------------------------------------------------
# Each sources the REAL shipped entry point, so the arithmetic under test is the
# shipped arithmetic and not a transcription of it.

run_in_env() {
  local cores="$1" meminfo="$2" cgroot="$3" script="$4"
  shift 4
  stub_nproc "${cores}"
  env -u CERALIVE_KERNEL_BUILD_JOBS -u CERALIVE_KERNEL_BUILD_JOBS_FORCE \
    -u JOBS -u CERALIVE_BUILD_BOARD_JOBS -u FETCH_JOBS \
    PATH="${BIN}:${PATH}" \
    CERALIVE_RESOURCE_MEMINFO_FILE="${meminfo}" \
    CERALIVE_RESOURCE_CGROUP_ROOT="${cgroot}" \
    CERALIVE_RESOURCE_CGROUP_PROC_FILE="${cgroot}.proc" \
    "$@" \
    bash -c "${script}" 2>&1
}

derive_jobs() {
  run_in_env "$1" "$2" "$3" \
    "source '${PIPELINE_DIR}/lib/build-kernel.sh'; derive_kernel_build_jobs" \
    "${@:4}"
}

board_jobs() {
  run_in_env "$1" "$2" "$3" \
    "source '${PIPELINE_DIR}/lib/build-all.sh'; printf '%s' \"\${JOBS}\"" \
    "${@:4}"
}

fetch_jobs() {
  run_in_env "$1" "$2" "$3" \
    "source '${PIPELINE_DIR}/lib/fetch-debs.sh' >/dev/null 2>&1 || true; printf '%s' \"\${FETCH_JOBS:-}\"" \
    "${@:4}"
}

lib_call() {
  run_in_env "$1" "$2" "$3" \
    "source '${RESOURCE_LIB}'; ${4}" \
    "${@:5}"
}

printf 'build parallelism (cgroup-aware job derivation)\n'

# ===========================================================================
# 1. The chain walk itself.
# ===========================================================================
printf '\n-- cgroup chain walk --\n'

CG_EMPTY="$(new_cgroup empty '')"
CG_NESTED="$(new_cgroup nested /a/b)"

capture lib_call 8 "$(meminfo_mib 65536)" "${CG_NESTED}" 'resource_cgroup_chain'
assert_eq 'chain lists leaf first' "${CG_NESTED}/a/b" "$(printf '%s\n' "${OUT}" | sed -n 1p)"
assert_eq 'chain lists the intermediate ancestor' "${CG_NESTED}/a" "$(printf '%s\n' "${OUT}" | sed -n 2p)"
assert_eq 'chain ends at the mount root' "${CG_NESTED}" "$(printf '%s\n' "${OUT}" | sed -n 3p)"
assert_eq 'chain stops at the mount root' 3 "$(printf '%s\n' "${OUT}" | grep -c .)"

# A namespaced container mount exposes the leaf AT the mount root while
# /proc/self/cgroup still reports the host-relative path. That must degrade to
# "the mount is the leaf", not to "there is no cgroup" — this is the shape the
# containerized build actually runs in.
CG_NS="$(new_cgroup namespaced '')"
printf '0::/docker/9f3c\n' >"${CG_NS}.proc"
cg_cpu "${CG_NS}" '100000 100000'
capture lib_call 8 "$(meminfo_mib 65536)" "${CG_NS}" \
  'resource_effective_cpus; printf "%s" "${RESOURCE_EFFECTIVE_CPUS}"'
assert_eq 'a namespaced mount still finds its own limits' 1 "${VALUE}"

# A v1-only host has no `0::` line at all and must read as "no v2 hierarchy"
# rather than being guessed at from a v1 controller path.
CG_V1="$(new_cgroup v1only '')"
printf '4:memory:/user.slice\n1:cpu:/user.slice\n' >"${CG_V1}.proc"
capture lib_call 8 "$(meminfo_mib 65536)" "${CG_V1}" \
  'resource_effective_cpus; printf "%s" "${RESOURCE_EFFECTIVE_CPUS}"'
assert_eq 'a v1-only /proc/self/cgroup falls back to the mount root' 8 "${VALUE}"

# ===========================================================================
# 2. derive_kernel_build_jobs — an UNCONSTRAINED host is byte-for-byte the
#    pre-cgroup answer. This is the MUST-NOT of the whole change.
# ===========================================================================
printf '\n-- unconstrained host (no behaviour change) --\n'

capture derive_jobs 8 "$(meminfo_mib 65536)" "${CG_EMPTY}"
assert_eq 'unlimited host: 8 cores and 64 GiB uses all 8 cores' 8 "${VALUE}"
assert_out_has 'unlimited host: names nproc as the CPU basis' 'no cgroup v2 cpu.max limit'
assert_out_has 'unlimited host: names MemAvailable as the memory basis' 'no cgroup v2 memory.max limit'

capture derive_jobs 8 "$(meminfo_mib 6144)" "${CG_EMPTY}"
assert_eq 'unlimited host: 6 GiB caps 8 cores at 3 jobs' 3 "${VALUE}"

capture derive_jobs 2 "$(meminfo_mib 65536)" "${CG_EMPTY}"
assert_eq 'unlimited host: spare memory buys no extra cores' 2 "${VALUE}"

capture derive_jobs 8 "${WORK}/absent" "${CG_EMPTY}"
assert_eq 'unlimited host: an unreadable meminfo falls back to nproc' 8 "${VALUE}"
assert_out_has 'unlimited host: and SAYS there is no memory ceiling' 'NO memory ceiling'

# ===========================================================================
# 3. FIXTURE A — leaf-max-but-parent-limited.
# ===========================================================================
printf '\n-- fixture: leaf reads max, an ANCESTOR is the real limit --\n'

CG_PCPU="$(new_cgroup parentcpu /slice/job)"
cg_cpu "${CG_PCPU}/slice" '200000 100000'
cg_cpu "${CG_PCPU}/slice/job" 'max'

capture derive_jobs 8 "$(meminfo_mib 65536)" "${CG_PCPU}"
assert_eq 'parent cpu.max binds even though the leaf reads max' 2 "${VALUE}"
assert_out_has 'the log names the ancestor that bound it' "cgroup cpu.max ceiling 2 at ${CG_PCPU}/slice"

# ceil(), not floor(): 2.5 CPUs of quota is 3 whole CPUs of width, and truncating
# would silently under-build every fractional-quota cgroup.
CG_CEIL="$(new_cgroup ceilcpu /slice)"
cg_cpu "${CG_CEIL}/slice" '250000 100000'
capture derive_jobs 8 "$(meminfo_mib 65536)" "${CG_CEIL}"
assert_eq 'a fractional cpu quota rounds UP to whole CPUs' 3 "${VALUE}"

CG_PMEM="$(new_cgroup parentmem /slice/job)"
cg_mem "${CG_PMEM}/slice" $((8 * 1024 * MIB)) 0
printf 'max\n' >"${CG_PMEM}/slice/job/memory.max"

capture derive_jobs 8 "$(meminfo_mib 65536)" "${CG_PMEM}"
assert_eq 'parent memory.max binds even though the leaf reads max' 3 "${VALUE}"
assert_out_has 'the log names the ancestor that bound the memory' "${CG_PMEM}/slice"

# ===========================================================================
# 4. FIXTURE B — nearly-exhausted memory.
# ===========================================================================
printf '\n-- fixture: memory.max minus memory.current is ~0 --\n'

CG_TIGHT="$(new_cgroup tight /slice)"
cg_mem "${CG_TIGHT}/slice" $((8 * 1024 * MIB)) $((8 * 1024 * MIB - MIB))

capture derive_jobs 8 "$(meminfo_mib 65536)" "${CG_TIGHT}"
assert_eq 'a nearly-exhausted cgroup builds SERIALLY' 1 "${VALUE}"
assert_out_lacks 'and never plans -j0' '-j0'

# memory.current may legitimately exceed memory.max (the limit is enforced by
# reclaim/OOM, not by refusing the accounting). Unsaturated, that subtraction
# underflows to a gigantic value in exactly the state that must answer "1".
CG_OVER="$(new_cgroup overcommitted /slice)"
cg_mem "${CG_OVER}/slice" $((8 * 1024 * MIB)) $((8 * 1024 * MIB + 4096))

capture derive_jobs 8 "$(meminfo_mib 65536)" "${CG_OVER}"
assert_eq 'memory.current ABOVE memory.max saturates to one job' 1 "${VALUE}"

# ===========================================================================
# 5. FIXTURE C — a lower leaf limit, but a sibling-exhausted parent.
#
# leaf:   16 GiB limit, 0 used   -> 16 GiB of room
# parent: 64 GiB limit, 58 used  ->  6 GiB of room
#
# The parent's LIMIT is four times the leaf's, so an implementation that selects
# the ancestor by smallest limit picks the leaf and answers 7. The parent has the
# least ROOM, so the correct answer is 2.
# ===========================================================================
printf '\n-- fixture: lower leaf limit, sibling-exhausted parent --\n'

CG_SIB="$(new_cgroup sibling /slice/job)"
cg_mem "${CG_SIB}/slice" $((64 * 1024 * MIB)) $((58 * 1024 * MIB))
cg_mem "${CG_SIB}/slice/job" $((16 * 1024 * MIB)) 0

capture derive_jobs 8 "$(meminfo_mib 65536)" "${CG_SIB}"
assert_eq "the PARENT's remaining headroom wins over the leaf's lower limit" 2 "${VALUE}"
assert_out_has 'the log names the parent as the binding ancestor' "${CG_SIB}/slice"
assert_out_lacks 'the leaf is NOT named as the binding ancestor' "${CG_SIB}/slice/job (16"

capture lib_call 8 "$(meminfo_mib 65536)" "${CG_SIB}" \
  'resource_cgroup_mem_headroom_kib; printf "%s" "${RESOURCE_CGROUP_MEM_HEADROOM_PATH}"'
assert_eq 'headroom is minimised PER ANCESTOR, not by smallest limit' "${CG_SIB}/slice" "${VALUE}"

# ===========================================================================
# 6. CERALIVE_KERNEL_BUILD_JOBS — kept, clamped, and forceable.
# ===========================================================================
printf '\n-- kernel build-jobs override --\n'

capture derive_jobs 8 "$(meminfo_mib 65536)" "${CG_SIB}" CERALIVE_KERNEL_BUILD_JOBS=16
assert_eq 'an override above the memory ceiling is CLAMPED to it' 2 "${VALUE}"
assert_out_has 'and the clamp says how to override it' 'CERALIVE_KERNEL_BUILD_JOBS_FORCE=1'

capture derive_jobs 8 "$(meminfo_mib 65536)" "${CG_SIB}" \
  CERALIVE_KERNEL_BUILD_JOBS=16 CERALIVE_KERNEL_BUILD_JOBS_FORCE=1
assert_eq 'FORCE=1 restores the unconditional upward override' 16 "${VALUE}"
assert_out_has 'and says the ceiling was not applied' 'memory ceiling NOT applied'

capture derive_jobs 8 "$(meminfo_mib 65536)" "${CG_SIB}" CERALIVE_KERNEL_BUILD_JOBS=2
assert_eq 'an override within the ceiling is honoured unchanged' 2 "${VALUE}"
assert_out_has 'and is reported as an override' 'CERALIVE_KERNEL_BUILD_JOBS override'

capture derive_jobs 8 "${WORK}/absent" "${CG_EMPTY}" CERALIVE_KERNEL_BUILD_JOBS=16
assert_eq 'with no readable memory figure there is no ceiling to clamp to' 16 "${VALUE}"
assert_out_has 'and that is stated rather than assumed' 'NO memory ceiling'

capture derive_jobs 8 "$(meminfo_mib 65536)" "${CG_EMPTY}" CERALIVE_KERNEL_BUILD_JOBS=all
assert_eq 'a non-numeric override is refused' 1 "$([[ ${RC} -ne 0 ]] && echo 1 || echo 0)"
assert_out_has 'and the refusal names the variable' 'CERALIVE_KERNEL_BUILD_JOBS'

# `FORCE=true` reading as "off" would leave an operator believing the clamp is
# disabled while it is armed, so the value is refused rather than interpreted.
capture derive_jobs 8 "$(meminfo_mib 65536)" "${CG_SIB}" \
  CERALIVE_KERNEL_BUILD_JOBS=16 CERALIVE_KERNEL_BUILD_JOBS_FORCE=true
assert_eq 'a non-0/1 FORCE value is refused, never guessed at' 1 "$([[ ${RC} -ne 0 ]] && echo 1 || echo 0)"
assert_out_has 'and the refusal names the FORCE variable' 'CERALIVE_KERNEL_BUILD_JOBS_FORCE'

# ===========================================================================
# 7. lib/build-all.sh — the default must not move.
# ===========================================================================
printf '\n-- multi-board runner cap --\n'

capture board_jobs 8 "$(meminfo_mib 65536)" "${CG_EMPTY}"
assert_eq 'unconfigured: the cap is still min(nproc,4)' 4 "${VALUE}"

capture board_jobs 2 "$(meminfo_mib 65536)" "${CG_EMPTY}"
assert_eq 'unconfigured: a 2-core host still gets 2' 2 "${VALUE}"

# The default is deliberately NOT cgroup-adaptive: the cap of 4 already bounds it,
# and a zero-configuration `build --all` must produce the same number it always
# did. Adaptivity lives behind the explicit knob below.
capture board_jobs 8 "$(meminfo_mib 65536)" "${CG_SIB}"
assert_eq 'unconfigured: a constrained cgroup does NOT move the default' 4 "${VALUE}"

capture board_jobs 8 "$(meminfo_mib 65536)" "${CG_EMPTY}" JOBS=7
assert_eq 'the pre-existing JOBS override still wins' 7 "${VALUE}"

capture board_jobs 8 "$(meminfo_mib 65536)" "${CG_EMPTY}" JOBS=7 CERALIVE_BUILD_BOARD_JOBS=1
assert_eq 'JOBS keeps precedence over the new knob' 7 "${VALUE}"

capture board_jobs 8 "$(meminfo_mib 65536)" "${CG_EMPTY}" JOBS=nonsense
assert_eq 'a bogus JOBS still falls back to the cap, as before' 4 "${VALUE}"

capture board_jobs 8 "$(meminfo_mib 65536)" "${CG_EMPTY}" CERALIVE_BUILD_BOARD_JOBS=8
assert_eq 'the raise knob lifts the cap when memory allows' 8 "${VALUE}"

capture board_jobs 8 "$(meminfo_mib 65536)" "${CG_SIB}" CERALIVE_BUILD_BOARD_JOBS=8
assert_eq 'the raise knob is clamped by the cgroup memory headroom' 1 "${VALUE}"
assert_out_has 'and the clamp is reported' 'CLAMPED'

capture board_jobs 8 "$(meminfo_mib 65536)" "${CG_EMPTY}" CERALIVE_BUILD_BOARD_JOBS=nope
assert_eq 'a bogus raise knob is FATAL, never silently defaulted' 1 "$([[ ${RC} -ne 0 ]] && echo 1 || echo 0)"
assert_out_has 'and the refusal names the variable' 'CERALIVE_BUILD_BOARD_JOBS'

# ===========================================================================
# 8. lib/fetch-debs.sh — FETCH_JOBS default min(cpus, 8).
# ===========================================================================
printf '\n-- fetch concurrency --\n'

capture fetch_jobs 16 "$(meminfo_mib 65536)" "${CG_EMPTY}"
assert_eq 'FETCH_JOBS is capped at 8 on a many-core host' 8 "${VALUE}"

capture fetch_jobs 2 "$(meminfo_mib 65536)" "${CG_EMPTY}"
assert_eq 'FETCH_JOBS follows a small core count' 2 "${VALUE}"

capture fetch_jobs 16 "$(meminfo_mib 65536)" "${CG_PCPU}"
assert_eq 'FETCH_JOBS respects a cgroup cpu quota set by an ANCESTOR' 2 "${VALUE}"

capture fetch_jobs 16 "$(meminfo_mib 65536)" "${CG_EMPTY}" FETCH_JOBS=1
assert_eq 'the FETCH_JOBS=1 serial baseline still works' 1 "${VALUE}"

capture fetch_jobs 16 "$(meminfo_mib 65536)" "${CG_EMPTY}" FETCH_JOBS=bogus
assert_eq 'a bogus FETCH_JOBS falls back to the derived default' 8 "${VALUE}"

printf '\nbuild-parallelism: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
