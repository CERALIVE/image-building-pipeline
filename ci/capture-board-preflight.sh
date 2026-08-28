#!/usr/bin/env bash
#
# capture-board-preflight.sh — read-only hardware inventory of a bench board.
#
# WHY this exists: Wave 8 refuses to build, flash or deploy anything against a
# board whose layout, kernel, RAUC slot state and installed trust anchor have
# not been READ from that board first. Every fact this emits is a fact a later
# hardware-evidence tuple claims, so it is captured once, from the device, into
# a parseable file — never retyped from a terminal and never assumed from a
# manifest.
#
# It is READ-ONLY BY CONSTRUCTION. The remote payload runs no command that
# writes to the board, changes RAUC slot state, loads a module, reboots, or
# touches package state. `assert_payload_is_read_only` re-proves that on every
# invocation (including --self-test) by screening the payload text itself, so a
# future edit that adds a write cannot ship quietly.
#
# It uses ONLY interfaces present on the production package set. Two of the
# interfaces the plan expected are NOT on a real device and are recorded as
# honestly unavailable rather than worked around:
#   * `sfdisk` is absent entirely (util-linux 2.38.1 is installed, sfdisk is
#     not). Partition geometry therefore comes from sysfs
#     (`/sys/class/block/<part>/{start,size}`), which is non-root readable and
#     is the same information in the same units (512-byte sectors).
#   * `blkid` exists at /usr/sbin/blkid but probes nothing as an unprivileged
#     user, and this capture deliberately does NOT escalate. Filesystem
#     identity comes from `lsblk`, which reports FSTYPE/UUID/PARTLABEL/PARTUUID
#     from udev without privilege.
# `lspci`/`lsusb`/`gdisk` are likewise absent, so PCI and USB inventory is read
# straight out of sysfs.
#
# Usage:
#   capture-board-preflight.sh --host <host> --board <board> --out <dir> \
#       [--ssh-user <user>] [--ssh-identity <path>] [--connect-timeout <secs>] \
#       [--command-timeout <secs>]
#   capture-board-preflight.sh --self-test
#
# Outputs (into <dir>):
#   <board>-preflight.json   the full capture (or an honest unreachable record)
#   <board>-keyring.pem      the board's installed RAUC keyring, verbatim
#                            (present only when the board was reachable and
#                            carries one) — this is the file
#                            ci/verify-bench-rauc-trust.sh anchors against
#
# Exit codes:
#   0  board reachable, capture written
#   2  usage / local error (nothing written)
#   3  board NOT reachable — an unreachable record WAS written, and that is a
#      result, not a tool failure
#   1  reachable but the capture was unusable (or a self-test leg failed)
#
# shellcheck shell=bash

set -uo pipefail

SCHEMA_VERSION=1
TOOL_NAME="ci/capture-board-preflight.sh"

usage() { sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
fail() { printf 'capture-board-preflight: %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# The remote payload.
#
# It is emitted as TEXT so the identical bytes can be (a) piped to `ssh … bash
# -s` and (b) executed locally against a fixture tree by --self-test. Nothing
# in it is host-expanded: PF_ROOT prefixes every filesystem read and PF_BIN_DIR
# prepends the command search path, and BOTH are empty on a real board.
# ---------------------------------------------------------------------------
preflight_payload() {
  cat <<'PAYLOAD'
set -uo pipefail
PF_ROOT="${PF_ROOT:-}"
[ -n "${PF_BIN_DIR:-}" ] && PATH="${PF_BIN_DIR}:${PATH}"
# A production image keeps blkid/modinfo in /usr/sbin, which is not on an
# unprivileged login PATH. Adding the sbin dirs is a LOOKUP change only.
PATH="${PATH}:/usr/local/sbin:/usr/sbin:/sbin"
export PATH

pf_read() { cat "${PF_ROOT}$1" 2>/dev/null | tr -d '\000'; }
pf_exists() { [ -e "${PF_ROOT}$1" ]; }
pf_first_line() { pf_read "$1" | head -1; }
# PF_ABSENT_TOOLS is a SELF-TEST-ONLY fault injection: it is always empty on a
# real board. It exists because "this device does not ship sfdisk" is a real,
# load-bearing board condition that a fixture cannot otherwise reproduce on a
# developer box that does ship it — and the honest-unavailability branch is
# exactly the branch that must never regress into a silent null.
have() {
  case " ${PF_ABSENT_TOOLS:-} " in *" $1 "*) return 1 ;; esac
  command -v "$1" >/dev/null 2>&1
}

jesc() {
  local s="${1-}"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')"
  s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}
jstr() { printf '"%s"' "$(jesc "${1-}")"; }
jopt() { if [ -z "${1-}" ]; then printf 'null'; else jstr "$1"; fi; }
jbool() { if [ "${1-}" = "1" ]; then printf 'true'; else printf 'false'; fi; }
jnum() { case "${1-}" in ''|*[!0-9]*) printf 'null' ;; *) printf '%s' "$1" ;; esac; }
# jraw <text> — embed already-JSON output, or null when it is not an object.
jraw() {
  local t="${1-}"
  case "${t}" in
    \{*|\[*) printf '%s' "$t" ;;
    *) printf 'null' ;;
  esac
}
# jmulti <text> — a multi-line command output as a JSON array of lines.
jmulti() {
  local line first=1
  printf '['
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    [ "${first}" = 1 ] || printf ','
    first=0
    jstr "${line}"
  done <<EOF
${1-}
EOF
  printf ']'
}

