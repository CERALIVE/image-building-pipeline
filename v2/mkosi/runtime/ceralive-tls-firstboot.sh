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
# SCOPE IS LOCKED to exactly one thing: generate ONE per-device key+cert, ONCE,
# into a /data-backed path so it survives reboots AND A/B OTA slot swaps (/data is
# shared across slots). Idempotent: a present cert short-circuits the script, so
# re-runs and every subsequent boot are clean no-ops. Nothing here touches nginx
# config, port 80, or the rotation channel (cert-rotation/, a separate domain).
#
# shellcheck shell=bash

set -euo pipefail

log() {
    logger -t ceralive-tls-firstboot -- "$*" 2>/dev/null || true
    echo "ceralive-tls-firstboot: $*"
}

# Persistence root: prefer /data (survives reboots + A/B OTA slot swaps) so the
# device keeps ONE stable TLS identity for its whole lifetime. Fall back to
# /etc/ceralive/tls on an image with no /data partition (mountpoint-guarded, same
# convention as ceralive-ssh-firstboot.sh).
if mountpoint -q /data 2>/dev/null; then
    STATE_DIR="/data/ceralive/tls"
else
    STATE_DIR="/etc/ceralive/tls"
fi
CERT="${STATE_DIR}/ceralive.crt"
KEY="${STATE_DIR}/ceralive.key"
CERT_DAYS="${CERALIVE_TLS_CERT_DAYS:-3650}"

# Idempotency: a present key+cert means this device already has its identity —
# nothing to do (a re-run, a later boot, or a fresh OTA slot reading shared /data).
if [ -s "${CERT}" ] && [ -s "${KEY}" ]; then
    log "TLS cert already present at ${CERT} — nothing to generate"
    exit 0
fi

command -v openssl >/dev/null 2>&1 || { log "FATAL: openssl not found — cannot mint TLS cert"; exit 1; }

# Identity for the cert. CN + the primary SAN is the mDNS name the operator types
# (<hostname>.local); we also pin the bare hostname and, when known, the current
# IPv4 so reaching the box by raw address does not mismatch the cert name.
HOSTNAME_SHORT="$(hostname 2>/dev/null || echo ceralive)"
[ -n "${HOSTNAME_SHORT}" ] || HOSTNAME_SHORT="ceralive"
FQDN="${HOSTNAME_SHORT}.local"

# First global-scope IPv4 on a non-loopback link, if the device is on a network
# yet. Empty on a fresh offline box — the cert is still valid by .local name, and
# the IP SAN is simply omitted (regenerated identities are not re-minted later, so
# this is a best-effort convenience SAN, not a correctness requirement).
DEVICE_IP="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"

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

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "${tmp_key}" -out "${tmp_crt}" \
    -days "${CERT_DAYS}" \
    -subj "/CN=${FQDN}" \
    -addext "subjectAltName=${SAN}"

chmod 0600 "${tmp_key}"
chmod 0644 "${tmp_crt}"
mv -f "${tmp_key}" "${KEY}"
mv -f "${tmp_crt}" "${CERT}"
trap - EXIT

log "TLS cert generated: ${CERT} (key ${KEY})"
exit 0
