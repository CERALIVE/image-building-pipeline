#!/usr/bin/env bash
#
# build-feature-sysext.sh — build a SIGNED per-board/per-OS feature sysext (.raw)
# from a `.deb` staging tree (Stage 3, task 24).
#
#     build-feature-sysext.sh --feature <name> --board <board> --os-version <ver> \
#                             --deb-staging <dir> --out <dir> [--keyring <gpg-home>]
#
# WHAT IT DOES
#   1. Validates the staging tree against the sysext payload boundary (G2): a
#      systemd-sysext overlays ONLY /usr and /opt, so a staging tree that carries
#      a top-level /etc or /var is REFUSED — those paths are silently lost at
#      merge time and shipping them is a latent bug, not a warning.
#   2. Reuses lib/app-layer/sysext.sh::build_app_layer to squash the /usr+/opt
#      subtrees into a `.raw`, with the extension-release matching file the kernel
#      keys merging on. G1 is pinned here: SYSEXT_LEVEL=1 (the version-decoupled
#      ABI axis) and VERSION_ID=<os-version> (12 for the bookworm stack). The
#      produced extension-release is read BACK out of the squashfs and asserted to
#      carry both — the guard has teeth, it does not merely trust the defaults.
#   3. Names the artifact per-board/per-OS: <feature>-<board>-<os_version>.raw.
#   4. SIGNS it: a sha256 sidecar (.raw.sha256) AND a DETACHED GPG signature
#      (.raw.sig). This mirrors the sha256+detached-signature contract the RAUC
#      bundle path uses (lib/build-bundle.sh), but in a SEPARATE TRUST DOMAIN —
#      add-on signing NEVER reuses the RAUC keyring (cert-work/rauc). The public
#      half of the signing key is exported alongside as addon-keyring.gpg so the
#      artifact is independently verifiable (and matches the image-baked keyring).
#   5. SELF-VERIFIES the detached signature with gpgv against that exported public
#      keyring before declaring success (signing is exercised, never faked).
#
# SIGNING CONTRACT (the add-on artifact trust model)
#   For every published add-on `.raw` the fleet trusts on evidence of TWO facts:
#     * integrity  — sha256(<raw>) matches the committed `.raw.sha256` sidecar.
#     * authenticity — gpgv --keyring /usr/share/ceralive/addon-keyring.gpg \
#                            <raw>.sig <raw>   verifies the detached signature
#                      against the image-baked add-on PUBLIC keyring.
#   The add-on keyring is a DISTINCT trust anchor from the RAUC root CA
#   (/etc/rauc/ceralive-keyring.pem): RAUC signs the OS A/B slots, this key signs
#   optional add-on payloads. Compromise of one domain must not grant the other.
#
# KEYS
#   --keyring <gpg-home>  a GnuPG home directory holding the add-on signing SECRET
#                         key. In CI the real key is injected this way. For local
#                         and test builds it defaults to v2/.dev-addon-keys/gnupg,
#                         a THROWAWAY keypair generated on first use (gitignored,
#                         exactly like the RAUC dev keypair in v2/.dev-keys). It is
#                         a SEPARATE keypair from the RAUC dev keys — add-on signing
#                         is its own trust domain.
#
# DESIGN RULES (inherited from lib/common.sh): strict mode, loud ERR trap, and
# absolutely NO `|| true` error swallowing.
#
# shellcheck shell=bash

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${HERE}/common.sh"
# build_app_layer + the G1 SYSEXT_LEVEL/VERSION_ID matching machinery live here.
# shellcheck source=lib/app-layer/sysext.sh
source "${HERE}/app-layer/sysext.sh"

V2_DIR="$(cd "${HERE}/.." && pwd)"

# Throwaway DEV add-on signing home. SEPARATE from v2/.dev-keys (RAUC) — distinct
# trust domain. Generated on first use, gitignored. CI overrides via --keyring.
DEV_ADDON_KEYS_DIR="${CERALIVE_ADDON_KEYS_DIR:-${V2_DIR}/.dev-addon-keys}"
DEV_ADDON_GNUPGHOME="${DEV_ADDON_KEYS_DIR}/gnupg"