printf '{'
printf '"collected_by":"remote-payload"'

# --- tooling census -------------------------------------------------------
# Recorded FIRST and in full: which interfaces this device actually offers is
# itself an inventory fact, and it is the fact that explains every null below.
printf ',"tooling":{'
tool_first=1
for t in uname rauc lsblk blkid sfdisk findmnt udevadm modinfo openssl \
         ceralive-boot-state dpkg-query lspci lsusb sgdisk gdisk python3 jq; do
  [ "${tool_first}" = 1 ] || printf ','
  tool_first=0
  printf '%s:%s' "$(jstr "$t")" "$(jopt "$(command -v "$t" 2>/dev/null)")"
done
printf '}'

# --- kernel / OS ----------------------------------------------------------
printf ',"uname":{"raw":%s,"release":%s,"machine":%s,"nodename":%s}' \
  "$(jopt "$(uname -a 2>/dev/null)")" \
  "$(jopt "$(uname -r 2>/dev/null)")" \
  "$(jopt "$(uname -m 2>/dev/null)")" \
  "$(jopt "$(uname -n 2>/dev/null)")"
printf ',"os_release":{"id":%s,"version_id":%s,"pretty_name":%s}' \
  "$(jopt "$(pf_read /etc/os-release | sed -n 's/^ID=//p' | tr -d '"' | head -1)")" \
  "$(jopt "$(pf_read /etc/os-release | sed -n 's/^VERSION_ID=//p' | tr -d '"' | head -1)")" \
  "$(jopt "$(pf_read /etc/os-release | sed -n 's/^PRETTY_NAME=//p' | tr -d '"' | head -1)")"
printf ',"cmdline":%s' "$(jopt "$(pf_first_line /proc/cmdline)")"
printf ',"device_tree_compatible":%s' \
  "$(jopt "$(pf_read /proc/device-tree/compatible | tr '\000' ' ' | sed 's/ *$//')")"

# --- installed first-party package versions -------------------------------
printf ',"packages":'
if have dpkg-query; then
  jmulti "$(dpkg-query -W -f='${Package} ${Version}\n' \
      ceralive-device cerastream srtla-send-rs libsrt1.5-ceralive rauc \
      util-linux kmod 2>/dev/null)"
else
  printf 'null'
fi

# --- RAUC -----------------------------------------------------------------
rauc_conf_path="/etc/rauc/system.conf"
rauc_keyring_path="$(pf_read "${rauc_conf_path}" | sed -n 's/^path=//p' | head -1)"
[ -n "${rauc_keyring_path}" ] || rauc_keyring_path="/etc/rauc/ceralive-keyring.pem"
printf ',"rauc":{'
printf '"available":%s' "$(if have rauc; then printf true; else printf false; fi)"
printf ',"version":%s' "$(jopt "$(rauc --version 2>/dev/null | head -1)")"
printf ',"compatible":%s' \
  "$(jopt "$(pf_read "${rauc_conf_path}" | sed -n 's/^compatible=//p' | head -1)")"
printf ',"bootloader":%s' \
  "$(jopt "$(pf_read "${rauc_conf_path}" | sed -n 's/^bootloader=//p' | head -1)")"
printf ',"system_conf_path":%s' "$(jstr "${rauc_conf_path}")"
printf ',"system_conf":%s' "$(jopt "$(pf_read "${rauc_conf_path}")")"
printf ',"keyring_path":%s' "$(jstr "${rauc_keyring_path}")"
printf ',"status":%s' "$(jraw "$(rauc status --output-format=json 2>/dev/null | head -c 65536)")"
printf '}'

