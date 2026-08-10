#!/usr/bin/env bash
#
# transport.sh — host resolution + SSH/rsync transport for the dev-sync loop.
#
# Sourced (or run) after config.sh. Responsibilities:
#
#   1. RESOLVE the target. Try the mDNS `.local` name FIRST (avahi-resolve, then
#      getent hosts, then ping as last-ditch reachability). On resolution OR ssh
#      failure, fall back to the configured IP. Logs which path was taken.
#
#   2. PREFLIGHT ssh connectivity before any rsync — a fast, batch-mode probe
#      (`ssh -o ConnectTimeout=5 -o BatchMode=yes … true`) so a dead link fails
#      in seconds with a clear message instead of hanging mid-transfer.
#
#   3. WRAP ssh / rsync with safe flags:
#        - rsync uses `--temp-dir` so partial transfers never land in place;
#        - then an ATOMIC remote rename (rsync to `<dest>.dev-sync.tmp`, then
#          `mv -f` into place) so readers never see a half-written file;
#        - `--checksum` for binary pushes (content-addressed, immune to the
#          mtime/size-only heuristic that can skip a rebuilt same-size binary).
#
# DRY_RUN=1 (mirrors dev-push): every ssh/rsync/mv is LOGGED with a [DRY_RUN]
# prefix and NOT executed; resolution logs the planned probe and assumes the
# mDNS candidate so the planned target + commands are fully visible offline.
#
# shellcheck shell=bash

TRANSPORT_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# config.sh sources common.sh and settles every DEV_SYNC_* / SSH_USER / DRY_RUN.
# shellcheck source=config.sh
source "${TRANSPORT_HERE}/config.sh"

# Resolution output (set by resolve_target).
RESOLVED_TARGET=""   # the host/IP transport_ssh + transport_rsync talk to
RESOLVED_VIA=""      # "mdns" | "ip" — which path won

# A preflight escape hatch for environments without a live sshd (offline QA of
# the resolution/fallback logic): set DEV_SYNC_SKIP_SSH_PREFLIGHT=1.
DEV_SYNC_SKIP_SSH_PREFLIGHT="${DEV_SYNC_SKIP_SSH_PREFLIGHT:-0}"

# ---------------------------------------------------------------------------
# _transport_ssh_opts — emit the shared ssh option array (key, port, timeout).
# Callers splice it into their own ssh command line.
# ---------------------------------------------------------------------------
_transport_ssh_opts() {
  local -a opts=(-o ConnectTimeout=5)
  [[ -n "${DEV_SYNC_SSH_KEY}" ]] && opts+=(-i "${DEV_SYNC_SSH_KEY}")
  [[ -n "${DEV_SYNC_SSH_PORT}" && "${DEV_SYNC_SSH_PORT}" != "22" ]] \
    && opts+=(-p "${DEV_SYNC_SSH_PORT}")
  # Operator-supplied extras (e.g. SSH_OPTS="-o StrictHostKeyChecking=accept-new").
  if [[ -n "${SSH_OPTS:-}" ]]; then
    # shellcheck disable=SC2206  # intentional word-split of the env knob
    local -a extra=(${SSH_OPTS})
    opts+=("${extra[@]}")
  fi
  printf '%s\n' "${opts[@]}"
}

# ---------------------------------------------------------------------------
# _resolvable <addr> — true if <addr> resolves/reaches via mDNS or DNS or ping.
# avahi-resolve only answers for .local names; getent/ping cover IPs + DNS.
# ---------------------------------------------------------------------------
_resolvable() {
  local addr="$1"
  if [[ "$addr" == *.local ]] && command -v avahi-resolve >/dev/null 2>&1; then
    # avahi-resolve exits 0 EVEN ON FAILURE (it prints "Failed to resolve …" to
    # stderr and still returns 0). Key on stdout instead: a hit prints "name\tip".
    local out
    out="$(avahi-resolve -4 -n "$addr" 2>/dev/null)" || true
    [[ -n "$out" ]] && return 0
  fi
  getent hosts "$addr" >/dev/null 2>&1 && return 0
  ping -c1 -W1 "$addr" >/dev/null 2>&1 && return 0
  return 1
}

