#!/usr/bin/env bash
set -euo pipefail

board_ip="" ssh_user="" ssh_port="" ssh_identity="" authorized_line_file="" access_id="" receipt=""
known_hosts=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --board-ip) board_ip="${2:-}"; shift 2 ;;
    --ssh-user) ssh_user="${2:-}"; shift 2 ;;
    --ssh-port) ssh_port="${2:-}"; shift 2 ;;
    --ssh-identity) ssh_identity="${2:-}"; shift 2 ;;
    --known-hosts) known_hosts="${2:-}"; shift 2 ;;
    --authorized-line) authorized_line_file="${2:-}"; shift 2 ;;
    --access-id) access_id="${2:-}"; shift 2 ;;
    --receipt) receipt="${2:-}"; shift 2 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
for value in board_ip ssh_user ssh_port ssh_identity known_hosts authorized_line_file access_id receipt; do
  [[ -n "${!value}" ]] || { printf '%s is required\n' "${value}" >&2; exit 2; }
done
[[ -r "${ssh_identity}" && -r "${known_hosts}" && -r "${authorized_line_file}" && "${ssh_port}" =~ ^[0-9]+$ ]]
[[ "${access_id}" =~ ^[A-Za-z0-9._-]{1,80}$ ]]
[[ -d "$(dirname -- "${receipt}")" && ! -L "${receipt}" ]]

line_b64="$(base64 -w0 "${authorized_line_file}")"
payload="$(mktemp)"
trap 'rm -f -- "${payload}"' EXIT
cat >"${payload}" <<EOF
set -eu
line=\$(printf '%s' '${line_b64}' | base64 -d)
keys=/data/ceralive/ssh/root_authorized_keys
tmp=\$(mktemp /data/ceralive/ssh/.root_authorized_keys.XXXXXX)
awk -v line="\${line}" '\$0 != line' "\${keys}" >"\${tmp}"
chmod 0600 "\${tmp}"
mv -f "\${tmp}" "\${keys}"
rm -f '/data/ceralive/ssh/ci-access/${access_id}' \
  '/data/ceralive/ssh/ci-access/${access_id}.retain-once'
! grep -Fqx -- "\${line}" "\${keys}"
test ! -e '/data/ceralive/ssh/ci-access/${access_id}'
test ! -e '/data/ceralive/ssh/ci-access/${access_id}.retain-once'
printf 'ephemeral_ssh_access=revoked\naccess_id=${access_id}\n'
EOF

ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
  -o "UserKnownHostsFile=${known_hosts}" -o GlobalKnownHostsFile=/dev/null \
  -o IdentitiesOnly=yes -i "${ssh_identity}" -p "${ssh_port}" \
  "${ssh_user}@${board_ip}" "/bin/sh" <"${payload}" >"${receipt}"
grep -Fxq 'ephemeral_ssh_access=revoked' "${receipt}"
grep -Fxq "access_id=${access_id}" "${receipt}"
