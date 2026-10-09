#!/usr/bin/env bash
# Build the Legacy unsigned iOS sideload IPA for older 64-bit devices
# (iPhone 5s, iPhone 6, iPhone 6 Plus and others on iOS 12):
#   Orvix-v<version>-iOS-12-Legacy.ipa
#
# Flutter 3.35 raised Flutter's iOS minimum to 13.0, so this build needs the
# pinned Flutter 3.32 toolchain and the Legacy-only dependency set in
# tools/ios_legacy/ (see docs/ios-legacy-build.md). For the duration of the
# build it applies, in this checkout only:
#   - tools/ios_legacy/pubspec_overrides.yaml -> ./pubspec_overrides.yaml
#   - tools/ios_legacy/overlay/lib/...        -> ./lib/...
# and restores both on exit, so a later Modern build is unaffected.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"
# shellcheck source=tools/ios_ipa_common.sh
source "$ROOT/tools/ios_ipa_common.sh"

PROFILE=legacy
LEGACY_DIR="tools/ios_legacy"
OVERLAY_DIR="$LEGACY_DIR/overlay"

EXPECTED_FLUTTER="$(orvix_ios_profile_value flutter-version "$PROFILE")"
EXPECTED_XCODE="$(orvix_ios_profile_value xcode-version "$PROFILE")"

FLUTTER_VERSION="$(flutter --version --machine | python3 -c 'import json, sys; print(json.load(sys.stdin)["frameworkVersion"])')"
DART_VERSION="$(dart --version 2>&1 | sed -n 's/^Dart SDK version: \([^ ]*\).*/\1/p')"
XCODE_VERSION="$(xcodebuild -version | sed -n 's/^Xcode //p' | head -1)"
echo "Legacy iOS toolchain: Flutter $FLUTTER_VERSION, Dart $DART_VERSION, Xcode $XCODE_VERSION"

if [[ "$FLUTTER_VERSION" != "$EXPECTED_FLUTTER" ]]; then
  echo "Legacy iOS builds require Flutter $EXPECTED_FLUTTER (found $FLUTTER_VERSION)." >&2
  echo "Flutter 3.35+ cannot target iOS 12." >&2
  exit 1
fi
if [[ "$XCODE_VERSION" != "$EXPECTED_XCODE" && "$XCODE_VERSION" != "$EXPECTED_XCODE".* ]]; then
  echo "Legacy iOS builds are validated with Xcode $EXPECTED_XCODE (found $XCODE_VERSION)." >&2
  exit 1
fi
if [[ -e pubspec_overrides.yaml ]]; then
  echo "A pubspec_overrides.yaml already exists; refusing to overwrite it." >&2
  exit 1
fi

# Remember the files the overlay replaces and put everything back on exit.
BACKUP="$(mktemp -d "${TMPDIR:-/tmp}/orvix-ios-legacy.XXXXXX")"
OVERLAY_FILES=()
while IFS= read -r file; do
  OVERLAY_FILES+=("${file#"$OVERLAY_DIR/"}")
done < <(find "$OVERLAY_DIR" -type f | sort)
if [[ ${#OVERLAY_FILES[@]} -eq 0 ]]; then
  echo "No Legacy source overlay files found in $OVERLAY_DIR" >&2
  exit 1
fi

restore_checkout() {
  local status=$?
  rm -f "$ROOT/pubspec_overrides.yaml"
  local relative
  for relative in "${OVERLAY_FILES[@]}"; do
    if [[ -f "$BACKUP/$relative" ]]; then
      cp "$BACKUP/$relative" "$ROOT/$relative"
    fi
  done
  rm -rf "$BACKUP"
  return "$status"
}
trap restore_checkout EXIT

for relative in "${OVERLAY_FILES[@]}"; do
  if [[ ! -f "$relative" ]]; then
    # An overlay may only replace an existing adapter, never add new code.
    echo "Legacy overlay $OVERLAY_DIR/$relative has no counterpart at $relative" >&2
    exit 1
  fi
  mkdir -p "$BACKUP/$(dirname "$relative")"
  cp "$relative" "$BACKUP/$relative"
  cp "$OVERLAY_DIR/$relative" "$relative"
  echo "Applied Legacy overlay: $relative"
done
cp "$LEGACY_DIR/pubspec_overrides.yaml" pubspec_overrides.yaml
echo "Applied Legacy dependency overrides from $LEGACY_DIR/pubspec_overrides.yaml"

orvix_ios_resolve_versions "${1:-}"
orvix_ios_build_and_package "$PROFILE"
