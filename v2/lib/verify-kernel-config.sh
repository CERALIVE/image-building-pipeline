#!/usr/bin/env bash
# Assert that every symbol a Kconfig fragment DECLARES actually survived into the
# resolved .config.
#
# WHY THIS EXISTS
#
# `scripts/kconfig/merge_config.sh -m` only MERGES text; it reports a symbol the
# fragment REDEFINES but says nothing about a symbol that `make olddefconfig`
# later drops. A symbol is dropped whenever its Kconfig visibility condition is
# unmet — most commonly because the fragment names a leaf config but not the
# `menuconfig` parent that gates it. The build then succeeds, the package
# validates, the image boots, and the driver is simply absent.
#
# That is not hypothetical: `rk3588-edge.fragment` declared
# `CONFIG_RTW89_8852BE=m` (the Rock 5B+ RTL8852BE WiFi adapter) without the
# parent `CONFIG_RTW89`, which is `tristate` and defaults off. `olddefconfig`
# discarded the leaf, the shipped 7.1.5 kernel carried
# `# CONFIG_RTW89 is not set`, and a real board enumerated the radio at PCI level
# (10ec:b852) with no driver bound and no `wl*` interface — with nothing in the
# build log to suggest anything had been lost.
#
# Usage: verify-kernel-config.sh <declared> <resolved-.config> [<allow-absent>]
#
# <declared> is whatever the manifest declared as the config source: a Kconfig
# FRAGMENT (defconfig mode) or a COMPLETE .config fetched from an upstream
# publisher (config-file mode). Both are read the same way — a list of symbol
# expectations — so one gate serves both modes.
#
# Semantics:
#   CONFIG_X=y|m|<value>       must appear VERBATIM in the resolved config
#   CONFIG_X=n                 must resolve to not-set (or be absent entirely)
#   # CONFIG_X is not set      must resolve to not-set (or be absent entirely)
#   comments / blank lines     ignored
#
# Exact value match is deliberate. A fragment asking for `=m` and receiving `=y`
# is a real difference in what ships (built-in vs a loadable module the initrd
# has to carry), so it is reported rather than tolerated; if a `select` from
# elsewhere legitimately forces a symbol built-in, say so in the fragment.
#
# <allow-absent> is an OPTIONAL file of bare symbol names (one per line, `#`
# comments ignored) that are permitted NOT to take their declared value. It
# exists for exactly one situation: a full upstream .config that declares
# symbols which cannot exist in the pinned source tree because the publisher's
# own build framework injects them from OUT-OF-TREE sources at build time
# (Armbian's EXTRAWIFI drivers). Every entry must be reviewed and justified in
# the file itself.
#
# The allowlist is NON-VACUOUS BY CONSTRUCTION: a listed symbol that DID take
# its declared value is a STALE exception and fails the build. Otherwise the
# list could silently grow into a blanket opt-out of the whole gate — which is
# the failure this gate exists to prevent, one level up.
set -euo pipefail

usage() {
	echo "usage: $(basename "$0") <declared> <resolved-.config> [<allow-absent>]" >&2
	exit 2
}

