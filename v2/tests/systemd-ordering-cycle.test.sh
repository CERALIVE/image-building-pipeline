#!/usr/bin/env bash
#
# systemd-ordering-cycle.test.sh — offline guard against the boot-time systemd
# ordering cycles that deleted ssh.socket and local-fs.target on real hardware
# (proof-10 UART boot log, 2026-07-15).
#
# Two independent cycles were shipped:
#
#   1. ssh.socket cycle. Both ceralive-ssh-firstboot.service and
#      ceralive-ci-uart-bootstrap.service are Before=ssh.socket. ssh.socket is
#      itself Before=sockets.target (early boot, before basic.target), so a guard
#      that inherits the default After=basic.target closes the loop
#      ssh.socket -> guard -> basic.target -> sockets.target -> ssh.socket.
#      systemd breaks it by DELETING ssh.socket's start job — SSH never starts.
#
#   2. local-fs.target cycle. ceralive-migrate-data.service seeds the /data
#      skeleton that the /var/log|/opt/ceralive bind mounts shadow, so those
#      mounts are After=ceralive-migrate-data.service AND (by default)
#      Before=local-fs.target. A migrate-data that inherits the default
#      After=basic.target/local-fs.target closes
#      local-fs.target -> var-log.mount -> migrate-data -> (basic/local-fs).
#
# The fix for all three units is DefaultDependencies=no plus explicit early
# ordering. This test enforces that invariant two ways:
#
#   Part A — static contract (systemd-version independent): the three units must
#            carry DefaultDependencies=no and must not re-introduce the late
#            ordering that closes each cycle.
#   Part B — dynamic proof (needs systemd-analyze + systemctl): assemble the real
#            unit set into a --root and assert `systemd-analyze verify` finds ZERO
#            ordering cycles in the multi-user.target transaction.
#
# shellcheck disable=SC2016

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2="$(cd "${HERE}/.." && pwd)"
RUNTIME="${V2}/mkosi/runtime"
POSTINST_LIB="${V2}/mkosi/customize/postinst-lib.sh"
FIRSTBOOT="${RUNTIME}/ceralive-ssh-firstboot.service"
CIUART="${RUNTIME}/ceralive-ci-uart-bootstrap.service"

fail() { printf 'systemd-ordering-cycle regression: %s\n' "$1" >&2; exit 1; }

for f in "${FIRSTBOOT}" "${CIUART}" "${POSTINST_LIB}"; do
  [[ -f "${f}" ]] || fail "missing source file: ${f}"
done

# ---------------------------------------------------------------------------
# Part A — static contract (version independent)
# ---------------------------------------------------------------------------

# Any unit ordered Before=ssh.socket must opt out of default dependencies, else
# it inherits After=basic.target and cycles ssh.socket <-> sockets.target.
for unit in "${FIRSTBOOT}" "${CIUART}"; do
  base="$(basename "${unit}")"
  grep -Fq 'Before=ssh.service ssh.socket' "${unit}" \
    || fail "${base} no longer orders Before=ssh.service ssh.socket (guard contract changed)"
  grep -Eq '^DefaultDependencies=no$' "${unit}" \
    || fail "${base} is Before=ssh.socket but lacks DefaultDependencies=no — reopens the ssh.socket ordering cycle"
done

# ceralive-migrate-data.service (generated inline by postinst-lib.sh) must run in
# the local-fs setup phase, not after it.
mig="$(awk '
  /cat >\/etc\/systemd\/system\/ceralive-migrate-data\.service <<EOF/ { f=1; next }
  f && /^EOF$/ { exit }
  f { print }
' "${POSTINST_LIB}")"
[[ -n "${mig}" ]] || fail "could not extract ceralive-migrate-data.service heredoc from postinst-lib.sh"
grep -Eq '^DefaultDependencies=no$' <<<"${mig}" \
  || fail "ceralive-migrate-data.service lacks DefaultDependencies=no — reopens the local-fs.target ordering cycle"
grep -Eq '^After=local-fs\.target$' <<<"${mig}" \
  && fail "ceralive-migrate-data.service still has After=local-fs.target — closes local-fs.target <-> var-log.mount cycle"
grep -Eq '^Before=.*\blocal-fs\.target\b' <<<"${mig}" \
  || fail "ceralive-migrate-data.service must be Before=local-fs.target (run before the bind mounts it seeds)"

echo "systemd-ordering-cycle: Part A static contract OK"

# ---------------------------------------------------------------------------
# Part B — dynamic proof via systemd-analyze verify
# ---------------------------------------------------------------------------
if ! command -v systemd-analyze >/dev/null 2>&1 || ! command -v systemctl >/dev/null 2>&1; then
  echo "systemd-ordering-cycle: systemd-analyze/systemctl unavailable — skipping dynamic proof (static contract enforced)"
  echo "systemd-ordering-cycle regression: PASS (static only)"
  exit 0
