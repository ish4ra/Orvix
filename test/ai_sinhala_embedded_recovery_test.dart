import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('automatic startup uses the active player embedded text track as timing truth', () {
    final details = File('lib/screens/details_screen.dart').readAsStringSync();
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(
      details,
      contains('_legacyCompleteFileAiPreflightEnabled => false'),
    );
    final openStart = player.indexOf('Future<void> _open()');
    final openEnd = player.indexOf('void _onPlaybackError', openStart);
    final open = player.substring(openStart, openEnd);
    expect(open, contains('final useProgressiveNativeCueAi ='));
    expect(open, contains('play: !(aiReady || useProgressiveNativeCueAi)'));
    expect(open, contains('await _activateProgressiveNativeCueAi();'));
    expect(player, contains('_bestNativeEnglishTextTrack()'));
    expect(player, contains('_enableEmbeddedLiveAiFallback('));
    expect(player, contains('native-cue-ai-ready'));
  });

  test('complete-file preparation never warms the video by secretly playing it', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final start =
        player.indexOf('Future<bool> _prepareAiSinhalaBeforePlayback()');
    final end =
        player.indexOf('Future<void> _restoreNativeSubtitleFallback()', start);
    final prepare = player.substring(start, end);

    expect(prepare, isNot(contains('await player.play();')));
    expect(prepare, isNot(contains('await player.setRate(')));
    expect(prepare, isNot(contains('_primeSubtitleTracksForAiPreflight()')));
    expect(prepare, contains('await _setNativeSubtitleVisibility(false);'));
  });
}
