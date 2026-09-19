import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AI Sinhala opens media paused, calibrates, then starts playback', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(
      player,
      contains('Opening video paused to verify its real English subtitle track'),
    );
    expect(player, contains('Future<bool> _prepareAiSinhalaBeforePlayback()'));

    final openStart = player.indexOf('Future<void> _open()');
    final prepareStart =
        player.indexOf('Future<bool> _prepareAiSinhalaBeforePlayback()');
    final open = player.substring(openStart, prepareStart);

    expect(open, contains('play: !aiPreferred'));
    expect(
      open.indexOf('await widget.playback.open('),
      lessThan(open.indexOf('await _prepareAiSinhalaBeforePlayback()')),
    );
    expect(open, contains('await widget.playback.player.play();'));
  });

  test('loading overlay hides accelerated native-cue sampling', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(player, contains('if (_error == null && _aiSubtitleLoading)'));
    expect(player, contains("const Text(\n                            'Preparing AI Sinhala before playback'"));
  });
}
