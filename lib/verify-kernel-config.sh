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
# Usage (POSITIONAL — the in-builder form, unchanged):
#   verify-kernel-config.sh <declared> <resolved-.config> [<allow-absent>]
#
# Usage (OPTIONS — the closure-manifest form):
#   verify-kernel-config.sh --config <resolved-.config>
#                           [--declared <declared>] [--allow-absent <list>]
#                           [--required <list>] [--forbidden <list>]
#
# The two forms are the SAME checker: the positional form is exactly
# `--declared <1> --config <2> [--allow-absent <3>]`, and an invocation written
# either way produces the same verdict. The option form exists because the
# dependency-closure manifests (`--required` / `--forbidden`) have no positional
# slot, and because a resolved config can be audited against those manifests
# with no declared fragment at all — which is what the acceptance matrix does
# against a real build's `.config`.
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
	{
		echo "usage: $(basename "$0") <declared> <resolved-.config> [<allow-absent>]"
		echo "       $(basename "$0") --config <resolved-.config> [--declared <declared>]"
		echo "                        [--allow-absent <list>] [--required <list>] [--forbidden <list>]"
	} >&2
	exit 2
}

FRAGMENT=""
RESOLVED=""
ALLOW_ABSENT=""
REQUIRED_LIST=""
FORBIDDEN_LIST=""

