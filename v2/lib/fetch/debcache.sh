#!/usr/bin/env bash
#
# fetch/debcache.sh — the persistent, content-addressed .deb download cache.
#
# All three verified fetch families (BSP, RK3588 userspace, first-party) already
# arrive at a point where they hold BOTH the exact bytes they want AND that
# artifact's expected SHA-256 from signed metadata or a committed pin file. That
# is the only precondition a cache needs to be safe: a reused entry is checked
# against the SAME expected hash the network path would have checked, so reuse
# can never weaken verification. A cache MISS and a cache HIT are indistinguishable
# to every caller except in how long they take.
#
# WHAT IS CACHED: final, already-verified `.deb` payloads only. Apt indexes,
# InRelease/Release, Packages.gz and the GPG keyring are DELIBERATELY never
# cached — those are the rotating trust material whose whole job is to be fresh,
# and a stale index is how a cache turns into a downgrade attack surface.
#
# WHY NOT THE PER-BOARD BUILD LOCK: orchestrate.sh's flock (acquire_board_lock)
# is keyed on ONE board, and different boards are explicitly allowed to build in
# parallel. This cache is shared across every board, so two concurrent builds are
# two concurrent writers of the same entry. Concurrency here is therefore its own
# PER-CACHE-KEY flock, taken under ${DEBCACHE_DIR}/.locks/, mirroring the idiom in
# v2/mkosi/.staging/.locks/ rather than reusing that lock.
#
# LOCK DISCIPLINE, and the one race this file exists to close:
#   * A READER holds the key lock across the WHOLE hit sequence — existence check,
#     SHA re-verification, copy-out. Releasing after verification and copying
#     afterwards would let eviction unlink the entry in between, so the reader
#     would then copy a file it had verified and no longer has.
#   * EVICTION takes each victim's own key lock, with `flock -n`, BEFORE unlinking,
#     and SKIPS a victim whose lock is held. Skipping (rather than waiting) is what
#     keeps the ordering trivial: no code path ever holds two key locks at once, so
#     reader-vs-eviction cannot deadlock in either direction, and an entry a reader
#     is mid-way through is simply left for the next cleanup pass.
#
# EVERY failure here is NON-FATAL. The cache is an optimisation, so an unwritable
# directory, a lost lock race or a failed copy degrades to "fetch it from the
# network" — the exact behaviour of CERALIVE_DEBCACHE=0.
#
# Sourced by lib/fetch-debs.sh; not standalone. Reads the entry point's ${HERE}
# (= v2/lib) for the repo-local default cache path, and DRY_RUN from fetch/retry.sh.
#
# shellcheck shell=bash

# ---------------------------------------------------------------------------
# Configuration. CERALIVE_DEBCACHE=0 disables the cache completely: no lookup,
# no store, no eviction, and no directory is created — fetch semantics are then
# byte-identical to the pre-cache path.
#
# The cache lives INSIDE the already-ignored staging tree
# (v2/mkosi/.staging/.debcache) as a SIBLING of the per-board staging dirs, so
# the per-board `rm -rf` an orchestrator run performs never touches it, and the
# repo's existing `/.staging/` ignore rule already covers it. It is repo-local by
# construction (Rule D): nothing here resolves a path above the checkout root.
# ---------------------------------------------------------------------------
CERALIVE_DEBCACHE="${CERALIVE_DEBCACHE:-1}"
DEBCACHE_DIR="${CERALIVE_DEBCACHE_DIR:-${HERE}/../mkosi/.staging/.debcache}"

# 4 GiB. Large enough to hold a couple of full board plans (the RK3588 kernel +
# firmware set alone is several hundred MB) without becoming an unbounded disk
# consumer on a long-lived CI runner.
CERALIVE_DEBCACHE_MAX_BYTES="${CERALIVE_DEBCACHE_MAX_BYTES:-4294967296}"
[[ "${CERALIVE_DEBCACHE_MAX_BYTES}" =~ ^[0-9]+$ ]] || CERALIVE_DEBCACHE_MAX_BYTES=4294967296

