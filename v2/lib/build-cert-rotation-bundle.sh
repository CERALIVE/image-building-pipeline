#!/usr/bin/env bash
#
# build-cert-rotation-bundle.sh — package a NEW intermediate + leaf signing cert
# into a SIGNED RAUC bundle that rotates them on the fleet WITHOUT a reflash
# (Stage 7, task 42).
#
#     build-cert-rotation-bundle.sh <board> <new-intermediate.pem> <new-leaf.pem> <new-leaf.key>
#
# WHAT THIS IS (and is NOT)
#   The device trusts the IMMUTABLE root CA baked into its RAUC keyring at flash
#   time. RAUC has NO through-channel root swap (cert-work/rauc/README.txt). The
#   intermediate (<=5y) and leaf (<=2y) BELOW that root, however, MUST be rotatable
#   in the field. This script produces a `.raucb` whose payload is the NEW
#   intermediate.pem + leaf.pem; on the device a baked-in install hook stages them
#   and cert-rotation.service re-verifies the chain to the immutable root before
#   activating them at /data/ceralive/certs/ (survives A/B OS updates).
#
#   This bundle does NOT change the root, does NOT update a rootfs slot, and does
#   NOT ship any private key to devices (a device only VERIFIES bundles — it never
#   signs). The <new-leaf.key> argument is used ONLY on the build host to prove the
#   supplied new-leaf.pem/new-leaf.key are a matching pair; it is never placed in
#   the bundle.
#
# SIGNING (identical trust structure to lib/build-bundle.sh, task 28)
#   The bundle is signed with the CURRENT release leaf (cert-work/rauc/
#   leaf-signing.key) + the CURRENT chain.pem — NEVER the root key. A device with
#   the unchanged root in its keyring accepts it (leaf -> intermediate -> root).
#   This is "pre-expiry rotation": you sign with the still-valid current leaf to
#   deliver the next one. (The no-root-sign guard from build-bundle.sh is enforced.)
#
# NEW-CERT GATE (the verification this task is really about)
#   Before building anything, the NEW intermediate + leaf MUST verify to the SAME
#   immutable root (`openssl verify -CAfile root-ca.pem -untrusted new-int new-leaf`)
#   and must not be expired. A new intermediate that does NOT chain to the device's
#   root is refused here — shipping it would brick rotation (the device would reject
#   it too). This is the build-side twin of the on-device cert-rotation.sh gate.
#
# HOST WITHOUT rauc: falls back to the SAME OpenSSL CMS harness as build-bundle.sh
# (squashfs payload + detached CMS by the leaf, verified to the root keyring), so
# the signing chain is exercised end-to-end with the REAL PKI.
#
# DESIGN RULES (lib/common.sh): strict mode, loud ERR trap, NO `|| true`.
#
# shellcheck shell=bash

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Reuse build-bundle.sh's signing core (it sources common.sh and defines the PKI
# locations + the signer/verifier helpers + the no-root-sign guard). Sourcing is
# safe: build-bundle.sh only dispatches when executed directly (BASH_SOURCE guard).
# shellcheck source=lib/build-bundle.sh
source "${HERE}/build-bundle.sh"

