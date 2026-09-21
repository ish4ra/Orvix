import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('verified transcript is selected before playback but translated incrementally', () {
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();

    final start = service.indexOf(
      'prepareTranslatedTranscriptForNativeTiming',
    );
    final end = service.indexOf(
      'prepareGeneratedSinhalaFromNativeCalibration',
      start,
    );
    final transcript = service.substring(start, end);

    expect(transcript, contains('_downloadSubtitle(candidate.url)'));
    expect(transcript, contains('_parseSubtitle(text)'));
    expect(transcript, isNot(contains('_translateEntireSubtitle(')));
    expect(
      transcript,
      contains('Sinhala will buffer ahead while playback continues'),
    );
    expect(service, contains('ensureTranslatedAround('));
    expect(transcript, isNot(contains('_writeGeneratedSrt(')));
  });

  test('runtime timing comes from native cue events, never candidate timestamps', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final start =
        player.indexOf('Future<void> _handleEmbeddedSubtitleCue(List<String> lines)');
    final end =
        player.indexOf('Future<void> _registerLiveTranslationFailure(', start);
    final handler = player.substring(start, end);

    expect(handler, contains('matchSourceCueRange('));
    expect(handler, isNot(contains('subtitleAt(')));
    expect(handler, isNot(contains('_effectiveSyncOffsetMs')));
  });

  test('desktop subtitle scaling remains restrained', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(
      player,
      contains(
        'return (base * heightScale * 1.08).clamp(24.0, 44.0).toDouble();',
      ),
    );
  });
}
