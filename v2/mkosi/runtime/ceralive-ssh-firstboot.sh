#!/bin/bash
#
# ceralive-ssh-firstboot.sh — first-boot SSH hardening (Task 10, SC4).
#
# Committed standalone artifact (single source of truth under v2/mkosi/runtime/).
# Installed to /usr/local/sbin/ceralive-ssh-firstboot and run once per boot by
# ceralive-ssh-firstboot.service, ordered Before=ssh.service ssh.socket so sshd
# never accepts a connection before the hardening below is in place.
#
# SCOPE IS LOCKED to exactly four things (SC4 — nothing more, no fail2ban/UFW/
# auditd/key-only enforcement):
#   1. Per-device SSH host keys. The image BAKES shared host keys at build time
#      (etc/ssh/ssh_host_*), so every flashed unit would otherwise present an
#      IDENTICAL fingerprint — a MITM hazard. No systemd unit in the image
#      regenerates them, so we do it here, persisting the result so the device
#      keeps ONE stable, unique identity across reboots and A/B OTA slot swaps.
#   2. Root password login disabled (PermitRootLogin prohibit-password) via a
#      sshd_config.d drop-in. Key-based root is retained for recovery.
#   3. Default user (ceralive) forced to set a NEW password at first login
#      (chage -d 0), applied EXACTLY once via a first-boot flag.
#   4. Root and default-user authorized_keys stores live on /data so key access
#      survives A/B slot changes. The image contains no key; first boot creates
#      empty persistent files and links both slot-local home directories. CI keys
#      survive only an explicitly armed, one-use reboot; unarmed boots purge them
#      before sshd starts.
#
# Behaviour is documented for operators in v2/docs/ssh-hardening.md.
#
# shellcheck shell=bash

set -euo pipefail

log() {
    logger -t ceralive-ssh-firstboot -- "$*" 2>/dev/null || true
    echo "ceralive-ssh-firstboot: $*"
}

DEFAULT_USER="${CERALIVE_USER:-ceralive}"
SSH_DIR="/etc/ssh"
DROPIN_DIR="${SSH_DIR}/sshd_config.d"
HARDENING_DROPIN="${DROPIN_DIR}/99-ceralive-hardening.conf"

# Persistence root: prefer /data (survives reboots AND A/B OTA slot swaps) so the
# regenerated host identity is generated ONCE and then reused for the device's
# whole lifetime. Fall back to /etc/ceralive on an image with no /data partition.
if [ -n "${CERALIVE_SSH_STATE_DIR:-}" ]; then
    STATE_DIR="${CERALIVE_SSH_STATE_DIR}"
elif mountpoint -q /data 2>/dev/null; then
    STATE_DIR="/data/ceralive/ssh"
else
    STATE_DIR="/etc/ceralive"
fi
FLAG="${STATE_DIR}/ssh-firstboot.done"
KEYSTORE="${STATE_DIR}/host-keys"
AUTHORIZED_KEYS="${STATE_DIR}/authorized_keys"
ROOT_AUTHORIZED_KEYS="${STATE_DIR}/root_authorized_keys"
CI_ACCESS_DIR="${STATE_DIR}/ci-access"
DEBUG_IMAGE_MARKER="/etc/ceralive/debug-image"

# --- (2) Disable root password login -----------------------------------------
# Written every boot (deterministic content) so a freshly-activated OTA slot is
# always hardened, independent of the once-only first-boot flag further down.
write_hardening_dropin() {
    local tmp
    mkdir -p "${DROPIN_DIR}"
    tmp="$(mktemp "${DROPIN_DIR}/.99-ceralive-hardening.XXXXXX")"
    cat >"${tmp}" <<'CONF'
# CeraLive SSH hardening — managed by ceralive-ssh-firstboot.service.
# Root may NOT authenticate with a password; key-based root is retained for
# recovery. Add further drop-ins in /etc/ssh/sshd_config.d/ rather than editing
# this generated file (it is rewritten on every boot).
PermitRootLogin prohibit-password
CONF
    chmod 0644 "${tmp}"
    mv -f "${tmp}" "${HARDENING_DROPIN}"
}

# --- (1) Per-device host keys ------------------------------------------------
regenerate_host_keys() {
    log "regenerating per-device SSH host keys (image ships shared keys)"
    rm -f "${SSH_DIR}"/ssh_host_*
    ssh-keygen -A
}

persist_host_keys() {
    mkdir -p "${KEYSTORE}"
    chmod 0700 "${KEYSTORE}"
    cp -a "${SSH_DIR}"/ssh_host_* "${KEYSTORE}/"
}

