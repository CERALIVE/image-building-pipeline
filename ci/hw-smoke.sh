#!/usr/bin/env bash
#
# hw-smoke.sh — the BOARD-SIDE subsystem drill `run-rk3588-hardware-drill.sh`'s
# `candidate` profile invokes as `sudo /tmp/ceralive-qa/hw-smoke.sh --case <case>`.
#
# One case per mandatory subsystem. Each case prints exactly one terminal line:
#
#   RESULT=PASS case=<case> ...     every mandatory check of the case held
#   RESULT=NA   case=<case> reason=<reason>
#                                   an ENTRY PREREQUISITE is genuinely absent on
#                                   this unit (no radio, no attached SuperSpeed
#                                   device, no safe read source). NA is NOT a
#                                   pass and never claims one — it names the
#                                   observation that made the check unrunnable.
#   RESULT=FAIL case=<case> ...     a mandatory check ran and did not hold
#
# Exit status is 0 for PASS and NA and 1 for FAIL, so a genuinely unmet entry
# prerequisite does not abort the drill sequence while a real defect does. The
# distinction lives in the RESULT line and in the receipt marker derived from
# it — never in the exit code alone.
#
# Self-contained by construction: it runs inside a shipped device image where
# this repository's `lib/` is not present, so it sources nothing. Device-daemon
# strict-mode profile (`set -uo pipefail`, no `-e`): a probe that legitimately
# fails must be reported, not turned into a dead drill.
#
# Usage:
#   hw-smoke.sh --case encode|wifi|bluetooth|mmc|usb3 [--out <dir>]
#
# shellcheck shell=bash

set -uo pipefail

OUT_DIR="${CERALIVE_QA_OUT:-/tmp/ceralive-qa/out}"
CASE=""

log()  { printf '%s\n' "$*"; }
ok()   { printf 'ok   %s\n' "$*"; }
bad()  { printf 'FAIL %s\n' "$*"; FAILURES=$((FAILURES + 1)); }
FAILURES=0

usage() { sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --case) CASE="${2:-}"; shift 2 ;;
    --out)  OUT_DIR="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ -n "${CASE}" ]] || { printf -- '--case is required\n' >&2; usage >&2; exit 2; }
mkdir -p "${OUT_DIR}" || { printf 'cannot create %s\n' "${OUT_DIR}" >&2; exit 2; }

finish() {
  local verdict="$1"; shift
  printf 'RESULT=%s case=%s %s\n' "${verdict}" "${CASE}" "$*"
  case "${verdict}" in
    FAIL) exit 1 ;;
    *)    exit 0 ;;
  esac
}

na()   { finish NA "reason=$1"; }
done_() {
  if (( FAILURES == 0 )); then finish PASS "$*"; else finish FAIL "failures=${FAILURES} $*"; fi
}

# ---------------------------------------------------------------------------
# encode — the MPP hardware H.264 path, end to end.
# ---------------------------------------------------------------------------
encode_once() {
  # encode_once <label> <width> <height> <buffers> <timeout>
  local label="$1" w="$2" h="$3" buffers="$4" budget="$5"
  local target="${OUT_DIR}/${label}.h264" rc size
  rm -f "${target}"
  timeout "${budget}" gst-launch-1.0 -q \
    videotestsrc num-buffers="${buffers}" \
    ! "video/x-raw,format=NV12,width=${w},height=${h},framerate=30/1" \
    ! mpph264enc ! h264parse ! filesink location="${target}" \
    >"${OUT_DIR}/${label}.gst.log" 2>&1
  rc=$?
  size=$(stat -c %s "${target}" 2>/dev/null || printf 0)
  printf '%s rc=%s bytes=%s\n' "${label}" "${rc}" "${size}"
  (( rc == 0 )) || { bad "${label}: gst-launch exited ${rc}"; return 1; }
  (( size > 0 ))  || { bad "${label}: encoder produced a zero-byte stream"; return 1; }
  ok "${label}: rc=0 bytes=${size}"
  return 0
}

