#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

PUBSPEC_VERSION="$(awk '$1 == "version:" {print $2}' pubspec.yaml)"
if [[ -z "$PUBSPEC_VERSION" ]]; then
  echo "Could not resolve version from pubspec.yaml" >&2
  exit 1
fi

FULL_VERSION="${1:-${PUBSPEC_VERSION%%+*}}"
BUILD_NUMBER="${PUBSPEC_VERSION#*+}"
if [[ "$BUILD_NUMBER" == "$PUBSPEC_VERSION" || -z "$BUILD_NUMBER" ]]; then
  BUILD_NUMBER="1"
fi

if [[ ! "$FULL_VERSION" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]]; then
  echo "Invalid iOS release version: $FULL_VERSION" >&2
  exit 1
fi
if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "Invalid iOS build number from pubspec.yaml: $BUILD_NUMBER" >&2
  exit 1
fi

# Flutter platform directories are generated in CI just like Android/macOS.
flutter create --platforms=ios --org com.orvix --project-name orvix .
python3 tools/configure_ios_build.py
flutter pub get

flutter build ios --release --no-codesign \
  --build-name "$FULL_VERSION" \
  --build-number "$BUILD_NUMBER"

APP="build/ios/iphoneos/Runner.app"
if [[ ! -d "$APP" ]]; then
  echo "iOS build did not produce $APP" >&2
  exit 1
fi

PLIST="$APP/Info.plist"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"
BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILT_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$PLIST")"

[[ "$BUNDLE_ID" == "com.orvix.orvix" ]] || {
  echo "Unexpected iOS bundle identifier: $BUNDLE_ID" >&2
  exit 1
}
[[ "$BUILT_VERSION" == "$FULL_VERSION" ]] || {
  echo "Built iOS version $BUILT_VERSION does not match $FULL_VERSION" >&2
  exit 1
}
[[ "$BUILT_NUMBER" == "$BUILD_NUMBER" ]] || {
  echo "Built iOS build number $BUILT_NUMBER does not match $BUILD_NUMBER" >&2
  exit 1
}
[[ -n "$MIN_OS" ]] || {
  echo "Built iOS app has no MinimumOSVersion" >&2
  exit 1
}

EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")"
ARCHS="$(xcrun lipo -archs "$APP/$EXECUTABLE")"
if [[ " $ARCHS " != *" arm64 "* ]]; then
  echo "Built iOS app does not contain arm64: $ARCHS" >&2
  exit 1
fi

if [[ -d "$APP/_CodeSignature" ]]; then
  echo "Sideload IPA must be unsigned, but _CodeSignature exists." >&2
  exit 1
fi

OUTPUT="Orvix-v${FULL_VERSION}-iOS.ipa"
PACKAGE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/orvix-ios-ipa.XXXXXX")"
trap 'rm -rf "$PACKAGE_ROOT"' EXIT
mkdir -p "$PACKAGE_ROOT/Payload"
ditto "$APP" "$PACKAGE_ROOT/Payload/Orvix.app"

(
  cd "$PACKAGE_ROOT"
  /usr/bin/zip -qry "$ROOT/$OUTPUT" Payload
)

unzip -tq "$OUTPUT"
test -s "$OUTPUT"
echo "Created $OUTPUT (bundle=$BUNDLE_ID version=$BUILT_VERSION build=$BUILT_NUMBER minOS=$MIN_OS)"
