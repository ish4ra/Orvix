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


  test('Windows preflight never promotes a generic v3 result to exact timing', () {
    final details = File('lib/screens/details_screen.dart').readAsStringSync();
    final online =
        File('lib/services/online_subtitle_service.dart').readAsStringSync();

    expect(details, contains('candidate.exactHashPath'));
    expect(details, contains('candidate.strongReleaseMatchCount > 0'));
    expect(details, contains('hash-addon-rejected'));
    expect(online, contains('final bool exactHashPath;'));
    expect(online, contains('final int strongReleaseMatchCount;'));
    expect(online, contains('exactHashPath: true'));
    expect(online, contains('exactHashPath: false'));
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