# Bounded, never infinite: a wedged holder degrades this to a cache miss rather
# than hanging a build.
CERALIVE_DEBCACHE_LOCK_TIMEOUT="${CERALIVE_DEBCACHE_LOCK_TIMEOUT:-120}"
[[ "${CERALIVE_DEBCACHE_LOCK_TIMEOUT}" =~ ^[0-9]+$ ]] || CERALIVE_DEBCACHE_LOCK_TIMEOUT=120

# Set to 1 by debcache_init once the tree exists; -1 once it has been proven
# unusable, so a broken cache is diagnosed once rather than per package.
_DEBCACHE_READY=0

# debcache_enabled — the single gate every entry point consults. DRY_RUN is
# excluded here rather than at each call site: a plan-only run stages no .deb, so
# there is nothing to cache and nothing to reuse, and this keeps the resolved
# DRY_RUN plan byte-identical to the pre-cache one.
debcache_enabled() {
  [[ "${CERALIVE_DEBCACHE}" != "0" ]] || return 1
  [[ -z "${DRY_RUN}" ]] || return 1
  (( _DEBCACHE_READY >= 0 )) || return 1
  command -v flock >/dev/null 2>&1 || return 1
  command -v sha256sum >/dev/null 2>&1 || return 1
}

# debcache_init — idempotently materialise the cache tree. Returns non-zero (and
# latches the cache off for the rest of the run) when the tree cannot be created.
debcache_init() {
  if (( _DEBCACHE_READY == 1 )); then
    return 0
  fi
  if (( _DEBCACHE_READY < 0 )); then
    return 1
  fi
  if ! mkdir -p "${DEBCACHE_DIR}/.locks" 2>/dev/null; then
    _DEBCACHE_READY=-1
    log_warn ".deb cache: cannot create ${DEBCACHE_DIR} — continuing with downloads only"
    return 1
  fi
  _DEBCACHE_READY=1
  log_info ".deb cache: ${DEBCACHE_DIR} (max $(( CERALIVE_DEBCACHE_MAX_BYTES / 1048576 )) MiB, CERALIVE_DEBCACHE=0 disables)"
  return 0
}

# debcache_key_is_valid <key> — a cache key is the Debian pool filename, which is
# `<package>_<version>_<arch>.deb` by Debian policy for every archive this
# pipeline reads (the Armbian pool, apt.ceralive.tv, and the committed
# rk3588-userspace pin file all spell it exactly that way).
#
# Using the archive's own filename verbatim — rather than re-deriving it from the
# .deb control fields — is deliberate: the STORE side and the HIT side must agree
# on the key or the cache silently never hits, and an epoch version is `1:2.3` in
# the control file but `1%3a2.3` in the filename. One source, no re-derivation, no
# drift. Anything that is not a plain, traversal-free `.deb` basename is refused,
# which turns an unexpected name into a cache bypass rather than a path escape.
debcache_key_is_valid() {
  local key="$1"
  [[ -n "${key}" ]] || return 1
  [[ "${key}" != *"/"* ]] || return 1
  [[ "${key}" =~ ^[A-Za-z0-9][A-Za-z0-9._+~%:-]*\.deb$ ]] || return 1
}

debcache_entry_path() { printf '%s/%s' "${DEBCACHE_DIR}" "$1"; }
debcache_lock_path()  { printf '%s/.locks/%s.lock' "${DEBCACHE_DIR}" "$1"; }

