import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('update, shutdown and live P2P paths stay wired', () {
    final app = File('lib/app.dart').readAsStringSync();
    final update =
        File('lib/services/app_update_service.dart').readAsStringSync();
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final gate =
        File('lib/widgets/orvix_update_gate.dart').readAsStringSync();
    final torrent =
        File('lib/services/local_torrent_service.dart').readAsStringSync();
    final live =
        File('lib/services/free_p2p_live_probe_service.dart').readAsStringSync();
    final details =
        File('lib/screens/details_screen.dart').readAsStringSync();
    final tv =
        File('lib/screens/tv_source_browser_screen.dart').readAsStringSync();
    final android =
        File('tools/configure_android_build.py').readAsStringSync();
    final windows =
        File('windows/runner/flutter_window.cpp').readAsStringSync();
    final windowsMain =
        File('windows/runner/main.cpp').readAsStringSync();
    final installer = File('installer/orvix.iss').readAsStringSync();
    final releasePublisher =
        File('tools/publish_orvix_release.sh').readAsStringSync();
    final runnerCmake =
        File('windows/runner/CMakeLists.txt').readAsStringSync();
    final windowsCmake =
        File('windows/CMakeLists.txt').readAsStringSync();

    expect(app, contains('WidgetsBindingObserver'));
    expect(app, contains('AppLifecycleState.detached'));
    expect(app, contains('OrvixUpdateGate'));

    final packageVersion = RegExp(
      r'^version:\s*([^+\s]+)',
      multiLine: true,
    ).firstMatch(pubspec)?.group(1);
    final updaterVersion = RegExp(
      r"currentVersion\s*=\s*'([^']+)'",
    ).firstMatch(update)?.group(1);
    expect(packageVersion, isNotNull);
    expect(updaterVersion, packageVersion);
    expect(update, contains("name.contains('Windows-x64')"));
    expect(update, contains('Android-TV.apk'));
    expect(update, contains('Android-Mobile.apk'));
    expect(update, contains('sha256.bind(file.openRead())'));
    expect(update, isNot(contains('orvix_updater_helper.exe')));
    expect(update, contains('Process.start(\n        file.path'));
    expect(update, contains('ProcessStartMode.detached'));
    expect(update, contains('Duration(milliseconds: 700)'));
    expect(update, contains('await windowManager.close();'));
    expect(update, contains('exit(0)'));
    expect(update, isNot(contains('powershell.exe')));
    expect(runnerCmake, isNot(contains('add_executable(orvix_updater_helper')));
    expect(windowsCmake, isNot(contains('install(TARGETS orvix_updater_helper')));
    expect(installer, contains('CloseApplications=force'));
    expect(installer, contains('RestartApplications=no'));
    expect(installer, contains('function PrepareToInstall'));
    expect(installer, contains('orvix-stream-server.exe'));
    expect(installer, contains('taskkill.exe'));
    expect(installer, isNot(contains('powershell.exe')));
    expect(releasePublisher, contains('gh release create'));
    expect(releasePublisher, contains('--draft'));
    expect(releasePublisher, contains('gh release upload'));
    expect(releasePublisher, contains('--method PATCH'));
    expect(releasePublisher, contains('-F draft=false'));
    expect(releasePublisher, contains('-F prerelease=true'));
    expect(releasePublisher, contains('expected_count='));
    expect(releasePublisher, contains('.size > 0'));
    expect(windowsMain, contains('CreateMutexW'));
    expect(windowsMain, contains('OrvixDesktopSingleInstanceV1'));
    expect(windowsMain, contains('ERROR_ALREADY_EXISTS'));
    expect(windowsMain, contains('FindWindowW(nullptr, L"orvix")'));
    expect(windowsMain, contains('SetForegroundWindow(existing)'));
    expect(gate, contains('View what changed'));
    expect(gate, contains("label: const Text('Update')"));
    expect(update, contains("raw['assets_url']"));
    expect(update, contains('_fetchReleaseAssets('));
    expect(
      update,
      contains("'Cache-Control': 'no-cache, no-store, max-age=0'"),
    );
    expect(gate, contains('AppLifecycleState.resumed'));
    expect(gate, contains('Timer.periodic('));
    expect(gate, contains('Duration(minutes: 5)'));
    expect(gate, contains('Duration(seconds: 20)'));
    expect(update, contains('_releaseAssetFetchAttempts = 5'));
    expect(update, contains("'_orvix_check'"));
    expect(update, contains("'_orvix_asset_check'"));
    expect(update, contains("'per_page': '30'"));
    expect(
      gate,
      contains('Orvix will close; finish setup in the Windows installer'),
    );

    expect(torrent, contains('Future<LocalTorrentProbeResult> probe('));
    expect(torrent, contains('firstByteLatency'));
    expect(torrent, contains('sampleWindowsPassed'));
    expect(torrent, contains('preferredOffset = 8 * 1024 * 1024'));
    expect(live, contains('probeTopCandidates'));
    expect(live, contains('.take(6)'));
    expect(live, contains('retainSession: true'));
    expect(torrent, contains('prepareRetainedProbeForPlayback'));
    expect(torrent, contains('releaseRetainedProbeSessions'));
    expect(torrent, contains('await process.exitCode.timeout'));
    expect(torrent, contains('Duration(seconds: 3)'));
    expect(details, contains('liveProbe.rank(results, widget.sources)'));
    expect(tv, contains('_liveProbe.rank(_results, widget.sources)'));

    expect(android, contains('REQUEST_INSTALL_PACKAGES'));
    expect(android, contains('androidx.core.content.FileProvider'));
    expect(android, contains('"orvix/app_update"'));
    expect(android, contains('installApk'));
    expect(windows, contains('TerminateOwnedTorrentServers'));
    expect(windows, contains('orvix-stream-server.exe'));
  });

  test('future v0.7.6 beta releases must use atomic draft-first publishing', () {
    final workflows = Directory('.github/workflows')
        .listSync()
        .whereType<File>();

    final pattern = RegExp(r'orvix-v076-beta(\d+)-release\.yml$');
    for (final file in workflows) {
      final match = pattern.firstMatch(file.path.replaceAll('\\', '/'));
      if (match == null) continue;
      final beta = int.parse(match.group(1)!);
      if (beta < 32) continue;

      final workflow = file.readAsStringSync();
      expect(
        workflow,
        contains('tools/publish_orvix_release.sh'),
        reason:
            'beta.$beta must keep the release private until every asset is uploaded',
      );
    }
  });

}
