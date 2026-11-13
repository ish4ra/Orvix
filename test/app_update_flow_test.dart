import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/app_update_service.dart';
import 'package:orvix/widgets/update_check_section.dart';

import 'support/fake_github.dart';

class _Calls {
  final List<String> apks = [];
  final List<File> windows = [];
  final List<File> macos = [];
  final List<Uri> opened = [];
}

AppUpdateService _service(
  FakeGitHub github, {
  String installed = '0.7.10-beta.3',
  UpdatePlatform platform = const UpdatePlatform(UpdateTarget.androidTv),
  _Calls? calls,
  Future<String?> Function(String path)? android,
  Directory? downloads,
}) {
  final record = calls ?? _Calls();
  return AppUpdateService(
    client: github.client(),
    installedVersionLoader: () async => installed,
    platformLoader: () async => platform,
    downloadDirectory: () async =>
        downloads ?? Directory.systemTemp.createTempSync('orvix-update-test'),
    androidInstaller: android ??
        (path) async {
          record.apks.add(path);
          return 'installer_opened';
        },
    windowsInstallerLauncher: (file) async => record.windows.add(file),
    macosRevealer: (file) async => record.macos.add(file),
    urlOpener: (uri) async {
      record.opened.add(uri);
      return true;
    },
    sleep: (_) async {},
  );
}

/// A release whose TV APK is served with a correct (or wrong) checksum.
FakeGitHub _downloadable(String tag, List<int> bytes, {String? digest}) {
  final name = 'Orvix-$tag-Android-TV.apk';
  final entry = release(tag, assets: const []);
  entry['assets'] = [
    {
      'name': name,
      'browser_download_url': '$repoDownload/$tag/$name',
      'size': bytes.length,
      'digest': digest ?? 'sha256:${sha256.convert(bytes)}',
      'state': 'uploaded',
    }
  ];
  return FakeGitHub([
    [entry]
  ])..files['$repoDownload/$tag/$name'] = bytes;
}

