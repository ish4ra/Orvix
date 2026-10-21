// One place that decides which Orvix product a telemetry row or a release
// asset belongs to. Unknown values stay "Unknown"/"Other"; they are never
// folded into a real platform.

export const PLATFORMS = [
  "Android Mobile",
  "Android TV",
  "Windows",
  "macOS",
  "iOS",
] as const;

export type Platform = typeof PLATFORMS[number];
export type TelemetryPlatform = Platform | "Linux" | "Unknown";
export type AssetPlatform = Platform | "Other";

// Every client since telemetry was added (#57) reports one of these exact
// labels from OrvixTelemetryService._platformName(). The alias keys only
// tolerate case, spacing and punctuation differences.
const telemetryAliases: Record<string, TelemetryPlatform> = {
  androidmobile: "Android Mobile",
  androidtv: "Android TV",
  windows: "Windows",
  macos: "macOS",
  ios: "iOS",
  linux: "Linux",
};

/// Normalizes the build platform a client reported.
///
/// The platform is the Orvix *build* that is running (the TV APK reports
/// "Android TV" through the ORVIX_TV dart-define), not the hardware. A bare
/// "android" is ambiguous and stays Unknown rather than being guessed.
export function normalizePlatform(value: unknown): TelemetryPlatform {
  if (typeof value !== "string") return "Unknown";
  const key = value.toLowerCase().replace(/[^a-z]/g, "");
  return telemetryAliases[key] ?? "Unknown";
}

/// True when the build and the hardware disagree: the mobile APK running on
/// a leanback (TV) device, or the TV APK on a phone. Counted as a diagnostic,
/// never used to reassign the platform.
export function isFormFactorMismatch(
  platform: unknown,
  deviceType: unknown,
): boolean {
  const normalized = normalizePlatform(platform);
  const type = typeof deviceType === "string" ? deviceType.trim().toLowerCase() : "";
  if (normalized === "Android Mobile") return type === "tv";
  if (normalized === "Android TV") return type === "mobile";
  return false;
}

export type AssetKind = "app" | "component" | "metadata";

export type AssetClassification = {
  platform: AssetPlatform;
  variant: string;
  kind: AssetKind;
};

const metadataRe = /\.(sha256|sha512|sha1|md5|sig|asc|txt|json|yml|yaml)$/;

/// Classifies a GitHub release asset by its file name.
///
/// Current names (prerelease.yml):
///   Orvix-<tag>-Android-Mobile.apk                 universal APK
///   Orvix-<tag>-Android-Mobile-<abi>.apk           arm64-v8a / armeabi-v7a / x86_64
///   Orvix-<tag>-Android-TV.apk
///   Orvix-Setup-<tag>-Windows-x64.exe              installer
///   Orvix-<tag>-Windows-x64.zip                    portable
///   Orvix-<tag>-macOS.zip / .dmg
///   Orvix-<tag>-iOS-15.5-Plus.ipa / -iOS-12-Legacy.ipa / -iOS.ipa
/// Older names: Pikora-*-Windows-x64.*, Android-Mobile-Compat.apk.
/// `orvix-stream-server-*` is the Windows streaming helper that the release
/// workflow downloads while building; it is not an app download.
export function classifyReleaseAsset(name: unknown): AssetClassification {
  const value = String(name ?? "").trim().toLowerCase();

  if (value.includes("stream-server")) {
    return { platform: "Other", variant: "Stream server component", kind: "component" };
  }
  if (metadataRe.test(value)) {
    return { platform: "Other", variant: "Checksum / metadata", kind: "metadata" };
  }

  if (value.endsWith(".apk")) {
    // TV is checked first and only on an explicit "android-tv" marker, so a
    // generic APK never becomes a TV download.
    if (value.includes("android-tv")) {
      return { platform: "Android TV", variant: "TV APK", kind: "app" };
    }
    if (value.includes("android-mobile")) {
      if (value.includes("arm64-v8a")) {
        return { platform: "Android Mobile", variant: "arm64-v8a APK", kind: "app" };
      }
      if (value.includes("armeabi-v7a")) {
        return { platform: "Android Mobile", variant: "armeabi-v7a APK", kind: "app" };
      }
      if (value.includes("x86_64")) {
        return { platform: "Android Mobile", variant: "x86_64 APK", kind: "app" };
      }
      if (value.includes("compat")) {
        return { platform: "Android Mobile", variant: "Compat APK", kind: "app" };
      }
      return { platform: "Android Mobile", variant: "Universal APK", kind: "app" };
    }
    return { platform: "Other", variant: "Unlabeled APK", kind: "app" };
  }

  if (value.endsWith(".ipa")) {
    if (value.includes("legacy")) {
      return { platform: "iOS", variant: "Legacy IPA (iOS 12+)", kind: "app" };
    }
    if (value.includes("plus") || value.includes("modern")) {
      return { platform: "iOS", variant: "Modern IPA (iOS 15.5+)", kind: "app" };
    }
    return { platform: "iOS", variant: "IPA", kind: "app" };
  }

  if (value.includes("macos") || value.endsWith(".dmg") || value.endsWith(".pkg")) {
    return {
      platform: "macOS",
      variant: value.endsWith(".dmg") ? "DMG" : value.endsWith(".pkg") ? "PKG" : "ZIP",
      kind: "app",
    };
  }

  if (value.includes("windows") || value.includes("setup")) {
    if (value.endsWith(".exe") || value.endsWith(".msi") || value.endsWith(".msix")) {
      return { platform: "Windows", variant: "Installer", kind: "app" };
    }
    if (value.endsWith(".zip")) {
      return { platform: "Windows", variant: "Portable ZIP", kind: "app" };
    }
  }

  return { platform: "Other", variant: "Other file", kind: "app" };
}

export function emptyPlatformCounts(): Record<AssetPlatform, number> {
  return {
    "Android Mobile": 0,
    "Android TV": 0,
    "Windows": 0,
    "macOS": 0,
    "iOS": 0,
    "Other": 0,
  };
}
