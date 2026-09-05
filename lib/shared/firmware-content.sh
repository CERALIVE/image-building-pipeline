#!/usr/bin/env bash
# The digest binds the .deb ARCHIVE FILE, never installed or post-prune content.
# Index arguments must come from the existing dual-signature BSP verification.

firmware_content_read() {
  jq -ers '
    if length != 1 then error("expected one firmware pin") else .[0] end |
    if type != "object" then error("expected firmware pin object") else . end |
    if keys != ["architecture","archive_sha256","compressed_bytes","installed_kib","package","version"]
      then error("firmware pin keys differ") else . end |
    if .package != "armbian-firmware-full" or .version != "26.8.3" or .architecture != "all"
      then error("firmware pin identity differs") else . end |
    if (.archive_sha256 | type) != "string" then error("archive SHA256 must be a string") else . end |
    if (.archive_sha256 | length) != 64 or (.archive_sha256 | test("^[0-9a-f]{64}$") | not)
      then error("malformed archive SHA256") else . end |
    if .compressed_bytes != 763716604 or .installed_kib != 2283248
      then error("firmware pin size differs") else . end |
    [.package,.version,.architecture,.archive_sha256,.compressed_bytes,.installed_kib] | @tsv
  ' "$1"
}

firmware_content_assert_index() {
  local pin="$1" index="$2" expected actual
  expected="$(firmware_content_read "${pin}")" || return 1
  actual="$(awk '
    BEGIN { RS=""; FS="\n"; OFS="\t" }
    {
      delete fields; delete counts
      for(i=1;i<=NF;i++) {
        colon=index($i,": ")
        if(colon) {key=substr($i,1,colon-1); fields[key]=substr($i,colon+2); counts[key]++}
      }
      if(fields["Package"]=="armbian-firmware-full" && fields["Version"]=="26.8.3") {
        matches++
        split("Package Version Architecture SHA256 Size Installed-Size Filename",required," ")
        for(i in required) if(counts[required[i]]!=1) invalid=1
        print fields["Package"],fields["Version"],fields["Architecture"],fields["SHA256"],fields["Size"],fields["Installed-Size"]
      }
    }
    END {if(matches!=1 || invalid) exit 1}
  ' "${index}")" || return 1
  if [[ "${actual}" != "${expected}" ]]; then
    printf 'firmware archive pin disagrees with authenticated package record\n' >&2
    return 1
  fi
}
