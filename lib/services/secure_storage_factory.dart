import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Creates Orvix secure storage with a macOS configuration that works for
/// ad-hoc distributed builds as well as normal signed builds.
///
/// flutter_secure_storage uses the macOS data-protection keychain by default.
/// That requires Keychain Sharing/provisioning and causes errSecMissingEntitlement
/// (-34018) in ad-hoc DMG builds. Orvix does not share secrets between apps, so
/// the legacy per-user Keychain is the correct portable choice on macOS.
FlutterSecureStorage createOrvixSecureStorage() {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS) {
    return const FlutterSecureStorage(
      mOptions: MacOsOptions(usesDataProtectionKeychain: false),
    );
  }
  return const FlutterSecureStorage();
}