[[ $# -eq 2 || $# -eq 3 ]] || usage

FRAGMENT="$1"
RESOLVED="$2"
ALLOW_ABSENT="${3:-}"

[[ -r "${FRAGMENT}" ]] || { echo "FATAL: fragment not readable: ${FRAGMENT}" >&2; exit 1; }
[[ -r "${RESOLVED}" ]] || { echo "FATAL: resolved config not readable: ${RESOLVED}" >&2; exit 1; }

declare -A allow_absent=()
if [[ -n "${ALLOW_ABSENT}" ]]; then
	[[ -r "${ALLOW_ABSENT}" ]] \
		|| { echo "FATAL: allow-absent list not readable: ${ALLOW_ABSENT}" >&2; exit 1; }
	while IFS= read -r line; do
		line="${line%$'\r'}"
		line="${line%%#*}"
		line="${line//[[:space:]]/}"
		[[ -n "${line}" ]] || continue
		[[ "${line}" == CONFIG_* ]] \
			|| { echo "FATAL: allow-absent entry must be a full CONFIG_ symbol name: '${line}' (${ALLOW_ABSENT})" >&2; exit 1; }
		allow_absent["${line}"]=1
	done < "${ALLOW_ABSENT}"
	echo "allow-absent: ${#allow_absent[@]} reviewed exception(s) from ${ALLOW_ABSENT}"
fi

# --- resolved config -> map -------------------------------------------------
# A symbol absent from the map is "not set"; kconfig writes an explicit
# `# CONFIG_X is not set` for a visible-but-off symbol and omits an invisible
# one entirely, and both mean the same thing to the build.
declare -A resolved=()
while IFS= read -r line; do
	case "${line}" in
		CONFIG_*=*)
			resolved["${line%%=*}"]="${line#*=}"
			;;
		'# CONFIG_'*' is not set')
			sym="${line#\# }"
			resolved["${sym%% is not set}"]=''
			;;
	esac
done < "${RESOLVED}"

# --- fragment -> expectations ----------------------------------------------
declare -a failures=()
declare -i checked=0
declare -i allowed=0

while IFS= read -r line; do
	# Strip a trailing CR so a fragment saved with CRLF endings still parses.
	line="${line%$'\r'}"
	case "${line}" in
		'# CONFIG_'*' is not set')
			sym="${line#\# }"
			sym="${sym%% is not set}"
			want=''
			;;
		'#'*|'') continue ;;
		CONFIG_*=*)
			sym="${line%%=*}"
			want="${line#*=}"
			[[ "${want}" == 'n' ]] && want=''
			;;
		*) continue ;;
	esac

	checked+=1

	got=''
	[[ -v resolved["${sym}"] ]] && got="${resolved["${sym}"]}"

	if [[ -v allow_absent["${sym}"] ]]; then
		if [[ "${got}" == "${want}" ]]; then
			failures+=("${sym}: STALE EXCEPTION — listed in ${ALLOW_ABSENT} as permitted-absent, but the resolved config DOES carry ${sym}=${want}. Remove the entry.")
		else
			allowed+=1
		fi
		continue
	fi

	if [[ -z "${want}" ]]; then
		# Asked for OFF. Absent or explicitly-not-set both satisfy it.
		if [[ -n "${got}" ]]; then
			failures+=("${sym}: fragment asks for OFF, resolved config has ${sym}=${got}")
		fi
		continue
	fi

	if [[ ! -v resolved["${sym}"] ]]; then
		failures+=("${sym}: DROPPED — fragment asks for ${sym}=${want}, resolved config does not carry the symbol at all")
	elif [[ -z "${got}" ]]; then
		failures+=("${sym}: DROPPED — fragment asks for ${sym}=${want}, resolved config has '# ${sym} is not set'")
	elif [[ "${got}" != "${want}" ]]; then
		failures+=("${sym}: fragment asks for ${sym}=${want}, resolved config has ${sym}=${got}")
	fi
done < "${FRAGMENT}"

if (( ${#failures[@]} > 0 )); then
	{
		echo "FATAL: ${#failures[@]} of ${checked} fragment symbol(s) did not survive into the resolved kernel .config"
		echo "  fragment: ${FRAGMENT}"
		echo "  resolved: ${RESOLVED}"
		for f in "${failures[@]}"; do
			echo "  - ${f}"
		done
		echo
		echo "A DROPPED symbol almost always means its Kconfig visibility condition is unmet."
		echo "Check the symbol's own Kconfig entry for the parent 'menuconfig' it sits under"
		echo "and for its 'depends on' line, and declare those in the fragment too."
	} >&2
	exit 1
fi

echo "ok: $(( checked - allowed )) of ${checked} declared symbol(s) survived into the resolved kernel .config (${allowed} reviewed exception(s))"
