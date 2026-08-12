#!/usr/bin/env bash

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${TESTS_DIR}/.." && pwd)"
HELPER="${STAGING_HELPER:-${PIPELINE_DIR}/lib/stage-mkosi-package.sh}"
ORCHESTRATOR="${PIPELINE_DIR}/lib/orchestrate.sh"
PLATFORM_POSTINST="${PIPELINE_DIR}/mkosi/mkosi.images/platform/mkosi.postinst"
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mkosi-package-staging.XXXXXX")"

# The orchestrator is an ENTRY plus per-stage modules under lib/stages/. A static
# check that reads it by TEXT must read the whole SET in the entry's own source
# order, or it matches nothing and passes vacuously.
#
# Materialized to a FILE, never piped into `grep -q`: -q exits on the first match
# and SIGPIPEs the writer, which `set -o pipefail` then turns into a failed run.
ORCHESTRATOR_SOURCES="${RUN_DIR}/orchestrator-sources.sh"
{
	cat "${ORCHESTRATOR}"
	while read -r _stage_module; do
		cat "${PIPELINE_DIR}/lib/stages/${_stage_module}"
	done < <(sed -n 's#^source "\${STAGE_DIR}/\(.*\)"$#\1#p' "${ORCHESTRATOR}")
} >"${ORCHESTRATOR_SOURCES}"
[[ -s "${ORCHESTRATOR_SOURCES}" ]] || {
	printf 'FAIL could not assemble the orchestrator source set\n' >&2
	exit 1
}

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
	else
		sudo -n -u nobody -- find "${dir}" -maxdepth 1 -type f -name '*.deb' -printf '%f\n' 2>/dev/null
	fi
}

# The index probes below need GENUINE privilege separation — the `find` has to run
# as a different, unprivileged UID, because what they assert is a real on-disk
# ownership/mode permission check. `unshare --user --map-root-user` does NOT supply
# it: remapping a UID inside a namespace does not change those checks. So the probe
# needs real root (runuser) or passwordless sudo, and a sandboxed environment often
# has neither. Every other assertion in this file needs no privilege at all and
# always runs, which is why this file stays `default-shell` in tests/registry.tsv.
#
# Same opt-in shape as run-tests' CERALIVE_RUN_REAL_{AVAHI,RAUC}_CONTRACT gates:
# `skip` locally, `required` in CI. Note the one deliberate difference — those two
# gates decide whether the real check RUNS at all, while this one only decides what
# happens when the probe is genuinely unavailable. Real privilege is always
# exercised when it is present, whichever value is set.
PRIVILEGE_DROP_CONTRACT="${CERALIVE_RUN_REAL_PRIVILEGE_DROP_CONTRACT:-skip}"
case "${PRIVILEGE_DROP_CONTRACT}" in
	required | skip) ;;
	*)
		echo "ERROR: CERALIVE_RUN_REAL_PRIVILEGE_DROP_CONTRACT must be 'required' or 'skip'" >&2
		exit 2
		;;
esac

privilege_drop_available() {
	if [[ "$(id -u)" == "0" ]]; then
		return 0
	fi
	sudo -n -u nobody true 2>/dev/null
}

if privilege_drop_available; then
	PRIVILEGE_DROP=1
elif [[ "${PRIVILEGE_DROP_CONTRACT}" == "required" ]]; then
	printf 'FAIL unprivileged package-index probe requires root or passwordless sudo\n' >&2
	exit 1
else
	PRIVILEGE_DROP=0
	echo "== SKIP real privilege-drop contract (set CERALIVE_RUN_REAL_PRIVILEGE_DROP_CONTRACT=required) =="
fi

for class in bsp firstparty; do
	install -d -m 0700 "${RUN_DIR}/blocked/${class}"
	install -m 0644 "${RUN_DIR}/private-download/demo_1.0_arm64.deb" \
		"${RUN_DIR}/blocked/${class}/demo_1.0_arm64.deb"
	[[ "${PRIVILEGE_DROP}" -eq 1 ]] || continue
	[[ -z "$(unprivileged_index "${RUN_DIR}/blocked/${class}")" ]] || {
		printf 'FAIL mode-0700 %s directory unexpectedly exposed a package index\n' "${class}" >&2
		exit 1
	}
done
if [[ "${PRIVILEGE_DROP}" -eq 1 ]]; then
	printf 'PASS mode-0700 BSP and first-party directories yield empty unprivileged indexes\n'
else
	printf 'SKIP mode-0700 BSP and first-party unprivileged index probe (no privilege separation)\n'
