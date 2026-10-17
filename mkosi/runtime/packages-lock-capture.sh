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

# mkosi >= 25 syncs apt's gpgv-verified InRelease/Packages ONCE per build into a
# package-manager metadata cache and bind-mounts it onto /var/lib/apt/lists only
# for the duration of an actual apt/dpkg transaction; it is never copied into the
# built rootfs, so /var/lib/apt/lists is permanently empty by the time any
# postinst/finalize script runs, on every layer, regardless of
# CleanPackageMetadata=. The verified index still exists on disk: mkosi's
# metadata-cache directory ("<cache-directory>/<cache_key>.metadata.cache/") is a
# plain subdirectory of $SRCDIR and stays mounted here even after a mkosi-chroot
# re-root into /buildroot (mkosi re-binds /work on top of the remap), so it is
# read as a fallback. CERALIVE_MKOSI_CACHE_DIR (orchestrate.sh) names the exact
# per-board/per-privilege-domain leaf; the <cache_key> prefix is globbed rather
# than hardcoded so a future mkosi renaming it does not silently defeat this
# check.
apt_lists_dirs=(/var/lib/apt/lists)
if [[ -n "${CERALIVE_MKOSI_CACHE_DIR:-}" ]]; then
  apt_lists_dirs+=("${source_dir}/${CERALIVE_MKOSI_CACHE_DIR}"/*.metadata.cache/lib/apt/lists)
fi

lists=()
for apt_lists_dir in "${apt_lists_dirs[@]}"; do
  lists+=("${apt_lists_dir}"/*deb.debian.org*_Packages*)
done
(( ${#lists[@]} > 0 )) || { log_error "$layer: no apt-verified Debian Packages lists"; exit 1; }
for list in "${lists[@]}"; do
  /usr/lib/apt/apt-helper cat-file "$list" >>"$index"
  printf '\n' >>"$index"
done

# Debian legitimately re-publishes the SAME package/version/sha256 across
# multiple suites (trixie-security commonly mirrors a trixie entry byte-for-byte
# under a different pool path), and this layer's index now spans all three
# forwarded suites (APT_SUITE*) at once. auth_lookup_package requires EXACTLY
# ONE matching stanza, so an unambiguous package that happens to be verified
# twice would otherwise read as "not found". Collapse stanzas that agree on
# name+version+arch+sha256 to one; stanzas that DISAGREE on sha256 for the same
# name+version+arch are left as distinct rows, so that real ambiguity still
# fails the lookup exactly as before.
index_dedup="$work/Packages.dedup"
awk -v RS='' -v ORS='\n\n' '
  {
    pkg = ""; ver = ""; arch = ""; sha = ""
    n = split($0, ln, "\n")
    for (i = 1; i <= n; i++) {
      if (ln[i] ~ /^Package: /) pkg = substr(ln[i], 10)
      else if (ln[i] ~ /^Version: /) ver = substr(ln[i], 10)
      else if (ln[i] ~ /^Architecture: /) arch = substr(ln[i], 15)
      else if (ln[i] ~ /^SHA256: /) sha = substr(ln[i], 9)
    }
    key = pkg SUBSEP ver SUBSEP arch SUBSEP sha
    if (!(key in seen)) { seen[key] = 1; print }
  }
' "$index" >"$index_dedup"
mv "$index_dedup" "$index"

# Packages named on the command line are excluded from THIS layer's Debian-
# archive check because they are BSP/first-party origin, verified separately by
# the host-side fetch stage's own receipt (staging/packages-lock/*.jsonl, folded
# in by the final [6d/9] merge) — never by an apt index. That exclusion is a
# per-INVOCATION argument, though, and only the layer that actually installs a
# given BSP package (platform, for the kernel/DTB/U-Boot/firmware set) lists it.
# A LATER layer's dpkg status still carries that package (it stays installed),
# but that layer's own invocation never names it as excluded, so without a
# persistent record the "previously accounted for" check below cannot see it and
# tries — and fails — to verify a non-Debian package against the Debian archive.
# excluded.tsv is that record: written once, by whichever layer's exclusion list
# first names an installed package, and read by every later layer alongside the
# .jsonl receipts. It ships in the same directory the .jsonl receipts already
# do; packages-lock.py only globs *.jsonl, so this file is inert to it.
excluded_marker="$receipts/excluded.tsv"
: >>"$excluded_marker"

previous="$work/previous"
: >"$previous"
for receipt in "$receipts"/*.jsonl; do
  [[ -f "$receipt" ]] || continue
  awk -F'"' '{print $4 "\t" $8 "\t" $12}' "$receipt" >>"$previous"
done
cat "$excluded_marker" >>"$previous"
output="$receipts/$layer.jsonl"
: >"$output"
dpkg-query -W -f='${Package}\t${Version}\t${Architecture}\t${Status}\n' >"$work/status"
while IFS=$'\t' read -r name version arch status; do
  [[ "$status" == *' ok installed' ]] || continue
  skip=0
  for excluded in "$@"; do
    [[ "$name" != "$excluded" ]] || skip=1
  done
  if (( skip == 1 )); then
    printf '%s\t%s\t%s\n' "$name" "$version" "$arch" >>"$excluded_marker"
    continue
  fi
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
for apt_lists_dir in "${apt_lists_dirs[@]}"; do
  for release in "${apt_lists_dir}"/*deb.debian.org*_InRelease; do
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
done
