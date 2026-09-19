import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/subtitle_preferences_service.dart';

void main() {
  test('AI Sinhala timing stability guards stay enabled', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();

    expect(
      player,
      contains('(_timingTrackSelected && _timingTrackIsText)'),
    );
    expect(player, contains('_tryPrepareEmbeddedAiTiming'));
    expect(player, contains('Future<bool> _enableEmbeddedLiveAiFallback'));
    expect(player, contains('_embeddedMismatchCount >= 4'));
    expect(player, contains('_registerLiveTranslationFailure'));
    expect(service, contains('prepareForEmbeddedTiming'));
    expect(service, contains("sourceMatch: 'embedded-text-timing'"));
    expect(service, isNot(contains("match: 'title-episode'")));
    expect(service, contains('requireReleaseEvidence && specificTokens.isEmpty'));
    expect(SubtitlePreferencesService.defaultFontSize, 26);
  });
}
