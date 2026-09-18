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
}
