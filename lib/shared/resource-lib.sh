#!/usr/bin/env bash
#
# resource-lib.sh — the ONE reader for "how much CPU and memory may this build
# actually use", cgroup v2 included.
#
# STANDALONE ON PURPOSE, exactly like log-lib.sh, args-lib.sh and
# target-release-lib.sh: it sets no shell options, installs no trap and sources
# nothing at file scope, so any of the three shell profiles in
# docs/shell-profiles.md can source it without inheriting strict mode or an ERR
# trap.
#
# WHY IT EXISTS. `nproc` and `MemAvailable` describe the MACHINE. Every build
# this pipeline runs in CI — and most of the ones run locally — executes inside a
# cgroup that constrains it to a fraction of that machine, and neither reader can
# see the constraint. `make -j$(nproc)` inside a 4-CPU container on a 32-core host
# spawns 32 compilers that timeshare 4 CPUs; worse, a memory-thin cgroup answers a
# generous `MemAvailable` (which reports the HOST's reclaimable memory) right up
# to the moment the cgroup limit is hit, at which point the kernel OOM-kills the
# compile rather than reclaiming. That is the same "dead build, half an hour in,
# after every pin has already verified" failure the memory ceiling in
# lib/kernel/builder.sh was written for, arriving through a door it cannot see.
#
# THE FOUR RULES THIS LIBRARY IMPLEMENTS, each of which is a way to get it wrong:
#
#   1. WALK EVERY ANCESTOR, LEAF TO ROOT. A cgroup v2 limit is inherited: the
#      effective limit on a process is the MINIMUM over its whole chain. A leaf
#      whose own `cpu.max` reads `max` is NOT unlimited if a parent slice caps it,
#      so reading the leaf alone reports the machine's cores and reintroduces the
#      defect under a name that claims to have fixed it.
#
#   2. CPU IS A MINIMUM OF QUOTAS. `cpu.max` is `<quota> <period>`, both in µs;
#      the ceiling in whole CPUs is ceil(quota/period), and the binding one is the
#      smallest across the chain.
#
#   3. MEMORY HEADROOM IS COMPUTED PER ANCESTOR, THEN MINIMISED — never by
#      picking the smallest absolute `memory.max` first. What a build can actually
#      allocate at level i is `memory.max_i - memory.current_i`, and a HIGHER-limit
#      parent that SIBLING processes have nearly exhausted has LESS room left than
#      a lower-limit leaf that is empty. Choosing the ancestor by its limit and
#      then subtracting is the subtly wrong version that still looks right in a
#      one-level test.
#
#   4. EVERY STEP SATURATES. `memory.current` can exceed `memory.max` transiently
#      (the limit is enforced by reclaim/OOM, not by rejecting the accounting), so
#      an unguarded subtraction underflows to a gigantic unsigned-looking value in
#      exactly the state where the answer must be "one job".
#
# FIXTURE OVERRIDES. Every read is redirectable, so the derivations are unit
# testable with no privilege, no container and no real cgroup:
#
#   CERALIVE_RESOURCE_MEMINFO_FILE     default /proc/meminfo
#   CERALIVE_RESOURCE_CGROUP_ROOT      default /sys/fs/cgroup
#   CERALIVE_RESOURCE_CGROUP_PROC_FILE default /proc/self/cgroup
#   CERALIVE_RESOURCE_MEM_SAFETY_MARGIN_KIB  default 256 MiB (see below)
#
# ABSENCE IS UNLIMITED, AND THAT IS THE FAIL-SAFE DIRECTION. A host with no
# cgroup v2 hierarchy, a v1-only host, and an unconstrained cgroup all resolve to
# "no limit found", so the answer collapses to exactly the pre-cgroup one:
# min(nproc, MemAvailable / per-job). An unconfigured host therefore sees no
# behaviour change at all.
#
# shellcheck shell=bash
# shellcheck disable=SC2034  # the RESOURCE_* globals ARE this library's published
# result channel (see below) and are read by its consumers, not by this file.

# The margin subtracted from a CGROUP-DERIVED memory headroom, and from that one
# only. `MemAvailable` is already a conservative kernel ESTIMATE of what can be
# handed out without swapping; `memory.max - memory.current` is a HARD WALL whose
# far side is an OOM kill, and the build is never the only thing in its cgroup —
# the shell, make, the container runtime's own bookkeeping and (in CI) the agent
# all live there too. Applying it to MemAvailable as well would change the answer
# on an unconstrained host, which this library must not do.
: "${CERALIVE_RESOURCE_MEM_SAFETY_MARGIN_KIB:=$((256 * 1024))}"

