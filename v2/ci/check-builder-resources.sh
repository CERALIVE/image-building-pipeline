#!/usr/bin/env bash
set -euo pipefail

readonly MIN_DAEMON_MEMORY_BYTES=$((16 * 1024 * 1024 * 1024))
readonly MIN_HOST_HEADROOM_KIB=$((16 * 1024 * 1024))
readonly MIN_FREE_DISK_KIB=$((24 * 1024 * 1024))

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_integer() {
  local label="$1" value="$2"
  [[ "${value}" =~ ^[0-9]+$ ]] || die "${label} is not an integer: ${value:-<empty>}"
}

free_kib() {
  local path="$1" value
  value="$(df -k --output=avail "${path}" 2>/dev/null | awk 'NR == 2 { print $1 }')" \
    || die "cannot inspect free space for ${path}"
  require_integer "free space for ${path}" "${value}"
  printf '%s\n' "${value}"
}

context="${DOCKER_CONTEXT:-}"
[[ "${context}" == default ]] \
  || die "production candidate requires DOCKER_CONTEXT=default (got ${context:-<unset>})"

command -v docker >/dev/null 2>&1 || die 'docker is not installed'
endpoint="$(docker context inspect default --format '{{.Endpoints.docker.Host}}')"
[[ "${endpoint}" == unix:///var/run/docker.sock ]] \
  || die "default Docker context must use unix:///var/run/docker.sock (got ${endpoint})"

daemon_os="$(docker info --format '{{.OperatingSystem}}')"
[[ "${daemon_os}" != *'Docker Desktop'* ]] \
  || die "Docker Desktop is not allowed for the production candidate (daemon_os=${daemon_os})"

daemon_memory_bytes="$(docker info --format '{{.MemTotal}}')"
require_integer 'Docker daemon memory' "${daemon_memory_bytes}"
(( daemon_memory_bytes >= MIN_DAEMON_MEMORY_BYTES )) \
  || die "Docker daemon memory budget is below 16 GiB (bytes=${daemon_memory_bytes})"

meminfo_file="${CERALIVE_RESOURCE_MEMINFO_FILE:-/proc/meminfo}"
mem_available_kib="$(awk '$1 == "MemAvailable:" { print $2; found = 1 } END { if (!found) exit 1 }' "${meminfo_file}")" \
  || die "MemAvailable is missing from ${meminfo_file}"
swap_free_kib="$(awk '$1 == "SwapFree:" { print $2; found = 1 } END { if (!found) exit 1 }' "${meminfo_file}")" \
  || die "SwapFree is missing from ${meminfo_file}"
require_integer 'MemAvailable' "${mem_available_kib}"
require_integer 'SwapFree' "${swap_free_kib}"
host_headroom_kib=$((mem_available_kib + swap_free_kib))
(( host_headroom_kib >= MIN_HOST_HEADROOM_KIB )) \
  || die "host memory+swap headroom is below 16 GiB (available_kib=${mem_available_kib} swap_free_kib=${swap_free_kib})"

workspace="${GITHUB_WORKSPACE:-$(pwd)}"
docker_root="$(docker info --format '{{.DockerRootDir}}')"
[[ -n "${docker_root}" ]] || die 'Docker root directory is empty'
workspace_free_kib="$(free_kib "${workspace}")"
docker_root_free_kib="$(free_kib "${docker_root}")"
(( workspace_free_kib >= MIN_FREE_DISK_KIB )) \
  || die "workspace free space is below 24 GiB (path=${workspace} free_kib=${workspace_free_kib})"
(( docker_root_free_kib >= MIN_FREE_DISK_KIB )) \
  || die "Docker root free space is below 24 GiB (path=${docker_root} free_kib=${docker_root_free_kib})"

printf 'context=%s endpoint=%s daemon_os=%s daemon_memory_bytes=%s\n' \
  "${context}" "${endpoint}" "${daemon_os}" "${daemon_memory_bytes}"
printf 'host_headroom_kib=%s mem_available_kib=%s swap_free_kib=%s\n' \
  "${host_headroom_kib}" "${mem_available_kib}" "${swap_free_kib}"
printf 'workspace_free_kib=%s workspace=%s\n' "${workspace_free_kib}" "${workspace}"
printf 'docker_root_free_kib=%s docker_root=%s\n' "${docker_root_free_kib}" "${docker_root}"
printf 'production builder resource budget: PASS\n'
