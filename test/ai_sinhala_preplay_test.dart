import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AI Sinhala waits before playback and leaves normal playback untouched on failure', () {
    final details = File('lib/screens/details_screen.dart').readAsStringSync();
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(details, isNot(contains('AiSinhalaSubtitleService.prepareBuffered(')));
    expect(details, contains('aiSubtitle: null'));

    expect(player, contains('Opening video paused for AI Sinhala'));
    expect(player, contains('play: !aiPreferred'));
    expect(player, contains('Future<bool> _prepareAiSinhalaBeforePlayback()'));
    expect(player, contains('await widget.playback.player.play();'));
    expect(player, contains('Normal playback will continue.'));

    final openStart = player.indexOf('Future<void> _open()');
    final prepareStart =
        player.indexOf('Future<bool> _prepareAiSinhalaBeforePlayback()');
    final open = player.substring(openStart, prepareStart);
    expect(open, isNot(contains('await _restoreNativeSubtitleFallback();')));

    expect(
      player,
      isNot(contains('unawaited(_prepareAiSinhalaAfterPlaybackStarts());')),
    );
  });
}