# THE RESULT CHANNEL IS THESE GLOBALS, NOT STDOUT, and that is forced rather than
# stylistic: a derivation has to report both the NUMBER and WHICH CONSTRAINT
# produced it (an unexplained `-j` is unactionable; "the parent slice capped it"
# is not), and `x="$(fn)"` runs fn in a SUBSHELL, so every explanatory variable it
# set would be discarded at the closing paren. Callers therefore invoke the
# derivations directly and read these.
RESOURCE_NPROC=""
RESOURCE_EFFECTIVE_CPUS=""
RESOURCE_CPU_BASIS=""
RESOURCE_MEM_BUDGET_KIB=""
RESOURCE_MEM_BASIS=""
RESOURCE_MEM_AVAILABLE_KIB=""
RESOURCE_CGROUP_CPU_LIMIT=""
RESOURCE_CGROUP_CPU_LIMIT_PATH=""
RESOURCE_CGROUP_MEM_HEADROOM_KIB=""
RESOURCE_CGROUP_MEM_HEADROOM_PATH=""

# ---------------------------------------------------------------------------
# resource_mem_available_kib — MemAvailable in kB, or non-zero and no output.
#
# Deliberately does NOT invent a figure when the file is unreadable: a fabricated
# number would silently reinstate the unbounded default under a name that claims
# to have prevented it. The caller says so instead.
# ---------------------------------------------------------------------------
resource_mem_available_kib() {
  local file="${CERALIVE_RESOURCE_MEMINFO_FILE:-/proc/meminfo}" value
  value="$(awk '$1 == "MemAvailable:" { print $2; found = 1 } END { if (!found) exit 1 }' \
    "${file}" 2>/dev/null)" || return 1
  [[ "${value}" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "${value}"
}

# ---------------------------------------------------------------------------
# resource_cgroup_root — the cgroup v2 mount point, trailing slash stripped.
# ---------------------------------------------------------------------------
resource_cgroup_root() {
  local root="${CERALIVE_RESOURCE_CGROUP_ROOT:-/sys/fs/cgroup}"
  root="${root%/}"
  printf '%s' "${root:-/}"
}

# ---------------------------------------------------------------------------
# resource_cgroup_self_rel — this process's UNIFIED cgroup path, or non-zero.
#
# /proc/self/cgroup's v2 line is `0::<path>`; a v1-only host has controllers in
# numbered lines and no unified one, and is correctly reported as "no v2
# hierarchy" rather than guessed at from a v1 controller path.
#
# Parsed with sed rather than `awk -F:` because a cgroup path may itself contain
# a colon (systemd scope names do), which would truncate `$3`. The `q` stops at
# the first match inside sed, so nothing is piped and nothing can SIGPIPE.
# ---------------------------------------------------------------------------
resource_cgroup_self_rel() {
  local file="${CERALIVE_RESOURCE_CGROUP_PROC_FILE:-/proc/self/cgroup}" rel
  [[ -r "${file}" ]] || return 1
  rel="$(sed -n '/^0::/{s/^0:://p;q;}' "${file}" 2>/dev/null)" || return 1
  [[ -n "${rel}" ]] || return 1
  printf '%s' "${rel}"
}

# ---------------------------------------------------------------------------
# resource_cgroup_chain — one absolute cgroup directory per line, LEAF first,
# mount root last. Non-zero and no output when there is no readable hierarchy.
#
# NAMESPACED MOUNTS. Inside a container /proc/self/cgroup still reports the
# HOST-relative path while the mount exposes the leaf AT the mount root, so
# `<root><rel>` does not exist. That means "the mount IS the leaf", not "there is
# no cgroup" — falling through to the root is what keeps the walk working in the
# containerized build, which is the case that matters most.
# ---------------------------------------------------------------------------
resource_cgroup_chain() {
  local root leaf rel dir parent
  root="$(resource_cgroup_root)"
  [[ -d "${root}" ]] || return 1
  rel="$(resource_cgroup_self_rel)" || rel=""
  [[ "${rel}" != "/" ]] || rel=""
  leaf="${root}${rel}"
  [[ -d "${leaf}" ]] || leaf="${root}"
  dir="${leaf}"
  while :; do
    printf '%s\n' "${dir}"
    [[ "${dir}" != "${root}" ]] || break
    parent="${dir%/*}"
    [[ -n "${parent}" && "${parent}" != "${dir}" ]] || break
    dir="${parent}"
    # Never climb above the mount root, whatever /proc/self/cgroup claimed.
    case "${dir}" in "${root}"*) ;; *) break ;; esac
  done
}

