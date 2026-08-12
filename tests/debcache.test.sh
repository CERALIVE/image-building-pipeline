#!/usr/bin/env bash
#
# debcache.test.sh — contract for the persistent, content-addressed .deb cache
# (lib/fetch/debcache.sh) and its three fetch-family call sites.
#
# The legs this suite exists for, in the order they matter:
#
#   (a) A HIT is only ever a re-VERIFIED hit. Every leg that reuses an entry
#       asserts the SHA-256 was checked against the expected hash first, and the
#       corrupt/stale legs assert the bad entry is DELETED rather than skipped —
#       a cache that silently tolerates a bad entry re-fails every future build.
#   (b) The concurrent reader-vs-eviction race is exercised with a REAL second
#       process holding a REAL flock, not a sequential simulation. Eviction must
#       skip a locked victim, and the reader's file must survive all the way
#       through copy-out. The same eviction is then replayed with no reader to
#       prove the skip was not vacuous.
#   (c) DRY_RUN is byte-unchanged: zero downloads, zero cache mutation, no cache
#       directory brought into existence.
#   (d) CERALIVE_DEBCACHE=0 restores the pre-cache fetch semantics exactly.
#
# Counting is the behaviour under test throughout: every integration leg asserts
# the NUMBER of payload downloads, because "it worked" is true of a cache that
# never hits.

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${TESTS_DIR}/.." && pwd)"
REPO_ROOT="${PIPELINE_DIR}"
FETCH_DEBS="${PIPELINE_DIR}/lib/fetch-debs.sh"
DEBCACHE_SRC="${PIPELINE_DIR}/lib/fetch/debcache.sh"
# Static guards scan the entry point PLUS every lib/fetch/ module: a guard bound
# to one path goes quietly vacuous the moment the guarded code moves (T20).
FETCH_SOURCES=("${FETCH_DEBS}" "${PIPELINE_DIR}"/lib/fetch/*.sh)

RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/debcache.XXXXXX")"
REAL_CURL="$(command -v curl)"
REAL_SHA256SUM="$(command -v sha256sum)"

cleanup() {
	rm -rf "${RUN_DIR}"
}
trap cleanup EXIT

pass() { printf 'PASS %s\n' "$1"; }
fail() {
	printf 'FAIL %s\n' "$1" >&2
	[[ -n "${2:-}" && -f "${2}" ]] && cat "${2}" >&2
	exit 1
}

line_of() { grep -n -- "$2" "$1" | head -n1 | cut -d: -f1; }

# --------------------------------------------------------------------------
# Part A — static contract
# --------------------------------------------------------------------------

if ! grep -q 'debcache_store "${destination}"' "${PIPELINE_DIR}/lib/fetch/pool.sh"; then
	fail "publish_staged_deb does not store into the cache (the one chokepoint all three families share)"
fi
pass "static: the cache stores at publish_staged_deb, the single verified-publish chokepoint"

for module in bsp userspace firstparty; do
	if ! grep -q 'debcache_try_hit' "${PIPELINE_DIR}/lib/fetch/${module}.sh"; then
		fail "fetch/${module}.sh never consults the cache before downloading"
	fi
done
pass "static: all three fetch families consult debcache_try_hit before downloading"

# Both BSP transports (native apt + curl) and both first-party transports must be
# covered — a family half-wired reads as "cached" while its default host path is not.
bsp_hits="$(grep -c 'debcache_try_hit' "${PIPELINE_DIR}/lib/fetch/bsp.sh")"
fp_hits="$(grep -c 'debcache_try_hit' "${PIPELINE_DIR}/lib/fetch/firstparty.sh")"
if [[ "${bsp_hits}" -ne 2 || "${fp_hits}" -ne 2 ]]; then
	fail "expected both transports wired per family (bsp=2 firstparty=2), got bsp=${bsp_hits} firstparty=${fp_hits}"
fi
pass "static: both transports of BSP and first-party are wired, not just one each"

if cat "${FETCH_SOURCES[@]}" | grep -E 'debcache_(store|try_hit)' \
		| grep -Eqi 'InRelease|Packages|Release|keyring|\.gpg|\.asc'; then
	fail "a cache call site names apt index/metadata — only final verified .deb payloads may be cached"
fi
pass "static: no apt index / InRelease / Packages / keyring is ever routed into the cache"

if ! grep -q 'deb\$' "${DEBCACHE_SRC}"; then
	fail "debcache_key_is_valid does not anchor the key on a .deb suffix"
fi
pass "static: a cache key must be a traversal-free .deb basename"

# The reader must hold the key lock across verification AND copy-out; releasing
# after the hash check would let eviction unlink the file it just verified.
hit_start="$(line_of "${DEBCACHE_SRC}" 'debcache_try_hit() {')"
hit_flock="$(awk -v s="${hit_start}" 'NR>s && /flock -w/ {print NR; exit}' "${DEBCACHE_SRC}")"
hit_sha="$(awk -v s="${hit_start}" 'NR>s && /sha256sum/ {print NR; exit}' "${DEBCACHE_SRC}")"
hit_mv="$(awk -v s="${hit_start}" 'NR>s && /mv -f -- "\$\{out\}"/ {print NR; exit}' "${DEBCACHE_SRC}")"
hit_close="$(awk -v s="${hit_start}" 'NR>s && /^  \) 9>/ {print NR; exit}' "${DEBCACHE_SRC}")"
if [[ -z "${hit_flock}" || -z "${hit_sha}" || -z "${hit_mv}" || -z "${hit_close}" ]] \
		|| (( hit_flock >= hit_sha || hit_sha >= hit_mv || hit_mv >= hit_close )); then
	fail "debcache_try_hit does not hold the key lock across verify -> copy-out (flock=${hit_flock:-?} sha=${hit_sha:-?} mv=${hit_mv:-?} unlock=${hit_close:-?})"
fi
if awk -v s="${hit_start}" -v e="${hit_close}" 'NR>s && NR<e && /flock -u/ {found=1} END {exit !found}' \
		"${DEBCACHE_SRC}"; then
	fail "debcache_try_hit releases the key lock early — the whole hit sequence must run under one hold"
fi
pass "static: the reader holds the key lock across the WHOLE hit sequence (verify -> copy-out)"

evict_start="$(line_of "${DEBCACHE_SRC}" 'debcache_evict() {')"
evict_flock="$(awk -v s="${evict_start}" 'NR>s && /flock -n 9/ {print NR; exit}' "${DEBCACHE_SRC}")"
evict_rm="$(awk -v s="${evict_start}" 'NR>s && /rm -f -- "\$\{path\}"/ {print NR; exit}' "${DEBCACHE_SRC}")"
if [[ -z "${evict_flock}" || -z "${evict_rm}" ]] || (( evict_flock >= evict_rm )); then
	fail "eviction unlinks without first taking the victim's own key lock"
fi
pass "static: eviction takes each victim's key lock BEFORE unlinking it"

# Code lines only: the header deliberately DISCUSSES the per-board build lock to
# record why this cache may not reuse it, so a whole-file grep would read its own
# rationale as a violation.
debcache_code() { grep -vE '^[[:space:]]*#' "${DEBCACHE_SRC}"; }
if ! debcache_code | grep -q 'DEBCACHE_DIR=.*mkosi/\.staging/\.debcache'; then
	fail "the default cache path is not the repo-local ignored staging tree"
fi
if debcache_code | grep -qE 'BUILD_LOCK|acquire_board_lock'; then
	fail "the cache reuses the PER-BOARD build lock; it must own a per-cache-key lock"
fi
pass "static: repo-local cache path, and a per-cache-key lock rather than the per-board build lock"

if command -v git >/dev/null 2>&1 && git -C "${REPO_ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
	if ! git -C "${REPO_ROOT}" check-ignore -q "mkosi/.staging/.debcache/x_1_arm64.deb"; then
		fail "the default cache path is NOT gitignored"
	fi
	pass "static: the default cache path is inside the already-ignored staging tree"
fi

# --------------------------------------------------------------------------
# Shared fixture: minimal but REAL .deb archives (ar + control.tar.gz), so the
# shipped control-identity checks run against genuine packages.
# --------------------------------------------------------------------------
make_deb() { # <outfile> <package> <version> <arch> <payload-marker>
	local out="$1" pkg="$2" ver="$3" arch="$4" marker="$5"
	local work; work="$(mktemp -d "${RUN_DIR}/mkdeb.XXXXXX")"
	mkdir -p "${work}/ctl" "${work}/data"
	printf 'Package: %s\nVersion: %s\nArchitecture: %s\nMaintainer: t <t@t>\nDescription: fixture\n' \
		"${pkg}" "${ver}" "${arch}" >"${work}/ctl/control"
	printf '%s\n' "${marker}" >"${work}/data/payload"
	tar -czf "${work}/control.tar.gz" -C "${work}/ctl" ./control
	tar -czf "${work}/data.tar.gz" -C "${work}/data" ./payload
	printf '2.0\n' >"${work}/debian-binary"
	( cd "${work}" && ar rc "$(basename "${out}")" debian-binary control.tar.gz data.tar.gz )
	mv "${work}/$(basename "${out}")" "${out}"
	rm -rf "${work}"
}
sha_of() { "${REAL_SHA256SUM}" "$1" | awk '{print $1}'; }

# Load the shipped implementation. Sourcing installs fetch/retry.sh's EXIT trap,
# which would otherwise replace this suite's own cleanup.
UNIT_CACHE="${RUN_DIR}/unit-cache"
# shellcheck source=../lib/fetch-debs.sh
CERALIVE_DEBCACHE_DIR="${UNIT_CACHE}" source "${FETCH_DEBS}"
trap 'fetch_scratch_cleanup; cleanup' EXIT

# --------------------------------------------------------------------------
# Part B — unit legs against the shipped module
# --------------------------------------------------------------------------
UNIT_SRC="${RUN_DIR}/src"; mkdir -p "${UNIT_SRC}"
UNIT_DEST="${RUN_DIR}/dest"; mkdir -p "${UNIT_DEST}"
make_deb "${UNIT_SRC}/alpha_1.0-1_arm64.deb" alpha 1.0-1 arm64 alpha-payload
ALPHA_SHA="$(sha_of "${UNIT_SRC}/alpha_1.0-1_arm64.deb")"

if ! debcache_store "${UNIT_SRC}/alpha_1.0-1_arm64.deb"; then
	fail "debcache_store returned non-zero (a cache failure must never fail a fetch)"
fi
if [[ ! -f "${UNIT_CACHE}/alpha_1.0-1_arm64.deb" ]]; then
	fail "debcache_store did not create the <package>_<version>_<arch>.deb entry"
fi
pass "unit: store creates a <package>_<version>_<arch>.deb entry"

if debcache_try_hit "beta_9.9-9_arm64.deb" "${ALPHA_SHA}" "${UNIT_DEST}/beta.deb"; then
	fail "a MISS reported a hit"
fi
if [[ -e "${UNIT_DEST}/beta.deb" ]]; then
	fail "a MISS wrote something to the destination"
fi
pass "unit: MISS returns non-zero and writes nothing"

if ! debcache_try_hit "alpha_1.0-1_arm64.deb" "${ALPHA_SHA}" "${UNIT_DEST}/alpha_1.0-1_arm64.deb"; then
	fail "a stored, matching entry did not produce a hit"
fi
if [[ "$(sha_of "${UNIT_DEST}/alpha_1.0-1_arm64.deb")" != "${ALPHA_SHA}" ]]; then
	fail "the reused file does not match the expected hash"
fi
if [[ "$(stat -c '%a' "${UNIT_DEST}/alpha_1.0-1_arm64.deb")" != "644" ]]; then
	fail "the reused file is not mode 0644 like a normally-published .deb"
fi
pass "unit: HIT re-verifies the SHA and publishes a mode-0644 copy"

printf 'tampered\n' >>"${UNIT_CACHE}/alpha_1.0-1_arm64.deb"
rm -f "${UNIT_DEST}/alpha_1.0-1_arm64.deb"
if debcache_try_hit "alpha_1.0-1_arm64.deb" "${ALPHA_SHA}" "${UNIT_DEST}/alpha_1.0-1_arm64.deb"; then
	fail "a CORRUPT entry was reused"
fi
if [[ -e "${UNIT_CACHE}/alpha_1.0-1_arm64.deb" ]]; then
	fail "a corrupt entry was left in the cache to fail every future build"
fi
if [[ -e "${UNIT_DEST}/alpha_1.0-1_arm64.deb" ]]; then
	fail "a corrupt entry still wrote to the destination"
fi
pass "unit: a CORRUPT entry is refused, DELETED, and never reaches the destination"

debcache_store "${UNIT_SRC}/alpha_1.0-1_arm64.deb"
if debcache_try_hit "alpha_1.0-1_arm64.deb" \
		"0000000000000000000000000000000000000000000000000000000000000000" \
		"${UNIT_DEST}/alpha_1.0-1_arm64.deb"; then
	fail "an entry whose bytes no longer match the archive's expected hash was reused"
fi
if [[ -e "${UNIT_CACHE}/alpha_1.0-1_arm64.deb" ]]; then
	fail "a STALE entry (archive replaced the bytes) was not evicted on mismatch"
fi
pass "unit: a STALE entry (expected hash moved) is refused and deleted"

# Eviction: three entries, explicit staggered mtimes, a ceiling that fits two.
EV_CACHE="${RUN_DIR}/evict-cache"
# Re-point the sourced module at a leg-private cache; consumed by fetch/debcache.sh.
# shellcheck disable=SC2034
DEBCACHE_DIR="${EV_CACHE}"; _DEBCACHE_READY=0
mkdir -p "${EV_CACHE}/.locks"
for n in 1 2 3; do
	head -c 1000 /dev/zero | tr '\0' 'x' >"${EV_CACHE}/ev${n}_1.0_arm64.deb"
done
touch -d '2020-01-01 00:00:00' "${EV_CACHE}/ev1_1.0_arm64.deb"
touch -d '2020-01-02 00:00:00' "${EV_CACHE}/ev2_1.0_arm64.deb"
touch -d '2020-01-03 00:00:00' "${EV_CACHE}/ev3_1.0_arm64.deb"
CERALIVE_DEBCACHE_MAX_BYTES=2100 debcache_evict >"${RUN_DIR}/evict1.log" 2>&1
if [[ -e "${EV_CACHE}/ev1_1.0_arm64.deb" ]]; then
	fail "eviction did not remove the least-recently-used entry" "${RUN_DIR}/evict1.log"
fi
if [[ ! -e "${EV_CACHE}/ev2_1.0_arm64.deb" || ! -e "${EV_CACHE}/ev3_1.0_arm64.deb" ]]; then
	fail "eviction removed more than the ceiling required" "${RUN_DIR}/evict1.log"
fi
pass "unit: bounded LRU eviction drops the oldest entry and stops at the ceiling"

# mtime is refreshed on reuse, so "least recently USED" is not merely "oldest download".
if ! debcache_try_hit "ev2_1.0_arm64.deb" "$(sha_of "${EV_CACHE}/ev2_1.0_arm64.deb")" \
		"${UNIT_DEST}/ev2.deb"; then
	fail "could not reuse ev2 to refresh its mtime"
fi
CERALIVE_DEBCACHE_MAX_BYTES=1100 debcache_evict >"${RUN_DIR}/evict2.log" 2>&1
if [[ ! -e "${EV_CACHE}/ev2_1.0_arm64.deb" ]]; then
	fail "the just-REUSED entry was evicted ahead of an older, untouched one" "${RUN_DIR}/evict2.log"
fi
pass "unit: reuse refreshes the LRU position (mtime is a use, not just a download)"

# --------------------------------------------------------------------------
# Part C — the concurrent hit-vs-eviction race, with a REAL second process
# --------------------------------------------------------------------------
RACE_CACHE="${RUN_DIR}/race-cache"
# shellcheck disable=SC2034
DEBCACHE_DIR="${RACE_CACHE}"; _DEBCACHE_READY=0
mkdir -p "${RACE_CACHE}/.locks" "${RUN_DIR}/race-dest"
make_deb "${RUN_DIR}/race_1.0-1_arm64.deb" race 1.0-1 arm64 race-payload
cp "${RUN_DIR}/race_1.0-1_arm64.deb" "${RACE_CACHE}/race_1.0-1_arm64.deb"
RACE_SHA="$(sha_of "${RACE_CACHE}/race_1.0-1_arm64.deb")"

# A stub sha256sum that sleeps first, so the SHIPPED debcache_try_hit genuinely
# holds the key flock across a long verification window. The shipped code is
# unmodified; only the clock it runs against is.
SLOW_BIN="${RUN_DIR}/slow-bin"; mkdir -p "${SLOW_BIN}"
cat >"${SLOW_BIN}/sha256sum" <<SH
#!/usr/bin/env bash
sleep "\${SLOW_SHA_SECONDS:-4}"
exec "${REAL_SHA256SUM}" "\$@"
SH
chmod +x "${SLOW_BIN}/sha256sum"

cat >"${RUN_DIR}/reader.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source "${FETCH_DEBS}"
if debcache_try_hit "${RACE_KEY}" "${RACE_SHA}" "${RACE_DEST}"; then
	printf 'READER_HIT\n'
	exit 0
fi
printf 'READER_MISS\n'
exit 1
SH
chmod +x "${RUN_DIR}/reader.sh"

lock_is_held() { ! flock -n "$1" true 2>/dev/null; }

PATH="${SLOW_BIN}:${PATH}" \
	FETCH_DEBS="${FETCH_DEBS}" \
	CERALIVE_DEBCACHE_DIR="${RACE_CACHE}" \
	RACE_KEY="race_1.0-1_arm64.deb" \
	RACE_SHA="${RACE_SHA}" \
	RACE_DEST="${RUN_DIR}/race-dest/race_1.0-1_arm64.deb" \
	SLOW_SHA_SECONDS=4 \
	"${RUN_DIR}/reader.sh" >"${RUN_DIR}/reader.out" 2>&1 &
READER_PID=$!

RACE_LOCK="${RACE_CACHE}/.locks/race_1.0-1_arm64.deb.lock"
held=0
for _ in $(seq 1 60); do
	if [[ -e "${RACE_LOCK}" ]] && lock_is_held "${RACE_LOCK}"; then held=1; break; fi
	sleep 0.2
done
if (( held == 0 )); then
	wait "${READER_PID}" || true
	fail "the reader never took the key lock — the race leg would be vacuous" "${RUN_DIR}/reader.out"
fi

# Eviction runs while the reader is provably mid-verification, with a ceiling of
# 1 byte so this exact entry is the intended victim.
CERALIVE_DEBCACHE_MAX_BYTES=1 debcache_evict >"${RUN_DIR}/race-evict.log" 2>&1
if [[ ! -e "${RACE_CACHE}/race_1.0-1_arm64.deb" ]]; then
	fail "eviction unlinked an entry a reader was holding" "${RUN_DIR}/race-evict.log"
fi
if ! grep -q 'locked by a reader' "${RUN_DIR}/race-evict.log"; then
	fail "eviction did not report skipping the locked victim" "${RUN_DIR}/race-evict.log"
fi
pass "concurrency: eviction SKIPS a victim a live reader holds, and the entry survives"

reader_rc=0
wait "${READER_PID}" || reader_rc=$?
if (( reader_rc != 0 )) || ! grep -q 'READER_HIT' "${RUN_DIR}/reader.out"; then
	fail "the concurrent reader did not complete its hit" "${RUN_DIR}/reader.out"
fi
if [[ "$(sha_of "${RUN_DIR}/race-dest/race_1.0-1_arm64.deb")" != "${RACE_SHA}" ]]; then
	fail "the concurrent reader's reused file is not the verified content"
fi
pass "concurrency: the reader's file survives verification through copy-out, bytes intact"

# Non-vacuity: the SAME eviction, with no reader, does remove the entry.
CERALIVE_DEBCACHE_MAX_BYTES=1 debcache_evict >"${RUN_DIR}/race-evict2.log" 2>&1
if [[ -e "${RACE_CACHE}/race_1.0-1_arm64.deb" ]]; then
	fail "eviction failed to remove an UNLOCKED over-ceiling entry — the skip leg proves nothing" "${RUN_DIR}/race-evict2.log"
fi
pass "concurrency: with no reader holding it, the same eviction DOES remove the entry"

# The leg above slows the reader inside VERIFICATION, so it cannot distinguish
# "holds the lock to the end" from "unlocks the instant the hash matches". This
# one slows the step BETWEEN verification and the copy, which is the exact window
# the task's race lives in: release there and eviction unlinks the entry the
# reader has already verified and is about to read.
SLOW_MKTEMP_BIN="${RUN_DIR}/slow-mktemp-bin"; mkdir -p "${SLOW_MKTEMP_BIN}"
cat >"${SLOW_MKTEMP_BIN}/mktemp" <<SH
#!/usr/bin/env bash
sleep "\${SLOW_MKTEMP_SECONDS:-4}"
exec "$(command -v mktemp)" "\$@"
SH
chmod +x "${SLOW_MKTEMP_BIN}/mktemp"

RACE2_CACHE="${RUN_DIR}/race2-cache"
# shellcheck disable=SC2034
DEBCACHE_DIR="${RACE2_CACHE}"; _DEBCACHE_READY=0
mkdir -p "${RACE2_CACHE}/.locks" "${RUN_DIR}/race2-dest"
cp "${RUN_DIR}/race_1.0-1_arm64.deb" "${RACE2_CACHE}/race_1.0-1_arm64.deb"

PATH="${SLOW_MKTEMP_BIN}:${PATH}" \
	FETCH_DEBS="${FETCH_DEBS}" \
	CERALIVE_DEBCACHE_DIR="${RACE2_CACHE}" \
	RACE_KEY="race_1.0-1_arm64.deb" \
	RACE_SHA="${RACE_SHA}" \
	RACE_DEST="${RUN_DIR}/race2-dest/race_1.0-1_arm64.deb" \
	SLOW_MKTEMP_SECONDS=4 \
	"${RUN_DIR}/reader.sh" >"${RUN_DIR}/reader2.out" 2>&1 &
READER2_PID=$!

RACE2_LOCK="${RACE2_CACHE}/.locks/race_1.0-1_arm64.deb.lock"
held=0
for _ in $(seq 1 60); do
	if [[ -e "${RACE2_LOCK}" ]] && lock_is_held "${RACE2_LOCK}"; then held=1; break; fi
	sleep 0.2
done
if (( held == 0 )); then
	wait "${READER2_PID}" || true
	fail "the reader released the key lock after verification — eviction can unlink between verify and reuse" "${RUN_DIR}/reader2.out"
fi

CERALIVE_DEBCACHE_MAX_BYTES=1 debcache_evict >"${RUN_DIR}/race2-evict.log" 2>&1
if [[ ! -e "${RACE2_CACHE}/race_1.0-1_arm64.deb" ]]; then
	fail "eviction unlinked a verified entry between the reader's check and its copy" "${RUN_DIR}/race2-evict.log"
fi

reader2_rc=0
wait "${READER2_PID}" || reader2_rc=$?
if (( reader2_rc != 0 )) || ! grep -q 'READER_HIT' "${RUN_DIR}/reader2.out"; then
	fail "the reader could not complete its copy-out under concurrent eviction" "${RUN_DIR}/reader2.out"
fi
if [[ "$(sha_of "${RUN_DIR}/race2-dest/race_1.0-1_arm64.deb")" != "${RACE_SHA}" ]]; then
	fail "the copy-out under concurrent eviction produced the wrong bytes"
fi
pass "concurrency: the verify -> copy-out window itself is lock-protected against eviction"

# --------------------------------------------------------------------------
# Part D — integration against the shipped rk3588-userspace fetcher
#
# The userspace family is pinned by exact URL + SHA-256 in a committed file, so
# it can be driven end to end offline over file:// URLs with the real fetcher,
# the real pin reader, the real control-identity checks and the real cache.
# --------------------------------------------------------------------------
POOL="${RUN_DIR}/pool"; mkdir -p "${POOL}"
make_deb "${POOL}/pkga_1.0-1_arm64.deb" pkga 1.0-1 arm64 pkga-payload
make_deb "${POOL}/pkgb_2.0-1_all.deb" pkgb 2.0-1 all pkgb-payload
PKGA_SHA="$(sha_of "${POOL}/pkga_1.0-1_arm64.deb")"
PKGB_SHA="$(sha_of "${POOL}/pkgb_2.0-1_all.deb")"

PIN_FILE="${RUN_DIR}/pins.txt"
{
	printf '# fixture pins\n'
	printf 'pkga  pkga_1.0-1_arm64.deb  %s  file://%s/pkga_1.0-1_arm64.deb\n' "${PKGA_SHA}" "${POOL}"
	printf 'pkgb  pkgb_2.0-1_all.deb  %s  file://%s/pkgb_2.0-1_all.deb\n' "${PKGB_SHA}" "${POOL}"
} >"${PIN_FILE}"

FAMILY="${RUN_DIR}/family.yaml"
printf 'armbian_branch: vendor\n' >"${FAMILY}"

COUNT_DIR="${RUN_DIR}/counts"; mkdir -p "${COUNT_DIR}"
COUNT_BIN="${RUN_DIR}/count-bin"; mkdir -p "${COUNT_BIN}"
cat >"${COUNT_BIN}/curl" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"\${COUNT_DIR}/curl"
exec "${REAL_CURL}" "\$@"
SH
chmod +x "${COUNT_BIN}/curl"

INT_CACHE="${RUN_DIR}/int-cache"
curl_count() { [[ -f "${COUNT_DIR}/curl" ]] && wc -l <"${COUNT_DIR}/curl" | tr -d ' ' || printf '0'; }

run_userspace() { # <dest> <log> [extra env assignments...]
	local dest="$1" log="$2"; shift 2
	rm -f "${COUNT_DIR}/curl"
	mkdir -p "${dest}"
	(
		export PATH="${COUNT_BIN}:${PATH}"
		export COUNT_DIR="${COUNT_DIR}"
		export FIRMWARE_PACKAGES="pkga pkgb"
		export RK3588_USERSPACE_DEB_VERSIONS_FILE="${PIN_FILE}"
		export CERALIVE_DEBCACHE_DIR="${INT_CACHE}"
		export DRY_RUN=""
		local kv
		for kv in "$@"; do export "${kv?}"; done
		# shellcheck source=/dev/null
		source "${FETCH_DEBS}"
		fetch_rk3588_userspace "${FAMILY}" "${dest}"
	) >"${log}" 2>&1
}

if ! run_userspace "${RUN_DIR}/d1" "${RUN_DIR}/run1.log"; then
	fail "first real userspace fetch failed" "${RUN_DIR}/run1.log"
fi
if [[ "$(curl_count)" != "2" ]]; then
	fail "cold run did not download both payloads (curl=$(curl_count))" "${RUN_DIR}/run1.log"
fi
if [[ "$(sha_of "${RUN_DIR}/d1/pkga_1.0-1_arm64.deb")" != "${PKGA_SHA}" ]]; then
	fail "cold run staged the wrong bytes for pkga"
fi
if [[ ! -f "${INT_CACHE}/pkga_1.0-1_arm64.deb" || ! -f "${INT_CACHE}/pkgb_2.0-1_all.deb" ]]; then
	fail "cold run did not populate the cache" "${RUN_DIR}/run1.log"
fi
pass "integration: a cold fetch downloads both payloads and populates the cache"

if ! run_userspace "${RUN_DIR}/d2" "${RUN_DIR}/run2.log"; then
	fail "second userspace fetch failed" "${RUN_DIR}/run2.log"
fi
if [[ "$(curl_count)" != "0" ]]; then
	fail "second fetch of the same plan still downloaded payloads (curl=$(curl_count))" "${RUN_DIR}/run2.log"
fi
if [[ "$(grep -c '.deb cache HIT' "${RUN_DIR}/run2.log")" != "2" ]]; then
	fail "second fetch did not log two re-verified cache hits" "${RUN_DIR}/run2.log"
fi
if [[ "$(sha_of "${RUN_DIR}/d2/pkga_1.0-1_arm64.deb")" != "${PKGA_SHA}" \
		|| "$(sha_of "${RUN_DIR}/d2/pkgb_2.0-1_all.deb")" != "${PKGB_SHA}" ]]; then
	fail "the cache-served run staged the wrong bytes"
fi
pass "integration: a second fetch of the same plan performs ZERO payload downloads"

printf 'tampered\n' >>"${INT_CACHE}/pkga_1.0-1_arm64.deb"
if ! run_userspace "${RUN_DIR}/d3" "${RUN_DIR}/run3.log"; then
	fail "the corrupt-entry run failed instead of re-fetching" "${RUN_DIR}/run3.log"
fi
if [[ "$(curl_count)" != "1" ]]; then
	fail "the corrupt entry did not cause exactly one re-download (curl=$(curl_count))" "${RUN_DIR}/run3.log"
fi
if [[ "$(sha_of "${RUN_DIR}/d3/pkga_1.0-1_arm64.deb")" != "${PKGA_SHA}" ]]; then
	fail "the re-fetched package does not match its pin"
fi
if [[ "$(sha_of "${INT_CACHE}/pkga_1.0-1_arm64.deb")" != "${PKGA_SHA}" ]]; then
	fail "the corrupt cache entry was not replaced by the re-fetched bytes"
fi
pass "integration: a corrupt cache entry re-fetches exactly that package and repairs itself"

DISABLED_CACHE="${RUN_DIR}/disabled-cache"
if ! ( INT_CACHE="${DISABLED_CACHE}" run_userspace "${RUN_DIR}/d4" "${RUN_DIR}/run4.log" \
		"CERALIVE_DEBCACHE=0" "CERALIVE_DEBCACHE_DIR=${DISABLED_CACHE}" ); then
	fail "the cache-disabled run failed" "${RUN_DIR}/run4.log"
fi
if [[ "$(curl_count)" != "2" ]]; then
	fail "CERALIVE_DEBCACHE=0 still served from the cache (curl=$(curl_count))" "${RUN_DIR}/run4.log"
fi
if [[ -e "${DISABLED_CACHE}" ]]; then
	fail "CERALIVE_DEBCACHE=0 created a cache directory"
fi
pass "integration: CERALIVE_DEBCACHE=0 downloads every payload and creates no cache"

snapshot() { find "$1" -mindepth 1 -printf '%p %s %T@\n' 2>/dev/null | LC_ALL=C sort; }
snapshot "${INT_CACHE}" >"${RUN_DIR}/cache-before"
if ! run_userspace "${RUN_DIR}/d5" "${RUN_DIR}/run5.log" "DRY_RUN=1"; then
	fail "the DRY_RUN plan failed" "${RUN_DIR}/run5.log"
fi
snapshot "${INT_CACHE}" >"${RUN_DIR}/cache-after"
if [[ "$(curl_count)" != "0" ]]; then
	fail "DRY_RUN executed downloads (curl=$(curl_count))" "${RUN_DIR}/run5.log"
fi
if ! diff -q "${RUN_DIR}/cache-before" "${RUN_DIR}/cache-after" >/dev/null; then
	fail "DRY_RUN mutated the cache" "${RUN_DIR}/run5.log"
fi
if grep -q '.deb cache' "${RUN_DIR}/run5.log"; then
	fail "DRY_RUN emitted cache lines — the resolved plan must be byte-unchanged" "${RUN_DIR}/run5.log"
fi
pass "integration: DRY_RUN downloads nothing, mutates nothing, and says nothing about the cache"

printf 'ALL DEBCACHE CONTRACT LEGS PASSED\n'
