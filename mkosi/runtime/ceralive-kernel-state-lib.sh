#!/bin/bash
# Shared durable writer for kernel state and per-slot overlays (schema 1).
# Values read by kernel_json_field are image-owned flat strings, never eval'd.
kernel_json_field() {
  [[ -r "$1" ]] || return 0
  kernel_json_string "$(<"$1")" "$2"
}

kernel_json_string() {
  printf '%s\n' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -n1
}

# Same balanced-object reader as slot-sync, scoped before reading nested fields.
kernel_json_object() {
  printf '%s' "$1" | grep -ozP "(?(DEFINE)(?<obj>\\{(?:[^{}\"]|\"(?:\\\\.|[^\"\\\\])*\"|(?&obj))*\\}))\"$2\"[[:space:]]*:[[:space:]]*\\K(?&obj)" | tr '\0' '\n'
}

kernel_uuid_valid() {
  [[ "$1" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[1-8][[:xdigit:]]{3}-[89aAbB][[:xdigit:]]{3}-[[:xdigit:]]{12}$ ]]
}

kernel_utc_timestamp_valid() {
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T(0[0-9]|1[0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]([.][0-9]+)?Z$ ]] &&
    date -u -d "$1" +%s >/dev/null 2>&1
}

# Adopted shared kernel reason vocabulary; journal detail is never serialized.
kernel_reason_json() {
  case "$1" in
    "") printf null ;;
    kernel_origin_mismatch|kernel_download_failed|kernel_staging_failed|kernel_identity_mismatch|kernel_boot_failed|kernel_interrupted)
      printf '"%s"' "$1" ;;
    *) return 1 ;;
  esac
}

kernel_atomic_write() {
  local file="$1" tmp
  tmp="$(mktemp "${file}.tmp.XXXXXX")" || return 1
  (umask 077; printf '%s\n' "$2" >"${tmp}") || return 1
  if "${SYNC_BIN:-sync}" "${tmp}" &&
    mv -f -- "${tmp}" "${file}" &&
    "${SYNC_BIN:-sync}" "$(dirname "${file}")"; then
    return 0
  fi
  rm -f -- "${tmp}"
  return 1
}

# Machine-owned JSON only; validate the whole document before extracting fields.
# Neither jq nor Python ships in the production image.
kernel_json_valid() {
  local grammar='(?(DEFINE)(?<s>"(?:[^"\\\x00-\x1f]|\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4}))*")(?<v>\s*(?:(?&s)|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?|true|false|null|(?&o)|(?&a))\s*)(?<o>\{\s*(?:(?&s)\s*:(?&v)(?:,\s*(?&s)\s*:(?&v))*)?\})(?<a>\[\s*(?:(?&v)(?:,(?&v))*)?\]))\A(?&v)\z'
  printf '%s' "$1" | grep -zPq "${grammar}"
}

