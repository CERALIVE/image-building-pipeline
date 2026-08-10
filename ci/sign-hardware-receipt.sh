#!/usr/bin/env bash
#
# sign-hardware-receipt.sh — canonicalize and sign a hardware-evidence receipt.
#
# The signature covers the receipt's RFC 8785 canonical BYTES, so this tool
# rewrites the receipt in place as canonical JSON first. A receipt that were
# signed as authored and reformatted later would verify against nothing;
# canonicalize-then-sign is what makes `verify-hardware-receipt.py`'s
# byte-for-byte canonicality check a check rather than a coincidence.
#
# Optionally recomputes the digests the receipt asserts (`--refresh-digests`),
# so a signer cannot certify a stale command-manifest or decisive-log hash.
#
# Usage:
#   sign-hardware-receipt.sh --receipt <file.json> --key <ed25519.pem>
#                            [--evidence-root <dir>] [--refresh-digests]
#                            [--out <file.json.sig>] [--pubkey-out <file.pem>]
#
# The key is the RUN-SCOPED evidence key created by todo 42, held outside every
# repository at mode 0600. This tool never creates one and never copies one into
# a repository.
#
# shellcheck shell=bash

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFIER="${HERE}/verify-hardware-receipt.py"

receipt="" key="" out="" pubkey_out="" evidence_root="" refresh=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --receipt) receipt="${2:-}"; shift 2 ;;
    --key) key="${2:-}"; shift 2 ;;
    --out) out="${2:-}"; shift 2 ;;
    --pubkey-out) pubkey_out="${2:-}"; shift 2 ;;
    --evidence-root) evidence_root="${2:-}"; shift 2 ;;
    --refresh-digests) refresh=1; shift ;;
    -h|--help) sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[[ -n "${receipt}" && -n "${key}" ]] || { printf -- '--receipt and --key are required\n' >&2; exit 2; }
[[ -f "${receipt}" ]] || { printf 'receipt not found: %s\n' "${receipt}" >&2; exit 1; }
[[ -f "${key}" && ! -L "${key}" ]] || { printf 'evidence key not found: %s\n' "${key}" >&2; exit 1; }
[[ "$(stat -c %a "${key}")" == 600 ]] \
  || { printf 'evidence key must be mode 0600: %s\n' "${key}" >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { printf 'openssl is required\n' >&2; exit 1; }

[[ -n "${evidence_root}" ]] || evidence_root="$(cd "$(dirname -- "${receipt}")" && pwd)"
[[ -n "${out}" ]] || out="${receipt%.json}.json.sig"

if (( refresh == 1 )); then
  python3 - "${receipt}" "${evidence_root}" <<'PY'
import hashlib, json, sys
from pathlib import Path

receipt_path, root = Path(sys.argv[1]), Path(sys.argv[2])
receipt = json.loads(receipt_path.read_text())


def digest(relative: str) -> str:
    return hashlib.sha256((root / relative).read_bytes()).hexdigest()


receipt["command_manifest"]["sha256"] = digest(receipt["command_manifest"]["path"])
for entry in receipt["decisive_logs"]:
    entry["sha256"] = digest(entry["path"])
receipt_path.write_text(json.dumps(receipt))
PY
fi

python3 "${VERIFIER}" --canonicalize "${receipt}"
openssl pkeyutl -sign -rawin -inkey "${key}" -in "${receipt}" -out "${out}"
chmod 644 "${out}"
if [[ -n "${pubkey_out}" ]]; then
  openssl pkey -in "${key}" -pubout -out "${pubkey_out}"
fi

fingerprint="sha256:$(openssl pkey -in "${key}" -pubout -outform DER | sha256sum | cut -d' ' -f1)"
printf 'SIGNED receipt=%s signature=%s evidence_key_fingerprint=%s\n' \
  "${receipt}" "${out}" "${fingerprint}"
