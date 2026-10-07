import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Android Mobile ABI APKs used to be published with versionCode
// ABI*1000+BUILD while the universal APK used BUILD. Installing the universal
// APK (also what the in-app updater downloads) over an ABI APK was then a
// versionCode downgrade, which Android reports as "App not installed as
// package appears to be invalid".
void main() {
  final prerelease = File('.github/workflows/prerelease.yml').readAsStringSync();
  final ci = File('.github/workflows/ci.yml').readAsStringSync();
  final verifier = File('tools/verify_android_apk.py').readAsStringSync();

  String job(String workflow, String name) {
    final start = workflow.indexOf('\n  $name:\n');
    expect(start, isNot(-1), reason: 'job $name is missing');
    final next = RegExp(r'\n  [a-z][\w-]*:\n').firstMatch(
      workflow.substring(start + name.length + 4),
    );
    return next == null
        ? workflow.substring(start)
        : workflow.substring(start, start + name.length + 4 + next.start);
  }

  const sameVersionCode =
      '--split-per-abi \\\n'
      '            --android-project-arg=force-version-code-ignoring-abi=true';

  test('release ABI APKs share the universal APK versionCode', () {
    final mobile = job(prerelease, 'android-mobile');
    expect(mobile, contains(sameVersionCode));
    expect(
      RegExp(r'--split-per-abi(?!\s*\\\s*\n\s*--android-project-arg=force-version-code-ignoring-abi=true)')
          .hasMatch(mobile),
      isFalse,
      reason: 'every split build must keep the universal versionCode',
    );
  });

  test('prerelease gates the published Android Mobile APKs', () {
    final mobile = job(prerelease, 'android-mobile');
    final rename = mobile.indexOf('- name: Rename APKs');
    final gate = mobile.indexOf('python3 tools/verify_android_apk.py');
    final upload = mobile.indexOf('name: android-mobile\n');
    expect(gate, greaterThan(rename), reason: 'check the renamed, published files');
    expect(gate, lessThan(upload));
    final gateStep = mobile.substring(gate, mobile.indexOf('- name:', gate));
    expect(gateStep, contains('--flavor mobile'));
    expect(gateStep, contains(r'--expected-cert-sha256 "$PREVIOUS_CERT"'));
    expect(gateStep, contains('--above-legacy-split-version-codes'));
    for (final apk in [
      r'Orvix-v$V-Android-Mobile.apk=arm64-v8a,armeabi-v7a,x86_64',
      r'Orvix-v$V-Android-Mobile-arm64-v8a.apk=arm64-v8a',
      r'Orvix-v$V-Android-Mobile-armeabi-v7a.apk=armeabi-v7a',
      r'Orvix-v$V-Android-Mobile-x86_64.apk=x86_64',
    ]) {
      expect(gateStep, contains(apk));
    }
    // The certificate continuity check against the published APK stays.
    expect(mobile, contains('Orvix-v0.7.9-beta.11-Android-Mobile.apk'));
    expect(mobile, contains('Android update signing certificate changed'));
  });

  test('CI builds and installs the same Android Mobile APK set', () {
    final mobile = job(ci, 'android-mobile');
    expect(mobile, contains('flutter build apk --release\n'));
    expect(mobile, contains(sameVersionCode));
    expect(mobile, contains('python3 tools/verify_android_apk.py'));
    expect(mobile, isNot(contains('flutter build apk --debug')));

    final install = job(ci, 'android-mobile-install');
    expect(install, contains('needs: android-mobile'));
    expect(install, contains('reactivecircus/android-emulator-runner'));
    expect(
      install,
      contains(
        'bash tools/android_install_smoke_test.sh apks/app-release.apk '
        'apks/app-x86_64-release.apk apks/app-arm64-v8a-release.apk',
      ),
    );
    expect(ci, contains('python3 -m unittest discover -s tools/tests'));
  });

  test('installability gate keeps its Orvix-specific requirements', () {
    expect(verifier, contains('PACKAGE_NAME = "com.orvix.orvix"'));
    expect(verifier, contains('SUPPORTED_MIN_SDK = 24'));
    expect(verifier, contains('HIGHEST_LEGACY_SPLIT_VERSION_CODE = 4205'));
    for (final lib in [
      'libflutter.so',
      'libapp.so',
      'libmpv.so',
      'libmediakitandroidhelper.so',
      'libstream_server.so',
      'libc++_shared.so',
    ]) {
      expect(verifier, contains('"$lib"'));
    }
    expect(verifier, contains('LEANBACK_LAUNCHER'));
  });

  test('release notes point phone users at the universal APK', () {
    final release = job(prerelease, 'release');
    expect(release, contains('Which Android file should I download?'));
    expect(release, contains(r'Orvix-v$V-Android-Mobile.apk\` (recommended'));
  });
}