# --- installed keyring certificate chain ----------------------------------
# The keyring is the device's IMMUTABLE root of trust; its fingerprint is what
# any candidate RAUC signer must terminate at. Emitted verbatim (PEM) so the
# trust verifier anchors against the bytes the board actually carries.
printf ',"keyring":{'
printf '"path":%s' "$(jstr "${rauc_keyring_path}")"
if pf_exists "${rauc_keyring_path}"; then
  keyring_pem="$(pf_read "${rauc_keyring_path}")"
  printf ',"present":true'
  printf ',"cert_count":%s' \
    "$(jnum "$(printf '%s\n' "${keyring_pem}" | grep -c 'BEGIN CERTIFICATE')")"
  printf ',"pem":%s' "$(jstr "${keyring_pem}")"
  printf ',"certificates":['
  if have openssl; then
    cert_i=0
    tmp_split="$(mktemp 2>/dev/null)" || tmp_split=""
    if [ -n "${tmp_split}" ]; then
      printf '%s\n' "${keyring_pem}" > "${tmp_split}"
      # openssl reads only the FIRST cert of a bundle per invocation, so the
      # bundle is walked cert-by-cert rather than parsed once.
      total="$(grep -c 'BEGIN CERTIFICATE' "${tmp_split}")"
      n=1
      while [ "${n}" -le "${total}" ]; do
        one="$(awk -v want="${n}" '
          /BEGIN CERTIFICATE/ { c++ }
          c == want { print }
          /END CERTIFICATE/ && c == want { exit }' "${tmp_split}")"
        [ "${cert_i}" = 0 ] || printf ','
        cert_i=1
        printf '{"index":%s' "${n}"
        printf ',"subject":%s' "$(jopt "$(printf '%s\n' "${one}" | openssl x509 -noout -subject 2>/dev/null | sed 's/^subject=//')")"
        printf ',"issuer":%s' "$(jopt "$(printf '%s\n' "${one}" | openssl x509 -noout -issuer 2>/dev/null | sed 's/^issuer=//')")"
        printf ',"serial":%s' "$(jopt "$(printf '%s\n' "${one}" | openssl x509 -noout -serial 2>/dev/null | sed 's/^serial=//')")"
        printf ',"not_before":%s' "$(jopt "$(printf '%s\n' "${one}" | openssl x509 -noout -startdate 2>/dev/null | sed 's/^notBefore=//')")"
        printf ',"not_after":%s' "$(jopt "$(printf '%s\n' "${one}" | openssl x509 -noout -enddate 2>/dev/null | sed 's/^notAfter=//')")"
        printf ',"sha256_fingerprint":%s' \
          "$(jopt "$(printf '%s\n' "${one}" | openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*Fingerprint=//' | tr 'A-F' 'a-f')")"
        printf '}'
        n=$((n + 1))
      done
      rm -f "${tmp_split}"
    fi
  fi
  printf ']'
else
  printf ',"present":false,"cert_count":0,"pem":null,"certificates":[]'
fi
printf '}'

# --- boot-state helper ----------------------------------------------------
printf ',"boot_state":{'
printf '"tool":%s' "$(jopt "$(command -v ceralive-boot-state 2>/dev/null)")"
if have ceralive-boot-state; then
  bs_dump="$(ceralive-boot-state dump 2>/dev/null)"
  printf ',"dump":%s' "$(jmulti "${bs_dump}")"
  printf ',"boot_order":%s' "$(jopt "$(printf '%s\n' "${bs_dump}" | sed -n 's/^BOOT_ORDER=//p' | head -1)")"
  printf ',"a_left":%s' "$(jnum "$(printf '%s\n' "${bs_dump}" | sed -n 's/^BOOT_A_LEFT=//p' | head -1)")"
  printf ',"b_left":%s' "$(jnum "$(printf '%s\n' "${bs_dump}" | sed -n 's/^BOOT_B_LEFT=//p' | head -1)")"
else
  printf ',"dump":null,"boot_order":null,"a_left":null,"b_left":null'
fi
printf '}'

# --- storage layout -------------------------------------------------------
printf ',"storage":{'
printf '"lsblk":%s' "$(jraw "$(lsblk -J -o NAME,PATH,SIZE,TYPE,FSTYPE,PARTLABEL,PARTUUID,UUID,MOUNTPOINT 2>/dev/null)")"
if have blkid; then
  blkid_out="$(blkid 2>/dev/null)"
  if [ -n "${blkid_out}" ]; then
    printf ',"blkid":{"available":true,"reason":null,"entries":%s}' "$(jmulti "${blkid_out}")"
  else
    printf ',"blkid":{"available":false,"reason":%s,"entries":[]}' \
      "$(jstr "installed but returns nothing to an unprivileged user; this capture does not escalate — filesystem identity is taken from lsblk instead")"
  fi
else
  printf ',"blkid":{"available":false,"reason":%s,"entries":[]}' \
    "$(jstr "not present on the production package set")"
fi
if have sfdisk; then
  printf ',"sfdisk":{"available":true,"reason":null,"dump":%s}' \
    "$(jopt "$(sfdisk --dump "$(pf_read /proc/cmdline >/dev/null; echo /dev/mmcblk1)" 2>/dev/null)")"
else
  printf ',"sfdisk":{"available":false,"reason":%s,"dump":null}' \
    "$(jstr "not present on the production package set (util-linux is installed, sfdisk is not); partition geometry below is read from sysfs in the same 512-byte sector units")"
fi
printf ',"partitions":['
part_first=1
for blk in "${PF_ROOT}"/sys/class/block/*; do
  [ -e "${blk}/partition" ] || continue
  pname="$(basename "${blk}")"
  pparent="$(basename "$(dirname "$(readlink -f "${blk}" 2>/dev/null)")")"
  lbs="$(cat "$(dirname "$(readlink -f "${blk}" 2>/dev/null)")/queue/logical_block_size" 2>/dev/null)"
  [ "${part_first}" = 1 ] || printf ','
  part_first=0
  printf '{"name":%s,"parent":%s,"partition_index":%s,"start_sector":%s,"size_sectors":%s,"logical_block_size":%s}' \
    "$(jstr "${pname}")" "$(jstr "${pparent}")" \
    "$(jnum "$(cat "${blk}/partition" 2>/dev/null)")" \
    "$(jnum "$(cat "${blk}/start" 2>/dev/null)")" \
    "$(jnum "$(cat "${blk}/size" 2>/dev/null)")" \
    "$(jnum "${lbs}")"
done
printf ']}'

# --- mounts ---------------------------------------------------------------
printf ',"mounts":%s' "$(jraw "$(findmnt -J -o TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null)")"

# --- network interfaces + ID_PATH ----------------------------------------
printf ',"interfaces":['
if_first=1
for ifp in "${PF_ROOT}"/sys/class/net/*; do
  [ -e "${ifp}" ] || continue
  ifn="$(basename "${ifp}")"
  [ "${ifn}" = "lo" ] && continue
  idpath=""
  if have udevadm; then
    idpath="$(udevadm info "/sys/class/net/${ifn}" 2>/dev/null | sed -n 's/^E: ID_PATH=//p' | head -1)"
  fi
  drv="$(basename "$(readlink -f "${ifp}/device/driver" 2>/dev/null)" 2>/dev/null)"
  [ "${drv}" = "." ] && drv=""
  [ "${if_first}" = 1 ] || printf ','
  if_first=0
  printf '{"name":%s,"mac":%s,"operstate":%s,"driver":%s,"id_path":%s,"wireless":%s}' \
    "$(jstr "${ifn}")" \
    "$(jopt "$(cat "${ifp}/address" 2>/dev/null)")" \
    "$(jopt "$(cat "${ifp}/operstate" 2>/dev/null)")" \
    "$(jopt "${drv}")" \
    "$(jopt "${idpath}")" \
    "$(if [ -d "${ifp}/wireless" ] || [ -d "${ifp}/phy80211" ]; then printf true; else printf false; fi)"
done
printf ']'

# --- PCI inventory (sysfs, never lspci) -----------------------------------
printf ',"pci":['
pci_first=1
for d in "${PF_ROOT}"/sys/bus/pci/devices/*; do
  [ -e "${d}/vendor" ] || continue
  pdrv="$(basename "$(readlink -f "${d}/driver" 2>/dev/null)" 2>/dev/null)"
  [ "${pdrv}" = "." ] && pdrv=""
  [ "${pci_first}" = 1 ] || printf ','
  pci_first=0
  printf '{"slot":%s,"vendor":%s,"device":%s,"class":%s,"driver":%s}' \
    "$(jstr "$(basename "${d}")")" \
    "$(jopt "$(cat "${d}/vendor" 2>/dev/null)")" \
    "$(jopt "$(cat "${d}/device" 2>/dev/null)")" \
    "$(jopt "$(cat "${d}/class" 2>/dev/null)")" \
    "$(jopt "${pdrv}")"
done
printf ']'

# --- USB topology + negotiated speeds (sysfs, never lsusb) ----------------
printf ',"usb":['
usb_first=1
for d in "${PF_ROOT}"/sys/bus/usb/devices/*; do
  [ -e "${d}/idVendor" ] || continue
  [ "${usb_first}" = 1 ] || printf ','
  usb_first=0
  printf '{"path":%s,"id_vendor":%s,"id_product":%s,"speed_mbps":%s,"product":%s,"manufacturer":%s,"bus_num":%s,"dev_num":%s}' \
    "$(jstr "$(basename "${d}")")" \
    "$(jopt "$(cat "${d}/idVendor" 2>/dev/null)")" \
    "$(jopt "$(cat "${d}/idProduct" 2>/dev/null)")" \
    "$(jopt "$(cat "${d}/speed" 2>/dev/null)")" \
    "$(jopt "$(cat "${d}/product" 2>/dev/null)")" \
    "$(jopt "$(cat "${d}/manufacturer" 2>/dev/null)")" \
    "$(jnum "$(cat "${d}/busnum" 2>/dev/null)")" \
    "$(jnum "$(cat "${d}/devnum" 2>/dev/null)")"
done
printf ']'

# --- Wi-Fi / Bluetooth modules + firmware ---------------------------------
# Modules are DISCOVERED from the live device tree (wireless netdev drivers and
# the bluetooth class), never from a hardcoded name list, then described with
# modinfo. A hardcoded list would silently report nothing on a board whose
# adapter differs.
wifi_bt_mods=""
for ifp in "${PF_ROOT}"/sys/class/net/*; do
  { [ -d "${ifp}/wireless" ] || [ -d "${ifp}/phy80211" ]; } || continue
  m="$(basename "$(readlink -f "${ifp}/device/driver" 2>/dev/null)" 2>/dev/null)"
  [ -n "${m}" ] && [ "${m}" != "." ] && wifi_bt_mods="${wifi_bt_mods} ${m}"
done
for bt in "${PF_ROOT}"/sys/class/bluetooth/*; do
  [ -e "${bt}" ] || continue
  m="$(basename "$(readlink -f "${bt}/device/driver" 2>/dev/null)" 2>/dev/null)"
  [ -n "${m}" ] && [ "${m}" != "." ] && wifi_bt_mods="${wifi_bt_mods} ${m}"
  m2="$(basename "$(readlink -f "${bt}/device/../driver" 2>/dev/null)" 2>/dev/null)"
  [ -n "${m2}" ] && [ "${m2}" != "." ] && wifi_bt_mods="${wifi_bt_mods} ${m2}"
done
printf ',"wireless_bluetooth":{'
printf '"discovered_modules":%s' "$(jmulti "$(printf '%s\n' ${wifi_bt_mods} | sort -u)")"
printf ',"modules":['
mod_first=1
for m in $(printf '%s\n' ${wifi_bt_mods} | sort -u); do
  have modinfo || break
  [ "${mod_first}" = 1 ] || printf ','
  mod_first=0
  printf '{"name":%s,"filename":%s,"version":%s,"vermagic":%s,"intree":%s,"firmware":%s}' \
    "$(jstr "${m}")" \
    "$(jopt "$(modinfo -F filename "${m}" 2>/dev/null | head -1)")" \
    "$(jopt "$(modinfo -F version "${m}" 2>/dev/null | head -1)")" \
    "$(jopt "$(modinfo -F vermagic "${m}" 2>/dev/null | head -1)")" \
    "$(jopt "$(modinfo -F intree "${m}" 2>/dev/null | head -1)")" \
    "$(jmulti "$(modinfo -F firmware "${m}" 2>/dev/null)")"
done
printf ']'
printf ',"loaded_modules":%s' \
  "$(jmulti "$(pf_read /proc/modules | awk '{print $1}' | grep -Ei 'rtw|bt|blue|mac80211|cfg80211|rfkill' | sort)")"
printf ',"rfkill":['
rf_first=1
for rf in "${PF_ROOT}"/sys/class/rfkill/*; do
  [ -e "${rf}/name" ] || continue
  [ "${rf_first}" = 1 ] || printf ','
  rf_first=0
  printf '{"name":%s,"type":%s,"soft":%s,"hard":%s}' \
    "$(jopt "$(cat "${rf}/name" 2>/dev/null)")" \
    "$(jopt "$(cat "${rf}/type" 2>/dev/null)")" \
    "$(jnum "$(cat "${rf}/soft" 2>/dev/null)")" \
    "$(jnum "$(cat "${rf}/hard" 2>/dev/null)")"
done
printf ']}'

printf '}'
printf '\n'
PAYLOAD
}

# ---------------------------------------------------------------------------
# Read-only self-guard.
#
# The payload is the ONLY thing that ever runs on a real board, so the
# read-only promise is enforced against its text on every invocation. Each
# pattern is a whole-word match on a command position, so `readlink` cannot be
# mistaken for a write and `rm -f "${tmp_split}"` (a local mktemp scratch file,
# not board state) is admitted by name.
# ---------------------------------------------------------------------------
assert_payload_is_read_only() {
  local payload="$1" bad=0 pat
  local -a forbidden=(
    'rauc[[:space:]]+install' 'rauc[[:space:]]+mark'
    'ceralive-boot-state[[:space:]]+(init|set-primary|set-state|mark-good|boot-select)'
    '(^|[^[:alnum:]_/-])(reboot|shutdown|poweroff|halt)([[:space:]]|$)'
    '(^|[^[:alnum:]_/-])(dd|mkfs[.a-z0-9]*|sfdisk[[:space:]]+--wipe|parted|wipefs|fdisk)([[:space:]]|$)'
    '(^|[^[:alnum:]_/-])(apt|apt-get|dpkg[[:space:]]+-i|modprobe|insmod|rmmod|systemctl)([[:space:]]|$)'
    '(^|[^[:alnum:]_/-])(mount|umount|chmod|chown|ln[[:space:]]+-s|touch|tee)([[:space:]]|$)'
  )
  for pat in "${forbidden[@]}"; do
    if grep -Eq -- "${pat}" <<<"${payload}"; then
      fail "remote payload contains a forbidden non-read-only construct: ${pat}"
      bad=1
    fi
  done
  # Redirections into a path are writes unless they target the local scratch
  # file the keyring walk needs.
  if grep -Eq '>[[:space:]]*"?\$\{?PF_ROOT' <<<"${payload}"; then
    fail "remote payload redirects into a board path"
    bad=1
  fi
  return "${bad}"
}

json_escape() {
  local s="${1-}"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')"
  s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

# write_envelope <out-file> <board> <host> <reachable:0|1> <error> <inventory-json>
write_envelope() {
  local out="$1" board="$2" host="$3" reachable="$4" err="$5" inventory="$6"
  {
    printf '{\n'
    printf '  "schema_version": %s,\n' "${SCHEMA_VERSION}"
    printf '  "capture_tool": "%s",\n' "$(json_escape "${TOOL_NAME}")"
    printf '  "board": "%s",\n' "$(json_escape "${board}")"
    printf '  "host": "%s",\n' "$(json_escape "${host}")"
    printf '  "captured_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '  "read_only": true,\n'
    if [[ "${reachable}" == 1 ]]; then
      printf '  "reachable": true,\n'
      printf '  "error": null,\n'
      printf '  "inventory": %s\n' "${inventory}"
    else
      printf '  "reachable": false,\n'
      printf '  "error": "%s",\n' "$(json_escape "${err}")"
      printf '  "inventory": null\n'
    fi
    printf '}\n'
  } >"${out}"
}

# extract_keyring_pem <preflight-json> — pull the verbatim PEM back out.
extract_keyring_pem() {
  sed -n 's/.*"keyring":{[^}]*"pem":"\(-----BEGIN[^"]*\)".*/\1/p' "$1" \
    | head -1 | sed 's/\\n/\n/g'
}

