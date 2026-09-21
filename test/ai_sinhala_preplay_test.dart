import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AI Sinhala never covers already-playing local P2P while buffering', () {
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
    expect(
      player,
      contains(
        '_aiSubtitleLoading &&\n'
        '                    !_playbackStarted',
      ),
    );
  });

  test('native timing mode keeps English as a visible safety fallback until Sinhala is ready', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(player, contains('_timingTrackSelected = true;'));
    expect(player, contains('_timingTrackIsText = true;'));
    expect(player, contains('player.stream.subtitle.listen(_onEmbeddedSubtitleCue)'));
    expect(player, contains('await _setNativeSubtitleVisibility(true);'));
    expect(player, contains('unawaited(_setNativeSubtitleVisibility(false));'));
  });
}
