#!/usr/bin/env bash
#
# backup-data.sh — preservation-safe backup and restore of the device `/data`
# partition, for the physical deployment path's restore rehearsal.
#
# `/data` is the ONLY partition a full re-flash destroys that the device cannot
# rebuild: WiFi credentials, the SSH host identity, the machine-id, the CeraUI
# working tree, the hostname index. So the physical path is only a legitimate
# deployment path if a restore has actually been rehearsed on that exact board.
#
# RESTORE IS DESTRUCTIVE, and it is therefore bound by the same
# remote-destructive-write contract as the whole-media flash
# (`ci/destructive-target-guard.sh`): the target must be a LOCAL absolute path,
# and the operator must supply a physical-write confirmation naming that exact
# target. There is no flag that accepts `user@host:/data`, and there is no
# `ssh host 'tar -x'` path — a restore is performed by an operator on the board
# or against a locally-mounted `/data`, never pushed down a pipe.
#
# Usage:
#   backup-data.sh --mode backup  --source <dir> --archive <file>
#   backup-data.sh --mode restore --archive <file> --target <dir> \
#                  --confirm-physical-write I-AM-AT-THE-BENCH:<target>
#   backup-data.sh --mode verify  --archive <file>
#   backup-data.sh --self-test
#
# The archive is a gzip tar plus a co-located `<archive>.sha256` and
# `<archive>.manifest` (one `<mode> <sha256|-> <type> <path>` row per entry).
# Restore verifies BOTH the archive digest and, after extraction, every entry in
# the manifest — a restore that silently dropped a file is the failure this
# rehearsal exists to catch.
#
# Exit codes: 0 ok, 1 refused/failed, 2 usage.
#
# shellcheck shell=bash

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci/destructive-target-guard.sh
source "${HERE}/destructive-target-guard.sh"

