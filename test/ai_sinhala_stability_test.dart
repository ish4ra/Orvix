import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/subtitle_preferences_service.dart';

void main() {
  test('AI Sinhala uses a complete generated file, not per-cue live translation', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();

    final start =
        player.indexOf('Future<bool> _prepareAiSinhalaBeforePlayback()');
    final end =
        player.indexOf('Future<void> _restoreNativeSubtitleFallback()', start);
    final startup = player.substring(start, end);

    expect(
      startup,
      contains('prepareGeneratedSinhalaFromOnlineSubtitle('),
    );
    expect(startup, isNot(contains('_translateLiveSubtitleCue')));
    expect(startup, isNot(contains('_handleEmbeddedSubtitleCue')));
    expect(service, contains('_translateEntireSubtitle('));
    expect(service, contains('_writeGeneratedSrt('));
    expect(
      service,
      contains("sourceMatch: 'user-or-ranked-online-subtitle'"),
    );
    expect(SubtitlePreferencesService.defaultFontSize, 26);
  });

  test('generated file path is cached by subtitle identity and URL', () {
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();

    expect(
      service,
      contains("'online|\$subtitleIdentity|\$cleanUrl|\$_generatedSubtitleCacheVersion'"),
    );
    expect(service, contains("'srt-v2-online-source'"));
  });
}
