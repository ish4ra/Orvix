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
    expect(service, contains("match: 'video-hash'"));
    expect(service, contains("preserveProviderOrder: endpoint.match == 'video-hash'"));
    expect(
      service,
      contains("trust the provider's"),
    );
  });
}