ensure_host_keys() {
    # No persisted identity yet → device's first boot: regenerate + persist.
    if [ ! -e "${KEYSTORE}/ssh_host_ed25519_key" ]; then
        regenerate_host_keys
        persist_host_keys
        return
    fi
    # A persisted identity exists. If this slot's keys differ from it (a fresh
    # OTA slot still carrying the baked shared keys), restore the device's real
    # identity so the fingerprint stays stable across updates.
    if ! cmp -s "${KEYSTORE}/ssh_host_ed25519_key" "${SSH_DIR}/ssh_host_ed25519_key" 2>/dev/null; then
        log "restoring persisted per-device host keys onto this slot"
        cp -a "${KEYSTORE}"/ssh_host_* "${SSH_DIR}/"
    fi
}

ensure_authorized_keys() {
    local user="$1" store="$2" home ssh_dir
    home="$(getent passwd "${user}" | cut -d: -f6)"
    [ -n "${home}" ] || {
        log "authorized-key user '${user}' has no home directory"
        return 1
    }
    ssh_dir="${home}/.ssh"

    install -d -m 0755 "${STATE_DIR}"
    install -d -m 0700 -o "${user}" -g "${user}" "${ssh_dir}"
    touch "${store}"
    chown "${user}:${user}" "${store}"
    chmod 0600 "${store}"
    ln -sfn "${store}" "${ssh_dir}/authorized_keys"
    chown -h "${user}:${user}" "${ssh_dir}/authorized_keys"
}

guard_ci_access() {
    local marker access_id retain tmp retained_ids="|"
    [ -f "${ROOT_AUTHORIZED_KEYS}" ] && [ ! -L "${ROOT_AUTHORIZED_KEYS}" ] || return 1

    shopt -s nullglob
    for marker in "${CI_ACCESS_DIR}"/*; do
        case "${marker}" in *.retain-once) continue ;; esac
        access_id="$(basename -- "${marker}")"
        [[ "${access_id}" =~ ^[A-Za-z0-9._-]{1,80}$ ]] || return 1
        retain="${marker}.retain-once"
        if [ -f "${retain}" ] && [ ! -L "${retain}" ] && \
           [ "$(tr -d '[:space:]' <"${retain}")" = "access_id=${access_id}" ]; then
            rm -f -- "${retain}"
            retained_ids="${retained_ids}${access_id}|"
            continue
        fi
        rm -f -- "${marker}" "${retain}"
    done
    for retain in "${CI_ACCESS_DIR}"/*.retain-once; do
        rm -f -- "${retain}"
    done
    tmp="$(mktemp "${STATE_DIR}/.root_authorized_keys.XXXXXX")"
    awk -v retained="${retained_ids}" '
        / ceralive-ci-[A-Za-z0-9._-]+$/ {
            access_id = $0
            sub(/^.* ceralive-ci-/, "", access_id)
            if (index(retained, "|" access_id "|") != 0) print
            next
        }
        { print }
    ' "${ROOT_AUTHORIZED_KEYS}" >"${tmp}"
    chmod --reference="${ROOT_AUTHORIZED_KEYS}" "${tmp}"
    chown --reference="${ROOT_AUTHORIZED_KEYS}" "${tmp}"
    mv -f -- "${tmp}" "${ROOT_AUTHORIZED_KEYS}"
    shopt -u nullglob
}

if [ "${CERALIVE_SSH_GUARD_ONLY:-0}" = 1 ]; then
    guard_ci_access
    exit 0
fi

write_hardening_dropin
ensure_host_keys
ensure_authorized_keys "${DEFAULT_USER}" "${AUTHORIZED_KEYS}"
ensure_authorized_keys root "${ROOT_AUTHORIZED_KEYS}"
guard_ci_access

# --- (3) Force default-user password change at first login -------------------
# Applied EXACTLY once (flag-guarded); a clean no-op on every subsequent boot.
if [ -e "${DEBUG_IMAGE_MARKER}" ]; then
    log "lab debug image detected; retaining the injected '${DEFAULT_USER}' password"
elif [ ! -e "${FLAG}" ]; then
    if id -u "${DEFAULT_USER}" >/dev/null 2>&1; then
        log "expiring '${DEFAULT_USER}' password → forced change at first login"
        chage -d 0 "${DEFAULT_USER}"
    else
        log "default user '${DEFAULT_USER}' absent — skipping forced password change"
    fi
    mkdir -p "${STATE_DIR}"
    : >"${FLAG}"
fi

# Validate the resulting sshd config so a bad drop-in can never wedge sshd's
# ExecStartPre (`sshd -t`) on the very first connection.
if command -v sshd >/dev/null 2>&1; then
    sshd -t
fi

log "first-boot SSH hardening complete"
exit 0
