import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'orvix_backend_config.dart';

/// Creates Orvix secure storage with a macOS configuration that works for
/// ad-hoc distributed builds as well as normal signed builds.
///
/// flutter_secure_storage uses the macOS data-protection keychain by default.
/// That requires Keychain Sharing/provisioning and causes errSecMissingEntitlement
/// (-34018) in ad-hoc DMG builds. Orvix does not share secrets between apps, so
/// the legacy per-user Keychain is the correct portable choice on macOS.
///
/// That keychain is one store for the whole user account, and items are found
/// by a service name. A private test build therefore uses its own service
/// name, so it can neither read nor overwrite what the installed Orvix saved
/// (sign-in, debrid tokens), and two test copies do not share theirs.
FlutterSecureStorage createOrvixSecureStorage() {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS) {
    if (OrvixBackendConfig.isTestBuild) {
      return FlutterSecureStorage(
        mOptions: MacOsOptions(
          usesDataProtectionKeychain: false,
          accountName: testBuildKeychainService(
            sandboxContainerId: Platform.environment['APP_SANDBOX_CONTAINER_ID'],
            executablePath: Platform.resolvedExecutable,
          ),
        ),
      );
    }
    return const FlutterSecureStorage(
      mOptions: MacOsOptions(usesDataProtectionKeychain: false),
    );
  }
  return const FlutterSecureStorage();
}

/// The keychain service name of one macOS test app.
///
/// macOS gives a sandboxed app its bundle identifier in
/// `APP_SANDBOX_CONTAINER_ID`. Without it the name of the app bundle is used,
/// so two differently named copies still stay apart.
@visibleForTesting
String testBuildKeychainService({
  required String? sandboxContainerId,
  required String executablePath,
}) {
  var id = (sandboxContainerId ?? '').trim();
  if (id.isEmpty) {
    final bundle = RegExp(r'([^/]+)\.app/Contents/MacOS/[^/]+$')
        .firstMatch(executablePath)
        ?.group(1);
    id = bundle ?? 'unknown';
  }
  final safe = id.toLowerCase().replaceAll(RegExp(r'[^a-z0-9.]+'), '-');
  return 'orvix-test.$safe';
}
