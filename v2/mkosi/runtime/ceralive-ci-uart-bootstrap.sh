#!/bin/bash
set -euo pipefail

STATE_DIR="${CERALIVE_UART_STATE_DIR:-/data/ceralive/ssh}"
IMAGE_COMMIT_FILE="${CERALIVE_IMAGE_COMMIT_FILE:-/etc/ceralive/image-build-commit}"
KEYS="${STATE_DIR}/root_authorized_keys"
ACCESS_DIR="${STATE_DIR}/ci-access"
NONCE_DIR="${STATE_DIR}/ci-nonces"
EPOCH_FLOOR="${STATE_DIR}/ci-epoch-floor"
DATE_BIN="${CERALIVE_UART_DATE_BIN:-date}"
CHOWN_BIN="${CERALIVE_UART_CHOWN_BIN:-chown}"
INSTALL_BIN="${CERALIVE_UART_INSTALL_BIN:-install}"
OPENSSL_BIN="${CERALIVE_UART_OPENSSL_BIN:-openssl}"
PUBLIC_KEY_FILE="${CERALIVE_UART_PUBLIC_KEY_FILE:-/etc/ceralive/uart-bootstrap-public.pem}"
CHIP_INFO_BIN="${CERALIVE_CHIP_INFO_BIN:-/usr/local/sbin/ceralive-rockchip-chip-info}"

fail() {
    printf 'CERALIVE_UART_BOOTSTRAP_ERROR %s\n' "$1"
    exit 1
}

# RK3588's live console /dev/ttyFIQ0 is the FIQ-debugger's fixed-rate software
# console over the debug UART: it rejects the TCSETS baud ioctl, so `stty 1500000`
# fails and, under `set -e`, aborted the whole bootstrap before READY (real
# Rock 5B+ regression, 2026-07-19). There the channel already works by default,
# so stty is best-effort. On a real UART (future ttyS board / x86 ttyS0) the baud
# set is meaningful: keep it fatal — deliberately NOT `|| true` — so a genuine
# mis-provision is surfaced, not masked.
configure_bootstrap_tty() {
    local dev
    dev="$(tty 2>/dev/null || true)"
    case "${dev##*/}" in
    ttyFIQ*)
        stty -echo <&0 2>/dev/null \
            || printf 'CERALIVE_UART_BOOTSTRAP_INFO fiq-tty-stty-skipped %s\n' "${dev}"
        ;;
    *)
        stty 1500000 sane -echo <&0 || fail tty-setup
        ;;
    esac
}

if [[ -t 0 ]]; then
    configure_bootstrap_tty
fi
boot_nonce="${CERALIVE_UART_BOOT_NONCE:-$("${OPENSSL_BIN}" rand -hex 32)}"
[[ "${boot_nonce}" =~ ^[0-9a-f]{64}$ ]] || fail boot-nonce
printf 'CERALIVE_UART_BOOTSTRAP_READY %s\n' "${boot_nonce}"
IFS= read -r request || fail request-read
read -r version payload_b64 signature_b64 extra <<<"${request}"
[[ "${version}" == CERALIVE3 && -n "${payload_b64:-}" && \
   -n "${signature_b64:-}" && -z "${extra:-}" ]] || fail request-version
[[ "${payload_b64}" =~ ^[A-Za-z0-9+/=]+$ ]] || fail request-encoding
[[ "${signature_b64}" =~ ^[A-Za-z0-9+/=]+$ ]] || fail signature-encoding
[[ -f "${PUBLIC_KEY_FILE}" && ! -L "${PUBLIC_KEY_FILE}" ]] || fail public-key
verify_root="${CERALIVE_UART_VERIFY_ROOT:-/run}"
verify_dir="$(mktemp -d "${verify_root}/ceralive-uart-verify.XXXXXX")" || fail verify-temp
tmp=""
cleanup_bootstrap() {
    [[ -z "${tmp}" ]] || rm -f -- "${tmp}"
    rm -rf -- "${verify_dir}"
}
trap cleanup_bootstrap EXIT
printf '%s' "${payload_b64}" | base64 -d >"${verify_dir}/payload" 2>/dev/null \
    || fail request-decode
printf '%s' "${signature_b64}" | base64 -d >"${verify_dir}/signature" 2>/dev/null \
    || fail signature-decode
"${OPENSSL_BIN}" pkeyutl -verify -pubin -inkey "${PUBLIC_KEY_FILE}" -rawin \
    -in "${verify_dir}/payload" -sigfile "${verify_dir}/signature" >/dev/null 2>&1 \
    || fail request-signature
payload="$(<"${verify_dir}/payload")"

declare -A fields=()
while IFS='=' read -r name value; do
    [[ "${name}" =~ ^(access_id|expires|host_epoch|challenge|candidate_commit|soc_id|boot_nonce|key_type|key_body)$ ]] \
        || fail request-field
    [[ -z "${fields[${name}]+x}" ]] || fail request-duplicate
    fields["${name}"]="${value}"
done <<<"${payload}"

for name in access_id expires host_epoch challenge candidate_commit soc_id boot_nonce key_type key_body; do
    [[ -n "${fields[${name}]:-}" ]] || fail "request-missing-${name}"