# ---------------------------------------------------------------------------
# debcache_try_hit <key> <expected_sha256> <destination>
#
# Returns 0 ONLY when <destination> now holds a mode-0644 .deb whose SHA-256 was
# re-verified against <expected_sha256> while the key lock was held. Any other
# outcome returns non-zero and the caller downloads exactly as before.
#
# A stored entry whose hash no longer matches is DELETED, not merely skipped: it
# is either corrupt on disk or the archive replaced the bytes under the same
# filename, and in both cases keeping it would re-fail every future build.
#
# The copy-out happens INSIDE the lock, on purpose — see the lock discipline note
# at the top of this file.
# ---------------------------------------------------------------------------
debcache_try_hit() {
  local key="$1" expected="$2" dest="$3"
  debcache_enabled || return 1
  debcache_key_is_valid "${key}" || return 1
  [[ "${expected}" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ -n "${dest}" ]] || return 1
  debcache_init || return 1

  local entry lock rc=0
  entry="$(debcache_entry_path "${key}")"
  lock="$(debcache_lock_path "${key}")"

  (
    flock -w "${CERALIVE_DEBCACHE_LOCK_TIMEOUT}" 9 || exit 4
    [[ -f "${entry}" ]] || exit 1
    actual="$(sha256sum "${entry}" | awk '{print $1}')"
    if [[ "${actual}" != "${expected}" ]]; then
      rm -f -- "${entry}"
      exit 2
    fi
    out="$(mktemp "$(dirname "${dest}")/.debcache-out-XXXXXX")" || exit 3
    if ! cp -- "${entry}" "${out}"; then rm -f -- "${out}"; exit 3; fi
    if ! chmod 0644 "${out}"; then rm -f -- "${out}"; exit 3; fi
    if ! mv -f -- "${out}" "${dest}"; then rm -f -- "${out}"; exit 3; fi
    # LRU is mtime-ordered, so a reuse must count as a use.
    touch -- "${entry}" 2>/dev/null || true
  ) 9>"${lock}" || rc=$?

  case "${rc}" in
    0) log_info ".deb cache HIT: ${key} (sha256 re-verified) -> ${dest}"; return 0 ;;
    1) return 1 ;;
    2) log_warn ".deb cache: stored ${key} failed SHA-256 re-verification — entry deleted, re-fetching"; return 1 ;;
    3) log_warn ".deb cache: could not copy ${key} out of the cache — re-fetching"; return 1 ;;
    4) log_warn ".deb cache: timed out waiting for the ${key} entry lock — re-fetching"; return 1 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# debcache_store <verified_deb_path>
#
# Called from publish_staged_deb, the ONE chokepoint every staged .deb passes,
# and therefore only ever with bytes a family has already verified (SHA-256 from
# signed metadata or a pin file, plus the Debian control identity check).
#
# Download-then-atomic-rename: the copy lands on a private .tmp-store-* file in
# the cache dir and is renamed into place under the key lock, so a killed build
# leaves a stray temp rather than a truncated cache entry that would then need a
# hash check to discover.
#
# ALWAYS returns 0. A cache that cannot be written must not fail a fetch.
# ---------------------------------------------------------------------------
debcache_store() {
  local src="$1" key entry lock rc=0
  debcache_enabled || return 0
  [[ -f "${src}" ]] || return 0
  key="$(basename -- "${src}")"
  debcache_key_is_valid "${key}" || return 0
  debcache_init || return 0

  entry="$(debcache_entry_path "${key}")"
  lock="$(debcache_lock_path "${key}")"

  (
    flock -w "${CERALIVE_DEBCACHE_LOCK_TIMEOUT}" 9 || exit 1
    tmp="$(mktemp "${DEBCACHE_DIR}/.tmp-store-XXXXXX")" || exit 1
    if ! cp -- "${src}" "${tmp}"; then rm -f -- "${tmp}"; exit 1; fi
    if ! chmod 0644 "${tmp}"; then rm -f -- "${tmp}"; exit 1; fi
    if ! mv -f -- "${tmp}" "${entry}"; then rm -f -- "${tmp}"; exit 1; fi
  ) 9>"${lock}" || rc=$?

  if (( rc != 0 )); then
    log_warn ".deb cache: could not store ${key} — continuing (cache is advisory)"
    return 0
  fi
  log_info ".deb cache STORE: ${key}"
  debcache_evict
  return 0
}

