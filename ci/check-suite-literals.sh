#!/usr/bin/env bash
#
# check-suite-literals.sh — the regression guard for the ONE target-release
# mapping (manifests/target-release.env).
#
# suite-literal-ok(file): the hunter has to spell the literals it hunts — they are
# in SUITE_LITERAL_RE, in the operator-facing failure text and in the self-test
# fixtures. There is no way to write this gate without them.
#
# WHY: the target Debian suite and its os-release VERSION_ID used to be spelled
# out independently in ten places. Every one of those sites now derives from the
# mapping — but "derives" is a property nothing enforces, and the failure mode of
# a re-introduced literal is invisible: the image BUILDS, it BOOTS, and it is
# simply wrong (apt sources naming the previous suite, or a sysext the kernel
# silently refuses to merge because its VERSION_ID no longer matches the host).
# So the derivation is a GATE, not a convention.
#
# TWO CHECKS, and they catch different things:
#
#   [1/2] LITERAL SWEEP — no production file may carry a `bookworm` or a
#         `VERSION_ID=12` literal unless that occurrence is explicitly
#         ANNOTATED with a reason. This is what catches a NEW hardcode.
#
#   [2/2] MIRROR DRIFT — the handful of places that cannot read a shell/Python
#         file at all (mkosi's `[Distribution] Release=`, the add-on JSON Schema
#         `const`, the add-on descriptors) carry a mirrored value. Each is
#         compared against what the mapping DECLARES. This is what catches a
#         mapping bump that forgot a mirror.
#
# ANNOTATION FORMS — a legitimate literal states why, in the file, next to itself:
#
#   <anything>   # suite-literal-ok: <reason>      same line
#   # suite-literal-ok: <reason>                   the line IMMEDIATELY above
#                                                  (for data rows that cannot
#                                                  carry a trailing comment)
#   # suite-literal-ok(file): <reason>             anywhere in the file; exempts
#                                                  the WHOLE file. Reserved for
#                                                  upstream-provenance files
#                                                  whose every mention is a
#                                                  third-party pool/suite name.
#
# An annotation with an EMPTY reason is rejected — the point is the reason, not
# the marker.
#
# SCOPE: every tracked file, minus the exclusions in EXCLUDED_PATH_RES, each of
# which carries its own stated reason. Documentation is excluded because a
# historical note about bookworm is CORRECT and must stay readable.
#
# USAGE
#   ci/check-suite-literals.sh              run both checks (the gate)
#   ci/check-suite-literals.sh --list       print every literal it accepted, with
#                                           the annotation that accepted it
#   ci/check-suite-literals.sh --self-test  prove the gate has teeth (both
#                                           directions, in a scratch tree)
#
# Exit codes: 0 clean · 1 violation(s) found · 2 usage/local error.
#
# shellcheck shell=bash

set -uo pipefail

HERE="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="${CERALIVE_SUITE_AUDIT_ROOT:-$(CDPATH='' cd -- "${HERE}/.." && pwd)}"

# shellcheck source=../lib/shared/target-release-lib.sh
source "${HERE}/../lib/shared/target-release-lib.sh"

# The literals a production file may not carry unannotated. `bookworm` is the
# retired suite name; the VERSION_ID form matches `VERSION_ID=12`, `VERSION_ID="12"`
# and `SYSEXT_OS_VERSION_ID=12` alike, in shell, JSON and os-release syntax.
SUITE_LITERAL_RE='bookworm|VERSION_ID[[:space:]]*=[[:space:]]*"?12"?|"versionId"[[:space:]]*:[[:space:]]*"12"'

ANNOTATION_RE='suite-literal-ok:[[:space:]]*[^[:space:]]'
FILE_ANNOTATION_RE='suite-literal-ok\(file\):[[:space:]]*[^[:space:]]'

