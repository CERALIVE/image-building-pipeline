#!/usr/bin/env bash
#
# ssh-enablement-contract.test.sh — offline guard for the production
# disabled-by-default SSH contract (Todo-42/PR#60) and the two defects that made
# it silently untrue on a real build.
#
# DEFECT 1 — a SIGPIPE race turned the disable into a no-op. `disable_service`
# probed for the unit with
#
#     systemctl list-unit-files "$svc" >/dev/null 2>&1 \
#       && systemctl list-unit-files "$svc" | grep -q "$svc"
#
# `grep -q` exits at its FIRST match and closes the pipe; systemctl is still
# writing its "N unit files listed" trailer, takes SIGPIPE, and under the modules'
# `set -o pipefail` the pipeline reports 141. The guard then reads "not present",
# `systemctl disable ssh.service` never runs, openssh-server's own postinst
# `enable` survives into the image, and the `[7/9]` parity gate fails a PRODUCTION
# build on "ssh.service is enabled but MUST be disabled-by-default". It is a race,
# so it fired on one board's build and not another's from the identical commit,
# and a single offline replay never reproduces it — measured 23/300 against a real
# built arm64 rootfs.
#
# DEFECT 2 — even a landed disable does not survive first boot. /etc/machine-id
# ships holding "uninitialized", so every freshly flashed board is a systemd FIRST
# BOOT and PID 1 runs `preset-all`. Debian's default verdict is `enable`, and mkosi
# ships /usr/lib/systemd/system-preset/80-mkosi-ssh.preset holding
# `enable ssh.socket`, so the operator's very first power-on re-enables what the
# build disabled. A CeraLive preset sorting AHEAD of mkosi's restates the
# build-time intent as the first matching preset line.
#
# Part A — static contract on the real function bodies.
# Part B — runtime: drive the REAL shipped functions against a stub systemctl
#          whose trailer makes the old form's SIGPIPE deterministic, plus a
#          non-vacuity leg proving the old form DOES fail that same harness.
#
# shellcheck disable=SC2016

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"
POSTINST_LIB="${PIPELINE_DIR}/mkosi/customize/postinst-lib.sh"
POSTINST_D="${PIPELINE_DIR}/mkosi/customize/postinst.d"

# shellcheck source=tests/lib/assertions.sh
source "${HERE}/lib/assertions.sh"

[[ -f "${POSTINST_LIB}" && -d "${POSTINST_D}" ]] || {
  printf 'ssh-enablement-contract: missing postinst library\n' >&2; exit 1; }

# The entry only SOURCES the per-concern modules, so a static read pointed at it
# alone finds no function bodies and passes every check below vacuously.
POSTINST_SRC="$(cat "${POSTINST_LIB}" "${POSTINST_D}"/*.sh)"

extract_fn() {
  awk -v fn="$1" '
    $0 ~ "^" fn "\\(\\) \\{" { f=1 }
    f { print }
    f && /^\}/ { exit }
  ' <<<"${POSTINST_SRC}"
}

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# ---------------------------------------------------------------------------
# Part A — static contract
# ---------------------------------------------------------------------------
echo "Part A — static contract"

disable_body="$(extract_fn disable_service)"
[[ -n "${disable_body}" ]] && ok "disable_service() is defined in the postinst module set" \
  || bad "disable_service() not found in the postinst module set"

if grep -Eq 'systemctl[^|]*list-unit-files[^|]*\|[[:space:]]*grep' <<<"${disable_body}"; then
  bad "disable_service() pipes systemctl list-unit-files into grep — the SIGPIPE race that no-op'd the production ssh disable"
else
  ok "disable_service() does not pipe systemctl list-unit-files into grep"
fi

present_body="$(extract_fn unit_file_present)"
[[ -n "${present_body}" ]] && ok "unit_file_present() is defined" \
  || bad "unit_file_present() not found — disable_service lost its non-piped probe"

grep -Eq '\$\(systemctl[[:space:]]+list-unit-files' <<<"${present_body}" \
  && ok "unit_file_present() captures systemctl output in a command substitution (no early reader, so no SIGPIPE)" \
  || bad "unit_file_present() no longer captures systemctl output in a command substitution"

