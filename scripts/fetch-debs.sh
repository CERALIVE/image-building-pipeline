#!/bin/bash
# Fetch Debian packages from R2 (CI mode) or GitHub releases (local mode)
#
# Environment variables:
#   CHANNEL - stable or beta (default: stable)
#   ARCH    - arm64 or amd64 (default: arm64)
#   DEST    - destination directory (default: ./debs)
#
# CI mode (R2_ACCESS_KEY_ID set):
#   Fetches from R2 bucket using AWS CLI
#
# Local mode (no R2 credentials):
#   Fetches from GitHub releases using gh CLI

set -euo pipefail

CHANNEL="${CHANNEL:-stable}"
ARCH="${ARCH:-arm64}"
DEST="${DEST:-./debs}"

# Read a pin value from versions.yaml (graceful fallback: returns "" if absent)
# Usage: get_pin <key> [registry_file]
VERSIONS_YAML="${VERSIONS_YAML:-$(dirname "$0")/../../versions.yaml}"
get_pin() {
  local key="$1" file="${2:-$VERSIONS_YAML}"
  [[ -f "$file" ]] || { echo ""; return; }
  awk -v key="$key" '$0==key":"{f=1;next} f&&/^[a-zA-Z]/{f=0}
    f&&/^[[:space:]]+pin:/{gsub(/^[[:space:]]+pin:[[:space:]]*/,"");print;exit}' "$file"
}

echo "=== Fetch Debian Packages ==="
echo "Channel: ${CHANNEL}"
echo "Arch: ${ARCH}"
echo "Destination: ${DEST}"
echo ""

mkdir -p "$DEST"

REPOS=("srtla" "srt" "ceracoder" "CeraUI")

for _r in "${REPOS[@]}"; do
  _pin="$(get_pin "$_r")"
  echo "PIN: ${_r}=${_pin:-latest}"
done
echo ""

if [[ -n "${R2_ACCESS_KEY_ID:-}" ]]; then
    echo "CI mode: Fetching from R2..."

    [[ -n "${R2_SECRET_ACCESS_KEY:-}" ]] || { echo "Error: R2_SECRET_ACCESS_KEY unset in CI mode." >&2; exit 1; }
    [[ -n "${R2_BUCKET:-}" ]]            || { echo "Error: R2_BUCKET unset in CI mode." >&2; exit 1; }
    [[ -n "${R2_ENDPOINT:-}" ]]          || { echo "Error: R2_ENDPOINT unset in CI mode." >&2; exit 1; }

    # Env-only creds: never persist to ~/.aws/credentials on disk (CI security risk).
    export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
    export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
    export AWS_DEFAULT_REGION="${R2_REGION:-auto}"

    # Sync all .deb files from the channel/arch path
    aws s3 sync \
        "s3://${R2_BUCKET}/dists/${CHANNEL}/binary-${ARCH}/" \
        "$DEST/" \
        --endpoint-url "$R2_ENDPOINT" \
        --exclude "*" \
        --include "*.deb"
    
    echo "Downloaded from R2:"
    ls -la "$DEST"/*.deb 2>/dev/null || echo "No .deb files found"
else
    echo "Local mode: Fetching from GitHub releases..."
    
    # Check if gh CLI is available
    if ! command -v gh &> /dev/null; then
        echo "Error: gh CLI not found. Install it with: https://cli.github.com/"
        echo "Or set R2_* environment variables to use CI mode."
        exit 1
    fi
    
    # Check if authenticated
    if ! gh auth status &> /dev/null; then
        echo "Warning: gh CLI not authenticated. Run 'gh auth login' for private repos."
    fi
    
    for repo in "${REPOS[@]}"; do
        echo "Fetching from CERALIVE/${repo}..."
        
        # Determine release filter based on channel
        if [[ "$CHANNEL" == "beta" ]]; then
            # For beta, include prereleases
            RELEASE_FLAG=""
        else
            # For stable, exclude prereleases
            RELEASE_FLAG="--exclude-pre-releases"
        fi
        
        # Try to download matching .deb files
        gh release download \
            --repo "CERALIVE/${repo}" \
            --pattern "*${ARCH}*.deb" \
            --dir "$DEST" \
            $RELEASE_FLAG \
            2>/dev/null || echo "  No matching releases found for ${repo}"
    done
    
    echo ""
    echo "Downloaded from GitHub:"
    ls -la "$DEST"/*.deb 2>/dev/null || echo "No .deb files found"
fi

# Verify we got some packages
if ! ls "$DEST"/*.deb 1>/dev/null 2>&1; then
    echo "" >&2
    echo "Error: No .deb packages were fetched into ${DEST}." >&2
    echo "Expected packages for: ${REPOS[*]} (channel=${CHANNEL}, arch=${ARCH})." >&2
    echo "Check R2 credentials / GitHub release availability before building the image." >&2
    exit 1
fi

echo ""
echo "=== Fetch Complete ==="
echo "Packages ready in: ${DEST}"
