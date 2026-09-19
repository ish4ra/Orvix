import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('strict AI Sinhala requires exact hash+size and full translation', () {
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();

    final start = service.indexOf(
      'static Future<AiPreparedSubtitle?> prepareExactFileFully',
    );
    final end = service.indexOf(
      'static Future<AiPreparedSubtitle?> prepareBuffered',
      start,
    );
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final strict = service.substring(start, end);

    expect(strict, contains('probe.hash == null'));
    expect(strict, contains('probe.size == null'));
    expect(strict, contains('_fetchExactRestSubtitle('));
    expect(strict, contains('_translateEntireSubtitle('));
    expect(
      strict,
      contains('prepared.translatedCount != prepared.cues.length'),
    );
    expect(strict, contains("sourceMatch: 'rest-moviehash-full'"));
    expect(strict, isNot(contains('opensubtitles-v3.strem.io')));
    expect(strict, isNot(contains('prepareForEmbeddedTiming')));
  });

  test('player startup does not use embedded fuzzy/live timing paths', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final start =
        player.indexOf('Future<bool> _prepareAiSinhalaBeforePlayback()');
    final end =
        player.indexOf('Future<void> _restoreNativeSubtitleFallback()', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final prepare = player.substring(start, end);

    expect(prepare, contains('prepareExactFileFully('));
    expect(prepare, isNot(contains('_tryPrepareEmbeddedAiTiming()')));
    expect(prepare, isNot(contains('prepareBuffered(')));
    expect(prepare, isNot(contains('_enableEmbeddedLiveAiFallback(')));
  });

  test('seek is an in-memory subtitle lookup only', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final start = player.indexOf('void _afterSeek(Duration target)');
    final end = player.indexOf('Future<void> _toggleMute()', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final seek = player.substring(start, end);

    expect(seek, contains('_refreshAiSubtitle();'));
    expect(seek, isNot(contains('_ensureEnglishTimingTrack')));
    expect(seek, isNot(contains('_ensureAiTranslationNear')));
  });

  test('desktop subtitle scaling is restrained', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(
      player,
      contains(
        'return (base * heightScale * 1.08).clamp(24.0, 44.0).toDouble();',
      ),
    );
  });
}