fi

SYS_LIB=""
for cand in /usr/lib/systemd/system /lib/systemd/system; do
  [[ -d "${cand}" ]] && { SYS_LIB="${cand}"; break; }
done
[[ -n "${SYS_LIB}" ]] || { echo "systemd-ordering-cycle: no host systemd unit tree — skipping dynamic proof"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
S="${TMP}/root"
ETC="${S}/etc/systemd/system"
mkdir -p "${ETC}" "${S}/usr/lib/systemd/system" "${S}/etc/ssh" "${S}/usr/local/sbin"
cp -a "${SYS_LIB}/." "${S}/usr/lib/systemd/system/" 2>/dev/null || true
for exe in ceralive-ssh-firstboot ceralive-ci-uart-bootstrap ceralive-migrate-data; do
  printf '#!/bin/sh\nexit 0\n' >"${S}/usr/local/sbin/${exe}"; chmod 0755 "${S}/usr/local/sbin/${exe}"
done

# faithful Debian ssh.socket/ssh.service (Before=sockets.target, no Conflicts)
cat >"${S}/usr/lib/systemd/system/ssh.socket" <<'EOF'
[Unit]
Description=OpenBSD Secure Shell server socket
Before=sockets.target
[Socket]
ListenStream=22
Accept=no
[Install]
WantedBy=sockets.target
EOF
cat >"${S}/usr/lib/systemd/system/ssh.service" <<'EOF'
[Unit]
Description=OpenBSD Secure Shell server
After=network.target
[Service]
ExecStart=/usr/sbin/sshd -D
Type=simple
[Install]
WantedBy=multi-user.target
EOF

# real device units under test
cp "${FIRSTBOOT}" "${ETC}/ceralive-ssh-firstboot.service"
cp "${CIUART}"    "${ETC}/ceralive-ci-uart-bootstrap.service"

# render the generated migrate-data + bind-mount units straight from postinst-lib.sh
printf '%s\n' "${mig}" | sed 's#${data_root}#/data#g' >"${ETC}/ceralive-migrate-data.service"
mount_tpl="$(awk '
  /cat >"\/etc\/systemd\/system\/\$\{unit\}" <<EOF/ { f=1; next }
  f && /^EOF$/ { exit }
  f { print }
' "${POSTINST_LIB}")"
[[ -n "${mount_tpl}" ]] || fail "could not extract bind-mount heredoc from postinst-lib.sh"
render_mount() { # $1=src $2=dst $3=unitname
  printf '%s\n' "${mount_tpl}" \
    | sed -e "s#\${data_root}#/data#g" -e "s#\${src}#$1#g" -e "s#\${dst}#$2#g" \
    >"${ETC}/$3"
}
render_mount /data/log       /var/log       var-log.mount
render_mount /data/ceralive  /opt/ceralive  opt-ceralive.mount

# /data mount + stubs referenced by Before=
cat >"${ETC}/data.mount" <<'EOF'
[Unit]
Description=CeraLive data partition
[Mount]
What=/dev/disk/by-partlabel/data
Where=/data
Type=ext4
EOF
for stub in ceralive.service ceralive-hostname.service; do
  cat >"${ETC}/${stub}" <<EOF
[Unit]
Description=${stub} stub
[Service]
ExecStart=/bin/true
[Install]
WantedBy=multi-user.target
EOF
done

systemctl --root "${S}" enable \
  ssh.socket ceralive-ssh-firstboot.service ceralive-ci-uart-bootstrap.service \
  ceralive-migrate-data.service var-log.mount opt-ceralive.mount data.mount \
  ceralive.service ceralive-hostname.service >/dev/null 2>&1 || true
mkdir -p "${ETC}/multi-user.target.wants"
ln -sf ../ssh.service "${ETC}/multi-user.target.wants/ssh.service"
ln -sf "${SYS_LIB}/multi-user.target" "${ETC}/default.target"

# verify is non-deterministic in which job it deletes to break a cycle, so run a
# few times and fail if a cycle surfaces in ANY run.
cycles=0
for _ in 1 2 3; do
  out="$(systemd-analyze verify --root "${S}" default.target 2>&1 || true)"
  n="$(printf '%s\n' "${out}" | grep -c 'Found ordering cycle' || true)"
  cycles=$((cycles + n))
  last="${out}"
done
if (( cycles > 0 )); then
  printf '%s\n' "${last}" | grep -E 'Found ordering cycle|deleted to break' | sort -u >&2
  fail "systemd-analyze verify found ${cycles} ordering cycle(s) across the assembled unit set"
fi

echo "systemd-ordering-cycle: Part B dynamic proof OK (systemd $(systemd-analyze --version | awk 'NR==1{print $2}'), zero cycles)"
echo "systemd-ordering-cycle regression: PASS"