ffprobe_check() {
  # ffprobe_check <label> <expected-width> <expected-height>
  local label="$1" w="$2" h="$3" target="${OUT_DIR}/$1.h264" probe
  probe=$(ffprobe -v error -select_streams v:0 \
            -show_entries stream=codec_name,width,height,nb_read_frames \
            -count_frames -of default=nw=1 "${target}" 2>&1)
  printf '%s ffprobe:\n%s\n' "${label}" "${probe}"
  grep -qx "codec_name=h264" <<<"${probe}" || { bad "${label}: ffprobe did not report codec_name=h264"; return 1; }
  grep -qx "width=${w}"      <<<"${probe}" || { bad "${label}: ffprobe width != ${w}"; return 1; }
  grep -qx "height=${h}"     <<<"${probe}" || { bad "${label}: ffprobe height != ${h}"; return 1; }
  ok "${label}: ffprobe decodes h264 ${w}x${h}"
  return 0
}

case_encode() {
  log "== element registration =="
  if gst-inspect-1.0 mpph264enc >"${OUT_DIR}/gst-inspect-mpph264enc.txt" 2>&1; then
    ok "gst-inspect-1.0 mpph264enc exits 0"
  else
    bad "gst-inspect-1.0 mpph264enc: element not registered"
  fi

  log "== dma-heap device / sysfs identity =="
  if [[ -d /dev/dma_heap ]]; then
    ls -l /dev/dma_heap
    local heap
    for heap in /dev/dma_heap/*; do
      [[ -e "${heap}" ]] || continue
      printf 'heap %s %s\n' "$(basename "${heap}")" "$(stat -c '%t:%T %F' "${heap}")"
    done
    if [[ -c /dev/dma_heap/system-uncached ]]; then
      ok "dma-heap system-uncached present ($(stat -c '%t:%T' /dev/dma_heap/system-uncached))"
    else
      bad "dma-heap system-uncached ABSENT — MPP allocates every encode buffer from it"
    fi
    if [[ -c /dev/dma_heap/system ]]; then
      ok "dma-heap system present ($(stat -c '%t:%T' /dev/dma_heap/system))"
    else
      bad "dma-heap system ABSENT"
    fi
  else
    bad "/dev/dma_heap does not exist (CONFIG_DMABUF_HEAPS off?)"
  fi
  log "-- sysfs dma_heap class --"
  ls -l /sys/class/dma_heap 2>&1 || true
  log "-- mpp service node --"
  ls -l /dev/mpp_service 2>&1 || true

  log "== 60-buffer 1080p NV12 encode =="
  if encode_once enc-1080p60 1920 1080 60 120; then ffprobe_check enc-1080p60 1920 1080; fi

  log "== 60-buffer 4K NV12 encode =="
  if encode_once enc-2160p60 3840 2160 60 240; then ffprobe_check enc-2160p60 3840 2160; fi

  log "== dual concurrent 600-buffer pipelines =="
  local pid_a pid_b rc_a rc_b size_a size_b
  rm -f "${OUT_DIR}/enc-dual-a.h264" "${OUT_DIR}/enc-dual-b.h264"
  timeout 300 gst-launch-1.0 -q videotestsrc num-buffers=600 \
    ! "video/x-raw,format=NV12,width=1920,height=1080,framerate=30/1" \
    ! mpph264enc ! h264parse ! filesink location="${OUT_DIR}/enc-dual-a.h264" \
    >"${OUT_DIR}/enc-dual-a.gst.log" 2>&1 & pid_a=$!
  timeout 300 gst-launch-1.0 -q videotestsrc num-buffers=600 \
    ! "video/x-raw,format=NV12,width=1920,height=1080,framerate=30/1" \
    ! mpph264enc ! h264parse ! filesink location="${OUT_DIR}/enc-dual-b.h264" \
    >"${OUT_DIR}/enc-dual-b.gst.log" 2>&1 & pid_b=$!
  wait "${pid_a}"; rc_a=$?
  wait "${pid_b}"; rc_b=$?
  size_a=$(stat -c %s "${OUT_DIR}/enc-dual-a.h264" 2>/dev/null || printf 0)
  size_b=$(stat -c %s "${OUT_DIR}/enc-dual-b.h264" 2>/dev/null || printf 0)
  printf 'dual a rc=%s bytes=%s | b rc=%s bytes=%s\n' "${rc_a}" "${size_a}" "${rc_b}" "${size_b}"
  if (( rc_a == 0 && rc_b == 0 && size_a > 0 && size_b > 0 )); then
    ok "dual 600-buffer pipelines both completed with non-empty output"
  else
    bad "dual 600-buffer pipelines: a(rc=${rc_a},bytes=${size_a}) b(rc=${rc_b},bytes=${size_b})"
  fi

  log "== 20x open/encode/SIGTERM loop =="
  local i loop_fail=0 lrc
  for i in $(seq 1 20); do
    timeout 60 gst-launch-1.0 -q videotestsrc is-live=true \
      ! "video/x-raw,format=NV12,width=1280,height=720,framerate=30/1" \
      ! mpph264enc ! h264parse ! filesink location="${OUT_DIR}/enc-loop.h264" \
      >"${OUT_DIR}/enc-loop.gst.log" 2>&1 &
    lrc=$!
    sleep 2
    kill -TERM "${lrc}" 2>/dev/null
    wait "${lrc}" 2>/dev/null
    # A SIGTERM'd `timeout` wrapper exits 143 (128+15) or 124 on its own budget.
    # Anything else means the pipeline died on its own before the signal.
    local status=$?
    case "${status}" in
      143|0) : ;;
      *) printf 'loop iteration %s exited %s\n' "${i}" "${status}"; loop_fail=$((loop_fail + 1)) ;;
    esac
  done
  if (( loop_fail == 0 )); then
    ok "20 open/encode/SIGTERM iterations completed without an unexpected exit"
  else
    bad "${loop_fail}/20 open/encode/SIGTERM iterations exited unexpectedly"
  fi

  log "== element still registered after the loop =="
  if gst-inspect-1.0 mpph264enc >/dev/null 2>&1; then
    ok "mpph264enc still registered after 20 teardown cycles"
  else
    bad "mpph264enc LOST registration after the teardown loop"
  fi

  done_ "heap=$( [[ -c /dev/dma_heap/system-uncached ]] && printf present || printf absent )"
}

# ---------------------------------------------------------------------------
# wifi
# ---------------------------------------------------------------------------
case_wifi() {
  log "== wireless phy inventory =="
  ls -l /sys/class/ieee80211 2>&1
  local phys=0
  if [[ -d /sys/class/ieee80211 ]]; then
    phys=$(find /sys/class/ieee80211 -mindepth 1 -maxdepth 1 | wc -l)
  fi
  log "wireless_phy_count=${phys}"
  log "-- nmcli device status --"
  nmcli -t device status 2>&1
  if (( phys == 0 )); then
    na "no-wireless-phy: /sys/class/ieee80211 exposes zero PHYs on this unit (M.2 E-key slot unpopulated); nmcli lists no wifi device"
  fi
  log "-- nmcli device wifi rescan --"
  nmcli device wifi rescan 2>&1 || bad "nmcli device wifi rescan failed"
  sleep 5
  log "-- nmcli device wifi list --"
  nmcli device wifi list 2>&1 || bad "nmcli device wifi list failed"
  done_ "phys=${phys}"
}

# ---------------------------------------------------------------------------
# bluetooth
# ---------------------------------------------------------------------------
case_bluetooth() {
  log "== bluetooth controller inventory =="
  ls -l /sys/class/bluetooth 2>&1
  local hci=0
  if [[ -d /sys/class/bluetooth ]]; then
    hci=$(find /sys/class/bluetooth -mindepth 1 -maxdepth 1 | wc -l)
  fi
  log "hci_controller_count=${hci}"
  log "-- rfkill --"
  rfkill list 2>&1 || true
  if (( hci == 0 )); then
    na "no-bluetooth-controller: /sys/class/bluetooth exposes zero HCI devices on this unit (no onboard BT radio and no USB BT adapter attached)"
  fi
  log "-- bluetoothctl list --"
  timeout 20 bluetoothctl list </dev/null 2>&1 || bad "bluetoothctl list failed"
  log "-- bluetoothctl show --"
  timeout 20 bluetoothctl show </dev/null 2>&1 || bad "bluetoothctl show failed"
  done_ "controllers=${hci}"
}

# ---------------------------------------------------------------------------
# mmc — journal signatures plus ONE bounded, read-only, non-mounted read.
# ---------------------------------------------------------------------------
case_mmc() {
  log "== block inventory =="
  lsblk -o NAME,PATH,SIZE,TYPE,PARTLABEL,FSTYPE,MOUNTPOINT
  log "== eMMC presence =="
  local emmc="" dev
  for dev in /sys/block/mmcblk*; do
    [[ -e "${dev}" ]] || continue
    local t; t=$(cat "${dev}/device/type" 2>/dev/null)
    printf '%s type=%s\n' "$(basename "${dev}")" "${t:-unknown}"
    [[ "${t}" == "MMC" ]] && emmc="$(basename "${dev}")"
  done

  # An mmc HOST with zero enumerated cards is an EMPTY SOCKET. A host the device
  # tree declares `non-removable` (the eMMC controller) logs exactly
  # "mmcN: Failed to initialize a non-removable card" on every boot when nothing
  # is fitted. That line is the socket being empty, not a card failing — so it is
  # exempted for THAT host index only. The same line from a host that DID
  # enumerate a card is a genuine failure and still rejects.
  local host empty_hosts=() card_hosts=()
  for host in /sys/class/mmc_host/*; do
    [[ -e "${host}" ]] || continue
    local hname; hname=$(basename "${host}")
    if compgen -G "${host}/${hname}:*" >/dev/null; then
      card_hosts+=("${hname}")
      printf 'host %s: card enumerated (%s)\n' "${hname}" \
        "$(basename "$(compgen -G "${host}/${hname}:*" | head -1)")"
    else
      empty_hosts+=("${hname}")
      printf 'host %s: EMPTY socket (zero enumerated cards)\n' "${hname}"
    fi
  done

  if [[ -n "${emmc}" ]]; then
    ok "eMMC present: ${emmc}"
  else
    log "NA-note: eMMC leg is N/A on this unit — no eMMC block device exists;" \
        "every mmcblk* is an SD card and the eMMC host socket is empty"
  fi

  log "== journalctl -k -b 0 mmc signatures =="
  journalctl -k --no-pager -b 0 2>/dev/null \
    | grep -Ei 'mmc[0-9]|mmcblk|sdhci|dwcmshc|dw_mmc' \
    | tee "${OUT_DIR}/mmc-journal.txt"
  local sig_lines; sig_lines=$(wc -l <"${OUT_DIR}/mmc-journal.txt")
  log "mmc_journal_lines=${sig_lines}"
  if (( sig_lines > 0 )); then
    ok "kernel log carries mmc host/card signatures (${sig_lines} lines)"
  else
    bad "kernel log carries NO mmc signatures at all"
  fi
  local screened="${OUT_DIR}/mmc-journal-screened.txt"
  cp "${OUT_DIR}/mmc-journal.txt" "${screened}"
  local eh
  for eh in "${empty_hosts[@]:-}"; do
    [[ -n "${eh}" ]] || continue
    grep -v "${eh}: Failed to initialize a non-removable card" "${screened}" >"${screened}.tmp" \
      && mv "${screened}.tmp" "${screened}"
    log "exempt: '${eh}: Failed to initialize a non-removable card' — ${eh} is an empty socket"
  done
  if grep -qEi 'switch to (hs[0-9]+) failed|Failed to initialize a non-removable card|I/O error.*mmcblk|mmc[0-9]: error|mmc[0-9]: tuning execution failed' \
       "${screened}"; then
    bad "kernel log carries an mmc negotiation/IO error signature"
    grep -Ei 'switch to (hs[0-9]+) failed|Failed to initialize a non-removable card|I/O error.*mmcblk|mmc[0-9]: error|mmc[0-9]: tuning execution failed' "${screened}"
  else
    ok "no mmc negotiation or IO error signature from any host that enumerated a card"
  fi

  log "== bounded read-only source selection =="
  # Only a partition that `findmnt` proves is mounted NOWHERE may be read, and
  # only through a read-only, count-bounded, O_DIRECT read into /dev/null. This
  # never writes and never touches a mounted slot.
  local candidate="" part
  for part in /dev/disk/by-partlabel/*; do
    [[ -e "${part}" ]] || continue
    local real; real=$(readlink -f "${part}")
    if findmnt -n -S "${real}" >/dev/null 2>&1; then
      printf 'skip %s (%s): MOUNTED at %s\n' "${part}" "${real}" \
        "$(findmnt -n -o TARGET -S "${real}" | tr '\n' ' ')"
      continue
    fi
    printf 'candidate %s (%s): not mounted\n' "${part}" "${real}"
    [[ -n "${candidate}" ]] || candidate="${real}"
  done
  if [[ -z "${candidate}" ]]; then
    na "no-unmounted-read-source: every partition on this unit is mounted; a bounded read against a mounted partition is out of scope"
  fi
  log "read source: ${candidate}"
  if findmnt -n -S "${candidate}" >/dev/null 2>&1; then
    bad "refusing to read ${candidate}: it became mounted between selection and read"
    done_ "read=refused"
  fi
  local ddlog rc
  ddlog="${OUT_DIR}/mmc-dd.txt"
  dd if="${candidate}" of=/dev/null bs=4M count=64 iflag=direct >"${ddlog}" 2>&1
  rc=$?
  cat "${ddlog}"
  if (( rc == 0 )); then
    ok "bounded read-only 256 MiB O_DIRECT read of ${candidate} completed"
  else
    bad "bounded read-only read of ${candidate} exited ${rc}"
  fi
  done_ "emmc=${emmc:-none-fitted} emmc_leg=$( [[ -n "${emmc}" ]] && printf tested || printf NA ) card_hosts='${card_hosts[*]:-}' empty_hosts='${empty_hosts[*]:-}' read_source=${candidate}"
}

# ---------------------------------------------------------------------------
# usb3 — requires a NAMED attached SuperSpeed device; nothing attached is an
# unmet entry prerequisite, never an invented pass.
# ---------------------------------------------------------------------------
case_usb3() {
  log "== usb topology and negotiated speeds =="
  local dev found=0 named=""
  for dev in /sys/bus/usb/devices/*; do
    [[ -f "${dev}/speed" ]] || continue
    local base speed vid pid product
    base=$(basename "${dev}")
    speed=$(cat "${dev}/speed" 2>/dev/null)
    vid=$(cat "${dev}/idVendor" 2>/dev/null)
    pid=$(cat "${dev}/idProduct" 2>/dev/null)
    product=$(cat "${dev}/product" 2>/dev/null)
    printf '%s speed=%s %s:%s %s\n' "${base}" "${speed}" "${vid:-----}" "${pid:-----}" "${product:-}"
    # A root hub (usbN) reports the CONTROLLER's capability, not an attached
    # device, so it can never satisfy this check.
    [[ "${base}" =~ ^usb[0-9]+$ ]] && continue
    case "${speed}" in
      5000|10000|20000)
        found=$((found + 1))
        [[ -n "${named}" ]] || named="${base} ${vid}:${pid} ${product:-unnamed} speed=${speed}"
        ;;
    esac
  done
  if (( found == 0 )); then
    na "no-superspeed-device-attached: no non-root-hub USB node reports speed 5000/10000/20000; the USB3 drill's entry prerequisite is unmet"
  fi
  ok "attached SuperSpeed device: ${named}"
  done_ "superspeed_devices=${found} device='${named}'"
}

case "${CASE}" in
  encode)    case_encode ;;
  wifi)      case_wifi ;;
  bluetooth) case_bluetooth ;;
  mmc)       case_mmc ;;
  usb3)      case_usb3 ;;
  *) printf 'unknown case: %s\n' "${CASE}" >&2; usage >&2; exit 2 ;;
esac
