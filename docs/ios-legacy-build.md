# iOS builds: Modern and Legacy

Orvix ships two unsigned iPhone / iPad sideload IPAs. They are built by
separate CI jobs from the same source and are never mixed.

| | Modern (recommended) | Legacy |
| --- | --- | --- |
| Release file | `Orvix-v<version>-iOS-15.5-Plus.ipa` | `Orvix-v<version>-iOS-12-Legacy.ipa` |
| Minimum iOS | 15.5 | 12.0 |
| Devices | anything that runs iOS / iPadOS 15.5+ | older 64-bit devices on iOS 12, e.g. iPhone 5s, iPhone 6, iPhone 6 Plus |
| Builder | `tools/build_ios_ipa.sh` | `tools/build_ios_legacy_ipa.sh` |
| Verifier | `tools/verify_ios_ipa.sh` | `tools/verify_ios_legacy_ipa.sh` |
| CI job / artifact | `Build iOS Modern sideload IPA` / `ios-modern` | `Build iOS Legacy sideload IPA` / `ios-legacy` |
| Flutter | current stable (same as every other job) | 3.32.8 (Dart 3.8.1), pinned |
| Xcode | runner default | 16.4, selected explicitly |
| Dependencies | `pubspec.yaml` | `pubspec.yaml` + `tools/ios_legacy/pubspec_overrides.yaml` |
| AltStore / SideStore source | listed in `store.json` | direct GitHub download only |

Both use bundle ID `com.orvix.orvix`, display name `Orvix`, the
three-component marketing version (`0.7.9` for `0.7.9-beta.65`) and the
pubspec `+BUILD` number. Both ship `Payload/Orvix.app` unsigned, arm64, with
no `embedded.mobileprovision`; nested frameworks may keep Flutter's ad-hoc
signatures. The two profiles are defined once, in `tools/ios_profiles.py`.

## Why Legacy needs its own toolchain

Flutter 3.35 raised Flutter's minimum iOS to 13.0, so Flutter 3.32.8 is the
newest release that can still build for iOS 12. Orvix's `lib/` compiles with
it (Dart 3.8.1) after two small, behaviour-preserving source changes:

- `lib/screens/account_screen.dart`: the QR scanner `errorBuilder` takes its
  `child` argument as optional, which satisfies both mobile_scanner 6.x and
  7.x signatures.
- `lib/services/subtitle_file_picker.dart`: the external-subtitle picker call
  moved out of `player_screen.dart` into this adapter. The Legacy build swaps
  in `tools/ios_legacy/overlay/lib/services/subtitle_file_picker.dart`, which
  makes the same request through file_picker 11's API.

## Legacy dependency audit and overrides

Every package with iOS native code was checked for its iOS deployment target
(podspec / Package.swift) and its Dart / Flutter SDK constraint. A package is
overridden only when its current release cannot be used for iOS 12 with
Flutter 3.32.8; then the newest compatible release is used. All pins are
exact so the native stack is reproducible.

| Package | Normal build | Legacy | Reason |
| --- | --- | --- | --- |
| mobile_scanner | ^6.0.11 (ML Kit, iOS 15.5) | 7.4.2 | 7.x uses Apple Vision and supports iOS 12.0; latest release, needs Flutter ≥ 3.29 |
| file_picker | ^13.1.0 | 11.0.3 | 12.x/13.x need Dart 3.10 / Flutter 3.38 and iOS 14 (file_picker_darwin); 11.0.3 supports iOS 12 |
| flutter_secure_storage | ^11.2.0 | 10.3.4 | 11.x uses flutter_secure_storage_darwin 0.4 (iOS 13) |
| flutter_secure_storage_darwin | 0.4.x | 0.3.2 | last release with iOS 12.0 |
| package_info_plus | ^10.1.0 | 9.0.1 | 10.x needs Dart 3.10 / Flutter 3.38 |
| video_player | ^2.14.0 | 2.10.1 | 2.14 needs Dart 3.12; 2.10.1 is the newest for Dart 3.8 |
| video_player_avfoundation | latest | 2.8.4 | newer releases need iOS 13 / Dart 3.10+ |
| url_launcher_ios | latest | 6.3.4 | 6.4 needs iOS 13 |
| shared_preferences_foundation | latest | 2.5.4 | newer releases need iOS 13 |
| path_provider_foundation | latest | 2.4.2 | newest for Dart 3.8; iOS 12.0 |
| sqflite_darwin | latest | 2.4.2 | newest for Dart 3.8; iOS 12.0 |
| app_links (Supabase) | latest | 6.4.1 | 7.x needs iOS 13 / Dart 3.12 |
| wakelock_plus (media_kit_video) | latest | 1.4.0 | newest for Dart 3.8; iOS 12.0 |
| media_kit_libs_ios_video | 1.1.4 | 1.1.4 | unchanged; libmpv frameworks are built for iOS 9.0 |
| media_kit, media_kit_video | Debrify fork @ 709eca3 | same | unchanged; repeated because a pubspec_overrides file replaces pubspec overrides |
| ffmpeg_kit_flutter_new_https | 2.6.2 | Dart-only stand-in | see below |