capture() {
  local host="$1" board="$2" outdir="$3" ssh_user="$4" identity="$5"
  local connect_timeout="$6" command_timeout="$7"
  local out payload rc stdout stderr

  mkdir -p "${outdir}" || { fail "cannot create ${outdir}"; return 2; }
  out="${outdir}/${board}-preflight.json"

  payload="$(preflight_payload)"
  assert_payload_is_read_only "${payload}" || return 2

  local -a ssh_cmd=(ssh -o BatchMode=yes -o ConnectTimeout="${connect_timeout}"
                    -o StrictHostKeyChecking=accept-new)
  [[ -z "${identity}" ]] || ssh_cmd+=(-i "${identity}")
  ssh_cmd+=("${ssh_user:+${ssh_user}@}${host}" 'bash -s')

  stdout="$(mktemp)"; stderr="$(mktemp)"
  timeout "${command_timeout}" "${ssh_cmd[@]}" <<<"${payload}" \
    >"${stdout}" 2>"${stderr}"
  rc=$?

  if (( rc != 0 )) && [[ ! -s "${stdout}" ]]; then
    local err
    err="$(head -3 "${stderr}" | tr '\n' ' ')"
    [[ -n "${err}" ]] || err="ssh exited ${rc} with no diagnostic (timed out after ${command_timeout}s)"
    write_envelope "${out}" "${board}" "${host}" 0 "${err}" 'null'
    printf 'capture-board-preflight: %s UNREACHABLE — %s\n' "${board}" "${err}" >&2
    printf 'capture-board-preflight: wrote unreachable record %s\n' "${out}"
    rm -f "${stdout}" "${stderr}"
    return 3
  fi

  local inventory
  inventory="$(cat "${stdout}")"
  rm -f "${stdout}" "${stderr}"
  case "${inventory}" in
    \{*\}) : ;;
    *) fail "${board}: remote payload did not return a JSON object"; return 1 ;;
  esac

  write_envelope "${out}" "${board}" "${host}" 1 '' "${inventory}"

  local pem
  pem="$(extract_keyring_pem "${out}")"
  if [[ "${pem}" == -----BEGIN* ]]; then
    printf '%s\n' "${pem}" >"${outdir}/${board}-keyring.pem"
    printf 'capture-board-preflight: wrote %s and %s-keyring.pem\n' "${out}" "${board}"
  else
    printf 'capture-board-preflight: wrote %s (board carries no RAUC keyring)\n' "${out}"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# self-test — the payload is executed for real against a synthetic sysfs/proc