usage() {
  cat >&2 <<EOF
Usage: build-feature-sysext.sh --feature <name> --board <board> \\
         --os-version <ver> --deb-staging <dir> --out <dir> \\
         [--descriptor <path>] [--keyring <gpg-home>]

Builds a SIGNED per-board/per-OS feature sysext (.raw) from a .deb staging tree
and emits, into <out>:
  <feature>-<board>-<os_version>.raw         the squashfs sysext (/usr+/opt only)
  <feature>-<board>-<os_version>.raw.sha256  integrity sidecar
  <feature>-<board>-<os_version>.raw.sig     detached GPG signature
  addon-keyring.gpg                          PUBLIC keyring that verifies .raw.sig

Args:
  --feature <name>      add-on/feature id (descriptor stem), e.g. debug-toolset.
  --board <board>       board id the artifact is built for, e.g. rock-5b-plus.
  --os-version <ver>    OS VERSION_ID the artifact targets. Default: 12 (bookworm).
                        Baked into the extension-release as VERSION_ID (G1).
  --deb-staging <dir>   extracted .deb staging tree (a filesystem root). ONLY the
                        /usr and /opt subtrees cross the sysext boundary (G2); a
                        top-level /etc or /var is REJECTED.
  --out <dir>           output directory for the artifacts above.
  --descriptor <path>   add-on descriptor JSON to schema-validate before building.
                        Default: manifests/addons/<feature>.json. A PRESENT
                        descriptor that fails addon.schema.json ABORTS the build
                        (C6b fail-fast); an absent one is skipped (synthetic
                        features have no catalogue descriptor).
  --keyring <gpg-home>  GnuPG home dir holding the add-on signing SECRET key.
                        Default: ${DEV_ADDON_GNUPGHOME}
                        (throwaway dev keypair, generated on first use).

Env:
  CERALIVE_ADDON_KEYS_DIR  override the dev keys dir (default v2/.dev-addon-keys).
  SOURCE_DATE_EPOCH        clamps the squashfs mtime for reproducible artifacts.
EOF
}

# ---------------------------------------------------------------------------
# assert_payload_boundary <deb-staging> — G2: a systemd-sysext overlays ONLY
# /usr and /opt. A staging tree that carries a TOP-LEVEL /etc or /var would have
# those paths silently dropped at merge time; that is a packaging bug, so refuse
# to build rather than ship an extension that is missing the config it thinks it
# installed.
# ---------------------------------------------------------------------------
assert_payload_boundary() {
  local staging="$1" sub
  for sub in etc var; do
    if [[ -e "${staging}/${sub}" ]]; then
      die "G2 boundary: staging tree carries /${sub} — a sysext overlays ONLY /usr and /opt; move config/state out of the payload (refusing to build)"
    fi
  done
}

# ---------------------------------------------------------------------------
# assert_descriptor_valid <descriptor> — C6b: fail-fast schema gate. The target
# add-on descriptor MUST validate against manifests/schema/addon.schema.json
# BEFORE any build side-effect, reusing ci/validate-manifests.py's single-file
# (--file) mode. Schema validation ONLY; the cross-descriptor G1/G2/E6 semantics
# stay CI-only (they need the whole descriptor set). Errors name the failing path
# and the first jsonschema error, then refuse to build.
# ---------------------------------------------------------------------------
assert_descriptor_valid() {
  local descriptor="$1"
  require_cmd python3
  log_info "validating add-on descriptor against addon.schema.json: ${descriptor}"
  python3 "${V2_DIR}/ci/validate-manifests.py" --file "${descriptor}" \
    || die "add-on descriptor failed schema validation: ${descriptor} (refusing to build)"
  log_success "descriptor schema-valid: ${descriptor}"
}

