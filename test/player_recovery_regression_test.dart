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

    expect(details, contains('_episodeForPinnedRelease'));
    expect(details, contains('seriesWide: item.kind == MediaKind.series'));
    expect(details, isNot(contains('onTap: item.kind == MediaKind.movie')));

    expect(player, contains('_preparePlayerExit'));
    expect(player, contains('WillPopScope'));
    expect(player, contains('_closing'));
    expect(player, isNot(contains('final wasPlaying = player.state.playing;')));

    // AI Sinhala fail-closed means English timing tracks stay hidden unless
    // the user explicitly switches back to a native subtitle track.
    expect(
      player,
      contains('await _setNativeSubtitleVisibility(false);'),
    );

    // Local P2P must not seek to the file tail for a subtitle hash.
    expect(service, contains("uri.host == '127.0.0.1'"));
    expect(service, contains('uri.port == 11470'));
    expect(service, contains('return _VideoProbe(fileName: fallbackName, size: fallbackSize);'));

    // Low-seed local streams should wait for a healthier cache before resume.
    expect(playback, contains("'cache-pause-initial': 'yes'"));
    expect(playback, contains("'cache-pause-wait': '8'"));
  });
}
