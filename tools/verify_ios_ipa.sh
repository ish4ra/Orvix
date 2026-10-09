#!/usr/bin/env bash
# Verify an unsigned Orvix sideload IPA: zip integrity, Payload layout,
# Apple-compatible version metadata, arm64 executable and no signature.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

IPA="${1:?usage: verify_ios_ipa.sh <ipa> <release-version> <build-number>}"
RELEASE_VERSION="${2:?missing release version}"
BUILD_NUMBER="${3:?missing build number}"

test -s "$IPA"
unzip -tq "$IPA"
unzip -l "$IPA" | grep -q 'Payload/Orvix.app/Info.plist'
if unzip -l "$IPA" | grep -q '/_CodeSignature/'; then
  echo "iOS sideload IPA is unexpectedly signed." >&2
  exit 1
fi

python3 - "$IPA" "$RELEASE_VERSION" "$BUILD_NUMBER" "$ROOT/tools" <<'PY'
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[4])
from update_altstore_source import ios_build_version, ios_marketing_version, read_ipa

ipa, release, build = sys.argv[1:4]
info, _ = read_ipa(Path(ipa))
expected = {
    "CFBundleIdentifier": "com.orvix.orvix",
    "CFBundleDisplayName": "Orvix",
    "CFBundleShortVersionString": ios_marketing_version(release),
    "CFBundleVersion": ios_build_version(build),
}
for key, value in expected.items():
    if info.get(key) != value:
        raise SystemExit(f"IPA {key}={info.get(key)!r}, expected {value!r}")
if not info.get("NSCameraUsageDescription"):
    raise SystemExit("IPA is missing NSCameraUsageDescription")
if not info.get("MinimumOSVersion"):
    raise SystemExit("IPA is missing MinimumOSVersion")
print(
    "IPA metadata OK: "
    + ", ".join(f"{key}={value}" for key, value in expected.items())
    + f", MinimumOSVersion={info['MinimumOSVersion']}"
)
PY

WORK="$(mktemp -d "${TMPDIR:-/tmp}/orvix-ipa-verify.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
unzip -q "$IPA" 'Payload/Orvix.app/*' -d "$WORK"
APP="$WORK/Payload/Orvix.app"
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist")"
ARCHS="$(xcrun lipo -archs "$APP/$EXECUTABLE")"
if [[ " $ARCHS " != *" arm64 "* ]]; then
  echo "iOS executable does not contain arm64: $ARCHS" >&2
  exit 1
fi
echo "IPA OK: $(basename "$IPA") size=$(wc -c < "$IPA" | tr -d ' ') bytes archs=$ARCHS"
