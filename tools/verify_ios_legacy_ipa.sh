#!/usr/bin/env bash
# Verify the Legacy iOS sideload IPA (Orvix-v<version>-iOS-12-Legacy.ipa).
#
# Info.plist's MinimumOSVersion is only a claim. iOS 12 refuses to load any
# binary whose own load commands require a newer iOS, so on top of the normal
# sideload checks (tools/verify_ios_ipa.sh ... legacy) this reads every
# Mach-O file in the IPA with Apple's lipo and otool and fails when any of
# them:
#   - lacks an arm64 device slice or carries x86/simulator code,
#   - is not built for the iOS device platform,
#   - requires an iOS version above the Legacy target (12.0),
#   - disagrees with tools/ios_macho.py's independent reading.
# It prints the full deployment-target inventory for the CI log.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

IPA="${1:?usage: verify_ios_legacy_ipa.sh <ipa> <release-version> <build-number>}"
RELEASE_VERSION="${2:?missing release version}"
BUILD_NUMBER="${3:?missing build number}"
PROFILE=legacy
MAX_MIN_IOS="$(python3 "$ROOT/tools/ios_profiles.py" min-ios "$PROFILE")"

fail() {
  [[ -n "${GITHUB_ACTIONS:-}" ]] && echo "::error title=iOS Legacy IPA verification::$*"
  echo "$*" >&2
  exit 1
}

# Zip, layout, metadata (MinimumOSVersion 12.0), naming, signing rules and
# the pure-Python Mach-O deployment-target gate.
bash "$ROOT/tools/verify_ios_ipa.sh" "$IPA" "$RELEASE_VERSION" "$BUILD_NUMBER" "$PROFILE"

command -v xcrun >/dev/null 2>&1 || fail "verify_ios_legacy_ipa.sh needs Xcode command line tools (xcrun lipo/otool)."

WORK="$(mktemp -d "${TMPDIR:-/tmp}/orvix-legacy-verify.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
unzip -q "$IPA" -d "$WORK/ipa"
APP="$WORK/ipa/Payload/Orvix.app"

python3 "$ROOT/tools/ios_macho.py" "$APP" --max-min-ios "$MAX_MIN_IOS" \
  --json "$WORK/parser.json" > "$WORK/parser.txt" \
  || { cat "$WORK/parser.txt"; fail "tools/ios_macho.py rejected the Legacy IPA binaries."; }

# Re-derive every binary's slices with Apple's tools.
: > "$WORK/apple.tsv"
while IFS= read -r relative; do
  binary="$WORK/ipa/Payload/$relative"
  archs="$(xcrun lipo -archs "$binary")"
  for arch in $archs; do
    read -r platform minos < <(
      xcrun otool -arch "$arch" -l "$binary" | awk -v arch="$arch" '
        $1 == "cmd" && $2 == "LC_BUILD_VERSION" { mode = "build"; next }
        $1 == "cmd" && $2 == "LC_VERSION_MIN_IPHONEOS" { mode = "min"; next }
        $1 == "cmd" { mode = "" }
        mode == "build" && $1 == "platform" { platform = $2 }
        mode == "build" && $1 == "minos" { minos = $2; mode = "" }
        mode == "min" && $1 == "version" {
          minos = $2
          platform = (arch == "x86_64" || arch == "i386") ? 7 : 2
          mode = ""
        }
        END { print (platform == "" ? "none" : platform), (minos == "" ? "none" : minos) }
      '
    )
    printf '%s\t%s\t%s\t%s\n' "$relative" "$arch" "$platform" "$minos" >> "$WORK/apple.tsv"
  done
done < <(python3 -c 'import json, sys; [print(p) for p in sorted({row["path"] for row in json.load(open(sys.argv[1]))})]' "$WORK/parser.json")

python3 - "$WORK/apple.tsv" "$WORK/parser.json" "$MAX_MIN_IOS" "$ROOT/tools" <<'PY'
import json
import os
import sys

sys.path.insert(0, sys.argv[4])
from ios_macho import parse_version

apple_tsv, parser_json, max_min_ios = sys.argv[1:4]
limit = parse_version(max_min_ios)
# otool prints the numeric platform; 2 = iOS device, 7 = iOS Simulator.
platforms = {"2": "ios", "7": "ios-simulator", "1": "macos", "6": "maccatalyst"}

apple = {}
with open(apple_tsv, encoding="utf-8") as handle:
    for line in handle:
        path, arch, platform, minos = line.rstrip("\n").split("\t")
        apple[(path, arch)] = (platforms.get(platform, f"platform{platform}"), minos)
parser = {
    (row["path"], row["arch"]): (row["platform"], row["minos"])
    for row in json.load(open(parser_json, encoding="utf-8"))
}

problems = []
if set(apple) != set(parser):
    problems.append(
        "lipo and tools/ios_macho.py disagree on slices: "
        f"apple-only={sorted(set(apple) - set(parser))} "
        f"parser-only={sorted(set(parser) - set(apple))}"
    )

width = max((len(path) for path, _ in apple), default=6)
print("Legacy IPA Mach-O deployment-target inventory (lipo + otool):")
print(f"{'binary'.ljust(width)}  arch    platform        minOS")
highest = None
for (path, arch), (platform, minos) in sorted(apple.items()):
    print(f"{path.ljust(width)}  {arch:<7} {platform:<15} {minos}")
    label = f"{path} [{arch}]"
    if arch in ("x86_64", "i386"):
        problems.append(f"{label}: Intel simulator code in a device IPA")
    if platform != "ios":
        problems.append(f"{label}: built for {platform}, not iOS devices")
    if minos == "none":
        problems.append(f"{label}: no deployment target load command")
        continue
    if parse_version(minos) > limit:
        problems.append(f"{label}: requires iOS {minos}, above iOS {max_min_ios}")
    if highest is None or parse_version(minos) > parse_version(highest):
        highest = minos
    other = parser.get((path, arch))
    if other and (other[0] != platform or parse_version(other[1] or "0") != parse_version(minos)):
        problems.append(f"{label}: otool says {platform} {minos}, parser says {other[0]} {other[1]}")
    if arch != "arm64" and arch != "arm64e":
        problems.append(f"{label}: unexpected architecture for a 64-bit device IPA")

binaries = sorted({path for path, _ in apple})
for path in binaries:
    if (path, "arm64") not in apple:
        problems.append(f"{path}: no arm64 slice")

summary = (
    f"{len(binaries)} Mach-O binaries, {len(apple)} slices; highest iOS deployment "
    f"target {highest}; Legacy limit iOS {max_min_ios}"
)
print(summary)
if os.environ.get("GITHUB_ACTIONS"):
    print(f"::notice title=Legacy IPA deployment targets::{summary}")
if problems:
    for problem in problems:
        if os.environ.get("GITHUB_ACTIONS"):
            print(f"::error title=iOS Legacy IPA verification::{problem}")
        print(f"error: {problem}", file=sys.stderr)
    raise SystemExit(1)
PY

echo "Legacy IPA OK: $(basename "$IPA") is arm64-only and every shipped binary supports iOS $MAX_MIN_IOS."
