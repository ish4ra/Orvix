import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('guest AI Sinhala pretranslates a transcript before real playback', () {
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(service, contains('static bool get canTranslate => true;'));
    expect(service, contains(r"'Authorization': 'Bearer $_guestFunctionJwt'"));
    expect(service, contains('translate-subtitle-si'));
    expect(
      service,
      contains('prepareTranslatedTranscriptForNativeTiming'),
    );
    expect(service, contains('_translateEntireSubtitle('));

    expect(player, contains('_captureNativeEnglishSamples()'));
    expect(player, contains('OnlineSubtitleService.search('));
    expect(
      player,
      contains('prepareTranslatedTranscriptForNativeTiming('),
    );
    expect(player, contains('_subtitleTimingSubscription ??='));
    expect(player, contains('player.stream.subtitle.listen(_onEmbeddedSubtitleCue)'));
  });
}
