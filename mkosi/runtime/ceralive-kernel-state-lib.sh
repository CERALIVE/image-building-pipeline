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
  local file="$1" tmp="${1}.tmp.$$"
  (umask 077; printf '%s\n' "$2" >"${tmp}") || return 1
  "${SYNC_BIN:-sync}" "${tmp}" &&
    mv -f -- "${tmp}" "${file}" &&
    "${SYNC_BIN:-sync}" "$(dirname "${file}")"
}
