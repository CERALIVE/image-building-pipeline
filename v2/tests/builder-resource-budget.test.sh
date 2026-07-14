#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2="$(cd "${HERE}/.." && pwd)"
CHECK="${V2}/ci/check-builder-resources.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

if [[ ! -x "${CHECK}" ]]; then
  printf 'BUG: production candidate has no executable builder resource-budget check: %s\n' "${CHECK}" >&2
  exit 1
fi

mkdir -p "${TMP}/bin"
cat >"${TMP}/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  context)
    [[ "${2:-}" == inspect ]]
    printf '%s\n' "${MOCK_DOCKER_ENDPOINT}"
    ;;
  info)
    case "${*: -1}" in
      *OperatingSystem*) printf '%s\n' "${MOCK_DOCKER_OS}" ;;
      *MemTotal*) printf '%s\n' "${MOCK_DOCKER_MEMORY_BYTES}" ;;
      *DockerRootDir*) printf '%s\n' "${MOCK_DOCKER_ROOT}" ;;
      *) printf 'unexpected docker info format: %s\n' "${*: -1}" >&2; exit 90 ;;
    esac
    ;;
  *) printf 'unexpected docker command: %s\n' "$*" >&2; exit 91 ;;
esac
EOF
cat >"${TMP}/bin/df" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
path="${*: -1}"
if [[ "${path}" == "${MOCK_DF_FAIL_PATH:-}" ]]; then
  exit 93
fi
printf 'Avail\n'
case "${path}" in
  /workspace) printf '%s\n' "${MOCK_WORKSPACE_FREE_KIB}" ;;
  /docker-root) printf '%s\n' "${MOCK_DOCKER_FREE_KIB}" ;;
  *) printf 'unexpected df path: %s\n' "${path}" >&2; exit 92 ;;
esac
EOF
chmod +x "${TMP}/bin/docker" "${TMP}/bin/df"

gib_kib=$((1024 * 1024))
gib_bytes=$((1024 * 1024 * 1024))

write_meminfo() {
  local available_kib="$1" swap_free_kib="$2"
  cat >"${TMP}/meminfo" <<EOF
MemTotal:       $((32 * gib_kib)) kB
MemAvailable:   ${available_kib} kB
SwapTotal:      $((20 * gib_kib)) kB
SwapFree:       ${swap_free_kib} kB
EOF
}

DOCKER_CONTEXT=default
MOCK_DOCKER_ENDPOINT=unix:///var/run/docker.sock
MOCK_DOCKER_OS='Arch Linux'
MOCK_DOCKER_MEMORY_BYTES=$((32 * gib_bytes))
MOCK_DOCKER_ROOT=/docker-root
MOCK_WORKSPACE_FREE_KIB=$((64 * gib_kib))
MOCK_DOCKER_FREE_KIB=$((64 * gib_kib))
MOCK_DF_FAIL_PATH=
write_meminfo "$((20 * gib_kib))" "$((10 * gib_kib))"

run_check() {
  env \
    PATH="${TMP}/bin:/usr/bin:/bin" \
    DOCKER_CONTEXT="${DOCKER_CONTEXT}" \
    GITHUB_WORKSPACE=/workspace \
    CERALIVE_RESOURCE_MEMINFO_FILE="${TMP}/meminfo" \
    MOCK_DOCKER_ENDPOINT="${MOCK_DOCKER_ENDPOINT}" \
    MOCK_DOCKER_OS="${MOCK_DOCKER_OS}" \
    MOCK_DOCKER_MEMORY_BYTES="${MOCK_DOCKER_MEMORY_BYTES}" \
    MOCK_DOCKER_ROOT="${MOCK_DOCKER_ROOT}" \
    MOCK_WORKSPACE_FREE_KIB="${MOCK_WORKSPACE_FREE_KIB}" \
    MOCK_DOCKER_FREE_KIB="${MOCK_DOCKER_FREE_KIB}" \
    MOCK_DF_FAIL_PATH="${MOCK_DF_FAIL_PATH}" \
    "${CHECK}" 2>&1
}