# ---------------------------------------------------------------------------
# resource_cgroup_cpu_limit — the MINIMUM whole-CPU ceiling across the chain.
#
# Sets RESOURCE_CGROUP_CPU_LIMIT{,_PATH}; returns non-zero with both cleared when
# no ancestor declares a finite cpu.max. `max` at one level is unlimited AT THAT
# LEVEL ONLY and must not end the walk (rule 1).
# ---------------------------------------------------------------------------
resource_cgroup_cpu_limit() {
  RESOURCE_CGROUP_CPU_LIMIT=""
  RESOURCE_CGROUP_CPU_LIMIT_PATH=""
  local dir quota period cpus
  while read -r dir; do
    [[ -r "${dir}/cpu.max" ]] || continue
    quota=""; period=""
    read -r quota period <"${dir}/cpu.max" || continue
    [[ "${quota}" =~ ^[0-9]+$ ]] || continue
    [[ "${period}" =~ ^[1-9][0-9]*$ ]] || continue
    cpus=$(( (quota + period - 1) / period ))
    (( cpus >= 1 )) || cpus=1
    if [[ -z "${RESOURCE_CGROUP_CPU_LIMIT}" ]] || (( cpus < RESOURCE_CGROUP_CPU_LIMIT )); then
      RESOURCE_CGROUP_CPU_LIMIT="${cpus}"
      RESOURCE_CGROUP_CPU_LIMIT_PATH="${dir}"
    fi
  done < <(resource_cgroup_chain)
  [[ -n "${RESOURCE_CGROUP_CPU_LIMIT}" ]] || return 1
}

# ---------------------------------------------------------------------------
# resource_cgroup_mem_headroom_kib — the MINIMUM remaining memory across the
# chain, in kB, computed PER ANCESTOR (rule 3) and saturating (rule 4).
#
# Sets RESOURCE_CGROUP_MEM_HEADROOM_KIB{,_PATH}; returns non-zero with both
# cleared when no ancestor declares a finite memory.max. No safety margin is
# applied here — that is the consumer's decision and is done in
# resource_mem_budget_kib, so this function stays a plain measurement.
# ---------------------------------------------------------------------------
resource_cgroup_mem_headroom_kib() {
  RESOURCE_CGROUP_MEM_HEADROOM_KIB=""
  RESOURCE_CGROUP_MEM_HEADROOM_PATH=""
  local dir max cur remaining kib
  while read -r dir; do
    [[ -r "${dir}/memory.max" ]] || continue
    max=""
    read -r max <"${dir}/memory.max" || continue
    [[ "${max}" =~ ^[0-9]+$ ]] || continue
    cur=0
    if [[ -r "${dir}/memory.current" ]]; then
      read -r cur <"${dir}/memory.current" || cur=0
      [[ "${cur}" =~ ^[0-9]+$ ]] || cur=0
    fi
    if (( max > cur )); then remaining=$(( max - cur )); else remaining=0; fi
    kib=$(( remaining / 1024 ))
    if [[ -z "${RESOURCE_CGROUP_MEM_HEADROOM_KIB}" ]] || (( kib < RESOURCE_CGROUP_MEM_HEADROOM_KIB )); then
      RESOURCE_CGROUP_MEM_HEADROOM_KIB="${kib}"
      RESOURCE_CGROUP_MEM_HEADROOM_PATH="${dir}"
    fi
  done < <(resource_cgroup_chain)
  [[ -n "${RESOURCE_CGROUP_MEM_HEADROOM_KIB}" ]] || return 1
}