grep -Fq 'unit_file_present' <<<"${disable_body}" \
  && ok "disable_service() probes through unit_file_present()" \
  || bad "disable_service() no longer probes through unit_file_present()"

ssh_body="$(extract_fn configure_ssh_enablement)"
[[ -n "${ssh_body}" ]] && ok "configure_ssh_enablement() is defined" \
  || bad "configure_ssh_enablement() not found"

grep -Fq 'disable_service ssh.service' <<<"${ssh_body}" \
  && grep -Fq 'disable_service ssh.socket' <<<"${ssh_body}" \
  && ok "production branch actively disables ssh.service AND ssh.socket" \
  || bad "production branch no longer disables both ssh.service and ssh.socket"

grep -Fq 'assert_ssh_not_enabled' <<<"${ssh_body}" \
  && ok "production branch asserts the disable actually landed" \
  || bad "production branch no longer asserts the disable landed — a silent miss ships an SSH-reachable production image"

grep -Fq 'write_ssh_preset disable' <<<"${ssh_body}" \
  && ok "production branch writes the disable preset (survives first-boot preset-all)" \
  || bad "production branch no longer writes a disable preset — first-boot preset-all re-enables SSH"

grep -Fq 'write_ssh_preset enable' <<<"${ssh_body}" \
  && ok "debug branch writes the enable preset" \
  || bad "debug branch no longer writes an enable preset"

preset_body="$(extract_fn write_ssh_preset)"
preset_name="$(grep -oE '[0-9]{2}-[A-Za-z0-9-]+\.preset' <<<"${preset_body}" | head -1)"
if [[ -n "${preset_name}" && "${preset_name}" < "80-mkosi-ssh.preset" ]]; then
  ok "CeraLive preset ${preset_name} sorts ahead of mkosi's 80-mkosi-ssh.preset"
else
  bad "CeraLive preset '${preset_name}' does not sort ahead of 80-mkosi-ssh.preset — mkosi's 'enable ssh.socket' would win"
fi

grep -Fq 'disable ssh.socket' <<<"${preset_body}" \
  && ok "the preset pins ssh.socket too (mkosi's 80-mkosi-ssh.preset enables it explicitly)" \
  || bad "the preset does not pin ssh.socket — mkosi's explicit 'enable ssh.socket' still applies at first boot"

assert_body="$(extract_fn assert_ssh_not_enabled)"
grep -Fq 'ssh.socket' <<<"${assert_body}" && grep -Fq 'ssh.service' <<<"${assert_body}" \
  && ok "assert_ssh_not_enabled() mirrors the parity predicate (both unit names, symlinks under /etc/systemd/system)" \
  || bad "assert_ssh_not_enabled() no longer checks both ssh.service and ssh.socket"

# ---------------------------------------------------------------------------
# Part B — runtime, against a stub systemctl
# ---------------------------------------------------------------------------
echo "Part B — runtime behaviour"

STUBS="${TMP}/bin"
mkdir -p "${STUBS}"
CALLS="${TMP}/calls"
: >"${CALLS}"

# Emits the real table shape, then a trailer large enough that a reader which
# exits at the first match ALWAYS leaves unread bytes — making the old form's
# SIGPIPE deterministic instead of a ~8% race.
cat >"${STUBS}/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${CERALIVE_TEST_CALLS}"
case "$1" in
  list-unit-files)
    for a in "$@"; do case "$a" in ssh.service|ssh.socket) unit="$a" ;; esac; done
    [[ -n "${unit:-}" ]] || exit 1
    printf '%s enabled enabled\n' "${unit}"
    head -c 200000 /dev/zero | tr '\0' 'x'
    printf '\n1 unit files listed.\n'
    ;;
  *) : ;;
esac
STUB
chmod +x "${STUBS}/systemctl"
export CERALIVE_TEST_CALLS="${CALLS}"
PATH="${STUBS}:${PATH}"
export PATH

# shellcheck source=/dev/null
source "${POSTINST_LIB}"

probe_disable() {
  : >"${CALLS}"
  ( set -euo pipefail; disable_service ssh.service ) >/dev/null 2>&1
  grep -Fq 'disable ssh.service' "${CALLS}"
}

