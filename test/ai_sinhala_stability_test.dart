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
    expect(player, contains('unawaited(_refreshNativeCueAfterSeek());'));
  });

  test('live AI fallback shows English while translation is in flight', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final start = player.indexOf('Future<void> _translateLiveSubtitleCue');
    final end = player.indexOf('double _effectiveSubtitleFontSize', start);
    final live = player.substring(start, end);

    expect(live, contains('await _setNativeSubtitleVisibility(true);'));
    expect(live, contains('await _setNativeSubtitleVisibility(false);'));
  });


  test('re-enabling prepared AI restores native timing with English fallback', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final start = player.indexOf('Future<void> _enablePreparedAiSubtitle()');
    final end = player.indexOf('Future<void> _setSubtitleFontSize', start);
    final method = player.substring(start, end);

    expect(method, contains('await _ensureEnglishTimingTrack();'));
    expect(method, contains('await _setNativeSubtitleVisibility(true);'));
    expect(method, contains('unawaited(_ensureAiTranslationNear(position'));
    expect(method, contains('unawaited(_refreshNativeCueAfterSeek());'));
  });


  test('player exposes a persistent AI Sinhala switch and persists the preference', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(player, contains('class _AiSinhalaSwitchTile'));
    expect(player, contains("title: const Text(\n          'AI Sinhala'"));
    expect(player, contains('AiSinhalaPreferencesService.setEnabled(enabled)'));
    expect(player, contains('_setAiSinhalaEnabledFromPlayer(value)'));
  });

  test('all prepared AI startup paths subscribe position and prebuffer nearby Sinhala', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final openStart = player.indexOf('Future<void> _open()');
    final embeddedStart =
        player.indexOf('Future<bool> _tryPrepareEmbeddedAiTiming()', openStart);
    final open = player.substring(openStart, embeddedStart);

    expect(open, contains('player.stream.position.listen(_onPosition)'));
    expect(open, contains('unawaited(_ensureAiTranslationNear(position'));
  });

  test('selected native English track identity is passed to embedded transcript extraction', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(player, contains('preferredTrackLabel: _subtitleTrackPreferenceLabel(chosen)'));
    expect(player, contains('preferredTrackLabel: _subtitleTrackPreferenceLabel(timingTrack)'));
  });


  test('native clock directly reads ASS text so AI does not depend on stream events', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final start = player.indexOf('Future<void> _pollNativeSubtitleClock()');
    final end = player.indexOf('void _acceptAutoSyncSample', start);
    final poller = player.substring(start, end);

    expect(poller, contains("'sub-text'"));
    expect(poller, contains('_handleEmbeddedSubtitleCue(<String>[text])'));
    expect(poller, contains('if (_timingTrackIsText)'));
  });

}