kernel_load_state() {
  KERNEL_STATE_FILE="$1/kernel-state.json"
  KERNEL_STATE="" KERNEL_RECORD=""
  [[ -e "${KERNEL_STATE_FILE}" ]] || return 0
  KERNEL_RECORD="$(<"${KERNEL_STATE_FILE}")" || return 1
  kernel_json_valid "${KERNEL_RECORD}" || return 1
  [[ "${KERNEL_RECORD}" =~ ^[[:space:]]*\{ ]] || return 1
  local key value count
  for key in schema attempt package version deb_sha256 target_slot booted_slot_at_stage boot_id_at_activation state reason timestamps; do
    count="$(printf '%s' "${KERNEL_RECORD}" | grep -oE "\"${key}\"[[:space:]]*:" | wc -l)"
    [[ "${count}" == 1 ]] || return 1
  done
  [[ "${KERNEL_RECORD}" =~ \"schema\"[[:space:]]*:[[:space:]]*1[[:space:]]*[,}] ]] || return 1
  KERNEL_STATE="$(kernel_json_string "${KERNEL_RECORD}" state)"
  KERNEL_ATTEMPT="$(kernel_json_string "${KERNEL_RECORD}" attempt)"
  KERNEL_PACKAGE="$(kernel_json_string "${KERNEL_RECORD}" package)"
  KERNEL_VERSION="$(kernel_json_string "${KERNEL_RECORD}" version)"
  KERNEL_SHA="$(kernel_json_string "${KERNEL_RECORD}" deb_sha256)"
  KERNEL_TARGET="$(kernel_json_string "${KERNEL_RECORD}" target_slot)"
  KERNEL_BOOTED="$(kernel_json_string "${KERNEL_RECORD}" booted_slot_at_stage)"
  KERNEL_ACTIVATION_BOOT="$(kernel_json_string "${KERNEL_RECORD}" boot_id_at_activation)"
  if [[ -n "${KERNEL_ACTIVATION_BOOT}" ]]; then
    kernel_uuid_valid "${KERNEL_ACTIVATION_BOOT}" || return 1
  else
    [[ "${KERNEL_RECORD}" =~ \"boot_id_at_activation\"[[:space:]]*:[[:space:]]*null ]] || return 1
  fi
  kernel_uuid_valid "${KERNEL_ATTEMPT}" || return 1
  [[ "${KERNEL_PACKAGE}" =~ ^linux-image-[0-9]+[.][0-9]+[.][0-9]+-ceralive-rk3588$ &&
     "${KERNEL_VERSION}" =~ ^[0-9]+[.][0-9]+[.][0-9]+-ceralive[0-9]+$ &&
     "${KERNEL_SHA}" =~ ^[a-f0-9]{64}$ &&
     "${KERNEL_TARGET}" =~ ^[AB]$ && "${KERNEL_BOOTED}" =~ ^[AB]$ &&
     "${KERNEL_TARGET}" != "${KERNEL_BOOTED}" ]] || return 1
  [[ "${KERNEL_PACKAGE}" == "linux-image-${KERNEL_VERSION%%-ceralive*}-ceralive-rk3588" ]] || return 1
  case "${KERNEL_STATE}" in
    staging|staged|armed|failed) ;;
    activating|activated|succeeded|rolled_back)
      kernel_uuid_valid "${KERNEL_ACTIVATION_BOOT}" || return 1 ;;
    *) return 1 ;;
  esac
  value="$(kernel_json_string "${KERNEL_RECORD}" reason)"
  if [[ -n "${value}" ]]; then
    kernel_reason_json "${value}" >/dev/null || return 1
  else
    [[ "${KERNEL_RECORD}" =~ \"reason\"[[:space:]]*:[[:space:]]*null ]] || return 1
  fi
  KERNEL_TIMESTAMPS="$(kernel_json_object "${KERNEL_RECORD}" timestamps)" || return 1
  local member='"(staging|staged|armed|activating|activated|succeeded|rolled_back|failed)"[[:space:]]*:[[:space:]]*"[0-9TZ:.-]+"'
  local pattern="^\\{[[:space:]]*(${member}([[:space:]]*,[[:space:]]*${member})*)?[[:space:]]*\\}$"
  [[ "${KERNEL_TIMESTAMPS}" =~ ${pattern} ]] || return 1
  for key in staging staged armed activating activated succeeded rolled_back failed; do
    count="$(printf '%s' "${KERNEL_TIMESTAMPS}" | grep -oE "\"${key}\"[[:space:]]*:" | wc -l)"
    [[ "${count}" -le 1 ]] || return 1
    value="$(kernel_json_string "${KERNEL_TIMESTAMPS}" "${key}")"
    [[ -z "${value}" ]] || kernel_utc_timestamp_valid "${value}" || return 1
  done
  case "${KERNEL_STATE}" in
    staging|failed) ;;
    *) kernel_utc_timestamp_valid "$(kernel_json_string "${KERNEL_TIMESTAMPS}" staged)" || return 1 ;;
  esac
}