# A leading `-` selects the option form; anything else is the historical
# positional form, which every in-builder invocation still uses.
if [[ $# -gt 0 && "$1" == -* ]]; then
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--config)       [[ $# -ge 2 ]] || usage; RESOLVED="$2";      shift 2 ;;
			--declared)     [[ $# -ge 2 ]] || usage; FRAGMENT="$2";      shift 2 ;;
			--allow-absent) [[ $# -ge 2 ]] || usage; ALLOW_ABSENT="$2";  shift 2 ;;
			--required)     [[ $# -ge 2 ]] || usage; REQUIRED_LIST="$2"; shift 2 ;;
			--forbidden)    [[ $# -ge 2 ]] || usage; FORBIDDEN_LIST="$2";shift 2 ;;
			-h|--help)      usage ;;
			*) echo "FATAL: unknown option: $1" >&2; usage ;;
		esac
	done
	[[ -n "${RESOLVED}" ]] || { echo "FATAL: --config is required" >&2; usage; }
	[[ -n "${FRAGMENT}${REQUIRED_LIST}${FORBIDDEN_LIST}" ]] \
		|| { echo "FATAL: nothing to check — give at least one of --declared/--required/--forbidden" >&2; usage; }
	[[ -n "${FRAGMENT}" || -z "${ALLOW_ABSENT}" ]] \
		|| { echo "FATAL: --allow-absent has no meaning without --declared" >&2; usage; }
else
	[[ $# -eq 2 || $# -eq 3 ]] || usage
	FRAGMENT="$1"
	RESOLVED="$2"
	ALLOW_ABSENT="${3:-}"
fi

[[ -z "${FRAGMENT}" || -r "${FRAGMENT}" ]] || { echo "FATAL: fragment not readable: ${FRAGMENT}" >&2; exit 1; }
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

if [[ -n "${FRAGMENT}" ]]; then
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
fi

# --- closure manifests -> expectations --------------------------------------
# A REQUIRED entry is either `CONFIG_X=<value>` (exact, same rule as a fragment
# line) or a bare `CONFIG_X` meaning "set to something" — the form used for a
# `menuconfig` PARENT whose own tristate value is defconfig's business, but whose
# presence is what keeps every leaf under it visible.
#
# A FORBIDDEN entry is a bare symbol name and nothing else. `CONFIG_X=<value>`
# there would read as "this exact value is banned, another is fine", which is a
# weaker claim than the manifest is for, so it is refused as a usage error
# rather than silently reinterpreted.
declare -a closure_failures=()
declare -i required_checked=0
declare -i forbidden_checked=0

if [[ -n "${REQUIRED_LIST}" ]]; then
	[[ -r "${REQUIRED_LIST}" ]] \
		|| { echo "FATAL: required-symbols list not readable: ${REQUIRED_LIST}" >&2; exit 1; }
	while IFS= read -r line; do
		line="${line%$'\r'}"
		line="${line%%#*}"
		line="${line//[[:space:]]/}"
		[[ -n "${line}" ]] || continue
		[[ "${line}" == CONFIG_* ]] \
			|| { echo "FATAL: required entry must be a full CONFIG_ symbol name: '${line}' (${REQUIRED_LIST})" >&2; exit 1; }
		required_checked+=1

		sym="${line%%=*}"
		want=''
		[[ "${line}" == *=* ]] && want="${line#*=}"

		got=''
		[[ -v resolved["${sym}"] ]] && got="${resolved["${sym}"]}"

		if [[ ! -v resolved["${sym}"] ]]; then
			closure_failures+=("${sym}: REQUIRED but the resolved config does not carry the symbol at all")
		elif [[ -z "${got}" ]]; then
			closure_failures+=("${sym}: REQUIRED but the resolved config has '# ${sym} is not set'")
		elif [[ -n "${want}" && "${got}" != "${want}" ]]; then
			closure_failures+=("${sym}: REQUIRED as ${sym}=${want}, resolved config has ${sym}=${got}")
		fi
	done < "${REQUIRED_LIST}"
fi

if [[ -n "${FORBIDDEN_LIST}" ]]; then
	[[ -r "${FORBIDDEN_LIST}" ]] \
		|| { echo "FATAL: forbidden-symbols list not readable: ${FORBIDDEN_LIST}" >&2; exit 1; }
	while IFS= read -r line; do
		line="${line%$'\r'}"
		line="${line%%#*}"
		line="${line//[[:space:]]/}"
		[[ -n "${line}" ]] || continue
		[[ "${line}" == CONFIG_* ]] \
			|| { echo "FATAL: forbidden entry must be a full CONFIG_ symbol name: '${line}' (${FORBIDDEN_LIST})" >&2; exit 1; }
		[[ "${line}" != *=* ]] \
			|| { echo "FATAL: forbidden entry must be a bare symbol name, not a value assignment: '${line}' (${FORBIDDEN_LIST})" >&2; exit 1; }
		forbidden_checked+=1

		if [[ -v resolved["${line}"] && -n "${resolved["${line}"]}" ]]; then
			closure_failures+=("${line}: FORBIDDEN but the resolved config has ${line}=${resolved["${line}"]}")
		fi
	done < "${FORBIDDEN_LIST}"
fi

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
fi

if (( ${#closure_failures[@]} > 0 )); then
	{
		echo "FATAL: ${#closure_failures[@]} dependency-closure violation(s) in the resolved kernel .config"
		echo "  resolved:  ${RESOLVED}"
		[[ -n "${REQUIRED_LIST}" ]]  && echo "  required:  ${REQUIRED_LIST}"
		[[ -n "${FORBIDDEN_LIST}" ]] && echo "  forbidden: ${FORBIDDEN_LIST}"
		for f in "${closure_failures[@]}"; do
			echo "  - ${f}"
		done
		echo
		echo "A REQUIRED symbol that is absent is usually a dropped 'menuconfig' PARENT:"
		echo "the leaves under it stop being visible and vanish without any warning."
		echo "A FORBIDDEN symbol that is present means a platform or debug selection"
		echo "the edge config is supposed to exclude came back in."
	} >&2
fi

(( ${#failures[@]} + ${#closure_failures[@]} == 0 )) || exit 1

if [[ -n "${FRAGMENT}" ]]; then
	echo "ok: $(( checked - allowed )) of ${checked} declared symbol(s) survived into the resolved kernel .config (${allowed} reviewed exception(s))"
fi
if (( required_checked + forbidden_checked > 0 )); then
	echo "ok: ${required_checked} required and ${forbidden_checked} forbidden symbol(s) hold in ${RESOLVED}"
fi
