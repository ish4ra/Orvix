# Shared steps for the Orvix iOS sideload builders. Source this file; it is
# not a command. tools/build_ios_ipa.sh (Modern) and
# tools/build_ios_legacy_ipa.sh (Legacy) each pass their own fixed profile,
# so neither builder can produce the other's IPA.

# Sets RELEASE_VERSION, BUILD_NUMBER and IOS_VERSION from pubspec.yaml and
# the optional release-version argument.
orvix_ios_resolve_versions() {
  local pubspec_version
  pubspec_version="$(awk '$1 == "version:" {print $2}' pubspec.yaml)"
  if [[ -z "$pubspec_version" ]]; then
    echo "Could not resolve version from pubspec.yaml" >&2
    return 1
  fi

  RELEASE_VERSION="${1:-${pubspec_version%%+*}}"
  BUILD_NUMBER="${pubspec_version#*+}"
  if [[ "$BUILD_NUMBER" == "$pubspec_version" || -z "$BUILD_NUMBER" ]]; then
    echo "pubspec.yaml version $pubspec_version has no +BUILD number for CFBundleVersion" >&2
    return 1
  fi

  if [[ ! "$RELEASE_VERSION" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]]; then
    echo "Invalid iOS release version: $RELEASE_VERSION" >&2
    return 1
  fi

  # Apple requires CFBundleShortVersionString to be Major.Minor.Patch, so
  # 0.7.9-beta.64 ships as 0.7.9. Beta iterations stay unique through
  # CFBundleVersion, which is the same +BUILD number Android uses.
  read -r IOS_VERSION BUILD_NUMBER < <(
    python3 - "$RELEASE_VERSION" "$BUILD_NUMBER" "$ROOT/tools" <<'PY'
import sys

sys.path.insert(0, sys.argv[3])
from update_altstore_source import ios_build_version, ios_marketing_version

try:
    print(ios_marketing_version(sys.argv[1]), ios_build_version(sys.argv[2]))
except ValueError as exc:
    raise SystemExit(f"error: {exc}")
PY
  )
  if [[ -z "${IOS_VERSION:-}" || -z "${BUILD_NUMBER:-}" ]]; then
    echo "Could not derive iOS version/build from $RELEASE_VERSION / $pubspec_version" >&2
    return 1
  fi
}

orvix_ios_profile_value() {
  python3 "$ROOT/tools/ios_profiles.py" "$@"
}

# Fails when the resolved packages do not belong to the profile being built:
# Modern must never see tools/ios_legacy, Legacy must use its stand-ins.
orvix_ios_check_dependency_profile() {
  local profile="$1"
  local config=".dart_tool/package_config.json"
  [[ -s "$config" ]] || {
    echo "Missing $config after flutter pub get" >&2
    return 1
  }
  if [[ "$profile" == "modern" ]]; then
    if grep -q 'tools/ios_legacy' "$config"; then
      echo "Modern iOS build resolved a Legacy-only package from tools/ios_legacy." >&2
      return 1
    fi
  else
    grep -q 'tools/ios_legacy/packages/ffmpeg_kit_flutter_new_https' "$config" || {
      echo "Legacy iOS build did not resolve the FFmpegKit stand-in package." >&2
      return 1
    }
    grep -q 'mobile_scanner-7\.' "$config" || {
      echo "Legacy iOS build did not resolve mobile_scanner 7.x (iOS 12 capable)." >&2
      return 1
    }
  fi
}

# Generates and configures the iOS runner, builds it unsigned, checks the
# app bundle and packages Payload/Orvix.app as the profile's IPA name.
orvix_ios_build_and_package() {
  local profile="$1"
  local expected_min_os output
  expected_min_os="$(orvix_ios_profile_value min-ios "$profile")"
  output="$(orvix_ios_profile_value ipa-filename "$profile" "$RELEASE_VERSION")"

  # Flutter platform directories are generated in CI just like Android/macOS.
  flutter create --platforms=ios --org com.orvix --project-name orvix .
  python3 tools/configure_ios_build.py --profile "$profile"
  flutter pub get
  orvix_ios_check_dependency_profile "$profile"

  flutter build ios --release --no-codesign \
    --build-name "$IOS_VERSION" \
    --build-number "$BUILD_NUMBER"

  local app="build/ios/iphoneos/Runner.app"
  if [[ ! -d "$app" ]]; then
    echo "iOS build did not produce $app" >&2
    return 1
  fi

  local plist="$app/Info.plist"
  local bundle_id built_version built_number min_os display_name executable archs
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")"
  built_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
  built_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
  min_os="$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$plist")"

  [[ "$bundle_id" == "com.orvix.orvix" ]] || {
    echo "Unexpected iOS bundle identifier: $bundle_id" >&2
    return 1
  }
  [[ "$built_version" == "$IOS_VERSION" ]] || {
    echo "Built iOS version $built_version does not match expected $IOS_VERSION" >&2
    return 1
  }
  [[ "$built_number" == "$BUILD_NUMBER" ]] || {
    echo "Built iOS build number $built_number does not match $BUILD_NUMBER" >&2
    return 1
  }
  [[ "$min_os" == "$expected_min_os" ]] || {
    echo "Built $profile iOS app has MinimumOSVersion $min_os, expected $expected_min_os" >&2
    return 1
  }
  display_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$plist")"
  [[ "$display_name" == "Orvix" ]] || {
    echo "Unexpected iOS display name: $display_name" >&2
    return 1
  }
  /usr/libexec/PlistBuddy -c 'Print :NSCameraUsageDescription' "$plist" >/dev/null || {
    echo "Built iOS app is missing NSCameraUsageDescription for QR scanning" >&2
    return 1
  }

  executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")"
  archs="$(xcrun lipo -archs "$app/$executable")"
  if [[ " $archs " != *" arm64 "* ]]; then
    echo "Built iOS app does not contain arm64: $archs" >&2
    return 1
  fi

  if [[ -d "$app/_CodeSignature" ]]; then
    echo "Sideload IPA must be unsigned, but _CodeSignature exists." >&2
    return 1
  fi

  local package_root
  package_root="$(mktemp -d "${TMPDIR:-/tmp}/orvix-ios-ipa.XXXXXX")"
  mkdir -p "$package_root/Payload"
  ditto "$app" "$package_root/Payload/Orvix.app"
  rm -f "$ROOT/$output"
  (
    cd "$package_root"
    /usr/bin/zip -qry "$ROOT/$output" Payload
  )
  rm -rf "$package_root"

  unzip -tq "$output"
  test -s "$output"
  echo "Created $output (profile=$profile release=$RELEASE_VERSION iosVersion=$built_version build=$built_number minOS=$min_os)"
}