# fixture with stubbed device commands and a REAL generated certificate, so the
# keyring walk exercises real openssl rather than a canned string.
# ---------------------------------------------------------------------------
self_test() {
  local failures=0 tmp
  # The os-release fixture below must model the release the image actually
  # targets, so it is read from the ONE mapping rather than frozen. Loaded HERE
  # and not at file scope: the real capture path runs against a live board and
  # must not gain a dependency on a repo file it does not need.
  # shellcheck source=../lib/shared/target-release-lib.sh
  source "$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../lib/shared" && pwd)/target-release-lib.sh"
  target_release_load
  tmp="$(mktemp -d)" || { fail "mktemp -d failed"; return 1; }
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  check() {
    local label="$1"; shift
    if "$@"; then printf '  ok   %s\n' "${label}"
    else printf '  FAIL %s\n' "${label}"; failures=$((failures + 1)); fi
  }

  local payload root bin
  payload="$(preflight_payload)"
  root="${tmp}/root"; bin="${tmp}/bin"
  mkdir -p "${bin}"
  mkdir -p "${root}"/{etc/rauc,proc,sys/class/block/sdz1,sys/class/net/eth9/device,sys/class/net/wlan9/{wireless,device},sys/bus/pci/devices/0000:00:01.0,sys/bus/usb/devices/9-1,sys/class/rfkill/rfkill0,sys/class/bluetooth/hci0/device}

  # --- fixture: a REAL self-signed root CA in the keyring -------------------
  openssl req -x509 -newkey rsa:2048 -keyout "${tmp}/fixture-root.key" \
    -out "${root}/etc/rauc/ceralive-keyring.pem" -days 3 -nodes \
    -subj '/CN=capture-preflight self-test root' >/dev/null 2>&1
  local fixture_fp
  fixture_fp="$(openssl x509 -in "${root}/etc/rauc/ceralive-keyring.pem" -noout \
    -fingerprint -sha256 | sed 's/^.*Fingerprint=//' | tr 'A-F' 'a-f')"

  cat >"${root}/etc/rauc/system.conf" <<'EOF'
