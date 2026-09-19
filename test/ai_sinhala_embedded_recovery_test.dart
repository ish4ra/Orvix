import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('startup uses full generated subtitle file instead of live cue AI', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final start =
        player.indexOf('Future<bool> _prepareAiSinhalaBeforePlayback()');
    final end =
        player.indexOf('Future<void> _restoreNativeSubtitleFallback()', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final startup = player.substring(start, end);

    expect(startup, contains('prepareGeneratedSinhalaFile('));
    expect(startup, contains('mk.SubtitleTrack.uri('));
    expect(startup, contains("language: 'si'"));
    expect(startup, isNot(contains('_tryPrepareEmbeddedAiTiming')));
    expect(startup, isNot(contains('_enableEmbeddedLiveAiFallback')));
    expect(startup, isNot(contains('translateCue(')));
  });

  test('generated subtitle is handed to normal player timing', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(
      player,
      contains(
        '// media_kit/libmpv owns timing, pause, seek and resume from this point.',
      ),
    );
    expect(player, contains('await _setNativeSubtitleDelayProperty(0);'));
    expect(player, contains('_transitionAi(AiSinhalaRuntimeMode.native);'));
  });
}
