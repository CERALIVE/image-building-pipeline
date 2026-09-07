#!/usr/bin/env bash
# Profile-neutral: shared by platform postinst and the emitted-image checker.

bluetooth_firmware_error() { printf 'Bluetooth firmware: %s\n' "$*" >&2; return 1; }

bluetooth_firmware_load() {
  local manifest="$1" kind module pattern note key base
  [[ -s "${manifest}" ]] || { bluetooth_firmware_error "missing roots manifest ${manifest}"; return 1; }
  BT_FW_PATTERNS=()
  declare -gA BT_FW_CLASSES=()
  local -A seen=()
  while read -r kind module pattern note; do
    case "${kind}" in ''|'#'*) continue ;; esac
    [[ "${module}" =~ ^[a-z0-9_]+$ && "${pattern}" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_./,*+-]*$ && "${pattern}" != *..* && "${pattern}" != *//* ]] \
      || { bluetooth_firmware_error "unsafe root ${pattern}"; return 1; }
    base="${pattern##*/}"
    [[ "${pattern}" != *'**'* && "${pattern}" != *'*/'* && "${base}" != '*' ]] \
      || { bluetooth_firmware_error "over-broad root ${pattern}"; return 1; }
    if [[ "${pattern}" == *'*'* && "${pattern}" != */* && "${pattern}" != BCM'*.hcd' ]]; then
      bluetooth_firmware_error "over-broad top-level root ${pattern}"; return 1
    fi
    [[ -z "${note}" || "${note}" == '# '* ]] || { bluetooth_firmware_error "extra root fields ${pattern}"; return 1; }
    [[ -z "${seen[${pattern}]:-}" ]] || { bluetooth_firmware_error "duplicate root ${pattern}"; return 1; }
    seen["${pattern}"]=1
    key="${module}:${pattern}"
    case "${kind}" in
      static) [[ "${pattern}" != *'*'* && "${pattern}" != */ ]] || return 1 ;;
      runtime-composed) [[ "${note}" == '# '* ]] || { bluetooth_firmware_error "unreviewed runtime root ${pattern}"; return 1; } ;;
      reviewed-hardware-gap)
        [[ "${note}" == '# '* ]] || return 1
        case "${key}" in
          btmrvl_sdio:mrvl/sd8987_uapsta.bin|btmtk:mediatek/mt7927/BT_RAM_CODE_MT6639_2_1_hdr.bin) ;;
          *) bluetooth_firmware_error "unapproved hardware gap ${key}"; return 1 ;;
        esac ;;
      *) bluetooth_firmware_error "unknown classification ${kind}"; return 1 ;;
    esac
    BT_FW_CLASSES["${key}"]="${kind}"
    [[ "${kind}" == reviewed-hardware-gap ]] || BT_FW_PATTERNS+=("${pattern}")
  done <"${manifest}"
  (( ${#BT_FW_PATTERNS[@]} > 0 )) || { bluetooth_firmware_error 'zero declared roots'; return 1; }
}

bluetooth_firmware_snapshot() {
  local fw="$1" pattern object target listing matches
  BT_FW_OBJECTS=()
  fw="$(realpath -e "${fw}")" || return 1
  for pattern in "${BT_FW_PATTERNS[@]}"; do
    matches="$(compgen -G "${fw}/${pattern}")" || { bluetooth_firmware_error "missing declared root ${pattern}"; return 1; }
    while IFS= read -r object; do
      listing="$(find "${object}" \( -type f -o -type l \) -print)" || return 1
      [[ -n "${listing}" ]] || { bluetooth_firmware_error "empty declared root ${pattern}"; return 1; }
      while IFS= read -r object; do
        target="$(realpath -e "${object}")" || { bluetooth_firmware_error "dangling closure object ${object}"; return 1; }
        [[ "${target}" == "${fw}/"* && -f "${target}" ]] || { bluetooth_firmware_error "escaping closure object ${object}"; return 1; }
        BT_FW_OBJECTS+=("${object#"${fw}/"}" "${target#"${fw}/"}")
      done <<<"${listing}"
    done <<<"${matches}"
  done
}

bluetooth_firmware_scan() {
  local modules="$1" fw="$2" listing ko name deps dep refs ref key
  command -v modinfo >/dev/null 2>&1 || { bluetooth_firmware_error 'modinfo unavailable; cannot prove closure'; return 1; }
  listing="$(find "${modules}" -type f \( -name '*.ko' -o -name '*.ko.xz' -o -name '*.ko.zst' -o -name '*.ko.gz' \) -print)" || return 1
  local -A paths=() visited=()
  local -a queue=() dependencies=()
  while IFS= read -r ko; do
    [[ -n "${ko}" ]] || continue
    name="${ko##*/}"; name="${name%%.ko*}"; name="${name//-/_}"
    [[ -z "${paths[${name}]:-}" ]] || { bluetooth_firmware_error "duplicate module ${name}"; return 1; }
    paths["${name}"]="${ko}"
    case "${ko}" in */kernel/drivers/bluetooth/*|*/kernel/net/bluetooth/*|*/kernel/drivers/hid/uhid.ko*) queue+=("${name}") ;; esac
  done <<<"${listing}"
  (( ${#queue[@]} > 0 )) || { bluetooth_firmware_error 'zero Bluetooth/UHID modules'; return 1; }
  local -i i count=0
  for ((i=0; i<${#queue[@]}; i++)); do
    name="${queue[i]}"; [[ -z "${visited[${name}]:-}" ]] || continue
    visited["${name}"]=1
    ko="${paths[${name}]:-}"
    [[ -n "${ko}" ]] || { bluetooth_firmware_error "missing dependency module ${name}"; return 1; }
    if ! deps="$(modinfo -F depends "${ko}")" || ! refs="$(modinfo -F firmware "${ko}")"; then
      bluetooth_firmware_error "unparseable closure module ${name}"; return 1
    fi
    IFS=, read -r -a dependencies <<<"${deps}"
    for dep in "${dependencies[@]}"; do [[ -z "${dep}" ]] || queue+=("${dep//-/_}"); done
    while IFS= read -r ref; do
      [[ -n "${ref}" ]] || continue
      key="${name}:${ref}"
      case "${BT_FW_CLASSES[${key}]:-}" in
        reviewed-hardware-gap)
          if [[ ! -f "${fw}/${ref}" ]]; then
            printf 'reviewed-hardware-gap module=%s firmware=%s\n' "${name}" "${ref}"
            continue
          fi ;;
        static) ;;
        *) bluetooth_firmware_error "unknown static reference module=${name} firmware=${ref}"; return 1 ;;
      esac
      [[ -f "${fw}/${ref}" ]] || { bluetooth_firmware_error "missing static object module=${name} firmware=${ref}"; return 1; }
    done <<<"${refs}"
    count+=1
  done
  printf 'Bluetooth firmware closure: %s parsed modules\n' "${count}"
}

bluetooth_firmware_prepare() {
  bluetooth_firmware_load "$3" && bluetooth_firmware_scan "$1" "$2" && bluetooth_firmware_snapshot "$2"
}

bluetooth_firmware_assert_candidates() {
  local candidate object
  for candidate in "$@"; do
    for object in "${BT_FW_OBJECTS[@]}"; do
      if [[ "${object}" == "${candidate}" || "${object}" == "${candidate}/"* ]]; then
        # Intel was already a candidate; protect its runtime-only Bluetooth files.
        [[ "${candidate}" == intel ]] && continue
        bluetooth_firmware_error "Bluetooth prune candidate ${candidate} overlaps ${object}"; return 1
      fi
    done
  done
}

bluetooth_firmware_assert_retained() {
  local fw="$1" object
  for object in "${BT_FW_OBJECTS[@]}"; do
    [[ -f "${fw}/${object}" ]] || { bluetooth_firmware_error "removed closure object ${object}"; return 1; }
  done
}