void main() {
  group('automatic check', () {
    test('a newer public stable is offered', () async {
      final service = _service(FakeGitHub([
        [release('v0.7.10'), release('v0.7.10-beta.3')]
      ]));
      final update = await service.checkAutomatic();
      expect(update!.version, '0.7.10');
      expect(update.prerelease, isFalse);
      expect(update.notes, 'Notes for v0.7.10');
    });

    test('a newer public beta, even beta.999, is never offered', () async {
      final service = _service(FakeGitHub([
        [release('v0.7.10-beta.999'), release('v0.7.10-beta.4')]
      ]));
      expect(await service.checkAutomatic(), isNull);
    });

    test('a private draft is never offered', () async {
      final service = _service(FakeGitHub([
        [release('v0.7.11', draft: true)]
      ]));
      expect(await service.checkAutomatic(), isNull);
    });

    test('an older or the same stable is never offered', () async {
      for (final installed in ['0.7.10', '0.7.11-beta.1', '0.7.11']) {
        final service = _service(
          FakeGitHub([
            [release('v0.7.10')]
          ]),
          installed: installed,
        );
        expect(await service.checkAutomatic(), isNull, reason: installed);
      }
    });

    test('a failed check never prompts', () async {
      final service = _service(FakeGitHub([rateLimited()])
        ..feed = atomFeed(['v0.7.11']));
      expect(await service.checkAutomatic(), isNull);
    });

    test('iOS keeps no automatic prompt', () async {
      final service = _service(
        FakeGitHub([
          [release('v0.7.11')]
        ]),
        platform: const UpdatePlatform(UpdateTarget.ios),
      );
      expect(await service.checkAutomatic(), isNull);
    });
  });

  group('manual check', () {
    test('signed out, with no account at all, public updates work', () async {
      // AppUpdateService has no account dependency; this is the whole setup.
      final report = await _service(FakeGitHub([
        [release('v0.7.10-beta.4')]
      ])).checkForUpdateReport();
      expect(report.status, UpdateCheckStatus.available);
      final summary = describeUpdateCheck(report);
      expect(summary.headline, 'Orvix 0.7.10-beta.4 (beta) is available');
      expect(summary.actionLabel, 'Install beta');
      expect(summary.canInstall, isTrue);
      expect(summary.details.join(' '), contains('prerelease'));
    });

    test('a stable update is labelled stable', () async {
      final report = await _service(FakeGitHub([
        [release('v0.7.10')]
      ])).checkForUpdateReport();
      final summary = describeUpdateCheck(report);
      expect(summary.headline, 'Orvix 0.7.10 is available');
      expect(summary.actionLabel, 'Install update');
      expect(summary.details, contains('Stable release from GitHub.'));
    });

    test('up to date only after a successful check', () async {
      final report = await _service(FakeGitHub([
        [release('v0.7.10-beta.3'), release('v0.7.9')]
      ])).checkForUpdateReport();
      expect(report.status, UpdateCheckStatus.upToDate);
      expect(describeUpdateCheck(report).headline, 'Orvix is up to date');
    });

    test('failures are explained and never shown as up to date', () async {
      final cases = <FakeGitHub, String>{
        FakeGitHub([rateLimited()]): "GitHub's update limit was reached",
        FakeGitHub([const []])..offline = true: 'Could not check for updates',
        FakeGitHub([const []])..hang = false: 'Orvix is up to date',
      };
      for (final entry in cases.entries) {
        final report =
            await _service(entry.key).checkForUpdateReport();
        final summary = describeUpdateCheck(report);
        expect(summary.headline, entry.value);
        if (entry.value != 'Orvix is up to date') {
          expect(summary.failed, isTrue);
          expect(summary.canInstall, isFalse);
          expect(report.failed, isTrue);
        }
      }
    });

    test('a rate limit names when to retry', () async {
      final reset = DateTime(2026, 10, 14, 18, 5);
      final report = await _service(FakeGitHub([
        rateLimited(
            resetEpochSeconds: reset.toUtc().millisecondsSinceEpoch ~/ 1000)
      ])).checkForUpdateReport();
      final summary =
          describeUpdateCheck(report, now: DateTime(2026, 10, 14, 17, 30));
      expect(summary.details.last, contains('after 18:05'));
    });

    test('a missing installer for this device is explained', () async {
      final report = await _service(
        FakeGitHub([
          [release('v0.7.10-beta.6', assets: androidAssets('0.7.10-beta.6'))]
        ]),
        platform: const UpdatePlatform(UpdateTarget.windows),
      ).checkForUpdateReport();
      expect(report.status, UpdateCheckStatus.noCompatibleAsset);
      final summary = describeUpdateCheck(report);
      expect(summary.headline,
          'Orvix 0.7.10-beta.6 has no installer for this device yet');
      expect(summary.canInstall, isFalse);
    });

    test('iOS is told about the update and gets the release page', () async {
      final calls = _Calls();
      final service = _service(
        FakeGitHub([
          [release('v0.7.11')]
        ]),
        platform: const UpdatePlatform(UpdateTarget.ios),
        calls: calls,
      );
      final report = await service.checkForUpdateReport();
      final summary = describeUpdateCheck(report);
      expect(summary.opensReleasePage, isTrue);
      expect(summary.actionLabel, 'Open release page');
      expect(summary.details.join(' '), contains('iOS does not let apps'));
      final result =
          await service.install(report.update!, File('unused.ipa'));
      expect(result, AppUpdateInstallResult.openedReleasePage);
      expect(calls.opened.single.toString(),
          'https://github.com/ish4ra/Orvix/releases/tag/v0.7.11');
    });

    test('an unknown installed version is reported', () async {
      final report = await _service(FakeGitHub([const []]),
              installed: 'not-a-version')
          .checkForUpdateReport();
      expect(report.status, UpdateCheckStatus.installedVersionUnknown);
      expect(describeUpdateCheck(report).failed, isTrue);
    });
  });

  group('download and verification', () {
    test('a verified download goes to the Android installer', () async {
      final bytes = List<int>.generate(5000, (i) => i % 251);
      final calls = _Calls();
      final service =
          _service(_downloadable('v0.7.11', bytes), calls: calls);
      final update = (await service.checkForUpdateReport()).update!;
      final progress = <double>[];
      final file = await service.download(update, onProgress: progress.add);
      expect(await file.readAsBytes(), bytes);
      expect(progress.last, 1.0);
      expect(await service.install(update, file),
          AppUpdateInstallResult.installerOpened);
      expect(calls.apks.single, file.path);
    });

    test('a checksum mismatch deletes the file and never installs', () async {
      final calls = _Calls();
      final service = _service(
        _downloadable('v0.7.11', List.filled(100, 7), digest: 'sha256:$digestHex'),
        calls: calls,
      );
      final update = (await service.checkForUpdateReport()).update!;
      await expectLater(
        service.download(update),
        throwsA(isA<UpdateFailure>().having(
            (e) => e.message, 'message', contains('checksum'))),
      );
      expect(calls.apks, isEmpty);
    });

    test('a missing download (404) fails once with a clear error', () async {
      final github = _downloadable('v0.7.11', [1, 2, 3]);
      github.files.clear();
      final service = _service(github);
      final update = (await service.checkForUpdateReport()).update!;
      final before = github.requests.length;
      await expectLater(
        service.download(update),
        throwsA(isA<UpdateFailure>()
            .having((e) => e.message, 'message', contains('HTTP 404'))
            .having((e) => e.retryable, 'retryable', isFalse)),
      );
      expect(github.requests.length - before, 1);
    });

    test('a download can be retried after a failure', () async {
      final github = _downloadable('v0.7.11', [1, 2, 3]);
      final bytes = github.files.values.single;
      github.files.clear();
      final service = _service(github);
      final update = (await service.checkForUpdateReport()).update!;
      await expectLater(service.download(update), throwsA(isA<UpdateFailure>()));
      github.files['$repoDownload/v0.7.11/Orvix-v0.7.11-Android-TV.apk'] = bytes;
      final file = await service.download(update);
      expect(await file.readAsBytes(), bytes);
    });

    test('a non-HTTPS asset URL is refused before downloading', () async {
      final service = _service(FakeGitHub([const []]));
      const update = AppUpdateInfo(
        tag: 'v0.7.11',
        version: '0.7.11',
        title: 't',
        notes: '',
        releaseUrl: 'https://github.com/ish4ra/Orvix/releases/tag/v0.7.11',
        assetName: 'Orvix-v0.7.11-Android-TV.apk',
        assetUrl: 'http://github.com/x.apk',
      );
      await expectLater(service.download(update), throwsA(isA<UpdateFailure>()));
    });
  });

  group('installer handoff', () {
    final update = const AppUpdateInfo(
      tag: 'v0.7.11',
      version: '0.7.11',
      title: 't',
      notes: '',
      releaseUrl: 'https://github.com/ish4ra/Orvix/releases/tag/v0.7.11',
      assetName: 'Orvix-v0.7.11-Android-TV.apk',
      assetUrl: '$repoDownload/v0.7.11/Orvix-v0.7.11-Android-TV.apk',
    );

    File tempFile() {
      final dir = Directory.systemTemp.createTempSync('orvix-install-test');
      return File('${dir.path}/update.bin')..writeAsBytesSync([1, 2, 3]);
    }

    test('an APK downgrade (lower versionCode) is refused and deleted',
        () async {
      final file = tempFile();
      final service = _service(FakeGitHub([const []]),
          android: (_) async => throw PlatformException(
              code: 'version_code_not_newer', message: '4200 < 4226'));
      await expectLater(
        service.install(update, file),
        throwsA(isA<UpdateFailure>()
            .having((e) => e.message, 'message', contains('version code'))
            .having((e) => e.retryable, 'retryable', isFalse)),
      );
      expect(file.existsSync(), isFalse);
    });

    test('an APK for another package is refused', () async {
      final service = _service(FakeGitHub([const []]),
          android: (_) async =>
              throw PlatformException(code: 'package_mismatch'));
      await expectLater(service.install(update, tempFile()),
          throwsA(isA<UpdateFailure>()));
    });

    test('the unknown-sources permission request is reported', () async {
      final service = _service(FakeGitHub([const []]),
          android: (_) async => 'permission_required');
      expect(await service.install(update, tempFile()),
          AppUpdateInstallResult.permissionRequired);
    });

    test('an installer that cannot open falls back to the release page',
        () async {
      final calls = _Calls();
      final service = _service(FakeGitHub([const []]),
          calls: calls,
          android: (_) async =>
              throw PlatformException(code: 'apk_install_failed'));
      expect(await service.install(update, tempFile()),
          AppUpdateInstallResult.openedReleasePage);
      expect(calls.opened, hasLength(1));
    });

    test('Windows hands the installer to Windows', () async {
      final calls = _Calls();
      final file = tempFile();
      final service = _service(FakeGitHub([const []]),
          calls: calls, platform: const UpdatePlatform(UpdateTarget.windows));
      expect(await service.install(update, file),
          AppUpdateInstallResult.installerOpened);
      expect(calls.windows.single.path, file.path);
      expect(calls.apks, isEmpty);
    });

    test('macOS reveals the download instead of claiming to install it',
        () async {
      final calls = _Calls();
      final file = tempFile();
      final service = _service(FakeGitHub([const []]),
          calls: calls, platform: const UpdatePlatform(UpdateTarget.macos));
      expect(await service.install(update, file),
          AppUpdateInstallResult.revealedDownload);
      expect(calls.macos.single.path, file.path);
    });

    test('private builds are not downloadable from the public updater',
        () async {
      final service = _service(FakeGitHub([const []]));
      const private = AppUpdateInfo(
        tag: 'v0.7.11',
        version: '0.7.11',
        title: 't',
        notes: '',
        releaseUrl: '',
        assetName: 'x.apk',
        assetUrl: '',
        internalVersion: '0.7.11',
      );
      await expectLater(service.download(private), throwsA(isA<UpdateFailure>()));
    });
  });
}
