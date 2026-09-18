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
    expect(player, contains('_embeddedMismatchCount < 3'));
    expect(player, contains('if (remainingMs < 700) return;'));
    expect(player, contains("'sub-end/full'"));
    expect(player, contains('_autoSyncSamples.length < 3'));
    expect(service, contains('math.min(96, cues.length)'));
    expect(service, contains('requireReleaseEvidence: endpoint.match =='));
    expect(SubtitlePreferencesService.defaultFontSize, 26);
  });
}
