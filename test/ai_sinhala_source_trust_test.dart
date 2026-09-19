import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('OpenSubtitles ranking is never trusted as timing truth', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final startupStart =
        player.indexOf('Future<bool> _prepareAiSinhalaBeforePlayback()');
    final startupEnd =
        player.indexOf('Future<void> _restoreNativeSubtitleFallback()', startupStart);
    final startup = player.substring(startupStart, startupEnd);

    expect(startup, contains('_captureNativeEnglishSamples()'));
    expect(startup, contains('OnlineSubtitleService.search('));
    expect(startup, contains('videoHash: null'));
    expect(startup, isNot(contains('final chosen = english.first;')));
    expect(
      startup,
      contains('prepareGeneratedSinhalaFromNativeCalibration('),
    );
  });

  test('candidate acceptance requires multiple native dialogue matches', () {
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();

    expect(service, contains('if (pairs.length < 3) return null;'));
    expect(service, contains('selected.matches < 3'));
    expect(service, contains('selected.medianResidualMs > 850'));
    expect(service, contains("sourceMatch: 'native-track-calibrated'"));
  });

  test('calibration supports constant offsets and small FPS drift', () {
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();

    expect(service, contains('scale < .94 || scale > 1.06'));
    expect(service, contains('offsets[offsets.length ~/ 2]'));
    expect(service, contains('medianResidual'));
  });

  test('exact local P2P hash still fails closed as fallback', () {
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();

    expect(service, contains("path: '/opensubHash'"));
    expect(service, contains("'videoUrl': videoUri.toString()"));
    expect(service, contains('size: null'));
    expect(service, contains('hash: null'));
  });
}
