import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/public_release_discovery.dart';

// The prerelease workflow can publish either every platform or only the
// Android Mobile and Android TV APKs. These tests keep both paths, the release
// trigger and the Android update path consistent with pubspec.yaml.
void main() {
  final prerelease = File('.github/workflows/prerelease.yml').readAsStringSync();
  final pubspec = File('pubspec.yaml').readAsStringSync();
  final updater =
      File('lib/services/public_release_discovery.dart').readAsStringSync();

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
  final match = RegExp(r'^(\d+\.\d+\.\d+)(?:-beta\.(\d+))?\+(\d+)$')
      .firstMatch(version);

  test('pubspec has a version and higher Android build number', () {
    expect(match, isNotNull,
        reason: 'expected X.Y.Z[beta]+BUILD, got $version');
    expect(int.parse(match!.group(3)!), greaterThan(4223),
        reason: 'above public v0.7.9 (4223) so it installs as an update');
  });

  test('stable branch trigger matches release and public channel', () {
    expect(prerelease, contains("'release/stable-v0.7.9'"));
    expect(prerelease, contains('  group: orvix-release-079\n'));
    expect(prerelease, contains("release/stable-v0.7.9:0.7.9)"));
    expect(prerelease, contains("!startsWith(github.ref_name, 'release/stable-v')"));
  });

  test('develop carries the v0.7.10 beta, a prerelease above public v0.7.9',
      () {
    expect(match!.group(1), '0.7.10');
    expect(match.group(2), isNotNull,
        reason: 'v0.7.10 is a beta until the owner approves otherwise');
    expect(prerelease,
        contains("      - 'release/android-v${match.group(1)}-beta.${match.group(2)}'\n"));
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
    expect(updater, contains(r"'Orvix-v$version-Android-Mobile.apk'"));
    expect(updater, contains(r"'Orvix-v$version-Android-Mobile-$abi.apk'"));
    expect(updater, contains(r"'Orvix-v$version-Android-TV.apk'"));
  });

  test('every product finds its installer among the published asset names',
      () {
    final release = job('release');
    final all = release.substring(
      release.indexOf('            all)\n'),
      release.indexOf('            *)\n'),
    );
    const v = '0.7.10-beta.999';
    final published = RegExp(r'"dist/[^"]*/(Orvix-[^"/]+)"')
        .allMatches(all)
        .map((m) => m.group(1)!.replaceAll(r'$V', v))
        .toSet();
    expect(published, hasLength(10));
    for (final (target, abis) in <(UpdateTarget, List<String>)>[
      (UpdateTarget.androidTv, const []),
      (UpdateTarget.androidMobile, const []),
      (UpdateTarget.androidMobile, const ['arm64-v8a']),
      (UpdateTarget.androidMobile, const ['armeabi-v7a']),
      (UpdateTarget.androidMobile, const ['x86_64']),
      (UpdateTarget.windows, const []),
      (UpdateTarget.macos, const []),
      (UpdateTarget.ios, const []),
    ]) {
      final first = expectedAssetNames(target, v, androidAbis: abis).first;
      expect(published, contains(first), reason: '$target $abis');
    }
  });
}
