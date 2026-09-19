import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AI Sinhala waits before playback and restores one native subtitle renderer on failure', () {
    final details = File('lib/screens/details_screen.dart').readAsStringSync();
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(details, isNot(contains('AiSinhalaSubtitleService.prepareBuffered(')));
    expect(details, contains('aiSubtitle: null'));

    expect(player, contains('Opening video paused for AI Sinhala'));
    expect(player, contains('play: !aiPreferred'));
    expect(player, contains('Future<bool> _prepareAiSinhalaBeforePlayback()'));
    expect(player, contains('await widget.playback.player.play();'));
    expect(player, contains('Future<void> _restoreNativeSubtitleFallback()'));

    // alpha.13: text subtitles render only through Flutter SubtitleView.
    // libmpv native subtitle rendering is enabled only for bitmap/image tracks.
    expect(
      player,
      contains('await _setNativeSubtitleVisibility(_isImageSubtitleTrack(chosen));'),
    );
    expect(
      player,
      contains('await _setNativeSubtitleVisibility(_isImageSubtitleTrack(track));'),
    );
    expect(player, contains('tracks.where(_isEnglishTextTrack)'));

    expect(
      player,
      isNot(contains('unawaited(_prepareAiSinhalaAfterPlaybackStarts());')),
    );
  });
}
