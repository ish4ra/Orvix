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

resolve_release_id() {
  gh release view "$tag" --json databaseId --jq '.databaseId' 2>/dev/null || true
}

release_id="$(resolve_release_id)"
if [[ -n "$release_id" ]]; then
  is_draft="$(gh release view "$tag" --json isDraft --jq '.isDraft' 2>/dev/null || true)"
  if [[ "$is_draft" != "true" ]]; then
    echo "non-draft release already exists: $tag" >&2
    exit 1
  fi
  echo "reusing existing private draft $tag (release id $release_id)"
else
  gh release create "$tag" \
    --draft \
    --target "$target_sha" \
    --title "$title" \
    --notes-file "$notes_file"

  # Draft releases are not served by the REST /releases/tags/{tag} endpoint.
  # Resolve them with gh release view, retrying briefly for GitHub's release
  # index to observe the newly-created draft.
  for _ in 1 2 3 4 5 6; do
    release_id="$(resolve_release_id)"
    [[ -n "$release_id" ]] && break
    sleep 2
  done
  if [[ -z "$release_id" ]]; then
    echo "could not resolve draft release id for $tag" >&2
    exit 1
  fi
fi

cleanup_draft() {
  echo "release publication failed; $tag remains a private draft" >&2
}
trap cleanup_draft ERR

# Re-running a failed publication is safe: replace any same-named draft assets.
gh release upload "$tag" --clobber "${assets[@]}"

expected_count="${#assets[@]}"
actual_count="$(gh api "repos/$GITHUB_REPOSITORY/releases/$release_id" --jq '.assets | length')"
if [[ "$actual_count" -ne "$expected_count" ]]; then
  echo "expected $expected_count uploaded assets, found $actual_count" >&2
  exit 1
fi

for asset in "${assets[@]}"; do
  name="$(basename "$asset")"
  found="$(gh api "repos/$GITHUB_REPOSITORY/releases/$release_id" \
    | jq -r --arg name "$name" '[.assets[] | select(.name == $name and .size > 0)] | length')"
  if [[ "$found" -ne 1 ]]; then
    echo "release asset was not published exactly once or is empty: $name" >&2
    exit 1
  fi
done

# Draft releases are not available through /releases/tags/{tag}. Publish by
# concrete release ID only after every updater asset has been verified.
# Beta workflows keep the historical prerelease default. Stable workflows can
# opt out explicitly without maintaining a second release publisher.
release_prerelease="${ORVIX_RELEASE_PRERELEASE:-true}"
if [[ "$release_prerelease" != "true" && "$release_prerelease" != "false" ]]; then
  echo "ORVIX_RELEASE_PRERELEASE must be true or false" >&2
  exit 64
fi

gh api \
  --method PATCH \
  "repos/$GITHUB_REPOSITORY/releases/$release_id" \
  -F draft=false \
  -F prerelease="$release_prerelease" \
  >/dev/null

trap - ERR
echo "published $tag with $expected_count verified assets"
