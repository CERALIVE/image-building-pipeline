#!/usr/bin/env bash
#
# systemd-ordering-cycle.test.sh — offline guard for the boot-time systemd
# dependency graph of the SSH-gate + data-migration units.
#
# It defends against TWO distinct classes of regression, both seen on real
# hardware in this effort:
#
#   (A) ORDERING CYCLES (proof-10 UART boot log, 2026-07-15). ssh.socket is
#       Before=sockets.target (early boot, before basic.target). A guard that is
#       Before=ssh.socket while carrying the default After=basic.target closes
#       ssh.socket -> guard -> basic.target -> sockets.target -> ssh.socket, and
#       systemd DELETES ssh.socket's start job (SSH never starts). The same trap
#       hit ceralive-migrate-data.service vs local-fs.target/var-log.mount. Fix:
#       DefaultDependencies=no.
#
#   (B) MISSING SYSINIT ORDERING (proof-11 UART boot log, 2026-07-15). Opting out
#       of default deps to break (A) ALSO dropped the implicit After=sysinit.target.
#       ceralive-ssh-firstboot.service then raced ahead of systemd-sysusers /
#       systemd-tmpfiles / udev and FAILED under `set -euo pipefail`, taking
#       ssh.service/ssh.socket down with "Dependency failed" — with ZERO ordering
#       cycles in the boot log. Fix: re-add After=sysinit.target explicitly (the
#       SAFE half of the default deps; sysinit.target is ordered before
#       sockets.target so it cannot re-close the ssh.socket loop).
#
# A cycle-only test would NOT have caught (B) (proof-11 had zero cycles yet still
# failed), so this test asserts BOTH acyclicity AND real ordering:
#
#   Part A — static contract (systemd-version independent).
#   Part B — dynamic proof via `systemd-analyze verify --root`:
#              B1 the assembled unit set has ZERO ordering cycles, and
#              B2 each Before=ssh.socket guard is TRANSITIVELY ordered after
#                 systemd-sysusers.service and systemd-tmpfiles-setup.service.
#            (B2) is proven with an ordering PROBE: a throwaway unit that is
#            After=<guard> Before=<sysinit-phase unit> MUST close a cycle iff the
#            guard is genuinely ordered after that unit. This turns an ordering
#            question into one `systemd-analyze verify` can answer offline.
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

# Any unit ordered Before=ssh.socket must (A) opt out of default dependencies to
# avoid the ssh.socket cycle, and (B) explicitly re-add After=sysinit.target so it
# still runs after the sysinit phase (users/tmpfiles/udev/RNG) it depends on.
for unit in "${FIRSTBOOT}" "${CIUART}"; do
  base="$(basename "${unit}")"
  grep -Fq 'Before=ssh.service ssh.socket' "${unit}" \
    || fail "${base} no longer orders Before=ssh.service ssh.socket (guard contract changed)"
  grep -Eq '^DefaultDependencies=no$' "${unit}" \
    || fail "${base} is Before=ssh.socket but lacks DefaultDependencies=no — reopens the ssh.socket ordering cycle"
  grep -Eq '^After=.*\bsysinit\.target\b' "${unit}" \
    || fail "${base} has DefaultDependencies=no but no After=sysinit.target — races ahead of sysusers/tmpfiles (proof-11 failure)"
  grep -Eq '^After=.*\bbasic\.target\b' "${unit}" \
    && fail "${base} must NOT be After=basic.target — that re-closes the ssh.socket ordering cycle"
done

# ceralive-migrate-data.service (generated inline by postinst-lib.sh) must run in
# the local-fs setup phase, not after it. It CANNOT be After=sysinit.target
# (sysinit.target is After=local-fs.target — that would cycle); it only touches
# /data + rootfs paths as root, so it needs no sysinit-phase ordering.
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
grep -Eq '\bsysinit\.target\b' <<<"${mig}" \
  && fail "ceralive-migrate-data.service must NOT reference sysinit.target — it runs in the local-fs phase (would cycle)"

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

# systemd-analyze verify is non-deterministic in WHICH job it deletes to break a
# cycle, so count matched cycle lines across a few runs.
count_cycles() {
  local out n total=0
  for _ in 1 2 3; do
    out="$(systemd-analyze verify --root "${S}" default.target 2>&1 || true)"
    n="$(printf '%s\n' "${out}" | grep -c 'Found ordering cycle' || true)"
    total=$((total + n))
  done
  printf '%s' "${total}"
}

# --- B1: the assembled unit set must be acyclic ---------------------------------
base_cycles="$(count_cycles)"
if (( base_cycles > 0 )); then
  systemd-analyze verify --root "${S}" default.target 2>&1 \
    | grep -E 'Found ordering cycle|deleted to break' | sort -u >&2
  fail "assembled unit set has ${base_cycles} ordering cycle(s) — see above"
fi
echo "systemd-ordering-cycle: Part B1 acyclic OK (systemd $(systemd-analyze --version | awk 'NR==1{print $2}'))"

# --- B2: prove each guard is transitively After the sysinit-phase units ---------
# Inject a probe unit After=<guard> Before=<sysinit unit>. If (and only if) the
# guard is genuinely ordered after that sysinit unit, the probe closes a cycle.
probe_orders_after() { # $1=guard unit  $2=target sysinit unit -> 0 if guard is After target
  local guard="$1" target="$2" probe="${ETC}/zz-order-probe.service"
  cat >"${probe}" <<EOF
[Unit]
Description=ordering probe (${guard} after ${target})
DefaultDependencies=no
After=${guard}
Before=${target}
[Service]
Type=oneshot
ExecStart=/bin/true
[Install]
WantedBy=sysinit.target
EOF
  mkdir -p "${ETC}/sysinit.target.wants"
  ln -sf ../zz-order-probe.service "${ETC}/sysinit.target.wants/zz-order-probe.service"
  local c; c="$(count_cycles)"
  rm -f "${probe}" "${ETC}/sysinit.target.wants/zz-order-probe.service"
  (( c > 0 ))
}

checked=0
for target in systemd-sysusers.service systemd-tmpfiles-setup.service; do
  [[ -f "${SYS_LIB}/${target}" ]] || { echo "systemd-ordering-cycle: ${target} absent — skipping its ordering probe"; continue; }
  for guard in ceralive-ssh-firstboot.service ceralive-ci-uart-bootstrap.service; do
    probe_orders_after "${guard}" "${target}" \
      || fail "${guard} is NOT ordered after ${target} (missing After=sysinit.target — proof-11 runtime failure)"
    checked=$((checked + 1))
  done
done

# Backstop when neither sysinit unit shipped: prove After=sysinit.target directly.
if (( checked == 0 )); then
  for guard in ceralive-ssh-firstboot.service ceralive-ci-uart-bootstrap.service; do
    probe_orders_after "${guard}" sysinit.target \
      || fail "${guard} is NOT ordered after sysinit.target (proof-11 runtime failure)"
  done
fi

echo "systemd-ordering-cycle: Part B2 sysinit ordering OK (guards run after sysusers/tmpfiles)"
echo "systemd-ordering-cycle regression: PASS"
