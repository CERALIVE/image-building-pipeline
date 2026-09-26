#!/usr/bin/env bash

fetch_lock_sidecar() {
  [[ -z "${DRY_RUN}" ]] || return 0
  local target="${DEST}/packages-lock/fetch.jsonl" deb name version arch record filename digest resolved rc origin _url override_arch
  local bsp_index="${_BSP_APT_INDEX:-${_PKG_INDEX:-}}"
  local firstparty_index="${_FIRST_PARTY_INDEX:-}"
  [[ -n "$firstparty_index" ]] || firstparty_index="$(debcache_apt_index "${DEST}/debs/.apt-state-firstparty")"
  mkdir -p "$(dirname "$target")"
  : >"$target"
  shopt -s nullglob
  for deb in "${DEST}/debs/"*.deb; do
    name="$(deb_pkg_name "$deb")"
    version="$(deb_pkg_version "$deb")"
    arch="$(deb_pkg_arch "$deb")"
    [[ -n "$name" && -n "$version" && -n "$arch" ]] || die "invalid staged .deb identity: $deb"
    [[ "$name" != libv4l-0 ]] || continue
    [[ "$name" != linux-image-* ]] || continue
    record="$(rk3588_userspace_record "$name")"
    if [[ -n "$record" ]]; then
      IFS=$'\t' read -r filename digest _url <<<"$record"
      origin=userspace-pin
    elif [[ " ${FIRST_PARTY_APT_PKGS[*]} " == *" $name "* ]]; then
      record="$(python3 - "${DEST}/first-party-local-override.json" "$name" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as source:
    matches = [row for row in json.load(source) if row["package"] == sys.argv[2]]
assert len(matches) <= 1
if matches:
    row = matches[0]
    print(row["filename"], row["sha256"], row["version"], row["arch"], sep="\t")
PY
)" || die "invalid first-party local override manifest for $name"
      if [[ -n "$record" ]]; then
        IFS=$'\t' read -r filename digest resolved override_arch <<<"$record"
        [[ "$override_arch" == "$arch" ]] || die "first-party local override architecture mismatch for $name=$version/$arch"
        origin=first-party-local-override
      else
        [[ -n "$firstparty_index" ]] || die "first-party verified Packages index missing for $name"
        rc=0
        record="$(index_lookup_optional "$firstparty_index" "$name" "$version" "$ARCH")" || rc=$?
        (( rc == 0 )) || die "first-party verified Packages digest missing for $name=$version/$arch"
        IFS=$'\t' read -r filename digest resolved <<<"$record"
        origin=first-party
      fi
    else
      [[ -n "$bsp_index" ]] || die "BSP verified Packages index missing for $name"
      rc=0
      record="$(index_lookup_optional "$bsp_index" "$name" "$version" "$ARCH")" || rc=$?
      (( rc == 0 )) || die "BSP verified Packages digest missing for $name=$version/$arch"
      IFS=$'\t' read -r filename digest resolved <<<"$record"
      origin=bsp
    fi
    [[ "$(basename "$filename")" == "$(basename "$deb")" && "$digest" =~ ^[0-9a-f]{64}$ ]] \
      || die "verified digest identity mismatch for $name=$version/$arch: $filename"
    [[ "$origin" == userspace-pin || "$resolved" == "$version" ]] \
      || die "verified index version differs from staged $name=$version/$arch"
    [[ "$origin" != first-party-local-override || "$(sha256sum "$deb" | cut -d' ' -f1)" == "$digest" ]] \
      || die "verified digest identity mismatch for $name=$version/$arch: $filename"
    printf '{"name":"%s","version":"%s","arch":"%s","origin":"%s","sha256":"%s"}\n' \
      "$name" "$version" "$arch" "$origin" "$digest" >>"$target"
  done
  shopt -u nullglob
}
