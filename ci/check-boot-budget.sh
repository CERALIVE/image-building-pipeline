#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ci/check-boot-budget.sh \
  --samples <cold-boots.tsv> \
  --board <board-id> \
  --max-userspace-ms <milliseconds> \
  --basis <measurement-basis> \
  [--min-samples <count>]

Input is a tab-separated file with this exact header:
schema_version	board	artifact	slot	peripherals	uplink	kernel_ms	userspace_ms

All selected samples must use one artifact, slot, peripheral set, and uplink
state. At least three samples are required. The median userspace time is the
blocking value; the complete kernel/userspace median and range are reported.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_uint() {
  local label="$1" value="$2"
  [[ "${value}" =~ ^[0-9]+$ ]] || die "${label} must be an unsigned integer (got ${value:-<empty>})"
}

samples_file=""
board=""
max_userspace_ms=""
basis=""
min_samples=3

while (($#)); do
  case "$1" in
    --samples) samples_file="${2:-}"; shift 2 ;;
    --board) board="${2:-}"; shift 2 ;;
    --max-userspace-ms) max_userspace_ms="${2:-}"; shift 2 ;;
    --basis) basis="${2:-}"; shift 2 ;;
    --min-samples) min_samples="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ -n "${samples_file}" ]] || die '--samples is required'
[[ -r "${samples_file}" ]] || die "sample file is not readable: ${samples_file}"
[[ "${board}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "--board is invalid: ${board:-<empty>}"
require_uint '--max-userspace-ms' "${max_userspace_ms}"
require_uint '--min-samples' "${min_samples}"
(( min_samples >= 3 )) || die '--min-samples cannot weaken the three-cold-boot floor'
[[ -n "${basis}" ]] || die '--basis is required so the threshold has an auditable measurement basis'

readonly expected_header=$'schema_version\tboard\tartifact\tslot\tperipherals\tuplink\tkernel_ms\tuserspace_ms'
IFS= read -r header <"${samples_file}" || die "sample file is empty: ${samples_file}"
[[ "${header}" == "${expected_header}" ]] || die 'sample file header does not match schema version 1'

declare -a kernel_values=()
declare -a userspace_values=()
control_artifact=""
control_slot=""
control_peripherals=""
control_uplink=""
line_no=1

while IFS=$'\t' read -r schema sample_board artifact slot peripherals uplink kernel_ms userspace_ms extra; do
  line_no=$((line_no + 1))
  [[ -z "${extra:-}" ]] || die "line ${line_no}: unexpected extra field"
  [[ -n "${schema}${sample_board}${artifact}${slot}${peripherals}${uplink}${kernel_ms}${userspace_ms}" ]] \
    || die "line ${line_no}: empty rows are not allowed"
  [[ "${schema}" == 1 ]] || die "line ${line_no}: unsupported schema_version ${schema}"
  [[ "${sample_board}" == "${board}" ]] || continue
  require_uint "line ${line_no} kernel_ms" "${kernel_ms}"
  require_uint "line ${line_no} userspace_ms" "${userspace_ms}"

  if ((${#userspace_values[@]} == 0)); then
    control_artifact="${artifact}"
    control_slot="${slot}"
    control_peripherals="${peripherals}"
    control_uplink="${uplink}"
  else
    [[ "${artifact}" == "${control_artifact}" ]] || die "line ${line_no}: artifact changed (${control_artifact} -> ${artifact})"
    [[ "${slot}" == "${control_slot}" ]] || die "line ${line_no}: slot changed (${control_slot} -> ${slot})"
    [[ "${peripherals}" == "${control_peripherals}" ]] || die "line ${line_no}: peripherals changed (${control_peripherals} -> ${peripherals})"
    [[ "${uplink}" == "${control_uplink}" ]] || die "line ${line_no}: uplink state changed (${control_uplink} -> ${uplink})"
  fi

  kernel_values+=("${kernel_ms}")
  userspace_values+=("${userspace_ms}")
done < <(tail -n +2 "${samples_file}")

sample_count=${#userspace_values[@]}
(( sample_count >= min_samples )) \
  || die "board ${board} has ${sample_count} matched sample(s); need at least ${min_samples}"

summarize() {
  local values_name="$1" median_x2_name="$2" median_text_name="$3" min_name="$4" max_name="$5"
  local -n values_ref="${values_name}"
  local -a sorted=()
  mapfile -t sorted < <(printf '%s\n' "${values_ref[@]}" | sort -n)
  local count middle median_x2 median_text
  count=${#sorted[@]}
  middle=$((count / 2))
  if (( count % 2 == 1 )); then
    median_x2=$((sorted[middle] * 2))
    median_text="${sorted[middle]}"
  else
    median_x2=$((sorted[middle - 1] + sorted[middle]))
    if (( median_x2 % 2 == 0 )); then
      median_text="$((median_x2 / 2))"
    else
      median_text="$((median_x2 / 2)).5"
    fi
  fi
  printf -v "${median_x2_name}" '%s' "${median_x2}"
  printf -v "${median_text_name}" '%s' "${median_text}"
  printf -v "${min_name}" '%s' "${sorted[0]}"
  printf -v "${max_name}" '%s' "${sorted[count - 1]}"
}

kernel_median_x2=""
kernel_median=""
kernel_min=""
kernel_max=""
userspace_median_x2=""
userspace_median=""
userspace_min=""
userspace_max=""
summarize kernel_values kernel_median_x2 kernel_median kernel_min kernel_max
summarize userspace_values userspace_median_x2 userspace_median userspace_min userspace_max
require_uint 'kernel median (doubled)' "${kernel_median_x2}"

printf 'board=%s samples=%s artifact=%s slot=%s peripherals=%s uplink=%s\n' \
  "${board}" "${sample_count}" "${control_artifact}" "${control_slot}" \
  "${control_peripherals}" "${control_uplink}"
printf 'kernel_ms median=%s range=%s-%s\n' "${kernel_median}" "${kernel_min}" "${kernel_max}"
printf 'userspace_ms median=%s range=%s-%s budget=%s\n' \
  "${userspace_median}" "${userspace_min}" "${userspace_max}" "${max_userspace_ms}"
printf 'measurement_basis=%s\n' "${basis}"

if (( userspace_median_x2 > max_userspace_ms * 2 )); then
  die "boot budget exceeded: board=${board} userspace_median_ms=${userspace_median} max_userspace_ms=${max_userspace_ms}"
fi

printf 'boot budget: PASS\n'