miss=0
for _ in $(seq 1 50); do probe_disable || miss=$((miss + 1)); done
(( miss == 0 )) \
  && ok "disable_service() actually disables an installed unit on 50/50 runs (was the SIGPIPE no-op)" \
  || bad "disable_service() skipped the disable on ${miss}/50 runs"

# Non-vacuity: the pre-fix probe against the identical stub must FAIL, or the
# harness above is proving nothing.
old_form_disable() {
  local svc="$1"
  if systemctl list-unit-files "${svc}" >/dev/null 2>&1 \
     && systemctl list-unit-files "${svc}" | grep -q "${svc}"; then
    systemctl disable "${svc}"
  fi
}
: >"${CALLS}"
( set -euo pipefail; old_form_disable ssh.service ) >/dev/null 2>&1
grep -Fq 'disable ssh.service' "${CALLS}" \
  && bad "non-vacuity: the pre-fix piped probe still disabled the unit — the harness does not reproduce the defect" \
  || ok "non-vacuity: the pre-fix piped probe silently skips the disable under the same stub"

# unit_file_present must still answer NO for a unit that is genuinely absent.
( set -euo pipefail; unit_file_present cups.service ) \
  && bad "unit_file_present() reported an absent unit as present" \
  || ok "unit_file_present() reports an absent unit as not present"

# Production branch — preset content, and the post-condition assertion.
run_ssh_branch() {
  local etc="$1" preset="$2" debug="$3"
  ( set -euo pipefail
    export CERALIVE_SYSTEMD_ETC_UNIT_DIR="${etc}" \
           CERALIVE_SYSTEMD_PRESET_DIR="${preset}" \
           CERALIVE_DEBUG_IMAGE="${debug}"
    configure_ssh_enablement ) >/dev/null 2>&1
}

prod_etc="${TMP}/prod-etc"; prod_preset="${TMP}/prod-preset"
mkdir -p "${prod_etc}/multi-user.target.wants"
run_ssh_branch "${prod_etc}" "${prod_preset}" 0 \
  && ok "configure_ssh_enablement() production branch succeeds on a clean tree" \
  || bad "configure_ssh_enablement() production branch failed on a clean tree"

prod_preset_file="$(find "${prod_preset}" -name '*.preset' -print -quit 2>/dev/null)"
if [[ -n "${prod_preset_file}" ]]; then
  assert_eq "production preset line 1" "disable ssh.service" "$(sed -n 1p "${prod_preset_file}")"
  assert_eq "production preset line 2" "disable ssh.socket" "$(sed -n 2p "${prod_preset_file}")"
else
  bad "production branch wrote no system-preset file"
fi

# The post-condition must FAIL CLOSED when a disable silently did not land.
leak_etc="${TMP}/leak-etc"
mkdir -p "${leak_etc}/multi-user.target.wants"
ln -sf /lib/systemd/system/ssh.service "${leak_etc}/multi-user.target.wants/ssh.service"
run_ssh_branch "${leak_etc}" "${TMP}/leak-preset" 0 \
  && bad "fail-closed: a surviving ssh.service enable symlink did NOT abort the build" \
  || ok "fail-closed: a surviving ssh.service enable symlink aborts the build"

# Debug branch — enabled, and the preset says so.
dbg_etc="${TMP}/dbg-etc"; dbg_preset="${TMP}/dbg-preset"
mkdir -p "${dbg_etc}"
: >"${CALLS}"
run_ssh_branch "${dbg_etc}" "${dbg_preset}" 1 \
  && ok "configure_ssh_enablement() debug branch succeeds" \
  || bad "configure_ssh_enablement() debug branch failed"
grep -Fq 'enable ssh' "${CALLS}" \
  && ok "debug branch enables ssh" \
  || bad "debug branch did not enable ssh"
dbg_preset_file="$(find "${dbg_preset}" -name '*.preset' -print -quit 2>/dev/null)"
[[ -n "${dbg_preset_file}" ]] && assert_eq "debug preset line 1" "enable ssh.service" "$(sed -n 1p "${dbg_preset_file}")" \
  || bad "debug branch wrote no system-preset file"

printf '\nssh-enablement-contract: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