# ---------------------------------------------------------------------------
# resource_effective_cpus — min(nproc, cgroup cpu ceiling), floor 1, published
# as RESOURCE_EFFECTIVE_CPUS with RESOURCE_CPU_BASIS naming what bound it.
#
# Always succeeds: a host with no cgroup limit and a host whose nproc is
# unreadable both have a defensible answer, and neither is a reason to fail a
# build.
# ---------------------------------------------------------------------------
resource_effective_cpus() {
  local cpus
  RESOURCE_EFFECTIVE_CPUS=""
  RESOURCE_CPU_BASIS=""
  cpus="$(nproc 2>/dev/null || echo 1)"
  [[ "${cpus}" =~ ^[1-9][0-9]*$ ]] || cpus=1
  RESOURCE_NPROC="${cpus}"
  if resource_cgroup_cpu_limit; then
    if (( RESOURCE_CGROUP_CPU_LIMIT < cpus )); then
      cpus="${RESOURCE_CGROUP_CPU_LIMIT}"
      RESOURCE_CPU_BASIS="cgroup cpu.max ceiling ${cpus} at ${RESOURCE_CGROUP_CPU_LIMIT_PATH}"
    else
      RESOURCE_CPU_BASIS="nproc (cgroup cpu.max allows ${RESOURCE_CGROUP_CPU_LIMIT})"
    fi
  else
    RESOURCE_CPU_BASIS="nproc (no cgroup v2 cpu.max limit)"
  fi
  RESOURCE_EFFECTIVE_CPUS="${cpus}"
}

# ---------------------------------------------------------------------------
# resource_mem_budget_kib — the memory a build may plan against, in kB, published
# as RESOURCE_MEM_BUDGET_KIB with RESOURCE_MEM_BASIS naming what bound it.
#
# min(MemAvailable, cgroup headroom − safety margin), each half optional. Returns
# non-zero only when NEITHER is readable, which is the one state where a caller
# must say "no memory ceiling applied" out loud instead of inventing one.
# ---------------------------------------------------------------------------
resource_mem_budget_kib() {
  local avail head margin
  RESOURCE_MEM_BUDGET_KIB=""
  RESOURCE_MEM_BASIS=""
  RESOURCE_MEM_AVAILABLE_KIB=""
  avail="$(resource_mem_available_kib)" || avail=""
  RESOURCE_MEM_AVAILABLE_KIB="${avail}"

  margin="${CERALIVE_RESOURCE_MEM_SAFETY_MARGIN_KIB}"
  [[ "${margin}" =~ ^[0-9]+$ ]] || margin=$((256 * 1024))

  head=""
  if resource_cgroup_mem_headroom_kib; then
    head="${RESOURCE_CGROUP_MEM_HEADROOM_KIB}"
    # Saturating, because a margin larger than the remaining headroom means
    # "no room", never a negative budget.
    if (( head > margin )); then head=$(( head - margin )); else head=0; fi
  fi

  if [[ -n "${avail}" && -n "${head}" ]]; then
    if (( head < avail )); then
      RESOURCE_MEM_BUDGET_KIB="${head}"
      RESOURCE_MEM_BASIS="cgroup memory.max headroom at ${RESOURCE_CGROUP_MEM_HEADROOM_PATH} (${RESOURCE_CGROUP_MEM_HEADROOM_KIB} kB less ${margin} kB margin)"
    else
      RESOURCE_MEM_BUDGET_KIB="${avail}"
      RESOURCE_MEM_BASIS="MemAvailable (cgroup headroom at ${RESOURCE_CGROUP_MEM_HEADROOM_PATH} allows ${head} kB)"
    fi
  elif [[ -n "${avail}" ]]; then
    RESOURCE_MEM_BUDGET_KIB="${avail}"
    RESOURCE_MEM_BASIS="MemAvailable (no cgroup v2 memory.max limit)"
  elif [[ -n "${head}" ]]; then
    RESOURCE_MEM_BUDGET_KIB="${head}"
    RESOURCE_MEM_BASIS="cgroup memory.max headroom at ${RESOURCE_CGROUP_MEM_HEADROOM_PATH} (${RESOURCE_CGROUP_MEM_HEADROOM_KIB} kB less ${margin} kB margin) — MemAvailable unreadable"
  else
    return 1
  fi
}

# ---------------------------------------------------------------------------
# resource_jobs_for_mem <budget_kib> <per_job_kib> — whole jobs the budget buys.
#
# Deliberately NOT floored at 1: the caller logs this raw quotient so a `0` reads
# as "memory bought no parallelism" rather than being hidden behind the floor it
# then applies to the final answer.
# ---------------------------------------------------------------------------
resource_jobs_for_mem() {
  local budget="$1" per_job="$2"
  [[ "${budget}" =~ ^[0-9]+$ ]] || { printf '0'; return 0; }
  [[ "${per_job}" =~ ^[1-9][0-9]*$ ]] || { printf '0'; return 0; }
  printf '%s' $(( budget / per_job ))
}
