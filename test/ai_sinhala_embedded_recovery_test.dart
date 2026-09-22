import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('automatic startup uses the complete embedded subtitle file as timing truth', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final openStart = player.indexOf('Future<void> _open()');
    final prepareStart =
        player.indexOf('Future<bool> _prepareAiSinhalaBeforePlayback()');
    final prepareEnd =
        player.indexOf('Future<void> _restoreNativeSubtitleFallback()', prepareStart);

    final open = player.substring(openStart, prepareStart);
    final prepare = player.substring(prepareStart, prepareEnd);

    expect(
      open.indexOf('await widget.playback.open('),
      lessThan(open.indexOf('await _prepareAiSinhalaBeforePlayback()')),
    );
    expect(open, contains('play: !aiPreferred'));
    expect(open, contains('await _loadGeneratedAiSubtitleTrack()'));
    expect(prepare, contains('prepareGeneratedSinhalaFromEmbeddedSubtitle('));
    expect(prepare, contains('_generatedAiSubtitlePath = generated.path'));
    expect(prepare, isNot(contains('_captureNativeEnglishSamples()')));
    expect(prepare, isNot(contains('OnlineSubtitleService.search(')));
    expect(prepare, isNot(contains('_enableEmbeddedLiveAiFallback(')));
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
