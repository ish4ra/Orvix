import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('strict startup no longer depends on embedded cue warmup or live AI', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final start =
        player.indexOf('Future<bool> _prepareAiSinhalaBeforePlayback()');
    final end =
        player.indexOf('Future<void> _restoreNativeSubtitleFallback()', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final startup = player.substring(start, end);

    expect(startup, contains('prepareExactFileFully('));
    expect(startup, isNot(contains('_primeSubtitleTracksForAiPreflight')));
    expect(startup, isNot(contains('_tryPrepareEmbeddedAiTiming')));
    expect(startup, isNot(contains('_enableEmbeddedLiveAiFallback')));
    expect(startup, isNot(contains('translateCue(')));
  });

  test('legacy embedded helpers cannot become startup dependencies again', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(player, contains('Future<bool> _tryPrepareEmbeddedAiTiming()'));
    expect(player, contains('Future<bool> _enableEmbeddedLiveAiFallback'));
    expect(
      player.indexOf('_tryPrepareEmbeddedAiTiming();'),
      equals(-1),
    );
    expect(
      player.indexOf('await _primeSubtitleTracksForAiPreflight();'),
      equals(-1),
    );
  });
}
