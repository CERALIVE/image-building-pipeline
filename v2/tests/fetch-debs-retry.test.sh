#!/usr/bin/env bash
#
# fetch-debs-retry.test.sh — fault-injection contract for fetch-debs.sh's bounded
# transient-failure retry and its trap-managed scratch dir.
#
# The four legs this suite exists for:
#   (a) a transient failure followed by success        -> succeeds, 2 attempts logged
#   (b) retries exhausted                              -> fails, status + diagnostic survive
#   (c) a SHA-256 / signature / credential VERDICT     -> exactly 1 attempt, no retry
#   (d) a signal mid-fetch                             -> zero stray tmpfiles
#
# Leg (c) is the one that matters most: a retry loop that replays a bad signature
# or a bad hash turns a loud, immediate, correct refusal into a slow one whose
# real diagnostic is buried under two more attempts. Nothing here asserts merely
# that a retry "works" — every leg counts ATTEMPTS, because the count is the
# behaviour under test.

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2="$(cd "${TESTS_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${V2}/.." && pwd)"
FETCH_DEBS="${V2}/lib/fetch-debs.sh"
# The fetch path is the entry point PLUS its lib/fetch/ family modules, so every
# STATIC guard below must scan all of them — scanning only the entry would go
# quietly vacuous the moment a curl call site moves into a module.
FETCH_SOURCES=("${FETCH_DEBS}" "${V2}"/lib/fetch/*.sh)
ARTIFACT_DIR="${REPO_ROOT}/test-results/flows/fetch-retry"
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fetch-debs-retry.XXXXXX")"
FAKE_BIN="${RUN_DIR}/bin"
FAKE_CURL_BIN="${RUN_DIR}/curl-bin"
COUNT_DIR="${RUN_DIR}/counts"
RESULTS_LOG="${ARTIFACT_DIR}/fetch-debs-retry.log"

cleanup() {
	rm -rf "${RUN_DIR}"
}
trap cleanup EXIT

mkdir -p "${FAKE_BIN}" "${FAKE_CURL_BIN}" "${COUNT_DIR}" "${ARTIFACT_DIR}"
: >"${RESULTS_LOG}"

pass() { printf 'PASS %s\n' "$1" | tee -a "${RESULTS_LOG}"; }
fail() {
	printf 'FAIL %s\n' "$1" | tee -a "${RESULTS_LOG}"
	[[ -n "${2:-}" && -f "${2}" ]] && cat "${2}" >&2
	exit 1
}

count_of() {
	local name="$1"
	[[ -f "${COUNT_DIR}/${name}" ]] || { printf '0'; return 0; }
	wc -l <"${COUNT_DIR}/${name}" | tr -d ' '
}

reset_counts() { rm -f "${COUNT_DIR}"/*; }

# --------------------------------------------------------------------------
# Fake apt-get. Every invocation appends one line to a per-subcommand counter,
# so a leg can assert "exactly one attempt" rather than merely "it failed".
# FAKE_APT_FAIL_MODE picks the injected fault; FAKE_APT_FAIL_TIMES bounds how
# many leading invocations of `update` fail before it starts behaving.
# --------------------------------------------------------------------------
cat >"${FAKE_BIN}/apt-get" <<'SH'
#!/usr/bin/env bash
set -uo pipefail

command_name=""
for arg in "$@"; do
	case "${arg}" in
		update|download) command_name="${arg}"; break ;;
	esac
done
printf '%s\n' "${command_name}" >>"${COUNT_DIR}/${command_name:-other}"
attempt="$(wc -l <"${COUNT_DIR}/${command_name:-other}")"

inject_failure() {
	case "${FAKE_APT_FAIL_MODE:-none}" in
		transient)
			printf 'E: Failed to fetch %s  Could not connect to apt.invalid:443 (10.0.0.1), connection timed out\n' \
				"${FAKE_APT_FAIL_URL:-https://apt.invalid/dists/stable/InRelease}" >&2
			printf 'E: Some index files failed to download.\n' >&2
			return 100
			;;
		hash)
			printf 'E: Failed to fetch https://apt.invalid/dists/stable/InRelease  Hash Sum mismatch\n' >&2
			return 100
			;;
		gpg)
			printf 'E: GPG error: https://apt.invalid stable InRelease: The following signatures were invalid: BADSIG 0000000000000000\n' >&2
			return 100
			;;
		notfound)
			printf 'E: Failed to fetch https://apt.invalid/pool/x.deb  404  Not Found [IP: 10.0.0.1 443]\n' >&2
			return 100
			;;
		*) return 0 ;;
	esac
}

if [[ "${command_name}" == "update" ]]; then
	if (( attempt <= ${FAKE_APT_FAIL_TIMES:-0} )); then
		inject_failure
		exit $?
	fi
	exit 0
fi

if [[ "${command_name}" == "download" ]]; then
	if (( attempt <= ${FAKE_APT_DOWNLOAD_FAIL_TIMES:-0} )); then
		inject_failure
		exit $?
	fi
	seen_download=0
	for arg in "$@"; do
		if [[ "${seen_download}" -eq 0 ]]; then
			[[ "${arg}" == "download" ]] && seen_download=1
			continue
		fi
		pkg="${arg%%=*}"
		version="${arg#*=}"
		tmp="$(mktemp -d)"
		mkdir -p "${tmp}/DEBIAN"
		printf 'Package: %s\nVersion: %s\nArchitecture: %s\nMaintainer: Test <test@example.invalid>\nDescription: fixture\n' \
			"${pkg}" "${version}" "${ARCH:-arm64}" >"${tmp}/DEBIAN/control"
		printf '2.0\n' >"${tmp}/debian-binary"
		tar -czf "${tmp}/control.tar.gz" -C "${tmp}/DEBIAN" ./control
		tar -czf "${tmp}/data.tar.gz" --files-from /dev/null
		ar r "${pkg}_${version}_${ARCH:-arm64}.deb" \
			"${tmp}/debian-binary" "${tmp}/control.tar.gz" "${tmp}/data.tar.gz" >/dev/null
		rm -rf "${tmp}"
	done
fi
exit 0
SH
chmod 755 "${FAKE_BIN}/apt-get"

# --------------------------------------------------------------------------
# Fake curl / gpgv for the first-party curl transport and the signal leg. The
# curl stub records every requested URL so a leg can prove a hash verdict was
# fetched EXACTLY once, and honours FAKE_CURL_HANG_ON to stall a fetch so the
# signal leg can interrupt a real in-flight download.
# --------------------------------------------------------------------------
cat >"${FAKE_CURL_BIN}/curl" <<'SH'
#!/usr/bin/env bash
set -uo pipefail

out=""
url=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		-o) out="$2"; shift 2 ;;
		--cert|--key|--retry|--connect-timeout|--max-time) shift 2 ;;
		-*) shift ;;
		*) url="$1"; shift ;;
	esac
done
[[ -n "${out}" && -n "${url}" ]] || exit 2
printf '%s\n' "${url}" >>"${COUNT_DIR}/curl-urls"

if [[ -n "${FAKE_CURL_HANG_ON:-}" && "${url}" == *"${FAKE_CURL_HANG_ON}" ]]; then
	# Snapshot the scratch state BEFORE stalling: the signal leg needs proof the
	# directory really existed at interrupt time, or "nothing leaked" is vacuous.
	ls -1 "${TMPDIR:-/tmp}" >"${FAKE_CURL_HANG_MARKER}" 2>/dev/null || true
	sleep 120
	exit 28
fi

case "${url}" in
	*/InRelease) cp "${FAKE_REPO_DIR}/InRelease" "${out}" ;;
	*/Packages.gz) cp "${FAKE_REPO_DIR}/Packages.gz" "${out}" ;;
	*.deb) cp "${FAKE_REPO_DIR}/debs/$(basename "${url}")" "${out}" ;;
	*) exit 22 ;;
