#!/usr/bin/env bash

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2="$(cd "${TESTS_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${V2}/.." && pwd)"
FETCH_DEBS="${V2}/lib/fetch-debs.sh"
ARTIFACT_DIR="${REPO_ROOT}/test-results/flows/apt"
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fetch-debs-apt-chain.XXXXXX")"
FAKE_BIN="${RUN_DIR}/bin"
FAKE_CURL_BIN="${RUN_DIR}/curl-bin"
FAKE_APT_LOG="${RUN_DIR}/apt-get.log"
RESULTS_LOG="${ARTIFACT_DIR}/fetch-debs-apt-chain.log"

cleanup() {
	rm -rf "${RUN_DIR}"
}
trap cleanup EXIT

mkdir -p "${FAKE_BIN}" "${FAKE_CURL_BIN}" "${ARTIFACT_DIR}"

cat >"${FAKE_BIN}/apt-get" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

printf 'apt-get %q' "$1" >>"${FAKE_APT_LOG}"
shift || true
for arg in "$@"; do
	printf ' %q' "${arg}" >>"${FAKE_APT_LOG}"
done
printf '\n' >>"${FAKE_APT_LOG}"

command_name=""
for arg in "$@"; do
	case "${arg}" in
		update|download)
			command_name="${arg}"
			break
			;;
	esac
done

if [[ "${command_name}" == "update" && "${FAKE_APT_MODE:-ok}" == "bad-update" ]]; then
	printf 'E: test metadata signature mismatch\n' >&2
	exit 100
fi

if [[ "${command_name}" == "download" ]]; then
	seen_download=0
	for arg in "$@"; do
		if [[ "${seen_download}" -eq 0 ]]; then
			[[ "${arg}" == "download" ]] && seen_download=1
			continue
		fi
		pkg="${arg%%=*}"
		version="${arg#*=}"
		if [[ "${FAKE_APT_MODE:-ok}" == missing-one && "${pkg}" == srtla-send-rs ]]; then
			continue
		fi
		tmp="$(mktemp -d)"
		mkdir -p "${tmp}/DEBIAN"
		printf 'Package: %s\nVersion: %s\nArchitecture: %s\nMaintainer: Test <test@example.invalid>\nDescription: fixture\n' \
			"${pkg}" "${version}" "${ARCH:-arm64}" >"${tmp}/DEBIAN/control"
		printf '2.0\n' >"${tmp}/debian-binary"
		tar -czf "${tmp}/control.tar.gz" -C "${tmp}/DEBIAN" ./control
		tar -czf "${tmp}/data.tar.gz" --files-from /dev/null
		ar r "${pkg}_${version}_${ARCH:-arm64}.deb" "${tmp}/debian-binary" "${tmp}/control.tar.gz" "${tmp}/data.tar.gz" >/dev/null
		chmod 0600 "${pkg}_${version}_${ARCH:-arm64}.deb"
		if [[ "${FAKE_APT_MODE:-ok}" == duplicate-one && "${pkg}" == cerastream ]]; then
			cp "${pkg}_${version}_${ARCH:-arm64}.deb" "${pkg}_${version}_duplicate_${ARCH:-arm64}.deb"
		fi
		rm -rf "${tmp}"
	done
fi
SH
chmod 755 "${FAKE_BIN}/apt-get"

cat >"${FAKE_CURL_BIN}/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

out=""
url=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		-o)
			out="$2"
			shift 2
			;;
		--cert|--key|--retry)
			shift 2
			;;
		-*)
			shift
			;;
		*)
			url="$1"
			shift
			;;
	esac
done

[[ -n "${out}" && -n "${url}" ]] || exit 2
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
[[ "${FAKE_GPGV_MODE:-ok}" == ok ]] || exit 1
out=""
inrelease=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		--status-fd|--keyring)
			shift 2
			;;
		--output)
			out="$2"
			shift 2
			;;
		-*)
			shift
			;;
		*)
			inrelease="$1"
			shift
			;;
	esac
done
[[ -n "${out}" && -n "${inrelease}" ]] || exit 2
cp "${inrelease}" "${out}"
SH
chmod 755 "${FAKE_CURL_BIN}/gpgv"

valid_b64() {
	printf '%s' "$1" | base64 -w0
}

run_fetch_first_party() {
	local dest="$1"
	shift
	mkdir -p "${dest}"
	env \
		PATH="${FAKE_BIN}:${PATH}" \
		FAKE_APT_LOG="${FAKE_APT_LOG}" \
		"$@" \
		bash -c 'source "$1"; fetch_first_party "$2"' bash "${FETCH_DEBS}" "${dest}"
	}

