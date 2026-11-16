#!/usr/bin/env bash
# Family policy supplies candidates; installed drivers authorize each deletion.

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
  if ! refs="$(installed_module_firmware_refs "${root}" "" --with-modules)"; then
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
