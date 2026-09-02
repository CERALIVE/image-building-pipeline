#!/usr/bin/env bash
#
# check-build-log.sh — census-governed build-log lint.
#
# Reads docs/build-log-census.md (the frozen inventory of every warning/error
# signature a real build may emit) and rejects a build log that:
#
#   * contains a BLOCKING signature                         — never allowed
#   * contains a FIXED signature                            — a regression
#   * contains a signature that is in NO table              — novel
#   * contains an ACCEPTED signature MORE times than its recorded baseline
#   * contains a POST-FIX signature more times than its ceiling
#
# There are no wildcard exceptions. Every allowed pattern is compared with `==`
# against a normalized line, so an entry can only ever match what it literally
# says. See docs/build-log-census.md "Diagnostic surface" for the normalization
# contract this file implements.
#
# Usage:
#   ci/check-build-log.sh <build.log> [<build.log>…]
#   ci/check-build-log.sh --census-report <build.log>   # counts, no verdict
#   ci/check-build-log.sh --self-test                   # fixture-driven proof
#
# shellcheck shell=bash
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"
CENSUS="${CERALIVE_BUILD_LOG_CENSUS:-${PIPELINE_DIR}/docs/build-log-census.md}"
FIXTURE_DIR="${HERE}/fixtures/build-log"

die() { printf 'check-build-log: %s\n' "$*" >&2; exit 2; }