# ---------------------------------------------------------------------------
# ensure_dev_addon_keyring <gnupg-home> — generate the THROWAWAY add-on signing
# keypair on first use. No passphrase (CI/local automation), signing-only primary.
# Idempotent: a home that already holds a secret key is left untouched.
# ---------------------------------------------------------------------------
ensure_dev_addon_keyring() {
  local home="$1"
  require_cmd gpg

  if [[ -d "${home}" ]] \
       && gpg --homedir "${home}" --list-secret-keys --with-colons 2>/dev/null | grep -q '^sec'; then
    log_info "addon keyring: using existing dev signing key in ${home}"
    return 0
  fi

  log_warn "addon keyring: no signing key in ${home} — generating a THROWAWAY dev keypair (NON-PRODUCTION)"
  mkdir -p "${home}"
  chmod 700 "${home}"

  local params
  params="$(mktemp)"
  cat >"${params}" <<EOF
%no-protection
Key-Type: RSA
Key-Length: 3072
Key-Usage: sign
Name-Real: CeraLive Add-on Signing (DEV)
Name-Email: addon-dev@ceralive.tv
Name-Comment: throwaway non-production add-on signing key
Expire-Date: 0
%commit
EOF
  gpg --homedir "${home}" --batch --gen-key "${params}"
  rm -f "${params}"
  log_success "addon keyring: dev signing keypair generated in ${home}"
}

# ---------------------------------------------------------------------------
# export_pubkeyring <gnupg-home> <out-file> — export the PUBLIC half of the add-on
# signing key as an OpenPGP keyring gpgv can verify against. This is exactly what
# is baked into the image at /usr/share/ceralive/addon-keyring.gpg.
# ---------------------------------------------------------------------------
export_pubkeyring() {
  local home="$1" out="$2"
  require_cmd gpg
  gpg --homedir "${home}" --export >"${out}"
  [[ -s "${out}" ]] || die "addon keyring: exported public keyring is empty (${out})"
}

# ---------------------------------------------------------------------------
# assert_g1 <raw> — read the extension-release back OUT of the squashfs and assert
# it carries SYSEXT_LEVEL=1 and VERSION_ID=<os-version>. The guard does not trust
# the build inputs; it inspects the artifact it just produced.
# ---------------------------------------------------------------------------
assert_g1() {
  local raw="$1" feature="$2" os_version="$3"
  require_cmd unsquashfs

  local tmp rel
  tmp="$(mktemp -d)"
  rel="usr/lib/extension-release.d/extension-release.${feature}"
  unsquashfs -no-progress -d "${tmp}/x" "${raw}" "${rel}" >/dev/null \
    || { rm -rf "${tmp}"; die "G1: extension-release ${rel} missing from ${raw}"; }

  local relfile="${tmp}/x/${rel}"
  grep -qx 'SYSEXT_LEVEL=1' "${relfile}" \
    || { rm -rf "${tmp}"; die "G1: ${rel} does NOT carry SYSEXT_LEVEL=1"; }
  grep -qx "VERSION_ID=${os_version}" "${relfile}" \
    || { rm -rf "${tmp}"; die "G1: ${rel} does NOT carry VERSION_ID=${os_version}"; }
  rm -rf "${tmp}"
  log_success "G1 verified: ${rel} carries SYSEXT_LEVEL=1 + VERSION_ID=${os_version}"
}