[system]
compatible=ceralive-selftest-board
bootloader=custom
[keyring]
path=/etc/rauc/ceralive-keyring.pem
EOF
  cat >"${root}/etc/os-release" <<EOF
ID=debian
VERSION_ID="${OS_VERSION_ID}"
PRETTY_NAME="Debian GNU/Linux ${OS_VERSION_ID} (${RELEASE})"
EOF
  printf 'root=PARTLABEL=xrootfs_b rauc.slot=B\n' >"${root}/proc/cmdline"
  printf 'rtw89_core 700416 3 - Live 0x0\nbtusb 61440 0 - Live 0x0\n' >"${root}/proc/modules"

  # --- fixture: sysfs geometry, PCI, USB, netdevs, rfkill ------------------
  printf '1\n' >"${root}/sys/class/block/sdz1/partition"
  printf '32768\n' >"${root}/sys/class/block/sdz1/start"
  printf '524288\n' >"${root}/sys/class/block/sdz1/size"
  printf '0x10ec\n' >"${root}/sys/bus/pci/devices/0000:00:01.0/vendor"
  printf '0xb852\n' >"${root}/sys/bus/pci/devices/0000:00:01.0/device"
  printf '0x028000\n' >"${root}/sys/bus/pci/devices/0000:00:01.0/class"
  printf '19f7\n' >"${root}/sys/bus/usb/devices/9-1/idVendor"
  printf '0080\n' >"${root}/sys/bus/usb/devices/9-1/idProduct"
  printf '480\n' >"${root}/sys/bus/usb/devices/9-1/speed"
  printf 'Self Test Capture Device\n' >"${root}/sys/bus/usb/devices/9-1/product"
  printf 'aa:bb:cc:dd:ee:01\n' >"${root}/sys/class/net/eth9/address"
  printf 'up\n' >"${root}/sys/class/net/eth9/operstate"
  printf 'aa:bb:cc:dd:ee:02\n' >"${root}/sys/class/net/wlan9/address"
  printf 'down\n' >"${root}/sys/class/net/wlan9/operstate"
  printf 'hci0\n' >"${root}/sys/class/rfkill/rfkill0/name"
  printf 'bluetooth\n' >"${root}/sys/class/rfkill/rfkill0/type"
  printf '0\n' >"${root}/sys/class/rfkill/rfkill0/soft"
  printf '0\n' >"${root}/sys/class/rfkill/rfkill0/hard"
  mkdir -p "${root}/drivers/rtw89_pci" "${root}/drivers/btusb"
  ln -sf "${root}/drivers/rtw89_pci" "${root}/sys/class/net/wlan9/device/driver"
  ln -sf "${root}/drivers/btusb" "${root}/sys/class/bluetooth/hci0/device/driver"

  # --- fixture: stubbed device commands ------------------------------------
  cat >"${bin}/rauc" <<'EOF'