usage() {
  sed -n '3,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

# ---------------------------------------------------------------------------
# DIAGNOSTIC_ANCHORS — what counts as a warning/error line at all.
#
# Deliberately tool-prefix based rather than a bare `grep -iE 'warn|error'`: a
# kernel build emits hundreds of `CC drivers/.../error.o` object lines, and a
# keyword grep would drown the real signal in them and make the whole lint
# unusable (which is how build-log noise gets ignored in the first place).
#
# COVERAGE, not mechanism, is what widens here. A keyword sweep of a real
# 20,016-line trixie build (`-iE 'error|warn|fail|denied|permission|cannot|
# unable'`) matched 220 lines; 142 were already anchored and 93 were not. 51 of
# those 93 are pure substring noise a keyword grep cannot tell from a diagnostic
# — the packages `libgpg-error0`/`liberror-perl`, kernel objects such as
# `net/core/failover.o`, patch filenames like `0015-rkvenc-resource-error-…`,
# and this pipeline's own prose ("…restart policy (additive Restart=on-failure
# drop-in…)"). The remaining 42 were real diagnostics in four families the
# anchors could not see, each added below. The keyword sweep is ALSO strictly
# weaker than the anchors in the other direction: 15 anchored lines carry none
# of those keywords at all (`Ign:<N> …`, `invoke-rc.d: could not determine
# current runlevel`, `dir not exist`), which is why the anchor list stays the
# mechanism and the sweep is only how its gaps are found.
#
#   * `^<builder> …`  — see LINE_PREFIX_RULES; BuildKit step-prefixed lines from
#     the two builder-image builds (`ci/Dockerfile`, `ci/Dockerfile.kernel`).
#   * BuildKit's own Dockerfile-lint block (`#<n> WARN: <Rule>: …` plus the
#     `N warning(s) found …` summary and its ` - <Rule>: … (line <n>)` bullet).
#   * `^runit: ` — the runit init-helper's policy-rc.d denial, which Debian's
#     openssh-server/dnsmasq postinsts emit ALONGSIDE the invoke-rc.d one.
#   * `^Running in chroot, ignoring …` — deb-systemd-invoke/deb-systemd-helper
#     declining a start/reload in the build chroot. Same permission/denied class
#     as the runit line it sits next to, and found because of that adjacency:
#     it carries none of the sweep's keywords and so is invisible to a grep.
# ---------------------------------------------------------------------------
DIAGNOSTIC_ANCHORS=$'^dpkg: warning: |^dpkg-statoverride: warning: |^update-alternatives: (warning|error): |^update-rc\\.d: warning: |^invoke-rc\\.d: |^start-stop-daemon: |^W: |^(Ign|Err):[0-9]+ |^\u2023 .*(is deprecated|should be configured in \\[Output\\]|falling back to copying)|^Reloading system message bus config|^/usr/lib/tmpfiles\\.d/.*: Failed to resolve user |^mv: cannot move \'/etc/resolv\\.conf\'|^ln: failed to create symbolic link \'/etc/resolv\\.conf\'|^Cannot (take a backup|install symlink|open netlink)|^dir not exist$|^Configured GrowFileSystem=|^<builder> (update-alternatives: (warning|error): |invoke-rc\\.d: |WARN: )|^ ?[0-9]+ warnings? found \\(use docker|^ ?- [A-Za-z]+: .* \\(line [0-9]+\\)$|^runit: |^Running in chroot, ignoring '

# ---------------------------------------------------------------------------
# LINE_PREFIX_RULES — step 1: reduce a line to the diagnostic it carries.
#
# Three transport artefacts carry no information and vary per run, so anchoring
# never sees them: the CR (the mkosi/dpkg legs of a real log are CRLF, which is
# why an obvious grep for these strings "mysteriously" fails), the pipeline's
# own `[LEVEL] HH:MM:SS ` prefix, and BuildKit's SGR colour codes (its lint
# summary is emitted as `\033[33m1 warning found …`).
#
# BuildKit's per-line `#<step> <elapsed> ` prefix is handled DIFFERENTLY: it is
# collapsed to the FIXED marker `<builder> ` rather than deleted. Deleting it is
# the obvious simplification and it would fail every clean release build —
# census rows 5 and 6 (`update-alternatives: warning: skip creation of …` and
# `update-alternatives: error: alternative path …`) are FIXED, meaning ANY
# occurrence fails, because todo9 removed their cause in the DEVICE IMAGE
# layers. The builder images legitimately emit 34 of the first form while
# installing automake/xz-utils/fakeroot into a slim base that ships no manpages,
# so merging the two subjects would turn a correct build into a red one. The
# marker keeps the builder-image family a separate signature with its own
# ceiling, which is also what the census Stage/Owner columns exist to express.
# ---------------------------------------------------------------------------
LINE_PREFIX_RULES=$'s/\033\\[[0-9;]*m//g; s/\r$//; s/^\\[[A-Z ]{1,6}\\] [0-9]{2}:[0-9]{2}:[0-9]{2} //; s/^#[0-9]+ ([0-9]+\\.[0-9]+ )?/<builder> /'

# ---------------------------------------------------------------------------
# normalize_log <file> — emit one normalized signature per diagnostic line.
#
# Step 1 is LINE_PREFIX_RULES above. Step 2 elides variable substrings into the
# fixed placeholder vocabulary and collapses the multi-line diagnostics onto a
# single signature each, by EXACT line match rather than by pattern.
# ---------------------------------------------------------------------------
normalize_log() {
  sed -E "${LINE_PREFIX_RULES}" "$1" \
    | { grep -E "${DIAGNOSTIC_ANCHORS}" || true; } \
    | sed -f <(normalize_rules)
}

normalize_rules() {
  cat <<'NORMALIZE'
s/^dpkg: warning: This system uses merged-usr-via-aliased-dirs, going behind dpkg's$/dpkg: warning: <merged-usr-via-aliased-dirs advisory>/
s/^dpkg: warning: back, breaking its core assumptions\. This can cause silent file$/dpkg: warning: <merged-usr-via-aliased-dirs advisory>/
s/^dpkg: warning: overwrites and disappearances, and its general tools misbehavior\.$/dpkg: warning: <merged-usr-via-aliased-dirs advisory>/
s|^dpkg: warning: See <https://wiki.debian.org/Teams/Dpkg/FAQ#broken-usrmerge>\.$|dpkg: warning: <merged-usr-via-aliased-dirs advisory>|
s|^mv: cannot move '/etc/resolv\.conf' to '/etc/\.resolv\.conf\.systemd-resolved\.bak': Device or resource busy$|<systemd-resolved postinst: /etc/resolv.conf busy (builder bind-mount)>|
s|^Cannot take a backup of /etc/resolv\.conf\.$|<systemd-resolved postinst: /etc/resolv.conf busy (builder bind-mount)>|
s|^ln: failed to create symbolic link '/etc/resolv\.conf': Device or resource busy$|<systemd-resolved postinst: /etc/resolv.conf busy (builder bind-mount)>|
s|^Cannot install symlink from /etc/resolv\.conf to \.\./run/systemd/resolve/stub-resolv\.conf$|<systemd-resolved postinst: /etc/resolv.conf busy (builder bind-mount)>|
s|^update-alternatives: warning: skip creation of .* because associated file .* (of link group .*) doesn.t exist$|update-alternatives: warning: skip creation of <PATH> because associated file <PATH> (of link group <GROUP>) doesn't exist|
s|^update-alternatives: error: alternative path .* doesn.t exist$|update-alternatives: error: alternative path <PATH> doesn't exist|
s|^invoke-rc\.d: initscript dbus, action ".*" failed\.$|invoke-rc.d: initscript dbus, action "<ACTION>" failed.|
s|^invoke-rc\.d: policy-rc\.d denied execution of .*\.$|invoke-rc.d: policy-rc.d denied execution of <ACTION>.|
s|^W: Possible missing firmware .* for built-in driver .*$|W: Possible missing firmware <PATH> for built-in driver <DRIVER>|
s#^\(Ign\|Err\):[0-9][0-9]* #\1:<N> #
s|^‣ .*: Setting FinalizeScript is deprecated, please use FinalizeScripts instead\.$|‣ <PATH>: Setting FinalizeScript is deprecated, please use FinalizeScripts instead.|
s|^‣ .*: Setting RepartDirectories should be configured in \[Output\], not \[Content\]\.$|‣ <PATH>: Setting RepartDirectories should be configured in [Output], not [Content].|
s|^‣ Could not rename .* to .* as they are located on different devices, falling back to copying$|‣ Could not rename <PATH> to <PATH> as they are located on different devices, falling back to copying|
s|^Configured GrowFileSystem=[a-z]* for partition type 'linux-generic' that doesn.t support it, ignoring\.$|Configured GrowFileSystem=<VALUE> for partition type 'linux-generic' that doesn't support it, ignoring.|
s|^<builder> update-alternatives: warning: skip creation of .* because associated file .* (of link group .*) doesn.t exist$|<builder> update-alternatives: warning: skip creation of <PATH> because associated file <PATH> (of link group <GROUP>) doesn't exist|
s|^<builder> update-alternatives: warning: forcing reinstallation of alternative .* because link group .* is broken$|<builder> update-alternatives: warning: forcing reinstallation of alternative <PATH> because link group <GROUP> is broken|
s|^<builder> invoke-rc\.d: policy-rc\.d denied execution of .*\.$|<builder> invoke-rc.d: policy-rc.d denied execution of <ACTION>.|
s|^<builder> WARN: InvalidDefaultArgInFrom: .*$|<builder-image lint: InvalidDefaultArgInFrom on the required BASE_IMAGE arg>|
s|^ \{0,1\}[0-9][0-9]* warnings\{0,1\} found (use docker --debug to expand):$|<builder-image lint: InvalidDefaultArgInFrom on the required BASE_IMAGE arg>|
s|^ \{0,1\}- InvalidDefaultArgInFrom: .*$|<builder-image lint: InvalidDefaultArgInFrom on the required BASE_IMAGE arg>|
s|^runit: .*: start action denied by policy-rc\.d$|runit: <SERVICE>: start action denied by policy-rc.d|
s|^Running in chroot, ignoring command '.*'$|Running in chroot, ignoring command '<COMMAND>'|
NORMALIZE
}


# ---------------------------------------------------------------------------
# load_census — populate CENSUS_DISPOSITION[sig] and CENSUS_LIMIT[sig].
#
# The census is markdown on purpose (it is the document a human reviews), so the
# parse is deliberately strict: a row that does not match the frozen column shape
# is a parse error, never a silently skipped allowlist entry.
# ---------------------------------------------------------------------------
declare -A CENSUS_DISPOSITION=()
declare -A CENSUS_LIMIT=()

load_census() {
  [[ -f "${CENSUS}" ]] || die "census not found: ${CENSUS}"
  local line table="" sig count disp
  while IFS= read -r line; do
    case "${line}" in
      '| # | Signature | Baseline | Stage | Owner | Disposition | Note |') table="baseline"; continue ;;
      '| Signature | Max | Stage | Introduced by | Rationale |')            table="postfix";  continue ;;
      '|'*) ;;
      *) table=""; continue ;;
    esac
    [[ -n "${table}" ]] || continue
    [[ "${line}" =~ ^\|[[:space:]]*:?-{2,} ]] && continue

    if [[ "${table}" == "baseline" ]]; then
      [[ "${line}" =~ ^\|[[:space:]]*[0-9]+[[:space:]]*\|[[:space:]]*\`(.*)\`[[:space:]]*\|[[:space:]]*([0-9]+)[[:space:]]*\|[^|]*\|[^|]*\|[[:space:]]*([A-Z]+)[[:space:]]*\| ]] \
        || die "unparseable baseline census row: ${line}"
      sig="${BASH_REMATCH[1]}"; count="${BASH_REMATCH[2]}"; disp="${BASH_REMATCH[3]}"
    else
      [[ "${line}" =~ ^\|[[:space:]]*\`(.*)\`[[:space:]]*\|[[:space:]]*([0-9]+)[[:space:]]*\| ]] \
        || die "unparseable post-fix census row: ${line}"
      sig="${BASH_REMATCH[1]}"; count="${BASH_REMATCH[2]}"; disp="POSTFIX"
    fi

    [[ -z "${CENSUS_DISPOSITION[${sig}]:-}" ]] || die "duplicate census signature: ${sig}"
    CENSUS_DISPOSITION["${sig}"]="${disp}"
    CENSUS_LIMIT["${sig}"]="${count}"
  done <"${CENSUS}"

  (( ${#CENSUS_DISPOSITION[@]} > 0 )) || die "census parsed to zero signatures: ${CENSUS}"
}

# ---------------------------------------------------------------------------
# check_log <file> — 0 when the log is within the census, 1 otherwise.
# ---------------------------------------------------------------------------
check_log() {
  local log="$1"
  [[ -f "${log}" ]] || die "no such build log: ${log}"

  local -A seen=()
  local sig
  while IFS= read -r sig; do
    [[ -n "${sig}" ]] || continue
    seen["${sig}"]=$(( ${seen["${sig}"]:-0} + 1 ))
  done < <(normalize_log "${log}")

  local -a violations=()
  for sig in "${!seen[@]}"; do
    local n="${seen[${sig}]}" disp="${CENSUS_DISPOSITION[${sig}]:-}"
    case "${disp}" in
      "")
        violations+=("NOVEL      x${n}  ${sig}")
        ;;
      BLOCKING)
        violations+=("BLOCKING   x${n}  ${sig}")
        ;;
      FIXED)
        violations+=("REGRESSED  x${n}  ${sig}")
        ;;
      ACCEPTED|POSTFIX)
        local limit="${CENSUS_LIMIT[${sig}]}"
        if (( n > limit )); then
          violations+=("OVER-LIMIT x${n} (max ${limit})  ${sig}")
        fi
        ;;
      *)
        violations+=("BAD-DISPOSITION '${disp}'  ${sig}")
        ;;
    esac
  done

  if (( ${#violations[@]} > 0 )); then
    printf 'FAIL %s\n' "${log}" >&2
    printf '  %s\n' "${violations[@]}" | sort >&2
    printf '  census: %s\n' "${CENSUS}" >&2
    return 1
  fi

  printf 'OK   %s (%d distinct signature(s), all within census)\n' "${log}" "${#seen[@]}"
  return 0
}

census_report() {
  local log="$1"
  [[ -f "${log}" ]] || die "no such build log: ${log}"
  normalize_log "${log}" | sort | uniq -c | sort -k2
}

# ---------------------------------------------------------------------------
# self_test — prove the lint is NON-VACUOUS against committed fixtures.
#
# A lint that accepts everything also "passes" every real log, so the clean and
# known fixtures alone prove nothing. The novel/regressed/over-limit fixtures are
# what establish that a pass means something.
# ---------------------------------------------------------------------------
self_test() {
  local failures=0
  expect() {
    local want="$1" name="$2"; shift 2
    local got=0
    "$@" >/dev/null 2>&1 || got=$?
    if [[ "${got}" == "${want}" ]]; then
      printf 'self-test ok   %-34s (exit %s)\n' "${name}" "${got}"
    else
      printf 'self-test FAIL %-34s (exit %s, wanted %s)\n' "${name}" "${got}" "${want}" >&2
      failures=$(( failures + 1 ))
    fi
  }

  local f
  for f in clean.log known-accepted.log novel.log builder-image.log; do
    [[ -f "${FIXTURE_DIR}/${f}" ]] || die "missing fixture: ${FIXTURE_DIR}/${f}"
  done

  expect 0 "clean log"              check_log "${FIXTURE_DIR}/clean.log"
  expect 0 "known accepted log"     check_log "${FIXTURE_DIR}/known-accepted.log"
  expect 1 "novel signature"        check_log "${FIXTURE_DIR}/novel.log"
  expect 0 "builder-image + chroot"  check_log "${FIXTURE_DIR}/builder-image.log"

  # Generated, not committed: these prove the two failure modes a static fixture
  # set would silently stop covering if a disposition were re-labelled.
  local tmp
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064  # expand tmp now, on purpose
  trap "rm -rf '${tmp}'" RETURN

  # The delete-vs-collapse decision in LINE_PREFIX_RULES, driven in BOTH
  # directions on ONE line of text. Deleting BuildKit's step prefix instead of
  # rewriting it to `<builder> ` makes these two logs identical, and the pair
  # then cannot both hold: row 5 is FIXED, so the device-layer form MUST fail,
  # while a builder image installing automake into a manpage-less slim base MUST
  # pass. Without this pair the "simplification" reds every clean release build.
  local alt_line='update-alternatives: warning: skip creation of /usr/share/man/man1/lzma.1.gz because associated file /usr/share/man/man1/xz.1.gz (of link group lzma) doesn'"'"'t exist'
  printf '%s\n' "${alt_line}" >"${tmp}/device-alternatives.log"
  expect 1 "device-layer alternatives (FIXED)" check_log "${tmp}/device-alternatives.log"
  printf '#5 24.35 %s\n' "${alt_line}" >"${tmp}/builder-alternatives.log"
  expect 0 "builder-image alternatives"        check_log "${tmp}/builder-alternatives.log"

  # BuildKit paints its lint summary with SGR codes, so the anchor only ever
  # sees that block if step 1 strips them. A fixture cannot carry raw ESC bytes
  # reviewably, hence the generated leg.
  local esc=$'\033' lint_sig='<builder-image lint: InvalidDefaultArgInFrom on the required BASE_IMAGE arg>'
  {
    printf '#1 WARN: InvalidDefaultArgInFrom: Default value for ARG ${BASE_IMAGE} results in empty or invalid base image name (line 21)\n'
    printf ' %s[33m1 warning found (use docker --debug to expand):\n' "${esc}"
    printf '%s[0m - InvalidDefaultArgInFrom: Default value for ARG ${BASE_IMAGE} results in empty or invalid base image name (line 21)\n' "${esc}"
  } >"${tmp}/buildkit-lint.log"
  expect 0 "buildkit lint block (SGR)" check_log "${tmp}/buildkit-lint.log"
  local lint_seen
  lint_seen="$(normalize_log "${tmp}/buildkit-lint.log" | sort -u)"
  if [[ "${lint_seen}" == "${lint_sig}" ]]; then
    printf 'self-test ok   %-34s (exit 0)\n' "buildkit lint collapses to 1 sig"
  else
    printf 'self-test FAIL %-34s (got %s)\n' "buildkit lint collapses to 1 sig" "${lint_seen}" >&2
    failures=$(( failures + 1 ))
  fi

  local fixed_sig accepted_sig accepted_limit
  fixed_sig="$(first_signature_with FIXED)"
  accepted_sig="$(first_signature_with ACCEPTED)"
  accepted_limit="${CENSUS_LIMIT[${accepted_sig}]}"

  printf '%s\n' "${fixed_sig}" >"${tmp}/regressed.log"
  expect 1 "FIXED signature regressed" check_log "${tmp}/regressed.log"

  local i
  : >"${tmp}/over-limit.log"
  for (( i = 0; i <= accepted_limit; i++ )); do
    printf '%s\n' "${accepted_sig}" >>"${tmp}/over-limit.log"
  done
  expect 1 "ACCEPTED count inflated"   check_log "${tmp}/over-limit.log"

  # …and the paired control: exactly the baseline count is still fine, so the
  # case above fails on the INFLATION rather than on the signature.
  : >"${tmp}/at-limit.log"
  for (( i = 0; i < accepted_limit; i++ )); do
    printf '%s\n' "${accepted_sig}" >>"${tmp}/at-limit.log"
  done
  expect 0 "ACCEPTED at exact baseline" check_log "${tmp}/at-limit.log"

  if (( failures > 0 )); then
    printf 'self-test: %d case(s) failed\n' "${failures}" >&2
    return 1
  fi
  printf 'self-test: all cases passed\n'
  return 0
}

# The normalizer replaces variable substrings, so a census signature is only
# usable as a synthetic log line when it survives its own normalization. Pick the
# first one that does, rather than hardcoding a row number the census may renumber.
first_signature_with() {
  local want="$1" sig tmp
  tmp="$(mktemp)"
  for sig in "${!CENSUS_DISPOSITION[@]}"; do
    [[ "${CENSUS_DISPOSITION[${sig}]}" == "${want}" ]] || continue
    printf '%s\n' "${sig}" >"${tmp}"
    if [[ "$(normalize_log "${tmp}")" == "${sig}" ]]; then
      rm -f "${tmp}"
      printf '%s\n' "${sig}"
      return 0
    fi
  done
  rm -f "${tmp}"
  die "no ${want} census signature survives normalization — the self-test cannot be non-vacuous"
}

main() {
  local mode="check"
  local -a logs=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --self-test)     mode="self-test"; shift ;;
      --census-report) mode="report"; shift ;;
      -h|--help)       usage; exit 0 ;;
      -*)              usage; die "unknown option: $1" ;;
      *)               logs+=("$1"); shift ;;
    esac
  done

  load_census

  case "${mode}" in
    self-test) self_test ;;
    report)
      (( ${#logs[@]} == 1 )) || die "--census-report takes exactly one log"
      census_report "${logs[0]}"
      ;;
    check)
      (( ${#logs[@]} > 0 )) || { usage; die "no build log given"; }
      local rc=0 log
      for log in "${logs[@]}"; do
        check_log "${log}" || rc=1
      done
      return "${rc}"
      ;;
  esac
}

main "$@"
