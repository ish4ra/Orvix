import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AI Sinhala completes network translation before libmpv/P2P open', () {
    final details = File('lib/screens/details_screen.dart').readAsStringSync();
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(details, isNot(contains('AiSinhalaSubtitleService.prepareBuffered(')));
    expect(details, contains('aiSubtitle: null'));

    expect(
      player,
      contains('Preparing Sinhala subtitle before opening video'),
    );
    expect(player, contains('Future<bool> _prepareAiSinhalaBeforePlayback()'));

    final openStart = player.indexOf('Future<void> _open()');
    final prepareStart =
        player.indexOf('Future<bool> _prepareAiSinhalaBeforePlayback()');
    final open = player.substring(openStart, prepareStart);
    expect(
      open.indexOf('await _prepareAiSinhalaBeforePlayback()'),
      lessThan(open.indexOf('await widget.playback.open(')),
    );
    expect(open, contains('play: !aiReady'));
    expect(open, contains('await widget.playback.player.play();'));
    expect(open, isNot(contains('await _restoreNativeSubtitleFallback();')));

    expect(
      player,
      isNot(contains('unawaited(_prepareAiSinhalaAfterPlaybackStarts());')),
    );
  });
}
