#!/usr/bin/env bash
#
# ssh-firstboot-privsep.test.sh — offline guard for the boot-time failure that
# ceralive-ssh-firstboot.service hit on real hardware (proof-13 UART, 2026-07-16).
#
# THE BUG. The last thing ceralive-ssh-firstboot.sh does is `sshd -t` to validate
# the sshd config it just wrote. `sshd -t` refuses to run without the privilege-
# separation directory /run/sshd, exiting 255 with "Missing privilege separation
# directory: /run/sshd". On a fresh boot that directory does not exist yet:
#
#   * nothing in the image ships a tmpfiles.d entry that creates /run/sshd, and
#   * its only creator is ssh.service's `RuntimeDirectory=sshd`, which runs AFTER
#     this Before=ssh.service guard.
#
# So `sshd -t` exits 255, `set -euo pipefail` fails the unit, and — because both
# ssh.service (the LAN sshd on :22) and ssh.socket carry
# Requires=ceralive-ssh-firstboot.service via their RequiredBy= — BOTH depend-fail:
# port 22 is closed on every boot while the rest of the system boots fine.
#
# WHY THE SIBLING systemd-ordering-cycle.test.sh COULD NOT CATCH IT. That test is a
# dependency-GRAPH check (systemd-analyze verify / ordering probes). This failure is
# NOT a graph defect: the ordering graph is perfectly acyclic and correct. It is a
# RUNTIME failure inside the guard's ExecStart script — a missing /run/sshd at the
# instant `sshd -t` runs. No amount of static systemd-analyze inspection can see it
# because the unit's *dependencies* are all satisfied; the *script* is what exits
# non-zero. A live-boot check would instead have to assert, after boot, that
# `systemctl is-active ceralive-ssh-firstboot.service` is active AND `ssh.service`
# is active AND TCP :22 accepts a connection (exactly the orchestrator's post-flash
# network probe) — none of which is expressible in an offline dependency graph.
#
# WHAT WE CAN STILL ENFORCE OFFLINE. The fix is a source contract: the guard script
# must create /run/sshd BEFORE it invokes `sshd -t`. That ordering-within-the-script
# is statically checkable and is what Part A locks. Part B additionally reproduces
# the real runtime failure end-to-end in a rootless namespace when the host supports
# it, proving the contract Part A checks is the one that actually keeps port 22 open.
#
# shellcheck disable=SC2016

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2="$(cd "${HERE}/.." && pwd)"
RUNTIME="${V2}/mkosi/runtime"
FIRSTBOOT_SH="${RUNTIME}/ceralive-ssh-firstboot.sh"

fail() { printf 'ssh-firstboot-privsep regression: %s\n' "$1" >&2; exit 1; }

[[ -f "${FIRSTBOOT_SH}" ]] || fail "missing source file: ${FIRSTBOOT_SH}"

# ---------------------------------------------------------------------------
# Part A — static source contract (version independent, always enforced)
# ---------------------------------------------------------------------------
# The guard must run `sshd -t`, must create /run/sshd, and the creation MUST come
# first. Line numbers make the "before" relationship explicit and robust.

sshd_t_line="$(grep -nE '^[[:space:]]*sshd[[:space:]]+-t([[:space:]]|$)' "${FIRSTBOOT_SH}" | head -1 | cut -d: -f1)"
[[ -n "${sshd_t_line}" ]] \
  || fail "ceralive-ssh-firstboot.sh no longer runs 'sshd -t' — validation contract changed"

# Accept either install -d or mkdir -p as the privsep-dir creator, in any casing of
# the path, so the contract survives a stylistic rewrite of the exact command.
privsep_line="$(grep -nE '(install[[:space:]]+-d|mkdir([[:space:]]+-p)?)[^#]*/run/sshd' "${FIRSTBOOT_SH}" | head -1 | cut -d: -f1)"
[[ -n "${privsep_line}" ]] \
  || fail "ceralive-ssh-firstboot.sh does not create /run/sshd before 'sshd -t' — reopens the proof-13 privsep failure (sshd -t exits 255, unit fails, ssh.service/ssh.socket DEPEND-fail, port 22 closed)"

