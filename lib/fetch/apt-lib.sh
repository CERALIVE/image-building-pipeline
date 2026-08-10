#!/usr/bin/env bash
#
# fetch/apt-lib.sh — GENERIC apt transport helpers, shared by every fetch family.
#
# Two things lived twice before this module existed: the isolated apt state the
# BSP and first-party transports both build (so the HOST apt configuration is
# never touched), and the privilege-aware apt sandbox plumbing, which sat in
# `firstparty.sh` even though nothing about it is first-party specific.
#
# Sourced by lib/fetch-debs.sh; not standalone. `run_or_plan` and the loggers come
# from the entry point's common.sh.
#
# shellcheck shell=bash

# ---------------------------------------------------------------------------
# apt_isolated_state_init <apt_state> [extra-dir ...] — create the throwaway apt
# state tree. `lists/partial` and `cache/archives/partial` are apt's own layout;
# it will not run without them. Goes through run_or_plan so a DRY_RUN plan logs
# the mkdir instead of performing it.
# ---------------------------------------------------------------------------
apt_isolated_state_init() {
  local apt_state="$1"; shift
  run_or_plan mkdir -p \
    "${apt_state}/lists/partial" "${apt_state}/cache/archives/partial" "$@"
}

# ---------------------------------------------------------------------------
# apt_isolated_opts <apt_state> <src_list> <arch> — emit, one token per line, the
# apt options that redirect every path apt reads or writes into <apt_state> and
# pin the package architecture. Consume with:
#
#   mapfile -t apt_opts < <(apt_isolated_opts "${apt_state}" "${src_list}" "${ARCH}")
#
# A family that needs more (the first-party mTLS pair) appends to that array; the
# shared six are identical everywhere and are no longer written out twice.
# ---------------------------------------------------------------------------
apt_isolated_opts() {
  local apt_state="$1" src_list="$2" arch="$3"
  printf '%s\n' \
    -o "Dir::Etc::SourceList=${src_list}" \
    -o "Dir::Etc::SourceParts=-" \
    -o "Dir::State::Lists=${apt_state}/lists" \
    -o "Dir::Cache=${apt_state}/cache" \
    -o "Dir::Cache::Archives=${apt_state}/cache/archives" \
    -o "APT::Architecture=${arch}"
}

# ---------------------------------------------------------------------------
# apt sandbox plumbing for the build-time fetch.
#
# apt drops its acquire methods to `_apt` WHENEVER it is invoked as root, so a
# root-owned 0600 client key is unreadable to it — the device-side twin of this
# path already paid for that once (AGENTS.md, "Baked mTLS client key MUST be
# `_apt`-owned"). The old answer was apt's sandbox-user override pinned to root,
# which fixes no permission: it turns the sandbox OFF for the whole build-time
# fetch. That override must never reappear in the emitted apt options — the guard
# greps every fetch module for its literal spelling, so do not write it out even
# in a comment.
#
# Privilege-aware, because unlike the device this runs on the HOST (before any
# container, orchestrate.sh) and is frequently NOT root: as root, hand `_apt`
# the key and a tree it can traverse; unprivileged, apt never drops privileges
# so the invoking user's own credentials are already the right ones; with no
# `_apt` at all the host is non-Debian and the curl fallback owns the path.
# ---------------------------------------------------------------------------
APT_SANDBOX_USER="${APT_SANDBOX_USER:-_apt}"

apt_sandbox_user_exists() {
  if command -v getent >/dev/null 2>&1; then
    getent passwd "${APT_SANDBOX_USER}" >/dev/null 2>&1
  else
    grep -q "^${APT_SANDBOX_USER}:" /etc/passwd 2>/dev/null
  fi
}

# True only when apt will actually drop privileges for this fetch.
apt_sandbox_active() {
  (( EUID == 0 )) || return 1
  apt_sandbox_user_exists
}

# `_apt` must be able to TRAVERSE every directory apt reads or writes through.
# Explicit modes, never the ambient umask — the same reason the mkosi consumer
# directories are created with an explicit `install -d -m 0755`: a restrictive
# runner umask otherwise hides the tree from an unprivileged helper.
apt_sandbox_make_traversable() {
  local dir
  for dir in "$@"; do
    [[ -d "${dir}" ]] || continue
    chmod 0755 "${dir}"
  done
}

# apt WRITES the acquired .deb into the download directory as `_apt`, so
# traversal is not enough there: a mode-0755 root-owned download dir still
# degrades to "Download is performed unsandboxed as root". Hand the directory
# to `_apt` exactly the way apt hands itself its own `partial/` dirs.
apt_sandbox_own_download_dir() {
  local dir="$1"
  chown "${APT_SANDBOX_USER}:root" "${dir}"
  chmod 0700 "${dir}"
}
