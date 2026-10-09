#!/usr/bin/env bash
# Verify an unsigned Orvix sideload IPA: zip integrity, Payload layout,
# Apple-compatible version metadata, the profile's IPA name and exact
# MinimumOSVersion, the deployment target of every shipped Mach-O binary,
# arm64 executable and no app signature.
#
# The profile defaults to modern (Orvix-v<version>-iOS-15.5-Plus.ipa).
# tools/verify_ios_legacy_ipa.sh runs this with "legacy" and adds the Apple
# toolchain deployment-target inventory for the iOS 12 build.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

IPA="${1:?usage: verify_ios_ipa.sh <ipa> <release-version> <build-number> [modern|legacy]}"
RELEASE_VERSION="${2:?missing release version}"
BUILD_NUMBER="${3:?missing build number}"
PROFILE="${4:-modern}"

fail() {
  # Also surface the reason as a workflow annotation in GitHub Actions.
  [[ -n "${GITHUB_ACTIONS:-}" ]] && echo "::error title=iOS $PROFILE IPA verification::$*"
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

# Metadata, layout, exact MinimumOSVersion and Mach-O deployment targets.
python3 "$ROOT/tools/ios_ipa_checks.py" --profile "$PROFILE" \
  "$IPA" "$RELEASE_VERSION" "$BUILD_NUMBER" \
  || fail "$(basename "$IPA") failed the $PROFILE iOS IPA checks (see errors above)."

unzip -q "$IPA" -d "$WORK"
APP="$WORK/Payload/Orvix.app"

if command -v codesign >/dev/null 2>&1; then
  # Orvix.app must be unsigned. Nested bundles may keep the ad-hoc
  # signatures Flutter's toolchain gives them (App.framework,
  # Flutter.framework, objective_c.framework), but nothing may be signed
  # with a certificate or Apple team identity.
  UNSIGNED_NESTED=0
  ADHOC_NESTED=""
  while IFS= read -r bundle; do
    name="${bundle#"$WORK/"}"
    details="$(codesign -dv --verbose=2 "$bundle" 2>&1 || true)"
    if grep -q 'code object is not signed at all' <<< "$details"; then
      [[ "$bundle" == "$APP" ]] || UNSIGNED_NESTED=$((UNSIGNED_NESTED + 1))
      continue
    fi
    [[ "$bundle" != "$APP" ]] || fail "Payload/Orvix.app is code signed; the sideload IPA must ship it unsigned."
    if grep -q '^Authority=' <<< "$details" \
      || ! grep -qx 'Signature=adhoc' <<< "$details" \
      || ! grep -qx 'TeamIdentifier=not set' <<< "$details"; then
      fail "$name is signed with a certificate or team identity: $(grep -E '^(Authority|TeamIdentifier|Signature)=' <<< "$details" | tr '\n' ' ')"
    fi
    ADHOC_NESTED+="${name#Payload/Orvix.app/}"$'\n'
  done < <(
    echo "$APP"
    find "$APP" -mindepth 1 \( -name '*.framework' -o -name '*.appex' -o -name '*.dylib' \) -prune -print | sort
  )
  notice "IPA codesign summary" "Payload/Orvix.app: not signed
Ad-hoc signed nested bundles (no certificate, TeamIdentifier not set):
${ADHOC_NESTED:-none
}Unsigned nested bundles: $UNSIGNED_NESTED"
fi

EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist")"
ARCHS="$(xcrun lipo -archs "$APP/$EXECUTABLE")"
[[ " $ARCHS " == *" arm64 "* ]] || fail "iOS executable does not contain arm64: $ARCHS"
echo "IPA OK: $(basename "$IPA") size=$(wc -c < "$IPA" | tr -d ' ') bytes archs=$ARCHS"