esac
SH
chmod 755 "${FAKE_CURL_BIN}/curl"

cat >"${FAKE_CURL_BIN}/gpgv" <<'SH'
#!/usr/bin/env bash
out=""
inrelease=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		--status-fd|--keyring) shift 2 ;;
		--output) out="$2"; shift 2 ;;
		-*) shift ;;
		*) inrelease="$1"; shift ;;
	esac
done
[[ -n "${out}" && -n "${inrelease}" ]] || exit 2
cp "${inrelease}" "${out}"
SH
chmod 755 "${FAKE_CURL_BIN}/gpgv"

b64() { printf '%s' "$1" | base64 -w0; }
KEY_B64="$(b64 'test public keyring')"
CRT_B64="$(b64 'test client certificate')"

run_first_party_native() {
	local dest="$1"
	shift
	mkdir -p "${dest}"
	# Scenario-private .deb cache. These legs COUNT downloads and inject download
	# failures, so a cache shared with an earlier leg (or with a developer's real
	# build) would serve the very payload the leg is trying to fail — the fetch
	# would succeed and the assertion would be measuring ambient state.
	local cache_dir; cache_dir="$(dirname "${dest}")/.debcache"
	env \
		PATH="${FAKE_BIN}:${PATH}" \
		COUNT_DIR="${COUNT_DIR}" \
		APT_GPG_PUBLIC_B64="${KEY_B64}" \
		CERALIVE_DEBCACHE_DIR="${cache_dir}" \
		"$@" \
		bash -c 'source "$1"; fetch_first_party "$2"' bash "${FETCH_DEBS}" "${dest}"
}

