#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="${1:-native}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p \
  "$OUT_DIR/jniLibs/armeabi-v7a" \
  "$OUT_DIR/jniLibs/arm64-v8a" \
  "$OUT_DIR/jniLibs/x86" \
  "$OUT_DIR/jniLibs/x86_64" \
  "$OUT_DIR/libs"

extract_native() {
  local abi="$1"
  local file="$2"
  local sha="$3"
  local apk="$TMP_DIR/$file"

  curl --fail --location --retry 4 --retry-delay 2 \
    "https://github.com/stremio-native/stremio-android/releases/download/v1.2.4/$file" \
    -o "$apk"
  echo "$sha  $apk" | sha256sum -c -

  unzip -p "$apk" "lib/$abi/libstream_server.so" > "$OUT_DIR/jniLibs/$abi/libstream_server.so"
  unzip -p "$apk" "lib/$abi/libc++_shared.so" > "$OUT_DIR/jniLibs/$abi/libc++_shared.so"
  test -s "$OUT_DIR/jniLibs/$abi/libstream_server.so"
  test -s "$OUT_DIR/jniLibs/$abi/libc++_shared.so"
}

extract_native arm64-v8a StremioMobile-v1.2.4-arm64-v8a-release.apk 3ffd96e6c6f0b23845f7ee6ab721d52ba1534055304959ed84c9589aac8bc97e
extract_native armeabi-v7a StremioMobile-v1.2.4-armeabi-v7a-release.apk 519ab54a8a57e93c5a2f2a70cced18673063cffcb88cfdcd0ec6c9a7e5f5570e
extract_native x86 StremioMobile-v1.2.4-x86-release.apk 201012b229914b533665f4c477140f174d7b933fdc27c1fae6a2fb3a1f232058
extract_native x86_64 StremioMobile-v1.2.4-x86_64-release.apk bee94497864d46a3b7c1905848e161da03179ca4ff85c6808710cdd435cafc94

curl --fail --location --retry 4 --retry-delay 2 \
  "https://raw.githubusercontent.com/stremio-native/stremio-android/4bdef3b6be1186d9aa22acd8b3ec391c22f0e083/app/libs/rustls-platform-verifier-0.1.1.aar" \
  -o "$OUT_DIR/libs/rustls-platform-verifier-0.1.1.aar"

test -s "$OUT_DIR/libs/rustls-platform-verifier-0.1.1.aar"
