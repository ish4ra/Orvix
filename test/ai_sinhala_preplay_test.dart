import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AI Sinhala is prepared before playback and fails open to native subtitles', () {
    final details = File('lib/screens/details_screen.dart').readAsStringSync();
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(details, contains('await AiSinhalaSubtitleService.prepareBuffered('));
    expect(details, contains("_status = 'AI Sinhala • matching this exact video file…';"));
    expect(details, contains('aiSubtitle: preparedAiSubtitle'));
    expect(
      details,
      contains('Opening the video with normal English/native subtitles instead.'),
    );

    expect(player, contains('final aiReady = _preparedAiSubtitle != null;'));
    expect(player, contains('await _setNativeSubtitleVisibility(!aiReady);'));
    expect(
      player,
      isNot(contains('unawaited(_prepareAiSinhalaAfterPlaybackStarts());')),
    );
  });
}