Unchanged in Legacy: supabase_flutter 2.15.4 (and its Dart-only Supabase
client packages), url_launcher, shared_preferences, path_provider,
cached_network_image, http, crypto, archive, qr_flutter.

### FFmpegKit

The real `ffmpeg_kit_flutter_new_https` iOS pod requires iOS 14. Orvix uses
FFmpegKit only for embedded subtitle extraction and the AI audio subtitle
fallback, and both are already disabled on iOS
(`EmbeddedSubtitleExtractorService.isSupportedPlatform`, `AiAudioSttService`).
The Legacy build therefore resolves `tools/ios_legacy/packages/ffmpeg_kit_flutter_new_https`,
a Dart-only package with the same API and no native code, whose sessions
report failure without running anything. No FFmpeg binary ships in the Legacy
IPA. Android, Android TV, Windows, macOS and Modern iOS are unaffected.

### Playback

`media_kit_libs_ios_video` 1.1.4 downloads libmpv-darwin-build v0.6.0
(SHA-256 pinned in the package). All 18 device frameworks (Mpv, Avcodec,
Avformat, Avfilter, Avutil, Swresample, Swscale, Ass, Dav1d, Freetype,
Fribidi, Harfbuzz, Mbedcrypto, Mbedtls, Mbedx509, Png16, Uchardet, Xml2) are
arm64 and encode a minimum of iOS 9.0, and they only link system frameworks
present on iOS 12. The Debrify `media_kit_video` iOS plugin renders through
OpenGL ES and keeps its iOS 15 picture-in-picture code behind `@available`.

## How the Legacy build stays isolated

- `tools/build_ios_legacy_ipa.sh` refuses to run unless Flutter is exactly
  3.32.8 and Xcode is 16.4. It copies the override file to
  `./pubspec_overrides.yaml` and applies the source overlay, and restores both
  on exit. The root `pubspec_overrides.yaml` is git-ignored.
- `tools/build_ios_ipa.sh` refuses to run if a `pubspec_overrides.yaml` or
  the Legacy overlay is present.
- After `flutter pub get`, both builders check the resolved packages: Modern
  must not resolve anything from `tools/ios_legacy`; Legacy must resolve the
  FFmpegKit stand-in and mobile_scanner 7.x.
- Only the CI / prerelease `ios-legacy` jobs pin a Flutter or Xcode version.
  `tools/tests/test_ios_build_profiles.py` enforces all of the above.

## Verifying what actually ships

`MinimumOSVersion` in Info.plist is only a claim. Both verifiers run
`tools/ios_ipa_checks.py`, which reads every Mach-O file in the IPA
(`tools/ios_macho.py`) and fails if any slice:

- has no arm64 device slice, contains x86_64/i386 code or is built for the
  simulator or another platform;
- encodes an iOS deployment target above the profile's minimum (15.5 / 12.0);
- strongly links a system framework or Swift runtime library that does not
  exist on that iOS version.

`tools/verify_ios_legacy_ipa.sh` also re-reads every binary with Apple's
`lipo` and `otool`, prints the deployment-target inventory to the CI log and
fails if Apple's tools and the parser disagree.

## Code signatures inside the IPA

`tools/ios_signing.py` runs `codesign -dv` on `Payload/Orvix.app` and on
every nested framework, app extension and dylib, prints the inventory, and
applies these rules:

- `Payload/Orvix.app` must be **unsigned**. Any signature on it (Apple
  Development, Apple Distribution, App Store, ad-hoc, ...) fails, and so does
  an `embedded.mobileprovision` anywhere in the IPA.
- Nested items may be unsigned, or ad-hoc signed by Flutter's toolchain
  (`Signature=adhoc`, no certificate, `TeamIdentifier` not set).
- **Legacy only:** because the deployment target is below iOS 12.2, Xcode
  embeds Apple's Swift runtime back-deployment libraries
  (`Frameworks/libswift*.dylib`) and they keep Apple's own signature. They are
  accepted only at `Payload/Orvix.app/Frameworks/libswift<Name>.dylib` with
  identifier `com.apple.dt.runtime.swift<Name>`, the certificate chain
  `Software Signing` → `Apple Code Signing Certification Authority` →
  `Apple Root CA`, team `59GAB85EFG`, and an arm64 iOS slice that fits
  iOS 12.0. Sideload tools re-sign them along with the app. The Modern build
  never contains them, so it does not accept them.
- Anything else, including any other certificate, team or unparseable
  `codesign` output, fails.

## Installing the Legacy IPA

Current AltStore and SideStore apps do not run on iOS 12, so the Legacy IPA is
not listed in `store.json` (adding it would also give one bundle ID two
entries with the same version and build). It is published as a direct GitHub
Release download for computer-based sideloading tools that still support
iOS 12.

The Legacy build has been validated in CI (build, dependency resolution and
binary compatibility). It still needs testing on a real iOS 12 device such as
an iPhone 5s on iOS 12.5.7 before it is promoted as working.
