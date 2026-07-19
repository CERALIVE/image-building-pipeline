#!/usr/bin/env bash
#
# uart-console-path.test.sh — offline guard for the RK3588 CI-UART console path.
#
# Real Rock 5B+ hardware regression: the one-shot CI UART bootstrap targeted the
# wrong console. RK3588's live Linux-phase console is /dev/ttyFIQ0 (the Rockchip
# vendor kernel's FIQ debugger claims physical UART2 once Linux boots and systemd
# spawns serial-getty@ttyFIQ0.service — there is NO /dev/ttyS2 device node at
# runtime). U-Boot/early-kernel still drive raw ttyS2 @ 1500000 (the family
# serial_console → console= arg), which is correct and unchanged; only the LIVE
# console owned by systemd differs. When the bootstrap unit used TTYPath=/dev/ttyS2
# its systemd TTY setup failed instantly (no device node) and the transient
# getty mask targeted serial-getty@ttyS2.service — a no-op that left the real
# ttyFIQ0 getty contending for the port. Both must reference ttyFIQ0.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2="$(cd "${HERE}/.." && pwd)"
UNIT="${V2}/mkosi/runtime/ceralive-ci-uart-bootstrap.service"
UART_PROVISION="${V2}/ci/uart-provision-ssh.sh"

fail() { printf 'uart-console-path: FAIL: %s\n' "$*" >&2; exit 1; }

for f in "${UNIT}" "${UART_PROVISION}"; do
  [[ -f "${f}" ]] || fail "missing source file: ${f}"
done

# The bootstrap unit owns the LIVE console — it must be ttyFIQ0, never ttyS2.
grep -Eq '^TTYPath=/dev/ttyFIQ0$' "${UNIT}" \
  || fail "ceralive-ci-uart-bootstrap.service must set TTYPath=/dev/ttyFIQ0 (RK3588 live console)"
grep -Eq '^TTYPath=/dev/ttyS2$' "${UNIT}" \
  && fail "ceralive-ci-uart-bootstrap.service still targets /dev/ttyS2 — no such runtime device node on RK3588"

# The transient getty mask must silence the getty systemd actually spawns
# (serial-getty@ttyFIQ0.service), so it cannot fight the bootstrap for the port.
grep -Fq 'systemd.mask=serial-getty@ttyFIQ0.service' "${UART_PROVISION}" \
  || fail "uart-provision-ssh.sh must mask serial-getty@ttyFIQ0.service (the live RK3588 getty)"
grep -Fq 'systemd.mask=serial-getty@ttyS2.service' "${UART_PROVISION}" \
  && fail "uart-provision-ssh.sh still masks serial-getty@ttyS2.service — a no-op; the real getty runs on ttyFIQ0"

# The two console references must agree: whatever the mask silences is exactly the
# TTY the bootstrap claims (both ttyFIQ0). This catches a future half-migration.
unit_tty="$(grep -Eom1 '^TTYPath=/dev/(ttyFIQ0|ttyS2)$' "${UNIT}" | sed 's#^TTYPath=/dev/##')"
mask_tty="$(grep -Eom1 'systemd\.mask=serial-getty@(ttyFIQ0|ttyS2)\.service' "${UART_PROVISION}" \
  | sed -E 's#.*serial-getty@([^.]+)\.service#\1#')"
[[ -n "${unit_tty}" && -n "${mask_tty}" ]] \
  || fail "could not extract console names from unit (${unit_tty:-none}) / provision script (${mask_tty:-none})"
[[ "${unit_tty}" = "${mask_tty}" ]] \
  || fail "console mismatch: bootstrap TTYPath=${unit_tty} but getty mask targets ${mask_tty}"

# The U-Boot/early console (serial_console) is a DIFFERENT concern and stays ttyS2:
# it is the raw UART2 the bootloader/early kernel use before the FIQ debugger takes
# over. Assert the family manifest keeps that early console unchanged so this fix is
# not misread as "rename everything to ttyFIQ0".
RK3588_FAMILY="${V2}/manifests/families/rk3588.yaml"
[[ -f "${RK3588_FAMILY}" ]] || fail "missing ${RK3588_FAMILY}"
grep -Eq '^serial_console:[[:space:]]*ttyS2:1500000$' "${RK3588_FAMILY}" \
  || fail "rk3588.yaml serial_console must stay ttyS2:1500000 (raw UART2 early/bootloader console — NOT the live ttyFIQ0 console)"

printf 'uart-console-path: PASS (bootstrap + getty mask target ttyFIQ0; early console stays ttyS2)\n'