#!/bin/sh
case "$*" in
  --version) echo "rauc 1.8" ;;
  *json*) printf '{"compatible":"ceralive-selftest-board","booted":"B","slots":[]}\n' ;;
esac
EOF
  cat >"${bin}/lsblk" <<'EOF'
#!/bin/sh
printf '{"blockdevices":[{"name":"sdz","children":[{"name":"sdz1","partlabel":"xboot"}]}]}\n'
EOF
  cat >"${bin}/findmnt" <<'EOF'
#!/bin/sh
printf '{"filesystems":[{"target":"/","source":"/dev/sdz3","fstype":"ext4"}]}\n'
EOF
  cat >"${bin}/udevadm" <<'EOF'
#!/bin/sh
echo "E: ID_PATH=platform-selftest.pcie-pci-0000:00:01.0"
EOF
  cat >"${bin}/modinfo" <<'EOF'
#!/bin/sh
case "$1" in
  -F) case "$2" in
        filename) echo "/lib/modules/selftest/$3.ko" ;;
        firmware) echo "rtw89/selftest_fw.bin" ;;
        vermagic) echo "selftest SMP preempt aarch64" ;;
        intree)   echo "Y" ;;
      esac ;;
esac
EOF
  cat >"${bin}/ceralive-boot-state" <<'EOF'
#!/bin/sh
[ "$1" = dump ] || exit 1
printf 'STATE_FILE=/boot/boot_state.txt\nBOOT_ORDER=A B\nBOOT_A_LEFT=3\nBOOT_B_LEFT=2\n'
EOF
  cat >"${bin}/dpkg-query" <<'EOF'
#!/bin/sh
echo "rauc 1.8-2"
EOF
  # blkid is INSTALLED but answers nothing unprivileged, and sfdisk is not
  # installed at all. That is exactly the shape a real Rock 5B+ presents, and
  # the two branches differ, so the fixture reproduces both.
  cat >"${bin}/blkid" <<'EOF'
