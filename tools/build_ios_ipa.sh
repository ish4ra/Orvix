#!/usr/bin/env bash
# Build the Modern (recommended) unsigned iOS sideload IPA:
#   Orvix-v<version>-iOS-15.5-Plus.ipa  (iOS / iPadOS 15.5 or later)
# It uses the normal pubspec.yaml dependencies and the current Flutter.
# The iOS 12 Legacy IPA has its own builder: tools/build_ios_legacy_ipa.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"
# shellcheck source=tools/ios_ipa_common.sh
source "$ROOT/tools/ios_ipa_common.sh"

PROFILE=modern

# Never build the Modern IPA with Legacy dependencies or Legacy sources.
if [[ -e pubspec_overrides.yaml ]]; then
  echo "pubspec_overrides.yaml exists; the Modern iOS build must use the normal dependencies." >&2
  echo "It is generated only by tools/build_ios_legacy_ipa.sh. Remove it and retry." >&2
  exit 1
fi
if cmp -s lib/services/subtitle_file_picker.dart \
  tools/ios_legacy/overlay/lib/services/subtitle_file_picker.dart; then
  echo "lib/ contains the Legacy iOS source overlay; restore it before a Modern build." >&2
  exit 1
fi

orvix_ios_resolve_versions "${1:-}"
orvix_ios_build_and_package "$PROFILE"
