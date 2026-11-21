#!/usr/bin/env bash
# Family policy supplies candidates; installed drivers authorize each deletion.

# The device stager's reader lives in a hashed kernel build input, so its bytes
# stay frozen under the released kernel version. The build sweep needs module
# identities and built-in driver metadata, so it reads those sources itself.
# shortcut: two readers, absorb this into the stager at the next kernel bump.
firmware_sweep_module_refs() (
  local root="$1"
  local moddir="${root}/usr/lib/modules"
  [[ -d "${moddir}" ]] || moddir="${root}/lib/modules"
  [[ -d "${moddir}" ]] || return 1

  # Complete traversal is a precondition: a partially read tree must never be
  # mistaken for a complete driver inventory.
  local work
  work="$(mktemp -d)" || return 1
  trap 'rm -rf -- "${work}"' EXIT
  find "${moddir}" -type f -name '*.ko*' \
    -print0 >"${work}/modules" || return 1
  find "${moddir}" -type f -name modules.builtin -print0 >"${work}/builtin-lists" || return 1
  find "${moddir}" -type f -name modules.builtin.modinfo -print0 \
    >"${work}/builtin-modinfo" || return 1

  local -a mods=() builtin_lists=() builtin_modinfo=()
  mapfile -d '' -t mods <"${work}/modules"
  mapfile -d '' -t builtin_lists <"${work}/builtin-lists"
  mapfile -d '' -t builtin_modinfo <"${work}/builtin-modinfo"

  local refs="" record="" line="" ref out ko head name key value builtin sibling path member mapped
  local -i records=0
  local -A seen=() expected=() file_names=() listed=()
  local -a paths=() names=()
  for ko in "${mods[@]}"; do
    # One unreadable module would omit a possible consumer, so it voids the proof.
    out="$(modinfo -F firmware "${ko}" 2>/dev/null)" || return 1
    while IFS= read -r ref; do
      [[ -n "${ref}" ]] || continue
      ref="${ref#"${ref%%[!/]*}"}"
      refs+="${ref}"$'\t'"${ko#"${moddir}/"}"$'\n'
    done <<<"${out}"
  done
  # modules.builtin.modinfo is the kernel's concatenated .modinfo section:
  # NUL-terminated <module>.<key>=<value> records, one trailing NUL. Values may
  # contain newlines, so records are split on NUL, never on lines.
  for builtin in "${builtin_modinfo[@]}"; do
    [[ -r "${builtin}" ]] || return 1
    while IFS= read -r -d '' record; do
      [[ -n "${record}" && "${record}" == *=* ]] || return 1
      head="${record%%=*}"
      [[ "${head}" =~ ^[A-Za-z0-9_]+(:[A-Za-z0-9_]+)*\.[A-Za-z0-9_]+$ ]] || return 1
      name="${head%%.*}"
      key="${head#*.}"
      value="${record#*=}"
      IFS=: read -r -a names <<<"${name}"
      for member in "${names[@]}"; do seen["${builtin}|${member}"]=1; done
      records+=1
      case "${key}" in
        firmware)
          value="${value#"${value%%[!/]*}"}"
          [[ -n "${value}" ]] || continue
          refs+="${value}"$'\t'"${name} (built-in)"$'\n'
          ;;
        file)
          # KBUILD_MODNAME joins normalized owners with ':', KBUILD_MODFILE
          # joins their raw paths with spaces, in the same order.
          [[ "${value}" != *$'\n'* ]] || return 1
          read -r -a paths <<<"${value}"
          mapped=""
          for path in "${paths[@]}"; do
            member="${path##*/}"
            member="${member//[-,]/_}"
            mapped+="${mapped:+:}${member}"
            file_names["${builtin}|${member}"]=1
            expected["${builtin}|kernel/${path}.ko"]="${builtin%.modinfo}"
          done
          [[ "${mapped}" == "${name}" ]] || return 1
          ;;
      esac
    done <"${builtin}"
    # A trailing record without its NUL is truncated metadata, not proof.
    [[ -z "${record}" ]] || return 1
  done
  # modules.builtin is derived from the same records, so a listed driver without
  # its record means the pair is truncated or mismatched.
  for builtin in "${builtin_lists[@]}"; do
    [[ -r "${builtin}" ]] || return 1
    sibling="${builtin}.modinfo"
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ -n "${line}" ]] || continue
      listed["${sibling}|${line}"]=1
      path="${line#kernel/}"
      path="${path%.ko}"
      name="${path##*/}"
      name="${name//[-,]/_}"
      if [[ -n "${expected["${sibling}|${line}"]:-}" ]]; then
        continue
      fi
      # Name-only records cannot override a supplied full-path relation.
      [[ -n "${seen["${sibling}|${name}"]:-}" \
         && -z "${file_names["${sibling}|${name}"]:-}" ]] || return 1
    done <"${builtin}"
  done
  for path in "${!expected[@]}"; do
    [[ ! -e "${expected["${path}"]}" || -n "${listed["${path}"]:-}" ]] || return 1
  done
  # Empty is provable only from an explicit fact: installed modules, an explicit
  # modules.builtin list, or non-empty built-in metadata records. An orphan
  # empty metadata file is absence of proof, not an empty inventory.
  (( ${#mods[@]} + ${#builtin_lists[@]} + records > 0 )) || return 1
  if [[ "${2:-}" == --examined-modules ]]; then
    for ko in "${mods[@]}"; do
      printf '\t%s\n' "${ko#"${moddir}/"}"
    done
  fi
  printf '%s' "${refs}" | awk 'NF' | sort -u
)

firmware_sweep_blocker() {
  local name="$1" refs="$2" ref module
  for ref in "${BT_FW_OBJECTS[@]}"; do
    if [[ "${ref}" == "${name}" || "${ref}" == "${name}/"* ]]; then
      printf 'Bluetooth closure: %s' "${ref}"
      return 0
    fi
  done
  while IFS=$'\t' read -r ref module; do
    [[ -n "${ref}" ]] || continue
    if [[ "${ref}" == "${name}" || "${ref}" == "${name}/"* ]]; then
      printf '%s: %s' "${module}" "${ref}"
      return 0
    fi
  done <<<"${refs}"
}

firmware_sweep() {
  local root="${1:?firmware root is required}"
  local fw="${root}/usr/lib/firmware"
  local -a candidates=() candidate_files=() preserved_roots=()
  read -r -a candidates <<<"${FIRMWARE_SWEEP_PREFIXES:-}"
  if (( ${#candidates[@]} == 0 )); then
    log "no sweep candidates for this family"
    return 0
  fi
  read -r -a candidate_files <<<"${FIRMWARE_SWEEP_FILES:-}"
  read -r -a preserved_roots <<<"${FIRMWARE_PRESERVED_ROOTS:?firmware preserved roots are required}"

  local name preserved
  for name in "${candidates[@]}" "${candidate_files[@]}"; do
    for preserved in "${preserved_roots[@]}"; do
      if [[ "${name}" == "${preserved}" || "${name}" == "${preserved}/"* || "${preserved}" == "${name}/"* ]]; then
        log "FATAL: ${preserved} firmware is a preserved family and must never be a prune candidate"
        return 1
      fi
    done
  done

  [[ -d "${fw}" ]] || { log "no ${fw} — nothing to prune"; return 0; }
  if ! command -v modinfo >/dev/null 2>&1; then
    log "WARNING: modinfo is unavailable — cannot prove a firmware family has no consumer, so NOTHING is pruned"
    return 0
  fi
  if declare -F bluetooth_firmware_assert_candidates >/dev/null; then
    bluetooth_firmware_assert_candidates "${candidates[@]}" "${candidate_files[@]}" || return 1
  fi

  local refs
  if ! refs="$(firmware_sweep_module_refs "${root}")"; then
    log "WARNING: the installed and built-in driver inventory is incomplete or unreadable — the consumer set is unprovable, so NOTHING is pruned"
    return 0
  fi

  local -a pruned=() kept=()
  local name blocked
  for name in "${candidates[@]}"; do
    [[ -e "${fw}/${name}" ]] || continue
    blocked="$(firmware_sweep_blocker "${name}" "${refs}")"
    if [[ -n "${blocked}" ]]; then
      kept+=("${name} (referenced by an installed module: ${blocked})")
      continue
    fi
    rm -rf "${fw:?}/${name}"
    pruned+=("${name}")
  done
  for name in "${candidate_files[@]}"; do
    [[ -e "${fw}/${name}" ]] || continue
    blocked="$(firmware_sweep_blocker "${name}" "${refs}")"
    if [[ -n "${blocked}" ]]; then
      kept+=("${name} (referenced by an installed module: ${blocked})")
      continue
    fi
    rm -f "${fw:?}/${name}"
    pruned+=("${name}")
  done
  log "firmware prune: removed ${#pruned[@]} family/families with zero installed consumers${pruned[0]+: ${pruned[*]}}"
  for name in "${kept[@]}"; do log "firmware prune: KEPT ${name}"; done
  if declare -F bluetooth_firmware_assert_retained >/dev/null; then
    bluetooth_firmware_assert_retained "${fw}" || return 1
  fi
}
