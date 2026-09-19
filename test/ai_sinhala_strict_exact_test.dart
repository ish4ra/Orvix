import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('generated-file mode preserves whole-file translation and SRT output', () {
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();

    final start = service.indexOf(
      'static Future<AiGeneratedSubtitleFile> prepareGeneratedSinhalaFile',
    );
    final end = service.indexOf(
      'static Future<AiPreparedSubtitle?> prepareExactFileFully',
      start,
    );
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final generated = service.substring(start, end);

    expect(generated, contains('_fetchEmbeddedEnglishSubtitle(videoUrl)'));
    expect(generated, contains('_translateEntireSubtitle('));
    expect(generated, contains('_writeGeneratedSrt('));
    expect(generated, contains('_fetchExactRestSubtitle('));
    expect(generated, contains('_generatedSubtitleCacheVersion'));
    expect(generated, contains('subtitle_cache'));
  });

  test('player startup loads Sinhala as a normal external subtitle track', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final start =
        player.indexOf('Future<bool> _prepareAiSinhalaBeforePlayback()');
    final end =
        player.indexOf('Future<void> _restoreNativeSubtitleFallback()', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final prepare = player.substring(start, end);

    expect(prepare, contains('prepareGeneratedSinhalaFile('));
    expect(prepare, contains('mk.SubtitleTrack.uri('));
    expect(prepare, contains("language: 'si'"));
    expect(prepare, contains('_transitionAi(AiSinhalaRuntimeMode.native)'));
    expect(prepare, isNot(contains('_tryPrepareEmbeddedAiTiming()')));
    expect(prepare, isNot(contains('_enableEmbeddedLiveAiFallback(')));
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
