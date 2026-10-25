#!/usr/bin/env bash

# Download the newest CI disk image built from a branch, by default the current one.

set -euo pipefail

DISK_IMAGE="${1:?Usage: download.sh <disk image> [branch]}"
BRANCH="${2:-$(git branch --show-current)}"

read -r run url < <(gh api "repos/{owner}/{repo}/actions/artifacts?name=disk-image&per_page=100" \
    --jq '[.artifacts[] | select(.workflow_run.head_branch == "'"$BRANCH"'" and (.expired | not))]
        | sort_by(.created_at) | last | "\(.workflow_run.id) \(.archive_download_url)"')
if [[ $url == null ]]; then
    echo "No disk-image artifact found for ${BRANCH}." >&2
    exit 1
fi

echo "Downloading the disk image from run ${run}."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# GitHub redirects to a short-lived URL, which aria2c downloads in parallel.
aria2c -x 16 -s 16 --console-log-level=warn --summary-interval=0 --download-result=hide -d "$tmp" -o artifact.zip \
    "$(curl -fsS -o /dev/null -w '%{redirect_url}' -H "Authorization: Bearer $(gh auth token)" "$url")"
mkdir -p "$(dirname "$DISK_IMAGE")"
unzip -p "$tmp/artifact.zip" "$(basename "$DISK_IMAGE").zst" | zstd -d -f -o "$DISK_IMAGE"
