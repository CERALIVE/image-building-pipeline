#!/usr/bin/env bash
#
# config.sh — device target configuration for the dev-sync developer loop.
#
# This is the single config foundation the other dev-sync scripts (transport.sh,
# arch.sh) source. It defines WHERE the developer's device lives and HOW to reach
# it: an mDNS `.local` name (tried first), a fallback IP, the SSH user/key/port,
# the rsync ignore globs, and the per-component remote paths.
#
# DESIGN — dev-sync is a DEVELOPER CONVENIENCE layer, not a production deploy
# path. Its config therefore lives ONLY here on the developer's workstation and
# is NEVER stored in RuntimeConfig or the device's config.json. The device knows
# nothing about dev-sync.
#
# Three-layer precedence (highest wins):
#   1. environment variable   (e.g. SSH_USER=pi DEV_SYNC_TARGET_IP=10.0.0.9 …)
#   2. a `.dev-sync.yaml` file (see .dev-sync.yaml.example for every field)
#   3. the built-in defaults below
#
# Env-knob names mirror dev-push exactly so muscle memory carries over:
#   DRY_RUN, SSH_USER, REMOTE_EXT_DIR, plus a DEV_SYNC_* family for the rest.
#
# The `.dev-sync.yaml` is discovered (first hit wins) at:
#   $DEV_SYNC_CONFIG (explicit)               → this file path
#   ./.dev-sync.yaml                          → cwd
#   <this dir>/.dev-sync.yaml                  → alongside the scripts
#   $WORKSPACE_ROOT/.dev-sync.yaml            → repo workspace root
#
# shellcheck shell=bash

DEV_SYNC_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# common.sh provides strict mode, the loud ERR trap, loggers, die, require_cmd.
# shellcheck source=../common.sh
source "${DEV_SYNC_HERE}/../common.sh"

# Workspace root: v2/lib/dev-sync → v2/lib → v2 → image-building-pipeline →
# <ceralive parent> (siblings live here), matching dev-push's WORKSPACE_ROOT.
DEV_SYNC_WORKSPACE_ROOT="$(cd "${DEV_SYNC_HERE}/../../../.." && pwd)"

# ---------------------------------------------------------------------------
# Built-in defaults (layer 3). Every one is overridable by yaml then env.
# ---------------------------------------------------------------------------
_DS_DEFAULT_target_host="ceralive.local"     # mDNS name, tried first
_DS_DEFAULT_target_ip=""                       # fallback IP (empty = none)
_DS_DEFAULT_ssh_user="root"
_DS_DEFAULT_ssh_key=""                          # empty = ssh-agent / default key
_DS_DEFAULT_ssh_port="22"
_DS_DEFAULT_remote_ext_dir="/var/lib/extensions"
_DS_DEFAULT_remote_tmp="/tmp"
_DS_DEFAULT_budget="120"
_DS_DEFAULT_ceracoder_remote="/var/lib/extensions"
_DS_DEFAULT_srtla_remote="/var/lib/extensions"
_DS_DEFAULT_ceraui_remote="/opt/ceralive"
# Default rsync ignore globs (sane dev noise).
_DS_DEFAULT_IGNORE=(".git/" "node_modules/" "*.tmp" "*.swp" ".DS_Store")

