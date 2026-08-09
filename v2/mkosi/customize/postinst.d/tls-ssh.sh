#!/usr/bin/env bash
#
# postinst.d/tls-ssh.sh — who can reach this device, and over what.
#
# Sourced by customize/postinst-lib.sh (never executed). Concern: the device's
# credentials and its authenticated/encrypted entry points —
#
#   * configure_debug_access     the bench-only password unlock (CERALIVE_DEBUG_IMAGE)
#   * configure_ssh_enablement   whether ssh.service ships enabled at all
#   * setup_ssh_firstboot        first-boot host-key regeneration + hardening, and
#                                the opt-in one-shot UART CI bootstrap
#   * setup_tls_proxy            the nginx 443 front and its per-device self-signed cert
#   * setup_cert_rotation        the intermediate/leaf rotation channel (root immutable)
#   * setup_paseto_public_key    the device-token verification key CeraUI reads
#
# Everything here is a reachability or trust decision, so the two production
# defaults that are easy to get backwards live side by side on purpose: SSH ships
# DISABLED unless this is a debug image, and the PASETO material baked in is the
# PUBLIC key only — a private key here would let a compromised device forge its
# own tokens, so the build fails closed if any private material appears.
#
# CHROOT-SAFE STANDALONE: like every module under postinst.d/, this file carries
# its own declare -F-guarded log()/die() fallbacks. The modules are sourced
# inside mkosi SUBIMAGE CHROOTS where the repo's lib/ is NOT mounted, so a module
# must never assume that anything else has already been sourced.
#
# shellcheck shell=bash

if ! declare -F log >/dev/null 2>&1; then
  log() { printf '[runtime-lib] %s\n' "$*" >&2; }
fi
if ! declare -F die >/dev/null 2>&1; then
  die() { log "FATAL: $*"; exit 1; }
fi

configure_debug_access() {
  local user="${CERALIVE_USER:-ceralive}"
  local mode="${CERALIVE_DEBUG_IMAGE:-0}"
  local hash="${CERALIVE_DEBUG_PASSWORD_HASH:-}"

  case "${mode}" in
    0|1) ;;
    *) die "CERALIVE_DEBUG_IMAGE must be 0 or 1" ;;
  esac
  if [[ -n "${hash}" && "${mode}" != "1" ]]; then
    die "CERALIVE_DEBUG_PASSWORD_HASH requires CERALIVE_DEBUG_IMAGE=1"
  fi
  [[ "${mode}" == "1" ]] || return 0
  [[ -n "${hash}" ]] || die "CERALIVE_DEBUG_IMAGE=1 requires CERALIVE_DEBUG_PASSWORD_HASH"
  [[ "${hash}" == '$'* ]] || die "CERALIVE_DEBUG_PASSWORD_HASH must be an encrypted password hash"
  id -u "${user}" >/dev/null || die "lab debug user '${user}' is absent"

  usermod --password "${hash}" "${user}"
  chage -d -1 "${user}"
  install -Dm 0600 /dev/null /etc/ceralive/debug-image
  log "lab debug image: password access enabled for '${user}'"
}

# SSH enablement gated on CERALIVE_DEBUG_IMAGE (Todo 42). The base layer installs
# openssh-server, whose Debian postinst preset ALREADY enables ssh.service — so a
# production image must actively DISABLE it, not merely skip the enable, to truly
# ship disabled-by-default. Debug (=1) keeps the historical enabled-by-default plus
# the predefined debug password (configure_debug_access). CERALIVE_DEBUG_IMAGE is
# validated 0/1 upstream (orchestrate.sh + configure_debug_access), so no re-check.
configure_ssh_enablement() {
  local mode="${CERALIVE_DEBUG_IMAGE:-0}"
  if [[ "${mode}" == "1" ]]; then
    enable_service ssh
    log "lab debug image: ssh.service enabled by default"
  else
    disable_service ssh.service
    disable_service ssh.socket
    log "production image: ssh.service NOT enabled (operator enables via CeraUI)"
  fi
}