(( privsep_line < sshd_t_line )) \
  || fail "/run/sshd is created at line ${privsep_line} but 'sshd -t' runs earlier at line ${sshd_t_line} — sshd -t would still hit the missing privsep dir"

echo "ssh-firstboot-privsep: Part A static contract OK (creates /run/sshd at line ${privsep_line} before sshd -t at line ${sshd_t_line})"

# ---------------------------------------------------------------------------
# Part B — runtime reproduction in a rootless user+mount namespace (best effort)
# ---------------------------------------------------------------------------
# Prove the real script survives the exact proof-13 condition (empty /run, so no
# /run/sshd) end-to-end. We fake just enough of the baked image — a ceralive user
# mapped to the namespace root, an empty tmpfs /etc/ssh + /run, and faithful stubs
# for the few privileged/host binaries — then run the UNMODIFIED script and require
# exit 0. The `sshd` stub replicates real OpenSSH `sshd -t`: it fails iff /run/sshd
# is absent (verified against real Debian sshd during the proof-13 investigation),
# so a future removal of the fix makes this test fail exactly as the board did.

if ! unshare -rm --map-root-user true 2>/dev/null; then
  echo "ssh-firstboot-privsep: rootless user+mount namespaces unavailable — skipping Part B runtime reproduction (static contract enforced)"
  echo "ssh-firstboot-privsep regression: PASS (static only)"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

BIN="${TMP}/bin"
mkdir -p "${BIN}" "${TMP}/home" "${TMP}/root-home"

# Faithful `sshd -t`: succeed only when the privilege-separation dir exists.
cat >"${BIN}/sshd" <<'STUB'
#!/bin/sh
if [ ! -d /run/sshd ]; then
  echo "Missing privilege separation directory: /run/sshd" >&2
  exit 255
fi
exit 0
STUB
# `ssh-keygen -A` just needs to leave host-key files behind for the persist/copy.
cat >"${BIN}/ssh-keygen" <<'STUB'
#!/bin/sh
for t in rsa ecdsa ed25519; do : >"/etc/ssh/ssh_host_${t}_key"; : >"/etc/ssh/ssh_host_${t}_key.pub"; done
exit 0
STUB
printf '#!/bin/sh\nexit 0\n' >"${BIN}/chage"
printf '#!/bin/sh\nexit 0\n' >"${BIN}/logger"
chmod 0755 "${BIN}"/*

# ceralive + root both mapped to the namespace root uid so `install -o`/chown
# resolve; both homes point at writable tmp dirs (the real /root is owned by an
# unmapped host uid and is not writable inside the namespace).
printf 'root:x:0:0::%s:/bin/bash\nceralive:x:0:0::%s:/bin/bash\n' "${TMP}/root-home" "${TMP}/home" >"${TMP}/passwd"
printf 'root:x:0:\nceralive:x:0:\n' >"${TMP}/group"

REPRO="${TMP}/repro.sh"
cat >"${REPRO}" <<REPRO_EOF
set -e
mount -t tmpfs none /run
mount -t tmpfs none /etc/ssh
mount --bind "${TMP}/passwd" /etc/passwd
mount --bind "${TMP}/group" /etc/group
# Seed the main sshd_config the guard's drop-in extends (the image ships it).
printf 'Include /etc/ssh/sshd_config.d/*.conf\n' >/etc/ssh/sshd_config
export PATH="${BIN}:\$PATH"
export CERALIVE_SSH_STATE_DIR="${TMP}/state"
bash "${FIRSTBOOT_SH}"
test -d /run/sshd
REPRO_EOF

if unshare -rm --map-root-user bash "${REPRO}" >/dev/null 2>&1; then
  echo "ssh-firstboot-privsep: Part B runtime reproduction OK (real script exits 0 with an initially-empty /run)"
else
  fail "the real ceralive-ssh-firstboot.sh failed against an empty /run (proof-13 condition) — /run/sshd guard missing or ineffective"
fi

echo "ssh-firstboot-privsep regression: PASS"
