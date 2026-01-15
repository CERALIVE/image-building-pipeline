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

set -e

CHANNEL="${CHANNEL:-stable}"
ARCH="${ARCH:-arm64}"
DEST="${DEST:-./debs}"

echo "=== Fetch Debian Packages ==="
echo "Channel: ${CHANNEL}"
echo "Arch: ${ARCH}"
echo "Destination: ${DEST}"
echo ""

mkdir -p "$DEST"

# List of repos to fetch from
REPOS=("srtla" "srt" "ceracoder" "CeraUI")

if [[ -n "$R2_ACCESS_KEY_ID" ]]; then
    echo "CI mode: Fetching from R2..."
    
    # Configure AWS CLI for R2
    aws configure set aws_access_key_id "$R2_ACCESS_KEY_ID"
    aws configure set aws_secret_access_key "$R2_SECRET_ACCESS_KEY"
    
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
    echo ""
    echo "Warning: No .deb packages were fetched!"
    echo "This may cause the image build to fail."
    exit 0  # Don't fail the script, let the build decide
fi

echo ""
echo "=== Fetch Complete ==="
echo "Packages ready in: ${DEST}"
