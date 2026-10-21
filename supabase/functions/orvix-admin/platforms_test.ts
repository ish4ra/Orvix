// deno test --allow-read supabase/functions/orvix-admin/
import { classifyReleaseAsset, isFormFactorMismatch, normalizePlatform } from "./platforms.ts";
import { assertEquals } from "./test_assert.ts";

Deno.test("telemetry platform labels from every client version normalize exactly", () => {
  assertEquals(normalizePlatform("Android TV"), "Android TV");
  assertEquals(normalizePlatform("Android Mobile"), "Android Mobile");
  assertEquals(normalizePlatform("Windows"), "Windows");
  assertEquals(normalizePlatform("macOS"), "macOS");
  assertEquals(normalizePlatform("iOS"), "iOS");
  assertEquals(normalizePlatform("Linux"), "Linux");
  assertEquals(normalizePlatform(" android_tv "), "Android TV");
  assertEquals(normalizePlatform("MACOS"), "macOS");
});

Deno.test("ambiguous or invalid platforms stay Unknown", () => {
  for (const value of ["android", "Android", "fuchsia", "", "TV", null, undefined, 7, "windows phone"]) {
    assertEquals(normalizePlatform(value), "Unknown", String(value));
  }
});

Deno.test("build/hardware mismatch is detected but never reassigns", () => {
  assertEquals(isFormFactorMismatch("Android Mobile", "TV"), true);
  assertEquals(isFormFactorMismatch("Android TV", "Mobile"), true);
  assertEquals(isFormFactorMismatch("Android TV", "TV"), false);
  assertEquals(isFormFactorMismatch("Android Mobile", "Mobile"), false);
  assertEquals(isFormFactorMismatch("Windows", "TV"), false);
  assertEquals(normalizePlatform("Android Mobile"), "Android Mobile");
});

const cases: [string, string, string, string][] = [
  ["Orvix-v0.7.10-beta.4-Android-Mobile.apk", "Android Mobile", "Universal APK", "app"],
  ["Orvix-v0.7.10-beta.4-Android-Mobile-arm64-v8a.apk", "Android Mobile", "arm64-v8a APK", "app"],
  ["Orvix-v0.7.10-beta.4-Android-Mobile-armeabi-v7a.apk", "Android Mobile", "armeabi-v7a APK", "app"],
  ["Orvix-v0.7.10-beta.4-Android-Mobile-x86_64.apk", "Android Mobile", "x86_64 APK", "app"],
  ["Orvix-v0.7.4-alpha.01-Android-Mobile-Compat.apk", "Android Mobile", "Compat APK", "app"],
  ["Orvix-v0.7.10-beta.4-Android-TV.apk", "Android TV", "TV APK", "app"],
  ["Orvix-Setup-v0.7.10-beta.4-Windows-x64.exe", "Windows", "Installer", "app"],
  ["Orvix-v0.7.10-beta.4-Windows-x64.zip", "Windows", "Portable ZIP", "app"],
  ["Pikora-Setup-v0.3.2-Windows-x64.exe", "Windows", "Installer", "app"],
  ["Pikora-v0.3.2-Windows-x64.zip", "Windows", "Portable ZIP", "app"],
  ["Orvix-v0.7.10-beta.4-macOS.zip", "macOS", "ZIP", "app"],
  ["Orvix-v0.7.3-alpha.9-macOS.dmg", "macOS", "DMG", "app"],
  ["Orvix-v0.7.10-beta.4-iOS-15.5-Plus.ipa", "iOS", "Modern IPA (iOS 15.5+)", "app"],
  ["Orvix-v0.7.10-beta.4-iOS-12-Legacy.ipa", "iOS", "Legacy IPA (iOS 12+)", "app"],
  ["Orvix-v0.7.9-beta.68-iOS.ipa", "iOS", "IPA", "app"],
  ["orvix-stream-server-windows-amd64.exe", "Other", "Stream server component", "component"],
  ["orvix-stream-server-windows-amd64.sha256", "Other", "Stream server component", "component"],
  ["Orvix-v0.7.10-beta.4-Windows-x64.zip.sha256", "Other", "Checksum / metadata", "metadata"],
  ["Orvix-v0.7.10-beta.4-Android.apk", "Other", "Unlabeled APK", "app"],
  ["README.pdf", "Other", "Other file", "app"],
];

for (const [name, platform, variant, kind] of cases) {
  Deno.test(`asset ${name}`, () => {
    assertEquals(classifyReleaseAsset(name), { platform, variant, kind });
  });
}

Deno.test("a generic APK is never counted as Android TV", () => {
  assertEquals(classifyReleaseAsset("app-release.apk").platform, "Other");
  assertEquals(classifyReleaseAsset("Orvix-tvbox-helper.apk").platform, "Other");
});
