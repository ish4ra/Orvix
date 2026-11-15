#!/usr/bin/env bash
# Packs the private macOS Watch Party test build for download.
#
#   tools/package_macos_test_build.sh <built .app> <output directory>
#
# The output is one ZIP with:
#   Orvix Watch Party Test.app     the test app (com.orvix.orvix.wptest)
#   Orvix Watch Party Test 2.app   the same build under a second identity
#                                  (com.orvix.orvix.wptest2), so two signed-in
#                                  participants can run on one Mac
#   INSTALL.txt
#
# macOS keeps a sandboxed app's settings, sign-in and caches in a folder
# named after its bundle identifier, so the two copies and the public Orvix
# never share data. The second copy is the first with another identifier; it
# is signed again, ad-hoc, with the same entitlements.
#
# Both are ad-hoc signed. They are not Developer ID signed and not notarized.
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "usage: $0 <built .app> <output directory>" >&2
  exit 2
fi
app=$1
out=$2
second_id=com.orvix.orvix.wptest2
second_name="Orvix Watch Party Test 2"
here=$(cd "$(dirname "$0")" && pwd)

[ -d "$app" ] || { echo "package: $app is not an app bundle." >&2; exit 1; }
first_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app/Contents/Info.plist")
[ "$first_id" = com.orvix.orvix.wptest ] || {
  echo "package: $app is not the test build (identifier $first_id)." >&2
  exit 1
}

folder="$out/Orvix Watch Party Test (macOS)"
rm -rf "$folder"
mkdir -p "$folder"
ditto "$app" "$folder/$(basename "$app")"

second="$folder/$second_name.app"
ditto "$app" "$second"
plist="$second/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$second_id" "$plist"
plutil -replace CFBundleName -string "$second_name" "$plist"
plutil -replace CFBundleDisplayName -string "$second_name" "$plist"

# Changing Info.plist invalidates the signature. Sign the copy again with the
# entitlements of the original; the libraries inside keep their signatures.
entitlements=$(mktemp)
codesign --display --entitlements - --xml "$app" > "$entitlements" 2>/dev/null
grep -q "com.apple.security.app-sandbox" "$entitlements" || {
  echo "package: could not read the entitlements of $app." >&2
  exit 1
}
codesign --force --sign - --entitlements "$entitlements" "$second"
rm -f "$entitlements"
codesign --verify --deep --strict "$folder/$(basename "$app")"
codesign --verify --deep --strict "$second"

cp "$here/macos_test_build_INSTALL.txt" "$folder/INSTALL.txt"

zip="$out/orvix-watch-party-test-macos.zip"
rm -f "$zip"
ditto -c -k --sequesterRsrc --keepParent "$folder" "$zip"
test -s "$zip"
echo "Packed $zip"
