#!/usr/bin/env bash
#
# postinst.d/services.sh — the systemd unit policy for the image.
#
# Sourced by customize/postinst-lib.sh (never executed). Concern: which units
# exist, which are enabled, and which must be actively suppressed —
#
#   * ensure_group / enable_service / disable_service / mask_service
#                              the four primitives every other module uses
#   * configure_services       the enable/disable pass, and the single call site
#                              that drives the hardware and SSH policy modules
#   * suppress_unusable_boot_units
#                              the six stock units this image can never satisfy
#   * configure_ntp, install_console_font_service, setup_boot_healthcheck,
#     setup_avahi_restart, setup_cerastream_ordering, setup_rtmp_gateway
#
# NOT to be confused with customize/services.sh one directory up: that is a
# run-all.sh module (an ENTRY the mkosi hooks dispatch), while this is a library
# module the postinst entry sources. The drift gate keys on full paths, so the
# shared basename is safe — but they are different files with different callers.
#
# configure_services calls into hardware.sh and tls-ssh.sh. That is a runtime
# call, not a source-time one, so module load order stays irrelevant; the entry
# sources every module before anything is invoked.
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

# install_chroot_service_policy — re-assert the build-time service-start denial
# for the apt/dpkg transactions THIS repository drives itself.
#
# mkosi writes its own /usr/sbin/policy-rc.d around every `Apt.install()` and
# UNLINKS it when that transaction ends (mkosi/installer/apt.py). Only the base
# image declares `Packages=`, so once the base layer's bootstrap finishes the path
# is GONE — and the base skeleton tree's copy goes with it, because mkosi's unlink
# does not care who put the file there. Every later transaction this repository
# runs from a postinst script (runtime's shared.list set, platform's BSP via
# mkosi-install, app's first-party .debs) is therefore outside any mkosi
# transaction and unprotected. That is what kept emitting census rows 9 and 21
# from the runtime layer long after the base-layer half looked fixed.
#
# Mode 0755 is the entire point: invoke-rc.d gates on `test -x "${POLICYHELPER}"`,
# so a non-executable helper is reported as MISSING rather than as denying.
#
# Removed again at the end of the layer chain by
# app/mkosi.postinst.chroot::remove_chroot_service_policy, which DIES if it
# survives into the sealed rootfs.
install_chroot_service_policy() {
  local policy="${CERALIVE_POLICY_RCD:-/usr/sbin/policy-rc.d}"
  install -d -m 0755 "$(dirname "${policy}")"
  printf '#!/bin/sh\n# BUILD-TIME ONLY — deny every service start in the build chroot.\nexit 101\n' >"${policy}"
  chmod 0755 "${policy}"
  [[ -x "${policy}" ]] || die "could not install an EXECUTABLE ${policy} — invoke-rc.d would report it MISSING"
  log "build-time service-start policy installed at ${policy} (exit 101, mode 0755)"
}

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

# NEVER `systemctl list-unit-files "$svc" | grep -q "$svc"`: `grep -q` exits at its
# first match and closes the pipe, systemctl dies of SIGPIPE mid-trailer, and
# `set -o pipefail` reports 141 for a unit that WAS found. Measured at 23/300 runs
# against a real built rootfs — it silently no-op'd `disable_service ssh.service` on
# a production build and failed the `[7/9]` disabled-by-default SSH parity gate.
# A command substitution has no early reader, so nothing can SIGPIPE the writer.
unit_file_present() {
  local svc="$1" listed
  listed="$(systemctl list-unit-files --no-legend --no-pager "${svc}" 2>/dev/null)" || return 1
  [[ -n "${listed}" ]]
}

disable_service() {
  # Disabling a not-installed unit is a legitimate no-op (the package was never
  # added to this minimal image) — skip cleanly when the unit file is absent.
  local svc="$1"
  if unit_file_present "${svc}"; then
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
  # RAUC A/B replaces /etc wholesale, so a runtime-only enable silently self-reverts on every OTA; the CeraUI boot reconciler (separate BT foundation todo) covers already-flashed images.
  disable_service cups.service
  suppress_unusable_boot_units
  setup_typec_policy
  setup_fan_curve
  setup_fan_kickstart
  setup_led_status
  setup_hdmirx_edid
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

# ---------------------------------------------------------------------------
# Boot healthcheck (task 29): install the COMMITTED canonical artifacts (single
# source of truth) instead of re-embedding stripped heredoc twins. Mirrors
# customize/services.sh::install_healthcheck_service. CERALIVE_RUNTIME_SRC must
# point at the runtime/ source dir (postinst: "${SRCDIR}/runtime"; customize:
# "${SERVICES_DIR}/../runtime").
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
