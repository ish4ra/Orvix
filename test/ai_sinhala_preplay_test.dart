import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AI Sinhala startup keeps playback paused until the complete SRT is attached', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final openStart = player.indexOf('Future<void> _open()');
    final prepareStart =
        player.indexOf('Future<bool> _prepareAiSinhalaBeforePlayback()');
    final open = player.substring(openStart, prepareStart);

    expect(open, contains('play: !aiPreferred'));
    expect(
      open.indexOf('await widget.playback.open('),
      lessThan(open.indexOf('await _prepareAiSinhalaBeforePlayback()')),
    );
    expect(
      open.indexOf('await _prepareAiSinhalaBeforePlayback()'),
      lessThan(open.indexOf('await _loadGeneratedAiSubtitleTrack()')),
    );
    expect(
      open.indexOf('await _loadGeneratedAiSubtitleTrack()'),
      lessThan(open.indexOf('await widget.playback.player.play();')),
    );
    expect(
      player,
      contains('Preparing the complete embedded Sinhala subtitle before playback'),
    );
    expect(
      player,
      contains('if (_error == null && _aiSubtitleLoading)'),
    );
    expect(
      player,
      isNot(contains('_aiSubtitleLoading &&\n                    !_playbackStarted')),
    );
  });

  test('automatic preparation translates the complete embedded track, not live cues', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final start =
        player.indexOf('Future<bool> _prepareAiSinhalaBeforePlayback()');
    final end =
        player.indexOf('Future<void> _restoreNativeSubtitleFallback()', start);
    final prepare = player.substring(start, end);

    expect(
      prepare,
      contains('prepareGeneratedSinhalaFromEmbeddedSubtitle('),
    );
    expect(prepare, contains('_generatedAiSubtitlePath = generated.path'));
    expect(prepare, isNot(contains('OnlineSubtitleService.search(')));
    expect(prepare, isNot(contains('_enableEmbeddedLiveAiFallback(')));
    expect(prepare, isNot(contains('ensureTranslatedAround(')));
  });

  test('turning AI Sinhala on pauses, generates, attaches, then resumes', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final start =
        player.indexOf('Future<void> _setAiSinhalaEnabledFromPlayer(bool enabled)');
    final end =
        player.indexOf('Future<void> _loadSubtitlePreferences()', start);
    final toggle = player.substring(start, end);

    expect(toggle, contains('await player.pause();'));
    expect(toggle, contains('await _prepareAiSinhalaBeforePlayback();'));
    expect(toggle, contains('await _loadGeneratedAiSubtitleTrack();'));
    expect(toggle, contains('await player.play();'));
    expect(
      toggle.indexOf('await player.pause();'),
      lessThan(toggle.indexOf('await _prepareAiSinhalaBeforePlayback();')),
    );
    expect(
      toggle.indexOf('await _loadGeneratedAiSubtitleTrack();'),
      lessThan(toggle.lastIndexOf('await player.play();')),
    );
  });
}