prepare_fake_curl_repo() {
	local repo="$1"
	local packages="${repo}/Packages"
	mkdir -p "${repo}/debs"
	: >"${packages}"
	local spec pkg version deb sha tmp
	while IFS= read -r spec; do
		pkg="${spec%%=*}"
		version="${spec#*=}"
		deb="${pkg}_${version}_${ARCH:-arm64}.deb"
		tmp="$(mktemp -d)"
		mkdir -p "${tmp}/DEBIAN"
		printf 'Package: %s\nVersion: %s\nArchitecture: %s\nMaintainer: Test <test@example.invalid>\nDescription: fixture\n' \
			"${pkg}" "${version}" "${ARCH:-arm64}" >"${tmp}/DEBIAN/control"
		printf '2.0\n' >"${tmp}/debian-binary"
		tar -czf "${tmp}/control.tar.gz" -C "${tmp}/DEBIAN" ./control
		tar -czf "${tmp}/data.tar.gz" --files-from /dev/null
		ar r "${repo}/debs/${deb}" "${tmp}/debian-binary" "${tmp}/control.tar.gz" "${tmp}/data.tar.gz" >/dev/null
		rm -rf "${tmp}"
		sha="$(sha256sum "${repo}/debs/${deb}" | awk '{print $1}')"
		cat >>"${packages}" <<EOF
Package: ${pkg}
Architecture: ${ARCH:-arm64}
Version: ${version}
Filename: ./${deb}
SHA256: ${sha}

EOF
	done < <(bash -c 'source "$1"; first_party_download_specs' bash "${FETCH_DEBS}")
	gzip -c "${packages}" >"${repo}/Packages.gz"
	sha="$(sha256sum "${repo}/Packages.gz" | awk '{print $1}')"
	cat >"${repo}/InRelease" <<EOF
SHA256:
 ${sha} $(wc -c <"${repo}/Packages.gz") Packages.gz
EOF
}

run_first_party_curl() {
	local dest="$1" repo="$2"
	shift 2
	mkdir -p "${dest}"
	# Scenario-private .deb cache. These legs COUNT downloads and inject download
	# failures, so a cache shared with an earlier leg (or with a developer's real
	# build) would serve the very payload the leg is trying to fail — the fetch
	# would succeed and the assertion would be measuring ambient state.
	local cache_dir; cache_dir="$(dirname "${dest}")/.debcache"
	env \
		PATH="${FAKE_CURL_BIN}:${PATH}" \
		COUNT_DIR="${COUNT_DIR}" \
		FAKE_REPO_DIR="${repo}" \
		FETCH_DEBS_FIRST_PARTY_TRANSPORT=curl \
		APT_GPG_PUBLIC_B64="${KEY_B64}" \
		CERALIVE_DEBCACHE_DIR="${cache_dir}" \
		"$@" \
		bash -c 'source "$1"; fetch_first_party "$2"' bash "${FETCH_DEBS}" "${dest}"
}