usage() { sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die()   { printf 'backup-data: %s\n' "$*" >&2; exit 1; }

# emit_manifest <root> — a stable, sorted inventory of everything under <root>.
# Content hash for regular files, link target for symlinks, mode+type for all,
# so an inventory comparison catches a lost mode or a dereferenced symlink as
# well as lost bytes.
emit_manifest() {
  local root="$1" path rel type mode digest
  while IFS= read -r -d '' path; do
    rel="${path#"${root}"}"
    rel="${rel#/}"
    [[ -n "${rel}" ]] || continue
    mode="$(stat -c '%a' "${path}")"
    if [[ -L "${path}" ]]; then
      type=symlink
      digest="$(readlink -- "${path}")"
    elif [[ -d "${path}" ]]; then
      type=dir
      digest='-'
    elif [[ -f "${path}" ]]; then
      type='file'
      digest="$(sha256sum -- "${path}" | cut -d' ' -f1)"
    else
      type=other
      digest='-'
    fi
    printf '%s %s %s %s\n' "${mode}" "${digest}" "${type}" "${rel}"
  done < <(find "${root}" -mindepth 1 -print0 | sort -z) 
}

do_backup() {
  local source="$1" archive="$2"
  guard_assert_local_target 'backup source' "${source}" || exit 1
  guard_assert_local_target 'backup archive' "${archive}" || exit 1
  [[ -d "${source}" ]] || die "backup source is not a directory: ${source}"
  [[ -d "$(dirname -- "${archive}")" ]] || die "archive directory does not exist"

  emit_manifest "${source}" >"${archive}.manifest" \
    || die "could not inventory ${source}"
  tar --numeric-owner --preserve-permissions --sort=name -czf "${archive}" \
    -C "${source}" . || die "could not create ${archive}"
  sha256sum "${archive}" | cut -d' ' -f1 >"${archive}.sha256"
  printf 'BACKUP ok source=%s archive=%s entries=%s sha256=%s\n' \
    "${source}" "${archive}" "$(wc -l <"${archive}.manifest")" "$(<"${archive}.sha256")"
}

do_verify() {
  local archive="$1" recorded actual
  guard_assert_local_target 'backup archive' "${archive}" || exit 1
  [[ -f "${archive}" ]] || die "archive not found: ${archive}"
  [[ -s "${archive}.sha256" ]] || die "archive digest sidecar missing: ${archive}.sha256"
  [[ -s "${archive}.manifest" ]] || die "archive manifest missing: ${archive}.manifest"
  recorded="$(<"${archive}.sha256")"
  actual="$(sha256sum "${archive}" | cut -d' ' -f1)"
  [[ "${recorded}" == "${actual}" ]] \
    || die "archive digest mismatch: recorded ${recorded}, got ${actual}"
  tar -tzf "${archive}" >/dev/null 2>&1 || die "archive is not a readable tar.gz"
  printf 'VERIFY ok archive=%s sha256=%s\n' "${archive}" "${actual}"
}

do_restore() {
  local archive="$1" target="$2" token="$3" restored
  guard_assert_local_target 'restore target' "${target}" || exit 1
  guard_assert_local_target 'backup archive' "${archive}" || exit 1
  guard_require_physical_confirmation 'data restore' "${target}" "${token}" || exit 1

  do_verify "${archive}" >/dev/null || exit 1
  [[ -d "${target}" ]] || die "restore target is not a directory: ${target}"

  tar --numeric-owner --preserve-permissions -xzf "${archive}" -C "${target}" \
    || die "restore extraction failed"
  restored="$(mktemp)"
  emit_manifest "${target}" >"${restored}"
  if ! diff -u "${archive}.manifest" "${restored}" >/dev/null; then
    printf 'RESTORE mismatch (recorded vs restored):\n' >&2
    diff -u "${archive}.manifest" "${restored}" >&2 || true
    rm -f "${restored}"
    die "restored tree does not match the backup inventory"
  fi
  rm -f "${restored}"
  printf 'RESTORE ok archive=%s target=%s entries=%s\n' \
    "${archive}" "${target}" "$(wc -l <"${archive}.manifest")"
}

# ---------------------------------------------------------------------------
# self-test — a synthetic /data-shaped tree, never a real board. Proves the
# round trip AND four distinct refusals; a self-test that only walks the happy
# path would pass with every guard deleted.
# ---------------------------------------------------------------------------
self_test() {
  local root failures=0 out rc
  root="$(mktemp -d)"
  local src="${root}/data" dst="${root}/restored" archive="${root}/data-backup.tar.gz"
  local token="${GUARD_PHYSICAL_CONFIRMATION_PREFIX}:${dst}"

  mkdir -p "${src}/ceralive/ssh/ci-access" "${src}/ceralive/tls" "${src}/log/journal" \
    "${dst}"
  printf 'ceralive2\n' >"${src}/ceralive/host_index"
  printf '{"bitrate":6000}\n' >"${src}/ceralive/config.json"
  printf 'secret-host-key\n' >"${src}/ceralive/ssh/host_ed25519_key"
  chmod 600 "${src}/ceralive/ssh/host_ed25519_key"
  printf 'cert\n' >"${src}/ceralive/tls/device.crt"
  printf 'unicode ✓ payload\n' >"${src}/ceralive/notes-ünicode.txt"
  head -c 4096 /dev/zero >"${src}/log/journal/system.journal"
  ln -s /var/www/ceralive "${src}/ceralive/public"

  ok() { printf '  ok   %s\n' "$*"; }
  bad() { printf '  FAIL %s\n' "$*" >&2; failures=$((failures + 1)); }

  if out="$(do_backup "${src}" "${archive}" 2>&1)"; then
    ok "backup of a synthetic /data tree: ${out##*archive=}"
  else
    bad "backup failed: ${out}"
  fi

  out="$(do_restore "${archive}" "${dst}" "${token}" 2>&1)"; rc=$?
  if (( rc == 0 )); then
    ok 'restore round-trip reproduces the recorded inventory exactly'
  else
    bad "restore round-trip failed: ${out}"
  fi
  if [[ "$(readlink "${dst}/ceralive/public")" == /var/www/ceralive ]]; then
    ok 'restore preserves the frontend public symlink as a symlink'
  else
    bad 'restore did not preserve the public symlink'
  fi
  if [[ "$(stat -c '%a' "${dst}/ceralive/ssh/host_ed25519_key")" == 600 ]]; then
    ok 'restore preserves mode 0600 on the persisted host key'
  else
    bad 'restore lost the 0600 mode on the persisted host key'
  fi

  out="$(do_restore "${archive}" "root@192.0.2.10:/data" "${token}" 2>&1)"; rc=$?
  if (( rc != 0 )) && grep -q 'REFUSED' <<<"${out}"; then
    ok 'restore REFUSES a remote user@host:/path target'
  else
    bad "remote user@host restore target was accepted (rc=${rc})"
  fi

  out="$(do_restore "${archive}" "192.0.2.10:/data" \
    "${GUARD_PHYSICAL_CONFIRMATION_PREFIX}:192.0.2.10:/data" 2>&1)"; rc=$?
  if (( rc != 0 )) && grep -q 'REFUSED' <<<"${out}"; then
    ok 'restore REFUSES a bare host:/path target even with a matching token'
  else
    bad "remote host:/path restore target was accepted (rc=${rc})"
  fi

  out="$(do_restore "${archive}" "${dst}" '' 2>&1)"; rc=$?
  if (( rc != 0 )) && grep -q 'physical-write confirmation' <<<"${out}"; then
    ok 'restore REFUSES a local target with no physical-write confirmation'
  else
    bad "unconfirmed restore was accepted (rc=${rc})"
  fi

  out="$(do_restore "${archive}" "${dst}" \
    "${GUARD_PHYSICAL_CONFIRMATION_PREFIX}:${root}/somewhere-else" 2>&1)"; rc=$?
  if (( rc != 0 )) && grep -q 'does not name this target' <<<"${out}"; then
    ok 'restore REFUSES a confirmation captured for a different target'
  else
    bad "a confirmation naming another target was accepted (rc=${rc})"
  fi

  printf 'corrupted\n' >>"${archive}"
  out="$(do_restore "${archive}" "${dst}" "${token}" 2>&1)"; rc=$?
  if (( rc != 0 )) && grep -q 'archive digest mismatch' <<<"${out}"; then
    ok 'restore REFUSES an archive whose digest no longer matches'
  else
    bad "corrupted archive was restored (rc=${rc})"
  fi

  rm -rf "${root}"
  if (( failures == 0 )); then
    printf 'backup-data self-test: PASS (round trip + 5 refusals)\n'
    return 0
  fi
  printf 'backup-data self-test: FAIL (%s leg(s))\n' "${failures}" >&2
  return 1
}

main() {
  local mode="" source="" archive="" target="" token=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode)    mode="${2:-}"; shift 2 ;;
      --source)  source="${2:-}"; shift 2 ;;
      --archive) archive="${2:-}"; shift 2 ;;
      --target)  target="${2:-}"; shift 2 ;;
      --confirm-physical-write) token="${2:-}"; shift 2 ;;
      --self-test) mode="self-test"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) printf 'unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
  done

  case "${mode}" in
    self-test) self_test; exit $? ;;
    backup)
      [[ -n "${source}" && -n "${archive}" ]] || { printf -- '--source and --archive are required\n' >&2; exit 2; }
      do_backup "${source}" "${archive}" ;;
    restore)
      [[ -n "${archive}" && -n "${target}" ]] || { printf -- '--archive and --target are required\n' >&2; exit 2; }
      do_restore "${archive}" "${target}" "${token}" ;;
    verify)
      [[ -n "${archive}" ]] || { printf -- '--archive is required\n' >&2; exit 2; }
      do_verify "${archive}" ;;
    *) printf -- '--mode must be backup, restore or verify\n' >&2; usage >&2; exit 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
