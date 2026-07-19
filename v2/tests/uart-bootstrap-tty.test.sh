#!/usr/bin/env bash
#
# uart-bootstrap-tty.test.sh — offline guard for the RK3588 CI-UART bootstrap's
# tty setup.
#
# Real Rock 5B+ regression (2026-07-19, empirically reproduced): the bootstrap
# ran `stty 1500000 sane -echo <&0` on /dev/ttyFIQ0 — the Rockchip FIQ-debugger's
# FIXED-RATE software console over the debug UART. That tty rejects the TCSETS
# baud ioctl, so `stty` exited non-zero and `set -euo pipefail` aborted the whole
# bootstrap before it could print CERALIVE_UART_BOOTSTRAP_READY. No handshake, no
# run-local SSH key, provisioning failed.
#
# The fix makes stty BEST-EFFORT on a FIQ tty (the channel already works by
# default and its baud is not settable) while keeping it FATAL on a real UART —
# deliberately NOT a blanket `|| true`, so a genuine mis-provision on a
# settable-baud board is surfaced rather than masked. This test exercises the
# SHIPPED configure_bootstrap_tty() against both tty classes with stubbed
# tty/stty binaries.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2="$(cd "${HERE}/.." && pwd)"
SCRIPT="${V2}/mkosi/runtime/ceralive-ci-uart-bootstrap.sh"

fail() { printf 'uart-bootstrap-tty: FAIL: %s\n' "$*" >&2; exit 1; }
[[ -f "${SCRIPT}" ]] || fail "missing ${SCRIPT}"

# --- static contract -------------------------------------------------------
grep -Eq '^configure_bootstrap_tty\(\) \{' "${SCRIPT}" \
  || fail "configure_bootstrap_tty() not found — tty setup no longer factored"
grep -Eq '^if \[\[ -t 0 \]\]; then$' "${SCRIPT}" \
  || fail "the [[ -t 0 ]] guard around tty setup is gone"
grep -Eq 'ttyFIQ\*\)' "${SCRIPT}" \
  || fail "no ttyFIQ* case — the FIQ tty is not handled specially"
grep -Eq '^[[:space:]]*stty 1500000 sane -echo <&0 \|\| fail' "${SCRIPT}" \
  || fail "real-UART path must keep a FATAL stty (not || true) — regressions must surface"

# --- runtime proof against stubbed tty classes -----------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
BIN="${TMP}/bin"
mkdir -p "${BIN}"

# Extract the SHIPPED fail() + configure_bootstrap_tty() so we test real code.
extract_func() {
  awk -v f="$1" 'index($0, f"() {") == 1 { p = 1 } p { print } p && /^}$/ { exit }' "${SCRIPT}"
}
{ extract_func fail; extract_func configure_bootstrap_tty; } >"${TMP}/funcs.sh"

cat >"${BIN}/tty" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${STUB_TTY:-/dev/tty}"
SH
# Distinguish a baud request (1500000) from a plain -echo request so the FIQ
# case (baud impossible, -echo maybe) and the real-UART case are both modelled.
cat >"${BIN}/stty" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do
  [[ "$a" = 1500000 ]] && exit "${STUB_STTY_BAUD_RC:-0}"
done
exit "${STUB_STTY_ECHO_RC:-0}"
SH
chmod +x "${BIN}"/*

run_case() { # $1=ttydev $2=baud_rc $3=echo_rc -> prints function stdout + RC=<code>
  ( set +e
    PATH="${BIN}:${PATH}" STUB_TTY="$1" STUB_STTY_BAUD_RC="$2" STUB_STTY_ECHO_RC="$3" \
      bash -c 'set -euo pipefail; source "'"${TMP}"'/funcs.sh"; configure_bootstrap_tty </dev/null'
    printf 'RC=%s\n' "$?" )
}

# 1. FIQ tty, -echo honored → success, no fatal marker.
out="$(run_case /dev/ttyFIQ0 1 0)"
[[ "$out" == *RC=0* ]] || fail "FIQ tty with working -echo should succeed: ${out}"
[[ "$out" != *CERALIVE_UART_BOOTSTRAP_ERROR* ]] || fail "FIQ tty must not emit a fatal error: ${out}"

# 2. FIQ tty, EVEN -echo rejected → still success (best-effort), logs INFO skip.
#    This is the exact regression: never abort the bootstrap on the FIQ tty.
out="$(run_case /dev/ttyFIQ0 1 1)"
[[ "$out" == *RC=0* ]] || fail "FIQ tty must never abort even if stty fully fails: ${out}"
[[ "$out" == *CERALIVE_UART_BOOTSTRAP_INFO*fiq-tty-stty-skipped* ]] || fail "FIQ skip not logged: ${out}"
[[ "$out" != *CERALIVE_UART_BOOTSTRAP_ERROR* ]] || fail "FIQ tty must not emit a fatal error: ${out}"

# 3. Real UART (ttyS0), stty honored → success.
out="$(run_case /dev/ttyS0 0 0)"
[[ "$out" == *RC=0* ]] || fail "real UART with working stty should succeed: ${out}"

# 4. Real UART (ttyS0), baud-set FAILS → FATAL. A real-UART regression must NOT
#    be masked (this is why the fix is not a blanket `|| true`).
out="$(run_case /dev/ttyS0 1 0)"
[[ "$out" == *RC=1* ]] || fail "real UART baud failure must be fatal: ${out}"
[[ "$out" == *CERALIVE_UART_BOOTSTRAP_ERROR*tty-setup* ]] \
  || fail "real UART failure must emit the error marker: ${out}"

printf 'uart-bootstrap-tty: PASS (FIQ tty tolerant; real UART strict)\n'
