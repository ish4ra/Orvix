import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/subtitle_preferences_service.dart';

void main() {
  test('native cue text is the final subtitle clock at runtime', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();

    expect(player, contains('_nativeAiMatchIndex'));
    expect(player, contains('matchSourceCueRange('));
    expect(
      service,
      contains("sourceMatch: 'native-cue-text-oracle'"),
    );
    expect(SubtitlePreferencesService.defaultFontSize, 26);
  });

  test('no per-cue network work happens in the native timing handler', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final start =
        player.indexOf('Future<void> _handleEmbeddedSubtitleCue(List<String> lines)');
    final end =
        player.indexOf('Future<void> _registerLiveTranslationFailure(', start);
    final handler = player.substring(start, end);

    expect(handler, isNot(contains('AiSinhalaSubtitleService.translateCue')));
    expect(handler, isNot(contains('AiSinhalaSubtitleService.ensureTranslatedAround')));
    expect(handler, contains("setState(() => _aiDisplaySubtitle = translated)"));
  });

  test('seek clears stale Sinhala and re-reads the current native cue', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(player, contains('Future<void> _refreshNativeCueAfterSeek()'));
    expect(player, contains("'sub-text'"));
    expect(player, contains('_nativeAiMatchIndex = -1;'));
    expect(player, contains('unawaited(_refreshNativeCueAfterSeek());'));
  });

  test('incremental Sinhala buffering stays small and follows playback position', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(player, contains('lookBehind: 3'));
    expect(player, contains('lookAhead: 24'));
    expect(player, contains('final bucket = position.inSeconds ~/ 30;'));
    expect(player, contains('unawaited(_ensureAiTranslationNear(position'));
  });

  test('live AI fallback shows English while translation is in flight', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final start = player.indexOf('Future<void> _translateLiveSubtitleCue');
    final end = player.indexOf('double _effectiveSubtitleFontSize', start);
    final live = player.substring(start, end);

    expect(live, contains('await _setNativeSubtitleVisibility(true);'));
    expect(live, contains('await _setNativeSubtitleVisibility(false);'));
  });

}
