#!/usr/bin/env bash
# Proves that the Free P2P engine starts and answers inside the macOS App
# Sandbox, with the entitlements Orvix ships and the engine signed the way
# tools/bundle_macos_stream_engine.sh signs it.
#
#   tools/macos_sandbox_engine_test.sh <engine binary> [<engine binary> ...]
#
# It builds a tiny sandboxed app around the engine
# (tools/macos_sandbox_engine_probe.swift) and runs it. Orvix itself cannot
# be used for this on a hosted build machine: it stops a few seconds after
# starting because the machine has no accelerated OpenGL.
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 <engine binary> [<engine binary> ...]" >&2
  exit 2
fi
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
app="$work/OrvixEngineProbe.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>com.orvix.orvix.engineprobe</string>
	<key>CFBundleName</key>
	<string>OrvixEngineProbe</string>
	<key>CFBundleExecutable</key>
	<string>OrvixEngineProbe</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>LSMinimumSystemVersion</key>
	<string>11.0</string>
	<key>NSAppTransportSecurity</key>
	<dict>
		<key>NSAllowsLocalNetworking</key>
		<true/>
	</dict>
</dict>
</plist>
PLIST
swiftc -O "$here/macos_sandbox_engine_probe.swift" -o "$app/Contents/MacOS/OrvixEngineProbe"

# Sign it with what the real app has: sandbox, network client and server.
cat > "$work/app.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.network.client</key>
	<true/>
	<key>com.apple.security.network.server</key>
	<true/>
</dict>
</plist>
PLIST
codesign --force --sign - --entitlements "$work/app.entitlements" "$app"
bash "$here/bundle_macos_stream_engine.sh" "$app" "$@"

# The network part uses Sintel, the Blender Foundation's open movie (CC BY),
# a torrent that is free to share. It only reports; peers may be out of reach.
export ORVIX_PROBE_MAGNET="${ORVIX_PROBE_MAGNET-magnet:?xt=urn:btih:08ada5a7a6183aae1e09d831df6748d566095a10&dn=Sintel&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce&tr=udp%3A%2F%2Fopen.demonii.com%3A1337%2Fannounce&tr=udp%3A%2F%2Fexplodie.org%3A6969}"

echo "--- Running the engine inside the App Sandbox"
"$app/Contents/MacOS/OrvixEngineProbe"