# ---------------------------------------------------------------------------
# _ds_unquote <string> — strip one layer of surrounding single/double quotes.
# ---------------------------------------------------------------------------
_ds_unquote() {
  local s="$1"
  if [[ "$s" == \"*\" && ${#s} -ge 2 ]]; then
    s="${s:1:${#s}-2}"
  elif [[ "$s" == \'*\' && ${#s} -ge 2 ]]; then
    s="${s:1:${#s}-2}"
  fi
  printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# _ds_expand_tilde <path> — expand a leading ~/ to $HOME/ (config convenience).
# ---------------------------------------------------------------------------
_ds_expand_tilde() {
  local p="$1" tilde='~'
  if [[ "${p:0:1}" == "${tilde}" && "${p:1:1}" == "/" ]]; then
    printf '%s' "${HOME}/${p:2}"
  else
    printf '%s' "$p"
  fi
}

# ---------------------------------------------------------------------------
# _ds_find_config — echo the first existing .dev-sync.yaml on the search path,
# or nothing. $DEV_SYNC_CONFIG (if set) short-circuits the search.
# ---------------------------------------------------------------------------
_ds_find_config() {
  if [[ -n "${DEV_SYNC_CONFIG:-}" ]]; then
    [[ -f "${DEV_SYNC_CONFIG}" ]] && { printf '%s' "${DEV_SYNC_CONFIG}"; return 0; }
    return 0
  fi
  local cand
  for cand in \
    "./.dev-sync.yaml" \
    "${DEV_SYNC_HERE}/.dev-sync.yaml" \
    "${DEV_SYNC_WORKSPACE_ROOT}/.dev-sync.yaml"; do
    if [[ -f "$cand" ]]; then
      printf '%s' "$cand"
      return 0
    fi
  done
}

# ---------------------------------------------------------------------------
# _ds_parse_yaml <file> — minimal, deliberately NON-general YAML reader for the
# flat dev-sync schema: scalar `key: value` pairs plus a single `ignore:` block
# list (`  - glob`). Scalars land in _DS_YAML_<key>; the list in _DS_YAML_ignore[].
# Not a YAML library — no nesting, no flow style. Exactly enough for this config.
# ---------------------------------------------------------------------------
_ds_parse_yaml() {
  local file="$1" line key val in_ignore=0
  _DS_YAML_ignore=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"                         # tolerate CRLF
    [[ -z "${line//[[:space:]]/}" ]] && continue # blank
    [[ "$line" =~ ^[[:space:]]*# ]] && continue  # full-line comment

    # `  - item` → an ignore-list entry (only while inside the ignore: block).
    if [[ "$line" =~ ^[[:space:]]+-[[:space:]]*(.*)$ ]]; then
      if (( in_ignore )); then
        val="${BASH_REMATCH[1]%%#*}"             # drop trailing comment
        val="${val%"${val##*[![:space:]]}"}"     # rtrim
        val="$(_ds_unquote "$val")"
        [[ -n "$val" ]] && _DS_YAML_ignore+=("$val")
      fi
      continue
    fi

    # `key: value` at any indent.
    if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*):[[:space:]]*(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]%%#*}"               # drop trailing comment
      val="${val%"${val##*[![:space:]]}"}"       # rtrim
      val="$(_ds_unquote "$val")"
      if [[ "$key" == "ignore" && -z "$val" ]]; then
        in_ignore=1
        continue
      fi
      in_ignore=0
      printf -v "_DS_YAML_${key}" '%s' "$val"
    fi
  done < "$file"
}

# ---------------------------------------------------------------------------
# _ds_resolve <var_name> <yaml_key> <default> — set $var_name honouring the
# env > yaml > default precedence. If the env var is already non-empty it wins;
# otherwise the yaml value (if any); otherwise the default.
# ---------------------------------------------------------------------------
_ds_resolve() {
  local var="$1" yaml_key="$2" default="$3"
  local env_val="${!var:-}"
  local yaml_var="_DS_YAML_${yaml_key}"
  local yaml_val="${!yaml_var:-}"
  if [[ -n "$env_val" ]]; then
    printf -v "$var" '%s' "$env_val"
  elif [[ -n "$yaml_val" ]]; then
    printf -v "$var" '%s' "$yaml_val"
  else
    printf -v "$var" '%s' "$default"
  fi
}

# ---------------------------------------------------------------------------
# dev_sync_load_config — discover + parse .dev-sync.yaml (if any) then settle
# every config variable through the three-layer precedence. Idempotent; the
# other dev-sync scripts call it once at source time.
# ---------------------------------------------------------------------------
dev_sync_load_config() {
  local cfg
  _DS_YAML_ignore=()
  cfg="$(_ds_find_config)"
  DEV_SYNC_CONFIG_FILE="${cfg}"
  if [[ -n "$cfg" ]]; then
    log_info "dev-sync: loading config ${cfg}"
    _ds_parse_yaml "$cfg"
  else
    log_info "dev-sync: no .dev-sync.yaml found — using env + built-in defaults"
  fi

  # Scalar config (env name == public var; yaml key is the snake_case field).
  _ds_resolve DEV_SYNC_TARGET_HOST target_host  "${_DS_DEFAULT_target_host}"
  _ds_resolve DEV_SYNC_TARGET_IP   target_ip    "${_DS_DEFAULT_target_ip}"
  _ds_resolve SSH_USER             ssh_user     "${_DS_DEFAULT_ssh_user}"
  _ds_resolve DEV_SYNC_SSH_KEY     ssh_key      "${_DS_DEFAULT_ssh_key}"
  _ds_resolve DEV_SYNC_SSH_PORT    ssh_port     "${_DS_DEFAULT_ssh_port}"
  _ds_resolve REMOTE_EXT_DIR       remote_ext_dir "${_DS_DEFAULT_remote_ext_dir}"
  _ds_resolve DEV_SYNC_REMOTE_TMP  remote_tmp   "${_DS_DEFAULT_remote_tmp}"
  _ds_resolve DEV_SYNC_BUDGET      budget       "${_DS_DEFAULT_budget}"

  # Per-component remote destinations.
  _ds_resolve DEV_SYNC_CERACODER_REMOTE ceracoder_remote "${_DS_DEFAULT_ceracoder_remote}"
  _ds_resolve DEV_SYNC_SRTLA_REMOTE     srtla_remote     "${_DS_DEFAULT_srtla_remote}"
  _ds_resolve DEV_SYNC_CERAUI_REMOTE    ceraui_remote    "${_DS_DEFAULT_ceraui_remote}"

  # Expand a leading ~/ in the key path for ssh -i convenience.
  [[ -n "$DEV_SYNC_SSH_KEY" ]] && DEV_SYNC_SSH_KEY="$(_ds_expand_tilde "$DEV_SYNC_SSH_KEY")"

  # Ignore globs: env (space/comma separated) > yaml list > default array.
  DEV_SYNC_IGNORE_GLOBS=()
  if [[ -n "${DEV_SYNC_IGNORE:-}" ]]; then
    local IFS=$' \t\n,'
    # shellcheck disable=SC2206  # intentional word-split of the env knob
    DEV_SYNC_IGNORE_GLOBS=(${DEV_SYNC_IGNORE})
  elif (( ${#_DS_YAML_ignore[@]} > 0 )); then
    DEV_SYNC_IGNORE_GLOBS=("${_DS_YAML_ignore[@]}")
  else
    DEV_SYNC_IGNORE_GLOBS=("${_DS_DEFAULT_IGNORE[@]}")
  fi

  # DRY_RUN mirrors dev-push (0 = execute, 1 = log-only).
  DRY_RUN="${DRY_RUN:-0}"
}

# ---------------------------------------------------------------------------
# dev_sync_print_config — dump the settled config (QA / `config.sh` direct run).
# ---------------------------------------------------------------------------
dev_sync_print_config() {
  cat <<EOF >&2
dev-sync config (file: ${DEV_SYNC_CONFIG_FILE:-<none>})
  DEV_SYNC_TARGET_HOST   = ${DEV_SYNC_TARGET_HOST}
  DEV_SYNC_TARGET_IP     = ${DEV_SYNC_TARGET_IP:-<unset>}
  SSH_USER               = ${SSH_USER}
  DEV_SYNC_SSH_KEY       = ${DEV_SYNC_SSH_KEY:-<agent/default>}
  DEV_SYNC_SSH_PORT      = ${DEV_SYNC_SSH_PORT}
  REMOTE_EXT_DIR         = ${REMOTE_EXT_DIR}
  DEV_SYNC_REMOTE_TMP    = ${DEV_SYNC_REMOTE_TMP}
  DEV_SYNC_BUDGET        = ${DEV_SYNC_BUDGET}
  ceracoder_remote       = ${DEV_SYNC_CERACODER_REMOTE}
  srtla_remote           = ${DEV_SYNC_SRTLA_REMOTE}
  ceraui_remote          = ${DEV_SYNC_CERAUI_REMOTE}
  ignore globs           = ${DEV_SYNC_IGNORE_GLOBS[*]}
  DRY_RUN                = ${DRY_RUN}
EOF
}

# Settle config the moment this file is sourced so dependents see ready vars.
# Load once: dependents source both config.sh and transport.sh (which re-sources
# config.sh), so the sentinel keeps it to a single load without losing re-source
# function redefinition.
if [[ -z "${_DEV_SYNC_CONFIG_LOADED:-}" ]]; then
  dev_sync_load_config
  _DEV_SYNC_CONFIG_LOADED=1
fi

# Direct invocation prints the resolved config (handy: `bash config.sh`).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  dev_sync_print_config
fi