usage() {
  cat >&2 <<EOF
Usage: build-cert-rotation-bundle.sh <board> <new-intermediate.pem> <new-leaf.pem> <new-leaf.key>

Builds a signed RAUC .raucb that rotates the intermediate + leaf signing certs on
the fleet without a reflash. The new certs are verified against the IMMUTABLE root
CA before bundling; the bundle is signed with the CURRENT leaf (never the root).

Args:
  <board>                board id (e.g. orangepi5plus); selects the output subtree
                         and the default compatible string.
  <new-intermediate.pem> the NEW intermediate cert (must chain to the SAME root).
  <new-leaf.pem>         the NEW leaf cert (signed by the new intermediate).
  <new-leaf.key>         the NEW leaf private key — used ONLY to prove it matches
                         <new-leaf.pem>; NEVER shipped to devices.

Env:
  COMPATIBLE_STRING      RAUC \`compatible\`. Default: ceralive-<board>. MUST match
                         the device system.conf or \`rauc install\` rejects the bundle.
  BUNDLE_VERSION         version string. Default: certrot-<timestamp>.
  CERALIVE_RAUC_PKI_DIR  override the cert-work/rauc PKI directory.

Output:
  images/<board>/cert-bundles/<timestamp>.raucb         the signed rotation bundle
  images/<board>/cert-bundles/<timestamp>.raucb.sha256  checksum (for R2 upload)
EOF
}

# ---------------------------------------------------------------------------
# assert_new_certs <new-int> <new-leaf> <new-leaf-key> — the new-cert gate.
#
# The NEW pair must verify to the IMMUTABLE root, must be in-date, and the key
# must match the leaf cert. We compare modulus DIGESTS only (never print key
# material — cert-work/AGENTS.md: do not log key/cert VALUES).
# ---------------------------------------------------------------------------
assert_new_certs() {
  local new_int="$1" new_leaf="$2" new_key="$3"
  local f
  for f in "${new_int}" "${new_leaf}" "${new_key}"; do
    [[ -s "${f}" ]] || die "new cert input missing or empty: ${f}"
  done

  log_info "verifying NEW chain to the IMMUTABLE root: ${RAUC_ROOT_CA}"
  if ! openssl verify -purpose any -CAfile "${RAUC_ROOT_CA}" \
        -untrusted "${new_int}" "${new_leaf}" >/dev/null; then
    die "NEW intermediate/leaf do NOT chain to ${RAUC_ROOT_CA} — a device with this immutable root would reject the rotation (refusing to build)"
  fi
  log_success "NEW chain verifies: leaf -> intermediate -> root"

  openssl x509 -checkend 0 -noout -in "${new_int}" \
    || die "NEW intermediate is already expired — refusing to build"
  openssl x509 -checkend 0 -noout -in "${new_leaf}" \
    || die "NEW leaf is already expired — refusing to build"

  local leaf_mod key_mod
  leaf_mod="$(openssl x509 -noout -modulus -in "${new_leaf}" | openssl sha256)"
  key_mod="$(openssl rsa -noout -modulus -in "${new_key}" | openssl sha256)"
  [[ "${leaf_mod}" == "${key_mod}" ]] \
    || die "NEW leaf.key does not match NEW leaf.pem (modulus digest mismatch) — refusing to build"
  log_success "NEW leaf key matches NEW leaf cert (modulus digest)"
}

# ---------------------------------------------------------------------------
# write_cert_manifest <path> <compatible> <version>
#
# A RAUC `install` hook bundle: the `certs` image is delivered by hook.sh (RAUC
# does not write a slot itself), so the device needs only the baked-in
# [slot.certs.0] (runtime/rauc/system.conf) — no reflash to receive a rotation.
# ---------------------------------------------------------------------------
write_cert_manifest() {
  local path="$1" compatible="$2" version="$3"
  cat >"${path}" <<EOF
[update]
compatible=${compatible}
version=${version}

[bundle]
format=plain

[hooks]
filename=hook.sh

[image.certs]
filename=certs.tar
hooks=install
EOF
}

# ---------------------------------------------------------------------------
# write_install_hook <path> — the device-side install hook embedded in the bundle.
#
# RAUC runs this with `slot-install` for the `certs` image AFTER it has verified
# the bundle's CMS signature to the keyring root. It extracts the new certs into
# the staging dir and hands off to the BAKED-IN cert-rotation.service, which
# re-verifies the chain to the immutable root before activating (defense in depth).
# ---------------------------------------------------------------------------
write_install_hook() {
  local path="$1"
  cat >"${path}" <<'HOOKEOF'
#!/bin/bash
# CeraLive cert-rotation bundle install hook (task 42). RAUC calls this for the
# `certs` image; it stages the new certs and triggers cert-rotation.service, which
# verifies leaf -> intermediate -> immutable-root before activating them.
set -euo pipefail

INCOMING="/data/ceralive/certs/incoming"

case "$1" in
  slot-install)
    mkdir -p "${INCOMING}"
    # cwd is the mounted bundle; $RAUC_IMAGE_NAME is the image to install (certs.tar).
    tar -xf "${RAUC_IMAGE_NAME}" -C "${INCOMING}"
    # Hand off to the baked-in verifier+activator. Prefer the unit (journald +
    # ordering); fall back to a direct call if systemd is not driving us.
    if command -v systemctl >/dev/null 2>&1; then
      systemctl start --no-block cert-rotation.service
    else
      /usr/local/bin/cert-rotation.sh install
    fi
    ;;
  *)
    exit 0
    ;;
esac
HOOKEOF
  chmod +x "${path}"
}

# ---------------------------------------------------------------------------
# stage_cert_content <new-int> <new-leaf> <content-dir> — assemble bundle content.
# ---------------------------------------------------------------------------
stage_cert_content() {
  local new_int="$1" new_leaf="$2" content="$3"
  local staging
  staging="$(mktemp -d)"
  # PUBLIC certs only — never a private key (a device only verifies bundles).
  install -m 0644 "${new_int}" "${staging}/intermediate.pem"
  install -m 0644 "${new_leaf}" "${staging}/leaf.pem"
  tar --numeric-owner --owner=0 --group=0 -cf "${content}/certs.tar" -C "${staging}" .
  rm -rf "${staging}"
}

# ---------------------------------------------------------------------------
# build-cert-rotation-bundle <board> <new-int> <new-leaf> <new-leaf-key>
# ---------------------------------------------------------------------------
build-cert-rotation-bundle() {
  [[ $# -eq 4 ]] || { usage; die "expected exactly 4 args, got $#"; }
  local board="$1" new_int="$2" new_leaf="$3" new_key="$4"
  [[ -n "${board}" ]] || die "empty board"

  # CURRENT signing material (cert-work/rauc): leaf-signing.key + chain.pem + root.
  assert_pki
  # NEW certs gate: must chain to the immutable root, be in-date, key matches cert.
  assert_new_certs "${new_int}" "${new_leaf}" "${new_key}"

  local compatible version ts
  compatible="${COMPATIBLE_STRING:-}"
  if [[ -z "${compatible}" ]]; then
    compatible="ceralive-${board}"
    log_warn "COMPATIBLE_STRING unset — defaulting to '${compatible}' (orchestrator normally sets this from the manifest)"
  fi
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  version="${BUNDLE_VERSION:-certrot-${ts}}"

  log_info "board=${board} compatible=${compatible} version=${version}"

  local content
  content="$(mktemp -d)"
  trap 'rm -rf "${content}"' RETURN
  stage_cert_content "${new_int}" "${new_leaf}" "${content}"
  write_install_hook "${content}/hook.sh"
  write_cert_manifest "${content}/manifest.raucm" "${compatible}" "${version}"
  log_info "content staged: manifest.raucm + hook.sh + certs.tar (intermediate.pem + leaf.pem)"

  local out_dir out
  out_dir="${IMAGES_DIR}/${board}/cert-bundles"
  mkdir -p "${out_dir}"
  out="${out_dir}/${ts}.raucb"

  if command -v rauc >/dev/null 2>&1; then
    log_info "rauc present — using native rauc bundle"
    bundle_with_rauc "${content}" "${out}"
  else
    bundle_with_openssl "${content}" "${out}"
  fi

  ( cd "${out_dir}" && sha256sum "$(basename "${out}")" >"$(basename "${out}").sha256" )

  log_success "cert-rotation bundle: ${out} ($(du -h "${out}" | cut -f1))"
  log_info "sha256: $(cut -d' ' -f1 <"${out}.sha256")"
  log_info "R2 layout: images/${board}/cert-bundles/$(basename "${out}") — upload to R2; roll out via hawkBit exactly like an OS bundle"

  printf '%s\n' "${out}"
}

# ---------------------------------------------------------------------------
# Direct-invocation dispatch.
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    -h | --help | "") usage; exit 0 ;;
    *) build-cert-rotation-bundle "$@" ;;
  esac
fi
