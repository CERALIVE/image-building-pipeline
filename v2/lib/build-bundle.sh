#!/usr/bin/env bash
#
# build-bundle.sh — package a rootfs slot image into a SIGNED RAUC bundle (.raucb).
#
# Stage 4, task 28. Produces a `.raucb` for the A/B RAUC update flow:
#
#     build-bundle.sh <board> <rootfs-dir-or-tar>
#
# WHAT IT DOES
#   1. Builds a RAUC `manifest.raucm` (rootfs slot, compatible, version).
#   2. Assembles the bundle content (manifest + rootfs image).
#   3. SIGNS it with the leaf signing key + the intermediate chain —
#      NEVER the root CA key (the root stays offline/immutable, README.txt).
#   4. VERIFIES the signature chain against the device trust anchor
#      (the explicit release root, identical to the on-device keyring).
#   5. Emits to images/<board>/bundles/<timestamp>.raucb (+ .sha256) — the
#      layout consumed by the R2 upload step. Bundles are served from R2;
#      they are NOT placed in the hawkBit local artifact store.
#
# PKI (explicit CERALIVE_RAUC_PKI_DIR):
#   root-ca.pem        device keyring (immutable trust anchor)        — VERIFY only
#   root-ca.key        root private key                               — NEVER touched here
#   chain.pem          intermediate-ca.pem                           — embedded in bundle
#   leaf-signing.pem   leaf code-signing cert                         — the signer cert
#   leaf-signing.key   leaf private key                               — SIGNS the bundle (CMS)
#
# Device verify path: leaf -> intermediate (from the bundle's chain.pem) -> root
# (from /etc/rauc/ceralive-keyring.pem). RAUC has no through-channel root swap.
#
# RAUC INVOCATION (real `rauc`, when present). chain.pem contains the intermediate
# certificate, while the signer cert is passed explicitly as the leaf and the
# chain is supplied via --intermediate (the README-canonical form). This still
# uses ONLY leaf-signing.key + chain.pem; root-ca.key never appears:
#
#     rauc bundle --cert=leaf-signing.pem --key=leaf-signing.key \
#                 --intermediate=chain.pem  <content-dir> <output.raucb>
#     rauc info   --keyring=root-ca.pem     <output.raucb>
#
# HOST WITHOUT rauc: this script falls back to an OpenSSL CMS harness that
# reproduces RAUC's plain-format trust structure (squashfs payload + detached
# CMS over it, signed by the leaf, verified to the root keyring). The signing
# chain is exercised end-to-end with the REAL PKI so the evidence is meaningful.
#
# DESIGN RULES (inherited from lib/common.sh): strict mode, loud ERR trap, and
# absolutely NO `|| true` error swallowing.
#
# shellcheck shell=bash

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${HERE}/common.sh"

# ---------------------------------------------------------------------------
# Locations.
# ---------------------------------------------------------------------------
V2_DIR="$(cd "${HERE}/.." && pwd)"
IMAGES_DIR="${V2_DIR}/images"

# Reproducible builds (task 14). One fixed epoch clamps every embedded mtime
# (the staged rootfs.tar entries + the squashfs superblock/inodes), and the
# reproducible signer omits the wall-clock CMS signingTime — the one source of
# bundle non-determinism real `rauc` cannot suppress (rauc 1.x exposes no flag
# for it). REPRODUCIBLE=0 opts back into the native `rauc bundle` signer.
SOURCE_DATE_EPOCH="$(resolve_source_date_epoch "${V2_DIR}")"
export SOURCE_DATE_EPOCH
REPRODUCIBLE="${REPRODUCIBLE:-1}"

# The orchestrator resolves development/production PKI once and passes the exact
# directory. Direct callers must do the same; no sibling-workspace fallback exists.
[[ -n "${CERALIVE_RAUC_PKI_DIR:-}" ]] \
  || die "CERALIVE_RAUC_PKI_DIR is required (resolve it with rauc-pki-contract.sh)"
RAUC_PKI_DIR="${CERALIVE_RAUC_PKI_DIR}"

# The orchestrator has already proven root-ca.pem matches the keyring baked into
# both slots; direct callers must supply the same resolved directory.
RAUC_ROOT_CA="${RAUC_PKI_DIR}/root-ca.pem"
RAUC_CHAIN="${RAUC_PKI_DIR}/chain.pem"
RAUC_LEAF_CERT="${RAUC_PKI_DIR}/leaf-signing.pem"
RAUC_LEAF_KEY="${RAUC_PKI_DIR}/leaf-signing.key"
# Reference only — used by the no-root-sign guard to assert it is NEVER consumed.
RAUC_ROOT_KEY="${RAUC_PKI_DIR}/root-ca.key"

