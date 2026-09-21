import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AI Sinhala opens media paused and does not show it until preparation finishes', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(
      player,
      contains('Opening video paused to verify its real English subtitle track'),
    );

    final openStart = player.indexOf('Future<void> _open()');
    final prepareStart =
        player.indexOf('Future<bool> _prepareAiSinhalaBeforePlayback()');
    final open = player.substring(openStart, prepareStart);

    expect(open, contains('play: deferAiForLocalP2p ? true : !aiPreferred'));
    expect(
      open.indexOf('await widget.playback.open('),
      lessThan(open.indexOf('await _prepareAiSinhalaBeforePlayback()')),
    );
    expect(open, contains('await _tryPrepareEmbeddedAiTiming()'));
    expect(
      open,
      contains('Starting local P2P normally; AI Sinhala will follow'),
    );
    expect(open, contains('await widget.playback.player.play();'));
    expect(player, contains('if (_error == null && _aiSubtitleLoading)'));
    expect(player, contains('Preparing AI Sinhala before playback'));
  });

  test('native timing mode keeps the English track selected but invisible', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(player, contains('await _setNativeSubtitleVisibility(false);'));
    expect(player, contains('_timingTrackSelected = true;'));
    expect(player, contains('_timingTrackIsText = true;'));
    expect(player, contains('player.stream.subtitle.listen(_onEmbeddedSubtitleCue)'));
  });
}