# ---------------------------------------------------------------------------
# ssh_preflight <addr> — batch-mode connectivity probe. Honours DRY_RUN and the
# DEV_SYNC_SKIP_SSH_PREFLIGHT escape hatch. Returns non-zero on a dead link.
# ---------------------------------------------------------------------------
ssh_preflight() {
  local addr="$1"
  local -a opts
  mapfile -t opts < <(_transport_ssh_opts)
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_info "[DRY_RUN] ssh ${opts[*]} -o BatchMode=yes ${SSH_USER}@${addr} true  # preflight"
    return 0
  fi
  if [[ "${DEV_SYNC_SKIP_SSH_PREFLIGHT}" == "1" ]]; then
    log_warn "ssh preflight SKIPPED for ${addr} (DEV_SYNC_SKIP_SSH_PREFLIGHT=1)"
    return 0
  fi
  ssh "${opts[@]}" -o BatchMode=yes "${SSH_USER}@${addr}" true
}

# ---------------------------------------------------------------------------
# resolve_target — pick the address to use. mDNS .local candidate first, then
# the configured IP. A candidate wins when it resolves AND its ssh preflight
# passes; otherwise we fall through to the next. Sets RESOLVED_TARGET/_VIA.
# ---------------------------------------------------------------------------
resolve_target() {
  RESOLVED_TARGET=""
  RESOLVED_VIA=""

  local -a kinds=() addrs=()
  if [[ -n "${DEV_SYNC_TARGET_HOST}" ]]; then
    kinds+=("mdns"); addrs+=("${DEV_SYNC_TARGET_HOST}")
  fi
  if [[ -n "${DEV_SYNC_TARGET_IP}" ]]; then
    kinds+=("ip"); addrs+=("${DEV_SYNC_TARGET_IP}")
  fi
  (( ${#addrs[@]} > 0 )) \
    || die "resolve_target: neither DEV_SYNC_TARGET_HOST nor DEV_SYNC_TARGET_IP is set"

  local i kind addr
  for i in "${!addrs[@]}"; do
    kind="${kinds[$i]}"
    addr="${addrs[$i]}"

    if [[ "${DRY_RUN}" == "1" ]]; then
      log_info "[DRY_RUN] would probe (${kind}) ${addr} via avahi-resolve/getent/ping, then ssh preflight"
      RESOLVED_TARGET="${addr}"
      RESOLVED_VIA="${kind}"
      log_success "[DRY_RUN] resolved target = ${addr} (via ${kind}; first candidate assumed)"
      return 0
    fi

    if ! _resolvable "${addr}"; then
      log_warn "resolve_target: ${kind} candidate '${addr}' did not resolve — trying next"
      continue
    fi
    if ! ssh_preflight "${addr}"; then
      log_warn "resolve_target: ssh preflight to '${addr}' (${kind}) failed — trying next"
      continue
    fi

    RESOLVED_TARGET="${addr}"
    RESOLVED_VIA="${kind}"
    log_success "resolve_target: using ${addr} (via ${kind})"
    return 0
  done

  die "resolve_target: no reachable target (tried: ${addrs[*]}). Check device power/network and .dev-sync.yaml."
}

# ---------------------------------------------------------------------------
# transport_ssh <remote_cmd> — run a remote command on RESOLVED_TARGET. DRY_RUN
# logs the exact ssh invocation instead of executing it.
# ---------------------------------------------------------------------------
transport_ssh() {
  local remote_cmd="$1"
  [[ -n "${RESOLVED_TARGET}" ]] || die "transport_ssh: call resolve_target first"
  local -a opts
  mapfile -t opts < <(_transport_ssh_opts)
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_info "[DRY_RUN] ssh ${opts[*]} ${SSH_USER}@${RESOLVED_TARGET} '${remote_cmd}'"
    return 0
  fi
  # remote_cmd is built by us and is meant to run on the device, not the client.
  # shellcheck disable=SC2029
  ssh "${opts[@]}" "${SSH_USER}@${RESOLVED_TARGET}" "${remote_cmd}"
}

# ---------------------------------------------------------------------------
# _transport_rsync_excludes — emit one --exclude=<glob> per configured ignore.
# ---------------------------------------------------------------------------
_transport_rsync_excludes() {
  local g
  for g in "${DEV_SYNC_IGNORE_GLOBS[@]}"; do
    printf '%s\n' "--exclude=${g}"
  done
}

# ---------------------------------------------------------------------------
# transport_rsync <src> <remote_dest> [--binary]
#   Push <src> to RESOLVED_TARGET:<remote_dest> safely:
#     - rsync into <remote_dest>.dev-sync.tmp using --temp-dir (no partials in
#       place), then atomically `mv -f` it onto <remote_dest>;
#     - --checksum when --binary (rebuilt same-size binaries must NOT be skipped).
#   DRY_RUN logs the rsync + the mv without executing either.
# ---------------------------------------------------------------------------
transport_rsync() {
  local src="$1" remote_dest="$2" mode="${3:-}"
  [[ -n "${RESOLVED_TARGET}" ]] || die "transport_rsync: call resolve_target first"
  [[ -n "${src}" ]]            || die "transport_rsync: missing <src>"
  [[ -n "${remote_dest}" ]]    || die "transport_rsync: missing <remote_dest>"

  local -a rsync_opts=(-a --temp-dir="${DEV_SYNC_REMOTE_TMP}")
  if [[ "${mode}" == "--binary" ]]; then
    rsync_opts+=(--checksum)
  fi

  # Excludes from the ignore globs.
  local -a excludes
  mapfile -t excludes < <(_transport_rsync_excludes)
  (( ${#excludes[@]} > 0 )) && rsync_opts+=("${excludes[@]}")

  # rsync runs over our ssh option set (key/port/timeout).
  local -a ssh_opts
  mapfile -t ssh_opts < <(_transport_ssh_opts)
  rsync_opts+=(-e "ssh ${ssh_opts[*]}")

  local tmp_dest="${remote_dest}.dev-sync.tmp"
  local remote_ref="${SSH_USER}@${RESOLVED_TARGET}"

  if [[ "${DRY_RUN}" == "1" ]]; then
    log_info "[DRY_RUN] rsync ${rsync_opts[*]} ${src} ${remote_ref}:${tmp_dest}"
    log_info "[DRY_RUN] ssh ${ssh_opts[*]} ${remote_ref} 'mv -f ${tmp_dest} ${remote_dest}'  # atomic rename"
    return 0
  fi

  log_info "rsync ${src} → ${remote_ref}:${tmp_dest} (${mode:-mtime/size})"
  rsync "${rsync_opts[@]}" "${src}" "${remote_ref}:${tmp_dest}"
  log_info "atomic rename ${tmp_dest} → ${remote_dest}"
  transport_ssh "mv -f '${tmp_dest}' '${remote_dest}'"
}

# ---------------------------------------------------------------------------
# CLI — sourceable as a library; runnable for QA.
#   transport.sh resolve
#   transport.sh preflight
#   transport.sh push <src> <remote_dest> [--binary]
# ---------------------------------------------------------------------------
_transport_main() {
  local sub="${1:-}"
  shift || true
  case "${sub}" in
    resolve)
      resolve_target
      log_info "RESOLVED_TARGET=${RESOLVED_TARGET} RESOLVED_VIA=${RESOLVED_VIA}"
      ;;
    preflight)
      resolve_target
      ssh_preflight "${RESOLVED_TARGET}"
      log_success "preflight OK → ${SSH_USER}@${RESOLVED_TARGET} (via ${RESOLVED_VIA})"
      ;;
    push)
      [[ $# -ge 2 ]] || die "usage: transport.sh push <src> <remote_dest> [--binary]"
      resolve_target
      transport_rsync "$@"
      ;;
    ""|-h|--help)
      cat >&2 <<EOF
Usage: transport.sh <resolve|preflight|push> [args]
  resolve                         resolve target (mDNS .local first, IP fallback)
  preflight                       resolve + ssh connectivity probe
  push <src> <remote_dest> [--binary]
                                  safe rsync (--temp-dir + atomic rename;
                                  --checksum when --binary)
Env knobs mirror dev-push: DRY_RUN, SSH_USER, REMOTE_EXT_DIR, DEV_SYNC_* (see
config.sh / .dev-sync.yaml.example). DEV_SYNC_SKIP_SSH_PREFLIGHT=1 skips the probe.
EOF
      [[ "${sub}" == "" ]] && return 1 || return 0
      ;;
    *)
      die "transport.sh: unknown subcommand '${sub}' (resolve|preflight|push)"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  _transport_main "$@"
fi