#!/bin/sh
exit 2
EOF
  chmod +x "${bin}"/*

  local out
  out="$(PF_ROOT="${root}" PF_BIN_DIR="${bin}" PF_ABSENT_TOOLS="sfdisk lspci lsusb" \
    bash <<<"${payload}" 2>"${tmp}/payload.err")"

  check "payload is screened read-only" assert_payload_is_read_only "${payload}"
  check "payload emits a single JSON object" \
    bash -c '[[ "$1" == \{*\} ]]' _ "${out}"
  check "payload writes nothing to stderr" \
    bash -c '[[ ! -s "$1" ]]' _ "${tmp}/payload.err"

  local -a required=(
    '"tooling"' '"uname"' '"os_release"' '"cmdline"' '"rauc"' '"keyring"'
    '"boot_state"' '"storage"' '"mounts"' '"interfaces"' '"pci"' '"usb"'
    '"wireless_bluetooth"'
  )
  local key
  for key in "${required[@]}"; do
    check "section ${key} present" bash -c 'grep -Fq "$1" <<<"$2"' _ "${key}" "${out}"
  done

  check "the REAL fixture root-CA fingerprint is reported" \
    bash -c 'grep -Fq "$1" <<<"$2"' _ "${fixture_fp}" "${out}"
  check "keyring PEM is carried verbatim" \
    bash -c 'grep -Fq "BEGIN CERTIFICATE" <<<"$1"' _ "${out}"
  check "absent sfdisk is reported unavailable with a reason, not silently" \
    bash -c 'grep -Eq "\"sfdisk\":\{\"available\":false,\"reason\":\"[^\"]+\"" <<<"$1"' _ "${out}"
  check "installed-but-unprivileged blkid is reported unavailable with a reason" \
    bash -c 'grep -Fq "installed but returns nothing to an unprivileged user" <<<"$1"' _ "${out}"
  check "sysfs partition geometry substitutes for sfdisk" \
    bash -c 'grep -Fq "\"start_sector\":32768,\"size_sectors\":524288" <<<"$1"' _ "${out}"
  check "PCI inventory comes from sysfs (vendor/device/class)" \
    bash -c 'grep -Fq "\"vendor\":\"0x10ec\",\"device\":\"0xb852\",\"class\":\"0x028000\"" <<<"$1"' _ "${out}"
  check "USB inventory carries the negotiated speed" \
    bash -c 'grep -Fq "\"id_vendor\":\"19f7\",\"id_product\":\"0080\",\"speed_mbps\":\"480\"" <<<"$1"' _ "${out}"
  check "ID_PATH is captured per interface" \
    bash -c 'grep -Fq "platform-selftest.pcie-pci-0000:00:01.0" <<<"$1"' _ "${out}"
  check "wifi/bt modules are DISCOVERED, not hardcoded" \
    bash -c 'grep -Fq "rtw89_pci" <<<"$1" && grep -Fq "btusb" <<<"$1"' _ "${out}"
  check "boot-state counters are parsed" \
    bash -c 'grep -Fq "\"boot_order\":\"A B\",\"a_left\":3,\"b_left\":2" <<<"$1"' _ "${out}"
  check "lo is excluded from the interface inventory" \
    bash -c '! grep -Fq "\"name\":\"lo\"" <<<"$1"' _ "${out}"

  # Non-vacuity: a payload that stopped reporting the absent tool honestly must
  # fail the honesty leg above.
  local mutated
  mutated="${payload//not present on the production package set (util-linux is installed, sfdisk is not); partition geometry below is read from sysfs in the same 512-byte sector units/}"
  local mutated_out
  mutated_out="$(PF_ROOT="${root}" PF_BIN_DIR="${bin}" PF_ABSENT_TOOLS="sfdisk lspci lsusb" \
    bash <<<"${mutated}" 2>/dev/null)"
  check "non-vacuity: an empty sfdisk reason FAILS the honesty check" \
    bash -c '! grep -Eq "\"sfdisk\":\{\"available\":false,\"reason\":\"[^\"]+\"" <<<"$1"' _ "${mutated_out}"

  # Envelope legs — reachable and the unreachable record.
  write_envelope "${tmp}/reach.json" selftest-board 203.0.113.9 1 '' "${out}"
  check "reachable envelope marks reachable:true" \
    bash -c 'grep -Fq "\"reachable\": true" "$1"' _ "${tmp}/reach.json"
  check "reachable envelope embeds the inventory" \
    bash -c 'grep -Fq "\"tooling\"" "$1"' _ "${tmp}/reach.json"
  local round_tripped
  round_tripped="$(extract_keyring_pem "${tmp}/reach.json")"
  check "keyring PEM round-trips out of the envelope" \
    bash -c '[[ "$1" == -----BEGIN* ]]' _ "${round_tripped}"
  check "the round-tripped PEM is a parseable certificate" \
    bash -c 'openssl x509 -noout -subject <<<"$1" >/dev/null 2>&1' _ "${round_tripped}"

  # The CR is not decoration: ssh's own diagnostics carry one, and an unescaped
  # 0x0D inside a JSON string makes the whole evidence file unparseable.
  write_envelope "${tmp}/unreach.json" orange-pi-5-plus 203.0.113.10 0 \
    $'ssh: connect to host 203.0.113.10 port 22: No route to host\r' 'null'
  check "a CR in the ssh diagnostic is escaped, not embedded raw" \
    bash -c '! grep -q "$(printf "\r")" "$1" && grep -Fq "No route to host\\r" "$1"' _ "${tmp}/unreach.json"
  check "unreachable envelope marks reachable:false" \
    bash -c 'grep -Fq "\"reachable\": false" "$1"' _ "${tmp}/unreach.json"
  check "unreachable envelope records the verbatim error" \
    bash -c 'grep -Fq "No route to host" "$1"' _ "${tmp}/unreach.json"
  check "unreachable envelope fabricates no inventory" \
    bash -c 'grep -Fq "\"inventory\": null" "$1"' _ "${tmp}/unreach.json"

  # A real unreachable capture against TEST-NET-1 must exit 3, not 0 and not 1.
  local rc
  capture 192.0.2.1 selftest-unreachable "${tmp}/unreach-dir" '' '' 1 5 >/dev/null 2>&1
  rc=$?
  check "an unreachable board exits 3 and still writes a record" \
    bash -c '[[ "$1" == 3 && -s "$2" ]]' _ "${rc}" "${tmp}/unreach-dir/selftest-unreachable-preflight.json"

  if (( failures == 0 )); then
    printf 'capture-board-preflight self-test: PASS\n'
    return 0
  fi
  printf 'capture-board-preflight self-test: FAIL (%s leg(s))\n' "${failures}" >&2
  return 1
}

main() {
  local host="" board="" outdir="" ssh_user="" identity=""
  local connect_timeout=8 command_timeout=120 mode="capture"

  while (( $# )); do
    case "$1" in
      --host)            host="${2-}"; shift 2 ;;
      --board)           board="${2-}"; shift 2 ;;
      --out)             outdir="${2-}"; shift 2 ;;
      --ssh-user)        ssh_user="${2-}"; shift 2 ;;
      --ssh-identity)    identity="${2-}"; shift 2 ;;
      --connect-timeout) connect_timeout="${2-}"; shift 2 ;;
      --command-timeout) command_timeout="${2-}"; shift 2 ;;
      --self-test)       mode="self-test"; shift ;;
      -h|--help)         usage; return 0 ;;
      *) fail "unknown option: $1"; usage >&2; return 2 ;;
    esac
  done

  if [[ "${mode}" == self-test ]]; then
    self_test
    return $?
  fi

  [[ -n "${host}" && -n "${board}" && -n "${outdir}" ]] || {
    fail "--host, --board and --out are all required"
    usage >&2
    return 2
  }
  [[ "${board}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || {
    fail "board name is not a manifest stem: '${board}'"; return 2; }

  capture "${host}" "${board}" "${outdir}" "${ssh_user}" "${identity}" \
    "${connect_timeout}" "${command_timeout}"
}

main "$@"
