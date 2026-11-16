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
  find "${moddir}" -type f \
    \( -name '*.ko' -o -name '*.ko.xz' -o -name '*.ko.zst' -o -name '*.ko.gz' \) \
    -print0 >"${work}/modules" || return 1
  find "${moddir}" -type f -name modules.builtin -print0 >"${work}/builtin-lists" || return 1
  find "${moddir}" -type f -name modules.builtin.modinfo -print0 \
    >"${work}/builtin-modinfo" || return 1

  local -a mods=() builtin_lists=() builtin_modinfo=()
  mapfile -d '' -t mods <"${work}/modules"
  mapfile -d '' -t builtin_lists <"${work}/builtin-lists"
  mapfile -d '' -t builtin_modinfo <"${work}/builtin-modinfo"

  local refs="" ref out ko entry builtin data
  for ko in "${mods[@]}"; do
    # One unreadable module would omit a possible consumer, so it voids the proof.
    out="$(modinfo -F firmware "${ko}" 2>/dev/null)" || return 1
    while IFS= read -r ref; do
      [[ -n "${ref}" ]] || continue
      ref="${ref#"${ref%%[!/]*}"}"
      refs+="${ref}"$'\t'"${ko#"${moddir}/"}"$'\n'
    done <<<"${out}"
  done
  for builtin in "${builtin_modinfo[@]}"; do
    data="$(tr '\0' '\n' <"${builtin}")" || return 1
    while IFS= read -r entry; do
      [[ "${entry}" == *.firmware=* ]] || continue
      ref="${entry#*.firmware=}"
      ref="${ref#"${ref%%[!/]*}"}"
      [[ -n "${ref}" ]] || continue
      refs+="${ref}"$'\t'"${entry%%.firmware=*} (built-in)"$'\n'
    done <<<"${data}"
  done
  # A built-in inventory that lists drivers needs usable metadata beside it.
  for builtin in "${builtin_lists[@]}"; do
    data="$(cat -- "${builtin}")" || return 1
    case "${data}" in
      *[![:space:]]*) ;;
      *) continue ;;
    esac
    [[ -f "${builtin}.modinfo" && -r "${builtin}.modinfo" && -s "${builtin}.modinfo" ]] \
      || return 1
    data="$(tr '\0' '\n' <"${builtin}.modinfo")" || return 1
    while IFS= read -r entry; do
      [[ "${entry}" == *.firmware=* ]] || continue
      ref="${entry#*.firmware=}"
      ref="${ref#"${ref%%[!/]*}"}"
      [[ -n "${ref}" ]] || continue
      refs+="${ref}"$'\t'"${entry%%.firmware=*} (built-in)"$'\n'
    done <<<"${data}"
  done
  # Empty is provable only when the kernel states its inventory; a tree with no
  # .ko and no built-in facts has nothing to prove the consumer set against.
  (( ${#mods[@]} + ${#builtin_lists[@]} + ${#builtin_modinfo[@]} > 0 )) || return 1
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