# ==========================================================================
# 0. Bounds contract — the retry must be finite in three independent ways, and
#    the shipped defaults are part of the contract (3 attempts, 2s then 4s).
# ==========================================================================
defaults="$(bash -c 'source "$1"; printf "%s|%s|%s|%s" \
	"${FETCH_RETRY_ATTEMPTS}" "${FETCH_RETRY_BACKOFF}" \
	"${FETCH_RETRY_TIMEOUT}" "${FETCH_RETRY_DEADLINE}"' bash "${FETCH_DEBS}")"
[[ "${defaults}" == "3|2 4|600|1800" ]] \
	|| fail "bounds-defaults: expected '3|2 4|600|1800', got '${defaults}'"
pass "bounds: defaults are 3 attempts, 2s/4s backoff, 600s per-attempt cap, 1800s deadline"

# A hostile override must be sanitised, never trusted into an unbounded loop.
sanitised="$(FETCH_RETRY_ATTEMPTS=0 FETCH_RETRY_BACKOFF='' FETCH_RETRY_TIMEOUT=x FETCH_RETRY_DEADLINE=-1 \
	bash -c 'source "$1"; printf "%s|%s|%s|%s" \
		"${FETCH_RETRY_ATTEMPTS}" "${FETCH_RETRY_BACKOFF}" \
		"${FETCH_RETRY_TIMEOUT}" "${FETCH_RETRY_DEADLINE}"' bash "${FETCH_DEBS}")"
[[ "${sanitised}" == "3|2 4|600|1800" ]] \
	|| fail "bounds-sanitised: a malformed override survived: '${sanitised}'"
pass "bounds: malformed attempt/backoff/timeout/deadline overrides fall back to the finite defaults"

# ==========================================================================
# (b-exact) Status propagation — retry_transient must hand the caller the FINAL
# attempt's own exit status, never a flattened 1.
# ==========================================================================
FETCH_RETRY_ATTEMPTS=2 FETCH_RETRY_BACKOFF=0 \
	bash -c 'source "$1"; rc=0
		retry_transient probe bash -c "echo transient stall >&2; exit 42" || rc=$?
		printf "RETRY_RC=%s\n" "${rc}"' \
	bash "${FETCH_DEBS}" >"${RUN_DIR}/status.out" 2>&1
grep -q 'RETRY_RC=42' "${RUN_DIR}/status.out" \
	|| fail "status-propagation: retry_transient flattened the wrapped command's exit status" "${RUN_DIR}/status.out"
grep -q 'transient stall' "${RUN_DIR}/status.out" \
	|| fail "status-propagation: the wrapped command's own stderr was swallowed" "${RUN_DIR}/status.out"
pass "status: the final attempt's exit status and its stderr both reach the caller unmodified"

# ==========================================================================
# LEG (a) — a transient failure followed by success.
# ==========================================================================
reset_counts
if ! run_first_party_native "${RUN_DIR}/leg-a/debs" \
	FAKE_APT_FAIL_MODE=transient FAKE_APT_FAIL_TIMES=1 \
	>"${RUN_DIR}/leg-a.out" 2>&1; then
	fail "leg-a-transient-then-success" "${RUN_DIR}/leg-a.out"
fi
[[ "$(count_of update)" == "2" ]] \
	|| fail "leg-a: expected exactly 2 apt-get update attempts, got $(count_of update)" "${RUN_DIR}/leg-a.out"
grep -q 'attempt 1/3 failed (exit 100) — transient; retrying in 2s' "${RUN_DIR}/leg-a.out" \
	|| fail "leg-a: the retry decision was not logged with its attempt number and backoff" "${RUN_DIR}/leg-a.out"
grep -q 'succeeded on attempt 2/3' "${RUN_DIR}/leg-a.out" \
	|| fail "leg-a: the recovering attempt was not logged" "${RUN_DIR}/leg-a.out"
