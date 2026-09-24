#!/usr/bin/env bash
set -euo pipefail

layer="${1:?layer required}"
shift
case "$layer" in base|platform|runtime|app) ;; *) exit 2 ;; esac
source_dir="${SRCDIR:-${CHROOT_SRCDIR:-}}"
: "${source_dir:?mkosi source mount required for verified index helpers}"
: "${APT_SUITE:?suite must be forwarded by orchestrator}"
: "${APT_SUITE_UPDATES:?updates suite must be forwarded by orchestrator}"
: "${APT_SUITE_SECURITY:?security suite must be forwarded by orchestrator}"
source "${source_dir}/lib/fetch-debs-auth.sh"
source "${source_dir}/lib/fetch/index.sh"
log_error() { printf 'packages lock: %s\n' "$*" >&2; }

receipts=/usr/lib/ceralive/build-lock
mkdir -p "$receipts"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
index="$work/Packages"
: >"$index"
shopt -s nullglob
lists=(/var/lib/apt/lists/*deb.debian.org*_Packages*)
(( ${#lists[@]} > 0 )) || { log_error "$layer: no apt-verified Debian Packages lists"; exit 1; }
for list in "${lists[@]}"; do
  /usr/lib/apt/apt-helper cat-file "$list" >>"$index"
  printf '\n' >>"$index"
done

previous="$work/previous"
: >"$previous"
for receipt in "$receipts"/*.jsonl; do
  [[ -f "$receipt" ]] || continue
  awk -F'"' '{print $4 "\t" $8 "\t" $12}' "$receipt" >>"$previous"
done
output="$receipts/$layer.jsonl"
: >"$output"
dpkg-query -W -f='${Package}\t${Version}\t${Architecture}\t${Status}\n' >"$work/status"
while IFS=$'\t' read -r name version arch status; do
  [[ "$status" == *' ok installed' ]] || continue
  skip=0
  for excluded in "$@"; do
    [[ "$name" != "$excluded" ]] || skip=1
  done
  (( skip == 0 )) || continue
  if awk -F'\t' -v n="$name" -v v="$version" -v a="$arch" \
      '$1==n && $2==v && $3==a {found=1} END {exit !found}' "$previous"; then
    continue
  fi
  row="$(index_lookup_optional "$index" "$name" "$version" "$arch")" || {
    log_error "$layer: newly installed $name=$version/$arch has no verified Debian Packages SHA256"
    exit 1
  }
  IFS=$'\t' read -r _filename sha resolved_version <<<"$row"
  [[ "$resolved_version" == "$version" && "$sha" =~ ^[0-9a-f]{64}$ ]] || exit 1
  printf '{"name":"%s","version":"%s","arch":"%s","origin":"debian","sha256":"%s"}\n' \
    "$name" "$version" "$arch" "$sha" >>"$output"
done < "$work/status"

dates="$receipts/$layer.dates"
: >"$dates"
for release in /var/lib/apt/lists/*deb.debian.org*_InRelease; do
  [[ -f "$release" ]] || continue
  suite="${release##*_dists_}"
  suite="${suite%_InRelease}"
  case "$suite" in
    "$APT_SUITE"|"$APT_SUITE_UPDATES"|"$APT_SUITE_SECURITY") ;;
    *) continue ;;
  esac
  date="$(awk '/^Date: / {sub(/^Date: /, ""); print; exit}' "$release")"
  [[ -n "$date" ]] || { log_error "$layer: missing Release Date for $suite"; exit 1; }
  printf '%s\t%s\n' "$suite" "$date" >>"$dates"
done
