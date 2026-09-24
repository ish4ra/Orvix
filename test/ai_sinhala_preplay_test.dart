import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('automatic AI Sinhala starts from native player cues without full-SRT blocking', () {
    final details = File('lib/screens/details_screen.dart').readAsStringSync();
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(
      details,
      contains('_legacyCompleteFileAiPreflightEnabled => false'),
    );

    final openStart = player.indexOf('Future<void> _open()');
    final openEnd = player.indexOf('void _onPlaybackError', openStart);
    final open = player.substring(openStart, openEnd);
    expect(open, contains('final useProgressiveNativeCueAi ='));
    expect(open, contains('play: !(aiReady || useProgressiveNativeCueAi)'));
    expect(open, contains('await _activateProgressiveNativeCueAi();'));
    expect(open, contains('await widget.playback.player.play();'));
    expect(
      open,
      isNot(contains('await _prepareAiSinhalaBeforePlayback();')),
    );
  });

  test('legacy complete-file helper remains available outside automatic startup', () {
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

  test('turning AI Sinhala on is progressive and does not pause playback', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final start =
        player.indexOf('Future<void> _setAiSinhalaEnabledFromPlayer(bool enabled)');
    final end =
        player.indexOf('Future<void> _loadSubtitlePreferences()', start);
    final toggle = player.substring(start, end);

    expect(
      toggle,
      contains('await _activateProgressiveNativeCueAi('),
    );
    expect(
      toggle,
      contains('unawaited(_discoverNativeCueAiAfterPlayback());'),
    );
    expect(toggle, isNot(contains('await player.pause();')));
    expect(
      toggle,
      isNot(contains('await _prepareAiSinhalaBeforePlayback();')),
    );
    expect(
      toggle,
      isNot(contains('await _loadGeneratedAiSubtitleTrack();')),
    );
  });
}
