#!/usr/bin/env bash
set -euo pipefail

# Prove that Android's Package Manager accepts the Android Mobile release APKs
# and that every variant can replace every other one on the same device.
#
# usage: android_install_smoke_test.sh <universal.apk> <x86_64.apk> [<arm64-v8a.apk>]
#
# Run against a booted emulator. Installing the universal APK over an ABI APK
# is the path that failed when ABI APKs carried a higher versionCode
# ("App not installed as package appears to be invalid").

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <universal.apk> <x86_64.apk> [<arm64-v8a.apk>]" >&2
  exit 64
fi

PACKAGE="com.orvix.orvix"
universal="$1"
x86_64="$2"
arm64="${3:-}"

install_apk() {
  local apk="$1"
  local output
  echo "::group::adb install -r $(basename "$apk")"
  output="$(adb install -r "$apk" 2>&1 || true)"
  echo "$output"
  echo "::endgroup::"
  if ! grep -q '^Success' <<<"$output"; then
    echo "Package Manager rejected $(basename "$apk"): $output" >&2
    exit 1
  fi
}

expect_installed_abi() {
  local abi="$1"
  local dump
  dump="$(adb shell dumpsys package "$PACKAGE")"
  grep -E 'versionCode=|versionName=|primaryCpuAbi=' <<<"$dump" | head -3
  if ! grep -q "primaryCpuAbi=$abi" <<<"$dump"; then
    echo "$PACKAGE is not installed with primary ABI $abi" >&2
    exit 1
  fi
}

adb wait-for-device
adb shell getprop ro.build.version.sdk
abilist="$(adb shell getprop ro.product.cpu.abilist | tr -d '\r')"
echo "Device ABIs: $abilist"
adb uninstall "$PACKAGE" >/dev/null 2>&1 || true

# Fresh install of the recommended download.
install_apk "$universal"
adb shell pm path "$PACKAGE"
expect_installed_abi x86_64

# ABI APK over the universal APK, then back again.
install_apk "$x86_64"
expect_installed_abi x86_64
install_apk "$universal"
expect_installed_abi x86_64

# Emulator images with ARM translation can also take the arm64-v8a APK.
if [[ -n "$arm64" ]]; then
  if [[ ",$abilist," == *",arm64-v8a,"* ]]; then
    install_apk "$arm64"
    expect_installed_abi arm64-v8a
    install_apk "$universal"
  else
    echo "Device cannot run arm64-v8a code; skipping the arm64-v8a APK install."
  fi
fi

echo "Package Manager accepted every Android Mobile APK variant."