done
[[ "${fields[access_id]}" =~ ^[A-Za-z0-9._-]{1,80}$ ]] || fail access-id
[[ "${fields[expires]}" =~ ^[0-9]{14}Z$ ]] || fail expiry
[[ "${fields[host_epoch]}" =~ ^[0-9]{10}$ ]] || fail host-epoch
[[ "${fields[challenge]}" =~ ^[0-9a-f]{64}$ ]] || fail challenge
[[ "${fields[candidate_commit]}" =~ ^[0-9a-f]{40}$ ]] || fail candidate-commit
[[ "${fields[soc_id]}" =~ ^[0-9a-f]{32}$ ]] || fail soc-id
[[ "${fields[boot_nonce]}" =~ ^[0-9a-f]{64}$ ]] || fail boot-nonce
[[ "${fields[boot_nonce]}" == "${boot_nonce}" ]] || fail boot-nonce-mismatch
[[ "${fields[key_type]}" == ssh-ed25519 ]] || fail key-type
[[ "${fields[key_body]}" =~ ^[A-Za-z0-9+/=]+$ ]] || fail key-body
expiry_iso="${fields[expires]:0:4}-${fields[expires]:4:2}-${fields[expires]:6:2}T${fields[expires]:8:2}:${fields[expires]:10:2}:${fields[expires]:12:2}Z"
expires_epoch="$("${DATE_BIN}" -u -d "${expiry_iso}" +%s 2>/dev/null)" || fail expiry-parse
host_epoch=$((10#${fields[host_epoch]}))
(( expires_epoch >= host_epoch + 60 && expires_epoch <= host_epoch + 3600 )) \
    || fail expiry-window
[[ -r "${IMAGE_COMMIT_FILE}" ]] || fail image-commit-missing
image_commit="$(tr -d '[:space:]' <"${IMAGE_COMMIT_FILE}")"
[[ "${image_commit}" == "${fields[candidate_commit]}" ]] || fail image-commit-mismatch
[[ -x "${CHIP_INFO_BIN}" && ! -L "${CHIP_INFO_BIN}" ]] || fail soc-id-source
device_soc_id="$("${CHIP_INFO_BIN}" 2>/dev/null)" || fail soc-id-missing
device_soc_id="${device_soc_id,,}"
[[ "${device_soc_id}" =~ ^[0-9a-f]{32}$ ]] || fail soc-id-invalid
[[ "${device_soc_id}" == "${fields[soc_id]}" ]] || fail soc-id-mismatch

[[ -d "${STATE_DIR}" && ! -L "${STATE_DIR}" ]] || fail state-dir
"${INSTALL_BIN}" -d -m 0700 -o root -g root "${NONCE_DIR}"
[[ -d "${NONCE_DIR}" && ! -L "${NONCE_DIR}" ]] || fail nonce-store
if [[ -e "${EPOCH_FLOOR}" || -L "${EPOCH_FLOOR}" ]]; then
    [[ -f "${EPOCH_FLOOR}" && ! -L "${EPOCH_FLOOR}" ]] || fail epoch-floor
    epoch_floor="$(tr -d '[:space:]' <"${EPOCH_FLOOR}")"
    [[ "${epoch_floor}" =~ ^[0-9]{10}$ ]] || fail epoch-floor
    (( host_epoch >= 10#${epoch_floor} )) || fail epoch-rollback
fi
nonce_marker="${NONCE_DIR}/${boot_nonce}"
[[ ! -e "${nonce_marker}" && ! -L "${nonce_marker}" ]] || fail nonce-replay
( set -o noclobber; printf 'access_id=%s\nhost_epoch=%s\n' \
    "${fields[access_id]}" "${host_epoch}" >"${nonce_marker}" ) 2>/dev/null \
    || fail nonce-replay
"${CHOWN_BIN}" root:root "${nonce_marker}"
chmod 0600 "${nonce_marker}"
[[ ! -L "${EPOCH_FLOOR}" ]] || fail epoch-floor
tmp="$(mktemp "${STATE_DIR}/.ci-epoch-floor.XXXXXX")"
printf '%s\n' "${host_epoch}" >"${tmp}"
"${CHOWN_BIN}" root:root "${tmp}"
chmod 0600 "${tmp}"
mv -f -- "${tmp}" "${EPOCH_FLOOR}"
tmp=""

"${DATE_BIN}" -u -s "@${host_epoch}" >/dev/null
[[ -f "${KEYS}" && ! -L "${KEYS}" ]] || fail root-key-store
"${INSTALL_BIN}" -d -m 0700 -o root -g root "${ACCESS_DIR}"
[[ -d "${ACCESS_DIR}" && ! -L "${ACCESS_DIR}" ]] || fail access-store
authorized_line="restrict,expiry-time=\"${fields[expires]}\" ${fields[key_type]} ${fields[key_body]} ceralive-ci-${fields[access_id]}"
grep -Fqx -- "${authorized_line}" "${KEYS}" || printf '%s\n' "${authorized_line}" >>"${KEYS}"
"${CHOWN_BIN}" root:root "${KEYS}"
chmod 0600 "${KEYS}"

marker="${ACCESS_DIR}/${fields[access_id]}"
tmp="$(mktemp "${ACCESS_DIR}/.${fields[access_id]}.XXXXXX")"
printf 'challenge=%s\ncandidate_commit=%s\nsoc_id=%s\n' \
    "${fields[challenge]}" "${fields[candidate_commit]}" "${fields[soc_id]}" >"${tmp}"
chmod 0600 "${tmp}"
mv -f -- "${tmp}" "${marker}"
tmp=""

printf 'CERALIVE_UART_PROVISIONED %s %s\n' \
    "${fields[challenge]}" "${fields[candidate_commit]}"
