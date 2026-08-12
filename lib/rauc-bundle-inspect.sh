#!/usr/bin/env bash
set -euo pipefail

rauc_bundle_verify_and_compatible() {
  local bundle="$1" keyring="$2" work total trailer sig_len payload_len compatible
  work="$(mktemp -d)"
  total="$(stat -c '%s' "$bundle")"
  trailer="$(tail -c 8 "$bundle" | od -An -tx1 | tr -d ' \n')"
  [[ "$trailer" =~ ^[0-9a-f]{16}$ ]] || { rm -rf "$work"; return 1; }
  sig_len=$((16#$trailer))
  payload_len=$((total - 8 - sig_len))
  (( payload_len > 0 && sig_len > 0 )) || { rm -rf "$work"; return 1; }
  head -c "$payload_len" "$bundle" >"$work/payload.squashfs"
  tail -c "$((sig_len + 8))" "$bundle" | head -c "$sig_len" >"$work/signature.cms"
  openssl cms -verify -binary -inform DER -in "$work/signature.cms" \
    -content "$work/payload.squashfs" -CAfile "$keyring" -purpose any \
    -out /dev/null 2>"$work/verify.log" || { cat "$work/verify.log" >&2; rm -rf "$work"; return 1; }
  unsquashfs -no-progress -cat "$work/payload.squashfs" manifest.raucm >"$work/manifest.raucm" \
    || { rm -rf "$work"; return 1; }
  compatible="$(sed -n 's/^compatible=//p' "$work/manifest.raucm" | head -1)"
  rm -rf "$work"
  [[ -n "$compatible" ]] || return 1
  printf '%s\n' "$compatible"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  [[ $# -eq 2 ]] || exit 2
  rauc_bundle_verify_and_compatible "$1" "$2"
fi
