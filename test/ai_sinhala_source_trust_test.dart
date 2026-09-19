import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AI Sinhala source order is embedded exact timing then exact hash', () {
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final generatedStart =
        service.indexOf('prepareGeneratedSinhalaFile');
    final generatedEnd =
        service.indexOf('prepareExactFileFully', generatedStart);
    expect(generatedStart, greaterThanOrEqualTo(0));
    expect(generatedEnd, greaterThan(generatedStart));
    final generated = service.substring(generatedStart, generatedEnd);

    expect(generated, contains('_fetchEmbeddedEnglishSubtitle(videoUrl)'));
    expect(generated, contains('_probeVideo('));
    expect(generated, contains('_fetchExactRestSubtitle('));
    expect(generated, contains('_translateEntireSubtitle('));
    expect(generated, contains('_writeGeneratedSrt('));

    final startupStart =
        player.indexOf('Future<bool> _prepareAiSinhalaBeforePlayback()');
    final startupEnd =
        player.indexOf('Future<void> _restoreNativeSubtitleFallback()', startupStart);
    final startup = player.substring(startupStart, startupEnd);

    expect(startup, contains('prepareGeneratedSinhalaFile('));
    expect(startup, isNot(contains('_tryPrepareEmbeddedAiTiming()')));
    expect(startup, isNot(contains('prepareBuffered(')));
    expect(startup, isNot(contains('_enableEmbeddedLiveAiFallback(')));
  });

  test('exact OpenSubtitles fingerprint remains the fallback', () {
    final sources =
        File('lib/services/source_provider_service.dart').readAsStringSync();
    final details = File('lib/screens/details_screen.dart').readAsStringSync();
    final player = File('lib/screens/player_screen.dart').readAsStringSync();
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();

    expect(sources, contains("hints?['videoHash']"));
    expect(sources, contains('final String? videoHash;'));
    expect(details, contains('expectedVideoHash: chosen.videoHash'));
    expect(player, contains('expectedVideoHash: widget.expectedVideoHash'));
    expect(service, contains('_normalizeVideoHash(expectedVideoHash)'));
    expect(service, contains('_probeLocalOpenSubtitlesHash('));
    expect(service, contains("path: '/opensubHash'"));
    expect(service, contains('_openSubtitlesExactEndpoint'));
    expect(service, contains('_fetchExactRestSubtitle('));
  });
}