# The signing leaf carries a DUAL EKU: emailProtection + codeSigning.
#   * emailProtection satisfies the device's UNCONFIGURED default verify purpose.
#     Debian bookworm ships rauc 1.8, which predates check-purpose=codesign
#     (added in rauc 1.9), so its CMS_verify() falls back to OpenSSL's default
#     smime_sign purpose. A codeSigning-ONLY leaf fails that with "unsuitable
#     certificate purpose" — confirmed on real Rock 5B+ hardware; emailProtection
#     is what makes `rauc install` accept the bundle on 1.8.
#   * codeSigning keeps the leaf forward-compatible with a future rauc >=1.9
#     upgrade using check-purpose=codesign (below).
# RAUC_VERIFY_OPTS still requests check-purpose=codesign so a modern host `rauc`
# (>=1.9, e.g. CI/local rauc 1.15.2) exercises the strict codesign path; on the
# device's 1.8 this flag doesn't exist, hence the emailProtection belt-and-braces.
RAUC_VERIFY_OPTS=(-C keyring:check-purpose=codesign)

usage() {
  cat >&2 <<EOF
Usage: build-bundle.sh <board> <rootfs-dir-or-tar>

Packages a rootfs slot image into a signed RAUC .raucb bundle and verifies it
against the device root-CA keyring.

Args:
  <board>              board id (e.g. orangepi5plus); selects the output subtree.
  <rootfs-dir-or-tar>  a rootfs directory OR a rootfs tarball to ship as the
                       rootfs slot image.

Env:
  COMPATIBLE_STRING       RAUC \`compatible\` — REQUIRED. The orchestrator exports
                          it board-specific (ceralive-<board-slug>). No default:
                          it MUST match system.conf on the device or install fails.
  BUNDLE_VERSION          bundle version string. Default: git short SHA, else
                          the build timestamp.
  CERALIVE_RAUC_PKI_DIR   explicit signer PKI directory (required).
  BUNDLE_OUT_DIR          override the output directory. Default:
                          images/<board>/bundles. The orchestrator sets this to
                          images/<board> so the .raucb lands ALONGSIDE the .raw.
  BUNDLE_TS               override the output filename stem (<stem>.raucb).
                          Default: a fresh UTC timestamp. The orchestrator sets
                          this to the build timestamp shared with the .raw/.rootfs.tar.

Output:
  <BUNDLE_OUT_DIR>/<BUNDLE_TS>.raucb        the signed bundle
  <BUNDLE_OUT_DIR>/<BUNDLE_TS>.raucb.sha256 checksum (for R2 upload)

Bundles are served from R2; they are NOT written to the hawkBit local store.
EOF
}

# ---------------------------------------------------------------------------
# assert_pki — every public PKI input the build needs must be present and
# non-empty before we touch anything.
# ---------------------------------------------------------------------------
assert_pki() {
  local f
  for f in "${RAUC_ROOT_CA}" "${RAUC_CHAIN}" "${RAUC_LEAF_CERT}" "${RAUC_LEAF_KEY}"; do
    [[ -s "${f}" ]] || die "RAUC PKI file missing or empty: ${f} (set CERALIVE_RAUC_PKI_DIR?)"
  done
  log_info "PKI: ${RAUC_PKI_DIR}"
}

# ---------------------------------------------------------------------------
# assert_no_root_signing <argv...> — the no-root-sign guard.
#
# RAUC bundle signing must use the leaf key + intermediate chain ONLY. The
# root CA key is offline and immutable; it signs the intermediate and nothing
# else (README.txt). This greps the *rendered signing invocation* and aborts if
# root-ca.key appears, and positively asserts the leaf key is the signer.
# ---------------------------------------------------------------------------
assert_no_root_signing() {
  local rendered="$*"
  local root_key_base
  root_key_base="$(basename "${RAUC_ROOT_KEY}")"   # root-ca.key — the forbidden signer
  if grep -Fq "${root_key_base}" <<<"${rendered}"; then
    die "REFUSING to sign: signing invocation references ${root_key_base} — root must stay offline"
  fi
  grep -q 'leaf-signing\.key' <<<"${rendered}" \
    || die "signing invocation does not use leaf-signing.key — refusing (expected leaf signer)"
  log_success "no-root-sign guard OK — signer is the leaf key, ${root_key_base} absent from argv"
}

# ---------------------------------------------------------------------------
# write_manifest <path> <compatible> <version> <image-filename>
# ---------------------------------------------------------------------------
write_manifest() {
  local path="$1" compatible="$2" version="$3" image="$4"
  cat >"${path}" <<EOF
[update]
compatible=${compatible}
version=${version}

[bundle]
format=plain

[image.rootfs]
filename=${image}
EOF
}

# ---------------------------------------------------------------------------
# append_image_checksum <manifest> <image-path>
# RAUC needs sha256+size in [image.<slot>]; `rauc bundle` fills these itself, but
# the OpenSSL signer must add them or `rauc info`/install rejects the bundle with
# "Unsupported checksum algorithm". Appended under the [image.rootfs] section
# write_manifest emits last.
# ---------------------------------------------------------------------------
append_image_checksum() {
  local manifest="$1" image_path="$2" sha size
  sha="$(sha256sum "${image_path}" | cut -d' ' -f1)"
  size="$(stat -c '%s' "${image_path}")"
  cat >>"${manifest}" <<EOF
sha256=${sha}
size=${size}
EOF
  log_info "manifest: image sha256=${sha:0:12}… size=${size} bytes"
}

# ---------------------------------------------------------------------------
# stage_rootfs <rootfs-src> <content-dir> -> prints the image filename
#
# A directory becomes rootfs.tar (RAUC unpacks tar* into the ext4 slot). A
# tarball is shipped as-is; any other regular file is treated as a filesystem
# image and shipped verbatim.
# ---------------------------------------------------------------------------
stage_rootfs() {
  local src="$1" content="$2" image
  if [[ -d "${src}" ]]; then
    image="rootfs.tar"
    tar --sort=name --numeric-owner --owner=0 --group=0 \
        --mtime="@${SOURCE_DATE_EPOCH}" --format=gnu \
        -cf "${content}/${image}" -C "${src}" .
  elif [[ -f "${src}" ]]; then
    case "${src}" in
      *.tar | *.tar.* | *.tgz) image="rootfs.tar" ;;
      *) image="$(basename "${src}")" ;;
    esac
    cp -- "${src}" "${content}/${image}"
  else
    die "rootfs source not found: ${src}"
  fi
  printf '%s\n' "${image}"
}

# ---------------------------------------------------------------------------
# bundle_with_rauc <content-dir> <out>  — real `rauc` path.
# ---------------------------------------------------------------------------
bundle_with_rauc() {
  local content="$1" out="$2"
  local -a sign_cmd=(
    rauc bundle
    "--cert=${RAUC_LEAF_CERT}"
    "--key=${RAUC_LEAF_KEY}"
    "--intermediate=${RAUC_CHAIN}"
    "${content}" "${out}"
  )
  assert_no_root_signing "${sign_cmd[*]}"
  log_info "signing: ${sign_cmd[*]}"
  "${sign_cmd[@]}"
  log_info "verifying against device root-CA keyring: ${RAUC_ROOT_CA}"
  rauc info "${RAUC_VERIFY_OPTS[@]}" --keyring="${RAUC_ROOT_CA}" "${out}"
}

# ---------------------------------------------------------------------------
# bundle_with_openssl <content-dir> <out>  — the deterministic signer.
#
# Reproduces RAUC's plain-format trust structure, and is what `rauc info`/install
# verify against the device keyring:
#   payload   = squashfs(content/)                       (manifest + rootfs image)
#   signature = detached CMS(payload) by the LEAF, with chain.pem intermediates embedded
#   bundle    = payload || signature || uint64-BE(len(signature))
#
# Determinism (task 14): mksquashfs clamps the superblock + inode times to the
# exported SOURCE_DATE_EPOCH, and the CMS is signed with -noattr so NO wall-clock
# signingTime enters the signature. With the RSA leaf key the signature bytes are
# then a pure function of the payload → bit-identical across rebuilds, while still
# verifying leaf -> intermediate -> root (signing is NOT weakened).
# ---------------------------------------------------------------------------
bundle_with_openssl() {
  local content="$1" out="$2"
  require_cmd mksquashfs
  require_cmd openssl

  local work payload sig
  work="$(dirname "${out}")"
  payload="${work}/.$(basename "${out}").squashfs"
  sig="${work}/.$(basename "${out}").cms"

  log_info "building plain-format bundle via squashfs + OpenSSL CMS (SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH})"
  mksquashfs "${content}" "${payload}" -all-root -noappend -no-progress -quiet -comp gzip

  # Detached CMS over the squashfs payload, signed by the leaf, chain embedded for
  # path building. -noattr drops the signed-attribute set (incl. the wall-clock
  # signingTime) so the RSA signature is reproducible. The signer is the leaf cert
  # + leaf key; root-ca.key is nowhere in this argv (guard below).
  local -a sign_cmd=(
    openssl cms -sign -binary -nosmimecap -noattr
    -in "${payload}"
    -signer "${RAUC_LEAF_CERT}"
    -inkey "${RAUC_LEAF_KEY}"
    -certfile "${RAUC_CHAIN}"
    -outform DER -out "${sig}"
  )
  assert_no_root_signing "${sign_cmd[*]}"
  log_info "signing: ${sign_cmd[*]}"
  "${sign_cmd[@]}"

  # Assemble payload || signature || uint64-BE(sig length).
  local sig_len hex i
  sig_len="$(stat -c '%s' "${sig}")"
  cat "${payload}" "${sig}" >"${out}"
  hex="$(printf '%016x' "${sig_len}")"
  for ((i = 0; i < 16; i += 2)); do printf '%b' "\\x${hex:i:2}"; done >>"${out}"
  rm -f "${payload}" "${sig}"

  log_info "verifying against device root-CA keyring: ${RAUC_ROOT_CA}"
  verify_openssl_bundle "${out}"
}

# ---------------------------------------------------------------------------
# verify_openssl_bundle <bundle> — split the trailer, verify the CMS chain to
# the root keyring, and confirm the signer is the leaf (not the root).
# ---------------------------------------------------------------------------
verify_openssl_bundle() {
  local bundle="$1"
  local total sig_len payload_len work payload sig
  total="$(stat -c '%s' "${bundle}")"
  # Last 8 bytes = big-endian signature length.
  sig_len=$(( 16#$(tail -c 8 "${bundle}" | od -An -tx1 | tr -d ' \n') ))
  payload_len=$(( total - 8 - sig_len ))
  [[ "${payload_len}" -gt 0 ]] || die "bundle trailer corrupt (payload_len=${payload_len})"

  work="$(dirname "${bundle}")"
  payload="${work}/.verify.$(basename "${bundle}").squashfs"
  sig="${work}/.verify.$(basename "${bundle}").cms"
  head -c "${payload_len}" "${bundle}" >"${payload}"
  tail -c "$(( sig_len + 8 ))" "${bundle}" | head -c "${sig_len}" >"${sig}"

  # Verify to the ROOT keyring with -purpose smimesign — deliberately NOT
  # -purpose any. This self-check must reproduce what the DEVICE enforces at
  # `rauc install` time, not a laxer superset. The device runs rauc 1.8 (Debian
  # bookworm), which predates check-purpose=codesign (rauc 1.9) and therefore
  # falls back to OpenSSL's default smime_sign purpose. -purpose any accepted
  # ANY purpose and so silently passed a codeSigning-ONLY leaf that rauc 1.8
  # rejects on hardware ("unsuitable certificate purpose") — the exact parity gap
  # that shipped a non-installable bundle. -purpose smimesign reproduces the 1.8
  # check (same OpenSSL error), so a single-purpose leaf fails HERE at build time
  # instead of on the device; the dual-EKU leaf (emailProtection + codeSigning)
  # satisfies it. The intermediate is taken from the certs embedded in the CMS at
  # signing time.
  local rc=0
  openssl cms -verify -binary -inform DER -in "${sig}" \
    -content "${payload}" -CAfile "${RAUC_ROOT_CA}" -purpose smimesign \
    -out /dev/null 2>"${work}/.verify.log" || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    cat "${work}/.verify.log" >&2 || true
    rm -f "${payload}" "${sig}" "${work}/.verify.log"
    die "bundle signature did NOT verify against the root-CA keyring"
  fi
  rm -f "${payload}" "${sig}" "${work}/.verify.log"
  log_success "signature verified: leaf -> intermediate -> root (${RAUC_ROOT_CA})"
}

# ---------------------------------------------------------------------------
# bundle_info <bundle> <compatible> <version>  — `rauc info`-equivalent.
#
# Re-extracts manifest.raucm FROM the produced bundle (proving the metadata is
# actually embedded, not just echoed) and prints compatible + version.
# ---------------------------------------------------------------------------
bundle_info() {
  local bundle="$1"
  if command -v rauc >/dev/null 2>&1; then
    rauc info "${RAUC_VERIFY_OPTS[@]}" --keyring="${RAUC_ROOT_CA}" "${bundle}"
    return
  fi
  require_cmd unsquashfs
  local tmp
  tmp="$(mktemp -d)"
  # unsquashfs reads bytes_used from the superblock; the trailing CMS+len are
  # ignored. Extract just the manifest to prove it is embedded in the bundle.
  unsquashfs -no-progress -d "${tmp}/x" "${bundle}" manifest.raucm >/dev/null
  echo "=== manifest.raucm (extracted from bundle) ==="
  cat "${tmp}/x/manifest.raucm"
  rm -rf "${tmp}"
}

# ---------------------------------------------------------------------------
# build-bundle <board> <rootfs-dir-or-tar>  — the task entry point.
# ---------------------------------------------------------------------------
build-bundle() {
  [[ $# -eq 2 ]] || { usage; die "expected exactly 2 args, got $#"; }
  local board="$1" rootfs_src="$2"
  [[ -n "${board}" ]] || die "empty board"

  assert_pki

  local compatible version ts
  # T12: read the compatible verbatim from the orchestrator — no local default. A
  # bundle stamped with a guessed compatible that disagrees with the device
  # system.conf is rejected by `rauc install`, so fail loud rather than ship one.
  compatible="${COMPATIBLE_STRING:-}"
  [[ -n "${compatible}" ]] || die "COMPATIBLE_STRING is unset/empty — the orchestrator must export ceralive-<board-slug> (board-specific); refusing to stamp a bundle the device would reject"

  version="${BUNDLE_VERSION:-}"
  if [[ -z "${version}" ]]; then
    if version="$(git -C "${V2_DIR}" rev-parse --short HEAD 2>/dev/null)"; then
      :
    else
      version=""
    fi
  fi
  # BUNDLE_TS lets the orchestrator share ONE build timestamp across the
  # .rootfs.tar / .raw / .raucb triple so they collate under images/<board>/.
  ts="${BUNDLE_TS:-$(date -u +%Y%m%dT%H%M%SZ)}"
  [[ -n "${version}" ]] || version="${ts}"

  log_info "board=${board} compatible=${compatible} version=${version}"

  # Assemble bundle content in a scratch dir.
  local content image
  content="$(mktemp -d)"
  trap 'rm -rf "${content}"' RETURN
  image="$(stage_rootfs "${rootfs_src}" "${content}")"
  write_manifest "${content}/manifest.raucm" "${compatible}" "${version}" "${image}"
  log_info "content staged: manifest.raucm + ${image} ($(du -h "${content}/${image}" | cut -f1))"

  # Output layout for R2 serving (NOT the hawkBit local store).
  local out_dir out
  out_dir="${BUNDLE_OUT_DIR:-${IMAGES_DIR}/${board}/bundles}"
  mkdir -p "${out_dir}"
  out="${out_dir}/${ts}.raucb"

  if [[ "${REPRODUCIBLE}" != "0" ]]; then
    log_info "reproducible mode (REPRODUCIBLE=1) — deterministic OpenSSL CMS signer"
    append_image_checksum "${content}/manifest.raucm" "${content}/${image}"
    bundle_with_openssl "${content}" "${out}"
  elif command -v rauc >/dev/null 2>&1; then
    log_info "REPRODUCIBLE=0 — native rauc bundle (NOT bit-reproducible: rauc bakes a CMS signingTime)"
    bundle_with_rauc "${content}" "${out}"
  else
    append_image_checksum "${content}/manifest.raucm" "${content}/${image}"
    bundle_with_openssl "${content}" "${out}"
  fi

  # Checksum sidecar for the R2 upload step.
  ( cd "${out_dir}" && sha256sum "$(basename "${out}")" >"$(basename "${out}").sha256" )

  log_success "bundle: ${out} ($(du -h "${out}" | cut -f1))"
  log_info "sha256: $(cut -d' ' -f1 <"${out}.sha256")"
  log_info "R2 layout: images/${board}/bundles/$(basename "${out}") — upload to R2; do NOT stage in hawkBit local artifact store"

  printf '%s\n' "${out}"
}

# ---------------------------------------------------------------------------
# Direct-invocation dispatch (sourced by the orchestrator otherwise).
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    -h | --help | "") usage; exit 0 ;;
    *) build-bundle "$@" ;;
  esac
fi