# ---------------------------------------------------------------------------
# First-boot SSH hardening (task 10, SC4): install the COMMITTED standalone
# artifacts ceralive-ssh-firstboot.{sh,service} and the opt-in, one-shot UART
# bootstrap (single source of truth under
# v2/mkosi/runtime/) instead of inlining them in the runtime postinst — keeps
# postinst.chroot under the 950-line drift ceiling. Mirrors setup_boot_healthcheck.
# Scope is LOCKED to host-key regeneration, PermitRootLogin prohibit-password,
# once-only `chage -d 0 ceralive`, persistent authorized-key stores, and the
# boot-scoped UART CI key guard; see the script header. CERALIVE_RUNTIME_SRC must
# point at the runtime/ source dir.
# ---------------------------------------------------------------------------
setup_ssh_firstboot() {
  log "installing first-boot SSH hardening and one-shot UART CI bootstrap"
  local src="${CERALIVE_RUNTIME_SRC:-}"
  [[ -n "${src}" && -f "${src}/ceralive-ssh-firstboot.sh" ]] \
    || die "ssh-firstboot source not found: ${src}/ceralive-ssh-firstboot.sh (is \$SRCDIR/runtime mounted?)"
  [[ -f "${src}/ceralive-ci-uart-bootstrap.sh" && -f "${src}/ceralive-ci-uart-bootstrap.service" && \
     -f "${src}/ceralive-ci-uart-bootstrap-public.pem" ]] \
    || die "UART bootstrap source not found under ${src}"
  mkdir -p /usr/local/sbin
  install -m 0755 "${src}/ceralive-ssh-firstboot.sh" /usr/local/sbin/ceralive-ssh-firstboot
  install -m 0644 "${src}/ceralive-ssh-firstboot.service" /etc/systemd/system/ceralive-ssh-firstboot.service
  install -m 0755 "${src}/ceralive-ci-uart-bootstrap.sh" /usr/local/sbin/ceralive-ci-uart-bootstrap
  install -m 0644 "${src}/ceralive-ci-uart-bootstrap.service" /etc/systemd/system/ceralive-ci-uart-bootstrap.service
  [[ "${CERALIVE_IMAGE_BUILD_COMMIT:-}" =~ ^[0-9a-f]{40}$ ]] \
    || die "CERALIVE_IMAGE_BUILD_COMMIT is not an exact commit SHA"
  install -d -m 0755 /etc/ceralive
  install -m 0444 "${src}/ceralive-ci-uart-bootstrap-public.pem" /etc/ceralive/uart-bootstrap-public.pem
  printf '%s\n' "${CERALIVE_IMAGE_BUILD_COMMIT}" >/etc/ceralive/image-build-commit
  chmod 0444 /etc/ceralive/image-build-commit
  enable_service ceralive-ssh-firstboot.service
  enable_service ceralive-ci-uart-bootstrap.service
}

# ---------------------------------------------------------------------------
# CeraUI TLS front (task 15, SC3): nginx terminates HTTPS on 443 and proxies to
# the CeraUI backend on 127.0.0.1:80 (WebSocket-upgrade aware, EC6). Port 80 is
# LEFT to the backend — nginx must NOT bind it and there is NO 80->443 redirect.
# Installs the COMMITTED canonical artifacts under v2/mkosi/runtime/ (single source
# of truth, no inline twin — Task 6 pattern), mirroring setup_ssh_firstboot. The
# cert is per-device self-signed, generated on first boot into /data by
# ceralive-tls-firstboot.service; nginx is ordered AFTER it via a drop-in.
# CERALIVE_RUNTIME_SRC must point at the runtime/ source dir.
# ---------------------------------------------------------------------------
setup_tls_proxy() {
  log "installing CeraUI TLS front (nginx 443 -> 127.0.0.1:80 + first-boot self-signed cert)"
  local src="${CERALIVE_RUNTIME_SRC:-}"
  [[ -n "${src}" && -f "${src}/ceralive-tls-firstboot.sh" ]] \
    || die "tls-proxy source not found: ${src}/ceralive-tls-firstboot.sh (is \$SRCDIR/runtime mounted?)"

  # (1) First-boot cert generator + its oneshot unit.
  mkdir -p /usr/local/sbin
  install -m 0755 "${src}/ceralive-tls-firstboot.sh" /usr/local/sbin/ceralive-tls-firstboot
  install -m 0644 "${src}/ceralive-tls-firstboot.service" /etc/systemd/system/ceralive-tls-firstboot.service

  # (2) nginx 443 TLS site. Symlink (not copy) sites-available -> sites-enabled so
  # the layout matches Debian's nginx convention exactly.
  mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
  install -m 0644 "${src}/ceralive-tls.nginx.conf" /etc/nginx/sites-available/ceralive-tls.conf
  ln -sf ../sites-available/ceralive-tls.conf /etc/nginx/sites-enabled/ceralive-tls.conf

  # (3) SC3: nginx binds 443 ONLY. The stock nginx-light ships a default site that
  # listens on :80 — remove it so nginx never competes with the backend for port 80.
  rm -f /etc/nginx/sites-enabled/default

  # (4) Order nginx AFTER first-boot cert generation (hard dependency drop-in).
  mkdir -p /etc/systemd/system/nginx.service.d
  install -m 0644 "${src}/ceralive-tls-nginx.dropin.conf" /etc/systemd/system/nginx.service.d/10-ceralive-tls.conf

  enable_service ceralive-tls-firstboot.service
  enable_service nginx.service
}