prepare_fake_curl_repo() {
	local repo="$1"
	local packages="${repo}/Packages"
	mkdir -p "${repo}/debs"
	: >"${packages}"

	local spec pkg version deb sha
	while IFS= read -r spec; do
		pkg="${spec%%=*}"
		if [[ "${spec}" == *=* ]]; then
			version="${spec#*=}"
			version="${version%\*}"
		else
			version="1.0"
		fi
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

run_fetch_first_party_curl() {
	local dest="$1" repo="$2"
	shift 2
	mkdir -p "${dest}"
	env \
		PATH="${FAKE_CURL_BIN}:${PATH}" \
		FAKE_REPO_DIR="${repo}" \
		FETCH_DEBS_FIRST_PARTY_TRANSPORT=curl \
		"$@" \
		bash -c 'source "$1"; fetch_first_party "$2"' bash "${FETCH_DEBS}" "${dest}"
}

expect_success() {
	local name="$1"
	shift
	local dest="${RUN_DIR}/${name}"
	local output="${RUN_DIR}/${name}.out"
	if ! run_fetch_first_party "${dest}/debs" "$@" >"${output}" 2>&1; then
		printf 'FAIL %s\n' "${name}" | tee -a "${RESULTS_LOG}"
		cat "${output}" >&2
		exit 1
	fi
	printf 'PASS %s\n' "${name}" | tee -a "${RESULTS_LOG}"
}

expect_failure() {
	local name="$1" needle="$2"
	shift 2
	local dest="${RUN_DIR}/${name}"
	local output="${RUN_DIR}/${name}.out"
	if run_fetch_first_party "${dest}/debs" "$@" >"${output}" 2>&1; then
		printf 'FAIL %s: expected non-zero exit\n' "${name}" | tee -a "${RESULTS_LOG}"
		exit 1
	fi
	if ! grep -q "${needle}" "${output}"; then
		printf 'FAIL %s: output missing %s\n' "${name}" "${needle}" | tee -a "${RESULTS_LOG}"
		cat "${output}" >&2
		exit 1
	fi
	printf 'PASS %s\n' "${name}" | tee -a "${RESULTS_LOG}"
}

: >"${RESULTS_LOG}"
: >"${FAKE_APT_LOG}"

KEY_B64="$(valid_b64 'test public keyring')"
CRT_B64="$(valid_b64 'test client certificate')"
CLIENT_KEY_B64="$(valid_b64 'test client private key')"

expect_success \
	"valid-gpg-and-mtls-stages-first-party-debs" \
	APT_GPG_PUBLIC_B64="${KEY_B64}" \
	APT_CLIENT_CRT_B64="${CRT_B64}" \
	APT_CLIENT_KEY_B64="${CLIENT_KEY_B64}"

staged_count="$(find "${RUN_DIR}/valid-gpg-and-mtls-stages-first-party-debs/debs" -maxdepth 1 -name '*.deb' | wc -l)"
if [[ "${staged_count}" -ne 5 ]]; then
	printf 'FAIL valid-gpg-and-mtls-stages-first-party-debs: staged %s debs, expected 5\n' "${staged_count}" | tee -a "${RESULTS_LOG}"
	exit 1
fi
if find "${RUN_DIR}/valid-gpg-and-mtls-stages-first-party-debs/debs" -maxdepth 1 -name '*.deb' ! -perm 0644 -print -quit | grep -q .; then
	printf 'FAIL valid-gpg-and-mtls-stages-first-party-debs: package mode is not 0644\n' | tee -a "${RESULTS_LOG}"
	exit 1
fi
printf 'PASS valid-gpg-and-mtls-stages-first-party-debs staged exactly 5 debs\n' | tee -a "${RESULTS_LOG}"

curl_repo="${RUN_DIR}/curl-repo"
prepare_fake_curl_repo "${curl_repo}"
curl_dest="${RUN_DIR}/valid-curl-fallback/debs"
if ! run_fetch_first_party_curl "${curl_dest}" "${curl_repo}" \
	APT_GPG_PUBLIC_B64="${KEY_B64}" \
	APT_CLIENT_CRT_B64="${CRT_B64}" \
	APT_CLIENT_KEY_B64="${CLIENT_KEY_B64}" >"${RUN_DIR}/valid-curl-fallback.out" 2>&1; then
	printf 'FAIL valid-curl-fallback-stages-first-party-debs\n' | tee -a "${RESULTS_LOG}"
	cat "${RUN_DIR}/valid-curl-fallback.out" >&2
	exit 1
fi
curl_staged_count="$(find "${curl_dest}" -maxdepth 1 -name '*.deb' | wc -l)"
if [[ "${curl_staged_count}" -ne 5 ]]; then
	printf 'FAIL valid-curl-fallback-stages-first-party-debs: staged %s debs, expected 5\n' "${curl_staged_count}" | tee -a "${RESULTS_LOG}"
	exit 1
fi
if find "${curl_dest}" -maxdepth 1 -name '*.deb' ! -perm 0644 -print -quit | grep -q .; then
	printf 'FAIL valid-curl-fallback-stages-first-party-debs: package mode is not 0644\n' | tee -a "${RESULTS_LOG}"
	exit 1
fi
printf 'PASS valid-curl-fallback-stages-first-party-debs\n' | tee -a "${RESULTS_LOG}"

if run_fetch_first_party_curl "${RUN_DIR}/bad-signature/debs" "${curl_repo}" \
	FAKE_GPGV_MODE=bad APT_GPG_PUBLIC_B64="${KEY_B64}" >"${RUN_DIR}/bad-signature.out" 2>&1; then
	printf 'FAIL bad-curl-signature-is-fatal\n' | tee -a "${RESULTS_LOG}"
	exit 1
fi
grep -q 'signature verification failed' "${RUN_DIR}/bad-signature.out"
printf 'PASS bad-curl-signature-is-fatal\n' | tee -a "${RESULTS_LOG}"

corrupt_repo="${RUN_DIR}/corrupt-repo"
cp -a "${curl_repo}" "${corrupt_repo}"
printf 'tampered\n' >>"$(find "${corrupt_repo}/debs" -type f -name '*.deb' | head -1)"
if run_fetch_first_party_curl "${RUN_DIR}/bad-package-hash/debs" "${corrupt_repo}" \
	APT_GPG_PUBLIC_B64="${KEY_B64}" >"${RUN_DIR}/bad-package-hash.out" 2>&1; then
	printf 'FAIL bad-curl-package-hash-is-fatal\n' | tee -a "${RESULTS_LOG}"
	exit 1
fi
grep -q 'checksum mismatch' "${RUN_DIR}/bad-package-hash.out"
printf 'PASS bad-curl-package-hash-is-fatal\n' | tee -a "${RESULTS_LOG}"

expect_failure \
	"half-mtls-pair-is-fatal" \
	"incomplete mTLS pair" \
	APT_GPG_PUBLIC_B64="${KEY_B64}" \
	APT_CLIENT_CRT_B64="${CRT_B64}"

expect_failure \
	"bad-gpg-key-material-is-fatal" \
	"base64" \
	APT_GPG_PUBLIC_B64="@@@@"

expect_failure \
	"bad-apt-metadata-update-is-fatal" \
	"metadata signature mismatch" \
	FAKE_APT_MODE="bad-update" \
	APT_GPG_PUBLIC_B64="${KEY_B64}" \
	APT_CLIENT_CRT_B64="${CRT_B64}" \
	APT_CLIENT_KEY_B64="${CLIENT_KEY_B64}"

expect_failure \
	"missing-first-party-package-is-fatal" \
	"expected exactly" \
	FAKE_APT_MODE="missing-one" \
	APT_GPG_PUBLIC_B64="${KEY_B64}"

expect_failure \
	"duplicate-first-party-package-is-fatal" \
	"expected exactly" \
	FAKE_APT_MODE="duplicate-one" \
	APT_GPG_PUBLIC_B64="${KEY_B64}"

expected_download=" download"
while IFS= read -r spec; do
	printf -v quoted_spec '%q' "${spec}"
	expected_download+=" ${quoted_spec}"
done < <(bash -c 'source "$1"; first_party_download_specs' bash "${FETCH_DEBS}")

if ! grep -q ' update$' "${FAKE_APT_LOG}" || ! grep -Fq "${expected_download}" "${FAKE_APT_LOG}"; then
	printf 'FAIL apt-get fake did not observe expected update/download contract\n' | tee -a "${RESULTS_LOG}"
	cat "${FAKE_APT_LOG}" >&2
	exit 1
fi
printf 'PASS apt-get update/download contract observed\n' | tee -a "${RESULTS_LOG}"