expect_rejected() {
  local label="$1" expected="$2" output
  if output="$(run_check)"; then
    printf 'BUG: %s resource state was accepted\n%s\n' "${label}" "${output}" >&2
    exit 1
  fi
  if [[ "${output}" != *"${expected}"* ]]; then
    printf 'BUG: %s failed without actionable diagnostic %q\n%s\n' \
      "${label}" "${expected}" "${output}" >&2
    exit 1
  fi
  printf '%s rejected: %s\n' "${label}" "${expected}"
}

DOCKER_CONTEXT=desktop-linux
MOCK_DOCKER_ENDPOINT=unix:///home/runner/.docker/desktop/docker.sock
MOCK_DOCKER_OS='Docker Desktop 4.81.0'
MOCK_DOCKER_MEMORY_BYTES=$((7501 * 1024 * 1024))
write_meminfo "$((2 * gib_kib))" 0
expect_rejected 'failed desktop-linux topology (first run)' 'DOCKER_CONTEXT=default'
expect_rejected 'failed desktop-linux topology (second run)' 'DOCKER_CONTEXT=default'

DOCKER_CONTEXT=default
MOCK_DOCKER_ENDPOINT=unix:///var/run/docker.sock
MOCK_DOCKER_MEMORY_BYTES=$((32 * gib_bytes))
write_meminfo "$((20 * gib_kib))" "$((10 * gib_kib))"
expect_rejected 'Docker Desktop daemon' 'Docker Desktop is not allowed'

MOCK_DOCKER_OS='Arch Linux'
MOCK_DOCKER_ENDPOINT=unix:///tmp/alternate-docker.sock
expect_rejected 'alternate default-context endpoint' 'default Docker context must use unix:///var/run/docker.sock'

MOCK_DOCKER_ENDPOINT=unix:///var/run/docker.sock
MOCK_DOCKER_MEMORY_BYTES=$((7501 * 1024 * 1024))
expect_rejected '7.501 GiB daemon memory' 'daemon memory budget is below 16 GiB'

MOCK_DOCKER_MEMORY_BYTES=$((32 * gib_bytes))
write_meminfo "$((2 * gib_kib))" 0
expect_rejected 'exhausted host memory and swap' 'host memory+swap headroom is below 16 GiB'

write_meminfo "$((20 * gib_kib))" "$((10 * gib_kib))"
MOCK_WORKSPACE_FREE_KIB=$((8 * gib_kib))
expect_rejected 'workspace disk pressure' 'workspace free space is below 24 GiB'

MOCK_WORKSPACE_FREE_KIB=$((64 * gib_kib))
MOCK_DOCKER_FREE_KIB=$((8 * gib_kib))
expect_rejected 'Docker-root disk pressure' 'Docker root free space is below 24 GiB'

MOCK_DOCKER_FREE_KIB=$((64 * gib_kib))
MOCK_DF_FAIL_PATH=/docker-root
expect_rejected 'unstatable Docker root' 'cannot inspect free space for /docker-root'

MOCK_DF_FAIL_PATH=
output="$(run_check)"
[[ "${output}" == *'production builder resource budget: PASS'* ]]
[[ "${output}" == *'context=default'* ]]
[[ "${output}" == *'daemon_memory_bytes='* ]]
[[ "${output}" == *'host_headroom_kib='* ]]
[[ "${output}" == *'workspace_free_kib='* ]]
[[ "${output}" == *'docker_root_free_kib='* ]]
printf '%s\n' "${output}"

MOCK_DOCKER_MEMORY_BYTES=$((16 * gib_bytes))
MOCK_WORKSPACE_FREE_KIB=$((24 * gib_kib))
MOCK_DOCKER_FREE_KIB=$((24 * gib_kib))
write_meminfo "$((16 * gib_kib))" 0
output="$(run_check)"
[[ "${output}" == *'production builder resource budget: PASS'* ]]
printf 'exact admission boundaries accepted\n'
printf 'builder resource budget regression: PASS\n'