# Paths the sweep does not read. Each entry is a POSIX ERE matched against the
# repo-relative path, and each one is a decision:
#
#   docs/, *.md   Documentation. A historical note naming bookworm is CORRECT —
#                 the effort's own record of what the image used to target — and
#                 rewriting history to satisfy a lint is worse than the lint.
#   tests/        Test fixtures deliberately model BOTH suites: several suites
#                 seed a wrong-suite input precisely to prove a consumer rejects
#                 or rewrites it. Their config-surface expectations are pinned by
#                 the suites themselves, not by this sweep.
#   manifests/packages/
#                 Package lists and their removal ledger. Every mention there is
#                 prose about which Debian release ships which package, and that
#                 surface belongs to the package-list migration — this gate must
#                 not collide with it. EXPANSION POINT: drop this entry once that
#                 migration lands, and annotate what survives.
#   mkosi/build/, mkosi/cache/, mkosi/.staging/, images/, .mkosi-workspace/
#                 Generated build output; never sources of truth.
EXCLUDED_PATH_RES=(
  '^docs/'
  '\.md$'
  '^tests/'
  '^manifests/packages/'
  '^mkosi/(build|cache|\.staging)/'
  '^images/'
  '^\.mkosi-workspace/'
)

note()  { printf 'check-suite-literals: %s\n' "$*"; }
fail()  { printf 'check-suite-literals: %s\n' "$*" >&2; }

path_excluded() {
  local rel="$1" re
  for re in "${EXCLUDED_PATH_RES[@]}"; do
    [[ "${rel}" =~ ${re} ]] && return 0
  done
  return 1
}

# Every file the sweep reads: tracked files PLUS untracked-but-not-ignored ones.
#
# Both halves matter. Going through git at all is what keeps gitignored build
# output (a whole `bookworm` rootfs tree under mkosi/build/) out of the report —
# an audit that fires on throwaway files trains people to ignore it. Including
# `--others --exclude-standard` is what makes this usable BEFORE `git add`: a
# newly written file carrying a fresh hardcode is exactly what the gate exists to
# catch, and a tracked-only sweep would pass it right up until it was committed.
audit_files() {
  local rel
  while IFS= read -r rel; do
    [[ -n "${rel}" ]] || continue
    path_excluded "${rel}" && continue
    [[ -f "${PIPELINE_DIR}/${rel}" ]] || continue
    printf '%s\n' "${rel}"
  done < <(git -C "${PIPELINE_DIR}" ls-files --cached --others --exclude-standard 2>/dev/null | sort -u)
}

# ---------------------------------------------------------------------------
# check_literals [--list] — [1/2] the sweep.
# ---------------------------------------------------------------------------
check_literals() {
  local list_mode="${1:-}" rel violations=0 accepted=0

  while IFS= read -r rel; do
    local abs="${PIPELINE_DIR}/${rel}"
    grep -Eq "${SUITE_LITERAL_RE}" -- "${abs}" 2>/dev/null || continue

    if grep -Eq "${FILE_ANNOTATION_RE}" -- "${abs}"; then
      accepted=$((accepted + 1))
      [[ "${list_mode}" == "--list" ]] \
        && printf '  file-exempt  %s\n' "${rel}"
      continue
    fi

    local lineno line prev
    while IFS=: read -r lineno line; do
      [[ -n "${lineno}" ]] || continue
      # The annotation is on the offending line, or on the line above it (the
      # only placement a data row can use).
      prev=""
      (( lineno > 1 )) && prev="$(sed -n "$((lineno - 1))p" -- "${abs}")"
      if [[ "${line}" =~ ${ANNOTATION_RE} || "${prev}" =~ ${ANNOTATION_RE} ]]; then
        accepted=$((accepted + 1))
        [[ "${list_mode}" == "--list" ]] \
          && printf '  annotated    %s:%s\n' "${rel}" "${lineno}"
        continue
      fi
      violations=$((violations + 1))
      fail "unannotated target-release literal: ${rel}:${lineno}: ${line}"
    done < <(grep -nE "${SUITE_LITERAL_RE}" -- "${abs}")
  done < <(audit_files)

  if (( violations > 0 )); then
    fail "[1/2] literal sweep: ${violations} unannotated literal(s)."
    fail "      Derive the value from manifests/target-release.env, or annotate the"
    fail "      line with '# suite-literal-ok: <reason>' if it is genuinely not the"
    fail "      target release (an Armbian BSP suite, an upstream pool name, a"
    fail "      historical note)."
    return 1
  fi
  note "[1/2] literal sweep clean (${accepted} annotated/exempt occurrence(s))"
  return 0
}

