#!/usr/bin/env bash
#
# fetch-debs-apt-sandbox.test.sh — the build-time first-party fetch must let apt
# keep its sandbox.
#
# apt drops its acquire methods to `_apt` whenever it is invoked as root. The
# fetcher used to answer that with an `APT::Sandbox::User=root` override, which
# fixes no permission — it turns apt's sandbox off for the whole fetch. The
# shipped answer is privilege-aware: as root, hand `_apt` the mTLS client key and
# a traversable/writable state+download tree; unprivileged, emit nothing at all.
#
# Two halves:
#   Part A  static contract on lib/fetch-debs.sh (no override, both branches
#           present, the download dir handed over before apt runs).
#   Part B  the SHIPPED fetch_first_party driven by a REAL apt-get against a
#           real GPG-signed fixture repository inside a container, once at real
#           UID 0 and once unprivileged. The root leg is the critical one and is
#           NEVER skipped: it proves the acquisition stayed sandboxed by the
#           absence of apt's own "Download is performed unsandboxed as root"
#           fallback warning, and a control replay proves that assertion has
#           teeth on this very fixture.

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${TESTS_DIR}/.." && pwd)"
REPO_ROOT="${PIPELINE_DIR}"
FETCH_DEBS="${PIPELINE_DIR}/lib/fetch-debs.sh"
# The fetch path is the entry point PLUS its lib/fetch/ family modules. Part A
# must scan all of them: the sandbox helpers and fetch_first_party now live in
# lib/fetch/firstparty.sh, and a static contract that keeps looking only at the
# entry would report PASS while asserting nothing at all — which on THIS suite
# would mean the sandbox-override check silently stops checking.
FETCH_SOURCES=("${FETCH_DEBS}" "${PIPELINE_DIR}"/lib/fetch/*.sh)
HARNESS="${TESTS_DIR}/fixtures/apt-sandbox/in-container.sh"
HARNESS_IN_CONTAINER="/repo${HARNESS#"${REPO_ROOT}"}"
ARTIFACT_DIR="${REPO_ROOT}/test-results/flows/apt"
RESULTS_LOG="${ARTIFACT_DIR}/fetch-debs-apt-sandbox.log"
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fetch-debs-apt-sandbox.XXXXXX")"
# The container must run the suite the IMAGE targets, not a frozen one. Part B's
# whole claim is about apt's own sandbox behaviour — whether `_apt` exists, and
# whether apt drops to it and then emits its unsandboxed-as-root fallback — and
# that is apt's behaviour, which moves with the suite. Proving it on a retired
# release would leave the shipped one unproven while the suite stayed green.
# shellcheck source=../lib/shared/target-release-lib.sh
source "${PIPELINE_DIR}/lib/shared/target-release-lib.sh"
target_release_load
CONTAINER_IMAGE="${CERALIVE_APT_SANDBOX_TEST_IMAGE:-debian:${RELEASE}-slim}"
UNSANDBOXED_WARNING='Download is performed unsandboxed as root'

mkdir -p "${ARTIFACT_DIR}"
: >"${RESULTS_LOG}"

FAILED=0
pass() { printf 'PASS %s\n' "$1" | tee -a "${RESULTS_LOG}"; }
fail() {
	printf 'FAIL %s\n' "$1" | tee -a "${RESULTS_LOG}"
	FAILED=1
}
abort() {
	printf 'FAIL %s\n' "$1" | tee -a "${RESULTS_LOG}"
	exit 1
}

cleanup() {
	# The container legs' apt transcripts live only in RUN_DIR; keep them when
	# asked, or a failing root leg leaves nothing to read.
	if [[ "${CERALIVE_APT_SANDBOX_KEEP_RUNDIR:-0}" == "1" ]]; then
		printf 'kept run dir: %s\n' "${RUN_DIR}" >&2
		return
	fi
	rm -rf "${RUN_DIR}"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Part A — static contract
# ---------------------------------------------------------------------------

if [[ "$(cat "${FETCH_SOURCES[@]}" | grep -c 'Sandbox::User')" -eq 0 ]]; then
	pass "no apt sandbox-user override anywhere on the fetch path (all modules, comments included)"
else
	fail "the fetch path still spells the apt sandbox-user override: $(grep -n 'Sandbox::User' "${FETCH_SOURCES[@]}")"
fi

if grep -q '^apt_sandbox_active()' "${FETCH_SOURCES[@]}" \
	&& grep -q 'EUID == 0' "${FETCH_SOURCES[@]}" \
	&& grep -q '^apt_sandbox_user_exists()' "${FETCH_SOURCES[@]}"; then
	pass "the sandbox gate is privilege-aware (root AND the sandbox user must exist)"
else
	fail "the fetch path has no privilege-aware apt sandbox gate"
fi

if grep -q 'chown "${APT_SANDBOX_USER}:root" "${certs_dir}/client.key"' "${FETCH_SOURCES[@]}" \
	&& grep -q 'chmod 400 "${certs_dir}/client.key"' "${FETCH_SOURCES[@]}"; then
	pass "the root branch hands the mTLS client key to the sandbox user at mode 0400"
else
	fail "the root branch does not chown/chmod the mTLS client key for the sandbox user"
fi

if grep -q 'is not readable by the invoking user' "${FETCH_SOURCES[@]}"; then
	pass "the unprivileged branch asserts the client key is readable instead of overriding apt"
else
	fail "the unprivileged branch does not assert client-key readability"
fi

if grep -q 'chmod 0755 "${dir}"' "${FETCH_SOURCES[@]}" \
	&& grep -q 'apt_sandbox_make_traversable "$(dirname "${debs}")" "${debs}" "${apt_state}"' "${FETCH_SOURCES[@]}"; then
	pass "the isolated apt state tree is given explicit traversable modes, not the ambient umask"
else
	fail "the isolated apt state tree is not explicitly made traversable"
fi

# The mktemp -> handover -> download ORDERING below is a within-file property, so
# resolve the one module that carries the download transaction and assert against
# it. Requiring all three anchors in the SAME file is itself part of the contract:
# split across two files the ordering would be unobservable, not merely unchecked.
DOWNLOAD_TXN_FILE=""
for candidate in "${FETCH_SOURCES[@]}"; do
	if grep -q 'apt_sandbox_own_download_dir "${tmpd}"' "${candidate}"; then
		DOWNLOAD_TXN_FILE="${candidate}"
		break
	fi
done
if [[ -n "${DOWNLOAD_TXN_FILE}" ]]; then
	pass "the first-party download transaction lives in one module ($(basename "${DOWNLOAD_TXN_FILE}"))"
else
	abort "no module on the fetch path performs the sandbox download-dir handover"
fi

# awk/index, not grep: a literal match with no regex escaping, and an absent
# anchor yields "" instead of tripping `set -o pipefail` before it can be reported.
line_of() {
	awk -v pat="$1" 'index($0, pat) { print NR; exit }' "${DOWNLOAD_TXN_FILE}"
}
mktemp_line="$(line_of 'mktemp -d "${debs}/.fetch-firstparty-XXXXXX"')"
own_line="$(line_of 'apt_sandbox_own_download_dir "${tmpd}"')"
download_line="$(line_of 'apt-get "${apt_opts[@]}" download')"
if [[ -n "${mktemp_line}" && -n "${own_line}" && -n "${download_line}" ]] \
	&& (( mktemp_line < own_line && own_line < download_line )); then
	pass "the 0700 mktemp download dir is handed to the sandbox user before apt-get download runs"
else
	fail "the download dir is not handed to the sandbox user between mktemp and apt-get download (mktemp=${mktemp_line:-none} own=${own_line:-none} download=${download_line:-none})"
fi

if grep -q 'chown "${APT_SANDBOX_USER}:root" "${dir}"' "${FETCH_SOURCES[@]}"; then
	pass "the download dir is CHOWNED to the sandbox user (traversal alone is not enough for a write)"
else
	fail "the download dir is not chowned to the sandbox user"
fi

# ---------------------------------------------------------------------------
# Part B — real apt, real UID 0, in a container. Never skipped.
# ---------------------------------------------------------------------------

RUNTIME=""
for candidate in docker podman; do
	if command -v "${candidate}" >/dev/null 2>&1; then
		RUNTIME="${candidate}"
		break
	fi
done
[[ -n "${RUNTIME}" ]] \
	|| abort "no container runtime (docker/podman) — the real-UID-0 apt sandbox leg cannot be skipped"
[[ -x "${HARNESS}" ]] || abort "container harness missing or not executable: ${HARNESS}"

if ! "${RUNTIME}" image inspect "${CONTAINER_IMAGE}" >/dev/null 2>&1; then
	"${RUNTIME}" pull "${CONTAINER_IMAGE}" >/dev/null \
		|| abort "cannot obtain container image ${CONTAINER_IMAGE} for the real-UID-0 apt sandbox leg"
fi

for tool in gpg ar tar gzip; do
	command -v "${tool}" >/dev/null 2>&1 \
		|| abort "host tool '${tool}' is required to build the signed apt fixture repository"
done

# --- signed fixture repository (flat, Suites: ./ — the apt-worker layout) -----
FIXTURE="${RUN_DIR}/fixture"
POOL="${FIXTURE}/repo/dists/stable/binary-arm64"
mkdir -p "${POOL}" "${RUN_DIR}/gnupg" "${RUN_DIR}/work"
chmod 0755 "${RUN_DIR}" "${FIXTURE}" "${RUN_DIR}/work"
chmod 0700 "${RUN_DIR}/gnupg"

build_fixture_deb() {
	local pkg="$1" version="$2" tmp
	tmp="$(mktemp -d "${RUN_DIR}/deb.XXXXXX")"
	mkdir -p "${tmp}/DEBIAN"
	printf 'Package: %s\nVersion: %s\nArchitecture: arm64\nMaintainer: Fixture <fixture@example.invalid>\nDescription: apt sandbox fixture\n' \
		"${pkg}" "${version}" >"${tmp}/DEBIAN/control"
	printf '2.0\n' >"${tmp}/debian-binary"
	tar -czf "${tmp}/control.tar.gz" -C "${tmp}/DEBIAN" ./control
	tar -czf "${tmp}/data.tar.gz" --files-from /dev/null
	ar r "${POOL}/${pkg}_${version}_arm64.deb" \
		"${tmp}/debian-binary" "${tmp}/control.tar.gz" "${tmp}/data.tar.gz" 2>/dev/null
	rm -rf "${tmp}"
}

EXPECTED_COUNT=0
while IFS= read -r spec; do
	build_fixture_deb "${spec%%=*}" "${spec#*=}"
	EXPECTED_COUNT=$(( EXPECTED_COUNT + 1 ))
done < <(bash -c 'source "$1"; first_party_download_specs' bash "${FETCH_DEBS}")
(( EXPECTED_COUNT > 0 )) || abort "the shipped first-party spec list resolved to zero packages"

(
	cd "${POOL}"
	: >Packages
	for deb in *.deb; do
		{
			ar p "${deb}" control.tar.gz | tar -xzO ./control | sed '/^$/d'
			printf 'Filename: ./%s\nSize: %s\nSHA256: %s\n\n' \
				"${deb}" "$(stat -c%s "${deb}")" "$(sha256sum "${deb}" | awk '{print $1}')"
		} >>Packages
	done
	gzip -9kf Packages
	{
		printf 'Origin: ceralive-fixture\nLabel: ceralive-fixture\nArchitectures: arm64\nDate: %s\n' \
			"$(LC_ALL=C date -u -d '-1 hour' '+%a, %d %b %Y %H:%M:%S UTC')"
		printf 'SHA256:\n'
		for f in Packages Packages.gz; do
			printf ' %s %s %s\n' "$(sha256sum "${f}" | awk '{print $1}')" "$(stat -c%s "${f}")" "${f}"
		done
	} >Release
)

export GNUPGHOME="${RUN_DIR}/gnupg"
gpg --batch --quiet --passphrase '' --pinentry-mode loopback \
	--quick-generate-key 'CeraLive Fixture <fixture@example.invalid>' default default never >/dev/null 2>&1 \
	|| abort "could not generate the fixture signing key"
FIXTURE_FPR="$(gpg --batch --with-colons --list-keys 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')"
gpg --batch --yes --quiet --passphrase '' --pinentry-mode loopback \
	--clearsign -o "${POOL}/InRelease" "${POOL}/Release" 2>/dev/null
gpg --batch --quiet --export "${FIXTURE_FPR}" 2>/dev/null >"${FIXTURE}/keyring.gpg"
chmod -R a+rX "${FIXTURE}"

# Inputs go in and evidence comes out over `<runtime> cp`, never a bind mount:
# a bind mount silently constrains WHERE this suite may run (Docker Desktop
# refuses to share an arbitrary $TMPDIR), and $TMPDIR is exactly what the
# documented `TMPDIR=/tmp ./run-tests` invocation moves around.
CTX="${RUN_DIR}/ctx"
mkdir -p "${CTX}/repo/tests/fixtures"
cp -a "${PIPELINE_DIR}/lib" "${PIPELINE_DIR}/manifests" "${CTX}/repo/"
cp -a "${TESTS_DIR}/fixtures/apt-sandbox" "${CTX}/repo/tests/fixtures/"
cp -a "${REPO_ROOT}/versions.yaml" "${CTX}/repo/"

run_leg() {
	local leg="$1" cid rc=0
	cid="$("${RUNTIME}" create --network=none "${CONTAINER_IMAGE}" \
		"${HARNESS_IN_CONTAINER}" "${leg}" "$(id -u):$(id -g)")"
	"${RUNTIME}" cp "${CTX}/repo" "${cid}:/repo" >/dev/null
	"${RUNTIME}" cp "${FIXTURE}" "${cid}:/fx" >/dev/null
	"${RUNTIME}" start -a "${cid}" || rc=$?
	"${RUNTIME}" cp "${cid}:/work/${leg}" "${RUN_DIR}/work/" >/dev/null || rc=9
	"${RUNTIME}" rm -f "${cid}" >/dev/null
	return "${rc}"
}

assert_common_leg() {
	local leg="$1" out="${RUN_DIR}/work/$1"
	local rc staged

	rc="$(cat "${out}/rc")"
	if [[ "${rc}" == "0" ]]; then
		pass "${leg} leg: the shipped fetch_first_party completed against a real signed apt repo"
	else
		fail "${leg} leg: fetch_first_party exited ${rc}"
		sed -n '1,80p' "${out}/fetch.out" >&2
	fi

	staged="$(wc -l <"${out}/staged.txt")"
	if [[ "${staged}" -eq "${EXPECTED_COUNT}" ]]; then
		pass "${leg} leg: staged exactly ${EXPECTED_COUNT} first-party .deb(s)"
	else
		fail "${leg} leg: staged ${staged} .deb(s), expected ${EXPECTED_COUNT}"
	fi

	if awk '$2 != "644" {exit 1}' "${out}/staged.txt"; then
		pass "${leg} leg: every staged .deb is mode 0644"
	else
		fail "${leg} leg: a staged .deb is not mode 0644: $(cat "${out}/staged.txt")"
	fi

	if grep -q 'Sandbox::User' "${out}/apt-argv.log"; then
		fail "${leg} leg: the emitted apt argv carries a sandbox-user override: $(grep -m1 'Sandbox::User' "${out}/apt-argv.log")"
	else
		pass "${leg} leg: no sandbox-user override reached apt (argv recorded from the real invocation)"
	fi
}

for leg in root rootless; do
	if ! run_leg "${leg}" >"${RUN_DIR}/${leg}.container.out" 2>&1; then
		cat "${RUN_DIR}/${leg}.container.out" >&2
		abort "${leg} leg: the container harness itself failed"
	fi
done

root_out="${RUN_DIR}/work/root"
rootless_out="${RUN_DIR}/work/rootless"

if [[ "$(cat "${root_out}/uid")" == "0" ]]; then
	pass "root leg ran at REAL uid 0 (id -u reported 0 inside the container)"
else
	abort "root leg did not run at uid 0 (got $(cat "${root_out}/uid")) — a fakeroot-shaped run proves nothing"
fi

if [[ "$(cat "${rootless_out}/uid")" != "0" ]]; then
	pass "rootless leg ran unprivileged (uid $(cat "${rootless_out}/uid"))"
else
	abort "rootless leg ran as root"
fi

assert_common_leg root
assert_common_leg rootless

if grep -qF "${UNSANDBOXED_WARNING}" "${root_out}/fetch.out"; then
	fail "root leg: apt fell back to an UNSANDBOXED download: $(grep -m1 -F "${UNSANDBOXED_WARNING}" "${root_out}/fetch.out")"
else
	pass "root leg: apt kept its sandbox — no '${UNSANDBOXED_WARNING}' fallback in the acquisition output"
fi

if grep -qiE 'unsandboxed|drop privileges|No sandbox user' "${root_out}/fetch.out"; then
	fail "root leg: apt reported a sandbox degradation: $(grep -m1 -iE 'unsandboxed|drop privileges|No sandbox user' "${root_out}/fetch.out")"
else
	pass "root leg: apt reported no sandbox degradation of any kind"
fi

if grep -qF "${UNSANDBOXED_WARNING}" "${root_out}/control.out"; then
	pass "root leg non-vacuity: the same acquisition into a plain 0700 mktemp dir DOES warn"
else
	fail "root leg non-vacuity: the pre-fix control replay did not warn — the assertion above is vacuous on this fixture"
	sed -n '1,40p' "${root_out}/control.out" >&2
fi

if [[ "$(cat "${root_out}/client-key.stat")" == "_apt 400" ]]; then
	pass "root leg: the mTLS client key is _apt-owned, mode 0400"
else
	fail "root leg: client key is '$(cat "${root_out}/client-key.stat")', expected '_apt 400'"
fi

if [[ "$(awk '{print $2}' "${rootless_out}/client-key.stat")" == "600" ]] \
	&& [[ "$(awk '{print $1}' "${rootless_out}/client-key.stat")" != "_apt" ]]; then
	pass "rootless leg: the client key stays the invoking user's, mode 0600 (no ownership handover)"
else
	fail "rootless leg: client key is '$(cat "${rootless_out}/client-key.stat")', expected the invoking user at mode 600"
fi

if grep -q 'no override emitted' "${rootless_out}/fetch.out"; then
	pass "rootless leg: the fetcher recorded that it emitted no apt sandbox override"
else
	fail "rootless leg: the unprivileged branch did not run"
fi

exit "${FAILED}"
