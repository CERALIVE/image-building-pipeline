#!/usr/bin/env bash
#
# customize/postinst-lib.sh — SINGLE SOURCE OF TRUTH for the runtime customization
# logic that used to be duplicated ("dual-track") between the wired runtime
# executor mkosi.images/runtime/mkosi.postinst.chroot and the decomposed
# customize/*.sh modules (see Task 6).
#
# This file is the ENTRY POINT ONLY: the chroot-safe fallback helpers plus the
# explicit list of per-concern modules under customize/postinst.d/ that carry the
# implementation. Sourcing it yields the COMPLETE API in one `source`; callers
# never reach into postinst.d/ themselves.
#
# It is SOURCED (never executed) by:
#   * mkosi.images/runtime/mkosi.postinst.chroot — via "${SRCDIR}/customize/
#     postinst-lib.sh" (mkosi mounts $SRCDIR=v2/mkosi inside the .chroot postinst),
#   * customize/services.sh and customize/data-persistence.sh — via their own dir,
#     so the canonical decomposed modules and the wired postinst share ONE copy.
#
# SELF-CONTAINED: it does NOT hard-depend on lib/common.sh (the runtime postinst
# is standalone and runs in a chroot where the repo tree's lib/ is not mounted).
# It provides FALLBACK log()/die() only when the caller has not already defined
# them, so callers that DO source common.sh (the customize modules) keep their
# own structured loggers, and the standalone postinst keeps its own log().
#
# Payload scripts/units for the boot healthcheck (task 29) and cert rotation
# (task 42) are NOT re-embedded here as heredocs — they are INSTALLED from the
# committed canonical artifacts under "${CERALIVE_RUNTIME_SRC}" (the runtime/
# source dir), exactly as customize/services.sh does. Callers MUST export
# CERALIVE_RUNTIME_SRC before calling setup_boot_healthcheck / setup_cert_rotation.
#
# shellcheck shell=bash

# --- Fallback helpers (defined only if the caller has not) -------------------
if ! declare -F log >/dev/null 2>&1; then
  log() { printf '[runtime-lib] %s\n' "$*" >&2; }
fi
if ! declare -F die >/dev/null 2>&1; then
  die() { log "FATAL: $*"; exit 1; }
fi
# Same fallback contract as log()/die() above: callers that already sourced
# lib/common.sh keep its copy, the standalone chroot postinst gets this one.
# CERALIVE_BENCH_LABELS=1 is the opt-in bench overlay (xboot/xrootfs_a/xrootfs_b/
# xdata) that keeps a bench microSD's PARTLABELs off the production set on the
# eMMC it boots beside; it reaches this chroot via mkosi.conf PassEnvironment=.
if ! declare -F partlabel_prefix >/dev/null 2>&1; then
  partlabel_prefix() {
    [[ "${CERALIVE_BENCH_LABELS:-0}" == "1" ]] && printf 'x'
    return 0
  }
fi
if ! declare -F resolve_partlabel >/dev/null 2>&1; then
  resolve_partlabel() {
    printf '%s%s' "$(partlabel_prefix)" "${1:?resolve_partlabel needs a partition role}"
  }
fi

# --- Concern modules ---------------------------------------------------------
# The implementation lives in per-concern modules under customize/postinst.d/.
# Sourcing this file is unchanged for every caller: it still defines the whole
# API in one `source`, and postinst-drift-check.sh still requires each
# consolidated function to be defined EXACTLY ONCE across the entry + modules.
#
# The list is EXPLICIT and ordered, never a glob: a module that is renamed, lost
# from the mkosi source mount, or added under postinst.d/ but never wired up must
# fail HERE and loudly, not later with `command not found` halfway through a
# postinst that has already half-configured the image. Load order does not affect
# correctness — modules only DEFINE functions; nothing calls across at source time.
CERALIVE_POSTINST_D="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/postinst.d"
CERALIVE_POSTINST_MODULES=(
  hardware.sh
  hostname.sh
  networking.sh
  persistence.sh
)

for _ceralive_postinst_module in "${CERALIVE_POSTINST_MODULES[@]}"; do
  [[ -f "${CERALIVE_POSTINST_D}/${_ceralive_postinst_module}" ]] \
    || die "postinst module missing: ${CERALIVE_POSTINST_D}/${_ceralive_postinst_module} (is \$SRCDIR/customize mounted?)"
  # shellcheck source=/dev/null
  source "${CERALIVE_POSTINST_D}/${_ceralive_postinst_module}"