fi

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
	[[ "${PRIVILEGE_DROP}" -eq 1 ]] || continue
	[[ "$(unprivileged_index "${dir}")" == "demo_1.0_arm64.deb" ]] || {
		printf 'FAIL unprivileged package index is empty: %s\n' "${dir}" >&2
		exit 1
	}
done
[[ "${PRIVILEGE_DROP}" -eq 1 ]] ||
	printf 'SKIP mkosi consumer unprivileged index probe (no privilege separation)\n'

[[ "$(stat -c '%a' "${RUN_DIR}/private-download")" == "700" ]] || {
	printf 'FAIL private download directory permissions were widened\n' >&2
	exit 1
}
[[ "$(stat -c '%a' "${RUN_DIR}/private-download/demo_1.0_arm64.deb")" == "600" ]] || {
	printf 'FAIL private download archive permissions were widened\n' >&2
	exit 1
}

grep -Fq "MKOSI_PACKAGE_STAGING_SH=\"\${HERE}/stage-mkosi-package.sh\"" "${ORCHESTRATOR}"
grep -Fq -- "\"\${MKOSI_PACKAGE_STAGING_SH}\" \"\${deb}\" \"\${bsp_dir}\"" "${ORCHESTRATOR_SOURCES}"
grep -Fq -- "\"\${MKOSI_PACKAGE_STAGING_SH}\" \"\${deb}\" \"\${firstparty_dir}\"" "${ORCHESTRATOR_SOURCES}"

# The runner service uses UMask=0077, so the checkout and .staging ancestors are
# intentionally private. The container must mount each consumer leaf directly;
# passing its /work path makes mkosi's unprivileged repository indexer see zero
# packages even when the leaf and archives themselves are readable.
grep -Fq -- '-v "${bsp_dir}:/run/ceralive-bsp:ro"' "${ORCHESTRATOR_SOURCES}"
grep -Fq -- '-v "${firstparty_dir}:/run/ceralive-firstparty:ro"' "${ORCHESTRATOR_SOURCES}"
grep -Fq -- '--package-directory /run/ceralive-bsp' "${ORCHESTRATOR_SOURCES}"
grep -Fq -- '--extra-tree /run/ceralive-firstparty:/opt/ceralive-staging' "${ORCHESTRATOR_SOURCES}"
if grep -Fq -- '--package-directory /work/mkosi/.staging/' "${ORCHESTRATOR_SOURCES}"; then
	printf 'FAIL containerized mkosi still traverses private /work staging ancestors\n' >&2
	exit 1
fi

mount_source="${RUN_DIR}/consumer,with space"
mount_args=(-v "${mount_source}:/run/ceralive-bsp:ro")
[[ "${#mount_args[@]}" -eq 2 ]] || {
	printf 'FAIL read-only package bind mount split into multiple arguments\n' >&2
	exit 1
}
[[ "${mount_args[1]}" == "${mount_source}:/run/ceralive-bsp:ro" ]] || {
	printf 'FAIL read-only package bind mount changed a source path containing comma/space\n' >&2
	exit 1
}

# Raw apt-get uses the image's persistent APT state and cannot see mkosi's
# ephemeral file:/repository. A non-chroot postinstall receives mkosi's wrapper,
# which carries the local repository and package-list state into both BSP installs.
[[ "${PLATFORM_POSTINST}" != *.chroot ]] || {
	printf 'FAIL platform BSP installer is chrooted outside mkosi wrapper PATH\n' >&2
	exit 1
}
# FOUR install sites: the HW-accel GStreamer set, zstd, initramfs-tools, and the
# boot BSP. initramfs-tools is deliberately its OWN transaction and not one more
# name on the boot-BSP line — a kernel .deb emits its initramfs by run-parts-ing
# /etc/kernel/postinst.d, so on the source-built path the hook has to be configured
# before the kernel is unpacked (see docs/kernel-build-from-source.md §4b). zstd is
# separate for the same ORDERING reason: initramfs-tools defaults to COMPRESS=zstd
# and degrades to gzip if the binary is not already configured when the kernel
# postinst runs, and shared.list installs it a whole layer too late.
[[ "$(grep -Ec '^[[:space:]]*mkosi-install -y --no-install-recommends ' "${PLATFORM_POSTINST}")" -eq 4 ]] || {
	printf 'FAIL platform BSP installs do not all use mkosi-install\n' >&2
	exit 1
}
# The exact count above catches an added/removed site; this catches a site that
# installs by some other means entirely, which a count alone cannot see.
if grep -Eq '^[[:space:]]*(apt-get|apt|aptitude) install |^[[:space:]]*dpkg -i ' "${PLATFORM_POSTINST}"; then
	printf 'FAIL platform BSP install bypasses mkosi local repository\n' >&2
	exit 1
