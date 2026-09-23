import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('automatic Windows startup uses the complete pre-player embedded subtitle as timing truth', () {
    final details = File('lib/screens/details_screen.dart').readAsStringSync();
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final engineIndex =
        details.indexOf('OrvixMediaEngineService.instance.prepare(');
    final playerIndex = details.indexOf('await _openMpvPlayer(');
    expect(engineIndex, greaterThanOrEqualTo(0));
    expect(playerIndex, greaterThan(engineIndex));
    expect(details, contains('prepareGeneratedSinhalaFromEngineEmbedded('));
    expect(details, contains('preparedAiSubtitleFile: preparedAiSubtitleFile'));

    final openStart = player.indexOf('Future<void> _open()');
    final openEnd = player.indexOf('void _onPlaybackError', openStart);
    final open = player.substring(openStart, openEnd);
    expect(open, contains('final preprepared ='));
    expect(open, contains('play: !(aiReady || usePlayerPreflight)'));
    expect(open, contains('await _loadGeneratedAiSubtitleTrack()'));
    expect(
      open.indexOf('await _loadGeneratedAiSubtitleTrack()'),
      lessThan(open.indexOf('await widget.playback.player.play();')),
    );
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
