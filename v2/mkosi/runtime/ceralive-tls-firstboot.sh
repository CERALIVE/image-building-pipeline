#!/bin/bash
#
# ceralive-tls-firstboot.sh — first-boot per-device TLS cert generation (Task 15, SC3).
#
# Committed standalone artifact (single source of truth under v2/mkosi/runtime/).
# Installed to /usr/local/sbin/ceralive-tls-firstboot and run once per boot by
# ceralive-tls-firstboot.service, ordered Before=nginx.service so the nginx TLS
# front (ceralive-tls.nginx.conf, listen 443 ssl) always has a key+cert to load.
#
# WHY self-signed (and ONLY self-signed): a CeraLive box is a headless appliance
# on a private LAN with no public DNS name and no inbound path for an ACME
# challenge. SC3 explicitly forbids ACME/Let's Encrypt and mTLS here, so we mint a
# per-device self-signed leaf. The honest consequence: the FIRST time an operator
# opens https://<device>.local the browser shows a "self-signed / not secure"
# warning; accepting it once reaches the UI over TLS. This is documented behaviour,
# not a bug — the alternative (a shared baked cert) would give every unit the same
# key, a far worse posture.
#
# SCOPE IS LOCKED to keeping one per-device key+cert aligned with the committed
# mDNS identity in a /data-backed path. The pair survives reboots and A/B OTA
# slot swaps; it is replaced only when the hostname changes or the pair is
# invalid. Nothing here touches nginx config, port 80, or cert-rotation/.
#
# shellcheck shell=bash

set -euo pipefail

log() {
    logger -t ceralive-tls-firstboot -- "$*" 2>/dev/null || true
    echo "ceralive-tls-firstboot: $*"
}

if [ -n "${CERALIVE_TLS_STATE_DIR:-}" ]; then
    STATE_DIR="${CERALIVE_TLS_STATE_DIR}"
elif mountpoint -q /data 2>/dev/null; then
    STATE_DIR="/data/ceralive/tls"
else
    STATE_DIR="/etc/ceralive/tls"
fi
CERT="${STATE_DIR}/ceralive.crt"
KEY="${STATE_DIR}/ceralive.key"
CERT_DAYS="${CERALIVE_TLS_CERT_DAYS:-3650}"
OPENSSL_BIN="${OPENSSL_BIN:-openssl}"
HOSTNAME_BIN="${HOSTNAME_BIN:-hostname}"
IP_BIN="${IP_BIN:-ip}"

command -v "${OPENSSL_BIN}" >/dev/null 2>&1 || { log "FATAL: openssl not found — cannot mint TLS cert"; exit 1; }
command -v "${HOSTNAME_BIN}" >/dev/null 2>&1 || { log "FATAL: hostname not found — cannot mint TLS cert"; exit 1; }

# Identity for the cert. CN + the primary SAN is the mDNS name the operator types
# (<hostname>.local); we also pin the bare hostname and, when known, the current
# IPv4 so reaching the box by raw address does not mismatch the cert name.
HOSTNAME_SHORT="$("${HOSTNAME_BIN}" 2>/dev/null)" \
    || { log "FATAL: cannot read committed hostname"; exit 1; }
[[ "${HOSTNAME_SHORT}" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] \
    || { log "FATAL: invalid committed hostname '${HOSTNAME_SHORT}'"; exit 1; }
FQDN="${HOSTNAME_SHORT}.local"

certificate_matches_identity() {
    local cert="$1" key="$2" cert_pub key_pub checkhost
    [ -s "$cert" ] && [ -s "$key" ] || return 1
    # `openssl x509 -checkhost` prints its verdict but exits 0 on a mismatch on most
    # OpenSSL releases, so parse the printed phrase instead of trusting the exit code
    # (else a stale cert survives a deterministic hostname advance). Fail closed.
    checkhost="$("${OPENSSL_BIN}" x509 -in "$cert" -noout -checkhost "$FQDN" 2>/dev/null)" || return 1
    case "$checkhost" in
        *"does match certificate"*) ;;
        *) return 1 ;;
    esac
    cert_pub="$("${OPENSSL_BIN}" x509 -in "$cert" -pubkey -noout \
        | "${OPENSSL_BIN}" pkey -pubin -outform DER \
        | "${OPENSSL_BIN}" dgst -sha256)" || return 1
    key_pub="$("${OPENSSL_BIN}" pkey -in "$key" -pubout -outform DER \
        | "${OPENSSL_BIN}" dgst -sha256)" || return 1
    [ -n "$cert_pub" ] && [ "$cert_pub" = "$key_pub" ]
}

if certificate_matches_identity "${CERT}" "${KEY}"; then
    log "TLS cert already present for ${FQDN} at ${CERT} — nothing to generate"
    exit 0
fi

# First global-scope IPv4 on a non-loopback link, if the device is on a network
# yet. Empty on a fresh offline box — the cert is still valid by .local name, and
# the IP SAN is simply omitted; it is a convenience SAN, not identity state.
DEVICE_IP="$("${IP_BIN}" -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"

SAN="DNS:${FQDN},DNS:${HOSTNAME_SHORT}"
if [ -n "${DEVICE_IP}" ]; then
    SAN="${SAN},IP:${DEVICE_IP}"
fi

log "minting per-device self-signed TLS cert (CN=${FQDN}, SAN=${SAN}, ${CERT_DAYS}d)"

mkdir -p "${STATE_DIR}"
chmod 0700 "${STATE_DIR}"

# Write to temp paths first, then move into place, so a crash mid-generation never
# leaves nginx a half-written key+cert pair to choke on.
tmp_key="$(mktemp "${STATE_DIR}/.ceralive.key.XXXXXX")"
tmp_crt="$(mktemp "${STATE_DIR}/.ceralive.crt.XXXXXX")"
# shellcheck disable=SC2317  # invoked indirectly by the EXIT trap below
cleanup() { rm -f "${tmp_key}" "${tmp_crt}"; }
trap cleanup EXIT

"${OPENSSL_BIN}" req -x509 -newkey rsa:2048 -nodes \
    -keyout "${tmp_key}" -out "${tmp_crt}" \
    -days "${CERT_DAYS}" \
    -subj "/CN=${FQDN}" \
    -addext "subjectAltName=${SAN}"

chmod 0600 "${tmp_key}"
chmod 0644 "${tmp_crt}"
certificate_matches_identity "${tmp_crt}" "${tmp_key}" \
    || { log "FATAL: generated TLS certificate does not match ${FQDN} and its private key"; exit 1; }
mv -f "${tmp_key}" "${KEY}"
mv -f "${tmp_crt}" "${CERT}"
trap - EXIT

log "TLS cert generated: ${CERT} (key ${KEY})"
exit 0
