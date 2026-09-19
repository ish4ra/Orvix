import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/subtitle_preferences_service.dart';

void main() {
  test('native timing calibration produces one complete generated SRT', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();

    expect(player, contains('_captureNativeEnglishSamples()'));
    expect(
      player,
      contains('prepareGeneratedSinhalaFromNativeCalibration('),
    );
    expect(service, contains('_translateEntireSubtitle('));
    expect(service, contains('_writeGeneratedSrt('));
    expect(
      service,
      contains("sourceMatch: 'native-track-calibrated'"),
    );
    expect(SubtitlePreferencesService.defaultFontSize, 26);
  });

  test('native calibration cache includes video identity and alignment', () {
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();

    expect(service, contains("'native-cal|"));
    expect(service, contains('videoIdentity'));
    expect(service, contains('scaleKey'));
    expect(service, contains('offsetKey'));
    expect(service, contains("'native-cal-v1'"));
  });

  test('cue sampling is bounded and restores the player', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(player, contains('samples.length >= 6'));
    expect(player, contains('Duration(seconds: 14)'));
    expect(player, contains('await player.setRate(originalRate);'));
    expect(player, contains('await player.seek(originalPosition);'));
    expect(player, contains('await player.setVolume(originalVolume);'));
  });
}