expected_debs="$(bash -c 'source "$1"; printf "%s" "${#FIRST_PARTY_APT_PKGS[@]}"' bash "${FETCH_DEBS}")"
staged="$(find "${RUN_DIR}/leg-a/debs" -maxdepth 1 -name '*.deb' | wc -l)"
[[ "${staged}" == "${expected_debs}" ]] \
	|| fail "leg-a: recovered run staged ${staged} .debs, expected ${expected_debs}"
pass "leg-a: a transient apt-get update failure is retried and the fetch completes (2 attempts logged)"

# The same must hold for the download half, not just the metadata refresh.
reset_counts
if ! run_first_party_native "${RUN_DIR}/leg-a-download/debs" \
	FAKE_APT_FAIL_MODE=transient FAKE_APT_DOWNLOAD_FAIL_TIMES=1 FETCH_RETRY_BACKOFF=0 \
	>"${RUN_DIR}/leg-a-download.out" 2>&1; then
	fail "leg-a-download-transient-then-success" "${RUN_DIR}/leg-a-download.out"
fi
[[ "$(count_of download)" == "2" ]] \
	|| fail "leg-a-download: expected exactly 2 apt-get download attempts, got $(count_of download)" "${RUN_DIR}/leg-a-download.out"
pass "leg-a: a transient apt-get download failure is retried too (2 attempts)"

# ==========================================================================
# LEG (b) — retries exhausted.
# ==========================================================================
reset_counts
leg_b_rc=0
run_first_party_native "${RUN_DIR}/leg-b/debs" \
	FAKE_APT_FAIL_MODE=transient FAKE_APT_FAIL_TIMES=99 FETCH_RETRY_BACKOFF=0 \
	>"${RUN_DIR}/leg-b.out" 2>&1 || leg_b_rc=$?
(( leg_b_rc != 0 )) || fail "leg-b: exhausted retries must fail the fetch" "${RUN_DIR}/leg-b.out"
[[ "$(count_of update)" == "3" ]] \
	|| fail "leg-b: expected exactly 3 attempts (FETCH_RETRY_ATTEMPTS), got $(count_of update)" "${RUN_DIR}/leg-b.out"
grep -q 'transient-failure retries exhausted after 3/3 attempt(s); last exit 100' "${RUN_DIR}/leg-b.out" \
	|| fail "leg-b: the exhaustion diagnostic did not name the attempt count and last exit status" "${RUN_DIR}/leg-b.out"
grep -q 'connection timed out' "${RUN_DIR}/leg-b.out" \
	|| fail "leg-b: apt-get's ORIGINAL diagnostic was swallowed by the retry wrapper" "${RUN_DIR}/leg-b.out"
pass "leg-b: exhausted retries fail loudly, bounded at 3 attempts, with apt-get's own diagnostic intact"

# The overall elapsed ceiling must be able to cut a run short of its attempt
# budget — the count bound alone is not the only bound.
reset_counts
leg_b_deadline_rc=0
run_first_party_native "${RUN_DIR}/leg-b-deadline/debs" \
	FAKE_APT_FAIL_MODE=transient FAKE_APT_FAIL_TIMES=99 \
	FETCH_RETRY_ATTEMPTS=9 FETCH_RETRY_BACKOFF=1 FETCH_RETRY_DEADLINE=1 \
	>"${RUN_DIR}/leg-b-deadline.out" 2>&1 || leg_b_deadline_rc=$?
(( leg_b_deadline_rc != 0 )) || fail "leg-b-deadline: must still fail" "${RUN_DIR}/leg-b-deadline.out"
grep -q 'retry deadline reached' "${RUN_DIR}/leg-b-deadline.out" \
	|| fail "leg-b-deadline: the elapsed ceiling never fired" "${RUN_DIR}/leg-b-deadline.out"
[[ "$(count_of update)" -lt 9 ]] \
	|| fail "leg-b-deadline: the deadline did not cut the run short of its 9-attempt budget"
pass "leg-b: the overall elapsed ceiling ends a run before its attempt budget is spent"

# ==========================================================================
# LEG (c) — verdicts are NEVER retried: exactly one attempt each.
# ==========================================================================
for mode in hash gpg notfound; do
	reset_counts
	rc=0
	run_first_party_native "${RUN_DIR}/leg-c-${mode}/debs" \
		FAKE_APT_FAIL_MODE="${mode}" FAKE_APT_FAIL_TIMES=99 FETCH_RETRY_BACKOFF=0 \
		>"${RUN_DIR}/leg-c-${mode}.out" 2>&1 || rc=$?
	(( rc != 0 )) || fail "leg-c-${mode}: must fail" "${RUN_DIR}/leg-c-${mode}.out"
	[[ "$(count_of update)" == "1" ]] \
		|| fail "leg-c-${mode}: a ${mode} VERDICT was retried — expected exactly 1 attempt, got $(count_of update)" \
			"${RUN_DIR}/leg-c-${mode}.out"
	grep -q 'NOT retrying' "${RUN_DIR}/leg-c-${mode}.out" \
		|| fail "leg-c-${mode}: the no-retry decision was not logged" "${RUN_DIR}/leg-c-${mode}.out"
	pass "leg-c: a ${mode} failure fails on the FIRST attempt and is never retried"
done

# A tampered .deb on the curl transport: the SHA-256 verdict sits outside every
# wrapper, so the package must be fetched exactly once and refused.
curl_repo="${RUN_DIR}/curl-repo"
prepare_fake_curl_repo "${curl_repo}"
corrupt_repo="${RUN_DIR}/corrupt-repo"
cp -a "${curl_repo}" "${corrupt_repo}"
tampered="$(find "${corrupt_repo}/debs" -type f -name '*.deb' | sort | head -1)"
printf 'tampered\n' >>"${tampered}"
tampered_base="$(basename "${tampered}")"

reset_counts
leg_c_sha_rc=0
run_first_party_curl "${RUN_DIR}/leg-c-sha/debs" "${corrupt_repo}" FETCH_JOBS=1 \
	>"${RUN_DIR}/leg-c-sha.out" 2>&1 || leg_c_sha_rc=$?
(( leg_c_sha_rc != 0 )) || fail "leg-c-sha: a SHA-256 mismatch must be fatal" "${RUN_DIR}/leg-c-sha.out"
grep -q 'checksum mismatch' "${RUN_DIR}/leg-c-sha.out" \
	|| fail "leg-c-sha: the original checksum diagnostic did not survive" "${RUN_DIR}/leg-c-sha.out"
sha_fetches="$(grep -c "/${tampered_base}\$" "${COUNT_DIR}/curl-urls" || true)"
[[ "${sha_fetches}" == "1" ]] \
	|| fail "leg-c-sha: the tampered .deb was fetched ${sha_fetches} times — a hash verdict must not be retried"
pass "leg-c: a SHA-256 mismatch is refused after exactly 1 download attempt"

# A half-supplied mTLS pair is a credential verdict: it must abort before any
# archive round trip happens at all.
reset_counts
leg_c_mtls_rc=0
run_first_party_native "${RUN_DIR}/leg-c-mtls/debs" \
	APT_CLIENT_CRT_B64="${CRT_B64}" \
	>"${RUN_DIR}/leg-c-mtls.out" 2>&1 || leg_c_mtls_rc=$?
(( leg_c_mtls_rc != 0 )) || fail "leg-c-mtls: a half-supplied mTLS pair must be fatal" "${RUN_DIR}/leg-c-mtls.out"
grep -q 'incomplete mTLS pair' "${RUN_DIR}/leg-c-mtls.out" \
	|| fail "leg-c-mtls: the original credential diagnostic did not survive" "${RUN_DIR}/leg-c-mtls.out"
[[ "$(count_of update)" == "0" && "$(count_of download)" == "0" ]] \
	|| fail "leg-c-mtls: a credential fatal reached the archive (update=$(count_of update) download=$(count_of download))"
pass "leg-c: a half-supplied mTLS credential aborts with zero archive round trips"

# ==========================================================================
# LEG (d) — a signal mid-fetch leaves no stray tmpfiles.
#
# The pre-fix code removed the mktemp'd Armbian metadata triple only on the
# SUCCESS path, so a Ctrl-C during the fetch leaked three files into $TMPDIR
# on every interrupted build. The fetch runs in its own process group so the
# signal reaches the stalled curl too, which is what a real Ctrl-C does.
# ==========================================================================
signal_home="${RUN_DIR}/signal-tmp"
signal_debs="${RUN_DIR}/signal/debs"
hang_marker="${RUN_DIR}/signal-scratch-snapshot"
mkdir -p "${signal_home}" "${signal_debs}"
reset_counts

set -m
env \
	PATH="${FAKE_CURL_BIN}:${PATH}" \
	TMPDIR="${signal_home}" \
	COUNT_DIR="${COUNT_DIR}" \
	FAKE_REPO_DIR="${curl_repo}" \
	FAKE_CURL_HANG_ON="/InRelease" \
	FAKE_CURL_HANG_MARKER="${hang_marker}" \
	ARMBIAN_APT_KEYRING="${RUN_DIR}/keyring.gpg" \
	bash -c 'source "$1"; _fetch_bsp_curl "$2" demo=1.0' bash "${FETCH_DEBS}" "${signal_debs}" \
	>"${RUN_DIR}/leg-d.out" 2>&1 &
signal_pid=$!
set +m

waited=0
while [[ ! -s "${hang_marker}" ]] && (( waited < 100 )); do
	sleep 0.1
	waited=$(( waited + 1 ))
done
[[ -s "${hang_marker}" ]] \
	|| fail "leg-d: the fetch never reached an in-flight download" "${RUN_DIR}/leg-d.out"
grep -q '^fetch-debs\.' "${hang_marker}" \
	|| fail "leg-d: no scratch dir existed at interrupt time — the leak assertion would be vacuous"

kill -TERM -- "-${signal_pid}" 2>/dev/null || kill -TERM "${signal_pid}" 2>/dev/null || true
signal_rc=0
wait "${signal_pid}" || signal_rc=$?
(( signal_rc != 0 )) || fail "leg-d: an interrupted fetch must not report success" "${RUN_DIR}/leg-d.out"

leaked="$(find "${signal_home}" -mindepth 1 -print)"
[[ -z "${leaked}" ]] \
	|| fail "leg-d: signal left stray tmpfiles behind:
${leaked}"
pass "leg-d: a signal mid-fetch removes the whole scratch dir (verified non-vacuous, exit ${signal_rc})"

# The same must hold for an ordinary failing exit, not just a signal.
fail_home="${RUN_DIR}/fail-tmp"
mkdir -p "${fail_home}"
TMPDIR="${fail_home}" PATH="${FAKE_BIN}:${PATH}" COUNT_DIR="${COUNT_DIR}" \
	bash -c 'source "$1"; fetch_scratch_init; die "synthetic fatal"' \
	bash "${FETCH_DEBS}" >"${RUN_DIR}/leg-d-die.out" 2>&1 && \
	fail "leg-d-die: die() must exit non-zero" "${RUN_DIR}/leg-d-die.out"
[[ -z "$(find "${fail_home}" -mindepth 1 -print)" ]] \
	|| fail "leg-d-die: a fatal exit leaked the scratch dir"
pass "leg-d: a die() exit removes the scratch dir too (success/failure/signal are symmetric)"

# ==========================================================================
# Structural guard — every curl on this path carries both transport bounds.
# `--retry` alone does not bound a connection that is accepted and then stalls,
# which is the exact hang this suite's timeouts exist to prevent.
# ==========================================================================
curl_invocations="$(cat "${FETCH_SOURCES[@]}" | grep -c 'curl -')"
(( curl_invocations >= 9 )) \
	|| fail "curl-bounds: only ${curl_invocations} curl invocation(s) found — the guard's pattern has rotted"
unbounded="$(grep -n 'curl -' "${FETCH_SOURCES[@]}" | grep -v 'CURL_TIMEOUT_OPTS' || true)"
[[ -z "${unbounded}" ]] \
	|| fail "curl-bounds: curl invocation(s) without CURL_TIMEOUT_OPTS:
${unbounded}"
grep -q -- '--connect-timeout "${CURL_CONNECT_TIMEOUT}" --max-time "${CURL_MAX_TIME}"' "${FETCH_SOURCES[@]}" \
	|| fail "curl-bounds: CURL_TIMEOUT_OPTS no longer carries --connect-timeout/--max-time"
curl_defaults="$(bash -c 'source "$1"; printf "%s|%s" "${CURL_CONNECT_TIMEOUT}" "${CURL_MAX_TIME}"' \
	bash "${FETCH_DEBS}")"
[[ "${curl_defaults}" == "10|300" ]] \
	|| fail "curl-bounds: expected defaults '10|300', got '${curl_defaults}'"
pass "curl-bounds: every curl carries --connect-timeout 10 --max-time 300"

printf '\nALL LEGS PASSED — fetch-debs retry + scratch-cleanup contract\n' | tee -a "${RESULTS_LOG}"
