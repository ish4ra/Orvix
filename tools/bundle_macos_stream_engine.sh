#!/usr/bin/env bash
# Puts the Free P2P engine into a built macOS app and signs the result.
#
#   tools/bundle_macos_stream_engine.sh <app> <engine> [<engine> ...]
#
# Give one engine per architecture; they are joined into one universal
# binary at Contents/Resources/orvix-stream-server, which is where the app
# looks for it.
#
# The app is sandboxed and starts the engine as a child process. The engine
# is signed with the two entitlements a sandboxed helper must have (sandbox,
# inherit), so it runs inside the app's own sandbox and gets the app's
# network access, nothing more. Adding a file changes the app's seal, so the
# app is signed again with exactly the entitlements it already had.
#
# Signing is ad-hoc: valid for running, but not a Developer ID signature.
set -euo pipefail

if [ $# -lt 2 ]; then
  echo "usage: $0 <app> <engine> [<engine> ...]" >&2
  exit 2
fi
app=$1
shift
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
[ -d "$app/Contents/Resources" ] || { echo "bundle: $app is not an app bundle." >&2; exit 1; }

target="$app/Contents/Resources/orvix-stream-server"
rm -f "$target"
if [ $# -eq 1 ]; then
  cp "$1" "$target"
else
  lipo -create "$@" -output "$target"
fi
chmod 755 "$target"
echo "Engine architectures: $(lipo -archs "$target")"

licenses="$app/Contents/Resources/licenses/stream-server"
mkdir -p "$licenses"
cp "$root/licenses/stream-server/LICENSE" "$licenses/LICENSE.txt"
cp "$root/licenses/stream-server/NOTICE.md" "$licenses/NOTICE.md"

id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app/Contents/Info.plist")
codesign --force --sign - --identifier "$id.stream-server" \
  --entitlements "$here/macos_stream_engine.entitlements" "$target"

entitlements=$(mktemp)
codesign --display --entitlements - --xml "$app" > "$entitlements" 2>/dev/null
grep -q "com.apple.security.app-sandbox" "$entitlements" || {
  echo "bundle: $app is not sandboxed; refusing to guess its entitlements." >&2
  exit 1
}
codesign --force --sign - --entitlements "$entitlements" "$app"
rm -f "$entitlements"
codesign --verify --deep --strict "$app"
echo "Engine bundled and signed in $(basename "$app")."
