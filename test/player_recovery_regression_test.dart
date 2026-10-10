import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('player and pinned-source escape regressions stay fixed', () {
    final details = File('lib/screens/details_screen.dart').readAsStringSync();
    final player = File('lib/screens/player_screen.dart').readAsStringSync();
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();
    final playback =
        File('lib/services/playback_service.dart').readAsStringSync();
    final exo =
        File('lib/screens/android_exo_player_screen.dart').readAsStringSync();
    final app = File('lib/app.dart').readAsStringSync();

    expect(details, contains('_episodeForPinnedRelease'));
    expect(details, contains('seriesWide: item.kind == MediaKind.series'));
    expect(details, isNot(contains('onTap: item.kind == MediaKind.movie')));

    expect(player, contains('_preparePlayerExit'));
    expect(player, contains('WillPopScope'));
    expect(player, contains('_closing'));
    expect(player, isNot(contains('final wasPlaying = player.state.playing;')));

    expect(
      player,
      contains('await _setNativeSubtitleVisibility(false);'),
    );

    // The bundled stream-server computes the canonical hash for the exact
    // selected torrent file index before libmpv opens. This avoids the old
    // playback-time probe race while still giving OpenSubtitles exact timing.
    expect(service, contains("uri.host == '127.0.0.1'"));
    expect(service, contains('uri.port == 11470'));
    expect(service, contains("path: '/opensubHash'"));
    expect(service, contains("'videoUrl': videoUri.toString()"));

    // Low-seed local streams should wait for a healthier cache before resume.
    expect(playback, contains("'cache-pause-initial': 'yes'"));
    expect(playback, contains("'cache-pause-wait': '8'"));

    // Returning from a title must not remount Home and lose scroll/catalog
    // state merely because library/watch state changed.
    expect(
      app,
      isNot(contains('HomeScreen(\n        key: ValueKey(_libraryRevision)')),
    );
    expect(app, contains("key: ValueKey('media-library-\$_libraryRevision')"));

    // Android Auto starts on subtitle-capable MPV, can hand off safely to Exo
    // when MPV itself cannot start, and Exo fully disposes its controller
    // before a reverse engine switch.
    expect(details, contains('fallbackToExo: androidAutoFallbackToExo'));
    expect(details, contains('!useLocalMediaBridge'));
    expect(details, contains('source?.isMagnet != true'));
    expect(player, contains('_runStartupFallback'));
    expect(
      player,
      contains('if (!await _exit.leave(PlayerExitIntent.startupFallback)) return;'),
    );
    // The native ExoPlayer is released (and awaited) before the route pops.
    expect(exo, contains('await controller.close();'));
    expect(exo, contains('ReadingOrderTraversalPolicy'));
    expect(
      exo,
      contains('if (!_surfaceFocus.hasPrimaryFocus) return KeyEventResult.ignored;'),
    );

    // Automatic AI Sinhala now opens the real player first and translates
    // the exact native English cue stream progressively. Complete-file helpers
    // remain available, but they no longer gate normal startup.
    expect(
      details,
      contains('_legacyCompleteFileAiPreflightEnabled => true'),
    );
    expect(player, contains('final useProgressiveNativeCueAi ='));
    expect(player, contains('play: !(aiReady || useProgressiveNativeCueAi)'));
    expect(player, contains('await _activateProgressiveNativeCueAi();'));
    expect(player, contains('native-cue-ai-ready'));
    expect(player, isNot(contains('deferAiForLocalP2p')));

    // The native torrent endpoint should be warmed with real bytes before MPV
    // opens it on Windows.
    final torrent =
        File('lib/services/local_torrent_service.dart').readAsStringSync();
    expect(torrent, contains('Platform.isWindows'));
    expect(torrent, contains('targetBytes: 2 * 1024 * 1024'));
    expect(torrent, contains('_primeLocalStream'));

    // Player Back is serialized so a second Back press cannot pop the route
    // while the first native teardown is still in progress.
    expect(player, contains('late final PlayerExitController _exit'));
    expect(player, contains('teardown: _preparePlayerExitInternal,'));
    expect(player, contains('await widget.playback.player.pause();'));
    expect(
      player,
      contains('Duration(milliseconds: 180)'),
    );

    // Local P2P is detached only after the MPV route has fully closed.
    expect(torrent, contains('Future<void> releaseCurrentStream()'));
    expect(details, contains('await LocalTorrentService.instance.releaseCurrentStream();'));

    // Focus/selection remains visible through fill/border/scale, not a neon halo.
    expect(player, isNot(contains('Color(0x883CFF00)')));
    expect(
      exo,
      isNot(contains('primary.withValues(alpha: .34)')),
    );

    // Back navigation is a strict one-step stack. The modal source picker
    // closes before player push, then reopens from cached results when the
    // player returns. This avoids rendering the player underneath the sheet.
    expect(details, contains('FreeP2pLiveProbeService? probeSession'));
    expect(details, contains('final probeSession = autoProbeSession ??'));
    expect(details, contains('FreeP2pLiveProbeService('));
    expect(details, contains('parseMediaRuntime(item.runtime)'));
    // The loop lives in runSourcePlaybackLoop so Back during pre-player
    // preparation can also return to the same list.
    final preparation =
        File('lib/services/playback_preparation.dart').readAsStringSync();
    expect(details, contains('await runSourcePlaybackLoop<SourceResult>('));
    expect(details, contains('isActive: () => mounted'));
    expect(preparation, contains('while (isActive())'));
    expect(details, contains('probeSession: probeSession'));
    expect(details, contains('Player returned, or Back cancelled the preparation: the loop'));
    expect(details, contains('reopens the source picker'));
    expect(details, contains('already-resolved results and cached live-probe ranking'));
    expect(details, isNot(contains('onPlaySource: (selected) async')));
    expect(player, contains('await _exit.leave(PlayerExitIntent.backButton);'));
    expect(player, contains('return _exit.allowSystemPop();'));
    expect(player, contains('Navigator.of(context).pop();'));

  });
}
