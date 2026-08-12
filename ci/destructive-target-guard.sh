#!/usr/bin/env bash
#
# destructive-target-guard.sh — the remote-destructive-write contract.
#
# HARD RULE (plan scope, must-not-have): no CeraLive bench tool may perform a
# raw whole-media or whole-tree destructive write whose TARGET is remote. There
# is no `ssh host 'dd of=/dev/mmcblk0'` shaped path, and there must never be one:
# a raw write pushed down an SSH pipe has no capacity check, no readback, no
# operator standing at the board, and a typo in the hostname destroys a machine
# nobody was looking at.
#
# The refusal is STRUCTURAL, not a grep over the source:
#
#   1. Every destructive-write target is parsed by `guard_assert_local_target`,
#      which accepts ONLY an absolute local path. Every remote spelling — SCP
#      `user@host:/path`, bare `host:/path`, `ssh://`, `rsync://`, UNC
#      `//host/share`, or anything carrying whitespace, a newline or a NUL-ish
#      control character — is REFUSED before the caller can reach its writer.
#   2. Every program that performs the write is parsed by
#      `guard_assert_local_command`, which resolves the binary and refuses a
#      remote transport (ssh/scp/rsync/nc/curl/... ) whether it is named
#      directly or hidden behind a same-named wrapper script.
#   3. The write itself may only be issued through
#      `guard_require_physical_confirmation`, which demands an explicit
#      bench-operator token naming THE EXACT target and echoes the physical
#      confirmation line. An unconfirmed destructive write cannot proceed.
#
# The callers route EVERY destructive write through these three, so a future
# "just add a --remote-host flag" cannot bypass them without deleting them —
# which `tests/flash-remote-guard.test.sh` fails on.
#
# shellcheck shell=bash

GUARD_PHYSICAL_CONFIRMATION_PREFIX="I-AM-AT-THE-BENCH"

# Remote transports. A destructive write must never be issued through any of
# these, so they are refused as the writer program regardless of how the caller
# spelled the path.
GUARD_REMOTE_TRANSPORTS=(
  ssh scp sftp rsh rcp rlogin rexec rsync sshpass ssh-copy-id autossh
  telnet nc ncat netcat socat curl wget ftp tftp
  docker podman kubectl nsenter lxc-attach adb
)

guard_fail() {
  printf 'destructive-target-guard: REFUSED: %s\n' "$*" >&2
  return 1
}