done
unset _ceralive_postinst_module

# Idempotent group creation (replaces v1's `|| true`).
ensure_group() {
  local grp="$1"
  getent group "${grp}" >/dev/null || groupadd --system "${grp}"
}

enable_service() {
  # A service we EXPECT must be enableable; a missing unit is a parity failure.
  local svc="$1"
  systemctl enable "${svc}"
}

disable_service() {
  # Disabling a not-installed unit is a legitimate no-op (the package was never
  # added to this minimal image) — skip cleanly when the unit file is absent.
  local svc="$1"
  if systemctl list-unit-files "${svc}" >/dev/null 2>&1 \
     && systemctl list-unit-files "${svc}" | grep -q "${svc}"; then
    systemctl disable "${svc}"
  else
    log "service ${svc} not present — nothing to disable"
  fi
}

# mask_service — for units a build-time `disable` CANNOT durably suppress.
#
# `systemctl mask` writes /etc/systemd/system/<unit> -> /dev/null, which outranks
# every [Install] section and every vendor preset, because `systemctl enable`
# REFUSES to act on a masked unit. That matters here specifically: this image
# ships /etc/machine-id holding the literal string `uninitialized`, so EVERY
# freshly flashed board is a systemd FIRST BOOT and PID 1 runs `preset-all` —
# which re-applies the vendor presets to units this build already disabled. A
# `disable_service` is therefore silently undone the first time the device boots;
# only a mask survives. See suppress_unusable_boot_units for the concrete cases.
#
# The resulting symlink is VERIFIED rather than assumed: a mask that quietly did
# not land would put the defect straight back into the fleet on an image that
# otherwise builds, boots and passes every other gate. Fail the build instead.
# CERALIVE_MASK_UNIT_DIR overrides the mask directory for the offline unit test.
mask_service() {
  local svc="$1"
  local unit_dir="${CERALIVE_MASK_UNIT_DIR:-/etc/systemd/system}"
  systemctl mask "${svc}"
  [[ -L "${unit_dir}/${svc}" && "$(readlink "${unit_dir}/${svc}")" == "/dev/null" ]] \
    || die "mask did not land: ${unit_dir}/${svc} is not a symlink to /dev/null"
}

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

# --- 8c. NTP configuration (chrony pools) --------------------------------
configure_ntp() {
  log "configuring NTP (chrony pools)"
  mkdir -p /etc/chrony/conf.d
  # Install the ceralive-ntp.conf drop-in with explicit public NTP pools.
  # This file is staged into the image at build time by the customize layer.
  if [[ -f "${CERALIVE_CUSTOMIZE_SRC:-}/ceralive-ntp.conf" ]]; then
    cp "${CERALIVE_CUSTOMIZE_SRC}/ceralive-ntp.conf" /etc/chrony/conf.d/ceralive-ntp.conf
  else
    # Fallback: inline the config if the file is not available (e.g., in the
    # standalone postinst context where the customize dir is not mounted).
    cat >/etc/chrony/conf.d/ceralive-ntp.conf <<'EOF'
pool pool.ntp.org iburst
pool ntp.ubuntu.com iburst
makestep 1 3
EOF
  fi
}

install_console_font_service() {
  local src="${CERALIVE_RUNTIME_SRC:-}"
  [[ -n "${src}" && -f "${src}/ceralive-console-font.service" ]] \
    || die "console font service source not found: ${src}/ceralive-console-font.service (is \$SRCDIR/runtime mounted?)"

  install -m 0644 "${src}/ceralive-console-font.service" /etc/systemd/system/ceralive-console-font.service
}

# --- 9. Services enable/disable (verbatim from postinst section 9) --------
configure_services() {
  log "enabling/disabling services"
  configure_debug_access
  configure_ntp  # install NTP pools before enabling chrony
  install_console_font_service
  local svc
  for svc in systemd-resolved NetworkManager ModemManager chrony avahi-daemon ceralive-console-font; do
    enable_service "${svc}"
  done
  configure_ssh_enablement
  for svc in bluetooth.service cups.service; do
    disable_service "${svc}"
  done
  suppress_unusable_boot_units
  setup_typec_source_role
  setup_fan_curve
  setup_fan_kickstart
  setup_led_status
}