# ---------------------------------------------------------------------------
# PASETO device-token verification key (ADR-0006 D2): bake the PUBLIC Ed25519
# key into the CeraUI backend runtime env so the device can VERIFY device-control
# / relay-config tokens. CeraUI reads it from the PASETO_PUBLIC_KEY env var
# (apps/backend device-token.ts DEVICE_TOKEN_PUBLIC_KEY_ENV); its PRESENCE gates
# real verification — absent → CeraUI runs the MVP opaque-token path, so a
# key-less dev/local build still boots. The value arrives base64-wrapped in
# $PASETO_PUBLIC_KEY_B64 (orchestrator-forwarded), exactly like $ADDON_KEYRING_B64;
# the decoded payload is the raw-32-byte Ed25519 PUBLIC key in standard base64
# (cert-work/paseto/gen-keys.sh -> paseto.public.raw.b64), the form CeraUI's
# importEd25519PublicKey() consumes. It is written as an ADDITIVE drop-in on the
# ceralive.service unit shipped by the CeraUI .deb (like 10-data-persistence).
# PUBLIC ONLY — a k4.secret / PEM private key here would let a compromised device
# FORGE tokens, so the build FAILS if any private material slipped in.
# PASETO_DROPIN_DIR overrides the drop-in directory for the offline unit test.
# ---------------------------------------------------------------------------
setup_paseto_public_key() {
  local dropin_dir="${PASETO_DROPIN_DIR:-/etc/systemd/system/ceralive.service.d}"
  local dropin="${dropin_dir}/20-paseto-public-key.conf"

  if [[ -z "${PASETO_PUBLIC_KEY_B64:-}" ]]; then
    log "no PASETO public key in env — skipping device-token key provisioning (CeraUI runs the MVP opaque-token path until a key is baked in)"
    return 0
  fi

  local key
  key="$(printf '%s' "${PASETO_PUBLIC_KEY_B64}" | base64 -d | tr -d '\r\n')"
  [[ -n "${key}" ]] || die "PASETO_PUBLIC_KEY_B64 decoded to empty — refusing to bake an unusable key"

  case "${key}" in
    *k4.secret*) die "PASETO_PUBLIC_KEY_B64 carries a k4.secret PRIVATE key — provision the PUBLIC key (k4.public / raw-base64) only" ;;
  esac
  if printf '%s' "${key}" | grep -aq 'PRIVATE KEY'; then
    die "PASETO_PUBLIC_KEY_B64 carries PEM PRIVATE KEY material — provision the PUBLIC key only"
  fi

  log "provisioning PASETO_PUBLIC_KEY into the CeraUI backend runtime env (device-token verification, public key)"
  mkdir -p "${dropin_dir}"
  cat >"${dropin}" <<EOF
[Service]
Environment=PASETO_PUBLIC_KEY=${key}
EOF
  chmod 0644 "${dropin}"
}

# ---------------------------------------------------------------------------
# Cert rotation (task 42): install the COMMITTED canonical artifacts (single
# source of truth) instead of re-embedding stripped heredoc twins. Mirrors
# customize/services.sh::install_cert_rotation. The channel carries intermediate
# and leaf certificates only — the root stays immutable. CERALIVE_RUNTIME_SRC
# must point at the runtime/ source dir (postinst: "${SRCDIR}/runtime";
# customize: "${SERVICES_DIR}/../runtime").
# ---------------------------------------------------------------------------
setup_cert_rotation() {
  log "installing cert rotation (intermediate/leaf through-channel; root immutable)"
  local src="${CERALIVE_RUNTIME_SRC:-}/cert-rotation"
  [[ -n "${CERALIVE_RUNTIME_SRC:-}" && -f "${src}/cert-rotation.sh" ]] \
    || die "cert-rotation source not found: ${src}/cert-rotation.sh (is \$SRCDIR/runtime mounted?)"
  mkdir -p /usr/local/bin /etc/ceralive
  install -m 0755 "${src}/cert-rotation.sh" /usr/local/bin/cert-rotation.sh
  install -m 0644 "${src}/cert-rotation.conf" /etc/ceralive/cert-rotation.conf
  install -m 0644 "${src}/cert-rotation.service" /etc/systemd/system/cert-rotation.service
  install -m 0644 "${src}/cert-rotation-expiry.service" /etc/systemd/system/cert-rotation-expiry.service
  install -m 0644 "${src}/cert-rotation-expiry.timer" /etc/systemd/system/cert-rotation-expiry.timer
  enable_service cert-rotation.service
  enable_service cert-rotation-expiry.timer
}
