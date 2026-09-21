import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('update, shutdown and live P2P paths stay wired', () {
    final app = File('lib/app.dart').readAsStringSync();
    final update =
        File('lib/services/app_update_service.dart').readAsStringSync();
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
    final installer = File('installer/orvix.iss').readAsStringSync();
    final helper =
        File('windows/runner/updater_helper.cpp').readAsStringSync();
    final runnerCmake =
        File('windows/runner/CMakeLists.txt').readAsStringSync();
    final windowsCmake =
        File('windows/CMakeLists.txt').readAsStringSync();

    expect(app, contains('WidgetsBindingObserver'));
    expect(app, contains('AppLifecycleState.detached'));
    expect(app, contains('OrvixUpdateGate'));

    expect(update, contains("currentVersion = '0.7.6-beta.1'"));
    expect(update, contains("name.contains('Windows-x64')"));
    expect(update, contains('Android-TV.apk'));
    expect(update, contains('Android-Mobile.apk'));
    expect(update, contains('sha256.bind(file.openRead())'));
    expect(update, contains('orvix_updater_helper.exe'));
    expect(update, contains('ProcessStartMode.detached'));
    expect(update, isNot(contains('powershell.exe')));
    expect(update, isNot(contains("'/CLOSEAPPLICATIONS'")));
    expect(helper, contains('WaitForSingleObject(parent, 30000)'));
    expect(helper, contains('CreateProcessW'));
    expect(helper, contains('FindInstalledOrvix'));
    expect(helper, contains('InstallLocation'));
    expect(helper, contains('FOLDERID_LocalAppData'));
    expect(helper, contains('--no-restart'));
    expect(runnerCmake, contains('add_executable(orvix_updater_helper'));
    expect(windowsCmake, contains('install(TARGETS orvix_updater_helper'));
    expect(installer, isNot(contains('powershell.exe')));
    expect(installer, isNot(contains('Check: WizardSilent')));
    expect(installer, isNot(contains('function PrepareToInstall')));
    expect(gate, contains('View what changed'));
    expect(gate, contains("label: const Text('Update')"));

    expect(torrent, contains('Future<LocalTorrentProbeResult> probe('));
    expect(torrent, contains('firstByteLatency'));
    expect(torrent, contains('sampleWindowsPassed'));
    expect(torrent, contains('preferredOffset = 8 * 1024 * 1024'));
    expect(live, contains('probeTopCandidates'));
    expect(live, contains('.take(6)'));
    expect(live, contains('retainSession: true'));
    expect(torrent, contains('prepareRetainedProbeForPlayback'));
    expect(torrent, contains('releaseRetainedProbeSessions'));
    expect(details, contains('liveProbe.rank(results, widget.sources)'));
    expect(tv, contains('_liveProbe.rank(_results, widget.sources)'));

    expect(android, contains('REQUEST_INSTALL_PACKAGES'));
    expect(android, contains('androidx.core.content.FileProvider'));
    expect(android, contains('"orvix/app_update"'));
    expect(android, contains('installApk'));
    expect(windows, contains('TerminateOwnedTorrentServers'));
    expect(windows, contains('orvix-stream-server.exe'));
  });
}