# ---------------------------------------------------------------------------
# debcache_evict — bounded cleanup. Least-recently-used first, ordered by mtime
# (which debcache_try_hit refreshes on every reuse, so "least recently used" is
# genuinely that and not merely "oldest download").
#
# Each victim's own key lock is taken with `flock -n` BEFORE the unlink. A victim
# whose lock is held is a victim some reader is currently verifying and copying
# out, so it is SKIPPED and left to the next pass — that is the whole safety
# property, and the reason eviction never blocks: no key lock is ever held while
# another is acquired, in either direction, so the reader/evictor pair has no
# lock-ordering hazard to get wrong.
#
# Accounting is deliberately approximate under concurrent evictors: two passes may
# both count a byte they then both try to free, so the cache can end up slightly
# UNDER the ceiling. Overshooting the ceiling is the failure that matters; going
# under it costs one re-download.
# ---------------------------------------------------------------------------
debcache_evict() {
  debcache_enabled || return 0
  (( CERALIVE_DEBCACHE_MAX_BYTES > 0 )) || return 0
  [[ -d "${DEBCACHE_DIR}" ]] || return 0

  local listing total=0 size path
  # `*.deb` only: the .locks/ subdir and any .tmp-store-* in flight are excluded
  # from both the accounting and the victim list.
  listing="$(find "${DEBCACHE_DIR}" -maxdepth 1 -type f -name '*.deb' \
    -printf '%T@ %s %p\n' 2>/dev/null | LC_ALL=C sort -n)" || return 0
  [[ -n "${listing}" ]] || return 0

  while read -r _ size _; do
    [[ -n "${size}" ]] || continue
    total=$(( total + size ))
  done <<<"${listing}"

  if (( total <= CERALIVE_DEBCACHE_MAX_BYTES )); then
    return 0
  fi

  log_info ".deb cache: ${total} B over the ${CERALIVE_DEBCACHE_MAX_BYTES} B ceiling — evicting least-recently-used entries"

  local key lock freed=0
  while read -r _ size path; do
    if (( total <= CERALIVE_DEBCACHE_MAX_BYTES )); then
      break
    fi
    [[ -n "${path}" ]] || continue
    key="$(basename -- "${path}")"
    lock="$(debcache_lock_path "${key}")"
    if (
      flock -n 9 || exit 1
      [[ -f "${path}" ]] || exit 1
      rm -f -- "${path}"
    ) 9>"${lock}" 2>/dev/null; then
      total=$(( total - size ))
      freed=$(( freed + 1 ))
      log_info ".deb cache EVICT: ${key} (${size} B)"
    else
      log_info ".deb cache: ${key} is locked by a reader — skipping this pass"
    fi
  done <<<"${listing}"

  log_info ".deb cache: evicted ${freed} entrie(s); ${total} B remain"
  return 0
}

# ---------------------------------------------------------------------------
# debcache_apt_index <apt_state> — echo the single Packages list apt wrote into an
# isolated apt state, or nothing.
#
# The two apt-driven transports (BSP native, first-party native) resolve their
# expected SHA-256 from this list, which is the same signed-metadata-derived index
# apt itself verified the download against. Without it those transports could
# still STORE (their bytes are verified) but could never HIT, because a hit needs
# the expected hash BEFORE anything is downloaded.
#
# Anything other than exactly one list is a shape this function refuses to guess
# at: the caller then simply does not consult the cache.
# ---------------------------------------------------------------------------
debcache_apt_index() {
  local apt_state="$1"
  local -a lists=()
  [[ -d "${apt_state}/lists" ]] || return 0
  shopt -s nullglob
  lists=("${apt_state}/lists/"*_Packages)
  shopt -u nullglob
  (( ${#lists[@]} == 1 )) || return 0
  printf '%s' "${lists[0]}"
}
