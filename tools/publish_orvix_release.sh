#!/usr/bin/env bash
set -euo pipefail

# Publish an Orvix release atomically from the updater's point of view.
#
# gh release create TAG asset1 asset2 ... exposes the public release before
# every asset upload is necessarily visible. An already-open Orvix client can
# hit that window and see a newer tag without its platform installer.
#
# This helper keeps the release private as a draft until every expected asset
# exists and is non-empty, then publishes it as a prerelease in one final step.

if [[ $# -lt 5 ]]; then
  echo "usage: $0 <tag> <title> <notes-file> <target-sha> <asset> [asset...]" >&2
  exit 64
fi

tag="$1"
title="$2"
notes_file="$3"
target_sha="$4"
shift 4
assets=("$@")

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"

for asset in "${assets[@]}"; do
  if [[ ! -s "$asset" ]]; then
    echo "release asset is missing or empty: $asset" >&2
    exit 1
  fi
done

if gh release view "$tag" >/dev/null 2>&1; then
  echo "release already exists: $tag" >&2
  exit 1
fi

gh release create "$tag"   --draft   --target "$target_sha"   --title "$title"   --notes-file "$notes_file"

cleanup_draft() {
  echo "release publication failed; $tag remains a private draft" >&2
}
trap cleanup_draft ERR

gh release upload "$tag" "${assets[@]}"

expected_count="${#assets[@]}"
actual_count="$(gh api "repos/$GITHUB_REPOSITORY/releases/tags/$tag" --jq '.assets | length')"
if [[ "$actual_count" -ne "$expected_count" ]]; then
  echo "expected $expected_count uploaded assets, found $actual_count" >&2
  exit 1
fi

for asset in "${assets[@]}"; do
  name="$(basename "$asset")"
  found="$(gh api "repos/$GITHUB_REPOSITORY/releases/tags/$tag"     --jq --arg name "$name" '[.assets[] | select(.name == $name and .size > 0)] | length')"
  if [[ "$found" -ne 1 ]]; then
    echo "release asset was not published exactly once or is empty: $name" >&2
    exit 1
  fi
done

# Public visibility happens only after the updater assets are complete.
gh release edit "$tag" --draft=false --prerelease

trap - ERR
echo "published $tag with $expected_count verified assets"
