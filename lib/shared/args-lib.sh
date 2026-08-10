#!/usr/bin/env bash
#
# args-lib.sh — the shared command-line plumbing for the pipeline's entry points
# (`build`, `run-tests`, `dev-push`, `dev-sync`).
#
# WHAT WAS DUPLICATED
#
# Each entry point hand-rolled the same three things around its own genuinely
# different option set:
#
#   1. inline `--opt=value` splitting        (build, twice: --only= and --variant=)
#   2. `usage; die "unknown option: '$1'"`   (all four, four different spellings)
#   3. `-h|--help) usage; exit 0`            (dev-push, dev-sync)
#
# Those three are now here. The OPTION SETS stay in each entry point, because
# they are not the duplication — `--variant` means nothing to dev-sync and
# `--frontend` means nothing to build. A generic "declare your options and I'll
# parse them" framework would have replaced three small duplications with one
# large abstraction and moved every per-flag error message away from the code
# that produces it.
#
# CONTRACT: this library changes HOW arguments are parsed, never WHAT a user
# sees. `args_usage_die` runs the caller's own `usage` and then the caller's own
# `die` with the caller's own wording, so every help and error byte is where it
# was. That is checked by diffing pre/post `--help` and invalid-option captures.
#
# STANDALONE: sets no shell options, installs no trap, sources nothing. It is
# usable from any profile in docs/shell-profiles.md. `die` is used if the caller
# already has one (lib/common.sh) and otherwise defined here, matching the
# `declare -F`-guarded fallback idiom the postinst modules use.
#
# shellcheck shell=bash

if ! declare -F die >/dev/null 2>&1; then
  die() { printf '[ERROR] %s %s\n' "$(date '+%H:%M:%S')" "$*" >&2; exit 1; }
fi

# args_usage_die <usage-fn> <message...>
#   Print the caller's usage, then die with the caller's message. This is the
#   single most repeated two-liner across the entry points, and keeping it in one
#   place is what guarantees usage always precedes the error rather than the
#   other way round (which buries the error above a screen of help text).
args_usage_die() {
  local usage_fn="$1"
  shift
  "${usage_fn}"
  die "$*"
}

# args_is_help <token>
#   True for the conventional help tokens. `build` deliberately does NOT call
#   this: it has never accepted --help and treats it as an unknown option, and
#   making it accept one would change the CLI surface this refactor must not
#   touch.
args_is_help() {
  [[ "$1" == "-h" || "$1" == "--help" ]]
}

# args_has_flag <flag> <arg>...
#   True when a bare flag appears before any `--`. For an entry point whose only
#   option is a mode switch (`run-tests --list`), this replaces a parse loop that
#   would otherwise have to reimplement the passthrough rule to stay correct.
args_has_flag() {
  local want="$1" arg
  shift
  for arg in "$@"; do
    [[ "${arg}" == "--" ]] && return 1
    [[ "${arg}" == "${want}" ]] && return 0
  done
  return 1
}

# args_expand_inline <opt>... -- <arg>...
#   Rewrite `--opt=value` into the two tokens `--opt` `value`, for the named
#   value-taking options only, and publish the result in the ARGS_EXPANDED array.
#   A caller then needs one branch per option instead of two.
#
#   Three properties are load-bearing:
#     * `--opt=` (empty value) expands to `--opt` plus an EMPTY token, so the
#       caller's existing "requires a value" check still fires with its existing
#       message. Dropping the empty token instead would silently consume the
#       NEXT argument as the value.
#     * expansion STOPS at a literal `--`; everything after it is passthrough
#       payload that must reach the delegate unmodified.
#     * an undeclared `--other=x` is passed through untouched, so an option this
#       entry point does not know still reaches its own unknown-option branch
#       spelled exactly as the user typed it.
args_expand_inline() {
  local -a opts=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    opts+=("$1")
    shift
  done
  [[ "${1:-}" == "--" ]] && shift

  ARGS_EXPANDED=()
  local arg name opt matched
  local passthrough=0
  for arg in "$@"; do
    if (( passthrough )); then ARGS_EXPANDED+=("${arg}"); continue; fi
    if [[ "${arg}" == "--" ]]; then passthrough=1; ARGS_EXPANDED+=("${arg}"); continue; fi
    matched=0
    if [[ "${arg}" == --*=* ]]; then
      name="${arg%%=*}"
      for opt in "${opts[@]}"; do
        if [[ "${name}" == "${opt}" ]]; then
          ARGS_EXPANDED+=("${name}" "${arg#*=}")
          matched=1
          break
        fi
      done
    fi
    (( matched )) || ARGS_EXPANDED+=("${arg}")
  done
  return 0
}