# Six stock Debian/systemd units that this image either can NEVER satisfy or must
# not be gated on. Together they cost a shipped Rock 5B+ ~2 minutes of every boot
# and left two units permanently `failed`, so `systemctl is-system-running` read
# `degraded` forever — which hides genuinely new failures from an operator.
#
# 1-3. THE NETWORKD STACK (systemd-networkd.service/.socket/-wait-online.service).
# NetworkManager is this image's ONLY network stack. No `.network` file ships, so
# systemd-networkd manages ZERO links — `networkctl list` reports lo/eth0/wlan0 all
# `unmanaged` while `nmcli device status` shows eth0 `connected`. But
# systemd-networkd-wait-online is still pulled into network-online.target, where it
# can never be satisfied: on the board it burned its full hardcoded 120s default and
# exited 1 with the network completely up. Because a target only becomes active once
# EVERY ordering dependency reaches a terminal state — failure counts — that timeout
# held network-online.target to 2min 1.362s even though NetworkManager-wait-online
# had already SUCCEEDED at 19.3s. Everything behind the target inherited the delay,
# including ceralive-hostname.service and therefore ceralive.service: the operator
# could not reach the CeraUI web UI on port 80 AT ALL for two minutes after power-on.
#
# Masking systemd-networkd.service itself (not just wait-online) is deliberate and is
# what closes the resurrection path: its [Install] carries
# `Also=systemd-networkd-wait-online.service`, and `Also=` is applied UNCONDITIONALLY
# by `enable` — which is why Debian's own `90-systemd.preset` losing battle
# (`enable systemd-networkd.service` two lines above
# `disable systemd-networkd-wait-online.service`) ships wait-online ENABLED anyway.
#
# CRITICALLY, this does NOT touch interface naming. The `.link` files
# install_interface_naming writes are consumed by udev's BUILT-IN `net_setup_link`,
# which lives in systemd-udevd and is a completely separate mechanism from whether
# the networkd DAEMON runs. eth0/wlan0 renaming — and therefore SRTLA's `eth*`/`wlan*`
# bonding globs — are unaffected. Do NOT widen this to NetworkManager or systemd-udevd.
#
# 4. systemd-machine-id-commit.service exists solely to persist a machine-id that an
# initrd generated on a TMPFS. This image never does that — but the unit is not inert
# either, because its `ConditionPathIsMountPoint=/etc/machine-id` is SATISFIED by our
# own `ceralive-migrate-data`, which bind-mounts /data/ceralive/machine-id onto
# /etc/machine-id to keep host identity stable across A/B slots. The condition passes,
# `systemd-machine-id-setup --commit` runs, and it fails with
# `/etc/machine-id is not on a temporary file system` because the bind source is real
# ext4 on /data. It is structurally guaranteed to fail on every boot, forever.
#
# 5. dnsmasq.service is the STANDALONE Debian unit, enabled by package preset and
# never wired up by this repo. It always fails `failed to create listening socket for
# port 53: Address already in use`, because systemd-resolved owns port 53 by design
# (the /etc/resolv.conf stub-symlink architecture). This is NOT NetworkManager's
# hotspot dnsmasq: NM spawns its own dnsmasq CHILD PROCESS for `ipv4.method shared`
# AP mode, reading /etc/NetworkManager/dnsmasq-shared.d — it never starts this unit,
# and the `dnsmasq` package stays installed so that child still has its binary.
#
# 6. chrony-wait.service blocks multi-user.target for ~21s running
# `chronyc waitsync 0 0.1 0.0 1` — it waits for NTP to converge to within 0.1s. It is
# the second-largest single unit in `systemd-analyze blame` and becomes the tallest
# remaining pole once the networkd stall above is gone. Nothing on this device orders
# itself after `time-sync.target` or `chrony-wait.service` — not
# ceralive-tls-firstboot.service (which generates the per-device self-signed cert),
# not ceralive-healthcheck.service, not RAUC, not nginx, not ceralive.service. The
# apparent "cert is generated after the clock synced" safety today is an ACCIDENT of
# the very 2-minute networkd stall being removed here, not a contract: there is no
# ordering edge between the two units, so masking removes no guarantee that ever
# existed. chronyd itself is untouched and still steps the clock (`makestep 1 3`);
# only the boot-readiness GATE goes away. Never mask chrony.service.
suppress_unusable_boot_units() {
  log "masking the stock units this image can never satisfy (networkd stack, machine-id commit, standalone dnsmasq) plus chrony-wait (clock sync must not gate boot readiness)"
  local svc
  for svc in \
    systemd-networkd.service \
    systemd-networkd.socket \
    systemd-networkd-wait-online.service \
    systemd-machine-id-commit.service \
    dnsmasq.service \
    chrony-wait.service
  do
    mask_service "${svc}"
  done
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
# Boot healthcheck (task 29) + cert rotation (task 42): install the COMMITTED
# canonical artifacts (single source of truth) instead of re-embedding stripped
# heredoc twins. Mirrors customize/services.sh::install_healthcheck_service /
# install_cert_rotation. CERALIVE_RUNTIME_SRC must point at the runtime/ source
# dir (postinst: "${SRCDIR}/runtime"; customize: "${SERVICES_DIR}/../runtime").
# ---------------------------------------------------------------------------
setup_boot_healthcheck() {
  log "installing boot healthcheck (ceralive-healthcheck.service — gates rauc mark-good)"
  local src="${CERALIVE_RUNTIME_SRC:-}"
  [[ -n "${src}" && -f "${src}/ceralive-healthcheck.sh" ]] \
    || die "boot healthcheck source not found: ${src}/ceralive-healthcheck.sh (is \$SRCDIR/runtime mounted?)"
  mkdir -p /usr/local/bin
  install -m 0755 "${src}/ceralive-healthcheck.sh" /usr/local/bin/ceralive-healthcheck.sh
  install -m 0644 "${src}/ceralive-healthcheck.service" /etc/systemd/system/ceralive-healthcheck.service
  enable_service ceralive-healthcheck.service
}

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
# avahi-daemon restart hardening (defense-in-depth mDNS reliability): stock Debian's
# avahi-daemon.service ships NO Restart= directive, so ANY signal or crash leaves
# avahi-daemon — and therefore <hostname>.local mDNS — permanently dead until the
# next reboot. Confirmed live on real hardware: the daemon was killed by SIGUSR2
# (status=12/USR2 -> result 'signal'), with NRestarts=0 (no restart policy active).
# Operators reach the device by <hostname>.local (docs/FIRST-BOOT.md + the
# deterministic first-boot unique-hostname service), so bake an ADDITIVE drop-in
# that makes systemd auto-restart the daemon after any non-clean exit. The signal
# SOURCE (a CeraUI udev rule's overly-broad pkill) is fixed separately in the CeraUI
# repo (root cause); this is the systemd-level defense-in-depth against ANY future
# cause. Installed from the committed standalone artifact under CERALIVE_RUNTIME_SRC
# (like setup_tls_proxy's nginx drop-in), never inlined here.
# AVAHI_DROPIN_DIR overrides the drop-in directory for the offline unit test.
# ---------------------------------------------------------------------------
setup_avahi_restart() {
  log "hardening avahi-daemon restart policy (additive Restart=on-failure drop-in for mDNS reliability)"
  local src="${CERALIVE_RUNTIME_SRC:-}"
  [[ -n "${src}" && -f "${src}/avahi-daemon-restart.dropin.conf" ]] \
    || die "avahi-restart source not found: ${src}/avahi-daemon-restart.dropin.conf (is \$SRCDIR/runtime mounted?)"
  local dropin_dir="${AVAHI_DROPIN_DIR:-/etc/systemd/system/avahi-daemon.service.d}"
  mkdir -p "${dropin_dir}"
  install -m 0644 "${src}/avahi-daemon-restart.dropin.conf" "${dropin_dir}/10-ceralive-restart.conf"
}

# ---------------------------------------------------------------------------
# ceralive.service -> cerastream.service boot ordering (soft hint, defense against a
# real boot race): ceralive.service's initPipelines() boot step connects to
# cerastream's control socket exactly once, so if cerastream isn't up yet the
# connection fails permanently for that boot. Confirmed live: cerastream.service
# started ~2 minutes AFTER ceralive.service in one boot instance, and
# `systemctl show ceralive -p After` had NO mention of cerastream.service. Bake an
# ADDITIVE drop-in on the ceralive.service unit (shipped by the CeraUI .deb, like
# 10-data-persistence / 20-paseto-public-key) that adds After=cerastream.service.
# ORDERING-ONLY — never Requires=: ceralive.service must still boot into its
# "engine unavailable" degraded state (CeraUI helpers/boot-guard.ts::guardNonCritical)
# if cerastream is genuinely absent/masked, and After= on an out-of-transaction unit
# is a harmless no-op. Installed from the committed standalone artifact under
# CERALIVE_RUNTIME_SRC (like setup_avahi_restart / setup_tls_proxy), never inlined.
# CERASTREAM_ORDERING_DROPIN_DIR overrides the drop-in directory for the offline unit test.
# ---------------------------------------------------------------------------
setup_cerastream_ordering() {
  log "ordering ceralive.service after cerastream.service (additive After= boot-ordering drop-in; no hard dependency)"
  local src="${CERALIVE_RUNTIME_SRC:-}"
  [[ -n "${src}" && -f "${src}/ceralive-cerastream-ordering.dropin.conf" ]] \
    || die "cerastream-ordering source not found: ${src}/ceralive-cerastream-ordering.dropin.conf (is \$SRCDIR/runtime mounted?)"
  local dropin_dir="${CERASTREAM_ORDERING_DROPIN_DIR:-/etc/systemd/system/ceralive.service.d}"
  mkdir -p "${dropin_dir}"
  install -m 0644 "${src}/ceralive-cerastream-ordering.dropin.conf" "${dropin_dir}/30-cerastream-ordering.conf"
}

# ---------------------------------------------------------------------------
# RTMP ingest gateway (Todo 14): bake the PINNED MediaMTX relay.
#
# Build-time FETCH of a pinned MediaMTX release (declarative pin: rtmp-gateway/
# mediamtx.recipe.conf) for the TARGET architecture, verified against a per-arch
# sha256 pin — the build FAILS CLOSED on any checksum mismatch. Stages the single
# static binary to /usr/local/bin/mediamtx, the committed RTMP-only config to
# /etc/mediamtx.yml, and the unit to
# /etc/systemd/system/ceralive-rtmp-gateway.service, then enables it.
#
# The relay is a SINGLE-PURPOSE LAN ingest: it accepts a publish at path
# `publish/live` over RTMP (:1935) OR SRT (:4001) and serves that SAME path on
# loopback so cerastream can pull it — `rtmpsrc rtmp://127.0.0.1/publish/live` or
# `srt://127.0.0.1:4001?streamid=read:publish/live` (app=publish, stream=live —
# HARDCODED in cerastream crates/cerastream-core/src/sources/spec.rs). Every other
# MediaMTX protocol (RTSP/HLS/WebRTC/MoQ/API/metrics/pprof/playback) is disabled in
# mediamtx.yml. MediaMTX's built-in SRT server terminates the SRT leg directly
# (Todo 14 B2): cerastream pulls the SRT read stream on loopback, exactly as it
# pulls RTMP — one MediaMTX process owns both ingest protocols.
#
# Runs INSIDE the target-arch chroot, so `dpkg --print-architecture` yields the
# image arch and curl/tar/sha256sum are present (shared.list: curl + ca-certificates
# + coreutils tar/sha256sum). Network is available — same as the apt install step.
#
# CERALIVE_RUNTIME_SRC must point at the runtime/ source dir. Test seams:
#   MEDIAMTX_RECIPE        — override recipe path (default rtmp-gateway/mediamtx.recipe.conf)
#   MEDIAMTX_ARCH          — override detected target arch (default dpkg --print-architecture)
#   MEDIAMTX_LOCAL_TARBALL — use a local tarball instead of fetching (offline verify)
#   MEDIAMTX_DESTROOT      — install-path prefix (default empty = real /usr,/etc; tests use a tmpdir)
# ---------------------------------------------------------------------------
setup_rtmp_gateway() {
  log "installing RTMP ingest gateway (ceralive-rtmp-gateway.service — pinned MediaMTX LAN publish/live relay)"
  local src="${CERALIVE_RUNTIME_SRC:-}/rtmp-gateway"
  local recipe="${MEDIAMTX_RECIPE:-${src}/mediamtx.recipe.conf}"
  [[ -n "${CERALIVE_RUNTIME_SRC:-}" && -f "${recipe}" ]] \
    || die "rtmp-gateway recipe not found: ${recipe} (is \$SRCDIR/runtime mounted?)"
  [[ -f "${src}/mediamtx.yml" ]] \
    || die "rtmp-gateway config not found: ${src}/mediamtx.yml"
  [[ -f "${src}/ceralive-rtmp-gateway.service" ]] \
    || die "rtmp-gateway unit not found: ${src}/ceralive-rtmp-gateway.service"

  # Load the declarative PIN (KEY=value only).
  local MEDIAMTX_VERSION="" MEDIAMTX_URL_TEMPLATE=""
  # shellcheck source=/dev/null
  source "${recipe}"
  [[ -n "${MEDIAMTX_VERSION}" ]]      || die "${recipe}: MEDIAMTX_VERSION is required"
  [[ -n "${MEDIAMTX_URL_TEMPLATE}" ]] || die "${recipe}: MEDIAMTX_URL_TEMPLATE is required"

  # Target architecture — the chroot IS the image arch.
  local arch="${MEDIAMTX_ARCH:-}"
  if [[ -z "${arch}" ]]; then
    command -v dpkg >/dev/null 2>&1 || die "dpkg not found — cannot resolve target architecture for MediaMTX fetch"
    arch="$(dpkg --print-architecture)"
  fi
  case "${arch}" in
    amd64 | arm64) ;;
    *) die "unsupported architecture for MediaMTX: '${arch}' (recipe pins amd64 + arm64 only)" ;;
  esac

  # Resolve the per-arch sha256 pin (indirect expansion of MEDIAMTX_SHA256_<arch>).
  local sha_var="MEDIAMTX_SHA256_${arch}"
  local expected="${!sha_var:-}"
  [[ -n "${expected}" ]] || die "${recipe}: missing ${sha_var} pin for arch '${arch}'"

  local tmpdir
  tmpdir="$(mktemp -d)"
  local tarball="${tmpdir}/mediamtx.tar.gz"

  # Fetch the pinned tarball (or use a local one for offline verification).
  if [[ -n "${MEDIAMTX_LOCAL_TARBALL:-}" ]]; then
    [[ -f "${MEDIAMTX_LOCAL_TARBALL}" ]] \
      || { rm -rf "${tmpdir}"; die "MEDIAMTX_LOCAL_TARBALL not a file: ${MEDIAMTX_LOCAL_TARBALL}"; }
    cp "${MEDIAMTX_LOCAL_TARBALL}" "${tarball}"
  else
    command -v curl >/dev/null 2>&1 || { rm -rf "${tmpdir}"; die "curl not found — cannot fetch MediaMTX"; }
    local url="${MEDIAMTX_URL_TEMPLATE//\{ver\}/${MEDIAMTX_VERSION}}"
    url="${url//\{arch\}/${arch}}"
    log "fetching MediaMTX ${MEDIAMTX_VERSION} (${arch}) from ${url}"
    curl -fsSL --retry 3 -o "${tarball}" "${url}" \
      || { rm -rf "${tmpdir}"; die "MediaMTX fetch failed: ${url}"; }
  fi

  # FAIL CLOSED on checksum mismatch — this is the pin gate.
  local actual
  actual="$(sha256sum "${tarball}" | awk '{print $1}')"
  if [[ "${actual}" != "${expected}" ]]; then
    rm -rf "${tmpdir}"
    die "MediaMTX ${MEDIAMTX_VERSION} (${arch}) sha256 MISMATCH — build fails closed. expected=${expected} actual=${actual}"
  fi
  log "MediaMTX ${MEDIAMTX_VERSION} (${arch}) sha256 verified: ${actual}"

  # Extract only the static binary from the verified tarball.
  tar -xzf "${tarball}" -C "${tmpdir}" mediamtx \
    || { rm -rf "${tmpdir}"; die "MediaMTX tarball missing 'mediamtx' binary member"; }

  # Stage binary + config + unit. install -D creates parents; DESTROOT is empty in
  # production (absolute /usr,/etc) and a tmpdir in the offline self-test.
  local destroot="${MEDIAMTX_DESTROOT:-}"
  install -D -m 0755 "${tmpdir}/mediamtx" "${destroot}/usr/local/bin/mediamtx"
  install -D -m 0644 "${src}/mediamtx.yml" "${destroot}/etc/mediamtx.yml"
  install -D -m 0644 "${src}/ceralive-rtmp-gateway.service" "${destroot}/etc/systemd/system/ceralive-rtmp-gateway.service"
  rm -rf "${tmpdir}"

  enable_service ceralive-rtmp-gateway.service
}
