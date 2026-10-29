#!/usr/bin/env bash
# Verbatim kernel_check_bootstrap_state from apt-worker e43c860beb3001df9e860511bf5be95d44a0183c.
# Test-only publisher boundary snapshot; the producer must not enforce eligibility.
kernel_check_bootstrap_state() {
  local keys key found=false receipt=false index="$STAGING_DIR/kernel-prior-index"
  keys="$(aws s3api list-objects-v2 --bucket "$R2_BUCKET" --prefix kernel-publications/ \
    --endpoint-url "$R2_ENDPOINT" --query 'Contents[].Key' --output text)" \
    || die 'Kernel bootstrap receipt inventory failed'
  for key in $keys; do
    [[ "$key" == None ]] && continue
    if [[ "$key" == "$KERNEL_BOOTSTRAP_KEY" ]]; then
      # Its bytes are checked by kernel_receipt before any write, including replay.
      found=true
      receipt=true
      continue
    fi
    [[ "$key" == "$KERNEL_RECEIPT_KEY" || "$key" == "$KERNEL_COMPLETE_KEY" ]] \
      || die 'Kernel bootstrap refused: prior different publication receipt'
    found=true
    [[ "$key" != "$KERNEL_RECEIPT_KEY" ]] || receipt=true
  done
  keys="$(aws s3api list-objects-v2 --bucket "$R2_BUCKET" --prefix dists/ \
    --endpoint-url "$R2_ENDPOINT" --query 'Contents[].Key' --output text)" \
    || die 'Kernel bootstrap pool inventory failed'
  for key in $keys; do
    if [[ "$key" =~ /linux-image-[0-9]+\.[0-9]+\.[0-9]+-ceralive-rk3588_.*\.deb$ ]]; then
      found=true
      [[ "$key" == "dists/$CHANNEL/binary-arm64/${KERNEL_PACKAGE}_${VERSION}_arm64.deb" ]] \
        || die 'Kernel bootstrap refused: prior different pool publication'
    elif [[ "$key" == dists/*/binary-*/Packages ]]; then
      aws s3 cp "s3://$R2_BUCKET/$key" "$index" --endpoint-url "$R2_ENDPOINT" --no-progress \
        || die 'Kernel bootstrap prior index unreadable'
      if grep -Eq '^Package: linux-image-[0-9]+\.[0-9]+\.[0-9]+-ceralive-rk3588$' "$index"; then
        found=true
        [[ "$key" == "dists/$CHANNEL/binary-arm64/Packages" ]] \
          || die 'Kernel bootstrap refused: prior different index channel or architecture'
        awk -v pkg="$KERNEL_PACKAGE" -v ver="$VERSION" -v sha="$KERNEL_ARTIFACT_SHA256" '
          BEGIN { RS=""; FS="\n" }
          {
            delete f
            for (i=1; i<=NF; i++) { n=index($i, ": "); if(n) f[substr($i,1,n-1)]=substr($i,n+2) }
            if (f["Package"] ~ /^linux-image-[0-9]+\.[0-9]+\.[0-9]+-ceralive-rk3588$/ &&
                (f["Package"] != pkg || f["Version"] != ver || f["SHA256"] != sha ||
                 f["Architecture"] != "arm64")) bad=1
          }
          END { exit bad }
        ' "$index" || die 'Kernel bootstrap refused: prior different index publication'
      fi
    fi
  done
  if $found && ! $receipt; then
    die 'Kernel bootstrap refused: existing kernel lacks identical authorization receipt'
  fi
}
