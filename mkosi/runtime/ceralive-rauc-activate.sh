#!/usr/bin/env bash
set -uo pipefail

STATE_DIR="${CERALIVE_ACTIVATION_STATE_DIR:-/data/ceralive/update-state}"
ARMED="${STATE_DIR}/activation-armed"
STREAMING="${CERALIVE_STREAMING_MARKER:-/run/ceralive/streaming}"
LOCK="${CERALIVE_ACTIVATION_LOCK:-/run/lock/ceralive-rauc-activate.lock}"

log() { printf 'ceralive-rauc-activate: %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

[[ $# -le 1 ]] || die 'usage: ceralive-rauc-activate [--arm|--disarm|--now]'
action="${1:---stop}"
case "$action" in --arm|--disarm|--now|--stop) ;; *) die "invalid action: $action" ;; esac
[[ $(id -u) -eq 0 ]] || die 'root is required (use systemctl start ceralive-rauc-arm@<action>.service)'

exec {lock_fd}>"$LOCK" || die 'cannot open activation lock'
flock -w 10 "$lock_fd" || die 'cannot acquire activation lock'

if [[ "$action" == --disarm ]]; then
  rm -f -- "$ARMED" || die 'cannot remove activation marker'
  log 'activation disarmed'
  exit 0
fi
if [[ "$action" == --stop && ! -f "$ARMED" ]]; then
  exit 0
fi
if [[ -e "$STREAMING" ]]; then
  if [[ "$action" == --stop ]]; then
    log 'streaming still present: deferring activation'
    exit 0
  fi
  [[ "$action" == --arm ]] || die 'streaming still present: activation refused'
fi

# The pinned RAUC 1.15.2 reports per-slot install/activation timestamps in the detailed
# shell status. Never source that output: slot metadata may contain bundle text.
status="$(rauc status --detailed --output-format=shell)" || die 'RAUC status unavailable'
declare -A bootnames=() states=() installed=() activated=()
primary='' booted='' slot_names='' slot_indexes=''
while IFS= read -r line; do
  key="${line%%=*}"
  value="${line#*=}"
  case "$key" in
    RAUC_BOOT_PRIMARY|RAUC_SYSTEM_BOOTED_BOOTNAME|RAUC_SYSTEM_SLOTS|RAUC_SLOTS|\
    RAUC_SLOT_BOOTNAME_*|RAUC_SLOT_STATE_*|\
    RAUC_SLOT_STATUS_INSTALLED_TIMESTAMP_*|RAUC_SLOT_STATUS_ACTIVATED_TIMESTAMP_*) ;;
    *) continue ;;
  esac
  [[ "$value" == "'"*"'" && ${#value} -ge 2 ]] || die "invalid RAUC shell value for $key"
  value="${value:1:${#value}-2}"
  [[ "$value" != *"'"* ]] || die "unsupported RAUC shell quoting in $key"
  case "$key" in
    RAUC_BOOT_PRIMARY) primary="$value" ;;
    RAUC_SYSTEM_BOOTED_BOOTNAME) booted="$value" ;;
    RAUC_SYSTEM_SLOTS) slot_names="$value" ;;
    RAUC_SLOTS) slot_indexes="$value" ;;
    RAUC_SLOT_BOOTNAME_*) bootnames["${key##*_}"]="$value" ;;
    RAUC_SLOT_STATE_*) states["${key##*_}"]="$value" ;;
    RAUC_SLOT_STATUS_INSTALLED_TIMESTAMP_*) installed["${key##*_}"]="$value" ;;
    RAUC_SLOT_STATUS_ACTIVATED_TIMESTAMP_*) activated["${key##*_}"]="$value" ;;
  esac
done <<<"$status"

[[ -n "$primary" && -n "$booted" ]] || die 'RAUC booted/primary identity missing'
read -r -a names <<<"$slot_names"
read -r -a indexes <<<"$slot_indexes"
[[ ${#names[@]} -eq ${#indexes[@]} && ${#names[@]} -gt 0 ]] || die 'RAUC slot indexes/names mismatch'
booted_name='' other='' other_idx='' rootfs_count=0
for position in "${!names[@]}"; do
  idx="${indexes[$position]}"
  [[ "$idx" =~ ^[1-9][0-9]*$ ]] || die 'invalid RAUC slot index'
  [[ "${names[$position]}" == rootfs.* ]] || continue
  [[ -n "${bootnames[$idx]:-}" ]] || die 'RAUC rootfs bootname missing'
  rootfs_count=$((rootfs_count + 1))
  if [[ "${bootnames[$idx]}" == "$booted" ]]; then
    booted_name="${names[$position]}"
  else
    other="${names[$position]}"
    other_idx="$idx"
    [[ "${states[$idx]:-}" == inactive ]] || die 'other rootfs is not inactive'
  fi
done
[[ "$rootfs_count" == 2 && "$booted_name" == "$primary" && -n "$other_idx" ]] \
  || die 'RAUC primary/booted rootfs mismatch or not exactly two bootable slots'

stamp="${installed[$other_idx]:-}"
previous="${activated[$other_idx]:-}"
if [[ -z "$stamp" ]]; then
  [[ "$action" == --arm ]] && die 'no installed other rootfs to arm'
  log 'no installed other rootfs: activation deferred'
  exit 0
fi
install_epoch="$(date -u -d "$stamp" +%s)" || die 'invalid RAUC installed timestamp'
activation_epoch=0
if [[ -n "$previous" ]]; then
  activation_epoch="$(date -u -d "$previous" +%s)" || die 'invalid RAUC activated timestamp'
fi
if (( install_epoch <= activation_epoch )); then
  [[ "$action" == --arm ]] && die 'other rootfs already activated; no pending install'
  log 'other rootfs has no unactivated install'
  exit 0
fi

if [[ "$action" == --arm ]]; then
  install -d -m 0750 "$STATE_DIR" || die 'cannot create activation state directory'
  umask 077
  : >"$ARMED" || die 'cannot arm activation'
  log "armed pending $other"
  exit 0
fi
[[ -f "$ARMED" ]] || die 'activation is not armed'
[[ ! -e "$STREAMING" ]] || die 'streaming began during activation check'
rauc status mark-active other || die 'RAUC mark-active other failed'
rm -f -- "$ARMED" || die 'marked active but failed to disarm; inspect RAUC state'
log "activated staged $other ($action); no reboot requested"
