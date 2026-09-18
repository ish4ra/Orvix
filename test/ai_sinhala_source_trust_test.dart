import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AI Sinhala never uses an untrusted generic timeline', () {
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(service, isNot(contains("match: 'title-episode'")));
    expect(
      service,
      contains('This stream does not expose enough release metadata'),
    );
    expect(service, contains('prepareForEmbeddedTiming'));
    expect(service, contains("sourceMatch: 'embedded-text-timing'"));
    expect(
      service,
      contains('requireReleaseEvidence && specificTokens.isEmpty'),
    );

    expect(player, contains('_tryPrepareEmbeddedAiTiming'));
    expect(
      player,
      contains('embedded text track is the real video clock'),
    );
    expect(player, isNot(contains('_tryEnableLiveAiFallback()')));
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
    expect(service, contains("_openSubtitlesExactEndpoint"));
    expect(service, contains("'opensubtitles-exact'"));
    expect(service, contains("sourceMatch: 'rest-moviehash'"));
    expect(service, contains("data['moviehash_match'] != true"));
    expect(service, contains("match: 'video-hash'"));
    expect(service, contains("requireHashEvidence: endpoint.match == 'video-hash'"));
    expect(service, contains("marker == 'h'"));
    expect(service, contains("entry['moviehash_match'] == true"));
    expect(service, contains("preserveProviderOrder: endpoint.match == 'video-hash'"));
    final embeddedIndex = player.indexOf(
      'final embeddedReady = await _tryPrepareEmbeddedAiTiming();',
    );
    final externalIndex = player.indexOf(
      'final prepared = await AiSinhalaSubtitleService.prepareBuffered(',
    );
    expect(embeddedIndex, greaterThanOrEqualTo(0));
    expect(externalIndex, greaterThan(embeddedIndex));
  });
}
