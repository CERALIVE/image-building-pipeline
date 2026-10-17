#!/usr/bin/env bash
diagnose_debian_tls_failure() {
  log "Debian TLS failure: collecting evidence inside the runtime chroot"
  date -u
  if [[ -s /etc/ssl/certs/ca-certificates.crt ]]; then
    stat -c 'CA bundle: %n size=%s bytes mtime=%y' /etc/ssl/certs/ca-certificates.crt
  else
    log "CA bundle absent or empty at failure time"
  fi
  if ! command -v openssl >/dev/null 2>&1; then
    log "openssl unavailable in runtime chroot; cannot inspect peer certificate"
    return
  fi
  local family
  for family in -4 -6; do
    log "deb.debian.org TLS peer (${family}) — direct, SNI and hostname verified"
    if timeout 20 openssl s_client "${family}" -connect deb.debian.org:443 \
      -servername deb.debian.org -verify_hostname deb.debian.org \
      -verify_return_error -brief </dev/null 2>&1; then
      log "deb.debian.org ${family} TLS verified"
    else
      log "deb.debian.org ${family} TLS probe failed (see peer/verification output above)"
    fi
    if timeout 20 openssl s_client "${family}" -connect deb.debian.org:443 \
      -servername deb.debian.org -showcerts </dev/null 2>/dev/null \
      | openssl x509 -noout -subject -issuer -dates 2>&1; then
      :
    else
      log "deb.debian.org ${family} certificate identity unavailable"
    fi
  done
}
