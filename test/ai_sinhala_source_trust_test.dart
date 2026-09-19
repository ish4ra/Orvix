import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AI Sinhala startup uses only exact-file OpenSubtitles timing', () {
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(service, contains('prepareExactFileFully'));
    expect(service, contains('probe.hash == null'));
    expect(service, contains('probe.size == null'));
    expect(service, contains('_fetchExactRestSubtitle('));
    expect(service, contains("sourceMatch: 'rest-moviehash-full'"));

    final start =
        player.indexOf('Future<bool> _prepareAiSinhalaBeforePlayback()');
    final end =
        player.indexOf('Future<void> _restoreNativeSubtitleFallback()', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final startup = player.substring(start, end);

    expect(startup, contains('prepareExactFileFully('));
    expect(startup, isNot(contains('_tryPrepareEmbeddedAiTiming()')));
    expect(startup, isNot(contains('prepareBuffered(')));
    expect(startup, isNot(contains('_enableEmbeddedLiveAiFallback(')));
  });

  test('exact OpenSubtitles file hash is preserved end to end', () {
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
    expect(service, contains("'videoUrl': videoUri.toString()"));
    expect(service, contains('_openSubtitlesExactEndpoint'));
    expect(service, contains("'opensubtitles-exact'"));
    expect(service, contains("sourceMatch: 'rest-moviehash-full'"));
    expect(service, contains('_fetchExactRestSubtitle('));
    expect(service, contains('_translateEntireSubtitle('));
  });
}