# ---------------------------------------------------------------------------
# build-feature-sysext — the task entry point.
# ---------------------------------------------------------------------------
build-feature-sysext() {
  local feature="" board="" os_version="12" deb_staging="" out_dir="" gnupg_home=""
  local descriptor=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --feature)     feature="${2:-}";     shift 2 ;;
      --board)       board="${2:-}";       shift 2 ;;
      --os-version)  os_version="${2:-}";  shift 2 ;;
      --deb-staging) deb_staging="${2:-}"; shift 2 ;;
      --out)         out_dir="${2:-}";     shift 2 ;;
      --descriptor)  descriptor="${2:-}";  shift 2 ;;
      --keyring)     gnupg_home="${2:-}";  shift 2 ;;
      -h | --help)   usage; return 0 ;;
      *) usage; die "unknown argument: $1" ;;
    esac
  done

  [[ -n "${feature}" ]]     || { usage; die "--feature is required"; }
  [[ -n "${board}" ]]       || { usage; die "--board is required"; }
  [[ -n "${os_version}" ]]  || { usage; die "--os-version is required"; }
  [[ -n "${deb_staging}" ]] || { usage; die "--deb-staging is required"; }
  [[ -n "${out_dir}" ]]     || { usage; die "--out is required"; }
  [[ -d "${deb_staging}" ]] || die "--deb-staging dir not found: ${deb_staging}"

  # C6b: fail-fast schema gate — validate the target descriptor BEFORE any build
  # side-effect. Only a PRESENT descriptor is gated; synthetic features (no
  # catalogue descriptor) skip validation and proceed.
  descriptor="${descriptor:-${V2_DIR}/manifests/addons/${feature}.json}"
  if [[ -f "${descriptor}" ]]; then
    assert_descriptor_valid "${descriptor}"
  else
    log_warn "no catalogue descriptor at ${descriptor} — skipping schema validation"
  fi

  gnupg_home="${gnupg_home:-${DEV_ADDON_GNUPGHOME}}"

  require_cmd mksquashfs
  require_cmd gpg
  require_cmd gpgv
  require_cmd sha256sum

  log_info "feature=${feature} board=${board} os_version=${os_version}"
  log_info "deb-staging=${deb_staging} out=${out_dir} keyring=${gnupg_home}"

  # G2: refuse a payload that escapes the /usr+/opt sysext boundary.
  assert_payload_boundary "${deb_staging}"

  # G1: pin the merge identity for build_app_layer. SYSEXT_LEVEL=1 is the stable
  # ABI axis; VERSION_ID tracks the requested OS line (12 for bookworm).
  export SYSEXT_LEVEL=1
  export SYSEXT_OS_VERSION_ID="${os_version}"

  mkdir -p "${out_dir}"
  local stem="${feature}-${board}-${os_version}"

  # Build into a scratch dir under the requested feature name (build_app_layer
  # names the extension-release after <feature>, matching the descriptor stem),
  # then move to the per-board/per-OS artifact name.
  local build_tmp raw
  build_tmp="$(mktemp -d)"
  build_app_layer "${feature}" "${deb_staging}" "${build_tmp}" >/dev/null
  raw="${out_dir}/${stem}.raw"
  mv -f "${build_tmp}/${feature}.raw" "${raw}"
  rm -rf "${build_tmp}"
  log_info "sysext built: ${raw} ($(du -h "${raw}" | cut -f1))"

  # G1 teeth: inspect the produced artifact, do not trust the inputs.
  assert_g1 "${raw}" "${feature}" "${os_version}"

  # Integrity sidecar (sha256), mirroring the RAUC .sha256 convention.
  ( cd "${out_dir}" && sha256sum "$(basename "${raw}")" >"$(basename "${raw}").sha256" )
  log_info "sha256: $(cut -d' ' -f1 <"${raw}.sha256")"

  # Authenticity: detached GPG signature in the add-on trust domain.
  ensure_dev_addon_keyring "${gnupg_home}"
  local pubkeyring="${out_dir}/addon-keyring.gpg"
  export_pubkeyring "${gnupg_home}" "${pubkeyring}"

  local sig="${raw}.sig"
  log_info "signing (detached GPG, add-on trust domain): ${sig}"
  gpg --homedir "${gnupg_home}" --batch --yes --detach-sign --output "${sig}" "${raw}"
  [[ -s "${sig}" ]] || die "detached signature not produced: ${sig}"

  # Self-verify the way the device will: gpgv against the exported public keyring.
  log_info "verifying detached signature against the add-on keyring: ${pubkeyring}"
  gpgv --keyring "${pubkeyring}" "${sig}" "${raw}" 2>/dev/null \
    || die "addon signature did NOT verify against ${pubkeyring} (refusing to ship)"
  log_success "signature verified: ${stem}.raw.sig -> addon-keyring.gpg (add-on trust domain)"

  log_success "feature sysext: ${raw}"
  log_info "artifacts: ${stem}.raw + .raw.sha256 + .raw.sig (+ addon-keyring.gpg)"
  printf '%s\n' "${raw}"
}

# ---------------------------------------------------------------------------
# Direct-invocation dispatch (sourced otherwise — BASH_SOURCE guard).
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    -h | --help | "") usage; exit 0 ;;
    *) build-feature-sysext "$@" ;;
  esac
fi