# ---------------------------------------------------------------------------
# check_mirrors — [2/2] the drift check.
#
# Reads the DECLARED values (target_release_declared runs under `env -i`), so an
# exported RELEASE in the caller's shell cannot mask a mirror that has drifted.
# ---------------------------------------------------------------------------
check_mirrors() {
  local release version_id drift=0 got

  release="$(target_release_declared RELEASE)"        || return 2
  version_id="$(target_release_declared OS_VERSION_ID)" || return 2

  mirror() {
    local label="$1" expected="$2" actual="$3"
    if [[ "${actual}" != "${expected}" ]]; then
      fail "mirror drift: ${label} is '${actual}' but manifests/target-release.env declares '${expected}'"
      drift=$((drift + 1))
    fi
  }

  local mkosi_conf="${PIPELINE_DIR}/mkosi/mkosi.conf"
  if [[ -r "${mkosi_conf}" ]]; then
    got="$(sed -n 's/^Release=//p' -- "${mkosi_conf}" | head -n1)"
    mirror "mkosi/mkosi.conf [Distribution] Release=" "${release}" "${got}"
  fi

  local schema="${PIPELINE_DIR}/manifests/schema/addon.schema.json"
  if [[ -r "${schema}" ]]; then
    got="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["properties"]["versionId"].get("const",""))' "${schema}")" \
      || { fail "cannot read versionId.const from ${schema}"; return 2; }
    mirror "manifests/schema/addon.schema.json properties.versionId.const" "${version_id}" "${got}"
  fi

  local descriptor
  for descriptor in "${PIPELINE_DIR}"/manifests/addons/*.json; do
    [[ -r "${descriptor}" ]] || continue
    local rel="${descriptor#"${PIPELINE_DIR}"/}"
    got="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("versionId",""))' "${descriptor}")" \
      || { fail "cannot read versionId from ${rel}"; return 2; }
    mirror "${rel} versionId" "${version_id}" "${got}"
    while IFS= read -r got; do
      [[ -n "${got}" ]] || continue
      mirror "${rel} compatibleOsVersions[]" "${version_id}" "${got}"
    done < <(python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
print("\n".join(d.get("compatibleOsVersions") or []))' "${descriptor}")
    got="$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
print((d.get("conditions") or {}).get("min_os_version",""))' "${descriptor}")"
    [[ -n "${got}" ]] && mirror "${rel} conditions.min_os_version" "${version_id}" "${got}"
  done

  if (( drift > 0 )); then
    fail "[2/2] mirror drift: ${drift} site(s) disagree with the mapping."
    return 1
  fi
  note "[2/2] every mirrored literal agrees with the mapping (release=${release} version_id=${version_id})"
  return 0
}

# ---------------------------------------------------------------------------
# self_test — prove the gate has teeth, in BOTH directions.
#
# A gate that can only ever pass is worse than no gate: it reports success on a
# tree it never actually read. Each leg therefore runs the REAL functions against
# a scratch git tree and asserts the expected verdict.
# ---------------------------------------------------------------------------
self_test() {
  local failures=0 tmp
  tmp="$(mktemp -d)" || { fail "mktemp -d failed"; return 2; }
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  check() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then printf '  ok   %s\n' "${label}"
    else printf '  FAIL %s\n' "${label}"; failures=$((failures + 1)); fi
  }
  check_fails() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then
      printf '  FAIL %s (expected a violation, got a pass)\n' "${label}"
      failures=$((failures + 1))
    else
      printf '  ok   %s\n' "${label}"
    fi
  }

  local root="${tmp}/repo"
  mkdir -p "${root}/manifests/schema" "${root}/manifests/addons" "${root}/mkosi" "${root}/docs"
  cp "${PIPELINE_DIR}/manifests/target-release.env" "${root}/manifests/target-release.env"
  printf '[Distribution]\nRelease=trixie\n' >"${root}/mkosi/mkosi.conf"
  printf '{"properties":{"versionId":{"const":"13"}}}\n' >"${root}/manifests/schema/addon.schema.json"
  printf '{"id":"x","versionId":"13","compatibleOsVersions":["13"],"conditions":{"min_os_version":"13"}}\n' \
    >"${root}/manifests/addons/x.json"
  printf 'Historically the image targeted bookworm (VERSION_ID=12).\n' >"${root}/docs/history.md"
  git -C "${root}" init -q                >/dev/null 2>&1
  git -C "${root}" add -A                 >/dev/null 2>&1

  run_audit() { CERALIVE_SUITE_AUDIT_ROOT="${root}" bash "${BASH_SOURCE[0]}" "$@"; }

  check "a clean tree passes both checks" run_audit

  # Leg: an unannotated literal in a production file is caught. This is the
  # NON-VACUITY leg — without it, a sweep that silently read nothing would pass.
  printf 'APT_SUITE=bookworm\n' >"${root}/mkosi/scratch.conf"
  git -C "${root}" add -A >/dev/null 2>&1
  check_fails "an unannotated 'bookworm' literal is REJECTED" run_audit

  # Leg: the same literal, annotated with a reason, is accepted.
  printf 'APT_SUITE=bookworm  # suite-literal-ok: scratch self-test fixture\n' \
    >"${root}/mkosi/scratch.conf"
  git -C "${root}" add -A >/dev/null 2>&1
  check "the same literal WITH a reason is accepted" run_audit

  # Leg: a marker with no reason is not an annotation.
  printf 'APT_SUITE=bookworm  # suite-literal-ok:\n' >"${root}/mkosi/scratch.conf"
  git -C "${root}" add -A >/dev/null 2>&1
  check_fails "an EMPTY annotation reason is REJECTED" run_audit

  # Leg: the preceding-line form, which is the only one a data row can use.
  printf '# suite-literal-ok: data row cannot carry a trailing comment\nfoo bookworm bar\n' \
    >"${root}/mkosi/scratch.conf"
  git -C "${root}" add -A >/dev/null 2>&1
  check "a preceding-line annotation is accepted" run_audit
  rm -f "${root}/mkosi/scratch.conf"
  git -C "${root}" add -A >/dev/null 2>&1

  # Leg: documentation keeps its historical mentions without annotation.
  check "a historical mention under docs/ is NOT a violation" run_audit

  # Leg: each mirror is compared, and a drifted one fails.
  printf '[Distribution]\nRelease=bookworm  # suite-literal-ok: drift fixture\n' >"${root}/mkosi/mkosi.conf"
  git -C "${root}" add -A >/dev/null 2>&1
  check_fails "a drifted mkosi.conf Release= is REJECTED" run_audit
  printf '[Distribution]\nRelease=trixie\n' >"${root}/mkosi/mkosi.conf"

  printf '{"properties":{"versionId":{"const":"12"}}}\n' >"${root}/manifests/schema/addon.schema.json"
  git -C "${root}" add -A >/dev/null 2>&1
  check_fails "a drifted addon.schema.json versionId.const is REJECTED" run_audit
  printf '{"properties":{"versionId":{"const":"13"}}}\n' >"${root}/manifests/schema/addon.schema.json"

  printf '{"id":"x","versionId":"13","compatibleOsVersions":["12"],"conditions":{"min_os_version":"13"}}\n' \
    >"${root}/manifests/addons/x.json"
  git -C "${root}" add -A >/dev/null 2>&1
  check_fails "a drifted compatibleOsVersions[] entry is REJECTED" run_audit

  if (( failures > 0 )); then
    printf 'check-suite-literals self-test: FAIL (%d)\n' "${failures}" >&2
    return 1
  fi
  printf 'check-suite-literals self-test: PASS\n'
  return 0
}

main() {
  case "${1:-}" in
    --self-test) self_test; exit $? ;;
    --list)      check_literals --list; exit $? ;;
    -h|--help)   sed -n '2,50p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    "")          ;;
    *)           fail "unknown option: $1"; exit 2 ;;
  esac

  local rc=0
  check_literals || rc=1
  check_mirrors  || rc=$?
  if (( rc == 0 )); then
    note "OK — every target-release fact derives from manifests/target-release.env"
  fi
  exit "${rc}"
}

main "$@"