# guard_assert_local_target <label> <value>
#
# Accepts an absolute local path and nothing else. Returns 0 on accept.
guard_assert_local_target() {
  local label="$1" value="${2-}"

  [[ -n "${value}" ]] || { guard_fail "${label} is empty"; return 1; }

  # A control character (newline, tab, CR, ESC...) in a target is never a real
  # device path; it is how an argument is smuggled past a later word-split.
  if [[ "${value}" =~ [[:cntrl:]] ]]; then
    guard_fail "${label} contains a control character"
    return 1
  fi
  if [[ "${value}" =~ [[:space:]] ]]; then
    guard_fail "${label} contains whitespace: '${value}'"
    return 1
  fi
  # scheme://host/... — ssh://, rsync://, sftp://, smb://, nfs://, file:// too:
  # a URL is never a block device and accepting file:// would only invite the
  # next scheme to be accepted as well.
  if [[ "${value}" == *://* ]]; then
    guard_fail "${label} is a URL, not a local path: '${value}'"
    return 1
  fi
  # UNC / SMB share.
  if [[ "${value}" == //* ]]; then
    guard_fail "${label} is a network share path: '${value}'"
    return 1
  fi
  # SCP forms: user@host:/path, host:/path, [v6::addr]:/path. A colon anywhere
  # in a destructive target is refused outright — a legitimate local block device
  # or /data directory never contains one, and every remote spelling does.
  if [[ "${value}" == *:* ]]; then
    guard_fail "${label} names a remote target (host:path form): '${value}'"
    return 1
  fi
  if [[ "${value}" == *@* ]]; then
    guard_fail "${label} names a remote target (user@host form): '${value}'"
    return 1
  fi
  if [[ "${value}" != /* ]]; then
    guard_fail "${label} is not an absolute path: '${value}'"
    return 1
  fi
  if [[ "${value}" == *"/../"* || "${value}" == */.. ]]; then
    guard_fail "${label} traverses out of its own path: '${value}'"
    return 1
  fi
  return 0
}

# guard_assert_local_block_device <label> <path>
#
# guard_assert_local_target plus "this really is a local block device". Used by
# any path that writes raw sectors to attached media.
guard_assert_local_block_device() {
  local label="$1" value="${2-}"
  guard_assert_local_target "${label}" "${value}" || return 1
  [[ "${value}" == /dev/* ]] || {
    guard_fail "${label} is not under /dev: '${value}'"
    return 1
  }
  [[ ! -L "${value}" ]] || {
    guard_fail "${label} is a symlink; name the real device node: '${value}'"
    return 1
  }
  return 0
}

# guard_assert_local_command <label> <command>
#
# Resolve the program that will perform the write and refuse a remote transport.
# Two layers, because a wrapper is the obvious way past a name check:
#   (a) the RESOLVED basename may not be a remote transport;
#   (b) if the resolved file is a text script, none of its executed words may be
#       a remote transport either — a shim called `rkdeveloptool` that execs
#       `ssh host dd` is exactly the shape this contract exists to stop.
guard_assert_local_command() {
  local label="$1" value="${2-}" resolved base transport first_line

  [[ -n "${value}" ]] || { guard_fail "${label} is empty"; return 1; }
  if [[ "${value}" =~ [[:cntrl:]] || "${value}" =~ [[:space:]] ]]; then
    guard_fail "${label} is not a single program path: '${value}'"
    return 1
  fi
  if [[ "${value}" == *://* || "${value}" == *:* || "${value}" == *@* ]]; then
    guard_fail "${label} names a remote program: '${value}'"
    return 1
  fi

  resolved="$(command -v -- "${value}" 2>/dev/null || true)"
  [[ -n "${resolved}" ]] || { guard_fail "${label} does not resolve: '${value}'"; return 1; }
  resolved="$(readlink -f -- "${resolved}" 2>/dev/null || printf '%s' "${resolved}")"
  [[ -f "${resolved}" && -x "${resolved}" ]] || {
    guard_fail "${label} is not a local executable file: '${resolved}'"
    return 1
  }

  base="$(basename -- "${resolved}")"
  for transport in "${GUARD_REMOTE_TRANSPORTS[@]}"; do
    [[ "${base}" != "${transport}" ]] || {
      guard_fail "${label} resolves to the remote transport '${base}'"
      return 1
    }
  done

  first_line="$(head -c 2 -- "${resolved}" 2>/dev/null || true)"
  if [[ "${first_line}" == '#!' ]]; then
    if guard_script_invokes_remote_transport "${resolved}"; then
      guard_fail "${label} is a wrapper script that delegates to a remote transport: '${resolved}'"
      return 1
    fi
  fi
  return 0
}

# guard_script_invokes_remote_transport <script> — 0 when the script names a
# remote transport as a bare command WORD (`ssh …`, `/usr/bin/ssh …`, `exec ssh
# …`), which is how a shim called `rkdeveloptool` smuggles the write off-box.
#
# The word test is `(^|[^[:alnum:]_-])<transport>([[:space:]]|$)`: the leading
# class admits a path separator so `/usr/bin/ssh` matches, while excluding `-`
# and `_` keeps `--ssh-identity` and `$ssh_bin` from matching. It is deliberately
# CONSERVATIVE — a real flashing program is a compiled binary with no shebang and
# is never scanned at all, so the only thing a false positive can refuse is a
# shell shim, which has no business being the destructive writer either.
guard_script_invokes_remote_transport() {
  local script="$1" transport
  for transport in "${GUARD_REMOTE_TRANSPORTS[@]}"; do
    if grep -Eq -- "(^|[^[:alnum:]_-])${transport}([[:space:]]|\$)" "${script}"; then
      return 0
    fi
  done
  return 1
}

# guard_require_physical_confirmation <label> <target> <token>
#
# A destructive write requires an operator standing at the board. The token must
# be exactly `I-AM-AT-THE-BENCH:<target>`, so a confirmation captured for one
# device cannot authorise a write to another, and a blanket `--yes` cannot exist.
# On accept it ECHOES the physical-confirmation line, which is the operator-facing
# half of the contract and is captured into the run transcript.
guard_require_physical_confirmation() {
  local label="$1" target="$2" token="${3-}" expected

  guard_assert_local_target "${label} target" "${target}" || return 1
  expected="${GUARD_PHYSICAL_CONFIRMATION_PREFIX}:${target}"
  [[ -n "${token}" ]] || {
    guard_fail "${label} needs an explicit physical-write confirmation (expected '${expected}')"
    return 1
  }
  [[ "${token}" == "${expected}" ]] || {
    guard_fail "${label} physical-write confirmation does not name this target (expected '${expected}')"
    return 1
  }
  printf 'PHYSICAL-WRITE-CONFIRMED %s target=%s\n' "${label}" "${target}"
  return 0
}

# guard_assert_local_evidence_dir <label> <dir>
#
# Rule D: an A-local tool writes evidence only under a local absolute path, and
# NEVER inside another repository's own evidence tree.
guard_assert_local_evidence_dir() {
  local label="$1" value="${2-}"
  guard_assert_local_target "${label}" "${value}" || return 1
  if [[ "${value}" == *"/.omo/evidence/"* || "${value}" == *"/.omo/evidence" ]]; then
    guard_fail "${label} points into another repository's .omo/evidence tree: '${value}'"
    return 1
  fi
  return 0
}
