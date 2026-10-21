#!/usr/bin/env bash
# Vendors the pinned @supabase/supabase-js browser (UMD) build for the
# Control Center page, so the page loads no JavaScript from a CDN.
#
#   tools/vendor_supabase_js.sh           write the files
#   tools/vendor_supabase_js.sh --check   rebuild in a temp dir and compare
#
# The npm tarball is verified against its pinned registry integrity before
# anything is extracted. Nothing is installed and no npm scripts run: the
# package already ships a self-contained dist/umd build.
set -euo pipefail

VERSION="2.45.4"
INTEGRITY="sha512-E5p8/zOLaQ3a462MZnmnz03CrduA5ySH9hZyL03Y+QZLIOO4/Gs8Rdy4ZCKDHsN7x0xdanVEWWFN3pJFQr9/hg=="
TARBALL="https://registry.npmjs.org/@supabase/supabase-js/-/supabase-js-${VERSION}.tgz"

root=$(cd "$(dirname "$0")/.." && pwd)
dest="$root/supabase/functions/orvix-admin/web/vendor/supabase-js/$VERSION"

mode=write
if [ "${1:-}" = "--check" ]; then
  mode=check
elif [ $# -ne 0 ]; then
  echo "usage: $0 [--check]" >&2
  exit 2
fi

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

curl --fail --silent --show-error --location --output "$work/package.tgz" "$TARBALL"
actual="sha512-$(openssl dgst -sha512 -binary "$work/package.tgz" | base64 | tr -d '\n')"
if [ "$actual" != "$INTEGRITY" ]; then
  echo "integrity mismatch for supabase-js $VERSION: $actual" >&2
  exit 1
fi

tar -xzf "$work/package.tgz" -C "$work" \
  package/dist/umd/supabase.js package/dist/umd/591.supabase.js package/LICENSE
out="$work/out"
mkdir -p "$out"
cp "$work/package/dist/umd/supabase.js" "$work/package/dist/umd/591.supabase.js" \
  "$work/package/LICENSE" "$out/"
(cd "$out" && sha256sum supabase.js 591.supabase.js LICENSE > SHA256SUMS)
sri="sha384-$(openssl dgst -sha384 -binary "$out/supabase.js" | base64 | tr -d '\n')"

if [ "$mode" = check ]; then
  diff -r "$out" "$dest"
  echo "vendored supabase-js $VERSION matches the pinned npm tarball"
else
  mkdir -p "$dest"
  cp "$out"/* "$dest/"
  echo "wrote $dest"
fi
echo "script integrity for web/index.html: $sri"