kernel_transition() {
  local next="$1" reason="${2:-}" boot="${3:-${KERNEL_ACTIVATION_BOOT}}" now record stamps
  reason="$(kernel_reason_json "${reason}")" || return 1
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 1
  stamps="${KERNEL_TIMESTAMPS}"
  # Keep first-entry anchors, especially staged across disarm/recovery.
  if [[ -z "$(kernel_json_string "${stamps}" "${next}")" ]]; then
    stamps="${stamps%\}}"
    [[ "${stamps}" =~ ^\{[[:space:]]*$ ]] || stamps+=,
    stamps+="\"${next}\":\"${now}\"}"
  fi
  record="${KERNEL_RECORD/"${KERNEL_TIMESTAMPS}"/"${stamps}"}"
  record="$(printf '%s' "${record}" | sed -E \
    -e "s/(\"state\"[[:space:]]*:[[:space:]]*)\"[^\"]*\"/\\1\"${next}\"/" \
    -e "s/(\"reason\"[[:space:]]*:[[:space:]]*)(null|\"[^\"]*\")/\\1${reason}/")" || return 1
  if [[ -n "${boot}" ]]; then
    kernel_uuid_valid "${boot}" || return 1
    record="$(printf '%s' "${record}" | sed -E "s/(\"boot_id_at_activation\"[[:space:]]*:[[:space:]]*)(null|\"[^\"]*\")/\\1\"${boot}\"/")"
  fi
  kernel_atomic_write "${KERNEL_STATE_FILE}" "${record}" || return 1
  kernel_load_state "$(dirname "${KERNEL_STATE_FILE}")"
}

kernel_overlay_matches() {
  local file="$1" status="$2" record kernel key count base
  [[ -r "${file}" ]] || return 1
  record="$(<"${file}")"
  kernel_json_valid "${record}" || return 1
  [[ "${record}" =~ ^[[:space:]]*\{ ]] || return 1
  for key in status attempt kernel base_bundle_identity package version deb_sha256; do
    count="$(printf '%s' "${record}" | grep -oE "\"${key}\"[[:space:]]*:" | wc -l)"
    [[ "${count}" == 1 ]] || return 1
  done
  base="$(kernel_json_object "${record}" base_bundle_identity)" || return 1
  [[ "$(kernel_json_string "${base}" slot)" =~ ^rootfs[.][0-9]+$ &&
     "$(kernel_json_string "${base}" bundleHash)" =~ ^[a-f0-9]{64}$ &&
     "$(kernel_json_string "${base}" checksum)" =~ ^[a-f0-9]{64}$ &&
     "${base}" =~ \"installedCount\"[[:space:]]*:[[:space:]]*[1-9][0-9]*[[:space:]]*[,}] ]] || return 1
  kernel_utc_timestamp_valid "$(kernel_json_string "${base}" installedAt)" || return 1
  kernel="$(kernel_json_object "${record}" kernel)" || return 1
  [[ "$(kernel_json_string "${record}" status)" == "${status}" &&
     "$(kernel_json_string "${record}" attempt)" == "${KERNEL_ATTEMPT}" &&
     "$(kernel_json_string "${kernel}" package)" == "${KERNEL_PACKAGE}" &&
     "$(kernel_json_string "${kernel}" version)" == "${KERNEL_VERSION}" &&
     "$(kernel_json_string "${kernel}" deb_sha256)" == "${KERNEL_SHA}" ]]
}

kernel_reconcile_terminal() {
  local dir file record entry item remainder found=0
  dir="$(dirname "${KERNEL_STATE_FILE}")"
  case "${KERNEL_STATE}" in
    succeeded)
      file="${dir}/slot-overlay-${KERNEL_TARGET}.json"
      # A later verified mirror or full install may have retired this overlay.
      [[ -e "${file}" ]] || return 0
      kernel_overlay_matches "${file}" confirmed && return 0
      kernel_overlay_matches "${file}" pending || return 0
      record="$(sed -E 's/("status"[[:space:]]*:[[:space:]]*)"pending"/\1"confirmed"/' "${file}")"
      kernel_atomic_write "${file}" "${record}" ;;
    rolled_back)
      file="${dir}/kernel-quarantine.json"
      record='[]'
      [[ ! -e "${file}" ]] || record="$(<"${file}")"
      kernel_json_valid "${record}" && [[ "${record}" =~ ^[[:space:]]*\[ ]] || return 1
      entry="$(printf '{"package":"%s","version":"%s","deb_sha256":"%s"}' "${KERNEL_PACKAGE}" "${KERNEL_VERSION}" "${KERNEL_SHA}")"
      record="$(printf '%s' "${record}" | tr -d '[:space:]')"
      remainder="$(printf '%s' "${record}" | sed -E 's/\{[^{}]*\}//g')"
      [[ "${remainder}" =~ ^\[,*\]$ ]] || return 1
      while IFS= read -r item; do
        [[ "$(kernel_json_string "${item}" package)" =~ ^linux-image-[0-9]+[.][0-9]+[.][0-9]+-ceralive-rk3588$ &&
           "$(kernel_json_string "${item}" version)" =~ ^[0-9]+[.][0-9]+[.][0-9]+-ceralive[0-9]+$ &&
           "$(kernel_json_string "${item}" deb_sha256)" =~ ^[a-f0-9]{64}$ ]] || return 1
        if [[ "$(kernel_json_string "${item}" package)" == "${KERNEL_PACKAGE}" &&
              "$(kernel_json_string "${item}" version)" == "${KERNEL_VERSION}" &&
              "$(kernel_json_string "${item}" deb_sha256)" == "${KERNEL_SHA}" ]]; then
          found=1
        fi
      done < <(printf '%s' "${record}" | grep -oE '\{[^{}]*\}')
      [[ "${found}" == 0 ]] || return 0
      record="${record%]}"
      [[ "${record}" == '[' ]] || record+=,
      kernel_atomic_write "${file}" "${record}${entry}]" ;;
  esac
}

kernel_running_identity_matches() {
  local installed expected="${KERNEL_PACKAGE#linux-image-}"
  [[ "$("${UNAME_BIN:-uname}" -r)" == "${expected}" ]] || return 1
  installed="$("${DPKG_QUERY_BIN:-dpkg-query}" -W -f="\${Status}\t\${Version}\n" "${KERNEL_PACKAGE}")" || return 1
  [[ "${installed}" == $'install ok installed\t'"${KERNEL_VERSION}" ]]
}

# Read-only selector decisions: never reset the failed target's attempt budget.
kernel_reconcile_boot() {
  local slot="$1" boot="$2" primary state overlay
  KERNEL_CONFIRM_PENDING=0
  case "${KERNEL_STATE}" in
    succeeded|rolled_back) kernel_reconcile_terminal; return $? ;;
    activating|activated) ;;
    *) return 0 ;;
  esac
  primary="$("${BOOT_STATE_BIN:-ceralive-boot-state}" get-primary)" || return 1
  [[ "${primary}" =~ ^[AB]$ ]] || return 1
  if [[ "${slot}" == "${KERNEL_TARGET}" ]]; then
    kernel_running_identity_matches || return 1
  fi
  if [[ "${boot}" == "${KERNEL_ACTIVATION_BOOT}" ]]; then
    if [[ "${KERNEL_STATE}" == activating && "${primary}" != "${KERNEL_TARGET}" ]]; then
      kernel_transition armed
    fi
    return $?
  fi
  if [[ "${slot}" == "${KERNEL_TARGET}" ]]; then
    overlay="$(dirname "${KERNEL_STATE_FILE}")/slot-overlay-${KERNEL_TARGET}.json"
    kernel_overlay_matches "${overlay}" pending || return 1
    KERNEL_CONFIRM_PENDING=1
  else
    state="$("${BOOT_STATE_BIN:-ceralive-boot-state}" get-state "${KERNEL_TARGET}")" || return 1
    case "${state}" in good|bad) ;; *) return 1 ;; esac
    if [[ "${primary}" != "${KERNEL_TARGET}" || "${state}" == bad ]]; then
      kernel_transition rolled_back kernel_boot_failed &&
        kernel_reconcile_terminal || return 1
    fi
  fi
}

kernel_confirm_boot() {
  [[ "${KERNEL_CONFIRM_PENDING:-0}" == 1 ]] || return 0
  kernel_transition succeeded && kernel_reconcile_terminal
}
