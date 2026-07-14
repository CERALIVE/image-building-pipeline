#!/usr/bin/env bash

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2="$(cd "${TESTS_DIR}/.." && pwd)"
HELPER="${STAGING_HELPER:-${V2}/lib/stage-mkosi-package.sh}"
ORCHESTRATOR="${V2}/lib/orchestrate.sh"
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mkosi-package-staging.XXXXXX")"

cleanup() {
	rm -rf "${RUN_DIR}"
}
trap cleanup EXIT

[[ -x "${HELPER}" ]] || {
	printf 'FAIL mkosi package staging helper is missing: %s\n' "${HELPER}" >&2
	exit 1
}

chmod 755 "${RUN_DIR}"
install -d -m 0700 "${RUN_DIR}/private-download"
printf 'authenticated package payload\n' >"${RUN_DIR}/private-download/demo_1.0_arm64.deb"
chmod 600 "${RUN_DIR}/private-download/demo_1.0_arm64.deb"

unprivileged_index() {
	local dir="$1"
	if [[ "$(id -u)" == "0" ]]; then
		runuser -u nobody -- find "${dir}" -maxdepth 1 -type f -name '*.deb' -printf '%f\n' 2>/dev/null
	elif sudo -n -u nobody true 2>/dev/null; then
		sudo -n -u nobody -- find "${dir}" -maxdepth 1 -type f -name '*.deb' -printf '%f\n' 2>/dev/null
	else
		printf 'FAIL unprivileged package-index probe requires root or passwordless sudo\n' >&2
		return 1
	fi
}

for class in bsp firstparty; do
	install -d -m 0700 "${RUN_DIR}/blocked/${class}"
	install -m 0644 "${RUN_DIR}/private-download/demo_1.0_arm64.deb" \
		"${RUN_DIR}/blocked/${class}/demo_1.0_arm64.deb"
	[[ -z "$(unprivileged_index "${RUN_DIR}/blocked/${class}")" ]] || {
		printf 'FAIL mode-0700 %s directory unexpectedly exposed a package index\n' "${class}" >&2
		exit 1
	}
done
printf 'PASS mode-0700 BSP and first-party directories yield empty unprivileged indexes\n'

umask 077
"${HELPER}" "${RUN_DIR}/private-download/demo_1.0_arm64.deb" "${RUN_DIR}/bsp"
"${HELPER}" "${RUN_DIR}/private-download/demo_1.0_arm64.deb" "${RUN_DIR}/firstparty"

for dir in "${RUN_DIR}/bsp" "${RUN_DIR}/firstparty"; do
	[[ "$(stat -c '%a' "${dir}")" == "755" ]] || {
		printf 'FAIL mkosi consumer directory is not traversable: %s mode=%s\n' \
			"${dir}" "$(stat -c '%a' "${dir}")" >&2
		exit 1
	}
	[[ "$(stat -c '%a' "${dir}/demo_1.0_arm64.deb")" == "644" ]] || {
		printf 'FAIL mkosi consumer archive is not readable: %s mode=%s\n' \
			"${dir}/demo_1.0_arm64.deb" \
			"$(stat -c '%a' "${dir}/demo_1.0_arm64.deb")" >&2
		exit 1
	}
	[[ "$(unprivileged_index "${dir}")" == "demo_1.0_arm64.deb" ]] || {
		printf 'FAIL unprivileged package index is empty: %s\n' "${dir}" >&2
		exit 1
	}
done

[[ "$(stat -c '%a' "${RUN_DIR}/private-download")" == "700" ]] || {
	printf 'FAIL private download directory permissions were widened\n' >&2
	exit 1
}
[[ "$(stat -c '%a' "${RUN_DIR}/private-download/demo_1.0_arm64.deb")" == "600" ]] || {
	printf 'FAIL private download archive permissions were widened\n' >&2
	exit 1
}

grep -Fq "MKOSI_PACKAGE_STAGING_SH=\"\${HERE}/stage-mkosi-package.sh\"" "${ORCHESTRATOR}"
grep -Fq "\"\${MKOSI_PACKAGE_STAGING_SH}\" \"\${deb}\" \"\${bsp_dir}\"" "${ORCHESTRATOR}"
grep -Fq "\"\${MKOSI_PACKAGE_STAGING_SH}\" \"\${deb}\" \"\${firstparty_dir}\"" "${ORCHESTRATOR}"

printf 'PASS mkosi package consumers are readable while download temporaries stay private\n'
