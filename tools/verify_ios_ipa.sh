#!/usr/bin/env bash
# Verify an unsigned Orvix sideload IPA: zip integrity, Payload layout,
# Apple-compatible version metadata, arm64 executable and no signature.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

IPA="${1:?usage: verify_ios_ipa.sh <ipa> <release-version> <build-number>}"
RELEASE_VERSION="${2:?missing release version}"
BUILD_NUMBER="${3:?missing build number}"

fail() {
  # Also surface the reason as a workflow annotation in GitHub Actions.
  [[ -n "${GITHUB_ACTIONS:-}" ]] && echo "::error title=iOS IPA verification::$*"
  echo "$*" >&2
  exit 1
}
trap 'fail "verify_ios_ipa.sh: command failed at line $LINENO"' ERR

WORK="$(mktemp -d "${TMPDIR:-/tmp}/orvix-ipa-verify.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

[[ -s "$IPA" ]] || fail "IPA is missing or empty: $IPA"
unzip -tq "$IPA" >/dev/null || fail "IPA zip integrity check failed: $IPA"
# List once into a file: piping unzip into `grep -q` can SIGPIPE unzip and
# fail the check under pipefail even when the entry exists.
unzip -Z1 "$IPA" > "$WORK/entries.txt"
grep -qx 'Payload/Orvix.app/Info.plist' "$WORK/entries.txt" \
  || fail "IPA is missing Payload/Orvix.app/Info.plist"

notice() {
  # Multi-line workflow annotations encode newlines as %0A.
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::notice title=$1::${2//$'\n'/%0A}"
  fi
  printf '%s:\n%s\n' "$1" "$2"
}
SIGNATURE_PATHS="$(grep -E '_CodeSignature/CodeResources$|embedded\.mobileprovision$' "$WORK/entries.txt" || true)"
notice "IPA signature paths" "${SIGNATURE_PATHS:-none}"
# The app bundle itself must be unsigned. Embedded frameworks such as
# Flutter.framework ship pre-signed; sideload tools re-sign them anyway.
if grep -Eq '^Payload/Orvix\.app/(_CodeSignature/|embedded\.mobileprovision$)' "$WORK/entries.txt"; then
  fail "iOS sideload IPA is unexpectedly signed (app _CodeSignature or embedded.mobileprovision)."
fi

python3 - "$IPA" "$RELEASE_VERSION" "$BUILD_NUMBER" "$ROOT/tools" <<'PY'
import os
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[4])
from update_altstore_source import ios_build_version, ios_marketing_version, read_ipa


def fail(message: str) -> None:
    if os.environ.get("GITHUB_ACTIONS"):
        print(f"::error title=iOS IPA verification::{message}", flush=True)
    raise SystemExit(message)


ipa, release, build = sys.argv[1:4]
try:
    info, _ = read_ipa(Path(ipa))
    expected = {
        "CFBundleIdentifier": "com.orvix.orvix",
        "CFBundleDisplayName": "Orvix",
        "CFBundleShortVersionString": ios_marketing_version(release),
        "CFBundleVersion": ios_build_version(build),
    }
except Exception as exc:  # report any parsing problem as an annotation
    fail(f"{type(exc).__name__}: {exc}")
for key, value in expected.items():
    if info.get(key) != value:
        fail(f"IPA {key}={info.get(key)!r}, expected {value!r}")
if not info.get("NSCameraUsageDescription"):
    fail("IPA is missing NSCameraUsageDescription")
if not info.get("MinimumOSVersion"):
    fail("IPA is missing MinimumOSVersion")
print(
    "IPA metadata OK: "
    + ", ".join(f"{key}={value}" for key, value in expected.items())
    + f", MinimumOSVersion={info['MinimumOSVersion']}"
)
PY

unzip -q "$IPA" 'Payload/Orvix.app/*' -d "$WORK"
APP="$WORK/Payload/Orvix.app"

if command -v codesign >/dev/null 2>&1; then
  SIGNATURE_DETAILS=""
  while IFS= read -r bundle; do
    details="$(codesign -dv --verbose=2 "$bundle" 2>&1 \
      | grep -E '^(Signature|Authority|TeamIdentifier|Identifier)=|not signed' \
      | tr '\n' ' ' || true)"
    SIGNATURE_DETAILS+="${bundle#"$WORK/"}: ${details:-no codesign output}"$'\n'
  done < <(
    echo "$APP"
    find "$APP" -mindepth 1 \( -name '*.framework' -o -name '*.appex' -o -name '*.dylib' \) -prune -print | sort
  )
  notice "IPA codesign details" "${SIGNATURE_DETAILS%$'\n'}"
fi
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist")"
ARCHS="$(xcrun lipo -archs "$APP/$EXECUTABLE")"
[[ " $ARCHS " == *" arm64 "* ]] || fail "iOS executable does not contain arm64: $ARCHS"
echo "IPA OK: $(basename "$IPA") size=$(wc -c < "$IPA" | tr -d ' ') bytes archs=$ARCHS"
