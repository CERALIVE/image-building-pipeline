#!/usr/bin/env bash
# Family policy supplies candidates; installed drivers authorize each deletion.

# The device stager's reader lives in a hashed kernel build input, so its bytes
# stay frozen under the released kernel version. The build sweep needs module
# identities and built-in driver metadata, so it reads those sources itself.
# shortcut: two readers, absorb this into the stager at the next kernel bump.
firmware_sweep_module_refs() {
  local root="$1"
  local moddir="${root}/usr/lib/modules"
  [[ -d "${moddir}" ]] || moddir="${root}/lib/modules"
  [[ -d "${moddir}" ]] || return 1

  local -a mods=() builtins=()
  mapfile -d '' -t mods < <(find "${moddir}" -type f \
    \( -name '*.ko' -o -name '*.ko.xz' -o -name '*.ko.zst' -o -name '*.ko.gz' \) -print0)
  mapfile -d '' -t builtins < <(find "${moddir}" -type f -name modules.builtin.modinfo -print0)
  # No installed driver metadata is not proof that no driver needs firmware.
  (( ${#mods[@]} + ${#builtins[@]} > 0 )) || return 1

  local refs="" ref out ko entry builtin
  local -i parsed=0
  for ko in "${mods[@]}"; do
    if out="$(modinfo -F firmware "${ko}" 2>/dev/null)"; then
      parsed+=1
      while IFS= read -r ref; do
        [[ -n "${ref}" ]] || continue
        ref="${ref#"${ref%%[!/]*}"}"
        refs+="${ref}"$'\t'"${ko#"${moddir}/"}"$'\n'
      done <<<"${out}"
    fi
  done
  for builtin in "${builtins[@]}"; do
    [[ -r "${builtin}" ]] || return 1
    while IFS= read -r entry || [[ -n "${entry}" ]]; do
      [[ "${entry}" == *.firmware=* ]] || continue
      ref="${entry#*.firmware=}"
      ref="${ref#"${ref%%[!/]*}"}"
      [[ -n "${ref}" ]] || continue
      refs+="${ref}"$'\t'"${entry%%.firmware=*} (built-in)"$'\n'
    done < <(tr '\0' '\n' <"${builtin}")
    parsed+=1
  done
  # A run in which no metadata parsed yields an EMPTY consumer set and would
  # authorise deleting every candidate family, so it returns non-zero instead.
  (( parsed > 0 )) || return 1
  printf '%s' "${refs}" | awk 'NF' | sort -u
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
    log "WARNING: no installed module could be read by modinfo — the consumer set is unprovable, so NOTHING is pruned"
    return 0
  fi

  local -a pruned=() kept=()
  local ref module blocked
  for name in "${candidates[@]}" "${candidate_files[@]}"; do
    [[ -e "${fw}/${name}" ]] || continue
    blocked=""
    for ref in "${BT_FW_OBJECTS[@]}"; do
      if [[ "${ref}" == "${name}" || "${ref}" == "${name}/"* ]]; then
        blocked="Bluetooth closure: ${ref}"; break
      fi
    done
    while IFS=$'\t' read -r ref module; do
      [[ -n "${ref}" ]] || continue
      if [[ "${ref}" == "${name}" || "${ref}" == "${name}/"* ]]; then
        blocked="${module}: ${ref}"; break
      fi
    done <<<"${refs}"
    if [[ -n "${blocked}" ]]; then
      kept+=("${name} (referenced by an installed module: ${blocked})")
      continue
    fi
    rm -rf "${fw:?}/${name}"
    pruned+=("${name}")
  done
  log "firmware prune: removed ${#pruned[@]} family/families with zero installed consumers${pruned[0]+: ${pruned[*]}}"
  for name in "${kept[@]}"; do log "firmware prune: KEPT ${name}"; done
  if declare -F bluetooth_firmware_assert_retained >/dev/null; then
    bluetooth_firmware_assert_retained "${fw}" || return 1
  fi
}
