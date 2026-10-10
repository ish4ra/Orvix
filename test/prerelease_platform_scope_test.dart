import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// The prerelease workflow can publish either every platform or only the
// Android Mobile and Android TV APKs. These tests keep both paths, the release
// trigger and the Android update path consistent with pubspec.yaml.
void main() {
  final prerelease = File('.github/workflows/prerelease.yml').readAsStringSync();
  final pubspec = File('pubspec.yaml').readAsStringSync();
  final updater =
      File('lib/services/app_update_service.dart').readAsStringSync();

  String job(String name) {
    final start = prerelease.indexOf('\n  $name:\n');
    expect(start, isNot(-1), reason: 'job $name is missing');
    final next = RegExp(r'\n  [a-z][\w-]*:\n').firstMatch(
      prerelease.substring(start + name.length + 4),
    );
    return next == null
        ? prerelease.substring(start)
        : prerelease.substring(start, start + name.length + 4 + next.start);
  }

  final version = RegExp(r'^version: (\S+)$', multiLine: true)
      .firstMatch(pubspec)!
      .group(1)!;
  final match =
      RegExp(r'^(\d+\.\d+\.\d+-beta\.(\d+))\+(\d+)$').firstMatch(version);

  test('pubspec carries a beta version with a monotonic build number', () {
    expect(match, isNotNull, reason: 'expected X.Y.Z-beta.N+BUILD, got $version');
    // Every v0.7.9-beta.64 Android APK (universal, ABI and TV) was published
    // with versionCode 4209. develop once lagged at beta.59+204 because
    // beta.60-64 were versioned only on their release branches; a build from
    // that state would have been a downgrade Android refuses to install.
    expect(int.parse(match!.group(3)!), greaterThan(4209));
  });

  test('release trigger and concurrency group match the pubspec version', () {
    final beta = match!.group(2)!;
    final trigger = RegExp(r"^      - 'release/(all|android)-v([^']+)'$",
            multiLine: true)
        .allMatches(prerelease)
        .toList();
    expect(trigger, hasLength(1), reason: 'exactly one release branch trigger');
    expect(trigger.single.group(2), match.group(1));
    expect(prerelease, contains('  group: orvix-prerelease-beta$beta\n'));
  });

  test('manual runs infer the platforms or choose all / Android only', () {
    expect(
      prerelease,
      contains('        type: choice\n'
          '        options:\n'
          '          - auto\n'
          '          - all\n'
          '          - android\n'
          '        default: auto\n'),
    );
    final metadata = job('metadata');
    expect(
      metadata,
      contains('platforms: \${{ steps.platforms.outputs.platforms }}'),
    );
    expect(metadata, contains('release/android-v*) PLATFORMS=android ;;'));
    expect(metadata, contains('*) PLATFORMS=all ;;'));
    expect(metadata, contains('release/android-v*:all)'));
  });

  test('desktop and iOS jobs are skipped for an Android-only release', () {
    const onlyAll = "    if: needs.metadata.outputs.platforms == 'all'\n";
    for (final name in ['windows', 'macos', 'ios-modern', 'ios-legacy']) {
      expect(job(name), contains(onlyAll), reason: name);
    }
    for (final name in ['validate', 'android-native', 'android-mobile', 'android-tv']) {
      expect(job(name), isNot(contains('needs.metadata.outputs.platforms')),
          reason: '$name runs for every release');
    }
  });

  test('release job publishes only after the selected platforms succeed', () {
    final release = job('release');
    expect(release, contains('!cancelled()'));
    for (final name in ['validate', 'android-mobile', 'android-tv']) {
      expect(release, contains("needs.$name.result == 'success'"));
    }
    expect(release, contains("needs.metadata.outputs.platforms == 'android'"));
    for (final name in ['windows', 'macos', 'ios-modern', 'ios-legacy']) {
      expect(release, contains("needs.$name.result == 'success'"));
    }
    expect(release, contains("TITLE=\"Orvix v\$V Android Mobile + TV\""));
    final altstore =
        release.substring(release.indexOf('Prepare AltStore / SideStore source entry'));
    expect(altstore, contains("if: needs.metadata.outputs.platforms == 'all'"));
  });

  test('every Android APK is checked against the latest published release', () {
    final mobile = job('android-mobile');
    final mobileGate = mobile.substring(
      mobile.indexOf('Verify Android Mobile APKs update the latest published release'),
    );
    expect(mobileGate, contains('python3 tools/check_android_update_path.py'));
    expect(mobileGate, contains('endswith("-Android-Mobile.apk")'));
    expect(mobileGate, contains('select(.draft == false)'));
    for (final apk in [
      r'"Orvix-v$V-Android-Mobile.apk"',
      r'"Orvix-v$V-Android-Mobile-arm64-v8a.apk"',
      r'"Orvix-v$V-Android-Mobile-armeabi-v7a.apk"',
      r'"Orvix-v$V-Android-Mobile-x86_64.apk"',
    ]) {
      expect(mobileGate, contains(apk));
    }
    expect(
      mobile.indexOf('Verify Android Mobile APKs update'),
      lessThan(mobile.indexOf('name: android-mobile\n')),
      reason: 'gate before upload',
    );

    final tv = job('android-tv');
    final tvGate = tv.substring(
      tv.indexOf('Verify Android TV APK updates the latest published release'),
    );
    expect(tvGate, contains('python3 tools/check_android_update_path.py'));
    expect(tvGate, contains('endswith("-Android-TV.apk")'));
    expect(tvGate, contains(r'"Orvix-v$V-Android-TV.apk"'));
    expect(
      tv.indexOf('Verify Android TV APK updates'),
      lessThan(tv.indexOf('name: android-tv\n')),
    );
  });

  test('Android-only assets are the files the in-app updater looks for', () {
    final release = job('release');
    final android = release.substring(
      release.indexOf('            android)\n'),
      release.indexOf('            all)\n'),
    );
    expect(RegExp(r'"dist/').allMatches(android), hasLength(5));
    expect(android, contains(r'"dist/mobile/Orvix-v$V-Android-Mobile.apk"'));
    expect(android, contains(r'"dist/tv/Orvix-v$V-Android-TV.apk"'));
    expect(android, isNot(contains('Windows')));
    expect(android, isNot(contains('macOS')));
    expect(android, isNot(contains('iOS')));
    expect(updater, contains("name.endsWith('Android-Mobile.apk')"));
    expect(updater, contains("name.endsWith('Android-TV.apk')"));
  });
}