fi

install -d -m 0755 "${RUN_DIR}/bin"
printf '%s\n' '#!/bin/sh' 'printf "%s\\n" "$*" >>"${MKOSI_INSTALL_CALLS}"' \
	>"${RUN_DIR}/bin/mkosi-install"
printf '%s\n' '#!/bin/sh' 'printf "raw apt-get invoked\\n" >&2' 'exit 90' \
	>"${RUN_DIR}/bin/apt-get"
printf '%s\n' '#!/bin/sh' 'printf "%s\\n" "$*" >>"${RM_CALLS}"' \
	>"${RUN_DIR}/bin/rm"
chmod 755 "${RUN_DIR}/bin/"*

# The firmware prune is now GATED on a modinfo sweep of the installed modules
# rather than deleting a fixed list of directory names, so the fixture has to
# carry a firmware tree for it to have anything to decide about. Both classes are
# present: candidate families, and preserved ones that must survive.
for _fw in qcom intel ath10k ath11k ath12k updates microchip nvidia tegra renesas brcm rtw89 rockchip; do
	install -d -m 0755 "${RUN_DIR}/buildroot/usr/lib/firmware/${_fw}"
done
: >"${RUN_DIR}/buildroot/usr/lib/firmware/r8a779x_usb3_rom.mem"

MKOSI_INSTALL_CALLS="${RUN_DIR}/mkosi-install.calls" \
	RM_CALLS="${RUN_DIR}/rm.calls" \
	PATH="${RUN_DIR}/bin:${PATH}" \
	BUILDROOT="${RUN_DIR}/buildroot" \
	ARCH=arm64 \
	INSTALL_BOOT_BSP=1 \
	HW_ACCEL_GSTREAMER_PLUGINS='gstreamer-bsp' \
	GSTREAMER_RUNTIME_PACKAGES='gstreamer-runtime' \
	KERNEL_PACKAGES='linux-image-demo' \
	DTB_PACKAGES='linux-dtb-demo' \
	UBOOT_PACKAGES='linux-u-boot-demo' \
	FIRMWARE_PACKAGES='firmware-demo' \
	bash "${PLATFORM_POSTINST}" >"${RUN_DIR}/platform-postinst.log" 2>&1 || {
		cat "${RUN_DIR}/platform-postinst.log" >&2
		printf 'FAIL platform BSP installer did not use the mkosi wrapper\n' >&2
		exit 1
	}

# The ORDER is the assertion, not just the membership: zstd must be a configured
# package before the kernel .deb's postinst generates the initramfs, or
# initramfs-tools silently falls back to gzip. (initramfs-tools itself is absent
# here because this fixture drives the PREBUILT vendor path, where the kernel
# package pulls it as a hard dependency; the source-built path adds a fourth call.)
mapfile -t install_calls <"${RUN_DIR}/mkosi-install.calls"
[[ "${#install_calls[@]}" -eq 3 ]]
[[ "${install_calls[0]}" == '-y --no-install-recommends gstreamer-bsp gstreamer-runtime' ]]
[[ "${install_calls[1]}" == '-y --no-install-recommends zstd' ]]
[[ "${install_calls[2]}" == '-y --no-install-recommends linux-image-demo linux-dtb-demo linux-u-boot-demo firmware-demo' ]]

# The prune now issues ONE removal per family it has proved has no consumer, in
# candidate order, and must issue none at all for a preserved family. Asserting
# the exact call list keeps both halves honest: a widened candidate list and a
# silently-skipped prune each fail here.
_expected_rm=""
for _fw in qcom intel ath10k ath11k ath12k updates microchip nvidia tegra renesas; do
	_expected_rm+="-rf ${RUN_DIR}/buildroot/usr/lib/firmware/${_fw}"$'\n'
done
_expected_rm+="-f ${RUN_DIR}/buildroot/usr/lib/firmware/r8a779x_usb3_rom.mem"
[[ "$(<"${RUN_DIR}/rm.calls")" == "${_expected_rm}" ]] || {
	printf 'FAIL firmware prune issued unexpected removals:\n%s\n---- expected ----\n%s\n' \
		"$(<"${RUN_DIR}/rm.calls")" "${_expected_rm}" >&2
	exit 1
}
for _fw in brcm rtw89 rockchip; do
	if grep -q "firmware/${_fw}\$" "${RUN_DIR}/rm.calls"; then
		printf 'FAIL preserved firmware family %s was removed\n' "${_fw}" >&2
		exit 1
	fi
done

printf 'PASS mkosi package consumers are readable while download temporaries stay private\n'
