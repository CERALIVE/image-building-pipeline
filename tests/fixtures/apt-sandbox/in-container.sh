#!/usr/bin/env bash
#
# Container-side half of tests/fetch-debs-apt-sandbox.test.sh.
#
# Runs the SHIPPED fetch_first_party with a REAL apt-get against a real,
# GPG-signed fixture repository, under a deliberately restrictive umask, and
# drops the evidence the host driver asserts on into /work/<leg>/.
#
#   root      leg — real UID 0, so apt drops its acquire methods to `_apt`
#   rootless  leg — a real unprivileged account, so apt keeps the caller's own
#
# DESTRUCTIVE: it adds a user, chowns and chmods. Only ever run in a throwaway
# container.
#
# Usage: in-container.sh <root|rootless> <host-uid>:<host-gid>

set -euo pipefail

leg="${1:?leg (root|rootless)}"
host_owner="${2:?host uid:gid}"

REPO_DIR=/repo
FIXTURE_DIR=/fx
WORK="/work/${leg}"
TEST_USER=ceratest
TEST_UID=4242

# The rootless leg still ENTERS as root (that is how the container starts), so
# it drops privileges here and re-execs itself, then hands the evidence tree
# back to the host uid once the unprivileged half has finished.
if [[ "${leg}" == "rootless" && "$(id -u)" -eq 0 ]]; then
	id -u "${TEST_USER}" >/dev/null 2>&1 \
		|| useradd --create-home --uid "${TEST_UID}" "${TEST_USER}"
	install -d -m 0755 -o "${TEST_USER}" -g "${TEST_USER}" "${WORK}"
	rc=0
	runuser -u "${TEST_USER}" -- "$0" "${leg}" "${host_owner}" || rc=$?
	chown -R "${host_owner}" "${WORK}"
	exit "${rc}"
fi

uid="$(id -u)"
case "${leg}" in
	root)
		[[ "${uid}" -eq 0 ]] \
			|| { printf 'FATAL: root leg is not real UID 0 (id -u=%s)\n' "${uid}" >&2; exit 2; }
		;;
	rootless)
		[[ "${uid}" -ne 0 ]] \
			|| { printf 'FATAL: rootless leg is running as root\n' >&2; exit 2; }
		;;
	*)
		printf 'FATAL: unknown leg %s\n' "${leg}" >&2
		exit 2
		;;
esac

install -d -m 0755 "${WORK}"
printf '%s\n' "${uid}" >"${WORK}/uid"

bin="${WORK}/bin"
install -d -m 0755 "${bin}"
argv_log="${WORK}/apt-argv.log"
: >"${argv_log}"

# Records the EXACT argv the shipped code hands apt, then runs the real apt-get.
cat >"${bin}/apt-get" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
{
	printf 'apt-get'
	for a in "$@"; do printf ' %q' "${a}"; done
	printf '\n'
} >>"${CERALIVE_TEST_APT_ARGV_LOG}"
exec /usr/bin/apt-get "$@"
SH
chmod 0755 "${bin}/apt-get"

# binutils is not in debian:*-slim; deb-lib.sh needs exactly this one ar form.
cat >"${bin}/ar" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == p && "${3:-}" == control.tar.gz ]] || exit 1
dpkg-deb --ctrl-tarfile "$2" | gzip -c
SH
chmod 0755 "${bin}/ar"

# 0077 is the whole point of the fixture: the staging tree is created exactly as
# a restrictive-umask runner would create it, so the traversability fix is what
# makes apt able to keep its sandbox rather than the ambient mode.
dest="${WORK}/staging"
(
	umask 0077
	mkdir -p "${dest}/debs"
)

rc=0
env \
	PATH="${bin}:${PATH}" \
	CERALIVE_TEST_APT_ARGV_LOG="${argv_log}" \
	CHANNEL=stable \
	ARCH=arm64 \
	APT_CERALIVE_URL="file://${FIXTURE_DIR}/repo" \
	APT_GPG_PUBLIC_B64="$(base64 -w0 "${FIXTURE_DIR}/keyring.gpg")" \
	APT_CLIENT_CRT_B64="$(printf '%s' 'fixture client certificate' | base64 -w0)" \
	APT_CLIENT_KEY_B64="$(printf '%s' 'fixture client private key' | base64 -w0)" \
	bash -c 'umask 0077; source "$1"; fetch_first_party "$2"' \
	bash "${REPO_DIR}/lib/fetch-debs.sh" "${dest}/debs" \
	>"${WORK}/fetch.out" 2>&1 || rc=$?
printf '%s\n' "${rc}" >"${WORK}/rc"

key="${dest}/debs/.apt-state-firstparty/certs/client.key"
: >"${WORK}/client-key.stat"
[[ -e "${key}" ]] && stat -c '%U %a' "${key}" >"${WORK}/client-key.stat"

find "${dest}/debs" -maxdepth 1 -type f -name '*.deb' -printf '%f %m\n' \
	| sort >"${WORK}/staged.txt"

# Non-vacuity control (root only): replay the SAME acquisition the shipped code
# just performed, but into a plain `mktemp -d` — the exact pre-fix shape. It
# MUST still warn, or the "no unsandboxed fallback" assertion above proves
# nothing about this fixture. The command is replayed verbatim from the recorded
# argv so the control can never drift from what the code actually ran.
if [[ "${leg}" == "root" ]]; then
	: >"${WORK}/control.out"
	download_argv="$(grep -F ' download ' "${argv_log}" | tail -1 || true)"
	if [[ -n "${download_argv}" ]]; then
		control_dir="$(mktemp -d "${dest}/debs/.control-XXXXXX")"
		(
			cd "${control_dir}"
			eval "/usr/bin/apt-get ${download_argv#apt-get}"
		) >"${WORK}/control.out" 2>&1 || true
		rm -rf "${control_dir}"
	fi
	chown -R "${host_owner}" "${WORK}"
fi

exit 0
