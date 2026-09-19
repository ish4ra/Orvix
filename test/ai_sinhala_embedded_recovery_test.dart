import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AI Sinhala primes embedded tracks behind a loading cover', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(player, contains('Future<void> _primeSubtitleTracksForAiPreflight()'));
    expect(player, contains("await player.setVolume(0);"));
    expect(player, contains('await player.play();'));
    expect(player, contains('await player.pause();'));
    expect(player, contains('await _primeSubtitleTracksForAiPreflight();'));
    expect(player, contains('ColoredBox('));
    expect(player, contains('color: Colors.black'));
  });

  test('embedded English can fall back to direct live Sinhala translation', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(player, contains('Future<bool> _enableEmbeddedLiveAiFallback'));
    expect(player, contains('_transitionAi(AiSinhalaRuntimeMode.liveEmbedded)'));
    expect(player, contains('AiSinhalaSubtitleService.translateCue('));
    expect(player, contains('_liveTranslationFailures < 3'));
    expect(
      player,
      contains("AI translation service is unavailable — using English subtitles."),
    );
  });

  test('selected unlabeled text track is accepted as timing source', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(player, contains('_isUnlabeledTextTrack(current)'));
  });
}
