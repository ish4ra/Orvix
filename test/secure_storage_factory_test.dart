import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/secure_storage_factory.dart';

// A macOS test build keeps its secrets under its own keychain service name,
// so it never reads or overwrites the installed app's.
void main() {
  test('the sandbox bundle identifier names the keychain service', () {
    expect(
      testBuildKeychainService(
        sandboxContainerId: 'com.orvix.orvix.wptest',
        executablePath: '/Applications/Anything.app/Contents/MacOS/Anything',
      ),
      'orvix-test.com.orvix.orvix.wptest',
    );
  });

  test('two test copies get different services', () {
    String service(String id) => testBuildKeychainService(
          sandboxContainerId: id,
          executablePath: '/x/Orvix.app/Contents/MacOS/Orvix',
        );
    expect(service('com.orvix.orvix.wptest'),
        isNot(service('com.orvix.orvix.wptest2')));
  });

  test('without a sandbox the app bundle name is used', () {
    expect(
      testBuildKeychainService(
        sandboxContainerId: null,
        executablePath: '/Applications/Orvix Watch Party Test 2.app'
            '/Contents/MacOS/Orvix Watch Party Test 2',
      ),
      'orvix-test.orvix-watch-party-test-2',
    );
    expect(
      testBuildKeychainService(sandboxContainerId: ' ', executablePath: '/bin/x'),
      'orvix-test.unknown',
    );
  });

  test('a test service is never the default service', () {
    // flutter_secure_storage's default service is what the public app uses.
    expect(
      testBuildKeychainService(
        sandboxContainerId: 'flutter_secure_storage_service',
        executablePath: '',
      ),
      isNot('flutter_secure_storage_service'),
    );
  });

  test('normal builds keep the existing macOS storage options', () {
    final source =
        File('lib/services/secure_storage_factory.dart').readAsStringSync();
    expect(
      source,
      contains('return const FlutterSecureStorage(\n'
          '      mOptions: MacOsOptions(usesDataProtectionKeychain: false),\n'
          '    );'),
    );
    expect(source, contains('if (OrvixBackendConfig.isTestBuild) {'));
  });
}
