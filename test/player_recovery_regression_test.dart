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

    // TV free P2P starts on MPV, can hand off safely to Exo, and Exo fully
    // disposes its controller before a reverse engine switch.
    expect(details, contains('fallbackToExo: tvFreeP2pAuto'));
    expect(player, contains('_runStartupFallback'));
    expect(player, contains('await _preparePlayerExit();'));
    expect(exo, contains('await controller.dispose();'));
    expect(exo, contains('ReadingOrderTraversalPolicy'));
    expect(
      exo,
      contains('if (!_surfaceFocus.hasPrimaryFocus) return KeyEventResult.ignored;'),
    );
  });
}
